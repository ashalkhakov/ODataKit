// Reconciliation as a whole (docs/offline-sync.md, 6 and 7): every
// conflict a both entity can meet, under every rule, found on download and
// on upload; and devices, peers and the service changing data at random,
// syncing in random orders, which must end in agreement.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <ODataSync/ODataSync.h>
#import <ODataService/ODataService.h>

static NSAttributeDescription *OSCAttribute(NSString *name, NSAttributeType type, NSDictionary *userInfo)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = YES;
  attribute.preservesValueInHistoryOnDeletion = YES;
  if (userInfo) attribute.userInfo = userInfo;
  return attribute;
}

static NSEntityDescription *OSCEntity(NSString *name, NSString *set, NSString *direction, NSArray *properties)
{
  NSEntityDescription *entity = [[NSEntityDescription alloc] init];
  entity.name = name;
  entity.managedObjectClassName = @"NSManagedObject";
  NSMutableDictionary *userInfo = [@{ @"OData.entitySet": set, ODataSyncDirectionKey: direction } mutableCopy];
  if ([direction isEqualToString:@"up"] || [direction isEqualToString:@"both"]) userInfo[ODataSyncModifiedKey] = @"modified";
  entity.userInfo = userInfo;
  entity.properties = properties;
  return entity;
}

// Assets (down, with the service's version counter), Inspections (up) and
// Tasks (both), each up or both one stamped for last writer wins.
static NSManagedObjectModel *OSCModel(BOOL versions)
{
  NSDictionary *key = @{ @"OData.key": @"YES" };
  NSEntityDescription *asset = OSCEntity(@"Asset", @"Assets", @"down", @[
    OSCAttribute(@"id", NSInteger32AttributeType, key), OSCAttribute(@"name", NSStringAttributeType, nil),
    OSCAttribute(@"version", NSInteger64AttributeType, @{ @"OData.etag": @"YES" }) ]);
  NSEntityDescription *inspection = OSCEntity(@"Inspection", @"Inspections", @"up", @[
    OSCAttribute(@"id", NSStringAttributeType, key), OSCAttribute(@"note", NSStringAttributeType, nil),
    OSCAttribute(@"modified", NSStringAttributeType, nil) ]);
  NSEntityDescription *task = OSCEntity(@"Task", @"Tasks", @"both", @[
    OSCAttribute(@"id", NSStringAttributeType, key), OSCAttribute(@"title", NSStringAttributeType, nil),
    OSCAttribute(@"done", NSBooleanAttributeType, nil), OSCAttribute(@"modified", NSStringAttributeType, nil) ]);
  if (versions) {
    // What each version has seen (docs/offline-sync.md, 12).
    for (NSEntityDescription *entity in @[ inspection, task ]) {
      entity.properties = [entity.properties arrayByAddingObject:OSCAttribute(@"versions", NSStringAttributeType, nil)];
      NSMutableDictionary *info = [entity.userInfo mutableCopy];
      info[ODataSyncVersionsKey] = @"versions";
      entity.userInfo = info;
    }
  }
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ asset, inspection, task ];
  return model;
}

// A device: its store, its engine, its peer server, and its remotes.
@interface OSCDevice : NSObject
@property (nonatomic) NSUInteger number;
@property (nonatomic, strong) NSPersistentStoreCoordinator *store;
@property (nonatomic, strong) ODataSyncEngine *engine;
@property (nonatomic, strong) ODataSyncPeerServer *server;
@property (nonatomic) BOOL reachesService;
@end

@implementation OSCDevice
@end

@interface ODataSyncConvergenceTests : XCTestCase
@end

@implementation ODataSyncConvergenceTests {
  NSMutableArray<NSURL *> *_files;
  NSPersistentStoreCoordinator *_server;
  ODataService *_service;
  uint64_t _random;
  BOOL _versions;
  ODataSyncService *_sync;
  long long _serviceTime;
  int _serviceCounter;
}

- (void)setUp
{
  _files = [NSMutableArray array];
}

- (void)tearDown
{
  for (NSURL *url in _files) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
}

#pragma mark Stores

- (NSPersistentStoreCoordinator *)storeWithModel:(NSManagedObjectModel *)model
{
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
  [_files addObject:url];
  NSError *error = nil;
  XCTAssertNotNil([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url
                                                  options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error], @"%@", error);
  return coordinator;
}

