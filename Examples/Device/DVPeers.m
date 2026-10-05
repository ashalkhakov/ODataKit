// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DVPeers.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

NSNotificationName const DVPeersDidChangeNotification = @"DVPeersDidChange";
const NSUInteger DVPeersPort = 8642;

// Whom a paired device syncs as here.
static NSString * const DVPeerSubject = @"peer";

// Whether an interface is a local network's, by its name: Ethernet and
// Wi-Fi as Apple's systems and Linux name them (en*, eth*, wl*), bridges;
// not cellular (pdp_ip*), a VPN's (utun*, tun*, ppp*), nor a container's.
static BOOL DVIsLocalInterface(const char *name)
{
  const char *prefixes[] = { "en", "eth", "wl", "bridge", NULL };
  for (int i = 0; prefixes[i]; i++) {
    if (strncmp(name, prefixes[i], strlen(prefixes[i])) == 0) return YES;
  }
  return NO;
}

// The device's address on the local network: Wi-Fi's on Apple's systems
// (en0) first, else another local interface's; never cellular or a VPN's,
// which peers nearby cannot reach.
static NSString *DVLocalAddress(void)
{
  struct ifaddrs *interfaces = NULL;
  if (getifaddrs(&interfaces) != 0) return nil;
  NSString *found = nil, *other = nil;
  for (struct ifaddrs *at = interfaces; at; at = at->ifa_next) {
    if (!at->ifa_addr || at->ifa_addr->sa_family != AF_INET) continue;
    if (!(at->ifa_flags & IFF_UP) || (at->ifa_flags & IFF_LOOPBACK)) continue;
    char text[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET, &((struct sockaddr_in *)at->ifa_addr)->sin_addr, text, sizeof text)) continue;
    NSString *address = @(text);
    if (strcmp(at->ifa_name, "en0") == 0) {
      found = address;
      break;
    }
    if (!other && DVIsLocalInterface(at->ifa_name)) other = address;
  }
  freeifaddrs(interfaces);
  return found ?: other;
}

@interface DVPeers () <ODataSyncPeerBrowserDelegate>
@end

@implementation DVPeers {
  BOOL _discarded;  // the device reset: what finishes now is not kept
  BOOL _pairing;
  NSTimer *_expiry;
  NSURL *_directory;
  ODataSyncPeerServer *_server;
  ODataSyncPeerAdvertiser *_advertiser;
  ODataSyncPeerBrowser *_browser;
}

