// ODataIncrementalStore
// Copyright (C) 2026 OIS contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <ODataKit/ODataApply.h>
#import "ODataIncrementalStore+Private.h"
#import <OTelKit/OTTrace.h>

// One object's share of a save: the entity body, the $ref requests for
// to-many changes a body cannot carry, and the relationships that had to
// wait because their targets were not saved yet.
@interface OISWrite : NSObject
@property (nonatomic, strong) NSMutableDictionary *body;
@property (nonatomic, strong) NSMutableArray *references;  // @[ method, NSURL, body or NSNull ]
@property (nonatomic, strong) NSMutableSet *deferred;      // relationship names
@end

@implementation OISWrite
- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _body = [NSMutableDictionary dictionary];
  _references = [NSMutableArray array];
  _deferred = [NSMutableSet set];
  return self;
}
@end

// One request of a save and what to do with its response. A save is a
// list of these, sent as one $batch change set or one at a time.
@interface OISOperation : NSObject
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSManagedObjectID *objectID;  // what it writes, for its messages
@property (nonatomic, copy) BOOL (^completion)(ODataHTTPResponse *response, NSError **error);
@end

@implementation OISOperation
@end

typedef NS_ENUM(NSInteger, OISWriteMode) {
  OISWriteInsert,    // every set attribute, keys the client chose, every relationship
  OISWriteUpdate,    // what changed since the last save
  OISWriteDeferred   // only the relationships an insert had to leave out
};

// What -fetchRemoteChanges: knows of one entity set: its rows as last
// read (object ID -> row; NSNull for one this store wrote since, whose row
// it has not seen), and the delta link to read the next changes from,
// where the service gave one.
@interface OISTracking : NSObject
@property (nonatomic, strong) NSMutableDictionary *rows;
@property (nonatomic, strong, nullable) NSURL *deltaLink;
@end

@implementation OISTracking
@end

// A batch update's or delete's result: what the store found, as the
// request's result type asks.
@interface OISBatchUpdateResult : NSBatchUpdateResult
@property (nonatomic, strong) id storeResult;
@property (nonatomic) NSBatchUpdateRequestResultType storeResultType;
@end

@implementation OISBatchUpdateResult
- (id)result
{
  return self.storeResult;
}
- (NSBatchUpdateRequestResultType)resultType
{
  return self.storeResultType;
}
@end

@interface OISBatchDeleteResult : NSBatchDeleteResult
@property (nonatomic, strong) id storeResult;
@property (nonatomic) NSBatchDeleteRequestResultType storeResultType;
@end

@implementation OISBatchDeleteResult
- (id)result
{
  return self.storeResult;
}
- (NSBatchDeleteRequestResultType)resultType
{
  return self.storeResultType;
}
@end

@implementation ODataIncrementalStore {
  ODataClient *_client;
  ODataPropertyMapper *_mapper;
  ODataQueryBuilder *_builder;
  NSMutableDictionary *_nodeCache;
  NSMutableDictionary *_etags;      // object ID -> ETag, exactly as the service sent it
  NSMutableDictionary *_versions;   // object ID -> node version, bumped when the ETag changes
  NSMutableDictionary *_deferred;   // object ID -> relationship names to write after insert
  NSMutableDictionary *_editLinks;  // object ID -> @odata.editLink, where the service gave one
  NSMutableDictionary *_members;    // object ID -> to-many name -> member IDs, from an $expand
  NSMutableDictionary *_streams;    // object ID -> stream name (@"" media) -> what its row said of it
  NSMutableDictionary *_streamFiles; // object ID -> stream name -> @{ file, etag, type } downloaded
  BOOL _batchRefused;               // the service answered $batch itself with an error
  NSLock *_lock;
  ODataHistoryLog *_history;        // with NSPersistentHistoryTrackingKey
  NSMutableDictionary *_tracking;   // entity name -> OISTracking, for -fetchRemoteChanges:
  NSMutableDictionary *_kept;       // object ID -> property name -> what the service does not serve (OData.served NO), as saved
}

+ (NSString *)storeType
{
  return ODataIncrementalStoreType;
}

+ (void)registerStore
{
  [NSPersistentStoreCoordinator registerStoreClass:self forStoreType:[self storeType]];
}

+ (ODataSchema *)schemaForServiceAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error
{
  ODataConfiguration *configuration = [[ODataConfiguration alloc] initWithURL:url options:options];
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  id transport = options[ODataIncrementalStoreTransportOption];
  if ([transport respondsToSelector:@selector(startExchange:)]) client.transport = transport;
  NSData *metadata = [client metadataWithError:error];
  return metadata ? [ODataSchema schemaWithData:metadata error:error] : nil;
}

+ (NSManagedObjectModel *)modelForServiceAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error
{
  ODataSchema *schema = [self schemaForServiceAtURL:url options:options error:error];
  return schema ? [ODataModelBuilder modelWithSchema:schema] : nil;
}

+ (NSDictionary *)metadataForSchema:(ODataSchema *)schema
{
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  // NSStoreModelVersionHashesVersion is in every store's metadata Core
  // Data writes, though not in its headers; without it, Apple's
  // -isConfiguration:compatibleWithStoreMetadata: takes any model for a
  // match. FreeCoreData compares the hashes either way.
  return @{
    NSStoreTypeKey: [self storeType],
    NSStoreModelVersionHashesKey: model.entityVersionHashesByName,
    NSStoreModelVersionIdentifiersKey: model.versionIdentifiers.allObjects,
    @"NSStoreModelVersionHashesVersion": @3,
  };
}

+ (NSDictionary *)metadataForServiceAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error
{
  ODataSchema *schema = [self schemaForServiceAtURL:url options:options error:error];
  return schema ? [self metadataForSchema:schema] : nil;
}

- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                                 configurationName:(NSString *)name
                                               URL:(NSURL *)url
                                           options:(NSDictionary *)options
{
  self = [super initWithPersistentStoreCoordinator:root configurationName:name URL:url options:options];
  if (!self) return nil;
  _nodeCache = [NSMutableDictionary dictionary];
  _members = [NSMutableDictionary dictionary];
  _streams = [NSMutableDictionary dictionary];
  _streamFiles = [NSMutableDictionary dictionary];
  _etags = [NSMutableDictionary dictionary];
  _versions = [NSMutableDictionary dictionary];
  _deferred = [NSMutableDictionary dictionary];
  _editLinks = [NSMutableDictionary dictionary];
  _metadataProblems = @[];
  _lock = [[NSLock alloc] init];
  _tracking = [NSMutableDictionary dictionary];
  return self;
}

- (BOOL)loadMetadata:(NSError **)error
{
  NSURL *url = self.URL;
  if (!url) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingServiceURL, @"The store URL must be the OData service root.");
    return NO;
  }
  ODataConfiguration *configuration = [[ODataConfiguration alloc] initWithURL:url options:self.options];
  _client = [[ODataClient alloc] initWithConfiguration:configuration];
  id transport = self.options[ODataIncrementalStoreTransportOption];
  if ([transport respondsToSelector:@selector(startExchange:)]) {
    _client.transport = transport;
  }
  _mapper = [[ODataPropertyMapper alloc] init];
  _mapper.naming = configuration.naming;
  _mapper.values.IEEE754Compatible = configuration.IEEE754Compatible;
  _builder = [[ODataQueryBuilder alloc] initWithMapper:_mapper serviceRoot:configuration.serviceRoot];
  // `category == %@` compares keys, which only this store can read out of
  // one of its object IDs.
  __weak ODataIncrementalStore *weakSelf = self;
  _builder.keysForObjectID = ^NSDictionary *(NSManagedObjectID *objectID) {
    ODataIncrementalStore *store = weakSelf;
    if (!store || objectID.persistentStore != store) return nil;
    return [ODataResourceIdentifier identifierFromReference:[store referenceObjectForObjectID:objectID]].keys;
  };
  NSData *metadata = [_client metadataWithError:error];
  if (!metadata) return NO;
  // The schema, where it can be read, fills in what the model leaves
  // unsaid; what does not match is reported, and fails the open only when
  // asked to. A schema that cannot be read is a problem, not a failure.
  NSError *schemaError = nil;
  _schema = [ODataSchema schemaWithData:metadata error:&schemaError];
  _mapper.schema = _schema;
  configuration.authorizations = _schema.authorizations;
  id keyAsSegment = self.options[ODataIncrementalStoreKeyAsSegmentOption];
  _builder.keyAsSegment = keyAsSegment ? [keyAsSegment boolValue] : _schema.keyAsSegmentSupported;
  // A 4.0 service rejects 4.01 syntax (Northwind and TripPin answer `in`
  // with 400 and 500), so requests are written in the version it speaks.
  configuration.version = [configuration versionForService:_schema.version];
  configuration.JSONBatch = configuration.JSONBatchAllowed && [configuration.version isEqualToString:@"4.01"];
  id repeatable = _schema.containerName ? [_schema annotation:@"Repeatability.Supported" forTarget:_schema.containerName] : nil;
  configuration.repeatable = [repeatable isEqual:@YES];
  _builder.version = configuration.version;
  NSManagedObjectModel *model = self.persistentStoreCoordinator.managedObjectModel;
  _metadataProblems = _schema ? [_mapper problemsWithModel:model configuration:self.configurationName] : @[ schemaError.localizedDescription ?: @"$metadata could not be read" ];
  if (_metadataProblems.count && [self.options[ODataIncrementalStoreRequireMatchingModelOption] boolValue]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorModelMismatch,
                                 [@"The model does not match the service's $metadata: " stringByAppendingString:[_metadataProblems componentsJoinedByString:@"; "]]);
    return NO;
  }
  NSString *uuid = [NSIncrementalStore identifierForNewStoreAtURL:url];
  if (![uuid isKindOfClass:[NSString class]]) uuid = [[NSUUID UUID] UUIDString];
  NSMutableDictionary *storeMetadata = [@{ NSStoreUUIDKey: uuid, NSStoreTypeKey: [[self class] storeType] } mutableCopy];

  // A model generated from a schema is a version of the service's model,
  // and is checked as Core Data checks a model against any store: by the
  // version hashes of the model the service's schema describes now.
  NSString *modelVersion = [ODataModelBuilder versionIdentifierOfModel:model];
  if (modelVersion && _schema) {
    [storeMetadata addEntriesFromDictionary:[[self class] metadataForSchema:_schema]];
    storeMetadata[NSStoreUUIDKey] = uuid;
    if (![model isConfiguration:self.configurationName compatibleWithStoreMetadata:storeMetadata]) {
      NSString *serviceVersion = [ODataModelBuilder versionIdentifierForSchema:_schema];
      NSString *message = [NSString stringWithFormat:@"The service's schema has changed since the model was generated: the model is %@, the service %@. "
                                                     @"Generate a new model version from its $metadata.", modelVersion, serviceVersion];
      if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPersistentStoreIncompatibleVersionHashError
                                          userInfo:@{ NSLocalizedDescriptionKey: message, NSURLErrorKey: url }];
      return NO;
    }
  }
  self.metadata = storeMetadata;
  if ([self.options[NSPersistentHistoryTrackingKey] boolValue]) _history = [[ODataHistoryLog alloc] initWithStoreID:uuid];
  return YES;
}

// Each request a span, current while it runs (its wire requests go under
// it): fetch Product, count Product, save, ...
- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError **)error
{
  NSString *operation = @"request", *entity = nil;
  if ([request isKindOfClass:[NSFetchRequest class]]) {
    NSFetchRequest *fetch = (NSFetchRequest *)request;
    operation = fetch.resultType == NSCountResultType ? @"count" : @"fetch";
    entity = fetch.entityName ?: fetch.entity.name;
  } else if (request.requestType == NSSaveRequestType) {
    operation = @"save";
  } else if ([request isKindOfClass:[NSBatchUpdateRequest class]]) {
    operation = @"update";
    entity = [(NSBatchUpdateRequest *)request entityName];
  } else if ([request isKindOfClass:[NSBatchDeleteRequest class]]) {
    operation = @"delete";
    entity = [(NSBatchDeleteRequest *)request fetchRequest].entityName;
  }
  NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObject:operation forKey:@"db.operation.name"];
  attributes[@"db.system.name"] = @"odata";
  attributes[@"db.collection.name"] = entity;
  attributes[@"server.address"] = _client.configuration.serviceRoot.host;
  OTSpan *span = [_client.tracer startSpanNamed:entity ? [NSString stringWithFormat:@"%@ %@", operation, entity] : operation
                                     attributes:attributes];
  NSError *failure = nil;
  id result = [self performRequest:request withContext:context error:&failure];
  if (!result) [span recordError:failure];
  if ([result isKindOfClass:[NSArray class]]) [span setAttribute:@([(NSArray *)result count]) forKey:@"db.response.returned_rows"];
  [span end];
  if (error) *error = failure;
  return result;
}

- (id)performRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError **)error
{
  if (request.requestType == NSFetchRequestType) {
    if (![request isKindOfClass:[NSFetchRequest class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, @"Expected NSFetchRequest");
      return nil;
    }
    return [self executeFetch:(NSFetchRequest *)request context:context error:error];
  }
  if (request.requestType == NSSaveRequestType) {
    if (![request isKindOfClass:[NSSaveChangesRequest class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, @"Expected NSSaveChangesRequest");
      return nil;
    }
    // A save may move members from one collection to another.
    [_lock lock];
    [_members removeAllObjects];
    NSDictionary *kept = [[NSDictionary alloc] initWithDictionary:_kept ?: @{} copyItems:YES];
    [_lock unlock];
    [self keepWhatIsNotServedOf:(NSSaveChangesRequest *)request];
    id saved = [self executeSave:(NSSaveChangesRequest *)request error:error];
    if (!saved) {
      [_lock lock];
      _kept = [kept mutableCopy];
      [_lock unlock];
    }
    return saved;
  }
  if (request.requestType == NSBatchUpdateRequestType && [request isKindOfClass:[NSBatchUpdateRequest class]]) {
    return [self executeBatchUpdate:(NSBatchUpdateRequest *)request context:context error:error];
  }
  if (request.requestType == NSBatchDeleteRequestType && [request isKindOfClass:[NSBatchDeleteRequest class]]) {
    return [self executeBatchDelete:(NSBatchDeleteRequest *)request context:context error:error];
  }
  if ([request isKindOfClass:[NSPersistentHistoryChangeRequest class]]) {
    if (!_history) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                   @"Persistent history tracking is not enabled on this store (NSPersistentHistoryTrackingKey).");
      return nil;
    }
    return [_history resultForRequest:(NSPersistentHistoryChangeRequest *)request error:error];
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, @"Unsupported NSPersistentStoreRequest");
  return nil;
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError **)error
{
  (void)context;
  [_lock lock];
  NSIncrementalStoreNode *cached = _nodeCache[objectID];
  [_lock unlock];
  if (cached) return cached;

  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:error];
  if (!identifier) return nil;
  NSURL *url = [_builder URLForReadingIdentifier:identifier entity:objectID.entity error:error];
  if (!url) return nil;
  id json = [_client JSONAtURL:url error:error];
  if (!json) return nil;
  if (![json isKindOfClass:[NSDictionary class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Expected entity for %@", identifier.path]);
    return nil;
  }
  return [self cacheNodeForObjectID:objectID entity:objectID.entity payload:json error:error];
}

// What a save gives properties the service does not serve (OData.served
// NO): kept here, as saved, for as long as the store is open -- an
// attribute's value, a relationship's object IDs.
- (void)keepWhatIsNotServedOf:(NSSaveChangesRequest *)save
{
  NSMutableSet *changed = [NSMutableSet setWithSet:save.insertedObjects ?: [NSSet set]];
  [changed unionSet:save.updatedObjects ?: [NSSet set]];
  for (NSManagedObject *object in changed) {
    for (NSPropertyDescription *property in object.entity.properties) {
      if (property.isTransient || [_mapper servesProperty:property]) continue;
      id value = [object valueForKey:property.name];
      if ([property isKindOfClass:[NSRelationshipDescription class]]) {
        value = [(NSRelationshipDescription *)property isToMany] ? [[value allObjects] valueForKey:@"objectID"] : [value objectID];
      }
      [_lock lock];
      if (!_kept) _kept = [NSMutableDictionary dictionary];
      if (!_kept[object.objectID]) _kept[object.objectID] = [NSMutableDictionary dictionary];
      _kept[object.objectID][property.name] = value ?: [NSNull null];
      [_lock unlock];
    }
    [self keepInCachedNodeOf:object.objectID];
  }
  for (NSManagedObject *object in save.deletedObjects) {
    [_lock lock];
    [_kept removeObjectForKey:object.objectID];
    [_lock unlock];
  }
}

// The row kept for an object, with what it keeps of its own: a save that
// changes only that sends nothing, and the row would say otherwise.
- (void)keepInCachedNodeOf:(NSManagedObjectID *)objectID
{
  [_lock lock];
  NSIncrementalStoreNode *node = _nodeCache[objectID];
  NSDictionary *kept = [_kept[objectID] copy];
  [_lock unlock];
  if (!node || !kept.count) return;
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSPropertyDescription *property in objectID.entity.properties) {
    if ([property isKindOfClass:[NSRelationshipDescription class]] && [(NSRelationshipDescription *)property isToMany]) continue;
    id value = kept[property.name] ?: [node valueForPropertyDescription:property];
    if (!value || (value == [NSNull null] && [property isKindOfClass:[NSAttributeDescription class]])) continue;
    values[property.name] = value;
  }
  [node updateWithValues:values version:node.version];
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError **)error
{
  (void)context;
  if (![_mapper servesProperty:relationship]) {
    // Not the service's: what was saved here, if anything.
    [_lock lock];
    id kept = _kept[objectID][relationship.name];
    [_lock unlock];
    if (relationship.isToMany) return [kept isKindOfClass:[NSArray class]] ? [kept mutableCopy] : [NSMutableArray array];
    return kept ?: [NSNull null];
  }
  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:error];
  if (!identifier) return nil;
  NSURL *url = [_builder URLForIdentifier:identifier relationship:relationship error:error];
  if (!url) return nil;
  NSEntityDescription *destination = relationship.destinationEntity;
  if (!destination) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingEntitySet, relationship.name);
    return nil;
  }
  if (relationship.isToMany) {
    // Its members, when an $expand brought them all.
    [_lock lock];
    NSArray *members = _members[objectID][relationship.name];
    [_lock unlock];
    if (members) return [members mutableCopy];
    NSArray *rows = [self rowsAtURL:url limit:0 pageSize:0 error:error];
    if (!rows) return nil;
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *row in rows) {
      NSManagedObjectID *oid = [self objectIDFromPayload:row entity:destination error:error];
      if (!oid) return nil;
      [self cacheNodeForObjectID:oid entity:oid.entity payload:row error:nil];
      [ids addObject:oid];
    }
    return ids;
  }
  id json = [_client JSONAtURL:url error:error];
  if (!json) return nil;
  // 204 No Content: nothing is related (Part 1 section 11.2.7).
  if (![json isKindOfClass:[NSDictionary class]]) return [NSNull null];
  NSManagedObjectID *oid = [self objectIDFromPayload:json entity:destination error:error];
  if (oid) [self cacheNodeForObjectID:oid entity:oid.entity payload:json error:nil];
  return oid;
}