- (void)makeService
{
  NSManagedObjectModel *model = OSCModel(_versions);
  if (_versions) [ODataSyncService addBookkeepingToModel:model configuration:nil];
  _server = [self storeWithModel:model];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_server serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  // The service compares histories, and keeps deletions.
  _sync = _versions ? [[ODataSyncService alloc] initWithService:_service] : nil;
  _serviceTime = 0;
  _serviceCounter = 0;
}

- (ODataSyncRemote *)serviceRemote
{
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  remote.transport = _service;
  return remote;
}

- (OSCDevice *)deviceNumber:(NSUInteger)number
{
  NSManagedObjectModel *model = OSCModel(_versions);
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  OSCDevice *device = [[OSCDevice alloc] init];
  device.number = number;
  device.store = [self storeWithModel:model];
  device.engine = [[ODataSyncEngine alloc] initWithCoordinator:device.store];
  device.server = [[ODataSyncPeerServer alloc] initWithEngine:device.engine host:@"peer.test" port:8000 + number];
  return device;
}

- (ODataSyncRemote *)peerRemoteOf:(OSCDevice *)device
{
  ODataSyncRemote *peer = [ODataSyncRemote peerWithServiceRoot:device.server.serviceRoot];
  peer.transport = device.server.service;
  return peer;
}

- (void)in:(NSPersistentStoreCoordinator *)coordinator do:(void (^)(NSManagedObjectContext *context))work
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  [context performBlockAndWait:^{
    work(context);
    NSError *error = nil;
    if (context.hasChanges) XCTAssertTrue([context save:&error], @"%@", error);
  }];
}

- (NSManagedObject *)object:(NSString *)entity id:(id)identifier in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", identifier];
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

// Each object of the entity as its values, by id.
- (NSDictionary<id<NSCopying>, NSDictionary *> *)rowsOf:(NSString *)entity keys:(NSArray<NSString *> *)keys in:(NSPersistentStoreCoordinator *)coordinator
{
  NSMutableDictionary *rows = [NSMutableDictionary dictionary];
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    for (NSManagedObject *object in [context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:entity] error:NULL]) {
      NSMutableDictionary *row = [NSMutableDictionary dictionary];
      for (NSString *key in keys) row[key] = [object valueForKey:key] ?: [NSNull null];
      rows[[object valueForKey:@"id"]] = row;
    }
  }];
  return rows;
}

- (NSUInteger)pendingIn:(OSCDevice *)device
{
  __block NSUInteger count = 0;
  [self in:device.store do:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"ODSOutboxEntry"];
    count = [context countForFetchRequest:fetch error:NULL];
  }];
  return count;
}

// The service's own writes stamp as a hybrid logical clock would: past
// the wall clock and past the row's stamp.
- (NSString *)serviceStampAfter:(NSString *)previous
{
  long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
  long long seenTime = previous.length >= 21 ? [[previous substringToIndex:16] longLongValue] : 0;
  int seenCounter = previous.length >= 21 ? [[previous substringWithRange:NSMakeRange(17, 4)] intValue] : 0;
  if (seenTime > _serviceTime || (seenTime == _serviceTime && seenCounter > _serviceCounter)) {
    _serviceTime = seenTime;
    _serviceCounter = seenCounter;
  }
  if (now > _serviceTime) {
    _serviceTime = now;
    _serviceCounter = 0;
  } else {
    _serviceCounter++;
  }
  return [NSString stringWithFormat:@"%016lld.%04d.service0", _serviceTime, _serviceCounter];
}

#pragma mark The conflict matrix

typedef NS_ENUM(NSInteger, OSCChange) { OSCNone, OSCEditTitle, OSCEditDone, OSCDelete };
typedef NS_ENUM(NSInteger, OSCRule) { OSCRemoteWins, OSCLocalWins, OSCLastWriterLocalLater, OSCLastWriterRemoteLater, OSCMerge };

static NSString *OSCChangeName(OSCChange change)
{
  return @[ @"none", @"edit title", @"edit done", @"delete" ][change];
}

static NSString *OSCRuleName(OSCRule rule)
{
  return @[ @"remote wins", @"local wins", @"last writer (local later)", @"last writer (remote later)", @"merge" ][rule];
}

