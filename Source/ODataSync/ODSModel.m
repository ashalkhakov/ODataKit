// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSModel.h"
#import <ODataKit/ODataExpression.h>
#import <ODataKit/ODataError.h>

// The mapper's version attribute key (ODataService's ODataUserInfoETag):
// named here, so that ODataSync's client needs no ODataService (iOS).
static NSString * const ODSUserInfoETag = @"OData.etag";

NSString * const ODataSyncDirectionKey = @"ODataSync.direction";
NSString * const ODataSyncConflictsKey = @"ODataSync.conflicts";
NSString * const ODataSyncModifiedKey = @"ODataSync.modified";
NSString * const ODataSyncVersionsKey = @"ODataSync.versions";
NSString * const ODataSyncMergeKey = @"ODataSync.merge";

// An attribute an entity (or one it derives from) names in its userInfo,
// when it is a String.
static NSAttributeDescription *ODSNamedString(NSEntityDescription *entity, NSString *key)
{
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    NSString *name = e.userInfo[key];
    if (name) {
      NSAttributeDescription *attribute = entity.attributesByName[name];
      return attribute.attributeType == NSStringAttributeType ? attribute : nil;
    }
  }
  return nil;
}

NSAttributeDescription *ODSModifiedAttributeOf(NSEntityDescription *entity)
{
  return ODSNamedString(entity, ODataSyncModifiedKey);
}

@implementation ODSModel {
  NSMutableDictionary<NSString *, NSArray *> *_attributes;
  NSMutableDictionary<NSString *, NSArray *> *_toOnes;
}

- (instancetype)initWithModel:(NSManagedObjectModel *)model
{
  self = [super init];
  if (!self) return nil;
  _model = model;
  _mapper = [[ODataPropertyMapper alloc] init];
  _attributes = [NSMutableDictionary dictionary];
  _toOnes = [NSMutableDictionary dictionary];
  return self;
}

- (NSEntityDescription *)rootOf:(NSEntityDescription *)entity
{
  while (entity.superentity) entity = entity.superentity;
  return entity;
}

- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity
{
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    NSString *direction = [e.userInfo[ODataSyncDirectionKey] lowercaseString];
    if ([direction isEqualToString:@"down"]) return ODataSyncDirectionDown;
    if ([direction isEqualToString:@"up"]) return ODataSyncDirectionUp;
    if ([direction isEqualToString:@"both"]) return ODataSyncDirectionBoth;
  }
  return ODataSyncDirectionNone;
}

- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity toward:(ODataSyncRemote *)remote
{
  ODataSyncDirection direction = [self directionOfEntity:entity];
  return remote.peer && direction == ODataSyncDirectionUp ? ODataSyncDirectionBoth : direction;
}

- (NSArray<NSEntityDescription *> *)rootEntitiesGoing:(NSSet<NSNumber *> *)directions toward:(ODataSyncRemote *)remote
{
  NSMutableArray *roots = [NSMutableArray array];
  for (NSEntityDescription *entity in [self.model.entities sortedArrayUsingComparator:^NSComparisonResult(NSEntityDescription *a, NSEntityDescription *b) {
         return [a.name compare:b.name];
       }]) {
    if (entity.superentity || ![directions containsObject:@([self directionOfEntity:entity toward:remote])]) continue;
    if (![self.mapper keyAttributesForEntity:entity].count) continue;
    [roots addObject:entity];
  }
  // Parents first: depth-first, an entity after the destinations of its to-ones.
  NSMutableArray *ordered = [NSMutableArray array];
  NSMutableSet *visiting = [NSMutableSet set];
  __block void (^visit)(NSEntityDescription *);
  __weak __block void (^weakVisit)(NSEntityDescription *);
  weakVisit = visit = ^(NSEntityDescription *entity) {
    if ([ordered containsObject:entity] || [visiting containsObject:entity.name]) return;
    [visiting addObject:entity.name];
    for (NSRelationshipDescription *toOne in [self toOnesOf:entity]) {
      NSEntityDescription *destination = [self rootOf:toOne.destinationEntity];
      if ([roots containsObject:destination]) weakVisit(destination);
    }
    [ordered addObject:entity];
  };
  for (NSEntityDescription *entity in roots) visit(entity);
  return ordered;
}

