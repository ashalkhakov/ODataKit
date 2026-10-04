// ODataService — what the service's own files share, beyond its public
// interface: the call a request is answered by, and the types it uses.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "ODataService.h"
#import <HTTPServerKit/HSAuthentication.h>
#import <HTTPServerKit/HSLog.h>
#import <OTelKit/OTTrace.h>
#import <OTelKit/OTHTTP.h>
#import "ODataError.h"
#import "ODataValue.h"
#import "ODataSchema.h"
#import "ODataMetadataWriter.h"
#import <ODataKit/ODataPredicateBuilder.h>
#import "ODataOperationCatalog.h"
#import "ODataApply.h"
#import "ODataTimeline.h"

NS_ASSUME_NONNULL_BEGIN

@class OISServedOperation, OISPlan, OISPlanNode, OISRelation;

// What a permission lets the caller do to an entity set's rows: its
// handler's readScopes, insertScopes, updateScopes or deleteScopes.
typedef NS_ENUM(NSInteger, OISAccess) { OISAccessRead, OISAccessInsert, OISAccessUpdate, OISAccessDelete };

@interface ODataRequest ()
// Which entity a handler is asked about (a nested write's, while it answers).
@property (nonatomic, readwrite, strong, nullable) NSEntityDescription *entity;
@end

@interface ODataReply (Internal)
// The handler method has returned this: an answer now, unless it deferred.
- (void)returned:(nullable id)value;
@end

@interface ODataReply ()
@property (nonatomic, readwrite, strong, nullable) OTSpan *span;
@end

@interface ODataService ()
// History is pruned up to here (pruneHistoryBeforeDate:): a delta token
// issued before it may have lost changes. Kept in the store's metadata.
- (nullable NSDate *)historyPrunedBefore;
- (void)rememberAnswer:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body
                forKey:(NSString *)key signature:(nullable NSString *)signature;
- (void)prepare;
@property (nonatomic, strong) ODataPredicateBuilder *predicates;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ODataEntitySetHandler *> *handlers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *metadataByVersion;
@property (nonatomic, strong) ODataMetadataWriter *writer;
@property (nonatomic, strong) OISOperationCatalog *catalog;
// What configurationName could not say, one sentence each.
@property (nonatomic, copy) NSArray<NSString *> *configurationProblems;
@property (nonatomic) BOOL prepared;
- (ODataEntitySetHandler *)handlerForEntity:(NSEntityDescription *)entity;
- (BOOL)isComputedAttribute:(NSAttributeDescription *)attribute;
- (BOOL)isImmutableAttribute:(NSAttributeDescription *)attribute;
- (NSDictionary *)metadataContainerAnnotations;
- (NSString *)entitySetForEntity:(NSEntityDescription *)entity;
- (NSAttributeDescription *)versionAttributeOfEntity:(NSEntityDescription *)entity;
@end

static inline NSEntityDescription *OISRootEntity(NSEntityDescription *entity)
{
  while (entity.superentity) entity = entity.superentity;
  return entity;
}

typedef NS_ENUM(NSInteger, OISTargetKind) {
  OISTargetServiceDocument,
  OISTargetMetadata,
  OISTargetCollection,
  OISTargetEntity,
  OISTargetProperty,
  OISTargetValue,
  OISTargetCount,
  OISTargetOperation,
  OISTargetReference,
  OISTargetStream,  // a media resource (Entity/$value) or stream property: `attribute` holds it
  OISTargetEach     // Collection/$each: each member, written alike
};

@interface OISStoreGrouping : NSObject
@property (nonatomic, strong) ODataApplyTransformation *transformation;
@property (nonatomic, strong) NSFetchRequest *fetch;
@property (nonatomic, copy) NSArray<NSString *> *keyPaths;
@property (nonatomic, copy) NSArray *groupAttributes;
@property (nonatomic, copy) NSDictionary *aggregateAttributes;
// By alias: how each aggregate is read from a fetched row.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *methods;  // count, sum, decimalSum, average, exactAverage, value
- (NSArray<NSDictionary *> *)groupsOfRows:(NSArray<NSDictionary *> *)rows;
@end

