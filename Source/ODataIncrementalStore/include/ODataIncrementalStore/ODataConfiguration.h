// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <ODataKit/OISRuntime.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataIncrementalStoreAccessTokenOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreUsernameOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStorePasswordOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreTimeoutOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStorePostOnObtainPermanentIDsOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreTransportOption;
// Posted by the store, on the thread of the fetch or save, when a response
// carries Core.Messages: ODataMessagesKey holds the ODataMessages,
// ODataMessagesURLKey the request's URL, and ODataMessagesObjectIDKey the
// object they are about, when they are about one (a POST's, a PATCH's, a
// fetched row's own).
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreDidReceiveMessagesNotification;
FOUNDATION_EXPORT NSString * const ODataMessagesKey;
FOUNDATION_EXPORT NSString * const ODataMessagesURLKey;
FOUNDATION_EXPORT NSString * const ODataMessagesObjectIDKey;
// NSNumber BOOL, default YES: ask for IEEE754Compatible=true, so Int64 and
// Decimal values travel as strings and keep every digit. Turn it off only
// for a service that rejects the parameter.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreIEEE754CompatibleOption;
// NSNumber BOOL, default YES: send a save of two or more requests as one
// $batch change set, so it takes effect whole or not at all. A service
// that refuses $batch gets the requests one at a time regardless.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreBatchSavesOption;
// NSNumber BOOL, default YES: with a service that speaks 4.01, send a
// $batch in the JSON batch format rather than multipart. A service that
// refuses it gets multipart from then on.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreJSONBatchOption;
// NSNumber BOOL, default NO: requests prefer respond-async (Part 1 section
// 8.2.8.8). A service may then answer one that takes its time with 202
// and a status monitor, which the client polls, as Retry-After asks, until
// it has the answer; callers see only the answer. For long work (a large
// $batch, a slow action) behind proxies that cut long requests off.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreRespondAsyncOption;
// NSNumber BOOL, default NO: fail to open when the model does not match
// the service's $metadata, rather than report it in metadataProblems.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreRequireMatchingModelOption;
// NSString, default @"4.01": the OData-MaxVersion requests carry, the
// newest protocol version the store will speak. The store speaks the
// newer of 4.0 and 4.01 that both this and the service's $metadata
// allow, and writes its requests in that version: see `version`.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreMaxVersionOption;
// NSNumber BOOL: address entities as Products/1 rather than Products(1)
// (Part 2 section 4.3.6). Unset, the store does so when $metadata says
// the service supports it (Capabilities.KeyAsSegmentSupported).
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreKeyAsSegmentOption;
// NSArray of entity names: the entities -fetchRemoteChanges: tracks.
// Unset, every entity with an entity set of its own.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreTrackedEntitiesOption;
// NSURL of a directory: where downloaded streams are kept (ODataStreamTransfer).
// Unset, a directory of the store's own under NSTemporaryDirectory().
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreStreamDirectoryOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreType;
// NSString: an API key, sent as the service's Authorization.ApiKey says
// (its KeyName, in a header, the query or a cookie).
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreAPIKeyOption;
// An object conforming to ODataCredentialProviding.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreCredentialProviderOption;

@class ODataSchemaAuthorization;

// Credentials for the way to sign in a service declares, when the
// configuration has none of its own, or the ones it had are refused. Asked
// on the thread of the request, which waits: a provider that refreshes a
// token over the network does so there.
@protocol ODataCredentialProviding <NSObject>
@optional
// A bearer token: for OpenIDConnect, the OAuth2 flows, Http bearer (its
// issuer and the scopes the service needs are in the authorization). With
// no way known (none declared, or $metadata not read, as where it is behind
// the sign-in), asked once the service refuses a request, authorization
// nil. refresh: the last one it gave was answered 401.
- (nullable NSString *)accessTokenForAuthorization:(nullable ODataSchemaAuthorization *)authorization refresh:(BOOL)refresh;
// A user and password, for Http basic.
- (nullable NSURLCredential *)credentialForAuthorization:(nullable ODataSchemaAuthorization *)authorization;
// A key, for ApiKey.
- (nullable NSString *)APIKeyForAuthorization:(nullable ODataSchemaAuthorization *)authorization;
@end

@interface ODataConfiguration : NSObject
@property (nonatomic, copy) NSURL *serviceRoot;
@property (nonatomic, copy, nullable) NSString *accessToken;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy, nullable) NSString *apiKey;
@property (nonatomic, strong, nullable) id<ODataCredentialProviding> credentialProvider;
// The ways to sign in the service declares ($metadata's Authorization
// vocabulary); the store sets them once it has read it. Requests are
// signed the first way the credentials here, or the provider's, can: a
// bearer token, a user and password, or an API key where the service
// wants it. None declared: a bearer token if there is one, else basic.
@property (nonatomic, copy, nullable) NSArray<ODataSchemaAuthorization *> *authorizations;
@property (nonatomic, readonly, nullable) ODataSchemaAuthorization *authorization;
// After a 401: asks the provider for a fresh token; YES if it gave one.
- (BOOL)refreshCredentials;
// What the service expects, for an error that says why it was refused.
@property (nonatomic, readonly, nullable) NSString *expectedCredentials;
@property (nonatomic) NSTimeInterval timeout;
@property (nonatomic) ODataPropertyNaming naming;
@property (nonatomic) BOOL postOnObtainPermanentIDs;
@property (nonatomic) BOOL IEEE754Compatible;
@property (nonatomic) BOOL batchSaves;
// $batch as JSON (4.01) rather than multipart: set by the store once it
// knows the service speaks 4.01, where ODataIncrementalStoreJSONBatchOption
// allows it.
@property (nonatomic) BOOL JSONBatch;
@property (nonatomic, readonly) BOOL JSONBatchAllowed;
// Requests that change something carry Repeatability-Request-ID and
// Repeatability-First-Sent (OData Repeatable Requests), and one that gets
// no answer at all is sent again, as it was, up to twice: the service
// answers a repeat as it answered the first. Set from $metadata
// (Repeatability.Supported on the container).
@property (nonatomic) BOOL repeatable;
// ODataIncrementalStoreRespondAsyncOption; and how long to poll a status
// monitor before giving up (and DELETE-ing it). Default: 600 seconds.
@property (nonatomic) BOOL respondAsync;
@property (nonatomic) NSTimeInterval asyncTimeout;
@property (nonatomic, copy) NSString *maxVersion;
// The OData-Version requests carry, and the one their URLs and bodies are
// written in: 4.0 until the store has read $metadata.
@property (nonatomic, copy) NSString *version;
// The version to speak with a service that speaks `serviceVersion`.
- (NSString *)versionForService:(nullable NSString *)serviceVersion;
@property (nonatomic, copy) NSString *userAgent;

- (instancetype)initWithURL:(NSURL *)url options:(nullable NSDictionary *)options NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)applyToRequest:(NSMutableURLRequest *)request;
@end

NS_ASSUME_NONNULL_END
