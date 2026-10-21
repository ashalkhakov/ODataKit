// An offline store kept in sync with a service (docs/offline-sync.md): the
// engine against an ODataService in the process, each with a SQLite store
// of its own that keeps history.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <ODataSync/ODataSync.h>
#import <ODataService/ODataService.h>
#import <ODataKit/ODataError.h>
#import "OISCatalogModel.h"

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

// The service, with the requests sent to it counted; refusesCasts, it
// answers a read that expands behind a type cast (Default.FillUp/Unit) 501,
// as ODataKit's service did before 0.3.11.
@interface OSTCountingTransport : NSObject <ODataTransport>
@property (nonatomic, strong) ODataService *service;
@property (atomic, strong) NSMutableArray<NSURLRequest *> *requests;
@property (atomic) BOOL refusesCasts;
@end

@implementation OSTCountingTransport
- (void)startExchange:(ODataExchange *)exchange
{
  @synchronized (self) {
    if (!_requests) _requests = [NSMutableArray array];
    [_requests addObject:exchange.request];
  }
  NSString *query = exchange.request.URL.query.stringByRemovingPercentEncoding ?: @"";
  NSRange expand = [query rangeOfString:@"$expand="];
  if (self.refusesCasts && expand.location != NSNotFound && [[query substringFromIndex:expand.location] rangeOfString:@"Default.FillUp/"].location != NSNotFound) {
    exchange.URLResponse = [[NSHTTPURLResponse alloc] initWithURL:exchange.request.URL statusCode:501 HTTPVersion:@"HTTP/1.1"
                                                     headerFields:@{ @"Content-Type": @"application/json" }];
    exchange.data = [@"{\"error\":{\"code\":\"501\",\"message\":\"$expand=Default.FillUp/Unit is not supported\"}}"
        dataUsingEncoding:NSUTF8StringEncoding];
    [exchange finish];
    return;
  }
  [_service startExchange:exchange];
}
@end

// Keeps the version agreed on of the attachment, the rest as the remote
// has it: a resolver that names a file by the base's digest.
@interface OSTBaseAttachment : NSObject <ODataSyncResolving>
@end

@implementation OSTBaseAttachment
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  NSMutableDictionary *values = [conflict.remote mutableCopy];
  values[@"attachment"] = conflict.base[@"attachment"] ?: [NSNull null];
  return [ODataSyncResolution mergedValues:values];
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
                       OSTAttribute(@"done", NSBooleanAttributeType, NO), OSTAttribute(@"modified", NSStringAttributeType, NO),
                       OSTAttribute(@"attachment", NSBinaryDataAttributeType, NO) ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ asset, inspection, task ];
  return model;
}

// Records (both, with version vectors when asked, and a modified stamp)
// and fill-ups, a record of their own kind served in the Records set
// (OData.type names each type), each in a unit (down): a to-one of the
// sub-entity's own.
static NSManagedObjectModel *OSTRecordsModel(BOOL service, BOOL versions, BOOL stamped)
{
  NSEntityDescription *unit = [[NSEntityDescription alloc] init];
  unit.name = @"Unit";
  unit.managedObjectClassName = @"NSManagedObject";
  unit.userInfo = @{ @"OData.entitySet": @"Units", @"OData.type": @"Default.Unit", ODataSyncDirectionKey: @"down" };
  NSEntityDescription *record = [[NSEntityDescription alloc] init];
  record.name = @"Record";
  record.managedObjectClassName = @"NSManagedObject";
  NSMutableDictionary *info = [@{ @"OData.entitySet": @"Records", @"OData.type": @"Default.Record", ODataSyncDirectionKey: @"both" } mutableCopy];
  NSMutableArray *properties = [@[ OSTAttribute(@"id", NSStringAttributeType, YES), OSTAttribute(@"note", NSStringAttributeType, NO),
                                    OSTAttribute(@"amount", NSDecimalAttributeType, NO) ] mutableCopy];
  if (stamped) {
    info[ODataSyncModifiedKey] = @"modified";
    [properties addObject:OSTAttribute(@"modified", NSStringAttributeType, NO)];
  }
  if (versions) {
    info[ODataSyncVersionsKey] = @"versions";
    [properties addObject:OSTAttribute(@"versions", NSStringAttributeType, NO)];
  }
  record.userInfo = info;
  record.properties = properties;
  NSEntityDescription *fillUp = [[NSEntityDescription alloc] init];
  fillUp.name = @"FillUp";
  fillUp.managedObjectClassName = @"NSManagedObject";
  fillUp.userInfo = @{ @"OData.type": @"Default.FillUp" };

  NSRelationshipDescription *inUnit = [[NSRelationshipDescription alloc] init];
  inUnit.name = @"unit";
  inUnit.destinationEntity = unit;
  inUnit.maxCount = 1;
  inUnit.optional = YES;
  inUnit.deleteRule = NSNullifyDeleteRule;
  NSRelationshipDescription *fillUps = [[NSRelationshipDescription alloc] init];
  fillUps.name = @"fillUps";
  fillUps.destinationEntity = fillUp;
  fillUps.maxCount = 0;
  fillUps.optional = YES;
  fillUps.deleteRule = NSNullifyDeleteRule;
  inUnit.inverseRelationship = fillUps;
  fillUps.inverseRelationship = inUnit;

  unit.properties = @[ OSTAttribute(@"id", NSStringAttributeType, YES), fillUps ];
  fillUp.properties = @[ OSTAttribute(@"driver", NSStringAttributeType, NO), OSTAttribute(@"litres", NSDoubleAttributeType, NO), inUnit ];
  record.subentities = @[ fillUp ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ unit, record, fillUp ];
  if (service) [ODataSyncService addBookkeepingToModel:model configuration:nil];
  else [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  return model;
}

// Vehicles (both) keyed by a UUID attribute, and trucks among them.
static NSManagedObjectModel *OSTVehiclesModel(BOOL service)
{
  NSEntityDescription *vehicle = [[NSEntityDescription alloc] init];
  vehicle.name = @"Vehicle";
  vehicle.managedObjectClassName = @"NSManagedObject";
  vehicle.userInfo = @{ @"OData.entitySet": @"Vehicles", @"OData.type": @"Default.Vehicle", ODataSyncDirectionKey: @"both",
                        ODataSyncVersionsKey: @"versions", ODataSyncModifiedKey: @"modified" };
  vehicle.properties = @[ OSTAttribute(@"id", NSUUIDAttributeType, YES), OSTAttribute(@"name", NSStringAttributeType, NO),
                          OSTAttribute(@"versions", NSStringAttributeType, NO), OSTAttribute(@"modified", NSStringAttributeType, NO) ];
  NSEntityDescription *truck = [[NSEntityDescription alloc] init];
  truck.name = @"Truck";
  truck.managedObjectClassName = @"NSManagedObject";
  truck.userInfo = @{ @"OData.type": @"Default.Truck" };
  truck.properties = @[ OSTAttribute(@"axles", NSInteger32AttributeType, NO) ];
  vehicle.subentities = @[ truck ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ vehicle, truck ];
  if (service) [ODataSyncService addBookkeepingToModel:model configuration:nil];
  else [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  return model;
}

// Keeps this side's, and the conflict it saw.
@interface OSTKeepingResolver : NSObject <ODataSyncResolving>
@property (atomic, strong) ODataSyncConflict *last;
@end

@implementation OSTKeepingResolver
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  self.last = conflict;
  return [ODataSyncResolution keepLocal];
}
@end

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
  OSTCountingTransport *_records;
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

// The service named itself otherwise for a while (its host's own name, its
// root unset), and the delta links it gave then name that, which may never
// answer here: the set read again from the remote, not followed there.
- (void)testADeltaLinkElsewhereIsReadAgainFromTheRemote
{
  OSTCountingTransport *counting = [[OSTCountingTransport alloc] init];
  counting.service = _service;
  _remote.transport = counting;
  [self sync];
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *state = [[context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"ODSRemoteState"] error:NULL] firstObject];
    NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSString class], nil];
    NSDictionary *links = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:[state valueForKey:@"deltaLinks"] error:NULL];
    XCTAssertTrue(links.count > 0, @"links kept");
    NSMutableDictionary *elsewhere = [NSMutableDictionary dictionary];
    for (NSString *name in links)
      elsewhere[name] = [links[name] stringByReplacingOccurrencesOfString:@"http://example.test/" withString:@"http://ct100:8080/"];
    [state setValue:[NSKeyedArchiver archivedDataWithRootObject:elsewhere requiringSecureCoding:NO error:NULL] forKey:@"deltaLinks"];
  }];
  [self atServer:^(NSManagedObjectContext *context) {
    [[self object:@"Asset" id:@1 in:context] setValue:@"Pump, renamed" forKey:@"name"];
  }];
  counting.requests = [NSMutableArray array];
  [self sync];
  XCTAssertTrue([[self values:@"name" of:@"Asset" in:_device] containsObject:@"Pump, renamed"], @"read again");
  for (NSURLRequest *request in counting.requests)
    XCTAssertEqualObjects(request.URL.host, @"example.test", @"%@", request.URL);
}

