// ODataIncrementalStore — a Core Data model served over OData.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// ODataService is the server's core: it takes an OData request and answers
// it from a Core Data store, and never sees a socket (docs/server-design.md).
// It is an ODataTransport, so an ODataIncrementalStore can be handed one
// and talk to a Core Data store through OData in-process; the HTTP adapter
// (HSServer) hands it requests from the network the same way.
//
// What it serves, read from the model through ODataPropertyMapper:
//   - the service document and $metadata (ODataMetadataWriter);
//   - entity sets, entities by key (Products(1), and Products/1), their
//     properties and raw values ($value), navigation (Categories(1)/Products),
//     and /$count;
//   - $filter, $orderby, $top, $skip, $count, $select, $expand with its
//     own options, $skiptoken for server-driven paging, parameter aliases;
//   - POST, PATCH, PUT, DELETE, with @odata.bind for relationships, ETags
//     and If-Match, Prefer return=minimal|representation;
//   - OData 4.01, and 4.0 for a client that asks for no more
//     (OData-MaxVersion).
// Every failure is an OData error body with its status: 400 for a request
// that does not parse or does not fit the model, 404, 405, 412, and 501 for
// what is not supported yet.
//
// An application changes what an entity set does with an
// ODataEntitySetHandler, adds actions and functions by declaring them in
// protocols (below), and answers through an ODataReply.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataTransport.h>
#import <ODataKit/ODataExpression.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

@class ODataService, ODataRequest, HSPrincipal, HSMetrics, OTTracer, OTSpan;
@protocol HSAuthenticator;

// userInfo on an Integer attribute: the entity's version, sent as its ETag
// and incremented by every update. Without one, an entity's ETag is a hash
// of its values.
FOUNDATION_EXPORT NSString * const ODataUserInfoETag;  // @"OData.etag"

// How a handler answers. The service is the only caller of a handler's
// methods, and the reply is its end of the call. A method that can answer
// at once returns its result, or calls -failWithError: and returns nil. A
// method that has to wait for something calls -defer, returns (what it
// returns is then ignored), and later, on any thread, calls
// -finishWithResult: or -failWithError:. Whatever it does with the
// request's context after returning goes through -performBlock:. A
// deferred reply that is not answered within the service's replyTimeout
// is answered 504 for it, and a later answer is ignored.
@interface ODataReply : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (void)defer;
- (void)finishWithResult:(nullable id)result;
- (void)failWithError:(NSError *)error;
@property (nonatomic, readonly, getter=isDeferred) BOOL deferred;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
@property (nonatomic, readonly, strong, nullable) id result;
@property (nonatomic, readonly, strong, nullable) NSError *error;
// The request being answered: its context, its headers, and for an
// operation bound to a collection, the collection.
@property (nonatomic, readonly, weak, nullable) ODataRequest *request;
// The span of what was asked: an operation's call ("call Name"), a store
// request ("fetch Product"). Current on the thread while the method runs;
// work it defers to another thread makes it current there itself, so what
// that work traces goes under the request too:
//
//   [reply defer];
//   [self.engine startProcess:... then:^{
//     [reply.span becomeCurrent];
//     ... what traces ...
//     [reply.span resignCurrent];
//     [reply finishWithResult:outcome];
//   }];
@property (nonatomic, readonly, strong, nullable) OTSpan *span;
@end

