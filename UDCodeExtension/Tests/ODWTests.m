// UDCode's OData extension against UDCode's own document and project (its
// SDK) and the Workbench's built-in service, in this process (no network):
// requests read from text as VS Code's REST Client writes them, sent and
// answered; services kept where they say; the XIBs loaded and connected.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#import <XCTest/XCTest.h>
#import <UDCodeKit/UDCodeKit.h>
#import "ODWServices.h"
#import "ODWNavigatorViewController.h"
#import "ODWBottomViewController.h"
#import "ODWServiceSheet.h"
#import "ODWExtension.h"
#import "ODWBuilderViewController.h"
#import "WBQueryPanel.h"
#import "ODWTemplates.h"
#import <ODataKit/ODataSchema.h>
#import <UDPieceTable/UDTextModel.h>

// The window's side, as much of it as the services ask of: its project (a
// folder of the test's own, or none) and its window.
@interface ODWTestWorkbench : NSObject
@property (nonatomic, strong, nullable) UDProject *project;
@property (nonatomic, strong, nullable) NSWindow *window;
@property (nonatomic, strong, nullable) UDCodeDocument *selectedDocument;
@property (nonatomic, strong, nullable) id selectedEditor;
@property (nonatomic, strong) NSMutableArray *shownInBottomArea;
// The documents opened (UDWorkbench's -openUntitledDocumentWithText:...),
// the last the selected one.
@property (nonatomic, strong) NSMutableArray<UDCodeDocument *> *opened;
@end


@implementation ODWTestWorkbench
- (instancetype)init
{
  if ((self = [super init])) {
    _shownInBottomArea = [NSMutableArray array];
    _opened = [NSMutableArray array];
  }
  return self;
}
- (void)openUntitledDocumentWithText:(NSString *)text languageMode:(NSString *)mode name:(NSString *)name
{
  UDCodeDocument *document = [[UDCodeDocument alloc] initWithText:text fileURL:nil languageMode:nil];
  [_opened addObject:document];
  _selectedDocument = document;
  _selectedEditor = nil;
}
- (void)showBottomAreaViewController:(NSViewController *)viewController title:(NSString *)title extension:(id)extension
{
  [_shownInBottomArea addObject:viewController];
}
@end

@interface ODWTests : XCTestCase
@end

@implementation ODWTests {
  ODWTestWorkbench *_workbench;
  ODWServices *_services;
  NSMutableArray<ODWAnswer *> *_answers;
  NSArray *_userServicesBefore;
  NSMutableArray<NSWindow *> *_windows;
}

- (void)setUp
{
  [super setUp];
  [NSApplication sharedApplication];
  _userServicesBefore = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ODWServices"];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ODWServices"];
  _workbench = [[ODWTestWorkbench alloc] init];
  _services = [[ODWServices alloc] initWithWorkbench:(id<UDWorkbench>)_workbench];
  _answers = [NSMutableArray array];
  _windows = [NSMutableArray array];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(answerCame:) name:ODWAnswerNotification object:_services];
}

