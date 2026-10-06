// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataHierarchyPredicate.h"
#import "ODataQuery.h"
#import "ODataPredicateTranslator.h"
#import <ODataKit/ODataRegex.h>
#import <ODataKit/ODataApply.h>
#import "ODataError.h"
#import "ODataFunctionExpression.h"
#include <string.h>

@interface ODataPredicateTranslator ()
// Inside a lambda (any/all), paths start from this variable, not the
// entity being fetched; nested lambdas number theirs by depth.
@property (nonatomic, copy, nullable) NSString *lambdaVariable;
@property (nonatomic) NSUInteger lambdaDepth;
// The attribute a comparison's constant is compared with: it decides how
// the constant is written (a Date as an Edm.Date, a Decimal without an
// exponent, a Boolean from @0).
@property (nonatomic, strong, nullable) NSAttributeDescription *comparedAttribute;
// Or the type it is compared with, where that is no attribute's: a member
// of a complex value, an element of a collection.
@property (nonatomic, copy, nullable) NSString *comparedType;
// Inside a lambda over a collection of values (not of entities): their
// type, which paths inside the lambda start from.
@property (nonatomic, copy, nullable) NSString *elementType;
// Inside a SUBQUERY written as a lambda: its variable, whose key paths
// ($s.city) are the lambda variable's.
@property (nonatomic, copy, nullable) NSString *subqueryVariable;
// Translating a counted SUBQUERY's condition into $count($filter=...):
// its variable is the member counted ($this, and its paths bare), SELF is
// $it. A key path not through the variable is refused: in a SUBQUERY it
// is the outer object's (as Apple's stores and evaluation read it), which
// the filter would read as the member's. throughVariable: mapping a path
// that came through it.
@property (nonatomic) BOOL countFilter;
@property (nonatomic) NSInteger throughVariable;
// Under an odd number of NOTs. Core Data's conditions are two-valued: a
// function of nil, or ANY over a nil to-one's collection, is false, and
// NOT of it true. OData's are three-valued: those are null, and not null is
// null (URL conventions 5.1.1.1.9), which $filter leaves out. So under NOT
// such a condition is written with its operands' nulls ruled out, which
// makes it false where Core Data has it false.
@property (nonatomic) BOOL negated;
@end

// An expression that applies a key path to another (the variable of a
// SUBQUERY, $s.city, or the subquery itself, SUBQUERY(...).@count): on
// Apple a valueForKeyPath: function, in gnustep-base a key path
// composition.
static BOOL OISKeyPathOn(NSExpression *expression, NSExpression **base, NSString **keyPath)
{
  if (expression.expressionType == NSFunctionExpressionType && [expression.function isEqualToString:@"valueForKeyPath:"]) {
    NSExpression *argument = expression.arguments.firstObject;
    NSString *path = nil;
    if ([argument respondsToSelector:@selector(keyPath)]) path = [(id)argument keyPath];
    if (!path && argument.expressionType == NSConstantValueExpressionType && [argument.constantValue isKindOfClass:[NSString class]]) path = argument.constantValue;
    if (!path) return NO;
    *base = expression.operand;
    *keyPath = path;
    return YES;
  }
#if !defined(__APPLE__)
  if (expression.expressionType == NSKeyPathCompositionExpressionType) {
    NSExpression *right = [expression rightExpression];
    if (right.expressionType != NSKeyPathExpressionType) return NO;
    *base = [expression leftExpression];
    *keyPath = right.keyPath;
    return YES;
  }
#endif
  return NO;
}

// The entities a type test names: `entity == E`, `entity IN {E, F}`.
static NSArray<NSEntityDescription *> *OISEntitiesIn(NSExpression *expression)
{
  if (expression.expressionType == NSAggregateExpressionType) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSExpression *e in expression.collection) {
      if (e.expressionType != NSConstantValueExpressionType || ![e.constantValue isKindOfClass:[NSEntityDescription class]]) return nil;
      [out addObject:e.constantValue];
    }
    return out;
  }
  if (expression.expressionType != NSConstantValueExpressionType) return nil;
  id value = expression.constantValue;
  if ([value isKindOfClass:[NSEntityDescription class]]) return @[ value ];
  if ([value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSOrderedSet class]]) value = [value allObjects];
  if (![value isKindOfClass:[NSArray class]]) return nil;
  for (id v in value) {
    if (![v isKindOfClass:[NSEntityDescription class]]) return nil;
  }
  return value;
}

@implementation ODataPredicateTranslator

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper entity:(NSEntityDescription *)entity
{
  self = [super init];
  if (!self) return nil;
  _mapper = mapper;
  _entity = entity;
  _version = @"4.0";
  return self;
}

- (NSString *)translatePredicate:(NSPredicate *)predicate error:(NSError **)error
{
  return [self expressionForPredicate:predicate error:error].description;
}

- (NSString *)translateExpression:(NSExpression *)expression error:(NSError **)error
{
  return [self expressionForValue:expression error:error].description;
}

- (ODataPredicateTranslator *)innerFor:(NSEntityDescription *)entity
{
  ODataPredicateTranslator *inner = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
  inner.lambdaDepth = self.lambdaDepth + 1;
  inner.keysForObjectID = self.keysForObjectID;
  inner.version = self.version;
  inner.writesAggregates = self.writesAggregates;
  inner.negated = self.negated;
  return inner;
}

// condition, which is null where an operand is (a function's argument, a
// lambda's collection through a to-one), as Core Data has it under NOT:
// false there (false and null is false: 5.1.1.1.7).
- (ODataExpression *)known:(ODataExpression *)condition operands:(NSArray<ODataExpression *> *)operands negated:(BOOL)negated
                     error:(NSError **)error
{
  if (!negated || !condition) return condition;
  ODataExpression *known = condition;
  for (ODataExpression *operand in operands) {
    if (operand.kind == ODataExpressionLiteral) continue;
    ODataExpression *null = [self literalFromText:@"null" error:error];
    ODataExpression *there = null ? [ODataExpression binary:@"ne" left:operand right:null error:error] : nil;
    known = there ? [ODataExpression binary:@"and" left:known right:there error:error] : nil;
    if (!known) return nil;
  }
  return known;
}

// a and b and c, left to right, as the parser reads it; none is `empty`.
static ODataExpression *OISJoined(NSArray<ODataExpression *> *parts, NSString *op, BOOL empty, NSError **error)
{
  if (!parts.count) return [ODataExpression literalWithValue:@(empty)];
  ODataExpression *out = parts.firstObject;
  for (NSUInteger i = 1; i < parts.count; i++) out = [ODataExpression binary:op left:out right:parts[i] error:error];
  return out;
}

// name(argument); nil for a nil argument (what built it has said why).
static ODataExpression *OISCall1(NSString *name, ODataExpression *argument, NSError **error)
{
  return argument ? [ODataExpression call:name arguments:@[ argument ] error:error] : nil;
}

// A path as OData writes it (Category/Name, Zoo.Lion/MaxRoar, Address/City)
// on from an expression (nil: from $it): a segment with a dot is a type
// cast.
// nil, and the error, for a segment that is no name OData allows there.
static ODataExpression *OISAlongPath(ODataExpression *from, NSString *path, NSError **error)
{
  ODataExpression *e = from;
  for (NSString *segment in [path componentsSeparatedByString:@"/"]) {
    if (!segment.length) continue;
    e = [segment rangeOfString:@"."].location != NSNotFound ? [ODataExpression cast:segment of:e error:error]
                                                            : [ODataExpression member:segment of:e error:error];
    if (!e) return nil;
  }
  return e;
}

// A literal as the value coder writes it, typed.
- (ODataExpression *)literalFromText:(NSString *)text error:(NSError **)error
{
  ODataExpression *e = text ? [ODataExpression literalWithText:text] : nil;
  if (!e && error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"No literal: %@", text]);
  return e;
}

