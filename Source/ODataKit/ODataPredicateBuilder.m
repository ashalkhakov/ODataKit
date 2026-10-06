// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataPredicateBuilder.h"
#import "ODataError.h"
#import "ODataValue.h"
#import <ODataKit/ODataApply.h>
#import <ODataKit/ODataRegex.h>
#include <math.h>

typedef NS_ENUM(NSInteger, OISTermKind) {
  OISTermValue,       // a scalar: an attribute's value, a count, a computed value
  OISTermEntity,      // one object: $it, a lambda's variable, a to-one relationship
  OISTermCollection,  // a to-many relationship
  OISTermLiteral      // a literal, typed once it is known what it meets
};

// What an expression stands for, on the way to an NSExpression.
@interface OISTerm : NSObject
@property (nonatomic) OISTermKind kind;
@property (nonatomic, copy, nullable) NSString *variable;  // a lambda's, generated; nil: $it
@property (nonatomic, copy, nullable) NSString *keyPath;   // from the variable (or $it); nil: itself
@property (nonatomic, strong, nullable) NSExpression *expression;  // a computed value's
@property (nonatomic, strong, nullable) NSAttributeDescription *attribute;  // types what it meets
@property (nonatomic, strong, nullable) NSEntityDescription *entity;
@property (nonatomic, copy, nullable) NSString *wireName;  // for messages
@property (nonatomic, strong, nullable) ODataExpression *literal;
@property (nonatomic, copy, nullable) NSString *caseFunction;  // tolower or toupper around `inner`
// year, date, floor, ceiling or round around `inner`: compared with a
// literal, a range of `inner`.
@property (nonatomic, copy, nullable) NSString *stepFunction;
// A string step's literals: substring's start and length, indexof's
// needle, concat's prefix and suffix (NSNull where the property is).
@property (nonatomic, copy, nullable) NSArray *stepArguments;
@property (nonatomic, strong, nullable) OISTerm *inner;
// What a type cast on the way asks of an object's entity: the term has a
// value only where it holds, and is null elsewhere.
@property (nonatomic, strong, nullable) NSPredicate *guard;
// A collection's cast (Staff/NS.Manager): only its members of this type.
@property (nonatomic, strong, nullable) NSEntityDescription *elementType;
// The key paths the term's value comes from that may hold nil: an
// optional attribute, or any reached through a relationship.
@property (nonatomic, copy, nullable) NSArray<NSExpression *> *nullables;
// Arithmetic: numbers in it, and a number compared with it, are plain
// NSNumbers (Apple's SQLite store compares a computed value with an
// NSDecimalNumber as text).
@property (nonatomic) BOOL computed;
@end

@implementation OISTerm
@end

// The values of `inner` where f(inner) is n: from lower to upper, each
// bound in or out.
@interface OISInterval : NSObject
@property (nonatomic, strong) id lower;
@property (nonatomic) BOOL lowerIn;
@property (nonatomic, strong) id upper;
@property (nonatomic) BOOL upperIn;
@end

@implementation OISInterval
@end

static OISInterval *OISIntervalMake(id lower, BOOL lowerIn, id upper, BOOL upperIn)
{
  OISInterval *interval = [[OISInterval alloc] init];
  interval.lower = lower;
  interval.lowerIn = lowerIn;
  interval.upper = upper;
  interval.upperIn = upperIn;
  return interval;
}

static NSDate *OISStartOfYear(long long year)
{
  NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSDateComponents *components = [[NSDateComponents alloc] init];
  components.year = (NSInteger)year;
  components.month = 1;
  components.day = 1;
  return [calendar dateFromComponents:components];
}

static BOOL OISIsPlainName(NSString *name)
{
  if (!name.length) return NO;
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    BOOL letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    if (!letter && !(i > 0 && c >= '0' && c <= '9')) return NO;
  }
  return YES;
}

// The function an arithmetic operator is in NSExpression. gnustep-base
// names them as its own parser writes them, and has no modulo.
static NSString *OISArithmeticFunction(NSString *op)
{
#if defined(__APPLE__)
  NSDictionary *names = @{ @"add": @"add:to:", @"sub": @"from:subtract:", @"mul": @"multiply:by:",
                           @"div": @"divide:by:", @"divby": @"divide:by:", @"mod": @"modulus:by:" };
#else
  NSDictionary *names = @{ @"add": @"_add", @"sub": @"_sub", @"mul": @"_mul", @"div": @"_div", @"divby": @"_div" };
#endif
  return names[op];
}

static NSPredicateOperatorType OISComparisonOperator(NSString *op)
{
  if ([op isEqualToString:@"ne"]) return NSNotEqualToPredicateOperatorType;
  if ([op isEqualToString:@"gt"]) return NSGreaterThanPredicateOperatorType;
  if ([op isEqualToString:@"ge"]) return NSGreaterThanOrEqualToPredicateOperatorType;
  if ([op isEqualToString:@"lt"]) return NSLessThanPredicateOperatorType;
  if ([op isEqualToString:@"le"]) return NSLessThanOrEqualToPredicateOperatorType;
  return NSEqualToPredicateOperatorType;
}

// The operator that keeps a comparison true with its sides swapped.
static NSString *OISSwapped(NSString *op)
{
  NSDictionary *swapped = @{ @"gt": @"lt", @"ge": @"le", @"lt": @"gt", @"le": @"ge" };
  return swapped[op] ?: op;
}

static NSNumber *OISPlainNumber(NSNumber *number)
{
  if (![number isKindOfClass:[NSDecimalNumber class]]) return number;
  double value = number.doubleValue;
  return value == floor(value) && fabs(value) < 9e15 ? @((long long)value) : @(value);
}

static NSPredicate *OISAnd(NSPredicate *a, NSPredicate *b)
{
  if (!a) return b;
  if (!b) return a;
  return [NSCompoundPredicate andPredicateWithSubpredicates:@[ a, b ]];
}

static void OISCollectSubentities(NSEntityDescription *entity, NSMutableArray *into)
{
  [into addObject:entity];
  for (NSEntityDescription *subentity in entity.subentities) OISCollectSubentities(subentity, into);
}

static NSPredicate *OISCompare(NSExpression *left, NSPredicateOperatorType type, NSExpression *right, NSComparisonPredicateOptions options)
{
  return [NSComparisonPredicate predicateWithLeftExpression:left
                                            rightExpression:right
                                                   modifier:NSDirectPredicateModifier
                                                       type:type
                                                    options:options];
}

#pragma mark - One translation

@interface OISPredicateBuild : NSObject
@property (nonatomic, strong) ODataPropertyMapper *mapper;
@property (nonatomic, strong) NSEntityDescription *root;
@property (nonatomic, copy) NSDictionary<NSString *, ODataExpression *> *aliases;
@property (nonatomic, strong) NSMutableDictionary<NSString *, OISTerm *> *scope;
// Inside a count's $filter: the member counted, which a member path with
// no variable, and $this, start from ($it is still the root).
@property (nonatomic, strong, nullable) OISTerm *current;
@property (nonatomic, copy) NSDictionary<NSString *, NSEntityDescription *> *entitiesByTypeName;
@property (nonatomic, copy) NSSet * (^restrictedProperties)(NSEntityDescription *entity, BOOL sorting);
@property (nonatomic, copy) ODataDynamicPropertyPredicate dynamicProperty;
@property (nonatomic, strong, nullable) id userInfo;
@property (nonatomic) BOOL sorting;
// $compute's names, and how deep one stands for another.
@property (nonatomic, copy) NSDictionary<NSString *, ODataExpression *> *computed;
@property (nonatomic) NSInteger computeDepth;
@property (nonatomic) NSInteger variables;
@property (nonatomic, strong, nullable) NSError *error;
// The span of a date month() and the like range over: given, by
// attribute (+spanKeyOfAttribute:), or asked for (wanted: the attributes
// a predicate's date parts need), or read from a context.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSArray *> *spans;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSAttributeDescription *> *wanted;
@property (nonatomic, strong, nullable) NSManagedObjectContext *context;
// OData's conditions are three-valued (URL conventions 5.1.1.1.7-9): true,
// false, or null, which $filter leaves out as it does false. A predicate
// says where a condition is true; for one that can be null, this says
// where it is false, the rest being null. A condition not in it is never
// null: false wherever it is not true.
@property (nonatomic, strong) NSMapTable<NSPredicate *, NSPredicate *> *falsehoods;
@end

@implementation OISPredicateBuild

// p, a condition null where neither it nor f holds: f where it is false.
- (NSPredicate *)condition:(NSPredicate *)p falseWhere:(NSPredicate *)f
{
  if (!p || !f) return p;
  if (!self.falsehoods) {
    self.falsehoods = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                            valueOptions:NSPointerFunctionsStrongMemory];
  }
  [self.falsehoods setObject:f forKey:p];
  return p;
}

// Where p is false: what it says, for one that can be null; else
// wherever it is not true.
- (NSPredicate *)falsehoodOf:(NSPredicate *)p
{
  return [self.falsehoods objectForKey:p] ?: [NSCompoundPredicate notPredicateWithSubpredicate:p];
}

- (BOOL)mayBeNull:(NSPredicate *)p
{
  return [self.falsehoods objectForKey:p] != nil;
}

// A function of terms that is null where any of them is (URL conventions
// 5.1.1.4: "If a parameter of a canonical function is null, the function
// returns null"), as has is (5.1.1.1.10), and a Boolean value itself:
// true where they are all there and c holds, false where they are and it
// does not.
- (NSPredicate *)nullable:(NSPredicate *)c terms:(NSArray<OISTerm *> *)terms type:(NSPredicateOperatorType)type
{
  if (!c) return nil;
  NSPredicate *t = [self guarded:[self nullSafe:c terms:terms type:type] terms:terms whenNull:NO];
  BOOL mayBeNull = NO;
  for (OISTerm *term in terms) mayBeNull = mayBeNull || term.guard || term.nullables.count;
  if (!mayBeNull) return t;
  NSPredicate *f = [self guarded:[self nullSafe:[NSCompoundPredicate notPredicateWithSubpredicate:c] terms:terms type:type]
                           terms:terms
                        whenNull:NO];
  return [self condition:t falseWhere:f];
}

- (id)fail:(NSInteger)status message:(NSString *)message
{
  if (!self.error) self.error = ODataServiceError(status, message);
  return nil;
}

- (id)unsupported:(NSString *)what
{
  return [self fail:501 message:[NSString stringWithFormat:@"%@ is not supported here", what]];
}

// An alias's value, followed through aliases of aliases.
- (ODataExpression *)resolve:(ODataExpression *)e
{
  for (NSInteger depth = 0; e.kind == ODataExpressionAlias; depth++) {
    ODataExpression *value = self.aliases[e.name];
    if (!value || depth > 8) return [self fail:400 message:[NSString stringWithFormat:@"no value for the parameter alias @%@", e.name]];
    e = value;
  }
  return e;
}

- (OISTerm *)itTerm
{
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = OISTermEntity;
  t.entity = self.root;
  return t;
}

- (NSExpression *)pathExpression:(OISTerm *)t
{
  if (t.expression) return t.expression;
  if (t.variable) {
    if (!t.keyPath) return [NSExpression expressionForVariable:t.variable];
    // Generated variable names and model property names only; see the header.
    return [NSExpression expressionWithFormat:[NSString stringWithFormat:@"$%@.%@", t.variable, t.keyPath]];
  }
  return t.keyPath ? [NSExpression expressionForKeyPath:t.keyPath] : [NSExpression expressionForEvaluatedObject];
}

#pragma mark Types

// t (an object) is of type, or of a type derived from it: its entity is one
// of them. Apple's stores and FreeCoreData's all answer "entity" in a
// predicate, of the fetched object or one it reaches.
- (NSPredicate *)object:(OISTerm *)t isOfType:(NSEntityDescription *)type
{
  OISTerm *entity = [[OISTerm alloc] init];
  entity.variable = t.variable;
  entity.keyPath = t.keyPath ? [t.keyPath stringByAppendingString:@".entity"] : @"entity";
  NSMutableArray *entities = [NSMutableArray array];
  OISCollectSubentities(type, entities);
  return OISCompare([self pathExpression:entity], NSInPredicateOperatorType, [NSExpression expressionForConstantValue:entities], 0);
}

// The entity type a cast or isof names: a qualified name (NS.Manager), or,
// as some clients write it, the name in quotes.
- (NSEntityDescription *)typeNamed:(ODataExpression *)e what:(NSString *)what
{
  e = [self resolve:e];
  if (!e) return nil;
  NSString *name = nil;
  if (e.kind == ODataExpressionCast && !e.operand) name = e.name;
  if (e.kind == ODataExpressionLiteral && [e.value isKindOfClass:[NSString class]]) name = e.value;
  if (!name) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes a qualified type name, not %@", what, e]];
  return [self typeForName:name what:what];
}

