// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"

// What the engine tells of its outbox and of a sync: a change waiting, one
// set aside (an issue), what a sync did.

@implementation ODataSyncChange

- (instancetype)initWithEntry:(NSManagedObject *)entry objectID:(NSManagedObjectID *)objectID
{
  self = [super init];
  if (!self) return nil;
  _entryID = entry.objectID;
  _remoteIdentifier = [entry valueForKey:@"remote"] ?: @"";
  _entityName = [entry valueForKey:@"entityType"] ?: @"";
  _key = ODSUnarchive([entry valueForKey:@"key"]) ?: @{};
  _operation = [[entry valueForKey:@"operation"] integerValue];
  _properties = ODSUnarchive([entry valueForKey:@"properties"]);
  _attempts = [[entry valueForKey:@"attempts"] integerValue];
  _objectID = objectID;
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncChange %@ %@ %ld>", _entityName, _key, (long)_operation];
}

@end

@implementation ODataSyncIssue

- (instancetype)initWithEntry:(NSManagedObject *)entry objectID:(NSManagedObjectID *)objectID
{
  self = [super initWithEntry:entry objectID:objectID];
  if (!self) return nil;
  _status = [[entry valueForKey:@"status"] integerValue];
  _message = [entry valueForKey:@"message"] ?: @"";
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncIssue %@ %@ %ld: %@>", self.entityName, self.key, (long)_status, _message];
}

@end

@implementation ODataSyncResult

- (instancetype)initWithTally:(NSDictionary<NSString *, NSNumber *> *)tally
{
  self = [super init];
  if (!self) return nil;
  _downloaded = [tally[@"downloaded"] unsignedIntegerValue];
  _removed = [tally[@"removed"] unsignedIntegerValue];
  _uploaded = [tally[@"uploaded"] unsignedIntegerValue];
  _refused = [tally[@"refused"] unsignedIntegerValue];
  _conflicts = [tally[@"conflicts"] unsignedIntegerValue];
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncResult down %lu, removed %lu, up %lu, refused %lu, conflicts %lu>",
                                    (unsigned long)_downloaded, (unsigned long)_removed, (unsigned long)_uploaded,
                                    (unsigned long)_refused, (unsigned long)_conflicts];
}

@end

@implementation ODataSyncProgress

- (instancetype)initWithRemote:(ODataSyncRemote *)remote phase:(ODataSyncPhase)phase completed:(NSUInteger)completed total:(NSUInteger)total
{
  self = [super init];
  if (!self) return nil;
  _remote = remote;
  _phase = phase;
  _completed = completed;
  _total = total;
  return self;
}

- (NSString *)description
{
  NSArray *phases = @[ @"receiving", @"sending", @"merging" ];
  return [NSString stringWithFormat:@"<ODataSyncProgress %@ %@ %lu of %lu>", _remote.identifier, phases[(NSUInteger)_phase],
                                    (unsigned long)_completed, (unsigned long)_total];
}

@end
