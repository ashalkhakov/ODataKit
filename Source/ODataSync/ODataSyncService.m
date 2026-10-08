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

// What every replica heard from within retention has seen of an object's
// merged attribute, this replica's version recorded first (record: the
// service keeps them; a peer server does not, and so collects nothing).
static NSData *ODSSeenByAll(NSManagedObjectContext *context, NSString *entityType, NSString *keyText, NSString *property,
                            NSString *replica, NSData *version, id<ODataSyncMerging> merger, NSTimeInterval retention)
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSMergeSeenEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"entityType == %@ AND keyText == %@ AND property == %@", entityType, keyText, property];
  NSArray *rows = [context executeFetchRequest:fetch error:NULL] ?: @[];
  NSDate *now = [NSDate date], *since = retention > 0 ? [now dateByAddingTimeInterval:-retention] : nil;
  NSManagedObject *mine = nil;
  for (NSManagedObject *row in rows) {
    if ([[row valueForKey:@"replica"] isEqual:replica]) mine = row;
  }
  if (replica.length) {
    if (!mine) {
      mine = [NSEntityDescription insertNewObjectForEntityForName:ODSMergeSeenEntity inManagedObjectContext:context];
      [mine setValue:entityType forKey:@"entityType"];
      [mine setValue:keyText forKey:@"keyText"];
      [mine setValue:property forKey:@"property"];
      [mine setValue:replica forKey:@"replica"];
      rows = [rows arrayByAddingObject:mine];
    }
    [mine setValue:version forKey:@"version"];
    [mine setValue:now forKey:@"seen"];
  }
  NSData *meet = nil;
  for (NSManagedObject *row in rows) {
    NSDate *seen = [row valueForKey:@"seen"];
    if (since && [seen compare:since] == NSOrderedAscending) {
      // Not heard from within retention: no longer waited for.
      [context deleteObject:row];
      continue;
    }
    NSData *theirs = [row valueForKey:@"version"];
    if (!theirs) continue;
    meet = meet ? [merger versionMeeting:meet andVersion:theirs] : theirs;
  }
  return meet;
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
  ODSCodec *codec = engine.codec;
  NSMutableArray *answers = [NSMutableArray array];
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
    NSData *delta = ODSDataOfBase64(item[@"Delta"]);
    if (delta.length) {
      // Through the handler: merged, written as any update is.
      if (![handler updateObject:object values:@{ attribute.name: delta } request:request reply:reply]) return nil;
    }
    NSData *state = [object valueForKey:attribute.name];
    NSData *version = [merger versionOfState:state];
    // What the device lacks, before anything is collected: what is collected
    // now it has not seen yet, and is told (then collects it itself).
    NSData *theirs = ODSDataOfBase64(item[@"Version"]);
    NSData *lacks = [merger deltaOfState:state sinceVersion:theirs.length ? theirs : nil];
    NSString *keyText = [codec keyTextOf:key entity:[engine.model rootOf:entity]];
    NSData *seen = record ? ODSSeenByAll(context, [engine.model rootOf:entity].name, keyText, attribute.name,
                                         [replica isKindOfClass:[NSString class]] ? replica : nil, version, merger, retention)
                          : nil;
    if (seen.length) {
      NSData *collected = [merger stateByCollecting:state seenBy:seen];
      if (collected && ![collected isEqual:state]) {
        [object setValue:collected forKey:attribute.name];
        state = collected;
      }
    }
    NSMutableDictionary *answer = [NSMutableDictionary dictionary];
    answer[@"Delta"] = ODSBase64Of(lacks);
    answer[@"Version"] = ODSBase64Of([merger versionOfState:state]);
    if (seen.length) answer[@"SeenByAll"] = ODSBase64Of(seen);
    [answers addObject:answer];
  }
  return @{ @"Items": answers };
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