// With postOnObtainPermanentIDs (the default) inserts are POSTed here, so
// the service assigns the keys. Objects are posted in dependency order, so
// a new Product can bind to a new Category posted just before it; what a
// cycle leaves unbound is written by -executeSave:.
- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error
{
  for (NSManagedObject *object in array) {
    if (object.objectID.isTemporaryID && ![self checkCapabilitiesOf:object change:@"Insert" error:error]) return nil;
    NSError *violation = object.objectID.isTemporaryID && _client.configuration.postOnObtainPermanentIDs ? [_mapper vocabularyViolationOfObject:object] : nil;
    if (violation) {
      if (error) *error = violation;
      return nil;
    }
  }
  NSMutableDictionary *assigned = [NSMutableDictionary dictionary];  // temporary ID -> permanent ID
  NSArray *order = _client.configuration.postOnObtainPermanentIDs ? [self insertOrder:array] : array;
  for (NSManagedObject *object in order) {
    NSEntityDescription *entity = object.entity;
    NSManagedObjectID *oid = nil;
    if (_client.configuration.postOnObtainPermanentIDs) {
      OISWrite *write = [self writeForObject:object mode:OISWriteInsert assigned:assigned];
      NSDictionary *payload = [self postWrite:write entity:entity error:error];
      if (!payload) return nil;
      oid = [self objectIDFromPayload:payload entity:entity error:error];
      if (!oid) return nil;
      [self cacheNodeForObjectID:oid entity:entity payload:payload error:nil];
      [self noteMessagesIn:payload URL:nil objectID:oid];
      if (write.deferred.count) {
        [_lock lock];
        _deferred[oid] = [write.deferred copy];
        [_lock unlock];
      }
    } else {
      NSDictionary *keys = [self clientKeysForObject:object error:error];
      if (!keys) return nil;
      ODataResourceIdentifier *identifier = [self identifierForEntity:entity keys:keys];
      oid = [self newObjectIDForEntity:entity referenceObject:identifier.data];
    }
    assigned[object.objectID] = oid;
  }
  NSMutableArray *ids = [NSMutableArray array];
  for (NSManagedObject *object in array) [ids addObject:assigned[object.objectID]];
  return ids;
}

// Inserted objects, each after the inserted objects it refers to. A cycle
// is broken arbitrarily; the reference that closes it is deferred.
- (NSArray *)insertOrder:(NSArray *)objects
{
  NSMutableSet *batch = [NSMutableSet set];
  for (NSManagedObject *o in objects) [batch addObject:o.objectID];
  NSMutableArray *order = [NSMutableArray array];
  NSMutableSet *done = [NSMutableSet set];
  NSMutableSet *visiting = [NSMutableSet set];
  __block void (^visit)(NSManagedObject *) = nil;
  void (^visitor)(NSManagedObject *) = ^(NSManagedObject *object) {
    NSManagedObjectID *oid = object.objectID;
    if ([done containsObject:oid] || [visiting containsObject:oid]) return;
    [visiting addObject:oid];
    for (NSRelationshipDescription *rel in object.entity.relationshipsByName.allValues) {
      if (![self writesRelationship:rel]) continue;
      id value = [object valueForKey:rel.name];
      NSArray *targets = rel.isToMany ? [value allObjects] : (value ? @[ value ] : @[]);
      for (NSManagedObject *target in targets) {
        if ([target isKindOfClass:[NSManagedObject class]] && [batch containsObject:target.objectID]) visit(target);
      }
    }
    [visiting removeObject:oid];
    [done addObject:oid];
    [order addObject:object];
  };
  visit = visitor;
  for (NSManagedObject *object in objects) visit(object);
  visit = nil;
  return order;
}

#pragma mark - Messages

// Core.Messages in a JSON body, as a notification.
- (void)noteMessagesIn:(id)json URL:(NSURL *)url objectID:(NSManagedObjectID *)objectID
{
  NSArray *messages = [ODataMessage messagesInJSON:json];
  if (!messages) return;
  NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:messages forKey:ODataMessagesKey];
  if (url) info[ODataMessagesURLKey] = url;
  if (objectID) info[ODataMessagesObjectIDKey] = objectID;
  [[NSNotificationCenter defaultCenter] postNotificationName:ODataIncrementalStoreDidReceiveMessagesNotification object:self userInfo:info];
}

- (void)noteMessagesOf:(ODataHTTPResponse *)response operation:(OISOperation *)operation
{
  if (!response.data.length) return;
  [self noteMessagesIn:[response JSONWithError:NULL] URL:operation.request.URL objectID:operation.objectID];
}

#pragma mark - Capabilities

// What the service's Capabilities say of an entity's set: a term's value
// there, or the container's.
- (id)capability:(NSString *)term forEntity:(NSEntityDescription *)entity
{
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  return [_schema capability:term forEntitySet:[_mapper entitySetForEntity:root]];
}

static BOOL OISRefused(id value)
{
  return [value isEqual:@NO];
}

// The property paths a record's member lists ({"$PropertyPath": "Name"}).
static NSSet *OISPropertyPaths(id record, NSString *member)
{
  NSMutableSet *paths = [NSMutableSet set];
  id list = [record isKindOfClass:[NSDictionary class]] ? record[member] : nil;
  if (![list isKindOfClass:[NSArray class]]) return paths;
  for (id item in list) {
    id path = [item isKindOfClass:[NSDictionary class]] ? (item[@"$PropertyPath"] ?: item[@"$NavigationPropertyPath"]) : item;
    if ([path isKindOfClass:[NSString class]]) [paths addObject:path];
  }
  return paths;
}

// The key paths a predicate uses, from the fetched entity.
static void OISCollectKeyPaths(NSPredicate *predicate, NSMutableSet *into)
{
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    for (NSPredicate *sub in [(NSCompoundPredicate *)predicate subpredicates]) OISCollectKeyPaths(sub, into);
  } else if ([predicate isKindOfClass:[NSComparisonPredicate class]]) {
    for (NSExpression *e in @[ [(NSComparisonPredicate *)predicate leftExpression], [(NSComparisonPredicate *)predicate rightExpression] ]) {
      if (e.expressionType == NSKeyPathExpressionType) [into addObject:e.keyPath];
    }
  }
}

- (NSError *)notAllowed:(NSString *)what entity:(NSEntityDescription *)entity term:(NSString *)term
{
  return OISError(ODataIncrementalStoreErrorNotAllowedByService,
                  [NSString stringWithFormat:@"%@: the service does not %@ (Capabilities.%@)", entity.name, what, term]);
}

// The fetch to send, as the service's Capabilities let it be sent; what it
// does not do is done here after: sorting, then skipping, then the limit
// (sortLocally, and a nonzero skip or limit). A filter it cannot take is
// an error: evaluating it here would read every row.
- (NSFetchRequest *)sendableFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity
                      sortLocally:(BOOL *)sortLocally skip:(NSUInteger *)skip limit:(NSUInteger *)limit
                            count:(BOOL *)countLocally error:(NSError **)error
{
  *sortLocally = NO;
  *skip = 0;
  *limit = 0;
  *countLocally = NO;
  if (!_schema) return fetch;
  NSFetchRequest *sent = [fetch copy];

  id filtering = [self capability:@"Capabilities.FilterRestrictions" forEntity:entity];
  if ([filtering isKindOfClass:[NSDictionary class]]) {
    if (fetch.predicate && OISRefused(filtering[@"Filterable"])) {
      if (error) *error = [self notAllowed:@"filter" entity:entity term:@"FilterRestrictions"];
      return nil;
    }
    if (!fetch.predicate && [filtering[@"RequiresFilter"] isEqual:@YES]) {
      if (error) *error = [self notAllowed:@"list every row: give a predicate" entity:entity term:@"FilterRestrictions"];
      return nil;
    }
    NSSet *forbidden = OISPropertyPaths(filtering, @"NonFilterableProperties");
    NSMutableSet *used = [NSMutableSet set];
    if (fetch.predicate) OISCollectKeyPaths(fetch.predicate, used);
    for (NSString *keyPath in used) {
      NSString *wire = [_mapper propertyPathForKeyPath:keyPath entity:entity];
      NSString *first = [wire componentsSeparatedByString:@"/"].firstObject;
      if ([forbidden containsObject:wire] || [forbidden containsObject:first]) {
        if (error) *error = [self notAllowed:[NSString stringWithFormat:@"filter by %@", wire] entity:entity term:@"FilterRestrictions"];
        return nil;
      }
    }
    NSMutableSet *usedWire = [NSMutableSet set];
    for (NSString *keyPath in used) [usedWire addObject:[_mapper propertyPathForKeyPath:keyPath entity:entity]];
    for (NSString *required in OISPropertyPaths(filtering, @"RequiredProperties")) {
      if (![usedWire containsObject:required]) {
        if (error) *error = [self notAllowed:[NSString stringWithFormat:@"list rows without a filter on %@", required] entity:entity term:@"FilterRestrictions"];
        return nil;
      }
    }
  }

  if (fetch.resultType == NSCountResultType) {
    id counting = [self capability:@"Capabilities.CountRestrictions" forEntity:entity];
    if ([counting isKindOfClass:[NSDictionary class]] && OISRefused(counting[@"Countable"])) {
      // Counted here: the keys of the rows.
      *countLocally = YES;
      sent.resultType = NSManagedObjectIDResultType;
    }
  }

  id sorting = [self capability:@"Capabilities.SortRestrictions" forEntity:entity];
  if (fetch.sortDescriptors.count && [sorting isKindOfClass:[NSDictionary class]]) {
    BOOL local = OISRefused(sorting[@"Sortable"]);
    NSSet *forbidden = OISPropertyPaths(sorting, @"NonSortableProperties");
    for (NSSortDescriptor *descriptor in fetch.sortDescriptors) {
      if (descriptor.key && [forbidden containsObject:[_mapper propertyPathForKeyPath:descriptor.key entity:entity]]) local = YES;
    }
    if (local) {
      *sortLocally = YES;
      sent.sortDescriptors = nil;
    }
  }
  BOOL top = !OISRefused([self capability:@"Capabilities.TopSupported" forEntity:entity]);
  BOOL skipping = !OISRefused([self capability:@"Capabilities.SkipSupported" forEntity:entity]);
  // Sorted here, every row is needed before the skip and the limit.
  if (*sortLocally || !skipping || (!top && fetch.fetchOffset)) {
    *skip = fetch.fetchOffset;
    *limit = fetch.fetchLimit;
    sent.fetchOffset = 0;
    sent.fetchLimit = 0;
    if (!*sortLocally && top && fetch.fetchLimit) sent.fetchLimit = fetch.fetchOffset + fetch.fetchLimit;
  } else if (!top) {
    *limit = fetch.fetchLimit;
    sent.fetchLimit = 0;
  }

  id select = [self capability:@"Capabilities.SelectSupport" forEntity:entity];
  if ([select isKindOfClass:[NSDictionary class]] && OISRefused(select[@"Supported"])) sent.propertiesToFetch = nil;
  return sent;
}

// Sorted, skipped and limited here, as the service would have.
- (NSArray *)finishLocally:(NSArray *)results sort:(NSArray *)sort skip:(NSUInteger)skip limit:(NSUInteger)limit
                   context:(NSManagedObjectContext *)context
{
  if (sort.count) {
    BOOL identifiers = [results.firstObject isKindOfClass:[NSManagedObjectID class]];
    if (identifiers && context) {
      NSMutableArray *objects = [NSMutableArray array];
      for (NSManagedObjectID *oid in results) [objects addObject:[context objectWithID:oid]];
      results = [[objects sortedArrayUsingDescriptors:sort] valueForKey:@"objectID"];
    } else if (!identifiers) {
      results = [results sortedArrayUsingDescriptors:sort];
    }
  }
  if (skip) results = skip < results.count ? [results subarrayWithRange:NSMakeRange(skip, results.count - skip)] : @[];
  if (limit && results.count > limit) results = [results subarrayWithRange:NSMakeRange(0, limit)];
  return results;
}

// A change the service's Capabilities refuse, before anything is sent.
- (BOOL)checkCapabilitiesOf:(NSManagedObject *)object change:(NSString *)change error:(NSError **)error
{
  if (!_schema) return YES;
  NSString *term = [NSString stringWithFormat:@"Capabilities.%@Restrictions", change];
  id restrictions = [self capability:term forEntity:object.entity];
  NSString *member = [change isEqualToString:@"Insert"] ? @"Insertable" : [change isEqualToString:@"Update"] ? @"Updatable" : @"Deletable";
  if ([restrictions isKindOfClass:[NSDictionary class]] && OISRefused(restrictions[member])) {
    if (error) *error = [self notAllowed:[change lowercaseString] entity:object.entity term:[change stringByAppendingString:@"Restrictions"]];
    return NO;
  }
  return YES;
}

// Properties a POST (or a PATCH) is not to carry: Non*Properties.
- (NSSet *)unwritablePropertiesOf:(NSEntityDescription *)entity insert:(BOOL)insert
{
  if (!_schema) return [NSSet set];
  id restrictions = [self capability:insert ? @"Capabilities.InsertRestrictions" : @"Capabilities.UpdateRestrictions" forEntity:entity];
  return OISPropertyPaths(restrictions, insert ? @"NonInsertableProperties" : @"NonUpdatableProperties");
}

#pragma mark - Fetch / save

- (ODataQueryBuilder *)builder
{
  return _builder;
}

- (NSArray *)rowsForPath:(NSString *)path options:(ODataQueryOptions *)options limit:(NSUInteger)limit pageSize:(NSUInteger)pageSize
                     URL:(NSURL **)urlp error:(NSError **)error
{
  NSURL *url = [_builder URLForPath:path options:options error:error];
  if (urlp) *urlp = url;
  return url ? [self rowsAtURL:url limit:limit pageSize:pageSize error:error] : nil;
}

- (NSArray *)objectIDsForRows:(NSArray *)rows entity:(NSEntityDescription *)entity URL:(NSURL *)url error:(NSError **)error
{
  NSMutableArray *objectIDs = [NSMutableArray array];
  for (NSDictionary *row in rows) {
    NSManagedObjectID *oid = [row isKindOfClass:[NSDictionary class]] ? [self objectIDFromPayload:row entity:entity error:error] : nil;
    if (!oid) return nil;
    [self cacheNodeForObjectID:oid entity:oid.entity payload:row error:nil];
    if (url) [self noteMessagesIn:row URL:url objectID:oid];
    [objectIDs addObject:oid];
  }
  return objectIDs;
}

- (id)executeFetch:(NSFetchRequest *)fetch context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSEntityDescription *entity = [self resolvedEntity:fetch];
  if (!entity) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingEntitySet, fetch.entityName ?: @"Unknown");
    return nil;
  }
  if (fetch.resultType == NSDictionaryResultType && [self aggregates:fetch]) {
    return [self executeAggregateFetch:fetch entity:entity context:context error:error];
  }
  if (fetch.resultType == NSDictionaryResultType && [self computes:fetch] && ![self sendsComputeForEntity:entity]) {
    return [self executeComputedFetchHere:fetch entity:entity context:context error:error];
  }
  BOOL sortLocally = NO, countLocally = NO;
  NSUInteger skip = 0, limit = 0;
  NSFetchRequest *original = fetch;
  fetch = [self sendableFetch:original entity:entity sortLocally:&sortLocally skip:&skip limit:&limit count:&countLocally error:error];
  if (!fetch) return nil;
  // The fetch, typed: what the service is asked.
  ODataQueryOptions *options = [_builder optionsForFetch:fetch entity:entity error:error];
  if (!options) return nil;
  NSString *set = [_mapper collectionPathForEntity:entity];

  if (fetch.resultType == NSCountResultType) {
    NSURL *url = [_builder URLForPath:[set stringByAppendingString:@"/$count"] options:options error:error];
    NSString *text = url ? [_client textAtURL:url error:error] : nil;
    if (!text) return nil;
    NSInteger count = [text integerValue];
    return @[ @(count) ];
  }

  NSURL *url = nil;
  NSArray *rows = [self rowsForPath:set options:options limit:fetch.fetchLimit pageSize:fetch.fetchBatchSize URL:&url error:error];
  if (!rows) return nil;

  NSArray *sort = sortLocally ? original.sortDescriptors : nil;
  if (fetch.resultType == NSDictionaryResultType) {
    NSMutableArray *dicts = [NSMutableArray array];
    for (NSDictionary *row in rows) {
      [dicts addObject:[self dictionaryFromPayload:row entity:entity properties:original.propertiesToFetch]];
    }
    return [self finishLocally:dicts sort:sort skip:skip limit:limit context:context];
  }

  // Every row is a whole entity, so it is cached whether or not the fetch
  // returns faults: firing the fault then costs nothing, where it used to
  // cost one GET per object.
  NSArray *kept = [self objectIDsForRows:rows entity:entity URL:url error:error];
  if (!kept) return nil;
  NSMutableArray *objectIDs = [NSMutableArray array];
  for (NSManagedObjectID *oid in kept) {
    // A set of a base type holds its derived types too; a fetch that does
    // not include sub-entities leaves them out.
    if (!fetch.includesSubentities && oid.entity != entity && ![oid.entity.name isEqualToString:entity.name]) continue;
    [objectIDs addObject:oid];
  }

  NSArray *identifiers = [self finishLocally:objectIDs sort:sort skip:skip limit:limit context:context];
  if (countLocally) return @[ @(identifiers.count) ];
  if (fetch.resultType == NSManagedObjectIDResultType) return identifiers;
  if (!context) return identifiers;
  NSMutableArray *objects = [NSMutableArray array];
  for (NSManagedObjectID *oid in identifiers) {
    [objects addObject:[context objectWithID:oid]];
  }
  return objects;
}

