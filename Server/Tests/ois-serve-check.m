// ois-serve-check — the HTTP adapter over a real loopback socket.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   ois-serve-check <Catalog.momd or .xcdatamodeld>
//
// Starts an HSServer on 127.0.0.1 over the Catalog model in memory
// and talks to it with plain sockets, not the URL loading system, so that
// what is tested is the listener and the service, as a proxy would reach
// them. One line per check; exits 0 only if all pass. The protocol itself
// is tested without sockets, in Tests/ODataServiceTests.m.

#import <ODataService/ODataServer.h>
#import <ODataKit/ODataBatch.h>
#import <ODataKit/ODataError.h>
#import <ODataSync/ODataSync.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>

static int failures;
static NSUInteger port;

static void check(BOOL ok, NSString *name, NSString *detail)
{
  printf("%s %s: %s\n", ok ? "PASS" : "FAIL", name.UTF8String, detail.UTF8String);
  if (!ok) failures++;
}

@interface OISReply : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary *headers;  // lower-case names
@property (nonatomic, copy) NSData *body;
@property (nonatomic, readonly) id json;
@property (nonatomic, readonly) NSString *text;
@end

@implementation OISReply
- (id)json
{
  return self.body.length ? [NSJSONSerialization JSONObjectWithData:self.body options:0 error:NULL] : nil;
}
- (NSString *)text
{
  return [[NSString alloc] initWithData:self.body ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
}
@end

// A chunked body's chunks, joined; nil if it is not one.
static NSData *OISUnchunked(NSData *data)
{
  NSMutableData *joined = [NSMutableData data];
  const char *bytes = data.bytes;
  NSUInteger at = 0;
  while (at < data.length) {
    NSUInteger lineEnd = at;
    while (lineEnd + 1 < data.length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) lineEnd++;
    NSString *sizeText = [[NSString alloc] initWithBytes:bytes + at length:lineEnd - at encoding:NSASCIIStringEncoding];
    unsigned long size = strtoul(sizeText.UTF8String, NULL, 16);
    at = lineEnd + 2;
    if (size == 0) return joined;
    if (at + size > data.length) return nil;
    [joined appendBytes:bytes + at length:size];
    at += size + 2;
  }
  return nil;
}

static NSData *OISGunzip(NSData *data)
{
  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  if (inflateInit2(&stream, 15 + 16) != Z_OK) return nil;
  NSMutableData *out = [NSMutableData dataWithLength:data.length * 20 + 1024];
  stream.next_in = (Bytef *)data.bytes;
  stream.avail_in = (uInt)data.length;
  stream.next_out = out.mutableBytes;
  stream.avail_out = (uInt)out.length;
  int status = inflate(&stream, Z_FINISH);
  out.length = stream.total_out;
  inflateEnd(&stream);
  return status == Z_STREAM_END ? out : nil;
}

// One request, written as given, and the whole response, read to the end
// (the server closes each connection).
static OISReply *OISSendRaw(NSData *request)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((uint16_t)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(fd);
    return nil;
  }
  const uint8_t *bytes = request.bytes;
  for (NSUInteger sent = 0; sent < request.length;) {
    ssize_t n = write(fd, bytes + sent, request.length - sent);
    if (n <= 0) break;
    sent += (NSUInteger)n;
  }
  NSMutableData *all = [NSMutableData data];
  uint8_t buffer[16384];
  for (;;) {
    ssize_t n = read(fd, buffer, sizeof(buffer));
    if (n <= 0) break;
    [all appendBytes:buffer length:(NSUInteger)n];
  }
  close(fd);

  NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSRange end = [all rangeOfData:separator options:0 range:NSMakeRange(0, all.length)];
  if (end.location == NSNotFound) return nil;
  NSString *head = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
  NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
  OISReply *reply = [[OISReply alloc] init];
  NSArray *statusLine = [lines[0] componentsSeparatedByString:@" "];
  reply.status = statusLine.count > 1 ? [statusLine[1] integerValue] : 0;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    headers[[line substringToIndex:colon.location].lowercaseString] =
      [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  }
  reply.headers = headers;
  reply.body = [all subdataWithRange:NSMakeRange(NSMaxRange(end), all.length - NSMaxRange(end))];
  if ([[headers[@"transfer-encoding"] lowercaseString] isEqualToString:@"chunked"]) reply.body = OISUnchunked(reply.body);
  return reply;
}

#pragma mark A connection kept open

static int OISConnect(void)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((uint16_t)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(fd);
    return -1;
  }
  struct timeval timeout = { 5, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  return fd;
}

// Bytes from the socket into buffer until it holds at least count; NO at its end.
static BOOL OISFill(int fd, NSMutableData *buffer, NSUInteger count)
{
  uint8_t chunk[16384];
  while (buffer.length < count) {
    ssize_t n = read(fd, chunk, sizeof(chunk));
    if (n <= 0) return NO;
    [buffer appendBytes:chunk length:(NSUInteger)n];
  }
  return YES;
}

// One response off a kept connection, its end found by its Content-Length or
// its chunks (none for HEAD); what follows it stays in buffer.
static OISReply *OISReadOne(int fd, NSMutableData *buffer, BOOL head)
{
  NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSRange end;
  while ((end = [buffer rangeOfData:separator options:0 range:NSMakeRange(0, buffer.length)]).location == NSNotFound) {
    if (!OISFill(fd, buffer, buffer.length + 1)) return nil;
  }
  NSString *headText = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
  [buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(end)) withBytes:NULL length:0];
  NSArray *lines = [headText componentsSeparatedByString:@"\r\n"];
  OISReply *reply = [[OISReply alloc] init];
  NSArray *statusLine = [lines[0] componentsSeparatedByString:@" "];
  reply.status = statusLine.count > 1 ? [statusLine[1] integerValue] : 0;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location != NSNotFound) {
      headers[[line substringToIndex:colon.location].lowercaseString] =
        [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
  }
  reply.headers = headers;
  if (head || reply.status == 204 || reply.status == 304) {
    reply.body = [NSData data];
  } else if ([[headers[@"transfer-encoding"] lowercaseString] isEqualToString:@"chunked"]) {
    NSData *last = [@"0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange done;
    while ((done = [buffer rangeOfData:last options:0 range:NSMakeRange(0, buffer.length)]).location == NSNotFound) {
      if (!OISFill(fd, buffer, buffer.length + 1)) return nil;
    }
    reply.body = OISUnchunked([buffer subdataWithRange:NSMakeRange(0, NSMaxRange(done))]);
    [buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(done)) withBytes:NULL length:0];
  } else {
    NSUInteger length = (NSUInteger)[headers[@"content-length"] integerValue];
    if (!OISFill(fd, buffer, length)) return nil;
    reply.body = [buffer subdataWithRange:NSMakeRange(0, length)];
    [buffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
  }
  return reply;
}

static void OISWrite(int fd, NSString *text)
{
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  const uint8_t *bytes = data.bytes;
  for (NSUInteger sent = 0; sent < data.length;) {
    ssize_t n = write(fd, bytes + sent, data.length - sent);
    if (n <= 0) return;
    sent += (NSUInteger)n;
  }
}

// Whether the server has closed the connection (a read gives its end).
static BOOL OISClosed(int fd)
{
  uint8_t byte;
  return read(fd, &byte, 1) == 0;
}

static OISReply *OISSend(NSString *method, NSString *target, NSDictionary *headers, id json)
{
  NSData *body = json ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : nil;
  NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1:%lu\r\nConnection: close\r\n",
                           method, target, (unsigned long)port];
  for (NSString *name in headers) [head appendFormat:@"%@: %@\r\n", name, headers[name]];
  if (body) [head appendFormat:@"Content-Type: application/json\r\nContent-Length: %lu\r\n", (unsigned long)body.length];
  [head appendString:@"\r\n"];
  NSMutableData *request = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  if (body) [request appendData:body];
  return OISSendRaw(request);
}

#pragma mark An application of its own

// GET /hello/:name: who it greets, and who asked.
@interface OISHelloHandler : NSObject <HSHandler>
@end

@implementation OISHelloHandler
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  NSMutableString *order = request.userInfo[@"order"];
  [order appendString:@"handler"];
  [reply finishWithResponse:[HSResponse responseWithJSON:@{ @"hello": request.pathParameters[@"name"] ?: @"",
                                                                      @"asker": request.principal.subject ?: [NSNull null] }
                                                            status:200]];
}
@end

// Answers later, from another queue, as a handler that asks a database does.
@interface OISLaterHandler : NSObject <HSHandler>
@end

@implementation OISLaterHandler
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  double delay = request.userInfo[@"delay"] ? [request.userInfo[@"delay"] doubleValue] : 0.03;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
    [reply finishWithResponse:[HSResponse responseWithText:@"later" status:202]];
  });
}
@end

// A file, a stream, a JSON body worth compressing, and what came.
@interface OISBodiesHandler : NSObject <HSHandler, HSResponseStream>
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, strong) NSURL *file;
@property (nonatomic) NSInteger chunk;
@end

@implementation OISBodiesHandler
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  if ([self.kind isEqualToString:@"file"]) {
    [reply finishWithResponse:[HSResponse responseWithFile:self.file contentType:@"application/octet-stream" status:200]];
  } else if ([self.kind isEqualToString:@"stream"]) {
    OISBodiesHandler *stream = [[OISBodiesHandler alloc] init];
    [reply finishWithResponse:[HSResponse responseWithStream:stream contentType:@"text/plain" status:200]];
  } else if ([self.kind isEqualToString:@"json"]) {
    NSMutableArray *rows = [NSMutableArray array];
    for (int i = 0; i < 200; i++) [rows addObject:@{ @"id": @(i), @"name": [NSString stringWithFormat:@"row %d of many", i] }];
    [reply finishWithResponse:[HSResponse responseWithJSON:@{ @"value": rows } status:200]];
  } else {
    [reply finishWithResponse:[HSResponse responseWithJSON:@{ @"size": @(request.body.length), @"inFile": @(request.bodyFileURL != nil) }
                                                             status:200]];
  }
}
- (NSData *)nextChunk:(NSError **)error
{
  NSArray *pieces = @[ @"one,", @"two,", @"three" ];
  return self.chunk < (NSInteger)pieces.count ? [pieces[self.chunk++] dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
}
@end

@interface OISBoomHandler : NSObject <HSHandler>
@end

@implementation OISBoomHandler
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  [NSException raise:NSInternalInconsistencyException format:@"on purpose"];
}
@end

// Notes the way in and the way out: X-Order shows the order stages ran.
@interface OISOrderStage : HSStage
@property (nonatomic, copy) NSString *name;
@end

@implementation OISOrderStage
- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  NSMutableString *order = request.userInfo[@"order"];
  if (!order) request.userInfo[@"order"] = order = [NSMutableString string];
  [order appendFormat:@"%@>", self.name];
  return YES;
}
- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  NSMutableString *order = request.userInfo[@"order"];
  [order appendFormat:@"<%@", self.name];
  [response setValue:order forHeader:@"X-Order"];
}
@end

// Answers /blocked itself, and sees its own answer on the way back.
@interface OISBlockingStage : HSStage
@end

