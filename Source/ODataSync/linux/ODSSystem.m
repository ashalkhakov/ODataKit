// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSLinuxSystem.h"
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>

NSData *ODSSystemSHA256(NSData *data)
{
  uint8_t digest[32];
  gnutls_hash_fast(GNUTLS_DIG_SHA256, data.bytes, data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof digest];
}

void ODSSystemRandomBytes(void *bytes, size_t length)
{
  gnutls_rnd(GNUTLS_RND_KEY, bytes, length);
}

NSUInteger ODSSystemPrivateFileWritingOptions(void)
{
  return NSDataWritingAtomic;
}

NSString *ODSSystemDeviceName(void)
{
  return [NSProcessInfo processInfo].hostName;
}

// A .local name takes nss-mdns, which not every Linux has: the address is
// looked up through Avahi instead.
BOOL ODSSystemResolvesLocalNames(void)
{
  return NO;
}

NSURL *ODSSystemIdentityDirectory(void)
{
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                      ?: NSTemporaryDirectory();
  NSString *path = [[support stringByAppendingPathComponent:[NSProcessInfo processInfo].processName]
                    stringByAppendingPathComponent:@"ODataSync Peers"];
  return [NSURL fileURLWithPath:path isDirectory:YES];
}
