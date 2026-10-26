// OTTrace — tracing as OpenTelemetry has it: spans, their context across
// threads and processes (W3C Trace Context), sampling, and processors that
// hand ended spans to an exporter (OTLPExporter.h).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A library makes spans with a tracer of its own name, from the shared
// provider:
//
//   OTTracer *tracer = [OTTracer tracerNamed:@"Billing" version:@"1.0"];
//   OTSpan *span = [tracer startSpanNamed:@"charge" kind:OTSpanKindInternal parent:request.span.context attributes:nil];
//   ...
//   [span end];
//
// Until an application sets the shared provider, spans record nothing, but
// still carry their context, so a trace passes through.
//
// A span made current (-becomeCurrent) is the parent of the spans started
// on that thread with -startSpanNamed:attributes: until it ends; work that
// starts and ends on one thread nests by itself. That is how a library
// that does not link OTelKit (a Core Data store) makes spans: it declares a
// protocol of its own with -startSpanNamed:attributes: (an OTTracer's) and
// -setAttribute:forKey:, -recordError: and -end (an OTSpan's), and is handed
// a tracer by the application (docs/observability.md).

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Which trace a span is in, and which span it is: what goes from process to
// process, as traceparent (00-<trace id>-<span id>-<flags>), with the
// tracestate that came with it (vendors' own, passed on as it came).
@interface OTSpanContext : NSObject <NSCopying>
// Lower-case hex: 32 digits, and 16; never all zero.
- (instancetype)initWithTraceID:(NSString *)traceID spanID:(NSString *)spanID sampled:(BOOL)sampled remote:(BOOL)remote
                     traceState:(nullable NSString *)traceState NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithTraceID:(NSString *)traceID spanID:(NSString *)spanID sampled:(BOOL)sampled remote:(BOOL)remote;
- (instancetype)init NS_UNAVAILABLE;
// A remote context from a traceparent header, or nil when it is not well
// formed (W3C Trace Context, level 1); tracestate kept when it is (at most
// 32 members, 512 characters), dropped when not.
+ (nullable instancetype)contextWithTraceparent:(nullable NSString *)traceparent;
+ (nullable instancetype)contextWithTraceparent:(nullable NSString *)traceparent tracestate:(nullable NSString *)tracestate;
// The same from a request's (or a response's) headers, by any case.
+ (nullable instancetype)contextWithHeaders:(nullable NSDictionary<NSString *, NSString *> *)headers;
@property (nonatomic, readonly, copy) NSString *traceID;
@property (nonatomic, readonly, copy) NSString *spanID;
// Whether the trace is being recorded: the flags' sampled bit.
@property (nonatomic, readonly, getter=isSampled) BOOL sampled;
// From another process.
@property (nonatomic, readonly, getter=isRemote) BOOL remote;
@property (nonatomic, readonly, copy) NSString *traceparent;
// The caller's tracestate, which each span of the trace here carries on.
@property (nonatomic, readonly, copy, nullable) NSString *traceState;
// What to send with a request so its spans join this trace: traceparent,
// and tracestate when there is one.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *propagationHeaders;
@end

