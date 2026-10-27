// HSApplication — a server, made from its settings, that an application
// adds its APIs to and changes by overriding a few methods.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   @interface ReportsServer : HSApplication
//   @end
//
//   @implementation ReportsServer
//   - (void)configureModules:(NSMutableArray<id<HSModule>> *)modules
//   {
//     [modules addObject:[[ReportsAPI alloc] init]];    // an HSModule
//   }
//   - (void)configureRouter:(HSRouter *)router
//   {
//     [router insertRoute:[HSRoute routeWithMethod:@"POST" path:@"/webhooks/billing"
//                                         handler:[[BillingWebhook alloc] init]] atIndex:0];
//   }
//   - (void)configurePipeline:(HSPipeline *)pipeline
//   {
//     [pipeline insertStage:[[TenantStage alloc] init] afterStageOfClass:[HSAuthenticationStage class]];
//   }
//   @end
//
//   int main(int argc, const char *argv[])
//   {
//     return HSMain(argc, argv, [ReportsServer class]);
//   }
//
// An API is a module (HSModule): OData's is ODataService's, which
// ODataServerApplication, the application ois-serve is, adds from the
// settings. What -prepare: makes, in order, each handed to its -configure
// method before the next is made:
//
//   the authenticator  from the settings, when they name one
//   the router     GET /health (HealthPath), GET /ready (ReadyPath),
//                  GET /metrics (MetricsPath; on the admin listener when
//                  there is one)
//   the modules    each adds its routes, readiness checks, metrics
//   the pipeline   HSRoutingStage, HSRequestIDStage, HSTraceContextStage
//                  (TraceContext), HSMetricsStage (Metrics),
//                  HSAccessLogStage (AccessLog), HSCORSStage (CORSOrigins),
//                  HSCompressionStage (Compression), HSAuthenticationStage
//                  (with the authenticator), then the router
//   the listener   on Port, loopback unless Localhost is NO; and with
//                  AdminPort, the operators' own
//
// Everything is a public class: an application that would rather build its
// own pipeline does, and hands it to an HSServer.

#pragma once
#import <Foundation/Foundation.h>
#import "HSServer.h"
#import "HSRouter.h"
#import "HSStages.h"
#import "HSObservability.h"
#import "HSLog.h"

@class HSApplication, OTTracerProvider;
@protocol HSAuthenticator;

NS_ASSUME_NONNULL_BEGIN

// The settings a server is made from, and what they make.
//
//   Port          default 8080
//   Localhost     YES (the default): listen on loopback only, for a proxy
//                 on the same machine
//   MaxBodySize   bytes; default 64 MiB
//   MaxBodyInMemory  bytes; a larger request body (or a chunked one) waits
//                 in a temporary file. Default 1 MiB
//   KeepAliveTimeout  seconds a connection waits for its next request
//                 (default 5; 0 closes each after one response)
//   MaxRequestsPerConnection  default 100
//   TrustedUserHeader, TrustedClaimHeaders, ProxySecretHeader,
//   ProxySecretEnvironment   who is asking, from the headers of a proxy
//                 that signs users in (HSTrustedHeaderAuthenticator)
//   JWTIssuer, JWTAudience, JWTKeysURL   or from a JWT access token
//   IntrospectionEndpoint, IntrospectionClientID,
//   IntrospectionSecretEnvironment   or any access token, asked about
//   RequiredScopes  scopes every token needs (JWT or introspection)
//   HealthPath    default /health; empty for none
//   ReadyPath     GET here answers whether to send requests (default
//                 /ready; empty for none): 503 while draining, or when a
//                 readiness check fails
//   AccessLog     YES (the default): a line per request on standard error;
//                 json: the same as a JSON object, for a log collector
//   SlowRequestThreshold  seconds; a slower request is logged at warn
//                 (JSON). Default 1
//   Metrics       YES (the default): requests counted and timed
//                 (HSMetricsStage), at MetricsPath (default /metrics)
//   TraceContext  YES (the default): W3C traceparent taken and passed on,
//                 each request a span (HSTraceContextStage)
//   OTLPEndpoint  where spans go, an OpenTelemetry collector's OTLP/HTTP
//                 base URL (http://collector:4318), as
//                 OTEL_EXPORTER_OTLP_ENDPOINT, which is read too, with the
//                 rest of OpenTelemetry's variables (OTTracerProvider).
//                 Default: none, and nothing is recorded
//   TraceSampleRatio  of new traces, 0 to 1 (a caller's choice is kept
//                 for its own): parentbased_traceidratio. Default 1
//   ServiceName   the traces' service.name. Default: the process's name
//   LogLevel      debug, info (the default), warn, error: what is logged
//                 beside the access log (HSLog)
//   LogFormat     text, or json (the default when AccessLog is json)
//   AdminPort     a second listener for operators: health, readiness and
//                 the metrics, which are then not on Port. Loopback unless
//                 AdminLocalhost is NO. Default: none
//   DrainDelay    seconds between SIGTERM and closing the listener, not
//                 ready meanwhile, for a load balancer to notice (default 0)
//   ShutdownTimeout  seconds requests under way have to finish after
//                 that (default 30)
//   CORSOrigins   origins browsers may call from (a list, or text with
//                 spaces or commas between; * for any): HSCORSStage
//   CORSCredentials  YES: browsers may send cookies and Authorization
//   Compression   YES (the default): gzip for clients that take it
//   Bundles       bundles to load first (the application's code; see
//                 HSMain)
//   Libraries     shared libraries to load first (a store backend's)
//
// A module reads its own (ODataServerConfiguration has the OData
// service's). Each can come from the environment too
// (+environmentVariableForSetting:), as a container is configured:
// HS_PORT=8080 HS_LOCALHOST=NO (OIS_ for ois-serve).
@interface HSConfiguration : NSObject
- (instancetype)initWithSettings:(NSDictionary<NSString *, id> *)settings NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The property list -Config names (or the Config variable), then the
// environment's prefixed variables, then the rest of the command line's
// -Name value pairs: a later one wins.
+ (nullable instancetype)configurationFromCommandLine:(NSError **)error;
// The same from given arguments (-Name value pairs, without the dashes)
// and environment.
+ (nullable instancetype)configurationWithArguments:(NSDictionary<NSString *, id> *)arguments
                                        environment:(NSDictionary<NSString *, NSString *> *)environment
                                              error:(NSError **)error;
