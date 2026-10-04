// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataQuery.h"
#import "ODataIncrementalStore+Private.h"
#import "ODataQueryBuilder.h"
#import "ODataPredicateTranslator.h"
#import "ODataHierarchyPredicate.h"

@implementation ODataQuery {
  ODataIncrementalStore *_store;
  NSEntityDescription *_entity;
  NSURL *_URL;
  NSArray *_rows;
  NSArray *_resultIDs;
  NSArray *_result;
  NSError *_error;
  ODataQueryOptions *_sent;                  // what is sent: the options and the steps
  NSString *_path;
  NSMutableArray<NSDictionary *> *_steps;  // $apply's, typed: kind and what it takes
  NSError *_optionsError;                    // what the options set could not be read as
}

+ (instancetype)queryOfEntity:(NSString *)entityName inContext:(NSManagedObjectContext *)context
{
  ODataQuery *query = [[self alloc] init];
  query->_entityName = [entityName copy];
  query->_context = context;
  query->_resultType = NSManagedObjectResultType;
  return query;
}

+ (instancetype)queryWithFetchRequest:(NSFetchRequest *)fetch inContext:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSString *name = fetch.entityName ?: fetch.entity.name;
  ODataQuery *query = [self queryOfEntity:name inContext:context];
  if (![query findStore]) {
    if (error) *error = query->_error;
    return nil;
  }
  if (fetch.propertiesToGroupBy.count || fetch.resultType == NSCountResultType) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, @"A grouping or a count is no query of rows");
    return nil;
  }
  ODataQueryOptions *options = [query->_store.builder optionsForFetch:fetch entity:query->_entity error:error];
  if (!options) return nil;
  query.queryOptions = options;
  query.resultType = fetch.resultType == NSDictionaryResultType ? NSDictionaryResultType : NSManagedObjectResultType;
  return query;
}

- (void)setOptions:(NSDictionary<NSString *, NSString *> *)options
{
  NSError *error = nil;
  _queryOptions = options ? [ODataQueryOptions optionsWithQuery:options error:&error] : nil;
  _optionsError = options && !_queryOptions ? error : nil;
}

- (NSDictionary<NSString *, NSString *> *)options
{
  if (!_queryOptions) return nil;
  NSMutableDictionary *options = [NSMutableDictionary dictionary];
  for (NSArray *item in _queryOptions.queryItems) options[item[0]] = item[1];
  return options;
}

- (void)setQueryOptions:(ODataQueryOptions *)queryOptions
{
  _queryOptions = [queryOptions copy];
  _optionsError = nil;
}

#pragma mark - $apply's steps, typed

- (void)addStep:(NSDictionary *)step
{
  if (!_steps) _steps = [NSMutableArray array];
  [_steps addObject:step];
}

- (void)addFilter:(NSPredicate *)predicate
{
  [self addStep:@{ @"kind": @"filter", @"predicate": predicate }];
}

- (void)addAncestorsInHierarchy:(NSString *)qualifier nodeKeyPath:(NSString *)nodeKeyPath
                             of:(NSPredicate *)start maxDistance:(NSUInteger)maxDistance keepStart:(BOOL)keepStart
{
  [self addStep:@{ @"kind": @"ancestors", @"qualifier": qualifier, @"node": nodeKeyPath ?: [NSNull null], @"predicate": start,
                   @"distance": @(maxDistance), @"keep": @(keepStart) }];
}

- (void)addDescendantsInHierarchy:(NSString *)qualifier nodeKeyPath:(NSString *)nodeKeyPath
                               of:(NSPredicate *)start maxDistance:(NSUInteger)maxDistance keepStart:(BOOL)keepStart
{
  [self addStep:@{ @"kind": @"descendants", @"qualifier": qualifier, @"node": nodeKeyPath ?: [NSNull null], @"predicate": start,
                   @"distance": @(maxDistance), @"keep": @(keepStart) }];
}

- (void)addTraversalOfHierarchy:(NSString *)qualifier nodeKeyPath:(NSString *)nodeKeyPath postorder:(BOOL)postorder
                sortDescriptors:(NSArray<NSSortDescriptor *> *)sortDescriptors
{
  [self addStep:@{ @"kind": @"traverse", @"qualifier": qualifier, @"node": nodeKeyPath ?: [NSNull null], @"postorder": @(postorder),
                   @"sort": sortDescriptors ?: @[] }];
}

// A step, typed; nil and the error for one that cannot be (a name from
// the model the expression builders refuse among them).
- (ODataApplyTransformation *)applyStep:(NSDictionary *)step error:(NSError **)error
{
  return ODataExpressionBuilding(error, ^id {
    return [self uncheckedApplyStep:step error:error];
  });
}

