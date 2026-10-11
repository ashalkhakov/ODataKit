// Signing in to a service that asks for it, as its $metadata says
// (ODataSignIn): a user and password, or OpenID Connect's device flow, in
// a panel made in code: the code to enter, the page to enter it on (opened
// in the browser), and the identity provider's client the Workbench signs
// in as.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>
#import <ODataSync/ODataSignIn.h>

NS_ASSUME_NONNULL_BEGIN

@interface WBSignInPanel : NSObject <ODataSignInDelegate>
// For a sign-in that has learnt what its service asks for (a user and
// password, or OpenID Connect).
- (instancetype)initWithSignIn:(ODataSignIn *)signIn NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataSignIn *signIn;
// Shown beside window, until signed in (done YES) or given up (done NO).
- (void)showBesideWindow:(nullable NSWindow *)window done:(void (^)(BOOL signedIn))done;
// The panel, for the self-test.
@property (nonatomic, readonly) NSPanel *panel;
@property (nonatomic, readonly) NSTextField *codeField;
@end

// The identity provider's client the Workbench signs in to a service as,
// remembered for each service root; nil until one is typed (there is no
// default: each provider has clients of its own).
FOUNDATION_EXPORT NSString *_Nullable WBClientIDForRoot(NSURL *root);
FOUNDATION_EXPORT void WBSetClientIDForRoot(NSString *clientID, NSURL *root);

NS_ASSUME_NONNULL_END
