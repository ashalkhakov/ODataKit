// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataService.h"
#import <HTTPServerKit/HSAuthentication.h>
#import "ODataError.h"
#import "ODataValue.h"
#import "ODataSchema.h"
#import "ODataMetadataWriter.h"
#import <ODataKit/ODataPredicateBuilder.h>
#import "ODataOperationCatalog.h"
#import "ODataServiceBatch.h"
#import "ODataApply.h"
#import "ODataBatch.h"
#import "ODataTimeline.h"
#import "ODataCSDL.h"
#import <objc/runtime.h>
#import "ODataServiceInternal.h"
#import "OISPlan.h"

NSString * const ODataUserInfoETag = @"OData.etag";

// With the request id and trace a host gave the request (X-Request-ID,
// traceparent), so that what the service logs is found beside the host's
// lines of the request, and its trace.
void OISLog(HSLogLevel level, NSURLRequest *request, NSString *format, ...)
{
  HSLog *log = [HSLog sharedLog];
  if (![log logsLevel:level]) return;
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  [log log:level component:@"ODataService" message:message fields:[HSLog fieldsOfHeaders:request.allHTTPHeaderFields]];
}

// A request as the host sees it, for an authenticator.
static HSRequest *OISHostRequest(NSURLRequest *request)
{
  NSString *path = request.URL.path.length ? request.URL.path : @"/";
  NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES];
  NSString *target = components.percentEncodedPath.length ? components.percentEncodedPath : path;
  if (components.percentEncodedQuery) target = [NSString stringWithFormat:@"%@?%@", target, components.percentEncodedQuery];
  NSURL *url = [NSURL URLWithString:target relativeToURL:request.URL] ?: request.URL;
  return [[HSRequest alloc] initWithMethod:request.HTTPMethod ?: @"GET" URL:url.absoluteURL
                                   headers:request.allHTTPHeaderFields ?: @{} body:request.HTTPBody];
}

#pragma mark - Replies

@interface ODataReply ()
@property (nonatomic, strong, nullable) id target;
@property (nonatomic) SEL action;
@property (nonatomic, strong, nullable) NSManagedObjectContext *context;
@property (nonatomic, readwrite) BOOL deferred;
@property (nonatomic, readwrite) BOOL finished;
@property (nonatomic, readwrite, strong, nullable) id result;
@property (nonatomic, readwrite, strong, nullable) NSError *error;
@property (nonatomic) BOOL fired;
@property (nonatomic, readwrite, weak, nullable) ODataRequest *request;
@property (nonatomic) NSTimeInterval timeout;
@end

@implementation ODataReply

- (instancetype)initWithTarget:(id)target action:(SEL)action context:(NSManagedObjectContext *)context
{
  self = [super init];
  if (!self) return nil;
  _target = target;
  _action = action;
  _context = context;
  return self;
}

- (void)defer
{
  @synchronized (self) {
    if (self.deferred) return;
    self.deferred = YES;
  }
  if (self.timeout <= 0) return;
  // The timer keeps the reply: a handler that drops it must still be
  // answered for.
  ODataReply *reply = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeout * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
    [reply failWithError:ODataServiceError(504, @"The service took too long to answer")];
  });
}

// The first answer counts. A deferred one goes on in the request's context.
- (void)finishWithResult:(id)result error:(NSError *)error
{
  BOOL later;
  @synchronized (self) {
    if (self.finished) return;
    self.finished = YES;
    self.result = result;
    self.error = error;
    later = self.deferred;
  }
  if (later) {
    // In the request's context; a reply that has none (an authenticator
    // asked by a host) on a queue of its own.
    NSManagedObjectContext *context = self.context;
    if (context) {
      [context performBlock:^{
        [self fire];
      }];
    } else {
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self fire];
      });
    }
  }
}

- (void)finishWithResult:(id)result
{
  [self finishWithResult:result error:nil];
}

- (void)failWithError:(NSError *)error
{
  [self finishWithResult:nil error:error ?: ODataServiceError(500, @"The request failed")];
}

// The handler method has returned this.
- (void)returned:(id)value
{
  BOOL now;
  @synchronized (self) {
    now = !self.deferred;
    if (now && !self.finished) {
      self.finished = YES;
      self.result = value;
    }
  }
  if (now) [self fire];
}

- (void)fire
{
  id target;
  @synchronized (self) {
    if (self.fired) return;
    self.fired = YES;
    target = self.target;
    self.target = nil;
  }
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:self.action];
  send(target, self.action, self);
}

@end

#pragma mark - Requests

@interface ODataRequest ()
@property (nonatomic, readwrite, weak) ODataService *service;
@property (nonatomic, readwrite) NSURLRequest *URLRequest;
@property (nonatomic, readwrite, copy) NSString *method;
@property (nonatomic, readwrite, strong) ODataResourcePath *path;
@property (nonatomic, readwrite, strong) ODataQueryOptions *options;
@property (nonatomic, readwrite, strong) NSManagedObjectContext *context;
@property (nonatomic, readwrite, copy) NSString *version;
@property (nonatomic, readwrite, copy) NSDictionary *preferences;
@property (nonatomic, readwrite, strong) NSMutableDictionary *userInfo;
@property (nonatomic, readwrite, strong, nullable) NSFetchRequest *collectionFetchRequest;
@property (nonatomic, readwrite, strong, nullable) HSPrincipal *principal;
@property (nonatomic, strong) NSMutableArray<ODataMessage *> *pendingMessages;
@end

@implementation ODataRequest

- (void)addMessage:(NSString *)message code:(NSString *)code severity:(NSString *)severity target:(NSString *)target
{
  @synchronized (self) {
    if (!self.pendingMessages) self.pendingMessages = [NSMutableArray array];
    [self.pendingMessages addObject:[ODataMessage messageWithCode:code text:message severity:severity target:target]];
  }
}

- (NSArray *)messages
{
  @synchronized (self) {
    return [self.pendingMessages copy] ?: @[];
  }
}

// Whether Prefer: odata.include-annotations="..." takes this annotation
// (Part 1 section 8.2.8.4): a list of terms, NS.* and *, each excluded with
// a leading -, the most specific winning. None given: every one.
- (BOOL)includesAnnotation:(NSString *)term
{
  NSString *preference = self.preferences[@"odata.include-annotations"] ?: self.preferences[@"include-annotations"];
  if (!preference) return YES;
  preference = [preference stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
  NSString *namespace = [term substringToIndex:[term rangeOfString:@"." options:NSBackwardsSearch].location];
  NSDictionary *aliases = @{ @"Org.OData.Core.V1": @"Core" };
  BOOL included = NO;
  NSInteger best = -1;
  for (NSString *raw in [preference componentsSeparatedByString:@","]) {
    NSString *item = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    BOOL exclude = [item hasPrefix:@"-"];
    if (exclude) item = [item substringFromIndex:1];
    NSString *short_ = aliases[namespace] ? [NSString stringWithFormat:@"%@%@", aliases[namespace], [term substringFromIndex:namespace.length]] : term;
    NSInteger rank = -1;
    if ([item isEqualToString:term] || [item isEqualToString:short_]) rank = 2;
    else if ([item isEqualToString:[namespace stringByAppendingString:@".*"]] ||
             (aliases[namespace] && [item isEqualToString:[aliases[namespace] stringByAppendingString:@".*"]])) rank = 1;
    else if ([item isEqualToString:@"*"]) rank = 0;
    if (rank > best || (rank == best && exclude)) {
      best = rank;
      included = !exclude;
    }
  }
  return best >= 0 && included;
}

- (instancetype)initWithURLRequest:(NSURLRequest *)request
{
  self = [super init];
  if (!self) return nil;
  _URLRequest = request;
  _method = (request.HTTPMethod ?: @"GET").uppercaseString;
  _userInfo = [NSMutableDictionary dictionary];
  _preferences = @{};
  _version = @"4.01";
  return self;
}

- (NSString *)valueForHeader:(NSString *)name
{
  NSDictionary *headers = self.URLRequest.allHTTPHeaderFields;
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

@end

#pragma mark - Entity set handlers

@interface ODataEntitySetHandler ()
@property (nonatomic, readwrite, weak, nullable) ODataService *service;
@end

// A fetch, and what a store refuses to evaluate (Apple's SQLite store
// raises for arithmetic on a key path's collection operator,
// products.@count * 20) as 501, not as the service failing.
static NSString *OISStringFromHistoryToken(NSPersistentHistoryToken *token);
static BOOL OISHistoryTokenFromString(NSString *string, NSPersistentHistoryToken **token, NSDate **issued);

static NSArray *OISFetch(NSManagedObjectContext *context, NSFetchRequest *fetchRequest, NSError **error)
{
  @try {
    return [context executeFetchRequest:fetchRequest error:error];
  } @catch (NSException *exception) {
    if (![exception.name isEqualToString:NSInvalidArgumentException]) @throw;
    if (error) *error = ODataServiceError(501, [NSString stringWithFormat:@"The store cannot evaluate this: %@", exception.reason]);
    return nil;
  }
}

@implementation ODataChanges {
  NSMutableArray *_changed;
  NSMutableArray *_deleted;
}

+ (instancetype)changesWithToken:(NSString *)token
{
  ODataChanges *changes = [[self alloc] init];
  changes.token = token;
  return changes;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _changed = [NSMutableArray array];
  _deleted = [NSMutableArray array];
  _token = @"0";
  return self;
}

- (NSArray *)changed
{
  return [_changed copy];
}

- (NSArray *)deleted
{
  return [_deleted copy];
}

- (void)addChanged:(NSManagedObjectID *)objectID
{
  if (objectID) [_changed addObject:objectID];
}

- (void)addDeletedEntity:(NSEntityDescription *)entity keyValues:(NSDictionary *)values
{
  if (entity) [_deleted addObject:@{ @"entity": entity, @"values": values ?: @{} }];
}

@end

@implementation ODataEntitySetHandler {
  BOOL _storeFiltersDynamicProperties;
  BOOL _storeFiltersDynamicPropertiesSet;
}

- (instancetype)initWithEntity:(NSEntityDescription *)entity
{
  self = [super init];
  if (!self) return nil;
  _entity = entity;
  _allowsInsert = YES;
  _nonFilterableProperties = [NSSet set];
  _customAggregationMethods = [NSSet set];
  _customAggregates = @{};
  _nonSortableProperties = [NSSet set];
  _allowsUpdate = YES;
  _allowsDelete = YES;
  _allowsUpsert = YES;
  _tracksChanges = YES;
  return self;
}

- (NSAttributeDescription *)dynamicPropertiesAttribute
{
  for (NSEntityDescription *entity = self.entity; entity; entity = entity.superentity) {
    for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
      id flag = attribute.userInfo[ODataUserInfoDynamicProperties];
      if (attribute.attributeType == NSTransformableAttributeType && ([flag isEqual:@"YES"] || [flag isEqual:@YES])) return attribute;
    }
  }
  return nil;
}

- (BOOL)isOpenType
{
  return _openType || self.dynamicPropertiesAttribute != nil;
}

- (BOOL)storeFiltersDynamicProperties
{
  return _storeFiltersDynamicPropertiesSet ? _storeFiltersDynamicProperties : !self.dynamicPropertiesAttribute;
}

- (void)setStoreFiltersDynamicProperties:(BOOL)filters
{
  _storeFiltersDynamicProperties = filters;
  _storeFiltersDynamicPropertiesSet = YES;
}

// Each object's, from its bag.
- (NSDictionary *)dynamicPropertiesOfObjects:(NSArray<NSManagedObject *> *)objects request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSAttributeDescription *bag = self.dynamicPropertiesAttribute;
  if (!bag) return @{};
  NSMutableDictionary *answer = [NSMutableDictionary dictionary];
  for (NSManagedObject *object in objects) {
    id kept = [object valueForKey:bag.name];
    if ([kept isKindOfClass:[NSDictionary class]]) answer[object.objectID] = kept;
  }
  return answer;
}

- (NSPredicate *)predicateForDynamicProperty:(NSArray<NSString *> *)path
                                    operator:(NSPredicateOperatorType)type
                                       value:(id)value
                                     request:(ODataRequest *)request
                                       error:(NSError **)error
{
  // The bag's entry, compared as it is kept: evaluated here, not by the
  // store (storeFiltersDynamicProperties).
  NSAttributeDescription *bag = self.dynamicPropertiesAttribute;
  if (!bag) return nil;
  NSString *keyPath = [[@[ bag.name ] arrayByAddingObjectsFromArray:path] componentsJoinedByString:@"."];
  return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:keyPath]
                                            rightExpression:[NSExpression expressionForConstantValue:value]
                                                   modifier:NSDirectPredicateModifier type:type options:0];
}

- (id)writeDynamicProperties:(NSArray<NSDictionary *> *)values ofObjects:(NSArray<NSManagedObject *> *)objects
                     request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSAttributeDescription *bag = self.dynamicPropertiesAttribute;
  if (bag) {
    // A new dictionary each: Core Data sees no change made to one in place.
    BOOL replacing = [request.method isEqualToString:@"PUT"];
    for (NSUInteger i = 0; i < objects.count; i++) {
      id kept = replacing ? nil : [objects[i] valueForKey:bag.name];
      NSMutableDictionary *dynamic = [kept isKindOfClass:[NSDictionary class]] ? [kept mutableCopy] : [NSMutableDictionary dictionary];
      [values[i] enumerateKeysAndObjectsUsingBlock:^(id name, id value, BOOL *stop) {
        (void)stop;
        if (value == [NSNull null]) [dynamic removeObjectForKey:name];
        else dynamic[name] = value;
      }];
      [objects[i] setValue:dynamic.count ? [dynamic copy] : nil forKey:bag.name];
    }
    return @YES;
  }
  NSMutableSet *names = [NSMutableSet set];
  for (NSDictionary *each in values) [names addObjectsFromArray:each.allKeys];
  [reply failWithError:ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", self.entity.name,
                                                                       [[names.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]])];
  return nil;
}

- (BOOL)allowsInsert
{
  return _allowsInsert && !self.service.isReadOnly;
}

- (BOOL)allowsUpdate
{
  return _allowsUpdate && !self.service.isReadOnly;
}

- (BOOL)allowsDelete
{
  return _allowsDelete && !self.service.isReadOnly;
}

- (BOOL)canTrackChanges
{
  NSPersistentStoreCoordinator *coordinator = self.service.coordinator;
  if (!self.tracksChanges || !coordinator.persistentStores.count) return NO;
  for (NSPersistentStore *store in coordinator.persistentStores) {
    id option = store.options[NSPersistentHistoryTrackingKey];
    BOOL tracking = [option isKindOfClass:[NSDictionary class]] || ([option respondsToSelector:@selector(boolValue)] && [option boolValue]);
    if (!tracking) return NO;
  }
  NSEntityDescription *root = self.entity;
  while (root.superentity) root = root.superentity;
  for (NSAttributeDescription *attribute in [self.service.mapper keyAttributesForEntity:root]) {
    if (!attribute.preservesValueInHistoryOnDeletion) return NO;
  }
  return YES;
}

- (NSString *)changeTokenForRequest:(ODataRequest *)request
{
  return OISStringFromHistoryToken([self.service.coordinator currentPersistentHistoryTokenFromStores:nil]);
}

// The persistent history since the token: each object's changes in order,
// one that came and went since not mentioned.
- (ODataChanges *)changesSince:(NSString *)token request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSPersistentHistoryToken *since = nil;
  NSDate *issued = nil;
  if (!OISHistoryTokenFromString(token, &since, &issued)) {
    [reply failWithError:ODataServiceError(400, [NSString stringWithFormat:@"$deltatoken=%@ is not one this service wrote", token])];
    return nil;
  }
  // Given before the history was pruned up to: changes made after it may be
  // gone (FreeCoreData does not say so itself, as Apple's history does).
  NSDate *pruned = [self.service historyPrunedBefore];
  // In milliseconds, as tokens say.
  if (issued && pruned && (long long)(issued.timeIntervalSince1970 * 1000) < (long long)(pruned.timeIntervalSince1970 * 1000)) {
    [reply failWithError:ODataServiceError(410, @"The delta link has expired; read the set again")];
    return nil;
  }
  NSError *error = nil;
  NSPersistentHistoryChangeRequest *history = [NSPersistentHistoryChangeRequest fetchHistoryAfterToken:since];
  history.resultType = NSPersistentHistoryResultTypeTransactionsAndChanges;
  NSPersistentHistoryResult *result = (NSPersistentHistoryResult *)[request.context executeRequest:history error:&error];
  if (!result) {
    // NSPersistentHistoryTokenExpiredError, which FreeCoreData does not name.
    BOOL expired = [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == 134301;
    [reply failWithError:expired ? ODataServiceError(410, @"The delta link has expired; read the set again") : error];
    return nil;
  }
  NSMutableOrderedSet *changed = [NSMutableOrderedSet orderedSet];
  NSMutableDictionary *deleted = [NSMutableDictionary dictionary];
  NSPersistentHistoryToken *last = since;
  for (NSPersistentHistoryTransaction *transaction in result.result) {
    last = transaction.token ?: last;
    for (NSPersistentHistoryChange *change in transaction.changes) {
      NSManagedObjectID *oid = change.changedObjectID;
      if (![oid.entity isKindOfEntity:self.entity]) continue;
      switch (change.changeType) {
        case NSPersistentHistoryChangeTypeInsert:
          [changed addObject:oid];
          break;
        case NSPersistentHistoryChangeTypeUpdate: {
          // An update of what the service keeps for itself changes nothing
          // a client sees.
          BOOL seen = !change.updatedProperties.count;
          for (NSPropertyDescription *property in change.updatedProperties) seen = seen || [self.service.mapper servesProperty:property];
          if (seen) [changed addObject:oid];
          break;
        }
        case NSPersistentHistoryChangeTypeDelete:
          // Made and gone since the link, it is still told: a client may
          // have it all the same (one that made it after reading the
          // link: an offline device's upload). One that never had it
          // finds nothing to remove.
          [changed removeObject:oid];
          deleted[oid] = change.tombstone ?: @{};
          break;
      }
    }
  }
  ODataChanges *changes = [ODataChanges changesWithToken:OISStringFromHistoryToken(last)];
  for (NSManagedObjectID *oid in changed) [changes addChanged:oid];
  for (NSManagedObjectID *oid in deleted) [changes addDeletedEntity:oid.entity keyValues:deleted[oid]];
  return changes;
}

- (NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request
{
  return nil;
}

- (NSString *)scopeVersionForRequest:(ODataRequest *)request
{
  return nil;
}

- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSError *error = nil;
  NSArray *objects = OISFetch(request.context, fetchRequest, &error);
  if (!objects) [reply failWithError:error];
  return objects;
}

- (id)valueOfAggregationMethod:(NSString *)method values:(NSArray *)values request:(ODataRequest *)request
{
  return nil;
}

- (id)valueOfCustomAggregate:(NSString *)name objects:(NSArray *)objects request:(ODataRequest *)request
{
  return nil;
}

- (NSArray *)groupedRowsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSError *error = nil;
  NSArray *rows = OISFetch(request.context, fetchRequest, &error);
  if (!rows) [reply failWithError:error];
  return rows;
}

- (NSNumber *)countForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSError *error = nil;
  NSUInteger count = NSNotFound;
  @try {
    count = [request.context countForFetchRequest:fetchRequest error:&error];
  } @catch (NSException *exception) {
    if (![exception.name isEqualToString:NSInvalidArgumentException]) @throw;
    error = ODataServiceError(501, [NSString stringWithFormat:@"The store cannot evaluate this: %@", exception.reason]);
  }
  if (count == NSNotFound) {
    [reply failWithError:error];
    return nil;
  }
  return @(count);
}

- (NSManagedObject *)objectWithKey:(NSDictionary *)key request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *name in key) {
    [parts addObject:[NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:name]
                                                        rightExpression:[NSExpression expressionForConstantValue:key[name]]
                                                               modifier:NSDirectPredicateModifier
                                                                   type:NSEqualToPredicateOperatorType
                                                                options:0]];
  }
  NSPredicate *visible = [self predicateForVisibleObjectsInRequest:request];
  if (visible) [parts addObject:visible];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:parts];
  fetch.fetchLimit = 1;
  NSError *error = nil;
  NSArray *found = [request.context executeFetchRequest:fetch error:&error];
  if (!found) [reply failWithError:error];
  return found.firstObject;
}

- (void)applyValues:(NSDictionary *)values to:(NSManagedObject *)object
{
  for (NSString *name in values) {
    id value = values[name];
    [object setValue:value == [NSNull null] ? nil : value forKey:name];
  }
}

- (NSManagedObject *)insertObjectWithValues:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSManagedObject *object = [[NSManagedObject alloc] initWithEntity:request.entity ?: self.entity
                                     insertIntoManagedObjectContext:request.context];
  [self applyValues:values to:object];
  return object;
}

- (NSManagedObject *)updateObject:(NSManagedObject *)object values:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [self applyValues:values to:object];
  return object;
}

- (void)deleteObject:(NSManagedObject *)object request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [request.context deleteObject:object];
}

@end

#pragma mark - The service's own state


// An asynchronous request: the client's exchange until it is answered
// (202, or the answer itself when that comes first), who sent it, and its
// answer once there is one.
@interface OISAsyncJob : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, weak) ODataService *service;
@property (nonatomic, strong, nullable) ODataExchange *exchange;
@property (nonatomic, strong, nullable) ODataRequest *request;
@property (nonatomic) BOOL accepted;
@property (nonatomic) BOOL finished;
@property (nonatomic, strong, nullable) NSDate *finishedAt;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy, nullable) NSDictionary *headers;
@property (nonatomic, copy, nullable) NSData *body;
- (void)exchangeDidFinish:(ODataExchange *)inner;
- (void)accept;
@end

@interface ODataService (OISAsync)
- (void)acceptAsyncJob:(OISAsyncJob *)job exchange:(ODataExchange *)exchange;
- (nullable OISAsyncJob *)asyncJobWithIdentifier:(NSString *)identifier;
- (void)forgetAsyncJob:(OISAsyncJob *)job;
- (NSString *)statusMonitorOf:(OISAsyncJob *)job;
@end

// Whether JSON nests no deeper than depth (0: any), counted without
// parsing it, since a parser recurses: arrays and objects, outside strings.
BOOL ODataJSONNestedWithin(NSData *data, NSUInteger depth)
{
  if (!depth) return YES;
  const unsigned char *bytes = data.bytes;
  NSUInteger level = 0;
  BOOL inString = NO, escaped = NO;
  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char c = bytes[i];
    if (inString) {
      if (escaped) escaped = NO;
      else if (c == '\\') escaped = YES;
      else if (c == '"') inString = NO;
      continue;
    }
    if (c == '"') inString = YES;
    else if (c == '[' || c == '{') {
      if (++level > depth) return NO;
    } else if ((c == ']' || c == '}') && level) {
      level--;
    }
  }
  return YES;
}



// A delta token: when it was given (milliseconds), a dot, and the
// persistent history token, archived, in base64url (0 for the start of
// history: a store with none yet may have no token). Every change after
// the token's place was made after it was given, so history pruned up to
// a later time may have lost some: the token has expired.
static NSString *OISStringFromHistoryToken(NSPersistentHistoryToken *token)
{
  long long issued = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
  if (!token) return [NSString stringWithFormat:@"%lld.0", issued];
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:token requiringSecureCoding:YES error:NULL];
  return data ? [NSString stringWithFormat:@"%lld.%@", issued, ODataBase64URLString(data)] : nil;
}

static BOOL OISHistoryTokenFromString(NSString *string, NSPersistentHistoryToken **token, NSDate **issued)
{
  *token = nil;
  *issued = nil;
  // One given before tokens said when (no dot: base64url has none).
  NSRange dot = [string rangeOfString:@"."];
  if (dot.location != NSNotFound) {
    long long ms = [[string substringToIndex:dot.location] longLongValue];
    if (ms > 0) *issued = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)ms / 1000];
    string = [string substringFromIndex:NSMaxRange(dot)];
  }
  if ([string isEqualToString:@"0"]) return YES;
  NSData *data = ODataDataFromBase64(string);
  if (!data.length) return NO;
  id object = nil;
  @try {
    object = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSPersistentHistoryToken class] fromData:data error:NULL];
  } @catch (NSException *exception) {
    object = nil;
  }
  if (![object isKindOfClass:[NSPersistentHistoryToken class]]) return NO;
  *token = object;
  return YES;
}


static NSString *OISPercentDecoded(NSString *text)
{
  return [text stringByRemovingPercentEncoding] ?: text;
}


#pragma mark - One call

// One request, from the URL to the response. Each step that asks a handler
// for something goes on in the method its reply names.
// $apply's first groupby or aggregate, done by the store: a fetch of
// dictionaries grouped by Core Data, and how to turn them into the groups
// ODataAggregation would have made in memory from the same rows. Only
// what the store computes exactly as ODataAggregation does is asked of it
// (see -storeGroupingOf:predicate:); the rest is helpers:
//   sum and average leave out nulls and are null over none: a count of
//   the values beside each, and null where it is 0;
//   sum of integers is a decimal, and average of integers the exact
//   quotient of their sum and their count.

@implementation OISStoreGrouping

static NSString *OISHelperName(NSString *alias, NSString *what)
{
  return [NSString stringWithFormat:@"__ois_%@_%@", what, alias];
}

- (NSArray<NSDictionary *> *)groupsOfRows:(NSArray<NSDictionary *> *)rows
{
  // An aggregate over no rows at all is still one row, as in memory.
  if (!rows.count && !self.keyPaths.count) rows = @[ @{} ];
  NSMutableArray *groups = [NSMutableArray array];
  for (NSDictionary *row in rows) {
    NSMutableDictionary *group = [NSMutableDictionary dictionary];
    for (NSString *keyPath in self.keyPaths) group[keyPath] = row[keyPath] ?: [NSNull null];
    for (ODataAggregate *aggregate in self.transformation.aggregates) {
      NSString *alias = aggregate.alias, *method = self.methods[alias];
      id value = row[alias];
      if (value == [NSNull null]) value = nil;
      NSNumber *n = row[OISHelperName(alias, @"n")];
      BOOL none = [n isKindOfClass:[NSNumber class]] && n.longLongValue == 0;
      if ([method isEqualToString:@"count"]) {
        group[alias] = @([value longLongValue]);
      } else if ([method isEqualToString:@"decimalSum"]) {
        group[alias] = none || !value ? [NSNull null] : [NSDecimalNumber decimalNumberWithDecimal:[value decimalValue]];
      } else if ([method isEqualToString:@"exactAverage"]) {
        NSNumber *sum = row[OISHelperName(alias, @"sum")];
        group[alias] = none || ![sum isKindOfClass:[NSNumber class]] || ![n isKindOfClass:[NSNumber class]] ? [NSNull null]
            : [[NSDecimalNumber decimalNumberWithDecimal:sum.decimalValue] decimalNumberByDividingBy:[NSDecimalNumber decimalNumberWithDecimal:n.decimalValue]];
      } else if ([method isEqualToString:@"sum"] || [method isEqualToString:@"average"]) {
        group[alias] = none || !value ? [NSNull null] : @([value doubleValue]);
      } else {
        group[alias] = value ?: [NSNull null];
      }
    }
    [groups addObject:group];
  }
  return groups;
}

@end

// The $apply transformations the service has (Data Aggregation sections 3
// and 6), as $metadata lists them.
static NSArray<NSString *> *OISApplyTransformations(void)
{
  return @[ @"filter", @"groupby", @"aggregate", @"identity", @"search", @"compute", @"orderby", @"top", @"skip",
            @"topcount", @"topsum", @"toppercent", @"bottomcount", @"bottomsum", @"bottompercent", @"concat", @"join", @"outerjoin",
            @"ancestors", @"descendants", @"traverse" ];
}

// A recursive hierarchy (Data Aggregation section 5.5.1), as the caller
// sees it: the nodes of a set (Aggregation.RecursiveHierarchy#Q on its
// entity type: NodeProperty, the node identifier, q; and
// ParentNavigationProperty), read once per request. Core Data has no
// recursive query: the service reads each node's identifier and its
// parents' and walks the tree here, and what it finds is a set of
// identifiers, which a store tests with IN.

@implementation OISHierarchy

- (void)readObjects:(NSArray<NSManagedObject *> *)objects
{
  self.nodes = [NSMutableArray array];
  self.objects = [NSMutableDictionary dictionary];
  self.parents = [NSMutableDictionary dictionary];
  self.children = [NSMutableDictionary dictionary];
  for (NSManagedObject *object in objects) {
    id node = [object valueForKeyPath:self.nodeKeyPath];
    if (!node || node == [NSNull null] || self.objects[node]) continue;  // not a node, or not the first with it
    [self.nodes addObject:node];
    self.objects[node] = object;
  }
  // Parents among the nodes: one outside the set the caller sees is none.
  for (id node in self.nodes) {
    id related = [self.objects[node] valueForKey:self.parentKey];
    NSMutableArray *parents = [NSMutableArray array];
    for (NSManagedObject *parent in (self.parentsAreMany ? related : (related ? @[ related ] : @[]))) {
      id identifier = [parent valueForKeyPath:self.nodeKeyPath];
      if (identifier && self.objects[identifier] == parent && ![parents containsObject:identifier]) [parents addObject:identifier];
    }
    self.parents[node] = parents;
    for (id parent in parents) {
      if (!self.children[parent]) self.children[parent] = [NSMutableArray array];
      [self.children[parent] addObject:node];
    }
  }
}

- (NSArray *)roots
{
  NSMutableArray *roots = [NSMutableArray array];
  for (id node in self.nodes) if (![self.parents[node] count]) [roots addObject:node];
  return roots;
}

- (NSArray *)leaves
{
  NSMutableArray *leaves = [NSMutableArray array];
  for (id node in self.nodes) if (![self.children[node] count]) [leaves addObject:node];
  return leaves;
}

// Breadth first along parents or children, each node once (a cycle, which
// the spec forbids, ends there).
- (NSArray *)reachedFrom:(id)node along:(NSDictionary *)links distance:(NSInteger)distance includeSelf:(BOOL)includeSelf
{
  NSMutableArray *found = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet setWithObject:node];
  if (includeSelf) [found addObject:node];
  NSArray *level = @[ node ];
  for (NSInteger step = 1; level.count && (distance <= 0 || step <= distance); step++) {
    NSMutableArray *next = [NSMutableArray array];
    for (id at in level) {
      for (id linked in links[at]) {
        if ([seen containsObject:linked]) continue;
        [seen addObject:linked];
        [found addObject:linked];
        [next addObject:linked];
      }
    }
    level = next;
  }
  return found;
}

- (NSArray *)ancestorsOf:(id)node distance:(NSInteger)distance includeSelf:(BOOL)includeSelf
{
  return [self reachedFrom:node along:self.parents distance:distance includeSelf:includeSelf];
}

- (NSArray *)descendantsOf:(id)node distance:(NSInteger)distance includeSelf:(BOOL)includeSelf
{
  return [self reachedFrom:node along:self.children distance:distance includeSelf:includeSelf];
}

// Two nodes with a parent in common, or two roots.
- (NSArray *)siblingsOf:(id)node
{
  if (!self.objects[node]) return @[];
  NSMutableArray *siblings = [NSMutableArray array];
  NSArray *parents = self.parents[node];
  NSArray *candidates = parents.count ? nil : [self roots];
  if (!candidates) {
    NSMutableArray *all = [NSMutableArray array];
    for (id parent in parents) [all addObjectsFromArray:self.children[parent]];
    candidates = all;
  }
  for (id other in candidates) {
    if (![other isEqual:node] && ![siblings containsObject:other]) [siblings addObject:other];
  }
  return siblings;
}

