// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The window: the connection above, the query panel under it, the
// results below, and the wire log beside them. What each of the three is
// lives in WBConnection, WBQuery and WBResults; this controller shows
// them, copies the panel's values into the query, and tells the results
// what the query asks.

#import "WorkbenchController+Private.h"
#import "WorkbenchSupport.h"
#import "WBUpdater.h"
#import <objc/runtime.h>

static BOOL WorkbenchLoadNib(NSString *name, id owner)
{
#if defined(__APPLE__)
  NSArray *top = nil;
  return [[NSBundle mainBundle] loadNibNamed:name owner:owner topLevelObjects:&top];
#else
  return [NSBundle loadNibNamed:name owner:owner];
#endif
}

@implementation WorkbenchController {
  NSMutableDictionary *_pathItems;  // key path -> the one string the outline knows it by
  BOOL _loadingPage;
  BOOL _keepingLogSelection;  // the log's row chosen again after a reload: not shown again
  BOOL _awake;  // the window's xib has loaded; the owner hears it again of each window of its own
  WBUpdater *_updater;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _connection = [[WBConnection alloc] init];
  _connection.target = self;
  _connection.connectedAction = @selector(connectionDidConnect:);
  _connection.logAction = @selector(appendLog:);
  // Every span kept, for the trace window: the store's, its requests', the
  // built-in service's.
  _traceRecorder = [[WBTraceRecorder alloc] init];
  OTTracerProvider.sharedProvider = WBTracerProvider(_traceRecorder);
  [ODataIncrementalStore registerStore];
  if (!WorkbenchLoadNib(@"WorkbenchWindow", self)) {
    NSLog(@"Workbench: failed to load WorkbenchWindow.xib");
  }
  return self;
}

- (void)awakeFromNib
{
  if (_awake) return;
  _awake = YES;
  if (self.mainMenu) [NSApp setMainMenu:self.mainMenu];
  [self updateStoreMenu];
  self.tableView.dataSource = self;
  self.tableView.delegate = self;
  self.limitField.delegate = (id)self;
  self.skipField.delegate = (id)self;
  self.batchSizeField.delegate = (id)self;
  _pathItems = [NSMutableDictionary dictionary];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(predicateChanged:)
                                               name:NSTextDidChangeNotification
                                             object:self.predicateView];
  // Scrolled to the end: the next screenful.
  NSClipView *clip = self.tableView.enclosingScrollView.contentView;
  clip.postsBoundsChangedNotifications = YES;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(resultsScrolled:)
                                               name:NSViewBoundsDidChangeNotification object:clip];
  _log = [NSMutableArray array];
  // A double click on an exchange shows it too.
  _logTable.target = self;
  _logTable.doubleAction = @selector(showExchange:);
  [self keepScroller:_logTable.enclosingScrollView];
  [self addTraceMenus];
  [self addSyncMenu];
  if (self.storeMenu) {
    [self.storeMenu addItem:[NSMenuItem separatorItem]];
    [self.storeMenu addItemWithTitle:@"Sign Out of the Service" action:@selector(signOut:) keyEquivalent:@""].target = self;
  }
  for (NSTextView *view in @[ self.predicateView, self.inspectorView ]) [self prepareTextView:view fixedPitch:NO];
  [self rebuildStreams];
  [self.servicePopup selectItemAtIndex:WBServiceBuiltIn];
  [self serviceChanged:nil];
}

// The xibs leave the text views' colours to the platform, and GNUstep
// draws them black on black; and they are the size of their scroll views
// (below). An exchange and a plan are read in a fixed-pitch font.
- (void)prepareTextView:(NSTextView *)view fixedPitch:(BOOL)fixedPitch
{
  view.drawsBackground = YES;
  view.backgroundColor = [NSColor textBackgroundColor];
  view.textColor = [NSColor textColor];
  view.insertionPointColor = [NSColor textColor];
  if (fixedPitch) view.font = [NSFont userFixedPitchFontOfSize:11];
  [self makeScrollable:view];
}

// Off and on again: GNUstep leaves a scroller it hid, while what it holds
// fitted, out of the view, and setting YES again does not bring it back.
- (void)keepScroller:(NSScrollView *)scrollView
{
  scrollView.autohidesScrollers = NO;
  scrollView.hasVerticalScroller = NO;
  scrollView.hasVerticalScroller = YES;
  [scrollView tile];
}

// The xib's text views are the size of their scroll views and stay so:
// with nothing beyond the visible part there is nothing to scroll. They
// grow with their text instead, as wide as the scroll view.
- (void)makeScrollable:(NSTextView *)view
{
  NSScrollView *scrollView = view.enclosingScrollView;
  NSSize size = scrollView.contentSize;
  view.minSize = NSMakeSize(0, size.height);
  view.maxSize = NSMakeSize(1e7, 1e7);
  view.verticallyResizable = YES;
  view.horizontallyResizable = NO;
  view.autoresizingMask = NSViewWidthSizable;
  view.frame = NSMakeRect(0, 0, size.width, size.height);
  view.textContainer.containerSize = NSMakeSize(size.width, 1e7);
  view.textContainer.widthTracksTextView = YES;
  [self keepScroller:scrollView];
}

// Text into a text view, which is resized to it (GNUstep does not do that
// on -setString:), and shown from the top.
- (void)show:(NSString *)text in:(NSTextView *)view
{
  view.string = text ?: @"";
  [view.layoutManager ensureLayoutForTextContainer:view.textContainer];  // Apple lays text out lazily
  [view sizeToFit];
  [view scrollRangeToVisible:NSMakeRange(0, 0)];
}

