// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWBottomViewController.h"
#import "ODWServices.h"

@interface ODWBottomViewController ()
@property (nonatomic, readwrite, weak) IBOutlet NSSegmentedControl *paneSwitch;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *statusLabel;
@property (nonatomic, weak) IBOutlet NSTabView *tabView;
@property (nonatomic, readwrite, weak) IBOutlet NSTableView *rowsTable;
@property (nonatomic, strong) IBOutlet NSTableColumn *templateColumn;
@property (nonatomic, readwrite, strong) IBOutlet NSTextView *jsonView;
@property (nonatomic, readwrite, weak) IBOutlet NSTableView *logTable;
@property (nonatomic, readwrite, strong) IBOutlet NSTextView *exchangeView;
@property (nonatomic, weak) IBOutlet NSView *tracesHost;
@end

// A value as one line of a cell: text as it is, numbers and true/false as
// JSON writes them, a structure or a list as compact JSON, null empty.
static NSString *ODWCellText(id value)
{
  if (!value || value == [NSNull null]) return @"";
  if ([value isKindOfClass:[NSString class]]) return value;
  if ([value isKindOfClass:[NSNumber class]]) {
    // JSON's true and false are the numbers @YES and @NO are, on both
    // AppKits (no CoreFoundation on GNUstep to ask).
    if ([value isKindOfClass:[@YES class]]) return [value boolValue] ? @"true" : @"false";
    return [value stringValue];
  }
  NSData *data = [NSJSONSerialization isValidJSONObject:value] ? [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL] : nil;
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : [value description];
}

@implementation ODWBottomViewController {
  WBTracesViewController *_traces;
}

- (instancetype)initWithServices:(ODWServices *)services
{
  self = [super initWithNibName:@"ODWBottom" bundle:[NSBundle bundleForClass:[ODWBottomViewController class]]];
  if (!self) return nil;
  _services = services;
  self.title = @"OData";
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(answerCame:) name:ODWAnswerNotification object:services];
  [center addObserver:self selector:@selector(exchangeLogChanged:) name:ODWExchangeLogDidChangeNotification object:services];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// gnustep-gui has no -viewDidLoad: set up as the view loads.
- (void)loadView
{
  [super loadView];
  for (NSTextView *text in @[ _jsonView, _exchangeView ]) {
    text.font = [NSFont userFixedPitchFontOfSize:11];
    text.textContainer.widthTracksTextView = YES;
  }
  // The template column: the look each answer's columns are made in.
  [_templateColumn.tableView removeTableColumn:_templateColumn];
  _traces = [[WBTracesViewController alloc] initWithRecorder:[ODWServices traceRecorder]];
  NSView *traces = _traces.view;
  traces.frame = _tracesHost.bounds;
  traces.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [_tracesHost addSubview:traces];
  [self showAnswer:_services.lastAnswer];
  [_logTable reloadData];
}

#pragma mark The panes

- (ODWBottomPane)pane
{
  return (ODWBottomPane)MAX(0, _paneSwitch.selectedSegment);
}

- (void)showPane:(ODWBottomPane)pane
{
  (void)self.view;
  [_paneSwitch setSelectedSegment:pane];
  [_tabView selectTabViewItemAtIndex:pane];
  if (pane == ODWBottomTraces) [_traces reloadTraces];
  if (pane == ODWBottomWireLog) [_logTable reloadData];
}

- (IBAction)paneChanged:(id)sender
{
  [self showPane:(ODWBottomPane)MAX(0, _paneSwitch.selectedSegment)];
}

#pragma mark Results

- (void)answerCame:(NSNotification *)note
{
  if (self.isViewLoaded) [self showAnswer:note.userInfo[ODWAnswerKey]];
}

- (void)showAnswer:(ODWAnswer *)answer
{
  _answer = answer;
  if (!self.isViewLoaded) return;
  // Its columns, made in the template's look.
  for (NSTableColumn *column in [_rowsTable.tableColumns copy]) [_rowsTable removeTableColumn:column];
  for (NSString *name in answer.columns) {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:name];
    [column.headerCell setStringValue:name];
    column.dataCell = [_templateColumn.dataCell copy];
    column.width = _templateColumn.width;
    column.minWidth = _templateColumn.minWidth;
    column.editable = NO;
    [_rowsTable addTableColumn:column];
  }
  [_rowsTable reloadData];
  _jsonView.string = answer.text ?: @"";
  [_jsonView scrollRangeToVisible:NSMakeRange(0, 0)];
  _statusLabel.stringValue = [self statusOf:answer];
  if (answer && self.pane != ODWBottomResults) [self showPane:ODWBottomResults];
}

// 200 OK · 20 rows · 143 ms — Products?$top=20 (Northwind)
- (NSString *)statusOf:(ODWAnswer *)answer
{
  if (!answer) return @"No request sent yet: Send Request (⌘↩) in an .odata document.";
  if (answer.failure) return [NSString stringWithFormat:@"%@: %@", answer.title, answer.failure];
  NSMutableArray *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%ld %@", (long)answer.status,
                                                          [NSHTTPURLResponse localizedStringForStatusCode:answer.status].capitalizedString]];
  if (answer.rows) [parts addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)answer.rows.count, answer.rows.count == 1 ? @"row" : @"rows"]];
  [parts addObject:[NSString stringWithFormat:@"%.0f ms", answer.duration * 1000]];
  return [NSString stringWithFormat:@"%@ — %@ (%@)", [parts componentsJoinedByString:@" · "], answer.title, answer.service.name ?: @""];
}

#pragma mark The wire log

- (void)exchangeLogChanged:(NSNotification *)note
{
  if (!self.isViewLoaded) return;
  WBExchangeLog *log = _services.exchangeLog;
  WorkbenchLogEntry *shown = [log entryAtRow:_logTable.selectedRow];
  [_logTable reloadData];
  NSUInteger again = shown ? [log.entries indexOfObjectIdenticalTo:shown] : NSNotFound;
  if (again != NSNotFound) [_logTable selectRowIndexes:[NSIndexSet indexSetWithIndex:again] byExtendingSelection:NO];
}

- (void)showExchange:(WorkbenchLogEntry *)entry
{
  _exchangeView.string = entry ? [NSString stringWithFormat:@"%@\n\n%@", [WBExchangeLog rawRequestOf:entry], [WBExchangeLog rawResponseOf:entry]]
                               : @"Choose an exchange.";
  [_exchangeView scrollRangeToVisible:NSMakeRange(0, 0)];
}

#pragma mark NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  if (table == _logTable) return (NSInteger)_services.exchangeLog.entries.count;
  return (NSInteger)_answer.rows.count;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _logTable) return [_services.exchangeLog valueForColumn:column.identifier row:row];
  if (row < 0 || (NSUInteger)row >= _answer.rows.count) return nil;
  return ODWCellText(_answer.rows[(NSUInteger)row][column.identifier]);
}

- (void)tableViewSelectionDidChange:(NSNotification *)note
{
  if (note.object == _logTable) [self showExchange:[_services.exchangeLog entryAtRow:_logTable.selectedRow]];
}

@end
