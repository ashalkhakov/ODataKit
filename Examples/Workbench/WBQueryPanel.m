// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBQueryPanel.h"

@interface WBQueryPanel ()
@property (nonatomic, readwrite, strong) IBOutlet NSPopUpButton *entityPopup;
@property (nonatomic, readwrite, strong) IBOutlet NSPopUpButton *resultTypePopup;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *limitField;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *skipField;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *batchSizeField;
@property (nonatomic, readwrite, strong) IBOutlet NSButton *subentitiesButton;
@property (nonatomic, readwrite, strong) IBOutlet NSButton *faultsButton;
@property (nonatomic, readwrite, strong) IBOutlet NSTextView *predicateView;
@property (nonatomic, readwrite, strong) IBOutlet NSPredicateEditor *predicateEditor;
@property (nonatomic, readwrite, strong) IBOutlet NSSegmentedControl *predicateModeControl;
@property (nonatomic, strong) IBOutlet NSTabView *predicateTabView;
@property (nonatomic, strong) IBOutlet NSTextField *predicateNote;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *timeField;
@property (nonatomic, readwrite, strong) IBOutlet NSTableView *sortTable;
@property (nonatomic, readwrite, strong) IBOutlet NSOutlineView *expandOutline;
@property (nonatomic, readwrite, strong) IBOutlet NSTableView *selectTable;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *searchField;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *computeField;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *groupField;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *aggregateField;
@property (nonatomic, readwrite, strong) IBOutlet NSTextField *wireURLField;
@property (nonatomic, readwrite, strong) IBOutlet NSButton *explainButton;
@property (nonatomic, readwrite, strong) IBOutlet NSButton *executeButton;
@end

@implementation WBQueryPanel {
  NSMutableDictionary *_pathItems;  // key path -> the one string the outline knows it by
  BOOL _prefersText;                // Text chosen: kept until Builder is
}

- (instancetype)init
{
  return [self initStacked:NO];
}

- (instancetype)initStacked:(BOOL)stacked
{
  self = [super initWithNibName:stacked ? @"WBQueryPanelStacked" : @"WBQueryPanel"
                         bundle:[NSBundle bundleForClass:[WBQueryPanel class]]];
  if (!self) return nil;
  _pathItems = [NSMutableDictionary dictionary];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// gnustep-gui has no -viewDidLoad: the fields wired up as the view loads.
- (void)loadView
{
  [super loadView];
  for (NSTextField *field in @[ _limitField, _skipField, _batchSizeField ]) field.delegate = self;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(predicateChanged:)
                                               name:NSTextDidChangeNotification object:_predicateView];
  // The XIB leaves the text view's colours to the platform, and GNUstep
  // draws them black on black; it grows with its text, as wide as its
  // scroll view.
  NSTextView *view = _predicateView;
  view.drawsBackground = YES;
  view.backgroundColor = [NSColor textBackgroundColor];
  view.textColor = [NSColor textColor];
  view.insertionPointColor = [NSColor textColor];
  NSSize size = view.enclosingScrollView.contentSize;
  view.minSize = NSMakeSize(0, size.height);
  view.maxSize = NSMakeSize(1e7, 1e7);
  view.verticallyResizable = YES;
  view.horizontallyResizable = NO;
  view.autoresizingMask = NSViewWidthSizable;
  view.textContainer.containerSize = NSMakeSize(size.width, 1e7);
  view.textContainer.widthTracksTextView = YES;
}

- (void)setQuery:(WBQuery *)query
{
  (void)self.view;
  _query = query;
  [_entityPopup removeAllItems];
  if (query) [_entityPopup addItemsWithTitles:[query entityNames]];
  [self showQueryControls];
  [self refreshTranslation];
}

- (void)changed
{
  if (_queryDidChange) _queryDidChange();
}

#pragma mark The controls