- (NSEntityDescription *)typeForName:(NSString *)name what:(NSString *)what
{
  if ([name hasPrefix:@"Edm."]) return [self unsupported:[NSString stringWithFormat:@"%@ with the primitive type %@", what, name]];
  NSEntityDescription *type = self.entitiesByTypeName[name];
  if (!type) return [self fail:400 message:[NSString stringWithFormat:@"%@ is not an entity type of this service", name]];
  return type;
}

// A primitive type a cast or isof names (Edm.Decimal); nil for another.
- (NSString *)primitiveTypeNamed:(ODataExpression *)e
{
  e = [self resolve:e];
  NSString *name = nil;
  if (e.kind == ODataExpressionCast && !e.operand) name = e.name;
  if (e.kind == ODataExpressionLiteral && [e.value isKindOfClass:[NSString class]]) name = e.value;
  return [name hasPrefix:@"Edm."] ? name : nil;
}

// Whether every value of one primitive type is a value of the other, as
// it is: Int32 in Int64, Decimal or Double.
static BOOL OISWidens(NSString *from, NSString *to)
{
  if ([from isEqualToString:to]) return YES;
  NSDictionary<NSString *, NSArray *> *wider = @{
    @"Edm.Byte": @[ @"Edm.Int16", @"Edm.Int32", @"Edm.Int64", @"Edm.Decimal", @"Edm.Single", @"Edm.Double" ],
    @"Edm.SByte": @[ @"Edm.Int16", @"Edm.Int32", @"Edm.Int64", @"Edm.Decimal", @"Edm.Single", @"Edm.Double" ],
    @"Edm.Int16": @[ @"Edm.Int32", @"Edm.Int64", @"Edm.Decimal", @"Edm.Single", @"Edm.Double" ],
    @"Edm.Int32": @[ @"Edm.Int64", @"Edm.Decimal", @"Edm.Double" ],
    @"Edm.Int64": @[ @"Edm.Decimal" ],
    @"Edm.Single": @[ @"Edm.Double" ],
  };
  return [wider[from] containsObject:to];
}

// A property's value as a primitive type that holds every value of its
// own: itself, compared as the wider type. Another cast (a narrowing one,
// which the spec rounds as it sees fit, or to and from strings) is 501.
- (OISTerm *)value:(OISTerm *)base castTo:(NSString *)type
{
  NSString *own = base.kind == OISTermValue && base.attribute && !base.expression && !base.caseFunction && !base.stepFunction
      ? [self.mapper declaredTypeForAttribute:base.attribute] : nil;
  if (!own || !OISWidens(own, type)) {
    return [self unsupported:[NSString stringWithFormat:@"A cast of %@%@ to %@", base.wireName ?: @"a value",
                              own ? [NSString stringWithFormat:@" (%@)", own] : @"", type]];
  }
  if ([own isEqualToString:type]) return base;
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = OISTermValue;
  t.variable = base.variable;
  t.keyPath = base.keyPath;
  t.guard = base.guard;
  t.nullables = base.nullables;
  // Untyped by the attribute: 2.5 is a Decimal here, compared as a plain number.
  t.computed = YES;
  t.wireName = [NSString stringWithFormat:@"cast(%@,%@)", base.wireName ?: @"", type];
  return t;
}

// base as type: an object that is null unless it is of the type, a
// collection of those of its members that are.
- (OISTerm *)cast:(OISTerm *)base to:(NSEntityDescription *)type named:(NSString *)name
{
  if (base.kind != OISTermEntity && base.kind != OISTermCollection) {
    return [self unsupported:[NSString stringWithFormat:@"A cast of %@", base.wireName ?: @"a value"]];
  }
  if (![type isKindOfEntity:base.entity] && ![base.entity isKindOfEntity:type]) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ is not derived from %@, nor it from %@", name, base.entity.name, name]];
  }
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = base.kind;
  t.variable = base.variable;
  t.keyPath = base.keyPath;
  t.guard = base.guard;
  t.elementType = base.elementType;
  t.entity = type;
  t.wireName = base.wireName ? [NSString stringWithFormat:@"%@/%@", base.wireName, name] : name;
  if (type != base.entity && [type isKindOfEntity:base.entity]) {
    if (base.kind == OISTermCollection) {
      t.elementType = type;
    } else {
      t.guard = OISAnd(base.guard, [self object:base isOfType:type]);
    }
  }
  return t;
}

// matchesPattern(x, 'pattern') (4.01): the pattern, ECMAScript's (Part 2
// section 5.1.1.5.4), found anywhere in x, as ECMAScript's RegExp test finds
// it; MATCHES is of the whole string, so anything at all around it, one
// character at a time (ODataRegex.h).
- (NSPredicate *)matchesPattern:(ODataExpression *)e
{
  NSArray<ODataExpression *> *args = e.arguments ?: @[];
  if (args.count != 2) return [self fail:400 message:@"matchesPattern takes a string and a pattern"];
  OISTerm *x = [self term:args[0]];
  if (!x) return nil;
  ODataExpression *pattern = [self resolve:args[1]];
  if (!pattern) return nil;
  if (pattern.kind != ODataExpressionLiteral || ![pattern.value isKindOfClass:[NSString class]]) {
    return [self unsupported:@"matchesPattern with anything but a literal pattern"];
  }
  if (x.kind != OISTermValue || (x.attribute && x.attribute.attributeType != NSStringAttributeType)) {
    return [self fail:400 message:[NSString stringWithFormat:@"matchesPattern: %@ is not a string", args[0]]];
  }
  NSError *error = nil;
  NSString *anywhere = [ODataRegex matchesPatternFindingECMAScript:pattern.value error:&error];
  if (!anywhere) {
    if (error.code == ODataIncrementalStoreErrorSyntax) {
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a regular expression: %@", pattern, error.localizedDescription]];
    }
    return [self unsupported:[NSString stringWithFormat:@"matchesPattern with %@: %@", pattern, error.localizedDescription]];
  }
  NSExpression *value = [self valueExpression:x typedBy:nil];
  if (!value) return nil;
  NSPredicate *p = OISCompare(value, NSMatchesPredicateOperatorType, [NSExpression expressionForConstantValue:anywhere], 0);
  return [self nullable:p terms:@[ x ] type:NSMatchesPredicateOperatorType];
}

// isdefined(path) (Data Aggregation section 3.2.1): whether the instance
// has the property at all, null or not. Of an entity, a declared property
// or a computed one is defined, whatever its value; a name the type does
// not have is not. Known before any row is read.
- (NSPredicate *)isDefined:(ODataExpression *)e
{
  NSArray<NSString *> *path = e.arguments.count == 1 ? e.arguments[0].memberPath : nil;
  if (!path.count) return [self fail:400 message:@"isdefined takes a property path"];
  if (path.count == 1 && self.computed[path[0]]) return [NSPredicate predicateWithValue:YES];
  NSEntityDescription *entity = self.root;
  for (NSString *name in path) {
    NSPropertyDescription *property = entity ? [self.mapper propertyForWireName:name entity:entity] : nil;
    if (!property) return [NSPredicate predicateWithValue:NO];
    entity = [property isKindOfClass:[NSRelationshipDescription class]] ? ((NSRelationshipDescription *)property).destinationEntity : nil;
  }
  return [NSPredicate predicateWithValue:YES];
}

// isof(Type), of $it, or isof(expression, Type).
- (NSPredicate *)isOf:(ODataExpression *)e
{
  NSArray<ODataExpression *> *args = e.arguments ?: @[];
  if (args.count != 1 && args.count != 2) return [self fail:400 message:@"isof takes a type, or an expression and a type"];
  NSString *primitive = [self primitiveTypeNamed:args.lastObject];
  if (primitive) {
    // Of a type that holds its every value: true, null included (null is
    // assignable to any type). Anything else depends on the value: 501.
    if (args.count != 2) return [NSPredicate predicateWithValue:NO];
    OISTerm *value = [self term:args[0]];
    if (!value) return nil;
    return [self value:value castTo:primitive] ? [NSPredicate predicateWithValue:YES] : nil;
  }
  NSEntityDescription *type = [self typeNamed:args.lastObject what:@"isof"];
  if (!type) return nil;
  OISTerm *object = args.count == 2 ? [self term:args[0]] : (self.current ?: [self itTerm]);
  if (!object) return nil;
  if (object.kind == OISTermCollection) return [self fail:400 message:[NSString stringWithFormat:@"isof: %@ is a collection", args[0]]];
  if (object.kind != OISTermEntity) return [self unsupported:@"isof of a value"];
  NSPredicate *test;
  if ([object.entity isKindOfEntity:type]) {
    // It is, when it is there at all.
    test = object.keyPath ? OISCompare([self pathExpression:object], NSNotEqualToPredicateOperatorType, [NSExpression expressionForConstantValue:nil], 0)
                          : [NSPredicate predicateWithValue:YES];
  } else if ([type isKindOfEntity:object.entity]) {
    test = [self object:object isOfType:type];
  } else {
    test = [NSPredicate predicateWithValue:NO];
  }
  return OISAnd(object.guard, test);
}

// p, about terms of which some are null where their guard does not hold:
// there p is as it would be for null, whenNull.
- (NSPredicate *)guarded:(NSPredicate *)p terms:(NSArray<OISTerm *> *)terms whenNull:(BOOL)whenNull
{
  if (!p) return nil;
  NSPredicate *guard = nil;
  for (OISTerm *t in terms) guard = OISAnd(guard, t.guard);
  if (!guard) return p;
  if (whenNull) return [NSCompoundPredicate orPredicateWithSubpredicates:@[ [NSCompoundPredicate notPredicateWithSubpredicate:guard], p ]];
  return OISAnd(guard, p);
}

// OData's null: a comparison with a null value is false (null ne a value
// is true), where SQL's is unknown, and NOT unknown is unknown, not true;
// and arithmetic on nil raises when a store evaluates it itself. So the
// nil test comes first.
- (NSPredicate *)nullSafe:(NSPredicate *)p terms:(NSArray<OISTerm *> *)terms type:(NSPredicateOperatorType)type
{
  if (!p) return nil;
  NSMutableArray *paths = [NSMutableArray array];
  for (OISTerm *t in terms) [paths addObjectsFromArray:t.nullables ?: @[]];
  if (!paths.count) return p;
  NSMutableArray *tests = [NSMutableArray array];
  BOOL ne = type == NSNotEqualToPredicateOperatorType;
  for (NSExpression *path in paths) {
    [tests addObject:OISCompare(path, ne ? NSEqualToPredicateOperatorType : NSNotEqualToPredicateOperatorType,
                                [NSExpression expressionForConstantValue:nil], 0)];
  }
  [tests addObject:p];
  return ne ? [NSCompoundPredicate orPredicateWithSubpredicates:tests] : [NSCompoundPredicate andPredicateWithSubpredicates:tests];
}

// A collection member's test, where the collection is cast: of the type,
// and then the test.
- (NSPredicate *)member:(OISTerm *)element of:(OISTerm *)collection test:(NSPredicate *)test
{
  if (!collection.elementType) return test ?: [NSPredicate predicateWithValue:YES];
  return OISAnd([self object:element isOfType:collection.elementType], test);
}

#pragma mark Literals

