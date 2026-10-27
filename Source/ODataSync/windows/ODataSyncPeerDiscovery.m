// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// No discovery on Windows yet (its DNS-SD is its own API, not dns_sd.h):
// nothing is advertised or found, and starting says why.

#import <ODataSync/ODataSyncPeerDiscovery.h>
#import "ODSWindowsSystem.h"

NSString * const ODataSyncPeerServiceType = @"_odatasync._tcp";

@implementation ODataSyncPeerAnnouncement
@end

@implementation ODataSyncPeerAdvertiser

- (instancetype)initWithServer:(ODataSyncPeerServer *)server name:(NSString *)name
{
  if (!(self = [super init])) return nil;
  _server = server;
  return self;
}

- (BOOL)start:(NSError **)error
{
  if (error) *error = ODSSystemPeersUnavailable();
  return NO;
}

- (void)stop
{
}

- (BOOL)isAdvertising
{
  return NO;
}

- (NSError *)error
{
  return ODSSystemPeersUnavailable();
}

- (NSString *)registeredName
{
  return nil;
}

@end

@implementation ODataSyncPeerBrowser

- (instancetype)initWithReplica:(NSString *)replica
{
  if (!(self = [super init])) return nil;
  _delegateQueue = [NSOperationQueue mainQueue];
  return self;
}

- (instancetype)init
{
  return [self initWithReplica:nil];
}

- (BOOL)start:(NSError **)error
{
  if (error) *error = ODSSystemPeersUnavailable();
  return NO;
}

- (void)stop
{
}

- (NSArray<ODataSyncPeerAnnouncement *> *)peers
{
  return @[];
}

@end
