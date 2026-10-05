// Peer sync between devices (docs/peer-sync.md): identity, TLS, trust,
// discovery. On GNUstep, discovery takes avahi-daemon running (the test
// says so and passes without it).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <ODataSync/ODataSync.h>
#import <ODataSync/ODataSyncPeerIdentity.h>
#import <ODataSync/ODataSyncPeerListener.h>
#import <HTTPServerKit/HTTPServerKit.h>
#import <ODataSync/ODataSyncPeerTrust.h>
#import <ODataSync/ODataSyncPeerTransport.h>
#import <ODataSync/ODataSyncPeerTokens.h>
#import <ODataSync/ODataSyncPeerDiscovery.h>
#import "OSPSystem.h"

// What a browser finds and loses, for a test to wait on (on a queue of
// the browser's own: GNUstep's XCTest has no expectations).
@interface OSPWatcher : NSObject <ODataSyncPeerBrowserDelegate>
@property (atomic, copy) NSString *replica;
@property (atomic, strong, nullable) ODataSyncPeerAnnouncement *peer;
@property (atomic) BOOL lost;
@end

@implementation OSPWatcher
- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didFindPeer:(ODataSyncPeerAnnouncement *)peer
{
  if ([peer.replica isEqualToString:self.replica]) self.peer = peer;
}

- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didLosePeer:(ODataSyncPeerAnnouncement *)peer
{
  if ([peer.replica isEqualToString:self.replica]) self.lost = YES;
}
@end

// Until the condition holds, or seconds go by: whether it holds.
static BOOL OSPWaitFor(NSTimeInterval seconds, BOOL (^condition)(void))
{
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!condition()) {
    if (until.timeIntervalSinceNow < 0) return NO;
    [NSThread sleepForTimeInterval:0.05];
  }
  return YES;
}

#import <ODataService/ODataService.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

// A port no one listens on now.
static NSUInteger OSPFreePort(void)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
  bind(fd, (struct sockaddr *)&address, sizeof address);
  socklen_t length = sizeof address;
  getsockname(fd, (struct sockaddr *)&address, &length);
  close(fd);
  return ntohs(address.sin_port);
}

static NSAttributeDescription *OSPAttribute(NSString *name, NSAttributeType type, BOOL key)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = !key;
  if (key) attribute.userInfo = @{ @"OData.key": @"YES" };
  return attribute;
}

// Assets the service's (down), tasks everyone's (both).
static NSManagedObjectModel *OSPModel(void)
{
  NSEntityDescription *asset = [[NSEntityDescription alloc] init];
  asset.name = @"Asset";
  asset.managedObjectClassName = @"NSManagedObject";
  asset.userInfo = @{ @"OData.entitySet": @"Assets", ODataSyncDirectionKey: @"down" };
  NSAttributeDescription *version = OSPAttribute(@"version", NSInteger64AttributeType, NO);
  version.userInfo = @{ @"OData.etag": @"YES" };
  asset.properties = @[ OSPAttribute(@"id", NSInteger32AttributeType, YES), OSPAttribute(@"name", NSStringAttributeType, NO), version ];
  NSEntityDescription *task = [[NSEntityDescription alloc] init];
  task.name = @"Task";
  task.managedObjectClassName = @"NSManagedObject";
  task.userInfo = @{ @"OData.entitySet": @"Tasks", ODataSyncDirectionKey: @"both", ODataSyncModifiedKey: @"modified" };
  task.properties = @[ OSPAttribute(@"id", NSStringAttributeType, YES), OSPAttribute(@"title", NSStringAttributeType, NO),
                       OSPAttribute(@"modified", NSStringAttributeType, NO) ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ asset, task ];
  return model;
}

// Signed in as alice, whatever the request: the service's own sign-in, as
// far as these tests care.
@interface OSPSignedIn : NSObject <HSAuthenticator>
@end

@implementation OSPSignedIn
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  [reply finishWithPrincipal:[[HSPrincipal alloc] initWithSubject:@"alice" claims:@{ @"scope": @"tasks" }]];
}
@end

// Behind the listener: which certificate the request's connection came with.
@interface OSPWhoAmI : NSObject <HSHandler>
@property (nonatomic, weak) ODataSyncPeerListener *listener;
@end

