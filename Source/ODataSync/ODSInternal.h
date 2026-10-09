// What ODataSync's files share: the engine's parts (the model, the codec,
// the requests, the store, the clocks, the recorder), and the two halves.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "ODataSyncEngine.h"
#import <ODataKit/ODataPropertyMapper.h>
#import <ODataKit/ODataValue.h>
#import <ODataKit/ODataExpression.h>
#import <ODataKit/ODataError.h>
#import <ODataIncrementalStore/ODataClient.h>
#import <ODataIncrementalStore/ODataConfiguration.h>
#import <OTelKit/OTTrace.h>
#import "ODSModel.h"
#import "ODSStore.h"
#import "ODSClock.h"
#import "ODSRequests.h"
#import "ODSRecorder.h"

NS_ASSUME_NONNULL_BEGIN

// Version vectors (ODSVersions.m): replica -> the count of its latest
// change a version includes.
typedef NS_ENUM(NSInteger, ODSOrder) {
  ODSOrderSame,        // the same version
  ODSOrderBefore,      // the first is included in the second (older)
  ODSOrderAfter,       // the first includes the second (newer)
  ODSOrderConcurrent,  // neither: made without knowing of each other
};
FOUNDATION_EXPORT NSString * const ODSServiceReplica;  // @"svc"
// A DELETE's header that carries the deletion's vector; and the code of a
// 409's error detail whose message is a tombstone's vector.
FOUNDATION_EXPORT NSString * const ODataSyncVersionsHeader;  // @"ODataSync-Versions"
FOUNDATION_EXPORT NSString * const ODSDeletedCode;           // @"ODataSync.deleted"
// What a client's DELETEs sent in a context ("Entity keyText" -> the
// deletion's vector), for their tombstones.
FOUNDATION_EXPORT NSString * const ODSDeletionsKey;
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *_Nullable ODSSentDeletions(NSManagedObjectContext *context);
FOUNDATION_EXPORT void ODSNoteSentDeletion(NSManagedObjectContext *context, NSString *name, NSString *versions);
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *ODSVersionsFromText(NSString *_Nullable text);
FOUNDATION_EXPORT NSString *ODSTextOfVersions(NSDictionary<NSString *, NSNumber *> *_Nullable versions);
FOUNDATION_EXPORT ODSOrder ODSCompareVersions(NSDictionary<NSString *, NSNumber *> *_Nullable a, NSDictionary<NSString *, NSNumber *> *_Nullable b);
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *ODSMergeVersions(NSDictionary<NSString *, NSNumber *> *_Nullable a,
                                                                       NSDictionary<NSString *, NSNumber *> *_Nullable b);
// A replica ID (a UUID) as a vector names it: 8 characters.
FOUNDATION_EXPORT NSString *ODSShortReplica(NSString *replicaID);

FOUNDATION_EXPORT NSError *ODSError(NSInteger code, NSString *message);
FOUNDATION_EXPORT NSData *ODSArchive(id _Nullable plist);
FOUNDATION_EXPORT id _Nullable ODSUnarchive(NSData *_Nullable data);

// How the engine's objects are written and read as OData: by the mapper's
// names, the value coder's values. What an entity is (its keys, synced
// properties, directions) is the model's (ODSModel).
@interface ODSCodec : NSObject
- (instancetype)initWithModel:(ODSModel *)model;
@property (nonatomic, readonly) ODSModel *model;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;  // the model's
// Keys, by Core Data attribute name.
- (NSDictionary *)keyOfObject:(NSManagedObject *)object;
- (nullable NSDictionary *)keyFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity;
- (nullable NSDictionary *)keyFromValues:(NSDictionary *)values entity:(NSEntityDescription *)entity;
// From an @odata.id (Products(5), or a whole URL): the entity it names
// (of those given) and its key.
- (nullable NSDictionary *)keyFromID:(NSString *)identifier entity:(NSEntityDescription *_Nullable *_Nullable)entity
                          among:(NSArray<NSEntityDescription *> *)entities;
