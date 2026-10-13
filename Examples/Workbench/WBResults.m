// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBResults.h"
#import "WorkbenchSupport.h"

@implementation WBResults {
  // The results, a page at a time: the request they came from, where its
  // next page starts (in its own terms: an offset), and how many it may
  // still give (its limit; 0 for no limit).
  NSFetchRequest *_paged;
  NSUInteger _nextOffset;
  NSUInteger _remaining;
  BOOL _verbatim;  // an ODataQuery's rows, all at once
}

- (instancetype)initWithConnection:(WBConnection *)connection
{
  if (!(self = [super init])) return nil;
  _connection = connection;
  _rows = @[];
  return self;
}

- (NSManagedObjectContext *)context
{
  return _connection.context;
}

- (BOOL)builtIn
{
  return _connection.service == WBServiceBuiltIn;
}

#pragma mark The rows

- (void)clear
{
  _verbatim = NO;
  _rows = @[];
  _paged = nil;
  _hasMore = NO;
  _total = nil;
}

static void WBFlatten(NSDictionary *json, NSString *prefix, NSMutableDictionary *into)
{
  for (NSString *key in json) {
    NSString *path = prefix ? [NSString stringWithFormat:@"%@/%@", prefix, key] : key;
    id value = json[key];
    if ([value isKindOfClass:[NSDictionary class]]) WBFlatten(value, path, into);
    else into[path] = value;
  }
}

- (BOOL)runQuery:(ODataQuery *)query
{
  [self clear];
  _verbatim = YES;
  NSError *error = nil;
  NSArray *rows = [query execute:&error];
  _lastError = rows ? nil : ([error.localizedDescription copy] ?: @"The query failed.");
  NSMutableArray *flat = [NSMutableArray array];
  for (id row in rows ?: @[]) {
    if (![row isKindOfClass:[NSDictionary class]]) {
      [flat addObject:row];
      continue;
    }
    NSMutableDictionary *one = [NSMutableDictionary dictionary];
    WBFlatten(row, nil, one);
    [flat addObject:one];
  }
  _rows = flat;
  _total = rows ? @(rows.count) : nil;
  return rows != nil;
}

- (BOOL)fetch:(NSFetchRequest *)request pageSize:(NSUInteger)pageSize
{
  [self clear];
  _lastError = nil;
  NSError *error = nil;
  if (request.resultType == NSCountResultType) {
    // A count goes through -countForFetchRequest:error:, which reports a
    // failed request; -executeFetchRequest: on Apple makes it a count of 0.
    NSUInteger count = [[self context] countForFetchRequest:request error:&error];
    _lastError = [error.localizedDescription copy];
    _rows = count == NSNotFound ? @[] : @[ @(count) ];
    return count != NSNotFound;
  }
  _paged = request;
  _nextOffset = request.fetchOffset;
  _remaining = request.fetchLimit;
  _hasMore = YES;
  if (!request.propertiesToGroupBy.count && request.resultType != NSDictionaryResultType) {
    // How many there are in all: the service's $count, within $skip and $top.
    NSFetchRequest *counting = [request copy];
    counting.fetchOffset = 0;
    counting.fetchLimit = 0;
    counting.resultType = NSCountResultType;
    NSUInteger count = [[self context] countForFetchRequest:counting error:NULL];
    if (count != NSNotFound) {
      NSUInteger after = count > request.fetchOffset ? count - request.fetchOffset : 0;
      _total = @(request.fetchLimit ? MIN(after, request.fetchLimit) : after);
    }
  }
  return [self loadPageOfSize:pageSize];
}

- (BOOL)loadPageOfSize:(NSUInteger)pageSize
{
  if (!_paged || !_hasMore) return YES;
  NSUInteger take = _remaining ? MIN(pageSize, _remaining) : pageSize;
  NSFetchRequest *request = [_paged copy];
  request.fetchOffset = _nextOffset;
  request.fetchLimit = take;
  NSError *error = nil;
  NSArray *got = [[self context] executeFetchRequest:request error:&error];
  if (!got) {
    _lastError = [error.localizedDescription copy] ?: @"The fetch failed.";
    _hasMore = NO;
    return NO;
  }
  // New objects not yet saved come with every page: once, and not counted
  // as the service's rows.
  NSMutableArray *rows = [_rows mutableCopy];
  NSUInteger fromService = 0;
  for (id row in got) {
    BOOL unsaved = [row isKindOfClass:[NSManagedObject class]] && [row objectID].isTemporaryID;
    if (!unsaved) fromService++;
    if ([rows indexOfObjectIdenticalTo:row] == NSNotFound) [rows addObject:row];
  }
  _rows = rows;
  _nextOffset += fromService;
  if (_remaining) _remaining -= MIN(fromService, _remaining);
  _hasMore = fromService >= take && (!_paged.fetchLimit || _remaining > 0);
  return YES;
}

