// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Merged attributes exchanged as deltas (docs/offline-sync.md, 14): the
// device's half. Each object with an entry to merge (one changed here, one
// a download brought) has its merged attributes exchanged in one
// MergeAttributes call, then a second for what the remote lacks.

#import "ODSInternal.h"

// Items to an action call at most.
static const NSUInteger ODSMergeBatch = 100;
// Exchanges an object's merged attributes may fail before its entry is set
// aside (an issue: the app retries or discards it).
static const NSInteger ODSMergeAttempts = 3;

static NSString *ODSBase64(NSData *data)
{
  return [data base64EncodedStringWithOptions:0] ?: @"";
}

static NSData *ODSFromBase64(id text)
{
  return [text isKindOfClass:[NSString class]] ? [[NSData alloc] initWithBase64EncodedString:text options:0] : nil;
}

// One merged attribute of one object, as it is exchanged.
@interface ODSMergeSlot : NSObject
@property (nonatomic, strong) NSManagedObject *entry;
@property (nonatomic, strong) NSManagedObject *object;
@property (nonatomic, strong) NSAttributeDescription *attribute;
@property (nonatomic, strong) id<ODataSyncMerging> merger;
@property (nonatomic, copy) NSDictionary *item;  // EntitySet, Key, Property
@property (nonatomic) BOOL failed;
@property (nonatomic, copy) NSString *message;    // why, when failed
@property (nonatomic) BOOL changed;               // an answer changed it here
@end

@implementation ODSMergeSlot
@end

@implementation ODSMergeExchange {
  ODataSyncEngine *_engine;
  ODataSyncRemote *_remote;
  ODSModel *_model;
  ODSCodec *_codec;
}

- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote
{
  self = [super init];
  if (!self) return nil;
  _engine = engine;
  _remote = remote;
  _model = engine.model;
  _codec = engine.codec;
  return self;
}

// The key as the wire has it: wire names, JSON values.
- (NSDictionary *)keyJSONOf:(NSDictionary *)key entity:(NSEntityDescription *)root
{
  NSMutableDictionary *json = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [_model keyAttributesOf:root]) {
    id value = key[attribute.name];
    if (!value) continue;
    json[[_codec.mapper propertyForAttribute:attribute]] = [_codec.mapper.values JSONForCoreDataValue:value attribute:attribute];
  }
  return json;
}

// The slots of the entries: each merged attribute of each object still
// here with a merger registered. An entry whose object is gone is done.
- (NSArray<ODSMergeSlot *> *)slotsOf:(NSArray<NSManagedObject *> *)entries context:(NSManagedObjectContext *)context
{
  NSMutableArray *slots = [NSMutableArray array];
  for (NSManagedObject *entry in entries) {
    NSEntityDescription *root = _model.model.entitiesByName[[entry valueForKey:@"entityType"]];
    NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
    NSManagedObject *object = root && key ? [_codec objectOfEntity:root key:key inContext:context] : nil;
    if (!object) {
      [context deleteObject:entry];
      continue;
    }
    NSDictionary *keyJSON = [self keyJSONOf:key entity:root];
    NSString *set = [_codec.mapper entitySetForEntity:root];
    for (NSAttributeDescription *attribute in [_model mergedAttributesOf:object.entity]) {
      id<ODataSyncMerging> merger = [_engine mergerForName:[_model mergerNameOf:attribute]];
      // No merger registered (an app that has not set one): left as it is.
      if (!merger) continue;
      ODSMergeSlot *slot = [[ODSMergeSlot alloc] init];
      slot.entry = entry;
      slot.object = object;
      slot.attribute = attribute;
      slot.merger = merger;
      slot.item = @{ @"EntitySet": set ?: @"", @"Key": keyJSON, @"Property": [_codec.mapper propertyForAttribute:attribute] };
      [slots addObject:slot];
    }
  }
  return slots;
}

