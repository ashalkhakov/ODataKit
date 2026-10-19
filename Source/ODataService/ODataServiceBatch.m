// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServiceBatch.h"
#import "ODataServiceInternal.h"
#import <HTTPServerKit/HSAuthentication.h>
#import "ODataBatch.h"
#import "ODataError.h"

// One request of the batch, and once answered, its response.
@interface OISBatchItem : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *URLString;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSData *body;
@property (nonatomic, copy, nullable) NSString *identifier;  // Content-ID, or the JSON request's id
@property (nonatomic, copy, nullable) NSString *group;       // its change set or atomicity group
// The response; status 0 until there is one.
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary *responseHeaders;
@property (nonatomic, copy) NSData *responseBody;
@end

@implementation OISBatchItem
@end

static NSString *OISHeaderValue(NSDictionary *headers, NSString *name)
{
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

static void OISAppendText(NSMutableData *data, NSString *text)
{
  [data appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

@implementation OISBatchCall {
  ODataService *_service;
  ODataExchange *_exchange;
  NSString *_version;
  BOOL _JSON;
  BOOL _continueOnError;
  NSArray<OISBatchItem *> *_items;
  NSUInteger _index;
  BOOL _stopped;
  // The change set being answered: its context, and whether it has failed.
  NSString *_group;
  NSManagedObjectContext *_groupContext;
  OISBatchItem *_groupFailure;
  NSMutableDictionary<NSString *, NSString *> *_locations;  // Content-ID -> what it created
  NSMutableSet<NSString *> *_failedGroups;
  NSMutableDictionary<NSString *, OISBatchItem *> *_groupFailures;
  // Whether the item in flight finished while it was being started.
  BOOL _starting;
  BOOL _finishedWhileStarting;
  HSPrincipal *_principal;
}

- (instancetype)initWithService:(ODataService *)service exchange:(ODataExchange *)exchange version:(NSString *)version
                      principal:(HSPrincipal *)principal
{
  self = [super init];
  if (!self) return nil;
  _service = service;
  _principal = principal;
  _exchange = exchange;
  _version = [version copy];
  _locations = [NSMutableDictionary dictionary];
  _failedGroups = [NSMutableSet set];
  _groupFailures = [NSMutableDictionary dictionary];
  return self;
}

#pragma mark Answering the batch itself

- (void)respondStatus:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body
{
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  all[@"OData-Version"] = _version;
  _exchange.URLResponse = [[NSHTTPURLResponse alloc] initWithURL:_exchange.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:all];
  _exchange.data = body ?: [NSData data];
  OTSpan *span = self.span;
  self.span = nil;
  [span setAttribute:@(status) forKey:@"http.response.status_code"];
  [span setAttribute:@(_items.count) forKey:@"odata.batch.requests"];
  if (status >= 500) [span setStatus:OTStatusError message:nil];
  [span end];
  [_exchange finish];
}

- (NSData *)errorBody:(NSInteger)status message:(NSString *)message
{
  NSDictionary *error = @{ @"error": @{ @"code": [NSString stringWithFormat:@"%ld", (long)status], @"message": message ?: @"" } };
  return [NSJSONSerialization dataWithJSONObject:error options:0 error:NULL];
}

- (void)fail:(NSInteger)status message:(NSString *)message
{
  [self respondStatus:status headers:@{ @"Content-Type": @"application/json;odata.metadata=minimal;charset=utf-8" }
                 body:[self errorBody:status message:message]];
}

#pragma mark Reading

- (void)start
{
  NSURLRequest *request = _exchange.request;
  if (![(request.HTTPMethod ?: @"GET").uppercaseString isEqualToString:@"POST"]) {
    NSDictionary *headers = @{ @"Allow": @"POST", @"Content-Type": @"application/json;odata.metadata=minimal;charset=utf-8" };
    [self respondStatus:405 headers:headers body:[self errorBody:405 message:@"$batch takes POST"]];
    return;
  }
  NSString *type = OISHeaderValue(request.allHTTPHeaderFields, @"Content-Type") ?: @"";
  NSString *prefer = [OISHeaderValue(request.allHTTPHeaderFields, @"Prefer") ?: @"" lowercaseString];
  _continueOnError = [prefer rangeOfString:@"continue-on-error"].location != NSNotFound &&
                     [prefer rangeOfString:@"continue-on-error=false"].location == NSNotFound;
  NSArray *items = nil;
  if ([type.lowercaseString hasPrefix:@"multipart/mixed"]) {
    items = [self itemsFromMultipart:request.HTTPBody type:type];
  } else if ([type.lowercaseString hasPrefix:@"application/json"]) {
    _JSON = YES;
    items = [self itemsFromJSON:request.HTTPBody];
  } else {
    [self fail:415 message:@"A $batch request is multipart/mixed, or application/json"];
    return;
  }
  if (!items) return;
  if (_service.maxBatchRequests && items.count > _service.maxBatchRequests) {
    [self fail:400 message:[NSString stringWithFormat:@"The $batch has more requests than the service takes (%lu)", (unsigned long)_service.maxBatchRequests]];
    return;
  }
  _items = items;
  [self next];
}

- (NSArray *)itemsFromMultipart:(NSData *)body type:(NSString *)type
{
  NSString *boundary = ODataMultipartBoundary(type);
  NSArray<ODataBatchPart *> *parts = boundary ? ODataBatchParts(body ?: [NSData data], boundary) : nil;
  if (!parts) {
    [self fail:400 message:@"The $batch body is not a multipart body with that boundary"];
    return nil;
  }
  NSMutableArray *items = [NSMutableArray array];
  for (ODataBatchPart *part in parts) {
    if (!part.method || !part.URLString) {
      [self fail:400 message:@"A part of the $batch body is not a request"];
      return nil;
    }
    OISBatchItem *item = [[OISBatchItem alloc] init];
    item.method = part.method.uppercaseString;
    item.URLString = part.URLString;
    item.headers = part.headers;
    item.body = part.body;
    item.identifier = part.contentID;
    item.group = part.changeSet;
    [items addObject:item];
  }
  return items;
}

- (NSArray *)itemsFromJSON:(NSData *)body
{
  if (!ODataJSONNestedWithin(body, _service.maxJSONDepth)) {
    [self fail:400 message:@"The $batch body is nested deeper than the service takes"];
    return nil;
  }
  id json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
  NSArray *requests = [json isKindOfClass:[NSDictionary class]] ? json[@"requests"] : nil;
  if (![requests isKindOfClass:[NSArray class]]) {
    [self fail:400 message:@"A JSON $batch body is an object with requests"];
    return nil;
  }
  NSMutableArray *items = [NSMutableArray array];
  NSMutableSet *groupsSeen = [NSMutableSet set];
  NSString *lastGroup = nil;
  for (NSDictionary *request in requests) {
    if (![request isKindOfClass:[NSDictionary class]] || ![request[@"id"] isKindOfClass:[NSString class]] ||
        ![request[@"method"] isKindOfClass:[NSString class]] || ![request[@"url"] isKindOfClass:[NSString class]]) {
      [self fail:400 message:@"Each request of a JSON $batch has an id, a method and a url"];
      return nil;
    }
    OISBatchItem *item = [[OISBatchItem alloc] init];
    item.identifier = request[@"id"];
    item.method = [request[@"method"] uppercaseString];
    item.URLString = request[@"url"];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSDictionary *given = [request[@"headers"] isKindOfClass:[NSDictionary class]] ? request[@"headers"] : @{};
    for (NSString *name in given) {
      if ([given[name] isKindOfClass:[NSString class]]) headers[name] = given[name];
    }
    id content = request[@"body"];
    if ([content isKindOfClass:[NSDictionary class]] || [content isKindOfClass:[NSArray class]]) {
      item.body = [NSJSONSerialization dataWithJSONObject:content options:0 error:NULL];
      if (!OISHeaderValue(headers, @"Content-Type")) headers[@"Content-Type"] = @"application/json";
    } else if ([content isKindOfClass:[NSString class]]) {
      item.body = [content dataUsingEncoding:NSUTF8StringEncoding];
    } else {
      item.body = [NSData data];
    }
    item.headers = headers;
    NSString *group = [request[@"atomicityGroup"] isKindOfClass:[NSString class]] ? request[@"atomicityGroup"] : nil;
    if (group && ![group isEqualToString:lastGroup] && [groupsSeen containsObject:group]) {
      [self fail:400 message:[NSString stringWithFormat:@"The requests of atomicity group %@ are not together", group]];
      return nil;
    }
    if (group) [groupsSeen addObject:group];
    lastGroup = group;
    item.group = group;
    [items addObject:item];
  }
  return items;
}

#pragma mark Answering the requests

// $1, and $1/Products: what request 1 created, where a URL is expected.
- (NSString *)resolvedReference:(NSString *)text
{
  if (![text hasPrefix:@"$"]) return nil;
  NSRange slash = [text rangeOfString:@"/"];
  NSString *name = [text substringWithRange:NSMakeRange(1, (slash.location == NSNotFound ? text.length : slash.location) - 1)];
  NSString *location = _locations[name];
  if (!location) return nil;
  return slash.location == NSNotFound ? location : [location stringByAppendingString:[text substringFromIndex:slash.location]];
}

- (NSData *)bodyResolvingReferences:(NSData *)body headers:(NSDictionary *)headers
{
  NSString *type = OISHeaderValue(headers, @"Content-Type") ?: @"";
  if (!body.length || ![type.lowercaseString hasPrefix:@"application/json"] || !_locations.count) return body;
  id json = [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:NULL];
  if (![json isKindOfClass:[NSMutableDictionary class]]) return body;
  NSMutableDictionary *object = json;
  for (NSString *key in object.allKeys) {
    if (![key hasSuffix:@"@odata.bind"] && ![key hasSuffix:@"@bind"]) continue;
    id value = object[key];
    if ([value isKindOfClass:[NSString class]]) {
      object[key] = [self resolvedReference:value] ?: value;
    } else if ([value isKindOfClass:[NSArray class]]) {
      NSMutableArray *resolved = [NSMutableArray array];
      for (id each in value) [resolved addObject:([each isKindOfClass:[NSString class]] ? [self resolvedReference:each] : nil) ?: each];
      object[key] = resolved;
    }
  }
  return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] ?: body;
}

- (NSURLRequest *)requestFor:(OISBatchItem *)item
{
  NSString *text = [self resolvedReference:item.URLString] ?: item.URLString;
  NSURL *url = [NSURL URLWithString:text relativeToURL:_service.serviceRoot].absoluteURL;
  if (!url) return nil;
  // The batch's $schemaversion, for a request that names none (Part 1,
  // 11.2.12).
  NSString *version = nil;
  for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:_exchange.request.URL resolvingAgainstBaseURL:NO].queryItems) {
    if ([item.name isEqualToString:@"$schemaversion"]) version = item.value;
  }
  NSString *query = url.query ?: @"";
  if (version && [query rangeOfString:@"$schemaversion="].location == NSNotFound
      && [query rangeOfString:@"%24schemaversion="].location == NSNotFound) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.queryItems = [(components.queryItems ?: @[]) arrayByAddingObject:[NSURLQueryItem queryItemWithName:@"$schemaversion" value:version]];
    url = components.URL ?: url;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = item.method;
  // The batch's own headers (who is asking, which versions) hold for each
  // request, under the request's own.
  NSSet *batchOnly = [NSSet setWithObjects:@"content-type", @"content-length", @"accept", @"prefer", @"transfer-encoding", @"expect", nil];
  NSDictionary *outer = _exchange.request.allHTTPHeaderFields;
  for (NSString *name in outer) {
    if (![batchOnly containsObject:name.lowercaseString]) [request setValue:outer[name] forHTTPHeaderField:name];
  }
  for (NSString *name in item.headers) [request setValue:item.headers[name] forHTTPHeaderField:name];
  // Each request's span under the batch's.
  if (self.span) [request ot_setTraceContext:self.span.context];
  request.HTTPBody = [self bodyResolvingReferences:item.body headers:item.headers];
  return request;
}

