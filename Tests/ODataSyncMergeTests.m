// Merged attributes (docs/offline-sync.md, 14): a Binary attribute whose
// value is a mergeable state, exchanged as deltas through MergeAttributes,
// never in a row; what every replica has seen collected. Devices and a
// service with ODataSync's part, in the process, each with a SQLite store.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <ODataSync/ODataSync.h>
#import <ODataService/ODataService.h>
#import <ODataIncrementalStore/ODataClient.h>
#import <ODataIncrementalStore/ODataConfiguration.h>

// A two-phase set, as the tests' mergeable state: {"add": [...], "del": [...]},
// an element there when added and not deleted. Its version is the state
// itself; a delta, what a version lacks; a meet, what both have; collecting
// forgets an element deleted where every copy has seen it deleted.
@interface OSMTwoPhaseSet : NSObject <ODataSyncMerging>
@property (atomic) NSUInteger collections;
+ (NSData *)stateAdding:(NSArray *)add deleting:(NSArray *)del;
+ (NSDictionary *)setsOf:(NSData *)state;
+ (NSArray *)elementsOf:(NSData *)state;
@end

@implementation OSMTwoPhaseSet

+ (NSData *)stateAdding:(NSArray *)add deleting:(NSArray *)del
{
  NSArray *a = [[NSSet setWithArray:add].allObjects sortedArrayUsingSelector:@selector(compare:)];
  NSArray *d = [[NSSet setWithArray:del].allObjects sortedArrayUsingSelector:@selector(compare:)];
  return [NSJSONSerialization dataWithJSONObject:@{ @"add": a, @"del": d } options:NSJSONWritingSortedKeys error:NULL];
}

+ (NSDictionary *)setsOf:(NSData *)state
{
  NSDictionary *json = state.length ? [NSJSONSerialization JSONObjectWithData:state options:0 error:NULL] : nil;
  return @{ @"add": [NSSet setWithArray:json[@"add"] ?: @[]], @"del": [NSSet setWithArray:json[@"del"] ?: @[]] };
}

