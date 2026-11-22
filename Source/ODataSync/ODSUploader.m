// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Up (docs/offline-sync.md, 5): the local store's history, after the token
// the remote's state keeps, into the outbox (an entry per object, changes
// folded together), saved with the new token; then the outbox to the
// remote, a $batch at a time, each change an upsert or a DELETE that
// stands or falls alone.

#import "ODSInternal.h"
#import <ODataKit/ODataBatch.h>
#import <ODataKit/ODataError.h>
#import <ODataKit/ODataTransport.h>

// How many times a both object's change meets a newer version in one sync
// before it waits for the next.
static const NSInteger ODSConflictRounds = 3;

// The engine saved a remote's history token and nothing else (collecting
// or uploading, as itself or as the remote).
static BOOL ODSOnlyHistoryTokens(NSPersistentHistoryTransaction *transaction)
{
  if (![transaction.author hasPrefix:@"ODataSync."] || !transaction.changes.count) return NO;
  for (NSPersistentHistoryChange *change in transaction.changes) {
    if (change.changeType != NSPersistentHistoryChangeTypeUpdate) return NO;
    if (![change.changedObjectID.entity.name isEqualToString:ODSRemoteStateEntity]) return NO;
    NSSet *names = [change.updatedProperties valueForKey:@"name"];
    if (![names isEqualToSet:[NSSet setWithObject:@"historyToken"]]) return NO;
  }
  return YES;
}

@implementation ODSUploader {
  ODataSyncEngine *_engine;
  ODataSyncRemote *_remote;
  ODSModel *_model;
  ODSCodec *_codec;
  ODSRequests *_requests;
  ODataClient *_client;
  NSArray<NSEntityDescription *> *_entities;
  BOOL _batchUnsupported;
  // A JSON batch, but no atomicity group there.
  BOOL _groupsUnsupported;
}

- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote
{
  self = [super init];
  if (!self) return nil;
  _engine = engine;
  _remote = remote;
  _model = engine.model;
  _codec = engine.codec;
  _requests = [[ODSRequests alloc] initWithEngine:engine remote:remote];
  _client = [engine clientOf:remote];
  _entities = [_model rootEntitiesGoing:[NSSet setWithObjects:@(ODataSyncDirectionUp), @(ODataSyncDirectionBoth), nil] toward:_remote];
  return self;
}

#pragma mark History into the outbox

// The synced properties a change names (Core Data names); nil for none.
- (NSSet<NSString *> *)syncedNamesOf:(NSArray<NSPropertyDescription *> *)properties entity:(NSEntityDescription *)entity
{
  NSMutableSet *names = [NSMutableSet set];
  NSSet *attributes = [NSSet setWithArray:[[[_model attributesOf:entity] arrayByAddingObjectsFromArray:[_model mergedAttributesOf:entity]]
                                              valueForKey:@"name"]];
  NSSet *toOnes = [NSSet setWithArray:[[[_model toOnesOf:entity] arrayByAddingObjectsFromArray:[_model setsOf:entity]] valueForKey:@"name"]];
  for (NSPropertyDescription *property in properties) {
    if ([attributes containsObject:property.name] || [toOnes containsObject:property.name]) [names addObject:property.name];
  }
  return names.count ? names : nil;
}

// A change into the entry of its object. Relayed: it came from another
// remote, and so is no authority's (-checksVersionsOf:).
- (void)fold:(ODataSyncOperation)operation properties:(NSSet<NSString *> *)properties entity:(NSEntityDescription *)root
         key:(NSDictionary *)key relayed:(BOOL)relayed context:(NSManagedObjectContext *)context
{
  NSString *keyText = [_codec keyTextOf:key entity:root];
  NSManagedObject *entry = [_engine.store entryOf:root.name keyText:keyText remote:_remote inContext:context];
  if (!entry) {
    entry = [NSEntityDescription insertNewObjectForEntityForName:ODSOutboxEntity inManagedObjectContext:context];
    [entry setValue:_remote.identifier forKey:@"remote"];
    [entry setValue:root.name forKey:@"entityType"];
    [entry setValue:ODSArchive(key) forKey:@"key"];
    [entry setValue:keyText forKey:@"keyText"];
    [entry setValue:@(operation) forKey:@"operation"];
    [entry setValue:ODSArchive(properties.allObjects) forKey:@"properties"];
    [entry setValue:@([_engine.store nextSequenceIn:context]) forKey:@"sequence"];
    [entry setValue:@(relayed) forKey:@"relayed"];
    [_engine.store indexEntry:entry];
    return;
  }
  // A change made here is this device's to send, whatever else came.
  if (!relayed) [entry setValue:@NO forKey:@"relayed"];
  // Changed again: it is sent again, whatever was refused before.
  [entry setValue:@NO forKey:@"setAside"];
  ODataSyncOperation pending = [[entry valueForKey:@"operation"] integerValue];
  BOOL sent = [[entry valueForKey:@"attempts"] integerValue] > 0;
  if (operation == ODataSyncOperationDelete) {
    // Made and gone before the remote heard of it: nothing to send.
    if (pending == ODataSyncOperationInsert && !sent) {
      [context deleteObject:entry];
      return;
    }
    [entry setValue:@(ODataSyncOperationDelete) forKey:@"operation"];
    [entry setValue:nil forKey:@"properties"];
    return;
  }
  if (pending == ODataSyncOperationDelete || operation == ODataSyncOperationInsert) {
    // Made again (the same key): the whole object.
    [entry setValue:@(ODataSyncOperationInsert) forKey:@"operation"];
    [entry setValue:nil forKey:@"properties"];
    return;
  }
  if (pending == ODataSyncOperationInsert) return;  // the whole object goes anyway
  NSArray *before = ODSUnarchive([entry valueForKey:@"properties"]);
  if (!before) return;  // all of it already
  [entry setValue:ODSArchive([[NSSet setWithArray:before] setByAddingObjectsFromSet:properties].allObjects) forKey:@"properties"];
}

