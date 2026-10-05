// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataMetadataWriter.h"
#import <ODataKit/ODataXML.h>
#import "ODataValue.h"
#import <ODataKit/ODataRegex.h>

// An element with these attributes, in this order: name, value, name,
// value. NSXML escapes what it writes.
static ODataXMLElement *OISElement(NSString *name, NSArray *attributes)
{
  ODataXMLElement *element = [[ODataXMLElement alloc] initWithName:name];
  for (NSUInteger i = 0; i + 1 < attributes.count; i += 2) {
    [element addAttribute:[ODataXMLNode attributeWithName:attributes[i] stringValue:[attributes[i + 1] description]]];
  }
  return element;
}

static ODataXMLElement *OISTextElement(NSString *name, NSString *text)
{
  ODataXMLElement *element = [[ODataXMLElement alloc] initWithName:name];
  element.stringValue = text;
  return element;
}

static NSString *OISNamespaceOf(NSString *qualified)
{
  NSRange dot = [qualified rangeOfString:@"." options:NSBackwardsSearch];
  return dot.location == NSNotFound ? @"" : [qualified substringToIndex:dot.location];
}

static NSString *OISSimpleNameOf(NSString *qualified)
{
  NSRange dot = [qualified rangeOfString:@"." options:NSBackwardsSearch];
  return dot.location == NSNotFound ? qualified : [qualified substringFromIndex:dot.location + 1];
}

static NSString *OISElementTypeOf(NSString *type)
{
  if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) {
    return [type substringWithRange:NSMakeRange(11, type.length - 12)];
  }
  return type;
}

@interface ODataMetadataWriter ()
// The vocabularies the document's annotations use, to reference.
@property (nonatomic, strong) NSMutableSet<NSString *> *vocabularies;
@end

@implementation ODataMetadataWriter {
  NSMutableArray<NSString *> *_problems;
}

- (instancetype)initWithModel:(NSManagedObjectModel *)model mapper:(ODataPropertyMapper *)mapper
{
  self = [super init];
  if (!self) return nil;
  _model = model;
  _mapper = mapper;
  _namespaceName = @"Default";
  _containerName = @"Container";
  return self;
}

- (NSArray *)problems
{
  if (!_problems) [self XMLStringForVersion:@"4.01"];
  return [_problems copy];
}

#pragma mark - Types

NSString * const ODataUserInfoStream = @"OData.stream";
NSString * const ODataUserInfoMediaStream = @"OData.mediaStream";
NSString * const ODataUserInfoContentType = @"OData.contentType";

static BOOL OISYes(id value)
{
  return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

- (NSAttributeDescription *)mediaAttributeOfEntity:(NSEntityDescription *)entity
{
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    id name = e.userInfo[ODataUserInfoMediaStream];
    if ([name isKindOfClass:[NSString class]]) {
      NSAttributeDescription *attribute = entity.attributesByName[name];
      return attribute.attributeType == NSBinaryDataAttributeType ? attribute : nil;
    }
  }
  return nil;
}

- (BOOL)isStreamAttribute:(NSAttributeDescription *)attribute
{
  return attribute.attributeType == NSBinaryDataAttributeType && OISYes(attribute.userInfo[ODataUserInfoStream]);
}

- (NSAttributeDescription *)contentTypeAttributeOfStream:(NSAttributeDescription *)stream
{
  id name = stream.userInfo[ODataUserInfoContentType];
  NSAttributeDescription *attribute = [name isKindOfClass:[NSString class]] ? stream.entity.attributesByName[name] : nil;
  return attribute.attributeType == NSStringAttributeType ? attribute : nil;
}

// A media resource, or where a stream's content type is kept: part of a
// stream, not a property.
- (BOOL)isPartOfStream:(NSAttributeDescription *)attribute
{
  NSEntityDescription *entity = attribute.entity;
  NSAttributeDescription *media = [self mediaAttributeOfEntity:entity];
  if ([media.name isEqualToString:attribute.name]) return YES;
  if ([[self contentTypeAttributeOfStream:media].name isEqualToString:attribute.name]) return YES;
  for (NSAttributeDescription *other in entity.attributesByName.allValues) {
    if ([self isStreamAttribute:other] && [[self contentTypeAttributeOfStream:other].name isEqualToString:attribute.name]) return YES;
  }
  return NO;
}

