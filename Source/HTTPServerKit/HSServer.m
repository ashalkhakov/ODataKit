// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSServer.h"
#import "HSLog.h"
#import "HSRouter.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerFileRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerStreamedResponse.h"
#include <errno.h>

@interface HSServer ()
- (void)requestDidFinish;
@end

// One request's way back to the socket.
@interface HSListenerAnswer : NSObject
@property (nonatomic, copy) GCDWebServerCompletionBlock completion;
@property (nonatomic) BOOL headOnly;
@property (nonatomic, weak) HSServer *server;
@end

@implementation HSListenerAnswer

- (void)replyDidFinish:(HSReply *)reply
{
  [self.server requestDidFinish];
  HSResponse *answer = reply.response;
  NSDictionary *headers = answer.headers;
  NSString *type = [answer valueForHeader:@"Content-Type"] ?: @"application/octet-stream";
  NSData *body = self.headOnly ? nil : answer.body;
  GCDWebServerResponse *response = nil;
  if (!self.headOnly && answer.bodyFileURL) {
    GCDWebServerFileResponse *file = [GCDWebServerFileResponse responseWithFile:answer.bodyFileURL.path];
    if (!file) {
      HSLogMessage(HSLogLevelError, @"HTTPServerKit", nil, @"%@ cannot be read", answer.bodyFileURL.path);
      self.completion([GCDWebServerResponse responseWithStatusCode:500]);
      return;
    }
    file.contentType = type;
    response = file;
  } else if (!self.headOnly && answer.bodyStream) {
    id<HSResponseStream> stream = answer.bodyStream;
    response = [GCDWebServerStreamedResponse responseWithContentType:type streamBlock:^NSData *(NSError **error) {
      return [stream nextChunk:error];
    }];
  } else if (body.length) {
    response = [GCDWebServerDataResponse responseWithData:body contentType:type];
  } else {
    response = [GCDWebServerResponse response];
  }
  response.statusCode = answer.status;
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame || [name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    [response setValue:headers[name] forAdditionalHeader:name];
  }
  // HEAD: the headers a GET would have, with no body.
  if (self.headOnly && answer.body.length && [answer valueForHeader:@"Content-Type"]) {
    [response setValue:[answer valueForHeader:@"Content-Type"] forAdditionalHeader:@"Content-Type"];
  }
  self.completion(response);
}

@end

@implementation HSServer {
  GCDWebServer *_server;
  NSUInteger _inFlight;
}

- (NSUInteger)requestsInFlight
{
  @synchronized (self) {
    return _inFlight;
  }
}

- (void)requestDidFinish
{
  @synchronized (self) {
    if (_inFlight) _inFlight--;
  }
}

- (instancetype)initWithHandler:(id<HSHandler>)handler
{
  self = [super init];
  if (!self) return nil;
  _handler = handler;
  _bindToLocalhost = YES;
  _maxBodySize = 64 * 1024 * 1024;
  _maxBodyInMemory = 1024 * 1024;
  _keepAliveTimeout = 5;
  _maxRequestsPerConnection = 100;
  _server = [[GCDWebServer alloc] init];
  __weak HSServer *weakSelf = self;
  [_server addHandlerWithMatchBlock:^GCDWebServerRequest *(NSString *method, NSURL *url, NSDictionary *headers, NSString *path, NSDictionary *query) {
    // A body too large for memory, or of a size not said, goes to a file.
    NSString *length = nil, *encoding = nil;
    for (NSString *name in headers) {
      if ([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) length = headers[name];
      if ([name caseInsensitiveCompare:@"Transfer-Encoding"] == NSOrderedSame) encoding = headers[name];
    }
    NSUInteger inMemory = weakSelf.maxBodyInMemory;
    BOOL toFile = encoding.length || (inMemory && length.longLongValue > (long long)inMemory);
    Class kind = toFile ? [GCDWebServerFileRequest class] : [GCDWebServerDataRequest class];
    return [[kind alloc] initWithMethod:method url:url headers:headers path:path query:query];
  } asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completion) {
    [weakSelf answer:request completion:completion];
  }];
  return self;
}