@implementation OISBlockingStage
- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  if (![request.path isEqualToString:@"/blocked"]) return YES;
  [reply finishWithResponse:[HSResponse responseWithText:@"no" status:418]];
  return NO;
}
- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
  if (response.status == 418) [response setValue:@"418" forHeader:@"X-Blocked-Saw"];
}
@end

// The access log, kept rather than written.
@interface OISKeptLog : HSAccessLogStage
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@end

@implementation OISKeptLog
- (void)writeLine:(NSString *)line
{
  @synchronized (self) {
    [self.lines addObject:line];
  }
}
@end

// Asks elsewhere and answers later, from another queue: Token <name> is
// <name>; Token banned is refused.
@interface OISLaterAuthenticator : NSObject <HSAuthenticator>
@end

@implementation OISLaterAuthenticator
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  NSString *given = [[request valueForHeader:@"Authorization"] stringByReplacingOccurrencesOfString:@"Token " withString:@""];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    if ([given isEqualToString:@"banned"]) {
      [reply failWithError:HSError(401, @"That token is not taken here")];
    } else {
      [reply finishWithPrincipal:given.length ? [[HSPrincipal alloc] initWithSubject:given claims:@{}] : nil];
    }
  });
}
- (NSString *)challengeForRequest:(HSRequest *)request
{
  return @"Token realm=\"check\"";
}
@end

// Collects what an authenticator answered.
// (A condition lock, not a semaphore: on GNUstep a dispatch object is no
// Objective-C object a property can keep.)
@interface OISAnswers : NSObject
@property (nonatomic, strong) NSConditionLock *done;
@property (nonatomic, strong) HSAuthenticationReply *answer;
@end

@implementation OISAnswers
- (void)didAuthenticate:(HSAuthenticationReply *)answer
{
  [self.done lock];
  self.answer = answer;
  [self.done unlockWithCondition:1];
}
@end

static HSAuthenticationReply *OISAskLater(NSString *authorization)
{
  HSRequest *request = [[HSRequest alloc] initWithMethod:@"GET" URL:[NSURL URLWithString:@"http://example.test/anything"]
                                                 headers:authorization ? @{ @"Authorization": authorization } : @{} body:nil];
  OISAnswers *answers = [[OISAnswers alloc] init];
  answers.done = [[NSConditionLock alloc] initWithCondition:0];
  HSAuthenticationReply *reply = [[HSAuthenticationReply alloc] initWithTarget:answers action:@selector(didAuthenticate:)];
  reply.timeout = 5;
  [[[OISLaterAuthenticator alloc] init] authenticateRequest:request reply:reply];
  if (![answers.done lockWhenCondition:1 beforeDate:[NSDate dateWithTimeIntervalSinceNow:5]]) return nil;
  HSAuthenticationReply *answer = answers.answer;
  [answers.done unlock];
  return answer;
}

// What the trace context stage left for handlers, as the response.
@interface OISTraceHandler : NSObject <HSHandler>
@end

@implementation OISTraceHandler
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  request.operation = @"echoTrace";
  [reply finishWithResponse:[HSResponse responseWithJSON:@{ @"trace": request.userInfo[HSTraceIDKey] ?: [NSNull null],
                                                                      @"span": request.userInfo[HSSpanIDKey] ?: [NSNull null],
                                                                      @"traceparent": request.userInfo[HSTraceparentKey] ?: [NSNull null] }
                                                            status:200]];
}
@end

// Makes the slow route slow.
@interface OISSlowStage : HSStage
@end

@implementation OISSlowStage
- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  if ([request.path isEqualToString:@"/slow"]) request.userInfo[@"delay"] = @0.5;
  return YES;
}
@end

// A readiness check the test turns on and off.
@interface OISSwitchCheck : NSObject <HSReadinessCheck>
@property (atomic) BOOL failing;
@end

@implementation OISSwitchCheck
- (NSString *)name
{
  return @"switch";
}
- (void)checkReadiness:(HSCheck *)check
{
  if (self.failing) {
    [check failWithReason:@"switched off"];
  } else {
    [check pass];
  }
}
@end

// Metrics, logs as JSON, readiness, the admin listener, a graceful stop.
@interface OISObservedApplication : ODataServerApplication
@property (nonatomic, strong) OISKeptLog *log;
@property (nonatomic, strong) OISSwitchCheck *check;
@end

@implementation OISObservedApplication
- (void)configureRouter:(HSRouter *)router
{
  [router insertRoute:[HSRoute routeWithMethod:@"GET" path:@"/trace" handler:[[OISTraceHandler alloc] init]] atIndex:0];
  [router insertRoute:[HSRoute routeWithMethod:@"GET" path:@"/slow" handler:[[OISLaterHandler alloc] init]] atIndex:0];
  self.check = [[OISSwitchCheck alloc] init];
  [self.readiness addCheck:self.check];
}
- (void)configurePipeline:(HSPipeline *)pipeline
{
  HSAccessLogStage *configured = [pipeline stageOfClass:[HSAccessLogStage class]];
  self.log = [[OISKeptLog alloc] init];
  self.log.lines = [NSMutableArray array];
  self.log.format = configured.format;
  [pipeline replaceStageOfClass:[HSAccessLogStage class] withStage:self.log];
  [pipeline addStage:[[OISSlowStage alloc] init]];
}
@end

// An application's settings of its own, as SimpleNotes has them: its own
// prefix, and none of the service's settings known to it by name.
@interface OISOwnConfiguration : HSConfiguration
@end

@implementation OISOwnConfiguration
+ (NSString *)environmentPrefix { return @"OWN_"; }
@end

@interface OISCheckApplication : ODataServerApplication
@property (nonatomic, strong) OISKeptLog *log;
@property (nonatomic, strong) NSURL *file;
@end

@implementation OISCheckApplication
- (void)configureRouter:(HSRouter *)router
{
  [router insertRoute:[HSRoute routeWithMethod:@"GET" path:@"/hello/:name" handler:[[OISHelloHandler alloc] init]] atIndex:0];
  HSRoute *billing = [HSRoute routeWithMethod:@"POST" path:@"/webhooks/billing" handler:[[OISLaterHandler alloc] init]];
  billing.scopes = [NSSet setWithObject:@"Billing.Notify"];
  [router addRoute:billing];
  HSRoute *members = [HSRoute routeWithMethod:@"GET" path:@"/members" handler:[[OISHelloHandler alloc] init]];
  members.requiresPrincipal = YES;
  [router addRoute:members];
  [router addRoute:[HSRoute routeWithMethod:@"GET" path:@"/later" handler:[[OISLaterHandler alloc] init]]];
  [router addRoute:[HSRoute routeWithMethod:@"GET" path:@"/boom" handler:[[OISBoomHandler alloc] init]]];
  for (NSString *kind in @[ @"file", @"stream", @"json", @"echo" ]) {
    OISBodiesHandler *bodies = [[OISBodiesHandler alloc] init];
    bodies.kind = kind;
    bodies.file = self.file;
    [router addRoute:[HSRoute routeWithMethod:nil path:[@"/bodies/" stringByAppendingString:kind] handler:bodies]];
  }
}
- (void)configurePipeline:(HSPipeline *)pipeline
{
  // Its own log in place of the standard one, where it was.
  self.log = [[OISKeptLog alloc] init];
  self.log.lines = [NSMutableArray array];
  [pipeline replaceStageOfClass:[HSAccessLogStage class] withStage:self.log];
  OISOrderStage *a = [[OISOrderStage alloc] init], *b = [[OISOrderStage alloc] init];
  a.name = @"a";
  b.name = @"b";
  [pipeline addStage:a];
  [pipeline addStage:b];
  [pipeline addStage:[[OISBlockingStage alloc] init]];
}
@end

static NSManagedObject *OISInsert(NSManagedObjectContext *context, NSString *entity, NSDictionary *values)
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) [object setValue:values[key] forKey:key];
  return object;
}

#pragma mark Observability

// What the shared log would write, kept.
@interface OISCapturingLog : HSLog
- (NSArray<NSString *> *)taken;
@end

@implementation OISCapturingLog {
  NSMutableArray<NSString *> *_lines;
}
- (void)writeLine:(NSString *)line
{
  @synchronized (self) {
    if (!_lines) _lines = [NSMutableArray array];
    [_lines addObject:line];
  }
}
- (NSArray<NSString *> *)taken
{
  @synchronized (self) {
    return [_lines copy] ?: @[];
  }
}
@end

// An OpenTelemetry collector (POST /v1/traces, kept) and an identity
// provider that is down (anything else: 500), in one.
@interface OISCollector : NSObject <HSHandler>
- (NSArray<NSDictionary *> *)spans;
@end

@implementation OISCollector {
  NSMutableArray<NSDictionary *> *_bodies;
}
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  if ([request.method isEqualToString:@"POST"] && [request.path isEqualToString:@"/v1/traces"]) {
    id json = request.JSONBody;
    @synchronized (self) {
      if (!_bodies) _bodies = [NSMutableArray array];
      if (json) [_bodies addObject:json];
    }
    [reply finishWithResponse:[HSResponse responseWithJSON:@{} status:200]];
    return;
  }
  [reply finishWithResponse:[HSResponse responseWithStatus:500]];
}
// Every span sent, with its resource's service.name as "service".
- (NSArray<NSDictionary *> *)spans
{
  NSMutableArray *all = [NSMutableArray array];
  @synchronized (self) {
    for (NSDictionary *body in _bodies) {
      for (NSDictionary *resourceSpans in body[@"resourceSpans"]) {
        NSString *service = nil;
        for (NSDictionary *attribute in resourceSpans[@"resource"][@"attributes"]) {
          if ([attribute[@"key"] isEqual:@"service.name"]) service = attribute[@"value"][@"stringValue"];
        }
        for (NSDictionary *scope in resourceSpans[@"scopeSpans"]) {
          for (NSDictionary *span in scope[@"spans"]) {
            NSMutableDictionary *one = [span mutableCopy];
            one[@"service"] = service ?: @"";
            one[@"scope"] = scope[@"scope"][@"name"] ?: @"";
            [all addObject:one];
          }
        }
      }
    }
  }
  return all;
}
@end

static OTSpan *OISSpanNamed(NSArray<OTSpan *> *spans, NSString *prefix)
{
  for (OTSpan *span in spans) {
    if ([span.name hasPrefix:prefix]) return span;
  }
  return nil;
}

static NSDictionary *OISSentSpanNamed(NSArray<NSDictionary *> *spans, NSString *name)
{
  for (NSDictionary *span in spans) {
    if ([span[@"name"] isEqual:name]) return span;
  }
  return nil;
}

static id OISSentAttribute(NSDictionary *span, NSString *key)
{
  for (NSDictionary *attribute in span[@"attributes"]) {
    if ([attribute[@"key"] isEqual:key]) return attribute[@"value"];
  }
  return nil;
}

