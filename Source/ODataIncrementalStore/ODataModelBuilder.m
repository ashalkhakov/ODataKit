// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataModelBuilder.h"
#import "ODataPropertyMapper.h"
#import "ODataValue.h"
#import "ODataError.h"
#import <ODataKit/ODataXML.h>
#import "ODataRegex.h"

NSString * const ODataUserInfoUnmapped = @"OData.unmapped";
NSString * const ODataModelVersionPrefix = @"odata:";

#pragma mark - Names

// UserName is userName, ID is id, URLPath is urlPath.
static NSString *OISLowerCamel(NSString *name)
{
  NSUInteger n = 0;
  while (n < name.length && [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[name characterAtIndex:n]]) n++;
  if (n == 0) return name;
  if (n == name.length) return name.lowercaseString;
  NSUInteger lower = n == 1 ? 1 : n - 1;
  return [[[name substringToIndex:lower] lowercaseString] stringByAppendingString:[name substringFromIndex:lower]];
}

// Names NSManagedObject or NSObject already answer to.
static BOOL OISReserved(NSString *name)
{
  static NSSet *reserved;
  if (!reserved) {
    reserved = [NSSet setWithArray:@[ @"description", @"entity", @"objectID", @"managedObjectContext", @"class", @"hash",
                                      @"self", @"superclass", @"zone", @"isDeleted", @"isInserted", @"isUpdated", @"isFault",
                                      @"deleted", @"inserted", @"updated", @"fault", @"hasChanges", @"changedValues",
                                      @"faultingState", @"debugDescription" ]];
  }
  return [reserved containsObject:name];
}

// A property name for the model, unique within its entity and inherited
// names.
static NSString *OISPropertyName(NSString *wire, NSMutableSet *taken)
{
  NSString *name = OISLowerCamel(wire);
  if (!name.length) name = @"property";
  if (OISReserved(name)) name = [name stringByAppendingString:@"Value"];
  NSString *unique = name;
  for (NSUInteger i = 2; [taken containsObject:unique]; i++) unique = [NSString stringWithFormat:@"%@%lu", name, (unsigned long)i];
  [taken addObject:unique];
  return unique;
}

#pragma mark - Types

// The attribute type for an Edm type, and the OData.type to mark it with
// when its Core Data type alone would be read as another Edm type. NO for
// what has no attribute.
static BOOL OISAttributeType(NSString *edm, ODataSchema *schema, NSAttributeType *type, NSString **marked)
{
  *marked = nil;
  // Any JSON value (the JSON vocabulary): Transformable, kept as it is.
  if ([edm isEqualToString:@"Org.OData.JSON.V1.JSON"]) {
    *type = NSTransformableAttributeType;
    *marked = edm;
    return YES;
  }
  // A collection of what an attribute could hold, or a complex value:
  // Transformable, an NSArray or an NSDictionary (see ODataValue.h).
  if ([edm hasPrefix:@"Collection("] && [edm hasSuffix:@")"]) {
    NSString *element = [edm substringWithRange:NSMakeRange(11, edm.length - 12)];
    NSAttributeType elementType;
    NSString *elementMarked;
    if ([element hasPrefix:@"Collection("] || !OISAttributeType(element, schema, &elementType, &elementMarked)) return NO;
    *type = NSTransformableAttributeType;
    *marked = [NSString stringWithFormat:@"Collection(%@)", [schema qualifiedName:element]];
    return YES;
  }
  if ([schema complexTypeNamed:edm]) {
    *type = NSTransformableAttributeType;
    *marked = [schema qualifiedName:edm];
    return YES;
  }
  if ([schema enumTypeNamed:edm]) {
    *type = NSStringAttributeType;
    *marked = [schema qualifiedName:edm];
    return YES;
  }
  static NSDictionary *plain, *markedTypes;
  if (!plain) {
    plain = @{
      @"Edm.String": @(NSStringAttributeType), @"Edm.Boolean": @(NSBooleanAttributeType),
      @"Edm.Byte": @(NSInteger16AttributeType), @"Edm.SByte": @(NSInteger16AttributeType),
      @"Edm.Int16": @(NSInteger16AttributeType), @"Edm.Int32": @(NSInteger32AttributeType),
      @"Edm.Int64": @(NSInteger64AttributeType), @"Edm.Decimal": @(NSDecimalAttributeType),
      @"Edm.Double": @(NSDoubleAttributeType), @"Edm.Single": @(NSFloatAttributeType),
      @"Edm.DateTimeOffset": @(NSDateAttributeType), @"Edm.Binary": @(NSBinaryDataAttributeType),
    };
    markedTypes = @{
      @"Edm.Date": @(NSDateAttributeType), @"Edm.TimeOfDay": @(NSStringAttributeType),
      @"Edm.Duration": @(NSDoubleAttributeType), @"Edm.Guid": @(NSStringAttributeType),
    };
  }
  NSNumber *t = plain[edm];
  if (t) {
    *type = (NSAttributeType)t.unsignedIntegerValue;
    return YES;
  }
  t = markedTypes[edm];
  if (t) {
    *type = (NSAttributeType)t.unsignedIntegerValue;
    *marked = edm;
    return YES;
  }
  return NO;
}

