// odatakit-permissions — a permissions file, checked against its model
// before it is served (docs/permissions.md).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   odatakit-permissions check Model.momd Permissions.plist
//
// Prints what does not fit, one line each, as the service would find it
// (ODataPermissions -problemsWithModel:), and exits 1 when anything does;
// 0, silently, when it all fits; 2 when it cannot read either file. A
// build step, or a test, runs it.

#import <ODataService/ODataService.h>

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    if (argc != 4 || strcmp(argv[1], "check") != 0) {
      fprintf(stderr, "usage: odatakit-permissions check Model.momd Permissions.plist\n");
      return 2;
    }
    NSString *modelPath = [NSString stringWithUTF8String:argv[2]], *path = [NSString stringWithUTF8String:argv[3]];
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:modelPath]];
    if (!model.entities.count) {
      fprintf(stderr, "odatakit-permissions: %s is not a model\n", modelPath.UTF8String);
      return 2;
    }
    NSError *error = nil;
    ODataPermissions *permissions = [ODataPermissions permissionsWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
    if (!permissions) {
      fprintf(stderr, "odatakit-permissions: %s\n", error.localizedDescription.UTF8String);
      return 2;
    }
    NSArray<NSString *> *problems = [permissions problemsWithModel:model];
    for (NSString *problem in problems) fprintf(stderr, "%s: %s\n", path.UTF8String, problem.UTF8String);
    return problems.count ? 1 : 0;
  }
}
