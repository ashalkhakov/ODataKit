// Workbench --self-test: the window driven as a person would drive it,
// against each service in turn.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchController+Private.h"
#import "WBUpdater.h"
#import <objc/runtime.h>

@implementation WorkbenchController (SelfTest)


// Workbench --self-test: the window driven as a person would drive it,
// against each service in turn; a line per check, and the exit status the
// number of failures. With WORKBENCH_SHOTS set, a PNG of the window per
// service goes there.
- (void)waitWhileConnecting
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
  while (self.connection.connecting && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  // Let the log's queued reports arrive.
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
}

- (void)shoot:(NSString *)name
{
  [self shoot:name window:self.window];
}

- (void)shoot:(NSString *)name window:(NSWindow *)window
{
  NSString *directory = [NSProcessInfo processInfo].environment[@"WORKBENCH_SHOTS"];
  if (!directory.length) return;
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
#if defined(__APPLE__)
  // Light, so dark mode's white labels do not vanish on the PDF's white.
  window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
#endif
  NSView *view = window.contentView;
  [view display];
  // As a PDF: a bitmap cache of the view leaves some controls blank.
  NSData *pdf = [view dataWithPDFInsideRect:view.bounds];
  [pdf writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"pdf"]] atomically:YES];
}

static int WBChecks, WBFailures;

static void WBCheck(BOOL ok, NSString *what, NSString *detail)
{
  WBChecks++;
  if (!ok) WBFailures++;
  fprintf(stderr, "%s  %s%s%s\n", ok ? "PASS" : "FAIL", what.UTF8String, detail.length ? " — " : "", detail.UTF8String ?: "");
}

// The built-in EquipmentUnits: an open type whose dynamic properties the
// service keeps in a Transformable, so a filter on one is evaluated by
// the service, the rest of it by the store; edited in the cell.
- (void)checkBuiltInOpenType
{
  [self runPreset:[self presetLabelled:@"Forklifts over 2 t"]];
  NSString *wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  NSArray *names = [self.results.rows valueForKey:@"name"];
  WBCheck(!self.results.lastError && [names isEqual:@[ @"Forklift FL-1" ]] &&
          [wire rangeOfString:@"$filter=Kind eq 'Forklift' and LoadCapacityKg gt 2000"].location != NSNotFound,
          @"open type: filtered by a dynamic property", self.results.lastError ?: [NSString stringWithFormat:@"%@ %@", names, wire]);
  [self explainQuery:nil];
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
  NSString *physical = self.physicalPlanView.string;
  NSRange here = [physical rangeOfString:@"LoadCapacityKg gt 2000"];
  NSRange store = [physical rangeOfString:@"Store scan EquipmentUnit where Kind eq 'Forklift'"];
  WBCheck(here.location != NSNotFound && store.location != NSNotFound && here.location < store.location &&
          [[physical substringFromIndex:store.location] rangeOfString:@"LoadCapacityKg"].location == NSNotFound,
          @"open type: explain filters the dynamic property here, over the store's scan", physical);
  [self.planWindow orderOut:nil];

  [self runPreset:[self presetLabelled:@"Equipment ("]];
  NSUInteger scale = [self rowWhere:@"name" is:@"Scale SC-1"];
  [self editColumn:@"dynamicProperties" row:scale value:@"MaxWeightKg=350; Calibrated=2026-03-01"];
  [self saveChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 0 inserted (POST), 1 updated"], @"open type: dynamic properties saved (PATCH)",
          self.statusField.stringValue);
  [self runPreset:[self presetLabelled:@"Equipment ("]];
  scale = [self rowWhere:@"name" is:@"Scale SC-1"];
  if (scale != NSNotFound) [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:scale] byExtendingSelection:NO];
  [self inspectSelection];
  NSString *shown = self.inspectorView.string;
  WBCheck([shown rangeOfString:@"MaxWeightKg = 350"].location != NSNotFound && [shown rangeOfString:@"Calibrated = 2026-03-01"].location != NSNotFound &&
          [shown rangeOfString:@"Certificate"].location == NSNotFound,
          @"open type: kept by the service, one left out removed", shown);
  [self shoot:@"Equipment"];
}

// TripPin's Person is an open type: dynamic properties, set in the cell,
// saved, read back typed, and filtered by.
- (void)checkDynamicProperties
{
  NSUInteger russell = [self rowWhere:@"userName" is:@"russellwhyte"];
  [self editColumn:@"dynamicProperties" row:russell value:@"Nickname='Rusty'; Visits=3; Since=2020-01-02"];
  [self saveChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 0 inserted (POST), 1 updated"], @"dynamic properties: saved (PATCH)",
          self.statusField.stringValue);
  self.predicateView.string = @"dynamicProperties.Nickname == 'Rusty'";
  [self predicateChanged:nil];
  [self runFetch:nil];
  NSString *wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  NSArray *names = [self.results.rows valueForKey:@"userName"];
  WBCheck([names isEqual:@[ @"russellwhyte" ]] && [wire rangeOfString:@"$filter=Nickname eq 'Rusty'"].location != NSNotFound,
          @"dynamic properties: filtered by one", [NSString stringWithFormat:@"%@ %@", names, wire]);
  if (names.count) [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [self inspectSelection];
  NSString *shown = self.inspectorView.string;
  WBCheck([shown rangeOfString:@"Nickname = Rusty"].location != NSNotFound && [shown rangeOfString:@"Since = 2020-01-02"].location != NSNotFound &&
          [shown rangeOfString:@"Visits = 3"].location != NSNotFound, @"dynamic properties: in the inspector, a date as a date", shown);
  [self shoot:@"TripPin-dynamic"];
  self.predicateView.string = @"";
  [self predicateChanged:nil];
}

- (void)editColumn:(NSString *)identifier row:(NSUInteger)row value:(id)value
{
  NSUInteger column = [[self.tableView.tableColumns valueForKey:@"identifier"] indexOfObject:identifier];
  if (row == NSNotFound || column == NSNotFound) return;
  [self tableView:self.tableView setObjectValue:value forTableColumn:self.tableView.tableColumns[column] row:(NSInteger)row];
}

// The row whose key has this value, the results scrolled as far as it
// takes: a screenful at a time, as scrolling to the end loads them.
- (NSUInteger)rowWhere:(NSString *)key is:(id)value
{
  NSUInteger found;
  while ((found = [[self.results.rows valueForKey:key] indexOfObject:value]) == NSNotFound && self.results.hasMore) {
    NSUInteger before = self.results.rows.count;
    [self loadNextPage];
    if (self.results.rows.count == before) break;
  }
  return found;
}

// Insert, fill in, Save (a POST); find it; Delete, Save (a DELETE); gone.
- (void)checkInsertAndDeleteWithKey:(NSString *)key value:(NSString *)value fields:(NSDictionary *)fields
{
  NSString *entity = [[self currentQuery] entity].name;
  // A short screen, however big this one is: the new row may be pages away.
  self.screenfulForTests = 5;
  [self insertObject:nil];
  [self editColumn:key row:0 value:value];
  for (NSString *field in fields) [self editColumn:field row:0 value:fields[field]];
  [self saveChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 1 inserted (POST)"], [NSString stringWithFormat:@"Insert a %@, Save (POST)", entity],
          self.statusField.stringValue);
  NSUInteger found = [self rowWhere:key is:value];
  WBCheck(found != NSNotFound, [NSString stringWithFormat:@"the new %@ is read back", entity], self.statusField.stringValue);
  if (found == NSNotFound) {
    self.screenfulForTests = 0;
    return;
  }
  [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:found] byExtendingSelection:NO];
  [self deleteSelected:nil];
  [self saveChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 0 inserted (POST), 0 updated (PATCH), 1 deleted"] &&
          [self rowWhere:key is:value] == NSNotFound,
          [NSString stringWithFormat:@"Delete it, Save (DELETE)"], self.statusField.stringValue);
  self.screenfulForTests = 0;
}

