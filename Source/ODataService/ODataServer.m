// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServer.h"
#import "ODataError.h"
#include <dlfcn.h>

static BOOL OISFailWith(NSError **error, NSString *message)
{
  if (error) *error = [NSError errorWithDomain:HSErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
  return NO;
}

static NSURL *OISURL(id text)
{
  if (![text isKindOfClass:[NSString class]] || ![text length]) return nil;
  return [text rangeOfString:@"://"].location != NSNotFound ? [NSURL URLWithString:text] : [NSURL fileURLWithPath:text];
}

static NSString *OISStoreType(NSString *name)
{
  NSMutableDictionary *known = [@{ @"SQLite": NSSQLiteStoreType, @"InMemory": NSInMemoryStoreType } mutableCopy];
#if !(defined(__APPLE__) && TARGET_OS_IPHONE)
  known[@"XML"] = NSXMLStoreType;  // not on iOS
#endif
#if defined(__APPLE__)
  known[@"Binary"] = NSBinaryStoreType;  // FreeCoreData has none
#endif
  return known[name] ?: name;
}

// A store type nothing has registered: a backend's library, by its name
// (CDPostgreSQLStore is libCDPostgreSQLStore), registers it when loaded.
// Not found is not an error here: opening the store says what is wrong.
static void OISLoadBackendFor(NSString *type)
{
  if ([NSPersistentStoreCoordinator registeredStoreTypes][type]) return;
  if ([type rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) return;
#if defined(__APPLE__)
  NSString *library = [NSString stringWithFormat:@"lib%@.dylib", type];
#else
  NSString *library = [NSString stringWithFormat:@"lib%@.so", type];
#endif
  dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
}


#pragma mark - The service mounted


@implementation ODataServiceHandler

+ (void)initialize
{
  if (self == [ODataServiceHandler class]) HSRegisterStatusErrorDomain(ODataServiceErrorDomain);
}

- (instancetype)initWithService:(ODataService *)service
{
  self = [super init];
  if (!self) return nil;
  _service = service;
  return self;
}

// What a request under the service root asks, by a name of few values: the
// entity set (or operation import) it names first, $metadata, $batch...;
// the service document; or (other), so a client cannot make up new ones.
- (NSString *)operationOf:(HSRequest *)request
{
  NSString *root = self.service.serviceRoot.path.length ? self.service.serviceRoot.path : @"/";
  NSString *path = request.path;
  NSString *rest = [path hasPrefix:root] ? [path substringFromIndex:root.length] : @"";
  if ([rest hasPrefix:@"/"]) rest = [rest substringFromIndex:1];
  NSString *first = [rest componentsSeparatedByString:@"/"].firstObject ?: @"";
  NSRange parenthesis = [first rangeOfString:@"("];
  if (parenthesis.location != NSNotFound) first = [first substringToIndex:parenthesis.location];
  if (!first.length) return @"(service document)";
  if ([first hasPrefix:@"$"] && first.length < 20) return first;
  return [self.service.entitySets containsObject:first] ? first : @"(other)";
}

- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  request.operation = [self operationOf:request];
  NSMutableURLRequest *urlRequest = [[request URLRequestOnOrigin:self.service.serviceRoot] mutableCopy];
  // Who asked, for the service's handlers and logs: the request id, and the
  // trace context this server's span carries on.
  NSString *requestID = request.userInfo[HSRequestIDKey];
  if (requestID) [urlRequest setValue:requestID forHTTPHeaderField:@"X-Request-ID"];
  OTSpanContext *trace = request.span.context;
  if (trace) {
    [urlRequest ot_setTraceContext:trace];
  } else if (request.userInfo[HSTraceparentKey]) {
    [urlRequest setValue:request.userInfo[HSTraceparentKey] forHTTPHeaderField:@"traceparent"];
  }
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:urlRequest target:self action:@selector(exchangeDidFinish:)];
  exchange.context = reply;
  if (request.authenticated) {
    [self.service startExchange:exchange principal:request.principal];
  } else {
    [self.service startExchange:exchange];
  }
}

- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  HSReply *reply = exchange.context;
  NSHTTPURLResponse *http = [exchange.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)exchange.URLResponse : nil;
  if (!http) {
    [reply failWithError:exchange.error ?: HSError(500, @"The service gave no answer")];
    return;
  }
  HSResponse *response = [HSResponse responseWithStatus:http.statusCode];
  response.body = exchange.data.length ? exchange.data : nil;
  NSDictionary *headers = http.allHeaderFields;
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    [response setValue:headers[name] forHeader:name];
  }
  [reply finishWithResponse:response];
}

// As OData answers errors: {"error": {"code", "message"}}, with the
// challenge a 401 or a 403 for scopes needs.
- (HSResponse *)responseForError:(NSError *)error request:(HSRequest *)request
{
  NSInteger status = [HSResponse statusOfError:error];
  NSString *message = status == 500 && ![error.domain isEqualToString:ODataServiceErrorDomain] && ![error.domain isEqualToString:HSErrorDomain]
      ? @"The service could not answer the request" : (error.localizedDescription ?: @"");
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  body[@"code"] = error.userInfo[ODataErrorCodeKey] ?: [NSString stringWithFormat:@"%ld", (long)status];
  body[@"message"] = message;
  if (error.userInfo[ODataErrorTargetKey]) body[@"target"] = error.userInfo[ODataErrorTargetKey];
  HSResponse *response = [HSResponse responseWithJSON:@{ @"error": body } status:status];
  [response setValue:@"4.01" forHeader:@"OData-Version"];
  NSString *challenge = [HSResponse challengeForError:error];
  if (challenge) [response setValue:challenge forHeader:@"WWW-Authenticate"];
  return response;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataServiceHandler %@>", self.service.serviceRoot.absoluteString];
}

@end

#pragma mark - Readiness

@implementation ODataServiceStoreCheck {
  ODataService *_service;
}

- (instancetype)initWithService:(ODataService *)service
{
  self = [super init];
  if (!self) return nil;
  _service = service;
  return self;
}

- (NSString *)name
{
  return @"store";
}

// A store that does not answer (a database gone) is not ready: a count of
// one entity set, in a context of its own.
- (void)checkReadiness:(HSCheck *)check
{
  NSString *set = _service.entitySets.firstObject;
  NSEntityDescription *entity = set ? [_service handlerForEntitySet:set].entity : nil;
  if (!entity) {
    [check pass];
    return;
  }
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = _service.coordinator;
  [context performBlock:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity.name];
    fetch.fetchLimit = 1;
    NSError *error = nil;
    if ([context countForFetchRequest:fetch error:&error] == NSNotFound) {
      [check failWithReason:error.localizedDescription ?: @"The store did not answer"];
    } else {
      [check pass];
    }
  }];
}

@end


#pragma mark - The module

@implementation ODataServiceModule

+ (void)initialize
{
  // The service's errors are statuses, wherever HTTPServerKit meets them.
  if (self == [ODataServiceModule class]) HSRegisterStatusErrorDomain(ODataServiceErrorDomain);
}

- (instancetype)initWithService:(ODataService *)service
{
  self = [super init];
  if (!self) return nil;
  _service = service;
  return self;
}

- (BOOL)addToApplication:(HSApplication *)application error:(NSError **)error
{
  ODataService *service = self.service;
  // An operation that cannot be declared would answer 404 until someone
  // noticed: better not to start.
  if (service.operationProblems.count) {
    return OISFailWith(error, [NSString stringWithFormat:@"the service cannot declare these operations; fix them, or leave them out:\n  %@",
                                                         [service.operationProblems componentsJoinedByString:@"\n  "]]);
  }
  if (!service.authenticator) service.authenticator = application.authenticator;
  if (!service.metrics) service.metrics = application.metrics;
  // Read here, not by ODataServerConfiguration, so that an application of
  // its own settings (SN_ALLOW_ANONYMOUS_METADATA) has it too.
  HSConfiguration *settings = application.configuration;
  if ([settings setting:@"AllowAnonymousMetadata"]) service.allowsAnonymousMetadata = [settings flag:@"AllowAnonymousMetadata" otherwise:NO];
  // A Core Data that traces its stores' work (FreeCoreData; see
  // docs/observability.md) is handed a tracer of its own name: its spans
  // go under the service's store requests, current on the thread it works on.
  Class coordinator = [NSPersistentStoreCoordinator class];
  SEL setTracer = NSSelectorFromString(@"cd_setTracer:");
  if ([coordinator respondsToSelector:setTracer]) {
    void (*set)(id, SEL, id) = (void (*)(id, SEL, id))[coordinator methodForSelector:setTracer];
    set(coordinator, setTracer, [OTTracer tracerNamed:@"FreeCoreData" version:nil]);
  }
  NSString *root = service.serviceRoot.path.length ? service.serviceRoot.path : @"/";
  [application.router addRoute:[HSRoute routeWithMethod:nil path:[root stringByAppendingPathComponent:@"*"]
                                                handler:[[ODataServiceHandler alloc] initWithService:service]]];
  [application.readiness addCheck:[[ODataServiceStoreCheck alloc] initWithService:service]];
  return YES;
}

