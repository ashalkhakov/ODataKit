// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataQueryBuilder.h"
#import "ODataFunctionExpression.h"
#import "ODataPredicateTranslator.h"
#import "ODataError.h"
#import "ODataSearchPredicate.h"
#import "ODataTemporalPredicate.h"
#import <ODataKit/ODataApply.h>
#import <objc/runtime.h>
#import <ODataKit/ODataExpression.h>

static NSString *OISPercentEncode(NSString *value)
{
  if (!value.length) return @"";
  /* Portable RFC 3986 unreserved encoder. Avoids URLQueryAllowedCharacterSet,
     which is missing on some gnustep-base versions. */
  static const char hex[] = "0123456789ABCDEF";
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *bytes = data.bytes;
  NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 3];
  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char c = bytes[i];
    BOOL unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
    if (unreserved) {
      [out appendFormat:@"%c", c];
    } else {
      [out appendFormat:@"%%%c%c", hex[c >> 4], hex[c & 15]];
    }
  }
  return out;
}

@implementation ODataQueryBuilder

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper serviceRoot:(NSURL *)serviceRoot
{
  self = [super init];
  if (!self) return nil;
  _mapper = mapper;
  _serviceRoot = [serviceRoot copy];
  return self;
}

- (NSURL *)composePath:(NSString *)path query:(NSArray<NSArray *> *)items error:(NSError **)error
{
  NSString *root = self.serviceRoot.absoluteString ?: @"";
  if (root.length && ![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSMutableString *s = [NSMutableString stringWithFormat:@"%@%@", root, path];
  if (items.count) {
    [s appendString:@"?"];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSArray *pair in items) {
      NSString *name = pair[0];
      NSString *value = pair.count > 1 ? pair[1] : @"";
      [parts addObject:[NSString stringWithFormat:@"%@=%@", name, OISPercentEncode(value)]];
    }
    [s appendString:[parts componentsJoinedByString:@"&"]];
  }
  NSURL *url = [NSURL URLWithString:s];
  if (!url) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, [NSString stringWithFormat:@"Could not build URL for %@", path]);
    return nil;
  }
  return url;
}

// Whether the entity's set can be searched (Capabilities.SearchRestrictions).
- (BOOL)searches:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return YES;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id restrictions = [schema capability:@"Capabilities.SearchRestrictions" forEntitySet:[self.mapper entitySetForEntity:root]];
  return !([restrictions isKindOfClass:[NSDictionary class]] && [restrictions[@"Searchable"] isEqual:@NO]);
}

// Whether the service has Data Aggregation for the entity's set
// (Aggregation.ApplySupported, or the container's ApplySupportedDefaults;
// null for either is none), and so aggregate() in $filter and $orderby.
- (BOOL)aggregates:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return NO;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id apply = [schema capability:@"Aggregation.ApplySupported" forEntitySet:[self.mapper entitySetForEntity:root]];
  id defaults = schema.containerName ? [schema annotation:@"Aggregation.ApplySupportedDefaults" forTarget:schema.containerName] : nil;
  if (apply == [NSNull null] || defaults == [NSNull null]) return NO;
  return apply != nil || defaults != nil;
}

// Whether the service expands this navigation property of the entity's
// set (Capabilities.ExpandRestrictions): an expansion only saves requests,
// so one it refuses is left out.
- (BOOL)expands:(NSString *)wire entity:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return YES;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id restrictions = [schema capability:@"Capabilities.ExpandRestrictions" forEntitySet:[self.mapper entitySetForEntity:root]];
  if (![restrictions isKindOfClass:[NSDictionary class]]) return YES;
  if ([restrictions[@"Expandable"] isEqual:@NO]) return NO;
  for (id path in [restrictions[@"NonExpandableProperties"] isKindOfClass:[NSArray class]] ? restrictions[@"NonExpandableProperties"] : @[]) {
    id name = [path isKindOfClass:[NSDictionary class]] ? path[@"$NavigationPropertyPath"] : path;
    if ([name isEqual:wire]) return NO;
  }
  return YES;
}

// Nav($select=Key) for each to-one relationship not already expanded.
// Core Data asks for every to-one relationship as soon as a fault fires,
// and a row does not name its related entities; without this, firing N
// faults costs N more requests. A service that ignores the nested $select
// sends the whole related entity, which is cached too.
- (NSArray<ODataExpandItem *> *)toOneKeyExpansionsForEntity:(NSEntityDescription *)entity except:(NSSet *)expanded error:(NSError **)error
{
  NSMutableArray *out = [NSMutableArray array];
  NSArray *names = [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSRelationshipDescription *rel = entity.relationshipsByName[name];
    // One the service does not serve is kept by the store, not read.
    if (rel.isToMany || !rel.destinationEntity || ![self.mapper servesProperty:rel]) continue;
    NSString *wire = [self.mapper propertyForRelationship:rel];
    if ([expanded containsObject:wire] || ![self expands:wire entity:entity]) continue;
    NSMutableArray *keys = [NSMutableArray array];
    for (NSAttributeDescription *key in [self.mapper keyAttributesForEntity:rel.destinationEntity]) {
      ODataSelectItem *item = [ODataSelectItem itemWithPath:@[ [self.mapper propertyForAttribute:key] ] error:error];
      if (!item) return nil;
      [keys addObject:item];
    }
    if (!keys.count) continue;
    ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
    options.select = keys;
    ODataExpandItem *item = [ODataExpandItem itemWithPath:@[ wire ] options:options error:error];
    if (!item) return nil;
    [out addObject:item];
  }
  return out;
}

