// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSObservability.h"
#import "HSRouter.h"
#import "HSStages.h"
#import "HSAuthentication.h"
#import <OTelKit/OTTrace.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#if defined(_WIN32)
// Lean: COM's headers define interface, which is Objective-C's.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#endif
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#ifndef HTTPSERVERKIT_VERSION
#define HTTPSERVERKIT_VERSION "dev"
#endif
NSString * const HSVersion = @HTTPSERVERKIT_VERSION;

NSString * const HSTraceIDKey = @"HS.traceID";
NSString * const HSSpanIDKey = @"HS.spanID";
NSString * const HSTraceparentKey = @"HS.traceparent";
static NSString * const HSMetricsStartKey = @"HS.metricsStarted";

// Seconds on a clock that only goes forward, for durations.
static double HSMonotonicSeconds(void)
{
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

#pragma mark - Metrics

typedef NS_ENUM(NSInteger, HSMetricKind) { HSMetricCounter, HSMetricGauge, HSMetricHistogram };

@interface HSMetricSeries : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *labels;
@property (nonatomic) double value;                       // a counter's or gauge's; a histogram's sum
@property (nonatomic) unsigned long long count;           // a histogram's
@property (nonatomic, strong) NSMutableArray<NSNumber *> *bucketCounts;  // a histogram's, per bound, not cumulative
@end

@implementation HSMetricSeries
@end

@interface HSMetricFamily : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *help;
@property (nonatomic) HSMetricKind kind;
@property (nonatomic, copy) NSArray<NSNumber *> *buckets;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HSMetricSeries *> *series;
@end

@implementation HSMetricFamily
@end

static double HSProcessStart;

@implementation HSMetrics {
  NSMutableDictionary<NSString *, HSMetricFamily *> *_families;
}

+ (void)initialize
{
  if (self == [HSMetrics class]) HSProcessStart = [[NSDate date] timeIntervalSince1970];
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _families = [NSMutableDictionary dictionary];
  return self;
}

static NSString *HSLabelKey(NSDictionary<NSString *, NSString *> *labels)
{
  NSMutableString *key = [NSMutableString string];
  for (NSString *name in [labels.allKeys sortedArrayUsingSelector:@selector(compare:)]) [key appendFormat:@"%@=%@\x1f", name, labels[name]];
  return key;
}

// The series of a family, made on first use; nil when the name is another kind.
- (HSMetricSeries *)series:(NSString *)name help:(NSString *)help kind:(HSMetricKind)kind labels:(NSDictionary *)labels buckets:(NSArray *)buckets
{
  HSMetricFamily *family = _families[name];
  if (!family) {
    family = [[HSMetricFamily alloc] init];
    family.name = name;
    family.help = help;
    family.kind = kind;
    family.buckets = buckets;
    family.series = [NSMutableDictionary dictionary];
    _families[name] = family;
  }
  if (family.kind != kind) return nil;
  NSString *key = HSLabelKey(labels ?: @{});
  HSMetricSeries *series = family.series[key];
  if (!series) {
    series = [[HSMetricSeries alloc] init];
    series.labels = labels ?: @{};
    if (kind == HSMetricHistogram) {
      series.bucketCounts = [NSMutableArray array];
      for (NSUInteger i = 0; i < family.buckets.count; i++) [series.bucketCounts addObject:@0];
    }
    family.series[key] = series;
  }
  return series;
}

- (void)incrementCounter:(NSString *)name help:(NSString *)help labels:(NSDictionary *)labels by:(double)value
{
  @synchronized (self) {
    HSMetricSeries *series = [self series:name help:help kind:HSMetricCounter labels:labels buckets:nil];
    series.value += value;
  }
}

- (void)setGauge:(NSString *)name help:(NSString *)help labels:(NSDictionary *)labels value:(double)value
{
  @synchronized (self) {
    [self series:name help:help kind:HSMetricGauge labels:labels buckets:nil].value = value;
  }
}

- (void)addToGauge:(NSString *)name help:(NSString *)help labels:(NSDictionary *)labels by:(double)value
{
  @synchronized (self) {
    HSMetricSeries *series = [self series:name help:help kind:HSMetricGauge labels:labels buckets:nil];
    series.value += value;
  }
}

+ (NSArray<NSNumber *> *)defaultBuckets
{
  return @[ @0.005, @0.01, @0.025, @0.05, @0.1, @0.25, @0.5, @1, @2.5, @5, @10 ];
}

- (void)observeHistogram:(NSString *)name help:(NSString *)help labels:(NSDictionary *)labels value:(double)value buckets:(NSArray *)buckets
{
  @synchronized (self) {
    HSMetricSeries *series = [self series:name help:help kind:HSMetricHistogram labels:labels
                                   buckets:buckets ?: [HSMetrics defaultBuckets]];
    if (!series) return;
    NSArray *bounds = _families[name].buckets;
    for (NSUInteger i = 0; i < bounds.count; i++) {
      if (value <= [bounds[i] doubleValue]) {
        series.bucketCounts[i] = @([series.bucketCounts[i] unsignedLongLongValue] + 1);
        break;
      }
    }
    series.value += value;
    series.count += 1;
  }
}

- (double)valueOf:(NSString *)name labels:(NSDictionary *)labels
{
  @synchronized (self) {
    HSMetricSeries *series = _families[name].series[HSLabelKey(labels ?: @{})];
    return _families[name].kind == HSMetricHistogram ? (double)series.count : series.value;
  }
}

static NSString *HSNumber(double value)
{
  if (isinf(value)) return value > 0 ? @"+Inf" : @"-Inf";
  if (isnan(value)) return @"NaN";
  if (value == floor(value) && fabs(value) < 1e15) return [NSString stringWithFormat:@"%.0f", value];
  return [NSString stringWithFormat:@"%.9g", value];
}

static NSString *HSEscapedLabel(NSString *value)
{
  return [[[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
           stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]
          stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}

static NSString *HSLabels(NSDictionary<NSString *, NSString *> *labels, NSString *extraName, NSString *extraValue)
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *name in [labels.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [parts addObject:[NSString stringWithFormat:@"%@=\"%@\"", name, HSEscapedLabel(labels[name])]];
  }
  if (extraName) [parts addObject:[NSString stringWithFormat:@"%@=\"%@\"", extraName, extraValue]];
  return parts.count ? [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@","]] : @"";
}

// The process's resident memory, in bytes; 0 where it cannot be told.
static double HSResidentBytes(void)
{
#if defined(__APPLE__)
  struct mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) return (double)info.resident_size;
  return 0;
#elif defined(_WIN32)
  // The working set: what Windows calls resident.
  PROCESS_MEMORY_COUNTERS counters;
  if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof counters)) return (double)counters.WorkingSetSize;
  return 0;
