// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWNavigatorViewController.h"
#import "ODWServices.h"
#import "ODWServiceSheet.h"
#import "ODWBuilderViewController.h"
#import "ODWTemplates.h"
#import <ODataKit/ODataSchema.h>
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
  BOOL _fillingMenu;   // gnustep-gui asks again as an item with a submenu is put in
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
  if (_fillingMenu) return;
  _fillingMenu = YES;
  [menu removeAllItems];
  _menuNode = [self nodeAtRow:_outlineView.clickedRow];
  BOOL entitySet = _menuNode.kind == ODWNodeEntitySet, operation = _menuNode.kind == ODWNodeOperation;
  NSMenu *items = entitySet || operation ? _itemMenu : _menuNode ? _serviceMenu : nil;
  for (NSMenuItem *item in items.itemArray) {
    // The item menu's: tagged 1 an entity set's only, 2 an operation's.
    if (items == _itemMenu && ((item.tag == 1 && !entitySet) || (item.tag == 2 && !operation))) continue;
    [menu addItem:[item copy]];
  }
  _fillingMenu = NO;
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

// A new builder document of the service's: the file's request, named
// (its tab's title; Save's file name); sent once it is shown, when asked.
- (void)openBuilderOfFile:(NSDictionary *)file named:(NSString *)name service:(ODWService *)service execute:(BOOL)execute
{
  ODWServices *services = _services;
  id<UDWorkbench> workbench = services.workbench;
  services.executesNextBuilder = execute;
  [workbench openUntitledDocumentWithText:[ODWBuilderViewController textOfFile:file service:service.name]
                             languageMode:@"odataq" name:name];
  services.executesNextBuilder = NO;
  UDCodeDocument *document = workbench.selectedDocument;
  if (document) [services setService:service ofDocument:document];
}

- (IBAction)newQueryBuilder:(id)sender
{
  ODWNode *node = [self actedNode];
  ODWService *service = node.service;
  if (!service) return;
  // An entity set's entity: its type's name, as the model built from
  // $metadata names its entities.
  NSDictionary *query = @{};
  NSString *entity = node.kind == ODWNodeEntitySet ? ODWEntityOfEntitySet(service.connection.store.schema, node.title) : nil;
  if (entity.length && service.connection.model.entitiesByName[entity]) query = @{ @"entity": entity };
  NSString *name = node.kind == ODWNodeEntitySet ? [NSString stringWithFormat:@"%@ Query", node.title]
                                                 : [service.name stringByAppendingString:@" Query"];
  [self openBuilderOfFile:@{ @"request": @"query", @"query": query } named:name service:service execute:NO];
}

// A builder set up for a request of the item's: an entity set's (its
// sender's tag an ODWTemplate), an operation's call.
- (IBAction)insertRequestOfItem:(id)sender
{
  ODWNode *node = [self actedNode];
  ODataSchema *schema = node.service.connection.store.schema;
  if (!schema) return;
  if (node.kind == ODWNodeEntitySet) {
    ODWTemplate kind = (ODWTemplate)[sender tag];
    NSDictionary *file = ODWTemplateOfEntitySet(schema, node.title, kind);
    NSArray *names = @[ @"%@ Query", @"%@ by Key", @"%@ Count", @"New %@", @"%@ Update", @"%@ Delete" ];
    NSString *name = [NSString stringWithFormat:names[(NSUInteger)MIN(MAX(kind, 0), 5)], node.title];
    if (file) [self openBuilderOfFile:file named:name service:node.service execute:NO];
  } else if (node.kind == ODWNodeOperation) {
    NSDictionary *file = ODWTemplateOfOperation(schema, node.title);
    if (file) [self openBuilderOfFile:file named:[node.title stringByAppendingString:@" Call"] service:node.service execute:NO];
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
    // An entity set's rows, asked for; an operation's call, set up.
    ODataSchema *schema = node.service.connection.store.schema;
    BOOL set = node.kind == ODWNodeEntitySet;
    NSDictionary *file = !schema ? nil : set ? ODWTemplateOfEntitySet(schema, node.title, ODWTemplateGetAll) : ODWTemplateOfOperation(schema, node.title);
    NSString *name = [node.title stringByAppendingString:set ? @" Query" : @" Call"];
    if (file) [self openBuilderOfFile:file named:name service:node.service execute:set];
  } else if (!node.service.connected && !node.service.connecting) {
    [_services connect:node.service];
  }
}

@end
