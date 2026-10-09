// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Down (docs/offline-sync.md, 4): each down and both set read whole the
// first time, with change tracking, and by its delta link after; applied
// by key, in a context writing as the remote's down author, and saved with
// the new delta link. A peer is no authority (docs/offline-sync.md, 7): its
// removals and the rows it lacks delete nothing here, and its rows of a
// down entity only add what is missing, or replace an older version (by
// the service's version counter, where the entity has one).

#import "ODSInternal.h"
#import <ODataKit/ODataError.h>
#import <ODataKit/ODataTransport.h>

// A delta link the remote no longer follows.
static const NSInteger ODSGone = 410;

@implementation ODSDownloader {
  ODataSyncEngine *_engine;
  ODataSyncRemote *_remote;
  ODSModel *_model;
  ODSCodec *_codec;
  ODSRequests *_requests;
  ODataClient *_client;
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
  return self;
}

- (NSString *)author
{
  return [ODataSyncDownAuthorPrefix stringByAppendingString:_remote.identifier];
}

- (NSArray<NSEntityDescription *> *)entities
{
  return [_model rootEntitiesGoing:[NSSet setWithObjects:@(ODataSyncDirectionDown), @(ODataSyncDirectionBoth), nil] toward:_remote];
}

#pragma mark Requests

// A GET's JSON; *status the HTTP status of a failure (0: none came).
- (NSDictionary *)JSONAt:(NSURL *)url prefer:(NSString *)prefer status:(NSInteger *)status error:(NSError **)error
{
  NSMutableURLRequest *request = [_requests GET:url prefer:prefer];
  NSError *failure = nil;
  ODataHTTPResponse *response = [_client sendRequest:request error:&failure];
  if (status) *status = 0;
  if (!response) {
    if (status && failure.code > ODataIncrementalStoreErrorHTTP && failure.code < ODataIncrementalStoreErrorHTTP + 600) {
      *status = failure.code - ODataIncrementalStoreErrorHTTP;
    }
    if (error) *error = failure;
    return nil;
  }
  id json = [response JSONWithError:error];
  if (![json isKindOfClass:[NSDictionary class]]) {
    if (error && json) *error = ODSError(1, [NSString stringWithFormat:@"%@ did not answer with a JSON object", url]);
    return nil;
  }
  return json;
}

// The rows of a read, page after page; the delta link the last page gave.
- (NSArray<NSDictionary *> *)rowsAt:(NSURL *)url prefer:(NSString *)prefer deltaLink:(NSString **)deltaLink
                             status:(NSInteger *)status error:(NSError **)error
{
  NSMutableArray *rows = [NSMutableArray array];
  NSURL *next = url;
  if (deltaLink) *deltaLink = nil;
  while (next) {
    NSDictionary *page = [self JSONAt:next prefer:prefer status:status error:error];
    if (!page) return nil;
    id value = page[@"value"];
    if ([value isKindOfClass:[NSArray class]]) [rows addObjectsFromArray:value];
    NSString *nextLink = [page[@"@odata.nextLink"] isKindOfClass:[NSString class]] ? page[@"@odata.nextLink"] : nil;
    next = nextLink ? [_requests URLOfLink:nextLink relativeTo:next] : nil;
    NSString *delta = [page[@"@odata.deltaLink"] isKindOfClass:[NSString class]] ? page[@"@odata.deltaLink"] : nil;
    if (delta && deltaLink) *deltaLink = [_requests URLOfLink:delta relativeTo:url].absoluteString;
  }
  return rows;
}

#pragma mark Applying

// The local object a row names, made when there is none (of the type the
// row says).
- (NSManagedObject *)objectFor:(NSDictionary *)row entity:(NSEntityDescription *)entity context:(NSManagedObjectContext *)context
                       created:(BOOL *)created
{
  NSDictionary *key = [_codec keyFromJSON:row entity:entity];
  if (!key) return nil;
  NSManagedObject *object = [_codec objectOfEntity:entity key:key inContext:context];
  if (created) *created = object == nil;
  if (!object) {
    NSString *type = [row[@"@odata.type"] isKindOfClass:[NSString class]] ? row[@"@odata.type"] : nil;
    NSEntityDescription *concrete = type ? [_codec.mapper entity:entity forTypeName:type] : entity;
    object = [[NSManagedObject alloc] initWithEntity:concrete ?: entity insertIntoManagedObjectContext:context];
    for (NSString *name in key) [object setValue:key[name] forKey:name];
  }
  return object;
}

