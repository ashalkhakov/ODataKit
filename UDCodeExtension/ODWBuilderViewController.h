// An .odataq document's tab (ODWBuilder.xib): a query built with the
// Workbench's query panel (WBQueryPanel) against a service of the window's,
// as the SQL mode's query by example is built: the document's text is the
// query (JSON: the service's name, and the query as WBQuery's -dictionary
// says it), each change of the panel's written into it, so undo, saving and
// diffs are UDCode's; the text changed otherwise is read into the panel
// again. Execute, and UDCode's Editor > Run, send its GET to the service; the
// answer is the bottom area's Results.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ODWServices, ODWService, WBQueryPanel, UDCodeDocument;

@interface ODWBuilderViewController : NSViewController
- (instancetype)initWithServices:(ODWServices *)services document:(UDCodeDocument *)document NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, readonly) UDCodeDocument *document;
@property (nonatomic, weak, readonly) ODWServices *services;
// The service it is built against (its text's), connected when the tab is
// shown; nil until one is chosen.
@property (nonatomic, readonly, nullable) ODWService *service;
// The panel, once the service is connected.
@property (nonatomic, readonly, nullable) WBQueryPanel *panel;

@property (nonatomic, weak, readonly) NSPopUpButton *servicePopup;
@property (nonatomic, weak, readonly) NSButton *connectButton;
@property (nonatomic, weak, readonly) NSTextField *statusLabel;

// The text that keeps a query for a service: what a new builder document
// starts as.
+ (NSString *)textOfQuery:(NSDictionary *)query service:(nullable NSString *)service;
// The query's GET sent (the panel's Execute, Editor > Run).
- (IBAction)runFetch:(nullable id)sender;
- (IBAction)serviceChosen:(nullable id)sender;
- (IBAction)connectService:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