#pragma mark - Grouping and aggregating

// A key path grouped by or fetched: given as a string, a property, or as
// Apple's Core Data passes a string on, an expression description of it.
static NSString *OISKeyPathOf(id property)
{
  if ([property isKindOfClass:[NSString class]]) return property;
  if ([property isKindOfClass:[NSExpressionDescription class]]) {
    NSExpression *e = [(NSExpressionDescription *)property expression];
    return e.expressionType == NSKeyPathExpressionType ? e.keyPath : nil;
  }
  if ([property isKindOfClass:[NSPropertyDescription class]] && ![property isKindOfClass:[NSExpressionDescription class]]) return [property name];
  return nil;
}

// A dictionary fetch that groups (propertiesToGroupBy) or aggregates (an
// NSExpressionDescription of sum:, min:, max:, average:, count:).
// An aggregate (sum:, min:, max:, average:, count:), as against a value
// computed from each row.
static BOOL OISIsAggregate(NSExpressionDescription *description)
{
  NSExpression *e = description.expression;
  return e.expressionType == NSFunctionExpressionType &&
         [@[ @"sum:", @"min:", @"max:", @"average:", @"count:" ] containsObject:e.function];
}

- (BOOL)aggregates:(NSFetchRequest *)fetch
{
  if (fetch.propertiesToGroupBy.count) return YES;
  for (id property in fetch.propertiesToFetch) {
    if ([property isKindOfClass:[NSExpressionDescription class]] && !OISKeyPathOf(property) && OISIsAggregate(property)) return YES;
  }
  return NO;
}

// Values computed from each row (unitPrice * 2), not grouped.
- (BOOL)computes:(NSFetchRequest *)fetch
{
  for (id property in fetch.propertiesToFetch) {
    if ([property isKindOfClass:[NSExpressionDescription class]] && !OISKeyPathOf(property) && !OISIsAggregate(property)) return YES;
  }
  return NO;
}

// $compute: 4.01, where the service does not say it has none
// (Capabilities.SelectSupport/ComputeSupported).
- (BOOL)sendsComputeForEntity:(NSEntityDescription *)entity
{
  if (![_client.configuration.version isEqualToString:@"4.01"]) return NO;
  id support = [self capability:@"Capabilities.SelectSupport" forEntity:entity];
  return !([support isKindOfClass:[NSDictionary class]] && OISRefused(support[@"ComputeSupported"]));
}

// Whether a dictionary fetch names a dynamic property (dynamicProperties.Size),
// which $select can ask for by its name.
- (BOOL)selectsDynamicProperties:(NSFetchRequest *)fetch
{
  NSEntityDescription *entity = fetch.entity;
  for (id property in fetch.propertiesToFetch) {
    NSString *path = [property isKindOfClass:[NSString class]] ? property
                   : [property isKindOfClass:[NSExpressionDescription class]] ? OISKeyPathOf(property) : nil;
    NSArray *parts = [path componentsSeparatedByString:@"."];
    if (parts.count > 1 && [_mapper attributeHoldsDynamicProperties:entity.attributesByName[parts[0]]]) return YES;
  }
  return NO;
}

// FreeCoreData shapes grouped, aggregated and computed dictionary fetches
// itself unless the store says it does; this one does, and those that
// name a dynamic property, which $select asks the service for.
- (BOOL)_canShapeDictionaryRequest:(NSFetchRequest *)request
{
  return [self aggregates:request] || [self computes:request] || [self selectsDynamicProperties:request];
}

// Where the service computes nothing: the rows, and each value computed
// here from its object.
- (NSArray *)executeComputedFetchHere:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity
                              context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSFetchRequest *rows = [fetch copy];
  rows.entity = entity;
  rows.resultType = NSManagedObjectResultType;
  rows.propertiesToFetch = nil;
  NSArray *objects = [self executeFetch:rows context:context error:error];
  if (!objects) return nil;
  NSMutableArray *out = [NSMutableArray array];
  for (NSManagedObject *object in objects) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    for (id property in fetch.propertiesToFetch) {
      // An attribute, a key path, or an expression to evaluate.
      NSString *keyPath = OISKeyPathOf(property);
      id value = nil;
      @try {
        value = keyPath ? [object valueForKeyPath:keyPath]
                        : [[(NSExpressionDescription *)property expression] expressionValueWithObject:object context:nil];
      } @catch (NSException *exception) {
        value = nil;  // a null operand
      }
      NSString *name = [property isKindOfClass:[NSString class]] ? property : [property name];
      if (value && value != [NSNull null]) row[name] = value;
    }
    [out addObject:row];
  }
  return out;
}

// The attribute a key path ends at, through to-one relationships.
static NSAttributeDescription *OISAttributeAtKeyPath(NSEntityDescription *entity, NSString *keyPath)
{
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  NSEntityDescription *at = entity;
  for (NSUInteger i = 0; i + 1 < parts.count; i++) {
    NSRelationshipDescription *rel = at.relationshipsByName[parts[i]];
    if (!rel || rel.isToMany) return nil;
    at = rel.destinationEntity;
  }
  return at.attributesByName[parts.lastObject];
}


// Rows grouped and aggregated (Data Aggregation): by $apply where the
// service says it has it (Aggregation.ApplySupported), else here over the
// rows it sends. havingPredicate, the sort, the offset and the limit
// follow the grouping in $apply as far as the service can take them
// (stepsAfterGrouping:), and are applied here otherwise. Keys are as Core Data's: the
// grouped key paths (category.name) and the expressions' names.
// What a grouping fetch asks, by key path: the grouped key paths, the
// aggregates as Core Data's key paths name them (local) and as the wire
// does, what each row gives, and the aggregates' result types and
// attributes. NO, with the reason, for one that cannot be done.
- (BOOL)planAggregateFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity
                  keyPaths:(NSMutableArray *)keyPaths local:(NSMutableArray *)local wire:(NSMutableArray *)wire
                   outputs:(NSMutableArray *)outputs resultTypes:(NSMutableDictionary *)resultTypes
       aggregateAttributes:(NSMutableDictionary *)aggregateAttributes error:(NSError **)error
{
  for (id property in fetch.propertiesToGroupBy) {
    NSString *keyPath = OISKeyPathOf(property);
    if (!keyPath || !OISAttributeAtKeyPath(entity, keyPath)) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, [NSString stringWithFormat:@"Grouping by %@", property]);
      return NO;
    }
    [keyPaths addObject:keyPath];
  }
  NSDictionary *methods = @{ @"sum:": @"sum", @"min:": @"min", @"max:": @"max", @"average:": @"average", @"count:": @"$count" };
  for (id property in fetch.propertiesToFetch) {
    if (![property isKindOfClass:[NSExpressionDescription class]] || OISKeyPathOf(property)) {
      NSString *keyPath = OISKeyPathOf(property);
      if (!keyPath || ![keyPaths containsObject:keyPath]) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                     [NSString stringWithFormat:@"%@ is fetched but not grouped by", property]);
        return NO;
      }
      [outputs addObject:keyPath];
      continue;
    }
    NSExpressionDescription *description = property;
    NSExpression *e = description.expression;
    NSString *method = e.expressionType == NSFunctionExpressionType ? methods[e.function] : nil;
    NSExpression *argument = e.expressionType == NSFunctionExpressionType ? e.arguments.firstObject : nil;
    NSString *keyPath = argument.expressionType == NSKeyPathExpressionType ? argument.keyPath : nil;
    NSAttributeDescription *attribute = keyPath ? OISAttributeAtKeyPath(entity, keyPath) : nil;
    if (!method || (!attribute && ![method isEqualToString:@"$count"])) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@: %@", description.name, e]);
      return NO;
    }
    BOOL count = [method isEqualToString:@"$count"];
    // The expression description's name is the alias: an OData identifier,
    // as the model's names are (the mapper's).
    ODataAggregate *here = [ODataAggregate aggregateOfPath:count ? nil : [keyPath componentsSeparatedByString:@"."]
                                                    method:count ? nil : method alias:description.name error:error];
    ODataAggregate *there = here ? [ODataAggregate aggregateOfPath:count ? nil : [[_mapper propertyPathForKeyPath:keyPath entity:entity]
                                                                                   componentsSeparatedByString:@"/"]
                                                            method:count ? nil : method alias:description.name error:error] : nil;
    if (!there) return NO;
    [local addObject:here];
    [wire addObject:there];
    resultTypes[description.name] = @(description.expressionResultType);
    if (attribute) aggregateAttributes[description.name] = attribute;
    [outputs addObject:description.name];
  }
  return YES;
}

// What of a grouping fetch the service does after the grouping, as $apply
// steps: its havingPredicate as filter(), its sort as orderby(), then its
// offset and limit as skip() and top() when everything before them went
// too; each only where the service lists the transformation
// (Aggregation.ApplySupported/Transformations). The rest is done here, in
// that order: what went is set in the flags.
- (NSArray *)stepsAfterGrouping:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity keyPaths:(NSArray *)keyPaths
                          paths:(NSArray *)paths aggregates:(NSArray *)aggregates
                         having:(BOOL *)having sort:(BOOL *)sort paging:(BOOL *)paging
{
  *having = *sort = *paging = NO;
  NSDictionary *apply = [self applySupportFor:entity];
  NSArray *listed = apply[@"Transformations"];
  // No list: every transformation (Data Aggregation section 5.1).
  NSSet *supported = [listed isKindOfClass:[NSArray class]] ? [NSSet setWithArray:listed]
                                                            : [NSSet setWithObjects:@"filter", @"orderby", @"skip", @"top", nil];
  NSMutableDictionary *names = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < keyPaths.count; i++) names[keyPaths[i]] = [paths[i] componentsJoinedByString:@"/"];
  for (ODataAggregate *aggregate in aggregates) names[aggregate.alias] = aggregate.alias;
  NSMutableArray *steps = [NSMutableArray array];
  ODataExpression *filter = fetch.havingPredicate && [supported containsObject:@"filter"]
      ? [_builder groupedFilterExpressionForPredicate:fetch.havingPredicate names:names] : nil;
  if (filter) [steps addObject:[ODataApplyTransformation filterWithExpression:filter]];
  *having = !fetch.havingPredicate || filter;
  NSArray *order = fetch.sortDescriptors.count && [supported containsObject:@"orderby"]
      ? [_builder groupedOrderItemsForSortDescriptors:fetch.sortDescriptors names:names] : nil;
  if (order) [steps addObject:[ODataApplyTransformation orderByItems:order]];
  *sort = !fetch.sortDescriptors.count || order;
  BOOL skip = !fetch.fetchOffset || [supported containsObject:@"skip"], top = !fetch.fetchLimit || [supported containsObject:@"top"];
  if (*having && *sort && skip && top) {
    if (fetch.fetchOffset) [steps addObject:[ODataApplyTransformation skip:fetch.fetchOffset]];
    if (fetch.fetchLimit) [steps addObject:[ODataApplyTransformation top:fetch.fetchLimit]];
    *paging = YES;
  }
  return steps;
}

// What $apply the service has for an entity's set: its ApplySupported
// over the container's ApplySupportedDefaults (Data Aggregation section
// 5.1), the one replacing the other's properties; nil for none. Either
// said null is none.
- (NSDictionary *)applySupportFor:(NSEntityDescription *)entity
{
  id apply = [self capability:@"Aggregation.ApplySupported" forEntity:entity];
  id defaults = _schema.containerName ? [_schema annotation:@"Aggregation.ApplySupportedDefaults" forTarget:_schema.containerName] : nil;
  if (apply == [NSNull null] || defaults == [NSNull null] || (!apply && !defaults)) return nil;
  NSMutableDictionary *merged = [NSMutableDictionary dictionary];
  if ([defaults isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:defaults];
  if ([apply isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:apply];
  return merged;
}

// $apply where the service says it has it (Aggregation.ApplySupported);
// nil where the rows are grouped here.
- (NSArray *)applyPathsFor:(NSArray *)keyPaths entity:(NSEntityDescription *)entity
{
  if (![self applySupportFor:entity]) return nil;
  NSMutableArray *paths = [NSMutableArray array];
  for (NSString *keyPath in keyPaths) [paths addObject:[[_mapper propertyPathForKeyPath:keyPath entity:entity] componentsSeparatedByString:@"/"]];
  return paths;
}

// Grouped here: every row the predicate matches, with what the key paths
// go through, as object IDs.
- (NSFetchRequest *)rowsToGroupFor:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity
                          keyPaths:(NSArray *)keyPaths local:(NSArray *)local
{
  NSFetchRequest *all = [NSFetchRequest fetchRequestWithEntityName:entity.name];
  all.entity = entity;
  all.predicate = fetch.predicate;
  NSMutableSet *through = [NSMutableSet set];
  for (NSString *keyPath in [keyPaths arrayByAddingObjectsFromArray:[local valueForKey:@"path"]]) {
    if ([(id)keyPath isKindOfClass:[NSNull class]]) continue;  // $count
    NSArray *parts = [keyPath isKindOfClass:[NSArray class]] ? (NSArray *)keyPath : [keyPath componentsSeparatedByString:@"."];
    if (parts.count > 1) [through addObject:[[parts subarrayWithRange:NSMakeRange(0, parts.count - 1)] componentsJoinedByString:@"."]];
  }
  all.relationshipKeyPathsForPrefetching = through.allObjects;
  all.resultType = NSManagedObjectIDResultType;
  return all;
}

- (NSURL *)URLForFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
  // Named by its entity, a request not yet used by a context has no
  // entity on Apple, and raises when asked: given its entity here.
  NSFetchRequest *fetch = [request copy];
  NSEntityDescription *named = request.entityName ? self.persistentStoreCoordinator.managedObjectModel.entitiesByName[request.entityName] : nil;
  if (named) fetch.entity = named;
  NSEntityDescription *entity = named ?: [self resolvedEntity:fetch];
  if (!entity) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingEntitySet, fetch.entityName ?: @"Unknown");
    return nil;
  }
  if (fetch.resultType != NSDictionaryResultType || ![self aggregates:fetch]) {
    BOOL sortLocally = NO, countLocally = NO;
    NSUInteger skip = 0, limit = 0;
    NSFetchRequest *sendable = [self sendableFetch:fetch entity:entity sortLocally:&sortLocally skip:&skip limit:&limit count:&countLocally error:error];
    return sendable ? [_builder URLForFetch:sendable entity:entity error:error] : nil;
  }
  NSMutableArray *keyPaths = [NSMutableArray array], *local = [NSMutableArray array], *wire = [NSMutableArray array];
  if (![self planAggregateFetch:fetch entity:entity keyPaths:keyPaths local:local wire:wire outputs:[NSMutableArray array]
                    resultTypes:[NSMutableDictionary dictionary] aggregateAttributes:[NSMutableDictionary dictionary] error:error]) return nil;
  NSArray *paths = [self applyPathsFor:keyPaths entity:entity];
  if (paths) {
    BOOL having, sort, paging;
    NSArray *after = [self stepsAfterGrouping:fetch entity:entity keyPaths:keyPaths paths:paths aggregates:wire having:&having sort:&sort paging:&paging];
    return [_builder URLForAggregateFetch:fetch entity:entity groupPaths:paths aggregates:wire after:after error:error];
  }
  return [_builder URLForFetch:[self rowsToGroupFor:fetch entity:entity keyPaths:keyPaths local:local] entity:entity error:error];
}

