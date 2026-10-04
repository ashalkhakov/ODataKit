// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataPropertyMapper.h"
#import "ODataExpression.h"
#import "ODataRegex.h"

NSString * const ODataUserInfoEntitySet = @"OData.entitySet";
NSString * const ODataUserInfoProperty = @"OData.property";
NSString * const ODataUserInfoKey = @"OData.key";
NSString * const ODataUserInfoDescription = @"OData.description";
NSString * const ODataUserInfoLongDescription = @"OData.longDescription";
NSString * const ODataUserInfoComputed = @"OData.computed";
NSString * const ODataUserInfoImmutable = @"OData.immutable";
NSString * const ODataUserInfoPermissions = @"OData.permissions";
NSString * const ODataUserInfoUnit = @"OData.unit";
NSString * const ODataUserInfoISOCurrency = @"OData.isoCurrency";
NSString * const ODataUserInfoScale = @"OData.scale";
NSString * const ODataUserInfoAnnotations = @"OData.annotations";
NSString * const ODataUserInfoPeriodStart = @"OData.periodStart";
NSString * const ODataUserInfoPeriodEnd = @"OData.periodEnd";
NSString * const ODataUserInfoObjectKey = @"OData.objectKey";
NSString * const ODataUserInfoClosedClosedPeriods = @"OData.closedClosedPeriods";
NSString * const ODataUserInfoDynamicProperties = @"OData.dynamicProperties";
NSString * const ODataUserInfoServed = @"OData.served";

@implementation ODataPropertyMapper

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _naming = ODataPropertyNamingPascalCase;
  _values = [[ODataValueCoder alloc] init];
  return self;
}

- (void)setSchema:(ODataSchema *)schema
{
  _schema = schema;
  _values.schema = schema;
  __weak ODataPropertyMapper *weakSelf = self;
  _values.declaredTypeForAttribute = schema ? ^NSString *(NSAttributeDescription *attribute) {
    return [weakSelf declaredTypeForAttribute:attribute];
  } : nil;
}

#pragma mark - Types and sets

- (ODataSchemaEntityType *)entityTypeForEntity:(NSEntityDescription *)entity
{
  if (!self.schema || !entity) return nil;
  NSString *declared = entity.userInfo[ODataUserInfoType];
  if ([declared isKindOfClass:[NSString class]]) return [self.schema entityTypeNamed:declared];
  return [self.schema entityTypeWithSimpleName:entity.name ?: @""];
}

- (NSString *)qualifiedTypeForEntity:(NSEntityDescription *)entity
{
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  if (type) return type.qualifiedName;
  NSString *declared = entity.userInfo[ODataUserInfoType];
  return [declared isKindOfClass:[NSString class]] ? declared : nil;
}

// A term's value for an attribute: its userInfo's, else the schema's.
- (id)annotation:(NSString *)term userInfo:(NSString *)key ofAttribute:(NSAttributeDescription *)attribute
{
  id local = key ? attribute.userInfo[key] : nil;
  if (local) return local;
  ODataSchemaEntityType *type = [self entityTypeForEntity:attribute.entity];
  return type ? [self.schema annotation:term forProperty:[self propertyForAttribute:attribute] ofEntityType:type] : nil;
}

- (BOOL)attributeIsComputed:(NSAttributeDescription *)attribute
{
  id computed = [self annotation:@"Core.Computed" userInfo:ODataUserInfoComputed ofAttribute:attribute];
  if ([computed respondsToSelector:@selector(boolValue)] && [computed boolValue]) return YES;
  id permissions = [self annotation:@"Core.Permissions" userInfo:ODataUserInfoPermissions ofAttribute:attribute];
  return [permissions isEqual:@"Read"] || [permissions isEqual:@"None"];
}

- (BOOL)attributeIsImmutable:(NSAttributeDescription *)attribute
{
  id immutable = [self annotation:@"Core.Immutable" userInfo:ODataUserInfoImmutable ofAttribute:attribute];
  return [immutable respondsToSelector:@selector(boolValue)] && [immutable boolValue];
}

#pragma mark - Measures

- (NSString *)unitOfAttribute:(NSAttributeDescription *)attribute
{
  id unit = [self annotation:@"Measures.Unit" userInfo:ODataUserInfoUnit ofAttribute:attribute]
         ?: [self annotation:@"Measures.UNECEUnit" userInfo:nil ofAttribute:attribute];
  return [unit isKindOfClass:[NSString class]] ? unit : nil;
}

