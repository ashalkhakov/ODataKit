// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A write's plan (docs/write-plan.md): made from the request and its body
// before anything is done, then run as databases run DML. Every read the
// write needs (the rows it refers to, the rows it changes, the keys it
// counts on from) goes through the handlers first; then every check; then
// the writes, through the handlers, the ones a write depends on first;
// then the save; then what it answers with, as a read.

#import "ODataServiceInternal.h"
#import "OISPlan.h"

static NSString *OISWriteKey(NSString *pass, OISPlanNode *node)
{
  return [NSString stringWithFormat:@"%@/%p", pass, (void *)node];
}

static id OISFailed(NSError **error, NSInteger status, NSString *message)
{
  if (error) *error = ODataServiceError(status, message);
  return nil;
}

// Where a body's dynamic properties (an open type's) wait among its
// values, by a name no Core Data property has: taken out before a handler
// sees the values, and handed to it at the commit, all at once.
static NSString * const OISDynamicKey = @"@dynamic";

static BOOL OISIsIntegerAttribute(NSAttributeDescription *attribute)
{
  NSAttributeType type = attribute.attributeType;
  return type == NSInteger16AttributeType || type == NSInteger32AttributeType || type == NSInteger64AttributeType;
}

static BOOL OISIsWrite(OISPlanNode *node)
{
  switch (node.op) {
    case OISPlanInsert:
    case OISPlanUpdate:
    case OISPlanDelete:
    case OISPlanLink:
    case OISPlanUnlink:
    case OISPlanMerge:
    case OISPlanTemporal:
    case OISPlanCommit:
      return YES;
    default:
      return NO;
  }
}

@implementation OISServiceCall (Write)

#pragma mark - Planning

- (OISPlan *)beginWritePlan
{
  self.writing = [[OISPlan alloc] init];
  self.writeSequences = [NSMutableDictionary dictionary];
  return self.writing;
}

// The largest key of an entity, read once for the plan.
- (OISPlanNode *)sequenceOf:(NSAttributeDescription *)attribute entity:(NSEntityDescription *)root
{
  NSString *name = [NSString stringWithFormat:@"%@.%@", root.name, attribute.name];
  OISPlanNode *sequence = self.writeSequences[name];
  if (sequence) return sequence;
  sequence = [OISPlanNode operator:OISPlanSequence input:nil];
  sequence.entity = root;
  sequence.attributeName = attribute.name;
  sequence.handler = [self.service handlerForEntity:root] ?: self.handler;
  self.writeSequences[name] = sequence;
  return sequence;
}

// Keys a new row is not given: integers counted on from the largest
// (a Sequence), strings and UUIDs made up. Given integers are noted: the
// sequence counts on from above them.
- (BOOL)planKeysOf:(OISPlanNode *)insert values:(NSMutableDictionary *)values entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSEntityDescription *root = OISRootEntity(entity);
  NSMutableDictionary *sequences = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:root]) {
    id given = values[attribute.name];
    if (given && given != [NSNull null]) {
      if (OISIsIntegerAttribute(attribute) && [given isKindOfClass:[NSNumber class]]) {
        NSString *name = [NSString stringWithFormat:@"%@.%@", root.name, attribute.name];
        if ([given longLongValue] > [self.writing.givenKeys[name] longLongValue]) self.writing.givenKeys[name] = given;
      }
      continue;
    }
    if (OISIsIntegerAttribute(attribute)) {
      sequences[attribute.name] = [self sequenceOf:attribute entity:root];
    } else if (attribute.attributeType == NSStringAttributeType) {
      values[attribute.name] = [NSUUID UUID].UUIDString;
    } else if (attribute.attributeType == NSUUIDAttributeType) {
      values[attribute.name] = [NSUUID UUID];
    } else {
      return OISFailed(error, 400, [NSString stringWithFormat:@"A new %@ needs its %@", entity.name, [self.mapper propertyForAttribute:attribute]]) != nil;
    }
  }
  insert.sequences = sequences;
  return YES;
}

// The row an entity id names: Categories(1), or the whole URL.
- (OISPlanNode *)lookupOfReference:(id)reference error:(NSError **)error
{
  if (![reference isKindOfClass:[NSString class]]) return OISFailed(error, 400, @"An entity reference must be a string");
  NSString *text = reference;
  NSString *root = [self rootString];
  NSString *rootPath = self.service.serviceRoot.path ?: @"/";
  if (![rootPath hasSuffix:@"/"]) rootPath = [rootPath stringByAppendingString:@"/"];
  if ([text hasPrefix:root]) text = [text substringFromIndex:root.length];
  else if ([text hasPrefix:rootPath]) text = [text substringFromIndex:rootPath.length];
  ODataResourcePath *path = [ODataResourcePath pathWithString:[text stringByRemovingPercentEncoding] ?: text error:NULL];
  ODataPathSegment *first = path.segments.firstObject;
  ODataEntitySetHandler *handler = first ? [self.service handlerForEntitySet:first.name] : nil;
  NSDictionary *parts = first.keys;
  NSEntityDescription *saved = self.entity;
  self.entity = handler.entity;
  if (handler && !parts && path.segments.count == 2) parts = @{ @"": [self literalForKeySegment:path.segments[1].name] };
  NSDictionary *key = handler && parts && path.segments.count <= 2 ? [self keyFromPartsQuietly:parts entity:handler.entity] : nil;
  self.entity = saved;
  if (!key) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is not an entity of this service", reference]);
  OISPlanNode *lookup = [OISPlanNode operator:OISPlanLookup input:nil];
  lookup.entity = handler.entity;
  lookup.handler = handler;
  lookup.key = key;
  lookup.reference = reference;
  return lookup;
}

// The row a nested body names: by @id, or by its key (which may name
// none); nil, with no error, when it names none.
- (OISPlanNode *)lookupOfNested:(NSDictionary *)body entity:(NSEntityDescription *)entity error:(NSError **)error
{
  id reference = body[@"@id"] ?: body[@"@odata.id"];
  if ([reference isKindOfClass:[NSString class]]) return [self lookupOfReference:reference error:error];
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(entity)]) {
    id given = body[[self.mapper propertyForAttribute:attribute]];
    id value = given && given != [NSNull null] ? [self.coder coreDataValueForJSON:given attribute:attribute] : nil;
    if (!value || value == [NSNull null]) return nil;
    key[attribute.name] = value;
  }
  if (!key.count) return nil;
  OISPlanNode *lookup = [OISPlanNode operator:OISPlanLookup input:nil];
  lookup.entity = OISRootEntity(entity);
  lookup.handler = [self.service handlerForEntity:entity];
  lookup.key = key;
  lookup.reference = [self canonicalPathOfValues:key entity:entity] ?: entity.name;
  lookup.optional = YES;
  return lookup;
}

// The entity type a nested body names with @odata.type, of the one it
// is in; that one when it names none.
- (NSEntityDescription *)entityOf:(id)body within:(NSEntityDescription *)entity name:(NSString *)name error:(NSError **)error
{
  if (![body isKindOfClass:[NSDictionary class]]) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ takes entities", name]);
  id type = body[@"@odata.type"];
  if (![type isKindOfClass:[NSString class]]) return entity;
  NSEntityDescription *named = [self entityForTypeName:ODataTypeNameFromControlInformation(type)];
  if (!named || ![named isKindOfEntity:entity]) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is not a type of %@", type, name]);
  return named;
}

