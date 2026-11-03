// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWBuilderViewController.h"
#import "ODWServices.h"
#import "WBQueryPanel.h"
#import <UDPieceTable/UDTextModel.h>

// The tab's view (ODWBuilder.xib): its controller after it in the chain,
// wherever UDCode puts it, so the panel's Execute (sent to the first
// responder) reaches the tab. AppKit puts a view controller there by itself;
// gnustep-gui does not; and a view put in another is given its superview as
// the next responder again.
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

@interface ODWBuilderViewController ()
@property (nonatomic, readwrite, weak) IBOutlet NSPopUpButton *servicePopup;
@property (nonatomic, readwrite, weak) IBOutlet NSButton *connectButton;
@property (nonatomic, readwrite, weak) IBOutlet NSTextField *statusLabel;
@property (nonatomic, weak) IBOutlet NSView *panelHost;
@property (nonatomic, readwrite, nullable) ODWService *service;
@property (nonatomic, readwrite, nullable) WBQueryPanel *panel;
@end

@implementation ODWBuilderViewController {
  // The query as the text has it, for the panel once it is there.
  NSDictionary *_query;
  // The text being written (what the text model tells then is our own).
  BOOL _writing;
  // The connection the panel's query is of.
  WBConnection *_panelConnection;
  // The panel's own size (its XIB's): the least it is shown at.
  NSSize _panelSize;
}

+ (NSString *)textOfQuery:(NSDictionary *)query service:(NSString *)service
{
  NSMutableDictionary *file = [NSMutableDictionary dictionaryWithObject:query ?: @{} forKey:@"query"];
  if (service.length) file[@"service"] = service;
  NSData *data = [NSJSONSerialization dataWithJSONObject:file options:NSJSONWritingPrettyPrinted error:NULL];
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
  return [text hasSuffix:@"\n"] ? text : [text stringByAppendingString:@"\n"];
}

- (instancetype)initWithServices:(ODWServices *)services document:(UDCodeDocument *)document
{
  self = [super initWithNibName:@"ODWBuilder" bundle:[NSBundle bundleForClass:[ODWBuilderViewController class]]];
  if (!self) return nil;
  _services = services;
  _document = document;
  self.title = @"Query Builder";
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(textDidChange:) name:UDTextModelDidChangeNotification object:document.textModel];
  [center addObserver:self selector:@selector(servicesDidChange:) name:ODWServicesDidChangeNotification object:services];
  [self read];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

// gnustep-gui has no -viewDidLoad: the service list filled as the view
// loads.
- (void)loadView
{
  [super loadView];
  NSClipView *clip = _panelHost.enclosingScrollView.contentView;
  clip.postsFrameChangedNotifications = YES;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clipDidResize:)
                                               name:NSViewFrameDidChangeNotification object:clip];
  [self showReading:YES];
}

#pragma mark Reading

// The text's service and query; an empty text, a new query of the
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
  _query = [dictionary[@"query"] isKindOfClass:[NSDictionary class]] ? dictionary[@"query"] : @{};
  [self showReading:YES];
}

- (void)textDidChange:(NSNotification *)note
{
  if (_writing) return;
  [self read];
}

- (void)servicesDidChange:(NSNotification *)note
{
  if (self.isViewLoaded) [self showReading:NO];
}

#pragma mark Showing

// The services to choose from; the panel, over the service's connection,
// once it is connected (connected now when it is not); or what is wanted.
// The panel's query is the text's when the text was just read, or the panel
// is new; otherwise it is left as it is being edited.
- (void)showReading:(BOOL)reading
{
  if (!self.isViewLoaded) return;
  ODWServices *services = _services;
  [_servicePopup removeAllItems];
  for (ODWService *service in services.services) [_servicePopup addItemWithTitle:service.name];
  if (_service) [_servicePopup selectItemWithTitle:_service.name];
  else [_servicePopup selectItemAtIndex:-1];
  _connectButton.enabled = _service && !_service.connected && !_service.connecting;
  if (!_service) {
    _statusLabel.stringValue = @"Choose the service to build the query against.";
    [self removePanel];
    return;
  }
  if (!_service.connected) {
    _statusLabel.stringValue = _service.connecting ? [NSString stringWithFormat:@"Connecting to %@ …", _service.name]
                             : _service.failure ? [NSString stringWithFormat:@"Not connected: %@", _service.failure]
                                                : [NSString stringWithFormat:@"Connect to %@ to build the query.", _service.name];
    [self removePanel];
    if (!_service.connecting && !_service.failure) [services connect:_service];
    return;
  }
  [self showPanelReading:reading];
}