- (NSString *)statusFor:(NSString *)entityName
{
  if (_lastError) return _lastError;
  if (!_paged && !_verbatim) return [NSString stringWithFormat:@"count = %@", _rows.firstObject];
  NSString *shown = _total ? [NSString stringWithFormat:@"%lu of %@", (unsigned long)_rows.count, _total]
                           : [NSString stringWithFormat:@"%lu", (unsigned long)_rows.count];
  return [NSString stringWithFormat:@"%@ %@%@", shown, entityName, _hasMore ? @" — scroll for more" : @""];
}

- (NSManagedObject *)objectAtRow:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _rows.count) return nil;
  id obj = _rows[(NSUInteger)row];
  if ([obj isKindOfClass:[NSManagedObject class]]) return obj;
  if ([obj isKindOfClass:[NSManagedObjectID class]]) return [[self context] objectWithID:obj];
  return nil;
}

// First among the rows, managed objects only.
- (void)putFirst:(NSManagedObject *)object
{
  NSMutableArray *rows = [NSMutableArray arrayWithObject:object];
  for (id row in _rows) {
    if ([row isKindOfClass:[NSManagedObject class]] && row != object) [rows addObject:row];
  }
  _rows = rows;
}

#pragma mark Writing

- (NSUInteger)pendingCount
{
  NSManagedObjectContext *context = [self context];
  return context.insertedObjects.count + context.updatedObjects.count + context.deletedObjects.count;
}

- (NSString *)pendingSummary
{
  NSManagedObjectContext *context = [self context];
  if (![self pendingCount]) return nil;
  return [NSString stringWithFormat:@"Unsaved: %lu new, %lu changed, %lu deleted. Save sends them; Revert drops them.",
                                    (unsigned long)context.insertedObjects.count, (unsigned long)context.updatedObjects.count,
                                    (unsigned long)context.deletedObjects.count];
}

// What a new object is given, so Core Data lets it be saved: each required
// attribute without a default gets an empty value of its type (an
// enumeration its first member). Relationships are left to you.
- (void)fillRequiredValuesOf:(NSManagedObject *)object
{
  for (NSAttributeDescription *attr in object.entity.attributesByName.allValues) {
    if (attr.isOptional || attr.defaultValue || [object valueForKey:attr.name]) continue;
    id value = nil;
    switch (attr.attributeType) {
      case NSStringAttributeType: {
        NSString *type = attr.userInfo[ODataUserInfoType];
        ODataSchemaEnumType *enumeration = [type isKindOfClass:[NSString class]] ? [_connection.store.schema enumTypeNamed:type] : nil;
        value = enumeration.memberNames.firstObject ?: @"";
        break;
      }
      case NSInteger16AttributeType:
      case NSInteger32AttributeType:
      case NSInteger64AttributeType:
      case NSDoubleAttributeType:
      case NSFloatAttributeType: value = @0; break;
      case NSDecimalAttributeType: value = [NSDecimalNumber zero]; break;
      case NSBooleanAttributeType: value = @NO; break;
      case NSDateAttributeType: value = [NSDate date]; break;
      case NSBinaryDataAttributeType: value = [NSData data]; break;
      default:
        if (attr.attributeType == NSUUIDAttributeType) value = [NSUUID UUID];
        else if ([attr.attributeValueClassName isEqualToString:@"NSArray"]) value = @[];
        else if ([attr.attributeValueClassName isEqualToString:@"NSDictionary"]) value = @{};
        break;
    }
    if (value) [object setValue:value forKey:attr.name];
  }
}

- (NSManagedObject *)insertObjectOf:(NSEntityDescription *)entity
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:[self context]];
  [self fillRequiredValuesOf:object];
  if (!_paged) [self clear];  // a count, or nothing: the new object alone
  [self putFirst:object];
  return object;
}

