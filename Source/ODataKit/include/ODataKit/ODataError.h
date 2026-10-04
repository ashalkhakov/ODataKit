// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const ODataIncrementalStoreErrorDomain;

typedef NS_ENUM(NSInteger, ODataIncrementalStoreErrorCode) {
  ODataIncrementalStoreErrorMissingServiceURL = 1,
  ODataIncrementalStoreErrorUnsupportedRequest = 2,
  ODataIncrementalStoreErrorUnsupportedPredicate = 3,
  ODataIncrementalStoreErrorUnsupportedExpression = 4,
  ODataIncrementalStoreErrorDecoding = 5,
  ODataIncrementalStoreErrorMissingEntitySet = 6,
  ODataIncrementalStoreErrorMissingKey = 7,
  ODataIncrementalStoreErrorTransport = 8,
  ODataIncrementalStoreErrorModelMismatch = 9,
  ODataIncrementalStoreErrorSyntax = 10,           // OData URL syntax that does not parse (ODataExpression.h)
  ODataIncrementalStoreErrorNotAllowedByService = 11,  // what the service's Capabilities say it does not do
  ODataIncrementalStoreErrorNoStream = 12,         // an object with no such stream, or a stream with nothing in it
  ODataIncrementalStoreErrorInvalidName = 13,      // a name a builder writes as it is, not one OData allows there (ODataExpression.h)
  ODataIncrementalStoreErrorHTTP = 1000,
  ODataIncrementalStoreErrorOptimisticLocking = 1570
};

FOUNDATION_EXPORT NSError *OISError(ODataIncrementalStoreErrorCode code, NSString *message);

// What a service said about a failed request (JSON Format section 21,
// Part 1 section 9.4), in the userInfo of an ODataIncrementalStoreErrorHTTP
// + status error. Its message is the error's localizedDescription.
FOUNDATION_EXPORT NSString * const ODataErrorHTTPStatusKey;    // NSNumber
FOUNDATION_EXPORT NSString * const ODataErrorCodeKey;          // the service's error code
FOUNDATION_EXPORT NSString * const ODataErrorTargetKey;        // the property or entity it concerns
FOUNDATION_EXPORT NSString * const ODataErrorDetailsKey;       // NSArray of { code, message, target }
FOUNDATION_EXPORT NSString * const ODataErrorResponseBodyKey;  // the body, as text
// The OAuth scopes a 401 or 403 says the request needs (NSArray): those of
// the WWW-Authenticate challenge's scope (RFC 6750 section 3), as a client
// reads them back; in a service's error, answered with that challenge,
// error="insufficient_scope" for a 403. The message says whether one of
// them is enough or all are needed.
FOUNDATION_EXPORT NSString * const ODataErrorScopesKey;

// A service's error: the code is the HTTP status to answer with, and the
// userInfo carries the message and, optionally, ODataErrorCodeKey,
// ODataErrorTargetKey and ODataErrorDetailsKey, as the client reads them
// back. ODataService answers any other error a handler gives it with 500.
FOUNDATION_EXPORT NSErrorDomain const ODataServiceErrorDomain;
FOUNDATION_EXPORT NSError *ODataServiceError(NSInteger status, NSString *message);
FOUNDATION_EXPORT NSError *ODataServiceErrorWithTarget(NSInteger status, NSString *message, NSString * _Nullable target);

FOUNDATION_EXPORT NSError *OISHTTPError(ODataIncrementalStoreErrorCode code, NSInteger status, NSURL * _Nullable url, NSData * _Nullable body);
// The error of a 401 or 403 with what its WWW-Authenticate challenge says:
// the scopes it names (ODataErrorScopesKey), and for insufficient_scope a
// recovery suggestion naming them. Any other error, or no challenge: the
// error as it is.
FOUNDATION_EXPORT NSError *OISHTTPErrorWithChallenge(NSError *error, NSString * _Nullable challenge);

NS_ASSUME_NONNULL_END
