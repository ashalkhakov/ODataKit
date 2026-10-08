// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"

NSString * const ODSRemoteStateEntity = @"ODSRemoteState";
NSString * const ODSOutboxEntity = @"ODSOutboxEntry";
NSString * const ODSShadowEntity = @"ODSShadow";
NSString * const ODSTombstoneEntity = @"ODSTombstone";
NSString * const ODataSyncPeerConfiguration = @"ODataSync.peer";

static NSAttributeDescription *ODSAttribute(NSString *name, NSAttributeType type)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = YES;
  // A flag or a count is NO or 0, never NULL (which a predicate's != YES
  // does not take).
  if (type == NSBooleanAttributeType) attribute.defaultValue = @NO;
  if (type == NSInteger16AttributeType || type == NSInteger32AttributeType || type == NSInteger64AttributeType) attribute.defaultValue = @0;
  return attribute;
}

static NSEntityDescription *ODSEntity(NSString *name, NSArray<NSAttributeDescription *> *attributes)
{
  NSEntityDescription *entity = [[NSEntityDescription alloc] init];
  entity.name = name;
  entity.managedObjectClassName = NSStringFromClass([NSManagedObject class]);
  entity.properties = attributes;
  return entity;
}

// A fetch index on the entity's attributes of those names, in that order.
// The bookkeeping is looked up a row at a time (each object a sync moves):
// unindexed, a sync reads each table once per row. Set after the
// properties: Apple's Core Data drops an entity's indexes when they are set.
static NSFetchIndexDescription *ODSIndex(NSEntityDescription *entity, NSString *name, NSArray<NSString *> *attributes)
{
  NSMutableArray *elements = [NSMutableArray array];
  for (NSString *attribute in attributes) {
    [elements addObject:[[NSFetchIndexElementDescription alloc] initWithProperty:entity.attributesByName[attribute]
                                                                   collationType:NSFetchIndexElementTypeBinary]];
  }
  return [[NSFetchIndexDescription alloc] initWithName:name elements:elements];
}

void ODSIndexKeys(NSManagedObjectModel *model, NSArray<NSEntityDescription *> *entities)
{
  ODSModel *synced = [[ODSModel alloc] initWithModel:model];
  for (NSEntityDescription *entity in entities) {
    NSArray<NSString *> *key = [[synced keyAttributesOf:entity] valueForKey:@"name"];
    if (!key.count) continue;
    BOOL indexed = NO;
    for (NSFetchIndexDescription *index in entity.indexes) {
      NSArray *names = [index.elements valueForKeyPath:@"property.name"];
      if (names.count >= key.count && [[names subarrayWithRange:NSMakeRange(0, key.count)] isEqualToArray:key]) indexed = YES;
    }
    if (indexed) continue;
    // Apple's raises for an index the entity has already: let go, then all.
    NSArray *indexes = [entity.indexes arrayByAddingObject:ODSIndex(entity, @"ODataSyncKey", key)];
    entity.indexes = @[];
    entity.indexes = indexes;
  }
}

NSEntityDescription *ODSTombstoneEntityDescription(void)
{
  NSEntityDescription *tombstone = ODSEntity(ODSTombstoneEntity, @[ ODSAttribute(@"entityType", NSStringAttributeType), ODSAttribute(@"keyText", NSStringAttributeType),
                                                                    ODSAttribute(@"deleted", NSDateAttributeType), ODSAttribute(@"versions", NSStringAttributeType) ]);
  // By the object it was (a deletion told, a key reused), and by age (pruning).
  tombstone.indexes = @[ ODSIndex(tombstone, @"byObject", @[ @"entityType", @"keyText" ]), ODSIndex(tombstone, @"byDeleted", @[ @"deleted" ]) ];
  return tombstone;
}

@implementation ODSStore {
  ODSCodec *_codec;
  NSString *_replicaID;
}