@end


// An entity with values $apply's compute gave it: answers them by name,
// and anything else as the object does.

@implementation OISComputedRow
- (id)valueForKey:(NSString *)key
{
  id value = self.computed[key];
  if (value) return value == [NSNull null] ? nil : value;
  return [self.object valueForKey:key];
}
@end

@implementation OISServiceCall

- (ODataPropertyMapper *)mapper
{
  return self.service.mapper;
}

// The service's builder, with this request for its blocks.
- (ODataPredicateBuilder *)predicates
{
  return [self.service.predicates builderWithUserInfo:self.request];
}

- (ODataReply *)replyWithAction:(SEL)action
{
  ODataReply *reply = [[ODataReply alloc] initWithTarget:self action:action context:self.request.context];
  reply.request = self.request;
  reply.timeout = self.service.replyTimeout;
  // What it answers for: the operation's call or the store request under way.
  reply.span = self.callSpan ?: self.storeSpan;
  return reply;
}

#pragma mark Responses

- (void)respondStatus:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body
{
  if (self.done) return;
  self.done = YES;
  [self traceRespondedWithStatus:status];
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  all[@"OData-Version"] = self.request.version ?: @"4.01";
  if (self.repeatabilityKey) {
    all[@"Repeatability-Result"] = @"accepted";
    [self.service rememberAnswer:status headers:all body:body ?: [NSData data]
                          forKey:self.repeatabilityKey signature:self.repeatabilitySignature];
  }
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.exchange.request.URL
                                                            statusCode:status
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:all];
  self.exchange.URLResponse = response;
  self.exchange.data = self.headOnly ? [NSData data] : (body ?: [NSData data]);
  [self.exchange finish];
}

- (NSString *)JSONContentType
{
  return [NSString stringWithFormat:@"application/json;odata.metadata=%@;odata.streaming=true;IEEE754Compatible=%@;charset=utf-8",
          self.metadataLevel ?: @"minimal", self.coder.IEEE754Compatible ? @"true" : @"false"];
}

- (void)respondJSON:(id)json status:(NSInteger)status headers:(NSDictionary *)headers
{
  NSArray *messages = self.request.messages;
  if (messages.count && [json isKindOfClass:[NSDictionary class]] && ![json objectForKey:@"error"] &&
      [self.request includesAnnotation:@"Org.OData.Core.V1.Messages"]) {
    NSMutableDictionary *annotated = [json mutableCopy];
    annotated[ODataMessagesAnnotation] = [messages valueForKey:@"JSONObject"];
    json = annotated;
  }
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
  if (!data) {
    [self respondError:ODataServiceError(500, [NSString stringWithFormat:@"The response could not be written: %@", error.localizedDescription])];
    return;
  }
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  all[@"Content-Type"] = [self JSONContentType];
  [self respondStatus:status headers:all body:data];
}

- (void)respondText:(NSString *)text contentType:(NSString *)type headers:(NSDictionary *)headers
{
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  all[@"Content-Type"] = type;
  [self respondStatus:200 headers:all body:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

// What an error answers with: a service error's own status; a failed
// validation's 400, with a detail for each property; a conflict's 409;
// anything else 500.
- (void)respondError:(NSError *)error
{
  NSInteger status = 500;
  NSMutableArray *details = [NSMutableArray array];
  NSString *target = error.userInfo[ODataErrorTargetKey];
  // The service's own errors, and the host's (an authenticator's refusal).
  if ([error.domain isEqualToString:ODataServiceErrorDomain] || [error.domain isEqualToString:HSErrorDomain]) {
    status = error.code >= 400 && error.code < 600 ? error.code : 500;
    for (NSDictionary *detail in error.userInfo[ODataErrorDetailsKey] ?: @[]) [details addObject:detail];
  } else if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code >= NSValidationErrorMinimum && error.code <= NSValidationErrorMaximum) {
    status = 400;
    NSArray *each = error.code == NSValidationMultipleErrorsError ? error.userInfo[NSDetailedErrorsKey] : @[ error ];
    BOOL own = NO;
    for (NSError *e in each) {
      NSManagedObject *object = e.userInfo[NSValidationObjectErrorKey];
      NSString *key = e.userInfo[NSValidationKeyErrorKey];
      NSPropertyDescription *property = key ? object.entity.propertiesByName[key] : nil;
      // One the service keeps for itself: no request can put it right, and
      // Core Data's words name it.
      if (property && ![self.mapper servesProperty:property]) {
        OISLog(HSLogLevelError, self.exchange.request, @"%@ %@: %@ is not valid: %@", self.request.method, self.exchange.request.URL, key,
               e.localizedDescription);
        own = YES;
        continue;
      }
      NSMutableDictionary *detail = [NSMutableDictionary dictionary];
      detail[@"code"] = [NSString stringWithFormat:@"%ld", (long)e.code];
      detail[@"message"] = e.localizedDescription ?: @"Validation failed";
      if ([property isKindOfClass:[NSAttributeDescription class]] && [self.mapper servesProperty:property]) {
        detail[@"target"] = [self.mapper propertyForAttribute:(NSAttributeDescription *)property];
      } else if ([property isKindOfClass:[NSRelationshipDescription class]]
                 && [self.mapper servesProperty:property]) {
        detail[@"target"] = [self.mapper propertyForRelationship:(NSRelationshipDescription *)property];
      }
      [details addObject:detail];
    }
    if (own) {
      status = 500;
      error = ODataServiceError(500, @"The service could not complete the entity: a value it keeps for itself is not valid");
      [details removeAllObjects];
    } else if (details.count == 1) {
      target = details[0][@"target"];
    }
  } else if ([error.domain isEqualToString:NSCocoaErrorDomain] && (error.code == 133020 || error.code == 133021)) {
    status = 409;  // NSManagedObjectMergeError, NSManagedObjectConstraintMergeError
  } else if (!error) {
    error = ODataServiceError(500, @"The request failed");
  } else {
    // The store's own failure: logged, and not shown, since it may say
    // more of the service than a client should know.
    OISLog(HSLogLevelError, self.exchange.request, @"%@ %@ failed: %@", self.request.method, self.exchange.request.URL, error);
    [self.span recordError:error];
    error = ODataServiceError(500, @"The service could not answer the request");
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  body[@"code"] = error.userInfo[ODataErrorCodeKey] ?: [NSString stringWithFormat:@"%ld", (long)status];
  body[@"message"] = error.localizedDescription ?: @"";
  if (target) body[@"target"] = target;
  if (details.count) body[@"details"] = details;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  if (status == 405 && error.userInfo[@"Allow"]) headers[@"Allow"] = error.userInfo[@"Allow"];
  // The scopes it needs, as the challenge names them (RFC 6750 section 3).
  id named = error.userInfo[ODataErrorScopesKey] ?: error.userInfo[HSErrorScopesKey];
  NSArray *scopes = [named isKindOfClass:[NSArray class]] ? named : nil;
  NSString *scope = [[scopes componentsJoinedByString:@" "] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
  if (status == 401) {
    id<HSAuthenticator> authenticator = self.service.authenticator;
    NSString *challenge = [authenticator respondsToSelector:@selector(challengeForRequest:)]
        ? [authenticator challengeForRequest:self.authenticationRequest ?: OISHostRequest(self.request.URLRequest)] : nil;
    challenge = challenge.length ? challenge : @"Bearer";
    if (scope.length) challenge = [challenge stringByAppendingFormat:@"%@scope=\"%@\"", [challenge rangeOfString:@" "].location == NSNotFound ? @" " : @", ", scope];
    headers[@"WWW-Authenticate"] = challenge;
  } else if (status == 403 && scope.length) {
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"\"\\"];
    NSString *description = [[body[@"message"] componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"'"];
    headers[@"WWW-Authenticate"] = [NSString stringWithFormat:@"Bearer realm=\"api\", error=\"insufficient_scope\", "
                                                              @"error_description=\"%@\", scope=\"%@\"", description, scope];
  }
  [self respondJSON:@{ @"error": body } status:status headers:headers];
}

- (void)fail:(NSInteger)status message:(NSString *)message
{
  [self respondError:ODataServiceError(status, message)];
}

- (BOOL)holds:(NSSet<NSString *> *)scopes
{
  return !scopes.count || [scopes intersectsSet:self.request.principal.scopes ?: [NSSet set]];
}

- (BOOL)permits:(NSSet<NSString *> *)scopes to:(NSString *)what
{
  if ([self holds:scopes]) return YES;
  NSArray *sorted = [scopes.allObjects sortedArrayUsingSelector:@selector(compare:)];
  // No one at all (an anonymous request): signing in may help.
  NSInteger status = self.request.principal ? 403 : 401;
  NSString *message = [NSString stringWithFormat:@"To %@ needs one of the scopes %@", what, [sorted componentsJoinedByString:@" "]];
  NSMutableDictionary *info = [ODataServiceError(status, message).userInfo mutableCopy];
  info[ODataErrorScopesKey] = sorted;
  [self respondError:[NSError errorWithDomain:ODataServiceErrorDomain code:status userInfo:info]];
  return NO;
}

- (BOOL)permitsAll:(NSDictionary<NSString *, NSSet<NSString *> *> *)permissions
{
  for (NSString *what in [permissions.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (![self permits:permissions[what] to:what]) return NO;
  }
  return YES;
}

- (void)methodNotAllowed:(NSArray<NSString *> *)allowed
{
  NSString *allow = [allowed componentsJoinedByString:@", "];
  NSError *error = [NSError errorWithDomain:ODataServiceErrorDomain code:405 userInfo:@{
    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not allowed here", self.request.method],
    @"Allow": allow,
  }];
  [self respondError:error];
}

#pragma mark Reading the request

// The resource path after the service root, and the query options, both
// decoded.
// How deep $expand nests: 0 for none. $levels=max counts one level: the
// service bounds it itself.
static NSUInteger OISExpandDepth(ODataQueryOptions *options)
{
  NSUInteger deepest = 0;
  for (ODataExpandItem *item in options.expand) {
    NSUInteger levels = item.options.levels && item.options.levels.integerValue > 0 ? item.options.levels.unsignedIntegerValue : 1;
    deepest = MAX(deepest, levels + OISExpandDepth(item.options));
  }
  return deepest;
}

- (BOOL)readURL
{
  NSURL *url = self.exchange.request.URL;
  NSString *rootPath = self.service.serviceRoot.path ?: @"/";
  if (![rootPath hasSuffix:@"/"]) rootPath = [rootPath stringByAppendingString:@"/"];
  NSString *path = url.path.length ? url.path : @"/";
  // NSURL drops a trailing slash from -path; the root itself may be asked
  // for with or without one.
  NSString *requestPath = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
  if (![requestPath hasPrefix:rootPath]) {
    [self fail:404 message:[NSString stringWithFormat:@"%@ is not under the service root %@", path, rootPath]];
    return NO;
  }
  // The path as it was sent, so that an escaped character in a key keeps
  // its meaning until the parser has read the key.
  NSString *encoded = [self encodedPathOf:url];
  NSString *resource = encoded.length > rootPath.length ? [encoded substringFromIndex:rootPath.length] : @"";
  if ([resource hasSuffix:@"/"]) resource = [resource substringToIndex:resource.length - 1];
  // $explain/<resource path>: the request's plans, where the service says
  // so; a write's, without writing.
  if (self.service.explains && ([resource isEqualToString:@"$explain"] || [resource hasPrefix:@"$explain/"])) {
    self.explaining = YES;
    resource = resource.length > 9 ? [resource substringFromIndex:9] : @"";
  }
  self.resourcePath = OISPercentDecoded(resource);

  NSError *error = nil;
  ODataResourcePath *resourcePath = [ODataResourcePath pathWithString:self.resourcePath error:&error];
  if (!resourcePath) {
    [self respondError:ODataServiceError(400, error.localizedDescription)];
    return NO;
  }
  self.request.path = resourcePath;

  NSMutableDictionary *query = [NSMutableDictionary dictionary];
  NSMutableDictionary *JSONAliases = [NSMutableDictionary dictionary];
  NSString *raw = url.query;
  for (NSString *pair in raw.length ? [raw componentsSeparatedByString:@"&"] : @[]) {
    if (!pair.length) continue;
    NSRange equals = [pair rangeOfString:@"="];
    NSString *key = OISPercentDecoded(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
    NSString *value = equals.location == NSNotFound ? @"" : OISPercentDecoded([pair substringFromIndex:equals.location + 1]);
    if (query[key] || JSONAliases[key]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is given twice", key]];
      return NO;
    }
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([key hasPrefix:@"@"] && trimmed.length && strchr("[{\"", (char)[trimmed characterAtIndex:0])) {
      id json = [NSJSONSerialization JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                                                options:NSJSONReadingAllowFragments
                                                  error:NULL];
      if (!json) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ is not JSON", key]];
        return NO;
      }
      JSONAliases[[key substringFromIndex:1]] = json;
      continue;
    }
    if ([key isEqualToString:@"$id"]) self.referenceID = value;
    query[key] = value;
  }
  self.JSONAliases = JSONAliases;
  self.deltaToken = query[@"$deltatoken"];
  for (NSString *key in query) {
    // The schema the request is made against (Part 1, 11.2.12): the
    // service's (its modelVersion, or *); another only where the service
    // can read what such a client writes (upgradeBody), and its $metadata
    // never, the service having only its own.
    if ([key isEqualToString:@"$schemaversion"]) {
      NSString *asked = query[key];
      BOOL current = [asked isEqualToString:@"*"] || (self.service.modelVersion && [asked isEqualToString:self.service.modelVersion]);
      if (!current && (!self.service.upgradeBody || [self.resourcePath isEqualToString:@"$metadata"])) {
        [self fail:404 message:[NSString stringWithFormat:@"The service has no schema version %@", asked]];
        return NO;
      }
      if (!current) self.schemaVersion = asked;
    }
    if ([@[ @"$index" ] containsObject:key]) {
      [self fail:501 message:[NSString stringWithFormat:@"%@ is not supported", key]];
      return NO;
    }
  }
  ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:query error:&error];
  if (!options) {
    NSInteger status = error.code == ODataIncrementalStoreErrorUnsupportedExpression ? 501 : 400;
    [self respondError:ODataServiceError(status, error.localizedDescription)];
    return NO;
  }
  self.request.options = options;
  NSUInteger most = self.service.maxExpandDepth;
  if (most && OISExpandDepth(options) > most) {
    [self fail:400 message:[NSString stringWithFormat:@"$expand goes deeper than the service takes (%lu)", (unsigned long)most]];
    return NO;
  }
  return YES;
}


- (NSString *)encodedPathOf:(NSURL *)url
{
  NSString *absolute = url.absoluteString;
  NSRange scheme = [absolute rangeOfString:@"://"];
  NSUInteger start = 0;
  if (scheme.location != NSNotFound) {
    NSRange slash = [absolute rangeOfString:@"/" options:0 range:NSMakeRange(NSMaxRange(scheme), absolute.length - NSMaxRange(scheme))];
    start = slash.location == NSNotFound ? absolute.length : slash.location;
  }
  NSString *rest = [absolute substringFromIndex:start];
  NSRange end = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
  NSString *path = end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
  return path.length ? path : @"/";
}

// OData-MaxVersion picks 4.0 or 4.01; OData-Version must be one the
// service speaks.
- (BOOL)negotiateVersion
{
  NSString *max = self.service.maxVersion;
  NSString *asked = [self.request valueForHeader:@"OData-MaxVersion"];
  NSString *version = [max isEqualToString:@"4.0"] ? @"4.0" : @"4.01";
  if (asked && [asked compare:@"4.01" options:NSNumericSearch] == NSOrderedAscending) version = @"4.0";
  self.request.version = version;
  NSString *sent = [self.request valueForHeader:@"OData-Version"];
  if (sent && ![sent isEqualToString:@"4.0"] && ![sent isEqualToString:@"4.01"]) {
    [self fail:400 message:[NSString stringWithFormat:@"OData-Version %@ is not supported", sent]];
    return NO;
  }
  if (sent && [sent compare:version options:NSNumericSearch] == NSOrderedDescending) {
    [self fail:400 message:[NSString stringWithFormat:@"The request is in OData-Version %@, and this service speaks %@", sent, version]];
    return NO;
  }
  return YES;
}

// $format, or Accept: JSON, with its odata.metadata and
// IEEE754Compatible parameters.
- (BOOL)negotiateFormat
{
  NSString *format = self.request.options.format;
  NSString *accept = [self.request valueForHeader:@"Accept"];
  NSString *given = format ?: accept ?: @"";
  NSString *lower = given.lowercaseString;
  BOOL metadata = self.kind == OISTargetMetadata;
  if (format) {
    BOOL json = [lower isEqualToString:@"json"] || [lower hasPrefix:@"application/json"];
    BOOL xml = [lower isEqualToString:@"xml"] || [lower hasPrefix:@"application/xml"];
    if (metadata && json) self.metadataAsJSON = YES;
    if (!(metadata ? (xml || json) : json)) {
      [self fail:406 message:[NSString stringWithFormat:@"$format=%@ is not a format this resource has", format]];
      return NO;
    }
  } else if (accept.length && metadata) {
    // $metadata as JSON when JSON is asked for and XML is not.
    BOOL json = NO, xml = NO;
    for (NSString *range in [lower componentsSeparatedByString:@","]) {
      NSString *type = [[range componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([type isEqualToString:@"application/json"]) json = YES;
      if ([type isEqualToString:@"application/xml"] || [type isEqualToString:@"*/*"] || [type isEqualToString:@"application/*"]) xml = YES;
    }
    self.metadataAsJSON = json && !xml;
  } else if (accept.length && !metadata && self.kind != OISTargetCount && self.kind != OISTargetValue && self.kind != OISTargetStream) {
    BOOL acceptable = NO;
    for (NSString *range in [lower componentsSeparatedByString:@","]) {
      NSString *type = [[range componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([type isEqualToString:@"application/json"] || [type isEqualToString:@"*/*"] || [type isEqualToString:@"application/*"]) acceptable = YES;
    }
    if (!acceptable) {
      [self fail:406 message:@"This service answers in application/json"];
      return NO;
    }
  }
  self.metadataLevel = @"minimal";
  for (NSString *parameter in [lower componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";,"]]) {
    NSString *p = [parameter stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *name in @[ @"odata.metadata=", @"metadata=" ]) {
      if ([p hasPrefix:name]) {
        NSString *level = [p substringFromIndex:name.length];
        if ([@[ @"minimal", @"full", @"none" ] containsObject:level]) self.metadataLevel = level;
      }
    }
    if ([p isEqualToString:@"ieee754compatible=true"]) self.coder.IEEE754Compatible = YES;
  }
  return YES;
}

- (void)readPreferences
{
  NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
  NSString *prefer = [self.request valueForHeader:@"Prefer"];
  // Split at commas outside quotes (RFC 7240): include-annotations="-*,Core.*"
  // is one preference.
  NSMutableArray *items = [NSMutableArray array];
  NSMutableString *current = [NSMutableString string];
  BOOL quoted = NO;
  for (NSUInteger i = 0; i < prefer.length; i++) {
    unichar c = [prefer characterAtIndex:i];
    if (c == '"') quoted = !quoted;
    if (c == ',' && !quoted) {
      [items addObject:[current copy]];
      [current setString:@""];
      continue;
    }
    [current appendFormat:@"%C", c];
  }
  if (current.length) [items addObject:current];
  for (NSString *item in items) {
    NSString *part = [[item componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSRange equals = [part rangeOfString:@"="];
    NSString *name = (equals.location == NSNotFound ? part : [part substringToIndex:equals.location]).lowercaseString;
    NSString *value = equals.location == NSNotFound ? @"" : [part substringFromIndex:equals.location + 1];
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
    if ([name isEqualToString:@"maxpagesize"]) name = @"odata.maxpagesize";
    if (name.length) preferences[name] = value;
  }
  self.request.preferences = preferences;
}

#pragma mark Starting

- (void)run
{
  self.request.method = [self.request.method isEqualToString:@"HEAD"] ? @"GET" : self.request.method;
  if (self.principalGiven && !self.authenticated) {
    self.authenticated = YES;
    [self admit:self.request.principal];
    return;
  }
  if (self.authenticated || !self.service.authenticator) {
    [self answer];
    return;
  }
  // Who is asking, first: the authenticator sees the request as the host
  // does, and may take its time.
  self.authenticationRequest = OISHostRequest(self.request.URLRequest);
  HSAuthenticationReply *reply = [[HSAuthenticationReply alloc] initWithTarget:self action:@selector(didAuthenticate:)];
  reply.timeout = self.service.replyTimeout;
  self.authenticating = YES;
  [self.service.authenticator authenticateRequest:self.authenticationRequest reply:reply];
  self.authenticating = NO;
}

// An answer at once goes on here; a later one, in the request's context.
- (void)didAuthenticate:(HSAuthenticationReply *)reply
{
  if (!self.authenticating) {
    [self.request.context performBlock:^{
      [self admitAnswer:reply];
    }];
    return;
  }
  [self admitAnswer:reply];
}

- (void)admitAnswer:(HSAuthenticationReply *)reply
{
  if (self.done) return;
  self.authenticated = YES;
  if (reply.error) {
    [self respondError:reply.error];
    return;
  }
  [self admit:reply.principal];
}

// Who the authenticator found, or the host did: no one is answered 401,
// unless the service lets anyone in (or anyone read $metadata).
- (void)admit:(HSPrincipal *)principal
{
  if (!self.service.authenticator) {
    self.request.principal = principal;
    [self answer];
    return;
  }
  NSString *path = self.request.URLRequest.URL.path ?: @"";
  NSString *root = self.service.serviceRoot.path ?: @"/";
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  BOOL metadata = [path isEqualToString:root] || [path isEqualToString:[root substringToIndex:root.length - 1]] ||
                  [path isEqualToString:[root stringByAppendingString:@"$metadata"]];
  if (!principal && !self.service.allowsAnonymousRequests && !(metadata && self.service.allowsAnonymousMetadata)) {
    [self fail:401 message:@"The request names no one: sign in"];
    return;
  }
  self.request.principal = principal;
  [self answer];
}

- (void)answer
{
  self.phaseStarted = OTNow();
  if (![self negotiateVersion] || ![self readURL]) return;
  NSString *resource = self.request.path.segments.firstObject.name;
  if (resource.length && self.span.recording) {
    self.span.name = [NSString stringWithFormat:@"ODataService %@ %@", self.request.method, resource];
    [self.span setAttribute:resource forKey:@"odata.resource"];
  }
  [self readPreferences];

  NSArray<ODataPathSegment *> *segments = self.request.path.segments;
  if (!segments.count) {
    self.kind = OISTargetServiceDocument;
    [self dispatch];
    return;
  }
  ODataPathSegment *first = segments[0];
  if ([first.name isEqualToString:@"$metadata"] && segments.count == 1) {
    self.kind = OISTargetMetadata;
    [self dispatch];
    return;
  }
  if ([first.name isEqualToString:@"$async"]) {
    [self statusMonitor:segments.count == 2 ? segments[1].name : nil];
    return;
  }
  if ([first.name isEqualToString:@"$batch"]) {
    if (segments.count > 1 || !self.saves) {
      [self fail:(segments.count > 1 ? 404 : 400) message:@"$batch is a resource of its own, and cannot be nested"];
      return;
    }
    // The batch answers the exchange itself, once its requests have.
    self.done = YES;
    OISBatchCall *batch = [[OISBatchCall alloc] initWithService:self.service exchange:self.exchange version:self.request.version
                                                      principal:self.request.principal];
    batch.span = self.span;
    self.span = nil;
    [batch start];
    return;
  }
  ODataEntitySetHandler *handler = first.isCall ? nil : [self.service handlerForEntitySet:first.name];
  OISServedOperation *import = handler ? nil : [self.service.catalog importNamed:first.name];
  if (import) {
    // CountProducts(), Echo(Text='x'): an unqualified name's parentheses
    // read as a key predicate, by name.
    NSDictionary *arguments = first.keys ?: first.arguments;
    if (arguments[@""]) {
      [self fail:400 message:[NSString stringWithFormat:@"The arguments of %@ are given by name", import.name]];
      return;
    }
    self.index = 1;
    [self callOperation:import arguments:arguments];
    return;
  }
  if (!handler) {
    [self fail:404 message:[NSString stringWithFormat:@"The service has no entity set %@", first.name]];
    return;
  }
  self.handler = handler;
  self.entity = handler.entity;
  self.kind = OISTargetCollection;
  if (![self permitsPathThrough:handler.entity from:1]) return;
  // A key is looked for with the index at its segment, and the walk goes on
  // after it.
  self.index = 0;
  if (first.keys) {
    [self findObjectWithParts:first.keys];
    return;
  }
  self.index = 1;
  [self walk];
}

// Along the path, one segment at a time, from the collection or entity at
// self.index.
- (void)walk
{
  NSArray<ODataPathSegment *> *segments = self.request.path.segments;
  while (self.index < segments.count) {
    ODataPathSegment *segment = segments[self.index];
    NSString *name = segment.name;
    switch (self.kind) {
      case OISTargetCollection:
        if ([name isEqualToString:@"$ref"] && self.index + 1 == segments.count && !segment.keys) {
          self.kind = OISTargetReference;
          self.referencesCollection = YES;
          self.index++;
          continue;
        }
        if ([name rangeOfString:@"."].location != NSNotFound) {
          OISServedOperation *operation = [self.service.catalog operationNamed:name boundTo:self.entity collection:YES];
          if (operation) {
            self.index++;
            [self callOperation:operation arguments:segment.arguments];
            return;
          }
          // The Temporal vocabulary's actions, bound to a timeline set.
          for (NSString *prefix in @[ @"Temporal.", @"Org.OData.Temporal.V1." ]) {
            NSString *action = [name hasPrefix:prefix] ? [name substringFromIndex:prefix.length] : nil;
            if (action && [@[ @"Update", @"Upsert", @"Delete" ] containsObject:action] && self.index + 1 == segments.count) {
              [self temporalAction:action];
              return;
            }
          }
        }
        if ([name isEqualToString:@"$count"] && self.index + 1 == segments.count && !segment.keys) {
          self.kind = OISTargetCount;
          self.index++;
          continue;
        }
        if ([name isEqualToString:@"$filter"] && segment.keys.count == 1 && segment.keys[@""]) {
          // The members that pass (Part 2 section 4.12): what it reaches is read.
          NSMutableDictionary *reached = [NSMutableDictionary dictionary];
          [self readExpression:segment.keys[@""] entity:self.entity into:reached];
          if (![self permitsAll:reached]) return;
          if (!self.pathFilters) self.pathFilters = [NSMutableArray array];
          [self.pathFilters addObject:segment.keys[@""]];
          self.index++;
          continue;
        }
        if ([name isEqualToString:@"$each"] && self.index + 1 == segments.count && !segment.keys) {
          self.kind = OISTargetEach;
          self.index++;
          continue;
        }
        if (!segment.keys && !segment.isCall && ![name hasPrefix:@"$"] && [name rangeOfString:@"."].location == NSNotFound &&
            [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)].count == 1) {
          // A key as a segment: Products/1 (Part 2 section 4.3.6).
          [self findObjectWithParts:@{ @"": [self literalForKeySegment:name] }];
          return;
        }
        if ([name rangeOfString:@"."].location != NSNotFound && !segment.keys && !segment.isCall) {
          // A type cast: the members of that derived type (Part 2 section 4.11).
          NSEntityDescription *derived = [self entityForTypeName:name];
          if (derived && [derived isKindOfEntity:self.entity]) {
            self.entity = derived;
            self.index++;
            continue;
          }
        }
        [self fail:404 message:[NSString stringWithFormat:@"%@ cannot follow a collection here", name]];
        return;
      case OISTargetEntity: {
        if ([name rangeOfString:@"."].location != NSNotFound) {
          OISServedOperation *operation = [self.service.catalog operationNamed:name boundTo:self.object.entity collection:NO];
          if (operation) {
            self.index++;
            [self callOperation:operation arguments:segment.arguments];
            return;
          }
        }
        if ([name isEqualToString:@"$ref"] && self.index + 1 == segments.count && !segment.keys) {
          self.kind = OISTargetReference;
          self.index++;
          continue;
        }
        if ([name rangeOfString:@"."].location != NSNotFound && !segment.keys && !segment.isCall) {
          NSEntityDescription *derived = [self entityForTypeName:name];
          if (derived) {
            if (![self.object.entity isKindOfEntity:derived]) {
              [self fail:404 message:[NSString stringWithFormat:@"That %@ is not a %@", self.object.entity.name, name]];
              return;
            }
            self.index++;
            continue;
          }
        }
        if ([name isEqualToString:@"$value"]) {
          // A media entity's media resource (Part 1 section 11.1.2).
          NSAttributeDescription *media = [self.service.writer mediaAttributeOfEntity:self.object.entity];
          if (!media) {
            [self fail:400 message:[NSString stringWithFormat:@"%@ is not a media entity", self.object.entity.name]];
            return;
          }
          self.attribute = media;
          self.kind = OISTargetStream;
          self.index++;
          continue;
        }
        if ([name isEqualToString:@"$ref"] || [name rangeOfString:@"."].location != NSNotFound) {
          [self fail:501 message:[NSString stringWithFormat:@"%@ is not supported", name]];
          return;
        }
        NSPropertyDescription *property = [self.mapper propertyForWireName:name entity:self.object.entity];
        if (!property) {
          [self fail:404 message:[NSString stringWithFormat:@"%@ has no property %@", self.object.entity.name, name]];
          return;
        }
        if ([property isKindOfClass:[NSAttributeDescription class]]) {
          if (segment.keys) {
            [self fail:400 message:[NSString stringWithFormat:@"%@ is not a collection", name]];
            return;
          }
          self.attribute = (NSAttributeDescription *)property;
          if (![self.service.writer typeNameForAttribute:self.attribute]) {
            [self fail:404 message:[NSString stringWithFormat:@"%@ has no property %@", self.object.entity.name, name]];
            return;
          }
          self.kind = [self.service.writer isStreamAttribute:self.attribute] ? OISTargetStream : OISTargetProperty;
          self.index++;
          if (self.kind == OISTargetStream) continue;
          if (self.index < segments.count && [segments[self.index].name isEqualToString:@"$value"]) {
            self.kind = OISTargetValue;
            self.index++;
          }
          continue;
        }
        NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
        ODataEntitySetHandler *handler = [self.service handlerForEntity:relationship.destinationEntity];
        if (!handler) {
          [self fail:404 message:[NSString stringWithFormat:@"%@ leads to no entity set", name]];
          return;
        }
        // A write's path, going on, reads the entity it is of (a read's did,
        // reaching it) -- unless it writes that entity's navigation ($ref);
        // then reaches the set it leads to.
        BOOL read = [self.request.method isEqualToString:@"GET"];
        if ((!read && ![self permitsPathThrough:self.object.entity from:self.index]) ||
            ![self permitsPathThrough:relationship.destinationEntity from:self.index + 1]) {
          return;
        }
        self.handler = handler;
        if (relationship.isToMany) {
          self.parent = self.object;
          self.navigation = relationship;
          self.object = nil;
          self.entity = relationship.destinationEntity;
          self.kind = OISTargetCollection;
          self.index++;
          if (segment.keys) {
            self.index--;
            [self findObjectWithParts:segment.keys];
            return;
          }
          continue;
        }
        if (segment.keys) {
          [self fail:400 message:[NSString stringWithFormat:@"%@ is not a collection", name]];
          return;
        }
        NSManagedObject *related = [self.object valueForKey:relationship.name];
        NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
        if (related && visible && ![visible evaluateWithObject:related]) related = nil;
        self.referrer = self.object;
        self.referrerNavigation = relationship;
        if (self.index + 2 == segments.count && [segments[self.index + 1].name isEqualToString:@"$ref"]) {
          // Products(1)/Category/$ref: the reference, which may be null.
          self.object = related;
          self.entity = relationship.destinationEntity;
          self.kind = OISTargetReference;
          self.index += 2;
          continue;
        }
        if (!related) {
          // A single-valued navigation property that is null (Part 1 section 11.2.6).
          [self respondStatus:204 headers:@{} body:nil];
          return;
        }
        self.object = related;
        self.entity = related.entity;
        self.index++;
        continue;
      }
      default:
        [self fail:400 message:[NSString stringWithFormat:@"%@ cannot follow a property value", name]];
        return;
    }
  }
  [self dispatch];
}

// Whether the rest of the path, from index, goes on from the entity to
// another set -- a navigation, or a bound operation, called on what the
// path reached -- rather than ending at it: its properties, its $value, a
// cast, $count, $each, a temporal action, or a navigation's $ref (which
// writes this entity's navigation property).
- (BOOL)pathLeaves:(NSEntityDescription *)entity from:(NSUInteger)index
{
  NSArray<ODataPathSegment *> *segments = self.request.path.segments;
  for (NSUInteger i = index; i < segments.count; i++) {
    ODataPathSegment *segment = segments[i];
    NSString *name = segment.name;
    if ([name hasPrefix:@"$"]) continue;
    if ([name rangeOfString:@"."].location != NSNotFound) {
      NSEntityDescription *derived = segment.isCall || segment.keys ? nil : [self entityForTypeName:name];
      if (derived) {
        entity = derived;
        continue;
      }
      if ([name hasPrefix:@"Temporal."] || [name hasPrefix:@"Org.OData.Temporal.V1."]) continue;
      return YES;
    }
    NSPropertyDescription *property = entity ? [self.mapper propertyForWireName:name entity:entity] : nil;
    if (![property isKindOfClass:[NSRelationshipDescription class]]) continue;  // a property, a key segment
    return !(i + 2 == segments.count && [segments[i + 1].name isEqualToString:@"$ref"]);
  }
  return NO;
}

// Every set the path reaches is read -- the one it ends at too, unless the
// request writes it, which the write's own permission covers: checked as
// the walk gets there, before any row of it is looked for.
- (BOOL)permitsPathThrough:(NSEntityDescription *)entity from:(NSUInteger)index
{
  if (![self.request.method isEqualToString:@"GET"] && ![self pathLeaves:entity from:index]) return YES;
  return [self permitsTo:OISAccessRead entity:entity];
}

- (ODataExpression *)literalForKeySegment:(NSString *)text
{
  NSAttributeDescription *key = [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)].firstObject;
  // A string key is written bare in a segment; anything else as its literal.
  if (key.attributeType == NSStringAttributeType) {
    NSString *quoted = [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
    return [ODataExpression expressionWithString:quoted error:NULL];
  }
  return [ODataExpression expressionWithString:text error:NULL];
}

// A key predicate's parts as Core Data values, by attribute name.
- (NSDictionary *)keyFromParts:(NSDictionary<NSString *, ODataExpression *> *)parts entity:(NSEntityDescription *)entity
{
  NSArray<NSAttributeDescription *> *attributes = [self.mapper keyAttributesForEntity:OISRootEntity(entity)];
  if (!attributes.count) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ has no key", entity.name]];
    return nil;
  }
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in attributes) {
    NSString *wire = [self.mapper propertyForAttribute:attribute];
    ODataExpression *part = parts[wire];
    if (!part && attributes.count == 1 && parts.count == 1) part = parts[@""];
    while (part.kind == ODataExpressionAlias) part = self.request.options.aliases[part.name];
    if (!part || part.kind != ODataExpressionLiteral) {
      [self fail:400 message:[NSString stringWithFormat:@"The key of %@ needs %@", entity.name, wire]];
      return nil;
    }
    id value = part.value ? [self.coder coreDataValueForJSON:part.value attribute:attribute] : nil;
    if (!value || value == [NSNull null]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", part, wire]];
      return nil;
    }
    key[attribute.name] = value;
  }
  if (parts.count > attributes.count) {
    [self fail:400 message:[NSString stringWithFormat:@"The key of %@ has %lu parts", entity.name, (unsigned long)attributes.count]];
    return nil;
  }
  return key;
}

- (void)findObjectWithParts:(NSDictionary *)parts
{
  NSDictionary *key = [self keyFromParts:parts entity:self.entity];
  if (!key) return;
  self.lookedUpKey = key;
  ODataReply *reply = [self replyWithAction:@selector(didFindObject:)];
  NSManagedObject *object = [self.handler objectWithKey:key request:self.request reply:reply];
  [reply returned:object];
}

- (void)didFindObject:(ODataReply *)reply
{
  if (reply.error) {
    [self respondError:reply.error];
    return;
  }
  NSManagedObject *object = reply.result;
  if (object && self.parent && self.navigation) {
    id members = [self.parent valueForKey:self.navigation.name];
    if (![members containsObject:object]) object = nil;
  }
  if (!object) {
    if ([self upsertsMissingEntity]) return;
    [self fail:404 message:[NSString stringWithFormat:@"%@ has no such entity", self.request.path.segments[self.index > 0 ? self.index - 1 : 0].name]];
    return;
  }
  self.object = object;
  self.entity = object.entity;
  self.kind = OISTargetEntity;
  self.referrer = self.parent;
  self.referrerNavigation = self.navigation;
  self.parent = nil;
  self.navigation = nil;
  self.index++;
  [self walk];
}

// PATCH or PUT to an entity set's key that names no entity: an upsert
// creates it (ODataEntitySetHandler's allowsUpsert). Not through a
// navigation property, and only as the path's last segment.
- (BOOL)upsertsMissingEntity
{
  NSString *method = self.request.method;
  if (![method isEqualToString:@"PATCH"] && ![method isEqualToString:@"PUT"]) return NO;
  if (self.parent || self.index + 1 != self.request.path.segments.count) return NO;
  if (!self.handler.allowsInsert || !self.handler.allowsUpsert || !self.lookedUpKey) return NO;
  if ([self ifMatchHeader]) {
    [self fail:412 message:@"There is no such entity to match"];
    return YES;
  }
  self.index++;
  if (![self negotiateFormat]) return YES;
  self.request.entity = self.entity;
  [self insertWithKey:self.lookedUpKey];
  return YES;
}

#pragma mark Dispatch

- (void)dispatch
{
  if (![self negotiateFormat]) return;
  NSString *method = self.request.method;
  self.request.entity = self.entity;
  switch (self.kind) {
    case OISTargetServiceDocument:
      if ([method isEqualToString:@"GET"]) [self serviceDocument];
      else [self methodNotAllowed:@[ @"GET" ]];
      return;
    case OISTargetMetadata:
      if ([method isEqualToString:@"GET"] && self.metadataAsJSON) {
        NSError *error = nil;
        NSData *xml = [[self.service metadataXMLForVersion:self.request.version] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *json = [ODataCSDL JSONDataForXMLData:xml error:&error];
        if (!json) {
          [self respondError:ODataServiceError(500, error.localizedDescription)];
          return;
        }
        [self respondStatus:200 headers:@{ @"Content-Type": @"application/json;charset=utf-8" } body:json];
      } else if ([method isEqualToString:@"GET"]) {
        [self respondText:[self.service metadataXMLForVersion:self.request.version] contentType:@"application/xml;charset=utf-8" headers:nil];
      } else {
        [self methodNotAllowed:@[ @"GET" ]];
      }
      return;
    case OISTargetCollection:
      if ([method isEqualToString:@"GET"]) [self readCollection];
      else if ([method isEqualToString:@"POST"] && !self.pathFilters.count) [self insert];
      else if ([method isEqualToString:@"PATCH"]) [self updateCollection];
      else if ([method isEqualToString:@"PUT"] && !self.pathFilters.count) [self replaceCollection];
      else [self methodNotAllowed:self.pathFilters.count ? @[ @"GET" ] : @[ @"GET", @"POST", @"PATCH", @"PUT" ]];
      return;
    case OISTargetEach:
      if ([method isEqualToString:@"PATCH"]) [self updateEach];
      else if ([method isEqualToString:@"DELETE"]) [self removeEach];
      else [self methodNotAllowed:@[ @"PATCH", @"DELETE" ]];
      return;
    case OISTargetCount:
      if ([method isEqualToString:@"GET"]) [self readCount];
      else [self methodNotAllowed:@[ @"GET" ]];
      return;
    case OISTargetEntity:
      if ([method isEqualToString:@"GET"]) [self readEntity];
      else if ([method isEqualToString:@"PATCH"] || [method isEqualToString:@"MERGE"]) [self updateReplacing:NO];
      else if ([method isEqualToString:@"PUT"]) [self updateReplacing:YES];
      else if ([method isEqualToString:@"DELETE"]) [self remove];
      else [self methodNotAllowed:@[ @"GET", @"PATCH", @"PUT", @"DELETE" ]];
      return;
    case OISTargetOperation:
      if ([method isEqualToString:(self.operation.isAction ? @"POST" : @"GET")]) [self invokeOperation];
      else [self methodNotAllowed:@[ self.operation.isAction ? @"POST" : @"GET" ]];
      return;
    case OISTargetProperty:
    case OISTargetValue:
      if ([method isEqualToString:@"GET"]) [self readProperty];
      else if ([@[ @"PUT", @"PATCH", @"DELETE" ] containsObject:method]) [self writeProperty];
      else [self methodNotAllowed:@[ @"GET", @"PUT", @"PATCH", @"DELETE" ]];
      return;
    case OISTargetStream: {
      // A stream property can be emptied; a media entity is deleted whole.
      BOOL property = [self.service.writer isStreamAttribute:self.attribute];
      if ([method isEqualToString:@"GET"]) [self readStream];
      else if ([method isEqualToString:@"PUT"]) [self writeStream];
      else if (property && [method isEqualToString:@"DELETE"]) [self writeStream];
      else [self methodNotAllowed:property ? @[ @"GET", @"PUT", @"DELETE" ] : @[ @"GET", @"PUT" ]];
      return;
    }
    case OISTargetReference:
      if ([method isEqualToString:@"GET"]) [self readReference];
      else if ([@[ @"PUT", @"POST", @"DELETE" ] containsObject:method]) [self writeReference];
      else [self methodNotAllowed:@[ @"GET", @"PUT", @"POST", @"DELETE" ]];
      return;
  }
}

#pragma mark URLs

- (NSString *)rootString
{
  NSString *root = self.service.serviceRoot.absoluteString;
  return [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
}

- (NSString *)contextBase
{
  return [[self rootString] stringByAppendingString:@"$metadata"];
}

// Products(1), OrderItems(OrderID=1,ItemNo=2): an entity's canonical path.
- (NSString *)canonicalPathOf:(NSManagedObject *)object
{
  return [self canonicalPathOfValues:object entity:object.entity];
}

// The same from the key's values by attribute name (a deletion's
// tombstone); nil when one is missing.
- (NSString *)canonicalPathOfValues:(id)values entity:(NSEntityDescription *)entity
{
  NSEntityDescription *root = OISRootEntity(entity);
  NSArray<NSAttributeDescription *> *key = [self.mapper keyAttributesForEntity:root];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSAttributeDescription *attribute in key) {
    id value = [values valueForKey:attribute.name];
    if (!value || value == [NSNull null]) return nil;
    NSString *literal = [self.coder literalForValue:value attribute:attribute];
    [parts addObject:key.count == 1 ? literal : [NSString stringWithFormat:@"%@=%@", [self.mapper propertyForAttribute:attribute], literal]];
  }
  return [NSString stringWithFormat:@"%@(%@)", [self.service entitySetForEntity:root], [parts componentsJoinedByString:@","]];
}

- (NSString *)selectListForOptions:(ODataQueryOptions *)options
{
  NSMutableArray *items = [NSMutableArray array];
  for (ODataSelectItem *item in options.select) [items addObject:item.isStar ? @"*" : [item.path componentsJoinedByString:@"/"]];
  BOOL v401 = [self.request.version isEqualToString:@"4.01"];
  for (ODataExpandItem *item in options.expand) {
    if (item.isStar || item.isRef || item.isCount) continue;
    NSString *nested = [self selectListForOptions:item.options];
    if (nested.length) {
      [items addObject:[NSString stringWithFormat:@"%@%@", [item.path componentsJoinedByString:@"/"], nested]];
    } else if (v401) {
      [items addObject:[NSString stringWithFormat:@"%@()", [item.path componentsJoinedByString:@"/"]]];
    }
  }
  return items.count ? [NSString stringWithFormat:@"(%@)", [items componentsJoinedByString:@","]] : @"";
}

#pragma mark ETags

- (NSString *)etagOf:(NSManagedObject *)object
{
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:object.entity];
  if (version) return [NSString stringWithFormat:@"W/\"%@\"", [object valueForKey:version.name] ?: @0];
  // A hash of the values, in a fixed order: it changes when they do.
  uint64_t hash = 14695981039346656037ULL;
  NSArray *names = [object.entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSAttributeDescription *attribute = object.entity.attributesByName[name];
    if (attribute.isTransient) continue;
    // Streams have ETags of their own. The bag of dynamic properties is
    // served, as they are.
    BOOL bag = [self.mapper attributeHoldsDynamicProperties:attribute];
    if ((!bag && ![self.service.writer typeNameForAttribute:attribute]) || [self.service.writer isStreamAttribute:attribute]) continue;
    id json = [self.coder JSONForCoreDataValue:[object valueForKey:name] attribute:attribute];
    NSString *text = [NSString stringWithFormat:@"%@=%@;", name, json];
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
      hash ^= p[i];
      hash *= 1099511628211ULL;
    }
  }
  return [NSString stringWithFormat:@"W/\"%016llx\"", (unsigned long long)hash];
}

#pragma mark Serialising

#pragma mark Streams

// A stream's ETag: a hash of its bytes.
- (NSString *)mediaEtagOf:(NSData *)data
{
  uint64_t hash = 14695981039346656037ULL;
  const uint8_t *p = data.bytes;
  for (NSUInteger i = 0; i < data.length; i++) {
    hash ^= p[i];
    hash *= 1099511628211ULL;
  }
  return [NSString stringWithFormat:@"W/\"%016llx-%lx\"", (unsigned long long)hash, (unsigned long)data.length];
}

- (NSString *)contentTypeOfStream:(NSAttributeDescription *)stream of:(NSManagedObject *)object
{
  NSAttributeDescription *where = [self.service.writer contentTypeAttributeOfStream:stream];
  NSString *type = where ? [object valueForKey:where.name] : nil;
  return type.length ? type : @"application/octet-stream";
}

// Its control information (JSON Format section 4.5.10-13): the media ETag
// and content type of a stream there is, and at metadata=full its links.
// prefix: the stream property's name, or @"" for the media resource.
- (void)describeStream:(NSAttributeDescription *)stream of:(NSManagedObject *)object prefix:(NSString *)prefix
                  full:(BOOL)full into:(NSMutableDictionary *)json
{
  NSData *data = [object valueForKey:stream.name];
  if (full) {
    NSString *link = [NSString stringWithFormat:@"%@/%@", [self canonicalPathOf:object], prefix.length ? prefix : @"$value"];
    json[[prefix stringByAppendingString:@"@odata.mediaReadLink"]] = link;
    json[[prefix stringByAppendingString:@"@odata.mediaEditLink"]] = link;
  }
  if (!data) return;
  json[[prefix stringByAppendingString:@"@odata.mediaEtag"]] = [self mediaEtagOf:data];
  json[[prefix stringByAppendingString:@"@odata.mediaContentType"]] = [self contentTypeOfStream:stream of:object];
}

// GET a stream: its bytes as they were put, with their content type and
// media ETag; none (204) for a stream property without one.
- (void)readStream
{
  NSData *data = [self.object valueForKey:self.attribute.name];
  if (!data) {
    [self respondStatus:204 headers:@{} body:nil];
    return;
  }
  NSString *etag = [self mediaEtagOf:data];
  NSString *unless = [self.request valueForHeader:@"If-None-Match"];
  for (NSString *tag in [unless componentsSeparatedByString:@","]) {
    NSString *t = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([t isEqualToString:etag] || [t isEqualToString:@"*"]) {
      [self respondStatus:304 headers:@{ @"ETag": etag } body:nil];
      return;
    }
  }
  [self respondStatus:200 headers:@{ @"Content-Type": [self contentTypeOfStream:self.attribute of:self.object], @"ETag": etag } body:data];
}

- (NSArray<NSAttributeDescription *> *)servedAttributesOf:(NSEntityDescription *)entity
{
  // Sorted by name: -properties has no specified order.
  NSMutableArray *attributes = [NSMutableArray array];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attribute = entity.attributesByName[name];
    if ([self.service.writer typeNameForAttribute:attribute]) [attributes addObject:attribute];
  }
  return attributes;
}

- (NSMutableDictionary *)JSONForObject:(NSManagedObject *)object
                               options:(ODataQueryOptions *)options
                              expected:(NSEntityDescription *)expected
                                 error:(NSError **)error
{
  NSMutableDictionary *json = [NSMutableDictionary dictionary];
  BOOL none = [self.metadataLevel isEqualToString:@"none"];
  BOOL full = [self.metadataLevel isEqualToString:@"full"];
  if (!none) json[@"@odata.etag"] = [self etagOf:object];
  if (full || (!none && expected && object.entity != expected)) {
    json[@"@odata.type"] = [@"#" stringByAppendingString:[self.service.writer typeNameForEntity:object.entity]];
  }
  if (full) {
    NSString *path = [self canonicalPathOf:object];
    json[@"@odata.id"] = path;
    json[@"@odata.editLink"] = path;
  }

  NSArray<NSAttributeDescription *> *attributes = [self servedAttributesOf:object.entity];
  ODataEntitySetHandler *handler = [self.service handlerForEntity:object.entity];
  BOOL star = !options.select.count;
  NSMutableSet *selected = [NSMutableSet set];
  for (ODataSelectItem *item in options.select) {
    if (item.isStar) {
      star = YES;
      continue;
    }
    if (item.path.count == 2 && [item.path[0] rangeOfString:@"."].location != NSNotFound) {
      // Default.Manager/Budget: the property, of the objects of that type.
      NSEntityDescription *derived = [self entityForTypeName:item.path[0]];
      NSPropertyDescription *property = derived ? [self.mapper propertyForWireName:item.path[1] entity:derived] : nil;
      if (!property) {
        if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"$select=%@ names no property", [item.path componentsJoinedByString:@"/"]]);
        return nil;
      }
      if ([object.entity isKindOfEntity:derived]) [selected addObject:property.name];
      continue;
    }
    if (item.path.count != 1 && ![self.mapper propertyForWireName:item.path[0] entity:object.entity]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", object.entity.name, item.path[0]]);
      return nil;
    }
    if (item.path.count != 1) {
      if (error) *error = ODataServiceError(501, [NSString stringWithFormat:@"$select=%@ is not supported", [item.path componentsJoinedByString:@"/"]]);
      return nil;
    }
    if ([self computedNamesOf:options][item.path[0]]) {
      [selected addObject:item.path[0]];
      continue;
    }
    NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:object.entity];
    if (!property && handler.isOpenType) {
      [selected addObject:item.path[0]];  // a dynamic property's
      continue;
    }
    if (!property && ![self.mapper propertyForWireName:item.path[0] entity:expected ?: object.entity]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", object.entity.name, item.path[0]]);
      return nil;
    }
    if (property) [selected addObject:property.name];
  }
  NSAttributeDescription *media = [self.service.writer mediaAttributeOfEntity:object.entity];
  if (media && !none) [self describeStream:media of:object prefix:@"" full:full into:json];
  for (NSAttributeDescription *attribute in attributes) {
    if (!star && ![selected containsObject:attribute.name]) continue;
    if ([self.service.writer isStreamAttribute:attribute]) {
      // A stream is not in the payload, only what is known of it.
      if (!none) [self describeStream:attribute of:object prefix:[self.mapper propertyForAttribute:attribute] full:full into:json];
      continue;
    }
    json[[self.mapper propertyForAttribute:attribute]] = [self.coder JSONForCoreDataValue:[object valueForKey:attribute.name] attribute:attribute];
  }
  NSDictionary *dynamic = handler.isOpenType ? self.planDynamic[object.objectID] : nil;
  for (NSString *name in ([dynamic isKindOfClass:[NSDictionary class]] ? dynamic : nil)) {
    if ([name hasPrefix:@"@"] || [self.mapper propertyForWireName:name entity:object.entity]) continue;
    if (!star && ![selected containsObject:name]) continue;
    // Typed where JSON alone does not say: a date is a string, and a
    // number could be any of them.
    NSString *type = [self.coder dynamicTypeNameOfValue:dynamic[name]];
    json[name] = [self.coder JSONForValue:dynamic[name] typeName:type];
    if (type && !none) json[[name stringByAppendingString:@"@odata.type"]] = [@"#" stringByAppendingString:[type substringFromIndex:4]];
  }
  // $compute's values: of the request, or of the expansion.
  for (ODataComputeItem *item in options.compute) {
    if (!star && ![selected containsObject:item.alias]) continue;
    id value = [self computedValue:item of:object options:options error:error];
    if (!value) return nil;
    json[item.alias] = value;
  }
  for (ODataExpandItem *item in options.expand) {
    if (![self expand:item of:object into:json error:error]) return nil;
  }
  return json;
}

