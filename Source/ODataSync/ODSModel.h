// What the model says about syncing: the one place ODataSync reads it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Each entity's userInfo (ODataSyncEngine.h): ODataSync.direction,
// ODataSync.conflicts, ODataSync.modified, ODataSync.versions; and the
// mapper's (OData.key, OData.entitySet, OData.served, OData.etag), through
// one ODataPropertyMapper.

#pragma once
#import <ODataSync/ODataSyncEngine.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

// The String attribute last writer wins orders by (ODataSync.modified), for
// what has no ODSModel (a resolver has an entity, no engine).
FOUNDATION_EXPORT NSAttributeDescription *_Nullable ODSModifiedAttributeOf(NSEntityDescription *entity);

@interface ODSModel : NSObject
- (instancetype)initWithModel:(NSManagedObjectModel *)model NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSManagedObjectModel *model;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;

- (NSEntityDescription *)rootOf:(NSEntityDescription *)entity;
- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity;
// The way it goes with this remote: with a peer, up is both.
- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity toward:(nullable ODataSyncRemote *)remote;
// Root entities going these ways (with the remote), parents before
// children (an entity before those whose to-ones point to it).
- (NSArray<NSEntityDescription *> *)rootEntitiesGoing:(NSSet<NSNumber *> *)directions toward:(nullable ODataSyncRemote *)remote;
// Every entity that syncs (sub-entities too): what a peer server serves.
- (NSArray<NSEntityDescription *> *)syncedEntities;
// The names requests are written of, each an OData identifier: the synced
// entities' sets, their synced properties and to-ones, their keys. NO,
// and an ODataIncrementalStoreErrorInvalidName, for one that is not (a
// model's OData.entitySet or OData.property): nothing is sent then.
- (BOOL)checkNames:(NSError **)error;

// The synced attributes (served, not computed, no dynamic bag) and to-one
// relationships to synced entities; the key's attributes (the root's).
- (NSArray<NSAttributeDescription *> *)attributesOf:(NSEntityDescription *)entity;
// Merged attributes (ODataSync.merge: a merger's name; docs/offline-sync.md,
// 14): Binary, served, not among attributesOf:, exchanged as deltas after a
// row's own.
- (NSArray<NSAttributeDescription *> *)mergedAttributesOf:(NSEntityDescription *)entity;
- (nullable NSString *)mergerNameOf:(NSAttributeDescription *)attribute;
// Whether the entity, or one derived from it, has a merged attribute.
- (BOOL)mergesEntity:(NSEntityDescription *)entity;
- (NSArray<NSRelationshipDescription *> *)toOnesOf:(NSEntityDescription *)entity;
- (NSArray<NSAttributeDescription *> *)keyAttributesOf:(NSEntityDescription *)entity;

// The conflict rule the model names (ODataSync.conflicts: remote, local,
// lastwriter, merge), lower case; nil for none.
- (nullable NSString *)conflictRuleOf:(NSEntityDescription *)entity;
// The String attribute last writer wins orders by (ODataSync.modified).
- (nullable NSAttributeDescription *)modifiedAttributeOf:(NSEntityDescription *)entity;
// The attribute that keeps an object's version vector (ODataSync.versions).
- (nullable NSAttributeDescription *)versionsAttributeOf:(NSEntityDescription *)entity;
// The service's version counter (an integer attribute that OData.etag
// names, which the service increments on each update): which of two
// copies is newer.
- (nullable NSAttributeDescription *)versionAttributeOf:(NSEntityDescription *)entity;
@end

NS_ASSUME_NONNULL_END