- (ODataApplyTransformation *)uncheckedApplyStep:(NSDictionary *)step error:(NSError **)error
{
  ODataPropertyMapper *mapper = _store.mapper;
  ODataPredicateTranslator *translator = [[ODataPredicateTranslator alloc] initWithMapper:mapper entity:_entity];
  translator.writesAggregates = YES;
  NSString *kind = step[@"kind"];
  ODataExpression *filter = nil;
  if (step[@"predicate"]) {
    filter = [translator expressionForPredicate:step[@"predicate"] error:error];
    if (!filter) return nil;
  }
  if ([kind isEqualToString:@"filter"]) return [ODataApplyTransformation filterWithExpression:filter];

  NSString *qualifier = step[@"qualifier"];
  NSString *nodeKeyPath = nil;
  NSEntityDescription *nodes = [ODataHierarchyPredicate entityOfHierarchy:qualifier model:_entity.managedObjectModel mapper:mapper
                                                             nodeKeyPath:&nodeKeyPath parent:NULL];
  NSString *given = step[@"node"] == [NSNull null] ? nil : step[@"node"];
  if (!nodes || (!given && ![_entity isKindOfEntity:nodes])) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                 nodes ? [NSString stringWithFormat:@"%@ of %@: %@ is no node of it; say which key path leads to one", kind, qualifier, _entity.name]
                                       : [NSString stringWithFormat:@"%@: no entity has the recursive hierarchy %@ (Aggregation.RecursiveHierarchy)", kind, qualifier]);
    return nil;
  }
  NSEntityDescription *root = nodes;
  while (root.superentity) root = root.superentity;
  NSArray *hierarchy = @[ [mapper entitySetForEntity:root] ];
  NSArray *nodePath = [[mapper propertyPathForKeyPath:given ?: nodeKeyPath entity:_entity] componentsSeparatedByString:@"/"];
  if ([kind isEqualToString:@"traverse"]) {
    NSMutableArray *order = [NSMutableArray array];
    for (NSSortDescriptor *sort in step[@"sort"]) {
      NSArray *path = [[mapper propertyPathForKeyPath:sort.key ?: @"" entity:nodes] componentsSeparatedByString:@"/"];
      [order addObject:[ODataOrderItem itemWithExpression:[ODataExpression memberPath:path of:nil] descending:!sort.ascending]];
    }
    return [ODataApplyTransformation traverseHierarchy:hierarchy qualifier:qualifier nodePath:nodePath
                                             postorder:[step[@"postorder"] boolValue] orderBy:order];
  }
  return [ODataApplyTransformation hierarchical:kind hierarchy:hierarchy qualifier:qualifier nodePath:nodePath
                                       sequence:@[ [ODataApplyTransformation filterWithExpression:filter] ]
                                    maxDistance:[step[@"distance"] unsignedIntegerValue] keepStart:[step[@"keep"] boolValue]];
}

- (NSArray *)result
{
  return _result;
}

- (NSError *)error
{
  return _error;
}

- (void)failWith:(ODataIncrementalStoreErrorCode)code message:(NSString *)message
{
  _error = OISError(code, message);
}

#pragma mark - Before: the store and the URL

// The model's entity, and the store of the context.
- (BOOL)findStore
{
  NSPersistentStoreCoordinator *coordinator = self.context.persistentStoreCoordinator;
  _entity = coordinator.managedObjectModel.entitiesByName[self.entityName];
  if (!_entity) {
    [self failWith:ODataIncrementalStoreErrorMissingEntitySet message:[NSString stringWithFormat:@"No entity %@ in the model", self.entityName]];
    return NO;
  }
  _store = nil;
  for (NSPersistentStore *store in coordinator.persistentStores) {
    if ([store isKindOfClass:[ODataIncrementalStore class]]) {
      _store = (ODataIncrementalStore *)store;
      break;
    }
  }
  if (!_store) {
    [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:@"No OData store to send the query to"];
    return NO;
  }
  return YES;
}

- (BOOL)prepare
{
  _error = nil;
  _result = nil;
  if (![self findStore]) return NO;
  if (_optionsError) {
    _error = _optionsError;
    return NO;
  }
  if (self.resultType != NSManagedObjectResultType && self.resultType != NSDictionaryResultType) {
    [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:@"A query gives objects or dictionaries"];
    return NO;
  }
  // The typed steps first, then the options' own $apply.
  ODataMutableQueryOptions *options = _queryOptions ? [_queryOptions mutableCopy] : [[ODataMutableQueryOptions alloc] init];
  NSError *error = nil;
  if (_steps.count) {
    NSMutableArray *apply = [NSMutableArray array];
    for (NSDictionary *step in _steps) {
      ODataApplyTransformation *typed = [self applyStep:step error:&error];
      if (!typed) {
        _error = error;
        return NO;
      }
      [apply addObject:typed];
    }
    [apply addObjectsFromArray:options.apply ?: @[]];
    options.apply = apply;
  }
  _sent = options;
  _path = [_store.mapper collectionPathForEntity:_entity];
  _URL = [_store.builder URLForPath:_path options:options error:&error];
  if (!_URL) _error = error;
  return _URL != nil;
}

