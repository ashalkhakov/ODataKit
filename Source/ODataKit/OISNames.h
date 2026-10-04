// Names the builders write as they are given, checked against what OData's
// grammar allows in their place (ODataExpression.h): ODataKit's own, not
// installed.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// An OData identifier (Part 2 section 4.3): a letter or _, then letters,
// digits and _, 128 at most.
FOUNDATION_EXPORT BOOL OISIsODataIdentifier(NSString *_Nullable name);
// Identifiers joined by dots, two or more: NS.Type, Edm.String.
FOUNDATION_EXPORT BOOL OISIsQualifiedName(NSString *_Nullable name);
// A segment of a path: a property, or a cast or bound operation (a
// qualified name).
FOUNDATION_EXPORT BOOL OISIsPathSegment(NSString *_Nullable name);

// allowed, or NO and *error an ODataIncrementalStoreErrorInvalidName:
// "name" is not what (a member name, an OData identifier).
FOUNDATION_EXPORT BOOL OISCheckName(BOOL allowed, NSString *what, id _Nullable name, NSError **error);
// Each of path's names a path segment (and one at least); with star, the
// last may be * (alone, or after a cast: NS.Type/*), and with namespaceStar
// NS.* (every operation of a namespace): $select's.
FOUNDATION_EXPORT BOOL OISCheckPath(NSArray *_Nullable path, NSString *what, BOOL star, BOOL namespaceStar, NSError **error);

NS_ASSUME_NONNULL_END
