// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerDiscovery.h"
#if defined(__APPLE__)
#import <dns_sd.h>
#import <objc/runtime.h>
#import "ODataSyncPeerTrust.h"
#import "ODataSyncPeerListener.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NSString * const ODataSyncPeerServiceType = @"_odatasync._tcp";

static NSError *ODSDiscoveryError(DNSServiceErrorType code, NSString *what)
{
  return [NSError errorWithDomain:@"ODataSyncPeerDiscovery" code:code
                         userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (dns_sd %d)", what, (int)code] }];
}

// The device's name: what a person knows it by.
static NSString *ODSDeviceName(void)
{
#if TARGET_OS_IPHONE
  __block NSString *name = nil;
  if ([NSThread isMainThread]) name = [UIDevice currentDevice].name;
  else dispatch_sync(dispatch_get_main_queue(), ^{ name = [UIDevice currentDevice].name; });
  return name;
#else
  return [NSHost currentHost].localizedName ?: [NSProcessInfo processInfo].hostName;
#endif
}

@interface ODataSyncPeerAnnouncement ()
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *replica;
@property (nonatomic, readwrite, copy) NSString *thumbprint;
@property (nonatomic, readwrite, copy) NSString *host;
@property (nonatomic, readwrite) NSUInteger port;
@property (nonatomic, readwrite, copy) NSURL *serviceRoot;
@end

@implementation ODataSyncPeerAnnouncement
- (NSString *)description
{
  return [NSString stringWithFormat:@"<peer %@ %@ at %@>", self.name, self.replica, self.serviceRoot];
}
@end

#pragma mark - Advertising

@implementation ODataSyncPeerAdvertiser {
  DNSServiceRef _service;
  NSString *_name;
  dispatch_queue_t _queue;
}

- (instancetype)initWithServer:(ODataSyncPeerServer *)server name:(NSString *)name
{
  self = [super init];
  if (!self) return nil;
  _server = server;
  _name = [name copy];
  _queue = dispatch_queue_create("ODataSync peer advertiser", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (void)dealloc
{
  [self stop];
}

static void ODSRegistered(DNSServiceRef service, DNSServiceFlags flags, DNSServiceErrorType error, const char *name, const char *type,
                          const char *domain, void *context)
{
}

- (BOOL)start:(NSError **)error
{
  if (_service) return YES;
  ODataSyncPeerTrust *trust = _server.trust;
  if (!_server.running || !trust || !_server.listener) {
    if (error) *error = ODSDiscoveryError(kDNSServiceErr_BadState, @"Only a running peer server with a trust is advertised");
    return NO;
  }
  TXTRecordRef txt;
  TXTRecordCreate(&txt, 0, NULL);
  NSDictionary *entries = @{ @"v": @"1", @"replica": _server.engine.replicaID, @"path": _server.serviceRoot.path,
                             @"thumbprint": trust.identity.thumbprint };
  for (NSString *key in entries) {
    NSData *value = [entries[key] dataUsingEncoding:NSUTF8StringEncoding];
    TXTRecordSetValue(&txt, key.UTF8String, (uint8_t)value.length, value.bytes);
  }
  NSString *name = _name ?: ODSDeviceName();
  DNSServiceErrorType status = DNSServiceRegister(&_service, 0, kDNSServiceInterfaceIndexAny, name.UTF8String, ODataSyncPeerServiceType.UTF8String,
                                                  NULL, NULL, htons((uint16_t)_server.listener.port), TXTRecordGetLength(&txt),
                                                  TXTRecordGetBytesPtr(&txt), ODSRegistered, (__bridge void *)self);
  TXTRecordDeallocate(&txt);
  if (status != kDNSServiceErr_NoError) {
    _service = NULL;
    if (error) *error = ODSDiscoveryError(status, @"The peer server could not be advertised");
    return NO;
  }
  DNSServiceSetDispatchQueue(_service, _queue);
  return YES;
}

- (void)stop
{
  if (!_service) return;
  DNSServiceRef service = _service;
  _service = NULL;
  dispatch_sync(_queue, ^{
    DNSServiceRefDeallocate(service);
  });
}

- (BOOL)isAdvertising
{
  return _service != NULL;
}

@end

#pragma mark - Browsing

// A service found, being resolved.
@interface ODSFound : NSObject
@property (nonatomic, copy) NSString *key;  // name, type, domain, interface
@property (nonatomic, copy) NSString *name;
@property (nonatomic) DNSServiceRef resolving;
@property (nonatomic, strong, nullable) ODataSyncPeerAnnouncement *announcement;
@end

@implementation ODSFound
@end

@interface ODataSyncPeerBrowser ()
- (void)found:(NSString *)name type:(NSString *)type domain:(NSString *)domain interface:(uint32_t)interface added:(BOOL)added;
- (void)resolved:(ODSFound *)found host:(NSString *)host port:(uint16_t)port txt:(NSData *)txt;
- (void)failed:(DNSServiceErrorType)error;
@end

static void ODSBrowsed(DNSServiceRef service, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error, const char *name,
                       const char *type, const char *domain, void *context)
{
  ODataSyncPeerBrowser *browser = (__bridge ODataSyncPeerBrowser *)context;
  if (error != kDNSServiceErr_NoError) {
    [browser failed:error];
    return;
  }
  [browser found:@(name) type:@(type) domain:@(domain) interface:interface added:(flags & kDNSServiceFlagsAdd) != 0];
}

static void ODSResolved(DNSServiceRef service, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error, const char *fullname,
                        const char *host, uint16_t port, uint16_t txtLength, const unsigned char *txt, void *context)
{
  ODSFound *found = (__bridge ODSFound *)context;
  ODataSyncPeerBrowser *browser = objc_getAssociatedObject(found, "browser");
  if (error != kDNSServiceErr_NoError || !browser) return;
  [browser resolved:found host:@(host) port:ntohs(port) txt:[NSData dataWithBytes:txt length:txtLength]];
}

@implementation ODataSyncPeerBrowser {
  NSString *_replica;
  DNSServiceRef _browsing;
  dispatch_queue_t _queue;
  NSMutableDictionary<NSString *, ODSFound *> *_found;
}

- (instancetype)init
{
  return [self initWithReplica:nil];
}

- (instancetype)initWithReplica:(NSString *)replica
{
  self = [super init];
  if (!self) return nil;
  _replica = [replica copy];
  _queue = dispatch_queue_create("ODataSync peer browser", DISPATCH_QUEUE_SERIAL);
  _delegateQueue = dispatch_get_main_queue();
  _found = [NSMutableDictionary dictionary];
  return self;
}

- (void)dealloc
{
  [self stop];
}

- (BOOL)start:(NSError **)error
{
  if (_browsing) return YES;
  DNSServiceErrorType status = DNSServiceBrowse(&_browsing, 0, kDNSServiceInterfaceIndexAny, ODataSyncPeerServiceType.UTF8String, NULL,
                                                ODSBrowsed, (__bridge void *)self);
  if (status != kDNSServiceErr_NoError) {
    _browsing = NULL;
    if (error) *error = ODSDiscoveryError(status, @"Peers could not be looked for");
    return NO;
  }
  DNSServiceSetDispatchQueue(_browsing, _queue);
  return YES;
}

- (void)stop
{
  if (!_browsing) return;
  DNSServiceRef browsing = _browsing;
  _browsing = NULL;
  dispatch_sync(_queue, ^{
    DNSServiceRefDeallocate(browsing);
    for (ODSFound *found in self->_found.allValues) {
      if (found.resolving) DNSServiceRefDeallocate(found.resolving);
      found.resolving = NULL;
    }
    [self->_found removeAllObjects];
  });
}

- (NSArray *)peers
{
  __block NSArray *peers = nil;
  dispatch_sync(_queue, ^{
    NSMutableDictionary *byReplica = [NSMutableDictionary dictionary];
    for (ODSFound *found in self->_found.allValues) {
      if (found.announcement) byReplica[found.announcement.replica] = found.announcement;
    }
    peers = [byReplica.allValues sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ]];
  });
  return peers;
}

#pragma mark On the queue

- (void)tell:(void (^)(id<ODataSyncPeerBrowserDelegate> delegate))message
{
  id<ODataSyncPeerBrowserDelegate> delegate = self.delegate;
  if (!delegate) return;
  dispatch_async(_delegateQueue, ^{
    message(delegate);
  });
}

- (void)failed:(DNSServiceErrorType)error
{
  NSError *failure = ODSDiscoveryError(error, @"Looking for peers failed");
  [self tell:^(id<ODataSyncPeerBrowserDelegate> delegate) {
    if ([delegate respondsToSelector:@selector(peerBrowser:didFailWithError:)]) [delegate peerBrowser:self didFailWithError:failure];
  }];
}

- (void)found:(NSString *)name type:(NSString *)type domain:(NSString *)domain interface:(uint32_t)interface added:(BOOL)added
{
  NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%u", name, type, domain, interface];
  if (!added) {
    ODSFound *lost = _found[key];
    if (!lost) return;
    [_found removeObjectForKey:key];
    if (lost.resolving) DNSServiceRefDeallocate(lost.resolving);
    lost.resolving = NULL;
    ODataSyncPeerAnnouncement *announcement = lost.announcement;
    // Lost only when no other interface still has it.
    BOOL still = NO;
    for (ODSFound *other in _found.allValues) still = still || [other.announcement.replica isEqualToString:announcement.replica];
    if (announcement && !still) {
      [self tell:^(id<ODataSyncPeerBrowserDelegate> delegate) {
        [delegate peerBrowser:self didLosePeer:announcement];
      }];
    }
    return;
  }
  if (_found[key]) return;
  ODSFound *found = [[ODSFound alloc] init];
  found.key = key;
  found.name = name;
  objc_setAssociatedObject(found, "browser", self, OBJC_ASSOCIATION_ASSIGN);
  _found[key] = found;
  DNSServiceRef resolving = NULL;
  DNSServiceErrorType status = DNSServiceResolve(&resolving, 0, interface, name.UTF8String, type.UTF8String, domain.UTF8String,
                                                 ODSResolved, (__bridge void *)found);
  if (status == kDNSServiceErr_NoError) {
    found.resolving = resolving;
    DNSServiceSetDispatchQueue(resolving, _queue);
  }
}

static NSString *ODSTXTValue(NSData *txt, const char *key)
{
  uint8_t length = 0;
  const void *value = TXTRecordGetValuePtr((uint16_t)txt.length, txt.bytes, key, &length);
  return value ? [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding] : nil;
}

- (void)resolved:(ODSFound *)found host:(NSString *)host port:(uint16_t)port txt:(NSData *)txt
{
  if (found.resolving) {
    DNSServiceRefDeallocate(found.resolving);
    found.resolving = NULL;
  }
  NSString *replica = ODSTXTValue(txt, "replica"), *path = ODSTXTValue(txt, "path"), *thumbprint = ODSTXTValue(txt, "thumbprint");
  if (!replica.length || !path.length || !thumbprint.length || [replica isEqualToString:_replica] || !_found[found.key]) return;
  if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
  NSURL *root = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@:%u%@%@", host, port, path, [path hasSuffix:@"/"] ? @"" : @"/"]];
  if (!root) return;
  ODataSyncPeerAnnouncement *announcement = [[ODataSyncPeerAnnouncement alloc] init];
  announcement.name = found.name;
  announcement.replica = replica;
  announcement.thumbprint = thumbprint;
  announcement.host = host;
  announcement.port = port;
  announcement.serviceRoot = root;
  BOOL known = NO;
  for (ODSFound *other in _found.allValues) known = known || (other != found && [other.announcement.replica isEqualToString:replica]);
  found.announcement = announcement;
  if (known) return;
  [self tell:^(id<ODataSyncPeerBrowserDelegate> delegate) {
    [delegate peerBrowser:self didFindPeer:announcement];
  }];
}

@end
#endif
