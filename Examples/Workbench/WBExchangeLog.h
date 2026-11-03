// The wire log: each exchange with the service, newest first, as a table
// shows it (its time, method, status and URL), and as it went over the wire
// (the raw request and response). No views: the Workbench's window shows it,
// and a host's pane.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#import <Foundation/Foundation.h>
#import "WorkbenchModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface WBExchangeLog : NSObject

// Newest first.
@property (nonatomic, readonly, copy) NSArray<WorkbenchLogEntry *> *entries;
// How many are kept (default 1000): the oldest go.
@property (nonatomic) NSUInteger limit;
// The service's root: a URL is shown from it on.
@property (nonatomic, copy, nullable) NSURL *serviceRoot;

- (void)addEntry:(WorkbenchLogEntry *)entry;
- (void)clear;
// The entry at a table's row; nil past the end.
- (nullable WorkbenchLogEntry *)entryAtRow:(NSInteger)row;
// A row's column as a table shows it, by the column's identifier: time,
// method, status, URL (from the service root on, decoded to be read).
- (nullable NSString *)valueForColumn:(NSString *)identifier row:(NSInteger)row;

// As it went: the request line, headers and body; the status line, headers
// and body (a body that is not UTF-8 as a hex dump), or why there was no
// answer.
+ (NSString *)rawRequestOf:(WorkbenchLogEntry *)entry;
+ (NSString *)rawResponseOf:(WorkbenchLogEntry *)entry;

@end

NS_ASSUME_NONNULL_END
