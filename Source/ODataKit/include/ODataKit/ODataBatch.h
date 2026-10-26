// ODataIncrementalStore — multipart $batch (Part 1 section 11.7).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OData 4.0's batch format: a multipart/mixed body whose parts are HTTP
// messages, with a nested multipart/mixed change set for requests that
// succeed or fail together. The JSON batch format is 4.01 only.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

// One HTTP message out of a batch: a request (method, URL) or a response
// (status), its headers, its body, and its Content-ID if it had one.
@interface ODataBatchPart : NSObject
@property (nonatomic, copy, nullable) NSString *method;
@property (nonatomic, copy, nullable) NSString *URLString;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSData *body;
@property (nonatomic, copy, nullable) NSString *contentID;
// The boundary of the change set the part came in; nil for a part of the
// batch itself.
@property (nonatomic, copy, nullable) NSString *changeSet;
// Case-insensitive, as header names are.
- (nullable NSString *)valueForHeader:(NSString *)name;
@end

/* ODataKit's own: exported where ODataKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef ODATAKIT_EXPORT
#define ODATAKIT_EXPORT FOUNDATION_EXPORT
#endif

// A batch holding one change set of these requests, each with an absolute
// URL (services such as TripPin reject relative ones in a batch). The
// Content-IDs are 1, 2, ... in order.
ODATAKIT_EXPORT NSData *ODataChangeSetBody(NSArray<NSURLRequest *> *requests, NSString *batchBoundary);

// The same change set in OData 4.01's JSON batch format (JSON Format
// section 19): {"requests": [...]}, one atomicity group, ids 1, 2, ...,
// absolute URLs, JSON bodies as JSON.
ODATAKIT_EXPORT NSData *ODataJSONBatchBody(NSArray<NSURLRequest *> *requests);

// The responses of a JSON batch response, in order, as parts: status,
// headers, the body as data (JSON re-serialised), and the request's id as
// the Content-ID. nil if it is not one.
ODATAKIT_EXPORT NSArray<ODataBatchPart *> * _Nullable ODataJSONBatchParts(NSData *body);

// The boundary parameter of a multipart Content-Type, or nil.
ODATAKIT_EXPORT NSString * _Nullable ODataMultipartBoundary(NSString *contentType);

// One application/http message (a request or a response), as a batch
// part or a status monitor's answer carries it; nil if it is not one.
ODATAKIT_EXPORT ODataBatchPart * _Nullable ODataHTTPMessage(NSData *data);

// A response as an application/http message: status line, headers (not
// Content-Length), a blank line, the body.
ODATAKIT_EXPORT NSData *ODataHTTPResponseMessage(NSInteger status, NSDictionary<NSString *, NSString *> *headers, NSData * _Nullable body);
ODATAKIT_EXPORT NSString *ODataHTTPReasonPhrase(NSInteger status);

// The HTTP messages in a multipart/mixed body, in order, with any nested
// change set flattened into its members. Requests and responses both.
ODATAKIT_EXPORT NSArray<ODataBatchPart *> * _Nullable ODataBatchParts(NSData *body, NSString *boundary);

NS_ASSUME_NONNULL_END