// The batch's requests, on from where it is: an exception anywhere in them
// answers the batch 500, rather than leave its client waiting.
- (void)next
{
  @try {
    [self runItems];
  } @catch (NSException *exception) {
    OISLog(HSLogLevelError, _exchange.request, @"%@ %@ raised %@: %@", _exchange.request.HTTPMethod, _exchange.request.URL, exception.name,
           exception.reason);
    _stopped = YES;
    [self.span addEventNamed:@"exception" attributes:@{ @"exception.type": exception.name ?: @"", @"exception.message": exception.reason ?: @"" }];
    [self fail:500 message:@"The batch failed inside the service"];
  }
}

- (void)runItems
{
  while (_index < _items.count && !_stopped) {
    OISBatchItem *item = _items[_index];
    if (item.group && ![item.group isEqualToString:_group]) [self beginGroup:item.group];

    // The rest of a change set that has failed is not attempted.
    if (item.group && _groupFailure) {
      [self advance];
      continue;
    }
    if (item.group && [item.method isEqualToString:@"GET"] && !_JSON) {
      [self record:item status:400 headers:@{ @"Content-Type": @"application/json" }
              body:[self errorBody:400 message:@"A change set holds changes only; send GET outside it"]];
      [self advance];
      continue;
    }
    NSURLRequest *request = [self requestFor:item];
    if (!request) {
      [self record:item status:400 headers:@{ @"Content-Type": @"application/json" }
              body:[self errorBody:400 message:[NSString stringWithFormat:@"%@ is not a URL", item.URLString]]];
      [self advance];
      continue;
    }
    ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:request target:self action:@selector(itemDidFinish:)];
    exchange.context = item;
    @synchronized (self) {
      _starting = YES;
      _finishedWhileStarting = NO;
    }
    [_service startExchange:exchange inContext:_groupContext saves:(item.group == nil) authenticated:YES principal:_principal given:NO];
    BOOL finished;
    @synchronized (self) {
      _starting = NO;
      finished = _finishedWhileStarting;
    }
    // A handler that answers later: the batch goes on from -itemDidFinish:.
    if (!finished) return;
  }
  [self finish];
}

