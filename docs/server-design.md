# OData server: design

**Status: milestones 1 to 7 are implemented** (see Milestones): the core
(`ODataService`, `ODataEntitySetHandler`, `ODataReply`), `$metadata` from
the model (`ODataMetadataWriter`), `$filter` to `NSPredicate`
(`ODataPredicateBuilder`), the HTTP server (`HTTPServerKit`) with
`ois-serve` (`Server/`),
operations declared in protocols (`ODataOperationCatalog`), and `$batch`
(`ODataServiceBatch`); and the Workbench's built-in service is this server
(milestone 7). Where the code went differently from the plan, the sections
below say so.

ODataIncrementalStore is a client: Core Data on one side, a remote OData v4
service on the other. The server is the same mapping run the other way: an
OData v4 service whose entity sets are a Core Data model, written in
Objective-C, built on modern GNUstep (clang, libobjc2, gnustep-base,
FreeCoreData) and on Cocoa, with no platform-specific code in its core.

## Goals

- Let an application serve its Core Data model as an OData 4.01 API
  (answering 4.0 clients too), with little code of its own. The workflow:
  1. Design the model in FreeCoreData's Model Builder (or Xcode).
  2. Add the OData mappings: set names, wire names, keys, vocabulary
     annotations. They go in `userInfo`, which Model Builder already edits.
  3. Implement the actions and functions.
  4. Where the default is not enough, override what an entity set does:
     get by key, fetch by predicate, insert, update, delete.
  5. Run it as a service behind a reverse proxy.
- Serve over OData JSON: the service document, `$metadata`, entity sets,
  single entities, navigation, create, update and delete, and
  operations.
- Any Core Data store behind it: SQLite, in-memory, and FreeCoreData's
  PostgreSQL and MySQL/MariaDB backends. Those are `NSIncrementalStore`s
  that register their own store type, so the service needs no code for
  them; the store type and URL are configuration.
- Cover at least everything the client sends. The client is the first
  consumer, and the snapshots in `Tests/Snapshots/` are the first
  specification.
- One core for both platforms, testable with no sockets.
- An embedded HTTP listener for development, tests and production behind
  the proxy. The proxy owns TLS, HTTP/2, compression, rate limiting and,
  at first, authentication. The listener binds to loopback by default.
- Runs as an OS service: a systemd unit on Linux, a launchd job on macOS.
  It logs to standard error and stops cleanly on `SIGTERM`.

## Non-goals, at first

- None left of those first listed: `$batch`, `$apply`, `$search`,
  streams, media entities, delta links and asynchronous requests are
  done.
- XML (Atom) payloads. JSON only, as the client speaks.
- Being a general-purpose web framework.

## Architecture

```
            reverse proxy (TLS, auth, limits)
                        │ HTTP/1.1
┌───────────────────────▼──────────────────────────┐
│ HTTP adapter          vendored GCDWebServer      │  thin, replaceable
├──────────────────────────────────────────────────┤
│ ODataService          request → response         │  no sockets
│   router  ·  query options  ·  serializer        │
├──────────────────────────────────────────────────┤
│ ODataEntitySetHandler  one per set               │  the default: Core Data;
│   fetch · by key · count · insert · update · del │  subclass to change it
├──────────────────────────────────────────────────┤
│ shared with the client                           │
│   ODataPropertyMapper · ODataResourceIdentifier  │
│   literals · $filter grammar · CSDL              │
└──────────────────────────────────────────────────┘
```

### The core takes a request and returns a response

`ODataService` takes an `NSURLRequest` (method, URL, headers, body) and
answers with a status, headers and body. It never sees a socket. It is an
`ODataTransport`: it takes an `ODataExchange`, fills in the response and
finishes it, target-action, as every transport does; an in-memory service
finishes before returning. So a service can be handed to
`ODataIncrementalStore` as its transport:

```objc
ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator
                                                                     serviceRoot:root];
// A Core Data store talking to a Core Data store through OData, in-process.
options = @{ ODataIncrementalStoreTransportOption: service };
```

This gives a full round-trip test with no network on both platforms
(`-[ODataServiceTests testIncrementalStoreOverTheService]`). It is also
what the Workbench's built-in service is: `WorkbenchEngine` wraps an
`ODataService` over the Catalog model in an in-memory Core Data store,
seeded with Northwind's rows, logs each exchange, and declares a few
operations of its own. It replaced a hand-written, dictionary-backed
prototype of this core, about 900 lines.

### Handlers, not a data source

The plan had an `ODataDataSource` protocol under the service, with a Core
Data implementation, and handlers on top. In the code the handler is the
only seam: `ODataEntitySetHandler`'s default methods are the Core Data
implementation, and a set that is not Core Data would be a handler that
overrides all of them. One layer fewer, and nothing lost.

Each request gets its own private-queue context on the service's
coordinator, and all work runs inside `-performBlockAndWait:`, or
`-performBlock:` once a reply is deferred. On GNUstep that depends on
libdispatch having been built before gnustep-base, which
`build-gnustep.sh` in gnustep-patches already guarantees and verifies.

### What an application writes

The defaults serve the model as it is. An application adds to them in
two places, entity sets and operations, and both answer through a reply
(below). Neither needs a subclass of the service.

**Entity sets.** Each set is handled by an `ODataEntitySetHandler`. The
default one does everything over the data source:

| Method | Default |
|---|---|
| get by key | a fetch on the key attributes and the visible rows, limit 1 |
| fetch | the request's predicate, sort, limit, offset and prefetching |
| count | `countForFetchRequest:` |
| insert | a new object from the body's values; a missing integer key is one more than the largest, a string or UUID key a new UUID |
| update | the body's values set on the object (`If-Match` is checked first) |
| delete | `-deleteObject:` (`If-Match` is checked first) |

The service converts the body before a handler sees it: values arrive
keyed by Core Data property name, as Core Data values, with
`@odata.bind` resolved to managed objects. It saves after the handler
answers, and turns a failed validation into a `400` with a detail for each
property.

- A subclass overrides any of these for one set and is registered by
  set name (`-setHandler:forEntitySet:`). Typical uses:
  - fetch: add a predicate that scopes rows to the caller;
  - insert: fill in server-side values;
  - delete: refuse, or mark as deleted instead.
- `allowsInsert`, `allowsUpdate` and `allowsDelete` switch a method off;
  it then answers `405`, and `$metadata` says so on the set
  (`Capabilities.InsertRestrictions` and its siblings), as the handler
  allows at the time of the request.