#else
  FILE *statm = fopen("/proc/self/statm", "r");
  if (!statm) return 0;
  unsigned long size = 0, resident = 0;
  int read = fscanf(statm, "%lu %lu", &size, &resident);
  fclose(statm);
  return read == 2 ? (double)resident * (double)sysconf(_SC_PAGESIZE) : 0;
#endif
}

- (NSString *)exposition
{
  NSMutableString *text = [NSMutableString string];
  @synchronized (self) {
    for (NSString *name in [_families.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      HSMetricFamily *family = _families[name];
      NSString *kind = family.kind == HSMetricCounter ? @"counter" : family.kind == HSMetricGauge ? @"gauge" : @"histogram";
      [text appendFormat:@"# HELP %@ %@\n# TYPE %@ %@\n", name, [family.help stringByReplacingOccurrencesOfString:@"\n" withString:@" "], name, kind];
      for (NSString *key in [family.series.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        HSMetricSeries *series = family.series[key];
        if (family.kind != HSMetricHistogram) {
          [text appendFormat:@"%@%@ %@\n", name, HSLabels(series.labels, nil, nil), HSNumber(series.value)];
          continue;
        }
        unsigned long long cumulative = 0;
        for (NSUInteger i = 0; i < family.buckets.count; i++) {
          cumulative += [series.bucketCounts[i] unsignedLongLongValue];
          [text appendFormat:@"%@_bucket%@ %llu\n", name, HSLabels(series.labels, @"le", HSNumber([family.buckets[i] doubleValue])), cumulative];
        }
        [text appendFormat:@"%@_bucket%@ %llu\n", name, HSLabels(series.labels, @"le", @"+Inf"), series.count];
        [text appendFormat:@"%@_sum%@ %@\n", name, HSLabels(series.labels, nil, nil), HSNumber(series.value)];
        [text appendFormat:@"%@_count%@ %llu\n", name, HSLabels(series.labels, nil, nil), series.count];
      }
    }
  }
  [text appendFormat:@"# HELP process_start_time_seconds When the process started, in seconds since the epoch.\n"
                     @"# TYPE process_start_time_seconds gauge\nprocess_start_time_seconds %@\n", HSNumber(floor(HSProcessStart))];
  double resident = HSResidentBytes();
  if (resident > 0) {
    [text appendFormat:@"# HELP process_resident_memory_bytes Resident memory, in bytes.\n"
                       @"# TYPE process_resident_memory_bytes gauge\nprocess_resident_memory_bytes %@\n", HSNumber(resident)];
  }
  [text appendFormat:@"# HELP httpserverkit_build_info The HTTPServerKit this is, as a label.\n"
                     @"# TYPE httpserverkit_build_info gauge\nhttpserverkit_build_info{version=\"%@\"} 1\n", HSEscapedLabel(HSVersion)];
  return text;
}

@end

@implementation HSMetricsStage

- (instancetype)initWithMetrics:(HSMetrics *)metrics
{
  self = [super init];
  if (!self) return nil;
  _metrics = metrics;
  return self;
}

- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  request.userInfo[HSMetricsStartKey] = @(HSMonotonicSeconds());
  [self.metrics addToGauge:@"http_requests_in_flight" help:@"Requests being answered." labels:nil by:1];
  return YES;
}

- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  HSMetrics *metrics = self.metrics;
  [metrics addToGauge:@"http_requests_in_flight" help:@"Requests being answered." labels:nil by:-1];
  NSString *route = request.route.pattern ?: @"(none)";
  NSString *status = [NSString stringWithFormat:@"%ld", (long)response.status];
  [metrics incrementCounter:@"http_requests_total" help:@"Requests answered, by method, route and status."
                     labels:@{ @"method": request.method, @"route": route, @"status": status } by:1];
  NSNumber *started = request.userInfo[HSMetricsStartKey];
  if (started) {
    [metrics observeHistogram:@"http_request_duration_seconds" help:@"How long requests took to answer, by method and route."
                       labels:@{ @"method": request.method, @"route": route } value:HSMonotonicSeconds() - started.doubleValue buckets:nil];
  }
  if (response.body || !response.bodyStream) {
    double size = response.body.length;
    if (response.bodyFileURL) size = [[[NSFileManager defaultManager] attributesOfItemAtPath:response.bodyFileURL.path error:NULL] fileSize];
    [metrics observeHistogram:@"http_response_size_bytes" help:@"Response body sizes, by method and route."
                       labels:@{ @"method": request.method, @"route": route } value:size
                      buckets:@[ @100, @1000, @10000, @100000, @1000000, @10000000 ]];
  }
  if (request.operation) {
    [metrics incrementCounter:@"http_operations_total" help:@"Requests answered, by route, the operation its handler named, method and status."
                       labels:@{ @"route": route, @"operation": request.operation, @"method": request.method, @"status": status } by:1];
  }
  // Refusals, by why: the authenticator's reason when it gave one (an
  // expired token, a bad signature, a provider away), else by status.
  NSString *reason = request.userInfo[HSAuthenticationFailureKey];
  if (reason || response.status == 401 || response.status == 403) {
    if (!reason) reason = response.status == 401 ? @"unauthenticated" : @"forbidden";
    [metrics incrementCounter:@"http_auth_failures_total" help:@"Requests refused for who sent them, by reason."
                       labels:@{ @"reason": reason } by:1];
  }
}