// The downloader asks for pages of so many rows (a service may have no
// paging of its own), and follows them however the service cuts them: here
// a row a page, by the service's maxPageBytes, read whole and by delta link.
- (void)testTheDownloaderAsksForPagesAndFollowsThem
{
  OSTCountingTransport *counting = [[OSTCountingTransport alloc] init];
  counting.service = _service;
  _remote.transport = counting;
  _service.maxPageBytes = 1;
  [self atServer:^(NSManagedObjectContext *context) {
    for (int i = 4; i <= 9; i++) {
      NSManagedObject *asset = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
      [asset setValue:@(i) forKey:@"id"];
      [asset setValue:[NSString stringWithFormat:@"Asset %d", i] forKey:@"name"];
      [asset setValue:@1 forKey:@"version"];
    }
  }];
  [self sync];
  XCTAssertEqual([self values:@"name" of:@"Asset" in:_device].count, 9u, @"nine pages of one");
  for (NSURLRequest *request in counting.requests) {
    if (![request.HTTPMethod isEqualToString:@"GET"]) continue;
    XCTAssertTrue([[request valueForHTTPHeaderField:@"Prefer"] containsString:@"odata.maxpagesize=100"], @"%@: %@", request.URL,
                  [request valueForHTTPHeaderField:@"Prefer"]);
  }
  [self atServer:^(NSManagedObjectContext *context) {
    for (int i = 4; i <= 7; i++) [[self object:@"Asset" id:@(i) in:context] setValue:@"Renamed" forKey:@"name"];
  }];
  [self sync];
  NSArray *names = [self values:@"name" of:@"Asset" in:_device];
  XCTAssertEqual([[names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'Renamed'"]] count], 4u,
                 @"the delta, a row a page: %@", names);
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

// A batch keeps to the remote's batchBytes: rows with large values go in
// more batches, and one larger than the budget goes alone.
- (void)testABatchKeepsToItsBytes
{
  [self sync];
  OSTCountingTransport *counting = [[OSTCountingTransport alloc] init];
  counting.service = _service;
  _remote.transport = counting;
  _remote.batchBytes = 4000;
  NSString *large = [@"" stringByPaddingToLength:1000 withString:@"x" startingAtIndex:0];
  for (NSUInteger i = 0; i < 12; i++) [self makeTask:[large stringByAppendingFormat:@"%lu", (unsigned long)i]];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 12u, @"%@", _engine.lastResult);
  NSPredicate *batches = [NSPredicate predicateWithFormat:@"URL.path ENDSWITH '$batch'"];
  NSUInteger sent = [counting.requests filteredArrayUsingPredicate:batches].count;
  XCTAssertGreaterThanOrEqual(sent, 3u, @"twelve rows of 1 KB, in batches of 4 KB at most");
  XCTAssertLessThanOrEqual(sent, 6u);

  // What goes is within the budget, as sent: escapes counted (a slash is
  // two bytes, and base64 is full of them), and the batch's own JSON.
  [counting.requests removeAllObjects];
  _remote.batchBytes = 5000;
  NSString *slashes = [@"" stringByPaddingToLength:1000 withString:@"/" startingAtIndex:0];
  for (NSUInteger i = 0; i < 6; i++) [self makeTask:[slashes stringByAppendingFormat:@"%lu", (unsigned long)i]];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 6u, @"%@", _engine.lastResult);
  NSArray *sentBatches = [counting.requests filteredArrayUsingPredicate:batches];
  XCTAssertGreaterThanOrEqual(sentBatches.count, 3u, @"two rows of 2 KB as JSON to a batch, at most");
  for (NSURLRequest *batch in sentBatches) XCTAssertLessThanOrEqual(batch.HTTPBody.length, 5000u, @"a batch past its budget");

  _remote.batchBytes = 10;
  [counting.requests removeAllObjects];
  [self makeTask:large];
  [self makeTask:large];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 2u);
  XCTAssertEqual([counting.requests filteredArrayUsingPredicate:batches].count, 2u, @"each larger than the budget: alone");
}

// History folded into the outbox a few hundred changes at a time, saved
// and the context emptied between: within one transaction (an import
// saved at once) and across many, nothing lost, nothing left.
- (void)testHistoryIsFoldedAFewHundredAtATime
{
  [self sync];
  NSUInteger before = [self values:@"title" of:@"Task" in:_server].count;
  [self onDevice:^(NSManagedObjectContext *context) {
    for (NSUInteger i = 0; i < 600; i++) {
      NSManagedObject *task = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
      [task setValue:[NSUUID UUID].UUIDString forKey:@"id"];
      [task setValue:[NSString stringWithFormat:@"Imported %lu", (unsigned long)i] forKey:@"title"];
    }
  }];
  [self sync];
  XCTAssertEqual([self values:@"title" of:@"Task" in:_server].count, before + 600, @"one transaction of 600");
  XCTAssertEqual(_engine.pendingChanges.count, 0u, @"%@", _engine.pendingChanges);
  for (NSUInteger i = 0; i < 520; i++) [self makeTask:[NSString stringWithFormat:@"Made %lu", (unsigned long)i]];
  [self sync];
  XCTAssertEqual([self values:@"title" of:@"Task" in:_server].count, before + 1120, @"and 520 transactions of one");
  XCTAssertEqual(_engine.pendingChanges.count, 0u, @"%@", _engine.pendingChanges);
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 0u, @"nothing folded twice: %@", _engine.lastResult);
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

// A change whose key cannot be read back (kept by a Foundation that could
// write it, read by one that cannot): set aside with why, not dropped, and
// kept so through later syncs, and when it is retried.
- (void)testAChangeWhoseKeyCannotBeReadIsSetAside
{
  [self sync];
  NSString *unreadable = [self inspect:@"unreadable" asset:@1];
  [self inspect:@"good" asset:@2];
  XCTAssertEqual([_engine pendingChanges].count, 2u);
  __block NSUInteger spoilt = 0;
  [self onDevice:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"ODSOutboxEntry"];
    for (NSManagedObject *entry in [context executeFetchRequest:fetch error:NULL]) {
      if ([[entry valueForKey:@"keyText"] rangeOfString:unreadable].location == NSNotFound) continue;
      [entry setValue:[@"not an archive" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"key"];
      spoilt++;
    }
  }];
  XCTAssertEqual(spoilt, 1u);
  [self sync];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"good" ]), @"the rest went");
  XCTAssertEqual(_engine.lastResult.refused, 1u, @"%@", _engine.lastResult);
  NSArray<ODataSyncIssue *> *issues = [_engine issues];
  XCTAssertEqual(issues.count, 1u, @"%@", issues);
  XCTAssertEqualObjects(issues.firstObject.entityName, @"Inspection");
  XCTAssertTrue([issues.firstObject.message hasPrefix:@"The change's key could not be read"], @"%@", issues.firstObject.message);
  XCTAssertEqual(_delegate.setAside.count, 1u);

  // Kept through the next sync, and set aside again when retried.
  [self sync];
  XCTAssertEqual([_engine issues].count, 1u, @"not dropped");
  [_engine retryIssue:[_engine issues].firstObject];
  [self sync];
  XCTAssertEqual(_engine.lastResult.refused, 1u, @"%@", _engine.lastResult);
  XCTAssertEqual([_engine issues].count, 1u, @"not dropped when retried");
  XCTAssertEqual([_engine pendingChanges].count, 1u);
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