- (NSNumber *)scaleOfAttribute:(NSAttributeDescription *)attribute
{
  id scale = [self annotation:@"Measures.Scale" userInfo:ODataUserInfoScale ofAttribute:attribute];
  if ([scale isKindOfClass:[NSString class]]) scale = @([scale integerValue]);
  return [scale isKindOfClass:[NSNumber class]] ? scale : nil;
}

- (NSString *)currencyOfAttribute:(NSAttributeDescription *)attribute inObject:(NSManagedObject *)object
{
  id currency = [self annotation:@"Measures.ISOCurrency" userInfo:ODataUserInfoISOCurrency ofAttribute:attribute];
  NSString *path = [currency isKindOfClass:[NSDictionary class]] ? currency[@"$Path"] : nil;
  // In userInfo, the name of the attribute that holds it; in $metadata, a path.
  if ([currency isKindOfClass:[NSString class]] && attribute.entity.attributesByName[currency]) {
    return [[object valueForKey:currency] description];
  }
  if (path) {
    NSPropertyDescription *holder = [self propertyForWireName:path entity:attribute.entity];
    id value = holder ? [object valueForKey:holder.name] : nil;
    return [value isKindOfClass:[NSString class]] ? value : nil;
  }
  return [currency isKindOfClass:[NSString class]] ? currency : nil;
}

#pragma mark - Validation beyond Core Data's