// $levels=max is taken as this deep, and no object is expanded inside
// itself (Part 2 section 5.1.3.1).
static const NSInteger OISMaxLevels = 32;

- (BOOL)expand:(ODataExpandItem *)item of:(NSManagedObject *)object into:(NSMutableDictionary *)json error:(NSError **)error
{
  NSNumber *levels = item.options.levels;
  NSInteger depth = !levels ? 1 : levels.integerValue < 0 ? OISMaxLevels : MAX(levels.integerValue, 1);
  return [self expand:item of:object into:json levels:depth path:[NSMutableSet setWithObject:object.objectID] error:error];
}

// One level further down the same navigation property, while $levels
// allows and the object is not one it came through.
- (BOOL)expandLevels:(ODataExpandItem *)item of:(NSManagedObject *)object into:(NSMutableDictionary *)json
              levels:(NSInteger)levels path:(NSMutableSet *)path error:(NSError **)error
{
  if (levels <= 1 || item.isRef || item.isCount || item.path.count != 1) return YES;
  if (![[self.mapper propertyForWireName:item.path[0] entity:object.entity] isKindOfClass:[NSRelationshipDescription class]]) return YES;
  if ([path containsObject:object.objectID]) return YES;
  [path addObject:object.objectID];
  BOOL ok = [self expand:item of:object into:json levels:levels - 1 path:path error:error];
  [path removeObject:object.objectID];
  return ok;
}

- (BOOL)expand:(ODataExpandItem *)item
            of:(NSManagedObject *)object
          into:(NSMutableDictionary *)json
        levels:(NSInteger)levels
          path:(NSMutableSet *)path
         error:(NSError **)error
{
  ODataQueryOptions *options = item.options;
  NSMutableArray<NSRelationshipDescription *> *relationships = [NSMutableArray array];
  if (item.isStar) {
    for (NSRelationshipDescription *relationship in object.entity.relationshipsByName.allValues) {
      if (![self.mapper servesProperty:relationship]) continue;
      if ([self.service handlerForEntity:relationship.destinationEntity]) [relationships addObject:relationship];
    }
  } else {
    if (item.path.count != 1) {
      if (error) *error = ODataServiceError(501, [NSString stringWithFormat:@"$expand=%@ is not supported", [item.path componentsJoinedByString:@"/"]]);
      return NO;
    }
    NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:object.entity];
    if (![property isKindOfClass:[NSRelationshipDescription class]]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no navigation property %@", object.entity.name, item.path[0]]);
      return NO;
    }
    [relationships addObject:(NSRelationshipDescription *)property];
  }

  for (NSRelationshipDescription *relationship in relationships) {
    NSString *wire = [self.mapper propertyForRelationship:relationship];
    NSEntityDescription *destination = relationship.destinationEntity;
    // What the plan read: this object's members, as the options say, and
    // the options they are written with (their $these in).
    NSDictionary *entry = [self nestedMembersOf:item relationship:relationship.name parent:object];
    if (!entry) {
      if (error) *error = ODataServiceError(500, [NSString stringWithFormat:@"$expand=%@ was not read for %@", wire, object.entity.name]);
      return NO;
    }
    NSArray *members = entry[@"members"];
    ODataQueryOptions *written = entry[@"options"] ?: options;

    if (!relationship.isToMany) {
      NSManagedObject *related = members.firstObject;
      if (item.isRef) {
        json[wire] = related ? @{ @"@odata.id": [self canonicalPathOf:related] } : [NSNull null];
      } else {
        id nested = related ? [self JSONForObject:related options:written expected:destination error:error] : [NSNull null];
        if (!nested) return NO;
        if (related && ![self expandLevels:item of:related into:nested levels:levels path:path error:error]) return NO;
        json[wire] = nested;
      }
      continue;
    }

    if (options.includeCount.boolValue || item.isCount) json[[wire stringByAppendingString:@"@odata.count"]] = entry[@"count"];
    if (item.isCount) continue;
    NSMutableArray *values = [NSMutableArray array];
    for (NSManagedObject *member in members) {
      if (item.isRef) {
        [values addObject:@{ @"@odata.id": [self canonicalPathOf:member] }];
        continue;
      }
      NSMutableDictionary *nested = [self JSONForObject:member options:written expected:destination error:error];
      if (!nested) return NO;
      if (![self expandLevels:item of:member into:nested levels:levels path:path error:error]) return NO;
      [values addObject:nested];
    }
    json[wire] = values;
  }
  return YES;
}

#pragma mark Reads

- (void)serviceDocument
{
  NSMutableArray *sets = [NSMutableArray array];
  for (NSString *name in self.service.entitySets) {
    [sets addObject:@{ @"name": name, @"kind": @"EntitySet", @"url": name }];
  }
  [self respondJSON:@{ @"@odata.context": [self contextBase], @"value": sets } status:200 headers:nil];
}

- (NSString *)setName
{
  return [self.service entitySetForEntity:OISRootEntity(self.entity)];
}

// $search as a predicate over the entity's searchable string properties:
// a word or phrase, CONTAINS[cd] in any of them. nil, answered, when the
// set cannot be searched.
- (NSPredicate *)predicateForSearch:(ODataSearchExpression *)search entity:(NSEntityDescription *)entity
{
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  NSSet *allowed = handler.searchableProperties;
  NSMutableArray *names = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self servedAttributesOf:entity]) {
    if (attribute.attributeType != NSStringAttributeType) continue;
    if (allowed && ![allowed containsObject:[self.mapper propertyForAttribute:attribute]]) continue;
    NSString *type = [self.service.writer typeNameForAttribute:attribute];
    if (![type isEqualToString:@"Edm.String"]) continue;  // an enumeration, a time of day: not text to search
    [names addObject:attribute.name];
  }
  if (!names.count) {
    [self fail:501 message:[NSString stringWithFormat:@"%@ cannot be searched", entity.name]];
    return nil;
  }
  return [self predicateForSearch:search attributes:names];
}

- (NSPredicate *)predicateForSearch:(ODataSearchExpression *)search attributes:(NSArray<NSString *> *)names
{
  switch (search.kind) {
    case ODataSearchWord:
    case ODataSearchPhrase: {
      NSMutableArray *any = [NSMutableArray array];
      for (NSString *name in names) {
        [any addObject:[NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:name]
                                                          rightExpression:[NSExpression expressionForConstantValue:search.text]
                                                                 modifier:NSDirectPredicateModifier
                                                                     type:NSContainsPredicateOperatorType
                                                                  options:NSCaseInsensitivePredicateOption | NSDiacriticInsensitivePredicateOption]];
      }
      return any.count == 1 ? any.firstObject : [NSCompoundPredicate orPredicateWithSubpredicates:any];
    }
    case ODataSearchAnd:
    case ODataSearchOr: {
      NSArray *both = @[ [self predicateForSearch:search.left attributes:names], [self predicateForSearch:search.right attributes:names] ];
      return search.kind == ODataSearchAnd ? [NSCompoundPredicate andPredicateWithSubpredicates:both]
                                           : [NSCompoundPredicate orPredicateWithSubpredicates:both];
    }
    case ODataSearchNot:
      return [NSCompoundPredicate notPredicateWithSubpredicate:[self predicateForSearch:search.operand attributes:names]];
  }
  return [NSPredicate predicateWithValue:NO];
}

// The predicate a collection's rows answer to: the filter, the navigation
// they were reached through, and what the set lets the caller see.
- (NSPredicate *)collectionPredicateWithFilter:(BOOL)withFilter error:(NSError **)error
{
  NSMutableArray *parts = [NSMutableArray array];
  if (withFilter && self.request.options.filter) {
    NSPredicate *filter = [self.predicates predicateForExpression:[self resolved:self.request.options.filter options:self.request.options]
                                                                   entity:self.entity
                                                                  aliases:self.request.options.aliases
                                                                 computed:[self computedNamesOf:self.request.options]
                                                                  spans:self.planSpans
                                                                    error:error];
    if (!filter) return nil;
    [parts addObject:filter];
  }
  if (withFilter && [self applyIsFiltersOnly]) {
    for (ODataApplyTransformation *t in self.request.options.apply) {
      NSPredicate *filter = [self.predicates predicateForExpression:[self hierarchical:t.filter] entity:self.entity
                                                                   aliases:self.request.options.aliases
                                                                  computed:[self computedNamesOf:self.request.options]
                                                                   spans:self.planSpans error:error];
      if (!filter) return nil;
      [parts addObject:filter];
    }
  }
  if (withFilter && self.request.options.temporalText.count) {
    NSPredicate *period = [self predicateForApplicationTimeOf:self.request.options entity:self.entity error:error];
    if (!period) return nil;
    if (period != (id)[NSNull null]) [parts addObject:period];
  }
  if (withFilter && self.request.options.searchExpression) {
    NSPredicate *search = [self predicateForSearch:self.request.options.searchExpression entity:self.entity];
    if (!search) return nil;
    [parts addObject:search];
  }
  if (self.members) [parts addObject:[self predicateForObjects:self.members]];
  if (self.parent && self.navigation) {
    NSPredicate *members = [self membersOfNavigation];
    if (!members) {
      if (error) *error = ODataServiceError(500, [NSString stringWithFormat:@"%@ has no key to follow %@ by", self.parent.entity.name, self.navigation.name]);
      return nil;
    }
    [parts addObject:members];
  }
  NSPredicate *visible = [self.handler predicateForVisibleObjectsInRequest:self.request];
  if (visible) [parts addObject:visible];
  if (!parts.count) return [NSPredicate predicateWithValue:YES];
  return parts.count == 1 ? parts[0] : [NSCompoundPredicate andPredicateWithSubpredicates:parts];
}