// Operations. Objective-C has no annotations, so a protocol declares them:
// one that inherits ODataFunctions declares functions (no side effects,
// called with GET), one that inherits ODataActions actions (POST). Every
// method takes an ODataReply as its last parameter.
//
//   @protocol ProductFunctions <ODataFunctions>
//   - (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply;
//   + (NSArray *)pricierThanPrice:(double)price reply:(ODataReply *)reply;
//   @end
//   @interface Product : NSManagedObject <ProductFunctions>
//
// An instance method of an entity's managed object class is bound to the
// entity (Products(1)/Default.DiscountedPriceByPercent(Percent=10)), a class
// method to its collection (Products/Default.PricierThanPrice(Price=20)),
// and a method of the service's serviceOperations object is unbound,
// reached through an import (CountProducts()). Only protocols a class
// adopts itself count, not those it inherits.
//
// Names come from the selector, by the mapper's naming: the first keyword
// up to "With" names the operation and the rest the first parameter
// (shareTripWithUserName:tripId:reply: is ShareTrip(UserName, TripId));
// without "With", the whole keyword names the operation and its last word
// the parameter (pricierThanPrice: is PricierThanPrice(Price)). Types come
// from the protocol's extended type encodings, which name each object
// parameter's class: int32_t is Edm.Int32, int64_t Edm.Int64, int16_t
// Edm.Int16, double Edm.Double, float Edm.Single, BOOL Edm.Boolean,
// NSString Edm.String, NSDate Edm.DateTimeOffset, NSDecimalNumber
// Edm.Decimal, NSUUID Edm.Guid, NSData Edm.Binary, NSDictionary
// Edm.Untyped, a managed object class its entity type. An Edm.Untyped (or
// Org.OData.JSON.V1.JSON) value is any JSON, passed as NSJSONSerialization
// reads it and written as it would write it (4.0's $metadata says
// Org.OData.JSON.V1.JSON for Edm.Untyped, which is CSDL 4.01's); declare
// an id or NSArray parameter so to take one. What the runtime cannot see, a collection's element type
// or which number an NSNumber is, the class says in a class method, and it
// can rename what the rules get wrong:
//
//   + (NSDictionary *)ODataOperationTypes
//   { return @{ @"pricierThanPrice:reply:": @"Collection(Default.Product)",
//               @"countWithLimit:reply:.limit": @"Edm.Int32" }; }
//   + (NSDictionary *)ODataOperationNames
//   { return @{ @"pricierThanPrice:reply:": @"MorePricey",
//               @"pricierThanPrice:reply:.price": @"Floor" }; }
//
// An operation that needs a permission says so in another class method,
// any one of the scopes it names being enough (403 without; $metadata says
// it as the overload's OperationRestrictions). What it answers with is its
// own; what that is expanded with, or a bound one is called on, is read
// (the sets' readScopes), all checked before it is called:
//
//   + (NSDictionary *)ODataOperationScopes
//   { return @{ @"raisePriceByPercent:reply:": @[ @"Products.Write" ] }; }
//
// A declaration the service cannot type is listed in operationProblems and
// left out; so is one whose scopes name no scope (a scope, or an array or
// set of them), and a scope named for no operation (a typo) is listed too.
// ois-serve refuses to start with any.
@protocol ODataFunctions
@end
@protocol ODataActions
@end

// A request as the service read it.
@interface ODataRequest : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, weak) ODataService *service;
@property (nonatomic, readonly) NSURLRequest *URLRequest;
@property (nonatomic, readonly, copy) NSString *method;
// Header names are case-insensitive.
- (nullable NSString *)valueForHeader:(NSString *)name;
@property (nonatomic, readonly, strong) ODataResourcePath *path;
@property (nonatomic, readonly, strong) ODataQueryOptions *options;
// The entity the request is about: its entity set's, or the type an
// inserted entity's @odata.type names.
@property (nonatomic, readonly, strong, nullable) NSEntityDescription *entity;
// For an operation bound to a collection: the collection's rows, as a fetch
// request (its navigation, and what the set lets the caller see).
@property (nonatomic, readonly, strong, nullable) NSFetchRequest *collectionFetchRequest;
// The request's own private-queue context. Handler methods run inside its
// -performBlockAndWait:.
@property (nonatomic, readonly, strong) NSManagedObjectContext *context;
// The OData-Version the response is in: 4.0 or 4.01.
@property (nonatomic, readonly, copy) NSString *version;
// Prefer, by preference name in lower case: return, odata.maxpagesize, ...
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *preferences;
// The application's own, for the length of the request.
@property (nonatomic, readonly, strong) NSMutableDictionary *userInfo;
// Who is asking, as the service's authenticator found them; nil without
// one, or for an anonymous request it allows (HSAuthentication.h).
@property (nonatomic, readonly, strong, nullable) HSPrincipal *principal;
// Something to tell the client alongside the answer (Core.Messages): a
// price rounded, a property ignored. Written into the response's JSON
// body, unless the client's Prefer: odata.include-annotations leaves
// Core.Messages out; a response without a body (204) has none to carry
// it. Severity: success, info, warning or error. From any thread.
- (void)addMessage:(NSString *)message code:(NSString *)code severity:(NSString *)severity target:(nullable NSString *)target;
@property (nonatomic, readonly, copy) NSArray<ODataMessage *> *messages;
@end

