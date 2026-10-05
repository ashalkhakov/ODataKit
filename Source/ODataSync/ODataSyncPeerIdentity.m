// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerIdentity.h"
#if defined(__APPLE__)
#import <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>

#pragma mark - DER, as much of it as a certificate needs

static NSData *ODSDERLength(NSUInteger length)
{
  NSMutableData *out = [NSMutableData data];
  if (length < 0x80) {
    uint8_t byte = (uint8_t)length;
    [out appendBytes:&byte length:1];
    return out;
  }
  uint8_t bytes[sizeof(NSUInteger)];
  NSUInteger count = 0;
  for (NSUInteger rest = length; rest; rest >>= 8) bytes[count++] = (uint8_t)(rest & 0xff);
  uint8_t first = (uint8_t)(0x80 | count);
  [out appendBytes:&first length:1];
  for (NSUInteger i = count; i > 0; i--) [out appendBytes:&bytes[i - 1] length:1];
  return out;
}

static NSData *ODSDER(uint8_t tag, NSData *content)
{
  NSMutableData *out = [NSMutableData dataWithBytes:&tag length:1];
  [out appendData:ODSDERLength(content.length)];
  [out appendData:content];
  return out;
}

static NSData *ODSDERSequence(NSArray<NSData *> *items)
{
  NSMutableData *content = [NSMutableData data];
  for (NSData *item in items) [content appendData:item];
  return ODSDER(0x30, content);
}

static NSData *ODSDERSet(NSArray<NSData *> *items)
{
  NSMutableData *content = [NSMutableData data];
  for (NSData *item in items) [content appendData:item];
  return ODSDER(0x31, content);
}

// An OID from its arcs.
static NSData *ODSDEROID(NSArray<NSNumber *> *arcs)
{
  NSMutableData *content = [NSMutableData data];
  uint8_t first = (uint8_t)(arcs[0].unsignedIntValue * 40 + arcs[1].unsignedIntValue);
  [content appendBytes:&first length:1];
  for (NSUInteger i = 2; i < arcs.count; i++) {
    unsigned long arc = arcs[i].unsignedLongValue;
    uint8_t bytes[10];
    NSUInteger count = 0;
    do {
      bytes[count++] = (uint8_t)(arc & 0x7f);
      arc >>= 7;
    } while (arc);
    for (NSUInteger j = count; j > 0; j--) {
      uint8_t byte = bytes[j - 1] | (j > 1 ? 0x80 : 0);
      [content appendBytes:&byte length:1];
    }
  }
  return ODSDER(0x06, content);
}

// A positive INTEGER from big-endian bytes.
static NSData *ODSDERUnsigned(NSData *bytes)
{
  NSMutableData *content = [NSMutableData data];
  const uint8_t *b = bytes.bytes;
  NSUInteger start = 0;
  while (start + 1 < bytes.length && b[start] == 0) start++;
  if (b[start] & 0x80) {
    uint8_t zero = 0;
    [content appendBytes:&zero length:1];
  }
  [content appendBytes:b + start length:bytes.length - start];
  return ODSDER(0x02, content);
}

static NSData *ODSDERTime(NSDate *date)
{
  // UTCTime to 2049, GeneralizedTime after (RFC 5280 4.1.2.5).
  NSDateFormatter *format = [[NSDateFormatter alloc] init];
  format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  format.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  format.dateFormat = @"yyyy";
  BOOL utc = [format stringFromDate:date].integerValue < 2050;
  format.dateFormat = utc ? @"yyMMddHHmmss'Z'" : @"yyyyMMddHHmmss'Z'";
  return ODSDER(utc ? 0x17 : 0x18, [[format stringFromDate:date] dataUsingEncoding:NSASCIIStringEncoding]);
}

// CN=name.
static NSData *ODSDERName(NSString *name)
{
  NSData *attribute = ODSDERSequence(@[ ODSDEROID(@[ @2, @5, @4, @3 ]), ODSDER(0x0c, [name dataUsingEncoding:NSUTF8StringEncoding]) ]);
  return ODSDERSequence(@[ ODSDERSet(@[ attribute ]) ]);
}

// ecdsa-with-SHA256 (no parameters).
static NSData *ODSDERECDSAWithSHA256(void)
{
  return ODSDERSequence(@[ ODSDEROID(@[ @1, @2, @840, @10045, @4, @3, @2 ]) ]);
}

static NSData *ODSDERBitString(NSData *bits)
{
  NSMutableData *content = [NSMutableData dataWithLength:1];  // no unused bits
  [content appendData:bits];
  return ODSDER(0x03, content);
}

#pragma mark - The identity

static NSError *ODSIdentityError(OSStatus status, NSString *what)
{
  return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                         userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (%d)", what, (int)status] }];
}

