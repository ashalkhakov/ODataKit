// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What the peer tests need of the system they run on: a TLS client of
// their own, and a look at an identity as the system's TLS sees it. One
// implementation for each system (Tests/apple, Tests/linux), as
// ODataSync's own (ODSSystem).

#pragma once
#import <Foundation/Foundation.h>
#import <ODataSync/ODataSyncPeerIdentity.h>

NS_ASSUME_NONNULL_BEGIN

// A client of a TLS peer: its certificate given (or none), the server's
// taken as it comes and noted (what the transport checks, later).
@interface OSPClient : NSObject
- (instancetype)initWithIdentity:(nullable ODataSyncPeerIdentity *)identity;
@property (nonatomic, strong, nullable) ODataSyncPeerIdentity *identity;
@property (atomic, copy, nullable) NSString *serverThumbprint;
// GET, waited for: the status and the JSON (0 and the error).
- (NSInteger)get:(NSURL *)url json:(id _Nullable *_Nullable)json error:(NSError **)error;
- (void)close;
@end

// Nil when the identity's certificate is well formed and signed by its
// own key (trusted as its own anchor), its key signs what the certificate
// checks, and the key is kept private; else what is wrong.
FOUNDATION_EXPORT NSString *_Nullable OSPCheckIdentity(ODataSyncPeerIdentity *identity);

// Whether peers can be advertised and browsed for here: Bonjour is always
// there on Apple platforms; on Linux, when avahi-daemon runs.
FOUNDATION_EXPORT BOOL OSPDiscoveryAvailable(void);

NS_ASSUME_NONNULL_END
