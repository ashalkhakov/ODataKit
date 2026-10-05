// An offline device: the built-in model in a store of its own, kept in
// sync with the built-in service by ODataSync (docs/offline-sync.md). No
// views: the Workbench's Sync window (AppKit) and the Device app (UIKit,
// on iOS) show it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <ODataSync/ODataSync.h>
#import "WorkbenchModel.h"

NS_ASSUME_NONNULL_BEGIN

// How the device settles a conflict, as the menus list them.
typedef NS_ENUM(NSInteger, WBSyncRule) {
  WBSyncRuleRemoteWins = 0,
  WBSyncRuleDeviceWins,
  WBSyncRuleLastWriterWins,
  WBSyncRuleMergeFields,
  WBSyncRuleSetAside,  // deferred: an issue, to retry or discard
};
// The rules' titles, in WBSyncRule's order.
FOUNDATION_EXPORT NSArray<NSString *> *WBSyncRuleTitles(void);

// What a sync does: all of it, or one half, or the reconciliation.
typedef NS_ENUM(NSInteger, WBSyncAction) {
  WBSyncActionSync = 0,
  WBSyncActionDownload,
  WBSyncActionUpload,
  WBSyncActionReconcile,
};

// A conflict the device met, and how it went.
@interface WBSyncConflict : NSObject
@property (nonatomic, readonly) ODataSyncConflict *conflict;
@property (nonatomic, readonly) ODataSyncResolutionKind outcome;
@property (nonatomic, readonly) NSDate *date;
@end

// The device: its Categories, Suppliers and Locations come down from the
// service (down), and its Products and Stock both sides edit (both);
// Products are stamped (lastChanged) for last writer wins. It reaches the
// service through a transport (the Workbench's built-in engine, or the
// network), unless offline, and keeps a log of its own exchanges.
@interface WorkbenchDevice : NSObject <ODataSyncDelegate>
// The compiled Catalog model the built-in model is made from; the store at
// storeURL (nil: a temporary one, removed when the device goes).
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL serviceRoot:(NSURL *)serviceRoot
                                transport:(id<ODataTransport>)transport storeURL:(nullable NSURL *)storeURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
@property (nonatomic, readonly) ODataSyncEngine *sync;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *coordinator;
// The device's objects, as the views show them (the main queue's).
@property (nonatomic, readonly) NSManagedObjectContext *context;

// On the main thread: something finished (a save, a sync or half of one,
// the line going off or on), in words. The views read the device again.
@property (nonatomic, copy, nullable) void (^didChange)(NSString *status);
// On the main thread: one more exchange in requests.
@property (nonatomic, copy, nullable) void (^didLog)(WorkbenchLogEntry *entry);
// The device's exchanges, newest first (200 at most).
@property (nonatomic, readonly, copy) NSArray<WorkbenchLogEntry *> *requests;

@property (nonatomic) WBSyncRule rule;
@property (nonatomic, getter=isOffline) BOOL offline;
// Each change on the device is followed by a sync.
@property (nonatomic) BOOL syncsEachChange;
// A sync (or half of one) running on its thread.
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

// The entities the device shows, in the menus' order; which way each goes
// (down, both, up), as the model's userInfo says.
+ (NSArray<NSString *> *)entityNames;
- (NSString *)directionOfEntity:(NSString *)entity;
- (BOOL)entityIsEditable:(NSString *)entity;
// The entity, and which way it goes; what that means, in a few sentences.
- (NSString *)titleOfEntity:(NSString *)entity;
- (NSString *)rulesOfEntity:(NSString *)entity;
// What to show of it: the Catalog's columns, the version, the stamp and the
// history, its to-one relationships; which of them the device edits.
- (NSArray<NSString *> *)columnsOfEntity:(NSString *)entity;
- (BOOL)column:(NSString *)column isEditableInEntity:(NSString *)entity;

// As the store has them now, by key (the context is reset first).
- (NSArray<NSManagedObject *> *)objectsOfEntity:(NSString *)entity;
- (NSArray<ODataSyncChange *> *)pendingChanges;
- (NSArray<WBSyncConflict *> *)conflicts;
// The device's value of an object's attribute, read from the store.
- (nullable id)valueOfAttribute:(NSString *)attribute entity:(NSString *)entity key:(id)key;

// The work on a thread of its own; didChange says how it went. NO, and
// nothing done, while another runs.
- (BOOL)run:(WBSyncAction)action;
// The remote of the service (the first): where a peer token comes from.
@property (nonatomic, readonly) ODataSyncRemote *serviceRemote;
// A sync with one remote alone (a peer: its download, then its upload),
// on a thread of its own, said as "Sync with name"; NO while another runs.
// The remote is the engine's only while it runs.
- (BOOL)syncWithRemote:(ODataSyncRemote *)remote named:(NSString *)name;
// A whole sync, waited for.
- (BOOL)syncAndWait:(NSError *_Nullable *_Nullable)error;

// Edits, saved at once (then synced, with syncsEachChange); didChange says
// what happened. A value as typed: text, made the attribute's type.
- (void)setValue:(nullable id)value ofAttribute:(NSString *)attribute object:(NSManagedObject *)object;
- (nullable NSManagedObject *)newObjectOfEntity:(NSString *)entity;
- (void)deleteObject:(NSManagedObject *)object;
- (void)retryIssue:(ODataSyncIssue *)issue;
- (void)discardIssue:(ODataSyncIssue *)issue;
// Emptied: a new store, which reads everything again; the conflicts met
// are forgotten. NO when it does not open.
- (BOOL)reset;
@end

// What the views show, as text.
FOUNDATION_EXPORT NSString *WBKeyText(NSDictionary *key);
FOUNDATION_EXPORT NSString *WBOutcomeName(ODataSyncResolutionKind kind);
FOUNDATION_EXPORT NSString *WBTimeText(NSDate *date);
// A change waiting: what it does (update name, unitPrice), and why it was
// set aside ("" when it was not).
FOUNDATION_EXPORT NSString *WBChangeText(ODataSyncChange *change);
FOUNDATION_EXPORT NSString *WBIssueText(ODataSyncChange *change);
// What each side changed of a conflict ("deleted" when it deleted it).
FOUNDATION_EXPORT NSString *WBConflictSideText(WBSyncConflict *met, BOOL local);
// A conflict's three versions: the one both last agreed on, the device's,
// the service's (* changed).
FOUNDATION_EXPORT NSString *WBConflictText(WBSyncConflict *met);
// An exchange: what went and what came back, headers and bodies.
FOUNDATION_EXPORT NSString *WBRequestText(WorkbenchLogEntry *entry);
// Its URL after the service root.
FOUNDATION_EXPORT NSString *WBRequestPath(WorkbenchLogEntry *entry, NSURL *serviceRoot);

NS_ASSUME_NONNULL_END