// A file in a row: the shadow keeps its digest, not the file (twice over,
// as base64); what each side changed is known all the same.
- (void)testAFileIsAgreedOnByItsDigest
{
  _engine.resolver = [[ODataSyncMergeFields alloc] init];
  NSMutableData *file = [NSMutableData dataWithLength:8192];
  for (NSUInteger i = 0; i < file.length; i++) ((uint8_t *)file.mutableBytes)[i] = (uint8_t)(i * 7);
  NSString *task = [self makeTask:@"Read the manual"];
  [self set:@{ @"attachment": file } onTask:task in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:_server], (@[ file ]));
  __block NSData *kept = nil;
  [self onDevice:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"ODSShadow"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"entityType == 'Task'"];
    kept = [[[context executeFetchRequest:fetch error:NULL] firstObject] valueForKey:@"values"];
  }];
  XCTAssertNotNil(kept);
  XCTAssertLessThan(kept.length, 1024u, @"the file's digest, not the file");
  XCTAssertTrue([[[NSString alloc] initWithData:kept encoding:NSUTF8StringEncoding] containsString:@"@odatasync.sha256"]);

  // The device changes the file, the server the title: both kept.
  NSMutableData *newer = [file mutableCopy];
  ((uint8_t *)newer.mutableBytes)[100] ^= 0xFF;
  [self set:@{ @"attachment": newer } onTask:task in:_device];
  [self set:@{ @"title": @"Read the manual, twice" } onTask:task in:_server];
  [self sync];
  XCTAssertEqual(_engine.lastResult.conflicts, 1u);
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:side], (@[ newer ]), @"the device's file");
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:side], (@[ @"Read the manual, twice" ]), @"the server's title");
  }

  // The other way round: the server's file, the device's done.
  [self set:@{ @"attachment": file } onTask:task in:_server];
  [self set:@{ @"done": @YES } onTask:task in:_device];
  [self sync];
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:side], (@[ file ]), @"the server's file");
    XCTAssertEqualObjects([self values:@"done" of:@"Task" in:side], (@[ @YES ]), @"the device's done");
  }
}

// A digest is equal to another of the same, not to data; whether data is
// its own, it says (and reads the data once, however often it is asked).
- (void)testADigestIsOfItsData
{
  NSMutableData *file = [NSMutableData dataWithLength:4096];
  ((uint8_t *)file.mutableBytes)[7] = 7;
  NSData *data = [file copy];
  ODataSyncDigest *digest = [ODataSyncDigest digestOfData:data], *again = [ODataSyncDigest digestOfData:data];
  XCTAssertEqualObjects(digest, again);
  XCTAssertEqual(digest.hash, again.hash);
  XCTAssertTrue([digest isDigestOfData:data]);
  XCTAssertFalse([digest isEqual:data], @"equal to digests only, as data is to data");
  XCTAssertFalse([data isEqual:digest]);
  ((uint8_t *)file.mutableBytes)[8] = 8;
  XCTAssertFalse([digest isDigestOfData:file]);
  XCTAssertFalse([digest isDigestOfData:[file subdataWithRange:NSMakeRange(0, 100)]]);
}

// A model to add the bookkeeping to, read from the compiled model itself
// (#46): editable, the caller's own each time (not a copy of a loaded one,
// which on Apple's Core Data can point into the original once that is
// freed), from a .momd or its .mom; the bookkeeping added in one call.
- (void)testAModelForTheBookkeepingIsReadFromTheCompiledModel
{
  NSURL *momd = OISCatalogModelURL();
  XCTAssertNotNil(momd);
  NSError *error = nil;
  NSManagedObjectModel *one = ODataSyncModelAtURL(momd, &error);
  NSManagedObjectModel *two = ODataSyncModelAtURL(momd, &error);
  XCTAssertNotNil(one, @"%@", error);
  XCTAssertNotNil(one.entitiesByName[@"Product"]);
  XCTAssertTrue(one != two, @"a fresh one each time");
  NSEntityDescription *product = one.entitiesByName[@"Product"];
  NSAttributeDescription *added = [[NSAttributeDescription alloc] init];
  added.name = @"versions";
  added.attributeType = NSStringAttributeType;
  added.optional = YES;
  product.properties = [product.properties arrayByAddingObject:added];
  NSEntityDescription *untouched = two.entitiesByName[@"Product"];
  XCTAssertNotNil(product.attributesByName[@"versions"], @"editable");
  XCTAssertNil(untouched.attributesByName[@"versions"], @"and its own");

  // The .mom inside, by name.
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[momd URLByAppendingPathComponent:@"VersionInfo.plist"]];
  NSString *current = info[@"NSManagedObjectModel_CurrentVersionName"];
  if (current) {
    NSURL *mom = [momd URLByAppendingPathComponent:[current stringByAppendingPathExtension:@"mom"]];
    NSManagedObjectModel *fromMom = ODataSyncModelAtURL(mom, &error);
    XCTAssertNotNil(fromMom.entitiesByName[@"Category"], @"%@", error);
  }

  NSManagedObjectModel *service = nil, *device = nil;
  @autoreleasepool {
    service = [ODataSyncService modelWithBookkeepingAtURL:momd configuration:nil error:&error];
    device = [ODataSyncEngine modelWithBookkeepingAtURL:momd configuration:nil error:&error];
    // Memory churned, as a server's start does.
    NSMutableArray *churn = [NSMutableArray array];
    for (NSUInteger i = 0; i < 20000; i++) [churn addObject:[NSString stringWithFormat:@"churn %lu", (unsigned long)i]];
  }
  XCTAssertNotNil(service.entitiesByName[@"ODSTombstone"], @"%@", error);
  XCTAssertNotNil(device.entitiesByName[@"ODSShadow"], @"%@", error);
  for (NSManagedObjectModel *model in @[ service, device ]) {
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    XCTAssertNotNil([coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error], @"%@", error);
  }

  // No model there.
  error = nil;
  XCTAssertNil(ODataSyncModelAtURL([NSURL fileURLWithPath:@"/nonexistent/Model.momd"], &error));
  XCTAssertEqualObjects(error.domain, ODataSyncErrorDomain);
  NSString *text = [NSTemporaryDirectory() stringByAppendingPathComponent:@"not-a-model.mom"];
  [@"not a model" writeToFile:text atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  XCTAssertNil(ODataSyncModelAtURL([NSURL fileURLWithPath:text], &error), @"a file that is not one");
  [[NSFileManager defaultManager] removeItemAtPath:text error:NULL];
}

