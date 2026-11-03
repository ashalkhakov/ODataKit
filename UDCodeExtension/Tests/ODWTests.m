// UDCode's OData extension against UDCode's own document and project (its
// SDK) and the Workbench's built-in service, in this process (no network):
// requests read from text as VS Code's REST Client writes them, sent and
// answered; services kept where they say; the XIBs loaded and connected.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#import <XCTest/XCTest.h>
#import <UDCodeKit/UDCodeKit.h>
#import "ODWRequests.h"
#import "ODWServices.h"
#import "ODWNavigatorViewController.h"
#import "ODWBottomViewController.h"
#import "ODWServiceSheet.h"
#import "ODWExtension.h"
#import "ODWBuilderViewController.h"
#import "WBQueryPanel.h"
#import <UDPieceTable/UDTextModel.h>

// The window's side, as much of it as the services ask of: its project (a
// folder of the test's own, or none) and its window.
@interface ODWTestWorkbench : NSObject
@property (nonatomic, strong, nullable) UDProject *project;
@property (nonatomic, strong, nullable) NSWindow *window;
@property (nonatomic, strong, nullable) UDCodeDocument *selectedDocument;
@property (nonatomic, strong, nullable) id selectedEditor;
@property (nonatomic, strong) NSMutableArray *shownInBottomArea;
@end

@implementation ODWTestWorkbench
- (instancetype)init
{
  if ((self = [super init])) _shownInBottomArea = [NSMutableArray array];
  return self;
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
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(answerCame:) name:ODWAnswerNotification object:_services];
}

- (void)tearDown
{
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

#pragma mark Requests as text

- (void)testRequestsAreReadAsRESTClientWritesThem
{
  NSString *text = @"# Northwind\n"
                   @"GET Products?$filter=UnitPrice gt 20\n"
                   @"  &$expand=Category&$top=10\n"
                   @"\n"
                   @"### Patch one\n"
                   @"PATCH Products(1) HTTP/1.1\n"
                   @"Content-Type: application/json\n"
                   @"If-Match: *\n"
                   @"\n"
                   @"{ \"UnitPrice\": 19.5 }\n"
                   @"\n"
                   @"###\n"
                   @"Customers('ALFKI')/Orders\n";
  NSArray<ODWRequest *> *requests = ODWRequestsOfText(text);
  XCTAssertEqual(requests.count, (NSUInteger)3);
  ODWRequest *get = requests[0], *patch = requests[1], *bare = requests[2];
  XCTAssertEqualObjects(get.method, @"GET");
  XCTAssertEqualObjects(get.target, @"Products?$filter=UnitPrice gt 20&$expand=Category&$top=10", @"its query line joined");
  XCTAssertEqual(get.line, (NSUInteger)2);
  XCTAssertNil(get.body);
  XCTAssertEqualObjects(patch.method, @"PATCH");
  XCTAssertEqualObjects(patch.target, @"Products(1)", @"HTTP/1.1 left out");
  XCTAssertEqualObjects(patch.title, @"Patch one", @"its separator's name");
  XCTAssertEqual(patch.headers.count, (NSUInteger)2);
  XCTAssertEqualObjects(patch.body, @"{ \"UnitPrice\": 19.5 }");
  XCTAssertEqualObjects(bare.method, @"GET", @"no method: GET");
  XCTAssertEqualObjects(bare.title, @"GET Customers('ALFKI')/Orders");

  // The caret's request, and the last one before a caret between them.
  XCTAssertEqual(ODWRequestAt(text, [text rangeOfString:@"Content-Type"].location).line, patch.line);
  XCTAssertEqual(ODWRequestAt(text, text.length).line, bare.line);
  XCTAssertNil(ODWRequestAt(@"# only a comment\n", 3));

  // Its URL: from the service root, the filter's spaces encoded.
  NSString *why = nil;
  NSURLRequest *request = [get URLRequestWithServiceRoot:[NSURL URLWithString:@"https://example.org/odata"] error:&why];
  XCTAssertEqualObjects(request.URL.absoluteString,
                        @"https://example.org/odata/Products?$filter=UnitPrice%20gt%2020&$expand=Category&$top=10", @"%@", why);
  NSURLRequest *patched = [patch URLRequestWithServiceRoot:[NSURL URLWithString:@"https://example.org/odata/"] error:NULL];
  XCTAssertEqualObjects(patched.HTTPMethod, @"PATCH");
  XCTAssertEqualObjects([patched valueForHTTPHeaderField:@"If-Match"], @"*");
  XCTAssertEqualObjects([[NSString alloc] initWithData:patched.HTTPBody encoding:NSUTF8StringEncoding], @"{ \"UnitPrice\": 19.5 }");
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

// The built-in service, in this process: connected, a request sent as
// written, its rows read; the exchange in the wire log, its spans in Traces.
- (void)testARequestToTheBuiltInServiceIsAnswered
{
  ODWService *builtIn = [_services serviceNamed:@"Built-in Sample"];
  NSString *text = @"GET Products?$top=3&$select=ProductName,UnitPrice\n";
  ODWRequest *request = ODWRequestsOfText(text).firstObject;
  [_services sendRequest:request toService:builtIn];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count > 0); }], @"no answer");
  XCTAssertTrue(builtIn.connected, @"connected for the request: %@", builtIn.failure);
  ODWAnswer *answer = _answers.lastObject;
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

  // A request that is no URL is answered why, not sent.
  NSUInteger exchanges = _services.exchangeLog.entries.count;
  [_services sendRequest:ODWRequestsOfText(@"GET http://\n").firstObject toService:builtIn];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count > 1); }]);
  XCTAssertNotNil(_answers.lastObject.failure);
  XCTAssertEqual(_services.exchangeLog.entries.count, exchanges);
}

