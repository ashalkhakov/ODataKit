// HSMessage — a request, its response, and the reply that carries one
// to the other.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What every stage and handler of HTTPServerKit works with, whatever
// listens on the socket: the listener makes the request, the handler at the
// end of the pipeline finishes the reply with a response, and the listener
// writes it.

#pragma once
#import <Foundation/Foundation.h>

@class HSPrincipal, HSRoute, HSRequest, HSResponse, OTSpan;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

/* HTTPServerKit's own: exported where HTTPServerKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef HTTPSERVERKIT_EXPORT
#define HTTPSERVERKIT_EXPORT FOUNDATION_EXPORT
#endif

// An error a request is answered with: its code is the HTTP status, its
// localizedDescription what the client is told (problem+json's detail).
HTTPSERVERKIT_EXPORT NSErrorDomain const HSErrorDomain;
HTTPSERVERKIT_EXPORT NSError *HSError(NSInteger status, NSString *message);
// In an error's userInfo: the problem's type, a URI (RFC 9457; default
// about:blank); and the OAuth scopes a 401 or 403 needs (NSArray), which
// the challenge names (RFC 6750).
HTTPSERVERKIT_EXPORT NSString * const HSErrorTypeKey;
HTTPSERVERKIT_EXPORT NSString * const HSErrorScopesKey;
// Another domain whose codes are HTTP statuses too (an API library's own:
// OData's), answered with that status and message rather than 500.
HTTPSERVERKIT_EXPORT void HSRegisterStatusErrorDomain(NSErrorDomain domain);

// How an API answers errors, in its own format: OData's {"error": ...}, an
// OpenAPI's problem+json with types of its own. A route's (HSRoute's
// errorFormatter, by default its handler, when it is one) answers every
// error of a request it takes, wherever in the pipeline it arose; without
// one, problem+json.
@protocol HSErrorFormatting <NSObject>
- (HSResponse *)responseForError:(NSError *)error request:(HSRequest *)request;
@end

@interface HSRequest : NSObject
// URL: the request target as the client sent it (path and query, still
// escaped), on the host the listener answers.
- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)URL
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          body:(nullable NSData *)body;
// A body that waits in a file (a large one, which the listener wrote to a
// temporary file as it came): body maps it when asked. owner is kept as
// long as the request is (the listener's, which removes the file after).
- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)URL
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                   bodyFileURL:(nullable NSURL *)bodyFileURL owner:(nullable id)owner NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *method;  // upper case
@property (nonatomic, readonly, copy) NSURL *URL;
// The request target as the client sent it: the path and query, escaped.
@property (nonatomic, readonly, copy) NSString *target;
// The path, unescaped; the query's items, unescaped (the last of a repeated
// name).
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *query;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *headers;
// Header names are case-insensitive.
- (nullable NSString *)valueForHeader:(NSString *)name;
@property (nonatomic, readonly, copy, nullable) NSData *body;
// Where the body waits, when it is a file; nil when it came in memory.
@property (nonatomic, readonly, copy, nullable) NSURL *bodyFileURL;
// The body as JSON, or nil when it is none.
@property (nonatomic, readonly, nullable) id JSONBody;
// The client's address, as the listener saw it (the proxy's, behind one).
@property (nonatomic, copy, nullable) NSString *remoteAddress;

// Who is asking, once the authentication stage has asked (authenticated):
// nil for no one.
@property (nonatomic, strong, nullable) HSPrincipal *principal;
@property (nonatomic, getter=isAuthenticated) BOOL authenticated;
// What the route matched: /orders/:id gives id; a trailing * gives "*".
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *pathParameters;
// The route that matched, once the router has found it: its pattern is what
// metrics and logs name the request by (/orders/:id, not each order's path).
@property (nonatomic, strong, nullable) HSRoute *route;
// What was asked, by a name of few values, as the handler that answers
// knows it: an OpenAPI operationId, an OData entity set ($metadata,
// $batch). Metrics count by it, and logs say it, beside the route.
@property (nonatomic, copy, nullable) NSString *operation;
// This server's span of the request (OTelKit), once HSTraceContextStage
// has begun it: a handler's own spans go under its context, and it may add
// attributes. It records nothing when tracing is off, but still carries
// the trace on.
@property (nonatomic, strong, nullable) OTSpan *span;
// The stages' and handlers' own, for the length of the request.
@property (nonatomic, readonly, strong) NSMutableDictionary *userInfo;

// The same request for Foundation's URL loading types (an authenticator,
// an ODataService): on the given origin when there is one (scheme, host,
// port), as the public URL a proxy forwards from.
- (NSURLRequest *)URLRequestOnOrigin:(nullable NSURL *)origin;
@end

// A body made as it is sent: asked for its next piece, on a queue of the
// listener's, one call at a time, until it gives an empty one (the end) or
// nil (an error: the connection is closed, the status having been sent).
@protocol HSResponseStream <NSObject>
- (nullable NSData *)nextChunk:(NSError **)error;
@end

@interface HSResponse : NSObject
+ (instancetype)responseWithStatus:(NSInteger)status;
+ (instancetype)responseWithStatus:(NSInteger)status body:(nullable NSData *)body contentType:(nullable NSString *)contentType;
+ (instancetype)responseWithJSON:(id)json status:(NSInteger)status;
+ (instancetype)responseWithText:(NSString *)text status:(NSInteger)status;
// A file, sent from disk as it is read, not loaded first.
+ (instancetype)responseWithFile:(NSURL *)file contentType:(nullable NSString *)contentType status:(NSInteger)status;
// A stream, sent chunked as it gives its pieces.
+ (instancetype)responseWithStream:(id<HSResponseStream>)stream contentType:(nullable NSString *)contentType status:(NSInteger)status;
// An error as problem details (RFC 9457, application/problem+json): type,
// title (the status's reason), status, detail. Its status is the error's
// code for HSErrorDomain or a domain registered as one, 500 for any other
// (whose own words are logged, not shown). A 401 or 403 that names the
// scopes it needs (HSErrorScopesKey) carries the challenge saying so.
+ (instancetype)responseWithError:(NSError *)error;
// The error as the request's route answers errors (HSErrorFormatting), or
// as above.
+ (instancetype)responseWithError:(NSError *)error request:(nullable HSRequest *)request;
// The status an error answers with, as above.
+ (NSInteger)statusOfError:(nullable NSError *)error;
// The WWW-Authenticate challenge for an error's scopes (a 401, or a 403's
// insufficient_scope), or nil.
+ (nullable NSString *)challengeForError:(NSError *)error;

@property (nonatomic) NSInteger status;
// The body: in memory, or a file, or a stream (one of the three).
@property (nonatomic, copy, nullable) NSData *body;
@property (nonatomic, copy, nullable) NSURL *bodyFileURL;
@property (nonatomic, strong, nullable) id<HSResponseStream> bodyStream;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *headers;
// Header names are case-insensitive; nil removes one.
- (nullable NSString *)valueForHeader:(NSString *)name;
- (void)setValue:(nullable NSString *)value forHeader:(NSString *)name;
@end

// One request's answer: finished once, with a response, now or later, from
// any thread; a second answer is ignored. Whoever starts the request (the
// listener, a stage passing it on, a test) makes the reply, and is sent
// the action with it once it is finished.
@interface HSReply : NSObject
- (instancetype)initWithTarget:(id)target action:(SEL)action NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)finishWithResponse:(HSResponse *)response;
// The same with +[HSResponse responseWithError:request:].
- (void)failWithError:(NSError *)error;
// The request it answers, for the format of its errors.
@property (nonatomic, strong, nullable) HSRequest *request;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
@property (nonatomic, readonly, strong, nullable) HSResponse *response;
// Its starter's, to find its way back with.
@property (nonatomic, strong, nullable) id context;
@end

NS_ASSUME_NONNULL_END
