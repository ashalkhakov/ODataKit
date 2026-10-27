// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// No listener on Windows yet: it does not start.

#import <ODataSync/ODataSyncPeerListener.h>
#import "ODSWindowsSystem.h"

@implementation ODataSyncPeerListener

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity backendPort:(NSUInteger)backendPort
{
  if (!(self = [super init])) return nil;
  _identity = identity;
  _backendPort = backendPort;
  return self;
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
  if (error) *error = ODSSystemPeersUnavailable();
  return NO;
}

- (void)stop
{
}

- (NSUInteger)port
{
  return 0;
}

- (BOOL)isRunning
{
  return NO;
}

- (NSString *)thumbprintOfConnectionFrom:(NSString *)remoteAddress
{
  return nil;
}

- (NSUInteger)connectionCount
{
  return 0;
}

@end