- (ODataExpression *)expressionForPredicate:(NSPredicate *)predicate error:(NSError **)error
{
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    return [self translateCompound:(NSCompoundPredicate *)predicate error:error];
  }
  if ([predicate isKindOfClass:[NSComparisonPredicate class]]) {
    return [self translateComparison:(NSComparisonPredicate *)predicate error:error];
  }
  if ([predicate isKindOfClass:[ODataFilterPredicate class]]) {
    // As it is written: the caller's OData, read.
    NSString *filter = ((ODataFilterPredicate *)predicate).filter;
    ODataExpression *e = [ODataExpression expressionWithString:filter error:error];
    if (!e && error && !*error) *error = OISError(ODataIncrementalStoreErrorSyntax, filter);
    return e;
  }
  if ([predicate isKindOfClass:[ODataHierarchyPredicate class]]) {
    return [self translateHierarchy:(ODataHierarchyPredicate *)predicate error:error];
  }
  if ([predicate.predicateFormat isEqualToString:@"TRUEPREDICATE"]) return [ODataExpression literalWithValue:@YES];
  if ([predicate.predicateFormat isEqualToString:@"FALSEPREDICATE"]) return [ODataExpression literalWithValue:@NO];
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, predicate.description);
  return nil;
}

// Aggregation.isdescendant(HierarchyNodes=$root/Set,HierarchyQualifier='Q',
// Node=path,Ancestor=...) and the rest (Data Aggregation section 5.5.1.1).
- (ODataExpression *)translateHierarchy:(ODataHierarchyPredicate *)h error:(NSError **)error
{
  if (!self.writesAggregates) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"%@: the service has no Data Aggregation (Aggregation.ApplySupported)", h]);
    return nil;
  }
  NSString *nodeKeyPath = nil;
  NSEntityDescription *entity = [ODataHierarchyPredicate entityOfHierarchy:h.qualifier model:self.entity.managedObjectModel
                                                                    mapper:self.mapper nodeKeyPath:&nodeKeyPath parent:NULL];
  if (!entity || (!h.nodeKeyPath && ![self.entity isKindOfEntity:entity])) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 entity ? [NSString stringWithFormat:@"%@: %@ is no node of it; say which key path leads to one", h, self.entity.name]
                                        : [NSString stringWithFormat:@"%@: no entity has the recursive hierarchy %@ (Aggregation.RecursiveHierarchy)", h, h.qualifier]);
    return nil;
  }
  ODataExpression *node = [self mapKeyPath:h.nodeKeyPath ?: nodeKeyPath error:error];
  if (!node) return nil;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  ODataExpression *nodes = [ODataExpression member:[self.mapper entitySetForEntity:root] of:[ODataExpression variable:@"$root" error:error] error:error];
  if (!nodes) return nil;
  parameters[@"HierarchyNodes"] = nodes;
  parameters[@"HierarchyQualifier"] = [ODataExpression literalWithValue:h.qualifier];
  parameters[@"Node"] = node;
  NSString *other = h.test == ODataHierarchyIsAncestor ? @"Descendant" : h.test == ODataHierarchyIsDescendant ? @"Ancestor"
                  : h.test == ODataHierarchyIsSibling ? @"Other" : nil;
  if (other) {
    if (!h.node) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, [NSString stringWithFormat:@"%@: which node?", h]);
      return nil;
    }
    NSAttributeDescription *identifier = (NSAttributeDescription *)[self propertyAtKeyPath:nodeKeyPath of:entity];
    ODataExpression *literal = [self literalFromText:[self.mapper.values literalForValue:h.node attribute:identifier] error:error];
    if (!literal) return nil;
    parameters[other] = literal;
    if (h.maxDistance && h.test != ODataHierarchyIsSibling) parameters[@"MaxDistance"] = [ODataExpression literalWithValue:@(h.maxDistance)];
    if (h.includeSelf && h.test != ODataHierarchyIsSibling) parameters[@"IncludeSelf"] = [ODataExpression literalWithValue:@YES];
  }
  return [ODataExpression call:[@"Org.OData.Aggregation.V1." stringByAppendingString:h.functionName] of:nil namedArguments:parameters error:error];
}

- (NSPropertyDescription *)propertyAtKeyPath:(NSString *)keyPath of:(NSEntityDescription *)entity
{
  NSPropertyDescription *property = nil;
  for (NSString *name in [keyPath componentsSeparatedByString:@"."]) {
    property = entity.propertiesByName[name];
    entity = [property isKindOfClass:[NSRelationshipDescription class]] ? ((NSRelationshipDescription *)property).destinationEntity : nil;
  }
  return property;
}

- (ODataExpression *)translateCompound:(NSCompoundPredicate *)compound error:(NSError **)error
{
  NSMutableArray *parts = [NSMutableArray array];
  BOOL not = compound.compoundPredicateType == NSNotPredicateType;
  if (not) self.negated = !self.negated;
  for (NSPredicate *sub in compound.subpredicates) {
    ODataExpression *t = [self expressionForPredicate:sub error:error];
    if (!t) {
      if (not) self.negated = !self.negated;
      return nil;
    }
    [parts addObject:t];
  }
  if (not) self.negated = !self.negated;
  switch (compound.compoundPredicateType) {
    case NSAndPredicateType: return OISJoined(parts, @"and", YES, error);
    case NSOrPredicateType: return OISJoined(parts, @"or", NO, error);
    case NSNotPredicateType:
      return parts.count ? [ODataExpression unary:@"not" operand:parts.firstObject error:error] : [ODataExpression literalWithValue:@NO];
    default:
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, compound.description);
      return nil;
  }
}

- (ODataExpression *)function:(NSString *)name left:(ODataExpression *)lhs right:(ODataExpression *)rhs caseInsensitive:(BOOL)ci
                         error:(NSError **)error
{
  if (ci) {
    lhs = OISCall1(@"tolower", lhs, error);
    rhs = OISCall1(@"tolower", rhs, error);
  }
  if (!lhs || !rhs) return nil;
  return [ODataExpression call:name arguments:@[ lhs, rhs ] error:error];
}

