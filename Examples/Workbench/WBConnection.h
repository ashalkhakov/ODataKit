// The Workbench's connection: which service, the store over it, and how
// the store talks to it. No views: the window controller shows it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "WorkbenchEngine.h"

NS_ASSUME_NONNULL_BEGIN

// The services the Workbench knows, in the order it offers them.
typedef NS_ENUM(NSInteger, WBService) {
  WBServiceBuiltIn = 0,
  WBServiceNorthwind,
  WBServiceTripPin,
  WBServiceOther
};

@interface WBConnection : NSObject

// The service root a known service has; nil for another.
+ (nullable NSString *)rootOfService:(WBService)service;
// The service a typed root names: one of the known ones, or another.
+ (WBService)serviceOfRoot:(NSString *)root;

// What it tells: connectedAction once a connection is made or has failed
// (the argument this connection: see store and failure), logAction for
// each exchange with the service (the argument a WorkbenchLogEntry), on
// the main thread.
@property (nonatomic, weak, nullable) id target;
@property (nonatomic) SEL connectedAction;
@property (nonatomic) SEL logAction;

// A connection to a service: the built-in one at once, in this process;
// another reads $metadata away from the main thread and tells when it is
// done. nil once started; else why it cannot be (a root that is not one).
- (nullable NSString *)connectToService:(WBService)service root:(NSString *)root;

@property (nonatomic, readonly) WBService service;
@property (nonatomic, readonly, getter=isConnecting) BOOL connecting;
@property (nonatomic, readonly, nullable) NSURL *serviceRoot;
@property (nonatomic, readonly, nullable) NSManagedObjectModel *model;
@property (nonatomic, readonly, nullable) ODataIncrementalStore *store;
@property (nonatomic, readonly, nullable) NSManagedObjectContext *context;
// Why the last connection failed; nil when it did not.
@property (nonatomic, readonly, copy, nullable) NSString *failure;
// The built-in service, when that is the one.
@property (nonatomic, readonly, nullable) WorkbenchEngine *engine;
// The built-in service served on the network too (HTTPServerKit), for a
// device elsewhere (the Device app, on iOS): at servePort (default 8640),
// on all interfaces, with no authentication. Its root is then the network
// one (servedRoot), which its links begin with, in this process as well.
// Taken at the next connection.
@property (nonatomic) BOOL servesNetwork;
@property (nonatomic) NSUInteger servePort;
@property (nonatomic, readonly, nullable) NSURL *servedRoot;
// Why it is not served, when it was asked to be.
@property (nonatomic, readonly, copy, nullable) NSString *serveFailure;
// How many exchanges the transport in use has started.
@property (nonatomic, readonly) NSUInteger exchangesStarted;
// What the service is, in a line: entities, operations, version.
- (NSString *)summary;

// The Store menu's choices. On a conflict: 0 the save fails, 1 my changes
// win, 2 the service's win; applied to the context at once. The other two
// take effect on the next connection.
@property (nonatomic) NSInteger mergePolicy;
// Credentials for a service that asks for a sign-in (an ODataSignIn),
// taken at the next connection; nil: none.
@property (nonatomic, strong, nullable) id<ODataCredentialProviding> credentialProvider;
@property (nonatomic) BOOL respondAsync;
@property (nonatomic) BOOL JSONBatch;

@end

NS_ASSUME_NONNULL_END
