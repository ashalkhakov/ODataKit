// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBConnection.h"
#import "WorkbenchSupport.h"
#import <ODataService/ODataServer.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

static NSString * const WBBuiltInRoot = @"http://workbench.local/odata/";
static NSString * const WBNorthwindRoot = @"https://services.odata.org/V4/Northwind/Northwind.svc/";
static NSString * const WBTripPinRoot = @"https://services.odata.org/V4/TripPinServiceRW/";

static NSURL *WorkbenchModelURL(void)
{
  NSBundle *bundle = [NSBundle mainBundle];
  for (NSString *ext in @[ @"momd", @"xcdatamodeld" ]) {
    NSURL *url = [bundle URLForResource:@"Catalog" withExtension:ext];
    if (url) return url;
  }
#ifdef WORKBENCH_MODEL_DIR
  NSString *src = [@(WORKBENCH_MODEL_DIR) stringByAppendingPathComponent:@"Catalog.xcdatamodeld"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:src]) return [NSURL fileURLWithPath:src];
  src = [@(WORKBENCH_MODEL_DIR) stringByAppendingPathComponent:@"../Catalog/Catalog.xcdatamodeld"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:src]) return [NSURL fileURLWithPath:src];
#endif
  return nil;
}

// TripPin keeps what a client writes in a session of its own, named in
// the URL; a new one starts from TripPin's sample data.
static NSURL *WBTripPinSession(void)
{
  NSMutableString *key = [NSMutableString stringWithString:@"oiswb"];
  const char *alphabet = "abcdefghijklmnopqrstuvwxyz012345";
  while (key.length < 24) [key appendFormat:@"%c", alphabet[arc4random_uniform(32)]];
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://services.odata.org/V4/(S(%@))/TripPinServiceRW/", key]];
}

// This machine's address on the local network: the first IPv4 address of
// an interface that is up and not the loopback (en0 first); nil for none.
static NSString *WBLocalAddress(void)
{
  struct ifaddrs *list = NULL;
  if (getifaddrs(&list) != 0) return nil;
  NSString *found = nil;
  for (int pass = 0; pass < 2 && !found; pass++) {
    for (struct ifaddrs *each = list; each && !found; each = each->ifa_next) {
      if (!each->ifa_addr || each->ifa_addr->sa_family != AF_INET) continue;
      if (!(each->ifa_flags & IFF_UP) || (each->ifa_flags & IFF_LOOPBACK)) continue;
      if (pass == 0 && strcmp(each->ifa_name, "en0") != 0) continue;
      char text[INET_ADDRSTRLEN];
      const struct sockaddr_in *address = (const struct sockaddr_in *)(const void *)each->ifa_addr;
      if (inet_ntop(AF_INET, &address->sin_addr, text, sizeof text)) found = @(text);
    }
  }
  freeifaddrs(list);
  return found;
}

@implementation WBConnection {
  id _wire;  // the transport in use: the engine, or a network transport
  HSServer *_server;
}

+ (NSString *)rootOfService:(WBService)service
{
  switch (service) {
    case WBServiceBuiltIn: return WBBuiltInRoot;
    case WBServiceNorthwind: return WBNorthwindRoot;
    case WBServiceTripPin: return WBTripPinRoot;
    case WBServiceOther: return nil;
  }
  return nil;
}

+ (WBService)serviceOfRoot:(NSString *)root
{
  NSUInteger index = [@[ WBBuiltInRoot, WBNorthwindRoot, WBTripPinRoot ] indexOfObject:root];
  return index == NSNotFound ? WBServiceOther : (WBService)index;
}

- (instancetype)init
{
  if ((self = [super init])) {
    _JSONBatch = YES;
    _servePort = 8640;
  }
  return self;
}

- (void)dealloc
{
  _engine.didHandle = nil;
  [_server stop];
}