// The keychain the identity is kept in: the data protection one where an
// app has it (iOS); the file keychain on macOS, where a process unsigned
// (a test runner) has no other.
static void ODSKeychain(NSMutableDictionary *query)
{
#if TARGET_OS_IPHONE
  query[(__bridge id)kSecUseDataProtectionKeychain] = @YES;
#endif
}

@implementation ODataSyncPeerIdentity {
  SecIdentityRef _identity;
  SecCertificateRef _certificate;
}

+ (NSString *)thumbprintOfCertificateData:(NSData *)certificate
{
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(certificate.bytes, (CC_LONG)certificate.length, digest);
  NSString *base64 = [[NSData dataWithBytes:digest length:sizeof digest] base64EncodedStringWithOptions:0];
  base64 = [[base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  return [base64 stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
}

+ (NSString *)thumbprintOfCertificate:(SecCertificateRef)certificate
{
  if (!certificate) return nil;
  NSData *der = (__bridge_transfer NSData *)SecCertificateCopyData(certificate);
  return der ? [self thumbprintOfCertificateData:der] : nil;
}

- (instancetype)initWithName:(NSString *)name identity:(SecIdentityRef)identity
{
  self = [super init];
  if (!self) return nil;
  _name = [name copy];
  _identity = (SecIdentityRef)CFRetain(identity);
  SecIdentityCopyCertificate(identity, &_certificate);
  _certificateData = (__bridge_transfer NSData *)SecCertificateCopyData(_certificate);
  _thumbprint = [ODataSyncPeerIdentity thumbprintOfCertificateData:_certificateData];
  return self;
}

- (void)dealloc
{
  if (_identity) CFRelease(_identity);
  if (_certificate) CFRelease(_certificate);
}

- (SecIdentityRef)identity
{
  return _identity;
}

- (SecCertificateRef)certificate
{
  return _certificate;
}

+ (NSString *)labelOf:(NSString *)name
{
  return [@"ODataSync peer " stringByAppendingString:name];
}

// The certificate kept under the name, then the identity of that very
// certificate (the keychain's pairing of it with its key): an identity
// query by label can answer with another identity altogether (the macOS
// file keychain does), so the certificate decides, and is checked.
+ (SecIdentityRef)copyKeptIdentityNamed:(NSString *)name
{
  NSMutableDictionary *query = [@{ (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
                                   (__bridge id)kSecAttrLabel: [self labelOf:name],
                                   (__bridge id)kSecReturnRef: @YES,
                                   (__bridge id)kSecReturnAttributes: @YES } mutableCopy];
  ODSKeychain(query);
  CFTypeRef found = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &found) != errSecSuccess) return NULL;
  NSDictionary *item = (__bridge_transfer NSDictionary *)found;
  SecCertificateRef certificate = (__bridge SecCertificateRef)item[(__bridge id)kSecValueRef];
  if (!certificate) return NULL;
  SecIdentityRef identity = NULL;
#if TARGET_OS_OSX
  if (SecIdentityCreateWithCertificate(NULL, certificate, &identity) != errSecSuccess) return NULL;
#else
  NSData *keyHash = item[(__bridge id)kSecAttrPublicKeyHash];
  if (!keyHash) return NULL;
  NSMutableDictionary *pair = [@{ (__bridge id)kSecClass: (__bridge id)kSecClassIdentity,
                                  (__bridge id)kSecAttrApplicationLabel: keyHash,
                                  (__bridge id)kSecReturnRef: @YES } mutableCopy];
  ODSKeychain(pair);
  CFTypeRef paired = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)pair, &paired) != errSecSuccess) return NULL;
  identity = (SecIdentityRef)paired;
#endif
  // That certificate, or none at all.
  SecCertificateRef its = NULL;
  SecIdentityCopyCertificate(identity, &its);
  NSData *mine = (__bridge_transfer NSData *)SecCertificateCopyData(certificate);
  NSData *theirs = its ? (__bridge_transfer NSData *)SecCertificateCopyData(its) : nil;
  if (its) CFRelease(its);
  if (![mine isEqualToData:theirs]) {
    CFRelease(identity);
    return NULL;
  }
  return identity;
}

+ (instancetype)identityNamed:(NSString *)name error:(NSError **)error
{
  SecIdentityRef kept = [self copyKeptIdentityNamed:name];
  if (kept) {
    ODataSyncPeerIdentity *identity = [[self alloc] initWithName:name identity:kept];
    CFRelease(kept);
    return identity;
  }
  return [self makeIdentityNamed:name error:error];
}

