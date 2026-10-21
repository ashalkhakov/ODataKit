// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Requests go out through a transport and come back by target-action (an
// ODataExchange). The synchronous methods, which the store uses because
// NSIncrementalStore's callbacks are synchronous, wait on a condition for
// the exchange to finish; nothing else has to be asynchronous.

#import "ODataClient.h"
#import "ODataError.h"
#import "ODataBatch.h"
#import <OTelKit/OTTrace.h>
#import <OTelKit/OTHTTP.h>

// A request's span, ended when its wire exchange finishes, before the
// client hears of it.
@interface OISTracedWire : NSObject
@property (nonatomic, strong) OTSpan *span;
@property (nonatomic, strong) id target;
@property (nonatomic) SEL action;
@end

@implementation OISTracedWire
- (void)wireDidFinish:(ODataExchange *)wire
{
  [self.span endWithResponse:wire.URLResponse error:wire.error];
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[self.target methodForSelector:self.action];
  send(self.target, self.action, wire);
}
@end

@interface OISWaiter : NSObject
- (void)exchangeDidFinish:(ODataExchange *)exchange;
- (BOOL)waitUntil:(NSDate *)deadline;
@end

@implementation OISWaiter {
  NSCondition *_condition;
  BOOL _done;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _condition = [[NSCondition alloc] init];
  return self;
}

- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  [_condition lock];
  _done = YES;
  [_condition signal];
  [_condition unlock];
}

- (BOOL)waitUntil:(NSDate *)deadline
{
  [_condition lock];
  while (!_done && [_condition waitUntilDate:deadline]) {}
  BOOL done = _done;
  [_condition unlock];
  return done;
}
@end

// A request the service accepted to answer later (202): its status
// monitor, polled until it answers, within the configuration's asyncTimeout.
@interface OISStatusMonitor : NSObject
@property (nonatomic, strong) ODataExchange *exchange;  // the one sent: its request, the caller's context
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, strong) NSDate *deadline;
// Finishes the caller's exchange from the answer, as the first response would have.
@property (nonatomic, copy) void (^finish)(ODataExchange *wire);
@end

@implementation OISStatusMonitor
@end

static NSString *OISHeaderOf(NSHTTPURLResponse *response, NSString *name)
{
  NSDictionary *headers = response.allHeaderFields;
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

#pragma mark - The client

// $expand's items, at its top level: A($select=B,C),D is A($select=B,C) and D.
static NSArray<NSString *> *OISTopLevelItems(NSString *list)
{
  NSMutableArray *items = [NSMutableArray array];
  NSInteger depth = 0;
  BOOL quoted = NO;
  NSUInteger start = 0;
  for (NSUInteger i = 0; i < list.length; i++) {
    unichar c = [list characterAtIndex:i];
    if (c == '\'') quoted = !quoted;
    else if (quoted) continue;
    else if (c == '(') depth++;
    else if (c == ')') depth--;
    else if (c == ',' && depth == 0) {
      [items addObject:[list substringWithRange:NSMakeRange(start, i - start)]];
      start = i + 1;
    }
  }
  [items addObject:[list substringFromIndex:start]];
  return items;
}

// An $expand item behind a type cast: Ns.Type/Nav(...).
static BOOL OISIsCastExpansion(NSString *item)
{
  NSRange open = [item rangeOfString:@"("];
  NSString *path = open.location == NSNotFound ? item : [item substringToIndex:open.location];
  NSRange slash = [path rangeOfString:@"/"];
  return slash.location != NSNotFound && [[path substringToIndex:slash.location] rangeOfString:@"."].location != NSNotFound;
}

static NSString *OISEncodeQueryValue(NSString *value)
{
  static const char hex[] = "0123456789ABCDEF";
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *bytes = data.bytes;
  NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 3];
  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char c = bytes[i];
    BOOL unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
    if (unreserved) [out appendFormat:@"%c", c];
    else [out appendFormat:@"%%%c%c", hex[c >> 4], hex[c & 15]];
  }
  return out;
}