// A body's properties as values of a write, by Core Data name: an
// attribute's value (the checks against the row, for an update, are the
// check's); a relationship's row (a Lookup of @odata.bind, a nested
// Insert, or for an update a nested Merge), or members. Deletes a delta
// asks for go into inputs.
- (NSMutableDictionary *)plannedValuesOfBody:(NSDictionary *)body entity:(NSEntityDescription *)entity updating:(BOOL)updating
                                      inputs:(NSMutableArray *)inputs error:(NSError **)error
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  NSMutableDictionary *dynamic = [NSMutableDictionary dictionary];
  BOOL open = [self.service handlerForEntity:entity].isOpenType;
  for (NSString *key in [body.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([key hasPrefix:@"@"]) continue;
    NSRange at = [key rangeOfString:@"@"];
    NSString *name = at.location == NSNotFound ? key : [key substringToIndex:at.location];
    NSString *annotation = at.location == NSNotFound ? nil : [key substringFromIndex:at.location + 1];
    if ([annotation hasPrefix:@"odata."]) annotation = [annotation substringFromIndex:6];
    if (annotation && ![annotation isEqualToString:@"bind"] && ![annotation isEqualToString:@"delta"]) continue;
    NSPropertyDescription *property = [self.mapper propertyForWireName:name entity:entity];
    id value = body[key];
    if (!property && open && !annotation) {
      // A dynamic property: typed as its annotation says; null removes it.
      if (value == [NSNull null]) {
        dynamic[name] = value;
        continue;
      }
      NSMutableDictionary *one = [NSMutableDictionary dictionaryWithObject:value forKey:name];
      for (NSString *typeKey in @[ [name stringByAppendingString:@"@odata.type"], [name stringByAppendingString:@"@type"] ]) {
        if (body[typeKey]) one[typeKey] = body[typeKey];
      }
      id decoded = [self.coder dynamicPropertiesInJSON:one declared:[NSSet set]][name];
      if (!decoded) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is not a value of %@", value, name]);
      dynamic[name] = decoded;
      continue;
    }
    if (!property) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ has no property %@", entity.name, name]);
    if ([property isKindOfClass:[NSAttributeDescription class]]) {
      if (annotation) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is not a navigation property", name]);
      NSAttributeDescription *attribute = (NSAttributeDescription *)property;
      if (![self.service.writer typeNameForAttribute:attribute]) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ has no property %@", entity.name, name]);
      if ([self.service.writer isStreamAttribute:attribute]) {
        return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is a stream: PUT it at its own URL", name]);
      }
      // Core.Computed, or read only: the service's to set, whatever a body
      // says.
      if ([self.service isComputedAttribute:attribute]) continue;
      if (value == [NSNull null]) {
        values[attribute.name] = [NSNull null];
        continue;
      }
      id converted = [self.coder coreDataValueForJSON:value attribute:attribute];
      if (!converted || converted == [NSNull null]) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is not a value of %@", value, name]);
      values[attribute.name] = converted;
      continue;
    }
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
    if ([annotation isEqualToString:@"delta"]) {
      if (!updating || !relationship.isToMany || ![value isKindOfClass:[NSArray class]]) {
        return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is an array of changes to a collection of an existing entity", key]);
      }
      OISPlanMembers *members = [self plannedDelta:value within:relationship.destinationEntity name:name removesDelete:NO inputs:inputs error:error];
      if (!members) return nil;
      values[relationship.name] = members;
      continue;
    }
    if (!annotation) {
      // A deep insert: the related entities are created with this one. A
      // deep update: they are these, each one there updated, or created.
      id related = updating ? [self plannedNestedForUpdate:value relationship:relationship error:error]
                            : [self plannedInsertNested:value relationship:relationship error:error];
      if (!related) return nil;
      values[relationship.name] = related;
      continue;
    }
    if (!relationship.isToMany) {
      if (value == [NSNull null]) {
        values[relationship.name] = [NSNull null];
        continue;
      }
      OISPlanNode *lookup = [self lookupOfReference:value error:error];
      if (!lookup) return nil;
      values[relationship.name] = lookup;
      continue;
    }
    if (![value isKindOfClass:[NSArray class]]) return OISFailed(error, 400, [NSString stringWithFormat:@"%@@odata.bind takes an array", name]);
    // An update adds to a collection, as 4.0 has it; an insert sets it.
    NSMutableArray *nodes = [NSMutableArray array];
    for (id reference in value) {
      OISPlanNode *lookup = [self lookupOfReference:reference error:error];
      if (!lookup) return nil;
      [nodes addObject:lookup];
    }
    values[relationship.name] = [OISPlanMembers membersOf:nodes removing:@[] adding:updating];
  }
  if (dynamic.count) values[OISDynamicKey] = dynamic;
  return values;
}

// A new row of a deep insert (Part 1 section 11.4.2.2), its own nested
// ones in its values.
- (OISPlanNode *)plannedInsertOfBody:(NSDictionary *)body entity:(NSEntityDescription *)entity error:(NSError **)error
{
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  if (!handler || !handler.allowsInsert) {
    return OISFailed(error, handler ? 405 : 400, [NSString stringWithFormat:@"%@ cannot be inserted here", entity.name]);
  }
  NSMutableArray *inputs = [NSMutableArray array];
  NSMutableDictionary *values = [self plannedValuesOfBody:body entity:entity updating:NO inputs:inputs error:error];
  if (!values) return nil;
  OISPlanNode *insert = [OISPlanNode operator:OISPlanInsert input:nil];
  insert.entity = entity;
  insert.handler = handler;
  if (![self planKeysOf:insert values:values entity:entity error:error]) return nil;
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:entity];
  if (version) values[version.name] = @1;
  insert.values = values;
  insert.inputs = inputs;
  return insert;
}

// A deep insert's nested entities: a row, or members.
- (id)plannedInsertNested:(id)value relationship:(NSRelationshipDescription *)relationship error:(NSError **)error
{
  NSString *name = [self.mapper propertyForRelationship:relationship];
  NSArray *bodies = relationship.isToMany ? ([value isKindOfClass:[NSArray class]] ? value : nil)
                                          : ([value isKindOfClass:[NSDictionary class]] ? @[ value ] : nil);
  if (!bodies) {
    return OISFailed(error, 400, [NSString stringWithFormat:@"%@ takes %@", name, relationship.isToMany ? @"an array of entities" : @"an entity"]);
  }
  NSMutableArray *nodes = [NSMutableArray array];
  for (id body in bodies) {
    NSEntityDescription *entity = [self entityOf:body within:relationship.destinationEntity name:name error:error];
    if (!entity) return nil;
    OISPlanNode *insert = [self plannedInsertOfBody:body entity:entity error:error];
    if (!insert) return nil;
    [nodes addObject:insert];
  }
  return relationship.isToMany ? [OISPlanMembers membersOf:nodes removing:@[] adding:NO] : nodes.firstObject;
}

// A deep update's nested entities (Part 1 section 11.4.3.1): a to-one's
// entity, or null; a to-many's entities, those it had and does not name
// any more unlinked (not deleted).
- (id)plannedNestedForUpdate:(id)value relationship:(NSRelationshipDescription *)relationship error:(NSError **)error
{
  NSString *name = [self.mapper propertyForRelationship:relationship];
  if (!relationship.isToMany) {
    if (value == [NSNull null]) return value;
    if (![value isKindOfClass:[NSDictionary class]]) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ takes an entity or null", name]);
    return [self plannedMergeOfBody:value within:relationship.destinationEntity name:name error:error];
  }
  if (![value isKindOfClass:[NSArray class]]) return OISFailed(error, 400, [NSString stringWithFormat:@"%@ takes an array of entities", name]);
  NSMutableArray *nodes = [NSMutableArray array];
  for (id body in value) {
    OISPlanNode *merge = [self plannedMergeOfBody:body within:relationship.destinationEntity name:name error:error];
    if (!merge) return nil;
    [nodes addObject:merge];
  }
  return [OISPlanMembers membersOf:nodes removing:@[] adding:NO];
}

// A nested entity of a deep update: the one it names updated with the rest
// of it, as by PATCH; one it does not name, created. A branch that cannot
// be planned fails only if it is the one taken.
- (OISPlanNode *)plannedMergeOfBody:(id)body within:(NSEntityDescription *)within name:(NSString *)name error:(NSError **)error
{
  NSEntityDescription *entity = [self entityOf:body within:within name:name error:error];
  if (!entity) return nil;
  OISPlanNode *lookup = [self lookupOfNested:body entity:entity error:error];
  if (!lookup && error && *error) return nil;
  if (!lookup) return [self plannedInsertOfBody:body entity:entity error:error];

  OISPlanNode *merge = [OISPlanNode operator:OISPlanMerge input:lookup];
  merge.entity = entity;
  NSError *matchedError = nil;
  NSMutableArray *inputs = [NSMutableArray array];
  NSMutableDictionary *values = [self plannedValuesOfBody:body entity:entity updating:YES inputs:inputs error:&matchedError];
  OISPlanNode *update = [OISPlanNode operator:OISPlanUpdate input:nil];
  update.entity = entity;
  update.handler = [self.service handlerForEntity:entity];
  update.target = lookup;
  update.values = values ?: @{};
  update.inputs = inputs;
  update.typed = body[@"@odata.type"] != nil;
  id etag = body[@"@odata.etag"] ?: body[@"@etag"];
  if ([etag isKindOfClass:[NSString class]]) update.etag = etag;
  update.failure = values ? nil : matchedError;
  merge.matched = update;
  if (lookup.optional) {
    NSError *otherwiseError = nil;
    OISPlanNode *insert = [self plannedInsertOfBody:body entity:entity error:&otherwiseError];
    if (!insert) {
      insert = [OISPlanNode operator:OISPlanInsert input:nil];
      insert.entity = entity;
      insert.failure = otherwiseError;
    }
    merge.otherwise = insert;
    if (update.failure && insert.failure) {
      if (error) *error = update.failure;
      return nil;
    }
  } else if (update.failure) {
    if (error) *error = update.failure;
    return nil;
  }
  return merge;
}

// Nav@delta, or a delta payload: the collection's members changed, added
// (created or updated as they come) and, with @removed, taken away:
// deleted where they are removed for the reason "deleted" (or
// removesDelete: from an entity set), else unlinked.
- (OISPlanMembers *)plannedDelta:(NSArray *)changes within:(NSEntityDescription *)within name:(NSString *)name
                   removesDelete:(BOOL)removesDelete inputs:(NSMutableArray *)inputs error:(NSError **)error
{
  NSMutableArray *added = [NSMutableArray array], *removed = [NSMutableArray array];
  NSMutableArray *answers = [NSMutableArray array];
  for (NSDictionary *change in changes) {
    if (![change isKindOfClass:[NSDictionary class]]) return OISFailed(error, 400, @"A delta holds entities");
    id marker = change[@"@removed"] ?: change[@"@odata.removed"];
    if (!marker) {
      OISPlanNode *merge = [self plannedMergeOfBody:change within:within name:name error:error];
      if (!merge) return nil;
      [added addObject:merge];
      [answers addObject:merge];
      continue;
    }
    NSEntityDescription *entity = [self entityOf:change within:within name:name error:error];
    if (!entity) return nil;
    OISPlanNode *lookup = [self lookupOfNested:change entity:entity error:error];
    if (!lookup && error && *error) return nil;
    if (!lookup) return OISFailed(error, 400, @"A removed entity names no entity: give its @id or its key");
    lookup.optional = NO;
    [removed addObject:lookup];
    NSString *reason = [marker isKindOfClass:[NSDictionary class]] && [marker[@"reason"] isKindOfClass:[NSString class]] ? marker[@"reason"] : @"changed";
    BOOL deletes = removesDelete || [reason isEqualToString:@"deleted"];
    [answers addObject:@{ @"node": lookup, @"reason": deletes ? @"deleted" : reason }];
    if (!deletes) continue;
    ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
    if (!handler.allowsDelete) return OISFailed(error, 405, [NSString stringWithFormat:@"%@ cannot be deleted here", entity.name]);
    OISPlanNode *delete = [OISPlanNode operator:OISPlanDelete input:nil];
    delete.entity = entity;
    delete.handler = handler;
    delete.target = lookup;
    [inputs addObject:delete];
  }
  self.writeAnswers = answers;
  return [OISPlanMembers membersOf:added removing:removed adding:YES];
}

