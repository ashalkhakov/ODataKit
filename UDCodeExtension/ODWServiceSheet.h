// Add Service… and Edit Service… (ODWServiceSheet.xib): a service's name,
// its service root, and whether the project keeps it (its
// .udcode/settings.json, shared with the folder: no secret is kept there;
// a sign-in's are the system's) or the user does.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ODWService;

@interface ODWServiceSheet : NSObject
// For a new service (nil) or one to edit; hasProject: the window has a
// folder, whose settings can keep it.
- (nullable instancetype)initWithService:(nullable ODWService *)service inProject:(BOOL)hasProject NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Shown as a sheet of window (a panel of its own without one); done with
// the service as typed (a new one), or nil when cancelled.
- (void)beginSheetForWindow:(nullable NSWindow *)window done:(void (^)(ODWService *_Nullable service))done;

@property (nonatomic, readonly) NSWindow *sheet;
@property (nonatomic, weak, readonly) NSTextField *nameField;
@property (nonatomic, weak, readonly) NSTextField *rootField;
@property (nonatomic, weak, readonly) NSButton *projectCheckbox;
@property (nonatomic, weak, readonly) NSTextField *problemLabel;
// The service as typed, or nil and why (problemLabel says so).
- (nullable ODWService *)typedService;
- (IBAction)save:(nullable id)sender;
- (IBAction)cancel:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
