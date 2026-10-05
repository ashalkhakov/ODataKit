// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The peer client on libcurl (built with GnuTLS). libcurl pins a public
// key, not a certificate: a peer's certificate is seen first on a new
// connection, not kept (its "Cert:" info), and its key pinned for every
// request after.

#import "ODSLinuxSystem.h"
#import <ODataSync/ODataSyncPeerIdentity.h>
#include <curl/curl.h>
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <gnutls/x509.h>
#include <gnutls/abstract.h>

static NSError *ODSCurlError(CURLcode code, const char *detail)
{
  NSInteger url = NSURLErrorUnknown;
  switch (code) {
    case CURLE_COULDNT_RESOLVE_HOST: url = NSURLErrorCannotFindHost; break;
    case CURLE_COULDNT_CONNECT: url = NSURLErrorCannotConnectToHost; break;
    case CURLE_OPERATION_TIMEDOUT: url = NSURLErrorTimedOut; break;
    case CURLE_SSL_PINNEDPUBKEYNOTMATCH: url = NSURLErrorServerCertificateUntrusted; break;
    case CURLE_SSL_CONNECT_ERROR: url = NSURLErrorSecureConnectionFailed; break;
    case CURLE_SEND_ERROR:
    case CURLE_RECV_ERROR:
    case CURLE_GOT_NOTHING: url = NSURLErrorNetworkConnectionLost; break;
    default: break;
  }
  NSString *text = detail && *detail ? [NSString stringWithFormat:@"%s (%s)", curl_easy_strerror(code), detail] : @(curl_easy_strerror(code));
  return [NSError errorWithDomain:NSURLErrorDomain code:url userInfo:@{ NSLocalizedDescriptionKey: text, @"CURLcode": @(code) }];
}

static size_t ODSCurlBody(char *bytes, size_t size, size_t count, void *context)
{
  [(__bridge NSMutableData *)context appendBytes:bytes length:size * count];
  return size * count;
}

// Each response's header fields; a new status line (after a 100) starts
// them again.
static size_t ODSCurlHeader(char *bytes, size_t size, size_t count, void *context)
{
  NSMutableDictionary *fields = (__bridge NSMutableDictionary *)context;
  NSString *line = [[NSString alloc] initWithBytes:bytes length:size * count encoding:NSISOLatin1StringEncoding];
  line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([line hasPrefix:@"HTTP/"]) {
    [fields removeAllObjects];
  } else {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location != NSNotFound && colon.location > 0) {
      NSString *name = [line substringToIndex:colon.location];
      NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSString *had = fields[name];
      fields[name] = had ? [NSString stringWithFormat:@"%@, %@", had, value] : value;
    }
  }
  return size * count;
}

// libcurl pins a public key (sha256//base64 of its SubjectPublicKeyInfo's
// SHA-256), during the handshake: the key of the certificate known.
static NSString *ODSKeyPin(NSData *certificate)
{
  gnutls_x509_crt_t parsed = NULL;
  gnutls_pubkey_t key = NULL;
  gnutls_datum_t in = { (unsigned char *)certificate.bytes, (unsigned int)certificate.length }, spki = { NULL, 0 };
  int status = gnutls_x509_crt_init(&parsed);
  if (status >= 0) status = gnutls_x509_crt_import(parsed, &in, GNUTLS_X509_FMT_DER);
  if (status >= 0) status = gnutls_pubkey_init(&key);
  if (status >= 0) status = gnutls_pubkey_import_x509(key, parsed, 0);
  if (status >= 0) status = gnutls_pubkey_export2(key, GNUTLS_X509_FMT_DER, &spki);
  if (key) gnutls_pubkey_deinit(key);
  if (parsed) gnutls_x509_crt_deinit(parsed);
  if (status < 0) return nil;
  uint8_t digest[32];
  gnutls_hash_fast(GNUTLS_DIG_SHA256, spki.data, spki.size, digest);
  gnutls_free(spki.data);
  return [@"sha256//" stringByAppendingString:[[NSData dataWithBytes:digest length:sizeof digest] base64EncodedStringWithOptions:0]];
}

// The server's certificate, from what libcurl tells of a new connection
// (its "Cert:" field, PEM).
static NSData *ODSPresentedCertificate(CURL *curl)
{
  struct curl_certinfo *info = NULL;
  if (curl_easy_getinfo(curl, CURLINFO_CERTINFO, &info) != CURLE_OK || !info || info->num_of_certs < 1) return nil;
  for (struct curl_slist *field = info->certinfo[0]; field; field = field->next) {
    if (strncmp(field->data, "Cert:", 5) != 0) continue;
    const char *pem = field->data + 5;
    gnutls_datum_t in = { (unsigned char *)pem, (unsigned int)strlen(pem) }, der = { NULL, 0 };
    if (gnutls_pem_base64_decode2("CERTIFICATE", &in, &der) < 0) return nil;
    NSData *certificate = [NSData dataWithBytes:der.data length:der.size];
    gnutls_free(der.data);
    return certificate;
  }
  return nil;
}

