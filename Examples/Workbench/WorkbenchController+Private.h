// What the window controller keeps to itself, and its self-test reads.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "WorkbenchController.h"
#import "WBConnection.h"
#import "WBQuery.h"
#import "WBResults.h"
#import "WBTraces.h"
#import "WBSync.h"
#import "WBSignInPanel.h"

@interface WorkbenchController () <ODataSignInDelegate>

// The three parts: the connection, the query, and its results.
@property (nonatomic, strong) WBConnection *connection;
// Signing in to a service that asks for it: one sign-in for each service
// root, its tokens in the system's secret store; the panel while it asks.
@property (nonatomic, strong) NSMutableDictionary<NSString *, ODataSignIn *> *signIns;
@property (nonatomic, strong, nullable) WBSignInPanel *signInPanel;
@property (nonatomic, strong) WBQuery *query;
@property (nonatomic, strong) WBResults *results;
// The service's canned queries, as the presets menu lists them.
@property (nonatomic, copy) NSArray<NSDictionary *> *presets;

// The query panel's lists and fields (WorkbenchWindow.xib).
@property (nonatomic, strong) IBOutlet NSTableView *sortTable;
@property (nonatomic, strong) IBOutlet NSOutlineView *expandOutline;
@property (nonatomic, strong) IBOutlet NSTableView *selectTable;
@property (nonatomic, strong) IBOutlet NSTextField *searchField;
@property (nonatomic, strong) IBOutlet NSTextField *computeField;
@property (nonatomic, strong) IBOutlet NSTextField *groupField;
@property (nonatomic, strong) IBOutlet NSTextField *aggregateField;
@property (nonatomic, strong) IBOutlet NSTextField *timeField;

// What acts on the selected result.
@property (nonatomic, strong) IBOutlet NSButton *deleteButton;
@property (nonatomic, strong) IBOutlet NSButton *faultButton;
@property (nonatomic, strong) IBOutlet NSButton *fireButton;
@property (nonatomic, strong) IBOutlet NSPopUpButton *streamPopup;
@property (nonatomic, strong) IBOutlet NSButton *downloadButton;
@property (nonatomic, strong) IBOutlet NSButton *uploadButton;

// The wire log, newest first, and the window that shows one exchange
// (ExchangeWindow.xib, loaded when first shown).
@property (nonatomic, strong) NSMutableArray *log;
@property (nonatomic, strong) IBOutlet NSTableView *logTable;
@property (nonatomic, strong) IBOutlet NSWindow *exchangeWindow;
@property (nonatomic, strong) IBOutlet NSTextView *requestView;
@property (nonatomic, strong) IBOutlet NSTextView *responseView;
@property (nonatomic, strong) IBOutlet NSMenu *storeMenu;

// Explain: the built-in service's plan for the query, physical and logical
// (PlanWindow.xib, loaded when first shown).
@property (nonatomic, strong) IBOutlet NSButton *explainButton;
@property (nonatomic, strong) IBOutlet NSWindow *planWindow;
@property (nonatomic, strong) IBOutlet NSTextView *explainedView;
@property (nonatomic, strong) IBOutlet NSTextView *physicalPlanView;
@property (nonatomic, strong) IBOutlet NSTextView *logicalPlanView;

// Traces: every span the store, its requests and the built-in service
// make, kept (the recorder), and shown (Trace > Show Traces, or an
// exchange's own).
@property (nonatomic, strong) WBTraceRecorder *traceRecorder;
@property (nonatomic, strong) WBTraceWindow *traceWindow;
// Sync: an offline device beside the built-in service (Sync > Show Device).
@property (nonatomic, strong) WBSyncWindow *syncWindow;

// How many rows a screen holds, as a test says; 0: as the table's height says.
@property (nonatomic) NSUInteger screenfulForTests;

// The query, as the panel says it now.
- (WBQuery *)currentQuery;
- (NSManagedObject *)selectedObject;
- (void)inspectSelection;
- (NSString *)itemForPath:(NSString *)path;
- (void)show:(NSString *)text in:(NSTextView *)view;
- (void)setQueryValue:(id)value in:(NSTableView *)table column:(NSTableColumn *)column row:(NSInteger)row;
- (void)outlineView:(NSOutlineView *)outline setObjectValue:(id)value forTableColumn:(NSTableColumn *)column byItem:(id)item;
- (void)predicateChanged:(NSNotification *)notification;
- (void)loadNextPage;
- (void)rebuildOperations;
- (void)rebuildStreams;
- (BOOL)uploadStreamFromFile:(NSURL *)file;
- (IBAction)addSort:(id)sender;
- (IBAction)moveSortUp:(id)sender;
- (IBAction)downloadStream:(id)sender;
- (IBAction)showExchange:(id)sender;
- (IBAction)explainQuery:(id)sender;
- (IBAction)setMergePolicy:(NSMenuItem *)sender;
- (IBAction)toggleRespondAsync:(id)sender;
- (IBAction)toggleServeNetwork:(id)sender;
- (IBAction)showTraces:(id)sender;
// The selected exchange's trace, the span that sent it chosen.
- (IBAction)showTraceOfExchange:(id)sender;
- (IBAction)clearTraces:(id)sender;
- (IBAction)showSync:(id)sender;
// The device for the built-in service now (made, or made again for a new
// one); nil for another service.
- (WBSyncWindow *)syncDevice;

@end
