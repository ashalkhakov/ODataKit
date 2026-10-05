// The Device app's Peers tab (DVPeers): the peer token, serving, the
// devices nearby, pairing (a QR code shown, or scanned), the devices paired.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "DVControllers.h"

NS_ASSUME_NONNULL_BEGIN

// This device (its token, serving, pairing), the devices found nearby (a
// tap syncs with one), the devices paired (a swipe forgets one).
@interface DVPeersController : DVTableController
@end

// The pairing offer, as a QR code and as text, while it is good.
@interface DVOfferController : UIViewController
- (instancetype)initWithPeers:(DVPeers *)peers;
@end

// The other device's offer, read by the camera, or pasted (the simulator
// has no camera); offer is called with its text.
@interface DVScanController : UIViewController
- (instancetype)initWithOffer:(void (^)(NSString *text))offer;
@end

NS_ASSUME_NONNULL_END