// Text, then an image, in the inspector: scaled to fit its height, and up
// to be seen when it is small.
- (void)showImage:(NSImage *)image below:(NSString *)text
{
  NSSize size = image.size;
  CGFloat room = MAX(self.inspectorView.enclosingScrollView.contentSize.height - 24, 48.0);
  CGFloat scale = MIN(room / size.height, 4.0);
  image.size = NSMakeSize(floor(size.width * scale), floor(size.height * scale));
  NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
  NSTextAttachmentCell *cell = [[NSTextAttachmentCell alloc] initImageCell:image];
  attachment.attachmentCell = cell;
  NSMutableAttributedString *shown = [[NSMutableAttributedString alloc] initWithString:[text stringByAppendingString:@"\n"]
                                                                           attributes:@{ NSForegroundColorAttributeName: [NSColor textColor] }];
  [shown appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
  [self.inspectorView.textStorage setAttributedString:shown];
  [self.inspectorView.layoutManager ensureLayoutForTextContainer:self.inspectorView.textContainer];
  [self.inspectorView sizeToFit];
  [self.inspectorView scrollRangeToVisible:NSMakeRange(shown.length, 0)];
}

- (void)showWindow
{
  [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  (void)sender;
  return YES;
}

// Updates, set up before the app finishes launching (as Sparkle asks);
// not started in a self-test. Where there is no updater, no menu item,
// nor the separator under it.
- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
  (void)notification;
  _updater = [[WBUpdater alloc] initStarting:!self.selfTesting];
  if (!_updater.available) {
    NSMenu *appMenu = [[NSApp mainMenu] itemAtIndex:0].submenu;
    NSInteger check = [appMenu indexOfItemWithTag:7100];
    if (check < 0) return;
    [appMenu removeItemAtIndex:check];
    if (check < appMenu.numberOfItems && [[appMenu itemAtIndex:check] isSeparatorItem]) [appMenu removeItemAtIndex:check];
  }
}

- (IBAction)checkForUpdates:(id)sender
{
  [_updater checkForUpdates:sender];
}

- (BOOL)builtIn
{
  return _connection.service == WBServiceBuiltIn;
}

#pragma mark - The connection

- (IBAction)serviceChanged:(id)sender
{
  (void)sender;
  WBService service = (WBService)MAX(0, self.servicePopup.indexOfSelectedItem);
  NSString *root = [WBConnection rootOfService:service];
  if (!root) {
    if ([WBConnection serviceOfRoot:self.serviceURLField.stringValue] != WBServiceOther) self.serviceURLField.stringValue = @"";
    [self.window makeFirstResponder:self.serviceURLField];
    self.statusField.stringValue = @"Type the service root URL of an OData v4 service, then Connect.";
    return;
  }
  self.serviceURLField.stringValue = root;
  [self connect:nil];
}

- (IBAction)connect:(id)sender
{
  if (_connection.connecting) return;
  WBService service = (WBService)MAX(0, self.servicePopup.indexOfSelectedItem);
  if (sender == self.serviceURLField || sender == self.connectButton) {
    // A URL typed in is another service, unless it is one of ours.
    NSString *typed = [self.serviceURLField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    service = [WBConnection serviceOfRoot:typed];
    [self.servicePopup selectItemAtIndex:service];
  }
  [_log removeAllObjects];
  [_logTable reloadData];
  [_results clear];
  [self.tableView reloadData];
  self.connectButton.enabled = NO;
  // Another service may ask for a sign-in: what for, first, from its
  // $metadata.
  ODataSignIn *signIn = service == WBServiceOther ? [self signInForRoot:self.serviceURLField.stringValue] : nil;
  if (signIn) {
    self.statusField.stringValue = [NSString stringWithFormat:@"Asking %@ how to sign in …", signIn.serviceRoot.host];
    signIn.delegate = self;
    [signIn learn];
    return;
  }
  [self startConnectionToService:service signIn:nil];
}

- (void)startConnectionToService:(WBService)service signIn:(ODataSignIn *)signIn
{
  _connection.credentialProvider = signIn.kind == ODataSignInNone ? nil : signIn;
  if (service != WBServiceBuiltIn) {
    self.statusField.stringValue = [NSString stringWithFormat:@"Connecting to %@ …", self.serviceURLField.stringValue];
  }
  NSString *why = [_connection connectToService:service root:self.serviceURLField.stringValue];
  if (why) {
    self.connectButton.enabled = YES;
    self.statusField.stringValue = why;
  }
}

#pragma mark - Signing in

// The sign-in for a typed service root (nil: no root).
- (ODataSignIn *)signInForRoot:(NSString *)typed
{
  NSString *text = [typed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (text.length && ![text hasSuffix:@"/"]) text = [text stringByAppendingString:@"/"];
  NSURL *root = [NSURL URLWithString:text];
  if (!root.scheme.length || !root.host.length) return nil;
  if (!self.signIns) self.signIns = [NSMutableDictionary dictionary];
  ODataSignIn *signIn = self.signIns[root.absoluteString];
  if (!signIn) {
    signIn = [[ODataSignIn alloc] initWithServiceRoot:root secrets:[[ODataSecretStore alloc] initWithServiceName:@"ODataKit Workbench"]];
    self.signIns[root.absoluteString] = signIn;
  }
  signIn.clientID = WBClientIDForRoot(root);
  return signIn;
}

// What the service asks for, learnt: nothing, or signed in already, and
// it is connected to; else the panel asks.
- (void)signInDidLearn:(ODataSignIn *)signIn
{
  signIn.delegate = nil;
  if (signIn.kind == ODataSignInNone || signIn.signedIn) {
    [self startConnectionToService:WBServiceOther signIn:signIn];
    return;
  }
  [self askToSignIn:signIn];
}

- (void)askToSignIn:(ODataSignIn *)signIn
{
  self.statusField.stringValue = [NSString stringWithFormat:@"%@ asks for a sign-in.", signIn.serviceRoot.host];
  self.signInPanel = [[WBSignInPanel alloc] initWithSignIn:signIn];
  __weak WorkbenchController *weak = self;
  [self.signInPanel showBesideWindow:self.window done:^(BOOL signedIn) {
    WorkbenchController *me = weak;
    me.signInPanel = nil;
    if (signedIn) {
      [me startConnectionToService:WBServiceOther signIn:signIn];
    } else {
      me.connectButton.enabled = YES;
      me.statusField.stringValue = @"Not signed in: connect again to sign in.";
    }
  }];
}

// $metadata not read (behind the sign-in too, or the service down): the
// connection tried all the same, with whatever this sign-in kept.
- (void)signIn:(ODataSignIn *)signIn didFail:(NSError *)error
{
  signIn.delegate = nil;
  [self startConnectionToService:WBServiceOther signIn:signIn];
}

- (IBAction)signOut:(id)sender
{
  (void)sender;
  ODataSignIn *signIn = [self signInForRoot:self.serviceURLField.stringValue];
  [signIn signOut];
  self.statusField.stringValue = [NSString stringWithFormat:@"Signed out of %@: connect again to sign in.", signIn.serviceRoot.host ?: @"the service"];
}

// Connected, or not: a new query and new results, over the new store.
- (void)connectionDidConnect:(WBConnection *)connection
{
  self.connectButton.enabled = YES;
  _explainButton.enabled = connection.engine != nil;
  if (connection.failure) {
    self.statusField.stringValue = [NSString stringWithFormat:@"Could not connect: %@", connection.failure];
    ODataSignIn *signIn = connection.service == WBServiceOther ? self.signIns[connection.serviceRoot.absoluteString] : nil;
    if (signIn && (signIn.kind == ODataSignInOpenID || signIn.kind == ODataSignInPassword) && [connection.failure containsString:@"401"]) {
      [signIn signOut];
      self.connectButton.enabled = NO;
      [self askToSignIn:signIn];
    }
    return;
  }
  _query = [[WBQuery alloc] initWithModel:connection.model builtIn:[self builtIn]];
  _query.configurationName = connection.store.configurationName;
  _results = [[WBResults alloc] initWithConnection:connection];
  [self updateStoreMenu];
  [self.entityPopup removeAllItems];
  [self.entityPopup addItemsWithTitles:[_query entityNames]];
  _presets = [WBQuery presetsForService:connection.service model:connection.model];
  [self.presetsPopup removeAllItems];
  for (NSDictionary *preset in _presets) [self.presetsPopup addItemWithTitle:preset[@"label"]];
  [self showPending];
  NSString *summary = [connection summary];
  ODataSignIn *signIn = connection.service == WBServiceOther ? self.signIns[connection.serviceRoot.absoluteString] : nil;
  if (signIn.signedIn && signIn.userName.length) summary = [summary stringByAppendingFormat:@"  Signed in as %@.", signIn.userName];
  self.statusField.stringValue = summary;
  if (_presets.count) {
    [self.presetsPopup selectItemAtIndex:0];
    [self applyPreset:nil];
    [self runFetch:nil];
    self.statusField.stringValue = [NSString stringWithFormat:@"%@  %@", summary, self.statusField.stringValue];
  } else {
    [self entityChanged:nil];
  }
}

- (IBAction)resetStore:(id)sender
{
  (void)sender;
  // The built-in service is seeded again; TripPin gets a new session.
  [self connect:nil];
}

#pragma mark - The query

// The panel's values, into the query: what it asks is what the panel says.
- (void)readQueryControls
{
  if (!_query) return;
  _query.entityName = self.entityPopup.titleOfSelectedItem.length ? self.entityPopup.titleOfSelectedItem : nil;
  NSString *type = self.resultTypePopup.titleOfSelectedItem;
  _query.resultType = [type isEqualToString:@"count"] ? NSCountResultType
                    : [type isEqualToString:@"dictionary"] ? NSDictionaryResultType
                    : [type isEqualToString:@"object IDs"] ? NSManagedObjectIDResultType : NSManagedObjectResultType;
  _query.predicateText = [self.predicateView.string copy] ?: @"";
  _query.limitText = self.limitField.stringValue ?: @"";
  _query.skipText = self.skipField.stringValue ?: @"";
  _query.pageSizeText = self.batchSizeField.stringValue ?: @"";
  _query.includesSubentities = self.subentitiesButton.state == NSOnState;
  _query.returnsObjectsAsFaults = self.faultsButton.state == NSOnState;
  _query.searchText = _searchField.stringValue ?: @"";
  _query.computeText = _computeField.stringValue ?: @"";
  _query.groupText = _groupField.stringValue ?: @"";
  _query.aggregateText = _aggregateField.stringValue ?: @"";
  _query.timeText = _timeField.stringValue ?: @"";
}

// The query's values, into the panel: after a preset, or a new entity.
- (void)showQueryControls
{
  [self.entityPopup selectItemWithTitle:[_query entity].name];
  NSString *type = _query.resultType == NSCountResultType ? @"count"
                 : _query.resultType == NSDictionaryResultType ? @"dictionary"
                 : _query.resultType == NSManagedObjectIDResultType ? @"object IDs" : @"objects";
  [self.resultTypePopup selectItemWithTitle:type];
  self.predicateView.string = _query.predicateText;
  self.limitField.stringValue = _query.limitText;
  self.skipField.stringValue = _query.skipText;
  _searchField.stringValue = _query.searchText;
  _computeField.stringValue = _query.computeText;
  _groupField.stringValue = _query.groupText;
  _aggregateField.stringValue = _query.aggregateText;
  _timeField.stringValue = _query.timeText;
  _timeField.enabled = [_query hasApplicationTime];
  [_pathItems removeAllObjects];
  [self reloadQueryPanel];
}

- (WBQuery *)currentQuery
{
  [self readQueryControls];
  return _query;
}

- (void)rebuildColumns
{
  NSArray *existing = [self.tableView.tableColumns copy];
  for (NSTableColumn *col in existing) [self.tableView removeTableColumn:col];
  WBQuery *query = [self currentQuery];
  if (!query) return;
  if (query.resultType == NSCountResultType) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"count"];
    col.title = @"count";
    col.width = 120;
    [self.tableView addTableColumn:col];
    return;
  }
  for (NSString *ident in [query columnNames]) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = ident;
    col.width = ident.length > 6 ? 150 : 90;
    [self.tableView addTableColumn:col];
  }
}

