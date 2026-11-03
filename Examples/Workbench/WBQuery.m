// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBQuery.h"
#import "WorkbenchSupport.h"

// Presets: entity, predicate, sort key, ascending, $expand, result type,
// and a limit.
static NSDictionary *WBPreset(NSString *label, NSString *entity, NSString *predicate, NSString *sort, BOOL asc,
                              NSString *expand, NSString *type, NSString *limit)
{
  return @{ @"label": label, @"entity": entity, @"predicate": predicate ?: @"", @"sort": sort ?: @"", @"asc": @(asc),
            @"expand": expand ?: @"", @"type": type ?: @"objects", @"limit": limit ?: @"" };
}

// The same, with more of what the query panel says (compute, time).
static NSDictionary *WBPresetMore(NSDictionary *preset, NSDictionary *more)
{
  NSMutableDictionary *all = [preset mutableCopy];
  [all addEntriesFromDictionary:more];
  return all;
}

// The same, with $search, or grouped: key paths and aggregates.
static NSDictionary *WBPresetWith(NSDictionary *preset, NSString *search, NSString *group, NSString *aggregate)
{
  NSMutableDictionary *more = [preset mutableCopy];
  more[@"search"] = search ?: @"";
  more[@"group"] = group ?: @"";
  more[@"aggregate"] = aggregate ?: @"";
  return more;
}

