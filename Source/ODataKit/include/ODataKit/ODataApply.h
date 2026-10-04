// ODataKit — $apply: grouping and aggregating (OData Data Aggregation 4.0).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// $apply is a sequence of transformations, each on the result of the one
// before (Data Aggregation section 3):
//
//   filter(UnitPrice gt 10)/groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total,$count as Products))
//
// These are read and written: filter, groupby (of property paths, with an
// aggregate), and aggregate, of property paths with sum, min, max,
// average or countdistinct, and of $count; identity, search, compute,
// orderby, top, skip, topcount, topsum, toppercent and their bottom kin,
// concat, and expand (of a navigation property, with a filter). The
// others (nest, the hierarchy transformations, rollup, custom methods) are
// ODataIncrementalStoreErrorUnsupportedExpression; what is not $apply at
// all is ODataIncrementalStoreErrorSyntax.

#pragma once
#import "OISRuntime.h"
#import "ODataExpression.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ODataApplyKind) {
  ODataApplyFilter,     // filter
  ODataApplyGroupBy,    // groupPaths; aggregates (may be empty), or sequence
  ODataApplyAggregate,  // aggregates
  ODataApplyIdentity,   // identity: the input as it is
  ODataApplySearch,     // search
  ODataApplyCompute,    // compute
  ODataApplyOrderBy,    // orderBy
  ODataApplyTop,        // number
  ODataApplySkip,       // number
  ODataApplyTopBottom,  // method (topcount, bottomsum, ...), number, expression
  ODataApplyConcat,     // branches
  ODataApplyExpand,     // expansion: as $expand writes it, Category($filter=...)
  ODataApplyJoin,       // join or outerjoin (method): path as alias, sequence (may be nil)
  ODataApplyHierarchy   // ancestors, descendants or traverse (method): hierarchy, qualifier, nodePath, and the rest
};

// An aggregate expression (Data Aggregation section 3.1.3), each as alias:
//   path with method        path, method (sum, min, max, average, countdistinct)
//   expression with method  expression, method: Price mul Quantity with sum
//   $count                  path nil, method nil
//   path/$count             path (to the collection), method $count: Sales/$count
//   custom aggregate        custom, the name a CustomAggregate annotation
//                           gives it (Forecast, or Forecast as F)
// A method with a dot in its name is a custom aggregation method
// (Custom.concat).
// A path may go through collection-valued navigation properties
// (Sales/Amount): the values of all of them.
//
// Built, its names are checked, as ODataExpression.h's builders check
// theirs: nil and an ODataIncrementalStoreErrorInvalidName for an alias
// or a custom aggregate's name that is no OData identifier, a path that
// is empty or not identifiers and qualified names, a method that is not
// sum, min, max, average, countdistinct or a qualified name ($count
// with a path, or none without), or no expression (nil: what built it
// failed, and has said why).
@interface ODataAggregate : NSObject
+ (nullable instancetype)aggregateOfPath:(nullable NSArray<NSString *> *)path method:(nullable NSString *)method alias:(NSString *)alias
                                   error:(NSError **)error;
+ (nullable instancetype)aggregateOfExpression:(ODataExpression *)expression method:(NSString *)method alias:(NSString *)alias
                                         error:(NSError **)error;
+ (nullable instancetype)aggregateOfCustom:(NSString *)name alias:(NSString *)alias error:(NSError **)error;
@property (nonatomic, readonly, copy, nullable) NSString *custom;
// A custom aggregate, or a custom aggregation method.
@property (nonatomic, readonly) BOOL isCustom;
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *path;
@property (nonatomic, readonly, strong, nullable) ODataExpression *expression;
@property (nonatomic, readonly, copy, nullable) NSString *method;
@property (nonatomic, readonly, copy) NSString *alias;
// $count, of the input or of a collection at path.
@property (nonatomic, readonly) BOOL isCount;
@end

