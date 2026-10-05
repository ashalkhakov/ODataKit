// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DVPeers.h"
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

NSNotificationName const DVPeersDidChangeNotification = @"DVPeersDidChange";
const NSUInteger DVPeersPort = 8642;

// Whom a paired device syncs as here.
static NSString * const DVPeerSubject = @"peer";

// The device's address on the local network: Wi-Fi's (en0) first, else
// the first other interface up with an IPv4 address.
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
    if (!other) other = address;
  }
  freeifaddrs(interfaces);
  return found ?: other;
}

@interface DVPeers () <ODataSyncPeerBrowserDelegate>
@end

@implementation DVPeers {
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
  [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *replica = device.sync.replicaID;
  ODataSyncPeerIdentity *identity = [ODataSyncPeerIdentity identityNamed:replica error:error];
  if (!identity) return nil;
  _trust = [[ODataSyncPeerTrust alloc] initWithIdentity:identity pairingsURL:[self fileNamed:@"Pairings"]];
  NSData *data = [NSData dataWithContentsOfURL:[self fileNamed:@"PeerToken"]];
  NSDictionary *answer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if ([answer isKindOfClass:[NSDictionary class]]) [_trust takePeerTokenAnswer:answer error:NULL];
  return self;
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
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    NSDictionary *answer = [sync peerTokenFromRemote:remote thumbprint:thumbprint error:&error];
    BOOL ok = answer && [self.trust takePeerTokenAnswer:answer error:&error];
    if (ok) {
      // Kept: peers are met without the Workbench, until it expires.
      NSData *data = [NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL];
      [data writeToURL:file options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:NULL];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_fetchingToken = NO;
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
  ODataSyncPeerServer *server = [[ODataSyncPeerServer alloc] initWithEngine:_device.sync trust:_trust host:host port:DVPeersPort];
  if (![server start:error]) return NO;
  ODataSyncPeerAdvertiser *advertiser = [[ODataSyncPeerAdvertiser alloc] initWithServer:server name:nil];
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
  ODataSyncPeerTrust *trust = _trust;
  NSString *replica = _device.sync.replicaID, *name = UIDevice.currentDevice.name;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    ODataSyncPeerTransport *transport = [ODataSyncPeerTransport transportPairingWithOffer:offer trust:trust replica:replica name:name
                                                                                 subject:DVPeerSubject scopes:[NSSet set] error:&error];
    dispatch_async(dispatch_get_main_queue(), ^{
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
  [_browser stop];
  _browser = nil;
  [self changed];
  [self say:[NSString stringWithFormat:@"No longer looking for peers: %@", error.localizedDescription]];
}

- (BOOL)syncWithPeer:(ODataSyncPeerAnnouncement *)peer
{
  ODataSyncRemote *remote = [ODataSyncRemote peerWithServiceRoot:peer.serviceRoot];
  remote.transport = [[ODataSyncPeerTransport alloc] initWithServiceRoot:peer.serviceRoot trust:_trust];
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
  [_advertiser stop];
  [_server stop];
  [_browser stop];
  _advertiser = nil;
  _server = nil;
  _browser = nil;
}

- (void)discard
{
  [self stop];
  [_trust.identity removeWithError:NULL];
  [[NSFileManager defaultManager] removeItemAtURL:[self fileNamed:@"Pairings"] error:NULL];
  [[NSFileManager defaultManager] removeItemAtURL:[self fileNamed:@"PeerToken"] error:NULL];
}

@end