- (NSArray *)executeAggregateFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity
                           context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSMutableArray *keyPaths = [NSMutableArray array], *local = [NSMutableArray array], *wire = [NSMutableArray array];
  NSMutableArray *outputs = [NSMutableArray array];
  NSMutableDictionary *resultTypes = [NSMutableDictionary dictionary], *aggregateAttributes = [NSMutableDictionary dictionary];
  if (![self planAggregateFetch:fetch entity:entity keyPaths:keyPaths local:local wire:wire outputs:outputs
                    resultTypes:resultTypes aggregateAttributes:aggregateAttributes error:error]) return nil;

  // Each row as nested dictionaries, as the key paths read them.
  NSMutableArray *rows = [NSMutableArray array];
  NSArray *paths = [self applyPathsFor:keyPaths entity:entity];
  BOOL havingThere = NO, sortThere = NO, pagingThere = NO;
  if (paths) {
    NSArray *after = [self stepsAfterGrouping:fetch entity:entity keyPaths:keyPaths paths:paths aggregates:wire
                                       having:&havingThere sort:&sortThere paging:&pagingThere];
    ODataQueryOptions *options = [_builder optionsForAggregateFetch:fetch entity:entity groupPaths:paths aggregates:wire after:after error:error];
    NSArray *answers = options ? [self rowsForPath:[_mapper collectionPathForEntity:entity] options:options limit:0 pageSize:0 URL:NULL error:error] : nil;
    if (!answers) return nil;
    for (NSDictionary *answer in answers) {
      NSMutableDictionary *row = [NSMutableDictionary dictionary];
      for (NSUInteger i = 0; i < keyPaths.count; i++) {
        id json = answer;
        for (NSString *segment in paths[i]) json = [json isKindOfClass:[NSDictionary class]] ? json[segment] : nil;
        id value = json && json != [NSNull null] ? [_mapper.values coreDataValueForJSON:json attribute:OISAttributeAtKeyPath(entity, keyPaths[i])] : nil;
        OISSetKeyPath(row, keyPaths[i], value);
      }
      for (ODataAggregate *aggregate in wire) {
        OISSetKeyPath(row, aggregate.alias, [self aggregateValue:answer[aggregate.alias] method:aggregate.method
                                                       attribute:aggregateAttributes[aggregate.alias]
                                                            type:[resultTypes[aggregate.alias] unsignedIntegerValue]]);
      }
      [rows addObject:row];
    }
  } else {
    // Here: every row, with what the key paths go through.
    NSFetchRequest *all = [self rowsToGroupFor:fetch entity:entity keyPaths:keyPaths local:local];
    NSArray *identifiers = [self executeFetch:all context:context error:error];
    if (!identifiers) return nil;
    // Each row as what its key paths read, from the rows kept.
    NSMutableSet *needed = [NSMutableSet setWithArray:keyPaths];
    for (ODataAggregate *aggregate in local) if (aggregate.path) [needed addObject:[aggregate.path componentsJoinedByString:@"."]];
    NSMutableArray *objects = [NSMutableArray array];
    for (NSManagedObjectID *oid in identifiers) {
      NSMutableDictionary *object = [NSMutableDictionary dictionary];
      for (NSString *keyPath in needed) {
        id value = nil;
        if (![self value:&value atKeyPath:keyPath objectID:oid context:context error:error]) return nil;
        OISSetKeyPath(object, keyPath, value);
      }
      [objects addObject:object];
    }
    for (NSDictionary *group in [ODataAggregation groupObjects:objects byKeyPaths:keyPaths aggregates:local]) {
      NSMutableDictionary *row = [NSMutableDictionary dictionary];
      for (NSString *key in group) OISSetKeyPath(row, key, group[key] == [NSNull null] ? nil : group[key]);
      // Sums and averages of the type asked for, as the service's would be.
      for (ODataAggregate *aggregate in local) {
        if ([aggregate.method isEqualToString:@"min"] || [aggregate.method isEqualToString:@"max"]) continue;
        OISSetKeyPath(row, aggregate.alias, [self aggregateValue:group[aggregate.alias] method:aggregate.method attribute:nil
                                                            type:[resultTypes[aggregate.alias] unsignedIntegerValue]]);
      }
      [rows addObject:row];
    }
  }

  // What the service did not do after the grouping, here.
  NSArray *result = rows;
  if (fetch.havingPredicate && !havingThere) result = [result filteredArrayUsingPredicate:fetch.havingPredicate];
  if (fetch.sortDescriptors.count && !sortThere) result = [result sortedArrayUsingDescriptors:fetch.sortDescriptors];
  if (!pagingThere) {
    NSUInteger skip = MIN(fetch.fetchOffset, result.count);
    result = [result subarrayWithRange:NSMakeRange(skip, result.count - skip)];
    if (fetch.fetchLimit && fetch.fetchLimit < result.count) result = [result subarrayWithRange:NSMakeRange(0, fetch.fetchLimit)];
  }
  // Flat, keyed as Core Data keys them; a value there is none of is left out.
  NSMutableArray *flat = [NSMutableArray array];
  for (NSDictionary *row in result) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in outputs) {
      id value = [row valueForKeyPath:key];
      if (value && value != [NSNull null]) out[key] = value;
    }
    [flat addObject:out];
  }
  return flat;
}

// What a key path reads of an object, through its to-one relationships,
// from the rows the store keeps (or reads). NO, with the error, when a row
// cannot be read.
- (BOOL)value:(id *)value atKeyPath:(NSString *)keyPath objectID:(NSManagedObjectID *)objectID
      context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  NSManagedObjectID *at = objectID;
  *value = nil;
  for (NSUInteger i = 0; i < parts.count; i++) {
    NSIncrementalStoreNode *node = [self newValuesForObjectWithID:at withContext:context error:error];
    if (!node) return NO;
    NSPropertyDescription *property = at.entity.propertiesByName[parts[i]];
    if (i + 1 == parts.count) {
      id found = property ? [node valueForPropertyDescription:property] : nil;
      *value = found == [NSNull null] ? nil : found;
      return YES;
    }
    if (![property isKindOfClass:[NSRelationshipDescription class]] || [(NSRelationshipDescription *)property isToMany]) return YES;
    id related = [node valueForPropertyDescription:property];
    if (!related) related = [self newValueForRelationship:(NSRelationshipDescription *)property forObjectWithID:at withContext:context error:error];
    if (![related isKindOfClass:[NSManagedObjectID class]]) return related != nil || !error || !*error;
    at = related;
  }
  return YES;
}

// Sets value at a key path in nested dictionaries.
static void OISSetKeyPath(NSMutableDictionary *row, NSString *keyPath, id value)
{
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  NSMutableDictionary *at = row;
  for (NSUInteger i = 0; i + 1 < parts.count; i++) {
    if (![at[parts[i]] isKindOfClass:[NSMutableDictionary class]]) at[parts[i]] = [NSMutableDictionary dictionary];
    at = at[parts[i]];
  }
  at[parts.lastObject] = value ?: [NSNull null];
}

// An aggregated value as the expression's type has it: min and max as
// the attribute's, the others as numbers of the result type.
- (id)aggregateValue:(id)json method:(NSString *)method attribute:(NSAttributeDescription *)attribute type:(NSAttributeType)type
{
  if (!json || json == [NSNull null]) return nil;
  if (attribute && ([method isEqualToString:@"min"] || [method isEqualToString:@"max"])) {
    return [_mapper.values coreDataValueForJSON:json attribute:attribute];
  }
  NSDecimalNumber *number = [json isKindOfClass:[NSString class]] ? [NSDecimalNumber decimalNumberWithString:json]
                          : [json isKindOfClass:[NSNumber class]] ? [NSDecimalNumber decimalNumberWithDecimal:[json decimalValue]] : nil;
  if (!number) return nil;
  switch (type) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType:
    case NSInteger64AttributeType: return @(number.longLongValue);
    case NSDoubleAttributeType:
    case NSFloatAttributeType: return @(number.doubleValue);
    default: return number;
  }
}

// The rows of a collection, across every page the service splits it into:
// @odata.nextLink is followed until it stops, or until `limit` rows (0 for
// no limit) are in hand (Part 1 section 11.2.6.7). A failed request fails
// the whole read; it is never an empty result. A page size, from the
// fetch's fetchBatchSize, is asked for with Prefer: odata.maxpagesize
// (section 8.2.8.3); the service may page smaller, never larger.
- (NSArray *)rowsAtURL:(NSURL *)url limit:(NSUInteger)limit pageSize:(NSUInteger)pageSize error:(NSError **)error
{
  return [self rowsAtURL:url limit:limit pageSize:pageSize trackChanges:NO deltaLink:NULL error:error];
}

// With trackChanges, asks for a delta link (Prefer: odata.track-changes,
// Part 1 section 8.2.8.6), which comes with the last page.
- (NSArray *)rowsAtURL:(NSURL *)url
                 limit:(NSUInteger)limit
              pageSize:(NSUInteger)pageSize
          trackChanges:(BOOL)trackChanges
             deltaLink:(NSURL **)deltaLink
                 error:(NSError **)error
{
  NSMutableArray *preferences = [NSMutableArray array];
  if (pageSize) [preferences addObject:[NSString stringWithFormat:@"odata.maxpagesize=%lu", (unsigned long)pageSize]];
  if (trackChanges) [preferences addObject:@"odata.track-changes"];
  NSDictionary *headers = preferences.count ? @{ @"Prefer": [preferences componentsJoinedByString:@","] } : nil;
  if (deltaLink) *deltaLink = nil;
  NSMutableArray *rows = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  while (url) {
    NSString *absolute = url.absoluteString ?: @"";
    if ([seen containsObject:absolute]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Next link loops back to %@", absolute]);
      return nil;
    }
    [seen addObject:absolute];
    id json = [_client JSONAtURL:url headers:headers error:error];
    if (!json) return nil;
    if (json == [NSNull null]) break;
    if (![json isKindOfClass:[NSDictionary class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Expected a JSON object from %@", absolute]);
      return nil;
    }
    // Of the collection; an entity's own, as its row is read.
    if (json[@"value"]) [self noteMessagesIn:json URL:url objectID:nil];
    id value = json[@"value"];
    NSArray *page = [value isKindOfClass:[NSArray class]] ? value : @[ json ];
    for (id row in page) {
      if ([row isKindOfClass:[NSDictionary class]]) [rows addObject:row];
    }
    if (limit && rows.count >= limit) {
      return [rows subarrayWithRange:NSMakeRange(0, limit)];
    }
    NSString *next = json[@"@odata.nextLink"];
    NSString *delta = json[@"@odata.deltaLink"];
    if (deltaLink && [delta isKindOfClass:[NSString class]]) {
      NSURL *resolved = [NSURL URLWithString:delta relativeToURL:url].absoluteURL;
      *deltaLink = resolved ? [self serviceURLForLink:resolved] : nil;
    }
    url = [next isKindOfClass:[NSString class]] ? [NSURL URLWithString:next relativeToURL:url].absoluteURL : nil;
  }
  return rows;
}

- (id)executeSave:(NSSaveChangesRequest *)save error:(NSError **)error
{
  NSMutableArray *operations = [NSMutableArray array];
  NSMutableArray *referenced = [NSMutableArray array];  // objects whose $ref requests may change their ETag
  for (NSManagedObject *object in save.insertedObjects) {
    if (![self checkCapabilitiesOf:object change:@"Insert" error:error]) return nil;
  }
  // Validation.MultipleOf and Constraint: refused here, as the service
  // would.
  for (NSSet *changed in @[ save.insertedObjects ?: [NSSet set], save.updatedObjects ?: [NSSet set] ]) {
    for (NSManagedObject *object in changed) {
      NSError *violation = [_mapper vocabularyViolationOfObject:object];
      if (violation) {
        if (error) *error = violation;
        return nil;
      }
    }
  }
  for (NSManagedObject *object in save.updatedObjects) {
    if (![self checkCapabilitiesOf:object change:@"Update" error:error]) return nil;
  }
  for (NSManagedObject *object in save.deletedObjects) {
    if (![self checkCapabilitiesOf:object change:@"Delete" error:error]) return nil;
  }

  if (!_client.configuration.postOnObtainPermanentIDs) {
    for (NSManagedObject *object in [self insertOrder:save.insertedObjects.allObjects]) {
      OISWrite *write = [self writeForObject:object mode:OISWriteInsert assigned:nil];
      if (![self addPostOf:write object:object to:operations error:error]) return nil;
      if (![self addReferencesOf:write to:operations error:error]) return nil;
    }
  }
  for (NSManagedObject *object in save.insertedObjects) {
    [_lock lock];
    BOOL deferred = _deferred[object.objectID] != nil;
    [_lock unlock];
    if (!deferred) continue;
    OISWrite *write = [self writeForObject:object mode:OISWriteDeferred assigned:nil];
    if (![self addPatchOf:write object:object to:operations error:error]) return nil;
    if (write.references.count) [referenced addObject:object];
  }
  for (NSManagedObject *object in save.updatedObjects) {
    OISWrite *write = [self writeForObject:object mode:OISWriteUpdate assigned:nil];
    if (![self addPatchOf:write object:object to:operations error:error]) return nil;
    if (write.references.count) [referenced addObject:object];
  }
  for (NSManagedObject *object in save.deletedObjects) {
    NSURL *url = [self editURLForObjectID:object.objectID error:error];
    NSMutableURLRequest *request = url ? [_client requestWithMethod:@"DELETE" URL:url body:nil
                                                               etag:[self currentETagForObjectID:object.objectID] error:error] : nil;
    if (!request) return nil;
    NSManagedObjectID *objectID = object.objectID;
    [operations addObject:[self operation:request completion:^BOOL(ODataHTTPResponse *response, NSError **e) {
      [self forgetObjectID:objectID];
      return YES;
    }]];
  }

  NSError *sendError = nil;
  if (![self sendOperations:operations error:&sendError]) {
    if (error) *error = [self saveConflictFor:sendError operations:operations save:save] ?: sendError;
    return nil;
  }

  for (NSManagedObject *object in save.insertedObjects) {
    [_lock lock];
    [_deferred removeObjectForKey:object.objectID];
    [_lock unlock];
  }
  // A $ref request changes the entity, and may change its ETag, without
  // returning it; read it back so the next write does not send a stale one.
  for (NSManagedObject *object in referenced) {
    [_lock lock];
    BOOL hasETag = _etags[object.objectID] != nil;
    [_lock unlock];
    if (!hasETag) continue;
    ODataResourceIdentifier *identifier = [self identifierFromObjectID:object.objectID error:NULL];
    NSURL *url = identifier ? [_builder URLForReadingIdentifier:identifier entity:object.entity error:NULL] : nil;
    id fresh = url ? [_client JSONAtURL:url error:NULL] : nil;
    if ([fresh isKindOfClass:[NSDictionary class]]) {
      [self cacheNodeForObjectID:object.objectID entity:object.entity payload:fresh error:nil];
    } else {
      [_lock lock];
      [_etags removeObjectForKey:object.objectID];
      [_lock unlock];
    }
  }
  [self recordSave:save];
  return @[];
}

#pragma mark - History

// FreeCoreData's coordinator asks a store these for its history token.
- (BOOL)_historyTrackingEnabled
{
  return _history != nil;
}

- (long long)_lastHistoryTransactionNumber
{
  return _history.lastTransactionNumber;
}

// A save, as a transaction; and what the store now knows of the rows the
// save touched, for -fetchRemoteChanges:.
- (void)recordSave:(NSSaveChangesRequest *)save
{
  NSMutableArray *inserted = [NSMutableArray array];
  NSMutableDictionary *updated = [NSMutableDictionary dictionary];
  NSMutableArray *deleted = [NSMutableArray array];
  NSManagedObjectContext *context = nil;
  for (NSManagedObject *object in save.insertedObjects) {
    [inserted addObject:object.objectID];
    context = context ?: object.managedObjectContext;
  }
  for (NSManagedObject *object in save.updatedObjects) {
    updated[object.objectID] = [NSSet setWithArray:object.changedValues.allKeys];
    context = context ?: object.managedObjectContext;
  }
  for (NSManagedObject *object in save.deletedObjects) {
    [deleted addObject:object.objectID];
    context = context ?: object.managedObjectContext;
  }
  [self recordInserted:inserted updated:updated deleted:deleted context:context];
}

// Changes this store made at the service: what -fetchRemoteChanges:
// compares against, and the persistent history.
- (void)recordInserted:(NSArray *)inserted updated:(NSDictionary *)updated deleted:(NSArray *)deleted context:(NSManagedObjectContext *)context
{
  [_lock lock];
  for (OISTracking *tracking in _tracking.allValues) {
    for (NSManagedObjectID *oid in inserted) {
      if (tracking == _tracking[[self trackedEntityFor:oid.entity].name]) tracking.rows[oid] = [NSNull null];
    }
    for (NSManagedObjectID *oid in updated) {
      if (tracking.rows[oid]) tracking.rows[oid] = [NSNull null];
    }
    for (NSManagedObjectID *oid in deleted) [tracking.rows removeObjectForKey:oid];
  }
  [_lock unlock];
  [_history recordInserted:inserted updated:updated deleted:deleted author:context.transactionAuthor contextName:context.name];
}

#pragma mark - Batch updates and deletes

// NSBatchUpdateRequest and NSBatchDeleteRequest (4.01's collection writes,
// Part 1 sections 11.4.13-14): PATCH or DELETE of Set/$filter(@f)/$each,
// where the set's Capabilities say it takes a filter segment (and a cast
// one, for a sub-entity); elsewhere, or for what a filter segment cannot
// say (a limit, $search, application time), the objects are fetched and
// each is written, in one change set. As with Core Data's own stores, no
// context is changed: merge the result's object IDs into those that need
// them (NSUpdatedObjectsKey, NSDeletedObjectsKey,
// +mergeChangesFromRemoteContextSave:intoContexts:).
- (id)executeBatchUpdate:(NSBatchUpdateRequest *)request context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSEntityDescription *entity = request.entity ?: self.persistentStoreCoordinator.managedObjectModel.entitiesByName[request.entityName];
  id restrictions = [self capability:@"Capabilities.UpdateRestrictions" forEntity:entity];
  if ([restrictions isKindOfClass:[NSDictionary class]] && OISRefused(restrictions[@"Updatable"])) {
    if (error) *error = [self notAllowed:@"update" entity:entity term:@"UpdateRestrictions"];
    return nil;
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  NSMutableSet *names = [NSMutableSet set];
  for (id key in request.propertiesToUpdate) {
    NSString *name = [key isKindOfClass:[NSPropertyDescription class]] ? [key name] : key;
    NSPropertyDescription *property = entity.propertiesByName[name];
    id value = request.propertiesToUpdate[key];
    if ([value isKindOfClass:[NSExpression class]]) {
      if ([value expressionType] != NSConstantValueExpressionType) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                     [NSString stringWithFormat:@"%@.%@: a batch update sends a value to each; %@ is not one", entity.name, name, value]);
        return nil;
      }
      value = [value constantValue];
    }
    if (value == [NSNull null]) value = nil;
    // Attributes, as Core Data's own batch updates take.
    if (![property isKindOfClass:[NSAttributeDescription class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                   [NSString stringWithFormat:@"%@.%@: a batch update sets attributes", entity.name, name]);
      return nil;
    }
    NSAttributeDescription *attribute = (NSAttributeDescription *)property;
    if ([_mapper attributeHoldsDynamicProperties:attribute]) {
      // Each entry set on every object; the rest left as they are, which
      // one PATCH cannot know.
      if (![value isKindOfClass:[NSDictionary class]]) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                     [NSString stringWithFormat:@"%@.%@: a batch update sets dynamic properties from a dictionary of them (NSNull removes one)", entity.name, name]);
        return nil;
      }
      [_mapper.values addDynamicProperties:value toJSON:body];
      [names addObject:name];
      continue;
    }
    body[[_mapper propertyForAttribute:attribute]] = value ? [_mapper.values JSONForCoreDataValue:value attribute:attribute] : [NSNull null];
    [names addObject:name];
  }
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity.name];
  fetch.predicate = request.predicate;
  fetch.includesSubentities = request.includesSubentities;
  NSArray *objectIDs = [self writeEach:@"PATCH" fetch:fetch body:body restrictions:restrictions context:context error:error];
  if (!objectIDs) return nil;
  NSMutableDictionary *updated = [NSMutableDictionary dictionary];
  for (NSManagedObjectID *oid in objectIDs) updated[oid] = names;
  [self recordInserted:@[] updated:updated deleted:@[] context:context];
  OISBatchUpdateResult *result = [[OISBatchUpdateResult alloc] init];
  result.storeResultType = request.resultType;
  result.storeResult = request.resultType == NSUpdatedObjectIDsResultType ? objectIDs
                     : request.resultType == NSUpdatedObjectsCountResultType ? @(objectIDs.count) : @YES;
  return result;
}