@interface ODataApplyTransformation : NSObject
+ (nullable NSArray<ODataApplyTransformation *> *)transformationsWithString:(NSString *)text error:(NSError **)error;
// The transformations as $apply writes them.
+ (NSString *)stringForTransformations:(NSArray<ODataApplyTransformation *> *)transformations;

// Built: nil for a nil expression (what built it failed, and has said why).
+ (nullable instancetype)filterWithExpression:(ODataExpression *)expression;
// Each path's names checked (identifiers and qualified names): nil and an
// ODataIncrementalStoreErrorInvalidName for one that is not.
+ (nullable instancetype)groupByPaths:(NSArray<NSArray<NSString *> *> *)paths aggregates:(NSArray<ODataAggregate *> *)aggregates
                                error:(NSError **)error;
+ (nullable instancetype)groupByPaths:(NSArray<NSArray<NSString *> *> *)paths sequence:(NSArray<ODataApplyTransformation *> *)sequence
                                error:(NSError **)error;
+ (instancetype)aggregateWith:(NSArray<ODataAggregate *> *)aggregates;
+ (instancetype)orderByItems:(NSArray<ODataOrderItem *> *)items;
+ (instancetype)computeItems:(NSArray<ODataComputeItem *> *)items;
+ (nullable instancetype)searchWith:(ODataSearchExpression *)search;
+ (instancetype)top:(NSUInteger)count;
+ (instancetype)skip:(NSUInteger)count;
// ancestors or descendants (method) of the nodes of $root/hierarchy, by
// the qualifier, each input's node at nodePath; sequence picks the start.
// nil and an ODataIncrementalStoreErrorInvalidName for another method, a
// qualifier that is no OData identifier, or a path (the hierarchy's, the
// node's) that is empty or not identifiers and qualified names.
+ (nullable instancetype)hierarchical:(NSString *)method hierarchy:(NSArray<NSString *> *)hierarchy qualifier:(NSString *)qualifier
                             nodePath:(NSArray<NSString *> *)nodePath sequence:(NSArray<ODataApplyTransformation *> *)sequence
                          maxDistance:(NSUInteger)maxDistance keepStart:(BOOL)keepStart error:(NSError **)error;
+ (nullable instancetype)traverseHierarchy:(NSArray<NSString *> *)hierarchy qualifier:(NSString *)qualifier
                                  nodePath:(NSArray<NSString *> *)nodePath postorder:(BOOL)postorder
                                   orderBy:(nullable NSArray<ODataOrderItem *> *)orderBy error:(NSError **)error;

@property (nonatomic, readonly) ODataApplyKind kind;
@property (nonatomic, readonly, strong, nullable) ODataExpression *filter;
@property (nonatomic, readonly, copy) NSArray<NSArray<NSString *> *> *groupPaths;
@property (nonatomic, readonly, copy) NSArray<ODataAggregate *> *aggregates;
// join's and outerjoin's (section 3.5.1): the collection-valued path, and
// the alias its members are under; sequence the transformations applied to
// each instance's collection.
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *joinPath;
@property (nonatomic, readonly, copy, nullable) NSString *alias;
@property (nonatomic, readonly) BOOL outer;
// groupby's transformations when they are more than one aggregate
// (groupby((Category),filter(...)/aggregate(...))): applied to each group.
@property (nonatomic, readonly, copy, nullable) NSArray<ODataApplyTransformation *> *sequence;
@property (nonatomic, readonly, strong, nullable) ODataSearchExpression *search;
@property (nonatomic, readonly, copy, nullable) NSArray<ODataComputeItem *> *compute;
@property (nonatomic, readonly, copy, nullable) NSArray<ODataOrderItem *> *orderBy;
@property (nonatomic, readonly, copy, nullable) NSString *method;
@property (nonatomic, readonly, strong, nullable) NSNumber *number;
// topcount's (and its kin's) number when it is an expression of the
// input, not a literal: topcount($these/$count div 3,Amount).
@property (nonatomic, readonly, strong, nullable) ODataExpression *numberExpression;
@property (nonatomic, readonly, strong, nullable) ODataExpression *expression;
@property (nonatomic, readonly, copy, nullable) NSArray<NSArray<ODataApplyTransformation *> *> *branches;
@property (nonatomic, readonly, copy, nullable) NSString *expansion;
// The hierarchical transformations (section 6), each over a recursive
// hierarchy: its nodes, $root/SalesOrganizations (hierarchy, the path after
// $root), the qualifier of its RecursiveHierarchy annotation, and the path
// p from each input instance to its node's identifier (nodePath).
//   ancestors(H,Q,p,T[,d][,keep start]) and descendants(...): sequence the
//     T that picks the start instances (a bare condition is a filter),
//     number the maximum distance d, keepStart.
//   traverse(H,Q,p,preorder|postorder[,o]): traversal, and orderBy the o
//     the roots (and here each node's children) are sorted by.
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *hierarchy;
@property (nonatomic, readonly, copy, nullable) NSString *qualifier;
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *nodePath;
@property (nonatomic, readonly) BOOL keepStart;
@property (nonatomic, readonly, copy, nullable) NSString *traversal;
@end

