// ODataSyncService — the service's part of ODataSync's causal history
// (docs/offline-sync.md, 12), for a server app's ODataService.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A server whose synced entities keep a version vector (ODataSync.versions,
// as the devices' model has it) installs it on its service:
//
//   NSManagedObjectModel *model = ...;           // ODataSync.versions on the synced entities
//   [ODataSyncService addBookkeepingToModel:model configuration:nil];
//   ... the coordinator, the ODataService ...
//   ODataSyncService *sync = [[ODataSyncService alloc] initWithService:service];
//
// Then a write a device sends is compared with what the service has: an
// insert of a key the service deleted, whose version the deletion had
// seen, is late (410); one made without knowing of it is a conflict (409,
// the deletion's history in the error's details), for the device to
// settle; one made by a device that knew is taken. A device's vector is
// stored as it comes; a change the server app (or any client that sends
// no vector) makes is counted as the service's (replica svc).

#pragma once
#import <ODataSync/ODataSyncEngine.h>
#import <ODataService/ODataService.h>
#import <ODataSync/ODataSyncPeerTokens.h>

NS_ASSUME_NONNULL_BEGIN

// A synced set's handler that keeps deletions and compares histories. A
// server's own handler for such a set subclasses it.
@interface ODataSyncSetHandler : ODataEntitySetHandler
@property (nonatomic, weak, nullable) ODataSyncEngine *engine;
// The transaction author a write is made with. Default: a client that
// sends a version vector writes as ODataSync.client (its vector kept,
// not counted again); any other write, nil (the server's own, counted).
- (nullable NSString *)authorOfRequest:(ODataRequest *)request values:(nullable NSDictionary<NSString *, id> *)values;
@end

@interface ODataSyncService : NSObject
// What the service keeps of deletions (a tombstone entity), added to the
// model before a coordinator uses it, in the configuration its synced
// entities' store has (nil: the default one). Not served: it has no key.
+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(nullable NSString *)configuration;
// Installs ODataSyncSetHandler on each set of an entity that keeps a
// version vector and has the default handler (a server's own handler of
// such a set should be an ODataSyncSetHandler), and counts the server's
// own changes. Before the service's first request.
- (instancetype)initWithService:(ODataService *)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataService *service;
// The service as a replica: its tombstones, its count, its save observer.
@property (nonatomic, readonly) ODataSyncEngine *engine;
// How long deletions are kept. Default: 30 days.
@property (nonatomic) NSTimeInterval tombstoneRetention;
// Sets whose handler is neither the default nor an ODataSyncSetHandler:
// their deletions and histories are not checked.
@property (nonatomic, readonly, copy) NSArray<NSString *> *uncheckedEntitySets;
// Peer tokens for its devices (docs/peer-sync.md, 3.1): set, the service
// answers PeerToken(Replica, Thumbprint) for a device signed in, through
// the service's serviceOperations, made for it when the service has none
// (else that object adopts ODataSyncPeerTokenActions and answers with
// -peerTokenWithReplica:thumbprint:reply:). Before the first request, as
// serviceOperations.
@property (nonatomic, strong, nullable) ODataSyncPeerTokenIssuer *peerTokens;
- (nullable NSDictionary *)peerTokenWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint reply:(ODataReply *)reply;
@end

NS_ASSUME_NONNULL_END
