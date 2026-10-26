// HSLog — what a server says as it runs, beside its access log: a line per
// message, as text or as JSON, with the request it is about (its request
// id, trace id and span id), so a log collector puts it with the request's
// other lines and its trace.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   HSLogMessage(HSLogLevelWarn, @"Billing", request, @"card declined for %@", order);
//
// As text: Billing: warning: card declined for 42 (request_id=..., trace_id=...)
// As JSON: {"time": ..., "level": "warn", "component": "Billing",
//           "message": "card declined for 42", "request_id": ..., "trace_id": ..., "span_id": ...}

#pragma once
#import <Foundation/Foundation.h>

@class HSRequest;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, HSLogLevel) {
  HSLogLevelDebug,
  HSLogLevelInfo,
  HSLogLevelWarn,
  HSLogLevelError,
};

typedef NS_ENUM(NSInteger, HSLogFormat) {
  HSLogFormatText,
  HSLogFormatJSON,
};

// Thread-safe. Lines below level are not written (nor made: ask
// -logsLevel: before making an expensive one).
@interface HSLog : NSObject
// The process's: what the application configures (LogLevel, LogFormat),
// and what libraries write to.
@property (class, atomic, strong, null_resettable) HSLog *sharedLog;
@property (atomic) HSLogLevel level;    // default: info
@property (atomic) HSLogFormat format;  // default: text
- (BOOL)logsLevel:(HSLogLevel)level;
// component: who says it (ODataService, the application's name). fields:
// more for a JSON line's members, and after a text line's message.
- (void)log:(HSLogLevel)level component:(NSString *)component message:(NSString *)message
     fields:(nullable NSDictionary<NSString *, id> *)fields;
// request_id, trace_id and span_id of a request, those it has.
+ (NSDictionary<NSString *, id> *)fieldsOfRequest:(nullable HSRequest *)request;
// The same from a request's headers, as a library behind the server sees
// them (X-Request-ID, traceparent).
+ (NSDictionary<NSString *, id> *)fieldsOfHeaders:(nullable NSDictionary<NSString *, NSString *> *)headers;
// Every line, the access log's too: to standard error. A subclass sends
// them elsewhere (it must not wait).
- (void)writeLine:(NSString *)line;
// debug, info, warn (or warning), error; nil for another name.
+ (nullable NSNumber *)levelNamed:(NSString *)name;
@end

/* HTTPServerKit's own: exported where HTTPServerKit is built for Windows (its
   GNUmakefile), imported everywhere else, as FOUNDATION_EXPORT. */
#ifndef HTTPSERVERKIT_EXPORT
#define HTTPSERVERKIT_EXPORT FOUNDATION_EXPORT
#endif

HTTPSERVERKIT_EXPORT void HSLogMessage(HSLogLevel level, NSString *component, HSRequest *_Nullable request, NSString *format, ...)
    NS_FORMAT_FUNCTION(4, 5);

NS_ASSUME_NONNULL_END