- (NSString *)description
{
  return @"<HSMetricsStage>";
}

@end

@implementation HSMetricsHandler {
  HSMetrics *_metrics;
}

- (instancetype)initWithMetrics:(HSMetrics *)metrics
{
  self = [super init];
  if (!self) return nil;
  _metrics = metrics;
  return self;
}

- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  HSResponse *response = [HSResponse responseWithStatus:200 body:[[_metrics exposition] dataUsingEncoding:NSUTF8StringEncoding]
                                                              contentType:@"text/plain; version=0.0.4; charset=utf-8"];
  [response setValue:@"no-store" forHeader:@"Cache-Control"];
  [reply finishWithResponse:response];
}

- (NSString *)description
{
  return @"<HSMetricsHandler>";
}

@end

#pragma mark - Trace context

// The client's address without its port: 192.0.2.1, ::1.
static NSString *HSClientAddress(NSString *remote)
{
  if (!remote.length) return nil;
  NSRange colon = [remote rangeOfString:@":" options:NSBackwardsSearch];
  NSString *host = colon.location == NSNotFound || [remote rangeOfString:@":"].location != colon.location ||
                   [remote hasPrefix:@"["] ? remote : [remote substringToIndex:colon.location];
  if ([host hasPrefix:@"["]) {
    NSRange close = [host rangeOfString:@"]"];
    host = close.location == NSNotFound ? host : [host substringWithRange:NSMakeRange(1, close.location - 1)];
  }
  return host;
}