// A both object's row (nil: removed) when the device changed it too: a
// conflict, settled; YES when it was (and so is not applied here).
- (BOOL)settled:(NSDictionary *)row entity:(NSEntityDescription *)entity key:(NSDictionary *)key etag:(NSString *)etag
        context:(NSManagedObjectContext *)context
{
  if ([_model directionOfEntity:entity toward:_remote] != ODataSyncDirectionBoth) return NO;
  NSString *keyText = [_codec keyTextOf:key entity:entity];
  NSManagedObject *entry = [_engine.store entryOf:entity.name keyText:keyText remote:_remote inContext:context];
  if (entry && [[entry valueForKey:@"operation"] integerValue] == ODataSyncOperationRefresh) {
    // A conflict given up: this is the version it waited for.
    [context deleteObject:entry];
    entry = nil;
  }
  NSManagedObject *object = [_codec objectOfEntity:entity key:key inContext:context];
  NSDictionary *theirs = [_codec versionsOfRow:row entity:entity];
  // Deleted here: the row is an older copy (the deletion is to go), the
  // object made again by one that knew of it, or a change made without
  // knowing (a conflict), as the histories say.
  if (!object && row && [_engine.store isDeleted:entity.name keyText:keyText inContext:context]) {
    NSDictionary *deleted = [_engine.store deletedVersionsOf:entity.name keyText:keyText inContext:context];
    if (deleted.count && theirs.count) {
      ODSOrder order = ODSCompareVersions(theirs, deleted);
      if (order == ODSOrderAfter) {
        [_engine.store forgetDeletionOf:entity.name keyText:keyText inContext:context];
        [_engine agreeOn:row etag:etag of:entity keyText:keyText remote:_remote context:context];
        if (entry) [context deleteObject:entry];
        return NO;
      }
      if (!entry) entry = [_engine.store newEntryOf:entity key:key operation:ODataSyncOperationDelete remote:_remote context:context];
      if (order == ODSOrderConcurrent) {
        [_engine settleConflictOf:entity key:key entry:entry remoteRow:row etag:etag remote:_remote context:context];
      } else {
        [_engine agreeOn:row etag:etag of:entity keyText:keyText remote:_remote context:context];
      }
      return YES;
    }
    // No history to tell by: a peer brings nothing back.
    if (_remote.peer) return YES;
  }
  if (!entry) {
    NSDictionary *mine = [_codec versionsOfObject:object];
    if (row && object && theirs.count && mine.count) {
      switch (ODSCompareVersions(theirs, mine)) {
        case ODSOrderSame:
          [_engine agreeOn:row etag:etag of:entity keyText:keyText remote:_remote context:context];
          return YES;
        case ODSOrderAfter:
          [_engine agreeOn:row etag:etag of:entity keyText:keyText remote:_remote context:context];
          return NO;
        case ODSOrderBefore:
          // Older than this side's: this side's goes to it.
          return [_engine keepNewerThan:row etag:etag of:entity key:key remote:_remote context:context versions:YES];
        case ODSOrderConcurrent:
          // Changed here by way of another remote, and there: a conflict.
          entry = [_engine.store newEntryOf:entity key:key operation:ODataSyncOperationUpdate remote:_remote context:context];
          [_engine settleConflictOf:entity key:key entry:entry remoteRow:row etag:etag remote:_remote context:context];
          return YES;
      }
    }
    if (row && [_engine keepNewerThan:row etag:etag of:entity key:key remote:_remote context:context]) return YES;
    [_engine agreeOn:row etag:etag of:entity keyText:keyText remote:_remote context:context];
    return NO;
  }
  [_engine settleConflictOf:entity key:key entry:entry remoteRow:row etag:etag remote:_remote context:context];
  return YES;
}

