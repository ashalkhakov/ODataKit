// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataApply.h"
#import "ODataError.h"

// The builders' name checks (ODataExpression.m): one not allowed raises.
void OISRequireQueryNames(NSArray<NSString *> *path, NSString *what, BOOL starLast);
void OISRequireQueryName(NSString *name, NSString *what);


@implementation ODataAggregate

+ (instancetype)aggregateOfPath:(NSArray *)path method:(NSString *)method alias:(NSString *)alias
{
  OISRequireQueryNames(path ?: @[], @"an aggregate's path segment", NO);
  OISRequireQueryName(alias, @"an aggregate's alias, an OData identifier,");
  NSSet *methods = [NSSet setWithObjects:@"sum", @"min", @"max", @"average", @"countdistinct", @"$count", nil];
  if (method && ![methods containsObject:method]) OISRequireQueryNames(@[ method ], @"an aggregation method", NO);
  ODataAggregate *a = [[self alloc] init];
  a->_path = [path copy];
  a->_method = [method copy];
  a->_alias = [alias copy];
  return a;
}

+ (instancetype)aggregateOfExpression:(ODataExpression *)expression method:(NSString *)method alias:(NSString *)alias
{
  ODataAggregate *a = [[self alloc] init];
  a->_expression = expression;
  a->_method = [method copy];
  a->_alias = [alias copy];
  return a;
}

+ (instancetype)aggregateOfCustom:(NSString *)name alias:(NSString *)alias
{
  ODataAggregate *a = [[self alloc] init];
  a->_custom = [name copy];
  a->_alias = [alias copy];
  return a;
}

- (BOOL)isCount
{
  return !_custom && !_expression && (!_path || [_method isEqualToString:@"$count"]);
}

- (BOOL)isCustom
{
  // (A nil method's range would be {0, 0}: messaging nil.)
  return _custom != nil || (_method && [_method rangeOfString:@"."].location != NSNotFound);
}

- (NSString *)description
{
  if (self.custom) return [self.alias isEqualToString:self.custom] ? self.custom : [NSString stringWithFormat:@"%@ as %@", self.custom, self.alias];
  if (self.expression) return [NSString stringWithFormat:@"%@ with %@ as %@", self.expression, self.method, self.alias];
  if (!self.path) return [NSString stringWithFormat:@"$count as %@", self.alias];
  if (self.isCount) return [NSString stringWithFormat:@"%@/$count as %@", [self.path componentsJoinedByString:@"/"], self.alias];
  return [NSString stringWithFormat:@"%@ with %@ as %@", [self.path componentsJoinedByString:@"/"], self.method, self.alias];
}

@end

@implementation ODataApplyTransformation

+ (instancetype)filterWithExpression:(ODataExpression *)expression
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyFilter;
  t->_filter = expression;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  return t;
}

+ (instancetype)groupByPaths:(NSArray *)paths aggregates:(NSArray *)aggregates
{
  for (NSArray *path in paths) OISRequireQueryNames(path, @"a groupby path's segment", NO);
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyGroupBy;
  t->_groupPaths = [paths copy];
  t->_aggregates = [aggregates copy] ?: @[];
  return t;
}

+ (instancetype)groupByPaths:(NSArray *)paths sequence:(NSArray *)sequence
{
  for (NSArray *path in paths) OISRequireQueryNames(path, @"a groupby path's segment", NO);
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyGroupBy;
  t->_groupPaths = [paths copy];
  t->_aggregates = @[];
  t->_sequence = [sequence copy];
  return t;
}

+ (instancetype)aggregateWith:(NSArray *)aggregates
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyAggregate;
  t->_groupPaths = @[];
  t->_aggregates = [aggregates copy];
  return t;
}

