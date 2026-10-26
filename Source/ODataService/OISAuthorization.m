// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OISAuthorization.h"

NSString * const OISRelationKeyPrefix = @"OData.relation.";
NSString * const OISTupleObjectKey = @"OData.tuple.object";
NSString * const OISTupleRelationKey = @"OData.tuple.relation";
NSString * const OISTupleRelationNameKey = @"OData.tuple.relationName";
NSString * const OISTupleUserKey = @"OData.tuple.user";

// How deep relations are followed (from terms through relationships): Zanzibar
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

#pragma mark Formats

// A relation is compiled to one predicate format, which the platform's own
// parser makes the predicate of, once: the shapes it makes are the ones its
// stores translate (a subquery's, especially), and no predicate is written
// back out and read again (gnustep-base's -predicateFormat does not quote
// strings). The caller's identities go in as arguments (%@): a constant
// array, as `IN %@` makes.

static NSString *OISQuoted(NSString *text)
{
  NSString *escaped = [[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  return [NSString stringWithFormat:@"\"%@\"", [escaped stringByReplacingOccurrencesOfString:@"%" withString:@"%%"]];
}

static NSSet<NSString *> *OISFormatKeywords(void)
{
  static NSSet *keywords;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    keywords = [NSSet setWithArray:@[ @"AND", @"OR", @"NOT", @"ANY", @"ALL", @"SOME", @"NONE", @"IN", @"CONTAINS", @"BEGINSWITH", @"ENDSWITH",
                                      @"LIKE", @"MATCHES", @"BETWEEN", @"TRUEPREDICATE", @"FALSEPREDICATE", @"NIL", @"NULL", @"YES", @"NO", @"TRUE",
                                      @"FALSE", @"SUBQUERY", @"FUNCTION", @"CAST", @"FIRST", @"LAST", @"SIZE" ]];
  });
  return keywords;
}

// A where term's text, its key paths under prefix (a key path, or a
// subquery's variable: $v1.catalog), $user one argument more (the
// identities). Quoted strings, variables, keywords, functions and options
// ([c]) stay as they are.
static NSString *OISConditionFormat(NSString *text, NSString *prefix, NSArray *identities, NSMutableArray *arguments)
{
  NSMutableString *out = [NSMutableString string];
  NSCharacterSet *start = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"];
  NSCharacterSet *part = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@"];
  NSUInteger i = 0, n = text.length;
  while (i < n) {
    unichar c = [text characterAtIndex:i];
    if (c == '\'' || c == '"') {
      NSUInteger j = i + 1;
      while (j < n && [text characterAtIndex:j] != c) j += [text characterAtIndex:j] == '\\' ? 2 : 1;
      NSString *quoted = [text substringWithRange:NSMakeRange(i, MIN(j + 1, n) - i)];
      [out appendString:[quoted stringByReplacingOccurrencesOfString:@"%" withString:@"%%"]];
      i = MIN(j + 1, n);
    } else if (c == '[') {
      NSUInteger j = i;
      while (j < n && [text characterAtIndex:j] != ']') j++;
      [out appendString:[text substringWithRange:NSMakeRange(i, MIN(j + 1, n) - i)]];
      i = MIN(j + 1, n);
    } else if (c == '$') {
      NSUInteger j = i + 1;
      while (j < n && [part characterIsMember:[text characterAtIndex:j]]) j++;
      NSString *variable = [text substringWithRange:NSMakeRange(i + 1, j - i - 1)];
      if ([variable isEqualToString:@"user"] || [variable hasPrefix:@"user."]) {
        [out appendString:@"%@"];
        [out appendString:[variable substringFromIndex:4]];
        [arguments addObject:identities];
      } else {
        [out appendFormat:@"$%@", variable];
      }
      i = j;
    } else if ([start characterIsMember:c]) {
      NSUInteger j = i;
      while (j < n && [part characterIsMember:[text characterAtIndex:j]]) j++;
      NSString *token = [text substringWithRange:NSMakeRange(i, j - i)];
      NSUInteger k = j;
      while (k < n && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[text characterAtIndex:k]]) k++;
      BOOL function = k < n && [text characterAtIndex:k] == '(';
      NSString *head = [[token componentsSeparatedByString:@"."].firstObject uppercaseString];
      if (function || [OISFormatKeywords() containsObject:head] || !prefix.length) {
        [out appendString:token];
      } else if ([head isEqualToString:@"SELF"]) {
        [out appendString:[prefix stringByAppendingString:[token substringFromIndex:4]]];
      } else {
        [out appendFormat:@"%@.%@", prefix, token];
      }
      i = j;
    } else if (c == '%') {
      [out appendString:@"%%"];
      i++;
    } else {
      [out appendFormat:@"%C", c];
      i++;
    }
  }
  return out;
}

#pragma mark The model

// A relation's definition, read: its terms, each one of these.
typedef NS_ENUM(NSInteger, OISRelationTermKind) {
  OISTermDirect,     // [user]: the tuples naming the object and the relation
  OISTermComputed,   // manager: another relation of the same object
  OISTermFrom,       // keeper from warehouse: a relation of what a relationship reaches (a to-many: any member)
  OISTermWhere,      // where catalogOwner.email IN $user: the row's own values
};

