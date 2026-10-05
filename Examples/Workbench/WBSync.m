// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBSync.h"
#import "WorkbenchSupport.h"

static NSTableColumn *WBSyncColumn(NSString *identifier, NSString *title, CGFloat width)
{
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
  [column.headerCell setStringValue:title];
  column.width = width;
  column.editable = NO;
  return column;
}

static NSButton *WBSyncButton(NSString *title, NSRect frame, id target, SEL action)
{
  NSButton *button = [[NSButton alloc] initWithFrame:frame];
  button.title = title;
#if defined(__APPLE__)
  button.bezelStyle = NSBezelStyleRounded;
#else
  button.bezelStyle = NSRoundedBezelStyle;
#endif
  button.target = target;
  button.action = action;
  return button;
}

@implementation WBSyncWindow {
  NSArray<NSString *> *_columns;
}

- (instancetype)initWithEngine:(WorkbenchEngine *)engine
{
  WorkbenchDevice *device = [[WorkbenchDevice alloc] initWithModelURL:engine.modelURL serviceRoot:engine.serviceRoot transport:engine storeURL:nil];
  if (!device) return nil;
  self = [self initWithDevice:device engine:engine];
  if (!self) return nil;
  __weak WBSyncWindow *weak = self;
  device.didLog = ^(WorkbenchLogEntry *entry) {
    [weak logged:entry];
  };
  device.didChange = ^(NSString *status) {
    [weak changed:status];
  };
  return self;
}

- (instancetype)initWithDevice:(WorkbenchDevice *)device engine:(WorkbenchEngine *)engine
{
  self = [super init];
  if (!self) return nil;
  _engine = engine;
  _device = device;
  _objects = @[];
  _changes = @[];
  _conflicts = @[];
  [self makeWindow];
  [self entityChanged:nil];
  return self;
}

- (void)setDevice:(WorkbenchDevice *)device
{
  _device = device;
  [_rulePopup selectItemAtIndex:device.rule];
  _offlineButton.state = device.offline ? NSOnState : NSOffState;
  _autoSyncButton.state = device.syncsEachChange ? NSOnState : NSOffState;
  [self entityChanged:nil];
  [self reload];
}

- (ODataSyncEngine *)sync
{
  return _device.sync;
}

- (NSPersistentStoreCoordinator *)deviceStore
{
  return _device.coordinator;
}

- (NSManagedObjectContext *)context
{
  return _device.context;
}

- (NSArray<WorkbenchLogEntry *> *)requests
{
  return _device.requests;
}

- (BOOL)isBusy
{
  return _device.busy;
}

#pragma mark The window

- (NSScrollView *)scrollViewFor:(NSView *)document frame:(NSRect)frame
{
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.borderType = NSBezelBorder;
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.documentView = document;
  return scroll;
}

- (NSTextField *)labelWithFrame:(NSRect)frame text:(NSString *)text
{
  NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
  label.stringValue = text;
  label.editable = NO;
  label.selectable = NO;
  label.bordered = NO;
  label.drawsBackground = NO;
  return label;
}

- (NSTableView *)tableWithColumns:(NSArray<NSTableColumn *> *)columns frame:(NSRect)frame
{
  NSTableView *table = [[NSTableView alloc] initWithFrame:frame];
  for (NSTableColumn *column in columns) [table addTableColumn:column];
  table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
  table.dataSource = self;
  table.delegate = self;
  table.allowsEmptySelection = YES;
  return table;
}