// What changed in a set since a token (Part 1 section 11.3, delta links):
// the objects inserted or updated, first changed first; those deleted, by
// entity and key values (Core Data attribute names, as a tombstone keeps
// them); and the token the next delta goes on from.
@interface ODataChanges : NSObject
+ (instancetype)changesWithToken:(NSString *)token;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, readonly, copy) NSArray<NSManagedObjectID *> *changed;
// Each @{ @"entity": NSEntityDescription, @"values": key values }.
@property (nonatomic, readonly, copy) NSArray<NSDictionary *> *deleted;
- (void)addChanged:(NSManagedObjectID *)objectID;
- (void)addDeletedEntity:(NSEntityDescription *)entity keyValues:(NSDictionary<NSString *, id> *)values;
@end

// What an entity set does. The default does everything over the request's
// context; a subclass overrides what it needs to and is registered with
// -[ODataService setHandler:forEntitySet:]. Values are keyed by Core Data
// property name: attributes hold Core Data values, relationships managed
// objects (a set of them for a to-many relationship). The service saves
// after insert, update and delete, and reports a failed save.
@interface ODataEntitySetHandler : NSObject

- (instancetype)initWithEntity:(NSEntityDescription *)entity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSEntityDescription *entity;
@property (nonatomic, readonly, weak, nullable) ODataService *service;

// What the set allows. A method it does not is answered with 405. A
// read-only service's sets allow none of them, whatever they are set to.
@property (nonatomic) BOOL allowsInsert;
@property (nonatomic) BOOL allowsUpdate;
@property (nonatomic) BOOL allowsDelete;
// Upsert (Part 1 section 11.4.4): a PATCH or PUT to a key of the set that
// names no entity creates it, through -insertObjectWithValues:, with the
// key from the URL (which the body need not repeat, and must not
// contradict), and is answered 201 (204 with return=minimal); with
// If-Match it is 412 instead, there being nothing to match. With
// If-None-Match: * a PATCH or PUT only creates: 412 when the entity is
// there. What a client that makes its own keys (UUIDs) sends again and
// again with the same outcome. Default YES; needs allowsInsert, and is
// said in $metadata (UpdateRestrictions/Upsertable) when allowsUpdate too.
@property (nonatomic) BOOL allowsUpsert;
// The permissions the set's methods need, as OAuth scopes the caller's
// principal has (HSPrincipal's scopes): any one of a set's is enough;
// nil or empty, the default, none is needed. Read is every read that
// reaches the set's rows -- along the path (an entity, a navigation to
// them), and through $expand, $filter (a lambda, a path's $filter), $orderby,
// $compute, $apply. The others are the writes, of an entity, a property, a
// $ref (the row whose navigation property it is), in a deep insert or
// update, a $batch or a temporal action; a write's path reads the sets it
// passes through, not the one it writes, and its answer is what it wrote
// (what else it is asked to expand is read; what the service expands
// unasked, the nested entities of a deep write, is left out where the
// caller may not read it). Everything a request needs is checked before
// anything is written; a caller without it is answered 403 (401 when no
// one asks), WWW-Authenticate naming the scopes (RFC 6750,
// insufficient_scope). $metadata says them as the set's ReadRestrictions,
// InsertRestrictions, UpdateRestrictions and DeleteRestrictions
// Permissions, under the authenticator's scheme (Capabilities and
// Authorization vocabularies); $explain, as the plan's.
@property (nonatomic, copy, nullable) NSSet<NSString *> *readScopes;
@property (nonatomic, copy, nullable) NSSet<NSString *> *insertScopes;
@property (nonatomic, copy, nullable) NSSet<NSString *> *updateScopes;
@property (nonatomic, copy, nullable) NSSet<NSString *> *deleteScopes;
// Properties (wire names) of the set's entities that $filter, and
// $orderby, may not use: answered 400, and said in $metadata
// (Capabilities.FilterRestrictions, SortRestrictions). Empty by default.
@property (nonatomic, copy) NSSet<NSString *> *nonFilterableProperties;
@property (nonatomic, copy) NSSet<NSString *> *nonSortableProperties;
// What $search looks in (Part 2 section 5.1.7): these properties (wire
// names), each a string; a word or "phrase" matches a row where one of
// them holds it, regardless of case and diacritics. nil, the default:
// every string property. Empty: the set cannot be searched (501), as
// $metadata says (Capabilities.SearchRestrictions).
@property (nonatomic, copy, nullable) NSSet<NSString *> *searchableProperties;
// $apply (Data Aggregation section 5.1), said in $metadata as the set's
// Aggregation.ApplySupported. The properties (wire names, or paths
// through to-one navigation: Category, Category/CategoryName) groupby may
// use, and aggregate may, each with the methods it may be aggregated with
// (sum, …, or a custom one; none listed: any); nil, the default: every
// property. A path is allowed when it, or where it starts, is listed.
@property (nonatomic, copy, nullable) NSSet<NSString *> *groupableProperties;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSArray<NSString *> *> *aggregatableProperties;
// Aggregation methods of the handler's own, namespace-qualified
// (Custom.concat): aggregate(Name with Custom.concat as Names). Each is
// computed by -valueOfAggregationMethod:values:request:. Empty by default.
@property (nonatomic, copy) NSSet<NSString *> *customAggregationMethods;
// Custom aggregates (Aggregation.CustomAggregate): name to the Edm type of
// its value (@"Forecast": @"Edm.Decimal"); aggregate(Forecast) or
// aggregate(Forecast as F), each computed by
// -valueOfCustomAggregate:objects:request:. Empty by default.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *customAggregates;

