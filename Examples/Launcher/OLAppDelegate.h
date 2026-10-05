// The chooser the Linux AppImage opens (XFormsKit's XFormsLauncher, after
// UDQuakeTools' UDLauncher): an AppImage has one entry point, and this one
// carries two apps, the Workbench and the desktop Device app; a window with
// a button for each.
//
// GNUstep only: on a Mac each app is its own bundle, and there is nothing
// to choose between.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OLAppDelegate : NSObject
@end

NS_ASSUME_NONNULL_END
