// ODataSyncPeerTransport — a remote's way to a peer over TLS
// (docs/peer-sync.md, 3).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// It presents this device's certificate (the trust's identity) and sends
// its peer token with every request. Before its first request it checks
// the peer: it asks for the peer's own token (GET <root>$peer) and notes the
// certificate that connection presented; the trust says whether that is a
// peer to sync with (paired with it, or its token the service's and bound to
// that certificate). From then on it takes no other certificate there.
//
//   ODataSyncRemote *peer = [ODataSyncRemote peerWithServiceRoot:advertised.serviceRoot];
//   peer.transport = [[ODataSyncPeerTransport alloc] initWithServiceRoot:peer.serviceRoot trust:trust];
//   [sync addRemote:peer];
//
// URLSession on Apple platforms; libcurl (built with GnuTLS) on GNUstep,
// which pins the peer's public key once its certificate is seen.

#pragma once
#import <Foundation/Foundation.h>
#import <ODataKit/ODataTransport.h>
#import <ODataSync/ODataSyncPeerTrust.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataSyncPeerTransport : NSObject <ODataTransport>
- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot trust:(ODataSyncPeerTrust *)trust NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
@property (nonatomic, readonly) ODataSyncPeerTrust *trust;
// The peer, once checked: its certificate's thumbprint, and whom the trust
// took it for (its replica in claims, odatasync_replica).
@property (atomic, readonly, copy, nullable) NSString *peerThumbprint;
@property (atomic, readonly, strong, nullable) HSPrincipal *peerPrincipal;
// The certificate the peer is said to have (an announcement's thumbprint,
// an offer's): a connection presenting another is refused before anything
// is sent. Nil: whichever it presents, the trust judging it.
@property (atomic, copy, nullable) NSString *expectedThumbprint;
// Checked (before the first request, and again before each after: a
// pairing forgotten, a token expired, ends it): YES when the peer is the
// device at the service root (its replica) and one to sync with; NO and
// why (an HSError 401 for one that is not).
- (BOOL)checkPeer:(NSError **)error;

// Pairing with the device whose offer this is (the JSON of its QR code:
// host, port, replica, thumbprint, code; ODataSyncPeerServer
// -pairingOfferForSubject:scopes:): reached at that host and port, its
// certificate the offer's (seen before the code is sent), told this
// device's replica (and name), and kept here as paired, syncing as
// subject with scopes. YES once both keep it; the transport then knows
// the peer. Its service root is the offer's.
+ (nullable instancetype)transportPairingWithOffer:(NSDictionary<NSString *, id> *)offer trust:(ODataSyncPeerTrust *)trust
                                            replica:(NSString *)replica name:(nullable NSString *)name
                                            subject:(NSString *)subject scopes:(NSSet<NSString *> *)scopes
                                              error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