// A side's version after its change: {title, done}, nil when deleted.
static NSDictionary *OSCAfter(OSCChange change, NSString *title)
{
  switch (change) {
    case OSCNone: return @{ @"title": @"Base", @"done": @NO };
    case OSCEditTitle: return @{ @"title": title, @"done": @NO };
    case OSCEditDone: return @{ @"title": @"Base", @"done": @YES };
    case OSCDelete: return nil;
  }
}

// What both sides should end with.
static NSDictionary *OSCExpected(OSCChange local, OSCChange remote, OSCRule rule)
{
  NSDictionary *mine = OSCAfter(local, @"Local"), *theirs = OSCAfter(remote, @"Remote");
  if (local == OSCNone) return theirs;
  if (remote == OSCNone) return mine;
  if (!mine && !theirs) return nil;
  switch (rule) {
    case OSCRemoteWins: return theirs;
    case OSCLocalWins: return mine;
    case OSCLastWriterLocalLater:
    case OSCLastWriterRemoteLater:
      // A delete has no stamp: the other side's change stands.
      if (!mine) return theirs;
      if (!theirs) return mine;
      return rule == OSCLastWriterRemoteLater ? theirs : mine;
    case OSCMerge: {
      // A delete is the fallback's (remote wins); else property by property,
      // what both changed the fallback's.
      if (!mine || !theirs) return theirs;
      NSDictionary *base = OSCAfter(OSCNone, nil);
      NSMutableDictionary *merged = [NSMutableDictionary dictionary];
      for (NSString *name in base) {
        BOOL here = ![mine[name] isEqual:base[name]], there = ![theirs[name] isEqual:base[name]];
        merged[name] = here && !there ? mine[name] : theirs[name];
      }
      return merged;
    }
  }
}

- (id<ODataSyncResolving>)resolverFor:(OSCRule)rule
{
  switch (rule) {
    case OSCRemoteWins: return [[ODataSyncRemoteWins alloc] init];
    case OSCLocalWins: return [[ODataSyncLocalWins alloc] init];
    case OSCLastWriterLocalLater:
    case OSCLastWriterRemoteLater: return [[ODataSyncLastWriterWins alloc] init];
    case OSCMerge: return [[ODataSyncMergeFields alloc] init];
  }
}

- (void)apply:(OSCChange)change to:(NSString *)task title:(NSString *)title stamp:(NSString *)stamp in:(NSPersistentStoreCoordinator *)store
{
  if (change == OSCNone) return;
  [self in:store do:^(NSManagedObjectContext *context) {
    NSManagedObject *object = [self object:@"Task" id:task in:context];
    if (change == OSCDelete) {
      [context deleteObject:object];
      return;
    }
    if (change == OSCEditTitle) [object setValue:title forKey:@"title"];
    if (change == OSCEditDone) [object setValue:@YES forKey:@"done"];
    if (stamp) [object setValue:stamp forKey:@"modified"];
  }];
}

