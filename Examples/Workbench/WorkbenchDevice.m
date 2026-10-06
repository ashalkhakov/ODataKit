// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchDevice.h"
#import "WorkbenchSupport.h"

// The device's way to the service: a transport, or nothing at all. Each
// exchange the device has, recorded as it went.
@interface WBDeviceLine : NSObject <ODataTransport>
@property (nonatomic, strong) id<ODataTransport> transport;
@property (atomic) BOOL offline;
@property (nonatomic, copy) void (^didFinish)(WorkbenchLogEntry *entry);
@end

@implementation WBDeviceLine
- (WorkbenchLogEntry *)entryOf:(NSURLRequest *)request started:(NSDate *)started
{
  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  entry.method = request.HTTPMethod.uppercaseString ?: @"GET";
  entry.URL = request.URL.absoluteString ?: @"";
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.date = started;
  entry.storeHint = @"";
  return entry;
}

// On the main thread, by its run loop (which a nested run loop runs too).
- (void)report:(WorkbenchLogEntry *)entry
{
  if (![NSThread isMainThread]) {
    [self performSelectorOnMainThread:_cmd withObject:entry waitUntilDone:NO];
    return;
  }
  if (self.didFinish) self.didFinish(entry);
}

- (void)startExchange:(ODataExchange *)exchange
{
  if (self.offline || !self.transport) {
    exchange.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                                     userInfo:@{ NSLocalizedDescriptionKey: @"The device is offline." }];
    WorkbenchLogEntry *entry = [self entryOf:exchange.request started:[NSDate date]];
    entry.failure = exchange.error.localizedDescription;
    [self report:entry];
    [exchange finish];
    return;
  }
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:self action:@selector(innerDidFinish:)];
  inner.context = @[ exchange, [NSDate date] ];
  [self.transport startExchange:inner];
}

- (void)innerDidFinish:(ODataExchange *)inner
{
  ODataExchange *outer = inner.context[0];
  outer.URLResponse = inner.URLResponse;
  outer.data = inner.data;
  outer.error = inner.error;
  NSHTTPURLResponse *http = [inner.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)inner.URLResponse : nil;
  WorkbenchLogEntry *entry = [self entryOf:inner.request started:inner.context[1]];
  entry.status = http.statusCode;
  entry.responseHeaders = http.allHeaderFields;
  entry.responseData = inner.data ?: [NSData data];
  entry.failure = inner.error.localizedDescription;
  entry.duration = -[entry.date timeIntervalSinceNow];
  [self report:entry];
  [outer finish];
}
@end

@interface WBSyncConflict ()
@property (nonatomic, readwrite) ODataSyncConflict *conflict;
@property (nonatomic, readwrite) ODataSyncResolutionKind outcome;
@property (nonatomic, readwrite) NSDate *date;
@end

@implementation WBSyncConflict
@end

// The rule chosen, and each conflict it settled, kept.
@interface WBSyncRecorder : NSObject <ODataSyncResolving>
@property (atomic) WBSyncRule rule;
@property (nonatomic, strong) NSMutableArray<WBSyncConflict *> *conflicts;
@end

@implementation WBSyncRecorder
- (instancetype)init
{
  self = [super init];
  _conflicts = [NSMutableArray array];
  return self;
}

- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  id<ODataSyncResolving> rule = nil;
  switch (self.rule) {
    case WBSyncRuleRemoteWins: rule = [[ODataSyncRemoteWins alloc] init]; break;
    case WBSyncRuleDeviceWins: rule = [[ODataSyncLocalWins alloc] init]; break;
    case WBSyncRuleLastWriterWins: rule = [[ODataSyncLastWriterWins alloc] init]; break;
    case WBSyncRuleMergeFields: rule = [[ODataSyncMergeFields alloc] init]; break;
    case WBSyncRuleSetAside: break;
  }
  ODataSyncResolution *resolution = rule ? [rule resolveConflict:conflict] : [ODataSyncResolution defer];
  WBSyncConflict *met = [[WBSyncConflict alloc] init];
  met.conflict = conflict;
  met.outcome = resolution.kind;
  met.date = [NSDate date];
  @synchronized (_conflicts) {
    [_conflicts insertObject:met atIndex:0];
  }
  return resolution;
}