// The predicate field: NSPredicate's syntax, with the hierarchy tests of
// Data Aggregation (ODataHierarchyPredicate) as functions of their own,
// among the rest:
//   ISDESCENDANT(SalesOrgHierarchy, 'EMEA')
//   ISANCESTOR(SalesOrgHierarchy, 'US East', SELF)          and itself
//   ISDESCENDANT(SalesOrgHierarchy, 'Sales', 1)              within 1
//   ISDESCENDANT(SalesOrgHierarchy, 'US', salesOrganization.id)  a related node
//   ISNODE, ISROOT, ISLEAF(SalesOrgHierarchy); ISSIBLING(SalesOrgHierarchy, 'US')
static NSArray<NSString *> *WBArguments(NSString *text)
{
  NSMutableArray *arguments = [NSMutableArray array];
  NSMutableString *current = [NSMutableString string];
  unichar quote = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (quote) {
      if (c == quote) quote = 0;
    } else if (c == '\'' || c == '"') {
      quote = c;
    } else if (c == ',') {
      [arguments addObject:[current stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
      [current setString:@""];
      continue;
    }
    [current appendFormat:@"%C", c];
  }
  [arguments addObject:[current stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
  return arguments;
}

static NSPredicate *WBHierarchyPredicate(NSString *function, NSString *inside, NSError **error)
{
  NSDictionary *tests = @{ @"ISNODE": @(ODataHierarchyIsNode), @"ISROOT": @(ODataHierarchyIsRoot), @"ISLEAF": @(ODataHierarchyIsLeaf),
                           @"ISANCESTOR": @(ODataHierarchyIsAncestor), @"ISDESCENDANT": @(ODataHierarchyIsDescendant),
                           @"ISSIBLING": @(ODataHierarchyIsSibling) };
  ODataHierarchyTest test = [tests[function.uppercaseString] integerValue];
  NSArray<NSString *> *arguments = WBArguments(inside);
  BOOL related = test == ODataHierarchyIsAncestor || test == ODataHierarchyIsDescendant || test == ODataHierarchyIsSibling;
  if (!arguments.firstObject.length || (related && arguments.count < 2)) {
    if (error) *error = WBError(9, [NSString stringWithFormat:@"%@: the hierarchy's qualifier%@", function, related ? @", and a node" : @""]);
    return nil;
  }
  id node = nil;
  NSUInteger next = 1;
  if (related) {
    NSString *text = arguments[1];
    if (text.length >= 2 && ([text hasPrefix:@"'"] || [text hasPrefix:@"\""])) {
      node = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    } else {
      NSScanner *scanner = [NSScanner scannerWithString:text];
      long long integer = 0;
      node = [scanner scanLongLong:&integer] && scanner.isAtEnd ? @(integer) : text;
    }
    next = 2;
  }
  NSString *keyPath = nil;
  NSUInteger distance = 0;
  BOOL includeSelf = NO;
  for (NSUInteger i = next; i < arguments.count; i++) {
    NSString *argument = arguments[i];
    if ([argument caseInsensitiveCompare:@"SELF"] == NSOrderedSame) includeSelf = YES;
    else if (argument.integerValue > 0) distance = (NSUInteger)argument.integerValue;
    else if (argument.length) keyPath = argument;
  }
  return [ODataHierarchyPredicate predicateWithTest:test hierarchy:arguments[0] node:node nodeKeyPath:keyPath maxDistance:distance includeSelf:includeSelf];
}

// Each $__wbhN == 1 the text stood in for, as its hierarchy predicate.
static NSPredicate *WBReplacingPlaceholders(NSPredicate *predicate, NSArray *hierarchies)
{
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    NSCompoundPredicate *compound = (NSCompoundPredicate *)predicate;
    NSMutableArray *subpredicates = [NSMutableArray array];
    for (NSPredicate *sub in compound.subpredicates) [subpredicates addObject:WBReplacingPlaceholders(sub, hierarchies)];
    return [[NSCompoundPredicate alloc] initWithType:compound.compoundPredicateType subpredicates:subpredicates];
  }
  if ([predicate isKindOfClass:[NSComparisonPredicate class]]) {
    NSExpression *left = ((NSComparisonPredicate *)predicate).leftExpression;
    if (left.expressionType == NSVariableExpressionType && [left.variable hasPrefix:@"__wbh"]) {
      NSUInteger index = (NSUInteger)[[left.variable substringFromIndex:5] integerValue];
      if (index < hierarchies.count) return hierarchies[index];
    }
  }
  return predicate;
}

static NSPredicate *WBPredicate(NSString *format, NSError **error)
{
  NSRegularExpression *call = [NSRegularExpression regularExpressionWithPattern:@"\\b(IS(?:NODE|ROOT|LEAF|ANCESTOR|DESCENDANT|SIBLING))\\s*\\(([^()]*)\\)"
                                                                        options:NSRegularExpressionCaseInsensitive error:NULL];
  NSArray<NSTextCheckingResult *> *matches = [call matchesInString:format options:0 range:NSMakeRange(0, format.length)];
  NSMutableArray *hierarchies = [NSMutableArray array];
  NSMutableString *text = [format mutableCopy];
  for (NSTextCheckingResult *match in matches) {
    NSPredicate *hierarchy = WBHierarchyPredicate([format substringWithRange:[match rangeAtIndex:1]], [format substringWithRange:[match rangeAtIndex:2]], error);
    if (!hierarchy) return nil;
    [hierarchies addObject:hierarchy];
  }
  for (NSUInteger i = matches.count; i > 0; i--) {
    [text replaceCharactersInRange:matches[i - 1].range withString:[NSString stringWithFormat:@"$__wbh%lu == 1", (unsigned long)(i - 1)]];
  }
  NSPredicate *predicate = nil;
  @try {
    predicate = [NSPredicate predicateWithFormat:text];
  } @catch (NSException *ex) {
    if (error) *error = WBError(1, ex.reason ?: @"bad predicate");
    return nil;
  }
  return hierarchies.count ? WBReplacingPlaceholders(predicate, hierarchies) : predicate;
}

static NSArray *WBKnownPresets(WBService service)
{
  switch (service) {
    case WBServiceBuiltIn:
      return @[
        WBPreset(@"All products", @"Product", nil, @"name", YES, nil, nil, nil),
        WBPreset(@"Priced over 20", @"Product", @"unitPrice > 20 AND discontinued == NO", @"unitPrice", NO, nil, nil, nil),
        WBPreset(@"Beverages + category", @"Product", @"category.name == \"Beverages\"", @"name", YES, @"category", nil, nil),
        WBPreset(@"Top 5 dictionary", @"Product", nil, @"unitPrice", NO, nil, @"dictionary", @"5"),
        WBPreset(@"Count discontinued", @"Product", @"discontinued == YES", @"id", YES, nil, @"count", nil),
        WBPreset(@"Name begins with C", @"Product", @"name BEGINSWITH[c] \"c\"", @"name", YES, nil, nil, nil),
        WBPreset(@"UK suppliers", @"Supplier", @"country == \"UK\"", @"companyName", YES, @"products", nil, nil),
        WBPreset(@"Stock on hand", @"Stock", @"quantity > 10", @"quantity", NO, @"location", nil, nil),
        WBPreset(@"Suppliers of pricey things (any)", @"Supplier", @"ANY products.unitPrice > 30", @"companyName", YES, nil, nil, nil),
        WBPreset(@"Stock in London (a path)", @"Stock", @"location.city == \"London\" AND product.discontinued == NO", @"quantity", NO, @"product", nil, nil),
        WBPreset(@"Chosen products (in)", @"Product", @"name IN {\"Chai\", \"Tofu\", \"Ikura\"}", @"name", YES, nil, nil, nil),
        WBPreset(@"By category, then price; nested prefetch", @"Product", nil, @"category.name, unitPrice desc", YES,
                 @"category, suppliers.products", nil, nil),
        WBPresetWith(WBPreset(@"Search: jars OR cote", @"Product", @"discontinued == NO", @"name", YES, nil, nil, nil),
                     @"jars OR cote", nil, nil),
        WBPresetWith(WBPreset(@"Grouped by category: count, total, dearest", @"Product", nil, @"category.name", YES, nil, @"dictionary", nil),
                     nil, @"category.name", @"count:(id) as products, sum:(unitPrice) as total, max:(unitPrice) as dearest"),
        WBPresetMore(WBPreset(@"Computed: price with tax ($compute)", @"Product", nil, @"name", YES, nil, @"dictionary", nil),
                     @{ @"compute": @"unitPrice * 1.2 as withTax" }),
        WBPresetMore(WBPreset(@"Budgets on 2024-10-01 (application time, $at)", @"Budget", nil, @"category", YES, nil, nil, nil),
                     @{ @"time": @"2024-10-01" }),
        WBPresetMore(WBPreset(@"Budgets during 2024 ($from, $to)", @"Budget", nil, @"category, from", YES, nil, nil, nil),
                     @{ @"time": @"2024-01-01..2025-01-01" }),
        WBPreset(@"Budgets over time (Temporal actions)", @"Budget", nil, @"category, from", YES, nil, nil, nil),
        WBPreset(@"Pictures (a media entity: Download, Upload)", @"Picture", nil, @"id", YES, nil, nil, nil),
        WBPreset(@"Equipment (an open type: dynamic properties)", @"EquipmentUnit", nil, @"name", YES, @"location", nil, nil),
        WBPreset(@"Forklifts over 2 t (a dynamic property, filtered here)", @"EquipmentUnit",
                 @"kind == \"Forklift\" AND dynamicProperties.LoadCapacityKg > 2000", @"name", YES, nil, nil, nil),
        WBPreset(@"Categories over 90 in all (aggregate())", @"Category", @"products.@sum.unitPrice > 90", @"name", YES, @"products", nil, nil),
        WBPreset(@"Hierarchy: below EMEA (isdescendant)", @"SalesOrganization", @"ISDESCENDANT(SalesOrgHierarchy, 'EMEA')", @"id", YES,
                 @"superordinate", nil, nil),
        WBPreset(@"Hierarchy: US East and above (isancestor)", @"SalesOrganization", @"ISANCESTOR(SalesOrgHierarchy, 'US East', SELF)", @"id", YES,
                 @"superordinate", nil, nil),
        WBPreset(@"Hierarchy: the leaves in the US (isleaf)", @"SalesOrganization", @"ISLEAF(SalesOrgHierarchy) AND id BEGINSWITH \"US\"", @"id", YES,
                 nil, nil, nil),
        WBPreset(@"Hierarchy: sales anywhere below US (a related node)", @"Sale",
                 @"ISDESCENDANT(SalesOrgHierarchy, 'US', salesOrganization.id)", @"id", YES, @"salesOrganization", nil, nil),
        WBPreset(@"As written: the tree in preorder ($apply=traverse)", @"SalesOrganization",
                 @"$apply=traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder,Name asc)&$expand=Superordinate", nil, YES, nil, nil, nil),
        WBPreset(@"As written: totals in tree order (dictionaries)", @"Sale",
                 @"$apply=groupby((SalesOrganization/ID),aggregate(Amount with sum as Total))"
                 @"/traverse($root/SalesOrganizations,SalesOrgHierarchy,SalesOrganization/ID,preorder)", nil, YES, nil, @"dictionary", nil),
        WBPresetWith(WBPreset(@"Sales by organization (grouped)", @"Sale", nil, @"salesOrganization.name", YES, nil, @"dictionary", nil),
                     nil, @"salesOrganization.name", @"sum:(amount) as total, count:(id) as sales"),
      ];
    case WBServiceNorthwind:
      return @[
        WBPreset(@"All products", @"Product", nil, @"productName", YES, nil, nil, nil),
        WBPreset(@"Priced over 20", @"Product", @"unitPrice > 20 AND discontinued == NO", @"unitPrice", NO, nil, nil, nil),
        WBPreset(@"Beverages + category", @"Product", @"category.categoryName == \"Beverages\"", @"productName", YES, @"category", nil, nil),
        WBPreset(@"Top 5 dictionary", @"Product", nil, @"unitPrice", NO, nil, @"dictionary", @"5"),
        WBPreset(@"Count discontinued", @"Product", @"discontinued == YES", @"productID", YES, nil, @"count", nil),
        WBPreset(@"Ordered 100 at once (any)", @"Product", @"ANY order_Details.quantity >= 100", @"productName", YES, nil, nil, nil),
        WBPreset(@"Orders of ALFKI", @"Order", @"customerID == \"ALFKI\"", @"orderDate", YES, @"customer", nil, nil),
        WBPreset(@"UK suppliers", @"Supplier", @"country == \"UK\"", @"companyName", YES, @"products", nil, nil),
        WBPreset(@"Latest orders, with lines and products", @"Order", nil, @"orderDate desc, orderID", YES,
                 @"customer, order_Details.product", nil, @"10"),
        WBPresetWith(WBPreset(@"Grouped by category (no $apply: grouped here)", @"Product", nil, @"category.categoryName", YES, nil, @"dictionary", nil),
                     nil, @"category.categoryName", @"count:(productID) as products, average:(unitPrice) as meanPrice"),
      ];
    case WBServiceTripPin:
      return @[
        WBPreset(@"All people", @"Person", nil, @"userName", YES, nil, nil, nil),
        WBPreset(@"Women (an enumeration)", @"Person", @"gender == \"Female\"", @"lastName", YES, nil, nil, nil),
        WBPreset(@"Lives in Boise (any, complex)", @"Person", @"ANY addressInfo.city.name == \"Boise\"", @"userName", YES, nil, nil, nil),
        WBPreset(@"E-mail at example.com", @"Person", @"ANY emails ENDSWITH \"example.com\"", @"userName", YES, nil, nil, nil),
        WBPreset(@"Airports in San Francisco", @"Airport", @"location.city.name == \"San Francisco\"", @"name", YES, nil, nil, nil),
        WBPreset(@"All airlines", @"Airline", nil, @"name", YES, nil, nil, nil),
        WBPreset(@"Count people", @"Person", nil, @"userName", YES, nil, @"count", nil),
        WBPreset(@"Top 3 dictionary", @"Person", nil, @"lastName", YES, nil, @"dictionary", @"3"),
        WBPreset(@"People, their photos, their friends' photos", @"Person", nil, @"lastName, firstName", YES, @"photo, friends.photo", nil, nil),
        WBPreset(@"Photos (media entities: Download, Upload)", @"Photo", nil, @"id", YES, nil, nil, nil),
        WBPresetWith(WBPreset(@"Search: Russell", @"Person", nil, @"userName", YES, nil, nil, nil), @"Russell", nil, nil),
        WBPresetWith(WBPreset(@"Search airports: Los, ICAO K…", @"Airport", @"icaoCode BEGINSWITH \"K\"", @"name", YES, nil, nil, nil), @"Los", nil, nil),
        WBPresetWith(WBPreset(@"Grouped by gender", @"Person", nil, @"gender", YES, nil, @"dictionary", nil), nil, @"gender", @"count:(userName) as people"),
      ];
    case WBServiceOther:
      return @[];
  }
  return @[];
}

@implementation WBQuery

+ (NSArray *)presetsForService:(WBService)service model:(NSManagedObjectModel *)model
{
  NSArray *known = WBKnownPresets(service);
  if (known.count) return known;
  // Another service: the first few entity sets, whole.
  NSMutableArray *generic = [NSMutableArray array];
  NSArray *names = [[model.entitiesByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSEntityDescription *entity = model.entitiesByName[name];
    if (entity.superentity || entity.isAbstract) continue;
    [generic addObject:WBPreset([NSString stringWithFormat:@"All %@", name], name, nil, WBColumnNames(entity, NO).firstObject, YES, nil, nil, @"50")];
    if (generic.count == 12) break;
  }
  return generic;
}

- (instancetype)initWithModel:(NSManagedObjectModel *)model builtIn:(BOOL)builtIn
{
  if (!(self = [super init])) return nil;
  _model = model;
  _builtIn = builtIn;
  _resultType = NSManagedObjectResultType;
  _predicateText = _limitText = _skipText = _pageSizeText = @"";
  _searchText = _computeText = _groupText = _aggregateText = _timeText = @"";
  _includesSubentities = YES;
  _sorts = [NSMutableArray array];
  _prefetch = [NSMutableSet set];
  _select = [NSMutableSet set];
  return self;
}

#pragma mark The model

- (NSArray *)entityNames
{
  NSMutableArray *names = [NSMutableArray array];
  for (NSEntityDescription *e in _configurationName ? [_model entitiesForConfiguration:_configurationName] : _model.entities) {
    if (e.name) [names addObject:e.name];
  }
  return [names sortedArrayUsingSelector:@selector(compare:)];
}

- (NSEntityDescription *)entity
{
  return (_entityName ? _model.entitiesByName[_entityName] : nil) ?: _model.entitiesByName[[self entityNames].firstObject];
}

- (NSArray *)attributeNames
{
  return [[[self entity].attributesByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray *)columnNamesFor:(NSEntityDescription *)entity
{
  return WBColumnNames(entity, _builtIn);
}

- (BOOL)hasApplicationTime
{
  NSEntityDescription *entity = [self entity];
  while (entity.superentity) entity = entity.superentity;
  return entity.userInfo[ODataUserInfoPeriodStart] != nil;
}

// The relationships a fetch of objects prefetches, each a column of its
// own: what came with the rows.
- (NSArray *)prefetchedRelationshipNames
{
  NSMutableArray *names = [NSMutableArray array];
  for (NSString *path in [_prefetch.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *first = [path componentsSeparatedByString:@"."].firstObject;
    if ([self entity].relationshipsByName[first] && ![names containsObject:first]) [names addObject:first];
  }
  return names;
}

- (NSArray *)columnNames
{
  NSArray *computed = _resultType == NSDictionaryResultType ? [self computedDescriptionsError:NULL] : nil;
  if (computed.count && ![self groupPaths].count && ![self aggregateTexts].count) {
    NSArray *base = _select.count ? [_select.allObjects sortedArrayUsingSelector:@selector(compare:)] : [self columnNamesFor:[self entity]];
    return [base arrayByAddingObjectsFromArray:[computed valueForKey:@"name"]];
  }
  if (_resultType == NSDictionaryResultType && ([self groupPaths].count || [self aggregateTexts].count)) {
    NSMutableArray *names = [[self groupPaths] mutableCopy];
    for (NSExpressionDescription *description in [self aggregateDescriptionsError:NULL] ?: @[]) [names addObject:description.name];
    return names;
  }
  if (_resultType == NSDictionaryResultType && _select.count) {
    return [_select.allObjects sortedArrayUsingSelector:@selector(compare:)];
  }
  NSArray *columns = [self columnNamesFor:[self entity]];
  if (_resultType == NSManagedObjectResultType) columns = [columns arrayByAddingObjectsFromArray:[self prefetchedRelationshipNames]];
  return columns;
}

- (BOOL)keyPathLeadsToAnAttribute:(NSString *)keyPath
{
  NSEntityDescription *entity = [self entity];
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  for (NSUInteger i = 0; i < parts.count; i++) {
    if (i == parts.count - 1) return entity.attributesByName[parts[i]] != nil;
    NSRelationshipDescription *rel = entity.relationshipsByName[parts[i]];
    if (!rel || rel.isToMany) return NO;
    entity = rel.destinationEntity;
  }
  return NO;
}

#pragma mark Grouping and computing

// Comma-separated, trimmed, none empty.
static NSArray *WBItems(NSString *text)
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *item in [text componentsSeparatedByString:@","]) {
    NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length) [items addObject:trimmed];
  }
  return items;
}

// group by: key paths, through to-one relationships (category.name).
- (NSArray *)groupPaths
{
  return WBItems(_groupText);
}

- (NSArray *)aggregateTexts
{
  return WBItems(_aggregateText);
}

// aggregate: sum:(unitPrice) as total, count:(id) as products, as Core
// Data's functions are named; each an expression description.
- (NSArray *)aggregateDescriptionsError:(NSError **)error
{
  NSRegularExpression *form = [NSRegularExpression regularExpressionWithPattern:@"^(sum|min|max|average|count):?\\s*\\(\\s*([A-Za-z_][\\w.]*)\\s*\\)(?:\\s+as\\s+([A-Za-z_]\\w*))?$"
                                                                        options:NSRegularExpressionCaseInsensitive error:NULL];
  NSMutableArray *descriptions = [NSMutableArray array];
  for (NSString *text in [self aggregateTexts]) {
    NSTextCheckingResult *match = [form firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    NSString *path = match ? [text substringWithRange:[match rangeAtIndex:2]] : nil;
    if (!match || ![self keyPathLeadsToAnAttribute:path]) {
      if (error) *error = WBError(5, [NSString stringWithFormat:@"Cannot aggregate \"%@\": write sum:(unitPrice) as total, with sum, min, max, average or count, of an attribute", text]);
      return nil;
    }
    NSString *function = [[text substringWithRange:[match rangeAtIndex:1]] lowercaseString];
    NSRange alias = [match rangeAtIndex:3];
    NSExpressionDescription *description = [[NSExpressionDescription alloc] init];
    description.name = alias.location != NSNotFound ? [text substringWithRange:alias]
                                                     : [NSString stringWithFormat:@"%@_%@", function, [path stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
    description.expression = [NSExpression expressionForFunction:[function stringByAppendingString:@":"]
                                                       arguments:@[ [NSExpression expressionForKeyPath:path] ]];
    NSEntityDescription *entity = [self entity];
    NSArray *parts = [path componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i + 1 < parts.count; i++) entity = [entity.relationshipsByName[parts[i]] destinationEntity];
    NSAttributeType type = [entity.attributesByName[parts.lastObject] attributeType];
    if ([function isEqualToString:@"count"]) type = NSInteger64AttributeType;
    else if ([function isEqualToString:@"average"]) type = NSDoubleAttributeType;
    description.expressionResultType = type;
    [descriptions addObject:description];
  }
  return descriptions;
}

// compute: NSExpression formats, each with its name: unitPrice * 2 as twice.
- (NSArray *)computedDescriptionsError:(NSError **)error
{
  NSMutableArray *descriptions = [NSMutableArray array];
  NSString *text = _computeText ?: @"";
  NSMutableArray *items = [NSMutableArray array];
  NSInteger depth = 0, start = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == ',' && depth == 0) {
      [items addObject:[text substringWithRange:NSMakeRange((NSUInteger)start, i - (NSUInteger)start)]];
      start = (NSInteger)i + 1;
    }
  }
  [items addObject:[text substringFromIndex:(NSUInteger)start]];
  NSRegularExpression *form = [NSRegularExpression regularExpressionWithPattern:@"^(.*\\S)\\s+as\\s+([A-Za-z_]\\w*)$" options:0 error:NULL];
  for (NSString *item in items) {
    NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!trimmed.length) continue;
    NSTextCheckingResult *match = [form firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    NSExpression *expression = nil;
    @try {
      expression = match ? [NSExpression expressionWithFormat:[trimmed substringWithRange:[match rangeAtIndex:1]]] : nil;
    } @catch (NSException *exception) {
      expression = nil;
    }
    if (!expression) {
      if (error) *error = WBError(7, [NSString stringWithFormat:@"Cannot compute \"%@\": write an expression as a name, unitPrice * 2 as twice", trimmed]);
      return nil;
    }
    NSExpressionDescription *description = [[NSExpressionDescription alloc] init];
    description.name = [trimmed substringWithRange:[match rangeAtIndex:2]];
    description.expression = expression;
    // Decimal where a decimal goes into it, else a double.
    NSAttributeType type = NSDoubleAttributeType;
    for (NSAttributeDescription *attribute in [self entity].attributesByName.allValues) {
      if (attribute.attributeType == NSDecimalAttributeType && [trimmed rangeOfString:attribute.name].location != NSNotFound) type = NSDecimalAttributeType;
    }
    description.expressionResultType = type;
    [descriptions addObject:description];
  }
  return descriptions;
}

// A day ($at), a..b ($from, $to), a..=b ($from, $toInclusive), or a..
// ($from alone), on an entity with application time.
- (NSPredicate *)applicationTimePredicate:(NSString *)text error:(NSError **)error
{
  NSString *problem = nil;
  NSPredicate *predicate = nil;
  if (![self hasApplicationTime]) {
    problem = [NSString stringWithFormat:@"%@ has no application time", [self entity].name];
  } else if ([text rangeOfString:@".."].location == NSNotFound) {
    NSDate *at = WBDate(text);
    if (at) predicate = [ODataTemporalPredicate predicateAt:at];
  } else {
    NSRange dots = [text rangeOfString:@".."];
    NSString *rest = [text substringFromIndex:NSMaxRange(dots)];
    BOOL inclusive = [rest hasPrefix:@"="];
    if (inclusive) rest = [rest substringFromIndex:1];
    NSDate *from = WBDate([text substringToIndex:dots.location]);
    NSDate *to = rest.length ? WBDate(rest) : nil;
    if (from && (to || !rest.length)) {
      predicate = inclusive ? [ODataTemporalPredicate predicateFrom:from toInclusive:to] : [ODataTemporalPredicate predicateFrom:from to:to];
    }
  }
  if (!predicate && error) {
    *error = WBError(8, problem ?: [NSString stringWithFormat:@"Application time \"%@\": a day (2024-10-01), or from..to, from..=to, from..", text]);
  }
  return predicate;
}

#pragma mark The request

- (BOOL)isVerbatim
{
  return [[_predicateText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] hasPrefix:@"$"];
}

// name=value&name=value, split where & is outside quotes and parentheses.
- (ODataQuery *)verbatimQueryInContext:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSString *text = [_predicateText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSMutableArray *parts = [NSMutableArray array];
  NSInteger depth = 0;
  BOOL quoted = NO;
  NSUInteger start = 0;
  for (NSUInteger i = 0; i <= text.length; i++) {
    unichar c = i < text.length ? [text characterAtIndex:i] : '&';
    if (c == '\'') quoted = !quoted;
    if (quoted) continue;
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == '&' && depth == 0) {
      [parts addObject:[text substringWithRange:NSMakeRange(start, i - start)]];
      start = i + 1;
    }
  }
  NSMutableDictionary *options = [NSMutableDictionary dictionary];
  for (NSString *part in parts) {
    NSRange equals = [part rangeOfString:@"="];
    NSString *name = equals.location == NSNotFound ? nil : [part substringToIndex:equals.location];
    if (!name.length) {
      if (error) *error = WBError(10, [NSString stringWithFormat:@"\"%@\" is no query option: $name=value", part]);
      return nil;
    }
    options[[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]] = [part substringFromIndex:NSMaxRange(equals)];
  }
  ODataQuery *query = [ODataQuery queryOfEntity:[self entity].name inContext:context];
  query.options = options;
  query.resultType = _resultType == NSDictionaryResultType ? NSDictionaryResultType : NSManagedObjectResultType;
  return query;
}

- (NSFetchRequest *)fetchRequestError:(NSError **)error
{
  NSEntityDescription *entity = [self entity];
  if (!entity) {
    if (error) *error = WBError(2, @"Not connected.");
    return nil;
  }
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity.name];
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  NSString *format = [_predicateText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (format.length) {
    request.predicate = WBPredicate(format, error);
    if (!request.predicate) return nil;
  }
  // Application time: a day ($at), or from..to ($from and $to), ..= to
  // include the end.
  NSString *time = [_timeText stringByTrimmingCharactersInSet:space];
  if (time.length) {
    NSPredicate *period = [self applicationTimePredicate:time error:error];
    if (!period) return nil;
    request.predicate = request.predicate ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ period, request.predicate ]] : period;
  }
  // $search: the service's own, ANDed with the predicate.
  NSString *search = [_searchText stringByTrimmingCharactersInSet:space];
  if (search.length) {
    NSPredicate *searching = [ODataSearchPredicate predicateWithSearch:search];
    request.predicate = request.predicate ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ searching, request.predicate ]] : searching;
  }
  NSMutableArray *sorts = [NSMutableArray array];
  for (NSDictionary *sort in _sorts) {
    NSString *key = [sort[@"key"] stringByTrimmingCharactersInSet:space];
    if (!key.length) continue;
    if (![self keyPathLeadsToAnAttribute:key]) {
      if (error) *error = WBError(3, [NSString stringWithFormat:@"Cannot sort by %@: not an attribute, or through to-one relationships to one", key]);
      return nil;
    }
    [sorts addObject:[NSSortDescriptor sortDescriptorWithKey:key ascending:![sort[@"descending"] boolValue]]];
  }
  request.sortDescriptors = sorts;
  if (_limitText.length) request.fetchLimit = (NSUInteger)[_limitText integerValue];
  if (_skipText.length) request.fetchOffset = (NSUInteger)[_skipText integerValue];
  if (_pageSizeText.length) request.fetchBatchSize = (NSUInteger)[_pageSizeText integerValue];
  request.includesSubentities = _includesSubentities;
  request.relationshipKeyPathsForPrefetching = [_prefetch.allObjects sortedArrayUsingSelector:@selector(compare:)];
  request.resultType = _resultType;
  request.returnsObjectsAsFaults = _returnsObjectsAsFaults;
  if (request.resultType == NSDictionaryResultType) {
    NSArray *aggregates = [self aggregateDescriptionsError:error];
    if (!aggregates) return nil;
    NSArray *groups = [self groupPaths];
    for (NSString *path in groups) {
      if (![self keyPathLeadsToAnAttribute:path]) {
        if (error) *error = WBError(4, [NSString stringWithFormat:@"Cannot group by %@: not an attribute, or through to-one relationships to one", path]);
        return nil;
      }
    }
    NSArray *computed = [self computedDescriptionsError:error];
    if (!computed) return nil;
    if ((groups.count || aggregates.count) && computed.count) {
      if (error) *error = WBError(6, @"compute is for rows, group by and aggregate for groups: one or the other");
      return nil;
    }
    if (groups.count || aggregates.count) {
      // Grouped ($apply=groupby((...),aggregate(...))): the groups' values and the aggregates.
      if (groups.count) request.propertiesToGroupBy = groups;
      request.propertiesToFetch = [groups arrayByAddingObjectsFromArray:aggregates];
    } else if (computed.count) {
      // Computed from each row ($compute, where the service has it).
      NSArray *base = _select.count ? [_select.allObjects sortedArrayUsingSelector:@selector(compare:)] : [self columnNamesFor:entity];
      request.propertiesToFetch = [base arrayByAddingObjectsFromArray:computed];
    } else {
      request.propertiesToFetch = [self columnNames];
    }
  }
  return request;
}