- (void)tearDown
{
  for (NSWindow *window in _windows) [window orderOut:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (_userServicesBefore) [[NSUserDefaults standardUserDefaults] setObject:_userServicesBefore forKey:@"ODWServices"];
  else [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ODWServices"];
  [super tearDown];
}

- (void)answerCame:(NSNotification *)note
{
  [_answers addObject:note.userInfo[ODWAnswerKey]];
}

// The run loop turned until the condition holds, five seconds at most.
- (BOOL)waitFor:(BOOL (^)(void))condition
{
  for (NSDate *until = [NSDate dateWithTimeIntervalSinceNow:5]; !condition() && [until timeIntervalSinceNow] > 0;) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  return condition();
}

#pragma mark Services

- (void)testThePresetsAndTheUsersServices
{
  NSArray *names = [_services.services valueForKey:@"name"];
  NSArray *presets = @[ @"Built-in Sample", @"Northwind", @"TripPin" ];
  XCTAssertEqualObjects(names, presets);
  ODWService *mine = [ODWServices serviceNamed:@"Orders" root:[NSURL URLWithString:@"https://example.org/odata/"] inProject:YES];
  [_services addService:mine];
  XCTAssertFalse(mine.inProject, @"no folder: the user's");
  NSArray *kept = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ODWServices"];
  XCTAssertEqualObjects([kept valueForKey:@"name"], @[ @"Orders" ]);
  // A window opened later knows it.
  ODWServices *again = [[ODWServices alloc] initWithWorkbench:(id<UDWorkbench>)_workbench];
  XCTAssertEqualObjects([again serviceNamed:@"Orders"].root.absoluteString, @"https://example.org/odata/");
  [_services removeService:[_services serviceNamed:@"Northwind"]];
  XCTAssertNotNil([_services serviceNamed:@"Northwind"], @"a preset is not removed");
  [_services removeService:mine];
  XCTAssertNil([_services serviceNamed:@"Orders"]);
}

- (void)testAProjectsServicesAreItsSettings
{
  NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
  [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
  _workbench.project = [[UDProject alloc] initWithFolderURL:[NSURL fileURLWithPath:folder isDirectory:YES]];
  ODWServices *services = [[ODWServices alloc] initWithWorkbench:(id<UDWorkbench>)_workbench];
  [services addService:[ODWServices serviceNamed:@"Shared" root:[NSURL URLWithString:@"https://example.org/shared/"] inProject:YES]];
  NSData *data = [NSData dataWithContentsOfURL:_workbench.project.settingsURL];
  NSDictionary *settings = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  XCTAssertEqualObjects([settings[@"odataServices"] valueForKey:@"url"], @[ @"https://example.org/shared/" ]);
  XCTAssertNil(settings[@"odataServices"][0][@"password"], @"no secret in the project's settings");
  XCTAssertEqual([[[NSUserDefaults standardUserDefaults] arrayForKey:@"ODWServices"] count], (NSUInteger)0, @"not the user's");
  [[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
}

// A GET (a path from the service root) sent to a service, connected first;
// its answer.
- (ODWAnswer *)send:(NSString *)path to:(ODWService *)service
{
  [_services connect:service];
  [self waitFor:^{ return service.connected; }];
  NSString *root = service.connection.serviceRoot.absoluteString ?: @"";
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[root stringByAppendingString:path]]];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSUInteger before = _answers.count;
  [_services sendURLRequest:request title:[@"GET " stringByAppendingString:path] toService:service];
  [self waitFor:^{ return (BOOL)(self->_answers.count > before); }];
  return _answers.count > before ? _answers.lastObject : nil;
}

- (void)testARequestToTheBuiltInServiceIsAnswered
{
  ODWService *builtIn = [_services serviceNamed:@"Built-in Sample"];
  ODWAnswer *answer = [self send:@"Products?$top=3&$select=ProductName,UnitPrice" to:builtIn];
  XCTAssertNotNil(answer, @"no answer");
  XCTAssertTrue(builtIn.connected, @"connected for the request: %@", builtIn.failure);
  XCTAssertNil(answer.failure);
  XCTAssertEqual(answer.status, (NSInteger)200, @"%@", answer.text);
  XCTAssertEqual(answer.rows.count, (NSUInteger)3, @"%@", answer.text);
  XCTAssertTrue([answer.columns containsObject:@"ProductName"], @"%@", answer.columns);
  XCTAssertTrue([answer.text containsString:@"\"value\""]);
  XCTAssertTrue([builtIn.entitySetNames containsObject:@"Products"]);
  XCTAssertGreaterThan(_services.exchangeLog.entries.count, (NSUInteger)0, @"in the wire log");
  WorkbenchLogEntry *sent = _services.exchangeLog.entries.firstObject;
  XCTAssertTrue([sent.URL containsString:@"Products?"], @"%@", sent.URL);
  XCTAssertNotNil(WBTraceIDOfHeaders(sent.requestHeaders), @"its trace passed on");
  XCTAssertNotNil([[ODWServices traceRecorder] traceWithID:WBTraceIDOfHeaders(sent.requestHeaders)], @"its trace kept");

  // To a service not connected: answered why, not sent.
  NSUInteger exchanges = _services.exchangeLog.entries.count;
  ODWService *northwind = [_services serviceNamed:@"Northwind"];
  [_services sendURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.invalid/x"]] title:@"GET x" toService:northwind];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count > 1); }]);
  XCTAssertNotNil(_answers.lastObject.failure);
  XCTAssertEqual(_services.exchangeLog.entries.count, exchanges);
}

#pragma mark Templates

// A builder of a file, in a window, its request shown (its service
// connected, its panel there for a query).
- (ODWBuilderViewController *)builderOfFile:(NSDictionary *)file
{
  UDCodeDocument *document = [[UDCodeDocument alloc] initWithText:[ODWBuilderViewController textOfFile:file service:@"Built-in Sample"]
                                                          fileURL:nil languageMode:nil];
  ODWBuilderViewController *builder = [[ODWBuilderViewController alloc] initWithServices:_services document:document];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 420) styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered defer:YES];
  [window setReleasedWhenClosed:NO];
  [window.contentView addSubview:builder.view];
  [_windows addObject:window];
  [self waitFor:^{ return (BOOL)(builder.service.connected && (builder.kind != ODWBuilderQuery || builder.panel)); }];
  return builder;
}

// Each of an entity set's, and an operation's call: the builder's request
// as the template means it; the GETs answered.
- (void)testTemplatesAreTheBuildersRequests
{
  ODWService *builtIn = [self connectedBuiltIn];
  ODataSchema *schema = builtIn.connection.store.schema;
  XCTAssertNotNil(schema);
  NSDictionary *lines = @{ @(ODWTemplateGetAll): @"GET Products?", @(ODWTemplateGetByKey): @"GET Products(1)",
                           @(ODWTemplateCount): @"GET Products/$count", @(ODWTemplatePost): @"POST Products",
                           @(ODWTemplatePatch): @"PATCH Products(1)", @(ODWTemplateDelete): @"DELETE Products(1)" };
  for (NSNumber *kind in lines) {
    NSDictionary *file = ODWTemplateOfEntitySet(schema, @"Products", kind.integerValue);
    XCTAssertNotNil(file, @"%@", kind);
    ODWBuilderViewController *builder = [self builderOfFile:file];
    NSString *failure = nil;
    NSURLRequest *request = [builder URLRequestWithFailure:&failure];
    XCTAssertNotNil(request, @"%@: %@", file, failure);
    XCTAssertTrue([builder.requestLine.stringValue hasPrefix:lines[kind]], @"%@ for %@", builder.requestLine.stringValue, lines[kind]);
    XCTAssertEqualObjects([[lines[kind] componentsSeparatedByString:@" "] firstObject], request.HTTPMethod);
    if (request.HTTPBody) {
      id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL];
      XCTAssertTrue([body isKindOfClass:[NSDictionary class]], @"a JSON object: %@", file[@"body"]);
      if (kind.integerValue == ODWTemplatePatch) XCTAssertNil(body[@"ProductID"], @"no key in an update: %@", body);
      if (kind.integerValue == ODWTemplatePost) XCTAssertNotNil(body[@"ProductName"], @"%@", body);
      XCTAssertFalse(builder.bodySection.isHidden);
    }
    XCTAssertEqual(builder.panelScroll.isHidden, builder.kind != ODWBuilderQuery);
    XCTAssertEqual(builder.fieldsSection.isHidden, kind.integerValue == ODWTemplatePost, @"the key's fields: %@", lines[kind]);
    if ([request.HTTPMethod isEqualToString:@"GET"]) {
      [_answers removeAllObjects];
      [builder runFetch:nil];
      XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count > 0); }]);
      XCTAssertNil(_answers.lastObject.failure, @"%@", _answers.lastObject.text);
      XCTAssertEqual(_answers.lastObject.status, (NSInteger)200, @"%@: %@", _answers.lastObject.title, _answers.lastObject.text);
    }
  }
  // An operation's call: a function's GET, its parameters in the URL; an
  // action's POST, its parameters the body.
  for (NSString *name in [builtIn operationNames]) {
    ODWBuilderViewController *builder = [self builderOfFile:ODWTemplateOfOperation(schema, name)];
    NSURLRequest *request = [builder URLRequestWithFailure:NULL];
    BOOL action = schema.operationImports[name].isAction;
    XCTAssertEqualObjects(request.HTTPMethod, action ? @"POST" : @"GET", @"%@", name);
    XCTAssertTrue([builder.requestLine.stringValue containsString:name], @"%@", builder.requestLine.stringValue);
    XCTAssertTrue(builder.bodySection.isHidden, @"its parameters are fields");
  }
  // As curl: its method, URL, headers and body, quoted for a shell.
  NSURLRequest *patch = [[self builderOfFile:ODWTemplateOfEntitySet(schema, @"Products", ODWTemplatePatch)] URLRequestWithFailure:NULL];
  NSString *curl = ODWCurlOfRequest(patch);
  XCTAssertTrue([curl hasPrefix:@"curl -X PATCH 'http"], @"%@", curl);
  XCTAssertTrue([curl containsString:@"-H 'Content-Type: application/json'"], @"%@", curl);
  XCTAssertTrue([curl containsString:@"-H 'If-Match: *'"], @"%@", curl);
  XCTAssertTrue([curl containsString:@"--data-raw '{"], @"%@", curl);
  NSURLRequest *quoted = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://h/P('a')"]];
  XCTAssertEqualObjects(ODWCurlOfRequest(quoted), @"curl 'http://h/P('\\''a'\\'')'\n", @"a quote in a word");
  // A key as typed.
  XCTAssertEqualObjects(ODWKeyPath(schema, @"Products", @{ @"ProductID": @"7" }), @"Products(7)");
}