- (void)makeWindow
{
  NSRect frame = NSMakeRect(160, 100, 1180, 780);
  _window = [[NSWindow alloc] initWithContentRect:frame
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                  NSWindowStyleMaskMiniaturizable
                                          backing:NSBackingStoreBuffered defer:YES];
  _window.title = @"Sync: an Offline Device";
  _window.releasedWhenClosed = NO;
  _window.minSize = NSMakeSize(760, 480);
  NSView *content = _window.contentView;
  CGFloat width = frame.size.width, height = frame.size.height;

  // Along the top: what a sync does, the rule, the line.
  CGFloat top = height - 40, x = 12;
  for (NSArray *button in @[ @[ @"Sync", NSStringFromSelector(@selector(sync:)), @70 ],
                             @[ @"Download", NSStringFromSelector(@selector(download:)), @90 ],
                             @[ @"Upload", NSStringFromSelector(@selector(upload:)), @76 ],
                             @[ @"Reconcile", NSStringFromSelector(@selector(reconcile:)), @90 ],
                             @[ @"Change at the Service", NSStringFromSelector(@selector(changeAtTheService:)), @170 ] ]) {
    // Another client's change: the Workbench's alone, whose service it is.
    if (!_engine && [button[1] isEqualToString:NSStringFromSelector(@selector(changeAtTheService:))]) continue;
    NSButton *made = WBSyncButton(button[0], NSMakeRect(x, top, [button[2] doubleValue], 28), self, NSSelectorFromString(button[1]));
    made.autoresizingMask = NSViewMinYMargin;
    [content addSubview:made];
    x += [button[2] doubleValue] + 6;
  }
  NSTextField *conflicts = [self labelWithFrame:NSMakeRect(x + 8, top + 4, 70, 20) text:@"Conflicts:"];
  conflicts.autoresizingMask = NSViewMinYMargin;
  [content addSubview:conflicts];
  _rulePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x + 80, top + 2, 200, 26) pullsDown:NO];
  [_rulePopup addItemsWithTitles:WBSyncRuleTitles()];
  _rulePopup.target = self;
  _rulePopup.action = @selector(ruleChanged:);
  _rulePopup.autoresizingMask = NSViewMinYMargin;
  [content addSubview:_rulePopup];
  _offlineButton = [[NSButton alloc] initWithFrame:NSMakeRect(x + 292, top + 4, 80, 22)];
  [_offlineButton setButtonType:NSSwitchButton];
  _offlineButton.title = @"Offline";
  _offlineButton.target = self;
  _offlineButton.action = @selector(offlineChanged:);
  _offlineButton.autoresizingMask = NSViewMinYMargin;
  [content addSubview:_offlineButton];
  _autoSyncButton = [[NSButton alloc] initWithFrame:NSMakeRect(x + 372, top + 4, 140, 22)];
  [_autoSyncButton setButtonType:NSSwitchButton];
  _autoSyncButton.title = @"Sync each change";
  _autoSyncButton.autoresizingMask = NSViewMinYMargin;
  [content addSubview:_autoSyncButton];
  NSButton *reset = WBSyncButton(@"Reset Device", NSMakeRect(width - 122, top, 110, 28), self, @selector(resetDevice:));
  reset.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [content addSubview:reset];

  // Along the bottom: what happened last.
  _statusField = [self labelWithFrame:NSMakeRect(12, 8, width - 24, 20) text:@"Sync reads the service's data into the device."];
  _statusField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [content addSubview:_statusField];

  NSSplitView *across = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 34, width, height - 84)];
  across.vertical = YES;
  across.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // At the left: the device's objects, edited in place.
  NSView *left = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, height - 84)];
  left.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  CGFloat leftHeight = left.frame.size.height;
  _entityPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(8, leftHeight - 30, 220, 26) pullsDown:NO];
  for (NSString *entity in [WorkbenchDevice entityNames]) {
    [_entityPopup addItemWithTitle:[_device titleOfEntity:entity]];
    _entityPopup.lastItem.representedObject = entity;
  }
  _entityPopup.target = self;
  _entityPopup.action = @selector(entityChanged:);
  _entityPopup.autoresizingMask = NSViewMinYMargin;
  [left addSubview:_entityPopup];
  _makeButton = WBSyncButton(@"New", NSMakeRect(236, leftHeight - 32, 64, 28), self, @selector(newObject:));
  _makeButton.autoresizingMask = NSViewMinYMargin;
  [left addSubview:_makeButton];
  _deleteButton = WBSyncButton(@"Delete", NSMakeRect(304, leftHeight - 32, 72, 28), self, @selector(deleteObject:));
  _deleteButton.autoresizingMask = NSViewMinYMargin;
  [left addSubview:_deleteButton];
  // What the rules are, for the entity shown.
  _rulesField = [self labelWithFrame:NSMakeRect(8, leftHeight - 84, 544, 50) text:@""];
  [_rulesField.cell setWraps:YES];
  _rulesField.font = [NSFont systemFontOfSize:11];
  _rulesField.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
  [left addSubview:_rulesField];
  _dataTable = [self tableWithColumns:@[] frame:NSMakeRect(0, 0, 560, leftHeight - 90)];
  NSScrollView *data = [self scrollViewFor:_dataTable frame:NSMakeRect(0, 0, 560, leftHeight - 90)];
  [left addSubview:data];
  [across addSubview:left];

  // At the right: what waits to be sent, the conflicts met, one in detail.
  NSSplitView *down = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 520, height - 84)];
  down.vertical = NO;
  down.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSView *waiting = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 220)];
  waiting.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSTextField *waitingLabel = [self labelWithFrame:NSMakeRect(8, 194, 220, 20) text:@"Waiting to be sent"];
  waitingLabel.autoresizingMask = NSViewMinYMargin;
  [waiting addSubview:waitingLabel];
  NSButton *retry = WBSyncButton(@"Retry", NSMakeRect(300, 190, 70, 28), self, @selector(retryIssue:));
  retry.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
  [waiting addSubview:retry];
  NSButton *discard = WBSyncButton(@"Discard", NSMakeRect(374, 190, 80, 28), self, @selector(discardIssue:));
  discard.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
  [waiting addSubview:discard];
  _changesTable = [self tableWithColumns:@[ WBSyncColumn(@"entity", @"Entity", 70), WBSyncColumn(@"key", @"Key", 60),
                                            WBSyncColumn(@"change", @"Change", 150), WBSyncColumn(@"attempts", @"Sent", 40),
                                            WBSyncColumn(@"issue", @"Set aside", 180) ]
                                    frame:NSMakeRect(0, 0, 520, 186)];
  [waiting addSubview:[self scrollViewFor:_changesTable frame:NSMakeRect(0, 0, 520, 186)]];
  [down addSubview:waiting];

  NSView *met = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 200)];
  met.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSTextField *metLabel = [self labelWithFrame:NSMakeRect(8, 176, 300, 20) text:@"Conflicts met"];
  metLabel.autoresizingMask = NSViewMinYMargin;
  [met addSubview:metLabel];
  _conflictTable = [self tableWithColumns:@[ WBSyncColumn(@"time", @"Time", 70), WBSyncColumn(@"entity", @"Entity", 70),
                                             WBSyncColumn(@"key", @"Key", 50), WBSyncColumn(@"here", @"Device changed", 110),
                                             WBSyncColumn(@"there", @"Service changed", 110), WBSyncColumn(@"outcome", @"Outcome", 90) ]
                                     frame:NSMakeRect(0, 0, 520, 172)];
  [met addSubview:[self scrollViewFor:_conflictTable frame:NSMakeRect(0, 0, 520, 172)]];
  [down addSubview:met];

  NSView *asked = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 180)];
  asked.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSTextField *askedLabel = [self labelWithFrame:NSMakeRect(8, 156, 300, 20) text:@"The device's requests"];
  askedLabel.autoresizingMask = NSViewMinYMargin;
  [asked addSubview:askedLabel];
  _requestTable = [self tableWithColumns:@[ WBSyncColumn(@"time", @"Time", 70), WBSyncColumn(@"method", @"Method", 60),
                                            WBSyncColumn(@"url", @"URL", 260), WBSyncColumn(@"status", @"Status", 50),
                                            WBSyncColumn(@"ms", @"ms", 50) ]
                                    frame:NSMakeRect(0, 0, 520, 152)];
  [asked addSubview:[self scrollViewFor:_requestTable frame:NSMakeRect(0, 0, 520, 152)]];
  [down addSubview:asked];

  _detailView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 520, 200)];
  _detailView.editable = NO;
  _detailView.richText = NO;
  _detailView.font = [NSFont userFixedPitchFontOfSize:11];
  // GNUstep leaves a text view made in code black on black.
  _detailView.textColor = [NSColor textColor];
  _detailView.backgroundColor = [NSColor textBackgroundColor];
  _detailView.drawsBackground = YES;
  _detailView.verticallyResizable = YES;
  _detailView.horizontallyResizable = NO;
  _detailView.autoresizingMask = NSViewWidthSizable;
  _detailView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
  _detailView.textContainer.widthTracksTextView = YES;
  _detailView.string = @"Select a conflict for its three versions (the one both last agreed on, the device's, the service's; * changed), "
                       @"or a request for what went and what came back.";
  [down addSubview:[self scrollViewFor:_detailView frame:NSMakeRect(0, 0, 520, 200)]];
  [across addSubview:down];
  [content addSubview:across];
  [across adjustSubviews];
  [down adjustSubviews];
  [across setPosition:560 ofDividerAtIndex:0];
  [down setPosition:180 ofDividerAtIndex:0];
  [down setPosition:340 ofDividerAtIndex:1];
  [down setPosition:540 ofDividerAtIndex:2];
}