// A key as text, the same however it was made: what the outbox and the
// shadows find an object's entry by (with its root entity's name).
- (NSString *)keyTextOf:(NSDictionary *)key entity:(NSEntityDescription *)entity;
// Set(key), not percent-encoded.
- (NSString *)pathOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key;
// The local object of an entity (or one derived from it) with this key.
- (nullable NSManagedObject *)objectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key
                                   inContext:(NSManagedObjectContext *)context;
// An entity's JSON applied to an object: its attributes; its to-ones, by
// the related keys expanded in it (Nav: {key}), to the local objects
// those name (nil when none is local: the next download may bring it).
- (void)applyJSON:(NSDictionary *)json toObject:(NSManagedObject *)object;
// A body for a PATCH: these properties (nil: all synced), attributes as
// JSON and to-ones as Nav@odata.bind (null to unlink).
- (NSDictionary *)JSONOfObject:(NSManagedObject *)object properties:(nullable NSSet<NSString *> *)properties;
// Values by Core Data property name (an attribute's value, a to-one's
// related key, NSNull for none): an object's; a row's (what it has); and
// back onto an object (what they name).
- (NSDictionary *)valuesOfObject:(NSManagedObject *)object;
- (NSDictionary *)valuesFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity;
- (void)applyValues:(NSDictionary *)values toObject:(NSManagedObject *)object;
// An object as a row: what a shadow keeps of a version (wire names, its
// to-ones' keys expanded).
- (NSDictionary *)rowOfObject:(NSManagedObject *)object;
// An object's version vector, a row's (by the mapper's property name);
// empty when it keeps none.
- (NSDictionary<NSString *, NSNumber *> *)versionsOfObject:(nullable NSManagedObject *)object;
- (NSDictionary<NSString *, NSNumber *> *)versionsOfRow:(nullable NSDictionary *)row entity:(NSEntityDescription *)entity;
@end

// The properties whose values differ (missing is NSNull).
FOUNDATION_EXPORT NSSet<NSString *> *ODSChangedNames(NSDictionary *_Nullable before, NSDictionary *_Nullable after);

