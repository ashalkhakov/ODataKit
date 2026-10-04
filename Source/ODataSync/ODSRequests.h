// Every request ODataSync sends a remote: the one place they are made.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// URLs under the remote's service root (and the links it gives), the
// headers every request has, a set's reads (whole, keys only, some keys),
// an object's read, and the changes: an upsert (PATCH) or a deletion, with
// their conditions (If-Match, If-None-Match), alone or in a $batch.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class ODataSyncEngine, ODataSyncRemote;

NS_ASSUME_NONNULL_BEGIN

@interface ODSRequests : NSObject
- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataSyncRemote *remote;

// A URL under the remote's service root, from a path and query not yet
// percent-encoded; a link the remote gave (a next or delta link), resolved
// against the URL it came with. Each names the schema version this side
// speaks ($schemaversion), when its model has one.
- (NSURL *)URLOf:(NSString *)relative;
- (NSURL *)URLOfLink:(NSString *)link relativeTo:(nullable NSURL *)base;
// What every request has: to a peer, this replica.
- (NSDictionary<NSString *, NSString *> *)headers;

// A set's rows (its to-ones' keys expanded), as the remote's filter for it
// has them, or only their keys; those of these keys; an object's row.
// Typed queries, written by ODataKit; nil and the error for a remote's
// filter that does not parse, or a name that cannot be written.
- (nullable NSURL *)URLOfSet:(NSEntityDescription *)entity keysOnly:(BOOL)keysOnly error:(NSError **)error;
- (nullable NSURL *)URLOfSet:(NSEntityDescription *)entity keys:(NSArray<NSDictionary *> *)keys error:(NSError **)error;
- (nullable NSURL *)URLOfObject:(NSEntityDescription *)entity key:(NSDictionary *)key error:(NSError **)error;
// A GET of JSON, with the headers every request has.
- (NSMutableURLRequest *)GET:(NSURL *)url prefer:(nullable NSString *)prefer;

// A change as a request {method, url, headers, body}: checked, it goes
// only over the version agreed on (If-Match of its ETag; a new one,
// If-None-Match: *; a version never agreed on, an ETag no remote gives,
// so that it meets the remote's instead of overwriting it unseen).
- (NSDictionary *)upsertOf:(NSManagedObject *)object entity:(NSEntityDescription *)root key:(NSDictionary *)key
                properties:(nullable NSSet<NSString *> *)properties insert:(BOOL)insert checked:(BOOL)checked etag:(nullable NSString *)etag;
// A deletion, with its history for the remote's tombstone.
- (NSDictionary *)deletionOf:(NSEntityDescription *)root key:(NSDictionary *)key checked:(BOOL)checked etag:(nullable NSString *)etag
                    versions:(nullable NSDictionary<NSString *, NSNumber *> *)versions;
// Such a request to send alone; several as one $batch, each standing or
// falling alone (ids 1, 2, ...).
- (NSMutableURLRequest *)HTTPRequestOf:(NSDictionary *)request;
- (NSMutableURLRequest *)batchOf:(NSArray<NSDictionary *> *)requests;
@end

NS_ASSUME_NONNULL_END
