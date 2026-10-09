// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"
#import <ODataKit/ODataExpression.h>

@implementation ODSCodec

- (instancetype)initWithModel:(ODSModel *)model
{
  self = [super init];
  if (!self) return nil;
  _model = model;
  return self;
}

- (ODataPropertyMapper *)mapper
{
  return self.model.mapper;
}

- (NSDictionary *)keyOfObject:(NSManagedObject *)object
{
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model keyAttributesOf:object.entity]) {
    id value = [object valueForKey:attribute.name];
    if (value) key[attribute.name] = value;
  }
  return key;
}

- (NSDictionary *)keyFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity
{
  if (![json isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model keyAttributesOf:entity]) {
    id raw = json[[self.mapper propertyForAttribute:attribute]];
    id value = raw && raw != [NSNull null] ? [self.mapper.values coreDataValueForJSON:raw attribute:attribute] : nil;
    if (!value) return nil;
    key[attribute.name] = value;
  }
  return key;
}

- (NSDictionary *)keyFromValues:(NSDictionary *)values entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model keyAttributesOf:entity]) {
    id value = values[attribute.name];
    if (!value || value == [NSNull null]) return nil;
    key[attribute.name] = value;
  }
  return key;
}

- (NSDictionary *)keyFromID:(NSString *)identifier entity:(NSEntityDescription **)found among:(NSArray<NSEntityDescription *> *)entities
{
  NSString *text = [identifier stringByRemovingPercentEncoding] ?: identifier;
  // A whole URL: from the entity set's name on.
  for (NSEntityDescription *entity in entities) {
    NSString *set = [self.mapper entitySetForEntity:entity];
    NSRange at = [text rangeOfString:[NSString stringWithFormat:@"/%@(", set] options:NSBackwardsSearch];
    if (at.location != NSNotFound) {
      text = [text substringFromIndex:at.location + 1];
      break;
    }
  }
  ODataResourcePath *path = [ODataResourcePath pathWithString:text error:NULL];
  ODataPathSegment *segment = path.segments.firstObject;
  if (!segment.keys) return nil;
  NSEntityDescription *entity = nil;
  for (NSEntityDescription *candidate in entities) {
    if ([[self.mapper entitySetForEntity:candidate] isEqualToString:segment.name]) entity = candidate;
  }
  if (!entity) return nil;
  NSArray<NSAttributeDescription *> *attributes = [self.model keyAttributesOf:entity];
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in attributes) {
    ODataExpression *part = segment.keys[[self.mapper propertyForAttribute:attribute]];
    if (!part && attributes.count == 1) part = segment.keys[@""];
    id value = part.value ? [self.mapper.values coreDataValueForJSON:part.value attribute:attribute] : nil;
    if (!value) return nil;
    key[attribute.name] = value;
  }
  if (found) *found = entity;
  return key;
}

- (NSString *)keyTextOf:(NSDictionary *)key entity:(NSEntityDescription *)entity
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self.model keyAttributesOf:entity]) {
    [parts addObject:[NSString stringWithFormat:@"%@=%@", attribute.name, [self.mapper.values literalForValue:key[attribute.name] attribute:attribute]]];
  }
  return [parts componentsJoinedByString:@","];
}

- (NSString *)pathOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key
{
  NSArray<NSAttributeDescription *> *attributes = [self.model keyAttributesOf:entity];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSAttributeDescription *attribute in attributes) {
    NSString *literal = [self.mapper.values literalForValue:key[attribute.name] attribute:attribute];
    [parts addObject:attributes.count == 1 ? literal
                                           : [NSString stringWithFormat:@"%@=%@", [self.mapper propertyForAttribute:attribute], literal]];
  }
  return [NSString stringWithFormat:@"%@(%@)", [self.mapper entitySetForEntity:[self.model rootOf:entity]], [parts componentsJoinedByString:@","]];
}

- (NSManagedObject *)objectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key inContext:(NSManagedObjectContext *)context
{
  NSEntityDescription *root = [self.model rootOf:entity];
  NSMutableArray *conditions = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self.model keyAttributesOf:root]) {
    if (!key[attribute.name]) return nil;
    [conditions addObject:[NSPredicate predicateWithFormat:@"%K == %@", attribute.name, key[attribute.name]]];
  }
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:root.name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:conditions];
  fetch.includesSubentities = YES;
  fetch.fetchLimit = 1;
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

static BOOL ODSSame(id a, id b)
{
  // A digest (a shadow's large binary) says whether data is its own.
  if ([b isKindOfClass:[ODataSyncDigest class]]) return [b isEqual:a];
  return a == b || [a isEqual:b];
}

