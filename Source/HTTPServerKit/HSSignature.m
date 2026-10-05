// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSSignature.h"

#if defined(__APPLE__)
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#else
#include <gnutls/gnutls.h>
#include <gnutls/abstract.h>
#include <gnutls/crypto.h>
#endif

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

static NSError *HSSigningError(NSString *what)
{
  return [NSError errorWithDomain:@"HSSignature" code:1 userInfo:@{ NSLocalizedDescriptionKey: what }];
}

// A number as exactly size bytes, big-endian: padded with zeros, or its
// leading zeros taken off.
static NSData *HSFixedWidth(NSData *number, NSUInteger size)
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
static NSData *HSMember(NSDictionary *jwk, NSString *name)
{
  id value = jwk[name];
  return [value isKindOfClass:[NSString class]] ? HSBase64URLDecode(value) : nil;
}

static NSData *HSWithoutLeadingZeros(NSData *number)
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

typedef struct {
  const char *family;  // RS, PS, ES
  int hash;            // 256, 384, 512
  const char *curve;   // ES only
  NSUInteger size;     // an ES coordinate's bytes
} HSAlgorithm;

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

#if defined(__APPLE__)

static NSData *HSDERLength(NSUInteger length)
{
  if (length < 0x80) return [NSData dataWithBytes:(unsigned char[]){ (unsigned char)length } length:1];
  unsigned char bytes[5];
  NSUInteger count = 0;
  for (NSUInteger n = length; n; n >>= 8) count++;
  bytes[0] = (unsigned char)(0x80 | count);
  for (NSUInteger i = 0; i < count; i++) bytes[count - i] = (unsigned char)(length >> (8 * i));
  return [NSData dataWithBytes:bytes length:count + 1];
}

static NSData *HSDERInteger(NSData *number)
{
  NSMutableData *value = [NSMutableData data];
  NSData *n = HSWithoutLeadingZeros(number);
  if (n.length && (((const unsigned char *)n.bytes)[0] & 0x80)) [value appendBytes:"\0" length:1];
  [value appendData:n];
  NSMutableData *der = [NSMutableData dataWithBytes:"\x02" length:1];
  [der appendData:HSDERLength(value.length)];
  [der appendData:value];
  return der;
}

static SecKeyRef HSCreateKey(NSData *data, CFStringRef type, NSString **reason)
{
  CFErrorRef error = NULL;
  NSDictionary *attributes = @{ (__bridge id)kSecAttrKeyType: (__bridge id)type,
                                (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic };
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)attributes, &error);
  if (!key) {
    if (reason) *reason = [NSString stringWithFormat:@"the key does not load: %@", CFBridgingRelease(error)];
    else if (error) CFRelease(error);
  }
  return key;
}

