// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The listener on GnuTLS, over sockets, listening on IPv6 and IPv4 alike.
// Each relay has two threads, one a direction (GnuTLS lets one thread
// send while another receives on a session): neither waits on the other,
// and a socket idle too long ends the relay. At most ODSMostRelays at once.

#import <ODataSync/ODataSyncPeerListener.h>
#import "ODSLinuxSystem.h"
#include <gnutls/gnutls.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// Relays at once: a connection past them is closed as it comes.
static const NSUInteger ODSMostRelays = 64;
// A handshake's time; a socket's idle time (nothing read, nothing sent).
static const int ODSHandshakeMilliseconds = 10000;
static const time_t ODSIdleSeconds = 300;

static NSError *ODSListenerError(NSString *what, int code)
{
  return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                         userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (%s)", what, strerror(code)] }];
}

static NSError *ODSListenerTLSError(NSString *what, int code)
{
  return [NSError errorWithDomain:@"GnuTLS" code:code
                         userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (%s)", what, gnutls_strerror(code)] }];
}

// All of it sent, or NO.
static BOOL ODSSendAll(int fd, const uint8_t *bytes, size_t length)
{
  while (length) {
    ssize_t n = send(fd, bytes, length, MSG_NOSIGNAL);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return NO;
    bytes += n;
    length -= (size_t)n;
  }
  return YES;
}

static BOOL ODSRecordSendAll(gnutls_session_t session, const uint8_t *bytes, size_t length)
{
  while (length) {
    ssize_t n = gnutls_record_send(session, bytes, length);
    if (n == GNUTLS_E_INTERRUPTED) continue;
    if (n <= 0) return NO;  // (GNUTLS_E_AGAIN: the send timed out)
    bytes += n;
    length -= (size_t)n;
  }
  return YES;
}

// Reads and writes on fd give up after the idle time.
static void ODSIdleTimeouts(int fd)
{
  struct timeval idle = { .tv_sec = ODSIdleSeconds, .tv_usec = 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &idle, sizeof idle);
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &idle, sizeof idle);
}

// One client's connection, and its relay to the server: each socket open
// until closed is set, the session until its last thread is done (all
// under the listener's lock).
@interface ODSRelay : NSObject
@property (nonatomic) int client;
@property (nonatomic) int server;
@property (nonatomic) gnutls_session_t session;
@property (nonatomic) BOOL handshaken;
@property (nonatomic) NSUInteger threads;
@property (nonatomic, copy, nullable) NSString *address;     // the relay's, as the server sees it
@property (nonatomic, copy, nullable) NSString *thumbprint;  // the client's certificate's
@property (nonatomic) BOOL closed;
@end

@implementation ODSRelay
@end

static char ODSListenerQueueKey;