- (BOOL)fillOutbox:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSManagedObject *state = [_engine.store stateOf:_remote inContext:context];
  NSData *archived = [state valueForKey:@"historyToken"];
  NSPersistentHistoryToken *token = archived ? [NSKeyedUnarchiver unarchivedObjectOfClass:[NSPersistentHistoryToken class] fromData:archived error:NULL] : nil;
  NSPersistentHistoryChangeRequest *request = [NSPersistentHistoryChangeRequest fetchHistoryAfterToken:token];
  request.resultType = NSPersistentHistoryResultTypeTransactionsAndChanges;
  NSPersistentHistoryResult *result = (NSPersistentHistoryResult *)[context executeRequest:request error:error];
  if (!result) return NO;
  // Each object's entry found in an index of the outbox, not by a fetch
  // each (which looks through every entry made in this pass).
  [_engine.store indexOutboxOf:_remote inContext:context];
  NSPersistentHistoryToken *last = token;
  NSSet *bookkeeping = [NSSet setWithObjects:ODSRemoteStateEntity, ODSOutboxEntity, ODSShadowEntity, ODSTombstoneEntity, nil];
  // Made and gone within what is read now: its deletion is nothing to send.
  NSMutableSet<NSManagedObjectID *> *fleeting = [NSMutableSet set];
  // Every few hundred changes, what is folded is saved and the context
  // emptied: each change's object is read (for its key), whole, files and
  // all, and kept, they would add up to every object changed. Within a
  // transaction too: an import saved at once is one. (The history token is
  // saved only at the end: a pass that stops is folded again, into the same
  // entries.)
  NSUInteger unsaved = 0;
  NSError *failure = nil;
  BOOL failed = NO;
  // Whether anything was read but the history tokens saved by earlier
  // passes: saving the token past only those would be one more of them, for
  // the next pass to read, and so on at every sync.
  BOOL moved = NO;
  for (NSPersistentHistoryTransaction *transaction in result.result) @autoreleasepool {
    if (failed) break;
    last = transaction.token ?: last;
    if (!moved && !ODSOnlyHistoryTokens(transaction)) moved = YES;
    BOOL relayed = NO, fromPeer = NO;
    if ([transaction.author hasPrefix:@"ODataSync."]) {
      // What came from this remote is not sent back, nor the engine's own
      // state; what came from another is passed on when either is a peer.
      if (![transaction.author hasPrefix:ODataSyncDownAuthorPrefix]) continue;
      NSString *source = [transaction.author substringFromIndex:ODataSyncDownAuthorPrefix.length];
      if ([source isEqualToString:_remote.identifier]) continue;
      ODataSyncRemote *from = [_engine remoteWithIdentifier:source];
      // One that is not among the remotes sent it to this device's peer server: a peer.
      fromPeer = !from || from.peer;
      if (!_remote.peer && !fromPeer) continue;
      relayed = YES;
    }
    for (NSPersistentHistoryChange *change in transaction.changes) @autoreleasepool {
      if (unsaved >= 500) {
        NSError *e = nil;
        if (![context save:&e]) {
          failure = e;
          failed = YES;
          break;
        }
        [context reset];
        state = [_engine.store stateOf:_remote inContext:context];
        [_engine.store indexOutboxOf:_remote inContext:context];
        unsaved = 0;
      }
      unsaved++;
      NSEntityDescription *entity = change.changedObjectID.entity;
      if ([bookkeeping containsObject:entity.name]) continue;
      ODataSyncDirection direction = [_model directionOfEntity:entity];
      if (direction == ODataSyncDirectionDown) {
        if (!relayed) [_engine ignoredLocalChangeTo:change.changedObjectID];
        continue;
      }
      if (direction == ODataSyncDirectionNone) continue;
      NSEntityDescription *root = [_model rootOf:entity];
      if (change.changeType == NSPersistentHistoryChangeTypeDelete) {
        // A deletion a peer sent here was made there (an engine sends a
        // peer its own deletions, and those passed on so): passed on. One
        // that came down from a service may be its scope, not the object's
        // end; and a peer's reads delete nothing.
        if (relayed && !fromPeer) continue;
        if ([fleeting containsObject:change.changedObjectID]) continue;
        NSDictionary *key = [_codec keyFromValues:change.tombstone ?: @{} entity:root];
        // Its key was not kept on deletion (preservesValueInHistoryOnDeletion): it cannot be named.
        if (!key) continue;
        [self fold:ODataSyncOperationDelete properties:nil entity:root key:key relayed:relayed context:context];
        NSManagedObject *merge = [_engine.store mergeEntryOf:root.name keyText:[_codec keyTextOf:key entity:root] remote:_remote inContext:context];
        if (merge) [context deleteObject:merge];
        continue;
      }
      // Gone since: its deletion comes later in history.
      NSManagedObject *object = [context existingObjectWithID:change.changedObjectID error:NULL];
      if (!object) {
        if (change.changeType == NSPersistentHistoryChangeTypeInsert) [fleeting addObject:change.changedObjectID];
        continue;
      }
      NSDictionary *key = [_codec keyOfObject:object];
      if (key.count != [_codec.mapper keyAttributesForEntity:root].count) continue;
      NSSet *merged = [NSSet setWithArray:[[_model mergedAttributesOf:entity] valueForKey:@"name"]];
      if (change.changeType == NSPersistentHistoryChangeTypeInsert) {
        [self fold:ODataSyncOperationInsert properties:nil entity:root key:key relayed:relayed context:context];
        if (merged.count) [_engine.store noteMergeOf:root key:key remote:_remote context:context];
      } else {
        NSSet *names = [self syncedNamesOf:change.updatedProperties.allObjects entity:entity];
        // A change of nothing synced (an empty set: unknown, so all).
        if (!names && change.updatedProperties.count) continue;
        // Merged attributes go as deltas, in an entry of their own; the
        // row's PATCH has the rest.
        if (merged.count && (!names || [names intersectsSet:merged])) [_engine.store noteMergeOf:root key:key remote:_remote context:context];
        NSMutableSet *rest = [names mutableCopy];
        [rest minusSet:merged];
        if (names && !rest.count) continue;
        [self fold:ODataSyncOperationUpdate properties:names ? rest : nil entity:root key:key relayed:relayed context:context];
      }
    }
  }
  [_engine.store endOutboxIndex];
  if (failed) {
    if (error) *error = failure;
    return NO;
  }
  if (last && moved) [state setValue:[NSKeyedArchiver archivedDataWithRootObject:last requiringSecureCoding:YES error:NULL] forKey:@"historyToken"];
  return [context save:error];
}

#pragma mark Requests


// Whether the entry is sent as a both entity's (If-Match, If-None-Match;
// a 412 a conflict): a both entity, an up entity to a peer, and an up
// entity's change that came from elsewhere, which may be stale, or
// already deleted at the remote.
- (BOOL)checksVersionsOf:(NSManagedObject *)entry
{
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  ODataSyncDirection direction = [_model directionOfEntity:root toward:_remote];
  return direction == ODataSyncDirectionBoth || (direction == ODataSyncDirectionUp && [[entry valueForKey:@"relayed"] boolValue]);
}

