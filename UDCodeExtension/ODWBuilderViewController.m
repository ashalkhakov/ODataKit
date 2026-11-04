// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWBuilderViewController.h"
#import "ODWServices.h"
#import "ODWTemplates.h"
#import "WBQueryPanel.h"
#import <ODataKit/ODataSchema.h>
#import <UDPieceTable/UDTextModel.h>

// The tab's view (ODWBuilder.xib): its controller after it in the chain,
// wherever UDCode puts it, so what is sent to the first responder reaches
// the tab. AppKit puts a view controller there by itself; gnustep-gui does
// not; and a view put in another is given its superview as the next
// responder again.
@interface ODWBuilderView : NSView
@property (nonatomic, weak) IBOutlet NSResponder *controller;
@end

@implementation ODWBuilderView

- (void)setNextResponder:(NSResponder *)responder
{
  NSResponder *controller = self.controller;
  if (controller == nil || responder == controller) {
    [super setNextResponder:responder];
    return;
  }
  [controller setNextResponder:responder];
  [super setNextResponder:controller];
}

@end

// The panel's host, the scroll view's document: flipped, so the panel is
// put at its top and the scroll view starts there.
@interface ODWPanelHostView : NSView
@end

@implementation ODWPanelHostView

- (BOOL)isFlipped
{
  return YES;
}

@end

// The file's names of the kinds, in ODWBuilderKind's order.
static NSArray<NSString *> *ODWKindNames(void)
{
  return @[ @"query", @"create", @"update", @"delete", @"call" ];
}

// A file's dictionary of texts: its values as text.
static NSMutableDictionary<NSString *, NSString *> *ODWTexts(id dictionary)
{
  NSMutableDictionary *texts = [NSMutableDictionary dictionary];
  if (![dictionary isKindOfClass:[NSDictionary class]]) return texts;
  [dictionary enumerateKeysAndObjectsUsingBlock:^(id name, id value, BOOL *stop) {
    if (![name isKindOfClass:[NSString class]]) return;
    texts[name] = [value isKindOfClass:[NSString class]] ? value : [value description];
  }];
  return texts;
}

@interface ODWBuilderViewController ()
@property (nonatomic, readwrite, weak) IBOutlet NSPopUpButton *servicePopup;
@property (nonatomic, readwrite, weak) IBOutlet NSButton *connectButton;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *statusLabel;
@property (nonatomic, readwrite, weak) IBOutlet NSPopUpButton *kindPopup;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *targetLabel;
@property (nonatomic, readwrite, weak) IBOutlet NSPopUpButton *targetPopup;
@property (nonatomic, weak) IBOutlet NSView *contentHost;
@property (nonatomic, readwrite, weak) IBOutlet NSView *fieldsSection;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *fieldsLabel;
@property (nonatomic, readwrite, weak) IBOutlet NSTableView *fieldsTable;
@property (nonatomic, readwrite, weak) IBOutlet NSView *bodySection;
@property (nonatomic, readwrite, strong) IBOutlet NSTextView *bodyView;
@property (nonatomic, readwrite, weak) IBOutlet NSScrollView *panelScroll;
@property (nonatomic, weak) IBOutlet NSView *panelHost;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *requestLine;
@property (nonatomic, readwrite, weak) IBOutlet NSButton *executeButton;
@property (nonatomic, readwrite, nullable) ODWService *service;
@property (nonatomic, readwrite) ODWBuilderKind kind;
@property (nonatomic, readwrite, nullable) WBQueryPanel *panel;
@end

@implementation ODWBuilderViewController {
  // The request as the text has it, for the controls once they are there.
  NSDictionary *_query;
  NSString *_entitySet;
  NSString *_operation;
  NSMutableDictionary<NSString *, NSString *> *_key;
  NSMutableDictionary<NSString *, NSString *> *_parameters;
  NSString *_body;
  // The fields shown: the key's, or the call's parameters.
  NSArray<NSString *> *_fieldNames;
  // The text being written (what the text model tells then is our own).
  BOOL _writing;
  // The connection the panel's query is of.
  WBConnection *_panelConnection;
  // The panel's own size (its XIB's): the least it is shown at.
  NSSize _panelSize;
}

