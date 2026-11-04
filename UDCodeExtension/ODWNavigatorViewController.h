// The OData navigator (ODWNavigator.xib): a window's services
// (ODWServices), each with what it serves once connected (its entity sets,
// its functions and actions). Double-clicking a service connects to it;
// an entity set, a query of its rows, sent; an operation, its call, set
// up. A right click's menu is the row's: a service's (a new query builder,
// connect, sign out, edit, remove), an entity set's (a new query builder, a
// builder set up for a request of it: ODWTemplates; copy its name), a
// function's (a builder set up for its call).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ODWServices, ODWService;

@interface ODWNavigatorViewController : NSViewController <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
- (instancetype)initWithServices:(ODWServices *)services NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSNibName)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, weak, readonly) ODWServices *services;
@property (nonatomic, weak, readonly) NSOutlineView *outlineView;
// The service a row is (or is in), the selected one when row is -1.
- (nullable ODWService *)serviceAtRow:(NSInteger)row;

- (IBAction)addService:(nullable id)sender;
- (IBAction)editService:(nullable id)sender;
- (IBAction)removeService:(nullable id)sender;
- (IBAction)connectService:(nullable id)sender;
- (IBAction)refreshService:(nullable id)sender;
- (IBAction)disconnectService:(nullable id)sender;
- (IBAction)signOutOfService:(nullable id)sender;
// A new query document (.odataq), built against the service: of the entity
// set's entity, when it is one's.
- (IBAction)newQueryBuilder:(nullable id)sender;
// A new builder set up for a request of the item's: an entity set's (its
// sender's tag an ODWTemplate), an operation's call.
- (IBAction)insertRequestOfItem:(nullable id)sender;
- (IBAction)copyName:(nullable id)sender;
- (IBAction)openItem:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