- (NSString *)description
{
  switch (self.kind) {
    case ODataApplyFilter:
      return [NSString stringWithFormat:@"filter(%@)", self.filter];
    case ODataApplyAggregate:
      return [NSString stringWithFormat:@"aggregate(%@)", [[self.aggregates valueForKey:@"description"] componentsJoinedByString:@","]];
    case ODataApplyIdentity:
      return @"identity";
    case ODataApplySearch:
      return [NSString stringWithFormat:@"search(%@)", self.search];
    case ODataApplyCompute:
      return [NSString stringWithFormat:@"compute(%@)", [[self.compute valueForKey:@"description"] componentsJoinedByString:@","]];
    case ODataApplyOrderBy:
      return [NSString stringWithFormat:@"orderby(%@)", [[self.orderBy valueForKey:@"description"] componentsJoinedByString:@","]];
    case ODataApplyTop:
      return [NSString stringWithFormat:@"top(%@)", self.number];
    case ODataApplySkip:
      return [NSString stringWithFormat:@"skip(%@)", self.number];
    case ODataApplyTopBottom:
      return [NSString stringWithFormat:@"%@(%@,%@)", self.method, self.number ?: self.numberExpression, self.expression];
    case ODataApplyConcat: {
      NSMutableArray *branches = [NSMutableArray array];
      for (NSArray *branch in self.branches) [branches addObject:[ODataApplyTransformation stringForTransformations:branch]];
      return [NSString stringWithFormat:@"concat(%@)", [branches componentsJoinedByString:@","]];
    }
    case ODataApplyExpand:
      return [NSString stringWithFormat:@"expand(%@)", self.expansion];
    case ODataApplyJoin: {
      NSString *joined = [NSString stringWithFormat:@"%@ as %@", [self.joinPath componentsJoinedByString:@"/"], self.alias];
      if (self.sequence.count) joined = [joined stringByAppendingFormat:@",%@", [ODataApplyTransformation stringForTransformations:self.sequence]];
      return [NSString stringWithFormat:@"%@(%@)", self.outer ? @"outerjoin" : @"join", joined];
    }
    case ODataApplyHierarchy: {
      NSMutableArray *parts = [NSMutableArray arrayWithObjects:[@"$root/" stringByAppendingString:[self.hierarchy componentsJoinedByString:@"/"]],
                                                               self.qualifier, [self.nodePath componentsJoinedByString:@"/"], nil];
      if (self.traversal) {
        [parts addObject:self.traversal];
        for (ODataOrderItem *item in self.orderBy) [parts addObject:item.description];
      } else {
        [parts addObject:[ODataApplyTransformation stringForTransformations:self.sequence]];
        if (self.number) [parts addObject:self.number];
        if (self.keepStart) [parts addObject:@"keep start"];
      }
      return [NSString stringWithFormat:@"%@(%@)", self.method, [parts componentsJoinedByString:@","]];
    }
    case ODataApplyGroupBy: {
      NSMutableArray *paths = [NSMutableArray array];
      for (NSArray *path in self.groupPaths) [paths addObject:[path componentsJoinedByString:@"/"]];
      NSString *grouped = [NSString stringWithFormat:@"(%@)", [paths componentsJoinedByString:@","]];
      if (self.sequence.count) {
        return [NSString stringWithFormat:@"groupby(%@,%@)", grouped, [ODataApplyTransformation stringForTransformations:self.sequence]];
      }
      if (!self.aggregates.count) return [NSString stringWithFormat:@"groupby(%@)", grouped];
      return [NSString stringWithFormat:@"groupby(%@,aggregate(%@))", grouped,
              [[self.aggregates valueForKey:@"description"] componentsJoinedByString:@","]];
    }
  }
  return @"";
}

+ (NSString *)stringForTransformations:(NSArray *)transformations
{
  return [[transformations valueForKey:@"description"] componentsJoinedByString:@"/"];
}

#pragma mark Reading

static NSError *OISApplyError(ODataIncrementalStoreErrorCode code, NSString *message, NSString *text)
{
  return OISError(code, [NSString stringWithFormat:@"$apply: %@ in \"%@\"", message, text]);
}