// The GET the store would send, from the same schema and version it uses.
- (void)refreshTranslation
{
  WBQuery *query = [self currentQuery];
  if (!query) return;
  NSError *error = nil;
  if ([query isVerbatim]) {
    NSURL *url = _connection.context ? [[query verbatimQueryInContext:_connection.context error:&error] URL:&error] : nil;
    self.wireURLField.stringValue = url.absoluteString ?: (error.localizedDescription ?: @"");
    return;
  }
  NSFetchRequest *request = [query fetchRequestError:&error];
  if (!request) {
    self.wireURLField.stringValue = error.localizedDescription ?: @"bad predicate";
    return;
  }
  NSURL *url = [_connection.store URLForFetchRequest:request error:&error];
  self.wireURLField.stringValue = url.absoluteString ?: (error.localizedDescription ?: @"");
}

- (void)controlTextDidChange:(NSNotification *)n
{
  // The query's fields: the results below are no longer its answer.
  NSArray *fields = @[ self.limitField, self.skipField, self.batchSizeField, _searchField, _computeField, _groupField, _aggregateField, _timeField ];
  if ([fields indexOfObjectIdenticalTo:n.object] != NSNotFound) [self invalidateResults];
  [self refreshTranslation];
}

- (void)predicateChanged:(NSNotification *)n
{
  (void)n;
  [self invalidateResults];
  [self refreshTranslation];
}

// A switch of the query's: result type, sub-entities, faults.
- (IBAction)queryChanged:(id)sender
{
  (void)sender;
  [self invalidateResults];
  [self refreshTranslation];
}

- (IBAction)entityChanged:(id)sender
{
  (void)sender;
  [[self currentQuery] reset];
  [self showQueryControls];
  [self invalidateResults];
  [self refreshTranslation];
}

- (IBAction)applyPreset:(id)sender
{
  (void)sender;
  NSInteger idx = self.presetsPopup.indexOfSelectedItem;
  if (!_query || idx < 0 || idx >= (NSInteger)_presets.count) return;
  [self readQueryControls];
  [_query applyPreset:_presets[(NSUInteger)idx]];
  [self showQueryControls];
  [self invalidateResults];
  [self refreshTranslation];
}

#pragma mark - The results

// The screen is master and detail: the query above, its results below. A
// change to the query empties the results, and what acts on them, until
// Execute fetches them again.
- (void)invalidateResults
{
  [_results clear];
  [self.tableView deselectAll:nil];
  [self rebuildColumns];
  [self.tableView reloadData];
  [self selectionChanged];
  if (_query && !_connection.connecting) self.statusField.stringValue = @"The query changed: Execute to fetch.";
}

// What acts on the selected result: the inspector, the operations bound to
// it, its streams, and the buttons that need a row.
- (void)selectionChanged
{
  [self inspectSelection];
  [self rebuildOperations];
  [self rebuildStreams];
  BOOL object = [self selectedObject] != nil;
  _deleteButton.enabled = object;
  _faultButton.enabled = object;
  _fireButton.enabled = object;
}