- (void)show
{
  [self reload];
  [_window makeKeyAndOrderFront:nil];
}

#pragma mark Reading

- (NSString *)entityName
{
  return _entityPopup.selectedItem.representedObject ?: @"Product";
}

- (IBAction)entityChanged:(id)sender
{
  (void)sender;
  NSString *entity = [self entityName];
  _columns = [_device columnsOfEntity:entity];
  _rulesField.stringValue = [_device rulesOfEntity:entity];
  BOOL editable = [_device entityIsEditable:entity];
  _makeButton.enabled = editable;
  _deleteButton.enabled = editable;
  while (_dataTable.tableColumns.count) [_dataTable removeTableColumn:_dataTable.tableColumns.lastObject];
  for (NSString *name in _columns) {
    NSTableColumn *column = WBSyncColumn(name, name, [name isEqualToString:@"lastChanged"] || [name isEqualToString:@"versions"] ? 190 : 90);
    column.editable = [_device column:name isEditableInEntity:entity];
    [_dataTable addTableColumn:column];
  }
  [self reloadObjects];
}

- (void)logged:(WorkbenchLogEntry *)entry
{
  (void)entry;
  [_requestTable reloadData];
  // The newest at the top, in view.
  if (_requestTable.selectedRow < 1) [_requestTable scrollRowToVisible:0];
}