// What the environment's variables begin with: HS_ (a subclass says its
// own: OIS_ for ois-serve).
+ (NSString *)environmentPrefix;
// The settings read by name, for their variables' names: a subclass adds
// its own to super's (a name like MaxURLLength needs to be known to be
// found as MAX_URL_LENGTH).
+ (NSArray<NSString *> *)knownSettings;
// A setting's environment variable: the prefix and its name in capitals,
// words apart (Port: HS_PORT, MaxPageSize: HS_MAX_PAGE_SIZE, JWTIssuer:
// HS_JWT_ISSUER). A value that starts with { or [ is read as JSON (a
// dictionary, a list); Bundles and Libraries take a list as paths
// separated by ':'.
+ (NSString *)environmentVariableForSetting:(NSString *)name;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *settings;

// For a subclass's and a module's own settings: one as it is; a flag
// (YES, NO, true, 1...); a number; a list of paths (array, or text with ':'
// between).
- (nullable id)setting:(NSString *)name;
- (BOOL)flag:(NSString *)name otherwise:(BOOL)otherwise;
- (double)number:(NSString *)name otherwise:(double)otherwise;
- (NSArray<NSString *> *)paths:(NSString *)name;

@property (nonatomic, readonly) NSUInteger port;
@property (nonatomic, readonly) BOOL bindToLocalhost;
@property (nonatomic, readonly) NSUInteger maxBodySize;
@property (nonatomic, readonly, copy) NSArray<NSString *> *bundlePaths;
@property (nonatomic, readonly, copy) NSArray<NSString *> *libraryPaths;
@property (nonatomic, readonly, copy) NSString *healthPath;
@property (nonatomic, readonly) BOOL accessLog;
@property (nonatomic, readonly, copy) NSArray<NSString *> *corsOrigins;
@property (nonatomic, readonly) BOOL corsCredentials;
@property (nonatomic, readonly) BOOL compression;
@property (nonatomic, readonly) NSUInteger maxBodyInMemory;
@property (nonatomic, readonly) NSTimeInterval keepAliveTimeout;
@property (nonatomic, readonly) NSUInteger maxRequestsPerConnection;
@property (nonatomic, readonly) BOOL accessLogJSON;
@property (nonatomic, readonly) NSTimeInterval slowRequestThreshold;
@property (nonatomic, readonly) BOOL metrics;
@property (nonatomic, readonly, copy) NSString *metricsPath;
@property (nonatomic, readonly, copy) NSString *readyPath;
@property (nonatomic, readonly) BOOL traceContext;
@property (nonatomic, readonly) NSUInteger adminPort;
@property (nonatomic, readonly) BOOL adminBindToLocalhost;
@property (nonatomic, readonly) NSTimeInterval drainDelay;
@property (nonatomic, readonly) NSTimeInterval shutdownTimeout;
@property (nonatomic, readonly) HSLogLevel logLevel;
@property (nonatomic, readonly) BOOL logJSON;
// What the configuration was read from: OTEL_ variables are taken from it.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *environment;

