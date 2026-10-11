// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Signing in as a service's $metadata says to (ODataSignIn.h). Moved here
// from SimpleNotes (TopoText), where it began.

#import "ODataSignIn.h"
#import "ODSSystem.h"
#import <ODataKit/ODataSchema.h>

NSString * const ODataSignInErrorDomain = @"ODataSignIn";

static NSError *ODSSignInError(NSString *what) {
    return [NSError errorWithDomain:ODataSignInErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: what }];
}

/* application/x-www-form-urlencoded, as OAuth posts. */
static NSData *ODSSignInForm(NSDictionary<NSString *, NSString *> *fields) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@=%@", [k stringByAddingPercentEncodingWithAllowedCharacters:allowed],
                                                    [fields[k] stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
    return [[parts componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}

/* A JWT's claims, unchecked (the server checks them; the app only shows
   who it is). */
static NSDictionary *ODSClaimsOfJWT(NSString *jwt) {
    NSArray *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2) return nil;
    NSString *b64 = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (b64.length % 4) b64 = [b64 stringByAppendingString:@"="];
    NSData *json = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    id claims = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
    return [claims isKindOfClass:[NSDictionary class]] ? claims : nil;
}

static NSString *ODSSignInBase64URL(NSData *data) {
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    base64 = [[base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [base64 stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
}

/* PKCE (RFC 7636): a verifier of 32 random bytes, base64url; its S256
   challenge, base64url of its SHA-256. Sent though the device flow does
   not ask for it: some providers do (Keycloak, with the client's PKCE
   method set), the others ignore it. */
static NSString *ODSNewVerifier(void) {
    uint8_t bytes[32];
    ODSSystemRandomBytes(bytes, sizeof bytes);
    return ODSSignInBase64URL([NSData dataWithBytes:bytes length:sizeof bytes]);
}

NSString *ODataSignInChallengeOfVerifier(NSString *verifier) {
    return ODSSignInBase64URL(ODSSystemSHA256([verifier dataUsingEncoding:NSASCIIStringEncoding]));
}

@implementation ODataSecretStore

- (instancetype)initWithServiceName:(NSString *)serviceName {
    if (!(self = [super init])) return nil;
    _serviceName = [serviceName copy];
    return self;
}

- (NSDictionary *)secretsForAccount:(NSString *)account {
    return ODSSystemSecrets(_serviceName, account);
}

- (BOOL)setSecrets:(NSDictionary *)secrets forAccount:(NSString *)account {
    return ODSSystemSetSecrets(secrets, _serviceName, account);
}

@end

@implementation ODataSignIn {
    id<ODataSecretStoring> _secrets;
    NSURL *_deviceEndpoint, *_tokenEndpoint;
    /* The device flow under way, and its PKCE verifier. */
    NSString *_deviceCode, *_verifier;
    NSTimeInterval _interval;
    NSDate *_deadline;
    NSTimer *_poll;
    BOOL _beginWhenLearnt;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot secrets:(id<ODataSecretStoring>)secrets {
    if (!(self = [super init])) return nil;
    _serviceRoot = [serviceRoot copy];
    _secrets = secrets;
    NSDictionary *kept = [self kept];
    _kind = (ODataSignInKind)[kept[@"kind"] integerValue];
    _issuer = [kept[@"issuer"] length] ? [NSURL URLWithString:kept[@"issuer"]] : nil;
    return self;
}

- (void)dealloc {
    [_poll invalidate];
}

#pragma mark what is kept

- (NSString *)account {
    return _serviceRoot.absoluteString;
}

- (NSDictionary *)kept {
    return [_secrets secretsForAccount:[self account]] ?: @{};
}

- (void)keep:(NSDictionary *)changes {
    NSMutableDictionary *now = [[self kept] mutableCopy];
    [now addEntriesFromDictionary:changes];
    now[@"kind"] = @(_kind);
    if (_issuer) now[@"issuer"] = _issuer.absoluteString;
    [_secrets setSecrets:now forAccount:[self account]];
}

- (BOOL)isSignedIn {
    NSDictionary *k = [self kept];
    if (_kind == ODataSignInNone) return YES;
    if (_kind == ODataSignInPassword) return [k[@"user"] length] > 0;
    return [k[@"refresh"] length] > 0 || [k[@"access"] length] > 0;
}

- (NSString *)userName {
    NSDictionary *k = [self kept];
    if (_kind == ODataSignInPassword) return k[@"user"];
    return k[@"name"];
}

- (void)signOut {
    [self cancel];
    [_secrets setSecrets:@{ @"kind": @(_kind), @"issuer": _issuer.absoluteString ?: @"" } forAccount:[self account]];
}

#pragma mark talking

- (void)send:(NSURLRequest *)request done:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))done {
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        done(data, [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil, error);
    }] resume];
}

- (NSMutableURLRequest *)post:(NSURL *)url form:(NSDictionary *)form {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    r.HTTPBody = ODSSignInForm(form);
    return r;
}

static NSDictionary *ODSSignInJSON(NSData *data) {
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

/* The delegate told, on the main thread. */
- (void)tell:(SEL)selector with:(id)argument {
    id<ODataSignInDelegate> delegate = _delegate;
    if (![delegate respondsToSelector:selector]) return;
    if (argument) [(id)delegate performSelectorOnMainThread:selector withObject:argument waitUntilDone:NO];
    else [(id)delegate performSelectorOnMainThread:selector withObject:self waitUntilDone:NO];
}

- (void)fail:(NSError *)error {
    [self cancelOnMain];
    id<ODataSignInDelegate> delegate = _delegate;
    if ([delegate respondsToSelector:@selector(signIn:didFail:)])
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate signIn:self didFail:error];
        });
}

