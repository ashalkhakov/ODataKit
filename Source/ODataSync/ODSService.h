// The service's part that a peer server shares: ODataSync's own operations
// (PeerToken, MergeAttributes), and MergeAttributes answered.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "ODataSyncService.h"

NS_ASSUME_NONNULL_BEGIN

// A service's operations when the app has none of its own. Of a service:
// sync set (PeerToken; MergeAttributes recording what replicas have seen).
// Of a peer server: sync nil, engine its device's (MergeAttributes only,
// nothing recorded, nothing collected).
@interface ODSServiceOperations : NSObject <ODataSyncPeerTokenActions, ODataSyncMergeActions>
@property (nonatomic, weak, nullable) ODataSyncService *sync;
@property (nonatomic, weak, nullable) ODataSyncEngine *engine;
@end

// MergeAttributes(Replica, Items) answered for the reply's request
// (docs/offline-sync.md, 14.2): each item merged through its set's handler,
// as the request may see it. record: what the replica has seen kept, and
// what all have seen (within retention) collected and told.
FOUNDATION_EXPORT NSDictionary *_Nullable ODSAnswerMergeAttributes(ODataSyncEngine *engine, NSString *_Nullable replica, NSArray *items,
                                                                   ODataReply *reply, BOOL record, NSTimeInterval retention);

// What the service kept of a deleted object's merged attributes (what
// replicas have seen, the horizon), forgotten.
FOUNDATION_EXPORT void ODSForgetMerges(NSManagedObjectContext *context, NSString *entityType, NSString *keyText);

NS_ASSUME_NONNULL_END
