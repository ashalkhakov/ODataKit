// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWNavigatorViewController.h"
#import "ODWServices.h"
#import "ODWServiceSheet.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, ODWNodeKind) {
  ODWNodeService,
  ODWNodeNote,       // Connecting…, why it failed, double-click to connect
  ODWNodeGroup,      // Entity Sets, Functions and Actions
  ODWNodeEntitySet,
  ODWNodeOperation,
};

// A row of the outline.
@interface ODWNode : NSObject
@property (nonatomic) ODWNodeKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *badge;
@property (nonatomic, copy, nullable) NSString *toolTip;
@property (nonatomic, strong) ODWService *service;
@property (nonatomic, copy) NSArray<ODWNode *> *children;
// What was open, to be opened again: Service/Group.
@property (nonatomic, copy) NSString *path;
@end

@implementation ODWNode

+ (instancetype)nodeOfKind:(ODWNodeKind)kind title:(NSString *)title service:(ODWService *)service path:(NSString *)path
{
  ODWNode *node = [[self alloc] init];
  node.kind = kind;
  node.title = title;
  node.service = service;
  node.children = @[];
  node.path = path;
  return node;
}

@end

@interface ODWNavigatorViewController ()
@property (nonatomic, readwrite, weak) IBOutlet NSOutlineView *outlineView;
@property (nonatomic, strong) IBOutlet NSMenu *serviceMenu;
@property (nonatomic, strong) IBOutlet NSMenu *itemMenu;
@end

@implementation ODWNavigatorViewController {
  NSArray<ODWNode *> *_roots;
  ODWNode *_menuNode;  // what the context menu is about
  ODWServiceSheet *_sheet;
}

- (instancetype)initWithServices:(ODWServices *)services
{
  self = [super initWithNibName:@"ODWNavigator" bundle:[NSBundle bundleForClass:[ODWNavigatorViewController class]]];
  if (!self) return nil;
  _services = services;
  _roots = @[];
  self.title = @"OData";
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(servicesDidChange:)
                                               name:ODWServicesDidChangeNotification object:services];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// gnustep-gui has no -viewDidLoad: the rows filled as the view loads.
- (void)loadView
{
  [super loadView];
  _outlineView.frame = _outlineView.enclosingScrollView.contentView.bounds;
  [_outlineView sizeLastColumnToFit];
  [self reload];
}

- (void)servicesDidChange:(NSNotification *)note
{
  if (self.isViewLoaded) [self reload];
}

#pragma mark The rows

- (ODWNode *)nodeOfService:(ODWService *)service
{
  ODWNode *node = [ODWNode nodeOfKind:ODWNodeService title:service.name service:service path:service.name];
  node.toolTip = service.root.absoluteString;
  NSMutableArray *children = [NSMutableArray array];
  if (service.connecting) {
    node.badge = @"connecting…";
    [children addObject:[ODWNode nodeOfKind:ODWNodeNote title:@"Connecting…" service:service path:@""]];
  } else if (service.connected) {
    NSArray *sets = [service entitySetNames], *operations = [service operationNames];
    node.badge = [NSString stringWithFormat:@"%lu sets", (unsigned long)sets.count];
    ODWNode *setGroup = [ODWNode nodeOfKind:ODWNodeGroup title:@"Entity Sets" service:service
                                       path:[service.name stringByAppendingString:@"/Entity Sets"]];
    NSMutableArray *setNodes = [NSMutableArray array];
    for (NSString *name in sets) [setNodes addObject:[ODWNode nodeOfKind:ODWNodeEntitySet title:name service:service path:@""]];
    setGroup.children = setNodes;
    setGroup.badge = [NSString stringWithFormat:@"%lu", (unsigned long)sets.count];
    [children addObject:setGroup];
    if (operations.count) {
      ODWNode *operationGroup = [ODWNode nodeOfKind:ODWNodeGroup title:@"Functions and Actions" service:service
                                               path:[service.name stringByAppendingString:@"/Functions and Actions"]];
      NSMutableArray *operationNodes = [NSMutableArray array];
      for (NSString *name in operations) {
        [operationNodes addObject:[ODWNode nodeOfKind:ODWNodeOperation title:name service:service path:@""]];
      }
      operationGroup.children = operationNodes;
      operationGroup.badge = [NSString stringWithFormat:@"%lu", (unsigned long)operations.count];
      [children addObject:operationGroup];
    }
  } else if (service.failure) {
    node.badge = @"failed";
    ODWNode *note = [ODWNode nodeOfKind:ODWNodeNote title:service.failure service:service path:@""];
    note.toolTip = service.failure;
    [children addObject:note];
  } else {
    node.badge = service.preset ? (service.kind == ODWServiceBuiltIn ? @"in UDCode" : @"sample") : (service.inProject ? @"project" : nil);
    [children addObject:[ODWNode nodeOfKind:ODWNodeNote title:@"Double-click to connect" service:service path:@""]];
  }
  node.children = children;
  return node;
}

