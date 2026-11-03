// An .odataq document's tab (ODWBuilder.xib): a request to a service of the
// window's, built as the SQL mode's query by example is: a query (the
// Workbench's query panel, WBQueryPanel; of one entity by its key, when the
// key is given), an entity created, updated or deleted (its key, a JSON
// body), a function or action called (its parameters). The document's text
// is the request (JSON: the service's name, the kind, and what the kind
// asks: the query as WBQuery's -dictionary says it, the entity set, the
// key, the body, the operation, the parameters), each change written into
// it, so undo, saving and diffs are UDCode's; the text changed otherwise is
// read again. Execute, and UDCode's Editor > Run, send it; the answer is
// the bottom area's Results. Show curl and Copy curl give it as a curl
// command.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ODWServices, ODWService, WBQueryPanel, UDCodeDocument;

// The kind popup's tags.
typedef NS_ENUM(NSInteger, ODWBuilderKind) {
  ODWBuilderQuery,
  ODWBuilderCreate,
  ODWBuilderUpdate,
  ODWBuilderDelete,
  ODWBuilderCall,
};

@interface ODWBuilderViewController : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate>
- (instancetype)initWithServices:(ODWServices *)services document:(UDCodeDocument *)document NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, readonly) UDCodeDocument *document;
@property (nonatomic, weak, readonly) ODWServices *services;
// The service it is sent to (its text's), connected when the tab is shown;
// nil until one is chosen.
@property (nonatomic, readonly, nullable) ODWService *service;
@property (nonatomic, readonly) ODWBuilderKind kind;
// The panel, once the service is connected (a query's).
@property (nonatomic, readonly, nullable) WBQueryPanel *panel;
// Sent as soon as the service is connected and the request shown (a double
// click on an entity set).
@property (nonatomic) BOOL executesWhenShown;

@property (nonatomic, weak, readonly) NSPopUpButton *servicePopup;
@property (nonatomic, weak, readonly) NSButton *connectButton;
@property (nonatomic, weak, readonly) NSTextField *statusLabel;
@property (nonatomic, weak, readonly) NSPopUpButton *kindPopup;
@property (nonatomic, weak, readonly) NSTextField *targetLabel;
@property (nonatomic, weak, readonly) NSPopUpButton *targetPopup;
@property (nonatomic, weak, readonly) NSView *fieldsSection;
@property (nonatomic, weak, readonly) NSTextField *fieldsLabel;
@property (nonatomic, weak, readonly) NSTableView *fieldsTable;
@property (nonatomic, weak, readonly) NSView *bodySection;
@property (nonatomic, readonly) NSTextView *bodyView;
@property (nonatomic, weak, readonly) NSScrollView *panelScroll;
@property (nonatomic, weak, readonly) NSTextField *requestLine;
@property (nonatomic, weak, readonly) NSButton *executeButton;

// The text that keeps a request (a file's dictionary: "request", "query",
// "entitySet", "key", "body", "operation", "parameters", as ODWTemplates
// makes them) for a service: what a new builder document starts as.
+ (NSString *)textOfFile:(NSDictionary *)file service:(nullable NSString *)service;
+ (NSString *)textOfQuery:(NSDictionary *)query service:(nullable NSString *)service;
// The request as it would be sent now; nil, and why, when it cannot be.
- (nullable NSURLRequest *)URLRequestWithFailure:(NSString *_Nullable *_Nullable)failure;
// Its request sent (Execute, Editor > Run).
- (IBAction)runFetch:(nullable id)sender;
- (IBAction)serviceChosen:(nullable id)sender;
- (IBAction)connectService:(nullable id)sender;
- (IBAction)kindChosen:(nullable id)sender;
- (IBAction)targetChosen:(nullable id)sender;
// Its request as curl: in a new shell document; on the clipboard.
- (IBAction)showCurl:(nullable id)sender;
- (IBAction)copyCurl:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
