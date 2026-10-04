// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A read's plan (docs/query-plan.md): made from the parsed request, the
// store's part rewritten into store operators, then run.

#import "ODataServiceInternal.h"
#import "OISPlan.h"

// How many parents one fetch of their members names (an IN list of bound
// parameters, which SQLite and FreeCoreData's SQL stores limit).
static const NSUInteger OISNestBatch = 500;

// $levels=max is taken as this deep (Part 2 section 5.1.3.1).
static const NSInteger OISNestMaxLevels = 32;

static NSString *OISKeyOf(OISPlanNode *node, NSString *scope)
{
  return [NSString stringWithFormat:@"%p/%@", (void *)node, scope ?: @""];
}

static NSManagedObject *OISObjectOfRow(id row)
{
  if ([row isKindOfClass:[OISComputedRow class]]) return ((OISComputedRow *)row).object;
  return [row isKindOfClass:[NSManagedObject class]] ? row : nil;
}

// Whether an expression names, from $it, a property the entity does not
// declare (nor $compute): an open type's dynamic property. Not inside a
// lambda, whose names are its variable's, nor in a count's $filter, whose
// names are the counted member's.
static BOOL OISNamesUndeclared(ODataExpression *e, NSEntityDescription *entity, ODataPropertyMapper *mapper, NSDictionary *computed)
{
  if (!e) return NO;
  switch (e.kind) {
    case ODataExpressionMember:
      if (e.operand) return OISNamesUndeclared(e.operand, entity, mapper, computed);
      return !computed[e.name] && ![mapper propertyForWireName:e.name entity:entity];
    case ODataExpressionUnary:
    case ODataExpressionCast:
    case ODataExpressionCount:
    case ODataExpressionLambda:
      return OISNamesUndeclared(e.operand, entity, mapper, computed);
    case ODataExpressionBinary:
      return OISNamesUndeclared(e.left, entity, mapper, computed) || OISNamesUndeclared(e.right, entity, mapper, computed);
    case ODataExpressionCall:
    case ODataExpressionList:
      for (ODataExpression *argument in e.arguments) if (OISNamesUndeclared(argument, entity, mapper, computed)) return YES;
      for (ODataExpression *argument in e.namedArguments.allValues) if (OISNamesUndeclared(argument, entity, mapper, computed)) return YES;
      return NO;
    default:
      return NO;
  }
}

// A filter's parts, where it is a conjunction: each may go its own way.
static void OISAddConjuncts(ODataExpression *e, NSMutableArray *into)
{
  if (e.kind == ODataExpressionBinary && [e.name isEqualToString:@"and"]) {
    OISAddConjuncts(e.left, into);
    OISAddConjuncts(e.right, into);
  } else if (e) {
    [into addObject:e];
  }
}

@implementation OISServiceCall (Plan)

// Filters split: what the store evaluates, and what is evaluated here
// (conjuncts naming dynamic properties it cannot filter by). NO when all
// go to the store.
- (BOOL)splitFilters:(NSArray<ODataExpression *> *)filters entity:(NSEntityDescription *)entity computed:(NSDictionary *)computed
               store:(NSMutableArray *)store here:(NSMutableArray *)here
{
  for (ODataExpression *filter in filters) {
    NSMutableArray *parts = [NSMutableArray array];
    OISAddConjuncts(filter, parts);
    for (ODataExpression *part in parts) {
      [[self filterIsForMemory:part entity:entity computed:computed] ? here : store addObject:part];
    }
  }
  return here.count > 0;
}

// Whether a filter is evaluated here rather than by the store: it names a
// dynamic property the store cannot filter by (kept in a Transformable,
// see -[ODataEntitySetHandler storeFiltersDynamicProperties]).
- (BOOL)filterIsForMemory:(ODataExpression *)filter entity:(NSEntityDescription *)entity computed:(NSDictionary *)computed
{
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  if (!filter || !handler.isOpenType || handler.storeFiltersDynamicProperties) return NO;
  return OISNamesUndeclared(filter, entity, self.mapper, computed ?: @{});
}

#pragma mark - Planning

// What the request does not say but every row answers to: the function's
// results it reads on from, the navigation it came through, what the
// caller may see.
- (NSArray<NSPredicate *> *)fixedPredicatesSummary:(NSString **)summary error:(NSError **)error
{
  NSMutableArray *fixed = [NSMutableArray array];
  NSMutableArray *names = [NSMutableArray array];
  if (self.members) {
    [fixed addObject:[self predicateForObjects:self.members]];
    [names addObject:@"the results"];
  }
  if (self.parent && self.navigation) {
    NSPredicate *members = [self membersOfNavigation];
    if (!members) {
      if (error) *error = ODataServiceError(500, [NSString stringWithFormat:@"%@ has no key to follow %@ by", self.parent.entity.name, self.navigation.name]);
      return nil;
    }
    [fixed addObject:members];
    [names addObject:[NSString stringWithFormat:@"%@ of the %@", self.navigation.name, self.parent.entity.name]];
  }
  for (ODataExpression *filter in self.pathFilters) {
    NSPredicate *predicate = [self.predicates predicateForExpression:filter entity:self.entity aliases:self.request.options.aliases
                                                                    computed:nil spans:self.planSpans error:error];
    if (!predicate) return nil;
    [fixed addObject:predicate];
    [names addObject:[NSString stringWithFormat:@"$filter(%@)", filter]];
  }
  NSPredicate *visible = [self.handler predicateForVisibleObjectsInRequest:self.request];
  if (visible) {
    [fixed addObject:visible];
    [names addObject:@"visible"];
  }
  if (summary) *summary = [names componentsJoinedByString:@" and "];
  return fixed;
}

static void OISAddHierarchyTransformations(NSArray<ODataApplyTransformation *> *transformations, NSMutableArray *into)
{
  for (ODataApplyTransformation *t in transformations) {
    if (t.kind == ODataApplyHierarchy) [into addObject:t];
    OISAddHierarchyTransformations(t.sequence, into);
    for (NSArray *branch in t.branches) OISAddHierarchyTransformations(branch, into);
  }
}

static void OISAddHierarchyTransformationsOfOptions(ODataQueryOptions *options, NSMutableArray *into)
{
  if (!options) return;
  OISAddHierarchyTransformations(options.apply, into);
  for (ODataExpandItem *item in options.expand) OISAddHierarchyTransformationsOfOptions(item.options, into);
}

// A Closure for each recursive hierarchy the request names: in its
// hierarchy functions, and its hierarchical transformations.
- (NSArray<OISPlanNode *> *)closuresOf:(ODataQueryOptions *)options
{
  NSMutableArray *closures = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  void (^add)(NSArray *, NSString *) = ^(NSArray *hierarchy, NSString *qualifier) {
    if (!hierarchy.count || !qualifier) return;
    NSString *key = [NSString stringWithFormat:@"%@#%@", [hierarchy componentsJoinedByString:@"/"], qualifier];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    OISPlanNode *closure = [OISPlanNode operator:OISPlanClosure input:nil];
    closure.hierarchy = hierarchy;
    closure.qualifier = qualifier;
    [closures addObject:closure];
  };
  NSMutableArray *expressions = [NSMutableArray array];
  OISAddExpressionsOfOptions(options, expressions);
  for (ODataExpression *e in expressions) {
    NSArray *calls = [e partsPassingTest:^BOOL(ODataExpression *part) {
      return part.kind == ODataExpressionCall && OISHierarchyFunction(part.name) != nil;
    }];
    for (ODataExpression *call in calls) {
      NSString *nodes = call.namedArguments[@"HierarchyNodes"].description;
      ODataExpression *qualifier = call.namedArguments[@"HierarchyQualifier"];
      if (![nodes hasPrefix:@"$root/"] || ![qualifier.value isKindOfClass:[NSString class]]) continue;  // said when it is resolved
      add([[nodes substringFromIndex:6] componentsSeparatedByString:@"/"], qualifier.value);
    }
  }
  NSMutableArray *hierarchical = [NSMutableArray array];
  OISAddHierarchyTransformationsOfOptions(options, hierarchical);
  for (ODataApplyTransformation *t in hierarchical) add(t.hierarchy, t.qualifier);
  return closures;
}

// Where $these and the hierarchy functions are, stand-ins while planning,
// before they are known.
static ODataExpression *OISPlanningStandIns(ODataExpression *e)
{
  NSMutableDictionary *standIns = [NSMutableDictionary dictionary];
  for (ODataExpression *these in [e aggregatesOfThese]) standIns[these.description] = @0;
  NSArray *calls = [e partsPassingTest:^BOOL(ODataExpression *part) {
    return part.kind == ODataExpressionCall && OISHierarchyFunction(part.name) != nil;
  }];
  for (ODataExpression *call in calls) standIns[call.description] = @YES;
  return standIns.count ? [e expressionReplacing:standIns] : e;
}

static void OISAddFilters(NSArray<ODataApplyTransformation *> *transformations, NSMutableArray *into)
{
  for (ODataApplyTransformation *t in transformations) {
    if (t.filter) [into addObject:t.filter];
    OISAddFilters(t.sequence, into);
    for (NSArray *branch in t.branches) OISAddFilters(branch, into);
  }
}

- (void)addSpansOf:(ODataQueryOptions *)options entity:(NSEntityDescription *)entity into:(NSMutableDictionary *)spans
{
  if (!options || !entity) return;
  NSMutableArray *filters = [NSMutableArray array];
  if (options.filter) [filters addObject:options.filter];
  OISAddFilters(options.apply, filters);
  for (ODataExpression *filter in filters) {
    NSArray *attributes = [self.predicates spanAttributesOfExpression:OISPlanningStandIns(filter) entity:entity
                                                                      aliases:self.request.options.aliases computed:[self computedNamesOf:options]];
    for (NSAttributeDescription *attribute in attributes) {
      NSString *key = [ODataPredicateBuilder spanKeyOfAttribute:attribute];
      if (spans[key]) continue;
      OISPlanNode *span = [OISPlanNode operator:OISPlanSpan input:nil];
      span.entity = attribute.entity;
      span.attributeName = attribute.name;
      spans[key] = span;
    }
  }
  for (ODataExpandItem *item in options.expand) {
    NSPropertyDescription *property = item.path.count == 1 && !item.isStar ? [self.mapper propertyForWireName:item.path[0] entity:entity] : nil;
    if ([property isKindOfClass:[NSRelationshipDescription class]]) {
      [self addSpansOf:item.options entity:((NSRelationshipDescription *)property).destinationEntity into:spans];
    }
  }
}

