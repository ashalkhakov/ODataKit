// Workbench — try out an OData v4 service interactively: the built-in
// in-memory one, Northwind, TripPin, or any other.
//
//   Workbench --self-test           drives the window against each, and exits
//   Workbench --self-test builtin   the built-in service alone: no network
//   Workbench --serve [port]        the built-in service served on the network
//                                   too (default port 8640), for the Device app
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <AppKit/AppKit.h>
#import "WorkbenchController.h"
#include <stdlib.h>
#include <string.h>

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    BOOL selfTest = NO, offline = NO, serve = NO;
    unsigned long port = 0;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--self-test")) selfTest = YES;
      else if (selfTest && !strcmp(argv[i], "builtin")) offline = YES;
      else if (!strcmp(argv[i], "--serve")) serve = YES;
      else if (serve && !port && strtoul(argv[i], NULL, 10)) port = strtoul(argv[i], NULL, 10);
    }
    [NSApplication sharedApplication];
    WorkbenchController *app = [[WorkbenchController alloc] init];
    [NSApp setDelegate:(id)app];
    app.selfTestOffline = offline;
    app.selfTesting = selfTest;
    [app showWindow];
    if (serve && !selfTest) [app serveOnTheNetworkAtPort:port];
    if (selfTest) [app performSelector:@selector(runSelfTest) withObject:nil afterDelay:0.5];
    [NSApp run];
  }
  return 0;
}