// The navigator's Insert Request, Insert Call: a new builder set up for
// the request.
- (void)testInsertRequestOpensABuilder
{
  ODWService *builtIn = [self connectedBuiltIn];
  ODWNavigatorViewController *navigator = [[ODWNavigatorViewController alloc] initWithServices:_services];
  XCTAssertNotNil(navigator.view);
  NSMenu *itemMenu = [navigator valueForKey:@"itemMenu"];
  XCTAssertEqual([itemMenu itemWithTitle:@"Insert Request"].submenu.numberOfItems, (NSInteger)7, @"six requests and a separator");
  XCTAssertNotNil([itemMenu itemWithTitle:@"Insert Call"]);
  XCTAssertNil([itemMenu itemWithTitle:@"New Request"], @"no text requests");
  XCTAssertNil([[navigator valueForKey:@"serviceMenu"] itemWithTitle:@"New Request Document"]);

  // The context menu of an entity set's row: Insert Request's submenu
  // whole, Insert Call not there; of an operation's, the other way about.
  NSOutlineView *outline = navigator.outlineView;
  for (NSInteger row = 0; row < outline.numberOfRows; row++) [outline expandItem:[outline itemAtRow:row]];
  NSInteger setRow = -1, operationRow = -1;
  for (NSInteger row = 0; row < outline.numberOfRows; row++) {
    NSString *title = [[outline itemAtRow:row] valueForKey:@"title"];
    if ([title isEqualToString:@"Products"]) setRow = row;
    if ([[builtIn operationNames] containsObject:title]) operationRow = row;
  }
  XCTAssertGreaterThanOrEqual(setRow, 0);
  XCTAssertGreaterThanOrEqual(operationRow, 0);
  [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)setRow] byExtendingSelection:NO];
  [navigator menuNeedsUpdate:outline.menu];
  XCTAssertNil([outline.menu itemWithTitle:@"Insert Call"]);
  [navigator menuNeedsUpdate:outline.menu];
  XCTAssertEqual([outline.menu itemWithTitle:@"Insert Request"].submenu.numberOfItems, (NSInteger)7, @"the menu made again");
  NSMenuItem *byKey = [[outline.menu itemWithTitle:@"Insert Request"].submenu itemWithTitle:@"GET by Key"];
  XCTAssertEqual(byKey.target, navigator);
  [navigator insertRequestOfItem:byKey];
  XCTAssertEqual(_workbench.opened.count, (NSUInteger)1);
  NSDictionary *file = [self fileOfText:[_workbench.opened.lastObject.textModel getValue]];
  XCTAssertEqualObjects(file[@"request"], @"query");
  XCTAssertEqualObjects(file[@"service"], @"Built-in Sample");
  XCTAssertEqualObjects(file[@"query"][@"entity"], @"Product");
  XCTAssertEqualObjects(file[@"key"][@"ProductID"], @"1");
  [navigator menuDidClose:outline.menu];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

  [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)operationRow] byExtendingSelection:NO];
  [navigator menuNeedsUpdate:outline.menu];
  XCTAssertNil([outline.menu itemWithTitle:@"Insert Request"]);
  NSMenuItem *call = [outline.menu itemWithTitle:@"Insert Call"];
  XCTAssertNotNil(call);
  [navigator insertRequestOfItem:call];
  XCTAssertEqual(_workbench.opened.count, (NSUInteger)2);
  file = [self fileOfText:[_workbench.opened.lastObject.textModel getValue]];
  XCTAssertEqualObjects(file[@"request"], @"call");
  XCTAssertEqualObjects(file[@"operation"], [[outline itemAtRow:operationRow] valueForKey:@"title"]);
  [navigator menuDidClose:outline.menu];
}