// Rows applied: objects made first, then each row's values, so a to-one
// to a row of the same read finds it.
- (void)applyRows:(NSArray<NSDictionary *> *)rows entity:(NSEntityDescription *)entity context:(NSManagedObjectContext *)context
             seen:(NSMutableSet<NSString *> *)seen
{
  NSMutableArray *pairs = [NSMutableArray array];
  BOOL onlyMissing = _remote.peer && [_model directionOfEntity:entity] == ODataSyncDirectionDown;
  // Merged attributes come after, as deltas: each row that came, exchanged.
  BOOL merges = !onlyMissing && [_model mergesEntity:entity];
  NSAttributeDescription *version = onlyMissing ? [_model versionAttributeOf:entity] : nil;
  NSString *versionProperty = version ? [_codec.mapper propertyForAttribute:version] : nil;
  for (NSDictionary *row in rows) {
    if (![row isKindOfClass:[NSDictionary class]]) continue;
    NSDictionary *key = [_codec keyFromJSON:row entity:entity];
    if (!key) continue;
    [seen addObject:[_codec keyTextOf:key entity:entity]];
    if (merges) [_engine.store noteMergeOf:entity key:key remote:_remote context:context];
    NSString *etag = [row[@"@odata.etag"] isKindOfClass:[NSString class]] ? row[@"@odata.etag"] : nil;
    NSAttributeDescription *stamp = [_model modifiedAttributeOf:entity];
    if (stamp) [_engine.clock witness:row[[_codec.mapper propertyForAttribute:stamp]]];
    if ([self settled:row entity:entity key:key etag:etag context:context]) continue;
    // Deleted here: a peer that has not heard yet does not bring it back.
    if (_remote.peer && ![_codec objectOfEntity:entity key:key inContext:context] &&
        [_engine.store isDeleted:entity.name keyText:[_codec keyTextOf:key entity:entity] inContext:context]) continue;
    BOOL created = NO;
    NSManagedObject *object = [self objectFor:row entity:entity context:context created:&created];
    if (onlyMissing && !created) {
      // No version counter: nothing tells the peer's copy newer; only what
      // is missing here is taken.
      if (!version) continue;
      // The service's version, newer than this one: as good as from the service.
      id theirs = versionProperty ? row[versionProperty] : nil;
      id ours = [object valueForKey:version.name];
      if (![theirs respondsToSelector:@selector(longLongValue)] || (ours && [theirs longLongValue] <= [ours longLongValue])) continue;
    }
    if (object) [pairs addObject:@[ object, row ]];
  }
  NSUInteger changed = 0;
  for (NSArray *pair in pairs) {
    NSManagedObject *object = pair[0];
    [_codec applyJSON:pair[1] toObject:object];
    // A row as it is here already (a delta's echo, a peer's copy) is no download.
    if (object.isInserted || object.changedValues.count) changed++;
  }
  [_engine count:@"downloaded" by:changed];
}

- (void)removeObjectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key context:(NSManagedObjectContext *)context
{
  if (_remote.peer) return;
  if ([self settled:nil entity:entity key:key etag:nil context:context]) return;
  NSManagedObject *object = [_codec objectOfEntity:entity key:key inContext:context];
  if (!object) return;
  [context deleteObject:object];
  [_engine count:@"removed" by:1];
}

// Local objects of the set the remote did not name, deleted (but not one
// made here and not sent yet). Not a peer's.
- (void)sweep:(NSEntityDescription *)entity keeping:(NSSet<NSString *> *)seen context:(NSManagedObjectContext *)context
{
  if (_remote.peer) return;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity.name];
  fetch.includesSubentities = YES;
  for (NSManagedObject *object in [context executeFetchRequest:fetch error:NULL]) {
    NSDictionary *key = [_codec keyOfObject:object];
    NSString *keyText = [_codec keyTextOf:key entity:entity];
    if ([seen containsObject:keyText]) continue;
    NSManagedObject *entry = [_engine.store entryOf:entity.name keyText:keyText remote:_remote inContext:context];
    if (entry && [[entry valueForKey:@"operation"] integerValue] == ODataSyncOperationInsert) continue;
    if (entry) [context deleteObject:entry];
    [context deleteObject:object];
    [_engine count:@"removed" by:1];
  }
}

#pragma mark Reading

