// A UDCode window's OData services (one of these a window, ODWExtension's),
// as the SQL mode keeps its databases:
//
// - the Workbench's own: the built-in sample service (in this process, no
//   network), Northwind (read-only) and TripPin (a session of its own);
// - the project's, in its .udcode/settings.json ("odataServices": a name
//   and a service root, never a secret), shared with the folder;
// - the user's, every project's (the user's defaults).
//
// Each is connected when first wanted (its $metadata read, a sign-in asked
// for when it wants one: WBSignInPanel), its tokens or password kept in
// the system's store (UDCredentialStore). An .odataq document's builder
// sends its request to the service chosen for it; the answers go to the
// bottom area's Results, every exchange to the Wire Log, every request's
// spans to Traces.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>
#import <UDCodeKit/UDCodeKit.h>
#import "WBConnection.h"
#import "WBExchangeLog.h"
#import "WBTraces.h"

NS_ASSUME_NONNULL_BEGIN

@class ODWServices;

// Posted when a service is added, removed, changed, connected or not;
// object: the ODWServices.
FOUNDATION_EXPORT NSNotificationName const ODWServicesDidChangeNotification;
// A document's service chosen; object: the UDCodeDocument.
FOUNDATION_EXPORT NSNotificationName const ODWDocumentServiceDidChangeNotification;
// An exchange added to the wire log; object: the ODWServices.
FOUNDATION_EXPORT NSNotificationName const ODWExchangeLogDidChangeNotification;
// A request's answer come (or its failure); object: the ODWServices,
// userInfo ODWAnswerKey: the ODWAnswer.
FOUNDATION_EXPORT NSNotificationName const ODWAnswerNotification;
FOUNDATION_EXPORT NSString *const ODWAnswerKey;

// The kinds of service.
typedef NS_ENUM(NSInteger, ODWServiceKind) {
  ODWServiceBuiltIn = WBServiceBuiltIn,
  ODWServiceNorthwind = WBServiceNorthwind,
  ODWServiceTripPin = WBServiceTripPin,
  ODWServiceOther = WBServiceOther,
};

// A service the window knows, and how it is.
@interface ODWService : NSObject
@property (nonatomic, copy) NSString *name;
// Its service root.
@property (nonatomic, copy) NSURL *root;
@property (nonatomic, readonly) ODWServiceKind kind;
// The Workbench's own: always there, not edited or removed.
@property (nonatomic, readonly, getter=isPreset) BOOL preset;
// Kept in the project's settings (else the user's).
@property (nonatomic) BOOL inProject;
@property (nonatomic, readonly, nullable) WBConnection *connection;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly, getter=isConnecting) BOOL connecting;
// Why the last connection failed; nil when it did not.
@property (nonatomic, readonly, copy, nullable) NSString *failure;
// What it serves, once connected: its entity sets, and the functions and
// actions of its container (its operation imports), each sorted.
- (NSArray<NSString *> *)entitySetNames;
- (NSArray<NSString *> *)operationNames;
@end

// A request sent, and what came back.
@interface ODWAnswer : NSObject
@property (nonatomic, readonly) ODWService *service;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) NSURLRequest *request;
// 0: no answer (see failure).
@property (nonatomic, readonly) NSInteger status;
@property (nonatomic, readonly, copy, nullable) NSData *data;
@property (nonatomic, readonly, copy, nullable) NSString *failure;
@property (nonatomic, readonly) NSTimeInterval duration;
// The answer read as JSON: its rows (a collection's value, or the one
// entity), each a dictionary; nil when it is none.
@property (nonatomic, readonly, copy, nullable) NSArray<NSDictionary *> *rows;
// The rows' properties, in the order the first row has them; annotations
// (@odata.etag, …) last.
@property (nonatomic, readonly, copy) NSArray<NSString *> *columns;
// The body as text: JSON indented, else as it came.
@property (nonatomic, readonly, copy) NSString *text;
@end

@interface ODWServices : NSObject

- (instancetype)initWithWorkbench:(id<UDWorkbench>)workbench NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, weak, readonly) id<UDWorkbench> workbench;
// The extension it is of: its segment of the bottom area (the answers, the
// wire log, traces).
@property (nonatomic, weak, nullable) id<UDExtension> extension;
// What its segment shows, made by the extension (ODWBottomViewController).
@property (nonatomic, strong, nullable) NSViewController *bottomPane;

// The presets first, then the project's, then the user's.
@property (nonatomic, readonly, copy) NSArray<ODWService *> *services;
- (nullable ODWService *)serviceNamed:(NSString *)name;
// A service of the user's or the project's added (kept where it says), or
// put in place of the one of its name.
- (void)addService:(ODWService *)service;
- (void)removeService:(ODWService *)service;
// A new one, for -addService: (a name and root to be set).
+ (ODWService *)serviceNamed:(NSString *)name root:(NSURL *)root inProject:(BOOL)inProject;

// Connected: its $metadata read, signed in first when it asks (the panel
// beside the window); told by ODWServicesDidChangeNotification.
- (void)connect:(ODWService *)service;
- (void)disconnect:(ODWService *)service;
// Its tokens or password forgotten, and disconnected.
- (void)signOut:(ODWService *)service;

// The service a document sends its request to: the one chosen for it, else
// the only one connected, else none.
- (nullable ODWService *)serviceOfDocument:(UDCodeDocument *)document;
- (void)setService:(nullable ODWService *)service ofDocument:(UDCodeDocument *)document;

// A request (the builder's), titled, to a service that is connected; its
// answer told by ODWAnswerNotification.
- (void)sendURLRequest:(NSURLRequest *)request title:(NSString *)title toService:(ODWService *)service;
// The next builder made (a document being opened) sends its request as
// soon as it is shown (a double click on an entity set); it sets it back.
@property (nonatomic) BOOL executesNextBuilder;
// The last answer, for the Results pane opened later.
@property (nonatomic, readonly, nullable) ODWAnswer *lastAnswer;

// Every exchange with the services, newest first.
@property (nonatomic, readonly) WBExchangeLog *exchangeLog;
// The process's traces (one recorder, every window's).
+ (WBTraceRecorder *)traceRecorder;

@end

NS_ASSUME_NONNULL_END