// Files and images kept outside the store, by default: each synced
// entity's Binary attributes (a key's not, nor one the app keeps in its
// rows, ODataSync.external NO), on the device and at the service. A file
// past 128 KiB is then a file beside the SQLite store, not in its rows.
- (void)testSyncedFilesAreKeptOutsideTheStore
{
  NSManagedObjectModel *device = OSTModel();
  NSEntityDescription *asset = device.entitiesByName[@"Asset"];
  NSAttributeDescription *kept = [[NSAttributeDescription alloc] init];
  kept.name = @"thumbnail";
  kept.attributeType = NSBinaryDataAttributeType;
  kept.optional = YES;
  kept.userInfo = @{ ODataSyncExternalKey: @"NO" };
  asset.properties = [asset.properties arrayByAddingObject:kept];
  [ODataSyncEngine addBookkeepingToModel:device configuration:nil];
  NSAttributeDescription *attachment = [device.entitiesByName[@"Task"] attributesByName][@"attachment"];
  NSAttributeDescription *thumbnail = [device.entitiesByName[@"Asset"] attributesByName][@"thumbnail"];
  NSAttributeDescription *values = [device.entitiesByName[@"ODSShadow"] attributesByName][@"values"];
  XCTAssertTrue(attachment.allowsExternalBinaryDataStorage);
  XCTAssertFalse(thumbnail.allowsExternalBinaryDataStorage, @"kept in its rows");
  XCTAssertFalse(values.allowsExternalBinaryDataStorage, @"the bookkeeping is small");

  NSManagedObjectModel *service = OSTModel();
  NSEntityDescription *task = service.entitiesByName[@"Task"];
  NSAttributeDescription *versions = [[NSAttributeDescription alloc] init];
  versions.name = @"versions";
  versions.attributeType = NSStringAttributeType;
  versions.optional = YES;
  task.properties = [task.properties arrayByAddingObject:versions];
  NSMutableDictionary *info = [task.userInfo mutableCopy];
  info[ODataSyncVersionsKey] = @"versions";
  task.userInfo = info;
  [ODataSyncService addBookkeepingToModel:service configuration:nil];
  NSAttributeDescription *served = task.attributesByName[@"attachment"];
  XCTAssertTrue(served.allowsExternalBinaryDataStorage, @"at the service too");

  // A file of 512 KiB, synced down: a file beside the device's store.
  NSMutableData *file = [NSMutableData dataWithLength:512 * 1024];
  for (NSUInteger i = 0; i < file.length; i += 4096) ((uint8_t *)file.mutableBytes)[i] = (uint8_t)(i / 4096);
  NSString *identifier = [self makeTask:@"With a file"];
  [self set:@{ @"attachment": file } onTask:identifier in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:_server], (@[ file ]));
  NSPersistentStore *deviceStore = _device.persistentStores.firstObject;
  NSURL *store = deviceStore.URL;
  NSString *external = [[store.path stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:[NSString stringWithFormat:@".%@_SUPPORT/_EXTERNAL_DATA", store.lastPathComponent.stringByDeletingPathExtension]];
  NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:external error:NULL]
      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"NOT SELF BEGINSWITH '.'"]];
  XCTAssertGreaterThan(files.count, 0u, @"in %@", external);
  XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:_device], (@[ file ]), @"and read back whole");
}

// The same file saved again (an app that sets every field it shows) is
// no change: nothing stamped, nothing sent.
- (void)testTheSameFileSavedAgainSendsNothing
{
  NSMutableData *file = [NSMutableData dataWithLength:8192];
  for (NSUInteger i = 0; i < file.length; i++) ((uint8_t *)file.mutableBytes)[i] = (uint8_t)(i * 11);
  NSString *task = [self makeTask:@"Read the manual"];
  [self set:@{ @"attachment": file } onTask:task in:_device];
  [self sync];
  NSArray *stamped = [self values:@"modified" of:@"Task" in:_device];
  [self set:@{ @"attachment": [file copy], @"title": @"Read the manual" } onTask:task in:_device];
  XCTAssertEqualObjects([self values:@"modified" of:@"Task" in:_device], stamped, @"not stamped: nothing changed");
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 0u, @"%@", _engine.lastResult);
  XCTAssertEqual(_engine.pendingChanges.count, 0u, @"%@", _engine.pendingChanges);
}

// A resolution that names the attachment by the base's digest: the side
// whose bytes those are is written; when neither side has them any more,
// there is nothing to write, and the conflict is set aside.
- (void)testAResolutionThatKeepsTheBaseFile
{
  [_engine setResolver:[[OSTBaseAttachment alloc] init] forEntityName:@"Task"];
  NSMutableData *file = [NSMutableData dataWithLength:8192];
  for (NSUInteger i = 0; i < file.length; i++) ((uint8_t *)file.mutableBytes)[i] = (uint8_t)(i * 3);
  NSString *task = [self makeTask:@"Read the manual"];
  [self set:@{ @"attachment": file } onTask:task in:_device];
  [self sync];
  // The service changes the file, the device the title: the base's file is
  // the device's, kept.
  NSMutableData *theirs = [file mutableCopy];
  ((uint8_t *)theirs.mutableBytes)[10] ^= 0xFF;
  [self set:@{ @"attachment": theirs } onTask:task in:_server];
  [self set:@{ @"title": @"Read it" } onTask:task in:_device];
  [self sync];
  XCTAssertEqual(_engine.issues.count, 0u, @"%@", _engine.issues);
  XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:_device], (@[ file ]), @"the base's bytes, here");
  [self sync];
  XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:_server], (@[ file ]), @"and there");

  // Both change the file: the base's bytes are nowhere; set aside.
  NSMutableData *ours = [file mutableCopy], *again = [file mutableCopy];
  ((uint8_t *)ours.mutableBytes)[20] ^= 0xFF;
  ((uint8_t *)again.mutableBytes)[30] ^= 0xFF;
  [self set:@{ @"attachment": ours } onTask:task in:_device];
  [self set:@{ @"attachment": again } onTask:task in:_server];
  [self sync];
  XCTAssertEqual(_engine.issues.count, 1u, @"%@", _engine.issues);
  XCTAssertTrue([_engine.issues.firstObject.message containsString:@"digest"], @"%@", _engine.issues.firstObject.message);
  XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:_device], (@[ ours ]), @"nothing written over it");
}

// A late copy (a peer's, older than the version agreed on) of a row whose
// shadow keeps its file only as a digest: not sent, and not set from the
// shadow - read again from the service.
- (void)testALateCopyOfAFileIsReadAgain
{
  NSMutableData *file = [NSMutableData dataWithLength:8192];
  for (NSUInteger i = 0; i < file.length; i++) ((uint8_t *)file.mutableBytes)[i] = (uint8_t)(i * 5);
  NSString *task = [self makeTask:@"Read the manual"];
  [self set:@{ @"attachment": file } onTask:task in:_device];
  [self sync];
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = _device;
  if ([context respondsToSelector:@selector(setTransactionAuthor:)]) context.transactionAuthor = @"ODataSync.down.a-peer";
  [context performBlockAndWait:^{
    NSManagedObject *object = [self object:@"Task" id:task in:context];
    [object setValue:@"An older copy" forKey:@"title"];
    [object setValue:@"0000000000000001.0000.peer0000" forKey:@"modified"];
    NSError *error = nil;
    XCTAssertTrue([context save:&error], @"%@", error);
  }];
  [self sync];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Read the manual" ]), @"not sent over the newer");
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Read the manual" ]), @"read again");
  XCTAssertEqualObjects([self values:@"attachment" of:@"Task" in:_device], (@[ file ]), @"with its file");
  XCTAssertEqual(_engine.pendingChanges.count, 0u, @"%@", _engine.pendingChanges);
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

#pragma mark Derived types

// The entity and properties of the record with this key, or nil.
- (NSDictionary *)record:(NSString *)identifier in:(NSPersistentStoreCoordinator *)coordinator
{
  __block NSDictionary *found = nil;
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSManagedObject *record = [self object:@"Record" id:identifier in:context];
    if (!record) return;
    NSMutableDictionary *values = [[record dictionaryWithValuesForKeys:record.entity.attributesByName.allKeys] mutableCopy];
    values[@"entity"] = record.entity.name;
    found = values;
  }];
  return found;
}