- (ODataExpression *)translateComparison:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  // OData has no diacritic-insensitive comparison, and dropping [d] would
  // fetch fewer rows than Core Data would match.
  if (cmp.options & NSDiacriticInsensitivePredicateOption) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"[d] has no OData equivalent: %@", cmp]);
    return nil;
  }
  if (cmp.comparisonPredicateModifier != NSDirectPredicateModifier) {
    return [self translateLambda:cmp error:error];
  }
  if ([self comparesObjects:cmp.rightExpression]) {
    return [self translateObjectComparison:cmp error:error];
  }
  if (cmp.predicateOperatorType == NSLikePredicateOperatorType || cmp.predicateOperatorType == NSMatchesPredicateOperatorType) {
    return [self translatePattern:cmp error:error];
  }
  BOOL handled = NO;
  ODataExpression *special = [self translateTypeTest:cmp handled:&handled error:error];
  if (handled) return special;
  special = [self translateCount:cmp handled:&handled error:error];
  if (handled) return special;
  self.comparedAttribute = [self attributeAtExpression:cmp.leftExpression] ?: [self attributeAtExpression:cmp.rightExpression];
  self.comparedType = [self typeAtExpression:cmp.leftExpression] ?: [self typeAtExpression:cmp.rightExpression];
  ODataExpression *lhs = [self expressionForValue:cmp.leftExpression error:error];
  ODataExpression *rhs = lhs ? [self expressionForValue:cmp.rightExpression error:error] : nil;
  if (!rhs) {
    self.comparedAttribute = nil;
    self.comparedType = nil;
    return nil;
  }
  BOOL ci = (cmp.options & NSCaseInsensitivePredicateOption) != 0;
  // ==[c] as tolower on both sides, as startswith and the others have it.
  ODataExpression *lowered = ci ? OISCall1(@"tolower", lhs, error) : lhs;
  ODataExpression *loweredRight = ci ? OISCall1(@"tolower", rhs, error) : rhs;
  switch (cmp.predicateOperatorType) {
    case NSEqualToPredicateOperatorType:
      return [ODataExpression binary:@"eq" left:lowered right:loweredRight error:error];
    case NSNotEqualToPredicateOperatorType:
      return [ODataExpression binary:@"ne" left:lowered right:loweredRight error:error];
    case NSLessThanPredicateOperatorType:
      return [ODataExpression binary:@"lt" left:lhs right:rhs error:error];
    case NSLessThanOrEqualToPredicateOperatorType:
      return [ODataExpression binary:@"le" left:lhs right:rhs error:error];
    case NSGreaterThanPredicateOperatorType:
      return [ODataExpression binary:@"gt" left:lhs right:rhs error:error];
    case NSGreaterThanOrEqualToPredicateOperatorType:
      return [ODataExpression binary:@"ge" left:lhs right:rhs error:error];
    case NSBeginsWithPredicateOperatorType:
      return [self known:[self function:@"startswith" left:lhs right:rhs caseInsensitive:ci error:error] operands:@[ lhs, rhs ]
                 negated:self.negated error:error];
    case NSEndsWithPredicateOperatorType:
      return [self known:[self function:@"endswith" left:lhs right:rhs caseInsensitive:ci error:error] operands:@[ lhs, rhs ]
                 negated:self.negated error:error];
    case NSContainsPredicateOperatorType:
      return [self known:[self function:@"contains" left:lhs right:rhs caseInsensitive:ci error:error] operands:@[ lhs, rhs ]
                 negated:self.negated error:error];
    case NSInPredicateOperatorType: {
      NSArray *literals = [self literalsInExpression:cmp.rightExpression error:error];
      return literals ? [self membership:lhs literals:literals error:error] : nil;
    }
    case NSBetweenPredicateOperatorType:
      if (cmp.rightExpression.expressionType == NSAggregateExpressionType) {
        NSArray *col = cmp.rightExpression.collection;
        if ([col isKindOfClass:[NSArray class]] && col.count == 2) {
          ODataExpression *low = [self expressionForValue:col[0] error:error];
          ODataExpression *high = low ? [self expressionForValue:col[1] error:error] : nil;
          if (!high) return nil;
          return [ODataExpression binary:@"and" left:[ODataExpression binary:@"ge" left:lhs right:low error:error]
                                   right:[ODataExpression binary:@"le" left:lhs right:high error:error] error:error];
        }
      }
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
      return nil;
    default:
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
      return nil;
  }
}

- (BOOL)speaks401
{
  return [self.version compare:@"4.01" options:NSNumericSearch] != NSOrderedAscending;
}

// x in (a, b) in 4.01 (Part 2 section 5.1.1.1.12); x eq a or x eq b in
// 4.0, which has no `in`. Nothing to be in is false.
- (ODataExpression *)membership:(ODataExpression *)lhs literals:(NSArray<ODataExpression *> *)literals error:(NSError **)error
{
  if (!literals.count) return [ODataExpression literalWithValue:@NO];
  if (literals.count == 1) return [ODataExpression binary:@"eq" left:lhs right:literals[0] error:error];
  if (self.speaks401) return [ODataExpression binary:@"in" left:lhs right:[ODataExpression list:literals] error:error];
  NSMutableArray *parts = [NSMutableArray array];
  for (ODataExpression *literal in literals) {
    ODataExpression *equal = [ODataExpression binary:@"eq" left:lhs right:literal error:error];
    if (!equal) return nil;
    [parts addObject:equal];
  }
  return OISJoined(parts, @"or", NO, error);
}

// The members of IN's right side, each as a literal.
- (NSArray<ODataExpression *> *)literalsInExpression:(NSExpression *)expression error:(NSError **)error
{
  NSMutableArray *literals = [NSMutableArray array];
  if (expression.expressionType == NSAggregateExpressionType && [expression.collection isKindOfClass:[NSArray class]]) {
    for (NSExpression *e in expression.collection) {
      ODataExpression *t = [self expressionForValue:e error:error];
      if (!t) return nil;
      [literals addObject:t];
    }
    return literals;
  }
  id value = expression.expressionType == NSConstantValueExpressionType ? expression.constantValue : nil;
  if ([value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSOrderedSet class]]) value = [value allObjects];
  if (![value isKindOfClass:[NSArray class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"IN needs a collection: %@", expression]);
    return nil;
  }
  for (id v in value) {
    ODataExpression *literal = [self literal:v error:error];
    if (!literal) return nil;
    [literals addObject:literal];
  }
  return literals;
}

// LIKE and MATCHES: matchesPattern with an ECMAScript regular expression,
// anchored, since both match the whole string (Part 2 section
// 5.1.1.5.4, 4.01 only). The pattern is read as the platform's NSPredicate
// reads it and written as OData's, or refused where the two cannot say
// the same (ODataRegex.h).
- (ODataExpression *)translatePattern:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  BOOL like = cmp.predicateOperatorType == NSLikePredicateOperatorType;
  BOOL ci = (cmp.options & NSCaseInsensitivePredicateOption) != 0;
  id pattern = cmp.rightExpression.expressionType == NSConstantValueExpressionType ? cmp.rightExpression.constantValue : nil;
  NSString *why = nil;
  if (!self.speaks401) why = @"needs OData 4.01 (matchesPattern), and the service speaks 4.0";
  else if (![pattern isKindOfClass:[NSString class]]) why = @"needs a constant pattern";
  else if (ci && !like) why = @"cannot be case-insensitive: a regular expression cannot be lowercased safely";
  NSString *regex = nil;
  if (!why) {
    NSError *failure = nil;
    ODataRegex *read = [ODataRegex regexWithString:ci ? [pattern lowercaseString] : pattern
                                           dialect:like ? ODataRegexLike : ODataRegexMatches error:&failure];
    regex = [[read whole] stringInDialect:ODataRegexECMAScript error:&failure];
    if (!regex) why = failure.localizedDescription;
  }
  if (why) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"%@ %@: %@", like ? @"LIKE" : @"MATCHES", why, cmp]);
    return nil;
  }
  ODataExpression *lhs = [self expressionForValue:cmp.leftExpression error:error];
  if (!lhs) return nil;
  ODataExpression *subject = ci ? OISCall1(@"tolower", lhs, error) : lhs;
  if (!subject) return nil;
  return [self known:[ODataExpression call:@"matchesPattern" arguments:@[ subject, [ODataExpression literalWithValue:regex] ] error:error]
            operands:@[ lhs ]
             negated:self.negated
               error:error];
}

- (ODataExpression *)expressionForValue:(NSExpression *)expression error:(NSError **)error
{
  switch (expression.expressionType) {
    case NSConstantValueExpressionType:
      // gnustep-base rewrites BETWEEN into >= AND <= and wraps each bound,
      // already an NSExpression, in a second constant expression.
      if ([expression.constantValue isKindOfClass:[NSExpression class]]) {
        return [self expressionForValue:expression.constantValue error:error];
      }
      return [self literal:expression.constantValue error:error];
    case NSKeyPathExpressionType:
      return [self mapKeyPath:expression.keyPath error:error];
    case NSEvaluatedObjectExpressionType:
      return [ODataExpression variable:self.lambdaVariable ?: @"$it" error:error];
    case NSVariableExpressionType:
      if (self.subqueryVariable && [expression.variable isEqualToString:self.subqueryVariable]) {
        return [ODataExpression variable:self.lambdaVariable ?: @"$this" error:error];
      }
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
      return nil;
    case NSFunctionExpressionType: {
      NSError *pathError = nil;
      ODataExpression *variablePath = [self translateVariablePath:expression handled:NULL error:&pathError];
      if (variablePath) return variablePath;
      if (pathError) {
        if (error) *error = pathError;
        return nil;
      }
      return [self translateFunction:expression error:error];
    }
#if !defined(__APPLE__)
    case NSKeyPathCompositionExpressionType: {
      ODataExpression *variablePath = [self translateVariablePath:expression handled:NULL error:error];
      if (variablePath) return variablePath;
      if (error && !*error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
      return nil;
    }
#endif
    case NSAggregateExpressionType: {
      NSArray *col = expression.collection;
      if (![col isKindOfClass:[NSArray class]]) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
        return nil;
      }
      NSMutableArray *inner = [NSMutableArray array];
      for (NSExpression *e in col) {
        ODataExpression *t = [self expressionForValue:e error:error];
        if (!t) return nil;
        [inner addObject:t];
      }
      return [ODataExpression list:inner];
    }
    default:
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
      return nil;
  }
}