- (NSString *)startupDescription
{
  return [NSString stringWithFormat:@"OData at %@, %lu entity sets", self.service.serviceRoot.absoluteString,
                                    (unsigned long)self.service.entitySets.count];
}

@end

#pragma mark - Settings

@implementation ODataServerConfiguration

+ (NSString *)environmentPrefix
{
  return @"OIS_";
}

+ (NSArray<NSString *> *)knownSettings
{
  return [[super knownSettings] arrayByAddingObjectsFromArray:@[
    @"Model", @"StoreType", @"StoreURL", @"StoreOptions", @"ServiceRoot", @"MaxPageSize", @"MaxVersion", @"Namespace", @"Container",
    @"MaxURLLength", @"MaxExpandDepth", @"MaxBatchRequests", @"MaxRowsInMemory", @"MaxJSONDepth", @"MaxAsyncRequests",
    @"ReplyTimeout", @"AsyncResultDuration", @"RepeatabilityDuration", @"RepeatabilityMemory", @"HistoryRetention", @"AllowAnonymous", @"AllowAnonymousMetadata", @"PrintMetadata" ]];
}

- (BOOL)printsMetadata
{
  return [self flag:@"PrintMetadata" otherwise:NO];
}


- (ODataService *)serviceWithError:(NSError **)error
{
  NSString *modelPath = [self setting:@"Model"];
  if (!modelPath) {
    OISFailWith(error, @"no -Model: give the compiled model, or a -Config that names it");
    return nil;
  }
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:OISURL(modelPath)];
  if (!model.entities.count) {
    OISFailWith(error, [NSString stringWithFormat:@"%@ is not a model", modelPath]);
    return nil;
  }
  // (Libraries the settings name are loaded already, by HSApplication.)
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSString *type = OISStoreType([self setting:@"StoreType"] ?: @"InMemory");
  OISLoadBackendFor(type);
  NSURL *storeURL = OISURL([self setting:@"StoreURL"]);
  NSError *failure = nil;
  if (![coordinator addPersistentStoreWithType:type configuration:nil URL:storeURL options:[self setting:@"StoreOptions"] error:&failure]) {
    OISFailWith(error, [NSString stringWithFormat:@"the %@ store at %@ does not open: %@", type, storeURL ?: @"(none)", failure.localizedDescription]);
    return nil;
  }

  NSURL *root = OISURL([self setting:@"ServiceRoot"])
      ?: [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%lu/odata/", (unsigned long)self.port]];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator serviceRoot:root];
  if ([self setting:@"Namespace"]) service.namespaceName = [self setting:@"Namespace"];
  if ([self setting:@"Container"]) service.containerName = [self setting:@"Container"];
  if ([self setting:@"MaxVersion"]) service.maxVersion = [self setting:@"MaxVersion"];
  // What one request may ask (ODataService.h): each a number, 0 for none.
  if ([self setting:@"MaxPageSize"]) service.maxPageSize = (NSUInteger)[self number:@"MaxPageSize" otherwise:0];
  if ([self setting:@"MaxURLLength"]) service.maxURLLength = (NSUInteger)[self number:@"MaxURLLength" otherwise:0];
  if ([self setting:@"MaxExpandDepth"]) service.maxExpandDepth = (NSUInteger)[self number:@"MaxExpandDepth" otherwise:0];
  if ([self setting:@"MaxBatchRequests"]) service.maxBatchRequests = (NSUInteger)[self number:@"MaxBatchRequests" otherwise:0];
  if ([self setting:@"MaxRowsInMemory"]) service.maxRowsInMemory = (NSUInteger)[self number:@"MaxRowsInMemory" otherwise:0];
  if ([self setting:@"MaxJSONDepth"]) service.maxJSONDepth = (NSUInteger)[self number:@"MaxJSONDepth" otherwise:0];
  if ([self setting:@"MaxAsyncRequests"]) service.maxAsyncRequests = (NSUInteger)[self number:@"MaxAsyncRequests" otherwise:0];
  if ([self setting:@"ReplyTimeout"]) service.replyTimeout = [self number:@"ReplyTimeout" otherwise:0];
  if ([self setting:@"AsyncResultDuration"]) service.asyncResultDuration = [self number:@"AsyncResultDuration" otherwise:0];
  if ([self setting:@"RepeatabilityDuration"]) service.repeatabilityDuration = [self number:@"RepeatabilityDuration" otherwise:0];
  if ([self setting:@"RepeatabilityMemory"]) service.repeatabilityMemory = (NSUInteger)[self number:@"RepeatabilityMemory" otherwise:0];
  if ([self setting:@"HistoryRetention"]) service.historyRetention = [self number:@"HistoryRetention" otherwise:0];
  if ([self setting:@"AllowAnonymous"]) service.allowsAnonymousRequests = [self flag:@"AllowAnonymous" otherwise:NO];
  return service;
}