@interface ODataAggregation : NSObject
// The methods it computes: sum, min, max, average, countdistinct.
+ (NSSet<NSString *> *)methods;
// Objects (anything answering key paths) grouped by the values at
// keyPaths, first seen first, and aggregated: one dictionary per group,
// each key path to its value (NSNull for none), each aggregate's alias to
// its value. An aggregate's path is a key path's components. sum, min,
// max and average leave out nulls and are NSNull over none; sum and
// average of integers and decimals are NSDecimalNumbers; $count and
// countdistinct are NSNumbers. No key paths: one dictionary, even for no
// objects. A key path through a to-many relationship reaches all its
// members' values (a collection's values are each a value); a $count of a
// path counts them.
+ (NSArray<NSDictionary *> *)groupObjects:(NSArray *)objects
                               byKeyPaths:(NSArray<NSString *> *)keyPaths
                               aggregates:(NSArray<ODataAggregate *> *)aggregates;
// The same, custom aggregates and custom methods valued by custom, given
// the aggregate and the group's objects (nil for null).
+ (NSArray<NSDictionary *> *)groupObjects:(NSArray *)objects
                               byKeyPaths:(NSArray<NSString *> *)keyPaths
                               aggregates:(NSArray<ODataAggregate *> *)aggregates
                                   custom:(nullable id _Nullable (^)(ODataAggregate *aggregate, NSArray *objects))custom;
// A key path's values in objects: a collection's each, nulls left out.
+ (NSArray *)valuesAtKeyPath:(NSString *)keyPath inObjects:(NSArray *)objects;
// An expression over the members of rows (dictionaries, nested for a
// path: Category/CategoryName is Category.CategoryName) as a predicate:
// comparisons with literals, and, or, not. nil with
// ODataIncrementalStoreErrorUnsupportedExpression for anything more.
+ (nullable NSPredicate *)predicateForExpression:(ODataExpression *)expression error:(NSError **)error;
// An expression's value with a grouped row (nested dictionaries): a
// literal, a path in the row, and add, sub, mul, div and minus of those.
// nil, with the reason, for anything else.
//
// isdefined(path), in a predicate over grouped rows: whether the row has
// that property at all (null or not), which it does not once it has been
// aggregated away.
+ (nullable id)valueOfExpression:(ODataExpression *)expression inRow:(id)row error:(NSError **)error;
// topcount, topsum, toppercent, bottomcount, bottomsum, bottompercent
// (section 3.2): the rows with the largest (smallest) values, as many as
// the count, or as make up the sum or the percent of the whole sum;
// values given in the order of the rows.
+ (NSArray *)rows:(NSArray *)rows values:(NSArray *)values method:(NSString *)method number:(double)number;
@end

NS_ASSUME_NONNULL_END