- (NSDictionary *)optionsForPort:(NSUInteger)port
{
  return @{
    GCDWebServerOption_Port: @(port),
    GCDWebServerOption_BindToLocalhost: @(self.bindToLocalhost),
    GCDWebServerOption_MaxBodySize: @(self.maxBodySize),
    GCDWebServerOption_ServerName: @"HTTPServerKit",
    GCDWebServerOption_AutomaticallyMapHEADToGET: @NO,
    GCDWebServerOption_KeepAliveTimeout: @(self.keepAliveTimeout),
    GCDWebServerOption_MaxRequestsPerConnection: @(self.maxRequestsPerConnection),
  };
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
  // With port 0 GCDWebServer takes the port the system picks for IPv4 and
  // binds IPv6 to the same one, which may be taken there: then any other
  // free port will do.
  for (int attempt = 0; attempt < 8; attempt++) {
    NSError *failure = nil;
    if ([_server startWithOptions:[self optionsForPort:port] error:&failure]) return YES;
    BOOL taken = [failure.domain isEqualToString:NSPOSIXErrorDomain] && failure.code == EADDRINUSE;
    if (port != 0 || !taken) {
      if (error) *error = failure;
      return NO;
    }
  }
  return [_server startWithOptions:[self optionsForPort:port] error:error];
}

- (BOOL)runOnPort:(NSUInteger)port error:(NSError **)error
{
#if defined(__APPLE__) && TARGET_OS_IPHONE
  // An app does not block its main thread serving: -startOnPort:error:.
  if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError
                                      userInfo:@{ NSLocalizedDescriptionKey: @"On iOS a server is started (-startOnPort:error:), not run" }];
  return NO;
#else
  return [_server runWithOptions:[self optionsForPort:port] error:error];
#endif
}

- (void)stop
{
  [_server stop];
}

- (BOOL)isRunning
{
  return _server.running;
}

- (NSUInteger)port
{
  return _server.port;
}

// The request target as the client sent it, still escaped, on the host it
// was sent to.
- (NSURL *)URLOf:(GCDWebServerRequest *)request
{
  NSURL *received = request.URL;
  NSString *target = received.relativeString ?: @"/";
  if ([target rangeOfString:@"://"].location != NSNotFound) {
    NSString *query = received.query;
    target = [(received.path.length ? received.path : @"/") stringByAppendingString:query ? [@"?" stringByAppendingString:query] : @""];
  }
  NSString *host = request.headers[@"Host"];
  for (NSString *name in request.headers) {
    if ([name caseInsensitiveCompare:@"Host"] == NSOrderedSame) host = request.headers[name];
  }
  if (!host.length || [host rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#@ "]].location != NSNotFound) {
    host = [NSString stringWithFormat:@"127.0.0.1:%lu", (unsigned long)self.port];
  }
  return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@%@", host, target]];
}

- (void)answer:(GCDWebServerRequest *)request completion:(GCDWebServerCompletionBlock)completion
{
  NSURL *url = [self URLOf:request];
  if (!url) {
    completion([GCDWebServerResponse responseWithStatusCode:400]);
    return;
  }
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSString *name in request.headers) headers[name] = request.headers[name];
  HSRequest *httpRequest;
  if ([request isKindOfClass:[GCDWebServerFileRequest class]]) {
    // The file goes when the listener's request does: kept with ours.
    NSString *path = ((GCDWebServerFileRequest *)request).temporaryPath;
    httpRequest = [[HSRequest alloc] initWithMethod:request.method URL:url headers:headers
                                                 bodyFileURL:request.hasBody ? [NSURL fileURLWithPath:path] : nil owner:request];
  } else {
    NSData *body = request.hasBody ? ((GCDWebServerDataRequest *)request).data : nil;
    httpRequest = [[HSRequest alloc] initWithMethod:request.method URL:url headers:headers body:body];
  }
  httpRequest.remoteAddress = request.remoteAddressString;
  HSListenerAnswer *answer = [[HSListenerAnswer alloc] init];
  answer.completion = completion;
  answer.headOnly = [httpRequest.method isEqualToString:@"HEAD"];
  answer.server = self;
  @synchronized (self) {
    _inFlight++;
  }
  HSReply *reply = [[HSReply alloc] initWithTarget:answer action:@selector(replyDidFinish:)];
  reply.request = httpRequest;
  [self.handler handleRequest:httpRequest reply:reply];
}

@end
