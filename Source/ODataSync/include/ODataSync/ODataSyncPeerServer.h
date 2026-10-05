// ODataSyncPeerServer — a device's store, served to its peers
// (docs/offline-sync.md, 7).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// An ODataService over the engine's store, on HTTPServerKit, so that other
// devices can add it as a peer remote (+[ODataSyncRemote
// peerWithServiceRoot:]) and sync with it as with the service:
//
//   ODataSyncPeerServer *peers = [[ODataSyncPeerServer alloc] initWithEngine:sync host:@"192.168.1.20" port:8642];
//   peers.service.authenticator = ...;     // who may sync: the app's to decide
//   [peers start:&error];
//   ... advertise peers.serviceRoot (Bonjour, a QR code) ...
//
// Its sets are the synced entities' (the engine's bookkeeping is not
// served); down sets are read only. What a peer sends is written as coming
// from that peer (ODataSyncReplicaHeader), so it is passed on to the
// service and the other peers, not back; its ODataSync.modified stamps are
// kept, and move this side's clock past them. Discovery and trust are the
// app's.

#pragma once
#import <ODataSync/ODataSyncEngine.h>

@class ODataService, ODataSyncPeerTrust, ODataSyncPeerListener;

NS_ASSUME_NONNULL_BEGIN

@interface ODataSyncPeerServer : NSObject
// At http://<host>:<port>/sync/<replica ID>/: the host the peers reach
// this device at.
- (instancetype)initWithEngine:(ODataSyncEngine *)engine host:(NSString *)host port:(NSUInteger)port NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataSyncEngine *engine;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
// Configure it before starting (an authenticator, limits); in the process,
// it is a remote's transport too.
@property (nonatomic, readonly) ODataService *service;
- (BOOL)start:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

#if defined(__APPLE__)
// Over TLS, for devices (docs/peer-sync.md; Apple only): at
// https://<host>:<port>/sync/<replica ID>/, the server itself on loopback
// behind an ODataSyncPeerListener with the trust's identity. Who may sync:
// a peer showing a token the service issued, bound to the certificate it
// connects with, or one this device paired with (the trust's to say);
// each write made as coming from the replica its token or pairing names.
// The port is the one peers reach (not 0: the service root names it).
// Also answered there: GET $peer (this device's own token, for a peer to
// check it by), POST $pair (a pairing: see -pairingOfferForSubject:scopes:).
- (instancetype)initWithEngine:(ODataSyncEngine *)engine trust:(ODataSyncPeerTrust *)trust host:(NSString *)host port:(NSUInteger)port;
@property (nonatomic, readonly, nullable) ODataSyncPeerTrust *trust;
@property (nonatomic, readonly, nullable) ODataSyncPeerListener *listener;
// A pairing's offer, for the other device to read (a QR code of its JSON):
// host, port, replica, thumbprint, and a one-time code good for two
// minutes (one at a time: a new offer replaces the last). The device that
// pairs with it syncs here as subject, with these scopes.
- (NSDictionary<NSString *, id> *)pairingOfferForSubject:(NSString *)subject scopes:(NSSet<NSString *> *)scopes;
#endif
@end

NS_ASSUME_NONNULL_END
