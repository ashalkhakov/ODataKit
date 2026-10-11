// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The service's part of the causal history (docs/offline-sync.md, 12),
// and what a peer server shares with it: deletions kept, and an insert of
// a deleted key judged by the histories.

#import "ODataSyncService.h"
#import "ODSService.h"
#import "ODSInternal.h"
#import <ODataKit/ODataError.h>

NSString * const ODSClientAuthor = @"ODataSync.client";

@implementation ODataSyncSetHandler {
  NSDate *_pruned;
}

- (NSString *)authorOfRequest:(ODataRequest *)request values:(NSDictionary<NSString *, id> *)values
{
  NSAttributeDescription *versions = [self.engine.model versionsAttributeOf:self.entity];
  BOOL sent = versions && values[versions.name] && values[versions.name] != [NSNull null];
  return sent || [request valueForHeader:ODataSyncVersionsHeader] ? ODSClientAuthor : nil;
}

- (void)writeAs:(ODataRequest *)request values:(NSDictionary *)values
{
  NSString *author = [self authorOfRequest:request values:values];
  NSManagedObjectContext *context = request.context;
  if (author && [context respondsToSelector:@selector(setTransactionAuthor:)]) context.transactionAuthor = author;
}

- (NSString *)keyTextOf:(NSDictionary *)key
{
  ODSCodec *codec = self.engine.codec;
  ODSModel *model = self.engine.model;
  return key ? [codec keyTextOf:key entity:[model rootOf:self.entity]] : nil;
}

// Merged attributes merged into what the object has, never written over it
// (docs/offline-sync.md, 14.5): a client that sends the whole state, and the
// MergeAttributes action, which sends a delta. nil, the reply failed, for
// one that does not merge.
- (NSDictionary *)valuesMerging:(NSDictionary<NSString *, id> *)values into:(nullable NSManagedObject *)object reply:(ODataReply *)reply
{
  ODataSyncEngine *engine = self.engine;
  NSArray<NSAttributeDescription *> *merged = [engine.model mergedAttributesOf:object ? object.entity : self.entity];
  if (!merged.count) return values;
  NSMutableDictionary *result = [values mutableCopy];
  for (NSAttributeDescription *attribute in merged) {
    id sent = values[attribute.name];
    if (![sent isKindOfClass:[NSData class]]) continue;  // absent, or null: left to the store
    id<ODataSyncMerging> merger = [engine mergerForName:[engine.model mergerNameOf:attribute]];
    if (!merger) continue;  // no merger here: stored as sent, as before
    NSError *error = nil;
    NSData *state = [merger stateByMerging:sent intoState:object ? [object valueForKey:attribute.name] : nil error:&error];
    if (!state) {
      [reply failWithError:ODataServiceError(400, [NSString stringWithFormat:@"%@ does not merge: %@", attribute.name,
                                                                                error.localizedDescription ?: @"not a state or delta"])];
      return nil;
    }
    result[attribute.name] = state;
  }
  return result;
}

// What is derived from the merged attributes a write merged, set again
// (the merger's -mergedAttribute:ofObject:).
- (void)mergedAttributesIn:(NSDictionary *)values ofObject:(NSManagedObject *)object
{
  ODataSyncEngine *engine = self.engine;
  for (NSAttributeDescription *attribute in object ? [engine.model mergedAttributesOf:object.entity] : @[]) {
    if (![values[attribute.name] isKindOfClass:[NSData class]]) continue;
    id<ODataSyncMerging> merger = [engine mergerForName:[engine.model mergerNameOf:attribute]];
    if ([merger respondsToSelector:@selector(mergedAttribute:ofObject:)]) [merger mergedAttribute:attribute ofObject:object];
  }
}

- (NSManagedObject *)insertObjectWithValues:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSManagedObject *made = [self insertMergingValues:values request:request reply:reply];
  [self mergedAttributesIn:values ofObject:made];
  return made;
}

