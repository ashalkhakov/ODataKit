// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DDSelfTest.h"
#import "DVSession.h"

static NSUInteger DDPassed, DDFailed;

static void DDCheck(BOOL ok, NSString *what, NSString *detail)
{
  if (ok) DDPassed++;
  else DDFailed++;
  printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", what.UTF8String, detail.length ? ": " : "", detail.UTF8String ?: "");
  fflush(stdout);
}

// The main run loop turned (what the sessions say comes on the main queue)
// until the condition holds, or seconds go by: whether it holds.
static BOOL DDWaitFor(NSTimeInterval seconds, BOOL (^condition)(void))
{
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!condition()) {
    if (until.timeIntervalSinceNow < 0) return NO;
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  return YES;
}

// A device of the self-test's own, emptied: at the Workbench, on port.
static DVSession *DDDevice(NSString *name, NSURL *workbench, NSUInteger port)
{
  DVSession *session = [[DVSession alloc] initWithInstance:[@"self-test-" stringByAppendingString:name]];
  session.deviceName = [@"Self-test " stringByAppendingString:name];
  session.peerPort = port;
  NSString *why = [session useServiceRoot:workbench.absoluteString];
  if (!why && session.device) [session resetDevice];
  DDCheck(session.device != nil && session.peers != nil, [NSString stringWithFormat:@"device %@ opens", name], why ?: session.status);
  session.device.offline = NO;
  session.device.syncsEachChange = NO;
  return session;
}

// A sync (with the Workbench, or a peer) waited for: whether it went.
static BOOL DDSynced(DVSession *session, NSString *what, BOOL (^start)(void))
{
  __block NSString *said = nil;
  id observer = [[NSNotificationCenter defaultCenter] addObserverForName:DVSessionDidChangeNotification object:session queue:nil
                                                              usingBlock:^(NSNotification *notification) {
    said = notification.userInfo[@"status"];
  }];
  BOOL started = start();
  BOOL done = started && DDWaitFor(60, ^{ return (BOOL)!session.device.busy; });
  [[NSNotificationCenter defaultCenter] removeObserver:observer];
  BOOL ok = done && said && [said rangeOfString:@"failed"].location == NSNotFound;
  DDCheck(ok, what, said ?: (started ? @"no answer in a minute" : @"did not start"));
  return ok;
}

static NSManagedObject *DDFirstProduct(DVSession *session)
{
  return [session.device objectsOfEntity:@"Product"].firstObject;
}

int DDRunSelfTest(NSURL *workbench)
{
  printf("Device self-test against %s\n", workbench.absoluteString.UTF8String);
  DVSession *a = DDDevice(@"A", workbench, 8650), *b = DDDevice(@"B", workbench, 8651), *c = DDDevice(@"C", workbench, 8652);
  if (DDFailed) return (int)DDFailed;

  // A and B: the Workbench's data, and a peer token each.
  for (DVSession *session in @[ a, b, c ]) {
    DDSynced(session, [NSString stringWithFormat:@"%@ syncs with the Workbench", session.deviceName], ^{
      return [session.device run:WBSyncActionSync];
    });
  }
  DDCheck(DDFirstProduct(a) != nil, @"A has the Workbench's products", nil);
  for (DVSession *session in @[ a, b ]) {
    [session.peers fetchToken];
    DDWaitFor(30, ^{ return (BOOL)!session.peers.fetchingToken; });
    DDCheck(session.peers.hasToken, [NSString stringWithFormat:@"%@ gets a peer token", session.deviceName], session.status);
  }

  // A serves; B finds it nearby.
  NSError *error = nil;
  DDCheck([a.peers startServing:&error], @"A serves to peers", error.localizedDescription ?: a.peers.serviceRoot.absoluteString);
  [b.peers startBrowsing];
  NSString *replicaA = a.device.sync.replicaID;
  __block ODataSyncPeerAnnouncement *found = nil;
  BOOL seen = DDWaitFor(30, ^{
    for (ODataSyncPeerAnnouncement *peer in b.peers.found) {
      if ([peer.replica isEqualToString:replicaA]) found = peer;
    }
    return (BOOL)(found != nil);
  });
  DDCheck(seen, @"B finds A nearby (Bonjour)", found ? found.serviceRoot.absoluteString : @"not in thirty seconds (is avahi-daemon running?)");

  // A's change, not sent to the Workbench, reaches B from A.
  NSManagedObject *product = DDFirstProduct(a);
  id key = [product valueForKey:@"id"];
  NSString *name = [NSString stringWithFormat:@"Peer-synced %@", [NSUUID UUID].UUIDString.lowercaseString];
  a.device.offline = YES;
  [a.device setValue:name ofAttribute:@"name" object:product];
  if (found) {
    DDSynced(b, @"B syncs with A, by token", ^{
      return [b.peers syncWithPeer:found];
    });
    DDCheck([[b.device valueOfAttribute:@"name" entity:@"Product" key:key] isEqual:name], @"B has A's change", nil);
  }

  // C, with no token: refused, then paired with A, and synced.
  if (found) {
    BOOL started = [c.peers syncWithPeer:found];
    DDCheck(!started, @"C, without a token or a pairing, does not sync", c.status);
  }
  NSString *offer = [a.peers newPairingOffer];
  DDCheck(offer != nil, @"A offers a pairing", nil);
  __block BOOL answered = NO;
  __block NSError *refusal = nil;
  [c.peers pairWithOffer:offer ?: @"" completion:^(NSError *pairingError) {
    refusal = pairingError;
    answered = YES;
  }];
  DDWaitFor(30, ^{ return answered; });
  DDCheck(answered && !refusal, @"C pairs with A", refusal.localizedDescription);
  // The sync that follows a pairing.
  DDWaitFor(1, ^{ return (BOOL)c.device.busy; });
  DDWaitFor(60, ^{ return (BOOL)!c.device.busy; });
  DDCheck([[c.device valueOfAttribute:@"name" entity:@"Product" key:key] isEqual:name], @"C has A's change", c.status);
  DDCheck(c.peers.pairings.count == 1 && a.peers.pairings.count == 1, @"A and C keep each other as paired", nil);

  // Left as found: no server, no identities, no stores, no settings.
  [a.peers stopServing];
  for (DVSession *session in @[ a, b, c ]) [session discardDevice];
  printf("Device self-test: passed: %lu checks, %lu failed\n", (unsigned long)DDPassed, (unsigned long)DDFailed);
  return (int)DDFailed;
}