#pragma mark learning what the server asks for

- (void)learn {
    NSURL *metadata = [NSURL URLWithString:@"$metadata" relativeToURL:_serviceRoot];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:metadata.absoluteURL];
    [r setValue:@"application/xml" forHTTPHeaderField:@"Accept"];
    [self send:r done:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (!data || response.statusCode != 200) {
            [self fail:error ?: ODSSignInError([NSString stringWithFormat:@"The server did not say how to sign in (HTTP %ld).", (long)response.statusCode])];
            return;
        }
        ODataSchema *schema = [ODataSchema schemaWithData:data error:NULL];
        ODataSignInKind kind = ODataSignInNone;
        NSURL *issuer = nil;
        for (ODataSchemaAuthorization *a in schema.authorizations) {
            if ([a.kind isEqual:@"OpenIDConnect"] && a.issuerURL) {
                kind = ODataSignInOpenID;
                issuer = a.issuerURL;
                break;
            }
            if ([a.kind isEqual:@"Http"] && [a.scheme.lowercaseString isEqual:@"basic"]) kind = ODataSignInPassword;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_kind = kind;
            self->_issuer = issuer;
            [self keep:@{}];
            [self tell:@selector(signInDidLearn:) with:nil];
            if (self->_beginWhenLearnt) {
                self->_beginWhenLearnt = NO;
                [self begin];
            }
        });
    }];
}

#pragma mark the device flow

- (void)begin {
    if (_kind == ODataSignInUnknown) {
        _beginWhenLearnt = YES;
        [self learn];
        return;
    }
    if (_kind != ODataSignInOpenID) {
        [self tell:@selector(signInDidFinish:) with:nil];
        return;
    }
    if (!_clientID.length) {
        [self fail:ODSSignInError(@"No client to sign in with: the identity provider's client ID is not set.")];
        return;
    }
    if (_deviceEndpoint && _tokenEndpoint) {
        [self askForCode];
        return;
    }
    /* The provider's endpoints, from its discovery document. */
    NSURL *discovery = [NSURL URLWithString:[_issuer.absoluteString stringByAppendingString:
                                               [_issuer.absoluteString hasSuffix:@"/"] ? @".well-known/openid-configuration"
                                                                                       : @"/.well-known/openid-configuration"]];
    [self send:[NSURLRequest requestWithURL:discovery] done:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *d = ODSSignInJSON(data);
        NSURL *device = [d[@"device_authorization_endpoint"] length] ? [NSURL URLWithString:d[@"device_authorization_endpoint"]] : nil;
        NSURL *token = [d[@"token_endpoint"] length] ? [NSURL URLWithString:d[@"token_endpoint"]] : nil;
        if (!device || !token) {
            [self fail:error ?: ODSSignInError(@"The sign-in provider has no device sign-in (OAuth 2.0 Device Authorization Grant).")];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_deviceEndpoint = device;
            self->_tokenEndpoint = token;
            [self askForCode];
        });
    }];
}

