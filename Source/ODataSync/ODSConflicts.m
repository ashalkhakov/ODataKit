// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Conflicts (docs/offline-sync.md, 6): a both object changed here and at
// a remote since the version both last agreed on (the shadow's). Found on
// download (a row of an object with an outbox entry) and on upload (412);
// settled here, the same way, by the entity's resolver.

#import "ODSInternal.h"


#pragma mark - Conflicts and resolutions

@implementation ODataSyncConflict

- (instancetype)initWithEntity:(NSEntityDescription *)entity key:(NSDictionary *)key base:(NSDictionary *)base
                         local:(NSDictionary *)local remote:(NSDictionary *)remote
                  localChanges:(NSSet *)localChanges remoteChanges:(NSSet *)remoteChanges withPeer:(BOOL)withPeer
{
  self = [super init];
  if (!self) return nil;
  _entity = entity;
  _key = [key copy];
  _base = [base copy];
  _local = [local copy];
  _remote = [remote copy];
  _localChanges = [localChanges copy];
  _remoteChanges = [remoteChanges copy];
  _withPeer = withPeer;
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncConflict %@ %@: here %@, there %@>", _entity.name, _key,
                                    _local ? _localChanges : @"deleted", _remote ? _remoteChanges : @"deleted"];
}

@end

@implementation ODataSyncResolution

- (instancetype)initWithKind:(ODataSyncResolutionKind)kind values:(NSDictionary *)values
{
  self = [super init];
  if (!self) return nil;
  _kind = kind;
  _values = [values copy];
  return self;
}

+ (instancetype)takeRemote
{
  return [[self alloc] initWithKind:ODataSyncTakeRemote values:nil];
}

+ (instancetype)keepLocal
{
  return [[self alloc] initWithKind:ODataSyncKeepLocal values:nil];
}

+ (instancetype)mergedValues:(NSDictionary *)values
{
  return [[self alloc] initWithKind:ODataSyncMerge values:values ?: @{}];
}

+ (instancetype)defer
{
  return [[self alloc] initWithKind:ODataSyncDefer values:nil];
}

@end

#pragma mark - Resolvers

@implementation ODataSyncRemoteWins
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  return [ODataSyncResolution takeRemote];
}
@end

@implementation ODataSyncLocalWins
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  return [ODataSyncResolution keepLocal];
}
@end

// Values as text, in the order of their names: the same on every side.
static NSString *ODSFingerprint(NSDictionary *values)
{
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]) [text appendFormat:@"%@=%@;", name, values[name]];
  return text;
}

@implementation ODataSyncLastWriterWins
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  NSString *name = ODSModifiedAttributeOf(conflict.entity).name;
  id local = name ? conflict.local[name] : nil;
  id remote = name ? conflict.remote[name] : nil;
  // A delete has no stamp of its own: the other side's change stands.
  if (!conflict.local && conflict.remote) return [ODataSyncResolution takeRemote];
  if (!conflict.remote && conflict.local) return [ODataSyncResolution keepLocal];
  NSComparisonResult order = [local isKindOfClass:[NSString class]] && [remote isKindOfClass:[NSString class]] ? [local compare:remote]
                                                                                                           : NSOrderedSame;
  // No stamps to tell (or the same): the service's, from a service; from a
  // peer, the same side whichever asks, by the values.
  if (order == NSOrderedSame && conflict.withPeer) order = [ODSFingerprint(conflict.local) compare:ODSFingerprint(conflict.remote)];
  return order == NSOrderedDescending ? [ODataSyncResolution keepLocal] : [ODataSyncResolution takeRemote];
}
@end

@implementation ODataSyncMergeFields

- (instancetype)initWithFallback:(id<ODataSyncResolving>)fallback
{
  self = [super init];
  if (!self) return nil;
  _fallback = fallback;
  return self;
}

- (instancetype)init
{
  return [self initWithFallback:[[ODataSyncRemoteWins alloc] init]];
}

- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  if (!conflict.base || !conflict.local || !conflict.remote) return [self.fallback resolveConflict:conflict];
  NSMutableDictionary *merged = [NSMutableDictionary dictionary];
  ODataSyncResolution *overlap = nil;
  NSMutableSet *names = [NSMutableSet setWithSet:conflict.localChanges];
  [names unionSet:conflict.remoteChanges];
  for (NSString *name in names) {
    BOOL here = [conflict.localChanges containsObject:name], there = [conflict.remoteChanges containsObject:name];
    id local = conflict.local[name] ?: [NSNull null], remote = conflict.remote[name] ?: [NSNull null];
    if (here && there && ![local isEqual:remote]) {
      // Both changed it, differently: as the fallback has the whole object.
      if (!overlap) overlap = [self.fallback resolveConflict:conflict];
      if (overlap.kind == ODataSyncDefer) return overlap;
      if (overlap.kind == ODataSyncMerge) merged[name] = overlap.values[name] ?: local;
      else merged[name] = overlap.kind == ODataSyncKeepLocal ? local : remote;
    } else {
      merged[name] = here ? local : remote;
    }
  }
  return [ODataSyncResolution mergedValues:merged];
}

@end

#pragma mark - Settling

@implementation ODataSyncEngine (ODSConflicts)

// Between peers neither side is the authority, and each asks in turn: a
// rule must choose the same version whichever side asks, or the two swap
// forever. The remote's or this side's are not such; last writer wins is.
- (id<ODataSyncResolving>)resolverFor:(NSEntityDescription *)root remote:(ODataSyncRemote *)remote
{
  id<ODataSyncResolving> resolver = [self resolverFor:root];
  if (!remote.peer) return resolver;
  BOOL (^sided)(id) = ^BOOL(id rule) {
    return [rule isKindOfClass:[ODataSyncRemoteWins class]] || [rule isKindOfClass:[ODataSyncLocalWins class]];
  };
  if (sided(resolver)) return [[ODataSyncLastWriterWins alloc] init];
  if ([resolver isKindOfClass:[ODataSyncMergeFields class]] && sided(((ODataSyncMergeFields *)resolver).fallback)) {
    return [[ODataSyncMergeFields alloc] initWithFallback:[[ODataSyncLastWriterWins alloc] init]];
  }
  return resolver;
}

- (id<ODataSyncResolving>)resolverFor:(NSEntityDescription *)root
{
  id<ODataSyncResolving> resolver = [self resolverForEntityName:root.name];
  if (resolver) return resolver;
  NSString *named = [self.model conflictRuleOf:root];
  if ([named isEqualToString:@"local"]) return [[ODataSyncLocalWins alloc] init];
  if ([named isEqualToString:@"lastwriter"]) return [[ODataSyncLastWriterWins alloc] init];
  if ([named isEqualToString:@"merge"]) return [[ODataSyncMergeFields alloc] init];
  if ([named isEqualToString:@"remote"]) return [[ODataSyncRemoteWins alloc] init];
  if (self.resolver) return self.resolver;
  return self.conflictPolicy == ODataSyncPolicyLocalWins ? [[ODataSyncLocalWins alloc] init] : [[ODataSyncRemoteWins alloc] init];
}

- (void)agreeOn:(NSDictionary *)row etag:(NSString *)etag of:(NSEntityDescription *)root keyText:(NSString *)keyText
         remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context
{
  NSManagedObject *shadow = [self.store shadowOf:root.name keyText:keyText remote:remote inContext:context make:row != nil];
  if (!row) {
    if (shadow) [context deleteObject:shadow];
    return;
  }
  if (etag) [shadow setValue:etag forKey:@"etag"];
  // Large binaries as their digests: what a comparison needs of them.
  [shadow setValue:[NSJSONSerialization dataWithJSONObject:[self.codec shadowOfRow:row entity:root] options:0 error:NULL] forKey:@"values"];
}