- (OISPlanNode *)objectsNode:(NSArray *)objects entity:(NSEntityDescription *)entity
{
  OISPlanNode *given = [OISPlanNode operator:OISPlanObjects input:nil];
  given.objects = objects;
  given.entity = entity;
  return given;
}

// The collection the request names, as the caller may see it: its $filter
// segments, the navigation it came through; in key order.
- (OISPlanNode *)scanOfCollection:(NSError **)error
{
  NSString *summary = nil;
  NSArray *fixed = [self fixedPredicatesSummary:&summary error:error];
  if (!fixed) return nil;
  OISPlanNode *scan = [OISPlanNode operator:OISPlanStoreScan input:nil];
  scan.entity = self.entity;
  scan.fixed = fixed;
  scan.fixedSummary = summary ?: @"";
  scan.keyOrder = YES;
  scan.limit = self.service.maxRowsInMemory;
  return scan;
}

// Runs a write: its plan, from the modification, with what it answers
// with as a read for explain; then after.
- (void)runWrite:(OISPlanNode *)modification inputs:(NSArray *)inputs answer:(OISPlanNode *)answer then:(SEL)after
{
  OISPlan *plan = self.writing;
  OISPlanNode *commit = [OISPlanNode operator:OISPlanCommit input:modification];
  commit.inputs = inputs ?: @[];
  plan.write = commit;
  if (answer) {
    ODataQueryOptions *options = self.responseOptions ?: self.request.options;
    OISPlanNode *given = [self objectsNode:@[] entity:answer.entity];
    given.objectsSummary = [NSString stringWithFormat:@"what %@ wrote", [[answer description] componentsSeparatedByString:@" set "].firstObject];
    OISPlan *returning = [self planOfObjects:@[] options:options entity:answer.entity];
    returning.root = given;
    plan.returning = returning;
  }
  self.writeAnswer = answer;
  self.writeRequestEntity = self.request.entity;
  [self runPlan:plan then:after];
}

- (void)failPlanning:(NSError *)error
{
  [self respondError:error ?: ODataServiceError(500, @"The write could not be planned")];
}

// If-Match against an ETag (nil: there is none, which * does not match).
static BOOL OISConditionAllows(NSString *condition, NSString *current)
{
  for (NSString *tag in [condition componentsSeparatedByString:@","]) {
    NSString *t = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (([t isEqualToString:@"*"] && current) || (current && [t isEqualToString:current])) return YES;
  }
  return NO;
}

- (NSString *)ifMatchHeader
{
  NSString *condition = [self.request valueForHeader:@"If-Match"];
  return condition.length ? condition : nil;
}

#pragma mark - The writes

- (void)insert
{
  [self insertWithKey:nil];
}

- (void)insertWithKey:(NSDictionary *)key
{
  if (!self.handler.allowsInsert) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  NSAttributeDescription *media = [self.service.writer mediaAttributeOfEntity:self.entity];
  NSString *given = [self.request valueForHeader:@"Content-Type"].lowercaseString;
  if (!key && media && given.length && ![given hasPrefix:@"application/json"]) {
    [self insertMedia:self.entity media:media];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  NSEntityDescription *entity = self.entity;
  id type = body[@"@odata.type"];
  if ([type isKindOfClass:[NSString class]]) {
    NSEntityDescription *named = [self.mapper entity:entity forTypeName:type];
    if ([[self.service.writer typeNameForEntity:named] isEqualToString:ODataTypeNameFromControlInformation(type)]) {
      entity = named;
    } else {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is not a type of %@", type, [self setName]]];
      return;
    }
  }
  if (entity.isAbstract) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ is abstract: name a derived type with @odata.type", entity.name]];
    return;
  }
  [self beginWritePlan];
  NSError *error = nil;
  NSMutableArray *inputs = [NSMutableArray array];
  NSMutableDictionary *values = [self plannedValuesOfBody:body entity:entity updating:NO inputs:inputs error:&error];
  if (!values) {
    [self failPlanning:error];
    return;
  }
  // An upsert's key is the URL's.
  for (NSString *name in key) {
    id given = values[name];
    if (given && given != [NSNull null] && ![given isEqual:key[name]]) {
      NSAttributeDescription *attribute = OISRootEntity(entity).attributesByName[name];
      [self fail:400 message:[NSString stringWithFormat:@"The body's %@ is not the key the URL names",
                                                       attribute ? [self.mapper propertyForAttribute:attribute] : name]];
      return;
    }
    values[name] = key[name];
  }
  NSArray *expansion = [self expansionOfBody:body entity:entity];
  if (expansion.count) {
    ODataMutableQueryOptions *shown = [[ODataMutableQueryOptions alloc] init];
    shown.expand = expansion;
    self.responseOptions = shown;
  }
  [self planInsertOf:entity values:values inputs:inputs];
}

// An Insert into the set the request names; through a navigation property,
// related to its parent.
- (void)planInsertOf:(NSEntityDescription *)entity values:(NSMutableDictionary *)values inputs:(NSArray *)inputs
{
  OISPlanNode *insert = [OISPlanNode operator:OISPlanInsert input:nil];
  insert.entity = entity;
  insert.handler = self.handler;
  NSError *error = nil;
  if (![self planKeysOf:insert values:values entity:entity error:&error]) {
    [self failPlanning:error];
    return;
  }
  if (self.parent && self.navigation.inverseRelationship) {
    NSRelationshipDescription *inverse = self.navigation.inverseRelationship;
    values[inverse.name] = inverse.isToMany ? [NSSet setWithObject:self.parent] : self.parent;
  }
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:entity];
  if (version) values[version.name] = @1;
  insert.values = values;
  insert.inputs = inputs ?: @[];
  OISPlanNode *top = insert;
  if (self.parent && self.navigation && !self.navigation.inverseRelationship) {
    // A to-many parent whose inverse is not modelled gets the new row.
    OISPlanNode *link = [OISPlanNode operator:OISPlanLink input:nil];
    link.entity = self.parent.entity;
    link.handler = [self.service handlerForEntity:self.parent.entity];
    link.target = [self objectsNode:@[ self.parent ] entity:self.parent.entity];
    link.relationship = self.navigation;
    link.member = insert;
    top = link;
  }
  [self runWrite:top inputs:nil answer:insert then:@selector(didRunInsert)];
}

// POST a media resource to a set of media entities (Part 1 section
// 11.4.2.1): a new entity, its stream the body; its other properties are
// set after, by PATCH.
- (void)insertMedia:(NSEntityDescription *)entity media:(NSAttributeDescription *)media
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  values[media.name] = self.exchange.request.HTTPBody ?: [NSData data];
  NSAttributeDescription *type = [self.service.writer contentTypeAttributeOfStream:media];
  NSString *given = [self.request valueForHeader:@"Content-Type"];
  if (type && given.length) values[type.name] = given;
  [self beginWritePlan];
  [self planInsertOf:entity values:values inputs:nil];
}

- (void)didRunInsert
{
  NSManagedObject *object = [self resultOf:self.writeAnswer];
  NSString *location = [[self rootString] stringByAppendingString:[self canonicalPathOf:object]];
  NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{ @"Location": location, @"ETag": [self etagOf:object] }];
  if ([self.request.preferences[@"return"] isEqualToString:@"minimal"]) {
    headers[@"OData-EntityId"] = location;
    headers[@"Preference-Applied"] = @"return=minimal";
    [self respondStatus:204 headers:headers body:nil];
    return;
  }
  if ([self.request.preferences[@"return"] isEqualToString:@"representation"]) headers[@"Preference-Applied"] = @"return=representation";
  [self writeEntity:object status:201 headers:headers];
}