// MergeAttributes(Replica, Items): the answer's items, in order; nil and
// *unsupported when the remote has no such action (an older service).
- (NSArray *)call:(NSArray<NSDictionary *> *)items unsupported:(BOOL *)unsupported error:(NSError **)error
{
  NSURL *url = [NSURL URLWithString:@"MergeAttributes" relativeToURL:_remote.serviceRoot].absoluteURL;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"Replica": _engine.replicaID, @"Items": items } options:0 error:NULL];
  NSError *failure = nil;
  ODataHTTPResponse *response = [[_engine clientOf:_remote] sendRequest:request error:&failure];
  if (!response) {
    NSInteger status = [failure.userInfo[ODataErrorHTTPStatusKey] integerValue];
    if (unsupported) *unsupported = status == 404 || status == 405 || status == 501;
    if (error) *error = failure;
    return nil;
  }
  id json = [response JSONWithError:error];
  // An Edm.Untyped result, as itself or under value.
  NSDictionary *answer = [json isKindOfClass:[NSDictionary class]] && [json[@"value"] isKindOfClass:[NSDictionary class]] ? json[@"value"] : json;
  NSArray *answered = [answer isKindOfClass:[NSDictionary class]] ? answer[@"Items"] : nil;
  if (![answered isKindOfClass:[NSArray class]] || answered.count != items.count) {
    if (error) *error = ODSError(1, @"The remote's MergeAttributes answer is not one");
    return nil;
  }
  return answered;
}

// An answer applied: what the device lacked merged in, what all have seen
// collected. The remote's version after, for what it lacks (nil: failed).
- (NSData *)apply:(NSDictionary *)answer to:(ODSMergeSlot *)slot
{
  if (![answer isKindOfClass:[NSDictionary class]] || answer[@"Error"]) {
    slot.failed = YES;
    slot.message = [answer isKindOfClass:[NSDictionary class]] && [answer[@"Error"] isKindOfClass:[NSString class]] ? answer[@"Error"]
                                                                                                                    : @"No answer for it";
    return nil;
  }
  NSData *state = [slot.object valueForKey:slot.attribute.name];
  NSData *merged = state;
  NSError *error = nil;
  // Failed only where a merge was tried and gave nothing: a copy with no
  // state yet (a body not come, or none) answered nothing is not one.
  BOOL tried = NO;
  if ([answer[@"Reset"] boolValue]) {
    // Behind what the remote collected (docs/offline-sync.md, 14.4): its
    // state, with what this copy did since the horizon, and nothing older,
    // which every other copy has seen, and which is gone there.
    NSData *theirs = ODSFromBase64(answer[@"State"]), *horizon = ODSFromBase64(answer[@"Horizon"]);
    NSData *since = [slot.merger deltaOfState:state sinceVersion:horizon.length ? horizon : nil];
    tried = since.length > 0;
    merged = tried ? [slot.merger stateByMerging:since intoState:theirs error:&error] : theirs;
  } else {
    NSData *delta = ODSFromBase64(answer[@"Delta"]);
    tried = delta.length > 0;
    if (tried) merged = [slot.merger stateByMerging:delta intoState:state error:&error];
  }
  if (tried && !merged) {
    slot.failed = YES;
    slot.message = error.localizedDescription ?: @"What the remote sent does not merge";
    return nil;
  }
  NSData *seen = ODSFromBase64(answer[@"SeenByAll"]);
  if (seen.length) merged = [slot.merger stateByCollecting:merged seenBy:seen] ?: merged;
  if (!(merged == state || [merged isEqual:state])) {
    slot.changed = YES;
    [slot.object setValue:merged forKey:slot.attribute.name];
    if ([slot.merger respondsToSelector:@selector(mergedAttribute:ofObject:)]) [slot.merger mergedAttribute:slot.attribute ofObject:slot.object];
  }
  return ODSFromBase64(answer[@"Version"]) ?: [NSData data];
}