- (BOOL)checkNames:(NSError **)error
{
  for (NSEntityDescription *entity in [self syncedEntities]) {
    NSMutableArray *names = [NSMutableArray arrayWithObject:@[ [self.mapper entitySetForEntity:[self rootOf:entity]], @"entity set" ]];
    for (NSAttributeDescription *attribute in [[self attributesOf:entity] arrayByAddingObjectsFromArray:[self keyAttributesOf:entity]]) {
      [names addObject:@[ [self.mapper propertyForAttribute:attribute], [@"property of " stringByAppendingString:entity.name] ]];
    }
    for (NSRelationshipDescription *toOne in [self toOnesOf:entity]) {
      [names addObject:@[ [self.mapper propertyForRelationship:toOne], [@"navigation property of " stringByAppendingString:entity.name] ]];
    }
    for (NSArray *named in names) {
      if (ODataIsIdentifier(named[0])) continue;
      if (error) *error = OISError(ODataIncrementalStoreErrorInvalidName,
                                   [NSString stringWithFormat:@"\"%@\" is not an OData identifier (an %@'s name)", named[0], named[1]]);
      return NO;
    }
  }
  return YES;
}

- (NSArray<NSEntityDescription *> *)syncedEntities
{
  NSMutableArray *synced = [NSMutableArray array];
  for (NSEntityDescription *entity in self.model.entities) {
    if ([self directionOfEntity:entity] != ODataSyncDirectionNone) [synced addObject:entity];
  }
  return synced;
}

- (NSArray<NSAttributeDescription *> *)attributesOf:(NSEntityDescription *)entity
{
  @synchronized (_attributes) {
    NSArray *known = _attributes[entity.name];
    if (known) return known;
  }
  NSMutableArray *attributes = [NSMutableArray array];
  NSAttributeDescription *bag = [self.mapper dynamicPropertiesAttributeOfEntity:entity];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attribute = entity.attributesByName[name];
    if (attribute.isTransient || attribute == bag || ![self.mapper servesProperty:attribute]) continue;
    // Merged: exchanged as deltas, never in a row (docs/offline-sync.md, 14).
    if ([self mergerNameOf:attribute]) continue;
    [attributes addObject:attribute];
  }
  @synchronized (_attributes) {
    _attributes[entity.name] = attributes;
  }
  return attributes;
}

- (NSString *)mergerNameOf:(NSAttributeDescription *)attribute
{
  id name = attribute.userInfo[ODataSyncMergeKey];
  return attribute.attributeType == NSBinaryDataAttributeType && [name isKindOfClass:[NSString class]] && [name length] ? name : nil;
}

- (BOOL)mergesEntity:(NSEntityDescription *)entity
{
  if ([self mergedAttributesOf:entity].count) return YES;
  for (NSEntityDescription *sub in entity.subentities) {
    if ([self mergesEntity:sub]) return YES;
  }
  return NO;
}

- (NSArray<NSAttributeDescription *> *)mergedAttributesOf:(NSEntityDescription *)entity
{
  NSMutableArray *merged = [NSMutableArray array];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attribute = entity.attributesByName[name];
    if (!attribute.isTransient && [self mergerNameOf:attribute] && [self.mapper servesProperty:attribute]) [merged addObject:attribute];
  }
  return merged;
}

- (NSArray<NSRelationshipDescription *> *)toOnesOf:(NSEntityDescription *)entity
{
  @synchronized (_toOnes) {
    NSArray *known = _toOnes[entity.name];
    if (known) return known;
  }
  NSMutableArray *toOnes = [NSMutableArray array];
  for (NSString *name in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSRelationshipDescription *relationship = entity.relationshipsByName[name];
    if (relationship.isToMany || relationship.isTransient || !relationship.destinationEntity) continue;
    if ([self directionOfEntity:relationship.destinationEntity] == ODataSyncDirectionNone) continue;
    if (![self.mapper servesProperty:relationship]) continue;
    [toOnes addObject:relationship];
  }
  @synchronized (_toOnes) {
    _toOnes[entity.name] = toOnes;
  }
  return toOnes;
}

- (NSArray<NSAttributeDescription *> *)keyAttributesOf:(NSEntityDescription *)entity
{
  return [self.mapper keyAttributesForEntity:[self rootOf:entity]];
}

- (NSString *)conflictRuleOf:(NSEntityDescription *)entity
{
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    NSString *rule = e.userInfo[ODataSyncConflictsKey];
    if (rule) return rule.lowercaseString;
  }
  return nil;
}

- (NSAttributeDescription *)modifiedAttributeOf:(NSEntityDescription *)entity
{
  return ODSNamedString(entity, ODataSyncModifiedKey);
}

- (NSAttributeDescription *)versionsAttributeOf:(NSEntityDescription *)entity
{
  return ODSNamedString(entity, ODataSyncVersionsKey);
}

- (NSAttributeDescription *)versionAttributeOf:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
    id flag = attribute.userInfo[ODSUserInfoETag];
    if (!([flag isEqual:@"YES"] || [flag isEqual:@YES])) continue;
    switch (attribute.attributeType) {
      case NSInteger16AttributeType:
      case NSInteger32AttributeType:
      case NSInteger64AttributeType:
        return attribute;
      default:
        return nil;
    }
  }
  return nil;
}

@end