// $these/aggregate(Amount with sum), $these/$count.
- (ODataExpression *)translateThese:(ODataTheseExpression *)expression error:(NSError **)error
{
  if (!self.writesAggregates || self.lambdaVariable) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                 [NSString stringWithFormat:@"%@: %@", expression,
                                  self.lambdaVariable ? @"only of the collection the fetch filters, not inside ANY or ALL"
                                                      : @"the service has no Data Aggregation (Aggregation.ApplySupported)"]);
    return nil;
  }
  ODataExpression *these = [ODataExpression variable:@"$these" error:error];
  if (!expression.method) return [ODataExpression countOf:these];
  if (![@[ @"sum", @"average", @"min", @"max", @"countdistinct" ] containsObject:expression.method] ||
      ![self attributeAtKeyPath:expression.aggregatedKeyPath entity:self.entity]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                 [NSString stringWithFormat:@"%@: sum, average, min, max or countdistinct of an attribute of %@", expression, self.entity.name]);
    return nil;
  }
  NSString *path = [self.mapper propertyPathForKeyPath:expression.aggregatedKeyPath entity:self.entity];
  return [self aggregateOf:these path:path method:expression.method error:error];
}

// collection/aggregate(path with method), built: a name that is no OData
// identifier is refused, not written into the filter.
- (ODataExpression *)aggregateOf:(ODataExpression *)collection path:(NSString *)path method:(NSString *)method error:(NSError **)error
{
  ODataAggregate *aggregate = [ODataAggregate aggregateOfPath:[path componentsSeparatedByString:@"/"] method:method alias:@"value" error:error];
  return aggregate ? [ODataExpression aggregateOf:collection aggregate:aggregate error:error] : nil;
}

- (ODataExpression *)translateFunction:(NSExpression *)expression error:(NSError **)error
{
  if ([expression isKindOfClass:[ODataTheseExpression class]]) return [self translateThese:(ODataTheseExpression *)expression error:error];
  if ([expression isKindOfClass:[ODataFunctionExpression class]]) {
    return [self translateODataFunction:(ODataFunctionExpression *)expression type:NULL attribute:NULL error:error];
  }
  NSString *name = expression.function;
  NSArray *args = expression.arguments ?: @[];
  if ([name isEqualToString:@"lowercase:"] || [name isEqualToString:@"uppercase:"]) {
    ODataExpression *inner = [self expressionForValue:args.firstObject error:error];
    if (!inner) return nil;
    return OISCall1([name hasPrefix:@"lower"] ? @"tolower" : @"toupper", inner, error);
  }
  // Arithmetic, as Apple and gnustep-base each name it.
  NSDictionary *operators = @{ @"add:to:": @"add", @"from:subtract:": @"sub", @"multiply:by:": @"mul", @"divide:by:": @"div",
                               @"modulus:by:": @"mod", @"_add": @"add", @"_sub": @"sub", @"_mul": @"mul", @"_div": @"div" };
  NSString *op = operators[name];
  if (op && args.count == 2) {
    ODataExpression *left = [self expressionForValue:args[0] error:error];
    ODataExpression *right = left ? [self expressionForValue:args[1] error:error] : nil;
    return right ? [ODataExpression binary:op left:left right:right error:error] : nil;
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
  return nil;
}

// A key path as a property path, from the lambda variable inside a
// lambda: relationships and attributes (a complex value's members after
// its attribute) as the mapper names them, a subentity's property after a
// cast to it (Default.Manager/Budget), @count after a to-many relationship
// as $count, @sum, @avg, @min and @max after one as aggregate() where the
// service has it (Products/aggregate(UnitPrice with sum)), length after a
// string attribute as length(). Anything else is no property of the model,
// and an error, not a guess.
- (ODataExpression *)mapKeyPath:(NSString *)path error:(NSError **)error
{
  if (self.countFilter && !self.throughVariable) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"%@: in a counted SUBQUERY, a key path not through its variable is the outer "
                                                            @"object's; write it through the variable ($%@.%@)", path, self.subqueryVariable, path]);
    return nil;
  }
  // nil: from $it. So each step built is checked: a failed one is no $it.
  ODataExpression *mapped = nil;
  if (self.lambdaVariable) {
    mapped = [ODataExpression variable:self.lambdaVariable error:error];
    if (!mapped) return nil;
  }
  if (self.elementType) {
    return OISAlongPath(mapped, [self.mapper memberPath:[path componentsSeparatedByString:@"."] ofType:self.elementType memberType:NULL], error);
  }
  NSArray<NSString *> *parts = [path componentsSeparatedByString:@"."];
  NSEntityDescription *current = self.entity;
  BOOL collection = NO;
  for (NSUInteger i = 0; i < parts.count; i++) {
    NSString *part = parts[i];
    BOOL last = i + 1 == parts.count;
    if ([part isEqualToString:@"@count"] && last && collection) return [ODataExpression countOf:mapped];
    NSString *method = @{ @"@sum": @"sum", @"@avg": @"average", @"@min": @"min", @"@max": @"max" }[part];
    if (method && collection && !last) {
      if (!self.writesAggregates) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                     [NSString stringWithFormat:@"%@: the service has no aggregate() (Aggregation.ApplySupported)", path]);
        return nil;
      }
      NSString *rest = [[parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)] componentsJoinedByString:@"."];
      NSPropertyDescription *end = nil;
      NSEntityDescription *at = current;
      for (NSString *name in [rest componentsSeparatedByString:@"."]) {
        end = at.propertiesByName[name];
        NSRelationshipDescription *through = [end isKindOfClass:[NSRelationshipDescription class]] ? (NSRelationshipDescription *)end : nil;
        if (through.isToMany) end = nil;
        if (!end) break;
        at = through.destinationEntity;
      }
      if (![end isKindOfClass:[NSAttributeDescription class]]) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                     [NSString stringWithFormat:@"%@: %@ is no attribute of %@ through to-one relationships", path, rest, current.name]);
        return nil;
      }
      return [self aggregateOf:mapped path:[self.mapper propertyPathForKeyPath:rest entity:current] method:method error:error];
    }
    if (collection) break;
    NSPropertyDescription *property = current.propertiesByName[part];
    if (!property) {
      // A subentity's own, after a cast to it.
      NSMutableArray *queue = [current.subentities mutableCopy];
      while (queue.count && !property) {
        NSEntityDescription *sub = queue.firstObject;
        [queue removeObjectAtIndex:0];
        property = sub.propertiesByName[part];
        if (property) {
          NSString *cast = [self.mapper qualifiedTypeForEntity:sub];
          if (!cast) break;
          mapped = [ODataExpression cast:cast of:mapped error:error];
          if (!mapped) return nil;
          current = sub;
        } else {
          [queue addObjectsFromArray:sub.subentities];
        }
      }
    }
    if (property && ![self.mapper servesProperty:property]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                   [NSString stringWithFormat:@"%@.%@ is not the service's (OData.served NO): it cannot filter or sort by it (in %@)",
                                                              current.name, part, path]);
      return nil;
    }
    if ([property isKindOfClass:[NSAttributeDescription class]]) {
      NSAttributeDescription *attribute = (NSAttributeDescription *)property;
      NSArray *rest = [parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)];
      if ([self.mapper attributeHoldsDynamicProperties:attribute]) {
        // dynamicProperties.Nickname: the dynamic property Nickname.
        if (!rest.count) {
          if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                       [NSString stringWithFormat:@"%@: name a dynamic property in %@ (%@.Name)", path, part, part]);
          return nil;
        }
        return OISAlongPath(mapped, [rest componentsJoinedByString:@"/"], error);
      }
      mapped = [ODataExpression member:[self.mapper propertyForAttribute:attribute] of:mapped error:error];
      if (!mapped) return nil;
      if (rest.count == 1 && [rest[0] isEqualToString:@"length"] && attribute.attributeType == NSStringAttributeType) {
        return OISCall1(@"length", mapped, error);
      }
      if (rest.count) mapped = OISAlongPath(mapped, [self.mapper memberPath:rest ofType:[self.mapper.values typeNameOfAttribute:attribute] memberType:NULL], error);
      return mapped;
    }
    if ([property isKindOfClass:[NSRelationshipDescription class]]) {
      NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
      mapped = [ODataExpression member:[self.mapper propertyForRelationship:relationship] of:mapped error:error];
      if (!mapped) return nil;
      current = relationship.destinationEntity;
      collection = relationship.isToMany;
      continue;
    }
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                 [NSString stringWithFormat:@"%@ has no property %@ (in %@)", current.name, part, path]);
    return nil;
  }
  // A path through a to-many relationship: ANY or ALL says which member.
  NSUInteger crossed = 0;
  NSEntityDescription *walk = self.entity;
  for (NSString *part in parts) {
    NSRelationshipDescription *relationship = walk.relationshipsByName[part];
    if (!relationship) break;
    crossed++;
    if (relationship.isToMany && crossed < parts.count) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                   [NSString stringWithFormat:@"%@ goes through the collection %@: say which member with ANY or ALL", path, part]);
      return nil;
    }
    walk = relationship.destinationEntity;
  }
  return mapped ?: [ODataExpression variable:@"$it" error:error];
}