+ (NSArray *)elementsOf:(NSData *)state
{
  NSDictionary *sets = [self setsOf:state];
  NSMutableSet *there = [sets[@"add"] mutableCopy];
  [there minusSet:sets[@"del"]];
  return [there.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (NSData *)versionOfState:(NSData *)state
{
  NSDictionary *s = [OSMTwoPhaseSet setsOf:state];
  return [OSMTwoPhaseSet stateAdding:[s[@"add"] allObjects] deleting:[s[@"del"] allObjects]];
}

- (NSData *)deltaOfState:(NSData *)state sinceVersion:(NSData *)version
{
  NSDictionary *s = [OSMTwoPhaseSet setsOf:state], *v = [OSMTwoPhaseSet setsOf:version];
  NSMutableSet *add = [s[@"add"] mutableCopy], *del = [s[@"del"] mutableCopy];
  [add minusSet:v[@"add"]];
  [del minusSet:v[@"del"]];
  if (!add.count && !del.count) return [NSData data];
  return [OSMTwoPhaseSet stateAdding:add.allObjects deleting:del.allObjects];
}

- (NSData *)stateByMerging:(NSData *)delta intoState:(NSData *)state error:(NSError **)error
{
  id json = [NSJSONSerialization JSONObjectWithData:delta options:0 error:NULL];
  if (![json isKindOfClass:[NSDictionary class]]) {
    if (error) *error = [NSError errorWithDomain:@"OSM" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"not a set" }];
    return nil;
  }
  NSDictionary *s = [OSMTwoPhaseSet setsOf:state], *d = [OSMTwoPhaseSet setsOf:delta];
  return [OSMTwoPhaseSet stateAdding:[[s[@"add"] setByAddingObjectsFromSet:d[@"add"]] allObjects]
                            deleting:[[s[@"del"] setByAddingObjectsFromSet:d[@"del"]] allObjects]];
}

- (NSData *)versionMeeting:(NSData *)version andVersion:(NSData *)other
{
  NSDictionary *a = [OSMTwoPhaseSet setsOf:version], *b = [OSMTwoPhaseSet setsOf:other];
  NSMutableSet *add = [a[@"add"] mutableCopy], *del = [a[@"del"] mutableCopy];
  [add intersectSet:b[@"add"]];
  [del intersectSet:b[@"del"]];
  return [OSMTwoPhaseSet stateAdding:add.allObjects deleting:del.allObjects];
}

// The title, what the body's elements are (as a note's title is its text's
// first line): set again after a merge.
- (void)mergedAttribute:(NSAttributeDescription *)attribute ofObject:(NSManagedObject *)object
{
  [object setValue:[[OSMTwoPhaseSet elementsOf:[object valueForKey:attribute.name]] componentsJoinedByString:@" "] forKey:@"title"];
}

- (NSData *)stateByCollecting:(NSData *)state seenBy:(NSData *)version
{
  NSDictionary *s = [OSMTwoPhaseSet setsOf:state], *v = [OSMTwoPhaseSet setsOf:version];
  NSMutableSet *gone = [s[@"del"] mutableCopy];
  [gone intersectSet:v[@"del"]];
  if (!gone.count) return state;
  self.collections++;
  NSMutableSet *add = [s[@"add"] mutableCopy], *del = [s[@"del"] mutableCopy];
  [add minusSet:gone];
  [del minusSet:gone];
  return [OSMTwoPhaseSet stateAdding:add.allObjects deleting:del.allObjects];
}

@end

// The service in the process, each request noted (its method, URL and body).
@interface OSMRecordingTransport : NSObject <ODataTransport>
- (instancetype)initWithService:(ODataService *)service;
@property (atomic, strong) NSMutableArray<NSURLRequest *> *requests;
@end

@implementation OSMRecordingTransport {
  ODataService *_service;
}

- (instancetype)initWithService:(ODataService *)service
{
  self = [super init];
  _service = service;
  _requests = [NSMutableArray array];
  return self;
}

- (void)startExchange:(ODataExchange *)exchange
{
  @synchronized (self) {
    [_requests addObject:exchange.request];
  }
  [_service startExchange:exchange];
}

@end

static NSAttributeDescription *OSMAttribute(NSString *name, NSAttributeType type, NSDictionary *userInfo)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = YES;
  attribute.preservesValueInHistoryOnDeletion = YES;
  attribute.userInfo = userInfo ?: @{};
  return attribute;
}

// Docs (both): a title, and a merged body (a two-phase set).
static NSManagedObjectModel *OSMModel(void)
{
  NSEntityDescription *doc = [[NSEntityDescription alloc] init];
  doc.name = @"Doc";
  doc.managedObjectClassName = @"NSManagedObject";
  doc.userInfo = @{ @"OData.entitySet": @"Docs", ODataSyncDirectionKey: @"both", ODataSyncModifiedKey: @"modified",
                    ODataSyncVersionsKey: @"versions" };
  doc.properties = @[ OSMAttribute(@"id", NSStringAttributeType, @{ @"OData.key": @"YES" }), OSMAttribute(@"title", NSStringAttributeType, nil),
                      OSMAttribute(@"body", NSBinaryDataAttributeType, @{ ODataSyncMergeKey: @"TwoPhase" }),
                      OSMAttribute(@"modified", NSStringAttributeType, nil), OSMAttribute(@"versions", NSStringAttributeType, nil) ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ doc ];
  return model;
}

@interface ODataSyncMergeTests : XCTestCase
@end

@implementation ODataSyncMergeTests {
  NSMutableArray<NSURL *> *_files;
  NSPersistentStoreCoordinator *_server;
  ODataService *_service;
  ODataSyncService *_sync;
  OSMTwoPhaseSet *_merger;
  OSMRecordingTransport *_transport;
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
  _merger = [[OSMTwoPhaseSet alloc] init];
  NSManagedObjectModel *model = OSMModel();
  [ODataSyncService addBookkeepingToModel:model configuration:nil];
  _server = [self coordinatorWithModel:model];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_server serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  _service.allowsAnonymousRequests = YES;
  _sync = [[ODataSyncService alloc] initWithService:_service];
  [_sync.engine setMerger:_merger forName:@"TwoPhase"];
  XCTAssertEqualObjects(_service.operationProblems, @[]);
  XCTAssertTrue([[_service metadataXMLForVersion:@"4.01"] containsString:@"MergeAttributes"], @"declared");
  _transport = [[OSMRecordingTransport alloc] initWithService:_service];
}