// The URL without $expand's items behind a type cast (a derived type's
// own navigation properties, Ns.Type/Nav), which a service may not take
// (ODataKit's before 0.3.11 answers 501); nil when it has none.
static NSURL *OISURLWithoutCastExpansions(NSURL *url)
{
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  NSString *query = components.percentEncodedQuery;
  if (!query.length) return nil;
  NSMutableArray *parts = [NSMutableArray array];
  BOOL changed = NO;
  for (NSString *part in [query componentsSeparatedByString:@"&"]) {
    NSRange equals = [part rangeOfString:@"="];
    NSString *name = equals.location == NSNotFound ? part : [[part substringToIndex:equals.location] stringByRemovingPercentEncoding];
    if (![name isEqualToString:@"$expand"]) {
      [parts addObject:part];
      continue;
    }
    NSString *value = [[part substringFromIndex:equals.location + 1] stringByRemovingPercentEncoding] ?: @"";
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *item in OISTopLevelItems(value)) {
      if (OISIsCastExpansion(item)) changed = YES;
      else [kept addObject:item];
    }
    if (kept.count) [parts addObject:[NSString stringWithFormat:@"%@=%@", [part substringToIndex:equals.location], OISEncodeQueryValue([kept componentsJoinedByString:@","])]];
  }
  if (!changed) return nil;
  components.percentEncodedQuery = parts.count ? [parts componentsJoinedByString:@"&"] : nil;
  return components.URL;
}

@implementation ODataClient {
  // A service refused $expand's type casts: left out from then on.
  BOOL _castExpansionsRefused;
}

- (instancetype)initWithConfiguration:(ODataConfiguration *)configuration
{
  self = [super init];
  if (!self) return nil;
  _configuration = configuration;
  _tracer = [OTTracer tracerNamed:@"ODataIncrementalStore" version:nil];
  return self;
}

// What a request asks, by a name of few values: the entity set (or
// operation, $batch, $metadata) its path names first under the service
// root, for the span's name.
- (NSString *)spanNameFor:(NSURLRequest *)request
{
  NSString *root = self.configuration.serviceRoot.path ?: @"";
  NSString *path = request.URL.path ?: @"";
  NSString *rest = [path hasPrefix:root] ? [path substringFromIndex:root.length] : path;
  if ([rest hasPrefix:@"/"]) rest = [rest substringFromIndex:1];
  NSString *first = [rest componentsSeparatedByString:@"/"].firstObject ?: @"";
  NSRange parenthesis = [first rangeOfString:@"("];
  if (parenthesis.location != NSNotFound) first = [first substringToIndex:parenthesis.location];
  NSString *method = request.HTTPMethod.length ? request.HTTPMethod : @"GET";
  return first.length ? [NSString stringWithFormat:@"%@ %@", method, first] : method;
}

// The client's own exchange rides in the transport's as its context.
- (ODataExchange *)sendRequest:(NSURLRequest *)request target:(id)target action:(SEL)action
{
  NSMutableURLRequest *req = [request mutableCopy];
  [self.configuration applyToRequest:req];
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:req target:target action:action];
  [self transport:req context:exchange action:@selector(requestDidFinish:)];
  return exchange;
}

// The wire exchange carries context (the client's exchange, or a status
// monitor) back to action.
- (void)transport:(NSURLRequest *)request context:(id)context action:(SEL)action
{
  id<ODataTransport> transport = self.transport ?: ODataDefaultTransport();
  NSMutableURLRequest *traced = [request mutableCopy];
  OISTracedWire *trace = [[OISTracedWire alloc] init];
  trace.span = [self.tracer startClientSpanForRequest:traced name:[self spanNameFor:request] parent:nil];
  trace.target = self;
  trace.action = action;
  ODataExchange *wire = [[ODataExchange alloc] initWithRequest:traced target:trace action:@selector(wireDidFinish:)];
  wire.context = context;
  if (!transport) {
    wire.error = OISError(ODataIncrementalStoreErrorTransport, @"No transport: this Foundation has neither NSURLSession nor NSURLConnection");
    [wire finish];
    return;
  }
  [transport startExchange:wire];
}