@implementation OSPWhoAmI
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  NSString *thumbprint = [self.listener thumbprintOfConnectionFrom:request.remoteAddress];
  [reply finishWithResponse:[HSResponse responseWithJSON:@{ @"thumbprint": thumbprint ?: [NSNull null], @"from": request.remoteAddress ?: @"" }
                                                  status:200]];
}
@end

@interface ODataSyncPeerTests : XCTestCase
@end

@implementation ODataSyncPeerTests {
  NSMutableArray<ODataSyncPeerIdentity *> *_identities;
  NSURL *_directory;
}

- (void)setUp
{
  _identities = [NSMutableArray array];
  NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"peers-" stringByAppendingString:[NSUUID UUID].UUIDString]];
  _directory = [NSURL fileURLWithPath:directory isDirectory:YES];
}

- (void)tearDown
{
  for (ODataSyncPeerIdentity *identity in _identities) [identity removeWithError:NULL];
  [[NSFileManager defaultManager] removeItemAtURL:_directory error:NULL];
}

// Under its name, in this test's directory (where identities are files).
- (ODataSyncPeerIdentity *)identityNamed:(NSString *)name error:(NSError **)error
{
  return [ODataSyncPeerIdentity identityNamed:name directory:_directory error:error];
}

// An identity of this test's own, forgotten when it ends.
- (ODataSyncPeerIdentity *)identity:(NSString *)name
{
  NSError *error = nil;
  NSString *unique = [NSString stringWithFormat:@"%@ %@", name, [NSUUID UUID].UUIDString];
  ODataSyncPeerIdentity *identity = [self identityNamed:unique error:&error];
  XCTAssertNotNil(identity, @"%@", error);
  if (identity) [_identities addObject:identity];
  return identity;
}

// A key pair and a certificate of it, kept: the same identity again by
// its name, a certificate that is one (its own anchor, it is trusted), and
// a thumbprint that is its SHA-256.
- (void)testIdentity
{
  ODataSyncPeerIdentity *identity = [self identity:@"device A"];
  XCTAssertEqual(identity.thumbprint.length, 43u, @"%@", identity.thumbprint);
  XCTAssertEqualObjects([ODataSyncPeerIdentity thumbprintOfCertificateData:identity.certificateData], identity.thumbprint);

  NSError *error = nil;
  ODataSyncPeerIdentity *again = [self identityNamed:identity.name error:&error];
  XCTAssertEqualObjects(again.thumbprint, identity.thumbprint, @"kept: %@", error);
  ODataSyncPeerIdentity *other = [self identity:@"device B"];
  XCTAssertNotEqualObjects(other.thumbprint, identity.thumbprint);

  // Well formed and signed by its own key, the key kept private, as the
  // system's TLS sees them.
  NSString *wrong = OSPCheckIdentity(identity);
  XCTAssertNil(wrong, @"%@", wrong);

  // Forgotten: a new one under the name.
  XCTAssertTrue([identity removeWithError:&error], @"%@", error);
  ODataSyncPeerIdentity *anew = [self identityNamed:identity.name error:&error];
  XCTAssertNotNil(anew, @"%@", error);
  XCTAssertNotEqualObjects(anew.thumbprint, identity.thumbprint);
  [_identities addObject:anew];
}

- (NSPersistentStoreCoordinator *)coordinatorWithModel:(NSManagedObjectModel *)model
{
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
  NSError *error = nil;
  XCTAssertNotNil([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url
                                                  options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error], @"%@", error);
  return coordinator;
}

- (ODataSyncEngine *)device
{
  NSManagedObjectModel *model = OSPModel();
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  return [[ODataSyncEngine alloc] initWithCoordinator:[self coordinatorWithModel:model]];
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

- (NSArray *)values:(NSString *)key of:(NSString *)entity in:(NSPersistentStoreCoordinator *)coordinator
{
  __block NSArray *values = nil;
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:key ascending:YES] ];
    values = [[context executeFetchRequest:fetch error:NULL] valueForKey:key];
  }];
  return values;
}

- (void)task:(NSString *)identifier title:(NSString *)title in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSManagedObject *task = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
    [task setValue:identifier forKey:@"id"];
    [task setValue:title forKey:@"title"];
  }];
}

// A peer remote of engine, over TLS to server, with this trust.
- (ODataSyncRemote *)peerOf:(ODataSyncPeerServer *)server for:(ODataSyncEngine *)engine trust:(ODataSyncPeerTrust *)trust
{
  ODataSyncRemote *remote = [ODataSyncRemote peerWithServiceRoot:server.serviceRoot];
  remote.transport = [[ODataSyncPeerTransport alloc] initWithServiceRoot:server.serviceRoot trust:trust];
  [engine addRemote:remote];
  return remote;
}

