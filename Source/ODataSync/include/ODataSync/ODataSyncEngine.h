// ODataSyncEngine — a Core Data store that works offline, kept in sync
// with an OData service (docs/offline-sync.md).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The app works against one local store, as any Core Data app; the engine
// brings down what the service owns and sends up what the app collects:
//
//   NSManagedObjectModel *model = ...;      // entities say ODataSync.direction
//   [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
//   ... a coordinator; its SQLite store with NSPersistentHistoryTrackingKey ...
//   ODataSyncEngine *sync = [[ODataSyncEngine alloc] initWithCoordinator:coordinator];
//   [sync addRemote:[ODataSyncRemote remoteWithServiceRoot:url]];
//   NSError *error = nil;
//   [sync syncWithError:&error];            // off the main thread
//
// Each entity says which way it goes, in its userInfo:
//
//   ODataSync.direction  down: the service owns it; the app reads it.
//                        up: the app owns it (a UUID key it makes); sent
//                        by upsert, so sending it again is harmless.
//                        both: either changes it; a change made on both
//                        sides since they last agreed is a conflict,
//                        settled by a resolver (below).
//                        Absent: local only.
//   ODataSync.conflicts  of a both entity: remote (the default), local,
//                        lastWriter or merge; a resolver set in code
//                        (-setResolver:forEntityName:) comes first.
//   ODataSync.versions   the String attribute that keeps what the
//                        object's version has seen: a version vector
//                        (docs/offline-sync.md, 12), which the engine
//                        keeps, and the service and peers store as any
//                        property. Two versions met are then known for
//                        the same, older, newer, or a conflict (made
//                        without knowing of each other), not guessed.
//   ODataSync.modified   the String attribute last writer wins orders by:
//                        the engine stamps it, on every save of the
//                        object's changes but its own, with a hybrid
//                        logical clock (wall time, a counter, this store),
//                        which the service keeps like any attribute. A
//                        change made at the service should stamp it too.
//
// Keys and entity sets are the mapper's (OData.key, OData.entitySet). Keep
// an up or both entity's key attributes in history on deletion
// (preservesValueInHistoryOnDeletion): a deletion is sent by its key.
//
// Devices sync with each other too: one serves its store
// (ODataSyncPeerServer.h), another adds it as a peer remote. What came
// from one remote is passed on to the others (a peer's work to the
// service, the service's to a peer), but not back to where it came from.

#pragma once
#import <Foundation/Foundation.h>
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataTransport.h>

@class ODataConfiguration, ODataSyncEngine;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataSyncDirectionKey;    // @"ODataSync.direction"
FOUNDATION_EXPORT NSString * const ODataSyncConflictsKey;    // @"ODataSync.conflicts"
FOUNDATION_EXPORT NSString * const ODataSyncModifiedKey;     // @"ODataSync.modified"
FOUNDATION_EXPORT NSString * const ODataSyncVersionsKey;     // @"ODataSync.versions"
FOUNDATION_EXPORT NSString * const ODataSyncErrorDomain;
// The transaction author of what the engine writes: what came down from a
// remote (ODataSyncDownAuthorPrefix and the remote's identifier), and its
// own bookkeeping. What came from a remote is not sent back to it, and is
// passed on to others only to or from a peer; bookkeeping is never sent.
FOUNDATION_EXPORT NSString * const ODataSyncDownAuthorPrefix;  // @"ODataSync.down."
FOUNDATION_EXPORT NSString * const ODataSyncBookkeepingAuthor; // @"ODataSync.bookkeeping"
// The request header a device names its replica in, to a peer: what the
// peer is sent is written as coming from that replica.
FOUNDATION_EXPORT NSString * const ODataSyncReplicaHeader;     // @"ODataSync-Replica"
// The model configuration +addBookkeepingToModel:configuration: adds for
// a peer server: the synced entities (no store need use it).
FOUNDATION_EXPORT NSString * const ODataSyncPeerConfiguration; // @"ODataSync.peer"