// $select items of paths as OData writes them (Name, Zoo.Lion/MaxRoar).
static NSArray<ODataSelectItem *> *OISSelectItems(NSArray<NSString *> *paths, NSError **error)
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *path in paths) {
    ODataSelectItem *item = [ODataSelectItem itemWithPath:[path componentsSeparatedByString:@"/"] error:error];
    if (!item) return nil;
    [items addObject:item];
  }
  return items;
}

// $select for rows read as objects: the attributes the model has that the
// service's type has too, and each subentity's own behind its type cast
// (Zoo.Lion/MaxRoar), so a service sends nothing the store would drop.
// *select nil, for every property, without $metadata, when a subentity
// names no type, when the set's Capabilities.SelectSupport says it has
// none, or for an open type, whose dynamic properties no $select can name
// ahead. NO, and the error, for a name that cannot be written.
- (BOOL)select:(NSArray<ODataSelectItem *> **)select forEntity:(NSEntityDescription *)entity error:(NSError **)error
{
  *select = nil;
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return YES;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id support = [schema capability:@"Capabilities.SelectSupport" forEntitySet:[self.mapper entitySetForEntity:root]];
  if ([support isKindOfClass:[NSDictionary class]] && [support[@"Supported"] isEqual:@NO]) return YES;
  NSMutableArray *names = [NSMutableArray array];
  if (![self select:entity cast:nil into:names] || !names.count) return YES;
  *select = OISSelectItems(names, error);
  return *select != nil;
}

- (BOOL)select:(NSEntityDescription *)entity cast:(NSString *)cast into:(NSMutableArray *)names
{
  ODataSchemaEntityType *type = [self.mapper entityTypeForEntity:entity];
  if (!type) return NO;
  NSMutableArray *own = [NSMutableArray array];
  for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
    if (attribute.isTransient) continue;
    if ([self.mapper attributeHoldsDynamicProperties:attribute]) return NO;
    if (![self.mapper servesProperty:attribute]) continue;
    if (cast && entity.superentity.attributesByName[attribute.name]) continue;  // the base type's, selected already
    NSString *wire = [self.mapper propertyForAttribute:attribute];
    if (![self.mapper.schema property:wire ofEntityType:type]) continue;
    [own addObject:cast ? [NSString stringWithFormat:@"%@/%@", cast, wire] : wire];
  }
  // Stream properties too: not in the model, but their media ETags and
  // links come only with them.
  ODataSchemaEntityType *base = cast && entity.superentity ? [self.mapper entityTypeForEntity:entity.superentity] : nil;
  NSArray *inherited = base ? [self.mapper.schema streamPropertiesOfEntityType:base] : @[];
  for (NSString *stream in [self.mapper.schema streamPropertiesOfEntityType:type]) {
    if ([inherited containsObject:stream]) continue;
    [own addObject:cast ? [NSString stringWithFormat:@"%@/%@", cast, stream] : stream];
  }
  [names addObjectsFromArray:[own sortedArrayUsingSelector:@selector(compare:)]];
  NSArray *subentities = [entity.subentities sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ]];
  for (NSEntityDescription *subentity in subentities) {
    NSString *qualified = [self.mapper qualifiedTypeForEntity:subentity];
    if (!qualified || ![self select:subentity cast:qualified into:names]) return NO;
  }
  return YES;
}

- (ODataMutableQueryOptions *)readingOptionsForEntity:(NSEntityDescription *)entity error:(NSError **)error
{
  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  NSArray *select = nil;
  if (![self select:&select forEntity:entity error:error]) return nil;
  if (select) options.select = select;
  options.expand = [self toOneKeyExpansionsForEntity:entity except:[NSSet set] error:error];
  return options.expand ? options : nil;
}