- (id)valueOfLiteral:(ODataExpression *)literal attribute:(NSAttributeDescription *)attribute ok:(BOOL *)ok
{
  *ok = YES;
  id value = literal.value;
  if (!value || value == [NSNull null]) return nil;
  if (attribute) {
    id typed = [self.mapper.values coreDataValueForJSON:value attribute:attribute];
    if (typed && typed != [NSNull null]) return typed;
    *ok = NO;
    [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", literal, [self.mapper propertyForAttribute:attribute]]];
    return nil;
  }
  NSString *type = literal.literalType;
  if ([type isEqualToString:@"Edm.Date"] || [type isEqualToString:@"Edm.DateTimeOffset"]) return ODataDateFromString(value);
  if ([type isEqualToString:@"Edm.Duration"]) return ODataDurationFromString(value);
  if ([type isEqualToString:@"Edm.Binary"]) return ODataDataFromBase64(value);
  return value;
}

// A term as an expression, a literal typed by the attribute it meets.
- (NSExpression *)valueExpression:(OISTerm *)t typedBy:(OISTerm *)other
{
  if (t.kind == OISTermLiteral) {
    BOOL ok;
    id value = [self valueOfLiteral:t.literal attribute:other.attribute ?: other.inner.attribute ok:&ok];
    if (ok && other.computed && [value isKindOfClass:[NSNumber class]]) value = OISPlainNumber(value);
    return ok ? [NSExpression expressionForConstantValue:value] : nil;
  }
  if (t.stepFunction) {
    return [self unsupported:[NSString stringWithFormat:@"%@() but compared with a literal", t.stepFunction]];
  }
  if (t.caseFunction) {
    NSExpression *inner = [self valueExpression:t.inner typedBy:other];
    if (!inner) return nil;
    NSString *function = [t.caseFunction isEqualToString:@"tolower"] ? @"lowercase:" : @"uppercase:";
    return [NSExpression expressionForFunction:function arguments:@[ inner ]];
  }
  return [self pathExpression:t];
}

#pragma mark Terms

- (OISTerm *)term:(ODataExpression *)e
{
  e = [self resolve:e];
  if (!e) return nil;
  switch (e.kind) {
    case ODataExpressionLiteral: {
      OISTerm *t = [[OISTerm alloc] init];
      t.kind = OISTermLiteral;
      t.literal = e;
      return t;
    }
    case ODataExpressionVariable: {
      if ([e.name isEqualToString:@"$it"]) return [self itTerm];
      if ([e.name isEqualToString:@"$this"]) return self.current ?: [self itTerm];
      OISTerm *scoped = self.scope[e.name];
      if (scoped) return scoped;
      if ([e.name hasPrefix:@"$"]) return [self unsupported:e.name];
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a lambda variable in scope", e.name]];
    }
    case ODataExpressionMember:
      return [self memberTerm:e];
    case ODataExpressionCount: {
      OISTerm *collection = [self term:e.operand];
      if (!collection) return nil;
      if (collection.kind != OISTermCollection) {
        return [self fail:400 message:[NSString stringWithFormat:@"%@/$count: not a collection", e.operand]];
      }
      OISTerm *t = [[OISTerm alloc] init];
      t.kind = OISTermValue;
      t.guard = collection.guard;
      t.wireName = e.description;
      if (collection.elementType || e.countFilter) {
        // The members counted: of a cast collection, those of the type;
        // with $filter, those it is true of, read from the member ($it
        // still the root, a key path from it, as in any and all).
        OISTerm *element = [self elementOf:collection];
        NSPredicate *test = nil;
        if (e.countFilter) {
          OISTerm *outer = self.current;
          self.current = element;
          test = [self predicate:e.countFilter];
          self.current = outer;
          if (!test) return nil;
        }
        NSPredicate *member = [self member:element of:collection test:test];
        NSExpression *members = [NSExpression expressionForSubquery:[self pathExpression:collection]
                                              usingIteratorVariable:element.variable
                                                          predicate:member];
        t.expression = [NSExpression expressionForFunction:@"count:" arguments:@[ members ]];
        return t;
      }
      t.variable = collection.variable;
      t.keyPath = [NSString stringWithFormat:@"%@.@count", collection.keyPath];
      return t;
    }
    case ODataExpressionUnary:
      if ([e.name isEqualToString:@"-"]) return [self arithmetic:@"mul" left:e.operand right:nil negate:YES];
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", e]];
    case ODataExpressionBinary:
      if (OISArithmeticFunction(e.name) || [e.name isEqualToString:@"mod"]) {
        return [self arithmetic:e.name left:e.left right:e.right negate:NO];
      }
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", e]];
    case ODataExpressionCall:
      return e.aggregate ? [self aggregateTerm:e] : [self callTerm:e];
    case ODataExpressionCast: {
      OISTerm *base = e.operand ? [self term:e.operand] : (self.current ?: [self itTerm]);
      if (!base) return nil;
      NSEntityDescription *type = [self typeForName:e.name what:@"A cast"];
      return type ? [self cast:base to:type named:e.name] : nil;
    }
    default:
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", e]];
  }
}

- (OISTerm *)memberTerm:(ODataExpression *)e
{
  // $compute's names and a join's aliases are the root's, not a counted
  // member's.
  id named = e.operand || self.current ? nil : self.computed[e.name];
  if ([named isKindOfClass:[NSEntityDescription class]]) {
    // A join's alias: a navigation property to the joined member, which may
    // be null (an outerjoin's).
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermEntity;
    t.entity = named;
    t.keyPath = e.name;
    t.wireName = e.name;
    return t;
  }
  ODataExpression *computed = [named isKindOfClass:[ODataExpression class]] ? named : nil;
  if (computed) {
    if (self.computeDepth > 8) return [self fail:400 message:[NSString stringWithFormat:@"$compute: %@ stands for itself", e.name]];
    self.computeDepth++;
    OISTerm *t = [self term:computed];
    self.computeDepth--;
    return t;
  }
  OISTerm *base = e.operand ? [self term:e.operand] : (self.current ?: [self itTerm]);
  if (!base) return nil;
  if (base.kind == OISTermCollection) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ is a collection: its members are reached with any or all", e.operand]];
  }
  if (base.kind != OISTermEntity) return [self unsupported:[NSString stringWithFormat:@"The member %@ of a value", e.name]];

  NSPropertyDescription *property = [self.mapper propertyForWireName:e.name entity:base.entity];
  if (!property) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ has no property %@", base.entity.name, e.name]];
  }
  if (!OISIsPlainName(property.name)) return [self unsupported:[NSString stringWithFormat:@"The property %@", e.name]];
  if (self.restrictedProperties && [self.restrictedProperties(base.entity, self.sorting) containsObject:property.name]) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ cannot be %@ by here", e.name, self.sorting ? @"sorted" : @"filtered"]];
  }

  OISTerm *t = [[OISTerm alloc] init];
  t.guard = base.guard;
  t.variable = base.variable;
  t.keyPath = base.keyPath ? [NSString stringWithFormat:@"%@.%@", base.keyPath, property.name] : property.name;
  t.wireName = base.wireName ? [NSString stringWithFormat:@"%@/%@", base.wireName, e.name] : e.name;
  if ([property isKindOfClass:[NSAttributeDescription class]]) {
    t.kind = OISTermValue;
    t.attribute = (NSAttributeDescription *)property;
    if (t.attribute.isOptional || base.keyPath) t.nullables = @[ [self pathExpression:t] ];
  } else {
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
    t.kind = relationship.isToMany ? OISTermCollection : OISTermEntity;
    t.entity = relationship.destinationEntity;
    // A collection through a to-one that may be null is null where no
    // entity is related (OData 4.01 URL conventions, 5.1.1.15: "its value,
    // and the values of its components, are treated as null"), so nothing
    // about it holds there: any, all and every $count comparison leave the
    // row out. The to-one is tested first, as a store evaluating count: of
    // nothing itself raises.
    if (relationship.isToMany && base.keyPath) {
      t.guard = OISAnd(base.guard, OISCompare([self pathExpression:base], NSNotEqualToPredicateOperatorType,
                                              [NSExpression expressionForConstantValue:nil], 0));
    }
  }
  return t;
}

- (OISTerm *)arithmetic:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right negate:(BOOL)negate
{
  NSString *function = OISArithmeticFunction(op);
  if (!function) return [self unsupported:[NSString stringWithFormat:@"The operator %@", op]];
  OISTerm *l = [self term:left];
  OISTerm *r;
  if (negate) {
    r = [[OISTerm alloc] init];
    r.kind = OISTermValue;
    r.expression = [NSExpression expressionForConstantValue:@-1];
  } else {
    r = [self term:right];
  }
  if (!l || !r) return nil;
  for (OISTerm *side in @[ l, r ]) {
    if (side.kind == OISTermEntity || side.kind == OISTermCollection) {
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a number", side.wireName ?: @"an operand"]];
    }
  }
  // Operands' numbers plain, as the value compared with the result.
  OISTerm *plainL = [[OISTerm alloc] init];
  plainL.computed = YES;
  plainL.attribute = l.attribute;
  OISTerm *plainR = [[OISTerm alloc] init];
  plainR.computed = YES;
  plainR.attribute = r.attribute;
  NSExpression *le = [self valueExpression:l typedBy:plainR];
  NSExpression *re = [self valueExpression:r typedBy:plainL];
  if (!le || !re) return nil;
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = OISTermValue;
  t.expression = [NSExpression expressionForFunction:function arguments:@[ le, re ]];
  t.attribute = l.attribute ?: r.attribute;
  t.guard = OISAnd(l.guard, r.guard);
  t.computed = YES;
  t.nullables = [(l.nullables ?: @[]) arrayByAddingObjectsFromArray:r.nullables ?: @[]];
  return t;
}

// Products/aggregate(UnitPrice with sum): a key path's collection operator
// (products.@sum.unitPrice), for a path through to-one relationships to an
// attribute of the members, with sum, min, max or average, or $count.
- (OISTerm *)aggregateTerm:(ODataExpression *)e
{
  ODataAggregate *a = e.aggregate;
  if (e.operand.kind == ODataExpressionVariable && [e.operand.name isEqualToString:@"$these"]) {
    return [self unsupported:[NSString stringWithFormat:@"%@ here", e]];
  }
  OISTerm *collection = [self term:e.operand];
  if (!collection) return nil;
  if (collection.kind != OISTermCollection) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@: not a collection", e]];
  }
  NSDictionary *operators = @{ @"sum": @"@sum", @"min": @"@min", @"max": @"@max", @"average": @"@avg" };
  if (collection.elementType || !collection.entity || a.expression || a.isCustom || (!a.isCount && !operators[a.method]) || (a.isCount && a.path)) {
    return [self unsupported:[NSString stringWithFormat:@"%@", e]];
  }
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = OISTermValue;
  t.guard = collection.guard;
  t.variable = collection.variable;
  t.wireName = e.description;
  t.computed = YES;
  if (a.isCount) {
    t.keyPath = [NSString stringWithFormat:@"%@.@count", collection.keyPath];
    return t;
  }
  NSEntityDescription *entity = collection.entity;
  NSMutableArray *names = [NSMutableArray array];
  NSAttributeDescription *attribute = nil;
  for (NSUInteger i = 0; i < a.path.count; i++) {
    NSPropertyDescription *property = [self.mapper propertyForWireName:a.path[i] entity:entity];
    if (!property) return [self fail:400 message:[NSString stringWithFormat:@"%@ has no property %@", entity.name, a.path[i]]];
    [names addObject:property.name];
    BOOL last = i + 1 == a.path.count;
    if (last && [property isKindOfClass:[NSAttributeDescription class]]) {
      attribute = (NSAttributeDescription *)property;
    } else if (!last && [property isKindOfClass:[NSRelationshipDescription class]] && !((NSRelationshipDescription *)property).isToMany) {
      entity = ((NSRelationshipDescription *)property).destinationEntity;
    } else {
      return [self unsupported:[NSString stringWithFormat:@"%@", e]];
    }
  }
  BOOL numeric = attribute.attributeType == NSInteger16AttributeType || attribute.attributeType == NSInteger32AttributeType
              || attribute.attributeType == NSInteger64AttributeType || attribute.attributeType == NSDecimalAttributeType
              || attribute.attributeType == NSDoubleAttributeType || attribute.attributeType == NSFloatAttributeType;
  if (!numeric && ([a.method isEqualToString:@"sum"] || [a.method isEqualToString:@"average"])) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@: %@ is not a number", e, [a.path componentsJoinedByString:@"/"]]];
  }
  if (![a.method isEqualToString:@"average"]) t.attribute = attribute;
  t.keyPath = [NSString stringWithFormat:@"%@.%@.%@", collection.keyPath, operators[a.method], [names componentsJoinedByString:@"."]];
  return t;
}