- (void)updateReplacing:(BOOL)replace
{
  if (!self.handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  // If-None-Match: * only creates (an upsert's); a list of ETags refuses
  // the entity in one of those versions.
  NSString *unless = [self.request valueForHeader:@"If-None-Match"];
  if (unless.length && OISConditionAllows(unless, [self etagOf:self.object])) {
    [self fail:412 message:[unless rangeOfString:@"*"].location != NSNotFound ? @"The entity exists" : @"The entity is in that version"];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  [self beginWritePlan];
  NSError *error = nil;
  NSMutableArray *inputs = [NSMutableArray array];
  NSMutableDictionary *values = [self plannedValuesOfBody:body entity:self.object.entity updating:YES inputs:inputs error:&error];
  if (!values) {
    [self failPlanning:error];
    return;
  }
  NSArray *expansion = [self expansionOfBody:body entity:self.object.entity];
  if (expansion.count) {
    ODataMutableQueryOptions *shown = [[ODataMutableQueryOptions alloc] init];
    shown.expand = expansion;
    self.responseOptions = shown;
  }
  OISPlanNode *update = [self updateOf:self.object values:values];
  update.inputs = inputs;
  update.replace = replace;
  [self runWrite:update inputs:nil answer:update then:@selector(didRunUpdate)];
}

- (OISPlanNode *)updateOf:(NSManagedObject *)object values:(NSDictionary *)values
{
  OISPlanNode *update = [OISPlanNode operator:OISPlanUpdate input:nil];
  update.entity = object.entity;
  update.handler = self.handler;
  update.target = [self objectsNode:@[ object ] entity:object.entity];
  update.values = values;
  update.ifMatch = [self ifMatchHeader];
  return update;
}

- (void)didRunUpdate
{
  NSManagedObject *object = [self resultOf:self.writeAnswer];
  NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{ @"ETag": [self etagOf:object] }];
  if ([self.request.preferences[@"return"] isEqualToString:@"representation"]) {
    headers[@"Preference-Applied"] = @"return=representation";
    [self writeEntity:object status:200 headers:headers];
    return;
  }
  [self respondStatus:204 headers:headers body:nil];
}

- (void)remove
{
  if (!self.handler.allowsDelete) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  [self beginWritePlan];
  OISPlanNode *delete = [OISPlanNode operator:OISPlanDelete input:nil];
  delete.entity = self.object.entity;
  delete.handler = self.handler;
  delete.target = [self objectsNode:@[ self.object ] entity:self.object.entity];
  delete.ifMatch = [self ifMatchHeader];
  [self runWrite:delete inputs:nil answer:nil then:@selector(didRunDelete)];
}

- (void)didRunDelete
{
  [self respondStatus:204 headers:@{} body:nil];
}

// $ref: a relationship's member added, set or taken away (Part 1 section
// 11.4.6).
- (void)writeReference
{
  NSString *method = self.request.method;
  NSManagedObject *holder = self.referencesCollection ? self.parent : self.referrer;
  NSRelationshipDescription *relationship = self.referencesCollection ? self.navigation : self.referrerNavigation;
  if (!holder || !relationship) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  ODataEntitySetHandler *handler = [self.service handlerForEntity:holder.entity];
  if (!handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  BOOL deleting = [method isEqualToString:@"DELETE"];
  if (relationship.isToMany && !(deleting || ([method isEqualToString:@"POST"] && self.referencesCollection))) {
    [self methodNotAllowed:self.referencesCollection ? @[ @"GET", @"POST", @"DELETE" ] : @[ @"GET", @"DELETE" ]];
    return;
  }
  if (!relationship.isToMany && (self.referencesCollection || [method isEqualToString:@"POST"])) {
    [self methodNotAllowed:@[ @"GET", @"PUT", @"DELETE" ]];
    return;
  }
  [self beginWritePlan];
  NSError *error = nil;
  OISPlanNode *member = nil;
  if (!deleting) {
    NSDictionary *body = [self bodyJSON];
    if (!body) return;
    member = [self lookupOfReference:body[@"@odata.id"] error:&error];
  } else if (self.referencesCollection) {
    if (!self.referenceID) {
      [self fail:400 message:@"Name the entity to remove with $id"];
      return;
    }
    member = [self lookupOfReference:self.referenceID error:&error];
  } else if (relationship.isToMany) {
    member = [self objectsNode:@[ self.object ] entity:self.object.entity];
  }
  if (error) {
    [self failPlanning:error];
    return;
  }
  OISPlanNode *link = [OISPlanNode operator:deleting ? OISPlanUnlink : OISPlanLink input:nil];
  link.entity = holder.entity;
  link.handler = handler;
  link.target = [self objectsNode:@[ holder ] entity:holder.entity];
  link.relationship = relationship;
  link.member = member;
  link.ifMatch = [self ifMatchHeader];
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:holder.entity];
  if (version) link.values = @{ version.name: @([[holder valueForKey:version.name] longLongValue] + 1) };
  self.object = holder;
  [self runWrite:link inputs:nil answer:link then:@selector(didRunUpdate)];
}

// PUT or PATCH one property ({"value": ...}, or the raw text of its
// $value), DELETE it to null (Part 1 sections 11.4.9.1-2).
- (void)writeProperty
{
  if (!self.handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  NSAttributeDescription *attribute = self.attribute;
  NSString *wire = [self.mapper propertyForAttribute:attribute];
  if ([[self.mapper keyAttributesForEntity:OISRootEntity(self.object.entity)] containsObject:attribute]) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ is the key, and cannot change", wire]];
    return;
  }
  id json = [NSNull null];
  if (![self.request.method isEqualToString:@"DELETE"]) {
    if (self.kind == OISTargetValue) {
      NSData *data = self.exchange.request.HTTPBody ?: [NSData data];
      json = attribute.attributeType == NSBinaryDataAttributeType ? (id)data : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (!json) {
        [self fail:400 message:@"The body is not text"];
        return;
      }
    } else {
      NSDictionary *body = [self bodyJSON];
      if (!body) return;
      if (!body[@"value"]) {
        [self fail:400 message:@"A property is written as {\"value\": ...}"];
        return;
      }
      json = body[@"value"];
    }
  }
  id value = json;
  if (json != [NSNull null] && ![json isKindOfClass:[NSData class]]) {
    value = [self.coder coreDataValueForJSON:json attribute:attribute];
    if (!value || value == [NSNull null]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", json, wire]];
      return;
    }
  }
  [self beginWritePlan];
  OISPlanNode *update = [self updateOf:self.object values:@{ attribute.name: value }];
  [self runWrite:update inputs:nil answer:update then:@selector(didRunUpdate)];
}

// PUT a stream: the body, as it comes, with its Content-Type; DELETE a
// stream property: none. If-Match is against the media ETag (Part 1
// section 11.4.7).
- (void)writeStream
{
  if (!self.handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  BOOL delete = [self.request.method isEqualToString:@"DELETE"];
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  values[self.attribute.name] = delete ? [NSNull null] : (self.exchange.request.HTTPBody ?: [NSData data]);
  NSAttributeDescription *type = [self.service.writer contentTypeAttributeOfStream:self.attribute];
  NSString *given = [self.request valueForHeader:@"Content-Type"];
  if (type) values[type.name] = delete || !given.length ? [NSNull null] : given;
  [self beginWritePlan];
  OISPlanNode *update = [self updateOf:self.object values:values];
  update.mediaAttribute = self.attribute;
  [self runWrite:update inputs:nil answer:update then:@selector(didRunStream)];
}

- (void)didRunStream
{
  NSManagedObject *object = [self resultOf:self.writeAnswer];
  NSData *data = [object valueForKey:self.attribute.name];
  [self respondStatus:204 headers:data ? @{ @"ETag": [self mediaEtagOf:data] } : @{} body:nil];
}

// Temporal.Update, Upsert or Delete on a timeline set (OData-Temporal
// section 4.3.2): the delta time slices of the body, over the slices the
// caller may see, all or nothing; the slices made or changed (or, for
// Delete, the periods taken away) as Temporal.TimesliceWithPeriod.
- (void)temporalAction:(NSString *)action
{
  if (![self.request.method isEqualToString:@"POST"]) {
    [self methodNotAllowed:@[ @"POST" ]];
    return;
  }
  OISTimeline *timeline = [OISTimeline timelineOfEntity:self.entity mapper:self.mapper];
  if (!timeline) {
    [self fail:404 message:[NSString stringWithFormat:@"%@ has no application time", [self setName]]];
    return;
  }
  BOOL allowed = self.handler.allowsInsert && self.handler.allowsUpdate && ([action isEqualToString:@"Delete"] ? self.handler.allowsDelete : YES);
  if (!allowed) {
    [self fail:405 message:[NSString stringWithFormat:@"%@ does not allow the changes Temporal.%@ makes", [self setName], action]];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  NSArray *deltas = [body[@"deltaTimeslices"] isKindOfClass:[NSArray class]] ? body[@"deltaTimeslices"] : nil;
  if (!deltas) {
    [self fail:400 message:@"The body has its deltaTimeslices"];
    return;
  }
  [self beginWritePlan];
  NSMutableArray *values = [NSMutableArray array];
  for (NSDictionary *delta in deltas) {
    NSDictionary *slice = [delta isKindOfClass:[NSDictionary class]] ? delta[@"Timeslice"] : nil;
    if (![slice isKindOfClass:[NSDictionary class]] || delta[@"PeriodStart"] || delta[@"PeriodEnd"]) {
      [self fail:400 message:@"Each delta time slice is a Timeslice, with its period in it (the timeline is visible)"];
      return;
    }
    NSError *error = nil;
    NSMutableArray *inputs = [NSMutableArray array];
    NSDictionary *v = [self plannedValuesOfBody:slice entity:self.entity updating:NO inputs:inputs error:&error];
    if (!v) {
      [self failPlanning:error];
      return;
    }
    if (v[OISDynamicKey]) {
      [self fail:400 message:@"A time slice takes the properties its type declares"];
      return;
    }
    for (id value in v.allValues) {
      if ([value isKindOfClass:[OISPlanMembers class]] || ([value isKindOfClass:[OISPlanNode class]] && OISIsWrite(value))) {
        [self fail:400 message:@"A time slice takes properties and binds to single entities"];
        return;
      }
    }
    [values addObject:v];
  }
  NSError *error = nil;
  OISPlanNode *slices = [self scanOfCollection:&error];
  if (!slices) {
    [self failPlanning:error];
    return;
  }
  OISPlanNode *temporal = [OISPlanNode operator:OISPlanTemporal input:slices];
  temporal.entity = self.entity;
  temporal.handler = self.handler;
  temporal.action = action;
  temporal.deltas = values;
  NSMutableDictionary *sequences = [NSMutableDictionary dictionary];
  NSEntityDescription *root = OISRootEntity(self.entity);
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:root]) {
    if (OISIsIntegerAttribute(attribute)) sequences[attribute.name] = [self sequenceOf:attribute entity:root];
  }
  temporal.sequences = sequences;
  [self runWrite:temporal inputs:nil answer:nil then:@selector(didRunTemporal)];
}

- (void)didRunTemporal
{
  if ([self.request.preferences[@"return"] isEqualToString:@"minimal"]) {
    [self respondStatus:204 headers:@{ @"Preference-Applied": @"return=minimal" } body:nil];
    return;
  }
  // The slices' expansions read first.
  OISTimelineChanges *changes = self.planMemo[OISWriteKey(@"t", self.plan.write.input)];
  self.timeslices = changes.results;
  NSMutableArray *objects = [NSMutableArray array];
  for (OISTimeslice *result in changes.results) if (result.object) [objects addObject:result.object];
  [self runPlan:[self planOfObjects:objects options:self.request.options entity:self.entity] then:@selector(didExpandTimeslices)];
}

#pragma mark Collections

// PATCH of a collection (Part 1 section 11.4.12): a delta payload, its
// entities upserted, its removed ones deleted (from a navigation property's
// collection, unlinked unless removed as "deleted").
- (void)updateCollection
{
  if (![self collectionIsWritable]) return;
  if (self.pathFilters.count || self.entity != self.handler.entity) {
    [self fail:400 message:@"A collection updated with a delta payload is not cast or filtered"];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  NSArray *changes = [body[@"value"] isKindOfClass:[NSArray class]] ? body[@"value"] : nil;
  if (!changes) {
    [self fail:400 message:@"A delta payload has its value"];
    return;
  }
  [self beginWritePlan];
  NSError *error = nil;
  NSMutableArray *inputs = [NSMutableArray array];
  OISPlanMembers *members = [self plannedDelta:changes within:self.entity name:[self setName]
                                 removesDelete:!self.parent inputs:inputs error:&error];
  if (!members) {
    [self failPlanning:error];
    return;
  }
  OISPlanNode *top = nil;
  if (self.parent) {
    top = [self updateOf:self.parent values:@{ self.navigation.name: members }];
    top.handler = [self.service handlerForEntity:self.parent.entity];
    top.ifMatch = nil;
    top.inputs = inputs;
  }
  NSMutableArray *writes = [NSMutableArray arrayWithArray:members.nodes];
  if (!top) [writes addObjectsFromArray:inputs];
  [self runWrite:top inputs:writes answer:nil then:@selector(didWriteCollection)];
}

// PUT of a collection (section 11.4.12): its entities upserted, and those
// not among them deleted.
- (void)replaceCollection
{
  if (![self collectionIsWritable]) return;
  if (!self.handler.allowsDelete) {
    [self methodNotAllowed:@[ @"GET", @"POST", @"PATCH" ]];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  NSArray *entities = [body[@"value"] isKindOfClass:[NSArray class]] ? body[@"value"] : nil;
  if (!entities) {
    [self fail:400 message:@"A collection is written as {\"value\": [...]}"];
    return;
  }
  [self beginWritePlan];
  NSError *error = nil;
  NSMutableArray *merges = [NSMutableArray array], *kept = [NSMutableArray array];
  for (id entity in entities) {
    OISPlanNode *merge = [self plannedMergeOfBody:entity within:self.entity name:[self setName] error:&error];
    if (!merge) {
      [self failPlanning:error];
      return;
    }
    [merges addObject:merge];
    if (merge.op == OISPlanMerge) [kept addObject:merge.input];
  }
  OISPlanNode *scan = [self scanOfCollection:&error];
  if (!scan) {
    [self failPlanning:error];
    return;
  }
  OISPlanNode *delete = [OISPlanNode operator:OISPlanDelete input:nil];
  delete.entity = self.entity;
  delete.handler = self.handler;
  delete.target = scan;
  delete.except = kept;
  OISPlanNode *top = nil;
  if (self.parent) {
    top = [self updateOf:self.parent values:@{ self.navigation.name: [OISPlanMembers membersOf:merges removing:@[] adding:NO] }];
    top.handler = [self.service handlerForEntity:self.parent.entity];
    top.ifMatch = nil;
  }
  self.writeAnswers = merges;
  NSMutableArray *writes = [NSMutableArray arrayWithObject:delete];
  if (!top) [writes addObjectsFromArray:merges];
  [self runWrite:top inputs:writes answer:nil then:@selector(didWriteCollection)];
}

// PATCH Collection/$each (section 11.4.13): each member updated alike.
- (void)updateEach
{
  if (!self.handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"DELETE" ]];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  [self beginWritePlan];
  NSError *error = nil;
  NSMutableArray *inputs = [NSMutableArray array];
  NSMutableDictionary *values = [self plannedValuesOfBody:body entity:self.entity updating:YES inputs:inputs error:&error];
  if (!values) {
    [self failPlanning:error];
    return;
  }
  for (id value in values.allValues) {
    BOOL nested = [value isKindOfClass:[OISPlanNode class]] && OISIsWrite(value);
    for (id node in [value isKindOfClass:[OISPlanMembers class]] ? [value nodes] : @[]) nested = nested || ([node isKindOfClass:[OISPlanNode class]] && OISIsWrite(node));
    if (nested || inputs.count) {
      [self fail:501 message:@"Nested entities in an update of each member are not supported: bind them"];
      return;
    }
  }
  OISPlanNode *scan = [self scanOfCollection:&error];
  if (!scan) {
    [self failPlanning:error];
    return;
  }
  OISPlanNode *update = [OISPlanNode operator:OISPlanUpdate input:nil];
  update.entity = self.entity;
  update.handler = self.handler;
  update.target = scan;
  update.values = values;
  self.writeAnswers = @[ update ];
  [self runWrite:update inputs:nil answer:update then:@selector(didWriteCollection)];
}

// DELETE Collection/$each (section 11.4.14): each member deleted.
- (void)removeEach
{
  if (!self.handler.allowsDelete) {
    [self methodNotAllowed:@[ @"PATCH" ]];
    return;
  }
  [self beginWritePlan];
  NSError *error = nil;
  OISPlanNode *scan = [self scanOfCollection:&error];
  if (!scan) {
    [self failPlanning:error];
    return;
  }
  OISPlanNode *delete = [OISPlanNode operator:OISPlanDelete input:nil];
  delete.entity = self.entity;
  delete.handler = self.handler;
  delete.target = scan;
  self.writeAnswers = @[ @{ @"node": delete, @"reason": @"deleted" } ];
  [self runWrite:delete inputs:nil answer:nil then:@selector(didWriteCollection)];
}

// Each change is allowed or not as it is planned and checked: this is
// whether the collection can be written at all.
- (BOOL)collectionIsWritable
{
  if (self.handler.allowsUpdate) return YES;
  [self methodNotAllowed:self.handler.allowsInsert ? @[ @"GET", @"POST" ] : @[ @"GET" ]];
  return NO;
}

// A collection's write answered: nothing, unless return=representation;
// then the rows as they are now (for $each's PATCH and a PUT), or a delta
// payload of the changes, in the order the request gave them.
- (void)didWriteCollection
{
  if (![self.request.preferences[@"return"] isEqualToString:@"representation"]) {
    [self respondStatus:204 headers:@{} body:nil];
    return;
  }
  // What the write did, before the read of it replaces the plan.
  NSMutableArray *entries = [NSMutableArray array], *objects = [NSMutableArray array];
  for (id answer in self.writeAnswers) {
    if ([answer isKindOfClass:[NSDictionary class]]) {
      for (NSDictionary *removed in self.planMemo[OISWriteKey(@"p", answer[@"node"])]) {
        NSMutableDictionary *entry = [[self removedEntry:removed[@"path"] reason:answer[@"reason"]] mutableCopy];
        if (![self.request.version isEqualToString:@"4.0"]) [entry addEntriesFromDictionary:removed[@"keys"]];
        [entries addObject:entry];
      }
      continue;
    }
    NSArray *rows = [self rowsWrittenBy:answer];
    [entries addObjectsFromArray:rows];
    [objects addObjectsFromArray:rows];
  }
  self.writeAnswers = entries;
  [self runPlan:[self planOfObjects:objects options:self.request.options entity:self.entity] then:@selector(didExpandWrittenCollection)];
}

- (void)didExpandWrittenCollection
{
  NSError *error = nil;
  BOOL delta = ([self.request.method isEqualToString:@"PATCH"] && self.kind != OISTargetEach) || [self.request.method isEqualToString:@"DELETE"];
  NSMutableArray *values = [NSMutableArray array];
  for (id entry in self.writeAnswers) {
    if ([entry isKindOfClass:[NSDictionary class]]) {
      [values addObject:entry];
      continue;
    }
    NSMutableDictionary *json = [self JSONForObject:entry options:self.request.options expected:self.entity error:&error];
    if (!json) {
      [self respondError:error];
      return;
    }
    [values addObject:json];
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) {
    body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@%@%@%@", [self contextBase], [self setName], [self castSuffixFor:self.entity],
                                                         [self selectListForOptions:self.request.options], delta ? @"/$delta" : @""];
  }
  body[@"value"] = values;
  [self respondJSON:body status:200 headers:@{ @"Preference-Applied": @"return=representation" }];
}

// An operation: the entities its parameters name, read; then the call,
// which is the operation's own code, and what it answers with read as any
// response is.
- (void)readLookups:(NSArray<OISPlanNode *> *)lookups call:(NSString *)signature then:(SEL)after
{
  OISPlan *plan = [self beginWritePlan];
  OISPlanNode *call = [OISPlanNode operator:OISPlanCall input:nil];
  call.reference = signature;
  call.inputs = lookups;
  plan.write = call;
  self.writeRequestEntity = self.request.entity;
  [self runPlan:plan then:after];
}

#pragma mark - Running

// From the top: what is known is not asked again, what is written is not
// written again.
- (void)resumeWrite
{
  if (self.done) return;
  self.planPending = NO;
  self.request.entity = self.writeRequestEntity;
  OISPlanNode *write = self.plan.write;
  if (![self readFor:write]) return;
  if (!self.planMemo[@"checked"]) {
    if (![self checkFor:write]) return;
    self.planMemo[@"checked"] = @YES;
  }
  if (![self writeFor:write]) return;
  if (self.done) return;
  self.request.entity = self.writeRequestEntity;
  SEL after = self.planAfter;
  self.planAfter = NULL;
  if (!after) return;
  void (*send)(id, SEL) = (void (*)(id, SEL))[self methodForSelector:after];
  send(self, after);
}

// The nodes a node reads or writes from, in order; a Merge's, only the
// branch it takes.
- (NSArray<OISPlanNode *> *)childrenOf:(OISPlanNode *)node
{
  NSMutableArray *children = [NSMutableArray array];
  if (node.op == OISPlanMerge) {
    if (node.input) [children addObject:node.input];
    return children;
  }
  for (NSString *name in [node.sequences.allKeys sortedArrayUsingSelector:@selector(compare:)]) [children addObject:node.sequences[name]];
  NSMutableArray *valueSets = [NSMutableArray arrayWithObject:node.values];
  if (node.deltas) [valueSets addObjectsFromArray:node.deltas];
  for (NSDictionary *values in valueSets) {
    for (NSString *name in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      id value = values[name];
      if ([value isKindOfClass:[OISPlanNode class]]) [children addObject:value];
      if ([value isKindOfClass:[OISPlanMembers class]]) {
        for (id member in [value nodes]) if ([member isKindOfClass:[OISPlanNode class]]) [children addObject:member];
        for (id member in [value removes]) if ([member isKindOfClass:[OISPlanNode class]]) [children addObject:member];
      }
    }
  }
  [children addObjectsFromArray:node.inputs];
  [children addObjectsFromArray:node.except];
  if (node.target) [children addObject:node.target];
  if (node.member) [children addObject:node.member];
  if (node.input) [children addObject:node.input];
  return children;
}

// A Merge's branch: an Update of the row it found, else an Insert.
- (OISPlanNode *)chosenOf:(OISPlanNode *)merge
{
  id found = merge.input ? self.planMemo[OISWriteKey(@"o", merge.input)] : nil;
  return found && found != [NSNull null] ? merge.matched : merge.otherwise;
}

#pragma mark Permissions

// What a node writes: an Insert into its set, an Update, Delete, Link or
// Unlink of its target's (a Link or Unlink changes the row whose
// navigation property it is). Lookups and scans are what the write
// changes, or refers to, not reads of their own.
- (void)addWritesOf:(OISPlanNode *)node into:(NSMutableDictionary *)permissions seen:(NSHashTable *)seen
{
  if (!node || [seen containsObject:node]) return;
  [seen addObject:node];
  switch (node.op) {
    case OISPlanInsert: [self need:OISAccessInsert entity:node.entity into:permissions]; break;
    case OISPlanUpdate:
    case OISPlanLink:
    case OISPlanUnlink: [self need:OISAccessUpdate entity:node.target.entity ?: node.entity into:permissions]; break;
    case OISPlanDelete: [self need:OISAccessDelete entity:node.target.entity ?: node.entity into:permissions]; break;
    default: break;
  }
  for (OISPlanNode *child in [self childrenOf:node]) [self addWritesOf:child into:permissions seen:seen];
}

- (void)addWritesOf:(OISPlanNode *)node into:(NSMutableDictionary *)permissions
{
  [self addWritesOf:node into:permissions seen:[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]];
}

#pragma mark Reads

- (BOOL)readFor:(OISPlanNode *)node
{
  if (!node) return YES;
  switch (node.op) {
    case OISPlanLookup: return [self foundBy:node] != nil;
    case OISPlanSequence: return [self largestOf:node] != nil;
    case OISPlanStoreScan: return [self relationOf:node scope:nil input:nil] != nil;
    default: break;
  }
  for (OISPlanNode *child in [self childrenOf:node]) {
    if (![self readFor:child]) return NO;
  }
  if (node.op == OISPlanMerge) return [self readFor:[self chosenOf:node]];
  return YES;
}

// A Lookup's row: the object, or NSNull for none; nil until it is known,
// or when there must be one and there is none (answered: 400).
- (id)foundBy:(OISPlanNode *)lookup
{
  NSString *foundKey = OISWriteKey(@"o", lookup);
  id found = self.planMemo[foundKey];
  if (found) return found;
  NSMutableArray *conditions = [NSMutableArray array];
  for (NSString *name in lookup.key) {
    [conditions addObject:[NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:name]
                                                             rightExpression:[NSExpression expressionForConstantValue:lookup.key[name]]
                                                                    modifier:NSDirectPredicateModifier
                                                                        type:NSEqualToPredicateOperatorType
                                                                     options:0]];
  }
  ODataEntitySetHandler *handler = lookup.handler;
  NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
  if (visible) [conditions addObject:visible];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:OISRootEntity(lookup.entity).name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:conditions];
  fetch.fetchLimit = 1;
  NSArray *rows = [self answerFor:OISWriteKey(@"r", lookup) ask:OISAskObjects fetch:fetch handler:handler];
  if (!rows) return nil;
  found = [rows isKindOfClass:[NSArray class]] ? [rows firstObject] : nil;
  if (!found && !lookup.optional) {
    [self fail:400 message:[NSString stringWithFormat:@"There is no %@", lookup.reference]];
    return nil;
  }
  self.planMemo[foundKey] = found ?: [NSNull null];
  return self.planMemo[foundKey];
}