// One case: a task both agreed on, changed on each side, then synced; the
// conflict met by the download, or by the upload's If-Match.
- (void)runLocal:(OSCChange)local remote:(OSCChange)remote rule:(OSCRule)rule onUpload:(BOOL)onUpload
{
  NSString *name = [NSString stringWithFormat:@"device %@, service %@, %@, on %@", OSCChangeName(local), OSCChangeName(remote),
                                              OSCRuleName(rule), onUpload ? @"upload" : @"download"];
  [self makeService];
  OSCDevice *device = [self deviceNumber:0];
  ODataSyncRemote *service = [self serviceRemote];
  [device.engine addRemote:service];
  [device.engine setResolver:[self resolverFor:rule] forEntityName:@"Task"];
  NSString *task = [NSUUID UUID].UUIDString;
  [self in:device.store do:^(NSManagedObjectContext *context) {
    NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
    [object setValue:task forKey:@"id"];
    [object setValue:@"Base" forKey:@"title"];
    [object setValue:@NO forKey:@"done"];
  }];
  NSError *error = nil;
  XCTAssertTrue([device.engine syncWithError:&error], @"%@: %@", name, error);
  // The device's change stamped now; the service's earlier or later.
  NSString *remoteStamp = rule == OSCLastWriterRemoteLater ? @"9999999999999999.0000.service0" : @"0000000000000001.0000.service0";
  [self apply:remote to:task title:@"Remote" stamp:remoteStamp in:_server];
  [self apply:local to:task title:@"Local" stamp:nil in:device.store];

  if (onUpload) XCTAssertTrue([device.engine uploadToRemote:service error:&error], @"%@: %@", name, error);
  XCTAssertTrue([device.engine syncWithError:&error], @"%@: %@", name, error);
  NSDictionary *expected = OSCExpected(local, remote, rule);
  for (NSPersistentStoreCoordinator *side in @[ device.store, _server ]) {
    NSDictionary *row = [self rowsOf:@"Task" keys:@[ @"title", @"done" ] in:side][task];
    XCTAssertEqualObjects(row, expected, @"%@ at the %@", name, side == _server ? @"service" : @"device");
  }
  XCTAssertEqual([self pendingIn:device], 0u, @"%@: nothing left to send", name);
  XCTAssertEqual(device.engine.issues.count, 0u, @"%@", name);
  XCTAssertTrue([device.engine syncWithError:&error], @"%@: %@", name, error);
  ODataSyncResult *again = device.engine.lastResult;
  XCTAssertEqual(again.uploaded + again.downloaded + again.removed + again.conflicts, 0u, @"%@: settled for good: %@", name, again);
}

// The service's synced sets (those that keep version vectors) indexed by
// their keys: each object a device sends is looked up by it.
- (void)testTheServicesSyncedSetsAreIndexedByKey
{
  NSManagedObjectModel *model = OSCModel(YES);
  [ODataSyncService addBookkeepingToModel:model configuration:nil];
  for (NSString *name in @[ @"Inspection", @"Task" ]) {
    NSFetchIndexDescription *index = [model.entitiesByName[name] indexes].firstObject;
    XCTAssertEqualObjects(index.name, @"ODataSyncKey", @"%@", name);
    XCTAssertEqualObjects([index.elements valueForKeyPath:@"property.name"], @[ @"id" ], @"%@", name);
  }
  XCTAssertEqual([model.entitiesByName[@"Asset"] indexes].count, 0u, @"keeps no versions: not synced at the service");
  XCTAssertNotNil([self storeWithModel:model], @"and a store is made with them");
}

- (void)testEveryConflictUnderEveryRuleWithVersions
{
  _versions = YES;
  [self testEveryConflictUnderEveryRule];
}

- (void)testEveryConflictUnderEveryRule
{
  for (OSCRule rule = OSCRemoteWins; rule <= OSCMerge; rule++) {
    for (OSCChange local = OSCNone; local <= OSCDelete; local++) {
      for (OSCChange remote = OSCNone; remote <= OSCDelete; remote++) {
        if (local == OSCNone && remote == OSCNone) continue;
        if (local == OSCEditDone) continue;  // the same as editing the title, here
        for (int onUpload = 0; onUpload < 2; onUpload++) [self runLocal:local remote:remote rule:rule onUpload:onUpload];
      }
    }
  }
}

#pragma mark Convergence

- (uint64_t)next
{
  _random ^= _random << 13;
  _random ^= _random >> 7;
  _random ^= _random << 17;
  return _random;
}

- (NSUInteger)below:(NSUInteger)n
{
  return (NSUInteger)([self next] % n);
}

- (id)pick:(NSArray *)array
{
  return array.count ? array[[self below:array.count]] : nil;
}