// The panel as wide as the tab, its own height, at the top; no smaller than
// its own size (the scroll view scrolls then).
- (void)layoutPanel
{
  NSView *view = _panel.view;
  if (!view) return;
  NSSize shown = _panelHost.enclosingScrollView.contentSize;
  NSSize size = NSMakeSize(MAX(shown.width, _panelSize.width), MAX(shown.height, _panelSize.height));
  [_panelHost setFrameSize:size];
  view.frame = NSMakeRect(0, 0, size.width, _panelSize.height);
  // Its top in view again (a scroller come or gone moves it), across as it
  // was.
  NSClipView *clip = _panelHost.enclosingScrollView.contentView;
  CGFloat across = MIN(MAX(clip.bounds.origin.x, 0), MAX(size.width - NSWidth(clip.bounds), 0));
  [clip scrollToPoint:NSMakePoint(across, 0)];
  [_panelHost.enclosingScrollView reflectScrolledClipView:clip];
}

- (void)clipDidResize:(NSNotification *)note
{
  [self layoutPanel];
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
    _panel = [[WBQueryPanel alloc] init];
    NSView *view = _panel.view;
    _panelSize = view.frame.size;
    view.autoresizingMask = NSViewNotSizable;
    [_panelHost addSubview:view];
    [self layoutPanel];
    // Explain is the Workbench's, at its built-in service; Execute is the
    // tab's, wherever the focus is.
    [_panel.explainButton setHidden:YES];
    _panel.executeButton.target = self;
    _panel.executeButton.action = @selector(runFetch:);
    _panel.connection = connection;
    _panelConnection = connection;
    __weak ODWBuilderViewController *weak = self;
    _panel.queryDidChange = ^{
      [weak scheduleWrite];
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
  _statusLabel.stringValue = [connection summary];
}

#pragma mark Writing

- (void)scheduleWrite
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(write) object:nil];
  [self performSelector:@selector(write) withObject:nil afterDelay:0];
}

// The query, as the panel says it, written as the text: one edit, so undone
// as one.
- (void)write
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(write) object:nil];
  WBQuery *query = [_panel currentQuery];
  NSDictionary *dictionary = query ? [query dictionary] : _query;
  NSString *text = [ODWBuilderViewController textOfQuery:dictionary service:_service.name];
  UDTextModel *model = _document.textModel;
  if ([text isEqualToString:[model getValue]]) return;
  _query = dictionary;
  UDRange all = [model validateRange:(UDRange){1, 1, NSIntegerMax, NSIntegerMax}];
  _writing = YES;
  [model applyEdits:@[ [[UDTextModelEdit alloc] initWithRange:all text:text] ]];
  _writing = NO;
}

#pragma mark Actions

- (IBAction)serviceChosen:(id)sender
{
  ODWService *chosen = [_services serviceNamed:_servicePopup.titleOfSelectedItem ?: @""];
  if (!chosen || chosen == _service) return;
  // Another service, another model: the query starts again, of its entities.
  [self write];
  _service = chosen;
  _query = @{};
  [_services setService:chosen ofDocument:_document];
  [self removePanel];
  [self write];
  [self showReading:YES];
}

- (IBAction)connectService:(id)sender
{
  if (_service) [_services connect:_service];
}

- (IBAction)runFetch:(id)sender
{
  [self write];
  if (!_service.connected || !_panel) {
    NSBeep();
    _statusLabel.stringValue = @"Connect to the service first.";
    return;
  }
  NSString *translation = _panel.translation;
  NSURL *url = [NSURL URLWithString:translation];
  if (!url.scheme.length) {
    _statusLabel.stringValue = translation.length ? translation : @"The query makes no request yet.";
    return;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"GET";
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSString *root = _service.connection.serviceRoot.absoluteString ?: @"";
  NSString *shown = [translation hasPrefix:root] ? [translation substringFromIndex:root.length] : translation;
  [_services sendURLRequest:request title:[@"GET " stringByAppendingString:[shown stringByRemovingPercentEncoding] ?: shown]
                  toService:_service];
}

@end