// Annotations of a property or an entity: the schema's, else what
// userInfo's OData.annotations holds (by the full term name).
- (NSDictionary *)annotationsOfProperty:(NSPropertyDescription *)property entity:(NSEntityDescription *)entity
{
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  NSMutableDictionary *found = [NSMutableDictionary dictionary];
  if (type) {
    // The declaring type's own target, through the base types.
    for (ODataSchemaEntityType *t = type; t; t = t.baseType ? [self.schema entityTypeNamed:t.baseType] : nil) {
      NSString *target = t.qualifiedName;
      if (property) {
        NSString *wire = [property isKindOfClass:[NSAttributeDescription class]] ? [self propertyForAttribute:(NSAttributeDescription *)property]
                                                                                   : [self propertyForRelationship:(NSRelationshipDescription *)property];
        target = [target stringByAppendingFormat:@"/%@", wire];
      }
      NSDictionary *annotations = [self.schema annotationsForTarget:target];
      for (NSString *term in annotations) if (!found[term]) found[term] = annotations[term];
      if (!property) break;
    }
  }
  if (found.count) return found;
  id local = (property ?: (id)entity) ? [(property ? (id)property : (id)entity) userInfo][ODataUserInfoAnnotations] : nil;
  if ([local isKindOfClass:[NSString class]]) local = [NSJSONSerialization JSONObjectWithData:[local dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
  if (![local isKindOfClass:[NSDictionary class]]) return found;
  for (NSString *term in local) {
    NSString *full = term;
    for (NSString *vocabulary in @[ @"Core", @"Validation", @"Capabilities", @"Aggregation" ]) {
      NSString *prefix = [vocabulary stringByAppendingString:@"."];
      if ([term hasPrefix:prefix]) full = [NSString stringWithFormat:@"Org.OData.%@.V1.%@", vocabulary, [term substringFromIndex:prefix.length]];
    }
    found[full] = local[term];
  }
  return found;
}

// A CSDL expression, as JSON CSDL writes it, as an NSExpression: a path
// from the entity, or a constant.
- (NSExpression *)expressionForOperand:(id)operand entity:(NSEntityDescription *)entity
{
  if ([operand isKindOfClass:[NSDictionary class]]) {
    NSString *path = operand[@"$Path"] ?: operand[@"$PropertyPath"];
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSMutableArray *keys = [NSMutableArray array];
    NSEntityDescription *current = entity;
    for (NSString *wire in [path componentsSeparatedByString:@"/"]) {
      NSPropertyDescription *found = nil;
      for (NSPropertyDescription *property in current.properties) {
        NSString *name = [property isKindOfClass:[NSAttributeDescription class]] ? [self propertyForAttribute:(NSAttributeDescription *)property]
                                                                                   : [self propertyForRelationship:(NSRelationshipDescription *)property];
        if ([name isEqualToString:wire]) found = property;
      }
      if (!found) return nil;
      [keys addObject:found.name];
      current = [found isKindOfClass:[NSRelationshipDescription class]] ? [(NSRelationshipDescription *)found destinationEntity] : nil;
    }
    return [NSExpression expressionForKeyPath:[keys componentsJoinedByString:@"."]];
  }
  if (operand == [NSNull null]) return [NSExpression expressionForConstantValue:nil];
  if ([operand isKindOfClass:[NSString class]] || [operand isKindOfClass:[NSNumber class]]) return [NSExpression expressionForConstantValue:operand];
  return nil;
}

- (NSPredicate *)predicateForCondition:(id)condition entity:(NSEntityDescription *)entity
{
  if ([condition isKindOfClass:[NSNumber class]]) return [NSPredicate predicateWithValue:[condition boolValue]];
  if (![condition isKindOfClass:[NSDictionary class]]) return nil;
  NSDictionary *comparisons = @{ @"$Eq": @(NSEqualToPredicateOperatorType), @"$Ne": @(NSNotEqualToPredicateOperatorType),
                                 @"$Gt": @(NSGreaterThanPredicateOperatorType), @"$Ge": @(NSGreaterThanOrEqualToPredicateOperatorType),
                                 @"$Lt": @(NSLessThanPredicateOperatorType), @"$Le": @(NSLessThanOrEqualToPredicateOperatorType) };
  for (NSString *op in comparisons) {
    NSArray *operands = condition[op];
    if (![operands isKindOfClass:[NSArray class]]) continue;
    if (operands.count != 2) return nil;
    NSExpression *left = [self expressionForOperand:operands[0] entity:entity];
    NSExpression *right = [self expressionForOperand:operands[1] entity:entity];
    if (!left || !right) return nil;
    return [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:right modifier:NSDirectPredicateModifier
                                                         type:[comparisons[op] unsignedIntegerValue] options:0];
  }
  for (NSString *op in @[ @"$And", @"$Or" ]) {
    NSArray *operands = condition[op];
    if (![operands isKindOfClass:[NSArray class]]) continue;
    NSMutableArray *parts = [NSMutableArray array];
    for (id operand in operands) {
      NSPredicate *part = [self predicateForCondition:operand entity:entity];
      if (!part) return nil;
      [parts addObject:part];
    }
    return [op isEqualToString:@"$And"] ? [NSCompoundPredicate andPredicateWithSubpredicates:parts]
                                        : [NSCompoundPredicate orPredicateWithSubpredicates:parts];
  }
  NSArray *not = condition[@"$Not"];
  if ([not isKindOfClass:[NSArray class]]) {
    NSPredicate *inner = not.count == 1 ? [self predicateForCondition:not[0] entity:entity] : nil;
    return inner ? [NSCompoundPredicate notPredicateWithSubpredicate:inner] : nil;
  }
  NSArray *branches = condition[@"$If"];
  if ([branches isKindOfClass:[NSArray class]]) {
    if (branches.count != 3) return nil;
    NSPredicate *test = [self predicateForCondition:branches[0] entity:entity];
    NSPredicate *then = [self predicateForCondition:branches[1] entity:entity];
    NSPredicate *otherwise = [self predicateForCondition:branches[2] entity:entity];
    if (!test || !then || !otherwise) return nil;
    return [NSCompoundPredicate orPredicateWithSubpredicates:@[
      [NSCompoundPredicate andPredicateWithSubpredicates:@[ test, then ]],
      [NSCompoundPredicate andPredicateWithSubpredicates:@[ [NSCompoundPredicate notPredicateWithSubpredicate:test], otherwise ]] ]];
  }
  NSArray *in = condition[@"$In"];
  if ([in isKindOfClass:[NSArray class]] && in.count == 2 && [in[1] isKindOfClass:[NSArray class]]) {
    NSExpression *left = [self expressionForOperand:in[0] entity:entity];
    if (!left) return nil;
    return [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:[NSExpression expressionForConstantValue:in[1]]
                                                     modifier:NSDirectPredicateModifier type:NSInPredicateOperatorType options:0];
  }
  NSArray *apply = condition[@"$Apply"];
  if ([apply isKindOfClass:[NSArray class]] && [condition[@"$Function"] isEqual:@"odata.matchesPattern"] && apply.count == 2 &&
      [apply[1] isKindOfClass:[NSString class]]) {
    NSExpression *text = [self expressionForOperand:apply[0] entity:entity];
    if (!text) return nil;
    // ECMAScript's, found anywhere, as MATCHES reads it (ODataRegex.h).
    NSString *anywhere = [ODataRegex matchesPatternFindingECMAScript:apply[1] error:NULL];
    if (!anywhere) return nil;
    return [NSComparisonPredicate predicateWithLeftExpression:text rightExpression:[NSExpression expressionForConstantValue:anywhere]
                                                     modifier:NSDirectPredicateModifier type:NSMatchesPredicateOperatorType options:0];
  }
  return nil;
}

static NSError *OISViolation(NSManagedObject *object, NSString *key, NSString *message)
{
  NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
  info[NSValidationObjectErrorKey] = object;
  if (key) info[NSValidationKeyErrorKey] = key;
  return [NSError errorWithDomain:NSCocoaErrorDomain code:NSManagedObjectValidationError userInfo:info];
}

// Each Validation.Constraint (qualified or not) of these annotations that
// the object breaks.
- (NSError *)constraintViolation:(NSDictionary *)annotations object:(NSManagedObject *)object key:(NSString *)key
{
  NSString *constraint = @"Org.OData.Validation.V1.Constraint";
  for (NSString *term in [annotations.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (![term isEqualToString:constraint] && ![term hasPrefix:[constraint stringByAppendingString:@"#"]]) continue;
    NSDictionary *record = annotations[term];
    if (![record isKindOfClass:[NSDictionary class]]) continue;
    NSPredicate *condition = [self predicateForCondition:record[@"Condition"] entity:object.entity];
    if (!condition) continue;  // one it cannot read is the service's to check
    BOOL holds = NO;
    @try {
      holds = [condition evaluateWithObject:object];
    } @catch (NSException *exception) {
      holds = NO;
    }
    if (!holds) {
      NSString *message = [record[@"FailureMessage"] isKindOfClass:[NSString class]] ? record[@"FailureMessage"]
          : [NSString stringWithFormat:@"%@ breaks a constraint", key ?: object.entity.name];
      return OISViolation(object, key, message);
    }
  }
  return nil;
}

- (NSError *)vocabularyViolationOfObject:(NSManagedObject *)object
{
  NSEntityDescription *entity = object.entity;
  NSError *violation = [self constraintViolation:[self annotationsOfProperty:nil entity:entity] object:object key:nil];
  if (violation) return violation;
  for (NSPropertyDescription *property in entity.properties) {
    NSDictionary *annotations = [self annotationsOfProperty:property entity:entity];
    if (!annotations.count) continue;
    if ([property isKindOfClass:[NSAttributeDescription class]]) {
      id step = annotations[@"Org.OData.Validation.V1.MultipleOf"];
      id value = [object valueForKey:property.name];
      if ([step isKindOfClass:[NSNumber class]] && [value isKindOfClass:[NSNumber class]] && [step doubleValue] != 0) {
        NSDecimalNumber *v = [NSDecimalNumber decimalNumberWithDecimal:[value decimalValue]];
        NSDecimalNumber *m = [NSDecimalNumber decimalNumberWithDecimal:[step decimalValue]];
        NSDecimalNumber *quotient = [v decimalNumberByDividingBy:m];
        NSDecimalNumberHandler *whole = [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundPlain scale:0 raiseOnExactness:NO
                                                                                    raiseOnOverflow:NO raiseOnUnderflow:NO raiseOnDivideByZero:NO];
        if ([[quotient decimalNumberByRoundingAccordingToBehavior:whole] compare:quotient] != NSOrderedSame) {
          NSString *wire = [self propertyForAttribute:(NSAttributeDescription *)property];
          return OISViolation(object, property.name, [NSString stringWithFormat:@"%@ is a multiple of %@", wire, step]);
        }
      }
    }
    // A property's constraint is of its value: none while it has none (as
    // Core Data's own validation of a property; Nullable says whether it
    // may have none).
    if ([object valueForKey:property.name] == nil) continue;
    violation = [self constraintViolation:annotations object:object key:property.name];
    if (violation) return violation;
  }
  return nil;
}

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity
{
  NSString *override = entity.userInfo[ODataUserInfoEntitySet];
  if ([override isKindOfClass:[NSString class]]) return ODataSchemaSpelling(override, self.schema.entitySets);
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  NSString *set = type ? [self.schema entitySetForEntityType:type] : nil;
  if (set) return set;
  // A sub-entity lives in its super-entity's set.
  if (entity.superentity) return [self entitySetForEntity:entity.superentity];
  NSString *name = entity.name ?: @"Entity";
  if ([name hasSuffix:@"s"]) return name;
  if ([name hasSuffix:@"y"] && name.length > 1) {
    return [[name substringToIndex:name.length - 1] stringByAppendingString:@"ies"];
  }
  return [name stringByAppendingString:@"s"];
}

- (BOOL)entityIsDerivedInItsSet:(NSEntityDescription *)entity
{
  NSString *qualified = [self qualifiedTypeForEntity:entity];
  if (!qualified) return NO;
  NSString *setType = self.schema.entitySets[[self entitySetForEntity:entity]];
  if (setType) return ![setType isEqualToString:qualified];
  // No schema: a sub-entity that names its type is derived.
  return entity.superentity != nil;
}

- (NSString *)collectionPathForEntity:(NSEntityDescription *)entity
{
  NSString *set = [self entitySetForEntity:entity];
  if (![self entityIsDerivedInItsSet:entity]) return set;
  return [NSString stringWithFormat:@"%@/%@", set, [self qualifiedTypeForEntity:entity]];
}

- (NSEntityDescription *)entity:(NSEntityDescription *)entity forTypeName:(NSString *)typeName
{
  if (![typeName isKindOfClass:[NSString class]] || !typeName.length) return entity;
  NSString *name = ODataTypeNameFromControlInformation(typeName);
  if (self.schema) name = [self.schema qualifiedName:name];
  NSMutableArray *queue = [NSMutableArray arrayWithObject:entity];
  while (queue.count) {
    NSEntityDescription *candidate = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([[self qualifiedTypeForEntity:candidate] isEqualToString:name]) return candidate;
    [queue addObjectsFromArray:candidate.subentities];
  }
  return entity;
}

#pragma mark - Names

// The schema's name for a property when it differs from ours only in case
// (Id against ID): a name made from the attribute's is a guess.
- (NSString *)schemaName:(NSString *)guess inEntity:(NSEntityDescription *)entity navigation:(BOOL)navigation
{
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  if (!type) return guess;
  BOOL exists = navigation ? [self.schema navigationProperty:guess ofEntityType:type] != nil
                           : [self.schema property:guess ofEntityType:type] != nil;
  if (exists) return guess;
  for (ODataSchemaEntityType *t = type; t; t = t.baseType ? [self.schema entityTypeNamed:t.baseType] : nil) {
    NSArray *names = navigation ? t.declaredNavigationProperties.allKeys : t.declaredProperties.allKeys;
    for (NSString *name in names) {
      if ([name caseInsensitiveCompare:guess] == NSOrderedSame) return name;
    }
  }
  return guess;
}

- (NSString *)propertyForAttribute:(NSAttributeDescription *)attribute
{
  NSString *override = attribute.userInfo[ODataUserInfoProperty];
  if ([override isKindOfClass:[NSString class]]) return [self schemaName:override inEntity:attribute.entity navigation:NO];
  return [self schemaName:[self wireName:attribute.name] inEntity:attribute.entity navigation:NO];
}

- (NSString *)propertyForRelationship:(NSRelationshipDescription *)relationship
{
  NSString *override = relationship.userInfo[ODataUserInfoProperty];
  if ([override isKindOfClass:[NSString class]]) return [self schemaName:override inEntity:relationship.entity navigation:YES];
  return [self schemaName:[self wireName:relationship.name] inEntity:relationship.entity navigation:YES];
}

- (BOOL)attributeHoldsDynamicProperties:(NSAttributeDescription *)attribute
{
  id flag = attribute.userInfo[ODataUserInfoDynamicProperties];
  return [flag isEqual:@"YES"] || [flag isEqual:@YES];
}

- (NSAttributeDescription *)dynamicPropertiesAttributeOfEntity:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
    if ([self attributeHoldsDynamicProperties:attribute]) return attribute;
  }
  return nil;
}

- (BOOL)servesRelationship:(NSRelationshipDescription *)relationship
{
  if (!self.servedEntityNames) return YES;
  NSEntityDescription *root = relationship.destinationEntity;
  while (root.superentity) root = root.superentity;
  return root && [self.servedEntityNames containsObject:root.name];
}

- (BOOL)servesProperty:(NSPropertyDescription *)property
{
  // A model's userInfo holds strings: NO, false or 0.
  id served = property.userInfo[ODataUserInfoServed];
  if ([served respondsToSelector:@selector(boolValue)] && ![served boolValue]) return NO;
  if ([property isKindOfClass:[NSRelationshipDescription class]]) {
    return [self servesRelationship:(NSRelationshipDescription *)property];
  }
  return YES;
}

- (NSPropertyDescription *)propertyForWireName:(NSString *)name entity:(NSEntityDescription *)entity
{
  for (NSPropertyDescription *property in entity.properties) {
    NSString *wire = nil;
    if (![self servesProperty:property]) continue;
    if ([property isKindOfClass:[NSAttributeDescription class]]) {
      if ([self attributeHoldsDynamicProperties:(NSAttributeDescription *)property]) continue;
      wire = [self propertyForAttribute:(NSAttributeDescription *)property];
    } else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
      wire = [self propertyForRelationship:(NSRelationshipDescription *)property];
    }
    if ([wire isEqualToString:name]) return property;
  }
  return nil;
}

