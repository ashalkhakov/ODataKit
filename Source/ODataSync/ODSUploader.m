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

@implementation ODSUploader {
  ODataSyncEngine *_engine;
  ODataSyncRemote *_remote;
  ODSModel *_model;
  ODSCodec *_codec;
  ODSRequests *_requests;
  ODataClient *_client;
  NSArray<NSEntityDescription *> *_entities;
  BOOL _batchUnsupported;
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
  NSSet *toOnes = [NSSet setWithArray:[[_model toOnesOf:entity] valueForKey:@"name"]];
  for (NSPropertyDescription *property in properties) {
    if ([attributes containsObject:property.name] || [toOnes containsObject:property.name]) [names addObject:property.name];
  }
  return names.count ? names : nil;
}

// A change into the entry of its object. Relayed: it came from another
// remote, and so is no authority's (-checksVersionsOf:).
- (void)fold:(ODataSyncOperation)operation properties:(NSSet<NSString *> *)properties entity:(NSEntityDescription *)root
         key:(NSDictionary *)key relayed:(BOOL)relayed context:(NSManagedObjectContext *)context sequence:(int64_t *)sequence
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
    [entry setValue:@((*sequence)++) forKey:@"sequence"];
    [entry setValue:@(relayed) forKey:@"relayed"];
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
  int64_t sequence = [_engine.store nextSequenceIn:context];
  NSPersistentHistoryToken *last = token;
  NSSet *bookkeeping = [NSSet setWithObjects:ODSRemoteStateEntity, ODSOutboxEntity, ODSShadowEntity, ODSTombstoneEntity, nil];
  // Made and gone within what is read now: its deletion is nothing to send.
  NSMutableSet<NSManagedObjectID *> *fleeting = [NSMutableSet set];
  for (NSPersistentHistoryTransaction *transaction in result.result) {
    last = transaction.token ?: last;
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
    for (NSPersistentHistoryChange *change in transaction.changes) {
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
        [self fold:ODataSyncOperationDelete properties:nil entity:root key:key relayed:relayed context:context sequence:&sequence];
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
        [self fold:ODataSyncOperationInsert properties:nil entity:root key:key relayed:relayed context:context sequence:&sequence];
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
        [self fold:ODataSyncOperationUpdate properties:names ? rest : nil entity:root key:key relayed:relayed context:context sequence:&sequence];
      }
    }
  }
  if (last) [state setValue:[NSKeyedArchiver archivedDataWithRootObject:last requiringSecureCoding:YES error:NULL] forKey:@"historyToken"];
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

- (NSArray<NSManagedObject *> *)pendingIn:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND setAside != YES", _remote.identifier];
  NSArray *entries = [context executeFetchRequest:fetch error:NULL];
  // Upserts parents first, deletions children first; in order within.
  NSMutableDictionary *place = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < _entities.count; i++) place[_entities[i].name] = @(i);
  return [entries sortedArrayUsingComparator:^NSComparisonResult(NSManagedObject *a, NSManagedObject *b) {
    BOOL deleteA = [[a valueForKey:@"operation"] integerValue] == ODataSyncOperationDelete;
    BOOL deleteB = [[b valueForKey:@"operation"] integerValue] == ODataSyncOperationDelete;
    if (deleteA != deleteB) return deleteA ? NSOrderedDescending : NSOrderedAscending;
    NSInteger pa = [place[[a valueForKey:@"entityType"]] integerValue], pb = [place[[b valueForKey:@"entityType"]] integerValue];
    if (pa != pb) return (deleteA ? pa < pb : pa > pb) ? NSOrderedDescending : NSOrderedAscending;
    return [[a valueForKey:@"sequence"] compare:[b valueForKey:@"sequence"]];
  }];
}