// UDCode's Run: the request at the selection, sent to the document's
// service.
- (void)testRunSendsTheRequestAtTheCaret
{
  UDCodeDocument *document = [[UDCodeDocument alloc] initWithText:@"GET Categories\n\n###\nGET Products?$top=2\n" fileURL:nil languageMode:nil];
  ODWService *builtIn = [_services serviceNamed:@"Built-in Sample"];
  [_services setService:builtIn ofDocument:document];
  XCTAssertEqual([_services serviceOfDocument:document], builtIn);
  NSString *text = [document.textModel getValue];
  [_services sendRequestsOfDocument:document selection:NSMakeRange([text rangeOfString:@"Products"].location, 0) all:NO];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count > 0); }]);
  XCTAssertEqualObjects(_answers.lastObject.title, @"GET Products?$top=2", @"the request the caret is in");
  XCTAssertEqual(_answers.lastObject.rows.count, (NSUInteger)2, @"%@", _answers.lastObject.text);
  // Run All: each, in order.
  [_answers removeAllObjects];
  [_services sendRequestsOfDocument:document selection:NSMakeRange(0, 0) all:YES];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count == 2); }]);
  XCTAssertEqualObjects([_answers valueForKey:@"title"], (@[ @"GET Categories", @"GET Products?$top=2" ]));
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
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 360) styleMask:NSWindowStyleMaskTitled
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
  XCTAssertEqualWithAccuracy(NSMaxY(inTab), NSMinY(builder.servicePopup.frame) - 4, 12, @"the panel at the top: %@", NSStringFromRect(inTab));
  CGFloat height = NSHeight(builder.view.frame);
  [builder.view setFrameSize:NSMakeSize(600, height)];
  XCTAssertEqualWithAccuracy(NSWidth(panelView.frame), 1084, 0.5, @"not squeezed: WBQueryPanel.xib's width");
  XCTAssertEqualWithAccuracy(NSMaxY([builder.view convertRect:panelView.bounds fromView:panelView]), NSMaxY(inTab), 1, @"still at the top");
  [builder.view setFrameSize:NSMakeSize(1100, height)];
  // Execute is the tab's, whatever is focused.
  XCTAssertEqual(builder.panel.executeButton.target, builder);

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
  [builder.panel.executeButton performClick:nil];
  XCTAssertTrue([self waitFor:^{ return (BOOL)(self->_answers.count > 0); }]);
  ODWAnswer *answer = _answers.lastObject;
  XCTAssertNil(answer.failure);
  XCTAssertTrue([answer.title hasPrefix:@"GET Categories"], @"%@", answer.title);
  XCTAssertEqual(answer.rows.count, (NSUInteger)4, @"%@", answer.text);
  [window orderOut:nil];
}

#pragma mark The XIBs

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
  [_services sendRequest:ODWRequestsOfText(@"GET Categories\n").firstObject toService:[_services serviceNamed:@"Built-in Sample"]];
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
  for (NSString *text in @[ @"GET Categories?$select=Name\n", @"GET Products\n" ]) {
    ODWAnswer *last = bottom.answer;
    [_services sendRequest:ODWRequestsOfText(text).firstObject toService:[_services serviceNamed:@"Built-in Sample"]];
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