+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(NSString *)configuration
{
  if (model.entitiesByName[ODSRemoteStateEntity]) return;
  NSEntityDescription *outbox = ODSEntity(ODSOutboxEntity, @[ ODSAttribute(@"remote", NSStringAttributeType), ODSAttribute(@"entityType", NSStringAttributeType),
                                  ODSAttribute(@"key", NSBinaryDataAttributeType), ODSAttribute(@"keyText", NSStringAttributeType),
                                  ODSAttribute(@"operation", NSInteger16AttributeType), ODSAttribute(@"properties", NSBinaryDataAttributeType),
                                  ODSAttribute(@"sequence", NSInteger64AttributeType), ODSAttribute(@"attempts", NSInteger32AttributeType),
                                  ODSAttribute(@"status", NSInteger32AttributeType), ODSAttribute(@"message", NSStringAttributeType),
                                  ODSAttribute(@"setAside", NSBooleanAttributeType), ODSAttribute(@"relayed", NSBooleanAttributeType) ]);
  // An object's change waiting for a remote (each local change); a
  // remote's changes, by its first column (each upload); the last
  // sequence number, for the next entry's (each local change too).
  outbox.indexes = @[ ODSIndex(outbox, @"byObject", @[ @"remote", @"entityType", @"keyText" ]), ODSIndex(outbox, @"bySequence", @[ @"sequence" ]) ];
  NSEntityDescription *shadow = ODSEntity(ODSShadowEntity, @[ ODSAttribute(@"remote", NSStringAttributeType), ODSAttribute(@"entityType", NSStringAttributeType),
                                  ODSAttribute(@"keyText", NSStringAttributeType), ODSAttribute(@"etag", NSStringAttributeType),
                                  ODSAttribute(@"values", NSBinaryDataAttributeType) ]);
  // What a remote last had of an object (each object downloaded or sent).
  shadow.indexes = @[ ODSIndex(shadow, @"byObject", @[ @"remote", @"entityType", @"keyText" ]) ];
  NSArray *added = @[
    ODSEntity(ODSRemoteStateEntity, @[ ODSAttribute(@"remote", NSStringAttributeType), ODSAttribute(@"deltaLinks", NSBinaryDataAttributeType),
                                       ODSAttribute(@"filters", NSBinaryDataAttributeType), ODSAttribute(@"historyToken", NSBinaryDataAttributeType) ]),
    outbox,
    shadow,
    ODSTombstoneEntityDescription(),
  ];
  // What a peer server serves: the synced entities, with their sub-entities.
  ODSModel *syncing = [[ODSModel alloc] initWithModel:model];
  NSArray *synced = [syncing syncedEntities];
  // Their objects looked up by key, each one a sync moves: indexed by it,
  // at the root (a sub-entity's rows are its root's).
  NSMutableOrderedSet *roots = [NSMutableOrderedSet orderedSet];
  for (NSEntityDescription *entity in synced) [roots addObject:[syncing rootOf:entity]];
  ODSIndexKeys(model, roots.array);
  model.entities = [model.entities arrayByAddingObjectsFromArray:added];
  [model setEntities:synced forConfiguration:ODataSyncPeerConfiguration];
  if (configuration) {
    NSArray *entities = [model entitiesForConfiguration:configuration] ?: @[];
    [model setEntities:[entities arrayByAddingObjectsFromArray:added] forConfiguration:configuration];
  }
}

- (instancetype)initWithCoordinator:(NSPersistentStoreCoordinator *)coordinator codec:(ODSCodec *)codec
{
  self = [super init];
  if (!self) return nil;
  _coordinator = coordinator;
  _codec = codec;
  return self;
}

- (NSManagedObjectContext *)contextWritingAs:(NSString *)author
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = self.coordinator;
  context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
  if ([context respondsToSelector:@selector(setTransactionAuthor:)]) context.transactionAuthor = author;
  return context;
}

#pragma mark State, outbox, shadows

- (NSManagedObject *)stateOf:(ODataSyncRemote *)remote inContext:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSRemoteStateEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@", remote.identifier];
  fetch.fetchLimit = 1;
  NSManagedObject *state = [[context executeFetchRequest:fetch error:NULL] firstObject];
  if (!state) {
    state = [NSEntityDescription insertNewObjectForEntityForName:ODSRemoteStateEntity inManagedObjectContext:context];
    [state setValue:remote.identifier forKey:@"remote"];
  }
  return state;
}

- (NSManagedObject *)entryOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                   inContext:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND entityType == %@ AND keyText == %@", remote.identifier, entityName, keyText];
  fetch.fetchLimit = 1;
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

