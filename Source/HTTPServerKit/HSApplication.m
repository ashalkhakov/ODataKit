// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSApplication.h"
#import "HSAuthentication.h"
#import "HSObservability.h"
#import "HSLog.h"
#import <OTelKit/OTelKit.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#import "HSMemorySystem.h"


static NSError *HSServerError(NSString *message)
{
  return [NSError errorWithDomain:HSErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static BOOL HSFailWith(NSError **error, NSString *message)
{
  if (error) *error = HSServerError(message);
  return NO;
}

static NSURL *HSURL(id text)
{
  if (![text isKindOfClass:[NSString class]] || ![text length]) return nil;
  return [text rangeOfString:@"://"].location != NSNotFound ? [NSURL URLWithString:text] : [NSURL fileURLWithPath:text];
}

#pragma mark - Configuration

@implementation HSConfiguration {
  NSMutableArray<NSString *> *_warnings;
  NSDictionary<NSString *, NSString *> *_environment;
}

- (instancetype)initWithSettings:(NSDictionary *)settings
{
  self = [super init];
  if (!self) return nil;
  _settings = [settings copy] ?: @{};
  _warnings = [NSMutableArray array];
  return self;
}

+ (instancetype)configurationFromCommandLine:(NSError **)error
{
  NSDictionary *arguments = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain];
  return [self configurationWithArguments:arguments environment:[NSProcessInfo processInfo].environment error:error];
}

+ (NSString *)environmentPrefix
{
  return @"HS_";
}

// Every setting this class reads, for the environment's names of them.
+ (NSArray<NSString *> *)knownSettings
{
  return @[ @"Config", @"Port", @"Localhost", @"MaxBodySize", @"TrustedUserHeader", @"TrustedClaimHeaders", @"ProxySecretHeader",
            @"ProxySecretEnvironment", @"JWTIssuer", @"JWTAudience", @"JWTKeysURL", @"IntrospectionEndpoint",
            @"IntrospectionClientID", @"IntrospectionSecretEnvironment", @"RequiredScopes", @"HealthPath",
            @"AccessLog", @"CORSOrigins", @"CORSCredentials", @"Compression", @"MaxBodyInMemory", @"KeepAliveTimeout",
            @"MaxRequestsPerConnection", @"SlowRequestThreshold", @"Metrics", @"MetricsPath", @"ReadyPath", @"TraceContext",
            @"AdminPort", @"AdminLocalhost", @"DrainDelay", @"ShutdownTimeout", @"Bundles", @"Libraries", @"LogLevel",
            @"LogFormat", @"OTLPEndpoint", @"TraceSampleRatio", @"ServiceName" ];
}

+ (NSString *)environmentVariableForSetting:(NSString *)name
{
  // A new word at a capital after a small letter (MaxPage), or at the last
  // capital of a run before a small letter (JWTIssuer, MaxURLLength).
  NSMutableString *variable = [NSMutableString stringWithString:[self environmentPrefix]];
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    BOOL upper = c >= 'A' && c <= 'Z';
    if (upper && i > 0) {
      unichar before = [name characterAtIndex:i - 1];
      unichar after = i + 1 < name.length ? [name characterAtIndex:i + 1] : 0;
      BOOL lowerBefore = (before >= 'a' && before <= 'z') || (before >= '0' && before <= '9');
      BOOL upperBefore = before >= 'A' && before <= 'Z';
      BOOL lowerAfter = after >= 'a' && after <= 'z';
      if (lowerBefore || (upperBefore && lowerAfter)) [variable appendString:@"_"];
    }
    [variable appendFormat:@"%C", (unichar)(upper || !(c >= 'a' && c <= 'z') ? c : c - 32)];
  }
  return variable;
}

// A prefixed variable not known by name: its words, each capitalized
// (HS_REPORT_TITLE: ReportTitle), for an application's own settings.
static NSString *HSSettingOfVariable(NSString *variable, NSString *prefix)
{
  NSMutableString *name = [NSMutableString string];
  for (NSString *word in [[variable substringFromIndex:prefix.length] componentsSeparatedByString:@"_"]) {
    if (!word.length) continue;
    [name appendString:[word substringToIndex:1].uppercaseString];
    [name appendString:[word substringFromIndex:1].lowercaseString];
  }
  return name;
}