static NSPredicate *OISEquals(NSString *keyPath, id value, NSComparisonPredicateModifier modifier)
{
  return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:keyPath]
                                            rightExpression:[NSExpression expressionForConstantValue:value]
                                                   modifier:modifier
                                                       type:NSEqualToPredicateOperatorType
                                                    options:0];
}

// These objects, by key: id IN (1, 2), or one AND of the key's parts each.
- (NSPredicate *)predicateForObjects:(NSArray<NSManagedObject *> *)objects
{
  NSArray<NSAttributeDescription *> *key = [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)];
  if (key.count == 1) {
    return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:key[0].name]
                                              rightExpression:[NSExpression expressionForConstantValue:[objects valueForKey:key[0].name]]
                                                     modifier:NSDirectPredicateModifier
                                                         type:NSInPredicateOperatorType
                                                      options:0];
  }
  NSMutableArray *each = [NSMutableArray array];
  for (NSManagedObject *object in objects) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSAttributeDescription *attribute in key) [parts addObject:OISEquals(attribute.name, [object valueForKey:attribute.name], NSDirectPredicateModifier)];
    [each addObject:[NSCompoundPredicate andPredicateWithSubpredicates:parts]];
  }
  return each.count ? [NSCompoundPredicate orPredicateWithSubpredicates:each] : [NSPredicate predicateWithValue:NO];
}

// The rows a navigation property leads to, by key rather than by object:
// category.id == 2, ANY suppliers.id == 2. Every store can compare
// attributes; not every store compares managed objects in a fetch
// (FreeCoreData's in-memory store matches none, and cannot count them).
- (NSPredicate *)membersOfNavigation
{
  NSRelationshipDescription *inverse = self.navigation.inverseRelationship;
  NSArray<NSAttributeDescription *> *parentKey = [self.mapper keyAttributesForEntity:OISRootEntity(self.parent.entity)];
  if (inverse && parentKey.count) {
    if (parentKey.count == 1) {
      NSString *path = [NSString stringWithFormat:@"%@.%@", inverse.name, parentKey[0].name];
      return OISEquals(path, [self.parent valueForKey:parentKey[0].name], inverse.isToMany ? NSAnyPredicateModifier : NSDirectPredicateModifier);
    }
    if (!inverse.isToMany) {
      NSMutableArray *parts = [NSMutableArray array];
      for (NSAttributeDescription *attribute in parentKey) {
        [parts addObject:OISEquals([NSString stringWithFormat:@"%@.%@", inverse.name, attribute.name],
                                   [self.parent valueForKey:attribute.name], NSDirectPredicateModifier)];
      }
      return [NSCompoundPredicate andPredicateWithSubpredicates:parts];
    }
  }
  // No inverse, or a compound key on the far side of a to-many one: the
  // members' own keys.
  NSArray<NSAttributeDescription *> *key = [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)];
  if (!key.count) return nil;
  NSSet *members = [self.parent valueForKey:self.navigation.name] ?: [NSSet set];
  if (key.count == 1) {
    NSArray *values = [members.allObjects valueForKey:key[0].name];
    return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:key[0].name]
                                              rightExpression:[NSExpression expressionForConstantValue:values]
                                                     modifier:NSDirectPredicateModifier
                                                         type:NSInPredicateOperatorType
                                                      options:0];
  }
  NSMutableArray *each = [NSMutableArray array];
  for (NSManagedObject *member in members) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSAttributeDescription *attribute in key) [parts addObject:OISEquals(attribute.name, [member valueForKey:attribute.name], NSDirectPredicateModifier)];
    [each addObject:[NSCompoundPredicate andPredicateWithSubpredicates:parts]];
  }
  return each.count ? [NSCompoundPredicate orPredicateWithSubpredicates:each] : [NSPredicate predicateWithValue:NO];
}

- (void)readCount
{
  OISPlan *plan = [self planCountRead];
  if (!plan) return;
  [self runPlan:plan then:@selector(didRunCount)];
}

- (void)didRunCount
{
  [self respondText:[self.planResult.count description] ?: @"0" contentType:@"text/plain;charset=utf-8" headers:nil];
}

- (BOOL)applyIsFiltersOnly
{
  NSArray *apply = self.request.options.apply;
  if (!apply.count) return NO;
  for (ODataApplyTransformation *t in apply) {
    if (t.kind != ODataApplyFilter || [t.filter aggregatesOfThese].count) return NO;
  }
  return YES;
}

#pragma mark $apply

// Sets value at path in nested dictionaries.
static void OISSetAtPath(NSMutableDictionary *row, NSArray<NSString *> *path, id value)
{
  NSMutableDictionary *at = row;
  for (NSUInteger i = 0; i + 1 < path.count; i++) {
    NSMutableDictionary *next = at[path[i]];
    if (![next isKindOfClass:[NSMutableDictionary class]]) {
      next = [NSMutableDictionary dictionary];
      at[path[i]] = next;
    }
    at = next;
  }
  at[path.lastObject] = value ?: [NSNull null];
}

// Whether the stores group themselves: on Apple, only SQLite takes
// propertiesToGroupBy; FreeCoreData groups for any store, in SQL where its
// store can.
static BOOL OISStoresGroup(NSManagedObjectContext *context)
{
#if defined(__APPLE__)
  NSArray *stores = context.persistentStoreCoordinator.persistentStores;
  if (!stores.count) return NO;
  for (NSPersistentStore *store in stores) {
    if (![store.type isEqualToString:NSSQLiteStoreType]) return NO;
  }
#endif
  return YES;
}

static BOOL OISIsIntegerAttribute(NSAttributeDescription *attribute)
{
  NSAttributeType type = attribute.attributeType;
  return type == NSInteger16AttributeType || type == NSInteger32AttributeType || type == NSInteger64AttributeType;
}

static BOOL OISIsRealAttribute(NSAttributeDescription *attribute)
{
  return attribute.attributeType == NSDoubleAttributeType || attribute.attributeType == NSFloatAttributeType;
}

static NSExpressionDescription *OISAggregateDescription(NSString *name, NSString *function, NSString *keyPath, NSAttributeType type)
{
  NSExpressionDescription *description = [[NSExpressionDescription alloc] init];
  description.name = name;
  description.expression = [NSExpression expressionForFunction:function arguments:@[ [NSExpression expressionForKeyPath:keyPath] ]];
  description.expressionResultType = type;
  return description;
}

// A groupby or aggregate the store can do exactly as rowsOfGrouping would
// (OISStoreGrouping), over the rows this predicate selects; nil for one it
// cannot, which is then grouped here:
//   - grouped by attributes, through to-one relationships;
//   - $count; sum and average of integers (exact) and of doubles; min and
//     max of numbers and dates (no decimals, which SQLite sums as doubles,
//     and no strings, which SQL orders by collation, not as NSString does);
//     no countdistinct, no computed values;
//   - a handler whose rows are the store's (see groupedRowsForFetchRequest:).
- (OISStoreGrouping *)storeGroupingOf:(ODataApplyTransformation *)t predicate:(NSPredicate *)predicate
{
  if (t.kind != ODataApplyGroupBy && t.kind != ODataApplyAggregate) return nil;
  if (t.sequence.count || !OISStoresGroup(self.request.context)) return nil;
  // What the handler does not allow is refused where the grouping is done.
  if ([self refusalOfGrouping:t computed:@{}]) return nil;
  Class base = [ODataEntitySetHandler class];
  Class handler = [self.handler class];
  SEL objects = @selector(objectsForFetchRequest:request:reply:), grouped = @selector(groupedRowsForFetchRequest:request:reply:);
  if ([handler instanceMethodForSelector:grouped] == [base instanceMethodForSelector:grouped] &&
      [handler instanceMethodForSelector:objects] != [base instanceMethodForSelector:objects]) return nil;

  OISStoreGrouping *grouping = [[OISStoreGrouping alloc] init];
  grouping.transformation = t;
  grouping.methods = [NSMutableDictionary dictionary];
  NSMutableArray *keyPaths = [NSMutableArray array], *groupAttributes = [NSMutableArray array], *fetched = [NSMutableArray array];
  NSMutableDictionary *aggregateAttributes = [NSMutableDictionary dictionary];
  for (NSArray *path in t.groupPaths) {
    NSPropertyDescription *property = nil;
    NSString *keyPath = [self.predicates keyPathForPath:path entity:self.entity property:&property error:NULL];
    NSAttributeType type = [property isKindOfClass:[NSAttributeDescription class]] ? ((NSAttributeDescription *)property).attributeType : NSUndefinedAttributeType;
    if (!keyPath || type == NSUndefinedAttributeType || type == NSTransformableAttributeType || type == NSBinaryDataAttributeType) return nil;
    [keyPaths addObject:keyPath];
    [groupAttributes addObject:property];
    [fetched addObject:keyPath];
  }
  NSString *someKey = [self.mapper keyAttributesForEntity:self.entity].firstObject.name;
  for (ODataAggregate *aggregate in t.aggregates) {
    NSString *alias = aggregate.alias;
    // An expression, a collection's $count, a custom one: grouped here.
    if (aggregate.expression || aggregate.isCustom || (aggregate.path && aggregate.isCount)) return nil;
    if (!aggregate.path) {
      if (!someKey) return nil;
      [fetched addObject:OISAggregateDescription(alias, @"count:", someKey, NSInteger64AttributeType)];
      grouping.methods[alias] = @"count";
      continue;
    }
    NSPropertyDescription *property = nil;
    NSString *keyPath = [self.predicates keyPathForPath:aggregate.path entity:self.entity property:&property error:NULL];
    if (!keyPath || ![property isKindOfClass:[NSAttributeDescription class]]) return nil;
    NSAttributeDescription *attribute = (NSAttributeDescription *)property;
    NSString *method = aggregate.method;
    BOOL integer = OISIsIntegerAttribute(attribute), real = OISIsRealAttribute(attribute);
    NSExpressionDescription *values = OISAggregateDescription(OISHelperName(alias, @"n"), @"count:", keyPath, NSInteger64AttributeType);
    if ([method isEqualToString:@"sum"] && (integer || real)) {
      [fetched addObject:OISAggregateDescription(alias, @"sum:", keyPath, integer ? NSInteger64AttributeType : NSDoubleAttributeType)];
      [fetched addObject:values];
      grouping.methods[alias] = integer ? @"decimalSum" : @"sum";
    } else if ([method isEqualToString:@"average"] && integer) {
      [fetched addObject:OISAggregateDescription(OISHelperName(alias, @"sum"), @"sum:", keyPath, NSInteger64AttributeType)];
      [fetched addObject:values];
      grouping.methods[alias] = @"exactAverage";
    } else if ([method isEqualToString:@"average"] && real) {
      [fetched addObject:OISAggregateDescription(alias, @"average:", keyPath, NSDoubleAttributeType)];
      [fetched addObject:values];
      grouping.methods[alias] = @"average";
    } else if (([method isEqualToString:@"min"] || [method isEqualToString:@"max"]) &&
               (integer || real || attribute.attributeType == NSDateAttributeType)) {
      NSString *function = [method isEqualToString:@"min"] ? @"min:" : @"max:";
      [fetched addObject:OISAggregateDescription(alias, function, keyPath, attribute.attributeType)];
      grouping.methods[alias] = @"value";
    } else {
      return nil;
    }
    aggregateAttributes[alias] = attribute;
  }
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
  fetch.predicate = predicate;
  fetch.resultType = NSDictionaryResultType;
  fetch.propertiesToFetch = fetched;
  if (keyPaths.count) fetch.propertiesToGroupBy = keyPaths;
  if (self.service.maxRowsInMemory) fetch.fetchLimit = self.service.maxRowsInMemory + 1;
  grouping.fetch = fetch;
  grouping.keyPaths = keyPaths;
  grouping.groupAttributes = groupAttributes;
  grouping.aggregateAttributes = aggregateAttributes;
  return grouping;
}

// Whether a name is one compute gave (the dictionary also holds a join's
// aliases, each to the entity its members are).
static BOOL OISIsComputed(NSDictionary *computed, NSString *name)
{
  return [computed[name] isKindOfClass:[ODataExpression class]];
}

// A path of wire names as a key path: through a join's alias (Sale/Amount
// is the joined sale's amount), else from the set's entity; through
// collection-valued navigation where through says so (an aggregate's
// path). nil, and a 400, for a name that is not there.
- (NSString *)keyPathForPath:(NSArray *)path computed:(NSDictionary *)computed property:(NSPropertyDescription **)property
          throughCollections:(BOOL)through error:(NSError **)error
{
  id joined = path.count ? computed[path[0]] : nil;
  if (![joined isKindOfClass:[NSEntityDescription class]]) {
    return through ? [self keyPathThroughCollections:path property:property error:error]
                   : [self.predicates keyPathForPath:path entity:self.entity property:property error:error];
  }
  NSMutableArray *keys = [NSMutableArray arrayWithObject:path[0]];
  NSEntityDescription *current = joined;
  NSPropertyDescription *found = nil;
  for (NSUInteger i = 1; i < path.count; i++) {
    found = current ? [self.mapper propertyForWireName:path[i] entity:current] : nil;
    NSRelationshipDescription *relationship = [found isKindOfClass:[NSRelationshipDescription class]] ? (NSRelationshipDescription *)found : nil;
    if (!found || (relationship.isToMany && !through && i + 1 < path.count)) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", current.name ?: @"A value", path[i]]);
      return nil;
    }
    [keys addObject:found.name];
    current = relationship.destinationEntity;
  }
  if (!found) {
    if (error) *error = ODataServiceError(501, [NSString stringWithFormat:@"%@ is a join's alias: name its properties", path[0]]);
    return nil;
  }
  if (property) *property = found;
  return [keys componentsJoinedByString:@"."];
}

// Whether a path (wire names) is among those listed: it, or where it
// starts (Category allows Category/CategoryName).
static BOOL OISPathListed(NSArray<NSString *> *path, id listed)
{
  for (NSUInteger n = path.count; n > 0; n--) {
    if ([listed containsObject:[[path subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@"/"]]) return YES;
  }
  return NO;
}

// A grouping of the set's entities as the handler allows it (Data
// Aggregation section 5.1): its groupable and aggregatable properties, and
// the custom aggregates and methods it declares. nil, or a 400.
- (NSError *)refusalOfGrouping:(ODataApplyTransformation *)t computed:(NSDictionary *)computed
{
  ODataEntitySetHandler *handler = self.handler;
  for (NSArray *path in t.groupPaths) {
    if (path.count == 1 && OISIsComputed(computed, path[0])) continue;
    if (handler.groupableProperties && !OISPathListed(path, handler.groupableProperties)) {
      return ODataServiceError(400, [NSString stringWithFormat:@"%@ cannot be grouped by (Aggregation.ApplySupported/GroupableProperties)",
                                                                [path componentsJoinedByString:@"/"]]);
    }
  }
  for (ODataAggregate *aggregate in t.aggregates) {
    if (aggregate.custom) {
      if (!handler.customAggregates[aggregate.custom]) {
        return ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a custom aggregate of %@", aggregate.custom, [self setName]]);
      }
      continue;
    }
    if (aggregate.method && [aggregate.method rangeOfString:@"."].location != NSNotFound && ![handler.customAggregationMethods containsObject:aggregate.method]) {
      return ODataServiceError(400, [NSString stringWithFormat:@"%@ is not an aggregation method of %@", aggregate.method, [self setName]]);
    }
    if (!handler.aggregatableProperties || !aggregate.path || aggregate.isCount) continue;
    if (aggregate.path.count == 1 && OISIsComputed(computed, aggregate.path[0])) continue;
    NSString *listed = nil;
    for (NSUInteger n = aggregate.path.count; n > 0 && !listed; n--) {
      NSString *prefix = [[aggregate.path subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@"/"];
      if (handler.aggregatableProperties[prefix]) listed = prefix;
    }
    NSArray *methods = listed ? handler.aggregatableProperties[listed] : nil;
    if (!listed || (methods.count && ![methods containsObject:aggregate.method])) {
      return ODataServiceError(400, [NSString stringWithFormat:@"%@ cannot be aggregated%@ (Aggregation.ApplySupported/AggregatableProperties)",
                                                                [aggregate.path componentsJoinedByString:@"/"],
                                                                listed ? [@" with " stringByAppendingString:aggregate.method] : @""]);
    }
  }
  return nil;
}

// The rows of a groupby or aggregate, as the response has them: each
// grouped path nested (Category/CategoryName is {"Category": {"CategoryName": ...}}),
// each aggregate by its alias.
- (NSArray *)rowsOfGrouping:(ODataApplyTransformation *)t over:(NSArray *)objects computed:(NSDictionary *)computed error:(NSError **)error
{
  NSError *refusal = [self refusalOfGrouping:t computed:computed];
  if (refusal) {
    if (error) *error = refusal;
    return nil;
  }
  NSMutableArray *keyPaths = [NSMutableArray array];
  NSMutableArray *groupAttributes = [NSMutableArray array];
  for (NSArray *path in t.groupPaths) {
    if (path.count == 1 && OISIsComputed(computed, path[0])) {
      // A value compute gave: by its name, typed by what it is.
      [keyPaths addObject:path[0]];
      [groupAttributes addObject:[NSNull null]];
      continue;
    }
    NSPropertyDescription *property = nil;
    NSString *keyPath = [self keyPathForPath:path computed:computed property:&property throughCollections:NO error:error];
    if (!keyPath) return nil;
    if (![property isKindOfClass:[NSAttributeDescription class]]) {
      if (error) *error = ODataServiceError(501, [NSString stringWithFormat:@"groupby by %@, a navigation property", [path componentsJoinedByString:@"/"]]);
      return nil;
    }
    [keyPaths addObject:keyPath];
    [groupAttributes addObject:property];
  }
  NSMutableArray *aggregates = [NSMutableArray array];
  NSMutableDictionary *aggregateAttributes = [NSMutableDictionary dictionary];
  NSMutableDictionary *expressions = [NSMutableDictionary dictionary];  // hidden name -> each object's value
  for (ODataAggregate *aggregate in t.aggregates) {
    if (aggregate.expression) {
      // An expression with a method: its value with each object, under a
      // name of its own, aggregated as a path is.
      NSExpression *value = [self.predicates valueExpressionForExpression:aggregate.expression entity:self.entity
                                                                          aliases:self.request.options.aliases computed:computed error:error];
      if (!value) return nil;
      NSString *hidden = [@"__ois_aggregate_" stringByAppendingString:aggregate.alias];
      expressions[hidden] = value;
      ODataAggregate *valued = [ODataAggregate aggregateOfPath:@[ hidden ] method:aggregate.method alias:aggregate.alias error:error];
      if (!valued) return nil;
      [aggregates addObject:valued];
      continue;
    }
    if (aggregate.custom || !aggregate.path || (aggregate.path.count == 1 && OISIsComputed(computed, aggregate.path[0]))) {
      [aggregates addObject:aggregate];
      continue;
    }
    // Through collection-valued navigation too: Sales/Amount is every sale's.
    NSPropertyDescription *property = nil;
    NSString *keyPath = [self keyPathForPath:aggregate.path computed:computed property:&property throughCollections:YES error:error];
    if (!keyPath) return nil;
    if (aggregate.isCount) {
      if (![property isKindOfClass:[NSRelationshipDescription class]]) {
        if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@/$count: not a collection", [aggregate.path componentsJoinedByString:@"/"]]);
        return nil;
      }
    } else if (![property isKindOfClass:[NSAttributeDescription class]]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a property to aggregate", [aggregate.path componentsJoinedByString:@"/"]]);
      return nil;
    } else if (!aggregate.isCustom) {
      aggregateAttributes[aggregate.alias] = property;
    }
    ODataAggregate *stored = [ODataAggregate aggregateOfPath:[keyPath componentsSeparatedByString:@"."] method:aggregate.method alias:aggregate.alias
                                                       error:error];
    if (!stored) return nil;
    [aggregates addObject:stored];
  }
  if (expressions.count) {
    NSMutableArray *valued = [NSMutableArray array];
    for (id object in objects) {
      OISComputedRow *given = [object isKindOfClass:[OISComputedRow class]] ? object : nil;
      OISComputedRow *row = [[OISComputedRow alloc] init];
      row.object = given ? given.object : object;
      row.computed = given ? [given.computed mutableCopy] : [NSMutableDictionary dictionary];
      for (NSString *hidden in expressions) {
        id value = nil;
        @try {
          value = [expressions[hidden] expressionValueWithObject:object context:nil];
        } @catch (NSException *exception) {
          value = nil;
        }
        row.computed[hidden] = value ?: [NSNull null];
      }
      [valued addObject:row];
    }
    objects = valued;
  }
  // Custom aggregates and methods: the handler's.
  ODataEntitySetHandler *handler = self.handler;
  ODataRequest *request = self.request;
  NSArray *raw = [ODataAggregation groupObjects:objects byKeyPaths:keyPaths aggregates:aggregates
                                         custom:^id(ODataAggregate *aggregate, NSArray *members) {
    NSMutableArray *entities = [NSMutableArray array];
    for (id member in members) [entities addObject:[member isKindOfClass:[OISComputedRow class]] ? ((OISComputedRow *)member).object : member];
    if (aggregate.custom) return [handler valueOfCustomAggregate:aggregate.custom objects:entities request:request];
    NSArray *values = [ODataAggregation valuesAtKeyPath:[aggregate.path componentsJoinedByString:@"."] inObjects:members];
    return [handler valueOfAggregationMethod:aggregate.method values:values request:request];
  }];
  return [self rowsOfGroups:raw grouping:t keyPaths:keyPaths groupAttributes:groupAttributes aggregateAttributes:aggregateAttributes];
}

// A path of wire names as a key path, through navigation of either
// cardinality (an aggregate's: Sales/Amount), to a property; nil, and a 400,
// for a name that is not there.
- (NSString *)keyPathThroughCollections:(NSArray *)path property:(NSPropertyDescription **)property error:(NSError **)error
{
  NSMutableArray *keys = [NSMutableArray array];
  NSEntityDescription *current = self.entity;
  NSPropertyDescription *found = nil;
  for (NSString *name in path) {
    found = current ? [self.mapper propertyForWireName:name entity:current] : nil;
    if (!found) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", current.name ?: @"A value", name]);
      return nil;
    }
    [keys addObject:found.name];
    current = [found isKindOfClass:[NSRelationshipDescription class]] ? ((NSRelationshipDescription *)found).destinationEntity : nil;
  }
  if (property) *property = found;
  return [keys componentsJoinedByString:@"."];
}

// Groups (a dictionary each, by key path and by alias, as ODataAggregation
// gives them) as the response has them: each grouped path nested
// (Category/CategoryName is {"Category": {"CategoryName": ...}}), each
// aggregate by its alias, values as JSON.
- (NSArray *)rowsOfGroups:(NSArray<NSDictionary *> *)raw grouping:(ODataApplyTransformation *)t keyPaths:(NSArray *)keyPaths
          groupAttributes:(NSArray *)groupAttributes aggregateAttributes:(NSDictionary *)aggregateAttributes
{
  NSMutableArray *rows = [NSMutableArray array];
  for (NSDictionary *group in raw) {
    NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:[NSNull null] forKey:@"@odata.id"];
    for (NSUInteger i = 0; i < keyPaths.count; i++) {
      id value = group[keyPaths[i]];
      id attribute = groupAttributes[i];
      OISSetAtPath(row, t.groupPaths[i], value == [NSNull null] ? nil
                                         : attribute == [NSNull null] ? [self JSONForComputedValue:value]
                                                                      : [self.coder JSONForCoreDataValue:value attribute:attribute]);
    }
    for (ODataAggregate *aggregate in t.aggregates) {
      id value = group[aggregate.alias];
      NSAttributeDescription *attribute = aggregateAttributes[aggregate.alias];
      // min and max are of the property's type; the rest are numbers.
      if (value != [NSNull null] && attribute && ([aggregate.method isEqualToString:@"min"] || [aggregate.method isEqualToString:@"max"])) {
        value = [self.coder JSONForCoreDataValue:value attribute:attribute];
      }
      row[aggregate.alias] = value;
    }
    [rows addObject:row];
  }
  return rows;
}

// An ordering of grouped rows, by their paths; nil, answered, for any
// other.
- (NSArray *)descriptorsForGroupedOrder:(NSArray<ODataOrderItem *> *)items
{
  NSMutableArray *descriptors = [NSMutableArray array];
  for (ODataOrderItem *item in items) {
    NSArray *path = item.expression.memberPath;
    if (item.expression.kind != ODataExpressionMember || !path.count) {
      // An expression of the row's values: its value with each row.
      NSError *error = nil;
      if (![ODataAggregation valueOfExpression:item.expression inRow:@{} error:&error] && error.code == ODataIncrementalStoreErrorUnsupportedExpression &&
          [error.localizedDescription rangeOfString:@"over aggregated rows"].location != NSNotFound) {
        [self fail:501 message:[NSString stringWithFormat:@"Ordering grouped rows by %@", item.expression]];
        return nil;
      }
      ODataExpression *expression = item.expression;
      // (@self: a dictionary's valueForKey: takes a key without @ as its own.)
      [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:@"@self" ascending:!item.descending comparator:^NSComparisonResult(id a, id b) {
        id x = [ODataAggregation valueOfExpression:expression inRow:a error:NULL], y = [ODataAggregation valueOfExpression:expression inRow:b error:NULL];
        BOOL noX = !x || x == [NSNull null], noY = !y || y == [NSNull null];
        if (noX || noY) return noX == noY ? NSOrderedSame : noX ? NSOrderedAscending : NSOrderedDescending;
        return [x compare:y];
      }]];
      continue;
    }
    [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:[path componentsJoinedByString:@"."] ascending:!item.descending
                                                         comparator:^NSComparisonResult(id a, id b) {
      // null first, as $orderby has it
      BOOL noA = !a || a == [NSNull null], noB = !b || b == [NSNull null];
      if (noA || noB) return noA == noB ? NSOrderedSame : noA ? NSOrderedAscending : NSOrderedDescending;
      return [a compare:b];
    }]];
  }
  return descriptors;
}

// $apply that leaves entities (no groupby or aggregate): the query's
// $filter, $orderby, $count, $skip and $top on them, each written with the
// values compute gave it.
- (void)writeAppliedEntities:(NSArray *)rows computed:(NSDictionary *)computed count:(NSNumber *)count
{
  ODataQueryOptions *options = self.request.options;
  NSError *error = nil;
  // A join's aliases: written where $expand names them, as their entity.
  NSMutableDictionary *joinedExpansions = [NSMutableDictionary dictionary];  // alias -> its $expand item
  for (ODataExpandItem *item in options.expand) {
    if (item.path.count == 1 && [computed[item.path[0]] isKindOfClass:[NSEntityDescription class]]) joinedExpansions[item.path[0]] = item;
  }
  ODataQueryOptions *written = self.writtenOptions ?: options;
  NSMutableArray *values = [NSMutableArray array];
  for (id row in rows) {
    OISComputedRow *more = [row isKindOfClass:[OISComputedRow class]] ? row : nil;
    NSMutableDictionary *json = [self JSONForObject:more ? more.object : row options:written expected:self.entity error:&error];
    if (!json) {
      [self respondError:error];
      return;
    }
    for (NSString *name in more.computed) {
      id value = more.computed[name];
      if (![computed[name] isKindOfClass:[NSEntityDescription class]]) {
        json[name] = [self JSONForComputedValue:value];
        continue;
      }
      // A joined member: only where $expand names it.
      ODataExpandItem *item = joinedExpansions[name];
      if (!item) continue;
      if (![value isKindOfClass:[NSManagedObject class]]) {
        json[name] = [NSNull null];
        continue;
      }
      NSMutableDictionary *member = [self JSONForObject:value options:item.options expected:computed[name] error:&error];
      if (!member) {
        [self respondError:error];
        return;
      }
      json[name] = member;
    }
    [values addObject:json];
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@", [self contextBase], [self setName]];
  if (count) body[@"@odata.count"] = count;
  body[@"value"] = values;
  [self respondJSON:body status:200 headers:nil];
}

// A grouping of grouped rows: their paths are the key paths, and their
// values are JSON already.
- (NSArray *)rowsOfGroupingRows:(ODataApplyTransformation *)t over:(NSArray *)rows error:(NSError **)error
{
  NSMutableArray *keyPaths = [NSMutableArray array];
  for (NSArray *path in t.groupPaths) [keyPaths addObject:[path componentsJoinedByString:@"."]];
  // An expression with a method: its value with each row, under a name of
  // its own, aggregated as a path is.
  NSMutableArray *aggregates = [NSMutableArray array];
  NSMutableArray *valued = [rows mutableCopy];
  for (ODataAggregate *aggregate in t.aggregates) {
    if (!aggregate.expression) {
      [aggregates addObject:aggregate];
      continue;
    }
    NSString *hidden = [@"__ois_aggregate_" stringByAppendingString:aggregate.alias];
    for (NSUInteger i = 0; i < valued.count; i++) {
      NSMutableDictionary *row = [valued[i] mutableCopy];
      id value = [ODataAggregation valueOfExpression:aggregate.expression inRow:valued[i] error:error];
      if (!value) return nil;
      row[hidden] = value;
      valued[i] = row;
    }
    ODataAggregate *hiddenAggregate = [ODataAggregate aggregateOfPath:@[ hidden ] method:aggregate.method alias:aggregate.alias error:error];
    if (!hiddenAggregate) return nil;
    [aggregates addObject:hiddenAggregate];
  }
  for (ODataAggregate *aggregate in aggregates) {
    if (aggregate.custom) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"the custom aggregate %@ of grouped rows", aggregate.custom]);
      return nil;
    }
  }
  ODataEntitySetHandler *handler = self.handler;
  ODataRequest *request = self.request;
  NSArray *raw = [ODataAggregation groupObjects:valued byKeyPaths:keyPaths aggregates:aggregates custom:^id(ODataAggregate *aggregate, NSArray *members) {
    if (![handler.customAggregationMethods containsObject:aggregate.method]) return nil;
    NSArray *values = [ODataAggregation valuesAtKeyPath:[aggregate.path componentsJoinedByString:@"."] inObjects:members];
    return [handler valueOfAggregationMethod:aggregate.method values:values request:request];
  }];
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *group in raw) {
    NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:[NSNull null] forKey:@"@odata.id"];
    for (NSUInteger i = 0; i < keyPaths.count; i++) {
      id value = group[keyPaths[i]];
      OISSetAtPath(row, t.groupPaths[i], value == [NSNull null] ? nil : value);
    }
    for (ODataAggregate *aggregate in t.aggregates) row[aggregate.alias] = group[aggregate.alias];
    [out addObject:row];
  }
  return out;
}

// For a context URL: Category(CategoryName),Total.
static NSString *OISSelectListOfPaths(NSArray<NSArray<NSString *> *> *paths)
{
  NSMutableArray *order = [NSMutableArray array];
  NSMutableDictionary *children = [NSMutableDictionary dictionary];
  for (NSArray *path in paths) {
    NSString *head = path.firstObject;
    if (!children[head]) {
      children[head] = [NSMutableArray array];
      [order addObject:head];
    }
    if (path.count > 1) [children[head] addObject:[path subarrayWithRange:NSMakeRange(1, path.count - 1)]];
  }
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *head in order) {
    NSArray *below = children[head];
    [items addObject:below.count ? [NSString stringWithFormat:@"%@(%@)", head, OISSelectListOfPaths(below)] : head];
  }
  return [items componentsJoinedByString:@","];
}