@implementation ODataSyncPeerListener {
  dispatch_source_t _accepting;
  dispatch_queue_t _queue;
  gnutls_certificate_credentials_t _credentials;
  gnutls_priority_t _priority;
  NSMutableSet<ODSRelay *> *_relays;                          // under @synchronized (_relays)
  NSMutableDictionary<NSString *, NSString *> *_thumbprints;  // relay address -> thumbprint; the same
}

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity backendPort:(NSUInteger)backendPort
{
  self = [super init];
  if (!self) return nil;
  _identity = identity;
  _backendPort = backendPort;
  _queue = dispatch_queue_create("ODataSync peer listener", DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(_queue, &ODSListenerQueueKey, (__bridge void *)self, NULL);
  _relays = [NSMutableSet set];
  _thumbprints = [NSMutableDictionary dictionary];
  return self;
}

- (void)dealloc
{
  [self stop];
  if (_credentials) gnutls_certificate_free_credentials(_credentials);
  if (_priority) gnutls_priority_deinit(_priority);
  dispatch_release(_queue);
}

#pragma mark Listening

// On every address, IPv6 and IPv4 both where the system has IPv6.
static int ODSListen(NSUInteger port, NSUInteger *bound, int *failure)
{
  int one = 1, zero = 0;
  int fd = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd >= 0) {
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof zero);
    struct sockaddr_in6 address = { .sin6_family = AF_INET6, .sin6_port = htons((uint16_t)port), .sin6_addr = in6addr_any };
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0) {
      close(fd);
      fd = -1;
    }
  }
  if (fd < 0) {
    fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
      *failure = errno;
      return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0) {
      *failure = errno;
      close(fd);
      return -1;
    }
  }
  if (listen(fd, 16) != 0) {
    *failure = errno;
    close(fd);
    return -1;
  }
  struct sockaddr_storage address;
  socklen_t length = sizeof address;
  getsockname(fd, (struct sockaddr *)&address, &length);
  *bound = ntohs(address.ss_family == AF_INET6 ? ((struct sockaddr_in6 *)&address)->sin6_port : ((struct sockaddr_in *)&address)->sin_port);
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  return fd;
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
  if (_accepting) return YES;
  if (!_credentials) {
    gnutls_certificate_allocate_credentials(&_credentials);
    int status = gnutls_certificate_set_x509_key_file2(_credentials, _identity.system.certificateURL.path.fileSystemRepresentation,
                                                       _identity.system.keyURL.path.fileSystemRepresentation, GNUTLS_X509_FMT_PEM, NULL, 0);
    if (status < 0) {
      gnutls_certificate_free_credentials(_credentials);
      _credentials = NULL;
      if (error) *error = ODSListenerTLSError(@"The identity does not load", status);
      return NO;
    }
  }
  // TLS 1.2 at least.
  if (!_priority) {
    int status = gnutls_priority_init(&_priority, "NORMAL:-VERS-ALL:+VERS-TLS1.3:+VERS-TLS1.2", NULL);
    if (status < 0) {
      _priority = NULL;
      if (error) *error = ODSListenerTLSError(@"TLS could not be set up", status);
      return NO;
    }
  }
  int failure = 0;
  NSUInteger bound = 0;
  int fd = ODSListen(port, &bound, &failure);
  if (fd < 0) {
    if (error) *error = ODSListenerError(@"The listener did not start", failure);
    return NO;
  }
  _port = bound;
  dispatch_source_t accepting = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
  __weak ODataSyncPeerListener *weak = self;
  dispatch_source_set_event_handler(accepting, ^{
    [weak acceptOn:fd source:accepting];
  });
  dispatch_source_set_cancel_handler(accepting, ^{
    close(fd);
  });
  dispatch_resume(accepting);
  _accepting = accepting;
  return YES;
}

- (void)stop
{
  dispatch_source_t accepting = _accepting;
  _accepting = nil;
  if (accepting) {
    // Closed before this returns (the port free to listen on again): its
    // cancel handler run, after any accept under way.
    dispatch_source_cancel(accepting);
    if (dispatch_get_specific(&ODSListenerQueueKey) != (__bridge void *)self) dispatch_sync(_queue, ^{});
    dispatch_release(accepting);
  }
  // Each relay's threads find their sockets shut, and end.
  @synchronized (_relays) {
    for (ODSRelay *relay in _relays) {
      if (relay.closed) continue;
      shutdown(relay.client, SHUT_RDWR);
      if (relay.server >= 0) shutdown(relay.server, SHUT_RDWR);
    }
    [_thumbprints removeAllObjects];
  }
}

- (BOOL)isRunning
{
  return _accepting != nil;
}

- (NSString *)thumbprintOfConnectionFrom:(NSString *)remoteAddress
{
  if (!remoteAddress) return nil;
  @synchronized (_relays) {
    return _thumbprints[remoteAddress];
  }
}

- (NSUInteger)connectionCount
{
  @synchronized (_relays) {
    return _relays.count;
  }
}

#pragma mark Relaying

- (void)acceptOn:(int)listening source:(dispatch_source_t)source
{
  for (;;) {
    int fd = accept(listening, NULL, NULL);
    if (fd >= 0) {
      // Blocking (the BSDs pass the listener's O_NONBLOCK on), not inherited.
      fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
      fcntl(fd, F_SETFD, FD_CLOEXEC);
    }
    if (fd < 0) {
      // Out of descriptors: the source would fire again at once, and spin.
      // Rest a second, then take what waits.
      if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM) {
        dispatch_suspend(source);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _queue, ^{
          dispatch_resume(source);
        });
      }
      return;  // else EAGAIN: all taken
    }
    ODSRelay *relay = nil;
    @synchronized (_relays) {
      if (_relays.count < ODSMostRelays) {
        relay = [[ODSRelay alloc] init];
        relay.client = fd;
        relay.server = -1;
        relay.threads = 1;
        [_relays addObject:relay];
      }
    }
    if (!relay) {
      close(fd);
      continue;
    }
    ODSIdleTimeouts(fd);
    [NSThread detachNewThreadSelector:@selector(relay:) toTarget:self withObject:relay];
  }
}