static id HSEnvironmentValue(NSString *text)
{
  NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["]) {
    id json = [NSJSONSerialization JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (json) return json;
  }
  return text;
}

+ (instancetype)configurationWithArguments:(NSDictionary *)arguments environment:(NSDictionary *)environment error:(NSError **)error
{
  NSMutableDictionary *fromEnvironment = [NSMutableDictionary dictionary];
  NSMutableDictionary *known = [NSMutableDictionary dictionary];
  for (NSString *name in [self knownSettings]) known[[self environmentVariableForSetting:name]] = name;
  NSString *prefix = [self environmentPrefix];
  for (NSString *variable in environment) {
    if (![variable hasPrefix:prefix] || variable.length <= prefix.length) continue;
    fromEnvironment[known[variable] ?: HSSettingOfVariable(variable, prefix)] = HSEnvironmentValue(environment[variable]);
  }

  NSMutableDictionary *settings = [NSMutableDictionary dictionary];
  NSString *config = arguments[@"Config"] ?: fromEnvironment[@"Config"];
  if (config) {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:config];
    if (!file) {
      HSFailWith(error, [NSString stringWithFormat:@"%@ is not a property list", config]);
      return nil;
    }
    [settings addEntriesFromDictionary:file];
  }
  [settings addEntriesFromDictionary:fromEnvironment];
  [settings addEntriesFromDictionary:arguments];
  HSConfiguration *configuration = [[self alloc] initWithSettings:settings];
  configuration->_environment = [environment copy];
  return configuration;
}

- (NSDictionary<NSString *, NSString *> *)environment
{
  return _environment ?: [NSProcessInfo processInfo].environment;
}

- (id)setting:(NSString *)name
{
  return self.settings[name];
}

- (double)number:(NSString *)name otherwise:(double)otherwise
{
  id value = [self setting:name];
  return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : otherwise;
}

- (void)addWarning:(NSString *)warning
{
  @synchronized (self) {
    [_warnings addObject:warning];
  }
}

- (BOOL)flag:(NSString *)name otherwise:(BOOL)otherwise
{
  id value = [self setting:name];
  return value ? [value boolValue] : otherwise;
}

- (NSUInteger)port
{
  id value = [self setting:@"Port"];
  return value ? (NSUInteger)[value integerValue] : 8080;
}

- (BOOL)bindToLocalhost
{
  return [self flag:@"Localhost" otherwise:YES];
}

- (NSUInteger)maxBodySize
{
  id value = [self setting:@"MaxBodySize"];
  return value ? (NSUInteger)[value integerValue] : 64 * 1024 * 1024;
}

// A list of paths: an array, or text, ':' between paths.
- (NSArray<NSString *> *)paths:(NSString *)name
{
  id paths = [self setting:name];
  if ([paths isKindOfClass:[NSString class]]) {
    NSMutableArray *split = [NSMutableArray array];
    for (NSString *path in [paths componentsSeparatedByString:@":"]) {
      if (path.length) [split addObject:path];
    }
    return split;
  }
  return [paths isKindOfClass:[NSArray class]] ? paths : @[];
}

- (NSArray<NSString *> *)bundlePaths
{
  return [self paths:@"Bundles"];
}

- (NSArray<NSString *> *)libraryPaths
{
  return [self paths:@"Libraries"];
}

- (NSString *)healthPath
{
  id path = [self setting:@"HealthPath"];
  return [path isKindOfClass:[NSString class]] ? path : @"/health";
}

- (BOOL)accessLog
{
  return self.accessLogJSON || [self flag:@"AccessLog" otherwise:YES];
}

- (BOOL)accessLogJSON
{
  id value = [self setting:@"AccessLog"];
  return [value isKindOfClass:[NSString class]] && [value caseInsensitiveCompare:@"json"] == NSOrderedSame;
}

- (NSTimeInterval)slowRequestThreshold
{
  id value = [self setting:@"SlowRequestThreshold"];
  return value ? [value doubleValue] : 1;
}

- (BOOL)metrics
{
  return [self flag:@"Metrics" otherwise:YES];
}