// A row, and the rows nested in it, as mutable dictionaries: a partition's
// result, to be given its partition's values.
static NSMutableDictionary *OISMutableRow(NSDictionary *row)
{
  NSMutableDictionary *copy = [NSMutableDictionary dictionary];
  for (NSString *key in row) {
    id value = row[key];
    copy[key] = [value isKindOfClass:[NSDictionary class]] ? OISMutableRow(value) : value;
  }
  return copy;
}

// groupby with transformations of its own (Data Aggregation section 3.2.3):
// the rows partitioned by the grouping paths' values, the transformations
// applied to each partition, and each result given its partition's values.
// The transformations have to leave grouped rows (aggregate, or groupby).
- (BOOL)groupRows:(NSArray **)rowsp shape:(NSMutableArray **)shapep by:(ODataApplyTransformation *)t
         computed:(NSMutableDictionary *)computed expansions:(NSMutableArray *)expansions
{
  NSArray *rows = *rowsp;
  NSMutableArray *shape = *shapep;
  NSError *error = nil;
  // Each grouping path's key path, and how its value is written.
  NSMutableArray *keyPaths = [NSMutableArray array], *attributes = [NSMutableArray array];
  for (NSArray *path in t.groupPaths) {
    if (shape || (path.count == 1 && OISIsComputed(computed, path[0]))) {
      // Grouped rows' values are JSON already; compute's are written as it writes them.
      [keyPaths addObject:[path componentsJoinedByString:@"."]];
      [attributes addObject:shape ? @"row" : @"computed"];
      continue;
    }
    NSPropertyDescription *property = nil;
    NSString *keyPath = [self keyPathForPath:path computed:computed property:&property throughCollections:NO error:&error];
    if (!keyPath) {
      [self respondError:error];
      return NO;
    }
    if (![property isKindOfClass:[NSAttributeDescription class]]) {
      [self fail:501 message:[NSString stringWithFormat:@"groupby by %@, a navigation property", [path componentsJoinedByString:@"/"]]];
      return NO;
    }
    [keyPaths addObject:keyPath];
    [attributes addObject:property];
  }
  // The partitions, first seen first.
  NSMutableArray *order = [NSMutableArray array];
  NSMutableDictionary *partitions = [NSMutableDictionary dictionary];
  for (id row in rows) {
    NSMutableArray *key = [NSMutableArray array];
    for (NSString *keyPath in keyPaths) [key addObject:[row valueForKeyPath:keyPath] ?: [NSNull null]];
    if (!partitions[key]) {
      partitions[key] = [NSMutableArray array];
      [order addObject:key];
    }
    [partitions[key] addObject:row];
  }
  NSMutableArray *out = [NSMutableArray array];
  NSMutableArray *outShape = [t.groupPaths mutableCopy];
  for (NSArray *key in order) {
    NSArray *partRows = partitions[key];
    NSMutableArray *partShape = shape ? [shape mutableCopy] : nil;
    NSMutableDictionary *partComputed = [computed mutableCopy];
    if (![self applyTransformations:t.sequence rows:&partRows shape:&partShape computed:partComputed expansions:expansions]) return NO;
    if (!partShape) {
      [self fail:501 message:@"$apply: groupby's transformations have to aggregate (end in aggregate or groupby)"];
      return NO;
    }
    for (NSDictionary *result in partRows) {
      NSMutableDictionary *row = OISMutableRow(result);
      for (NSUInteger i = 0; i < key.count; i++) {
        id value = key[i] == [NSNull null] ? nil : key[i];
        id attribute = attributes[i];
        if (value && [attribute isKindOfClass:[NSAttributeDescription class]]) value = [self.coder JSONForCoreDataValue:value attribute:attribute];
        else if (value && [attribute isEqual:@"computed"]) value = [self JSONForComputedValue:value];
        OISSetAtPath(row, t.groupPaths[i], value);
      }
      [out addObject:row];
    }
    for (NSArray *path in partShape) if (![outShape containsObject:path]) [outShape addObject:path];
  }
  *rowsp = out;
  *shapep = outShape;
  return YES;
}

// join and outerjoin (Data Aggregation section 3.5.1): each row once for
// each member of its collection at the path (after the join's own
// transformations, if any), with the member under the alias; an outerjoin's
// row with no members, once, with null. The alias is then a navigation
// property of the rows, to the members' entity. nil once answered.
- (NSArray *)rowsJoining:(ODataApplyTransformation *)t over:(NSArray *)rows computed:(NSMutableDictionary *)computed
              expansions:(NSMutableArray *)expansions
{
  NSError *error = nil;
  NSPropertyDescription *property = nil;
  NSString *keyPath = [self keyPathForPath:t.joinPath computed:computed property:&property throughCollections:YES error:&error];
  if (!keyPath) {
    [self respondError:error];
    return nil;
  }
  NSRelationshipDescription *relationship = [property isKindOfClass:[NSRelationshipDescription class]] ? (NSRelationshipDescription *)property : nil;
  if (!relationship.isToMany) {
    // A collection of complex values is one, but not joined here.
    BOOL complex = [property isKindOfClass:[NSAttributeDescription class]] &&
                   ((NSAttributeDescription *)property).attributeType == NSTransformableAttributeType;
    [self fail:complex ? 501 : 400 message:[NSString stringWithFormat:@"$apply: %@ is not a collection of entities to join",
                                                                            [t.joinPath componentsJoinedByString:@"/"]]];
    return nil;
  }
  NSEntityDescription *destination = relationship.destinationEntity;
  if (computed[t.alias] || [self.mapper propertyForWireName:t.alias entity:self.entity]) {
    [self fail:400 message:[NSString stringWithFormat:@"$apply: %@ is a name the rows have already", t.alias]];
    return nil;
  }
  ODataEntitySetHandler *handler = [self.service handlerForEntity:destination];
  NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
  NSMutableArray *sort = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(destination)]) {
    [sort addObject:[NSSortDescriptor sortDescriptorWithKey:attribute.name ascending:YES]];
  }
  // Each row's members: the collection of its owners (itself, or what a
  // path of to-one steps leads to), read through the handler for all the
  // rows at once, as an expansion's are; nil until they are known (the
  // plan goes on when they are).
  NSArray *steps = [keyPath componentsSeparatedByString:@"."];
  NSString *prefix = steps.count > 1 ? [[steps subarrayWithRange:NSMakeRange(0, steps.count - 1)] componentsJoinedByString:@"."] : nil;
  NSMutableArray *owners = [NSMutableArray array];
  NSMutableArray *ownersOfRows = [NSMutableArray array];
  for (id row in rows) {
    NSMutableArray *mine = [NSMutableArray array];
    for (id owner in prefix ? [ODataAggregation valuesAtKeyPath:prefix inObjects:@[ row ]]
                            : @[ [row isKindOfClass:[OISComputedRow class]] ? ((OISComputedRow *)row).object : row ]) {
      if (![owner isKindOfClass:[NSManagedObject class]]) continue;
      [mine addObject:owner];
      if (![owners containsObject:owner]) [owners addObject:owner];
    }
    [ownersOfRows addObject:mine];
  }
  NSString *ownersNamed = [[owners valueForKeyPath:@"objectID.URIRepresentation.absoluteString"] componentsJoinedByString:@","];
  NSString *key = [NSString stringWithFormat:@"join/%p/%lu/%lu", (void *)t, (unsigned long)owners.count, (unsigned long)ownersNamed.hash];
  NSDictionary *byOwner = [self membersOf:owners relationship:relationship predicate:visible sort:sort key:key];
  if (!byOwner) return nil;
  NSMutableArray *out = [NSMutableArray array];
  for (NSUInteger index = 0; index < rows.count; index++) {
    id row = rows[index];
    NSMutableArray *gathered = [NSMutableArray array];
    for (NSManagedObject *owner in ownersOfRows[index]) [gathered addObjectsFromArray:byOwner[owner.objectID] ?: @[]];
    NSArray *members = [gathered sortedArrayUsingDescriptors:sort];
    if (t.sequence.count && members.count) {
      // The join's transformations, on the members: as the set of their own.
      NSEntityDescription *entity = self.entity;
      ODataEntitySetHandler *own = self.handler;
      self.entity = destination;
      self.handler = handler ?: own;
      NSMutableArray *memberShape = nil;
      BOOL done = [self applyTransformations:t.sequence rows:&members shape:&memberShape computed:[NSMutableDictionary dictionary] expansions:[NSMutableArray array]];
      self.entity = entity;
      self.handler = own;
      if (!done) return nil;
      if (memberShape) {
        [self fail:501 message:@"$apply: a join's transformations have to leave entities"];
        return nil;
      }
    }
    if (!members.count && t.outer) members = @[ [NSNull null] ];
    OISComputedRow *given = [row isKindOfClass:[OISComputedRow class]] ? row : nil;
    for (id member in members) {
      OISComputedRow *joined = [[OISComputedRow alloc] init];
      joined.object = given ? given.object : row;
      joined.computed = given ? [given.computed mutableCopy] : [NSMutableDictionary dictionary];
      joined.computed[t.alias] = [member isKindOfClass:[OISComputedRow class]] ? ((OISComputedRow *)member).object : member;
      [out addObject:joined];
    }
  }
  computed[t.alias] = destination;
  return out;
}

// An expression with the values of the current collection it asks for
// ($these/$count, $these/aggregate(Amount with sum)) as literals: each the
// value aggregate(... as D) gives over the rows (entities, or grouped rows
// with shape); nil once answered, with the error.
- (ODataExpression *)expression:(ODataExpression *)e over:(NSArray *)rows shape:(NSArray *)shape computed:(NSDictionary *)computed
{
  NSArray<ODataExpression *> *asked = [e aggregatesOfThese];
  if (!asked.count) return e;
  NSDictionary *values = [self valuesOf:asked over:rows shape:shape computed:computed];
  return values ? [e expressionReplacing:values] : nil;
}

- (NSDictionary *)valuesOf:(NSArray<ODataExpression *> *)asked over:(NSArray *)rows shape:(NSArray *)shape computed:(NSDictionary *)computed
{
  NSMutableArray *aggregates = [NSMutableArray array];
  for (NSUInteger i = 0; i < asked.count; i++) {
    NSString *alias = [NSString stringWithFormat:@"__ois_these_%lu", (unsigned long)i];
    ODataAggregate *a = asked[i].aggregate;
    NSError *aggregateError = nil;
    // (custom: a custom aggregate named alone; a custom method is a path's.)
    ODataAggregate *again = !a ? [ODataAggregate aggregateOfPath:nil method:nil alias:alias error:&aggregateError]
                          : a.custom ? [ODataAggregate aggregateOfCustom:a.custom alias:alias error:&aggregateError]
                          : a.expression ? [ODataAggregate aggregateOfExpression:a.expression method:a.method alias:alias error:&aggregateError]
                          : [ODataAggregate aggregateOfPath:a.path method:a.method alias:alias error:&aggregateError];
    if (!again) {
      [self respondError:ODataServiceError(400, aggregateError.localizedDescription)];
      return nil;
    }
    [aggregates addObject:again];
  }
  ODataApplyTransformation *t = [ODataApplyTransformation aggregateWith:aggregates];
  NSError *error = nil;
  NSArray *out = shape ? [self rowsOfGroupingRows:t over:rows error:&error] : [self rowsOfGrouping:t over:rows computed:computed error:&error];
  if (!out) {
    [self respondError:shape ? ODataServiceError(501, error.localizedDescription) : error];
    return nil;
  }
  NSDictionary *row = out.firstObject;
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < asked.count; i++) values[asked[i].description] = row[[aggregates[i] alias]] ?: [NSNull null];
  return values;
}

// An expression of the request's options with what the hierarchy
// functions stand for, and the collection's values, in.
- (ODataExpression *)resolved:(ODataExpression *)e options:(ODataQueryOptions *)options
{
  e = [self hierarchical:e];
  // The plan's store scan bound them ($compute's $these, when written).
  return self.planValues.count && options == self.request.options ? [e expressionReplacing:self.planValues] : e;
}

- (ODataExpression *)hierarchical:(ODataExpression *)e
{
  return e && self.hierarchyCalls.count ? [e expressionReplacing:self.hierarchyCalls] : e;
}

// An $orderby with what the hierarchy functions stand for in.
- (NSArray<ODataOrderItem *> *)resolvedOrder:(NSArray<ODataOrderItem *> *)items options:(ODataQueryOptions *)options
{
  if (!self.hierarchyCalls.count) return items;
  NSMutableArray *out = [NSMutableArray array];
  for (ODataOrderItem *item in items) {
    [out addObject:[ODataOrderItem itemWithExpression:[self hierarchical:item.expression] descending:item.descending]];
  }
  return out;
}

static NSArray<ODataExpression *> *OISTheseIn(NSArray<ODataExpression *> *expressions)
{
  NSMutableArray *asked = [NSMutableArray array];
  for (ODataExpression *e in expressions) {
    for (ODataExpression *one in [e aggregatesOfThese]) {
      if (![[asked valueForKey:@"description"] containsObject:one.description]) [asked addObject:one];
    }
  }
  return asked;
}

// What $filter and $compute of options ask of their collection, and what
// $orderby asks of its own.
NSArray<ODataExpression *> *OISTheseOfFilter(ODataQueryOptions *options)
{
  NSMutableArray *expressions = [NSMutableArray array];
  if (options.filter) [expressions addObject:options.filter];
  for (ODataComputeItem *item in options.compute) [expressions addObject:item.expression];
  return OISTheseIn(expressions);
}

NSArray<ODataExpression *> *OISTheseOfOrder(ODataQueryOptions *options)
{
  return OISTheseIn([options.orderBy valueForKey:@"expression"] ?: @[]);
}

// Options with some of their values in: $filter's and $compute's, and
// $orderby's.
ODataQueryOptions *OISOptionsReplacing(ODataQueryOptions *options, NSDictionary *filterValues, NSDictionary *orderValues)
{
  if (!filterValues.count && !orderValues.count) return options;
  ODataMutableQueryOptions *copy = [options mutableCopy];
  if (filterValues.count) {
    copy.filter = [options.filter expressionReplacing:filterValues];
    NSMutableArray *compute = [NSMutableArray array];
    for (ODataComputeItem *item in options.compute) {
      // (The alias was checked as the item was made.)
      [compute addObject:[ODataComputeItem itemWithExpression:[item.expression expressionReplacing:filterValues] alias:item.alias error:NULL]];
    }
    copy.compute = compute;
  }
  if (orderValues.count) {
    NSMutableArray *order = [NSMutableArray array];
    for (ODataOrderItem *item in options.orderBy) {
      [order addObject:[ODataOrderItem itemWithExpression:[item.expression expressionReplacing:orderValues] descending:item.descending]];
    }
    copy.orderBy = order;
  }
  return copy;
}

#pragma mark Recursive hierarchies

// isnode, isroot, isleaf, isancestor, isdescendant, issibling, of the
// Aggregation vocabulary (section 5.5.1.1), by its alias or its namespace.
NSString *OISHierarchyFunction(NSString *name)
{
  for (NSString *prefix in @[ @"Aggregation.", @"Org.OData.Aggregation.V1." ]) {
    if (![name hasPrefix:prefix]) continue;
    NSString *function = [name substringFromIndex:prefix.length];
    return [@[ @"isnode", @"isroot", @"isleaf", @"isancestor", @"isdescendant", @"issibling" ] containsObject:function] ? function : nil;
  }
  return nil;
}

void OISAddExpressionsOfTransformations(NSArray<ODataApplyTransformation *> *transformations, NSMutableArray *into)
{
  for (ODataApplyTransformation *t in transformations) {
    if (t.filter) [into addObject:t.filter];
    if (t.expression) [into addObject:t.expression];
    if (t.numberExpression) [into addObject:t.numberExpression];
    for (ODataComputeItem *item in t.compute) [into addObject:item.expression];
    for (ODataOrderItem *item in t.orderBy) [into addObject:item.expression];
    OISAddExpressionsOfTransformations(t.sequence, into);
    for (NSArray *branch in t.branches) OISAddExpressionsOfTransformations(branch, into);
  }
}

void OISAddExpressionsOfOptions(ODataQueryOptions *options, NSMutableArray *into)
{
  if (!options) return;
  if (options.filter) [into addObject:options.filter];
  for (ODataComputeItem *item in options.compute) [into addObject:item.expression];
  for (ODataOrderItem *item in options.orderBy) [into addObject:item.expression];
  OISAddExpressionsOfTransformations(options.apply, into);
  for (ODataExpandItem *item in options.expand) OISAddExpressionsOfOptions(item.options, into);
}

// Each hierarchy function the request calls, as Node in (identifiers):
// the store tests that. NO once answered, with the error.
- (BOOL)resolveHierarchyCalls
{
  NSMutableArray *expressions = [NSMutableArray array];
  OISAddExpressionsOfOptions(self.request.options, expressions);
  NSMutableDictionary *calls = [NSMutableDictionary dictionary];
  for (ODataExpression *e in expressions) {
    NSArray *found = [e partsPassingTest:^BOOL(ODataExpression *part) {
      return part.kind == ODataExpressionCall && OISHierarchyFunction(part.name) != nil;
    }];
    for (ODataExpression *call in found) {
      if (calls[call.description]) continue;
      ODataExpression *resolved = [self resolvedHierarchyCall:call];
      if (!resolved) return NO;
      calls[call.description] = resolved;
    }
  }
  self.hierarchyCalls = calls;
  return YES;
}

- (ODataExpression *)resolvedHierarchyCall:(ODataExpression *)call
{
  NSString *function = OISHierarchyFunction(call.name);
  NSDictionary<NSString *, ODataExpression *> *named = call.namedArguments;
  ODataExpression *nodes = named[@"HierarchyNodes"], *qualifier = named[@"HierarchyQualifier"], *node = named[@"Node"];
  NSString *nodesText = nodes.description;
  if (!nodes || ![nodesText hasPrefix:@"$root/"] || qualifier.kind != ODataExpressionLiteral || ![qualifier.value isKindOfClass:[NSString class]] || !node) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ takes HierarchyNodes=$root/set, HierarchyQualifier='qualifier' and Node=path", call.name]];
    return nil;
  }
  OISHierarchy *hierarchy = [self hierarchyOfNodes:[[nodesText substringFromIndex:6] componentsSeparatedByString:@"/"] qualifier:qualifier.value];
  if (!hierarchy) return nil;
  id (^literal)(NSString *) = ^id(NSString *name) {
    ODataExpression *argument = named[name];
    return argument.kind == ODataExpressionLiteral ? (argument.value ?: [NSNull null]) : nil;
  };
  NSInteger distance = 0;
  if (named[@"MaxDistance"]) {
    id value = literal(@"MaxDistance");
    if (![value isKindOfClass:[NSNumber class]] || [value integerValue] < 1 || [value doubleValue] != [value integerValue]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@: MaxDistance is a whole number, 1 or more", call.name]];
      return nil;
    }
    distance = [value integerValue];
  }
  BOOL includeSelf = NO;
  if (named[@"IncludeSelf"]) {
    id value = literal(@"IncludeSelf");
    if (![value isKindOfClass:[NSNumber class]]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@: IncludeSelf is true or false", call.name]];
      return nil;
    }
    includeSelf = [value boolValue];
  }
  NSArray *identifiers = nil;
  if ([function isEqualToString:@"isnode"]) {
    identifiers = hierarchy.nodes;
  } else if ([function isEqualToString:@"isroot"]) {
    identifiers = [hierarchy roots];
  } else if ([function isEqualToString:@"isleaf"]) {
    identifiers = [hierarchy leaves];
  } else {
    NSString *parameter = [function isEqualToString:@"isdescendant"] ? @"Ancestor" : [function isEqualToString:@"isancestor"] ? @"Descendant" : @"Other";
    if (!named[parameter]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ takes %@", call.name, parameter]];
      return nil;
    }
    id given = literal(parameter);
    if (!given || given == [NSNull null]) {
      [self fail:given ? 400 : 501 message:[NSString stringWithFormat:@"%@: %@ is taken as a literal node identifier", call.name, parameter]];
      return nil;
    }
    identifiers = [function isEqualToString:@"isdescendant"] ? [hierarchy descendantsOf:given distance:distance includeSelf:includeSelf]
                : [function isEqualToString:@"isancestor"] ? [hierarchy ancestorsOf:given distance:distance includeSelf:includeSelf]
                : [hierarchy siblingsOf:given];
  }
  return [ODataExpression expression:node inValues:identifiers];
}

// The nodes of a set that the caller can see, as a recursive hierarchy:
// the RecursiveHierarchy annotation of the set's entity type with the
// qualifier. nil once answered, with the error.
- (OISHierarchy *)hierarchyOfNodes:(NSArray<NSString *> *)setPath qualifier:(NSString *)qualifier
{
  // Read by the plan's Closure, before anything that uses it.
  NSString *key = [NSString stringWithFormat:@"%@#%@", [setPath componentsJoinedByString:@"/"], qualifier];
  OISHierarchy *hierarchy = self.hierarchies[key];
  if (!hierarchy) [self fail:500 message:[NSString stringWithFormat:@"The recursive hierarchy %@ was not read first", key]];
  return hierarchy;
}

// A recursive hierarchy as the model declares it, its nodes not read yet:
// and the fetch of them, through the handler it gives; nil once answered.
- (OISHierarchy *)describedHierarchyOf:(NSArray<NSString *> *)setPath qualifier:(NSString *)qualifier
                                 fetch:(NSFetchRequest **)fetchp handler:(ODataEntitySetHandler **)handlerp
{
  ODataEntitySetHandler *handler = setPath.count == 1 ? [self.service handlerForEntitySet:setPath[0]] : nil;
  if (!handler) {
    [self fail:setPath.count == 1 ? 400 : 501 message:[NSString stringWithFormat:@"$root/%@: %@", [setPath componentsJoinedByString:@"/"],
                                                       setPath.count == 1 ? @"no such entity set" : @"only an entity set is taken as a hierarchy's nodes"]];
    return nil;
  }
  NSEntityDescription *entity = handler.entity;
  NSString *term = [@"Org.OData.Aggregation.V1.RecursiveHierarchy#" stringByAppendingString:qualifier];
  NSDictionary *record = [self.mapper annotationsOfProperty:nil entity:entity][term];
  if (![record isKindOfClass:[NSDictionary class]]) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ has no recursive hierarchy %@", setPath[0], qualifier]];
    return nil;
  }
  id node = record[@"NodeProperty"], parent = record[@"ParentNavigationProperty"];
  NSString *nodePath = [node isKindOfClass:[NSDictionary class]] ? node[@"$PropertyPath"] : node;
  NSString *parentPath = [parent isKindOfClass:[NSDictionary class]] ? (parent[@"$NavigationPropertyPath"] ?: parent[@"$PropertyPath"]) : parent;
  NSPropertyDescription *nodeProperty = nil;
  NSString *nodeKeyPath = [nodePath isKindOfClass:[NSString class]]
      ? [self.predicates keyPathForPath:[nodePath componentsSeparatedByString:@"/"] entity:entity property:&nodeProperty error:NULL] : nil;
  NSRelationshipDescription *relationship = [parentPath isKindOfClass:[NSString class]]
      ? (NSRelationshipDescription *)[self.mapper propertyForWireName:parentPath entity:entity] : nil;
  if (!nodeKeyPath || ![nodeProperty isKindOfClass:[NSAttributeDescription class]] || ![relationship isKindOfClass:[NSRelationshipDescription class]]
      || ![entity isKindOfEntity:relationship.destinationEntity]) {
    [self fail:500 message:[NSString stringWithFormat:@"The recursive hierarchy %@ of %@ names no node property, or no parent navigation property to %@ itself",
                                                      qualifier, setPath[0], setPath[0]]];
    return nil;
  }
  OISHierarchy *hierarchy = [[OISHierarchy alloc] init];
  hierarchy.entity = entity;
  hierarchy.qualifier = qualifier;
  hierarchy.nodeKeyPath = nodeKeyPath;
  hierarchy.parentKey = relationship.name;
  hierarchy.parentsAreMany = relationship.isToMany;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity.name];
  fetch.predicate = [handler predicateForVisibleObjectsInRequest:self.request];
  NSMutableArray *byKey = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(entity)]) {
    [byKey addObject:[NSSortDescriptor sortDescriptorWithKey:attribute.name ascending:YES]];
  }
  fetch.sortDescriptors = byKey;
  fetch.relationshipKeyPathsForPrefetching = @[ relationship.name ];
  if (self.service.maxRowsInMemory) fetch.fetchLimit = self.service.maxRowsInMemory + 1;
  if (fetchp) *fetchp = fetch;
  if (handlerp) *handlerp = handler;
  return hierarchy;
}

// Where a row's node identifier is: p, through single-valued segments (a
// path in a grouped row as it nests). nil once answered, with the error.
- (NSString *)nodeKeyPathOf:(ODataApplyTransformation *)t shape:(NSArray *)shape computed:(NSDictionary *)computed
                  collections:(NSArray<NSNumber *> **)collections
{
  if (shape) return [t.nodePath componentsJoinedByString:@"."];
  NSError *error = nil;
  NSString *keyPath = [self keyPathForPath:t.nodePath computed:computed property:NULL throughCollections:NO error:&error];
  if (keyPath) return keyPath;
  // Through collection-valued segments (p1/.../pk/r, section 6.1): each
  // row's node identifiers are the values along it.
  keyPath = [self keyPathForPath:t.nodePath computed:computed property:NULL throughCollections:YES error:NULL];
  if (!keyPath) {
    [self respondError:error];
    return nil;
  }
  NSMutableArray *many = [NSMutableArray array];
  NSEntityDescription *at = self.entity;
  for (NSString *name in [keyPath componentsSeparatedByString:@"."]) {
    NSRelationshipDescription *relationship = at.relationshipsByName[name];
    [many addObject:@(relationship.isToMany)];
    at = relationship.destinationEntity;
  }
  if (collections) *collections = many;
  return keyPath;
}

// sigma(x) of section 6.2.2 where p goes through collections: a sparse
// instance with only x's identifier at p, each collection-valued segment a
// collection of one (Sales/SalesOrganization/ID of US is
// {"Sales": [{"SalesOrganization": {"ID": "US"}}]}), under p's first name.
static id OISSparseAtPath(NSArray<NSString *> *path, NSArray<NSNumber *> *collections, NSUInteger from, id value)
{
  if (from + 1 >= path.count) return value;
  id inner = @{ path[from + 1]: OISSparseAtPath(path, collections, from + 1, value) };
  return [collections[from + 1] boolValue] ? @[ inner ] : inner;
}

// ancestors and descendants (section 6.2.1): of the input, those related
// to an ancestor (a descendant) of a start node, the nodes of what T
// picks; the start nodes too with keep start. traverse (section 6.2.2):
// the input related to each node, the nodes in preorder or postorder.
- (BOOL)applyHierarchical:(ODataApplyTransformation *)t rows:(NSArray **)rowsp shape:(NSMutableArray *)shape
                 computed:(NSMutableDictionary *)computed expansions:(NSMutableArray *)expansions
{
  OISHierarchy *hierarchy = [self hierarchyOfNodes:t.hierarchy qualifier:t.qualifier];
  if (!hierarchy) return NO;
  NSArray<NSNumber *> *collections = nil;
  NSString *keyPath = [self nodeKeyPathOf:t shape:shape computed:computed collections:&collections];
  if (!keyPath) return NO;
  BOOL many = [collections containsObject:@YES];
  NSArray *rows = *rowsp;
  // A row's node identifiers: one, or through collections, any number.
  NSArray *(^nodesOf)(id) = ^NSArray *(id row) {
    NSArray *values = nil;
    @try {
      values = many ? [ODataAggregation valuesAtKeyPath:keyPath inObjects:@[ row ]] : @[ [row valueForKeyPath:keyPath] ?: [NSNull null] ];
    } @catch (NSException *exception) {
      values = @[];
    }
    NSMutableArray *nodes = [NSMutableArray array];
    for (id value in values) if (value != [NSNull null] && ![nodes containsObject:value]) [nodes addObject:value];
    return nodes;
  };
  if (t.traversal) {
    if (hierarchy.parentsAreMany) {
      [self fail:501 message:@"$apply: traverse of a hierarchy whose nodes have many parents is not supported (section 6.2.2)"];
      return NO;
    }
    // The roots stable-sorted by the ordering; each node's children too
    // (their order is the service's to choose).
    NSArray *descriptors = nil;
    if (t.orderBy.count) {
      NSError *error = nil;
      BOOL inMemory = NO;
      descriptors = [self.predicates sortDescriptorsForOrderBy:t.orderBy entity:hierarchy.entity computed:nil inMemory:&inMemory error:&error];
      if (!descriptors) {
        [self respondError:error];
        return NO;
      }
    }
    NSMutableDictionary *byNode = [NSMutableDictionary dictionary];
    NSString *first = t.nodePath.firstObject;
    for (id row in rows) {
      for (id node in nodesOf(row)) {
        if (!byNode[node]) byNode[node] = [NSMutableArray array];
        id written = row;
        if (many) {
          // The row once per node it is related to, with that node's
          // identifier at p (sigma(x), section 6.2.2).
          OISComputedRow *given = [row isKindOfClass:[OISComputedRow class]] ? row : nil;
          OISComputedRow *one = [[OISComputedRow alloc] init];
          one.object = given ? given.object : row;
          one.computed = given ? [given.computed mutableCopy] : [NSMutableDictionary dictionary];
          id sparse = OISSparseAtPath(t.nodePath, collections, 0, node);
          one.computed[first] = [collections.firstObject boolValue] ? @[ sparse ] : sparse;
          written = one;
        }
        [byNode[node] addObject:written];
      }
    }
    NSMutableArray *out = [NSMutableArray array];
    [self traverse:[self nodes:[hierarchy roots] of:hierarchy sortedBy:descriptors] hierarchy:hierarchy sortedBy:descriptors
         postorder:[t.traversal isEqualToString:@"postorder"] rows:byNode seen:[NSMutableSet set] into:out];
    *rowsp = out;
    return YES;
  }
  NSArray *start = rows;
  NSMutableArray *startShape = shape ? [shape mutableCopy] : nil;
  if (![self applyTransformations:t.sequence rows:&start shape:&startShape computed:[computed mutableCopy] expansions:[expansions mutableCopy]]) return NO;
  if ((startShape == nil) != (shape == nil) || (shape && ![startShape isEqual:shape])) {
    [self fail:501 message:[NSString stringWithFormat:@"$apply: %@'s transformations have to pick among its input", t.method]];
    return NO;
  }
  BOOL ancestors = [t.method isEqualToString:@"ancestors"];
  NSMutableSet *targets = [NSMutableSet set];
  for (id row in start) {
    for (id node in nodesOf(row)) {
      [targets addObjectsFromArray:ancestors ? [hierarchy ancestorsOf:node distance:t.number.integerValue includeSelf:t.keepStart]
                                             : [hierarchy descendantsOf:node distance:t.number.integerValue includeSelf:t.keepStart]];
    }
  }
  NSMutableArray *out = [NSMutableArray array];
  for (id row in rows) {
    // Any of its nodes: the union has each row once (section 6.2.1).
    for (id node in nodesOf(row)) {
      if (![targets containsObject:node]) continue;
      [out addObject:row];
      break;
    }
  }
  *rowsp = out;
  return YES;
}

- (NSArray *)nodes:(NSArray *)nodes of:(OISHierarchy *)hierarchy sortedBy:(NSArray<NSSortDescriptor *> *)descriptors
{
  if (!descriptors.count) return nodes;
  return [nodes sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(id a, id b) {
    for (NSSortDescriptor *descriptor in descriptors) {
      NSComparisonResult order = [descriptor compareObject:hierarchy.objects[a] toObject:hierarchy.objects[b]];
      if (order != NSOrderedSame) return order;
    }
    return NSOrderedSame;
  }];
}