+ (NSString *)textOfFile:(NSDictionary *)file service:(NSString *)service
{
  NSMutableDictionary *whole = [file mutableCopy] ?: [NSMutableDictionary dictionary];
  if (service.length) whole[@"service"] = service;
  if (!whole[@"request"]) whole[@"request"] = @"query";
  if ([whole[@"request"] isEqual:@"query"] && !whole[@"query"]) whole[@"query"] = @{};
  NSData *data = [NSJSONSerialization dataWithJSONObject:whole options:NSJSONWritingPrettyPrinted error:NULL];
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
  text = [text stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
  return [text hasSuffix:@"\n"] ? text : [text stringByAppendingString:@"\n"];
}

+ (NSString *)textOfQuery:(NSDictionary *)query service:(NSString *)service
{
  return [self textOfFile:@{ @"request": @"query", @"query": query ?: @{} } service:service];
}

- (instancetype)initWithServices:(ODWServices *)services document:(UDCodeDocument *)document
{
  self = [super initWithNibName:@"ODWBuilder" bundle:[NSBundle bundleForClass:[ODWBuilderViewController class]]];
  if (!self) return nil;
  _services = services;
  _document = document;
  self.title = @"Request Builder";
  if (services.executesNextBuilder) {
    _executesWhenShown = YES;
    services.executesNextBuilder = NO;
  }
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(textModelDidChange:) name:UDTextModelDidChangeNotification object:document.textModel];
  [center addObserver:self selector:@selector(servicesDidChange:) name:ODWServicesDidChangeNotification object:services];
  [self read];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

// gnustep-gui has no -viewDidLoad: the controls filled as the view loads.
- (void)loadView
{
  [super loadView];
  NSClipView *clip = _panelScroll.contentView;
  clip.postsFrameChangedNotifications = YES;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clipDidResize:)
                                               name:NSViewFrameDidChangeNotification object:clip];
  _bodyView.font = [NSFont userFixedPitchFontOfSize:0];
#ifndef GNUSTEP
  // JSON's quotes as typed (gnustep-gui has no smart quotes to turn off).
  _bodyView.automaticQuoteSubstitutionEnabled = NO;
#endif
  [self showReading:YES];
}

- (ODataSchema *)schema
{
  return _service.connection.store.schema;
}

#pragma mark Reading

// The text's service and request; an empty text, a new query of the
// document's service (the navigator's choice).
- (void)read
{
  NSData *data = [[_document.textModel getValue] dataUsingEncoding:NSUTF8StringEncoding];
  id file = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  NSDictionary *dictionary = [file isKindOfClass:[NSDictionary class]] ? file : @{};
  NSString *name = [dictionary[@"service"] isKindOfClass:[NSString class]] ? dictionary[@"service"] : nil;
  ODWServices *services = _services;
  _service = (name ? [services serviceNamed:name] : nil) ?: [services serviceOfDocument:_document];
  if (_service) [services setService:_service ofDocument:_document];
  NSUInteger kind = [ODWKindNames() indexOfObject:dictionary[@"request"] ?: @"query"];
  _kind = kind == NSNotFound ? ODWBuilderQuery : (ODWBuilderKind)kind;
  _query = [dictionary[@"query"] isKindOfClass:[NSDictionary class]] ? dictionary[@"query"] : @{};
  _entitySet = [dictionary[@"entitySet"] isKindOfClass:[NSString class]] ? dictionary[@"entitySet"] : nil;
  _operation = [dictionary[@"operation"] isKindOfClass:[NSString class]] ? dictionary[@"operation"] : nil;
  _key = ODWTexts(dictionary[@"key"]);
  _parameters = ODWTexts(dictionary[@"parameters"]);
  _body = [dictionary[@"body"] isKindOfClass:[NSString class]] ? dictionary[@"body"] : @"";
  [self showReading:YES];
}

- (void)textModelDidChange:(NSNotification *)note
{
  if (_writing) return;
  [self read];
}

- (void)servicesDidChange:(NSNotification *)note
{
  if (self.isViewLoaded) [self showReading:NO];
}

#pragma mark Showing