@implementation ODSSystemPeerClient {
  ODataSyncPeerIdentity *_identity;
  NSLock *_sending;
  CURL *_curl;
  NSMutableDictionary<NSString *, NSString *> *_keyPins;  // thumbprint -> sha256//<its public key's hash>
}

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity
{
  self = [super init];
  if (!self) return nil;
  _identity = identity;
  _sending = [[NSLock alloc] init];
  _keyPins = [NSMutableDictionary dictionary];
  return self;
}

- (void)dealloc
{
  if (_curl) curl_easy_cleanup(_curl);
}

// A request, waited for: the response, the body, the certificate its
// connection presented. Over a connection pinned to the peer's key once
// it is known; until then (or fresh) over a new connection, not kept,
// whose certificate is noted (and its key, for pinning).
- (NSHTTPURLResponse *)send:(NSURLRequest *)request pinned:(NSString *)pinned fresh:(BOOL)fresh data:(NSData **)data
                  presented:(NSString **)presented error:(NSError **)error
{
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    curl_global_init(CURL_GLOBAL_DEFAULT);
  });
  // The key of the certificate pinned, once seen; until then a new
  // connection, its certificate compared.
  NSString *pin = nil;
  if (pinned && !fresh) {
    @synchronized (_keyPins) {
      pin = _keyPins[pinned];
    }
  }
  [_sending lock];
  if (!_curl) _curl = curl_easy_init();
  CURL *curl = _curl;
  // Its connections kept, its settings not.
  curl_easy_reset(curl);
  NSMutableData *body = [NSMutableData data];
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  char detail[CURL_ERROR_SIZE] = "";
  curl_easy_setopt(curl, CURLOPT_URL, request.URL.absoluteString.UTF8String);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, detail);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, (long)(request.timeoutInterval > 0 ? request.timeoutInterval : 60));
  curl_easy_setopt(curl, CURLOPT_SSLCERT, _identity.system.certificateURL.path.fileSystemRepresentation);
  curl_easy_setopt(curl, CURLOPT_SSLCERTTYPE, "PEM");
  curl_easy_setopt(curl, CURLOPT_SSLKEY, _identity.system.keyURL.path.fileSystemRepresentation);
  curl_easy_setopt(curl, CURLOPT_SSLKEYTYPE, "PEM");
  curl_easy_setopt(curl, CURLOPT_SSLVERSION, (long)CURL_SSLVERSION_TLSv1_2);
  // No authority vouches for a peer: its key is the one pinned, or the
  // certificate is noted for the trust to judge.
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
  curl_easy_setopt(curl, CURLOPT_SSL_SESSIONID_CACHE, 0L);
  if (pin) {
    curl_easy_setopt(curl, CURLOPT_PINNEDPUBLICKEY, pin.UTF8String);
  } else {
    curl_easy_setopt(curl, CURLOPT_FRESH_CONNECT, 1L);
    curl_easy_setopt(curl, CURLOPT_FORBID_REUSE, 1L);
    curl_easy_setopt(curl, CURLOPT_CERTINFO, 1L);
  }
  NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
  NSData *sent = request.HTTPBody;
  if ([method isEqualToString:@"GET"] && !sent.length) {
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
  } else if ([method isEqualToString:@"HEAD"]) {
    curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
  } else {
    if (![method isEqualToString:@"POST"]) curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.UTF8String);
    if (sent || [method isEqualToString:@"POST"]) {
      curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)sent.length);
      curl_easy_setopt(curl, CURLOPT_POSTFIELDS, sent.length ? sent.bytes : "");
    }
  }
  struct curl_slist *headers = curl_slist_append(NULL, "Expect:");
  for (NSString *name in request.allHTTPHeaderFields) {
    NSString *line = [NSString stringWithFormat:@"%@: %@", name, request.allHTTPHeaderFields[name]];
    headers = curl_slist_append(headers, line.UTF8String);
  }
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, ODSCurlBody);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, (__bridge void *)body);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, ODSCurlHeader);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, (__bridge void *)fields);
  CURLcode code = curl_easy_perform(curl);
  long status = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
  NSData *certificate = code == CURLE_OK && !pin ? ODSPresentedCertificate(curl) : nil;
  curl_slist_free_all(headers);
  [_sending unlock];
  if (code != CURLE_OK) {
    if (error) *error = ODSCurlError(code, detail);
    return nil;
  }
  NSString *thumbprint = certificate ? [ODataSyncPeerIdentity thumbprintOfCertificateData:certificate] : nil;
  if (thumbprint) {
    NSString *keyPin = ODSKeyPin(certificate);
    if (keyPin) {
      @synchronized (_keyPins) {
        _keyPins[thumbprint] = keyPin;
      }
    }
  }
  // Not the one expected: nothing of what it answered is taken.
  if (pinned && !pin && ![thumbprint isEqualToString:pinned]) {
    if (error) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorServerCertificateUntrusted
                                        userInfo:@{ NSLocalizedDescriptionKey: @"The peer presented another certificate" }];
    return nil;
  }
  if (presented) *presented = thumbprint;
  if (data) *data = body;
  if (error) *error = nil;
  return [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:fields];
}
@end