// A custom aggregation method's value over a group's values (nulls left
// out); a custom aggregate's over a group's objects. nil for null. The
// defaults answer nil.
- (nullable id)valueOfAggregationMethod:(NSString *)method values:(NSArray *)values request:(ODataRequest *)request;
- (nullable id)valueOfCustomAggregate:(NSString *)name objects:(NSArray<NSManagedObject *> *)objects request:(ODataRequest *)request;

// Whether a read of the set may ask to follow its changes (Prefer:
// odata.track-changes, Part 1 section 11.3): a delta link, answered by
// -changesSince:request:reply:. YES by default; a handler whose rows are
// not the store's, and that has no changes of its own to give, says NO.
@property (nonatomic) BOOL tracksChanges;
// Whether it can, as $metadata says (Capabilities.ChangeTracking). The
// default: tracksChanges, and the store's persistent history, which every
// store keeps (NSPersistentHistoryTrackingKey), with the set's key
// attributes kept in a deletion's tombstone
// (preservesValueInHistoryOnDeletion). A handler that gives changes of
// its own says so here.
- (BOOL)canTrackChanges;
// Where changes are followed from, now: a token -changesSince: takes. The
// default: the persistent history's.
- (nullable NSString *)changeTokenForRequest:(ODataRequest *)request;
// What changed in the set since a token this gave (the set's rows only: the
// service keeps those the request matches, and names the others it no
// longer does). A token it did not give is a failure with a 400
// (ODataServiceError), one it can no longer answer for a 410: the caller
// reads the set again. The default: the persistent history since it.
- (nullable ODataChanges *)changesSince:(NSString *)token request:(ODataRequest *)request reply:(ODataReply *)reply;
// The version of what the caller may see (-predicateForVisibleObjectsInRequest:),
// for what changes it other than the rows themselves changing: the
// principal's role, region or teams. A short opaque string (a counter the
// application moves when a membership changes, or a digest of the claims
// that decide it), which delta links carry; one followed with another
// version is answered 410, and the client reads the set again (or
// reconciles its keys: docs/offline-sync.md, 4.1). nil, the default: delta
// links do not depend on it.
- (nullable NSString *)scopeVersionForRequest:(ODataRequest *)request;