// The services to choose from; the request, once the service is connected
// (connected now when it is not); or what is wanted. What is shown is the
// text's when the text was just read; otherwise left as it is being
// edited.
- (void)showReading:(BOOL)reading
{
  if (!self.isViewLoaded) return;
  ODWServices *services = _services;
  [_servicePopup removeAllItems];
  for (ODWService *service in services.services) [_servicePopup addItemWithTitle:service.name];
  if (_service) [_servicePopup selectItemWithTitle:_service.name];
  else [_servicePopup selectItemAtIndex:-1];
  _connectButton.enabled = _service && !_service.connected && !_service.connecting;
  BOOL connected = _service.connected;
  [_contentHost setHidden:!connected];
  [_kindPopup setEnabled:connected];
  [_executeButton setEnabled:connected];
  if (!_service) {
    _statusLabel.stringValue = @"Choose the service to send the request to.";
    [self removePanel];
    [self showRequestLine];
    return;
  }
  if (!connected) {
    _statusLabel.stringValue = _service.connecting ? [NSString stringWithFormat:@"Connecting to %@ …", _service.name]
                             : _service.failure ? [NSString stringWithFormat:@"Not connected: %@", _service.failure]
                                                : [NSString stringWithFormat:@"Connect to %@ to build the request.", _service.name];
    [self removePanel];
    [self showRequestLine];
    if (!_service.connecting && !_service.failure) [services connect:_service];
    return;
  }
  _statusLabel.stringValue = [_service.connection summary];
  [self showRequestReading:reading];
  if (_executesWhenShown) {
    _executesWhenShown = NO;
    [self runFetch:nil];
  }
}

// The kind's controls: what it is of, its fields, the panel or the body.
- (void)showRequestReading:(BOOL)reading
{
  [_kindPopup selectItemWithTag:_kind];
  BOOL ofSet = _kind == ODWBuilderCreate || _kind == ODWBuilderUpdate || _kind == ODWBuilderDelete, call = _kind == ODWBuilderCall;
  [_targetLabel setHidden:!(ofSet || call)];
  [_targetPopup setHidden:!(ofSet || call)];
  if (ofSet || call) {
    NSArray *names = call ? [_service operationNames] : [_service entitySetNames];
    _targetLabel.stringValue = call ? @"Operation:" : @"Entity set:";
    [_targetPopup removeAllItems];
    [_targetPopup addItemsWithTitles:names];
    NSString *chosen = call ? _operation : _entitySet;
    if (![names containsObject:chosen ?: @""]) chosen = names.firstObject;
    if (call) _operation = chosen;
    else _entitySet = chosen;
    if (chosen) [_targetPopup selectItemWithTitle:chosen];
  }
  if (_kind == ODWBuilderQuery) [self showPanelReading:reading];
  if (reading || !_bodyView.string.length) _bodyView.string = _body ?: @"";
  [self showFields];
}

// The fields of the kind: a query's key (of the panel's entity's set), an
// update's or deletion's, a call's parameters.
- (void)showFields
{
  ODataSchema *schema = [self schema];
  NSString *set = _kind == ODWBuilderQuery ? [self entitySetOfQuery] : _entitySet;
  switch (_kind) {
  case ODWBuilderQuery:
    _fieldNames = set ? ODWKeyOfEntitySet(schema, set) : @[];
    _fieldsLabel.stringValue = @"Key: of the one to get (left empty, all of them)";
    break;
  case ODWBuilderUpdate:
  case ODWBuilderDelete:
    _fieldNames = set ? ODWKeyOfEntitySet(schema, set) : @[];
    _fieldsLabel.stringValue = _kind == ODWBuilderUpdate ? @"Key: of the one to update" : @"Key: of the one to delete";
    break;
  case ODWBuilderCall:
    _fieldNames = _operation ? ODWParametersOfOperation(schema, _operation) : @[];
    _fieldsLabel.stringValue = ODWOperationIsAction(schema, _operation ?: @"") ? @"Parameters (as JSON; a string as it is)"
                                                                               : @"Parameters (as in a URL; a string as it is)";
    break;
  case ODWBuilderCreate:
    _fieldNames = @[];
    break;
  }
  [_fieldsTable reloadData];
  [self layoutSections];
  [self showRequestLine];
}

// The entity set of the panel's entity (a query's).
- (NSString *)entitySetOfQuery
{
  NSString *entity = [_panel currentQuery].entityName ?: _query[@"entity"];
  return entity ? ODWEntitySetOfEntity([self schema], entity) : nil;
}

