// HSAuthentication — who is asking a server.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A server signs no one in: it is a relying party. An identity provider
// (OIDC, with passwords, passkeys or FIDO2 keys as it likes) signs the user
// in, and something the server trusts tells it who that is. Its
// authenticator hears it for each request (HSAuthenticationStage, once for
// every route), and the request carries the principal it found to every
// handler (request.principal): a route can require one, or OAuth scopes,
// and an API's handlers scope what they answer by it.
//
// HSTrustedHeaderAuthenticator takes the caller from headers that a
// reverse proxy sets once it has checked them with the provider
// (oauth2-proxy, Authelia, Caddy's forward_auth, nginx's auth_request).
// Anyone who can reach the service can send those headers too, so it is
// for a server that only the proxy can reach (HSServer listens on
// loopback by default), and the proxy has to replace the headers, never
// pass on a client's; a secret header the proxy adds makes sure of the
// first.
//
// Without such a proxy, a client sends the access token the provider gave
// it (Authorization: Bearer ...), and the server checks it: by its
// signature, with the provider's published keys (HSJWTAuthenticator,
// for a token that is a JWT), or by asking the provider
// (HSTokenIntrospectionAuthenticator, for any token). Anything else is
// an HSAuthenticator of the application's own.
//
// An API that batches requests (OData's $batch) authenticates the batch
// once, as a whole: its requests are the batch's principal's, whatever
// headers they carry inside it.

#pragma once
#import <Foundation/Foundation.h>
#import "HSMessage.h"

@class HSMetrics;

NS_ASSUME_NONNULL_BEGIN

// Why a request was refused, in a word, for metrics
// (http_auth_failures_total) and logs: in a refusal's userInfo, and the
// authentication stage puts it in the request's. HTTPServerKit's
// authenticators say malformed, algorithm, token_type, unknown_key,
// signature, issuer, audience, no_expiry, expired, not_yet_valid,
// no_subject, insufficient_scope, inactive, proxy_secret,
// provider_unavailable, timeout. An authenticator of one's own may say its
// own (a few, never a token or a name).
FOUNDATION_EXPORT NSString * const HSAuthenticationFailureKey;

// Who a request is from: the provider's subject (OIDC's sub, a user name),
// and what else is known of them.
@interface HSPrincipal : NSObject
- (instancetype)initWithSubject:(NSString *)subject claims:(nullable NSDictionary<NSString *, id> *)claims NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *subject;
// email, preferred_username, groups (an array), ... as the authenticator
// found them.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *claims;
// What the caller may do, as OAuth has it: the scope claim (text, space
// separated) or scp (an array). Empty when there is neither.
@property (nonatomic, readonly, copy) NSSet<NSString *> *scopes;
@end

// An authenticator's answer about one request: who sent it, or why they
// are refused. Answered once, now or later, from any thread; whoever asks
// is sent the action with it then.
@interface HSAuthenticationReply : NSObject
- (instancetype)initWithTarget:(id)target action:(SEL)action NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// nil: the request names no one (whether that is let in is the caller's to
// say: a route's, an API's).
- (void)finishWithPrincipal:(nullable HSPrincipal *)principal;
// A refusal: an HSError, 401 or 403.
- (void)failWithError:(NSError *)error;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
@property (nonatomic, readonly, strong, nullable) HSPrincipal *principal;
@property (nonatomic, readonly, strong, nullable) NSError *error;
// How long the asker waits: then it is failed with 504. 0, the default:
// as long as it takes.
@property (nonatomic) NSTimeInterval timeout;
// The asker's, to find its way back with.
@property (nonatomic, strong, nullable) id context;
@end

@protocol HSAuthenticator <NSObject>
// Who sent the request: finish the reply with an HSPrincipal, or with nil
// when it names no one; fail it with an HSError to refuse it (401, or 403
// with HSErrorScopesKey for scopes it lacks). Now, or later.
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply;
@optional
// The WWW-Authenticate header of a 401, for the request it refused.
// Default: Bearer.
- (NSString *)challengeForRequest:(HSRequest *)request;
// How a client signs in, for an API's description of itself: a record as
// OData's Authorization vocabulary has it ({"@type":
// "Org.OData.Authorization.V1.OpenIDConnect", "Name": ..., "IssuerUrl":
// ...}), which an OpenAPI security scheme can be made from too.
- (nullable NSDictionary<NSString *, id> *)authorizationDescription;
@end

// HTTP an authenticator asks of someone else: an identity provider's keys,
// a token's introspection. A fetch is started, and finished by the fetcher
// with what came (or the error), which sends its target the action, on any
// thread. Tests hand an authenticator a fetcher of their own.
@interface HSFetch : NSObject
- (instancetype)initWithRequest:(NSURLRequest *)request target:(id)target action:(SEL)action NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSURLRequest *request;
@property (nonatomic, strong, nullable) NSURLResponse *response;
@property (nonatomic, copy, nullable) NSData *data;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, strong, nullable) id context;
- (void)finish;
@end

@protocol HSFetching <NSObject>
- (void)startFetch:(HSFetch *)fetch;
@end

// NSURLSession where Foundation has it; on a gnustep-base without it,
// NSURLConnection on a thread of its own.
FOUNDATION_EXPORT id<HSFetching> HSDefaultFetcher(void);