- (NSManagedObject *)insertMergingValues:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  values = [self valuesMerging:values into:nil reply:reply];
  if (!values) return nil;
  ODataSyncEngine *engine = self.engine;
  ODSCodec *codec = engine.codec;
  ODSModel *model = engine.model;
  NSEntityDescription *root = [model rootOf:self.entity];
  NSString *keyText = [self keyTextOf:[codec keyFromValues:values entity:root]];
  // Now and then, deletions older than they are kept are forgotten.
  if (!_pruned || -[_pruned timeIntervalSinceNow] > 3600) {
    _pruned = [NSDate date];
    [engine pruneTombstones];
  }
  if (keyText && [engine.store isDeleted:root.name keyText:keyText inContext:request.context]) {
    NSDictionary *deleted = [engine.store deletedVersionsOf:root.name keyText:keyText inContext:request.context];
    NSAttributeDescription *attribute = [model versionsAttributeOf:self.entity];
    NSDictionary *sent = attribute ? ODSVersionsFromText(values[attribute.name]) : @{};
    ODSOrder order = deleted.count && sent.count ? ODSCompareVersions(sent, deleted) : ODSOrderBefore;
    if (order == ODSOrderConcurrent) {
      // Made without knowing of the deletion: the client settles it, given
      // the deletion's history.
      NSError *error = [NSError errorWithDomain:ODataServiceErrorDomain code:409 userInfo:@{
        NSLocalizedDescriptionKey: @"Deleted here by one that did not know of this change",
        ODataErrorDetailsKey: @[ @{ @"code": ODSDeletedCode, @"message": ODSTextOfVersions(deleted),
                                    @"target": attribute ? [codec.mapper propertyForAttribute:attribute] : @"" } ] }];
      [reply failWithError:error];
      return nil;
    }
    if (order != ODSOrderAfter) {
      // A copy older than the deletion (or no history to tell by).
      [reply failWithError:ODataServiceError(410, @"Deleted here")];
      return nil;
    }
    // Made again by one that knew of the deletion.
    [engine.store forgetDeletionOf:root.name keyText:keyText inContext:request.context];
  }
  [self writeAs:request values:values];
  return [super insertObjectWithValues:values request:request reply:reply];
}

- (NSManagedObject *)updateObject:(NSManagedObject *)object values:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request
                            reply:(ODataReply *)reply
{
  NSDictionary *merged = [self valuesMerging:values into:object reply:reply];
  if (!merged) return nil;
  [self writeAs:request values:merged];
  NSManagedObject *updated = [super updateObject:object values:merged request:request reply:reply];
  [self mergedAttributesIn:values ofObject:updated];
  return updated;
}

- (void)deleteObject:(NSManagedObject *)object request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [self writeAs:request values:nil];
  // The deletion's history, as the client sent it, for the tombstone.
  NSString *sent = [request valueForHeader:ODataSyncVersionsHeader];
  NSString *keyText = [self keyTextOf:[self.engine.codec keyOfObject:object]];
  if (sent.length && keyText) {
    ODSNoteSentDeletion(request.context, [[self.engine.model rootOf:self.entity].name stringByAppendingFormat:@" %@", keyText], sent);
  }
  if (keyText) ODSForgetMerges(request.context, [self.engine.model rootOf:self.entity].name, keyText);
  [super deleteObject:object request:request reply:reply];
}

@end

static NSString *ODSBase64Of(NSData *data)
{
  return [data base64EncodedStringWithOptions:0] ?: @"";
}

static NSData *ODSDataOfBase64(id text)
{
  return [text isKindOfClass:[NSString class]] ? [[NSData alloc] initWithBase64EncodedString:text options:0] : nil;
}

// The replica the horizon is kept under, among an object's ODSMergeSeen:
// what its merged attribute was last collected with.
static NSString * const ODSMergeHorizonReplica = @"ODataSync.collected";

static NSArray<NSManagedObject *> *ODSMergeRows(NSManagedObjectContext *context, NSString *entityType, NSString *keyText, NSString *property)
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSMergeSeenEntity];
  fetch.predicate = property ? [NSPredicate predicateWithFormat:@"entityType == %@ AND keyText == %@ AND property == %@", entityType, keyText, property]
                             : [NSPredicate predicateWithFormat:@"entityType == %@ AND keyText == %@", entityType, keyText];
  return [context executeFetchRequest:fetch error:NULL] ?: @[];
}