// Whether the set's entity type is open (OpenType in $metadata): its
// entities may have dynamic properties, properties the model does not
// declare, which -dynamicPropertiesOfObjects:request:reply: gives,
// -writeDynamicProperties:... keeps, and -predicateForDynamicProperty:...
// filters by. $select may name one, and
// an entity without it leaves it out. Where they are kept is the
// handler's to say (docs/server-design.md); by default, in the entity's
// dynamicPropertiesAttribute. NO by default, but YES for an entity that
// has one.
@property (nonatomic, getter=isOpenType) BOOL openType;
// An entity that keeps its dynamic properties itself: a Transformable
// attribute marked OData.dynamicProperties, an NSDictionary (see
// ODataPropertyMapper.h), which the service serves as no property of its
// own. The methods below keep them in it by default: they are read from
// it, written into it (null removing one, a PUT replacing them all), and
// filtered by in memory. The caveat: a Transformable is an archive, which
// no store filters by, so a filter that names a dynamic property reads
// every row the rest of the request allows (maxRowsInMemory at most, then
// 400) and is evaluated here, and so are its order and paging. For a set
// that grows, keep them in rows of their own and override these methods,
// and storeFiltersDynamicProperties. nil for none.
@property (nonatomic, readonly, nullable) NSAttributeDescription *dynamicPropertiesAttribute;
// Whether -predicateForDynamicProperty:...'s predicates go into the
// store's fetch with the rest of the filter (a subquery over rows of the
// application's own, say); NO: the service reads the rows and filters
// them itself. Default: YES, but NO while dynamic properties are kept in
// dynamicPropertiesAttribute.
@property (nonatomic) BOOL storeFiltersDynamicProperties;
// The dynamic properties of the set's entities a response writes, read
// at once, after its rows and their expansions (the plan's last step):
// by object ID, each entity's by name, each a value the service writes as
// it would an attribute's of its class (a dictionary or an array as JSON;
// a date, a decimal, a UUID or data annotated with its type). An entity
// with none may be left out; the names of its declared properties are
// ignored. Asked once a response for an open type only, inside the
// request context's -performBlockAndWait:, with the objects in the order
// they are written. The answer now, or nil and later through the reply
// (-[ODataReply returned:], or -failWithError: to fail the request). The
// default: none.
- (nullable NSDictionary<NSManagedObjectID *, NSDictionary<NSString *, id> *> *)
    dynamicPropertiesOfObjects:(NSArray<NSManagedObject *> *)objects
                       request:(ODataRequest *)request
                         reply:(ODataReply *)reply;
// The dynamic properties a write gives the set's entities: of every one
// its bodies insert or update (a deep insert's and a delta's included),
// asked at once, after the declared properties are set and before the
// save; values[i] are objects[i]'s, by name, each decoded as its type
// annotation says (Since@odata.type: #DateTimeOffset is an NSDate) or as
// its JSON is, NSNull for one the body sets to null, which removes it. A
// PUT replaces an entity: the dynamic properties its body leaves out go
// too (request.method says which). Keep them where they are kept: what
// the handler changes in the request context is saved with the rest.
// Answer anything but nil (@YES) now, or later through the reply; an
// error (-failWithError:) fails the write, and nothing of it is saved. The
// default keeps them in dynamicPropertiesAttribute; without one it
// refuses them (400).
- (nullable id)writeDynamicProperties:(NSArray<NSDictionary<NSString *, id> *> *)values
                            ofObjects:(NSArray<NSManagedObject *> *)objects
                              request:(ODataRequest *)request
                                reply:(ODataReply *)reply;
// $filter's comparison of a dynamic property with a value, as a predicate
// over the set's entity: Priority gt 2, or Variables/amount ge 100 (a path,
// the property's name first). The operator reads with the property on the
// left; eq, ne, gt, ge, lt and le are asked for, in as each value's eq, and
// the property alone as a condition its eq true. The value is the
// literal's: a number, string, boolean, NSDate ..., nil for null. The
// predicate is evaluated by the store, or in memory, so it may not fetch;
// a subquery over rows the entity reaches is how rows kept elsewhere
// answer. nil, with an error (ODataServiceError), refuses it; nil without
// one says there is no such property (400). Asked of an open type only,
// in the request's filter; the default: nil.
- (nullable NSPredicate *)predicateForDynamicProperty:(NSArray<NSString *> *)path
                                             operator:(NSPredicateOperatorType)type
                                                value:(nullable id)value
                                              request:(ODataRequest *)request
                                                error:(NSError **)error;