- (NSArray<WBSyncConflict *> *)recorded
{
  @synchronized (_conflicts) {
    return [_conflicts copy];
  }
}

- (void)forget
{
  @synchronized (_conflicts) {
    [_conflicts removeAllObjects];
  }
}
@end

NSArray<NSString *> *WBSyncRuleTitles(void)
{
  return @[ @"The service's wins", @"The device's wins", @"The last writer wins", @"Merge the fields", @"Set aside, to decide" ];
}

static NSDictionary<NSString *, NSString *> *WBSyncDirections(void)
{
  return @{ @"Category": @"down", @"Supplier": @"down", @"Location": @"down", @"Product": @"both", @"Stock": @"both" };
}

// The version, the stamp and the history: the engine's and the service's.
static NSArray<NSString *> *WBSyncBookkeeping(void)
{
  return @[ @"version", @"lastChanged", @"versions" ];
}

@implementation WorkbenchDevice {
  NSURL *_modelURL;
  NSURL *_storeURL;
  BOOL _temporary;
  WBDeviceLine *_line;
  WBSyncRecorder *_recorder;
}

- (instancetype)initWithModelURL:(NSURL *)modelURL serviceRoot:(NSURL *)serviceRoot
                       transport:(id<ODataTransport>)transport storeURL:(NSURL *)storeURL
{
  self = [super init];
  if (!self) return nil;
  _modelURL = [modelURL copy];
  _serviceRoot = [serviceRoot copy];
  _storeURL = [storeURL copy];
  _temporary = storeURL == nil;
  _line = [[WBDeviceLine alloc] init];
  _line.transport = transport;
  _recorder = [[WBSyncRecorder alloc] init];
  _requests = @[];
  __weak WorkbenchDevice *weak = self;
  _line.didFinish = ^(WorkbenchLogEntry *entry) {
    [weak logged:entry];
  };
  if (![self open]) return nil;
  return self;
}

- (void)dealloc
{
  if (_temporary) [self removeStore];
}

- (void)removeStore
{
  if (!_storeURL) return;
  for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
    [[NSFileManager defaultManager] removeItemAtPath:[_storeURL.path stringByAppendingString:suffix] error:NULL];
  }
}

// The built-in model, which way each entity goes said in its userInfo, and
// the engine's own entities added: a store of its own, an engine over it.
- (BOOL)open
{
  NSManagedObjectModel *model = WorkbenchBuiltInModel(_modelURL);
  if (!model) return NO;
  NSDictionary *directions = WBSyncDirections();
  for (NSString *name in directions) {
    NSEntityDescription *entity = model.entitiesByName[name];
    NSMutableDictionary *info = [entity.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    info[ODataSyncDirectionKey] = directions[name];
    if ([name isEqualToString:@"Product"]) info[ODataSyncModifiedKey] = @"lastChanged";
    entity.userInfo = info;
  }
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  if (_temporary) {
    [self removeStore];
    _storeURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                           [NSString stringWithFormat:@"Workbench-device-%@.sqlite", [NSProcessInfo processInfo].globallyUniqueString]]];
  }
  NSError *error = nil;
  if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:_storeURL
                                       options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error]) {
    NSLog(@"Workbench: the device's store does not open: %@", error);
    return NO;
  }
  _coordinator = coordinator;
  _context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  _context.persistentStoreCoordinator = coordinator;
  _sync = [[ODataSyncEngine alloc] initWithCoordinator:coordinator];
  _sync.resolver = _recorder;
  _sync.delegate = self;
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:_serviceRoot];
  remote.transport = _line;
  [_sync addRemote:remote];
  return YES;
}

- (BOOL)reset
{
  if (_busy) return NO;
  [_recorder forget];
  _context = nil;
  _sync = nil;
  _coordinator = nil;
  [self removeStore];
  return [self open];
}

- (ODataSyncRemote *)remote
{
  return _sync.remotes.firstObject;
}