- (void)applyJSON:(NSDictionary *)json toObject:(NSManagedObject *)object
{
  ODataValueCoder *values = self.mapper.values;
  for (NSAttributeDescription *attribute in [self.model attributesOf:object.entity]) {
    id raw = json[[self.mapper propertyForAttribute:attribute]];
    if (!raw) continue;
    id value = raw == [NSNull null] ? nil : [values coreDataValueForJSON:raw attribute:attribute];
    // Set only what differs: an unchanged value is no change in history.
    if (!ODSSame([object valueForKey:attribute.name], value)) [object setValue:value forKey:attribute.name];
  }
  for (NSRelationshipDescription *toOne in [self.model toOnesOf:object.entity]) {
    id raw = json[[self.mapper propertyForRelationship:toOne]];
    if (!raw) continue;
    NSManagedObject *related = nil;
    if ([raw isKindOfClass:[NSDictionary class]]) {
      NSDictionary *key = [self keyFromJSON:raw entity:toOne.destinationEntity];
      related = key ? [self objectOfEntity:toOne.destinationEntity key:key inContext:object.managedObjectContext] : nil;
    }
    if ([object valueForKey:toOne.name] != related) [object setValue:related forKey:toOne.name];
  }
}

- (NSDictionary *)JSONOfObject:(NSManagedObject *)object properties:(NSSet<NSString *> *)properties
{
  ODataValueCoder *values = self.mapper.values;
  NSMutableDictionary *json = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model attributesOf:object.entity]) {
    if (properties && ![properties containsObject:attribute.name]) continue;
    if ([self.mapper attributeIsComputed:attribute]) continue;
    id value = [object valueForKey:attribute.name];
    json[[self.mapper propertyForAttribute:attribute]] = value ? [values JSONForCoreDataValue:value attribute:attribute] : [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self.model toOnesOf:object.entity]) {
    if (properties && ![properties containsObject:toOne.name]) continue;
    NSManagedObject *related = [object valueForKey:toOne.name];
    NSString *name = [self.mapper propertyForRelationship:toOne];
    if (related) {
      json[[name stringByAppendingString:@"@odata.bind"]] = [self pathOfEntity:related.entity key:[self keyOfObject:related]];
    } else if (properties) {
      json[name] = [NSNull null];  // unlinked (a deep update's null)
    }
  }
  return json;
}

- (NSDictionary *)valuesOfObject:(NSManagedObject *)object
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model attributesOf:object.entity]) {
    values[attribute.name] = [object valueForKey:attribute.name] ?: [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self.model toOnesOf:object.entity]) {
    NSManagedObject *related = [object valueForKey:toOne.name];
    values[toOne.name] = related ? [self keyOfObject:related] : [NSNull null];
  }
  return values;
}

- (NSDictionary *)valuesFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model attributesOf:entity]) {
    id raw = json[[self.mapper propertyForAttribute:attribute]];
    if (!raw) continue;
    id value = raw == [NSNull null] ? nil : [self.mapper.values coreDataValueForJSON:raw attribute:attribute];
    values[attribute.name] = value ?: [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self.model toOnesOf:entity]) {
    id raw = json[[self.mapper propertyForRelationship:toOne]];
    if (!raw) continue;
    NSDictionary *key = [raw isKindOfClass:[NSDictionary class]] ? [self keyFromJSON:raw entity:toOne.destinationEntity] : nil;
    values[toOne.name] = key ?: [NSNull null];
  }
  return values;
}

- (void)applyValues:(NSDictionary *)values toObject:(NSManagedObject *)object
{
  for (NSAttributeDescription *attribute in [self.model attributesOf:object.entity]) {
    id value = values[attribute.name];
    if (!value) continue;
    if (value == [NSNull null]) value = nil;
    if (!ODSSame([object valueForKey:attribute.name], value)) [object setValue:value forKey:attribute.name];
  }
  for (NSRelationshipDescription *toOne in [self.model toOnesOf:object.entity]) {
    id key = values[toOne.name];
    if (!key) continue;
    NSManagedObject *related = [key isKindOfClass:[NSDictionary class]]
        ? [self objectOfEntity:toOne.destinationEntity key:key inContext:object.managedObjectContext] : nil;
    if ([object valueForKey:toOne.name] != related) [object setValue:related forKey:toOne.name];
  }
}

static NSString * const ODSDigestKey = @"@odatasync.sha256";
static NSString * const ODSDigestLengthKey = @"@odatasync.length";