/* OTelKit's own: exported where OTelKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef OTELKIT_EXPORT
#define OTELKIT_EXPORT FOUNDATION_EXPORT
#endif

// Random IDs, as a span context has them.
OTELKIT_EXPORT NSString *OTNewTraceID(void);
OTELKIT_EXPORT NSString *OTNewSpanID(void);
// Nanoseconds since 1970, as spans are timed.
OTELKIT_EXPORT uint64_t OTNow(void);

typedef NS_ENUM(NSInteger, OTSpanKind) {
  OTSpanKindInternal = 1,
  OTSpanKindServer = 2,  // a request this process answers
  OTSpanKindClient = 3,  // a request it makes
  OTSpanKindProducer = 4,
  OTSpanKindConsumer = 5,
};

typedef NS_ENUM(NSInteger, OTStatusCode) {
  OTStatusUnset = 0,
  OTStatusOK = 1,
  OTStatusError = 2,
};

@class OTTracer, OTTracerProvider;

// An operation, timed: a name, attributes (NSString, NSNumber for a
// boolean, integer or double, or an NSArray of one of those), events, and
// how it ended. Thread-safe: attributes may be set from any thread, until
// it ends. One that is not recording (not sampled, or no provider) takes
// and keeps nothing, and costs little.
@interface OTSpan : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) OTSpanContext *context;
@property (nonatomic, readonly, copy, nullable) NSString *parentSpanID;
@property (atomic, copy) NSString *name;  // may change before it ends: a route found later
@property (nonatomic, readonly) OTSpanKind kind;
@property (nonatomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, readonly) uint64_t startTime;
@property (atomic, readonly) uint64_t endTime;  // 0 until it ends
@property (atomic, readonly, getter=hasEnded) BOOL ended;
@property (atomic, readonly, copy) NSDictionary<NSString *, id> *attributes;
// Each {name, time (NSNumber, nanoseconds), attributes}.
@property (atomic, readonly, copy) NSArray<NSDictionary *> *events;
@property (atomic, readonly) OTStatusCode status;
@property (atomic, readonly, copy, nullable) NSString *statusMessage;
// The tracer's name and version (OTLP's instrumentation scope), and its
// provider's resource.
@property (nonatomic, readonly, copy) NSString *scopeName;
@property (nonatomic, readonly, copy, nullable) NSString *scopeVersion;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *resource;

// nil removes it.
- (void)setAttribute:(nullable id)value forKey:(NSString *)key;
- (void)addAttributes:(NSDictionary<NSString *, id> *)attributes;
- (void)addEventNamed:(NSString *)name attributes:(nullable NSDictionary<NSString *, id> *)attributes;
- (void)setStatus:(OTStatusCode)status message:(nullable NSString *)message;
// An exception event (exception.type, exception.message) and Error status.
- (void)recordError:(NSError *)error;
// Once; a later call does nothing. Hands it to the provider's processor.
- (void)end;
- (void)endAtTime:(uint64_t)time;

// This thread's current span, which spans started with
// -startSpanNamed:attributes: on it are under; nil for none.
+ (nullable OTSpan *)currentSpan;
// Current on this thread until it ends or resigns. It must end (or resign)
// on the thread it became current on.
- (void)becomeCurrent;
- (void)resignCurrent;
@end

// Whether a new span is recorded. Deciding by the trace ID keeps a trace
// whole: every process that samples by ratio picks the same traces.
@protocol OTSampler <NSObject>
- (BOOL)shouldSampleTraceID:(NSString *)traceID parent:(nullable OTSpanContext *)parent name:(NSString *)name kind:(OTSpanKind)kind;
@end

// A ratio of traces, by trace ID: 1 is every trace, 0 none.
@interface OTRatioSampler : NSObject <OTSampler>
- (instancetype)initWithRatio:(double)ratio NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) double ratio;
@end

// As the parent was, when there is one (a caller that records the trace is
// followed); the root sampler's choice for a new trace.
@interface OTParentBasedSampler : NSObject <OTSampler>
- (instancetype)initWithRootSampler:(id<OTSampler>)root NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) id<OTSampler> root;
@end

// Where ended spans go: an OTLP collector, memory, a file.
@protocol OTSpanExporter <NSObject>
// One batch at a time, on the processor's thread: YES when it was taken.
- (BOOL)exportSpans:(NSArray<OTSpan *> *)spans error:(NSError **)error;
@optional
- (void)shutdown;
@end

// What becomes of ended spans.
@protocol OTSpanProcessor <NSObject>
- (void)spanDidEnd:(OTSpan *)span;
// Everything ended so far, exported, waiting at most timeout: YES when it was.
- (BOOL)forceFlushWithTimeout:(NSTimeInterval)timeout;
- (void)shutdownWithTimeout:(NSTimeInterval)timeout;
@end

// What a processor reports, for an application's logs and metrics: spans
// sent, spans an exporter refused or could not send, spans dropped because
// the queue was full.
@protocol OTExportObserver <NSObject>
@optional
- (void)spanProcessor:(id<OTSpanProcessor>)processor didExportSpans:(NSUInteger)count;
- (void)spanProcessor:(id<OTSpanProcessor>)processor didFailToExportSpans:(NSUInteger)count error:(NSError *)error;
- (void)spanProcessor:(id<OTSpanProcessor>)processor didDropSpans:(NSUInteger)count;
@end

// Ended spans queued, and exported in batches on a thread of its own: when
// a batch is full, every scheduleDelay, and when flushed. A span that ends
// while the queue is full is dropped (and reported), never waited for.
@interface OTBatchSpanProcessor : NSObject <OTSpanProcessor>
- (instancetype)initWithExporter:(id<OTSpanExporter>)exporter NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) id<OTSpanExporter> exporter;
@property (nonatomic) NSUInteger maxQueueSize;     // default 2048
@property (nonatomic) NSUInteger maxBatchSize;     // default 512
@property (nonatomic) NSTimeInterval scheduleDelay;  // default 5 seconds
@property (atomic, weak, nullable) id<OTExportObserver> observer;
@end

// Each span exported as it ends, on the thread that ends it: for tests, and
// for an exporter that only keeps them (OTInMemoryExporter).
@interface OTSimpleSpanProcessor : NSObject <OTSpanProcessor>
- (instancetype)initWithExporter:(id<OTSpanExporter>)exporter NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) id<OTSpanExporter> exporter;
@end

// Spans kept in memory, for tests.
@interface OTInMemoryExporter : NSObject <OTSpanExporter>
@property (atomic, readonly, copy) NSArray<OTSpan *> *spans;
- (void)reset;
@end

// What a process's tracing is: its resource (service.name, service.version,
// host.name, ...), its sampler and its processor. Tracers take theirs from
// the shared provider when a span starts, so a library may make its tracer
// before the application sets it.
@interface OTTracerProvider : NSObject
// One that records nothing, until an application sets another.
@property (class, atomic, strong, null_resettable) OTTracerProvider *sharedProvider;
// Records nothing: spans carry their context only.
- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithResource:(NSDictionary<NSString *, id> *)resource sampler:(id<OTSampler>)sampler
                       processor:(id<OTSpanProcessor>)processor NS_DESIGNATED_INITIALIZER;
// The resource: what is given, with telemetry.sdk.* and, unless given,
// service.name (the process's name), host.name and process.pid.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *resource;
@property (nonatomic, readonly, nullable) id<OTSampler> sampler;
@property (nonatomic, readonly, nullable) id<OTSpanProcessor> processor;
@property (nonatomic, readonly, getter=isRecording) BOOL recording;
- (BOOL)forceFlushWithTimeout:(NSTimeInterval)timeout;
- (void)shutdownWithTimeout:(NSTimeInterval)timeout;

// From OpenTelemetry's environment variables: OTEL_SDK_DISABLED,
// OTEL_TRACES_EXPORTER (otlp; none), OTEL_EXPORTER_OTLP_ENDPOINT or
// OTEL_EXPORTER_OTLP_TRACES_ENDPOINT, OTEL_EXPORTER_OTLP(_TRACES)_HEADERS
// and _TIMEOUT, OTEL_EXPORTER_OTLP(_TRACES)_PROTOCOL (http/json only),
// OTEL_TRACES_SAMPLER (always_on, always_off, traceidratio and their
// parentbased_ forms) with OTEL_TRACES_SAMPLER_ARG, OTEL_SERVICE_NAME,
// OTEL_RESOURCE_ATTRIBUTES, and OTEL_BSP_* for the batch processor. nil
// without an error when tracing is off: no endpoint, or none, or disabled.
// defaults: resource attributes the variables do not set (service.version).
// nil with an error for what it cannot do (a protocol other than
// http/json, an endpoint that is no URL): a program goes on untraced, and
// says so; it never stops for it.
+ (nullable instancetype)providerWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment
                                        defaults:(nullable NSDictionary<NSString *, id> *)defaults
                                           error:(NSError **)error;
@end

// A library's spans: its name and version as OTLP's instrumentation scope.
@interface OTTracer : NSObject
// From the shared provider, whichever it is when a span starts.
+ (OTTracer *)tracerNamed:(NSString *)name version:(nullable NSString *)version;
- (instancetype)initWithName:(NSString *)name version:(nullable NSString *)version
                    provider:(nullable OTTracerProvider *)provider NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy, nullable) NSString *version;
// nil: the shared provider.
@property (nonatomic, readonly, nullable) OTTracerProvider *provider;

// Under parent (a remote one from traceparent, or a local span's context);
// nil begins a trace. Not made current.
- (OTSpan *)startSpanNamed:(NSString *)name kind:(OTSpanKind)kind parent:(nullable OTSpanContext *)parent
                attributes:(nullable NSDictionary<NSString *, id> *)attributes;
// startTime: nanoseconds since 1970 (OTNow()), for work found out later.
- (OTSpan *)startSpanNamed:(NSString *)name kind:(OTSpanKind)kind parent:(nullable OTSpanContext *)parent
                attributes:(nullable NSDictionary<NSString *, id> *)attributes startTime:(uint64_t)startTime;
// Internal, under this thread's current span (a new trace without one), and
// made current until it ends: for work that starts and ends on one thread.
- (OTSpan *)startSpanNamed:(NSString *)name attributes:(nullable NSDictionary<NSString *, id> *)attributes;
@end

OTELKIT_EXPORT NSString * const OTErrorDomain;

NS_ASSUME_NONNULL_END