static NSString *OISAttributeTypeName(NSAttributeType type)
{
  switch (type) {
    case NSInteger16AttributeType: return @"Integer 16";
    case NSInteger32AttributeType: return @"Integer 32";
    case NSInteger64AttributeType: return @"Integer 64";
    case NSDecimalAttributeType: return @"Decimal";
    case NSDoubleAttributeType: return @"Double";
    case NSFloatAttributeType: return @"Float";
    case NSStringAttributeType: return @"String";
    case NSBooleanAttributeType: return @"Boolean";
    case NSDateAttributeType: return @"Date";
    case NSBinaryDataAttributeType: return @"Binary";
    default: return type == NSUUIDAttributeType ? @"UUID" : @"Transformable";
  }
}

#pragma mark - The model

#pragma mark Vocabularies

static NSComparisonPredicate *OISConstraint(NSString *keyPath, NSPredicateOperatorType type, id constant)
{
  NSExpression *left = keyPath ? [NSExpression expressionForKeyPath:keyPath] : [NSExpression expressionForEvaluatedObject];
  return (NSComparisonPredicate *)[NSComparisonPredicate predicateWithLeftExpression:left
                                                                     rightExpression:[NSExpression expressionForConstantValue:constant]
                                                                            modifier:NSDirectPredicateModifier
                                                                                type:type
                                                                             options:0];
}

// A bound as the attribute holds it: a date from its text, a decimal as
// an NSDecimalNumber.
static id OISBound(id value, NSAttributeType type)
{
  if (type == NSDateAttributeType) return [value isKindOfClass:[NSString class]] ? ODataDateFromString(value) : nil;
  if (![value isKindOfClass:[NSNumber class]]) return nil;
  if (type == NSDecimalAttributeType && ![value isKindOfClass:[NSDecimalNumber class]]) {
    return [NSDecimalNumber decimalNumberWithDecimal:[value decimalValue]];
  }
  return value;
}