// The fields at the top of the content (when there are any), and under
// them what fills it: the panel (a query), the body (one created or
// updated), or nothing.
- (void)layoutSections
{
  NSRect bounds = _contentHost.bounds;
  BOOL fields = _fieldNames.count > 0;
  CGFloat top = NSHeight(bounds);
  [_fieldsSection setHidden:!fields];
  if (fields) {
    CGFloat height = NSHeight(_fieldsSection.frame);
    _fieldsSection.frame = NSMakeRect(0, top - height, NSWidth(bounds), height);
    top -= height + 4;
  }
  BOOL query = _kind == ODWBuilderQuery, body = _kind == ODWBuilderCreate || _kind == ODWBuilderUpdate;
  [_panelScroll setHidden:!query];
  [_bodySection setHidden:!body];
  NSView *filler = query ? _panelScroll : body ? _bodySection : nil;
  filler.frame = NSMakeRect(0, 0, NSWidth(bounds), MAX(top, 0));
  if (query) [self layoutPanel];
}

- (void)removePanel
{
  [_panel.view removeFromSuperview];
  _panel = nil;
  _panelConnection = nil;
}

// The panel over the service's model, its query the text's.
- (void)showPanelReading:(BOOL)reading
{
  WBConnection *connection = _service.connection;
  if (!_panel || _panelConnection != connection) {
    reading = YES;
    [self removePanel];
    _panel = [[WBQueryPanel alloc] initStacked:YES];
    NSView *view = _panel.view;
    _panelSize = view.frame.size;
    view.autoresizingMask = NSViewNotSizable;
    [_panelHost addSubview:view];
    [self layoutPanel];
    _panel.connection = connection;
    _panelConnection = connection;
    __weak ODWBuilderViewController *weak = self;
    _panel.queryDidChange = ^{
      [weak queryChanged];
    };
  }
  if (!reading) return;
  WBQuery *query = [[WBQuery alloc] initWithModel:connection.model builtIn:_service.kind == ODWServiceBuiltIn];
  query.configurationName = connection.store.configurationName;
  [query takeDictionary:_query];
  if (!query.entityName.length) query.entityName = [query entityNames].firstObject;
  _panel.query = query;
  // What the panel shows of the query but leaves as it found it.
  _panel.batchSizeField.stringValue = query.pageSizeText ?: @"";
  _panel.subentitiesButton.state = query.includesSubentities ? NSControlStateValueOn : NSControlStateValueOff;
  _panel.faultsButton.state = query.returnsObjectsAsFaults ? NSControlStateValueOn : NSControlStateValueOff;
}

// The panel's query changed: its key's fields may be another entity's.
- (void)queryChanged
{
  NSArray *before = _fieldNames;
  [self showFields];
  if (![before isEqual:_fieldNames]) [_key removeAllObjects];
  [self scheduleWrite];
}

// The panel as wide as the tab, its own height, at the top; no smaller than
// its own size (the scroll view scrolls then).
- (void)layoutPanel
{
  NSView *view = _panel.view;
  if (!view) return;
  NSSize shown = _panelScroll.contentSize;
  NSSize size = NSMakeSize(MAX(shown.width, _panelSize.width), MAX(shown.height, _panelSize.height));
  [_panelHost setFrameSize:size];
  view.frame = NSMakeRect(0, 0, size.width, _panelSize.height);
  // Its top in view again (a scroller come or gone moves it), across as it
  // was.
  NSClipView *clip = _panelScroll.contentView;
  CGFloat across = MIN(MAX(clip.bounds.origin.x, 0), MAX(size.width - NSWidth(clip.bounds), 0));
  [clip scrollToPoint:NSMakePoint(across, 0)];
  [_panelScroll reflectScrolledClipView:clip];
}

- (void)clipDidResize:(NSNotification *)note
{
  [self layoutPanel];
}

// The request as it is sent (method and URL from the service root), or why
// it cannot be.
- (void)showRequestLine
{
  NSString *failure = nil;
  NSURLRequest *request = _service.connected ? [self URLRequestWithFailure:&failure] : nil;
  _requestLine.stringValue = request ? [self titleOfRequest:request] : (failure ?: @"");
}

