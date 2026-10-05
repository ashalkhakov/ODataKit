// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The listener on GnuTLS, over sockets: a thread for each connection,
// listening on IPv6 and IPv4 alike.

#import <ODataSync/ODataSyncPeerListener.h>
#import "ODSLinuxSystem.h"
#include <gnutls/gnutls.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

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
    if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED) continue;
    if (n <= 0) return NO;
    bytes += n;
    length -= (size_t)n;
  }
  return YES;
}

// One client's connection, and its relay to the server: each socket open
// until closed is set (under the listener's lock).
@interface ODSRelay : NSObject
@property (nonatomic) int client;
@property (nonatomic) int server;
@property (nonatomic, copy, nullable) NSString *address;     // the relay's, as the server sees it
@property (nonatomic, copy, nullable) NSString *thumbprint;  // the client's certificate's
@property (nonatomic) BOOL closed;
@end

@implementation ODSRelay
@end

@implementation ODataSyncPeerListener {
  int _socket;
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
  _socket = -1;
  _queue = dispatch_queue_create("ODataSync peer listener", DISPATCH_QUEUE_SERIAL);
  _relays = [NSMutableSet set];
  _thumbprints = [NSMutableDictionary dictionary];
  return self;
}

- (void)dealloc
{
  [self stop];
  if (_credentials) gnutls_certificate_free_credentials(_credentials);
  if (_priority) gnutls_priority_deinit(_priority);
}

#pragma mark Listening

// On every address, IPv6 and IPv4 both where the system has IPv6.
static int ODSListen(NSUInteger port, NSUInteger *bound, int *failure)
{
  int one = 1, zero = 0;
  int fd = socket(AF_INET6, SOCK_STREAM, 0);
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
    fd = socket(AF_INET, SOCK_STREAM, 0);
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
  _socket = fd;
  _port = bound;
  dispatch_source_t accepting = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
  __weak ODataSyncPeerListener *weak = self;
  dispatch_source_set_event_handler(accepting, ^{
    [weak acceptOn:fd];
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
  _socket = -1;
  if (accepting) dispatch_source_cancel(accepting);
  // Each relay's thread finds its sockets shut, and ends.
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

- (void)acceptOn:(int)listening
{
  for (;;) {
    int fd = accept(listening, NULL, NULL);
    if (fd < 0) return;  // EAGAIN: all taken
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
    ODSRelay *relay = [[ODSRelay alloc] init];
    relay.client = fd;
    relay.server = -1;
    @synchronized (_relays) {
      [_relays addObject:relay];
    }
    [NSThread detachNewThreadSelector:@selector(relay:) toTarget:self withObject:relay];
  }
}

// A thread's: the handshake, the client's certificate, the server's
// connection, known by its address before a byte goes, then both ways
// until either side is done.
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
    gnutls_handshake_set_timeout(session, 10000);
    int status;
    do {
      status = gnutls_handshake(session);
    } while (status < 0 && !gnutls_error_is_fatal(status));
    unsigned int count = 0;
    const gnutls_datum_t *chain = status >= 0 ? gnutls_certificate_get_peers(session, &count) : NULL;
    if (chain && count) {
      relay.thumbprint = [ODataSyncPeerIdentity thumbprintOfCertificateData:[NSData dataWithBytes:chain[0].data length:chain[0].size]];
    }
    if (relay.thumbprint && [self connectServerFor:relay]) [self pump:relay session:session];
    if (status >= 0) gnutls_bye(session, GNUTLS_SHUT_WR);
    gnutls_deinit(session);
    [self close:relay];
  }
}

- (BOOL)connectServerFor:(ODSRelay *)relay
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return NO;
  struct sockaddr_in backend = { .sin_family = AF_INET, .sin_port = htons((uint16_t)_backendPort), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
  struct sockaddr_in local;
  socklen_t length = sizeof local;
  if (connect(fd, (struct sockaddr *)&backend, sizeof backend) != 0 || getsockname(fd, (struct sockaddr *)&local, &length) != 0) {
    close(fd);
    return NO;
  }
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

- (void)pump:(ODSRelay *)relay session:(gnutls_session_t)session
{
  uint8_t buffer[64 * 1024];
  for (;;) {
    // What GnuTLS read already, first: poll does not see it.
    BOOL fromClient = gnutls_record_check_pending(session) > 0, fromServer = NO;
    if (!fromClient) {
      struct pollfd fds[2] = { { .fd = relay.client, .events = POLLIN }, { .fd = relay.server, .events = POLLIN } };
      int ready = poll(fds, 2, -1);
      if (ready < 0 && errno == EINTR) continue;
      if (ready <= 0) return;
      fromClient = (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
      fromServer = (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
    }
    if (fromClient) {
      ssize_t n = gnutls_record_recv(session, buffer, sizeof buffer);
      if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED || n == GNUTLS_E_REHANDSHAKE) continue;
      // Done (0, or the client gone without a close_notify), or broken:
      // so is the relay (HTTP over it has no half-close worth keeping).
      if (n <= 0 || !ODSSendAll(relay.server, buffer, (size_t)n)) return;
    }
    if (fromServer) {
      ssize_t n = recv(relay.server, buffer, sizeof buffer, 0);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0 || !ODSRecordSendAll(session, buffer, (size_t)n)) return;
    }
  }
}

- (void)close:(ODSRelay *)relay
{
  @synchronized (_relays) {
    if (relay.closed) return;
    relay.closed = YES;
    if (relay.address) [_thumbprints removeObjectForKey:relay.address];
    close(relay.client);
    if (relay.server >= 0) close(relay.server);
    [_relays removeObject:relay];
  }
}

@end
