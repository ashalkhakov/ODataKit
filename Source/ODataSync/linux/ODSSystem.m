// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSLinuxSystem.h"
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSError *ODSSystemPOSIXError(NSString *what, NSString *path)
{
  int code = errno;
  return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                         userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ %@ (%s)", what, path, strerror(code)] }];
}

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

// Written beside it, then renamed over it: a new file of the user's alone
// (O_EXCL: not one someone left there; O_NOFOLLOW: not through a link).
BOOL ODSSystemWritePrivateFile(NSData *data, NSURL *url, NSError **error)
{
  NSString *path = url.path;
  NSString *partial = [path stringByAppendingFormat:@".%@.partial", [NSUUID UUID].UUIDString];
  int fd = open(partial.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) {
    if (error) *error = ODSSystemPOSIXError(@"Could not write", partial);
    return NO;
  }
  fchmod(fd, 0600);
  const uint8_t *bytes = data.bytes;
  NSUInteger written = 0;
  while (written < data.length) {
    ssize_t n = write(fd, bytes + written, data.length - written);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      if (error) *error = ODSSystemPOSIXError(@"Could not write", partial);
      close(fd);
      unlink(partial.fileSystemRepresentation);
      return NO;
    }
    written += (NSUInteger)n;
  }
  fsync(fd);
  close(fd);
  if (rename(partial.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
    if (error) *error = ODSSystemPOSIXError(@"Could not keep", path);
    unlink(partial.fileSystemRepresentation);
    return NO;
  }
  return YES;
}

void ODSSystemDispatchRelease(dispatch_object_t object)
{
  if (object._do) dispatch_release(object);
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
  // Never a shared temporary directory: someone else could make it first.
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                      ?: [NSHomeDirectory() stringByAppendingPathComponent:@".local/share"];
  NSString *path = [[support stringByAppendingPathComponent:[NSProcessInfo processInfo].processName]
                    stringByAppendingPathComponent:@"ODataSync Peers"];
  return [NSURL fileURLWithPath:path isDirectory:YES];
}