// The service's tokens: each device gets one for its certificate, and syncs
// with a peer that shows one; not without, and not with another's.
- (void)testPeersTrustedByTheServicesTokens
{
  NSManagedObjectModel *serverModel = OSPModel();
  [ODataSyncService addBookkeepingToModel:serverModel configuration:nil];
  NSPersistentStoreCoordinator *serverStore = [self coordinatorWithModel:serverModel];
  [self in:serverStore do:^(NSManagedObjectContext *context) {
    for (NSArray *a in @[ @[ @1, @"Pump" ], @[ @2, @"Valve" ] ]) {
      NSManagedObject *asset = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
      [asset setValue:a[0] forKey:@"id"];
      [asset setValue:a[1] forKey:@"name"];
      [asset setValue:@1 forKey:@"version"];
    }
  }];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:serverStore serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  service.authenticator = [[OSPSignedIn alloc] init];
  ODataSyncService *syncService = [[ODataSyncService alloc] initWithService:service];
  NSError *error = nil;
  NSDictionary *signingKey = HSGenerateSigningKey(&error);
  XCTAssertNotNil(signingKey, @"%@", error);
  syncService.peerTokens = [[ODataSyncPeerTokenIssuer alloc] initWithIssuer:@"http://example.test/odata/" signingKey:signingKey];

  // Each device signed in to the service: its token, and the service's keys.
  NSMutableDictionary<NSString *, ODataSyncEngine *> *engines = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, ODataSyncPeerTrust *> *trusts = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, ODataSyncRemote *> *toService = [NSMutableDictionary dictionary];
  for (NSString *name in @[ @"A", @"B", @"C", @"D" ]) {
    ODataSyncEngine *engine = [self device];
    ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:service.serviceRoot];
    remote.transport = service;
    [engine addRemote:remote];
    ODataSyncPeerTrust *trust = [[ODataSyncPeerTrust alloc] initWithIdentity:[self identity:[@"device " stringByAppendingString:name]] pairingsURL:nil];
    engines[name] = engine;
    trusts[name] = trust;
    toService[name] = remote;
  }
  for (NSString *name in @[ @"A", @"B", @"D" ]) {
    NSDictionary *answer = [engines[name] peerTokenFromRemote:toService[name] thumbprint:trusts[name].identity.thumbprint error:&error];
    XCTAssertNotNil(answer, @"%@: %@", name, error);
    XCTAssertTrue([trusts[name] takePeerTokenAnswer:answer error:&error], @"%@", error);
  }
  // C keeps the service's keys, but has no token of its own.
  trusts[@"C"].issuer = trusts[@"A"].issuer;
  trusts[@"C"].keySet = trusts[@"A"].keySet;
  // D shows B's token, with its own certificate.
  trusts[@"D"].token = trusts[@"B"].token;
  XCTAssertNotNil(trusts[@"A"].token);

  // A reads the service, and serves its store to peers over TLS.
  XCTAssertTrue([engines[@"A"] syncWithError:&error], @"%@", error);
  [self task:@"t1" title:@"Check the pump" in:engines[@"A"].coordinator];
  ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:engines[@"A"] trust:trusts[@"A"] host:@"127.0.0.1" port:OSPFreePort()];
  XCTAssertTrue([server start:&error], @"%@", error);
  XCTAssertEqualObjects(server.serviceRoot.scheme, @"https");

  // B, with its token: A's data, and its edit taken as B's.
  for (ODataSyncRemote *remote in [engines[@"B"].remotes copy]) [engines[@"B"] removeRemote:remote];
  ODataSyncRemote *peerA = [self peerOf:server for:engines[@"B"] trust:trusts[@"B"]];
  XCTAssertTrue([engines[@"B"] syncWithError:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:engines[@"B"].coordinator], (@[ @"Pump", @"Valve" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:engines[@"B"].coordinator], (@[ @"Check the pump" ]));
  ODataSyncPeerTransport *transport = (ODataSyncPeerTransport *)peerA.transport;
  XCTAssertEqualObjects(transport.peerThumbprint, trusts[@"A"].identity.thumbprint);
  XCTAssertEqualObjects(transport.peerPrincipal.claims[ODataSyncPeerReplicaClaim], engines[@"A"].replicaID);
  [self task:@"t2" title:@"Oil the valve" in:engines[@"B"].coordinator];
  XCTAssertTrue([engines[@"B"] syncWithError:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:engines[@"A"].coordinator], (@[ @"Check the pump", @"Oil the valve" ]));

  // C: no token, no sync. D: B's token is bound to B's certificate.
  for (NSString *name in @[ @"C", @"D" ]) {
    for (ODataSyncRemote *remote in [engines[name].remotes copy]) [engines[name] removeRemote:remote];
    [self peerOf:server for:engines[name] trust:trusts[name]];
    error = nil;
    XCTAssertFalse([engines[name] syncWithError:&error], @"%@ synced", name);
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:engines[name].coordinator], @[], @"%@: %@", name, error);
  }
  [server stop];
}

