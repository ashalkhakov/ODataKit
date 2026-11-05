// The query panel (WBQueryPanel.xib): everything a fetch request can ask of
// the store (an entity, a predicate, $top and $skip, a page size, sort keys,
// relationships to prefetch, properties to select, $search, computed values,
// a grouping, application time, the result type), and the GET the store
// will send for it. The Workbench's window shows it above the results, in a
// line (WBQueryPanel.xib); UDCode's OData extension, as its builder's
// editor, stacked a row a field (WBQueryPanelStacked.xib). Execute and Explain go
// to the first responder (-runFetch:, -explainQuery:): the host's.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>
#import "WBConnection.h"
#import "WBQuery.h"

NS_ASSUME_NONNULL_BEGIN

@interface WBQueryPanel : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource,
                                            NSOutlineViewDelegate, NSTextFieldDelegate>
// In a line (the Workbench's window).
- (instancetype)init;
// Stacked, for a host narrower than the Workbench's window (UDCode's OData
// builder): the GET, Explain and Execute are left to the host (nil).
- (instancetype)initStacked:(BOOL)stacked NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// What the GET is worked out against: the store it is sent to.
@property (nonatomic, strong, nullable) WBConnection *connection;
// The query the panel edits: set, its entities listed and its values shown.
@property (nonatomic, strong, nullable) WBQuery *query;
// The query, as the panel says it now (its values read into it).
- (nullable WBQuery *)currentQuery;
// The query's values into the panel again (after it changed elsewhere).
- (void)showQueryControls;
// A preset (WBQuery's +presetsForService:model:) applied.
- (void)applyPreset:(NSDictionary *)preset;
// The GET the store would send, shown under the panel; and as text.
- (void)refreshTranslation;
@property (nonatomic, readonly, copy) NSString *translation;
// Told when the query changes (a field, a list, a switch, the entity, a
// preset): the host's results are no longer its answer.
@property (nonatomic, copy, nullable) void (^queryDidChange)(void);

@property (nonatomic, readonly) NSPopUpButton *entityPopup;
@property (nonatomic, readonly) NSPopUpButton *resultTypePopup;
@property (nonatomic, readonly) NSTextField *limitField;
@property (nonatomic, readonly) NSTextField *skipField;
@property (nonatomic, readonly) NSTextField *batchSizeField;
@property (nonatomic, readonly) NSButton *subentitiesButton;
@property (nonatomic, readonly) NSButton *faultsButton;
@property (nonatomic, readonly) NSTextView *predicateView;
// The predicate built: rows of the entity's attributes, under All, Any or
// None. The text stays the query's; the builder shows it where it can.
@property (nonatomic, readonly) NSPredicateEditor *predicateEditor;
// Builder or Text. Builder is off for a text it cannot show: OData's own
// options ($...), a hierarchy test, what no row can say.
@property (nonatomic, readonly) NSSegmentedControl *predicateModeControl;
@property (nonatomic, readonly) BOOL showsPredicateBuilder;
@property (nonatomic, readonly) NSTextField *timeField;
@property (nonatomic, readonly) NSTableView *sortTable;
@property (nonatomic, readonly) NSOutlineView *expandOutline;
@property (nonatomic, readonly) NSTableView *selectTable;
@property (nonatomic, readonly) NSTextField *searchField;
@property (nonatomic, readonly) NSTextField *computeField;
@property (nonatomic, readonly) NSTextField *groupField;
@property (nonatomic, readonly) NSTextField *aggregateField;
@property (nonatomic, readonly) NSTextField *wireURLField;
// Execute: runFetch: to the first responder.
@property (nonatomic, readonly) NSButton *executeButton;
@property (nonatomic, readonly) NSButton *explainButton;

// The predicate typed in (its text view's change).
- (void)predicateChanged:(nullable NSNotification *)notification;
// The predicate built (the editor's action): written into the text.
- (IBAction)predicateEdited:(nullable id)sender;
// Builder or Text chosen.
- (IBAction)predicateModeChanged:(nullable id)sender;
- (IBAction)entityChanged:(nullable id)sender;
- (IBAction)queryChanged:(nullable id)sender;
- (IBAction)addSort:(nullable id)sender;
- (IBAction)removeSort:(nullable id)sender;
- (IBAction)moveSortUp:(nullable id)sender;
- (IBAction)moveSortDown:(nullable id)sender;
// The outline's items are key paths from the current entity, one string
// per path, so the outline can tell them apart.
- (NSString *)itemForPath:(NSString *)path;
- (void)setQueryValue:(id)value in:(NSTableView *)table column:(NSTableColumn *)column row:(NSInteger)row;
@end

NS_ASSUME_NONNULL_END
