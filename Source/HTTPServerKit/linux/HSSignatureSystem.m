// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// JWS signatures by GnuTLS (which gnustep-base links already).

#import "../HSSignature.h"
#import "../HSSignatureSystem.h"
#include <gnutls/gnutls.h>
#include <gnutls/abstract.h>
#include <gnutls/crypto.h>


static gnutls_datum_t HSDatum(NSData *data)
{
  return (gnutls_datum_t){ (unsigned char *)data.bytes, (unsigned int)data.length };
}

BOOL HSSystemVerify(HSAlgorithm a, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
{
  gnutls_pubkey_t key;
  if (gnutls_pubkey_init(&key) < 0) {
    if (reason) *reason = @"no key";
    return NO;
  }
  int loaded;
  gnutls_sign_algorithm_t algorithm;
  NSData *checked = signature;
  gnutls_datum_t der = { NULL, 0 };
  if (a.family[0] == 'E') {
    gnutls_ecc_curve_t curve = a.hash == 256 ? GNUTLS_ECC_CURVE_SECP256R1 : a.hash == 384 ? GNUTLS_ECC_CURVE_SECP384R1 : GNUTLS_ECC_CURVE_SECP521R1;
    NSData *x = HSMember(jwk, @"x"), *y = HSMember(jwk, @"y");
    gnutls_datum_t xd = HSDatum(x), yd = HSDatum(y);
    loaded = gnutls_pubkey_import_ecc_raw(key, curve, &xd, &yd);
    algorithm = a.hash == 256 ? GNUTLS_SIGN_ECDSA_SHA256 : a.hash == 384 ? GNUTLS_SIGN_ECDSA_SHA384 : GNUTLS_SIGN_ECDSA_SHA512;
    // JWS has r || s; GnuTLS takes the DER of X9.62.
    NSData *r = [signature subdataWithRange:NSMakeRange(0, a.size)];
    NSData *s = [signature subdataWithRange:NSMakeRange(a.size, a.size)];
    gnutls_datum_t rd = HSDatum(r), sd = HSDatum(s);
    if (loaded >= 0 && gnutls_encode_rs_value(&der, &rd, &sd) >= 0) {
      checked = [NSData dataWithBytes:der.data length:der.size];
    } else {
      loaded = -1;
    }
  } else {
    NSData *n = HSMember(jwk, @"n"), *e = HSMember(jwk, @"e");
    gnutls_datum_t nd = HSDatum(n), ed = HSDatum(e);
    loaded = gnutls_pubkey_import_rsa_raw(key, &nd, &ed);
    if (a.family[0] == 'R') {
      algorithm = a.hash == 256 ? GNUTLS_SIGN_RSA_SHA256 : a.hash == 384 ? GNUTLS_SIGN_RSA_SHA384 : GNUTLS_SIGN_RSA_SHA512;
    } else {
      algorithm = a.hash == 256 ? GNUTLS_SIGN_RSA_PSS_RSAE_SHA256 : a.hash == 384 ? GNUTLS_SIGN_RSA_PSS_RSAE_SHA384 : GNUTLS_SIGN_RSA_PSS_RSAE_SHA512;
    }
  }
  if (der.data) gnutls_free(der.data);
  if (loaded < 0) {
    gnutls_pubkey_deinit(key);
    if (reason) *reason = @"the key does not load";
    return NO;
  }
  gnutls_datum_t data = HSDatum(input), sig = HSDatum(checked);
  int verified = gnutls_pubkey_verify_data2(key, algorithm, 0, &data, &sig);
  gnutls_pubkey_deinit(key);
  if (verified < 0 && reason) *reason = @"the signature does not verify";
  return verified >= 0;
}

NSData *HSSystemSignES256(NSDictionary *jwk, NSData *input, NSError **error)
{
  gnutls_privkey_t key;
  if (gnutls_privkey_init(&key) < 0) {
    if (error) *error = HSSigningError(@"no key");
    return nil;
  }
  NSData *x = HSMember(jwk, @"x"), *y = HSMember(jwk, @"y"), *d = HSMember(jwk, @"d");
  gnutls_datum_t xd = HSDatum(x), yd = HSDatum(y), kd = HSDatum(d);
  if (gnutls_privkey_import_ecc_raw(key, GNUTLS_ECC_CURVE_SECP256R1, &xd, &yd, &kd) < 0) {
    gnutls_privkey_deinit(key);
    if (error) *error = HSSigningError(@"the signing key does not load");
    return nil;
  }
  gnutls_datum_t data = HSDatum(input), der = { NULL, 0 }, r = { NULL, 0 }, s = { NULL, 0 };
  int signedOK = gnutls_privkey_sign_data(key, GNUTLS_DIG_SHA256, 0, &data, &der);
  gnutls_privkey_deinit(key);
  NSData *raw = nil;
  if (signedOK >= 0 && gnutls_decode_rs_value(&der, &r, &s) >= 0) {
    NSData *rr = HSFixedWidth([NSData dataWithBytes:r.data length:r.size], 32);
    NSData *ss = HSFixedWidth([NSData dataWithBytes:s.data length:s.size], 32);
    if (rr && ss) {
      NSMutableData *both = [NSMutableData dataWithData:rr];
      [both appendData:ss];
      raw = both;
    }
  }
  if (der.data) gnutls_free(der.data);
  if (r.data) gnutls_free(r.data);
  if (s.data) gnutls_free(s.data);
  if (!raw && error) *error = HSSigningError(@"the signing failed");
  return raw;
}

BOOL HSSystemNewP256(NSData **x, NSData **y, NSData **d, NSError **error)
{
  gnutls_privkey_t key;
  if (gnutls_privkey_init(&key) < 0 ||
      gnutls_privkey_generate(key, GNUTLS_PK_ECDSA, GNUTLS_CURVE_TO_BITS(GNUTLS_ECC_CURVE_SECP256R1), 0) < 0) {
    if (error) *error = HSSigningError(@"no key could be made");
    return NO;
  }
  gnutls_ecc_curve_t curve;
  gnutls_datum_t xd = { NULL, 0 }, yd = { NULL, 0 }, kd = { NULL, 0 };
  int exported = gnutls_privkey_export_ecc_raw(key, &curve, &xd, &yd, &kd);
  gnutls_privkey_deinit(key);
  if (exported < 0) {
    if (error) *error = HSSigningError(@"the key could not be read");
    return NO;
  }
  *x = HSFixedWidth([NSData dataWithBytes:xd.data length:xd.size], 32);
  *y = HSFixedWidth([NSData dataWithBytes:yd.data length:yd.size], 32);
  *d = HSFixedWidth([NSData dataWithBytes:kd.data length:kd.size], 32);
  gnutls_free(xd.data);
  gnutls_free(yd.data);
  gnutls_free(kd.data);
  return *x && *y && *d;
}

NSData *HSSHA256(NSData *data)
{
  unsigned char digest[32];
  gnutls_hash_fast(GNUTLS_DIG_SHA256, data.bytes, data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof digest];
}