static NSManagedObject *ODSMergeRow(NSArray<NSManagedObject *> *rows, NSString *replica)
{
  for (NSManagedObject *row in rows) {
    if ([[row valueForKey:@"replica"] isEqual:replica]) return row;
  }
  return nil;
}

static NSManagedObject *ODSMakeMergeRow(NSManagedObjectContext *context, NSString *entityType, NSString *keyText, NSString *property,
                                        NSString *replica)
{
  NSManagedObject *row = [NSEntityDescription insertNewObjectForEntityForName:ODSMergeSeenEntity inManagedObjectContext:context];
  [row setValue:entityType forKey:@"entityType"];
  [row setValue:keyText forKey:@"keyText"];
  [row setValue:property forKey:@"property"];
  [row setValue:replica forKey:@"replica"];
  return row;
}

// version has seen all horizon has: the merger's meet of the two is
// horizon's own (versionMeeting: gives equal versions as equal bytes).
static BOOL ODSCovers(id<ODataSyncMerging> merger, NSData *version, NSData *horizon)
{
  return [[merger versionMeeting:version andVersion:horizon] isEqual:[merger versionMeeting:horizon andVersion:horizon]];
}

// What every replica heard from within retention has seen of an object's
// merged attribute, the service among them (what it has): the meet of what
// each last said it has. A replica not heard from since is let go of.
static NSData *ODSSeenByAll(NSManagedObjectContext *context, NSArray<NSManagedObject *> *rows, NSData *service,
                            id<ODataSyncMerging> merger, NSTimeInterval retention)
{
  NSDate *since = retention > 0 ? [NSDate dateWithTimeIntervalSinceNow:-retention] : nil;
  NSData *meet = service;
  BOOL replicas = NO;
  for (NSManagedObject *row in rows) {
    if (row.isDeleted || [[row valueForKey:@"replica"] isEqual:ODSMergeHorizonReplica]) continue;
    if (since && [[row valueForKey:@"seen"] compare:since] == NSOrderedAscending) {
      [context deleteObject:row];
      continue;
    }
    NSData *theirs = [row valueForKey:@"version"];
    if (!theirs) continue;
    meet = [merger versionMeeting:meet andVersion:theirs];
    replicas = YES;
  }
  return replicas ? meet : nil;
}