// Pairing, with no service at all: an offer read, the code posted once,
// each device then the other's peer.
- (void)testPairing
{
  ODataSyncEngine *e = [self device], *f = [self device];
  ODataSyncPeerTrust *trustE = [[ODataSyncPeerTrust alloc] initWithIdentity:[self identity:@"device E"] pairingsURL:nil];
  NSURL *pairings = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID].UUIDString stringByAppendingString:@".json"]]];
  ODataSyncPeerTrust *trustF = [[ODataSyncPeerTrust alloc] initWithIdentity:[self identity:@"device F"] pairingsURL:pairings];
  [self task:@"e1" title:@"From E" in:e.coordinator];
  NSError *error = nil;
  ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:e trust:trustE host:@"127.0.0.1" port:OSPFreePort()];
  XCTAssertTrue([server start:&error], @"%@", error);

  // Not paired: E takes no one.
  ODataSyncRemote *unpaired = [self peerOf:server for:f trust:trustF];
  XCTAssertFalse([f syncWithError:&error], @"synced unpaired");
  [f removeRemote:unpaired];

  NSDictionary *offer = [server pairingOfferForSubject:@"bob" scopes:[NSSet setWithObject:@"tasks"]];
  XCTAssertEqualObjects(offer[@"thumbprint"], trustE.identity.thumbprint);
  ODataSyncPeerTransport *transport = [ODataSyncPeerTransport transportPairingWithOffer:offer trust:trustF replica:f.replicaID name:@"F's phone"
                                                                               subject:@"erin" scopes:[NSSet set] error:&error];
  XCTAssertNotNil(transport, @"%@", error);
  XCTAssertEqualObjects([trustE pairingWithThumbprint:trustF.identity.thumbprint].subject, @"bob");
  XCTAssertEqualObjects([trustE pairingWithThumbprint:trustF.identity.thumbprint].name, @"F's phone");
  XCTAssertEqualObjects([trustF pairingWithThumbprint:trustE.identity.thumbprint].replica, e.replicaID);
  // The code is good once.
  error = nil;
  XCTAssertNil([ODataSyncPeerTransport transportPairingWithOffer:offer trust:trustF replica:f.replicaID name:nil subject:@"erin" scopes:[NSSet set] error:&error]);
  XCTAssertEqual(error.code, 410, @"%@", error);

  ODataSyncRemote *peer = [ODataSyncRemote peerWithServiceRoot:transport.serviceRoot];
  peer.transport = transport;
  [f addRemote:peer];
  XCTAssertTrue([f syncWithError:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:f.coordinator], (@[ @"From E" ]));
  [self task:@"f1" title:@"From F" in:f.coordinator];
  XCTAssertTrue([f syncWithError:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:e.coordinator], (@[ @"From E", @"From F" ]));

  // Kept: another trust over the same file knows E.
  ODataSyncPeerTrust *again = [[ODataSyncPeerTrust alloc] initWithIdentity:trustF.identity pairingsURL:pairings];
  XCTAssertEqualObjects([again pairingWithThumbprint:trustE.identity.thumbprint].replica, e.replicaID);
  // Forgotten by E: F no longer syncs there.
  XCTAssertTrue([trustE forgetPairingWithThumbprint:trustF.identity.thumbprint error:&error], @"%@", error);
  ODataSyncRemote *forgotten = [self peerOf:server for:f trust:trustF];
  [f removeRemote:peer];
  XCTAssertFalse([f syncWithError:&error], @"synced once forgotten");
  [f removeRemote:forgotten];
  [server stop];
  [[NSFileManager defaultManager] removeItemAtURL:pairings error:NULL];
}

