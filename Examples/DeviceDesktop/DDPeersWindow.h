// The desktop Device app's Peers window (DVPeers): the peer token,
// serving, a pairing code (QR and text), pairing with one pasted, the
// devices found nearby (a sync with one), the devices paired.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>
#import "DVSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface DDPeersWindow : NSObject <NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)initWithSession:(DVSession *)session NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) DVSession *session;
@property (nonatomic, readonly) NSWindow *window;
// Shown; looking for peers from then on.
- (void)show;
// Read again (the session's device, its peers).
- (void)reload;
@end

NS_ASSUME_NONNULL_END
