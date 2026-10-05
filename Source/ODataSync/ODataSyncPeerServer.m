// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Peers (docs/offline-sync.md, 7): the engine's store as an ODataService,
// each synced root a set whose writes are made as coming from the peer
// that sent them.

#import "ODataSyncPeerServer.h"
#import "ODataSyncService.h"
#import "ODSInternal.h"
#import <ODataKit/ODataError.h>
#import <ODataService/ODataService.h>
#import <ODataService/ODataServer.h>
#import <HTTPServerKit/HSServer.h>
#import <HTTPServerKit/HSRouter.h>
#import <HTTPServerKit/HSStages.h>
#import <HTTPServerKit/HSMessage.h>
#import "ODataSyncPeerTrust.h"
#import "ODataSyncPeerListener.h"
#import "ODSSystem.h"

// A replica ID as a peer names it: letters, digits and dashes (a UUID).
static BOOL ODSIsReplica(NSString *text)
{
  if (!text.length || text.length > 64) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                                                @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"];
  return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// A peer's write is made as coming from the replica the request names, so
// that the engine passes it on but not back; its stamp kept, and
// witnessed. Deletions kept and histories compared as at a service.
@interface ODSPeerSetHandler : ODataSyncSetHandler
@end

@implementation ODSPeerSetHandler

- (NSString *)authorOfRequest:(ODataRequest *)request values:(NSDictionary<NSString *, id> *)values
{
  // The replica a peer's token or pairing names, when it signed in so (TLS
  // peers): never the one it says it is. Else the header (a peer server
  // the app trusts its network for).
  id claimed = request.principal.claims[ODataSyncPeerReplicaClaim];
  NSString *replica = [claimed isKindOfClass:[NSString class]] ? claimed : [request valueForHeader:ODataSyncReplicaHeader];
  return ODSIsReplica(replica) ? [ODataSyncDownAuthorPrefix stringByAppendingString:replica] : [super authorOfRequest:request values:values];
}

- (void)witness:(NSManagedObject *)object
{
  ODataSyncEngine *engine = self.engine;
  NSAttributeDescription *stamp = object ? [engine.model modifiedAttributeOf:object.entity] : nil;
  if (stamp) [engine.clock witness:[object valueForKey:stamp.name]];
}

- (NSManagedObject *)insertObjectWithValues:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSManagedObject *object = [super insertObjectWithValues:values request:request reply:reply];
  [self witness:object];
  return object;
}

- (NSManagedObject *)updateObject:(NSManagedObject *)object values:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request
                            reply:(ODataReply *)reply
{
  NSManagedObject *updated = [super updateObject:object values:values request:request reply:reply];
  [self witness:updated];
  return updated;
}

@end

// Who a TLS peer is: the certificate its connection came with (the
// listener's), and the token it shows, as the trust says.
@interface ODSPeerAuthenticator : NSObject <HSAuthenticator>
@property (nonatomic, weak) ODataSyncPeerListener *listener;
@property (nonatomic, strong) ODataSyncPeerTrust *trust;
@end

@implementation ODSPeerAuthenticator
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  NSString *thumbprint = [self.listener thumbprintOfConnectionFrom:request.remoteAddress];
  if (!thumbprint) {
    [reply failWithError:HSError(401, @"Not a peer connection")];
    return;
  }
  NSString *authorization = [request valueForHeader:@"Authorization"];
  NSString *token = [authorization hasPrefix:@"Bearer "] ? [authorization substringFromIndex:7] : nil;
  // Neither paired nor with a token: no one (who may still pair, or ask
  // for this device's token); the service's route wants someone.
  if (!token && ![self.trust pairingWithThumbprint:thumbprint]) {
    [reply finishWithPrincipal:nil];
    return;
  }
  NSError *error = nil;
  HSPrincipal *principal = [self.trust principalForThumbprint:thumbprint token:token error:&error];
  if (principal) [reply finishWithPrincipal:principal];
  else [reply failWithError:error ?: HSError(401, @"Not a peer")];
}
@end

// $peer and $pair, beside the service.
@interface ODSPeerRoutes : NSObject <HSHandler>
@property (nonatomic, weak) ODataSyncPeerServer *server;
@property (nonatomic, copy) NSString *what;  // peer, pair
@end

