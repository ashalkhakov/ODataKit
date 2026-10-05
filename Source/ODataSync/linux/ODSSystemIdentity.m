// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Identities in files: the certificate and the private key, PEM, made
// with GnuTLS, the key readable by the user alone (0600), in a directory
// of the app's (0700).

#import "ODSLinuxSystem.h"
#import <ODataSync/ODataSyncPeerIdentity.h>
#include <gnutls/gnutls.h>
#include <gnutls/x509.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSError *ODSIdentityError(int code, NSString *what)
{
  NSString *text = code ? [NSString stringWithFormat:@"%@ (%s)", what, gnutls_strerror(code)] : what;
  return [NSError errorWithDomain:@"GnuTLS" code:code userInfo:@{ NSLocalizedDescriptionKey: text }];
}

static NSData *ODSDatum(gnutls_datum_t *datum)
{
  NSData *data = [NSData dataWithBytes:datum->data length:datum->size];
  gnutls_free(datum->data);
  datum->data = NULL;
  return data;
}

@implementation ODSSystemIdentity

- (instancetype)initWithCertificate:(NSData *)certificate certificateURL:(NSURL *)certificateURL keyURL:(NSURL *)keyURL
{
  self = [super init];
  if (!self) return nil;
  _certificate = [certificate copy];
  _certificateURL = [certificateURL copy];
  _keyURL = [keyURL copy];
  return self;
}

@end

