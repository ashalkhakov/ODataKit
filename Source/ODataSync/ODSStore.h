// What ODataSync keeps in the app's store: its own entities (the remotes'
// state, the outbox, the shadows, the tombstones) and its metadata.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <CoreData/CoreData.h>
#import <ODataSync/ODataSyncEngine.h>

@class ODSCodec;

NS_ASSUME_NONNULL_BEGIN

// The bookkeeping entities (docs/offline-sync.md, 3.3).
FOUNDATION_EXPORT NSString * const ODSRemoteStateEntity;   // remote, deltaLinks, filters, historyToken
FOUNDATION_EXPORT NSString * const ODSOutboxEntity;        // remote, entityType, key, keyText, operation, properties, sequence, ...
FOUNDATION_EXPORT NSString * const ODSShadowEntity;        // remote, entityType, keyText, etag, values (a row's JSON)
FOUNDATION_EXPORT NSString * const ODSTombstoneEntity;     // entityType, keyText, deleted (a date), versions
FOUNDATION_EXPORT NSEntityDescription *ODSTombstoneEntityDescription(void);
// Each entity's key indexed (ODataSyncKey), its attributes in order: what
// ODataSync looks an app's objects up by, one at a time. Not where an
// index of the app's own begins with them. Before the model is used.
FOUNDATION_EXPORT void ODSIndexKeys(NSManagedObjectModel *model, NSArray<NSEntityDescription *> *entities);

@interface ODSStore : NSObject
// The engine's entities added to a model (and ODataSyncPeerConfiguration,
// the synced entities, for a peer server).
+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(nullable NSString *)configuration;

- (instancetype)initWithCoordinator:(NSPersistentStoreCoordinator *)coordinator codec:(ODSCodec *)codec NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *coordinator;

// A new private context on the coordinator, writing as this author.
- (NSManagedObjectContext *)contextWritingAs:(NSString *)author;

// The remote's state object (made when there is none), in this context.
- (NSManagedObject *)stateOf:(ODataSyncRemote *)remote inContext:(NSManagedObjectContext *)context;
// An object's outbox entry for the remote, and its shadow (made when asked
// and there is none): by root entity name and key text.
- (nullable NSManagedObject *)entryOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                            inContext:(NSManagedObjectContext *)context;
- (nullable NSManagedObject *)shadowOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                             inContext:(NSManagedObjectContext *)context make:(BOOL)make;
// A new outbox entry, last in line; the next place in line.
- (NSManagedObject *)newEntryOf:(NSEntityDescription *)root key:(NSDictionary *)key operation:(ODataSyncOperation)operation
                         remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context;
- (int64_t)nextSequenceIn:(NSManagedObjectContext *)context;

// Deletions remembered: whether an object (by root entity name and key
// text) was deleted here and not made again since; the deleted version's
// vector (empty: none kept, or not deleted); the deletion forgotten (made
// again by one that knew of it); those older than a time, forgotten.
- (BOOL)isDeleted:(NSString *)entityName keyText:(NSString *)keyText inContext:(NSManagedObjectContext *)context;
- (NSDictionary<NSString *, NSNumber *> *)deletedVersionsOf:(NSString *)entityName keyText:(NSString *)keyText
                                                  inContext:(NSManagedObjectContext *)context;
- (void)forgetDeletionOf:(NSString *)entityName keyText:(NSString *)keyText inContext:(NSManagedObjectContext *)context;
// A deletion kept: its version (nil: none known).
- (void)rememberDeletionOf:(NSString *)entityName keyText:(NSString *)keyText
                  versions:(nullable NSDictionary<NSString *, NSNumber *> *)versions inContext:(NSManagedObjectContext *)context;
- (void)forgetDeletionsBefore:(NSDate *)date;

// The store's metadata: its replica ID (made the first time); the count of
// this replica's next change; the model version noticed last (YES when it
// was another, and then what remotes refused is to go again).
- (NSString *)replicaID;
- (int64_t)nextCount;
- (BOOL)noticeModelVersion:(NSString *)version;

// The outbox: every entry, oldest first (those set aside as issues); those
// set aside; one sent again (retry) or given up (discard).
- (NSArray<ODataSyncChange *> *)pendingChanges;
- (NSArray<ODataSyncIssue *> *)issues;
- (void)changeIssue:(ODataSyncIssue *)issue discarding:(BOOL)discard;
@end

NS_ASSUME_NONNULL_END