- (void)traverse:(NSArray *)nodes hierarchy:(OISHierarchy *)hierarchy sortedBy:(NSArray *)descriptors postorder:(BOOL)postorder
            rows:(NSDictionary *)byNode seen:(NSMutableSet *)seen into:(NSMutableArray *)out
{
  for (id node in nodes) {
    if ([seen containsObject:node]) continue;  // a cycle, which the spec forbids
    [seen addObject:node];
    if (!postorder) [out addObjectsFromArray:byNode[node] ?: @[]];
    [self traverse:[self nodes:hierarchy.children[node] ?: @[] of:hierarchy sortedBy:descriptors] hierarchy:hierarchy sortedBy:descriptors
         postorder:postorder rows:byNode seen:seen into:out];
    if (postorder) [out addObjectsFromArray:byNode[node] ?: @[]];
  }
}


// $apply's transformations, in order, on the rows (entities, or grouped
// rows once shape is set); NO once answered, with the error.
- (BOOL)applyTransformations:(NSArray<ODataApplyTransformation *> *)transformations rows:(NSArray **)rowsp shape:(NSMutableArray **)shapep
                    computed:(NSMutableDictionary *)computed expansions:(NSMutableArray *)expansions
{
  ODataQueryOptions *options = self.request.options;
  NSArray *rows = *rowsp;
  NSMutableArray *shape = *shapep;
  NSError *error = nil;
  for (ODataApplyTransformation *t in transformations) {
    switch (t.kind) {
      case ODataApplyIdentity:
        continue;
      case ODataApplyHierarchy:
        if (![self applyHierarchical:t rows:&rows shape:shape computed:computed expansions:expansions]) return NO;
        continue;
      case ODataApplyFilter: {
        ODataExpression *condition = [self expression:[self hierarchical:t.filter] over:rows shape:shape computed:computed];
        if (!condition) return NO;
        NSPredicate *filter = shape ? [ODataAggregation predicateForExpression:condition error:&error]
                                    : [self.predicates predicateForExpression:condition entity:self.entity aliases:options.aliases
                                                                             computed:computed spans:self.planSpans error:&error];
        if (!filter) {
          [self respondError:error.code == ODataIncrementalStoreErrorUnsupportedExpression ? ODataServiceError(501, error.localizedDescription) : error];
          return NO;
        }
        rows = [rows filteredArrayUsingPredicate:filter];
        continue;
      }
      case ODataApplySearch: {
        NSPredicate *search = shape ? nil : [self predicateForSearch:t.search entity:self.entity];
        if (!search) {
          if (shape) [self fail:501 message:@"$apply: search of grouped rows is not supported"];
          return NO;
        }
        rows = [rows filteredArrayUsingPredicate:search];
        continue;
      }
      case ODataApplyCompute: {
        NSMutableArray *out = [NSMutableArray array];
        NSMutableArray *itemExpressions = [NSMutableArray array];
        for (ODataComputeItem *item in t.compute) {
          ODataExpression *expression = [self expression:[self hierarchical:item.expression] over:rows shape:shape computed:computed];
          if (!expression) return NO;
          [itemExpressions addObject:expression];
        }
        if (shape) {
          for (NSDictionary *row in rows) {
            NSMutableDictionary *more = [row mutableCopy];
            for (NSUInteger i = 0; i < t.compute.count; i++) {
              ODataComputeItem *item = t.compute[i];
              id value = [ODataAggregation valueOfExpression:itemExpressions[i] inRow:more error:&error];
              if (!value) {
                [self respondError:ODataServiceError(501, error.localizedDescription)];
                return NO;
              }
              more[item.alias] = value;
            }
            [out addObject:more];
          }
          for (ODataComputeItem *item in t.compute) [shape addObject:@[ item.alias ]];
        } else {
          NSMutableArray *expressions = [NSMutableArray array];
          for (NSUInteger i = 0; i < t.compute.count; i++) {
            NSExpression *expression = [self.predicates valueExpressionForExpression:itemExpressions[i] entity:self.entity
                                                                                     aliases:options.aliases computed:computed error:&error];
            if (!expression) {
              [self respondError:error];
              return NO;
            }
            [expressions addObject:expression];
            computed[t.compute[i].alias] = itemExpressions[i];
          }
          for (id row in rows) {
            OISComputedRow *more = [row isKindOfClass:[OISComputedRow class]] ? row : [[OISComputedRow alloc] init];
            if (more != row) {
              more.object = row;
              more.computed = [NSMutableDictionary dictionary];
            }
            for (NSUInteger i = 0; i < t.compute.count; i++) {
              id value = nil;
              @try {
                value = [expressions[i] expressionValueWithObject:row context:nil];
              } @catch (NSException *exception) {
                value = nil;
              }
              more.computed[t.compute[i].alias] = value ?: [NSNull null];
            }
            [out addObject:more];
          }
        }
        rows = out;
        continue;
      }
      case ODataApplyOrderBy: {
        // Each item with the values of the input it asks for.
        NSMutableArray *items = [NSMutableArray array];
        for (ODataOrderItem *item in t.orderBy) {
          ODataExpression *e = [self expression:[self hierarchical:item.expression] over:rows shape:shape computed:computed];
          if (!e) return NO;
          [items addObject:[ODataOrderItem itemWithExpression:e descending:item.descending]];
        }
        NSArray *descriptors = shape ? [self descriptorsForGroupedOrder:items]
                                     : [self.predicates sortDescriptorsForOrderBy:items entity:self.entity computed:computed
                                                                                 inMemory:&(BOOL){ NO } error:&error];
        if (!descriptors) {
          if (error) [self respondError:error];
          return NO;
        }
        rows = [rows sortedArrayUsingDescriptors:descriptors];
        continue;
      }
      case ODataApplyTop:
      case ODataApplySkip: {
        NSUInteger n = MIN(t.number.unsignedIntegerValue, rows.count);
        rows = t.kind == ODataApplyTop ? [rows subarrayWithRange:NSMakeRange(0, n)] : [rows subarrayWithRange:NSMakeRange(n, rows.count - n)];
        continue;
      }
      case ODataApplyTopBottom: {
        NSMutableArray *values = [NSMutableArray array];
        ODataExpression *of = [self expression:[self hierarchical:t.expression] over:rows shape:shape computed:computed];
        if (!of) return NO;
        double number = t.number.doubleValue;
        if (t.numberExpression) {
          // topcount($these/$count div 3,Amount): a number of the input.
          ODataExpression *count = [self expression:t.numberExpression over:rows shape:shape computed:computed];
          if (!count) return NO;
          id value = [ODataAggregation valueOfExpression:count inRow:@{} error:NULL];
          if (![value isKindOfClass:[NSNumber class]] || [value doubleValue] < 0) {
            [self fail:400 message:[NSString stringWithFormat:@"$apply: %@ of %@ is not a number of none or more", t.method, t.numberExpression]];
            return NO;
          }
          number = [value doubleValue];
          if ([t.method hasSuffix:@"count"]) number = floor(number);
        }
        NSExpression *expression = shape ? nil
            : [self.predicates valueExpressionForExpression:of entity:self.entity aliases:options.aliases computed:computed error:&error];
        if (!shape && !expression) {
          [self respondError:error];
          return NO;
        }
        for (id row in rows) {
          id value = nil;
          if (shape) {
            value = [ODataAggregation valueOfExpression:of inRow:row error:&error];
            if (!value) {
              [self respondError:ODataServiceError(501, error.localizedDescription)];
              return NO;
            }
          } else {
            @try {
              value = [expression expressionValueWithObject:row context:nil];
            } @catch (NSException *exception) {
              value = nil;
            }
          }
          [values addObject:value ?: [NSNull null]];
        }
        rows = [ODataAggregation rows:rows values:values method:t.method number:number];
        continue;
      }
      case ODataApplyConcat: {
        // Each branch on the same input, the results one after the other.
        NSMutableArray *all = [NSMutableArray array];
        NSMutableArray *union_ = [NSMutableArray array];
        BOOL entities = NO, grouped = NO;
        for (NSArray *branch in t.branches) {
          NSArray *branchRows = rows;
          NSMutableArray *branchShape = shape ? [shape mutableCopy] : nil;
          NSMutableDictionary *branchComputed = [computed mutableCopy];
          NSMutableArray *branchExpansions = [expansions mutableCopy];
          if (![self applyTransformations:branch rows:&branchRows shape:&branchShape computed:branchComputed expansions:branchExpansions]) return NO;
          [all addObjectsFromArray:branchRows];
          if (branchShape) {
            grouped = YES;
            for (NSArray *path in branchShape) if (![union_ containsObject:path]) [union_ addObject:path];
          } else {
            entities = YES;
          }
          [computed addEntriesFromDictionary:branchComputed];
          for (NSString *expansion in branchExpansions) if (![expansions containsObject:expansion]) [expansions addObject:expansion];
        }
        if (entities && grouped) {
          [self fail:501 message:@"$apply: concat of entities and grouped rows is not supported"];
          return NO;
        }
        rows = all;
        shape = grouped ? union_ : nil;
        continue;
      }
      case ODataApplyExpand:
        if (shape) {
          [self fail:501 message:@"$apply: expand of grouped rows is not supported"];
          return NO;
        }
        [expansions addObject:t.expansion];
        continue;
      case ODataApplyJoin:
        if (shape) {
          [self fail:501 message:@"$apply: join of grouped rows is not supported"];
          return NO;
        }
        rows = [self rowsJoining:t over:rows computed:computed expansions:expansions];
        if (!rows) return NO;
        continue;
      case ODataApplyGroupBy:
      case ODataApplyAggregate:
        break;
    }
    if (t.sequence.count) {
      if (![self groupRows:&rows shape:&shape by:t computed:computed expansions:expansions]) return NO;
      continue;
    }
    if (shape) {
      // Grouped again: by the paths of the rows as they are.
      rows = [self rowsOfGroupingRows:t over:rows error:&error];
      if (!rows) {
        [self respondError:ODataServiceError(501, error.localizedDescription)];
        return NO;
      }
      shape = [t.groupPaths mutableCopy];
      for (ODataAggregate *aggregate in t.aggregates) [shape addObject:@[ aggregate.alias ]];
      continue;
    }
    rows = [self rowsOfGrouping:t over:rows computed:computed error:&error];
    if (!rows) {
      [self respondError:error];
      return NO;
    }
    shape = [t.groupPaths mutableCopy];
    for (ODataAggregate *aggregate in t.aggregates) [shape addObject:@[ aggregate.alias ]];
  }
  *rowsp = rows;
  *shapep = shape;
  return YES;
}

// A grouping $apply's rows, as the plan made them ($apply, then $filter,
// $orderby, $count, $skip and $top): entities, or grouped rows, whose
// $select keeps what it names.
- (void)didRunApplied
{
  OISRelation *result = self.planResult;
  if (!result.shape) {
    [self writeAppliedEntities:result.rows computed:result.computed count:result.count];
    return;
  }
  ODataQueryOptions *options = self.request.options;
  NSArray *rows = result.rows;
  NSMutableArray *shape = result.shape;
  NSNumber *count = result.count;
  // Grouped rows have no navigation to expand; $select keeps what it names.
  if (options.expand.count) {
    [self fail:400 message:@"The rows of a grouping have no navigation properties to $expand"];
    return;
  }
  if (options.select.count) {
    NSMutableSet *kept = [NSMutableSet set];
    NSMutableArray *selectedShape = [NSMutableArray array];
    for (ODataSelectItem *item in options.select) {
      if (item.isStar) continue;
      [kept addObject:item.path.firstObject];
    }
    if (kept.count) {
      NSMutableArray *projected = [NSMutableArray array];
      for (NSDictionary *row in rows) {
        NSMutableDictionary *only = [NSMutableDictionary dictionary];
        for (NSString *key in row) if ([kept containsObject:key] || [key hasPrefix:@"@"]) only[key] = row[key];
        [projected addObject:only];
      }
      rows = projected;
      for (NSArray *path in shape) if ([kept containsObject:path.firstObject]) [selectedShape addObject:path];
      shape = selectedShape;
    }
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) {
    body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@(%@)", [self contextBase], [self setName], OISSelectListOfPaths(shape)];
  }
  if (count) body[@"@odata.count"] = count;
  body[@"value"] = rows;
  [self respondJSON:body status:200 headers:nil];
}

#pragma mark Collections

- (void)readCollection
{
  ODataQueryOptions *options = self.request.options;
  BOOL grouping = options.apply.count && ![self applyIsFiltersOnly];
  if (!grouping && self.deltaToken) {
    [self readDelta];
    return;
  }
  OISPlan *plan = grouping ? [self planAppliedRead] : [self planPlainRead];
  if (!plan) return;
  [self runPlan:plan then:grouping ? @selector(didRunApplied) : @selector(didRunCollection)];
}

- (void)didRunCollection
{
  OISRelation *result = self.planResult;
  self.objects = result.rows;
  self.count = result.count;
  if (result.hasMore) self.nextLink = [self nextLinkWithToken:self.skipToken + self.pageSize];
  [self writeCollection];
}

// A read a delta link can follow: a set (or a cast of it) with its
// filter, not part of it by $top or $skip, nor a navigation's or a
// function's, nor grouped.
- (BOOL)canTrackChanges
{
  ODataQueryOptions *options = self.request.options;
  if (self.parent || self.members || self.referencesOnly || self.kind != OISTargetCollection) return NO;
  if (options.top || options.skip || (options.apply.count && ![self applyIsFiltersOnly])) return NO;
  return [[self.service handlerForEntity:OISRootEntity(self.entity)] canTrackChanges];
}

// This request again, from this many rows on.
- (NSString *)nextLinkWithToken:(NSUInteger)token
{
  NSString *skip = [NSString stringWithFormat:@"%lu", (unsigned long)token];
  if (self.trackingToken) skip = [skip stringByAppendingFormat:@"~%@", [self scopedToken:self.trackingToken]];
  return [self linkReplacing:@"$skiptoken" with:skip];
}

// This request's delta link: its options, and where its changes begin.
- (NSString *)deltaLink
{
  return [self linkReplacing:@"$deltatoken" with:[self scopedToken:self.trackingToken]];
}

// The caller's scope version (the handler's), as a link carries it after
// the handler's token: token*version. A history token is Base64URL, which
// has no *.
- (NSString *)scopeOfLinks
{
  NSString *version = [self.handler scopeVersionForRequest:self.request];
  return version.length ? ODataBase64URLString([version dataUsingEncoding:NSUTF8StringEncoding]) : nil;
}

- (NSString *)scopedToken:(NSString *)token
{
  NSString *scope = [self scopeOfLinks];
  return scope ? [token stringByAppendingFormat:@"*%@", scope] : token;
}

- (NSString *)tokenCheckingScope:(NSString *)link
{
  NSRange star = [link rangeOfString:@"*" options:NSBackwardsSearch];
  NSString *given = star.location == NSNotFound ? nil : [link substringFromIndex:NSMaxRange(star)];
  NSString *now = [self scopeOfLinks];
  if (!(given == now || [given isEqualToString:now])) {
    [self fail:410 message:@"What this set shows you has changed since that link; read it again"];
    return nil;
  }
  return star.location == NSNotFound ? link : [link substringToIndex:star.location];
}

// This request again, with this option (and neither $skiptoken nor
// $deltatoken otherwise).
- (NSString *)linkReplacing:(NSString *)option with:(NSString *)value
{
  NSMutableArray *pairs = [NSMutableArray array];
  NSString *raw = self.exchange.request.URL.query;
  for (NSString *pair in raw.length ? [raw componentsSeparatedByString:@"&"] : @[]) {
    NSString *key = OISPercentDecoded([pair componentsSeparatedByString:@"="][0]);
    if (pair.length && ![key isEqualToString:@"$skiptoken"] && ![key isEqualToString:@"$deltatoken"]) [pairs addObject:pair];
  }
  [pairs addObject:[NSString stringWithFormat:@"%@=%@", option, value]];
  NSString *path = [self encodedPathOf:self.exchange.request.URL];
  NSString *rootPath = self.service.serviceRoot.path ?: @"/";
  if (![rootPath hasSuffix:@"/"]) rootPath = [rootPath stringByAppendingString:@"/"];
  NSString *resource = path.length > rootPath.length ? [path substringFromIndex:rootPath.length] : @"";
  return [NSString stringWithFormat:@"%@%@?%@", [self rootString], resource, [pairs componentsJoinedByString:@"&"]];
}

- (void)writeCollection
{
  NSError *error = nil;
  NSMutableArray *values = [NSMutableArray array];
  for (NSManagedObject *object in self.objects) {
    if (self.referencesOnly) {
      [values addObject:@{ @"@odata.id": [self canonicalPathOf:object] }];
      continue;
    }
    NSDictionary *json = [self JSONForObject:object options:self.request.options expected:self.entity error:&error];
    if (!json) {
      [self respondError:error];
      return;
    }
    [values addObject:json];
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) {
    body[@"@odata.context"] = self.referencesOnly
        ? [NSString stringWithFormat:@"%@#Collection($ref)", [self contextBase]]
        : [NSString stringWithFormat:@"%@#%@%@%@", [self contextBase], [self setName], [self castSuffixFor:self.entity],
                                     [self selectListForOptions:self.request.options]];
  }
  if (self.count) body[@"@odata.count"] = self.count;
  body[@"value"] = values;
  if (self.nextLink) body[@"@odata.nextLink"] = self.nextLink;
  else if (self.trackingToken) body[@"@odata.deltaLink"] = [self deltaLink];
  NSMutableArray *applied = [NSMutableArray array];
  if (self.pagedByPreference) [applied addObject:[NSString stringWithFormat:@"odata.maxpagesize=%lu", (unsigned long)self.pageSize]];
  if (self.trackingToken) [applied addObject:@"odata.track-changes"];
  NSDictionary *headers = applied.count ? @{ @"Preference-Applied": [applied componentsJoinedByString:@", "] } : nil;
  [self respondJSON:body status:200 headers:headers];
}

#pragma mark Limits

// Rows fetched for work done in memory: no more than the service takes.
- (BOOL)withinRowsInMemory:(NSUInteger)count
{
  NSUInteger most = self.service.maxRowsInMemory;
  if (!most || count <= most) return YES;
  [self fail:400 message:[NSString stringWithFormat:@"This reads more than the %lu rows the service works on in memory: narrow it with $filter",
                                                    (unsigned long)most]];
  return NO;
}

#pragma mark Application time

// $at, or $from with $to or $toInclusive (OData-Temporal section 4.2.3),
// as a filter over a timeline set's periods; NSNull where the set has no
// application time, which they then do not affect.
- (id)predicateForApplicationTimeOf:(ODataQueryOptions *)options entity:(NSEntityDescription *)entity error:(NSError **)error
{
  OISTimeline *timeline = [OISTimeline timelineOfEntity:entity mapper:self.mapper];
  if (!timeline) return [NSNull null];
  NSDictionary *q = options.temporalText;
  BOOL at = q[@"$at"] != nil, from = q[@"$from"] != nil, to = q[@"$to"] != nil, inclusive = q[@"$toInclusive"] != nil;
  if ((at && (from || to || inclusive)) || (to && inclusive) || ((to || inclusive) && !from)) {
    if (error) *error = ODataServiceError(400, @"$at alone, or $from with $to or $toInclusive, or $from alone");
    return nil;
  }
  for (ODataExpression *e in @[ options.temporalAt ?: [NSNull null], options.temporalFrom ?: [NSNull null],
                                options.temporalTo ?: [NSNull null], options.temporalToInclusive ?: [NSNull null] ]) {
    if ((id)e != [NSNull null] && e.kind != ODataExpressionLiteral) {
      if (error) *error = ODataServiceError(501, @"Only a literal is taken for $at, $from, $to and $toInclusive");
      return nil;
    }
  }
  NSString *text = at ? [timeline filterFrom:q[@"$at"] to:q[@"$at"] inclusive:YES]
                      : [timeline filterFrom:q[@"$from"] to:q[@"$to"] ?: q[@"$toInclusive"] inclusive:!to];
  ODataExpression *expression = [ODataExpression expressionWithString:text error:error];
  if (!expression) return nil;
  return [self.predicates predicateForExpression:expression entity:entity aliases:nil computed:nil
                                                 spans:self.planSpans error:error];
}

- (void)didExpandTimeslices
{
  NSError *error = nil;
  NSMutableArray *value = [NSMutableArray array];
  NSString *context = [NSString stringWithFormat:@"%@#%@/$entity", [self contextBase], [self setName]];
  for (OISTimeslice *result in self.timeslices) {
    NSMutableDictionary *json;
    if (result.object) {
      json = [self JSONForObject:result.object options:self.request.options expected:self.entity error:&error];
      if (!json) {
        [self respondError:error];
        return;
      }
    } else {
      json = [NSMutableDictionary dictionary];
      for (NSAttributeDescription *attribute in [self servedAttributesOf:self.entity]) {
        id v = result.values[attribute.name];
        json[[self.mapper propertyForAttribute:attribute]] = [self.coder JSONForCoreDataValue:v attribute:attribute];
      }
    }
    json[@"@odata.context"] = context;
    [value addObject:@{ @"Timeslice": json }];
  }
  [self respondJSON:@{ @"@odata.context": [NSString stringWithFormat:@"%@#Collection(Org.OData.Temporal.V1.TimesliceWithPeriod)", [self contextBase]],
                       @"value": value } status:200 headers:nil];
}

#pragma mark $compute

// The request's computed names, and what each stands for.
- (NSDictionary<NSString *, ODataExpression *> *)computedNamesOf:(ODataQueryOptions *)options
{
  NSMutableDictionary *names = [NSMutableDictionary dictionary];
  for (ODataComputeItem *item in options.compute) names[item.alias] = [self resolved:item.expression options:options];
  return names;
}

// A computed value of an object, as JSON: typed by what it is, null when
// it cannot be computed (a null operand).
- (id)computedValue:(ODataComputeItem *)item of:(NSManagedObject *)object options:(ODataQueryOptions *)options error:(NSError **)error
{
  if (!self.computedExpressions) self.computedExpressions = [NSMutableDictionary dictionary];
  NSString *key = [NSString stringWithFormat:@"%p/%@/%@", options, object.entity.name, item.alias];
  NSExpression *expression = self.computedExpressions[key];
  if (!expression) {
    expression = [self.predicates valueExpressionForExpression:[self resolved:item.expression options:options] entity:object.entity
                                                               aliases:self.request.options.aliases computed:[self computedNamesOf:options] error:error];
    if (!expression) return nil;
    self.computedExpressions[key] = expression;
  }
  id value = nil;
  @try {
    value = [expression expressionValueWithObject:object context:nil];
  } @catch (NSException *exception) {
    value = nil;
  }
  return [self JSONForComputedValue:value];
}

// A value computed here, as JSON: typed by what it is.
- (id)JSONForComputedValue:(id)value
{
  if (!value || value == [NSNull null]) return [NSNull null];
  // JSON already: a traversal's sparse instance (section 6.2.2).
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) return value;
  NSString *type = @"Edm.String";
  if ([value isKindOfClass:[NSDecimalNumber class]]) type = @"Edm.Decimal";
  else if ([value isKindOfClass:[NSNumber class]]) {
    const char *objCType = [value objCType];
    if ([value isKindOfClass:[@YES class]]) type = @"Edm.Boolean";
    else type = (*objCType == 'd' || *objCType == 'f') ? @"Edm.Double" : @"Edm.Int64";
  } else if ([value isKindOfClass:[NSDate class]]) type = @"Edm.DateTimeOffset";
  else if ([value isKindOfClass:[NSData class]]) type = @"Edm.Binary";
  return [self.coder JSONForValue:value typeName:type] ?: [NSNull null];
}

#pragma mark Status monitors

// Part 1 section 11.6: 202 while the request is under way, then its answer
// as application/http (4.01 says its status in AsyncResult too); DELETE
// forgets it. One that is not there, or not the caller's, is 404.
- (void)statusMonitor:(NSString *)identifier
{
  OISAsyncJob *job = identifier ? [self.service asyncJobWithIdentifier:identifier] : nil;
  NSString *owner = job.request.principal.subject;
  if (!job || (owner && ![owner isEqualToString:self.request.principal.subject ?: @""])) {
    [self fail:404 message:@"There is no such asynchronous request"];
    return;
  }
  if ([self.request.method isEqualToString:@"DELETE"]) {
    [self.service forgetAsyncJob:job];
    [self respondStatus:204 headers:nil body:nil];
    return;
  }
  if (![self.request.method isEqualToString:@"GET"]) {
    [self methodNotAllowed:@[ @"GET", @"DELETE" ]];
    return;
  }
  BOOL finished;
  NSInteger status;
  NSDictionary *headers;
  NSData *body;
  @synchronized (job) {
    finished = job.finished;
    status = job.status;
    headers = job.headers;
    body = job.body;
  }
  if (!finished) {
    [self respondStatus:202 headers:@{ @"Location": [self.service statusMonitorOf:job], @"Retry-After": @"1" } body:nil];
    return;
  }
  NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:@"application/http" forKey:@"Content-Type"];
  if ([self.request.version isEqualToString:@"4.01"]) out[@"AsyncResult"] = [NSString stringWithFormat:@"%ld", (long)status];
  [self respondStatus:200 headers:out body:ODataHTTPResponseMessage(status, headers ?: @{}, body)];
}

#pragma mark Deltas

// What changed since a delta link's token (Part 1 section 11.3), from the
// stores' persistent history: the set's entities added or changed since,
// as they are now and as the request selects and expands them; those
// deleted, by the key their tombstone kept; and those that no longer
// match the request, removed as changed. The changes come in one
// response, with the delta link to follow next.
- (void)readDelta
{
  if (![self canTrackChanges]) {
    [self fail:410 message:@"The changes of this set are not tracked; read it again"];
    return;
  }
  NSString *token = [self tokenCheckingScope:self.deltaToken];
  if (!token) return;
  self.deltaToken = token;
  [self runPlan:[self planDelta] then:@selector(didRunDelta)];
}

- (void)didRunDelta
{
  [self writeDelta:self.planResult.rows removed:self.deltaRemoved ?: @[]];
}

// What changed since a delta token, as the handler says: the changed
// objects, the deleted ones' paths, and the token a delta link goes on
// from. NO once answered, with the error.
// Whether an expression reads only what a deleted row's tombstone kept
// (values): constants, and key paths that begin with a kept attribute.
static BOOL OISReadsOnlyKept(NSExpression *expression, NSDictionary *values)
{
  switch (expression.expressionType) {
    case NSConstantValueExpressionType:
      return YES;
    case NSKeyPathExpressionType: {
      NSString *first = [expression.keyPath componentsSeparatedByString:@"."].firstObject;
      return first.length && values[first] != nil;
    }
    case NSAggregateExpressionType:
      for (id member in expression.collection) {
        if (![member isKindOfClass:[NSExpression class]] || !OISReadsOnlyKept(member, values)) return NO;
      }
      return YES;
    case NSFunctionExpressionType:
      for (NSExpression *argument in expression.arguments) {
        if (!OISReadsOnlyKept(argument, values)) return NO;
      }
      return expression.operand.expressionType == NSConstantValueExpressionType || OISReadsOnlyKept(expression.operand, values);
    default:
      return NO;
  }
}

static BOOL OISPredicateReadsOnlyKept(NSPredicate *predicate, NSDictionary *values)
{
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    for (NSPredicate *sub in [(NSCompoundPredicate *)predicate subpredicates]) {
      if (!OISPredicateReadsOnlyKept(sub, values)) return NO;
    }
    return YES;
  }
  if ([predicate isKindOfClass:[NSComparisonPredicate class]]) {
    NSComparisonPredicate *comparison = (NSComparisonPredicate *)predicate;
    return comparison.comparisonPredicateModifier == NSDirectPredicateModifier &&
           comparison.predicateOperatorType != NSCustomSelectorPredicateOperatorType &&
           OISReadsOnlyKept(comparison.leftExpression, values) && OISReadsOnlyKept(comparison.rightExpression, values);
  }
  NSString *format = predicate.predicateFormat;
  return [format isEqualToString:@"TRUEPREDICATE"] || [format isEqualToString:@"FALSEPREDICATE"];
}

- (BOOL)takeChanges:(ODataChanges *)changes
{
  NSMutableArray *paths = [NSMutableArray array];
  // A deletion is the business of those who could see the row: by what its
  // tombstone kept, when the predicate reads nothing else; else everyone's.
  NSPredicate *visible = [self.handler predicateForVisibleObjectsInRequest:self.request];
  for (NSDictionary *deleted in changes.deleted) {
    NSDictionary *values = deleted[@"values"];
    if (visible && [values isKindOfClass:[NSDictionary class]] && OISPredicateReadsOnlyKept(visible, values) &&
        ![visible evaluateWithObject:values]) {
      continue;
    }
    NSString *path = [self canonicalPathOfValues:deleted[@"values"] entity:deleted[@"entity"]];
    if (!path) {
      [self fail:410 message:@"A deleted entity's key was not kept; read the set again"];
      return NO;
    }
    [paths addObject:path];
  }
  self.deltaDeleted = paths;
  self.deltaChanged = changes.changed;
  self.trackingToken = changes.token;
  return YES;
}

// A deleted entity, or one no longer in the request's rows: 4.01's
// removed control information, 4.0's $deletedEntity.
- (NSDictionary *)removedEntry:(NSString *)path reason:(NSString *)reason
{
  if ([self.request.version isEqualToString:@"4.0"]) {
    return @{ @"@odata.context": [NSString stringWithFormat:@"%@#%@/$deletedEntity", [self contextBase], [self setName]],
              @"id": path, @"reason": reason };
  }
  return @{ @"@odata.removed": @{ @"reason": reason }, @"@odata.id": path };
}

- (void)writeDelta:(NSArray<NSManagedObject *> *)objects removed:(NSArray *)removed
{
  NSError *error = nil;
  NSMutableArray *values = [NSMutableArray array];
  for (NSManagedObject *object in objects) {
    NSDictionary *json = [self JSONForObject:object options:self.request.options expected:self.entity error:&error];
    if (!json) {
      [self respondError:error];
      return;
    }
    [values addObject:json];
  }
  [values addObjectsFromArray:removed];
  for (NSString *path in self.deltaDeleted) [values addObject:[self removedEntry:path reason:@"deleted"]];
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) {
    body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@%@%@/$delta", [self contextBase], [self setName], [self castSuffixFor:self.entity],
                                                         [self selectListForOptions:self.request.options]];
  }
  body[@"value"] = values;
  body[@"@odata.deltaLink"] = [self deltaLink];
  [self respondJSON:body status:200 headers:nil];
}

- (NSDictionary *)entityBodyFor:(NSManagedObject *)object error:(NSError **)error
{
  ODataQueryOptions *options = self.responseOptions ?: self.request.options;
  NSMutableDictionary *json = [self JSONForObject:object options:options expected:nil error:error];
  if (!json) return nil;
  if (![self.metadataLevel isEqualToString:@"none"]) {
    NSEntityDescription *root = OISRootEntity(object.entity);
    NSString *cast = object.entity == root ? @"" : [@"/" stringByAppendingString:[self.service.writer typeNameForEntity:object.entity]];
    json[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@%@%@/$entity", [self contextBase],
                               [self.service entitySetForEntity:root], cast, [self selectListForOptions:options]];
  }
  return json;
}