// The panel's values, into the query: what it asks is what the panel says.
- (void)readQueryControls
{
  if (!_query) return;
  _query.entityName = _entityPopup.titleOfSelectedItem.length ? _entityPopup.titleOfSelectedItem : nil;
  NSString *type = _resultTypePopup.titleOfSelectedItem;
  _query.resultType = [type isEqualToString:@"count"] ? NSCountResultType
                    : [type isEqualToString:@"dictionary"] ? NSDictionaryResultType
                    : [type isEqualToString:@"object IDs"] ? NSManagedObjectIDResultType : NSManagedObjectResultType;
  _query.predicateText = [_predicateView.string copy] ?: @"";
  _query.limitText = _limitField.stringValue ?: @"";
  _query.skipText = _skipField.stringValue ?: @"";
  _query.pageSizeText = _batchSizeField.stringValue ?: @"";
  _query.includesSubentities = _subentitiesButton.state == NSOnState;
  _query.returnsObjectsAsFaults = _faultsButton.state == NSOnState;
  _query.searchText = _searchField.stringValue ?: @"";
  _query.computeText = _computeField.stringValue ?: @"";
  _query.groupText = _groupField.stringValue ?: @"";
  _query.aggregateText = _aggregateField.stringValue ?: @"";
  _query.timeText = _timeField.stringValue ?: @"";
}

// The query's values, into the panel: after a preset, or a new entity.
- (void)showQueryControls
{
  (void)self.view;
  [_entityPopup selectItemWithTitle:[_query entity].name];
  NSString *type = _query.resultType == NSCountResultType ? @"count"
                 : _query.resultType == NSDictionaryResultType ? @"dictionary"
                 : _query.resultType == NSManagedObjectIDResultType ? @"object IDs" : @"objects";
  [_resultTypePopup selectItemWithTitle:type];
  _predicateView.string = _query.predicateText ?: @"";
  [self showPredicate];
  _limitField.stringValue = _query.limitText ?: @"";
  _skipField.stringValue = _query.skipText ?: @"";
  _searchField.stringValue = _query.searchText ?: @"";
  _computeField.stringValue = _query.computeText ?: @"";
  _groupField.stringValue = _query.groupText ?: @"";
  _aggregateField.stringValue = _query.aggregateText ?: @"";
  _timeField.stringValue = _query.timeText ?: @"";
  _timeField.enabled = [_query hasApplicationTime];
  [_pathItems removeAllObjects];
  [self reloadQueryPanel];
}

- (WBQuery *)currentQuery
{
  [self readQueryControls];
  return _query;
}

// The GET the store would send, from the same schema and version it uses.
- (void)refreshTranslation
{
  _wireURLField.stringValue = self.translation;
}

- (NSString *)translation
{
  WBQuery *query = [self currentQuery];
  if (!query) return @"";
  NSError *error = nil;
  if ([query isVerbatim]) {
    NSURL *url = _connection.context ? [[query verbatimQueryInContext:_connection.context error:&error] URL:&error] : nil;
    return url.absoluteString ?: (error.localizedDescription ?: @"");
  }
  NSFetchRequest *request = [query fetchRequestError:&error];
  if (!request) return error.localizedDescription ?: @"bad predicate";
  NSURL *url = [_connection.store URLForFetchRequest:request error:&error];
  return url.absoluteString ?: (error.localizedDescription ?: @"");
}

- (void)controlTextDidChange:(NSNotification *)n
{
  [self changed];
  [self refreshTranslation];
}

- (void)predicateChanged:(NSNotification *)n
{
  // Typed: whether the builder can show it now.
  if (n) [self setBuilderAvailable:[self showTextInBuilder:_predicateView.string]];
  [self changed];
  [self refreshTranslation];
}

#pragma mark The predicate, built or written

// All, Any and None (the XIB's), and a row for each of the entity's
// attributes that has operators: a binary or transformable one has none.
- (void)rebuildPredicateTemplates
{
  NSMutableArray *templates = [NSMutableArray array];
  for (NSPredicateEditorRowTemplate *template in _predicateEditor.rowTemplates) {
    if (template.compoundTypes) {
      [templates addObject:template];
      break;
    }
  }
  NSEntityDescription *entity = [_query entity];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attribute = entity.attributesByName[name];  // gnustep-base: no generics to type the subscript
    switch (attribute.attributeType) {
      case NSInteger16AttributeType:
      case NSInteger32AttributeType:
      case NSInteger64AttributeType:
      case NSDecimalAttributeType:
      case NSDoubleAttributeType:
      case NSFloatAttributeType:
      case NSStringAttributeType:
      case NSBooleanAttributeType:
      case NSDateAttributeType:
        [paths addObject:name];
        break;
      default:
        break;
    }
  }
  if (paths.count) {
    [templates addObjectsFromArray:[NSPredicateEditorRowTemplate templatesWithAttributeKeyPaths:paths inEntityDescription:entity]];
  }
  _predicateEditor.rowTemplates = templates;
}