- (NSString *)metricsPath
{
  id path = [self setting:@"MetricsPath"];
  return [path isKindOfClass:[NSString class]] ? path : @"/metrics";
}

- (NSString *)readyPath
{
  id path = [self setting:@"ReadyPath"];
  return [path isKindOfClass:[NSString class]] ? path : @"/ready";
}

- (BOOL)traceContext
{
  return [self flag:@"TraceContext" otherwise:YES];
}

- (NSUInteger)adminPort
{
  return (NSUInteger)[self number:@"AdminPort" otherwise:0];
}

- (BOOL)adminBindToLocalhost
{
  return [self flag:@"AdminLocalhost" otherwise:YES];
}

- (NSTimeInterval)drainDelay
{
  return [[self setting:@"DrainDelay"] doubleValue];
}

- (NSTimeInterval)shutdownTimeout
{
  id value = [self setting:@"ShutdownTimeout"];
  return value ? [value doubleValue] : 30;
}

- (NSArray<NSString *> *)corsOrigins
{
  id origins = [self setting:@"CORSOrigins"];
  if ([origins isKindOfClass:[NSArray class]]) return origins;
  NSMutableArray *split = [NSMutableArray array];
  if ([origins isKindOfClass:[NSString class]]) {
    for (NSString *origin in [origins componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ,"]]) {
      if (origin.length) [split addObject:origin];
    }
  }
  return split;
}

- (BOOL)corsCredentials
{
  return [self flag:@"CORSCredentials" otherwise:NO];
}

- (BOOL)compression
{
  return [self flag:@"Compression" otherwise:YES];
}

- (NSUInteger)maxBodyInMemory
{
  id value = [self setting:@"MaxBodyInMemory"];
  return value ? (NSUInteger)[value integerValue] : 1024 * 1024;
}

- (NSTimeInterval)keepAliveTimeout
{
  id value = [self setting:@"KeepAliveTimeout"];
  return value ? [value doubleValue] : 5;
}

- (NSUInteger)maxRequestsPerConnection
{
  id value = [self setting:@"MaxRequestsPerConnection"];
  return value ? (NSUInteger)[value integerValue] : 100;
}

- (NSArray<NSString *> *)warnings
{
  return [_warnings copy];
}

- (HSLogLevel)logLevel
{
  NSNumber *level = [HSLog levelNamed:[self setting:@"LogLevel"]];
  return level ? (HSLogLevel)level.integerValue : HSLogLevelInfo;
}

- (BOOL)logJSON
{
  id value = [self setting:@"LogFormat"];
  if ([value isKindOfClass:[NSString class]]) return [value caseInsensitiveCompare:@"json"] == NSOrderedSame;
  return self.accessLogJSON;
}

- (OTTracerProvider *)tracerProviderWithError:(NSError **)error
{
  // The settings as the OTEL_ variables they stand for, over the
  // environment's own.
  NSMutableDictionary *environment = [NSMutableDictionary dictionary];
  NSDictionary *given = self.environment;
  for (NSString *name in given) {
    if ([name hasPrefix:@"OTEL_"]) environment[name] = given[name];
  }
  id endpoint = [self setting:@"OTLPEndpoint"];
  if ([endpoint isKindOfClass:[NSString class]] && [endpoint length]) {
    environment[@"OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint;
    // The setting is OTLP over HTTP as JSON, whatever the environment's
    // variables were for.
    for (NSString *name in @[ @"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", @"OTEL_TRACES_EXPORTER", @"OTEL_EXPORTER_OTLP_PROTOCOL",
                              @"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", @"OTEL_SDK_DISABLED" ]) {
      [environment removeObjectForKey:name];
    }
  }
  id ratio = [self setting:@"TraceSampleRatio"];
  if ([ratio respondsToSelector:@selector(doubleValue)]) {
    environment[@"OTEL_TRACES_SAMPLER"] = @"parentbased_traceidratio";
    environment[@"OTEL_TRACES_SAMPLER_ARG"] = [NSString stringWithFormat:@"%g", [ratio doubleValue]];
  }
  id service = [self setting:@"ServiceName"];
  if ([service isKindOfClass:[NSString class]] && [service length]) environment[@"OTEL_SERVICE_NAME"] = service;
  NSDictionary *defaults = @{ @"service.name": [NSProcessInfo processInfo].processName ?: @"server", @"service.version": HSVersion };
  NSError *failure = nil;
  OTTracerProvider *provider = [OTTracerProvider providerWithEnvironment:environment defaults:defaults error:&failure];
  if (error) *error = failure;
  return provider;
}

// A secret is taken from the environment, not the command line, where
// anyone on the machine can read it.
- (NSString *)secretIn:(NSString *)setting
{
  // getenv, not NSProcessInfo: gnustep-base's environment is the one the
  // process started with.
  NSString *variable = [self setting:setting];
  const char *value = [variable isKindOfClass:[NSString class]] && variable.length ? getenv(variable.UTF8String) : NULL;
  return value ? [NSString stringWithUTF8String:value] : nil;
}

- (id<HSAuthenticator>)authenticatorWithError:(NSError **)error
{
  NSString *userHeader = [self setting:@"TrustedUserHeader"];
  NSString *secretHeader = [self setting:@"ProxySecretHeader"];
  NSString *issuer = [self setting:@"JWTIssuer"];
  NSString *introspection = [self setting:@"IntrospectionEndpoint"];
  if ((userHeader.length > 0) + (issuer.length > 0) + (introspection.length > 0) > 1) {
    HSFailWith(error, @"one of -TrustedUserHeader, -JWTIssuer and -IntrospectionEndpoint: who is asking is known one way");
    return nil;
  }
  if (secretHeader.length && !userHeader.length) {
    HSFailWith(error, @"-ProxySecretHeader without -TrustedUserHeader: name the header the proxy puts the user in");
    return nil;
  }
  id scopes = [self setting:@"RequiredScopes"];
  if ([scopes isKindOfClass:[NSString class]]) scopes = [scopes componentsSeparatedByString:@" "];
  NSSet *requiredScopes = [scopes isKindOfClass:[NSArray class]] ? [NSSet setWithArray:scopes] : nil;

  if (userHeader.length) {
    HSTrustedHeaderAuthenticator *proxy = [[HSTrustedHeaderAuthenticator alloc] initWithSubjectHeader:userHeader];
    if ([[self setting:@"TrustedClaimHeaders"] isKindOfClass:[NSDictionary class]]) proxy.claimHeaders = [self setting:@"TrustedClaimHeaders"];
    if (secretHeader.length) {
      NSString *secret = [self secretIn:@"ProxySecretEnvironment"];
      if (!secret.length) {
        HSFailWith(error, @"-ProxySecretHeader needs the secret in the environment variable -ProxySecretEnvironment names");
        return nil;
      }
      proxy.secretHeader = secretHeader;
      proxy.secret = secret;
    } else if (!self.bindToLocalhost) {
      [_warnings addObject:[NSString stringWithFormat:@"anyone who reaches port %lu can send %@; set -ProxySecretHeader, or listen on loopback",
                                                      (unsigned long)self.port, userHeader]];
    }
    return proxy;
  }
  if (issuer.length) {
    NSString *audience = [self setting:@"JWTAudience"];
    HSJWTAuthenticator *jwt = [[HSJWTAuthenticator alloc] initWithIssuer:issuer audience:audience];
    if (!audience) [_warnings addObject:[NSString stringWithFormat:@"no -JWTAudience: a token %@ issued for anything is taken", issuer]];
    if ([self setting:@"JWTKeysURL"]) jwt.keySetURL = HSURL([self setting:@"JWTKeysURL"]);
    jwt.requiredScopes = requiredScopes;
    return jwt;
  }
  if (introspection.length) {
    NSString *secret = [self secretIn:@"IntrospectionSecretEnvironment"];
    NSString *client = [self setting:@"IntrospectionClientID"];
    if (!client.length || !secret.length) {
      HSFailWith(error, @"-IntrospectionEndpoint needs -IntrospectionClientID, and the secret in the environment variable "
                         @"-IntrospectionSecretEnvironment names");
      return nil;
    }
    HSTokenIntrospectionAuthenticator *introspector =
      [[HSTokenIntrospectionAuthenticator alloc] initWithEndpoint:HSURL(introspection) clientID:client clientSecret:secret];
    introspector.requiredScopes = requiredScopes;
    return introspector;
  }
  if (error) *error = nil;
  return nil;
}

@end

#pragma mark - The application

@interface HSApplication ()
@property (nonatomic, readwrite, strong, nullable) id<HSAuthenticator> authenticator;
@property (nonatomic, readwrite, copy) NSArray<id<HSModule>> *modules;
@property (nonatomic, readwrite, strong, nullable) HSRouter *router;
@property (nonatomic, readwrite, strong, nullable) HSPipeline *pipeline;
@property (nonatomic, readwrite, strong, nullable) HSServer *server;
@property (nonatomic, readwrite, strong, nullable) HSMetrics *metrics;
@property (nonatomic, readwrite, strong, nullable) HSReadinessHandler *readiness;
@property (nonatomic, readwrite, strong, nullable) HSRouter *adminRouter;
@property (nonatomic, readwrite, strong, nullable) HSServer *adminServer;
@property (nonatomic, readwrite, strong, nullable) OTTracerProvider *tracerProvider;
@end

@interface HSApplication () <OTExportObserver>
@end

@implementation HSApplication {
  NSDate *_lastExportWarning;
}

+ (Class)configurationClass
{
  return [HSConfiguration class];
}

- (instancetype)initWithConfiguration:(HSConfiguration *)configuration
{
  self = [super init];
  if (!self) return nil;
  _configuration = configuration;
  _modules = @[];
  _bundleClasses = @[];
  return self;
}

- (void)configureModules:(NSMutableArray<id<HSModule>> *)modules
{
}

- (void)configureRouter:(HSRouter *)router
{
}

- (void)configurePipeline:(HSPipeline *)pipeline
{
}

- (void)configureServer:(HSServer *)server
{
}

- (void)configureAdminRouter:(HSRouter *)router
{
}

- (BOOL)prepare:(NSError **)error
{
  if (self.server) return YES;
  HSConfiguration *configuration = self.configuration;
  // Libraries before anything uses what they bring (a store backend, which
  // registers itself when loaded).
  for (NSString *path in configuration.libraryPaths) {
    if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
      const char *why = dlerror();
      return HSFailWith(error, [NSString stringWithFormat:@"%@ does not load: %s", path, why ? why : "?"]);
    }
  }
  HSLog *log = [HSLog sharedLog];
  log.level = configuration.logLevel;
  log.format = configuration.logJSON ? HSLogFormatJSON : HSLogFormatText;

  NSError *failure = nil;
  id<HSAuthenticator> authenticator = [configuration authenticatorWithError:&failure];
  if (failure) {
    if (error) *error = failure;
    return NO;
  }
  self.authenticator = authenticator;

  HSMetrics *metrics = [[HSMetrics alloc] init];
  self.metrics = metrics;
  if ([(NSObject *)authenticator respondsToSelector:@selector(setMetrics:)]) [(id)authenticator setMetrics:metrics];

  // Traces, when the settings or the OTEL_ variables name where to send
  // them: the process's provider from now on.
  // Settings tracing cannot use do not stop the server (OpenTelemetry's
  // rule: telemetry never takes the program down): it runs untraced, and
  // says why. Another tool's OTEL_ variables (a build's, gRPC to a socket)
  // may be what it found.
  failure = nil;
  OTTracerProvider *provider = [configuration tracerProviderWithError:&failure];
  if (failure) [configuration addWarning:[@"not tracing: " stringByAppendingString:failure.localizedDescription]];
  if (provider) {
    if ([provider.processor isKindOfClass:[OTBatchSpanProcessor class]]) [(OTBatchSpanProcessor *)provider.processor setObserver:self];
    self.tracerProvider = provider;
    OTTracerProvider.sharedProvider = provider;
  }
  self.readiness = [[HSReadinessHandler alloc] init];

  // Health and readiness on every listener, for whatever asks; metrics on
  // the admin listener when there is one, else here.
  NSMutableArray *operational = [NSMutableArray array];
  if (configuration.healthPath.length) {
    [operational addObject:[HSRoute routeWithMethod:@"GET" path:configuration.healthPath handler:[[HSHealthHandler alloc] init]]];
  }
  if (configuration.readyPath.length) {
    [operational addObject:[HSRoute routeWithMethod:@"GET" path:configuration.readyPath handler:self.readiness]];
  }
  HSRoute *metricsRoute = configuration.metrics && configuration.metricsPath.length
      ? [HSRoute routeWithMethod:@"GET" path:configuration.metricsPath handler:[[HSMetricsHandler alloc] initWithMetrics:metrics]]
      : nil;
  HSRouter *router = [[HSRouter alloc] init];
  router.routes = operational;
  if (metricsRoute && !configuration.adminPort) [router addRoute:metricsRoute];
  self.router = router;

  // The APIs it serves: each adds its routes, checks and the rest.
  NSMutableArray<id<HSModule>> *modules = [NSMutableArray array];
  [self configureModules:modules];
  self.modules = modules;
  for (id<HSModule> module in modules) {
    if (![module addToApplication:self error:error]) return NO;
  }
  [self configureRouter:router];

  NSMutableArray *stages = [NSMutableArray arrayWithObject:[[HSRoutingStage alloc] initWithRouter:router]];
  [stages addObject:[[HSRequestIDStage alloc] init]];
  if (configuration.traceContext) [stages addObject:[[HSTraceContextStage alloc] init]];
  if (configuration.metrics) [stages addObject:[[HSMetricsStage alloc] initWithMetrics:metrics]];
  if (configuration.accessLog) {
    HSAccessLogStage *log = [[HSAccessLogStage alloc] init];
    log.format = configuration.accessLogJSON ? HSAccessLogJSON : HSAccessLogText;
    log.slowRequestThreshold = configuration.slowRequestThreshold;
    [stages addObject:log];
  }
  if (configuration.corsOrigins.count) {
    HSCORSStage *cors = [[HSCORSStage alloc] initWithAllowedOrigins:configuration.corsOrigins];
    cors.allowsCredentials = configuration.corsCredentials;
    [stages addObject:cors];
  }
  if (configuration.compression) [stages addObject:[[HSCompressionStage alloc] init]];
  if (authenticator) [stages addObject:[[HSAuthenticationStage alloc] initWithAuthenticator:authenticator]];
  HSPipeline *pipeline = [[HSPipeline alloc] initWithStages:stages handler:router];
  self.pipeline = pipeline;
  [self configurePipeline:pipeline];

  HSServer *server = [[HSServer alloc] initWithHandler:pipeline];
  server.bindToLocalhost = configuration.bindToLocalhost;
  server.maxBodySize = configuration.maxBodySize;
  server.maxBodyInMemory = configuration.maxBodyInMemory;
  server.keepAliveTimeout = configuration.keepAliveTimeout;
  server.maxRequestsPerConnection = configuration.maxRequestsPerConnection;
  self.server = server;
  [self configureServer:server];

  // The admin listener: what is for operators, not clients, apart.
  if (configuration.adminPort) {
    HSRouter *admin = [[HSRouter alloc] init];
    admin.routes = operational;
    if (metricsRoute) [admin addRoute:metricsRoute];
    self.adminRouter = admin;
    [self configureAdminRouter:admin];
    HSServer *adminServer = [[HSServer alloc] initWithHandler:admin];
    adminServer.bindToLocalhost = configuration.adminBindToLocalhost;
    adminServer.maxBodySize = 64 * 1024;
    self.adminServer = adminServer;
  }
  return YES;
}

- (BOOL)start:(NSError **)error
{
  if (![self prepare:error]) return NO;
  if (![self.server startOnPort:self.configuration.port error:error]) return NO;
  if (self.adminServer && ![self.adminServer startOnPort:self.configuration.adminPort error:error]) {
    [self.server stop];
    return NO;
  }
  return YES;
}

- (void)drain
{
  self.readiness.draining = YES;
}

- (BOOL)stopWithTimeout:(NSTimeInterval)timeout
{
  [self drain];
  [self.server stop];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (self.server.requestsInFlight > 0 && [deadline timeIntervalSinceNow] > 0) [NSThread sleepForTimeInterval:0.05];
  BOOL finished = self.server.requestsInFlight == 0;
  [self.adminServer stop];
  // The last spans out, and the process's tracing as it was.
  OTTracerProvider *provider = self.tracerProvider;
  if (provider) {
    [provider shutdownWithTimeout:MAX(MIN([deadline timeIntervalSinceNow], 5), 1)];
    if (OTTracerProvider.sharedProvider == provider) OTTracerProvider.sharedProvider = nil;
    self.tracerProvider = nil;
  }
  return finished;
}

#pragma mark Export

- (void)countSpans:(NSUInteger)count outcome:(NSString *)outcome
{
  [self.metrics incrementCounter:@"otel_exporter_spans_total" help:@"Spans handed to the exporter, by outcome: exported, failed, dropped."
                          labels:@{ @"outcome": outcome } by:count];
}

// At most a warning a minute: a collector away for an hour is not 720 lines.
- (void)warnOfExport:(NSString *)message
{
  @synchronized (self) {
    if (_lastExportWarning && -[_lastExportWarning timeIntervalSinceNow] < 60) return;
    _lastExportWarning = [NSDate date];
  }
  HSLogMessage(HSLogLevelWarn, @"OTelKit", nil, @"%@", message);
}

- (void)spanProcessor:(id<OTSpanProcessor>)processor didExportSpans:(NSUInteger)count
{
  [self countSpans:count outcome:@"exported"];
}

- (void)spanProcessor:(id<OTSpanProcessor>)processor didFailToExportSpans:(NSUInteger)count error:(NSError *)error
{
  [self countSpans:count outcome:@"failed"];
  [self warnOfExport:[NSString stringWithFormat:@"%lu spans not exported: %@", (unsigned long)count, error.localizedDescription]];
}

- (void)spanProcessor:(id<OTSpanProcessor>)processor didDropSpans:(NSUInteger)count
{
  [self countSpans:count outcome:@"dropped"];
  [self warnOfExport:[NSString stringWithFormat:@"%lu spans dropped: the export queue was full", (unsigned long)count]];
}

- (NSArray<NSString *> *)startupLines
{
  NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"on port %lu%s", (unsigned long)self.server.port,
                                                                                      self.server.bindToLocalhost ? " (loopback)" : ""]];
  for (id<HSModule> module in self.modules) {
    if ([module respondsToSelector:@selector(startupDescription)]) [lines addObject:[module startupDescription]];
  }
  if (self.adminServer) {
    [lines addObject:[NSString stringWithFormat:@"admin (health, readiness, metrics) on port %lu%s", (unsigned long)self.adminServer.port,
                                                self.adminServer.bindToLocalhost ? " (loopback)" : ""]];
  }
  OTTracerProvider *provider = self.tracerProvider;
  id<OTSpanProcessor> processor = provider.processor;
  if (provider) {
    id exporter = [processor isKindOfClass:[OTBatchSpanProcessor class]] ? (id)[(OTBatchSpanProcessor *)processor exporter] : (id)processor;
    NSString *to = [exporter isKindOfClass:[OTLPExporter class]] ? [(OTLPExporter *)exporter endpoint].absoluteString : [exporter description];
    [lines addObject:[NSString stringWithFormat:@"traces of %@ to %@ (%@)", provider.resource[@"service.name"], to, provider.sampler]];
  }
  return lines;
}