static void OISCollectCalls(ODataExpression *e, NSMutableSet *into)
{
  if (!e) return;
  if (e.kind == ODataExpressionCall && !e.aggregate && [e.name rangeOfString:@"."].location == NSNotFound) [into addObject:e.name];
  if (e.aggregate) [into addObject:@"aggregate"];
  if (e.kind == ODataExpressionCall && [e.name hasPrefix:@"Org.OData.Aggregation.V1."]) [into addObject:e.name];
  OISCollectCalls(e.operand, into);
  OISCollectCalls(e.left, into);
  OISCollectCalls(e.right, into);
  OISCollectCalls(e.body, into);
  for (ODataExpression *a in e.arguments) OISCollectCalls(a, into);
  for (ODataExpression *a in e.namedArguments.allValues) OISCollectCalls(a, into);
}

// A canonical function the set's Capabilities.FilterFunctions leaves out
// (Part 1 section 13.3, item 20); nil when it lists none, which lets every
// function be tried.
- (NSString *)refusedFunctionIn:(ODataExpression *)filter entity:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return nil;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id listed = [schema capability:@"Capabilities.FilterFunctions" forEntitySet:[self.mapper entitySetForEntity:root]];
  if (![listed isKindOfClass:[NSArray class]] || ![listed count]) return nil;
  NSMutableSet *used = [NSMutableSet set];
  OISCollectCalls(filter, used);
  for (NSString *name in [used.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
    // A vocabulary's function by its namespace, or by the alias Aggregation.
    NSString *vocabulary = @"Org.OData.Aggregation.V1.";
    NSString *aliased = [name hasPrefix:vocabulary] ? [@"Aggregation." stringByAppendingString:[name substringFromIndex:vocabulary.length]] : nil;
    if (![listed containsObject:name] && !(aliased && [listed containsObject:aliased])) return name;
  }
  return nil;
}

// The predicate without those of a class ANDed at its top (searches,
// application time), which go into found: a search as its expression.
static NSPredicate *OISWithout(NSPredicate *predicate, Class cls, NSMutableArray *found)
{
  if ([predicate isKindOfClass:cls]) {
    [found addObject:[predicate isKindOfClass:[ODataSearchPredicate class]] ? ((ODataSearchPredicate *)predicate).search : predicate];
    return nil;
  }
  if ([predicate isKindOfClass:[NSCompoundPredicate class]] &&
      ((NSCompoundPredicate *)predicate).compoundPredicateType == NSAndPredicateType) {
    NSMutableArray *rest = [NSMutableArray array];
    for (NSPredicate *sub in ((NSCompoundPredicate *)predicate).subpredicates) {
      NSPredicate *left = OISWithout(sub, cls, found);
      if (left) [rest addObject:left];
    }
    if (!rest.count) return nil;
    return rest.count == 1 ? rest.firstObject : [NSCompoundPredicate andPredicateWithSubpredicates:rest];
  }
  return predicate;
}

static NSPredicate *OISWithoutSearches(NSPredicate *predicate, NSMutableArray<ODataSearchExpression *> *searches)
{
  return OISWithout(predicate, [ODataSearchPredicate class], searches);
}

static ODataSearchExpression *OISAllOf(NSArray<ODataSearchExpression *> *searches)
{
  ODataSearchExpression *search = searches.firstObject;
  for (NSUInteger i = 1; i < searches.count; i++) {
    search = [ODataSearchExpression searchWithKind:ODataSearchAnd text:nil left:search right:searches[i] error:NULL];
  }
  return search;
}

- (ODataPredicateTranslator *)translatorFor:(NSEntityDescription *)entity
{
  ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
  t.keysForObjectID = self.keysForObjectID;
  if (self.version) t.version = self.version;
  t.writesAggregates = [self aggregates:entity];
  return t;
}

// Application time as its query options: $at, or $from with $to or
// $toInclusive, literals typed by the entity's period.
- (BOOL)addApplicationTime:(NSArray<ODataTemporalPredicate *> *)temporal entity:(NSEntityDescription *)entity
                        to:(ODataMutableQueryOptions *)options error:(NSError **)error
{
  if (!temporal.count) return YES;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  NSAttributeDescription *start = root.attributesByName[root.userInfo[ODataUserInfoPeriodStart]];
  if (!start || temporal.count > 1) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 start ? @"One application-time predicate a fetch"
                                       : [NSString stringWithFormat:@"%@ has no application time (OData.periodStart)", entity.name]);
    return NO;
  }
  ODataTemporalPredicate *p = temporal.firstObject;
  ODataExpression *(^literal)(NSDate *) = ^ODataExpression *(NSDate *date) {
    return [ODataExpression literalWithText:[self.mapper.values literalForValue:date attribute:start]];
  };
  if (p.at) {
    options.temporalAt = literal(p.at);
  } else {
    options.temporalFrom = literal(p.from);
    if (p.to && p.toInclusive) options.temporalToInclusive = literal(p.to);
    else if (p.to) options.temporalTo = literal(p.to);
  }
  return YES;
}