- (void)changed:(NSString *)status
{
  [self reload];
  _statusField.stringValue = status;
}

- (void)reloadObjects
{
  _objects = [_device objectsOfEntity:[self entityName]];
  [_dataTable reloadData];
}

- (void)reload
{
  [self reloadObjects];
  _changes = [_device pendingChanges];
  _conflicts = [_device conflicts];
  [_changesTable reloadData];
  [_conflictTable reloadData];
}

- (id)valueOfAttribute:(NSString *)attribute entity:(NSString *)entity key:(id)key
{
  return [_device valueOfAttribute:attribute entity:entity key:key];
}

#pragma mark Running

- (IBAction)sync:(id)sender
{
  (void)sender;
  [_device run:WBSyncActionSync];
}

- (IBAction)download:(id)sender
{
  (void)sender;
  [_device run:WBSyncActionDownload];
}

- (IBAction)upload:(id)sender
{
  (void)sender;
  [_device run:WBSyncActionUpload];
}

- (IBAction)reconcile:(id)sender
{
  (void)sender;
  [_device run:WBSyncActionReconcile];
}

- (BOOL)syncAndWait:(NSError **)error
{
  BOOL ok = [_device syncAndWait:error];
  [self reload];
  return ok;
}

- (IBAction)changeAtTheService:(id)sender
{
  (void)sender;
  NSInteger row = _dataTable.selectedRow;
  NSNumber *product = [[self entityName] isEqualToString:@"Product"] && row >= 0 && (NSUInteger)row < _objects.count
      ? [_objects[(NSUInteger)row] valueForKey:@"id"] : nil;
  _statusField.stringValue = [[_engine changeProductAtTheService:product] stringByAppendingString:@" Sync to meet it."];
}

#pragma mark Changing the device

// The switch as it is now (the self-test sets it without its action).
- (void)takeAutoSync
{
  BOOL syncs = _autoSyncButton.state == NSOnState;
  if (syncs == _device.syncsEachChange) return;
  _device.syncsEachChange = syncs;
  if (self.didChangeSetting) self.didChangeSetting();
}

- (void)setValue:(id)value ofAttribute:(NSString *)name row:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _objects.count) return;
  [self takeAutoSync];
  [_device setValue:value ofAttribute:name object:_objects[(NSUInteger)row]];
}

- (IBAction)newObject:(id)sender
{
  (void)sender;
  [self takeAutoSync];
  [_device newObjectOfEntity:[self entityName]];
}

- (IBAction)deleteObject:(id)sender
{
  (void)sender;
  NSInteger row = _dataTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _objects.count) return;
  [self takeAutoSync];
  [_device deleteObject:_objects[(NSUInteger)row]];
}

- (ODataSyncIssue *)selectedIssue
{
  NSInteger row = _changesTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _changes.count) return nil;
  ODataSyncChange *change = _changes[(NSUInteger)row];
  return [change isKindOfClass:[ODataSyncIssue class]] ? (ODataSyncIssue *)change : nil;
}

- (IBAction)retryIssue:(id)sender
{
  (void)sender;
  ODataSyncIssue *issue = [self selectedIssue];
  if (!issue) {
    _statusField.stringValue = @"Select a change set aside to retry it.";
    return;
  }
  [_device retryIssue:issue];
}

- (IBAction)discardIssue:(id)sender
{
  (void)sender;
  ODataSyncIssue *issue = [self selectedIssue];
  if (!issue) {
    _statusField.stringValue = @"Select a change set aside to discard it.";
    return;
  }
  [_device discardIssue:issue];
}

- (IBAction)resetDevice:(id)sender
{
  (void)sender;
  if (_device.busy) return;
  if (self.resetsDevice) {
    self.resetsDevice();
    return;
  }
  if (![_device reset]) {
    _statusField.stringValue = @"The device's store does not open.";
    return;
  }
  [self entityChanged:nil];
  [self reload];
  _statusField.stringValue = @"A new device: Sync reads the service's data into it.";
}