// The panel, clicked as a person would: two relationships prefetched, one
// nested; a second sort key through a relationship; two properties for a
// dictionary result.
- (void)checkQueryPanel
{
  [self.entityPopup selectItemWithTitle:@"Product"];
  [self entityChanged:nil];
  NSTableColumn *include = [self.expandOutline tableColumnWithIdentifier:@"include"];
  for (NSString *path in @[ @"category", @"suppliers", @"suppliers.products" ]) {
    [self outlineView:self.expandOutline setObjectValue:@YES forTableColumn:include byItem:[self itemForPath:path]];
  }
  [self addSort:nil];
  [self setQueryValue:@"category.name" in:self.sortTable column:[self.sortTable tableColumnWithIdentifier:@"key"] row:(NSInteger)self.query.sorts.count - 1];
  [self setQueryValue:@YES in:self.sortTable column:[self.sortTable tableColumnWithIdentifier:@"descending"] row:(NSInteger)self.query.sorts.count - 1];
  [self runFetch:nil];
  NSString *wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  WBCheck(!self.results.lastError && self.results.rows.count && [wire rangeOfString:@"$expand=Category("].location != NSNotFound &&
          [wire rangeOfString:@"Suppliers("].location != NSNotFound && [wire rangeOfString:@"$expand=Products("].location != NSNotFound &&
          [wire rangeOfString:@"$orderby=ProductID,Category/CategoryName desc"].location != NSNotFound,
          @"the query panel: nested prefetch, two sort keys", self.results.lastError ?: wire);

  // What was prefetched is in the table, and reading it asks nothing;
  // what was not asks the service.
  NSArray *columns = [self.tableView.tableColumns valueForKey:@"identifier"];
  NSUInteger chai = [[self.results.rows valueForKey:@"name"] indexOfObject:@"Chai"];
  NSTableColumn *categoryColumn = [self.tableView tableColumnWithIdentifier:@"category"];
  id shown = chai != NSNotFound && categoryColumn ? [self tableView:self.tableView objectValueForTableColumn:categoryColumn row:(NSInteger)chai] : nil;
  WBCheck([columns containsObject:@"category"] && [columns containsObject:@"suppliers"] && [shown isEqual:@"Beverages"],
          @"prefetched relationships are columns", [NSString stringWithFormat:@"%@; Chai's category: %@", columns, shown]);
  if (chai != NSNotFound) [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:chai] byExtendingSelection:NO];
  [self fireRelationships:nil];
  NSString *fired = self.inspectorView.string;
  WBCheck([fired rangeOfString:@"category (to-one) → Category — no request"].location != NSNotFound &&
          [fired rangeOfString:@"suppliers (to-many, 2) — no request"].location != NSNotFound &&
          [fired rangeOfString:@"stocks (to-many, 2) — 1 request to the service"].location != NSNotFound,
          @"Fire relationships: the prefetched ones ask nothing, the rest ask", fired);

  [self.resultTypePopup selectItemWithTitle:@"dictionary"];
  NSTableColumn *property = [self.selectTable tableColumnWithIdentifier:@"include"];
  NSArray *names = [[self currentQuery] attributeNames];
  for (NSString *name in @[ @"name", @"unitPrice" ]) {
    [self setQueryValue:@YES in:self.selectTable column:property row:(NSInteger)[names indexOfObject:name]];
  }
  [self runFetch:nil];
  wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  WBCheck(!self.results.lastError && self.results.rows.count && [wire rangeOfString:@"$select=ProductName,UnitPrice"].location != NSNotFound &&
          [[self.results.rows.firstObject allKeys] count] == 2,
          @"the query panel: $select from the checklist", self.results.lastError ?: wire);
  [self.resultTypePopup selectItemWithTitle:@"objects"];
}

// The wire log lists the exchanges; choosing one shows it whole: the
// $metadata request, and its answer to the last byte.
- (void)checkExchangeLog
{
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  NSUInteger metadata = NSNotFound;
  for (NSUInteger i = 0; i < self.log.count; i++) {
    WorkbenchLogEntry *logged = self.log[i];
    if ([logged.URL hasSuffix:@"$metadata"]) metadata = i;
  }
  WorkbenchLogEntry *entry = metadata != NSNotFound ? self.log[metadata] : nil;
  if (entry) [self.logTable selectRowIndexes:[NSIndexSet indexSetWithIndex:metadata] byExtendingSelection:NO];
  NSString *response = self.responseView.string;
  NSString *body = [[NSString alloc] initWithData:entry.responseData ?: [NSData data] encoding:NSUTF8StringEncoding];
  WBCheck(entry && self.exchangeWindow.isVisible && [self.requestView.string hasPrefix:@"GET "] &&
          [self.requestView.string rangeOfString:@"OData-MaxVersion: 4.01"].location != NSNotFound &&
          [response hasPrefix:@"HTTP/1.1 200"] && body.length > 1000 && [response hasSuffix:body] &&
          [response rangeOfString:@"</edmx:Edmx>"].location != NSNotFound,
          @"the wire log: an exchange, whole", [NSString stringWithFormat:@"%lu exchanges; $metadata answered with %lu bytes, shown %lu characters",
                                                 (unsigned long)self.log.count, (unsigned long)entry.responseData.length, (unsigned long)response.length]);
  if ([entry.URL hasPrefix:@"https://services.odata.org/V4/Northwind"]) [self shoot:@"Exchange" window:self.exchangeWindow];
  [self.exchangeWindow orderOut:nil];
  // Closed, it stays closed: the next exchanges do not open it again.
  [self runFetch:nil];
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  WBCheck(!self.exchangeWindow.isVisible, @"the exchange window stays closed as the log grows", nil);
  [self.logTable deselectAll:nil];
}

// The text views grow with their text, so there is something to scroll.
- (void)checkScrolling
{
  NSMutableString *long_ = [NSMutableString string];
  for (int i = 0; i < 200; i++) [long_ appendFormat:@"line %d\n", i];
  for (NSTextView *view in @[ self.inspectorView ]) {
    NSString *before = view.string;
    [self show:long_ in:view];
    NSScrollView *scrollView = view.enclosingScrollView;
    BOOL grew = view.frame.size.height > scrollView.contentSize.height;
    NSScroller *scroller = scrollView.verticalScroller;
    WBCheck(grew && scrollView.hasVerticalScroller && !scroller.isHidden && scroller.superview == scrollView,
            @"the inspector scrolls",
            [NSString stringWithFormat:@"text %.0f high in a view %.0f high", view.frame.size.height, scrollView.contentSize.height]);
    [self show:before in:view];
  }
}

- (NSUInteger)presetLabelled:(NSString *)prefix
{
  for (NSUInteger i = 0; i < self.presets.count; i++) {
    if ([self.presets[i][@"label"] hasPrefix:prefix]) return i;
  }
  return NSNotFound;
}

- (void)runPreset:(NSUInteger)index
{
  if (index == NSNotFound) return;
  [self.presetsPopup selectItemAtIndex:(NSInteger)index];
  [self applyPreset:self.presetsPopup];
  [self runFetch:nil];
}