// An HTTP response from the wire as an ODataHTTPResponse, or the error an
// error status is.
- (ODataHTTPResponse *)responseFrom:(ODataExchange *)wire error:(NSError **)error
{
  if (wire.error) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, wire.error.localizedDescription);
    return nil;
  }
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)wire.URLResponse;
  if (![http isKindOfClass:[NSHTTPURLResponse class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, @"No HTTP response");
    return nil;
  }
  NSData *body = wire.data ?: [NSData data];
  if (http.statusCode >= 400) {
    ODataIncrementalStoreErrorCode code = http.statusCode == 412
        ? ODataIncrementalStoreErrorOptimisticLocking
        : (ODataIncrementalStoreErrorCode)(ODataIncrementalStoreErrorHTTP + http.statusCode);
    if (error) {
      *error = OISHTTPErrorWithChallenge(OISHTTPError(code, http.statusCode, http.URL ?: wire.request.URL, body),
                                         OISHeaderOf(http, @"WWW-Authenticate"));
    }
    return nil;
  }
  ODataHTTPResponse *out = [[ODataHTTPResponse alloc] init];
  out.status = http.statusCode;
  out.data = body;
  out.headers = http.allHeaderFields ?: @{};
  out.URL = http.URL;
  return out;
}

- (void)requestDidFinish:(ODataExchange *)wire
{
  if ([self awaitedMonitor:wire finish:^(ODataExchange *answer) { [self requestDidFinish:answer]; }]) return;
  ODataExchange *exchange = wire.context;
  NSError *error = nil;
  exchange.response = [self responseFrom:wire error:&error];
  exchange.error = error;
  exchange.URLResponse = wire.URLResponse;
  exchange.data = wire.data;
  [exchange finish];
}

// 202 to a request that preferred respond-async: its answer is at the
// status monitor in Location (Part 1 section 11.6), polled for it here;
// finish is given the answer as though it had been the response.
- (BOOL)awaitedMonitor:(ODataExchange *)wire finish:(void (^)(ODataExchange *answer))finish
{
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)wire.URLResponse;
  NSString *location = [http isKindOfClass:[NSHTTPURLResponse class]] && http.statusCode == 202 ? OISHeaderOf(http, @"Location") : nil;
  NSString *prefer = [wire.request valueForHTTPHeaderField:@"Prefer"];
  if (wire.error || !location || ![prefer.lowercaseString containsString:@"respond-async"]) return NO;
  OISStatusMonitor *monitor = [[OISStatusMonitor alloc] init];
  monitor.exchange = wire;
  monitor.URL = [NSURL URLWithString:location relativeToURL:wire.request.URL].absoluteURL;
  monitor.deadline = [NSDate dateWithTimeIntervalSinceNow:self.configuration.asyncTimeout];
  monitor.finish = finish;
  [self poll:monitor after:http];
  return YES;
}

// Asks the monitor again once Retry-After has passed (a second when it
// does not say).
- (void)poll:(OISStatusMonitor *)monitor after:(NSHTTPURLResponse *)response
{
  NSString *retry = OISHeaderOf(response, @"Retry-After");
  NSTimeInterval delay = retry.length ? MAX(0.0, retry.doubleValue) : 1.0;
  delay = MIN(delay, MAX(0.0, monitor.deadline.timeIntervalSinceNow));
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                 dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [self transport:[self monitorRequest:monitor method:@"GET"] context:monitor action:@selector(monitorDidAnswer:)];
  });
}

// Signed as any request, but not asking to be answered later itself.
- (NSURLRequest *)monitorRequest:(OISStatusMonitor *)monitor method:(NSString *)method
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:monitor.URL];
  request.HTTPMethod = method;
  [self.configuration applyToRequest:request];
  [request setValue:nil forHTTPHeaderField:@"Prefer"];
  [request setValue:nil forHTTPHeaderField:@"Repeatability-Request-ID"];
  [request setValue:nil forHTTPHeaderField:@"Repeatability-First-Sent"];
  return request;
}