- (NSArray *)idsOf:(NSString *)entity in:(NSPersistentStoreCoordinator *)store
{
  return [[[self rowsOf:entity keys:@[] in:store] allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (void)runSeed:(uint64_t)seed steps:(NSUInteger)steps
{
  _random = seed * 2654435761u + 1;
  // Odd seeds settle by last writer wins, and the last version must stand;
  // even ones by the default (the remote wins), where agreeing is all.
  BOOL lastWriter = seed % 2 == 1;
  [self makeService];
  [self in:_server do:^(NSManagedObjectContext *context) {
    for (int i = 1; i <= 3; i++) {
      NSManagedObject *asset = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
      [asset setValue:@(i) forKey:@"id"];
      [asset setValue:[NSString stringWithFormat:@"Asset %d", i] forKey:@"name"];
      [asset setValue:@1 forKey:@"version"];
    }
  }];
  // Four devices: the first two reach the service; each of the others
  // reaches one or two of the devices before it, as a peer; and a device
  // may also offer itself to one that reaches the service.
  NSMutableArray<OSCDevice *> *devices = [NSMutableArray array];
  for (NSUInteger i = 0; i < 4; i++) {
    OSCDevice *device = [self deviceNumber:i];
    if (lastWriter) {
      for (NSString *entity in @[ @"Task", @"Inspection" ]) [device.engine setResolver:[[ODataSyncLastWriterWins alloc] init] forEntityName:entity];
    }
    if (i < 2) {
      device.reachesService = YES;
      [device.engine addRemote:[self serviceRemote]];
    } else {
      NSMutableSet *peers = [NSMutableSet setWithObject:devices[[self below:i]]];
      if ([self below:2]) [peers addObject:devices[[self below:i]]];
      for (OSCDevice *peer in peers) [device.engine addRemote:[self peerRemoteOf:peer]];
      if ([self below:2]) [devices[[self below:2]].engine addRemote:[self peerRemoteOf:device]];
    }
    [devices addObject:device];
  }
  NSMutableDictionary<NSString *, NSMutableArray *> *taskStamps = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSMutableArray *> *inspectionWrites = [NSMutableDictionary dictionary];
  NSMutableSet<NSString *> *deletedTasks = [NSMutableSet set], *deletedInspections = [NSMutableSet set];
  NSMutableArray *log = [NSMutableArray array];
  void (^record)(NSMutableDictionary *, NSString *, id) = ^(NSMutableDictionary *writes, NSString *identifier, id write) {
    if (!writes[identifier]) writes[identifier] = [NSMutableArray array];
    [writes[identifier] addObject:write];
  };

  for (NSUInteger step = 0; step < steps; step++) {
    NSUInteger roll = [self below:100];
    OSCDevice *device = [self pick:devices];
    NSString *label = [NSString stringWithFormat:@"%lu", (unsigned long)step];
    if (roll < 25) {
      // A task, on a device: made, edited or deleted.
      NSString *task = [self pick:[self idsOf:@"Task" in:device.store]];
      NSUInteger what = task ? [self below:4] : 0;
      __block NSString *identifier = task;
      [self in:device.store do:^(NSManagedObjectContext *context) {
        if (what == 0) {
          identifier = [NSUUID UUID].UUIDString;
          NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
          [object setValue:identifier forKey:@"id"];
          [object setValue:[@"Task " stringByAppendingString:label] forKey:@"title"];
          [object setValue:@NO forKey:@"done"];
        } else if (what == 3) {
          [context deleteObject:[self object:@"Task" id:task in:context]];
        } else {
          NSManagedObject *object = [self object:@"Task" id:task in:context];
          if (what == 1) [object setValue:[@"Title " stringByAppendingString:label] forKey:@"title"];
          else [object setValue:@(![[object valueForKey:@"done"] boolValue]) forKey:@"done"];
        }
      }];
      if (what == 3) {
        [deletedTasks addObject:identifier];
      } else {
        record(taskStamps, identifier, [self rowsOf:@"Task" keys:@[ @"modified" ] in:device.store][identifier][@"modified"]);
      }
      [log addObject:[NSString stringWithFormat:@"%@: device %lu task %@ %@", label, (unsigned long)device.number,
                                                @[ @"made", @"retitled", @"toggled", @"deleted" ][what], [identifier substringToIndex:4]]];
    } else if (roll < 40) {
      // An inspection, on a device.
      NSString *inspection = [self pick:[self idsOf:@"Inspection" in:device.store]];
      NSUInteger what = inspection ? [self below:3] : 0;
      __block NSString *identifier = inspection;
      NSString *note = [@"Note " stringByAppendingString:label];
      [self in:device.store do:^(NSManagedObjectContext *context) {
        if (what == 0) {
          identifier = [NSUUID UUID].UUIDString;
          NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
          [object setValue:identifier forKey:@"id"];
          [object setValue:note forKey:@"note"];
        } else if (what == 1) {
          [[self object:@"Inspection" id:inspection in:context] setValue:note forKey:@"note"];
        } else {
          [context deleteObject:[self object:@"Inspection" id:inspection in:context]];
        }
      }];
      if (what == 2) {
        [deletedInspections addObject:identifier];
      } else {
        record(inspectionWrites, identifier, [self rowsOf:@"Inspection" keys:@[ @"note", @"modified" ] in:device.store][identifier]);
      }
      [log addObject:[NSString stringWithFormat:@"%@: device %lu inspection %@ %@", label, (unsigned long)device.number,
                                                @[ @"made", @"noted", @"deleted" ][what], [identifier substringToIndex:4]]];
    } else if (roll < 55) {
      // At the service: a task made, edited or deleted, or an asset changed.
      NSUInteger what = [self below:5];
      NSString *task = [self pick:[self idsOf:@"Task" in:_server]];
      if (!task && what >= 1 && what <= 3) what = 0;
      __block NSString *identifier = task;
      __block NSString *stamp = nil;
      [self in:_server do:^(NSManagedObjectContext *context) {
        if (what == 0) {
          identifier = [NSUUID UUID].UUIDString;
          NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
          [object setValue:identifier forKey:@"id"];
          [object setValue:[@"Service's " stringByAppendingString:label] forKey:@"title"];
          [object setValue:@NO forKey:@"done"];
          stamp = [self serviceStampAfter:nil];
          [object setValue:stamp forKey:@"modified"];
        } else if (what <= 2) {
          NSManagedObject *object = [self object:@"Task" id:task in:context];
          if (what == 1) [object setValue:[@"Service's " stringByAppendingString:label] forKey:@"title"];
          else [object setValue:@(![[object valueForKey:@"done"] boolValue]) forKey:@"done"];
          stamp = [self serviceStampAfter:[object valueForKey:@"modified"]];
          [object setValue:stamp forKey:@"modified"];
        } else if (what == 3) {
          [context deleteObject:[self object:@"Task" id:task in:context]];
        } else {
          NSManagedObject *asset = [self object:@"Asset" id:@(1 + [self below:3]) in:context];
          [asset setValue:[@"Asset " stringByAppendingString:label] forKey:@"name"];
          [asset setValue:@([[asset valueForKey:@"version"] longLongValue] + 1) forKey:@"version"];
          identifier = [[asset valueForKey:@"id"] stringValue];
        }
      }];
      if (what == 3) [deletedTasks addObject:identifier];
      if (stamp) record(taskStamps, identifier, stamp);
      [log addObject:[NSString stringWithFormat:@"%@: service %@ %@", label, @[ @"made task", @"retitled task", @"toggled task", @"deleted task", @"changed asset" ][what],
                                                [identifier substringToIndex:MIN(4u, identifier.length)]]];
    } else {
      // A sync: of one remote, both halves or one, or of them all.
      ODataSyncRemote *remote = [self pick:device.engine.remotes];
      NSUInteger how = [self below:4];
      NSError *error = nil;
      BOOL ok = YES;
      if (how == 0 || !remote) ok = [device.engine syncWithError:&error];
      else if (how == 1) ok = [device.engine downloadFromRemote:remote error:&error];
      else if (how == 2) ok = [device.engine uploadToRemote:remote error:&error];
      else ok = [device.engine downloadFromRemote:remote error:&error] && [device.engine uploadToRemote:remote error:&error];
      XCTAssertTrue(ok, @"seed %llu step %@: %@", (unsigned long long)seed, label, error);
      [log addObject:[NSString stringWithFormat:@"%@: device %lu %@ %@", label, (unsigned long)device.number,
                                                @[ @"syncs all", @"downloads from", @"uploads to", @"syncs with" ][remote ? how : 0], remote ?: @""]];
    }
  }

  // Everyone reaches the service now, and syncs until nothing changes.
  for (OSCDevice *device in devices) {
    if (!device.reachesService) [device.engine addRemote:[self serviceRemote]];
  }
  NSUInteger rounds = 0, changes = 0;
  do {
    changes = 0;
    for (OSCDevice *device in devices) {
      NSError *error = nil;
      XCTAssertTrue([device.engine syncWithError:&error], @"seed %llu: %@", (unsigned long long)seed, error);
      ODataSyncResult *result = device.engine.lastResult;
      changes += result.uploaded + result.downloaded + result.removed + result.conflicts + result.refused;
      [log addObject:[NSString stringWithFormat:@"round %lu: device %lu %@", (unsigned long)rounds, (unsigned long)device.number, result]];
    }
    rounds++;
  } while (changes && rounds < 8);
  NSString *story = [log componentsJoinedByString:@"\n"];
  XCTAssertEqual(changes, 0u, @"seed %llu: still changing after %lu rounds\n%@", (unsigned long long)seed, (unsigned long)rounds, story);

  NSDictionary *tasks = [self rowsOf:@"Task" keys:@[ @"title", @"done", @"modified" ] in:_server];
  NSDictionary *assets = [self rowsOf:@"Asset" keys:@[ @"name", @"version" ] in:_server];
  for (OSCDevice *device in devices) {
    NSString *who = [NSString stringWithFormat:@"seed %llu, device %lu", (unsigned long long)seed, (unsigned long)device.number];
    NSDictionary *deviceTasks = [self rowsOf:@"Task" keys:@[ @"title", @"done", @"modified" ] in:device.store];
    NSDictionary *deviceAssets = [self rowsOf:@"Asset" keys:@[ @"name", @"version" ] in:device.store];
    if (![deviceTasks isEqual:tasks]) {
      // Only what differs: the service's, and this device's.
      NSMutableString *differences = [NSMutableString string];
      NSMutableSet *ids = [NSMutableSet setWithArray:tasks.allKeys];
      [ids addObjectsFromArray:deviceTasks.allKeys];
      for (NSString *task in ids) {
        if ([tasks[task] isEqual:deviceTasks[task]]) continue;
        [differences appendFormat:@"%@: service %@, device %@\n", task, tasks[task], deviceTasks[task]];
      }
      XCTFail(@"%@: the tasks differ\n%@\n%@", who, differences, story);
    }
    XCTAssertEqualObjects(deviceAssets, assets, @"%@: the assets agree", who);
    XCTAssertEqual([self pendingIn:device], 0u, @"%@: nothing left to send\n%@", who, story);
    XCTAssertEqual(device.engine.issues.count, 0u, @"%@: %@", who, device.engine.issues);
  }
  if (!lastWriter) return;
  // A task that is left has the last version written (by the stamps); one
  // that came back after a deletion may not (the known issue, 7.1).
  NSUInteger cameBack = 0;
  for (NSString *task in tasks) {
    NSString *last = [taskStamps[task] valueForKeyPath:@"@max.self"];
    NSString *kept = tasks[task][@"modified"];
    if ([kept isEqual:last]) continue;
    if ([deletedTasks containsObject:task]) {
      cameBack++;
      continue;
    }
    XCTFail(@"seed %llu: task %@ kept %@, not the last %@\n%@", (unsigned long long)seed, task, kept, last, story);
  }
  // An inspection no device deleted reached the service, as last written.
  NSDictionary *inspections = [self rowsOf:@"Inspection" keys:@[ @"note", @"modified" ] in:_server];
  for (NSString *inspection in inspectionWrites) {
    if ([deletedInspections containsObject:inspection]) continue;
    NSArray *writes = [inspectionWrites[inspection] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      return [a[@"modified"] compare:b[@"modified"]];
    }];
    XCTAssertEqualObjects(inspections[inspection], writes.lastObject, @"seed %llu: inspection %@\n%@", (unsigned long long)seed, inspection, story);
  }
  if (cameBack) NSLog(@"seed %llu: %lu deleted task(s) came back (docs/offline-sync.md, 7.1)", (unsigned long long)seed, (unsigned long)cameBack);
}

// The same, each object keeping what its version has seen.
- (void)testDevicesPeersAndTheServiceConvergeWithVersions
{
  _versions = YES;
  [self testDevicesPeersAndTheServiceConverge];
}

// ODATASYNC_SEEDS=200 for a longer run; ODATASYNC_SEED=n for one seed.
- (void)testDevicesPeersAndTheServiceConverge
{
  NSDictionary *environment = [NSProcessInfo processInfo].environment;
  if (environment[@"ODATASYNC_SEED"]) {
    [self runSeed:(uint64_t)[environment[@"ODATASYNC_SEED"] longLongValue] steps:120];
    return;
  }
  NSUInteger seeds = environment[@"ODATASYNC_SEEDS"] ? (NSUInteger)[environment[@"ODATASYNC_SEEDS"] integerValue] : 8;
  for (uint64_t seed = 1; seed <= seeds; seed++) [self runSeed:seed steps:120];
}

#pragma mark The service's part

- (NSString *)makeTask:(NSString *)title in:(NSPersistentStoreCoordinator *)store
{
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self in:store do:^(NSManagedObjectContext *context) {
    NSManagedObject *task = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
    [task setValue:identifier forKey:@"id"];
    [task setValue:title forKey:@"title"];
    [task setValue:@NO forKey:@"done"];
  }];
  return identifier;
}

- (void)sync:(OSCDevice *)device
{
  NSError *error = nil;
  XCTAssertTrue([device.engine syncWithError:&error], @"%@", error);
}

- (void)testAnInsertPassedOnLateDoesNotBringBackWhatTheServiceDeleted
{
  // docs/offline-sync.md, 7.1, closed by the histories.
  _versions = YES;
  [self makeService];
  OSCDevice *basement = [self deviceNumber:0];
  OSCDevice *carrier = [self deviceNumber:1];
  OSCDevice *late = [self deviceNumber:2];
  [carrier.engine addRemote:[self peerRemoteOf:basement]];
  [carrier.engine addRemote:[self serviceRemote]];
  [late.engine addRemote:[self peerRemoteOf:basement]];
  [late.engine addRemote:[self serviceRemote]];
  NSString *task = [self makeTask:@"Check pump" in:basement.store];
  [self sync:carrier];
  XCTAssertEqual([self idsOf:@"Task" in:_server].count, 1u, @"passed on to the service");
  [self in:_server do:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Task" id:task in:context]];
  }];
  // Another device that had not heard: it reads the task from the
  // basement, and passes its insert on.
  [self sync:late];
  XCTAssertEqual([self idsOf:@"Task" in:_server].count, 0u, @"the late insert refused (410)");
  XCTAssertEqual([self idsOf:@"Task" in:late.store].count, 0u, @"and the deletion taken");
  [self sync:late];
  XCTAssertEqual(late.engine.lastResult.uploaded + late.engine.lastResult.downloaded, 0u, @"%@", late.engine.lastResult);
}

