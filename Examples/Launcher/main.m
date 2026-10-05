// The Linux AppImage's chooser: the Workbench or the desktop Device app
// (OLAppDelegate.h).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <AppKit/AppKit.h>
#import "OLAppDelegate.h"

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    OLAppDelegate *delegate = [[OLAppDelegate alloc] init];
    app.delegate = (id)delegate;
    [app run];
  }
  return 0;
}
