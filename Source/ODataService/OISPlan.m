// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OISPlan.h"

@implementation OISPlanMembers

+ (instancetype)membersOf:(NSArray *)nodes removing:(NSArray *)removes adding:(BOOL)adds
{
  OISPlanMembers *members = [[self alloc] init];
  members.nodes = nodes ?: @[];
  members.removes = removes ?: @[];
  members.adds = adds;
  return members;
}

@end

@implementation OISPlanNode

+ (instancetype)operator:(OISPlanOperator)op input:(OISPlanNode *)input
{
  OISPlanNode *node = [[self alloc] init];
  node.op = op;
  node.input = input;
  node.bindings = @{};
  node.fixed = @[];
  node.fixedSummary = @"";
  node.filters = @[];
  node.order = @[];
  node.prefetch = @[];
  node.nests = @[];
  node.computed = @{};
  node.values = @{};
  node.inputs = @[];
  node.sequences = @{};
  node.except = @[];
  return node;
}

static NSString *OISJoined(NSArray *items, NSString *separator)
{
  return [[items valueForKey:@"description"] componentsJoinedByString:separator];
}

// What it does, on one line, as explain prints it.
- (NSString *)line
{
  NSMutableArray *parts = [NSMutableArray array];
  switch (self.op) {
    case OISPlanScan: [parts addObject:[NSString stringWithFormat:@"Scan %@", self.entity.name]]; break;
    case OISPlanObjects:
      [parts addObject:self.objectsSummary ? [NSString stringWithFormat:@"Objects (%@)", self.objectsSummary]
                                           : [NSString stringWithFormat:@"Objects (%lu)", (unsigned long)self.objects.count]];
      break;
    case OISPlanChanges: [parts addObject:[NSString stringWithFormat:@"Changes of %@", self.entity.name]]; break;
    case OISPlanInput: [parts addObject:@"Input"]; break;
    case OISPlanSpan: [parts addObject:[NSString stringWithFormat:@"Span %@.%@", self.entity.name, self.attributeName]]; break;
    case OISPlanClosure:
      [parts addObject:[NSString stringWithFormat:@"Closure $root/%@#%@", [self.hierarchy componentsJoinedByString:@"/"], self.qualifier]];
      break;
    case OISPlanSelect: [parts addObject:[@"Select " stringByAppendingString:OISJoined(self.filters, @" and ")]]; break;
    case OISPlanSort: [parts addObject:[@"Sort " stringByAppendingString:OISJoined(self.order, @", ")]]; break;
    case OISPlanLimit: {
      [parts addObject:@"Limit"];
      if (self.skip) [parts addObject:[NSString stringWithFormat:@"skip %@", self.skip]];
      if (self.top) [parts addObject:[NSString stringWithFormat:@"top %@", self.top]];
      if (self.pageSize) [parts addObject:[NSString stringWithFormat:@"page %lu", (unsigned long)self.pageSize]];
      break;
    }
    case OISPlanApply: [parts addObject:[NSString stringWithFormat:@"Apply %@", self.transformation]]; break;
    case OISPlanNest: [parts addObject:[NSString stringWithFormat:@"Nest %@", self.item.isStar ? @"*" : [self.item.path componentsJoinedByString:@"/"]]]; break;
    case OISPlanValue: [parts addObject:[NSString stringWithFormat:@"Value %@", self.expression]]; break;
    case OISPlanCount: [parts addObject:@"Count"]; break;
    case OISPlanStoreScan:
    case OISPlanStoreCount: {
      [parts addObject:[NSString stringWithFormat:@"%@ %@", self.op == OISPlanStoreScan ? @"Store scan" : @"Store count", self.entity.name]];
      NSMutableArray *where = [NSMutableArray arrayWithArray:[self.filters valueForKey:@"description"]];
      if (self.search) [where addObject:[NSString stringWithFormat:@"search %@", self.search]];
      if (self.time) [where addObject:@"at its time"];
      if (self.fixedSummary.length) [where addObject:self.fixedSummary];
      if (where.count) [parts addObject:[@"where " stringByAppendingString:[where componentsJoinedByString:@" and "]]];
      if (self.op == OISPlanStoreScan) {
        NSMutableArray *sort = [NSMutableArray arrayWithArray:[self.order valueForKey:@"description"]];
        if (self.keyOrder) [sort addObject:@"key"];
        if (self.after) [parts addObject:@"after a key"];
        if (sort.count) [parts addObject:[@"sort " stringByAppendingString:[sort componentsJoinedByString:@", "]]];
        if (self.skip.unsignedIntegerValue) [parts addObject:[NSString stringWithFormat:@"skip %@", self.skip]];
        if (self.top) [parts addObject:[NSString stringWithFormat:@"top %@", self.top]];
        if (self.pageSize) [parts addObject:[NSString stringWithFormat:@"page %lu", (unsigned long)self.pageSize]];
        if (self.limit) [parts addObject:[NSString stringWithFormat:@"at most %lu", (unsigned long)self.limit]];
        if (self.prefetch.count) [parts addObject:[@"with " stringByAppendingString:[self.prefetch componentsJoinedByString:@", "]]];
      }
      break;
    }
    case OISPlanStoreAggregate: [parts addObject:[NSString stringWithFormat:@"Store aggregate %@", self.transformation]]; break;
    case OISPlanLookup:
      [parts addObject:[NSString stringWithFormat:@"Lookup %@", self.reference ?: self.entity.name]];
      if (self.optional) [parts addObject:@"or none"];
      break;
    case OISPlanSequence:
      [parts addObject:[NSString stringWithFormat:@"Sequence %@.%@ from Store scan %@ sort %@ desc top 1", self.entity.name, self.attributeName,
                                                  self.entity.name, self.attributeName]];
      break;
    case OISPlanInsert:
    case OISPlanUpdate: {
      NSString *verb = self.op == OISPlanInsert ? @"Insert" : self.replace ? @"Replace" : @"Update";
      [parts addObject:[NSString stringWithFormat:@"%@ %@", verb, self.entity.name]];
      NSMutableArray *set = [NSMutableArray array];
      for (NSString *name in [self.values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![self.values[name] isKindOfClass:[OISPlanNode class]] && ![self.values[name] isKindOfClass:[OISPlanMembers class]]) [set addObject:name];
      }
      if (set.count) [parts addObject:[@"set " stringByAppendingString:[set componentsJoinedByString:@", "]]];
      break;
    }
    case OISPlanDelete: [parts addObject:[NSString stringWithFormat:@"Delete %@", self.entity.name]]; break;
    case OISPlanLink:
    case OISPlanUnlink:
      [parts addObject:[NSString stringWithFormat:@"%@ %@.%@", self.op == OISPlanLink ? @"Link" : @"Unlink", self.entity.name, self.relationship.name]];
      break;
    case OISPlanMerge: [parts addObject:[NSString stringWithFormat:@"Merge %@", self.entity.name]]; break;
    case OISPlanTemporal:
      [parts addObject:[NSString stringWithFormat:@"Temporal %@ of %@ (%lu delta time slices)", self.action, self.entity.name, (unsigned long)self.deltas.count]];
      break;
    case OISPlanCall: [parts addObject:[NSString stringWithFormat:@"Call %@", self.reference]]; break;
    case OISPlanCommit: [parts addObject:@"Commit"]; break;
  }
  if (self.op == OISPlanScan) {
    NSMutableArray *where = [NSMutableArray array];
    if (self.fixedSummary.length) [where addObject:self.fixedSummary];
    if (where.count) [parts addObject:[@"where " stringByAppendingString:[where componentsJoinedByString:@" and "]]];
  }
  return [parts componentsJoinedByString:@" "];
}