@interface HSTrustedHeaderAuthenticator : NSObject <HSAuthenticator>
// The caller's subject from this header (X-Forwarded-User, Remote-User).
- (instancetype)initWithSubjectHeader:(NSString *)header NS_DESIGNATED_INITIALIZER;
// X-Forwarded-User, as oauth2-proxy sends it.
- (instancetype)init;
@property (nonatomic, readonly, copy) NSString *subjectHeader;
// Claims from other headers, claim name to header. Default: email from
// X-Forwarded-Email, preferred_username from
// X-Forwarded-Preferred-Username, groups from X-Forwarded-Groups.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *claimHeaders;
// The claims whose header is a comma-separated list. Default: groups.
@property (nonatomic, copy) NSSet<NSString *> *listClaims;
// A header the proxy adds with a secret only it and the service know: a
// request without it did not come through the proxy, and is answered 401.
// nil (the default): none.
@property (nonatomic, copy, nullable) NSString *secretHeader;
@property (nonatomic, copy, nullable) NSString *secret;
@end

// An access token that is a JWT (RFC 9068), checked as RFC 8725 has it: its
// algorithm one of `algorithms` (never none, never HMAC, whatever the token
// says), its signature by one of the issuer's keys (never one the token
// names or carries), and then its claims: iss the issuer, aud including the
// audience, exp not past and nbf not ahead (within `leeway`), a sub (the
// principal's subject; every claim goes into its claims), and the scopes
// `requiredScopes` asks for (403 otherwise). A token typed other than JWT
// or at+jwt (an ID token, say) is refused. A request without a token names
// no one; one with a token that fails is answered 401 with
// WWW-Authenticate: Bearer error="invalid_token".
//
// The keys: `keySet` when given, or fetched from keySetURL, or from the
// jwks_uri of the issuer's discovery document
// (issuer/.well-known/openid-configuration, whose issuer must be the
// issuer), and fetched again after keySetLifetime, or when a token names a
// key they lack (a rotation), at most once a keySetRefetchInterval.
// Requests wait for a fetch (503 if it fails).
// Tokens of one's own: for an application that issues them (ES256, a P-256
// key as a JWK, its private d with it), which an HSJWTAuthenticator given
// the public key (keySet) then checks.
//
// A new P-256 key, as a JWK with its d, alg ES256, use sig, and kid its
// RFC 7638 thumbprint. Keep it secret; give out HSPublicKey of it.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable HSGenerateSigningKey(NSError *_Nullable *_Nullable error);
// The public part of a key (no d), for a JWK Set.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *HSPublicKey(NSDictionary<NSString *, id> *jwk);
// claims signed with the key (ES256), compact: its header names the key
// (kid) and the type (JWT).
FOUNDATION_EXPORT NSString *_Nullable HSSignJWT(NSDictionary<NSString *, id> *claims, NSDictionary<NSString *, id> *jwk,
                                                NSError *_Nullable *_Nullable error);

@interface HSJWTAuthenticator : NSObject <HSAuthenticator>
// issuer: exactly as the tokens' iss has it. audience: this service's
// name at the provider; nil takes any audience, which only suits a
// provider that issues tokens for nothing else.
- (instancetype)initWithIssuer:(NSString *)issuer audience:(nullable NSString *)audience NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *issuer;
@property (nonatomic, readonly, copy, nullable) NSString *audience;
@property (nonatomic, copy, nullable) NSURL *keySetURL;
// A JWK Set ({"keys": [...]}), used as it is and never fetched.
@property (nonatomic, copy, nullable) NSDictionary *keySet;
// Default: RS256, RS384, RS512, PS256, PS384, PS512, ES256, ES384, ES512.
@property (nonatomic, copy) NSSet<NSString *> *algorithms;
// Scopes every token needs, from its scope (space-separated) or scp.
@property (nonatomic, copy, nullable) NSSet<NSString *> *requiredScopes;
// Clock skew allowed for exp and nbf. Default: 60 seconds.
@property (nonatomic) NSTimeInterval leeway;
// How long fetched keys are used before they are fetched again. Default:
// an hour.
@property (nonatomic) NSTimeInterval keySetLifetime;
// How soon keys are fetched again for a token whose key they lack, so
// tokens with made-up key IDs cannot make the service fetch all the time.
// Default: 60 seconds.
@property (nonatomic) NSTimeInterval keySetRefetchInterval;
// How it fetches. Default: HSDefaultFetcher().
@property (nonatomic, strong) id<HSFetching> fetcher;
// Where its fetches are counted and timed
// (http_auth_provider_requests_total and
// http_auth_provider_request_duration_seconds, by endpoint: discovery,
// keys), when set; the application's. Each fetch is a client span too,
// under the request that set it off.
@property (nonatomic, strong, nullable) HSMetrics *metrics;
@end

// Any access token, opaque or not, checked by asking the provider (RFC
// 7662): it is posted to the introspection endpoint with the service's own
// client credentials, and the provider says whether it is active, and
// whose. The answer is kept for cacheLifetime (never past the token's exp),
// by the token's SHA-256, so a client's next request does not ask again; a
// token revoked in that time is taken until then. The principal is sub (or
// username), with every member of the answer as its claims; iss, aud and
// scopes are checked as for a JWT when set. An endpoint that does not
// answer is a 503.
@interface HSTokenIntrospectionAuthenticator : NSObject <HSAuthenticator>
- (instancetype)initWithEndpoint:(NSURL *)endpoint clientID:(NSString *)clientID clientSecret:(NSString *)clientSecret NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *endpoint;
@property (nonatomic, copy, nullable) NSString *issuer;
@property (nonatomic, copy, nullable) NSString *audience;
@property (nonatomic, copy, nullable) NSSet<NSString *> *requiredScopes;
// Default: 60 seconds. 0: every request asks.
@property (nonatomic) NSTimeInterval cacheLifetime;
@property (nonatomic, strong) id<HSFetching> fetcher;
// As HSJWTAuthenticator's: endpoint introspection.
@property (nonatomic, strong, nullable) HSMetrics *metrics;
@end

NS_ASSUME_NONNULL_END
