// The Workbench's query: everything a fetch request can ask of the store,
// as the query panel says it, and the fetch request it makes. No views:
// the window controller copies the panel's values in and out.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "WBConnection.h"

NS_ASSUME_NONNULL_BEGIN

@interface WBQuery : NSObject

// Canned queries for a service: label, entity, predicate, sort, asc,
// expand, type, limit, and the fields the panel has (search, compute,
// group, aggregate, time). For another service, its first few entity sets.
+ (NSArray<NSDictionary *> *)presetsForService:(WBService)service model:(NSManagedObjectModel *)model;

// Over a model; builtIn: the built-in service's Catalog, whose columns are
// chosen by hand.
- (instancetype)initWithModel:(NSManagedObjectModel *)model builtIn:(BOOL)builtIn NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly) NSManagedObjectModel *model;
@property (nonatomic, readonly) BOOL builtIn;
// The store's configuration of the model, whose entities are queried (nil:
// all of them).
@property (nonatomic, copy, nullable) NSString *configurationName;

@property (nonatomic, copy, nullable) NSString *entityName;
@property (nonatomic) NSFetchRequestResultType resultType;
@property (nonatomic, copy) NSString *predicateText;
@property (nonatomic, copy) NSString *limitText;      // $top
@property (nonatomic, copy) NSString *skipText;       // $skip
@property (nonatomic, copy) NSString *pageSizeText;   // the service's page size (fetchBatchSize)
@property (nonatomic) BOOL includesSubentities;
@property (nonatomic) BOOL returnsObjectsAsFaults;
@property (nonatomic, copy) NSString *searchText;     // $search
@property (nonatomic, copy) NSString *computeText;    // unitPrice * 2 as twice, ...
@property (nonatomic, copy) NSString *groupText;      // category.name, ...
@property (nonatomic, copy) NSString *aggregateText;  // sum:(unitPrice) as total, ...
@property (nonatomic, copy) NSString *timeText;       // a day, or from..to
// Sort keys, first first: each a dictionary of key (a key path) and
// descending (an NSNumber).
@property (nonatomic, readonly) NSMutableArray<NSMutableDictionary *> *sorts;
// Key paths to prefetch ($expand), and properties to fetch ($select).
@property (nonatomic, readonly) NSMutableSet<NSString *> *prefetch;
@property (nonatomic, readonly) NSMutableSet<NSString *> *select;

// All of it, as a property list a file keeps (UDCode's OData builder's):
// entity, type (objects, object IDs, dictionary, count), predicate, sort
// ([{key, descending}]), expand and select (key paths and names), limit,
// skip, pageSize, subentities, faults, search, compute, group, aggregate,
// time; only what differs from a new query. And taken back: what the
// dictionary leaves out, a new query's.
- (NSDictionary *)dictionary;
- (void)takeDictionary:(NSDictionary *)dictionary;
- (NSArray<NSString *> *)entityNames;
// The entity asked for, or the model's first.
- (nullable NSEntityDescription *)entity;
- (NSArray<NSString *> *)attributeNames;
// What the results have: the entity's columns, its prefetched
// relationships for objects, or a dictionary result's keys.
- (NSArray<NSString *> *)columnNames;
- (NSArray<NSString *> *)columnNamesFor:(NSEntityDescription *)entity;
// Whether the entity has application time (a period).
- (BOOL)hasApplicationTime;
// Through to-one relationships to an attribute: what can be sorted and
// grouped by.
- (BOOL)keyPathLeadsToAnAttribute:(NSString *)keyPath;
- (NSArray<NSString *> *)groupPaths;
- (NSArray<NSString *> *)aggregateTexts;
- (nullable NSArray<NSExpressionDescription *> *)aggregateDescriptionsError:(NSError **)error;
- (nullable NSArray<NSExpressionDescription *> *)computedDescriptionsError:(NSError **)error;

// A predicate that begins with $ is OData query options, sent as they are
// written ($apply=traverse(...)&$expand=Superordinate), by an ODataQuery of
// the entity: objects, or dictionaries for that result type. The panel's
// other fields are not used.
- (BOOL)isVerbatim;
- (nullable ODataQuery *)verbatimQueryInContext:(NSManagedObjectContext *)context error:(NSError **)error;

// The fetch request the query makes; nil, and why, for one it cannot.
- (nullable NSFetchRequest *)fetchRequestError:(NSError **)error;

// A new entity's query: sorted by its first column, nothing prefetched,
// nothing selected, the fields empty.
- (void)reset;
// A canned query, whole.
- (void)applyPreset:(NSDictionary *)preset;

// The sort keys: one more (a column not yet used); one fewer (this row,
// else the last); one moved (the row it lands on, or -1 when it cannot).
- (void)addSort;
- (void)removeSortAtRow:(NSInteger)row;
- (NSInteger)moveSortAtRow:(NSInteger)row by:(NSInteger)step;
// A relationship prefetched or not; not takes its nested ones with it.
- (void)setPrefetch:(NSString *)path included:(BOOL)included;

@end

NS_ASSUME_NONNULL_END