// A fill-up made on a device: sent by upsert to the Records set, it is
// made a fill-up there (the body says its type), with its own properties;
// changed, the change follows. To a peer's server the same.
- (void)testADerivedTypeIsCreatedAsItself
{
  NSPersistentStoreCoordinator *server = [self coordinatorWithModel:OSTRecordsModel(YES, YES, NO)];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:server
                                                                       serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  ODataSyncService *syncing = [[ODataSyncService alloc] initWithService:service];
  XCTAssertNotNil(syncing);
  NSPersistentStoreCoordinator *device = [self coordinatorWithModel:OSTRecordsModel(NO, YES, NO)];
  ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:device];
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  remote.transport = service;
  [engine addRemote:remote];

  NSString *identifier = [NSUUID UUID].UUIDString;
  [self in:device do:^(NSManagedObjectContext *context) {
    NSManagedObject *fillUp = [NSEntityDescription insertNewObjectForEntityForName:@"FillUp" inManagedObjectContext:context];
    [fillUp setValue:identifier forKey:@"id"];
    [fillUp setValue:@"Full tank" forKey:@"note"];
    [fillUp setValue:@"Ann" forKey:@"driver"];
    [fillUp setValue:@41.5 forKey:@"litres"];
  }];
  [self sync:engine];
  XCTAssertEqual(engine.lastResult.uploaded, 1u, @"%@", engine.lastResult);
  NSDictionary *served = [self record:identifier in:server];
  XCTAssertEqualObjects(served[@"entity"], @"FillUp", @"%@", served);
  XCTAssertEqualObjects(served[@"driver"], @"Ann");
  XCTAssertEqualObjects(served[@"litres"], @41.5);
  XCTAssertEqualObjects(served[@"note"], @"Full tank");

  [self in:device do:^(NSManagedObjectContext *context) {
    [[self object:@"Record" id:identifier in:context] setValue:@"Bob" forKey:@"driver"];
  }];
  [self sync:engine];
  XCTAssertEqual(engine.lastResult.uploaded, 1u, @"%@", engine.lastResult);
  served = [self record:identifier in:server];
  XCTAssertEqualObjects(served[@"entity"], @"FillUp", @"%@", served);
  XCTAssertEqualObjects(served[@"driver"], @"Bob", @"the change followed");
  XCTAssertEqualObjects(served[@"litres"], @41.5);

  // Another device, that reaches only this one: its fill-up goes to this
  // device's peer server, and on to the service.
  NSPersistentStoreCoordinator *basement = [self coordinatorWithModel:OSTRecordsModel(NO, YES, NO)];
  ODataSyncEngine *offline = [[ODataSyncEngine alloc] initWithCoordinator:basement];
  [offline addRemote:[self peerOf:engine]];
  NSString *other = [NSUUID UUID].UUIDString;
  [self in:basement do:^(NSManagedObjectContext *context) {
    NSManagedObject *fillUp = [NSEntityDescription insertNewObjectForEntityForName:@"FillUp" inManagedObjectContext:context];
    [fillUp setValue:other forKey:@"id"];
    [fillUp setValue:@"Carol" forKey:@"driver"];
    [fillUp setValue:@12 forKey:@"litres"];
  }];
  [self sync:offline];
  XCTAssertEqual(offline.lastResult.uploaded, 1u, @"%@", offline.lastResult);
  NSDictionary *relayed = [self record:other in:device];
  XCTAssertEqualObjects(relayed[@"entity"], @"FillUp", @"%@", relayed);
  XCTAssertEqualObjects(relayed[@"driver"], @"Carol");
  [self in:basement do:^(NSManagedObjectContext *context) {
    [[self object:@"Record" id:other in:context] setValue:@"Dan" forKey:@"driver"];
  }];
  [self sync:offline];
  XCTAssertEqualObjects([self record:other in:device][@"driver"], @"Dan", @"the change followed");
  [self sync:engine];
  served = [self record:other in:server];
  XCTAssertEqualObjects(served[@"entity"], @"FillUp", @"%@", served);
  XCTAssertEqualObjects(served[@"driver"], @"Dan");
  XCTAssertEqualObjects(served[@"litres"], @12);
}

// A service and a device over the records model: the server's store, the
// device's, and the device's engine.
- (ODataSyncEngine *)recordsWithVersions:(BOOL)versions server:(NSPersistentStoreCoordinator **)server
                                  device:(NSPersistentStoreCoordinator **)device service:(ODataSyncService **)syncing
{
  return [self recordsWithVersions:versions stamped:NO server:server device:device service:syncing];
}

- (ODataSyncEngine *)recordsWithVersions:(BOOL)versions stamped:(BOOL)stamped server:(NSPersistentStoreCoordinator **)server
                                  device:(NSPersistentStoreCoordinator **)device service:(ODataSyncService **)syncing
{
  *server = [self coordinatorWithModel:OSTRecordsModel(YES, versions, stamped)];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:*server
                                                                       serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  *syncing = [[ODataSyncService alloc] initWithService:service];
  *device = [self coordinatorWithModel:OSTRecordsModel(NO, versions, stamped)];
  ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:*device];
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  _records = [[OSTCountingTransport alloc] init];
  _records.service = service;
  remote.transport = _records;
  [engine addRemote:remote];
  return engine;
}

- (void)fillUp:(NSString *)identifier driver:(NSString *)driver unit:(NSString *)unit in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSManagedObject *fillUp = [NSEntityDescription insertNewObjectForEntityForName:@"FillUp" inManagedObjectContext:context];
    [fillUp setValue:identifier forKey:@"id"];
    [fillUp setValue:driver forKey:@"driver"];
    [fillUp setValue:@30 forKey:@"litres"];
    if (unit) [fillUp setValue:[self object:@"Unit" id:unit in:context] forKey:@"unit"];
  }];
}

- (void)makeUnits:(NSArray<NSString *> *)units in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    for (NSString *identifier in units) {
      [[NSEntityDescription insertNewObjectForEntityForName:@"Unit" inManagedObjectContext:context] setValue:identifier forKey:@"id"];
    }
  }];
}

- (void)set:(id)value forKey:(NSString *)key ofRecord:(NSString *)identifier in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSManagedObject *record = [self object:@"Record" id:identifier in:context];
    [record setValue:[key isEqualToString:@"unit"] ? [self object:@"Unit" id:value in:context] : value forKey:key];
  }];
}

// The bodies of the PATCHes the device sent last (in its last $batch).
- (NSArray<NSDictionary *> *)lastPatches
{
  NSMutableArray *bodies = [NSMutableArray array];
  for (NSURLRequest *request in _records.requests.reverseObjectEnumerator) {
    if (![request.HTTPMethod isEqualToString:@"POST"] || ![request.URL.path hasSuffix:@"$batch"]) continue;
    NSDictionary *batch = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL];
    for (NSDictionary *item in batch[@"requests"]) {
      if ([item[@"method"] isEqualToString:@"PATCH"]) [bodies addObject:item[@"body"]];
    }
    break;
  }
  return bodies;
}

// The id of the unit of the record with this key.
- (NSString *)unitOf:(NSString *)identifier in:(NSPersistentStoreCoordinator *)coordinator
{
  __block NSString *unit = nil;
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    unit = [[self object:@"Record" id:identifier in:context] valueForKeyPath:@"unit.id"];
  }];
  return unit;
}

// A sub-entity's own to-one comes down with its row (expanded behind its
// type's cast): read whole, by a delta link, and from a peer.
- (void)testASubEntitysToOnesComeDown
{
  NSPersistentStoreCoordinator *server = nil, *device = nil;
  ODataSyncService *syncing = nil;
  ODataSyncEngine *engine = [self recordsWithVersions:YES server:&server device:&device service:&syncing];
  [self makeUnits:@[ @"L", @"gal" ] in:server];
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self fillUp:identifier driver:@"Ann" unit:@"L" in:server];
  [self sync:engine];
  NSDictionary *record = [self record:identifier in:device];
  XCTAssertEqualObjects(record[@"entity"], @"FillUp", @"%@", record);
  XCTAssertEqualObjects(record[@"driver"], @"Ann");
  XCTAssertEqualObjects([self unitOf:identifier in:device], @"L", @"its own to-one, read whole");

  [self set:@"gal" forKey:@"unit" ofRecord:identifier in:server];
  [self sync:engine];
  XCTAssertEqualObjects([self unitOf:identifier in:device], @"gal", @"by the delta link");
  [self set:@"Bea" forKey:@"driver" ofRecord:identifier in:server];
  [self sync:engine];
  XCTAssertEqualObjects([self record:identifier in:device][@"driver"], @"Bea");
  XCTAssertEqualObjects([self unitOf:identifier in:device], @"gal", @"kept when only another property changed");

  // From a peer: this device's server, to another device.
  NSPersistentStoreCoordinator *basement = [self coordinatorWithModel:OSTRecordsModel(NO, YES, NO)];
  ODataSyncEngine *offline = [[ODataSyncEngine alloc] initWithCoordinator:basement];
  [offline addRemote:[self peerOf:engine]];
  [self sync:offline];
  XCTAssertEqualObjects([self record:identifier in:basement][@"entity"], @"FillUp");
  XCTAssertEqualObjects([self unitOf:identifier in:basement], @"gal", @"from the peer");
}

