// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OISCoreData.h"
#import "ODataValue.h"
#import "ODataSchema.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ODataPropertyNaming) {
  ODataPropertyNamingAsIs = 0,
  ODataPropertyNamingPascalCase = 1
};


FOUNDATION_EXPORT NSString * const ODataUserInfoEntitySet;
FOUNDATION_EXPORT NSString * const ODataUserInfoProperty;
FOUNDATION_EXPORT NSString * const ODataUserInfoKey;
// The Core vocabulary in userInfo: OData.description and
// OData.longDescription (text), OData.computed and OData.immutable (YES),
// OData.permissions (Read, ReadWrite, None); and OData.annotations, any
// annotations at all, by term, as a dictionary of JSON CSDL values or JSON
// text of one ({"Validation.Pattern": "^[A-Z]", "Core.Description#fr":
// "Nom"}). A service writes them into $metadata; a model built from
// $metadata has them from its annotations.
FOUNDATION_EXPORT NSString * const ODataUserInfoDescription;
FOUNDATION_EXPORT NSString * const ODataUserInfoLongDescription;
FOUNDATION_EXPORT NSString * const ODataUserInfoComputed;
FOUNDATION_EXPORT NSString * const ODataUserInfoImmutable;
FOUNDATION_EXPORT NSString * const ODataUserInfoPermissions;
FOUNDATION_EXPORT NSString * const ODataUserInfoAnnotations;
// The Measures vocabulary in userInfo: OData.unit (Measures.Unit, "kg"),
// OData.isoCurrency (Measures.ISOCurrency: an ISO 4217 code, "EUR", or the
// name of the attribute that holds one), OData.scale (Measures.Scale: the
// decimal places that are significant).
FOUNDATION_EXPORT NSString * const ODataUserInfoUnit;
FOUNDATION_EXPORT NSString * const ODataUserInfoISOCurrency;
FOUNDATION_EXPORT NSString * const ODataUserInfoScale;
// An open type's dynamic properties (JSON Format section 4.6.3), which the
// model does not declare: OData.dynamicProperties YES on a Transformable
// attribute (an NSDictionary) marks it as the property bag that holds them,
// by name, each value as ODataValueCoder's -dynamicPropertiesInJSON:...
// reads it. It is no property on the wire: its entries are, each by its
// own name, read from what the entity's JSON has that nothing declares,
// written back as members of their own (a removed one as null), and a key
// path into it (dynamicProperties.Nickname) is the property's name
// (Nickname). Assign a new dictionary to change it: Core Data does not see
// a dictionary change in place.
FOUNDATION_EXPORT NSString * const ODataUserInfoDynamicProperties;
// OData.served NO on an attribute or a relationship leaves it out of what
// a service serves: it is no property of its entity type, in $metadata or
// a payload, and naming it -- in a path, a query option or a body -- is an
// error as for any unknown name. What an application keeps for itself
// beside what it serves. A key cannot be left out. A client's store, over
// the same model, leaves it out of what it sends and asks for, refuses to
// filter or sort by it, and keeps what a save gives it in memory, for as
// long as the store is open: the service never has it.
FOUNDATION_EXPORT NSString * const ODataUserInfoServed;
// Application time (the Temporal vocabulary), userInfo on an entity whose
// rows are time slices, each valid for a period (Temporal.TimelineVisible):
// OData.periodStart and OData.periodEnd name its Date attributes, the
// period's start and end (none or 9999-12-31: no end); OData.objectKey the
// attributes, comma-separated, that say which object a slice belongs to
// (none: one object); OData.closedClosedPeriods YES when the end is the
// last day of the period rather than the first after it (Edm.Date only).
FOUNDATION_EXPORT NSString * const ODataUserInfoPeriodStart;
FOUNDATION_EXPORT NSString * const ODataUserInfoPeriodEnd;
FOUNDATION_EXPORT NSString * const ODataUserInfoObjectKey;
FOUNDATION_EXPORT NSString * const ODataUserInfoClosedClosedPeriods;

@interface ODataPropertyMapper : NSObject
@property (nonatomic) ODataPropertyNaming naming;
// How values are written and read; see ODataValue.h.
@property (nonatomic, strong) ODataValueCoder *values;

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity;
- (NSString *)propertyForAttribute:(NSAttributeDescription *)attribute;
- (NSString *)propertyForRelationship:(NSRelationshipDescription *)relationship;
- (NSArray<NSAttributeDescription *> *)keyAttributesForEntity:(NSEntityDescription *)entity;
// The other way: the attribute or relationship of an entity (its own or
// inherited) that a service calls this; nil when there is none.
- (nullable NSPropertyDescription *)propertyForWireName:(NSString *)name entity:(NSEntityDescription *)entity;
// The root entities a service serves, by name (each with its
// sub-entities); nil, the default: every one. A relationship to an entity
// not served is no property of its entity: propertyForWireName: does not
// find it.
@property (nonatomic, copy, nullable) NSSet<NSString *> *servedEntityNames;
// Whether the relationship leads to an entity that is served.
- (BOOL)servesRelationship:(NSRelationshipDescription *)relationship;
// Whether the property is served: not OData.served NO, and a relationship
// to an entity that is served.
- (BOOL)servesProperty:(NSPropertyDescription *)property;
- (NSString *)wireName:(NSString *)coreDataName;
// The property bag of an open type's entity (OData.dynamicProperties), its
// own or inherited; nil for none.
- (nullable NSAttributeDescription *)dynamicPropertiesAttributeOfEntity:(NSEntityDescription *)entity;
- (BOOL)attributeHoldsDynamicProperties:(nullable NSAttributeDescription *)attribute;
// A Core Data key path as an OData property path: each step by its wire
// name, through relationships, joined with '/' (Part 2 section 5.1.1.15).
// A key path that goes on past an attribute holding a complex value
// (address.city) goes on into its members: Address/City.
- (NSString *)propertyPathForKeyPath:(NSString *)keyPath entity:(nullable NSEntityDescription *)entity;
// The same, with the type the path ends at, when it ends in a complex
// value's member (qualified; nil otherwise).
- (NSString *)propertyPathForKeyPath:(NSString *)keyPath
                              entity:(nullable NSEntityDescription *)entity
                          memberType:(NSString * _Nullable * _Nullable)memberType;