// Whole: every row, by key; what the remote no longer has, gone.
- (BOOL)readWhole:(NSEntityDescription *)entity context:(NSManagedObjectContext *)context deltaLink:(NSString **)deltaLink
            error:(NSError **)error
{
  NSURL *url = [_requests URLOfSet:entity keysOnly:NO error:error];
  if (!url) return NO;
  NSArray *rows = [self rowsAt:url prefer:@"odata.track-changes" deltaLink:deltaLink status:NULL error:error];
  if (!rows) return NO;
  NSMutableSet *seen = [NSMutableSet set];
  [self applyRows:rows entity:entity context:context seen:seen];
  [self sweep:entity keeping:seen context:context];
  return YES;
}

// By the delta link: rows changed, rows removed. NO with *gone when the
// remote no longer follows it (410).
- (BOOL)follow:(NSString *)link entity:(NSEntityDescription *)entity context:(NSManagedObjectContext *)context
     deltaLink:(NSString **)deltaLink gone:(BOOL *)gone error:(NSError **)error
{
  NSInteger status = 0;
  NSError *failure = nil;
  NSArray *entries = [self rowsAt:[_requests URLOfLink:link relativeTo:nil] prefer:nil deltaLink:deltaLink status:&status error:&failure];
  if (!entries) {
    *gone = status == ODSGone;
    if (!*gone && error) *error = failure;
    return NO;
  }
  NSMutableArray *rows = [NSMutableArray array];
  for (NSDictionary *entry in entries) {
    if (![entry isKindOfClass:[NSDictionary class]]) continue;
    BOOL removed = entry[@"@odata.removed"] != nil || [entry[@"@odata.context"] hasSuffix:@"$deletedEntity"];
    if (!removed) {
      [rows addObject:entry];
      continue;
    }
    NSString *identifier = entry[@"@odata.id"] ?: entry[@"id"];
    NSDictionary *key = [identifier isKindOfClass:[NSString class]] ? [_codec keyFromID:identifier entity:NULL among:@[ entity ]] : nil;
    if (key) [self removeObjectOfEntity:entity key:key context:context];
  }
  [self applyRows:rows entity:entity context:context seen:[NSMutableSet set]];
  return YES;
}

- (BOOL)downloadEntity:(NSEntityDescription *)entity context:(NSManagedObjectContext *)context error:(NSError **)error
{
  OTSpan *span = [_engine.tracer startSpanNamed:[@"download " stringByAppendingString:entity.name] attributes:nil];
  NSManagedObject *state = [_engine.store stateOf:_remote inContext:context];
  NSMutableDictionary *links = [ODSUnarchive([state valueForKey:@"deltaLinks"]) mutableCopy] ?: [NSMutableDictionary dictionary];
  NSMutableDictionary *filters = [ODSUnarchive([state valueForKey:@"filters"]) mutableCopy] ?: [NSMutableDictionary dictionary];
  NSString *filter = _remote.filters[entity.name];
  NSString *link = links[entity.name];
  // A filter that changed is another set: read again.
  if (link && !(filters[entity.name] == filter || [filters[entity.name] isEqual:filter])) link = nil;
  NSString *next = nil;
  BOOL ok = NO;
  if (link) {
    BOOL gone = NO;
    ok = [self follow:link entity:entity context:context deltaLink:&next gone:&gone error:error];
    if (!ok && !gone) {
      [span end];
      return NO;
    }
    [span setAttribute:@(gone) forKey:@"odatasync.delta_gone"];
  }
  if (!ok && ![self readWhole:entity context:context deltaLink:&next error:error]) {
    [span end];
    return NO;
  }
  if (next) links[entity.name] = next; else [links removeObjectForKey:entity.name];
  if (filter) filters[entity.name] = filter; else [filters removeObjectForKey:entity.name];
  [state setValue:ODSArchive(links) forKey:@"deltaLinks"];
  [state setValue:ODSArchive(filters) forKey:@"filters"];
  // The rows and the link that follows them, together.
  ok = [context save:error];
  [span end];
  return ok;
}

