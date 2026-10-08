// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"

// An entity tag no remote gives.
static NSString * const ODSUnknownVersion = @"\"ODataSync.unknown\"";

@implementation ODSRequests {
  __weak ODataSyncEngine *_engine;
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

#pragma mark URLs

- (NSURL *)URLOf:(NSString *)relative
{
  NSString *root = _remote.serviceRoot.absoluteString;
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
  [allowed removeCharactersInString:@"+"];
  NSString *encoded = [relative stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  return [self versioned:[NSURL URLWithString:[root stringByAppendingString:encoded]]];
}

- (NSURL *)URLOfLink:(NSString *)link relativeTo:(NSURL *)base
{
  return [self versioned:base ? [NSURL URLWithString:link relativeToURL:base].absoluteURL : [NSURL URLWithString:link]];
}

// The version of the schema this side speaks, on every request (OData
// 4.01's $schemaversion; a $batch's requests have the batch's): a service
// on a newer one can read what it sends.
- (NSURL *)versioned:(NSURL *)url
{
  NSString *version = _engine.modelVersion;
  NSString *query = url.query;
  if (!version.length || !url || [query ?: @"" rangeOfString:@"schemaversion="].location != NSNotFound) return url;
  NSString *value = [version stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
  return [NSURL URLWithString:[url.absoluteString stringByAppendingFormat:@"%@$schemaversion=%@", query ? @"&" : @"?", value]] ?: url;
}

- (NSDictionary<NSString *, NSString *> *)headers
{
  ODataSyncEngine *engine = _engine;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  if (_remote.peer) headers[ODataSyncReplicaHeader] = engine.replicaID;
  return headers;
}

#pragma mark Reads

// Typed, as the store's queries are, and written by ODataKit: names and
// values checked as they are built, never text put together here.

// A path (written of names checked, ODSModel -checkNames:) and its
// options, each value percent-encoded.
- (NSURL *)URLOfPath:(NSString *)path options:(ODataQueryOptions *)options error:(NSError **)error
{
  NSArray *items = [options queryItemsWithError:error];
  if (!items) return nil;
  NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
  [allowed removeCharactersInString:@"&=+#"];
  NSMutableArray *query = [NSMutableArray array];
  for (NSArray *item in items) {
    [query addObject:[NSString stringWithFormat:@"%@=%@", item[0], [item[1] stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
  }
  NSString *root = _remote.serviceRoot.absoluteString;
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSMutableCharacterSet *segment = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
  [segment removeCharactersInString:@"?#"];
  NSString *written = [root stringByAppendingString:[path stringByAddingPercentEncodingWithAllowedCharacters:segment]];
  if (query.count) written = [written stringByAppendingFormat:@"?%@", [query componentsJoinedByString:@"&"]];
  NSURL *url = [NSURL URLWithString:written];
  if (!url && error) *error = OISError(ODataIncrementalStoreErrorTransport, [NSString stringWithFormat:@"Could not build a URL for %@", path]);
  return url ? [self versioned:url] : nil;
}

// The key's names, as $select items, for reading only keys.
- (NSArray<ODataSelectItem *> *)selectOfKeyOfEntity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [_model keyAttributesOf:entity]) {
    ODataSelectItem *item = [ODataSelectItem itemWithPath:@[ [_model.mapper propertyForAttribute:attribute] ] error:error];
    if (!item) return nil;
    [items addObject:item];
  }
  return items;
}

// $expand of the to-ones' keys, for reading an entity's rows.
- (NSArray<ODataExpandItem *> *)expandOfEntity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSRelationshipDescription *toOne in [_model toOnesOf:entity]) {
    ODataMutableQueryOptions *keys = [[ODataMutableQueryOptions alloc] init];
    keys.select = [self selectOfKeyOfEntity:toOne.destinationEntity error:error];
    if (!keys.select) return nil;
    ODataExpandItem *item = [ODataExpandItem itemWithPath:@[ [_model.mapper propertyForRelationship:toOne] ] options:keys error:error];
    if (!item) return nil;
    [items addObject:item];
  }
  return items;
}

// A filter naming these keys (k eq 1 or k eq 2; (a eq 1 and b eq 2) or ...).
- (ODataExpression *)filterOfKeys:(NSArray<NSDictionary *> *)keys entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSArray<NSAttributeDescription *> *attributes = [_model keyAttributesOf:entity];
  ODataExpression *any = nil;
  for (NSDictionary *key in keys) {
    ODataExpression *all = nil;
    for (NSAttributeDescription *attribute in attributes) {
      NSString *text = [_model.mapper.values literalForValue:key[attribute.name] attribute:attribute];
      ODataExpression *literal = [ODataExpression literalWithText:text];
      if (!literal) {
        if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"%@ is no literal of %@", text, attribute.name]);
        return nil;
      }
      ODataExpression *equal = [ODataExpression binary:@"eq" left:[ODataExpression member:[_model.mapper propertyForAttribute:attribute] of:nil error:error]
                                                 right:literal error:error];
      all = all ? [ODataExpression binary:@"and" left:all right:equal error:error] : equal;
      if (!all) return nil;
    }
    any = any ? [ODataExpression binary:@"or" left:any right:all error:error] : all;
    if (!any) return nil;
  }
  return any;
}