- (instancetype)initWithDevice:(WorkbenchDevice *)device directory:(NSURL *)directory error:(NSError **)error
{
  self = [super init];
  if (!self) return nil;
  _device = device;
  _directory = [directory copy];
  _deviceName = [NSProcessInfo processInfo].hostName;
  _port = DVPeersPort;
  [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *replica = device.sync.replicaID;
  ODataSyncPeerIdentity *identity = [ODataSyncPeerIdentity identityNamed:replica error:error];
  if (!identity) return nil;
  _trust = [[ODataSyncPeerTrust alloc] initWithIdentity:identity pairingsURL:[self fileNamed:@"Pairings"]];
  NSData *data = [NSData dataWithContentsOfURL:[self fileNamed:@"PeerToken"]];
  NSDictionary *answer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if ([answer isKindOfClass:[NSDictionary class]]) [_trust takePeerTokenAnswer:answer error:NULL];
  [self watchExpiry];
  return self;
}

// Told when the token runs out: the views say so.
- (void)watchExpiry
{
  [_expiry invalidate];
  _expiry = nil;
  NSTimeInterval left = self.tokenExpires.timeIntervalSinceNow;
  if (!_trust.token || left <= 0) return;
  _expiry = [NSTimer scheduledTimerWithTimeInterval:left + 1 target:self selector:@selector(tokenExpired:) userInfo:nil repeats:NO];
}

- (void)tokenExpired:(NSTimer *)timer
{
  _expiry = nil;
  [self changed];
  [self say:@"The peer token expired: get a new one from the Workbench (Peers)."];
}

- (BOOL)isBusy
{
  return _fetchingToken || _pairing;
}

- (void)dealloc
{
  [self stop];
}

// <name>-<replica>.json: a new device's are its own.
- (NSURL *)fileNamed:(NSString *)name
{
  NSString *file = [NSString stringWithFormat:@"%@-%@.json", name, _device.sync.replicaID];
  return [_directory URLByAppendingPathComponent:file];
}

- (void)say:(NSString *)status
{
  if (_say) _say(status);
}

- (void)changed
{
  [[NSNotificationCenter defaultCenter] postNotificationName:DVPeersDidChangeNotification object:self];
}

#pragma mark The token

- (BOOL)hasToken
{
  NSDate *expires = _trust.tokenExpires;
  return _trust.token != nil && (!expires || expires.timeIntervalSinceNow > 0);
}

- (NSDate *)tokenExpires
{
  return _trust.tokenExpires;
}

- (void)fetchToken
{
  if (_fetchingToken) return;
  ODataSyncRemote *remote = _device.serviceRemote;
  if (!remote) {
    [self say:@"No Workbench to ask for a peer token: set its address in Settings."];
    return;
  }
  _fetchingToken = YES;
  [self changed];
  [self say:@"Asking the Workbench for a peer token…"];
  ODataSyncEngine *sync = _device.sync;
  NSString *thumbprint = _trust.identity.thumbprint;
  NSURL *file = [self fileNamed:@"PeerToken"];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    NSError *error = nil;
    NSDictionary *answer = [sync peerTokenFromRemote:remote thumbprint:thumbprint error:&error];
    BOOL ok = answer && !self->_discarded && [self.trust takePeerTokenAnswer:answer error:&error];
    if (ok) {
      // Kept: peers are met without the Workbench, until it expires.
      NSData *data = [NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL];
      // The user's alone. (On iOS an app's files are protected until the
      // first unlock already.)
      if ([data writeToURL:file options:NSDataWritingAtomic error:NULL]) {
        [[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @0600 } ofItemAtPath:file.path error:NULL];
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_fetchingToken = NO;
      if (self->_discarded) return;
      [self watchExpiry];
      [self changed];
      if (!ok) {
        [self say:[NSString stringWithFormat:@"No peer token: %@", error.localizedDescription ?: @"no answer."]];
        return;
      }
      [self say:[NSString stringWithFormat:@"A peer token, until %@: devices with one sync with each other.",
                                           [NSDateFormatter localizedStringFromDate:self.tokenExpires ?: [NSDate distantFuture]
                                                                          dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]]];
    });
  });
}

#pragma mark Serving

- (BOOL)isServing
{
  return _server.running;
}

- (NSURL *)serviceRoot
{
  return _server.running ? _server.serviceRoot : nil;
}

- (BOOL)startServing:(NSError **)error
{
  if (_server.running) return YES;
  NSString *host = DVLocalAddress();
  if (!host) {
    if (error) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                                        userInfo:@{ NSLocalizedDescriptionKey: @"The device has no address on a local network." }];
    return NO;
  }
  ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:_device.sync trust:_trust host:host port:_port];
  if (![server start:error]) return NO;
  ODataSyncPeerAdvertiser *advertiser = [[ODataSyncPeerAdvertiser alloc] initWithServer:server name:_deviceName];
  __weak DVPeers *weak = self;
  advertiser.didFail = ^(NSError *failure) {
    DVPeers *strong = weak;
    if (!strong) return;
    strong->_discoveryError = failure;
    [strong changed];
    [strong say:failure.localizedDescription];
  };
  if (![advertiser start:error]) {
    [server stop];
    return NO;
  }
  _server = server;
  _advertiser = advertiser;
  [self changed];
  [self say:[NSString stringWithFormat:@"Serving to peers at %@.", server.serviceRoot.absoluteString]];
  return YES;
}

- (void)stopServing
{
  if (!_server) return;
  [_advertiser stop];
  [_server stop];
  _advertiser = nil;
  _server = nil;
  [self changed];
  [self say:@"No longer serving to peers."];
}