// A Span for each date attribute the read's month() and the rest range
// over: its earliest and latest, read through the handler.
- (NSArray<OISPlanNode *> *)spansOf:(ODataQueryOptions *)options entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *spans = [NSMutableDictionary dictionary];
  [self addSpansOf:options entity:entity into:spans];
  return [spans objectsForKeys:[spans.allKeys sortedArrayUsingSelector:@selector(compare:)] notFoundMarker:[NSNull null]];
}

// The rows a plain collection read gives (no grouping $apply): as far as
// can be, one store scan, its filter, order and page the store's.
- (OISPlan *)planPlainRead
{
  ODataQueryOptions *options = self.request.options;
  NSError *error = nil;
  NSString *summary = nil;
  NSArray *fixed = [self fixedPredicatesSummary:&summary error:&error];
  if (!fixed) {
    [self respondError:error];
    return nil;
  }
  OISPlan *plan = [[OISPlan alloc] init];
  plan.closures = [self closuresOf:options];
  plan.spans = [self spansOf:options entity:self.entity];
  NSMutableArray *filters = [NSMutableArray array];
  if (options.filter) [filters addObject:options.filter];
  NSMutableArray *applyFilters = [NSMutableArray array];
  if ([self applyIsFiltersOnly]) {
    for (ODataApplyTransformation *t in options.apply) [applyFilters addObject:t.filter];
  }
  [filters addObjectsFromArray:applyFilters];

  OISPlanNode *scan = [OISPlanNode operator:OISPlanStoreScan input:nil];
  scan.entity = self.entity;
  scan.fixed = fixed;
  scan.fixedSummary = summary;
  scan.filters = filters;
  scan.search = options.searchExpression;
  scan.time = options.temporalText.count ? options : nil;
  scan.computed = [self computedNamesOf:options];
  scan.keyOrder = YES;
  // A filter the store cannot evaluate: the rows the rest allows, filtered here.
  NSMutableArray *storeFilters = [NSMutableArray array], *hereFilters = [NSMutableArray array];
  BOOL memory = [self splitFilters:filters entity:self.entity computed:scan.computed store:storeFilters here:hereFilters];
  if (memory) scan.filters = storeFilters;
  NSMutableArray *prefetch = [NSMutableArray array];
  for (ODataExpandItem *item in options.expand) {
    if (item.path.count != 1) continue;
    NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:self.entity];
    if ([property isKindOfClass:[NSRelationshipDescription class]]) [prefetch addObject:property.name];
  }
  scan.prefetch = prefetch;

  // $these of $filter and $compute: of the rows before them (after a
  // filters-only $apply, what it leaves), a read of their own.
  NSArray *asked = OISTheseOfFilter(options);
  if (asked.count) {
    OISPlanNode *base = [OISPlanNode operator:OISPlanStoreScan input:nil];
    base.entity = self.entity;
    base.fixed = fixed;
    base.fixedSummary = summary;
    base.filters = applyFilters;
    base.limit = self.service.maxRowsInMemory;
    NSMutableDictionary *bindings = [NSMutableDictionary dictionary];
    for (ODataExpression *these in asked) {
      OISPlanNode *value = [OISPlanNode operator:OISPlanValue input:base];
      value.expression = these;
      bindings[these.description] = value;
    }
    scan.bindings = bindings;
  }

  // The order: the store's, where it sorts by key paths; else here, every
  // row, then the page.
  BOOL here = NO;
  if (options.orderBy.count) {
    if (OISTheseOfOrder(options).count) {
      here = YES;
    } else {
      NSArray *descriptors = [self.predicates sortDescriptorsForOrderBy:options.orderBy entity:self.entity computed:scan.computed
                                                                       inMemory:&here error:&error];
      if (!descriptors) {
        [self respondError:error];
        return nil;
      }
    }
  }

  // Paging: the smaller of the service's page and the client's.
  NSUInteger page = self.service.maxPageSize;
  NSString *preferred = self.request.preferences[@"odata.maxpagesize"];
  if (preferred.integerValue > 0 && (!page || (NSUInteger)preferred.integerValue < page)) {
    page = (NSUInteger)preferred.integerValue;
    self.pagedByPreference = YES;
  }
  NSString *skip = options.skipToken;
  if (skip) {
    // A tracked read's pages carry the token it began at: 20~token.
    NSRange tilde = [skip rangeOfString:@"~"];
    if (tilde.location != NSNotFound) {
      self.trackingToken = [self tokenCheckingScope:[skip substringFromIndex:NSMaxRange(tilde)]];
      if (!self.trackingToken) return nil;
      skip = [skip substringToIndex:tilde.location];
    }
    NSScanner *scanner = [NSScanner scannerWithString:skip];
    NSInteger token = 0;
    if (![scanner scanInteger:&token] || !scanner.isAtEnd || token < 0) {
      [self fail:400 message:[NSString stringWithFormat:@"$skiptoken=%@ is not one this service wrote", options.skipToken]];
      return nil;
    }
    self.skipToken = (NSUInteger)token;
  }
  // Changes are followed from before the rows are read: one made while
  // they are may come again in the delta, but none is missed.
  if (![self canTrackChanges]) {
    self.trackingToken = nil;
  } else if (!self.trackingToken && self.request.preferences[@"odata.track-changes"]) {
    self.trackingToken = [self.handler changeTokenForRequest:self.request];
  }
  NSUInteger remaining = NSUIntegerMax;
  if (options.top) {
    NSUInteger top = options.top.unsignedIntegerValue;
    remaining = top > self.skipToken ? top - self.skipToken : 0;
  }
  NSUInteger limit = page ? MIN(page, remaining) : remaining;
  self.pageSize = limit;
  NSUInteger offset = options.skip.unsignedIntegerValue + self.skipToken;
  // One more than the page, to know whether there is a next one.
  NSUInteger fetchLimit = 0;
  if (limit != NSUIntegerMax) fetchLimit = limit < remaining ? limit + 1 : limit;
  if (limit == 0) fetchLimit = 1;

  OISPlanNode *root = scan;
  OISPlanNode *filtered = scan;
  if (!here && !memory) {
    scan.order = options.orderBy;
    scan.skip = offset ? @(offset) : nil;
    scan.top = fetchLimit ? @(fetchLimit) : nil;
    scan.pageSize = limit == NSUIntegerMax ? 0 : limit;
  } else {
    // Every row, filtered, sorted and paged here: a store sorts by key
    // paths only, and filters by what it keeps.
    scan.limit = self.service.maxRowsInMemory;
    if (memory) {
      for (ODataExpression *filter in hereFilters) {
        OISPlanNode *select = [OISPlanNode operator:OISPlanApply input:filtered];
        select.transformation = [ODataApplyTransformation filterWithExpression:filter];
        filtered = select;
      }
    }
    OISPlanNode *sort = filtered;
    if (options.orderBy.count) {
      sort = [OISPlanNode operator:OISPlanApply input:filtered];
      sort.transformation = [ODataApplyTransformation orderByItems:options.orderBy];
    }
    OISPlanNode *paged = [OISPlanNode operator:OISPlanLimit input:sort];
    paged.skip = offset ? @(offset) : nil;
    paged.top = fetchLimit ? @(fetchLimit) : nil;
    paged.pageSize = limit == NSUIntegerMax ? 0 : limit;
    root = paged;
  }
  plan.root = root;
  if (options.includeCount.boolValue && memory) {
    plan.count = [OISPlanNode operator:OISPlanCount input:filtered];
  } else if (options.includeCount.boolValue) {
    OISPlanNode *count = [OISPlanNode operator:OISPlanStoreCount input:nil];
    count.entity = self.entity;
    count.fixed = fixed;
    count.fixedSummary = summary;
    count.filters = filters;
    count.search = scan.search;
    count.time = scan.time;
    count.computed = scan.computed;
    count.bindings = scan.bindings;
    plan.count = count;
  }
  plan.nests = [self nestsOf:options entity:self.entity];
  plan.logical = [self logicalPlanOf:options];
  return plan;
}

// A grouping $apply's rows: read with its leading filters, grouped in the
// store where it groups exactly, the rest here; then the query's own
// $filter, $orderby, $count, $skip and $top over what it made.
- (OISPlan *)planAppliedRead
{
  ODataQueryOptions *options = self.request.options;
  NSError *error = nil;
  NSString *summary = nil;
  NSArray *fixed = [self fixedPredicatesSummary:&summary error:&error];
  if (!fixed) {
    [self respondError:error];
    return nil;
  }
  OISPlan *plan = [[OISPlan alloc] init];
  plan.closures = [self closuresOf:options];
  plan.spans = [self spansOf:options entity:self.entity];
  OISPlanNode *scan = [OISPlanNode operator:OISPlanStoreScan input:nil];
  scan.entity = self.entity;
  scan.fixed = fixed;
  scan.fixedSummary = summary;
  scan.search = options.searchExpression;
  scan.keyOrder = YES;  // what $apply makes of them comes out the same way each time
  scan.limit = self.service.maxRowsInMemory;
  // Leading filters in the store; not one of the collection's values
  // ($these/aggregate(...)), which are of the rows before it.
  NSUInteger first = 0;
  NSMutableArray *filters = [NSMutableArray array];
  for (; first < options.apply.count && ((ODataApplyTransformation *)options.apply[first]).kind == ODataApplyFilter
         && ![((ODataApplyTransformation *)options.apply[first]).filter aggregatesOfThese].count
         && ![self filterIsForMemory:((ODataApplyTransformation *)options.apply[first]).filter entity:self.entity computed:nil]; first++) {
    [filters addObject:((ODataApplyTransformation *)options.apply[first]).filter];
  }
  scan.filters = filters;
  OISPlanNode *root = scan;
  NSArray *rest = [options.apply subarrayWithRange:NSMakeRange(first, options.apply.count - first)];
  // The first grouping, in the store where it gives what this would.
  if (rest.count && [self storeGroupingOf:rest.firstObject predicate:[NSPredicate predicateWithValue:YES]]) {
    OISPlanNode *grouped = [OISPlanNode operator:OISPlanStoreAggregate input:scan];
    grouped.transformation = rest.firstObject;
    root = grouped;
    rest = [rest subarrayWithRange:NSMakeRange(1, rest.count - 1)];
  }
  for (ODataApplyTransformation *t in rest) {
    OISPlanNode *step = [OISPlanNode operator:OISPlanApply input:root];
    step.transformation = t;
    root = step;
  }
  if (options.filter) {
    OISPlanNode *select = [OISPlanNode operator:OISPlanApply input:root];
    select.transformation = [ODataApplyTransformation filterWithExpression:options.filter];
    root = select;
  }
  if (options.orderBy.count) {
    OISPlanNode *sort = [OISPlanNode operator:OISPlanApply input:root];
    sort.transformation = [ODataApplyTransformation orderByItems:options.orderBy];
    root = sort;
  }
  if (options.includeCount.boolValue) plan.count = [OISPlanNode operator:OISPlanCount input:root];
  if (options.skip || options.top) {
    OISPlanNode *paged = [OISPlanNode operator:OISPlanLimit input:root];
    paged.skip = options.skip;
    paged.top = options.top;
    root = paged;
  }
  plan.root = root;
  // Entities still: written with what expand() asked for too, and a join's
  // aliases' members with their own.
  self.writtenOptions = [self writtenOptionsOf:options];
  NSMutableArray *nests = [NSMutableArray arrayWithArray:[self nestsOf:self.writtenOptions entity:self.entity]];
  NSSet *aliases = OISJoinAliases(options);
  for (ODataExpandItem *item in options.expand) {
    if (item.path.count != 1 || ![aliases containsObject:item.path[0]]) continue;
    OISPlanNode *nest = [OISPlanNode operator:OISPlanNest input:nil];
    nest.item = item;
    nest.entity = self.entity;
    [nests addObject:nest];
  }
  plan.nests = nests;
  plan.logical = [self logicalPlanOf:options];
  return plan;
}