typedef NS_ENUM(NSInteger, ODataSyncDirection) {
  ODataSyncDirectionNone = 0,
  ODataSyncDirectionDown,
  ODataSyncDirectionUp,
  ODataSyncDirectionBoth,
};

// A both entity's object changed on the device and at the service since
// they last agreed: whose version stands.
typedef NS_ENUM(NSInteger, ODataSyncConflictPolicy) {
  ODataSyncPolicyRemoteWins = 0,  // the service's: the device's change is dropped
  ODataSyncPolicyLocalWins,       // the device's: sent again over the service's
};

// A service to sync with, or a peer: another device's store, served by
// its ODataSyncPeerServer.
@interface ODataSyncRemote : NSObject
+ (instancetype)remoteWithServiceRoot:(NSURL *)serviceRoot;
// A peer, at the service root its peer server gives (which ends in its
// replica ID). A peer is no authority: what it reads deletes nothing
// here; from it come changes of up and both entities, and of down
// entities what is missing here or newer by their version counter (an
// OData.etag integer). Up entities go both ways with it, conflicts and
// all. Deletions it sends are passed on.
+ (instancetype)peerWithServiceRoot:(NSURL *)serviceRoot;
- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
@property (nonatomic, readonly, getter=isPeer) BOOL peer;
// What its state is kept under, and what came from it is written as.
// Default: the service root; a peer's replica ID.
@property (nonatomic, copy) NSString *identifier;
// Credentials, headers, timeouts, as ODataIncrementalStore takes them.
@property (nonatomic, strong) ODataConfiguration *configuration;
// nil: the network. An ODataService (in the process), or a transport of
// the app's own.
@property (nonatomic, strong, nullable) id<ODataTransport> transport;
// Of a down or both entity (by entity name): only its rows that match, as
// $filter text (Region eq 'North'). A set whose filter changes is read
// again.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *filters;
// How many changes go in one $batch. Default: 50.
@property (nonatomic) NSUInteger batchSize;
@end

typedef NS_ENUM(NSInteger, ODataSyncOperation) {
  ODataSyncOperationInsert = 1,
  ODataSyncOperationUpdate,
  ODataSyncOperationDelete,
  ODataSyncOperationRefresh,  // the remote's version read again (a conflict discarded)
};

// A both object changed here and at the remote since the version both last
// agreed on. Values by Core Data property name: an attribute's value, a
// to-one's related key (by its attributes' names), NSNull for none.
@interface ODataSyncConflict : NSObject
@property (nonatomic, readonly) NSEntityDescription *entity;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *key;
// The version both last agreed on; nil when not known (an object made on
// both sides, or before the engine kept versions).
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *base;
// This side's, and the remote's; nil when deleted there.
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *local;
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *remote;
// What each side changed since the base (every property when there is none).
@property (nonatomic, readonly, copy) NSSet<NSString *> *localChanges;
@property (nonatomic, readonly, copy) NSSet<NSString *> *remoteChanges;
// The remote is a peer: no authority, and it settles the same conflict
// the other way round when it syncs with this side. A rule must choose the
// same version whichever side asks (the built-in ones are made so: with a
// peer, the remote's or this side's becomes last writer wins).
@property (nonatomic, readonly) BOOL withPeer;
@end

typedef NS_ENUM(NSInteger, ODataSyncResolutionKind) {
  ODataSyncTakeRemote,  // the remote's version here; this side's change dropped
  ODataSyncKeepLocal,   // this side's version sent over the remote's
  ODataSyncMerge,       // these values here, and sent
  ODataSyncDefer,       // set aside for the user (an issue, status 409)
};

@interface ODataSyncResolution : NSObject
+ (instancetype)takeRemote;
+ (instancetype)keepLocal;
// The values to have (by property name, as a conflict has them); the
// properties not named keep this side's.
+ (instancetype)mergedValues:(NSDictionary<NSString *, id> *)values;
+ (instancetype)defer;
@property (nonatomic, readonly) ODataSyncResolutionKind kind;
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *values;
@end