// The remote's filter for a set (ODataSyncRemote's filters: $filter text),
// read as an expression; nil and no error for none.
- (BOOL)filter:(ODataExpression **)filter ofSet:(NSEntityDescription *)entity error:(NSError **)error
{
  NSString *text = _remote.filters[entity.name];
  *filter = text.length ? [ODataExpression expressionWithString:text error:error] : nil;
  return !text.length || *filter;
}

// Set?$filter=...&$select=...&$expand=to-one keys.
// $select of a row without its merged attributes, which come as deltas
// (docs/offline-sync.md, 14); nil (all) for an entity that has none, or
// subentities (whose properties a $select would need to cast to).
- (NSArray<ODataSelectItem *> *)selectWithoutMergedOf:(NSEntityDescription *)entity error:(NSError **)error
{
  if (![_model mergedAttributesOf:entity].count || entity.subentities.count) return nil;
  NSMutableArray *items = [NSMutableArray array];
  NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
  for (NSAttributeDescription *attribute in [[_model keyAttributesOf:entity] arrayByAddingObjectsFromArray:[_model attributesOf:entity]]) {
    [names addObject:[_model.mapper propertyForAttribute:attribute]];
  }
  for (NSString *name in names) {
    ODataSelectItem *item = [ODataSelectItem itemWithPath:@[ name ] error:error];
    if (!item) return nil;
    [items addObject:item];
  }
  return items;
}

- (NSURL *)URLOfSet:(NSEntityDescription *)entity filter:(ODataExpression *)filter select:(NSArray *)select expand:(BOOL)expand
              error:(NSError **)error
{
  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  options.filter = filter;
  if (!select) select = [self selectWithoutMergedOf:entity error:NULL];
  if (select) options.select = select;
  if (expand) {
    options.expand = [self expandOfEntity:entity error:error];
    if (!options.expand) return nil;
  }
  return [self URLOfPath:[_model.mapper entitySetForEntity:entity] options:options error:error];
}

- (NSURL *)URLOfSet:(NSEntityDescription *)entity keysOnly:(BOOL)keysOnly error:(NSError **)error
{
  ODataExpression *filter = nil;
  if (![self filter:&filter ofSet:entity error:error]) return nil;
  NSArray *select = nil;
  if (keysOnly && !(select = [self selectOfKeyOfEntity:entity error:error])) return nil;
  return [self URLOfSet:entity filter:filter select:select expand:!keysOnly error:error];
}

- (NSURL *)URLOfSet:(NSEntityDescription *)entity keys:(NSArray<NSDictionary *> *)keys error:(NSError **)error
{
  ODataExpression *filter = nil;
  if (![self filter:&filter ofSet:entity error:error]) return nil;
  ODataExpression *named = [self filterOfKeys:keys entity:entity error:error];
  if (!named) return nil;
  ODataExpression *both = filter ? [ODataExpression binary:@"and" left:filter right:named error:error] : named;
  return both ? [self URLOfSet:entity filter:both select:nil expand:YES error:error] : nil;
}