@interface ODataSyncPeerServer ()
- (void)answerPeer:(HSRequest *)request reply:(HSReply *)reply;
- (void)answerPair:(HSRequest *)request reply:(HSReply *)reply;
@end

@implementation ODSPeerRoutes
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  if ([self.what isEqualToString:@"peer"]) [self.server answerPeer:request reply:reply];
  else [self.server answerPair:request reply:reply];
}
@end

@implementation ODataSyncPeerServer {
  HSServer *_server;
  NSUInteger _port;
  NSDictionary *_offer;  // the pairing offered now: code, expires, subject, scopes
}

- (instancetype)initWithEngine:(ODataSyncEngine *)engine host:(NSString *)host port:(NSUInteger)port
{
  self = [super init];
  if (!self) return nil;
  [self setUpWithEngine:engine host:host port:port scheme:@"http"];
  return self;
}

- (instancetype)initWithEngine:(ODataSyncEngine *)engine trust:(ODataSyncPeerTrust *)trust host:(NSString *)host port:(NSUInteger)port
{
  self = [super init];
  if (!self) return nil;
  _trust = trust;
  [self setUpWithEngine:engine host:host port:port scheme:@"https"];
  return self;
}

- (void)setUpWithEngine:(ODataSyncEngine *)engine host:(NSString *)host port:(NSUInteger)port scheme:(NSString *)scheme
{
  _engine = engine;
  _port = port;
  NSString *root = [NSString stringWithFormat:@"%@://%@:%lu/sync/%@/", scheme, host, (unsigned long)port, engine.replicaID];
  _serviceRoot = [NSURL URLWithString:root];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:engine.coordinator serviceRoot:_serviceRoot];
  // The synced entities only (the configuration +addBookkeepingToModel:
  // made): not the bookkeeping, nor what is the app's alone.
  _service.configurationName = ODataSyncPeerConfiguration;
  ODSModel *model = engine.model;
  for (NSEntityDescription *entity in engine.coordinator.managedObjectModel.entities) {
    if (entity.superentity) continue;
    ODataSyncDirection direction = [model directionOfEntity:entity];
    if (direction == ODataSyncDirectionNone) continue;
    ODSPeerSetHandler *handler = [[ODSPeerSetHandler alloc] initWithEntity:entity];
    handler.engine = engine;
    // The service's alone: a peer reads them.
    BOOL writes = direction != ODataSyncDirectionDown;
    handler.allowsInsert = writes;
    handler.allowsUpdate = writes;
    handler.allowsDelete = writes;
    handler.allowsUpsert = writes;
    [_service setHandler:handler forEntitySet:[_service.mapper entitySetForEntity:entity]];
  }
}

- (BOOL)start:(NSError **)error
{
  if (_server.running) return YES;
  if (_trust) return [self startBehindListener:error];
  _server = [[HSServer alloc] initWithService:_service];
  return [_server startOnPort:_port error:error];
}

// The server on loopback (a port the system picks), $peer and $pair before
// the service, and TLS in front of it on the port peers reach.
- (BOOL)startBehindListener:(NSError **)error
{
  // (NSURL's path has no trailing slash.)
  NSString *root = [_serviceRoot.path stringByAppendingString:@"/"];
  HSRouter *router = [[HSRouter alloc] init];
  ODSPeerRoutes *peer = [[ODSPeerRoutes alloc] init];
  peer.server = self;
  peer.what = @"peer";
  ODSPeerRoutes *pair = [[ODSPeerRoutes alloc] init];
  pair.server = self;
  pair.what = @"pair";
  [router addRoute:[HSRoute routeWithMethod:@"GET" path:[root stringByAppendingString:@"$peer"] handler:peer]];
  [router addRoute:[HSRoute routeWithMethod:@"POST" path:[root stringByAppendingString:@"$pair"] handler:pair]];
  HSRoute *service = [HSRoute routeWithMethod:nil path:[root stringByAppendingString:@"*"] handler:[[ODataServiceHandler alloc] initWithService:_service]];
  service.requiresPrincipal = YES;
  [router addRoute:service];
  // Who is asking, found on the request the listener relayed (its address
  // names the certificate), before the router: the service is told.
  ODSPeerAuthenticator *authenticator = [[ODSPeerAuthenticator alloc] init];
  authenticator.trust = _trust;
  HSPipeline *pipeline = [[HSPipeline alloc] initWithStages:@[ [[HSRoutingStage alloc] initWithRouter:router],
                                                               [[HSAuthenticationStage alloc] initWithAuthenticator:authenticator] ]
                                                    handler:router];
  HSServer *server = [[HSServer alloc] initWithHandler:pipeline];
  server.bindToLocalhost = YES;
  if (![server startOnPort:0 error:error]) return NO;
  ODataSyncPeerListener *listener = [[ODataSyncPeerListener alloc] initWithIdentity:_trust.identity backendPort:server.port];
  if (![listener startOnPort:_port error:error]) {
    [server stop];
    return NO;
  }
  authenticator.listener = listener;
  _listener = listener;
  _server = server;
  return YES;
}