// A resource path's names are written as they are, so each is checked as
// the expression builders check theirs: an entity set's or a navigation
// property's (an OData identifier), a cast's (a qualified name), a key's.
static BOOL OISPathName(NSString *name, NSString *what, BOOL qualified, NSError **error)
{
  if (ODataIsIdentifier(name) || (qualified && ODataIsQualifiedName(name))) return YES;
  if (error) *error = OISError(ODataIncrementalStoreErrorInvalidName, [NSString stringWithFormat:@"\"%@\" is not %@", name ?: @"(nil)", what]);
  return NO;
}

// Set, or Set/NS.Type: the collection a fetch reads.
static BOOL OISCollectionPath(NSString *path, NSError **error)
{
  NSArray *segments = [path componentsSeparatedByString:@"/"];
  for (NSUInteger i = 0; i < segments.count; i++) {
    if (!OISPathName(segments[i], i ? @"a type cast in a resource path (a qualified name)" : @"an entity set's name (an OData identifier)", i > 0, error)) {
      return NO;
    }
  }
  return YES;
}

// An identifier's entity set (a path, as a collection's), and its keys'
// names (written when there are several).
static BOOL OISIdentifierNames(ODataResourceIdentifier *identifier, NSError **error)
{
  if (!OISCollectionPath(identifier.entitySet ?: @"", error)) return NO;
  for (NSString *key in identifier.keys) {
    if (!OISPathName(key, @"a key property's name (an OData identifier)", NO, error)) return NO;
  }
  return YES;
}

- (NSURL *)URLForPath:(NSString *)path options:(ODataQueryOptions *)options error:(NSError **)error
{
  NSArray *items = options ? [options queryItemsWithError:error] : @[];
  return items ? [self composePath:path query:items error:error] : nil;
}

- (NSURL *)URLForFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity error:(NSError **)error
{
  ODataQueryOptions *options = [self optionsForFetch:fetch entity:entity error:error];
  if (!options) return nil;
  // The entity set, with a type cast for a derived type (Animals/Zoo.Lion).
  NSString *set = [self.mapper collectionPathForEntity:entity];
  if (!OISCollectionPath(set, error)) return nil;
  return [self URLForPath:fetch.resultType == NSCountResultType ? [set stringByAppendingString:@"/$count"] : set options:options error:error];
}