// Who is asking, as the settings say to find out; nil, without an error,
// when they name no way.
- (nullable id<HSAuthenticator>)authenticatorWithError:(NSError **)error;
// Where traces go, as the settings and OTEL_ variables say; nil, without an
// error, when nowhere; nil with one for settings it cannot use (-prepare:
// warns of those, and runs untraced).
- (nullable OTTracerProvider *)tracerProviderWithError:(NSError **)error;
// What is allowed but probably not meant, one sentence each, once the
// authenticator is made (a subclass, a module adds its own).
@property (nonatomic, readonly, copy) NSArray<NSString *> *warnings;
- (void)addWarning:(NSString *)warning;
@end

// What an API is to an application: given the application once its
// authenticator, metrics, readiness and router are made, it adds what it
// serves -- routes, readiness checks, its own metrics. NO, with the error,
// stops the server from starting.
@protocol HSModule <NSObject>
- (BOOL)addToApplication:(HSApplication *)application error:(NSError **)error;
@optional
// What it serves, a line for run's log (an OData service at its root).
- (NSString *)startupDescription;
@end

@interface HSApplication : NSObject
// The configuration HSMain reads the settings into for this application.
+ (Class)configurationClass;
- (instancetype)initWithConfiguration:(HSConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) HSConfiguration *configuration;
// Principal classes of the bundles HSMain loaded that are no application:
// for an application to look among (ODataServerApplication hands the
// service to those that configure one).
@property (nonatomic, copy) NSArray<Class> *bundleClasses;

// What -prepare: makes, in this order, each handed to its -configure
// method before the next is made.
@property (nonatomic, readonly, strong, nullable) id<HSAuthenticator> authenticator;
// The metrics every stage and handler may add to, and the readiness
// handler checks are added to.
@property (nonatomic, readonly, strong, nullable) HSMetrics *metrics;
@property (nonatomic, readonly, strong, nullable) HSReadinessHandler *readiness;
@property (nonatomic, readonly, strong, nullable) HSRouter *router;
@property (nonatomic, readonly, copy) NSArray<id<HSModule>> *modules;
@property (nonatomic, readonly, strong, nullable) HSPipeline *pipeline;
@property (nonatomic, readonly, strong, nullable) HSServer *server;
// With AdminPort: the operators' listener and its router (health,
// readiness, metrics).
@property (nonatomic, readonly, strong, nullable) HSRouter *adminRouter;
@property (nonatomic, readonly, strong, nullable) HSServer *adminServer;
// The process's tracing while this application runs (made before the
// modules, so their spans are recorded too); its export
// counted in otel_exporter_spans_total, and its failures logged. Flushed
// and put away when it stops.
@property (nonatomic, readonly, strong, nullable) OTTracerProvider *tracerProvider;

// What an application overrides. Each default does nothing.
- (void)configureModules:(NSMutableArray<id<HSModule>> *)modules;
- (void)configureRouter:(HSRouter *)router;
- (void)configurePipeline:(HSPipeline *)pipeline;
- (void)configureServer:(HSServer *)server;
- (void)configureAdminRouter:(HSRouter *)router;

// Makes everything; NO, with the error, for settings it cannot use or a
// module that cannot start. Once only.
- (BOOL)prepare:(NSError **)error;
// Prepares (unless it has) and listens, on Port and AdminPort.
- (BOOL)start:(NSError **)error;
// Not ready any more (readiness answers 503), still serving.
- (void)drain;
// Drains, stops listening, and waits for the requests under way, at most
// timeout seconds: whether they all finished.
- (BOOL)stopWithTimeout:(NSTimeInterval)timeout;
// What run says once listening, a line each.
- (NSArray<NSString *> *)startupLines;
// Starts, and serves until SIGTERM or SIGINT (a second one exits at once);
// then drains for DrainDelay and stops within ShutdownTimeout: the
// process's exit status, 0 on a clean stop. Says what it is doing on
// standard error.
- (int)run;
@end

/* HTTPServerKit's own: exported where HTTPServerKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef HTTPSERVERKIT_EXPORT
#define HTTPSERVERKIT_EXPORT FOUNDATION_EXPORT
#endif

// What an application's main can be: the settings from the command line
// (into applicationClass's configuration class); the bundles they name
// loaded; the application made (of applicationClass, or of the one bundle
// whose principal class is its subclass), the other bundles' principal
// classes its bundleClasses; then run. Exits 1 for settings it cannot use.
HTTPSERVERKIT_EXPORT int HSMain(int argc, const char *_Nonnull argv[_Nonnull], Class applicationClass);

NS_ASSUME_NONNULL_END