- (void)describeInto:(NSMutableString *)text depth:(NSUInteger)depth
{
  NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
  [text appendFormat:@"%@%@\n", indent, [self line]];
  for (NSString *name in [self.bindings.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [text appendFormat:@"%@  %@ :=\n", indent, name];
    [self.bindings[name] describeInto:text depth:depth + 2];
  }
  if (self.nested) {
    [text appendFormat:@"%@  each:\n", indent];
    [self.nested describeInto:text depth:depth + 2];
  }
  for (OISPlanNode *nest in self.nests) [nest describeInto:text depth:depth + 1];
  [self describeWriteInto:text indent:indent depth:depth];
  [self.input describeInto:text depth:depth + 1];
}

// What a write checks, and the rows it reads and writes first.
- (void)describeWriteInto:(NSMutableString *)text indent:(NSString *)indent depth:(NSUInteger)depth
{
  if (self.ifMatch) [text appendFormat:@"%@  Assert If-Match %@%@\n", indent, self.ifMatch, self.mediaAttribute ? @" (of the stream)" : @""];
  if (self.etag) [text appendFormat:@"%@  Assert @odata.etag %@\n", indent, self.etag];
  if (self.typed) [text appendFormat:@"%@  Assert a %@\n", indent, self.entity.name];
  if (self.failure) [text appendFormat:@"%@  Fails: %@\n", indent, self.failure.localizedDescription];
  if (self.op == OISPlanUpdate) [text appendFormat:@"%@  Assert the key and what is immutable unchanged\n", indent];
  for (NSString *name in [self.sequences.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [text appendFormat:@"%@  %@ :=\n", indent, name];
    [self.sequences[name] describeInto:text depth:depth + 2];
  }
  for (NSString *name in [self.values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    id value = self.values[name];
    if ([value isKindOfClass:[OISPlanNode class]]) {
      [text appendFormat:@"%@  %@ :=\n", indent, name];
      [value describeInto:text depth:depth + 2];
    } else if ([value isKindOfClass:[OISPlanMembers class]]) {
      OISPlanMembers *members = value;
      [text appendFormat:@"%@  %@ := %@\n", indent, name, members.adds ? @"its members, and" : @"these"];
      for (id node in members.nodes) {
        if ([node isKindOfClass:[OISPlanNode class]]) [node describeInto:text depth:depth + 2];
      }
      if (members.removes.count) [text appendFormat:@"%@    but not\n", indent];
      for (id node in members.removes) {
        if ([node isKindOfClass:[OISPlanNode class]]) [node describeInto:text depth:depth + 3];
      }
    }
  }
  if (self.member) {
    [text appendFormat:@"%@  member:\n", indent];
    [self.member describeInto:text depth:depth + 2];
  }
  if (self.deltas.count) {
    for (NSDictionary *delta in self.deltas) {
      for (NSString *name in [delta.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![delta[name] isKindOfClass:[OISPlanNode class]]) continue;
        [text appendFormat:@"%@  %@ :=\n", indent, name];
        [delta[name] describeInto:text depth:depth + 2];
      }
    }
  }
  for (OISPlanNode *node in self.inputs) [node describeInto:text depth:depth + 1];
  if (self.target) [self.target describeInto:text depth:depth + 1];
  if (self.except.count) {
    [text appendFormat:@"%@  but not\n", indent];
    for (OISPlanNode *node in self.except) [node describeInto:text depth:depth + 2];
  }
  if (self.op == OISPlanMerge) {
    if (self.matched) {
      [text appendFormat:@"%@  when matched:\n", indent];
      [self.matched describeInto:text depth:depth + 2];
    }
    [text appendFormat:@"%@  otherwise:\n", indent];
    [self.otherwise describeInto:text depth:depth + 2];
  }
}

- (NSString *)treeDescription
{
  NSMutableString *text = [NSMutableString string];
  [self describeInto:text depth:0];
  return text;
}

- (NSString *)description
{
  return [self line];
}

@end

@implementation OISRelation

+ (instancetype)relationOfRows:(NSArray *)rows
{
  OISRelation *relation = [[self alloc] init];
  relation.rows = rows ?: @[];
  relation.computed = [NSMutableDictionary dictionary];
  relation.expansions = [NSMutableArray array];
  return relation;
}

- (id)copyWithZone:(NSZone *)zone
{
  OISRelation *copy = [OISRelation relationOfRows:self.rows];
  copy.shape = [self.shape mutableCopy];
  copy.computed = [self.computed mutableCopy];
  copy.expansions = [self.expansions mutableCopy];
  copy.hasMore = self.hasMore;
  copy.count = self.count;
  return copy;
}

@end

@implementation OISPlan

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _nests = @[];
  _closures = @[];
  _spans = @[];
  _dynamicSets = @[];
  _permissions = @{};
  _givenKeys = [NSMutableDictionary dictionary];
  return self;
}

- (NSString *)treeDescription
{
  NSMutableString *text = [NSMutableString string];
  if (self.write) {
    if (self.returning) {
      [text appendString:@"Returning\n"];
      for (NSString *line in [[self.returning treeDescription] componentsSeparatedByString:@"\n"]) {
        if (line.length) [text appendFormat:@"  %@\n", line];
      }
    }
    [self.write describeInto:text depth:0];
    [self describePermissionsInto:text];
    return text;
  }
  for (OISPlanNode *closure in self.closures) [closure describeInto:text depth:0];
  for (OISPlanNode *span in self.spans) [span describeInto:text depth:0];
  for (OISPlanNode *nest in self.nests) [nest describeInto:text depth:0];
  [self.root describeInto:text depth:0];
  if (self.count) {
    [text appendString:@"$count :=\n"];
    [self.count describeInto:text depth:1];
  }
  for (NSString *set in self.dynamicSets) [text appendFormat:@"Dynamic properties (%@)\n", set];
  [self describePermissionsInto:text];
  return text;
}

- (void)describePermissionsInto:(NSMutableString *)text
{
  for (NSString *what in [self.permissions.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSArray *scopes = [self.permissions[what].allObjects sortedArrayUsingSelector:@selector(compare:)];
    [text appendFormat:@"Permission to %@: %@\n", what, [scopes componentsJoinedByString:@" or "]];
  }
}

@end