@interface OISHierarchy : NSObject
@property (nonatomic, strong) NSEntityDescription *entity;
@property (nonatomic, copy) NSString *qualifier;
@property (nonatomic, copy) NSString *nodeKeyPath;   // q, as a Core Data key path
@property (nonatomic, copy) NSString *parentKey;     // the parent relationship's name
@property (nonatomic) BOOL parentsAreMany;
@property (nonatomic, strong) NSMutableArray *nodes;  // identifiers, in key order
@property (nonatomic, strong) NSMutableDictionary<id<NSCopying>, NSManagedObject *> *objects;
@property (nonatomic, strong) NSMutableDictionary<id<NSCopying>, NSArray *> *parents;
@property (nonatomic, strong) NSMutableDictionary<id<NSCopying>, NSMutableArray *> *children;
- (void)readObjects:(NSArray<NSManagedObject *> *)objects;
- (NSArray *)roots;
- (NSArray *)leaves;
// Within distance (0: any), and the node itself where includeSelf.
- (NSArray *)ancestorsOf:(id)node distance:(NSInteger)distance includeSelf:(BOOL)includeSelf;
- (NSArray *)descendantsOf:(id)node distance:(NSInteger)distance includeSelf:(BOOL)includeSelf;
- (NSArray *)siblingsOf:(id)node;
@end

@interface OISServiceCall : NSObject
// A repeatable request's: where its answer is remembered, and what it was.
@property (nonatomic, copy, nullable) NSString *repeatabilityKey;
@property (nonatomic, copy, nullable) NSString *repeatabilitySignature;
@property (nonatomic, strong) ODataService *service;
@property (nonatomic, strong) ODataExchange *exchange;
@property (nonatomic, strong) ODataRequest *request;
@property (nonatomic, strong) ODataValueCoder *coder;
@property (nonatomic, copy) NSString *metadataLevel;  // minimal, full, none
@property (nonatomic, copy) NSString *resourcePath;   // as the request wrote it, decoded
@property (nonatomic) BOOL headOnly;
@property (nonatomic) BOOL done;

// Where the path leads.
@property (nonatomic) OISTargetKind kind;
@property (nonatomic) NSUInteger index;
@property (nonatomic, strong) NSEntityDescription *entity;
@property (nonatomic, strong) ODataEntitySetHandler *handler;
@property (nonatomic, strong, nullable) NSManagedObject *object;
@property (nonatomic, strong, nullable) NSManagedObject *parent;
@property (nonatomic, strong, nullable) NSRelationshipDescription *navigation;
@property (nonatomic, strong, nullable) NSAttributeDescription *attribute;
@property (nonatomic, strong, nullable) OISServedOperation *operation;
// How the entity in hand was reached, when through a navigation property:
// what $ref after it refers to.
@property (nonatomic, strong, nullable) NSManagedObject *referrer;
@property (nonatomic, strong, nullable) NSRelationshipDescription *referrerNavigation;
// $id: the entity a DELETE of a collection's $ref removes.
@property (nonatomic, copy, nullable) NSString *referenceID;
@property (nonatomic) BOOL referencesCollection;  // Categories(1)/Products/$ref, Products/$ref
@property (nonatomic) BOOL referencesOnly;        // a collection read as references
// The entities a function returned, read on as a collection.
@property (nonatomic, copy, nullable) NSArray<NSManagedObject *> *members;
// A deep insert's response: the entity with what it created expanded.
@property (nonatomic, strong, nullable) ODataQueryOptions *responseOptions;
// The request's body, parsed once.
@property (nonatomic, strong, nullable) NSDictionary *parsedBody;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, ODataExpression *> *operationArguments;
// Parameter aliases whose values are JSON (@p=[...], @p={...}): an
// operation's complex and collection arguments.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *JSONAliases;

// $metadata in CSDL JSON rather than XML.
@property (nonatomic) BOOL metadataAsJSON;
// A collection read: its page of rows, their count, the next page, and how
// the pages are cut.
@property (nonatomic, strong, nullable) NSArray *objects;
@property (nonatomic, strong, nullable) NSNumber *count;
@property (nonatomic, copy, nullable) NSString *nextLink;
@property (nonatomic) NSUInteger pageSize;
@property (nonatomic) NSUInteger skipToken;
@property (nonatomic) BOOL pagedByPreference;
// The recursive hierarchies the request names, read once ($root/Set#Q), and
// what each hierarchy function in it stands for (Node in (...)), by the
// call's description.
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, OISHierarchy *> *hierarchies;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, ODataExpression *> *hierarchyCalls;
// $filter(...) segments of the path: the collection's members that pass.
@property (nonatomic, strong, nullable) NSMutableArray<ODataExpression *> *pathFilters;
// $compute's values' expressions, by entity and name.
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSExpression *> *computedExpressions;
// Change tracking: the $deltatoken asked about, and the token a delta link
// in the response carries (the history as it stood when the read began).
@property (nonatomic, copy, nullable) NSString *deltaToken;
@property (nonatomic, copy, nullable) NSString *trackingToken;
// The version of the schema the client named ($schemaversion), when not
// the service's own: what it writes goes through upgradeBody.
@property (nonatomic, copy, nullable) NSString *schemaVersion;
@property (nonatomic, copy, nullable) NSArray<NSManagedObjectID *> *deltaChanged;
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *deltaDeleted;