- (OISTerm *)callTerm:(ODataExpression *)e
{
  if (e.operand || e.namedArguments || [e.name rangeOfString:@"."].location != NSNotFound) {
    return [self unsupported:[NSString stringWithFormat:@"The function %@", e.name]];
  }
  NSArray<ODataExpression *> *args = e.arguments ?: @[];
  if ([e.name isEqualToString:@"tolower"] || [e.name isEqualToString:@"toupper"]) {
    if (args.count != 1) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes one argument", e.name]];
    OISTerm *inner = [self term:args[0]];
    if (!inner) return nil;
    if (inner.kind == OISTermLiteral) {
      NSString *text = [inner.literal.value isKindOfClass:[NSString class]] ? inner.literal.value : nil;
      if (!text) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes a string", e.name]];
      OISTerm *t = [[OISTerm alloc] init];
      t.kind = OISTermValue;
      t.expression = [NSExpression expressionForConstantValue:[e.name isEqualToString:@"tolower"] ? text.lowercaseString : text.uppercaseString];
      return t;
    }
    if (inner.kind != OISTermValue) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes a string", e.name]];
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermValue;
    t.caseFunction = e.name;
    t.inner = inner;
    t.attribute = inner.attribute;
    t.guard = inner.guard;
    t.nullables = inner.nullables;
    return t;
  }
  NSSet *dateSteps = [NSSet setWithObjects:@"year", @"date", @"month", @"day", @"hour", @"minute", @"second", nil];
  NSSet *numberSteps = [NSSet setWithObjects:@"floor", @"ceiling", @"round", nil];
  if ([dateSteps containsObject:e.name] || [numberSteps containsObject:e.name]) {
    if (args.count != 1) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes one argument", e.name]];
    OISTerm *inner = [self term:args[0]];
    if (!inner) return nil;
    BOOL date = [dateSteps containsObject:e.name];
    NSAttributeType type = inner.attribute.attributeType;
    BOOL fits = date ? type == NSDateAttributeType
                     : (type == NSInteger16AttributeType || type == NSInteger32AttributeType || type == NSInteger64AttributeType ||
                        type == NSDecimalAttributeType || type == NSDoubleAttributeType || type == NSFloatAttributeType);
    if (inner.kind != OISTermValue || inner.caseFunction || inner.stepFunction || !fits) {
      return [self fail:400 message:[NSString stringWithFormat:@"%@ takes %@", e.name, date ? @"a date" : @"a number"]];
    }
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermValue;
    t.stepFunction = e.name;
    t.inner = inner;
    t.guard = inner.guard;
    t.nullables = inner.nullables;
    t.wireName = e.description;
    return t;
  }
  if ([@[ @"fractionalseconds", @"time", @"totaloffsetminutes", @"totalseconds" ] containsObject:e.name]) {
    return [self unsupported:[NSString stringWithFormat:@"The function %@ (year, month, day, hour, minute, second and date are)", e.name]];
  }
  if ([@[ @"substring", @"trim", @"indexof", @"concat" ] containsObject:e.name]) return [self stringStepTerm:e];
  if ([e.name isEqualToString:@"length"]) {
    if (args.count != 1) return [self fail:400 message:@"length takes one argument"];
    OISTerm *inner = [self term:args[0]];
    if (!inner) return nil;
    if (inner.kind != OISTermValue || inner.expression || inner.caseFunction || !inner.keyPath ||
        inner.attribute.attributeType != NSStringAttributeType) {
      return [self unsupported:@"length of anything but a string property"];
    }
    // Compared with a number, a pattern of that many characters: a key
    // path's .length is no SQL a store writes (Apple's SQLite store takes
    // every row).
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermValue;
    t.stepFunction = @"length";
    t.inner = inner;
    t.guard = inner.guard;
    t.nullables = inner.nullables;
    return t;
  }
  if ([e.name isEqualToString:@"cast"]) {
    if (args.count != 1 && args.count != 2) return [self fail:400 message:@"cast takes a type, or an expression and a type"];
    NSString *primitive = [self primitiveTypeNamed:args.lastObject];
    if (primitive) {
      if (args.count != 2) return [self fail:400 message:[NSString stringWithFormat:@"An entity is not cast to %@", primitive]];
      OISTerm *base = [self term:args[0]];
      return base ? [self value:base castTo:primitive] : nil;
    }
    NSEntityDescription *type = [self typeNamed:args.lastObject what:@"cast"];
    OISTerm *base = !type ? nil : args.count == 2 ? [self term:args[0]] : (self.current ?: [self itTerm]);
    return base ? [self cast:base to:type named:args.lastObject.description] : nil;
  }
  if ([e.name isEqualToString:@"now"] && args.count == 0) {
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermValue;
    t.expression = [NSExpression expressionForConstantValue:[NSDate date]];
    return t;
  }
  return [self unsupported:[NSString stringWithFormat:@"The function %@", e.name]];
}

#pragma mark Predicates

- (NSPredicate *)predicate:(ODataExpression *)e
{
  e = [self resolve:e];
  if (!e) return nil;
  switch (e.kind) {
    case ODataExpressionBinary: {
      if ([e.name isEqualToString:@"and"] || [e.name isEqualToString:@"or"]) {
        NSPredicate *l = [self predicate:e.left];
        NSPredicate *r = l ? [self predicate:e.right] : nil;
        if (!r) return nil;
        // true and null is null, false and null false; true or null is
        // true, false or null null (5.1.1.1.7, 5.1.1.1.8).
        BOOL and = [e.name isEqualToString:@"and"];
        NSPredicate *p = and ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ l, r ]]
                             : [NSCompoundPredicate orPredicateWithSubpredicates:@[ l, r ]];
        if (![self mayBeNull:l] && ![self mayBeNull:r]) return p;
        NSArray *falsehoods = @[ [self falsehoodOf:l], [self falsehoodOf:r] ];
        return [self condition:p falseWhere:and ? [NSCompoundPredicate orPredicateWithSubpredicates:falsehoods]
                                                : [NSCompoundPredicate andPredicateWithSubpredicates:falsehoods]];
      }
      if ([@[ @"eq", @"ne", @"gt", @"ge", @"lt", @"le" ] containsObject:e.name]) return [self compare:e.name left:e.left right:e.right];
      if ([e.name isEqualToString:@"in"]) return [self in:e.left list:e.right];
      if ([e.name isEqualToString:@"has"]) return [self has:e.left flags:e.right];
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
    }
    case ODataExpressionUnary: {
      if (![e.name isEqualToString:@"not"]) return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
      NSPredicate *p = [self predicate:e.operand];
      if (!p) return nil;
      // not null is null (5.1.1.1.9): true where p is false, false where
      // it is true.
      if (![self mayBeNull:p]) return [NSCompoundPredicate notPredicateWithSubpredicate:p];
      return [self condition:[self falsehoodOf:p] falseWhere:p];
    }
    case ODataExpressionLambda:
      return [self lambda:e];
    case ODataExpressionLiteral:
      if ([e.value isKindOfClass:[NSNumber class]] && [e.literalType isEqualToString:@"Edm.Boolean"]) {
        return [NSPredicate predicateWithValue:[e.value boolValue]];
      }
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
    case ODataExpressionCall:
      if (!e.operand && !e.namedArguments && [e.name isEqualToString:@"isof"]) return [self isOf:e];
      if (!e.operand && !e.namedArguments && [e.name isEqualToString:@"isdefined"]) return [self isDefined:e];
      if (!e.operand && !e.namedArguments && [e.name isEqualToString:@"matchesPattern"]) return [self matchesPattern:e];
      if (!e.operand && !e.namedArguments) {
        NSDictionary *operators = @{ @"contains": @(NSContainsPredicateOperatorType),
                                     @"startswith": @(NSBeginsWithPredicateOperatorType),
                                     @"endswith": @(NSEndsWithPredicateOperatorType) };
        NSNumber *type = operators[e.name];
        if (type) {
          if (e.arguments.count != 2) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes two arguments", e.name]];
          return [self stringOperator:(NSPredicateOperatorType)type.integerValue name:e.name left:e.arguments[0] right:e.arguments[1]];
        }
      }
      // fall through: a function that returns a boolean value
    default: {
      NSArray *dynamicPath = [self dynamicPathOf:e];
      if (dynamicPath) {
        // A dynamic property on its own: is it true?
        ODataExpression *yes = [ODataExpression literalWithValue:@YES];
        return [self dynamic:dynamicPath type:NSEqualToPredicateOperatorType literal:yes];
      }
      OISTerm *t = [self term:e];
      if (!t) return nil;
      if (t.kind == OISTermValue && t.attribute.attributeType == NSBooleanAttributeType) {
        NSPredicate *p = OISCompare([self valueExpression:t typedBy:nil], NSEqualToPredicateOperatorType,
                                    [NSExpression expressionForConstantValue:@YES], 0);
        // Null where the value is.
        return [self nullable:p terms:@[ t ] type:NSEqualToPredicateOperatorType];
      }
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
    }
  }
}

// A string known before any row is read: a literal, or tolower or toupper
// of one.
static NSString *OISConstantString(OISTerm *t)
{
  if (t.kind == OISTermLiteral) return [t.literal.value isKindOfClass:[NSString class]] ? t.literal.value : nil;
  if (t.kind == OISTermValue && !t.keyPath && !t.variable && !t.caseFunction && t.expression.expressionType == NSConstantValueExpressionType) {
    id value = t.expression.constantValue;
    return [value isKindOfClass:[NSString class]] ? value : nil;
  }
  return nil;
}

// tolower(Name) eq 'abc' is Name ==[c] 'abc'; tolower(Name) eq 'Abc' is
// never true. So a store that can compare without case need not lower
// every row.
- (NSPredicate *)caseless:(OISTerm *)wrapped type:(NSPredicateOperatorType)type literal:(NSString *)text
{
  NSString *folded = [wrapped.caseFunction isEqualToString:@"tolower"] ? text.lowercaseString : text.uppercaseString;
  if (![folded isEqualToString:text]) return [NSPredicate predicateWithValue:type == NSNotEqualToPredicateOperatorType];
  NSExpression *inner = [self valueExpression:wrapped.inner typedBy:nil];
  if (!inner) return nil;
  return OISCompare(inner, type, [NSExpression expressionForConstantValue:text], NSCaseInsensitivePredicateOption);
}

#pragma mark Dynamic properties

// The names of a property the entity does not have, from $it: a name that
// is not one of its properties, and the members of it after. nil for
// anything else, or when nothing gives such properties a meaning.
- (NSArray<NSString *> *)dynamicPathOf:(ODataExpression *)e
{
  if (!self.dynamicProperty || self.sorting) return nil;
  NSMutableArray<NSString *> *path = [NSMutableArray array];
  for (e = [self resolve:e]; e.kind == ODataExpressionMember; e = e.operand) {
    [path insertObject:e.name atIndex:0];
    if (!e.operand) break;
  }
  if (e.kind != ODataExpressionMember && !(e.kind == ODataExpressionVariable && [e.name isEqualToString:@"$it"])) return nil;
  // Inside a count's $filter, a path with no variable is the member's.
  if (self.current && e.kind == ODataExpressionMember) return nil;
  if (!path.count || self.computed[path[0]] || [self.mapper propertyForWireName:path[0] entity:self.root]) return nil;
  return path;
}

// A dynamic property compared with a value, as the entity's handler says.
- (NSPredicate *)dynamic:(NSArray<NSString *> *)path type:(NSPredicateOperatorType)type literal:(ODataExpression *)literal
{
  NSString *name = [path componentsJoinedByString:@"/"];
  if (self.scope.count || self.current) {
    return [self unsupported:[NSString stringWithFormat:@"The dynamic property %@ inside any, all or $count(...)", name]];
  }
  literal = [self resolve:literal];
  if (!literal) return nil;
  if (literal.kind != ODataExpressionLiteral) {
    return [self unsupported:[NSString stringWithFormat:@"Comparing the dynamic property %@ with anything but a value", name]];
  }
  BOOL ok;
  id value = [self valueOfLiteral:literal attribute:nil ok:&ok];
  if (!ok) return nil;
  NSError *error = nil;
  NSPredicate *p = self.dynamicProperty(self.root, path, type, value, self.userInfo, &error);
  if (p) return p;
  if (error) {
    if (!self.error) self.error = error;
    return nil;
  }
  return [self fail:400 message:[NSString stringWithFormat:@"%@ has no property %@", self.root.name, name]];
}