// The rows again, what was open opened again, the selection kept.
- (void)reload
{
  NSMutableSet *open = [NSMutableSet set];
  for (NSInteger row = 0; row < _outlineView.numberOfRows; row++) {
    ODWNode *node = [_outlineView itemAtRow:row];
    if (node.path.length && [_outlineView isItemExpanded:node]) [open addObject:node.path];
  }
  ODWNode *selected = [_outlineView itemAtRow:_outlineView.selectedRow];
  NSString *selectedPath = selected.path.length ? selected.path : nil;
  NSMutableArray *roots = [NSMutableArray array];
  for (ODWService *service in _services.services) [roots addObject:[self nodeOfService:service]];
  _roots = roots;
  [_outlineView reloadData];
  for (ODWNode *root in _roots) {
    // A service connecting or connected is open, as it was asked to be.
    if ([open containsObject:root.path] || root.service.connecting || (root.service.connected && ![open count])) {
      [_outlineView expandItem:root];
    }
    for (ODWNode *group in root.children) {
      if (group.kind == ODWNodeGroup && ([open containsObject:group.path] || [group.title isEqualToString:@"Entity Sets"])) {
        [_outlineView expandItem:group];
      }
    }
  }
  for (NSInteger row = 0; selectedPath && row < _outlineView.numberOfRows; row++) {
    if ([[[_outlineView itemAtRow:row] path] isEqualToString:selectedPath]) {
      [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    }
  }
}

- (ODWNode *)nodeAtRow:(NSInteger)row
{
  if (row < 0) row = _outlineView.clickedRow >= 0 ? _outlineView.clickedRow : _outlineView.selectedRow;
  return row >= 0 ? [_outlineView itemAtRow:row] : nil;
}

- (ODWService *)serviceAtRow:(NSInteger)row
{
  return [self nodeAtRow:row].service;
}

// What an action is about: the context menu's row, else the clicked or
// selected one.
- (ODWNode *)actedNode
{
  return _menuNode ?: [self nodeAtRow:-1];
}

#pragma mark NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item
{
  return (NSInteger)(item ? [(ODWNode *)item children] : _roots).count;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item
{
  return (item ? [(ODWNode *)item children] : _roots)[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item
{
  return [(ODWNode *)item children].count > 0;
}

- (id)outlineView:(NSOutlineView *)outline objectValueForTableColumn:(NSTableColumn *)column byItem:(id)item
{
  return [(ODWNode *)item title];
}

#pragma mark NSOutlineViewDelegate

- (void)outlineView:(NSOutlineView *)outline willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column item:(id)item
{
  ODWNode *node = item;
  if ([cell isKindOfClass:[UDBadgeTextFieldCell class]]) [(UDBadgeTextFieldCell *)cell setBadge:node.badge];
  if ([cell respondsToSelector:@selector(setTextColor:)]) {
    [cell setTextColor:node.kind == ODWNodeNote ? [NSColor secondaryLabelColor] : [NSColor controlTextColor]];
  }
}

- (NSString *)outlineView:(NSOutlineView *)outline toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect
              tableColumn:(NSTableColumn *)column item:(id)item mouseLocation:(NSPoint)location
{
  return [(ODWNode *)item toolTip] ?: @"";
}

#pragma mark The context menu

- (void)menuNeedsUpdate:(NSMenu *)menu
{
  [menu removeAllItems];
  _menuNode = [self nodeAtRow:_outlineView.clickedRow];
  NSMenu *items = _menuNode.kind == ODWNodeEntitySet || _menuNode.kind == ODWNodeOperation ? _itemMenu : _menuNode ? _serviceMenu : nil;
  for (NSMenuItem *item in items.itemArray) [menu addItem:[item copy]];
}

- (void)menuDidClose:(NSMenu *)menu
{
  // The item chosen is sent after the menu closes: what it is about kept
  // till then.
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_menuNode = nil;
  });
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
  SEL action = item.action;
  ODWService *service = [self actedNode].service;
  if (sel_isEqual(action, @selector(editService:)) || sel_isEqual(action, @selector(removeService:))) return service && !service.preset;
  if (sel_isEqual(action, @selector(connectService:))) return service && !service.connected && !service.connecting;
  if (sel_isEqual(action, @selector(disconnectService:))) return service.connected || service.connecting;
  if (sel_isEqual(action, @selector(signOutOfService:))) return service && service.kind == ODWServiceOther;
  if (sel_isEqual(action, @selector(sendToService:))) return service && [_services canSend];
  return YES;
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
  if (sel_isEqual(item.action, @selector(removeService:)) || sel_isEqual(item.action, @selector(refreshService:))) {
    ODWService *service = [self nodeAtRow:-1].service;
    return sel_isEqual(item.action, @selector(refreshService:)) ? service != nil : service && !service.preset;
  }
  return YES;
}

#pragma mark Services

- (IBAction)addService:(id)sender
{
  [self editAService:nil];
}

- (IBAction)editService:(id)sender
{
  ODWService *service = [self actedNode].service;
  if (service && !service.preset) [self editAService:service];
}

- (void)editAService:(ODWService *)service
{
  ODWServices *services = _services;
  NSWindow *window = services.workbench.window ?: self.view.window;
  _sheet = [[ODWServiceSheet alloc] initWithService:service inProject:services.workbench.project != nil];
  __weak ODWNavigatorViewController *weak = self;
  [_sheet beginSheetForWindow:window done:^(ODWService *edited) {
    ODWNavigatorViewController *me = weak;
    if (!me) return;
    me->_sheet = nil;
    if (!edited) return;
    if (service && ![service.name isEqualToString:edited.name]) [services removeService:service];
    [services addService:edited];
    [services connect:[services serviceNamed:edited.name] ?: edited];
  }];
}

- (IBAction)removeService:(id)sender
{
  ODWService *service = [self actedNode].service;
  if (!service || service.preset) return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Remove “%@”?", service.name];
  alert.informativeText = service.inProject ? @"It is removed from the project's settings, for everyone who opens the folder."
                                            : @"It is removed from your services.";
  [alert addButtonWithTitle:@"Remove"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn) [_services removeService:service];
}

- (IBAction)connectService:(id)sender
{
  ODWService *service = [self actedNode].service;
  if (service) [_services connect:service];
}

- (IBAction)refreshService:(id)sender
{
  ODWService *service = [self actedNode].service;
  if (!service) return;
  [_services disconnect:service];
  [_services connect:service];
}

- (IBAction)disconnectService:(id)sender
{
  ODWService *service = [self actedNode].service;
  if (service) [_services disconnect:service];
}

- (IBAction)signOutOfService:(id)sender
{
  ODWService *service = [self actedNode].service;
  if (service) [_services signOut:service];
}

#pragma mark Requests

// A new .odata document, sent to the service: its first request written
// (an entity set's), or a note of how they are written.
- (void)openRequests:(NSString *)text ofService:(ODWService *)service send:(BOOL)send
{
  ODWServices *services = _services;
  id<UDWorkbench> workbench = services.workbench;
  [workbench openUntitledDocumentWithText:text languageMode:@"odata" name:[service.name stringByAppendingString:@" Requests"]];
  UDCodeDocument *document = workbench.selectedDocument;
  if (!document) return;
  [services setService:service ofDocument:document];
  [workbench.selectedEditor.textView setSelectedRange:NSMakeRange(text.length, 0)];
  if (send) [services sendRequest:nil];
}

- (IBAction)newRequestDocument:(id)sender
{
  ODWService *service = [self actedNode].service;
  if (!service) return;
  NSString *first = [service entitySetNames].firstObject;
  NSString *text = [NSString stringWithFormat:@"# Requests to %@ (%@), sent with Editor > Run (⌘↩), or all of them\n"
                                              @"# with Run All (⇧⌘↩). Each is a request line (METHOD URL, the URL\n"
                                              @"# from the service root), its headers, a blank line, its body;\n"
                                              @"# ### begins the next.\n\nGET %@?$top=20\n",
                                              service.name, service.root.absoluteString, first ?: @"$metadata"];
  [self openRequests:text ofService:service send:NO];
}

- (IBAction)sendToService:(id)sender
{
  ODWService *service = [self actedNode].service;
  ODWServices *services = _services;
  UDCodeDocument *document = services.workbench.selectedDocument;
  if (!service || !document || ![services canSend]) return;
  [services setService:service ofDocument:document];
}

- (IBAction)newRequestOfItem:(id)sender
{
  ODWNode *node = [self actedNode];
  if (node.kind == ODWNodeEntitySet) {
    [self openRequests:[NSString stringWithFormat:@"GET %@?$top=20\n", node.title] ofService:node.service send:YES];
  } else if (node.kind == ODWNodeOperation) {
    [self openRequests:[NSString stringWithFormat:@"GET %@()\n", node.title] ofService:node.service send:NO];
  }
}

- (IBAction)copyName:(id)sender
{
  ODWNode *node = [self actedNode];
  if (!node) return;
  NSPasteboard *board = [NSPasteboard generalPasteboard];
  [board declareTypes:@[ NSPasteboardTypeString ] owner:nil];
  [board setString:node.title forType:NSPasteboardTypeString];
}

// A double click: a service connected to; an entity set's rows asked for.
- (IBAction)openItem:(id)sender
{
  ODWNode *node = [self nodeAtRow:_outlineView.clickedRow];
  if (!node) return;
  if (node.kind == ODWNodeEntitySet || node.kind == ODWNodeOperation) {
    _menuNode = node;
    [self newRequestOfItem:sender];
    _menuNode = nil;
  } else if (!node.service.connected && !node.service.connecting) {
    [_services connect:node.service];
  }
}

@end
