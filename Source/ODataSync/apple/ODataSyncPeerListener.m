// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The listener on Network.framework.

#import <ODataSync/ODataSyncPeerListener.h>
#import "ODSAppleSystem.h"
#import <Network/Network.h>

static NSError *ODSListenerError(NSString *what, nw_error_t error)
{
  NSString *text = what;
  if (error) {
    CFErrorRef cf = nw_error_copy_cf_error(error);
    if (cf) {
      text = [NSString stringWithFormat:@"%@: %@", what, [(__bridge NSError *)cf localizedDescription]];
      CFRelease(cf);
    }
  }
  return [NSError errorWithDomain:NSPOSIXErrorDomain code:error ? nw_error_get_error_code(error) : EIO
                         userInfo:@{ NSLocalizedDescriptionKey: text }];
}

// One client's connection, and its relay to the server.
@interface ODSRelay : NSObject
@property (nonatomic, strong) nw_connection_t client;
@property (nonatomic, strong, nullable) nw_connection_t server;
@property (nonatomic, copy, nullable) NSString *address;     // the relay's, as the server sees it
@property (nonatomic, copy, nullable) NSString *thumbprint;  // the client's certificate's
@property (nonatomic) BOOL closed;
@end

@implementation ODSRelay
@end

@implementation ODataSyncPeerListener {
  nw_listener_t _listener;
  dispatch_queue_t _queue;
  NSMutableSet<ODSRelay *> *_relays;
  NSMutableDictionary<NSString *, NSString *> *_thumbprints;  // relay address -> thumbprint
}

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity backendPort:(NSUInteger)backendPort
{
  self = [super init];
  if (!self) return nil;
  _identity = identity;
  _backendPort = backendPort;
  _queue = dispatch_queue_create("ODataSync peer listener", DISPATCH_QUEUE_SERIAL);
  _relays = [NSMutableSet set];
  _thumbprints = [NSMutableDictionary dictionary];
  return self;
}

- (void)dealloc
{
  [self stop];
}

#pragma mark Listening

// TLS 1.2 at least, the device's identity, a client certificate asked for
// and taken as it is: the authenticator decides what it is worth.
- (nw_parameters_t)parameters
{
  sec_identity_t identity = sec_identity_create(_identity.system.secIdentity);
  dispatch_queue_t queue = _queue;
  return nw_parameters_create_secure_tcp(^(nw_protocol_options_t options) {
    sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(options);
    sec_protocol_options_set_local_identity(security, identity);
    sec_protocol_options_set_min_tls_protocol_version(security, tls_protocol_version_TLSv12);
    sec_protocol_options_set_peer_authentication_required(security, true);
    // Every connection a full handshake, its client's certificate proved
    // anew: no session resumed from another (which presents none).
    sec_protocol_options_set_tls_resumption_enabled(security, false);
    sec_protocol_options_set_tls_tickets_enabled(security, false);
    sec_protocol_options_set_verify_block(security, ^(sec_protocol_metadata_t metadata, sec_trust_t trust, sec_protocol_verify_complete_t complete) {
      // A certificate presented is all TLS asks; whose it is comes later.
      complete(trust != nil);
    }, queue);
  }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
  if (_listener) return YES;
  nw_parameters_t parameters = [self parameters];
  nw_parameters_set_reuse_local_address(parameters, true);
  nw_listener_t listener = port ? nw_listener_create_with_port([[NSString stringWithFormat:@"%lu", (unsigned long)port] UTF8String], parameters)
                                : nw_listener_create(parameters);
  if (!listener) {
    if (error) *error = ODSListenerError(@"The listener could not be made", NULL);
    return NO;
  }
  dispatch_semaphore_t settled = dispatch_semaphore_create(0);
  __block nw_error_t failure = nil;
  __block BOOL ready = NO;
  __weak ODataSyncPeerListener *weak = self;
  nw_listener_set_queue(listener, _queue);
  nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t stateError) {
    if (state == nw_listener_state_ready && !ready) {
      ready = YES;
      dispatch_semaphore_signal(settled);
    } else if (state == nw_listener_state_failed) {
      failure = stateError;
      if (!ready) dispatch_semaphore_signal(settled);
    }
  });
  nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
    [weak accept:connection];
  });
  nw_listener_start(listener);
  if (dispatch_semaphore_wait(settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC))) != 0 || !ready) {
    nw_listener_cancel(listener);
    if (error) *error = ODSListenerError(@"The listener did not start", failure);
    return NO;
  }
  _listener = listener;
  _port = nw_listener_get_port(listener);
  return YES;
}

- (void)stop
{
  nw_listener_t listener = _listener;
  _listener = nil;
  if (listener) nw_listener_cancel(listener);
  dispatch_sync(_queue, ^{
    for (ODSRelay *relay in [self->_relays copy]) [self close:relay];
  });
}

