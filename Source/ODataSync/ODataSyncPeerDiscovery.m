// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSyncPeerDiscovery.h"
#import <dns_sd.h>
#import <objc/runtime.h>
#import "ODataSyncPeerTrust.h"
#import "ODataSyncPeerListener.h"
#import "ODSSystem.h"
#include <arpa/inet.h>

NSString * const ODataSyncPeerServiceType = @"_odatasync._tcp";

static NSError *ODSDiscoveryError(DNSServiceErrorType code, NSString *what)
{
  return [NSError errorWithDomain:@"ODataSyncPeerDiscovery" code:code
                         userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (dns_sd %d)", what, (int)code] }];
}

// A DNSServiceRef's answers, read on a queue: its socket, a dispatch
// source over it. (Not DNSServiceSetDispatchQueue: Apple's alone, and
// Avahi's dns_sd has none.) Cancelled, the reference is deallocated once
// the source is done with it, so a callback may cancel its own.
@interface ODSWatch : NSObject
+ (nullable instancetype)watch:(DNSServiceRef)service queue:(dispatch_queue_t)queue;
- (void)cancel;
@end

@implementation ODSWatch {
  dispatch_source_t _source;
}

+ (instancetype)watch:(DNSServiceRef)service queue:(dispatch_queue_t)queue
{
  int fd = DNSServiceRefSockFD(service);
  if (fd < 0) {
    DNSServiceRefDeallocate(service);
    return nil;
  }
  ODSWatch *watch = [[self alloc] init];
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
  __weak ODSWatch *weak = watch;
  dispatch_source_set_event_handler(source, ^{
    // The daemon gone: no more answers, not a loop of failures.
    if (DNSServiceProcessResult(service) != kDNSServiceErr_NoError) [weak cancel];
  });
  dispatch_source_set_cancel_handler(source, ^{
    DNSServiceRefDeallocate(service);
  });
  watch->_source = source;
  dispatch_resume(source);
  return watch;
}

- (void)dealloc
{
  [self cancel];
}

- (void)cancel
{
  dispatch_source_t source = _source;
  _source = nil;
  if (source) dispatch_source_cancel(source);
}

@end

// A block, as an operation's target (NSInvocationOperation: GNUstep has
// NSBlockOperation as not portable).
@interface ODSMessage : NSObject
@property (nonatomic, copy) void (^block)(void);
- (void)send;
@end

@implementation ODSMessage
- (void)send
{
  self.block();
}
@end

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
  ODSWatch *_registration;
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
  if (_registration) return YES;
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
  NSString *name = _name ?: ODSSystemDeviceName();
  DNSServiceRef service = NULL;
  DNSServiceErrorType status = DNSServiceRegister(&service, 0, kDNSServiceInterfaceIndexAny, name.UTF8String, ODataSyncPeerServiceType.UTF8String,
                                                  NULL, NULL, htons((uint16_t)_server.listener.port), TXTRecordGetLength(&txt),
                                                  TXTRecordGetBytesPtr(&txt), ODSRegistered, (__bridge void *)self);
  TXTRecordDeallocate(&txt);
  if (status != kDNSServiceErr_NoError) {
    if (error) *error = ODSDiscoveryError(status, @"The peer server could not be advertised (on Linux: is avahi-daemon running?)");
    return NO;
  }
  _registration = [ODSWatch watch:service queue:_queue];
  if (!_registration) {
    if (error) *error = ODSDiscoveryError(kDNSServiceErr_Unknown, @"The peer server's advertisement cannot be followed");
    return NO;
  }
  return YES;
}

- (void)stop
{
  ODSWatch *registration = _registration;
  _registration = nil;
  if (!registration) return;
  dispatch_sync(_queue, ^{
    [registration cancel];
  });
}

- (BOOL)isAdvertising
{
  return _registration != nil;
}

@end

#pragma mark - Browsing

// A service found, being resolved (and, where the system resolves no .local
// names, its host looked up).
@interface ODSFound : NSObject
@property (nonatomic, copy) NSString *key;  // name, type, domain, interface
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t interface;
@property (nonatomic, strong, nullable) ODSWatch *resolving;
@property (nonatomic, strong, nullable) ODSWatch *lookingUp;
@property (nonatomic) uint16_t port;
@property (nonatomic, copy, nullable) NSData *txt;
@property (nonatomic, strong, nullable) ODataSyncPeerAnnouncement *announcement;
@end

@implementation ODSFound
- (void)cancel
{
  [self.resolving cancel];
  [self.lookingUp cancel];
  self.resolving = nil;
  self.lookingUp = nil;
}
@end