- (IBAction)runFetch:(id)sender
{
  (void)sender;
  if (!_connection.context || !_query) {
    self.statusField.stringValue = @"Not connected.";
    return;
  }
  // What the service has now, for the objects the context holds from
  // before too (another client's change, the Sync window's device): each
  // turned back into a fault, read again from what this fetch brings. An
  // unsaved edit here is kept.
  for (NSManagedObject *object in [_connection.context.registeredObjects copy]) {
    if (!object.hasChanges && !object.isFault) [_connection.context refreshObject:object mergeChanges:NO];
  }
  NSError *error = nil;
  if ([[self currentQuery] isVerbatim]) {
    // As it is written: every row at once, the columns what they have.
    ODataQuery *verbatim = [[self currentQuery] verbatimQueryInContext:_connection.context error:&error];
    if (!verbatim) {
      self.statusField.stringValue = error.localizedDescription;
      return;
    }
    [self refreshTranslation];
    [self.tableView deselectAll:nil];
    [_results runQuery:verbatim];
    [self rebuildColumns];
    if ([_results.rows.firstObject isKindOfClass:[NSDictionary class]]) {
      NSMutableArray *keys = [NSMutableArray array];
      for (NSDictionary *row in _results.rows) {
        for (NSString *key in [row.allKeys sortedArrayUsingSelector:@selector(compare:)]) if (![keys containsObject:key]) [keys addObject:key];
      }
      for (NSTableColumn *column in [self.tableView.tableColumns copy]) [self.tableView removeTableColumn:column];
      for (NSString *key in keys) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:key];
        column.title = key;
        column.width = key.length > 6 ? 150 : 90;
        [self.tableView addTableColumn:column];
      }
    }
    [self.tableView reloadData];
    self.statusField.stringValue = _results.lastError ?: [_results statusFor:[_query entity].name];
    [self selectionChanged];
    return;
  }
  NSFetchRequest *request = [[self currentQuery] fetchRequestError:&error];
  if (!request) {
    self.statusField.stringValue = error.localizedDescription;
    return;
  }
  [self refreshTranslation];
  [self rebuildColumns];
  [self.tableView deselectAll:nil];
  // A screenful, and the rest as the table is scrolled to its end.
  [_results fetch:request pageSize:[self screenful]];
  [self.tableView reloadData];
  self.statusField.stringValue = [_results statusFor:[_query entity].name];
  [self selectionChanged];
  [self fillTable];
}

// How many rows the table shows at once.
- (NSUInteger)screenful
{
  if (_screenfulForTests) return _screenfulForTests;
  CGFloat row = self.tableView.rowHeight + self.tableView.intercellSpacing.height;
  CGFloat height = self.tableView.enclosingScrollView.contentView.bounds.size.height;
  NSUInteger rows = row > 0 ? (NSUInteger)(height / row) + 1 : 20;
  return MAX(rows, (NSUInteger)10);
}

// The next screenful of the results, after those already there.
- (void)loadNextPage
{
  if (!_results.hasMore || _loadingPage) return;
  _loadingPage = YES;
  [_results loadPageOfSize:[self screenful]];
  _loadingPage = NO;
  [self.tableView reloadData];
  self.statusField.stringValue = [_results statusFor:[_query entity].name];
  [self fillTable];
}

// A table taller than a page's rows: filled (not when a test says how
// many rows a screen holds).
- (void)fillTable
{
  if (!_screenfulForTests) [self resultsScrolled:nil];
}

- (void)resultsScrolled:(NSNotification *)n
{
  (void)n;
  if (!_results.hasMore || _loadingPage || !_results.rows.count) return;
  NSRange visible = [self.tableView rowsInRect:self.tableView.enclosingScrollView.contentView.bounds];
  if (NSMaxRange(visible) + 1 >= _results.rows.count) [self loadNextPage];
}

#pragma mark - The wire log

- (void)appendLog:(WorkbenchLogEntry *)entry
{
  NSInteger selected = _logTable.selectedRow;
  WorkbenchLogEntry *shown = selected >= 0 && (NSUInteger)selected < _log.count ? _log[(NSUInteger)selected] : nil;
  [_log insertObject:entry atIndex:0];
  if (_log.count > 1000) [_log removeLastObject];
  [_logTable reloadData];
  NSUInteger again = shown ? [_log indexOfObjectIdenticalTo:shown] : NSNotFound;
  if (again != NSNotFound) {
    _keepingLogSelection = YES;
    [_logTable selectRowIndexes:[NSIndexSet indexSetWithIndex:again] byExtendingSelection:NO];
    _keepingLogSelection = NO;
  }
}

- (id)logValueForColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _log.count) return nil;
  WorkbenchLogEntry *entry = _log[(NSUInteger)row];
  NSString *identifier = column.identifier;
  if ([identifier isEqualToString:@"time"]) {
    static NSDateFormatter *format;
    if (!format) {
      format = [[NSDateFormatter alloc] init];
      format.dateFormat = @"HH:mm:ss.SSS";
    }
    return entry.date ? [format stringFromDate:entry.date] : @"";
  }
  if ([identifier isEqualToString:@"method"]) return entry.method;
  if ([identifier isEqualToString:@"status"]) return entry.status ? [NSString stringWithFormat:@"%ld", (long)entry.status] : @"—";
  // The URL from the service root on, decoded to be read.
  NSString *url = entry.URL;
  NSString *root = _connection.serviceRoot.absoluteString;
  if (root.length && [url hasPrefix:root]) url = [url substringFromIndex:root.length];
  return [url stringByRemovingPercentEncoding] ?: url;
}

// A body as it went: its text where it is UTF-8, else a hex dump.
static NSString *WBRawBody(NSData *data)
{
  if (!data.length) return @"";
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (text) return text;
  NSMutableString *dump = [NSMutableString stringWithFormat:@"(%lu bytes, not UTF-8 text)\n", (unsigned long)data.length];
  const unsigned char *bytes = data.bytes;
  for (NSUInteger offset = 0; offset < data.length; offset += 16) {
    NSMutableString *hex = [NSMutableString string], *ascii = [NSMutableString string];
    for (NSUInteger i = offset; i < offset + 16; i++) {
      if (i < data.length) {
        [hex appendFormat:@"%02x ", bytes[i]];
        [ascii appendFormat:@"%c", bytes[i] >= 32 && bytes[i] < 127 ? bytes[i] : '.'];
      } else {
        [hex appendString:@"   "];
      }
    }
    [dump appendFormat:@"%08lx  %@ |%@|\n", (unsigned long)offset, hex, ascii];
  }
  return dump;
}

static NSString *WBRawHeaders(NSDictionary *headers)
{
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
    [text appendFormat:@"%@: %@\n", name, headers[name]];
  }
  return text;
}

- (NSString *)rawRequestOf:(WorkbenchLogEntry *)entry
{
  return [NSString stringWithFormat:@"%@ %@ HTTP/1.1\n%@\n%@", entry.method, entry.URL, WBRawHeaders(entry.requestHeaders),
                                    WBRawBody(entry.requestData)];
}

- (NSString *)rawResponseOf:(WorkbenchLogEntry *)entry
{
  if (!entry.status) return [NSString stringWithFormat:@"(no answer: %@)", entry.failure ?: @"the request failed"];
  // HTTP's own reason phrases: Foundation's localized ones say "no error".
  static NSDictionary *reasons;
  if (!reasons) {
    reasons = @{ @200: @"OK", @201: @"Created", @202: @"Accepted", @204: @"No Content", @302: @"Found", @304: @"Not Modified",
                 @400: @"Bad Request", @401: @"Unauthorized", @403: @"Forbidden", @404: @"Not Found", @405: @"Method Not Allowed",
                 @406: @"Not Acceptable", @409: @"Conflict", @412: @"Precondition Failed", @415: @"Unsupported Media Type",
                 @428: @"Precondition Required", @500: @"Internal Server Error", @501: @"Not Implemented", @503: @"Service Unavailable" };
  }
  NSString *reason = reasons[@(entry.status)] ?: [NSHTTPURLResponse localizedStringForStatusCode:entry.status].capitalizedString;
  return [NSString stringWithFormat:@"HTTP/1.1 %ld %@\n%@\n%@", (long)entry.status, reason ?: @"",
                                    WBRawHeaders(entry.responseHeaders), WBRawBody(entry.responseData)];
}

