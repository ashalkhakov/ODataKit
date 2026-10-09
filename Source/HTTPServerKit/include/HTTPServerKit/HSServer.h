// HSServer — a handler on the network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The one part of HTTPServerKit that touches sockets. It listens with the
// vendored GCDWebServer (ThirdParty/GCDWebServer), turns each request into
// an HSRequest for its handler -- a pipeline, a router, an API's own
// handler -- and writes the response back. HTTP/1.1, with persistent
// connections (keepAliveTimeout), no TLS: it is meant to sit behind a
// reverse proxy (nginx, Caddy), which passes the request path on unchanged.
//
// Most applications do not make one themselves: HSApplication does, with
// a pipeline and router around their APIs.

#pragma once
#import <Foundation/Foundation.h>
#import "HSPipeline.h"


NS_ASSUME_NONNULL_BEGIN

@interface HSServer : NSObject

- (instancetype)initWithHandler:(id<HSHandler>)handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, strong) id<HSHandler> handler;
// Listen on 127.0.0.1 and ::1 only (the default: the proxy is on the same
// machine), or on every address.
@property (nonatomic) BOOL bindToLocalhost;
// The largest request body taken, in bytes; a larger one is answered 413.
// Default: 64 MiB.
@property (nonatomic) NSUInteger maxBodySize;
// A larger request body, or a chunked one (whose size is not said), is
// written to a temporary file as it comes, not kept in memory
// (HSRequest's bodyFileURL). Default: 1 MiB.
@property (nonatomic) NSUInteger maxBodyInMemory;
// How long a connection is kept open for the next request after a
// response (HTTP/1.1 persistent connections; a proxy's upstream keepalive),
// and how many requests it answers before it is closed. 0 closes each
// after one response. Default: 5 seconds, 100 requests.
@property (nonatomic) NSTimeInterval keepAliveTimeout;
@property (nonatomic) NSUInteger maxRequestsPerConnection;

// Starts listening; port 0 asks the system for a free one. Handlers run on
// dispatch queues, so the caller need not run a run loop.
- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;
// The same, and waits until the process gets SIGINT or SIGTERM, then stops.
- (BOOL)runOnPort:(NSUInteger)port error:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger port;
// Requests received and not yet answered: what a graceful stop waits for.
@property (atomic, readonly) NSUInteger requestsInFlight;
// Requests answered since it started.
@property (atomic, readonly) NSUInteger requestsAnswered;

@end

NS_ASSUME_NONNULL_END