// text split at separator where it is outside parentheses and quotes.
static NSArray<NSString *> *OISSplitTop(NSString *text, unichar separator)
{
  NSMutableArray *parts = [NSMutableArray array];
  NSInteger depth = 0;
  BOOL quoted = NO;
  NSUInteger start = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c == '\'') quoted = !quoted;  // '' inside a string toggles twice
    if (quoted) continue;
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == separator && depth == 0) {
      [parts addObject:[[text substringWithRange:NSMakeRange(start, i - start)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
      start = i + 1;
    }
  }
  [parts addObject:[[text substringFromIndex:start] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
  return parts;
}

// name(inside), or nil.
static NSString *OISCall(NSString *text, NSString **name)
{
  NSRange open = [text rangeOfString:@"("];
  if (open.location == NSNotFound || ![text hasSuffix:@")"]) return nil;
  *name = [[text substringToIndex:open.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  return [text substringWithRange:NSMakeRange(NSMaxRange(open), text.length - NSMaxRange(open) - 1)];
}

static NSArray<NSString *> *OISPath(NSString *text)
{
  NSArray *segments = [text componentsSeparatedByString:@"/"];
  for (NSString *segment in segments) {
    if (!segment.length) return nil;
    for (NSUInteger i = 0; i < segment.length; i++) {
      unichar c = [segment characterAtIndex:i];
      if (!(c == '_' || c == '.' || [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c])) return nil;
    }
  }
  return segments;
}

// Where word stands alone, outside parentheses and quotes, last: " as ",
// " with ". NSNotFound for nowhere.
static NSUInteger OISLastTopWord(NSString *text, NSString *word)
{
  NSString *spaced = [NSString stringWithFormat:@" %@ ", word];
  NSInteger depth = 0;
  BOOL quoted = NO;
  NSUInteger found = NSNotFound;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c == '\'') quoted = !quoted;
    if (quoted) continue;
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (depth == 0 && c == ' ' && i + spaced.length <= text.length &&
        [[text substringWithRange:NSMakeRange(i, spaced.length)] isEqualToString:spaced]) found = i;
  }
  return found;
}

// Each an aggregate expression as alias (section 3.1.3): a path or an
// expression with a method, $count, or a path to a collection with /$count.
+ (NSArray *)aggregatesIn:(NSString *)inside text:(NSString *)text error:(NSError **)error
{
  NSMutableArray *aggregates = [NSMutableArray array];
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  for (NSString *raw in OISSplitTop(inside, ',')) {
    NSString *item = [raw stringByTrimmingCharactersInSet:space];
    NSUInteger as = OISLastTopWord(item, @"as");
    NSString *alias = as == NSNotFound ? nil : [[item substringFromIndex:as + 4] stringByTrimmingCharactersInSet:space];
    NSString *what = as == NSNotFound ? item : [[item substringToIndex:as] stringByTrimmingCharactersInSet:space];
    if (OISLastTopWord(what, @"from") != NSNotFound) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, @"from is not supported", text);
      return nil;
    }
    // A custom aggregate is named alone, its alias optional (section 3.2.1.1,
    // type 4); one on a related collection (Sales/Forecast) is not supported.
    NSArray *named = OISPath(what);
    if (named && ![what isEqualToString:@"$count"] && ![what hasSuffix:@"/$count"] && OISLastTopWord(what, @"with") == NSNotFound) {
      if (named.count != 1) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression,
                                          [NSString stringWithFormat:@"%@: a custom aggregate of a related collection is not supported", what], text);
        return nil;
      }
      if (alias && OISPath(alias).count != 1) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not an alias", alias], text);
        return nil;
      }
      [aggregates addObject:[ODataAggregate aggregateOfCustom:named[0] alias:alias ?: named[0]]];
      continue;
    }
    if (OISPath(alias ?: @"").count != 1) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not an aggregate with an alias (as)", item], text);
      return nil;
    }
    // $count, or a collection's: Sales/$count.
    if ([what isEqualToString:@"$count"]) {
      [aggregates addObject:[ODataAggregate aggregateOfPath:nil method:nil alias:alias]];
      continue;
    }
    if ([what hasSuffix:@"/$count"]) {
      NSArray *path = OISPath([what substringToIndex:what.length - 7]);
      if (!path) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not a path", what], text);
        return nil;
      }
      [aggregates addObject:[ODataAggregate aggregateOfPath:path method:@"$count" alias:alias]];
      continue;
    }
    NSUInteger with = OISLastTopWord(what, @"with");
    NSString *method = with == NSNotFound ? nil : [[what substringFromIndex:with + 6] stringByTrimmingCharactersInSet:space];
    NSString *operand = with == NSNotFound ? nil : [[what substringToIndex:with] stringByTrimmingCharactersInSet:space];
    if (!method.length || !operand.length) {
      // A custom aggregate is named alone; this service declares none.
      if (error) *error = OISApplyError(OISPath(what).count ? ODataIncrementalStoreErrorUnsupportedExpression : ODataIncrementalStoreErrorSyntax,
                                        [NSString stringWithFormat:@"\"%@\" is not a path or an expression with a method (custom aggregates are not supported)", what], text);
      return nil;
    }
    // A custom method is namespace-qualified; which there are, the service says.
    BOOL qualified = [method rangeOfString:@"."].location != NSNotFound && OISPath(method).count == 1;
    if (![[ODataAggregation methods] containsObject:method] && !qualified) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"the method %@ is not supported", method], text);
      return nil;
    }
    NSArray *path = OISPath(operand);
    if (path) {
      [aggregates addObject:[ODataAggregate aggregateOfPath:path method:method alias:alias]];
      continue;
    }
    ODataExpression *expression = [ODataExpression expressionWithString:operand error:error];
    if (!expression) return nil;
    [aggregates addObject:[ODataAggregate aggregateOfExpression:expression method:method alias:alias]];
  }
  return aggregates;
}