// A service that takes no type cast in $expand (ODataKit's before 0.3.11):
// the sync goes on without them, as before them (a sub-entity's own to-ones
// do not come down), asked for once and then no more.
- (void)testASubEntitysToOnesFromAServiceThatTakesNoCast
{
  NSPersistentStoreCoordinator *server = nil, *device = nil;
  ODataSyncService *syncing = nil;
  ODataSyncEngine *engine = [self recordsWithVersions:YES server:&server device:&device service:&syncing];
  _records.refusesCasts = YES;
  [self makeUnits:@[ @"L" ] in:server];
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self fillUp:identifier driver:@"Ann" unit:@"L" in:server];
  [self sync:engine];
  NSDictionary *record = [self record:identifier in:device];
  XCTAssertEqualObjects(record[@"entity"], @"FillUp", @"%@", record);
  XCTAssertEqualObjects(record[@"driver"], @"Ann");
  [self set:@"Bea" forKey:@"driver" ofRecord:identifier in:server];
  [self sync:engine];
  XCTAssertEqualObjects([self record:identifier in:device][@"driver"], @"Bea", @"by the delta link");
  NSArray *urls = [[_records.requests valueForKeyPath:@"URL.query"] valueForKey:@"stringByRemovingPercentEncoding"];
  NSArray *casts = [urls filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS 'Default.FillUp/'"]];
  XCTAssertEqual(casts.count, 1u, @"refused once, then left out: %@", urls);
}

// A conflict of a sub-entity's object has its own properties, on each side
// and in what each changed; with nothing changed but what both did, the
// rest are no change (the version agreed on knows its type too).
- (void)testAConflictOfASubEntityHasItsProperties
{
  NSPersistentStoreCoordinator *server = nil, *device = nil;
  ODataSyncService *syncing = nil;
  ODataSyncEngine *engine = [self recordsWithVersions:NO server:&server device:&device service:&syncing];
  OSTKeepingResolver *keeping = [[OSTKeepingResolver alloc] init];
  [engine setResolver:keeping forEntityName:@"Record"];
  [self makeUnits:@[ @"L" ] in:server];
  [self sync:engine];
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self fillUp:identifier driver:@"Ann" unit:@"L" in:device];
  [self sync:engine];
  XCTAssertEqualObjects([self record:identifier in:server][@"entity"], @"FillUp");
  XCTAssertEqualObjects([self unitOf:identifier in:server], @"L");

  // Changed on both sides: a conflict.
  [self set:@"Server" forKey:@"driver" ofRecord:identifier in:server];
  [self set:@"Device" forKey:@"driver" ofRecord:identifier in:device];
  [self sync:engine];
  ODataSyncConflict *conflict = keeping.last;
  XCTAssertNotNil(conflict);
  XCTAssertEqualObjects(conflict.entity.name, @"FillUp");
  XCTAssertEqualObjects(conflict.base[@"driver"], @"Ann", @"%@", conflict.base);
  XCTAssertEqualObjects(conflict.local[@"driver"], @"Device", @"%@", conflict.local);
  XCTAssertEqualObjects(conflict.remote[@"driver"], @"Server", @"%@", conflict.remote);
  XCTAssertEqualObjects(conflict.remote[@"litres"], @30);
  XCTAssertEqualObjects(conflict.remote[@"unit"], @{ @"id": @"L" });
  XCTAssertEqualObjects(conflict.localChanges, [NSSet setWithObject:@"driver"]);
  XCTAssertEqualObjects(conflict.remoteChanges, [NSSet setWithObject:@"driver"]);
  XCTAssertEqualObjects([self record:identifier in:server][@"driver"], @"Device", @"this side's kept");
  XCTAssertEqualObjects([self unitOf:identifier in:server], @"L");

  // Changed here only, after a change there of another property: no conflict.
  keeping.last = nil;
  [self set:@40 forKey:@"litres" ofRecord:identifier in:server];
  [self sync:engine];
  XCTAssertEqualObjects([self record:identifier in:device][@"litres"], @40);
  XCTAssertEqualObjects([self unitOf:identifier in:device], @"L");
  [self set:@"Dee" forKey:@"driver" ofRecord:identifier in:device];
  [self sync:engine];
  XCTAssertNil(keeping.last, @"no conflict");
  XCTAssertEqualObjects([self lastPatches], (@[ @{ @"@odata.type": @"#Default.FillUp", @"Driver": @"Dee" } ]),
                        @"only what changed since the version agreed on");
  XCTAssertEqualObjects([self record:identifier in:server][@"driver"], @"Dee");
  XCTAssertEqualObjects([self record:identifier in:server][@"litres"], @40);
}

// Two devices, a fill-up each has: B's change of the note goes up; A
// changes it too, and takes the service's (its history now has a change
// that came to nothing); B's later change of the driver meets that
// version on its way up, and is no conflict with it: it goes up.
- (void)testAChangeMeetingOneThatCameToNothingGoesUp
{
  NSPersistentStoreCoordinator *server = nil, *b = nil;
  ODataSyncService *syncing = nil;
  ODataSyncEngine *engineB = [self recordsWithVersions:YES stamped:YES server:&server device:&b service:&syncing];
  OSTCountingTransport *toB = _records;
  NSPersistentStoreCoordinator *a = [self coordinatorWithModel:OSTRecordsModel(NO, YES, YES)];
  ODataSyncEngine *engineA = [[ODataSyncEngine alloc] initWithCoordinator:a];
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  remote.transport = toB.service;
  [engineA addRemote:remote];

  [self makeUnits:@[ @"L" ] in:server];
  [self sync:engineA];
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self fillUp:identifier driver:@"Ann" unit:@"L" in:a];
  [self set:[NSDecimalNumber decimalNumberWithString:@"68.4"] forKey:@"amount" ofRecord:identifier in:a];
  [self sync:engineA];
  [self sync:engineB];
  XCTAssertEqualObjects([self record:identifier in:b][@"entity"], @"FillUp");

  // 1. B changes the note (the root's), and sends it.
  [self set:@"Ben's note" forKey:@"note" ofRecord:identifier in:b];
  [self sync:engineB];
  XCTAssertEqualObjects([self record:identifier in:server][@"note"], @"Ben's note");
  // 2. A changes it too, offline; syncing, it takes the service's.
  [self set:@"Ann's note" forKey:@"note" ofRecord:identifier in:a];
  [self sync:engineA];
  XCTAssertEqualObjects([self record:identifier in:a][@"note"], @"Ben's note");
  // 3. B changes the driver (the fill-up's own), and sends it.
  [self set:@"Ben" forKey:@"driver" ofRecord:identifier in:b];
  [self sync:engineB];
  XCTAssertEqualObjects([self record:identifier in:server][@"driver"], @"Ben", @"%@", [self lastPatches]);
  [self sync:engineA];
  XCTAssertEqualObjects([self record:identifier in:a][@"driver"], @"Ben");
  // And once more, with nothing to download first.
  [self set:@"Bo" forKey:@"driver" ofRecord:identifier in:b];
  [self sync:engineB];
  XCTAssertEqualObjects([self record:identifier in:server][@"driver"], @"Bo", @"%@", [self lastPatches]);
}