- (ODataMutableQueryOptions *)optionsForFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity error:(NSError **)error
{
  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  NSMutableArray *temporal = [NSMutableArray array];
  NSPredicate *timeless = OISWithout(fetch.predicate, [ODataTemporalPredicate class], temporal);
  if (![self addApplicationTime:temporal entity:entity to:options error:error]) return nil;
  NSMutableArray<ODataSearchExpression *> *searches = [NSMutableArray array];
  NSPredicate *predicate = OISWithoutSearches(timeless, searches);
  if (predicate) {
    options.filter = [[self translatorFor:entity] expressionForPredicate:predicate error:error];
    if (!options.filter) return nil;
    NSString *refused = [self refusedFunctionIn:options.filter entity:entity];
    if (refused) {
      if (error) *error = OISError(ODataIncrementalStoreErrorNotAllowedByService,
                                   [NSString stringWithFormat:@"%@: the service does not filter with %@ (Capabilities.FilterFunctions)", entity.name, refused]);
      return nil;
    }
  }
  if (searches.count) {
    if (![self searches:entity]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorNotAllowedByService,
                                   [NSString stringWithFormat:@"%@: the service does not search (Capabilities.SearchRestrictions)", entity.name]);
      return nil;
    }
    options.searchExpression = OISAllOf(searches);
  }

  // /$count takes $filter alone (Part 2 section 4.8): TripPin answers
  // 400 to $orderby there.
  if (fetch.resultType == NSCountResultType) return options;

  if (fetch.sortDescriptors.count) {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *sorted = [NSMutableSet set];
    for (NSSortDescriptor *desc in fetch.sortDescriptors) {
      ODataExpression *by;
      if ([desc isKindOfClass:[ODataSortDescriptor class]]) {
        // Any expression $filter could hold: a function's result, say.
        by = [[self translatorFor:entity] expressionForValue:((ODataSortDescriptor *)desc).expression error:error];
      } else {
        // category.name is Category/CategoryName: a dot would be a type cast.
        by = [[self translatorFor:entity] expressionForValue:[NSExpression expressionForKeyPath:desc.key ?: @""] error:error];
      }
      if (!by) return nil;
      [sorted addObject:by.description];
      [items addObject:[ODataOrderItem itemWithExpression:by descending:!desc.ascending]];
    }
    // The key breaks ties. Paging resumes after the last row of a page by
    // its sort values, so with ties a service can skip rows: Northwind
    // returns 60 of 77 products sorted by category name alone.
    for (NSAttributeDescription *key in [self.mapper keyAttributesForEntity:entity]) {
      NSString *name = [self.mapper propertyForAttribute:key];
      if ([sorted containsObject:name]) continue;
      ODataOrderItem *item = [ODataOrderItem itemWithExpression:[ODataExpression member:name of:nil error:error] descending:NO];
      if (!item) return nil;
      [items addObject:item];
    }
    options.orderBy = items;
  }

  if (fetch.fetchLimit > 0) options.top = @(fetch.fetchLimit);
  if (fetch.fetchOffset > 0) options.skip = @(fetch.fetchOffset);

  // A dictionary's key paths through to-one relationships: $select cannot
  // follow a navigation property (services answer 400), so each is an
  // $expand with its own $select, nested: Category($select=CategoryName).
  NSMutableDictionary *through = [NSMutableDictionary dictionary];
  if (fetch.resultType == NSDictionaryResultType && fetch.propertiesToFetch.count) {
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *computed = [NSMutableArray array];
    // The bag itself: every dynamic property, which no $select names.
    BOOL all = NO;
    for (id prop in fetch.propertiesToFetch) {
      NSString *path = [prop isKindOfClass:[NSString class]] ? prop
                     : [prop isKindOfClass:[NSExpressionDescription class]] && [(NSExpressionDescription *)prop expression].expressionType == NSKeyPathExpressionType
                       ? [(NSExpressionDescription *)prop expression].keyPath : nil;
      if ([prop isKindOfClass:[NSAttributeDescription class]]) path = [prop name];
      NSString *first = [path componentsSeparatedByString:@"."].firstObject;
      NSPropertyDescription *named = first ? entity.propertiesByName[first] : nil;
      if (named && ![self.mapper servesProperty:named]) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                     [NSString stringWithFormat:@"%@.%@ is not the service's (OData.served NO): no dictionary result has it", entity.name, first]);
        return nil;
      }
      if (first && [self.mapper attributeHoldsDynamicProperties:entity.attributesByName[first]]) {
        // One dynamic property, by its name.
        if ([path isEqualToString:first]) all = YES;
        else [names addObject:[self.mapper propertyPathForKeyPath:path entity:entity]];
        continue;
      }
      if (path && [path rangeOfString:@"."].location != NSNotFound) {
        if (![self addPath:path entity:entity to:through error:error]) return nil;
        continue;
      }
      if ([prop isKindOfClass:[NSExpressionDescription class]]) {
        NSExpression *expression = [(NSExpressionDescription *)prop expression];
        if (expression.expressionType == NSKeyPathExpressionType) {
          [names addObject:[self.mapper propertyPathForKeyPath:expression.keyPath entity:entity]];
          continue;
        }
        // Computed by the service: $compute=<expression> as <name>.
        ODataExpression *value = [[self translatorFor:entity] expressionForValue:expression error:error];
        if (!value) return nil;
        ODataComputeItem *item = [ODataComputeItem itemWithExpression:value alias:[prop name] error:error];
        if (!item) return nil;
        [computed addObject:item];
        [names addObject:[prop name]];
      } else if ([prop isKindOfClass:[NSAttributeDescription class]]) {
        [names addObject:[self.mapper propertyForAttribute:prop]];
      } else if ([prop isKindOfClass:[NSString class]]) {
        NSAttributeDescription *attr = entity.attributesByName[prop];
        [names addObject:attr ? [self.mapper propertyForAttribute:attr] : [self.mapper wireName:prop]];
      }
    }
    if (computed.count) options.compute = computed;
    // Only related values asked for: the key, not every property.
    if (!names.count && through.count) {
      for (NSAttributeDescription *key in [self.mapper keyAttributesForEntity:entity]) [names addObject:[self.mapper propertyForAttribute:key]];
    }
    if (names.count && !all) {
      options.select = OISSelectItems(names, error);
      if (!options.select) return nil;
    }
  } else if (fetch.resultType == NSManagedObjectResultType || fetch.resultType == NSManagedObjectIDResultType) {
    // Object IDs too: their rows are cached the same.
    NSArray *select = nil;
    if (![self select:&select forEntity:entity error:error]) return nil;
    if (select) options.select = select;
  }

  NSMutableArray *expansions = [[self expansionsForKeyPaths:fetch.relationshipKeyPathsForPrefetching entity:entity error:error] mutableCopy];
  if (!expansions) return nil;
  NSMutableSet *expanded = [NSMutableSet set];
  for (NSString *path in fetch.relationshipKeyPathsForPrefetching) {
    NSString *first = [path componentsSeparatedByString:@"."].firstObject;
    NSRelationshipDescription *rel = entity.relationshipsByName[first];
    [expanded addObject:rel ? [self.mapper propertyForRelationship:rel] : [self.mapper wireName:first]];
  }
  if (fetch.resultType == NSManagedObjectResultType || fetch.resultType == NSManagedObjectIDResultType) {
    NSArray *keys = [self toOneKeyExpansionsForEntity:entity except:expanded error:error];
    if (!keys) return nil;
    [expansions addObjectsFromArray:keys];
  }
  if (through.count) {
    // A relationship expanded for a value is not expanded again to prefetch it.
    [expansions filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ODataExpandItem *item, NSDictionary *bindings) {
      return !through[item.path.firstObject];
    }]];
    for (NSString *navigation in [through.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataExpandItem *item = [self expansion:navigation node:through[navigation] error:error];
      if (!item) return nil;
      [expansions addObject:item];
    }
  }
  options.expand = expansions;
  return options;
}