- (NSManagedObject *)shadowOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                    inContext:(NSManagedObjectContext *)context make:(BOOL)make
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSShadowEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND entityType == %@ AND keyText == %@", remote.identifier, entityName, keyText];
  fetch.fetchLimit = 1;
  NSManagedObject *shadow = [[context executeFetchRequest:fetch error:NULL] firstObject];
  if (!shadow && make) {
    shadow = [NSEntityDescription insertNewObjectForEntityForName:ODSShadowEntity inManagedObjectContext:context];
    [shadow setValue:remote.identifier forKey:@"remote"];
    [shadow setValue:entityName forKey:@"entityType"];
    [shadow setValue:keyText forKey:@"keyText"];
  }
  return shadow;
}

- (int64_t)nextSequenceIn:(NSManagedObjectContext *)context
{
  NSFetchRequest *last = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  last.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"sequence" ascending:NO] ];
  last.fetchLimit = 1;
  return [[[[context executeFetchRequest:last error:NULL] firstObject] valueForKey:@"sequence"] longLongValue] + 1;
}

- (NSManagedObject *)newEntryOf:(NSEntityDescription *)root key:(NSDictionary *)key operation:(ODataSyncOperation)operation
                         remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context
{
  int64_t sequence = [self nextSequenceIn:context];
  NSManagedObject *entry = [NSEntityDescription insertNewObjectForEntityForName:ODSOutboxEntity inManagedObjectContext:context];
  [entry setValue:remote.identifier forKey:@"remote"];
  [entry setValue:root.name forKey:@"entityType"];
  [entry setValue:ODSArchive(key) forKey:@"key"];
  [entry setValue:[_codec keyTextOf:key entity:root] forKey:@"keyText"];
  [entry setValue:@(operation) forKey:@"operation"];
  [entry setValue:@(sequence) forKey:@"sequence"];
  return entry;
}

#pragma mark Deletions

- (NSFetchRequest *)tombstonesOf:(NSString *)entityName keyText:(NSString *)keyText
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSTombstoneEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"entityType == %@ AND keyText == %@", entityName, keyText];
  return fetch;
}

- (BOOL)isDeleted:(NSString *)entityName keyText:(NSString *)keyText inContext:(NSManagedObjectContext *)context
{
  return [context countForFetchRequest:[self tombstonesOf:entityName keyText:keyText] error:NULL] > 0;
}

- (NSDictionary *)deletedVersionsOf:(NSString *)entityName keyText:(NSString *)keyText inContext:(NSManagedObjectContext *)context
{
  NSManagedObject *tombstone = [[context executeFetchRequest:[self tombstonesOf:entityName keyText:keyText] error:NULL] firstObject];
  return ODSVersionsFromText([tombstone valueForKey:@"versions"]);
}

- (void)forgetDeletionOf:(NSString *)entityName keyText:(NSString *)keyText inContext:(NSManagedObjectContext *)context
{
  for (NSManagedObject *tombstone in [context executeFetchRequest:[self tombstonesOf:entityName keyText:keyText] error:NULL]) {
    [context deleteObject:tombstone];
  }
}

- (void)rememberDeletionOf:(NSString *)entityName keyText:(NSString *)keyText versions:(NSDictionary *)versions
                 inContext:(NSManagedObjectContext *)context
{
  NSManagedObject *tombstone = [NSEntityDescription insertNewObjectForEntityForName:ODSTombstoneEntity inManagedObjectContext:context];
  [tombstone setValue:entityName forKey:@"entityType"];
  [tombstone setValue:keyText forKey:@"keyText"];
  [tombstone setValue:[NSDate date] forKey:@"deleted"];
  if (versions.count) [tombstone setValue:ODSTextOfVersions(versions) forKey:@"versions"];
}

- (void)forgetDeletionsBefore:(NSDate *)date
{
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSTombstoneEntity];
    fetch.predicate = [NSPredicate predicateWithFormat:@"deleted < %@", date];
    for (NSManagedObject *tombstone in [context executeFetchRequest:fetch error:NULL]) [context deleteObject:tombstone];
    if (context.hasChanges) [context save:NULL];
  }];
}

#pragma mark Metadata

