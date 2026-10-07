// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataConfiguration.h"
#import "ODataSchema.h"

NSString * const ODataIncrementalStoreAccessTokenOption = @"ODataIncrementalStoreAccessToken";
NSString * const ODataIncrementalStoreUsernameOption = @"ODataIncrementalStoreUsername";
NSString * const ODataIncrementalStorePasswordOption = @"ODataIncrementalStorePassword";
NSString * const ODataIncrementalStoreTimeoutOption = @"ODataIncrementalStoreTimeout";
NSString * const ODataIncrementalStorePostOnObtainPermanentIDsOption = @"ODataIncrementalStorePostOnObtainPermanentIDs";
NSString * const ODataIncrementalStoreTransportOption = @"ODataIncrementalStoreTransport";
NSString * const ODataIncrementalStoreAPIKeyOption = @"ODataIncrementalStoreAPIKey";
NSString * const ODataIncrementalStoreCredentialProviderOption = @"ODataIncrementalStoreCredentialProvider";
NSString * const ODataIncrementalStoreDidReceiveMessagesNotification = @"ODataIncrementalStoreDidReceiveMessagesNotification";
NSString * const ODataMessagesKey = @"ODataMessages";
NSString * const ODataMessagesURLKey = @"ODataMessagesURL";
NSString * const ODataMessagesObjectIDKey = @"ODataMessagesObjectID";
NSString * const ODataIncrementalStoreTrackedEntitiesOption = @"ODataIncrementalStoreTrackedEntities";
NSString * const ODataIncrementalStoreStreamDirectoryOption = @"ODataIncrementalStoreStreamDirectory";
NSString * const ODataIncrementalStoreRespondAsyncOption = @"ODataIncrementalStoreRespondAsync";
NSString * const ODataIncrementalStoreJSONBatchOption = @"ODataIncrementalStoreJSONBatch";
NSString * const ODataIncrementalStoreKeyAsSegmentOption = @"ODataIncrementalStoreKeyAsSegment";
NSString * const ODataIncrementalStoreMaxVersionOption = @"ODataIncrementalStoreMaxVersion";
NSString * const ODataIncrementalStoreIEEE754CompatibleOption = @"ODataIncrementalStoreIEEE754Compatible";
NSString * const ODataIncrementalStoreBatchSavesOption = @"ODataIncrementalStoreBatchSaves";
NSString * const ODataIncrementalStoreRequireMatchingModelOption = @"ODataIncrementalStoreRequireMatchingModel";
NSString * const ODataIncrementalStoreType = @"ODataIncrementalStore";

@implementation ODataConfiguration {
  NSString *_providedToken;
}

- (instancetype)initWithURL:(NSURL *)url options:(NSDictionary *)options
{
  self = [super init];
  if (!self) return nil;
  NSString *abs = url.absoluteString ?: @"";
  if (abs.length && ![abs hasSuffix:@"/"]) {
    abs = [abs stringByAppendingString:@"/"];
  }
  _serviceRoot = [NSURL URLWithString:abs] ?: url;
  _accessToken = [options[ODataIncrementalStoreAccessTokenOption] copy];
  _username = [options[ODataIncrementalStoreUsernameOption] copy];
  _password = [options[ODataIncrementalStorePasswordOption] copy];
  _apiKey = [options[ODataIncrementalStoreAPIKeyOption] copy];
  _credentialProvider = options[ODataIncrementalStoreCredentialProviderOption];
  id timeout = options[ODataIncrementalStoreTimeoutOption];
  _timeout = timeout ? [timeout doubleValue] : 60.0;
  _naming = ODataPropertyNamingPascalCase;
  id post = options[ODataIncrementalStorePostOnObtainPermanentIDsOption];
  _postOnObtainPermanentIDs = post ? [post boolValue] : YES;
  id ieee = options[ODataIncrementalStoreIEEE754CompatibleOption];
  _IEEE754Compatible = ieee ? [ieee boolValue] : YES;
  id batch = options[ODataIncrementalStoreBatchSavesOption];
  _batchSaves = batch ? [batch boolValue] : YES;
  _respondAsync = [options[ODataIncrementalStoreRespondAsyncOption] boolValue];
  id JSONBatch = options[ODataIncrementalStoreJSONBatchOption];
  _JSONBatchAllowed = JSONBatch ? [JSONBatch boolValue] : YES;
  _asyncTimeout = 600;
  id maxVersion = options[ODataIncrementalStoreMaxVersionOption];
  _maxVersion = [maxVersion isKindOfClass:[NSString class]] ? [maxVersion copy] : @"4.01";
  _version = @"4.0";
  _userAgent = @"ODataIncrementalStore/1.0 (LGPL-2.1; libobjc2)";
  return self;
}