- (void)monitorDidAnswer:(ODataExchange *)wire
{
  OISStatusMonitor *monitor = (OISStatusMonitor *)wire.context;
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)wire.URLResponse;
  if (!wire.error && [http isKindOfClass:[NSHTTPURLResponse class]] && http.statusCode == 202) {
    if (monitor.deadline.timeIntervalSinceNow > 0) {
      [self poll:monitor after:http];
      return;
    }
    // Given up on: the service may stop the work.
    [self transport:[self monitorRequest:monitor method:@"DELETE"] context:nil action:@selector(monitorDidForget:)];
    ODataExchange *caller = monitor.exchange.context;
    caller.error = OISError(ODataIncrementalStoreErrorTransport, [NSString stringWithFormat:@"The service had not answered at %@ in time", monitor.URL]);
    [caller finish];
    return;
  }
  // The answer, as application/http; anything else stands as it is.
  NSString *type = [http isKindOfClass:[NSHTTPURLResponse class]] ? OISHeaderOf(http, @"Content-Type") : nil;
  ODataBatchPart *message = http.statusCode == 200 && [type.lowercaseString hasPrefix:@"application/http"] ? ODataHTTPMessage(wire.data) : nil;
  ODataExchange *answer = [[ODataExchange alloc] initWithRequest:monitor.exchange.request target:nil action:NULL];
  answer.context = monitor.exchange.context;
  answer.error = wire.error;
  answer.URLResponse = wire.URLResponse;
  answer.data = wire.data;
  if (message && message.status) {
    answer.URLResponse = [[NSHTTPURLResponse alloc] initWithURL:monitor.exchange.request.URL statusCode:message.status
                                                    HTTPVersion:@"HTTP/1.1" headerFields:message.headers];
    answer.data = message.body;
  }
  // Not a 202 any more, so not polled again.
  monitor.finish(answer);
}

- (void)monitorDidForget:(ODataExchange *)wire
{
}

// Waits for an exchange started by `start`, for as long as the request's
// own timeout allows and then some; a transport that never finishes is an
// error rather than a hang.
- (ODataExchange *)waitFor:(ODataExchange *(^)(OISWaiter *waiter))start error:(NSError **)error
{
  OISWaiter *waiter = [[OISWaiter alloc] init];
  ODataExchange *exchange = start(waiter);
  NSTimeInterval asynchronous = self.configuration.respondAsync ? self.configuration.asyncTimeout : 0;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:self.configuration.timeout + asynchronous + 30.0];
  if (![waiter waitUntil:deadline]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, @"The transport did not finish the request");
    return nil;
  }
  if (exchange.error) {
    if (error) *error = exchange.error;
    return nil;
  }
  return exchange;
}

- (ODataHTTPResponse *)sendRequest:(NSURLRequest *)request error:(NSError **)error
{
  NSError *failure = nil;
  // Its repeatability headers once, so that a repeat is the same request.
  NSMutableURLRequest *prepared = [request mutableCopy];
  [self.configuration applyToRequest:prepared];
  request = prepared;
  ODataHTTPResponse *response = [self waitFor:^ODataExchange *(OISWaiter *waiter) {
    return [self sendRequest:request target:waiter action:@selector(exchangeDidFinish:)];
  } error:&failure].response;
  // No answer at all to a repeatable request: sent again, the same.
  for (int again = 0; again < 2 && !response && [request valueForHTTPHeaderField:@"Repeatability-Request-ID"] &&
                      !failure.userInfo[ODataErrorHTTPStatusKey]; again++) {
    failure = nil;
    response = [self waitFor:^ODataExchange *(OISWaiter *waiter) {
      return [self sendRequest:request target:waiter action:@selector(exchangeDidFinish:)];
    } error:&failure].response;
  }
  BOOL refused = !response && [failure.userInfo[ODataErrorHTTPStatusKey] integerValue] == 401;
  // Refused: once more, with a fresh token from the provider.
  if (refused && [self.configuration refreshCredentials]) {
    NSMutableURLRequest *again = [request mutableCopy];
    [again setValue:nil forHTTPHeaderField:@"Authorization"];
    failure = nil;
    response = [self waitFor:^ODataExchange *(OISWaiter *waiter) {
      return [self sendRequest:again target:waiter action:@selector(exchangeDidFinish:)];
    } error:&failure].response;
    refused = !response && [failure.userInfo[ODataErrorHTTPStatusKey] integerValue] == 401;
  }
  // Refused still: what the service would take, as $metadata says.
  NSString *expected = refused ? self.configuration.expectedCredentials : nil;
  if (expected) {
    NSMutableDictionary *info = [failure.userInfo mutableCopy];
    info[NSLocalizedRecoverySuggestionErrorKey] = expected;
    failure = [NSError errorWithDomain:failure.domain code:failure.code userInfo:info];
  }
  if (!response && error) *error = failure;
  return response;
}

