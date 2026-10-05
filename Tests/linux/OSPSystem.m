// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OSPSystem.h"
#import "ODSLinuxSystem.h"
#include <curl/curl.h>
#include <gnutls/gnutls.h>
#include <gnutls/x509.h>
#include <gnutls/abstract.h>
#include <sys/stat.h>

// libcurl's: the server's certificate from what it tells of a new
// connection, kept for those after.

static size_t OSPBody(char *bytes, size_t size, size_t count, void *context)
{
  [(__bridge NSMutableData *)context appendBytes:bytes length:size * count];
  return size * count;
}

@implementation OSPClient {
  CURL *_curl;
}

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity
{
  self = [super init];
  _identity = identity;
  _curl = curl_easy_init();
  return self;
}

- (void)dealloc
{
  [self close];
}

- (NSInteger)get:(NSURL *)url json:(id *)json error:(NSError **)error
{
  NSMutableData *body = [NSMutableData data];
  curl_easy_reset(_curl);
  curl_easy_setopt(_curl, CURLOPT_URL, url.absoluteString.UTF8String);
  curl_easy_setopt(_curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(_curl, CURLOPT_TIMEOUT, 20L);
  curl_easy_setopt(_curl, CURLOPT_SSL_VERIFYPEER, 0L);
  curl_easy_setopt(_curl, CURLOPT_SSL_VERIFYHOST, 0L);
  curl_easy_setopt(_curl, CURLOPT_CERTINFO, 1L);
  if (self.identity) {
    curl_easy_setopt(_curl, CURLOPT_SSLCERT, self.identity.system.certificateURL.path.fileSystemRepresentation);
    curl_easy_setopt(_curl, CURLOPT_SSLKEY, self.identity.system.keyURL.path.fileSystemRepresentation);
  }
  curl_easy_setopt(_curl, CURLOPT_WRITEFUNCTION, OSPBody);
  curl_easy_setopt(_curl, CURLOPT_WRITEDATA, (__bridge void *)body);
  CURLcode code = curl_easy_perform(_curl);
  long status = 0;
  curl_easy_getinfo(_curl, CURLINFO_RESPONSE_CODE, &status);
  struct curl_certinfo *info = NULL;
  if (code == CURLE_OK && curl_easy_getinfo(_curl, CURLINFO_CERTINFO, &info) == CURLE_OK && info && info->num_of_certs > 0) {
    for (struct curl_slist *field = info->certinfo[0]; field; field = field->next) {
      if (strncmp(field->data, "Cert:", 5) != 0) continue;
      gnutls_datum_t in = { (unsigned char *)field->data + 5, (unsigned int)strlen(field->data + 5) }, der = { NULL, 0 };
      if (gnutls_pem_base64_decode2("CERTIFICATE", &in, &der) >= 0) {
        self.serverThumbprint = [ODataSyncPeerIdentity thumbprintOfCertificateData:[NSData dataWithBytes:der.data length:der.size]];
        gnutls_free(der.data);
      }
    }
  }
  if (json) *json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
  if (error) {
    *error = code == CURLE_OK ? nil : [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorSecureConnectionFailed
                                                      userInfo:@{ NSLocalizedDescriptionKey: @(curl_easy_strerror(code)) }];
  }
  return code == CURLE_OK ? status : 0;
}

- (void)close
{
  if (_curl) curl_easy_cleanup(_curl);
  _curl = NULL;
}
@end

NSString *OSPCheckIdentity(ODataSyncPeerIdentity *identity)
{
  NSString *wrong = nil;
  // Well formed and signed by its own key: trusted as its own anchor.
  gnutls_x509_crt_t certificate = NULL;
  gnutls_x509_crt_init(&certificate);
  gnutls_datum_t der = { (unsigned char *)identity.certificateData.bytes, (unsigned int)identity.certificateData.length };
  unsigned int verified = 1;
  if (gnutls_x509_crt_import(certificate, &der, GNUTLS_X509_FMT_DER) < 0) {
    wrong = @"the certificate is not one";
  } else if (gnutls_x509_crt_verify(certificate, &certificate, 1, 0, &verified) < 0 || verified != 0) {
    wrong = [NSString stringWithFormat:@"not its own anchor (status %u)", verified];
  }

  // Its key signs, and the certificate's public key checks it.
  NSData *keyText = [NSData dataWithContentsOfURL:identity.system.keyURL];
  gnutls_datum_t keyPEM = { (unsigned char *)keyText.bytes, (unsigned int)keyText.length };
  gnutls_privkey_t key = NULL;
  gnutls_pubkey_t publicKey = NULL;
  gnutls_privkey_init(&key);
  gnutls_pubkey_init(&publicKey);
  gnutls_datum_t message = { (unsigned char *)"peer", 4 }, signature = { NULL, 0 };
  if (!wrong) {
    if (gnutls_privkey_import_x509_raw(key, &keyPEM, GNUTLS_X509_FMT_PEM, NULL, 0) < 0) wrong = @"the key does not load";
    else if (gnutls_privkey_sign_data(key, GNUTLS_DIG_SHA256, 0, &message, &signature) < 0) wrong = @"the key does not sign";
    else if (gnutls_pubkey_import_x509(publicKey, certificate, 0) < 0) wrong = @"the certificate has no public key";
    else if (gnutls_pubkey_verify_data2(publicKey, GNUTLS_SIGN_ECDSA_SHA256, 0, &message, &signature) < 0) {
      wrong = @"the key's signature does not check with the certificate";
    }
  }
  gnutls_free(signature.data);
  gnutls_pubkey_deinit(publicKey);
  gnutls_privkey_deinit(key);
  gnutls_x509_crt_deinit(certificate);
  if (wrong) return wrong;

  // The key the user's alone.
  struct stat info;
  if (stat(identity.system.keyURL.path.fileSystemRepresentation, &info) != 0) return @"the key file is gone";
  if ((info.st_mode & 0777) != 0600) return [NSString stringWithFormat:@"the key file's mode is %o, not 600", info.st_mode & 0777];
  return nil;
}

BOOL OSPDiscoveryAvailable(void)
{
  return [[NSFileManager defaultManager] fileExistsAtPath:@"/run/avahi-daemon/socket"] ||
         [[NSFileManager defaultManager] fileExistsAtPath:@"/var/run/avahi-daemon/socket"];
}
