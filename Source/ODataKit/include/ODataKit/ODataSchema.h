// ODataIncrementalStore — the service's $metadata (CSDL XML).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What the store needs of a service's schema (OData CSDL XML 4.0): entity
// types with their keys, properties, navigation properties and base types;
// complex types with their properties and base types; enumeration types;
// entity sets. A property typed by a type definition takes its underlying
// type. Annotations are read into their targets. Type names are
// kept qualified by namespace; an alias ("Self.Person") resolves to its
// namespace, in a collection's element type too. Functions and actions
// are read with their parameters and return types, and their imports.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataSchemaProperty : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;          // qualified: Edm.String, NS.Color, Collection(Edm.String)
@property (nonatomic) BOOL nullable;
@property (nonatomic, copy, nullable) NSNumber *maxLength;  // MaxLength; nil for none, or max
@property (nonatomic, readonly) BOOL isCollection;
@property (nonatomic, readonly) NSString *elementType;  // the type, without Collection()
@end

@interface ODataSchemaNavigationProperty : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;          // the target entity type, qualified, without Collection()
@property (nonatomic) BOOL isCollection;
@property (nonatomic) BOOL containsTarget;
@property (nonatomic, copy, nullable) NSString *partner;
@end

@interface ODataSchemaEntityType : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic, copy, nullable) NSString *baseType;  // qualified
@property (nonatomic) BOOL isAbstract;
@property (nonatomic) BOOL hasStream;  // HasStream="true": a media entity
@property (nonatomic) BOOL isOpen;     // OpenType="true": its entities may have dynamic properties
@property (nonatomic, copy) NSArray<NSString *> *declaredKey;  // empty on a derived type
@property (nonatomic, copy) NSDictionary<NSString *, ODataSchemaProperty *> *declaredProperties;
@property (nonatomic, copy) NSDictionary<NSString *, ODataSchemaNavigationProperty *> *declaredNavigationProperties;
@end

// A structured value without identity (CSDL section 9). Navigation
// properties of complex types are read past.
@interface ODataSchemaComplexType : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic, copy, nullable) NSString *baseType;  // qualified
@property (nonatomic) BOOL isAbstract;
@property (nonatomic) BOOL isOpen;
@property (nonatomic, copy) NSDictionary<NSString *, ODataSchemaProperty *> *declaredProperties;
@end

@interface ODataSchemaEnumType : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic) BOOL isFlags;
@property (nonatomic, copy) NSArray<NSString *> *memberNames;       // in declaration order
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *values;
@end

@interface ODataSchemaParameter : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;  // qualified, Collection(...) for a collection
@property (nonatomic) BOOL nullable;
@end

// A function or an action (CSDL sections 12.1-12.2). A bound one's first
// parameter is its binding parameter: the entity, or the collection of
// entities, it is a method of.
@interface ODataSchemaOperation : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic) BOOL isAction;
@property (nonatomic) BOOL isBound;
@property (nonatomic) BOOL isComposable;
@property (nonatomic, copy) NSArray<ODataSchemaParameter *> *parameters;  // the binding parameter first
@property (nonatomic, copy, nullable) NSString *returnType;               // nil: returns nothing
@property (nonatomic, readonly, nullable) ODataSchemaParameter *bindingParameter;
// The parameters a caller gives: all but the binding one.
@property (nonatomic, readonly) NSArray<ODataSchemaParameter *> *callerParameters;
@end

// An unbound operation, as the entity container names it.
@interface ODataSchemaOperationImport : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *operation;            // qualified
@property (nonatomic) BOOL isAction;
@property (nonatomic, copy, nullable) NSString *entitySet;  // where returned entities live
@end

// A way to sign in the service declares (the Authorization vocabulary),
// in the order its SecuritySchemes list them.
@interface ODataSchemaAuthorization : NSObject
@property (nonatomic, copy) NSString *name;
// OpenIDConnect, Http, ApiKey, OAuth2ClientCredentials, OAuth2Implicit,
// OAuth2Password, OAuth2AuthCode.
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy, nullable) NSString *text;              // its Description
@property (nonatomic, copy, nullable) NSURL *issuerURL;            // OpenIDConnect
@property (nonatomic, copy, nullable) NSString *scheme;            // Http: bearer, basic
@property (nonatomic, copy, nullable) NSString *keyName;           // ApiKey
@property (nonatomic, copy, nullable) NSString *location;          // ApiKey: Header, QueryOption, Cookie
@property (nonatomic, copy, nullable) NSURL *tokenURL;             // OAuth2 flows
@property (nonatomic, copy, nullable) NSURL *authorizationURL;     // OAuth2Implicit, AuthCode
@property (nonatomic, copy) NSArray<NSString *> *requiredScopes;  // SecuritySchemes'
// A bearer token signs requests in: OpenIDConnect, OAuth2 flows, Http bearer.
@property (nonatomic, readonly) BOOL usesBearerToken;
@end