// A window of its own xib, loaded when it is first shown.
- (void)loadWindowNib:(NSString *)name textViews:(NSArray<NSTextView *> *(^)(void))textViews
{
  if (!WorkbenchLoadNib(name, self)) {
    NSLog(@"Workbench: failed to load %@.xib", name);
    return;
  }
  for (NSTextView *view in textViews()) [self prepareTextView:view fixedPitch:YES];
}

#pragma mark - Traces

// A Trace menu beside the others, and the exchange's trace a right click
// away in the log.
- (void)addTraceMenus
{
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Trace"];
  NSMenuItem *show = [menu addItemWithTitle:@"Show Traces" action:@selector(showTraces:) keyEquivalent:@"t"];
  show.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  NSMenuItem *exchange = [menu addItemWithTitle:@"Show Trace of Exchange" action:@selector(showTraceOfExchange:) keyEquivalent:@"t"];
  exchange.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Clear Traces" action:@selector(clearTraces:) keyEquivalent:@""];
  for (NSMenuItem *item in menu.itemArray) item.target = self;
  NSMenu *main = [NSApp mainMenu];
  if (main) {
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:@"Trace" action:NULL keyEquivalent:@""];
    holder.submenu = menu;
    // Before Window and Help, where those are.
    NSInteger at = main.numberOfItems;
    for (NSInteger i = 0; i < main.numberOfItems; i++) {
      NSString *title = [main itemAtIndex:i].title;
      if ([title isEqualToString:@"Window"] || [title isEqualToString:@"Help"]) {
        at = i;
        break;
      }
    }
    [main insertItem:holder atIndex:at];
  }
  if (!_logTable.menu) {
    NSMenu *context = [[NSMenu alloc] initWithTitle:@"Exchange"];
    [context addItemWithTitle:@"Show Exchange" action:@selector(showExchange:) keyEquivalent:@""].target = self;
    [context addItemWithTitle:@"Show Trace" action:@selector(showTraceOfExchange:) keyEquivalent:@""].target = self;
    _logTable.menu = context;
  }
}

#pragma mark - Sync

// A Sync menu beside Trace: an offline device, kept in sync with the
// built-in service by ODataSync.
- (void)addSyncMenu
{
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Sync"];
  NSMenuItem *show = [menu addItemWithTitle:@"Show Device" action:@selector(showSync:) keyEquivalent:@"y"];
  show.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  show.target = self;
  // For a device elsewhere: the Device app, on an iPhone on the same network.
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Serve on the Network" action:@selector(toggleServeNetwork:) keyEquivalent:@""].target = self;
  NSMenu *main = [NSApp mainMenu];
  if (!main) return;
  NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:@"Sync" action:NULL keyEquivalent:@""];
  holder.submenu = menu;
  NSInteger at = main.numberOfItems;
  for (NSInteger i = 0; i < main.numberOfItems; i++) {
    NSString *title = [main itemAtIndex:i].title;
    if ([title isEqualToString:@"Window"] || [title isEqualToString:@"Help"]) {
      at = i;
      break;
    }
  }
  [main insertItem:holder atIndex:at];
}

- (WBSyncWindow *)syncDevice
{
  WorkbenchEngine *engine = self.connection.engine;
  if (!engine) return nil;
  if (_syncWindow.engine != engine) {
    [_syncWindow.window close];
    _syncWindow = [[WBSyncWindow alloc] initWithEngine:engine];
  }
  return _syncWindow;
}

- (void)serveOnTheNetworkAtPort:(NSUInteger)port
{
  if (port) _connection.servePort = port;
  if (_connection.servesNetwork) return;
  [self.servicePopup selectItemAtIndex:WBServiceBuiltIn];
  self.serviceURLField.stringValue = [WBConnection rootOfService:WBServiceBuiltIn];
  [self toggleServeNetwork:nil];
}

// The built-in service served on the network too, or no longer: a new
// connection to it, at the network's root (its data starts again).
- (IBAction)toggleServeNetwork:(id)sender
{
  (void)sender;
  _connection.servesNetwork = !_connection.servesNetwork;
  if (![self builtIn]) {
    self.statusField.stringValue = _connection.servesNetwork ? @"The built-in service is served on the network once you connect to it."
                                                             : @"The built-in service is no longer served on the network.";
    return;
  }
  [self connect:nil];
}

- (IBAction)showSync:(id)sender
{
  (void)sender;
  WBSyncWindow *device = [self syncDevice];
  if (!device) {
    self.statusField.stringValue = @"Sync works with the built-in service: choose it, and Connect.";
    return;
  }
  [device show];
}

- (WBTraceWindow *)traces
{
  if (!_traceWindow) _traceWindow = [[WBTraceWindow alloc] initWithRecorder:_traceRecorder];
  return _traceWindow;
}

- (IBAction)showTraces:(id)sender
{
  (void)sender;
  [[self traces] show];
}

- (IBAction)showTraceOfExchange:(id)sender
{
  (void)sender;
  // A right click acts on the row clicked, which need not be selected.
  NSInteger row = _logTable.clickedRow >= 0 ? _logTable.clickedRow : _logTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _log.count) {
    [[self traces] show];
    return;
  }
  WorkbenchLogEntry *entry = _log[(NSUInteger)row];
  NSString *traceID = WBTraceIDOfHeaders(entry.requestHeaders);
  if (!traceID || ![[self traces] showTraceWithID:traceID spanID:WBSpanIDOfHeaders(entry.requestHeaders)]) {
    self.statusField.stringValue = traceID ? @"That exchange's trace is no longer kept." : @"That exchange carries no trace.";
  }
  // Asked for (a menu): to the front; following the log: beside it.
  if (sender) [_traceWindow.window makeKeyAndOrderFront:nil];
}

- (IBAction)clearTraces:(id)sender
{
  (void)sender;
  [_traceRecorder clear];
}

- (IBAction)showExchange:(id)sender
{
  (void)sender;
  NSInteger row = _logTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _log.count) return;
  WorkbenchLogEntry *entry = _log[(NSUInteger)row];
  if (!_exchangeWindow) [self loadWindowNib:@"ExchangeWindow" textViews:^{ return @[ self.requestView, self.responseView ]; }];
  _exchangeWindow.title = [NSString stringWithFormat:@"%@ %@ — %@ (%.0f ms)", entry.method, [self logValueForColumn:[_logTable tableColumnWithIdentifier:@"URL"] row:row],
                                                     entry.status ? [NSString stringWithFormat:@"%ld", (long)entry.status] : @"no answer", entry.duration * 1000];
  [self show:[self rawRequestOf:entry] in:_requestView];
  [self show:[self rawResponseOf:entry] in:_responseView];
  [_exchangeWindow makeKeyAndOrderFront:nil];
}

#pragma mark - Explain

// The built-in service's plan for the GET the store would send: the same
// URL under $explain/, which the service answers with the plans instead of
// the rows. Another service has no $explain.
- (IBAction)explainQuery:(id)sender
{
  (void)sender;
  WorkbenchEngine *engine = _connection.engine;
  if (!engine) {
    self.statusField.stringValue = @"Explain asks the built-in service for its plan; other services have no $explain.";
    return;
  }
  [self refreshTranslation];
  NSString *root = engine.serviceRoot.absoluteString;
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSString *wire = self.wireURLField.stringValue;
  if (![wire hasPrefix:root]) {
    self.statusField.stringValue = [NSString stringWithFormat:@"Nothing to explain: %@", wire.length ? wire : @"no query"];
    return;
  }
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@$explain/%@", root, [wire substringFromIndex:root.length]]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"4.01" forHTTPHeaderField:@"OData-MaxVersion"];
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:request target:self action:@selector(didExplain:)];
  [engine startExchange:exchange];
}