- (NSString *)declaredTypeForAttribute:(NSAttributeDescription *)attribute
{
  ODataSchemaEntityType *type = [self entityTypeForEntity:attribute.entity];
  if (!type) return nil;
  return [self.schema property:[self propertyForAttribute:attribute] ofEntityType:type].type;
}

#pragma mark - Keys

- (NSArray *)keyAttributesForEntity:(NSEntityDescription *)entity
{
  NSMutableArray *flagged = [NSMutableArray array];
  [entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    // gnustep-base types this block (id, id, BOOL *): no generics to narrow it.
    NSAttributeDescription *attr = obj;
    (void)key;
    id flag = attr.userInfo[ODataUserInfoKey];
    if ([flag isEqual:@"YES"] || [flag isEqual:@YES]) [flagged addObject:attr];
  }];
  if (flagged.count) return flagged;

  // The schema's key, where every part of it is an attribute.
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  NSArray *schemaKey = type ? [self.schema keyOfEntityType:type] : @[];
  if (schemaKey.count) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *wire in schemaKey) {
      for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
        if ([[self propertyForAttribute:attr] isEqualToString:wire]) {
          [found addObject:attr];
          break;
        }
      }
    }
    if (found.count == schemaKey.count) return found;
  }

  NSArray *candidates = @[ @"id", @"ID", @"Id", [NSString stringWithFormat:@"%@ID", entity.name ?: @""] ];
  for (NSString *c in candidates) {
    NSAttributeDescription *attr = entity.attributesByName[c];
    if (attr) return @[ attr ];
  }
  return @[];
}