// search, compute, orderby, top, skip, and the top and bottom kin.
+ (instancetype)readOther:(NSString *)name inside:(NSString *)inside text:(NSString *)text error:(NSError **)error
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_groupPaths = @[];
  t->_aggregates = @[];
  NSString *trimmed = [inside stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSNumber *(^number)(NSString *) = ^NSNumber *(NSString *value) {
    NSScanner *scanner = [NSScanner scannerWithString:[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    double d;
    return [scanner scanDouble:&d] && scanner.isAtEnd && d >= 0 ? @(d) : nil;
  };
  if ([name isEqualToString:@"search"]) {
    t->_kind = ODataApplySearch;
    t->_search = [ODataSearchExpression searchWithString:trimmed error:error];
    return t->_search ? t : nil;
  }
  if ([name isEqualToString:@"compute"] || [name isEqualToString:@"orderby"]) {
    ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:@{ [@"$" stringByAppendingString:name]: trimmed } error:error];
    if (!options) return nil;
    t->_kind = [name isEqualToString:@"compute"] ? ODataApplyCompute : ODataApplyOrderBy;
    t->_compute = options.compute;
    t->_orderBy = options.orderBy;
    return t;
  }
  if ([name isEqualToString:@"top"] || [name isEqualToString:@"skip"]) {
    t->_kind = [name isEqualToString:@"top"] ? ODataApplyTop : ODataApplySkip;
    t->_number = number(trimmed);
    if (!t->_number || t->_number.doubleValue != floor(t->_number.doubleValue)) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@ takes a count", name], text);
      return nil;
    }
    return t;
  }
  NSArray *arguments = OISSplitTop(trimmed, ',');
  t->_kind = ODataApplyTopBottom;
  t->_method = name;
  t->_number = arguments.count == 2 ? number(arguments[0]) : nil;
  if (!t->_number && arguments.count == 2) {
    t->_numberExpression = [ODataExpression expressionWithString:arguments[0] error:NULL];
    if (t->_numberExpression.kind == ODataExpressionLiteral) t->_numberExpression = nil;  // a negative one
  }
  t->_expression = t->_number || t->_numberExpression ? [ODataExpression expressionWithString:arguments[1] error:error] : nil;
  if (!t->_expression) {
    if (error && !*error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@ takes a number and a value", name], text);
    return nil;
  }
  return t;
}

+ (instancetype)orderByItems:(NSArray<ODataOrderItem *> *)items
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyOrderBy;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  t->_orderBy = [items copy];
  return t;
}

+ (instancetype)computeItems:(NSArray<ODataComputeItem *> *)items
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyCompute;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  t->_compute = [items copy];
  return t;
}

+ (instancetype)searchWith:(ODataSearchExpression *)search
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplySearch;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  t->_search = search;
  return t;
}

+ (instancetype)top:(NSUInteger)count
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyTop;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  t->_number = @(count);
  return t;
}

+ (instancetype)skip:(NSUInteger)count
{
  ODataApplyTransformation *t = [self top:count];
  t->_kind = ODataApplySkip;
  return t;
}

+ (instancetype)hierarchical:(NSString *)method hierarchy:(NSArray<NSString *> *)hierarchy qualifier:(NSString *)qualifier
                    nodePath:(NSArray<NSString *> *)nodePath sequence:(NSArray *)sequence
                 maxDistance:(NSUInteger)maxDistance keepStart:(BOOL)keepStart
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyHierarchy;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  t->_method = [method copy];
  t->_hierarchy = [hierarchy copy];
  t->_qualifier = [qualifier copy];
  t->_nodePath = [nodePath copy];
  t->_sequence = [sequence copy];
  t->_number = maxDistance ? @(maxDistance) : nil;
  t->_keepStart = keepStart;
  return t;
}

+ (instancetype)traverseHierarchy:(NSArray<NSString *> *)hierarchy qualifier:(NSString *)qualifier
                         nodePath:(NSArray<NSString *> *)nodePath postorder:(BOOL)postorder orderBy:(NSArray *)orderBy
{
  ODataApplyTransformation *t = [self hierarchical:@"traverse" hierarchy:hierarchy qualifier:qualifier nodePath:nodePath sequence:@[]
                                       maxDistance:0 keepStart:NO];
  t->_sequence = nil;
  t->_traversal = postorder ? @"postorder" : @"preorder";
  t->_orderBy = [orderBy copy];
  return t;
}

// ancestors, descendants and traverse (section 6).
+ (instancetype)readHierarchical:(NSString *)name inside:(NSString *)inside text:(NSString *)text error:(NSError **)error
{
  NSArray<NSString *> *arguments = OISSplitTop(inside, ',');
  BOOL traverse = [name isEqualToString:@"traverse"];
  NSString *usage = traverse ? @"traverse takes $root/set, a qualifier, a path, preorder or postorder, and an ordering"
                             : [name stringByAppendingString:@" takes $root/set, a qualifier, a path, transformations, a distance and keep start"];
  NSArray *hierarchy = arguments.count >= 4 && [arguments[0] hasPrefix:@"$root/"] ? OISPath([arguments[0] substringFromIndex:6]) : nil;
  NSArray *qualifier = arguments.count >= 4 ? OISPath(arguments[1]) : nil;
  NSArray *nodePath = arguments.count >= 4 ? OISPath(arguments[2]) : nil;
  if (!hierarchy || qualifier.count != 1 || [arguments[1] rangeOfString:@"."].location != NSNotFound || !nodePath) {
    if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, usage, text);
    return nil;
  }
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyHierarchy;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  t->_method = name;
  t->_hierarchy = hierarchy;
  t->_qualifier = arguments[1];
  t->_nodePath = nodePath;
  NSArray *rest = [arguments subarrayWithRange:NSMakeRange(4, arguments.count - 4)];
  if (traverse) {
    if (![arguments[3] isEqualToString:@"preorder"] && ![arguments[3] isEqualToString:@"postorder"]) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, usage, text);
      return nil;
    }
    t->_traversal = arguments[3];
    if (rest.count) {
      ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:@{ @"$orderby": [rest componentsJoinedByString:@","] } error:error];
      if (!options) return nil;
      t->_orderBy = options.orderBy;
    }
    return t;
  }
  // T: transformations, or a condition standing for filter(condition)
  // (the spec's example 56 writes Name eq 'US').
  NSError *sequenceError = nil;
  t->_sequence = [self transformationsWithString:arguments[3] error:&sequenceError];
  if (!t->_sequence) {
    ODataExpression *condition = [ODataExpression expressionWithString:arguments[3] error:NULL];
    if (!condition) {
      if (error) *error = sequenceError;
      return nil;
    }
    t->_sequence = @[ [self filterWithExpression:condition] ];
  }
  for (NSUInteger i = 0; i < rest.count; i++) {
    NSString *argument = rest[i];
    NSInteger distance = argument.integerValue;
    if ([argument isEqualToString:@"keep start"] && i + 1 == rest.count) {
      t->_keepStart = YES;
    } else if (i == 0 && distance >= 1 && [argument isEqualToString:[NSString stringWithFormat:@"%ld", (long)distance]]) {
      t->_number = @(distance);
    } else {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, usage, text);
      return nil;
    }
  }
  return t;
}