- (void)didExplain:(ODataExchange *)exchange
{
  if (![NSThread isMainThread]) {
    [self performSelectorOnMainThread:_cmd withObject:exchange waitUntilDone:NO];
    return;
  }
  NSInteger status = [exchange.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)exchange.URLResponse).statusCode : 0;
  id json = exchange.data.length ? [NSJSONSerialization JSONObjectWithData:exchange.data options:0 error:NULL] : nil;
  NSDictionary *body = [json isKindOfClass:[NSDictionary class]] ? json : nil;
  if (status != 200 || ![body[@"physical"] isKindOfClass:[NSString class]]) {
    NSString *why = [body[@"error"] isKindOfClass:[NSDictionary class]] ? body[@"error"][@"message"] : exchange.error.localizedDescription;
    self.statusField.stringValue = [NSString stringWithFormat:@"The service did not explain it (%ld): %@", (long)status, why ?: @"no answer"];
    return;
  }
  if (!_planWindow) {
    [self loadWindowNib:@"PlanWindow" textViews:^{ return @[ self.explainedView, self.physicalPlanView, self.logicalPlanView ]; }];
  }
  // The request as the store would send it, decoded: the URL without
  // $explain/.
  NSString *path = [exchange.request.URL.absoluteString stringByRemovingPercentEncoding] ?: exchange.request.URL.absoluteString;
  NSRange explain = [path rangeOfString:@"$explain/"];
  if (explain.location != NSNotFound) path = [path stringByReplacingCharactersInRange:explain withString:@""];
  _planWindow.title = @"Plan";
  [self show:[@"GET " stringByAppendingString:path] in:_explainedView];
  [self show:[@"Physical plan\n\n" stringByAppendingString:body[@"physical"]] in:_physicalPlanView];
  NSString *logical = [body[@"logical"] isKindOfClass:[NSString class]] ? body[@"logical"] : @"(the same as the physical plan)";
  [self show:[@"Logical plan\n\n" stringByAppendingString:logical] in:_logicalPlanView];
  [_planWindow makeKeyAndOrderFront:nil];
  self.statusField.stringValue = @"Explained: the plan is in its own window.";
}

#pragma mark - The table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  if (table == _logTable) return (NSInteger)_log.count;
  if (table == _sortTable) return (NSInteger)_query.sorts.count;
  if (table == _selectTable) return (NSInteger)[_query attributeNames].count;
  return (NSInteger)_results.rows.count;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _logTable) return [self logValueForColumn:column row:row];
  if (table == _sortTable || table == _selectTable) return [self queryValueIn:table column:column row:row];
  NSArray *rows = _results.rows;
  if (row < 0 || (NSUInteger)row >= rows.count) return nil;
  id obj = rows[(NSUInteger)row];
  if ([obj isKindOfClass:[NSNumber class]]) return obj;
  if ([obj isKindOfClass:[NSDictionary class]]) return WBCellValue(obj[column.identifier]);
  if ([obj isKindOfClass:[NSManagedObjectID class]]) return [obj URIRepresentation];
  if ([obj isKindOfClass:[NSManagedObject class]]) {
    @try {
      NSRelationshipDescription *relationship = [obj entity].relationshipsByName[column.identifier];
      if (relationship) {
        // Prefetched: what came with the row, named.
        id related = [obj valueForKey:column.identifier];
        if (!relationship.isToMany) return related ? WBTitleOf(related, [self builtIn]) : @"—";
        NSMutableArray *titles = [NSMutableArray array];
        for (NSManagedObject *member in related) [titles addObject:WBTitleOf(member, [self builtIn])];
        [titles sortUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"%lu: %@", (unsigned long)titles.count, [titles componentsJoinedByString:@", "]];
      }
      id value = [obj valueForKey:column.identifier];
      if (WBIsDynamic([obj entity].attributesByName[column.identifier])) return WBDynamicText(value);
      if ([[obj entity].attributesByName[column.identifier] attributeType] == NSBooleanAttributeType && value) {
        return [value boolValue] ? @"true" : @"false";
      }
      return WBCellValue(value);
    } @catch (NSException *ex) {
      return ex.reason;
    }
  }
  return [obj description];
}

// An edit waits for Save, as a change to a managed object does.
- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _sortTable || table == _selectTable) {
    [self setQueryValue:value in:table column:column row:row];
    return;
  }
  NSString *why = [_results setValue:value forKey:column.identifier ofRow:row];
  if (why) {
    self.statusField.stringValue = why;
    return;
  }
  [self showPending];
  [self.tableView reloadData];
  [self inspectSelection];
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
  if (n.object == _logTable) {
    if (!_keepingLogSelection) {
      [self showExchange:nil];
      // The trace window, when open, follows the log.
      if (_traceWindow.window.isVisible) [self showTraceOfExchange:nil];
    }
    return;
  }
  if (n.object != self.tableView) return;
  [self selectionChanged];
}

- (NSManagedObject *)selectedObject
{
  return [_results objectAtRow:self.tableView.selectedRow];
}

- (void)inspectSelection
{
  NSManagedObject *object = [self selectedObject];
  [self show:object ? WBDescribe(object) : @"Select a row." in:self.inspectorView];
}

- (IBAction)fulfillFault:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object) return;
  for (NSString *name in object.entity.attributesByName) {
    (void)[object valueForKey:name];
  }
  [self inspectSelection];
  [self.tableView reloadData];
}

- (IBAction)fireRelationships:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object) return;
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ relationships (each says whether reading it asked the service)\n", object.entity.name];
  NSArray *names = [[object.entity.relationshipsByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSRelationshipDescription *rel = object.entity.relationshipsByName[name];
    @try {
      NSUInteger before = _connection.exchangesStarted;
      id value = [object valueForKey:name];
      NSMutableString *members = [NSMutableString string];
      if (rel.isToMany) {
        for (NSManagedObject *m in value) [members appendFormat:@"  • %@ %@\n", m.entity.name, WBTitleOf(m, [self builtIn])];
      } else if (value) {
        [members appendFormat:@"  %@\n", WBTitleOf(value, [self builtIn])];
      }
      NSUInteger asked = _connection.exchangesStarted - before;
      NSString *how = asked ? [NSString stringWithFormat:@"%lu request%@ to the service", (unsigned long)asked, asked == 1 ? @"" : @"s"]
                            : @"no request: prefetched, or read before";
      if (rel.isToMany) {
        [text appendFormat:@"\n%@ (to-many, %lu) — %@\n", name, (unsigned long)[value count], how];
      } else {
        [text appendFormat:@"\n%@ (to-one) → %@ — %@\n", name, value ? [value entity].name : @"nil", how];
      }
      [text appendString:members];
    } @catch (NSException *ex) {
      [text appendFormat:@"\n%@: %@\n", name, ex.reason];
    }
  }
  [self show:text in:self.inspectorView];
}