static void OISAddExpansions(NSArray<ODataApplyTransformation *> *transformations, NSMutableArray *into, NSMutableSet *aliases)
{
  for (ODataApplyTransformation *t in transformations) {
    if (t.kind == ODataApplyExpand && ![into containsObject:t.expansion]) [into addObject:t.expansion];
    if (t.kind == ODataApplyJoin && t.alias) [aliases addObject:t.alias];
    OISAddExpansions(t.sequence, into, aliases);
    for (NSArray *branch in t.branches) OISAddExpansions(branch, into, aliases);
  }
}

// The join aliases $apply makes: navigation properties to the member.
static NSSet<NSString *> *OISJoinAliases(ODataQueryOptions *options)
{
  NSMutableSet *aliases = [NSMutableSet set];
  OISAddExpansions(options.apply, [NSMutableArray array], aliases);
  return aliases;
}

// What the entities are written with: $apply's expand() and the query's
// own $expand (not of a join's alias, whose member is written apart), and
// its $select.
- (ODataQueryOptions *)writtenOptionsOf:(ODataQueryOptions *)options
{
  NSMutableArray *expansions = [NSMutableArray array];
  NSMutableSet *aliases = [NSMutableSet set];
  OISAddExpansions(options.apply, expansions, aliases);
  BOOL joined = NO;
  for (ODataExpandItem *item in options.expand) if (item.path.count == 1 && [aliases containsObject:item.path[0]]) joined = YES;
  if (!expansions.count && !joined) return options;
  NSMutableArray *expand = [NSMutableArray arrayWithArray:expansions];
  for (ODataExpandItem *item in options.expand) {
    if (!(item.path.count == 1 && [aliases containsObject:item.path[0]])) [expand addObject:item.description];
  }
  NSMutableDictionary *query = [NSMutableDictionary dictionary];
  if (options.select.count) query[@"$select"] = [[options.select valueForKey:@"description"] componentsJoinedByString:@","];
  if (expand.count) query[@"$expand"] = [expand componentsJoinedByString:@","];
  NSError *error = nil;
  ODataQueryOptions *written = [ODataQueryOptions optionsWithQuery:query error:&error];
  return written ?: options;
}

// Objects in hand (an entity read, an operation's result, a write's):
// their expansions.
- (OISPlan *)planOfObjects:(NSArray *)objects options:(ODataQueryOptions *)options entity:(NSEntityDescription *)entity
{
  OISPlan *plan = [[OISPlan alloc] init];
  plan.closures = [self closuresOf:options];
  plan.spans = [self spansOf:options entity:entity];
  OISPlanNode *given = [OISPlanNode operator:OISPlanObjects input:nil];
  given.objects = objects ?: @[];
  given.entity = entity;
  plan.root = given;
  plan.nests = [self nestsOf:options entity:entity];
  return plan;
}

// A delta link's changes: what changed and still matches, what no longer
// does, and what was deleted.
- (OISPlan *)planDelta
{
  OISPlan *plan = [[OISPlan alloc] init];
  plan.closures = [self closuresOf:self.request.options];
  plan.spans = [self spansOf:self.request.options entity:self.entity];
  OISPlanNode *changes = [OISPlanNode operator:OISPlanChanges input:nil];
  changes.entity = self.entity;
  changes.deltaToken = self.deltaToken;
  plan.root = changes;
  plan.nests = [self nestsOf:self.request.options entity:self.entity];
  return plan;
}

// /$count: the store's count of the rows the read would give.
- (OISPlan *)planCountRead
{
  ODataQueryOptions *options = self.request.options;
  NSError *error = nil;
  NSString *summary = nil;
  NSArray *fixed = [self fixedPredicatesSummary:&summary error:&error];
  if (!fixed) {
    [self respondError:error];
    return nil;
  }
  OISPlan *plan = [[OISPlan alloc] init];
  plan.closures = [self closuresOf:options];
  plan.spans = [self spansOf:options entity:self.entity];
  OISPlanNode *count = [OISPlanNode operator:OISPlanStoreCount input:nil];
  count.entity = self.entity;
  count.fixed = fixed;
  count.fixedSummary = summary;
  NSMutableArray *filters = [NSMutableArray array];
  if (options.filter) [filters addObject:options.filter];
  if ([self applyIsFiltersOnly]) for (ODataApplyTransformation *t in options.apply) [filters addObject:t.filter];
  count.filters = filters;
  count.search = options.searchExpression;
  count.time = options.temporalText.count ? options : nil;
  count.computed = [self computedNamesOf:options];
  plan.count = count;
  NSMutableArray *storeFilters = [NSMutableArray array], *hereFilters = [NSMutableArray array];
  if ([self splitFilters:filters entity:self.entity computed:count.computed store:storeFilters here:hereFilters]) {
    // A filter the store cannot evaluate: the rows the rest allows,
    // filtered and counted here.
    OISPlanNode *scan = [OISPlanNode operator:OISPlanStoreScan input:nil];
    scan.entity = self.entity;
    scan.fixed = fixed;
    scan.fixedSummary = summary;
    scan.filters = storeFilters;
    scan.search = count.search;
    scan.time = count.time;
    scan.computed = count.computed;
    scan.limit = self.service.maxRowsInMemory;
    OISPlanNode *node = scan;
    for (ODataExpression *filter in hereFilters) {
      OISPlanNode *select = [OISPlanNode operator:OISPlanApply input:node];
      select.transformation = [ODataApplyTransformation filterWithExpression:filter];
      node = select;
    }
    plan.count = [OISPlanNode operator:OISPlanCount input:node];
  }
  plan.root = [OISPlanNode operator:OISPlanObjects input:nil];
  plan.root.objects = @[];
  return plan;
}

// $expand's items: a Nest each, its members read with the others'.
- (NSArray<OISPlanNode *> *)nestsOf:(ODataQueryOptions *)options entity:(NSEntityDescription *)entity
{
  NSMutableArray *nests = [NSMutableArray array];
  for (ODataExpandItem *item in options.expand) {
    OISPlanNode *nest = [OISPlanNode operator:OISPlanNest input:nil];
    nest.item = item;
    nest.entity = entity;
    NSPropertyDescription *property = item.path.count == 1 && !item.isStar ? [self.mapper propertyForWireName:item.path[0] entity:entity] : nil;
    NSEntityDescription *destination = [property isKindOfClass:[NSRelationshipDescription class]] ? ((NSRelationshipDescription *)property).destinationEntity : nil;
    nest.nests = destination ? [self nestsOf:item.options entity:destination] : @[];
    [nests addObject:nest];
  }
  return nests;
}

// Whether a Nest's members are filtered and sorted per parent, here:
// where its options ask for $these (each parent's own) or compute.
static BOOL OISNestsPerParent(ODataQueryOptions *options)
{
  return options.compute.count || OISTheseOfFilter(options).count || OISTheseOfOrder(options).count;
}

#pragma mark - The logical plan

// The request as the algebra says it, before anything is given to the
// store: for explain.
- (OISPlan *)logicalPlanOf:(ODataQueryOptions *)options
{
  OISPlan *plan = [[OISPlan alloc] init];
  plan.closures = [self closuresOf:options];
  plan.spans = [self spansOf:options entity:self.entity];
  OISPlanNode *node = [OISPlanNode operator:OISPlanScan input:nil];
  node.entity = self.entity;
  NSString *summary = nil;
  [self fixedPredicatesSummary:&summary error:NULL];
  node.fixedSummary = summary ?: @"";
  if (options.searchExpression) {
    node = [OISPlanNode operator:OISPlanApply input:node];
    node.transformation = [ODataApplyTransformation searchWith:options.searchExpression];
  }
  for (ODataApplyTransformation *t in options.apply) {
    OISPlanNode *step = [OISPlanNode operator:t.kind == ODataApplyFilter ? OISPlanSelect : OISPlanApply input:node];
    if (t.kind == ODataApplyFilter) step.filters = @[ t.filter ];
    else step.transformation = t;
    node = step;
  }
  if (options.filter) {
    node = [OISPlanNode operator:OISPlanSelect input:node];
    node.filters = @[ options.filter ];
  }
  if (options.compute.count) {
    node = [OISPlanNode operator:OISPlanApply input:node];
    node.transformation = [ODataApplyTransformation computeItems:options.compute];
  }
  if (options.orderBy.count) {
    node = [OISPlanNode operator:OISPlanSort input:node];
    node.order = options.orderBy;
  }
  if (options.includeCount.boolValue) plan.count = [OISPlanNode operator:OISPlanCount input:node];
  if (options.skip || options.top) {
    node = [OISPlanNode operator:OISPlanLimit input:node];
    node.skip = options.skip;
    node.top = options.top;
  }
  plan.root = node;
  plan.nests = [self nestsOf:options entity:self.entity];
  return plan;
}

#pragma mark - Running

#pragma mark Permissions

- (void)need:(OISAccess)access entity:(NSEntityDescription *)entity into:(NSMutableDictionary *)permissions
{
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  if (!handler) return;
  NSSet *scopes = nil;
  NSString *verb = nil;
  switch (access) {
    case OISAccessRead: scopes = handler.readScopes; verb = @"read"; break;
    case OISAccessInsert: scopes = handler.insertScopes; verb = @"insert into"; break;
    case OISAccessUpdate: scopes = handler.updateScopes; verb = @"update"; break;
    case OISAccessDelete: scopes = handler.deleteScopes; verb = @"delete from"; break;
  }
  if (!scopes.count) return;
  permissions[[NSString stringWithFormat:@"%@ %@", verb, [self.service entitySetForEntity:entity]]] = scopes;
}

- (BOOL)permitsTo:(OISAccess)access entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *needed = [NSMutableDictionary dictionary];
  [self need:access entity:entity into:needed];
  return [self permitsAll:needed];
}

