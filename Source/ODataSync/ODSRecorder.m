// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"

@implementation ODSRecorder {
  __weak ODataSyncEngine *_engine;
}

- (instancetype)initWithEngine:(ODataSyncEngine *)engine
{
  self = [super init];
  if (!self) return nil;
  _engine = engine;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contextWillSave:)
                                               name:NSManagedObjectContextWillSaveNotification object:nil];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Deletions remembered (docs/offline-sync.md, 7): whoever deleted a synced
// object, its key is kept, so that a peer that has not heard yet cannot
// bring it back (an insert passed on late, round and round). An object made
// here again, or by a service (the authority), is not deleted any more.
- (void)noteDeletionsIn:(NSManagedObjectContext *)context author:(NSString *)author count:(int64_t (^)(void))count
{
  ODataSyncEngine *engine = _engine;
  ODSModel *model = engine.model;
  ODSCodec *codec = engine.codec;
  ODSStore *store = engine.store;
  BOOL authority = ![author hasPrefix:@"ODataSync."];
  if ([author hasPrefix:ODataSyncDownAuthorPrefix]) {
    ODataSyncRemote *from = [engine remoteWithIdentifier:[author substringFromIndex:ODataSyncDownAuthorPrefix.length]];
    authority = from && !from.peer;
  }
  for (NSManagedObject *object in context.deletedObjects) {
    NSEntityDescription *root = [model rootOf:object.entity];
    if ([model directionOfEntity:root] == ODataSyncDirectionNone) continue;
    NSString *keyText = [codec keyTextOf:[codec keyOfObject:object] entity:root];
    if (!keyText || [store isDeleted:root.name keyText:keyText inContext:context]) continue;
    // The deleted version, and the deletion a change of its own when this
    // side made it; a client's deletion with the history it sent.
    NSDictionary *versions = [codec versionsOfObject:object];
    NSString *sent = ODSSentDeletions(context)[[root.name stringByAppendingFormat:@" %@", keyText]];
    if (sent) versions = ODSMergeVersions(versions, ODSVersionsFromText(sent));
    if (count && [model versionsAttributeOf:object.entity]) versions = ODSMergeVersions(versions, @{ engine.clock.shortReplica: @(count()) });
    [store rememberDeletionOf:root.name keyText:keyText versions:versions inContext:context];
  }
  if (!authority) return;
  for (NSManagedObject *object in context.insertedObjects) {
    NSEntityDescription *root = [model rootOf:object.entity];
    if ([model directionOfEntity:root] == ODataSyncDirectionNone) continue;
    NSString *keyText = [codec keyTextOf:[codec keyOfObject:object] entity:root];
    if (keyText) [store forgetDeletionOf:root.name keyText:keyText inContext:context];
  }
}

- (void)contextWillSave:(NSNotification *)notification
{
  ODataSyncEngine *engine = _engine;
  NSManagedObjectContext *context = notification.object;
  if (!engine || context.persistentStoreCoordinator != engine.coordinator) return;
  ODSModel *model = engine.model;
  ODSCodec *codec = engine.codec;
  ODSClock *clock = engine.clock;
  NSString *author = [context respondsToSelector:@selector(transactionAuthor)] ? context.transactionAuthor : nil;
  BOOL local = ![author hasPrefix:@"ODataSync."];
  // A save of the app's is one change of this replica's: one count for all
  // it changes, taken when first needed.
  __block int64_t counted = 0;
  int64_t (^count)(void) = ^int64_t {
    if (!counted) counted = [clock nextCount];
    return counted;
  };
  if (context.deletedObjects.count || context.insertedObjects.count) [self noteDeletionsIn:context author:author count:local ? count : nil];
  if (!local) return;
  NSMutableSet *changed = [NSMutableSet setWithSet:context.insertedObjects];
  [changed unionSet:context.updatedObjects];
  for (NSManagedObject *object in changed) {
    NSAttributeDescription *stamp = [model modifiedAttributeOf:object.entity];
    NSAttributeDescription *versions = [model versionsAttributeOf:object.entity];
    if (!stamp && !versions) continue;
    NSMutableDictionary *changes = [object.changedValues mutableCopy];
    // A stamp the save set itself (a server app's, an import's) stands.
    BOOL stamped = stamp && changes[stamp.name] != nil && [object valueForKey:stamp.name] != nil;
    if (stamp) [changes removeObjectForKey:stamp.name];
    if (versions) [changes removeObjectForKey:versions.name];
    // A to-many is not what a sync exchanges (its attributes and to-ones
    // are): one that gained or lost a member (a child bound to it, whose
    // own to-one changed) is no change of this object's, and its version
    // stays (#58: a catalog's ETag changed as warehouses were added).
    for (NSString *name in changes.allKeys) {
      if ([object.entity.relationshipsByName[name] isToMany]) [changes removeObjectForKey:name];
    }
    if (!object.isInserted && !changes.count) continue;
    if (stamp && !stamped) [object setValue:[clock tick] forKey:stamp.name];
    if (versions) {
      NSDictionary *seen = ODSMergeVersions([codec versionsOfObject:object], @{ clock.shortReplica: @(count()) });
      [object setValue:ODSTextOfVersions(seen) forKey:versions.name];
    }
  }
}

@end
