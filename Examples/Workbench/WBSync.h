// An offline device beside the built-in service: its own store, kept in
// sync by ODataSync (docs/offline-sync.md), and a window that shows it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>
#import <ODataSync/ODataSync.h>
#import "WorkbenchEngine.h"
#import "WorkbenchDevice.h"

NS_ASSUME_NONNULL_BEGIN

// The device's window: a WorkbenchDevice (WorkbenchDevice.h) in a SQLite
// store of its own, which reaches the service through the built-in engine
// (so its exchanges are in the wire log, and its syncs in Traces), unless
// offline.
@interface WBSyncWindow : NSObject <NSTableViewDataSource, NSTableViewDelegate>
// The Workbench's: a device of its own, over the built-in engine.
- (nullable instancetype)initWithEngine:(WorkbenchEngine *)engine;
// Another app's device (the Device apps'): its owner tells the window what
// changed (-changed:) and what was logged (-logged:). Without an engine,
// no Change at the Service.
- (instancetype)initWithDevice:(WorkbenchDevice *)device engine:(nullable WorkbenchEngine *)engine NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, nullable) WorkbenchEngine *engine;
// A new one shown (its owner reset it).
@property (nonatomic, strong) WorkbenchDevice *device;
// What Reset Device does instead of resetting the device in place: the
// owner makes a new one (and sets device).
@property (nonatomic, copy, nullable) void (^resetsDevice)(void);
// Told when the conflict rule, Offline or Sync each change was changed
// here (the owner keeps them).
@property (nonatomic, copy, nullable) void (^didChangeSetting)(void);
- (void)changed:(NSString *)status;
- (void)logged:(WorkbenchLogEntry *)entry;
@property (nonatomic, readonly) ODataSyncEngine *sync;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *deviceStore;
// The device's objects, as the table shows them (the main queue's).
@property (nonatomic, readonly) NSManagedObjectContext *context;

@property (nonatomic, readonly) NSWindow *window;
@property (nonatomic, readonly) NSPopUpButton *entityPopup;
@property (nonatomic, readonly) NSPopUpButton *rulePopup;
@property (nonatomic, readonly) NSButton *offlineButton;
// On: each change on the device is followed by a sync.
@property (nonatomic, readonly) NSButton *autoSyncButton;
@property (nonatomic, readonly) NSButton *makeButton;
@property (nonatomic, readonly) NSButton *deleteButton;
// Which way the entity shown goes, and what that means.
@property (nonatomic, readonly) NSTextField *rulesField;
// The device's own exchanges, newest first: its request log.
@property (nonatomic, readonly) NSTableView *requestTable;
@property (nonatomic, readonly, copy) NSArray<WorkbenchLogEntry *> *requests;
@property (nonatomic, readonly) NSTableView *dataTable;
@property (nonatomic, readonly) NSTableView *changesTable;
@property (nonatomic, readonly) NSTableView *conflictTable;
@property (nonatomic, readonly) NSTextView *detailView;
@property (nonatomic, readonly) NSTextField *statusField;

// As the table shows them now.
@property (nonatomic, readonly, copy) NSArray<NSManagedObject *> *objects;
@property (nonatomic, readonly, copy) NSArray<ODataSyncChange *> *changes;
@property (nonatomic, readonly, copy) NSArray<WBSyncConflict *> *conflicts;
@property (nonatomic) WBSyncRule rule;
@property (nonatomic, getter=isOffline) BOOL offline;
// A sync (or half of one) running on its thread.
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

- (void)show;
// What the window's buttons do; the work runs away from the main thread,
// and the tables are read again when it is done.
- (IBAction)sync:(nullable id)sender;
- (IBAction)download:(nullable id)sender;
- (IBAction)upload:(nullable id)sender;
- (IBAction)reconcile:(nullable id)sender;
// The selected product's price raised at the service, as another client
// would (the first product, when none is selected).
- (IBAction)changeAtTheService:(nullable id)sender;
- (IBAction)newObject:(nullable id)sender;
- (IBAction)deleteObject:(nullable id)sender;
- (IBAction)retryIssue:(nullable id)sender;
- (IBAction)discardIssue:(nullable id)sender;
// The device emptied: a new store, which reads everything again.
- (IBAction)resetDevice:(nullable id)sender;
- (IBAction)entityChanged:(nullable id)sender;
- (IBAction)ruleChanged:(nullable id)sender;
- (IBAction)offlineChanged:(nullable id)sender;
// The tables read again from the store.
- (void)reload;

// What the self-test drives: a whole sync, waited for; an edit as the
// table's cell makes it; the device's value of an object's attribute.
- (BOOL)syncAndWait:(NSError *_Nullable *_Nullable)error;
- (void)setValue:(nullable id)value ofAttribute:(NSString *)attribute row:(NSInteger)row;
- (nullable id)valueOfAttribute:(NSString *)attribute entity:(NSString *)entity key:(id)key;
@end

NS_ASSUME_NONNULL_END
