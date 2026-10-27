// ODataKit — requests on their way: exchanges, transports, HTTP responses.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What a client and a service share of HTTP: an exchange (a request, and
// once it is done its response, target-action), the transport that
// carries it (a service is one too), a response and its OData control
// information, and Core.Messages.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataHTTPResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSData *data;
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic, copy, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *etag;
// Header names are case-insensitive (RFC 9110), whatever case the
// transport kept them in.
- (nullable NSString *)valueForHeader:(NSString *)name;
// The JSON body, with control information spelled one way whatever the
// payload's OData-Version: a 4.01 payload may leave out the odata. prefix
// (JSON Format 4.01 section 4.5), so @etag, @nextLink and Orders@count
// become @odata.etag, @odata.nextLink and Orders@odata.count. A payload
// that says it is 4.0 is taken as it is; one that says nothing, as 4.01.
- (nullable id)JSONWithError:(NSError **)error;
@end

// Core.Messages (the Core vocabulary's MessageType): what a service says
// of a request it answered, alongside the answer: a price rounded, a
// field ignored. In a JSON body as the instance annotation
// @Org.OData.Core.V1.Messages (or @Core.Messages), of the whole response
// or of one entity in it.
@interface ODataMessage : NSObject
+ (instancetype)messageWithCode:(NSString *)code text:(NSString *)text severity:(NSString *)severity target:(nullable NSString *)target;
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *severity;  // success, info, warning, error
@property (nonatomic, copy, nullable) NSString *target;
@property (nonatomic, copy) NSArray<ODataMessage *> *details;
// The messages an object of a JSON body carries: nil for none.
+ (nullable NSArray<ODataMessage *> *)messagesInJSON:(nullable id)json;
- (NSDictionary *)JSONObject;
@end

/* ODataKit's own: exported where ODataKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef ODATAKIT_EXPORT
#define ODATAKIT_EXPORT FOUNDATION_EXPORT
#endif

ODATAKIT_EXPORT NSString * const ODataMessagesAnnotation;  // @"@Org.OData.Core.V1.Messages"

// The same, for JSON already parsed, from a payload of this OData-Version.
ODATAKIT_EXPORT id ODataNormalizedControlInformation(id json, NSString * _Nullable version);

// One request on its way, and once it is done, how it went. Whoever
// starts an exchange gives it a target and an action; -finish sends the
// action to the target, with the exchange as its argument, once:
//
//   - (void)exchangeDidFinish:(ODataExchange *)exchange;
//
// That is how both layers report: a transport fills in the HTTP response
// and data, or an error, and finishes; the client fills in the OData
// response (or change-set responses), or an OData error, and finishes.
@interface ODataExchange : NSObject
- (instancetype)initWithRequest:(NSURLRequest *)request target:(nullable id)target action:(nullable SEL)action NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSURLRequest *request;
@property (nonatomic, strong, nullable) id context;             // the starter's own, untouched
// Set by the transport.
@property (nonatomic, strong, nullable) NSURLResponse *URLResponse;
@property (nonatomic, copy, nullable) NSData *data;
// Set by the transport (a request that never got an answer) or the client.
@property (nonatomic, strong, nullable) NSError *error;
// Set by the client.
@property (nonatomic, strong, nullable) ODataHTTPResponse *response;
@property (nonatomic, copy, nullable) NSArray<ODataHTTPResponse *> *responses;  // a change set's, in order
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
// Sends the action to the target, from the calling thread, the first time
// it is called; later calls do nothing. The target is released after.
- (void)finish;
@end

// How requests reach a service. Send the exchange's request; when it is
// done - before returning, or later on any thread - set URLResponse and
// data, or error, and call -finish.
//
// The one rule: do not finish on the thread that started the exchange by
// waiting for that thread to come back. The store's callbacks are
// synchronous, so that thread is waiting for -finish, not running its run
// loop. NSURLSession finishes on its own queue, and a transport that
// answers from memory finishes before returning; both are fine.
@protocol ODataTransport <NSObject>
- (void)startExchange:(ODataExchange *)exchange;
@end

// The transport a client uses when it is given none: NSURLSession, where
// Foundation has it (Apple, and gnustep-base built with libcurl), else
// NSURLConnection on a thread of its own. For a transport that wraps the
// network (one that logs, say) to hand exchanges on to.
ODATAKIT_EXPORT id<ODataTransport> ODataDefaultTransport(void);

NS_ASSUME_NONNULL_END
