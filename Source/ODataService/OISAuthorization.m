// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OISAuthorization.h"
#import "ODataPermissions.h"

NSErrorDomain const ODataPermissionsErrorDomain = @"org.gnu.ois.ODataPermissions";

// How deep relations are followed (from terms through relationships):
// Zanzibar bounds its rewrites too; a deeper chain is no grant.
static const NSUInteger OISRelationDepth = 8;

static NSString * const OISServiceTarget = @"service";

// A model's name for a key path: letters, digits, _ and dots.
static BOOL OISIsKeyPath(id text)
{
  if (![text isKindOfClass:[NSString class]] || ![text length]) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                             @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_."];
  return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// YES as a property list says it: a boolean, or (OpenStep has none) YES.
static BOOL OISIsYes(id value)
{
  if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
  return [value isKindOfClass:[NSString class]] && ([value caseInsensitiveCompare:@"YES"] == NSOrderedSame || [value isEqualToString:@"1"]);
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
// ([c]) stay as they are. paths, when given, collects the key paths (for
// the check against the model).
static NSString *OISConditionFormat(NSString *text, NSString *prefix, NSArray *identities, NSMutableArray *arguments, NSMutableArray *paths)
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
        [arguments addObject:identities ?: @[]];
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
      BOOL keyword = function || [OISFormatKeywords() containsObject:head];
      if (!keyword && ![head isEqualToString:@"SELF"]) [paths addObject:token];
      if (keyword || !prefix.length) {
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

typedef NS_ENUM(NSInteger, OISRelationTermKind) {
  OISTermDirect,     // { direct = YES; }: the tuples naming the object and the relation
  OISTermComputed,   // { relation = manager; }: another relation of the same object (or, on = service, the service's)
  OISTermFrom,       // { relation = keeper; from = warehouse; }: a relation of what a relationship reaches (a to-many: any member)
  OISTermWhere,      // { where = "…"; }: the row's own values
  OISTermClaim,      // { claim = roles; value = admin; }: the caller's claim
};

@interface OISRelationTerm : NSObject
@property (nonatomic) OISRelationTermKind kind;
@property (nonatomic, copy) NSString *relation;  // computed, from
@property (nonatomic) BOOL onService;            // computed
@property (nonatomic, copy) NSString *through;   // from: the relationship
@property (nonatomic, copy) NSString *text;      // where: its predicate, as written
@property (nonatomic, copy) NSString *claim;     // claim
@property (nonatomic, copy) NSString *value;
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
  NSArray<NSString *> *_identities;                                               // claim names ("sub": the subject)
  NSDictionary<NSString *, NSArray<OISRelationTerm *> *> *_service;               // relation -> terms
  NSDictionary<NSString *, NSDictionary<NSString *, NSArray *> *> *_entities;     // entity -> relation -> terms
  NSArray<OISRelationTupleSource *> *_sources;
}

- (instancetype)initWithPropertyList:(NSDictionary *)plist model:(NSManagedObjectModel *)model
{
  if (!(self = [super init])) return nil;
  _model = model;
  _problems = [NSMutableArray array];
  if (![plist isKindOfClass:[NSDictionary class]]) plist = @{};
  for (NSString *key in plist) {
    if (![@[ @"Version", @"Identities", @"Service", @"Tuples", @"Entities" ] containsObject:key]) {
      [self problem:[NSString stringWithFormat:@"%@ is no key of a permissions file (Version, Identities, Service, Tuples, Entities)", key]];
    }
  }
  id version = plist[@"Version"];
  if (!version || [version integerValue] != 1) [self problem:@"Version is not 1"];

  id identities = plist[@"Identities"];
  if (identities && (![identities isKindOfClass:[NSArray class]] || ![identities count])) {
    [self problem:@"Identities is not a list of claim names"];
    identities = nil;
  }
  _identities = identities ?: @[ @"sub", @"email", @"preferred_username", @"groups" ];

  [self readTuples:plist[@"Tuples"]];

  NSMutableDictionary *service = [NSMutableDictionary dictionary];
  id serviceDefinitions = plist[@"Service"];
  if (serviceDefinitions && ![serviceDefinitions isKindOfClass:[NSDictionary class]]) [self problem:@"Service is not a dictionary of relations"];
  for (NSString *relation in [serviceDefinitions isKindOfClass:[NSDictionary class]] ? serviceDefinitions : @{}) {
    service[relation] = [self termsOf:serviceDefinitions[relation] relation:relation entity:nil];
  }
  _service = service;

  NSMutableDictionary *entities = [NSMutableDictionary dictionary];
  id entityDefinitions = plist[@"Entities"];
  if (entityDefinitions && ![entityDefinitions isKindOfClass:[NSDictionary class]]) [self problem:@"Entities is not a dictionary of entities"];
  for (NSString *name in [entityDefinitions isKindOfClass:[NSDictionary class]] ? entityDefinitions : @{}) {
    NSEntityDescription *entity = model.entitiesByName[name];
    id relations = entityDefinitions[name];
    if (!entity) {
      [self problem:[NSString stringWithFormat:@"Entities: the model has no entity %@", name]];
      continue;
    }
    if (![relations isKindOfClass:[NSDictionary class]]) {
      [self problem:[NSString stringWithFormat:@"Entities.%@ is not a dictionary of relations", name]];
      continue;
    }
    NSMutableDictionary *read = [NSMutableDictionary dictionary];
    for (NSString *relation in relations) read[relation] = [self termsOf:relations[relation] relation:relation entity:entity];
    entities[name] = read;
  }
  _entities = entities;
  [self checkNamedRelations];
  [self checkCycles];
  return self;
}

- (NSArray<NSString *> *)problems
{
  @synchronized (self) {
    return [_problems copy];
  }
}

- (void)problem:(NSString *)problem
{
  @synchronized (self) {
    if (![_problems containsObject:problem]) [_problems addObject:problem];
  }
}

// A key path's last property from the entity, through its relationships;
// nil (a problem said) when the entity has no such path.
- (NSPropertyDescription *)property:(NSString *)path of:(NSEntityDescription *)entity what:(NSString *)what
{
  NSEntityDescription *at = entity;
  NSPropertyDescription *property = nil;
  for (NSString *name in [path componentsSeparatedByString:@"."]) {
    if ([name hasPrefix:@"@"]) break;  // a collection operator (@count): what comes before is checked
    if (!at) {
      [self problem:[NSString stringWithFormat:@"%@: %@ goes on past an attribute", what, path]];
      return nil;
    }
    property = at.propertiesByName[name];
    if (!property) {
      [self problem:[NSString stringWithFormat:@"%@: %@ has no %@ (in %@)", what, at.name, name, path]];
      return nil;
    }
    at = [property isKindOfClass:[NSRelationshipDescription class]] ? ((NSRelationshipDescription *)property).destinationEntity : nil;
  }
  return property;
}

- (void)readTuples:(id)tuples
{
  NSMutableArray *sources = [NSMutableArray array];
  if (tuples && ![tuples isKindOfClass:[NSDictionary class]]) [self problem:@"Tuples is not a dictionary of entities"];
  for (NSString *name in [tuples isKindOfClass:[NSDictionary class]] ? tuples : @{}) {
    NSDictionary *tuple = tuples[name];
    NSString *what = [@"Tuples." stringByAppendingString:name];
    NSEntityDescription *entity = _model.entitiesByName[name];
    if (!entity) {
      [self problem:[NSString stringWithFormat:@"%@: the model has no entity %@", what, name]];
      continue;
    }
    if (![tuple isKindOfClass:[NSDictionary class]]) {
      [self problem:[NSString stringWithFormat:@"%@ is not a dictionary (object, relation or relationName, user)", what]];
      continue;
    }
    for (NSString *key in tuple) {
      if (![@[ @"object", @"relation", @"relationName", @"user" ] containsObject:key]) {
        [self problem:[NSString stringWithFormat:@"%@: %@ is no key of a tuple (object, relation or relationName, user)", what, key]];
      }
    }
    OISRelationTupleSource *source = [[OISRelationTupleSource alloc] init];
    source.entity = entity;
    id objectName = tuple[@"object"];
    source.object = [objectName isKindOfClass:[NSString class]] ? entity.relationshipsByName[objectName] : nil;
    source.user = [tuple[@"user"] isKindOfClass:[NSString class]] ? tuple[@"user"] : nil;
    source.relationAttribute = [tuple[@"relation"] isKindOfClass:[NSString class]] ? tuple[@"relation"] : nil;
    source.relationName = [tuple[@"relationName"] isKindOfClass:[NSString class]] ? tuple[@"relationName"] : nil;
    if (!source.object || source.object.isToMany) {
      [self problem:[NSString stringWithFormat:@"%@: object names no to-one of %@", what, name]];
      continue;
    }
    if (!source.object.inverseRelationship) {
      [self problem:[NSString stringWithFormat:@"%@: %@.%@ needs an inverse, for its object's rows to find their tuples", what, name, objectName]];
      continue;
    }
    if (!OISIsKeyPath(source.user)) {
      [self problem:[NSString stringWithFormat:@"%@: user names no key path", what]];
      continue;
    }
    if (![[self property:source.user of:entity what:what] isKindOfClass:[NSAttributeDescription class]]) continue;
    if ((source.relationName.length > 0) == (source.relationAttribute.length > 0)) {
      [self problem:[NSString stringWithFormat:@"%@: give relation (an attribute) or relationName (the one relation), one of them", what]];
      continue;
    }
    if (source.relationAttribute.length && !entity.attributesByName[source.relationAttribute]) {
      [self problem:[NSString stringWithFormat:@"%@: %@ has no attribute %@", what, name, source.relationAttribute]];
      continue;
    }
    [sources addObject:source];
  }
  _sources = sources;
}

// The terms of a relation's definition, checked against the model: of an
// entity, or (entity nil) of the service.
- (NSArray<OISRelationTerm *> *)termsOf:(id)definition relation:(NSString *)relation entity:(NSEntityDescription *)entity
{
  NSString *what = entity ? [NSString stringWithFormat:@"%@.%@", entity.name, relation] : [@"Service." stringByAppendingString:relation];
  if (![definition isKindOfClass:[NSArray class]]) {
    [self problem:[NSString stringWithFormat:@"%@ is not a list of terms", what]];
    return @[];
  }
  NSMutableArray *terms = [NSMutableArray array];
  for (id item in definition) {
    if (![item isKindOfClass:[NSDictionary class]]) {
      [self problem:[NSString stringWithFormat:@"%@: a term is not a dictionary", what]];
      continue;
    }
    NSDictionary *spec = item;
    OISRelationTerm *term = [[OISRelationTerm alloc] init];
    NSSet *allowed = nil;
    if (spec[@"direct"]) {
      allowed = [NSSet setWithObject:@"direct"];
      if (!OISIsYes(spec[@"direct"]) || !entity) {
        [self problem:[NSString stringWithFormat:@"%@: direct is YES, and only on an entity", what]];
        continue;
      }
      term.kind = OISTermDirect;
      BOOL any = NO;
      for (OISRelationTupleSource *source in _sources) {
        NSEntityDescription *object = source.object.destinationEntity;
        if ([entity isKindOfEntity:object] || [object isKindOfEntity:entity]) any = YES;
      }
      if (!any) [self problem:[NSString stringWithFormat:@"%@: direct, but no Tuples have a %@ as their object", what, entity.name]];
    } else if (spec[@"where"]) {
      allowed = [NSSet setWithObject:@"where"];
      term.kind = OISTermWhere;
      term.text = [spec[@"where"] isKindOfClass:[NSString class]] ? spec[@"where"] : nil;
      if (!term.text.length || !entity) {
        [self problem:[NSString stringWithFormat:@"%@: where is a predicate, and only on an entity", what]];
        continue;
      }
      @try {
        (void)[NSPredicate predicateWithFormat:term.text];
      } @catch (NSException *exception) {
        [self problem:[NSString stringWithFormat:@"%@: where %@ does not parse: %@", what, term.text, exception.reason]];
        continue;
      }
      NSMutableArray *paths = [NSMutableArray array];
      OISConditionFormat(term.text, @"", @[], [NSMutableArray array], paths);
      BOOL fits = YES;
      for (NSString *path in paths) {
        if (![self property:path of:entity what:what]) fits = NO;
      }
      if (!fits) continue;
    } else if (spec[@"claim"]) {
      allowed = [NSSet setWithObjects:@"claim", @"value", nil];
      term.kind = OISTermClaim;
      term.claim = [spec[@"claim"] isKindOfClass:[NSString class]] ? spec[@"claim"] : nil;
      term.value = [spec[@"value"] isKindOfClass:[NSString class]] ? spec[@"value"] : nil;
      if (!term.claim.length || !term.value.length) {
        [self problem:[NSString stringWithFormat:@"%@: a claim term names its claim and its value", what]];
        continue;
      }
    } else if (spec[@"relation"]) {
      allowed = [NSSet setWithObjects:@"relation", @"from", @"on", nil];
      term.relation = [spec[@"relation"] isKindOfClass:[NSString class]] ? spec[@"relation"] : nil;
      if (!term.relation.length) {
        [self problem:[NSString stringWithFormat:@"%@: relation names no relation", what]];
        continue;
      }
      id on = spec[@"on"], from = spec[@"from"];
      if (on && from) {
        [self problem:[NSString stringWithFormat:@"%@: a term is from a relationship, or on the service, not both", what]];
        continue;
      }
      if (on) {
        if (![on isEqual:OISServiceTarget]) {
          [self problem:[NSString stringWithFormat:@"%@: on is service", what]];
          continue;
        }
        term.kind = OISTermComputed;
        term.onService = YES;
      } else if (from) {
        NSRelationshipDescription *through = entity && [from isKindOfClass:[NSString class]] ? entity.relationshipsByName[from] : nil;
        if (!through) {
          [self problem:[NSString stringWithFormat:@"%@: from %@ is no relationship of %@", what, from, entity.name ?: @"the service"]];
          continue;
        }
        term.kind = OISTermFrom;
        term.through = from;
      } else {
        term.kind = OISTermComputed;
        term.onService = !entity;
      }
    } else {
      [self problem:[NSString stringWithFormat:@"%@: a term says direct, relation, where or claim", what]];
      continue;
    }
    NSMutableSet *extra = [NSMutableSet setWithArray:spec.allKeys];
    [extra minusSet:allowed];
    if (extra.count) {
      [self problem:[NSString stringWithFormat:@"%@: %@ is no key of this term", what,
                                               [[extra.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]];
    }
    [terms addObject:term];
  }
  return terms;
}

// The terms the entity (or a super-entity) defines the relation with; nil.
- (NSArray<OISRelationTerm *> *)termsOf:(NSString *)relation entity:(NSEntityDescription *)entity
{
  for (NSEntityDescription *at = entity; at; at = at.superentity) {
    NSArray *terms = _entities[at.name][relation];
    if (terms) return terms;
  }
  return nil;
}

- (BOOL)entity:(NSEntityDescription *)entity defines:(NSString *)relation
{
  return [self termsOf:relation entity:entity] != nil;
}

// What a term names elsewhere is defined (once every relation is read).
- (void)checkNamedRelations
{
  for (NSString *name in _entities) {
    NSEntityDescription *entity = _model.entitiesByName[name];
    for (NSString *relation in _entities[name]) {
      NSString *what = [NSString stringWithFormat:@"%@.%@", name, relation];
      for (OISRelationTerm *term in _entities[name][relation]) {
        if (term.kind == OISTermComputed && !term.onService && ![self entity:entity defines:term.relation]) {
          [self problem:[NSString stringWithFormat:@"%@ names %@, which %@ does not define", what, term.relation, name]];
        }
        if (term.kind == OISTermComputed && term.onService && !_service[term.relation]) {
          [self problem:[NSString stringWithFormat:@"%@ names %@ on the service, which Service does not define", what, term.relation]];
        }
        if (term.kind == OISTermFrom) {
          NSRelationshipDescription *through = entity.relationshipsByName[term.through];
          NSEntityDescription *destination = through.destinationEntity;
          if (![self entity:destination defines:term.relation]) {
            [self problem:[NSString stringWithFormat:@"%@: %@ does not define %@", what, destination.name, term.relation]];
          }
        }
      }
    }
  }
  for (NSString *relation in _service) {
    for (OISRelationTerm *term in _service[relation]) {
      if (term.kind == OISTermComputed && !_service[term.relation]) {
        [self problem:[NSString stringWithFormat:@"Service.%@ names %@, which Service does not define", relation, term.relation]];
      }
    }
  }
  // A tuple's one relation: its object's entity defines it.
  for (OISRelationTupleSource *source in _sources) {
    if (source.relationName.length && ![self entity:source.object.destinationEntity defines:source.relationName]) {
      [self problem:[NSString stringWithFormat:@"Tuples.%@: %@ does not define %@", source.entity.name, source.object.destinationEntity.name,
                                               source.relationName]];
    }
  }
}

// Computed relations that come back to themselves (a relation of the same
// object, all the way round) hold for no one: a mistake. (A from that does
// - a folder's viewers from its parent's - is a tree, followed to a depth.)
- (void)checkCycles
{
  for (NSString *name in _entities) {
    NSEntityDescription *entity = _model.entitiesByName[name];
    for (NSString *relation in _entities[name]) {
      NSMutableArray *path = [NSMutableArray array];
      if ([self relation:relation entity:entity reaches:relation path:path first:YES]) {
        [self problem:[NSString stringWithFormat:@"%@: %@ come round to %@", name, [path componentsJoinedByString:@" -> "], relation]];
      }
    }
  }
}

- (BOOL)relation:(NSString *)relation entity:(NSEntityDescription *)entity reaches:(NSString *)target path:(NSMutableArray *)path first:(BOOL)first
{
  if (!first && [relation isEqualToString:target]) return YES;
  if ([path containsObject:relation]) return NO;
  [path addObject:relation];
  for (OISRelationTerm *term in [self termsOf:relation entity:entity] ?: @[]) {
    if (term.kind != OISTermComputed || term.onService) continue;
    if ([self relation:term.relation entity:entity reaches:target path:path first:NO]) return YES;
  }
  [path removeLastObject];
  return NO;
}

#pragma mark Who

- (NSArray<NSString *> *)identitiesOfPrincipal:(HSPrincipal *)principal
{
  if (!principal) return @[];
  NSMutableOrderedSet *identities = [NSMutableOrderedSet orderedSet];
  for (NSString *claim in _identities) {
    id value = [claim isEqualToString:@"sub"] ? (principal.subject ?: principal.claims[@"sub"]) : principal.claims[claim];
    for (id item in [value isKindOfClass:[NSArray class]] ? value : (value ? @[ value ] : @[])) {
      if ([item isKindOfClass:[NSString class]] && [item length]) [identities addObject:item];
    }
  }
  return identities.array;
}

// A claim term: the principal's claim is the value, or (a list) has it.
static BOOL OISClaimHolds(HSPrincipal *principal, NSString *claim, NSString *value)
{
  id held = [claim isEqualToString:@"sub"] ? principal.subject : principal.claims[claim];
  if ([held isKindOfClass:[NSArray class]]) return [held containsObject:value];
  return [held isKindOfClass:[NSString class]] && [held isEqualToString:value];
}

// A relation of the service: held by the principal, or not.
- (BOOL)principal:(HSPrincipal *)principal holdsOnService:(NSString *)relation seen:(NSMutableSet *)seen
{
  if (!principal || [seen containsObject:relation]) return NO;
  [seen addObject:relation];
  BOOL holds = NO;
  for (OISRelationTerm *term in _service[relation] ?: @[]) {
    if (term.kind == OISTermClaim && OISClaimHolds(principal, term.claim, term.value)) holds = YES;
    if (term.kind == OISTermComputed && [self principal:principal holdsOnService:term.relation seen:seen]) holds = YES;
    if (holds) break;
  }
  [seen removeObject:relation];
  return holds;
}

#pragma mark Predicates

- (NSPredicate *)predicateForRelation:(NSString *)relation entity:(NSEntityDescription *)entity principal:(HSPrincipal *)principal
{
  if (![self entity:entity defines:relation]) return nil;
  NSMutableArray *arguments = [NSMutableArray array];
  NSString *format = [self formatForRelation:relation entity:entity prefix:@"" principal:principal identities:[self identitiesOfPrincipal:principal]
                                   arguments:arguments depth:0 seen:[NSMutableSet set]];
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
                      principal:(HSPrincipal *)principal
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
        if (term.onService) {
          BOOL held = [self principal:principal holdsOnService:term.relation seen:[NSMutableSet set]];
          [alternatives addObject:held ? @"TRUEPREDICATE" : @"FALSEPREDICATE"];
        } else {
          [alternatives addObject:[self formatForRelation:term.relation entity:entity prefix:prefix principal:principal identities:identities
                                                arguments:arguments depth:depth seen:seen]];
        }
        break;
      case OISTermFrom: {
        NSRelationshipDescription *through = entity.relationshipsByName[term.through];
        NSEntityDescription *destination = through.destinationEntity;
        NSString *path = [dot stringByAppendingString:term.through];
        if (!through.isToMany) {
          [alternatives addObject:[self formatForRelation:term.relation entity:destination prefix:path principal:principal identities:identities
                                                arguments:arguments depth:depth + 1 seen:seen]];
          break;
        }
        // Through a to-many: any of its members (Zanzibar's tuple to
        // userset reads every tuple of the set), a subquery whose variable
        // the members' relation is under.
        NSString *v = [NSString stringWithFormat:@"$v%lu", (unsigned long)depth + 1];
        NSString *member = [self formatForRelation:term.relation entity:destination prefix:v principal:principal identities:identities
                                         arguments:arguments depth:depth + 1 seen:seen];
        [alternatives addObject:[NSString stringWithFormat:@"SUBQUERY(%@, %@, %@).@count > 0", path, v, member]];
        break;
      }
      case OISTermWhere:
        [alternatives addObject:OISConditionFormat(term.text, prefix, identities, arguments, nil)];
        break;
      case OISTermClaim:
        [alternatives addObject:principal && OISClaimHolds(principal, term.claim, term.value) ? @"TRUEPREDICATE" : @"FALSEPREDICATE"];
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
      if (term.kind == OISTermComputed && !term.onService) [pending addObject:term.relation];
    }
  }
  return through;
}

- (NSString *)versionForPrincipal:(HSPrincipal *)principal context:(NSManagedObjectContext *)context
{
  if (!_sources.count && !_service.count) return nil;
  NSArray *identities = [self identitiesOfPrincipal:principal];
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
  // What the caller holds on the service (a claim given or taken) too.
  for (NSString *relation in [_service.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([self principal:principal holdsOnService:relation seen:[NSMutableSet set]]) [held addObject:[@"service#" stringByAppendingString:relation]];
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

#pragma mark - ODataPermissions

@interface ODataPermissions ()
- (instancetype)initWithPropertyList:(NSDictionary *)propertyList NS_DESIGNATED_INITIALIZER;
@end

@implementation ODataPermissions

+ (instancetype)permissionsWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
  NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
  if (!data) return nil;
  NSError *failure = nil;
  id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&failure];
  if (!plist) {
    if (error) {
      *error = [NSError errorWithDomain:ODataPermissionsErrorDomain code:1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a property list: %@", url.path, failure.localizedDescription ?: @"?"] }];
    }
    return nil;
  }
  return [self permissionsWithPropertyList:plist error:error];
}

+ (instancetype)permissionsWithPropertyList:(NSDictionary *)propertyList error:(NSError **)error
{
  if (![propertyList isKindOfClass:[NSDictionary class]] || [propertyList[@"Version"] integerValue] != 1) {
    if (error) {
      *error = [NSError errorWithDomain:ODataPermissionsErrorDomain code:2 userInfo:@{
        NSLocalizedDescriptionKey: @"Not a permissions file: a dictionary with Version 1 is" }];
    }
    return nil;
  }
  return [[self alloc] initWithPropertyList:propertyList];
}

- (instancetype)initWithPropertyList:(NSDictionary *)propertyList
{
  if (!(self = [super init])) return nil;
  _propertyList = [propertyList copy];
  return self;
}

- (NSArray<NSString *> *)problemsWithModel:(NSManagedObjectModel *)model
{
  return [[OISAuthorization alloc] initWithPropertyList:_propertyList model:model].problems;
}

@end