// The entity a path of names leads to (a navigation's destination, a
// cast's type), each set it passes through read; nil once it leaves
// entities (a property, a name it does not know). The first name may be
// an alias $apply gave a join's members.
- (NSEntityDescription *)readPath:(NSArray<NSString *> *)path from:(NSEntityDescription *)entity aliases:(NSDictionary *)aliases
                             into:(NSMutableDictionary *)permissions
{
  NSEntityDescription *at = entity;
  for (NSUInteger i = 0; i < path.count && at; i++) {
    NSString *name = path[i];
    if (i == 0 && aliases[name]) {
      at = aliases[name];
      continue;
    }
    if ([name rangeOfString:@"."].location != NSNotFound) {
      at = [self entityForTypeName:name];
      continue;
    }
    NSPropertyDescription *property = [self.mapper propertyForWireName:name entity:at];
    if (![property isKindOfClass:[NSRelationshipDescription class]]) return nil;
    at = ((NSRelationshipDescription *)property).destinationEntity;
    [self need:OISAccessRead entity:at into:permissions];
  }
  return at;
}

// The entity an expression stands for (a member path to one, a lambda's
// variable, a cast), each set its paths pass through read -- in a
// comparison, a lambda, an aggregate, wherever they are; nil for any other
// value. it is the entity $it is; variables, a lambda's.
- (NSEntityDescription *)readExpression:(ODataExpression *)e it:(NSEntityDescription *)it variables:(NSDictionary *)variables
                                   into:(NSMutableDictionary *)permissions
{
  if (!e) return nil;
  switch (e.kind) {
    case ODataExpressionMember: {
      // $root/SalesOrganizations: a set, named from the service root.
      if (e.operand.kind == ODataExpressionVariable && [e.operand.name isEqualToString:@"$root"]) {
        ODataEntitySetHandler *handler = [self.service handlerForEntitySet:e.name];
        [self need:OISAccessRead entity:handler.entity into:permissions];
        return handler.entity;
      }
      NSEntityDescription *base = e.operand ? [self readExpression:e.operand it:it variables:variables into:permissions] : it;
      return base ? [self readPath:@[ e.name ] from:base aliases:nil into:permissions] : nil;
    }
    case ODataExpressionVariable:
      // In a count's $filter, it is the member counted and $it the root
      // (variables' "$it", which no lambda variable can be named).
      if ([e.name isEqualToString:@"$it"]) return variables[@"$it"] ?: it;
      return [e.name isEqualToString:@"$this"] ? it : variables[e.name];
    case ODataExpressionCount: {
      NSEntityDescription *members = [self readExpression:e.operand it:it variables:variables into:permissions];
      if (e.countFilter && members) {
        NSMutableDictionary *inner = [NSMutableDictionary dictionaryWithDictionary:variables ?: @{}];
        inner[@"$it"] = variables[@"$it"] ?: it;
        [self readExpression:e.countFilter it:members variables:inner into:permissions];
      }
      return nil;
    }
    case ODataExpressionCast: {
      NSEntityDescription *base = e.operand ? [self readExpression:e.operand it:it variables:variables into:permissions] : it;
      NSEntityDescription *cast = [self entityForTypeName:e.name];
      return base && cast ? cast : nil;
    }
    case ODataExpressionLambda: {
      NSEntityDescription *members = [self readExpression:e.operand it:it variables:variables into:permissions];
      NSMutableDictionary *inner = [NSMutableDictionary dictionaryWithDictionary:variables ?: @{}];
      if (e.variable && members) inner[e.variable] = members;
      [self readExpression:e.body it:it variables:inner into:permissions];
      return nil;
    }
    case ODataExpressionCall: {
      NSEntityDescription *base = e.operand ? [self readExpression:e.operand it:it variables:variables into:permissions] : nil;
      if ([e.aggregate isKindOfClass:[ODataAggregate class]]) {
        // Sales/aggregate(Amount with sum): the aggregate's paths are the collection's.
        [self readAggregate:e.aggregate from:e.operand ? base : it aliases:nil into:permissions];
      }
      for (ODataExpression *argument in e.arguments) [self readExpression:argument it:it variables:variables into:permissions];
      for (NSString *name in e.namedArguments) [self readExpression:e.namedArguments[name] it:it variables:variables into:permissions];
      // cast(Boss,NS.Manager): the type, of what it stands for.
      if ([e.name isEqualToString:@"cast"] && e.arguments.count == 2) {
        ODataExpression *type = e.arguments[1];
        NSEntityDescription *cast = [type.value isKindOfClass:[NSString class]] ? [self entityForTypeName:type.value]
                                                                               : [self entityForTypeName:type.name ?: @""];
        return cast;
      }
      return nil;
    }
    default:
      [self readExpression:e.operand it:it variables:variables into:permissions];
      [self readExpression:e.left it:it variables:variables into:permissions];
      [self readExpression:e.right it:it variables:variables into:permissions];
      for (ODataExpression *argument in e.arguments) [self readExpression:argument it:it variables:variables into:permissions];
      [self readExpression:e.body it:it variables:variables into:permissions];
      return nil;
  }
}

- (void)readExpression:(ODataExpression *)e entity:(NSEntityDescription *)entity into:(NSMutableDictionary *)permissions
{
  [self readExpression:e it:entity variables:@{} into:permissions];
}

- (void)readAggregate:(ODataAggregate *)aggregate from:(NSEntityDescription *)entity aliases:(NSDictionary *)aliases
                 into:(NSMutableDictionary *)permissions
{
  if (!entity) return;
  if (aggregate.path) [self readPath:aggregate.path from:entity aliases:aliases into:permissions];
  if (aggregate.expression) [self readExpression:aggregate.expression entity:entity into:permissions];
}

// $apply's transformations over entity: what their expressions, paths and
// expansions reach. A join's alias names its members after it; what a
// grouping or compute names reaches no set.
- (void)readTransformations:(NSArray<ODataApplyTransformation *> *)transformations entity:(NSEntityDescription *)entity
                    aliases:(NSMutableDictionary *)aliases into:(NSMutableDictionary *)permissions
{
  for (ODataApplyTransformation *t in transformations) {
    [self readExpression:t.filter entity:entity into:permissions];
    [self readExpression:t.expression entity:entity into:permissions];
    [self readExpression:t.numberExpression entity:entity into:permissions];
    for (NSArray *path in t.groupPaths) [self readPath:path from:entity aliases:aliases into:permissions];
    for (ODataAggregate *aggregate in t.aggregates) [self readAggregate:aggregate from:entity aliases:aliases into:permissions];
    for (ODataComputeItem *item in t.compute) [self readExpression:item.expression entity:entity into:permissions];
    for (ODataOrderItem *item in t.orderBy) [self readExpression:item.expression entity:entity into:permissions];
    if (t.kind == ODataApplyExpand && t.expansion) {
      ODataQueryOptions *expanded = [ODataQueryOptions optionsWithQuery:@{ @"$expand": t.expansion } error:NULL];
      for (ODataExpandItem *item in expanded.expand) [self readExpansion:item entity:entity into:permissions];
    }
    if (t.kind == ODataApplyJoin && t.joinPath) {
      NSEntityDescription *members = [self readPath:t.joinPath from:entity aliases:aliases into:permissions];
      if (members && t.alias) aliases[t.alias] = members;
      if (members) [self readTransformations:t.sequence entity:members aliases:[NSMutableDictionary dictionary] into:permissions];
    } else {
      [self readTransformations:t.sequence entity:entity aliases:aliases into:permissions];
    }
    if (t.hierarchy.count) {
      ODataEntitySetHandler *handler = [self.service handlerForEntitySet:t.hierarchy[0]];
      if (handler) [self need:OISAccessRead entity:handler.entity into:permissions];
    }
    if (t.nodePath) [self readPath:t.nodePath from:entity aliases:aliases into:permissions];
    for (NSArray *branch in t.branches) [self readTransformations:branch entity:entity aliases:[aliases mutableCopy] into:permissions];
  }
}

// What query options over entity reach: $filter, $orderby, $compute,
// $apply, and $expand, with their own options, to any depth.
- (void)readOptions:(ODataQueryOptions *)options entity:(NSEntityDescription *)entity into:(NSMutableDictionary *)permissions
{
  if (!options || !entity) return;
  [self readExpression:options.filter entity:entity into:permissions];
  for (ODataOrderItem *item in options.orderBy) [self readExpression:item.expression entity:entity into:permissions];
  for (ODataComputeItem *item in options.compute) [self readExpression:item.expression entity:entity into:permissions];
  [self readTransformations:options.apply entity:entity aliases:[NSMutableDictionary dictionary] into:permissions];
  for (ODataExpandItem *item in options.expand) [self readExpansion:item entity:entity into:permissions];
}

// An $expand item: the sets it reaches (every one *'s does), $ref and
// $count of them too, then its own options over them.
- (void)readExpansion:(ODataExpandItem *)item entity:(NSEntityDescription *)entity into:(NSMutableDictionary *)permissions
{
  NSMutableArray *destinations = [NSMutableArray array];
  if (item.isStar) {
    for (NSRelationshipDescription *relationship in entity.relationshipsByName.allValues) {
      if (![self.mapper servesProperty:relationship]) continue;
      [self need:OISAccessRead entity:relationship.destinationEntity into:permissions];
      [destinations addObject:relationship.destinationEntity];
    }
  } else {
    NSEntityDescription *destination = [self readPath:item.path from:entity aliases:nil into:permissions];
    if (destination) [destinations addObject:destination];
  }
  for (NSEntityDescription *destination in destinations) [self readOptions:item.options entity:destination into:permissions];
}

// The entity a node's expressions are over: its own, or its input's.
static NSEntityDescription *OISEntityUnder(OISPlanNode *node)
{
  for (OISPlanNode *n = node; n; n = n.input) {
    if (n.entity) return n.entity;
  }
  return nil;
}