// The read's plan (OISServiceCall+Plan.m), and where it has got to: what
// is known, by operator; what the handler is being asked; the rows; the
// values of the store scan's bindings ($compute's, when rows are written);
// the members of each expansion, by expand item (identity), relationship
// and parent's object ID.
@property (nonatomic, strong, nullable) OISPlan *plan;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, id> *planMemo;
@property (nonatomic) SEL planAfter;
@property (nonatomic, copy, nullable) NSString *planPendingKey;
@property (nonatomic) BOOL planPending;
@property (nonatomic) BOOL planWaiting;
@property (nonatomic, strong, nullable) OISRelation *planResult;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *planValues;
// The spans of the dates month() and the rest range over, as the plan read them.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSArray *> *planSpans;
@property (nonatomic, strong, nullable) NSMapTable *nestResults;
// The dynamic properties of the open types' entities written, by object ID.
@property (nonatomic, copy, nullable) NSDictionary<NSManagedObjectID *, NSDictionary<NSString *, id> *> *planDynamic;
@property (nonatomic, strong, nullable) NSMutableSet<NSString *> *nestVisited;
// GET <root>/$explain/...: the plan is the answer.
@property (nonatomic) BOOL explaining;
// The options entities are written with ($apply's expand() in $expand).
@property (nonatomic, strong, nullable) ODataQueryOptions *writtenOptions;
// A delta's entries for what no longer matches the read.
@property (nonatomic, copy, nullable) NSArray *deltaRemoved;
// A response of entities, while the plan reads their expansions: the
// entity, its status and headers; an operation's reply, to go on with;
// a temporal action's slices.
@property (nonatomic, strong, nullable) NSManagedObject *writtenObject;
@property (nonatomic) NSInteger writtenStatus;
@property (nonatomic, copy, nullable) NSDictionary *writtenHeaders;
@property (nonatomic, strong, nullable) ODataReply *resumeReply;
@property (nonatomic, copy, nullable) NSArray *timeslices;

// A write's plan as it is made (its sequences, by "Entity.attribute"); the
// request's entity, which a handler asked has while it answers; what the
// write answers with: a node's rows, or, for a collection, nodes' rows and
// removed entries ({node, reason}).
@property (nonatomic, strong, nullable) OISPlan *writing;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, OISPlanNode *> *writeSequences;
@property (nonatomic, strong, nullable) NSEntityDescription *writeRequestEntity;
@property (nonatomic, strong, nullable) OISPlanNode *writeAnswer;
@property (nonatomic, copy, nullable) NSArray *writeAnswers;
// An operation's parameters, with Lookups for its entities until read.
@property (nonatomic, copy, nullable) NSArray *operationValuesPlanned;
// The key the path's last entity was looked up by (Core Data attribute
// names): an upsert's, when it names none.
@property (nonatomic, copy, nullable) NSDictionary *lookedUpKey;
// NO in a change set: its requests share a context, saved once they have
// all succeeded.
@property (nonatomic) BOOL saves;
// Who is asking is known: the authenticator has answered, or a batch
// the request is part of has been authenticated.
@property (nonatomic) BOOL authenticated;
// Who is asking was found by the host (-startExchange:principal:): the
// request's principal, admitted as the authenticator's answer would be.
@property (nonatomic) BOOL principalGiven;
// The request as its authenticator was asked about it (its challenge is for
// that one), and whether it is being asked now.
@property (nonatomic, strong, nullable) HSRequest *authenticationRequest;
@property (nonatomic) BOOL authenticating;

// What its work took (OISServiceCall+Tracing.m): the call's span, under
// the traceparent it came with; the execution's, once planned; the store
// request's under way. Times in nanoseconds (OTNow()): when what is being
// planned began (once admitted, or when the last execution ended), when
// execution began, when the store was asked.
@property (nonatomic, strong, nullable) OTSpan *span;
@property (nonatomic, strong, nullable) OTSpan *executeSpan;
@property (nonatomic, strong, nullable) OTSpan *storeSpan;
@property (nonatomic, strong, nullable) OTSpan *callSpan;
@property (nonatomic, copy, nullable) NSString *storeOperation;
@property (nonatomic, copy, nullable) NSString *storeEntity;
@property (nonatomic) uint64_t phaseStarted;
@property (nonatomic) uint64_t executeStarted;
@property (nonatomic) uint64_t storeStarted;
@end

