// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// ODSSystem on Windows: GnuTLS for hashes and random bytes, as on Linux;
// files written with Windows' own calls. A file is the user's alone where
// it is kept: Application Support is in the user's profile, whose
// permissions it inherits (Linux's 0600).

#import "ODSWindowsSystem.h"
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

NSError *ODSSystemPeersUnavailable(void)
{
  return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError
                         userInfo:@{ NSLocalizedDescriptionKey: @"Syncing with devices nearby is not available on Windows yet." }];
}

static NSError *ODSSystemWindowsError(NSString *what, NSString *path)
{
  DWORD code = GetLastError();
  wchar_t text[256] = L"";
  FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, text, 256, NULL);
  NSString *why = [[NSString stringWithCharacters:(const unichar *)text length:wcslen(text)]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
                         userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ %@ (%@)", what, path, why] }];
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

// Written beside it, then moved over it: a new file (CREATE_NEW: not one
// someone left there), through to the disk before it takes the name.
BOOL ODSSystemWritePrivateFile(NSData *data, NSURL *url, NSError **error)
{
  NSString *path = url.path;
  NSString *partial = [path stringByAppendingFormat:@".%@.partial", [NSUUID UUID].UUIDString];
  const wchar_t *wpartial = (const wchar_t *)[partial cStringUsingEncoding:NSUnicodeStringEncoding];
  const wchar_t *wpath = (const wchar_t *)[path cStringUsingEncoding:NSUnicodeStringEncoding];
  HANDLE file = CreateFileW(wpartial, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);
  if (file == INVALID_HANDLE_VALUE) {
    if (error) *error = ODSSystemWindowsError(@"Could not write", partial);
    return NO;
  }
  const uint8_t *bytes = data.bytes;
  NSUInteger written = 0;
  while (written < data.length) {
    DWORD n = 0;
    DWORD chunk = (DWORD)MIN(data.length - written, (NSUInteger)(1 << 30));
    if (!WriteFile(file, bytes + written, chunk, &n, NULL) || n == 0) {
      if (error) *error = ODSSystemWindowsError(@"Could not write", partial);
      CloseHandle(file);
      DeleteFileW(wpartial);
      return NO;
    }
    written += n;
  }
  FlushFileBuffers(file);
  CloseHandle(file);
  if (!MoveFileExW(wpartial, wpath, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    if (error) *error = ODSSystemWindowsError(@"Could not keep", path);
    DeleteFileW(wpartial);
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

BOOL ODSSystemResolvesLocalNames(void)
{
  return NO;
}

NSURL *ODSSystemIdentityDirectory(void)
{
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                      ?: NSHomeDirectory();
  NSString *path = [[support stringByAppendingPathComponent:[NSProcessInfo processInfo].processName]
                    stringByAppendingPathComponent:@"ODataSync Peers"];
  return [NSURL fileURLWithPath:path isDirectory:YES];
}

// As on Linux: a property list in the user's Application Support, every
// service's accounts in one file, written whole.
static NSURL *ODSSecretsFile(NSString *service)
{
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                      ?: NSHomeDirectory();
  NSString *directory = [support stringByAppendingPathComponent:service];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Secrets.plist"]];
}

static NSDictionary *ODSAllSecrets(NSString *service)
{
  NSData *data = [NSData dataWithContentsOfURL:ODSSecretsFile(service)];
  id all = data.length ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
  return [all isKindOfClass:[NSDictionary class]] ? all : @{};
}

NSDictionary *ODSSystemSecrets(NSString *service, NSString *account)
{
  id mine = ODSAllSecrets(service)[account];
  return [mine isKindOfClass:[NSDictionary class]] ? mine : nil;
}

BOOL ODSSystemSetSecrets(NSDictionary *secrets, NSString *service, NSString *account)
{
  NSMutableDictionary *all = [ODSAllSecrets(service) mutableCopy];
  if (secrets) all[account] = secrets;
  else [all removeObjectForKey:account];
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:all format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
  return data && ODSSystemWritePrivateFile(data, ODSSecretsFile(service), NULL);
}
