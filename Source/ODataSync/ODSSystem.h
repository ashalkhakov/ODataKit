// ODSSystem — what ODataSync's peers need of the system they run on
// (docs/peer-sync.md, 5). One implementation for each system, in its own
// directory, which the build picks:
//
//   apple/   Security, Network.framework, URLSession (the Xcode project)
//   linux/   GnuTLS, libcurl (the GNUmakefiles)
//
// Each directory also has the system's ODataSyncPeerListener. Nothing
// outside them asks which system it is on.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import <ODataSync/ODataSyncPeerIdentity.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSData *ODSSystemSHA256(NSData *data);
// Random bytes for keys and codes, from the system's generator.
FOUNDATION_EXPORT void ODSSystemRandomBytes(void *bytes, size_t length);
// How a file only this device should read is written: atomically, and
// protected where the system protects files (iOS's data protection).
FOUNDATION_EXPORT NSUInteger ODSSystemPrivateFileWritingOptions(void);
// The device's name, as people know it.
FOUNDATION_EXPORT NSString *ODSSystemDeviceName(void);
// Whether a .local name Bonjour resolves a peer to is one a URL can name
// (the system's resolver answers it); NO: it is looked up as an address.
FOUNDATION_EXPORT BOOL ODSSystemResolvesLocalNames(void);

// A device's identity as the system keeps it: its certificate (DER), and
// (in the system's own header) what its TLS presents it with.
@interface ODSSystemIdentity : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSData *certificate;
@end

// The identity kept under label, or a new one made and kept (a P-256 key,
// a self-signed certificate of it, CN the label); directory is where, for
// a system that keeps identities in files. Nil and why when neither can be.
FOUNDATION_EXPORT ODSSystemIdentity *_Nullable ODSSystemKeepIdentity(NSString *label, NSURL *directory, NSError **error);
// Removed: a device that does this is a new device to its peers.
FOUNDATION_EXPORT BOOL ODSSystemForgetIdentity(ODSSystemIdentity *identity, NSError **error);
// Where identities are kept by default, for a system that keeps them in
// files: Application Support/<the process>/ODataSync Peers.
FOUNDATION_EXPORT NSURL *ODSSystemIdentityDirectory(void);

@interface ODataSyncPeerIdentity (System)
@property (nonatomic, readonly) ODSSystemIdentity *system;
@end

// HTTPS to a peer, presenting this device's certificate. The peer's is
// taken only when it is the one pinned; with none pinned, any is taken and
// noted.
@interface ODSSystemPeerClient : NSObject
- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// A request, waited for: the response and its body, or nil and why.
// pinned: the thumbprint the peer's certificate must have (nil: any).
// fresh: over a new connection. presented: the thumbprint of the
// certificate a new connection presented (nil when one was reused).
- (nullable NSHTTPURLResponse *)send:(NSURLRequest *)request pinned:(nullable NSString *)pinned fresh:(BOOL)fresh
                                data:(NSData *_Nullable *_Nullable)data presented:(NSString *_Nullable *_Nullable)presented
                               error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
