// ODataIncrementalStore — a Core Data model as CSDL.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// $metadata for a service over a Core Data model (OData 4.01 CSDL XML):
// an entity type per entity, derived types for sub-entities, a key from the
// mapper (userInfo OData.key, else id), properties typed as ODataValueCoder
// reads and writes them, navigation properties with their partners, and an
// entity set per root entity, bound to each other through the
// relationships. Names come from the same ODataPropertyMapper the client
// uses, so one model file describes both ends.
//
// A Core Data model has no complex types or enumerations. An attribute
// whose userInfo OData.type names one is written when the mapper's schema
// defines it (as it does for a model built from a service's $metadata by
// ODataModelBuilder); the definitions are copied from there.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataXML.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

// The userInfo it writes as annotations: see ODataPropertyMapper.h.

// Streams (Part 1 section 11.1.2), kept in Binary attributes. userInfo on
// a Binary attribute: an Edm.Stream property, read and written at its own
// URL (Entity(1)/Photo), never in a body.
FOUNDATION_EXPORT NSString * const ODataUserInfoStream;       // @"OData.stream", YES
// userInfo on an entity: the Binary attribute that is its media resource
// (HasStream="true", at Entity(1)/$value).
FOUNDATION_EXPORT NSString * const ODataUserInfoMediaStream;  // @"OData.mediaStream"
// userInfo on either stream attribute: the String attribute its content
// type is kept in; without one, a stream is application/octet-stream. The
// media and content-type attributes are the stream's, not properties.
FOUNDATION_EXPORT NSString * const ODataUserInfoContentType;  // @"OData.contentType"

@interface ODataMetadataWriter : NSObject

- (instancetype)initWithModel:(NSManagedObjectModel *)model mapper:(ODataPropertyMapper *)mapper NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// A term by a standard vocabulary's own alias (Core.Description) with its
// namespace (Org.OData.Core.V1.Description); any other term as it is.
+ (NSString *)fullTerm:(NSString *)term;

@property (nonatomic, readonly) NSManagedObjectModel *model;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;
// The schema's namespace, for entities whose userInfo names no type of
// their own. Default: Default.
@property (nonatomic, copy) NSString *namespaceName;
@property (nonatomic, copy) NSString *containerName;  // Default: Container
// The entities it writes, by name: each a root entity, written with its
// sub-entities. nil, the default: every entity that has a key. A
// relationship to an entity it leaves out is left out with it.
@property (nonatomic, copy, nullable) NSSet<NSString *> *entityNames;
// The root entities, by name, whose types are open (OpenType): they, and
// the types derived from them, may have dynamic properties.
@property (nonatomic, copy, nullable) NSSet<NSString *> *openEntityNames;
// The attribute each entity's ETag is made of, when it has one
// (Core.OptimisticConcurrency). Set by the service.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSAttributeDescription *> *concurrencyAttributes;

// What each entity set does not allow, by set name: any of Insert, Update,
// Delete and Upsert, written as Org.OData.Capabilities.V1 restrictions
// (Upsertable in UpdateRestrictions unless Upsert is among them).
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSSet<NSString *> *> *restrictions;

// The scopes each entity set's methods need, by set name, by Read, Insert,
// Update and Delete; and each operation's, by overload (NS.Name, or for a
// bound one NS.Name(binding parameter type), as an annotation targets it):
// written as the set's restrictions' Permissions and the overload's
// OperationRestrictions, under the security scheme of this name.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary<NSString *, NSSet<NSString *> *> *> *permissions;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSSet<NSString *> *> *operationPermissions;
@property (nonatomic, copy, nullable) NSString *securitySchemeName;

// Annotations of each entity set, by set name, by term.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary<NSString *, id> *> *entitySetAnnotations;
// Annotations of the entity container, by term (Core.Description, or
// qualified), valued as JSON CSDL has them: the service's Authorization.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *containerAnnotations;
// The version of the schema (Core.SchemaVersion on the schema of
// namespaceName), which clients name in $schemaversion.
@property (nonatomic, copy, nullable) NSString *schemaVersion;
// More elements for the schema of namespaceName (Function, Action) and for
// the entity container (FunctionImport, ActionImport); copied in.
@property (nonatomic, copy, nullable) NSArray<ODataXMLElement *> *additionalSchemaElements;
@property (nonatomic, copy, nullable) NSArray<ODataXMLElement *> *additionalContainerElements;

// The document, in the CSDL of this OData-Version: 4.0 or 4.01.
- (NSString *)XMLStringForVersion:(NSString *)version;

// The qualified Edm type an attribute is written as; nil when it has none
// (a transformable value with no OData.type, a transient attribute).
- (nullable NSString *)typeNameForAttribute:(NSAttributeDescription *)attribute;
// An entity's qualified entity type name.
- (NSString *)typeNameForEntity:(NSEntityDescription *)entity;
// The entity's media resource, its own or a base's; nil for none.
- (nullable NSAttributeDescription *)mediaAttributeOfEntity:(NSEntityDescription *)entity;
- (BOOL)isStreamAttribute:(NSAttributeDescription *)attribute;
// Where a stream's content type is kept; nil for none.
- (nullable NSAttributeDescription *)contentTypeAttributeOfStream:(NSAttributeDescription *)stream;
// The entities the document has an entity type for: every entity with a key
// (or with a super-entity that has one).
@property (nonatomic, readonly) NSArray<NSEntityDescription *> *entities;
// What the document had to leave out, one sentence each.
@property (nonatomic, readonly) NSArray<NSString *> *problems;

@end

NS_ASSUME_NONNULL_END