// Whether what the remote took of the entry's object is kept (its
// shadow): a both entity's, and an up entity's with sets (its members
// there, so only the ones it has not are sent, a member taken away too),
// whose version is still not checked (-checksVersionsOf:).
- (BOOL)keepsShadowOf:(NSManagedObject *)entry
{
  if ([self checksVersionsOf:entry]) return YES;
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  if (!root) return NO;
  if ([_model setsOf:root].count) return YES;
  for (NSEntityDescription *sub in root.subentities) if ([_model setsOf:sub].count) return YES;
  return NO;
}

- (NSArray<NSManagedObject *> *)pendingIn:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND setAside != YES", _remote.identifier];
  NSArray *entries = [context executeFetchRequest:fetch error:NULL];
  // Upserts parents first, deletions children first; in order within.
  NSMutableDictionary *place = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < _entities.count; i++) place[_entities[i].name] = @(i);
  NSArray *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(NSManagedObject *a, NSManagedObject *b) {
    BOOL deleteA = [[a valueForKey:@"operation"] integerValue] == ODataSyncOperationDelete;
    BOOL deleteB = [[b valueForKey:@"operation"] integerValue] == ODataSyncOperationDelete;
    if (deleteA != deleteB) return deleteA ? NSOrderedDescending : NSOrderedAscending;
    NSInteger pa = [place[[a valueForKey:@"entityType"]] integerValue], pb = [place[[b valueForKey:@"entityType"]] integerValue];
    if (pa != pb) return (deleteA ? pa < pb : pa > pb) ? NSOrderedDescending : NSOrderedAscending;
    return [[a valueForKey:@"sequence"] compare:[b valueForKey:@"sequence"]];
  }];
  return [self referencesFirst:sorted context:context];
}

// An upsert after the upserts of what its object's to-ones are (a
// reminder done by a service made in the same save, the reminder's entry
// changed since and so later): the remote finds what it binds to, in the
// same atomicity group too. Otherwise as they were; a cycle as it comes.
- (void)place:(NSManagedObject *)entry into:(NSMutableArray *)ordered upserts:(NSDictionary<NSString *, NSManagedObject *> *)upserts
       placed:(NSMutableSet *)placed context:(NSManagedObjectContext *)context
{
  NSValue *seen = [NSValue valueWithNonretainedObject:entry];
  if ([placed containsObject:seen]) return;
  [placed addObject:seen];
  if ([[entry valueForKey:@"operation"] integerValue] != ODataSyncOperationDelete) {
    NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
    id key = ODSUnarchiveReporting([entry valueForKey:@"key"], NULL);
    NSManagedObject *object = root && [key isKindOfClass:[NSDictionary class]] ? [_codec objectOfEntity:root key:key inContext:context] : nil;
    for (NSRelationshipDescription *toOne in object ? [_model toOnesOf:object.entity] : @[]) {
      NSManagedObject *target = [object valueForKey:toOne.name];
      if (![target isKindOfClass:[NSManagedObject class]]) continue;
      NSEntityDescription *targetRoot = [_model rootOf:target.entity];
      NSDictionary *targetKey = [_codec keyOfObject:target];
      NSString *text = targetKey.count ? [_codec keyTextOf:targetKey entity:targetRoot] : nil;
      NSManagedObject *first = text ? upserts[[NSString stringWithFormat:@"%@ %@", targetRoot.name, text]] : nil;
      if (first) [self place:first into:ordered upserts:upserts placed:placed context:context];
    }
  }
  [ordered addObject:entry];
}

- (NSArray<NSManagedObject *> *)referencesFirst:(NSArray<NSManagedObject *> *)entries context:(NSManagedObjectContext *)context
{
  NSMutableDictionary<NSString *, NSManagedObject *> *upserts = [NSMutableDictionary dictionary];
  for (NSManagedObject *entry in entries) {
    if ([[entry valueForKey:@"operation"] integerValue] == ODataSyncOperationDelete) continue;
    upserts[[NSString stringWithFormat:@"%@ %@", [entry valueForKey:@"entityType"], [entry valueForKey:@"keyText"]]] = entry;
  }
  if (upserts.count < 2) return entries;
  NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:entries.count];
  NSMutableSet *placed = [NSMutableSet set];
  for (NSManagedObject *entry in entries) [self place:entry into:ordered upserts:upserts placed:placed context:context];
  return ordered;
}

// The request an entry is sent as: {method, url, headers, body}; nil when
// it has become nothing (an object made and gone before it was sent).
- (NSDictionary *)requestOf:(NSManagedObject *)entry context:(NSManagedObjectContext *)context
{
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  if (!root) {
    [context deleteObject:entry];
    return nil;
  }
  NSDictionary *key = [self keyOf:entry context:context];
  if (!key) return nil;
  ODataSyncOperation operation = [[entry valueForKey:@"operation"] integerValue];
  if (operation == ODataSyncOperationRefresh) return nil;  // read, not sent (-refreshIn:)
  if (operation == ODataSyncOperationMerge) return nil;    // exchanged after the batch (ODSMergeExchange)
  BOOL both = [self checksVersionsOf:entry];
  NSManagedObject *shadow = both ? [_engine.store shadowOf:root.name keyText:[entry valueForKey:@"keyText"] remote:_remote inContext:context make:NO] : nil;
  NSString *etag = [shadow valueForKey:@"etag"];
  NSManagedObject *object = operation == ODataSyncOperationDelete ? nil : [_codec objectOfEntity:root key:key inContext:context];
  if (operation != ODataSyncOperationDelete && !object) {
    if (operation == ODataSyncOperationInsert && [[entry valueForKey:@"attempts"] integerValue] == 0) {
      [context deleteObject:entry];
      return nil;
    }
    operation = ODataSyncOperationDelete;
    [entry setValue:@(operation) forKey:@"operation"];
  }
  NSData *kept = [shadow valueForKey:@"values"];
  id agreed = object && kept.length ? [NSJSONSerialization JSONObjectWithData:kept options:0 error:NULL] : nil;
  if ([agreed isKindOfClass:[NSDictionary class]]) {
    NSAttributeDescription *stamp = [_model modifiedAttributeOf:root];
    id ours = stamp ? [object valueForKey:stamp.name] : nil, theirs = stamp ? agreed[[_codec.mapper propertyForAttribute:stamp]] : nil;
    NSDictionary *mine = [_codec versionsOfObject:object], *seen = [_codec versionsOfRow:agreed entity:root];
    BOOL older = mine.count && seen.count ? ODSCompareVersions(mine, seen) == ODSOrderBefore
                                          : [ours isKindOfClass:[NSString class]] && [theirs isKindOfClass:[NSString class]] && [ours compare:theirs] == NSOrderedAscending;
    if (older) {
      // Older than the remote's (a copy that came round late): sent, it
      // would put an older version over a newer one. The remote's is taken:
      // the version agreed on, or, when it keeps a file only as its digest,
      // read again from the remote (-refreshIn:, at the next sync).
      if ([_codec shadowHasDigests:agreed entity:object.entity]) {
        [entry setValue:@(ODataSyncOperationRefresh) forKey:@"operation"];
        return nil;
      }
      [_codec applyJSON:agreed toObject:object];
      [context deleteObject:entry];
      return nil;
    }
    // What the remote has already (passed on there by another way, or come
    // from it): not sent again.
    NSSet *differ = ODSChangedNames([_codec valuesOfObject:object], [_codec valuesFromShadow:agreed entity:[_codec entityOfRow:agreed entity:object.entity]]);
    if (!differ.count) {
      [context deleteObject:entry];
      return nil;
    }
    operation = ODataSyncOperationUpdate;
    [entry setValue:@(operation) forKey:@"operation"];
    [entry setValue:ODSArchive(differ.allObjects) forKey:@"properties"];
  }
  if (operation == ODataSyncOperationDelete) {
    return [_requests deletionOf:root key:key checked:both etag:etag
                        versions:[_engine.store deletedVersionsOf:root.name keyText:[entry valueForKey:@"keyText"] inContext:context]];
  }
  NSArray *names = ODSUnarchive([entry valueForKey:@"properties"]);
  return [_requests upsertOf:object entity:root key:key properties:names ? [NSSet setWithArray:names] : nil
                      insert:operation == ODataSyncOperationInsert checked:both etag:etag];
}