#pragma mark Changing it

- (void)reset
{
  // The grouping first: while there is one, the columns are its keys, and
  // a sort by one would outlive it.
  _searchText = _computeText = _groupText = _aggregateText = _timeText = @"";
  [_prefetch removeAllObjects];
  [_select removeAllObjects];
  [_sorts removeAllObjects];
  NSString *first = [self columnNames].firstObject;
  if (first) [_sorts addObject:[@{ @"key": first, @"descending": @NO } mutableCopy]];
}

#pragma mark As a property list

static NSString *WBTypeName(NSFetchRequestResultType type)
{
  return type == NSCountResultType ? @"count" : type == NSDictionaryResultType ? @"dictionary"
       : type == NSManagedObjectIDResultType ? @"object IDs" : @"objects";
}

- (NSDictionary *)dictionary
{
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  if (_entityName.length) d[@"entity"] = _entityName;
  if (_resultType != NSManagedObjectResultType) d[@"type"] = WBTypeName(_resultType);
  NSDictionary *texts = @{ @"predicate": _predicateText ?: @"", @"limit": _limitText ?: @"", @"skip": _skipText ?: @"",
                           @"pageSize": _pageSizeText ?: @"", @"search": _searchText ?: @"", @"compute": _computeText ?: @"",
                           @"group": _groupText ?: @"", @"aggregate": _aggregateText ?: @"", @"time": _timeText ?: @"" };
  [texts enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *text, BOOL *stop) {
    if (text.length) d[key] = text;
  }];
  NSMutableArray *sorts = [NSMutableArray array];
  for (NSDictionary *sort in _sorts) {
    if ([sort[@"key"] length]) [sorts addObject:@{ @"key": sort[@"key"], @"descending": @([sort[@"descending"] boolValue]) }];
  }
  if (sorts.count) d[@"sort"] = sorts;
  if (_prefetch.count) d[@"expand"] = [_prefetch.allObjects sortedArrayUsingSelector:@selector(compare:)];
  if (_select.count) d[@"select"] = [_select.allObjects sortedArrayUsingSelector:@selector(compare:)];
  if (!_includesSubentities) d[@"subentities"] = @NO;
  if (_returnsObjectsAsFaults) d[@"faults"] = @YES;
  return d;
}