#pragma mark The builder

// The built-in service, connected (its model the builder's).
- (ODWService *)connectedBuiltIn
{
  ODWService *builtIn = [_services serviceNamed:@"Built-in Sample"];
  [_services connect:builtIn];
  [self waitFor:^{ return builtIn.connected; }];
  return builtIn;
}

- (NSDictionary *)fileOfText:(NSString *)text
{
  return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

- (NSDictionary *)queryOfText:(NSString *)text
{
  NSDictionary *file = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
  return file[@"query"];
}

// A query as a file keeps it, and back: all of it, not a preset's part.
- (void)testAQueryIsKeptWhole
{
  ODWService *builtIn = [self connectedBuiltIn];
  XCTAssertTrue(builtIn.connected, @"%@", builtIn.failure);
  WBQuery *query = [[WBQuery alloc] initWithModel:builtIn.connection.model builtIn:YES];
  query.entityName = @"Product";
  query.resultType = NSDictionaryResultType;
  query.predicateText = @"unitPrice > 10";
  query.limitText = @"5";
  query.skipText = @"2";
  query.pageSizeText = @"50";
  query.includesSubentities = NO;
  [query.sorts addObject:[@{ @"key": @"productName", @"descending": @YES } mutableCopy]];
  [query.select addObject:@"productName"];
  [query.prefetch addObject:@"category"];
  NSDictionary *kept = [query dictionary];
  WBQuery *again = [[WBQuery alloc] initWithModel:builtIn.connection.model builtIn:YES];
  [again takeDictionary:kept];
  XCTAssertEqualObjects([again dictionary], kept);
  XCTAssertEqualObjects(kept[@"type"], @"dictionary");
  XCTAssertEqualObjects(kept[@"skip"], @"2");
  XCTAssertEqualObjects(kept[@"subentities"], @NO);
  XCTAssertNil([[[WBQuery alloc] initWithModel:builtIn.connection.model builtIn:YES] dictionary][@"subentities"], @"a new query's left out");
}

// An .odataq document: the panel over its service, its query the text's;
// a change in the panel written into the text, the text changed read back;
// Execute's GET answered.
- (void)testTheBuilderIsItsDocumentsText
{
  NSString *text = [ODWBuilderViewController textOfQuery:@{ @"entity": @"Product", @"limit": @"3" } service:@"Built-in Sample"];
  UDCodeDocument *document = [[UDCodeDocument alloc] initWithText:text fileURL:nil languageMode:nil];
  ODWBuilderViewController *builder = [[ODWBuilderViewController alloc] initWithServices:_services document:document];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 420) styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered defer:YES];
  [window setReleasedWhenClosed:NO];
  [window.contentView addSubview:builder.view];
  XCTAssertNotNil(builder.servicePopup);
  XCTAssertNotNil(builder.connectButton);
  XCTAssertNotNil(builder.statusLabel);
  XCTAssertTrue([self waitFor:^{ return (BOOL)(builder.panel != nil); }], @"%@", builder.statusLabel.stringValue);
  XCTAssertEqualObjects(builder.service.name, @"Built-in Sample");
  XCTAssertEqualObjects(builder.servicePopup.titleOfSelectedItem, @"Built-in Sample");
  XCTAssertEqualObjects(builder.panel.entityPopup.titleOfSelectedItem, @"Product");
  XCTAssertEqualObjects(builder.panel.limitField.stringValue, @"3");
  XCTAssertTrue([builder.panel.translation containsString:@"Products?"], @"%@", builder.panel.translation);

  // The panel whole, at the top of the tab, its controls inside it; in a
  // tab narrower than it, as wide as it is (scrolled to).
  NSView *panelView = builder.panel.view;
  for (NSView *view in panelView.subviews) {
    XCTAssertTrue(NSContainsRect(panelView.bounds, view.frame), @"%@ at %@ is outside the panel's %@", view,
                  NSStringFromRect(view.frame), NSStringFromRect(panelView.bounds));
  }
  NSRect inTab = [builder.view convertRect:panelView.bounds fromView:panelView];
  NSRect shown = [builder.view convertRect:builder.panelScroll.bounds fromView:builder.panelScroll];
  XCTAssertEqualWithAccuracy(NSMaxY(inTab), NSMaxY(shown), 1, @"the panel at the top: %@ in %@", NSStringFromRect(inTab), NSStringFromRect(shown));
  XCTAssertFalse(builder.fieldsSection.isHidden, @"a product's key's fields");
  XCTAssertLessThanOrEqual(NSMaxY(shown), NSMinY([builder.view convertRect:builder.fieldsSection.bounds fromView:builder.fieldsSection]),
                           @"under the key's fields");
  CGFloat height = NSHeight(builder.view.frame);
  [builder.view setFrameSize:NSMakeSize(400, height)];
  XCTAssertEqualWithAccuracy(NSWidth(panelView.frame), 560, 0.5, @"not squeezed: WBQueryPanelStacked.xib's width");
  XCTAssertEqualWithAccuracy(NSMaxY([builder.view convertRect:panelView.bounds fromView:panelView]), NSMaxY(inTab), 1, @"still at the top");
  [builder.view setFrameSize:NSMakeSize(1100, height)];

  // The panel changed: the text written, as one edit.
  builder.panel.limitField.stringValue = @"2";
  [builder.panel controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:builder.panel.limitField]];
  XCTAssertTrue([self waitFor:^{ return [[self queryOfText:[document.textModel getValue]][@"limit"] isEqual:@"2"]; }],
                @"%@", [document.textModel getValue]);
  XCTAssertTrue(document.textModel.undoManager.canUndo);

  // The text changed otherwise: the panel reads it.
  UDTextModel *model = document.textModel;
  UDRange all = [model validateRange:(UDRange){1, 1, NSIntegerMax, NSIntegerMax}];
  [model applyEdits:@[ [[UDTextModelEdit alloc] initWithRange:all
                                                         text:[ODWBuilderViewController textOfQuery:@{ @"entity": @"Category", @"limit": @"4" }
                                                                                            service:@"Built-in Sample"]] ]];
  XCTAssertEqualObjects(builder.panel.entityPopup.titleOfSelectedItem, @"Category");
  XCTAssertEqualObjects(builder.panel.limitField.stringValue, @"4");

  // Execute: its GET, answered.
  [builder.executeButton performClick:nil];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count > 0); }]);
  ODWAnswer *answer = _answers.lastObject;
  XCTAssertNil(answer.failure);
  XCTAssertTrue([answer.title hasPrefix:@"GET Categories"], @"%@", answer.title);
  XCTAssertEqual(answer.rows.count, (NSUInteger)4, @"%@", answer.text);

  // A key given: the one's GET.
  XCTAssertTrue([builder.requestLine.stringValue hasPrefix:@"GET Categories?$top=4"], @"%@", builder.requestLine.stringValue);
  [builder tableView:builder.fieldsTable setObjectValue:@"2" forTableColumn:[builder.fieldsTable tableColumnWithIdentifier:@"value"] row:0];
  XCTAssertTrue([builder.requestLine.stringValue hasPrefix:@"GET Categories(2)"], @"%@", builder.requestLine.stringValue);
  XCTAssertFalse([builder.requestLine.stringValue containsString:@"$top"], @"one entity's: its $select and $expand only");
  XCTAssertTrue([self waitFor:^{ return (BOOL)([[self fileOfText:[document.textModel getValue]][@"key"] count] == 1); }],
                @"%@", [document.textModel getValue]);

  // Another kind: an update of the same entity set, its key kept, a body of
  // its properties.
  [builder.kindPopup selectItemWithTag:ODWBuilderUpdate];
  [builder kindChosen:builder.kindPopup];
  XCTAssertEqual(builder.kind, ODWBuilderUpdate);
  XCTAssertTrue(builder.panelScroll.isHidden);
  XCTAssertFalse(builder.bodySection.isHidden);
  XCTAssertEqualObjects(builder.targetPopup.titleOfSelectedItem, @"Categories");
  XCTAssertEqualObjects(builder.requestLine.stringValue, @"PATCH Categories(2)");
  XCTAssertTrue([builder.bodyView.string containsString:@"\"CategoryName\""], @"%@", builder.bodyView.string);
  XCTAssertTrue([self waitFor:^{ return [[self fileOfText:[document.textModel getValue]][@"request"] isEqual:@"update"]; }]);
  NSDictionary *file = [self fileOfText:[document.textModel getValue]];
  XCTAssertEqualObjects(file[@"entitySet"], @"Categories");
  XCTAssertEqualObjects(file[@"key"], @{ @"CategoryID": @"2" });
  // A body that is no JSON: no request, and why.
  builder.bodyView.string = @"{ nope";
  [builder textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:builder.bodyView]];
  XCTAssertEqualObjects(builder.requestLine.stringValue, @"The body is not JSON.");
  [window orderOut:nil];
}

