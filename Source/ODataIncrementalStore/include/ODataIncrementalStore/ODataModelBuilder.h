// ODataIncrementalStore — a Core Data model from a service's $metadata.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Two ways to use a service's schema as a model:
//
// - At runtime, for a client that knows nothing of the service in
//   advance: +modelWithSchema: (or +[ODataIncrementalStore
//   modelForServiceAtURL:options:error:]) builds the model in memory.
// - Ahead of time, for a client built on a particular service:
//   +writeModel:toPackage:... writes it as an .xcdatamodeld, which Xcode
//   edits and momc compiles like any other (Tools/ois-model does this),
//   with classes for its entities if asked (see ODataClassWriter.h).
//
// A service whose schema changes is a new version of the model, as in
// Core Data: writing to a package that already holds the model adds a
// version ("Model 2") and makes it current, keeping the old ones, when
// the schema differs; and a store opened with a generated model refuses a
// service whose schema is no longer the model's (see ODataIncrementalStore).
//
// The mapping: an entity type is an entity of the same name, a base type
// its super-entity; properties and navigation properties are attributes
// and relationships named in lower camel case (UserName is userName, ID is
// id), partners are inverses. Everything the store needs is written into
// userInfo (OData.type, OData.entitySet, OData.property, OData.key), so a
// generated model works without the schema. Edm types map as the store
// reads them: Date, TimeOfDay, Duration, Guid and enumerations are marked
// with their Edm type, Guid and enumerations held as strings. Complex
// values and collections are Transformable attributes marked with their
// type (NS.Address, Collection(Edm.String)): an NSDictionary and an
// NSArray, see ODataValue.h. An open type's dynamic properties are held
// in a Transformable attribute of its own, dynamicProperties, an
// NSDictionary marked OData.dynamicProperties (see ODataPropertyMapper.h):
// the property bag Core Data's own models keep what they do not declare
// in. Stream and spatial properties have no attribute; they are listed in
// the entity's userInfo under OData.unmapped.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataSchema.h>

NS_ASSUME_NONNULL_BEGIN

/* ODataIncrementalStore's own: exported where ODataIncrementalStore is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef ODATAINCREMENTALSTORE_EXPORT
#define ODATAINCREMENTALSTORE_EXPORT FOUNDATION_EXPORT
#endif

ODATAINCREMENTALSTORE_EXPORT NSString * const ODataUserInfoUnmapped;       // @"OData.unmapped"
ODATAINCREMENTALSTORE_EXPORT NSString * const ODataModelVersionPrefix;     // @"odata:"

@interface ODataModelBuilder : NSObject

// The model a schema describes, with the schema's fingerprint as its one
// version identifier.
+ (NSManagedObjectModel *)modelWithSchema:(ODataSchema *)schema;

// odata:<16 hex digits>: a hash of everything in the schema the model is
// made from (entity types, properties, keys, navigation, enumerations,
// entity sets), so it changes when, and only when, the model would.
+ (NSString *)versionIdentifierForSchema:(ODataSchema *)schema;

// The model's odata: version identifier, or nil for a model not built
// from a schema.
+ (nullable NSString *)versionIdentifierOfModel:(NSManagedObjectModel *)model;

// The xcdatamodel "contents" document for a model.
+ (NSData *)modelDocumentForModel:(NSManagedObjectModel *)model;

// Writes the model into an .xcdatamodeld package, creating it if need be.
// When the package's current version already has this model's version
// identifier, nothing is written and *changed is NO. Otherwise the model
// becomes a new version, named for the package ("Zoo", "Zoo 2", ...), and
// the current one. Returns the current version's name.
+ (nullable NSString *)writeModel:(NSManagedObjectModel *)model
                        toPackage:(NSString *)path
                          changed:(nullable BOOL *)changed
                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
