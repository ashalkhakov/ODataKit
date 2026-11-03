// UDCode's OData Workbench extension (docs/UDCODE.md): OData v4 services in
// UDCode, as the Workbench app tries them. The OData navigator lists the
// window's services (the Workbench's built-in sample, Northwind, TripPin,
// the project's and the user's: ODWServices), each with what it serves once
// connected; .odataq documents are requests built in a builder
// (ODWBuilderViewController), sent with its Execute and UDCode's Editor >
// Run (⌘↩) to the service chosen for them; the answers, the wire log and
// traces are its segment of the bottom area (ODWBottomViewController).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <AppKit/AppKit.h>
#import <UDCodeKit/UDExtension.h>

NS_ASSUME_NONNULL_BEGIN

@class ODWServices;

@interface ODWExtension : NSObject <UDExtension>
// A window's services, made the first time they are asked for.
- (ODWServices *)servicesOf:(id<UDWorkbench>)workbench;
@end

NS_ASSUME_NONNULL_END