- `readScopes`, `insertScopes`, `updateScopes` and `deleteScopes` are the
  permissions a method needs, as OAuth scopes the caller's principal
  carries (its token's `scope` or `scp`), any one of them enough: a
  permission names what it allows, and which people hold it is the
  identity provider's to say, so it outlasts a reorganization that roles
  would not. What a request needs is worked out from its plan, before
  anything runs (the plan's `permissions`, which `$explain` prints):
  - a read needs the read scopes of every set it reaches -- along its
    path, and through `$expand`, `$filter` (lambdas, `$count` of a
    navigation, a path's `$filter(…)`), `$orderby`, `$compute` and
    `$apply`, since a filter on `Category/CategoryName` reads categories
    as surely as expanding them does;
  - a write needs the scope of each row it makes, changes or deletes:
    deep inserts and updates row by row, an open type's dynamic properties
    with the rest, a `$ref` as an update of the row whose navigation
    property it is, a temporal action slice by slice. Its path reads the
    sets it passes through, not the one it writes. A Merge's branch and a
    temporal action's slices are known only once read, so they are checked
    then -- with the rest, in the check pass, before the first write;
  - what a write answers with is what it wrote, and an operation's result
    is the operation's: neither needs reading. What else the answer reads
    does: a client's `$expand`, checked before the write or the call. The
    nested entities a deep write expands unasked are left out where the
    caller may not read them, since the expansion holds every member, not
    only those written;
  - an operation names its own in `+ODataOperationScopes`; a bound one's
    path is read. Scopes that name no scope, or name no operation, are
    `operationProblems`, since either would leave an operation open.

  A caller without a permission is answered `403` (`401` when no one
  asks), with `WWW-Authenticate: Bearer error="insufficient_scope",
  scope="…"` (RFC 6750 section 3.1); the client reads the scopes back into
  `ODataErrorScopesKey`, with a recovery suggestion. `$metadata` says them,
  as the Capabilities vocabulary has it: each set's `ReadRestrictions` and
  its siblings, and each operation overload's `OperationRestrictions`,
  carry `Permissions` under the authenticator's security scheme, so a
  client knows which scopes to ask its provider for. That decides what a
  caller may do; which rows it sees is the next item's.
- `-predicateForVisibleObjectsInRequest:` scopes the rows the caller may
  see however they are reached: fetched, by key, through navigation,
  through `$expand`, or named in `@odata.bind`. That is where per-caller
  rows belong, rather than in an overridden fetch, which `$expand` would
  go around.
- Each method runs inside the request's context's
  `-performBlockAndWait:`. It gets the parsed request, never the raw
  URL, so it cannot get the grammar wrong, and answers through its
  reply.

**Operations.** Objective-C has no annotations, and Core Data models
cannot declare operations. Protocols take their place: an application
declares its operations in a protocol and implements them as ordinary
methods. The framework reads the protocols at startup, then does the
rest:

- writes the operations into `$metadata`;
- routes a GET or a POST to the right selector;
- decodes the parameters with the value coder the client uses;
- calls the method through `NSInvocation`;
- encodes the result, or the error.

The application never touches the protocol itself. `NSXPCConnection`
works the same way, with a protocol as the whole contract for remote
calls.

```objc
@protocol PersonActions <ODataActions>
- (void)shareTripWithUserName:(NSString *)userName tripId:(int32_t)tripId reply:(ODataReply *)reply;
@end

@protocol PersonFunctions <ODataFunctions>
- (Airline *)getFavoriteAirline:(ODataReply *)reply;
+ (NSArray *)peopleNearAirport:(Airport *)airport reply:(ODataReply *)reply;
@end

@interface Person : NSManagedObject <PersonActions, PersonFunctions>
@end

@implementation Person
- (Airline *)getFavoriteAirline:(ODataReply *)reply
{
  return self.trips.lastObject.airline;
}
…
@end
```

This works because clang records extended type encodings for a
protocol's methods. They name each object parameter's class and
protocols, where a class's own methods record only `@`:

```
getFavoriteAirline:              @"Airline" … @
discountBy:forItems:tag:reply:   d … d @"NSArray" @"<Marker>" @
+countOlderThan:reply:           i … q @
```

Both runtimes give these the same, through `_protocol_getMethodTypeEncoding`;
this was checked on Apple's runtime and on libobjc2. Every fact about an
operation comes from something the language already has:

| OData needs | Read from |
|---|---|
| operation and parameter names | the selector. `shareTripWithUserName:tripId:reply:` is `ShareTrip(UserName, TripId)`: the first keyword up to `With` names the operation, the rest the first parameter. Without `With`, the whole keyword names the operation and its last word the parameter: `pricierThanPrice:reply:` is `PricierThanPrice(Price)`. Named by `ODataPropertyMapper`'s rules, as properties are. |
| parameter and return types | the extended encoding: `int32_t` is `Edm.Int32`, `int64_t` `Edm.Int64`, `double` `Edm.Double`, `BOOL` `Edm.Boolean`, `NSString *` `Edm.String`, `NSDate *` `Edm.DateTimeOffset`, `NSDecimalNumber *` `Edm.Decimal`, `NSUUID *` `Edm.Guid`, `NSData *` `Edm.Binary`, `NSDictionary *` `Edm.Untyped`, a managed object class its entity type |
| function or action | the protocol it inherits from: `<ODataFunctions>` or `<ODataActions>` |
| binding | an instance method of an entity's class is bound to the entity; a class method (`+`) is bound to its collection; a method of the service's `serviceOperations` object is unbound, reached through an import. Only protocols a class adopts itself count. |
| nullability | a scalar is non-nullable; an object is nullable |

The runtime cannot see two things. Generics are erased, so
`NSArray<Person *> *` reads as `NSArray`. And an `NSNumber *` parameter,
which is how a nullable number is written, says nothing about which
number type it is. A class method supplies the rest, and renames what
the conventions get wrong:

```objc
+ (NSDictionary<NSString *, NSString *> *)ODataOperationTypes
{
  return @{ @"peopleNearAirport:reply:": @"Collection(Microsoft.OData.SampleService.Models.TripPin.Person)",
            @"shareTripWithUserName:tripId:reply:.tripId": @"Edm.Int32" };
}

+ (NSDictionary<NSString *, NSString *> *)ODataOperationNames
{
  return @{ @"namesInCategory:": @"ProductNames" };
}
```

Some values have no type of the model's: a document an application keeps
as it is, or a set of named values of any types. An `Edm.Untyped`
parameter or result (or `Org.OData.JSON.V1.JSON`, which `$metadata` then
references the JSON vocabulary for) is any JSON: the method is given it
as `NSJSONSerialization` reads it, and what it returns is written as
`NSJSONSerialization` writes it. A dictionary is one without being
declared; an `id` or `NSArray *` parameter is declared so, and a
collection of them `Collection(Edm.Untyped)`. `Edm.Untyped` is CSDL
4.01's: the `$metadata` a 4.0 client is sent says
`Org.OData.JSON.V1.JSON` in its place.

The keys are selectors as written, a parameter after a dot by the name
the rules give it. A declaration the framework cannot type is listed in
`operationProblems`, naming the selector and the key that would fix it,
and left out of `$metadata`; `ois-serve` refuses to start with any. So a
mistake shows at startup, not at the first call.
`ois-model --classes` already gives the client the same methods
(`-[Person getFavoriteAirline:]`); it will also write these protocols
from `$metadata`, so client and server can share one. Declarations in
CSDL, generating the protocol, can come later on top of this. The
protocol stays what the framework reads.

As built:

- **Arguments.** A function's come from the URL: literals, parameter
  aliases, and aliases whose value is JSON (`SumOfPrices(Prices=@p)?@p=[1.5,2.25]`),
  which is how the client passes complex values and collections. An
  action's come from its JSON body. Entities are passed by reference
  (`{"@odata.id": "Products(1)"}`). A missing number, an unknown
  parameter, or a value of the wrong type is a `400`.
- **The call.** Through `NSInvocation`, inside the request's context. The
  reply's `request` gives the method the context; for an operation bound
  to a collection, `request.collectionFetchRequest` is the collection:
  `Categories(1)/Products/Default.PricierThanPrice(Price=18)` sees the
  category's products only.
- **After it.** An action's changes are saved, as a write's are; a
  function's are rolled back. The result is written by its declared type:
  an entity with `$select` and `$expand` applied, a collection of them, a
  value or a collection of values, each with its context URL; nothing is
  a `204`.
- **Composing.** Functions are composable: the entities one returns are
  read on as any collection or entity, the rest of the path and the query
  options included (`Products/Default.PricierThanPrice(Price=10)?$filter=…&$top=2`,
  `…/$count`, `Products(4)/Default.CheapestInCategory()/Category`). An
  action's result, and a value, cannot be read on from (`400`).
- libobjc2's `Protocol` objects cannot be retained, so the catalog keeps
  them as pointers; Apple's can.
- The client calls these operations as it calls any service's
  (`-invokeODataOperation:parameters:error:`, `ODataOperationCall`), in
  `ODataServiceTests testClientCallsOperations`.

**Replies.** Every operation and every entity-set handler method takes
an `ODataReply` as its last parameter. The framework is the method's
only caller, and the reply is its end of the call. There are two ways to
answer:

- **At once.** Return the result. A method that fails calls
  `[reply failWithError:]` and returns. Most methods look like this, and
  never think about asynchrony.
- **Later.** Call `[reply defer]`, start the work, and return; whatever
  the method returns is then ignored. When the work ends, possibly on
  another thread, call `[reply finishWithResult:]` or
  `[reply failWithError:]`. Work that waits on something else is the
  reason for this: a payment provider, another service, a long query.

So only the code that actually waits is asynchronous, and there are no
blocks in the API. A deferred method runs its synchronous part inside
the request context's `-performBlockAndWait:` like any other. Whatever
it does with the context afterwards goes through `-performBlock:`. The
reply keeps the context alive until it is finished. A deferred reply that
is not answered within the service's `replyTimeout` (60 seconds by
default) is answered `504`, and a later answer is ignored.

The service's own steps continue through the same replies, target-action,
with no blocks: each step names the method its reply goes on in.

### Running it

`ois-serve` (`Server/ois-serve.m`) reads its settings from the property
list `-Config` names, and any of them from the command line, which wins
(`-Port 9000`): `Model`, `StoreType` (`SQLite`, `InMemory`, `XML`, or a
type a backend registers, such as `CDPostgreSQLStore`), `StoreURL`,
`StoreOptions`, `ServiceRoot` (the public URL, which `@odata.context` and
next links begin with), `Port`, `Localhost`, `MaxPageSize`, `MaxVersion`,
`Namespace`, `Container`, and `Bundles`; and the limits below
(`MaxBodySize`, `MaxURLLength`, `MaxExpandDepth`, `MaxBatchRequests`,
`MaxRowsInMemory`, `MaxJSONDepth`, `MaxAsyncRequests`, `ReplyTimeout`,
`AsyncResultDuration`, `RepeatabilityDuration`). A bundle's principal class that
conforms to `ODataServiceConfiguring` is sent `+configureService:` before
the first request: that is where an application registers its handlers.
`-PrintMetadata YES` prints `$metadata` and exits.

It serves until `SIGINT` or `SIGTERM`, logs a line per request to standard
error (`AccessLog`), answers `GET /health` (`HealthPath`), and exits 0.
`Server/Examples/` has a configuration for the Catalog model, a systemd
unit, a launchd job, nginx and Caddy configurations, and `CatalogServer.m`,
an application of its own.

### An application of its own

The server is two layers. `HTTPServerKit` is an HTTP server for any API:
the listener, the pipeline and router, sign-in, observability, and the
application that makes them from its settings (`HSApplication`), with no
OData in it; an API is a module (`HSModule`) that adds its routes, stages
and checks to the application. `ODataService` is one such API, OData the
first of them (OpenAPI is to come): `<ODataService/ODataServer.h>` has the
service mounted (`ODataServiceHandler`), as a module
(`ODataServiceModule`), and the application `ois-serve` is
(`ODataServerApplication`, which makes the service from the settings).

`ois-serve` is one call, `HSMain(argc, argv, [ODataServerApplication
class])`. An application with routes or stages of its own subclasses
`ODataServerApplication` (or `HSApplication`, with no OData service, or
with modules of its own), overrides what it needs, and makes the same call
with its class:

```objc
@implementation CatalogServer
- (void)configureService:(ODataService *)service { ... handlers ... }
- (void)configureRouter:(HSRouter *)router
{
  [router insertRoute:[HSRoute routeWithMethod:@"POST" path:@"/webhooks/billing"
                                                handler:[[BillingWebhook alloc] init]] atIndex:0];
}
- (void)configurePipeline:(HSPipeline *)pipeline
{
  [pipeline insertStage:[[TenantStage alloc] init] afterStageOfClass:[HSAuthenticationStage class]];
}
@end

int main(int argc, const char *argv[]) { return HSMain(argc, argv, [CatalogServer class]); }
```

The settings are `ois-serve`'s, read by `ODataServerConfiguration` (the
service's on top of `HSConfiguration`'s), and a bundle whose principal
class is such a subclass is the application too, for `ois-serve -Bundles`
without a `main` of one's own.

Errors are answered in the format of the route that took the request: a
handler that conforms to `HSErrorFormatting` formats its route's (the
mounted service answers OData's `{"error": {...}}`), and every other route,
or a request no route took, is answered `application/problem+json` (RFC
9457: `type`, `title`, `status`, `detail`). The routing stage runs first,
so a refusal by any stage after it (sign-in, CORS, limits) is already in
its route's format.

Everything is an object, and the pipeline is built from objects, not
blocks or conventions:

- An `HSHandler` answers a request: an application's endpoint, the
  service mounted (`ODataServiceHandler`), the router, a pipeline. Any of
  them can stand where another does; a route's handler can be a pipeline of
  its own.
- An `HSStage` is a step every request through a pipeline takes:
  `-shouldPassRequest:reply:` on the way in (answer and return `NO` to stop
  the request there), `-request:willSendResponse:` on the way back, or
  `-handleRequest:reply:next:` for a stage that has to wait (the
  authentication stage) or wrap what follows.
- An `HSPipeline` is an array of stages, to read, reorder or
  replace (`insertStage:beforeStageOfClass:`, `replaceStageOfClass:withStage:`),
  then a handler. Its `-description` lists them.
- An `HSRouter` is an ordered array of `HSRoute`s
  (`/orders/:id`, `/odata/*`), the first that matches answering: 405 with
  `Allow` for a path no route takes this method on, 404 for none. A route
  can require someone signed in (`requiresPrincipal`) or one of some OAuth
  `scopes`, answered as the service answers its own (401, 403 with the
  challenge naming them).

What `-prepare:` makes, each handed to its `-configure` method before the
next: the authenticator (and, for `ODataServerApplication`, the service);
the router (`/health`, `/ready`, `/metrics`, then each module's routes:
the service at its root's path); the pipeline (`HSRoutingStage`,
`HSRequestIDStage`, the trace context, metrics, `HSAccessLogStage`, CORS,
compression, `HSAuthenticationStage` when there is an authenticator, then
the router); the listener.

A request's life through the pipeline: each stage's way in, in order; the
handler finishes the reply, now or later, on whatever thread its work
finished on; finishing it is when the response exists, and in that same
call each stage it passed through sees it on the way back, last first, and
may still change it; then the listener writes it. No thread is started
for any of it, and the way back must not wait. A stage that answered
early sees its own answer; stages after it never ran.

The stages the settings add, besides request ids and the access log:

- `HSCORSStage` (`CORSOrigins`, `CORSCredentials`): browsers on other
  origins. A preflight is answered before authentication (403 for an
  origin not allowed); other responses to an allowed origin carry
  `Access-Control-Allow-Origin` (the origin itself, with `Vary: Origin`,
  unless any may read it without credentials) and expose OData's headers.
- `HSCompressionStage` (`Compression`, on by default): gzip for a client
  that takes it, of a JSON, XML or text body of at least 1 KiB, only when
  it comes out smaller, with `Vary: Accept-Encoding` either way and a
  strong ETag made weak. After-hooks run last first, so the access log
  sees what went out.

Bodies need not be in memory. A request body over `MaxBodyInMemory`
(default 1 MiB), or a chunked one, is written to a temporary file as it
arrives: `HSRequest`'s `bodyFileURL`, which `body` maps when asked
(the service reads it so). A response can be a file (`bodyFileURL`, sent
from disk) or an `HSResponseStream`, asked for its next piece as
it is sent, chunked.

Settings come from a property list (`-Config`, or `OIS_CONFIG`), then the
environment (`OIS_PORT`, `OIS_MAX_PAGE_SIZE`, `OIS_JWT_ISSUER`: each
setting's name in capitals, words apart; JSON for a dictionary or list),
then the command line, a later one winning, as a container is configured.
An application's own settings come the same way (`OIS_REPORT_TITLE` is
`ReportTitle`). `OIS_` is `ODataServerConfiguration`'s prefix; an
`HSApplication` with no OData service reads `HS_` unless its configuration
class says otherwise (`+environmentPrefix`). A store backend is a library that registers its store type
when loaded: `Libraries` loads any before the store is opened, and a
`StoreType` nothing has registered is looked for as `lib<StoreType>`, so
`-StoreType CDPostgreSQLStore` is all FreeCoreData's PostgreSQL store needs
where it is installed.

### Observability

What operators expect of a server today, as stages and handlers like the
rest; [observability.md](observability.md) has the whole of it:

- **Logs.** The access log, and everything else the server and the service
  say (`HSLog`), as text or JSON lines, each with the request id, trace id
  and span id of the request it is about.
- **Metrics,** in Prometheus's text format (`HSMetrics`, which an
  application adds its own to): requests by method, route pattern and
  status; sign-in refusals by reason, and the identity provider's answers
  and their times; the service's planning, execution and store requests
  by entity; the process's start time, resident memory and build. Labels
  are route patterns, operations and entities, never paths, so a client
  cannot make up new series.