// A key pair in the keychain, a certificate of it signed by it, kept
// beside it: the keychain pairs them into an identity.
+ (instancetype)makeIdentityNamed:(NSString *)name error:(NSError **)error
{
  NSString *label = [self labelOf:name];
  NSMutableDictionary *keyAttributes = [@{ (__bridge id)kSecAttrIsPermanent: @YES,
                                           (__bridge id)kSecAttrLabel: label,
                                           (__bridge id)kSecAttrApplicationTag: [label dataUsingEncoding:NSUTF8StringEncoding] } mutableCopy];
#if TARGET_OS_IPHONE
  keyAttributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
#endif
  NSMutableDictionary *parameters = [@{ (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                                        (__bridge id)kSecAttrKeySizeInBits: @256,
                                        (__bridge id)kSecPrivateKeyAttrs: keyAttributes } mutableCopy];
  ODSKeychain(parameters);
  CFErrorRef keyError = NULL;
  SecKeyRef privateKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)parameters, &keyError);
  if (!privateKey) {
    if (error) *error = (__bridge_transfer NSError *)keyError;
    return nil;
  }
  SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
  NSData *point = (__bridge_transfer NSData *)SecKeyCopyExternalRepresentation(publicKey, NULL);  // 04 || X || Y
  CFRelease(publicKey);

  uint8_t serial[16];
  if (SecRandomCopyBytes(kSecRandomDefault, sizeof serial, serial) != errSecSuccess) arc4random_buf(serial, sizeof serial);
  serial[0] &= 0x7f;
  NSDate *now = [NSDate date];
  NSData *algorithm = ODSDERECDSAWithSHA256();
  NSData *subjectKey = ODSDERSequence(@[ ODSDERSequence(@[ ODSDEROID(@[ @1, @2, @840, @10045, @2, @1 ]),
                                                           ODSDEROID(@[ @1, @2, @840, @10045, @3, @1, @7 ]) ]),
                                         ODSDERBitString(point) ]);
  NSData *version = ODSDER(0xa0, ODSDERUnsigned([NSData dataWithBytes:(uint8_t[]){ 2 } length:1]));
  NSData *tbs = ODSDERSequence(@[ version, ODSDERUnsigned([NSData dataWithBytes:serial length:sizeof serial]), algorithm,
                                  ODSDERName(label),
                                  ODSDERSequence(@[ ODSDERTime([now dateByAddingTimeInterval:-86400]),
                                                    ODSDERTime([now dateByAddingTimeInterval:20 * 365.25 * 86400]) ]),
                                  ODSDERName(label), subjectKey ]);
  CFErrorRef signError = NULL;
  NSData *signature = (__bridge_transfer NSData *)SecKeyCreateSignature(privateKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                                                        (__bridge CFDataRef)tbs, &signError);
  if (!signature) {
    CFRelease(privateKey);
    if (error) *error = (__bridge_transfer NSError *)signError;
    return nil;
  }
  NSData *der = ODSDERSequence(@[ tbs, algorithm, ODSDERBitString(signature) ]);
  SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
  if (!certificate) {
    CFRelease(privateKey);
    if (error) *error = ODSIdentityError(errSecDecode, @"The certificate made is not one");
    return nil;
  }
  NSMutableDictionary *add = [@{ (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
                                 (__bridge id)kSecValueRef: (__bridge id)certificate,
                                 (__bridge id)kSecAttrLabel: label } mutableCopy];
  ODSKeychain(add);
  OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  CFRelease(certificate);
  CFRelease(privateKey);
  if (status != errSecSuccess && status != errSecDuplicateItem) {
    if (error) *error = ODSIdentityError(status, @"The certificate could not be kept");
    return nil;
  }
  SecIdentityRef identity = [self copyKeptIdentityNamed:name];
  if (!identity) {
    if (error) *error = ODSIdentityError(errSecItemNotFound, @"The keychain did not pair the key with its certificate");
    return nil;
  }
  ODataSyncPeerIdentity *made = [[self alloc] initWithName:name identity:identity];
  CFRelease(identity);
  return made;
}

- (BOOL)removeWithError:(NSError **)error
{
  NSString *label = [ODataSyncPeerIdentity labelOf:_name];
  OSStatus worst = errSecSuccess;
  for (id itemClass in @[ (__bridge id)kSecClassCertificate, (__bridge id)kSecClassKey ]) {
    NSMutableDictionary *query = [@{ (__bridge id)kSecClass: itemClass, (__bridge id)kSecAttrLabel: label } mutableCopy];
    ODSKeychain(query);
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecSuccess && status != errSecItemNotFound) worst = status;
  }
  if (worst != errSecSuccess && error) *error = ODSIdentityError(worst, @"The identity could not be forgotten");
  return worst == errSecSuccess;
}

@end
#endif