// $s.city inside a SUBQUERY: the lambda variable's path; nil for any other
// expression (an error only where it is one and cannot be written).
- (ODataExpression *)translateVariablePath:(NSExpression *)expression handled:(BOOL *)handled error:(NSError **)error
{
  NSExpression *base = nil;
  NSString *keyPath = nil;
  if (!OISKeyPathOn(expression, &base, &keyPath) || base.expressionType != NSVariableExpressionType) return nil;
  if (!self.subqueryVariable || ![base.variable isEqualToString:self.subqueryVariable]) return nil;
  self.throughVariable++;
  ODataExpression *mapped = [self mapKeyPath:keyPath error:error];
  self.throughVariable--;
  return mapped;
}

#pragma mark - Types and counts

// isof for `entity == E` (E and not its subentities) and `entity IN {...}`,
// of the object or one it reaches (manager.entity). The entities that are
// the set's own, and those under them not in it, as isof and not isof.
- (ODataExpression *)translateTypeTest:(NSComparisonPredicate *)cmp handled:(BOOL *)handled error:(NSError **)error
{
  *handled = NO;
  NSExpression *left = cmp.leftExpression;
  NSString *keyPath = nil;
  NSExpression *base = nil;
  if (left.expressionType == NSKeyPathExpressionType) {
    keyPath = left.keyPath;
  } else if (!(OISKeyPathOn(left, &base, &keyPath) && base.expressionType == NSVariableExpressionType &&
               self.subqueryVariable && [base.variable isEqualToString:self.subqueryVariable])) {
    return nil;
  }
  if (![keyPath isEqualToString:@"entity"] && ![keyPath hasSuffix:@".entity"]) return nil;
  *handled = YES;
  NSArray<NSEntityDescription *> *entities = OISEntitiesIn(cmp.rightExpression);
  NSPredicateOperatorType type = cmp.predicateOperatorType;
  if (!entities.count || (type != NSEqualToPredicateOperatorType && type != NSNotEqualToPredicateOperatorType && type != NSInPredicateOperatorType)) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"a type test compares entity with an entity, or one of some: %@", cmp]);
    return nil;
  }
  ODataExpression *object = nil;
  if ([keyPath hasSuffix:@".entity"]) {
    if (base) self.throughVariable++;
    object = [self mapKeyPath:[keyPath substringToIndex:keyPath.length - 7] error:error];
    if (base) self.throughVariable--;
    if (!object) return nil;
  } else if (self.lambdaVariable) {
    object = [ODataExpression variable:self.lambdaVariable error:error];
    if (!object) return nil;
  }
  NSSet *set = [NSSet setWithArray:entities];
  NSMutableArray *clauses = [NSMutableArray array];
  for (NSEntityDescription *entity in entities) {
    if (entity.superentity && [set containsObject:entity.superentity]) continue;
    NSMutableArray *terms = [NSMutableArray array];
    ODataExpression *root = [self isof:entity object:object error:error];
    if (!root) return nil;
    [terms addObject:root];
    NSMutableArray *walk = [NSMutableArray arrayWithObject:entity];
    while (walk.count) {
      NSEntityDescription *node = walk.lastObject;
      [walk removeLastObject];
      for (NSEntityDescription *sub in node.subentities) {
        if ([set containsObject:sub]) {
          [walk addObject:sub];
        } else {
          ODataExpression *excluded = [self isof:sub object:object error:error];
          if (!excluded) return nil;
          ODataExpression *notOf = [ODataExpression unary:@"not" operand:excluded error:error];
          if (!notOf) return nil;
          [terms addObject:notOf];
        }
      }
    }
    [clauses addObject:OISJoined(terms, @"and", YES, error)];
  }
  ODataExpression *test = OISJoined(clauses, @"or", NO, error);
  return type == NSNotEqualToPredicateOperatorType ? [ODataExpression unary:@"not" operand:test error:error] : test;
}

- (ODataExpression *)isof:(NSEntityDescription *)entity object:(ODataExpression *)object error:(NSError **)error
{
  NSString *type = [self.mapper qualifiedTypeForEntity:entity];
  if (!type) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, [NSString stringWithFormat:@"%@ has no entity type to test for", entity.name]);
    return nil;
  }
  ODataExpression *named = [ODataExpression cast:type of:nil error:error];
  if (!named) return nil;
  return [ODataExpression call:@"isof" arguments:object ? @[ object, named ] : @[ named ] error:error];
}