- (NSURL *)URLOfObject:(NSEntityDescription *)entity key:(NSDictionary *)key error:(NSError **)error
{
  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  options.expand = [self expandOfEntity:[_model rootOf:entity] error:error];
  if (!options.expand) return nil;
  NSArray *select = [self selectWithoutMergedOf:[_model rootOf:entity] error:NULL];
  if (select) options.select = select;
  return [self URLOfPath:[_codec pathOfEntity:entity key:key] options:options error:error];
}

- (NSMutableURLRequest *)GET:(NSURL *)url prefer:(NSString *)prefer
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  if (prefer) [request setValue:prefer forHTTPHeaderField:@"Prefer"];
  NSDictionary *headers = [self headers];
  for (NSString *name in headers) [request setValue:headers[name] forHTTPHeaderField:name];
  return request;
}

#pragma mark Changes

- (NSDictionary *)upsertOf:(NSManagedObject *)object entity:(NSEntityDescription *)root key:(NSDictionary *)key
                properties:(NSSet<NSString *> *)properties insert:(BOOL)insert checked:(BOOL)checked etag:(NSString *)etag
{
  NSMutableDictionary *headers = [[self headers] mutableCopy];
  headers[@"Content-Type"] = @"application/json";
  headers[@"Prefer"] = @"return=minimal";
  // A change of a version never agreed on with this remote (one that came
  // from elsewhere): matching nothing, it meets the remote's version (a
  // 412, and the resolver), and so never overwrites it unseen.
  if (checked && insert && !etag) headers[@"If-None-Match"] = @"*";
  else if (checked) headers[@"If-Match"] = etag ?: ODSUnknownVersion;
  return @{ @"method": @"PATCH", @"url": [_codec pathOfEntity:root key:key], @"headers": headers,
            @"body": [_codec JSONOfObject:object properties:insert ? nil : properties] };
}

- (NSDictionary *)deletionOf:(NSEntityDescription *)root key:(NSDictionary *)key checked:(BOOL)checked etag:(NSString *)etag
                    versions:(NSDictionary<NSString *, NSNumber *> *)versions
{
  NSMutableDictionary *headers = [[self headers] mutableCopy];
  if (checked) headers[@"If-Match"] = etag ?: @"*";
  // The deletion's history, for the remote's tombstone.
  if (versions.count) headers[ODataSyncVersionsHeader] = ODSTextOfVersions(versions);
  return @{ @"method": @"DELETE", @"url": [_codec pathOfEntity:root key:key], @"headers": headers };
}

- (NSMutableURLRequest *)HTTPRequestOf:(NSDictionary *)request
{
  NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:[self URLOf:request[@"url"]]];
  http.HTTPMethod = request[@"method"];
  [http setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSDictionary *given = request[@"headers"];
  for (NSString *name in given) [http setValue:given[name] forHTTPHeaderField:name];
  if (request[@"body"]) http.HTTPBody = [NSJSONSerialization dataWithJSONObject:request[@"body"] options:0 error:NULL];
  return http;
}

- (NSMutableURLRequest *)batchOf:(NSArray<NSDictionary *> *)requests
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSUInteger i = 0; i < requests.count; i++) {
    NSMutableDictionary *item = [requests[i] mutableCopy];
    item[@"id"] = [NSString stringWithFormat:@"%lu", (unsigned long)i + 1];
    [items addObject:item];
  }
  NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:[self URLOf:@"$batch"]];
  http.HTTPMethod = @"POST";
  [http setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [http setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [http setValue:@"odata.continue-on-error" forHTTPHeaderField:@"Prefer"];
  NSDictionary *headers = [self headers];
  for (NSString *name in headers) [http setValue:headers[name] forHTTPHeaderField:name];
  http.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"requests": items } options:0 error:NULL];
  return http;
}

@end
