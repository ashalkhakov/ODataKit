// An offline store kept in sync with a service (docs/offline-sync.md): the
// engine against an ODataService in the process, each with a SQLite store
// of its own that keeps history.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <ODataSync/ODataSync.h>
#import <ODataService/ODataService.h>
#import <ODataKit/ODataError.h>

// Refuses an inspection whose note is "bad", as a service's rule would.
@interface OSTPickyInspections : ODataEntitySetHandler
@end

@implementation OSTPickyInspections
- (NSManagedObject *)insertObjectWithValues:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  if ([values[@"note"] isEqual:@"bad"]) {
    [reply failWithError:ODataServiceError(400, @"A note cannot be bad")];
    return nil;
  }
  return [super insertObjectWithValues:values request:request reply:reply];
}
@end

// Both titles, joined; or set aside, when told to.
@interface OSTJoiningResolver : NSObject <ODataSyncResolving>
@property (nonatomic) BOOL defers;
@property (atomic, strong) ODataSyncConflict *last;
@end

@implementation OSTJoiningResolver
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  self.last = conflict;
  if (self.defers) return [ODataSyncResolution defer];
  return [ODataSyncResolution mergedValues:@{ @"title": [NSString stringWithFormat:@"%@ / %@", conflict.local[@"title"], conflict.remote[@"title"]] }];
}
@end

@interface OSTDelegate : NSObject <ODataSyncDelegate>
@property (atomic, strong) NSMutableArray *setAside;
@property (atomic, strong) NSMutableArray *ignored;
@property (atomic, strong) NSMutableArray<ODataSyncProgress *> *progress;
@end

@implementation OSTDelegate
- (instancetype)init
{
  self = [super init];
  _setAside = [NSMutableArray array];
  _ignored = [NSMutableArray array];
  _progress = [NSMutableArray array];
  return self;
}
- (void)syncEngine:(ODataSyncEngine *)engine didProgress:(ODataSyncProgress *)progress
{
  @synchronized (self) {
    [self.progress addObject:progress];
  }
}
- (void)syncEngine:(ODataSyncEngine *)engine didSetAside:(ODataSyncIssue *)issue
{
  [self.setAside addObject:issue];
}
- (void)syncEngine:(ODataSyncEngine *)engine ignoredLocalChangeToObject:(NSManagedObjectID *)objectID
{
  [self.ignored addObject:objectID];
}
@end

static NSAttributeDescription *OSTAttribute(NSString *name, NSAttributeType type, BOOL key)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = YES;
  attribute.preservesValueInHistoryOnDeletion = YES;
  if (key) attribute.userInfo = @{ @"OData.key": @"YES" };
  return attribute;
}

// Assets (down), Inspections (up, each of an asset), Tasks (both).
static NSManagedObjectModel *OSTModel(void)
{
  NSEntityDescription *asset = [[NSEntityDescription alloc] init];
  asset.name = @"Asset";
  asset.managedObjectClassName = @"NSManagedObject";
  asset.userInfo = @{ @"OData.entitySet": @"Assets", ODataSyncDirectionKey: @"down" };
  NSEntityDescription *inspection = [[NSEntityDescription alloc] init];
  inspection.name = @"Inspection";
  inspection.managedObjectClassName = @"NSManagedObject";
  inspection.userInfo = @{ @"OData.entitySet": @"Inspections", ODataSyncDirectionKey: @"up" };
  NSEntityDescription *task = [[NSEntityDescription alloc] init];
  task.name = @"Task";
  task.managedObjectClassName = @"NSManagedObject";
  task.userInfo = @{ @"OData.entitySet": @"Tasks", ODataSyncDirectionKey: @"both", ODataSyncModifiedKey: @"modified" };

  NSRelationshipDescription *ofAsset = [[NSRelationshipDescription alloc] init];
  ofAsset.name = @"asset";
  ofAsset.destinationEntity = asset;
  ofAsset.maxCount = 1;
  ofAsset.optional = YES;
  ofAsset.deleteRule = NSNullifyDeleteRule;
  NSRelationshipDescription *inspections = [[NSRelationshipDescription alloc] init];
  inspections.name = @"inspections";
  inspections.destinationEntity = inspection;
  inspections.maxCount = 0;
  inspections.optional = YES;
  inspections.deleteRule = NSNullifyDeleteRule;
  ofAsset.inverseRelationship = inspections;
  inspections.inverseRelationship = ofAsset;

  // The service's version counter: an ordered ETag.
  NSAttributeDescription *version = OSTAttribute(@"version", NSInteger64AttributeType, NO);
  version.userInfo = @{ @"OData.etag": @"YES" };
  asset.properties = @[ OSTAttribute(@"id", NSInteger32AttributeType, YES), OSTAttribute(@"name", NSStringAttributeType, NO),
                        OSTAttribute(@"region", NSStringAttributeType, NO), version, inspections ];
  inspection.properties = @[ OSTAttribute(@"id", NSStringAttributeType, YES), OSTAttribute(@"note", NSStringAttributeType, NO),
                             OSTAttribute(@"score", NSInteger32AttributeType, NO), ofAsset ];
  task.properties = @[ OSTAttribute(@"id", NSStringAttributeType, YES), OSTAttribute(@"title", NSStringAttributeType, NO),
                       OSTAttribute(@"done", NSBooleanAttributeType, NO), OSTAttribute(@"modified", NSStringAttributeType, NO) ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ asset, inspection, task ];
  return model;
}

@interface ODataSyncTests : XCTestCase
@end

@implementation ODataSyncTests {
  NSMutableArray<NSURL *> *_files;
  NSPersistentStoreCoordinator *_server;
  ODataService *_service;
  NSPersistentStoreCoordinator *_device;
  ODataSyncEngine *_engine;
  ODataSyncRemote *_remote;
  OSTDelegate *_delegate;
  NSMutableArray<ODataSyncPeerServer *> *_peerServers;
}