static NSString *OISBase64URL(id json)
{
  NSString *text = [[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] base64EncodedStringWithOptions:0];
  text = [[text stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

#pragma mark Offline sync

static NSAttributeDescription *OISSyncAttribute(NSString *name, NSAttributeType type, BOOL key)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = YES;
  attribute.preservesValueInHistoryOnDeletion = YES;
  if (key) attribute.userInfo = @{ @"OData.key": @"YES" };
  return attribute;
}

// Assets (down), Inspections (up, each of an asset) and Tasks (both), as docs/offline-sync.md has them.
static NSManagedObjectModel *OISSyncModelKeeping(BOOL versions);

static NSManagedObjectModel *OISSyncModel(void)
{
  return OISSyncModelKeeping(NO);
}

// With versions: Tasks keep what each version has seen (a version vector).
static NSManagedObjectModel *OISSyncModelKeeping(BOOL versions)
{
  NSEntityDescription *asset = [[NSEntityDescription alloc] init];
  asset.name = @"Asset";
  asset.managedObjectClassName = @"NSManagedObject";
  asset.userInfo = @{ @"OData.entitySet": @"Assets", ODataSyncDirectionKey: @"down" };
  NSEntityDescription *inspection = [[NSEntityDescription alloc] init];
  inspection.name = @"Inspection";
  inspection.managedObjectClassName = @"NSManagedObject";
  inspection.userInfo = @{ @"OData.entitySet": @"Inspections", ODataSyncDirectionKey: @"up" };
  NSRelationshipDescription *ofAsset = [[NSRelationshipDescription alloc] init];
  ofAsset.name = @"asset";
  ofAsset.destinationEntity = asset;
  ofAsset.maxCount = 1;
  ofAsset.deleteRule = NSNullifyDeleteRule;
  NSRelationshipDescription *inspections = [[NSRelationshipDescription alloc] init];
  inspections.name = @"inspections";
  inspections.destinationEntity = inspection;
  inspections.maxCount = 0;
  inspections.deleteRule = NSNullifyDeleteRule;
  ofAsset.inverseRelationship = inspections;
  inspections.inverseRelationship = ofAsset;
  asset.properties = @[ OISSyncAttribute(@"id", NSInteger32AttributeType, YES), OISSyncAttribute(@"name", NSStringAttributeType, NO), inspections ];
  inspection.properties = @[ OISSyncAttribute(@"id", NSStringAttributeType, YES), OISSyncAttribute(@"note", NSStringAttributeType, NO), ofAsset ];
  NSEntityDescription *task = [[NSEntityDescription alloc] init];
  task.name = @"Task";
  task.managedObjectClassName = @"NSManagedObject";
  task.userInfo = @{ @"OData.entitySet": @"Tasks", ODataSyncDirectionKey: @"both", ODataSyncModifiedKey: @"modified" };
  task.properties = @[ OISSyncAttribute(@"id", NSStringAttributeType, YES), OISSyncAttribute(@"title", NSStringAttributeType, NO),
                       OISSyncAttribute(@"done", NSBooleanAttributeType, NO), OISSyncAttribute(@"modified", NSStringAttributeType, NO) ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  if (versions) {
    task.properties = [task.properties arrayByAddingObject:OISSyncAttribute(@"versions", NSStringAttributeType, NO)];
    NSMutableDictionary *info = [task.userInfo mutableCopy];
    info[ODataSyncVersionsKey] = @"versions";
    task.userInfo = info;
  }
  model.entities = @[ asset, inspection, task ];
  return model;
}

static NSPersistentStoreCoordinator *OISSyncStore(NSManagedObjectModel *model, NSError **error)
{
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:path]
                                       options:@{ NSPersistentHistoryTrackingKey: @YES } error:error]) return nil;
  return coordinator;
}

// A port nothing listens on now.
static NSUInteger OISFreePort(void)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  socklen_t length = sizeof(address);
  NSUInteger free = 0;
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && getsockname(fd, (struct sockaddr *)&address, &length) == 0) {
    free = ntohs(address.sin_port);
  }
  close(fd);
  return free;
}

static NSArray *OISSyncValues(NSPersistentStoreCoordinator *coordinator, NSString *entity, NSString *key)
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  __block NSArray *values = nil;
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
    values = [[context executeFetchRequest:fetch error:NULL] valueForKey:key];
  }];
  return values ?: @[];
}

static void OISSyncWrite(NSPersistentStoreCoordinator *coordinator, void (^work)(NSManagedObjectContext *context))
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  [context performBlockAndWait:^{
    work(context);
    [context save:NULL];
  }];
}