- (NSString *)replicaID
{
  @synchronized (self) {
    if (_replicaID) return _replicaID;
    NSPersistentStore *store = self.coordinator.persistentStores.firstObject;
    NSDictionary *metadata = store ? [self.coordinator metadataForPersistentStore:store] : nil;
    _replicaID = metadata[@"ODataSync.replica"];
    if (!_replicaID) {
      _replicaID = [NSUUID UUID].UUIDString.lowercaseString;
      if (store) {
        NSMutableDictionary *changed = [metadata mutableCopy] ?: [NSMutableDictionary dictionary];
        changed[@"ODataSync.replica"] = _replicaID;
        [self.coordinator setMetadata:changed forPersistentStore:store];
      }
    }
    return _replicaID;
  }
}

- (int64_t)nextCount
{
  @synchronized (self) {
    NSPersistentStore *store = self.coordinator.persistentStores.firstObject;
    NSMutableDictionary *metadata = [[self.coordinator metadataForPersistentStore:store] mutableCopy] ?: [NSMutableDictionary dictionary];
    int64_t count = [metadata[@"ODataSync.count"] longLongValue] + 1;
    metadata[@"ODataSync.count"] = @(count);
    if (store) [self.coordinator setMetadata:metadata forPersistentStore:store];
    return count;
  }
}

// When it is not the one before (the app was updated, and its store
// migrated), what remotes refused is to go again, now in the new model's
// shape (a conflict set aside stays so).
- (BOOL)noticeModelVersion:(NSString *)version
{
  NSPersistentStore *store = self.coordinator.persistentStores.firstObject;
  if (!version || !store) return NO;
  NSDictionary *metadata = [self.coordinator metadataForPersistentStore:store];
  NSString *before = metadata[@"ODataSync.model"];
  if ([before isEqualToString:version]) return NO;
  NSMutableDictionary *changed = [metadata mutableCopy] ?: [NSMutableDictionary dictionary];
  changed[@"ODataSync.model"] = version;
  [self.coordinator setMetadata:changed forPersistentStore:store];
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
    fetch.predicate = before ? [NSPredicate predicateWithFormat:@"setAside == YES AND status != 409"] : [NSPredicate predicateWithValue:NO];
    for (NSManagedObject *entry in [context executeFetchRequest:fetch error:NULL]) {
      [entry setValue:@NO forKey:@"setAside"];
      [entry setValue:@0 forKey:@"attempts"];
    }
    // The metadata goes with this save, or the sync's next one.
    if (context.hasChanges) [context save:NULL];
  }];
  return before != nil;
}

#pragma mark The outbox

- (NSArray *)changesWhere:(NSPredicate *)predicate issuesOnly:(BOOL)issuesOnly
{
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  NSMutableArray *changes = [NSMutableArray array];
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
    fetch.predicate = predicate;
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"sequence" ascending:YES] ];
    for (NSManagedObject *entry in [context executeFetchRequest:fetch error:NULL]) {
      NSEntityDescription *entity = self.coordinator.managedObjectModel.entitiesByName[[entry valueForKey:@"entityType"]];
      NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
      NSManagedObject *object = entity && key ? [self->_codec objectOfEntity:entity key:key inContext:context] : nil;
      Class kind = issuesOnly || [[entry valueForKey:@"setAside"] boolValue] ? [ODataSyncIssue class] : [ODataSyncChange class];
      [changes addObject:[[kind alloc] initWithEntry:entry objectID:object.objectID]];
    }
  }];
  return changes;
}

- (NSArray<ODataSyncChange *> *)pendingChanges
{
  return [self changesWhere:nil issuesOnly:NO];
}

- (NSArray<ODataSyncIssue *> *)issues
{
  return [self changesWhere:[NSPredicate predicateWithFormat:@"setAside == YES"] issuesOnly:YES];
}

- (void)changeIssue:(ODataSyncIssue *)issue discarding:(BOOL)discard
{
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  [context performBlockAndWait:^{
    NSManagedObject *entry = [context existingObjectWithID:issue.entryID error:NULL];
    if (!entry) return;
    if (discard && [[entry valueForKey:@"status"] integerValue] == 409) {
      // A conflict given up: the remote's version, read again at the next sync.
      [entry setValue:@(ODataSyncOperationRefresh) forKey:@"operation"];
      [entry setValue:@NO forKey:@"setAside"];
    } else if (discard) {
      [context deleteObject:entry];
    } else {
      [entry setValue:@NO forKey:@"setAside"];
      [entry setValue:@0 forKey:@"attempts"];
    }
    [context save:NULL];
  }];
}

@end