@implementation HSTraceContextStage

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _tracer = [OTTracer tracerNamed:@"HTTPServerKit" version:HSVersion];
  return self;
}

- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  OTSpanContext *parent = [OTSpanContext contextWithTraceparent:[request valueForHeader:@"traceparent"]
                                                      tracestate:[request valueForHeader:@"tracestate"]];
  NSString *pattern = request.route.pattern;
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
  attributes[@"http.request.method"] = request.method;
  attributes[@"url.path"] = request.path;
  NSRange question = [request.target rangeOfString:@"?"];
  if (question.location != NSNotFound) attributes[@"url.query"] = [request.target substringFromIndex:question.location + 1];
  attributes[@"url.scheme"] = @"http";
  attributes[@"network.protocol.version"] = @"1.1";
  if (pattern) attributes[@"http.route"] = pattern;
  attributes[@"client.address"] = HSClientAddress(request.remoteAddress);
  attributes[@"user_agent.original"] = [request valueForHeader:@"User-Agent"];
  attributes[@"request.id"] = request.userInfo[HSRequestIDKey];
  OTSpan *span = [self.tracer startSpanNamed:pattern ? [NSString stringWithFormat:@"%@ %@", request.method, pattern] : request.method
                                        kind:OTSpanKindServer parent:parent attributes:attributes];
  request.span = span;
  request.userInfo[HSTraceIDKey] = span.context.traceID;
  request.userInfo[HSSpanIDKey] = span.context.spanID;
  request.userInfo[HSTraceparentKey] = span.context.traceparent;
  return YES;
}

- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  OTSpan *span = request.span;
  if (!span.recording) {
    [span end];
    return;
  }
  NSString *pattern = request.route.pattern;
  if (pattern) {
    span.name = [NSString stringWithFormat:@"%@ %@", request.method, pattern];
    [span setAttribute:pattern forKey:@"http.route"];
  }
  [span setAttribute:@(response.status) forKey:@"http.response.status_code"];
  [span setAttribute:request.operation forKey:@"operation.name"];
  if (request.principal) [span setAttribute:@YES forKey:@"enduser.authenticated"];
  // A server's span is an error for what it got wrong, not the client.
  if (response.status >= 500) {
    [span setAttribute:[NSString stringWithFormat:@"%ld", (long)response.status] forKey:@"error.type"];
    [span setStatus:OTStatusError message:nil];
  }
  [span end];
}