// SIGTERM or SIGINT, from a queue of their own: the main thread is told.
static volatile sig_atomic_t HSStopSignal;

- (int)run
{
  NSString *name = [NSProcessInfo processInfo].processName;
  HSLog *log = [HSLog sharedLog];
  NSError *error = nil;
  if (![self prepare:&error]) {
    [log log:HSLogLevelError component:name message:error.localizedDescription fields:nil];
    return 1;
  }
  HSConfiguration *configuration = self.configuration;
  for (NSString *warning in configuration.warnings) [log log:HSLogLevelWarn component:name message:warning fields:nil];

  // The signals are taken before listening, so one that comes early stops
  // the server rather than the process. (Kept in a static array: on GNUstep
  // a dispatch object is no Objective-C object a collection can hold.)
  static dispatch_source_t sources[2];
  int signals[2] = { SIGTERM, SIGINT };
  for (int i = 0; i < 2; i++) {
    int signo = signals[i];
    signal(signo, SIG_IGN);
    sources[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)signo, 0, dispatch_get_global_queue(0, 0));
    dispatch_source_set_event_handler(sources[i], ^{
      if (HSStopSignal) _exit(130);  // a second one: now
      HSStopSignal = signo;
    });
    dispatch_resume(sources[i]);
  }

  if (![self start:&error]) {
    [log log:HSLogLevelError component:name message:[@"cannot listen: " stringByAppendingString:error.localizedDescription] fields:nil];
    return 1;
  }
  for (NSString *line in [self startupLines]) [log log:HSLogLevelInfo component:name message:line fields:nil];

  // The main thread runs its run loop (and so the main queue) until a
  // signal comes; a timer keeps the loop from finding nothing to wait for.
  NSTimer *keeper = [NSTimer scheduledTimerWithTimeInterval:3600 target:self selector:@selector(description) userInfo:nil repeats:YES];
  // Quiet a minute after requests came: what they freed given back to the
  // system (glibc keeps it otherwise, and a server that once answered a
  // large sync would look that size for ever).
  NSUInteger answered = 0;
  NSDate *checked = [NSDate date];
  while (!HSStopSignal) {
    @autoreleasepool {
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
      if (-checked.timeIntervalSinceNow >= 60) {
        checked = [NSDate date];
        NSUInteger now = self.server.requestsAnswered;
        if (now != answered && !self.server.requestsInFlight) {
          answered = now;
          HSSystemReturnFreedMemory();
        }
      }
    }
  }
  [keeper invalidate];

  // Draining: not ready, so a load balancer stops sending; a while for it to
  // notice; then no new connections, and those under way finished.
  [log log:HSLogLevelInfo component:name message:@"draining" fields:nil];
  [self drain];
  if (configuration.drainDelay > 0) [NSThread sleepForTimeInterval:configuration.drainDelay];
  BOOL finished = [self stopWithTimeout:configuration.shutdownTimeout];
  if (!finished) {
    [log log:HSLogLevelError component:name
         message:[NSString stringWithFormat:@"stopped with %lu requests unanswered after %.0f s", (unsigned long)self.server.requestsInFlight,
                                            configuration.shutdownTimeout] fields:nil];
    return 1;
  }
  [log log:HSLogLevelInfo component:name message:@"stopped" fields:nil];
  return 0;
}