- (NSString *)titleOfRequest:(NSURLRequest *)request
{
  NSString *url = request.URL.absoluteString ?: @"";
  NSString *root = [self rootText];
  NSString *shown = [url hasPrefix:root] ? [url substringFromIndex:root.length] : url;
  return [NSString stringWithFormat:@"%@ %@", request.HTTPMethod ?: @"GET", [shown stringByRemovingPercentEncoding] ?: shown];
}

#pragma mark The request

// The service root, ending in a slash.
- (NSString *)rootText
{
  NSString *root = _service.connection.serviceRoot.absoluteString ?: _service.root.absoluteString ?: @"";
  return [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
}

- (NSURL *)URLOfPath:(NSString *)path query:(NSString *)query
{
  NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: path;
  NSString *text = [[self rootText] stringByAppendingString:encoded];
  if (query.length) text = [NSString stringWithFormat:@"%@?%@", text, query];
  return [NSURL URLWithString:text];
}

// The panel's GET's options that a GET of one entity takes: $select and
// $expand.
- (NSString *)entityOptionsOf:(NSURL *)url
{
  NSMutableArray *kept = [NSMutableArray array];
  for (NSString *option in [url.query componentsSeparatedByString:@"&"] ?: @[]) {
    NSString *name = [[[option componentsSeparatedByString:@"="] firstObject] stringByRemovingPercentEncoding] ?: @"";
    if ([name isEqualToString:@"$select"] || [name isEqualToString:@"$expand"]) [kept addObject:option];
  }
  return [kept componentsJoinedByString:@"&"];
}

- (NSURLRequest *)URLRequestWithFailure:(NSString **)failure
{
  NSString *why = nil;
  NSURLRequest *request = [self makeRequestFailure:&why];
  if (!request && failure) *failure = why;
  return request;
}

- (NSURLRequest *)makeRequestFailure:(NSString **)why
{
  ODataSchema *schema = [self schema];
  if (!schema) {
    *why = @"Connect to the service first.";
    return nil;
  }
  NSMutableURLRequest *request = nil;
  NSString *body = nil;
  NSDictionary *key = [_key copy];
  BOOL keyGiven = NO, keyWhole = YES;
  for (NSString *name in _fieldNames) {
    BOOL given = [[key[name] ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] > 0;
    keyGiven = keyGiven || given;
    keyWhole = keyWhole && given;
  }
  switch (_kind) {
  case ODWBuilderQuery: {
    NSString *translation = [_panel translation] ?: @"";
    NSURL *url = [NSURL URLWithString:translation];
    if (!url.scheme.length) {
      *why = translation.length ? translation : @"The query makes no request yet.";
      return nil;
    }
    if (keyGiven) {
      NSString *set = [self entitySetOfQuery];
      NSString *path = keyWhole && set ? ODWKeyPath(schema, set, key) : nil;
      if (!path) {
        *why = @"Give each of the key's values, or none.";
        return nil;
      }
      url = [self URLOfPath:path query:[self entityOptionsOf:url]];
    }
    request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    break;
  }
  case ODWBuilderCreate:
    if (!_entitySet) {
      *why = @"Choose the entity set.";
      return nil;
    }
    request = [NSMutableURLRequest requestWithURL:[self URLOfPath:_entitySet query:nil]];
    request.HTTPMethod = @"POST";
    body = _body;
    break;
  case ODWBuilderUpdate:
  case ODWBuilderDelete: {
    NSString *path = _entitySet && keyWhole ? ODWKeyPath(schema, _entitySet, key) : nil;
    if (!path) {
      *why = _entitySet ? @"Give each of the key's values." : @"Choose the entity set.";
      return nil;
    }
    request = [NSMutableURLRequest requestWithURL:[self URLOfPath:path query:nil]];
    request.HTTPMethod = _kind == ODWBuilderUpdate ? @"PATCH" : @"DELETE";
    // Whatever version it is at: the builder's user means this one.
    [request setValue:@"*" forHTTPHeaderField:@"If-Match"];
    if (_kind == ODWBuilderUpdate) body = _body;
    break;
  }
  case ODWBuilderCall:
    if (!_operation) {
      *why = @"Choose the function or action.";
      return nil;
    }
    if (ODWOperationIsAction(schema, _operation)) {
      request = [NSMutableURLRequest requestWithURL:[self URLOfPath:_operation query:nil]];
      request.HTTPMethod = @"POST";
      body = ODWActionBody(schema, _operation, _parameters);
    } else {
      request = [NSMutableURLRequest requestWithURL:[self URLOfPath:ODWFunctionPath(schema, _operation, _parameters) query:nil]];
      request.HTTPMethod = @"GET";
    }
    break;
  }
  if (!request.URL) {
    *why = @"Its URL is no URL.";
    return nil;
  }
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  if (body) {
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (![NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]) {
      *why = @"The body is not JSON.";
      return nil;
    }
    request.HTTPBody = data;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  return request;
}

#pragma mark Writing

- (void)scheduleWrite
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(write) object:nil];
  [self performSelector:@selector(write) withObject:nil afterDelay:0];
  [self showRequestLine];
}

// The file: the kind, and what it asks.
- (NSDictionary *)file
{
  NSMutableDictionary *file = [NSMutableDictionary dictionaryWithObject:ODWKindNames()[(NSUInteger)_kind] forKey:@"request"];
  BOOL keyGiven = NO;
  for (NSString *value in _key.allValues) keyGiven = keyGiven || value.length > 0;
  switch (_kind) {
  case ODWBuilderQuery: {
    WBQuery *query = [_panel currentQuery];
    file[@"query"] = query ? [query dictionary] : (_query ?: @{});
    if (keyGiven) file[@"key"] = [_key copy];
    break;
  }
  case ODWBuilderCreate:
  case ODWBuilderUpdate:
  case ODWBuilderDelete:
    if (_entitySet) file[@"entitySet"] = _entitySet;
    if (_kind != ODWBuilderCreate) file[@"key"] = [_key copy];
    if (_kind != ODWBuilderDelete) file[@"body"] = _body ?: @"";
    break;
  case ODWBuilderCall:
    if (_operation) file[@"operation"] = _operation;
    file[@"parameters"] = [_parameters copy];
    break;
  }
  return file;
}

// The request, as the controls say it, written as the text: one edit, so
// undone as one.
- (void)write
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(write) object:nil];
  NSDictionary *file = [self file];
  NSString *text = [ODWBuilderViewController textOfFile:file service:_service.name];
  UDTextModel *model = _document.textModel;
  if ([text isEqualToString:[model getValue]]) return;
  if (file[@"query"]) _query = file[@"query"];
  UDRange all = [model validateRange:(UDRange){1, 1, NSIntegerMax, NSIntegerMax}];
  _writing = YES;
  [model applyEdits:@[ [[UDTextModelEdit alloc] initWithRange:all text:text] ]];
  _writing = NO;
}