- (void)deleteObject:(NSManagedObject *)object
{
  [[self context] deleteObject:object];
  NSMutableArray *rows = [_rows mutableCopy];
  [rows removeObject:object];
  _rows = rows;
}

// An edit waits for Save, as a change to a managed object does. A key is
// the service's once the object is saved: only a new object's is edited.
- (NSString *)setValue:(id)value forKey:(NSString *)key ofRow:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _rows.count) return @"No such row.";
  id obj = _rows[(NSUInteger)row];
  if (![obj isKindOfClass:[NSManagedObject class]]) return @"Only objects are edited.";
  NSAttributeDescription *attr = [obj entity].attributesByName[key];
  BOOL isNew = [obj objectID].isTemporaryID;
  if (!attr || ((WBIsKey(attr) || [key isEqualToString:@"id"]) && !isNew)) {
    return attr ? @"A saved object's key is the service's: it cannot be changed." : @"Not an attribute.";
  }
  if (WBIsDynamic(attr)) {
    // A new dictionary: Core Data sees no change made to one in place.
    [obj setValue:WBDynamicFromText([value description], [obj valueForKey:key]) forKey:key];
    return nil;
  }
  if (attr.attributeType == NSTransformableAttributeType || attr.attributeType == NSBinaryDataAttributeType) {
    return @"Complex values, collections and binary data are not edited here.";
  }
  id typed = value;
  switch (attr.attributeType) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType:
    case NSInteger64AttributeType: typed = @([value longLongValue]); break;
    case NSDoubleAttributeType:
    case NSFloatAttributeType: typed = @([value doubleValue]); break;
    case NSDecimalAttributeType: typed = [NSDecimalNumber decimalNumberWithString:[value description]]; break;
    case NSBooleanAttributeType: typed = @([value boolValue]); break;
    case NSStringAttributeType: typed = [value description]; break;
    default: break;
  }
  [obj setValue:typed forKey:key];
  return nil;
}

- (NSString *)save:(NSArray<NSMergeConflict *> **)conflicts
{
  if (conflicts) *conflicts = nil;
  NSError *error = nil;
  if ([[self context] save:&error]) return nil;
  // The changes stay, to be put right or reverted.
  NSArray *refused = error.userInfo[NSPersistentStoreSaveConflictsErrorKey];
  if (refused.count && conflicts) *conflicts = refused;
  NSArray *details = OISDetailedErrors(error);
  NSString *why = details.count ? [[details valueForKey:@"localizedDescription"] componentsJoinedByString:@"; "] : error.localizedDescription;
  return why ?: @"unknown error";
}

- (void)revert
{
  [[self context] rollback];
}