// The window's contents follow its size, as the xib's springs and struts
// say: the results and the log shrink, the URL field narrows, the buttons
// on the right keep to the right. Smaller, not larger: a small screen (a
// CI runner's) does not let the window grow.
- (void)checkResizing
{
  NSRect before = self.window.frame;
  NSRect results = self.tableView.enclosingScrollView.frame, log = self.logTable.enclosingScrollView.frame;
  NSRect wire = self.wireURLField.frame, explain = self.explainButton.frame;
  CGFloat dw = 160, dh = MIN(60.0, results.size.height / 2);
  [self.window setFrame:NSMakeRect(before.origin.x, before.origin.y + dh, before.size.width - dw, before.size.height - dh) display:YES];
  NSRect r = self.tableView.enclosingScrollView.frame, l = self.logTable.enclosingScrollView.frame;
  NSRect w = self.wireURLField.frame, e = self.explainButton.frame;
  BOOL ok = r.size.width < results.size.width - dw + 2 && r.size.height < results.size.height - dh + 2 &&
            l.size.height < log.size.height - dh + 2 && w.size.width < wire.size.width - dw + 2 && NSMaxX(e) < NSMaxX(explain) - dw + 2;
  WBCheck(ok, @"the window's contents follow its size",
          [NSString stringWithFormat:@"results %@ -> %@, log %@ -> %@, URL %@ -> %@, Explain %@ -> %@",
                                     NSStringFromRect(results), NSStringFromRect(r), NSStringFromRect(log), NSStringFromRect(l),
                                     NSStringFromRect(wire), NSStringFromRect(w), NSStringFromRect(explain), NSStringFromRect(e)]);
  [self.window setFrame:before display:YES];
}