// A key path through to-one relationships, into a tree of expansions:
// navigation (wire name) -> { select: properties, expand: the same again }.
- (BOOL)addPath:(NSString *)keyPath entity:(NSEntityDescription *)entity to:(NSMutableDictionary *)tree error:(NSError **)error
{
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  NSMutableDictionary *level = tree;
  NSEntityDescription *at = entity;
  for (NSUInteger i = 0; i + 1 < parts.count; i++) {
    NSRelationshipDescription *relationship = at.relationshipsByName[parts[i]];
    if (!relationship || relationship.isToMany) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                   [NSString stringWithFormat:@"%@: a dictionary's key path goes through to-one relationships only", keyPath]);
      return NO;
    }
    NSString *navigation = [self.mapper propertyForRelationship:relationship];
    NSMutableDictionary *node = level[navigation];
    if (!node) level[navigation] = node = [@{ @"select": [NSMutableOrderedSet orderedSet], @"expand": [NSMutableDictionary dictionary] } mutableCopy];
    at = relationship.destinationEntity;
    if (i + 2 == parts.count) {
      NSAttributeDescription *attribute = at.attributesByName[parts.lastObject];
      if (!attribute) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, [NSString stringWithFormat:@"%@: not an attribute", keyPath]);
        return NO;
      }
      [node[@"select"] addObject:[self.mapper propertyForAttribute:attribute]];
    }
    level = node[@"expand"];
  }
  return YES;
}