// A decimal goes up as written and is kept so (68.4, not 68.40000000000001
// as a double read back has it): the next change sends only itself.
- (void)testADecimalIsKeptAsSent
{
  NSPersistentStoreCoordinator *server = nil, *device = nil;
  ODataSyncService *syncing = nil;
  ODataSyncEngine *engine = [self recordsWithVersions:YES server:&server device:&device service:&syncing];
  [self makeUnits:@[ @"L" ] in:server];
  [self sync:engine];
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self fillUp:identifier driver:@"Ann" unit:@"L" in:device];
  [self set:[NSDecimalNumber decimalNumberWithString:@"68.4"] forKey:@"amount" ofRecord:identifier in:device];
  [self sync:engine];
  XCTAssertEqualObjects([self record:identifier in:server][@"amount"], [NSDecimalNumber decimalNumberWithString:@"68.4"]);
  [self sync:engine];
  XCTAssertEqualObjects([self record:identifier in:device][@"amount"], [NSDecimalNumber decimalNumberWithString:@"68.4"]);
  [self set:@"Bea" forKey:@"driver" ofRecord:identifier in:device];
  [self sync:engine];
  NSDictionary *patch = [self lastPatches].firstObject;
  XCTAssertEqualObjects([NSSet setWithArray:patch.allKeys], ([NSSet setWithObjects:@"@odata.type", @"Driver", @"Versions", nil]), @"%@", patch);
}

// Objects keyed by a UUID, made on a device (one of a sub-entity): each
// waits to be sent, goes up, and reaches another device.
- (void)testObjectsKeyedByAUUIDGoUp
{
  NSPersistentStoreCoordinator *server = [self coordinatorWithModel:OSTVehiclesModel(YES)];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:server
                                                                       serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  ODataSyncService *syncing = [[ODataSyncService alloc] initWithService:service];
  XCTAssertNotNil(syncing);
  NSMutableArray<ODataSyncEngine *> *engines = [NSMutableArray array];
  NSMutableArray<NSPersistentStoreCoordinator *> *devices = [NSMutableArray array];
  for (NSUInteger i = 0; i < 2; i++) {
    NSPersistentStoreCoordinator *device = [self coordinatorWithModel:OSTVehiclesModel(NO)];
    ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:device];
    ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
    remote.transport = service;
    [engine addRemote:remote];
    [devices addObject:device];
    [engines addObject:engine];
  }
  [self sync:engines[0]];
  NSUUID *car = [NSUUID UUID], *truck = [NSUUID UUID];
  [self in:devices[0] do:^(NSManagedObjectContext *context) {
    NSManagedObject *one = [NSEntityDescription insertNewObjectForEntityForName:@"Vehicle" inManagedObjectContext:context];
    [one setValue:car forKey:@"id"];
    [one setValue:@"Car" forKey:@"name"];
    NSManagedObject *two = [NSEntityDescription insertNewObjectForEntityForName:@"Truck" inManagedObjectContext:context];
    [two setValue:truck forKey:@"id"];
    [two setValue:@"Truck" forKey:@"name"];
    [two setValue:@3 forKey:@"axles"];
  }];
  XCTAssertEqual([engines[0] pendingChanges].count, 2u, @"%@", [engines[0] pendingChanges]);
  [self sync:engines[0]];
  XCTAssertEqual(engines[0].lastResult.uploaded, 2u, @"%@", engines[0].lastResult);
  XCTAssertEqualObjects([NSSet setWithArray:[self values:@"name" of:@"Vehicle" in:server]], ([NSSet setWithObjects:@"Car", @"Truck", nil]));
  [self sync:engines[1]];
  XCTAssertEqualObjects([NSSet setWithArray:[self values:@"name" of:@"Vehicle" in:devices[1]]], ([NSSet setWithObjects:@"Car", @"Truck", nil]));
  XCTAssertEqualObjects([self values:@"axles" of:@"Truck" in:devices[1]], (@[ @3 ]));
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

#pragma mark - Signing in

// Kept in memory, as the Keychain would keep them.
@interface OSTMemorySecrets : NSObject <ODataSecretStoring>
@property (nonatomic, strong) NSMutableDictionary *all;
@end

@implementation OSTMemorySecrets
- (instancetype)init
{
  if ((self = [super init])) _all = [NSMutableDictionary dictionary];
  return self;
}
- (NSDictionary *)secretsForAccount:(NSString *)account { return _all[account]; }
- (BOOL)setSecrets:(NSDictionary *)secrets forAccount:(NSString *)account
{
  _all[account] = secrets;
  return YES;
}
@end

// The service and the identity provider, answering as they would (the
// provider as Keycloak does, with PKCE set on the client).
@interface OSTFakeSignIn : ODataSignIn
@property (nonatomic, strong) ODataService *service;
@property (nonatomic, copy) NSDictionary *key;
@property (atomic) NSInteger polls, refreshes;
// Token polls lost on the way (no answer: the connection lost), first.
@property (atomic) NSInteger lost;
@property (atomic, copy) NSString *challenge;
@end

@implementation OSTFakeSignIn

static NSString *OSTFormValue(NSString *form, NSString *name)
{
  for (NSString *pair in [form componentsSeparatedByString:@"&"]) {
    NSArray *kv = [pair componentsSeparatedByString:@"="];
    if (kv.count == 2 && [kv[0] isEqual:name]) return [kv[1] stringByRemovingPercentEncoding];
  }
  return nil;
}

- (NSString *)tokenFor:(NSString *)user
{
  NSTimeInterval now = [NSDate date].timeIntervalSince1970;
  return HSSignJWT(@{ @"iss": @"https://id.test", @"sub": user, @"preferred_username": user, @"iat": @((long)now), @"exp": @((long)now + 3600) },
                   _key, NULL);
}

- (void)send:(NSURLRequest *)request done:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))done
{
  NSString *url = request.URL.absoluteString;
  NSString *form = request.HTTPBody ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : @"";
  NSInteger status = 200;
  id json = nil;
  NSData *body = nil;
  if ([url hasSuffix:@"$metadata"]) {
    body = [[_service metadataXMLForVersion:@"4.01"] dataUsingEncoding:NSUTF8StringEncoding];
  } else if ([url hasSuffix:@"/.well-known/openid-configuration"]) {
    json = @{ @"issuer": @"https://id.test", @"device_authorization_endpoint": @"https://id.test/device", @"token_endpoint": @"https://id.test/token" };
  } else if ([url hasSuffix:@"/device"] && ![OSTFormValue(form, @"code_challenge_method") isEqual:@"S256"]) {
    status = 400;
    json = @{ @"error": @"invalid_request", @"error_description": @"Missing parameter: code_challenge_method" };
  } else if ([url hasSuffix:@"/device"]) {
    self.challenge = OSTFormValue(form, @"code_challenge");
    json = @{ @"device_code": @"dc-1", @"user_code": @"WDJB-MJHT", @"verification_uri": @"https://id.test/activate",
              @"verification_uri_complete": @"https://id.test/activate?user_code=WDJB-MJHT", @"interval": @0.05, @"expires_in": @60 };
  } else if ([url hasSuffix:@"/token"] && [form containsString:@"device_code"] && self.lost > 0) {
    self.lost--;
    NSError *cut = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost
                                   userInfo:@{ NSLocalizedDescriptionKey: @"The network connection was lost." }];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      done(nil, nil, cut);
    });
    return;
  } else if ([url hasSuffix:@"/token"] && [form containsString:@"device_code"]) {
    // Pending once (the user still signing in), then the tokens; for the
    // verifier of the challenge only.
    NSString *verifier = OSTFormValue(form, @"code_verifier");
    if (!verifier || ![ODataSignInChallengeOfVerifier(verifier) isEqual:self.challenge]) {
      status = 400;
      json = @{ @"error": @"invalid_grant", @"error_description": @"PKCE verification failed" };
    } else if (self.polls++ == 0) {
      status = 400;
      json = @{ @"error": @"authorization_pending" };
    } else {
      json = @{ @"access_token": [self tokenFor:@"alice"], @"refresh_token": @"refresh-1", @"id_token": [self tokenFor:@"alice"], @"expires_in": @300 };
    }
  } else if ([url hasSuffix:@"/token"] && [form containsString:@"refresh_token"]) {
    self.refreshes++;
    json = @{ @"access_token": [self tokenFor:@"alice"], @"refresh_token": @"refresh-2", @"expires_in": @300 };
  } else {
    status = 404;
  }
  if (json) body = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{}];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    done(body, response, nil);
  });
}

