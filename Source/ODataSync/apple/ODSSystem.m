// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSAppleSystem.h"
#import <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NSData *ODSSystemSHA256(NSData *data)
{
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof digest];
}

void ODSSystemRandomBytes(void *bytes, size_t length)
{
  if (SecRandomCopyBytes(kSecRandomDefault, length, bytes) != errSecSuccess) arc4random_buf(bytes, length);
}

BOOL ODSSystemWritePrivateFile(NSData *data, NSURL *url, NSError **error)
{
  // Data protection where there is any (iOS; macOS takes it as atomic).
  NSDataWritingOptions options = NSDataWritingAtomic;
  if (@available(macOS 11.0, iOS 4.0, *)) options |= NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
  return [data writeToURL:url options:options error:error];
}

void ODSSystemDispatchRelease(dispatch_object_t object)
{
}

NSString *ODSSystemDeviceName(void)
{
#if TARGET_OS_IPHONE
  __block NSString *name = nil;
  if ([NSThread isMainThread]) name = [UIDevice currentDevice].name;
  else dispatch_sync(dispatch_get_main_queue(), ^{ name = [UIDevice currentDevice].name; });
  return name;
#else
  return [NSHost currentHost].localizedName ?: [NSProcessInfo processInfo].hostName;
#endif
}

BOOL ODSSystemResolvesLocalNames(void)
{
  return YES;
}

NSURL *ODSSystemIdentityDirectory(void)
{
  // The keychain keeps them; a directory is never written.
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
  return [NSURL fileURLWithPath:[support stringByAppendingPathComponent:@"ODataSync Peers"] isDirectory:YES];
}

NSString *ODSAppleThumbprint(SecCertificateRef certificate)
{
  if (!certificate) return nil;
  NSData *der = (__bridge_transfer NSData *)SecCertificateCopyData(certificate);
  return der ? [ODataSyncPeerIdentity thumbprintOfCertificateData:der] : nil;
}

// The Keychain: a generic password, its data the secrets as a property
// list; on iOS, this device's only, once it was unlocked.
static NSDictionary *ODSKeychainQuery(NSString *service, NSString *account)
{
  return @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
            (__bridge id)kSecAttrAccount: account };
}

NSDictionary *ODSSystemSecrets(NSString *service, NSString *account)
{
  NSMutableDictionary *query = [ODSKeychainQuery(service, account) mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef found = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &found) != errSecSuccess || !found) return nil;
  NSData *data = (__bridge_transfer NSData *)found;
  id secrets = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
  return [secrets isKindOfClass:[NSDictionary class]] ? secrets : nil;
}

BOOL ODSSystemSetSecrets(NSDictionary *secrets, NSString *service, NSString *account)
{
  NSDictionary *query = ODSKeychainQuery(service, account);
  SecItemDelete((__bridge CFDictionaryRef)query);
  if (!secrets) return YES;
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:secrets format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
  if (!data) return NO;
  NSMutableDictionary *item = [query mutableCopy];
  item[(__bridge id)kSecValueData] = data;
#if TARGET_OS_IPHONE
  item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
#endif
  return SecItemAdd((__bridge CFDictionaryRef)item, NULL) == errSecSuccess;
}