@interface ODataSyncPeerBrowser ()
- (void)found:(NSString *)name type:(NSString *)type domain:(NSString *)domain interface:(uint32_t)interface added:(BOOL)added;
- (void)resolved:(ODSFound *)found host:(NSString *)host port:(uint16_t)port txt:(NSData *)txt;
- (void)announce:(ODSFound *)found host:(NSString *)host;
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

// The host's IPv4 address (an A record), where the system resolves no
// .local names (Linux without nss-mdns; Avahi's dns_sd has no
// DNSServiceGetAddrInfo either).
static void ODSLookedUp(DNSServiceRef service, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error, const char *fullname,
                        uint16_t type, uint16_t rrclass, uint16_t length, const void *data, uint32_t ttl, void *context)
{
  ODSFound *found = (__bridge ODSFound *)context;
  ODataSyncPeerBrowser *browser = objc_getAssociatedObject(found, "browser");
  if (error != kDNSServiceErr_NoError || !browser || type != kDNSServiceType_A || length != 4 || !(flags & kDNSServiceFlagsAdd)) return;
  char text[INET_ADDRSTRLEN];
  if (!inet_ntop(AF_INET, data, text, sizeof text)) return;
  [browser announce:found host:@(text)];
}

@implementation ODataSyncPeerBrowser {
  NSString *_replica;
  ODSWatch *_browsing;
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
  _delegateQueue = [NSOperationQueue mainQueue];
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
  DNSServiceRef browsing = NULL;
  DNSServiceErrorType status = DNSServiceBrowse(&browsing, 0, kDNSServiceInterfaceIndexAny, ODataSyncPeerServiceType.UTF8String, NULL,
                                                ODSBrowsed, (__bridge void *)self);
  if (status != kDNSServiceErr_NoError) {
    if (error) *error = ODSDiscoveryError(status, @"Peers could not be looked for (on Linux: is avahi-daemon running?)");
    return NO;
  }
  _browsing = [ODSWatch watch:browsing queue:_queue];
  if (!_browsing) {
    if (error) *error = ODSDiscoveryError(kDNSServiceErr_Unknown, @"Looking for peers cannot be followed");
    return NO;
  }
  return YES;
}

- (void)stop
{
  ODSWatch *browsing = _browsing;
  _browsing = nil;
  if (!browsing) return;
  dispatch_sync(_queue, ^{
    [browsing cancel];
    for (ODSFound *found in self->_found.allValues) [found cancel];
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
  ODSMessage *run = [[ODSMessage alloc] init];
  run.block = ^{
    message(delegate);
  };
  [_delegateQueue addOperation:[[NSInvocationOperation alloc] initWithTarget:run selector:@selector(send) object:nil]];
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
    [lost cancel];
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
  found.interface = interface;
  objc_setAssociatedObject(found, "browser", self, OBJC_ASSOCIATION_ASSIGN);
  _found[key] = found;
  DNSServiceRef resolving = NULL;
  DNSServiceErrorType status = DNSServiceResolve(&resolving, 0, interface, name.UTF8String, type.UTF8String, domain.UTF8String,
                                                 ODSResolved, (__bridge void *)found);
  if (status == kDNSServiceErr_NoError) found.resolving = [ODSWatch watch:resolving queue:_queue];
}

static NSString *ODSTXTValue(NSData *txt, const char *key)
{
  uint8_t length = 0;
  const void *value = TXTRecordGetValuePtr((uint16_t)txt.length, txt.bytes, key, &length);
  return value ? [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding] : nil;
}

- (void)resolved:(ODSFound *)found host:(NSString *)host port:(uint16_t)port txt:(NSData *)txt
{
  [found.resolving cancel];
  found.resolving = nil;
  if (!_found[found.key]) return;
  found.port = port;
  found.txt = txt;
  if (ODSSystemResolvesLocalNames()) {
    [self announce:found host:host];
    return;
  }
  DNSServiceRef lookingUp = NULL;
  DNSServiceErrorType status = DNSServiceQueryRecord(&lookingUp, 0, found.interface, host.UTF8String, kDNSServiceType_A, kDNSServiceClass_IN,
                                                     ODSLookedUp, (__bridge void *)found);
  if (status == kDNSServiceErr_NoError) found.lookingUp = [ODSWatch watch:lookingUp queue:_queue];
}

- (void)announce:(ODSFound *)found host:(NSString *)host
{
  [found.lookingUp cancel];
  found.lookingUp = nil;
  NSData *txt = found.txt;
  uint16_t port = found.port;
  NSString *replica = ODSTXTValue(txt, "replica"), *path = ODSTXTValue(txt, "path"), *thumbprint = ODSTXTValue(txt, "thumbprint");
  if (!replica.length || !path.length || !thumbprint.length || [replica isEqualToString:_replica] || !_found[found.key]) return;
  if (found.announcement) return;
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