- (void)askForCode {
    _verifier = ODSNewVerifier();
    if (!_verifier) {
        [self fail:ODSSignInError(@"The system gave no random bytes to sign in with.")];
        return;
    }
    NSURLRequest *r = [self post:_deviceEndpoint form:@{ @"client_id": _clientID, @"scope": @"openid profile offline_access",
                                                        @"code_challenge": ODataSignInChallengeOfVerifier(_verifier), @"code_challenge_method": @"S256" }];
    [self send:r done:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *d = ODSSignInJSON(data);
        NSString *code = d[@"user_code"], *device = d[@"device_code"], *page = d[@"verification_uri"];
        if (![code isKindOfClass:[NSString class]] || ![device isKindOfClass:[NSString class]] || ![page isKindOfClass:[NSString class]]) {
            [self fail:error ?: ODSSignInError([NSString stringWithFormat:@"The sign-in provider refused: %@", d[@"error_description"] ?: d[@"error"] ?: @"no code"])];
            return;
        }
        NSString *complete = [d[@"verification_uri_complete"] isKindOfClass:[NSString class]] ? d[@"verification_uri_complete"] : nil;
        NSTimeInterval interval = [d[@"interval"] doubleValue] ?: 5, expires = [d[@"expires_in"] doubleValue] ?: 600;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_deviceCode = device;
            self->_interval = interval;
            self->_deadline = [NSDate dateWithTimeIntervalSinceNow:expires];
            id<ODataSignInDelegate> delegate = self->_delegate;
            if ([delegate respondsToSelector:@selector(signIn:showCode:page:completePage:)])
                [delegate signIn:self showCode:code page:[NSURL URLWithString:page] completePage:complete ? [NSURL URLWithString:complete] : nil];
            [self pollLater];
        });
    }];
}

- (void)pollLater {
    [_poll invalidate];
    /* In every mode: an alert or a menu open does not stop it. */
    _poll = [NSTimer timerWithTimeInterval:_interval target:self selector:@selector(poll:) userInfo:nil repeats:NO];
    /* GNUstep's common modes leave out the default one: named too. */
    [[NSRunLoop mainRunLoop] addTimer:_poll forMode:NSDefaultRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:_poll forMode:NSRunLoopCommonModes];
}

- (void)poll:(NSTimer *)timer {
    _poll = nil;
    if (!_deviceCode) return;
    if ([_deadline timeIntervalSinceNow] < 0) {
        [self fail:ODSSignInError(@"The code ran out before it was entered. Sign in again.")];
        return;
    }
    NSURLRequest *r = [self post:_tokenEndpoint form:@{ @"grant_type": @"urn:ietf:params:oauth:grant-type:device_code",
                                                        @"device_code": _deviceCode, @"client_id": _clientID, @"code_verifier": _verifier }];
    [self send:r done:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSDictionary *d = ODSSignInJSON(data);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_deviceCode) return;   /* cancelled meanwhile */
            if (response.statusCode == 200 && [d[@"access_token"] isKindOfClass:[NSString class]]) {
                self->_deviceCode = nil;
                [self keepTokens:d];
                [self tell:@selector(signInDidFinish:) with:nil];
                return;
            }
            /* No answer at all (on iOS, the request cut while the app waited
               behind the sign-in page; the network changed): asked again,
               while the code holds. */
            if (!response && error) {
                [self pollLater];
                return;
            }
            NSString *why = d[@"error"];
            if ([why isEqual:@"authorization_pending"]) [self pollLater];
            else if ([why isEqual:@"slow_down"]) {
                self->_interval += 5;
                [self pollLater];
            } else if ([why isEqual:@"access_denied"]) [self fail:ODSSignInError(@"Signing in was declined.")];
            else if ([why isEqual:@"expired_token"]) [self fail:ODSSignInError(@"The code ran out before it was entered. Sign in again.")];
            else [self fail:error ?: ODSSignInError([NSString stringWithFormat:@"Signing in failed: %@", d[@"error_description"] ?: why ?: @"no answer"])];
        });
    }];
}