- (NSString *)newPairingOffer
{
  if (!_server.running) return nil;
  NSDictionary *offer = [_server pairingOfferForSubject:DVPeerSubject scopes:[NSSet set]];
  NSData *data = [NSJSONSerialization dataWithJSONObject:offer options:NSJSONWritingSortedKeys error:NULL];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (void)pairWithOffer:(NSString *)text completion:(void (^)(NSError *))completion
{
  NSData *data = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *offer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![offer isKindOfClass:[NSDictionary class]]) {
    completion([NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError
                               userInfo:@{ NSLocalizedDescriptionKey: @"That is not a pairing offer: the other device shows one under Peers, Pairing Code." }]);
    return;
  }
  [self say:@"Pairing…"];
  _pairing = YES;
  [self changed];
  ODataSyncPeerTrust *trust = _trust;
  NSString *replica = _device.sync.replicaID, *name = _deviceName;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    NSError *error = nil;
    ODataSyncPeerTransport *transport = [ODataSyncPeerTransport transportPairingWithOffer:offer trust:trust replica:replica name:name
                                                                                 subject:DVPeerSubject scopes:[NSSet set] error:&error];
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_pairing = NO;
      if (self->_discarded) return;
      [self changed];
      if (!transport) {
        [self say:[NSString stringWithFormat:@"Not paired: %@", error.localizedDescription]];
        completion(error);
        return;
      }
      completion(nil);
      // Met at once: the offer's address, the transport that knows it.
      ODataSyncRemote *remote = [ODataSyncRemote peerWithServiceRoot:transport.serviceRoot];
      remote.transport = transport;
      [self.device syncWithRemote:remote named:@"the device paired"];
    });
  });
}

#pragma mark Browsing

- (void)startBrowsing
{
  if (_browser) return;
  ODataSyncPeerBrowser *browser = [[ODataSyncPeerBrowser alloc] initWithReplica:_device.sync.replicaID];
  browser.delegate = self;
  NSError *error = nil;
  if (![browser start:&error]) {
    [self say:[NSString stringWithFormat:@"Not looking for peers: %@", error.localizedDescription]];
    return;
  }
  _browser = browser;
}

- (NSArray *)found
{
  return _browser.peers ?: @[];
}

- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didFindPeer:(ODataSyncPeerAnnouncement *)peer
{
  [self changed];
}

- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didLosePeer:(ODataSyncPeerAnnouncement *)peer
{
  [self changed];
}

- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didFailWithError:(NSError *)error
{
  _discoveryError = error;
  [_browser stop];
  _browser = nil;
  [self changed];
  [self say:[NSString stringWithFormat:@"No longer looking for peers: %@", error.localizedDescription]];
}

- (BOOL)syncWithPeer:(ODataSyncPeerAnnouncement *)peer
{
  // Neither side would take the other: said so, not a TLS error.
  if (!self.hasToken && ![self pairingOfPeer:peer]) {
    [self say:[NSString stringWithFormat:@"Not synced with %@: get a peer token from the Workbench, or pair with it, first.", peer.name]];
    return NO;
  }
  ODataSyncRemote *remote = [ODataSyncRemote peerWithServiceRoot:peer.serviceRoot];
  ODataSyncPeerTransport *transport = [[ODataSyncPeerTransport alloc] initWithServiceRoot:peer.serviceRoot trust:_trust];
  // The certificate it advertised, and no other.
  transport.expectedThumbprint = peer.thumbprint;
  remote.transport = transport;
  return [_device syncWithRemote:remote named:peer.name];
}

#pragma mark Pairings

- (NSArray *)pairings
{
  return _trust.pairings;
}

- (ODataSyncPeerPairing *)pairingOfPeer:(ODataSyncPeerAnnouncement *)peer
{
  return [_trust pairingWithThumbprint:peer.thumbprint];
}

- (BOOL)forgetPairing:(ODataSyncPeerPairing *)pairing error:(NSError **)error
{
  BOOL ok = [_trust forgetPairingWithThumbprint:pairing.thumbprint error:error];
  [self changed];
  return ok;
}

#pragma mark Done

- (void)stop
{
  [_expiry invalidate];
  _expiry = nil;
  [_advertiser stop];
  [_server stop];
  [_browser stop];
  _advertiser = nil;
  _server = nil;
  _browser = nil;
}

- (void)discard
{
  _discarded = YES;
  [self stop];
  [_trust.identity removeWithError:NULL];
  [[NSFileManager defaultManager] removeItemAtURL:[self fileNamed:@"Pairings"] error:NULL];
  [[NSFileManager defaultManager] removeItemAtURL:[self fileNamed:@"PeerToken"] error:NULL];
}

@end
