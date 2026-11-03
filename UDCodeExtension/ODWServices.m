// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWServices.h"
#import "ODWRequests.h"
#import "WBSignInPanel.h"
#import <ODataSync/ODataSignIn.h>
#import <OTelKit/OTelKit.h>

NSNotificationName const ODWServicesDidChangeNotification = @"ODWServicesDidChangeNotification";
NSNotificationName const ODWDocumentServiceDidChangeNotification = @"ODWDocumentServiceDidChangeNotification";
NSNotificationName const ODWExchangeLogDidChangeNotification = @"ODWExchangeLogDidChangeNotification";
NSNotificationName const ODWAnswerNotification = @"ODWAnswerNotification";
NSString *const ODWAnswerKey = @"ODWAnswer";

// Where they are kept: the project's settings, the user's defaults, and
// which service each document file was last sent to.
static NSString *const ODWSettingsKey = @"odataServices";
static NSString *const ODWDefaultsKey = @"ODWServices";
static NSString *const ODWDocumentsDefaultsKey = @"ODWDocumentServices";
// A sign-in's tokens or password: UDCredentialStore's service, by root.
static NSString *const ODWCredentialService = @"UDCode OData";

// ODataSignIn's secrets kept where UDCode keeps passwords (UDCredentialStore:
// the Keychain, the Secret Service, Windows Credential Manager), as JSON.
@interface ODWSecrets : NSObject <ODataSecretStoring>
@end

@implementation ODWSecrets

- (NSDictionary<NSString *, id> *)secretsForAccount:(NSString *)account
{
  NSString *kept = [[UDCredentialStore sharedStore] passwordForService:ODWCredentialService account:account];
  NSData *data = [kept dataUsingEncoding:NSUTF8StringEncoding];
  id secrets = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  return [secrets isKindOfClass:[NSDictionary class]] ? secrets : nil;
}

- (BOOL)setSecrets:(NSDictionary<NSString *, id> *)secrets forAccount:(NSString *)account
{
  UDCredentialStore *store = [UDCredentialStore sharedStore];
  if (!secrets) return [store removePasswordForService:ODWCredentialService account:account error:NULL];
  NSData *data = [NSJSONSerialization dataWithJSONObject:secrets options:0 error:NULL];
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  return text && [store setPassword:text forService:ODWCredentialService account:account error:NULL];
}

@end

#pragma mark - A service

@interface ODWService ()
@property (nonatomic, readwrite) ODWServiceKind kind;
@property (nonatomic, readwrite, getter=isPreset) BOOL preset;
@property (nonatomic, readwrite, nullable) WBConnection *connection;
@property (nonatomic, readwrite, copy, nullable) NSString *failure;
@property (nonatomic, strong, nullable) ODataSignIn *signIn;
// Requests waiting for it to connect.
@property (nonatomic, strong) NSMutableArray<ODWRequest *> *waiting;
@end

@implementation ODWService

- (instancetype)init
{
  if ((self = [super init])) _waiting = [NSMutableArray array];
  return self;
}

- (BOOL)isConnected
{
  return _connection.store != nil && !_connection.connecting;
}

- (BOOL)isConnecting
{
  return _connection.connecting || (_signIn && !_connection);
}

- (NSArray<NSString *> *)entitySetNames
{
  return [_connection.store.schema.entitySets.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] ?: @[];
}

- (NSArray<NSString *> *)operationNames
{
  return [_connection.store.schema.operationImports.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] ?: @[];
}

- (NSDictionary *)plist
{
  return @{ @"name": _name ?: @"", @"url": _root.absoluteString ?: @"" };
}

@end

#pragma mark - An answer

@interface ODWAnswer ()
@property (nonatomic, readwrite) ODWService *service;
@property (nonatomic, readwrite, copy) NSString *title;
@property (nonatomic, readwrite) NSURLRequest *request;
@property (nonatomic, readwrite) NSInteger status;
@property (nonatomic, readwrite, copy, nullable) NSData *data;
@property (nonatomic, readwrite, copy, nullable) NSString *failure;
@property (nonatomic, readwrite) NSTimeInterval duration;
@property (nonatomic, readwrite, copy, nullable) NSArray<NSDictionary *> *rows;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *columns;
@property (nonatomic, readwrite, copy) NSString *text;
@end

@implementation ODWAnswer