// Bonjour: a peer server advertised, found with what it says of itself,
// a peer to sync with at the root found; lost once it stops.
- (void)testDiscovery
{
  ODataSyncEngine *e = [self device], *f = [self device];
  ODataSyncPeerTrust *trustE = [[ODataSyncPeerTrust alloc] initWithIdentity:[self identity:@"device E"] pairingsURL:nil];
  NSError *error = nil;
  ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:e trust:trustE host:@"127.0.0.1" port:OSPFreePort()];
  XCTAssertTrue([server start:&error], @"%@", error);
  ODataSyncPeerAdvertiser *advertiser = [[ODataSyncPeerAdvertiser alloc] initWithServer:server name:[@"Test peer " stringByAppendingString:e.replicaID]];
  // Nothing to advertise with (Linux without avahi-daemon): not run.
  if (!OSPDiscoveryAvailable()) {
    NSLog(@"testDiscovery: not run, no Bonjour here (on Linux: avahi-daemon)");
    [server stop];
    return;
  }
  XCTAssertTrue([advertiser start:&error], @"%@", error);

  OSPWatcher *watcher = [[OSPWatcher alloc] init];
  watcher.replica = e.replicaID;
  ODataSyncPeerBrowser *browser = [[ODataSyncPeerBrowser alloc] initWithReplica:f.replicaID];
  browser.delegate = watcher;
  browser.delegateQueue = [[NSOperationQueue alloc] init];
  browser.delegateQueue.maxConcurrentOperationCount = 1;
  XCTAssertTrue([browser start:&error], @"%@", error);
  XCTAssertTrue(OSPWaitFor(20, ^{ return (BOOL)(watcher.peer != nil); }), @"not found");
  ODataSyncPeerAnnouncement *peer = watcher.peer;
  XCTAssertEqualObjects(peer.thumbprint, trustE.identity.thumbprint);
  XCTAssertEqual(peer.port, server.listener.port);
  XCTAssertEqualObjects(peer.serviceRoot.path, server.serviceRoot.path);
  XCTAssertTrue([[browser.peers valueForKey:@"replica"] containsObject:e.replicaID]);

  [advertiser stop];
  XCTAssertTrue(OSPWaitFor(20, ^{ return watcher.lost; }), @"not lost");
  [browser stop];
  [server stop];
}

// TLS in front of a server on loopback: the client's certificate known to
// the server by the relayed connection's address, the server's presented
// to the client; no certificate, no connection.
- (void)testListener
{
  ODataSyncPeerIdentity *a = [self identity:@"listener A"];
  ODataSyncPeerIdentity *b = [self identity:@"client B"];
  OSPWhoAmI *who = [[OSPWhoAmI alloc] init];
  HSServer *server = [[HSServer alloc] initWithHandler:who];
  NSError *error = nil;
  XCTAssertTrue([server startOnPort:0 error:&error], @"%@", error);
  ODataSyncPeerListener *listener = [[ODataSyncPeerListener alloc] initWithIdentity:a backendPort:server.port];
  who.listener = listener;
  XCTAssertTrue([listener startOnPort:0 error:&error], @"%@", error);
  XCTAssertGreaterThan(listener.port, 0u);
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://127.0.0.1:%lu/whoami", (unsigned long)listener.port]];

  OSPClient *client = [[OSPClient alloc] initWithIdentity:b];
  id json = nil;
  NSInteger status = [client get:url json:&json error:&error];
  XCTAssertEqual(status, 200, @"%@", error);
  XCTAssertEqualObjects(json[@"thumbprint"], b.thumbprint, @"%@", json);
  XCTAssertEqualObjects(client.serverThumbprint, a.thumbprint);
  // Again, on the connection kept: the same.
  XCTAssertEqual([client get:url json:&json error:&error], 200, @"%@", error);
  XCTAssertEqualObjects(json[@"thumbprint"], b.thumbprint);

  OSPClient *stranger = [[OSPClient alloc] initWithIdentity:nil];
  error = nil;
  XCTAssertEqual([stranger get:url json:&json error:&error], 0, @"no certificate, no answer");
  XCTAssertNotNil(error);

  [client close];
  [listener stop];
  [server stop];
  XCTAssertNil([listener thumbprintOfConnectionFrom:json[@"from"] ?: @""]);
}

@end