@end

int HSMain(int argc, const char *argv[], Class applicationClass)
{
  // Before any thread: as few allocator arenas as a server needs.
  HSSystemLimitArenas();
  @autoreleasepool {
    NSString *name = [NSProcessInfo processInfo].processName;
    NSError *error = nil;
    Class chosen = applicationClass ?: [HSApplication class];
    HSConfiguration *configuration = [[chosen configurationClass] configurationFromCommandLine:&error];
    if (!configuration) {
      fprintf(stderr, "%s: %s\n", name.UTF8String, error.localizedDescription.UTF8String);
      return 1;
    }
    // The application's own code, and what it needs loaded first.
    NSMutableArray<Class> *others = [NSMutableArray array];
    for (NSString *path in configuration.bundlePaths) {
      NSBundle *bundle = [NSBundle bundleWithPath:path];
      if (![bundle loadAndReturnError:&error]) {
        fprintf(stderr, "%s: %s does not load: %s\n", name.UTF8String, path.UTF8String, error.localizedDescription.UTF8String);
        return 1;
      }
      Class principal = bundle.principalClass;
      if (principal && [principal isSubclassOfClass:chosen] && principal != chosen) {
        if (chosen != applicationClass) {
          fprintf(stderr, "%s: %s is an application too, and there is one already (%s)\n", name.UTF8String, path.UTF8String,
                  NSStringFromClass(chosen).UTF8String);
          return 1;
        }
        chosen = principal;
      } else if (principal) {
        [others addObject:principal];
      }
    }
    HSApplication *application = [[chosen alloc] initWithConfiguration:configuration];
    application.bundleClasses = others;
    return [application run];
  }
}
