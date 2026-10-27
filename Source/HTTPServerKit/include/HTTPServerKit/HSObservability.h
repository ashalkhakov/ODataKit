// HSObservability — what a server says about itself: metrics,
// trace context, readiness.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Metrics in Prometheus's text format (HSMetrics, HSMetricsStage,
// HSMetricsHandler), labelled by route pattern, never by path, so that
// their number stays bounded; W3C Trace Context (HSTraceContextStage),
// so a request can be followed through the proxy, this server and what it
// calls; and readiness (HSReadinessHandler), apart from liveness
// (HSHealthHandler): whether to send it requests, not whether it runs.

#pragma once
#import <Foundation/Foundation.h>
#import "HSPipeline.h"


NS_ASSUME_NONNULL_BEGIN

#pragma mark - Metrics

// A registry of metrics, by name and labels: counters, gauges and
// histograms, thread-safe. The application's own go in the same one as the
// server's, and come out at the same /metrics.
//
//   [metrics incrementCounter:@"orders_placed_total" help:@"Orders placed." labels:@{ @"channel": @"web" } by:1];
//
// Names and label names as Prometheus has them ([a-zA-Z_:][a-zA-Z0-9_:]*);
// label values are escaped when written. A name is one kind, with one help
// text: the first use says which.
@interface HSMetrics : NSObject
- (void)incrementCounter:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels by:(double)value;
- (void)setGauge:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels value:(double)value;
- (void)addToGauge:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels by:(double)value;
// buckets: upper bounds, ascending (+Inf is added); nil for the default,
// 5 ms to 10 s as Prometheus's clients have it.
- (void)observeHistogram:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels
                   value:(double)value buckets:(nullable NSArray<NSNumber *> *)buckets;
// The current value of a counter or gauge (0 for none): for tests and
// health checks.
- (double)valueOf:(NSString *)name labels:(nullable NSDictionary<NSString *, NSString *> *)labels;
// Everything, in the text exposition format (version 0.0.4), with the
// process's own: start time, resident memory, and the build.
- (NSString *)exposition;
@end

// Each request counted, timed and sized, by method, route pattern and
// status: http_requests_total, http_request_duration_seconds,
// http_response_size_bytes, http_requests_in_flight; and, for a request
// whose handler named its operation (an OpenAPI operationId, an OData
// entity set), http_operations_total by route and operation too. A request
// no route took is counted under route "(none)". A 401 or 403 is counted
// in http_auth_failures_total by reason: the authenticator's
// (HSAuthenticationFailureKey: expired, signature, provider_unavailable,
// ...), else unauthenticated or forbidden.
@interface HSMetricsStage : HSStage
- (instancetype)initWithMetrics:(HSMetrics *)metrics NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) HSMetrics *metrics;
@end

// GET: the metrics, as Prometheus scrapes them.
@interface HSMetricsHandler : NSObject <HSHandler>
- (instancetype)initWithMetrics:(HSMetrics *)metrics NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/* HTTPServerKit's own: exported where HTTPServerKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef HTTPSERVERKIT_EXPORT
#define HTTPSERVERKIT_EXPORT FOUNDATION_EXPORT
#endif

// The version the build says (HTTPSERVERKIT_VERSION when compiled), for
// httpserverkit_build_info and logs.
HTTPSERVERKIT_EXPORT NSString * const HSVersion;

#pragma mark - Trace context

// W3C Trace Context and the request's span: a request's traceparent
// (00-<trace id>-<parent id>-<flags>), with its tracestate, is taken when
// it is well formed, and a new trace begun when it is not; either way this server's part of it is
// a new span, the request's (request.span), a server span named
// "METHOD /route/pattern" with OpenTelemetry's HTTP attributes
// (http.request.method, url.path, url.query, http.route,
// http.response.status_code, client.address, user_agent.original), an
// error for a 5xx. It is recorded and exported when the shared
// OTTracerProvider is (HSApplication makes one from the OTEL_ variables
// and the OTLPEndpoint setting), and carries the trace on either way. In
// userInfo: the trace id (HSTraceIDKey), the span id (HSSpanIDKey) and the
// traceparent to send on to what it calls (HSTraceparentKey); a mounted
// service's handlers see it as the request's traceparent header. The
// access log writes the trace id.
HTTPSERVERKIT_EXPORT NSString * const HSTraceIDKey;
HTTPSERVERKIT_EXPORT NSString * const HSSpanIDKey;
HTTPSERVERKIT_EXPORT NSString * const HSTraceparentKey;
@class OTTracer;
@interface HSTraceContextStage : HSStage
// Default: HTTPServerKit's, from the shared provider.
@property (nonatomic, strong) OTTracer *tracer;
@end

#pragma mark - Readiness

@class HSCheck;

// One thing a server needs to answer requests: a store, a database, a
// service it calls. Asked each time readiness is: pass or fail the check,
// now or later, from any thread.
@protocol HSReadinessCheck <NSObject>
@property (nonatomic, readonly, copy) NSString *name;  // as the answer names it: store, cache
- (void)checkReadiness:(HSCheck *)check;
@end

// A check under way: passed, or failed with why; the first answer counts.
@interface HSCheck : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (void)pass;
- (void)failWithReason:(NSString *)reason;
@end

// Whether the server should be sent requests: 200, or 503 while it is
// draining (shutting down) or when a check fails or does not answer within
// timeout, with each check's answer ({"status": "ready", "checks":
// {"store": "ok"}}). A load balancer or an orchestrator asks;
// HSHealthHandler says only that the process runs.
@interface HSReadinessHandler : NSObject <HSHandler>
@property (copy) NSArray<id<HSReadinessCheck>> *checks;
- (void)addCheck:(id<HSReadinessCheck>)check;
@property (atomic, getter=isDraining) BOOL draining;
@property (nonatomic) NSTimeInterval timeout;  // default: 5 seconds
@end

NS_ASSUME_NONNULL_END