- (id)executeBatchDelete:(NSBatchDeleteRequest *)request context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSFetchRequest *fetch = [request.fetchRequest copy];
  NSEntityDescription *entity = [self resolvedEntity:fetch];
  id restrictions = [self capability:@"Capabilities.DeleteRestrictions" forEntity:entity];
  if ([restrictions isKindOfClass:[NSDictionary class]] && OISRefused(restrictions[@"Deletable"])) {
    if (error) *error = [self notAllowed:@"delete" entity:entity term:@"DeleteRestrictions"];
    return nil;
  }
  fetch.resultType = NSManagedObjectResultType;
  NSArray *objectIDs = [self writeEach:@"DELETE" fetch:fetch body:nil restrictions:restrictions context:context error:error];
  if (!objectIDs) return nil;
  for (NSManagedObjectID *oid in objectIDs) [self forgetObjectID:oid];
  [self recordInserted:@[] updated:@{} deleted:objectIDs context:context];
  OISBatchDeleteResult *result = [[OISBatchDeleteResult alloc] init];
  result.storeResultType = request.resultType;
  result.storeResult = request.resultType == NSBatchDeleteResultTypeObjectIDs ? objectIDs
                     : request.resultType == NSBatchDeleteResultTypeCount ? @(objectIDs.count) : @YES;
  return result;
}

// PATCH (with the body) or DELETE each object the fetch selects: the
// object IDs of those written; their rows, updated, kept.
- (NSArray *)writeEach:(NSString *)method fetch:(NSFetchRequest *)fetch body:(NSDictionary *)body
          restrictions:(id)restrictions context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSEntityDescription *entity = [self resolvedEntity:fetch];
  ODataQueryOptions *options = [_builder optionsForFetch:fetch entity:entity error:error];
  if (!options) return nil;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  BOOL segments = [_client.configuration.version isEqualToString:@"4.01"] &&
                  [restrictions isKindOfClass:[NSDictionary class]] && [restrictions[@"FilterSegmentSupported"] isEqual:@YES] &&
                  (entity == root || [restrictions[@"TypecastSegmentSupported"] isEqual:@YES]);
  // A filter segment says which, and nothing else: not how many, nor a
  // search, nor a time ($select and $expand are only what a read reads).
  BOOL filterOnly = !options.search && !options.apply.count && !options.compute.count && !options.temporalText.count &&
                    !fetch.fetchLimit && !fetch.fetchOffset && (fetch.includesSubentities || !entity.subentities.count);
  // The members' changed relationships are read again.
  [_lock lock];
  [_members removeAllObjects];
  [_lock unlock];
  if (segments && filterOnly) return [self sendEach:method entity:entity filter:options.filter body:body error:error];

  NSFetchRequest *ids = [fetch copy];
  ids.resultType = NSManagedObjectIDResultType;
  NSArray *objectIDs = [self executeFetch:ids context:context error:error];
  if (!objectIDs) return nil;
  NSMutableArray *operations = [NSMutableArray array];
  for (NSManagedObjectID *oid in objectIDs) {
    NSURL *url = [self editURLForObjectID:oid error:error];
    if (!url) return nil;
    NSMutableURLRequest *req = [_client requestWithMethod:method URL:url body:body etag:nil error:error];
    if (!req) return nil;
    OISOperation *operation = [self operation:req completion:^BOOL(ODataHTTPResponse *response, NSError **e) {
      id json = response.data.length ? [response JSONWithError:NULL] : nil;
      if ([json isKindOfClass:[NSDictionary class]]) [self cacheNodeForObjectID:oid entity:oid.entity payload:json error:nil];
      else [self discardCachedRowsForObjectIDs:@[ oid ]];
      return YES;
    }];
    operation.objectID = oid;
    [operations addObject:operation];
  }
  return [self sendOperations:operations error:error] ? objectIDs : nil;
}

// One request for them all: the rows it answers with are those written,
// entities for an update and removed entries, with their keys, for a
// delete.
- (NSArray *)sendEach:(NSString *)method entity:(NSEntityDescription *)entity filter:(ODataExpression *)filter
                 body:(NSDictionary *)body error:(NSError **)error
{
  NSString *path = [_mapper collectionPathForEntity:entity];
  ODataMutableQueryOptions *each = [[ODataMutableQueryOptions alloc] init];
  if (filter) {
    each.aliases = @{ @"f": filter };
    path = [path stringByAppendingString:@"/$filter(@f)"];
  }
  NSURL *url = [_builder URLForPath:[path stringByAppendingString:@"/$each"] options:each error:error];
  NSMutableURLRequest *req = url ? [_client requestWithMethod:method URL:url body:body etag:nil error:error] : nil;
  if (!req) return nil;
  [req setValue:@"return=representation" forHTTPHeaderField:@"Prefer"];
  ODataHTTPResponse *response = [_client sendRequest:req error:error];
  if (!response) return nil;
  id json = response.data.length ? [response JSONWithError:error] : @{};
  if (![json isKindOfClass:[NSDictionary class]]) return nil;
  [self noteMessagesIn:json URL:url objectID:nil];
  NSMutableArray *objectIDs = [NSMutableArray array];
  for (NSDictionary *row in [json[@"value"] isKindOfClass:[NSArray class]] ? json[@"value"] : @[]) {
    if (![row isKindOfClass:[NSDictionary class]]) continue;
    NSManagedObjectID *oid = [self objectIDFromPayload:row entity:entity error:error];
    if (!oid) return nil;
    if (!row[@"@odata.removed"] && !row[@"@removed"]) [self cacheNodeForObjectID:oid entity:oid.entity payload:row error:nil];
    [objectIDs addObject:oid];
  }
  return objectIDs;
}

#pragma mark - Remote changes

// The entities whose sets are tracked: the option's, or every entity with
// a set of its own (a sub-entity in its base's set is read with it).
- (NSArray *)trackedEntities
{
  NSManagedObjectModel *model = self.persistentStoreCoordinator.managedObjectModel;
  NSArray *named = self.options[ODataIncrementalStoreTrackedEntitiesOption];
  NSMutableArray *entities = [NSMutableArray array];
  if ([named isKindOfClass:[NSArray class]]) {
    for (NSString *name in named) {
      NSEntityDescription *entity = model.entitiesByName[name];
      if (entity) [entities addObject:entity];
    }
    return entities;
  }
  // The store's configuration's: the rest is another store's.
  NSArray *all = self.configurationName ? [model entitiesForConfiguration:self.configurationName] ?: @[] : model.entities;
  for (NSEntityDescription *entity in [all sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
         return [[a name] compare:[b name]];
       }]) {
    if ([self trackedEntityFor:entity] != entity) continue;
    ODataSchemaEntityType *type = [_mapper entityTypeForEntity:entity];
    if (_schema && type && ![_schema entitySetForEntityType:type] && [_schema entityTypeIsContained:type]) continue;
    [entities addObject:entity];
  }
  return entities;
}

// The entity whose set holds this one's rows.
- (NSEntityDescription *)trackedEntityFor:(NSEntityDescription *)entity
{
  NSEntityDescription *e = entity;
  while (e.superentity && [[_mapper entitySetForEntity:e] isEqualToString:[_mapper entitySetForEntity:e.superentity]]) e = e.superentity;
  return e;
}

// Rows compared without their control information, which changes with
// every read (a context, a session in a link) though the entity does not.
static BOOL OISSameRow(NSDictionary *a, NSDictionary *b)
{
  NSMutableDictionary *x = [NSMutableDictionary dictionary], *y = [NSMutableDictionary dictionary];
  for (NSString *key in a) if (![key hasPrefix:@"@"] || [key isEqualToString:@"@odata.etag"]) x[key] = a[key];
  for (NSString *key in b) if (![key hasPrefix:@"@"] || [key isEqualToString:@"@odata.etag"]) y[key] = b[key];
  return [x isEqualToDictionary:y];
}

// The names of the properties that differ between two rows of an object.
- (NSSet *)changedPropertiesFrom:(NSDictionary *)old to:(NSDictionary *)row entity:(NSEntityDescription *)entity
{
  NSMutableSet *names = [NSMutableSet set];
  for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
    if ([_mapper attributeHoldsDynamicProperties:attr]) {
      if (![[self dynamicPropertiesInPayload:old entity:entity] isEqual:[self dynamicPropertiesInPayload:row entity:entity]]) [names addObject:attr.name];
      continue;
    }
    NSString *wire = [_mapper propertyForAttribute:attr];
    id a = old[wire], b = row[wire];
    if (b && !(a == b || [a isEqual:b])) [names addObject:attr.name];
  }
  for (NSRelationshipDescription *rel in entity.relationshipsByName.allValues) {
    NSString *wire = [_mapper propertyForRelationship:rel];
    id a = old[wire], b = row[wire];
    if (b && !(a == b || [a isEqual:b])) [names addObject:rel.name];
  }
  return names;
}

// A known object the service names by URL (a deleted entity's id).
- (NSManagedObjectID *)objectIDNamed:(NSString *)url among:(NSDictionary *)rows
{
  NSString *decoded = [url stringByRemovingPercentEncoding] ?: url;
  for (NSManagedObjectID *oid in rows) {
    NSString *path = [ODataResourceIdentifier identifierFromReference:[self referenceObjectForObjectID:oid]].path;
    NSString *plain = [path stringByRemovingPercentEncoding] ?: path;
    if (plain.length && ([decoded hasSuffix:[@"/" stringByAppendingString:plain]] || [decoded isEqualToString:plain])) return oid;
    [_lock lock];
    NSURL *edit = _editLinks[oid];
    [_lock unlock];
    if (edit && [[[edit.absoluteString stringByRemovingPercentEncoding] ?: @"" lastPathComponent] isEqualToString:decoded.lastPathComponent]) return oid;
  }
  return nil;
}

- (void)bumpVersionForObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  _versions[objectID] = @([_versions[objectID] unsignedLongLongValue] + 1);
  [_lock unlock];
}

// One entry of a delta response (JSON Format section 15): an entity new
// or changed (perhaps only in part), a deleted one, a link added or taken
// away (a change to its source).
- (void)applyDeltaEntry:(NSDictionary *)entry
               tracking:(OISTracking *)tracking
                 entity:(NSEntityDescription *)entity
               inserted:(NSMutableArray *)inserted
                updated:(NSMutableDictionary *)updated
                deleted:(NSMutableArray *)deleted
{
  NSString *context = [entry[@"@odata.context"] isKindOfClass:[NSString class]] ? entry[@"@odata.context"] : @"";
  // What the entry is, by the end of its context: 4.0 has #Customers/$link,
  // 4.01 #$link as well (JSON Format section 15).
  NSRange cut = [context rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/#"] options:NSBackwardsSearch];
  NSString *kind = cut.location == NSNotFound ? @"" : [context substringFromIndex:cut.location + 1];
  if ([kind isEqualToString:@"$link"] || [kind isEqualToString:@"$deletedLink"]) {
    NSManagedObjectID *source = [entry[@"source"] isKindOfClass:[NSString class]] ? [self objectIDNamed:entry[@"source"] among:tracking.rows] : nil;
    if (!source) return;
    NSMutableSet *names = [updated[source] mutableCopy] ?: [NSMutableSet set];
    for (NSRelationshipDescription *rel in source.entity.relationshipsByName.allValues) {
      if ([[_mapper propertyForRelationship:rel] isEqual:entry[@"relationship"]]) [names addObject:rel.name];
    }
    updated[source] = names;
    [self discardCachedRowsForObjectIDs:@[ source ]];
    return;
  }
  if (entry[@"@odata.removed"] || [kind isEqualToString:@"$deletedEntity"]) {
    id name = entry[@"@odata.id"] ?: entry[@"id"];
    NSManagedObjectID *oid = [name isKindOfClass:[NSString class]] ? [self objectIDNamed:name among:tracking.rows]
                                                                   : [self objectIDFromPayload:entry entity:entity error:NULL];
    if (!oid) return;
    // Its last row stays: merging the deletion into a context fires the
    // object's fault, and the service no longer has it.
    [deleted addObject:oid];
    [tracking.rows removeObjectForKey:oid];
    return;
  }
  NSManagedObjectID *oid = [self objectIDFromPayload:entry entity:entity error:NULL];
  if (!oid && [entry[@"@odata.id"] isKindOfClass:[NSString class]]) oid = [self objectIDNamed:entry[@"@odata.id"] among:tracking.rows];
  if (!oid) return;
  id old = tracking.rows[oid];
  NSMutableDictionary *row = [old isKindOfClass:[NSDictionary class]] ? [old mutableCopy] : [NSMutableDictionary dictionary];
  [row addEntriesFromDictionary:entry];
  if (old) {
    NSMutableSet *names = [updated[oid] mutableCopy] ?: [NSMutableSet set];
    if ([old isKindOfClass:[NSDictionary class]]) [names unionSet:[self changedPropertiesFrom:old to:entry entity:oid.entity]];
    updated[oid] = names;
  } else {
    [inserted addObject:oid];
  }
  tracking.rows[oid] = row;
  [self cacheNodeForObjectID:oid entity:oid.entity payload:row error:NULL];
  [self bumpVersionForObjectID:oid];
}

- (BOOL)changesOfEntity:(NSEntityDescription *)entity
               inserted:(NSMutableArray *)inserted
                updated:(NSMutableDictionary *)updated
                deleted:(NSMutableArray *)deleted
                  error:(NSError **)error
{
  OISTracking *tracking = _tracking[entity.name];
  NSURL *deltaLink = nil;
  NSError *deltaError = nil;
  NSArray *entries = tracking.deltaLink ? [self rowsAtURL:tracking.deltaLink limit:0 pageSize:0 trackChanges:NO deltaLink:&deltaLink error:&deltaError] : nil;
  // 410 Gone: the service no longer follows the changes from there (its
  // history was purged, say); the set is read again and compared.
  if (tracking.deltaLink && !entries && deltaError.code != ODataIncrementalStoreErrorHTTP + 410) {
    if (error) *error = deltaError;
    return NO;
  }
  if (entries) {
    for (NSDictionary *entry in entries) {
      [self applyDeltaEntry:entry tracking:tracking entity:entity inserted:inserted updated:updated deleted:deleted];
    }
    // Without a new delta link (TripPin sends none), the next call reads
    // the whole set again and compares.
    tracking.deltaLink = deltaLink;
    return YES;
  }

  // The whole set, compared with what was read last time.
  NSURL *url = [_builder URLForFetch:[NSFetchRequest fetchRequestWithEntityName:entity.name] entity:entity error:error];
  NSArray *rows = url ? [self rowsAtURL:url limit:0 pageSize:0 trackChanges:YES deltaLink:&deltaLink error:error] : nil;
  if (!rows) return NO;
  NSMutableDictionary *now = [NSMutableDictionary dictionary];
  for (NSDictionary *row in rows) {
    NSManagedObjectID *oid = [self objectIDFromPayload:row entity:entity error:error];
    if (!oid) return NO;
    now[oid] = row;
    id old = tracking.rows[oid];
    if (tracking && !old) {
      [inserted addObject:oid];
    } else if ([old isKindOfClass:[NSDictionary class]] && !OISSameRow(old, row)) {
      updated[oid] = [self changedPropertiesFrom:old to:row entity:oid.entity];
      [self bumpVersionForObjectID:oid];
    }
    [self cacheNodeForObjectID:oid entity:oid.entity payload:row error:NULL];
  }
  for (NSManagedObjectID *oid in tracking.rows) {
    if (!now[oid]) [deleted addObject:oid];  // its last row stays, as for a delta's deletion
  }
  if (!tracking) {
    tracking = [[OISTracking alloc] init];
    _tracking[entity.name] = tracking;
  }
  tracking.rows = now;
  tracking.deltaLink = deltaLink;
  return YES;
}

- (NSNotification *)fetchRemoteChanges:(NSError **)error
{
  NSMutableArray *inserted = [NSMutableArray array];
  NSMutableDictionary *updated = [NSMutableDictionary dictionary];
  NSMutableArray *deleted = [NSMutableArray array];
  for (NSEntityDescription *entity in [self trackedEntities]) {
    if (![self changesOfEntity:entity inserted:inserted updated:updated deleted:deleted error:error]) return nil;
  }
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (inserted.count) info[NSInsertedObjectIDsKey] = [NSSet setWithArray:inserted];
  if (updated.count) info[NSUpdatedObjectIDsKey] = [NSSet setWithArray:updated.allKeys];
  if (deleted.count) info[NSDeletedObjectIDsKey] = [NSSet setWithArray:deleted];
  NSPersistentHistoryTransaction *transaction = [_history recordInserted:inserted updated:updated deleted:deleted
                                                                  author:ODataRemoteChangesAuthor contextName:nil];
  if (transaction && [self.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] boolValue]) {
    NSMutableDictionary *remote = [@{ NSStoreUUIDKey: self.identifier ?: @"", NSPersistentHistoryTokenKey: transaction.token } mutableCopy];
    if (self.URL) remote[@"storeURL"] = self.URL;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSPersistentStoreRemoteChangeNotification
                                                        object:self.persistentStoreCoordinator userInfo:remote];
  }
  return [NSNotification notificationWithName:NSManagedObjectContextDidSaveObjectIDsNotification object:self userInfo:info];
}