static NSManagedObject *OISSyncObject(NSManagedObjectContext *context, NSString *entity, id identifier)
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", identifier];
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: ois-serve-check <Catalog.momd>\n");
      return 2;
    }
    NSString *modelPath = @(argv[1]);
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:modelPath]];
    if (!model.entities.count) {
      fprintf(stderr, "ois-serve-check: %s is not a model\n", argv[1]);
      return 2;
    }
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSError *error = nil;
    [coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error];
    NSManagedObjectContext *seed = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    seed.persistentStoreCoordinator = coordinator;
    __block BOOL seeded = NO;
    [seed performBlockAndWait:^{
      NSManagedObject *beverages = OISInsert(seed, @"Category", @{ @"id": @1, @"name": @"Beverages" });
      NSManagedObject *condiments = OISInsert(seed, @"Category", @{ @"id": @2, @"name": @"Condiments" });
      OISInsert(seed, @"Product", @{ @"id": @1, @"name": @"Chai", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"18"], @"category": beverages });
      OISInsert(seed, @"Product", @{ @"id": @2, @"name": @"Chang", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"19"], @"category": beverages });
      OISInsert(seed, @"Product", @{ @"id": @3, @"name": @"Aniseed Syrup", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"10"], @"category": condiments });
      NSError *saveError = nil;
      seeded = [seed save:&saveError];
      if (!seeded) fprintf(stderr, "ois-serve-check: seeding failed: %s\n", saveError.localizedDescription.UTF8String);
    }];
    if (!seeded) return 2;

    // The public root a proxy would forward from; the adapter answers under
    // its path and writes links with it.
    ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator
                                                                         serviceRoot:[NSURL URLWithString:@"https://api.example.test/odata/"]];
    HSServer *server = [[HSServer alloc] initWithService:service];
    BOOL started = [server startOnPort:0 error:&error];
    port = server.port;
    check(started && port > 0, @"start", [NSString stringWithFormat:@"listening on 127.0.0.1:%lu %@", (unsigned long)port, error ?: @""]);
    if (!started) return 1;

    OISReply *metadata = OISSend(@"GET", @"/odata/$metadata", nil, nil);
    check(metadata.status == 200 && [metadata.headers[@"content-type"] hasPrefix:@"application/xml"] &&
          [metadata.text rangeOfString:@"<EntitySet Name=\"Products\""].location != NSNotFound,
          @"metadata", [NSString stringWithFormat:@"%ld %@", (long)metadata.status, metadata.headers[@"content-type"]]);

    OISReply *filtered = OISSend(@"GET", @"/odata/Products?$filter=UnitPrice%20gt%2015&$orderby=ProductName%20desc&$select=ProductName", nil, nil);
    NSArray *names = [filtered.json[@"value"] valueForKey:@"ProductName"];
    check(filtered.status == 200 && [names isEqual:(@[ @"Chang", @"Chai" ])] &&
          [filtered.json[@"@odata.context"] isEqual:@"https://api.example.test/odata/$metadata#Products(ProductName)"] &&
          [filtered.headers[@"odata-version"] isEqual:@"4.01"],
          @"query", [NSString stringWithFormat:@"%ld %@ %@", (long)filtered.status, names, filtered.json[@"@odata.context"]]);

    OISReply *quoted = OISSend(@"GET", @"/odata/Products?$filter=ProductName%20eq%20'Aniseed%20Syrup'", nil, nil);
    check([[quoted.json[@"value"] valueForKey:@"ProductID"] isEqual:@[ @3 ]], @"quoted-literal", quoted.text);

    OISReply *created = OISSend(@"POST", @"/odata/Products", nil, @{ @"ProductName": @"Ipoh Coffee", @"UnitPrice": @46, @"Category@odata.bind": @"Categories(1)" });
    check(created.status == 201 && [created.headers[@"location"] isEqual:@"https://api.example.test/odata/Products(4)"] && created.headers[@"etag"],
          @"create", [NSString stringWithFormat:@"%ld %@", (long)created.status, created.headers[@"location"]]);

    OISReply *stale = OISSend(@"PATCH", @"/odata/Products(4)", @{ @"If-Match": @"W/\"0\"" }, @{ @"UnitPrice": @40 });
    check(stale.status == 412 && [stale.json[@"error"][@"message"] length], @"stale-etag", [NSString stringWithFormat:@"%ld %@", (long)stale.status, stale.text]);
    OISReply *patched = OISSend(@"PATCH", @"/odata/Products(4)", @{ @"If-Match": created.headers[@"etag"] ?: @"*" }, @{ @"UnitPrice": @40 });
    check(patched.status == 204 && patched.headers[@"etag"] && ![patched.headers[@"etag"] isEqual:created.headers[@"etag"]],
          @"update", [NSString stringWithFormat:@"%ld %@", (long)patched.status, patched.headers[@"etag"]]);

    // A chunked body, as Caddy streams one.
    NSString *chunkedBody = @"{\"ProductName\":\"Genen Shouyu\",\"UnitPrice\":15.5}";
    NSString *chunked = [NSString stringWithFormat:@"POST /odata/Categories(2)/Products HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
                         @"Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n%lx\r\n%@\r\n0\r\n\r\n",
                         (unsigned long)chunkedBody.length, chunkedBody];
    OISReply *created2 = OISSendRaw([chunked dataUsingEncoding:NSUTF8StringEncoding]);
    check(created2.status == 201 && [created2.json[@"ProductName"] isEqual:@"Genen Shouyu"], @"chunked-create",
          [NSString stringWithFormat:@"%ld %@", (long)created2.status, created2.text]);
    OISReply *count = OISSend(@"GET", @"/odata/Categories(2)/Products/$count", nil, nil);
    check(count.status == 200 && [count.text isEqual:@"2"], @"count", count.text);

    OISReply *missing = OISSend(@"GET", @"/odata/Nothing", nil, nil);
    check(missing.status == 404 && [missing.json[@"error"][@"code"] length], @"not-found", missing.text);
    OISReply *outside = OISSend(@"GET", @"/elsewhere", nil, nil);
    check(outside.status == 404, @"outside-root", [NSString stringWithFormat:@"%ld", (long)outside.status]);
    OISReply *head = OISSend(@"HEAD", @"/odata/Products(1)", nil, nil);
    check(head.status == 200 && head.body.length == 0 && head.headers[@"etag"], @"head", [NSString stringWithFormat:@"%ld, %lu bytes", (long)head.status, (unsigned long)head.body.length]);
    OISReply *deleted = OISSend(@"DELETE", @"/odata/Products(4)", nil, nil);
    check(deleted.status == 204 && OISSend(@"GET", @"/odata/Products(4)", nil, nil).status == 404, @"delete", [NSString stringWithFormat:@"%ld", (long)deleted.status]);

    // Upsert: PATCH to a key that names nothing creates; sent again, updates.
    OISReply *upserted = OISSend(@"PATCH", @"/odata/Products(90)", nil, @{ @"ProductName": @"Upserted", @"UnitPrice": @7 });
    OISReply *upsertedAgain = OISSend(@"PATCH", @"/odata/Products(90)", nil, @{ @"ProductName": @"Upserted", @"UnitPrice": @7 });
    OISReply *upsertedRead = OISSend(@"GET", @"/odata/Products(90)", nil, nil);
    check(upserted.status == 201 && upsertedAgain.status == 204 && [upsertedRead.json[@"ProductName"] isEqual:@"Upserted"], @"upsert",
          [NSString stringWithFormat:@"%ld then %ld: %@", (long)upserted.status, (long)upsertedAgain.status, upsertedRead.text]);

    // A $batch with a change set, over the socket: two new categories, the
    // second one's product bound to the first by its Content-ID.
    NSString *batch = @"--b\r\nContent-Type: multipart/mixed; boundary=cs\r\n\r\n"
      @"--cs\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 1\r\n\r\n"
      @"POST Categories HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"CategoryName\":\"Seafood\"}\r\n"
      @"--cs\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 2\r\n\r\n"
      @"POST $1/Products HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"ProductName\":\"Ikura\"}\r\n"
      @"--cs--\r\n--b--\r\n";
    NSString *batchHead = [NSString stringWithFormat:@"POST /odata/$batch HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
                      @"Content-Type: multipart/mixed; boundary=b\r\nContent-Length: %lu\r\n\r\n", (unsigned long)[batch lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    OISReply *batched = OISSendRaw([[batchHead stringByAppendingString:batch] dataUsingEncoding:NSUTF8StringEncoding]);
    NSString *boundary = ODataMultipartBoundary(batched.headers[@"content-type"] ?: @"");
    NSArray *batchParts = boundary ? ODataBatchParts(batched.body, boundary) : nil;
    check(batched.status == 200 && [[batchParts valueForKey:@"status"] isEqual:(@[ @201, @201 ])] &&
          [OISSend(@"GET", @"/odata/Categories(3)/Products/$count", nil, nil).text isEqual:@"1"],
          @"batch", [NSString stringWithFormat:@"%ld %@", (long)batched.status, [batchParts valueForKey:@"status"]]);

    // Requests at once, each on a connection of its own.
    NSUInteger expected = (NSUInteger)[OISSend(@"GET", @"/odata/Products/$count", nil, nil).text integerValue];
    __block NSInteger ok = 0;
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [[NSObject alloc] init];
    for (int i = 0; i < 24; i++) {
      dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{
        OISReply *r = OISSend(@"GET", @"/odata/Products?$expand=Category", nil, nil);
        if (r.status == 200 && [r.json[@"value"] count] == expected) {
          @synchronized (lock) {
            ok++;
          }
        }
      });
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    check(ok == 24, @"concurrent", [NSString stringWithFormat:@"%ld of 24 answered", (long)ok]);

    // Behind a proxy that signs users in: who is asking, from its headers.
    HSTrustedHeaderAuthenticator *proxy = [[HSTrustedHeaderAuthenticator alloc] init];
    proxy.secretHeader = @"X-OIS-Proxy-Secret";
    proxy.secret = @"s3cret";
    service.authenticator = proxy;
    OISReply *anonymous = OISSend(@"GET", @"/odata/Products", nil, nil);
    check(anonymous.status == 401 && [anonymous.headers[@"www-authenticate"] isEqual:@"Bearer"], @"sign-in-required",
          [NSString stringWithFormat:@"%ld %@", (long)anonymous.status, anonymous.headers]);
    OISReply *signedIn = OISSend(@"GET", @"/odata/Products", @{ @"x-forwarded-user": @"ann", @"X-OIS-Proxy-Secret": @"s3cret" }, nil);
    check(signedIn.status == 200 && [signedIn.json[@"value"] count] == expected, @"signed-in", [NSString stringWithFormat:@"%ld %@", (long)signedIn.status, signedIn.text]);
    OISReply *bypassed = OISSend(@"GET", @"/odata/Products", @{ @"X-Forwarded-User": @"ann" }, nil);
    check(bypassed.status == 401, @"proxy-bypassed", [NSString stringWithFormat:@"%ld", (long)bypassed.status]);
    service.authenticator = nil;
    [server stop];

    // Settings from the environment, as a container has them: the property
    // list first, then OIS_ variables, then the command line.
    NSDictionary *variables = @{ @"Port": @"OIS_PORT", @"MaxPageSize": @"OIS_MAX_PAGE_SIZE", @"JWTIssuer": @"OIS_JWT_ISSUER",
                             @"MaxURLLength": @"OIS_MAX_URL_LENGTH", @"ServiceRoot": @"OIS_SERVICE_ROOT", @"MaxJSONDepth": @"OIS_MAX_JSON_DEPTH" };
    NSMutableArray *misnamed = [NSMutableArray array];
    for (NSString *name in variables) {
      NSString *variable = [ODataServerConfiguration environmentVariableForSetting:name];
      if (![variable isEqualToString:variables[name]]) [misnamed addObject:[NSString stringWithFormat:@"%@: %@", name, variable]];
    }
    check(!misnamed.count, @"env-names", [misnamed componentsJoinedByString:@", "]);
    NSString *plist = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ois-serve-check.plist"];
    [@{ @"Port": @7000, @"HealthPath": @"/up", @"Namespace": @"FromFile" } writeToFile:plist atomically:YES];
    HSConfiguration *fromEnvironment = [ODataServerConfiguration configurationWithArguments:@{ @"Namespace": @"FromArguments" }
      environment:@{ @"OIS_CONFIG": plist, @"OIS_PORT": @"7001", @"OIS_LOCALHOST": @"NO", @"OIS_NAMESPACE": @"FromEnvironment",
                     @"OIS_TRUSTED_CLAIM_HEADERS": @"{\"email\": \"X-Mail\"}", @"OIS_REPORT_TITLE": @"Daily",
                     @"OIS_BUNDLES": @"/a.bundle:/b.bundle", @"HOME": @"/root" } error:&error];
    check(fromEnvironment.port == 7001 && !fromEnvironment.bindToLocalhost && [fromEnvironment.healthPath isEqual:@"/up"] &&
          [fromEnvironment.settings[@"Namespace"] isEqual:@"FromArguments"] &&
          [fromEnvironment.settings[@"TrustedClaimHeaders"] isEqual:@{ @"email": @"X-Mail" }] &&
          [fromEnvironment.settings[@"ReportTitle"] isEqual:@"Daily"] &&
          [fromEnvironment.bundlePaths isEqual:(@[ @"/a.bundle", @"/b.bundle" ])] && !fromEnvironment.settings[@"Home"],
          @"env-settings", [NSString stringWithFormat:@"%@ %@", fromEnvironment.settings, error ?: @""]);
    [[NSFileManager defaultManager] removeItemAtPath:plist error:NULL];

    // An authenticator that answers later, asked for a host: no service, no
    // context, and the answer still comes.
    HSAuthenticationReply *deferredAnswer = OISAskLater(@"Token ann");
    check([deferredAnswer.principal.subject isEqual:@"ann"] && !deferredAnswer.error, @"auth-deferred", deferredAnswer.principal.subject ?: @"(no answer)");
    HSAuthenticationReply *nobody = OISAskLater(nil);
    check(nobody && !nobody.principal && !nobody.error, @"auth-no-one", nobody ? @"no one" : @"(no answer)");
    HSAuthenticationReply *banned = OISAskLater(@"Token banned");
    check(banned.error.code == 401 && [banned.error.domain isEqualToString:HSErrorDomain], @"auth-refused",
          [NSString stringWithFormat:@"%ld %@", (long)banned.error.code, banned.error.domain]);

    // An application of its own, made from settings as ois-serve's are:
    // routes and stages around the service, one sign-in for all of them.
    HSConfiguration *configuration = [[HSConfiguration alloc] initWithSettings:@{
      @"Model": modelPath, @"ServiceRoot": @"https://api.example.test/odata/", @"TrustedUserHeader": @"X-Forwarded-User",
      @"CORSOrigins": @"https://app.example.test", @"MaxBodyInMemory": @1000 }];
    OISCheckApplication *application = [[OISCheckApplication alloc] initWithConfiguration:configuration];
    NSMutableData *fileBytes = [NSMutableData dataWithLength:100000];
    for (NSUInteger i = 0; i < fileBytes.length; i++) ((uint8_t *)fileBytes.mutableBytes)[i] = (uint8_t)(i * 7);
    application.file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ois-serve-check.bin"]];
    [fileBytes writeToURL:application.file atomically:YES];
    BOOL prepared = [application prepare:&error];
    check(prepared, @"app-prepare", [NSString stringWithFormat:@"%@\n%@\n%@", error ?: @"", application.pipeline, application.router]);
    if (!prepared) return 1;
    started = [application.server startOnPort:0 error:&error];
    port = application.server.port;
    check(started, @"app-start", [NSString stringWithFormat:@"port %lu %@", (unsigned long)port, error ?: @""]);
    if (!started) return 1;
    NSDictionary *ann = @{ @"X-Forwarded-User": @"ann" };

    OISReply *health = OISSend(@"GET", @"/health", nil, nil);
    check(health.status == 200 && [health.json[@"status"] isEqual:@"ok"], @"app-health", health.text);
    OISReply *hello = OISSend(@"GET", @"/hello/world", ann, nil);
    check(hello.status == 200 && [hello.json[@"hello"] isEqual:@"world"] && [hello.json[@"asker"] isEqual:@"ann"],
          @"app-route", [NSString stringWithFormat:@"%ld %@", (long)hello.status, hello.text]);
    check([hello.headers[@"x-order"] isEqual:@"a>b>handler<b<a"], @"app-stage-order", hello.headers[@"x-order"] ?: @"(none)");
    check([hello.headers[@"x-request-id"] length] > 0, @"app-request-id", hello.headers[@"x-request-id"] ?: @"(none)");
    OISReply *given = OISSend(@"GET", @"/hello/x", @{ @"X-Request-ID": @"abc-123" }, nil);
    check([given.headers[@"x-request-id"] isEqual:@"abc-123"], @"app-request-id-given", given.headers[@"x-request-id"] ?: @"(none)");
    OISReply *anyone = OISSend(@"GET", @"/hello/x", nil, nil);
    check(anyone.status == 200 && anyone.json[@"asker"] == [NSNull null], @"app-route-anyone", anyone.text);

    OISReply *blocked = OISSend(@"GET", @"/blocked", nil, nil);
    check(blocked.status == 418 && [blocked.headers[@"x-blocked-saw"] isEqual:@"418"] && [blocked.headers[@"x-order"] isEqual:@"a>b><b<a"],
          @"app-stage-answers", [NSString stringWithFormat:@"%ld %@ %@", (long)blocked.status, blocked.headers[@"x-blocked-saw"], blocked.headers[@"x-order"]]);
    OISReply *later = OISSend(@"GET", @"/later", nil, nil);
    check(later.status == 202 && [later.text isEqual:@"later"] && [later.headers[@"x-order"] isEqual:@"a>b><b<a"],
          @"app-deferred", [NSString stringWithFormat:@"%ld %@ %@", (long)later.status, later.text, later.headers[@"x-order"]]);
    OISReply *boom = OISSend(@"GET", @"/boom", nil, nil);
    check(boom.status == 500 && [boom.json[@"detail"] length] && [boom.headers[@"content-type"] isEqual:@"application/problem+json"], @"app-exception", [NSString stringWithFormat:@"%ld %@", (long)boom.status, boom.text]);

    OISReply *wrongMethod = OISSend(@"DELETE", @"/hello/x", nil, nil);
    check(wrongMethod.status == 405 && [wrongMethod.headers[@"allow"] isEqual:@"GET, HEAD"], @"app-405",
          [NSString stringWithFormat:@"%ld %@", (long)wrongMethod.status, wrongMethod.headers[@"allow"]]);
    OISReply *nowhere = OISSend(@"GET", @"/nowhere", nil, nil);
    check(nowhere.status == 404 && [nowhere.json[@"status"] isEqual:@404] && [nowhere.json[@"title"] isEqual:@"Not Found"] &&
          [nowhere.json[@"type"] isEqual:@"about:blank"] && [nowhere.headers[@"content-type"] isEqual:@"application/problem+json"],
          @"app-404", nowhere.text);
    OISReply *headOnly = OISSend(@"HEAD", @"/hello/x", nil, nil);
    check(headOnly.status == 200 && headOnly.body.length == 0, @"app-head", [NSString stringWithFormat:@"%ld, %lu bytes", (long)headOnly.status, (unsigned long)headOnly.body.length]);

    OISReply *noOne = OISSend(@"GET", @"/members", nil, nil);
    check(noOne.status == 401 && [noOne.headers[@"www-authenticate"] hasPrefix:@"Bearer"], @"app-route-signed-in", [NSString stringWithFormat:@"%ld %@", (long)noOne.status, noOne.headers[@"www-authenticate"]]);
    check(OISSend(@"GET", @"/members", ann, nil).status == 200, @"app-route-member", @"");
    OISReply *unscoped = OISSend(@"POST", @"/webhooks/billing", ann, @{});
    check(unscoped.status == 403 && [unscoped.headers[@"www-authenticate"] containsString:@"scope=\"Billing.Notify\""], @"app-route-scopes",
          [NSString stringWithFormat:@"%ld %@", (long)unscoped.status, unscoped.headers[@"www-authenticate"]]);

    // The service behind the same sign-in, not asking again.
    OISReply *odataAnonymous = OISSend(@"GET", @"/odata/Products", nil, nil);
    check(odataAnonymous.status == 401, @"app-odata-sign-in", [NSString stringWithFormat:@"%ld %@", (long)odataAnonymous.status, odataAnonymous.text]);
    OISReply *odata = OISSend(@"GET", @"/odata/Products", ann, nil);
    check(odata.status == 200 && [odata.json[@"@odata.context"] isEqual:@"https://api.example.test/odata/$metadata#Products"], @"app-odata",
          [NSString stringWithFormat:@"%ld %@", (long)odata.status, odata.text]);
    OISReply *metadataAgain = OISSend(@"GET", @"/odata/$metadata", ann, nil);
    check(metadataAgain.status == 200 && [metadataAgain.headers[@"x-order"] isEqual:@"a>b><b<a"], @"app-odata-stages", metadataAgain.headers[@"x-order"] ?: @"(none)");

    NSArray *lines;
    @synchronized (application.log) {
      lines = [application.log.lines copy];
    }
    NSString *helloLine = nil;
    for (NSString *line in lines) if ([line containsString:@"\"GET /hello/world\" 200"]) helloLine = line;
    check(helloLine && [helloLine containsString:@" ann "], @"app-access-log", helloLine ?: [lines componentsJoinedByString:@"\n"]);

    // Browsers on other origins.
    NSDictionary *preflightHeaders = @{ @"Origin": @"https://app.example.test", @"Access-Control-Request-Method": @"GET",
                                        @"Access-Control-Request-Headers": @"authorization, x-unknown" };
    OISReply *preflight = OISSend(@"OPTIONS", @"/members", preflightHeaders, nil);
    check(preflight.status == 204 && [preflight.headers[@"access-control-allow-origin"] isEqual:@"https://app.example.test"] &&
          [preflight.headers[@"access-control-allow-headers"] isEqual:@"Authorization"] && [preflight.headers[@"vary"] containsString:@"Origin"] &&
          [preflight.headers[@"access-control-max-age"] isEqual:@"600"],
          @"cors-preflight", [NSString stringWithFormat:@"%ld %@", (long)preflight.status, preflight.headers]);
    OISReply *foreign = OISSend(@"OPTIONS", @"/hello/x", @{ @"Origin": @"https://evil.example.test", @"Access-Control-Request-Method": @"GET" }, nil);
    check(foreign.status == 403 && !foreign.headers[@"access-control-allow-origin"], @"cors-preflight-refused",
          [NSString stringWithFormat:@"%ld", (long)foreign.status]);
    OISReply *simple = OISSend(@"GET", @"/hello/x", @{ @"Origin": @"https://app.example.test" }, nil);
    check([simple.headers[@"access-control-allow-origin"] isEqual:@"https://app.example.test"] &&
          [simple.headers[@"access-control-expose-headers"] containsString:@"OData-Version"], @"cors-simple", [simple.headers description]);
    check(!OISSend(@"GET", @"/hello/x", nil, nil).headers[@"access-control-allow-origin"] &&
          !OISSend(@"GET", @"/hello/x", @{ @"Origin": @"https://evil.example.test" }, nil).headers[@"access-control-allow-origin"],
          @"cors-not-asked", @"");

    // gzip, to a client that takes it.
    OISReply *plainJSON = OISSend(@"GET", @"/bodies/json", nil, nil);
    OISReply *gzipped = OISSend(@"GET", @"/bodies/json", @{ @"Accept-Encoding": @"gzip, deflate" }, nil);
    NSData *inflated = OISGunzip(gzipped.body);
    check(!plainJSON.headers[@"content-encoding"] && [plainJSON.headers[@"vary"] containsString:@"Accept-Encoding"] &&
          [gzipped.headers[@"content-encoding"] isEqual:@"gzip"] && gzipped.body.length < plainJSON.body.length &&
          [inflated isEqualToData:plainJSON.body],
          @"compression", [NSString stringWithFormat:@"%lu -> %lu bytes, %@", (unsigned long)plainJSON.body.length,
                                                     (unsigned long)gzipped.body.length, gzipped.headers[@"content-encoding"] ?: @"identity"]);
    OISReply *refusing = OISSend(@"GET", @"/bodies/json", @{ @"Accept-Encoding": @"gzip;q=0" }, nil);
    OISReply *small = OISSend(@"GET", @"/hello/x", @{ @"Accept-Encoding": @"gzip" }, nil);
    check(!refusing.headers[@"content-encoding"] && !small.headers[@"content-encoding"], @"compression-not-asked", @"");

    // Bodies from a file and a stream; a large request body in a file.
    OISReply *download = OISSend(@"GET", @"/bodies/file", nil, nil);
    check(download.status == 200 && [download.body isEqualToData:fileBytes], @"file-response",
          [NSString stringWithFormat:@"%ld, %lu bytes", (long)download.status, (unsigned long)download.body.length]);
    OISReply *streamed = OISSend(@"GET", @"/bodies/stream", nil, nil);
    check(streamed.status == 200 && [streamed.text isEqual:@"one,two,three"] && [streamed.headers[@"transfer-encoding"] isEqual:@"chunked"],
          @"stream-response", [NSString stringWithFormat:@"%ld %@ %@", (long)streamed.status, streamed.text, streamed.headers[@"transfer-encoding"]]);
    NSMutableString *large = [NSMutableString string];
    while (large.length < 5000) [large appendString:@"0123456789"];
    OISReply *inFile = OISSend(@"POST", @"/bodies/echo", nil, @[ large ]);
    OISReply *inMemory = OISSend(@"POST", @"/bodies/echo", nil, @[ @"small" ]);
    check([inFile.json[@"inFile"] boolValue] && [inFile.json[@"size"] integerValue] > 5000 &&
          ![inMemory.json[@"inFile"] boolValue] && [inMemory.json[@"size"] integerValue] == 9,
          @"request-body-file", [NSString stringWithFormat:@"%@ %@", inFile.text, inMemory.text]);

    // One connection, several requests: kept open between them, closed when
    // asked, or after a while with nothing more.
    int fd = OISConnect();
    NSMutableData *buffer = [NSMutableData data];
    NSString *host = [NSString stringWithFormat:@"Host: 127.0.0.1:%lu\r\n", (unsigned long)port];
    OISWrite(fd, [NSString stringWithFormat:@"GET /hello/one HTTP/1.1\r\n%@\r\n", host]);
    OISReply *first = OISReadOne(fd, buffer, NO);
    OISWrite(fd, [NSString stringWithFormat:@"GET /bodies/stream HTTP/1.1\r\n%@\r\n", host]);
    OISReply *second = OISReadOne(fd, buffer, NO);
    OISWrite(fd, [NSString stringWithFormat:@"POST /bodies/echo HTTP/1.1\r\n%@Content-Type: application/json\r\nContent-Length: 9\r\n\r\n[\"small\"]", host]);
    OISReply *third = OISReadOne(fd, buffer, NO);
    OISWrite(fd, [NSString stringWithFormat:@"HEAD /hello/four HTTP/1.1\r\n%@\r\n", host]);
    OISReply *fourth = OISReadOne(fd, buffer, YES);
    OISWrite(fd, [NSString stringWithFormat:@"GET /odata/$metadata HTTP/1.1\r\n%@X-Forwarded-User: ann\r\nConnection: close\r\n\r\n", host]);
    OISReply *last = OISReadOne(fd, buffer, NO);
    check([first.json[@"hello"] isEqual:@"one"] && [first.headers[@"connection"] isEqual:@"keep-alive"] &&
          [second.text isEqual:@"one,two,three"] && [third.json[@"size"] integerValue] == 9 &&
          fourth.status == 200 && last.status == 200 && [last.headers[@"connection"] caseInsensitiveCompare:@"close"] == NSOrderedSame &&
          OISClosed(fd),
          @"keep-alive", [NSString stringWithFormat:@"%ld %ld %ld %ld %ld, %@ then %@", (long)first.status, (long)second.status, (long)third.status,
                                                    (long)fourth.status, (long)last.status, first.headers[@"connection"], last.headers[@"connection"]]);
    close(fd);
    // HTTP/1.0, and a request that came with the next one behind it: closed.
    fd = OISConnect();
    buffer = [NSMutableData data];
    OISWrite(fd, @"GET /hello/old HTTP/1.0\r\n\r\n");
    OISReply *old10 = OISReadOne(fd, buffer, NO);
    check(old10.status == 200 && OISClosed(fd), @"keep-alive-http10", [NSString stringWithFormat:@"%ld %@", (long)old10.status, old10.headers[@"connection"]]);
    close(fd);
    fd = OISConnect();
    buffer = [NSMutableData data];
    OISWrite(fd, [NSString stringWithFormat:@"GET /hello/a HTTP/1.1\r\n%@\r\nGET /hello/b HTTP/1.1\r\n%@\r\n", host, host]);
    OISReply *pipelined = OISReadOne(fd, buffer, NO);
    check(pipelined.status == 200 && [pipelined.headers[@"connection"] caseInsensitiveCompare:@"close"] == NSOrderedSame,
          @"keep-alive-pipelined", [NSString stringWithFormat:@"%ld %@", (long)pipelined.status, pipelined.headers[@"connection"]]);
    close(fd);

    [application.server stop];
    [[NSFileManager defaultManager] removeItemAtURL:application.file error:NULL];

    // What the server says about itself.
    HSConfiguration *observedSettings = [[HSConfiguration alloc] initWithSettings:@{
      @"Model": modelPath, @"ServiceRoot": @"https://api.example.test/odata/", @"AccessLog": @"json", @"AdminPort": @1 }];
    OISObservedApplication *observed = [[OISObservedApplication alloc] initWithConfiguration:observedSettings];
    BOOL observing = [observed prepare:&error] && [observed.server startOnPort:0 error:&error] && [observed.adminServer startOnPort:0 error:&error];
    check(observing, @"observed-start", [NSString stringWithFormat:@"%@", error ?: @""]);
    if (observing) {
      port = observed.server.port;
      NSUInteger mainPort = port, adminPort = observed.adminServer.port;
      OISSend(@"GET", @"/trace", nil, nil);
      OISSend(@"GET", @"/odata/Products", nil, nil);
      OISSend(@"GET", @"/odata/Products(1)", nil, nil);
      OISSend(@"GET", @"/odata/Nothing", nil, nil);
      OISSend(@"GET", @"/nowhere", nil, nil);

      // W3C trace context: a well-formed traceparent's trace is kept, with a
      // span of this server's; one that is not begins a new trace.
      NSString *parent = @"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
      OISReply *traced = OISSend(@"GET", @"/trace", @{ @"traceparent": parent }, nil);
      NSString *traceparent = traced.json[@"traceparent"];
      check([traced.json[@"trace"] isEqual:@"0af7651916cd43dd8448eb211c80319c"] && [traceparent hasPrefix:@"00-0af7651916cd43dd8448eb211c80319c-"] &&
            [traceparent hasSuffix:@"-01"] && ![traced.json[@"span"] isEqual:@"b7ad6b7169203331"] && [traced.json[@"span"] length] == 16,
            @"trace-context", traced.text);
      OISReply *untraced = OISSend(@"GET", @"/trace", @{ @"traceparent": @"00-00000000000000000000000000000000-b7ad6b7169203331-01" }, nil);
      check([untraced.json[@"trace"] length] == 32 && ![untraced.json[@"trace"] hasPrefix:@"0000"], @"trace-context-new", untraced.text);

      // Metrics: not on the public listener when there is an admin one.
      check(OISSend(@"GET", @"/metrics", nil, nil).status == 404, @"metrics-not-public", @"");
      port = adminPort;
      OISReply *scraped = OISSend(@"GET", @"/metrics", nil, nil);
      NSString *exposition = scraped.text;
      // (The store is empty: Products(1) is a 404 too; and the /metrics
      // asked of the public listener was one no route took.)
      NSArray *expected = @[ @"http_requests_total{method=\"GET\",route=\"/trace\",status=\"200\"} 3",
                             @"http_requests_total{method=\"GET\",route=\"(none)\",status=\"404\"} 2",
                             @"http_requests_total{method=\"GET\",route=\"/odata/*\",status=\"404\"} 2",
                             @"http_operations_total{method=\"GET\",operation=\"Products\",route=\"/odata/*\",status=\"200\"} 1",
                             @"http_operations_total{method=\"GET\",operation=\"Products\",route=\"/odata/*\",status=\"404\"} 1",
                             @"http_operations_total{method=\"GET\",operation=\"(other)\",route=\"/odata/*\",status=\"404\"} 1",
                             @"http_operations_total{method=\"GET\",operation=\"echoTrace\",route=\"/trace\",status=\"200\"} 3",
                             @"http_request_duration_seconds_bucket{method=\"GET\",route=\"/trace\",le=\"+Inf\"} 3",
                             @"http_request_duration_seconds_count{method=\"GET\",route=\"/trace\"} 3",
                             @"# TYPE http_request_duration_seconds histogram", @"http_requests_in_flight 0",
                             @"process_start_time_seconds ", @"httpserverkit_build_info{version=" ];
      NSMutableArray *missing = [NSMutableArray array];
      for (NSString *line in expected) if (![exposition containsString:line]) [missing addObject:line];
      check(scraped.status == 200 && [scraped.headers[@"content-type"] hasPrefix:@"text/plain; version=0.0.4"] && !missing.count,
            @"metrics", missing.count ? [NSString stringWithFormat:@"missing %@ in\n%@", missing, exposition] : @"");

      // Readiness: the store answers, and every check passes; then one
      // fails; then the server drains.
      OISReply *ready = OISSend(@"GET", @"/ready", nil, nil);
      check(ready.status == 200 && [ready.json[@"checks"][@"store"] isEqual:@"ok"] && [ready.json[@"checks"][@"switch"] isEqual:@"ok"],
            @"ready", ready.text);
      observed.check.failing = YES;
      OISReply *unready = OISSend(@"GET", @"/ready", nil, nil);
      check(unready.status == 503 && [unready.json[@"checks"][@"switch"] isEqual:@"switched off"], @"ready-check-fails", unready.text);
      observed.check.failing = NO;
      check(OISSend(@"GET", @"/health", nil, nil).status == 200, @"health-admin", @"");
      port = mainPort;
      check(OISSend(@"GET", @"/health", nil, nil).status == 200 && OISSend(@"GET", @"/ready", nil, nil).status == 200, @"health-public", @"");

      // The access log, as JSON lines.
      NSDictionary *traceLine = nil;
      NSArray *jsonLines;
      @synchronized (observed.log) {
        jsonLines = [observed.log.lines copy];
      }
      for (NSString *line in jsonLines) {
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if ([entry[@"trace_id"] isEqual:@"0af7651916cd43dd8448eb211c80319c"]) traceLine = entry;
      }
      check([traceLine[@"route"] isEqual:@"/trace"] && [traceLine[@"operation"] isEqual:@"echoTrace"] && [traceLine[@"status"] integerValue] == 200 &&
            [traceLine[@"level"] isEqual:@"info"] && [traceLine[@"time"] hasSuffix:@"Z"] && [traceLine[@"request_id"] length] > 0,
            @"access-log-json", traceLine ? traceLine.description : [jsonLines componentsJoinedByString:@"\n"]);

      // A graceful stop: not ready, no new connections, and the request under
      // way finished before it returns.
      __block OISReply *slow = nil;
      dispatch_semaphore_t slowDone = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(0, 0), ^{
        slow = OISSend(@"GET", @"/slow", nil, nil);
        dispatch_semaphore_signal(slowDone);
      });
      [NSThread sleepForTimeInterval:0.15];
      [observed drain];
      port = adminPort;
      OISReply *draining = OISSend(@"GET", @"/ready", nil, nil);
      port = mainPort;
      NSDate *stopping = [NSDate date];
      BOOL stoppedCleanly = [observed stopWithTimeout:5];
      NSTimeInterval stopTook = -[stopping timeIntervalSinceNow];
      dispatch_semaphore_wait(slowDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
      check(draining.status == 503 && [draining.json[@"status"] isEqual:@"draining"] && stoppedCleanly && slow.status == 202 &&
            stopTook > 0.2 && OISSend(@"GET", @"/health", nil, nil) == nil,
            @"graceful-stop", [NSString stringWithFormat:@"ready %ld, stopped %@ after %.2fs, slow %ld", (long)draining.status,
                                                         stoppedCleanly ? @"cleanly" : @"with requests left", stopTook, (long)slow.status]);
    }

    // A kept connection with nothing more to ask is closed after the timeout.
    // On every address, IPv4 and IPv6 both (Localhost NO), as in a container.
    // Behind a proxy that sends a secret: a request without it is refused by
    // the authentication stage, before any route, in the format of the API
    // it was for.
    setenv("OIS_CHECK_PROXY_SECRET", "s3cret", 1);
    HSConfiguration *briefly = [[HSConfiguration alloc] initWithSettings:@{
      @"Model": modelPath, @"KeepAliveTimeout": @0.5, @"AccessLog": @NO, @"Localhost": @NO,
      @"TrustedUserHeader": @"X-Forwarded-User", @"ProxySecretHeader": @"X-Proxy-Secret", @"ProxySecretEnvironment": @"OIS_CHECK_PROXY_SECRET",
      @"AllowAnonymous": @YES }];
    HSApplication *brief = [[ODataServerApplication alloc] initWithConfiguration:briefly];
    if ([brief prepare:&error] && [brief.server startOnPort:0 error:&error]) {
      port = brief.server.port;
      fd = OISConnect();
      buffer = [NSMutableData data];
      OISWrite(fd, [NSString stringWithFormat:@"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"]);
      OISReply *healthy = OISReadOne(fd, buffer, NO);  // refused (no proxy secret), and kept
      NSDate *started = [NSDate date];
      BOOL closed = OISClosed(fd);
      NSTimeInterval waited = -[started timeIntervalSinceNow];
      check(healthy.status == 401 && closed && waited > 0.3 && waited < 3, @"keep-alive-timeout",
            [NSString stringWithFormat:@"%ld, closed %@ after %.2fs", (long)healthy.status, closed ? @"YES" : @"NO", waited]);
      close(fd);
      NSDictionary *proxied = @{ @"X-Proxy-Secret": @"s3cret" };
      OISReply *odataRefused = OISSend(@"GET", @"/odata/Products", nil, nil);
      OISReply *otherRefused = OISSend(@"GET", @"/health", nil, nil);
      check(odataRefused.status == 401 && [odataRefused.json[@"error"][@"message"] length] &&
            [otherRefused.headers[@"content-type"] isEqual:@"application/problem+json"] && [otherRefused.json[@"status"] isEqual:@401] &&
            OISSend(@"GET", @"/odata/Products", proxied, nil).status == 200 && OISSend(@"GET", @"/health", proxied, nil).status == 200,
            @"error-format-by-route", [NSString stringWithFormat:@"%@ | %@", odataRefused.text, otherRefused.text]);
      [brief.server stop];
      check([brief.metrics valueOf:@"http_auth_failures_total" labels:@{ @"reason": @"proxy_secret" }] >= 3, @"auth-failure-metrics",
            [NSString stringWithFormat:@"proxy_secret %.0f", [brief.metrics valueOf:@"http_auth_failures_total" labels:@{ @"reason": @"proxy_secret" }]]);
    } else {
      check(NO, @"keep-alive-timeout", error.localizedDescription ?: @"");
    }

    // $metadata to anyone, so that a client reads how to sign in before it
    // has (OpenID Connect, its issuer): AllowAnonymousMetadata, from the
    // environment of an application with settings of its own; the rest
    // still signed in.
    HSConfiguration *own = [OISOwnConfiguration configurationWithArguments:@{ @"Model": modelPath, @"AccessLog": @NO,
                                                                              @"JWTIssuer": @"https://id.example.test/realms/notes" }
                                                               environment:@{ @"OWN_ALLOW_ANONYMOUS_METADATA": @"YES" } error:&error];
    HSApplication *open = own ? [[ODataServerApplication alloc] initWithConfiguration:own] : nil;
    if (open && [open prepare:&error] && [open.server startOnPort:0 error:&error]) {
      port = open.server.port;
      OISReply *described = OISSend(@"GET", @"/odata/$metadata", nil, nil);
      OISReply *served = OISSend(@"GET", @"/odata/", nil, nil);
      OISReply *rows = OISSend(@"GET", @"/odata/Products", nil, nil);
      check(described.status == 200 && [described.text containsString:@"https://id.example.test/realms/notes"] && served.status == 200 &&
            rows.status == 401,
            @"anonymous-metadata-setting", [NSString stringWithFormat:@"$metadata %ld, service document %ld, Products %ld",
                                            (long)described.status, (long)served.status, (long)rows.status]);
      [open.server stop];
    } else {
      check(NO, @"anonymous-metadata-setting", error.localizedDescription ?: @"");
    }

    // A request's trace, in memory: the server's span under the caller's,
    // the service's under it, and its plan, execution and store requests
    // under that; the access log's line with the same trace.
    {
      OTInMemoryExporter *memory = [[OTInMemoryExporter alloc] init];
      OTTracerProvider.sharedProvider =
          [[OTTracerProvider alloc] initWithResource:@{ @"service.name": @"ois-serve-check" } sampler:[[OTRatioSampler alloc] initWithRatio:1]
                                           processor:[[OTSimpleSpanProcessor alloc] initWithExporter:memory]];
      OISCapturingLog *captured = [[OISCapturingLog alloc] init];
      HSLog.sharedLog = captured;
      ODataServerApplication *traced = [[ODataServerApplication alloc]
          initWithConfiguration:[[ODataServerConfiguration alloc] initWithSettings:@{ @"Model": modelPath, @"AccessLog": @"json" }]];
      if ([traced prepare:&error] && [traced.server startOnPort:0 error:&error]) {
        port = traced.server.port;
        NSString *caller = @"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
        OISReply *read = OISSend(@"GET", @"/odata/Products?$top=2", @{ @"traceparent": caller }, nil);
        NSArray<OTSpan *> *spans = memory.spans;
        OTSpan *server = OISSpanNamed(spans, @"GET /odata/*");
        OTSpan *service = OISSpanNamed(spans, @"ODataService GET Products");
        OTSpan *plan = OISSpanNamed(spans, @"plan");
        OTSpan *execute = OISSpanNamed(spans, @"execute");
        OTSpan *fetch = OISSpanNamed(spans, @"fetch Product");
        BOOL nested = server && service && plan && execute && fetch &&
                      [server.context.traceID isEqual:@"4bf92f3577b34da6a3ce929d0e0e4736"] && [server.parentSpanID isEqual:@"00f067aa0ba902b7"] &&
                      server.kind == OTSpanKindServer && [server.attributes[@"http.response.status_code"] isEqual:@200] &&
                      [service.parentSpanID isEqual:server.context.spanID] && [plan.parentSpanID isEqual:service.context.spanID] &&
                      [execute.parentSpanID isEqual:service.context.spanID] && [fetch.parentSpanID isEqual:execute.context.spanID] &&
                      [plan.attributes[@"odata.plan"] length] > 0 && [fetch.attributes[@"db.collection.name"] isEqual:@"Product"] &&
                      plan.endTime <= execute.startTime && fetch.startTime >= execute.startTime && fetch.endTime <= execute.endTime;
        check(read.status == 200 && nested, @"trace-nesting",
              [NSString stringWithFormat:@"%ld: %@", (long)read.status, [[spans valueForKey:@"description"] componentsJoinedByString:@" | "]]);

        NSString *accessLine = nil;
        for (NSString *line in [captured taken]) {
          if ([line rangeOfString:@"\"status\":200"].location != NSNotFound && [line rangeOfString:@"Products"].location != NSNotFound) accessLine = line;
        }
        NSDictionary *access = accessLine ? [NSJSONSerialization JSONObjectWithData:[accessLine dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
        check([access[@"trace_id"] isEqual:server.context.traceID] && [access[@"span_id"] isEqual:server.context.spanID], @"log-trace",
              accessLine ?: @"no access log line");

        HSMetrics *metrics = traced.metrics;
        double fetches = [metrics valueOf:@"odata_store_request_duration_seconds" labels:@{ @"operation": @"fetch", @"entity": @"Product" }];
        double plans = [metrics valueOf:@"odata_plan_duration_seconds" labels:@{ @"entity": @"Product" }];
        double executions = [metrics valueOf:@"odata_execution_duration_seconds" labels:@{ @"entity": @"Product" }];
        check(fetches >= 1 && plans >= 1 && executions >= 1, @"store-metrics",
              [NSString stringWithFormat:@"fetches %.0f, plans %.0f, executions %.0f", fetches, plans, executions]);
        [traced stopWithTimeout:5];
      } else {
        check(NO, @"trace-nesting", error.localizedDescription ?: @"");
      }
      OTTracerProvider.sharedProvider = nil;
      HSLog.sharedLog = nil;
    }

    // Spans exported over OTLP/HTTP to a collector, as the settings say;
    // and the identity provider's failure, counted, logged and traced.
    {
      OISCollector *collector = [[OISCollector alloc] init];
      HSServer *collecting = [[HSServer alloc] initWithHandler:collector];
      if ([collecting startOnPort:0 error:&error]) {
        NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%lu", (unsigned long)collecting.port];
        ODataServerApplication *exporting = [[ODataServerApplication alloc] initWithConfiguration:[[ODataServerConfiguration alloc] initWithSettings:@{
          @"Model": modelPath, @"OTLPEndpoint": base, @"ServiceName": @"catalog-check", @"AccessLog": @NO, @"AllowAnonymous": @YES,
          @"JWTIssuer": @"https://issuer.invalid", @"JWTKeysURL": [base stringByAppendingString:@"/keys"] }]];
        OISCapturingLog *captured = [[OISCapturingLog alloc] init];
        HSLog.sharedLog = captured;
        if ([exporting prepare:&error] && [exporting.server startOnPort:0 error:&error]) {
          port = exporting.server.port;
          NSString *token = [@[ OISBase64URL(@{ @"alg": @"RS256", @"kid": @"k1", @"typ": @"JWT" }), OISBase64URL(@{ @"sub": @"ann" }), @"c2ln" ]
                               componentsJoinedByString:@"."];
          OISReply *unavailable = OISSend(@"GET", @"/odata/Products", @{ @"Authorization": [@"Bearer " stringByAppendingString:token] }, nil);
          OISReply *anonymous = OISSend(@"GET", @"/odata/Products", nil, nil);
          HSMetrics *metrics = exporting.metrics;
          double refused = [metrics valueOf:@"http_auth_failures_total" labels:@{ @"reason": @"provider_unavailable" }];
          double asked = [metrics valueOf:@"http_auth_provider_requests_total" labels:@{ @"endpoint": @"keys", @"outcome": @"500" }];
          BOOL logged = NO;
          for (NSString *line in [captured taken]) {
            if ([line rangeOfString:@"HSJWTAuthenticator: warning:"].location != NSNotFound) logged = YES;
          }
          check(unavailable.status == 503 && anonymous.status == 200 && refused == 1 && asked == 1 && logged, @"provider-failure",
                [NSString stringWithFormat:@"%ld %ld, refused %.0f, asked %.0f, logged %@", (long)unavailable.status, (long)anonymous.status,
                                           refused, asked, logged ? @"YES" : @"NO"]);
          [exporting stopWithTimeout:5];
          NSArray<NSDictionary *> *sent = [collector spans];
          NSDictionary *keys = OISSentSpanNamed(sent, @"GET keys");
          NSDictionary *authenticate = OISSentSpanNamed(sent, @"authenticate");
          NSDictionary *fetch = OISSentSpanNamed(sent, @"fetch Product");
          NSDictionary *server = nil;
          for (NSDictionary *span in sent) {
            if ([span[@"name"] isEqual:@"GET /odata/*"] && [OISSentAttribute(span, @"http.response.status_code")[@"intValue"] isEqual:@"503"]) server = span;
          }
          BOOL exported = keys && authenticate && fetch && server && [keys[@"service"] isEqual:@"catalog-check"] && [keys[@"kind"] isEqual:@3] &&
                          [keys[@"parentSpanId"] isEqual:server[@"spanId"]] && [keys[@"traceId"] isEqual:server[@"traceId"]] &&
                          [OISSentAttribute(authenticate, @"auth.failure_reason")[@"stringValue"] isEqual:@"provider_unavailable"] &&
                          [server[@"startTimeUnixNano"] isKindOfClass:[NSString class]];
          check(exported && [exporting.metrics valueOf:@"otel_exporter_spans_total" labels:@{ @"outcome": @"exported" }] >= sent.count,
                @"otlp-export", [NSString stringWithFormat:@"%lu spans: %@", (unsigned long)sent.count,
                                                          [[sent valueForKey:@"name"] componentsJoinedByString:@", "]]);
        } else {
          check(NO, @"otlp-export", error.localizedDescription ?: @"");
        }
        HSLog.sharedLog = nil;
        [collecting stop];
      } else {
        check(NO, @"otlp-export", error.localizedDescription ?: @"");
      }
    }
    // Another tool's OTEL_ variables (a container build's: gRPC to a
    // socket) do not stop a server: it says so, and runs untraced.
    {
      NSError *failure = nil;
      ODataServerConfiguration *foreign = (ODataServerConfiguration *)[ODataServerConfiguration
          configurationWithArguments:@{ @"Model": modelPath }
                         environment:@{ @"OTEL_TRACES_EXPORTER": @"otlp", @"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": @"grpc",
                                        @"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": @"unix:///dev/otel-grpc.sock" }
                               error:&failure];
      ODataServerApplication *untraced = [[ODataServerApplication alloc] initWithConfiguration:foreign];
      BOOL prepared = [untraced prepare:&failure];
      NSString *warned = [[foreign.warnings filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'not tracing'"]] firstObject];
      check(prepared && warned && !untraced.tracerProvider, @"foreign-otel-variables", warned ?: failure.localizedDescription ?: @"no warning");
    }
    // Offline sync over HTTP (ODataSync): a device's store, with history,
    // and a service's, as FreeCoreData keeps them on GNUstep.
    {
      NSError *failure = nil;
      NSPersistentStoreCoordinator *served = OISSyncStore(OISSyncModel(), &failure);
      NSManagedObjectModel *deviceModel = OISSyncModel();
      [ODataSyncEngine addBookkeepingToModel:deviceModel configuration:nil];
      NSPersistentStoreCoordinator *device = served ? OISSyncStore(deviceModel, &failure) : nil;
      OISSyncWrite(served, ^(NSManagedObjectContext *context) {
        for (NSArray *a in @[ @[ @1, @"Pump" ], @[ @2, @"Valve" ] ]) {
          NSManagedObject *asset = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
          [asset setValue:a[0] forKey:@"id"];
          [asset setValue:a[1] forKey:@"name"];
        }
      });
      // The service's links are absolute: its root has the port it listens on.
      NSUInteger syncPort = OISFreePort();
      NSString *root = [NSString stringWithFormat:@"http://127.0.0.1:%lu/sync/", (unsigned long)syncPort];
      ODataService *syncService = served ? [[ODataService alloc] initWithPersistentStoreCoordinator:served serviceRoot:[NSURL URLWithString:root]] : nil;
      HSServer *syncServer = syncService ? [[HSServer alloc] initWithService:syncService] : nil;
      if (device && [syncServer startOnPort:syncPort error:&failure]) {
        ODataSyncEngine *engine = [[ODataSyncEngine alloc] initWithCoordinator:device];
        [engine addRemote:[ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:root]]];
        BOOL first = [engine syncWithError:&failure];
        NSArray *assets = OISSyncValues(device, @"Asset", @"name");
        NSString *identifier = [NSUUID UUID].UUIDString;
        OISSyncWrite(device, ^(NSManagedObjectContext *context) {
          NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
          [inspection setValue:identifier forKey:@"id"];
          [inspection setValue:@"Leaks" forKey:@"note"];
          [inspection setValue:OISSyncObject(context, @"Asset", @1) forKey:@"asset"];
        });
        OISSyncWrite(served, ^(NSManagedObjectContext *context) {
          [OISSyncObject(context, @"Asset", @2) setValue:@"Valve (new)" forKey:@"name"];
        });
        BOOL second = first && [engine syncWithError:&failure];
        NSArray *uploaded = OISSyncValues(served, @"Inspection", @"note");
        NSArray *renamed = OISSyncValues(device, @"Asset", @"name");
        OISSyncWrite(device, ^(NSManagedObjectContext *context) {
          [context deleteObject:OISSyncObject(context, @"Inspection", identifier)];
        });
        BOOL third = second && [engine syncWithError:&failure];
        NSArray *deleted = OISSyncValues(served, @"Inspection", @"note");
        check(first && second && third && [assets isEqual:@[ @"Pump", @"Valve" ]] && [uploaded isEqual:@[ @"Leaks" ]] &&
              [renamed isEqual:@[ @"Pump", @"Valve (new)" ]] && deleted.count == 0, @"offline-sync",
              [NSString stringWithFormat:@"%@ | down %@, up %@, renamed %@, deleted %@ (%@)", failure.localizedDescription ?: @"", assets, uploaded,
                                         renamed, deleted, engine.lastResult]);
        // Conflicts on a both entity: the device's saves stamped by its clock
        // (FreeCoreData's will-save notification), a three-way merge on
        // download, and a 412 on upload settled by the later stamp.
        failure = nil;
        [engine setResolver:[[ODataSyncMergeFields alloc] initWithFallback:[[ODataSyncLastWriterWins alloc] init]] forEntityName:@"Task"];
        NSString *task = [NSUUID UUID].UUIDString;
        OISSyncWrite(device, ^(NSManagedObjectContext *context) {
          NSManagedObject *made = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
          [made setValue:task forKey:@"id"];
          [made setValue:@"Check pump" forKey:@"title"];
          [made setValue:@NO forKey:@"done"];
        });
        NSString *stamp = OISSyncValues(device, @"Task", @"modified").firstObject;
        BOOL made = [engine syncWithError:&failure];
        OISSyncWrite(served, ^(NSManagedObjectContext *context) {
          [OISSyncObject(context, @"Task", task) setValue:@"Check pump today" forKey:@"title"];
        });
        OISSyncWrite(device, ^(NSManagedObjectContext *context) {
          [OISSyncObject(context, @"Task", task) setValue:@YES forKey:@"done"];
        });
        BOOL merged = made && [engine syncWithError:&failure];
        NSArray *mergedHere = @[ OISSyncValues(device, @"Task", @"title"), OISSyncValues(device, @"Task", @"done") ];
        NSArray *mergedThere = @[ OISSyncValues(served, @"Task", @"title"), OISSyncValues(served, @"Task", @"done") ];
        OISSyncWrite(served, ^(NSManagedObjectContext *context) {
          NSManagedObject *there = OISSyncObject(context, @"Task", task);
          [there setValue:@"Service's, earlier" forKey:@"title"];
          [there setValue:@"0000000000000001.0000.service0" forKey:@"modified"];
        });
        OISSyncWrite(device, ^(NSManagedObjectContext *context) {
          [OISSyncObject(context, @"Task", task) setValue:@"Device's, later" forKey:@"title"];
        });
        BOOL later = merged && [engine uploadToRemote:engine.remotes.firstObject error:&failure];
        NSArray *titles = @[ OISSyncValues(device, @"Task", @"title"), OISSyncValues(served, @"Task", @"title") ];
        NSArray *expected = @[ @[ @"Check pump today" ], @[ @YES ] ];
        NSArray *latest = @[ @"Device's, later" ];
        check(made && merged && later && [stamp hasSuffix:[engine.replicaID substringToIndex:8]] && [mergedHere isEqual:expected] &&
              [mergedThere isEqual:expected] && [titles isEqual:@[ latest, latest ]], @"offline-sync-conflicts",
              [NSString stringWithFormat:@"%@ | stamp %@, merged %@ / %@, later %@ (%@)", failure.localizedDescription ?: @"", stamp, mergedHere,
                                         mergedThere, titles, engine.lastResult]);
        // Peers over HTTP: a device without the service serves its store
        // (ODataSyncPeerServer); this one syncs with it, and passes its
        // inspection on to the service, and this one's task to it.
        failure = nil;
        NSManagedObjectModel *basementModel = OISSyncModel();
        [ODataSyncEngine addBookkeepingToModel:basementModel configuration:nil];
        NSPersistentStoreCoordinator *basement = OISSyncStore(basementModel, &failure);
        ODataSyncEngine *offline = basement ? [[ODataSyncEngine alloc] initWithCoordinator:basement] : nil;
        ODataSyncPeerServer *peers = offline ? [[ODataSyncPeerServer alloc] initWithEngine:offline host:@"127.0.0.1" port:OISFreePort()] : nil;
        NSString *carried = [NSUUID UUID].UUIDString;
        if (basement) {
          OISSyncWrite(basement, ^(NSManagedObjectContext *context) {
            NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
            [inspection setValue:carried forKey:@"id"];
            [inspection setValue:@"From the basement" forKey:@"note"];
          });
        }
        BOOL listening = [peers start:&failure];
        if (listening) [engine addRemote:[ODataSyncRemote peerWithServiceRoot:peers.serviceRoot]];
        // The service, then the peer; the service again with what the peer gave.
        BOOL relayed = listening && [engine syncWithError:&failure] && [engine syncWithError:&failure];
        NSArray *notes = OISSyncValues(device, @"Inspection", @"note");
        NSArray *atService = OISSyncValues(served, @"Inspection", @"note");
        NSArray *atPeer = basement ? OISSyncValues(basement, @"Task", @"title") : @[];
        check(relayed && [notes containsObject:@"From the basement"] && [atService isEqual:@[ @"From the basement" ]] &&
              [atPeer isEqual:latest], @"offline-sync-peers",
              [NSString stringWithFormat:@"%@ | here %@, at the service %@, task at the peer %@ (%@)", failure.localizedDescription ?: @"", notes,
                                         atService, atPeer, engine.lastResult]);
        [peers stop];
        // Version vectors over HTTP (docs/offline-sync.md, 12), the service
        // keeping deletions (ODataSyncService): a deletion sent with its
        // history, and a change made without knowing of one, settled by last
        // writer wins (409, the deletion's history in the error).
        failure = nil;
        NSManagedObjectModel *keptModel = OISSyncModelKeeping(YES);
        [ODataSyncService addBookkeepingToModel:keptModel configuration:nil];
        NSPersistentStoreCoordinator *kept = OISSyncStore(keptModel, &failure);
        NSManagedObjectModel *keepingModel = OISSyncModelKeeping(YES);
        [ODataSyncEngine addBookkeepingToModel:keepingModel configuration:nil];
        NSPersistentStoreCoordinator *keeping = kept ? OISSyncStore(keepingModel, &failure) : nil;
        NSUInteger keptPort = OISFreePort();
        NSString *keptRoot = [NSString stringWithFormat:@"http://127.0.0.1:%lu/kept/", (unsigned long)keptPort];
        ODataService *keptService = kept ? [[ODataService alloc] initWithPersistentStoreCoordinator:kept serviceRoot:[NSURL URLWithString:keptRoot]] : nil;
        ODataSyncService *histories = keptService ? [[ODataSyncService alloc] initWithService:keptService] : nil;
        HSServer *keptServer = keptService ? [[HSServer alloc] initWithService:keptService] : nil;
        BOOL keptUp = keeping && histories && [keptServer startOnPort:keptPort error:&failure];
        ODataSyncEngine *keeper = keptUp ? [[ODataSyncEngine alloc] initWithCoordinator:keeping] : nil;
        [keeper addRemote:[ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:keptRoot]]];
        [keeper setResolver:[[ODataSyncLastWriterWins alloc] init] forEntityName:@"Task"];
        NSString *gone = [NSUUID UUID].UUIDString, *edited = [NSUUID UUID].UUIDString;
        if (keeper) {
          OISSyncWrite(keeping, ^(NSManagedObjectContext *context) {
            for (NSString *identifier in @[ gone, edited ]) {
              NSManagedObject *made = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
              [made setValue:identifier forKey:@"id"];
              [made setValue:@"Check pump" forKey:@"title"];
              [made setValue:@NO forKey:@"done"];
            }
          });
        }
        BOOL keptFirst = keeper && [keeper syncWithError:&failure];
        NSString *sentVersions = OISSyncValues(kept, @"Task", @"versions").firstObject;
        if (keptFirst) {
          OISSyncWrite(keeping, ^(NSManagedObjectContext *context) {
            [context deleteObject:OISSyncObject(context, @"Task", gone)];
            [OISSyncObject(context, @"Task", edited) setValue:@"Check pump today" forKey:@"title"];
          });
          OISSyncWrite(kept, ^(NSManagedObjectContext *context) {
            [context deleteObject:OISSyncObject(context, @"Task", edited)];
          });
        }
        BOOL settled = keptFirst && [keeper uploadToRemote:keeper.remotes.firstObject error:&failure] && [keeper syncWithError:&failure];
        NSArray *keptTitles = OISSyncValues(kept, @"Task", @"title");
        NSArray *here = keeping ? OISSyncValues(keeping, @"Task", @"title") : @[];
        check(settled && [sentVersions length] && [keptTitles isEqual:@[ @"Check pump today" ]] && [here isEqual:keptTitles], @"offline-sync-versions",
              [NSString stringWithFormat:@"%@ | sent %@, at the service %@, here %@ (%@)", failure.localizedDescription ?: @"", sentVersions, keptTitles,
                                         here, keeper.lastResult]);
        [keptServer stop];
        [syncServer stop];
      } else {
        check(NO, @"offline-sync", failure.localizedDescription ?: @"no store");
      }
    }
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
  }
  return failures ? 1 : 0;
}