// A Sequence's row: the one with the largest key, of all rows (not only
// those the caller may see: a key is unique among them all).
- (NSArray *)largestOf:(OISPlanNode *)sequence
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:sequence.entity.name];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:sequence.attributeName ascending:NO] ];
  fetch.fetchLimit = 1;
  return [self answerFor:OISWriteKey(@"r", sequence) ask:OISAskObjects fetch:fetch handler:sequence.handler];
}

- (NSNumber *)nextKeyOf:(OISPlanNode *)sequence
{
  NSString *name = [NSString stringWithFormat:@"%@.%@", sequence.entity.name, sequence.attributeName];
  NSMutableDictionary *counters = self.planMemo[@"counters"];
  if (!counters) {
    counters = [NSMutableDictionary dictionary];
    self.planMemo[@"counters"] = counters;
  }
  NSNumber *last = counters[name];
  if (!last) {
    NSArray *rows = self.planMemo[OISWriteKey(@"r", sequence)];
    long long largest = [[[rows firstObject] valueForKey:sequence.attributeName] longLongValue];
    last = @(MAX(largest, [self.plan.givenKeys[name] longLongValue]));
  }
  NSNumber *next = @(last.longLongValue + 1);
  counters[name] = next;
  return next;
}

// The rows a node stands for, once read (or written).
- (NSArray *)rowsOf:(OISPlanNode *)node
{
  switch (node.op) {
    case OISPlanObjects: return node.objects ?: @[];
    case OISPlanLookup: {
      id found = self.planMemo[OISWriteKey(@"o", node)];
      return found && found != [NSNull null] ? @[ found ] : @[];
    }
    case OISPlanStoreScan: return [self relationOf:node scope:nil input:nil].rows ?: @[];
    default: return [self rowsWrittenBy:node];
  }
}