NSDictionary *ODSAnswerMergeAttributes(ODataSyncEngine *engine, NSString *replica, NSArray *items, ODataReply *reply, BOOL record,
                                       NSTimeInterval retention)
{
  ODataRequest *request = reply.request;
  ODataService *service = request.service;
  NSManagedObjectContext *context = request.context;
  if (![items isKindOfClass:[NSArray class]] || !service || !context) {
    [reply failWithError:ODataServiceError(400, @"Items: a list of { EntitySet, Key, Property, Version, Delta }")];
    return nil;
  }
  if (![replica isKindOfClass:[NSString class]] || [replica isEqual:ODSMergeHorizonReplica]) replica = nil;
  ODSCodec *codec = engine.codec;
  NSMutableArray *answers = [NSMutableArray array];
  // Each object's ETag before the call changed it, and the answers about it.
  NSMutableDictionary<NSManagedObjectID *, NSString *> *etags = [NSMutableDictionary dictionary];
  NSMutableArray<NSArray *> *answered = [NSMutableArray array];
  for (NSDictionary *item in items) {
    NSString *(^failed)(NSString *) = ^NSString *(NSString *why) {
      [answers addObject:@{ @"Error": why }];
      return nil;
    };
    if (![item isKindOfClass:[NSDictionary class]] || ![item[@"EntitySet"] isKindOfClass:[NSString class]] ||
        ![item[@"Property"] isKindOfClass:[NSString class]] || ![item[@"Key"] isKindOfClass:[NSDictionary class]]) {
      failed(@"An item names an EntitySet, a Key and a Property");
      continue;
    }
    ODataEntitySetHandler *handler = [service handlerForEntitySet:item[@"EntitySet"]];
    NSEntityDescription *entity = handler.entity;
    NSDictionary *key = entity ? [codec keyFromJSON:item[@"Key"] entity:[engine.model rootOf:entity]] : nil;
    if (!key) {
      failed(@"No such entity set, or no key of it");
      continue;
    }
    // As the request may see it: a user merges into their own only.
    NSMutableArray *conditions = [NSMutableArray array];
    for (NSString *name in key) [conditions addObject:[NSPredicate predicateWithFormat:@"%K == %@", name, key[name]]];
    NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:request];
    if (visible) [conditions addObject:visible];
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity.name];
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:conditions];
    fetch.fetchLimit = 1;
    NSManagedObject *object = [[context executeFetchRequest:fetch error:NULL] firstObject];
    NSAttributeDescription *attribute = nil;
    for (NSAttributeDescription *a in object ? [engine.model mergedAttributesOf:object.entity] : @[]) {
      if ([[codec.mapper propertyForAttribute:a] isEqualToString:item[@"Property"]]) attribute = a;
    }
    id<ODataSyncMerging> merger = attribute ? [engine mergerForName:[engine.model mergerNameOf:attribute]] : nil;
    if (!object || !merger) {
      failed(object ? @"No merged attribute of that name" : @"No such object");
      continue;
    }
    NSString *entityType = [engine.model rootOf:entity].name;
    NSString *keyText = [codec keyTextOf:key entity:[engine.model rootOf:entity]];
    NSArray *rows = record ? ODSMergeRows(context, entityType, keyText, attribute.name) : @[];
    NSManagedObject *horizonRow = ODSMergeRow(rows, ODSMergeHorizonReplica);
    NSData *horizon = [horizonRow valueForKey:@"version"];
    NSData *theirs = ODSDataOfBase64(item[@"Version"]);
    if (!theirs.length) theirs = [merger versionOfState:nil];
    NSData *state = [object valueForKey:attribute.name];
    if (!etags[object.objectID]) etags[object.objectID] = [service etagOfObject:object];

    // Behind what was collected (away longer than the retention, or only
    // ever through peers): what it has cannot be merged, nor told what it
    // lacks. It is answered the whole state and the horizon, and re-bases
    // on them (docs/offline-sync.md, 14.4); nothing it sent is taken.
    if (horizon.length && !ODSCovers(merger, theirs, horizon)) {
      [answers addObject:@{ @"Reset": @YES, @"State": ODSBase64Of(state), @"Horizon": ODSBase64Of(horizon),
                            @"Version": ODSBase64Of([merger versionOfState:state]) }];
      continue;
    }
    NSData *delta = ODSDataOfBase64(item[@"Delta"]);
    if (delta.length) {
      // One that does not merge is this item's error, not the call's.
      NSError *error = nil;
      if (![merger stateByMerging:delta intoState:state error:&error]) {
        failed([NSString stringWithFormat:@"%@ does not merge: %@", item[@"Property"], error.localizedDescription ?: @"not a state or delta"]);
        continue;
      }
      // Through the handler: merged, written as any update is.
      if (![handler updateObject:object values:@{ attribute.name: delta } request:request reply:reply]) return nil;
      state = [object valueForKey:attribute.name];
      // What every copy had seen when it was collected comes back no more:
      // the delta merged as it is, then what it brought back of that let go
      // again. (Not the delta trimmed first: a delta is no state, and a
      // merger that reads states only answers nothing for it, so all it
      // brought would be lost.)
      if (horizon.length) {
        NSData *collected = [merger stateByCollecting:state seenBy:horizon];
        if (collected && ![collected isEqual:state]) {
          [object setValue:collected forKey:attribute.name];
          state = collected;
        }
      }
    }
    // What the device lacks, before anything is collected: what is collected
    // now it has not seen yet, and is told (then collects it itself).
    NSData *lacks = [merger deltaOfState:state sinceVersion:theirs];
    if (!lacks) {
      failed([NSString stringWithFormat:@"%@ is no state its merger reads", item[@"Property"]]);
      continue;
    }
    NSData *seen = nil;
    if (record) {
      // What the replica says it has: not what it is answered, which it may
      // never get (a lost answer), or fail to merge.
      if (replica) {
        NSManagedObject *mine = ODSMergeRow(rows, replica);
        if (!mine) {
          mine = ODSMakeMergeRow(context, entityType, keyText, attribute.name, replica);
          rows = [rows arrayByAddingObject:mine];
        }
        [mine setValue:theirs forKey:@"version"];
        [mine setValue:[NSDate date] forKey:@"seen"];
      }
      seen = ODSSeenByAll(context, rows, [merger versionOfState:state], merger, retention);
    }
    if (seen.length) {
      NSData *collected = [merger stateByCollecting:state seenBy:seen];
      if (collected && ![collected isEqual:state]) {
        [object setValue:collected forKey:attribute.name];
        state = collected;
        // A replica that has not seen all this is behind it from now on.
        if (!horizonRow) horizonRow = ODSMakeMergeRow(context, entityType, keyText, attribute.name, ODSMergeHorizonReplica);
        [horizonRow setValue:seen forKey:@"version"];
        [horizonRow setValue:[NSDate date] forKey:@"seen"];
      }
    }
    NSMutableDictionary *answer = [NSMutableDictionary dictionary];
    answer[@"Delta"] = ODSBase64Of(lacks);
    answer[@"Version"] = ODSBase64Of([merger versionOfState:state]);
    [answered addObject:@[ object, answer ]];
    if (seen.length) answer[@"SeenByAll"] = ODSBase64Of(seen);
    [answers addObject:answer];
  }
  // The rows a merge changed are written as any update is, and stamped as
  // they are saved: saved before the answer, which tells each its ETag as it
  // is kept now, and as it was (the device moves its own on from that one,
  // else its next write of the row is a conflict of the merge's making).
  // Saved here, the call is its own: inside an atomic $batch change set it
  // would not go or fail with the rest (devices send it alone).
  if (context.hasChanges) {
    NSError *error = nil;
    if (![context save:&error]) {
      [reply failWithError:error ?: ODataServiceError(500, @"The merges could not be saved")];
      return nil;
    }
  }
  for (NSArray *pair in answered) {
    NSManagedObject *object = pair[0];
    NSMutableDictionary *answer = pair[1];
    NSString *was = etags[object.objectID], *now = [service etagOfObject:object];
    if (was && now && ![now isEqualToString:was]) {
      answer[@"ETag"] = now;
      answer[@"PreviousETag"] = was;
      // And the history it was stamped with: the device's copy has seen it.
      NSAttributeDescription *versions = [engine.model versionsAttributeOf:object.entity];
      id text = versions ? [object valueForKey:versions.name] : nil;
      if ([text isKindOfClass:[NSString class]]) answer[@"Versions"] = text;
    }
  }
  return @{ @"Items": answers };
}