- (void)tearDown
{
  for (NSURL *url in _files) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
}

- (ODataSyncEngine *)device
{
  NSManagedObjectModel *model = OSMModel();
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:[self coordinatorWithModel:model]];
  [engine setMerger:_merger forName:@"TwoPhase"];
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:_service.serviceRoot];
  remote.transport = _transport;
  [engine addRemote:remote];
  return engine;
}

- (void)sync:(ODataSyncEngine *)engine
{
  NSError *error = nil;
  XCTAssertTrue([engine syncWithError:&error], @"%@", error);
  XCTAssertEqual(engine.issues.count, 0u, @"%@", engine.issues);
}

- (void)in:(NSPersistentStoreCoordinator *)coordinator do:(void (^)(NSManagedObjectContext *context))work
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  [context performBlockAndWait:^{
    work(context);
    NSError *error = nil;
    XCTAssertTrue(!context.hasChanges || [context save:&error], @"%@", error);
  }];
}

- (NSManagedObject *)doc:(NSString *)identifier in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Doc"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", identifier];
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

// The body's elements, here.
- (NSArray *)elementsOf:(NSString *)identifier in:(NSPersistentStoreCoordinator *)coordinator
{
  __block NSArray *elements = nil;
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    elements = [OSMTwoPhaseSet elementsOf:[[self doc:identifier in:context] valueForKey:@"body"]];
  }];
  return elements;
}

- (NSData *)stateOf:(NSString *)identifier in:(NSPersistentStoreCoordinator *)coordinator
{
  __block NSData *state = nil;
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    state = [[self doc:identifier in:context] valueForKey:@"body"];
  }];
  return state;
}

// Elements added to (and deleted from) the body, as an editor writes it.
- (void)edit:(NSString *)identifier in:(ODataSyncEngine *)engine adding:(NSArray *)add deleting:(NSArray *)del
{
  [self in:engine.coordinator do:^(NSManagedObjectContext *context) {
    NSManagedObject *doc = [self doc:identifier in:context];
    if (!doc) {
      doc = [NSEntityDescription insertNewObjectForEntityForName:@"Doc" inManagedObjectContext:context];
      [doc setValue:identifier forKey:@"id"];
      [doc setValue:@"A doc" forKey:@"title"];
    }
    NSDictionary *s = [OSMTwoPhaseSet setsOf:[doc valueForKey:@"body"]];
    [doc setValue:[OSMTwoPhaseSet stateAdding:[[s[@"add"] setByAddingObjectsFromArray:add] allObjects]
                                     deleting:[[s[@"del"] setByAddingObjectsFromArray:del ?: @[]] allObjects]]
           forKey:@"body"];
  }];
}

// A request to the service as any client sends it: its answer, or nil and
// the error.
- (ODataHTTPResponse *)send:(NSString *)method to:(NSString *)path JSON:(id)body error:(NSError **)error
{
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:[[ODataConfiguration alloc] initWithURL:_service.serviceRoot options:nil]];
  client.transport = _service;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:path relativeToURL:_service.serviceRoot].absoluteURL];
  request.HTTPMethod = method;
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  return [client sendRequest:request error:error];
}

// What was sent: each request's body, as text, of those to this path.
- (NSArray<NSString *> *)bodiesSentTo:(NSString *)path method:(NSString *)method
{
  NSMutableArray *bodies = [NSMutableArray array];
  for (NSURLRequest *request in _transport.requests) {
    if (![request.HTTPMethod isEqualToString:method] || ![request.URL.path containsString:path]) continue;
    [bodies addObject:request.HTTPBody ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : @""];
  }
  return bodies;
}