- (NSPersistentStoreCoordinator *)coordinatorWithModel:(NSManagedObjectModel *)model
{
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
  [_files addObject:url];
  NSError *error = nil;
  XCTAssertNotNil([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url
                                                  options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error], @"%@", error);
  return coordinator;
}

- (void)setUp
{
  _files = [NSMutableArray array];
  _peerServers = [NSMutableArray array];
  _server = [self coordinatorWithModel:OSTModel()];
  [self atServer:^(NSManagedObjectContext *context) {
    for (NSArray *a in @[ @[ @1, @"Pump", @"North" ], @[ @2, @"Valve", @"North" ], @[ @3, @"Boiler", @"South" ] ]) {
      NSManagedObject *asset = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
      [asset setValue:a[0] forKey:@"id"];
      [asset setValue:a[1] forKey:@"name"];
      [asset setValue:a[2] forKey:@"region"];
      [asset setValue:@1 forKey:@"version"];
    }
  }];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_server serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];

  NSManagedObjectModel *model = OSTModel();
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  _device = [self coordinatorWithModel:model];
  _engine = [[ODataSyncEngine alloc] initWithCoordinator:_device];
  _delegate = [[OSTDelegate alloc] init];
  _engine.delegate = _delegate;
  _remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  _remote.transport = _service;
  [_engine addRemote:_remote];
}

- (void)tearDown
{
  for (NSURL *url in _files) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
}

#pragma mark Helpers

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

- (void)atServer:(void (^)(NSManagedObjectContext *context))work
{
  [self in:_server do:work];
}

- (void)onDevice:(void (^)(NSManagedObjectContext *context))work
{
  [self in:_device do:work];
}

- (NSArray *)values:(NSString *)key of:(NSString *)entity in:(NSPersistentStoreCoordinator *)coordinator
{
  __block NSArray *values = nil;
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
    values = [[context executeFetchRequest:fetch error:NULL] valueForKey:key];
  }];
  return values;
}

- (NSManagedObject *)object:(NSString *)entity id:(id)identifier in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", identifier];
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

- (void)sync
{
  NSError *error = nil;
  XCTAssertTrue([_engine syncWithError:&error], @"%@", error);
}

- (NSString *)inspect:(NSString *)note asset:(NSNumber *)assetID
{
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [inspection setValue:identifier forKey:@"id"];
    [inspection setValue:note forKey:@"note"];
    [inspection setValue:@3 forKey:@"score"];
    if (assetID) [inspection setValue:[self object:@"Asset" id:assetID in:context] forKey:@"asset"];
  }];
  return identifier;
}

#pragma mark Down

// The bookkeeping is looked up an object at a time: each lookup indexed.
- (void)testTheBookkeepingIsIndexed
{
  NSDictionary *entities = _device.managedObjectModel.entitiesByName;
  NSDictionary *expected = @{ @"ODSShadow": @{ @"byObject": @[ @"remote", @"entityType", @"keyText" ] },
                              @"ODSOutboxEntry": @{ @"byObject": @[ @"remote", @"entityType", @"keyText" ], @"bySequence": @[ @"sequence" ] },
                              @"ODSTombstone": @{ @"byObject": @[ @"entityType", @"keyText" ], @"byDeleted": @[ @"deleted" ] },
                              // The app's synced entities, by their keys.
                              @"Asset": @{ @"ODataSyncKey": @[ @"id" ] }, @"Inspection": @{ @"ODataSyncKey": @[ @"id" ] },
                              @"Task": @{ @"ODataSyncKey": @[ @"id" ] } };
  for (NSString *name in expected) {
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    for (NSFetchIndexDescription *index in [entities[name] indexes]) {
      found[index.name] = [index.elements valueForKeyPath:@"property.name"];
    }
    XCTAssertEqualObjects(found, expected[name], @"%@", name);
  }
  // The store made with them takes what a sync writes.
  [self sync];
  XCTAssertEqual([self values:@"name" of:@"Asset" in:_device].count, 3u);

  // An app's own index that begins with the key is kept, and none added;
  // one that does not, the key's added beside it.
  NSManagedObjectModel *model = OSTModel();
  NSEntityDescription *task = model.entitiesByName[@"Task"], *asset = model.entitiesByName[@"Asset"];
  task.indexes = @[ [[NSFetchIndexDescription alloc] initWithName:@"byIDAndTitle" elements:@[
    [[NSFetchIndexElementDescription alloc] initWithProperty:task.attributesByName[@"id"] collationType:NSFetchIndexElementTypeBinary],
    [[NSFetchIndexElementDescription alloc] initWithProperty:task.attributesByName[@"title"] collationType:NSFetchIndexElementTypeBinary] ]] ];
  asset.indexes = @[ [[NSFetchIndexDescription alloc] initWithName:@"byRegion" elements:@[
    [[NSFetchIndexElementDescription alloc] initWithProperty:asset.attributesByName[@"region"] collationType:NSFetchIndexElementTypeBinary] ]] ];
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  XCTAssertEqualObjects([task.indexes valueForKey:@"name"], @[ @"byIDAndTitle" ]);
  XCTAssertEqualObjects([asset.indexes valueForKey:@"name"], (@[ @"byRegion", @"ODataSyncKey" ]));
}