- (NSString *)versionForService:(NSString *)serviceVersion
{
  BOOL service401 = [serviceVersion compare:@"4.01" options:NSNumericSearch] != NSOrderedAscending;
  BOOL client401 = [self.maxVersion compare:@"4.01" options:NSNumericSearch] != NSOrderedAscending;
  return service401 && client401 ? @"4.01" : @"4.0";
}

- (void)applyToRequest:(NSMutableURLRequest *)request
{
  NSString *method = request.HTTPMethod ?: @"GET";
  if (self.repeatable && ![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"] &&
      ![request valueForHTTPHeaderField:@"Repeatability-Request-ID"]) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      formatter = [[NSDateFormatter alloc] init];
      formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
      formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
      formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
    });
    [request setValue:[NSUUID UUID].UUIDString forHTTPHeaderField:@"Repeatability-Request-ID"];
    [request setValue:[formatter stringFromDate:[NSDate date]] forHTTPHeaderField:@"Repeatability-First-Sent"];
  }
  if (self.respondAsync) {
    NSString *prefer = [request valueForHTTPHeaderField:@"Prefer"];
    if (![prefer.lowercaseString containsString:@"respond-async"]) {
      [request setValue:prefer.length ? [prefer stringByAppendingString:@",respond-async"] : @"respond-async" forHTTPHeaderField:@"Prefer"];
    }
  }
  // JSON is the default, not a rule: $metadata asks for XML and $count for
  // text, and a service answers 406 or 415 when Accept rules those out.
  // IEEE754Compatible=true: Int64 and Decimal as strings, both ways
  // (JSON Format section 3.2), so no digit goes through a double.
  NSString *json = self.IEEE754Compatible ? @"application/json;odata.metadata=minimal;IEEE754Compatible=true"
                                          : @"application/json;odata.metadata=minimal";
  if (![request valueForHTTPHeaderField:@"Accept"]) {
    [request setValue:json forHTTPHeaderField:@"Accept"];
  }
  if (request.HTTPBody.length && ![request valueForHTTPHeaderField:@"Content-Type"]) {
    [request setValue:json forHTTPHeaderField:@"Content-Type"];
  }
  [request setValue:self.version forHTTPHeaderField:@"OData-Version"];
  [request setValue:self.maxVersion forHTTPHeaderField:@"OData-MaxVersion"];
  [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
  request.timeoutInterval = self.timeout;
  [self signRequest:request];
}

#pragma mark Signing in

- (id<ODataCredentialProviding>)provider
{
  return self.credentialProvider;
}

- (NSString *)bearerTokenFor:(ODataSchemaAuthorization *)authorization
{
  if (self.accessToken.length) return self.accessToken;
  @synchronized (self) {
    if (!_providedToken && [self.provider respondsToSelector:@selector(accessTokenForAuthorization:refresh:)]) {
      _providedToken = [[self.provider accessTokenForAuthorization:authorization refresh:NO] copy];
    }
    return _providedToken;
  }
}

- (NSURLCredential *)basicCredentialFor:(ODataSchemaAuthorization *)authorization
{
  if (self.username) return [NSURLCredential credentialWithUser:self.username password:self.password ?: @"" persistence:NSURLCredentialPersistenceNone];
  return [self.provider respondsToSelector:@selector(credentialForAuthorization:)] ? [self.provider credentialForAuthorization:authorization] : nil;
}

- (NSString *)keyFor:(ODataSchemaAuthorization *)authorization
{
  if (self.apiKey.length) return self.apiKey;
  return [self.provider respondsToSelector:@selector(APIKeyForAuthorization:)] ? [self.provider APIKeyForAuthorization:authorization] : nil;
}

