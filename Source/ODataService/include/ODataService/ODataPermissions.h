// ODataPermissions -- permissions on objects, as Google's Zanzibar models
// them (docs/permissions.md), in a file of their own: a property list
// beside the model, loaded by the service (ODataService.permissions), and
// checked against the model offline too (odatakit-permissions check).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   {
//     Version = 1;
//     Identities = ( sub, email, preferred_username, groups );   // who the caller is
//     Service = { admin = ( { claim = roles; value = admin; } ); };
//     Tuples = {
//       WarehouseStaff = { object = warehouse; relation = staffRole; user = "user.email"; };
//     };
//     Entities = {
//       Warehouse = {
//         owner   = ( { relation = owner; from = catalog; } );
//         manager = ( { direct = YES; }, { relation = owner; } );
//         read    = ( { relation = manager; }, { relation = admin; on = service; } );
//       };
//     };
//   }

#pragma once
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataPermissions : NSObject

// A permissions file: a property list, XML, binary or OpenStep. nil, and
// error set, when it cannot be read or is not one (not a dictionary, no
// Version 1); what it says of the model is -problemsWithModel:'s.
+ (nullable instancetype)permissionsWithContentsOfURL:(NSURL *)url error:(NSError **)error;
+ (nullable instancetype)permissionsWithPropertyList:(NSDictionary<NSString *, id> *)propertyList error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *propertyList;

// What does not fit the model, one sentence each; empty when it does: an
// entity, relationship or attribute the model has not; a from through
// what is no relationship; a relation defined nowhere; a where that does
// not parse, or names what the entity has not; a tuple's relation that
// its object defines not; computed relations in a cycle; a key it does not
// know. The service checks the same when it is given them
// (metadataProblems); a build checks it with odatakit-permissions.
- (NSArray<NSString *> *)problemsWithModel:(NSManagedObjectModel *)model;

@end

FOUNDATION_EXPORT NSErrorDomain const ODataPermissionsErrorDomain;

NS_ASSUME_NONNULL_END