// A thread's: the handshake, the client's certificate, the server's
// connection, known by its address before a byte goes; then this thread
// carries the client's bytes to the server, another the server's back.
- (void)relay:(ODSRelay *)relay
{
  @autoreleasepool {
    gnutls_session_t session = NULL;
    // A full handshake every time: no tickets (and no session cache), so
    // no session resumed from another, which presents no certificate. No
    // SIGPIPE for a client gone.
    gnutls_init(&session, GNUTLS_SERVER | GNUTLS_NO_TICKETS | GNUTLS_NO_SIGNAL);
    gnutls_priority_set(session, _priority);
    gnutls_credentials_set(session, GNUTLS_CRD_CERTIFICATE, _credentials);
    // A certificate asked for and taken as it is (no authority checks it):
    // the authenticator decides what it is worth. TLS proves the client
    // holds its key.
    gnutls_certificate_server_set_request(session, GNUTLS_CERT_REQUIRE);
    gnutls_transport_set_int(session, relay.client);
    gnutls_handshake_set_timeout(session, ODSHandshakeMilliseconds);
    relay.session = session;
    int status;
    do {
      status = gnutls_handshake(session);
    } while (status < 0 && !gnutls_error_is_fatal(status));
    relay.handshaken = status >= 0;
    unsigned int count = 0;
    const gnutls_datum_t *chain = status >= 0 ? gnutls_certificate_get_peers(session, &count) : NULL;
    if (chain && count) {
      relay.thumbprint = [ODataSyncPeerIdentity thumbprintOfCertificateData:[NSData dataWithBytes:chain[0].data length:chain[0].size]];
    }
    if (relay.thumbprint && [self connectServerFor:relay]) {
      @synchronized (_relays) {
        relay.threads++;
      }
      [NSThread detachNewThreadSelector:@selector(relayBack:) toTarget:self withObject:relay];
      [self pumpFromClient:relay];
    }
    [self endThreadOf:relay];
  }
}

// The server's bytes to the client.
- (void)relayBack:(ODSRelay *)relay
{
  @autoreleasepool {
    uint8_t buffer[64 * 1024];
    for (;;) {
      ssize_t n = recv(relay.server, buffer, sizeof buffer, 0);
      if (n < 0 && errno == EINTR) continue;
      // Done (0), idle too long (EAGAIN), or broken.
      if (n <= 0 || !ODSRecordSendAll(relay.session, buffer, (size_t)n)) break;
    }
    [self endThreadOf:relay];
  }
}

// The client's bytes to the server.
- (void)pumpFromClient:(ODSRelay *)relay
{
  uint8_t buffer[64 * 1024];
  for (;;) {
    ssize_t n = gnutls_record_recv(relay.session, buffer, sizeof buffer);
    if (n == GNUTLS_E_INTERRUPTED || n == GNUTLS_E_REHANDSHAKE) continue;
    // Done (0, or the client gone without a close_notify), idle too long
    // (GNUTLS_E_AGAIN), or broken: so is the relay (HTTP over it has no
    // half-close worth keeping).
    if (n <= 0 || !ODSSendAll(relay.server, buffer, (size_t)n)) return;
  }
}

- (BOOL)connectServerFor:(ODSRelay *)relay
{
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return NO;
  struct sockaddr_in backend = { .sin_family = AF_INET, .sin_port = htons((uint16_t)_backendPort), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
  struct sockaddr_in local;
  socklen_t length = sizeof local;
  if (connect(fd, (struct sockaddr *)&backend, sizeof backend) != 0 || getsockname(fd, (struct sockaddr *)&local, &length) != 0) {
    close(fd);
    return NO;
  }
  ODSIdleTimeouts(fd);
  @synchronized (_relays) {
    if (relay.closed || !_accepting) {
      close(fd);
      return NO;
    }
    relay.server = fd;
    relay.address = [NSString stringWithFormat:@"127.0.0.1:%u", ntohs(local.sin_port)];
    _thumbprints[relay.address] = relay.thumbprint;
  }
  return YES;
}

// One of the relay's threads done: the relay too (its sockets shut, so the
// other one ends), and the last one closes it.
- (void)endThreadOf:(ODSRelay *)relay
{
  BOOL last = NO;
  @synchronized (_relays) {
    if (!relay.closed) {
      relay.closed = YES;
      if (relay.address) [_thumbprints removeObjectForKey:relay.address];
      shutdown(relay.client, SHUT_RDWR);
      if (relay.server >= 0) shutdown(relay.server, SHUT_RDWR);
    }
    last = --relay.threads == 0;
    if (last) [_relays removeObject:relay];
  }
  if (!last) return;
  if (relay.handshaken) gnutls_bye(relay.session, GNUTLS_SHUT_WR);
  gnutls_deinit(relay.session);
  close(relay.client);
  if (relay.server >= 0) close(relay.server);
}

@end