- (NSPredicate *)compare:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right
{
  NSArray *dynamicLeft = [self dynamicPathOf:left];
  NSArray *dynamicRight = dynamicLeft ? nil : [self dynamicPathOf:right];
  if (dynamicLeft || dynamicRight) {
    if (dynamicLeft && [self dynamicPathOf:right]) return [self unsupported:@"Comparing two dynamic properties"];
    return dynamicLeft ? [self dynamic:dynamicLeft type:OISComparisonOperator(op) literal:right]
                       : [self dynamic:dynamicRight type:OISComparisonOperator(OISSwapped(op)) literal:left];
  }
  OISTerm *l = [self term:left];
  OISTerm *r = l ? [self term:right] : nil;
  if (!r) return nil;
  if (l.kind == OISTermLiteral && r.kind != OISTermLiteral) {
    OISTerm *swap = l;
    l = r;
    r = swap;
    op = OISSwapped(op);
  }
  NSPredicateOperatorType type = OISComparisonOperator(op);
  // Where a cast leaves a side null: null eq null, null ne 'x'.
  BOOL whenNull = NO;
  if (r.kind == OISTermLiteral && !(l.guard && r.guard)) {
    BOOL null = !r.literal.value || r.literal.value == [NSNull null];
    if (type == NSEqualToPredicateOperatorType) whenNull = null;
    if (type == NSNotEqualToPredicateOperatorType) whenNull = !null;
  }
  BOOL againstNull = r.kind == OISTermLiteral && (!r.literal.value || r.literal.value == [NSNull null]);
  if (l.stepFunction && r.kind == OISTermLiteral) {
    NSPredicate *step = [self step:l type:type literal:r.literal];
    if (!againstNull && ![@[ @"length", @"substring", @"trim", @"indexof", @"concat" ] containsObject:l.stepFunction]) {
      // A range already says what nil is (ne includes it).
      step = type == NSNotEqualToPredicateOperatorType ? step : [self nullSafe:step terms:@[ l ] type:type];
    } else if (!againstNull) {
      step = [self nullSafe:step terms:@[ l ] type:type];
    }
    return [self guarded:step terms:@[ l ] whenNull:whenNull];
  }
  if (l.stepFunction || r.stepFunction) {
    return [self unsupported:[NSString stringWithFormat:@"%@() but compared with a literal", l.stepFunction ?: r.stepFunction]];
  }
  NSPredicate *comparison = [self comparison:type left:l right:r];
  if (!againstNull && l.kind == OISTermValue) comparison = [self nullSafe:comparison terms:@[ l, r ] type:type];
  return [self guarded:comparison terms:@[ l, r ] whenNull:whenNull];
}

#pragma mark Step functions

// What the string functions count is characters one at a time, a \r of a
// \r\n included, where ICU's own "." would take a \r\n whole: these are
// the patterns they are compared with, as trees (ODataRegex.h).
static ODataRegex *OISRun(NSUInteger minimum, NSUInteger maximum)
{
  return [ODataRegex repeat:[ODataRegex any:ODataRegexAnyCodePoint] minimum:minimum maximum:maximum lazy:NO];
}

static ODataRegex *OISAnyRun(void)
{
  return OISRun(0, NSNotFound);
}

static ODataRegex *OISThen(NSArray<ODataRegex *> *parts)
{
  return [ODataRegex sequence:parts];
}

// x MATCHES the pattern, which MATCHES reads as it is written.
static NSPredicate *OISMatches(NSExpression *x, ODataRegex *pattern)
{
  NSString *text = [pattern stringInDialect:ODataRegexMatches error:NULL];
  return OISCompare(x, NSMatchesPredicateOperatorType, [NSExpression expressionForConstantValue:text], 0);
}

// length(x) op n: x MATCHES a run of so many characters.
- (NSPredicate *)length:(NSExpression *)x type:(NSPredicateOperatorType)type literal:(ODataExpression *)literal
{
  id value = literal.value;
  if (![value isKindOfClass:[NSNumber class]] || [literal.literalType isEqualToString:@"Edm.Boolean"] ||
      [value doubleValue] != floor([value doubleValue]) || [value doubleValue] < 0 || [value doubleValue] > 100000) {
    return [self fail:400 message:[NSString stringWithFormat:@"length() is compared with a whole number, not %@", literal]];
  }
  NSUInteger n = (NSUInteger)[value longLongValue];
  ODataRegex *pattern;
  BOOL negate = NO;
  switch (type) {
    case NSEqualToPredicateOperatorType: pattern = OISRun(n, n); break;
    case NSNotEqualToPredicateOperatorType: pattern = OISRun(n, n); negate = YES; break;
    case NSGreaterThanPredicateOperatorType: pattern = OISRun(n + 1, NSNotFound); break;
    case NSGreaterThanOrEqualToPredicateOperatorType: pattern = OISRun(n, NSNotFound); break;
    case NSLessThanPredicateOperatorType:
      if (n == 0) return [NSPredicate predicateWithValue:NO];
      pattern = OISRun(0, n - 1);
      break;
    case NSLessThanOrEqualToPredicateOperatorType: pattern = OISRun(0, n); break;
    default: return [self unsupported:@"length() with that operator"];
  }
  NSPredicate *p = OISMatches(x, pattern);
  return negate ? [NSCompoundPredicate notPredicateWithSubpredicate:p] : p;
}

#pragma mark String steps

// substring(s, i[, n]), trim(s), indexof(s, 'x') and concat(s, 'x') or
// concat('x', s), of a string property s: compared with a literal they are
// a pattern s matches, or an equality, which a store can evaluate.
- (OISTerm *)stringStepTerm:(ODataExpression *)e
{
  NSArray<ODataExpression *> *args = e.arguments ?: @[];
  NSString *name = e.name;
  NSUInteger wanted = [name isEqualToString:@"trim"] ? 1 : [name isEqualToString:@"substring"] ? 2 : 2;
  if (args.count != wanted && !([name isEqualToString:@"substring"] && args.count == 3)) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ takes %@", name,
                                   [name isEqualToString:@"substring"] ? @"a string, a start and a length" : [name isEqualToString:@"trim"] ? @"a string" : @"two strings"]];
  }
  NSMutableArray *terms = [NSMutableArray array];
  for (ODataExpression *arg in args) {
    OISTerm *t = [self term:arg];
    if (!t) return nil;
    [terms addObject:t];
  }
  OISTerm *(^property)(OISTerm *) = ^OISTerm *(OISTerm *t) {
    return t.kind == OISTermValue && !t.expression && !t.caseFunction && !t.stepFunction && t.keyPath &&
           t.attribute.attributeType == NSStringAttributeType ? t : nil;
  };
  id (^literal)(OISTerm *, Class) = ^id(OISTerm *t, Class cls) {
    return t.kind == OISTermLiteral && [t.literal.value isKindOfClass:cls] && ![t.literal.literalType isEqualToString:@"Edm.Boolean"] ? t.literal.value : nil;
  };
  OISTerm *inner = nil;
  NSMutableArray *arguments = [NSMutableArray array];
  if ([name isEqualToString:@"concat"]) {
    NSString *first = literal(terms[0], [NSString class]), *second = literal(terms[1], [NSString class]);
    if (first && second) {
      // Two literals: the literal they make.
      OISTerm *t = [[OISTerm alloc] init];
      t.kind = OISTermValue;
      t.expression = [NSExpression expressionForConstantValue:[first stringByAppendingString:second]];
      return t;
    }
    inner = property(first ? terms[1] : terms[0]);
    [arguments addObject:first ?: [NSNull null]];
    [arguments addObject:second ?: [NSNull null]];
    if (!inner || (!first && !second)) return [self unsupported:@"concat of anything but a string property and a literal"];
  } else {
    inner = property(terms[0]);
    if (!inner) return [self unsupported:[NSString stringWithFormat:@"%@ of anything but a string property", name]];
    for (NSUInteger i = 1; i < terms.count; i++) {
      id value = [name isEqualToString:@"indexof"] ? literal(terms[i], [NSString class]) : literal(terms[i], [NSNumber class]);
      if (!value || ([value isKindOfClass:[NSNumber class]] && ([value doubleValue] < 0 || [value doubleValue] != floor([value doubleValue]) ||
                                                                [value doubleValue] > 100000))) {
        return [self unsupported:[NSString stringWithFormat:@"%@ with anything but %@", name,
                                  [name isEqualToString:@"indexof"] ? @"a literal to look for" : @"whole numbers"]];
      }
      [arguments addObject:value];
    }
  }
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = OISTermValue;
  t.stepFunction = name;
  t.stepArguments = arguments;
  t.inner = inner;
  t.guard = inner.guard;
  t.nullables = inner.nullables;
  return t;
}

- (NSPredicate *)stringStep:(OISTerm *)t of:(NSExpression *)x type:(NSPredicateOperatorType)type literal:(ODataExpression *)literal
{
  NSString *f = t.stepFunction;
  NSPredicate *(^matches)(ODataRegex *) = ^NSPredicate *(ODataRegex *pattern) {
    return OISMatches(x, pattern);
  };
  NSPredicate *(^not)(NSPredicate *) = ^NSPredicate *(NSPredicate *p) { return [NSCompoundPredicate notPredicateWithSubpredicate:p]; };
  NSPredicate *no = [NSPredicate predicateWithValue:NO];
  if ([f isEqualToString:@"indexof"]) {
    id value = literal.value;
    if (![value isKindOfClass:[NSNumber class]] || [value doubleValue] != floor([value doubleValue])) {
      return [self fail:400 message:[NSString stringWithFormat:@"indexof() is compared with a whole number, not %@", literal]];
    }
    ODataRegex *needle = [ODataRegex literalString:t.stepArguments[0]];
    long long k = [value longLongValue];
    // Anywhere; so many characters, none the start of the needle.
    ODataRegex *anywhere = OISThen(@[ OISAnyRun(), needle, OISAnyRun() ]);
    ODataRegex *(^clear)(long long) = ^ODataRegex *(long long i) {
      ODataRegex *notNeedle = OISThen(@[ [ODataRegex look:needle behind:NO negated:YES], [ODataRegex any:ODataRegexAnyCodePoint] ]);
      return [ODataRegex repeat:notNeedle minimum:(NSUInteger)i maximum:(NSUInteger)i lazy:NO];
    };
    // Found first at k; found at k or later; found before k.
    NSPredicate *(^at)(long long) = ^NSPredicate *(long long i) {
      return i < 0 ? not(matches(anywhere)) : matches(OISThen(@[ clear(i), needle, OISAnyRun() ]));
    };
    NSPredicate *(^from)(long long) = ^NSPredicate *(long long i) {
      return matches(OISThen(@[ clear(MAX(i, 0)), OISAnyRun(), needle, OISAnyRun() ]));
    };
    NSPredicate *(^before)(long long) = ^NSPredicate *(long long i) {
      return i <= 0 ? not(matches(anywhere))
                    : [NSCompoundPredicate orPredicateWithSubpredicates:@[ not(matches(anywhere)),
                                                                          matches(OISThen(@[ OISRun(0, (NSUInteger)(i - 1)), needle, OISAnyRun() ])) ]];
    };
    switch (type) {
      case NSEqualToPredicateOperatorType: return at(k);
      case NSNotEqualToPredicateOperatorType: return not(at(k));
      case NSGreaterThanOrEqualToPredicateOperatorType: return k < 0 ? [NSPredicate predicateWithValue:YES] : from(k);
      case NSGreaterThanPredicateOperatorType: return k < -1 ? [NSPredicate predicateWithValue:YES] : from(k + 1);
      case NSLessThanPredicateOperatorType: return before(k);
      case NSLessThanOrEqualToPredicateOperatorType: return before(k + 1);
      default: return [self unsupported:@"indexof() with that operator"];
    }
  }
  NSString *v = [literal.value isKindOfClass:[NSString class]] ? literal.value : nil;
  if (!v) return [self fail:400 message:[NSString stringWithFormat:@"%@() is compared with a string, not %@", f, literal]];
  if (type != NSEqualToPredicateOperatorType && type != NSNotEqualToPredicateOperatorType) {
    return [self unsupported:[NSString stringWithFormat:@"%@() with anything but eq and ne", f]];
  }
  NSPredicate *match;
  if ([f isEqualToString:@"substring"]) {
    long long start = [t.stepArguments[0] longLongValue];
    BOOL counted = t.stepArguments.count > 1;
    long long length = counted ? [t.stepArguments[1] longLongValue] : 0;
    if (!v.length) {
      match = counted && length == 0 ? [NSPredicate predicateWithValue:YES] : matches(OISRun(0, (NSUInteger)start));
    } else if (counted && (long long)v.length > length) {
      match = no;
    } else {
      // Shorter than asked for: the string ends there.
      NSMutableArray *parts = [NSMutableArray arrayWithObjects:OISRun((NSUInteger)start, (NSUInteger)start), [ODataRegex literalString:v], nil];
      if (counted && (long long)v.length == length) [parts addObject:OISAnyRun()];
      match = matches(OISThen(parts));
    }
  } else if ([f isEqualToString:@"trim"]) {
    NSString *trimmed = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    ODataRegex *spaces = [ODataRegex repeat:[ODataRegex set:@[ [ODataRegexMember classOf:ODataRegexSpaces unicode:YES negated:NO] ] negated:NO]
                                    minimum:0 maximum:NSNotFound lazy:NO];
    match = ![trimmed isEqualToString:v] ? no : matches(OISThen(@[ spaces, [ODataRegex literalString:v], spaces ]));
  } else {
    // concat: what is left of the literal once the other part is taken off.
    NSString *prefix = t.stepArguments[0] == [NSNull null] ? @"" : t.stepArguments[0];
    NSString *suffix = t.stepArguments[1] == [NSNull null] ? @"" : t.stepArguments[1];
    // (hasPrefix: of an empty string is NO.)
    if (v.length < prefix.length + suffix.length || (prefix.length && ![v hasPrefix:prefix]) || (suffix.length && ![v hasSuffix:suffix])) {
      match = no;
    } else {
      NSString *rest = [v substringWithRange:NSMakeRange(prefix.length, v.length - prefix.length - suffix.length)];
      match = OISCompare(x, NSEqualToPredicateOperatorType, [NSExpression expressionForConstantValue:rest], 0);
    }
  }
  return type == NSEqualToPredicateOperatorType ? match : not(match);
}