// count:(collection) and collection.@count as $count; a SUBQUERY's count
// against nought as any (or not any, or all).
- (ODataExpression *)translateCount:(NSComparisonPredicate *)cmp handled:(BOOL *)handled error:(NSError **)error
{
  *handled = NO;
  NSExpression *left = cmp.leftExpression, *right = cmp.rightExpression;
  NSPredicateOperatorType type = cmp.predicateOperatorType;
  NSExpression *counted = [self countedIn:left];
  if (!counted) {
    counted = [self countedIn:right];
    if (!counted) return nil;
    NSExpression *swap = left;
    left = right;
    right = swap;
    NSDictionary *mirror = @{ @(NSLessThanPredicateOperatorType): @(NSGreaterThanPredicateOperatorType),
                              @(NSLessThanOrEqualToPredicateOperatorType): @(NSGreaterThanOrEqualToPredicateOperatorType),
                              @(NSGreaterThanPredicateOperatorType): @(NSLessThanPredicateOperatorType),
                              @(NSGreaterThanOrEqualToPredicateOperatorType): @(NSLessThanOrEqualToPredicateOperatorType) };
    if (mirror[@(type)]) type = [mirror[@(type)] unsignedIntegerValue];
  }
  *handled = YES;
  if (counted.expressionType == NSKeyPathExpressionType) {
    // count:(suppliers): suppliers.@count.
    NSComparisonPredicate *plain = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:[counted.keyPath stringByAppendingString:@".@count"]]
                                                                      rightExpression:right modifier:NSDirectPredicateModifier type:type options:0];
    return [self translateComparison:plain error:error];
  }
  id value = right.expressionType == NSConstantValueExpressionType ? right.constantValue : nil;
  BOOL zero = [value isKindOfClass:[NSNumber class]] && [value doubleValue] == 0;
  BOOL one = [value isKindOfClass:[NSNumber class]] && [value doubleValue] == 1;
  BOOL some = (zero && (type == NSGreaterThanPredicateOperatorType || type == NSNotEqualToPredicateOperatorType)) ||
              (one && type == NSGreaterThanOrEqualToPredicateOperatorType);
  BOOL none = (zero && (type == NSEqualToPredicateOperatorType || type == NSLessThanOrEqualToPredicateOperatorType)) ||
              (one && type == NSLessThanPredicateOperatorType);
  if (!some && !none && !self.speaks401) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"a SUBQUERY is counted against nought, as any or none, at OData 4.0 "
                                                            @"($count($filter=...) is 4.01's): %@", cmp]);
    return nil;
  }
  NSExpression *collection = counted.collection;
  if (collection.expressionType != NSKeyPathExpressionType) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, [NSString stringWithFormat:@"a SUBQUERY of %@", collection]);
    return nil;
  }
  NSEntityDescription *element = nil;
  NSEntityDescription *walk = self.entity;
  for (NSString *part in [collection.keyPath componentsSeparatedByString:@"."]) {
    NSRelationshipDescription *relationship = walk.relationshipsByName[part];
    walk = relationship.destinationEntity;
    element = relationship.isToMany ? walk : element;
  }
  ODataExpression *path = [self mapKeyPath:collection.keyPath error:error];
  if (!path) return nil;
  if (!element) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, [NSString stringWithFormat:@"%@ is not a collection", collection.keyPath]);
    return nil;
  }
  if (!some && !none) return [self filteredCount:counted path:path element:element type:type value:right error:error];
  // none of NOT q is all of q.
  NSPredicate *body = counted.predicate;
  NSString *function = @"any";
  if (none && [body isKindOfClass:[NSCompoundPredicate class]] && [(NSCompoundPredicate *)body compoundPredicateType] == NSNotPredicateType) {
    body = [(NSCompoundPredicate *)body subpredicates].firstObject;
    function = @"all";
    none = NO;
  }
  ODataPredicateTranslator *inner = [self innerFor:element];
  inner.lambdaVariable = [NSString stringWithFormat:@"x%lu", (unsigned long)self.lambdaDepth];
  inner.subqueryVariable = counted.variable;
  // none is not any: what it asks of the members is under that not.
  inner.negated = none ? !self.negated : self.negated;
  ODataExpression *test = [inner expressionForPredicate:body error:error];
  if (!test) return nil;
  ODataExpression *lambda = [ODataExpression lambda:function of:path variable:inner.lambdaVariable body:test error:error];
  if (none && lambda) lambda = [ODataExpression unary:@"not" operand:lambda error:error];
  // Through a nil to-one the count is nil, and the comparison false, any
  // or none alike: the guard goes on the whole of it.
  return [self known:lambda operands:[self toOnesBefore:collection.keyPath error:error] negated:self.negated error:error];
}

// SUBQUERY(cars, $c, q).@count > 1, at 4.01: Cars/$count($filter=q') gt 1,
// where q' reads $c's paths as the member's and SELF as $it.
- (ODataExpression *)filteredCount:(NSExpression *)counted path:(ODataExpression *)path element:(NSEntityDescription *)element
                              type:(NSPredicateOperatorType)type value:(NSExpression *)value error:(NSError **)error
{
  NSDictionary *operators = @{ @(NSEqualToPredicateOperatorType): @"eq", @(NSNotEqualToPredicateOperatorType): @"ne",
                               @(NSLessThanPredicateOperatorType): @"lt", @(NSLessThanOrEqualToPredicateOperatorType): @"le",
                               @(NSGreaterThanPredicateOperatorType): @"gt", @(NSGreaterThanOrEqualToPredicateOperatorType): @"ge" };
  NSString *op = operators[@(type)];
  if (!op) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"a SUBQUERY's count compared with =, !=, <, <=, > or >=: %@", counted]);
    return nil;
  }
  ODataPredicateTranslator *inner = [self innerFor:element];
  inner.subqueryVariable = counted.variable;
  inner.countFilter = YES;
  ODataExpression *test = [inner expressionForPredicate:counted.predicate error:error];
  if (!test) return nil;
  ODataExpression *right = [self expressionForValue:value error:error];
  if (!right) return nil;
  return [ODataExpression binary:op left:[ODataExpression countOf:path filter:test] right:right error:error];
}

// What an expression counts: the SUBQUERY of count:(SUBQUERY(...)) or
// SUBQUERY(...).@count, or the key path of count:(suppliers).
- (NSExpression *)countedIn:(NSExpression *)expression
{
  NSExpression *inner = nil;
  if (expression.expressionType == NSFunctionExpressionType && [expression.function isEqualToString:@"count:"] && expression.arguments.count == 1) {
    inner = expression.arguments.firstObject;
  } else {
    NSExpression *base = nil;
    NSString *keyPath = nil;
    if (OISKeyPathOn(expression, &base, &keyPath) && [keyPath isEqualToString:@"@count"]) inner = base;
  }
  if (inner.expressionType == NSSubqueryExpressionType) return inner;
  if (inner.expressionType == NSKeyPathExpressionType && [expression.function isEqualToString:@"count:"]) return inner;
  return nil;
}

#pragma mark - The service's functions

- (NSEntityDescription *)modelEntityForType:(NSString *)qualified
{
  for (NSEntityDescription *entity in self.entity.managedObjectModel.entities) {
    if ([[self.mapper qualifiedTypeForEntity:entity] isEqualToString:qualified]) return entity;
  }
  return nil;
}

// NS.GetFavoriteAirline()/Name: the call, bound to the entity the binding
// key path leads to (or to a collection, when it ends in a to-many
// relationship), and the path into its result. Through type and
// attribute, what the path ends at, for the literal it is compared with.
- (ODataExpression *)translateODataFunction:(ODataFunctionExpression *)expression
                                       type:(NSString **)typeOut
                                  attribute:(NSAttributeDescription **)attributeOut
                                      error:(NSError **)error
{
  NSString *why = nil;
  ODataSchema *schema = self.mapper.schema;
  NSEntityDescription *bound = self.entity;
  BOOL collection = NO;
  if (!schema) why = @"needs the service's $metadata";
  else if (self.elementType) why = @"is bound to entities, not to a collection of values";
  for (NSString *part in why ? @[] : [expression.bindingKeyPath componentsSeparatedByString:@"."] ?: @[]) {
    NSRelationshipDescription *rel = collection ? nil : bound.relationshipsByName[part];
    if (!rel) {
      why = [NSString stringWithFormat:@"is bound through %@, which is no relationship to follow", expression.bindingKeyPath];
      break;
    }
    bound = rel.destinationEntity;
    collection = rel.isToMany;
  }
  ODataSchemaEntityType *boundType = why ? nil : [self.mapper entityTypeForEntity:bound];
  if (!why && !boundType) why = [NSString stringWithFormat:@"is bound to %@, which has no entity type in $metadata", bound.name];
  NSSet *names = [NSSet setWithArray:expression.parameters.allKeys];
  ODataSchemaOperation *function = boundType ? [schema operationNamed:expression.functionName boundToEntityType:boundType
                                                              collection:collection parameterNames:names] : nil;
  if (!why && (!function || function.isAction)) {
    why = [NSString stringWithFormat:@"is no function bound to %@%@", collection ? @"a collection of " : @"", boundType.qualifiedName];
  }

  NSMutableDictionary *arguments = [NSMutableDictionary dictionary];
  for (NSString *given in why ? @[] : [expression.parameters.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaParameter *parameter = nil;
    for (ODataSchemaParameter *p in function.callerParameters) {
      if ([p.name isEqualToString:given] || (!parameter && [p.name caseInsensitiveCompare:given] == NSOrderedSame)) parameter = p;
    }
    if (!parameter) {
      why = [NSString stringWithFormat:@"has no parameter %@", given];
      break;
    }
    ODataExpression *literal = [ODataExpression literalWithText:[self.mapper.values literalForValue:expression.parameters[given] typeName:parameter.type]];
    if (!literal) {
      why = [NSString stringWithFormat:@"cannot take %@ for %@", expression.parameters[given], given];
      break;
    }
    arguments[parameter.name] = literal;
  }

  // Into the result: an entity's properties, a complex value's members.
  NSString *resultPath = nil;
  NSString *resultType = function.returnType;
  NSAttributeDescription *attribute = nil;
  if (!why && expression.resultKeyPath) {
    NSEntityDescription *resultEntity = [schema entityTypeNamed:resultType] ? [self modelEntityForType:resultType] : nil;
    if (resultEntity) {
      NSString *memberType = nil;
      resultPath = [self.mapper propertyPathForKeyPath:expression.resultKeyPath entity:resultEntity memberType:&memberType];
      attribute = [self attributeAtKeyPath:expression.resultKeyPath entity:resultEntity];
      resultType = memberType;
    } else if ([schema complexTypeNamed:resultType]) {
      NSString *memberType = nil;
      resultPath = [self.mapper memberPath:[expression.resultKeyPath componentsSeparatedByString:@"."] ofType:resultType memberType:&memberType];
      resultType = memberType;
    } else {
      why = [NSString stringWithFormat:@"returns %@, which has no %@ to follow", resultType ?: @"nothing", expression.resultKeyPath];
    }
  }
  if (why) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                 [NSString stringWithFormat:@"%@ %@", expression.functionName, why]);
    return nil;
  }

  ODataExpression *prefix = nil;
  if (expression.bindingKeyPath || self.lambdaVariable) {
    prefix = expression.bindingKeyPath ? [self mapKeyPath:expression.bindingKeyPath error:error]
                                       : [ODataExpression variable:self.lambdaVariable error:error];
    if (!prefix) return nil;
  }
  ODataExpression *call = [ODataExpression call:function.qualifiedName of:prefix namedArguments:arguments error:error];
  if (!call) return nil;
  if (resultPath.length) call = OISAlongPath(call, resultPath, error);
  if (typeOut) *typeOut = attribute ? nil : resultType;
  if (attributeOut) *attributeOut = attribute;
  return call;
}