- (void)readEntity
{
  NSString *etag = [self etagOf:self.object];
  NSString *unless = [self.request valueForHeader:@"If-None-Match"];
  if (unless.length && ([unless isEqualToString:@"*"] || [[unless componentsSeparatedByString:@","] containsObject:etag])) {
    [self respondStatus:304 headers:@{ @"ETag": etag } body:nil];
    return;
  }
  [self writeEntity:self.object status:200 headers:@{ @"ETag": etag }];
}

// An entity as a response: its expansions read first (the plan's Nest),
// then its body.
- (void)writeEntity:(NSManagedObject *)object status:(NSInteger)status headers:(NSDictionary *)headers
{
  self.writtenObject = object;
  self.writtenStatus = status;
  self.writtenHeaders = headers;
  ODataQueryOptions *options = self.responseOptions ?: self.request.options;
  [self runPlan:[self planOfObjects:@[ object ] options:options entity:object.entity] then:@selector(didExpandEntity)];
}

- (void)didExpandEntity
{
  NSError *error = nil;
  NSDictionary *json = [self entityBodyFor:self.writtenObject error:&error];
  if (!json) {
    [self respondError:error];
    return;
  }
  [self respondJSON:json status:self.writtenStatus headers:self.writtenHeaders];
}

- (void)readProperty
{
  id value = [self.object valueForKey:self.attribute.name];
  NSDictionary *headers = @{ @"ETag": [self etagOf:self.object] };
  if (!value) {
    [self respondStatus:204 headers:headers body:nil];
    return;
  }
  id json = [self.coder JSONForCoreDataValue:value attribute:self.attribute];
  if (self.kind == OISTargetValue) {
    if ([value isKindOfClass:[NSData class]]) {
      NSMutableDictionary *all = [headers mutableCopy];
      all[@"Content-Type"] = @"application/octet-stream";
      [self respondStatus:200 headers:all body:value];
      return;
    }
    NSString *text = [json isKindOfClass:[NSString class]] ? json : [json description];
    [self respondText:text contentType:@"text/plain;charset=utf-8" headers:headers];
    return;
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) {
    body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@/%@", [self contextBase], [self canonicalPathOf:self.object],
                               [self.mapper propertyForAttribute:self.attribute]];
  }
  body[@"value"] = json;
  [self respondJSON:body status:200 headers:headers];
}

#pragma mark Operations

- (void)callOperation:(OISServedOperation *)operation arguments:(NSDictionary *)arguments
{
  // A function's entities can be read on from (Part 2 section 4.5.2); an
  // action's result, and a value, cannot.
  if (self.index < self.request.path.segments.count && (operation.isAction || !operation.returns.entity)) {
    [self fail:400 message:[NSString stringWithFormat:@"Nothing can follow %@", operation.name]];
    return;
  }
  self.operation = operation;
  self.operationArguments = arguments;
  self.kind = OISTargetOperation;
  [self dispatch];
}

// A JSON value as the value a parameter takes: an entity a Lookup of its
// reference (read through the handler before the call), anything else by
// its type.
- (id)valueOfJSON:(id)json parameter:(OISServedParameter *)parameter error:(NSError **)error
{
  if (!json || json == [NSNull null]) return nil;
  BOOL collection = [parameter.type hasPrefix:@"Collection("];
  NSString *element = collection ? [parameter.type substringWithRange:NSMakeRange(11, parameter.type.length - 12)] : parameter.type;
  if (parameter.entity) {
    NSArray *references = collection ? ([json isKindOfClass:[NSArray class]] ? json : nil) : @[ json ];
    if (!references) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ takes a collection", parameter.name]);
      return nil;
    }
    NSMutableArray *lookups = [NSMutableArray array];
    for (id reference in references) {
      id text = [reference isKindOfClass:[NSDictionary class]] ? reference[@"@odata.id"] : reference;
      OISPlanNode *lookup = [self lookupOfReference:text error:error];
      if (!lookup) return nil;
      [lookups addObject:lookup];
    }
    return collection ? lookups : lookups.firstObject;
  }
  if (collection) {
    if (![json isKindOfClass:[NSArray class]]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ takes a collection", parameter.name]);
      return nil;
    }
    NSMutableArray *values = [NSMutableArray array];
    for (id item in json) {
      id value = item == [NSNull null] ? item : [self.coder valueForJSON:item typeName:element];
      if (!value) {
        if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a value of %@", item, element]);
        return nil;
      }
      [values addObject:value];
    }
    return values;
  }
  // A number for a C number: a JSON number, or a string that reads as one
  // (IEEE754Compatible, INF, NaN).
  if (parameter.scalar && ![json isKindOfClass:[NSNumber class]]) {
    NSScanner *scanner = [json isKindOfClass:[NSString class]] ? [NSScanner scannerWithString:json] : nil;
    double number;
    BOOL numeric = scanner && ([scanner scanDouble:&number] && scanner.isAtEnd);
    if (!numeric && ![@[ @"INF", @"-INF", @"NaN" ] containsObject:json ?: @""]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a value of %@", json, parameter.name]);
      return nil;
    }
  }
  id value = [self.coder valueForJSON:json typeName:element];
  if (!value || value == [NSNull null]) {
    if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a value of %@", json, parameter.name]);
  }
  return value == [NSNull null] ? nil : value;
}

// The arguments, by parameter, from a function's URL or an action's body;
// nil after answering with an error.
- (NSArray *)operationValues
{
  OISServedOperation *operation = self.operation;
  NSMutableDictionary *given = [NSMutableDictionary dictionary];  // name -> JSON
  NSMutableSet *names = [NSMutableSet setWithArray:[operation.parameters valueForKey:@"name"]];
  if (operation.isAction) {
    NSDictionary *body = @{};
    if (self.exchange.request.HTTPBody.length) {
      body = [self bodyJSON];
      if (!body) return nil;
    }
    for (NSString *key in body) {
      if ([key hasPrefix:@"@"]) continue;
      if (![names containsObject:key]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ has no parameter %@", operation.name, key]];
        return nil;
      }
      given[key] = body[key];
    }
  } else {
    for (NSString *key in self.operationArguments) {
      if (![names containsObject:key]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ has no parameter %@", operation.name, key]];
        return nil;
      }
      ODataExpression *argument = self.operationArguments[key];
      id json = nil;
      for (NSInteger depth = 0; argument.kind == ODataExpressionAlias && depth < 8; depth++) {
        json = self.JSONAliases[argument.name];
        if (json) break;
        argument = self.request.options.aliases[argument.name];
      }
      if (!json) {
        if (argument.kind != ODataExpressionLiteral) {
          [self fail:(argument ? 501 : 400) message:[NSString stringWithFormat:@"%@: an argument is a value or a parameter alias", key]];
          return nil;
        }
        json = argument.value ?: [NSNull null];
      }
      given[key] = json;
    }
  }

  NSMutableArray *values = [NSMutableArray array];
  for (OISServedParameter *parameter in operation.parameters) {
    NSError *error = nil;
    id value = [self valueOfJSON:given[parameter.name] parameter:parameter error:&error];
    if (error) {
      [self respondError:error];
      return nil;
    }
    if (!value && parameter.scalar) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ needs %@", operation.name, parameter.name]];
      return nil;
    }
    [values addObject:value ?: [NSNull null]];
  }
  return values;
}