- (NSString *)typeNameForAttribute:(NSAttributeDescription *)attribute
{
  if (attribute.isTransient) return nil;
  if (![self.mapper servesProperty:attribute]) return nil;
  if ([self.mapper attributeHoldsDynamicProperties:attribute]) return nil;  // its entries are properties, it is none
  if ([self isPartOfStream:attribute]) return nil;
  if ([self isStreamAttribute:attribute]) return @"Edm.Stream";
  NSString *declared = attribute.userInfo[ODataUserInfoType];
  if ([declared isKindOfClass:[NSString class]] && declared.length) return declared;
  switch (attribute.attributeType) {
    case NSInteger16AttributeType: return @"Edm.Int16";
    case NSInteger32AttributeType: return @"Edm.Int32";
    case NSInteger64AttributeType: return @"Edm.Int64";
    case NSDecimalAttributeType: return @"Edm.Decimal";
    case NSDoubleAttributeType: return @"Edm.Double";
    case NSFloatAttributeType: return @"Edm.Single";
    case NSStringAttributeType: return @"Edm.String";
    case NSBooleanAttributeType: return @"Edm.Boolean";
    case NSDateAttributeType: return @"Edm.DateTimeOffset";
    case NSBinaryDataAttributeType: return @"Edm.Binary";
    default: break;
  }
  if (attribute.attributeType == NSUUIDAttributeType) return @"Edm.Guid";
  if (attribute.attributeType == NSURIAttributeType) return @"Edm.String";
  return nil;
}

- (NSString *)typeNameForEntity:(NSEntityDescription *)entity
{
  return [self.mapper qualifiedTypeForEntity:entity] ?: [NSString stringWithFormat:@"%@.%@", self.namespaceName, entity.name];
}

- (NSEntityDescription *)rootOf:(NSEntityDescription *)entity
{
  while (entity.superentity) entity = entity.superentity;
  return entity;
}

// Whether the entity is written: its root has a key, and is among
// entityNames when they are given.
- (BOOL)writes:(NSEntityDescription *)entity
{
  NSEntityDescription *root = [self rootOf:entity];
  if (self.entityNames && ![self.entityNames containsObject:root.name]) return NO;
  return [self.mapper keyAttributesForEntity:root].count > 0;
}

- (NSArray *)entities
{
  NSMutableArray *entities = [NSMutableArray array];
  for (NSEntityDescription *entity in self.model.entities) {
    if ([self writes:entity]) [entities addObject:entity];
  }
  return entities;
}

// The properties an entity declares itself, not those it inherits.
- (NSArray<NSPropertyDescription *> *)declaredProperties:(NSEntityDescription *)entity
{
  NSDictionary *inherited = entity.superentity.propertiesByName ?: @{};
  NSMutableArray *declared = [NSMutableArray array];
  for (NSPropertyDescription *property in entity.properties) {
    if (!inherited[property.name] && [self.mapper servesProperty:property]) [declared addObject:property];
  }
  return declared;
}

#pragma mark - Annotations


static NSString * const OISCore = @"Org.OData.Core.V1";
static NSString * const OISValidation = @"Org.OData.Validation.V1";

static BOOL OISIsTrue(id value)
{
  return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

// A JSON CSDL value as a CSDL XML expression.
- (ODataXMLElement *)expression:(id)value
{
  if (!value || value == [NSNull null]) return OISElement(@"Null", nil);
  if ([value isKindOfClass:[@YES class]]) return OISTextElement(@"Bool", [value boolValue] ? @"true" : @"false");
  if ([value isKindOfClass:[NSDecimalNumber class]]) return OISTextElement(@"Decimal", [value stringValue]);
  if ([value isKindOfClass:[NSNumber class]]) {
    const char *type = [value objCType];
    BOOL real = type && (type[0] == 'd' || type[0] == 'f');
    return real ? OISTextElement(@"Float", [NSString stringWithFormat:@"%.17g", [value doubleValue]])
                : OISTextElement(@"Int", [NSString stringWithFormat:@"%lld", [value longLongValue]]);
  }
  if ([value isKindOfClass:[NSDate class]]) return OISTextElement(@"DateTimeOffset", ODataDateTimeOffsetString(value));
  if ([value isKindOfClass:[NSString class]]) return OISTextElement(@"String", value);
  if ([value isKindOfClass:[NSArray class]]) {
    ODataXMLElement *collection = OISElement(@"Collection", nil);
    for (id item in value) [collection addChild:[self expression:item]];
    return collection;
  }
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dictionary = value;
    // {"$Path": "..."}, {"$EnumMember": "..."}, {"$If": [...]}: an
    // expression, its other $ members its attributes.
    NSString *expression = nil;
    for (NSString *key in dictionary) {
      if ([key hasPrefix:@"$"] && ([dictionary[key] isKindOfClass:[NSArray class]] || [dictionary[key] isKindOfClass:[NSString class]])) {
        if (!expression || [dictionary[key] isKindOfClass:[NSArray class]]) expression = key;
      }
    }
    if (expression) {
      NSMutableArray *attributes = [NSMutableArray array];
      for (NSString *key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([key isEqualToString:expression] || ![key hasPrefix:@"$"]) continue;
        [attributes addObject:[key substringFromIndex:1]];
        [attributes addObject:[dictionary[key] description]];
      }
      ODataXMLElement *element = OISElement([expression substringFromIndex:1], attributes);
      id operand = dictionary[expression];
      if ([operand isKindOfClass:[NSArray class]]) {
        for (id item in operand) [element addChild:[self expression:item]];
      } else {
        element.stringValue = operand;
      }
      return element;
    }
    ODataXMLElement *record = OISElement(@"Record", nil);
    if ([dictionary[@"@type"] isKindOfClass:[NSString class]]) {
      [record addAttribute:[ODataXMLNode attributeWithName:@"Type" stringValue:dictionary[@"@type"]]];
      [self useTerm:dictionary[@"@type"]];
    }
    for (NSString *key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([key hasPrefix:@"@"]) continue;
      ODataXMLElement *propertyValue = OISElement(@"PropertyValue", @[ @"Property", key ]);
      [propertyValue addChild:[self expression:dictionary[key]]];
      [record addChild:propertyValue];
    }
    return record;
  }
  return OISTextElement(@"String", [value description]);
}

