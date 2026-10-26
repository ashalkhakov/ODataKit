// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OISAuthorization.h"

NSString * const OISRelationKeyPrefix = @"OData.relation.";
NSString * const OISTupleObjectKey = @"OData.tuple.object";
NSString * const OISTupleRelationKey = @"OData.tuple.relation";
NSString * const OISTupleRelationNameKey = @"OData.tuple.relationName";
NSString * const OISTupleUserKey = @"OData.tuple.user";

// How deep relations are followed (from terms through to-ones): Zanzibar
// bounds its rewrites too; a deeper chain is no grant.
static const NSUInteger OISRelationDepth = 8;

NSArray<NSString *> *OISIdentitiesOfPrincipal(HSPrincipal *principal)
{
  if (!principal) return @[];
  NSMutableOrderedSet *identities = [NSMutableOrderedSet orderedSet];
  if (principal.subject.length) [identities addObject:principal.subject];
  for (NSString *claim in @[ @"email", @"preferred_username" ]) {
    id value = principal.claims[claim];
    if ([value isKindOfClass:[NSString class]] && [value length]) [identities addObject:value];
  }
  id groups = principal.claims[@"groups"];
  for (id group in [groups isKindOfClass:[NSArray class]] ? groups : ([groups isKindOfClass:[NSString class]] ? @[ groups ] : @[])) {
    if ([group isKindOfClass:[NSString class]] && [group length]) [identities addObject:group];
  }
  return identities.array;
}

// A model's name for a key path: letters, digits, _ and dots.
static BOOL OISIsKeyPath(NSString *text)
{
  if (!text.length) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                             @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_."];
  return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

#pragma mark Prefixing

// A predicate of the row's, as one of a row that reaches it through
// prefix (a key path): key paths prefixed, variables (a subquery's) not.
static NSPredicate *OISPrefixedPredicate(NSPredicate *predicate, NSString *prefix);

static NSExpression *OISPrefixedExpression(NSExpression *expression, NSString *prefix)
{
  if (!prefix.length) return expression;
  switch (expression.expressionType) {
    case NSKeyPathExpressionType: {
      NSString *path = expression.keyPath;
      return [NSExpression expressionForKeyPath:[path isEqualToString:@"SELF"] ? prefix : [NSString stringWithFormat:@"%@.%@", prefix, path]];
    }
    case NSEvaluatedObjectExpressionType:
      return [NSExpression expressionForKeyPath:prefix];
    case NSFunctionExpressionType: {
      NSMutableArray *arguments = [NSMutableArray array];
      for (NSExpression *argument in expression.arguments ?: @[]) [arguments addObject:OISPrefixedExpression(argument, prefix)];
      NSExpression *operand = expression.operand;
      // A key path through the evaluated object (valueForKeyPath:):
      // through the prefix instead.
      if (operand.expressionType == NSEvaluatedObjectExpressionType && [expression.function isEqualToString:@"valueForKeyPath:"]) {
        NSExpression *path = expression.arguments.firstObject;
        if (path.expressionType == NSConstantValueExpressionType && [path.constantValue isKindOfClass:[NSString class]]) {
          return [NSExpression expressionForKeyPath:[NSString stringWithFormat:@"%@.%@", prefix, path.constantValue]];
        }
      }
      if (operand && operand.expressionType != NSConstantValueExpressionType) {
        return [NSExpression expressionForFunction:OISPrefixedExpression(operand, prefix) selectorName:expression.function
                                         arguments:expression.arguments ?: @[]];
      }
      return [NSExpression expressionForFunction:expression.function arguments:arguments];
    }
    case NSSubqueryExpressionType: {
      NSExpression *collection = [expression.collection isKindOfClass:[NSExpression class]] ? expression.collection : nil;
      if (!collection) return expression;
      return [NSExpression expressionForSubquery:OISPrefixedExpression(collection, prefix)
                           usingIteratorVariable:expression.variable
                                       predicate:expression.predicate];
    }
    case NSAggregateExpressionType: {
      NSMutableArray *items = [NSMutableArray array];
      for (NSExpression *item in [expression.collection isKindOfClass:[NSArray class]] ? expression.collection : @[]) {
        [items addObject:[item isKindOfClass:[NSExpression class]] ? OISPrefixedExpression(item, prefix) : item];
      }
      return [NSExpression expressionForAggregate:items];
    }
    default:
      return expression;
  }
}

static NSPredicate *OISPrefixedPredicate(NSPredicate *predicate, NSString *prefix)
{
  if (!prefix.length) return predicate;
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    NSCompoundPredicate *compound = (NSCompoundPredicate *)predicate;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSPredicate *part in compound.subpredicates) [parts addObject:OISPrefixedPredicate(part, prefix)];
    return [[NSCompoundPredicate alloc] initWithType:compound.compoundPredicateType subpredicates:parts];
  }
  if ([predicate isKindOfClass:[NSComparisonPredicate class]]) {
    NSComparisonPredicate *comparison = (NSComparisonPredicate *)predicate;
    NSExpression *left = OISPrefixedExpression(comparison.leftExpression, prefix);
    NSExpression *right = OISPrefixedExpression(comparison.rightExpression, prefix);
    if (comparison.predicateOperatorType == NSCustomSelectorPredicateOperatorType) {
      return [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:right customSelector:comparison.customSelector];
    }
    return [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:right modifier:comparison.comparisonPredicateModifier
                                                         type:comparison.predicateOperatorType options:comparison.options];
  }
  return predicate;  // TRUEPREDICATE, FALSEPREDICATE
}

