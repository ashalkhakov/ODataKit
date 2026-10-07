// ODataServer — an ODataService served by HTTPServerKit: the service as one
// of an application's APIs.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// ODataServerApplication is the application ois-serve is: HTTPServerKit's,
// with the OData service the settings describe as its module. An
// application of its own subclasses it, and has the service's
// -configureService: beside HSApplication's methods:
//
//   @interface CatalogServer : ODataServerApplication
//   @end
//
//   @implementation CatalogServer
//   - (void)configureService:(ODataService *)service
//   {
//     [service setHandler:[[OrdersHandler alloc] initWithEntity:...] forEntitySet:@"Orders"];
//   }
//   - (void)configureRouter:(HSRouter *)router
//   {
//     [router insertRoute:[HSRoute routeWithMethod:@"GET" path:@"/stats" handler:...] atIndex:0];
//   }
//   @end
//
//   int main(int argc, const char *argv[])
//   {
//     return HSMain(argc, argv, [CatalogServer class]);
//   }
//
// An application with other APIs beside OData adds an ODataServiceModule
// to an HSApplication's modules itself.

#pragma once
#import <ODataService/ODataService.h>
#import <HTTPServerKit/HTTPServerKit.h>

NS_ASSUME_NONNULL_BEGIN

// What a bundle's principal class implements for ois-serve to hand it the
// service before the first request: register entity set handlers, set
// paging, and so on. (A bundle whose principal class is an
// ODataServerApplication subclass is the application, and can add routes
// and stages too.)
@protocol ODataServiceConfiguring <NSObject>
+ (void)configureService:(ODataService *)service;
@end

// An ODataService, mounted: each request becomes an ODataExchange on the
// service's public URL (its serviceRoot's scheme, host and port, then the
// request target as it came), with who is asking when the authentication
// stage found out, so the service does not ask again. Its operation (for
// metrics and logs) is the entity set it names, $metadata, $batch, or
// (other). Errors of requests it takes are answered as OData answers them
// ({"error": {"code", "message"}}), wherever they arise. Mount it at the
// service root's path: /odata/*.
@interface ODataServiceHandler : NSObject <HSHandler, HSErrorFormatting>
- (instancetype)initWithService:(ODataService *)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataService *service;
@end

// An ODataService's store answers a count of one of its entity sets.
@interface ODataServiceStoreCheck : NSObject <HSReadinessCheck>
- (instancetype)initWithService:(ODataService *)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// The service as an application's module: mounted at its service root's
// path (ODataServiceHandler), its store a readiness check, the
// application's authenticator its own (for $metadata, and for requests that
// reach it otherwise), and the application's metrics its own. The
// application's AllowAnonymousMetadata setting, when it has one, is the
// service's allowsAnonymousMetadata, whatever its configuration's class. A Core Data
// that traces (one with +[NSPersistentStoreCoordinator cd_setTracer:]) is
// handed a tracer. An operation the service cannot declare stops the
// server from starting.
@interface ODataServiceModule : NSObject <HSModule>
- (instancetype)initWithService:(ODataService *)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataService *service;
@end

// ois-serve's settings: HTTPServerKit's, with the service's, and OIS_ for
// their environment variables (OIS_PORT, OIS_MODEL).
//
//   Model         the compiled model (.momd, .mom; on GNUstep an
//                 .xcdatamodeld too)
//   StoreType     SQLite, InMemory (default), XML, Binary (Apple only), or a
//                 store type a linked or loaded backend registers; one that
//                 nothing registered is looked for as lib<StoreType>
//                 (CDPostgreSQLStore: libCDPostgreSQLStore)
//   StoreURL      the store's URL; a plain path is a file
//   StoreOptions  a dictionary, handed to the coordinator as it is
//   ServiceRoot   the public URL of the service, which its links begin with
//                 (default http://127.0.0.1:<Port>/odata/)
//   MaxPageSize, MaxVersion, Namespace, Container, MaxURLLength,
//   MaxExpandDepth, MaxBatchRequests, MaxRowsInMemory, MaxJSONDepth,
//   MaxAsyncRequests, ReplyTimeout, AsyncResultDuration,
//   RepeatabilityDuration, HistoryRetention   the service's (ODataService.h)
//   AllowAnonymous  YES: a request that names no one is answered too
//   AllowAnonymousMetadata  YES: the service document and $metadata are,
//                 so that a client can read how to sign in (the
//                 Authorization vocabulary) before it has
//   PrintMetadata YES: write $metadata to standard output and exit
@interface ODataServerConfiguration : HSConfiguration
@property (nonatomic, readonly) BOOL printsMetadata;
// The service, its store opened, as the settings describe it.
- (nullable ODataService *)serviceWithError:(NSError **)error;
@end

@interface ODataServerApplication : HSApplication
// Made by -prepare:, from the settings (a Model is needed), before the
// modules are.
@property (nonatomic, readonly, strong, nullable) ODataService *service;
// What an application overrides to change the service: handlers,
// operations, limits. The bundles' that conform to ODataServiceConfiguring
// are sent theirs after. Default: none.
- (void)configureService:(ODataService *)service;
@end

@interface HSServer (ODataService)
// A service alone, at its service root's path: a router with that one
// route, and nothing in front of it (the service asks its authenticator
// itself).
- (instancetype)initWithService:(ODataService *)service;
@end

NS_ASSUME_NONNULL_END