// A read's nodes: the sets they scan, count, aggregate or follow changes
// of, and what their expressions reach. Objects given (an entity the path
// reached, a write's or an operation's) are not read again; what is read of
// them, their expansions, is.
- (void)readNode:(OISPlanNode *)node into:(NSMutableDictionary *)permissions seen:(NSHashTable *)seen
{
  if (!node || [seen containsObject:node]) return;
  [seen addObject:node];
  switch (node.op) {
    case OISPlanScan:
    case OISPlanStoreScan:
    case OISPlanStoreCount:
    case OISPlanStoreAggregate:
    case OISPlanChanges:
    case OISPlanSpan:
      // A function's results, read on from, are its own, as an action's are.
      if (self.members && [[self.service entitySetForEntity:node.entity] isEqualToString:[self.service entitySetForEntity:self.entity]]) break;
      [self need:OISAccessRead entity:node.entity into:permissions];
      break;
    case OISPlanClosure: {
      ODataEntitySetHandler *handler = node.hierarchy.count ? [self.service handlerForEntitySet:node.hierarchy[0]] : nil;
      if (handler) [self need:OISAccessRead entity:handler.entity into:permissions];
      break;
    }
    default:
      break;
  }
  NSEntityDescription *entity = OISEntityUnder(node);
  if (entity) {
    for (ODataExpression *filter in node.filters) [self readExpression:filter entity:entity into:permissions];
    for (ODataOrderItem *item in node.order) [self readExpression:item.expression entity:entity into:permissions];
    for (id value in node.computed.allValues) {
      if ([value isKindOfClass:[ODataExpression class]]) [self readExpression:value entity:entity into:permissions];
    }
    [self readExpression:node.expression entity:entity into:permissions];
    if (node.transformation) {
      [self readTransformations:@[ node.transformation ] entity:entity aliases:[NSMutableDictionary dictionary] into:permissions];
    }
    if (node.item) [self readExpansion:node.item entity:entity into:permissions];
  }
  [self readNode:node.input into:permissions seen:seen];
  [self readNode:node.nested into:permissions seen:seen];
  for (OISPlanNode *nest in node.nests) [self readNode:nest into:permissions seen:seen];
  for (NSString *name in node.bindings) [self readNode:node.bindings[name] into:permissions seen:seen];
}

- (void)addReadsOf:(OISPlan *)plan into:(NSMutableDictionary *)permissions
{
  NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
  [self readNode:plan.root into:permissions seen:seen];
  [self readNode:plan.count into:permissions seen:seen];
  for (OISPlanNode *node in plan.closures) [self readNode:node into:permissions seen:seen];
  for (OISPlanNode *node in plan.spans) [self readNode:node into:permissions seen:seen];
  for (OISPlanNode *node in plan.nests) [self readNode:node into:permissions seen:seen];
}

// Everything the plan does that asks for a permission, before it runs: a
// read, what it reaches; a write, what it writes (Write's), and what it
// answers with -- its returning read, or the read of what it wrote that a
// collection's write, or a temporal action's, answers with; an operation's
// call, and what it answers with (permissionsOfOperation).
- (NSDictionary<NSString *, NSSet<NSString *> *> *)permissionsOf:(OISPlan *)plan
{
  NSMutableDictionary *permissions = [NSMutableDictionary dictionary];
  if (!plan.write) {
    [self addReadsOf:plan into:permissions];
  } else if (plan.write.op == OISPlanCall) {
    [permissions addEntriesFromDictionary:[self permissionsOfOperation]];
  } else {
    [self addWritesOf:plan.write into:permissions];
    OISPlan *answer = plan.returning ?: [self planOfObjects:@[] options:self.request.options entity:self.entity];
    [self addReadsOf:answer into:permissions];
  }
  return permissions;
}

- (void)runPlan:(OISPlan *)plan then:(SEL)after
{
  // Every permission it needs, before anything runs.
  plan.permissions = [self permissionsOf:plan];
  if (![self permitsAll:plan.permissions]) return;
  if (!plan.write) plan.dynamicSets = [self dynamicSetsOf:plan];
  if (plan.returning) plan.returning.dynamicSets = [self dynamicSetsOf:plan.returning];
  self.plan = plan;
  self.planDynamic = nil;
  self.planAfter = after;
  self.planMemo = [NSMutableDictionary dictionary];
  self.nestResults = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                                           valueOptions:NSPointerFunctionsStrongMemory];
  if (self.service.logsPlans) OISLog(HSLogLevelInfo, self.exchange.request, @"%@ %@\n%@", self.request.method, self.exchange.request.URL, [plan treeDescription]);
  [self tracePlanned:plan];
  if (self.explaining) {
    [self respondExplaining:plan];
    return;
  }
  [self resumePlan];
}

- (void)respondExplaining:(OISPlan *)plan
{
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  body[@"physical"] = [plan treeDescription];
  if (plan.logical) body[@"logical"] = [plan.logical treeDescription];
  [self respondJSON:body status:200 headers:nil];
}

// From the top: what is known is not asked again.
- (void)resumePlan
{
  if (self.done) return;
  if (self.plan.write) {
    [self resumeWrite];
    return;
  }
  self.planPending = NO;
  OISPlan *plan = self.plan;
  for (OISPlanNode *closure in plan.closures) {
    if (![self runClosure:closure]) return;
  }
  NSMutableDictionary *spans = [NSMutableDictionary dictionary];
  for (OISPlanNode *span in plan.spans) {
    NSArray *bounds = [self scalarOf:span scope:nil input:nil];
    if (!bounds) return;
    spans[[NSString stringWithFormat:@"%@.%@", span.entity.name, span.attributeName]] = bounds;
  }
  self.planSpans = spans;
  if (!self.hierarchyCalls && ![self resolveHierarchyCalls]) return;
  OISRelation *result = [self relationOf:plan.root scope:nil input:nil];
  if (!result) return;
  if (plan.count) {
    id count = [self scalarOf:plan.count scope:nil input:nil];
    if (!count) return;
    result = [result copy];
    result.count = count;
  }
  // Each pass works the expansions out again, from what is known: a
  // pass cut short by an answer to come leaves none half done.
  self.nestResults = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                                           valueOptions:NSPointerFunctionsStrongMemory];
  self.nestVisited = [NSMutableSet set];
  for (OISPlanNode *nest in plan.nests) {
    if (![self runNest:nest over:result.rows computed:result.computed levels:0]) return;
  }
  if (self.done) return;
  if (plan.dynamicSets.count && ![self readDynamicPropertiesOf:result]) return;
  self.planResult = result;
  SEL after = self.planAfter;
  self.planAfter = NULL;
  if (!after) return;
  void (*send)(id, SEL) = (void (*)(id, SEL))[self methodForSelector:after];
  send(self, after);
}

// A store's answer: known, or asked for (nil until it comes; a handler
// that answers at once is known by the time this returns).
- (id)answerFor:(NSString *)key ask:(OISStoreAsk)ask fetch:(NSFetchRequest *)fetch handler:(ODataEntitySetHandler *)handler
{
  ODataEntitySetHandler *asked = handler ?: self.handler;
  // Timed and traced only when it is asked, not when it is known.
  OTSpan *span = nil;
  if (!self.planMemo[key] && !self.planPending && !self.done) {
    NSArray *operations = @[ @"fetch", @"count", @"aggregate", @"changes" ];
    [self beginStoreRequest:operations[ask] entity:fetch.entityName ?: asked.entity.name handler:asked];
    span = self.storeSpan;
  }
  id answer = [self answerFor:key asking:^(ODataReply *reply) {
    switch (ask) {
      case OISAskObjects: [reply returned:[asked objectsForFetchRequest:fetch request:self.request reply:reply]]; break;
      case OISAskCount: [reply returned:[asked countForFetchRequest:fetch request:self.request reply:reply]]; break;
      case OISAskGrouped: [reply returned:[asked groupedRowsForFetchRequest:fetch request:self.request reply:reply]]; break;
      case OISAskChanges: [reply returned:[asked changesSince:self.deltaToken request:self.request reply:reply]]; break;
    }
  }];
  // A later answer ends it on another thread: it is current here no more.
  [span resignCurrent];
  return answer;
}

- (id)answerFor:(NSString *)key asking:(void (^)(ODataReply *reply))ask
{
  id known = self.planMemo[key];
  if (known) return known;
  if (self.planPending || self.done) return nil;
  self.planPendingKey = key;
  ask([self replyWithAction:@selector(planDidReply:)]);
  known = self.planMemo[key];
  if (known) return known;
  if (!self.done) {
    self.planPending = YES;
    self.planWaiting = YES;
  }
  return nil;
}

- (void)planDidReply:(ODataReply *)reply
{
  [self endStoreRequest:reply.result error:reply.error];
  if (reply.error) {
    // A write's: nothing of it is kept.
    if (self.plan.write) [self.request.context rollback];
    [self respondError:reply.error];
    return;
  }
  NSString *key = self.planPendingKey;
  if (key) self.planMemo[key] = reply.result ?: @[];
  self.planPendingKey = nil;
  if (self.planWaiting) {
    self.planWaiting = NO;
    [self resumePlan];
  }
}

// An expression with its bindings in: what the hierarchy functions stand
// for, and the scalars the operator's bindings are.
- (ODataExpression *)expression:(ODataExpression *)e bound:(NSDictionary *)values
{
  e = [self hierarchical:e];
  return values.count ? [e expressionReplacing:values] : e;
}

- (NSDictionary *)valuesOfBindings:(OISPlanNode *)node scope:(NSString *)scope input:(OISRelation *)input
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *name in node.bindings) {
    id value = [self scalarOf:node.bindings[name] scope:scope input:input];
    if (!value) return nil;
    values[name] = value;
  }
  return values;
}

// A store scan's (or count's) predicate: what is fixed, then the filters,
// search and time, bound.
- (NSPredicate *)predicateOf:(OISPlanNode *)node values:(NSDictionary *)values
{
  NSMutableArray *parts = [NSMutableArray arrayWithArray:node.fixed];
  ODataQueryOptions *options = self.request.options;
  for (ODataExpression *filter in node.filters) {
    NSError *error = nil;
    NSPredicate *predicate = [self.predicates predicateForExpression:[self expression:filter bound:values] entity:node.entity
                                                                     aliases:options.aliases computed:node.computed
                                                                        spans:self.planSpans error:&error];
    if (!predicate) {
      [self respondError:error];
      return nil;
    }
    [parts addObject:predicate];
  }
  if (node.search) {
    NSPredicate *search = [self predicateForSearch:node.search entity:node.entity];
    if (!search) {
      if (!self.done) [self fail:501 message:[NSString stringWithFormat:@"%@ cannot be searched", node.entity.name]];
      return nil;
    }
    [parts addObject:search];
  }
  if (node.time) {
    NSError *error = nil;
    id period = [self predicateForApplicationTimeOf:node.time entity:node.entity error:&error];
    if (!period) {
      [self respondError:error];
      return nil;
    }
    if (period != [NSNull null]) [parts addObject:period];
  }
  if (!parts.count) return [NSPredicate predicateWithValue:YES];
  return parts.count == 1 ? parts[0] : [NSCompoundPredicate andPredicateWithSubpredicates:parts];
}

- (NSArray<NSSortDescriptor *> *)keyOrderOf:(NSEntityDescription *)entity
{
  NSMutableArray *keys = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(entity)]) {
    [keys addObject:[NSSortDescriptor sortDescriptorWithKey:attribute.name ascending:YES]];
  }
  return keys;
}