static void OISSetScalarArgument(NSInvocation *invocation, NSInteger index, char type, NSNumber *number)
{
  switch (type) {
    case 'c': { char v = (char)number.boolValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'C': { unsigned char v = (unsigned char)number.boolValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'B': { bool v = number.boolValue; [invocation setArgument:&v atIndex:index]; break; }
    case 's': { int16_t v = number.shortValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'S': { uint16_t v = number.unsignedShortValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'i':
    case 'l': { int32_t v = number.intValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'I':
    case 'L': { uint32_t v = number.unsignedIntValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'q': { int64_t v = number.longLongValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'Q': { uint64_t v = number.unsignedLongLongValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'f': { float v = number.floatValue; [invocation setArgument:&v atIndex:index]; break; }
    default: { double v = number.doubleValue; [invocation setArgument:&v atIndex:index]; break; }
  }
}

static NSNumber *OISScalarReturnValue(NSInvocation *invocation, char type)
{
  switch (type) {
    case 'c': { char v; [invocation getReturnValue:&v]; return @(v != 0); }
    case 'C': { unsigned char v; [invocation getReturnValue:&v]; return @(v != 0); }
    case 'B': { bool v; [invocation getReturnValue:&v]; return @(v); }
    case 's': { int16_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'S': { uint16_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'i':
    case 'l': { int32_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'I':
    case 'L': { uint32_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'q': { int64_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'Q': { uint64_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'f': { float v; [invocation getReturnValue:&v]; return @(v); }
    default: { double v; [invocation getReturnValue:&v]; return @(v); }
  }
}

// The entities its parameters name read first, through their handlers
// (the call's plan: Lookups, then Call).
- (NSDictionary<NSString *, NSSet<NSString *> *> *)permissionsOfOperation
{
  OISServedOperation *operation = self.operation;
  NSMutableDictionary *permissions = [NSMutableDictionary dictionary];
  if (operation.scopes.count) permissions[[@"call " stringByAppendingString:operation.qualifiedName]] = operation.scopes;
  // What it answers with is its own; what that is read with (expanded)
  // is read as any response is -- when the path ends at it, else as the
  // walk goes on from it.
  BOOL last = self.index >= self.request.path.segments.count;
  if (operation.returns.entity && last) {
    [self addReadsOf:[self planOfObjects:@[] options:self.request.options entity:operation.returns.entity] into:permissions];
  }
  return permissions;
}

- (void)invokeOperation
{
  if (![self permitsAll:[self permissionsOfOperation]]) return;
  NSArray *values = [self operationValues];
  if (!values) return;
  NSMutableArray *lookups = [NSMutableArray array];
  for (id value in values) {
    for (id item in [value isKindOfClass:[NSArray class]] ? value : @[ value ]) {
      if ([item isKindOfClass:[OISPlanNode class]]) [lookups addObject:item];
    }
  }
  if (!lookups.count && !(self.explaining && self.operation.isAction)) {
    [self invokeOperationWith:values];
    return;
  }
  self.operationValuesPlanned = values;
  [self readLookups:lookups call:self.operation.name then:@selector(didReadOperationValues)];
}

- (void)didReadOperationValues
{
  NSMutableArray *values = [NSMutableArray array];
  for (id value in self.operationValuesPlanned) {
    if ([value isKindOfClass:[OISPlanNode class]]) {
      [values addObject:[self resultOf:value] ?: [NSNull null]];
    } else if ([value isKindOfClass:[NSArray class]]) {
      NSMutableArray *items = [NSMutableArray array];
      for (id item in value) [items addObject:[item isKindOfClass:[OISPlanNode class]] ? [self resultOf:item] : item];
      [values addObject:items];
    } else {
      [values addObject:value];
    }
  }
  [self invokeOperationWith:values];
}

- (void)invokeOperationWith:(NSArray *)values
{
  OISServedOperation *operation = self.operation;

  id target;
  if (!operation.boundEntity) {
    target = self.service.serviceOperations;
  } else if (operation.boundToCollection) {
    target = NSClassFromString(operation.boundEntity.managedObjectClassName);
    NSError *error = nil;
    NSFetchRequest *collection = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
    collection.predicate = [self collectionPredicateWithFilter:NO error:&error];
    if (!collection.predicate) {
      [self respondError:error];
      return;
    }
    self.request.collectionFetchRequest = collection;
  } else {
    target = self.object;
  }
  if (!target) {
    [self fail:500 message:[NSString stringWithFormat:@"%@ has nothing to call", operation.signature]];
    return;
  }

  NSMethodSignature *signature = [target methodSignatureForSelector:operation.selector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
  invocation.target = target;
  invocation.selector = operation.selector;
  for (NSUInteger i = 0; i < operation.parameters.count; i++) {
    OISServedParameter *parameter = operation.parameters[i];
    id value = values[i] == [NSNull null] ? nil : values[i];
    if (parameter.scalar) {
      OISSetScalarArgument(invocation, (NSInteger)i + 2, parameter.scalar, value);
    } else {
      [invocation setArgument:&value atIndex:(NSInteger)i + 2];
    }
  }
  [self beginOperationCall:operation target:target];
  ODataReply *reply = [self replyWithAction:@selector(didInvokeOperation:)];
  [invocation setArgument:&reply atIndex:(NSInteger)operation.parameters.count + 2];
  [invocation invoke];
  // Current while it ran here; what it answers later is still its own.
  [self.callSpan resignCurrent];

  id result = nil;
  if (operation.returns.scalar) {
    result = OISScalarReturnValue(invocation, operation.returns.scalar);
  } else if (operation.returns) {
    __unsafe_unretained id returned = nil;
    [invocation getReturnValue:&returned];
    result = returned;
  }
  [reply returned:result];
}

// A function's entities, read as any collection or entity: the rest of the
// path, and the query options.
- (void)composeOn:(id)result
{
  OISServedOperation *operation = self.operation;
  self.operation = nil;
  NSEntityDescription *entity = operation.returns.entity;
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  if (!handler) {
    [self fail:500 message:[NSString stringWithFormat:@"%@ returns entities of no entity set", operation.signature]];
    return;
  }
  self.handler = handler;
  self.parent = nil;
  self.navigation = nil;
  self.referrer = nil;
  self.referrerNavigation = nil;
  if ([operation.returns.type hasPrefix:@"Collection("]) {
    NSArray *items = [result isKindOfClass:[NSSet class]] ? [result allObjects]
                   : [result isKindOfClass:[NSOrderedSet class]] ? [result array]
                   : [result isKindOfClass:[NSArray class]] ? result : nil;
    if (!items && result && result != [NSNull null]) {
      [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not a collection", operation.signature, [result class]]];
      return;
    }
    for (id item in items) {
      if (![item isKindOfClass:[NSManagedObject class]]) {
        [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not an entity", operation.signature, [item class]]];
        return;
      }
    }
    self.members = items ?: @[];
    self.entity = entity;
    self.object = nil;
    self.kind = OISTargetCollection;
  } else {
    if (!result || result == [NSNull null]) {
      [self respondStatus:204 headers:@{} body:nil];
      return;
    }
    if (![result isKindOfClass:[NSManagedObject class]]) {
      [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not an entity", operation.signature, [result class]]];
      return;
    }
    self.object = result;
    self.entity = [result entity];
    self.kind = OISTargetEntity;
  }
  [self walk];
}

- (void)didExpandOperationResults
{
  [self didInvokeOperation:self.resumeReply];
}

- (void)didInvokeOperation:(ODataReply *)reply
{
  OISServedOperation *operation = self.operation;
  if (reply.error) {
    [self endOperationCall:reply.error];
    [self.request.context rollback];
    [self respondError:reply.error];
    return;
  }
  // An action may have changed things (saved as part of its call: one that
  // fails is answered with the call still open, which marks it failed); a
  // function has no business to.
  if (operation.isAction && self.request.context.hasChanges && ![self save]) return;
  [self endOperationCall:nil];
  if (!operation.isAction) [self.request.context rollback];
  if (!operation.isAction && operation.returns.entity) {
    [self composeOn:reply.result];
    return;
  }

  id result = reply.result;
  OISServedParameter *returns = operation.returns;
  if (!returns || !result || result == [NSNull null]) {
    [self respondStatus:204 headers:@{} body:nil];
    return;
  }
  BOOL collection = [returns.type hasPrefix:@"Collection("];
  NSString *element = collection ? [returns.type substringWithRange:NSMakeRange(11, returns.type.length - 12)] : returns.type;
  NSArray *items = nil;
  if (collection) {
    if ([result isKindOfClass:[NSArray class]]) items = result;
    else if ([result isKindOfClass:[NSSet class]]) items = [result allObjects];
    else if ([result isKindOfClass:[NSOrderedSet class]]) items = [result array];
    if (!items) {
      [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not a collection", operation.signature, [result class]]];
      return;
    }
  }
  NSError *error = nil;
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  BOOL none = [self.metadataLevel isEqualToString:@"none"];

  if (returns.entity) {
    NSEntityDescription *root = OISRootEntity(returns.entity);
    for (id item in items ?: @[ result ]) {
      if (![item isKindOfClass:[NSManagedObject class]]) {
        [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not an entity", operation.signature, [item class]]];
        return;
      }
    }
    if (!collection) {
      [self writeEntity:result status:200 headers:@{ @"ETag": [self etagOf:result] }];
      return;
    }
    // Their expansions read first; then this again, which is done by then
    // with everything before (a function rolled back, an action saved).
    if (!self.planResult) {
      self.resumeReply = reply;
      [self runPlan:[self planOfObjects:items options:self.request.options entity:returns.entity] then:@selector(didExpandOperationResults)];
      return;
    }
    NSMutableArray *values = [NSMutableArray array];
    for (NSManagedObject *item in items) {
      NSDictionary *json = [self JSONForObject:item options:self.request.options expected:returns.entity error:&error];
      if (!json) {
        [self respondError:error];
        return;
      }
      [values addObject:json];
    }
    if (!none) {
      body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@%@", [self contextBase], [self.service entitySetForEntity:root],
                                 [self selectListForOptions:self.request.options]];
    }
    body[@"value"] = values;
    [self respondJSON:body status:200 headers:nil];
    return;
  }

  if (collection) {
    NSMutableArray *values = [NSMutableArray array];
    for (id item in items) [values addObject:[self.coder JSONForValue:(item == [NSNull null] ? nil : item) typeName:element]];
    body[@"value"] = values;
  } else {
    body[@"value"] = [self.coder JSONForValue:result typeName:element];
  }
  if (!none) body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@", [self contextBase], returns.type];
  [self respondJSON:body status:200 headers:nil];
}

#pragma mark Types

// The entity a qualified type name stands for (Default.Manager), among
// those the service serves; nil when none.
- (NSEntityDescription *)entityForTypeName:(NSString *)name
{
  for (NSEntityDescription *entity in self.service.writer.entities) {
    if ([[self.service.writer typeNameForEntity:entity] isEqualToString:name]) return entity;
  }
  return nil;
}

// Collections of a derived type are written with a cast after their set:
// Employees/Default.Manager.
- (NSString *)castSuffixFor:(NSEntityDescription *)entity
{
  return entity == OISRootEntity(entity) ? @"" : [@"/" stringByAppendingString:[self.service.writer typeNameForEntity:entity]];
}

#pragma mark References and single properties

- (void)readReference
{
  if (self.referencesCollection) {
    self.referencesOnly = YES;
    [self readCollection];
    return;
  }
  if (!self.object) {
    [self respondStatus:204 headers:@{} body:nil];
    return;
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) body[@"@odata.context"] = [NSString stringWithFormat:@"%@#$ref", [self contextBase]];
  body[@"@odata.id"] = [self canonicalPathOf:self.object];
  [self respondJSON:body status:200 headers:nil];
}

// PUT a to-one reference, POST one to a collection, DELETE either (Part 1
// section 11.4.6): an update of the entity that holds the relationship.
#pragma mark Writes

- (NSDictionary *)bodyJSON
{
  if (self.parsedBody) return self.parsedBody;
  NSString *type = [self.request valueForHeader:@"Content-Type"].lowercaseString;
  if (type.length && ![type hasPrefix:@"application/json"]) {
    [self fail:415 message:@"The body must be application/json"];
    return nil;
  }
  NSData *data = self.exchange.request.HTTPBody;
  if (!ODataJSONNestedWithin(data, self.service.maxJSONDepth)) {
    [self fail:400 message:[NSString stringWithFormat:@"The body is nested deeper than the service takes (%lu)", (unsigned long)self.service.maxJSONDepth]];
    return nil;
  }
  id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![json isKindOfClass:[NSDictionary class]]) {
    [self fail:400 message:@"The body must be a JSON object"];
    return nil;
  }
  NSDictionary *body = ODataNormalizedControlInformation(json, [self.request valueForHeader:@"OData-Version"] ?: self.request.version);
  // A client on another version of the schema: its body made this one's.
  ODataService *service = self.service;
  NSString *version = self.schemaVersion;
  if (version.length && service.upgradeBody) {
    NSError *error = nil;
    NSDictionary *upgraded = service.upgradeBody(body, version, self.request.entity, self.request, &error);
    if (![upgraded isKindOfClass:[NSDictionary class]]) {
      [self respondError:error ?: ODataServiceError(400, [NSString stringWithFormat:@"A client on model version %@ cannot write this", version])];
      return nil;
    }
    body = upgraded;
  }
  self.parsedBody = body;
  return self.parsedBody;
}

- (NSDictionary *)keyFromPartsQuietly:(NSDictionary *)parts entity:(NSEntityDescription *)entity
{
  BOOL wasDone = self.done;
  self.done = YES;  // a reference that does not resolve is the caller's to report
  NSDictionary *key = [self keyFromParts:parts entity:entity];
  self.done = wasDone;
  return key;
}

// What a deep insert's body nested, as $expand: the response shows it.
- (NSString *)expansionOfBody:(NSDictionary *)body entity:(NSEntityDescription *)entity
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *key in [body.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([key rangeOfString:@"@"].location != NSNotFound) continue;
    NSPropertyDescription *property = [self.mapper propertyForWireName:key entity:entity];
    if (![property isKindOfClass:[NSRelationshipDescription class]]) continue;
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
    // Not asked for, so left out where the caller may not read it: it may
    // hold more than the write wrote (the members it had, those named by @id).
    if (![self holds:[self.service handlerForEntity:relationship.destinationEntity].readScopes]) continue;
    id value = body[key];
    NSDictionary *first = [value isKindOfClass:[NSArray class]] ? [value firstObject] : value;
    NSString *inner = [first isKindOfClass:[NSDictionary class]] ? [self expansionOfBody:first entity:relationship.destinationEntity] : nil;
    [items addObject:inner.length ? [NSString stringWithFormat:@"%@($expand=%@)", key, inner] : key];
  }
  return [items componentsJoinedByString:@","];
}

- (BOOL)save
{
  // What Core Data's validation cannot hold: Validation.MultipleOf and
  // Validation.Constraint, of every object this request inserts or updates
  // (in a change set, of everything it has changed so far).
  NSManagedObjectContext *context = self.request.context;
  for (NSSet *changed in @[ context.insertedObjects, context.updatedObjects ]) {
    for (NSManagedObject *object in changed) {
      NSError *violation = [self.mapper vocabularyViolationOfObject:object];
      if (violation) {
        [context rollback];
        [self respondError:violation];
        return NO;
      }
    }
  }
  if (!self.saves) return YES;
  NSError *error = nil;
  // An action's changes are saved as part of its call, under its span.
  OTSpan *parent = self.callSpan ?: self.executeSpan ?: self.span;
  if (OISTimedSave(self.service, self.request.context, parent, self.entity.name, &error)) return YES;
  [self.request.context rollback];
  [self respondError:error];
  return NO;
}

@end

#pragma mark - The service

@implementation OISAsyncJob

- (void)exchangeDidFinish:(ODataExchange *)inner
{
  ODataExchange *client = nil;
  @synchronized (self) {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)inner.URLResponse;
    self.status = [http isKindOfClass:[NSHTTPURLResponse class]] ? http.statusCode : 500;
    self.headers = [http isKindOfClass:[NSHTTPURLResponse class]] ? http.allHeaderFields : @{};
    self.body = inner.data ?: [NSData data];
    self.finished = YES;
    self.finishedAt = [NSDate date];
    if (!self.accepted) {
      client = self.exchange;
      self.exchange = nil;
    }
  }
  // Answered before it was accepted: as though it had not asked.
  if (client) {
    client.URLResponse = inner.URLResponse;
    client.data = inner.data;
    [client finish];
  }
}

- (void)accept
{
  ODataExchange *client = nil;
  @synchronized (self) {
    if (self.finished || self.accepted) return;
    self.accepted = YES;
    client = self.exchange;
    self.exchange = nil;
  }
  [self.service acceptAsyncJob:self exchange:client];
}

@end

@implementation ODataService {
  // Repeatable requests: by client and request ID, what was answered.
  NSMutableDictionary<NSString *, NSDictionary *> *_remembered;
  NSLock *_rememberedLock;
  // Asynchronous requests, by status monitor.
  NSMutableDictionary<NSString *, OISAsyncJob *> *_jobs;
  NSLock *_jobsLock;
  // When history was last pruned (historyRetention).
  NSDate *_historyPruned;
}

- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator serviceRoot:(NSURL *)serviceRoot
{
  self = [super init];
  if (!self) return nil;
  _coordinator = coordinator;
  _model = coordinator.managedObjectModel;
  _serviceRoot = [serviceRoot copy];
  _mapper = [[ODataPropertyMapper alloc] init];
  _namespaceName = @"Default";
  _containerName = @"Container";
  _maxVersion = @"4.01";
  // Its version identifiers (Xcode's Core Data Model Identifier), the
  // empty one left out: none, no version.
  NSArray *identifiers = [[[_model.versionIdentifiers.allObjects valueForKey:@"description"]
                             filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
                             sortedArrayUsingSelector:@selector(compare:)];
  _modelVersion = identifiers.count ? [identifiers componentsJoinedByString:@","] : nil;
  _replyTimeout = 60;
  _tracer = [OTTracer tracerNamed:@"ODataService" version:nil];
  _repeatabilityDuration = 3600;
  _asyncResultDuration = 600;
  _maxAsyncRequests = 1000;
  _maxURLLength = 8192;
  _maxExpandDepth = 8;
  _maxBatchRequests = 100;
  _maxRowsInMemory = 10000;
  _maxJSONDepth = 64;
  _jobs = [NSMutableDictionary dictionary];
  _jobsLock = [[NSLock alloc] init];
  _remembered = [NSMutableDictionary dictionary];
  _rememberedLock = [[NSLock alloc] init];
  _handlers = [NSMutableDictionary dictionary];
  _metadataByVersion = [NSMutableDictionary dictionary];
  return self;
}

// $metadata from the model, read back as the schema the mapper answers
// from; and a handler for every set that has none.
- (void)prepare
{
  @synchronized (self) {
    if (self.prepared) return;
    ODataMetadataWriter *writer = [[ODataMetadataWriter alloc] initWithModel:self.model mapper:self.mapper];
    NSMutableArray *problems = [NSMutableArray array];
    writer.entityNames = [self servedEntityNamesWithProblems:problems];
    self.configurationProblems = problems;
    self.mapper.servedEntityNames = writer.entityNames;
    writer.namespaceName = self.namespaceName;
    writer.containerName = self.containerName;
    NSMutableDictionary *concurrency = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in writer.entities) {
      NSAttributeDescription *version = [self versionAttributeOfEntity:entity];
      if (version && !entity.superentity) concurrency[entity.name] = version;
    }
    writer.concurrencyAttributes = concurrency;
    OISOperationCatalog *catalog = [[OISOperationCatalog alloc] initWithModel:self.model
                                                                       mapper:self.mapper
                                                                       writer:writer
                                                            serviceOperations:self.serviceOperations];
    writer.additionalSchemaElements = catalog.schemaElements;
    writer.additionalContainerElements = catalog.containerElements;
    self.catalog = catalog;
    NSString *xml = [writer XMLStringForVersion:@"4.01"];
    ODataSchema *schema = [ODataSchema schemaWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
    if (schema) self.mapper.schema = schema;
    self.writer = writer;
    self.predicates = [[ODataPredicateBuilder alloc] initWithMapper:self.mapper];
    NSMutableDictionary *types = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in writer.entities) types[[writer typeNameForEntity:entity]] = entity;
    self.predicates.entitiesByTypeName = types;
    // What each set's handler, as it is now, lets $filter and $orderby use.
    __weak ODataService *weakService = self;
    // Dynamic properties, of an open type's entities.
    // The request is the builder's userInfo: each call's builder is its own
    // (-[OISServiceCall predicates]).
    self.predicates.dynamicProperty = ^NSPredicate *(NSEntityDescription *entity, NSArray<NSString *> *path,
                                                     NSPredicateOperatorType type, id value, id request, NSError **error) {
      ODataEntitySetHandler *handler = [weakService handlerForEntity:entity];
      if (!handler.isOpenType || ![request isKindOfClass:[ODataRequest class]]) return nil;
      return [handler predicateForDynamicProperty:path operator:type value:value request:request error:error];
    };
    self.predicates.restrictedProperties = ^NSSet *(NSEntityDescription *entity, BOOL sorting) {
      ODataService *service = weakService;
      ODataEntitySetHandler *handler = [service handlerForEntity:entity];
      NSSet *wire = sorting ? handler.nonSortableProperties : handler.nonFilterableProperties;
      if (!wire.count) return nil;
      NSMutableSet *names = [NSMutableSet set];
      for (NSPropertyDescription *property in entity.properties) {
        NSString *name = [property isKindOfClass:[NSAttributeDescription class]]
            ? [service.mapper propertyForAttribute:(NSAttributeDescription *)property]
            : [service.mapper propertyForRelationship:(NSRelationshipDescription *)property];
        if ([wire containsObject:name]) [names addObject:property.name];
      }
      return names;
    };
    NSMutableSet *served = [NSMutableSet set];
    for (NSEntityDescription *entity in writer.entities) {
      if (entity.superentity) continue;
      NSString *set = [self.mapper entitySetForEntity:entity];
      [served addObject:set];
      ODataEntitySetHandler *handler = self.handlers[set];
      if (!handler) {
        handler = [[ODataEntitySetHandler alloc] initWithEntity:entity];
        self.handlers[set] = handler;
      }
      handler.service = self;
    }
    // A handler for a set it does not serve serves nothing.
    for (NSString *set in self.handlers.allKeys) {
      if (![served containsObject:set]) [self.handlers removeObjectForKey:set];
    }
    [self addServingProblemsOf:writer.entities to:problems];
    self.configurationProblems = problems;
    self.prepared = YES;
  }
}

// What names a property the service does not serve (OData.served NO): a
// timeline's period or object key, a recursive hierarchy's node or parent.
- (void)addServingProblemsOf:(NSArray<NSEntityDescription *> *)entities to:(NSMutableArray *)problems
{
  for (NSEntityDescription *entity in entities) {
    if (entity.superentity) continue;
    NSDictionary *info = entity.userInfo;
    NSMutableArray *timeline = [NSMutableArray array];
    for (NSString *key in @[ ODataUserInfoPeriodStart, ODataUserInfoPeriodEnd ]) if ([info[key] isKindOfClass:[NSString class]]) [timeline addObject:info[key]];
    if ([info[ODataUserInfoObjectKey] isKindOfClass:[NSString class]]) [timeline addObjectsFromArray:[info[ODataUserInfoObjectKey] componentsSeparatedByString:@","]];
    for (NSString *name in timeline) {
      NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSAttributeDescription *attribute = entity.attributesByName[trimmed];
      if (attribute && ![self.mapper servesProperty:attribute]) {
        [problems addObject:[NSString stringWithFormat:@"%@: its timeline's %@ is not served, so it has no application time", entity.name, trimmed]];
      }
    }
    NSDictionary *annotations = [self.mapper annotationsOfProperty:nil entity:entity];
    for (NSString *term in [annotations.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if (![term hasPrefix:@"Org.OData.Aggregation.V1.RecursiveHierarchy"]) continue;
      NSDictionary *record = annotations[term];
      if (![record isKindOfClass:[NSDictionary class]]) continue;
      for (NSString *member in @[ @"NodeProperty", @"ParentNavigationProperty" ]) {
        id value = record[member];
        NSString *path = [value isKindOfClass:[NSDictionary class]] ? (value[@"$PropertyPath"] ?: value[@"$NavigationPropertyPath"]) : value;
        NSString *first = [path isKindOfClass:[NSString class]] ? [path componentsSeparatedByString:@"/"].firstObject : nil;
        if (first && ![self.mapper propertyForWireName:first entity:entity]) {
          [problems addObject:[NSString stringWithFormat:@"%@: %@ names %@, which is not served", entity.name, term, first]];
        }
      }
    }
  }
}

- (void)setHandler:(ODataEntitySetHandler *)handler forEntitySet:(NSString *)entitySet
{
  @synchronized (self) {
    self.handlers[entitySet] = handler;
    handler.service = self;
  }
}

- (ODataEntitySetHandler *)handlerForEntitySet:(NSString *)entitySet
{
  [self prepare];
  @synchronized (self) {
    return self.handlers[entitySet];
  }
}

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity
{
  return [self.mapper entitySetForEntity:OISRootEntity(entity)];
}

- (ODataEntitySetHandler *)handlerForEntity:(NSEntityDescription *)entity
{
  return entity ? [self handlerForEntitySet:[self entitySetForEntity:entity]] : nil;
}

- (NSArray *)entitySets
{
  [self prepare];
  @synchronized (self) {
    return [self.handlers.allKeys sortedArrayUsingSelector:@selector(compare:)];
  }
}


// Core.Computed: derived, the version, or userInfo says so (or read only).
- (BOOL)isComputedAttribute:(NSAttributeDescription *)attribute
{
  Class derived = NSClassFromString(@"NSDerivedAttributeDescription");
  if (derived && [attribute isKindOfClass:derived]) return YES;
  if (attribute == [self versionAttributeOfEntity:attribute.entity]) return YES;
  id computed = attribute.userInfo[ODataUserInfoComputed];
  if ([computed respondsToSelector:@selector(boolValue)] && [computed boolValue]) return YES;
  NSString *permissions = attribute.userInfo[ODataUserInfoPermissions];
  return [permissions isEqual:@"Read"] || [permissions isEqual:@"None"];
}

- (BOOL)isImmutableAttribute:(NSAttributeDescription *)attribute
{
  id immutable = attribute.userInfo[ODataUserInfoImmutable];
  return [immutable respondsToSelector:@selector(boolValue)] && [immutable boolValue];
}

// The container's annotations: the application's, and how to sign in, as
// the authenticator describes it (the Authorization vocabulary).
- (NSDictionary *)metadataContainerAnnotations
{
  // What the service does, as the Capabilities vocabulary says it; the
  // application's own annotations go over these.
  NSString *capabilities = @"Org.OData.Capabilities.V1.";
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  annotations[[capabilities stringByAppendingString:@"ConformanceLevel"]] = @{ @"$EnumMember": @"Org.OData.Capabilities.V1.ConformanceLevelType/Intermediate" };
  annotations[[capabilities stringByAppendingString:@"KeyAsSegmentSupported"]] = @YES;
  annotations[[capabilities stringByAppendingString:@"AsynchronousRequestsSupported"]] = @NO;
  annotations[[capabilities stringByAppendingString:@"IndexableByKey"]] = @YES;
  annotations[[capabilities stringByAppendingString:@"TopSupported"]] = @YES;
  annotations[[capabilities stringByAppendingString:@"SkipSupported"]] = @YES;
  annotations[[capabilities stringByAppendingString:@"BatchSupported"]] = @YES;
  annotations[[capabilities stringByAppendingString:@"BatchSupport"]] = @{
    @"Supported": @YES, @"ContinueOnErrorSupported": @YES, @"ReferencesInRequestBodiesSupported": @YES,
    @"ReferencesAcrossChangeSetsSupported": @NO, @"EtagReferencesSupported": @NO, @"RequestDependencyConditionsSupported": @NO,
    @"SupportedFormats": @[ @"multipart/mixed", @"application/json" ] };
  annotations[[capabilities stringByAppendingString:@"SelectSupport"]] = @{ @"Supported": @YES, @"Expandable": @YES, @"Filterable": @YES,
                                                                            @"Sortable": @YES, @"TopSupported": @YES, @"SkipSupported": @YES,
                                                                            @"Countable": @YES, @"ComputeSupported": @YES, @"Searchable": @YES };
  annotations[[capabilities stringByAppendingString:@"DeepInsertSupport"]] = @{ @"Supported": @YES, @"ContentIDSupported": @YES };
  annotations[[capabilities stringByAppendingString:@"DeepUpdateSupport"]] = @{ @"Supported": @YES, @"ContentIDSupported": @YES };
  annotations[[capabilities stringByAppendingString:@"FilterFunctions"]] = @[ @"contains", @"startswith", @"endswith", @"tolower", @"toupper",
                                                                                @"length", @"substring", @"indexof", @"trim", @"concat", @"year", @"month", @"day", @"hour", @"minute", @"second", @"date", @"floor", @"ceiling", @"round",
                                                                                @"now", @"cast", @"isof", @"matchesPattern",
                                                                                // Data Aggregation's (sections 3.6.1 and 5.5.1.1)
                                                                                @"aggregate", @"Org.OData.Aggregation.V1.isnode", @"Org.OData.Aggregation.V1.isroot",
                                                                                @"Org.OData.Aggregation.V1.isleaf", @"Org.OData.Aggregation.V1.isancestor",
                                                                                @"Org.OData.Aggregation.V1.isdescendant", @"Org.OData.Aggregation.V1.issibling" ];
  // Repeatable requests, remembered repeatabilityDuration.
  if (self.repeatabilityDuration > 0) annotations[@"Org.OData.Repeatability.V1.Supported"] = @YES;
  // Prefer: respond-async, where a request takes its time.
  if (self.asyncResultDuration > 0) annotations[@"Org.OData.Capabilities.V1.AsynchronousRequestsSupported"] = @YES;
  // The versions it speaks: 4.0 alone for a service that speaks no 4.01.
  if ([self.maxVersion isEqualToString:@"4.0"]) annotations[@"Org.OData.Core.V1.ODataVersions"] = @"4.0";
  // $apply, as far as it goes, for every set (Data Aggregation section 5.1:
  // ApplySupportedDefaults on the container, ApplySupported on each set).
  annotations[@"Org.OData.Aggregation.V1.ApplySupportedDefaults"] = @{ @"Transformations": OISApplyTransformations() };
  for (NSString *term in self.containerAnnotations) annotations[[ODataMetadataWriter fullTerm:term]] = self.containerAnnotations[term];
  id<HSAuthenticator> authenticator = self.authenticator;
  NSDictionary *authorization = [authenticator respondsToSelector:@selector(authorizationDescription)] ? [authenticator authorizationDescription] : nil;
  if (authorization && !annotations[@"Org.OData.Authorization.V1.Authorizations"]) {
    annotations[@"Org.OData.Authorization.V1.Authorizations"] = @[ authorization ];
    NSMutableDictionary *scheme = [NSMutableDictionary dictionaryWithObject:authorization[@"Name"] ?: @"" forKey:@"Authorization"];
    NSSet *scopes = [authenticator respondsToSelector:@selector(requiredScopes)] ? [(NSObject *)authenticator valueForKey:@"requiredScopes"] : nil;
    scheme[@"RequiredScopes"] = [scopes.allObjects sortedArrayUsingSelector:@selector(compare:)] ?: @[];
    annotations[@"Org.OData.Authorization.V1.SecuritySchemes"] = @[ scheme ];
  }
  return annotations;
}


- (NSAttributeDescription *)versionAttributeOfEntity:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
    id flag = attribute.userInfo[ODataUserInfoETag];
    if ([flag isEqual:@"YES"] || [flag isEqual:@YES]) return attribute;
  }
  return nil;
}

- (NSString *)metadataXMLForVersion:(NSString *)version
{
  [self prepare];
  @synchronized (self) {
    // What the handlers allow, as they are now: a handler may be replaced,
    // or change its mind, after the first request.
    NSMutableDictionary *restrictions = [NSMutableDictionary dictionary];
    NSMutableDictionary *setAnnotations = [NSMutableDictionary dictionary];
    NSMutableString *signature = [NSMutableString stringWithString:version];
    NSMutableSet *open = [NSMutableSet set];
    NSMutableDictionary *permissions = [NSMutableDictionary dictionary];
    for (NSString *set in [self.handlers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataEntitySetHandler *handler = self.handlers[set];
      NSMutableDictionary *needed = [NSMutableDictionary dictionary];
      if (handler.readScopes.count) needed[@"Read"] = handler.readScopes;
      if (handler.insertScopes.count) needed[@"Insert"] = handler.insertScopes;
      if (handler.updateScopes.count) needed[@"Update"] = handler.updateScopes;
      if (handler.deleteScopes.count) needed[@"Delete"] = handler.deleteScopes;
      if (needed.count) {
        permissions[set] = needed;
        for (NSString *kind in [needed.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
          [signature appendFormat:@";%@ %@:%@", set, kind,
                                  [[needed[kind] allObjects] sortedArrayUsingSelector:@selector(compare:)]];
        }
      }
      NSMutableSet *refused = [NSMutableSet set];
      if (!handler.allowsInsert) [refused addObject:@"Insert"];
      if (!handler.allowsUpdate) [refused addObject:@"Update"];
      if (!handler.allowsDelete) [refused addObject:@"Delete"];
      if (!handler.allowsUpsert || !handler.allowsInsert || !handler.allowsUpdate) [refused addObject:@"Upsert"];
      if (handler.isOpenType) {
        [open addObject:OISRootEntity(handler.entity).name];
        [signature appendFormat:@";%@ open", set];
      }
      if (refused.count) {
        restrictions[set] = refused;
        [signature appendFormat:@";%@:%@", set, [[refused.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
      }
      // Whether $search does, and what $filter and $orderby may not use.
      BOOL searchable = !handler.searchableProperties || handler.searchableProperties.count;
      NSMutableDictionary *capabilities = [@{ @"Org.OData.Capabilities.V1.SearchRestrictions": @{ @"Searchable": @(searchable) } } mutableCopy];
      if (!searchable) [signature appendFormat:@";%@ nosearch", set];
      NSArray *(^paths)(NSSet *) = ^NSArray *(NSSet *names) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *name in [names.allObjects sortedArrayUsingSelector:@selector(compare:)]) [out addObject:@{ @"$PropertyPath": name }];
        return out;
      };
      if (handler.nonFilterableProperties.count) {
        capabilities[@"Org.OData.Capabilities.V1.FilterRestrictions"] = @{ @"NonFilterableProperties": paths(handler.nonFilterableProperties) };
        [signature appendFormat:@";%@ filter:%@", set, [paths(handler.nonFilterableProperties) valueForKey:@"$PropertyPath"]];
      }
      if (handler.nonSortableProperties.count) {
        capabilities[@"Org.OData.Capabilities.V1.SortRestrictions"] = @{ @"NonSortableProperties": paths(handler.nonSortableProperties) };
        [signature appendFormat:@";%@ sort:%@", set, [paths(handler.nonSortableProperties) valueForKey:@"$PropertyPath"]];
      }
      // $apply: what the handler allows of it, and its custom aggregates.
      NSMutableDictionary *apply = [NSMutableDictionary dictionary];
      if (handler.groupableProperties) {
        NSMutableArray *groupable = [NSMutableArray array];
        for (NSString *path in [handler.groupableProperties.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
          [groupable addObject:@{ @"$PropertyPath": path }];
        }
        apply[@"GroupableProperties"] = groupable;
      }
      if (handler.aggregatableProperties) {
        NSMutableArray *aggregatable = [NSMutableArray array];
        for (NSString *path in [handler.aggregatableProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
          NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObject:@{ @"$PropertyPath": path } forKey:@"Property"];
          NSArray *methods = handler.aggregatableProperties[path];
          if (methods.count) record[@"SupportedAggregationMethods"] = methods;
          [aggregatable addObject:record];
        }
        apply[@"AggregatableProperties"] = aggregatable;
      }
      if (handler.customAggregationMethods.count) {
        apply[@"CustomAggregationMethods"] = [handler.customAggregationMethods.allObjects sortedArrayUsingSelector:@selector(compare:)];
      }
      capabilities[@"Org.OData.Aggregation.V1.ApplySupported"] = apply;
      for (NSString *name in [handler.customAggregates.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        capabilities[[@"Org.OData.Aggregation.V1.CustomAggregate#" stringByAppendingString:name]] = handler.customAggregates[name];
      }
      [signature appendFormat:@";%@ apply:%lu", set, (unsigned long)apply.description.hash + handler.customAggregates.description.hash];
      // Delta links, where the stores keep history.
      if ([handler canTrackChanges]) {
        capabilities[@"Org.OData.Capabilities.V1.ChangeTracking"] = @{ @"Supported": @YES };
        [signature appendFormat:@";%@ tracked", set];
      }
      // Application time (Temporal.ApplicationTimeSupport).
      OISTimeline *timeline = [OISTimeline timelineOfEntity:handler.entity mapper:self.mapper];
      if (timeline) {
        capabilities[@"Org.OData.Temporal.V1.ApplicationTimeSupport"] = [timeline applicationTimeSupport];
        [signature appendFormat:@";%@ temporal", set];
      }
      setAnnotations[set] = capabilities;
    }
    // The container's: the authenticator, or the application's, may be set
    // after the first request.
    NSDictionary *container = [self metadataContainerAnnotations];
    // What the operations need, and the scheme every permission is under.
    NSMutableDictionary *operationPermissions = [NSMutableDictionary dictionary];
    for (OISServedOperation *operation in self.catalog.operations) {
      if (!operation.scopes.count) continue;
      NSMutableString *overload = [operation.qualifiedName mutableCopy];
      if (operation.boundEntity) {
        NSString *type = [self.writer typeNameForEntity:operation.boundEntity];
        [overload appendFormat:operation.boundToCollection ? @"(Collection(%@))" : @"(%@)", type];
      }
      operationPermissions[overload] = operation.scopes;
    }
    for (NSString *overload in [operationPermissions.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      [signature appendFormat:@";%@:%@", overload, [[operationPermissions[overload] allObjects] sortedArrayUsingSelector:@selector(compare:)]];
    }
    id<HSAuthenticator> authenticator = self.authenticator;
    NSDictionary *authorization = [authenticator respondsToSelector:@selector(authorizationDescription)]
        ? [authenticator authorizationDescription] : nil;
    NSString *schemeName = [authorization[@"Name"] isKindOfClass:[NSString class]] ? authorization[@"Name"] : nil;
    [signature appendFormat:@";scheme:%@", schemeName ?: @""];
    [signature appendFormat:@";container:%lu", (unsigned long)container.description.hash];
    // The schema's version, which may be set after the first request too.
    [signature appendFormat:@";schema:%@", self.modelVersion ?: @""];
    NSString *xml = self.metadataByVersion[signature];
    if (!xml) {
      self.writer.containerAnnotations = container;
      self.writer.restrictions = restrictions;
      self.writer.permissions = permissions;
      self.writer.operationPermissions = operationPermissions;
      self.writer.securitySchemeName = schemeName;
      self.writer.openEntityNames = open;
      self.writer.entitySetAnnotations = setAnnotations;
      self.writer.schemaVersion = self.modelVersion;
      xml = [self.writer XMLStringForVersion:version];
      self.metadataByVersion[signature] = xml;
    }
    return xml;
  }
}

- (NSArray *)operationProblems
{
  [self prepare];
  return self.catalog.problems;
}

- (NSArray *)metadataProblems
{
  [self prepare];
  return [self.configurationProblems arrayByAddingObjectsFromArray:self.writer.problems ?: @[]];
}

// The roots configurationName lists, each served with its sub-entities;
// nil when there is no configuration. What does not hold is a problem.
- (NSSet *)servedEntityNamesWithProblems:(NSMutableArray *)problems
{
  NSString *name = self.configurationName;
  if (!name) return nil;
  NSArray *listed = [self.model entitiesForConfiguration:name];
  if (![self.model.configurations containsObject:name] && !listed.count) {
    [problems addObject:[NSString stringWithFormat:@"The model has no configuration %@: no entity is served", name]];
    return [NSSet set];
  }
  NSMutableSet *names = [NSMutableSet set];
  NSMutableSet *listedNames = [NSMutableSet set];
  for (NSEntityDescription *entity in listed) [listedNames addObject:entity.name];
  for (NSEntityDescription *entity in listed) {
    NSEntityDescription *root = entity;
    while (root.superentity) root = root.superentity;
    if (root == entity) {
      [names addObject:entity.name];
    } else if (![listedNames containsObject:root.name]) {
      [problems addObject:[NSString stringWithFormat:@"Configuration %@ lists %@ without its root entity %@: it is not served", name, entity.name, root.name]];
    }
  }
  // A root is served whole: a sub-entity left out is served all the same.
  for (NSEntityDescription *entity in self.model.entities) {
    NSEntityDescription *root = entity.superentity;
    while (root.superentity) root = root.superentity;
    if (root && [names containsObject:root.name] && ![listedNames containsObject:entity.name]) {
      [problems addObject:[NSString stringWithFormat:@"Configuration %@ lists %@ without its sub-entity %@: it is served all the same", name, root.name, entity.name]];
    }
  }
  return names;
}

- (void)startExchange:(ODataExchange *)exchange
{
  [self startExchange:exchange principal:nil given:NO];
}

- (void)startExchange:(ODataExchange *)exchange principal:(HSPrincipal *)principal
{
  [self startExchange:exchange principal:principal given:YES];
}

#pragma mark History

- (BOOL)pruneHistoryBeforeDate:(NSDate *)date error:(NSError **)error
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = self.coordinator;
  __block BOOL pruned = NO;
  __block NSError *failure = nil;
  [context performBlockAndWait:^{
    NSError *e = nil;
    pruned = [context executeRequest:[NSPersistentHistoryChangeRequest deleteHistoryBeforeDate:date] error:&e] != nil;
    failure = e;
  }];
  if (pruned) {
    // How far: a delta token given before this has expired. No further
    // than now: what comes after was not there to prune.
    NSDate *now = [NSDate date];
    if ([date compare:now] == NSOrderedDescending) date = now;
    @synchronized (self) {
      NSPersistentStore *store = self.coordinator.persistentStores.firstObject;
      NSMutableDictionary *metadata = store ? [[self.coordinator metadataForPersistentStore:store] mutableCopy] : nil;
      NSDate *before = metadata[@"ODataService.historyPrunedBefore"];
      if (store && (!before || [before compare:date] == NSOrderedAscending)) {
        metadata[@"ODataService.historyPrunedBefore"] = date;
        [self.coordinator setMetadata:metadata forPersistentStore:store];
      }
    }
  }
  if (error) *error = failure;
  return pruned;
}

- (NSDate *)historyPrunedBefore
{
  @synchronized (self) {
    NSPersistentStore *store = self.coordinator.persistentStores.firstObject;
    id before = store ? [self.coordinator metadataForPersistentStore:store][@"ODataService.historyPrunedBefore"] : nil;
    return [before isKindOfClass:[NSDate class]] ? before : nil;
  }
}

// Pruned as requests come, no more often than a tenth of the retention
// (between a minute and an hour), off the request's way.
- (void)pruneHistoryIfDue
{
  NSTimeInterval retention = self.historyRetention;
  if (retention <= 0) return;
  NSTimeInterval every = MIN(MAX(retention / 10, 60), 3600);
  @synchronized (self) {
    if (_historyPruned && -[_historyPruned timeIntervalSinceNow] < every) return;
    _historyPruned = [NSDate date];
  }
  NSDate *before = [NSDate dateWithTimeIntervalSinceNow:-retention];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
    NSError *error = nil;
    if (![self pruneHistoryBeforeDate:before error:&error]) {
      HSLogMessage(HSLogLevelWarn, @"ODataService", nil, @"persistent history was not pruned: %@", error.localizedDescription);
    }
  });
}

- (void)startExchange:(ODataExchange *)exchange principal:(HSPrincipal *)principal given:(BOOL)given
{
  [self pruneHistoryIfDue];
  if (self.maxURLLength && exchange.request.URL.absoluteString.length > self.maxURLLength) {
    NSDictionary *error = @{ @"error": @{ @"code": @"414", @"message": [NSString stringWithFormat:@"The URL is longer than the service takes (%lu characters)",
                                                                                                   (unsigned long)self.maxURLLength] } };
    [self answer:exchange status:414 headers:@{ @"Content-Type": @"application/json;charset=utf-8", @"OData-Version": @"4.01" }
            body:[NSJSONSerialization dataWithJSONObject:error options:0 error:NULL]];
    return;
  }
  NSTimeInterval wait = 0;
  if (self.asyncResultDuration > 0 && OISPrefersRespondAsync(exchange.request, &wait) && [self asyncRequestCount] < self.maxAsyncRequests) {
    [self startAsynchronously:exchange wait:wait principal:principal given:given];
    return;
  }
  [self startExchange:exchange inContext:nil saves:YES authenticated:NO principal:principal given:given];
}

#pragma mark Asynchronous requests

// Prefer: respond-async, and wait=N, how long the client would rather
// wait for the answer itself.
static BOOL OISPrefersRespondAsync(NSURLRequest *request, NSTimeInterval *wait)
{
  BOOL async = NO;
  for (NSString *item in [[request valueForHTTPHeaderField:@"Prefer"] ?: @"" componentsSeparatedByString:@","]) {
    NSString *part = [[item componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    if ([part isEqualToString:@"respond-async"]) async = YES;
    if ([part hasPrefix:@"wait="]) *wait = [[part substringFromIndex:5] doubleValue];
  }
  return async;
}

// Answered as any request is; one still under way when that returns, or
// after wait, is accepted.
- (void)startAsynchronously:(ODataExchange *)exchange wait:(NSTimeInterval)wait principal:(HSPrincipal *)principal given:(BOOL)given
{
  OISAsyncJob *job = [[OISAsyncJob alloc] init];
  // A letter first: the monitor's id is a path segment, read as a name.
  job.identifier = [@"a" stringByAppendingString:[[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString];
  job.service = self;
  job.exchange = exchange;
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:job action:@selector(exchangeDidFinish:)];
  job.request = [self startExchange:inner inContext:nil saves:YES authenticated:NO principal:principal given:given];
  if (wait > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [job accept];
    });
  } else {
    [job accept];
  }
}

- (NSUInteger)asyncRequestCount
{
  [_jobsLock lock];
  NSUInteger count = _jobs.count;
  [_jobsLock unlock];
  return count;
}

- (NSString *)statusMonitorOf:(OISAsyncJob *)job
{
  NSString *root = self.serviceRoot.absoluteString;
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  return [NSString stringWithFormat:@"%@$async/%@", root, job.identifier];
}

// Answers that have been ready longer than they are kept are let go.
- (void)forgetOldAsyncJobs
{
  for (NSString *identifier in _jobs.allKeys) {
    OISAsyncJob *job = _jobs[identifier];
    NSDate *finishedAt = nil;
    @synchronized (job) {
      finishedAt = job.finishedAt;
    }
    if (finishedAt && -[finishedAt timeIntervalSinceNow] > self.asyncResultDuration) [_jobs removeObjectForKey:identifier];
  }
}

- (void)acceptAsyncJob:(OISAsyncJob *)job exchange:(ODataExchange *)exchange
{
  [_jobsLock lock];
  [self forgetOldAsyncJobs];
  _jobs[job.identifier] = job;
  [_jobsLock unlock];
  NSString *asked = [exchange.request valueForHTTPHeaderField:@"OData-MaxVersion"];
  BOOL v40 = [self.maxVersion isEqualToString:@"4.0"] || (asked && [asked compare:@"4.01" options:NSNumericSearch] == NSOrderedAscending);
  [self answer:exchange status:202 headers:@{ @"Location": [self statusMonitorOf:job], @"Preference-Applied": @"respond-async",
                                              @"Retry-After": @"1", @"OData-Version": v40 ? @"4.0" : @"4.01" }
          body:nil];
}

- (OISAsyncJob *)asyncJobWithIdentifier:(NSString *)identifier
{
  [_jobsLock lock];
  [self forgetOldAsyncJobs];
  OISAsyncJob *job = _jobs[identifier];
  [_jobsLock unlock];
  return job;
}

- (void)forgetAsyncJob:(OISAsyncJob *)job
{
  [_jobsLock lock];
  [_jobs removeObjectForKey:job.identifier];
  [_jobsLock unlock];
}

#pragma mark Repeatable requests

static NSDateFormatter *OISHTTPDateFormatter(void)
{
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
  });
  return formatter;
}

- (void)answer:(ODataExchange *)exchange status:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body
{
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:exchange.request.URL statusCode:status
                                                           HTTPVersion:@"HTTP/1.1" headerFields:headers];
  exchange.URLResponse = response;
  exchange.data = body ?: [NSData data];
  [exchange finish];
}

- (void)reject:(ODataExchange *)exchange status:(NSInteger)status message:(NSString *)message
{
  NSDictionary *error = @{ @"error": @{ @"code": [NSString stringWithFormat:@"%ld", (long)status], @"message": message } };
  [self answer:exchange status:status headers:@{ @"Content-Type": @"application/json;charset=utf-8", @"OData-Version": @"4.01",
                                                 @"Repeatability-Result": @"rejected" }
          body:[NSJSONSerialization dataWithJSONObject:error options:0 error:NULL]];
}

// A repeatable request: answered here when it is one already answered (the
// same answer), too old to tell, or one whose ID another request took; else
// marked as under way, and its key and signature given back to remember it by.
- (BOOL)answeredRepeat:(ODataExchange *)exchange key:(NSString **)keyOut signature:(NSString **)signatureOut
{
  NSURLRequest *request = exchange.request;
  NSString *requestID = [request valueForHTTPHeaderField:@"Repeatability-Request-ID"];
  NSString *method = request.HTTPMethod ?: @"GET";
  if (!requestID.length || self.repeatabilityDuration <= 0 || [method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"]) return NO;
  NSDate *firstSent = [OISHTTPDateFormatter() dateFromString:[request valueForHTTPHeaderField:@"Repeatability-First-Sent"] ?: @""];
  if (!firstSent) {
    [self reject:exchange status:400 message:@"A repeatable request needs Repeatability-First-Sent"];
    return YES;
  }
  if (-[firstSent timeIntervalSinceNow] > self.repeatabilityDuration) {
    [self reject:exchange status:400 message:@"The request was first sent longer ago than the service remembers"];
    return YES;
  }
  NSString *key = [NSString stringWithFormat:@"%@\n%@", [request valueForHTTPHeaderField:@"Repeatability-Client-ID"] ?: @"", requestID];
  uint64_t hash = 14695981039346656037ULL;
  const uint8_t *bytes = request.HTTPBody.bytes;
  for (NSUInteger i = 0; i < request.HTTPBody.length; i++) {
    hash ^= bytes[i];
    hash *= 1099511628211ULL;
  }
  NSString *signature = [NSString stringWithFormat:@"%@ %@ %016llx", method, request.URL.absoluteString, (unsigned long long)hash];
  [_rememberedLock lock];
  // What is too old to be repeated any more is let go.
  for (NSString *old in _remembered.allKeys) {
    if (-[_remembered[old][@"date"] timeIntervalSinceNow] > self.repeatabilityDuration) [_remembered removeObjectForKey:old];
  }
  NSDictionary *entry = _remembered[key];
  if (!entry) _remembered[key] = @{ @"date": [NSDate date], @"signature": signature, @"pending": @YES };
  [_rememberedLock unlock];
  if (!entry) {
    *keyOut = key;
    *signatureOut = signature;
    return NO;
  }
  if (![entry[@"signature"] isEqualToString:signature]) {
    [self reject:exchange status:400 message:@"That Repeatability-Request-ID was given to another request"];
  } else if ([entry[@"pending"] boolValue]) {
    [self reject:exchange status:409 message:@"The request is being answered"];
  } else {
    [self answer:exchange status:[entry[@"status"] integerValue] headers:entry[@"headers"] body:entry[@"body"]];
  }
  return YES;
}

- (void)rememberAnswer:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body
                forKey:(NSString *)key signature:(NSString *)signature
{
  [_rememberedLock lock];
  // A failure of the service's own is not the answer: the request may be tried again.
  if (status >= 500) [_remembered removeObjectForKey:key];
  else _remembered[key] = @{ @"date": [NSDate date], @"signature": signature ?: @"", @"status": @(status), @"headers": headers, @"body": body };
  // Not without end: past 10000 answers, the oldest are let go.
  if (_remembered.count > 10000) {
    NSArray *oldest = [_remembered keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      return [a[@"date"] compare:b[@"date"]];
    }];
    [_remembered removeObjectsForKeys:[oldest subarrayWithRange:NSMakeRange(0, _remembered.count - 10000)]];
  }
  [_rememberedLock unlock];
}

- (ODataRequest *)startExchange:(ODataExchange *)exchange inContext:(NSManagedObjectContext *)shared saves:(BOOL)saves
                  authenticated:(BOOL)authenticated principal:(HSPrincipal *)principal given:(BOOL)given
{
  [self prepare];
  NSString *repeatabilityKey = nil, *repeatabilitySignature = nil;
  if (!shared && [self answeredRepeat:exchange key:&repeatabilityKey signature:&repeatabilitySignature]) return nil;
  OISServiceCall *call = [[OISServiceCall alloc] init];
  call.repeatabilityKey = repeatabilityKey;
  call.repeatabilitySignature = repeatabilitySignature;
  call.service = self;
  call.exchange = exchange;
  call.request = [[ODataRequest alloc] initWithURLRequest:exchange.request];
  call.request.service = self;
  call.headOnly = [call.request.method isEqualToString:@"HEAD"];
  ODataValueCoder *coder = [[ODataValueCoder alloc] init];
  coder.schema = self.mapper.schema;
  coder.declaredTypeForAttribute = self.mapper.values.declaredTypeForAttribute;
  call.coder = coder;

  call.saves = saves;
  call.authenticated = authenticated;
  call.principalGiven = given;
  call.request.principal = principal;
  NSManagedObjectContext *context = shared;
  if (!context) {
    context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = self.coordinator;
  }
  call.request.context = context;
  // The call's span, under the host's (or the batch's) when it says.
  OTSpanContext *parent = [OTSpanContext contextWithHeaders:exchange.request.allHTTPHeaderFields];
  call.span = [self.tracer startSpanNamed:[@"ODataService " stringByAppendingString:call.request.method ?: @"GET"] kind:OTSpanKindInternal
                                   parent:parent attributes:nil];
  if (call.span.recording) {
    [call.span setAttribute:call.request.method forKey:@"http.request.method"];
    [call.span setAttribute:exchange.request.URL.path forKey:@"url.path"];
    [call.span setAttribute:exchange.request.URL.query forKey:@"url.query"];
    [call.span setAttribute:[exchange.request valueForHTTPHeaderField:@"X-Request-ID"] forKey:@"request.id"];
  }
  [context performBlockAndWait:^{
    @try {
      [call run];
    } @catch (NSException *exception) {
      OISLog(HSLogLevelError, exchange.request, @"%@ %@ raised %@: %@", call.request.method, exchange.request.URL, exception.name,
             exception.reason);
      [call.span addEventNamed:@"exception" attributes:@{ @"exception.type": exception.name ?: @"", @"exception.message": exception.reason ?: @"" }];
      [context rollback];
      [call respondError:ODataServiceError(500, @"The request failed inside the service")];
    }
  }];
  return call.request;
}

@end
