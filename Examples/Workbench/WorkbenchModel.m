// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchModel.h"

@implementation WorkbenchLogEntry
@end

#pragma mark - The model

static NSAttributeDescription *WBAttribute(NSString *name, NSAttributeType type, NSString *wire, BOOL optional, NSDictionary *more)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = optional;
  NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:wire forKey:@"OData.property"];
  [info addEntriesFromDictionary:more ?: @{}];
  attribute.userInfo = info;
  // A key stays in a deleted row's tombstone: delta links can name it (the
  // Catalog's keys say so in the model, "Preserve After Deletion").
  if ([info[@"OData.key"] isEqual:@"YES"]) attribute.preservesValueInHistoryOnDeletion = YES;
  return attribute;
}

static NSEntityDescription *WBEntity(NSString *name, NSString *set, NSDictionary *more, NSArray *properties)
{
  NSEntityDescription *entity = [[NSEntityDescription alloc] init];
  entity.name = name;
  entity.managedObjectClassName = @"NSManagedObject";
  NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:set forKey:@"OData.entitySet"];
  [info addEntriesFromDictionary:more ?: @{}];
  entity.userInfo = info;
  entity.properties = properties;
  return entity;
}

static NSRelationshipDescription *WBRelationship(NSString *name, NSString *wire, NSEntityDescription *to, BOOL many)
{
  NSRelationshipDescription *relationship = [[NSRelationshipDescription alloc] init];
  relationship.name = name;
  relationship.destinationEntity = to;
  relationship.minCount = 0;
  relationship.maxCount = many ? 0 : 1;
  relationship.optional = YES;
  relationship.deleteRule = NSNullifyDeleteRule;
  relationship.userInfo = @{ @"OData.property": wire };
  return relationship;
}

NSString * const WorkbenchServedConfiguration = @"Served";