- (void)takeDictionary:(NSDictionary *)d
{
  id (^text)(NSString *) = ^id(NSString *key) {
    return [d[key] isKindOfClass:[NSString class]] ? [d[key] copy] : @"";
  };
  _entityName = [d[@"entity"] isKindOfClass:[NSString class]] ? [d[@"entity"] copy] : nil;
  NSString *type = text(@"type");
  _resultType = [type isEqualToString:@"count"] ? NSCountResultType
              : [type isEqualToString:@"dictionary"] ? NSDictionaryResultType
              : [type isEqualToString:@"object IDs"] ? NSManagedObjectIDResultType : NSManagedObjectResultType;
  _predicateText = text(@"predicate");
  _limitText = text(@"limit");
  _skipText = text(@"skip");
  _pageSizeText = text(@"pageSize");
  _searchText = text(@"search");
  _computeText = text(@"compute");
  _groupText = text(@"group");
  _aggregateText = text(@"aggregate");
  _timeText = text(@"time");
  [_sorts removeAllObjects];
  for (NSDictionary *sort in [d[@"sort"] isKindOfClass:[NSArray class]] ? d[@"sort"] : @[]) {
    if (![sort isKindOfClass:[NSDictionary class]] || ![sort[@"key"] isKindOfClass:[NSString class]]) continue;
    [_sorts addObject:[@{ @"key": sort[@"key"], @"descending": @([sort[@"descending"] boolValue]) } mutableCopy]];
  }
  [_prefetch removeAllObjects];
  for (id path in [d[@"expand"] isKindOfClass:[NSArray class]] ? d[@"expand"] : @[]) {
    if ([path isKindOfClass:[NSString class]]) [_prefetch addObject:path];
  }
  [_select removeAllObjects];
  for (id name in [d[@"select"] isKindOfClass:[NSArray class]] ? d[@"select"] : @[]) {
    if ([name isKindOfClass:[NSString class]]) [_select addObject:name];
  }
  _includesSubentities = d[@"subentities"] ? [d[@"subentities"] boolValue] : YES;
  _returnsObjectsAsFaults = [d[@"faults"] boolValue];
}