@interface ODataSyncEngine ()
// The engine of a service's store (ODataSyncService): its replica is svc.
- (instancetype)initServiceWithCoordinator:(NSPersistentStoreCoordinator *)coordinator;
@property (nonatomic, readonly, getter=isService) BOOL service;
// Its parts.
@property (nonatomic, readonly) ODSModel *model;
@property (nonatomic, readonly) ODSCodec *codec;
@property (nonatomic, readonly) ODSStore *store;
@property (nonatomic, readonly) ODSClock *clock;
@property (nonatomic, readonly) OTTracer *tracer;
// A client of the remote: its configuration, at 4.01, its transport.
- (ODataClient *)clientOf:(ODataSyncRemote *)remote;
// The remote added with this identifier.
- (nullable ODataSyncRemote *)remoteWithIdentifier:(NSString *)identifier;
// Deletions older than tombstoneRetention, forgotten.
- (void)pruneTombstones;
// What a sync did, as it goes: downloaded, removed, uploaded, refused, conflicts.
@property (nonatomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *tally;
- (void)count:(NSString *)what by:(NSUInteger)n;
// A phase with remote begun (total: what waits, 0: not known), the one
// before told as it ended; its progress told as it goes: n more done, or
// done of the total (each item settled for this sync, however: taken,
// refused, gone, failed and left for the next).
- (void)beginPhase:(ODataSyncPhase)phase remote:(ODataSyncRemote *)remote total:(NSUInteger)total;
- (void)progressed:(NSUInteger)n;
- (void)phaseDone:(NSUInteger)done;
- (void)setAside:(ODataSyncIssue *)issue;
- (void)ignoredLocalChangeTo:(NSManagedObjectID *)objectID;
- (nullable id<ODataSyncResolving>)resolverForEntityName:(NSString *)entityName;
@end

// Conflicts (ODSConflicts.m).
@interface ODataSyncEngine (ODSConflicts)
// A both object changed here (its outbox entry) and at the remote: its
// remote version (nil: deleted there) and ETag. The resolver's resolution
// applied, the outbox entry and the shadow with it.
- (void)settleConflictOf:(NSEntityDescription *)root key:(NSDictionary *)key entry:(NSManagedObject *)entry
               remoteRow:(nullable NSDictionary *)row etag:(nullable NSString *)etag remote:(ODataSyncRemote *)remote
                 context:(NSManagedObjectContext *)context;
// The same, of a remote that deleted it (row nil) and said with what
// history (its tombstone's vector).
- (void)settleConflictOf:(NSEntityDescription *)root key:(NSDictionary *)key entry:(NSManagedObject *)entry
               remoteRow:(nullable NSDictionary *)row remoteVersions:(nullable NSDictionary *)deletedVersions etag:(nullable NSString *)etag
                  remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context;
// The version both agree on now: the shadow's ETag and row (nil: none, the
// shadow gone).
- (void)agreeOn:(nullable NSDictionary *)row etag:(nullable NSString *)etag of:(NSEntityDescription *)root keyText:(NSString *)keyText
         remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context;
- (id<ODataSyncResolving>)resolverFor:(NSEntityDescription *)root remote:(ODataSyncRemote *)remote;
// A peer's row of an object this side has a newer version of (by the
// stamps), with no change pending for it: YES when so, and then the row is
// not applied: agreed on as the peer's, and this side's sent to it.
- (BOOL)keepNewerThan:(NSDictionary *)row etag:(nullable NSString *)etag of:(NSEntityDescription *)root key:(NSDictionary *)key
               remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context;
// The same, when the vectors said this side's is newer.
- (BOOL)keepNewerThan:(NSDictionary *)row etag:(nullable NSString *)etag of:(NSEntityDescription *)root key:(NSDictionary *)key
               remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context versions:(BOOL)known;
@end

@interface ODataSyncConflict ()
- (instancetype)initWithEntity:(NSEntityDescription *)entity key:(NSDictionary *)key base:(nullable NSDictionary *)base
                         local:(nullable NSDictionary *)local remote:(nullable NSDictionary *)remote
                  localChanges:(NSSet *)localChanges remoteChanges:(NSSet *)remoteChanges withPeer:(BOOL)withPeer;
@end

@interface ODataSyncChange ()
- (instancetype)initWithEntry:(NSManagedObject *)entry objectID:(nullable NSManagedObjectID *)objectID;
@property (nonatomic, readonly, strong) NSManagedObjectID *entryID;
@end

@interface ODataSyncProgress ()
- (instancetype)initWithRemote:(ODataSyncRemote *)remote phase:(ODataSyncPhase)phase completed:(NSUInteger)completed total:(NSUInteger)total;
@end

@interface ODataSyncResult ()
- (instancetype)initWithTally:(NSDictionary<NSString *, NSNumber *> *)tally;
@end

// Down: the remote's changes into the local store.
@interface ODSDownloader : NSObject
- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote;
- (BOOL)download:(NSError **)error;
- (BOOL)reconcile:(NSError **)error;
// One object's row at the remote, its to-ones' keys expanded; nil with
// *status 404 when it has none (0: no answer, the error).
- (nullable NSDictionary *)rowOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key status:(NSInteger *)status
                                 error:(NSError **)error;
// One object read again from the remote and applied, and agreed on;
// deleted locally when the remote has none. NO, with the error, when the
// remote did not answer.
- (BOOL)refreshObjectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key
                      context:(NSManagedObjectContext *)context error:(NSError **)error;
@end

// Merged attributes exchanged as deltas (ODSMerge.m; docs/offline-sync.md,
// 14): the objects with a merge entry, after a batch.
@interface ODSMergeExchange : NSObject
- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote;
// In the uploader's context (written as the remote's); NO, with the error,
// when the remote did not answer. A remote that has no MergeAttributes
// leaves merged attributes as they are.
- (BOOL)exchangeIn:(NSManagedObjectContext *)context error:(NSError **)error;
@end

// Up: history into the outbox, and the outbox to the remote.
@interface ODSUploader : NSObject
- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote;
// History into the outbox only: before a download, so what the device
// changed and has not sent is known (not swept, a conflict when the remote
// changed it too).
- (BOOL)collect:(NSError **)error;
- (BOOL)upload:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