- (NSString *)propertyPathForKeyPath:(NSString *)keyPath entity:(NSEntityDescription *)entity
{
  return [self propertyPathForKeyPath:keyPath entity:entity memberType:NULL];
}

- (NSString *)propertyPathForKeyPath:(NSString *)keyPath entity:(NSEntityDescription *)entity memberType:(NSString **)memberType
{
  if (memberType) *memberType = nil;
  NSEntityDescription *current = entity;
  NSMutableArray *mapped = [NSMutableArray array];
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  for (NSUInteger i = 0; i < parts.count; i++) {
    NSString *part = parts[i];
    NSAttributeDescription *attr = current.attributesByName[part];
    NSRelationshipDescription *rel = attr ? nil : current.relationshipsByName[part];
    if (attr && [self attributeHoldsDynamicProperties:attr]) {
      // A dynamic property: by its own name, and on into its members.
      [mapped addObjectsFromArray:[parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)]];
      break;
    }
    if (attr) {
      [mapped addObject:[self propertyForAttribute:attr]];
      if (i + 1 < parts.count) {
        NSArray *members = [parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)];
        [mapped addObject:[self memberPath:members ofType:[self.values typeNameOfAttribute:attr] memberType:memberType]];
        break;
      }
      current = nil;
    } else if (rel) {
      [mapped addObject:[self propertyForRelationship:rel]];
      current = rel.destinationEntity;
    } else {
      [mapped addObject:[self wireName:part]];
      current = nil;
    }
  }
  return [mapped componentsJoinedByString:@"/"];
}