- (void)keepTokens:(NSDictionary *)d {
    NSMutableDictionary *k = [NSMutableDictionary dictionary];
    k[@"access"] = d[@"access_token"];
    if ([d[@"refresh_token"] isKindOfClass:[NSString class]]) k[@"refresh"] = d[@"refresh_token"];
    k[@"expires"] = @([NSDate date].timeIntervalSince1970 + ([d[@"expires_in"] doubleValue] ?: 300));
    NSDictionary *claims = ODSClaimsOfJWT([d[@"id_token"] isKindOfClass:[NSString class]] ? d[@"id_token"] : d[@"access_token"]);
    NSString *name = claims[@"preferred_username"] ?: claims[@"email"] ?: claims[@"sub"];
    if ([name isKindOfClass:[NSString class]]) k[@"name"] = name;
    [self keep:k];
}

- (void)cancelOnMain {
    if ([NSThread isMainThread]) [self cancel];
    else [self performSelectorOnMainThread:@selector(cancel) withObject:nil waitUntilDone:NO];
}

- (void)cancel {
    [_poll invalidate];
    _poll = nil;
    _deviceCode = nil;
    _beginWhenLearnt = NO;
}

- (void)signInWithUser:(NSString *)user password:(NSString *)password {
    [self keep:@{ @"user": user ?: @"", @"password": password ?: @"" }];
    [self tell:@selector(signInDidFinish:) with:nil];
}

#pragma mark the sync's credentials

- (ODataConfiguration *)configuration {
    ODataConfiguration *c = [[ODataConfiguration alloc] initWithURL:_serviceRoot options:nil];
    /* Asked for credentials once the server refuses a request (a sync
       does not read $metadata, behind the sign-in on most servers). */
    c.credentialProvider = self;
    return c;
}

/* The access token; a fresh one when it ran out, or the server refused it
   (refresh). Asked on the sync's thread: waits there for the provider. */
- (NSString *)accessTokenForAuthorization:(ODataSchemaAuthorization *)authorization refresh:(BOOL)refresh {
    if (_kind != ODataSignInOpenID) return nil;
    NSDictionary *k = [self kept];
    NSTimeInterval expires = [k[@"expires"] doubleValue];
    if (!refresh && [k[@"access"] length] && expires - 30 > [NSDate date].timeIntervalSince1970) return k[@"access"];
    NSString *token = k[@"refresh"];
    if (!token.length) return refresh ? nil : k[@"access"];
    if (!_tokenEndpoint) [self discoverAndWait];
    if (!_tokenEndpoint) return nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *answer = nil;
    __block NSInteger status = 0;
    [self send:[self post:_tokenEndpoint form:@{ @"grant_type": @"refresh_token", @"refresh_token": token, @"client_id": _clientID }]
          done:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
              answer = ODSSignInJSON(data);
              status = response.statusCode;
              dispatch_semaphore_signal(done);
          }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    if (status != 200 || ![answer[@"access_token"] isKindOfClass:[NSString class]]) return nil;
    [self keepTokens:answer];
    return answer[@"access_token"];
}

- (void)discoverAndWait {
    NSURL *discovery = [NSURL URLWithString:[_issuer.absoluteString stringByAppendingString:
                                               [_issuer.absoluteString hasSuffix:@"/"] ? @".well-known/openid-configuration"
                                                                                       : @"/.well-known/openid-configuration"]];
    if (!discovery) return;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *d = nil;
    [self send:[NSURLRequest requestWithURL:discovery] done:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        d = ODSSignInJSON(data);
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    if ([d[@"token_endpoint"] length]) _tokenEndpoint = [NSURL URLWithString:d[@"token_endpoint"]];
    if ([d[@"device_authorization_endpoint"] length]) _deviceEndpoint = [NSURL URLWithString:d[@"device_authorization_endpoint"]];
}

- (NSURLCredential *)credentialForAuthorization:(ODataSchemaAuthorization *)authorization {
    if (_kind != ODataSignInPassword) return nil;
    NSDictionary *k = [self kept];
    return [k[@"user"] length] ? [NSURLCredential credentialWithUser:k[@"user"] password:k[@"password"] ?: @""
                                                          persistence:NSURLCredentialPersistenceNone] : nil;
}

@end