NSManagedObjectModel *WorkbenchBuiltInModel(NSURL *catalogURL)
{
  NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:catalogURL] copy];
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  if (!product) return nil;
  NSAttributeDescription *version = WBAttribute(@"version", NSInteger64AttributeType, @"Version", YES, @{ @"OData.etag": @"YES" });
  // When it was changed last, as a hybrid logical clock says (ODataSync's
  // last writer wins, in the Sync window): the device stamps it, and so does
  // the service's own change.
  NSAttributeDescription *lastChanged = WBAttribute(@"lastChanged", NSStringAttributeType, @"LastChanged", YES, nil);
  // What each version has seen (ODataSync's version vector), which the
  // service and the device keep alike.
  NSAttributeDescription *versions = WBAttribute(@"versions", NSStringAttributeType, @"Versions", YES, nil);
  product.properties = [product.properties arrayByAddingObjectsFromArray:@[ version, lastChanged, versions ]];
  NSMutableDictionary *productInfo = [product.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
  productInfo[@"ODataSync.versions"] = @"versions";
  product.userInfo = productInfo;
  NSEntityDescription *budget = WBEntity(@"Budget", @"Budgets", @{ @"OData.periodStart": @"from", @"OData.periodEnd": @"to", @"OData.objectKey": @"category" }, @[
    WBAttribute(@"id", NSInteger64AttributeType, @"BudgetID", NO, @{ @"OData.key": @"YES" }),
    WBAttribute(@"category", NSStringAttributeType, @"CategoryName", NO, nil),
    WBAttribute(@"from", NSDateAttributeType, @"ValidFrom", NO, @{ @"OData.type": @"Edm.Date" }),
    WBAttribute(@"to", NSDateAttributeType, @"ValidTo", YES, @{ @"OData.type": @"Edm.Date" }),
    WBAttribute(@"amount", NSDecimalAttributeType, @"Amount", YES, nil) ]);
  NSEntityDescription *picture = WBEntity(@"Picture", @"Pictures", @{ @"OData.mediaStream": @"content" }, @[
    WBAttribute(@"id", NSInteger32AttributeType, @"PictureID", NO, @{ @"OData.key": @"YES" }),
    WBAttribute(@"name", NSStringAttributeType, @"Name", YES, nil),
    WBAttribute(@"content", NSBinaryDataAttributeType, @"Content", YES, @{ @"OData.contentType": @"contentType" }),
    WBAttribute(@"contentType", NSStringAttributeType, @"ContentType", YES, nil) ]);
  // Sales organizations, a recursive hierarchy (Data Aggregation section
  // 5.5.1: the node identifier, and the parent), and their sales: the Data
  // Aggregation spec's example data.
  NSString *hierarchy = @"{\"Aggregation.RecursiveHierarchy#SalesOrgHierarchy\": {\"NodeProperty\": {\"$PropertyPath\": \"ID\"}, "
                        @"\"ParentNavigationProperty\": {\"$NavigationPropertyPath\": \"Superordinate\"}}}";
  NSEntityDescription *organization = WBEntity(@"SalesOrganization", @"SalesOrganizations", @{ @"OData.annotations": hierarchy }, @[
    WBAttribute(@"id", NSStringAttributeType, @"ID", NO, @{ @"OData.key": @"YES" }),
    WBAttribute(@"name", NSStringAttributeType, @"Name", YES, nil) ]);
  NSEntityDescription *sale = WBEntity(@"Sale", @"Sales", nil, @[
    WBAttribute(@"id", NSInteger32AttributeType, @"ID", NO, @{ @"OData.key": @"YES" }),
    WBAttribute(@"amount", NSDecimalAttributeType, @"Amount", YES, nil) ]);
  NSRelationshipDescription *superordinate = WBRelationship(@"superordinate", @"Superordinate", organization, NO);
  NSRelationshipDescription *subordinates = WBRelationship(@"subordinates", @"Subordinates", organization, YES);
  NSRelationshipDescription *sales = WBRelationship(@"sales", @"Sales", sale, YES);
  NSRelationshipDescription *seller = WBRelationship(@"salesOrganization", @"SalesOrganization", organization, NO);
  superordinate.inverseRelationship = subordinates;
  subordinates.inverseRelationship = superordinate;
  sales.inverseRelationship = seller;
  seller.inverseRelationship = sales;
  organization.properties = [organization.properties arrayByAddingObjectsFromArray:@[ superordinate, subordinates, sales ]];
  sale.properties = [sale.properties arrayByAddingObject:seller];
  // Equipment at the locations: each kind has properties of its own (a
  // forklift's load capacity, a freezer's temperature, a scale's
  // calibration), which the model does not declare. An open type, its
  // dynamic properties kept in a bag, a Transformable the service keeps
  // them in by default: filtered by, it is filtered here, not in SQLite.
  NSAttributeDescription *bag = [[NSAttributeDescription alloc] init];
  bag.name = @"dynamicProperties";
  bag.attributeType = NSTransformableAttributeType;
  bag.valueTransformerName = @"NSSecureUnarchiveFromData";
  bag.attributeValueClassName = @"NSDictionary";
  bag.optional = YES;
  bag.userInfo = @{ @"OData.dynamicProperties": @"YES" };
  NSEntityDescription *equipment = WBEntity(@"EquipmentUnit", @"EquipmentUnits", nil, @[
    WBAttribute(@"id", NSInteger32AttributeType, @"UnitID", NO, @{ @"OData.key": @"YES" }),
    WBAttribute(@"name", NSStringAttributeType, @"Name", NO, nil),
    WBAttribute(@"kind", NSStringAttributeType, @"Kind", NO, nil), bag ]);
  NSEntityDescription *location = model.entitiesByName[@"Location"];
  NSRelationshipDescription *site = WBRelationship(@"location", @"Location", location, NO);
  NSRelationshipDescription *units = WBRelationship(@"equipment", @"Equipment", equipment, YES);
  site.inverseRelationship = units;
  units.inverseRelationship = site;
  equipment.properties = [equipment.properties arrayByAddingObject:site];
  location.properties = [location.properties arrayByAddingObject:units];
  NSArray *served = [model.entities arrayByAddingObjectsFromArray:@[ budget, picture, organization, sale, equipment ]];
  // The application's own bookkeeping, which the service does not serve:
  // what its actions did. Left out of the configuration it serves.
  NSEntityDescription *audit = WBEntity(@"AuditEntry", @"AuditEntries", nil, @[
    WBAttribute(@"id", NSStringAttributeType, @"ID", NO, @{ @"OData.key": @"YES" }),
    WBAttribute(@"at", NSDateAttributeType, @"At", NO, nil),
    WBAttribute(@"what", NSStringAttributeType, @"What", NO, nil) ]);
  model.entities = [served arrayByAddingObject:audit];
  [model setEntities:served forConfiguration:WorkbenchServedConfiguration];
  return model;
}