// The body read: rows from JSON (a collection's value, or one entity), its
// columns, and its text indented.
- (void)read
{
  _columns = @[];
  _text = @"";
  if (!_data.length) return;
  id json = [NSJSONSerialization JSONObjectWithData:_data options:0 error:NULL];
  if (!json) {
    _text = [[NSString alloc] initWithData:_data encoding:NSUTF8StringEncoding] ?: [NSString stringWithFormat:@"(%lu bytes)", (unsigned long)_data.length];
    return;
  }
  NSData *pretty = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:NULL];
  _text = pretty ? [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding] : @"";
  NSArray *rows = nil;
  if ([json isKindOfClass:[NSDictionary class]]) {
    id value = json[@"value"];
    if ([value isKindOfClass:[NSArray class]]) {
      rows = value;
    } else {
      // One entity, or a single value ({"value": 42}): one row.
      NSMutableDictionary *one = [json mutableCopy];
      [one removeObjectForKey:@"@odata.context"];
      rows = one.count ? @[ one ] : nil;
    }
  } else if ([json isKindOfClass:[NSArray class]]) {
    rows = json;
  }
  NSMutableArray *kept = [NSMutableArray array];
  for (id row in rows) [kept addObject:[row isKindOfClass:[NSDictionary class]] ? row : @{ @"value": row }];
  _rows = kept.count || rows ? kept : nil;
  // The columns: the first row's properties, then any later rows add;
  // annotations last.
  NSMutableArray *names = [NSMutableArray array], *annotations = [NSMutableArray array];
  for (NSDictionary *row in kept) {
    for (NSString *key in row) {
      NSMutableArray *into = [key containsString:@"@"] ? annotations : names;
      if (![into containsObject:key]) [into addObject:key];
    }
  }
  [names addObjectsFromArray:annotations];
  _columns = names;
}

@end

#pragma mark - The services

@interface ODWServices () <ODataSignInDelegate>
@end

@implementation ODWServices {
  NSMutableArray<ODWService *> *_presets;
  NSMutableArray<ODWService *> *_kept;  // the project's, then the user's
  NSMapTable<UDCodeDocument *, NSString *> *_documentServices;
  WBSignInPanel *_signInPanel;
  // Requests sent one after another (Send All): the rest of them.
  NSMutableArray *_queue;
  BOOL _sending;
}

+ (WBTraceRecorder *)traceRecorder
{
  static WBTraceRecorder *recorder;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    recorder = [[WBTraceRecorder alloc] init];
    OTTracerProvider.sharedProvider = WBTracerProvider(recorder);
  });
  return recorder;
}

+ (ODWService *)serviceNamed:(NSString *)name root:(NSURL *)root inProject:(BOOL)inProject
{
  ODWService *service = [[ODWService alloc] init];
  service.name = name;
  service.root = root;
  service.inProject = inProject;
  service.kind = ODWServiceOther;
  return service;
}

- (instancetype)initWithWorkbench:(id<UDWorkbench>)workbench
{
  if (!(self = [super init])) return nil;
  _workbench = workbench;
  _exchangeLog = [[WBExchangeLog alloc] init];
  _documentServices = [NSMapTable weakToStrongObjectsMapTable];
  _queue = [NSMutableArray array];
  [ODWServices traceRecorder];
  _presets = [NSMutableArray array];
  NSArray *presets = @[ @[ @"Built-in Sample", @(ODWServiceBuiltIn) ], @[ @"Northwind", @(ODWServiceNorthwind) ],
                        @[ @"TripPin", @(ODWServiceTripPin) ] ];
  for (NSArray *preset in presets) {
    ODWService *service = [[ODWService alloc] init];
    service.name = preset[0];
    service.kind = [preset[1] integerValue];
    service.root = [NSURL URLWithString:[WBConnection rootOfService:(WBService)service.kind]];
    service.preset = YES;
    [_presets addObject:service];
  }
  [self readKept];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)changed
{
  [[NSNotificationCenter defaultCenter] postNotificationName:ODWServicesDidChangeNotification object:self];
}

#pragma mark Kept