+ (NSArray *)transformationsWithString:(NSString *)text error:(NSError **)error
{
  NSMutableArray *transformations = [NSMutableArray array];
  NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!trimmed.length) {
    if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, @"no transformation", text);
    return nil;
  }
  for (NSString *part in OISSplitTop(trimmed, '/')) {
    NSString *name = nil;
    if ([[part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:@"identity"]) {
      ODataApplyTransformation *t = [[self alloc] init];
      t->_kind = ODataApplyIdentity;
      t->_groupPaths = @[];
      t->_aggregates = @[];
      [transformations addObject:t];
      continue;
    }
    NSString *inside = OISCall(part, &name);
    if (!inside) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not a transformation", part], text);
      return nil;
    }
    if ([name isEqualToString:@"filter"]) {
      ODataExpression *expression = [ODataExpression expressionWithString:inside error:error];
      if (!expression) return nil;
      [transformations addObject:[self filterWithExpression:expression]];
    } else if ([name isEqualToString:@"aggregate"]) {
      NSArray *aggregates = [self aggregatesIn:inside text:text error:error];
      if (!aggregates) return nil;
      [transformations addObject:[self aggregateWith:aggregates]];
    } else if ([name isEqualToString:@"groupby"]) {
      NSArray *arguments = OISSplitTop(inside, ',');
      NSString *list = arguments.firstObject;
      if (![list hasPrefix:@"("] || ![list hasSuffix:@")"] || arguments.count > 2) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, @"groupby takes (paths) and an aggregate", text);
        return nil;
      }
      NSMutableArray *paths = [NSMutableArray array];
      for (NSString *item in OISSplitTop([list substringWithRange:NSMakeRange(1, list.length - 2)], ',')) {
        if ([item hasPrefix:@"rollup("] || [item isEqualToString:@"$all"]) {
          if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, @"rollup is not supported", text);
          return nil;
        }
        NSArray *path = OISPath(item);
        if (!path) {
          if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not a property path", item], text);
          return nil;
        }
        [paths addObject:path];
      }
      if (arguments.count < 2) {
        [transformations addObject:[self groupByPaths:paths aggregates:@[]]];
        continue;
      }
      // The transformations applied to each group: one aggregate, the
      // usual case, or any sequence (section 3.2.3).
      NSArray *sequence = [self transformationsWithString:arguments[1] error:error];
      if (!sequence) return nil;
      ODataApplyTransformation *only = sequence.count == 1 ? sequence.firstObject : nil;
      [transformations addObject:only.kind == ODataApplyAggregate ? [self groupByPaths:paths aggregates:only.aggregates]
                                                                  : [self groupByPaths:paths sequence:sequence]];
    } else if ([@[ @"search", @"compute", @"orderby", @"top", @"skip", @"topcount", @"topsum", @"toppercent",
                   @"bottomcount", @"bottomsum", @"bottompercent" ] containsObject:name]) {
      ODataApplyTransformation *t = [self readOther:name inside:inside text:text error:error];
      if (!t) return nil;
      [transformations addObject:t];
    } else if ([name isEqualToString:@"concat"]) {
      // Each argument a sequence of its own, on the same input.
      NSMutableArray *branches = [NSMutableArray array];
      for (NSString *branch in OISSplitTop(inside, ',')) {
        NSArray *sequence = [self transformationsWithString:branch error:error];
        if (!sequence) return nil;
        [branches addObject:sequence];
      }
      if (branches.count < 2) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, @"concat takes two sequences or more", text);
        return nil;
      }
      ODataApplyTransformation *t = [[self alloc] init];
      t->_kind = ODataApplyConcat;
      t->_groupPaths = @[];
      t->_aggregates = @[];
      t->_branches = branches;
      [transformations addObject:t];
    } else if ([name isEqualToString:@"expand"]) {
      // expand(Nav) or expand(Nav, filter(...)): as $expand=Nav($filter=...).
      NSArray *arguments = OISSplitTop(inside, ',');
      NSArray *path = OISPath(arguments.firstObject ?: @"");
      NSString *inner = nil, *filter = arguments.count == 2 ? OISCall(arguments[1], &inner) : nil;
      if (path.count != 1 || arguments.count > 2 || (arguments.count == 2 && (!filter || ![inner isEqualToString:@"filter"]))) {
        if (error) *error = OISApplyError(arguments.count == 2 && [inner isEqualToString:@"expand"] ? ODataIncrementalStoreErrorUnsupportedExpression
                                                                                                   : ODataIncrementalStoreErrorSyntax,
                                          @"expand takes a navigation property and a filter", text);
        return nil;
      }
      ODataApplyTransformation *t = [[self alloc] init];
      t->_kind = ODataApplyExpand;
      t->_groupPaths = @[];
      t->_aggregates = @[];
      t->_expansion = filter ? [NSString stringWithFormat:@"%@($filter=%@)", path[0], filter] : path[0];
      [transformations addObject:t];
    } else if ([name isEqualToString:@"join"] || [name isEqualToString:@"outerjoin"]) {
      // join(p as alias) or join(p as alias,transformations).
      NSArray *arguments = OISSplitTop(inside, ',');
      NSString *first = arguments.firstObject ?: @"";
      NSUInteger as = OISLastTopWord(first, @"as");
      NSArray *path = as == NSNotFound ? nil : OISPath([[first substringToIndex:as] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
      NSString *alias = as == NSNotFound ? nil : [[first substringFromIndex:as + 4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if (!path || OISPath(alias ?: @"").count != 1 || arguments.count > 2) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@ takes a path as an alias, and transformations", name], text);
        return nil;
      }
      NSArray *sequence = nil;
      if (arguments.count == 2) {
        sequence = [self transformationsWithString:arguments[1] error:error];
        if (!sequence) return nil;
      }
      ODataApplyTransformation *t = [[self alloc] init];
      t->_kind = ODataApplyJoin;
      t->_groupPaths = @[];
      t->_aggregates = @[];
      t->_joinPath = path;
      t->_alias = alias;
      t->_outer = [name isEqualToString:@"outerjoin"];
      t->_sequence = sequence;
      [transformations addObject:t];
    } else if ([@[ @"ancestors", @"descendants", @"traverse" ] containsObject:name]) {
      ODataApplyTransformation *t = [self readHierarchical:name inside:inside text:text error:error];
      if (!t) return nil;
      [transformations addObject:t];
    } else if ([name isEqualToString:@"nest"]) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ is not supported", name], text);
      return nil;
    } else {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@ is not a transformation", name], text);
      return nil;
    }
  }
  return transformations;
}