#pragma mark The model

// A relation's definition, read: its terms, each one of these.
typedef NS_ENUM(NSInteger, OISRelationTermKind) {
  OISTermDirect,     // [user]: the tuples naming the object and the relation
  OISTermComputed,   // manager: another relation of the same object
  OISTermFrom,       // keeper from warehouse: a relation of the object a to-one reaches
  OISTermWhere,      // where catalogOwner.email IN $user: the row's own values
};

@interface OISRelationTerm : NSObject
@property (nonatomic) OISRelationTermKind kind;
@property (nonatomic, copy) NSString *relation;       // computed, from
@property (nonatomic, copy) NSString *through;        // from: the to-one
@property (nonatomic, strong) NSPredicate *condition; // where
@end

@implementation OISRelationTerm
@end

// A tuple source: an entity whose rows are tuples.
@interface OISRelationTupleSource : NSObject
@property (nonatomic, strong) NSEntityDescription *entity;
@property (nonatomic, strong) NSRelationshipDescription *object;   // the tuple's to-one to its object
@property (nonatomic, copy) NSString *relationAttribute;           // or
@property (nonatomic, copy) NSString *relationName;
@property (nonatomic, copy) NSString *user;                        // key path
@end

@implementation OISRelationTupleSource
@end

@implementation OISAuthorization {
  NSManagedObjectModel *_model;
  NSMutableArray<NSString *> *_problems;
  NSMutableDictionary<NSString *, NSArray<OISRelationTerm *> *> *_definitions;   // "Entity relation" -> terms (parsed on first use)
  NSArray<OISRelationTupleSource *> *_sources;
}

- (instancetype)initWithModel:(NSManagedObjectModel *)model
{
  if (!(self = [super init])) return nil;
  _model = model;
  _problems = [NSMutableArray array];
  _definitions = [NSMutableDictionary dictionary];
  NSMutableArray *sources = [NSMutableArray array];
  for (NSEntityDescription *entity in model.entities) {
    NSDictionary *info = entity.userInfo;
    NSString *objectName = info[OISTupleObjectKey];
    if (!objectName && !info[OISTupleUserKey]) continue;
    OISRelationTupleSource *source = [[OISRelationTupleSource alloc] init];
    source.entity = entity;
    source.object = entity.relationshipsByName[objectName ?: @""];
    source.user = info[OISTupleUserKey];
    source.relationAttribute = info[OISTupleRelationKey];
    source.relationName = info[OISTupleRelationNameKey];
    if (!source.object || source.object.isToMany) {
      [_problems addObject:[NSString stringWithFormat:@"%@: %@ names no to-one of it (the tuple's object)", entity.name, OISTupleObjectKey]];
      continue;
    }
    if (!source.object.inverseRelationship) {
      [_problems addObject:[NSString stringWithFormat:@"%@.%@ needs an inverse, for its object's rows to find their tuples", entity.name, objectName]];
      continue;
    }
    if (!OISIsKeyPath(source.user)) {
      [_problems addObject:[NSString stringWithFormat:@"%@: %@ names no key path (the tuple's user)", entity.name, OISTupleUserKey]];
      continue;
    }
    if (!source.relationName.length && !entity.attributesByName[source.relationAttribute ?: @""]) {
      [_problems addObject:[NSString stringWithFormat:@"%@: give %@ (an attribute) or %@ (the relation)", entity.name, OISTupleRelationKey,
                                                      OISTupleRelationNameKey]];
      continue;
    }
    [sources addObject:source];
  }
  _sources = sources;
  // Every definition read now, so that a mistake is a problem from the start.
  for (NSEntityDescription *entity in model.entities) {
    for (NSString *key in entity.userInfo) {
      if ([key hasPrefix:OISRelationKeyPrefix]) [self termsOf:[key substringFromIndex:OISRelationKeyPrefix.length] entity:entity];
    }
  }
  return self;
}