// Many rows, a few at a time: pages read and batches sent, each saved and
// the context emptied between them (the outbox's index read again): all of
// them, read whole, sent, and changed and deleted by the delta link.
- (void)testManyRowsAFewAtATime
{
  _service.maxPageSize = 3;
  _remote.batchSize = 2;
  [self atServer:^(NSManagedObjectContext *context) {
    for (int i = 4; i <= 11; i++) {
      NSManagedObject *asset = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
      [asset setValue:@(i) forKey:@"id"];
      [asset setValue:[NSString stringWithFormat:@"Asset %d", i] forKey:@"name"];
      [asset setValue:@1 forKey:@"version"];
    }
  }];
  for (int i = 0; i < 11; i++) [self makeTask:[NSString stringWithFormat:@"Task %02d", i]];
  [self sync];
  XCTAssertEqual([self values:@"name" of:@"Asset" in:_device].count, 11u, @"read whole, in four pages");
  NSArray *titles = [[self values:@"title" of:@"Task" in:_server] sortedArrayUsingSelector:@selector(compare:)];
  XCTAssertEqual(titles.count, 11u, @"sent, in six batches: %@", titles);
  XCTAssertEqualObjects(titles.lastObject, @"Task 10");
  XCTAssertEqual(_engine.pendingChanges.count, 0u, @"%@", _engine.pendingChanges);
  ODataSyncProgress *last = nil;
  for (ODataSyncProgress *p in _delegate.progress) if (p.phase == ODataSyncPhaseSending) last = p;
  XCTAssertEqual(last.completed, 11u, @"%@", _delegate.progress);
  XCTAssertEqual(last.total, 11u);

  [self atServer:^(NSManagedObjectContext *context) {
    for (int i = 1; i <= 7; i++) {
      NSManagedObject *asset = [self object:@"Asset" id:@(i) in:context];
      [asset setValue:[NSString stringWithFormat:@"Renamed %d", i] forKey:@"name"];
      [asset setValue:@2 forKey:@"version"];
    }
    for (int i = 10; i <= 11; i++) [context deleteObject:[self object:@"Asset" id:@(i) in:context]];
  }];
  [self sync];
  NSArray *names = [self values:@"name" of:@"Asset" in:_device];
  XCTAssertEqual(names.count, 9u, @"two deleted, by the delta link's pages: %@", names);
  XCTAssertEqualObjects([names subarrayWithRange:NSMakeRange(0, 7)],
                        (@[ @"Renamed 1", @"Renamed 2", @"Renamed 3", @"Renamed 4", @"Renamed 5", @"Renamed 6", @"Renamed 7" ]));
  XCTAssertEqualObjects([names subarrayWithRange:NSMakeRange(7, 2)], (@[ @"Asset 8", @"Asset 9" ]));
  XCTAssertEqual(_engine.pendingChanges.count, 0u, @"%@", _engine.pendingChanges);
}

- (void)testDownloadWholeThenByDeltaLink
{
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Valve", @"Boiler" ]));
  XCTAssertEqual(_engine.lastResult.downloaded, 3u);

  [self atServer:^(NSManagedObjectContext *context) {
    [[self object:@"Asset" id:@1 in:context] setValue:@"Pump (new)" forKey:@"name"];
    [context deleteObject:[self object:@"Asset" id:@2 in:context]];
    NSManagedObject *added = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
    [added setValue:@4 forKey:@"id"];
    [added setValue:@"Fan" forKey:@"name"];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump (new)", @"Boiler", @"Fan" ]));
  XCTAssertEqual(_engine.lastResult.downloaded, 2u, @"only what changed: %@", _engine.lastResult);
  XCTAssertEqual(_engine.lastResult.removed, 1u);

  [self sync];
  XCTAssertEqual(_engine.lastResult.downloaded, 0u, @"nothing new: %@", _engine.lastResult);
}

- (void)testAnExpiredDeltaLinkReadsTheSetAgain
{
  [self sync];
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Asset" id:@3 in:context]];
  }];
  NSError *error = nil;
  XCTAssertTrue([_service pruneHistoryBeforeDate:[NSDate dateWithTimeIntervalSinceNow:1] error:&error], @"%@", error);
  [self sync];
  XCTAssertEqualObjects([self values:@"id" of:@"Asset" in:_device], (@[ @1, @2 ]), @"read again, and what is gone swept");
}

- (void)testFilteredSets
{
  _remote.filters = @{ @"Asset": @"Region eq 'North'" };
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Valve" ]));
  // Another filter: another set, read again.
  _remote.filters = @{ @"Asset": @"Region eq 'South'" };
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Boiler" ]));
}

// The remote's filter is $filter text, read as an expression: one that
// does not parse is the sync's error, not text sent as it is.
- (void)testAFilterThatDoesNotParse
{
  _remote.filters = @{ @"Asset": @"Region eq 'North') or (true" };
  NSError *error = nil;
  XCTAssertFalse([_engine syncWithError:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@", error);
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], @[]);
}

// A model's name that cannot be written (an OData.property that is no
// OData identifier): the sync's error, before anything is sent.
- (void)testNamesThatCannotBeWritten
{
  NSManagedObjectModel *model = OSTModel();
  NSEntityDescription *asset = model.entitiesByName[@"Asset"];  // typed: FreeCoreData's dictionaries are not
  NSAttributeDescription *name = asset.attributesByName[@"name"];
  name.userInfo = @{ @"OData.property": @"Name eq 0 or true" };
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  NSPersistentStoreCoordinator *device = [self coordinatorWithModel:model];
  ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:device];
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  remote.transport = _service;
  [engine addRemote:remote];
  NSError *error = nil;
  XCTAssertFalse([engine syncWithError:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorInvalidName, @"%@", error);
  XCTAssertTrue([error.localizedDescription containsString:@"Name eq 0 or true"], @"%@", error);
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:device], @[]);
}

- (void)testReconcilingKeys
{
  [self sync];
  // Here, a row the service has not (a down entity is not sent); and one
  // of its rows missing.
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *stray = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
    [stray setValue:@99 forKey:@"id"];
    [context deleteObject:[self object:@"Asset" id:@2 in:context]];
  }];
  NSError *error = nil;
  XCTAssertTrue([_engine reconcileWithRemote:_remote error:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"id" of:@"Asset" in:_device], (@[ @1, @2, @3 ]));
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Valve", @"Boiler" ]));
}

- (void)testLocalChangesToDownEntitiesAreNotSent
{
  [self sync];
  [self onDevice:^(NSManagedObjectContext *context) {
    [[self object:@"Asset" id:@1 in:context] setValue:@"Mine" forKey:@"name"];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_server].firstObject, @"Pump");
  XCTAssertEqual(_delegate.ignored.count, 1u);
}

