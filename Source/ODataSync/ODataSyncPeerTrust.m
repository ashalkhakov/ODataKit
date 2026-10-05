// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerTrust.h"
#if defined(__APPLE__)
#import <HTTPServerKit/HSMessage.h>

@implementation ODataSyncPeerPairing

- (instancetype)initWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint subject:(NSString *)subject scopes:(NSSet *)scopes
{
  self = [super init];
  if (!self) return nil;
  _replica = [replica copy];
  _thumbprint = [thumbprint copy];
  _subject = [subject copy];
  _scopes = [scopes copy] ?: [NSSet set];
  _date = [NSDate date];
  return self;
}

- (NSDictionary *)record
{
  NSMutableDictionary *record = [@{ @"replica": _replica, @"thumbprint": _thumbprint, @"subject": _subject,
                                    @"scopes": [_scopes.allObjects sortedArrayUsingSelector:@selector(compare:)],
                                    @"date": @(_date.timeIntervalSince1970) } mutableCopy];
  if (_name) record[@"name"] = _name;
  return record;
}

+ (instancetype)pairingOfRecord:(NSDictionary *)record
{
  if (![record isKindOfClass:[NSDictionary class]]) return nil;
  NSString *replica = record[@"replica"], *thumbprint = record[@"thumbprint"], *subject = record[@"subject"];
  if (![replica isKindOfClass:[NSString class]] || ![thumbprint isKindOfClass:[NSString class]] || ![subject isKindOfClass:[NSString class]]) return nil;
  NSArray *scopes = [record[@"scopes"] isKindOfClass:[NSArray class]] ? record[@"scopes"] : @[];
  ODataSyncPeerPairing *pairing = [[self alloc] initWithReplica:replica thumbprint:thumbprint subject:subject scopes:[NSSet setWithArray:scopes]];
  if ([record[@"date"] isKindOfClass:[NSNumber class]]) pairing->_date = [NSDate dateWithTimeIntervalSince1970:[record[@"date"] doubleValue]];
  if ([record[@"name"] isKindOfClass:[NSString class]]) pairing.name = record[@"name"];
  return pairing;
}

@end

// A token's answer, heard (HSJWTAuthenticator with its keys given answers
// at once).
@interface ODSHeard : NSObject
@property (nonatomic, strong, nullable) HSAuthenticationReply *reply;
@end

@implementation ODSHeard
- (void)heard:(HSAuthenticationReply *)reply
{
  self.reply = reply;
}
@end

@implementation ODataSyncPeerTrust {
  NSURL *_pairingsURL;
  NSMutableArray<ODataSyncPeerPairing *> *_pairings;
}

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity pairingsURL:(NSURL *)pairingsURL
{
  self = [super init];
  if (!self) return nil;
  _identity = identity;
  _pairingsURL = [pairingsURL copy];
  _pairings = [NSMutableArray array];
  NSData *data = pairingsURL ? [NSData dataWithContentsOfURL:pairingsURL] : nil;
  NSArray *records = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if ([records isKindOfClass:[NSArray class]]) {
    for (NSDictionary *record in records) {
      ODataSyncPeerPairing *pairing = [ODataSyncPeerPairing pairingOfRecord:record];
      if (pairing) [_pairings addObject:pairing];
    }
  }
  return self;
}

#pragma mark The service's

- (BOOL)takePeerTokenAnswer:(NSDictionary *)answer error:(NSError **)error
{
  NSString *token = answer[@"Token"], *issuer = answer[@"Issuer"];
  NSDictionary *keys = answer[@"Keys"];
  if (![token isKindOfClass:[NSString class]] || ![issuer isKindOfClass:[NSString class]] || ![keys isKindOfClass:[NSDictionary class]] ||
      ![keys[@"keys"] isKindOfClass:[NSArray class]]) {
    if (error) *error = HSError(502, @"The service's peer token answer is not one");
    return NO;
  }
  self.token = token;
  self.issuer = issuer;
  self.keySet = keys;
  self.tokenExpires = [answer[@"Expires"] isKindOfClass:[NSNumber class]] ? [NSDate dateWithTimeIntervalSince1970:[answer[@"Expires"] doubleValue]] : nil;
  return YES;
}

#pragma mark Pairings

- (NSArray *)pairings
{
  @synchronized (_pairings) {
    return [_pairings copy];
  }
}