static BOOL HSVerify(HSAlgorithm a, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
{
  SecKeyRef key = NULL;
  SecKeyAlgorithm algorithm;
  if (a.family[0] == 'E') {
    NSMutableData *point = [NSMutableData dataWithBytes:"\x04" length:1];
    [point appendData:HSMember(jwk, @"x")];
    [point appendData:HSMember(jwk, @"y")];
    key = HSCreateKey(point, kSecAttrKeyTypeECSECPrimeRandom, reason);
    algorithm = a.hash == 256 ? kSecKeyAlgorithmECDSASignatureMessageX962SHA256
              : a.hash == 384 ? kSecKeyAlgorithmECDSASignatureMessageX962SHA384
                              : kSecKeyAlgorithmECDSASignatureMessageX962SHA512;
    // JWS has r || s; X9.62 is SEQUENCE { r, s } (RFC 4754's raw form
    // needs macOS 14).
    NSMutableData *body = [NSMutableData dataWithData:HSDERInteger([signature subdataWithRange:NSMakeRange(0, a.size)])];
    [body appendData:HSDERInteger([signature subdataWithRange:NSMakeRange(a.size, a.size)])];
    NSMutableData *der = [NSMutableData dataWithBytes:"\x30" length:1];
    [der appendData:HSDERLength(body.length)];
    [der appendData:body];
    signature = der;
  } else {
    // PKCS #1 RSAPublicKey: SEQUENCE { modulus, publicExponent }.
    NSMutableData *body = [NSMutableData dataWithData:HSDERInteger(HSMember(jwk, @"n"))];
    [body appendData:HSDERInteger(HSMember(jwk, @"e"))];
    NSMutableData *der = [NSMutableData dataWithBytes:"\x30" length:1];
    [der appendData:HSDERLength(body.length)];
    [der appendData:body];
    key = HSCreateKey(der, kSecAttrKeyTypeRSA, reason);
    if (a.family[0] == 'R') {
      algorithm = a.hash == 256 ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
                : a.hash == 384 ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384
                                : kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512;
    } else {
      algorithm = a.hash == 256 ? kSecKeyAlgorithmRSASignatureMessagePSSSHA256
                : a.hash == 384 ? kSecKeyAlgorithmRSASignatureMessagePSSSHA384
                                : kSecKeyAlgorithmRSASignatureMessagePSSSHA512;
    }
  }
  if (!key) return NO;
  CFErrorRef error = NULL;
  BOOL ok = SecKeyVerifySignature(key, algorithm, (__bridge CFDataRef)input, (__bridge CFDataRef)signature, &error);
  CFRelease(key);
  if (error) CFRelease(error);
  if (!ok && reason) *reason = @"the signature does not verify";
  return ok;
}

// X9.62's SEQUENCE { r, s } as JWS's r || s.
static NSData *HSRawSignature(NSData *der, NSUInteger size)
{
  const unsigned char *b = der.bytes;
  NSUInteger at = 0, n = der.length;
  NSData *parts[2];
  if (n < 2 || b[at++] != 0x30) return nil;
  NSUInteger length = b[at++];
  if (length & 0x80) at += length & 0x7f;  // a long form length: skipped, the INTEGERs say theirs
  for (int i = 0; i < 2; i++) {
    if (at + 2 > n || b[at++] != 0x02) return nil;
    NSUInteger l = b[at++];
    if (at + l > n) return nil;
    parts[i] = HSFixedWidth([der subdataWithRange:NSMakeRange(at, l)], size);
    if (!parts[i]) return nil;
    at += l;
  }
  NSMutableData *raw = [NSMutableData dataWithData:parts[0]];
  [raw appendData:parts[1]];
  return raw;
}

static NSData *HSSignES256(NSDictionary *jwk, NSData *input, NSError **error)
{
  NSData *x = HSMember(jwk, @"x"), *y = HSMember(jwk, @"y"), *d = HSMember(jwk, @"d");
  NSMutableData *external = [NSMutableData dataWithBytes:"\x04" length:1];
  [external appendData:x];
  [external appendData:y];
  [external appendData:d];
  NSDictionary *attributes = @{ (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                                (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate };
  CFErrorRef cfError = NULL;
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)external, (__bridge CFDictionaryRef)attributes, &cfError);
  if (!key) {
    if (cfError) CFRelease(cfError);
    if (error) *error = HSSigningError(@"the signing key does not load");
    return nil;
  }
  NSData *der = (__bridge_transfer NSData *)SecKeyCreateSignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                                                  (__bridge CFDataRef)input, &cfError);
  CFRelease(key);
  if (!der) {
    if (cfError) CFRelease(cfError);
    if (error) *error = HSSigningError(@"the signing failed");
    return nil;
  }
  NSData *raw = HSRawSignature(der, 32);
  if (!raw && error) *error = HSSigningError(@"the signature is not one");
  return raw;
}

