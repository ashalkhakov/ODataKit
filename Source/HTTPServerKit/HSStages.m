// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSStages.h"
#import "HSAuthentication.h"
#import "HSRouter.h"
#import "HSObservability.h"
#import "HSLog.h"
#import <OTelKit/OTTrace.h>
#include <zlib.h>
#include <time.h>
#include <sys/time.h>

NSString * const HSRequestIDKey = @"HS.requestID";
static NSString * const HSStartKey = @"HS.started";

#pragma mark - Health

@implementation HSHealthHandler

- (NSDictionary *)status
{
  return @{ @"status": @"ok" };
}

- (NSInteger)statusCode
{
  return 200;
}

- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  HSResponse *response = [HSResponse responseWithJSON:[self status] status:[self statusCode]];
  [response setValue:@"no-store" forHeader:@"Cache-Control"];
  [reply finishWithResponse:response];
}

- (NSString *)description
{
  return @"<HSHealthHandler>";
}

@end

#pragma mark - Authentication

// One request's question to the authenticator, and where it goes next.
@interface HSAuthenticationStep : NSObject
@property (nonatomic, strong) id<HSAuthenticator> authenticator;
@property (nonatomic, strong) HSRequest *request;
@property (nonatomic, strong) HSReply *reply;
@property (nonatomic, strong) id<HSHandler> next;
@property (nonatomic, strong) OTSpan *span;
@end

// A refused request's refusal, in its words: the access log's.
static NSString * const HSRefusalKey = @"HSRefusal";

@implementation HSAuthenticationStep

- (void)didAuthenticate:(HSAuthenticationReply *)answer
{
  NSString *reason = answer.error.userInfo[HSAuthenticationFailureKey];
  if (reason) self.request.userInfo[HSAuthenticationFailureKey] = reason;
  // Why, in the refusal's words, for the access log.
  if (answer.error) self.request.userInfo[HSRefusalKey] = answer.error.localizedDescription ?: @"";
  [self.span setAttribute:answer.error ? @"refused" : answer.principal ? @"authenticated" : @"anonymous" forKey:@"auth.outcome"];
  [self.span setAttribute:reason forKey:@"auth.failure_reason"];
  if ([HSResponse statusOfError:answer.error] >= 500) [self.span recordError:answer.error];
  [self.span end];
  if (answer.error) {
    HSResponse *response = [HSResponse responseWithError:answer.error request:self.request];
    // A 401's challenge is the authenticator's: it knows why it refused.
    if ([HSResponse statusOfError:answer.error] == 401) {
      NSString *challenge = [self.authenticator respondsToSelector:@selector(challengeForRequest:)]
          ? [self.authenticator challengeForRequest:self.request] : nil;
      [response setValue:challenge.length ? challenge : @"Bearer" forHeader:@"WWW-Authenticate"];
    }
    [self.reply finishWithResponse:response];
    return;
  }
  self.request.principal = answer.principal;
  self.request.authenticated = YES;
  [self.next handleRequest:self.request reply:self.reply];
}

@end

@implementation HSAuthenticationStage

- (instancetype)initWithAuthenticator:(id<HSAuthenticator>)authenticator
{
  self = [super init];
  if (!self) return nil;
  _authenticator = authenticator;
  _timeout = 60;
  return self;
}

// It waits for the authenticator, so it owns its step.
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply next:(id<HSHandler>)next
{
  HSAuthenticationStep *step = [[HSAuthenticationStep alloc] init];
  step.authenticator = self.authenticator;
  step.request = request;
  step.reply = reply;
  step.next = next;
  step.span = [[OTTracer tracerNamed:@"HTTPServerKit" version:HSVersion] startSpanNamed:@"authenticate" kind:OTSpanKindInternal
                                                                                parent:request.span.context attributes:nil];
  HSAuthenticationReply *answer = [[HSAuthenticationReply alloc] initWithTarget:step action:@selector(didAuthenticate:)];
  answer.timeout = self.timeout;
  [self.authenticator authenticateRequest:request reply:answer];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<HSAuthenticationStage %@>", NSStringFromClass([(NSObject *)self.authenticator class])];
}