@interface OISServiceCall (Tracing)
// The plan made: planning timed (a "plan" span, its tree an attribute),
// execution begun.
- (void)tracePlanned:(OISPlan *)plan;
- (void)traceExecuted;
// A handler asked (fetch, count, aggregate, changes, write): timed, and a
// span, current on this thread while it asks; ended by its answer.
- (void)beginStoreRequest:(NSString *)operation entity:(nullable NSString *)entity handler:(nullable ODataEntitySetHandler *)handler;
- (void)endStoreRequest:(nullable id)result error:(nullable NSError *)error;
// An operation's own code called: a span ("call Name"), current on this
// thread while it runs, so what it does -- the store, an engine of its
// own that traces -- goes under it; ended by its reply, and for an action
// once its changes are saved (the save's span under it too).
- (void)beginOperationCall:(OISServedOperation *)operation target:(id)target;
- (void)endOperationCall:(nullable NSError *)error;
// The response made: what is under way ended, the call's span with it.
- (void)traceRespondedWithStatus:(NSInteger)status;
@end

// db.system.name for a coordinator's store: sqlite, postgresql, mysql,
// coredata.
FOUNDATION_EXPORT NSString *OISStoreSystemName(NSPersistentStoreCoordinator *coordinator);
// context saved, timed (odata_store_request_duration_seconds, operation
// save), a span under parent.
FOUNDATION_EXPORT BOOL OISTimedSave(ODataService *service, NSManagedObjectContext *context, OTSpan *_Nullable parent,
                                    NSString *_Nullable entity, NSError **error);