#pragma mark Fields and the body

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  return (NSInteger)_fieldNames.count;
}

- (NSMutableDictionary *)fieldValues
{
  return _kind == ODWBuilderCall ? _parameters : _key;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (row < 0 || row >= (NSInteger)_fieldNames.count) return nil;
  NSString *name = _fieldNames[(NSUInteger)row];
  return [column.identifier isEqualToString:@"name"] ? name : ([self fieldValues][name] ?: @"");
}

- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (row < 0 || row >= (NSInteger)_fieldNames.count || ![column.identifier isEqualToString:@"value"]) return;
  [self fieldValues][_fieldNames[(NSUInteger)row]] = [value description] ?: @"";
  [self scheduleWrite];
}

- (void)textDidChange:(NSNotification *)note
{
  if (note.object != _bodyView) return;
  _body = [_bodyView.string copy];
  [self scheduleWrite];
}

#pragma mark Actions

- (IBAction)serviceChosen:(id)sender
{
  ODWService *chosen = [_services serviceNamed:_servicePopup.titleOfSelectedItem ?: @""];
  if (!chosen || chosen == _service) return;
  // Another service, another model: the request starts again, of its
  // entities.
  [self write];
  _service = chosen;
  _query = @{};
  _entitySet = nil;
  _operation = nil;
  [_key removeAllObjects];
  [_parameters removeAllObjects];
  _body = @"";
  _kind = ODWBuilderQuery;
  [_services setService:chosen ofDocument:_document];
  [self removePanel];
  [self write];
  [self showReading:YES];
}

- (IBAction)connectService:(id)sender
{
  if (_service) [_services connect:_service];
}