// Two devices, each adding to the body offline: both keep all of it, and the
// rows go without it, the deltas through MergeAttributes.
- (void)testEditsMadeApartAreMergedAsDeltas
{
  ODataSyncEngine *a = [self device], *b = [self device];
  [self edit:@"d1" in:a adding:@[ @"apple" ] deleting:nil];
  [self sync:a];
  [self sync:b];
  XCTAssertEqualObjects([self elementsOf:@"d1" in:b.coordinator], (@[ @"apple" ]), @"the other device has it");

  [self edit:@"d1" in:a adding:@[ @"banana" ] deleting:nil];
  [self edit:@"d1" in:b adding:@[ @"cherry" ] deleting:nil];
  XCTAssertEqual(a.pendingChanges.count, 1u, @"one change waiting: its row's and its body's, one: %@", a.pendingChanges);
  [self sync:a];
  XCTAssertEqual(a.pendingChanges.count, 0u, @"%@", a.pendingChanges);
  [self sync:b];
  [self sync:a];
  NSArray *all = @[ @"apple", @"banana", @"cherry" ];
  XCTAssertEqualObjects([self elementsOf:@"d1" in:a.coordinator], all);
  XCTAssertEqualObjects([self elementsOf:@"d1" in:b.coordinator], all);
  XCTAssertEqualObjects([self elementsOf:@"d1" in:_server], all, @"and the service");
  // What is derived from it, set again after each merge: here and there.
  __block NSString *titleAtB = nil, *titleAtService = nil;
  [self in:b.coordinator do:^(NSManagedObjectContext *context) { titleAtB = [[self doc:@"d1" in:context] valueForKey:@"title"]; }];
  [self in:_server do:^(NSManagedObjectContext *context) { titleAtService = [[self doc:@"d1" in:context] valueForKey:@"title"]; }];
  XCTAssertEqualObjects(titleAtB, @"apple banana cherry");
  XCTAssertEqualObjects(titleAtService, @"apple banana cherry");

  // The rows never carried the body; the deltas did.
  NSString *batch = [[self bodiesSentTo:@"$batch" method:@"POST"] componentsJoinedByString:@"\n"];
  XCTAssertFalse([batch containsString:@"\"Body\""], @"%@", batch);
  XCTAssertGreaterThan([self bodiesSentTo:@"MergeAttributes" method:@"POST"].count, 0u);
  for (NSURLRequest *request in _transport.requests) {
    if ([request.HTTPMethod isEqualToString:@"GET"] && [request.URL.path hasSuffix:@"Docs"]) {
      XCTAssertTrue([request.URL.query containsString:@"select"], @"%@", request.URL);
    }
  }
  XCTAssertGreaterThan(a.lastResult.uploaded + a.lastResult.downloaded, 0u);
}

// A client that sends the whole state (one before merged attributes) has it
// merged into what the service has, not written over it.
- (void)testAWholeStateSentIsMergedIn
{
  ODataSyncEngine *a = [self device];
  [self edit:@"d1" in:a adding:@[ @"apple" ] deleting:nil];
  [self sync:a];
  NSData *old = [OSMTwoPhaseSet stateAdding:@[ @"pear" ] deleting:@[]];
  NSError *error = nil;
  ODataHTTPResponse *response = [self send:@"PATCH" to:@"Docs('d1')" JSON:@{ @"Body": [old base64EncodedStringWithOptions:0] } error:&error];
  XCTAssertNotNil(response, @"%@", error);
  XCTAssertEqualObjects([self elementsOf:@"d1" in:_server], (@[ @"apple", @"pear" ]));
  [self sync:a];
  XCTAssertEqualObjects([self elementsOf:@"d1" in:a.coordinator], (@[ @"apple", @"pear" ]), @"and comes down as a delta");
}