#pragma mark - ANY / ALL

// ANY products.unitPrice > 100  ->  Products/any(x0:x0/UnitPrice gt 100)
// The key path splits at its first to-many relationship: what comes before
// is the collection, what comes after is compared inside the lambda. A
// further to-many step nests another lambda.
- (ODataExpression *)translateLambda:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  NSString *function = nil;
  switch (cmp.comparisonPredicateModifier) {
    case NSAnyPredicateModifier: function = @"any"; break;
    case NSAllPredicateModifier: function = @"all"; break;
    default: break;
  }
  NSExpression *left = cmp.leftExpression;
  if (!function || left.expressionType != NSKeyPathExpressionType) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
    return nil;
  }

  // Walk the path to its first collection: a to-many relationship, or an
  // attribute or complex member holding a collection of values.
  NSArray *parts = [left.keyPath componentsSeparatedByString:@"."];
  NSEntityDescription *current = self.elementType ? nil : self.entity;
  NSString *currentType = self.elementType;
  NSEntityDescription *elementEntity = nil;
  NSString *elementType = nil;
  NSUInteger i = 0;
  for (; i < parts.count; i++) {
    NSString *type = nil;
    if (current) {
      NSRelationshipDescription *rel = current.relationshipsByName[parts[i]];
      if (rel) {
        if (rel.isToMany) {
          elementEntity = rel.destinationEntity;
          break;
        }
        current = rel.destinationEntity;
        continue;
      }
      NSAttributeDescription *attr = current.attributesByName[parts[i]];
      if (!attr) break;
      type = [self.mapper.values typeNameOfAttribute:attr];
      current = nil;
    } else {
      [self.mapper memberPath:@[ parts[i] ] ofType:currentType memberType:&type];
    }
    if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) {
      elementType = [type substringWithRange:NSMakeRange(11, type.length - 12)];
      break;
    }
    if (!type) break;
    currentType = type;
  }
  NSComparisonPredicate *direct =
      [NSComparisonPredicate predicateWithLeftExpression:left
                                         rightExpression:cmp.rightExpression
                                                modifier:NSDirectPredicateModifier
                                                    type:cmp.predicateOperatorType
                                                 options:cmp.options];
  // No collection on the path: ANY and ALL of one value is the value.
  if (!elementEntity && !elementType) return [self translateComparison:direct error:error];

  ODataExpression *collection = [self mapKeyPath:[[parts subarrayWithRange:NSMakeRange(0, i + 1)] componentsJoinedByString:@"."] error:error];
  if (!collection) return nil;
  NSArray *rest = [parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)];
  NSString *variable = [NSString stringWithFormat:@"x%lu", (unsigned long)self.lambdaDepth];

  ODataPredicateTranslator *inner = [self innerFor:elementEntity ?: self.entity];
  inner.elementType = elementType;
  inner.lambdaVariable = variable;
  NSExpression *innerLeft = rest.count
      ? [NSExpression expressionForKeyPath:[rest componentsJoinedByString:@"."]]
      : [NSExpression expressionForEvaluatedObject];
  // The same modifier again: it takes effect only if the rest of the path
  // crosses another collection.
  NSComparisonPredicate *innerPredicate =
      [NSComparisonPredicate predicateWithLeftExpression:innerLeft
                                         rightExpression:cmp.rightExpression
                                                modifier:(rest.count ? cmp.comparisonPredicateModifier : NSDirectPredicateModifier)
                                                    type:cmp.predicateOperatorType
                                                 options:cmp.options];
  ODataExpression *body = [inner expressionForPredicate:innerPredicate error:error];
  if (!body) return nil;
  ODataExpression *lambda = [ODataExpression lambda:function of:collection variable:variable body:body error:error];
  NSArray *before = i ? [self toOnesBefore:[[parts subarrayWithRange:NSMakeRange(0, i + 1)] componentsJoinedByString:@"."] error:error] : @[];
  return [self known:lambda operands:before negated:self.negated error:error];
}

// What a collection at keyPath is reached through that may be null: the
// path to the last to-one before it (Manager, of Manager/Reports), which is
// null where any to-one on the way is.
- (NSArray<ODataExpression *> *)toOnesBefore:(NSString *)keyPath error:(NSError **)error
{
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  NSEntityDescription *walk = self.elementType ? nil : self.entity;
  NSUInteger last = 0;
  for (NSUInteger i = 0; i + 1 < parts.count && walk; i++) {
    NSRelationshipDescription *relationship = walk.relationshipsByName[parts[i]];
    if (!relationship || relationship.isToMany) break;
    last = i + 1;
    walk = relationship.destinationEntity;
  }
  if (!last) return @[];
  ODataExpression *path = [self mapKeyPath:[[parts subarrayWithRange:NSMakeRange(0, last)] componentsJoinedByString:@"."] error:error];
  return path ? @[ path ] : @[];
}

#pragma mark - Managed objects as constants

static BOOL OISIsObject(id value)
{
  return [value isKindOfClass:[NSManagedObject class]] || [value isKindOfClass:[NSManagedObjectID class]];
}

// The constant side's objects: one, or a collection of them for IN.
static NSArray *OISObjectsInExpression(NSExpression *expression)
{
  if (expression.expressionType == NSAggregateExpressionType) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSExpression *e in expression.collection) {
      if (e.expressionType != NSConstantValueExpressionType || !OISIsObject(e.constantValue)) return nil;
      [out addObject:e.constantValue];
    }
    return out;
  }
  if (expression.expressionType != NSConstantValueExpressionType) return nil;
  id value = expression.constantValue;
  if (OISIsObject(value)) return @[ value ];
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
    NSArray *all = [value isKindOfClass:[NSSet class]] ? [value allObjects] : value;
    if (!all.count) return nil;
    for (id v in all) {
      if (!OISIsObject(v)) return nil;
    }
    return all;
  }
  return nil;
}