// The rows the caller may see at all, however they are reached: fetched,
// by key, through navigation or $expand. nil: every row. A deletion is
// reported in a delta (Prefer: odata.track-changes) to a caller this lets
// see the deleted row, evaluated on what its tombstone kept: so keep the
// attributes it reads (preservesValueInHistoryOnDeletion), or every caller
// is told of every deletion, as when it reads anything not kept.
- (nullable NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request;

// The rows of a request, already filtered, sorted and paged, with
// -predicateForVisibleObjectsInRequest: in its predicate.
- (nullable NSArray<NSManagedObject *> *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest
                                                        request:(ODataRequest *)request
                                                          reply:(ODataReply *)reply;
// $apply's groupby and aggregate, where the store can do them: a fetch of
// dictionaries (NSDictionaryResultType), grouped by propertiesToGroupBy
// and aggregated by the expressions in propertiesToFetch, with
// -predicateForVisibleObjectsInRequest: in its predicate; the dictionaries.
// The default executes it. The service asks this only of a handler that
// overrides it, or that does not override -objectsForFetchRequest:...: a
// handler whose rows are not the store's has its rows grouped by the
// service, from what -objectsForFetchRequest:... answers.
- (nullable NSArray<NSDictionary *> *)groupedRowsForFetchRequest:(NSFetchRequest *)fetchRequest
                                                         request:(ODataRequest *)request
                                                           reply:(ODataReply *)reply;
// How many rows the same request has, without paging; an NSNumber.
- (nullable NSNumber *)countForFetchRequest:(NSFetchRequest *)fetchRequest
                                    request:(ODataRequest *)request
                                      reply:(ODataReply *)reply;
// The row with this key (by Core Data attribute name), among the visible
// ones; nil when there is none (404).
- (nullable NSManagedObject *)objectWithKey:(NSDictionary<NSString *, id> *)key
                                    request:(ODataRequest *)request
                                      reply:(ODataReply *)reply;
- (nullable NSManagedObject *)insertObjectWithValues:(NSDictionary<NSString *, id> *)values
                                             request:(ODataRequest *)request
                                               reply:(ODataReply *)reply;
- (nullable NSManagedObject *)updateObject:(NSManagedObject *)object
                                    values:(NSDictionary<NSString *, id> *)values
                                   request:(ODataRequest *)request
                                     reply:(ODataReply *)reply;
// Finishes with no result.
- (void)deleteObject:(NSManagedObject *)object request:(ODataRequest *)request reply:(ODataReply *)reply;

@end

@interface ODataService : NSObject <ODataTransport>

// A service over a coordinator's stores, answering requests under this
// root: its path is where the service is (http://example.com/odata/), and
// the whole URL is what the service's own links begin with, so behind a
// reverse proxy it is the public one.
- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator
                                       serviceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSPersistentStoreCoordinator *coordinator;
@property (nonatomic, readonly) NSManagedObjectModel *model;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
// Names, keys and types. Set this, and the next two, before the first
// request: the service's $metadata is written from them then.
@property (nonatomic, strong) ODataPropertyMapper *mapper;
@property (nonatomic, copy) NSString *namespaceName;  // Default: Default
@property (nonatomic, copy) NSString *containerName;  // Default: Container
// The newest version the service speaks: 4.01 (the default) or 4.0.
@property (nonatomic, copy) NSString *maxVersion;
// Server-driven paging: at most this many rows a response, with a next
// link for the rest. 0, the default: as many as the client asks for
// (Prefer: odata.maxpagesize), else all of them.
@property (nonatomic) NSUInteger maxPageSize;
// How long a deferred reply may take before the request is answered 504
// Gateway Timeout. 0: no limit. Default: 60 seconds.
@property (nonatomic) NSTimeInterval replyTimeout;
// Repeatable requests (OData Repeatable Requests 1.0; the Repeatability
// vocabulary): a request that changes something and carries
// Repeatability-Request-ID and Repeatability-First-Sent is answered once,
// and its answer remembered this long; the same request again is given
// the same answer, with Repeatability-Result: accepted. One first sent
// longer ago than that, or an ID given to another request, is answered
// 400, Repeatability-Result: rejected. An answer 5xx is not remembered.
// 0 turns it off. Default: 3600 seconds.
@property (nonatomic) NSTimeInterval repeatabilityDuration;
// How much of the answers it keeps for that (bytes, their bodies): past it
// the oldest are let go, and an answer larger than it is not kept (a
// repeat of either is answered by doing it again, as one without the
// header would be). A sync of many changes sends many large answers
// (each $batch's): kept whole for the duration, they would add up to
// much of a server's memory. Default: 32 MB.
@property (nonatomic) NSUInteger repeatabilityMemory;
// Asynchronous requests (Part 1 sections 8.2.8.8 and 11.6). A request that
// prefers respond-async and is not answered at once (a handler or the
// authenticator defers, for longer than Prefer: wait=N allows) is answered
// 202 Accepted with a status monitor, $async/<id>, in Location. A GET of
// the monitor is 202 while the request is under way, then 200 with its
// answer as application/http; DELETE forgets it. Only who sent the request
// may ask. An answer is kept this long after it is ready. 0: respond-async
// is not applied. Default: 600 seconds.
@property (nonatomic) NSTimeInterval asyncResultDuration;
// At most this many asynchronous requests at a time, answered or not; more
// are answered as though they had not asked. Default: 1000.
@property (nonatomic) NSUInteger maxAsyncRequests;
// How long the store's persistent history is kept, in seconds: what is
// older is deleted, in the background, as requests come (at most every
// tenth of this, between a minute and an hour), and a delta link from
// before it is answered 410, so its client reads the set again. A delta
// link stays good this long after it was given. 0, the default: the
// service deletes none (history grows until something else prunes it).
@property (nonatomic) NSTimeInterval historyRetention;
// The store's persistent history before date deleted, now, as
// historyRetention does by itself.
- (BOOL)pruneHistoryBeforeDate:(NSDate *)date error:(NSError **)error;

// Limits on what one request may ask of the service, so that no request,
// careless or hostile, takes more than its share. Each is answered with an
// error saying so; 0 is no limit.
// A URL longer than this many characters: 414. Default: 8192.
@property (nonatomic) NSUInteger maxURLLength;
// $expand nested deeper than this, or $levels beyond it: 400. Default: 8.
@property (nonatomic) NSUInteger maxExpandDepth;
// More requests than this in one $batch: 400. Default: 100.
@property (nonatomic) NSUInteger maxBatchRequests;
// Work the store cannot do and the service does in memory ($apply's
// grouping and the rest, $orderby by a computed value, a filter on
// dynamic properties kept in a Transformable, a temporal action) over
// more rows than this: 400, to be narrowed with $filter.
// Default: 10000.
@property (nonatomic) NSUInteger maxRowsInMemory;
// A JSON body nested deeper than this: 400. Default: 64.
@property (nonatomic) NSUInteger maxJSONDepth;
// Each read is planned before it runs, in a nested relational algebra
// (docs/query-plan.md): what the store does, what is done here. With
// explains, GET <root>/$explain/<resource path>?<query> answers with a
// read's plans (logical and physical) instead of its rows; not standard
// OData, and off by default. With logsPlans, each read's plan is logged.
@property (nonatomic) BOOL explains;
@property (nonatomic) BOOL logsPlans;
// What its work takes. Each request is a span (OTelKit), under the
// traceparent it came with: "plan" (from the request read to its plan
// made, the plan's tree an attribute), then "execute", with a span for
// each request of a handler or the store ("fetch Product", "count Order",
// "write Order") and each save, current on its thread while the store
// works, so a store that traces puts its spans under it; and each call of
// an action or function ("call Name"), current while its method runs, so
// the spans of what it does go under it too. Recorded when the shared
// OTTracerProvider is. Default: ODataService's tracer.
@property (nonatomic, strong) OTTracer *tracer;
// Where the same is counted and timed, when set (ODataServiceModule sets
// the application's): odata_plan_duration_seconds and
// odata_execution_duration_seconds by entity;
// odata_store_request_duration_seconds and odata_store_errors_total by
// operation and entity; odata_store_rows_total by entity.
@property (nonatomic, strong, nullable) HSMetrics *metrics;
// Who each request is from (HSAuthentication.h). A request that names
// no one is answered 401, unless allowsAnonymousRequests; without an
// authenticator (the default) every request is anonymous and answered.
@property (nonatomic, strong, nullable) id<HSAuthenticator> authenticator;
@property (nonatomic) BOOL allowsAnonymousRequests;
// The service document and $metadata to anyone, as a client needs them
// to learn how to sign in (the Authorization vocabulary in $metadata).
// Default: NO.
@property (nonatomic) BOOL allowsAnonymousMetadata;
// Annotations of the entity container in $metadata, by term
// (Core.Description, Authorization.Authorizations, or qualified), valued
// as JSON CSDL has them (ODataSchema.h). Set before the first request.
// Entities and properties are annotated from the model (see
// ODataMetadataWriter.h), how to sign in from the authenticator.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *containerAnnotations;
// A service that writes nothing of itself: every entity set refuses
// insert, update and delete (405), whatever its handler allows, as
// $metadata says. Actions still write: what one changes in the request
// context it is handed is saved, as in any service. Default: NO.
@property (nonatomic, getter=isReadOnly) BOOL readOnly;
// The model's configuration whose entities it serves: each root entity
// the configuration lists, with its sub-entities, which the configuration
// lists too. nil, the default: every entity that has a key. One not served
// has no entity set, type or handler, and nothing reaches it: a
// relationship to it is no property of the types that have it (see
// ODataPropertyMapper's servedEntityNames), so naming it anywhere -- a
// path, a query option, a body -- is an error as for any unknown name.
// A configuration that lists a sub-entity without its root, or a root
// without all its sub-entities, or that the model has not, is among
// metadataProblems. Set it before the first request.
@property (nonatomic, copy, nullable) NSString *configurationName;
// The version of the schema it serves (OData 4.01's schema versioning):
// $metadata says it (Core.SchemaVersion), and a client names the one it
// speaks in $schemaversion. Default: the model's versionIdentifiers
// (Xcode's Core Data Model Identifier), sorted and joined by commas; nil
// when it has none.
@property (nonatomic, copy, nullable) NSString *modelVersion;
// A write from a client on another version of the schema ($schemaversion
// other than modelVersion: offline devices that have not updated yet, and
// send what they changed all the same):
// the body as it came (OData JSON, the client's property names), the
// version the client named, the entity it writes; answered with the body
// as this model takes it (a renamed property under its new name, a new
// required one filled in), or nil and an error to refuse it (400 when the
// error says no status). Called for every write that names a version
// other than modelVersion; not for one that names none. Without it, such
// a request is answered 404, as one of a version the service does not
// have; with it, reads of that version are answered from the service's
// own schema (its changes, additions). As a data migration, but of one
// request. Set it before the first request.
@property (nonatomic, copy, nullable) NSDictionary *_Nullable (^upgradeBody)(NSDictionary *body, NSString *clientVersion,
                                                                              NSEntityDescription *_Nullable entity,
                                                                              ODataRequest *request, NSError **error);
// The object whose methods are the service's unbound operations; see
// ODataFunctions. Set it before the first request (after it, it is taken,
// and $metadata changes under clients that read it: logged).
@property (nonatomic, strong, nullable) id serviceOperations;
// The operations that could not be declared, one sentence each, naming the
// selector.
@property (nonatomic, readonly) NSArray<NSString *> *operationProblems;

- (void)setHandler:(ODataEntitySetHandler *)handler forEntitySet:(NSString *)entitySet;
- (nullable ODataEntitySetHandler *)handlerForEntitySet:(NSString *)entitySet;
@property (nonatomic, readonly) NSArray<NSString *> *entitySets;

// $metadata, in the CSDL of 4.0 or 4.01.
- (NSString *)metadataXMLForVersion:(NSString *)version;
// What $metadata had to leave out of the model, one sentence each.
@property (nonatomic, readonly) NSArray<NSString *> *metadataProblems;

// ODataTransport: answers the exchange's request. A request whose handlers
// answer at once is finished before this returns.
- (void)startExchange:(ODataExchange *)exchange;
// The same, for a host that has asked who is sending it already, with this
// service's authenticator (HTTPServerKit's authentication stage): the
// principal it found, nil for no one. The authenticator is not asked
// again; allowsAnonymousRequests and allowsAnonymousMetadata apply as ever.
- (void)startExchange:(ODataExchange *)exchange principal:(nullable HSPrincipal *)principal;

@end

NS_ASSUME_NONNULL_END

// The rest of the server library, for those who import it by this name.
#import <HTTPServerKit/HSAuthentication.h>
#import <ODataKit/ODataPredicateBuilder.h>
#import "ODataMetadataWriter.h"
