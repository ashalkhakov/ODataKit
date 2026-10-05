// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSSignature.h"
#import "HSSignatureSystem.h"

NSSet<NSString *> *HSSignatureAlgorithms(void)
{
  return [NSSet setWithObjects:@"RS256", @"RS384", @"RS512", @"PS256", @"PS384", @"PS512", @"ES256", @"ES384", @"ES512", nil];
}

NSData *HSBase64URLDecode(NSString *text)
{
  NSCharacterSet *alphabet = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"];
  if ([text rangeOfCharacterFromSet:alphabet.invertedSet].location != NSNotFound || text.length % 4 == 1) return nil;
  NSMutableString *standard = [[[text stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                                 stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
  while (standard.length % 4) [standard appendString:@"="];
  return [[NSData alloc] initWithBase64EncodedString:standard options:0];
}

NSString *HSBase64URLEncode(NSData *data)
{
  NSString *base64 = [data base64EncodedStringWithOptions:0];
  base64 = [[base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  return [base64 stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
}

NSError *HSSigningError(NSString *what)
{
  return [NSError errorWithDomain:@"HSSignature" code:1 userInfo:@{ NSLocalizedDescriptionKey: what }];
}

// A number as exactly size bytes, big-endian: padded with zeros, or its
// leading zeros taken off.
NSData *HSFixedWidth(NSData *number, NSUInteger size)
{
  const unsigned char *bytes = number.bytes;
  NSUInteger skip = 0;
  while (number.length - skip > size && bytes[skip] == 0) skip++;
  if (number.length - skip > size) return nil;
  NSMutableData *out = [NSMutableData dataWithLength:size - (number.length - skip)];
  [out appendBytes:bytes + skip length:number.length - skip];
  return out;
}

// A JWK member's bytes: an unsigned big-endian number, or a coordinate.
NSData *HSMember(NSDictionary *jwk, NSString *name)
{
  id value = jwk[name];
  return [value isKindOfClass:[NSString class]] ? HSBase64URLDecode(value) : nil;
}

NSData *HSWithoutLeadingZeros(NSData *number)
{
  const unsigned char *bytes = number.bytes;
  NSUInteger skip = 0;
  while (skip + 1 < number.length && bytes[skip] == 0) skip++;
  return [number subdataWithRange:NSMakeRange(skip, number.length - skip)];
}

static NSUInteger HSBits(NSData *number)
{
  NSData *n = HSWithoutLeadingZeros(number);
  if (!n.length) return 0;
  unsigned char top = ((const unsigned char *)n.bytes)[0];
  NSUInteger bits = (n.length - 1) * 8;
  while (top) {
    bits++;
    top >>= 1;
  }
  return bits;
}


static BOOL HSAlgorithmNamed(NSString *alg, HSAlgorithm *out)
{
  if (![HSSignatureAlgorithms() containsObject:alg]) return NO;
  NSString *family = [alg substringToIndex:2];
  int hash = [[alg substringFromIndex:2] intValue];
  out->family = [family isEqualToString:@"RS"] ? "RS" : [family isEqualToString:@"PS"] ? "PS" : "ES";
  out->hash = hash;
  out->curve = hash == 256 ? "P-256" : hash == 384 ? "P-384" : "P-521";
  out->size = hash == 256 ? 32 : hash == 384 ? 48 : 66;
  return YES;
}


BOOL HSVerifyJWS(NSString *alg, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
{
  HSAlgorithm a;
  if (!HSAlgorithmNamed(alg, &a)) {
    if (reason) *reason = [NSString stringWithFormat:@"%@ is not an algorithm this service takes", alg];
    return NO;
  }
  if (![jwk isKindOfClass:[NSDictionary class]]) {
    if (reason) *reason = @"no key";
    return NO;
  }
  // A key may name the one algorithm it is for (RFC 7517 section 4.4), and
  // what it is for (4.2).
  if (jwk[@"alg"] && ![jwk[@"alg"] isEqual:alg]) {
    if (reason) *reason = [NSString stringWithFormat:@"the key is for %@, not %@", jwk[@"alg"], alg];
    return NO;
  }
  if (jwk[@"use"] && ![jwk[@"use"] isEqual:@"sig"]) {
    if (reason) *reason = @"the key is not for signatures";
    return NO;
  }
  if (a.family[0] == 'E') {
    NSData *x = HSMember(jwk, @"x"), *y = HSMember(jwk, @"y");
    if (![jwk[@"kty"] isEqual:@"EC"] || ![jwk[@"crv"] isEqual:@(a.curve)] || x.length != a.size || y.length != a.size) {
      if (reason) *reason = [NSString stringWithFormat:@"%@ takes an EC key on %s", alg, a.curve];
      return NO;
    }
    if (signature.length != 2 * a.size) {
      if (reason) *reason = @"the signature is not r || s";
      return NO;
    }
  } else {
    NSData *n = HSMember(jwk, @"n"), *e = HSMember(jwk, @"e");
    if (![jwk[@"kty"] isEqual:@"RSA"] || !n.length || !e.length) {
      if (reason) *reason = [NSString stringWithFormat:@"%@ takes an RSA key", alg];
      return NO;
    }
    if (HSBits(n) < 2048) {
      if (reason) *reason = [NSString stringWithFormat:@"the key has %lu bits, fewer than 2048", (unsigned long)HSBits(n)];
      return NO;
    }
  }
  return HSSystemVerify(a, jwk, input, signature, reason);
}

#pragma mark - Signing

// RFC 7638: the SHA-256 of the key's required members, in order.
static NSString *HSKeyThumbprint(NSString *x, NSString *y)
{
  NSString *canonical = [NSString stringWithFormat:@"{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"%@\",\"y\":\"%@\"}", x, y];
  return HSBase64URLEncode(HSSHA256([canonical dataUsingEncoding:NSUTF8StringEncoding]));
}

NSDictionary *HSGenerateSigningKey(NSError **error)
{
  NSData *x = nil, *y = nil, *d = nil;
  if (!HSSystemNewP256(&x, &y, &d, error)) return nil;
  NSString *xs = HSBase64URLEncode(x), *ys = HSBase64URLEncode(y);
  return @{ @"kty": @"EC", @"crv": @"P-256", @"x": xs, @"y": ys, @"d": HSBase64URLEncode(d),
            @"alg": @"ES256", @"use": @"sig", @"kid": HSKeyThumbprint(xs, ys) };
}

NSDictionary *HSPublicKey(NSDictionary *jwk)
{
  NSMutableDictionary *public = [NSMutableDictionary dictionary];
  for (NSString *name in @[ @"kty", @"crv", @"x", @"y", @"alg", @"use", @"kid" ]) {
    if (jwk[name]) public[name] = jwk[name];
  }
  return public;
}

NSString *HSSignJWT(NSDictionary *claims, NSDictionary *jwk, NSError **error)
{
  if (![jwk[@"kty"] isEqual:@"EC"] || ![jwk[@"crv"] isEqual:@"P-256"] || HSMember(jwk, @"x").length != 32 ||
      HSMember(jwk, @"y").length != 32 || HSMember(jwk, @"d").length != 32) {
    if (error) *error = HSSigningError(@"ES256 signs with a P-256 key and its d");
    return nil;
  }
  NSMutableDictionary *header = [@{ @"alg": @"ES256", @"typ": @"JWT" } mutableCopy];
  if (jwk[@"kid"]) header[@"kid"] = jwk[@"kid"];
  NSData *headerJSON = [NSJSONSerialization dataWithJSONObject:header options:0 error:error];
  NSData *claimsJSON = headerJSON ? [NSJSONSerialization dataWithJSONObject:claims options:0 error:error] : nil;
  if (!claimsJSON) return nil;
  NSString *input = [NSString stringWithFormat:@"%@.%@", HSBase64URLEncode(headerJSON), HSBase64URLEncode(claimsJSON)];
  NSData *signature = HSSystemSignES256(jwk, [input dataUsingEncoding:NSUTF8StringEncoding], error);
  return signature ? [NSString stringWithFormat:@"%@.%@", input, HSBase64URLEncode(signature)] : nil;
}