- (NSFetchRequest *)fetchOf:(OISPlanNode *)node values:(NSDictionary *)values
{
  NSPredicate *predicate = [self predicateOf:node values:values];
  if (!predicate) return nil;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:node.entity.name];
  fetch.predicate = predicate;
  NSMutableArray *sort = [NSMutableArray array];
  if (node.order.count) {
    NSMutableArray *items = [NSMutableArray array];
    for (ODataOrderItem *item in node.order) {
      [items addObject:[ODataOrderItem itemWithExpression:[self expression:item.expression bound:values] descending:item.descending]];
    }
    BOOL inMemory = NO;
    NSError *error = nil;
    NSArray *descriptors = [self.predicates sortDescriptorsForOrderBy:items entity:node.entity computed:node.computed
                                                                     inMemory:&inMemory error:&error];
    if (!descriptors || inMemory) {
      if (descriptors) error = ODataServiceError(500, @"An order the store was to sort by is not one it sorts by");
      [self respondError:error];
      return nil;
    }
    [sort addObjectsFromArray:descriptors];
  }
  if (node.keyOrder) [sort addObjectsFromArray:[self keyOrderOf:node.entity]];
  fetch.sortDescriptors = sort;
  fetch.fetchOffset = node.skip.unsignedIntegerValue;
  if (node.top) fetch.fetchLimit = node.top.unsignedIntegerValue;
  // One more than the service works on in memory, to know it is too many.
  if (node.limit) fetch.fetchLimit = node.limit + 1;
  if (node.prefetch.count) fetch.relationshipKeyPathsForPrefetching = node.prefetch;
  return fetch;
}

- (OISRelation *)relationOf:(OISPlanNode *)node scope:(NSString *)scope input:(OISRelation *)input
{
  NSString *key = OISKeyOf(node, scope);
  OISRelation *known = self.planMemo[[key stringByAppendingString:@"=relation"]];
  if (known) return known;
  OISRelation *relation = nil;
  switch (node.op) {
    case OISPlanInput:
      relation = input;
      break;
    case OISPlanObjects:
      relation = [OISRelation relationOfRows:node.objects];
      break;
    case OISPlanStoreScan: {
      NSDictionary *values = [self valuesOfBindings:node scope:scope input:input];
      if (!values) return nil;
      if (!scope) self.planValues = values;  // for $compute, when the rows are written
      NSFetchRequest *fetch = [self fetchOf:node values:values];
      if (!fetch) return nil;
      NSArray *rows = [self answerFor:key ask:OISAskObjects fetch:fetch handler:[self.service handlerForEntity:node.entity]];
      if (!rows) return nil;
      if (node.limit && ![self withinRowsInMemory:rows.count]) return nil;
      relation = [OISRelation relationOfRows:rows];
      [relation.computed addEntriesFromDictionary:node.computed];
      if (node.pageSize && rows.count > node.pageSize) {
        relation.rows = [rows subarrayWithRange:NSMakeRange(0, node.pageSize)];
        relation.hasMore = YES;
      }
      break;
    }
    case OISPlanStoreAggregate: {
      OISPlanNode *scan = node.input;
      NSPredicate *predicate = [self predicateOf:scan values:@{}];
      if (!predicate) return nil;
      OISStoreGrouping *grouping = [self storeGroupingOf:node.transformation predicate:predicate];
      if (!grouping) {
        [self fail:500 message:@"A grouping the store was to do is not one it does"];
        return nil;
      }
      NSArray *groups = [self answerFor:key ask:OISAskGrouped fetch:grouping.fetch handler:[self.service handlerForEntity:scan.entity]];
      if (!groups) return nil;
      if (![self withinRowsInMemory:groups.count]) return nil;
      relation = [OISRelation relationOfRows:[self rowsOfGroups:[grouping groupsOfRows:groups] grouping:grouping.transformation keyPaths:grouping.keyPaths
                                                  groupAttributes:grouping.groupAttributes aggregateAttributes:grouping.aggregateAttributes]];
      relation.shape = [grouping.transformation.groupPaths mutableCopy];
      for (ODataAggregate *aggregate in grouping.transformation.aggregates) [relation.shape addObject:@[ aggregate.alias ]];
      break;
    }
    case OISPlanApply: {
      OISRelation *given = [self relationOf:node.input scope:scope input:input];
      if (!given) return nil;
      relation = [given copy];
      NSArray *rows = relation.rows;
      NSMutableArray *shape = relation.shape;
      if (![self applyTransformations:@[ node.transformation ] rows:&rows shape:&shape computed:relation.computed expansions:relation.expansions]) return nil;
      relation.rows = rows;
      relation.shape = shape;
      break;
    }
    case OISPlanLimit: {
      OISRelation *given = [self relationOf:node.input scope:scope input:input];
      if (!given) return nil;
      relation = [given copy];
      NSArray *rows = given.rows;
      NSUInteger skip = MIN(node.skip.unsignedIntegerValue, rows.count);
      rows = [rows subarrayWithRange:NSMakeRange(skip, rows.count - skip)];
      if (node.top && node.top.unsignedIntegerValue < rows.count) rows = [rows subarrayWithRange:NSMakeRange(0, node.top.unsignedIntegerValue)];
      if (node.pageSize && rows.count > node.pageSize) {
        rows = [rows subarrayWithRange:NSMakeRange(0, node.pageSize)];
        relation.hasMore = YES;
      }
      relation.rows = rows;
      break;
    }
    case OISPlanChanges:
      relation = [self changesOf:node key:key];
      if (!relation) return nil;
      break;
    default:
      [self fail:500 message:[NSString stringWithFormat:@"The plan has an operator it cannot run: %@", node]];
      return nil;
  }
  self.planMemo[[key stringByAppendingString:@"=relation"]] = relation;
  return relation;
}

- (id)scalarOf:(OISPlanNode *)node scope:(NSString *)scope input:(OISRelation *)input
{
  NSString *key = OISKeyOf(node, scope);
  id known = self.planMemo[[key stringByAppendingString:@"=value"]];
  if (known) return known;
  id value = nil;
  switch (node.op) {
    case OISPlanCount: {
      OISRelation *given = [self relationOf:node.input scope:scope input:input];
      if (!given) return nil;
      value = @(given.rows.count);
      break;
    }
    case OISPlanStoreCount: {
      NSDictionary *values = [self valuesOfBindings:node scope:scope input:input];
      if (!values) return nil;
      NSPredicate *predicate = [self predicateOf:node values:values];
      if (!predicate) return nil;
      NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:node.entity.name];
      fetch.predicate = predicate;
      value = [self answerFor:key ask:OISAskCount fetch:fetch handler:[self.service handlerForEntity:node.entity]];
      if (!value) return nil;
      break;
    }
    case OISPlanSpan: {
      // The earliest and the latest there is, of those the caller may see.
      ODataEntitySetHandler *handler = [self.service handlerForEntity:node.entity];
      NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
      NSPredicate *some = [NSPredicate predicateWithFormat:@"%K != nil", node.attributeName];
      NSMutableArray *bounds = [NSMutableArray array];
      for (int i = 0; i < 2; i++) {
        NSFetchRequest *fetch = [[NSFetchRequest alloc] init];
        fetch.entity = node.entity;
        fetch.predicate = visible ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ some, visible ]] : some;
        fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:node.attributeName ascending:i == 0] ];
        fetch.fetchLimit = 1;
        NSArray *rows = [self answerFor:[NSString stringWithFormat:@"%@/%d", key, i] ask:OISAskObjects fetch:fetch handler:handler];
        if (!rows) return nil;
        id date = [rows.firstObject valueForKey:node.attributeName];
        [bounds addObject:[date isKindOfClass:[NSDate class]] ? date : [NSNull null]];
      }
      value = bounds;
      break;
    }
    case OISPlanValue: {
      OISRelation *given = [self relationOf:node.input scope:scope input:input];
      if (!given) return nil;
      NSDictionary *values = [self valuesOf:@[ node.expression ] over:given.rows shape:given.shape computed:given.computed];
      if (!values) return nil;
      value = values[node.expression.description] ?: [NSNull null];
      break;
    }
    default:
      [self fail:500 message:[NSString stringWithFormat:@"The plan has no scalar %@", node]];
      return nil;
  }
  self.planMemo[[key stringByAppendingString:@"=value"]] = value;
  return value;
}

// A recursive hierarchy's nodes, through the handler of their set.
- (BOOL)runClosure:(OISPlanNode *)closure
{
  NSString *name = [NSString stringWithFormat:@"%@#%@", [closure.hierarchy componentsJoinedByString:@"/"], closure.qualifier];
  if (self.hierarchies[name]) return YES;
  NSFetchRequest *fetch = nil;
  ODataEntitySetHandler *handler = nil;
  OISHierarchy *hierarchy = [self describedHierarchyOf:closure.hierarchy qualifier:closure.qualifier fetch:&fetch handler:&handler];
  if (!hierarchy) return NO;
  NSArray *objects = [self answerFor:OISKeyOf(closure, nil) ask:OISAskObjects fetch:fetch handler:handler];
  if (!objects) return NO;
  if (![self withinRowsInMemory:objects.count]) return NO;
  [hierarchy readObjects:objects];
  if (!self.hierarchies) self.hierarchies = [NSMutableDictionary dictionary];
  self.hierarchies[name] = hierarchy;
  return YES;
}

#pragma mark - Nest