- (NSURL *)URL:(NSError **)error
{
  NSURL *url = [self prepare] ? _URL : nil;
  if (error) *error = _error;
  return url;
}

#pragma mark - Sending: every page, each row an object or a dictionary

static id OISWithoutAnnotations(id json)
{
  if ([json isKindOfClass:[NSArray class]]) {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in json) [out addObject:OISWithoutAnnotations(item)];
    return out;
  }
  if (![json isKindOfClass:[NSDictionary class]]) return json;
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *key in json) {
    if ([key rangeOfString:@"@"].location != NSNotFound) continue;  // @odata.id, Name@odata.type
    out[key] = OISWithoutAnnotations(json[key]);
  }
  return out;
}

- (BOOL)perform
{
  NSError *error = nil;
  NSArray *rows = [_store rowsForPath:_path options:_sent limit:0 pageSize:0 URL:NULL error:&error];
  if (!rows) {
    _error = error;
    return NO;
  }
  if (self.resultType == NSDictionaryResultType) {
    _rows = OISWithoutAnnotations(rows);
    return YES;
  }
  NSArray *ids = [_store objectIDsForRows:rows entity:_entity URL:_URL error:&error];
  if (!ids) {
    [self failWith:ODataIncrementalStoreErrorDecoding
           message:[NSString stringWithFormat:@"A row of %@ is no %@ (%@): ask for dictionaries", _URL, self.entityName, error.localizedDescription ?: @"no key"]];
    return NO;
  }
  _resultIDs = ids;
  return YES;
}

// On the context's queue: the objects, in the context.
- (void)finish
{
  if (_rows) {
    _result = _rows;
    _rows = nil;
    return;
  }
  NSMutableArray *objects = [NSMutableArray array];
  for (NSManagedObjectID *oid in _resultIDs) [objects addObject:[self.context objectWithID:oid]];
  _result = objects;
  _resultIDs = nil;
}

- (NSArray *)execute:(NSError **)error
{
  if ([self prepare] && [self perform]) [self finish];
  // The ivars, not the getters (see -[ODataOperationCall invoke:]).
  if (error) *error = _error;
  return _error ? nil : _result;
}

- (void)executeWithTarget:(id)target action:(SEL)action
{
  // What needs the context is done here and at the end, on its queue; the
  // requests in between wait on another thread.
  BOOL prepared = [self prepare];
  NSManagedObjectContext *context = self.context;
  void (^deliver)(void) = ^{
    if (!self->_error) [self finish];
    void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:action];
    if (send) send(target, action, self);
  };
  void (^onContext)(void) = ^{
    if (context.concurrencyType == NSPrivateQueueConcurrencyType || context.concurrencyType == NSMainQueueConcurrencyType) {
      [context performBlock:deliver];
    } else {
      [self performSelectorOnMainThread:@selector(run:) withObject:[deliver copy] waitUntilDone:NO];
    }
  };
  if (!prepared) {
    onContext();
    return;
  }
  [NSThread detachNewThreadSelector:@selector(performThen:) toTarget:self withObject:[onContext copy]];
}

- (void)run:(void (^)(void))block
{
  block();
}

- (void)performThen:(void (^)(void))then
{
  @autoreleasepool {
    [self perform];
    then();
  }
}

@end

@implementation ODataFilterPredicate

+ (instancetype)predicateWithFilter:(NSString *)filter
{
  ODataFilterPredicate *predicate = [[self alloc] init];
  predicate->_filter = [filter copy];
  return predicate;
}

+ (BOOL)supportsSecureCoding
{
  return YES;
}

// Archived as itself: gnustep-base's NSPredicate archives its subclasses
// as NSPredicate, as a class cluster would.
- (Class)classForCoder
{
  return [self class];
}

- (Class)classForKeyedArchiver
{
  return [self class];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  self = [super init];
  if (!self) return nil;
  _filter = [coder decodeObjectOfClass:[NSString class] forKey:@"ODataFilter"];
  return _filter ? self : nil;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  [coder encodeObject:self.filter forKey:@"ODataFilter"];
}

// Immutable, as predicates are.
- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (BOOL)isEqual:(id)other
{
  return [other isKindOfClass:[ODataFilterPredicate class]] && [((ODataFilterPredicate *)other).filter isEqualToString:self.filter];
}

- (NSUInteger)hash
{
  return self.filter.hash;
}

- (NSString *)predicateFormat
{
  return [NSString stringWithFormat:@"ODATA_FILTER(%@)", self.filter];
}

- (NSString *)description
{
  return self.predicateFormat;
}

- (BOOL)evaluateWithObject:(id)object
{
  return NO;
}

- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)variables
{
  return NO;
}

@end