// How conflicts are settled: given one, the resolution. On the engine's
// thread, during a sync.
@protocol ODataSyncResolving <NSObject>
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict;
@end

// The remote's version stands.
@interface ODataSyncRemoteWins : NSObject <ODataSyncResolving>
@end

// This side's version stands.
@interface ODataSyncLocalWins : NSObject <ODataSyncResolving>
@end

// The version changed last stands, by the ODataSync.modified stamps (a
// hybrid logical clock's, which order changes across devices whatever
// their clocks say); a tie, or a side without one, goes to the remote, or
// with a peer to the version whose values sort last.
@interface ODataSyncLastWriterWins : NSObject <ODataSyncResolving>
@end

// Three-way, property by property: what only one side changed is taken
// from it; what both changed to different values, the fallback decides
// (as it would the whole object). A delete on either side, or no base, is
// the fallback's.
@interface ODataSyncMergeFields : NSObject <ODataSyncResolving>
- (instancetype)initWithFallback:(id<ODataSyncResolving>)fallback NS_DESIGNATED_INITIALIZER;
// Falling back to RemoteWins.
- (instancetype)init;
@property (nonatomic, readonly) id<ODataSyncResolving> fallback;
@end

// A change waiting for a remote to take it (-pendingChanges).
@interface ODataSyncChange : NSObject
@property (nonatomic, readonly, copy) NSString *remoteIdentifier;
@property (nonatomic, readonly, copy) NSString *entityName;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *key;   // by Core Data attribute name
@property (nonatomic, readonly) ODataSyncOperation operation;
// The properties an update sends; nil: all of them (an insert).
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *properties;
// How many times it was sent (none taken yet).
@property (nonatomic, readonly) NSInteger attempts;
// The object, while it exists.
@property (nonatomic, readonly, strong, nullable) NSManagedObjectID *objectID;
@end

// A change the service refused (400, 403, 409, 422...), or a conflict
// deferred (409): it stays in the outbox, set aside, until the app retries
// or discards it.
@interface ODataSyncIssue : ODataSyncChange
@property (nonatomic, readonly) NSInteger status;
// The service's own words: its OData error's message.
@property (nonatomic, readonly, copy) NSString *message;
@end

// What one sync did, for the app to say.
@interface ODataSyncResult : NSObject
@property (nonatomic, readonly) NSUInteger downloaded;  // objects inserted or changed from remotes
@property (nonatomic, readonly) NSUInteger removed;     // objects deleted because remotes did
@property (nonatomic, readonly) NSUInteger uploaded;    // changes remotes took
@property (nonatomic, readonly) NSUInteger refused;     // changes set aside (issues)
@property (nonatomic, readonly) NSUInteger conflicts;   // settled by the policy
@end

@protocol ODataSyncDelegate <NSObject>
@optional
// A change set aside; its issue says why. On the engine's thread.
- (void)syncEngine:(ODataSyncEngine *)engine didSetAside:(ODataSyncIssue *)issue;
// A local change to a down entity, which is not sent.
- (void)syncEngine:(ODataSyncEngine *)engine ignoredLocalChangeToObject:(NSManagedObjectID *)objectID;
@end

@interface ODataSyncEngine : NSObject

// The engine's own entities, added to the model before a coordinator uses
// it, in the configuration the synced entities' store has (nil: the
// default one); and ODataSyncPeerConfiguration, listing the synced
// entities, which a peer server serves.
+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(nullable NSString *)configuration;