// The root the built-in service has: its own made-up one, or the network's
// while served.
- (NSURL *)builtInRoot
{
  [_server stop];
  _server = nil;
  _servedRoot = nil;
  _serveFailure = nil;
  if (!_servesNetwork) return [NSURL URLWithString:WBBuiltInRoot];
  NSString *address = WBLocalAddress();
  if (!address) {
    _serveFailure = @"this Mac has no address on a network";
    return [NSURL URLWithString:WBBuiltInRoot];
  }
  return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%lu/odata/", address, (unsigned long)_servePort]];
}

- (void)serve
{
  if (!_servesNetwork || _serveFailure || !_engine) return;
  HSServer *server = [[HSServer alloc] initWithService:_engine.service];
  server.bindToLocalhost = NO;
  NSError *error = nil;
  if (![server startOnPort:_servePort error:&error]) {
    _serveFailure = error.localizedDescription ?: @"the server did not start";
    return;
  }
  _server = server;
  _servedRoot = _engine.serviceRoot;
}

- (NSUInteger)exchangesStarted
{
  return [[_wire valueForKey:@"started"] unsignedIntegerValue];
}

- (NSDictionary *)storeOptionsWithTransport:(id)transport
{
  NSMutableDictionary *options = [@{ ODataIncrementalStoreTransportOption: transport, NSPersistentHistoryTrackingKey: @YES,
                                     ODataIncrementalStoreRespondAsyncOption: @(_respondAsync),
                                     ODataIncrementalStoreJSONBatchOption: @(_JSONBatch) } mutableCopy];
  // Signed in: asked for credentials once the service refuses a request.
  if (_credentialProvider && _service != WBServiceBuiltIn) options[ODataIncrementalStoreCredentialProviderOption] = _credentialProvider;
  return options;
}

// Each exchange, to the target, on the main thread.
- (void)logEntry:(WorkbenchLogEntry *)entry
{
  WBSend(_target, _logAction, entry);
}

- (NSString *)connectToService:(WBService)service root:(NSString *)root
{
  if (_connecting) return @"Still connecting.";
  _service = service;
  _failure = nil;
  if (service != WBServiceBuiltIn) {
    [_server stop];
    _server = nil;
    _servedRoot = nil;
  }
  if (service == WBServiceBuiltIn) {
    [self openBuiltIn];
    return nil;
  }
  NSString *typed = [root stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (typed.length && ![typed hasSuffix:@"/"]) typed = [typed stringByAppendingString:@"/"];
  NSURL *url = service == WBServiceTripPin ? WBTripPinSession() : [NSURL URLWithString:typed];
  if (!url.scheme.length || !url.host.length) return @"That is not a service root URL (https://host/path/).";
  _connecting = YES;
  WorkbenchNetworkTransport *transport = [[WorkbenchNetworkTransport alloc] init];
  __weak WBConnection *weak = self;
  transport.didHandle = ^(WorkbenchLogEntry *entry) {
    [weak logEntry:entry];
  };
  _wire = transport;
  _engine = nil;
  [NSThread detachNewThreadSelector:@selector(connectInBackground:) toTarget:self withObject:@{ @"url": url, @"transport": transport }];
  return nil;
}

- (void)openBuiltIn
{
  NSURL *root = [self builtInRoot];
  NSURL *modelURL = WorkbenchModelURL();
  NSManagedObjectModel *model = modelURL ? WorkbenchBuiltInModel(modelURL) : nil;
  if (!model) {
    [self finishWithModel:nil coordinator:nil store:nil root:root error:WBError(9, @"Catalog.xcdatamodeld not found.")];
    return;
  }
  // A picture's content and its type are its media resource's, not
  // properties: the client reads them as a stream.
  NSEntityDescription *picture = model.entitiesByName[@"Picture"];
  NSMutableArray *kept = [NSMutableArray array];
  for (NSPropertyDescription *property in picture.properties) {
    if (![@[ @"content", @"contentType" ] containsObject:property.name]) [kept addObject:property];
  }
  picture.properties = kept;
  _engine = [[WorkbenchEngine alloc] initWithServiceRoot:root modelURL:modelURL];
  if (!_engine) {
    [self finishWithModel:nil coordinator:nil store:nil root:root error:WBError(9, @"The built-in service did not start.")];
    return;
  }
  __weak WBConnection *weak = self;
  _engine.didHandle = ^(WorkbenchLogEntry *entry) {
    [weak logEntry:entry];
  };
  _wire = _engine;
  [self serve];
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  // The configuration the service serves: the client's store holds it.
  ODataIncrementalStore *store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                                             configuration:WorkbenchServedConfiguration URL:root
                                                                                   options:[self storeOptionsWithTransport:_engine] error:&error];
  [self finishWithModel:model coordinator:psc store:store root:root error:error];
}