@end

#pragma mark - Evaluating

@implementation ODataAggregation

+ (NSSet *)methods
{
  static NSSet *methods;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    methods = [NSSet setWithObjects:@"sum", @"min", @"max", @"average", @"countdistinct", nil];
  });
  return methods;
}

static NSDecimalNumber *OISDecimal(NSNumber *n)
{
  return [n isKindOfClass:[NSDecimalNumber class]] ? (NSDecimalNumber *)n : [NSDecimalNumber decimalNumberWithDecimal:n.decimalValue];
}

static BOOL OISIsReal(NSNumber *n)
{
  if ([n isKindOfClass:[NSDecimalNumber class]]) return NO;
  const char *type = n.objCType;
  return type && (type[0] == 'd' || type[0] == 'f');
}

// A value, or each of a collection's (to-many relationships reached on
// the way), nulls left out.
static void OISAddValues(NSMutableArray *values, id value)
{
  if (!value || value == [NSNull null]) return;
  if ([value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSOrderedSet class]]) {
    for (id member in value) OISAddValues(values, member);
    return;
  }
  [values addObject:value];
}

+ (NSArray *)valuesAtKeyPath:(NSString *)keyPath inObjects:(NSArray *)objects
{
  NSMutableArray *values = [NSMutableArray array];
  for (id object in objects) OISAddValues(values, [object valueForKeyPath:keyPath]);
  return values;
}