- (NSString *)memberPath:(NSArray *)members ofType:(NSString *)typeName memberType:(NSString **)memberType
{
  NSMutableArray *mapped = [NSMutableArray array];
  NSString *type = typeName;
  for (NSString *member in members) {
    if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) type = [type substringWithRange:NSMakeRange(11, type.length - 12)];
    ODataSchemaComplexType *complex = [self.schema complexTypeNamed:type];
    ODataSchemaProperty *property = complex ? [self.schema property:member ofComplexType:complex] : nil;
    if (complex && !property) {
      NSDictionary *all = [self.schema propertiesOfComplexType:complex];
      for (NSString *name in all) {
        if ([name caseInsensitiveCompare:member] == NSOrderedSame) property = all[name];
      }
    }
    [mapped addObject:property ? property.name : [self wireName:member]];
    type = property.type;
  }
  if (memberType) *memberType = type;
  return [mapped componentsJoinedByString:@"/"];
}

- (NSString *)wireName:(NSString *)coreDataName
{
  if (self.naming == ODataPropertyNamingAsIs || coreDataName.length == 0) return coreDataName;
  NSString *first = [[coreDataName substringToIndex:1] uppercaseString];
  return [first stringByAppendingString:[coreDataName substringFromIndex:1]];
}

#pragma mark - Checking a model

