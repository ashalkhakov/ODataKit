// GNUstep: the AppImage is updated from outside it (WBUpdater.h).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBUpdater.h"

@implementation WBUpdater

- (instancetype)initStarting:(BOOL)start
{
  (void)start;
  return [super init];
}

- (BOOL)available
{
  return NO;
}

- (BOOL)canCheckForUpdates
{
  return NO;
}

- (IBAction)checkForUpdates:(id)sender
{
  (void)sender;
}

@end