static NSString *ODSMessageOf(NSData *body, NSInteger status)
{
  id json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
  id message = [json isKindOfClass:[NSDictionary class]] ? json[@"error"][@"message"] : nil;
  return [message isKindOfClass:[NSString class]] ? message : [NSString stringWithFormat:@"The service answered %ld", (long)status];
}

// A 409's deletion history: the error detail ODataSync.deleted, whose
// message is the tombstone's vector.
static NSDictionary *ODSDeletedVersionsIn(NSData *body)
{
  id json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
  id details = [json isKindOfClass:[NSDictionary class]] ? json[@"error"][@"details"] : nil;
  if (![details isKindOfClass:[NSArray class]]) return nil;
  for (NSDictionary *detail in details) {
    if ([detail isKindOfClass:[NSDictionary class]] && [detail[@"code"] isEqual:ODSDeletedCode]) return ODSVersionsFromText(detail[@"message"]);
  }
  return nil;
}

static NSString *ODSHeader(NSDictionary *headers, NSString *name)
{
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

// One request alone; its status (0: no answer), headers and body.
- (NSInteger)sendAlone:(NSDictionary *)request headers:(NSDictionary **)headers body:(NSData **)body error:(NSError **)error
{
  NSMutableURLRequest *http = [_requests HTTPRequestOf:request];
  NSError *failure = nil;
  ODataHTTPResponse *response = [_client sendRequest:http error:&failure];
  if (response) {
    *headers = response.headers ?: @{};
    *body = response.data;
    return response.status ?: 200;
  }
  NSInteger status = failure.code > ODataIncrementalStoreErrorHTTP && failure.code < ODataIncrementalStoreErrorHTTP + 600
      ? failure.code - ODataIncrementalStoreErrorHTTP : 0;
  *headers = @{};
  NSString *message = failure.localizedDescription ?: @"";
  *body = [NSJSONSerialization dataWithJSONObject:@{ @"error": @{ @"message": message } } options:0 error:NULL];
  if (!status && error) *error = failure;
  return status;
}

// The requests as one $batch, each standing or falling alone: by id, each
// answer's status, headers and body. nil and *status for the batch's own
// failure (0: no answer).
- (NSDictionary<NSString *, ODataBatchPart *> *)sendBatch:(NSArray<NSDictionary *> *)requests status:(NSInteger *)status error:(NSError **)error
{
  NSMutableURLRequest *http = [_requests batchOf:requests];
  NSError *failure = nil;
  ODataHTTPResponse *response = [_client sendRequest:http error:&failure];
  *status = response ? 200 : (failure.code > ODataIncrementalStoreErrorHTTP && failure.code < ODataIncrementalStoreErrorHTTP + 600
                                  ? failure.code - ODataIncrementalStoreErrorHTTP : 0);
  if (!response) {
    if (error) *error = failure;
    return nil;
  }
  NSArray<ODataBatchPart *> *parts = ODataJSONBatchParts(response.data);
  if (!parts) {
    *status = 400;
    return nil;
  }
  NSMutableDictionary *byID = [NSMutableDictionary dictionary];
  for (ODataBatchPart *part in parts) if (part.contentID) byID[part.contentID] = part;
  return byID;
}

#pragma mark Answers

// An entry's key; nil when it cannot be read (unarchived), and then the
// entry is set aside with why, not dropped: what the change was is still
// there, for the app to show, and to send again (an update that reads it)
// or discard.
- (NSDictionary *)keyOf:(NSManagedObject *)entry context:(NSManagedObjectContext *)context
{
  NSError *failure = nil;
  id key = ODSUnarchiveReporting([entry valueForKey:@"key"], &failure);
  if ([key isKindOfClass:[NSDictionary class]]) return key;
  NSString *why = failure.localizedDescription ?: @"it is not a dictionary";
  NSString *message = [NSString stringWithFormat:@"The change's key could not be read: %@", why];
  NSLog(@"ODataSync: a change to %@ %@ for %@ is set aside: %@", [entry valueForKey:@"entityType"], [entry valueForKey:@"keyText"],
        _remote.identifier, message);
  [self setAside:entry status:0 message:message context:context];
  return nil;
}

- (void)setAside:(NSManagedObject *)entry status:(NSInteger)status message:(NSString *)message context:(NSManagedObjectContext *)context
{
  [entry setValue:@YES forKey:@"setAside"];
  [entry setValue:@(status) forKey:@"status"];
  [entry setValue:message forKey:@"message"];
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
  NSManagedObject *object = root && key ? [_codec objectOfEntity:root key:key inContext:context] : nil;
  [_engine setAside:[[ODataSyncIssue alloc] initWithEntry:entry objectID:object.objectID]];
}

// A both object's newer version at the remote, met by its If-Match: read,
// and settled as a conflict.
- (BOOL)resolveConflictOf:(NSManagedObject *)entry context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
  ODSDownloader *down = [[ODSDownloader alloc] initWithEngine:_engine remote:_remote];
  NSInteger status = 0;
  NSError *failure = nil;
  NSDictionary *row = [down rowOfEntity:root key:key status:&status error:&failure];
  if (!row && status != 404) {
    if (error) *error = failure;
    return NO;
  }
  if (!row && _remote.peer) {
    // A peer without it: no deletion (a peer deletes nothing), but an object
    // it is yet to have.
    [_engine agreeOn:nil etag:nil of:root keyText:[entry valueForKey:@"keyText"] remote:_remote context:context];
    [entry setValue:@(ODataSyncOperationInsert) forKey:@"operation"];
    [entry setValue:nil forKey:@"properties"];
    return YES;
  }
  NSString *etag = [row[@"@odata.etag"] isKindOfClass:[NSString class]] ? row[@"@odata.etag"] : nil;
  [_engine settleConflictOf:root key:key entry:entry remoteRow:row etag:etag remote:_remote context:context];
  return YES;
}