// What the service kept of a deleted object's merged attributes, gone with it.
void ODSForgetMerges(NSManagedObjectContext *context, NSString *entityType, NSString *keyText)
{
  // A peer server's (a device's model) keeps none.
  if (!context.persistentStoreCoordinator.managedObjectModel.entitiesByName[ODSMergeSeenEntity]) return;
  for (NSManagedObject *row in ODSMergeRows(context, entityType, keyText, nil)) [context deleteObject:row];
}

// The service's operations when it has none of its own: PeerToken, and
// MergeAttributes.
@implementation ODSServiceOperations
// Items is a list of objects: what the runtime cannot tell.
+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"mergeAttributesWithReplica:items:reply:.items": @"Edm.Untyped" };
}

- (NSDictionary *)peerTokenWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint reply:(ODataReply *)reply
{
  ODataSyncService *sync = self.sync;
  if (!sync) {
    [reply failWithError:ODataServiceError(501, @"This service issues no peer tokens")];
    return nil;
  }
  return [sync peerTokenWithReplica:replica thumbprint:thumbprint reply:reply];
}

- (NSDictionary *)mergeAttributesWithReplica:(NSString *)replica items:(NSArray *)items reply:(ODataReply *)reply
{
  ODataSyncService *sync = self.sync;
  if (sync) return [sync mergeAttributesWithReplica:replica items:items reply:reply];
  return ODSAnswerMergeAttributes(self.engine, replica, items, reply, NO, 0);
}
@end

@implementation ODataSyncService