- (void)say:(NSString *)status
{
  if (self.didChange) self.didChange(status);
}

- (void)logged:(WorkbenchLogEntry *)entry
{
  NSMutableArray *requests = [_requests mutableCopy];
  [requests insertObject:entry atIndex:0];
  if (requests.count > 200) [requests removeLastObject];
  _requests = requests;
  if (self.didLog) self.didLog(entry);
}

#pragma mark Entities

+ (NSArray<NSString *> *)entityNames
{
  return @[ @"Product", @"Stock", @"Category", @"Supplier", @"Location" ];
}

- (NSString *)directionOfEntity:(NSString *)entity
{
  // Typed: FreeCoreData's dictionaries are not.
  NSEntityDescription *description = _coordinator.managedObjectModel.entitiesByName[entity];
  return description.userInfo[ODataSyncDirectionKey] ?: @"down";
}

- (BOOL)entityIsEditable:(NSString *)entity
{
  NSString *direction = [self directionOfEntity:entity];
  return [direction isEqualToString:@"both"] || [direction isEqualToString:@"up"];
}

- (NSString *)titleOfEntity:(NSString *)entity
{
  NSString *direction = [self directionOfEntity:entity];
  if ([direction isEqualToString:@"both"]) return [entity stringByAppendingString:@" (both ways)"];
  if ([direction isEqualToString:@"up"]) return [entity stringByAppendingString:@" (up: the device's)"];
  return [entity stringByAppendingString:@" (down: the service's)"];
}

- (NSString *)rulesOfEntity:(NSString *)entity
{
  NSString *direction = [self directionOfEntity:entity];
  if ([direction isEqualToString:@"both"]) {
    return [NSString stringWithFormat:@"%@: both ways. Edit it here (a cell, New, Delete): the change waits under Waiting to be sent until "
                                      @"Sync or Upload sends it. The service's changes come with Sync or Download. Changed on both sides: "
                                      @"the Conflicts rule settles it.", entity];
  }
  if ([direction isEqualToString:@"up"]) {
    return [NSString stringWithFormat:@"%@: up, the device's. Made and changed here, sent by Sync or Upload; the service never sends it back.",
                                      entity];
  }
  return [NSString stringWithFormat:@"%@: down, the service's. It comes with Sync or Download, and is read only here (the "
                                    @"Workbench has no up entity: Products and Stock go both ways).", entity];
}

- (NSArray<NSString *> *)columnsOfEntity:(NSString *)name
{
  NSEntityDescription *entity = _coordinator.managedObjectModel.entitiesByName[name];
  // As the Workbench shows the Catalog's entities; then the version and the
  // stamp (the service's and the engine's), and what it belongs to.
  NSMutableArray *columns = [NSMutableArray array];
  for (NSString *column in WBColumnNames(entity, YES)) {
    if (entity.attributesByName[column]) [columns addObject:column];
  }
  for (NSString *column in WBSyncBookkeeping()) {
    if (entity.attributesByName[column] && ![columns containsObject:column]) [columns addObject:column];
  }
  for (NSString *column in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSRelationshipDescription *relationship = entity.relationshipsByName[column];
    if (!relationship.isToMany) [columns addObject:column];
  }
  return columns;
}

- (BOOL)column:(NSString *)column isEditableInEntity:(NSString *)name
{
  NSEntityDescription *entity = _coordinator.managedObjectModel.entitiesByName[name];
  NSAttributeDescription *attribute = entity.attributesByName[column];
  return [self entityIsEditable:name] && attribute && !WBIsKey(attribute) && ![WBSyncBookkeeping() containsObject:column];
}

#pragma mark Reading

- (NSArray<NSManagedObject *> *)objectsOfEntity:(NSString *)entity
{
  [_context reset];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
  return [_context executeFetchRequest:fetch error:NULL] ?: @[];
}

- (NSArray<ODataSyncChange *> *)pendingChanges
{
  return [_sync pendingChanges];
}

- (NSArray<WBSyncConflict *> *)conflicts
{
  return [_recorder recorded];
}