#pragma mark - The query panel

- (void)reloadQueryPanel
{
  [_sortTable reloadData];
  [_expandOutline reloadData];
  [_selectTable reloadData];
}

// A change in the lists: the panel shows it, the results wait for Execute.
- (void)queryListsChanged
{
  [self reloadQueryPanel];
  [self invalidateResults];
  [self refreshTranslation];
}

- (IBAction)addSort:(id)sender
{
  (void)sender;
  [[self currentQuery] addSort];
  [self queryListsChanged];
  [_sortTable selectRowIndexes:[NSIndexSet indexSetWithIndex:_query.sorts.count - 1] byExtendingSelection:NO];
}

- (IBAction)removeSort:(id)sender
{
  (void)sender;
  [[self currentQuery] removeSortAtRow:_sortTable.selectedRow];
  [self queryListsChanged];
}

- (void)moveSortBy:(NSInteger)step
{
  NSInteger to = [[self currentQuery] moveSortAtRow:_sortTable.selectedRow by:step];
  if (to < 0) return;
  [self queryListsChanged];
  [_sortTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)to] byExtendingSelection:NO];
}

- (IBAction)moveSortUp:(id)sender
{
  (void)sender;
  [self moveSortBy:-1];
}

- (IBAction)moveSortDown:(id)sender
{
  (void)sender;
  [self moveSortBy:1];
}

- (id)queryValueIn:(NSTableView *)table column:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _sortTable) {
    if (row < 0 || (NSUInteger)row >= _query.sorts.count) return nil;
    return _query.sorts[(NSUInteger)row][column.identifier];
  }
  NSArray *names = [_query attributeNames];
  if (row < 0 || (NSUInteger)row >= names.count) return nil;
  if ([column.identifier isEqualToString:@"include"]) return @([_query.select containsObject:names[(NSUInteger)row]]);
  return names[(NSUInteger)row];
}

- (void)setQueryValue:(id)value in:(NSTableView *)table column:(NSTableColumn *)column row:(NSInteger)row
{
  WBQuery *query = [self currentQuery];
  if (table == _sortTable) {
    if (row < 0 || (NSUInteger)row >= query.sorts.count) return;
    query.sorts[(NSUInteger)row][column.identifier] = [column.identifier isEqualToString:@"descending"] ? @([value boolValue]) : [value description];
  } else if ([column.identifier isEqualToString:@"include"]) {
    NSArray *names = [query attributeNames];
    if (row < 0 || (NSUInteger)row >= names.count) return;
    if ([value boolValue]) [query.select addObject:names[(NSUInteger)row]];
    else [query.select removeObject:names[(NSUInteger)row]];
  }
  [self queryListsChanged];
}

// The outline's items are key paths from the current entity, one string
// per path, so the outline can tell them apart.
- (NSString *)itemForPath:(NSString *)path
{
  NSString *item = _pathItems[path];
  if (!item) _pathItems[path] = item = [path copy];
  return item;
}

- (NSEntityDescription *)entityAtPath:(NSString *)path
{
  NSEntityDescription *entity = [_query entity];
  for (NSString *part in path.length ? [path componentsSeparatedByString:@"."] : @[]) {
    NSRelationshipDescription *rel = entity.relationshipsByName[part];  // gnustep-base: no generics to type the subscript
    entity = rel.destinationEntity;
  }
  return entity;
}

- (NSArray *)childPathsOf:(NSString *)path
{
  if ([path componentsSeparatedByString:@"."].count >= 4) return @[];  // deep enough to see the point
  NSEntityDescription *entity = [self entityAtPath:path];
  NSMutableArray *children = [NSMutableArray array];
  for (NSString *name in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [children addObject:[self itemForPath:path.length ? [NSString stringWithFormat:@"%@.%@", path, name] : name]];
  }
  return children;
}

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item
{
  return _query ? (NSInteger)[self childPathsOf:item ?: @""].count : 0;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item
{
  return [self childPathsOf:item ?: @""][(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item
{
  return [self childPathsOf:item].count > 0;
}

- (id)outlineView:(NSOutlineView *)outline objectValueForTableColumn:(NSTableColumn *)column byItem:(id)item
{
  if ([column.identifier isEqualToString:@"include"]) return @([_query.prefetch containsObject:item]);
  NSString *name = [[item componentsSeparatedByString:@"."] lastObject];
  NSRange dot = [item rangeOfString:@"." options:NSBackwardsSearch];
  NSEntityDescription *owner = [self entityAtPath:dot.location == NSNotFound ? @"" : [item substringToIndex:dot.location]];
  NSRelationshipDescription *rel = owner.relationshipsByName[name];
  return [NSString stringWithFormat:@"%@ → %@%@", name, rel.destinationEntity.name, rel.isToMany ? @" (many)" : @""];
}

- (void)outlineView:(NSOutlineView *)outline setObjectValue:(id)value forTableColumn:(NSTableColumn *)column byItem:(id)item
{
  if (![column.identifier isEqualToString:@"include"]) return;
  // The prefetched relationships are columns: fetch again to see them.
  [[self currentQuery] setPrefetch:item included:[value boolValue]];
  [self queryListsChanged];
}

- (BOOL)outlineView:(NSOutlineView *)outline shouldEditTableColumn:(NSTableColumn *)column item:(id)item
{
  return [column.identifier isEqualToString:@"include"];
}

- (BOOL)tableView:(NSTableView *)table shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _logTable) return NO;
  if (table == _selectTable) return [column.identifier isEqualToString:@"include"];
  return YES;
}

#pragma mark - Writing

// The changes waiting for Save, in the status line and the buttons.
- (void)showPending
{
  NSUInteger pending = [_results pendingCount];
  self.saveButton.enabled = pending > 0;
  self.revertButton.enabled = pending > 0;
  NSString *summary = [_results pendingSummary];
  if (summary) self.statusField.stringValue = summary;
}

- (IBAction)insertObject:(id)sender
{
  (void)sender;
  WBQuery *query = [self currentQuery];
  NSEntityDescription *entity = [query entity];
  if (!_connection.context || !entity) return;
  if (entity.isAbstract) {
    self.statusField.stringValue = [NSString stringWithFormat:@"%@ is abstract: choose one of its sub-entities.", entity.name];
    return;
  }
  if (query.resultType != NSManagedObjectResultType) {
    [self.resultTypePopup selectItemWithTitle:@"objects"];
    [_results clear];
    [self rebuildColumns];
  }
  [_results insertObjectOf:entity];
  [self.tableView reloadData];
  [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [self inspectSelection];
  [self showPending];
}

- (IBAction)deleteSelected:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object) return;
  [_results deleteObject:object];
  [self.tableView reloadData];
  [self inspectSelection];
  [self showPending];
}

- (IBAction)saveChanges:(id)sender
{
  (void)sender;
  if (![_results pendingCount]) {
    self.statusField.stringValue = @"Nothing to save.";
    return;
  }
  NSManagedObjectContext *context = _connection.context;
  NSUInteger inserted = context.insertedObjects.count, updated = context.updatedObjects.count, deleted = context.deletedObjects.count;
  NSArray *conflicts = nil;
  NSString *why = [_results save:&conflicts];
  if (conflicts.count) {
    [self show:[_results describeConflicts:conflicts] in:self.inspectorView];
    self.statusField.stringValue = [NSString stringWithFormat:@"Save refused: %lu conflict%@ (see the inspector). Choose in Store what wins, then Save again, or Revert.",
                                    (unsigned long)conflicts.count, conflicts.count == 1 ? @"" : @"s"];
    return;
  }
  if (why) {
    self.statusField.stringValue = [NSString stringWithFormat:@"Could not save: %@", why];
    return;
  }
  [self runFetch:nil];
  self.statusField.stringValue = [NSString stringWithFormat:@"Saved: %lu inserted (POST), %lu updated (PATCH), %lu deleted (DELETE).",
                                  (unsigned long)inserted, (unsigned long)updated, (unsigned long)deleted];
  [self showPending];
}

- (IBAction)revertChanges:(id)sender
{
  (void)sender;
  [_results revert];
  [self runFetch:nil];
  self.statusField.stringValue = @"Reverted: the unsaved changes are gone.";
  [self showPending];
}

#pragma mark - Actions and functions

// What can be called now: the selected object's methods, its entity's
// class methods, and the service's own operations.
- (void)rebuildOperations
{
  [self.operationPopup removeAllItems];
  NSManagedObject *object = [self selectedObject];
  NSArray *items = _results ? [_results operationsForObject:object entity:[_query entity]] : @[];
  if (!items.count) {
    [self.operationPopup addItemWithTitle:object ? @"(no operations)" : @"(select a row for its operations)"];
    return;
  }
  for (NSArray *item in items) {
    [self.operationPopup addItemWithTitle:item[0]];
    self.operationPopup.lastItem.representedObject = item[1];
  }
}

- (IBAction)invokeOperation:(id)sender
{
  (void)sender;
  NSDictionary *what = self.operationPopup.selectedItem.representedObject;
  if (!what || !_connection.context) {
    self.statusField.stringValue = @"Choose an operation.";
    return;
  }
  NSString *status = nil;
  NSString *text = [_results invoke:what object:[self selectedObject]
                         parameters:[WBResults parametersFromText:self.operationParametersField.stringValue] status:&status];
  // Temporal's actions change the timeline: read it again.
  if (text && [what[@"kind"] isEqual:@"temporal"]) [self runFetch:nil];
  if (text) [self show:text in:self.inspectorView];
  self.statusField.stringValue = status ?: @"";
}

#pragma mark - Streams

// Beside the inspector, which gives up some of its width: the stream, and
// Download and Upload.
- (void)rebuildStreams
{
  [_streamPopup removeAllItems];
  NSManagedObject *object = [self selectedObject];
  NSEntityDescription *entity = object ? object.entity : [_query entity];
  NSArray *names = _results ? [_results streamNamesOf:entity] : @[];
  for (NSString *name in names) {
    [_streamPopup addItemWithTitle:name.length ? name : @"media ($value)"];
    _streamPopup.lastItem.representedObject = name;
  }
  if (!names.count) [_streamPopup addItemWithTitle:@"(no streams)"];
  _streamPopup.enabled = names.count > 0;
  _downloadButton.enabled = names.count > 0;
  // With no row chosen, an upload makes a new media entity.
  _uploadButton.enabled = names.count > 0;
}

- (IBAction)downloadStream:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  NSString *name = _streamPopup.selectedItem.representedObject;
  if (!object || !name) {
    self.statusField.stringValue = @"Select a row, and one of its streams.";
    return;
  }
  NSData *data = nil;
  NSString *contentType = nil, *status = nil;
  NSString *text = [_results download:name of:object data:&data contentType:&contentType status:&status];
  self.statusField.stringValue = status ?: @"";
  if (!text) return;
  [self show:text in:self.inspectorView];
  // An image: shown, under what is said of it.
  NSImage *image = [contentType hasPrefix:@"image/"] ? [[NSImage alloc] initWithData:data] : nil;
  if (image && image.size.width > 0 && image.size.height > 0) [self showImage:image below:text];
}