#pragma mark The XIBs

- (void)testBothPanelLayoutsLoadConnected
{
  NSArray *outlets = @[ @"entityPopup", @"resultTypePopup", @"limitField", @"skipField", @"batchSizeField", @"subentitiesButton",
                        @"faultsButton", @"predicateView", @"timeField", @"sortTable", @"expandOutline", @"selectTable",
                        @"searchField", @"computeField", @"groupField", @"aggregateField", @"wireURLField", @"explainButton",
                        @"executeButton" ];
  for (NSNumber *stacked in @[ @NO, @YES ]) {
    WBQueryPanel *panel = [[WBQueryPanel alloc] initStacked:stacked.boolValue];
    NSView *view = panel.view;
    XCTAssertNotNil(view, @"stacked %@", stacked);
    for (NSString *outlet in outlets) {
      // The stacked one's host shows the GET, Explain and Execute.
      if (stacked.boolValue && [@[ @"wireURLField", @"explainButton", @"executeButton" ] containsObject:outlet]) continue;
      XCTAssertNotNil([panel valueForKey:outlet], @"%@, stacked %@", outlet, stacked);
    }
    if (!stacked.boolValue) XCTAssertEqualObjects(NSStringFromSelector(panel.executeButton.action), @"runFetch:");
    XCTAssertEqual(panel.sortTable.dataSource, (id)panel);
    XCTAssertEqual(panel.expandOutline.dataSource, (id)panel);
    XCTAssertEqual(panel.selectTable.dataSource, (id)panel);
    for (NSView *control in view.subviews) {
      XCTAssertTrue(NSContainsRect(view.bounds, control.frame), @"%@ outside, stacked %@", control, stacked);
    }
  }
}