// A line for the shared HSLog, with the request id and trace of a
// request's headers.
FOUNDATION_EXPORT void OISLog(HSLogLevel level, NSURLRequest *_Nullable request, NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

@interface OISComputedRow : NSObject
@property (nonatomic, strong) NSManagedObject *object;
@property (nonatomic, strong) NSMutableDictionary *computed;
@end

// The call's own machinery, which the plan uses.
@interface OISServiceCall (Machinery)
- (ODataPropertyMapper *)mapper;
// The service's predicate builder, this request its userInfo.
- (ODataPredicateBuilder *)predicates;
- (ODataReply *)replyWithAction:(SEL)action;
- (void)respondJSON:(id)json status:(NSInteger)status headers:(nullable NSDictionary *)headers;
- (void)respondError:(NSError *)error;
- (void)fail:(NSInteger)status message:(NSString *)message;
// Whether the caller has one of the scopes (none needed: YES); answered 403
// when it has none, for what it asked to do (401 when no one asks), the
// challenge naming them.
- (BOOL)permits:(nullable NSSet<NSString *> *)scopes to:(NSString *)what;
// The same, not answered.
- (BOOL)holds:(nullable NSSet<NSString *> *)scopes;
// Whether it has one of each permission's scopes, by what each permits:
// answered for the first it lacks, in order.
- (BOOL)permitsAll:(NSDictionary<NSString *, NSSet<NSString *> *> *)permissions;
// An operation's: its call, and the read of what it answers with.
- (NSDictionary<NSString *, NSSet<NSString *> *> *)permissionsOfOperation;
- (NSString *)canonicalPathOf:(NSManagedObject *)object;
- (NSPredicate *)predicateForObjects:(NSArray<NSManagedObject *> *)objects;
- (nullable NSPredicate *)membersOfNavigation;
- (nullable NSPredicate *)collectionPredicateWithFilter:(BOOL)withFilter error:(NSError **)error;
- (nullable NSPredicate *)predicateForSearch:(ODataSearchExpression *)search entity:(NSEntityDescription *)entity;
- (nullable id)predicateForApplicationTimeOf:(ODataQueryOptions *)options entity:(NSEntityDescription *)entity error:(NSError **)error;
- (BOOL)applyIsFiltersOnly;
- (BOOL)canTrackChanges;
- (BOOL)withinRowsInMemory:(NSUInteger)count;
- (NSDictionary<NSString *, ODataExpression *> *)computedNamesOf:(ODataQueryOptions *)options;
- (nullable OISStoreGrouping *)storeGroupingOf:(ODataApplyTransformation *)t predicate:(NSPredicate *)predicate;
- (NSArray *)rowsOfGroups:(NSArray<NSDictionary *> *)raw grouping:(ODataApplyTransformation *)t keyPaths:(NSArray *)keyPaths
          groupAttributes:(NSArray *)groupAttributes aggregateAttributes:(NSDictionary *)aggregateAttributes;
- (BOOL)applyTransformations:(NSArray<ODataApplyTransformation *> *)transformations rows:(NSArray * _Nonnull * _Nonnull)rowsp
                       shape:(NSMutableArray * _Nullable * _Nonnull)shapep computed:(NSMutableDictionary *)computed expansions:(NSMutableArray *)expansions;
- (nullable NSDictionary *)valuesOf:(NSArray<ODataExpression *> *)asked over:(NSArray *)rows shape:(nullable NSArray *)shape computed:(NSDictionary *)computed;
- (nullable ODataExpression *)hierarchical:(nullable ODataExpression *)e;
- (NSArray<ODataOrderItem *> *)resolvedOrder:(NSArray<ODataOrderItem *> *)items options:(ODataQueryOptions *)options;
- (BOOL)resolveHierarchyCalls;
- (nullable OISHierarchy *)describedHierarchyOf:(NSArray<NSString *> *)setPath qualifier:(NSString *)qualifier
                                          fetch:(NSFetchRequest * _Nullable * _Nullable)fetchp handler:(ODataEntitySetHandler * _Nullable * _Nullable)handlerp;
- (BOOL)takeChanges:(ODataChanges *)changes;
// A token as links carry it, with the caller's scope version; and back,
// nil (answered 410) when the version is not the caller's now.
- (NSString *)scopedToken:(NSString *)token;
- (nullable NSString *)tokenCheckingScope:(NSString *)link;
- (NSDictionary *)removedEntry:(NSString *)path reason:(NSString *)reason;
// For writes.
- (nullable NSDictionary *)bodyJSON;
- (void)methodNotAllowed:(NSArray<NSString *> *)allowed;
- (void)respondStatus:(NSInteger)status headers:(nullable NSDictionary *)headers body:(nullable NSData *)body;
- (NSString *)rootString;
- (NSString *)contextBase;
- (NSString *)setName;
- (NSString *)castSuffixFor:(NSEntityDescription *)entity;
- (NSString *)selectListForOptions:(ODataQueryOptions *)options;
- (NSString *)etagOf:(NSManagedObject *)object;
- (NSString *)mediaEtagOf:(NSData *)data;
- (nullable NSString *)canonicalPathOfValues:(id)values entity:(NSEntityDescription *)entity;
- (nullable NSEntityDescription *)entityForTypeName:(NSString *)name;
- (nullable NSDictionary *)keyFromPartsQuietly:(NSDictionary *)parts entity:(NSEntityDescription *)entity;
- (nullable ODataExpression *)literalForKeySegment:(NSString *)text;
- (NSArray<ODataExpandItem *> *)expansionOfBody:(NSDictionary *)body entity:(NSEntityDescription *)entity;
- (NSArray<NSAttributeDescription *> *)servedAttributesOf:(NSEntityDescription *)entity;
- (nullable NSMutableDictionary *)JSONForObject:(NSManagedObject *)object options:(ODataQueryOptions *)options
                                       expected:(nullable NSEntityDescription *)expected error:(NSError **)error;
- (void)writeEntity:(NSManagedObject *)object status:(NSInteger)status headers:(nullable NSDictionary *)headers;
- (BOOL)save;
@end

// What the plan asks a handler for.
typedef NS_ENUM(NSInteger, OISStoreAsk) { OISAskObjects, OISAskCount, OISAskGrouped, OISAskChanges };

// The plan (OISServiceCall+Plan.m).
@interface OISServiceCall (Plan)
- (nullable NSArray<NSPredicate *> *)fixedPredicatesSummary:(NSString * _Nullable * _Nullable)summary error:(NSError **)error;
// A store's answer: known, or asked for (nil until it comes, or once it
// failed), kept under key.
- (nullable id)answerFor:(NSString *)key ask:(OISStoreAsk)ask fetch:(NSFetchRequest *)fetch handler:(nullable ODataEntitySetHandler *)handler;
- (nullable OISRelation *)relationOf:(OISPlanNode *)node scope:(nullable NSString *)scope input:(nullable OISRelation *)input;
- (void)respondExplaining:(OISPlan *)plan;
- (nullable OISPlan *)planPlainRead;
- (nullable OISPlan *)planAppliedRead;
- (nullable OISPlan *)planCountRead;
- (OISPlan *)planDelta;
- (OISPlan *)planOfObjects:(NSArray *)objects options:(ODataQueryOptions *)options entity:(nullable NSEntityDescription *)entity;
// Plans are run from the top, again when a handler answers later; then
// after, with planResult set.
- (void)runPlan:(OISPlan *)plan then:(SEL)after;
// Permissions (each by what it permits, its scopes): the one to do access
// to the entity's set, added to permissions when its handler asks for
// one; whether the caller has it. What a read reaches: an expression over
// entity, query options over it, a plan's nodes.
- (void)need:(OISAccess)access entity:(nullable NSEntityDescription *)entity into:(NSMutableDictionary *)permissions;
- (BOOL)permitsTo:(OISAccess)access entity:(nullable NSEntityDescription *)entity;
- (void)readExpression:(nullable ODataExpression *)e entity:(NSEntityDescription *)entity into:(NSMutableDictionary *)permissions;
- (void)readOptions:(nullable ODataQueryOptions *)options entity:(nullable NSEntityDescription *)entity into:(NSMutableDictionary *)permissions;
- (void)addReadsOf:(OISPlan *)plan into:(NSMutableDictionary *)permissions;
// The parents' members of a to-many relationship, as the store selects
// them (with the predicate and sort), read through the handler for them
// all, by parent object ID: under key, what the plan knows; nil until
// known (planPending), or once answered with the error.
- (nullable NSDictionary<NSManagedObjectID *, NSArray *> *)membersOf:(NSArray<NSManagedObject *> *)parents
                                                        relationship:(NSRelationshipDescription *)relationship
                                                           predicate:(nullable NSPredicate *)predicate
                                                                sort:(NSArray<NSSortDescriptor *> *)sort key:(NSString *)key;
- (void)planDidReply:(ODataReply *)reply;
// An expansion's members of a parent, as the plan read them:
// @{ members: its page, count: all of them }; nil when it has none.
- (nullable NSDictionary *)nestedMembersOf:(ODataExpandItem *)item relationship:(NSString *)name parent:(NSManagedObject *)parent;
@end

// Writes (OISServiceCall+Write.m): planned, then run as plans are.
@interface OISServiceCall (Write)
- (void)insert;
// The same with the key an upsert's URL gives: the body may repeat it, not
// contradict it.
- (void)insertWithKey:(nullable NSDictionary *)key;
- (nullable NSString *)ifMatchHeader;
- (void)insertMedia:(NSEntityDescription *)entity media:(NSAttributeDescription *)media;
- (void)updateReplacing:(BOOL)replace;
- (void)remove;
- (void)writeReference;
- (void)writeProperty;
- (void)writeStream;
- (void)temporalAction:(NSString *)action;
- (void)updateCollection;
- (void)replaceCollection;
- (void)updateEach;
- (void)removeEach;
// An operation's entity parameters, read, then after (the call is the
// operation's own code); for explain, the plan.
- (void)readLookups:(NSArray<OISPlanNode *> *)lookups call:(NSString *)signature then:(SEL)after;
- (nullable OISPlanNode *)lookupOfReference:(id)reference error:(NSError **)error;
- (nullable id)resultOf:(OISPlanNode *)node;
- (void)resumeWrite;
// What a write's nodes write that asks for a permission, as far as is
// known before anything is read: not a Merge's branches, nor a Temporal
// action's slices, which are checked once known.
- (void)addWritesOf:(OISPlanNode *)node into:(NSMutableDictionary *)permissions;
@end

NSArray<ODataExpression *> *OISTheseOfFilter(ODataQueryOptions *options);
NSArray<ODataExpression *> *OISTheseOfOrder(ODataQueryOptions *options);
NSString * _Nullable OISHierarchyFunction(NSString *name);
void OISAddExpressionsOfOptions(ODataQueryOptions * _Nullable options, NSMutableArray *into);
void OISAddExpressionsOfTransformations(NSArray<ODataApplyTransformation *> * _Nullable transformations, NSMutableArray *into);
// Options with some of their values in: $filter's and $compute's, and
// $orderby's ($these, by the description of what each stands for).
ODataQueryOptions *OISOptionsReplacing(ODataQueryOptions *options, NSDictionary * _Nullable filterValues, NSDictionary * _Nullable orderValues);

NS_ASSUME_NONNULL_END
