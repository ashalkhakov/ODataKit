// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <ODataKit/OISRuntime.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataResourceIdentifier : NSObject
@property (nonatomic, copy) NSString *entitySet;
@property (nonatomic, copy) NSDictionary<NSString *, id> *keys;
// Keys whose value is already an OData literal and goes into the path
// unquoted: a Guid, a date. Every other string key is quoted.
@property (nonatomic, copy) NSSet<NSString *> *unquotedKeys;

- (instancetype)initWithEntitySet:(NSString *)entitySet keys:(NSDictionary<NSString *, id> *)keys NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The canonical path: Products(1), OrderItems(OrderID=1,ItemNo=2).
- (NSString *)path;
// With keyAsSegment, a single-part key as a segment of its own, its value
// written bare (Part 2 section 4.3.6): Products/1, People/russellwhyte.
// A compound key keeps the canonical form.
- (NSString *)pathWithKeyAsSegment:(BOOL)keyAsSegment;
- (NSDictionary *)dictionary;
/* Opaque reference stored inside NSManagedObjectID. FreeCoreData uniques
   on this value and types it NSData; Apple accepts any NSCopying id. */
- (NSData *)data;
+ (nullable instancetype)identifierFromReference:(id)ref;
@end

/* ODataIncrementalStore's own: exported where ODataIncrementalStore is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef ODATAINCREMENTALSTORE_EXPORT
#define ODATAINCREMENTALSTORE_EXPORT FOUNDATION_EXPORT
#endif

ODATAINCREMENTALSTORE_EXPORT NSString *OISKeyLiteral(id value);

NS_ASSUME_NONNULL_END