// A deletion every device has seen is collected, at the service and on the
// devices; one a device has not seen yet is not.
- (void)testWhatEveryReplicaHasSeenDeletedIsCollected
{
  ODataSyncEngine *a = [self device], *b = [self device];
  [self edit:@"d1" in:a adding:@[ @"apple", @"banana" ] deleting:nil];
  [self sync:a];
  [self sync:b];
  [self edit:@"d1" in:a adding:@[] deleting:@[ @"apple" ]];
  [self sync:a];
  NSDictionary *atService = [OSMTwoPhaseSet setsOf:[self stateOf:@"d1" in:_server]];
  XCTAssertTrue([atService[@"del"] containsObject:@"apple"], @"b has not seen it deleted: kept");
  [self sync:b];
  [self sync:a];
  atService = [OSMTwoPhaseSet setsOf:[self stateOf:@"d1" in:_server]];
  XCTAssertFalse([atService[@"add"] containsObject:@"apple"] || [atService[@"del"] containsObject:@"apple"], @"%@", atService);
  NSDictionary *atA = [OSMTwoPhaseSet setsOf:[self stateOf:@"d1" in:a.coordinator]];
  XCTAssertFalse([atA[@"del"] containsObject:@"apple"], @"collected on the device too: %@", atA);
  XCTAssertEqualObjects([self elementsOf:@"d1" in:a.coordinator], (@[ @"banana" ]));
  XCTAssertEqualObjects([self elementsOf:@"d1" in:b.coordinator], (@[ @"banana" ]));
  XCTAssertGreaterThan(_merger.collections, 0u);
}

// An item for an object the request may not see, or none: an error of its
// own; the rest are answered.
- (void)testAnItemForNoObjectIsAnErrorOfItsOwn
{
  ODataSyncEngine *a = [self device];
  [self edit:@"d1" in:a adding:@[ @"apple" ] deleting:nil];
  [self sync:a];
  NSData *version = [_merger versionOfState:nil];
  NSDictionary *body = @{ @"Replica": @"r1", @"Items": @[
    @{ @"EntitySet": @"Docs", @"Key": @{ @"Id": @"nope" }, @"Property": @"Body", @"Version": [version base64EncodedStringWithOptions:0] },
    @{ @"EntitySet": @"Docs", @"Key": @{ @"Id": @"d1" }, @"Property": @"Body", @"Version": [version base64EncodedStringWithOptions:0] } ] };
  NSError *error = nil;
  ODataHTTPResponse *response = [self send:@"POST" to:@"MergeAttributes" JSON:body error:&error];
  XCTAssertNotNil(response, @"%@", error);
  id json = [response JSONWithError:NULL];
  NSDictionary *answer = [json[@"value"] isKindOfClass:[NSDictionary class]] ? json[@"value"] : json;
  NSArray *items = answer[@"Items"];
  XCTAssertEqual(items.count, 2u);
  XCTAssertNotNil(items[0][@"Error"]);
  NSData *delta = [[NSData alloc] initWithBase64EncodedString:items[1][@"Delta"] options:0];
  XCTAssertEqualObjects([OSMTwoPhaseSet elementsOf:delta], (@[ @"apple" ]), @"what a copy with nothing lacks");
}

// Two devices that meet as peers exchange their merged attributes too
// (the peer server answers MergeAttributes), and the service gets both.
- (void)testPeersMergeToo
{
  ODataSyncEngine *a = [self device], *b = [self device];
  [self edit:@"d1" in:a adding:@[ @"apple" ] deleting:nil];
  [self sync:a];
  [self sync:b];
  [self edit:@"d1" in:a adding:@[ @"banana" ] deleting:nil];
  [self edit:@"d1" in:b adding:@[ @"cherry" ] deleting:nil];
  ODataSyncPeerServer *served = [[ODataSyncPeerServer alloc] initWithEngine:a host:@"127.0.0.1" port:18642];
  served.service.allowsAnonymousRequests = YES;
  ODataSyncRemote *toA = [ODataSyncRemote peerWithServiceRoot:served.serviceRoot];
  toA.transport = served.service;
  NSError *error = nil;
  XCTAssertTrue([b syncWithRemote:toA error:&error], @"%@", error);
  NSArray *all = @[ @"apple", @"banana", @"cherry" ];
  XCTAssertEqualObjects([self elementsOf:@"d1" in:b.coordinator], all, @"b has a's");
  XCTAssertEqualObjects([self elementsOf:@"d1" in:a.coordinator], all, @"and a b's");
  [self sync:b];
  [self sync:a];
  XCTAssertEqualObjects([self elementsOf:@"d1" in:_server], all, @"passed on to the service");
}

@end
