// ODataSyncMerging — merged attributes (docs/offline-sync.md, 14).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A Binary attribute whose value is a mergeable state (a CRDT: states merge
// in any order to the same result) is declared so in its userInfo, naming
// a merger the app registers on the engine, on the device and at the
// service alike:
//
//   bodyText   Binary   ODataSync.merge   TopoText
//
//   [engine setMerger:[[TTSyncMerger alloc] init] forName:@"TopoText"];
//
// ODataSync then moves deltas, not states: a row goes up and comes down
// without its merged attributes, and they are exchanged after, in one
// MergeAttributes call (an action import the service answers). A merged
// attribute never makes a conflict. The service keeps what each replica
// has seen, so what all have seen can be collected (a state's tombstones).
// Versions and deltas are the merger's bytes; ODataSync only moves them.
//
// For collecting, a version never forgets: a collected state's version
// has still seen what was collected (a version vector keeps its counters),
// and merging a delta that brings it back adds nothing. And equal versions
// are equal bytes from -versionMeeting:andVersion:, by which ODataSync
// tells whether one version has seen all another has.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

// userInfo key on a Binary attribute: the merger's name.
FOUNDATION_EXPORT NSString * const ODataSyncMergeKey;   // @"ODataSync.merge"

@protocol ODataSyncMerging <NSObject>
// What a state has seen (nil: nothing).
- (NSData *)versionOfState:(nullable NSData *)state;
// What a copy at version lacks of state (version nil: all of it).
- (NSData *)deltaOfState:(nullable NSData *)state sinceVersion:(nullable NSData *)version;
// A delta (or a whole state) merged in; nil and the error for one that does
// not merge (not the merger's, or made for a copy that had seen more).
- (nullable NSData *)stateByMerging:(NSData *)delta intoState:(nullable NSData *)state error:(NSError **)error;
// What both versions have seen; equal versions as equal bytes.
- (NSData *)versionMeeting:(NSData *)version andVersion:(NSData *)other;
// State without what every copy has seen deleted (version: what all have
// seen); state itself when there is nothing to collect.
- (nullable NSData *)stateByCollecting:(nullable NSData *)state seenBy:(NSData *)version;
@optional
// After a merge changed the attribute's value on object (on the device, the
// exchange; at the service, a delta or a state merged in), in its context:
// what is derived from it set again (a plain-text copy, a title). What it
// sets is written as the merge is (on the device, as the remote's).
- (void)mergedAttribute:(NSAttributeDescription *)attribute ofObject:(NSManagedObject *)object;
@end

NS_ASSUME_NONNULL_END