// Conflicts given up: the remote's version read again, and taken.
- (BOOL)refreshIn:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND operation == %d AND setAside != YES", _remote.identifier,
                                                     (int)ODataSyncOperationRefresh];
  ODSDownloader *down = [[ODSDownloader alloc] initWithEngine:_engine remote:_remote];
  for (NSManagedObject *entry in [context executeFetchRequest:fetch error:NULL]) {
    NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
    NSDictionary *key = root ? [self keyOf:entry context:context] : nil;
    if (root && !key) continue;
    if (root && ![down refreshObjectOfEntity:root key:key context:context error:error]) return NO;
    [context deleteObject:entry];
  }
  return YES;
}

// Each entry by its answer. NO when the rest should wait for the next sync
// (a remote that is down, or refuses who is asking: the error).
- (BOOL)take:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body of:(NSManagedObject *)entry
     context:(NSManagedObjectContext *)context stop:(BOOL *)stop error:(NSError **)error
{
  return [self take:status headers:headers body:body of:entry withheld:nil context:context stop:stop error:error];
}

// Taken: what the remote has now agreed on (with what the request
// withheld as the remote has it: withheld's values, by property), and the
// entry done; or, where it withheld some, kept as an update of those
// (withheld's names), till they are taken.
- (BOOL)take:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body of:(NSManagedObject *)entry
    withheld:(NSDictionary *)withheld context:(NSManagedObjectContext *)context stop:(BOOL *)stop error:(NSError **)error
{
  ODataSyncOperation operation = [[entry valueForKey:@"operation"] integerValue];
  NSString *entityName = [entry valueForKey:@"entityType"];
  NSString *keyText = [entry valueForKey:@"keyText"];
  BOOL both = [self checksVersionsOf:entry];
  [entry setValue:@([[entry valueForKey:@"attempts"] integerValue] + 1) forKey:@"attempts"];
  if ((status >= 200 && status < 300) || (status == 404 && operation == ODataSyncOperationDelete)) {
    if ([self keepsShadowOf:entry]) {
      // What both have now: the device's version, but what was withheld.
      NSEntityDescription *root = _model.model.entitiesByName[entityName];
      NSManagedObject *object = operation == ODataSyncOperationDelete ? nil
          : [_codec objectOfEntity:root key:ODSUnarchive([entry valueForKey:@"key"]) inContext:context];
      NSMutableDictionary *row = object ? [[_codec rowOfObject:object] mutableCopy] : nil;
      [row addEntriesFromDictionary:withheld[@"values"] ?: @{}];
      [_engine agreeOn:row etag:ODSHeader(headers, @"ETag") of:root keyText:keyText remote:_remote context:context];
    }
    NSSet *names = withheld[@"names"];
    if (names.count && operation != ODataSyncOperationDelete) {
      [entry setValue:@(ODataSyncOperationUpdate) forKey:@"operation"];
      [entry setValue:ODSArchive(names.allObjects) forKey:@"properties"];
      [entry setValue:@0 forKey:@"attempts"];
    } else {
      [context deleteObject:entry];
    }
    [_engine count:@"uploaded" by:1];
    return YES;
  }
  if (status == 412 && both) {
    if ([[entry valueForKey:@"attempts"] integerValue] > ODSConflictRounds) {
      *stop = YES;
      return YES;
    }
    return [self resolveConflictOf:entry context:context error:error];
  }
  NSDictionary *deletedThere = status == 409 ? ODSDeletedVersionsIn(body) : nil;
  if (deletedThere && operation != ODataSyncOperationDelete) {
    // Deleted there by one that did not know of this change: a conflict,
    // delete against change, the deletion's history given.
    NSEntityDescription *root = _model.model.entitiesByName[entityName];
    [_engine settleConflictOf:root key:ODSUnarchive([entry valueForKey:@"key"]) entry:entry remoteRow:nil remoteVersions:deletedThere
                         etag:nil remote:_remote context:context];
    return YES;
  }
  if (status == 410 && operation != ODataSyncOperationDelete) {
    // Deleted there, by one that saw this version: deleted here too
    // (written as the remote's deletion, and so passed on).
    NSEntityDescription *root = _model.model.entitiesByName[entityName];
    NSManagedObject *object = [_codec objectOfEntity:root key:ODSUnarchive([entry valueForKey:@"key"]) inContext:context];
    if (object) {
      [context deleteObject:object];
      [_engine count:@"removed" by:1];
    }
    [_engine agreeOn:nil etag:nil of:root keyText:keyText remote:_remote context:context];
    [context deleteObject:entry];
    return YES;
  }
  if (status == 401) {
    if (error) *error = ODSError(401, ODSMessageOf(body, status));
    *stop = YES;
    return NO;
  }
  if (status == 0 || status == 408 || status == 429 || status >= 500) {
    // Not now: again at the next sync.
    *stop = YES;
    return YES;
  }
  [self setAside:entry status:status message:ODSMessageOf(body, status) context:context];
  return YES;
}

static NSString *ODSEntryName(NSManagedObject *entry)
{
  return [NSString stringWithFormat:@"%@ %@", [entry valueForKey:@"entityType"], [entry valueForKey:@"keyText"]];
}