- (WBSyncRule)rule
{
  return _device.rule;
}

- (void)setRule:(WBSyncRule)rule
{
  _device.rule = rule;
  [_rulePopup selectItemAtIndex:rule];
}

- (IBAction)ruleChanged:(id)sender
{
  (void)sender;
  _device.rule = (WBSyncRule)_rulePopup.indexOfSelectedItem;
  if (self.didChangeSetting) self.didChangeSetting();
}

- (BOOL)isOffline
{
  return _device.offline;
}

- (void)setOffline:(BOOL)offline
{
  _device.offline = offline;
  _offlineButton.state = offline ? NSOnState : NSOffState;
}

- (IBAction)offlineChanged:(id)sender
{
  (void)sender;
  _device.offline = _offlineButton.state == NSOnState;
  _statusField.stringValue = _device.offline ? @"Offline: change things on the device; they wait, and go when it is back."
                                             : @"Back online: Sync sends what waits.";
  if (self.didChangeSetting) self.didChangeSetting();
}

#pragma mark Tables

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  if (table == _dataTable) return (NSInteger)_objects.count;
  if (table == _changesTable) return (NSInteger)_changes.count;
  if (table == _conflictTable) return (NSInteger)_conflicts.count;
  if (table == _requestTable) return (NSInteger)self.requests.count;
  return 0;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  NSString *identifier = column.identifier;
  if (table == _dataTable) {
    if ((NSUInteger)row >= _objects.count) return nil;
    NSManagedObject *object = _objects[(NSUInteger)row];
    id value = [object valueForKey:identifier];
    if ([value isKindOfClass:[NSManagedObject class]]) return WBTitleOf(value, YES);
    return WBCellValue(value);
  }
  if (table == _changesTable) {
    if ((NSUInteger)row >= _changes.count) return nil;
    ODataSyncChange *change = _changes[(NSUInteger)row];
    if ([identifier isEqualToString:@"entity"]) return change.entityName;
    if ([identifier isEqualToString:@"key"]) return WBKeyText(change.key);
    if ([identifier isEqualToString:@"attempts"]) return @(change.attempts);
    if ([identifier isEqualToString:@"change"]) return WBChangeText(change);
    if ([identifier isEqualToString:@"issue"]) return WBIssueText(change);
    return nil;
  }
  if (table == _requestTable) {
    NSArray<WorkbenchLogEntry *> *requests = self.requests;
    if ((NSUInteger)row >= requests.count) return nil;
    WorkbenchLogEntry *entry = requests[(NSUInteger)row];
    if ([identifier isEqualToString:@"time"]) return WBTimeText(entry.date);
    if ([identifier isEqualToString:@"method"]) return entry.method;
    if ([identifier isEqualToString:@"url"]) return WBRequestPath(entry, _device.serviceRoot);
    if ([identifier isEqualToString:@"status"]) return entry.status ? @(entry.status) : @"-";
    if ([identifier isEqualToString:@"ms"]) return entry.duration ? [NSString stringWithFormat:@"%.0f", entry.duration * 1000] : @"";
    return nil;
  }
  if (table == _conflictTable) {
    if ((NSUInteger)row >= _conflicts.count) return nil;
    WBSyncConflict *met = _conflicts[(NSUInteger)row];
    if ([identifier isEqualToString:@"time"]) return WBTimeText(met.date);
    if ([identifier isEqualToString:@"entity"]) return met.conflict.entity.name;
    if ([identifier isEqualToString:@"key"]) return WBKeyText(met.conflict.key);
    if ([identifier isEqualToString:@"here"]) return WBConflictSideText(met, YES);
    if ([identifier isEqualToString:@"there"]) return WBConflictSideText(met, NO);
    if ([identifier isEqualToString:@"outcome"]) return WBOutcomeName(met.outcome);
  }
  return nil;
}

- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table != _dataTable) return;
  [self setValue:value ofAttribute:column.identifier row:row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  if (notification.object == _requestTable) {
    NSInteger selected = _requestTable.selectedRow;
    NSArray<WorkbenchLogEntry *> *requests = self.requests;
    if (selected >= 0 && (NSUInteger)selected < requests.count) _detailView.string = WBRequestText(requests[(NSUInteger)selected]);
    return;
  }
  if (notification.object != _conflictTable) return;
  NSInteger row = _conflictTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _conflicts.count) return;
  _detailView.string = WBConflictText(_conflicts[(NSUInteger)row]);
}

@end
