// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The service's part of the causal history (docs/offline-sync.md, 12),
// and what a peer server shares with it: deletions kept, and an insert of
// a deleted key judged by the histories.

#import "ODataSyncService.h"
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

- (NSManagedObject *)insertObjectWithValues:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
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
  [self writeAs:request values:values];
  return [super updateObject:object values:values request:request reply:reply];
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

// The service's operations when it has none of its own: PeerToken.
@interface ODSPeerTokenOperations : NSObject <ODataSyncPeerTokenActions>
@property (nonatomic, weak) ODataSyncService *sync;
@end

@implementation ODSPeerTokenOperations
- (NSDictionary *)peerTokenWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint reply:(ODataReply *)reply
{
  return [self.sync peerTokenWithReplica:replica thumbprint:thumbprint reply:reply];
}
@end

@implementation ODataSyncService

+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(NSString *)configuration
{
  if (model.entitiesByName[ODSTombstoneEntity]) return;
  NSEntityDescription *tombstone = ODSTombstoneEntityDescription();
  model.entities = [model.entities arrayByAddingObject:tombstone];
  if (configuration) {
    NSArray *entities = [model entitiesForConfiguration:configuration] ?: @[];
    [model setEntities:[entities arrayByAddingObject:tombstone] forConfiguration:configuration];
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
  return self;
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
  if (peerTokens && !_service.serviceOperations) {
    ODSPeerTokenOperations *operations = [[ODSPeerTokenOperations alloc] init];
    operations.sync = self;
    _service.serviceOperations = operations;
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