- (void)itemDidFinish:(ODataExchange *)exchange
{
  OISBatchItem *item = exchange.context;
  NSHTTPURLResponse *http = [exchange.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)exchange.URLResponse : nil;
  [self record:item status:(http ? http.statusCode : 500) headers:http.allHeaderFields ?: @{} body:exchange.data ?: [NSData data]];
  [self advance];
  BOOL resume;
  @synchronized (self) {
    resume = !_starting;
    if (_starting) _finishedWhileStarting = YES;
  }
  if (resume) [self next];
}

- (void)record:(OISBatchItem *)item status:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body
{
  item.status = status;
  item.responseHeaders = headers;
  item.responseBody = body;
  NSString *location = OISHeaderValue(headers, @"Location") ?: OISHeaderValue(headers, @"OData-EntityId");
  if (item.identifier && location && status < 400) _locations[item.identifier] = location;
  if (status >= 400) {
    if (item.group) {
      if (!_groupFailure) _groupFailure = item;
    } else if (!_continueOnError) {
      _stopped = YES;
    }
  }
}

// Past this item; the end of its change set, if it was the last one.
- (void)advance
{
  OISBatchItem *item = _items[_index];
  _index++;
  if (item.group && (_index >= _items.count || ![_items[_index].group isEqualToString:item.group])) [self endGroup];
}

