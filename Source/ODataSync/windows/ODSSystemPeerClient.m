// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// No peer client on Windows yet.

#import "ODSWindowsSystem.h"

@implementation ODSSystemPeerClient

- (instancetype)initWithIdentity:(ODataSyncPeerIdentity *)identity
{
  return [super init];
}

- (NSHTTPURLResponse *)send:(NSURLRequest *)request pinned:(NSString *)pinned fresh:(BOOL)fresh
                       data:(NSData **)data presented:(NSString **)presented error:(NSError **)error
{
  if (error) *error = ODSSystemPeersUnavailable();
  return nil;
}

@end