- (ODataSyncPeerPairing *)pairingWithThumbprint:(NSString *)thumbprint
{
  @synchronized (_pairings) {
    for (ODataSyncPeerPairing *pairing in _pairings) {
      if ([pairing.thumbprint isEqualToString:thumbprint]) return pairing;
    }
  }
  return nil;
}

- (BOOL)save:(NSError **)error
{
  if (!_pairingsURL) return YES;
  NSMutableArray *records = [NSMutableArray array];
  for (ODataSyncPeerPairing *pairing in _pairings) [records addObject:[pairing record]];
  NSData *data = [NSJSONSerialization dataWithJSONObject:records options:NSJSONWritingPrettyPrinted error:error];
  if (!data) return NO;
  NSDataWritingOptions options = NSDataWritingAtomic;
#if TARGET_OS_IPHONE
  options |= NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
#endif
  return [data writeToURL:_pairingsURL options:options error:error];
}

- (BOOL)addPairing:(ODataSyncPeerPairing *)pairing error:(NSError **)error
{
  @synchronized (_pairings) {
    NSUInteger at = [_pairings indexOfObjectPassingTest:^BOOL(ODataSyncPeerPairing *kept, NSUInteger i, BOOL *stop) {
      return [kept.thumbprint isEqualToString:pairing.thumbprint];
    }];
    if (at == NSNotFound) [_pairings addObject:pairing];
    else _pairings[at] = pairing;
    return [self save:error];
  }
}

- (BOOL)forgetPairingWithThumbprint:(NSString *)thumbprint error:(NSError **)error
{
  @synchronized (_pairings) {
    [_pairings filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ODataSyncPeerPairing *kept, NSDictionary *bindings) {
      return ![kept.thumbprint isEqualToString:thumbprint];
    }]];
    return [self save:error];
  }
}

#pragma mark Checking a peer

- (HSPrincipal *)principalForThumbprint:(NSString *)thumbprint token:(NSString *)token error:(NSError **)error
{
  if (!thumbprint.length) {
    if (error) *error = HSError(401, @"A peer presents its certificate");
    return nil;
  }
  // Paired: the pairing says whose it is.
  ODataSyncPeerPairing *pairing = [self pairingWithThumbprint:thumbprint];
  if (pairing) {
    NSMutableDictionary *claims = [@{ ODataSyncPeerReplicaClaim: pairing.replica, @"odatasync_paired": @YES } mutableCopy];
    if (pairing.scopes.count) {
      claims[@"scope"] = [[pairing.scopes.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "];
    }
    return [[HSPrincipal alloc] initWithSubject:pairing.subject claims:claims];
  }
  // A token the service issued, bound to this certificate.
  if (!token.length) {
    if (error) *error = HSError(401, @"Neither paired nor with a peer token");
    return nil;
  }
  NSString *issuer = self.issuer;
  NSDictionary *keys = self.keySet;
  if (!issuer || !keys) {
    if (error) *error = HSError(401, @"This device has no service keys to check a peer token with");
    return nil;
  }
  HSJWTAuthenticator *checker = [[HSJWTAuthenticator alloc] initWithIssuer:issuer audience:ODataSyncPeerTokenAudience];
  checker.keySet = keys;
  checker.algorithms = [NSSet setWithObject:@"ES256"];
  HSRequest *request = [[HSRequest alloc] initWithMethod:@"GET" URL:[NSURL URLWithString:@"https://peer.invalid/"]
                                                 headers:@{ @"Authorization": [@"Bearer " stringByAppendingString:token] } body:nil];
  ODSHeard *heard = [[ODSHeard alloc] init];
  HSAuthenticationReply *reply = [[HSAuthenticationReply alloc] initWithTarget:heard action:@selector(heard:)];
  [checker authenticateRequest:request reply:reply];
  HSPrincipal *principal = reply.finished ? reply.principal : nil;
  if (!principal) {
    if (error) *error = reply.error ?: HSError(401, @"The peer token is not one");
    return nil;
  }
  NSDictionary *confirmation = principal.claims[@"cnf"];
  NSString *bound = [confirmation isKindOfClass:[NSDictionary class]] ? confirmation[ODataSyncPeerThumbprintMember] : nil;
  if (![bound isKindOfClass:[NSString class]] || ![bound isEqualToString:thumbprint]) {
    if (error) *error = HSError(401, @"The peer token is bound to another certificate");
    return nil;
  }
  if (![principal.claims[ODataSyncPeerReplicaClaim] isKindOfClass:[NSString class]]) {
    if (error) *error = HSError(401, @"The peer token names no replica");
    return nil;
  }
  return principal;
}

@end
#endif