- (id)valueOfAttribute:(NSString *)attribute entity:(NSString *)entity key:(id)key
{
  __block id value = nil;
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = _coordinator;
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
    fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", key];
    value = [[[context executeFetchRequest:fetch error:NULL] firstObject] valueForKey:attribute];
  }];
  return value;
}

#pragma mark Running

- (BOOL)run:(WBSyncAction)action
{
  NSString *what = @[ @"Sync", @"Download", @"Upload", @"Reconcile" ][(NSUInteger)action];
  if (_busy) {
    [self say:@"Still syncing."];
    return NO;
  }
  _busy = YES;
  [self say:[what stringByAppendingString:@"…"]];
  ODataSyncEngine *sync = _sync;
  ODataSyncRemote *remote = [self remote];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSError *error = nil;
    BOOL ok = NO;
    switch (action) {
      case WBSyncActionSync: ok = [sync syncWithError:&error]; break;
      case WBSyncActionDownload: ok = [sync downloadFromRemote:remote error:&error]; break;
      case WBSyncActionUpload: ok = [sync uploadToRemote:remote error:&error]; break;
      case WBSyncActionReconcile: ok = [sync reconcileWithRemote:remote error:&error]; break;
    }
    ODataSyncResult *result = sync.lastResult;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finished:what ok:ok result:result error:error];
    });
  });
  return YES;
}

- (ODataSyncRemote *)serviceRemote
{
  return [self remote];
}

- (BOOL)syncWithRemote:(ODataSyncRemote *)remote named:(NSString *)name
{
  NSString *what = [@"Sync with " stringByAppendingString:name];
  if (_busy) {
    [self say:@"Still syncing."];
    return NO;
  }
  _busy = YES;
  [self say:[what stringByAppendingString:@"…"]];
  ODataSyncEngine *sync = _sync;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSError *error = nil;
    // The engine's only while it runs: Sync stays the service's.
    BOOL ok = [sync syncWithRemote:remote error:&error];
    ODataSyncResult *result = sync.lastResult;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finished:what ok:ok result:result error:error];
    });
  });
  return YES;
}

- (void)finished:(NSString *)what ok:(BOOL)ok result:(ODataSyncResult *)result error:(NSError *)error
{
  _busy = NO;
  if (!ok) {
    [self say:[NSString stringWithFormat:@"%@ failed: %@ The changes wait for the next sync.", what, error.localizedDescription ?: @"no answer."]];
    return;
  }
  NSMutableArray *parts = [NSMutableArray array];
  if (result) {
    [parts addObject:[NSString stringWithFormat:@"%lu down", (unsigned long)result.downloaded]];
    if (result.removed) [parts addObject:[NSString stringWithFormat:@"%lu removed", (unsigned long)result.removed]];
    [parts addObject:[NSString stringWithFormat:@"%lu up", (unsigned long)result.uploaded]];
    if (result.conflicts) [parts addObject:[NSString stringWithFormat:@"%lu conflict(s)", (unsigned long)result.conflicts]];
    if (result.refused) [parts addObject:[NSString stringWithFormat:@"%lu set aside", (unsigned long)result.refused]];
  }
  [self say:[NSString stringWithFormat:@"%@: %@. %lu change(s) waiting.", what, parts.count ? [parts componentsJoinedByString:@", "] : @"done",
                                       (unsigned long)[self pendingChanges].count]];
}

- (BOOL)syncAndWait:(NSError **)error
{
  return [_sync syncWithError:error];
}

#pragma mark Changing the device

- (id)valueFromText:(id)value attribute:(NSAttributeDescription *)attribute
{
  if (value == nil || [value isKindOfClass:[NSNull class]]) return nil;
  NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
  if (!text.length && attribute.attributeType != NSStringAttributeType) return nil;
  switch (attribute.attributeType) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType:
    case NSInteger64AttributeType: return @(text.longLongValue);
    case NSDecimalAttributeType: return [NSDecimalNumber decimalNumberWithString:text];
    case NSDoubleAttributeType:
    case NSFloatAttributeType: return @(text.doubleValue);
    case NSBooleanAttributeType: return @([@[ @"1", @"yes", @"true" ] containsObject:text.lowercaseString]);
    case NSDateAttributeType: return WBDate(text);
    default: return text;
  }
}

