// ODataSyncPeerIdentity — a device's name among its peers: a key pair and
// a certificate of it (docs/peer-sync.md, 2).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A P-256 key pair, made on the device and kept in its keychain, and a
// self-signed certificate of the public key. No authority signs it: a peer
// knows the device by its thumbprint (the certificate's SHA-256, base64url:
// RFC 8705's x5t#S256), which the service vouches for in a peer token, or a
// person pairs with. TLS uses it on both sides of a peer connection.
//
// Apple only (the Security framework, Network.framework's TLS).

#pragma once
#import <Foundation/Foundation.h>
#if defined(__APPLE__)
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataSyncPeerIdentity : NSObject
// The identity kept under name (the keychain's label: one per app and
// replica, say), or a new one made and kept; nil and the keychain's
// error when neither can be.
+ (nullable instancetype)identityNamed:(NSString *)name error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *name;
// The certificate, DER.
@property (nonatomic, readonly, copy) NSData *certificateData;
// Its x5t#S256: what peers know the device by.
@property (nonatomic, readonly, copy) NSString *thumbprint;
// For TLS (Network.framework, URLSession).
@property (nonatomic, readonly) SecIdentityRef identity;
@property (nonatomic, readonly) SecCertificateRef certificate;
// Forgotten: the key and the certificate taken out of the keychain. A
// device that does this is a new device to its peers.
- (BOOL)removeWithError:(NSError **)error;

// A certificate's x5t#S256: base64url (no padding) of its DER's SHA-256.
+ (NSString *)thumbprintOfCertificateData:(NSData *)certificate;
+ (nullable NSString *)thumbprintOfCertificate:(SecCertificateRef)certificate;
@end

NS_ASSUME_NONNULL_END
#endif
