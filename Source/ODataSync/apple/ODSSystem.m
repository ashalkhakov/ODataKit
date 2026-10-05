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