#pragma mark Up

- (void)testAServiceReadsWhatAnOlderModelSends
{
  // The service is on version 2, which has every inspection scored; a
  // device on version 1 does not know scores, and one on 0 is too old.
  _service.modelVersion = @"2";
  __block NSString *seen = nil;
  __block NSString *entity = nil;
  _service.upgradeBody = ^NSDictionary *(NSDictionary *body, NSString *version, NSEntityDescription *written, ODataRequest *request,
                                         NSError **error) {
    seen = version;
    entity = written.name;
    if ([version isEqualToString:@"0"]) {
      *error = ODataServiceError(400, @"Update the app");
      return nil;
    }
    NSMutableDictionary *upgraded = [body mutableCopy];
    if (!upgraded[@"Score"] || upgraded[@"Score"] == [NSNull null]) upgraded[@"Score"] = @5;
    return upgraded;
  };
  _engine.modelVersion = @"1";
  NSString *inspection = [NSUUID UUID].UUIDString;
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *made = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [made setValue:inspection forKey:@"id"];
    [made setValue:@"Leaks" forKey:@"note"];
  }];
  [self sync];
  XCTAssertEqualObjects(seen, @"1");
  XCTAssertEqualObjects(entity, @"Inspection");
  XCTAssertEqualObjects([self values:@"score" of:@"Inspection" in:_server], (@[ @5 ]), @"the gap filled in");

  // Too old: refused, and set aside; after the app's update, sent again.
  _engine.modelVersion = @"0";
  [self onDevice:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:inspection in:context] setValue:@"Leaks badly" forKey:@"note"];
  }];
  [self sync];
  XCTAssertEqual([_engine issues].count, 1u);
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"Leaks" ]));
  _engine.modelVersion = @"2";
  seen = nil;
  [self sync];
  XCTAssertNil(seen, @"a client on the service's version is not upgraded");
  XCTAssertEqual([_engine issues].count, 0u, @"sent again after the update");
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"Leaks badly" ]));
}

- (void)testWhatWaitsToBeSent
{
  [_service setHandler:[[OSTPickyInspections alloc] initWithEntity:_server.managedObjectModel.entitiesByName[@"Inspection"]] forEntitySet:@"Inspections"];
  NSString *good = [self inspect:@"good" asset:nil];
  NSString *bad = [self inspect:@"bad" asset:nil];
  NSArray<ODataSyncChange *> *waiting = [_engine pendingChanges];
  XCTAssertEqual(waiting.count, 2u, @"what the app changed, read from history: %@", waiting);
  XCTAssertEqualObjects([NSSet setWithArray:[waiting valueForKeyPath:@"key.id"]], ([NSSet setWithObjects:good, bad, nil]));
  XCTAssertEqual(waiting.firstObject.operation, ODataSyncOperationInsert);
  XCTAssertNotNil(waiting.firstObject.objectID);
  [self sync];
  waiting = [_engine pendingChanges];
  XCTAssertEqual(waiting.count, 1u, @"the refused one stays: %@", waiting);
  XCTAssertTrue([waiting.firstObject isKindOfClass:[ODataSyncIssue class]], @"set aside");
  XCTAssertEqual(waiting.firstObject.attempts, 1);
}

- (void)testUploadByUpsert
{
  [self sync];
  NSString *first = [self inspect:@"Leaks" asset:@1];
  NSString *second = [self inspect:@"Fine" asset:@2];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 2u, @"%@", _engine.lastResult);
  XCTAssertEqualObjects([NSSet setWithArray:[self values:@"note" of:@"Inspection" in:_server]], ([NSSet setWithObjects:@"Leaks", @"Fine", nil]));
  __block NSString *assetName = nil;
  [self atServer:^(NSManagedObjectContext *context) {
    assetName = [[self object:@"Inspection" id:first in:context] valueForKeyPath:@"asset.name"];
  }];
  XCTAssertEqualObjects(assetName, @"Pump", @"bound to its asset");

  // Changed, then deleted.
  [self onDevice:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:first in:context] setValue:@"Leaks badly" forKey:@"note"];
    [context deleteObject:[self object:@"Inspection" id:second in:context]];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"Leaks badly" ]));

  // Made and gone before a sync: never sent.
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *fleeting = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [fleeting setValue:@"fleeting" forKey:@"id"];
    [context save:NULL];
    [context deleteObject:fleeting];
  }];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 0u, @"%@", _engine.lastResult);
}

// How far a sync is: each phase told as it begins, sending with what
// waits, and its last told when all is done (whatever the throttle).
- (void)testProgressIsToldAsASyncGoes
{
  [self sync];
  XCTAssertEqual(_delegate.progress.firstObject.phase, ODataSyncPhaseReceiving);
  XCTAssertEqual(_delegate.progress.firstObject.total, 0u, @"how much is to come is not known");
  XCTAssertTrue(_delegate.progress.firstObject.remote == _remote);
  for (NSUInteger i = 0; i < 120; i++) [self makeTask:[NSString stringWithFormat:@"Task %lu", (unsigned long)i]];
  [_delegate.progress removeAllObjects];
  [self sync];
  NSArray *phases = [_delegate.progress valueForKey:@"phase"];
  XCTAssertEqualObjects(phases.firstObject, @(ODataSyncPhaseReceiving));
  NSUInteger sending = [phases indexOfObject:@(ODataSyncPhaseSending)];
  XCTAssertNotEqual(sending, NSNotFound, @"%@", _delegate.progress);
  ODataSyncProgress *began = _delegate.progress[sending];
  XCTAssertEqual(began.completed, 0u);
  XCTAssertEqual(began.total, 120u);
  ODataSyncProgress *last = _delegate.progress.lastObject;
  XCTAssertEqual(last.phase, ODataSyncPhaseSending);
  XCTAssertEqual(last.completed, 120u, @"%@", _delegate.progress);
  XCTAssertEqual(last.total, 120u);
  for (ODataSyncProgress *p in [_delegate.progress subarrayWithRange:NSMakeRange(sending, _delegate.progress.count - sending)])
    XCTAssertLessThanOrEqual(p.completed, p.total);
}