- (void)beginGroup:(NSString *)group
{
  _group = group;
  _groupFailure = nil;
  _groupContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  _groupContext.persistentStoreCoordinator = _service.coordinator;
}

// All of it, or none: saved when every request succeeded, else rolled back.
// An exception at the save (a willSave that raises) is a failed save, the
// change set's last request answered 500: caught here, as the group ends
// inside its last request's answer, which has answered already and so
// cannot answer for it (#44).
- (void)endGroup
{
  NSManagedObjectContext *context = _groupContext;
  __block NSError *error = nil;
  __block BOOL saved = NO;
  if (!_groupFailure) {
    [context performBlockAndWait:^{
      @autoreleasepool {
        NSError *e = nil;
        @try {
          saved = !context.hasChanges || OISTimedSave(self->_service, context, self.span, nil, &e);
        } @catch (NSException *exception) {
          OISLog(HSLogLevelError, self->_exchange.request, @"%@ %@: change set %@'s save raised %@: %@", self->_exchange.request.HTTPMethod,
                 self->_exchange.request.URL, self->_group, exception.name, exception.reason);
          [self.span addEventNamed:@"exception" attributes:@{ @"exception.type": exception.name ?: @"", @"exception.message": exception.reason ?: @"" }];
          saved = NO;
          e = [NSError errorWithDomain:ODataServiceErrorDomain code:500
                              userInfo:@{ NSLocalizedDescriptionKey: @"The change set failed inside the service" }];
        }
        if (!saved) [context rollback];
        error = e;
      }
    }];
  } else {
    [context performBlockAndWait:^{
      [context rollback];
    }];
  }
  if (!_groupFailure && !saved) {
    NSInteger status = 500;
    if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code >= NSValidationErrorMinimum && error.code <= NSValidationErrorMaximum) status = 400;
    if ([error.domain isEqualToString:NSCocoaErrorDomain] && (error.code == 133020 || error.code == 133021)) status = 409;
    // The save is the change set's; its last request answers for it.
    OISBatchItem *last = _items[_index - 1];
    last.status = status;
    last.responseHeaders = @{ @"Content-Type": @"application/json;odata.metadata=minimal;charset=utf-8" };
    last.responseBody = [self errorBody:status message:error.localizedDescription ?: @"The change set could not be saved"];
    _groupFailure = last;
  }
  if (_groupFailure) {
    [_failedGroups addObject:_group];
    _groupFailures[_group] = _groupFailure;
    if (!_continueOnError) _stopped = YES;
  }
  _group = nil;
  _groupContext = nil;
}

#pragma mark Writing the response

