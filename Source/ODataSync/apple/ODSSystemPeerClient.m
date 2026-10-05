// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The peer client on URLSession: the certificate checked in the server
// trust challenge, against the thumbprint the request is pinned to.

#import "ODSAppleSystem.h"
#import <ODataSync/ODataSyncPeerIdentity.h>

@interface ODSSystemPeerClient ()
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler;
@end

// The session's delegate, holding the client weakly: a session keeps its
// delegate until invalidated, which the client's dealloc does.
@interface ODSSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, weak) ODSSystemPeerClient *client;
@end

@implementation ODSSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
  ODSSystemPeerClient *client = self.client;
  if (client) [client URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
  else completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
@end

@implementation ODSSystemPeerClient {
  ODataSyncPeerIdentity *_identity;
  NSURLSession *_session;
  NSMutableDictionary<NSNumber *, NSString *> *_pinned;     // task identifier -> the thumbprint it takes
  NSMutableDictionary<NSNumber *, NSString *> *_presented;  // task identifier -> the thumbprint it was shown
}

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity
{
  self = [super init];
  if (!self) return nil;
  _identity = identity;
  _pinned = [NSMutableDictionary dictionary];
  _presented = [NSMutableDictionary dictionary];
  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  configuration.URLCache = nil;
  configuration.HTTPCookieStorage = nil;
  ODSSessionDelegate *delegate = [[ODSSessionDelegate alloc] init];
  delegate.client = self;
  _session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
  return self;
}

- (void)dealloc
{
  [_session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
  NSString *method = challenge.protectionSpace.authenticationMethod;
  if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
    completionHandler(NSURLSessionAuthChallengeUseCredential,
                      [NSURLCredential credentialWithIdentity:_identity.system.secIdentity certificates:nil
                                                  persistence:NSURLCredentialPersistenceNone]);
    return;
  }
  if (![method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    return;
  }
  // No authority vouches for a peer: its certificate is the one pinned, or
  // (with none) noted for the trust to judge.
  SecTrustRef trust = challenge.protectionSpace.serverTrust;
  CFArrayRef chain = SecTrustCopyCertificateChain(trust);
  SecCertificateRef leaf = chain && CFArrayGetCount(chain) ? (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0) : NULL;
  NSString *thumbprint = ODSAppleThumbprint(leaf);
  if (chain) CFRelease(chain);
  NSString *pinned = nil;
  @synchronized (_presented) {
    pinned = _pinned[@(task.taskIdentifier)];
  }
  if (!thumbprint || (pinned && ![pinned isEqualToString:thumbprint])) {
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    return;
  }
  @synchronized (_presented) {
    _presented[@(task.taskIdentifier)] = thumbprint;
  }
  completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
}

- (NSHTTPURLResponse *)send:(NSURLRequest *)request pinned:(NSString *)pinned fresh:(BOOL)fresh data:(NSData **)data
                  presented:(NSString **)presented error:(NSError **)error
{
  // A connection of its own, so that its certificate is the one noted.
  if (fresh) {
    dispatch_semaphore_t reset = dispatch_semaphore_create(0);
    [_session resetWithCompletionHandler:^{
      dispatch_semaphore_signal(reset);
    }];
    dispatch_semaphore_wait(reset, DISPATCH_TIME_FOREVER);
  }
  __block NSHTTPURLResponse *answer = nil;
  __block NSData *body = nil;
  __block NSError *failure = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *response, NSError *e) {
    answer = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    body = d;
    failure = e;
    dispatch_semaphore_signal(done);
  }];
  @synchronized (_presented) {
    if (pinned) _pinned[@(task.taskIdentifier)] = pinned;
  }
  [task resume];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  @synchronized (_presented) {
    if (presented) *presented = _presented[@(task.taskIdentifier)];
    [_presented removeObjectForKey:@(task.taskIdentifier)];
    [_pinned removeObjectForKey:@(task.taskIdentifier)];
  }
  if (data) *data = body;
  if (error) *error = answer ? nil : failure;
  return answer;
}

@end
