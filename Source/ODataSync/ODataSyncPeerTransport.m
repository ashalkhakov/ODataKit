// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerTransport.h"
#if defined(__APPLE__)
#import <HTTPServerKit/HSMessage.h>

@interface ODataSyncPeerTransport () <NSURLSessionDelegate>
@property (atomic, readwrite, copy, nullable) NSString *peerThumbprint;
@property (atomic, readwrite, strong, nullable) HSPrincipal *peerPrincipal;
// While no certificate is pinned: the one each task's connection presented.
@property (atomic, copy, nullable) NSString *expectedThumbprint;
@end

@implementation ODataSyncPeerTransport {
  NSURLSession *_session;
  NSMutableDictionary<NSNumber *, NSString *> *_presented;  // task identifier -> leaf thumbprint
  NSLock *_checking;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot trust:(ODataSyncPeerTrust *)trust
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _trust = trust;
  _presented = [NSMutableDictionary dictionary];
  _checking = [[NSLock alloc] init];
  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  configuration.URLCache = nil;
  configuration.HTTPCookieStorage = nil;
  _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
  return self;
}

- (void)dealloc
{
  [_session invalidateAndCancel];
}

#pragma mark TLS

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
  NSString *method = challenge.protectionSpace.authenticationMethod;
  if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
    completionHandler(NSURLSessionAuthChallengeUseCredential,
                      [NSURLCredential credentialWithIdentity:_trust.identity.identity certificates:nil persistence:NSURLCredentialPersistenceNone]);
    return;
  }
  if (![method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    return;
  }
  // No authority vouches for a peer: its certificate is the one pinned, or
  // (while checking it) noted for the trust to judge.
  SecTrustRef trust = challenge.protectionSpace.serverTrust;
  CFArrayRef chain = SecTrustCopyCertificateChain(trust);
  SecCertificateRef leaf = chain && CFArrayGetCount(chain) ? (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0) : NULL;
  NSString *thumbprint = [ODataSyncPeerIdentity thumbprintOfCertificate:leaf];
  if (chain) CFRelease(chain);
  NSString *pinned = self.peerThumbprint ?: self.expectedThumbprint;
  if (!thumbprint || (pinned && ![pinned isEqualToString:thumbprint])) {
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    return;
  }
  @synchronized (_presented) {
    _presented[@(task.taskIdentifier)] = thumbprint;
  }
  completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
}

// A request, waited for: the status, the body, the certificate its
// connection presented (when a new one was made for it).
- (NSInteger)send:(NSURLRequest *)request data:(NSData **)data presented:(NSString **)presented error:(NSError **)error
{
  __block NSInteger status = 0;
  __block NSData *body = nil;
  __block NSError *failure = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *response, NSError *e) {
    status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    body = d;
    failure = e;
    dispatch_semaphore_signal(done);
  }];
  [task resume];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  @synchronized (_presented) {
    if (presented) *presented = _presented[@(task.taskIdentifier)];
    [_presented removeObjectForKey:@(task.taskIdentifier)];
  }
  if (data) *data = body;
  if (error) *error = failure;
  return status;
}

#pragma mark Checking the peer

- (BOOL)checkPeer:(NSError **)error
{
  [_checking lock];
  BOOL ok = self.peerThumbprint != nil || [self checkPeerNow:error];
  [_checking unlock];
  return ok;
}

