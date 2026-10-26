// Permissions on objects, as Google's Zanzibar models them (Pang et al.,
// "Zanzibar: Google's Consistent, Global Authorization System", USENIX ATC
// 2019), with OpenFGA's terms, its open implementation: nothing here is
// ODataKit's own idea. docs/permissions.md.
//
//   Zanzibar                      here (a permissions file, ODataPermissions)
//   object type                   an entity (Entities)
//   relation tuple                a row of an entity listed in Tuples: its
//     object#relation@user          object, relation and user are its values
//   relation definition           a list of terms, joined by or:
//     define keeper: [user]         { direct = YES; } (a tuple's)
//       or manager                  { relation = manager; } (the same object's)
//   tuple to userset              { relation = keeper; from = warehouse; }:
//     keeper from warehouse         through the entity's own relationship
//                                   (Core Data's), a to-many's any member
//   intersection                  { all = ( …, … ); }: every one of them
//     a and b
//   Check(object, relation, user) the relation's predicate, on the row
//   ListObjects                   the relation's predicate, fetched with
//
// And, borrowed: SAP CAP's @restrict where ({ where = "…"; }, $user the
// caller's identities), and claims ({ claim = roles; value = admin; }),
// with relations held on the service as a whole (Service; on = service).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <CoreData/CoreData.h>
#import <HTTPServerKit/HSAuthentication.h>

NS_ASSUME_NONNULL_BEGIN

@interface OISAuthorization : NSObject
// A permissions file's property list, read against the model.
- (instancetype)initWithPropertyList:(NSDictionary *)propertyList model:(NSManagedObjectModel *)model NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// What it could not say of the model, one sentence each.
@property (nonatomic, readonly, copy) NSArray<NSString *> *problems;
// Who the principal is, as a tuple's user may name them: as Identities says.
- (NSArray<NSString *> *)identitiesOfPrincipal:(nullable HSPrincipal *)principal;
// Whether the entity (or a super-entity) defines the relation.
- (BOOL)entity:(NSEntityDescription *)entity defines:(NSString *)relation;
// The rows of the entity on which the principal holds the relation; nil
// when the entity defines no such relation (no limit).
- (nullable NSPredicate *)predicateForRelation:(NSString *)relation
                                        entity:(NSEntityDescription *)entity
                                     principal:(nullable HSPrincipal *)principal;
// The relationships the relation goes through (its from terms, its
// computed relations' too): a new row's, made in the same request, decides
// there.
- (NSSet<NSString *> *)relationshipsOfRelation:(NSString *)relation entity:(NSEntityDescription *)entity;
// What the principal holds, as a version: changes when a tuple of theirs
// is added, removed or changed (a delta link's scope version).
- (nullable NSString *)versionForPrincipal:(nullable HSPrincipal *)principal context:(NSManagedObjectContext *)context;
@end

// A row, or a row to be: its values, and the object's for the rest (an
// update's values over the object; an insert's, over nothing).
@interface OISRowToBe : NSObject
- (instancetype)initWithValues:(NSDictionary<NSString *, id> *)values object:(nullable NSManagedObject *)object NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
