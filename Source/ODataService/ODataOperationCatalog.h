// ODataIncrementalStore — a service's operations, read from protocols.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Private to ODataService. Finds the protocols that inherit ODataFunctions
// or ODataActions among those the model's managed object classes and the
// service's serviceOperations object adopt, and describes each method in
// them as an OData operation: its name from the selector, its parameters'
// and return types from the protocol's extended type encodings, and what
// the class's +ODataOperationTypes and +ODataOperationNames say. See
// ODataService.h for the rules.

#pragma once
#import "OISCoreData.h"
#import <ODataKit/ODataXML.h>
#import "ODataPropertyMapper.h"

NS_ASSUME_NONNULL_BEGIN

@class ODataMetadataWriter;

@interface OISServedParameter : NSObject
@property (nonatomic, copy) NSString *name;       // on the wire
@property (nonatomic, copy) NSString *type;       // qualified; Collection(...) for a collection
@property (nonatomic) char scalar;                // the C type's encoding; 0 for an object
@property (nonatomic, strong, nullable) NSEntityDescription *entity;  // an entity type's
@end

@interface OISServedOperation : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic) BOOL isAction;
@property (nonatomic) SEL selector;
@property (nonatomic) BOOL isClassMethod;
// Bound to this entity, or to its collection; nil: unbound, an import.
@property (nonatomic, strong, nullable) NSEntityDescription *boundEntity;
@property (nonatomic) BOOL boundToCollection;
@property (nonatomic, copy) NSArray<OISServedParameter *> *parameters;  // the caller's, in order
@property (nonatomic, strong, nullable) OISServedParameter *returns;     // nil: nothing
@property (nonatomic, copy, nullable) NSSet<NSString *> *scopes;        // any one needed; nil: none
@property (nonatomic, readonly) NSString *signature;  // for messages: -[Product selector:]
@end

@interface OISOperationCatalog : NSObject

- (instancetype)initWithModel:(NSManagedObjectModel *)model
                       mapper:(ODataPropertyMapper *)mapper
                       writer:(ODataMetadataWriter *)writer
            serviceOperations:(nullable id)serviceOperations;

@property (nonatomic, readonly) NSArray<OISServedOperation *> *operations;
@property (nonatomic, readonly) NSArray<NSString *> *problems;

// An operation bound to this entity (or a super-entity) or its collection,
// by qualified or simple name.
- (nullable OISServedOperation *)operationNamed:(NSString *)name boundTo:(NSEntityDescription *)entity collection:(BOOL)collection;
// An unbound operation, by its import's name.
- (nullable OISServedOperation *)importNamed:(NSString *)name;

// CSDL: the operations for the schema, the imports for the container.
@property (nonatomic, readonly) NSArray<ODataXMLElement *> *schemaElements;
@property (nonatomic, readonly) NSArray<ODataXMLElement *> *containerElements;

@end

NS_ASSUME_NONNULL_END