- (void)testSendingAgainIsHarmless
{
  [self sync];
  [self inspect:@"Once" asset:@1];
  [self sync];
  // The engine forgets how far it got (a crash before it could save): it
  // sends everything again, which the upserts take as the same.
  [self onDevice:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"ODSRemoteState"];
    [[[context executeFetchRequest:fetch error:NULL] firstObject] setValue:nil forKey:@"historyToken"];
  }];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 1u, @"sent again: %@", _engine.lastResult);
  XCTAssertEqual([self values:@"id" of:@"Inspection" in:_server].count, 1u, @"one inspection, not two");
}

- (void)testRefusedChangesAreSetAside
{
  [_service setHandler:[[OSTPickyInspections alloc] initWithEntity:_server.managedObjectModel.entitiesByName[@"Inspection"]] forEntitySet:@"Inspections"];
  [self sync];
  NSString *bad = [self inspect:@"bad" asset:@1];
  [self inspect:@"good" asset:@2];
  [self sync];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"good" ]), @"the rest went");
  XCTAssertEqual(_engine.lastResult.refused, 1u);
  NSArray<ODataSyncIssue *> *issues = [_engine issues];
  XCTAssertEqual(issues.count, 1u);
  XCTAssertEqual(issues.firstObject.status, 400);
  XCTAssertEqualObjects(issues.firstObject.message, @"A note cannot be bad");
  XCTAssertNotNil(issues.firstObject.objectID);
  XCTAssertEqual(_delegate.setAside.count, 1u);

  // Not sent again by itself; put right, it is.
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 0u);
  [self onDevice:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:bad in:context] setValue:@"better" forKey:@"note"];
  }];
  [self sync];
  XCTAssertEqualObjects([NSSet setWithArray:[self values:@"note" of:@"Inspection" in:_server]], ([NSSet setWithObjects:@"good", @"better", nil]));
  XCTAssertEqual([_engine issues].count, 0u);
}

#pragma mark Both

- (NSString *)makeTask:(NSString *)title
{
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *task = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
    [task setValue:identifier forKey:@"id"];
    [task setValue:title forKey:@"title"];
  }];
  return identifier;
}

- (void)retitle:(NSString *)identifier to:(NSString *)title in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    [[self object:@"Task" id:identifier in:context] setValue:title forKey:@"title"];
  }];
}

- (void)testBothWaysWithoutConflict
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Check pump" ]));
  [self retitle:task to:@"Check pump (server)" in:_server];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Check pump (server)" ]), @"came down");
  [self retitle:task to:@"Check pump (device)" in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Check pump (device)" ]), @"went up");
  XCTAssertEqual(_engine.lastResult.conflicts, 0u);
}

- (void)testConflictTheRemoteWins
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self retitle:task to:@"Server's" in:_server];
  [self retitle:task to:@"Device's" in:_device];
  [self sync];
  XCTAssertGreaterThan(_engine.lastResult.conflicts, 0u);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Server's" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's" ]), @"the device's change dropped");
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Server's" ]), @"and not sent later");
}

- (void)testConflictTheDeviceWins
{
  _engine.conflictPolicy = ODataSyncPolicyLocalWins;
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self retitle:task to:@"Server's" in:_server];
  [self retitle:task to:@"Device's" in:_device];
  [self sync];
  XCTAssertGreaterThan(_engine.lastResult.conflicts, 0u);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Device's" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Device's" ]));
}

#pragma mark Conflicts

- (void)set:(NSDictionary *)values onTask:(NSString *)identifier in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSManagedObject *task = [self object:@"Task" id:identifier in:context];
    for (NSString *name in values) [task setValue:values[name] forKey:name];
  }];
}

- (void)testMergeFields
{
  _engine.resolver = [[ODataSyncMergeFields alloc] init];
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Check pump today" } onTask:task in:_server];
  [self set:@{ @"done": @YES } onTask:task in:_device];
  [self sync];
  XCTAssertEqual(_engine.lastResult.conflicts, 1u);
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:side], (@[ @"Check pump today" ]), @"the server's title");
    XCTAssertEqualObjects([self values:@"done" of:@"Task" in:side], (@[ @YES ]), @"the device's done");
  }

  // Both changed the title: the fallback (the remote) decides that one.
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's", @"done": @NO } onTask:task in:_device];
  [self sync];
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:side], (@[ @"Server's" ]));
    XCTAssertEqualObjects([self values:@"done" of:@"Task" in:side], (@[ @NO ]), @"what only the device changed still goes");
  }
}

- (void)testLastWriterWins
{
  [_engine setResolver:[[ODataSyncLastWriterWins alloc] init] forEntityName:@"Task"];
  NSString *task = [self makeTask:@"Check pump"];
  XCTAssertNotNil([self values:@"modified" of:@"Task" in:_device].firstObject, @"stamped when saved");
  [self sync];

  // The device changes it, then the service, later.
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  NSString *later = [NSString stringWithFormat:@"%016lld.0000.server00", (long long)([[NSDate date] timeIntervalSince1970] * 1000) + 60000];
  [self set:@{ @"title": @"Server's, later", @"modified": later } onTask:task in:_server];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's, later" ]));

  // The service, with a stamp from before; then the device: the device's stands.
  [self set:@{ @"title": @"Server's, earlier", @"modified": @"0000000000000001.0000.server00" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's, after" } onTask:task in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Device's, after" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Device's, after" ]));
  NSString *stamp = [self values:@"modified" of:@"Task" in:_device].firstObject;
  XCTAssertEqual([stamp compare:later], NSOrderedDescending, @"the clock went past what it saw: %@ after %@", stamp, later);
}

