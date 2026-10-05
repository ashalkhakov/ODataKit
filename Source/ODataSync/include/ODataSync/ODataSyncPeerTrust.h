// ODataSyncPeerTrust — what a device trusts its peers by (docs/peer-sync.md,
// 3): tokens its service issued, and pairings a person made.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A peer is known by its certificate's thumbprint (ODataSyncPeerIdentity),
// which TLS proves it holds the key of. The certificate is trusted when
//   - it is one this device paired with: the pairing says whose it is
//     (subject, scopes), or
//   - the peer shows a token the service issued (ODataSyncPeerTokens),
//     bound to that certificate (cnf), checked with the service's keys
//     this device kept, as of now (not expired).
// The same answers both ways: a listener asks who a client is
// (ODataSyncPeerAuthenticator), a client asks who the server is
// (ODataSyncPeerTransport).
//
// Apple only, as the rest of TLS peer sync is.

#pragma once
#import <Foundation/Foundation.h>
#if defined(__APPLE__)
#import <ODataSync/ODataSyncPeerIdentity.h>
#import <ODataSync/ODataSyncPeerTokens.h>
#import <HTTPServerKit/HSAuthentication.h>

NS_ASSUME_NONNULL_BEGIN

// A peer this device paired with.
@interface ODataSyncPeerPairing : NSObject
- (instancetype)initWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint subject:(NSString *)subject
                         scopes:(NSSet<NSString *> *)scopes NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *replica;
@property (nonatomic, readonly, copy) NSString *thumbprint;
// Who it syncs as here, and with what scopes (the app's to say).
@property (nonatomic, readonly, copy) NSString *subject;
@property (nonatomic, readonly, copy) NSSet<NSString *> *scopes;
@property (nonatomic, readonly) NSDate *date;
// A name a person gave it (the other device's, say).
@property (nonatomic, copy, nullable) NSString *name;
@end

@interface ODataSyncPeerTrust : NSObject
// The device's identity; its pairings kept in this file (nil: in memory,
// for as long as this object lives).
- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity pairingsURL:(nullable NSURL *)pairingsURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataSyncPeerIdentity *identity;

// From the service, while online (-[ODataSyncEngine peerTokenFromRemote:
// error:]'s answer, taken by -takePeerTokenAnswer:): this device's token,
// and the service's issuer and keys, which peers' tokens are checked with.
- (BOOL)takePeerTokenAnswer:(NSDictionary<NSString *, id> *)answer error:(NSError **)error;
@property (atomic, copy, nullable) NSString *token;
@property (atomic, copy, nullable) NSDate *tokenExpires;
@property (atomic, copy, nullable) NSString *issuer;
@property (atomic, copy, nullable) NSDictionary<NSString *, id> *keySet;

@property (nonatomic, readonly, copy) NSArray<ODataSyncPeerPairing *> *pairings;
- (nullable ODataSyncPeerPairing *)pairingWithThumbprint:(NSString *)thumbprint;
// Kept (replacing one of the same thumbprint); NO and why when the file
// cannot be written.
- (BOOL)addPairing:(ODataSyncPeerPairing *)pairing error:(NSError **)error;
- (BOOL)forgetPairingWithThumbprint:(NSString *)thumbprint error:(NSError **)error;

// Whom a peer is, by the certificate it proved it holds and the token it
// showed (nil: none): the pairing's subject, or the token's; with the
// replica (odatasync_replica claim) and scopes. nil and why (an HSError:
// 401) for neither.
- (nullable HSPrincipal *)principalForThumbprint:(NSString *)thumbprint token:(nullable NSString *)token error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
#endif
