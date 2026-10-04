// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataPropertyMapper.h>
#import "ODataResourceIdentifier.h"
#import "ODataPredicateTranslator.h"
#import <ODataKit/ODataExpression.h>
#import <ODataKit/ODataApply.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataQueryBuilder : NSObject
@property (nonatomic, strong) ODataPropertyMapper *mapper;
// Handed to the predicate translator; see ODataPredicateTranslator.
@property (nonatomic, copy, nullable) ODataObjectKeysResolver keysForObjectID;
@property (nonatomic, copy) NSURL *serviceRoot;
// Address entities as Products/1 rather than Products(1); see
// -[ODataResourceIdentifier pathWithKeyAsSegment:].
@property (nonatomic) BOOL keyAsSegment;
// The OData version $filter is written in; see ODataPredicateTranslator.
@property (nonatomic, copy) NSString *version;

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper serviceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSURL *)URLForFetch:(NSFetchRequest *)fetch
                         entity:(NSEntityDescription *)entity
                          error:(NSError **)error;
// $apply for a fetch that groups and aggregates: its predicate as
// filter(), then groupby((paths),aggregate(...)), or aggregate(...) alone
// (Data Aggregation section 3), then the steps given (filter, orderby,
// skip, top). Paths are wire paths (Category/CategoryName).
- (nullable NSURL *)URLForAggregateFetch:(NSFetchRequest *)fetch
                                  entity:(NSEntityDescription *)entity
                              groupPaths:(NSArray<NSArray<NSString *> *> *)paths
                              aggregates:(NSArray *)aggregates
                                   after:(nullable NSArray<ODataApplyTransformation *> *)steps
                                   error:(NSError **)error;
// A grouping fetch's havingPredicate as a filter of the grouped rows:
// comparisons of what the rows hold (names: a grouped key path, or an
// aggregate's name, to its path in the rows, Category/CategoryName or
// Total) with numbers, strings, booleans and nil, and AND, OR and NOT of
// those; nil for anything else.
- (nullable ODataExpression *)groupedFilterExpressionForPredicate:(NSPredicate *)predicate names:(NSDictionary<NSString *, NSString *> *)names;
// The same, as $filter writes it.
- (nullable NSString *)groupedFilterForPredicate:(NSPredicate *)predicate names:(NSDictionary<NSString *, NSString *> *)names;
// Its sort descriptors as an orderby of the grouped rows: each a name's
// path, compared with compare:; nil for anything else.
- (nullable NSArray<ODataOrderItem *> *)groupedOrderItemsForSortDescriptors:(NSArray<NSSortDescriptor *> *)descriptors
                                                                      names:(NSDictionary<NSString *, NSString *> *)names;
// The same, as $orderby writes it.
- (nullable NSString *)groupedOrderForSortDescriptors:(NSArray<NSSortDescriptor *> *)descriptors names:(NSDictionary<NSString *, NSString *> *)names;
// The service root, a path from it, and query options by name, their
// values percent-encoded; nil, and why, when that is no URL.
- (nullable NSURL *)composePath:(NSString *)path query:(NSArray<NSArray<NSString *> *> *)items error:(NSError **)error;

// Every query the store sends is typed first (ODataKit's
// ODataQueryOptions: an ODataExpression filter, order items, expand items
// with options of their own, $apply's transformations) and written by
// this, the one place a URL's query is written. Its names are checked as
// they are built and as they are written (ODataExpression.h), and so are a
// resource path's this class writes (an entity set's, a cast's, a key's, a
// navigation property's): nil, and an ODataIncrementalStoreErrorInvalidName,
// for one OData does not allow there.
- (nullable NSURL *)URLForPath:(NSString *)path options:(nullable ODataQueryOptions *)options error:(NSError **)error;
// A fetch request's query, typed: what -URLForFetch:entity:error: sends
// (for a count, the options /$count takes).
- (nullable ODataMutableQueryOptions *)optionsForFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity error:(NSError **)error;
// A grouping fetch's: $apply, with the steps after the grouping.
- (nullable ODataMutableQueryOptions *)optionsForAggregateFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity
                                                      groupPaths:(NSArray<NSArray<NSString *> *> *)paths
                                                      aggregates:(NSArray<ODataAggregate *> *)aggregates
                                                           after:(nullable NSArray<ODataApplyTransformation *> *)after
                                                           error:(NSError **)error;
// An object's, or a relationship's members': its properties, and its
// to-one relationships' keys; nil, and an ODataIncrementalStoreError-
// InvalidName, for a model's name that cannot be written.
- (nullable ODataMutableQueryOptions *)readingOptionsForEntity:(NSEntityDescription *)entity error:(NSError **)error;
- (nullable NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier error:(NSError **)error;
// For reading one entity: the entity URL with its to-one keys expanded.
- (nullable NSURL *)URLForReadingIdentifier:(ODataResourceIdentifier *)identifier
                                     entity:(NSEntityDescription *)entity
                                      error:(NSError **)error;
// Entity(key)/Nav/$ref?$id=<target>: removes one entity from a collection-
// valued navigation property (Part 1 section 11.4.6.2).
- (nullable NSURL *)URLForReferenceFromEntityURL:(NSURL *)entity
                                    relationship:(NSRelationshipDescription *)relationship
                                          target:(NSURL *)target;
- (nullable NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier
                        relationship:(NSRelationshipDescription *)relationship
                               error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
