// DDSystem — what the desktop Device app needs of the system it runs on,
// one implementation for each, which the build picks: apple/ (AppKit on
// macOS, Core Image), linux/ (GNUstep's AppKit, libqrencode).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// A QR code of the text, side points wide, sharp (one module a block of
// pixels); nil when it cannot be made.
FOUNDATION_EXPORT NSImage *_Nullable DDSystemQRCode(NSString *text, CGFloat side);
// The general pasteboard's text, and text put there.
FOUNDATION_EXPORT NSString *_Nullable DDSystemPastedText(void);
FOUNDATION_EXPORT void DDSystemCopyText(NSString *text);
// A push button's rounded bezel, as the system names it.
FOUNDATION_EXPORT NSBezelStyle DDSystemRoundedBezel(void);
// The device's name, as people know it.
FOUNDATION_EXPORT NSString *DDSystemDeviceName(void);

NS_ASSUME_NONNULL_END