// f(x) op literal, as a range of x: year(d) eq 2025 is 2025-01-01 <= d <
// 2026-01-01 (in UTC, as dates are written), floor(p) le 18 is p < 19,
// round(p) eq 5 is 4.5 <= p < 5.5 (half away from zero). A store can use
// an index for that, and needs no function of its own.
- (NSPredicate *)step:(OISTerm *)t type:(NSPredicateOperatorType)type literal:(ODataExpression *)literal
{
  NSString *f = t.stepFunction;
  NSExpression *x = [self valueExpression:t.inner typedBy:nil];
  if (!x) return nil;
  if ([f isEqualToString:@"length"]) return [self length:x type:type literal:literal];
  if ([@[ @"substring", @"trim", @"indexof", @"concat" ] containsObject:f]) return [self stringStep:t of:x type:type literal:literal];
  id value = literal.value;
  if (!value || value == [NSNull null]) {
    if (type != NSEqualToPredicateOperatorType && type != NSNotEqualToPredicateOperatorType) return [NSPredicate predicateWithValue:NO];
    return OISCompare(x, type, [NSExpression expressionForConstantValue:nil], 0);
  }
  if (OISDatePartPeriod(f)) return [self datePart:t type:type literal:literal of:x];

  // The integer n the comparison is about; a fraction makes eq false, ne
  // true, and moves lt, le, gt, ge to the integer next to it.
  NSDecimalNumber *half = [NSDecimalNumber decimalNumberWithString:@"0.5"];
  NSDecimalNumber *one = [NSDecimalNumber one];
  OISInterval *(^interval)(id n);
  id n;
  if ([f isEqualToString:@"date"]) {
    NSDate *day = [literal.literalType isEqualToString:@"Edm.Date"] ? ODataDateFromString(value) : nil;
    if (!day) return [self fail:400 message:[NSString stringWithFormat:@"date() is compared with a date, not %@", literal]];
    n = day;
    interval = ^OISInterval *(id start) {
      return OISIntervalMake(start, YES, [start dateByAddingTimeInterval:86400], NO);
    };
  } else {
    if (![value isKindOfClass:[NSNumber class]] || [literal.literalType isEqualToString:@"Edm.Boolean"]) {
      return [self fail:400 message:[NSString stringWithFormat:@"%@() is compared with a number, not %@", f, literal]];
    }
    NSDecimalNumber *given = [value isKindOfClass:[NSDecimalNumber class]] ? value : [NSDecimalNumber decimalNumberWithDecimal:[value decimalValue]];
    NSDecimalNumber *whole = [NSDecimalNumber decimalNumberWithDecimal:[@((long long)floor(given.doubleValue)) decimalValue]];
    if ([whole compare:given] != NSOrderedSame) {
      if (type == NSEqualToPredicateOperatorType || type == NSNotEqualToPredicateOperatorType) {
        return [NSPredicate predicateWithValue:type == NSNotEqualToPredicateOperatorType];
      }
      // f takes whole values: f < 4.5 is f <= 4, f > 4.5 is f >= 5.
      if (type == NSLessThanPredicateOperatorType) type = NSLessThanOrEqualToPredicateOperatorType;
      if (type == NSGreaterThanPredicateOperatorType) type = NSGreaterThanOrEqualToPredicateOperatorType;
      if (type == NSGreaterThanOrEqualToPredicateOperatorType) whole = [whole decimalNumberByAdding:one];
    }
    if ([f isEqualToString:@"year"]) {
      n = whole;
      interval = ^OISInterval *(NSDecimalNumber *year) {
        return OISIntervalMake(OISStartOfYear(year.longLongValue), YES, OISStartOfYear(year.longLongValue + 1), NO);
      };
    } else if ([f isEqualToString:@"floor"]) {
      n = whole;
      interval = ^OISInterval *(NSDecimalNumber *m) {
        return OISIntervalMake(m, YES, [m decimalNumberByAdding:one], NO);
      };
    } else if ([f isEqualToString:@"ceiling"]) {
      n = whole;
      interval = ^OISInterval *(NSDecimalNumber *m) {
        return OISIntervalMake([m decimalNumberBySubtracting:one], NO, m, YES);
      };
    } else {
      n = whole;
      interval = ^OISInterval *(NSDecimalNumber *m) {
        NSComparisonResult sign = [m compare:[NSDecimalNumber zero]];
        return OISIntervalMake([m decimalNumberBySubtracting:half], sign != NSOrderedAscending && sign != NSOrderedSame,
                              [m decimalNumberByAdding:half], sign == NSOrderedAscending);
      };
    }
  }

  OISInterval *i = interval(n);
  NSExpression *lo = [NSExpression expressionForConstantValue:i.lower];
  NSExpression *hi = [NSExpression expressionForConstantValue:i.upper];
  NSPredicate *aboveLower = OISCompare(x, i.lowerIn ? NSGreaterThanOrEqualToPredicateOperatorType : NSGreaterThanPredicateOperatorType, lo, 0);
  NSPredicate *belowUpper = OISCompare(x, i.upperIn ? NSLessThanOrEqualToPredicateOperatorType : NSLessThanPredicateOperatorType, hi, 0);
  switch (type) {
    case NSEqualToPredicateOperatorType:
      return OISAnd(aboveLower, belowUpper);
    case NSNotEqualToPredicateOperatorType: {
      // null ne n, as for any value.
      NSPredicate *none = OISCompare(x, NSEqualToPredicateOperatorType, [NSExpression expressionForConstantValue:nil], 0);
      NSPredicate *below = OISCompare(x, i.lowerIn ? NSLessThanPredicateOperatorType : NSLessThanOrEqualToPredicateOperatorType, lo, 0);
      NSPredicate *above = OISCompare(x, i.upperIn ? NSGreaterThanPredicateOperatorType : NSGreaterThanOrEqualToPredicateOperatorType, hi, 0);
      return [NSCompoundPredicate orPredicateWithSubpredicates:@[ none, below, above ]];
    }
    case NSLessThanPredicateOperatorType:
      return OISCompare(x, i.lowerIn ? NSLessThanPredicateOperatorType : NSLessThanOrEqualToPredicateOperatorType, lo, 0);
    case NSLessThanOrEqualToPredicateOperatorType:
      return belowUpper;
    case NSGreaterThanPredicateOperatorType:
      return OISCompare(x, i.upperIn ? NSGreaterThanPredicateOperatorType : NSGreaterThanOrEqualToPredicateOperatorType, hi, 0);
    case NSGreaterThanOrEqualToPredicateOperatorType:
      return aboveLower;
    default:
      return [self unsupported:[NSString stringWithFormat:@"%@() with that operator", f]];
  }
}

// month, day, hour, minute and second: the calendar unit they count
// within (a year, a month, a day, an hour, a minute), and their own.
static NSCalendarUnit OISDatePartPeriod(NSString *f)
{
  NSDictionary *periods = @{ @"month": @(NSCalendarUnitYear), @"day": @(NSCalendarUnitMonth), @"hour": @(NSCalendarUnitDay),
                             @"minute": @(NSCalendarUnitHour), @"second": @(NSCalendarUnitMinute) };
  return [periods[f] unsignedIntegerValue];
}

static NSCalendarUnit OISDatePartUnit(NSString *f)
{
  NSDictionary *units = @{ @"month": @(NSCalendarUnitMonth), @"day": @(NSCalendarUnitDay), @"hour": @(NSCalendarUnitHour),
                           @"minute": @(NSCalendarUnitMinute), @"second": @(NSCalendarUnitSecond) };
  return [units[f] unsignedIntegerValue];
}

// date plus n of a calendar unit (gnustep-base has no
// -dateByAddingUnit:value:toDate:options:).
static NSDate *OISAddUnits(NSCalendar *calendar, NSCalendarUnit unit, NSInteger n, NSDate *date)
{
  NSDateComponents *step = [[NSDateComponents alloc] init];
  switch (unit) {
    case NSCalendarUnitYear: step.year = n; break;
    case NSCalendarUnitMonth: step.month = n; break;
    case NSCalendarUnitDay: step.day = n; break;
    case NSCalendarUnitHour: step.hour = n; break;
    case NSCalendarUnitMinute: step.minute = n; break;
    default: step.second = n; break;
  }
  return [calendar dateByAddingComponents:step toDate:date options:0];
}

// The most ranges a date part is asked as: an OR that long is still a
// statement SQLite takes (at most 999 variables in older versions).
static const NSUInteger OISMaxDateRanges = 200;