@end

#pragma mark - Request ids

@implementation HSRequestIDStage

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _headerName = @"X-Request-ID";
  return self;
}

// One a log line can carry as it is: short, and nothing but visible ASCII.
static BOOL HSUsableID(NSString *given)
{
  if (!given.length || given.length > 128) return NO;
  for (NSUInteger i = 0; i < given.length; i++) {
    unichar c = [given characterAtIndex:i];
    if (c <= ' ' || c > '~') return NO;
  }
  return YES;
}

- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  NSString *given = [request valueForHeader:self.headerName];
  request.userInfo[HSRequestIDKey] = HSUsableID(given) ? given : [NSUUID UUID].UUIDString.lowercaseString;
  return YES;
}

- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  [response setValue:request.userInfo[HSRequestIDKey] forHeader:self.headerName];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<HSRequestIDStage %@>", self.headerName];
}

@end

#pragma mark - CORS

@implementation HSCORSStage

- (instancetype)initWithAllowedOrigins:(NSArray<NSString *> *)origins
{
  self = [super init];
  if (!self) return nil;
  _allowedOrigins = [origins copy] ?: @[];
  _allowedMethods = @[ @"GET", @"HEAD", @"POST", @"PUT", @"PATCH", @"DELETE" ];
  _allowedHeaders = @[ @"Authorization", @"Content-Type", @"Accept", @"OData-Version", @"OData-MaxVersion", @"If-Match",
                       @"If-None-Match", @"Prefer", @"Isolation", @"X-Request-ID" ];
  _exposedHeaders = @[ @"OData-Version", @"ETag", @"Location", @"OData-EntityId", @"Preference-Applied", @"Retry-After",
                       @"WWW-Authenticate", @"X-Request-ID" ];
  _maxAge = 600;
  return self;
}

- (BOOL)allowsOrigin:(NSString *)origin
{
  for (NSString *allowed in self.allowedOrigins) {
    if ([allowed isEqualToString:@"*"] || [allowed caseInsensitiveCompare:origin] == NSOrderedSame) return YES;
  }
  return NO;
}

// Who the response is for: the origin itself, unless any may read it and
// no credentials go with it.
- (void)allowOrigin:(NSString *)origin onResponse:(HSResponse *)response
{
  BOOL any = [self.allowedOrigins containsObject:@"*"] && !self.allowsCredentials;
  [response setValue:any ? @"*" : origin forHeader:@"Access-Control-Allow-Origin"];
  if (!any) {
    NSString *vary = [response valueForHeader:@"Vary"];
    if (![vary.lowercaseString containsString:@"origin"]) [response setValue:vary.length ? [vary stringByAppendingString:@", Origin"] : @"Origin" forHeader:@"Vary"];
  }
  if (self.allowsCredentials) [response setValue:@"true" forHeader:@"Access-Control-Allow-Credentials"];
}

- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  NSString *origin = [request valueForHeader:@"Origin"];
  NSString *asked = [request valueForHeader:@"Access-Control-Request-Method"];
  if (!origin || ![request.method isEqualToString:@"OPTIONS"] || !asked) return YES;
  if (![self allowsOrigin:origin] || ![self.allowedMethods containsObject:asked.uppercaseString]) {
    [reply failWithError:HSError(403, [NSString stringWithFormat:@"%@ may not %@ here", origin, asked])];
    return NO;
  }
  HSResponse *response = [HSResponse responseWithStatus:204];
  [self allowOrigin:origin onResponse:response];
  [response setValue:[self.allowedMethods componentsJoinedByString:@", "] forHeader:@"Access-Control-Allow-Methods"];
  // The headers it asks for, those it may.
  NSMutableArray *headers = [NSMutableArray array];
  for (NSString *header in [[request valueForHeader:@"Access-Control-Request-Headers"] ?: @"" componentsSeparatedByString:@","]) {
    NSString *name = [header stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *allowed in self.allowedHeaders) {
      if (name.length && [allowed caseInsensitiveCompare:name] == NSOrderedSame) [headers addObject:allowed];
    }
  }
  if (headers.count) [response setValue:[headers componentsJoinedByString:@", "] forHeader:@"Access-Control-Allow-Headers"];
  [response setValue:[NSString stringWithFormat:@"%lu", (unsigned long)self.maxAge] forHeader:@"Access-Control-Max-Age"];
  [reply finishWithResponse:response];
  return NO;
}

- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  NSString *origin = [request valueForHeader:@"Origin"];
  if (!origin || ![self allowsOrigin:origin] || [response valueForHeader:@"Access-Control-Allow-Origin"]) return;
  [self allowOrigin:origin onResponse:response];
  if (self.exposedHeaders.count) [response setValue:[self.exposedHeaders componentsJoinedByString:@", "] forHeader:@"Access-Control-Expose-Headers"];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<HSCORSStage %@>", [self.allowedOrigins componentsJoinedByString:@" "]];
}

@end

#pragma mark - Compression

@implementation HSCompressionStage

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _minimumSize = 1024;
  _compressibleTypes = @[ @"application/json", @"application/xml", @"application/xhtml+xml", @"text/" ];
  return self;
}

// Whether the client takes gzip: named (or *) in Accept-Encoding without q=0.
static BOOL HSTakesGzip(NSString *accepted)
{
  for (NSString *item in [accepted ?: @"" componentsSeparatedByString:@","]) {
    NSArray *parts = [item componentsSeparatedByString:@";"];
    NSString *coding = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    if (![coding isEqualToString:@"gzip"] && ![coding isEqualToString:@"*"]) continue;
    BOOL refused = NO;
    for (NSString *parameter in [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]) {
      NSString *p = [parameter stringByReplacingOccurrencesOfString:@" " withString:@""].lowercaseString;
      if ([p hasPrefix:@"q="] && [[p substringFromIndex:2] doubleValue] <= 0) refused = YES;
    }
    if (!refused) return YES;
  }
  return NO;
}

- (BOOL)compresses:(NSString *)contentType
{
  NSString *type = [[contentType componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
  for (NSString *compressible in self.compressibleTypes) {
    if ([compressible hasSuffix:@"/"] ? [type hasPrefix:compressible] : [type isEqualToString:compressible]) return YES;
    if ([type hasSuffix:@"+json"] && [compressible isEqualToString:@"application/json"]) return YES;
  }
  return NO;
}

static NSData *HSGzip(NSData *data)
{
  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
  NSMutableData *compressed = [NSMutableData dataWithLength:deflateBound(&stream, (uLong)data.length) + 32];
  stream.next_in = (Bytef *)data.bytes;
  stream.avail_in = (uInt)data.length;
  stream.next_out = compressed.mutableBytes;
  stream.avail_out = (uInt)compressed.length;
  int status = deflate(&stream, Z_FINISH);
  compressed.length = stream.total_out;
  deflateEnd(&stream);
  return status == Z_STREAM_END ? compressed : nil;
}

- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  NSData *body = response.body;
  if (body.length < self.minimumSize || response.status == 204 || response.status == 304) return;
  if ([response valueForHeader:@"Content-Encoding"] || ![self compresses:[response valueForHeader:@"Content-Type"] ?: @""]) return;
  // Whether it is compressed depends on what the client takes, for a cache.
  NSString *vary = [response valueForHeader:@"Vary"];
  if (![vary.lowercaseString containsString:@"accept-encoding"]) {
    [response setValue:vary.length ? [vary stringByAppendingString:@", Accept-Encoding"] : @"Accept-Encoding" forHeader:@"Vary"];
  }
  if (!HSTakesGzip([request valueForHeader:@"Accept-Encoding"])) return;
  NSData *compressed = HSGzip(body);
  if (!compressed || compressed.length >= body.length) return;
  response.body = compressed;
  [response setValue:@"gzip" forHeader:@"Content-Encoding"];
  // The same entity, other bytes: a strong ETag no longer holds.
  NSString *etag = [response valueForHeader:@"ETag"];
  if (etag.length && ![etag hasPrefix:@"W/"]) [response setValue:[@"W/" stringByAppendingString:etag] forHeader:@"ETag"];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<HSCompressionStage from %lu bytes>", (unsigned long)self.minimumSize];
}

@end

#pragma mark - Access log

// Now, as RFC 3339 in UTC with milliseconds.
FOUNDATION_EXPORT NSString *HSLogTimestamp(void);

@implementation HSAccessLogStage

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _slowRequestThreshold = 1;
  return self;
}

- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  request.userInfo[HSStartKey] = [NSDate date];
  return YES;
}

- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  NSDate *started = request.userInfo[HSStartKey];
  double milliseconds = started ? -[started timeIntervalSinceNow] * 1000.0 : 0;
  NSString *who = request.principal.subject ?: @"-";
  if (self.format == HSAccessLogJSON) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"time"] = HSLogTimestamp();
    NSString *refusal = request.userInfo[HSRefusalKey];
    entry[@"level"] = response.status >= 500 || refusal || milliseconds > self.slowRequestThreshold * 1000 ? @"warn" : @"info";
    entry[@"remote"] = request.remoteAddress ?: [NSNull null];
    entry[@"principal"] = request.principal.subject ?: [NSNull null];
    entry[@"method"] = request.method;
    entry[@"target"] = request.target;
    entry[@"route"] = request.route.pattern ?: [NSNull null];
    entry[@"operation"] = request.operation ?: [NSNull null];
    entry[@"status"] = @(response.status);
    entry[@"bytes"] = response.bodyFileURL || response.bodyStream ? [NSNull null] : @(response.body.length);
    entry[@"request_id"] = request.userInfo[HSRequestIDKey] ?: [NSNull null];
    entry[@"trace_id"] = request.userInfo[HSTraceIDKey] ?: [NSNull null];
    entry[@"span_id"] = request.userInfo[HSSpanIDKey] ?: [NSNull null];
    entry[@"user_agent"] = [request valueForHeader:@"User-Agent"] ?: [NSNull null];
    // Who was refused, and why: a token from the wrong issuer, for another
    // audience, expired.
    if (refusal) {
      entry[@"auth_failure"] = request.userInfo[HSAuthenticationFailureKey] ?: [NSNull null];
      entry[@"auth_error"] = refusal;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    // The duration as text, so it is written as 0.7, not as the double
    // nearest it (which gnustep-base writes even for an NSDecimalNumber).
    line = [line stringByReplacingCharactersInRange:NSMakeRange(line.length - 1, 1)
                                         withString:[NSString stringWithFormat:@",\"duration_ms\":%.1f}", milliseconds]];
    [self writeLine:line];
    return;
  }
  // A file's or a stream's size is not known here.
  NSString *size = response.bodyFileURL || response.bodyStream ? @"-" : [NSString stringWithFormat:@"%lu", (unsigned long)response.body.length];
  NSString *line = [NSString stringWithFormat:@"%@ %@ \"%@ %@\" %ld %@ %.1fms %@", request.remoteAddress ?: @"-", who, request.method,
                                              request.target, (long)response.status, size, milliseconds,
                                              request.userInfo[HSRequestIDKey] ?: @"-"];
  NSString *refusal = request.userInfo[HSRefusalKey];
  if (refusal) {
    line = [line stringByAppendingFormat:@" refused (%@): %@", request.userInfo[HSAuthenticationFailureKey] ?: @"-", refusal];
  }
  [self writeLine:line];
}

- (void)writeLine:(NSString *)line
{
  [[HSLog sharedLog] writeLine:line];
}

@end