- (void)testTheNavigatorLoadsWithItsMenus
{
  ODWNavigatorViewController *navigator = [[ODWNavigatorViewController alloc] initWithServices:_services];
  XCTAssertNotNil(navigator.view);
  XCTAssertNotNil(navigator.outlineView);
  XCTAssertNotNil(navigator.outlineView.menu, @"a context menu");
  XCTAssertEqual(navigator.outlineView.numberOfRows, (NSInteger)3, @"the three presets");
  for (NSString *outlet in @[ @"serviceMenu", @"itemMenu" ]) {
    XCTAssertGreaterThan([[[navigator valueForKey:outlet] itemArray] count], (NSUInteger)0, @"%@", outlet);
  }
  // ⌘↩ is UDCode's Editor > Run, which the extension answers: no Editor
  // menu item of its own takes it.
  ODWExtension *extension = [[ODWExtension alloc] init];
  XCTAssertTrue([extension respondsToSelector:@selector(workbench:canRunDocument:)]);
  XCTAssertTrue([extension respondsToSelector:@selector(workbench:runDocument:selection:all:)]);
  XCTAssertFalse([extension respondsToSelector:@selector(editorMenuItemsForWorkbench:)]);
  // The right-clicked row's kind's items.
  NSMenu *menu = navigator.outlineView.menu;
  [navigator menuNeedsUpdate:menu];
  XCTAssertEqual(menu.numberOfItems, (NSInteger)0, @"no row clicked: nothing");
}