@end

// Signing in as the service's $metadata says to: what it asks for; the
// device flow (PKCE checked); the tokens kept, refreshed, and a sync signed
// in with them; and the system's secret store.
@interface ODataSignInTests : XCTestCase <ODataSignInDelegate>
@end

@implementation ODataSignInTests {
  NSMutableArray<NSURL *> *_files;
  NSPersistentStoreCoordinator *_server;
  ODataService *_service;
  NSDictionary *_key;
  NSString *_code;
  BOOL _learnt, _finished;
  NSError *_failed;
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
  _server = [self coordinatorWithModel:OSTModel()];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_server serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  NSError *error = nil;
  _key = HSGenerateSigningKey(&error);
  XCTAssertNotNil(_key, @"%@", error);
}

- (void)tearDown
{
  for (NSURL *url in _files) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
  }
}

// The service signs in with OpenID Connect, its $metadata to anyone.
- (void)signInWithOpenID
{
  HSJWTAuthenticator *jwt = [[HSJWTAuthenticator alloc] initWithIssuer:@"https://id.test" audience:nil];
  jwt.keySet = @{ @"keys": @[ HSPublicKey(_key) ] };
  _service.authenticator = jwt;
  _service.allowsAnonymousMetadata = YES;
}

- (OSTFakeSignIn *)signIn
{
  OSTFakeSignIn *signIn = [[OSTFakeSignIn alloc] initWithServiceRoot:_service.serviceRoot secrets:[[OSTMemorySecrets alloc] init]];
  signIn.service = _service;
  signIn.key = _key;
  signIn.clientID = @"workbench";
  signIn.delegate = self;
  return signIn;
}

- (void)waitFor:(BOOL (^)(void))done
{
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:10];
  while (!done() && !_failed && [until timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

- (void)signInDidLearn:(ODataSignIn *)signIn { _learnt = YES; }
- (void)signIn:(ODataSignIn *)signIn showCode:(NSString *)code page:(NSURL *)page completePage:(NSURL *)completePage { _code = code; }
- (void)signInDidFinish:(ODataSignIn *)signIn { _finished = YES; }
- (void)signIn:(ODataSignIn *)signIn didFail:(NSError *)error { _failed = error; }

- (void)testWhatTheServiceAsksForIsLearnt
{
  OSTFakeSignIn *none = [self signIn];
  [none learn];
  [self waitFor:^BOOL { return self->_learnt; }];
  XCTAssertEqual(none.kind, ODataSignInNone, @"no authenticator: no one asked for");
  [none begin];
  [self waitFor:^BOOL { return self->_finished; }];
  XCTAssertTrue(_finished && none.signedIn, @"nothing to sign in with: done at once");

  [self signInWithOpenID];
  _learnt = NO;
  OSTFakeSignIn *signIn = [self signIn];
  [signIn learn];
  [self waitFor:^BOOL { return self->_learnt; }];
  XCTAssertEqual(signIn.kind, ODataSignInOpenID);
  XCTAssertEqualObjects(signIn.issuer.absoluteString, @"https://id.test");
  XCTAssertFalse(signIn.signedIn);
}

// Polls lost on the way (iOS cuts them while the app waits behind the
// sign-in page): asked again, and signed in all the same.
- (void)testAPollLostOnTheWayIsAskedAgain
{
  [self signInWithOpenID];
  OSTFakeSignIn *signIn = [self signIn];
  signIn.lost = 2;
  [signIn begin];
  [self waitFor:^BOOL { return self->_finished || self->_failed; }];
  XCTAssertNil(_failed, @"%@", _failed);
  XCTAssertTrue(signIn.signedIn);
  XCTAssertEqual(signIn.lost, 0);
}

// The device flow: a code shown, the provider asked until the user has
// signed in (PKCE checked), the tokens kept; then a sync of a service that
// asks for a sign-in, with them.
- (void)testSigningInByTheDeviceFlowAndSyncing
{
  [self signInWithOpenID];
  OSTFakeSignIn *signIn = [self signIn];
  [signIn begin];
  [self waitFor:^BOOL { return self->_finished; }];
  XCTAssertNil(_failed);
  XCTAssertEqualObjects(_code, @"WDJB-MJHT");
  XCTAssertTrue(signIn.signedIn);
  XCTAssertEqualObjects(signIn.userName, @"alice");
  XCTAssertGreaterThanOrEqual(signIn.polls, 2, @"pending once, then the tokens");

  NSManagedObjectModel *model = OSTModel();
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:[self coordinatorWithModel:model]];
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:_service.serviceRoot];
  remote.transport = _service;
  remote.configuration = signIn.configuration;
  [engine addRemote:remote];
  NSError *error = nil;
  XCTAssertTrue([engine syncWithError:&error], @"signed in: %@", error);

  ODataSyncEngine *anonymous = [[ODataSyncEngine alloc] initWithCoordinator:[self coordinatorWithModel:model]];
  ODataSyncRemote *bare = [ODataSyncRemote remoteWithServiceRoot:_service.serviceRoot];
  bare.transport = _service;
  [anonymous addRemote:bare];
  XCTAssertFalse([anonymous syncWithError:&error], @"and not without it");
}

// A token run out is refreshed with the refresh token, once.
- (void)testAnExpiredTokenIsRefreshed
{
  [self signInWithOpenID];
  OSTMemorySecrets *secrets = [[OSTMemorySecrets alloc] init];
  OSTFakeSignIn *signIn = [[OSTFakeSignIn alloc] initWithServiceRoot:_service.serviceRoot secrets:secrets];
  signIn.service = _service;
  signIn.key = _key;
  signIn.clientID = @"workbench";
  signIn.delegate = self;
  [signIn begin];
  [self waitFor:^BOOL { return self->_finished; }];
  NSMutableDictionary *kept = [secrets.all[_service.serviceRoot.absoluteString] mutableCopy];
  kept[@"expires"] = @([NSDate date].timeIntervalSince1970 - 10);
  secrets.all[_service.serviceRoot.absoluteString] = kept;
  NSString *token = [signIn accessTokenForAuthorization:nil refresh:NO];
  XCTAssertTrue(token.length);
  XCTAssertEqual(signIn.refreshes, 1);
  XCTAssertEqualObjects(secrets.all[_service.serviceRoot.absoluteString][@"refresh"], @"refresh-2", @"the new refresh token kept");
}

- (void)testNoClientIDIsAnError
{
  [self signInWithOpenID];
  OSTFakeSignIn *signIn = [self signIn];
  signIn.clientID = nil;
  [signIn begin];
  [self waitFor:^BOOL { return NO; }];
  XCTAssertTrue([_failed.localizedDescription containsString:@"client"], @"%@", _failed);
}

// The system's store: the Keychain, or a file only the user can read.
- (void)testTheSystemKeepsSecrets
{
  ODataSecretStore *store = [[ODataSecretStore alloc] initWithServiceName:[@"ODataKit tests " stringByAppendingString:[NSUUID UUID].UUIDString]];
  XCTAssertNil([store secretsForAccount:@"http://example.test/"]);
  XCTAssertTrue([store setSecrets:@{ @"refresh": @"r-1" } forAccount:@"http://example.test/"]);
  XCTAssertEqualObjects([store secretsForAccount:@"http://example.test/"], @{ @"refresh": @"r-1" });
  XCTAssertTrue([store setSecrets:nil forAccount:@"http://example.test/"]);
  XCTAssertNil([store secretsForAccount:@"http://example.test/"]);
}

@end
