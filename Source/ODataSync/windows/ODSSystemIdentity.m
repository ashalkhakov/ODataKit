// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// No identity on Windows yet: it is what devices nearby know this one by.

#import "ODSWindowsSystem.h"

@implementation ODSSystemIdentity
@synthesize certificate = _certificate;
@end

ODSSystemIdentity *ODSSystemKeepIdentity(NSString *label, NSURL *directory, NSError **error)
{
  if (error) *error = ODSSystemPeersUnavailable();
  return nil;
}

BOOL ODSSystemForgetIdentity(ODSSystemIdentity *identity, NSError **error)
{
  return YES;
}