+ (id)aggregate:(ODataAggregate *)aggregate over:(NSArray *)objects
{
  if (!aggregate.path) return @(objects.count);
  NSString *keyPath = [aggregate.path componentsJoinedByString:@"."];
  NSMutableArray *values = [NSMutableArray array];
  for (id object in objects) OISAddValues(values, [object valueForKeyPath:keyPath]);
  if (aggregate.isCount) return @(values.count);
  NSString *method = aggregate.method;
  if ([method isEqualToString:@"countdistinct"]) return @([NSSet setWithArray:values].count);
  if (!values.count) return [NSNull null];
  if ([method isEqualToString:@"min"] || [method isEqualToString:@"max"]) {
    id best = values.firstObject;
    BOOL min = [method isEqualToString:@"min"];
    for (id value in values) {
      NSComparisonResult order = [value compare:best];
      if ((min && order == NSOrderedAscending) || (!min && order == NSOrderedDescending)) best = value;
    }
    return best;
  }
  // sum and average: of numbers, exactly unless one is a double.
  BOOL real = NO;
  for (id value in values) {
    if (![value isKindOfClass:[NSNumber class]]) return [NSNull null];
    if (OISIsReal(value)) real = YES;
  }
  if (real) {
    double total = 0;
    for (NSNumber *value in values) total += value.doubleValue;
    return [method isEqualToString:@"average"] ? @(total / values.count) : @(total);
  }
  NSDecimalNumber *total = [NSDecimalNumber zero];
  for (NSNumber *value in values) total = [total decimalNumberByAdding:OISDecimal(value)];
  if ([method isEqualToString:@"average"]) {
    return [total decimalNumberByDividingBy:[NSDecimalNumber decimalNumberWithDecimal:@(values.count).decimalValue]];
  }
  return total;
}

+ (NSArray *)groupObjects:(NSArray *)objects byKeyPaths:(NSArray *)keyPaths aggregates:(NSArray *)aggregates
{
  return [self groupObjects:objects byKeyPaths:keyPaths aggregates:aggregates custom:nil];
}

+ (NSArray *)groupObjects:(NSArray *)objects byKeyPaths:(NSArray *)keyPaths aggregates:(NSArray *)aggregates
                   custom:(id (^)(ODataAggregate *, NSArray *))custom
{
  NSMutableArray *order = [NSMutableArray array];
  NSMutableDictionary *groups = [NSMutableDictionary dictionary];
  for (id object in objects) {
    NSMutableArray *key = [NSMutableArray array];
    for (NSString *keyPath in keyPaths) [key addObject:[object valueForKeyPath:keyPath] ?: [NSNull null]];
    if (!groups[key]) {
      groups[key] = [NSMutableArray array];
      [order addObject:key];
    }
    [groups[key] addObject:object];
  }
  if (!keyPaths.count && !order.count) {
    [order addObject:@[]];
    groups[@[]] = [NSMutableArray array];
  }
  NSMutableArray *rows = [NSMutableArray array];
  for (NSArray *key in order) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < keyPaths.count; i++) row[keyPaths[i]] = key[i];
    for (ODataAggregate *aggregate in aggregates) {
      if (aggregate.isCustom) {
        row[aggregate.alias] = (custom ? custom(aggregate, groups[key]) : nil) ?: [NSNull null];
        continue;
      }
      row[aggregate.alias] = [self aggregate:aggregate over:groups[key]];
    }
    [rows addObject:row];
  }
  return rows;
}