- (ODataExpandItem *)expansion:(NSString *)navigation node:(NSDictionary *)node error:(NSError **)error
{
  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  NSOrderedSet *select = node[@"select"];
  if (select.count) {
    options.select = OISSelectItems(select.array, error);
    if (!options.select) return nil;
  }
  NSDictionary *expand = node[@"expand"];
  NSMutableArray *nested = [NSMutableArray array];
  for (NSString *name in [expand.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataExpandItem *item = [self expansion:name node:expand[name] error:error];
    if (!item) return nil;
    [nested addObject:item];
  }
  options.expand = nested;
  return [ODataExpandItem itemWithPath:@[ navigation ] options:options error:error];
}

- (NSURL *)URLForAggregateFetch:(NSFetchRequest *)fetch
                          entity:(NSEntityDescription *)entity
                      groupPaths:(NSArray *)paths
                      aggregates:(NSArray *)aggregates
                           after:(NSArray *)after
                           error:(NSError **)error
{
  ODataQueryOptions *options = [self optionsForAggregateFetch:fetch entity:entity groupPaths:paths aggregates:aggregates after:after error:error];
  NSString *set = [self.mapper collectionPathForEntity:entity];
  return options && OISCollectionPath(set, error) ? [self URLForPath:set options:options error:error] : nil;
}

- (ODataMutableQueryOptions *)optionsForAggregateFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity
                                             groupPaths:(NSArray *)paths aggregates:(NSArray *)aggregates
                                                  after:(NSArray *)after error:(NSError **)error
{
  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  NSMutableArray<ODataSearchExpression *> *searches = [NSMutableArray array];
  NSPredicate *predicate = OISWithoutSearches(fetch.predicate, searches);
  NSMutableArray *steps = [NSMutableArray array];
  if (predicate) {
    ODataExpression *filter = [[self translatorFor:entity] expressionForPredicate:predicate error:error];
    if (!filter) return nil;
    [steps addObject:[ODataApplyTransformation filterWithExpression:filter]];
  }
  ODataApplyTransformation *grouped = paths.count ? [ODataApplyTransformation groupByPaths:paths aggregates:aggregates error:error]
                                                  : [ODataApplyTransformation aggregateWith:aggregates];
  if (!grouped) return nil;
  [steps addObject:grouped];
  if (after.count) [steps addObjectsFromArray:after];
  options.apply = steps;
  if (searches.count) options.searchExpression = OISAllOf(searches);
  return options;
}

// A literal a grouped row's value is compared with: a number, a string, a
// boolean or null; nil for anything else.
static NSString *OISGroupedLiteral(id value)
{
  if (!value || value == [NSNull null]) return @"null";
  if ([value isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
  if (![value isKindOfClass:[NSNumber class]]) return nil;
  const char *type = [value objCType];
  // A boolean, as @YES and predicateWithFormat:'s YES are.
  if (type && (!strcmp(type, "c") || !strcmp(type, "B")) && ![value isKindOfClass:[NSDecimalNumber class]]) {
    return [value boolValue] ? @"true" : @"false";
  }
  if ([value isKindOfClass:[NSDecimalNumber class]]) return [value description];
  double d = [value doubleValue];
  if (isnan(d) || isinf(d)) return nil;
  return [value stringValue];
}

- (NSString *)groupedFilterForPredicate:(NSPredicate *)predicate names:(NSDictionary *)names
{
  return [self groupedFilterExpressionForPredicate:predicate names:names].description;
}

// (A name the builders refuse is nil too, as anything it cannot write.)
- (ODataExpression *)groupedFilterExpressionForPredicate:(NSPredicate *)predicate names:(NSDictionary *)names
{
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    NSCompoundPredicate *compound = (NSCompoundPredicate *)predicate;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSPredicate *sub in compound.subpredicates) {
      ODataExpression *part = [self groupedFilterExpressionForPredicate:sub names:names];
      if (!part) return nil;
      [parts addObject:part];
    }
    if (!parts.count) return nil;
    switch (compound.compoundPredicateType) {
      case NSNotPredicateType: return parts.count == 1 ? [ODataExpression unary:@"not" operand:parts[0] error:NULL] : nil;
      case NSAndPredicateType:
      case NSOrPredicateType: {
        ODataExpression *out = parts.firstObject;
        for (NSUInteger i = 1; i < parts.count; i++) {
          out = [ODataExpression binary:compound.compoundPredicateType == NSAndPredicateType ? @"and" : @"or" left:out right:parts[i] error:NULL];
        }
        return out;
      }
      default: return nil;
    }
  }
  if (![predicate isKindOfClass:[NSComparisonPredicate class]]) return nil;
  NSComparisonPredicate *cmp = (NSComparisonPredicate *)predicate;
  if (cmp.comparisonPredicateModifier != NSDirectPredicateModifier || cmp.options) return nil;
  NSExpression *left = cmp.leftExpression, *right = cmp.rightExpression;
  NSPredicateOperatorType type = cmp.predicateOperatorType;
  if (left.expressionType == NSConstantValueExpressionType && right.expressionType == NSKeyPathExpressionType) {
    NSExpression *swap = left; left = right; right = swap;
    NSDictionary *mirrored = @{ @(NSLessThanPredicateOperatorType): @(NSGreaterThanPredicateOperatorType),
                                @(NSGreaterThanPredicateOperatorType): @(NSLessThanPredicateOperatorType),
                                @(NSLessThanOrEqualToPredicateOperatorType): @(NSGreaterThanOrEqualToPredicateOperatorType),
                                @(NSGreaterThanOrEqualToPredicateOperatorType): @(NSLessThanOrEqualToPredicateOperatorType) };
    if (mirrored[@(type)]) type = [mirrored[@(type)] unsignedIntegerValue];
  }
  if (left.expressionType != NSKeyPathExpressionType || right.expressionType != NSConstantValueExpressionType) return nil;
  NSString *path = names[left.keyPath];
  NSString *literal = OISGroupedLiteral(right.constantValue);
  NSDictionary *operators = @{ @(NSEqualToPredicateOperatorType): @"eq", @(NSNotEqualToPredicateOperatorType): @"ne",
                               @(NSLessThanPredicateOperatorType): @"lt", @(NSLessThanOrEqualToPredicateOperatorType): @"le",
                               @(NSGreaterThanPredicateOperatorType): @"gt", @(NSGreaterThanOrEqualToPredicateOperatorType): @"ge" };
  NSString *op = operators[@(type)];
  ODataExpression *value = literal ? [ODataExpression literalWithText:literal] : nil;
  if (!path || !value || !op) return nil;
  return [ODataExpression binary:op left:[ODataExpression memberPath:[path componentsSeparatedByString:@"/"] of:nil error:NULL] right:value error:NULL];
}

- (NSString *)groupedOrderForSortDescriptors:(NSArray *)descriptors names:(NSDictionary *)names
{
  NSArray *items = [self groupedOrderItemsForSortDescriptors:descriptors names:names];
  return items.count ? [[items valueForKey:@"description"] componentsJoinedByString:@","] : nil;
}

// (A name the builders refuse is nil too, as anything it cannot write.)
- (NSArray<ODataOrderItem *> *)groupedOrderItemsForSortDescriptors:(NSArray *)descriptors names:(NSDictionary *)names
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSSortDescriptor *descriptor in descriptors) {
    NSString *path = descriptor.key ? names[descriptor.key] : nil;
    // (sel_isEqual: libobjc2's selectors carry types, so == may not match.)
    if (!path || !descriptor.selector || !sel_isEqual(descriptor.selector, @selector(compare:))) return nil;
#if defined(__APPLE__)
    // (gnustep-base has no comparator: a descriptor made with one has no
    // compare: there either.)
    if (descriptor.comparator) return nil;
#endif
    ODataOrderItem *item = [ODataOrderItem itemWithExpression:[ODataExpression memberPath:[path componentsSeparatedByString:@"/"] of:nil error:NULL]
                                                   descending:!descriptor.ascending];
    if (!item) return nil;
    [items addObject:item];
  }
  return items.count ? items : nil;
}