@interface OISRelationTerm : NSObject
@property (nonatomic) OISRelationTermKind kind;
@property (nonatomic, copy) NSString *relation;       // computed, from
@property (nonatomic, copy) NSString *through;        // from: the relationship
@property (nonatomic, copy) NSString *text;          // where: its predicate, as written
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
      term.text = [part substringFromIndex:6];
      @try {
        // Read once, with $user as the parser reads a variable, to say now
        // what does not parse.
        (void)[NSPredicate predicateWithFormat:term.text];
      } @catch (NSException *exception) {
        [self problem:[NSString stringWithFormat:@"%@.%@: %@ does not parse: %@", entity.name, relation, part, exception.reason]];
        continue;
      }
    } else if (words.count == 3 && [words[1] isEqualToString:@"from"] && OISIsKeyPath(words[0]) && OISIsKeyPath(words[2])) {
      NSRelationshipDescription *through = entity.relationshipsByName[words[2]];
      if (!through) {
        [self problem:[NSString stringWithFormat:@"%@.%@: %@ is no relationship of %@", entity.name, relation, words[2], entity.name]];
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
      [self problem:[NSString stringWithFormat:@"%@.%@: %@ is not a term ([user], a relation, <relation> from <relationship>, where <predicate>)",
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
  NSMutableArray *arguments = [NSMutableArray array];
  NSString *format = [self formatForRelation:relation entity:entity prefix:@"" identities:identities arguments:arguments depth:0
                                        seen:[NSMutableSet set]];
  @try {
    return [NSPredicate predicateWithFormat:format argumentArray:arguments];
  } @catch (NSException *exception) {
    [self problem:[NSString stringWithFormat:@"%@.%@ does not make a predicate: %@", entity.name, relation, exception.reason]];
    return [NSPredicate predicateWithValue:NO];
  }
}

- (NSString *)formatForRelation:(NSString *)relation
                         entity:(NSEntityDescription *)entity
                         prefix:(NSString *)prefix
                     identities:(NSArray *)identities
                      arguments:(NSMutableArray *)arguments
                          depth:(NSUInteger)depth
                           seen:(NSMutableSet *)seen
{
  NSString *visit = [NSString stringWithFormat:@"%@ %@ %@", entity.name, relation, prefix];
  if (depth > OISRelationDepth || [seen containsObject:visit]) return @"FALSEPREDICATE";
  [seen addObject:visit];
  NSMutableArray *alternatives = [NSMutableArray array];
  NSString *dot = prefix.length ? [prefix stringByAppendingString:@"."] : @"";
  for (OISRelationTerm *term in [self termsOf:relation entity:entity] ?: @[]) {
    switch (term.kind) {
      case OISTermDirect:
        for (OISRelationTupleSource *source in _sources) {
          NSRelationshipDescription *inverse = source.object.inverseRelationship;
          if (![entity isKindOfEntity:inverse.entity]) continue;
          if (source.relationName.length && ![source.relationName isEqualToString:relation]) continue;
          NSString *path = [dot stringByAppendingString:inverse.name];
          // Each depth's own variable: a subquery within another's does not
          // hide the outer one's.
          NSString *t = inverse.isToMany ? [NSString stringWithFormat:@"$t%lu", (unsigned long)depth] : path;
          NSString *named = source.relationName.length ? @"" : [NSString stringWithFormat:@" AND %@.%@ == %@", t, source.relationAttribute,
                                                                                         OISQuoted(relation)];
          NSString *tuple = [NSString stringWithFormat:@"%@.%@ IN %%@%@", t, source.user, named];
          [arguments addObject:identities];
          [alternatives addObject:inverse.isToMany ? [NSString stringWithFormat:@"SUBQUERY(%@, %@, %@).@count > 0", path, t, tuple] : tuple];
        }
        break;
      case OISTermComputed:
        [alternatives addObject:[self formatForRelation:term.relation entity:entity prefix:prefix identities:identities arguments:arguments
                                                  depth:depth seen:seen]];
        break;
      case OISTermFrom: {
        NSRelationshipDescription *through = entity.relationshipsByName[term.through];
        NSEntityDescription *destination = through.destinationEntity;
        NSString *path = [dot stringByAppendingString:term.through];
        if (!through.isToMany) {
          [alternatives addObject:[self formatForRelation:term.relation entity:destination prefix:path identities:identities arguments:arguments
                                                    depth:depth + 1 seen:seen]];
          break;
        }
        // Through a to-many: any of its members (Zanzibar's tuple to
        // userset reads every tuple of the set), a subquery whose variable
        // the members' relation is under.
        NSString *v = [NSString stringWithFormat:@"$v%lu", (unsigned long)depth + 1];
        NSString *member = [self formatForRelation:term.relation entity:destination prefix:v identities:identities arguments:arguments
                                             depth:depth + 1 seen:seen];
        [alternatives addObject:[NSString stringWithFormat:@"SUBQUERY(%@, %@, %@).@count > 0", path, v, member]];
        break;
      }
      case OISTermWhere:
        [alternatives addObject:OISConditionFormat(term.text, prefix, identities, arguments)];
        break;
    }
  }
  [seen removeObject:visit];
  if (!alternatives.count) return @"FALSEPREDICATE";
  NSMutableArray *grouped = [NSMutableArray array];
  for (NSString *alternative in alternatives) [grouped addObject:[NSString stringWithFormat:@"(%@)", alternative]];
  return [grouped componentsJoinedByString:@" OR "];
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