- (BOOL)checkPeerNow:(NSError **)error
{
  // A connection of its own, so that its certificate is the one noted.
  [_session resetWithCompletionHandler:^{}];
  NSURL *url = [NSURL URLWithString:@"$peer" relativeToURL:_serviceRoot].absoluteURL;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSData *data = nil;
  NSString *presented = nil;
  NSError *failure = nil;
  NSInteger status = [self send:request data:&data presented:&presented error:&failure];
  if (!status) {
    if (error) *error = failure ?: HSError(502, @"The peer did not answer");
    return NO;
  }
  if (!presented) {
    if (error) *error = HSError(401, @"The peer's certificate was not seen");
    return NO;
  }
  NSDictionary *json = status == 200 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  NSString *token = [json isKindOfClass:[NSDictionary class]] && [json[@"Token"] isKindOfClass:[NSString class]] ? json[@"Token"] : nil;
  HSPrincipal *principal = [_trust principalForThumbprint:presented token:token error:error];
  if (!principal) return NO;
  self.peerPrincipal = principal;
  self.peerThumbprint = presented;
  return YES;
}

#pragma mark ODataTransport

- (void)startExchange:(ODataExchange *)exchange
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSError *error = nil;
    if (![self checkPeer:&error]) {
      exchange.error = error;
      [exchange finish];
      return;
    }
    NSMutableURLRequest *request = [exchange.request mutableCopy];
    NSString *token = self.trust.token;
    if (token && ![request valueForHTTPHeaderField:@"Authorization"]) {
      [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }
    [[self->_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
      exchange.URLResponse = response;
      exchange.data = data;
      exchange.error = taskError;
      [exchange finish];
    }] resume];
  });
}

#pragma mark Pairing

+ (instancetype)transportPairingWithOffer:(NSDictionary *)offer trust:(ODataSyncPeerTrust *)trust replica:(NSString *)replica
                                     name:(NSString *)name subject:(NSString *)subject scopes:(NSSet *)scopes error:(NSError **)error
{
  NSString *host = offer[@"host"], *peerReplica = offer[@"replica"], *thumbprint = offer[@"thumbprint"], *code = offer[@"code"];
  NSNumber *port = offer[@"port"];
  if (![host isKindOfClass:[NSString class]] || ![port isKindOfClass:[NSNumber class]] || ![peerReplica isKindOfClass:[NSString class]] ||
      ![thumbprint isKindOfClass:[NSString class]] || ![code isKindOfClass:[NSString class]]) {
    if (error) *error = HSError(400, @"That is not a pairing offer");
    return nil;
  }
  NSString *hostPart = [host containsString:@":"] ? [NSString stringWithFormat:@"[%@]", host] : host;
  NSURL *root = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@:%@/sync/%@/", hostPart, port, peerReplica]];
  ODataSyncPeerTransport *transport = root ? [[self alloc] initWithServiceRoot:root trust:trust] : nil;
  if (!transport) {
    if (error) *error = HSError(400, @"The offer's host and port make no URL");
    return nil;
  }
  // Only the certificate the offer names: the device read, not whoever answers.
  transport.expectedThumbprint = thumbprint;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"$pair" relativeToURL:root].absoluteURL];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSMutableDictionary *body = [@{ @"Code": code, @"Replica": replica } mutableCopy];
  if (name) body[@"Name"] = name;
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  NSData *data = nil;
  NSString *presented = nil;
  NSError *failure = nil;
  NSInteger status = [transport send:request data:&data presented:&presented error:&failure];
  NSDictionary *json = status == 200 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (status != 200 || ![json isKindOfClass:[NSDictionary class]] || ![json[@"Thumbprint"] isEqual:thumbprint] ||
      (presented && ![presented isEqualToString:thumbprint])) {
    if (error) *error = failure ?: HSError(status ?: 502, status == 410 ? @"The peer took no pairing with that code (expired, or used)"
                                                                       : @"The pairing did not go through");
    return nil;
  }
  ODataSyncPeerPairing *pairing = [[ODataSyncPeerPairing alloc] initWithReplica:peerReplica thumbprint:thumbprint subject:subject scopes:scopes];
  if (![trust addPairing:pairing error:error]) return nil;
  transport.expectedThumbprint = nil;
  transport.peerThumbprint = thumbprint;
  transport.peerPrincipal = [trust principalForThumbprint:thumbprint token:nil error:NULL];
  return transport;
}

@end
#endif