// A term's vocabulary, to reference.
- (void)useTerm:(NSString *)term
{
  NSRange dot = [term rangeOfString:@"." options:NSBackwardsSearch];
  if (dot.location != NSNotFound) [self.vocabularies addObject:[term substringToIndex:dot.location]];
}

// Capabilities.PermissionType records: one, under the security scheme,
// any of whose scopes is enough.
- (NSArray *)permissionsOf:(NSSet<NSString *> *)scopes
{
  NSMutableArray *granted = [NSMutableArray array];
  for (NSString *scope in [scopes.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
    [granted addObject:@{ @"Scope": scope }];
  }
  return @[ @{ @"SchemeName": self.securitySchemeName ?: @"Default", @"Scopes": granted } ];
}

// Annotation elements: by term (Term#Qualifier), a term's own annotations
// inside it (Term@Term), as JSON CSDL keys them.
- (NSArray<ODataXMLElement *> *)annotations:(NSDictionary<NSString *, id> *)annotations
{
  NSMutableArray *elements = [NSMutableArray array];
  for (NSString *key in [annotations.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([key rangeOfString:@"@"].location != NSNotFound) continue;
    NSRange hash = [key rangeOfString:@"#"];
    NSString *term = hash.location == NSNotFound ? key : [key substringToIndex:hash.location];
    [self useTerm:term];
    ODataXMLElement *annotation = hash.location == NSNotFound
        ? OISElement(@"Annotation", @[ @"Term", term ])
        : OISElement(@"Annotation", @[ @"Term", term, @"Qualifier", [key substringFromIndex:hash.location + 1] ]);
    [annotation addChild:[self expression:annotations[key]]];
    NSString *prefix = [key stringByAppendingString:@"@"];
    NSMutableDictionary *nested = [NSMutableDictionary dictionary];
    for (NSString *other in annotations) {
      if ([other hasPrefix:prefix]) nested[[other substringFromIndex:prefix.length]] = annotations[other];
    }
    for (ODataXMLElement *inner in [self annotations:nested]) [annotation addChild:inner];
    [elements addObject:annotation];
  }
  return elements;
}

static void OISAddChildren(ODataXMLElement *parent, NSArray<ODataXMLElement *> *children)
{
  for (ODataXMLElement *child in children) [parent addChild:child];
}

// What userInfo says of an entity or a property: Core's description and
// flags, and anything in OData.annotations (a dictionary, or JSON of one).
- (NSMutableDictionary *)annotationsFromUserInfo:(NSDictionary *)userInfo
{
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  NSString *description = userInfo[ODataUserInfoDescription];
  if ([description isKindOfClass:[NSString class]]) annotations[[OISCore stringByAppendingString:@".Description"]] = description;
  NSString *longDescription = userInfo[ODataUserInfoLongDescription];
  if ([longDescription isKindOfClass:[NSString class]]) annotations[[OISCore stringByAppendingString:@".LongDescription"]] = longDescription;
  if (OISIsTrue(userInfo[ODataUserInfoComputed])) annotations[[OISCore stringByAppendingString:@".Computed"]] = @YES;
  if (OISIsTrue(userInfo[ODataUserInfoImmutable])) annotations[[OISCore stringByAppendingString:@".Immutable"]] = @YES;
  NSString *permissions = userInfo[ODataUserInfoPermissions];
  if ([permissions isKindOfClass:[NSString class]]) {
    annotations[[OISCore stringByAppendingString:@".Permissions"]] = @{ @"$EnumMember": [NSString stringWithFormat:@"Org.OData.Core.V1.Permission/%@", permissions] };
  }
  NSString *measures = @"Org.OData.Measures.V1.";
  if ([userInfo[ODataUserInfoUnit] isKindOfClass:[NSString class]]) annotations[[measures stringByAppendingString:@"Unit"]] = userInfo[ODataUserInfoUnit];
  if (userInfo[ODataUserInfoScale]) annotations[[measures stringByAppendingString:@"Scale"]] = @([userInfo[ODataUserInfoScale] integerValue]);
  id more = userInfo[ODataUserInfoAnnotations];
  if ([more isKindOfClass:[NSString class]]) {
    more = [NSJSONSerialization JSONObjectWithData:[more dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
  }
  if ([more isKindOfClass:[NSDictionary class]]) {
    for (NSString *term in more) annotations[[self fullTerm:term]] = more[term];
  }
  return annotations;
}

// Core.Description as Org.OData.Core.V1.Description; a term of a namespace
// of its own as it is.
- (NSString *)fullTerm:(NSString *)term
{
  return [[self class] fullTerm:term];
}

+ (NSString *)fullTerm:(NSString *)term
{
  NSArray *parts = [term componentsSeparatedByString:@"@"];
  NSMutableArray *full = [NSMutableArray array];
  for (NSString *part in parts) {
    NSRange dot = [part rangeOfString:@"."];
    NSString *head = dot.location == NSNotFound ? nil : [part substringToIndex:dot.location];
    BOOL standard = head && [@[ @"Core", @"Validation", @"Capabilities", @"Authorization", @"Measures", @"Aggregation", @"JSON", @"Repeatability", @"Temporal" ] containsObject:head] &&
                    [[part substringFromIndex:dot.location + 1] rangeOfString:@"."].location == NSNotFound;
    [full addObject:standard ? [NSString stringWithFormat:@"Org.OData.%@.V1%@", head, [part substringFromIndex:dot.location]] : part];
  }
  return [full componentsJoinedByString:@"@"];
}

// An attribute's: Computed for a derived one, or the version the service
// increments; Validation from the model's own validation predicates (as
// Xcode and FreeCoreData's momc write a minimum, a maximum, a length, a
// pattern: SELF >= 1, length <= 50, SELF MATCHES "..."); then userInfo.
// The length is the property's MaxLength, not an annotation.
- (NSMutableDictionary *)annotationsOfAttribute:(NSAttributeDescription *)attribute maxLength:(NSNumber **)maxLength
{
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  Class derived = NSClassFromString(@"NSDerivedAttributeDescription");
  BOOL version = [[self.concurrencyAttributes allValues] containsObject:attribute];
  if ((derived && [attribute isKindOfClass:derived]) || version) annotations[[OISCore stringByAppendingString:@".Computed"]] = @YES;
  NSString *minimum = [OISValidation stringByAppendingString:@".Minimum"];
  NSString *maximum = [OISValidation stringByAppendingString:@".Maximum"];
  NSString *exclusive = [OISValidation stringByAppendingString:@".Exclusive"];
  for (NSPredicate *predicate in attribute.validationPredicates) {
    if (![predicate isKindOfClass:[NSComparisonPredicate class]]) continue;
    NSComparisonPredicate *comparison = (NSComparisonPredicate *)predicate;
    NSExpression *left = comparison.leftExpression, *right = comparison.rightExpression;
    if (right.expressionType != NSConstantValueExpressionType) continue;
    id constant = right.constantValue;
    NSString *keyPath = left.expressionType == NSKeyPathExpressionType ? left.keyPath : nil;
    BOOL itself = left.expressionType == NSEvaluatedObjectExpressionType || [keyPath isEqualToString:@"self"] || [keyPath isEqualToString:@"SELF"];
    if ([keyPath isEqualToString:@"timeIntervalSinceReferenceDate"] && [constant isKindOfClass:[NSNumber class]]) {
      itself = YES;
      constant = [NSDate dateWithTimeIntervalSinceReferenceDate:[constant doubleValue]];
    }
    NSPredicateOperatorType type = comparison.predicateOperatorType;
    if ([keyPath isEqualToString:@"length"] && [constant isKindOfClass:[NSNumber class]]) {
      if (type == NSLessThanOrEqualToPredicateOperatorType && maxLength) *maxLength = constant;
      if (type == NSLessThanPredicateOperatorType && maxLength) *maxLength = @([constant longLongValue] - 1);
      continue;
    }
    if (!itself) continue;
    switch (type) {
      case NSGreaterThanOrEqualToPredicateOperatorType: annotations[minimum] = constant; break;
      case NSGreaterThanPredicateOperatorType:
        annotations[minimum] = constant;
        annotations[[NSString stringWithFormat:@"%@@%@", minimum, exclusive]] = @YES;
        break;
      case NSLessThanOrEqualToPredicateOperatorType: annotations[maximum] = constant; break;
      case NSLessThanPredicateOperatorType:
        annotations[maximum] = constant;
        annotations[[NSString stringWithFormat:@"%@@%@", maximum, exclusive]] = @YES;
        break;
      case NSMatchesPredicateOperatorType: {
        // MATCHES is of the whole string, and ICU's; Validation.Pattern is
        // ECMAScript's. Where ECMAScript cannot say the same, nothing is
        // said: the service still checks it (ODataRegex.h).
        ODataRegex *regex = [constant isKindOfClass:[NSString class]] ? [ODataRegex regexWithString:constant dialect:ODataRegexMatches error:NULL] : nil;
        NSString *pattern = [[regex whole] stringInDialect:ODataRegexECMAScript error:NULL];
        if (pattern) annotations[[OISValidation stringByAppendingString:@".Pattern"]] = pattern;
        break;
      }
      case NSInPredicateOperatorType: {
        id values = [constant isKindOfClass:[NSSet class]] ? [constant allObjects] : constant;
        if (![values isKindOfClass:[NSArray class]]) break;
        NSMutableArray *allowed = [NSMutableArray array];
        for (id value in values) [allowed addObject:@{ @"Value": value }];
        annotations[[OISValidation stringByAppendingString:@".AllowedValues"]] = allowed;
        break;
      }
      default:
        break;
    }
  }
  [annotations addEntriesFromDictionary:[self annotationsFromUserInfo:attribute.userInfo]];
  // An amount's currency: a code, or the attribute that holds one, as a path.
  id currency = attribute.userInfo[ODataUserInfoISOCurrency];
  if ([currency isKindOfClass:[NSString class]]) {
    NSAttributeDescription *holder = attribute.entity.attributesByName[currency];
    if (holder && ![self.mapper servesProperty:holder]) {
      [_problems addObject:[NSString stringWithFormat:@"%@.%@: its currency is in %@, which is not served", attribute.entity.name, attribute.name, holder.name]];
    } else {
      annotations[@"Org.OData.Measures.V1.ISOCurrency"] = holder ? @{ @"$Path": [self.mapper propertyForAttribute:holder] } : currency;
    }
  }
  return annotations;
}

- (NSMutableDictionary *)annotationsOfRelationship:(NSRelationshipDescription *)relationship
{
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  if (relationship.isToMany && relationship.minCount > 0) annotations[[OISValidation stringByAppendingString:@".MinItems"]] = @(relationship.minCount);
  if (relationship.isToMany && relationship.maxCount > 0) annotations[[OISValidation stringByAppendingString:@".MaxItems"]] = @(relationship.maxCount);
  [annotations addEntriesFromDictionary:[self annotationsFromUserInfo:relationship.userInfo]];
  return annotations;
}

#pragma mark - Writing

- (void)append:(ODataXMLElement *)element toNamespace:(NSString *)ns in:(NSMutableDictionary<NSString *, NSMutableArray *> *)schemas
{
  if (!schemas[ns]) schemas[ns] = [NSMutableArray array];
  [schemas[ns] addObject:element];
}

- (ODataXMLElement *)propertyNamed:(NSString *)name type:(NSString *)type nullable:(BOOL)nullable
                      maxLength:(NSNumber *)maxLength annotations:(NSDictionary *)annotations
{
  ODataXMLElement *property = OISElement(@"Property", @[ @"Name", name, @"Type", type ]);
  if (!nullable) [property addAttribute:[ODataXMLNode attributeWithName:@"Nullable" stringValue:@"false"]];
  if ([OISElementTypeOf(type) isEqualToString:@"Edm.Decimal"]) [property addAttribute:[ODataXMLNode attributeWithName:@"Scale" stringValue:@"variable"]];
  if (maxLength && [OISElementTypeOf(type) isEqualToString:@"Edm.String"]) {
    [property addAttribute:[ODataXMLNode attributeWithName:@"MaxLength" stringValue:[NSString stringWithFormat:@"%lld", maxLength.longLongValue]]];
  }
  OISAddChildren(property, [self annotations:annotations ?: @{}]);
  return property;
}

- (void)writeEntity:(NSEntityDescription *)entity into:(NSMutableDictionary *)schemas used:(NSMutableSet *)usedTypes
{
  NSString *qualified = [self typeNameForEntity:entity];
  ODataXMLElement *type = OISElement(@"EntityType", @[ @"Name", OISSimpleNameOf(qualified) ]);
  if (entity.superentity) [type addAttribute:[ODataXMLNode attributeWithName:@"BaseType" stringValue:[self typeNameForEntity:entity.superentity]]];
  if (entity.isAbstract) [type addAttribute:[ODataXMLNode attributeWithName:@"Abstract" stringValue:@"true"]];
  if ([self.openEntityNames containsObject:[self rootOf:entity].name]) {
    [type addAttribute:[ODataXMLNode attributeWithName:@"OpenType" stringValue:@"true"]];
  }
  if ([self mediaAttributeOfEntity:entity] && (!entity.superentity || ![self mediaAttributeOfEntity:entity.superentity])) {
    [type addAttribute:[ODataXMLNode attributeWithName:@"HasStream" stringValue:@"true"]];
  }
  OISAddChildren(type, [self annotations:[self annotationsFromUserInfo:entity.userInfo]]);

  NSArray *key = entity.superentity ? @[] : [self.mapper keyAttributesForEntity:entity];
  if (key.count) {
    ODataXMLElement *keyElement = OISElement(@"Key", nil);
    for (NSAttributeDescription *attr in key) {
      if (![self.mapper servesProperty:attr]) {
        [_problems addObject:[NSString stringWithFormat:@"%@.%@ is the key, which OData.served cannot leave out", entity.name, attr.name]];
      }
      [keyElement addChild:OISElement(@"PropertyRef", @[ @"Name", [self.mapper propertyForAttribute:attr] ])];
    }
    [type addChild:keyElement];
  }
  for (NSPropertyDescription *property in [self declaredProperties:entity]) {
    if ([property isKindOfClass:[NSAttributeDescription class]]) {
      NSAttributeDescription *attr = (NSAttributeDescription *)property;
      NSString *edm = [self typeNameForAttribute:attr];
      if (!edm) {
        if (!attr.isTransient && ![self isPartOfStream:attr] && ![self.mapper attributeHoldsDynamicProperties:attr]) {
          [_problems addObject:[NSString stringWithFormat:@"%@.%@ has no Edm type: give it an OData.type", entity.name, attr.name]];
        }
        continue;
      }
      NSString *element = OISElementTypeOf(edm);
      if ([element isEqualToString:@"Org.OData.JSON.V1.JSON"]) {
        [self useTerm:element];  // JSON values (the JSON vocabulary), referenced
      } else if (![element hasPrefix:@"Edm."]) {
        if (!self.mapper.schema.complexTypes[element] && !self.mapper.schema.enumTypes[element]) {
          [_problems addObject:[NSString stringWithFormat:@"%@.%@ is a %@, which no schema defines", entity.name, attr.name, element]];
          continue;
        }
        [usedTypes addObject:element];
      }
      BOOL nullable = attr.isOptional && ![key containsObject:attr];
      NSNumber *maxLength = nil;
      NSDictionary *annotations = [self annotationsOfAttribute:attr maxLength:&maxLength];
      [type addChild:[self propertyNamed:[self.mapper propertyForAttribute:attr] type:edm nullable:nullable
                               maxLength:maxLength annotations:annotations]];
    } else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
      NSRelationshipDescription *rel = (NSRelationshipDescription *)property;
      NSEntityDescription *target = rel.destinationEntity;
      if (!target || ![self writes:target]) continue;
      NSString *targetType = [self typeNameForEntity:target];
      NSString *navigationType = rel.isToMany ? [NSString stringWithFormat:@"Collection(%@)", targetType] : targetType;
      ODataXMLElement *navigation = OISElement(@"NavigationProperty", @[ @"Name", [self.mapper propertyForRelationship:rel], @"Type", navigationType ]);
      if (!rel.isToMany && !rel.isOptional) [navigation addAttribute:[ODataXMLNode attributeWithName:@"Nullable" stringValue:@"false"]];
      if (rel.inverseRelationship && [self.mapper servesProperty:rel.inverseRelationship]) {
        [navigation addAttribute:[ODataXMLNode attributeWithName:@"Partner" stringValue:[self.mapper propertyForRelationship:rel.inverseRelationship]]];
      }
      OISAddChildren(navigation, [self annotations:[self annotationsOfRelationship:rel]]);
      [type addChild:navigation];
    }
  }
  [self append:type toNamespace:OISNamespaceOf(qualified) in:schemas];
}

// Complex types and enumerations the entities use, copied from the
// mapper's schema, with the types they use in turn.
- (void)writeSchemaTypes:(NSMutableSet *)used into:(NSMutableDictionary *)schemas
{
  ODataSchema *schema = self.mapper.schema;
  NSMutableSet *written = [NSMutableSet set];
  NSMutableArray *queue = [[used allObjects] mutableCopy];
  [queue sortUsingSelector:@selector(compare:)];
  while (queue.count) {
    NSString *name = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([written containsObject:name]) continue;
    [written addObject:name];
    ODataSchemaEnumType *enumType = schema.enumTypes[name];
    if (enumType) {
      ODataXMLElement *element = OISElement(@"EnumType", @[ @"Name", enumType.name ]);
      if (enumType.isFlags) [element addAttribute:[ODataXMLNode attributeWithName:@"IsFlags" stringValue:@"true"]];
      for (NSString *member in enumType.memberNames) {
        [element addChild:OISElement(@"Member", @[ @"Name", member, @"Value", enumType.values[member] ])];
      }
      [self append:element toNamespace:OISNamespaceOf(name) in:schemas];
      continue;
    }
    ODataSchemaComplexType *complex = schema.complexTypes[name];
    if (!complex) continue;
    ODataXMLElement *element = OISElement(@"ComplexType", @[ @"Name", complex.name ]);
    if (complex.baseType) {
      [element addAttribute:[ODataXMLNode attributeWithName:@"BaseType" stringValue:complex.baseType]];
      [queue addObject:complex.baseType];
    }
    if (complex.isAbstract) [element addAttribute:[ODataXMLNode attributeWithName:@"Abstract" stringValue:@"true"]];
    if (complex.isOpen) [element addAttribute:[ODataXMLNode attributeWithName:@"OpenType" stringValue:@"true"]];
    for (NSString *propertyName in [complex.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *p = complex.declaredProperties[propertyName];
      [element addChild:[self propertyNamed:p.name type:p.type nullable:p.nullable maxLength:nil annotations:nil]];
      if (![p.elementType hasPrefix:@"Edm."]) [queue addObject:p.elementType];
    }
    [self append:element toNamespace:OISNamespaceOf(name) in:schemas];
  }
}

- (ODataXMLElement *)container
{
  ODataXMLElement *container = OISElement(@"EntityContainer", @[ @"Name", self.containerName ]);
  NSArray *entities = self.entities;
  for (NSEntityDescription *entity in entities) {
    if (entity.superentity) continue;
    ODataXMLElement *set = OISElement(@"EntitySet", @[ @"Name", [self.mapper entitySetForEntity:entity], @"EntityType", [self typeNameForEntity:entity] ]);
    // Its own relationships, and those of its derived types by a cast.
    for (NSEntityDescription *member in entities) {
      if ([self rootOf:member] != entity) continue;
      NSString *cast = member == entity ? @"" : [[self typeNameForEntity:member] stringByAppendingString:@"/"];
      for (NSPropertyDescription *property in [self declaredProperties:member]) {
        if (![property isKindOfClass:[NSRelationshipDescription class]]) continue;
        NSRelationshipDescription *rel = (NSRelationshipDescription *)property;
        if (!rel.destinationEntity || ![entities containsObject:rel.destinationEntity]) continue;
        [set addChild:OISElement(@"NavigationPropertyBinding", @[
          @"Path", [cast stringByAppendingString:[self.mapper propertyForRelationship:rel]],
          @"Target", [self.mapper entitySetForEntity:[self rootOf:rel.destinationEntity]] ])];
      }
    }
    NSString *setName = [self.mapper entitySetForEntity:entity];
    NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
    NSDictionary *permissions = self.permissions[setName];
    if ([permissions[@"Read"] count]) {
      annotations[@"Org.OData.Capabilities.V1.ReadRestrictions"] = @{ @"Permissions": [self permissionsOf:permissions[@"Read"]] };
    }
    for (NSString *restriction in @[ @"Insert", @"Update", @"Delete" ]) {
      NSMutableDictionary *record = [NSMutableDictionary dictionary];
      if ([permissions[restriction] count] && ![self.restrictions[setName] containsObject:restriction]) {
        record[@"Permissions"] = [self permissionsOf:permissions[restriction]];
      }
      if ([self.restrictions[setName] containsObject:restriction]) {
        NSString *property = [@{ @"Insert": @"Insertable", @"Update": @"Updatable", @"Delete": @"Deletable" } objectForKey:restriction];
        record[property] = @NO;
      } else if (![restriction isEqualToString:@"Insert"]) {
        // Collection/$each, after $filter(...) and cast segments; and for
        // updates, PATCH of a collection with a delta payload.
        record[@"FilterSegmentSupported"] = @YES;
        record[@"TypecastSegmentSupported"] = @YES;
        if ([restriction isEqualToString:@"Update"]) record[@"DeltaUpdateSupported"] = @YES;
        if ([restriction isEqualToString:@"Update"] && ![self.restrictions[setName] containsObject:@"Upsert"]) record[@"Upsertable"] = @YES;
      }
      if (record.count) annotations[[NSString stringWithFormat:@"Org.OData.Capabilities.V1.%@Restrictions", restriction]] = record;
    }
    NSAttributeDescription *concurrency = self.concurrencyAttributes[entity.name];
    // One not served still makes the ETag; the annotation names none.
    if (concurrency && [self.mapper servesProperty:concurrency]) {
      annotations[@"Org.OData.Core.V1.OptimisticConcurrency"] = @[ @{ @"$PropertyPath": [self.mapper propertyForAttribute:concurrency] } ];
    }
    [annotations addEntriesFromDictionary:self.entitySetAnnotations[setName] ?: @{}];
    OISAddChildren(set, [self annotations:annotations]);
    [container addChild:set];
  }
  for (ODataXMLElement *element in self.additionalContainerElements) [container addChild:[element copy]];
  NSMutableDictionary *containerAnnotations = [NSMutableDictionary dictionary];
  // The versions the service speaks, which is how a 4.01 client learns it
  // may send 4.01 payloads (Part 1 section 13.3, item 16).
  containerAnnotations[[OISCore stringByAppendingString:@".ODataVersions"]] = @"4.0 4.01";
  for (NSString *term in self.containerAnnotations) containerAnnotations[[self fullTerm:term]] = self.containerAnnotations[term];
  OISAddChildren(container, [self annotations:containerAnnotations]);
  return container;
}

static NSString * const OISEdmx = @"http://docs.oasis-open.org/odata/ns/edmx";
static NSString * const OISEdm = @"http://docs.oasis-open.org/odata/ns/edm";

- (NSString *)XMLStringForVersion:(NSString *)version
{
  _problems = [NSMutableArray array];
  self.vocabularies = [NSMutableSet set];
  NSMutableDictionary<NSString *, NSMutableArray *> *schemas = [NSMutableDictionary dictionary];
  NSMutableSet *usedTypes = [NSMutableSet set];
  for (NSEntityDescription *entity in self.model.entities) {
    if (![self.entities containsObject:entity]) {
      // One it was not asked to write is no problem.
      if (!self.entityNames || [self.entityNames containsObject:[self rootOf:entity].name]) {
        [_problems addObject:[NSString stringWithFormat:@"%@ has no key: give an attribute OData.key, or name it id", entity.name]];
      }
      continue;
    }
    [self writeEntity:entity into:schemas used:usedTypes];
  }
  [self writeSchemaTypes:usedTypes into:schemas];
  // Edm.Untyped is CSDL 4.01's: 4.0 has JSON's vocabulary say "any JSON".
  BOOL untyped = ![version isEqualToString:@"4.0"];
  for (ODataXMLElement *original in self.additionalSchemaElements) {
    ODataXMLElement *element = [original copy];
    // An operation's overload, as a target names it: NS.Name, or bound,
    // NS.Name(its binding parameter's type); its own permissions inside it.
    NSMutableString *overload = [NSMutableString stringWithFormat:@"%@.%@", self.namespaceName, [element attributeForName:@"Name"].stringValue];
    if ([[element attributeForName:@"IsBound"].stringValue isEqualToString:@"true"]) {
      ODataXMLElement *binding = [element elementsForName:@"Parameter"].firstObject;
      [overload appendFormat:@"(%@)", [binding attributeForName:@"Type"].stringValue ?: @""];
    }
    if ([self.operationPermissions[overload] count]) {
      OISAddChildren(element, [self annotations:@{ @"Org.OData.Capabilities.V1.OperationRestrictions":
                                                     @{ @"Permissions": [self permissionsOf:self.operationPermissions[overload]] } }]);
    }
    // An operation's JSON parameter or result references the vocabulary.
    for (ODataXMLNode *child in element.children) {
      if (child.kind != ODataXMLElementKind) continue;
      ODataXMLNode *attribute = [(ODataXMLElement *)child attributeForName:@"Type"];
      NSString *type = attribute.stringValue;
      if (!untyped && [OISElementTypeOf(type) isEqualToString:@"Edm.Untyped"]) {
        type = [type isEqualToString:@"Edm.Untyped"] ? @"Org.OData.JSON.V1.JSON" : @"Collection(Org.OData.JSON.V1.JSON)";
        attribute.stringValue = type;
      }
      if ([OISElementTypeOf(type) isEqualToString:@"Org.OData.JSON.V1.JSON"]) [self useTerm:@"Org.OData.JSON.V1.JSON"];
    }
    [self append:element toNamespace:self.namespaceName in:schemas];
  }
  [self append:[self container] toNamespace:self.namespaceName in:schemas];

  ODataXMLElement *edmx = [[ODataXMLElement alloc] initWithName:@"edmx:Edmx" URI:OISEdmx];
  [edmx addNamespace:[ODataXMLNode namespaceWithName:@"edmx" stringValue:OISEdmx]];
  [edmx addAttribute:[ODataXMLNode attributeWithName:@"Version" stringValue:version]];
  // The standard vocabularies used, each where OASIS publishes it.
  for (NSString *vocabulary in [self.vocabularies.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
    if (![vocabulary hasPrefix:@"Org.OData."] || ![vocabulary hasSuffix:@".V1"]) continue;
    NSString *alias = [[vocabulary substringFromIndex:10] stringByDeletingPathExtension];
    ODataXMLElement *reference = [[ODataXMLElement alloc] initWithName:@"edmx:Reference" URI:OISEdmx];
    [reference addAttribute:[ODataXMLNode attributeWithName:@"Uri"
                                             stringValue:[NSString stringWithFormat:@"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/%@.xml", vocabulary]]];
    ODataXMLElement *include = [[ODataXMLElement alloc] initWithName:@"edmx:Include" URI:OISEdmx];
    [include addAttribute:[ODataXMLNode attributeWithName:@"Namespace" stringValue:vocabulary]];
    [include addAttribute:[ODataXMLNode attributeWithName:@"Alias" stringValue:alias]];
    [reference addChild:include];
    [edmx addChild:reference];
  }
  ODataXMLElement *services = [[ODataXMLElement alloc] initWithName:@"edmx:DataServices" URI:OISEdmx];
  for (NSString *ns in [schemas.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataXMLElement *schema = OISElement(@"Schema", @[ @"Namespace", ns ]);
    [schema addNamespace:[ODataXMLNode namespaceWithName:@"" stringValue:OISEdm]];
    OISAddChildren(schema, schemas[ns]);
    // Its version, which clients name in $schemaversion (Core is referenced:
    // the container's ODataVersions is a Core term).
    if (self.schemaVersion.length && [ns isEqualToString:self.namespaceName]) {
      OISAddChildren(schema, [self annotations:@{ [OISCore stringByAppendingString:@".SchemaVersion"]: self.schemaVersion }]);
    }
    [services addChild:schema];
  }
  [edmx addChild:services];
  ODataXMLDocument *document = [[ODataXMLDocument alloc] initWithRootElement:edmx];
  document.version = @"1.0";
  document.characterEncoding = @"utf-8";
  return [document XMLStringWithOptions:ODataXMLNodeCompactEmptyElement];
}

@end