// The outbox entry, after a resolution: what this side still has to send
// over the remote's version (nothing: gone).
- (void)sendWhatDiffers:(NSManagedObject *)object from:(NSDictionary *)remoteValues entry:(NSManagedObject *)entry
                context:(NSManagedObjectContext *)context
{
  if (!remoteValues) {
    // Deleted there: made again, whole.
    [entry setValue:@(ODataSyncOperationInsert) forKey:@"operation"];
    [entry setValue:nil forKey:@"properties"];
    return;
  }
  NSSet *differ = ODSChangedNames([self.codec valuesOfObject:object], remoteValues);
  if (!differ.count) {
    [context deleteObject:entry];
    return;
  }
  [entry setValue:@(ODataSyncOperationUpdate) forKey:@"operation"];
  [entry setValue:ODSArchive(differ.allObjects) forKey:@"properties"];
}

- (BOOL)keepNewerThan:(NSDictionary *)row etag:(NSString *)etag of:(NSEntityDescription *)root key:(NSDictionary *)key
               remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context
{
  return [self keepNewerThan:row etag:etag of:root key:key remote:remote context:context versions:NO];
}

- (BOOL)keepNewerThan:(NSDictionary *)row etag:(NSString *)etag of:(NSEntityDescription *)root key:(NSDictionary *)key
               remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context versions:(BOOL)known
{
  ODSCodec *codec = self.codec;
  ODSModel *model = self.model;
  NSManagedObject *object = nil;
  if (known) {
    // The histories said so.
    object = [codec objectOfEntity:root key:key inContext:context];
    if (!object) return NO;
  } else {
    // By the stamps, from a peer.
    NSAttributeDescription *stamp = [model modifiedAttributeOf:root];
    object = stamp && remote.peer ? [codec objectOfEntity:root key:key inContext:context] : nil;
    id ours = [object valueForKey:stamp.name], theirs = row[[codec.mapper propertyForAttribute:stamp]];
    if (![ours isKindOfClass:[NSString class]] || ![theirs isKindOfClass:[NSString class]] || [ours compare:theirs] != NSOrderedDescending) return NO;
  }
  // Older than this side's: a peer a step behind (what it has came round
  // from where this side's went). Taken, it would go round again.
  NSString *keyText = [codec keyTextOf:key entity:root];
  [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
  NSManagedObject *entry = [self.store newEntryOf:root key:key operation:ODataSyncOperationUpdate remote:remote context:context];
  [self sendWhatDiffers:object from:[codec valuesFromJSON:row entity:root] entry:entry context:context];
  return YES;
}

- (void)settleConflictOf:(NSEntityDescription *)root key:(NSDictionary *)key entry:(NSManagedObject *)entry
               remoteRow:(NSDictionary *)row etag:(NSString *)etag remote:(ODataSyncRemote *)remote
                 context:(NSManagedObjectContext *)context
{
  [self settleConflictOf:root key:key entry:entry remoteRow:row remoteVersions:nil etag:etag remote:remote context:context];
}

// The version the object has now: what both have seen (each count the
// larger), and a change of this replica's when its values are new to both.
- (void)setVersionsOf:(NSManagedObject *)object seen:(NSDictionary *)local and:(NSDictionary *)remote changed:(BOOL)changed
{
  NSAttributeDescription *attribute = object ? [self.model versionsAttributeOf:object.entity] : nil;
  if (!attribute) return;
  NSDictionary *versions = ODSMergeVersions(local, remote);
  if (changed) versions = ODSMergeVersions(versions, @{ self.clock.shortReplica: @([self.clock nextCount]) });
  [object setValue:ODSTextOfVersions(versions) forKey:attribute.name];
}

- (NSManagedObject *)objectToWrite:(NSEntityDescription *)root key:(NSDictionary *)key context:(NSManagedObjectContext *)context
{
  NSManagedObject *object = [self.codec objectOfEntity:root key:key inContext:context];
  if (object) return object;
  object = [[NSManagedObject alloc] initWithEntity:root insertIntoManagedObjectContext:context];
  for (NSString *name in key) [object setValue:key[name] forKey:name];
  return object;
}

- (void)settleConflictOf:(NSEntityDescription *)root key:(NSDictionary *)key entry:(NSManagedObject *)entry
               remoteRow:(NSDictionary *)row remoteVersions:(NSDictionary *)deletedVersions etag:(NSString *)etag
                  remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context
{
  ODSCodec *codec = self.codec;
  ODSModel *model = self.model;
  NSString *keyText = [codec keyTextOf:key entity:root];
  NSManagedObject *shadow = [self.store shadowOf:root.name keyText:keyText remote:remote inContext:context make:NO];
  NSData *kept = [shadow valueForKey:@"values"];
  id baseRow = kept.length ? [NSJSONSerialization JSONObjectWithData:kept options:0 error:NULL] : nil;
  NSMutableDictionary *base = [baseRow isKindOfClass:[NSDictionary class]] ? [[codec valuesFromShadow:baseRow entity:root] mutableCopy] : nil;
  BOOL deletedHere = [[entry valueForKey:@"operation"] integerValue] == ODataSyncOperationDelete;
  NSManagedObject *object = deletedHere ? nil : [codec objectOfEntity:root key:key inContext:context];
  NSMutableDictionary *local = object ? [[codec valuesOfObject:object] mutableCopy] : nil;
  NSMutableDictionary *remoteValues = row ? [[codec valuesFromJSON:row entity:root] mutableCopy] : nil;
  NSAttributeDescription *stamp = [model modifiedAttributeOf:root];
  if (stamp && remoteValues) [self.clock witness:remoteValues[stamp.name]];
  // What each version has seen: the vectors, which the values compared
  // leave out (they differ whenever the histories do).
  NSAttributeDescription *versionsAttribute = [model versionsAttributeOf:root];
  NSDictionary *localVersions = object ? [codec versionsOfObject:object]
                                       : [self.store deletedVersionsOf:root.name keyText:keyText inContext:context];
  NSDictionary *remoteVersions = row ? [codec versionsOfRow:row entity:root] : deletedVersions ?: @{};
  if (versionsAttribute) {
    [base removeObjectForKey:versionsAttribute.name];
    [local removeObjectForKey:versionsAttribute.name];
    [remoteValues removeObjectForKey:versionsAttribute.name];
  }
  BOOL known = versionsAttribute && localVersions.count && remoteVersions.count;
  ODSOrder order = known ? ODSCompareVersions(remoteVersions, localVersions) : ODSOrderConcurrent;

  // The same values on both sides: nothing to settle; that is the version
  // agreed on (its history both histories).
  if ((!local && !remoteValues) || (local && remoteValues && !ODSChangedNames(local, remoteValues).count)) {
    [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
    if (object && known && order != ODSOrderAfter) {
      [self setVersionsOf:object seen:localVersions and:remoteVersions changed:NO];
      [self sendWhatDiffers:object from:remoteValues ? [codec valuesFromJSON:row entity:root] : nil entry:entry context:context];
    } else {
      if (object && known) [self setVersionsOf:object seen:localVersions and:remoteVersions changed:NO];
      [context deleteObject:entry];
    }
    return;
  }
  // The remote's version saw this side's change: no conflict; it is newer.
  if (known && order == ODSOrderAfter) {
    if (row) [codec applyJSON:row toObject:[self objectToWrite:root key:key context:context]];
    else if (object) [context deleteObject:object];
    [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
    [context deleteObject:entry];
    return;
  }
  // Only this side changed it: the remote's is a version this one saw (by
  // the vectors), or the one agreed on, read again. The change goes as it
  // is, over that version.
  if ((known && (order == ODSOrderBefore || order == ODSOrderSame)) || (!known && base && remoteValues && !ODSChangedNames(base, remoteValues).count)) {
    [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
    return;
  }
  NSArray *all = [[[model attributesOf:root] valueForKey:@"name"] arrayByAddingObjectsFromArray:[[model toOnesOf:root] valueForKey:@"name"]];
  NSMutableSet *everything = [NSMutableSet setWithArray:all];
  if (versionsAttribute) [everything removeObject:versionsAttribute.name];
  NSSet *localChanges = base && local ? ODSChangedNames(base, local) : everything;
  NSSet *remoteChanges = base && remoteValues ? ODSChangedNames(base, remoteValues) : everything;
  ODataSyncConflict *conflict = [[ODataSyncConflict alloc] initWithEntity:root key:key base:base local:local remote:remoteValues
                                                             localChanges:localChanges remoteChanges:remoteChanges
                                                                 withPeer:remote.peer];
  ODataSyncResolution *resolution = [[self resolverFor:root remote:remote] resolveConflict:conflict] ?: [ODataSyncResolution takeRemote];
  [self count:@"conflicts" by:1];
  NSDictionary *remoteWhole = row ? [codec valuesFromJSON:row entity:root] : nil;
  // A merge that names a file by its digest (the base's): that side's
  // bytes; neither side's, and there are none to write - set aside.
  ODataSyncResolutionKind kind = resolution.kind;
  NSMutableDictionary *mergedValues = [resolution.values mutableCopy] ?: [NSMutableDictionary dictionary];
  NSString *deferred = @"Changed here and at the service: a conflict to settle";
  if (kind == ODataSyncMerge) {
    for (NSString *name in [mergedValues allKeys]) {
      ODataSyncDigest *digest = mergedValues[name];
      if (![digest isKindOfClass:[ODataSyncDigest class]]) continue;
      if ([digest isDigestOfData:local[name]]) [mergedValues removeObjectForKey:name];
      else if ([digest isDigestOfData:remoteValues[name]]) mergedValues[name] = remoteValues[name];
      else {
        kind = ODataSyncDefer;
        deferred = [NSString stringWithFormat:@"The resolution kept %@ as agreed, which is known only by its digest: a conflict to settle", name];
      }
    }
  }
  switch (kind) {
    case ODataSyncTakeRemote:
      if (row) {
        object = [self objectToWrite:root key:key context:context];
        [codec applyJSON:row toObject:object];
      } else if ((object = [codec objectOfEntity:root key:key inContext:context])) {
        [context deleteObject:object];
        object = nil;
      }
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      if (object && known) {
        // The remote's values, and a history that includes this side's: the
        // remote is told, so that it does not take this side's for a conflict.
        [self setVersionsOf:object seen:localVersions and:remoteVersions changed:NO];
        [self sendWhatDiffers:object from:remoteWhole entry:entry context:context];
      } else {
        [context deleteObject:entry];
      }
      break;
    case ODataSyncKeepLocal:
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      if (!object) {
        // Deleted here: a deletion, now of the remote's version; nothing when gone there too.
        if (row) [entry setValue:@(ODataSyncOperationDelete) forKey:@"operation"]; else [context deleteObject:entry];
      } else {
        if (known) [self setVersionsOf:object seen:localVersions and:remoteVersions changed:NO];
        [self sendWhatDiffers:object from:remoteWhole entry:entry context:context];
      }
      break;
    case ODataSyncMerge: {
      object = [self objectToWrite:root key:key context:context];
      [codec applyValues:mergedValues toObject:object];
      if (stamp && [mergedValues objectForKey:stamp.name] == nil) [object setValue:[self.clock tick] forKey:stamp.name];
      if (known || versionsAttribute) {
        NSMutableDictionary *now = [[codec valuesOfObject:object] mutableCopy];
        if (versionsAttribute) [now removeObjectForKey:versionsAttribute.name];
        BOOL changed = (!local || ODSChangedNames(now, local).count) && (!remoteValues || ODSChangedNames(now, remoteValues).count);
        [self setVersionsOf:object seen:localVersions and:remoteVersions changed:changed];
      }
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      [self sendWhatDiffers:object from:remoteWhole entry:entry context:context];
      break;
    }
    case ODataSyncDefer:
      // The remote's version is the one a retry goes over, and the history
      // a retry has seen.
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      if (object && known) [self setVersionsOf:object seen:localVersions and:remoteVersions changed:NO];
      [entry setValue:@YES forKey:@"setAside"];
      [entry setValue:@409 forKey:@"status"];
      [entry setValue:deferred forKey:@"message"];
      [self setAside:[[ODataSyncIssue alloc] initWithEntry:entry objectID:object.objectID]];
      break;
  }
}

@end
