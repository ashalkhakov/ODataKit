// ODataIncrementalStore — JWS signatures, by the platform's own crypto.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Private to HSAuthentication. Security.framework on Apple, GnuTLS
// (which gnustep-base links already) elsewhere: nothing here does the
// arithmetic itself, it only puts a JWK and a JWS signature in the shape
// each wants.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Whether signature is alg's signature of input by the public key jwk
// (RFC 7518: RS256/384/512, PS256/384/512, ES256/384/512). NO, with the
// reason, for a key alg cannot use: of another type or curve, an RSA key
// under 2048 bits, a private key's fields present or not, whatever else.
FOUNDATION_EXPORT BOOL HSVerifyJWS(NSString *alg, NSDictionary *jwk, NSData *input, NSData *signature, NSString *_Nullable *_Nullable reason);

// The algorithms HSVerifyJWS knows.
FOUNDATION_EXPORT NSSet<NSString *> *HSSignatureAlgorithms(void);

FOUNDATION_EXPORT NSData *HSSHA256(NSData *data);

FOUNDATION_EXPORT NSString *HSBase64URLEncode(NSData *data);

// RFC 4648 section 5, without padding; nil for anything else.
FOUNDATION_EXPORT NSData *_Nullable HSBase64URLDecode(NSString *text);

NS_ASSUME_NONNULL_END
