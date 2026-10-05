// The desktop Device app: the iOS Device app's counterpart on macOS and
// Linux (GNUstep), for peer sync between desktops and phones. A device
// (DVSession, shared with the iOS app) kept in sync with a Workbench that
// serves its built-in service, shown in the Workbench's own Sync window
// (WBSyncWindow), and a Peers window (DDPeersWindow).
//
//   DeviceDesktop                      the device
//   DeviceDesktop -DVInstance B        another one, beside it (its own store,
//                 -DVPeerPort 8643     settings and identity; another port)
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDAppController : NSObject <NSApplicationDelegate>
- (void)start;
@end

NS_ASSUME_NONNULL_END