- (NSDictionary *)pairingOfferForSubject:(NSString *)subject scopes:(NSSet *)scopes
{
  uint8_t bytes[16];
  ODSSystemRandomBytes(bytes, sizeof bytes);
  NSString *code = [[[[NSData dataWithBytes:bytes length:sizeof bytes] base64EncodedStringWithOptions:0]
                      stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  code = [code stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
  NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:120];
  @synchronized (self) {
    _offer = @{ @"code": code, @"expires": expires, @"subject": subject, @"scopes": scopes ?: [NSSet set] };
  }
  return @{ @"host": _serviceRoot.host ?: @"", @"port": @(_port), @"replica": _engine.replicaID, @"thumbprint": _trust.identity.thumbprint,
            @"code": code, @"expires": @(floor(expires.timeIntervalSince1970)) };
}

// This device's own token: what a peer checks this server by.
- (void)answerPeer:(HSRequest *)request reply:(HSReply *)reply
{
  NSString *token = _trust.token;
  if (!token) {
    [reply finishWithResponse:[HSResponse responseWithError:HSError(404, @"This device has no peer token")]];
    return;
  }
  [reply finishWithResponse:[HSResponse responseWithJSON:@{ @"Token": token, @"Replica": _engine.replicaID } status:200]];
}

// A pairing: the code offered (once, in time), from the certificate the
// connection came with, kept with the offer's subject and scopes.
- (void)answerPair:(HSRequest *)request reply:(HSReply *)reply
{
  NSDictionary *body = [request.JSONBody isKindOfClass:[NSDictionary class]] ? request.JSONBody : nil;
  NSString *code = body[@"Code"], *replica = body[@"Replica"];
  NSString *thumbprint = [_listener thumbprintOfConnectionFrom:request.remoteAddress];
  NSDictionary *offer = nil;
  @synchronized (self) {
    offer = _offer;
    BOOL matches = offer && [code isKindOfClass:[NSString class]] && [code isEqualToString:offer[@"code"]] &&
                   [offer[@"expires"] timeIntervalSinceNow] > 0;
    if (!matches) offer = nil;
    else _offer = nil;  // once
  }
  if (!offer || !thumbprint || !ODSIsReplica(replica)) {
    // 410, not 403: the offer is gone (and URL loading takes a 403 on a
    // connection with a client certificate for that certificate refused).
    [reply finishWithResponse:[HSResponse responseWithError:HSError(410, @"No pairing offered with that code, or it has expired")]];
    return;
  }
  ODataSyncPeerPairing *pairing = [[ODataSyncPeerPairing alloc] initWithReplica:replica thumbprint:thumbprint subject:offer[@"subject"]
                                                                         scopes:offer[@"scopes"]];
  if ([body[@"Name"] isKindOfClass:[NSString class]]) pairing.name = body[@"Name"];
  NSError *error = nil;
  if (![_trust addPairing:pairing error:&error]) {
    [reply finishWithResponse:[HSResponse responseWithError:HSError(500, error.localizedDescription ?: @"The pairing could not be kept")]];
    return;
  }
  [reply finishWithResponse:[HSResponse responseWithJSON:@{ @"Replica": _engine.replicaID, @"Thumbprint": _trust.identity.thumbprint } status:200]];
}

- (void)stop
{
  [_listener stop];
  _listener = nil;
  [_server stop];
  _server = nil;
}

- (BOOL)isRunning
{
  return _server.running;
}

@end
