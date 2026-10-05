// The Device apps' state: the Workbench's device (WorkbenchDevice.h), on an
// iPhone (Examples/Device) or a desktop (Examples/DeviceDesktop), kept in
// sync over the network with a Workbench that serves its built-in service
// (Sync > Serve on the Network), and its settings. Foundation only: each
// app's views over it are its own.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "WorkbenchDevice.h"
#import "DVPeers.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when the device changed (a save, a sync, a
// setting, a new device): the views read it again. userInfo's "status"
// says what happened.
FOUNDATION_EXPORT NSNotificationName const DVSessionDidChangeNotification;
// Posted on the main thread for each exchange the device had.
FOUNDATION_EXPORT NSNotificationName const DVSessionDidLogNotification;

@interface DVSession : NSObject
// The service root last used, and its device (whose store is kept across
// launches); nil until a root is set. An instance (nil: the one) has a
// store and settings of its own: two on one machine are two devices.
- (instancetype)initWithInstance:(nullable NSString *)instance NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
@property (nonatomic, readonly, copy, nullable) NSString *instance;
// What peers are told this device is called (a pairing's name), and the
// port it serves them on (DVPeersPort).
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic) NSUInteger peerPort;
@property (nonatomic, readonly, nullable) WorkbenchDevice *device;
@property (nonatomic, readonly, copy, nullable) NSURL *serviceRoot;
// The device's peers: with the device, nil without (or when its identity
// cannot be made: the status says why).
@property (nonatomic, readonly, nullable) DVPeers *peers;
// What happened last, in words; said anew (posted).
@property (nonatomic, readonly, copy) NSString *status;
- (void)say:(NSString *)status;
// The Workbench's root, as typed: a new device for a new root (its store
// emptied). Nil when done; else why not.
- (nullable NSString *)useServiceRoot:(NSString *)text;
// Kept across launches.
@property (nonatomic) WBSyncRule rule;
@property (nonatomic, getter=isOffline) BOOL offline;
@property (nonatomic) BOOL syncsEachChange;
// The device emptied: Sync reads everything again.
- (void)resetDevice;
// The device gone, and all of it: its store, its identity, pairings and
// token, the address kept (the instance as never used).
- (void)discardDevice;
@end

NS_ASSUME_NONNULL_END