- (void)applyPreset:(NSDictionary *)p
{
  _entityName = [p[@"entity"] copy];
  NSString *type = p[@"type"];
  _resultType = [type isEqualToString:@"count"] ? NSCountResultType
              : [type isEqualToString:@"dictionary"] ? NSDictionaryResultType : NSManagedObjectResultType;
  [self reset];
  _predicateText = [p[@"predicate"] copy] ?: @"";
  [_sorts removeAllObjects];
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  for (NSString *item in [p[@"sort"] componentsSeparatedByString:@","]) {
    NSArray *words = [[item stringByTrimmingCharactersInSet:space] componentsSeparatedByString:@" "];
    if (![words.firstObject length]) continue;
    BOOL descending = words.count > 1 ? [words.lastObject isEqualToString:@"desc"] : ![p[@"asc"] boolValue];
    [_sorts addObject:[@{ @"key": words.firstObject, @"descending": @(descending) } mutableCopy]];
  }
  _limitText = [p[@"limit"] copy] ?: @"";
  _skipText = @"";
  for (NSString *path in WBItems(p[@"expand"] ?: @"")) [_prefetch addObject:path];
  _searchText = [p[@"search"] copy] ?: @"";
  _computeText = [p[@"compute"] copy] ?: @"";
  _groupText = [p[@"group"] copy] ?: @"";
  _aggregateText = [p[@"aggregate"] copy] ?: @"";
  _timeText = [p[@"time"] copy] ?: @"";
}