- (void)testCustomResolverAndTheConflictItSees
{
  OSTJoiningResolver *joining = [[OSTJoiningResolver alloc] init];
  [_engine setResolver:joining forEntityName:@"Task"];
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  [self sync];
  ODataSyncConflict *conflict = joining.last;
  XCTAssertEqualObjects(conflict.base[@"title"], @"Check pump", @"the version both had");
  XCTAssertEqualObjects(conflict.localChanges, ([NSSet setWithObjects:@"title", @"modified", nil]));
  XCTAssertEqualObjects(conflict.remoteChanges, [NSSet setWithObject:@"title"]);
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:side], (@[ @"Device's / Server's" ]));
  }
}

- (void)testDeferredConflictsAreIssues
{
  OSTJoiningResolver *deferring = [[OSTJoiningResolver alloc] init];
  deferring.defers = YES;
  [_engine setResolver:deferring forEntityName:@"Task"];
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  [self sync];
  NSArray<ODataSyncIssue *> *issues = [_engine issues];
  XCTAssertEqual(issues.count, 1u);
  XCTAssertEqual(issues.firstObject.status, 409);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Device's" ]), @"left as it was, for the user");

  // Retried: the device's goes over the server's.
  [_engine retryIssue:issues.firstObject];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Device's" ]));

  // Again, and given up: the server's comes back.
  [self set:@{ @"title": @"Server's again" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's again" } onTask:task in:_device];
  [self sync];
  [_engine discardIssue:[_engine issues].firstObject];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's again" ]));
  XCTAssertEqual([_engine issues].count, 0u);
}

- (void)testEditedHereDeletedThere
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Task" id:task in:context]];
  }];
  [self set:@{ @"title": @"Still needed" } onTask:task in:_device];
  [self sync];
  XCTAssertEqual([self values:@"id" of:@"Task" in:_device].count, 0u, @"the remote wins: gone here too");

  NSString *other = [self makeTask:@"Check valve"];
  [self sync];
  _engine.conflictPolicy = ODataSyncPolicyLocalWins;
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Task" id:other in:context]];
  }];
  [self set:@{ @"title": @"Still needed" } onTask:other in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Still needed" ]), @"the device wins: made again there");
}

- (void)testTheAgreedVersionReadAgainIsNoConflict
{
  // The delta link was made before this device's upload made the task: the
  // next read gives the task back, as agreed; the change made since stands.
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self retitle:task to:@"Check pump today" in:_device];
  [self sync];
  XCTAssertEqual(_engine.lastResult.conflicts, 0u, @"%@", _engine.lastResult);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Check pump today" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Check pump today" ]));
}

- (void)testAConflictMetOnUpload
{
  // Changed there after this side last read: met by the PATCH's If-Match (412).
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  NSError *error = nil;
  XCTAssertTrue([_engine uploadToRemote:_remote error:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Server's" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's" ]), @"the remote wins");
}

#pragma mark Peers

// Another device: its store and engine, with the service as a remote when asked.
- (ODataSyncEngine *)deviceWithService:(BOOL)service store:(NSPersistentStoreCoordinator **)store
{
  NSManagedObjectModel *model = OSTModel();
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  *store = [self coordinatorWithModel:model];
  ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:*store];
  if (service) {
    ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
    remote.transport = _service;
    [engine addRemote:remote];
  }
  return engine;
}

// The engine's store as a peer of the other's, in the process.
- (ODataSyncRemote *)peerOf:(ODataSyncEngine *)engine
{
  ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:engine host:@"peer.test" port:8642];
  [_peerServers addObject:server];
  ODataSyncRemote *peer = [ODataSyncRemote peerWithServiceRoot:server.serviceRoot];
  peer.transport = server.service;
  return peer;
}

- (void)sync:(ODataSyncEngine *)engine
{
  NSError *error = nil;
  XCTAssertTrue([engine syncWithError:&error], @"%@", error);
}

- (void)testAPeerCarriesInspectionsToTheService
{
  // The basement: a device that cannot reach the service.
  NSPersistentStoreCoordinator *basement = nil;
  ODataSyncEngine *offline = [self deviceWithService:NO store:&basement];
  ODataSyncRemote *peer = [self peerOf:offline];
  XCTAssertTrue(peer.peer);
  XCTAssertEqualObjects(peer.identifier, offline.replicaID, @"a peer's root names its replica");
  // This device reaches both: the peer first, then the service.
  NSPersistentStoreCoordinator *carrying = nil;
  ODataSyncEngine *carrier = [self deviceWithService:NO store:&carrying];
  _device = carrying;
  [carrier addRemote:peer];
  ODataSyncRemote *service = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  service.transport = _service;
  [carrier addRemote:service];

  NSString *identifier = [NSUUID UUID].UUIDString;
  [self in:basement do:^(NSManagedObjectContext *context) {
    NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [inspection setValue:identifier forKey:@"id"];
    [inspection setValue:@"Leaks" forKey:@"note"];
  }];
  [self sync:carrier];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_device], (@[ @"Leaks" ]), @"from the peer");
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"Leaks" ]), @"passed on to the service");
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Valve", @"Boiler" ]));
  [self sync:carrier];
  XCTAssertEqual(carrier.lastResult.uploaded, 0u, @"nothing sent back, nor again: %@", carrier.lastResult);
  XCTAssertEqual(carrier.lastResult.downloaded, 0u, @"%@", carrier.lastResult);

  // A change made there later comes the same way.
  [self in:basement do:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:identifier in:context] setValue:@"Leaks badly" forKey:@"note"];
  }];
  [self sync:carrier];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"Leaks badly" ]));
}

