// ODataSyncPeerDiscovery — finding peers on the local network
// (docs/peer-sync.md, 2): Bonjour, the dns_sd API.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A device that serves its store over TLS (ODataSyncPeerServer with a
// trust) advertises it as _odatasync._tcp, its TXT record the replica ID,
// the service root's path and the certificate's thumbprint. A device that
// looks for peers browses for that type and resolves what it finds into a
// service root. What a TXT record says is a hint: whom a peer is, TLS and
// its token or pairing prove (ODataSyncPeerTransport checks).
//
// On iOS an app that browses names the type in its Info.plist
// (NSBonjourServices: _odatasync._tcp) and says why it uses the local
// network (NSLocalNetworkUsageDescription).
//
// Apple only.

#pragma once
#import <Foundation/Foundation.h>
#if defined(__APPLE__)
#import <ODataSync/ODataSyncPeerServer.h>

NS_ASSUME_NONNULL_BEGIN

// _odatasync._tcp.
FOUNDATION_EXPORT NSString * const ODataSyncPeerServiceType;

// A peer found.
@interface ODataSyncPeerAnnouncement : NSObject
// The name it is advertised under (what a person sees: the device's).
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *replica;
// The certificate it says it has (checked when connecting).
@property (nonatomic, readonly, copy) NSString *thumbprint;
@property (nonatomic, readonly, copy) NSString *host;
@property (nonatomic, readonly) NSUInteger port;
// https://<host>:<port><path>: what a peer remote and its transport take.
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
@end

@interface ODataSyncPeerAdvertiser : NSObject
// The server's service root, under name (nil: the device's name).
- (instancetype)initWithServer:(ODataSyncPeerServer *)server name:(nullable NSString *)name NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataSyncPeerServer *server;
// Advertised (the server running, with a trust); NO and why not.
- (BOOL)start:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly, getter=isAdvertising) BOOL advertising;
@end

@class ODataSyncPeerBrowser;

@protocol ODataSyncPeerBrowserDelegate <NSObject>
// On the delegate queue (default: main).
- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didFindPeer:(ODataSyncPeerAnnouncement *)peer;
- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didLosePeer:(ODataSyncPeerAnnouncement *)peer;
@optional
- (void)peerBrowser:(ODataSyncPeerBrowser *)browser didFailWithError:(NSError *)error;
@end

@interface ODataSyncPeerBrowser : NSObject
// Skipping the device's own replica (nil: skipping none).
- (instancetype)initWithReplica:(nullable NSString *)replica NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
@property (nonatomic, weak, nullable) id<ODataSyncPeerBrowserDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
- (BOOL)start:(NSError **)error;
- (void)stop;
// What it has found and not lost, by replica.
@property (nonatomic, readonly, copy) NSArray<ODataSyncPeerAnnouncement *> *peers;
@end

NS_ASSUME_NONNULL_END
#endif
