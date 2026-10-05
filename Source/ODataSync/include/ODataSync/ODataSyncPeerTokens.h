// ODataSyncPeerTokens — tokens the service issues its devices, for their
// peers to trust them by (docs/peer-sync.md, 3.1).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A peer token is a JWT the service signs (ES256), short-lived, saying who
// the device's user is (sub), which replica it is (odatasync_replica), what
// it may sync (scope), and which certificate it is bound to (cnf, its
// x5t#S256: RFC 8705, RFC 7800). Peers check it with the service's public
// keys, which a device keeps from when it was online: a token is worth
// nothing without the certificate's key, and nothing once it expires.
//
// On the server, the service's part issues them (ODataSyncService
// -setPeerTokens:): its devices call PeerToken(Replica, Thumbprint), signed
// in as they are to the service.

#pragma once
#import <Foundation/Foundation.h>
#import <ODataService/ODataService.h>
#import <HTTPServerKit/HSAuthentication.h>

NS_ASSUME_NONNULL_BEGIN

// The audience of every peer token: odatasync-peer.
FOUNDATION_EXPORT NSString * const ODataSyncPeerTokenAudience;
// Its claims beyond JWT's own: the replica, and the confirmation (cnf).
FOUNDATION_EXPORT NSString * const ODataSyncPeerReplicaClaim;      // odatasync_replica
FOUNDATION_EXPORT NSString * const ODataSyncPeerThumbprintMember;  // x5t#S256, in cnf

@interface ODataSyncPeerTokenIssuer : NSObject
// issuer: the tokens' iss, which peers expect (the service root, say).
// signingKey: a P-256 key with its d (HSGenerateSigningKey()), kept by the
// server app; its public part is keySet.
- (instancetype)initWithIssuer:(NSString *)issuer signingKey:(NSDictionary<NSString *, id> *)signingKey NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *issuer;
// The public keys, as a JWK Set: what devices keep to check peers with.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *keySet;
// How long a token is good for. Default: a day.
@property (nonatomic) NSTimeInterval lifetime;
// The scopes a token gives, from the principal's: default, all of them.
@property (nonatomic, copy, nullable) NSSet<NSString *> * (^scopesForPrincipal)(HSPrincipal *principal);
// A token for the principal's device: replica and thumbprint as the device
// says them (its certificate's, which it proves it holds on every peer
// connection). nil and the error for no principal, or a thumbprint that
// is none.
- (nullable NSString *)tokenForPrincipal:(nullable HSPrincipal *)principal replica:(NSString *)replica thumbprint:(NSString *)thumbprint
                                   error:(NSError **)error;
// What PeerToken answers: { "Token": ..., "Keys": keySet, "Issuer": ..., "Expires": seconds since 1970 }.
- (nullable NSDictionary<NSString *, id> *)answerForPrincipal:(nullable HSPrincipal *)principal replica:(NSString *)replica
                                                   thumbprint:(NSString *)thumbprint error:(NSError **)error;
@end

// PeerToken(Replica, Thumbprint), an unbound action: a server app whose
// serviceOperations object is its own adopts this, and answers with
// -[ODataSyncService peerTokenWithReplica:thumbprint:reply:]; one with none
// gets one that does (ODataSyncService -setPeerTokens:).
@protocol ODataSyncPeerTokenActions <ODataActions>
- (nullable NSDictionary *)peerTokenWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint reply:(ODataReply *)reply;
@end

NS_ASSUME_NONNULL_END