// The coordinator's store (the one with the synced entities) must keep
// persistent history (NSPersistentHistoryTrackingKey).
- (instancetype)initWithCoordinator:(NSPersistentStoreCoordinator *)coordinator NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *coordinator;
@property (nonatomic, readonly, copy) NSArray<ODataSyncRemote *> *remotes;
- (void)addRemote:(ODataSyncRemote *)remote;
// No longer synced with (a peer gone): what it was sent is kept.
- (void)removeRemote:(ODataSyncRemote *)remote;
// How a both entity's conflicts are settled, when neither code nor its
// ODataSync.conflicts says: the resolver, else the policy.
@property (nonatomic) ODataSyncConflictPolicy conflictPolicy;
@property (nonatomic, strong, nullable) id<ODataSyncResolving> resolver;
- (void)setResolver:(nullable id<ODataSyncResolving>)resolver forEntityName:(NSString *)entityName;
// How long a deletion is remembered, so that a peer that has not heard of
// it cannot bring the object back (its insert refused, 410). Default: 30
// days; 0: for ever. A peer that comes back after longer may.
@property (nonatomic) NSTimeInterval tombstoneRetention;
// The version of the model's schema, named in every request
// ($schemaversion, OData 4.01's schema versioning; a service's $metadata
// says its own, Core.SchemaVersion), so that a service on a newer version
// can read what a device that has not updated yet sends (ODataService's
// upgradeBody). Default:
// the model's versionIdentifiers (Xcode's Core Data Model Identifier),
// sorted, joined by commas. When it changes (an app update, its store
// migrated), what remotes refused is sent again, in the new model's shape.
@property (nonatomic, copy, nullable) NSString *modelVersion;
// This store's replica ID: in its metadata, made the first time.
@property (nonatomic, readonly, copy) NSString *replicaID;
@property (nonatomic, weak, nullable) id<ODataSyncDelegate> delegate;

// Each remote in turn: what changed there brought down, then what changed
// here sent up. Synchronous: call it off the main thread. NO, with the
// error, when a remote cannot be reached or refuses as a whole (401); what
// was done until then is kept, and the next sync goes on from there. One
// at a time: a call made while one runs waits for it.
- (BOOL)syncWithError:(NSError **)error;
// The same, on a thread of its own; the action gets the result, or the
// error, on the main thread:
//   - (void)syncDidFinish:(ODataSyncResult *)result error:(NSError *)error;
- (void)syncWithTarget:(id)target action:(SEL)action;
@property (nonatomic, readonly, strong, nullable) ODataSyncResult *lastResult;

// The halves, for one remote.
- (BOOL)downloadFromRemote:(ODataSyncRemote *)remote error:(NSError **)error;
- (BOOL)uploadToRemote:(ODataSyncRemote *)remote error:(NSError **)error;
// Each scoped set's keys read again, and compared: local rows the remote
// no longer gives deleted, rows it gives that are missing read
// (docs/offline-sync.md, 4.1). After a change of user, or now and then.
- (BOOL)reconcileWithRemote:(ODataSyncRemote *)remote error:(NSError **)error;
// This device's peer token (docs/peer-sync.md, 3.1), from a remote that
// issues them (a service whose ODataSyncService has peerTokens), for the
// device signed in there: PeerToken(Replica, Thumbprint), the thumbprint
// its identity's (ODataSyncPeerIdentity). The answer is what
// -[ODataSyncPeerTrust takePeerTokenAnswer:error:] takes: the token, and
// the service's keys and issuer that peers' tokens are checked with.
- (nullable NSDictionary<NSString *, id> *)peerTokenFromRemote:(ODataSyncRemote *)remote thumbprint:(NSString *)thumbprint
                                                         error:(NSError **)error;

// The changes set aside, oldest first.
- (NSArray<ODataSyncIssue *> *)issues;
// Every change not yet taken, for every remote, oldest first: what the
// app changed since (read from the store's history), and what waits from
// before; those set aside are issues. For a "3 changes to send".
- (NSArray<ODataSyncChange *> *)pendingChanges;
// Sent again at the next sync (after the app put the object right; a new
// change to the object does this too).
- (void)retryIssue:(ODataSyncIssue *)issue;
// Forgotten: never sent. The object stays as it is locally; a conflict's
// object is read again from the remote at the next sync.
- (void)discardIssue:(ODataSyncIssue *)issue;

@end

NS_ASSUME_NONNULL_END