- (BOOL)isRunning
{
  return _listener != nil;
}

- (NSString *)thumbprintOfConnectionFrom:(NSString *)remoteAddress
{
  if (!remoteAddress) return nil;
  @synchronized (_thumbprints) {
    return _thumbprints[remoteAddress];
  }
}

- (NSUInteger)connectionCount
{
  __block NSUInteger count = 0;
  dispatch_sync(_queue, ^{
    count = self->_relays.count;
  });
  return count;
}

#pragma mark Relaying (on the queue)

- (void)accept:(nw_connection_t)connection
{
  ODSRelay *relay = [[ODSRelay alloc] init];
  relay.client = connection;
  [_relays addObject:relay];
  __weak ODataSyncPeerListener *weak = self;
  __weak ODSRelay *weakRelay = relay;
  nw_connection_set_queue(connection, _queue);
  nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
    ODSRelay *strongRelay = weakRelay;
    if (!strongRelay) return;
    if (state == nw_connection_state_ready) {
      [weak clientReady:strongRelay];
    } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
      [weak close:strongRelay];
    }
  });
  nw_connection_start(connection);
}

// The client's certificate, then a connection to the server for it.
- (void)clientReady:(ODSRelay *)relay
{
  nw_protocol_metadata_t metadata = nw_connection_copy_protocol_metadata(relay.client, nw_protocol_copy_tls_definition());
  __block SecCertificateRef leaf = NULL;
  if (metadata && nw_protocol_metadata_is_tls(metadata)) {
    sec_protocol_metadata_t security = nw_tls_copy_sec_protocol_metadata(metadata);
    sec_protocol_metadata_access_peer_certificate_chain(security, ^(sec_certificate_t certificate) {
      if (!leaf) leaf = sec_certificate_copy_ref(certificate);
    });
  }
  relay.thumbprint = ODSAppleThumbprint(leaf);
  if (leaf) CFRelease(leaf);
  if (!relay.thumbprint) {
    [self close:relay];
    return;
  }
  nw_endpoint_t backend = nw_endpoint_create_host("127.0.0.1", [[NSString stringWithFormat:@"%lu", (unsigned long)_backendPort] UTF8String]);
  nw_parameters_t plain = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
  nw_connection_t server = nw_connection_create(backend, plain);
  relay.server = server;
  __weak ODataSyncPeerListener *weak = self;
  __weak ODSRelay *weakRelay = relay;
  nw_connection_set_queue(server, _queue);
  nw_connection_set_state_changed_handler(server, ^(nw_connection_state_t state, nw_error_t error) {
    ODSRelay *strongRelay = weakRelay;
    if (!strongRelay) return;
    if (state == nw_connection_state_ready) {
      [weak serverReady:strongRelay];
    } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
      [weak close:strongRelay];
    }
  });
  nw_connection_start(server);
}

// Known by its address before a byte goes: then both ways.
- (void)serverReady:(ODSRelay *)relay
{
  nw_path_t path = nw_connection_copy_current_path(relay.server);
  nw_endpoint_t local = path ? nw_path_copy_effective_local_endpoint(path) : nil;
  if (!local) {
    [self close:relay];
    return;
  }
  relay.address = [NSString stringWithFormat:@"127.0.0.1:%u", nw_endpoint_get_port(local)];
  @synchronized (_thumbprints) {
    _thumbprints[relay.address] = relay.thumbprint;
  }
  [self pumpFrom:relay.client to:relay.server relay:relay];
  [self pumpFrom:relay.server to:relay.client relay:relay];
}

- (void)pumpFrom:(nw_connection_t)from to:(nw_connection_t)to relay:(ODSRelay *)relay
{
  __weak ODataSyncPeerListener *weak = self;
  __weak ODSRelay *weakRelay = relay;
  nw_connection_receive(from, 1, 64 * 1024, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
    ODSRelay *strongRelay = weakRelay;
    if (!strongRelay || strongRelay.closed) return;
    BOOL done = error || complete;
    if (content) {
      // The last of it sent before the relay closes.
      nw_connection_send(to, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t sendError) {
        if (sendError || done) [weak close:strongRelay];
      });
    } else if (done) {
      // One side is done: so is the relay (HTTP over it has no half-close
      // worth keeping).
      [weak close:strongRelay];
    }
    if (done) return;
    [weak pumpFrom:from to:to relay:strongRelay];
  });
}

- (void)close:(ODSRelay *)relay
{
  if (relay.closed) return;
  relay.closed = YES;
  if (relay.address) {
    @synchronized (_thumbprints) {
      [_thumbprints removeObjectForKey:relay.address];
    }
  }
  nw_connection_cancel(relay.client);
  if (relay.server) nw_connection_cancel(relay.server);
  [_relays removeObject:relay];
}

@end