- (void)checkAChangeMeetsTheDeletionUnder:(id<ODataSyncResolving>)rule changeStands:(BOOL)stands
{
  _versions = YES;
  [self makeService];
  OSCDevice *device = [self deviceNumber:0];
  [device.engine addRemote:[self serviceRemote]];
  [device.engine setResolver:rule forEntityName:@"Task"];
  NSString *task = [self makeTask:@"Check pump" in:device.store];
  [self sync:device];
  // Deleted at the service; changed on the device, which did not know.
  [self in:_server do:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Task" id:task in:context]];
  }];
  [self in:device.store do:^(NSManagedObjectContext *context) {
    [[self object:@"Task" id:task in:context] setValue:@"Check pump today" forKey:@"title"];
  }];
  NSError *error = nil;
  XCTAssertTrue([device.engine uploadToRemote:device.engine.remotes.firstObject error:&error], @"%@", error);
  [self sync:device];
  NSArray *atService = [[[self rowsOf:@"Task" keys:@[ @"title" ] in:_server] allValues] valueForKey:@"title"];
  NSArray *onDevice = [[[self rowsOf:@"Task" keys:@[ @"title" ] in:device.store] allValues] valueForKey:@"title"];
  NSArray *expected = stands ? @[ @"Check pump today" ] : @[];
  XCTAssertEqualObjects(atService, expected, @"%@", NSStringFromClass([rule class]));
  XCTAssertEqualObjects(onDevice, expected, @"%@", NSStringFromClass([rule class]));
  [self sync:device];
  XCTAssertEqual(device.engine.lastResult.uploaded + device.engine.lastResult.downloaded + device.engine.lastResult.conflicts, 0u, @"%@",
                 device.engine.lastResult);
}

- (void)testAChangeMadeWithoutKnowingOfTheDeletionIsAConflict
{
  [self checkAChangeMeetsTheDeletionUnder:[[ODataSyncLastWriterWins alloc] init] changeStands:YES];
  [self checkAChangeMeetsTheDeletionUnder:[[ODataSyncRemoteWins alloc] init] changeStands:NO];
}

@end