// Whether an attribute of this Core Data type can hold a property of this
// Edm type.
static BOOL OISCanHold(NSAttributeType core, NSString *edm, ODataSchema *schema)
{
  // Complex values and collections: an NSDictionary or an NSArray.
  if ([edm hasPrefix:@"Collection("] || [schema complexTypeNamed:edm]) return core == NSTransformableAttributeType;
  if ([schema enumTypeNamed:edm]) {
    return core == NSStringAttributeType || core == NSInteger16AttributeType ||
           core == NSInteger32AttributeType || core == NSInteger64AttributeType;
  }
  NSArray *integers = @[ @(NSInteger16AttributeType), @(NSInteger32AttributeType), @(NSInteger64AttributeType) ];
  NSDictionary *holders = @{
    @"Edm.String": @[ @(NSStringAttributeType) ],
    @"Edm.Boolean": @[ @(NSBooleanAttributeType) ],
    @"Edm.Byte": integers,
    @"Edm.SByte": integers,
    @"Edm.Int16": integers,
    @"Edm.Int32": @[ @(NSInteger32AttributeType), @(NSInteger64AttributeType) ],
    @"Edm.Int64": @[ @(NSInteger64AttributeType) ],
    @"Edm.Decimal": @[ @(NSDecimalAttributeType), @(NSDoubleAttributeType) ],
    @"Edm.Double": @[ @(NSDoubleAttributeType), @(NSDecimalAttributeType) ],
    @"Edm.Single": @[ @(NSFloatAttributeType), @(NSDoubleAttributeType), @(NSDecimalAttributeType) ],
    @"Edm.DateTimeOffset": @[ @(NSDateAttributeType) ],
    @"Edm.Date": @[ @(NSDateAttributeType) ],
    @"Edm.TimeOfDay": @[ @(NSStringAttributeType) ],
    @"Edm.Duration": @[ @(NSDoubleAttributeType) ],
    @"Edm.Guid": @[ @(NSUUIDAttributeType), @(NSStringAttributeType) ],
    @"Edm.Binary": @[ @(NSBinaryDataAttributeType) ],
  };
  NSArray *allowed = holders[edm];
  return allowed ? [allowed containsObject:@(core)] : NO;
}

static NSString *OISJoinedSorted(NSSet *names)
{
  return [[names.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}

- (NSArray *)problemsWithModel:(NSManagedObjectModel *)model
{
  return [self problemsWithModel:model configuration:nil];
}

// OData.entitySet and OData.property overrides that are no OData
// identifier: the expression builders refuse them (ODataExpression.h), so
// each request naming one fails.
static void OISAddNameProblems(NSArray<NSEntityDescription *> *entities, NSMutableArray *problems)
{
  for (NSEntityDescription *entity in entities) {
    id set = entity.userInfo[ODataUserInfoEntitySet];
    if ([set isKindOfClass:[NSString class]] && !ODataIsIdentifier(set)) {
      [problems addObject:[NSString stringWithFormat:@"%@: its %@ \"%@\" is no OData identifier", entity.name, ODataUserInfoEntitySet, set]];
    }
    for (NSPropertyDescription *property in [entity.properties sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ]]) {
      id name = property.userInfo[ODataUserInfoProperty];
      if ([name isKindOfClass:[NSString class]] && !ODataIsIdentifier(name)) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: its %@ \"%@\" is no OData identifier", entity.name, property.name,
                                                       ODataUserInfoProperty, name]];
      }
    }
  }
}

