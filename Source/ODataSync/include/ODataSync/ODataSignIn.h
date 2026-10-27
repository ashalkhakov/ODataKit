// ODataSignIn — signing in to a service as its $metadata says to.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A service says how to sign in with OData's Authorization vocabulary (an
// ODataService does, from its authenticator; with AllowAnonymousMetadata
// its $metadata is readable before signing in): with nothing, with a user
// and password (Http basic), or with OpenID Connect (Keycloak, Authentik,
// ...). For OpenID Connect this signs in by the OAuth device flow (RFC
// 8628, with PKCE): the app shows a short code and a page, the user signs
// in there in any browser, on any device, and the app is given tokens. The
// same on macOS, iOS and GNUstep, with no browser of the app's own.
//
// Tokens are kept in an ODataSecretStore (the Keychain; on GNUstep a file
// only the user can read), or any ODataSecretStoring (an app that kept its
// tokens elsewhere before keeps its own store, and nobody is signed out:
// by account, the service root; "kind", "access", "refresh", ...), and the
// access token is refreshed when it runs out. An ODataSignIn is a credential provider: an ODataConfiguration's
// (-configuration), or a store's (ODataIncrementalStoreCredentialProviderOption).
//
// The identity provider's client (clientID): a public client with the
// device flow on (Keycloak: OAuth 2.0 Device Authorization Grant), whose
// tokens name the service in their audience.

#pragma once
#import <Foundation/Foundation.h>
#import <ODataIncrementalStore/ODataConfiguration.h>

@class ODataSignIn;

NS_ASSUME_NONNULL_BEGIN

// Where a sign-in's tokens (or password) are kept: by account, the
// service's address.
@protocol ODataSecretStoring <NSObject>
- (nullable NSDictionary<NSString *, id> *)secretsForAccount:(NSString *)account;
- (BOOL)setSecrets:(nullable NSDictionary<NSString *, id> *)secrets forAccount:(NSString *)account;
@end

// The system's: the Keychain (a generic password of the service name); on
// GNUstep, a property list only the user can read (0600), in Application
// Support/<service name>.
@interface ODataSecretStore : NSObject <ODataSecretStoring>
- (instancetype)initWithServiceName:(NSString *)serviceName NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *serviceName;
@end

typedef NS_ENUM(NSInteger, ODataSignInKind) {
  ODataSignInUnknown,    // not asked yet
  ODataSignInNone,       // the service asks for no one
  ODataSignInPassword,   // a user and password (Http basic)
  ODataSignInOpenID,     // OpenID Connect: the device flow
};

// Told on the main thread.
@protocol ODataSignInDelegate <NSObject>
@optional
// What the service asks for, learnt (-learn).
- (void)signInDidLearn:(ODataSignIn *)signIn;
// The user to open page (completePage: with the code in it) and enter
// code. Until -signInDidFinish:, -signIn:didFail:, or -cancel.
- (void)signIn:(ODataSignIn *)signIn showCode:(NSString *)code page:(NSURL *)page completePage:(nullable NSURL *)completePage;
- (void)signInDidFinish:(ODataSignIn *)signIn;
- (void)signIn:(ODataSignIn *)signIn didFail:(NSError *)error;
@end

@interface ODataSignIn : NSObject <ODataCredentialProviding>
- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot secrets:(id<ODataSecretStoring>)secrets NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
// The identity provider's client the device flow signs in with: needed for
// OpenID Connect (-begin fails without one).
@property (nonatomic, copy, nullable) NSString *clientID;
@property (nonatomic, weak, nullable) id<ODataSignInDelegate> delegate;

// What the service asks for, from its $metadata; the delegate told.
- (void)learn;
@property (nonatomic, readonly) ODataSignInKind kind;
@property (nonatomic, readonly, copy, nullable) NSURL *issuer;

// OpenID Connect: the device flow begun (learnt first, when not yet); a
// service that asks for no one: finished at once.
- (void)begin;
- (void)signInWithUser:(NSString *)user password:(NSString *)password;
- (void)cancel;
// The tokens (or password) forgotten.
- (void)signOut;
@property (nonatomic, readonly, getter=isSignedIn) BOOL signedIn;
// Who: preferred_username (or e-mail, or the subject), from the tokens.
@property (nonatomic, readonly, copy, nullable) NSString *userName;

// A configuration for the service, its credentials this sign-in's: asked
// for once the service refuses a request (the reads of a store or a sync
// need not wait for $metadata, which a service may keep behind the
// sign-in).
- (ODataConfiguration *)configuration;

// How it asks: a test overrides it, to answer as a service and a provider
// would. On any thread; done once.
- (void)send:(NSURLRequest *)request done:(void (^)(NSData *_Nullable data, NSHTTPURLResponse *_Nullable response, NSError *_Nullable error))done;
@end

/* ODataSync's own: exported where ODataSync is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef ODATASYNC_EXPORT
#define ODATASYNC_EXPORT FOUNDATION_EXPORT
#endif

ODATASYNC_EXPORT NSString * const ODataSignInErrorDomain;

// PKCE's S256 challenge of a verifier (RFC 7636): sent with the device
// flow, which some providers ask for (Keycloak, with PKCE set on the client).
ODATASYNC_EXPORT NSString *ODataSignInChallengeOfVerifier(NSString *verifier);

NS_ASSUME_NONNULL_END