// What a write made or changed.
- (NSArray *)rowsWrittenBy:(OISPlanNode *)node
{
  if (node.op == OISPlanMerge) {
    OISPlanNode *chosen = [self chosenOf:node];
    return chosen ? [self rowsWrittenBy:chosen] : @[];
  }
  id written = self.planMemo[OISWriteKey(@"w", node)];
  if ([written isKindOfClass:[NSArray class]]) return written;
  return [written isKindOfClass:[NSManagedObject class]] ? @[ written ] : @[];
}

- (id)resultOf:(OISPlanNode *)node
{
  return [[self rowsOf:node] firstObject];
}

#pragma mark Checks

// Every check, before anything is written: NO once one has failed
// (answered).
- (BOOL)checkFor:(OISPlanNode *)node
{
  if (!node) return YES;
  NSString *key = OISWriteKey(@"c", node);
  if (self.planMemo[key]) return YES;
  self.planMemo[key] = @YES;
  if (node.failure) {
    [self respondError:node.failure];
    return NO;
  }
  if (node.op == OISPlanMerge) return [self checkFor:[self chosenOf:node]];
  for (OISPlanNode *child in [self childrenOf:node]) {
    if (![self checkFor:child]) return NO;
  }
  NSError *error = nil;
  switch (node.op) {
    case OISPlanLookup: {
      id found = self.planMemo[OISWriteKey(@"o", node)];
      if (found && found != [NSNull null]) self.planMemo[OISWriteKey(@"p", node)] = @[ [self removedOf:found] ];
      return YES;
    }
    case OISPlanInsert: {
      if (![self permitsTo:OISAccessInsert entity:node.entity]) return NO;
      NSMutableDictionary *keys = [NSMutableDictionary dictionary];
      for (NSString *name in node.sequences) keys[name] = [self nextKeyOf:node.sequences[name]];
      self.planMemo[OISWriteKey(@"k", node)] = keys;
      return YES;
    }
    case OISPlanUpdate: {
      NSMutableArray *all = [NSMutableArray array];
      for (NSManagedObject *object in [self rowsOf:node.target]) {
        if (![self allows:node object:object]) return NO;
        NSDictionary *values = [self updateValuesOf:node object:object error:&error];
        if (!values) {
          [self respondError:error];
          return NO;
        }
        if (values.count && ![(ODataEntitySetHandler *)node.handler allowsUpdate]) {
          [self fail:405 message:[NSString stringWithFormat:@"%@ cannot be updated here", object.entity.name]];
          return NO;
        }
        // Anything it changes, named or dynamic properties alike.
        if (values.count && ![self permitsTo:OISAccessUpdate entity:object.entity]) return NO;
        [all addObject:values];
      }
      self.planMemo[OISWriteKey(@"v", node)] = all;
      return YES;
    }
    case OISPlanDelete: {
      NSMutableSet *kept = [NSMutableSet set];
      for (OISPlanNode *except in node.except) [kept addObjectsFromArray:[self rowsOf:except]];
      NSMutableArray *objects = [NSMutableArray array], *paths = [NSMutableArray array];
      for (NSManagedObject *object in [self rowsOf:node.target]) {
        if ([kept containsObject:object]) continue;
        if (![self allows:node object:object]) return NO;
        if (![self permitsTo:OISAccessDelete entity:object.entity]) return NO;
        [objects addObject:object];
        [paths addObject:[self removedOf:object]];
      }
      self.planMemo[OISWriteKey(@"d", node)] = objects;
      self.planMemo[OISWriteKey(@"p", node)] = paths;
      return YES;
    }
    case OISPlanLink:
    case OISPlanUnlink: {
      NSManagedObject *holder = [self resultOf:node.target];
      if (![self allows:node object:holder]) return NO;
      if (![self permitsTo:OISAccessUpdate entity:holder.entity ?: node.target.entity]) return NO;
      if (!node.member || OISIsWrite(node.member)) return YES;
      NSManagedObject *member = [self resultOf:node.member];
      if (member && ![member.entity isKindOfEntity:node.relationship.destinationEntity]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ does not refer to a %@", [self.mapper propertyForRelationship:node.relationship], member.entity.name]];
        return NO;
      }
      if (node.op == OISPlanUnlink && node.relationship.isToMany && ![[holder valueForKey:node.relationship.name] containsObject:member]) {
        [self fail:404 message:@"The entity is not in the collection"];
        return NO;
      }
      return YES;
    }
    case OISPlanTemporal: return [self checkTemporal:node];
    default: return YES;
  }
}