- (NSArray *)problemsWithModel:(NSManagedObjectModel *)model configuration:(NSString *)configuration
{
  NSMutableArray *problems = [NSMutableArray array];
  NSArray *all = configuration ? [model entitiesForConfiguration:configuration] ?: @[] : model.entities;
  NSSet *checked = [NSSet setWithArray:all];
  NSArray *entities = [all sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a name] compare:[b name]];
  }];
  OISAddNameProblems(entities, problems);
  if (!self.schema) return problems;
  for (NSEntityDescription *entity in entities) {
    ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
    if (!type) {
      [problems addObject:[NSString stringWithFormat:@"%@: no entity type %@ in $metadata", entity.name,
                                                     [self qualifiedTypeForEntity:entity] ?: entity.name]];
      continue;
    }
    NSString *set = [self entitySetForEntity:entity];
    ODataSchemaEntityType *setType = [self.schema entityTypeNamed:self.schema.entitySets[set] ?: @""];
    if (!setType) {
      // A contained entity has no set; its container's navigation reaches it.
      if (![self.schema entityTypeIsContained:type]) {
        [problems addObject:[NSString stringWithFormat:@"%@: no entity set %@", entity.name, set]];
      }
    } else if (![self.schema entityType:type isOrDerivesFrom:setType]) {
      [problems addObject:[NSString stringWithFormat:@"%@: entity set %@ holds %@, not %@", entity.name, set,
                                                     setType.qualifiedName, type.qualifiedName]];
    }

    // What a sub-entity inherits is checked where it is declared.
    NSEntityDescription *parent = entity.superentity;
    for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      NSAttributeDescription *attr = entity.attributesByName[name];
      if (attr.isTransient || parent.attributesByName[name] || ![self servesProperty:attr]) continue;
      if ([self attributeHoldsDynamicProperties:attr]) {
        if (![self.schema entityTypeIsOpen:type]) {
          [problems addObject:[NSString stringWithFormat:@"%@.%@: dynamic properties, but %@ is not an open type", entity.name, name, type.qualifiedName]];
        }
        continue;
      }
      NSString *wire = [self propertyForAttribute:attr];
      ODataSchemaProperty *property = [self.schema property:wire ofEntityType:type];
      if (!property) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: no property %@ in %@", entity.name, name, wire, type.qualifiedName]];
      } else if (![attr.userInfo[ODataUserInfoType] isKindOfClass:[NSString class]] &&
                 !OISCanHold(attr.attributeType, property.type, self.schema)) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: %@ is %@, which this attribute cannot hold",
                                                       entity.name, name, wire, property.type]];
      }
    }

    NSMutableSet *ours = [NSMutableSet set];
    for (NSAttributeDescription *attr in [self keyAttributesForEntity:entity]) [ours addObject:[self propertyForAttribute:attr]];
    NSSet *theirs = [NSSet setWithArray:[self.schema keyOfEntityType:type]];
    if (theirs.count && ![ours isEqualToSet:theirs]) {
      [problems addObject:[NSString stringWithFormat:@"%@: key %@, but %@ is keyed by %@", entity.name,
                                                     OISJoinedSorted(ours), type.qualifiedName, OISJoinedSorted(theirs)]];
    }

    for (NSString *name in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      NSRelationshipDescription *rel = entity.relationshipsByName[name];
      if (parent.relationshipsByName[name] || ![self servesProperty:rel]) continue;
      // One out of the configuration leads to what the service does not serve.
      if (configuration && ![checked containsObject:rel.destinationEntity]) continue;
      NSString *wire = [self propertyForRelationship:rel];
      ODataSchemaNavigationProperty *navigation = [self.schema navigationProperty:wire ofEntityType:type];
      if (!navigation) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: no navigation property %@ in %@", entity.name, name, wire, type.qualifiedName]];
      } else if (navigation.isCollection != rel.isToMany) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: %@ is %@, the relationship %@", entity.name, name, wire,
                                                       navigation.isCollection ? @"a collection" : @"single-valued",
                                                       rel.isToMany ? @"to-many" : @"to-one"]];
      }
    }
  }
  return problems;
}

@end