// What a property's annotations say, in the model: Core's in userInfo,
// Validation's as Core Data's own validation, so that an object that breaks
// them fails at -save:, before the service is asked; and every annotation,
// as JSON, under OData.annotations.
static void OISApplyVocabularies(NSDictionary<NSString *, id> *annotations, ODataSchemaProperty *property,
                                 NSAttributeDescription *attribute, NSMutableDictionary *info)
{
  if (!annotations.count && !property.maxLength) return;
  NSString *core = @"Org.OData.Core.V1.", *validation = @"Org.OData.Validation.V1.";
  id description = annotations[[core stringByAppendingString:@"Description"]];
  if ([description isKindOfClass:[NSString class]]) info[ODataUserInfoDescription] = description;
  id longDescription = annotations[[core stringByAppendingString:@"LongDescription"]];
  if ([longDescription isKindOfClass:[NSString class]]) info[ODataUserInfoLongDescription] = longDescription;
  if ([annotations[[core stringByAppendingString:@"Computed"]] isEqual:@YES]) info[ODataUserInfoComputed] = @"YES";
  if ([annotations[[core stringByAppendingString:@"Immutable"]] isEqual:@YES]) info[ODataUserInfoImmutable] = @"YES";
  id permissions = annotations[[core stringByAppendingString:@"Permissions"]];
  if ([permissions isKindOfClass:[NSString class]]) info[ODataUserInfoPermissions] = permissions;
  NSString *measures = @"Org.OData.Measures.V1.";
  id unit = annotations[[measures stringByAppendingString:@"Unit"]] ?: annotations[[measures stringByAppendingString:@"UNECEUnit"]];
  if ([unit isKindOfClass:[NSString class]]) info[ODataUserInfoUnit] = unit;
  id scale = annotations[[measures stringByAppendingString:@"Scale"]];
  if ([scale isKindOfClass:[NSNumber class]]) info[ODataUserInfoScale] = [scale stringValue];
  id currency = annotations[[measures stringByAppendingString:@"ISOCurrency"]];
  if ([currency isKindOfClass:[NSString class]]) info[ODataUserInfoISOCurrency] = currency;
  if (annotations.count) {
    NSData *json = [NSJSONSerialization isValidJSONObject:annotations] ? [NSJSONSerialization dataWithJSONObject:annotations options:0 error:NULL] : nil;
    if (json) info[ODataUserInfoAnnotations] = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
  }
  if (!attribute) return;

  NSMutableArray *predicates = [NSMutableArray array];
  NSMutableArray *warnings = [NSMutableArray array];
  NSAttributeType type = attribute.attributeType;
  BOOL date = type == NSDateAttributeType;
  NSString *minimumTerm = [validation stringByAppendingString:@"Minimum"];
  NSString *maximumTerm = [validation stringByAppendingString:@"Maximum"];
  NSString *exclusive = [@"@" stringByAppendingString:[validation stringByAppendingString:@"Exclusive"]];
  id minimum = OISBound(annotations[minimumTerm], type);
  if (minimum) {
    BOOL open = [annotations[[minimumTerm stringByAppendingString:exclusive]] isEqual:@YES];
    [predicates addObject:OISConstraint(nil, open ? NSGreaterThanPredicateOperatorType : NSGreaterThanOrEqualToPredicateOperatorType, minimum)];
    [warnings addObject:@(date ? NSValidationDateTooSoonError : NSValidationNumberTooSmallError)];
  }
  id maximum = OISBound(annotations[maximumTerm], type);
  if (maximum) {
    BOOL open = [annotations[[maximumTerm stringByAppendingString:exclusive]] isEqual:@YES];
    [predicates addObject:OISConstraint(nil, open ? NSLessThanPredicateOperatorType : NSLessThanOrEqualToPredicateOperatorType, maximum)];
    [warnings addObject:@(date ? NSValidationDateTooLateError : NSValidationNumberTooLargeError)];
  }
  if (type == NSStringAttributeType) {
    id pattern = annotations[[validation stringByAppendingString:@"Pattern"]];
    // ECMAScript's, found anywhere, as MATCHES reads it; none where it
    // cannot say the same, rather than a constraint that is not the
    // service's.
    NSString *anywhere = [pattern isKindOfClass:[NSString class]] ? [ODataRegex matchesPatternFindingECMAScript:pattern error:NULL] : nil;
    if (anywhere) {
      [predicates addObject:OISConstraint(nil, NSMatchesPredicateOperatorType, anywhere)];
      [warnings addObject:@(NSValidationStringPatternMatchingError)];
    }
    if (property.maxLength) {
      [predicates addObject:OISConstraint(@"length", NSLessThanOrEqualToPredicateOperatorType, property.maxLength)];
      [warnings addObject:@(NSValidationStringTooLongError)];
    }
  }
  id allowed = annotations[[validation stringByAppendingString:@"AllowedValues"]];
  if ([allowed isKindOfClass:[NSArray class]]) {
    NSMutableArray *values = [NSMutableArray array];
    for (id record in allowed) {
      id value = [record isKindOfClass:[NSDictionary class]] ? record[@"Value"] : nil;
      if (!value) continue;
      id bound = type == NSStringAttributeType ? value : OISBound(value, type);
      if (bound) [values addObject:bound];
    }
    if (values.count) {
      [predicates addObject:OISConstraint(nil, NSInPredicateOperatorType, values)];
      [warnings addObject:@(NSManagedObjectValidationError)];
    }
  }
  if (predicates.count) [attribute setValidationPredicates:predicates withValidationWarnings:warnings];
}

@implementation ODataModelBuilder