// month(d) op n, and day, hour, minute and second: not one range of d but
// one in each year (for month), month (day), day (hour), hour (minute) or
// minute (second), from the earliest d the store has to the latest, as it
// is when the request asks. month(Hired) eq 3 over 2023 to 2025 is three
// Marches, in UTC as dates are written. A store can use an index for each;
// a span of more than OISMaxDateRanges is 501.
- (NSPredicate *)datePart:(OISTerm *)t type:(NSPredicateOperatorType)type literal:(ODataExpression *)literal of:(NSExpression *)x
{
  NSString *f = t.stepFunction;
  id value = literal.value;
  if (![value isKindOfClass:[NSNumber class]] || [literal.literalType isEqualToString:@"Edm.Boolean"]) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@() is compared with a number, not %@", f, literal]];
  }
  double given = [value doubleValue];
  long long n = (long long)floor(given);
  if ((double)n != given) {
    // Whole values only: f < 4.5 is f <= 4, f > 4.5 is f >= 5.
    if (type == NSEqualToPredicateOperatorType || type == NSNotEqualToPredicateOperatorType) {
      return [NSPredicate predicateWithValue:type == NSNotEqualToPredicateOperatorType];
    }
    if (type == NSLessThanPredicateOperatorType) type = NSLessThanOrEqualToPredicateOperatorType;
    if (type == NSGreaterThanPredicateOperatorType || type == NSGreaterThanOrEqualToPredicateOperatorType) {
      type = NSGreaterThanOrEqualToPredicateOperatorType;
      n += 1;
    }
  }
  NSAttributeDescription *attribute = t.inner.attribute;
  if ((!self.context && !self.spans && !self.wanted) || !attribute || !attribute.entity) {
    return [self unsupported:[NSString stringWithFormat:@"%@() of anything but a date property", f]];
  }

  // The span: the earliest and the latest date there is; as given, else
  // as the context has it.
  NSString *key = [ODataPredicateBuilder spanKeyOfAttribute:attribute];
  if (self.wanted) {
    self.wanted[key] = attribute;
    return [NSPredicate predicateWithValue:YES];
  }
  NSDate *bounds[2] = { nil, nil };
  if (self.spans) {
    NSArray *span = self.spans[key];
    if (span.count != 2) return [self fail:500 message:[NSString stringWithFormat:@"%@(): the span of %@ was not read", f, key]];
    for (int i = 0; i < 2; i++) bounds[i] = [span[(NSUInteger)i] isKindOfClass:[NSDate class]] ? span[(NSUInteger)i] : nil;
  }
  for (int i = 0; i < 2 && !self.spans; i++) {
    NSFetchRequest *fetch = [[NSFetchRequest alloc] init];
    fetch.entity = attribute.entity;
    fetch.predicate = [NSPredicate predicateWithFormat:@"%K != nil", attribute.name];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:attribute.name ascending:i == 0] ];
    fetch.fetchLimit = 1;
    NSError *error = nil;
    NSArray *rows = [self.context executeFetchRequest:fetch error:&error];
    if (!rows) return [self fail:500 message:[NSString stringWithFormat:@"%@() could not read the dates: %@", f, error.localizedDescription]];
    id date = [rows.firstObject valueForKey:attribute.name];
    bounds[i] = [date isKindOfClass:[NSDate class]] ? date : nil;
  }
  BOOL different = type == NSNotEqualToPredicateOperatorType;
  if (!bounds[0] || !bounds[1]) return [NSPredicate predicateWithValue:different];

  NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSCalendarUnit period = OISDatePartPeriod(f), part = OISDatePartUnit(f);
  // Month and day count from 1; hour, minute and second from 0.
  long long base = part == NSCalendarUnitMonth || part == NSCalendarUnitDay ? 1 : 0;
  NSTimeInterval shortest = period == NSCalendarUnitYear ? 365 * 86400.0 : period == NSCalendarUnitMonth ? 28 * 86400.0
                          : period == NSCalendarUnitDay ? 86400.0 : period == NSCalendarUnitHour ? 3600.0 : 60.0;
  if ([bounds[1] timeIntervalSinceDate:bounds[0]] / shortest + 1 > OISMaxDateRanges) {
    return [self unsupported:[NSString stringWithFormat:@"%@() over %@, whose dates span more than %lu of what it counts in,",
                              f, attribute.name, (unsigned long)OISMaxDateRanges]];
  }
  NSPredicateOperatorType op = different ? NSEqualToPredicateOperatorType : type;
  NSMutableArray<NSArray<NSDate *> *> *ranges = [NSMutableArray array];
  NSDate *start = nil;
  [calendar rangeOfUnit:period startDate:&start interval:NULL forDate:bounds[0]];
  while (start && [start compare:bounds[1]] != NSOrderedDescending) {
    NSDate *end = OISAddUnits(calendar, period, 1, start);
    // The start of the k-th unit of this period, held inside it (day 31
    // of April is its end).
    NSDate *(^at)(long long) = ^NSDate *(long long k) {
      if (k <= base) return start;
      NSDate *d = OISAddUnits(calendar, part, (NSInteger)(k - base), start);
      return !d || [d compare:end] == NSOrderedDescending ? end : d;
    };
    NSDate *lo, *hi;
    switch (op) {
      case NSEqualToPredicateOperatorType: lo = at(n); hi = at(n + 1); break;
      case NSLessThanPredicateOperatorType: lo = start; hi = at(n); break;
      case NSLessThanOrEqualToPredicateOperatorType: lo = start; hi = at(n + 1); break;
      case NSGreaterThanPredicateOperatorType: lo = at(n + 1); hi = end; break;
      case NSGreaterThanOrEqualToPredicateOperatorType: lo = at(n); hi = end; break;
      default: return [self unsupported:[NSString stringWithFormat:@"%@() with that operator", f]];
    }
    // A unit that is not there (day 31 of April) is where it would end.
    if (n < base || (op == NSEqualToPredicateOperatorType && [at(n) isEqualToDate:end])) {
      if (op == NSEqualToPredicateOperatorType) lo = hi = end;
    }
    if ([lo compare:hi] == NSOrderedAscending) {
      if ([ranges.lastObject[1] isEqualToDate:lo]) {
        ranges[ranges.count - 1] = @[ ranges.lastObject[0], hi ];
      } else {
        [ranges addObject:@[ lo, hi ]];
      }
    }
    start = end;
  }
  NSMutableArray *each = [NSMutableArray array];
  for (NSArray<NSDate *> *range in ranges) {
    [each addObject:OISAnd(OISCompare(x, NSGreaterThanOrEqualToPredicateOperatorType, [NSExpression expressionForConstantValue:range[0]], 0),
                           OISCompare(x, NSLessThanPredicateOperatorType, [NSExpression expressionForConstantValue:range[1]], 0))];
  }
  NSPredicate *any = each.count == 1 ? each.firstObject
                   : each.count ? [NSCompoundPredicate orPredicateWithSubpredicates:each] : [NSPredicate predicateWithValue:NO];
  if (!different) return any;
  // null ne n, as for any value.
  NSPredicate *none = OISCompare(x, NSEqualToPredicateOperatorType, [NSExpression expressionForConstantValue:nil], 0);
  return [NSCompoundPredicate orPredicateWithSubpredicates:@[ none, [NSCompoundPredicate notPredicateWithSubpredicate:any] ]];
}

- (NSPredicate *)comparison:(NSPredicateOperatorType)type left:(OISTerm *)l right:(OISTerm *)r
{
  if (l.caseFunction && OISConstantString(r) &&
      (type == NSEqualToPredicateOperatorType || type == NSNotEqualToPredicateOperatorType)) {
    return [self caseless:l type:type literal:OISConstantString(r)];
  }

  // A to-one relationship compares only with null.
  if (l.kind == OISTermEntity || r.kind == OISTermEntity) {
    OISTerm *entity = l.kind == OISTermEntity ? l : r;
    OISTerm *other = entity == l ? r : l;
    BOOL null = other.kind == OISTermLiteral && (!other.literal.value || other.literal.value == [NSNull null]);
    if (!null || (type != NSEqualToPredicateOperatorType && type != NSNotEqualToPredicateOperatorType)) {
      return [self unsupported:[NSString stringWithFormat:@"Comparing %@ with anything but null", entity.wireName ?: @"an entity"]];
    }
    // $it, or a lambda's variable, is there (a cast of it may not be).
    if (!entity.keyPath) return [NSPredicate predicateWithValue:type == NSNotEqualToPredicateOperatorType];
    return OISCompare([self pathExpression:entity], type, [NSExpression expressionForConstantValue:nil], 0);
  }
  for (OISTerm *side in @[ l, r ]) {
    if (side.kind == OISTermCollection) {
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is a collection: use any, all or $count", side.wireName]];
    }
  }
  NSExpression *le = [self valueExpression:l typedBy:r];
  NSExpression *re = le ? [self valueExpression:r typedBy:l] : nil;
  if (!re) return nil;
  return OISCompare(le, type, re, 0);
}

- (NSPredicate *)stringOperator:(NSPredicateOperatorType)type name:(NSString *)name left:(ODataExpression *)left right:(ODataExpression *)right
{
  OISTerm *l = [self term:left];
  OISTerm *r = l ? [self term:right] : nil;
  if (!r) return nil;
  return [self nullable:[self stringOperator:type name:name leftTerm:l rightTerm:r] terms:@[ l, r ] type:type];
}

- (NSPredicate *)stringOperator:(NSPredicateOperatorType)type name:(NSString *)name leftTerm:(OISTerm *)l rightTerm:(OISTerm *)r
{
  if (l.kind != OISTermValue && l.kind != OISTermLiteral) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes strings", name]];
  if (l.caseFunction && OISConstantString(r)) {
    NSString *text = OISConstantString(r);
    NSString *folded = [l.caseFunction isEqualToString:@"tolower"] ? text.lowercaseString : text.uppercaseString;
    if (![folded isEqualToString:text]) return [NSPredicate predicateWithValue:NO];
    NSExpression *inner = [self valueExpression:l.inner typedBy:nil];
    return inner ? OISCompare(inner, type, [NSExpression expressionForConstantValue:text], NSCaseInsensitivePredicateOption) : nil;
  }
  NSExpression *le = [self valueExpression:l typedBy:r];
  NSExpression *re = le ? [self valueExpression:r typedBy:l] : nil;
  return re ? OISCompare(le, type, re, 0) : nil;
}

// Flags has NS.Colour'Red,Blue': the value has every bit the member has.
// A predicate has no bitwise and a store evaluates, but an enumeration's
// values are few: the flags one's are the combinations of its members'
// bits, a plain one's its members'. So it is Flags IN those that have
// the bits.
- (NSPredicate *)has:(ODataExpression *)left flags:(ODataExpression *)right
{
  OISTerm *l = [self term:left];
  if (!l) return nil;
  ODataExpression *literal = [self resolve:right];
  if (!literal) return nil;
  NSAttributeDescription *attribute = l.attribute;
  ODataSchemaEnumType *type = attribute ? [self.mapper.schema enumTypeNamed:[self.mapper.values typeNameOfAttribute:attribute] ?: @""] : nil;
  if (l.kind != OISTermValue || l.caseFunction || l.stepFunction || l.expression || !type) {
    return [self fail:400 message:[NSString stringWithFormat:@"has: %@ is not an enumeration", left]];
  }
  NSAttributeType core = attribute.attributeType;
  // Kept as text, each value is its canonical text (ODataEnumText).
  BOOL text = core == NSStringAttributeType;
  if (!text && core != NSInteger16AttributeType && core != NSInteger32AttributeType && core != NSInteger64AttributeType) {
    return [self fail:400 message:[NSString stringWithFormat:@"has: %@ is kept as neither a number nor text", left]];
  }
  if (literal.kind != ODataExpressionLiteral || ![[self.mapper.schema qualifiedName:literal.literalType ?: @""] isEqualToString:type.qualifiedName]) {
    return [self fail:400 message:[NSString stringWithFormat:@"has takes a value of %@, not %@", type.qualifiedName, literal]];
  }
  id mask = text ? ODataEnumValue(type, [literal.value description]) : [self.mapper.values coreDataValueForJSON:literal.value attribute:attribute];
  if (![mask isKindOfClass:[NSNumber class]]) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", literal, type.qualifiedName]];
  }
  long long bits = [mask longLongValue];
  NSMutableArray *values = [NSMutableArray array];
  if (type.isFlags) {
    long long all = 0;
    for (NSString *member in type.memberNames) all |= type.values[member].longLongValue;
    if (all < 0 || __builtin_popcountll((unsigned long long)all) > 16) {
      return [self unsupported:[NSString stringWithFormat:@"has on %@, with more than 16 flags", type.qualifiedName]];
    }
    // Every subset of the members' bits, from all of them down to none.
    for (long long subset = all;; subset = (subset - 1) & all) {
      if ((subset & bits) == bits) [values addObject:@(subset)];
      if (subset == 0) break;
    }
  } else {
    for (NSString *member in type.memberNames) {
      long long value = type.values[member].longLongValue;
      if ((value & bits) == bits) [values addObject:@(value)];
    }
  }
  if (text) {
    NSMutableArray *texts = [NSMutableArray array];
    for (NSNumber *value in values) [texts addObject:ODataEnumText(type, value)];
    values = texts;
  }
  NSPredicate *p = values.count ? OISCompare([self pathExpression:l], NSInPredicateOperatorType, [NSExpression expressionForConstantValue:values], 0)
                                : [NSPredicate predicateWithValue:NO];
  return [self nullable:p terms:@[ l ] type:NSInPredicateOperatorType];
}

- (NSPredicate *)in:(ODataExpression *)left list:(ODataExpression *)list
{
  NSArray *dynamicPath = [self dynamicPathOf:left];
  if (dynamicPath) {
    // Each, as eq.
    list = [self resolve:list];
    if (!list) return nil;
    if (list.kind != ODataExpressionList) return [self unsupported:@"in with anything but a list of values"];
    NSMutableArray *each = [NSMutableArray array];
    for (ODataExpression *item in list.arguments) {
      NSPredicate *p = [self dynamic:dynamicPath type:NSEqualToPredicateOperatorType literal:item];
      if (!p) return nil;
      [each addObject:p];
    }
    return [NSCompoundPredicate orPredicateWithSubpredicates:each];
  }
  OISTerm *l = [self term:left];
  if (!l) return nil;
  list = [self resolve:list];
  if (!list) return nil;
  if (list.kind != ODataExpressionList) return [self unsupported:@"in with anything but a list of values"];
  if (l.kind != OISTermValue) return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", left]];
  if (l.stepFunction) {
    // year(d) in (2024,2025): each, as eq.
    NSMutableArray *each = [NSMutableArray array];
    for (ODataExpression *item in list.arguments) {
      ODataExpression *value = [self resolve:item];
      if (!value) return nil;
      if (value.kind != ODataExpressionLiteral) return [self unsupported:@"in with anything but a list of values"];
      NSPredicate *p = [self step:l type:NSEqualToPredicateOperatorType literal:value];
      if (!p) return nil;
      [each addObject:p];
    }
    NSPredicate *any = [NSCompoundPredicate orPredicateWithSubpredicates:each];
    return [self guarded:[self nullSafe:any terms:@[ l ] type:NSInPredicateOperatorType] terms:@[ l ] whenNull:NO];
  }
  NSMutableArray *values = [NSMutableArray array];
  for (ODataExpression *item in list.arguments) {
    ODataExpression *value = [self resolve:item];
    if (!value) return nil;
    if (value.kind != ODataExpressionLiteral) return [self unsupported:@"in with anything but a list of values"];
    BOOL ok;
    id typed = [self valueOfLiteral:value attribute:l.attribute ok:&ok];
    if (!ok) return nil;
    [values addObject:typed ?: [NSNull null]];
  }
  NSPredicate *p = OISCompare([self valueExpression:l typedBy:nil], NSInPredicateOperatorType,
                              [NSExpression expressionForConstantValue:values], 0);
  if (![values containsObject:[NSNull null]]) p = [self nullSafe:p terms:@[ l ] type:NSInPredicateOperatorType];
  return [self guarded:p terms:@[ l ] whenNull:[values containsObject:[NSNull null]]];
}

