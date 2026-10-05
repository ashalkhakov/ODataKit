// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The engine: its remotes, in turn, each read from and sent to; the
// resolvers; what a sync did; the app's view of the outbox. The work is
// its parts' (ODSInternal.h): what the model says (ODSModel), OData's
// values (ODSCodec) and requests (ODSRequests), what is kept in the store
// (ODSStore), the clocks (ODSClock), every save watched (ODSRecorder),
// down (ODSDownloader), up (ODSUploader), conflicts (ODSConflicts).

#import "ODSInternal.h"
#import <objc/message.h>

NSString * const ODataSyncErrorDomain = @"org.gnu.ois.ODataSync";
NSString * const ODataSyncDownAuthorPrefix = @"ODataSync.down.";
NSString * const ODataSyncBookkeepingAuthor = @"ODataSync.bookkeeping";
NSString * const ODataSyncReplicaHeader = @"ODataSync-Replica";

NSError *ODSError(NSInteger code, NSString *message)
{
  return [NSError errorWithDomain:ODataSyncErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}

NSData *ODSArchive(id plist)
{
  if (!plist) return nil;
  return [NSKeyedArchiver archivedDataWithRootObject:plist requiringSecureCoding:NO error:NULL];
}

id ODSUnarchive(NSData *data)
{
  if (!data.length) return nil;
  NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class], [NSDate class],
                                         [NSUUID class], [NSDecimalNumber class], [NSData class], [NSNull class], [NSSet class], nil];
  return [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:NULL];
}

@implementation ODataSyncEngine {
  NSMutableArray<ODataSyncRemote *> *_remotes;
  NSLock *_running;
  NSMutableDictionary<NSString *, NSNumber *> *_tally;
  NSMutableDictionary<NSString *, id<ODataSyncResolving>> *_resolvers;
  ODSRecorder *_recorder;
}

+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(NSString *)configuration
{
  [ODSStore addBookkeepingToModel:model configuration:configuration];
}

- (instancetype)initWithCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
  return [self initWithCoordinator:coordinator service:NO];
}

- (instancetype)initServiceWithCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
  return [self initWithCoordinator:coordinator service:YES];
}

- (instancetype)initWithCoordinator:(NSPersistentStoreCoordinator *)coordinator service:(BOOL)service
{
  self = [super init];
  if (!self) return nil;
  _coordinator = coordinator;
  _service = service;
  _model = [[ODSModel alloc] initWithModel:coordinator.managedObjectModel];
  _codec = [[ODSCodec alloc] initWithModel:_model];
  _store = [[ODSStore alloc] initWithCoordinator:coordinator codec:_codec];
  _clock = [[ODSClock alloc] initWithStore:_store service:service];
  _remotes = [NSMutableArray array];
  _running = [[NSLock alloc] init];
  _tally = [NSMutableDictionary dictionary];
  _tracer = [OTTracer tracerNamed:@"ODataSync" version:nil];
  _resolvers = [NSMutableDictionary dictionary];
  _tombstoneRetention = 30 * 24 * 3600;
  // Its version identifiers (Xcode's Core Data Model Identifier), the
  // empty one left out: none, no version.
  NSArray *identifiers = [[[coordinator.managedObjectModel.versionIdentifiers.allObjects valueForKey:@"description"]
                             filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
                             sortedArrayUsingSelector:@selector(compare:)];
  _modelVersion = identifiers.count ? [identifiers componentsJoinedByString:@","] : nil;
  // Every save watched: the app's changes stamped and counted, deletions kept.
  _recorder = [[ODSRecorder alloc] initWithEngine:self];
  return self;
}

#pragma mark Remotes, resolvers

- (NSArray<ODataSyncRemote *> *)remotes
{
  @synchronized (self) {
    return [_remotes copy];
  }
}

- (void)addRemote:(ODataSyncRemote *)remote
{
  @synchronized (self) {
    [_remotes addObject:remote];
  }
}

- (void)removeRemote:(ODataSyncRemote *)remote
{
  @synchronized (self) {
    [_remotes removeObject:remote];
  }
}

- (ODataSyncRemote *)remoteWithIdentifier:(NSString *)identifier
{
  for (ODataSyncRemote *remote in self.remotes) {
    if ([remote.identifier isEqualToString:identifier]) return remote;
  }
  return nil;
}

- (ODataClient *)clientOf:(ODataSyncRemote *)remote
{
  ODataConfiguration *configuration = remote.configuration;
  configuration.version = @"4.01";
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  client.transport = remote.transport;
  return client;
}

- (id<ODataSyncResolving>)resolverForEntityName:(NSString *)entityName
{
  @synchronized (_resolvers) {
    return _resolvers[entityName];
  }
}

- (void)setResolver:(id<ODataSyncResolving>)resolver forEntityName:(NSString *)entityName
{
  @synchronized (_resolvers) {
    _resolvers[entityName] = resolver;
  }
}

- (NSString *)replicaID
{
  return [_store replicaID];
}

#pragma mark What a sync did

- (NSMutableDictionary<NSString *, NSNumber *> *)tally
{
  return _tally;
}

- (void)count:(NSString *)what by:(NSUInteger)n
{
  @synchronized (_tally) {
    _tally[what] = @([_tally[what] unsignedIntegerValue] + n);
  }
}

- (void)setAside:(ODataSyncIssue *)issue
{
  [self count:@"refused" by:1];
  id<ODataSyncDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(syncEngine:didSetAside:)]) [delegate syncEngine:self didSetAside:issue];
}

- (void)ignoredLocalChangeTo:(NSManagedObjectID *)objectID
{
  id<ODataSyncDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(syncEngine:ignoredLocalChangeToObject:)]) [delegate syncEngine:self ignoredLocalChangeToObject:objectID];
}