- (NSArray<NSString *> *)problems
{
  @synchronized (self) {
    return [_problems copy];
  }
}

- (BOOL)hasTuples
{
  return _sources.count > 0;
}

// The entity (or super-entity) whose userInfo defines the relation.
- (NSString *)definitionOf:(NSString *)relation entity:(NSEntityDescription *)entity
{
  for (NSEntityDescription *at = entity; at; at = at.superentity) {
    id text = at.userInfo[[OISRelationKeyPrefix stringByAppendingString:relation]];
    if ([text isKindOfClass:[NSString class]]) return text;
  }
  return nil;
}

- (BOOL)entity:(NSEntityDescription *)entity defines:(NSString *)relation
{
  return [self definitionOf:relation entity:entity] != nil;
}

// A definition's terms: split at each top-level "or".
static NSArray<NSString *> *OISTermTexts(NSString *text)
{
  NSMutableArray *terms = [NSMutableArray array];
  NSInteger depth = 0;
  unichar quote = 0;
  NSUInteger start = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (quote) {
      if (c == quote) quote = 0;
      continue;
    }
    if (c == '\'' || c == '"') quote = c;
    else if (c == '(' || c == '[') depth++;
    else if (c == ')' || c == ']') depth--;
    else if (depth == 0 && c == 'o' && i + 2 < text.length && [text characterAtIndex:i + 1] == 'r' &&
             i > 0 && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[text characterAtIndex:i - 1]] &&
             [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[text characterAtIndex:i + 2]]) {
      [terms addObject:[text substringWithRange:NSMakeRange(start, i - start)]];
      start = i + 2;
      i++;
    }
  }
  [terms addObject:[text substringFromIndex:start]];
  NSMutableArray *trimmed = [NSMutableArray array];
  for (NSString *term in terms) [trimmed addObject:[term stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
  return trimmed;
}

- (void)problem:(NSString *)problem
{
  @synchronized (self) {
    if (![_problems containsObject:problem]) [_problems addObject:problem];
  }
}

- (NSArray<OISRelationTerm *> *)termsOf:(NSString *)relation entity:(NSEntityDescription *)entity
{
  NSString *text = [self definitionOf:relation entity:entity];
  if (!text) return nil;
  NSString *key = [NSString stringWithFormat:@"%@ %@", entity.name, relation];
  @synchronized (self) {
    NSArray *known = _definitions[key];
    if (known) return known;
  }
  NSMutableArray *terms = [NSMutableArray array];
  for (NSString *part in OISTermTexts(text)) {
    OISRelationTerm *term = [[OISRelationTerm alloc] init];
    NSArray *words = [part componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if ([part isEqualToString:@"[user]"]) {
      term.kind = OISTermDirect;
    } else if ([part hasPrefix:@"where "]) {
      term.kind = OISTermWhere;
      @try {
        term.condition = [NSPredicate predicateWithFormat:[part substringFromIndex:6]];
      } @catch (NSException *exception) {
        [self problem:[NSString stringWithFormat:@"%@.%@: %@ does not parse: %@", entity.name, relation, part, exception.reason]];
        continue;
      }
    } else if (words.count == 3 && [words[1] isEqualToString:@"from"] && OISIsKeyPath(words[0]) && OISIsKeyPath(words[2])) {
      NSRelationshipDescription *through = entity.relationshipsByName[words[2]];
      if (!through || through.isToMany) {
        [self problem:[NSString stringWithFormat:@"%@.%@: %@ is no to-one of %@", entity.name, relation, words[2], entity.name]];
        continue;
      }
      if (![self entity:through.destinationEntity defines:words[0]]) {
        [self problem:[NSString stringWithFormat:@"%@.%@: %@ does not define %@", entity.name, relation, through.destinationEntity.name, words[0]]];
        continue;
      }
      term.kind = OISTermFrom;
      term.relation = words[0];
      term.through = words[2];
    } else if (words.count == 1 && OISIsKeyPath(words[0])) {
      if (![self entity:entity defines:words[0]]) {
        [self problem:[NSString stringWithFormat:@"%@.%@ names %@, which %@ does not define", entity.name, relation, words[0], entity.name]];
        continue;
      }
      term.kind = OISTermComputed;
      term.relation = words[0];
    } else {
      [self problem:[NSString stringWithFormat:@"%@.%@: %@ is not a term ([user], a relation, <relation> from <to-one>, where <predicate>)",
                                               entity.name, relation, part]];
      continue;
    }
    [terms addObject:term];
  }
  @synchronized (self) {
    _definitions[key] = terms;
  }
  return terms;
}

#pragma mark Predicates

- (NSPredicate *)predicateForRelation:(NSString *)relation entity:(NSEntityDescription *)entity identities:(NSArray<NSString *> *)identities
{
  if (![self entity:entity defines:relation]) return nil;
  return [self predicateForRelation:relation entity:entity prefix:@"" identities:identities depth:0 seen:[NSMutableSet set]];
}

- (NSPredicate *)predicateForRelation:(NSString *)relation
                               entity:(NSEntityDescription *)entity
                               prefix:(NSString *)prefix
                           identities:(NSArray *)identities
                                depth:(NSUInteger)depth
                                 seen:(NSMutableSet *)seen
{
  NSString *visit = [NSString stringWithFormat:@"%@ %@ %@", entity.name, relation, prefix];
  if (depth > OISRelationDepth || [seen containsObject:visit]) return [NSPredicate predicateWithValue:NO];
  [seen addObject:visit];
  NSMutableArray *alternatives = [NSMutableArray array];
  NSString *dot = prefix.length ? [prefix stringByAppendingString:@"."] : @"";
  for (OISRelationTerm *term in [self termsOf:relation entity:entity] ?: @[]) {
    switch (term.kind) {
      case OISTermDirect:
        for (OISRelationTupleSource *source in _sources) {
          NSRelationshipDescription *inverse = source.object.inverseRelationship;
          if (![entity isKindOfEntity:inverse.entity]) continue;
          NSString *path = [dot stringByAppendingString:inverse.name];
          NSString *named = source.relationName.length ? @"" : [NSString stringWithFormat:@" AND $t.%@ == %%@", source.relationAttribute];
          if (source.relationName.length && ![source.relationName isEqualToString:relation]) continue;
          NSPredicate *tuple = nil;
          if (inverse.isToMany) {
            NSString *format = [NSString stringWithFormat:@"SUBQUERY(%@, $t, $t.%@ IN %%@%@).@count > 0", path, source.user, named];
            tuple = named.length ? [NSPredicate predicateWithFormat:format, identities, relation] : [NSPredicate predicateWithFormat:format, identities];
          } else {
            NSString *format = [NSString stringWithFormat:@"%@.%@ IN %%@%@", path, source.user,
                                                          named.length ? [NSString stringWithFormat:@" AND %@.%@ == %%@", path, source.relationAttribute] : @""];
            tuple = named.length ? [NSPredicate predicateWithFormat:format, identities, relation] : [NSPredicate predicateWithFormat:format, identities];
          }
          [alternatives addObject:tuple];
        }
        break;
      case OISTermComputed:
        if (![self entity:entity defines:term.relation]) {
          [self problem:[NSString stringWithFormat:@"%@.%@ names %@, which %@ does not define", entity.name, relation, term.relation, entity.name]];
          break;
        }
        [alternatives addObject:[self predicateForRelation:term.relation entity:entity prefix:prefix identities:identities depth:depth seen:seen]];
        break;
      case OISTermFrom: {
        NSRelationshipDescription *through = entity.relationshipsByName[term.through];
        NSEntityDescription *destination = through.destinationEntity;
        if (![self entity:destination defines:term.relation]) {
          [self problem:[NSString stringWithFormat:@"%@.%@: %@ does not define %@", entity.name, relation, destination.name, term.relation]];
          break;
        }
        [alternatives addObject:[self predicateForRelation:term.relation entity:destination prefix:[dot stringByAppendingString:term.through]
                                                identities:identities depth:depth + 1 seen:seen]];
        break;
      }
      case OISTermWhere: {
        NSPredicate *condition = [term.condition predicateWithSubstitutionVariables:@{ @"user": identities }];
        [alternatives addObject:OISPrefixedPredicate(condition, prefix)];
        break;
      }
    }
  }
  [seen removeObject:visit];
  if (!alternatives.count) return [NSPredicate predicateWithValue:NO];
  return alternatives.count == 1 ? alternatives.firstObject : [NSCompoundPredicate orPredicateWithSubpredicates:alternatives];
}

- (NSSet<NSString *> *)relationshipsOfRelation:(NSString *)relation entity:(NSEntityDescription *)entity
{
  NSMutableSet *through = [NSMutableSet set];
  NSMutableArray *pending = [NSMutableArray arrayWithObject:relation];
  NSMutableSet *done = [NSMutableSet set];
  while (pending.count) {
    NSString *name = pending.lastObject;
    [pending removeLastObject];
    if ([done containsObject:name]) continue;
    [done addObject:name];
    for (OISRelationTerm *term in [self termsOf:name entity:entity] ?: @[]) {
      if (term.kind == OISTermFrom) [through addObject:term.through];
      if (term.kind == OISTermComputed) [pending addObject:term.relation];
    }
  }
  return through;
}

- (NSString *)versionOfIdentities:(NSArray<NSString *> *)identities context:(NSManagedObjectContext *)context
{
  if (!_sources.count) return nil;
  NSMutableArray *held = [NSMutableArray array];
  for (OISRelationTupleSource *source in _sources) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:source.entity.name];
    fetch.predicate = [NSPredicate predicateWithFormat:[NSString stringWithFormat:@"%@ IN %%@", source.user], identities];
    NSArray *rows = [context executeFetchRequest:fetch error:NULL];
    if (!rows) return nil;
    for (NSManagedObject *row in rows) {
      NSManagedObject *object = [row valueForKey:source.object.name];
      NSString *named = source.relationName.length ? source.relationName : [[row valueForKey:source.relationAttribute] description];
      [held addObject:[NSString stringWithFormat:@"%@#%@@%@", object.objectID.URIRepresentation.absoluteString, named,
                                                 [row valueForKeyPath:source.user]]];
    }
  }
  [held sortUsingSelector:@selector(compare:)];
  uint64_t hash = 14695981039346656037ULL;
  NSData *bytes = [[held componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
  const uint8_t *p = bytes.bytes;
  for (NSUInteger i = 0; i < bytes.length; i++) {
    hash ^= p[i];
    hash *= 1099511628211ULL;
  }
  return [NSString stringWithFormat:@"g%016llx", (unsigned long long)hash];
}

@end

@implementation OISRowToBe {
  NSDictionary *_values;
  NSManagedObject *_object;
}

- (instancetype)initWithValues:(NSDictionary *)values object:(NSManagedObject *)object
{
  if (!(self = [super init])) return nil;
  _values = [values copy] ?: @{};
  _object = object;
  return self;
}

- (id)valueForKey:(NSString *)key
{
  id value = _values[key];
  if (value) return value == [NSNull null] ? nil : value;
  return [_object valueForKey:key];
}

- (id)valueForUndefinedKey:(NSString *)key
{
  return nil;
}

@end
