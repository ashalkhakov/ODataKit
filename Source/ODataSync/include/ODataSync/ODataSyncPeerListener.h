// ODataSyncPeerListener — TLS in front of a peer server (docs/peer-sync.md,
// 2): mutual, with the device's identity, each connection relayed to the
// server on loopback.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// It presents the device's certificate, and asks every client for one,
// checking it against no authority: what the certificate is worth is the
// authenticator's to decide, by a token bound to it or a pairing with it
// (ODataSyncPeerAuthenticator). Each connection it accepts is relayed,
// decrypted, to the HTTP server listening on loopback at backendPort; the
// client's certificate is known by the address the relayed connection
// comes from (127.0.0.1:port, the request's remoteAddress there), from
// before its first byte until it closes.
//
// Network.framework on Apple platforms; on GNUstep, GnuTLS over sockets
// (a thread for each connection), listening on IPv6 and IPv4 alike.

#pragma once
#import <Foundation/Foundation.h>
#import <ODataSync/ODataSyncPeerIdentity.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataSyncPeerListener : NSObject
- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity backendPort:(NSUInteger)backendPort NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataSyncPeerIdentity *identity;
@property (nonatomic, readonly) NSUInteger backendPort;
// Listening (port 0: one the system picks), when it is ready; NO and why
// not otherwise.
- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly) NSUInteger port;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
// The thumbprint (x5t#S256) of the certificate the client of a relayed
// connection presented, by the address that connection reached the
// server from (127.0.0.1:port); nil for one this listener did not relay,
// or one that has closed.
- (nullable NSString *)thumbprintOfConnectionFrom:(NSString *)remoteAddress;
// Connections relayed now.
@property (nonatomic, readonly) NSUInteger connectionCount;
@end

NS_ASSUME_NONNULL_END
