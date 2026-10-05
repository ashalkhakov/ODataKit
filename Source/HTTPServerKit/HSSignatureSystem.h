// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What JWS signatures need of the system (HSSignature): one implementation
// for each, in its own directory, which the build picks:
//
//   apple/   the Security framework (the Xcode project)
//   linux/   GnuTLS (the GNUmakefiles)
//
// Private to HSSignature, which checks a key's shape before it asks.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
  const char *family;  // RS, PS, ES
  int hash;            // 256, 384, 512
  const char *curve;   // ES only
  NSUInteger size;     // an ES coordinate's bytes
} HSAlgorithm;

// Whether signature is a's of input by the public key jwk (its shape
// checked already). NO, with the reason, otherwise.
FOUNDATION_EXPORT BOOL HSSystemVerify(HSAlgorithm a, NSDictionary *jwk, NSData *input, NSData *signature, NSString *_Nullable *_Nullable reason);
// input signed by the P-256 private key jwk (its d): r || s.
FOUNDATION_EXPORT NSData *_Nullable HSSystemSignES256(NSDictionary *jwk, NSData *input, NSError **error);
// A new P-256 key: its coordinates and its private scalar, 32 bytes each.
FOUNDATION_EXPORT BOOL HSSystemNewP256(NSData *_Nullable *_Nonnull x, NSData *_Nullable *_Nonnull y, NSData *_Nullable *_Nonnull d,
                                       NSError **error);

// HSSignature's, for the system's half.
FOUNDATION_EXPORT NSError *HSSigningError(NSString *what);
// A number as exactly size bytes, big-endian: padded with zeros, or its
// leading zeros taken off; nil when it does not fit.
FOUNDATION_EXPORT NSData *_Nullable HSFixedWidth(NSData *number, NSUInteger size);
// A JWK member's bytes (base64url).
FOUNDATION_EXPORT NSData *_Nullable HSMember(NSDictionary *jwk, NSString *name);
FOUNDATION_EXPORT NSData *HSWithoutLeadingZeros(NSData *number);

NS_ASSUME_NONNULL_END