// Another kind: what it is of carried over where it can be (the query's
// entity set, the key), a body begun with the entity's properties.
- (IBAction)kindChosen:(id)sender
{
  ODWBuilderKind kind = (ODWBuilderKind)_kindPopup.selectedTag;
  if (kind == _kind) return;
  ODataSchema *schema = [self schema];
  if (_kind == ODWBuilderQuery && kind != ODWBuilderCall) _entitySet = [self entitySetOfQuery] ?: _entitySet;
  if (kind == ODWBuilderQuery && _entitySet) {
    NSString *entity = ODWEntityOfEntitySet(schema, _entitySet);
    if (entity && ![[_panel currentQuery].entityName isEqual:entity]) {
      _query = @{ @"entity": entity };
      _kind = kind;
      [self showPanelReading:YES];
    }
  }
  _kind = kind;
  if ((kind == ODWBuilderCreate || kind == ODWBuilderUpdate) && !_body.length && _entitySet) {
    _body = ODWSampleBodyOfEntitySet(schema, _entitySet, kind == ODWBuilderCreate);
    _bodyView.string = _body;
  }
  if (kind == ODWBuilderCall && !_operation) {
    _operation = [_service operationNames].firstObject;
    if (_operation) _parameters = [ODWSampleParametersOfOperation(schema, _operation) mutableCopy];
  }
  [self showRequestReading:NO];
  [self scheduleWrite];
}

// Another entity set or operation: its key's fields empty, a body of its
// properties (unless one is written), its parameters' samples.
- (IBAction)targetChosen:(id)sender
{
  NSString *chosen = _targetPopup.titleOfSelectedItem;
  if (!chosen.length) return;
  ODataSchema *schema = [self schema];
  if (_kind == ODWBuilderCall) {
    if ([chosen isEqualToString:_operation]) return;
    _operation = chosen;
    _parameters = [ODWSampleParametersOfOperation(schema, chosen) mutableCopy];
  } else {
    if ([chosen isEqualToString:_entitySet]) return;
    BOOL withKey = _kind == ODWBuilderCreate;
    BOOL sample = !_body.length || (_entitySet && [_body isEqualToString:ODWSampleBodyOfEntitySet(schema, _entitySet, withKey)]);
    _entitySet = chosen;
    [_key removeAllObjects];
    if (sample && _kind != ODWBuilderDelete) {
      _body = ODWSampleBodyOfEntitySet(schema, chosen, withKey);
      _bodyView.string = _body;
    }
  }
  [self showFields];
  [self scheduleWrite];
}

- (IBAction)runFetch:(id)sender
{
  [self write];
  if (!_service.connected) {
    NSBeep();
    _statusLabel.stringValue = @"Connect to the service first.";
    return;
  }
  NSString *failure = nil;
  NSURLRequest *request = [self URLRequestWithFailure:&failure];
  if (!request) {
    NSBeep();
    _statusLabel.stringValue = failure ?: @"It makes no request yet.";
    return;
  }
  _statusLabel.stringValue = [_service.connection summary];
  [_services sendURLRequest:request title:[self titleOfRequest:request] toService:_service];
}

// The request as curl; a note where curl cannot send it as UDCode does.
- (nullable NSString *)curl
{
  NSURLRequest *request = [self URLRequestWithFailure:NULL];
  if (!request) return nil;
  NSString *curl = ODWCurlOfRequest(request);
  if (_service.kind == ODWServiceBuiltIn) {
    curl = [@"# The built-in service answers in UDCode only: not on the network.\n" stringByAppendingString:curl];
  }
  return curl;
}

- (IBAction)showCurl:(id)sender
{
  NSString *curl = [self curl];
  if (!curl) {
    NSBeep();
    return;
  }
  ODWServices *services = _services;
  NSString *name = [_document.displayName.stringByDeletingPathExtension ?: @"Request" stringByAppendingString:@" (curl)"];
  [services.workbench openUntitledDocumentWithText:curl languageMode:@"bash" name:name];
}

- (IBAction)copyCurl:(id)sender
{
  NSString *curl = [self curl];
  if (!curl) {
    NSBeep();
    return;
  }
  NSPasteboard *board = [NSPasteboard generalPasteboard];
  [board declareTypes:@[ NSPasteboardTypeString ] owner:nil];
  [board setString:curl forType:NSPasteboardTypeString];
}

@end