- (OISOperation *)operation:(NSURLRequest *)request completion:(BOOL (^)(ODataHTTPResponse *, NSError **))completion
{
  OISOperation *operation = [[OISOperation alloc] init];
  operation.request = request;
  operation.completion = completion;
  return operation;
}

// A save of two or more requests is one $batch change set, so it takes
// effect whole or not at all (Part 1 section 11.7.4). $batch is required
// only of Advanced services: one that answers the batch request itself
// with 400, 404, 405, 415 or 501 has run none of it, and gets the requests
// one at a time from then on. Any other failure fails the save: TripPin,
// for one, can apply part of a batch and then answer 500.
// A write refused for its ETag (412): the object changed at the service
// since it was read; or not found (404): it was deleted there. Its row is read again and kept, so its version moves
// on, and the save fails as Core Data's own stores fail one (the error
// NSPersistentStoreSaveConflictsError, its conflicts under
// NSPersistentStoreSaveConflictsErrorKey), with the service's values as
// the cached and persisted snapshots, or none for an object it no longer
// has. A merge policy can then settle it, and the save be tried again.
- (NSError *)saveConflictFor:(NSError *)failure operations:(NSArray *)operations save:(NSSaveChangesRequest *)save
{
  if (failure.code != ODataIncrementalStoreErrorOptimisticLocking && failure.code != ODataIncrementalStoreErrorHTTP + 404) return nil;
  NSURL *failed = failure.userInfo[NSURLErrorFailingURLErrorKey];
  NSMutableSet *objectIDs = [NSMutableSet set];
  for (OISOperation *operation in operations) {
    if (!operation.objectID) continue;
    // In a $batch the failed part is named; alone, the one sent last.
    if (!failed || [operation.request.URL.absoluteString isEqualToString:failed.absoluteString]) [objectIDs addObject:operation.objectID];
  }
  if (!objectIDs.count) return nil;
  NSMutableArray *conflicts = [NSMutableArray array];
  NSSet *changed = [save.updatedObjects setByAddingObjectsFromSet:save.deletedObjects ?: [NSSet set]];
  for (NSManagedObject *object in changed) {
    if (![objectIDs containsObject:object.objectID]) continue;
    uint64_t oldVersion = [self versionForObjectID:object.objectID];
    [self discardCachedRowsForObjectIDs:@[ object.objectID ]];
    NSError *readError = nil;
    NSIncrementalStoreNode *node = [self newValuesForObjectWithID:object.objectID withContext:object.managedObjectContext error:&readError];
    NSDictionary *snapshot = nil;
    if (node) {
      NSMutableDictionary *values = [NSMutableDictionary dictionary];
      for (NSPropertyDescription *property in object.entity.properties) {
        if (![property isKindOfClass:[NSAttributeDescription class]] && ![property isKindOfClass:[NSRelationshipDescription class]]) continue;
        if ([property isKindOfClass:[NSRelationshipDescription class]] && [(NSRelationshipDescription *)property isToMany]) continue;
        id value = [node valueForPropertyDescription:property];
        if (value) values[property.name] = value;
      }
      snapshot = values;
    } else if ([readError.userInfo[ODataErrorHTTPStatusKey] integerValue] != 404) {
      return nil;  // it cannot be told what the service has
    }
    NSMergeConflict *conflict = [[NSMergeConflict alloc] initWithSource:object
                                                             newVersion:(NSUInteger)(node ? node.version : oldVersion + 1)
                                                             oldVersion:(NSUInteger)oldVersion
                                                         cachedSnapshot:snapshot
                                                      persistedSnapshot:snapshot];
    [conflicts addObject:conflict];
  }
  if (!conflicts.count) return nil;
  return [NSError errorWithDomain:NSCocoaErrorDomain code:NSPersistentStoreSaveConflictsError userInfo:@{
    NSLocalizedDescriptionKey: @"The service has changed what this save changes",
    NSPersistentStoreSaveConflictsErrorKey: conflicts,
    NSUnderlyingErrorKey: failure }];
}

- (BOOL)sendOperations:(NSArray *)operations error:(NSError **)error
{
  if (!operations.count) return YES;
  id batchSupport = [_schema capability:@"Capabilities.BatchSupport" forEntitySet:nil];
  BOOL batchable = !OISRefused([_schema capability:@"Capabilities.BatchSupported" forEntitySet:nil]) &&
                   !([batchSupport isKindOfClass:[NSDictionary class]] && OISRefused(batchSupport[@"Supported"]));
  BOOL batch = operations.count > 1 && _client.configuration.batchSaves && !_batchRefused && batchable;
  if (batch) {
    NSMutableArray *requests = [NSMutableArray array];
    for (OISOperation *operation in operations) [requests addObject:operation.request];
    NSError *batchError = nil;
    NSArray *responses = [_client sendChangeSet:requests error:&batchError];
    if (responses) {
      for (NSUInteger i = 0; i < operations.count; i++) {
        OISOperation *operation = operations[i];
        if (operation.completion && !operation.completion(responses[i], error)) return NO;
        [self noteMessagesOf:responses[i] operation:operation];
      }
      return YES;
    }
    NSURL *failed = batchError.userInfo[NSURLErrorFailingURLErrorKey];
    NSInteger status = [batchError.userInfo[ODataErrorHTTPStatusKey] integerValue];
    BOOL refused = [failed.path hasSuffix:@"$batch"] &&
                   (status == 400 || status == 404 || status == 405 || status == 415 || status == 501);
    if (!refused) {
      if (error) *error = batchError;
      return NO;
    }
    // Refused as JSON: multipart, which every service with $batch reads,
    // from then on.
    if (_client.configuration.JSONBatch) {
      _client.configuration.JSONBatch = NO;
      return [self sendOperations:operations error:error];
    }
    _batchRefused = YES;
  }
  for (OISOperation *operation in operations) {
    ODataHTTPResponse *response = [_client sendRequest:operation.request error:error];
    if (!response) return NO;
    if (operation.completion && !operation.completion(response, error)) return NO;
    [self noteMessagesOf:response operation:operation];
  }
  return YES;
}

- (BOOL)addPostOf:(OISWrite *)write object:(NSManagedObject *)object to:(NSMutableArray *)operations error:(NSError **)error
{
  NSEntityDescription *entity = object.entity;
  NSManagedObjectID *objectID = object.objectID;
  NSURL *url = [_client.configuration.serviceRoot URLByAppendingPathComponent:[_mapper entitySetForEntity:entity]];
  NSMutableURLRequest *request = [_client requestWithMethod:@"POST" URL:url body:write.body etag:nil error:error];
  if (!request) return NO;
  OISOperation *post = [self operation:request completion:^BOOL(ODataHTTPResponse *response, NSError **e) {
    NSDictionary *payload = [self createdEntityFrom:response URL:url error:e];
    if (!payload) return NO;
    [self cacheNodeForObjectID:objectID entity:entity payload:payload error:nil];
    return YES;
  }];
  post.objectID = objectID;
  [operations addObject:post];
  return YES;
}

// PATCH the body, if there is one, with the entity's ETag; then the $ref
// requests. Nothing at all for an object with nothing to send, such as the
// to-many side of a relationship whose to-one side was bound.
- (BOOL)addPatchOf:(OISWrite *)write object:(NSManagedObject *)object to:(NSMutableArray *)operations error:(NSError **)error
{
  if (write.body.count) {
    NSURL *url = [self editURLForObjectID:object.objectID error:error];
    NSMutableURLRequest *request = url ? [_client requestWithMethod:@"PATCH" URL:url body:write.body
                                                               etag:[self currentETagForObjectID:object.objectID] error:error] : nil;
    if (!request) return NO;
    OISOperation *patch = [self operation:request completion:^BOOL(ODataHTTPResponse *response, NSError **e) {
      [self absorbResponse:response object:object URL:url];
      return YES;
    }];
    patch.objectID = object.objectID;
    [operations addObject:patch];
  }
  return [self addReferencesOf:write to:operations error:error];
}

- (BOOL)addReferencesOf:(OISWrite *)write to:(NSMutableArray *)operations error:(NSError **)error
{
  for (NSArray *reference in write.references) {
    id body = reference[2] == [NSNull null] ? nil : reference[2];
    NSMutableURLRequest *request = [_client requestWithMethod:reference[0] URL:reference[1] body:body etag:nil error:error];
    if (!request) return NO;
    [operations addObject:[self operation:request completion:nil]];
  }
  return YES;
}

// POST to the entity set now, outside any save: the entity as created.
- (NSDictionary *)postWrite:(OISWrite *)write entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSURL *url = [_client.configuration.serviceRoot URLByAppendingPathComponent:[_mapper entitySetForEntity:entity]];
  ODataHTTPResponse *response = [_client sendJSONMethod:@"POST" URL:url body:write.body etag:nil error:error];
  return response ? [self createdEntityFrom:response URL:url error:error] : nil;
}

// The entity a POST created. Prefer asks for it in the response; a service
// that answers 204 anyway gives its URL in Location (Part 1 section
// 11.4.2), which is read back.
- (NSDictionary *)createdEntityFrom:(ODataHTTPResponse *)response URL:(NSURL *)url error:(NSError **)error
{
  id json = response.data.length ? [response JSONWithError:NULL] : nil;
  if (![json isKindOfClass:[NSDictionary class]]) {
    NSString *location = [response valueForHeader:@"Location"] ?: [response valueForHeader:@"OData-EntityId"];
    NSURL *created = location.length ? [NSURL URLWithString:location relativeToURL:url].absoluteURL : nil;
    if (!created) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"POST %@ returned neither the entity nor its Location", url.lastPathComponent]);
      return nil;
    }
    json = [_client JSONAtURL:created error:error];
    if (!json) return nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Expected an entity at %@", created]);
      return nil;
    }
  }
  if (!json[@"@odata.etag"] && response.etag) {
    NSMutableDictionary *tagged = [json mutableCopy];
    tagged[@"@odata.etag"] = response.etag;
    json = tagged;
  }
  return json;
}

// After a PATCH: the entity as the service now has it. From the body when
// it sent one; else the object's own values, which the service just
// accepted, under the new ETag from the header. With neither body nor
// ETag header, an entity that had an ETag is read back, since sending the
// old one would fail the next write with 412.
- (void)absorbResponse:(ODataHTTPResponse *)response object:(NSManagedObject *)object URL:(NSURL *)url
{
  NSManagedObjectID *objectID = object.objectID;
  NSEntityDescription *entity = object.entity;
  id json = response.data.length ? [response JSONWithError:NULL] : nil;
  if ([json isKindOfClass:[NSDictionary class]]) {
    if (!json[@"@odata.etag"] && response.etag) {
      NSMutableDictionary *tagged = [json mutableCopy];
      tagged[@"@odata.etag"] = response.etag;
      json = tagged;
    }
    [self cacheNodeForObjectID:objectID entity:entity payload:json error:nil];
    return;
  }
  [_lock lock];
  BOOL hadETag = _etags[objectID] != nil;
  [_lock unlock];
  if (!response.etag.length && hadETag) {
    id fresh = [_client JSONAtURL:url error:NULL];
    if ([fresh isKindOfClass:[NSDictionary class]]) {
      [self cacheNodeForObjectID:objectID entity:entity payload:fresh error:nil];
      return;
    }
    [_lock lock];
    [_etags removeObjectForKey:objectID];
    [_lock unlock];
  }
  [self rememberETag:response.etag forObjectID:objectID];
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *name in entity.attributesByName) {
    id value = [object valueForKey:name];
    if (value) values[name] = value;
  }
  NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID
                                                                       withValues:values
                                                                          version:[self versionForObjectID:objectID]];
  [_lock lock];
  _nodeCache[objectID] = node;
  [_lock unlock];
}

#pragma mark - Mapping

// Whether this side of a relationship is written. Core Data changes both
// sides of a relationship, and the service needs to hear it once:
// - to-one: always, as a bind;
// - to-many opposite a to-one: never, the to-one side's bind says it;
// - many-to-many: from one side only, the first by entity and then
//   relationship name;
// - to-many with no inverse: always.
- (BOOL)writesRelationship:(NSRelationshipDescription *)rel
{
  if (![_mapper servesProperty:rel]) return NO;
  if (!rel.isToMany) return YES;
  NSRelationshipDescription *inverse = rel.inverseRelationship;
  // An inverse the service does not serve cannot write the link: this does.
  if (!inverse || ![_mapper servesProperty:inverse]) return YES;
  if (!inverse.isToMany) return NO;
  NSComparisonResult order = [rel.entity.name compare:inverse.entity.name];
  if (order == NSOrderedSame) order = [rel.name compare:inverse.name];
  return order != NSOrderedDescending;
}

static BOOL OISKeyIsSet(id value)
{
  if (!value || value == [NSNull null]) return NO;
  if ([value isKindOfClass:[NSNumber class]]) return [value longLongValue] != 0;
  if ([value isKindOfClass:[NSString class]]) return [value length] > 0;
  return YES;
}

// The resource path of a related object ("Categories(2)"), or nil while it
// is unsaved. `assigned` maps the temporary IDs of objects inserted earlier
// in the same batch to their new permanent IDs.
- (NSString *)entityPathForObject:(NSManagedObject *)target assigned:(NSDictionary *)assigned
{
  NSManagedObjectID *oid = target.objectID;
  if (oid.isTemporaryID) oid = assigned[oid];
  if (!oid || oid.isTemporaryID) return nil;
  return [ODataResourceIdentifier identifierFromReference:[self referenceObjectForObjectID:oid]].path;
}

- (ODataClient *)client
{
  return _client;
}

- (ODataPropertyMapper *)mapper
{
  return _mapper;
}

- (NSURL *)canonicalURLForObjectID:(NSManagedObjectID *)objectID error:(NSError **)error
{
  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:error];
  return identifier ? [self absoluteURLForPath:identifier.path] : nil;
}

- (NSURL *)absoluteURLForPath:(NSString *)path
{
  return [NSURL URLWithString:path relativeToURL:_client.configuration.serviceRoot].absoluteURL;
}

- (NSManagedObjectID *)objectIDOf:(id)value
{
  return [value isKindOfClass:[NSManagedObject class]] ? [value objectID] : value;
}

// What a PATCH says of dynamic properties that were old and are now new:
// each one that differs, and null for each one gone (a POST: old is nil).
static NSDictionary *OISDynamicChanges(id old, id now)
{
  NSDictionary *before = [old isKindOfClass:[NSDictionary class]] ? old : @{};
  NSDictionary *after = [now isKindOfClass:[NSDictionary class]] ? now : @{};
  NSMutableDictionary *changes = [NSMutableDictionary dictionary];
  for (NSString *name in after) {
    if (![after[name] isEqual:before[name]]) changes[name] = after[name];
  }
  for (NSString *name in before) {
    if (!after[name]) changes[name] = [NSNull null];
  }
  return changes;
}

