// Permissions on objects, as Google's Zanzibar models them (Pang et al.,
// "Zanzibar: Google's Consistent, Global Authorization System", USENIX ATC
// 2019), in the notation of OpenFGA, its open implementation: nothing here
// is ODataKit's own idea. docs/permissions.md.
//
//   Zanzibar                      here
//   object type                   an entity
//   relation tuple                a row of an entity annotated OData.tuple.*:
//     object#relation@user          object, relation and user are its values
//   relation definition           an entity's OData.relation.<name>, in
//     define keeper: [user]         OpenFGA's notation: [user], a relation of
//       or manager                  the same object, <relation> from <to-one>,
//                                   joined by or
//   tuple to userset              <relation> from <to-one>: through the
//     keeper from warehouse         entity's own relationship (Core Data's),
//                                   not a tupleset relation
//   Check(object, relation, user) the relation's predicate, evaluated on the
//                                 row
//   ListObjects                   the relation's predicate, fetched with
//
// And one term from SAP CAP's @restrict, for what holds by the row's own
// values (its owner): where <predicate>, $user the caller's identities.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <CoreData/CoreData.h>
#import <HTTPServerKit/HSAuthentication.h>

NS_ASSUME_NONNULL_BEGIN

// The annotations (userInfo keys).
FOUNDATION_EXPORT NSString * const OISRelationKeyPrefix;       // @"OData.relation."
FOUNDATION_EXPORT NSString * const OISTupleObjectKey;          // @"OData.tuple.object": its to-one to the object
FOUNDATION_EXPORT NSString * const OISTupleRelationKey;        // @"OData.tuple.relation": the attribute naming the relation
FOUNDATION_EXPORT NSString * const OISTupleRelationNameKey;    // @"OData.tuple.relationName": or the one relation all its rows are
FOUNDATION_EXPORT NSString * const OISTupleUserKey;            // @"OData.tuple.user": the key path to the user (or group) it is for

// Who a principal is, as a tuple's user may name them: its subject, its
// email and preferred_username claims, and each of its groups.
FOUNDATION_EXPORT NSArray<NSString *> *OISIdentitiesOfPrincipal(HSPrincipal *_Nullable principal);

@interface OISAuthorization : NSObject
- (instancetype)initWithModel:(NSManagedObjectModel *)model NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// What the annotations could not say, one sentence each.
@property (nonatomic, readonly, copy) NSArray<NSString *> *problems;
// Whether the entity (or a super-entity) defines the relation.
- (BOOL)entity:(NSEntityDescription *)entity defines:(NSString *)relation;
// The rows of the entity on which these identities hold the relation;
// nil when the entity defines no such relation (no limit).
- (nullable NSPredicate *)predicateForRelation:(NSString *)relation
                                        entity:(NSEntityDescription *)entity
                                    identities:(NSArray<NSString *> *)identities;
// The to-ones the relation goes through (its from terms, its computed
// relations' too): a new row's, made in the same request, decides there.
- (NSSet<NSString *> *)relationshipsOfRelation:(NSString *)relation entity:(NSEntityDescription *)entity;
// What these identities hold, as a version: changes when a tuple of theirs
// is added, removed or changed (a delta link's scope version).
- (nullable NSString *)versionOfIdentities:(NSArray<NSString *> *)identities context:(NSManagedObjectContext *)context;
@property (nonatomic, readonly) BOOL hasTuples;
@end

// A row, or a row to be: its values, and the object's for the rest (an
// update's values over the object; an insert's, over nothing).
@interface OISRowToBe : NSObject
- (instancetype)initWithValues:(NSDictionary<NSString *, id> *)values object:(nullable NSManagedObject *)object NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
