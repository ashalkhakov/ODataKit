// The OData extension's segment of the bottom area (ODWBottom.xib), behind
// a switch of its own:
//
// - Results: the last answer, its rows (a collection's value, or the one
//   entity) as a table, its JSON indented under them;
// - Wire Log: every exchange with the services, newest first; the chosen
//   one's request and response as they went;
// - Traces: each request's spans (WBTracesViewController).
//
// The line beside the switch says what the answer was (200 OK, 20 rows,
// 143 ms) or why there was none.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ODWServices, ODWAnswer;

typedef NS_ENUM(NSInteger, ODWBottomPane) {
  ODWBottomResults = 0,
  ODWBottomWireLog,
  ODWBottomTraces,
};

@interface ODWBottomViewController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
- (instancetype)initWithServices:(ODWServices *)services NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, weak, readonly) ODWServices *services;

@property (nonatomic, weak, readonly) NSSegmentedControl *paneSwitch;
@property (nonatomic, weak, readonly) NSTextField *statusLabel;
@property (nonatomic, weak, readonly) NSTableView *rowsTable;
@property (nonatomic, readonly) NSTextView *jsonView;
@property (nonatomic, weak, readonly) NSTableView *logTable;
@property (nonatomic, readonly) NSTextView *exchangeView;

// The answer shown.
@property (nonatomic, readonly, nullable) ODWAnswer *answer;
- (void)showAnswer:(nullable ODWAnswer *)answer;
@property (nonatomic, readonly) ODWBottomPane pane;
- (void)showPane:(ODWBottomPane)pane;
- (IBAction)paneChanged:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