/* ODataKit's own: exported where ODataKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef ODATAKIT_EXPORT
#define ODATAKIT_EXPORT FOUNDATION_EXPORT
#endif

// A name as $metadata spells it: the one of names that differs from it only
// in case (a 4.01 client sends identifiers as $metadata has them, Part 1
// section 13.3, item 17), else the name itself.
ODATAKIT_EXPORT NSString *ODataSchemaSpelling(NSString *name, id<NSFastEnumeration> _Nullable names);

@interface ODataSchema : NSObject

// CSDL XML, or CSDL JSON (4.01).
+ (nullable instancetype)schemaWithData:(NSData *)csdl error:(NSError **)error;

@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaEntityType *> *entityTypes;  // by qualified name
@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaComplexType *> *complexTypes;  // by qualified name
@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaEnumType *> *enumTypes;      // by qualified name
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *entitySets;                // name -> qualified type
// By qualified name: the overloads of each (functions overload by binding
// type and parameter names).
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<ODataSchemaOperation *> *> *operations;
@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaOperationImport *> *operationImports;  // by name
// The OData version the service speaks: the highest its container's
// Core.ODataVersions lists ("4.0 4.01"), else <edmx:Edmx Version="4.01">.
@property (nonatomic, readonly, copy) NSString *version;
// The entity container is annotated Org.OData.Capabilities.V1.KeyAsSegmentSupported.
@property (nonatomic, readonly) BOOL keyAsSegmentSupported;

// Annotations (CSDL section 14), inline and in <Annotations Target>: by
// target (NS.Product, NS.Product/Name, NS.Container, NS.Container/Products,
// NS.Colour/Red), the value of each term applied to it, by the term's
// qualified name (Org.OData.Core.V1.Description, with #Qualifier after it
// for a qualified one, and Term@Term for an annotation of an annotation:
// Validation.Maximum@Validation.Exclusive). Values as JSON CSDL has them: strings, numbers,
// Booleans (a tag is true), an enumeration's member names ("Read,Write"),
// a Collection an array, a Record a dictionary (its type as @type), a path
// {"$Path": "..."} ($PropertyPath, $NavigationPropertyPath, ...), a dynamic
// expression {"$If": [...]}, {"$Apply": [...], "$Function": "..."}.
@property (nonatomic, readonly) NSDictionary<NSString *, NSDictionary<NSString *, id> *> *annotations;
// For a target as the document names it, alias or not.
- (NSDictionary<NSString *, id> *)annotationsForTarget:(NSString *)target;
// A term qualified, alias-qualified, or by a standard vocabulary's own
// name whatever alias the document gives it (Core.Computed,
// Validation.Maximum, Capabilities.InsertRestrictions).
- (nullable id)annotation:(NSString *)term forTarget:(NSString *)target;
// On a property of an entity type, or of the base type declaring it.
- (nullable id)annotation:(NSString *)term forProperty:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type;
// The entity container, qualified.
@property (nonatomic, readonly, copy, nullable) NSString *containerName;
// The ways to sign in the container's Authorization.Authorizations
// declare: those SecuritySchemes name first, in their order, with their
// scopes; then any other.
@property (nonatomic, readonly, copy) NSArray<ODataSchemaAuthorization *> *authorizations;
// A term (Capabilities.TopSupported) for an entity set: its own
// annotation, else the container's.
- (nullable id)capability:(NSString *)term forEntitySet:(nullable NSString *)set;

// A qualified or alias-qualified name, as the schema's qualified name.
- (NSString *)qualifiedName:(NSString *)name;
- (nullable ODataSchemaEntityType *)entityTypeNamed:(NSString *)name;
- (nullable ODataSchemaComplexType *)complexTypeNamed:(NSString *)name;
- (nullable ODataSchemaEnumType *)enumTypeNamed:(NSString *)name;
// The entity type with this simple name, if exactly one has it.
- (nullable ODataSchemaEntityType *)entityTypeWithSimpleName:(NSString *)name;

// Through the base types.
- (NSArray<NSString *> *)keyOfEntityType:(ODataSchemaEntityType *)type;
- (nullable ODataSchemaProperty *)property:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type;
- (nullable ODataSchemaNavigationProperty *)navigationProperty:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type;
- (BOOL)entityType:(ODataSchemaEntityType *)type isOrDerivesFrom:(ODataSchemaEntityType *)ancestor;
// A media entity's type, or one derived from it (Part 1 section 11.1.2).
- (BOOL)entityTypeHasStream:(ODataSchemaEntityType *)type;
// Whether it, or a type it derives from, is open.
- (BOOL)entityTypeIsOpen:(ODataSchemaEntityType *)type;
// Its Edm.Stream properties, its base types' too, by name.
- (NSArray<NSString *> *)streamPropertiesOfEntityType:(ODataSchemaEntityType *)type;
- (nullable ODataSchemaProperty *)property:(NSString *)name ofComplexType:(ODataSchemaComplexType *)type;
// Its properties and its base types', by name.
- (NSDictionary<NSString *, ODataSchemaProperty *> *)propertiesOfComplexType:(ODataSchemaComplexType *)type;

// The entity set holding entities of this type: one declared for it, or
// for its nearest base type that has one.
- (nullable NSString *)entitySetForEntityType:(ODataSchemaEntityType *)type;

// The operations bound to this entity type or a base of it; with
// collection, to a collection of them.
- (NSArray<ODataSchemaOperation *> *)operationsBoundToEntityType:(ODataSchemaEntityType *)type collection:(BOOL)collection;
// The one to call: bound to this type (or a base) or its collection, or
// unbound when type is nil; named simply or qualified; an overload whose
// parameters are these names, else the only one.
- (nullable ODataSchemaOperation *)operationNamed:(NSString *)name
                                   boundToEntityType:(nullable ODataSchemaEntityType *)type
                                          collection:(BOOL)collection
                                      parameterNames:(nullable NSSet<NSString *> *)names;

// Whether entities of this type are contained in others (a navigation
// property with ContainsTarget reaches this type or a base of it): such
// entities have no entity set, and are reached through their container.
- (BOOL)entityTypeIsContained:(ODataSchemaEntityType *)type;

@end

NS_ASSUME_NONNULL_END
