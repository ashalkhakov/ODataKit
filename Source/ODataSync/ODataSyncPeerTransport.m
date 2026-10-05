// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerTransport.h"
#import "ODSSystem.h"
#import <HTTPServerKit/HSMessage.h>

@interface ODataSyncPeerTransport ()
@property (atomic, readwrite, copy, nullable) NSString *peerThumbprint;
@property (atomic, readwrite, strong, nullable) HSPrincipal *peerPrincipal;
// The token the peer showed (nil: paired), checked again before each
// exchange.
@property (atomic, copy, nullable) NSString *peerToken;
@end

@implementation ODataSyncPeerTransport {
  NSLock *_checking;
  ODSSystemPeerClient *_client;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot trust:(ODataSyncPeerTrust *)trust
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _trust = trust;
  _checking = [[NSLock alloc] init];
  _client = [[ODSSystemPeerClient alloc] initWithIdentity:trust.identity];
  return self;
}

// Over HTTPS, to the certificate pinned (the peer's, once checked; while
// pairing, the offer's), or to any, noted.
- (NSHTTPURLResponse *)send:(NSURLRequest *)request fresh:(BOOL)fresh data:(NSData **)data presented:(NSString **)presented
                      error:(NSError **)error
{
  return [_client send:request pinned:self.peerThumbprint ?: self.expectedThumbprint fresh:fresh data:data presented:presented error:error];
}

#pragma mark Checking the peer

- (BOOL)checkPeer:(NSError **)error
{
  [_checking lock];
  BOOL ok = self.peerThumbprint ? [self checkPeerAgain:error] : [self checkPeerNow:error];
  [_checking unlock];
  return ok;
}

// The peer known still trusted: its pairing not forgotten, its token not
// expired. Not: checked anew, from its certificate, next time.
- (BOOL)checkPeerAgain:(NSError **)error
{
  if ([_trust principalForThumbprint:self.peerThumbprint token:self.peerToken error:error]) return YES;
  self.peerThumbprint = nil;
  self.peerPrincipal = nil;
  self.peerToken = nil;
  return NO;
}

- (BOOL)checkPeerNow:(NSError **)error
{
  NSURL *url = [NSURL URLWithString:@"$peer" relativeToURL:_serviceRoot].absoluteURL;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSData *data = nil;
  NSString *presented = nil;
  NSError *failure = nil;
  NSHTTPURLResponse *response = [self send:request fresh:YES data:&data presented:&presented error:&failure];
  if (!response) {
    if (error) *error = failure ?: HSError(502, @"The peer did not answer");
    return NO;
  }
  if (!presented) {
    if (error) *error = HSError(401, @"The peer's certificate was not seen");
    return NO;
  }
  NSDictionary *json = response.statusCode == 200 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  NSString *token = [json isKindOfClass:[NSDictionary class]] && [json[@"Token"] isKindOfClass:[NSString class]] ? json[@"Token"] : nil;
  HSPrincipal *principal = [_trust principalForThumbprint:presented token:token error:error];
  if (!principal) return NO;
  // The device at this root (it ends in its replica), not another one the
  // trust would take as well.
  NSString *replica = principal.claims[ODataSyncPeerReplicaClaim];
  if (![replica isEqual:_serviceRoot.lastPathComponent]) {
    if (error) *error = HSError(401, [NSString stringWithFormat:@"The device answering is replica %@, not %@", replica, _serviceRoot.lastPathComponent]);
    return NO;
  }
  self.peerPrincipal = principal;
  self.peerToken = token;
  self.peerThumbprint = presented;
  return YES;
}

#pragma mark ODataTransport

- (void)startExchange:(ODataExchange *)exchange
{
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
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
    NSData *data = nil;
    NSHTTPURLResponse *response = [self send:request fresh:NO data:&data presented:NULL error:&error];
    exchange.URLResponse = response;
    exchange.data = data;
    exchange.error = response ? nil : error;
    [exchange finish];
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
  // Only the certificate the offer names: the device read, not whoever
  // answers. Seen first with nothing sent that matters ($peer), then the
  // code sent to it alone.
  transport.expectedThumbprint = thumbprint;
  NSMutableURLRequest *probe = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"$peer" relativeToURL:root].absoluteURL];
  NSString *presented = nil;
  NSError *failure = nil;
  if (![transport send:probe fresh:YES data:NULL presented:&presented error:&failure] || ![presented isEqualToString:thumbprint]) {
    if (error) *error = failure ?: HSError(401, @"The device at the offer's address is not the one that made it");
    return nil;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"$pair" relativeToURL:root].absoluteURL];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSMutableDictionary *body = [@{ @"Code": code, @"Replica": replica } mutableCopy];
  if (name) body[@"Name"] = name;
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
  NSData *data = nil;
  presented = nil;
  failure = nil;
  NSHTTPURLResponse *response = [transport send:request fresh:NO data:&data presented:&presented error:&failure];
  NSInteger status = response.statusCode;
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