// What a request withholds of its entry's change, sent after it in the
// batch or at a later sync: a to-one's link to an object whose insert has
// not gone yet (later in the batch, or in a later one: a cycle, a stock
// item's preferred supplier item of the stock item; a contact's address,
// the contact's), and a set's members (a many-to-many this side carries),
// added or taken away by $ref against those agreed on. What the remote has
// of each is what is agreed on (-take:...withheld:), till each is taken;
// the entry waits as an update of what is not.
//
// Into withheld: names (the relationships), values (by property, the
// remote's: a link's null or its agreed target, a set's agreed members),
// members (by set, its members the remote has: key text to the row's key).
// Into links, each request sent after: request, index, relationship,
// and for a link its value (the target's key, as a row has it), for a set's
// member its text, key and whether it is added.
- (NSDictionary *)withhold:(NSManagedObject *)entry request:(NSDictionary **)request index:(NSUInteger)index
                   inBatch:(NSDictionary<NSString *, NSNumber *> *)inBatch toCome:(NSSet<NSString *> *)toCome
                     links:(NSMutableArray *)links context:(NSManagedObjectContext *)context
{
  ODataSyncOperation operation = [[entry valueForKey:@"operation"] integerValue];
  if (operation != ODataSyncOperationInsert && operation != ODataSyncOperationUpdate) return nil;
  NSDictionary *body = (*request)[@"body"];
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  id key = ODSUnarchiveReporting([entry valueForKey:@"key"], NULL);
  NSManagedObject *object = root && [key isKindOfClass:[NSDictionary class]] ? [_codec objectOfEntity:root key:key inContext:context] : nil;
  if (!object || ![body isKindOfClass:[NSDictionary class]]) return nil;
  NSManagedObject *shadow = [_engine.store shadowOf:root.name keyText:[entry valueForKey:@"keyText"] remote:_remote inContext:context make:NO];
  NSData *kept = operation == ODataSyncOperationInsert ? nil : [shadow valueForKey:@"values"];
  id agreed = kept.length ? [NSJSONSerialization JSONObjectWithData:kept options:0 error:NULL] : nil;
  if (![agreed isKindOfClass:[NSDictionary class]]) agreed = @{};
  NSMutableSet *names = [NSMutableSet set];
  NSMutableDictionary *values = [NSMutableDictionary dictionary], *members = [NSMutableDictionary dictionary];
  NSMutableDictionary *sent = nil;
  NSString *path = [_codec pathOfEntity:root key:key];
  for (NSRelationshipDescription *toOne in [_model toOnesOf:object.entity]) {
    NSManagedObject *target = [object valueForKey:toOne.name];
    if (![target isKindOfClass:[NSManagedObject class]]) continue;
    NSEntityDescription *targetRoot = [_model rootOf:target.entity];
    NSDictionary *targetKey = [_codec keyOfObject:target];
    NSString *text = targetKey.count ? [NSString stringWithFormat:@"%@ %@", targetRoot.name, [_codec keyTextOf:targetKey entity:targetRoot]] : nil;
    NSString *property = [_model.mapper propertyForRelationship:toOne];
    NSString *bind = [property stringByAppendingString:@"@odata.bind"];
    NSNumber *at = text ? inBatch[text] : nil;
    BOOL later = at.unsignedIntegerValue > index || (text && [toCome containsObject:text]);
    if (!later || !body[bind]) continue;
    if (!sent) sent = [body mutableCopy];
    [sent removeObjectForKey:bind];
    [names addObject:toOne.name];
    values[property] = agreed[property] ?: [NSNull null];
    if (at.unsignedIntegerValue > index) {
      [links addObject:@{ @"request": [_requests upsertOf:object entity:root key:key properties:[NSSet setWithObject:toOne.name] insert:NO
                                                  checked:NO etag:nil],
                          @"index": @(index), @"relationship": toOne, @"value": [_codec JSONKeyOfObject:target] }];
    }
  }
  NSArray *properties = ODSUnarchive([entry valueForKey:@"properties"]);
  NSDictionary *agreedValues = [agreed count] ? [_codec valuesFromShadow:agreed entity:[_codec entityOfRow:agreed entity:object.entity]] : @{};
  NSDictionary *mine = [_codec valuesOfObject:object];
  for (NSRelationshipDescription *set in [_model setsOf:object.entity]) {
    if (operation == ODataSyncOperationUpdate && properties && ![properties containsObject:set.name]) continue;
    NSString *property = [_model.mapper propertyForRelationship:set];
    NSArray *agreedRow = [agreed[property] isKindOfClass:[NSArray class]] ? agreed[property] : @[];
    NSArray *theirs = [agreedValues[set.name] isKindOfClass:[NSArray class]] ? agreedValues[set.name] : @[];
    NSArray *ours = [mine[set.name] isKindOfClass:[NSArray class]] ? mine[set.name] : @[];
    NSMutableArray *changes = [NSMutableArray array];
    for (NSDictionary *member in ours) if (![theirs containsObject:member]) [changes addObject:@[ member, @YES ]];
    for (NSDictionary *member in theirs) if (![ours containsObject:member]) [changes addObject:@[ member, @NO ]];
    if (!changes.count) continue;
    // The remote's members, by key text, as the row has them.
    NSMutableDictionary *there = [NSMutableDictionary dictionary];
    for (id json in agreedRow) {
      NSDictionary *memberKey = [json isKindOfClass:[NSDictionary class]] ? [_codec keyFromJSON:json entity:set.destinationEntity] : nil;
      if (memberKey) there[[_codec keyTextOf:memberKey entity:set.destinationEntity]] = json;
    }
    members[set.name] = there;
    [names addObject:set.name];
    values[property] = agreedRow;
    for (NSArray *change in changes) {
      NSDictionary *memberKey = change[0];
      BOOL adding = [change[1] boolValue];
      NSManagedObject *member = adding ? [_codec objectOfEntity:set.destinationEntity key:memberKey inContext:context] : nil;
      NSString *memberText = [_codec keyTextOf:memberKey entity:set.destinationEntity];
      id memberJSON = adding ? (member ? [_codec JSONKeyOfObject:member] : nil) : there[memberText];
      if (!memberJSON) continue;
      [links addObject:@{ @"request": [_requests referenceOf:path navigation:property member:[_codec pathOfEntity:set.destinationEntity key:memberKey]
                                                     adding:adding],
                          @"index": @(index), @"relationship": set, @"member": memberText, @"key": memberJSON, @"adding": @(adding) }];
    }
  }
  if (sent) {
    NSMutableDictionary *changed = [*request mutableCopy];
    changed[@"body"] = sent;
    *request = changed;
  }
  return names.count ? @{ @"names": names, @"values": values, @"members": members } : nil;
}