// The builder's predicate as text: none for no rows, or All of nothing.
- (NSString *)builderText
{
  NSPredicate *predicate = _predicateEditor.predicate;
  NSString *format = predicate.predicateFormat;
  return !format || [format isEqualToString:@"TRUEPREDICATE"] ? @"" : format;
}

// The text into the builder, if it can show it as it is: it reads back the
// same predicate. A comparison alone goes under All, so that a row added
// beside it joins it.
- (BOOL)showTextInBuilder:(NSString *)text
{
  NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed hasPrefix:@"$"]) return NO;
  NSPredicate *predicate = nil;
  if (trimmed.length) {
    @try {
      predicate = [NSPredicate predicateWithFormat:trimmed];
    } @catch (NSException *exception) {
      return NO;
    }
  }
  @try {
    if (!predicate) {
      // Nothing: All, with no rows under it yet.
      _predicateEditor.objectValue = nil;
      [_predicateEditor insertRowAtIndex:0 withType:NSRuleEditorRowTypeCompound asSubrowOfRow:-1 animate:NO];
    } else if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
      _predicateEditor.objectValue = predicate;
    } else {
      _predicateEditor.objectValue = [NSCompoundPredicate andPredicateWithSubpredicates:@[ predicate ]];
    }
  } @catch (NSException *exception) {
    return NO;
  }
  return [[self builderText] isEqualToString:predicate ? predicate.predicateFormat : @""];
}

- (void)setBuilderAvailable:(BOOL)available
{
  [_predicateModeControl setEnabled:available forSegment:0];
  _predicateNote.hidden = available;
  if (!available) [self selectPredicatePage:NO];
}

- (void)selectPredicatePage:(BOOL)builder
{
  [_predicateTabView selectTabViewItemWithIdentifier:builder ? @"builder" : @"text"];
  _predicateModeControl.selectedSegment = builder ? 0 : 1;
}

- (BOOL)showsPredicateBuilder
{
  return [_predicateTabView.selectedTabViewItem.identifier isEqual:@"builder"];
}

// The query's predicate shown: in the builder unless Text was chosen, or
// the builder cannot show it.
- (void)showPredicate
{
  [self rebuildPredicateTemplates];
  BOOL shown = [self showTextInBuilder:_predicateView.string];
  [self setBuilderAvailable:shown];
  [self selectPredicatePage:shown && !_prefersText];
}

- (IBAction)predicateEdited:(id)sender
{
  (void)sender;
  _predicateView.string = [self builderText];
  [self predicateChanged:nil];
}

- (IBAction)predicateModeChanged:(id)sender
{
  (void)sender;
  if (_predicateModeControl.selectedSegment == 0) {
    BOOL shown = [self showTextInBuilder:_predicateView.string];
    [self setBuilderAvailable:shown];
    if (shown) _prefersText = NO;
    [self selectPredicatePage:shown];
  } else {
    _prefersText = YES;
    [self selectPredicatePage:NO];
  }
}

// A switch of the query's: result type, sub-entities, faults.
- (IBAction)queryChanged:(id)sender
{
  (void)sender;
  [self changed];
  [self refreshTranslation];
}

- (IBAction)entityChanged:(id)sender
{
  (void)sender;
  [[self currentQuery] reset];
  [self showQueryControls];
  [self changed];
  [self refreshTranslation];
}

- (void)applyPreset:(NSDictionary *)preset
{
  if (!_query) return;
  [self readQueryControls];
  [_query applyPreset:preset];
  [self showQueryControls];
  [self changed];
  [self refreshTranslation];
}

#pragma mark The lists

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
  [self changed];
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

#pragma mark NSTableViewDataSource (sort keys, properties)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  if (table == _sortTable) return (NSInteger)_query.sorts.count;
  if (table == _selectTable) return (NSInteger)[_query attributeNames].count;
  return 0;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  return [self queryValueIn:table column:column row:row];
}

- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  [self setQueryValue:value in:table column:column row:row];
}

- (BOOL)tableView:(NSTableView *)table shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _selectTable) return [column.identifier isEqualToString:@"include"];
  return YES;
}

#pragma mark NSOutlineViewDataSource (relationships to prefetch)

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

@end