- (BOOL)comparesObjects:(NSExpression *)expression
{
  return OISObjectsInExpression(expression) != nil;
}

// An object's key, by wire name: from the store for an object ID, or from
// a managed object's own key attributes.
- (NSDictionary *)keysForObject:(id)object entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSManagedObjectID *oid = [object isKindOfClass:[NSManagedObject class]] ? [object objectID] : object;
  if (oid.isTemporaryID) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, @"An unsaved object has no key to compare");
    return nil;
  }
  NSDictionary *keys = self.keysForObjectID ? self.keysForObjectID(oid) : nil;
  if (!keys && [object isKindOfClass:[NSManagedObject class]]) {
    NSMutableDictionary *read = [NSMutableDictionary dictionary];
    for (NSAttributeDescription *attr in [self.mapper keyAttributesForEntity:entity]) {
      id value = [object valueForKey:attr.name];
      if (!value) break;
      read[[self.mapper propertyForAttribute:attr]] = value;
    }
    if (read.count) keys = read;
  }
  if (!keys.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingKey, [NSString stringWithFormat:@"No key for %@", oid]);
    return nil;
  }
  return keys;
}

// A key written as its attribute's type: a Guid key, kept as a string,
// is still an unquoted Guid literal.
- (ODataExpression *)keyLiteral:(id)value property:(NSString *)wire entity:(NSEntityDescription *)entity error:(NSError **)error
{
  for (NSAttributeDescription *attr in [self.mapper keyAttributesForEntity:entity]) {
    if ([[self.mapper propertyForAttribute:attr] isEqualToString:wire]) {
      return [self literalFromText:[self.mapper.values literalForValue:value attribute:attr] error:error];
    }
  }
  return [self literalFromText:[self.mapper.values literalForValue:value attribute:nil] error:error];
}

// category == %@  ->  Category/CategoryID eq 2
// self IN %@      ->  ProductID in (1, 2)
// Objects compare by key, over the path to them; a compound key compares
// each part.
- (ODataExpression *)translateObjectComparison:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  NSExpression *left = cmp.leftExpression;
  NSEntityDescription *target = nil;
  ODataExpression *path = nil;
  if (left.expressionType == NSEvaluatedObjectExpressionType) {
    target = self.entity;
    if (self.lambdaVariable) {
      path = [ODataExpression variable:self.lambdaVariable error:error];
      if (!path) return nil;
    }
  } else if (left.expressionType == NSKeyPathExpressionType) {
    NSEntityDescription *current = self.entity;
    for (NSString *part in [left.keyPath componentsSeparatedByString:@"."]) {
      NSRelationshipDescription *rel = current.relationshipsByName[part];
      if (!rel || rel.isToMany) {
        current = nil;
        break;
      }
      current = rel.destinationEntity;
    }
    target = current;
    path = [self mapKeyPath:left.keyPath error:error];
    if (!path) return nil;
  }
  if (!target) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"Objects compare only with self or a to-one relationship: %@", cmp]);
    return nil;
  }

  NSMutableArray *clauses = [NSMutableArray array];
  NSMutableArray *singles = [NSMutableArray array];
  BOOL singleKey = YES;
  for (id object in OISObjectsInExpression(cmp.rightExpression)) {
    NSDictionary *keys = [self keysForObject:object entity:target error:error];
    if (!keys) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *wire in [keys.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataExpression *property = [ODataExpression member:wire of:path error:error];
      if (!property) return nil;
      ODataExpression *literal = [self keyLiteral:keys[wire] property:wire entity:target error:error];
      if (!literal) return nil;
      ODataExpression *equal = [ODataExpression binary:@"eq" left:property right:literal error:error];
      if (!equal) return nil;
      [parts addObject:equal];
      if (keys.count == 1) [singles addObject:@[ property, literal ]];
    }
    singleKey = singleKey && keys.count == 1;
    [clauses addObject:OISJoined(parts, @"and", YES, error)];
  }

  switch (cmp.predicateOperatorType) {
    case NSEqualToPredicateOperatorType:
      if (clauses.count == 1) return clauses[0];
      break;
    case NSNotEqualToPredicateOperatorType:
      if (clauses.count == 1) return [ODataExpression unary:@"not" operand:clauses[0] error:error];
      break;
    case NSInPredicateOperatorType: {
      if (singleKey) {
        NSMutableArray *literals = [NSMutableArray array];
        for (NSArray *pair in singles) [literals addObject:pair[1]];
        return [self membership:singles.firstObject[0] literals:literals error:error];
      }
      return OISJoined(clauses, @"or", NO, error);
    }
    default:
      break;
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
  return nil;
}

#pragma mark - Literals

- (ODataExpression *)literal:(id)value error:(NSError **)error
{
  // gnustep-base parses {1, 3} into a constant array of constant
  // expressions.
  while ([value isKindOfClass:[NSExpression class]] && [(NSExpression *)value expressionType] == NSConstantValueExpressionType) {
    value = [(NSExpression *)value constantValue];
  }
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id v in value) {
      ODataExpression *part = [self literal:v error:error];
      if (!part) return nil;
      [parts addObject:part];
    }
    return [ODataExpression list:parts];
  }
  NSString *text = self.comparedType ? [self.mapper.values literalForValue:value typeName:self.comparedType]
                                     : [self.mapper.values literalForValue:value attribute:self.comparedAttribute];
  return [self literalFromText:text error:error];
}

// The type a key path ends at when that is no attribute: a complex value's
// member, or inside a lambda over values, the element or its member.
- (NSString *)typeAtExpression:(NSExpression *)expression
{
  NSString *type = nil;
  if ([expression isKindOfClass:[ODataFunctionExpression class]]) {
    [self translateODataFunction:(ODataFunctionExpression *)expression type:&type attribute:NULL error:NULL];
    return type;
  }
  if (expression.expressionType == NSEvaluatedObjectExpressionType) return self.elementType;
  if (expression.expressionType != NSKeyPathExpressionType) return nil;
  if (self.elementType) {
    [self.mapper memberPath:[expression.keyPath componentsSeparatedByString:@"."] ofType:self.elementType memberType:&type];
  } else {
    [self.mapper propertyPathForKeyPath:expression.keyPath entity:self.entity memberType:&type];
  }
  return type;
}

// The attribute at the end of a key path, through to-one relationships.
- (NSAttributeDescription *)attributeAtExpression:(NSExpression *)expression
{
  if ([expression isKindOfClass:[ODataFunctionExpression class]]) {
    NSAttributeDescription *attribute = nil;
    [self translateODataFunction:(ODataFunctionExpression *)expression type:NULL attribute:&attribute error:NULL];
    return attribute;
  }
  if ([expression isKindOfClass:[ODataTheseExpression class]]) {
    // What a sum, min or max of an attribute compares as; an average or a
    // count is a number of its own.
    ODataTheseExpression *these = (ODataTheseExpression *)expression;
    BOOL same = [@[ @"sum", @"min", @"max" ] containsObject:these.method ?: @""];
    return same ? [self attributeAtKeyPath:these.aggregatedKeyPath entity:self.entity] : nil;
  }
  if (expression.expressionType != NSKeyPathExpressionType || self.elementType) return nil;
  return [self attributeAtKeyPath:expression.keyPath entity:self.entity];
}

- (NSAttributeDescription *)attributeAtKeyPath:(NSString *)keyPath entity:(NSEntityDescription *)entity
{
  NSEntityDescription *current = entity;
  NSAttributeDescription *found = nil;
  for (NSString *part in [keyPath componentsSeparatedByString:@"."]) {
    if (found || !current) return nil;
    found = current.attributesByName[part];
    for (NSEntityDescription *sub in current.subentities) {
      if (!found) found = sub.attributesByName[part];
    }
    if (!found) {
      NSRelationshipDescription *rel = current.relationshipsByName[part];
      current = rel.destinationEntity;
    }
  }
  return found;
}

@end