// The project's and the user's, as their settings have them.
- (void)readKept
{
  _kept = [NSMutableArray array];
  UDProject *project = _workbench.project;
  NSArray *fromProject = [project.settings[ODWSettingsKey] isKindOfClass:[NSArray class]] ? project.settings[ODWSettingsKey] : @[];
  NSArray *fromUser = [[NSUserDefaults standardUserDefaults] arrayForKey:ODWDefaultsKey] ?: @[];
  for (NSArray *pair in @[ @[ fromProject, @YES ], @[ fromUser, @NO ] ]) {
    for (NSDictionary *entry in pair[0]) {
      if (![entry isKindOfClass:[NSDictionary class]]) continue;
      NSURL *root = [entry[@"url"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:entry[@"url"]] : nil;
      NSString *name = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : nil;
      if (!root.host.length || !name.length || [self serviceNamed:name]) continue;
      [_kept addObject:[ODWServices serviceNamed:name root:root inProject:[pair[1] boolValue] && project]];
    }
  }
}

// Written where each is kept.
- (void)writeKept
{
  NSMutableArray *project = [NSMutableArray array], *user = [NSMutableArray array];
  for (ODWService *service in _kept) [(service.inProject ? project : user) addObject:[service plist]];
  [[NSUserDefaults standardUserDefaults] setObject:user forKey:ODWDefaultsKey];
  UDProject *folder = _workbench.project;
  if (!folder) return;
  NSMutableDictionary *settings = [folder.settings mutableCopy] ?: [NSMutableDictionary dictionary];
  NSArray *before = settings[ODWSettingsKey];
  if (project.count) settings[ODWSettingsKey] = project;
  else [settings removeObjectForKey:ODWSettingsKey];
  if ((before || project.count) && ![before isEqual:settings[ODWSettingsKey]]) {
    NSError *error = nil;
    if (![folder setSettings:settings error:&error]) NSLog(@"ODWServices: the project's settings weren't written: %@", error);
  }
}

- (NSArray<ODWService *> *)services
{
  return [_presets arrayByAddingObjectsFromArray:_kept];
}

- (ODWService *)serviceNamed:(NSString *)name
{
  for (ODWService *service in [self services]) {
    if ([service.name isEqualToString:name]) return service;
  }
  return nil;
}

- (void)addService:(ODWService *)service
{
  if (service.preset) return;
  if (!_workbench.project) service.inProject = NO;
  ODWService *old = [self serviceNamed:service.name];
  if (old.preset) return;
  NSUInteger at = old ? [_kept indexOfObjectIdenticalTo:old] : NSNotFound;
  if (at != NSNotFound) {
    [self disconnect:old];
    [_kept replaceObjectAtIndex:at withObject:service];
  } else if (![_kept containsObject:service]) {
    [_kept addObject:service];
  }
  [self writeKept];
  [self changed];
}

- (void)removeService:(ODWService *)service
{
  if (service.preset || ![_kept containsObject:service]) return;
  [self disconnect:service];
  [_kept removeObject:service];
  [self writeKept];
  [self changed];
}

#pragma mark Connecting

- (void)connect:(ODWService *)service
{
  if (service.connecting) return;
  service.failure = nil;
  if (service.kind == ODWServiceOther) {
    // What the service asks for, first, from its $metadata.
    service.signIn = [[ODataSignIn alloc] initWithServiceRoot:[self rootOf:service] secrets:[[ODWSecrets alloc] init]];
    service.signIn.clientID = WBClientIDForRoot(service.signIn.serviceRoot);
    service.signIn.delegate = self;
    [self changed];
    [service.signIn learn];
    return;
  }
  [self startConnection:service signIn:nil];
}

// A root ends in a slash.
- (NSURL *)rootOf:(ODWService *)service
{
  NSString *text = service.root.absoluteString ?: @"";
  return [text hasSuffix:@"/"] ? service.root : [NSURL URLWithString:[text stringByAppendingString:@"/"]];
}

- (ODWService *)serviceOfSignIn:(ODataSignIn *)signIn
{
  for (ODWService *service in [self services]) {
    if (service.signIn == signIn) return service;
  }
  return nil;
}

- (void)startConnection:(ODWService *)service signIn:(ODataSignIn *)signIn
{
  WBConnection *connection = [[WBConnection alloc] init];
  connection.target = self;
  connection.connectedAction = @selector(connectionDidConnect:);
  connection.logAction = @selector(appendExchange:);
  connection.credentialProvider = signIn.kind == ODataSignInNone ? nil : signIn;
  service.connection = connection;
  NSString *why = [connection connectToService:(WBService)service.kind root:service.root.absoluteString ?: @""];
  if (why) {
    service.connection = nil;
    service.signIn = nil;
    service.failure = why;
    [self failWaitingOf:service];
  }
  [self changed];
}

- (ODWService *)serviceOfConnection:(WBConnection *)connection
{
  for (ODWService *service in [self services]) {
    if (service.connection == connection) return service;
  }
  return nil;
}

- (void)connectionDidConnect:(WBConnection *)connection
{
  ODWService *service = [self serviceOfConnection:connection];
  if (!service) return;
  if (connection.failure) {
    service.failure = connection.failure;
    ODataSignIn *signIn = service.signIn;
    // Refused: what was kept is no good; signed in again.
    if (signIn && (signIn.kind == ODataSignInOpenID || signIn.kind == ODataSignInPassword) && [connection.failure containsString:@"401"]) {
      [signIn signOut];
      service.connection = nil;
      [self askToSignIn:signIn of:service];
      [self changed];
      return;
    }
    service.connection = nil;
    service.signIn = nil;
    [self failWaitingOf:service];
  } else {
    [self sendWaitingOf:service];
  }
  [self changed];
}

- (void)disconnect:(ODWService *)service
{
  [service.waiting removeAllObjects];
  service.connection = nil;
  service.signIn = nil;
  service.failure = nil;
  [self changed];
}

- (void)signOut:(ODWService *)service
{
  ODataSignIn *signIn = service.signIn ?: [[ODataSignIn alloc] initWithServiceRoot:[self rootOf:service] secrets:[[ODWSecrets alloc] init]];
  [signIn signOut];
  [self disconnect:service];
}

#pragma mark Signing in

- (void)signInDidLearn:(ODataSignIn *)signIn
{
  signIn.delegate = nil;
  ODWService *service = [self serviceOfSignIn:signIn];
  if (!service) return;
  if (signIn.kind == ODataSignInNone || signIn.signedIn) {
    [self startConnection:service signIn:signIn];
    return;
  }
  [self askToSignIn:signIn of:service];
}

// $metadata not read (behind the sign-in too, or the service down):
// connected all the same, with whatever was kept.
- (void)signIn:(ODataSignIn *)signIn didFail:(NSError *)error
{
  signIn.delegate = nil;
  ODWService *service = [self serviceOfSignIn:signIn];
  if (service) [self startConnection:service signIn:signIn];
}

- (void)askToSignIn:(ODataSignIn *)signIn of:(ODWService *)service
{
  _signInPanel = [[WBSignInPanel alloc] initWithSignIn:signIn];
  __weak ODWServices *weak = self;
  [_signInPanel showBesideWindow:_workbench.window done:^(BOOL signedIn) {
    ODWServices *me = weak;
    if (!me) return;
    me->_signInPanel = nil;
    if (signedIn) {
      [me startConnection:service signIn:signIn];
    } else {
      service.signIn = nil;
      service.failure = @"Not signed in.";
      [me failWaitingOf:service];
      [me changed];
    }
  }];
}

#pragma mark A document's service

- (ODWService *)serviceOfDocument:(UDCodeDocument *)document
{
  NSString *name = [_documentServices objectForKey:document];
  NSString *path = document.fileURL.path;
  if (!name && path) name = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ODWDocumentsDefaultsKey][path];
  ODWService *service = name ? [self serviceNamed:name] : nil;
  if (!service) {
    NSArray *connected = [[self services] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"connected == YES"]];
    if (connected.count == 1) service = connected.firstObject;
  }
  return service;
}

