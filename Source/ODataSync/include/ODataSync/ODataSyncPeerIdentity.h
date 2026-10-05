// ODataSyncPeerIdentity — a device's name among its peers: a key pair and
// a certificate of it (docs/peer-sync.md, 2).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A P-256 key pair, made on the device and kept there, and a self-signed
// certificate of the public key. No authority signs it: a peer knows the
// device by its thumbprint (the certificate's SHA-256, base64url: RFC
// 8705's x5t#S256), which the service vouches for in a peer token, or a
// person pairs with. TLS uses it on both sides of a peer connection.
//
// Where it is kept is the system's (ODSSystem): the keychain on Apple
// platforms; on Linux two PEM files, made with GnuTLS, the private key
// readable by the user alone (0600), in a directory of the app's (0700).

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataSyncPeerIdentity : NSObject
// The identity kept under name (one per app and replica, say), or a new
// one made and kept; nil and why when neither can be.
+ (nullable instancetype)identityNamed:(NSString *)name error:(NSError **)error;
// The same; directory is where, on a system that keeps identities in files
// (Linux: made, 0700, when missing). The keychain has no directory.
+ (nullable instancetype)identityNamed:(NSString *)name directory:(NSURL *)directory error:(NSError **)error;
// Where +identityNamed:error: keeps them in files: Application
// Support/<the process>/ODataSync Peers.
+ (NSURL *)defaultDirectory;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *name;
// The certificate, DER.
@property (nonatomic, readonly, copy) NSData *certificateData;
// Its x5t#S256: what peers know the device by.
@property (nonatomic, readonly, copy) NSString *thumbprint;
// Forgotten: the key and the certificate removed. A device that does this
// is a new device to its peers.
- (BOOL)removeWithError:(NSError **)error;

// A certificate's x5t#S256: base64url (no padding) of its DER's SHA-256.
+ (NSString *)thumbprintOfCertificateData:(NSData *)certificate;
@end

NS_ASSUME_NONNULL_END