+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(NSString *)configuration
{
  if (model.entitiesByName[ODSTombstoneEntity]) return;
  // The service's synced sets (those that keep version vectors): each
  // object a device sends looked up by its key.
  ODSModel *synced = [[ODSModel alloc] initWithModel:model];
  NSMutableArray *roots = [NSMutableArray array];
  for (NSEntityDescription *entity in model.entities) {
    if (!entity.superentity && [synced versionsAttributeOf:entity]) [roots addObject:entity];
  }
  ODSIndexKeys(model, roots);
  NSArray *added = @[ ODSTombstoneEntityDescription(), ODSMergeSeenEntityDescription() ];
  model.entities = [model.entities arrayByAddingObjectsFromArray:added];
  if (configuration) {
    NSArray *entities = [model entitiesForConfiguration:configuration] ?: @[];
    [model setEntities:[entities arrayByAddingObjectsFromArray:added] forConfiguration:configuration];
  }
}

- (instancetype)initWithService:(ODataService *)service
{
  self = [super init];
  if (!self) return nil;
  _service = service;
  _engine = [[ODataSyncEngine alloc] initServiceWithCoordinator:service.coordinator];
  NSMutableArray *unchecked = [NSMutableArray array];
  ODSModel *model = _engine.model;
  for (NSEntityDescription *entity in service.model.entities) {
    if (entity.superentity || ![model versionsAttributeOf:entity]) continue;
    NSString *set = [service.mapper entitySetForEntity:entity];
    ODataEntitySetHandler *existing = [service handlerForEntitySet:set];
    if ([existing isKindOfClass:[ODataSyncSetHandler class]]) {
      ((ODataSyncSetHandler *)existing).engine = _engine;
      continue;
    }
    if (existing && [existing class] != [ODataEntitySetHandler class]) {
      [unchecked addObject:set];
      continue;
    }
    ODataSyncSetHandler *handler = [[ODataSyncSetHandler alloc] initWithEntity:entity];
    handler.engine = _engine;
    [service setHandler:handler forEntitySet:set];
  }
  _uncheckedEntitySets = unchecked;
  // Merged attributes are exchanged through MergeAttributes (14).
  BOOL merges = NO;
  for (NSEntityDescription *entity in service.model.entities) {
    if ([model mergedAttributesOf:entity].count) merges = YES;
  }
  if (merges) [self installOperations];
  return self;
}

// ODataSync's operations, unless the app has its own (which then adopts
// ODataSyncPeerTokenActions and ODataSyncMergeActions, and forwards).
- (BOOL)installOperations
{
  id existing = _service.serviceOperations;
  if ([existing isKindOfClass:[ODSServiceOperations class]]) return YES;
  if (existing) return NO;
  ODSServiceOperations *operations = [[ODSServiceOperations alloc] init];
  operations.sync = self;
  operations.engine = _engine;
  _service.serviceOperations = operations;
  return YES;
}

- (NSTimeInterval)mergeRetention
{
  return _mergeRetention > 0 ? _mergeRetention : self.tombstoneRetention;
}

- (NSDictionary *)mergeAttributesWithReplica:(NSString *)replica items:(NSArray *)items reply:(ODataReply *)reply
{
  return ODSAnswerMergeAttributes(_engine, replica, items, reply, YES, self.mergeRetention);
}

- (NSTimeInterval)tombstoneRetention
{
  return _engine.tombstoneRetention;
}

- (void)setTombstoneRetention:(NSTimeInterval)retention
{
  _engine.tombstoneRetention = retention;
}

- (void)setPeerTokens:(ODataSyncPeerTokenIssuer *)peerTokens
{
  _peerTokens = peerTokens;
  if (peerTokens && [self installOperations]) {
    // ODataSync's own operations answer it.
  } else if (peerTokens && ![_service.serviceOperations conformsToProtocol:@protocol(ODataSyncPeerTokenActions)]) {
    // The app's own operations, without PeerToken: no device can ask.
    NSLog(@"ODataSyncService: the service's operations do not adopt ODataSyncPeerTokenActions: no PeerToken action, no peer tokens");
  }
}

- (NSDictionary *)peerTokenWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint reply:(ODataReply *)reply
{
  if (!_peerTokens) {
    [reply failWithError:ODataServiceError(501, @"This service issues no peer tokens")];
    return nil;
  }
  NSError *error = nil;
  NSDictionary *answer = [_peerTokens answerForPrincipal:reply.request.principal replica:replica thumbprint:thumbprint error:&error];
  if (!answer) [reply failWithError:error];
  return answer;
}

@end