static NSExpression *OISRowOperand(ODataExpression *e, NSError **error)
{
  if (e.kind == ODataExpressionLiteral) {
    return [NSExpression expressionForConstantValue:e.value == [NSNull null] ? nil : e.value];
  }
  NSArray *path = e.memberPath;
  if (e.kind == ODataExpressionMember && path.count) {
    return [NSExpression expressionForKeyPath:[path componentsJoinedByString:@"."]];
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ over aggregated rows", e]);
  return nil;
}

+ (id)valueOfExpression:(ODataExpression *)e inRow:(id)row error:(NSError **)error
{
  if (e.kind == ODataExpressionLiteral) return e.value;
  NSArray *path = e.memberPath;
  if (e.kind == ODataExpressionMember && path.count) {
    id value = row;
    for (NSString *segment in path) value = [value isKindOfClass:[NSDictionary class]] ? value[segment] : [value valueForKey:segment];
    return value ?: [NSNull null];
  }
  BOOL negate = e.kind == ODataExpressionUnary && [e.name isEqualToString:@"-"];
  BOOL arithmetic = e.kind == ODataExpressionBinary && [@[ @"add", @"sub", @"mul", @"div", @"divby" ] containsObject:e.name];
  if (negate || arithmetic) {
    id l = [self valueOfExpression:negate ? e.operand : e.left inRow:row error:error];
    id r = negate ? @-1 : (l ? [self valueOfExpression:e.right inRow:row error:error] : nil);
    if (!l || !r) return nil;
    if (![l isKindOfClass:[NSNumber class]] || ![r isKindOfClass:[NSNumber class]]) return [NSNull null];
    // Decimals stay decimal; anything else is a double.
    if ([l isKindOfClass:[NSDecimalNumber class]] || [r isKindOfClass:[NSDecimalNumber class]]) {
      NSDecimalNumber *a = [l isKindOfClass:[NSDecimalNumber class]] ? l : [NSDecimalNumber decimalNumberWithDecimal:[l decimalValue]];
      NSDecimalNumber *b = [r isKindOfClass:[NSDecimalNumber class]] ? r : [NSDecimalNumber decimalNumberWithDecimal:[r decimalValue]];
      NSString *op = negate ? @"mul" : e.name;
      if ([op isEqualToString:@"add"]) return [a decimalNumberByAdding:b];
      if ([op isEqualToString:@"sub"]) return [a decimalNumberBySubtracting:b];
      if ([op isEqualToString:@"mul"]) return [a decimalNumberByMultiplyingBy:b];
      return [b isEqual:[NSDecimalNumber zero]] ? [NSNull null] : [a decimalNumberByDividingBy:b];
    }
    double a = [l doubleValue], b = [r doubleValue];
    NSString *op = negate ? @"mul" : e.name;
    if ([op isEqualToString:@"add"]) return @(a + b);
    if ([op isEqualToString:@"sub"]) return @(a - b);
    if ([op isEqualToString:@"mul"]) return @(a * b);
    return b == 0 ? [NSNull null] : @(a / b);
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ over aggregated rows", e]);
  return nil;
}

+ (NSArray *)rows:(NSArray *)rows values:(NSArray *)values method:(NSString *)method number:(double)number
{
  BOOL top = [method hasPrefix:@"top"];
  NSMutableArray *indexes = [NSMutableArray array];
  for (NSUInteger i = 0; i < rows.count; i++) {
    if ([values[i] isKindOfClass:[NSNumber class]]) [indexes addObject:@(i)];  // a null is none of them
  }
  [indexes sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
    NSComparisonResult order = [values[a.unsignedIntegerValue] compare:values[b.unsignedIntegerValue]];
    return top ? -order : order;
  }];
  double whole = 0;
  for (NSNumber *i in indexes) whole += [values[i.unsignedIntegerValue] doubleValue];
  double goal = [method hasSuffix:@"percent"] ? whole * number / 100.0 : number;
  NSMutableArray *out = [NSMutableArray array];
  double sum = 0;
  for (NSNumber *i in indexes) {
    if ([method hasSuffix:@"count"]) {
      if (out.count >= (NSUInteger)number) break;
    } else if (sum >= goal) {
      break;
    }
    [out addObject:rows[i.unsignedIntegerValue]];
    sum += [values[i.unsignedIntegerValue] doubleValue];
  }
  return out;
}

+ (NSPredicate *)predicateForExpression:(ODataExpression *)e error:(NSError **)error
{
  if (e.kind == ODataExpressionUnary && [e.name isEqualToString:@"not"]) {
    NSPredicate *inner = [self predicateForExpression:e.operand error:error];
    return inner ? [NSCompoundPredicate notPredicateWithSubpredicate:inner] : nil;
  }
  if (e.kind == ODataExpressionBinary && ([e.name isEqualToString:@"and"] || [e.name isEqualToString:@"or"])) {
    NSPredicate *left = [self predicateForExpression:e.left error:error];
    NSPredicate *right = left ? [self predicateForExpression:e.right error:error] : nil;
    if (!right) return nil;
    return [e.name isEqualToString:@"and"] ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ left, right ]]
                                           : [NSCompoundPredicate orPredicateWithSubpredicates:@[ left, right ]];
  }
  if (e.kind == ODataExpressionCall && [e.name isEqualToString:@"isdefined"]) {
    NSArray *path = e.arguments.count == 1 ? e.arguments[0].memberPath : nil;
    if (!path.count) {
      if (error) *error = OISError(ODataIncrementalStoreErrorSyntax, @"isdefined takes a property path");
      return nil;
    }
    // Defined: the row has the property, null or not.
    return [NSPredicate predicateWithBlock:^BOOL(id row, NSDictionary *bindings) {
      id at = row;
      for (NSString *segment in path) {
        if (![at isKindOfClass:[NSDictionary class]] || !at[segment]) return NO;
        at = at[segment];
      }
      return YES;
    }];
  }
  NSDictionary *operators = @{ @"eq": @(NSEqualToPredicateOperatorType), @"ne": @(NSNotEqualToPredicateOperatorType),
                               @"gt": @(NSGreaterThanPredicateOperatorType), @"ge": @(NSGreaterThanOrEqualToPredicateOperatorType),
                               @"lt": @(NSLessThanPredicateOperatorType), @"le": @(NSLessThanOrEqualToPredicateOperatorType) };
  NSNumber *type = e.kind == ODataExpressionBinary ? operators[e.name] : nil;
  if (!type) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ over aggregated rows", e]);
    return nil;
  }
  NSExpression *left = OISRowOperand(e.left, error);
  NSExpression *right = left ? OISRowOperand(e.right, error) : nil;
  if (!right) return nil;
  return [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:right modifier:NSDirectPredicateModifier
                                                       type:(NSPredicateOperatorType)type.unsignedIntegerValue options:0];
}

@end