- (NSString *)describeConflicts:(NSArray<NSMergeConflict *> *)conflicts
{
  NSMutableString *text = [NSMutableString stringWithString:@"Conflicts: changed at the service since they were read\n"];
  for (NSMergeConflict *conflict in conflicts) {
    NSManagedObject *object = conflict.sourceObject;
    [text appendFormat:@"\n%@ %@ (version %lu, now %lu)\n", object.entity.name, WBTitleOf(object, [self builtIn]),
                       (unsigned long)conflict.oldVersionNumber, (unsigned long)conflict.newVersionNumber];
    if (!conflict.persistedSnapshot) {
      [text appendString:@"  deleted at the service\n"];
      continue;
    }
    for (NSString *name in [object.changedValues.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      [text appendFormat:@"  %@: yours %@, the service's %@\n", name, WBCellValue(object.changedValues[name]),
                         WBCellValue(conflict.persistedSnapshot[name]) ?: @"nil"];
    }
  }
  return text;
}

#pragma mark Operations

static NSString *WBSignature(ODataSchemaOperation *operation)
{
  NSArray *names = [operation.callerParameters valueForKey:@"name"];
  return [NSString stringWithFormat:@"%@(%@)%@", operation.name, [names componentsJoinedByString:@", "],
                                    operation.isAction ? @"" : @" — function"];
}

- (NSArray *)operationsForObject:(NSManagedObject *)object entity:(NSEntityDescription *)entity
{
  ODataSchema *schema = _connection.store.schema;
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  NSMutableArray *items = [NSMutableArray array];
  if (object) {
    ODataSchemaEntityType *type = [mapper entityTypeForEntity:object.entity];
    for (ODataSchemaOperation *operation in type ? [schema operationsBoundToEntityType:type collection:NO] : @[]) {
      [items addObject:@[ [NSString stringWithFormat:@"%@.%@", WBTitleOf(object, [self builtIn]), WBSignature(operation)],
                          @{ @"kind": @"object", @"name": operation.qualifiedName } ]];
    }
  }
  ODataSchemaEntityType *entityType = entity ? [mapper entityTypeForEntity:entity] : nil;
  for (ODataSchemaOperation *operation in entityType ? [schema operationsBoundToEntityType:entityType collection:YES] : @[]) {
    [items addObject:@[ [NSString stringWithFormat:@"%@ (all).%@", entity.name, WBSignature(operation)],
                        @{ @"kind": @"entity", @"name": operation.qualifiedName, @"entity": entity.name } ]];
  }
  // The Temporal vocabulary's actions, on an entity with application time.
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  if (root.userInfo[ODataUserInfoPeriodStart]) {
    for (NSString *action in @[ @"Update", @"Upsert", @"Delete" ]) {
      [items addObject:@[ [NSString stringWithFormat:@"%@ (all).Temporal.%@(%@, %@, …) — a period, and values", root.name, action,
                                                     root.userInfo[ODataUserInfoPeriodStart], root.userInfo[ODataUserInfoPeriodEnd]],
                          @{ @"kind": @"temporal", @"name": action, @"entity": root.name } ]];
    }
  }
  for (NSString *name in [schema.operationImports.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaOperation *operation = [schema operationNamed:name boundToEntityType:nil collection:NO parameterNames:nil];
    if (!operation) continue;
    [items addObject:@[ [NSString stringWithFormat:@"service.%@", WBSignature(operation)], @{ @"kind": @"service", @"name": name } ]];
  }
  return items;
}

+ (NSDictionary *)parametersFromText:(NSString *)text
{
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  NSString *separator = [text rangeOfString:@";"].location != NSNotFound ? @";" : @",";
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  for (NSString *pair in [text componentsSeparatedByString:separator]) {
    NSRange equals = [pair rangeOfString:@"="];
    if (equals.location == NSNotFound) continue;
    NSString *name = [[pair substringToIndex:equals.location] stringByTrimmingCharactersInSet:space];
    NSString *raw = [[pair substringFromIndex:NSMaxRange(equals)] stringByTrimmingCharactersInSet:space];
    if (!name.length) continue;
    id value = raw;
    if (raw.length >= 2 && ([raw hasPrefix:@"'"] || [raw hasPrefix:@"\""])) {
      value = [raw substringWithRange:NSMakeRange(1, raw.length - 2)];
    } else if ([raw isEqualToString:@"true"] || [raw isEqualToString:@"false"]) {
      value = @([raw isEqualToString:@"true"]);
    } else {
      NSScanner *scanner = [NSScanner scannerWithString:raw];
      double number;
      if ([scanner scanDouble:&number] && scanner.isAtEnd) value = [raw rangeOfString:@"."].location == NSNotFound ? @((long long)number) : @(number);
    }
    parameters[name] = value;
  }
  return parameters;
}

- (NSString *)invoke:(NSDictionary *)what object:(NSManagedObject *)object parameters:(NSDictionary *)parameters status:(NSString **)status
{
  if ([what[@"kind"] isEqual:@"temporal"]) return [self temporal:what[@"name"] entity:what[@"entity"] parameters:parameters status:status];
  ODataOperationCall *call;
  NSManagedObjectContext *context = [self context];
  if ([what[@"kind"] isEqual:@"object"]) {
    if (!object) {
      *status = @"Select a row for its operations.";
      return nil;
    }
    call = [ODataOperationCall callOfOperation:what[@"name"] onObject:object];
  } else if ([what[@"kind"] isEqual:@"entity"]) {
    call = [ODataOperationCall callOfOperation:what[@"name"] onEntity:what[@"entity"] inContext:context];
  } else {
    call = [ODataOperationCall callOfOperation:what[@"name"] inContext:context];
  }
  call.parameters = parameters;
  NSError *error = nil;
  id result = [call invoke:&error];
  if (!result) {
    *status = [NSString stringWithFormat:@"%@: %@", what[@"name"], error.localizedDescription ?: @"failed"];
    return nil;
  }
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@\n\n", call.operation.isAction ? @"Action" : @"Function",
                                                            call.operation.qualifiedName];
  if (result == [NSNull null]) {
    [text appendString:@"(returned nothing)\n"];
  } else if ([result isKindOfClass:[NSManagedObject class]]) {
    [text appendString:WBDescribe(result)];
  } else if ([result isKindOfClass:[NSArray class]] && [[result firstObject] isKindOfClass:[NSManagedObject class]]) {
    [text appendFormat:@"%lu objects\n", (unsigned long)[result count]];
    for (NSManagedObject *m in result) [text appendFormat:@"  • %@ %@\n", m.entity.name, WBTitleOf(m, [self builtIn])];
  } else {
    [text appendFormat:@"%@\n", WBCellValue(result)];
  }
  *status = [NSString stringWithFormat:@"%@ %@", call.operation.isAction ? @"POST" : @"GET", call.operation.name];
  return text;
}

// Temporal.Update, Upsert or Delete: the parameters are one delta time
// slice, attribute=value by Core Data name, its period included.
- (NSString *)temporal:(NSString *)action entity:(NSString *)entityName parameters:(NSDictionary *)parameters status:(NSString **)status
{
  NSEntityDescription *entity = _connection.model.entitiesByName[entityName];
  NSMutableDictionary *slice = [NSMutableDictionary dictionary];
  for (NSString *name in parameters) {
    NSAttributeDescription *attribute = entity.attributesByName[name];
    id value = parameters[name];
    switch (attribute.attributeType) {
      case NSDateAttributeType: value = WBDate([value description]); break;
      case NSDecimalAttributeType: value = [NSDecimalNumber decimalNumberWithString:[value description]]; break;
      case NSStringAttributeType: value = [value description]; break;
      default: break;
    }
    if (!attribute || !value) {
      *status = [NSString stringWithFormat:@"Temporal.%@: %@ is not an attribute of %@ with a value of its type", action, name, entityName];
      return nil;
    }
    slice[name] = value;
  }
  NSError *error = nil;
  NSArray *slices = [_connection.store performTemporalAction:action onEntityNamed:entityName deltaTimeslices:@[ slice ]
                                                     context:[self context] error:&error];
  if (!slices) {
    *status = [NSString stringWithFormat:@"Temporal.%@: %@", action, error.localizedDescription ?: @"failed"];
    return nil;
  }
  NSMutableString *text = [NSMutableString stringWithFormat:@"Temporal.%@ on %@: %lu time slice%@ %@\n\n", action, entityName,
                                                            (unsigned long)slices.count, slices.count == 1 ? @"" : @"s",
                                                            [action isEqualToString:@"Delete"] ? @"taken away" : @"made or changed"];
  NSArray *columns = WBColumnNames(entity, [self builtIn]);
  for (NSDictionary *one in slices) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *column in columns) [parts addObject:[NSString stringWithFormat:@"%@ = %@", column, WBCellValue(one[column]) ?: @"—"]];
    [text appendFormat:@"  • %@\n", [parts componentsJoinedByString:@", "]];
  }
  *status = [NSString stringWithFormat:@"POST %@/Temporal.%@: %lu slice%@; the timeline is read again.", entityName, action,
                                       (unsigned long)slices.count, slices.count == 1 ? @"" : @"s"];
  return text;
}

