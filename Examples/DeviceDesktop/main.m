// OIS Device for the desktop: the iOS Device app's counterpart, on macOS
// and Linux (GNUstep), to sync with a Workbench and with peers nearby
// (DDAppController.h). With --self-test <Workbench root>, no window: peer
// sync end to end (DDSelfTest.h).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <AppKit/AppKit.h>
#import "DDAppController.h"
#import "DDSelfTest.h"

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    // No window: peer sync end to end, against the Workbench given.
    for (int i = 1; i + 1 < argc; i++) {
      NSURL *workbench = [NSURL URLWithString:@(argv[i + 1])];
      if (!strcmp(argv[i], "--self-test")) return DDRunSelfTest(workbench);
      // Peers from a terminal (DDSelfTest.h).
      if (!strcmp(argv[i], "--serve")) return DDRunServe(workbench, i + 2 < argc ? atof(argv[i + 2]) : 0);
      if (!strcmp(argv[i], "--sync-with") && i + 2 < argc) {
        return DDRunSyncWith(workbench, [NSURL URLWithString:@(argv[i + 2])], i + 3 < argc ? @(argv[i + 3]) : nil);
      }
    }
    [NSApplication sharedApplication];
    DDAppController *controller = [[DDAppController alloc] init];
    NSApp.delegate = controller;
    [controller start];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
  }
  return 0;
}