- (NSDictionary *)shadowOfRow:(NSDictionary *)row entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *shadow = nil;
  for (NSAttributeDescription *attribute in [self.model attributesOf:entity]) {
    if (attribute.attributeType != NSBinaryDataAttributeType) continue;
    NSString *property = [self.mapper propertyForAttribute:attribute];
    id raw = row[property];
    // Base64 of more than that many bytes.
    if (![raw isKindOfClass:[NSString class]] || [raw length] <= ODataSyncShadowDigestBytes * 4 / 3 + 4) continue;
    id data = [self.mapper.values coreDataValueForJSON:raw attribute:attribute];
    if (![data isKindOfClass:[NSData class]] || [data length] <= ODataSyncShadowDigestBytes) continue;
    if (!shadow) shadow = [row mutableCopy];
    ODataSyncDigest *digest = [ODataSyncDigest digestOfData:data];
    shadow[property] = @{ ODSDigestKey: [digest.SHA256 base64EncodedStringWithOptions:0], ODSDigestLengthKey: @(digest.length) };
  }
  return shadow ?: row;
}

static ODataSyncDigest *ODSDigestOfMarker(id marker)
{
  if (![marker isKindOfClass:[NSDictionary class]] || ![marker[ODSDigestKey] isKindOfClass:[NSString class]]) return nil;
  NSData *sha = [[NSData alloc] initWithBase64EncodedString:marker[ODSDigestKey] options:0];
  return sha ? [[ODataSyncDigest alloc] initWithSHA256:sha length:[marker[ODSDigestLengthKey] unsignedIntegerValue]] : nil;
}

- (NSDictionary *)valuesFromShadow:(NSDictionary *)shadow entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *row = [shadow mutableCopy];
  NSMutableDictionary *digests = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model attributesOf:entity]) {
    if (attribute.attributeType != NSBinaryDataAttributeType) continue;
    NSString *property = [self.mapper propertyForAttribute:attribute];
    ODataSyncDigest *digest = ODSDigestOfMarker(row[property]);
    if (!digest) continue;
    digests[attribute.name] = digest;
    [row removeObjectForKey:property];
  }
  NSMutableDictionary *values = [[self valuesFromJSON:row entity:entity] mutableCopy];
  [values addEntriesFromDictionary:digests];
  return values;
}

- (BOOL)shadowHasDigests:(NSDictionary *)shadow entity:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attribute in [self.model attributesOf:entity])
    if (attribute.attributeType == NSBinaryDataAttributeType && ODSDigestOfMarker(shadow[[self.mapper propertyForAttribute:attribute]])) return YES;
  return NO;
}

- (NSDictionary *)rowOfObject:(NSManagedObject *)object
{
  ODataValueCoder *coder = self.mapper.values;
  NSMutableDictionary *row = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.model attributesOf:object.entity]) {
    id value = [object valueForKey:attribute.name];
    row[[self.mapper propertyForAttribute:attribute]] = value ? [coder JSONForCoreDataValue:value attribute:attribute] : [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self.model toOnesOf:object.entity]) {
    NSManagedObject *related = [object valueForKey:toOne.name];
    NSMutableDictionary *key = related ? [NSMutableDictionary dictionary] : nil;
    for (NSAttributeDescription *attribute in related ? [self.model keyAttributesOf:related.entity] : @[]) {
      key[[self.mapper propertyForAttribute:attribute]] = [coder JSONForCoreDataValue:[related valueForKey:attribute.name] attribute:attribute];
    }
    row[[self.mapper propertyForRelationship:toOne]] = key ?: [NSNull null];
  }
  return row;
}

NSSet<NSString *> *ODSChangedNames(NSDictionary *before, NSDictionary *after)
{
  NSMutableSet *names = [NSMutableSet setWithArray:before.allKeys ?: @[]];
  [names addObjectsFromArray:after.allKeys ?: @[]];
  NSMutableSet *changed = [NSMutableSet set];
  for (NSString *name in names) {
    id a = before[name] ?: [NSNull null], b = after[name] ?: [NSNull null];
    if (!ODSSame(a, b)) [changed addObject:name];
  }
  return changed;
}

- (NSDictionary *)versionsOfObject:(NSManagedObject *)object
{
  NSAttributeDescription *attribute = object ? [self.model versionsAttributeOf:object.entity] : nil;
  return attribute ? ODSVersionsFromText([object valueForKey:attribute.name]) : @{};
}

- (NSDictionary *)versionsOfRow:(NSDictionary *)row entity:(NSEntityDescription *)entity
{
  NSAttributeDescription *attribute = row ? [self.model versionsAttributeOf:entity] : nil;
  return attribute ? ODSVersionsFromText(row[[self.mapper propertyForAttribute:attribute]]) : @{};
}

@end