#pragma mark Streams

- (NSArray *)streamNamesOf:(NSEntityDescription *)entity
{
  ODataSchema *schema = _connection.store.schema;
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  ODataSchemaEntityType *type = entity && schema ? [mapper entityTypeForEntity:entity] : nil;
  if (!type) return @[];
  NSMutableArray *names = [NSMutableArray array];
  if ([schema entityTypeHasStream:type]) [names addObject:@""];
  [names addObjectsFromArray:[schema streamPropertiesOfEntityType:type]];
  return names;
}

static NSString *WBContentTypeOf(NSURL *file)
{
  NSDictionary *types = @{ @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"png": @"image/png", @"gif": @"image/gif",
                           @"txt": @"text/plain", @"json": @"application/json", @"xml": @"application/xml", @"pdf": @"application/pdf" };
  return types[file.pathExtension.lowercaseString] ?: @"application/octet-stream";
}

- (NSString *)download:(NSString *)stream of:(NSManagedObject *)object data:(NSData **)data
           contentType:(NSString **)contentType status:(NSString **)status
{
  ODataStreamTransfer *transfer = [[ODataStreamTransfer alloc] initWithObject:object stream:stream.length ? stream : nil];
  NSError *error = nil;
  NSURL *file = [transfer download:&error];
  if (!file) {
    *status = [NSString stringWithFormat:@"Download: %@", error.localizedDescription ?: @"failed"];
    return nil;
  }
  NSData *bytes = [NSData dataWithContentsOfURL:file] ?: [NSData data];
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ of %@ %@\n\n", stream.length ? stream : @"Media resource", object.entity.name,
                                                            WBAddressOf(object)];
  [text appendFormat:@"  content type = %@\n  media ETag = %@\n  %lu bytes, in %@\n", transfer.contentType ?: @"(none)",
                     transfer.mediaETag ?: @"(none)", (unsigned long)bytes.length, file.path];
  if ([transfer.contentType hasPrefix:@"text/"] || [transfer.contentType hasPrefix:@"application/json"]) {
    NSString *body = [[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(0, MIN(bytes.length, (NSUInteger)4096))] encoding:NSUTF8StringEncoding];
    if (body) [text appendFormat:@"\n%@\n", body];
  }
  *data = bytes;
  *contentType = transfer.contentType;
  *status = [NSString stringWithFormat:@"Downloaded %lu bytes (%@); it is kept while its media ETag is current.",
                                       (unsigned long)bytes.length, transfer.contentType ?: @"no content type"];
  return text;
}