// One batch of entries (by ID) exchanged and saved: 1 done, 0 failed, -1
// the remote has no such action (an older one: merged attributes stay as
// they are, the rest syncs).
- (NSInteger)exchangeBatch:(NSArray<NSManagedObjectID *> *)ids context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSMutableArray *chunk = [NSMutableArray array];
  for (NSManagedObjectID *objectID in ids) {
    NSManagedObject *entry = [context existingObjectWithID:objectID error:NULL];
    if (entry) [chunk addObject:entry];
  }
  NSArray<ODSMergeSlot *> *slots = [self slotsOf:chunk context:context];
  if (!slots.count) return [context save:error] ? 1 : 0;
  // Down: what each has, for what it lacks (and the remote's version).
  NSMutableArray *items = [NSMutableArray array];
  for (ODSMergeSlot *slot in slots) {
    NSMutableDictionary *item = [slot.item mutableCopy];
    item[@"Version"] = ODSBase64([slot.merger versionOfState:[slot.object valueForKey:slot.attribute.name]]);
    [items addObject:item];
  }
  BOOL unsupported = NO;
  NSArray *answers = [self call:items unsupported:&unsupported error:error];
  if (!answers) {
    if (unsupported) {
      if (error) *error = nil;
      return [context save:error] ? -1 : 0;
    }
    [context save:NULL];
    return 0;
  }
  // Up: what the remote lacks, since its version.
  NSMutableArray *ups = [NSMutableArray array];
  NSMutableArray<ODSMergeSlot *> *upSlots = [NSMutableArray array];
  for (NSUInteger i = 0; i < slots.count; i++) {
    ODSMergeSlot *slot = slots[i];
    NSData *theirs = [self apply:answers[i] to:slot];
    if (!theirs) continue;
    NSData *state = [slot.object valueForKey:slot.attribute.name];
    NSData *delta = [slot.merger deltaOfState:state sinceVersion:theirs.length ? theirs : nil];
    // Nothing it lacks, and nothing changed here: done. Changed, it is told
    // what this copy has now, for what it collects (what a copy says it
    // has, never what it was sent).
    if (!delta.length && !slot.changed) continue;
    NSMutableDictionary *item = [slot.item mutableCopy];
    item[@"Version"] = ODSBase64([slot.merger versionOfState:state]);
    if (delta.length) item[@"Delta"] = ODSBase64(delta);
    [ups addObject:item];
    [upSlots addObject:slot];
  }
  if (ups.count) {
    NSArray *upAnswers = [self call:ups unsupported:NULL error:error];
    if (!upAnswers) {
      [context save:NULL];
      return 0;
    }
    for (NSUInteger i = 0; i < upSlots.count; i++) [self apply:upAnswers[i] to:upSlots[i]];
  }
  // Done, but those that failed: again at the next sync, and set aside
  // after a few (one that never merges holds up nothing else).
  NSMutableDictionary<NSManagedObjectID *, ODSMergeSlot *> *failed = [NSMutableDictionary dictionary];
  for (ODSMergeSlot *slot in slots) {
    if (slot.failed) failed[slot.entry.objectID] = slot;
  }
  for (NSManagedObject *entry in chunk) {
    if (entry.isDeleted) continue;
    ODSMergeSlot *slot = failed[entry.objectID];
    if (slot) {
      NSInteger attempts = [[entry valueForKey:@"attempts"] integerValue] + 1;
      [entry setValue:@(attempts) forKey:@"attempts"];
      if (attempts >= ODSMergeAttempts) {
        [entry setValue:@YES forKey:@"setAside"];
        [entry setValue:@422 forKey:@"status"];
        [entry setValue:slot.message forKey:@"message"];
        [_engine setAside:[[ODataSyncIssue alloc] initWithEntry:entry objectID:slot.object.objectID]];
      }
    } else {
      [context deleteObject:entry];
      [_engine count:@"merged" by:1];
    }
  }
  return [context save:error] ? 1 : 0;
}

- (BOOL)exchangeIn:(NSManagedObjectContext *)context error:(NSError **)error
{
  // By ID: each batch saved and let go of (the context emptied), so that
  // as many objects as there are go in the memory of a batch.
  NSArray<NSManagedObjectID *> *ids = [[_engine.store mergeEntriesFor:_remote inContext:context] valueForKey:@"objectID"];
  for (NSUInteger start = 0; start < ids.count; start += ODSMergeBatch) {
    NSInteger done;
    NSError *failure = nil;
    @autoreleasepool {
      NSError *e = nil;
      done = [self exchangeBatch:[ids subarrayWithRange:NSMakeRange(start, MIN(ODSMergeBatch, ids.count - start))] context:context error:&e];
      failure = e;
      [context reset];
    }
    if (done < 0) return YES;
    if (!done) {
      if (error) *error = failure;
      return NO;
    }
  }
  return YES;
}

@end