// Connecting reads $metadata twice (for the model, then for the store), so
// it happens away from the main thread.
- (void)connectInBackground:(NSDictionary *)job
{
  @autoreleasepool {
    NSURL *url = job[@"url"];
    NSDictionary *options = [self storeOptionsWithTransport:job[@"transport"]];
    NSError *error = nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:url forKey:@"url"];
    NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:url options:options error:&error];
    if (model) {
      NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
      ODataIncrementalStore *store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                                                 configuration:nil URL:url options:options error:&error];
      result[@"model"] = model;
      result[@"coordinator"] = psc;
      if (store) result[@"store"] = store;
    }
    if (error) result[@"error"] = error;
    [self performSelectorOnMainThread:@selector(connected:) withObject:result waitUntilDone:NO];
  }
}

- (void)connected:(NSDictionary *)result
{
  _connecting = NO;
  [self finishWithModel:result[@"model"] coordinator:result[@"coordinator"] store:result[@"store"] root:result[@"url"] error:result[@"error"]];
}

- (void)finishWithModel:(NSManagedObjectModel *)model coordinator:(NSPersistentStoreCoordinator *)psc
                  store:(ODataIncrementalStore *)store root:(NSURL *)root error:(NSError *)error
{
  _serviceRoot = root;
  if (!store) {
    NSString *why = error.localizedDescription ?: @"the store could not be opened";
    NSError *cause = error.userInfo[NSUnderlyingErrorKey];
    if (cause.localizedDescription.length) why = [NSString stringWithFormat:@"%@ (%@)", why, cause.localizedDescription];
    _failure = why;
    WBSend(_target, _connectedAction, self);
    return;
  }
  _model = model;
  _store = store;
  _context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  _context.persistentStoreCoordinator = psc;
  _context.transactionAuthor = @"Workbench";
  self.mergePolicy = _mergePolicy;
  WBSend(_target, _connectedAction, self);
}

- (void)setMergePolicy:(NSInteger)mergePolicy
{
  _mergePolicy = mergePolicy;
  _context.mergePolicy = mergePolicy == 1 ? NSMergeByPropertyObjectTrumpMergePolicy
                       : mergePolicy == 2 ? NSMergeByPropertyStoreTrumpMergePolicy : NSErrorMergePolicy;
}

- (NSString *)summary
{
  NSUInteger operations = 0;
  for (NSArray *overloads in _store.schema.operations.allValues) operations += overloads.count;
  NSMutableString *summary = [NSMutableString stringWithFormat:@"%@: %lu entities, %lu operations, OData %@.",
                              _service == WBServiceBuiltIn ? @"Built-in service" : _serviceRoot.absoluteString,
                              (unsigned long)_model.entities.count, (unsigned long)operations, _store.schema.version ?: @"4.0"];
  if (_service == WBServiceTripPin) [summary appendString:@" A session of its own: write freely."];
  if (_service == WBServiceBuiltIn && _servedRoot) {
    [summary appendFormat:@" Served on the network at %@ (no authentication): the Device app syncs with it.", _servedRoot.absoluteString];
  }
  if (_service == WBServiceBuiltIn && _servesNetwork && _serveFailure) [summary appendFormat:@" Not served on the network: %@.", _serveFailure];
  if (_service == WBServiceNorthwind) [summary appendString:@" Read-only."];
  return summary;
}

@end