- (void)setService:(ODWService *)service ofDocument:(UDCodeDocument *)document
{
  if (service) [_documentServices setObject:service.name forKey:document];
  else [_documentServices removeObjectForKey:document];
  NSString *path = document.fileURL.path;
  if (path) {
    NSMutableDictionary *saved = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:ODWDocumentsDefaultsKey] mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
    if (service) saved[path] = service.name;
    else [saved removeObjectForKey:path];
    [[NSUserDefaults standardUserDefaults] setObject:saved forKey:ODWDocumentsDefaultsKey];
  }
  [[NSNotificationCenter defaultCenter] postNotificationName:ODWDocumentServiceDidChangeNotification object:document];
}

#pragma mark Sending

- (BOOL)canSend
{
  UDCodeDocument *document = _workbench.selectedDocument;
  return document && _workbench.selectedEditor && [document.languageMode.identifier isEqualToString:@"odata"];
}

- (IBAction)sendRequest:(id)sender
{
  [self sendFromSelectedDocument:NO];
}

- (IBAction)sendAllRequests:(id)sender
{
  [self sendFromSelectedDocument:YES];
}

- (void)sendFromSelectedDocument:(BOOL)all
{
  if (![self canSend]) {
    NSBeep();
    return;
  }
  UDCodeDocument *document = _workbench.selectedDocument;
  ODWService *service = [self serviceOfDocument:document];
  if (!service) {
    [self tell:[self answerOf:nil service:nil title:@"No service" failure:@"Choose a service for this document first: in the OData navigator, Send To."]];
    return;
  }
  NSString *text = [document.textModel getValue];
  NSArray *requests = all ? ODWRequestsOfText(text) : nil;
  if (!all) {
    ODWRequest *one = ODWRequestAt(text, _workbench.selectedEditor.textView.selectedRange.location);
    requests = one ? @[ one ] : @[];
  }
  if (!requests.count) {
    [self tell:[self answerOf:nil service:service title:@"No request" failure:@"There is no request here: write one (GET Products) first."]];
    return;
  }
  [_queue removeAllObjects];
  for (ODWRequest *request in requests) [_queue addObject:@[ request, service ]];
  [self sendNextQueued];
}