- (IBAction)uploadStream:(id)sender
{
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK || !panel.URLs.firstObject) return;
  [self uploadStreamFromFile:panel.URLs.firstObject];
}

// Into the selected row's stream (PUT, with its media ETag); with no row
// selected, a new media entity of the entity (POST), to be named and saved.
- (BOOL)uploadStreamFromFile:(NSURL *)file
{
  NSManagedObject *object = [self selectedObject];
  NSString *status = nil;
  BOOL done = [_results upload:file into:_streamPopup.selectedItem.representedObject of:object entity:[[self currentQuery] entity] status:&status];
  self.statusField.stringValue = status ?: @"";
  if (done && !object) {
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    self.statusField.stringValue = status;
  }
  return done;
}

#pragma mark - The Store menu

- (void)updateStoreMenu
{
  for (NSMenuItem *item in _storeMenu.itemArray) {
    if (item.tag <= 2 && sel_isEqual(item.action, @selector(setMergePolicy:))) item.state = item.tag == _connection.mergePolicy ? NSOnState : NSOffState;
    if (item.tag == 10) item.state = _connection.respondAsync ? NSOnState : NSOffState;
    if (item.tag == 11) item.state = _connection.JSONBatch ? NSOnState : NSOffState;
  }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
  if (sel_isEqual(item.action, @selector(checkForUpdates:))) return _updater.canCheckForUpdates;
  if (sel_isEqual(item.action, @selector(signOut:))) {
    ODataSignIn *signIn = _connection.service == WBServiceOther ? self.signIns[_connection.serviceRoot.absoluteString] : nil;
    return signIn.signedIn && signIn.kind != ODataSignInNone;
  }
  if (sel_isEqual(item.action, @selector(toggleServeNetwork:))) item.state = _connection.servesNetwork ? NSOnState : NSOffState;
  if (sel_isEqual(item.action, @selector(changeAtTheService:))) return _connection.engine != nil;
  return YES;
}

- (IBAction)setMergePolicy:(NSMenuItem *)sender
{
  _connection.mergePolicy = sender.tag;
  [self updateStoreMenu];
  self.statusField.stringValue = [@[ @"A conflict now refuses the save: you choose, then Save again.",
                                     @"On a conflict your changes now win, property by property.",
                                     @"On a conflict the service's changes now win, property by property." ][(NSUInteger)sender.tag] copy];
}

- (IBAction)toggleRespondAsync:(id)sender
{
  (void)sender;
  _connection.respondAsync = !_connection.respondAsync;
  [self updateStoreMenu];
  [self connect:nil];
}

- (IBAction)toggleJSONBatch:(id)sender
{
  (void)sender;
  _connection.JSONBatch = !_connection.JSONBatch;
  [self updateStoreMenu];
  [self connect:nil];
}

- (IBAction)changeAtTheService:(id)sender
{
  (void)sender;
  if (!_connection.engine) {
    self.statusField.stringValue = @"Only the built-in service can be changed behind your back.";
    return;
  }
  self.statusField.stringValue = [[_connection.engine changeAtTheService] stringByAppendingString:@" Changes reads it; a stale Save of it conflicts."];
}

#pragma mark - Changes at the service

- (IBAction)fetchRemoteChanges:(id)sender
{
  (void)sender;
  if (!_results) return;
  BOOL changed = NO;
  NSString *status = [_results mergeRemoteChanges:&changed];
  if (changed) [self runFetch:nil];
  self.statusField.stringValue = status;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