#pragma mark Syncing

- (void)pruneTombstones
{
  if (self.tombstoneRetention > 0) [_store forgetDeletionsBefore:[NSDate dateWithTimeIntervalSinceNow:-self.tombstoneRetention]];
}

- (void)noticeModelVersion
{
  [_store noticeModelVersion:self.modelVersion];
}

- (BOOL)syncWithError:(NSError **)error
{
  [_running lock];
  // Unlocked whatever happens: an exception out of a sync leaves the
  // engine able to sync again.
  @try {
    return [self syncLocked:error];
  } @finally {
    [_running unlock];
  }
}

- (BOOL)syncWithRemote:(ODataSyncRemote *)remote error:(NSError **)error
{
  [_running lock];
  @try {
    // A remote while it syncs (its state kept under its identifier), alone.
    BOOL added = ![self.remotes containsObject:remote];
    if (added) [self addRemote:remote];
    @synchronized (_tally) {
      [_tally removeAllObjects];
    }
    [self noticeModelVersion];
    BOOL ok = [self downloadFromRemote:remote error:error] && [self uploadToRemote:remote error:error];
    @synchronized (_tally) {
      _lastResult = [[ODataSyncResult alloc] initWithTally:_tally];
    }
    if (added) [self removeRemote:remote];
    return ok;
  } @finally {
    [_running unlock];
  }
}

- (BOOL)syncLocked:(NSError **)error
{
  @synchronized (_tally) {
    [_tally removeAllObjects];
  }
  OTSpan *span = [self.tracer startSpanNamed:@"sync" attributes:nil];
  [self pruneTombstones];
  [self noticeModelVersion];
  BOOL ok = YES;
  for (ODataSyncRemote *remote in self.remotes) {
    if (![self downloadFromRemote:remote error:error] || ![self uploadToRemote:remote error:error]) {
      ok = NO;
      break;
    }
  }
  @synchronized (_tally) {
    _lastResult = [[ODataSyncResult alloc] initWithTally:_tally];
  }
  if (!ok && error) [span recordError:*error];
  [span end];
  return ok;
}

- (void)syncWithTarget:(id)target action:(SEL)action
{
  [NSThread detachNewThreadSelector:@selector(runSyncFor:) toTarget:self withObject:@[ target, NSStringFromSelector(action) ]];
}

- (void)runSyncFor:(NSArray *)reply
{
  @autoreleasepool {
    NSError *error = nil;
    BOOL ok = [self syncWithError:&error];
    ODataSyncResult *result = ok ? self.lastResult : nil;
    id target = reply[0];
    SEL action = NSSelectorFromString(reply[1]);
    dispatch_async(dispatch_get_main_queue(), ^{
      void (*send)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
      send(target, action, result, ok ? nil : error);
    });
  }
}

- (BOOL)downloadFromRemote:(ODataSyncRemote *)remote error:(NSError **)error
{
  // The names requests are written of, checked before any is sent; then
  // what the device changed and has not sent, known first.
  return [self.model checkNames:error] && [[[ODSUploader alloc] initWithEngine:self remote:remote] collect:error] &&
         [[[ODSDownloader alloc] initWithEngine:self remote:remote] download:error];
}

- (BOOL)uploadToRemote:(ODataSyncRemote *)remote error:(NSError **)error
{
  [self noticeModelVersion];
  return [self.model checkNames:error] && [[[ODSUploader alloc] initWithEngine:self remote:remote] upload:error];
}

- (BOOL)reconcileWithRemote:(ODataSyncRemote *)remote error:(NSError **)error
{
  return [self.model checkNames:error] && [[[ODSUploader alloc] initWithEngine:self remote:remote] collect:error] &&
         [[[ODSDownloader alloc] initWithEngine:self remote:remote] reconcile:error];
}

- (NSDictionary *)peerTokenFromRemote:(ODataSyncRemote *)remote thumbprint:(NSString *)thumbprint error:(NSError **)error
{
  NSURL *url = [NSURL URLWithString:@"PeerToken" relativeToURL:remote.serviceRoot].absoluteURL;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"Replica": self.replicaID, @"Thumbprint": thumbprint } options:0 error:NULL];
  ODataHTTPResponse *response = [[self clientOf:remote] sendRequest:request error:error];
  id json = [response JSONWithError:error];
  // An Edm.Untyped result, as itself or under value.
  NSDictionary *answer = [json isKindOfClass:[NSDictionary class]] && [json[@"value"] isKindOfClass:[NSDictionary class]] ? json[@"value"] : json;
  if (![answer isKindOfClass:[NSDictionary class]] || ![answer[@"Token"] isKindOfClass:[NSString class]]) {
    if (error && response) *error = ODSError(1, @"The remote's PeerToken answer is not one");
    return nil;
  }
  return answer;
}

#pragma mark The outbox

- (NSArray<ODataSyncChange *> *)pendingChanges
{
  // Not while a sync runs (it collects too, and the main thread should not
  // wait for it): what is in the outbox then.
  if ([_running tryLock]) {
    for (ODataSyncRemote *remote in self.remotes) [[[ODSUploader alloc] initWithEngine:self remote:remote] collect:NULL];
    [_running unlock];
  }
  return [_store pendingChanges];
}

- (NSArray<ODataSyncIssue *> *)issues
{
  return [_store issues];
}

- (void)retryIssue:(ODataSyncIssue *)issue
{
  [_store changeIssue:issue discarding:NO];
}

- (void)discardIssue:(ODataSyncIssue *)issue
{
  [_store changeIssue:issue discarding:YES];
}

@end