- (id)JSONAtURL:(NSURL *)url error:(NSError **)error
{
  return [self JSONAtURL:url headers:nil error:error];
}

- (id)JSONAtURL:(NSURL *)url headers:(NSDictionary *)headers error:(NSError **)error
{
  if (_castExpansionsRefused) url = OISURLWithoutCastExpansions(url) ?: url;
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  for (NSString *name in headers) [req setValue:headers[name] forHTTPHeaderField:name];
  NSError *failure = nil;
  ODataHTTPResponse *response = [self sendRequest:req error:&failure];
  // A derived type's to-ones, prefetched behind its cast, refused: read
  // without them (each is then read when asked for), and so from now on.
  NSInteger status = [failure.userInfo[ODataErrorHTTPStatusKey] integerValue];
  NSURL *plain = !response && (status == 400 || status == 501) ? OISURLWithoutCastExpansions(url) : nil;
  if (plain) {
    _castExpansionsRefused = YES;
    req.URL = plain;
    failure = nil;
    response = [self sendRequest:req error:&failure];
  }
  if (!response) {
    if (error) *error = failure;
    return nil;
  }
  if (response.status == 204) return [NSNull null];
  return [response JSONWithError:error];
}

- (NSString *)textAtURL:(NSURL *)url error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  [req setValue:@"text/plain" forHTTPHeaderField:@"Accept"];
  ODataHTTPResponse *response = [self sendRequest:req error:error];
  if (!response) return nil;
  return [[NSString alloc] initWithData:response.data encoding:NSUTF8StringEncoding] ?: @"";
}

- (ODataHTTPResponse *)sendJSONMethod:(NSString *)method
                                  URL:(NSURL *)url
                                 body:(id)body
                                 etag:(NSString *)etag
                                error:(NSError **)error
{
  NSMutableURLRequest *req = [self requestWithMethod:method URL:url body:body etag:etag error:error];
  return req ? [self sendRequest:req error:error] : nil;
}

- (NSArray *)sendChangeSet:(NSArray *)requests error:(NSError **)error
{
  return [self waitFor:^ODataExchange *(OISWaiter *waiter) {
    return [self sendChangeSet:requests target:waiter action:@selector(exchangeDidFinish:)];
  } error:error].responses;
}

