// ois-filter — NSPredicate → OData $filter, on GNUstep.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Links FreeCoreData (https://github.com/ashalkhakov/FreeCoreData).
//
//   ./ois-filter 'unitPrice > 20 AND discontinued == NO'
//   UnitPrice gt 20 and Discontinued eq false

#import "ODataIncrementalStore.h"
#import <stdio.h>

// Core Data loads compiled models only: Tools/GNUmakefile compiles
// Examples/Catalog/Catalog.xcdatamodeld to Catalog.momd with momc, beside
// this file; or one in the current directory.
static NSManagedObjectModel *OISLoadCatalogModel(void)
{
  NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
  NSArray *candidates = @[
    [here stringByAppendingPathComponent:@"Catalog.momd"],
    @"Catalog.momd",
  ];
  for (NSString *path in candidates) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
      return [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]];
    }
  }
  return nil;
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSString *format = argc > 1
      ? [NSString stringWithUTF8String:argv[1]]
      : @"unitPrice > 20 AND discontinued == NO";

    NSManagedObjectModel *model = OISLoadCatalogModel();
    NSEntityDescription *entity = model.entitiesByName[@"Product"];
    if (!entity) {
      fprintf(stderr, "ois-filter: could not load Catalog.momd (run make in Tools/)\n");
      return 1;
    }

    ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
    ODataPredicateTranslator *translator =
        [[ODataPredicateTranslator alloc] initWithMapper:mapper entity:entity];

    NSError *error = nil;
    NSPredicate *predicate = [NSPredicate predicateWithFormat:format];
    NSString *filter = [translator translatePredicate:predicate error:&error];
    if (!filter) {
      fprintf(stderr, "ois-filter: %s\n",
              error.localizedDescription.UTF8String ?: "unsupported predicate");
      return 1;
    }
    puts(filter.UTF8String);
  }
  return 0;
}
