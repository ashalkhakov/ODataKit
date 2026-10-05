// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// JWS signatures by the Security framework (and CommonCrypto's SHA-256).

#import "../HSSignature.h"
#import "../HSSignatureSystem.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>


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

BOOL HSSystemVerify(HSAlgorithm a, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
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

NSData *HSSystemSignES256(NSDictionary *jwk, NSData *input, NSError **error)
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
BOOL HSSystemNewP256(NSData **x, NSData **y, NSData **d, NSError **error)
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

