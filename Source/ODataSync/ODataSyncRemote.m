// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"

@implementation ODataSyncRemote

+ (instancetype)remoteWithServiceRoot:(NSURL *)serviceRoot
{
  return [[self alloc] initWithServiceRoot:serviceRoot];
}

+ (instancetype)peerWithServiceRoot:(NSURL *)serviceRoot
{
  ODataSyncRemote *remote = [[self alloc] initWithServiceRoot:serviceRoot];
  remote->_peer = YES;
  NSString *replica = serviceRoot.path.lastPathComponent;
  if (replica.length) remote.identifier = replica;
  return remote;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _identifier = [serviceRoot.absoluteString copy];
  _configuration = [[ODataConfiguration alloc] initWithURL:serviceRoot options:nil];
  _filters = @{};
  _batchSize = 50;
  _batchBytes = 8 * 1024 * 1024;
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncRemote %@%@>", _peer ? @"peer " : @"", _identifier];
}

@end