// The label, as a file's: what is not a letter, a digit, a dot or a dash
// as an underscore, and (so that two labels never meet) its hash's start.
static NSString *ODSFileStem(NSString *label)
{
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                                                @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.-"];
  NSMutableString *stem = [NSMutableString string];
  for (NSUInteger i = 0; i < label.length && stem.length < 64; i++) {
    unichar c = [label characterAtIndex:i];
    [stem appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
  }
  NSString *hash = [ODataSyncPeerIdentity thumbprintOfCertificateData:[label dataUsingEncoding:NSUTF8StringEncoding]];
  return [NSString stringWithFormat:@"%@-%@", stem, [hash substringToIndex:8]];
}

// The files as they are: a certificate, and the key it is of (GnuTLS
// checks the two belong together).
static ODSSystemIdentity *ODSKeptIdentity(NSURL *certificateURL, NSURL *keyURL, NSError **error)
{
  gnutls_certificate_credentials_t credentials = NULL;
  gnutls_certificate_allocate_credentials(&credentials);
  int status = gnutls_certificate_set_x509_key_file2(credentials, certificateURL.path.fileSystemRepresentation,
                                                     keyURL.path.fileSystemRepresentation, GNUTLS_X509_FMT_PEM, NULL, 0);
  gnutls_certificate_free_credentials(credentials);
  if (status < 0) {
    if (error) *error = ODSIdentityError(status, [@"The identity kept does not load: " stringByAppendingString:certificateURL.path]);
    return nil;
  }
  NSData *pem = [NSData dataWithContentsOfURL:certificateURL];
  gnutls_x509_crt_t certificate = NULL;
  gnutls_x509_crt_init(&certificate);
  gnutls_datum_t in = { (unsigned char *)pem.bytes, (unsigned int)pem.length }, der = { NULL, 0 };
  status = gnutls_x509_crt_import(certificate, &in, GNUTLS_X509_FMT_PEM);
  if (status >= 0) status = gnutls_x509_crt_export2(certificate, GNUTLS_X509_FMT_DER, &der);
  gnutls_x509_crt_deinit(certificate);
  if (status < 0) {
    if (error) *error = ODSIdentityError(status, @"The certificate kept is not one");
    return nil;
  }
  return [[ODSSystemIdentity alloc] initWithCertificate:ODSDatum(&der) certificateURL:certificateURL keyURL:keyURL];
}

// A P-256 key, and a certificate of it signed by it (X.509 v3, CN the
// label, a random serial, good from yesterday for twenty years).
static ODSSystemIdentity *ODSMakeIdentity(NSString *label, NSURL *certificateURL, NSURL *keyURL, NSError **error)
{
  gnutls_x509_privkey_t key = NULL;
  gnutls_x509_crt_t certificate = NULL;
  gnutls_datum_t keyPEM = { NULL, 0 }, certificatePEM = { NULL, 0 }, der = { NULL, 0 };
  NSString *what = @"The key could not be made";
  int status = gnutls_x509_privkey_init(&key);
  if (status >= 0) status = gnutls_x509_privkey_generate(key, GNUTLS_PK_ECDSA, GNUTLS_CURVE_TO_BITS(GNUTLS_ECC_CURVE_SECP256R1), 0);
  if (status >= 0) {
    what = @"The certificate could not be made";
    status = gnutls_x509_crt_init(&certificate);
  }
  if (status >= 0) status = gnutls_x509_crt_set_version(certificate, 3);
  uint8_t serial[16];
  ODSSystemRandomBytes(serial, sizeof serial);
  serial[0] &= 0x7f;
  if (status >= 0) status = gnutls_x509_crt_set_serial(certificate, serial, sizeof serial);
  time_t now = time(NULL);
  if (status >= 0) status = gnutls_x509_crt_set_activation_time(certificate, now - 86400);
  if (status >= 0) status = gnutls_x509_crt_set_expiration_time(certificate, now + (time_t)(20 * 365.25 * 86400));
  const char *cn = label.UTF8String;
  if (status >= 0) status = gnutls_x509_crt_set_dn_by_oid(certificate, GNUTLS_OID_X520_COMMON_NAME, 0, cn, (unsigned)strlen(cn));
  if (status >= 0) status = gnutls_x509_crt_set_key(certificate, key);
  if (status >= 0) status = gnutls_x509_crt_sign2(certificate, certificate, key, GNUTLS_DIG_SHA256, 0);
  if (status >= 0) status = gnutls_x509_crt_export2(certificate, GNUTLS_X509_FMT_DER, &der);
  if (status >= 0) status = gnutls_x509_crt_export2(certificate, GNUTLS_X509_FMT_PEM, &certificatePEM);
  if (status >= 0) status = gnutls_x509_privkey_export2(key, GNUTLS_X509_FMT_PEM, &keyPEM);
  if (certificate) gnutls_x509_crt_deinit(certificate);
  if (key) gnutls_x509_privkey_deinit(key);
  if (status < 0) {
    gnutls_free(der.data);
    gnutls_free(certificatePEM.data);
    gnutls_free(keyPEM.data);
    if (error) *error = ODSIdentityError(status, what);
    return nil;
  }
  NSData *certificateData = ODSDatum(&der);
  NSData *certificateText = ODSDatum(&certificatePEM);
  NSData *keyText = ODSDatum(&keyPEM);
  // The key first: a certificate alone is no identity.
  if (!ODSSystemWritePrivateFile(keyText, keyURL, error)) return nil;
  if (![certificateText writeToURL:certificateURL options:NSDataWritingAtomic error:error]) {
    unlink(keyURL.path.fileSystemRepresentation);
    return nil;
  }
  return [[ODSSystemIdentity alloc] initWithCertificate:certificateData certificateURL:certificateURL keyURL:keyURL];
}

// The directory, made (0700) when missing; one the user owns, that no one
// else may enter (made so when it is the user's): else no identity is kept
// there, nor read from it (someone else's could hold a key planted).
static BOOL ODSPrivateDirectory(NSURL *directory, NSError **error)
{
  const char *path = directory.path.fileSystemRepresentation;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:directory.path withIntermediateDirectories:YES
                                                  attributes:@{ NSFilePosixPermissions: @0700 } error:error]) return NO;
  struct stat info;
  if (lstat(path, &info) != 0) {
    if (error) *error = ODSSystemPOSIXError(@"Cannot look at", directory.path);
    return NO;
  }
  if (!S_ISDIR(info.st_mode) || info.st_uid != getuid()) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a directory of this user's", directory.path] }];
    return NO;
  }
  if ((info.st_mode & 077) && chmod(path, 0700) != 0) {
    if (error) *error = ODSSystemPOSIXError(@"Cannot make private", directory.path);
    return NO;
  }
  return YES;
}

ODSSystemIdentity *ODSSystemKeepIdentity(NSString *label, NSURL *directory, NSError **error)
{
  NSString *stem = ODSFileStem(label);
  NSURL *certificateURL = [directory URLByAppendingPathComponent:[stem stringByAppendingString:@".crt.pem"]];
  NSURL *keyURL = [directory URLByAppendingPathComponent:[stem stringByAppendingString:@".key.pem"]];
  if (!ODSPrivateDirectory(directory, error)) return nil;
  NSFileManager *files = [NSFileManager defaultManager];
  if ([files fileExistsAtPath:certificateURL.path] && [files fileExistsAtPath:keyURL.path]) {
    return ODSKeptIdentity(certificateURL, keyURL, error);
  }
  return ODSMakeIdentity(label, certificateURL, keyURL, error);
}

BOOL ODSSystemForgetIdentity(ODSSystemIdentity *identity, NSError **error)
{
  BOOL ok = YES;
  for (NSURL *url in @[ identity.keyURL, identity.certificateURL ]) {
    if (unlink(url.path.fileSystemRepresentation) != 0 && errno != ENOENT) {
      if (error && ok) *error = ODSSystemPOSIXError(@"Could not remove", url.path);
      ok = NO;
    }
  }
  return ok;
}