- (NSPredicate *)lambda:(ODataExpression *)e
{
  OISTerm *collection = [self term:e.operand];
  if (!collection) return nil;
  if (collection.kind != OISTermCollection) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@/%@: %@ is not a collection", e.operand, e.name, e.operand]];
  }
  BOOL all = [e.name isEqualToString:@"all"];
  NSExpression *zero = [NSExpression expressionForConstantValue:@0];
  if (!e.body && all) return [self fail:400 message:@"all needs a condition"];
  if (!e.body && !collection.elementType) {
    NSExpression *count = [self pathExpression:collection];
    count = [NSExpression expressionForFunction:@"count:" arguments:@[ count ]];
    return [self any:collection count:count falseCount:count];
  }

  OISTerm *element = [self elementOf:collection];
  if (!e.body) {
    NSExpression *subquery = [NSExpression expressionForSubquery:[self pathExpression:collection]
                                            usingIteratorVariable:element.variable
                                                        predicate:[self member:element of:collection test:nil]];
    NSExpression *count = [NSExpression expressionForFunction:@"count:" arguments:@[ subquery ]];
    return [self any:collection count:count falseCount:count];
  }
  element.wireName = e.variable;
  NSString *variable = element.variable;
  OISTerm *outer = self.scope[e.variable];
  self.scope[e.variable] = element;
  NSPredicate *body = [self predicate:e.body];
  if (outer) {
    self.scope[e.variable] = outer;
  } else {
    [self.scope removeObjectForKey:e.variable];
  }
  if (!body) return nil;

  // any: some element matches; all: none fails to. Of a cast collection,
  // its elements of the type.
  NSExpression *(^counted)(NSPredicate *) = ^NSExpression *(NSPredicate *test) {
    NSExpression *subquery = [NSExpression expressionForSubquery:[self pathExpression:collection]
                                            usingIteratorVariable:variable
                                                        predicate:[self member:element of:collection test:test]];
    return [NSExpression expressionForFunction:@"count:" arguments:@[ subquery ]];
  };
  NSPredicate *notTrue = [NSCompoundPredicate notPredicateWithSubpredicate:body];
  if (!all) {
    if (!collection.guard && ![self mayBeNull:body]) {
      NSExpression *count = counted(body);
      return [self any:collection count:count falseCount:count];
    }
    // False where no member's condition is true or null: none could be.
    NSPredicate *notFalse = [self mayBeNull:body] ? [NSCompoundPredicate notPredicateWithSubpredicate:[self falsehoodOf:body]] : body;
    return [self any:collection count:counted(body) falseCount:counted(notFalse)];
  }
  NSPredicate *p = [self guarded:OISCompare(counted(notTrue), NSEqualToPredicateOperatorType, zero, 0) terms:@[ collection ] whenNull:NO];
  if (!collection.guard && ![self mayBeNull:body]) return p;
  // False where some member's condition is false; null where the
  // collection is, or none is false and some null.
  NSPredicate *f = [self guarded:OISCompare(counted([self falsehoodOf:body]), NSGreaterThanPredicateOperatorType, zero, 0)
                           terms:@[ collection ]
                        whenNull:NO];
  return [self condition:p falseWhere:f];
}

// any: true where count is more than 0. Of a collection that may be null
// (through a null to-one, or a cast that does not hold: its guard), null
// there (URL conventions 5.1.1.15); else false where falseCount, the
// members that are not known not to match, is 0.
- (NSPredicate *)any:(OISTerm *)collection count:(NSExpression *)count falseCount:(NSExpression *)falseCount
{
  NSExpression *zero = [NSExpression expressionForConstantValue:@0];
  NSPredicate *p = [self guarded:OISCompare(count, NSGreaterThanPredicateOperatorType, zero, 0) terms:@[ collection ] whenNull:NO];
  if (!collection.guard && count == falseCount) return p;
  NSPredicate *f = [self guarded:OISCompare(falseCount, NSEqualToPredicateOperatorType, zero, 0) terms:@[ collection ] whenNull:NO];
  return [self condition:p falseWhere:f];
}

// A new variable for the members of a collection.
- (OISTerm *)elementOf:(OISTerm *)collection
{
  OISTerm *element = [[OISTerm alloc] init];
  element.kind = OISTermEntity;
  element.variable = [NSString stringWithFormat:@"v%ld", (long)self.variables++];
  element.entity = collection.entity;
  return element;
}

@end

#pragma mark - The builder

@implementation ODataPredicateBuilder

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper
{
  self = [super init];
  if (!self) return nil;
  _mapper = mapper;
  return self;
}

- (instancetype)builderWithUserInfo:(id)userInfo
{
  ODataPredicateBuilder *builder = [[[self class] alloc] initWithMapper:self.mapper];
  builder.entitiesByTypeName = self.entitiesByTypeName;
  builder.restrictedProperties = self.restrictedProperties;
  builder.dynamicProperty = self.dynamicProperty;
  builder->_userInfo = userInfo;
  return builder;
}

- (OISPredicateBuild *)buildForEntity:(NSEntityDescription *)entity aliases:(NSDictionary *)aliases
{
  OISPredicateBuild *build = [[OISPredicateBuild alloc] init];
  build.mapper = self.mapper;
  build.root = entity;
  build.aliases = aliases ?: @{};
  build.scope = [NSMutableDictionary dictionary];
  build.entitiesByTypeName = self.entitiesByTypeName ?: @{};
  build.restrictedProperties = self.restrictedProperties;
  build.dynamicProperty = self.dynamicProperty;
  build.userInfo = self.userInfo;
  return build;
}

- (NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                 entity:(NSEntityDescription *)entity
                                aliases:(NSDictionary *)aliases
                                  error:(NSError **)error
{
  return [self predicateForExpression:expression entity:entity aliases:aliases context:nil error:error];
}

- (NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                 entity:(NSEntityDescription *)entity
                                aliases:(NSDictionary *)aliases
                                context:(NSManagedObjectContext *)context
                                  error:(NSError **)error
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:aliases];
  build.context = context;
  NSPredicate *predicate = [build predicate:expression];
  if (!predicate && error) *error = build.error ?: ODataServiceError(400, @"The filter does not apply");
  return predicate;
}

+ (NSString *)spanKeyOfAttribute:(NSAttributeDescription *)attribute
{
  return [NSString stringWithFormat:@"%@.%@", attribute.entity.name, attribute.name];
}

- (NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                 entity:(NSEntityDescription *)entity
                                aliases:(NSDictionary *)aliases
                               computed:(NSDictionary *)computed
                                  spans:(NSDictionary *)spans
                                  error:(NSError **)error
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:aliases];
  build.spans = spans ?: @{};
  build.computed = computed ?: @{};
  NSPredicate *predicate = [build predicate:expression];
  if (!predicate && error) *error = build.error ?: ODataServiceError(400, @"The filter does not apply");
  return predicate;
}

- (NSArray<NSAttributeDescription *> *)spanAttributesOfExpression:(ODataExpression *)expression entity:(NSEntityDescription *)entity
                                                            aliases:(NSDictionary *)aliases computed:(NSDictionary *)computed
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:aliases];
  build.wanted = [NSMutableDictionary dictionary];
  build.computed = computed ?: @{};
  [build predicate:expression];
  return build.wanted.allValues;
}

- (NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                 entity:(NSEntityDescription *)entity
                                aliases:(NSDictionary *)aliases
                               computed:(NSDictionary *)computed
                                context:(NSManagedObjectContext *)context
                                  error:(NSError **)error
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:aliases];
  build.context = context;
  build.computed = computed ?: @{};
  NSPredicate *predicate = [build predicate:expression];
  if (!predicate && error) *error = build.error ?: ODataServiceError(400, @"The filter does not apply");
  return predicate;
}

- (NSExpression *)valueExpressionForExpression:(ODataExpression *)expression
                                        entity:(NSEntityDescription *)entity
                                       aliases:(NSDictionary *)aliases
                                      computed:(NSDictionary *)computed
                                         error:(NSError **)error
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:aliases];
  build.computed = computed ?: @{};
  OISTerm *t = [build term:expression];
  if (t && (t.kind == OISTermEntity || t.kind == OISTermCollection)) {
    [build fail:400 message:[NSString stringWithFormat:@"%@ is not a value", expression]];
    t = nil;
  }
  NSExpression *value = t ? [build valueExpression:t typedBy:nil] : nil;
  if (!value && error) *error = build.error ?: ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a value", expression]);
  return value;
}

- (NSArray *)sortDescriptorsForOrderBy:(NSArray *)items entity:(NSEntityDescription *)entity computed:(NSDictionary *)computed
                              inMemory:(BOOL *)inMemory error:(NSError **)error
{
  *inMemory = NO;
  NSError *keyPathError = nil;
  // A computed name that stands for a property path is that path: the
  // store sorts by it. Anything beyond a path (a computed value, an
  // arithmetic expression) is sorted here: a store sorts by key paths only.
  NSArray *keyPaths = [self keyPathSortForOrderBy:items entity:entity computed:computed error:&keyPathError];
  if (keyPaths) return keyPaths;
  if (!computed.count && keyPathError.code != 501) {
    if (error) *error = keyPathError;
    return nil;
  }
  *inMemory = YES;
  // Each item's value with each object, compared: nulls first, as OData
  // sorts them ascending.
  NSMutableArray *descriptors = [NSMutableArray array];
  for (ODataOrderItem *item in items) {
    NSExpression *value = [self valueExpressionForExpression:item.expression entity:entity aliases:nil computed:computed error:error];
    if (!value) return nil;
    [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"self" ascending:!item.descending comparator:^NSComparisonResult(id a, id b) {
      id x = nil, y = nil;
      @try {
        x = [value expressionValueWithObject:a context:nil];
      } @catch (NSException *exception) {
        x = nil;
      }
      @try {
        y = [value expressionValueWithObject:b context:nil];
      } @catch (NSException *exception) {
        y = nil;
      }
      if (x == [NSNull null]) x = nil;
      if (y == [NSNull null]) y = nil;
      if (!x || !y) return !x && !y ? NSOrderedSame : (!x ? NSOrderedAscending : NSOrderedDescending);
      return [x compare:y];
    }]];
  }
  return descriptors;
}

- (NSArray *)sortDescriptorsForOrderBy:(NSArray *)items entity:(NSEntityDescription *)entity error:(NSError **)error
{
  return [self keyPathSortForOrderBy:items entity:entity computed:nil error:error];
}

- (NSArray *)keyPathSortForOrderBy:(NSArray *)items entity:(NSEntityDescription *)entity computed:(NSDictionary *)computed error:(NSError **)error
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:nil];
  build.sorting = YES;
  build.computed = computed;
  NSMutableArray *descriptors = [NSMutableArray array];
  for (ODataOrderItem *item in items) {
    OISTerm *t = [build term:item.expression];
    if (t && (t.kind != OISTermValue || t.expression || t.caseFunction || t.variable || !t.keyPath || t.guard)) {
      [build unsupported:[NSString stringWithFormat:@"Ordering by %@", item.expression]];
      t = nil;
    }
    if (!t) {
      if (error) *error = build.error;
      return nil;
    }
    [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:t.keyPath ascending:!item.descending]];
  }
  return descriptors;
}

- (NSString *)keyPathForPath:(NSArray *)path entity:(NSEntityDescription *)entity property:(NSPropertyDescription **)property error:(NSError **)error
{
  NSMutableArray *keys = [NSMutableArray array];
  NSEntityDescription *current = entity;
  NSPropertyDescription *found = nil;
  for (NSUInteger i = 0; i < path.count; i++) {
    NSString *name = path[i];
    found = current ? [self.mapper propertyForWireName:name entity:current] : nil;
    if (!found) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", current.name ?: @"A value", name]);
      return nil;
    }
    [keys addObject:found.name];
    NSRelationshipDescription *relationship = [found isKindOfClass:[NSRelationshipDescription class]] ? (NSRelationshipDescription *)found : nil;
    if (relationship.isToMany && i + 1 < path.count) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is a collection", name]);
      return nil;
    }
    current = relationship.destinationEntity;
  }
  if (property) *property = found;
  return [keys componentsJoinedByString:@"."];
}

@end