- (BOOL)upload:(NSURL *)file into:(NSString *)stream of:(NSManagedObject *)object entity:(NSEntityDescription *)entity status:(NSString **)status
{
  NSString *type = WBContentTypeOf(file);
  NSError *error = nil;
  if (object && stream) {
    ODataStreamTransfer *transfer = [[ODataStreamTransfer alloc] initWithObject:object stream:stream.length ? stream : nil];
    if (![transfer uploadFile:file contentType:type error:&error]) {
      *status = [NSString stringWithFormat:@"Upload: %@", error.localizedDescription ?: @"failed"];
      return NO;
    }
    *status = [NSString stringWithFormat:@"Uploaded %@ (%@) to %@%@; its media ETag is now %@.", file.lastPathComponent, type,
                                         WBAddressOf(object), stream.length ? [@"/" stringByAppendingString:stream] : @"/$value",
                                         transfer.mediaETag ?: @"unknown"];
    return YES;
  }
  if (![[self streamNamesOf:entity] containsObject:@""]) {
    *status = @"Select a row to upload into its stream; only a media entity is made from a file.";
    return NO;
  }
  ODataStreamTransfer *transfer = [[ODataStreamTransfer alloc] initWithEntityName:entity.name context:[self context]];
  if (![transfer uploadFile:file contentType:type error:&error]) {
    *status = [NSString stringWithFormat:@"Upload: %@", error.localizedDescription ?: @"failed"];
    return NO;
  }
  [self putFirst:transfer.object];
  *status = [NSString stringWithFormat:@"Created %@ %@ from %@ (POST); edit its other properties and Save.",
                                       entity.name, WBAddressOf(transfer.object), file.lastPathComponent];
  return YES;
}

#pragma mark Changes at the service

- (NSString *)mergeRemoteChanges:(BOOL *)changed
{
  if (changed) *changed = NO;
  ODataIncrementalStore *store = _connection.store;
  if (!store) return @"Not connected.";
  NSError *error = nil;
  NSNotification *changes = [store fetchRemoteChanges:&error];
  if (!changes) return error.localizedDescription ?: @"could not read the changes";
  NSDictionary *info = changes.userInfo;
  if (!info.count) return @"No changes since the last look (the first look starts tracking; write with another client, then look again).";
  [[self context] mergeChangesFromContextDidSaveNotification:changes];
  if (changed) *changed = YES;
  return [NSString stringWithFormat:@"Changes at the service: %lu inserted, %lu updated, %lu deleted (a history transaction).",
                                    (unsigned long)[info[NSInsertedObjectIDsKey] count], (unsigned long)[info[NSUpdatedObjectIDsKey] count],
                                    (unsigned long)[info[NSDeletedObjectIDsKey] count]];
}

@end