// x, y and d of a new P-256 key.
static BOOL HSNewP256(NSData **x, NSData **y, NSData **d, NSError **error)
{
  NSDictionary *parameters = @{ (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                                (__bridge id)kSecAttrKeySizeInBits: @256 };
  CFErrorRef cfError = NULL;
  SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)parameters, &cfError);
  NSData *external = key ? (__bridge_transfer NSData *)SecKeyCopyExternalRepresentation(key, &cfError) : nil;
  if (key) CFRelease(key);
  if (external.length != 97) {
    if (cfError) CFRelease(cfError);
    if (error) *error = HSSigningError(@"no key could be made");
    return NO;
  }
  *x = [external subdataWithRange:NSMakeRange(1, 32)];
  *y = [external subdataWithRange:NSMakeRange(33, 32)];
  *d = [external subdataWithRange:NSMakeRange(65, 32)];
  return YES;
}

NSData *HSSHA256(NSData *data)
{
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof digest];
}

#else

static gnutls_datum_t HSDatum(NSData *data)
{
  return (gnutls_datum_t){ (unsigned char *)data.bytes, (unsigned int)data.length };
}

static BOOL HSVerify(HSAlgorithm a, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
{
  gnutls_pubkey_t key;
  if (gnutls_pubkey_init(&key) < 0) {
    if (reason) *reason = @"no key";
    return NO;
  }
  int loaded;
  gnutls_sign_algorithm_t algorithm;
  NSData *checked = signature;
  gnutls_datum_t der = { NULL, 0 };
  if (a.family[0] == 'E') {
    gnutls_ecc_curve_t curve = a.hash == 256 ? GNUTLS_ECC_CURVE_SECP256R1 : a.hash == 384 ? GNUTLS_ECC_CURVE_SECP384R1 : GNUTLS_ECC_CURVE_SECP521R1;
    NSData *x = HSMember(jwk, @"x"), *y = HSMember(jwk, @"y");
    gnutls_datum_t xd = HSDatum(x), yd = HSDatum(y);
    loaded = gnutls_pubkey_import_ecc_raw(key, curve, &xd, &yd);
    algorithm = a.hash == 256 ? GNUTLS_SIGN_ECDSA_SHA256 : a.hash == 384 ? GNUTLS_SIGN_ECDSA_SHA384 : GNUTLS_SIGN_ECDSA_SHA512;
    // JWS has r || s; GnuTLS takes the DER of X9.62.
    NSData *r = [signature subdataWithRange:NSMakeRange(0, a.size)];
    NSData *s = [signature subdataWithRange:NSMakeRange(a.size, a.size)];
    gnutls_datum_t rd = HSDatum(r), sd = HSDatum(s);
    if (loaded >= 0 && gnutls_encode_rs_value(&der, &rd, &sd) >= 0) {
      checked = [NSData dataWithBytes:der.data length:der.size];
    } else {
      loaded = -1;
    }
  } else {
    NSData *n = HSMember(jwk, @"n"), *e = HSMember(jwk, @"e");
    gnutls_datum_t nd = HSDatum(n), ed = HSDatum(e);
    loaded = gnutls_pubkey_import_rsa_raw(key, &nd, &ed);
    if (a.family[0] == 'R') {
      algorithm = a.hash == 256 ? GNUTLS_SIGN_RSA_SHA256 : a.hash == 384 ? GNUTLS_SIGN_RSA_SHA384 : GNUTLS_SIGN_RSA_SHA512;
    } else {
      algorithm = a.hash == 256 ? GNUTLS_SIGN_RSA_PSS_RSAE_SHA256 : a.hash == 384 ? GNUTLS_SIGN_RSA_PSS_RSAE_SHA384 : GNUTLS_SIGN_RSA_PSS_RSAE_SHA512;
    }
  }
  if (der.data) gnutls_free(der.data);
  if (loaded < 0) {
    gnutls_pubkey_deinit(key);
    if (reason) *reason = @"the key does not load";
    return NO;
  }
  gnutls_datum_t data = HSDatum(input), sig = HSDatum(checked);
  int verified = gnutls_pubkey_verify_data2(key, algorithm, 0, &data, &sig);
  gnutls_pubkey_deinit(key);
  if (verified < 0 && reason) *reason = @"the signature does not verify";
  return verified >= 0;
}

static NSData *HSSignES256(NSDictionary *jwk, NSData *input, NSError **error)
{
  gnutls_privkey_t key;
  if (gnutls_privkey_init(&key) < 0) {
    if (error) *error = HSSigningError(@"no key");
    return nil;
  }
  NSData *x = HSMember(jwk, @"x"), *y = HSMember(jwk, @"y"), *d = HSMember(jwk, @"d");
  gnutls_datum_t xd = HSDatum(x), yd = HSDatum(y), kd = HSDatum(d);
  if (gnutls_privkey_import_ecc_raw(key, GNUTLS_ECC_CURVE_SECP256R1, &xd, &yd, &kd) < 0) {
    gnutls_privkey_deinit(key);
    if (error) *error = HSSigningError(@"the signing key does not load");
    return nil;
  }
  gnutls_datum_t data = HSDatum(input), der = { NULL, 0 }, r = { NULL, 0 }, s = { NULL, 0 };
  int signedOK = gnutls_privkey_sign_data(key, GNUTLS_DIG_SHA256, 0, &data, &der);
  gnutls_privkey_deinit(key);
  NSData *raw = nil;
  if (signedOK >= 0 && gnutls_decode_rs_value(&der, &r, &s) >= 0) {
    NSData *rr = HSFixedWidth([NSData dataWithBytes:r.data length:r.size], 32);
    NSData *ss = HSFixedWidth([NSData dataWithBytes:s.data length:s.size], 32);
    if (rr && ss) {
      NSMutableData *both = [NSMutableData dataWithData:rr];
      [both appendData:ss];
      raw = both;
    }
  }
  if (der.data) gnutls_free(der.data);
  if (r.data) gnutls_free(r.data);
  if (s.data) gnutls_free(s.data);
  if (!raw && error) *error = HSSigningError(@"the signing failed");
  return raw;
}

static BOOL HSNewP256(NSData **x, NSData **y, NSData **d, NSError **error)
{
  gnutls_privkey_t key;
  if (gnutls_privkey_init(&key) < 0 ||
      gnutls_privkey_generate(key, GNUTLS_PK_ECDSA, GNUTLS_CURVE_TO_BITS(GNUTLS_ECC_CURVE_SECP256R1), 0) < 0) {
    if (error) *error = HSSigningError(@"no key could be made");
    return NO;
  }
  gnutls_ecc_curve_t curve;
  gnutls_datum_t xd = { NULL, 0 }, yd = { NULL, 0 }, kd = { NULL, 0 };
  int exported = gnutls_privkey_export_ecc_raw(key, &curve, &xd, &yd, &kd);
  gnutls_privkey_deinit(key);
  if (exported < 0) {
    if (error) *error = HSSigningError(@"the key could not be read");
    return NO;
  }
  *x = HSFixedWidth([NSData dataWithBytes:xd.data length:xd.size], 32);
  *y = HSFixedWidth([NSData dataWithBytes:yd.data length:yd.size], 32);
  *d = HSFixedWidth([NSData dataWithBytes:kd.data length:kd.size], 32);
  gnutls_free(xd.data);
  gnutls_free(yd.data);
  gnutls_free(kd.data);
  return *x && *y && *d;
}

NSData *HSSHA256(NSData *data)
{
  unsigned char digest[32];
  gnutls_hash_fast(GNUTLS_DIG_SHA256, data.bytes, data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof digest];
}

#endif

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
  return HSVerify(a, jwk, input, signature, reason);
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
  if (!HSNewP256(&x, &y, &d, error)) return nil;
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
  NSData *signature = HSSignES256(jwk, [input dataUsingEncoding:NSUTF8StringEncoding], error);
  return signature ? [NSString stringWithFormat:@"%@.%@", input, HSBase64URLEncode(signature)] : nil;
}
