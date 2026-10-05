// The Device app's peers (docs/peer-sync.md): the device's identity and
// trust, its peer token from the Workbench, its store served to the devices
// nearby over TLS and advertised (Bonjour), the devices found, pairings.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "WorkbenchDevice.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when something of the peers changed: a token,
// serving, a device found or lost, a pairing.
FOUNDATION_EXPORT NSNotificationName const DVPeersDidChangeNotification;

// Where peers reach this device: 8642, the Workbench's port and two.
FOUNDATION_EXPORT const NSUInteger DVPeersPort;

// All on the main thread.
@interface DVPeers : NSObject
// Its identity named for the device's replica (made the first time, in the
// keychain), its files in directory (pairings, the token's answer).
- (nullable instancetype)initWithDevice:(WorkbenchDevice *)device directory:(NSURL *)directory error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) WorkbenchDevice *device;
@property (nonatomic, readonly) ODataSyncPeerTrust *trust;
// What happened, in words (the session's status line).
@property (nonatomic, copy, nullable) void (^say)(NSString *status);

// The token the Workbench issued (for this certificate), and until when;
// kept across launches.
@property (nonatomic, readonly) BOOL hasToken;
@property (nonatomic, readonly, nullable) NSDate *tokenExpires;
// Asked of the Workbench (PeerToken), on a thread of its own.
- (void)fetchToken;
@property (nonatomic, readonly, getter=isFetchingToken) BOOL fetchingToken;
// Asking for a token, or pairing: the device is not to be reset meanwhile.
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

// The device's store served at https://<its address>:8642/sync/<replica>/,
// and advertised; NO and why not.
- (BOOL)startServing:(NSError **)error;
- (void)stopServing;
@property (nonatomic, readonly, getter=isServing) BOOL serving;
@property (nonatomic, readonly, nullable) NSURL *serviceRoot;
// A pairing offer, as its QR code says it (JSON); nil when not serving. A
// new one replaces the last; good for two minutes, once.
- (nullable NSString *)newPairingOffer;
// Paired with the device whose offer that is (scanned, or pasted), then a
// sync with it; the completion (nil: paired) on the main thread.
- (void)pairWithOffer:(NSString *)text completion:(void (^)(NSError *_Nullable error))completion;

// Looking for devices nearby (asks, the first time, for the local network).
- (void)startBrowsing;
@property (nonatomic, readonly, copy) NSArray<ODataSyncPeerAnnouncement *> *found;
// A sync with a device found: its download, then its upload. NO while
// another runs.
- (BOOL)syncWithPeer:(ODataSyncPeerAnnouncement *)peer;

@property (nonatomic, readonly, copy) NSArray<ODataSyncPeerPairing *> *pairings;
- (nullable ODataSyncPeerPairing *)pairingOfPeer:(ODataSyncPeerAnnouncement *)peer;
- (BOOL)forgetPairing:(ODataSyncPeerPairing *)pairing error:(NSError **)error;

// Not serving, not browsing.
- (void)stop;
// Stopped, its identity, pairings and token gone (the device is reset);
// what was under way finishes without keeping anything.
- (void)discard;
@end

NS_ASSUME_NONNULL_END