@end

#pragma mark - The application

@interface ODataServerApplication ()
@property (nonatomic, readwrite, strong, nullable) ODataService *service;
@end

@implementation ODataServerApplication

+ (Class)configurationClass
{
  return [ODataServerConfiguration class];
}

- (void)configureService:(ODataService *)service
{
}

- (BOOL)prepare:(NSError **)error
{
  if (self.server) return YES;
  if (!self.service) {
    HSConfiguration *configuration = self.configuration;
    if (![configuration isKindOfClass:[ODataServerConfiguration class]]) {
      // Made with an HSConfiguration: the same settings, read as ois-serve's.
      configuration = [[ODataServerConfiguration alloc] initWithSettings:configuration.settings];
    }
    ODataService *service = [(ODataServerConfiguration *)configuration serviceWithError:error];
    if (!service) return NO;
    self.service = service;
    [self configureService:service];
    for (Class configurer in self.bundleClasses) {
      if ([configurer conformsToProtocol:@protocol(ODataServiceConfiguring)]) [(id<ODataServiceConfiguring>)configurer configureService:service];
    }
  }
  return [super prepare:error];
}

- (void)configureModules:(NSMutableArray<id<HSModule>> *)modules
{
  [super configureModules:modules];
  if (self.service) [modules addObject:[[ODataServiceModule alloc] initWithService:self.service]];
}

- (int)run
{
  NSString *name = [NSProcessInfo processInfo].processName;
  ODataServerConfiguration *configuration = (ODataServerConfiguration *)self.configuration;
  if ([configuration isKindOfClass:[ODataServerConfiguration class]] && configuration.printsMetadata) {
    NSError *error = nil;
    if (![self prepare:&error]) {
      fprintf(stderr, "%s: %s\n", name.UTF8String, error.localizedDescription.UTF8String);
      return 1;
    }
    printf("%s\n", [self.service metadataXMLForVersion:self.service.maxVersion].UTF8String);
    return 0;
  }
  NSError *error = nil;
  if ([self prepare:&error]) {
    for (NSString *problem in self.service.metadataProblems) fprintf(stderr, "%s: $metadata: %s\n", name.UTF8String, problem.UTF8String);
  }
  return [super run];
}

@end

@implementation HSServer (ODataService)

- (instancetype)initWithService:(ODataService *)service
{
  HSRouter *router = [[HSRouter alloc] init];
  NSString *root = service.serviceRoot.path.length ? service.serviceRoot.path : @"/";
  [router addRoute:[HSRoute routeWithMethod:nil path:[root stringByAppendingPathComponent:@"*"]
                                    handler:[[ODataServiceHandler alloc] initWithService:service]]];
  return [self initWithHandler:router];
}

@end