+ (NSString *)versionIdentifierForSchema:(ODataSchema *)schema
{
  // A canonical text of what the model is made from, hashed (FNV-1a, 64
  // bits: this identifies a version, it does not protect anything).
  NSMutableString *canonical = [NSMutableString string];
  for (NSString *name in [schema.entityTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaEntityType *type = schema.entityTypes[name];
    [canonical appendFormat:@"E %@ %@ %d %@%@\n", name, type.baseType ?: @"", type.isAbstract, [type.declaredKey componentsJoinedByString:@","],
                            type.isOpen ? @" open" : @""];
    for (NSString *p in [type.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *property = type.declaredProperties[p];
      [canonical appendFormat:@"P %@ %@ %d\n", p, property.type, property.nullable];
    }
    for (NSString *n in [type.declaredNavigationProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaNavigationProperty *navigation = type.declaredNavigationProperties[n];
      [canonical appendFormat:@"N %@ %@ %d %@\n", n, navigation.type, navigation.isCollection, navigation.partner ?: @""];
    }
  }
  for (NSString *name in [schema.complexTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaComplexType *type = schema.complexTypes[name];
    [canonical appendFormat:@"C %@ %@ %d %d\n", name, type.baseType ?: @"", type.isAbstract, type.isOpen];
    for (NSString *p in [type.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *property = type.declaredProperties[p];
      [canonical appendFormat:@"P %@ %@ %d\n", p, property.type, property.nullable];
    }
  }
  for (NSString *name in [schema.enumTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaEnumType *type = schema.enumTypes[name];
    [canonical appendFormat:@"M %@ %d", name, type.isFlags];
    for (NSString *member in type.memberNames) [canonical appendFormat:@" %@=%@", member, type.values[member]];
    [canonical appendString:@"\n"];
  }
  for (NSString *set in [schema.entitySets.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [canonical appendFormat:@"S %@ %@\n", set, schema.entitySets[set]];
  }
  NSData *bytes = [canonical dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *p = bytes.bytes;
  uint64_t hash = 14695981039346656037ULL;
  for (NSUInteger i = 0; i < bytes.length; i++) {
    hash ^= p[i];
    hash *= 1099511628211ULL;
  }
  return [NSString stringWithFormat:@"%@%016llx", ODataModelVersionPrefix, (unsigned long long)hash];
}

+ (NSString *)versionIdentifierOfModel:(NSManagedObjectModel *)model
{
  for (id identifier in model.versionIdentifiers) {
    if ([identifier isKindOfClass:[NSString class]] && [identifier hasPrefix:ODataModelVersionPrefix]) return identifier;
  }
  return nil;
}

+ (NSManagedObjectModel *)modelWithSchema:(ODataSchema *)schema
{
  NSString *version = [self versionIdentifierForSchema:schema];
  NSArray *typeNames = [schema.entityTypes.allKeys sortedArrayUsingSelector:@selector(compare:)];

  // Entity names: the type's name, unless two namespaces share it.
  NSMutableDictionary *entities = [NSMutableDictionary dictionary];  // qualified type -> entity
  NSCountedSet *simpleNames = [NSCountedSet set];
  for (NSString *qualified in typeNames) [simpleNames addObject:schema.entityTypes[qualified].name];
  for (NSString *qualified in typeNames) {
    ODataSchemaEntityType *type = schema.entityTypes[qualified];
    NSString *name = [simpleNames countForObject:type.name] > 1 ? [qualified stringByReplacingOccurrencesOfString:@"." withString:@"_"] : type.name;
    if (name.length) name = [[[name substringToIndex:1] uppercaseString] stringByAppendingString:[name substringFromIndex:1]];
    NSEntityDescription *entity = [[NSEntityDescription alloc] init];
    entity.name = name;
    entity.managedObjectClassName = @"NSManagedObject";
    entity.abstract = type.isAbstract;
    NSMutableDictionary *info = [@{ ODataUserInfoType: qualified } mutableCopy];
    // Its own set: a derived type is found through its base's.
    NSMutableArray *sets = [NSMutableArray array];
    for (NSString *set in schema.entitySets) {
      if ([schema.entitySets[set] isEqualToString:qualified]) [sets addObject:set];
    }
    if (sets.count == 1) info[ODataUserInfoEntitySet] = sets.firstObject;
    OISApplyVocabularies([schema annotationsForTarget:qualified], nil, nil, info);
    entity.userInfo = info;
    entities[qualified] = entity;
  }

  // Attributes, and a place for relationships, entity by entity; base
  // types first, so a derived type knows the names it inherits.
  NSMutableDictionary *taken = [NSMutableDictionary dictionary];           // qualified type -> NSMutableSet of names
  NSMutableDictionary *relationships = [NSMutableDictionary dictionary];   // "Type/Nav" -> relationship
  NSMutableDictionary *properties = [NSMutableDictionary dictionary];      // qualified type -> NSMutableArray
  NSMutableArray *ordered = [NSMutableArray array];
  NSMutableSet *placed = [NSMutableSet set];
  while (ordered.count < typeNames.count) {
    NSUInteger before = ordered.count;
    for (NSString *qualified in typeNames) {
      if ([placed containsObject:qualified]) continue;
      NSString *base = schema.entityTypes[qualified].baseType;
      if (base && entities[base] && ![placed containsObject:base]) continue;
      [ordered addObject:qualified];
      [placed addObject:qualified];
    }
    if (ordered.count == before) break;  // a base type cycle: leave the rest out
  }
  for (NSString *qualified in ordered) {
    ODataSchemaEntityType *type = schema.entityTypes[qualified];
    NSString *base = type.baseType && entities[type.baseType] ? type.baseType : nil;
    NSMutableSet *names = base ? [taken[base] mutableCopy] : [NSMutableSet set];
    taken[qualified] = names;
    NSMutableArray *own = [NSMutableArray array];
    NSMutableArray *unmapped = [NSMutableArray array];
    NSSet *key = [NSSet setWithArray:type.declaredKey];
    for (NSString *wire in [type.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *property = type.declaredProperties[wire];
      NSAttributeType attributeType;
      NSString *marked = nil;
      if (!OISAttributeType(property.type, schema, &attributeType, &marked)) {
        [unmapped addObject:wire];
        continue;
      }
      NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
      attr.name = OISPropertyName(wire, names);
      attr.attributeType = attributeType;
      attr.optional = property.nullable && ![key containsObject:wire];
      NSMutableDictionary *info = [@{ ODataUserInfoProperty: wire } mutableCopy];
      if ([key containsObject:wire]) info[ODataUserInfoKey] = @"YES";
      if (marked) info[ODataUserInfoType] = marked;
      OISApplyVocabularies([schema annotationsForTarget:[NSString stringWithFormat:@"%@/%@", qualified, wire]], property, attr, info);
      attr.userInfo = info;
      if (attributeType == NSTransformableAttributeType) {
        attr.valueTransformerName = @"NSSecureUnarchiveFromData";
        attr.attributeValueClassName = [marked isEqualToString:@"Org.OData.JSON.V1.JSON"] ? nil
                                     : property.isCollection ? @"NSArray" : @"NSDictionary";
      }
      [own addObject:attr];
    }
    // An open type's dynamic properties: a bag of them, which its derived
    // types inherit.
    if (type.isOpen && !(base && [schema entityTypeIsOpen:schema.entityTypes[base]])) {
      NSAttributeDescription *bag = [[NSAttributeDescription alloc] init];
      bag.name = OISPropertyName(@"DynamicProperties", names);
      bag.attributeType = NSTransformableAttributeType;
      bag.optional = YES;
      bag.valueTransformerName = @"NSSecureUnarchiveFromData";
      bag.attributeValueClassName = @"NSDictionary";
      bag.userInfo = @{ ODataUserInfoDynamicProperties: @"YES" };
      [own addObject:bag];
    }
    for (NSString *wire in [type.declaredNavigationProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaNavigationProperty *navigation = type.declaredNavigationProperties[wire];
      NSEntityDescription *destination = entities[navigation.type];
      if (!destination) {
        [unmapped addObject:wire];
        continue;
      }
      NSRelationshipDescription *rel = [[NSRelationshipDescription alloc] init];
      rel.name = OISPropertyName(wire, names);
      rel.destinationEntity = destination;
      rel.minCount = 0;
      rel.maxCount = navigation.isCollection ? 0 : 1;
      rel.optional = YES;
      rel.deleteRule = NSNullifyDeleteRule;
      NSMutableDictionary *relInfo = [@{ ODataUserInfoProperty: wire } mutableCopy];
      NSDictionary *relAnnotations = [schema annotationsForTarget:[NSString stringWithFormat:@"%@/%@", qualified, wire]];
      OISApplyVocabularies(relAnnotations, nil, nil, relInfo);
      if (navigation.isCollection) {
        id least = relAnnotations[@"Org.OData.Validation.V1.MinItems"], most = relAnnotations[@"Org.OData.Validation.V1.MaxItems"];
        if ([least isKindOfClass:[NSNumber class]]) rel.minCount = [least unsignedIntegerValue];
        if ([most isKindOfClass:[NSNumber class]]) rel.maxCount = [most unsignedIntegerValue];
      }
      rel.userInfo = relInfo;
      relationships[[NSString stringWithFormat:@"%@/%@", qualified, wire]] = rel;
      [own addObject:rel];
    }
    if (unmapped.count) {
      NSEntityDescription *entity = entities[qualified];
      NSMutableDictionary *info = [entity.userInfo mutableCopy];
      info[ODataUserInfoUnmapped] = [unmapped componentsJoinedByString:@","];
      entity.userInfo = info;
    }
    properties[qualified] = own;
  }

  // Application time: a timeline set's period and object key
  // (Temporal.ApplicationTimeSupport), in the userInfo the server reads.
  for (NSString *qualified in ordered) {
    NSEntityDescription *entity = entities[qualified];
    NSString *set = entity.userInfo[ODataUserInfoEntitySet];
    NSDictionary *support = set ? [schema capability:@"Temporal.ApplicationTimeSupport" forEntitySet:set] : nil;
    NSDictionary *timeline = [support isKindOfClass:[NSDictionary class]] ? support[@"Timeline"] : nil;
    if (![timeline isKindOfClass:[NSDictionary class]] || ![timeline[@"@type"] hasSuffix:@"TimelineVisible"]) continue;
    NSMutableDictionary *byWire = [NSMutableDictionary dictionary];
    for (id property in properties[qualified]) {
      if ([property isKindOfClass:[NSAttributeDescription class]]) byWire[[property userInfo][ODataUserInfoProperty]] = [property name];
    }
    NSString *(^path)(id) = ^NSString *(id value) {
      return [value isKindOfClass:[NSDictionary class]] ? byWire[value[@"$PropertyPath"]] : nil;
    };
    NSString *start = path(timeline[@"PeriodStart"]), *end = path(timeline[@"PeriodEnd"]);
    if (!start || !end) continue;
    NSMutableDictionary *info = [entity.userInfo mutableCopy];
    info[ODataUserInfoPeriodStart] = start;
    info[ODataUserInfoPeriodEnd] = end;
    NSMutableArray *objectKey = [NSMutableArray array];
    for (id item in [timeline[@"ObjectKey"] isKindOfClass:[NSArray class]] ? timeline[@"ObjectKey"] : @[]) {
      if (path(item)) [objectKey addObject:path(item)];
    }
    if (objectKey.count) info[ODataUserInfoObjectKey] = [objectKey componentsJoinedByString:@","];
    NSDictionary *unit = support[@"UnitOfTime"];
    if ([unit isKindOfClass:[NSDictionary class]] && [unit[@"ClosedClosedPeriods"] boolValue]) info[ODataUserInfoClosedClosedPeriods] = @"YES";
    entity.userInfo = info;
  }

  // Partners are inverses.
  for (NSString *qualified in ordered) {
    ODataSchemaEntityType *type = schema.entityTypes[qualified];
    for (NSString *wire in type.declaredNavigationProperties) {
      ODataSchemaNavigationProperty *navigation = type.declaredNavigationProperties[wire];
      NSRelationshipDescription *rel = relationships[[NSString stringWithFormat:@"%@/%@", qualified, wire]];
      if (!rel || !navigation.partner) continue;
      NSRelationshipDescription *partner = nil;
      for (ODataSchemaEntityType *t = schema.entityTypes[navigation.type]; t && !partner; t = t.baseType ? schema.entityTypes[t.baseType] : nil) {
        partner = relationships[[NSString stringWithFormat:@"%@/%@", t.qualifiedName, navigation.partner]];
      }
      if (partner) {
        rel.inverseRelationship = partner;
        partner.inverseRelationship = rel;
      }
    }
  }

  NSMutableArray *all = [NSMutableArray array];
  for (NSString *qualified in ordered) {
    NSEntityDescription *entity = entities[qualified];
    entity.properties = properties[qualified];
    [all addObject:entity];
  }
  for (NSString *qualified in ordered) {
    NSMutableArray *children = [NSMutableArray array];
    for (NSString *other in ordered) {
      if ([schema.entityTypes[other].baseType isEqualToString:qualified]) [children addObject:entities[other]];
    }
    if (children.count) [entities[qualified] setSubentities:children];
  }
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = all;
  model.versionIdentifiers = [NSSet setWithObject:version];
  return model;
}

#pragma mark - Writing a model

// An element with these attributes, in this order: name, value, ...
static ODataXMLElement *OISModelElement(NSString *name, NSArray *attributes)
{
  ODataXMLElement *element = [[ODataXMLElement alloc] initWithName:name];
  for (NSUInteger i = 0; i + 1 < attributes.count; i += 2) {
    [element addAttribute:[ODataXMLNode attributeWithName:attributes[i] stringValue:[attributes[i + 1] description]]];
  }
  return element;
}

static void OISAddUserInfo(ODataXMLElement *parent, NSDictionary *info)
{
  if (!info.count) return;
  ODataXMLElement *userInfo = OISModelElement(@"userInfo", nil);
  for (NSString *key in [info.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [userInfo addChild:OISModelElement(@"entry", @[ @"key", key, @"value", [info[key] description] ])];
  }
  [parent addChild:userInfo];
}

+ (NSData *)modelDocumentForModel:(NSManagedObjectModel *)model
{
  NSString *version = [self versionIdentifierOfModel:model];
  ODataXMLElement *root = OISModelElement(@"model", @[
    @"type", @"com.apple.IDECoreDataModeler.DataModel", @"documentVersion", @"1.0", @"lastSavedToolsVersion", @"1",
    @"systemVersion", @"1", @"minimumToolsVersion", @"Automatic", @"sourceLanguage", @"Objective-C",
    @"userDefinedModelVersionIdentifier", version ?: @"" ]);
  NSArray *entities = [model.entities sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a name] compare:[b name]];
  }];
  for (NSEntityDescription *entity in entities) {
    ODataXMLElement *element = OISModelElement(@"entity", @[ @"name", entity.name ]);
    NSString *cls = entity.managedObjectClassName;
    if (cls.length && ![cls isEqualToString:@"NSManagedObject"]) [element addAttribute:[ODataXMLNode attributeWithName:@"representedClassName" stringValue:cls]];
    if (entity.superentity) [element addAttribute:[ODataXMLNode attributeWithName:@"parentEntity" stringValue:entity.superentity.name]];
    if (entity.isAbstract) [element addAttribute:[ODataXMLNode attributeWithName:@"isAbstract" stringValue:@"YES"]];
    [element addAttribute:[ODataXMLNode attributeWithName:@"syncable" stringValue:@"YES"]];
    NSDictionary *inherited = entity.superentity.propertiesByName ?: @{};
    NSArray *names = [entity.propertiesByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
      if (inherited[name]) continue;
      NSPropertyDescription *property = entity.propertiesByName[name];
      ODataXMLElement *child;
      if ([property isKindOfClass:[NSAttributeDescription class]]) {
        NSAttributeDescription *attr = (NSAttributeDescription *)property;
        NSMutableArray *attributes = [@[ @"name", name, @"optional", attr.isOptional ? @"YES" : @"NO",
                                         @"attributeType", OISAttributeTypeName(attr.attributeType) ] mutableCopy];
        if (attr.valueTransformerName.length) [attributes addObjectsFromArray:@[ @"valueTransformerName", attr.valueTransformerName ]];
        if (attr.attributeValueClassName.length) [attributes addObjectsFromArray:@[ @"customClassName", attr.attributeValueClassName ]];
        if (attr.attributeType == NSInteger16AttributeType || attr.attributeType == NSInteger32AttributeType ||
            attr.attributeType == NSInteger64AttributeType || attr.attributeType == NSDoubleAttributeType ||
            attr.attributeType == NSFloatAttributeType || attr.attributeType == NSBooleanAttributeType ||
            attr.attributeType == NSDateAttributeType) {
          [attributes addObjectsFromArray:@[ @"usesScalarValueType", @"NO" ]];
        }
        child = OISModelElement(@"attribute", attributes);
      } else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
        NSRelationshipDescription *rel = (NSRelationshipDescription *)property;
        NSMutableArray *attributes = [@[ @"name", name, @"optional", @"YES" ] mutableCopy];
        [attributes addObjectsFromArray:rel.isToMany ? @[ @"toMany", @"YES" ] : @[ @"maxCount", @"1" ]];
        [attributes addObjectsFromArray:@[ @"deletionRule", @"Nullify", @"destinationEntity", rel.destinationEntity.name ?: @"" ]];
        if (rel.inverseRelationship) {
          [attributes addObjectsFromArray:@[ @"inverseName", rel.inverseRelationship.name,
                                             @"inverseEntity", rel.inverseRelationship.entity.name ?: @"" ]];
        }
        child = OISModelElement(@"relationship", attributes);
      } else {
        continue;
      }
      OISAddUserInfo(child, property.userInfo);
      [element addChild:child];
    }
    OISAddUserInfo(element, entity.userInfo);
    [root addChild:element];
  }
  ODataXMLDocument *document = [[ODataXMLDocument alloc] initWithRootElement:root];
  document.version = @"1.0";
  document.characterEncoding = @"UTF-8";
  document.standalone = YES;
  return [document XMLDataWithOptions:ODataXMLNodePrettyPrint | ODataXMLNodeCompactEmptyElement];
}

// The userDefinedModelVersionIdentifier of a model document.
static NSString *OISDocumentVersion(NSData *document)
{
  ODataXMLElement *root = document.length ? [[ODataXMLDocument alloc] initWithData:document options:0 error:NULL].rootElement : nil;
  NSString *version = [root attributeForName:@"userDefinedModelVersionIdentifier"].stringValue;
  return version.length ? version : nil;
}

+ (NSString *)writeModel:(NSManagedObjectModel *)model toPackage:(NSString *)path changed:(BOOL *)changed error:(NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
  NSString *currentFile = [path stringByAppendingPathComponent:@".xccurrentversion"];
  NSData *document = [self modelDocumentForModel:model];
  NSString *version = [self versionIdentifierOfModel:model];
  if (changed) *changed = NO;

  NSDictionary *current = [NSDictionary dictionaryWithContentsOfFile:currentFile];
  NSString *currentName = current[@"_XCCurrentVersionName"];
  NSMutableSet *existing = [NSMutableSet set];
  for (NSString *entry in [fm contentsOfDirectoryAtPath:path error:NULL] ?: @[]) {
    if ([entry.pathExtension isEqualToString:@"xcdatamodel"]) [existing addObject:entry];
  }
  if (!currentName && existing.count == 1) currentName = existing.anyObject;
  if (currentName) {
    NSString *contents = [[path stringByAppendingPathComponent:currentName] stringByAppendingPathComponent:@"contents"];
    NSData *old = [NSData dataWithContentsOfFile:contents];
    if (version && [OISDocumentVersion(old) isEqualToString:version]) {
      // The same version of the schema, written otherwise (with class
      // names, say): the same model version, rewritten in place.
      if (![old isEqualToData:document]) {
        if (![document writeToFile:contents options:NSDataWritingAtomic error:error]) return nil;
        if (changed) *changed = YES;
      }
      return currentName.stringByDeletingPathExtension;
    }
  }

  // A new version: "Zoo", then "Zoo 2", "Zoo 3", ...
  NSString *versionName = [name stringByAppendingPathExtension:@"xcdatamodel"];
  for (NSUInteger i = 2; [existing containsObject:versionName]; i++) {
    versionName = [[NSString stringWithFormat:@"%@ %lu", name, (unsigned long)i] stringByAppendingPathExtension:@"xcdatamodel"];
  }
  NSString *directory = [path stringByAppendingPathComponent:versionName];
  if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
  if (![document writeToFile:[directory stringByAppendingPathComponent:@"contents"] options:NSDataWritingAtomic error:error]) return nil;
  NSData *plist = [NSPropertyListSerialization dataWithPropertyList:@{ @"_XCCurrentVersionName": versionName }
                                                             format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
  if (!plist || ![plist writeToFile:currentFile options:NSDataWritingAtomic error:error]) return nil;
  if (changed) *changed = YES;
  return versionName.stringByDeletingPathExtension;
}

@end
