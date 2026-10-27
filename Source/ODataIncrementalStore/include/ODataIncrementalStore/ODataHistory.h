// ODataIncrementalStore — persistent history for a store over a service.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// With NSPersistentHistoryTrackingKey, the store keeps Core Data's
// persistent history: each save it makes is a transaction, and so is each
// read of what changed at the service (-[ODataIncrementalStore
// fetchRemoteChanges:]). An app catches up as with any store that tracks
// history: it fetches the transactions after the last token it kept
// (NSPersistentHistoryChangeRequest) and merges each one's
// objectIDNotification into its contexts.
//
// The history lives as long as the store: it is kept in memory, not with
// the service. A token from an earlier store stands before everything this
// one has recorded.

#pragma once
#import <ODataKit/OISCoreData.h>

NS_ASSUME_NONNULL_BEGIN

/* ODataIncrementalStore's own: exported where ODataIncrementalStore is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef ODATAINCREMENTALSTORE_EXPORT
#define ODATAINCREMENTALSTORE_EXPORT FOUNDATION_EXPORT
#endif

// The author of the transactions that record the service's changes.
ODATAINCREMENTALSTORE_EXPORT NSString * const ODataRemoteChangesAuthor;  // @"ODataIncrementalStore.remote"

@interface ODataHistoryToken : NSPersistentHistoryToken <NSSecureCoding>
@property (nonatomic, readonly, copy) NSString *storeID;
@property (nonatomic, readonly, copy) NSString *logID;         // the history it belongs to
@property (nonatomic, readonly) int64_t transactionNumber;
@end

@interface ODataHistoryChange : NSPersistentHistoryChange
@end

@interface ODataHistoryTransaction : NSPersistentHistoryTransaction
@end

// A store's history: what it records, and the answers to history requests.
@interface ODataHistoryLog : NSObject

- (instancetype)initWithStoreID:(NSString *)storeID;
@property (nonatomic, readonly, copy) NSString *storeID;
@property (nonatomic, readonly) int64_t lastTransactionNumber;
@property (nonatomic, readonly, strong) ODataHistoryToken *currentToken;

// Records a transaction of these changes; nothing when all are empty.
// updated maps each updated object's ID to the names of its changed
// properties (an empty set: unknown).
- (nullable NSPersistentHistoryTransaction *)recordInserted:(NSArray<NSManagedObjectID *> *)inserted
                                                    updated:(NSDictionary<NSManagedObjectID *, NSSet<NSString *> *> *)updated
                                                    deleted:(NSArray<NSManagedObjectID *> *)deleted
                                                     author:(nullable NSString *)author
                                                contextName:(nullable NSString *)contextName;

// The answer to an NSPersistentHistoryChangeRequest: an
// NSPersistentHistoryResult, as a store returns one.
- (nullable NSPersistentStoreResult *)resultForRequest:(NSPersistentHistoryChangeRequest *)request error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