- **Traces.** W3C `traceparent` is taken when well formed (a new trace
  begun when not), and each request is a span under it, the service's
  plan, execution and store requests spans under that, exported over
  OTLP/HTTP when an endpoint is named (`OTLPEndpoint`, or OpenTelemetry's
  `OTEL_` variables). OTelKit, the library that makes and sends them, is
  Foundation only, so a store underneath (FreeCoreData) can trace into the
  same spans without linking it.
- **Liveness and readiness.** `/health` says the process runs; `/ready`
  says whether to send it requests: 503 while it drains, or when one of its
  checks fails or does not answer within five seconds
  (`HSReadinessCheck`; a mounted service's store is one).
- **Draining.** `SIGTERM` (or `SIGINT`) makes the server not ready, waits
  `DrainDelay` for a load balancer to notice, stops accepting, gives the
  requests under way `ShutdownTimeout` to finish, and sends its last
  spans; a second signal exits at once.
- **An admin listener.** With `AdminPort`, metrics leave the public
  listener for one of their own (loopback unless `AdminLocalhost NO`), with
  health and readiness on both.

One sign-in serves every route: sign-in is the host's
(`<HTTPServerKit/HSAuthentication.h>`: trusted proxy headers, JWTs,
token introspection, or an `HSAuthenticator` of one's own), the
authentication stage asks the authenticator once, and the mounted service
is handed who it found
(`-startExchange:principal:`), applying `allowsAnonymousRequests` and
`allowsAnonymousMetadata` as it would to its own authenticator's answer.
Whether no one is let in is each route's to say.

### Limits

No request, careless or hostile, should take more than its share. Each
limit is answered with an error that says what it was, and each is a
property of the service (0: none), so an in-process service has them as
`ois-serve` does:

| What | Default | Answer |
|---|---|---|
| Body size (the HTTP adapter's `maxBodySize`) | 64 MiB | 413 |
| URL length (`maxURLLength`) | 8192 characters | 414 |
| `$expand` depth, `$levels` counted (`maxExpandDepth`); `$levels=max` is bounded by the service | 8 | 400 |
| Requests in a `$batch` (`maxBatchRequests`) | 100 | 400 |
| Rows worked on in memory: `$apply` beyond filters, `$orderby` by a computed value, a temporal action (`maxRowsInMemory`) | 10000 | 400: narrow it with `$filter` |
| JSON body nesting, counted before it is parsed (`maxJSONDepth`) | 64 | 400 |
| Nesting in `$filter`, `$search` and `$expand`: parentheses, `not`, minus | 100 | 400 |
| Asynchronous requests kept (`maxAsyncRequests`) | 1000 | answered at once |
| A deferred reply (`replyTimeout`) | 60 s | 504 |
| Repeatable requests remembered | 10000, and `repeatabilityDuration` | the oldest forgotten |

A failure of the store itself (anything but an OData error or a
validation error) is answered 500 with "The service could not answer the
request", and logged: its own message may name files or say more of the
service than a client should know.

`$schemaversion` names the schema a request is made against (Part 1,
11.2.12): `*` or the service's `modelVersion` (which `$metadata` says, as
`Core.SchemaVersion`) is its own; another is `404`, unless the service
reads it (`upgradeBody`, which then has each write's body made the
service's), and a `$batch`'s requests have the batch's. `$index` (a position in an ordered collection) is `501`: Core
Data's to-many relationships here are not ordered.

### The HTTP adapter

This is the only part that touches sockets, and it should stay small
enough to replace. Its whole job is to turn bytes into an
`HSRequest`, hand it to its handler (the pipeline), and write the
response back; the stages, routes and handlers never see the listener's
own types.

**Choice: GCDWebServer 3.5.4, vendored and ported.** Four candidates
were compared: the three first proposed, plus GCDWebServer, the project
OCFWebServer was forked from. All four were read, and the two GCD-based
ones were syntax-checked against gnustep-base (libobjc2, ARC):

| | GCDWebServer | OCFWebServer | Barista | ohttpd (CGIKit) |
|---|---|---|---|---|
| License | BSD-3 | BSD-3 | MIT | none ("All rights reserved") |
| Last change | 2020 (3.5.4) | 2013 | 2013 | 2013 |
| Size | 4.3K lines | 2.4K | 2.7K + 7.4K GCDAsyncSocket | 10K |
| I/O | GCD `dispatch_source`, `dispatch_io`, BSD sockets | the same (a 2013 fork of GCDWebServer) | GCDAsyncSocket (CFStream) | GCDAsyncSocket |
| HTTP parsing | `CFHTTPMessage` | `CFHTTPMessage` | `CFHTTPMessage`, whole message buffered | its own |
| IPv6 | yes | no | via the socket | via the socket |
| Chunked request bodies | yes | no | no | no |
| Streamed responses | yes | no | no | no |
| Keep-alive | no, `Connection: close` | no | no | no |
| Dependencies | none | none | JLRoutes, GRMustache (CocoaPods) | none |
| On GNUstep | 81 errors, nearly all `CFHTTPMessage`/`CFURL`/`CFUUID` | 154 errors: the same, plus IPv4-only BSD socket code (`sin_len`, `SO_NOSIGPIPE`) | CFStream under GCDAsyncSocket | not usable: no license |

OCFWebServer is on the list only as the fork: upstream kept going for
seven more years and fixed what matters here. Behind a proxy, chunked
request bodies matter because Caddy streams them; nginx buffers and
sends a length. Barista is a Sinatra-style framework over a large
socket library; the framework is the part we would throw away.

The port, kept as a patch over the pinned release so updates stay
possible:

- Replace `CFHTTPMessage` with a small request-head parser and
  response-head writer (request line, headers, `100-continue`). This is
  the bulk of the work, and the part the tests cover hardest.
- Replace `CFURL`/`CFUUID` with `NSURL`/`NSUUID`, and `st_mtimespec`
  with `st_mtim` on Linux.
- Drop Bonjour, NAT port mapping, digest authentication and iOS
  background suspension. Authentication belongs to the proxy or to the
  application's handlers.
- Add a size limit on request heads and bodies, and a read timeout.
- Keep-alive came later, for proxies that pool upstream connections
  (Caddy; nginx with `keepalive` and HTTP/1.1 upstreams): a connection is
  kept for its next request (`KeepAliveTimeout`, default 5 s, and
  `MaxRequestsPerConnection`, default 100) whenever that is safe, and
  closed otherwise (`PORTING.md`).

It lives in `ThirdParty/GCDWebServer/` with its license; `PORTING.md`
there lists every change, and `upstream.diff` reapplies them to the
pristine release. It is built into `libHTTPServerKit` (`Source/HTTPServerKit/`) only,
with `HSServer`, which turns each request into an
`HSRequest` for its handler and the finished reply back into a
response. The
listener's own smoke test and `Server/Tests/ois-serve-check.m` run in CI on
both platforms.

Two things surfaced on the way. GCDWebServer's handler blocks capture a
block in another block, which libobjc2 leaked until
`libobjc2/stack-block-retain` in gnustep-patches; the port copies its
blocks itself, so it does not depend on the fix. And gnustep-base leaves
fast enumeration to `NSDictionary`'s subclasses, so the port's header
dictionary implements it.

### Measures, JSON values and repeatable requests

- `userInfo` `OData.unit`, `OData.scale` and `OData.isoCurrency` (a code,
  or the name of the attribute holding one, written as a path) are the
  Measures terms of the property.
- An attribute declared `OData.type` `Org.OData.JSON.V1.JSON` holds any
  JSON value, a Transformable one as it is and a String one as its text;
  payloads carry the value inline, and `$metadata` references the JSON
  vocabulary.
- Repeatable requests: a top-level request that changes something and
  carries `Repeatability-Request-ID` (with `Repeatability-Client-ID`, if
  any) and `Repeatability-First-Sent` is answered once; the answer is
  remembered `repeatabilityDuration` (an hour; 0 turns it off) and given
  again, `Repeatability-Result: accepted`, to the same request, told by
  its method, URL and a hash of its body. A request first sent longer ago,
  an ID given to another request (`400`), or one still being answered
  (`409`) is `rejected`. A `5xx` answer is not remembered, so the request
  may be tried again. The container says `Repeatability.Supported`.

### `$metadata` in JSON

`$metadata?$format=json`, or an `Accept` that names `application/json`
and not XML, is answered in CSDL JSON (4.01): `ODataCSDL`, in ODataKit,
turns the CSDL XML the writer makes into it, and turns CSDL JSON back
into XML for the client's schema reader. The two defaults that differ are
kept: `$Nullable` is false when absent in JSON, true in XML, and `$Type`
is `Edm.String`.

### Reads are planned

Every read is planned before it runs, as a database plans a query
(`docs/query-plan.md`): the parsed request becomes a tree in a nested
relational algebra (Scan, Select, Sort, Limit, `$apply`'s
transformations, Nest for `$expand`, Closure for a recursive hierarchy,
Bind for a `$these` a store filter uses); rewriting it puts filters,
orders, pages, counts and the first grouping into store operators, which
reach the store through the set's handler, expansions and hierarchies
included; the rest runs here. With `ODataService.explains`,
`GET <root>/$explain/<resource path>?<query>` answers with the logical
and the physical plan instead of the rows (not standard OData);
`logsPlans` logs each read's.

### Writes are planned

Every write is planned too (`docs/write-plan.md`), as databases plan DML:
Lookups (of `@odata.bind`, `$ref`, a nested entity's `@id` or key),
Sequences (a new integer key: the largest read once, then counted on),
Insert, Update, Delete, Link and Unlink, Merge (a deep update's nested
entity: an Update of the one it names, else an Insert), Temporal, and
Commit (the save), with the read of what the write answers with. It runs
in phases: every read, through the handlers; every check (If-Match, a
nested `@odata.etag`, the key and what is immutable unchanged, what the
set allows); then the writes, through the handlers, the ones a write
depends on first; then the save. So a request that fails a check asks no
handler to write anything. A handler that answers later stops the plan
until it answers; it goes on from the top, and nothing asked is asked
again. With `explains`, `POST`, `PATCH`, `PUT` and `DELETE` on
`$explain/…` answer with the plan and write nothing; an action is `Call`,
after the Lookups of its entity parameters.

### `$apply`

`$apply` (OData Data Aggregation 4.0, Committee Specification 04) is read
by `ODataApplyTransformation` in ODataKit:

- `aggregate(…)`, each aggregate expression `as` an alias:
  - a path `with sum`, `min`, `max`, `average` or `countdistinct`, the
    path through navigation properties of either cardinality
    (`Products/UnitPrice with sum` is every product's price);
  - an expression with a method (`UnitPrice mul Quantity with sum`);
  - `$count`, or a collection's (`Products/$count`);
  - a custom aggregate the set declares, alone (`Forecast`, or
    `Forecast as F`), whose value the handler gives
    (`-valueOfCustomAggregate:objects:request:`), and a custom aggregation
    method, namespace-qualified (`ProductName with Custom.concat`), whose
    value the handler gives too (`-valueOfAggregationMethod:values:request:`).
- `groupby((paths))`, and `groupby((paths),transformations)`: each group's
  rows through the transformations (`filter(…)/aggregate(…)`, say), which
  have to aggregate, then given the group's values. Grouping paths go
  through to-one navigation.
- `filter(…)`, with `isdefined(path)` among its functions (true of a
  declared or computed property of an entity, null or not; of a grouped
  row, of what the grouping kept); `identity`; `search(…)`;
  `compute(… as …)`; `orderby(…)`; `top(n)`; `skip(n)`; `topcount`,
  `topsum`, `toppercent` and their `bottom` kin, each `(n,value)`, `n`
  a number or an expression of the input (`topcount($these/$count div 3,Amount)`).
- `join(Nav as Alias)` and `outerjoin(…)`, with transformations of their
  own after the alias (`join(Products as P,filter(UnitPrice gt 20))`):
  each row once per member of the collection, the member under the alias,
  a navigation property written where `$expand` names it; an outerjoin
  keeps a row with none, the alias null.
- `concat(sequence,sequence,…)`, each sequence on the same input and
  their rows one after the other (entities, or grouped rows, not both).
- `expand(Nav)` or `expand(Nav,filter(…))`, from earlier drafts, which the
  entities are written with, as `$expand=Nav($filter=…)`.

A `groupby` or `aggregate` of grouped rows groups them again, by their
paths. After `$apply`, `$select` and `$expand` work on entities as ever;
on grouped rows `$select` keeps what it names, and `$expand` is `400`.
Aggregates are values in expressions too (section 3.6), in `$filter`,
`$compute`, `$orderby` (an expression `$orderby` is sorted here), within
`$expand` as well, and in `$apply`'s `filter`, `compute`, `orderby` and
top and bottom kin:

- `$these/aggregate(UnitPrice with sum)` and `$these/$count`, of the
  current collection, each option's own: in `$apply`, the
  transformation's input; for the query's `$filter` and `$compute`, the
  rows the caller can see (after `$apply`, what it made), read once
  first; for `$orderby`, what the `$filter` leaves of them; within
  `$expand`, the parent's members, each parent's (whose members are then
  read one parent at a time, not with the others'). The values are then
  literals in what is read after.
- `Products/aggregate(UnitPrice with sum)`, of a collection-valued
  navigation, a path through to-one navigation to an attribute of the
  members with `sum`, `min`, `max` or `average`, or `$count`: a key path's
  collection operator (`products.@sum.unitPrice`), which each store
  evaluates (`testAggregatesOfNavigations`). An expression, `countdistinct`
  or a custom method there is `501`. Apple's SQLite store refuses arithmetic
  on one (`products.@count * 20`; FreeCoreData's stores do not): `501`,
  as any fetch the store raises for (docs/how-it-works.md, "What stays in memory, and why").

Recursive hierarchies (sections 5.5 and 6) are declared in the model, as
any annotation is: the entity's userInfo `OData.annotations` holds
`Aggregation.RecursiveHierarchy#Qualifier`, a `NodeProperty` (a path
through to-one relationships to an attribute) and a
`ParentNavigationProperty` to the entity itself, to-one or to-many:

```json
{"Aggregation.RecursiveHierarchy#SalesOrgHierarchy":
  {"NodeProperty": {"$PropertyPath": "ID"},
   "ParentNavigationProperty": {"$NavigationPropertyPath": "Superordinate"}}}
```

`$metadata` has it as ever, and a model built from `$metadata` has it
back. Core Data has no recursive query, so a request that names a
hierarchy (`HierarchyNodes=$root/SalesOrganizations`) reads its nodes
once, those the caller can see, and walks the parents here; a parent the
caller cannot see is none, and its children are roots.

- The functions `Aggregation.isnode`, `isroot`, `isleaf`, `isancestor`,
  `isdescendant` (with `MaxDistance` and `IncludeSelf`) and `issibling`,
  in `$filter`, in `$expand`'s, in lambdas and in `$apply`'s `filter`,
  are each read as `Node in (the identifiers that pass)`, which the store
  evaluates. `Ancestor`, `Descendant` and `Other` are literals; anything
  else there is `501`.
- `ancestors(H,Q,p,T[,d][,keep start])` and `descendants(…)`: of the
  input, what is related to an ancestor (a descendant) of the nodes T
  picks, within d, and those nodes with keep start. T is transformations
  that pick among the input, or a bare condition (`Name eq 'US'`, as
  example 56 has it).
- `traverse(H,Q,p,preorder|postorder[,o])`: the input related to each
  node, the nodes in that order; the roots sorted by o, stable, and each
  node's children too (their order is the service's to choose), else in
  key order. Over a hierarchy whose parents are single-valued, as the spec
  defines it.

All three work on entities or grouped rows. Where p goes through a
collection (`Sales/SalesOrganization/ID` of a product), an instance's
nodes are the values along it: ancestors and descendants keep it once if
any is one; traverse writes it once per node, with that node at p (a
collection of one where p's segment is one: example 88's
`{"Sales": [{"SalesOrganization": {"ID": "US"}}]}`).

`501`: what CS04 removed (`from`, `rollup`, `nest`). CS04 groups by
single-valued paths only; a collection-valued one is `400`.

`$metadata` says what a set can do: the container's
`ApplySupportedDefaults` lists the transformations, and each set's
`ApplySupported` the handler's `groupableProperties`,
`aggregatableProperties` (each with its methods) and
`customAggregationMethods`, with a `CustomAggregate` term per custom
aggregate. Aggregating or grouping by what the handler leaves out is
`400`.

| Conformance level (section 8) | What it asks | |
|---|---|---|
| Minimal | `aggregate`, `groupby`, `sum`, `min`, `max`, `average`, `$count` | ✅ |
| Intermediate | and `filter`, `orderby`, `search`, `topcount`, `bottomcount`, `compute`, `concat`, `isdefined` | ✅ |
| Advanced | and the rest | Partly: aggregating expressions and collection-valued paths, custom aggregates and methods, `groupby` with transformations of its own, the top and bottom kin, `join` and `outerjoin`, aggregates in expressions, the capability terms, and recursive hierarchies (p through a collection aside) |

Each works in order on what the one before left: before a grouping on
the entities (`compute` gives each object values by name, which later
filters, orderings, groupings and aggregates use), after one on its
rows (`compute` and the top and bottom kin over their paths, with `add`,
`sub`, `mul` and `div`). Without a grouping the answer is entities, each
with what `compute` gave it, and the query's `$filter`, `$orderby`,
`$count`, `$skip` and `$top` then apply to them. Filters alone join `$filter`, and the answer is
entities. Otherwise the handler fetches the rows the caller may see, with
the leading filters in the fetch; `ODataAggregation` groups and aggregates
them here (null left out; an empty sum is null, as section 3.1.3.1 has
it). The first grouping, when it comes right after those filters, is the
store's instead where the store gives exactly what `ODataAggregation`
would: a dictionary fetch with `propertiesToGroupBy` and aggregate
expressions (`-groupedRowsForFetchRequest:…` of the handler), grouped by
attributes through to-one relationships, with `$count`, `sum` and
`average` of integers (a decimal sum, and an exact decimal average of
the store's sum and count) and of doubles, and `min` and `max` of numbers
and dates. Decimals, which SQLite sums as doubles, strings, which SQL
orders by collation rather than as `NSString` does, `countdistinct`, and
computed values are grouped here, as is everything on Apple over a store
other than SQLite, and on a handler that answers
`-objectsForFetchRequest:…` itself without answering
`-groupedRowsForFetchRequest:…`. `testGroupingInTheStore` holds the two
ways to the same rows over each store. A filter after the grouping, and then `$filter`, `$orderby`,
`$skip`, `$top` and `$count`, work on the grouped rows, whose paths are
nested as the response has them (`{"Category": {"CategoryName": …},
"Total": …}`). The container says `Aggregation.ApplySupported` with
those transformations, `concat` among them. The store's grouping takes
only a `groupby` of plain aggregates: aggregating an expression or a
collection's values, and a `groupby` with transformations of its own,
are grouped here.

### `$compute`

`$compute` (Part 2 §5.1.3) is read as a list of `expression as Name`.
Each name then stands for its expression: in `$filter` (and a filter of
`$apply`, and `/$count`), in `$select`, where it is written into each
row, and in `$orderby`, and in a later `$compute` item. Its value is the
expression's `NSExpression`, evaluated with each object, and typed by
what it is: a decimal as `Edm.Decimal`, a whole number as `Edm.Int64`, a
date as `Edm.DateTimeOffset`; a null operand makes it null. Without
`$select` the computed values come with the rest. A store cannot sort by
an expression, so ordering by a computed value reads every matching row,
sorts them here, and pages after; ordering by properties stays with the
store. Inside `$expand`, an expansion's own `$compute` works the same for
its members. `SelectSupport` says `ComputeSupported`.

### Application time

An entity whose `userInfo` names its period (`OData.periodStart`,
`OData.periodEnd`: Date attributes; `OData.objectKey`: the attributes
that say which object a slice is of; `OData.closedClosedPeriods` for
dates whose end is the period's last day) is a timeline entity set
(OData-Temporal, `Temporal.TimelineVisible`): each row a time slice.
`$metadata` says so with `Temporal.ApplicationTimeSupport` (the unit of
time from the start attribute's type, the three actions below).

`$at`, or `$from` with `$to` (closed-open) or `$toInclusive`
(closed-closed), or `$from` alone, is a filter over the period ANDed with
`$filter` and `$search`, in `/$count` too: a slice that begins before the
interval ends and ends after it begins (or has no end: none, or
9999-12-31). The values are literals; another combination is `400`. They
do nothing on a set without application time. Inside `$expand` they apply
to the members of a timeline reached by navigation
(`Divisions(1)?$expand=Departments($at=2012-03-01)`, section 4.2.1).

`Temporal.Update`, `Temporal.Upsert` and `Temporal.Delete`, bound to the
set (`Departments/Temporal.Update`, or the full namespace), take
`deltaTimeslices`, each a `Timeslice` with its period in it (the
timeline is visible), and follow section 4.3.2 as SQL's `FOR PORTION OF`
does: a slice partly inside a delta's period is split at its edges, the
part inside changed (Update), and the rest kept; Upsert also fills the
gaps in the period, from the slice just before a gap or, for an object
with none there, from the delta alone; Delete takes the period away,
trimming or splitting what it overlaps. An object key the delta leaves
out matches every object. They work on the slices the caller may see,
through the set's handler: the slices are read, the changes worked out
over them (`OISTimeline` writes nothing), and each slice made, changed or
taken away is then its `insert`, `update` or `delete`, once, which can
refuse it (and then nothing of the action is done), or answer later. It
answers
with the slices made or changed (for Delete, the periods taken
away) as `Collection(Temporal.TimesliceWithPeriod)`, or `204` with
`return=minimal`. A new slice's key is assigned as an insert's is, and a
changed slice's version moves on.

### `$search`

`$search` (Part 2 §5.1.7) is parsed by `ODataSearchExpression`, in
ODataKit: words, `"phrases"`, `NOT`, `AND` or nothing between terms, `OR`,
and parentheses. The service makes it a predicate: a word or phrase is
`CONTAINS[cd]` in any of the set's searchable properties, which are its
string properties, or the handler's `searchableProperties` (an empty set:
not searchable, `501`, and `SearchRestrictions` says so). It is ANDed with
`$filter`, and works in `/$count` and in `$expand`'s options.

### Asynchronous requests

A request that prefers `respond-async` (Part 1 §8.2.8.8) is answered as
any request is. One answered while the service first runs it, or within
`Prefer: wait=N`, is answered so, and the preference is not applied. One
still under way, because a handler or the authenticator deferred, is
answered `202 Accepted`, `Preference-Applied: respond-async`, with a
status monitor (`$async/<id>`) in `Location` and `Retry-After: 1`. This
sits at `-startExchange:`, around the whole request, so a `$batch` is
answered this way as a whole.

The monitor (§11.6) is a resource like any other, authenticated as they
are: `GET` is `202` while the request is under way, then `200` with its
answer as `application/http` (and, in 4.01, `AsyncResult` with its
status); `DELETE` forgets it (the work itself is not stopped: a handler
has no way to be told). Only the principal who sent the request may ask;
anyone else, like a monitor that is not there, is `404`. An answer is
kept `asyncResultDuration` (600 seconds) after it is ready, and 0 turns
asynchronous requests off. The container says
`Capabilities.AsynchronousRequestsSupported`. A deferred reply is still
bounded by `replyTimeout`, so an application with long work raises it.

### Delta links

A read of a whole set (or a cast of it), with or without `$filter`,
`$search`, `$select` and `$expand`, but not `$top`, `$skip` or grouping,
takes `Prefer: odata.track-changes` (Part 1 §11.3): the answer says
`Preference-Applied`, and its last page has an `@odata.deltaLink`, the
same request with a `$deltatoken`. The token is the handler's
(`-changeTokenForRequest:`; by default Core Data's persistent history
token, archived, in base64url), taken before the rows are read, so a
change made meanwhile comes again rather than never. A paged read's next
links carry it (`$skiptoken=20~token`), so the delta starts from the first
page, not the last.

The delta link answers what changed since the token, as the handler
says (`-changesSince:request:reply:`, an `ODataChanges`: by default what
the persistent history holds; a handler with a change feed of its own
gives that, with tokens of its own), in one response, first changed
first, with the next delta link:

- entities added or changed, as they are now, through the handler's fetch
  and the request's own options, so visibility, `$select` and `$expand`
  hold as they do for the read;
- entities changed so that the request no longer matches them, visible to
  the caller, removed with reason `changed`;
- entities deleted, removed with reason `deleted`, named by the key their
  tombstone kept, to a caller the handler's visibility predicate,
  evaluated on what the tombstone kept, lets see them (to every caller
  when it reads anything not kept); one added and deleted since is not
  mentioned.

A removal is `@odata.removed` with `@odata.id` in 4.01 and a
`$deletedEntity` in 4.0. A relationship change is a change of the objects
on both sides, which come again whole, so there are no `$link` entries.

By default, a set can be followed where every store keeps history
(`NSPersistentHistoryTrackingKey`, which on both platforms means SQLite;
`ois-serve` takes it in `StoreOptions`), its key attributes are kept in a
deletion's tombstone (`preservesValueInHistoryOnDeletion`, "Preserve After
Deletion" in the model editor), and its handler's `tracksChanges` is left
`YES`; a handler that gives its own changes says so in
`-canTrackChanges`. `$metadata` says which with
`Capabilities.ChangeTracking`. Elsewhere
the preference is not applied, and a `$deltatoken` is `410 Gone`, as is
one whose history has been purged, or a deletion whose key was not kept:
the client reads the set again. A token the service did not write is
`400`.

What a caller may see can change other than by rows changing (their role,
region, team): a handler that says a version of it
(`-scopeVersionForRequest:`) has it carried in its links, and a link
followed with another version is `410` (docs/offline-sync.md, 4.1).

History is kept for `historyRetention` (`HistoryRetention` for
`ois-serve`), when set: what is older is deleted in the background as
requests come (at most every tenth of it, between a minute and an hour;
`-pruneHistoryBeforeDate:error:` does it at once), and a delta link from
before it is `410`. A link stays good that long after it was given;
without it the service deletes no history, which then grows.

### Streams

Streams are kept in Binary attributes, and marked in `userInfo`:

- `OData.stream = YES` on a Binary attribute makes it an `Edm.Stream`
  property, read and written at its own URL (`Photos(1)/Thumbnail`) and
  never in a body.
- `OData.mediaStream` on an entity names the Binary attribute that is its
  media resource: the type is `HasStream="true"`, and the resource is at
  `Photos(1)/$value`. `POST` of anything but JSON to its set creates one
  from the body; its other properties are set after, by `PATCH`.
- `OData.contentType` on either names the String attribute a stream's
  content type is kept in (from the `Content-Type` it was put with);
  without one it is `application/octet-stream`.

The media and content-type attributes are the stream's, not properties.
A stream's ETag is a hash of its bytes, apart from the entity's: `GET`
answers `304` to `If-None-Match` with it, `PUT` takes `If-Match` against
it. A payload says only what is known of a stream, its media ETag and
content type, and at `metadata=full` its links.

## Mapping Core Data to OData

The server uses the same annotations the client reads, and the same
`ODataPropertyMapper`, so one model file describes both ends.

| Core Data | OData |
|---|---|
| `NSEntityDescription` | `EntityType` |
| `userInfo[@"OData.entitySet"]` | `EntitySet` name |
| attribute, via the mapper (`unitPrice` → `UnitPrice`) | `Property` |
| `userInfo[@"OData.property"]` | override a wire name |
| `userInfo[@"OData.key"]` | `Key` |
| `NSRelationshipDescription` | `NavigationProperty` |
| `userInfo[@"OData.etag"]` on an integer attribute: incremented by each update | `@odata.etag`, and `Core.OptimisticConcurrency` in `$metadata` |
| without one, a hash of the row's values | `@odata.etag` |

`$metadata` (CSDL XML) is generated from the model, not written by hand.

A service need not serve all of a model. `configurationName` names one
of the model's configurations, and the service serves the root entities
it lists, each with its sub-entities (nil: every entity with a key). The
rest have no entity set, type or handler. A relationship to one of them
is no property of the types that have it: the mapper
(`ODataPropertyMapper`'s `servedEntityNames`) does not find it by its
name, so a path, a query option (`$filter`, `$orderby`, `$expand`,
`$select`, `$compute`, `$apply`) or a body that names it is refused as
naming nothing, and no answer tells it is there. An application whose
model also holds its own bookkeeping serves only what its clients are
meant to see, and says so where Core Data already says which entities
go together. A configuration that lists a sub-entity without its root
(not served), or a root without all its sub-entities (served whole), or
that the model has not (nothing served), is in `metadataProblems`.

Nor all of an entity. A configuration picks entities, not properties, so
an attribute or relationship whose userInfo says `OData.served` `NO` is
left out of its entity type: not in `$metadata` or a payload, not
searched, and an unknown name wherever a request names it. A `PUT`
replaces what is served and leaves it as it is. An application keeps
there what is its own -- a lock's revision, a tree the served rows hang
in -- beside what its clients see. A key cannot be left out; one marked
so is among `metadataProblems`. Nothing else names it either: a
relationship's `Partner`, `Core.OptimisticConcurrency` (a version
attribute not served still makes the ETag, which the annotation then
does not describe), `Measures.ISOCurrency`'s path; and a timeline or a
recursive hierarchy that needs one is a problem instead. A value of one
that fails validation is the service's fault, not the request's: `500`,
naming nothing, the details logged. An update of only such properties
is no change a delta link reports. Links are one thing, seen from
either end: a relationship served whose inverse is not still changes
both.

Nor need it write to it. A `readOnly` service answers every insert,
update and delete, `$ref` and batched ones included, with `405`, whatever
its handlers allow, and `$metadata` says so on every set. Its actions
still run, and what one changes in the request's context is saved as in
any service: an action is the application's own code, so every change
the model sees is one the application made and checked.

Nor need everything it serves be in the model. A handler whose `openType`
is set serves an open type (`OpenType` in `$metadata`), whose entities
may have dynamic properties. `-dynamicPropertiesOfObjects:request:reply:`
gives them, for all the set's entities a response writes at once: it is
the read plan's last step (`Dynamic properties (Categories)` in
`$explain`), after the rows and their expansions, so the objects are the
rows' and the expanded members' alike, and one query of the
application's answers for the page. Like the plan's other asks it may
answer later, through the reply; the plan goes on from what it knows
when it does. They are written with the declared properties (and named
in `$select` as they are); where the JSON does not say a value's type --
a date, a decimal, an integer, a double, a GUID, binary -- it is
annotated (`Reviewed@odata.type: "#DateTimeOffset"`), as JSON Format
requires of a dynamic property. A write gives them too: the members of a
body the type does not declare, each decoded as its annotation says, `null`
removing one, are handed over by `-writeDynamicProperties:ofObjects:request:reply:`
-- every entity of the set a write inserts or updates at once, a deep
insert's and a delta's included, after the declared properties are set
and before the save, so what the handler changes in the request context
is saved with them, and an error leaves nothing saved. A `PUT` replaces
them all. The default refuses them, naming them as unknown properties.
`-predicateForDynamicProperty:operator:value:request:error:`
says what `$filter` means by one compared with a value -- `Priority gt 2`,
or a path under one, `Variables/amount ge 100` -- as a predicate over
the entity, for this request (whose caller may see some properties and
not others). The predicate is evaluated where the rest of the filter
is, by the store or in memory, so it is built from what the entity
reaches: a subquery over rows of the application's own is how values
kept apart from the entity, a workflow's variables, answer a filter.
`ODataKit`'s `ODataPredicateBuilder` asks its `dynamicProperty` block for
these, handing it the builder's `userInfo`; the service's builder is
copied for each request (`-builderWithUserInfo:`) with the request as
its `userInfo`. Only comparisons with a value are handed over (and
`in`, and the property alone as a condition); sorting by a dynamic
property, or computing with one, is refused.

Where dynamic properties are kept is the handler's to say. By default,
in the entity itself: a Transformable attribute marked
`OData.dynamicProperties` (an `NSDictionary`, the property bag the
client's generated models have too) makes its set an open type with no
code at all. The bag is no property on the wire; its entries are read
from it, written into it (a new dictionary each time, `null` removing
one, a `PUT` replacing them all), and change the entity's ETag.

**The caveat is filtering.** A Transformable is an archive, on Apple and
FreeCoreData alike, which no store filters by, and no store keeps JSON
it can query into. So a filter that names a dynamic property kept there
is evaluated here: the rows the rest of the request allows are read
(`maxRowsInMemory` at most, then `400`, to be narrowed by the rest of
the filter), filtered, ordered and paged in
memory, and counted there (`$count`, `/$count`). A nested `$expand`
filter does the same per parent, and a `$apply` stops pushing filters to
the store at the first that names one. `$explain` shows it: the filter
is an `Apply` over the store scan rather than part of it. Fine for sets
of a few thousand; for a set that grows, keep them elsewhere and
override the handler's methods and `storeFiltersDynamicProperties`:

- **Rows of their own**, one per property, related to the entity: a
  name, a type, and a column for each kind of value, natively typed --
  text, a whole number, a real number (a date as seconds), bytes -- as a
  workflow engine keeps its variables (Camunda's `ACT_RU_VARIABLE`, or
  UDWorkflow's `WFVariable`: `textValue`, `wholeNumber`, `realNumber`,
  `bytesValue`). A filter is a `SUBQUERY` over them, which the store
  runs as SQL, and an index on the name and a value column serves it.
  A number may be in either numeric column, so a comparison asks both.
- **Computed** from what the entity already has (the tests' `Size`, a
  count of products), or **elsewhere** altogether, another service's:
  the handler asks, and may answer later through the reply.

Core Data's composite attributes (Apple, macOS 14) hold only members the
model declares, so they are no place for these.

Requests map onto fetch requests, the reverse of `ODataQueryBuilder`:

| OData | Core Data |
|---|---|
| `$filter` | `NSPredicate` |
| `$orderby` | `sortDescriptors` |
| `$top`, `$skip` | `fetchLimit`, `fetchOffset` |
| `$select` | the properties written; the rows are fetched whole |
| `$expand` | `relationshipKeyPathsForPrefetching`, then inline. A to-many's members are fetched for every parent on the page at once, with the visible rows' predicate, its `$filter`, `$search` and application time, and its `$orderby`, and split among the parents: a one-to-many in one fetch (`inverse IN parents`), a many-to-many or one with no inverse in two (the parents with the relationship prefetched, then `SELF IN` the related rows). Its `$top`, `$skip` and `$count` per parent, and an expansion with its own `$compute`, in memory |
| `$skiptoken` | the service's own: the offset of the next page |
| `Categories(1)/Products` | the destination's rows whose inverse leads to the parent's key: `category.id == 1`, `ANY suppliers.id == 1` |

Navigation compares keys, not objects. Every store compares attributes,
and a SQL store turns them into a plain `WHERE`; managed objects in a
predicate are harder on a store (FreeCoreData matched none of them in its
in-memory store, and raised when counting them, until FreeCoreData #41 and
gnustep-patches' `constant-expression-copy`).
| `/$count`, `$count=true` | `countForFetchRequest:` |
| `If-Match` | compare the ETag, `412 Precondition Failed` on mismatch |

### `$filter` to `NSPredicate`

`ODataExpression.h` parses a `$filter` into a tree, with a split lexer and a
recursive descent parser, and with OData's precedence. It reads the other
system query options and resource paths too (`$orderby`, `$select`,
`$expand` with options nested to any depth, and key predicates), and it
describes a tree back as canonical OData text. The client's tests check that
every `$filter` the translator writes parses.

`ODataPredicateBuilder` walks that tree from the top down, building
`NSCompoundPredicate`, `NSComparisonPredicate` and `NSExpression` objects.
It never formats a string ([below](#no-format-strings)). The sections below
follow the same order: logical operators, which hold comparisons, which hold
operands, which are paths, literals, arithmetic or function calls.

Anything not listed answers `501`: `time`, `totaloffsetminutes` and the
other functions not named here, narrowing casts, casts to and from strings,
and a service's own functions.

#### 1. Logical operators

| `$filter` | `NSPredicate` |
|---|---|
| `a and b`, `a or b` | `NSCompoundPredicate` `AND`, `OR` |
| `not a` | `NOT`, with OData's null ([below](#tested-against-the-client)) |
| `(…)` | Nesting only |
| `Discontinued` (a Boolean property) | `discontinued == YES` |
| `any`, `all`, `isof`, `has` | Predicates in their own right: see their sections |

#### 2. Comparisons

A comparison is two operands and an operator.

| `$filter` | `NSPredicate` |
|---|---|
| `Price gt 20` | `price > 20` (and `eq`, `ne`, `lt`, `le`, `ge`) |
| `Price gt 20`, where `Price` is optional | `price != nil AND price > 20` |
| `Price ne 18`, where `Price` is optional | `price == nil OR price != 18` |
| `Name eq null` | `name == nil` |
| `ID in (1, 2)` | `id IN {1, 2}` |
| `tolower(Name) eq 'abc'` | `name ==[c] 'abc'`, which a SQL store can use without lowering every row |

- **Null tests come first.** The null tests make a comparison hold as OData
  says it does. They come first so that a store evaluating the predicate
  itself never does arithmetic on nil, which raises.
- **Literals are typed** by the attribute they meet: `'2025-03-01'` against
  a Date attribute is a date.
- **Functions compared with a literal** are the exception to "two
  operands". A function the store cannot evaluate is rewritten, together
  with the literal it is compared with, into a range or a pattern of its
  argument ([step functions](#step-functions-as-ranges),
  [date parts](#date-parts), [string functions](#string-functions-as-patterns)).

#### 3. Operands: paths

| `$filter` | `NSPredicate` |
|---|---|
| `Name` | `name` |
| `Category/Name` | `category.name` |
| `Products/$count` | `products.@count` |
| `Products/$count($filter=Price gt 20)` | `SUBQUERY(products, $v0, $v0.price > 20).@count` (4.01) |
| `Products/any(p:p/Price gt 20)` | `SUBQUERY(products, $v0, $v0.price > 20).@count > 0` |
| `Products/all(p:p/Price gt 20)` | `SUBQUERY(products, $v0, NOT $v0.price > 20).@count == 0` |
| `Products/any()` | `products.@count > 0` |
| `@p` | The parameter alias's value, followed through aliases of aliases |

A lambda's body is built recursively, from [logical operators](#1-logical-operators)
down, with its variable in scope as `$v0`, `$v1` and so on. A count's
`$filter` is built the same way, its member the SUBQUERY's variable: there a
path with no variable, and `$this`, are the member's, and `$it` is still
the object filtered, a key path from it (Apple's stores and evaluation both
read a key path inside a SUBQUERY as the outer object's). `$search` inside
`$count(…)` is answered 501.

##### Type casts and `isof`

- **Forms.** Type casts (`Default.Manager/Budget`,
  `Manager/Default.Manager/Budget`, `Reports/Default.Manager/any(…)`,
  `Reports/Default.Manager/$count`, `cast(Manager,Default.Manager)`) and
  `isof` (`isof(Default.Manager)`, `isof(Manager,Default.Manager)`) test an
  object's type with `entity IN {the type and its subentities}`.
- **Store support.** Apple's stores all answer `entity` in a predicate, in
  SQL or evaluated on their nodes. That holds of the fetched object, of one
  it reaches through a relationship, and of a `SUBQUERY`'s variable.
  FreeCoreData's stores answer it too, since its atomic stores' nodes do.
- **The test comes first.** Whatever reads a cast object sits behind that
  test in an `AND`. A store that evaluates a predicate itself raises when
  asked an Employee's `budget`.
- **Null elsewhere.** Where the object is not of the type, the cast is
  null, as the URL conventions have it: `Default.Manager/Budget eq null`
  holds for every Employee that is not a Manager
  (`NOT test OR budget == nil`).
- **Ordering by a cast is `501`**: a store that sorts objects would ask
  every object for the property.
- **Primitive casts.** A cast to a primitive type holds when that type
  takes every value of the property's type:
  `cast(Quantity,Edm.Decimal) gt 2.5` compares the quantity as a number,
  and `isof(Quantity,Edm.Int64)` is true (null too: null casts to
  anything). A narrowing cast rounds as the service sees fit, and a cast
  to or from a string depends on text, so both are `501`.

#### 4. Operands: literals

Every OData literal type is read. A literal takes the type of the attribute
it is compared with, so `2.5` against a Decimal attribute is an
`NSDecimalNumber`, and against a Double one an `NSNumber`. Numbers in
[arithmetic](#5-operands-arithmetic), and numbers compared with arithmetic,
are always plain `NSNumber`s.

#### 5. Operands: arithmetic

| `$filter` | `NSPredicate` |
|---|---|
| `Price add 5 gt 20` | `price + 5 > 20` (and `sub`, `mul`, `div`) |
| `Price mod 2 eq 0` | `modulus:by:(price, 2) == 0`, on Apple only |
| `-Price` | `price * -1` |

gnustep-base names its arithmetic functions differently from Apple (`_add`,
not `add:to:`) and has no modulo, so `mod` works on Apple only.

#### 6. Operands: function calls

Only a few functions become an `NSExpression` the store evaluates:

| `$filter` | `NSPredicate` |
|---|---|
| `contains(Name, 'ha')` | `name CONTAINS 'ha'` |
| `startswith(Name, 'Ch')`, `endswith(…)` | `BEGINSWITH`, `ENDSWITH` |
| `tolower(x)`, `toupper(x)` | `[c]` on the comparison, or a folded constant |
| `now()` | The request's time, as a constant |
| `matchesPattern(Name, 'a.c')` | `name MATCHES`, the pattern found anywhere, rewritten from ECMAScript's syntax into ICU's ([below](#patterns-ecmascript-and-icu)) |

The rest have no `NSPredicate` equivalent, so they work only when compared
with a literal, as the following sections show.

##### Patterns: ECMAScript and ICU

OData's patterns are ECMAScript's; `MATCHES` reads ICU's, with `.`
matching line terminators (a `\r\n` taken whole) and, on Apple (and on
gnustep-base with the `predicate-matches-line-anchors` fix), `^` and `$` at
line boundaries. The two look alike and differ in what they match, so a
pattern is never passed through as text: `ODataRegex` (ODataKit) reads it
into a tree whose every node says exactly what it matches, and writes the
tree in the other dialect, which refuses what it cannot say exactly rather
than say something close. From ECMAScript, as `MATCHES` reads it:

| ECMAScript | ICU, as `MATCHES` reads it |
|---|---|
| `^`, `$` | `\A`, `\z`: the ends of the string, not of a line |
| `.` | `[^\n\r\u2028\u2029]`: not a line terminator |
| `\d`, `\w`, `\s` (and `\D`, `\W`, `\S`, in sets too) | `[0-9]`, `[A-Za-z0-9_]`, ECMAScript's white space spelled out: as ECMAScript has them |
| `\b` | a lookaround of ASCII word characters |
| found anywhere | `(?:[^\r]|\r)*(?:…)(?:[^\r]|\r)*`: any character, one at a time, so that a match starting at the `\n` of a `\r\n` is found |

A pattern that is none (`(`, `[a`, `a{3,2}`) is `400`; one that is, but
that the tree does not read (back references, `\p{…}`), is `501`.

The client goes the other way for `LIKE` and `MATCHES`: a wildcard, or a
`.`, is `(?:\r\n|\r(?!\n)|[^\r])`, any character with a `\r\n` as one,
as ICU takes it; `\A` and `\z` are `^` and `$`; and what ECMAScript cannot
say (`^` and `$` where they are at each line, ICU's Unicode `\d`, `\w`,
`\s` and `\b`, inline flags but a leading `(?s)`, sets in sets) is refused
rather than guessed. The `$metadata` writer does the same for a model's
`MATCHES` validation, written as `Validation.Pattern`, and leaves out one
ECMAScript cannot say; the client's model builder, and the service's
`Validation.Constraint`, read `Validation.Pattern` and `matchesPattern` as
the server's `matchesPattern` does.

The patterns written for `MATCHES` keep to the part of ICU's syntax
FreeCoreData's SQL stores translate (literal characters, sets and
ranges, `.`, `\A`, `\z`, groups, lookahead, repeats) wherever nothing
outside it is asked for, so they run in the database there.

##### Step functions as ranges

`year`, `date`, `floor`, `ceiling` and `round` are step functions, so
compared with a literal each is a range of its argument, and a SQL store can
use an index for it:

| `$filter` | `NSPredicate` |
|---|---|
| `year(Hired) eq 2025` | `hired >= 2025-01-01T00:00Z AND hired < 2026-01-01T00:00Z` (in UTC, as dates are written) |
| `floor(Price) le 18` | `price < 19` |
| `round(Price) eq -5` | `-5.5 < price <= -4.5` (half away from zero) |

- `ne` is outside the range, or null.
- `in` is each value's range.
- A fractional literal makes `eq` false, and moves the other comparisons to
  the whole number beside it.
- Compared with anything but a literal, or used in `$orderby`, these
  functions are `501`.

##### Date parts

`month`, `day`, `hour`, `minute` and `second` are not one range but one in
each year, month, day, hour or minute.

- `month(Hired) eq 3` is every March from the earliest `Hired` the caller
  can see to the latest.
- The read's plan finds that span first (a Span: two fetches of one row
  each, through the handler), and gives it to the builder
  (`-predicateForExpression:entity:aliases:computed:spans:error:`).
  Outside a service, the builder can be given a context to read it from
  instead.
- A span of more than 200 ranges (six years of days, for `hour`) is `501`,
  since an `OR` that long is more than SQLite takes.

##### String functions as patterns

`length`, `substring`, `trim` and `indexof` of a string property, and
`concat` of one with a literal, are compared with a literal. Each becomes a
pattern the property matches, or a plain comparison:

| `$filter` | `NSPredicate` |
|---|---|
| `length(Name) gt 10` | `name MATCHES '.{11,}'` |
| `substring(Name,1) eq 'hai'` | `name MATCHES '.{1}hai'` |
| `indexof(Name,'a') eq 2` | `name MATCHES '(?:(?!a).){2}a.*'` |
| `trim(Name) eq 'Chai'` | `name MATCHES '\s*Chai\s*'` |
| `concat(Name,' tea') eq 'Chai tea'` | `name == 'Chai'` |

`substring`, `trim` and `concat` are compared with `eq` and `ne` only.
Each `.` above is written `(?:[^\r]|\r)`, one character: ICU's own `.`
counts a `\r\n` as one, where `length` counts two.

##### `has`

`has` has no bitwise `and` that a store evaluates, but an enumeration has
few values.

- **Flags.** A flags enumeration's values are the combinations of its
  members' bits. `Colours has Default.Colour'Red'` is
  `colours IN {1, 3, 5, 7}`: every value that has the bit. Every store
  takes that.
- **Plain enumerations.** A plain enumeration's values are its members.
- **Kept as text.** An enumeration kept as text is kept as its canonical
  text (`Red,Green`, whatever order or numbers it was written in), so the
  test is `IN` those values' texts.
- **Limit.** An enumeration with more than 16 flags is `501`.

#### No format strings

**The builder never builds a predicate by formatting a string for
`+predicateWithFormat:`.** The one exception is a key path off a lambda's
variable (`$v0.unitPrice`), which is made from a generated name and the
model's own property names, never from request text. There are two
reasons:

- A string built from request input is an injection vector.
- gnustep-base's predicate parser has quirks the client has already hit.
  It rewrites `BETWEEN` into `>=` and `<=`, and wraps each bound in a
  second constant expression, so parsing is not a neutral step.

#### Tested against the client

The client's `ODataPredicateTranslator` and this builder are tested against
each other (`Tests/ODataPredicatePairTests.m`):

- predicate → `$filter` → predicate, and
  `$filter` → predicate → `$filter` → predicate;
- each pair selecting the same rows;
- over an in-memory store and SQLite, and on GNUstep over FreeCoreData's
  SQL backends too (PostgreSQL 16, MySQL 8 and MariaDB 11, in CI);
- in 4.0 and 4.01.

A `$filter` the service reads but the client cannot write is listed, with
the reason. Today the list is: in 4.0, which has no `matchesPattern`,
`matchesPattern` itself and the string functions the service reads as
`MATCHES` patterns (`length`, `substring`, `indexof`); in both versions,
`trim`, whose pattern uses `\s`, which ICU and ECMAScript read
differently. The test fails when the list stops being true.

What the tests found, and what was done about each:

- **OData's null is not SQL's.** `UnitPrice ne 18` holds for a null price,
  and so does `not (UnitPrice gt 20)`. SQL's `NULL <> 18` and
  `NOT (NULL > 20)` are unknown, so Apple's SQLite store left those rows
  out where its in-memory store kept them.
  - A comparison now tests its nullable key paths first: an optional
    attribute, or anything reached through a relationship.
    `UnitPrice gt 20` becomes `price != nil AND price > 20`, and
    `UnitPrice ne 18` becomes `price == nil OR price != 18`.
  - The test comes first so that a store evaluating the predicate itself
    never does arithmetic on nil, which raises.
- **`not` of null is null** (5.1.1.1.7-9). A comparison is never null,
  but a function of a null is (`contains(QuantityPerUnit,'jars')`), as are
  a null Boolean, `has` of a null, and `any` or `all` over a collection
  through a null to-one. So `not contains(QuantityPerUnit,'jars')` leaves
  out a null QuantityPerUnit. `and` and `or` follow the spec's tables:
  `null and false` is false, `null or true` true.
  - Each such condition keeps the predicate for where it is false beside
    the one for where it is true: `quantityPerUnit != nil AND NOT
    (quantityPerUnit CONTAINS 'jars')`. `not` swaps the two.
  - Core Data's `NOT` is two-valued, so the client, under an odd number of
    `NOT`s, writes such a condition with its operands known:
    `NOT (quantityPerUnit CONTAINS 'jars')` is
    `not (contains(QuantityPerUnit,'jars') and QuantityPerUnit ne null)`.
- **Decimals compared as text.** Apple's SQLite store compares a computed
  value with an `NSDecimalNumber` constant as text, so
  `UnitPrice mul 2 lt 30` returned every row. Numbers in arithmetic, and
  numbers compared with arithmetic, are now plain `NSNumber`s.
- **`length`.** Apple's SQLite store returned every row for
  `name.length > 10`. `length(x) op n` is now a pattern of that many
  characters: `name MATCHES '.{11,}'`.
- **Folded constants.** `startswith(tolower(Name), tolower('ch'))` was
  `lowercase:(name) BEGINSWITH 'ch'`, which Apple's SQLite store refuses
  (a `500`). The case-insensitive form now takes a folded constant the same
  way it takes a literal.
- **`matchesPattern`.** The 4.01 function, which the client writes for
  `LIKE` and `MATCHES`, is read as the pattern found anywhere in the
  string.
- **ECMAScript is not ICU.** `matchesPattern(Name,'a.b')` matched `a\nb`,
  and on Apple `'^b'` matched after a line break: `MATCHES` reads `.` as
  anything and `^` and `$` at line boundaries. Patterns are now rewritten
  both ways ([above](#patterns-ecmascript-and-icu)), and
  `testMatchesPatternIsECMAScripts` pins what ECMAScript finds.
- **Client fixes.** The client:
  - dropped the case of `==[c]`;
  - wrote `Suppliers/@count`;
  - guessed a wire name for any unknown key path (`entity` became
    `Entity eq '<NSEntityDescription …>'`);
  - could not write `SUBQUERY` counts, arithmetic, or a subentity's
    property.

  It now writes `tolower(…) eq tolower(…)`, `$count`, `isof` for an entity
  test, `any`/`all` for a counted `SUBQUERY`, `add`/`sub`/`mul`/`div`/`mod`,
  and casts (`Default.Manager/Budget`), and it refuses a name the model
  does not have.

### Values are serialised by the model's types

Literal and JSON values are written according to the attribute's
`attributeType`, never by inspecting the `NSNumber`:

- On gnustep-base a BOOL is an `NSBoolNumber` with type code `C`. On Apple
  it is `c`. The client's BOOL handling broke on exactly this.
- Every row the server writes goes through this path, so the same mistake
  would corrupt every boolean, not one test.

The same applies to dates (`Edm.DateTimeOffset`, UTC, ISO 8601), decimals
(`Edm.Decimal`, from `NSDecimalNumber` without going through `double`) and
UUIDs (`Edm.Guid`).

## Errors

Every failure is an OData error body with a status code: `400` for a query
that does not parse, `404` for an unknown set or key, `405` for a method a
resource does not allow, `412` for an ETag mismatch, `501` for a feature
outside the supported set, `406` and `415` for formats it does not speak.
Never a bare `500` for bad input. A handler reports with
`ODataServiceError(status, message)` (`ODataError.h`), whose code is the
status; the body's `code`, `message`, `target` and `details` are what the
client's `ODataError` keys read back.

## Testing

- **The core, without sockets.** `Tests/ODataServiceTests.m`, over the
  Catalog model in memory: `$metadata` (read back by the client's
  `ODataSchema`, and matching the model with no problems), query options,
  navigation, properties and `$value`, `$expand` with nested options,
  server-driven paging, create, update and delete with ETags, errors,
  metadata levels, a handler that hides rows and answers later.
- **Round trip.** `ODataIncrementalStore` over an in-process `ODataService`
  over an in-memory Core Data store: fetch, fault, insert, update and
  delete in one save, the backing store checked directly, and a change
  behind the client's back reported as a conflict.
- **HTTP adapter.** `Server/Tests/ois-serve-check.m`: requests over a real
  loopback socket, chunked bodies, errors, `HEAD`, concurrent requests.
- **Parser pairs**, as above.
- **Not the snapshots.** `Tests/Snapshots/` is a corpus of behaviours a
  client meets, from several services at once (a `204` whatever `Prefer`
  says, edit links elsewhere, a service's own validation and skip tokens,
  data that differs from file to file), not one service's answers.
  Replayed against the service, every difference was one of those, or
  one where the service follows the specification more closely (context
  URLs with the expanded select list, null properties written); so they
  stay the client's.

Everything runs in the existing CI: XCTest on macOS against Apple's Core
Data, and `tools-xctest` on Linux against FreeCoreData on the
gnustep-patches stack.

## Layout

The repository is ODataKit, and it builds five libraries, one directory
each under `Source/`, public headers in `include/<Library>/`:

| Library | Holds | Links |
|---|---|---|
| `ODataKit` | Schema, values, property mapping, the `$filter` lexer and parser, `$batch`, errors, the transport protocol and HTTP transports | Core Data |
| `ODataIncrementalStore` | The client: the store, configuration, query building and predicate translation, the model builder and class writer, history, operation calls | `ODataKit`, `OTelKit` |
| `OTelKit` | OpenTelemetry tracing: span context (W3C Trace Context), spans, sampling, batching, the OTLP/HTTP exporter | Foundation |
| `HTTPServerKit` | An HTTP server for any API: the listener (GCDWebServer), the pipeline, router and stages, sign-in and JWT signatures, logs, metrics, the application | `OTelKit` |
| `ODataService` | The core of the server: `ODataService`, `$batch`, the predicate builder, the metadata writer, operations; and the service as an `HTTPServerKit` module (`ODataServer.h`) | `ODataKit`, `HTTPServerKit` |

The client and the server share only `ODataKit` (and `OTelKit`, for
tracing), so an app that consumes a service does not carry the server and
one that serves does not carry the store. Class names keep their `OData` prefix; only the headers moved, so
an import is `<ODataKit/ODataSchema.h>`, `<ODataIncrementalStore/…>` or
`<ODataService/…>`. `HTTPServerKit`'s classes are `HS`-prefixed, `OTelKit`'s `OT`.

The HTTP server is a library of its own, `HTTPServerKit` (with the vendored
GCDWebServer, and sign-in), which knows nothing of OData; `ODataService`
links it for `ODataServer.h`, and the client links neither. `Server/` has
`ois-serve`, an example application and the loopback check.

## Milestones

1. ~~**Read-only core.**~~ Done: service document, `$metadata`, collections,
   entity by key (and key as segment), properties and `$value`, `$filter`,
   `$orderby`, `$top`, `$skip`, `$select`, `$count`, paging.
2. ~~**Navigation.**~~ Done: navigation paths and `$expand` with nested
   options, `$ref` and `/$count` within it, `$levels` (a number, or `max`,
   taken as 32 and never through the same entity twice); type casts in the
   path (`Employees/Default.Manager`, `Employees(2)/Default.Manager/Budget`,
   and inserting through one) and in `$select` (`Default.Manager/Budget`);
   references (`Products(1)/Category/$ref`, `Categories(1)/Products/$ref`).
   Also casts in `$filter` and `isof`, as above.
3. ~~**Writes.**~~ Done: POST (to a set or through a navigation property),
   PATCH, PUT, DELETE, ETags with `If-Match` and `If-None-Match`,
   `@odata.bind`, `Prefer: return`. The client round trip passes. Also:
   - a single property (`PUT`/`PATCH` `{"value": …}`, `PUT` its `$value`,
     `DELETE` it to null);
   - upsert (Part 1 section 11.4.4): `PATCH` or `PUT` to a key of a set
     that names no entity creates it, through the handler's insert, with
     the URL's key (a body may repeat it, not contradict it: `400`), and
     answers `201` (`204` with `return=minimal`); `If-Match` there is
     `412`, `If-None-Match: *` makes it create only (`412` when the entity
     exists). Sending the same again ends the same way, which is what a
     client that makes its own keys relies on (docs/offline-sync.md). A
     handler turns it off (`allowsUpsert`); `$metadata` says it
     (`UpdateRestrictions/Upsertable`). Not through a navigation property;
   - references: `PUT` and `DELETE` a to-one `$ref`, `POST` to a to-many
     one and `DELETE` from it by `$id` or by key, which is how the client
     changes relationships;
   - deep inserts, to any depth, each entity through its set's handler,
     answered with what was created expanded. The write is planned
     ("Writes are planned", above): a handler that answers later stops
     it there, and its answer starts it again from the top, where what
     was done is not done again;
   - deep updates (Part 1 section 11.4.3.1): a nested entity that names
     one there (by `@id`, or its key) updates it, as by PATCH, and one
     that names none is created; a to-one takes an entity or null, a
     to-many the full set, those it leaves out unlinked, not deleted; and
     `Nav@delta` changes a collection: entries added or updated, `@removed`
     ones unlinked, or deleted for the reason `deleted`. Each nested
     change goes through its set's handler as the set allows it (`405`
     otherwise), and a nested `@odata.etag` must match (`412`);
   - collections (4.01, Part 1 sections 11.4.12-14): `PATCH` of a
     collection with a delta payload (entities upserted, `@removed` ones
     deleted, or from a navigation property's collection unlinked unless
     removed as `deleted`), `PUT` of one (its entities upserted, the rest
     deleted), and `PATCH` or `DELETE` of `Collection/$each`, after type
     casts and `$filter(…)` segments (which reads take too). All or
     nothing; with `return=representation`, the rows as they are now, or
     a delta payload of the changes.
4. ~~**HTTP adapter.**~~ Done: GCDWebServer vendored and ported,
   `HSServer`, `ois-serve`, the loopback check in CI on both
   platforms, example units and proxy configurations.
5. ~~**Operations**~~, declared in protocols, as above. Done: functions and
   actions bound to entities and collections, and unbound ones through
   imports, answering at once or later, and composing on a function's
   entities.
6. ~~**`$batch`**~~, multipart and JSON. Done:
   - Each request is answered as any other, in order. A change set's (an
     atomicity group's) requests share one context, saved once they have
     all succeeded; if one fails, or the save does, none takes effect, and
     the change set is answered with that failure alone (in JSON, the
     others of the group with `424`).
   - `$1` names what request 1 created, in a URL and in `@odata.bind`; the
     batch's own headers (who is asking) hold for each request under its
     own; the batch stops at the first failure unless the client prefers
     `odata.continue-on-error`; no reads in a multipart change set.
   - A handler that answers later holds nothing up: the batch goes on when
     its exchange finishes, target-action.
   - The client's multi-object saves are atomic through it
     (`testClientSavesAreAtomic`). Inserts join the change set when the
     client supplies keys (`ODataIncrementalStorePostOnObtainPermanentIDsOption`
     set to NO); by default it POSTs them first, for the service to assign
     keys, and those are not part of the save's change set.
   - Found on the way: the client took the ETag of an entity from any
     payload that named it, a key-only reference inside another row
     included, while keeping older values, so its next update overwrote a
     change it had not seen. It now takes an ETag only with the row
     (`testReferencesDoNotRefreshTheClientsETag`). And with port 0,
     GCDWebServer can pick a port that is free for IPv4 and taken for
     IPv6; `HSServer` tries another.
7. ~~**Workbench on the server.**~~ Done: `WorkbenchEngine` is an
   `ODataService` over an in-memory store with operations of its own, and
   the Workbench's self-test (59 checks, 4 of them the built-in
   operations) passes on both platforms. The model is copied before its
   Product entity gets its own class, since a model loaded again may be
   the one the client already uses; FreeCoreData models can be copied
   since #43.

## Vocabularies

`$metadata` carries the Core, Validation, Capabilities and Authorization
vocabularies, each referenced when it is used, from what the model and
the service already say (see [odata-conformance.md](odata-conformance.md)
section 9): Core's `Computed`, `Immutable`, `Permissions`, `Description`
and `LongDescription` from `userInfo` and derived and version attributes,
and `OptimisticConcurrency`; Validation's `Minimum`, `Maximum` (with
`Exclusive`), `Pattern`, `AllowedValues`, `MinItems` and `MaxItems`, and
the `MaxLength` facet, from the model's validation predicates and
relationship counts; Capabilities' insert, update and delete
restrictions from the handlers; Authorization's schemes from the
authenticator. `OData.annotations` in `userInfo`, and the service's
`containerAnnotations`, add any others (JSON CSDL values). The service
ignores a value a body gives a computed property, and refuses to change
an immutable one; Core Data's validation enforces the rest, and the
service itself `Validation.MultipleOf` and `Constraint` before it saves.
Capabilities say what it does (its conformance level, batches, deep
inserts and updates, the functions `$filter` takes) and what each set's
handler allows, including properties `$filter` and `$orderby` may not
use. `Core.Messages` a handler adds go into the response's JSON body.

## Open questions

- ~~ETags~~: both. A version attribute where `userInfo` names one (and
  `$metadata` says so with `Core.OptimisticConcurrency`), else a hash of
  the row's values.
- ~~Paging~~: `maxPageSize` on the service, and the client's
  `Prefer: odata.maxpagesize`, whichever is smaller; the client follows
  `@odata.nextLink` already.
- ~~Authentication~~: the service is a relying party, and signs no one
  in. An identity provider (OIDC; passwords, passkeys or FIDO2 keys are
  its business) signs the user in, and the service's `authenticator`
  (`HSAuthentication.h`) says who each request is from, as an
  `HSPrincipal` on the request, which handlers see (a
  `-predicateForVisibleObjectsInRequest:` that scopes rows to the caller)
  and operations too. `HSTrustedHeaderAuthenticator` takes it from the
  headers a reverse proxy sets once it has checked the user
  (oauth2-proxy, Authelia, Caddy's `forward_auth`, nginx's
  `auth_request`; `ois-serve -TrustedUserHeader`), with a secret header
  the proxy adds so that a request that did not come through it is
  refused. Without such a proxy, the client sends its access token
  (`Authorization: Bearer`), and `HSJWTAuthenticator` checks a JWT by
  its signature, as RFC 8725 has it (the algorithm from an allow-list,
  never `none` or HMAC; the key from the issuer's JWK Set, found through
  its discovery document and fetched again when it rotates, never from
  the token; `iss`, `aud`, `exp`, `nbf`, `sub`, scopes), or
  `HSTokenIntrospectionAuthenticator` asks the provider about any
  token (RFC 7662), keeping the answer a minute. The signatures are the
  platform's to check: Security.framework on Apple, GnuTLS (which
  gnustep-base links already) elsewhere; JOSE libraries would bring more
  dependencies (libjwt needs jansson and OpenSSL, and has no Apple
  backend) than the parsing they save. A request that names no one is `401` with `WWW-Authenticate`,
  unless the service allows anonymous requests. An authenticator answers
  through an `ODataReply`, so one that asks elsewhere (introspecting a
  bearer token, say) can take its time. A `$batch` is authenticated once:
  its requests are its principal's, whatever headers they carry inside
  it, since the proxy never sees those.