- (void)saveSaying:(NSString *)what
{
  NSError *error = nil;
  if (![_context save:&error]) {
    [_context rollback];
    [self say:[NSString stringWithFormat:@"Not saved: %@", error.localizedDescription]];
    return;
  }
  if (_syncsEachChange) {
    [self run:WBSyncActionSync];
    return;
  }
  [self say:[NSString stringWithFormat:@"%@ on the device; %lu change(s) waiting: Sync (or Upload) sends them.", what,
                                       (unsigned long)[self pendingChanges].count]];
}

- (void)setValue:(id)value ofAttribute:(NSString *)name object:(NSManagedObject *)object
{
  NSAttributeDescription *attribute = object.entity.attributesByName[name];
  if (!attribute) return;
  [object setValue:[self valueFromText:value attribute:attribute] forKey:name];
  [self saveSaying:[NSString stringWithFormat:@"%@ %@ changed", object.entity.name, [object valueForKey:@"id"]]];
}

- (NSManagedObject *)newObjectOfEntity:(NSString *)entity
{
  if (![self entityIsEditable:entity]) {
    [self say:[NSString stringWithFormat:@"%@ is the service's: the device only reads it.", entity]];
    return nil;
  }
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:_context];
  // A key no one else will take (the Catalog's keys are numbers).
  [object setValue:@(100000 + (NSInteger)([NSUUID UUID].UUIDString.hash % 900000)) forKey:@"id"];
  if (object.entity.attributesByName[@"name"]) [object setValue:@"New on the device" forKey:@"name"];
  if (object.entity.attributesByName[@"quantity"]) [object setValue:@0 forKey:@"quantity"];
  [self saveSaying:[NSString stringWithFormat:@"%@ %@ made (a random key: the Catalog's keys are numbers; an offline app's own would be UUIDs)",
                                             object.entity.name, [object valueForKey:@"id"]]];
  return object;
}

- (void)deleteObject:(NSManagedObject *)object
{
  NSString *what = [NSString stringWithFormat:@"%@ %@ deleted", object.entity.name, [object valueForKey:@"id"]];
  [_context deleteObject:object];
  [self saveSaying:what];
}

- (void)retryIssue:(ODataSyncIssue *)issue
{
  [_sync retryIssue:issue];
  [self say:@"It goes again at the next sync (a conflict's: the device's version over the service's)."];
}

- (void)discardIssue:(ODataSyncIssue *)issue
{
  [_sync discardIssue:issue];
  [self say:@"Discarded (a conflict's: the service's version is read at the next sync)."];
}

- (WBSyncRule)rule
{
  return _recorder.rule;
}

- (void)setRule:(WBSyncRule)rule
{
  _recorder.rule = rule;
}

- (BOOL)isOffline
{
  return _line.offline;
}

- (void)setOffline:(BOOL)offline
{
  _line.offline = offline;
}

#pragma mark ODataSyncDelegate

- (void)syncEngine:(ODataSyncEngine *)engine didSetAside:(ODataSyncIssue *)issue
{
  (void)engine;
  (void)issue;
}

- (void)syncEngine:(ODataSyncEngine *)engine ignoredLocalChangeToObject:(NSManagedObjectID *)objectID
{
  (void)engine;
  NSString *name = objectID.entity.name;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self say:[NSString stringWithFormat:@"A change to %@ is not sent: the service owns it.", name]];
  });
}

@end

#pragma mark - As text

static NSString *WBOperationName(ODataSyncOperation operation)
{
  switch (operation) {
    case ODataSyncOperationInsert: return @"insert";
    case ODataSyncOperationUpdate: return @"update";
    case ODataSyncOperationDelete: return @"delete";
    case ODataSyncOperationRefresh: return @"read again";
  }
  return @"?";
}

NSString *WBOutcomeName(ODataSyncResolutionKind kind)
{
  switch (kind) {
    case ODataSyncTakeRemote: return @"the service's";
    case ODataSyncKeepLocal: return @"the device's";
    case ODataSyncMerge: return @"merged";
    case ODataSyncDefer: return @"set aside";
  }
  return @"?";
}