- (void)testTheServicesDataAndAPeersEditTravelOnce
{
  // This device reaches the service; the other only this one.
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  NSPersistentStoreCoordinator *other = nil;
  ODataSyncEngine *offline = [self deviceWithService:NO store:&other];
  [offline addRemote:[self peerOf:_engine]];
  [self sync:offline];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:other], (@[ @"Pump", @"Valve", @"Boiler" ]), @"the service's, from the peer");
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:other], (@[ @"Check pump" ]));

  [self retitle:task to:@"Check pump today" in:other];
  [self sync:offline];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Check pump today" ]), @"sent to the peer");
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Check pump today" ]), @"passed on to the service");

  // Nothing goes round again.
  [self sync:offline];
  XCTAssertEqual(offline.lastResult.uploaded + offline.lastResult.downloaded, 0u, @"%@", offline.lastResult);
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded + _engine.lastResult.downloaded, 0u, @"%@", _engine.lastResult);

  // The service's change reaches the other through this device.
  [self retitle:task to:@"Check pump (service)" in:_server];
  [self sync];
  [self sync:offline];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:other], (@[ @"Check pump (service)" ]));
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 0u, @"not sent back to the service: %@", _engine.lastResult);
}

- (void)testWhichDeletionsArePassedOn
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  NSPersistentStoreCoordinator *other = nil;
  ODataSyncEngine *offline = [self deviceWithService:NO store:&other];
  [offline addRemote:[self peerOf:_engine]];
  [self sync:offline];

  // The service's deletion is this device's to know; the peer's copy stays
  // until it hears from the service itself.
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Asset" id:@2 in:context]];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Boiler" ]));
  [self sync:offline];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:other], (@[ @"Pump", @"Valve", @"Boiler" ]), @"a peer deletes nothing");

  // The other's own deletion goes to the peer, which passes it on.
  [self in:other do:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Task" id:task in:context]];
  }];
  [self sync:offline];
  XCTAssertEqual([self values:@"title" of:@"Task" in:_device].count, 0u, @"deleted at the peer");
  [self sync];
  XCTAssertEqual([self values:@"title" of:@"Task" in:_server].count, 0u, @"passed on");
}

- (void)testLastWriterWinsAcrossPeers
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  NSPersistentStoreCoordinator *other = nil;
  ODataSyncEngine *offline = [self deviceWithService:NO store:&other];
  [offline addRemote:[self peerOf:_engine]];
  [offline setResolver:[[ODataSyncLastWriterWins alloc] init] forEntityName:@"Task"];
  [_engine setResolver:[[ODataSyncLastWriterWins alloc] init] forEntityName:@"Task"];
  [self sync:offline];

  [self retitle:task to:@"This device's" in:_device];
  [NSThread sleepForTimeInterval:0.01];
  [self retitle:task to:@"The other's, later" in:other];
  NSString *stamp = [self values:@"modified" of:@"Task" in:other].firstObject;
  [self sync:offline];
  XCTAssertGreaterThan(offline.lastResult.conflicts, 0u, @"%@", offline.lastResult);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:other], (@[ @"The other's, later" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"The other's, later" ]));
  XCTAssertEqualObjects([self values:@"modified" of:@"Task" in:_device].firstObject, stamp, @"its stamp kept by the peer");
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"The other's, later" ]), @"and passed on");
}

- (void)testAPeerServesTheSyncedSetsOnly
{
  ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:_engine host:@"peer.test" port:8642];
  NSString *metadata = [server.service metadataXMLForVersion:@"4.01"];
  XCTAssertTrue([metadata containsString:@"Name=\"Tasks\""], @"%@", metadata);
  XCTAssertTrue([metadata containsString:@"Name=\"Assets\""]);
  XCTAssertFalse([metadata containsString:@"ODSOutboxEntry"], @"bookkeeping is not served");
  XCTAssertFalse([metadata containsString:@"ODSShadow"]);
  NSString *path = [NSString stringWithFormat:@"/sync/%@/", _engine.replicaID];
  XCTAssertTrue([server.serviceRoot.absoluteString hasSuffix:path]);
  XCTAssertFalse([server.service handlerForEntitySet:@"Assets"].allowsInsert, @"down sets are read only");
  XCTAssertTrue([server.service handlerForEntitySet:@"Inspections"].allowsUpsert);
}

// A device that only reaches a peer: it syncs with that peer's server.
- (void)testAPeersDeletionIsPassedOn
{
  NSPersistentStoreCoordinator *basement = nil;
  ODataSyncEngine *offline = [self deviceWithService:NO store:&basement];
  [offline addRemote:[self peerOf:_engine]];
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self in:basement do:^(NSManagedObjectContext *context) {
    NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [inspection setValue:identifier forKey:@"id"];
    [inspection setValue:@"Leaks" forKey:@"note"];
  }];
  [self sync:offline];
  [self sync];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"Leaks" ]));

  // Deleted where it was made; this device passes the deletion on.
  [self in:basement do:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Inspection" id:identifier in:context]];
  }];
  [self sync:offline];
  XCTAssertEqual([self values:@"note" of:@"Inspection" in:_device].count, 0u);
  [self sync];
  XCTAssertEqual([self values:@"note" of:@"Inspection" in:_server].count, 0u, @"passed on to the service");
}

- (void)testARelayedChangeDoesNotBringBackWhatTheServiceDeleted
{
  NSPersistentStoreCoordinator *basement = nil;
  ODataSyncEngine *offline = [self deviceWithService:NO store:&basement];
  [offline addRemote:[self peerOf:_engine]];
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self in:basement do:^(NSManagedObjectContext *context) {
    NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [inspection setValue:identifier forKey:@"id"];
    [inspection setValue:@"Leaks" forKey:@"note"];
  }];
  [self sync:offline];
  [self sync];
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Inspection" id:identifier in:context]];
  }];
  // An edit made before the other device heard of the deletion, passed on later.
  [self in:basement do:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:identifier in:context] setValue:@"Leaks badly" forKey:@"note"];
  }];
  [self sync:offline];
  [self sync];
  XCTAssertEqual([self values:@"note" of:@"Inspection" in:_server].count, 0u, @"not made again by the upsert");
  XCTAssertEqual([self values:@"note" of:@"Inspection" in:_device].count, 0u, @"the service's deletion stands here");
  XCTAssertGreaterThan(_engine.lastResult.conflicts, 0u, @"%@", _engine.lastResult);
}