- (void)testTheBottomPaneShowsAnAnswer
{
  ODWBottomViewController *bottom = [[ODWBottomViewController alloc] initWithServices:_services];
  XCTAssertNotNil(bottom.view);
  for (id outlet in @[ bottom.paneSwitch ?: [NSNull null], bottom.statusLabel ?: [NSNull null], bottom.rowsTable ?: [NSNull null],
                      bottom.jsonView ?: [NSNull null], bottom.logTable ?: [NSNull null], bottom.exchangeView ?: [NSNull null] ]) {
    XCTAssertNotEqual(outlet, (id)[NSNull null]);
  }
  XCTAssertEqual(bottom.paneSwitch.segmentCount, (NSInteger)3);
  [bottom showPane:ODWBottomTraces];
  XCTAssertEqual(bottom.pane, ODWBottomTraces);
  [self send:@"Categories" to:[_services serviceNamed:@"Built-in Sample"]];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(bottom.answer != nil); }]);
  XCTAssertEqual(bottom.pane, ODWBottomResults, @"an answer brings Results forward");
  XCTAssertEqual(bottom.rowsTable.numberOfRows, (NSInteger)bottom.answer.rows.count);
  XCTAssertGreaterThan(bottom.rowsTable.numberOfColumns, (NSInteger)0);
  XCTAssertTrue([bottom.statusLabel.stringValue hasPrefix:@"200 OK"], @"HTTP's phrase: %@", bottom.statusLabel.stringValue);
  for (NSTableColumn *column in bottom.rowsTable.tableColumns) {
    XCTAssertTrue(column.width >= 60 && column.width <= 320, @"%@ is %.0f wide", column.identifier, column.width);
  }
  XCTAssertTrue([bottom.jsonView.string containsString:@"value"]);

  // Another answer, of fewer columns, then more: the table as wide as its
  // columns each time (its rows drawn under all of them).
  for (NSString *text in @[ @"Categories?$select=CategoryName", @"Products" ]) {
    ODWAnswer *last = bottom.answer;
    [self send:text to:[_services serviceNamed:@"Built-in Sample"]];
    XCTAssertTrue([self waitFor:^{ return (BOOL)(bottom.answer != last); }]);
    NSInteger count = bottom.rowsTable.numberOfColumns;
    XCTAssertGreaterThan(count, (NSInteger)0, @"%@", text);
    XCTAssertGreaterThanOrEqual(NSWidth(bottom.rowsTable.frame), NSMaxX([bottom.rowsTable rectOfColumn:count - 1]), @"%@", text);
  }
}

- (void)testTheServiceSheetSaysWhatIsMissing
{
  ODWServiceSheet *sheet = [[ODWServiceSheet alloc] initWithService:nil inProject:NO];
  XCTAssertNotNil(sheet.sheet);
  XCTAssertNotNil(sheet.nameField);
  XCTAssertNotNil(sheet.rootField);
  XCTAssertFalse(sheet.projectCheckbox.isEnabled, @"no folder: the user's");
  XCTAssertNil([sheet typedService]);
  XCTAssertTrue(sheet.problemLabel.stringValue.length > 0);
  sheet.nameField.stringValue = @"Orders";
  sheet.rootField.stringValue = @"not a url";
  XCTAssertNil([sheet typedService]);
  sheet.rootField.stringValue = @"https://example.org/odata/";
  ODWService *typed = [sheet typedService];
  XCTAssertEqualObjects(typed.name, @"Orders");
  XCTAssertFalse(typed.inProject);
}

@end