// What a removed entry says of a row, worked out before it is written:
// its path, and (in 4.01) its key and type, so a client knows which of its
// objects it was.
- (NSDictionary *)removedOf:(NSManagedObject *)object
{
  NSMutableDictionary *keys = [NSMutableDictionary dictionary];
  NSEntityDescription *root = OISRootEntity(object.entity);
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:root]) {
    keys[[self.mapper propertyForAttribute:attribute]] = [self.coder JSONForCoreDataValue:[object valueForKey:attribute.name] attribute:attribute];
  }
  if (object.entity != root) keys[@"@odata.type"] = [@"#" stringByAppendingString:[self.service.writer typeNameForEntity:object.entity]];
  return @{ @"path": [self canonicalPathOf:object], @"keys": keys };
}

// If-Match, a nested entity's ETag and type: NO, answered, when the row
// is not the one the request was written for.
- (BOOL)allows:(OISPlanNode *)node object:(NSManagedObject *)object
{
  if (node.ifMatch) {
    if (node.mediaAttribute) {
      NSData *current = [object valueForKey:node.mediaAttribute.name];
      if (!OISConditionAllows(node.ifMatch, current ? [self mediaEtagOf:current] : nil)) {
        [self fail:412 message:@"The stream has changed since that ETag"];
        return NO;
      }
    } else if (!OISConditionAllows(node.ifMatch, [self etagOf:object])) {
      [self fail:412 message:@"The entity has changed since that ETag"];
      return NO;
    }
  }
  if (node.etag && ![node.etag isEqualToString:[self etagOf:object]]) {
    [self fail:412 message:[NSString stringWithFormat:@"%@ has changed since that ETag", [self canonicalPathOf:object]]];
    return NO;
  }
  if (node.typed && object.entity != node.entity) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ is a %@", [self canonicalPathOf:object], object.entity.name]];
    return NO;
  }
  return YES;
}

// An Update's values for a row: the key as it is; what is immutable as it
// is; for PUT the rest back to its default; the version one more when
// anything changes. Nodes and members stay, for the write.
- (NSDictionary *)updateValuesOf:(OISPlanNode *)update object:(NSManagedObject *)object error:(NSError **)error
{
  NSEntityDescription *entity = object.entity;
  NSArray *key = [self.mapper keyAttributesForEntity:OISRootEntity(entity)];
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *name in update.values) {
    id value = update.values[name];
    NSAttributeDescription *attribute = entity.attributesByName[name];
    if (!attribute) {
      values[name] = value;
      continue;
    }
    id current = [object valueForKey:name];
    if ([key containsObject:attribute]) {
      if (value != [NSNull null] && ![value isEqual:current]) {
        return OISFailed(error, 400, [NSString stringWithFormat:@"%@ is the key, and cannot change", [self.mapper propertyForAttribute:attribute]]);
      }
      continue;
    }
    // Core.Immutable: set when the entity is made, and not after.
    if ([self.service isImmutableAttribute:attribute]) {
      if (value == [NSNull null] ? current != nil : ![value isEqual:current]) {
        return OISFailed(error, 400, [NSString stringWithFormat:@"%@ cannot change", [self.mapper propertyForAttribute:attribute]]);
      }
      if (value != [NSNull null]) continue;
    }
    values[name] = value;
  }
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:entity];
  // A PUT replaces an open type's dynamic properties too: with none, when
  // the body gives none.
  if (update.replace && !values[OISDynamicKey] && [self.service handlerForEntity:entity].isOpenType) values[OISDynamicKey] = @{};
  if (update.replace) {
    // PUT: what the body leaves out goes back to its default.
    for (NSAttributeDescription *attribute in [self servedAttributesOf:entity]) {
      if ([key containsObject:attribute] || attribute == version || values[attribute.name]) continue;
      if ([self.service.writer isStreamAttribute:attribute]) continue;  // not in a body, so not left out of one
      if ([self.service isComputedAttribute:attribute] || [self.service isImmutableAttribute:attribute]) continue;
      values[attribute.name] = attribute.defaultValue ?: [NSNull null];
    }
  }
  if (values.count && version) values[version.name] = @([[object valueForKey:version.name] longLongValue] + 1);
  return values;
}

// A Temporal action's changes, worked out over the slices it read, with
// the keys of the slices it makes.
- (BOOL)checkTemporal:(OISPlanNode *)node
{
  OISTimeline *timeline = [OISTimeline timelineOfEntity:node.entity mapper:self.mapper];
  NSMutableArray *deltas = [NSMutableArray array];
  for (NSDictionary *delta in node.deltas) [deltas addObject:[self rowsIn:delta object:nil]];
  NSError *error = nil;
  OISTimelineChanges *changes = [timeline changesOf:node.action deltas:deltas candidates:[self rowsOf:node.input] error:&error];
  if (!changes) {
    [self respondError:error ?: ODataServiceError(400, @"The time slices could not be changed")];
    return NO;
  }
  // Each slice made, changed or closed needs its permission.
  for (OISSliceRecord *record in changes.records) {
    NSEntityDescription *entity = record.entity ?: record.object.entity;
    OISAccess access = record.isNew ? OISAccessInsert : record.isDeleted ? OISAccessDelete : OISAccessUpdate;
    if (![self permitsTo:access entity:entity]) return NO;
  }
  for (OISSliceRecord *record in changes.records) {
    NSAttributeDescription *version = [self.service versionAttributeOfEntity:record.entity];
    if (record.isNew) {
      for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(record.entity)]) {
        if (record.values[attribute.name]) continue;
        if (node.sequences[attribute.name]) record.values[attribute.name] = [self nextKeyOf:node.sequences[attribute.name]];
        else if (attribute.attributeType == NSStringAttributeType) record.values[attribute.name] = [NSUUID UUID].UUIDString;
        else if (attribute.attributeType == NSUUIDAttributeType) record.values[attribute.name] = [NSUUID UUID];
        else {
          [self fail:400 message:[NSString stringWithFormat:@"A new %@ has no key", record.entity.name]];
          return NO;
        }
      }
      if (version) record.values[version.name] = @1;
    } else if (!record.isDeleted && version) {
      // Its version moves on once, however often the action changes it.
      record.changes[version.name] = @([[record.object valueForKey:version.name] longLongValue] + 1);
    }
  }
  self.planMemo[OISWriteKey(@"t", node)] = changes;
  return YES;
}

#pragma mark Writes

// Values with the rows of their nodes in: a Lookup's, what a write made,
// members as a set.
- (NSDictionary *)rowsIn:(NSDictionary *)values object:(NSManagedObject *)object
{
  NSMutableDictionary *resolved = [NSMutableDictionary dictionary];
  for (NSString *name in values) {
    id value = values[name];
    if ([name isEqualToString:OISDynamicKey]) continue;  // the commit's
    if ([value isKindOfClass:[OISPlanNode class]]) {
      resolved[name] = [self resultOf:value] ?: [NSNull null];
    } else if ([value isKindOfClass:[OISPlanMembers class]]) {
      OISPlanMembers *members = value;
      NSMutableSet *set = members.adds && object ? [[object valueForKey:name] mutableCopy] ?: [NSMutableSet set] : [NSMutableSet set];
      for (id member in members.nodes) {
        if ([member isKindOfClass:[OISPlanNode class]]) [set addObjectsFromArray:[self rowsOf:member]];
        else [set addObject:member];
      }
      for (id member in members.removes) {
        if ([member isKindOfClass:[OISPlanNode class]]) {
          for (id row in [self rowsOf:member]) [set removeObject:row];
        } else {
          [set removeObject:member];
        }
      }
      resolved[name] = set;
    } else {
      resolved[name] = value;
    }
  }
  return resolved;
}

