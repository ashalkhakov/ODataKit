// Requests written for the user (the navigator's Insert Request and Insert
// Call), in the REST Client format ODWRequests reads: an entity set's
// GET of its rows, of one by its key, its $count, a POST of a new one (a
// JSON body of its properties), a PATCH and a DELETE of one; an operation
// import's call (a function's GET, its parameters in the URL; an action's
// POST, its parameters the body). Values are the types' samples (1, 'text',
// a date) for the user to change; a computed property is left out of a
// body, the key out of a PATCH's.
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

// The request, its separator line first (### and what it does), ending in
// a newline; nil when the schema has no such entity set.
FOUNDATION_EXPORT NSString *_Nullable ODWTemplateOfEntitySet(ODataSchema *schema, NSString *entitySet, ODWTemplate kind);
// The operation import's call, as above; nil when there is none.
FOUNDATION_EXPORT NSString *_Nullable ODWTemplateOfOperation(ODataSchema *schema, NSString *operationImport);

// The text with the request put in at a caret: after the request the caret
// is inside, before the one it is at the start of, else at the start of
// its line; a blank line before it, the requests after it kept apart by a
// separator. The range is where the request is in the new text (from its
// request line), for the caret.
FOUNDATION_EXPORT NSString *ODWTextWithTemplate(NSString *text, NSUInteger caret, NSString *request,
                                                NSRange *_Nullable requestRange);

NS_ASSUME_NONNULL_END