// The switches are checkboxes: a cell that shows its state by its image
// (Xcode turns one with no <behavior> into a bevel button, which does not).
- (void)checkSwitches
{
  NSDictionary *cells = @{ @"sub-entities": self.subentitiesButton.cell, @"return as faults": self.faultsButton.cell,
                           @"sort: desc": [[self.sortTable tableColumnWithIdentifier:@"descending"] dataCell],
                           @"prefetch: include": [[self.expandOutline tableColumnWithIdentifier:@"include"] dataCell],
                           @"properties: include": [[self.selectTable tableColumnWithIdentifier:@"include"] dataCell] };
  NSMutableArray *not = [NSMutableArray array];
  for (NSString *name in [cells.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSButtonCell *cell = cells[name];
    if (![cell isKindOfClass:[NSButtonCell class]] || !(cell.showsStateBy & NSContentsCellMask)) [not addObject:name];
  }
  WBCheck(!not.count, @"the switches are checkboxes", [not componentsJoinedByString:@", "]);
}

// Choosing a preset, as a person does (the popup's own action), shows
// every part of it in the panel.
- (void)checkPresetsFillThePanel
{
  NSMutableArray *wrong = [NSMutableArray array];
  for (NSUInteger i = 0; i < self.presets.count; i++) {
    NSDictionary *p = self.presets[i];
    [self.presetsPopup selectItemAtIndex:(NSInteger)i];
    [self.presetsPopup sendAction:self.presetsPopup.action to:self.presetsPopup.target];
    NSString *type = p[@"type"] ?: @"objects";
    NSDictionary *shown = @{
      @"entity": @[ self.entityPopup.titleOfSelectedItem ?: @"", p[@"entity"] ?: @"" ],
      @"type": @[ self.resultTypePopup.titleOfSelectedItem ?: @"", [type isEqualToString:@"objects"] ? @"objects" : type ],
      @"predicate": @[ self.predicateView.string ?: @"", p[@"predicate"] ?: @"" ],
      @"limit": @[ self.limitField.stringValue ?: @"", p[@"limit"] ?: @"" ],
      @"search": @[ self.searchField.stringValue ?: @"", p[@"search"] ?: @"" ],
      @"compute": @[ self.computeField.stringValue ?: @"", p[@"compute"] ?: @"" ],
      @"group": @[ self.groupField.stringValue ?: @"", p[@"group"] ?: @"" ],
      @"aggregate": @[ self.aggregateField.stringValue ?: @"", p[@"aggregate"] ?: @"" ],
      @"time": @[ self.timeField.stringValue ?: @"", p[@"time"] ?: @"" ],
    };
    for (NSString *part in [shown.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if (![shown[part][0] isEqual:shown[part][1]]) {
        [wrong addObject:[NSString stringWithFormat:@"%@: %@ shows \"%@\", not \"%@\"", p[@"label"], part, shown[part][0], shown[part][1]]];
      }
    }
    NSUInteger sorts = 0;
    for (NSString *item in [p[@"sort"] ?: @"" componentsSeparatedByString:@","]) {
      if ([item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length) sorts++;
    }
    if ((NSUInteger)self.sortTable.numberOfRows != sorts) {
      [wrong addObject:[NSString stringWithFormat:@"%@: %ld sort keys shown, not %lu", p[@"label"], (long)self.sortTable.numberOfRows, (unsigned long)sorts]];
    }
  }
  WBCheck(!wrong.count, @"a preset chosen fills the panel", [wrong componentsJoinedByString:@"; "]);
  // A field being typed in when a preset is chosen shows the preset, and
  // keeps it once the editing ends.
  [self runPreset:[self presetLabelled:@"All products"]];
  [self.window makeFirstResponder:self.limitField];
  NSText *editor = [self.window fieldEditor:YES forObject:self.limitField];
  editor.string = @"7";
  NSUInteger top5 = [self presetLabelled:@"Top 5"];
  [self.presetsPopup selectItemAtIndex:(NSInteger)top5];
  [self.presetsPopup sendAction:self.presetsPopup.action to:self.presetsPopup.target];
  [self.window makeFirstResponder:nil];
  WBCheck([self.limitField.stringValue isEqualToString:@"5"] && [self.query.limitText isEqualToString:@"5"],
          @"a preset chosen while a field is being edited replaces what was typed",
          [NSString stringWithFormat:@"$top shows \"%@\", the query has \"%@\"", self.limitField.stringValue, self.query.limitText]);
  // Another entity after a grouped preset: nothing of the grouping stays,
  // not even a sort by one of its keys.
  [self runPreset:[self presetLabelled:@"Sales by organization"]];
  [self.entityPopup selectItemWithTitle:@"Product"];
  [self entityChanged:self.entityPopup];
  NSArray *keys = [self.query.sorts valueForKey:@"key"];
  WBCheck([keys isEqual:@[ @"id" ]] && !self.groupField.stringValue.length, @"another entity after a grouped preset starts afresh",
          [NSString stringWithFormat:@"sort keys %@, group by \"%@\"", keys, self.groupField.stringValue]);
  // Back to the first, which the checks after this start from.
  [self runPreset:0];
}

// $search beside the predicate, and a grouping with its aggregates, as
// the built-in service answers them: $search, and $apply.
- (void)checkSearchAndGrouping
{
  [self runPreset:[self presetLabelled:@"Search:"]];
  NSString *wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  NSArray *names = [self.results.rows valueForKey:@"name"];
  WBCheck(!self.results.lastError && [wire rangeOfString:@"$search=(jars OR cote)"].location != NSNotFound && [names containsObject:@"Côte de Blaye"] &&
          [names containsObject:@"Ikura"] && ![names containsObject:@"Chai"],
          @"$search beside a $filter (Côte found by cote)", self.results.lastError ?: [NSString stringWithFormat:@"%@ %@", wire, names]);

  [self runPreset:[self presetLabelled:@"Grouped by category"]];
  wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  NSDictionary *beverages = nil;
  for (NSDictionary *row in self.results.rows) {
    if ([row[@"category.name"] isEqual:@"Beverages"]) beverages = row;
  }
  WBCheck(!self.results.lastError && [wire rangeOfString:@"$apply=groupby((Category/CategoryName)"].location != NSNotFound &&
          [beverages[@"products"] integerValue] == 4 && [beverages[@"dearest"] doubleValue] == 263.5 &&
          [[self.tableView.tableColumns valueForKey:@"identifier"] isEqual:(@[ @"category.name", @"products", @"total", @"dearest" ])],
          @"grouped by a to-one path, with count, sum and max ($apply)", self.results.lastError ?: [NSString stringWithFormat:@"%@ %@", wire, beverages]);
}

// A media entity's stream: downloaded; uploaded again; and a new media
// entity made from a file.
- (void)checkStreams
{
  [self runPreset:[self presetLabelled:@"Photos"]];
  if (self.results.rows.count) [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [self rebuildStreams];
  BOOL media = [self.streamPopup.selectedItem.representedObject isEqual:@""] && self.downloadButton.isEnabled;
  [self downloadStream:nil];
  WBCheck(media && [self.inspectorView.string rangeOfString:@"image/jpeg"].location != NSNotFound &&
          [self.statusField.stringValue hasPrefix:@"Downloaded"],
          @"Download a photo's media resource ($value)", media ? self.statusField.stringValue : @"no media stream in the menu");
  NSManagedObject *photo = [self selectedObject];
  NSURL *file = photo ? [[[ODataStreamTransfer alloc] initWithObject:photo stream:nil] download:NULL] : nil;
  NSURL *copy = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"workbench-photo.jpg"]];
  [[NSFileManager defaultManager] removeItemAtURL:copy error:NULL];
  BOOL copied = file && [[NSFileManager defaultManager] copyItemAtURL:file toURL:copy error:NULL];
  WBCheck(copied && [self uploadStreamFromFile:copy] && [self.statusField.stringValue hasPrefix:@"Uploaded"],
          @"Upload it again (PUT $value, If-Match)", self.statusField.stringValue);
  [self.tableView deselectAll:nil];
  [self rebuildStreams];
  WBCheck(copied && [self uploadStreamFromFile:copy] && [self.statusField.stringValue hasPrefix:@"Created Photo"],
          @"a new media entity from a file (POST Photos)", self.statusField.stringValue);
  [self revertChanges:nil];
  [[NSFileManager defaultManager] removeItemAtURL:copy error:NULL];
}

// The query above, its results below: a change to the query empties them;
// Execute fetches a screenful, scrolling to the end the next; the buttons
// that act on a row wait for one; sort keys are reordered.
- (void)checkMasterDetail
{
  // The query's switches, as the xib wires them: a change to one is a change to the query.
  BOOL wired = YES;
  for (NSControl *control in @[ self.resultTypePopup, self.subentitiesButton, self.faultsButton ]) {
    wired = wired && control.target == self && sel_isEqual(control.action, @selector(queryChanged:));
  }
  WBCheck(wired, @"the xib wires the result type and the switches to queryChanged:", nil);

  [self runPreset:[self presetLabelled:@"All products"]];
  BOOL fetched = self.results.rows.count > 0;
  BOOL waiting = !self.faultButton.isEnabled && !self.deleteButton.isEnabled;
  [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  BOOL ready = self.faultButton.isEnabled && self.fireButton.isEnabled && self.deleteButton.isEnabled;
  self.predicateView.string = @"unitPrice > 1";
  [self predicateChanged:nil];
  WBCheck(fetched && waiting && ready && !self.results.rows.count && !self.faultButton.isEnabled &&
          [self.statusField.stringValue hasPrefix:@"The query changed"],
          @"master and detail: a change to the query empties its results; a row's buttons wait for a row", self.statusField.stringValue);

  self.screenfulForTests = 3;
  self.predicateView.string = @"";
  [self runFetch:nil];
  BOOL first = self.results.rows.count == 3 && [self.statusField.stringValue rangeOfString:@"scroll for more"].location != NSNotFound;
  NSString *said = self.statusField.stringValue;
  [self loadNextPage];
  WBCheck(first && self.results.rows.count == 6 && [self logHasURLContaining:@"$top=3"] && [self logHasURLContaining:@"$skip=3"],
          @"a screenful at a time: the next as the table reaches its end", [NSString stringWithFormat:@"%@ | %lu rows", said, (unsigned long)self.results.rows.count]);
  self.screenfulForTests = 0;

  [self.query.sorts removeAllObjects];
  [self.query.sorts addObject:[@{ @"key": @"name", @"descending": @NO } mutableCopy]];
  [self.query.sorts addObject:[@{ @"key": @"unitPrice", @"descending": @YES } mutableCopy]];
  [self.sortTable reloadData];
  [self.sortTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
  [self moveSortUp:nil];
  WBCheck([[self.wireURLField.stringValue stringByRemovingPercentEncoding] rangeOfString:@"$orderby=UnitPrice desc,ProductName"].location != NSNotFound,
          @"sort keys reordered: the selected one moved up", self.wireURLField.stringValue);
}

- (NSMenuItem *)storeItemTagged:(NSInteger)tag
{
  for (NSMenuItem *item in self.storeMenu.itemArray) {
    if (item.tag == tag && item.action) return item;
  }
  return nil;
}

- (BOOL)logHasURLContaining:(NSString *)text
{
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
  for (WorkbenchLogEntry *entry in self.log) {
    if ([[entry.URL stringByRemovingPercentEncoding] rangeOfString:text].location != NSNotFound) return YES;
  }
  return NO;
}

// What the built-in service shows beyond the Catalog: $compute,
// application time and its actions, a media entity, delta links, a
// conflict and the merge policies, and asynchronous requests.
- (void)checkBuiltInFeatures
{
  [self runPreset:[self presetLabelled:@"Computed:"]];
  NSString *wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  WBCheck(!self.results.lastError && [wire rangeOfString:@"$compute=UnitPrice mul 1.2 as withTax"].location != NSNotFound &&
          [[self.results.rows.firstObject objectForKey:@"withTax"] doubleValue] > 0,
          @"compute: a value from each row ($compute)", self.results.lastError ?: [NSString stringWithFormat:@"%@ %@", wire, self.results.rows.firstObject]);

  // Data Aggregation: a relationship's aggregate, and the hierarchy tests.
  [self runPreset:[self presetLabelled:@"Categories over 90"]];
  wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  NSArray *names = [self.results.rows valueForKey:@"name"];
  WBCheck(!self.results.lastError && [wire rangeOfString:@"$filter=Products/aggregate(UnitPrice with sum) gt 90"].location != NSNotFound &&
          [names isEqual:(@[ @"Beverages", @"Confections" ])],
          @"aggregate(): products.@sum.unitPrice", self.results.lastError ?: [NSString stringWithFormat:@"%@ %@", wire, names]);
  // Explain: the service's plan for that GET, the filter in the store.
  [self explainQuery:nil];
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
  NSString *physical = self.physicalPlanView.string;
  WorkbenchLogEntry *explained = self.log.firstObject;
  WBCheck([self.explainButton isEnabled] && self.planWindow.isVisible &&
          [physical rangeOfString:@"Store scan Category where Products/aggregate(UnitPrice with sum) gt 90"].location != NSNotFound &&
          [self.logicalPlanView.string rangeOfString:@"Select Products/aggregate(UnitPrice with sum) gt 90"].location != NSNotFound &&
          [explained.URL rangeOfString:@"$explain/Categories"].location != NSNotFound &&
          [self.explainedView.string hasPrefix:@"GET http://workbench.local/odata/Categories?$filter=Products/aggregate(UnitPrice with sum) gt 90&"],
          @"explain: the built-in service's plan for the query", [NSString stringWithFormat:@"%@ | %@", physical, explained.URL]);
  [self shoot:@"Plan" window:self.planWindow];
  [self.planWindow orderOut:nil];
  NSDictionary *hierarchies = @{ @"Hierarchy: below EMEA": @[ @"EMEA Central" ], @"Hierarchy: US East and above": @[ @"Sales", @"US", @"US East" ],
                                 @"Hierarchy: the leaves in the US": @[ @"US East", @"US West" ],
                                 @"Hierarchy: sales anywhere below US": @[ @1, @2, @3, @4, @5 ] };
  for (NSString *label in [hierarchies.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [self runPreset:[self presetLabelled:label]];
    wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
    NSArray *ids = [self.results.rows valueForKey:@"id"];
    WBCheck(!self.results.lastError && [wire rangeOfString:@"Org.OData.Aggregation.V1.is"].location != NSNotFound && [ids isEqual:hierarchies[label]],
            [NSString stringWithFormat:@"hierarchy: %@", [label substringFromIndex:11]],
            self.results.lastError ?: [NSString stringWithFormat:@"%@ %@", wire, ids]);
  }

  // A query as written: objects in the service's order, or dictionaries.
  [self runPreset:[self presetLabelled:@"As written: the tree"]];
  NSArray *tree = [self.results.rows valueForKey:@"id"];
  WBCheck(!self.results.lastError && [tree isEqual:(@[ @"Sales", @"EMEA", @"EMEA Central", @"US", @"US East", @"US West" ])],
          @"a query as written: $apply=traverse, objects", self.results.lastError ?: tree.description);
  [self runPreset:[self presetLabelled:@"As written: totals"]];
  NSArray *totals = [self.results.rows valueForKey:@"Total"];
  WBCheck(!self.results.lastError && [totals isEqual:(@[ @5, @12, @7 ])] && [self.tableView columnWithIdentifier:@"SalesOrganization/ID"] >= 0,
          @"a query as written: grouped rows, dictionaries", self.results.lastError ?: totals.description);

  [self runPreset:[self presetLabelled:@"Budgets on 2024-10-01"]];
  wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  NSArray *amounts = [[self.results.rows valueForKey:@"amount"] valueForKey:@"stringValue"];
  WBCheck(!self.results.lastError && [wire rangeOfString:@"$at=2024-10-01"].location != NSNotFound && [amounts isEqual:(@[ @"1000", @"950" ])],
          @"application time: a day ($at)", self.results.lastError ?: [NSString stringWithFormat:@"%@ %@", wire, amounts]);
  [self runPreset:[self presetLabelled:@"Budgets during 2024"]];
  wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  WBCheck(!self.results.lastError && [wire rangeOfString:@"$from=2024-01-01&$to=2025-01-01"].location != NSNotFound && self.results.rows.count == 3,
          @"application time: a period ($from, $to)", self.results.lastError ?: [NSString stringWithFormat:@"%@ %lu rows", wire, (unsigned long)self.results.rows.count]);

  [self runPreset:[self presetLabelled:@"Budgets over time"]];
  NSUInteger before = self.results.rows.count;
  BOOL found = [self selectOperationContaining:@"Temporal.Update"];
  self.operationParametersField.stringValue = @"category='Beverages', from=2025-03-01, to=2025-06-01, amount=1500";
  if (found) [self invokeOperation:nil];
  WBCheck(found && [self.statusField.stringValue rangeOfString:@"3 slices"].location != NSNotFound && self.results.rows.count == before + 2 &&
          [self.inspectorView.string rangeOfString:@"1500"].location != NSNotFound,
          @"Temporal.Update: a period's budget, the slice split around it", found ? self.statusField.stringValue : @"not in the operations menu");
  self.operationParametersField.stringValue = @"";

  [self runPreset:[self presetLabelled:@"Pictures"]];
  if (self.results.rows.count) [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  // As selecting it by hand does: the selection, not a call, enables them.
  BOOL enabled = self.downloadButton.isEnabled && [self.streamPopup.selectedItem.representedObject isEqual:@""];
  WBCheck(enabled, @"a built-in media entity: selecting a picture enables Download",
          [NSString stringWithFormat:@"%lu rows; stream menu: %@", (unsigned long)self.results.rows.count, self.streamPopup.selectedItem.title]);
  [self downloadStream:nil];
  WBCheck([self.inspectorView.string rangeOfString:@"image/png"].location != NSNotFound, @"a built-in media entity: Download",
          self.statusField.stringValue);
  unichar attachment = NSAttachmentCharacter;
  WBCheck([self.inspectorView.string rangeOfString:[NSString stringWithCharacters:&attachment length:1]].location != NSNotFound,
          @"a downloaded image is shown in the inspector", self.statusField.stringValue);
  [self checkMasterDetail];

  // Another client's change: read by delta link; a stale save of it, a
  // conflict, settled as the Store menu says.
  [self runPreset:0];
  [self fetchRemoteChanges:nil];
  NSString *said = [self.connection.engine changeAtTheService];
  [self fetchRemoteChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Changes at the service: 0 inserted, 1 updated"] && [self logHasURLContaining:@"$deltatoken="],
          @"Changes: another client's change, by the service's delta link", [NSString stringWithFormat:@"%@ | %@", said, self.statusField.stringValue]);
  NSUInteger chai = [[self.results.rows valueForKey:@"name"] indexOfObject:@"Chai"];
  if (chai != NSNotFound) [self editColumn:@"unitPrice" row:chai value:@"30"];
  [self.connection.engine changeAtTheService];
  [self saveChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Save refused: 1 conflict"] &&
          [self.inspectorView.string rangeOfString:@"unitPrice: yours 30"].location != NSNotFound,
          @"a stale save is a conflict, shown", self.statusField.stringValue);
  [self setMergePolicy:[self storeItemTagged:1]];
  [self saveChanges:nil];
  chai = [[self.results.rows valueForKey:@"name"] indexOfObject:@"Chai"];
  WBCheck([self.statusField.stringValue hasPrefix:@"Saved"] && chai != NSNotFound && [[self.results.rows[chai] valueForKey:@"unitPrice"] integerValue] == 30,
          @"Store: my changes win, and the save goes through", self.statusField.stringValue);
  [self setMergePolicy:[self storeItemTagged:0]];

  // A request that takes its time, answered 202 and read from its monitor.
  [self toggleRespondAsync:nil];
  [self waitWhileConnecting];
  found = [self selectOperationContaining:@"CountProductsSlowly"];
  self.operationParametersField.stringValue = @"Seconds=1";
  if (found) [self invokeOperation:nil];
  WBCheck(found && [self.inspectorView.string rangeOfString:@"14"].location != NSNotFound && [self logHasURLContaining:@"$async/"],
          @"Store: prefer respond-async (202, then the status monitor)", found ? self.statusField.stringValue : @"not in the operations menu");
  self.operationParametersField.stringValue = @"";
  [self toggleRespondAsync:nil];
  [self waitWhileConnecting];
}

- (BOOL)selectOperationContaining:(NSString *)text
{
  for (NSMenuItem *item in self.operationPopup.itemArray) {
    if ([item.title rangeOfString:text].location == NSNotFound) continue;
    [self.operationPopup selectItem:item];
    return YES;
  }
  return NO;
}

// The built-in service's own operations, declared in protocols and served
// by ODataService: one of each kind the operations menu offers.
- (void)checkBuiltInOperations
{
  [self.presetsPopup selectItemAtIndex:0];
  [self applyPreset:self.presetsPopup];
  [self runFetch:nil];
  NSUInteger chai = [[self.results.rows valueForKey:@"name"] indexOfObject:@"Chai"];
  if (chai != NSNotFound) {
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:chai] byExtendingSelection:NO];
    [self rebuildOperations];
  }
  NSArray *cases = @[
    @[ @"DiscountedPriceByPercent", @"Percent=10", @"16.2", @"an instance function: Chai.DiscountedPriceByPercent(Percent)" ],
    @[ @"CheaperThanPrice", @"Price=10", @"Konbu", @"a function of the collection: Product (all).CheaperThanPrice(Price)" ],
    @[ @"CountProductsInCategoryNamed", @"Name='Seafood'", @"2", @"a service function: CountProductsInCategoryNamed(Name)" ],
    @[ @"RaisePriceByPercent", @"Percent=50", @"27", @"an action: Chai.RaisePriceByPercent(Percent)" ],
  ];
  for (NSArray *c in cases) {
    BOOL found = chai != NSNotFound && [self selectOperationContaining:c[0]];
    self.operationParametersField.stringValue = c[1];
    if (found) [self invokeOperation:nil];
    WBCheck(found && [self.inspectorView.string rangeOfString:c[2]].location != NSNotFound, c[3],
            found ? [NSString stringWithFormat:@"%@ | %@", self.statusField.stringValue, self.inspectorView.string] : @"not in the operations menu");
  }
  self.operationParametersField.stringValue = @"";

  // The action kept a record of itself, in the model's other
  // configuration: the service serves none of it, and the client's store,
  // holding the served one, has none of it either.
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = self.connection.engine.service.coordinator;
  __block NSUInteger entries = 0;
  [context performBlockAndWait:^{
    entries = [context countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"AuditEntry"] error:NULL];
  }];
  ODataSchema *schema = self.connection.store.schema;
  WBCheck(entries == 1 && !schema.entitySets[@"AuditEntries"] && ![self.entityPopup itemWithTitle:@"AuditEntry"] &&
          !self.connection.store.metadataProblems.count,
          @"a configuration: the action's audit entry is kept, not served",
          [NSString stringWithFormat:@"%lu entries; sets %@; %@", (unsigned long)entries,
                                     [schema.entitySets.allKeys componentsJoinedByString:@","], self.connection.store.metadataProblems]);
}

// Traces: the newest exchange's, with the span that sent it chosen; at the
// built-in service, its planning and execution under the request.
- (void)checkTracesBuiltIn:(BOOL)builtIn
{
  [self.presetsPopup selectItemAtIndex:0];
  [self applyPreset:self.presetsPopup];
  [self runFetch:nil];
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
  WorkbenchLogEntry *entry = self.log.firstObject;
  [self.logTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [self showTraceOfExchange:self];
  WBTrace *trace = [self.traceRecorder traceWithID:WBTraceIDOfHeaders(entry.requestHeaders) ?: @""];
  NSArray *names = [trace.spans valueForKey:@"name"];
  OTSpan *chosen = [[self.traceWindow.spanOutline itemAtRow:self.traceWindow.spanOutline.selectedRow] valueForKey:@"span"];
  BOOL served = !builtIn || ([names containsObject:@"plan"] && [names containsObject:@"execute"] &&
                             [[names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'ODataService GET'"]] count]);
  BOOL shown = self.traceWindow.window.isVisible;
  BOOL sender = chosen.kind == OTSpanKindClient && [chosen.context.spanID isEqualToString:WBSpanIDOfHeaders(entry.requestHeaders) ?: @""];
  BOOL detailed = [self.traceWindow.detailView.string rangeOfString:@"http.response.status_code"].location != NSNotFound;
  WBCheck(trace && shown && sender && detailed && served, @"traces: the exchange's trace, the span that sent it chosen",
          [NSString stringWithFormat:@"%@%@%@%@%@ (%ld rows, row %ld chosen)", trace ? @"" : @"no trace; ", shown ? @"" : @"not shown; ",
                                     sender ? @"" : @"not the sender chosen; ", detailed ? @"" : @"no detail; ",
                                     [names componentsJoinedByString:@", "], (long)self.traceWindow.spanOutline.numberOfRows,
                                     (long)self.traceWindow.spanOutline.selectedRow]);
  [self shoot:[NSString stringWithFormat:@"Traces %@", builtIn ? @"built-in" : entry.method] window:self.traceWindow.window];
  // As it found them: selecting the exchange opened its window too.
  [self.traceWindow.window orderOut:nil];
  [self.exchangeWindow orderOut:nil];
  [self.logTable deselectAll:nil];
}

// The built-in service's product, as the service has it.
- (id)serviceValue:(NSString *)attribute ofProduct:(NSNumber *)productID
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = self.connection.engine.service.coordinator;
  __block id value = nil;
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", productID];
    value = [[[context executeFetchRequest:fetch error:NULL] firstObject] valueForKey:attribute];
  }];
  return value;
}

// Sync > Show Device: an offline device beside the built-in service, driven
// as a person would: read, edited, in conflict, offline.
- (void)checkSync
{
  [self showSync:nil];
  WBSyncWindow *device = self.syncWindow;
  NSError *error = nil;
  BOOL synced = [device syncAndWait:&error];
  NSUInteger products = device.objects.count;
  WBCheck(device.window.isVisible && synced && products > 0 && device.changes.count == 0, @"sync: the device reads the service's data",
          [NSString stringWithFormat:@"%lu products; %@", (unsigned long)products, error.localizedDescription ?: device.statusField.stringValue]);
  [self shoot:@"Sync" window:device.window];

  // An edit on the device waits, then goes.
  NSNumber *first = [device.objects.firstObject valueForKey:@"id"];
  NSUInteger nameColumn = [[device.dataTable.tableColumns valueForKey:@"identifier"] indexOfObject:@"name"];
  [device tableView:device.dataTable setObjectValue:@"Chai (device)" forTableColumn:device.dataTable.tableColumns[nameColumn] row:0];
  ODataSyncChange *waiting = device.changes.firstObject;
  BOOL queued = device.changes.count == 1 && waiting.operation == ODataSyncOperationUpdate && [waiting.properties containsObject:@"name"];
  synced = [device syncAndWait:&error];
  WBCheck(queued && synced && [[self serviceValue:@"name" ofProduct:first] isEqual:@"Chai (device)"] && device.changes.count == 0,
          @"sync: an edit on the device waits, then reaches the service", [NSString stringWithFormat:@"%@ %@", waiting, error ?: @""]);

  // Both change the product: merged, the device's name and the service's price.
  [device setRule:WBSyncRuleMergeFields];
  [device.dataTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [device changeAtTheService:nil];
  NSDecimalNumber *price = [self serviceValue:@"unitPrice" ofProduct:first];
  [device setValue:@"Chai (merged)" ofAttribute:@"name" row:0];
  synced = [device syncAndWait:&error];
  WBSyncConflict *met = device.conflicts.firstObject;
  BOOL merged = [[self serviceValue:@"name" ofProduct:first] isEqual:@"Chai (merged)"] &&
                [[device valueOfAttribute:@"unitPrice" entity:@"Product" key:first] isEqual:price] && met.outcome == ODataSyncMerge;
  WBCheck(synced && merged && device.changes.count == 0, @"sync: a conflict merged, each side's change kept",
          [NSString stringWithFormat:@"%@ (%@ at the service)", met.conflict, price]);
  [device.conflictTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [self shoot:@"Sync conflict" window:device.window];

  // Set aside to decide: an issue; discarded, the service's version is read.
  [device setRule:WBSyncRuleSetAside];
  [device changeAtTheService:nil];
  price = [self serviceValue:@"unitPrice" ofProduct:first];
  [device setValue:@"99" ofAttribute:@"unitPrice" row:0];
  synced = [device syncAndWait:&error];
  ODataSyncChange *aside = device.changes.firstObject;
  BOOL issue = [aside isKindOfClass:[ODataSyncIssue class]] && ((ODataSyncIssue *)aside).status == 409;
  [device.changesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [device discardIssue:nil];
  synced = synced && [device syncAndWait:&error];
  WBCheck(issue && synced && device.changes.count == 0 && [[device valueOfAttribute:@"unitPrice" entity:@"Product" key:first] isEqual:price],
          @"sync: a conflict set aside, discarded, the service's version read", [NSString stringWithFormat:@"%@", aside]);

  // Offline: edits wait; back online, they go.
  [device setRule:WBSyncRuleRemoteWins];
  device.offline = YES;
  [device setValue:@"Chai (offline)" ofAttribute:@"name" row:0];
  BOOL failed = ![device syncAndWait:&error];
  NSUInteger held = device.changes.count;
  device.offline = NO;
  synced = [device syncAndWait:&error];
  WBCheck(failed && held == 1 && synced && [[self serviceValue:@"name" ofProduct:first] isEqual:@"Chai (offline)"],
          @"sync: offline, an edit waits; online again, it goes", [NSString stringWithFormat:@"%lu held; %@", (unsigned long)held, error ?: @""]);

  // As a person would: the main window shows the products, the device
  // renames one and uploads, and Execute shows it renamed.
  [self runPreset:0];
  NSUInteger chai = [self rowWhere:@"id" is:first];
  NSString *before = chai != NSNotFound ? [self.results.rows[chai] valueForKey:@"name"] : nil;
  id versionBefore = [self serviceValue:@"version" ofProduct:first];
  [device setValue:@"Tchai" ofAttribute:@"name" row:0];
  [device upload:nil];
  NSDate *uploading = [NSDate dateWithTimeIntervalSinceNow:20];
  while (device.busy && [uploading timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  [self runFetch:nil];
  chai = [self rowWhere:@"id" is:first];
  NSString *after = chai != NSNotFound ? [self.results.rows[chai] valueForKey:@"name"] : nil;
  WBCheck([[self serviceValue:@"name" ofProduct:first] isEqual:@"Tchai"] && [after isEqual:@"Tchai"],
          @"sync: an upload from the device, seen in the main window", [NSString stringWithFormat:@"before %@, after %@, at the service %@, version %@ -> %@",
                                                                       before, after, [self serviceValue:@"name" ofProduct:first],
                                                                       versionBefore, [self serviceValue:@"version" ofProduct:first]]);

  // Which way each entity goes, said; a down one read only.
  BOOL bothSaid = [device.rulesField.stringValue rangeOfString:@"both ways"].location != NSNotFound && device.makeButton.isEnabled;
  [device.entityPopup selectItemAtIndex:2];
  [device entityChanged:device.entityPopup];
  BOOL downSaid = [device.rulesField.stringValue rangeOfString:@"down, the service's"].location != NSNotFound && !device.makeButton.isEnabled &&
                  [device.entityPopup.titleOfSelectedItem hasPrefix:@"Category (down"];
  [device.entityPopup selectItemAtIndex:0];
  [device entityChanged:device.entityPopup];
  WBCheck(bothSaid && downSaid, @"sync: which way each entity goes, said on the device", device.rulesField.stringValue);

  // Its own request log: what it sent, and what failed offline.
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  BOOL batched = NO, offlineLogged = NO;
  for (WorkbenchLogEntry *entry in device.requests) {
    batched = batched || [entry.URL hasSuffix:@"$batch"];
    offlineLogged = offlineLogged || (!entry.status && [entry.failure rangeOfString:@"offline"].location != NSNotFound);
  }
  [device.requestTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  BOOL detailed = [device.detailView.string rangeOfString:@"HTTP"].location != NSNotFound ||
                  [device.detailView.string rangeOfString:device.requests.firstObject.method ?: @"?"].location == 0;
  WBCheck(batched && offlineLogged && detailed, @"sync: the device's own request log",
          [NSString stringWithFormat:@"%lu requests, %ld rows%@%@", (unsigned long)device.requests.count, (long)device.requestTable.numberOfRows,
                                     batched ? @"" : @", no $batch",
                                     offlineLogged ? @"" : @", no offline failure"]);

  // Sync after each change: an edit goes at once.
  device.autoSyncButton.state = NSOnState;
  [device setValue:@"Chai (at once)" ofAttribute:@"name" row:0];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
  while (device.busy && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  device.autoSyncButton.state = NSOffState;
  WBCheck([[self serviceValue:@"name" ofProduct:first] isEqual:@"Chai (at once)"], @"sync: after each change, at once", device.statusField.stringValue);
  [self shoot:@"Sync requests" window:device.window];

  // Its exchanges in the wire log; its syncs in Traces.
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  BOOL logged = NO;
  for (WorkbenchLogEntry *entry in self.log) logged = logged || [entry.URL rangeOfString:@"deltatoken"].location != NSNotFound;
  BOOL traced = NO;
  for (WBTrace *trace in self.traceRecorder.traces) traced = traced || [trace.root.name isEqualToString:@"sync"];
  WBCheck(logged && traced, @"sync: its exchanges in the wire log, its syncs in Traces",
          [NSString stringWithFormat:@"%@%@", logged ? @"" : @"no delta link in the log; ", traced ? @"" : @"no sync trace"]);
  [device.window orderOut:nil];
}

// Sync > Serve on the Network: the built-in service over HTTP, and a device
// that reaches it as the Device app does on an iPhone (the network, a
// store of its own), its edit at the service.
- (void)checkServedOnTheNetwork
{
  self.connection.servePort = 18640 + arc4random_uniform(1000);
  [self toggleServeNetwork:nil];
  [self waitWhileConnecting];
  NSURL *root = self.connection.servedRoot;
  if (!root && [self.connection.serveFailure hasSuffix:@"no address on a network"]) {
    // A container with no network of its own: nothing to serve on.
    fprintf(stderr, "SKIP  sync: a device over the network (no address on a network)\n");
    [self toggleServeNetwork:nil];
    [self waitWhileConnecting];
    return;
  }
  WorkbenchDevice *device = root ? [[WorkbenchDevice alloc] initWithModelURL:self.connection.engine.modelURL serviceRoot:root
                                                                   transport:ODataDefaultTransport() storeURL:nil] : nil;
  NSError *error = nil;
  BOOL synced = [device syncAndWait:&error];
  NSArray *products = [device objectsOfEntity:@"Product"];
  NSNumber *first = [products.firstObject valueForKey:@"id"];
  if (products.count) [device setValue:@"Chai (from the network)" ofAttribute:@"name" object:products.firstObject];
  synced = synced && [device syncAndWait:&error];
  // Its log hears of each exchange on the main thread.
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  BOOL overHTTP = [device.requests.lastObject.URL hasPrefix:root.absoluteString ?: @"-"] && device.requests.lastObject.status == 200;
  WBCheck(synced && products.count > 0 && overHTTP && [[self serviceValue:@"name" ofProduct:first] isEqual:@"Chai (from the network)"],
          @"sync: a device over the network, the service served on it",
          [NSString stringWithFormat:@"%@; %lu products; first request %@ %ld; at the service %@; %@", root ?: self.connection.serveFailure,
                                     (unsigned long)products.count, device.requests.lastObject.URL, (long)device.requests.lastObject.status,
                                     [self serviceValue:@"name" ofProduct:first], error.localizedDescription ?: @"no error"]);
  [self toggleServeNetwork:nil];
  [self waitWhileConnecting];
}

- (void)runSelfTest
{
  // Check for Updates…: in the app menu where there is an updater
  // (Sparkle, on macOS), not where the image is updated from outside
  // (GNUstep's AppImage).
  BOOL hasUpdater = [[WBUpdater alloc] initStarting:NO].available;
  NSMenuItem *checkForUpdates = [[[NSApp mainMenu] itemAtIndex:0].submenu itemWithTag:7100];
  WBCheck((checkForUpdates != nil) == hasUpdater && (!checkForUpdates || sel_isEqual(checkForUpdates.action, @selector(checkForUpdates:))),
          hasUpdater ? @"Check for Updates… in the app menu" : @"Check for Updates… not offered", nil);
  NSArray *names = @[ @"Built-in", @"Northwind", @"TripPin" ];
  NSInteger last = self.selfTestOffline ? WBServiceBuiltIn : WBServiceTripPin;
  for (NSInteger service = WBServiceBuiltIn; service <= last; service++) {
    fprintf(stderr, "== %s\n", [names[(NSUInteger)service] UTF8String]);
    [self.servicePopup selectItemAtIndex:service];
    [self serviceChanged:self.servicePopup];
    [self waitWhileConnecting];
    WBCheck(self.connection.store != nil, @"connect", self.statusField.stringValue);
    if (!self.connection.store) continue;
    WBCheck(self.connection.store.schema != nil && !self.connection.store.metadataProblems.count, @"$metadata read, and the model agrees with it",
            [self.connection.store.metadataProblems componentsJoinedByString:@"; "]);
    [self checkExchangeLog];
    [self checkTracesBuiltIn:service == WBServiceBuiltIn];
    for (NSUInteger i = 0; i < self.presets.count; i++) {
      [self.presetsPopup selectItemAtIndex:(NSInteger)i];
      [self applyPreset:self.presetsPopup];
      [self runFetch:nil];
      NSString *label = self.presets[i][@"label"];
      BOOL counted = ![self.presets[i][@"type"] isEqual:@"count"] || [self.results.rows.firstObject integerValue] > 0;
      WBCheck(!self.results.lastError && self.results.rows.count > 0 && counted, [NSString stringWithFormat:@"preset \"%@\"", label],
              self.results.lastError ?: [NSString stringWithFormat:@"%@  %@", self.statusField.stringValue, self.wireURLField.stringValue]);
      if (i == 0) [self shoot:names[(NSUInteger)service]];
    }
    if (service == WBServiceBuiltIn) {
      [self.presetsPopup selectItemAtIndex:0];
      [self applyPreset:self.presetsPopup];
      [self runFetch:nil];
      [self checkInsertAndDeleteWithKey:@"name" value:@"Workbench Blend" fields:@{ @"quantityPerUnit": @"12 bags", @"unitPrice": @"9.5" }];
      NSString *first = [self.results.rows.firstObject valueForKey:@"name"];
      [self editColumn:@"name" row:0 value:@"Changed my mind"];
      [self revertChanges:nil];
      WBCheck([[self.results.rows.firstObject valueForKey:@"name"] isEqual:first] && ![self.results pendingCount], @"Revert drops an edit",
              self.statusField.stringValue);
      [self checkScrolling];
      [self checkPresetsFillThePanel];
      [self checkResizing];
      [self checkSwitches];
      [self checkQueryPanel];
      [self checkBuiltInOperations];
      [self checkSearchAndGrouping];
      [self checkBuiltInFeatures];
      [self checkBuiltInOpenType];
      [self checkSync];
      [self checkServedOnTheNetwork];
    }
    if (service != WBServiceBuiltIn) WBCheck(![self.explainButton isEnabled], @"explain: only at the built-in service", nil);
    if (service != WBServiceTripPin) continue;

    // TripPin: an instance function, a service function, an edit, the changes.
    [self.presetsPopup selectItemAtIndex:0];
    [self applyPreset:self.presetsPopup];
    [self runFetch:nil];
    // Paged to where he is: on a short screen he is pages away.
    NSUInteger russell = [self rowWhere:@"userName" is:@"russellwhyte"];
    if (russell != NSNotFound) {
      [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:russell] byExtendingSelection:NO];
      [self rebuildOperations];
    }
    BOOL found = [self selectOperationContaining:@"GetFavoriteAirline"];
    if (found) [self invokeOperation:nil];
    WBCheck(found && [self.inspectorView.string rangeOfString:@"American Airlines"].location != NSNotFound,
            @"an instance function: russellwhyte.GetFavoriteAirline()", found ? self.statusField.stringValue : @"not in the operations menu");
    found = [self selectOperationContaining:@"GetNearestAirport"];
    self.operationParametersField.stringValue = @"lat=33.94, lon=-118.4";
    if (found) [self invokeOperation:nil];
    WBCheck(found && [self.inspectorView.string rangeOfString:@"KLAX"].location != NSNotFound,
            @"a service function with parameters: GetNearestAirport(lat, lon)", found ? self.statusField.stringValue : @"not in the operations menu");
    [self shoot:@"TripPin-operation"];
    [self checkStreams];
    [self runPreset:0];
    russell = [self rowWhere:@"userName" is:@"russellwhyte"];

    [self editColumn:@"firstName" row:russell value:@"Rusty"];
    WBCheck([self.statusField.stringValue hasPrefix:@"Unsaved: 0 new, 1 changed"], @"an edit waits for Save", self.statusField.stringValue);
    [self saveChanges:nil];
    WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 0 inserted (POST), 1 updated"], @"Save sends it (PATCH)", self.statusField.stringValue);
    [self checkDynamicProperties];
    [self runPreset:0];
    [self checkInsertAndDeleteWithKey:@"userName" value:@"oiswbnew" fields:@{ @"firstName": @"New", @"lastName": @"Person" }];

    [self fetchRemoteChanges:nil];
    WBCheck([self.statusField.stringValue hasPrefix:@"No changes"], @"start tracking the service's changes", self.statusField.stringValue);
    [self fetchRemoteChanges:nil];
    WBCheck(![self.statusField.stringValue hasPrefix:@"Could"] && self.statusField.stringValue.length, @"look again for changes",
            self.statusField.stringValue);
  }
  fprintf(stderr, "%s: %d checks, %d failed\n", WBFailures ? "Workbench self-test: FAILED" : "Workbench self-test: passed", WBChecks, WBFailures);
  exit(WBFailures ? 1 : 0);
}

@end