// Prefetch key paths as $expand items, a path through relationships
// nested (suppliers.products is Suppliers($expand=Products): 4.0 has no
// paths in $expand), and paths that share a start merged under it.
- (NSArray<ODataExpandItem *> *)expansionsForKeyPaths:(NSArray *)paths entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSMutableArray *order = [NSMutableArray array];          // wire names, first seen first
  NSMutableDictionary *children = [NSMutableDictionary dictionary];  // wire name -> key paths beneath
  NSMutableDictionary *destinations = [NSMutableDictionary dictionary];
  for (NSString *path in paths) {
    NSArray *parts = [path componentsSeparatedByString:@"."];
    NSRelationshipDescription *rel = entity.relationshipsByName[parts.firstObject];
    if (rel && ![self.mapper servesProperty:rel]) continue;  // kept by the store, not read
    NSString *wire = rel ? [self.mapper propertyForRelationship:rel] : [self.mapper wireName:parts.firstObject];
    if (![self expands:wire entity:entity]) continue;
    if (!children[wire]) {
      [order addObject:wire];
      children[wire] = [NSMutableArray array];
      if (rel.destinationEntity) destinations[wire] = rel.destinationEntity;
    }
    if (parts.count > 1) [children[wire] addObject:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"."]];
  }
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *wire in order) {
    NSEntityDescription *destination = destinations[wire];
    NSMutableArray *nested = [[children[wire] count] && destination ? [self expansionsForKeyPaths:children[wire] entity:destination error:error] : @[]
                              mutableCopy];
    if (!nested) return nil;
    ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
    if (destination) {
      // Its rows as a fetch's are: trimmed, and naming their to-ones.
      NSArray *select = nil;
      if (![self select:&select forEntity:destination error:error]) return nil;
      if (select) options.select = select;
      NSMutableSet *named = [NSMutableSet set];
      for (NSString *path in children[wire]) {
        NSRelationshipDescription *rel = destination.relationshipsByName[[path componentsSeparatedByString:@"."].firstObject];
        if (rel) [named addObject:[self.mapper propertyForRelationship:rel]];
      }
      NSArray *keys = [self toOneKeyExpansionsForEntity:destination except:named error:error];
      if (!keys) return nil;
      [nested addObjectsFromArray:keys];
    }
    options.expand = nested;
    ODataExpandItem *item = [ODataExpandItem itemWithPath:@[ wire ] options:options error:error];
    if (!item) return nil;
    [items addObject:item];
  }
  return items;
}

- (NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier error:(NSError **)error
{
  if (!OISIdentifierNames(identifier, error)) return nil;
  return [self composePath:[identifier pathWithKeyAsSegment:self.keyAsSegment] query:@[] error:error];
}

- (NSURL *)URLForReferenceFromEntityURL:(NSURL *)entity
                            relationship:(NSRelationshipDescription *)relationship
                                  target:(NSURL *)target
{
  NSString *navigation = [self.mapper propertyForRelationship:relationship];
  if (!ODataIsIdentifier(navigation)) return nil;
  NSString *s = [NSString stringWithFormat:@"%@/%@/$ref?$id=%@", entity.absoluteString, navigation, OISPercentEncode(target.absoluteString ?: @"")];
  return [NSURL URLWithString:s];
}

- (NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier
               relationship:(NSRelationshipDescription *)relationship
                      error:(NSError **)error
{
  NSString *navigation = [self.mapper propertyForRelationship:relationship];
  if (!OISIdentifierNames(identifier, error) || !OISPathName(navigation, @"a navigation property's name (an OData identifier)", NO, error)) return nil;
  NSString *path = [NSString stringWithFormat:@"%@/%@", [identifier pathWithKeyAsSegment:self.keyAsSegment], navigation];
  ODataQueryOptions *options = relationship.destinationEntity ? [self readingOptionsForEntity:relationship.destinationEntity error:error] : nil;
  if (relationship.destinationEntity && !options) return nil;
  return [self URLForPath:path options:options error:error];
}

- (NSURL *)URLForReadingIdentifier:(ODataResourceIdentifier *)identifier
                            entity:(NSEntityDescription *)entity
                             error:(NSError **)error
{
  if (!OISIdentifierNames(identifier, error)) return nil;
  ODataQueryOptions *options = [self readingOptionsForEntity:entity error:error];
  return options ? [self URLForPath:[identifier pathWithKeyAsSegment:self.keyAsSegment] options:options error:error] : nil;
}

@end