// A request sent after (-withhold:...) answered: what it sent, the
// remote's now (a member taken away there already, too).
- (void)took:(NSInteger)status headers:(NSDictionary *)headers link:(NSDictionary *)link
    withheld:(NSMutableDictionary *)withheld failed:(NSMutableSet *)failed
{
  NSRelationshipDescription *relationship = link[@"relationship"];
  BOOL removing = link[@"adding"] && ![link[@"adding"] boolValue];
  if (!((status >= 200 && status < 300) || (status == 404 && removing))) {
    [failed addObject:relationship.name];
    return;
  }
  NSString *etag = ODSHeader(headers, @"ETag");
  if (etag) withheld[@"etag"] = etag;
  if (!relationship.isToMany) {
    withheld[@"values"][[_model.mapper propertyForRelationship:relationship]] = link[@"value"];
    return;
  }
  NSMutableDictionary *there = withheld[@"members"][relationship.name];
  if (removing) [there removeObjectForKey:link[@"member"]];
  else there[link[@"member"]] = link[@"key"];
}

// The withheld of an entry whose request was taken, once what went after
// it is answered: each link or set the remote took all of agreed on as
// this side has it, the rest as the remote has it, and only those waiting.
- (void)settleWithheld:(NSDictionary *)withheld failed:(NSSet *)failed entry:(NSManagedObject *)entry context:(NSManagedObjectContext *)context
{
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  id key = ODSUnarchiveReporting([entry valueForKey:@"key"], NULL);
  NSManagedObject *object = root && [key isKindOfClass:[NSDictionary class]] ? [_codec objectOfEntity:root key:key inContext:context] : nil;
  if (!object) return;
  NSMutableSet *waiting = [NSMutableSet set];
  NSDictionary *mine = [_codec rowOfObject:object];
  NSMutableDictionary *row = [mine mutableCopy];
  for (NSString *name in withheld[@"names"]) {
    NSRelationshipDescription *relationship = object.entity.relationshipsByName[name];
    NSString *property = [_model.mapper propertyForRelationship:relationship];
    id there = relationship.isToMany ? [withheld[@"members"][name] allValues] : withheld[@"values"][property];
    BOOL same = relationship.isToMany ? ![failed containsObject:name] && [withheld[@"members"][name] count] == [mine[property] count]
                                      : [there isEqual:mine[property]];
    if (same) continue;
    [waiting addObject:name];
    row[property] = there ?: [NSNull null];
  }
  if ([self keepsShadowOf:entry]) {
    NSManagedObject *shadow = [_engine.store shadowOf:root.name keyText:[entry valueForKey:@"keyText"] remote:_remote inContext:context make:NO];
    [_engine agreeOn:row etag:withheld[@"etag"] ?: [shadow valueForKey:@"etag"] of:root keyText:[entry valueForKey:@"keyText"]
              remote:_remote context:context];
  }
  if (waiting.count) [entry setValue:ODSArchive(waiting.allObjects) forKey:@"properties"];
  else [context deleteObject:entry];
}

// One batch of what waits, from where the sync is in its order (*next),
// sent and saved: 1 more to send, 2 done (the remote said stop), 3 the end
// of the order, 0 failed. What is to come (toCome: inserts not sent
// yet) is said so as it goes.
- (NSInteger)sendBatchIn:(NSManagedObjectContext *)context order:(NSArray<NSManagedObjectID *> *)order next:(NSUInteger *)next
                  toCome:(NSMutableSet<NSString *> *)toCome size:(NSUInteger)size error:(NSError **)error
{
  NSMutableArray<NSManagedObject *> *entries = [NSMutableArray array];
  NSMutableArray<NSDictionary *> *requests = [NSMutableArray array];
  // The batch's own: {"requests":[...]}, and each request's "id" and comma.
  NSUInteger bytes = 16, budget = MAX(_remote.batchBytes, 1u);
  while (*next < order.count) {
    NSManagedObject *entry = [context existingObjectWithID:order[*next] error:NULL];
    BOOL waits = entry && !entry.isDeleted && ![[entry valueForKey:@"setAside"] boolValue];
    NSDictionary *request = waits ? [self requestOf:entry context:context] : nil;
    // Not past the budget: the next batch takes it (the first goes alone).
    NSUInteger more = request ? ODataJSONByteCount(request) + 16 : 0;
    if (request && requests.count && bytes + more > budget) break;
    (*next)++;
    if (entry) [toCome removeObject:ODSEntryName(entry)];
    if (!request) continue;
    [entries addObject:entry];
    [requests addObject:request];
    bytes += more;
    if (requests.count == size) break;
  }
  if (!requests.count) return [context save:error] ? 3 : 0;
  NSMutableDictionary<NSString *, NSNumber *> *inBatch = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < entries.count; i++) {
    if ([[entries[i] valueForKey:@"operation"] integerValue] == ODataSyncOperationInsert) inBatch[ODSEntryName(entries[i])] = @(i);
  }
  NSMutableArray<NSDictionary *> *links = [NSMutableArray array];
  NSMutableArray *withheld = [NSMutableArray array];
  for (NSUInteger i = 0; i < entries.count; i++) {
    NSDictionary *request = requests[i];
    NSDictionary *held = [self withhold:entries[i] request:&request index:i inBatch:inBatch toCome:toCome links:links context:context];
    requests[i] = request;
    [withheld addObject:held ? [@{ @"names": held[@"names"], @"values": [held[@"values"] mutableCopy],
                                   @"members": held[@"members"] } mutableCopy] : [NSNull null]];
  }
  for (NSDictionary *link in links) [requests addObject:link[@"request"]];
  OTSpan *span = [_engine.tracer startSpanNamed:@"upload batch" attributes:@{ @"odatasync.changes": @(requests.count) }];
  NSInteger batchStatus = 0;
  NSError *failure = nil;
  // One atomicity group: a service saves the changes together, as this
  // side saved them, its rules seeing them all, not each before the rest
  // has come (a reminder closed there by a service before the reminder it
  // follows came). Refused as one, they go again, each standing alone:
  // which was refused is said, and the rest go in. A service that takes a
  // JSON batch but no atomicity group (a 400 for the batch) is sent them
  // standing alone from then on. A peer takes each alone.
  NSDictionary<NSString *, ODataBatchPart *> *parts = nil;
  if (!_batchUnsupported) {
    BOOL together = requests.count > 1 && !_remote.peer && !_groupsUnsupported;
    NSMutableArray *grouped = [NSMutableArray arrayWithCapacity:requests.count];
    for (NSDictionary *request in requests) {
      NSMutableDictionary *each = [request mutableCopy];
      if (together) each[@"atomicityGroup"] = @"changes";
      [grouped addObject:each];
    }
    parts = [self sendBatch:grouped status:&batchStatus error:&failure];
    BOOL refused = NO;
    for (ODataBatchPart *part in together ? parts.allValues : @[]) refused = refused || part.status < 200 || part.status >= 300;
    if (together && !parts && batchStatus == 400) {
      failure = nil;
      parts = [self sendBatch:requests status:&batchStatus error:&failure];
      if (parts) _groupsUnsupported = YES;
    } else if (refused) {
      parts = [self sendBatch:requests status:&batchStatus error:&failure];
    }
  }
  if (!parts && (_batchUnsupported || batchStatus == 400 || batchStatus == 404 || batchStatus == 405 || batchStatus == 415 || batchStatus == 501)) {
    // No JSON $batch there: one at a time.
    _batchUnsupported = YES;
    failure = nil;
  } else if (!parts) {
    [span end];
    [context save:NULL];
    if (error) *error = batchStatus == 401 ? ODSError(401, failure.localizedDescription ?: @"Not signed in") : failure;
    return 0;
  }
  BOOL stop = NO;
  NSMutableArray<NSNumber *> *taken = [NSMutableArray array];
  for (NSUInteger i = 0; i < entries.count && !stop; i++) {
    NSInteger status;
    NSDictionary *headers;
    NSData *body;
    if (parts) {
      ODataBatchPart *part = parts[[NSString stringWithFormat:@"%lu", (unsigned long)i + 1]];
      status = part ? part.status : 0;
      headers = part.headers ?: @{};
      body = part.body;
    } else {
      status = [self sendAlone:requests[i] headers:&headers body:&body error:&failure];
      if (!status) {
        [span end];
        [context save:NULL];
        if (error) *error = failure;
        return 0;
      }
    }
    id held = withheld[i];
    if (![self take:status headers:headers body:body of:entries[i] withheld:held == [NSNull null] ? nil : held context:context stop:&stop
              error:error]) {
      [span end];
      [context save:NULL];
      return 0;
    }
    if (status >= 200 && status < 300 && held != [NSNull null]) [taken addObject:@(i)];
  }
  // What went after: each of an entry taken. Stopped before it, what it
  // withheld waits (its entry an update of it).
  NSMutableDictionary<NSNumber *, NSMutableSet *> *failed = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < links.count && !stop; i++) {
    NSNumber *index = links[i][@"index"];
    if (![taken containsObject:index]) continue;
    NSInteger status = 0;
    NSDictionary *headers = @{};
    NSData *body = nil;
    if (parts) {
      ODataBatchPart *part = parts[[NSString stringWithFormat:@"%lu", (unsigned long)(entries.count + i + 1)]];
      status = part ? part.status : 0;
      headers = part.headers ?: @{};
    } else {
      status = [self sendAlone:links[i][@"request"] headers:&headers body:&body error:&failure];
    }
    if (!failed[index]) failed[index] = [NSMutableSet set];
    [self took:status headers:headers link:links[i] withheld:withheld[index.unsignedIntegerValue] failed:failed[index]];
  }
  if (!stop) {
    for (NSNumber *index in taken) {
      [self settleWithheld:withheld[index.unsignedIntegerValue] failed:failed[index] ?: [NSSet set] entry:entries[index.unsignedIntegerValue]
                   context:context];
    }
  }
  [span end];
  if (![context save:error]) return 0;
  return stop ? 2 : 1;
}