// The parents' members of a to-many relationship, as the store selects
// them: with those of the others, through the handler; where the inverse
// is to-one, one fetch (inverse IN the parents), split by the inverse;
// otherwise (a many-to-many, or no inverse) the parents again with the
// relationship read (the join, at once), then the members (SELF IN them
// all), each parent given those of its own set. By parent object ID; nil
// until known.
- (NSDictionary *)membersOf:(NSArray<NSManagedObject *> *)parents relationship:(NSRelationshipDescription *)relationship
                  predicate:(NSPredicate *)predicate sort:(NSArray *)sort key:(NSString *)key
{
  NSEntityDescription *destination = relationship.destinationEntity;
  ODataEntitySetHandler *handler = [self.service handlerForEntity:destination];
  NSRelationshipDescription *inverse = relationship.inverseRelationship;
  BOOL byInverse = inverse && !inverse.isToMany;
  NSMutableDictionary *byParent = [NSMutableDictionary dictionary];
  for (NSUInteger start = 0; start < parents.count; start += OISNestBatch) {
    NSArray *batch = [parents subarrayWithRange:NSMakeRange(start, MIN(OISNestBatch, parents.count - start))];
    NSString *batchKey = [NSString stringWithFormat:@"%@/%lu", key, (unsigned long)start];
    NSDictionary<NSManagedObjectID *, NSSet *> *sets = nil;
    id among = batch;
    NSString *through = inverse.name;
    if (!byInverse) {
      // The parents' sets, the join read at once.
      NSFetchRequest *again = [NSFetchRequest fetchRequestWithEntityName:relationship.entity.name];
      again.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForEvaluatedObject]
                                                           rightExpression:[NSExpression expressionForConstantValue:batch]
                                                                  modifier:NSDirectPredicateModifier type:NSInPredicateOperatorType options:0];
      again.relationshipKeyPathsForPrefetching = @[ relationship.name ];
      NSArray *read = [self answerFor:[batchKey stringByAppendingString:@"/join"] ask:OISAskObjects fetch:again
                              handler:[self.service handlerForEntity:relationship.entity]];
      if (!read) return nil;
      NSMutableDictionary *collected = [NSMutableDictionary dictionary];
      NSMutableSet *related = [NSMutableSet set];
      for (NSManagedObject *parent in batch) {
        NSSet *set = [parent valueForKey:relationship.name] ?: [NSSet set];
        collected[parent.objectID] = set;
        [related unionSet:set];
      }
      sets = collected;
      among = related.allObjects;
      through = nil;
    }
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:destination.name];
    NSPredicate *mine = [NSComparisonPredicate predicateWithLeftExpression:through ? [NSExpression expressionForKeyPath:through]
                                                                                   : [NSExpression expressionForEvaluatedObject]
                                                           rightExpression:[NSExpression expressionForConstantValue:among]
                                                                  modifier:NSDirectPredicateModifier type:NSInPredicateOperatorType options:0];
    fetch.predicate = predicate ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ mine, predicate ]] : mine;
    fetch.sortDescriptors = sort;
    NSArray *rows = [self answerFor:[batchKey stringByAppendingString:@"/members"] ask:OISAskObjects fetch:fetch handler:handler];
    if (!rows) return nil;
    for (NSManagedObject *parent in batch) byParent[parent.objectID] = [NSMutableArray array];
    if (byInverse) {
      for (NSManagedObject *row in rows) {
        NSManagedObject *parent = [row valueForKey:through];
        [byParent[parent.objectID] addObject:row];
      }
    } else {
      for (NSManagedObject *parent in batch) {
        NSSet *set = sets[parent.objectID];
        for (NSManagedObject *row in rows) if ([set containsObject:row]) [byParent[parent.objectID] addObject:row];
      }
    }
  }
  return byParent;
}

// A Nest's own nests, over a destination: made once a run, so that what
// they read is known when the plan runs again from the top.
- (NSArray<OISPlanNode *> *)innerNestsOf:(OISPlanNode *)nest destination:(NSEntityDescription *)destination
{
  NSString *key = [NSString stringWithFormat:@"%p/nests/%@", (void *)nest, destination.name];
  NSArray *known = self.planMemo[key];
  if (known) return known;
  NSArray *nests = [self nestsOf:nest.item.options entity:destination];
  self.planMemo[key] = nests;
  return nests;
}

- (NSDictionary *)nestedMembersOf:(ODataExpandItem *)item relationship:(NSString *)name parent:(NSManagedObject *)parent
{
  NSDictionary *byRelationship = [self.nestResults objectForKey:item];
  return byRelationship[name][parent.objectID];
}

- (void)keepNested:(NSDictionary *)entry item:(ODataExpandItem *)item relationship:(NSString *)name parent:(NSManagedObjectID *)parent
{
  NSMutableDictionary *byRelationship = [self.nestResults objectForKey:item];
  if (!byRelationship) {
    byRelationship = [NSMutableDictionary dictionary];
    [self.nestResults setObject:byRelationship forKey:item];
  }
  NSMutableDictionary *byParent = byRelationship[name];
  if (!byParent) byRelationship[name] = byParent = [NSMutableDictionary dictionary];
  byParent[parent] = entry;
}

// An $expand item over the rows written: each one's members, as its
// options say, read with the others'; then the members' own expansions,
// and further levels. NO until known, or once answered with the error.
- (BOOL)runNest:(OISPlanNode *)nest over:(NSArray *)rows computed:(NSDictionary *)computed levels:(NSInteger)levels
{
  ODataExpandItem *item = nest.item;
  ODataQueryOptions *options = item.options;
  NSInteger depth = levels ?: (!options.levels ? 1 : options.levels.integerValue < 0 ? OISNestMaxLevels : MAX(options.levels.integerValue, 1));
  // A join's alias: the member each row has under it.
  if (item.path.count == 1 && [computed[item.path[0]] isKindOfClass:[NSEntityDescription class]]) {
    NSMutableArray *members = [NSMutableArray array];
    for (id row in rows) {
      id member = [row isKindOfClass:[OISComputedRow class]] ? ((OISComputedRow *)row).computed[item.path[0]] : nil;
      if ([member isKindOfClass:[NSManagedObject class]]) [members addObject:member];
    }
    for (OISPlanNode *inner in [self innerNestsOf:nest destination:computed[item.path[0]]]) {
      if (![self runNest:inner over:members computed:@{} levels:0]) return NO;
    }
    return YES;
  }
  // The parents, by relationship: each row's entity has its own.
  NSMapTable *byRelationship = [NSMapTable strongToStrongObjectsMapTable];
  NSMutableArray *order = [NSMutableArray array];
  for (id row in rows) {
    NSManagedObject *object = OISObjectOfRow(row);
    if (!object) continue;
    NSMutableArray *relationships = [NSMutableArray array];
    if (item.isStar) {
      for (NSRelationshipDescription *relationship in object.entity.relationshipsByName.allValues) {
        if (![self.mapper servesProperty:relationship]) continue;
        if ([self.service handlerForEntity:relationship.destinationEntity]) [relationships addObject:relationship];
      }
    } else {
      if (item.path.count != 1) {
        [self fail:501 message:[NSString stringWithFormat:@"$expand=%@ is not supported", [item.path componentsJoinedByString:@"/"]]];
        return NO;
      }
      NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:object.entity];
      if (![property isKindOfClass:[NSRelationshipDescription class]]
          || ![self.service handlerForEntity:((NSRelationshipDescription *)property).destinationEntity]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ has no navigation property %@", object.entity.name, item.path[0]]];
        return NO;
      }
      [relationships addObject:property];
    }
    for (NSRelationshipDescription *relationship in relationships) {
      NSMutableArray *parents = [byRelationship objectForKey:relationship];
      if (!parents) {
        parents = [NSMutableArray array];
        [byRelationship setObject:parents forKey:relationship];
        [order addObject:relationship];
      }
      // Once a pass for each item and parent: $levels=max ends at a cycle.
      NSString *visit = [NSString stringWithFormat:@"%p/%@/%@", (void *)item, relationship.name, object.objectID.URIRepresentation];
      if ([self.nestVisited containsObject:visit]) continue;
      [self.nestVisited addObject:visit];
      [parents addObject:object];
    }
  }

  for (NSRelationshipDescription *relationship in order) {
    NSArray *parents = [byRelationship objectForKey:relationship];
    NSEntityDescription *destination = relationship.destinationEntity;
    ODataEntitySetHandler *handler = [self.service handlerForEntity:destination];
    NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
    BOOL perParent = OISNestsPerParent(options) || [self filterIsForMemory:options.filter entity:destination computed:[self computedNamesOf:options]];
    NSString *key = [NSString stringWithFormat:@"%p/%@/%ld", (void *)nest, relationship.name, (long)depth];

    // What the store does: visibility, and unless each parent needs its
    // own, the filter, search, time and order.
    OISPlanNode *reading = [OISPlanNode operator:OISPlanStoreScan input:nil];
    reading.entity = destination;
    reading.fixed = visible ? @[ visible ] : @[];
    reading.computed = [self computedNamesOf:options];
    NSMutableArray *order2 = [NSMutableArray array];
    BOOL sortedByStore = NO;
    if (!perParent) {
      reading.filters = options.filter ? @[ options.filter ] : @[];
      reading.search = options.searchExpression;
      reading.time = options.temporalText.count ? options : nil;
      if (options.orderBy.count) {
        BOOL inMemory = NO;
        NSError *error = nil;
        NSArray *descriptors = [self.predicates sortDescriptorsForOrderBy:[self resolvedOrder:options.orderBy options:options] entity:destination
                                                                         computed:reading.computed inMemory:&inMemory error:&error];
        if (!descriptors) {
          [self respondError:error];
          return NO;
        }
        if (!inMemory) {
          [order2 addObjectsFromArray:descriptors];
          sortedByStore = YES;
        }
      } else {
        sortedByStore = YES;
      }
    }
    [order2 addObjectsFromArray:[self keyOrderOf:destination]];
    NSPredicate *predicate = parents.count ? [self predicateOf:reading values:@{}] : nil;
    if (parents.count && !predicate) return NO;

    NSDictionary *members = nil;
    if (relationship.isToMany && parents.count) {
      members = [self membersOf:parents relationship:relationship predicate:predicate sort:sortedByStore ? order2 : [self keyOrderOf:destination] key:key];
      if (!members) return NO;
    } else if (parents.count) {
      NSMutableDictionary *single = [NSMutableDictionary dictionary];
      for (NSManagedObject *parent in parents) {
        id related = [parent valueForKey:relationship.name];
        NSArray *one = related ? @[ related ] : @[];
        single[parent.objectID] = [one filteredArrayUsingPredicate:predicate];
      }
      members = single;
    }

    NSMutableArray *written = [NSMutableArray array];
    // Each parent's own work is over the destination's entities.
    NSEntityDescription *entity = self.entity;
    ODataEntitySetHandler *own = self.handler;
    self.entity = destination;
    self.handler = handler ?: own;
    BOOL done = [self nestMembers:members parents:parents nest:nest relationship:relationship reading:reading perParent:perParent
                     sortedByStore:sortedByStore written:written];
    self.entity = entity;
    self.handler = own;
    if (!done) return NO;
    // The members' own expansions, then the next level down.
    if (written.count) {
      for (OISPlanNode *inner in [self innerNestsOf:nest destination:destination]) {
        if (![self runNest:inner over:written computed:@{} levels:0]) return NO;
      }
      if (depth > 1 && item.path.count == 1 && !item.isRef && !item.isCount) {
        if (![self runNest:nest over:written computed:@{} levels:depth - 1]) return NO;
      }
    }
  }
  return YES;
}

