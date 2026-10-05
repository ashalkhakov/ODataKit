// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerTokens.h"
#import <HTTPServerKit/HSMessage.h>

NSString * const ODataSyncPeerTokenAudience = @"odatasync-peer";
NSString * const ODataSyncPeerReplicaClaim = @"odatasync_replica";
NSString * const ODataSyncPeerThumbprintMember = @"x5t#S256";

// A thumbprint is a SHA-256, base64url: 43 characters of that alphabet.
static BOOL ODSIsThumbprint(NSString *text)
{
  if (![text isKindOfClass:[NSString class]] || text.length != 43) return NO;
  NSCharacterSet *alphabet = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"];
  return [text rangeOfCharacterFromSet:alphabet.invertedSet].location == NSNotFound;
}

@implementation ODataSyncPeerTokenIssuer {
  NSDictionary *_signingKey;
}

- (instancetype)initWithIssuer:(NSString *)issuer signingKey:(NSDictionary *)signingKey
{
  self = [super init];
  if (!self) return nil;
  _issuer = [issuer copy];
  _signingKey = [signingKey copy];
  _keySet = @{ @"keys": @[ HSPublicKey(signingKey) ] };
  _lifetime = 24 * 3600;
  return self;
}

- (NSString *)tokenForPrincipal:(HSPrincipal *)principal replica:(NSString *)replica thumbprint:(NSString *)thumbprint error:(NSError **)error
{
  return [self claimsAndTokenForPrincipal:principal replica:replica thumbprint:thumbprint expires:NULL error:error];
}

- (NSString *)claimsAndTokenForPrincipal:(HSPrincipal *)principal replica:(NSString *)replica thumbprint:(NSString *)thumbprint
                                 expires:(NSTimeInterval *)expires error:(NSError **)error
{
  if (!principal) {
    if (error) *error = HSError(401, @"A peer token is for a device signed in");
    return nil;
  }
  if (!ODSIsThumbprint(thumbprint) || ![replica isKindOfClass:[NSString class]] || !replica.length) {
    if (error) *error = HSError(400, @"PeerToken takes the replica and its certificate's thumbprint (x5t#S256)");
    return nil;
  }
  NSSet *scopes = self.scopesForPrincipal ? self.scopesForPrincipal(principal) : principal.scopes;
  NSTimeInterval now = floor([[NSDate date] timeIntervalSince1970]);
  NSMutableDictionary *claims = [@{ @"iss": _issuer, @"sub": principal.subject, @"aud": ODataSyncPeerTokenAudience,
                                    @"iat": @(now), @"exp": @(now + _lifetime), @"jti": [NSUUID UUID].UUIDString,
                                    ODataSyncPeerReplicaClaim: replica,
                                    @"cnf": @{ ODataSyncPeerThumbprintMember: thumbprint } } mutableCopy];
  if (scopes.count) claims[@"scope"] = [[scopes.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "];
  if (expires) *expires = now + _lifetime;
  return HSSignJWT(claims, _signingKey, error);
}

- (NSDictionary *)answerForPrincipal:(HSPrincipal *)principal replica:(NSString *)replica thumbprint:(NSString *)thumbprint error:(NSError **)error
{
  NSTimeInterval expires = 0;
  NSString *token = [self claimsAndTokenForPrincipal:principal replica:replica thumbprint:thumbprint expires:&expires error:error];
  return token ? @{ @"Token": token, @"Keys": _keySet, @"Issuer": _issuer, @"Expires": @(expires) } : nil;
}

@end