// The request an entry is sent as: {method, url, headers, body}; nil when
// it has become nothing (an object made and gone before it was sent).
- (NSDictionary *)requestOf:(NSManagedObject *)entry context:(NSManagedObjectContext *)context
{
  NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
  NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
  if (!root || !key) {
    [context deleteObject:entry];
    return nil;
  }
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
      // would put an older version over a newer one. The remote's is taken.
      [_codec applyJSON:agreed toObject:object];
      [context deleteObject:entry];
      return nil;
    }
    // What the remote has already (passed on there by another way, or come
    // from it): not sent again.
    NSSet *differ = ODSChangedNames([_codec valuesOfObject:object], [_codec valuesFromJSON:agreed entity:root]);
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
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND operation == %d", _remote.identifier, (int)ODataSyncOperationRefresh];
  ODSDownloader *down = [[ODSDownloader alloc] initWithEngine:_engine remote:_remote];
  for (NSManagedObject *entry in [context executeFetchRequest:fetch error:NULL]) {
    NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
    NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
    if (root && key && ![down refreshObjectOfEntity:root key:key context:context error:error]) return NO;
    [context deleteObject:entry];
  }
  return YES;
}

// Each entry by its answer. NO when the rest should wait for the next sync
// (a remote that is down, or refuses who is asking: the error).
- (BOOL)take:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body of:(NSManagedObject *)entry
     context:(NSManagedObjectContext *)context stop:(BOOL *)stop error:(NSError **)error
{
  ODataSyncOperation operation = [[entry valueForKey:@"operation"] integerValue];
  NSString *entityName = [entry valueForKey:@"entityType"];
  NSString *keyText = [entry valueForKey:@"keyText"];
  BOOL both = [self checksVersionsOf:entry];
  [entry setValue:@([[entry valueForKey:@"attempts"] integerValue] + 1) forKey:@"attempts"];
  if ((status >= 200 && status < 300) || (status == 404 && operation == ODataSyncOperationDelete)) {
    if (both) {
      // What both have now: the device's version.
      NSEntityDescription *root = _model.model.entitiesByName[entityName];
      NSManagedObject *object = operation == ODataSyncOperationDelete ? nil
          : [_codec objectOfEntity:root key:ODSUnarchive([entry valueForKey:@"key"]) inContext:context];
      [_engine agreeOn:object ? [_codec rowOfObject:object] : nil etag:ODSHeader(headers, @"ETag") of:root keyText:keyText
                remote:_remote context:context];
    }
    [context deleteObject:entry];
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

- (BOOL)sendIn:(NSManagedObjectContext *)context error:(NSError **)error
{
  if (![self refreshIn:context error:error]) return NO;
  // What will go: rows' changes (merged attributes go after, merging).
  NSPredicate *rows = [NSPredicate predicateWithFormat:@"operation != %d", (int)ODataSyncOperationMerge];
  [_engine beginPhase:ODataSyncPhaseSending remote:_remote total:[[self pendingIn:context] filteredArrayUsingPredicate:rows].count];
  NSUInteger size = MAX(_remote.batchSize, 1u);
  for (;;) {
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableArray *requests = [NSMutableArray array];
    for (NSManagedObject *entry in [self pendingIn:context]) {
      NSDictionary *request = [self requestOf:entry context:context];
      if (!request) continue;
      [entries addObject:entry];
      [requests addObject:request];
      if (requests.count == size) break;
    }
    if (!requests.count) return [context save:error];
    OTSpan *span = [_engine.tracer startSpanNamed:@"upload batch" attributes:@{ @"odatasync.changes": @(requests.count) }];
    NSInteger batchStatus = 0;
    NSError *failure = nil;
    NSDictionary<NSString *, ODataBatchPart *> *parts = _batchUnsupported ? nil : [self sendBatch:requests status:&batchStatus error:&failure];
    if (!parts && (_batchUnsupported || batchStatus == 400 || batchStatus == 404 || batchStatus == 405 || batchStatus == 415 || batchStatus == 501)) {
      // No JSON $batch there: one at a time.
      _batchUnsupported = YES;
      failure = nil;
    } else if (!parts) {
      [span end];
      [context save:NULL];
      if (error) *error = batchStatus == 401 ? ODSError(401, failure.localizedDescription ?: @"Not signed in") : failure;
      return NO;
    }
    BOOL stop = NO;
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
          return NO;
        }
      }
      if (![self take:status headers:headers body:body of:entries[i] context:context stop:&stop error:error]) {
        [span end];
        [context save:NULL];
        return NO;
      }
    }
    [span end];
    if (![context save:error]) return NO;
    if (stop) return YES;
  }
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