// Each parent's members, as the Nest's options say, kept for the writer:
// each parent's own $these and compute, and where the store did not,
// its filter and order; then its page. The members written are added to
// written.
- (BOOL)nestMembers:(NSDictionary *)members parents:(NSArray<NSManagedObject *> *)parents nest:(OISPlanNode *)nest
       relationship:(NSRelationshipDescription *)relationship reading:(OISPlanNode *)reading perParent:(BOOL)perParent
      sortedByStore:(BOOL)sortedByStore written:(NSMutableArray *)written
{
  ODataExpandItem *item = nest.item;
  ODataQueryOptions *options = item.options;
  NSEntityDescription *destination = relationship.destinationEntity;
  for (NSManagedObject *parent in parents) {
    NSArray *all = members[parent.objectID] ?: @[];
    // $compute's $these: of this parent's members, for when they are written.
    ODataQueryOptions *writtenOptions = nil;
    NSMutableArray *computeThese = [NSMutableArray array];
    for (ODataComputeItem *computing in options.compute) [computeThese addObjectsFromArray:[computing.expression aggregatesOfThese]];
    if (computeThese.count) {
      NSDictionary *values = [self valuesOf:computeThese over:all shape:nil computed:reading.computed];
      if (!values) return NO;
      writtenOptions = OISOptionsReplacing(options, values, nil);
    }
    if (relationship.isToMany && (perParent || !sortedByStore)) {
      // Here, each parent's own: its $these, compute, filter and order.
      OISRelation *mine = [OISRelation relationOfRows:all];
      [mine.computed addEntriesFromDictionary:reading.computed];
      NSMutableArray *steps = [NSMutableArray array];
      if (perParent && options.filter) [steps addObject:[ODataApplyTransformation filterWithExpression:options.filter]];
      if (perParent && options.searchExpression) [steps addObject:[ODataApplyTransformation searchWith:options.searchExpression]];
      if (options.orderBy.count) [steps addObject:[ODataApplyTransformation orderByItems:options.orderBy]];
      NSArray *out = mine.rows;
      NSMutableArray *shape = nil;
      if (steps.count && ![self applyTransformations:steps rows:&out shape:&shape computed:mine.computed expansions:mine.expansions]) return NO;
      if (perParent && options.temporalText.count) {
        NSError *error = nil;
        id period = [self predicateForApplicationTimeOf:options entity:destination error:&error];
        if (!period) {
          [self respondError:error];
          return NO;
        }
        if (period != [NSNull null]) out = [out filteredArrayUsingPredicate:period];
      }
      all = out;
    }
    NSUInteger count = all.count;
    NSUInteger skip = MIN(options.skip.unsignedIntegerValue, all.count);
    NSUInteger take = options.top ? MIN(options.top.unsignedIntegerValue, all.count - skip) : all.count - skip;
    NSArray *page = [all subarrayWithRange:NSMakeRange(skip, take)];
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{ @"members": page, @"count": @(count) }];
    if (writtenOptions) entry[@"options"] = writtenOptions;
    [self keepNested:entry item:item relationship:relationship.name parent:parent.objectID];
    for (NSManagedObject *member in page) if (![written containsObject:member]) [written addObject:member];
  }
  return YES;
}

#pragma mark - Changes

// A delta token's changes of the set, as the handler gives them; then
// what changed and still matches the read, and of the rest, what the
// caller may see (all through the handler).
- (OISRelation *)changesOf:(OISPlanNode *)node key:(NSString *)key
{
  if (!self.deltaChanged) {
    // What changed since the token, as the handler says.
    ODataChanges *changes = [self answerFor:[key stringByAppendingString:@"/since"] ask:OISAskChanges fetch:nil handler:self.handler];
    if (!changes) return nil;
    if (![self takeChanges:changes]) return nil;
  }
  NSArray *changed = self.deltaChanged;
  if (!changed.count) return [OISRelation relationOfRows:@[]];
  NSError *error = nil;
  NSPredicate *matching = [self collectionPredicateWithFilter:YES error:&error];
  if (!matching) {
    [self respondError:error];
    return nil;
  }
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[ [NSPredicate predicateWithFormat:@"self IN %@", changed], matching ]];
  NSMutableArray *prefetch = [NSMutableArray array];
  for (ODataExpandItem *item in self.request.options.expand) {
    if (item.path.count != 1) continue;
    NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:self.entity];
    if ([property isKindOfClass:[NSRelationshipDescription class]]) [prefetch addObject:property.name];
  }
  if (prefetch.count) fetch.relationshipKeyPathsForPrefetching = prefetch;
  NSArray *objects = [self answerFor:[key stringByAppendingString:@"/matching"] ask:OISAskObjects fetch:fetch handler:self.handler];
  if (!objects) return nil;
  // In the order the handler gave them: first changed first.
  NSMutableDictionary *place = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < changed.count; i++) place[changed[i]] = @(i);
  objects = [objects sortedArrayUsingComparator:^NSComparisonResult(NSManagedObject *a, NSManagedObject *b) {
    return [place[a.objectID] ?: @(NSNotFound) compare:place[b.objectID] ?: @(NSNotFound)];
  }];
  NSMutableSet *gone = [NSMutableSet setWithArray:changed];
  for (NSManagedObject *object in objects) [gone removeObject:object.objectID];
  NSMutableArray *removed = [NSMutableArray array];
  if (gone.count) {
    // Changed so that the request no longer matches them; only those the
    // caller may see are named.
    NSFetchRequest *others = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
    NSPredicate *members = [NSPredicate predicateWithFormat:@"self IN %@", gone.allObjects];
    NSPredicate *visible = [self.handler predicateForVisibleObjectsInRequest:self.request];
    others.predicate = visible ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ members, visible ]] : members;
    NSArray *seen = [self answerFor:[key stringByAppendingString:@"/removed"] ask:OISAskObjects fetch:others handler:self.handler];
    if (!seen) return nil;
    for (NSManagedObject *object in seen) [removed addObject:[self removedEntry:[self canonicalPathOf:object] reason:@"changed"]];
  }
  self.deltaRemoved = removed;
  return [OISRelation relationOfRows:objects];
}

#pragma mark - Dynamic properties

// The open types' entity sets a plan may write: its rows', and its
// expansions' destinations (a star's, each served relationship's).
- (NSArray<NSString *> *)dynamicSetsOf:(OISPlan *)plan
{
  NSMutableSet *entities = [NSMutableSet set];
  OISPlanNode *node = plan.root;
  while (node && !node.entity) node = node.input;
  if (node.entity) [entities addObject:node.entity];
  [self addDestinationsOf:plan.nests into:entities depth:0];
  NSMutableSet *sets = [NSMutableSet set];
  for (NSEntityDescription *entity in entities) {
    if ([self.service handlerForEntity:entity].isOpenType) [sets addObject:[self.service entitySetForEntity:OISRootEntity(entity)]];
  }
  return [sets.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (void)addDestinationsOf:(NSArray<OISPlanNode *> *)nests into:(NSMutableSet *)entities depth:(NSInteger)depth
{
  if (depth > OISNestMaxLevels) return;
  for (OISPlanNode *nest in nests) {
    NSMutableArray *destinations = [NSMutableArray array];
    if (nest.item.isStar) {
      for (NSRelationshipDescription *relationship in nest.entity.relationshipsByName.allValues) {
        if (![self.mapper servesProperty:relationship]) continue;
        if ([self.service handlerForEntity:relationship.destinationEntity]) [destinations addObject:relationship.destinationEntity];
      }
    } else {
      NSPropertyDescription *property = nest.item.path.count == 1 ? [self.mapper propertyForWireName:nest.item.path[0] entity:nest.entity] : nil;
      if ([property isKindOfClass:[NSRelationshipDescription class]]) [destinations addObject:((NSRelationshipDescription *)property).destinationEntity];
    }
    for (NSEntityDescription *destination in destinations) {
      [entities addObjectsFromArray:[destination.subentitiesByName.allValues arrayByAddingObject:destination]];
      NSArray *inner = nest.nests.count ? nest.nests : [self nestsOf:nest.item.options entity:destination];
      [self addDestinationsOf:inner into:entities depth:depth + 1];
    }
  }
}

// Rows, and the members of their expansions, as they are written: each
// row, then what it expands to, and theirs.
- (void)addWritten:(NSArray *)rows items:(NSArray<ODataExpandItem *> *)items to:(void (^)(id))add walked:(NSMutableSet *)walked
{
  for (id row in rows) {
    add(row);
    NSManagedObject *object = OISObjectOfRow(row);
    if (!object) continue;
    for (ODataExpandItem *item in items) {
      NSDictionary *byRelationship = [self.nestResults objectForKey:item];
      for (NSString *name in [byRelationship.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *entry = byRelationship[name][object.objectID];
        NSString *step = [NSString stringWithFormat:@"%p/%@/%@", (void *)item, name, object.objectID.URIRepresentation];
        if (!entry || [walked containsObject:step]) continue;
        [walked addObject:step];
        // Their own expansions, and more of this one's levels.
        [self addWritten:entry[@"members"] items:[(item.options.expand ?: @[]) arrayByAddingObject:item] to:add walked:walked];
      }
    }
  }
}

// The dynamic properties of the entities written, rows and expansions'
// members, asked of each open type's handler at once. NO until known, or
// once answered with the error.
- (BOOL)readDynamicPropertiesOf:(OISRelation *)result
{
  NSMutableDictionary<NSString *, NSMutableArray *> *bySet = [NSMutableDictionary dictionary];
  NSMutableSet *seen = [NSMutableSet set];
  void (^add)(id) = ^(id row) {
    NSManagedObject *object = OISObjectOfRow(row);
    if (!object || [seen containsObject:object.objectID]) return;
    if (![self.service handlerForEntity:object.entity].isOpenType) return;
    [seen addObject:object.objectID];
    NSString *set = [self.service entitySetForEntity:OISRootEntity(object.entity)];
    if (!bySet[set]) bySet[set] = [NSMutableArray array];
    [bySet[set] addObject:object];
  };
  NSMutableArray *items = [NSMutableArray array];
  for (OISPlanNode *nest in self.plan.nests) if (nest.item) [items addObject:nest.item];
  [self addWritten:result.rows items:items to:add walked:[NSMutableSet set]];
  // Anything the walk did not come to, in no particular order.
  for (NSDictionary *byRelationship in [[self.nestResults objectEnumerator] allObjects]) {
    for (NSDictionary *byParent in byRelationship.allValues) {
      for (NSDictionary *entry in byParent.allValues) {
        for (id member in entry[@"members"]) add(member);
      }
    }
  }
  NSMutableDictionary *dynamic = [NSMutableDictionary dictionary];
  for (NSString *set in [bySet.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataEntitySetHandler *handler = [self.service handlerForEntitySet:set];
    NSArray *objects = bySet[set];
    id answer = [self answerFor:[@"dynamic/" stringByAppendingString:set] asking:^(ODataReply *reply) {
      [reply returned:[handler dynamicPropertiesOfObjects:objects request:self.request reply:reply]];
    }];
    if (!answer) return NO;
    if ([answer isKindOfClass:[NSDictionary class]]) [dynamic addEntriesFromDictionary:answer];
  }
  self.planDynamic = dynamic;
  return YES;
}

@end