- (ODataExchange *)sendChangeSet:(NSArray *)requests target:(id)target action:(SEL)action
{
  NSURL *url = [self.configuration.serviceRoot URLByAppendingPathComponent:@"$batch"];
  NSMutableURLRequest *batch = [NSMutableURLRequest requestWithURL:url];
  batch.HTTPMethod = @"POST";
  if (self.configuration.JSONBatch) {
    // 4.01's JSON batch format (JSON Format section 19).
    batch.HTTPBody = ODataJSONBatchBody(requests);
    [batch setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [batch setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  } else {
    NSString *boundary = [@"batch_" stringByAppendingString:[[NSUUID UUID] UUIDString]];
    batch.HTTPBody = ODataChangeSetBody(requests, boundary);
    [batch setValue:[@"multipart/mixed; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
    [batch setValue:@"multipart/mixed" forHTTPHeaderField:@"Accept"];
  }
  [self.configuration applyToRequest:batch];
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:batch target:target action:action];
  exchange.context = requests;
  [self transport:batch context:exchange action:@selector(changeSetDidFinish:)];
  return exchange;
}

- (void)changeSetDidFinish:(ODataExchange *)wire
{
  if ([self awaitedMonitor:wire finish:^(ODataExchange *answer) { [self changeSetDidFinish:answer]; }]) return;
  ODataExchange *exchange = wire.context;
  NSArray *requests = exchange.context;
  NSError *error = nil;
  exchange.responses = [self changeSetResponsesFrom:wire requests:requests error:&error];
  exchange.error = error;
  exchange.URLResponse = wire.URLResponse;
  exchange.data = wire.data;
  [exchange finish];
}

- (NSArray *)changeSetResponsesFrom:(ODataExchange *)wire requests:(NSArray *)requests error:(NSError **)error
{
  ODataHTTPResponse *response = [self responseFrom:wire error:error];
  if (!response) return nil;
  NSURL *url = wire.request.URL;
  NSString *type = [response valueForHeader:@"Content-Type"] ?: @"";
  NSString *responseBoundary = ODataMultipartBoundary(type);
  BOOL JSON = [type.lowercaseString hasPrefix:@"application/json"];
  NSArray *parts = JSON ? ODataJSONBatchParts(response.data) : responseBoundary ? ODataBatchParts(response.data, responseBoundary) : nil;
  if (!parts) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, JSON ? @"The $batch response is not a JSON batch response"
                                                                         : @"The $batch response is not a multipart body");
    return nil;
  }
  // A change set that failed is answered with one response: the failure
  // (section 11.7.7.5). In JSON, each of its requests has one, the others
  // 424 Failed Dependency: the failure is the one that is not.
  ODataBatchPart *failure = nil;
  for (ODataBatchPart *part in parts) {
    if (part.status >= 400 && (!failure || failure.status == 424)) failure = part;
  }
  for (ODataBatchPart *part in failure ? @[ failure ] : @[]) {
    NSUInteger index = part.contentID ? (NSUInteger)(part.contentID.integerValue - 1) : 0;
    NSURL *failed = index < requests.count ? [requests[index] URL] : url;
    ODataIncrementalStoreErrorCode code = part.status == 412
        ? ODataIncrementalStoreErrorOptimisticLocking
        : (ODataIncrementalStoreErrorCode)(ODataIncrementalStoreErrorHTTP + part.status);
    if (error) *error = OISHTTPErrorWithChallenge(OISHTTPError(code, part.status, failed, part.body), [part valueForHeader:@"WWW-Authenticate"]);
    return nil;
  }
  if (parts.count != requests.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding,
                                 [NSString stringWithFormat:@"$batch answered %lu of %lu requests", (unsigned long)parts.count, (unsigned long)requests.count]);
    return nil;
  }
  NSMutableArray *responses = [NSMutableArray array];
  for (NSUInteger i = 0; i < parts.count; i++) {
    ODataBatchPart *part = parts[i];
    ODataHTTPResponse *one = [[ODataHTTPResponse alloc] init];
    one.status = part.status;
    one.data = part.body;
    one.headers = part.headers;
    one.URL = [requests[i] URL];
    [responses addObject:one];
  }
  return responses;
}

- (NSMutableURLRequest *)requestWithMethod:(NSString *)method
                                      URL:(NSURL *)url
                                     body:(id)body
                                     etag:(NSString *)etag
                                    error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = method;
  if (body) {
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (!req.HTTPBody) return nil;
  }
  if (etag) [req setValue:etag forHTTPHeaderField:@"If-Match"];
  // The entity back in the response, with its new key and ETag, saves a
  // GET (Part 1 section 8.2.8.7). Not for $ref, which has no entity.
  BOOL entity = ([method isEqualToString:@"POST"] || [method isEqualToString:@"PATCH"]) &&
                ![url.path hasSuffix:@"/$ref"];
  if (entity) [req setValue:@"return=representation" forHTTPHeaderField:@"Prefer"];
  [self.configuration applyToRequest:req];
  return req;
}

- (NSData *)metadataWithError:(NSError **)error
{
  NSURL *url = [self.configuration.serviceRoot URLByAppendingPathComponent:@"$metadata"];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  [req setValue:@"application/xml" forHTTPHeaderField:@"Accept"];
  return [self sendRequest:req error:error].data;
}

@end