// A handler asked to write: its answer, kept; nil until it comes (or once
// it failed).
- (id)ask:(NSString *)key node:(OISPlanNode *)node entity:(NSEntityDescription *)entity
     call:(id (^)(ODataEntitySetHandler *handler, ODataReply *reply))call
{
  id known = self.planMemo[key];
  if (known) return known;
  if (self.planPending || self.done) return nil;
  self.planPendingKey = key;
  NSEntityDescription *requested = self.request.entity;
  // The handler has the request's entity until it answers.
  self.request.entity = entity;
  ODataEntitySetHandler *handler = node.handler ?: self.handler;
  [self beginStoreRequest:@"write" entity:entity.name handler:handler];
  OTSpan *span = self.storeSpan;
  ODataReply *reply = [self replyWithAction:@selector(planDidReply:)];
  [reply returned:call(handler, reply)];
  [span resignCurrent];
  known = self.planMemo[key];
  if (known) {
    self.request.entity = requested;
    return known;
  }
  if (!self.done) {
    self.planPending = YES;
    self.planWaiting = YES;
  }
  return nil;
}

- (NSManagedObject *)objectAnswered:(id)answer what:(NSString *)what entity:(NSEntityDescription *)entity
{
  if ([answer isKindOfClass:[NSManagedObject class]]) return answer;
  [self.request.context rollback];
  [self respondError:ODataServiceError(500, [NSString stringWithFormat:@"The %@ was not %@", entity.name, what])];
  return nil;
}

// Each write's dynamic properties, as the writes went: those under node.
- (void)collectDynamicUnder:(OISPlanNode *)node into:(NSMutableArray *)pairs seen:(NSHashTable *)seen
{
  if (!node || [seen containsObject:node]) return;
  [seen addObject:node];
  if (node.op == OISPlanMerge) [self collectDynamicUnder:[self chosenOf:node] into:pairs seen:seen];
  for (OISPlanNode *child in [self childrenOf:node]) [self collectDynamicUnder:child into:pairs seen:seen];
  NSArray *mine = self.planMemo[OISWriteKey(@"y", node)];
  if (mine) [pairs addObjectsFromArray:mine];
}

// The dynamic properties the write gives, asked of each open type's
// handler at once. NO until each has answered (or once one failed).
- (BOOL)writeDynamicPropertiesUnder:(OISPlanNode *)commit
{
  NSMutableArray *pairs = [NSMutableArray array];
  [self collectDynamicUnder:commit into:pairs seen:[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]];
  NSMutableDictionary *bySet = [NSMutableDictionary dictionary];
  NSMutableArray *sets = [NSMutableArray array];
  for (NSArray *pair in pairs) {
    NSManagedObject *object = pair[0];
    NSString *set = [self.service entitySetForEntity:OISRootEntity(object.entity)];
    if (!bySet[set]) {
      bySet[set] = @[ [NSMutableArray array], [NSMutableArray array] ];
      [sets addObject:set];
    }
    [bySet[set][0] addObject:object];
    [bySet[set][1] addObject:pair[1]];
  }
  for (NSString *set in sets) {
    NSArray *objects = bySet[set][0], *values = bySet[set][1];
    NSManagedObject *first = objects.firstObject;
    OISPlanNode *asking = [OISPlanNode operator:OISPlanCommit input:nil];
    asking.handler = [self.service handlerForEntitySet:set];
    id answer = [self ask:[@"dynamic/" stringByAppendingString:set] node:asking entity:OISRootEntity(first.entity)
                     call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
                       return [handler writeDynamicProperties:values ofObjects:objects request:self.request reply:reply];
                     }];
    if (!answer) return NO;
  }
  return YES;
}

// The writes, those a write depends on first: its rows, once written; nil
// until the handlers have answered (or once one failed).
- (id)writeFor:(OISPlanNode *)node
{
  NSString *key = OISWriteKey(@"w", node);
  id written = self.planMemo[key];
  if (written) return written;
  if (node.op == OISPlanMerge) {
    OISPlanNode *chosen = [self chosenOf:node];
    return chosen ? [self writeFor:chosen] : @[];
  }
  if (!OISIsWrite(node)) return @YES;
  for (OISPlanNode *child in [self childrenOf:node]) {
    if (OISIsWrite(child) && ![self writeFor:child]) return nil;
  }
  switch (node.op) {
    case OISPlanInsert: {
      NSMutableDictionary *values = [[self rowsIn:node.values object:nil] mutableCopy];
      [values addEntriesFromDictionary:self.planMemo[OISWriteKey(@"k", node)]];
      id made = [self ask:[key stringByAppendingString:@"/ask"] node:node entity:node.entity call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
        return [handler insertObjectWithValues:values request:self.request reply:reply];
      }];
      if (!made) return nil;
      written = [self objectAnswered:made what:@"created" entity:node.entity];
      if (!written) return nil;
      if (node.values[OISDynamicKey]) self.planMemo[OISWriteKey(@"y", node)] = @[ @[ written, node.values[OISDynamicKey] ] ];
      break;
    }
    case OISPlanUpdate: {
      NSArray *objects = [self rowsOf:node.target];
      NSArray *all = self.planMemo[OISWriteKey(@"v", node)];
      NSMutableArray *rows = [NSMutableArray array];
      NSMutableArray *dynamic = [NSMutableArray array];
      for (NSUInteger i = 0; i < objects.count; i++) {
        NSManagedObject *object = objects[i];
        NSDictionary *values = [self rowsIn:all[i] object:object];
        if (all[i][OISDynamicKey]) [dynamic addObject:@[ object, all[i][OISDynamicKey] ]];
        if (!values.count) {
          [rows addObject:object];  // only named, or only dynamic properties: not changed here
          continue;
        }
        NSString *asked = [NSString stringWithFormat:@"%@/%lu", key, (unsigned long)i];
        id changed = [self ask:asked node:node entity:object.entity call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
          return [handler updateObject:object values:values request:self.request reply:reply];
        }];
        if (!changed) return nil;
        NSManagedObject *row = [self objectAnswered:changed what:@"updated" entity:object.entity];
        if (!row) return nil;
        [rows addObject:row];
      }
      written = rows;
      if (dynamic.count) self.planMemo[OISWriteKey(@"y", node)] = dynamic;
      break;
    }
    case OISPlanDelete: {
      NSArray *objects = self.planMemo[OISWriteKey(@"d", node)];
      for (NSUInteger i = 0; i < objects.count; i++) {
        NSManagedObject *object = objects[i];
        NSString *asked = [NSString stringWithFormat:@"%@/%lu", key, (unsigned long)i];
        if (![self ask:asked node:node entity:object.entity call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
              [handler deleteObject:object request:self.request reply:reply];
              return nil;
            }]) {
          return nil;
        }
      }
      written = @[];
      break;
    }
    case OISPlanLink:
    case OISPlanUnlink: {
      NSManagedObject *holder = [self resultOf:node.target];
      NSRelationshipDescription *relationship = node.relationship;
      NSManagedObject *member = node.member ? [self resultOf:node.member] : nil;
      NSMutableDictionary *values = [NSMutableDictionary dictionaryWithDictionary:node.values];
      if (relationship.isToMany) {
        NSMutableSet *members = [[holder valueForKey:relationship.name] mutableCopy] ?: [NSMutableSet set];
        if (node.op == OISPlanLink) [members addObject:member];
        else [members removeObject:member];
        values[relationship.name] = members;
      } else {
        values[relationship.name] = node.op == OISPlanLink && member ? member : [NSNull null];
      }
      id changed = [self ask:[key stringByAppendingString:@"/ask"] node:node entity:holder.entity call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
        return [handler updateObject:holder values:values request:self.request reply:reply];
      }];
      if (!changed) return nil;
      written = [self objectAnswered:changed what:@"updated" entity:holder.entity];
      if (!written) return nil;
      break;
    }
    case OISPlanTemporal: {
      OISTimelineChanges *changes = self.planMemo[OISWriteKey(@"t", node)];
      for (NSUInteger i = 0; i < changes.records.count; i++) {
        OISSliceRecord *record = changes.records[i];
        NSString *asked = [NSString stringWithFormat:@"%@/%lu", key, (unsigned long)i];
        id answer;
        if (record.isNew) {
          NSDictionary *values = [record.values copy];
          answer = [self ask:asked node:node entity:record.entity call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
            return [handler insertObjectWithValues:values request:self.request reply:reply];
          }];
          if (!answer) return nil;
          record.object = [self objectAnswered:answer what:@"created" entity:record.entity];
          if (!record.object) return nil;
        } else if (record.isDeleted) {
          NSManagedObject *slice = record.object;
          answer = [self ask:asked node:node entity:slice.entity call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
            [handler deleteObject:slice request:self.request reply:reply];
            return nil;
          }];
          if (!answer) return nil;
        } else {
          NSManagedObject *slice = record.object;
          NSDictionary *values = [record.changes copy];
          answer = [self ask:asked node:node entity:slice.entity call:^id(ODataEntitySetHandler *handler, ODataReply *reply) {
            return [handler updateObject:slice values:values request:self.request reply:reply];
          }];
          if (!answer) return nil;
          if (![self objectAnswered:answer what:@"updated" entity:slice.entity]) return nil;
        }
      }
      written = @[];
      break;
    }
    case OISPlanCommit:
      if (![self writeDynamicPropertiesUnder:node]) return nil;
      if (![self save]) return nil;
      written = @YES;
      break;
    default:
      written = @YES;
      break;
  }
  self.planMemo[key] = written;
  return written;
}

@end