- (OISWrite *)writeForObject:(NSManagedObject *)object mode:(OISWriteMode)mode assigned:(NSDictionary *)assigned
{
  OISWrite *write = [[OISWrite alloc] init];
  NSEntityDescription *entity = object.entity;
  NSDictionary *changed = mode == OISWriteUpdate ? [object changedValues] : nil;
  NSSet *only = nil;
  if (mode == OISWriteDeferred) {
    [_lock lock];
    only = _deferred[object.objectID];
    [_lock unlock];
  }

  if (mode == OISWriteInsert && [_mapper entityIsDerivedInItsSet:entity]) {
    write.body[@"@odata.type"] = [@"#" stringByAppendingString:[_mapper qualifiedTypeForEntity:entity]];
  }
  NSSet *unwritable = [self unwritablePropertiesOf:entity insert:mode == OISWriteInsert];
  if (mode != OISWriteDeferred) {
    NSMutableSet *keyNames = [NSMutableSet set];
    for (NSAttributeDescription *attr in [_mapper keyAttributesForEntity:entity]) [keyNames addObject:attr.name];
    for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
      NSString *name = attr.name;
      if (attr.isTransient || ![_mapper servesProperty:attr]) continue;  // not the service's
      id value = [object primitiveValueForKey:name];
      if ([keyNames containsObject:name]) {
        // A key goes in a POST only when the client chose it; the service
        // assigns the rest. Keys are never PATCHed.
        if (mode == OISWriteInsert && OISKeyIsSet(value)) write.body[[_mapper propertyForAttribute:attr]] = [_mapper.values JSONForCoreDataValue:value attribute:attr];
        continue;
      }
      if (mode == OISWriteUpdate && !changed[name]) continue;
      if ([_mapper attributeHoldsDynamicProperties:attr]) {
        NSDictionary *old = mode == OISWriteUpdate ? [object committedValuesForKeys:@[ name ]][name] : nil;
        [_mapper.values addDynamicProperties:OISDynamicChanges(old, value) toJSON:write.body];
        continue;
      }
      // What the service sets (Core.Computed, read only), and after the
      // entity is made, what it will not change (Core.Immutable).
      if ([_mapper attributeIsComputed:attr]) continue;
      if (mode == OISWriteUpdate && [_mapper attributeIsImmutable:attr]) continue;
      if ([unwritable containsObject:[_mapper propertyForAttribute:attr]]) continue;
      id json = [_mapper.values JSONForCoreDataValue:value attribute:attr];
      // POST omits unset optional properties (section 11.4.2); PATCH sends
      // null to clear one.
      if (mode == OISWriteInsert && json == [NSNull null]) continue;
      write.body[[_mapper propertyForAttribute:attr]] = json;
    }
  }

  NSURL *entityURL = mode == OISWriteInsert ? nil : [self editURLForObjectID:object.objectID error:NULL];
  NSArray *relationships = [entity.relationshipsByName.allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a name] compare:[b name]];
  }];
  for (NSRelationshipDescription *rel in relationships) {
    NSString *name = rel.name;
    if (![self writesRelationship:rel]) continue;
    if (only && ![only containsObject:name]) continue;
    if (mode == OISWriteUpdate && !changed[name]) continue;
    NSString *wire = [_mapper propertyForRelationship:rel];
    NSString *bindKey = [wire stringByAppendingString:@"@odata.bind"];
    NSURL *refURL = entityURL ? [NSURL URLWithString:[entityURL.absoluteString stringByAppendingFormat:@"/%@/$ref", wire]] : nil;

    if (!rel.isToMany) {
      NSManagedObject *target = [object valueForKey:name];
      if (mode == OISWriteInsert) {
        // A bind in the POST: the only way to create an entity whose
        // relationship is required (JSON Format section 8.5).
        if (!target) continue;
        NSString *path = [self entityPathForObject:target assigned:assigned];
        if (path) write.body[bindKey] = path;
        else [write.deferred addObject:name];
        continue;
      }
      // Changing an existing entity's reference: PUT or DELETE its $ref
      // (Part 1 sections 11.4.6.3, 11.4.6.2). A bind in a PATCH is allowed
      // too, but TripPin answers 204 and ignores it.
      if (!refURL) continue;
      if (target) {
        NSString *path = [self entityPathForObject:target assigned:assigned];
        if (!path) continue;
        NSDictionary *reference = @{ @"@odata.id": [self absoluteURLForPath:path].absoluteString };
        [write.references addObject:@[ @"PUT", refURL, reference ]];
      } else {
        [write.references addObject:@[ @"DELETE", refURL, [NSNull null] ]];
      }
      continue;
    }

    NSSet *current = [object valueForKey:name] ?: [NSSet set];
    if (mode == OISWriteInsert) {
      NSMutableArray *paths = [NSMutableArray array];
      for (NSManagedObject *target in current) {
        NSString *path = [self entityPathForObject:target assigned:assigned];
        if (!path) {
          paths = nil;
          [write.deferred addObject:name];
          break;
        }
        [paths addObject:path];
      }
      if (paths.count) write.body[bindKey] = paths;
      continue;
    }
    // Update, or deferred from an insert (where nothing was committed):
    // POST a reference for each addition, DELETE one for each removal.
    NSMutableSet *before = [NSMutableSet set];
    if (mode == OISWriteUpdate) {
      id committed = [object committedValuesForKeys:@[ name ]][name];
      for (id value in ([committed isKindOfClass:[NSSet class]] ? committed : @[])) [before addObject:[self objectIDOf:value]];
    }
    NSMutableSet *after = [NSMutableSet set];
    for (NSManagedObject *target in current) {
      NSManagedObjectID *oid = target.objectID;
      [after addObject:oid];
      if ([before containsObject:oid]) continue;
      NSString *path = [self entityPathForObject:target assigned:assigned];
      if (!path || !refURL) continue;
      NSDictionary *reference = @{ @"@odata.id": [self absoluteURLForPath:path].absoluteString };
      [write.references addObject:@[ @"POST", refURL, reference ]];
    }
    for (NSManagedObjectID *oid in before) {
      if ([after containsObject:oid] || !entityURL) continue;
      ODataResourceIdentifier *gone = [self identifierFromObjectID:oid error:NULL];
      NSURL *url = gone ? [_builder URLForReferenceFromEntityURL:entityURL
                                                    relationship:rel
                                                          target:[self absoluteURLForPath:gone.path]] : nil;
      if (url) [write.references addObject:@[ @"DELETE", url, [NSNull null] ]];
    }
  }
  return write;
}

- (NSDictionary *)dictionaryFromPayload:(NSDictionary *)payload
                                 entity:(NSEntityDescription *)entity
                             properties:(NSArray *)properties
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSArray *wanted = properties.count ? properties : entity.attributesByName.allKeys;
  for (id prop in wanted) {
    if ([prop isKindOfClass:[NSExpressionDescription class]] && !OISKeyPathOf(prop)) {
      // $compute's: typed as the description says.
      id raw = payload[[prop name]];
      if (!raw || raw == [NSNull null]) continue;
      NSAttributeDescription *typed = [[NSAttributeDescription alloc] init];
      typed.name = [prop name];
      typed.attributeType = [(NSExpressionDescription *)prop expressionResultType];
      id value = typed.attributeType == NSUndefinedAttributeType ? raw : [_mapper.values coreDataValueForJSON:raw attribute:typed];
      if (value) out[[prop name]] = value;
      continue;
    }
    NSString *name = [prop isKindOfClass:[NSPropertyDescription class]] ? [prop name] : prop;
    NSString *attributeName = [prop isKindOfClass:[NSExpressionDescription class]] ? OISKeyPathOf(prop) : name;
    NSArray *parts = [attributeName componentsSeparatedByString:@"."];
    if (parts.count && [_mapper attributeHoldsDynamicProperties:entity.attributesByName[parts[0]]]) {
      // The bag, or one of its entries (dynamicProperties.Nickname).
      id value = [self dynamicPropertiesInPayload:payload entity:entity];
      for (NSUInteger i = 1; i < parts.count; i++) value = [value isKindOfClass:[NSDictionary class]] ? value[parts[i]] : nil;
      if (value) out[name] = value;
      continue;
    }
    if (attributeName && [attributeName rangeOfString:@"."].location != NSNotFound) {
      // Through to-one relationships: in the expanded rows.
      id value = [self valueAtKeyPath:attributeName inPayload:payload entity:entity];
      if (value) out[name] = value;
      continue;
    }
    NSAttributeDescription *attr = attributeName ? entity.attributesByName[attributeName] : nil;
    if (!attr) continue;
    id raw = payload[[_mapper propertyForAttribute:attr]];
    id value = raw ? [_mapper.values coreDataValueForJSON:raw attribute:attr] : nil;
    if (value) out[name] = value;
  }
  return out;
}

// A key path through to-one relationships, read from a row and the rows
// expanded into it.
- (id)valueAtKeyPath:(NSString *)keyPath inPayload:(NSDictionary *)payload entity:(NSEntityDescription *)entity
{
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  id json = payload;
  NSEntityDescription *at = entity;
  for (NSUInteger i = 0; i + 1 < parts.count; i++) {
    NSRelationshipDescription *relationship = at.relationshipsByName[parts[i]];
    if (!relationship || relationship.isToMany || ![json isKindOfClass:[NSDictionary class]]) return nil;
    json = json[[_mapper propertyForRelationship:relationship]];
    at = relationship.destinationEntity;
  }
  NSAttributeDescription *attribute = at.attributesByName[parts.lastObject];
  id raw = [json isKindOfClass:[NSDictionary class]] && attribute ? json[[_mapper propertyForAttribute:attribute]] : nil;
  return raw && raw != [NSNull null] ? [_mapper.values coreDataValueForJSON:raw attribute:attribute] : nil;
}

- (NSManagedObjectID *)objectIDFromPayload:(NSDictionary *)payload
                                    entity:(NSEntityDescription *)entity
                                     error:(NSError **)error
{
  // A row of a derived type says so (JSON Format section 4.5.3): its object
  // is of the sub-entity standing for that type.
  entity = [_mapper entity:entity forTypeName:payload[@"@odata.type"]];
  NSArray *keyAttrs = [_mapper keyAttributesForEntity:entity];
  if (!keyAttrs.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingKey, entity.name ?: @"?");
    return nil;
  }
  NSMutableDictionary *keys = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attr in keyAttrs) {
    NSString *wire = [_mapper propertyForAttribute:attr];
    id raw = payload[wire] ?: payload[attr.name];
    // With IEEE754Compatible an Int64 key arrives as "1": decoded, it is
    // the same key, and the same object ID, as 1.
    id value = raw ? [self referenceValue:[_mapper.values coreDataValueForJSON:raw attribute:attr]] : nil;
    if (!value || value == [NSNull null]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Missing key %@", wire]);
      return nil;
    }
    keys[wire] = value;
  }
  ODataResourceIdentifier *identifier = [self identifierForEntity:entity keys:keys];
  NSManagedObjectID *oid = [self newObjectIDForEntity:entity referenceObject:identifier.data];
  // No ETag from here: this may be a reference ($select=ProductID inside
  // another row), whose ETag is the entity's current one while the row the
  // store keeps may be older. Taking it would send the next update with an
  // ETag the kept values do not have, and a change made meanwhile would be
  // overwritten. -cacheNodeForObjectID: takes it with the row.
  // An edit link is sent when writes go somewhere other than the entity's
  // conventional URL (JSON Format section 4.5.8); 4.01 drops the "odata."
  id editLink = payload[@"@odata.editLink"];
  if ([editLink isKindOfClass:[NSString class]]) {
    NSURL *resolved = [NSURL URLWithString:editLink relativeToURL:_client.configuration.serviceRoot].absoluteURL;
    if (resolved) {
      [_lock lock];
      _editLinks[oid] = resolved;
      [_lock unlock];
    }
  }
  return oid;
}

// What an entity's JSON names that is declared: the model's properties,
// what it could not map (OData.unmapped), and, with $metadata, every
// property of the type and its base types. An open type's dynamic
// properties are the rest.
- (NSSet<NSString *> *)declaredNamesOfEntity:(NSEntityDescription *)entity
{
  NSMutableSet *names = [NSMutableSet set];
  for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
    if (![_mapper attributeHoldsDynamicProperties:attr]) [names addObject:[_mapper propertyForAttribute:attr]];
  }
  for (NSRelationshipDescription *rel in entity.relationshipsByName.allValues) [names addObject:[_mapper propertyForRelationship:rel]];
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    NSString *unmapped = e.userInfo[ODataUserInfoUnmapped];
    if ([unmapped isKindOfClass:[NSString class]] && unmapped.length) [names addObjectsFromArray:[unmapped componentsSeparatedByString:@","]];
  }
  ODataSchema *schema = _mapper.schema;
  for (ODataSchemaEntityType *t = [_mapper entityTypeForEntity:entity]; t; t = t.baseType ? [schema entityTypeNamed:t.baseType] : nil) {
    [names addObjectsFromArray:t.declaredProperties.allKeys];
    [names addObjectsFromArray:t.declaredNavigationProperties.allKeys];
  }
  return names;
}

// An open type's dynamic properties, from its JSON.
- (NSDictionary *)dynamicPropertiesInPayload:(NSDictionary *)payload entity:(NSEntityDescription *)entity
{
  return [_mapper.values dynamicPropertiesInJSON:payload declared:[self declaredNamesOfEntity:entity]];
}

- (NSIncrementalStoreNode *)cacheNodeForObjectID:(NSManagedObjectID *)objectID
                                          entity:(NSEntityDescription *)entity
                                         payload:(NSDictionary *)payload
                                           error:(NSError **)error
{
  (void)error;
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  [entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    // gnustep-base types this block (id, id, BOOL *): no generics to narrow it.
    NSString *name = key;
    NSAttributeDescription *attr = obj;
    (void)stop;
    if ([self->_mapper attributeHoldsDynamicProperties:attr]) {
      values[name] = [self dynamicPropertiesInPayload:payload entity:entity];
      return;
    }
    id raw = payload[[self->_mapper propertyForAttribute:attr]];
    id value = raw ? [self->_mapper.values coreDataValueForJSON:raw attribute:attr] : nil;
    // A value that cannot be this attribute's type (a date that does not
    // parse) is left out rather than stored as the wrong class, and so is
    // null: an attribute that is nil has no value in a node. NSNull there
    // is taken for the value, and a Date attribute holding it crashes.
    if (value && value != [NSNull null]) values[name] = value;
  }];
  // Expanded navigation properties: a to-one's object ID goes in the node,
  // so Core Data need not ask for it; a related entity that came whole is
  // cached in its own right.
  for (NSRelationshipDescription *rel in entity.relationshipsByName.allValues) {
    id inline_ = payload[[_mapper propertyForRelationship:rel]];
    NSEntityDescription *destination = rel.destinationEntity;
    if (!inline_ || !destination) continue;
    if (!rel.isToMany) {
      if (inline_ == [NSNull null]) {
        values[rel.name] = [NSNull null];
      } else if ([inline_ isKindOfClass:[NSDictionary class]]) {
        NSManagedObjectID *related = [self objectIDFromPayload:inline_ entity:destination error:NULL];
        if (!related) continue;
        values[rel.name] = related;
        if ([self payloadIsWhole:inline_ entity:related.entity]) [self cacheNodeForObjectID:related entity:related.entity payload:inline_ error:NULL];
      }
    } else if ([inline_ isKindOfClass:[NSArray class]]) {
      // The members too, when they all came: none unnamed, and no
      // Nav@odata.nextLink to more.
      NSMutableArray *members = payload[[[_mapper propertyForRelationship:rel] stringByAppendingString:@"@odata.nextLink"]] ? nil : [NSMutableArray array];
      for (NSDictionary *row in inline_) {
        NSManagedObjectID *related = [row isKindOfClass:[NSDictionary class]] ? [self objectIDFromPayload:row entity:destination error:NULL] : nil;
        if (!related) {
          members = nil;
          continue;
        }
        [members addObject:related];
        if ([self payloadIsWhole:row entity:destination]) [self cacheNodeForObjectID:related entity:related.entity payload:row error:NULL];
      }
      [_lock lock];
      if (members) {
        if (!_members[objectID]) _members[objectID] = [NSMutableDictionary dictionary];
        _members[objectID][rel.name] = [members copy];
      } else {
        [_members[objectID] removeObjectForKey:rel.name];
      }
      [_lock unlock];
    }
  }
  // What the service does not serve: as it was saved here, else nothing.
  [_lock lock];
  NSDictionary *kept = [_kept[objectID] copy];
  [_lock unlock];
  for (NSString *name in kept) {
    NSPropertyDescription *property = entity.propertiesByName[name];
    if ([property isKindOfClass:[NSRelationshipDescription class]] && [(NSRelationshipDescription *)property isToMany]) continue;
    if (kept[name] != [NSNull null] || [property isKindOfClass:[NSRelationshipDescription class]]) values[name] = kept[name];
  }
  [self rememberETag:payload[@"@odata.etag"] forObjectID:objectID];
  [self rememberStreamsIn:payload objectID:objectID];
  uint64_t version = [self versionForObjectID:objectID];
  NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:values version:version];
  [_lock lock];
  _nodeCache[objectID] = node;
  [_lock unlock];
  return node;
}

// Whether an inline entity carries more than its key. A key-only one
// ($select=Key) names the entity; caching it would replace a good row
// with an empty one.
- (BOOL)payloadIsWhole:(NSDictionary *)payload entity:(NSEntityDescription *)entity
{
  NSMutableSet *keys = [NSMutableSet set];
  for (NSAttributeDescription *key in [_mapper keyAttributesForEntity:entity]) [keys addObject:key.name];
  for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
    if (![keys containsObject:attr.name] && payload[[_mapper propertyForAttribute:attr]]) return YES;
  }
  return NO;
}

#pragma mark - Streams

// Its media resource (@"") if it is a media entity, and its stream
// properties, as the schema has them; @"" alone without one.
- (NSArray<NSString *> *)streamNamesOfEntity:(NSEntityDescription *)entity
{
  ODataSchemaEntityType *type = [_mapper entityTypeForEntity:entity];
  if (!type) return @[ @"" ];
  NSMutableArray *names = [NSMutableArray array];
  if ([_schema entityTypeHasStream:type]) [names addObject:@""];
  [names addObjectsFromArray:[_schema streamPropertiesOfEntityType:type]];
  return names;
}

// What a row says of its streams (JSON Format sections 4.5.10-13): each
// one's links, media ETag and content type. A stream the row says nothing
// of is at its conventional URL, and has no ETag to trust.
- (void)rememberStreamsIn:(NSDictionary *)payload objectID:(NSManagedObjectID *)objectID
{
  NSMutableDictionary *found = [NSMutableDictionary dictionary];
  for (NSString *name in [self streamNamesOfEntity:objectID.entity]) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    for (NSString *what in @[ @"mediaReadLink", @"mediaEditLink", @"mediaEtag", @"mediaContentType" ]) {
      id value = payload[[NSString stringWithFormat:@"%@@odata.%@", name, what]];
      if ([value isKindOfClass:[NSString class]]) info[what] = value;
    }
    if (info.count) found[name] = info;
  }
  [_lock lock];
  if (found.count) _streams[objectID] = found;
  else [_streams removeObjectForKey:objectID];
  [_lock unlock];
}

- (NSString *)streamNamed:(NSString *)name objectID:(NSManagedObjectID *)objectID error:(NSError **)error
{
  NSArray *names = [self streamNamesOfEntity:objectID.entity];
  NSString *spelled = name.length ? ODataSchemaSpelling(name, names) : @"";
  // Without $metadata any name is taken on trust.
  if ([names containsObject:spelled] || ![_mapper entityTypeForEntity:objectID.entity]) return spelled;
  if (error) *error = OISError(ODataIncrementalStoreErrorNoStream, name.length
      ? [NSString stringWithFormat:@"%@ has no stream property %@", objectID.entity.name, name]
      : [NSString stringWithFormat:@"%@ is not a media entity", objectID.entity.name]);
  return nil;
}