// The first way to sign in the credentials can take.
- (ODataSchemaAuthorization *)authorization
{
  for (ODataSchemaAuthorization *authorization in self.authorizations) {
    if (authorization.usesBearerToken) {
      if (self.accessToken.length || [self.provider respondsToSelector:@selector(accessTokenForAuthorization:refresh:)]) return authorization;
    } else if ([authorization.kind isEqualToString:@"Http"]) {
      if (self.username || [self.provider respondsToSelector:@selector(credentialForAuthorization:)]) return authorization;
    } else if ([authorization.kind isEqualToString:@"ApiKey"]) {
      if (self.apiKey.length || [self.provider respondsToSelector:@selector(APIKeyForAuthorization:)]) return authorization;
    }
  }
  return nil;
}

static void OISSetBasic(NSMutableURLRequest *request, NSURLCredential *credential)
{
  NSString *pair = [NSString stringWithFormat:@"%@:%@", credential.user ?: @"", credential.password ?: @""];
  NSString *b64 = [[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
  [request setValue:[NSString stringWithFormat:@"Basic %@", b64] forHTTPHeaderField:@"Authorization"];
}

- (void)signRequest:(NSMutableURLRequest *)request
{
  ODataSchemaAuthorization *authorization = self.authorization;
  if (!authorization) {
    // None declared, or $metadata not read yet (as where it is behind the
    // sign-in): a bearer token if there is one, given or one the provider
    // gave once the service refused a request (-refreshCredentials), else
    // a user and password, given or a provider's that gives no tokens.
    // Declared, but none these credentials can take: the ones given.
    BOOL declared = self.authorizations.count > 0;
    NSString *token = self.accessToken;
    if (!token.length && !declared) @synchronized (self) { token = _providedToken; }
    BOOL tokens = [self.provider respondsToSelector:@selector(accessTokenForAuthorization:refresh:)];
    NSURLCredential *credential = token.length || (!self.username && (declared || tokens)) ? nil : [self basicCredentialFor:nil];
    if (token.length) {
      [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    } else if (credential) {
      OISSetBasic(request, credential);
    }
    return;
  }
  if (authorization.usesBearerToken) {
    NSString *token = [self bearerTokenFor:authorization];
    if (token.length) [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
  } else if ([authorization.kind isEqualToString:@"Http"]) {
    NSURLCredential *credential = [self basicCredentialFor:authorization];
    if (credential) OISSetBasic(request, credential);
  } else if ([authorization.kind isEqualToString:@"ApiKey"]) {
    NSString *key = [self keyFor:authorization];
    NSString *name = authorization.keyName ?: @"api_key";
    if (!key.length) return;
    if ([authorization.location isEqualToString:@"QueryOption"]) {
      NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES];
      NSMutableArray *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
      for (NSURLQueryItem *item in items) if ([item.name isEqualToString:name]) return;  // signed already
      [items addObject:[NSURLQueryItem queryItemWithName:name value:key]];
      components.queryItems = items;
      request.URL = components.URL;
    } else if ([authorization.location isEqualToString:@"Cookie"]) {
      [request setValue:[NSString stringWithFormat:@"%@=%@", name, key] forHTTPHeaderField:@"Cookie"];
    } else {
      [request setValue:key forHTTPHeaderField:name];
    }
  }
}

- (BOOL)refreshCredentials
{
  ODataSchemaAuthorization *authorization = self.authorization;
  if (self.accessToken.length || ![self.provider respondsToSelector:@selector(accessTokenForAuthorization:refresh:)]) return NO;
  if (authorization && !authorization.usesBearerToken) return NO;
  // refresh: a token it gave was refused; else asked for a first one.
  BOOL gave;
  @synchronized (self) { gave = _providedToken != nil; }
  NSString *fresh = [self.provider accessTokenForAuthorization:authorization refresh:gave];
  @synchronized (self) {
    BOOL changed = fresh.length && ![fresh isEqualToString:_providedToken];
    _providedToken = [fresh copy];
    return changed;
  }
}

- (NSString *)expectedCredentials
{
  if (!self.authorizations.count) return nil;
  return [NSString stringWithFormat:@"The service signs in by %@: give the store credentials for one of them "
                                    @"(an access token, a user and password, an API key), or a credential provider",
          [[self.authorizations valueForKey:@"description"] componentsJoinedByString:@"; or "]];
}

@end