- (BOOL)sendIn:(NSManagedObjectContext *)context error:(NSError **)error
{
  if (![self refreshIn:context error:error]) return NO;
  // What will go: rows' changes (merged attributes go after, merging); as
  // it goes, how many of them no longer wait, however each was settled.
  NSUInteger total = [self rowsWaitingIn:context];
  if (total) [_engine beginPhase:ODataSyncPhaseSending remote:_remote total:total];
  NSUInteger size = MAX(_remote.batchSize, 1u);
  // The order, once a pass (each entry's object read once, not each
  // batch): an entry then sent, or passed by. What waits at its end (what
  // entries withheld, their targets in now; a conflict's outcome to send)
  // goes in another pass, three at most.
  NSArray<NSManagedObjectID *> *order = nil;
  NSMutableSet<NSString *> *toCome = nil;
  NSUInteger next = 0, passes = 0;
  // A batch at a time, each saved and let go of (the context emptied): as
  // many changes as there are, in the memory of a batch.
  for (;;) {
    NSInteger sent;
    NSError *failure = nil;
    @autoreleasepool {
      if (!order) {
        NSArray<NSManagedObject *> *pending = [self pendingIn:context];
        order = [pending valueForKey:@"objectID"];
        toCome = [NSMutableSet set];
        for (NSManagedObject *entry in pending) {
          if ([[entry valueForKey:@"operation"] integerValue] == ODataSyncOperationInsert) [toCome addObject:ODSEntryName(entry)];
        }
        next = 0;
        passes++;
      }
      NSError *e = nil;
      sent = [self sendBatchIn:context order:order next:&next toCome:toCome size:size error:&e];
      failure = e;
      [context reset];
    }
    if (!sent) {
      if (error) *error = failure;
      return NO;
    }
    NSUInteger waiting = [self rowsWaitingIn:context];
    if (total) [_engine phaseDone:total > waiting ? total - waiting : 0];
    if (sent == 2) return YES;
    if (sent == 3) {
      if (!waiting || passes >= 3) return YES;
      order = nil;
    }
  }
}

// Rows' changes waiting to be sent: not set aside, not merged attributes,
// not a version to read again.
- (NSUInteger)rowsWaitingIn:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND setAside != YES AND operation != %d AND operation != %d", _remote.identifier,
                                                     (int)ODataSyncOperationMerge, (int)ODataSyncOperationRefresh];
  NSUInteger count = [context countForFetchRequest:fetch error:NULL];
  return count == NSNotFound ? 0 : count;
}

- (BOOL)collect:(NSError **)error
{
  NSManagedObjectContext *context = [_engine.store contextWritingAs:ODataSyncBookkeepingAuthor];
  __block BOOL ok = NO;
  __block NSError *failure = nil;
  [context performBlockAndWait:^{
    NSError *e = nil;
    ok = [self fillOutbox:context error:&e];
    failure = e;
  }];
  if (!ok && error) *error = failure;
  return ok;
}

- (BOOL)upload:(NSError **)error
{
  // A conflict's outcome is the remote's, written as coming from it (and
  // so passed on to the others).
  NSManagedObjectContext *context = [_engine.store contextWritingAs:[ODataSyncDownAuthorPrefix stringByAppendingString:_remote.identifier]];
  __block BOOL ok = NO;
  __block NSError *failure = nil;
  [context performBlockAndWait:^{
    NSError *e = nil;
    ok = [self fillOutbox:context error:&e] && [self sendIn:context error:&e] &&
         [[[ODSMergeExchange alloc] initWithEngine:self->_engine remote:self->_remote] exchangeIn:context error:&e];
    failure = e;
  }];
  if (!ok && error) *error = failure;
  return ok;
}

@end