NSString *WBKeyText(NSDictionary *key)
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *name in [key.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [parts addObject:key.count == 1 ? [key[name] description] : [NSString stringWithFormat:@"%@=%@", name, key[name]]];
  }
  return [parts componentsJoinedByString:@","];
}

NSString *WBTimeText(NSDate *date)
{
  NSDateFormatter *format = [[NSDateFormatter alloc] init];
  format.dateFormat = @"HH:mm:ss";
  return [format stringFromDate:date];
}

NSString *WBChangeText(ODataSyncChange *change)
{
  NSString *name = WBOperationName(change.operation);
  return change.operation == ODataSyncOperationUpdate && change.properties
      ? [NSString stringWithFormat:@"%@ %@", name, [change.properties componentsJoinedByString:@", "]] : name;
}

NSString *WBIssueText(ODataSyncChange *change)
{
  if (![change isKindOfClass:[ODataSyncIssue class]]) return @"";
  ODataSyncIssue *issue = (ODataSyncIssue *)change;
  return [NSString stringWithFormat:@"%ld %@", (long)issue.status, issue.message];
}

NSString *WBConflictSideText(WBSyncConflict *met, BOOL local)
{
  ODataSyncConflict *conflict = met.conflict;
  NSDictionary *values = local ? conflict.local : conflict.remote;
  NSSet *changed = local ? conflict.localChanges : conflict.remoteChanges;
  return values ? [[changed.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "] : @"deleted";
}

static NSString *WBValuesText(NSDictionary *values, NSSet *changed)
{
  if (!values) return @"  (deleted)\n";
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    id value = values[name] == [NSNull null] ? @"-" : values[name];
    [text appendFormat:@"  %@ %@ = %@\n", [changed containsObject:name] ? @"*" : @" ", name, WBCellValue(value)];
  }
  return text;
}

NSString *WBConflictText(WBSyncConflict *met)
{
  ODataSyncConflict *conflict = met.conflict;
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@: %@\n\n", conflict.entity.name, WBKeyText(conflict.key), WBOutcomeName(met.outcome)];
  [text appendString:@"Agreed on last:\n"];
  [text appendString:conflict.base ? WBValuesText(conflict.base, nil) : @"  (not known)\n"];
  [text appendString:@"\nOn the device:\n"];
  [text appendString:WBValuesText(conflict.local, conflict.localChanges)];
  [text appendString:@"\nAt the service:\n"];
  [text appendString:WBValuesText(conflict.remote, conflict.remoteChanges)];
  return text;
}

static NSString *WBBodyText(NSData *data)
{
  if (!data.length) return @"";
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  NSData *pretty = json ? [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:NULL] : nil;
  return [[NSString alloc] initWithData:pretty ?: data encoding:NSUTF8StringEncoding] ?: @"(binary)";
}

NSString *WBRequestText(WorkbenchLogEntry *entry)
{
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@\n", entry.method, entry.URL];
  for (NSString *name in [entry.requestHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [text appendFormat:@"%@: %@\n", name, entry.requestHeaders[name]];
  }
  if (entry.requestData.length) [text appendFormat:@"\n%@\n", WBBodyText(entry.requestData)];
  if (entry.failure && !entry.status) {
    [text appendFormat:@"\nNo answer: %@\n", entry.failure];
  } else {
    [text appendFormat:@"\n%ld\n", (long)entry.status];
    for (NSString *name in [entry.responseHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      [text appendFormat:@"%@: %@\n", name, entry.responseHeaders[name]];
    }
    if (entry.responseData.length) [text appendFormat:@"\n%@\n", WBBodyText(entry.responseData)];
  }
  return text;
}

NSString *WBRequestPath(WorkbenchLogEntry *entry, NSURL *serviceRoot)
{
  NSString *root = serviceRoot.absoluteString;
  return root.length && [entry.URL hasPrefix:root] ? [entry.URL substringFromIndex:root.length] : entry.URL;
}
