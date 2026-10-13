// The Workbench's updates. On macOS, Sparkle: the newest release's
// appcast (SUFeedURL in Info.plist, signed with the key SUPublicEDKey
// names) is checked once a day if the user allows it, and Check for
// Updates… checks now. On GNUstep, nothing: the AppImage is updated from
// outside it, by AppImageUpdate, Gear Lever and the like.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WBUpdater : NSObject
// Started at once unless told not to (a self-test reaches no network).
- (instancetype)initStarting:(BOOL)start;
// Whether this system has an updater at all (Check for Updates… shown).
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) BOOL canCheckForUpdates;
- (IBAction)checkForUpdates:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
