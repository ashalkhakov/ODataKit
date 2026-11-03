// Requests set up for the user (the navigator's Insert Request and Insert
// Call), as the builder's files keep them (ODWBuilderViewController): an
// entity set's query of its rows, of one by its key, of their $count; a
// new one created (a JSON body of its properties), one updated and one
// deleted; an operation import's call. Values are the types' samples (1,
// 'text', a date) for the user to change; a computed property is left out
// of a body, the key out of an update's. And what the builder makes of a
// file: a key's or a call's path in a URL, a body, the request as curl.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ODataSchema;

typedef NS_ENUM(NSInteger, ODWTemplate) {
  ODWTemplateGetAll,
  ODWTemplateGetByKey,
  ODWTemplateCount,
  ODWTemplatePost,
  ODWTemplatePatch,
  ODWTemplateDelete,
};

// The builder's file of the request (its "request", "query", "entitySet",
// "key", "body", "operation", "parameters"; ODWBuilderViewController); nil
// when the schema has no such entity set, or operation import.
FOUNDATION_EXPORT NSDictionary *_Nullable ODWTemplateOfEntitySet(ODataSchema *schema, NSString *entitySet, ODWTemplate kind);
FOUNDATION_EXPORT NSDictionary *_Nullable ODWTemplateOfOperation(ODataSchema *schema, NSString *operationImport);

// An entity set's entity, as the model built from $metadata names it (its
// type's simple name); the entity set of an entity of the model.
FOUNDATION_EXPORT NSString *_Nullable ODWEntityOfEntitySet(ODataSchema *schema, NSString *entitySet);
FOUNDATION_EXPORT NSString *_Nullable ODWEntitySetOfEntity(ODataSchema *schema, NSString *entity);
// Its key's properties, in their order; samples of them, as a key's values.
FOUNDATION_EXPORT NSArray<NSString *> *ODWKeyOfEntitySet(ODataSchema *schema, NSString *entitySet);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *ODWSampleKeyOfEntitySet(ODataSchema *schema, NSString *entitySet);
// A body of its properties' samples (its key's too, when asked).
FOUNDATION_EXPORT NSString *ODWSampleBodyOfEntitySet(ODataSchema *schema, NSString *entitySet, BOOL withKey);
// An operation import's parameters (a caller's), in their order; samples.
FOUNDATION_EXPORT NSArray<NSString *> *ODWParametersOfOperation(ODataSchema *schema, NSString *operationImport);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *ODWSampleParametersOfOperation(ODataSchema *schema, NSString *operationImport);
FOUNDATION_EXPORT BOOL ODWOperationIsAction(ODataSchema *schema, NSString *operationImport);

// Products(1), Lines(Order=1,Line=2): the key's values as typed (a string's
// quoted when it is not), nil when one is missing.
FOUNDATION_EXPORT NSString *_Nullable ODWKeyPath(ODataSchema *schema, NSString *entitySet, NSDictionary<NSString *, NSString *> *values);
// A function's call, Name(P=1,Q='a'), its values as typed (a string's
// quoted); an action's body, a JSON object of its values (each read as JSON,
// else a string).
FOUNDATION_EXPORT NSString *ODWFunctionPath(ODataSchema *schema, NSString *operationImport, NSDictionary<NSString *, NSString *> *values);
FOUNDATION_EXPORT NSString *ODWActionBody(ODataSchema *schema, NSString *operationImport, NSDictionary<NSString *, NSString *> *values);

// The request as a curl command, for a shell: its method, URL, headers and
// body, each quoted.
FOUNDATION_EXPORT NSString *ODWCurlOfRequest(NSURLRequest *request);

NS_ASSUME_NONNULL_END