#pragma mark - Peers from a terminal

// The device of -DVInstance, at the Workbench, synced, with a peer token
// (when the Workbench gives one): nil, said why, when it does not open.
static DVSession *DDTerminalDevice(NSURL *workbench)
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *instance = [defaults stringForKey:@"DVInstance"];
  DVSession *session = [[DVSession alloc] initWithInstance:instance];
  session.deviceName = [NSString stringWithFormat:@"%@%@", [NSProcessInfo processInfo].hostName,
                                                    instance.length ? [NSString stringWithFormat:@" (%@)", instance] : @""];
  NSInteger port = [defaults integerForKey:@"DVPeerPort"];
  if (port > 0 && port < 65536) session.peerPort = (NSUInteger)port;
  NSString *why = [session useServiceRoot:workbench.absoluteString];
  if (why || !session.device || !session.peers) {
    printf("The device does not open: %s\n", (why ?: session.status).UTF8String);
    return nil;
  }
  session.device.offline = NO;
  DDSynced(session, @"synced with the Workbench", ^{
    return [session.device run:WBSyncActionSync];
  });
  if (!session.peers.hasToken) {
    [session.peers fetchToken];
    DDWaitFor(30, ^{ return (BOOL)!session.peers.fetchingToken; });
  }
  DDCheck(session.peers.hasToken, @"a peer token", session.peers.hasToken ? nil : session.status);
  return session;
}

int DDRunServe(NSURL *workbench, NSTimeInterval seconds)
{
  DVSession *session = DDTerminalDevice(workbench);
  if (!session) return 1;
  NSError *error = nil;
  if (![session.peers startServing:&error]) {
    printf("Not serving: %s\n", error.localizedDescription.UTF8String);
    return 1;
  }
  printf("serving %s\n", session.peers.serviceRoot.absoluteString.UTF8String);
  printf("thumbprint %s\n", session.peers.trust.identity.thumbprint.UTF8String);
  printf("offer %s\n", [session.peers newPairingOffer].UTF8String);
  fflush(stdout);
  // What peers sync, said as it happens.
  [[NSNotificationCenter defaultCenter] addObserverForName:DVSessionDidChangeNotification object:session queue:nil
                                                usingBlock:^(NSNotification *notification) {
    printf("%s\n", [notification.userInfo[@"status"] UTF8String]);
    fflush(stdout);
  }];
  NSDate *until = seconds > 0 ? [NSDate dateWithTimeIntervalSinceNow:seconds] : [NSDate distantFuture];
  while (until.timeIntervalSinceNow > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
  }
  [session.peers stopServing];
  return 0;
}

int DDRunSyncWith(NSURL *workbench, NSURL *peer, NSString *thumbprintOrOffer)
{
  DVSession *session = DDTerminalDevice(workbench);
  if (!session) return 1;
  if ([thumbprintOrOffer hasPrefix:@"{"]) {
    __block BOOL answered = NO;
    __block NSError *refusal = nil;
    [session.peers pairWithOffer:thumbprintOrOffer completion:^(NSError *pairingError) {
      refusal = pairingError;
      answered = YES;
    }];
    DDWaitFor(30, ^{ return answered; });
    DDCheck(answered && !refusal, @"paired", refusal.localizedDescription);
    // The sync a pairing starts.
    DDWaitFor(1, ^{ return (BOOL)session.device.busy; });
    DDWaitFor(60, ^{ return (BOOL)!session.device.busy; });
    DDCheck(YES, @"synced with the device paired", session.status);
  } else {
    ODataSyncRemote *remote = [ODataSyncRemote peerWithServiceRoot:peer];
    ODataSyncPeerTransport *transport = [[ODataSyncPeerTransport alloc] initWithServiceRoot:peer trust:session.peers.trust];
    transport.expectedThumbprint = thumbprintOrOffer.length ? thumbprintOrOffer : nil;
    remote.transport = transport;
    DDSynced(session, [@"synced with " stringByAppendingString:peer.absoluteString], ^{
      return [session.device syncWithRemote:remote named:peer.host];
    });
  }
  printf("Device: passed: %lu checks, %lu failed\n", (unsigned long)DDPassed, (unsigned long)DDFailed);
  return (int)DDFailed;
}