- (void)finish
{
  if (_group) [self endGroup];  // stopped inside a change set
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  if (_continueOnError) headers[@"Preference-Applied"] = @"odata.continue-on-error";
  if (_JSON) {
    headers[@"Content-Type"] = @"application/json;charset=utf-8";
    [self respondStatus:200 headers:headers body:[self JSONResponse]];
    return;
  }
  NSString *boundary = [@"batchresponse_" stringByAppendingString:[NSUUID UUID].UUIDString];
  headers[@"Content-Type"] = [@"multipart/mixed; boundary=" stringByAppendingString:boundary];
  [self respondStatus:200 headers:headers body:[self multipartResponseWithBoundary:boundary]];
}

- (void)appendHTTPPart:(OISBatchItem *)item boundary:(NSString *)boundary to:(NSMutableData *)out
{
  OISAppendText(out, [NSString stringWithFormat:@"--%@\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n", boundary]);
  if (item.identifier) OISAppendText(out, [NSString stringWithFormat:@"Content-ID: %@\r\n", item.identifier]);
  OISAppendText(out, [NSString stringWithFormat:@"\r\nHTTP/1.1 %ld %@\r\n", (long)item.status, ODataHTTPReasonPhrase(item.status)]);
  for (NSString *name in [item.responseHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    OISAppendText(out, [NSString stringWithFormat:@"%@: %@\r\n", name, item.responseHeaders[name]]);
  }
  OISAppendText(out, @"\r\n");
  if (item.responseBody.length) [out appendData:item.responseBody];
  OISAppendText(out, @"\r\n");
}

- (NSData *)multipartResponseWithBoundary:(NSString *)boundary
{
  NSMutableData *out = [NSMutableData data];
  NSUInteger i = 0;
  while (i < _items.count) {
    OISBatchItem *item = _items[i];
    if (!item.group) {
      if (item.status) [self appendHTTPPart:item boundary:boundary to:out];
      i++;
      continue;
    }
    NSString *group = item.group;
    NSMutableArray *members = [NSMutableArray array];
    while (i < _items.count && [_items[i].group isEqualToString:group]) [members addObject:_items[i++]];
    OISBatchItem *first = members.firstObject;
    if (!first.status && ![_failedGroups containsObject:group]) continue;  // never reached
    if ([_failedGroups containsObject:group]) {
      // A failed change set is answered with its failure alone.
      [self appendHTTPPart:_groupFailures[group] boundary:boundary to:out];
      continue;
    }
    NSString *inner = [@"changesetresponse_" stringByAppendingString:[NSUUID UUID].UUIDString];
    OISAppendText(out, [NSString stringWithFormat:@"--%@\r\nContent-Type: multipart/mixed; boundary=%@\r\n\r\n", boundary, inner]);
    for (OISBatchItem *member in members) [self appendHTTPPart:member boundary:inner to:out];
    OISAppendText(out, [NSString stringWithFormat:@"--%@--\r\n", inner]);
  }
  OISAppendText(out, [NSString stringWithFormat:@"--%@--\r\n", boundary]);
  return out;
}

- (NSData *)JSONResponse
{
  NSMutableArray *responses = [NSMutableArray array];
  for (OISBatchItem *item in _items) {
    BOOL failedGroup = item.group && [_failedGroups containsObject:item.group];
    if (!item.status && !failedGroup) continue;  // never reached
    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"id"] = item.identifier ?: @"";
    if (item.group) response[@"atomicityGroup"] = item.group;
    if (failedGroup && _groupFailures[item.group] != item) {
      // The others of a failed atomicity group did not take effect.
      response[@"status"] = @424;
      response[@"body"] = [NSJSONSerialization JSONObjectWithData:[self errorBody:424 message:@"Another request of its atomicity group failed"]
                                                          options:0 error:NULL];
      [responses addObject:response];
      continue;
    }
    response[@"status"] = @(item.status);
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSString *name in item.responseHeaders) {
      if ([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
      headers[name] = item.responseHeaders[name];
    }
    if (headers.count) response[@"headers"] = headers;
    if (item.responseBody.length) {
      NSString *type = [OISHeaderValue(item.responseHeaders, @"Content-Type") ?: @"" lowercaseString];
      id body = [type hasPrefix:@"application/json"] ? [NSJSONSerialization JSONObjectWithData:item.responseBody options:0 error:NULL] : nil;
      response[@"body"] = body ?: [[NSString alloc] initWithData:item.responseBody encoding:NSUTF8StringEncoding] ?: @"";
    }
    [responses addObject:response];
  }
  return [NSJSONSerialization dataWithJSONObject:@{ @"responses": responses } options:0 error:NULL];
}

@end