- (void)sendNextQueued
{
  if (_sending || !_queue.count) return;
  NSArray *next = _queue.firstObject;
  [_queue removeObjectAtIndex:0];
  [self sendRequest:next[0] toService:next[1]];
}

- (void)sendRequest:(ODWRequest *)request toService:(ODWService *)service
{
  if (!service.connected) {
    [service.waiting addObject:request];
    if (!service.connecting) [self connect:service];
    return;
  }
  NSString *why = nil;
  NSURLRequest *urlRequest = [request URLRequestWithServiceRoot:service.connection.serviceRoot ?: [self rootOf:service] error:&why];
  if (!urlRequest) {
    [self tell:[self answerOf:nil service:service title:request.title failure:why]];
    return;
  }
  _sending = YES;
  NSDate *began = [NSDate date];
  // A client span of its own, as the store's requests have, its trace
  // passed on in the headers: at the built-in service, its own spans under it.
  NSMutableURLRequest *traced = [urlRequest mutableCopy];
  OTSpan *span = [[OTTracer tracerNamed:@"UDCode OData" version:nil] startClientSpanForRequest:traced name:request.title parent:nil];
  __weak ODWServices *weak = self;
  [service.connection sendRequest:traced done:^(ODataExchange *exchange) {
    ODWServices *me = weak;
    NSHTTPURLResponse *response = [exchange.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)exchange.URLResponse : nil;
    [span endWithResponse:exchange.URLResponse error:exchange.error];
    if (!me) return;
    me->_sending = NO;
    ODWAnswer *answer = [me answerOf:traced service:service title:request.title failure:response ? nil : (exchange.error.localizedDescription ?: @"No answer.")];
    answer.status = response.statusCode;
    answer.data = exchange.data;
    answer.duration = -[began timeIntervalSinceNow];
    [answer read];
    [me tell:answer];
    [me sendNextQueued];
  }];
}

- (void)sendWaitingOf:(ODWService *)service
{
  NSArray *waiting = [service.waiting copy];
  [service.waiting removeAllObjects];
  for (ODWRequest *request in waiting) [_queue insertObject:@[ request, service ] atIndex:0];
  [self sendNextQueued];
}

- (void)failWaitingOf:(ODWService *)service
{
  NSArray *waiting = [service.waiting copy];
  [service.waiting removeAllObjects];
  for (ODWRequest *request in waiting) {
    [self tell:[self answerOf:nil service:service title:request.title
                      failure:[NSString stringWithFormat:@"Not connected to %@: %@", service.name, service.failure ?: @"it failed"]]];
  }
}

- (ODWAnswer *)answerOf:(NSURLRequest *)request service:(ODWService *)service title:(NSString *)title failure:(NSString *)failure
{
  ODWAnswer *answer = [[ODWAnswer alloc] init];
  answer.service = service;
  answer.title = title ?: @"";
  answer.request = request;
  answer.failure = failure;
  answer.columns = @[];
  answer.text = failure ?: @"";
  return answer;
}

- (void)tell:(ODWAnswer *)answer
{
  _lastAnswer = answer;
  [[NSNotificationCenter defaultCenter] postNotificationName:ODWAnswerNotification object:self userInfo:@{ ODWAnswerKey: answer }];
  // The answer in view: the extension's segment of the bottom area.
  id<UDExtension> extension = _extension;
  if (extension && _bottomPane) [_workbench showBottomAreaViewController:_bottomPane title:@"OData" extension:extension];
}

#pragma mark The wire log

- (void)appendExchange:(WorkbenchLogEntry *)entry
{
  [_exchangeLog addEntry:entry];
  [[NSNotificationCenter defaultCenter] postNotificationName:ODWExchangeLogDidChangeNotification object:self];
}

@end