// Members of a value of this type (a complex type, or a collection of
// one): each by the schema's name for it, which may differ in case from
// the one given, joined with '/'; the last one's type through memberType.
- (NSString *)memberPath:(NSArray<NSString *> *)members
                  ofType:(nullable NSString *)typeName
              memberType:(NSString * _Nullable * _Nullable)memberType;

// The service's $metadata, when it could be read. With it the mapper finds
// what the model leaves unsaid: an entity's type and entity set (Person
// is in People), a key with no OData.key, a property's Edm type (an
// Edm.Date on a Date attribute, an enumeration), a name whose case differs
// from the attribute's. userInfo in the model always wins.
@property (nonatomic, strong, nullable) ODataSchema *schema;

// The entity type an entity stands for: userInfo[@"OData.type"] on the
// entity, else the schema's entity type of the entity's name.
- (nullable ODataSchemaEntityType *)entityTypeForEntity:(NSEntityDescription *)entity;
// An attribute a client does not write: Core.Computed, or Core.Permissions
// Read (or None), in its userInfo or the schema's annotations of its
// property.
- (BOOL)attributeIsComputed:(NSAttributeDescription *)attribute;
// Written when the entity is made, and not after: Core.Immutable.
- (BOOL)attributeIsImmutable:(NSAttributeDescription *)attribute;
// Measures: the attribute's unit (Measures.Unit, else UNECEUnit), its
// significant decimal places (Measures.Scale; nil for none said), and
// the ISO 4217 currency of an amount (Measures.ISOCurrency), read from
// the object when the currency is another of its properties.
- (nullable NSString *)unitOfAttribute:(NSAttributeDescription *)attribute;
- (nullable NSNumber *)scaleOfAttribute:(NSAttributeDescription *)attribute;
- (nullable NSString *)currencyOfAttribute:(NSAttributeDescription *)attribute inObject:(nullable NSManagedObject *)object;
// What of the Validation vocabulary Core Data cannot hold an object
// breaks: Validation.MultipleOf of an attribute, Validation.Constraint of
// its entity type or a property (a condition, a CSDL expression over the
// entity's properties: Eq, Ne, Gt, Ge, Lt, Le, And, Or, Not, If, In, Path,
// Null, constants, and Apply of odata.matchesPattern; a property's only
// while it has a value). A
// NSManagedObjectValidationError naming the object, and the property, with
// the constraint's FailureMessage; nil when it breaks none. From the
// schema's annotations, else userInfo's (OData.annotations).
- (nullable NSError *)vocabularyViolationOfObject:(NSManagedObject *)object;
// A condition as a predicate of an entity's objects; nil for an expression
// it cannot write.
- (nullable NSPredicate *)predicateForCondition:(id)condition entity:(NSEntityDescription *)entity;
// Its qualified name, from the schema or from userInfo alone.
- (nullable NSString *)qualifiedTypeForEntity:(NSEntityDescription *)entity;
// The annotations of a property of an entity, or (property nil) of the
// entity type, by full term (Org.OData.Aggregation.V1.RecursiveHierarchy#Q),
// as JSON CSDL has their values: the schema's, else userInfo's
// (OData.annotations).
- (NSDictionary<NSString *, id> *)annotationsOfProperty:(nullable NSPropertyDescription *)property entity:(NSEntityDescription *)entity;
// The path an entity's rows are read from: its entity set, followed by a
// type cast (People/NS.Employee) when the entity is a derived type in a
// set of its base type (Part 2 section 4.11).
- (NSString *)collectionPathForEntity:(NSEntityDescription *)entity;
// Whether a new object of this entity is a derived type in its set, and so
// needs @odata.type in the POST body.
- (BOOL)entityIsDerivedInItsSet:(NSEntityDescription *)entity;
// The entity, or one of its sub-entities, for an entity type named in a
// row's @odata.type.
- (NSEntityDescription *)entity:(NSEntityDescription *)entity forTypeName:(nullable NSString *)typeName;
// The Edm type the schema declares for an attribute, qualified; nil
// without a schema or without the property.
- (nullable NSString *)declaredTypeForAttribute:(NSAttributeDescription *)attribute;

// What does not match between a model and the schema, one sentence each:
// an entity with no entity type or entity set, an attribute or
// relationship with no property, a type that cannot hold the other, a key
// that differs. Without a schema, and before those: an OData.entitySet or
// OData.property override that is no OData identifier (ODataIsIdentifier),
// which no request can name.
- (NSArray<NSString *> *)problemsWithModel:(NSManagedObjectModel *)model;
// The same, of a configuration's entities only (nil: all of them), and of
// their relationships within it: a store that holds one configuration
// answers for its entities, the rest being another store's, or the
// application's own.
- (NSArray<NSString *> *)problemsWithModel:(NSManagedObjectModel *)model configuration:(nullable NSString *)configuration;
@end

NS_ASSUME_NONNULL_END