- (void)addSort
{
  NSSet *used = [NSSet setWithArray:[_sorts valueForKey:@"key"]];
  NSString *next = @"";
  for (NSString *name in [self columnNames]) {
    if (![used containsObject:name]) {
      next = name;
      break;
    }
  }
  [_sorts addObject:[@{ @"key": next, @"descending": @NO } mutableCopy]];
}

- (void)removeSortAtRow:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _sorts.count) row = (NSInteger)_sorts.count - 1;
  if (row < 0) return;
  [_sorts removeObjectAtIndex:(NSUInteger)row];
}

- (NSInteger)moveSortAtRow:(NSInteger)row by:(NSInteger)step
{
  NSInteger to = row + step;
  if (row < 0 || to < 0 || (NSUInteger)row >= _sorts.count || (NSUInteger)to >= _sorts.count) return -1;
  id item = _sorts[(NSUInteger)row];
  [_sorts removeObjectAtIndex:(NSUInteger)row];
  [_sorts insertObject:item atIndex:(NSUInteger)to];
  return to;
}

- (void)setPrefetch:(NSString *)path included:(BOOL)included
{
  if (included) {
    [_prefetch addObject:path];
    return;
  }
  for (NSString *prefetched in [_prefetch allObjects]) {
    if ([prefetched isEqualToString:path] || [prefetched hasPrefix:[path stringByAppendingString:@"."]]) [_prefetch removeObject:prefetched];
  }
}

@end