- (NSString *)description
{
  return @"<HSTraceContextStage>";
}

@end

#pragma mark - Readiness

// The answers of one readiness question, as they come; finished when all
// are in, or when the time is up.
@interface HSReadinessRound : NSObject
@property (nonatomic, strong) HSReply *reply;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *answers;  // name -> ok, or why not
@property (nonatomic) NSUInteger expected;
@property (nonatomic) BOOL done;
- (void)answer:(NSString *)name with:(NSString *)result;
- (void)finishTimedOut:(BOOL)timedOut;
@end

@interface HSCheck ()
@property (nonatomic, weak) HSReadinessRound *round;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL answered;
@end

@implementation HSCheck

- (instancetype)initInRound:(HSReadinessRound *)round name:(NSString *)name
{
  self = [super init];
  if (!self) return nil;
  _round = round;
  _name = [name copy];
  return self;
}

- (void)answerWith:(NSString *)result
{
  @synchronized (self) {
    if (self.answered) return;
    self.answered = YES;
  }
  [self.round answer:self.name with:result];
}

- (void)pass
{
  [self answerWith:@"ok"];
}

- (void)failWithReason:(NSString *)reason
{
  [self answerWith:reason.length ? reason : @"failed"];
}

@end

@implementation HSReadinessRound

- (void)answer:(NSString *)name with:(NSString *)result
{
  BOOL all;
  @synchronized (self) {
    if (self.done) return;
    self.answers[name] = result;
    all = self.answers.count >= self.expected;
  }
  if (all) [self finishTimedOut:NO];
}

- (void)finishTimedOut:(BOOL)timedOut
{
  NSDictionary *answers;
  @synchronized (self) {
    if (self.done) return;
    self.done = YES;
    answers = [self.answers copy];
  }
  BOOL ready = answers.count >= self.expected;
  for (NSString *name in answers) {
    if (![answers[name] isEqualToString:@"ok"]) ready = NO;
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObject:ready ? @"ready" : @"unavailable" forKey:@"status"];
  if (answers.count || timedOut) {
    NSMutableDictionary *checks = [answers mutableCopy];
    if (timedOut) body[@"reason"] = @"Not every check answered in time";
    body[@"checks"] = checks;
  }
  HSResponse *response = [HSResponse responseWithJSON:body status:ready ? 200 : 503];
  [response setValue:@"no-store" forHeader:@"Cache-Control"];
  [self.reply finishWithResponse:response];
}

@end

@implementation HSReadinessHandler

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _checks = @[];
  _timeout = 5;
  return self;
}

- (void)addCheck:(id<HSReadinessCheck>)check
{
  @synchronized (self) {
    self.checks = [self.checks arrayByAddingObject:check];
  }
}

- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  HSReadinessRound *round = [[HSReadinessRound alloc] init];
  round.reply = reply;
  round.answers = [NSMutableDictionary dictionary];
  if (self.draining) {
    HSResponse *response = [HSResponse responseWithJSON:@{ @"status": @"draining" } status:503];
    [response setValue:@"no-store" forHeader:@"Cache-Control"];
    [reply finishWithResponse:response];
    return;
  }
  NSArray *checks;
  @synchronized (self) {
    checks = self.checks;
  }
  round.expected = checks.count;
  if (!checks.count) {
    [round finishTimedOut:NO];
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeout * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
    [round finishTimedOut:YES];
  });
  for (id<HSReadinessCheck> check in checks) {
    [check checkReadiness:[[HSCheck alloc] initInRound:round name:check.name]];
  }
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<HSReadinessHandler %@%@>", [[self.checks valueForKey:@"name"] componentsJoinedByString:@" "],
                                    self.draining ? @" draining" : @""];
}

@end