- (NSDictionary *)streamInfo:(NSString *)name objectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  NSDictionary *info = [_streams[objectID][name] copy];
  [_lock unlock];
  return info ?: @{};
}

// A link from a row, or the stream's conventional URL: the entity's, then
// /$value or /Name.
- (NSURL *)streamURL:(NSString *)name objectID:(NSManagedObjectID *)objectID link:(NSString *)link error:(NSError **)error
{
  if (link.length) {
    NSURL *resolved = [NSURL URLWithString:link relativeToURL:_client.configuration.serviceRoot].absoluteURL;
    if (resolved) return [self serviceURLForLink:resolved];
  }
  NSURL *entity = [self editURLForObjectID:objectID error:error];
  if (!entity) return nil;
  return [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", entity.absoluteString, name.length ? name : @"$value"]];
}

- (NSURL *)streamDirectory
{
  NSURL *given = self.options[ODataIncrementalStoreStreamDirectoryOption];
  if ([given isKindOfClass:[NSURL class]]) return given;
  NSString *path = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"ODataIncrementalStore"] stringByAppendingPathComponent:self.identifier ?: @"store"];
  return [NSURL fileURLWithPath:path isDirectory:YES];
}

// A file name for the stream: its path at the service, made safe.
- (NSString *)fileNameForStream:(NSString *)name objectID:(NSManagedObjectID *)objectID
{
  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:NULL];
  NSString *path = [NSString stringWithFormat:@"%@-%@", identifier.path ?: objectID.URIRepresentation.lastPathComponent, name.length ? name : @"value"];
  NSMutableString *safe = [NSMutableString string];
  NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
  for (NSUInteger i = 0; i < path.length; i++) {
    unichar c = [path characterAtIndex:i];
    [safe appendString:[allowed characterIsMember:c] || c == '-' || c == '.' ? [NSString stringWithCharacters:&c length:1] : @"_"];
  }
  return [NSString stringWithFormat:@"%@-%08lx", safe, (unsigned long)(path.hash & 0xffffffff)];
}

- (NSURL *)fileForStream:(NSString *)name objectID:(NSManagedObjectID *)objectID contentType:(NSString **)contentType error:(NSError **)error
{
  NSDictionary *info = [self streamInfo:name objectID:objectID];
  [_lock lock];
  NSDictionary *kept = [_streamFiles[objectID][name] copy];
  [_lock unlock];
  NSFileManager *files = [NSFileManager defaultManager];
  BOOL there = kept && [files fileExistsAtPath:[kept[@"file"] path]];
  // Current: the ETag the row gives is the one the file was downloaded at.
  if (there && info[@"mediaEtag"] && [info[@"mediaEtag"] isEqualToString:kept[@"etag"]]) {
    if (contentType) *contentType = kept[@"type"];
    return kept[@"file"];
  }
  NSURL *url = [self streamURL:name objectID:objectID link:info[@"mediaReadLink"] error:error];
  if (!url) return nil;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
  if (there && kept[@"etag"]) [request setValue:kept[@"etag"] forHTTPHeaderField:@"If-None-Match"];
  NSError *failure = nil;
  ODataHTTPResponse *response = [_client sendRequest:request error:&failure];
  if (!response && there && [failure.userInfo[ODataErrorHTTPStatusKey] integerValue] == 304) {
    if (contentType) *contentType = kept[@"type"];
    return kept[@"file"];
  }
  if (!response) {
    if (error) *error = failure;
    return nil;
  }
  if (response.status == 304 && there) {
    if (contentType) *contentType = kept[@"type"];
    return kept[@"file"];
  }
  if (response.status == 204) {
    if (error) *error = OISError(ODataIncrementalStoreErrorNoStream, [NSString stringWithFormat:@"Nothing is in %@", url]);
    return nil;
  }
  NSURL *directory = [self streamDirectory];
  if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
  NSURL *file = [directory URLByAppendingPathComponent:[self fileNameForStream:name objectID:objectID]];
  if (![response.data ?: [NSData data] writeToURL:file options:NSDataWritingAtomic error:error]) return nil;
  NSString *type = [response valueForHeader:@"Content-Type"] ?: info[@"mediaContentType"] ?: @"application/octet-stream";
  NSString *etag = response.etag ?: info[@"mediaEtag"];
  [self keepStreamFile:file name:name objectID:objectID etag:etag type:type];
  if (contentType) *contentType = type;
  return file;
}

- (void)keepStreamFile:(NSURL *)file name:(NSString *)name objectID:(NSManagedObjectID *)objectID etag:(NSString *)etag type:(NSString *)type
{
  NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:file forKey:@"file"];
  if (etag) entry[@"etag"] = etag;
  if (type) entry[@"type"] = type;
  [_lock lock];
  if (!_streamFiles[objectID]) _streamFiles[objectID] = [NSMutableDictionary dictionary];
  _streamFiles[objectID][name] = entry;
  // What is known of the stream now is what was just read or written.
  NSMutableDictionary *streams = [_streams[objectID] mutableCopy] ?: [NSMutableDictionary dictionary];
  NSMutableDictionary *info = [streams[name] mutableCopy] ?: [NSMutableDictionary dictionary];
  if (etag) info[@"mediaEtag"] = etag;
  else [info removeObjectForKey:@"mediaEtag"];
  if (type) info[@"mediaContentType"] = type;
  streams[name] = info;
  _streams[objectID] = streams;
  [_lock unlock];
}

- (BOOL)putStream:(NSString *)name objectID:(NSManagedObjectID *)objectID data:(NSData *)data
      contentType:(NSString *)contentType error:(NSError **)error
{
  NSDictionary *info = [self streamInfo:name objectID:objectID];
  NSURL *url = [self streamURL:name objectID:objectID link:info[@"mediaEditLink"] error:error];
  if (!url) return NO;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = data ? @"PUT" : @"DELETE";
  if (data) {
    request.HTTPBody = data;
    [request setValue:contentType.length ? contentType : @"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
  }
  if (info[@"mediaEtag"]) [request setValue:info[@"mediaEtag"] forHTTPHeaderField:@"If-Match"];
  ODataHTTPResponse *response = [_client sendRequest:request error:error];
  if (!response) return NO;
  // The entity may have changed with it (its version, say): read again.
  [self discardCachedRowsForObjectIDs:@[ objectID ]];
  if (!data) {
    [_lock lock];
    [_streamFiles[objectID] removeObjectForKey:name];
    NSMutableDictionary *streams = [_streams[objectID] mutableCopy];
    [streams removeObjectForKey:name];
    if (streams) _streams[objectID] = streams;
    [_lock unlock];
    return YES;
  }
  // The new media ETag: the response's, or, from a service that answers
  // with the entity instead (TripPin: 200, no ETag header), its row's.
  NSString *etag = response.etag;
  id body = response.status == 200 && response.data.length ? [response JSONWithError:NULL] : nil;
  if ([body isKindOfClass:[NSDictionary class]]) {
    [self cacheNodeForObjectID:objectID entity:objectID.entity payload:body error:NULL];
    etag = etag ?: [self streamInfo:name objectID:objectID][@"mediaEtag"];
  }
  // What was put is what is there: kept as downloaded, at the new ETag.
  NSURL *directory = [self streamDirectory];
  NSURL *file = [directory URLByAppendingPathComponent:[self fileNameForStream:name objectID:objectID]];
  if ([[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL] &&
      etag && [data writeToURL:file options:NSDataWritingAtomic error:NULL]) {
    [self keepStreamFile:file name:name objectID:objectID etag:etag type:contentType];
  } else {
    [_lock lock];
    [_streamFiles[objectID] removeObjectForKey:name];
    [_lock unlock];
  }
  return YES;
}

- (NSManagedObjectID *)postMediaEntity:(NSEntityDescription *)entity data:(NSData *)data
                           contentType:(NSString *)contentType error:(NSError **)error
{
  NSString *root = _client.configuration.serviceRoot.absoluteString ?: @"";
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSURL *url = [NSURL URLWithString:[root stringByAppendingString:[_mapper collectionPathForEntity:entity]]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = data;
  [request setValue:contentType.length ? contentType : @"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
  [request setValue:@"return=representation" forHTTPHeaderField:@"Prefer"];
  ODataHTTPResponse *response = [_client sendRequest:request error:error];
  if (!response) return nil;
  id json = [response JSONWithError:error];
  if (!json) return nil;
  if (![json isKindOfClass:[NSDictionary class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, @"A new media entity came back without its row");
    return nil;
  }
  NSManagedObjectID *objectID = [self objectIDFromPayload:json entity:entity error:error];
  if (!objectID) return nil;
  [self cacheNodeForObjectID:objectID entity:objectID.entity payload:json error:NULL];
  return objectID;
}

#pragma mark - ETags

// ETags are opaque (Part 1 section 11.4.1.1): kept exactly as the service
// sent them, and sent back unchanged in If-Match. A node's version only has
// to change when the ETag does.
- (void)rememberETag:(id)etag forObjectID:(NSManagedObjectID *)objectID
{
  if (![etag isKindOfClass:[NSString class]] || ![etag length]) return;
  [_lock lock];
  if (![_etags[objectID] isEqualToString:etag]) {
    _etags[objectID] = etag;
    _versions[objectID] = @([_versions[objectID] unsignedLongLongValue] + 1);
  }
  [_lock unlock];
}

- (uint64_t)versionForObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  uint64_t version = [_versions[objectID] unsignedLongLongValue];
  [_lock unlock];
  return version ?: 1;
}

// nil when the service has not given one: no If-Match is sent then, rather
// than one the service never issued.
- (NSString *)currentETagForObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  NSString *etag = _etags[objectID];
  [_lock unlock];
  return etag;
}

- (void)discardCachedRowsForObjectIDs:(NSArray *)objectIDs
{
  [_lock lock];
  if (objectIDs) [_nodeCache removeObjectsForKeys:objectIDs];
  else [_nodeCache removeAllObjects];
  if (objectIDs) [_members removeObjectsForKeys:objectIDs];
  else [_members removeAllObjects];
  [_lock unlock];
}

- (NSArray *)performTemporalAction:(NSString *)action onEntityNamed:(NSString *)entityName
                   deltaTimeslices:(NSArray *)deltas context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSEntityDescription *entity = self.persistentStoreCoordinator.managedObjectModel.entitiesByName[entityName];
  if (![@[ @"Update", @"Upsert", @"Delete" ] containsObject:action] || !entity) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                 [NSString stringWithFormat:@"Temporal.%@ on %@: Update, Upsert or Delete, on an entity of the model", action, entityName]);
    return nil;
  }
  NSMutableArray *slices = [NSMutableArray array];
  for (NSDictionary *delta in deltas) {
    NSMutableDictionary *json = [NSMutableDictionary dictionary];
    for (NSString *name in delta) {
      NSAttributeDescription *attribute = entity.attributesByName[name];
      if (!attribute) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                     [NSString stringWithFormat:@"%@ is not an attribute of %@: a delta time slice has attribute values", name, entityName]);
        return nil;
      }
      id value = delta[name];
      if ([_mapper attributeHoldsDynamicProperties:attribute]) {
        if ([value isKindOfClass:[NSDictionary class]]) [_mapper.values addDynamicProperties:value toJSON:json];
        continue;
      }
      json[[_mapper propertyForAttribute:attribute]] = value == [NSNull null] ? value : [_mapper.values JSONForCoreDataValue:value attribute:attribute];
    }
    [slices addObject:@{ @"Timeslice": json }];
  }
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  NSString *base = _client.configuration.serviceRoot.absoluteString ?: @"";
  if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@/Org.OData.Temporal.V1.%@", base, [_mapper collectionPathForEntity:root], action]];
  ODataHTTPResponse *response = [_client sendJSONMethod:@"POST" URL:url body:@{ @"deltaTimeslices": slices } etag:nil error:error];
  if (!response) return nil;
  id body = response.status == 204 ? @{} : [response JSONWithError:error];
  if (![body isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *item in [body[@"value"] isKindOfClass:[NSArray class]] ? body[@"value"] : @[]) {
    NSDictionary *slice = [item isKindOfClass:[NSDictionary class]] ? item[@"Timeslice"] : nil;
    if ([slice isKindOfClass:[NSDictionary class]]) [out addObject:[self dictionaryFromPayload:slice entity:entity properties:nil]];
  }
  // The timeline has changed: its rows are read again.
  [_lock lock];
  for (NSManagedObjectID *oid in _nodeCache.allKeys) {
    if ([oid.entity isKindOfEntity:root]) {
      [_nodeCache removeObjectForKey:oid];
      [_members removeObjectForKey:oid];
    }
  }
  [_lock unlock];
  for (NSManagedObject *object in context.registeredObjects.allObjects) {
    if ([object.entity isKindOfEntity:root] && !object.hasChanges) [context refreshObject:object mergeChanges:NO];
  }
  return out;
}

- (void)forgetObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  [_nodeCache removeObjectForKey:objectID];
  [_members removeObjectForKey:objectID];
  [_streams removeObjectForKey:objectID];
  [_streamFiles removeObjectForKey:objectID];
  [_etags removeObjectForKey:objectID];
  [_versions removeObjectForKey:objectID];
  [_deferred removeObjectForKey:objectID];
  [_editLinks removeObjectForKey:objectID];
  [_kept removeObjectForKey:objectID];
  [_lock unlock];
}

// Where an object is written: its edit link when the service gave one,
// else its conventional URL. An edit link on the service's own host keeps
// the service root's scheme and port: TripPin, served over HTTPS, writes
// http:// edit links, and a PATCH to one hangs.
- (NSURL *)editURLForObjectID:(NSManagedObjectID *)objectID error:(NSError **)error
{
  [_lock lock];
  NSURL *link = _editLinks[objectID];
  [_lock unlock];
  if (link) return [self serviceURLForLink:link];
  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:error];
  return identifier ? [_builder URLForIdentifier:identifier error:error] : nil;
}

// A link the service gave, on the service root's scheme and port when it
// is on its host.
- (NSURL *)serviceURLForLink:(NSURL *)link
{
  {
    NSURL *root = _client.configuration.serviceRoot;
    if ([link.host caseInsensitiveCompare:root.host ?: @""] != NSOrderedSame) return link;
    NSString *s = link.absoluteString;
    NSRange scheme = [s rangeOfString:@"://"];
    NSRange path = [s rangeOfString:@"/" options:0 range:NSMakeRange(NSMaxRange(scheme), s.length - NSMaxRange(scheme))];
    NSString *r = root.absoluteString;
    NSRange rootScheme = [r rangeOfString:@"://"];
    NSRange rootPath = [r rangeOfString:@"/" options:0 range:NSMakeRange(NSMaxRange(rootScheme), r.length - NSMaxRange(rootScheme))];
    if (scheme.location != NSNotFound && path.location != NSNotFound && rootPath.location != NSNotFound) {
      NSURL *rewritten = [NSURL URLWithString:[[r substringToIndex:rootPath.location] stringByAppendingString:[s substringFromIndex:path.location]]];
      if (rewritten) return rewritten;
    }
    return link;
  }
}

- (ODataResourceIdentifier *)identifierFromObjectID:(NSManagedObjectID *)objectID error:(NSError **)error
{
  id ref = [self referenceObjectForObjectID:objectID];
  ODataResourceIdentifier *identifier = [ODataResourceIdentifier identifierFromReference:ref];
  if (!identifier) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, @"Bad reference object");
    return nil;
  }
  return identifier;
}

- (NSDictionary *)clientKeysForObject:(NSManagedObject *)object error:(NSError **)error
{
  NSArray *attrs = [_mapper keyAttributesForEntity:object.entity];
  if (!attrs.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingKey, object.entity.name ?: @"?");
    return nil;
  }
  NSMutableDictionary *keys = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attr in attrs) {
    id value = [object primitiveValueForKey:attr.name];
    if (!value && attr.attributeType == NSUUIDAttributeType) {
      value = [NSUUID UUID];
      [object setPrimitiveValue:value forKey:attr.name];
    }
    value = [self referenceValue:value];
    if (value) keys[[_mapper propertyForAttribute:attr]] = value;
  }
  return keys;
}

// An entity's identifier from its keys by wire name, marking the ones
// whose literal is unquoted.
- (ODataResourceIdentifier *)identifierForEntity:(NSEntityDescription *)entity keys:(NSDictionary *)keys
{
  ODataResourceIdentifier *identifier = [[ODataResourceIdentifier alloc] initWithEntitySet:[_mapper entitySetForEntity:entity] keys:keys];
  NSMutableSet *unquoted = [NSMutableSet set];
  for (NSAttributeDescription *attr in [_mapper keyAttributesForEntity:entity]) {
    switch ([_mapper.values edmTypeOfAttribute:attr]) {
      case ODataEdmGuid:
      case ODataEdmDateTimeOffset:
      case ODataEdmDate:
      case ODataEdmTimeOfDay:
        [unquoted addObject:[_mapper propertyForAttribute:attr]];
        break;
      default:
        break;
    }
  }
  identifier.unquotedKeys = unquoted;
  return identifier;
}

// A key as it goes into an object ID's reference object, which is JSON:
// numbers and strings as they are, anything else in its OData form.
- (id)referenceValue:(id)value
{
  if (!value || [value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) return value;
  if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
  if ([value isKindOfClass:[NSDate class]]) return ODataDateTimeOffsetString(value);
  if ([value isKindOfClass:[NSData class]]) return ODataBase64URLString(value);
  return [value description];
}

// By name first: Apple's -entity raises for a request made with a name
// that no context has used yet (a batch delete's).
- (NSEntityDescription *)resolvedEntity:(NSFetchRequest *)fetch
{
  if (fetch.entityName) return self.persistentStoreCoordinator.managedObjectModel.entitiesByName[fetch.entityName];
  return fetch.entity;
}

@end