- (void)testANewerVersionOfTheServicesDataFromAPeer
{
  // This device read the service once; the other later.
  [self sync];
  [self atServer:^(NSManagedObjectContext *context) {
    NSManagedObject *pump = [self object:@"Asset" id:@1 in:context];
    [pump setValue:@"Pump (new)" forKey:@"name"];
    [pump setValue:@2 forKey:@"version"];
  }];
  NSPersistentStoreCoordinator *other = nil;
  ODataSyncEngine *later = [self deviceWithService:YES store:&other];
  [self sync:later];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:other], (@[ @"Pump (new)", @"Valve", @"Boiler" ]));

  // From the peer: the newer version replaces this device's older one.
  ODataSyncRemote *peer = [self peerOf:later];
  NSError *error = nil;
  XCTAssertTrue([_engine downloadFromRemote:peer error:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump (new)", @"Valve", @"Boiler" ]));

  // And an older version from a peer replaces nothing.
  [self atServer:^(NSManagedObjectContext *context) {
    NSManagedObject *pump = [self object:@"Asset" id:@1 in:context];
    [pump setValue:@"Pump (newest)" forKey:@"name"];
    [pump setValue:@3 forKey:@"version"];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device].firstObject, @"Pump (newest)");
  ODataSyncRemote *stale = [self peerOf:later];
  stale.identifier = @"another";  // read whole again, as a new peer
  XCTAssertTrue([_engine downloadFromRemote:stale error:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device].firstObject, @"Pump (newest)", @"the peer's is older");
}

// Two devices, each the other's peer.
- (NSArray<ODataSyncEngine *> *)twoPeers:(NSPersistentStoreCoordinator *__strong *)stores
{
  NSPersistentStoreCoordinator *first = nil, *second = nil;
  ODataSyncEngine *a = [self deviceWithService:NO store:&first];
  ODataSyncEngine *b = [self deviceWithService:NO store:&second];
  [a addRemote:[self peerOf:b]];
  [b addRemote:[self peerOf:a]];
  stores[0] = first;
  stores[1] = second;
  return @[ a, b ];
}

- (NSString *)inspect:(NSString *)note in:(NSPersistentStoreCoordinator *)store
{
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self in:store do:^(NSManagedObjectContext *context) {
    NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [inspection setValue:identifier forKey:@"id"];
    [inspection setValue:note forKey:@"note"];
  }];
  return identifier;
}

- (void)note:(NSString *)note on:(NSString *)inspection in:(NSPersistentStoreCoordinator *)store
{
  [self in:store do:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:inspection in:context] setValue:note forKey:@"note"];
  }];
}

- (void)testAChangeOfAVersionNeverAgreedOnDoesNotOverwriteUnseen
{
  // Pushed to the other, which never read it from this one: no version
  // agreed on there; its change must meet this one's, not overwrite it.
  NSPersistentStoreCoordinator *stores[2];
  NSArray<ODataSyncEngine *> *peers = [self twoPeers:stores];
  NSString *inspection = [self inspect:@"Leaks" in:stores[0]];
  NSError *error = nil;
  XCTAssertTrue([peers[0] uploadToRemote:peers[0].remotes.firstObject error:&error], @"%@", error);
  [self note:@"The other's" on:inspection in:stores[1]];
  [NSThread sleepForTimeInterval:0.01];
  [self note:@"This one's, later" on:inspection in:stores[0]];
  XCTAssertTrue([peers[1] uploadToRemote:peers[1].remotes.firstObject error:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:stores[0]], (@[ @"This one's, later" ]), @"not overwritten by an older change");
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:stores[1]], (@[ @"This one's, later" ]), @"the later one taken");
}

- (void)testPeersSettleTheSameWayWhicheverAsks
{
  // The default (the remote wins) would have each take the other's, for
  // ever; with a peer, the later change stands on both.
  NSPersistentStoreCoordinator *stores[2];
  NSArray<ODataSyncEngine *> *peers = [self twoPeers:stores];
  NSString *inspection = [self inspect:@"Leaks" in:stores[0]];
  [self sync:peers[0]];
  [self sync:peers[1]];
  [self note:@"First" on:inspection in:stores[0]];
  [NSThread sleepForTimeInterval:0.01];
  [self note:@"Second, later" on:inspection in:stores[1]];
  for (int round = 0; round < 2; round++) {
    [self sync:peers[0]];
    [self sync:peers[1]];
  }
  for (int side = 0; side < 2; side++) {
    XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:stores[side]], (@[ @"Second, later" ]));
    [self sync:peers[side]];
    ODataSyncResult *again = peers[side].lastResult;
    XCTAssertEqual(again.uploaded + again.downloaded + again.conflicts, 0u, @"settled: %@", again);
  }
}

- (void)testAPeerDoesNotBringBackWhatWasDeleted
{
  NSPersistentStoreCoordinator *stores[2];
  NSArray<ODataSyncEngine *> *peers = [self twoPeers:stores];
  NSString *inspection = [self inspect:@"Leaks" in:stores[0]];
  [self sync:peers[0]];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:stores[1]], (@[ @"Leaks" ]));
  // Deleted there; changed here, not knowing.
  [self in:stores[1] do:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Inspection" id:inspection in:context]];
  }];
  [self note:@"Leaks badly" on:inspection in:stores[0]];
  for (int round = 0; round < 2; round++) {
    [self sync:peers[0]];
    [self sync:peers[1]];
  }
  for (int side = 0; side < 2; side++) {
    XCTAssertEqual([self values:@"note" of:@"Inspection" in:stores[side]].count, 0u, @"deleted on both (side %d)", side);
    [self sync:peers[side]];
    ODataSyncResult *again = peers[side].lastResult;
    XCTAssertEqual(again.uploaded + again.downloaded + again.removed, 0u, @"settled: %@", again);
  }
}

@end