- (BOOL)download:(NSError **)error
{
  [_engine beginPhase:ODataSyncPhaseReceiving remote:_remote total:0];
  NSManagedObjectContext *context = [_engine.store contextWritingAs:[self author]];
  __block BOOL ok = YES;
  __block NSError *failure = nil;
  [context performBlockAndWait:^{
    for (NSEntityDescription *entity in [self entities]) {
      NSError *e = nil;
      if (![self downloadEntity:entity context:context error:&e]) {
        failure = e;
        ok = NO;
        [context rollback];
        return;
      }
    }
  }];
  if (!ok && error) *error = failure;
  return ok;
}

#pragma mark Reconciling

- (BOOL)reconcileEntity:(NSEntityDescription *)entity context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSURL *url = [_requests URLOfSet:entity keysOnly:YES error:error];
  NSArray *rows = url ? [self rowsAt:url prefer:nil deltaLink:NULL status:NULL error:error] : nil;
  if (!rows) return NO;
  NSMutableDictionary<NSString *, NSDictionary *> *remote = [NSMutableDictionary dictionary];
  for (NSDictionary *row in rows) {
    NSDictionary *key = [row isKindOfClass:[NSDictionary class]] ? [_codec keyFromJSON:row entity:entity] : nil;
    if (key) remote[[_codec keyTextOf:key entity:entity]] = key;
  }
  [self sweep:entity keeping:[NSSet setWithArray:remote.allKeys] context:context];
  // What it has that is not here: read, a few keys at a time.
  NSMutableArray *missing = [NSMutableArray array];
  for (NSString *keyText in remote) {
    if (![_codec objectOfEntity:entity key:remote[keyText] inContext:context]) [missing addObject:remote[keyText]];
  }
  for (NSUInteger at = 0; at < missing.count; at += 40) {
    NSArray *keys = [missing subarrayWithRange:NSMakeRange(at, MIN(40u, missing.count - at))];
    NSURL *url = [_requests URLOfSet:entity keys:keys error:error];
    NSArray *found = url ? [self rowsAt:url prefer:nil deltaLink:NULL status:NULL error:error] : nil;
    if (!found) return NO;
    [self applyRows:found entity:entity context:context seen:[NSMutableSet set]];
  }
  return [context save:error];
}

- (BOOL)reconcile:(NSError **)error
{
  [_engine beginPhase:ODataSyncPhaseReceiving remote:_remote total:0];
  NSManagedObjectContext *context = [_engine.store contextWritingAs:[self author]];
  __block BOOL ok = YES;
  __block NSError *failure = nil;
  [context performBlockAndWait:^{
    for (NSEntityDescription *entity in [self entities]) {
      NSError *e = nil;
      if (![self reconcileEntity:entity context:context error:&e]) {
        failure = e;
        ok = NO;
        [context rollback];
        return;
      }
    }
  }];
  if (!ok && error) *error = failure;
  return ok;
}

#pragma mark One object

- (NSDictionary *)rowOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key status:(NSInteger *)status error:(NSError **)error
{
  NSURL *url = [_requests URLOfObject:entity key:key error:error];
  return url ? [self JSONAt:url prefer:nil status:status error:error] : nil;
}

- (BOOL)refreshObjectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key context:(NSManagedObjectContext *)context
                        error:(NSError **)error
{
  NSEntityDescription *root = [_model rootOf:entity];
  NSInteger status = 0;
  NSError *failure = nil;
  NSDictionary *row = [self rowOfEntity:root key:key status:&status error:&failure];
  NSManagedObject *object = [_codec objectOfEntity:root key:key inContext:context];
  NSString *keyText = [_codec keyTextOf:key entity:root];
  if (!row) {
    if (status != 404) {
      if (error) *error = failure;
      return NO;
    }
    if (object && !_remote.peer) {
      [context deleteObject:object];
      [_engine count:@"removed" by:1];
    }
    [_engine agreeOn:nil etag:nil of:root keyText:keyText remote:_remote context:context];
    return YES;
  }
  if (!object) object = [self objectFor:row entity:root context:context created:NULL];
  [_codec applyJSON:row toObject:object];
  [_engine count:@"downloaded" by:1];
  NSString *etag = [row[@"@odata.etag"] isKindOfClass:[NSString class]] ? row[@"@odata.etag"] : nil;
  [_engine agreeOn:row etag:etag of:root keyText:keyText remote:_remote context:context];
  return YES;
}

@end
