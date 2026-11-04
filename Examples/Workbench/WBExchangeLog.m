// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBExchangeLog.h"

// A body as it went: its text where it is UTF-8, else a hex dump.
static NSString *WBRawBody(NSData *data)
{
  if (!data.length) return @"";
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (text) return text;
  NSMutableString *dump = [NSMutableString stringWithFormat:@"(%lu bytes, not UTF-8 text)\n", (unsigned long)data.length];
  const unsigned char *bytes = data.bytes;
  for (NSUInteger offset = 0; offset < data.length; offset += 16) {
    NSMutableString *hex = [NSMutableString string], *ascii = [NSMutableString string];
    for (NSUInteger i = offset; i < offset + 16; i++) {
      if (i < data.length) {
        [hex appendFormat:@"%02x ", bytes[i]];
        [ascii appendFormat:@"%c", bytes[i] >= 32 && bytes[i] < 127 ? bytes[i] : '.'];
      } else {
        [hex appendString:@"   "];
      }
    }
    [dump appendFormat:@"%08lx  %@ |%@|\n", (unsigned long)offset, hex, ascii];
  }
  return dump;
}

static NSString *WBRawHeaders(NSDictionary *headers)
{
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
    [text appendFormat:@"%@: %@\n", name, headers[name]];
  }
  return text;
}

@implementation WBExchangeLog {
  NSMutableArray<WorkbenchLogEntry *> *_entries;
}

- (instancetype)init
{
  if (!(self = [super init])) return nil;
  _entries = [NSMutableArray array];
  _limit = 1000;
  return self;
}

- (NSArray<WorkbenchLogEntry *> *)entries
{
  return [_entries copy];
}

- (void)addEntry:(WorkbenchLogEntry *)entry
{
  [_entries insertObject:entry atIndex:0];
  while (_entries.count > _limit) [_entries removeLastObject];
}

- (void)clear
{
  [_entries removeAllObjects];
}

- (WorkbenchLogEntry *)entryAtRow:(NSInteger)row
{
  return row >= 0 && (NSUInteger)row < _entries.count ? _entries[(NSUInteger)row] : nil;
}

- (NSString *)valueForColumn:(NSString *)identifier row:(NSInteger)row
{
  WorkbenchLogEntry *entry = [self entryAtRow:row];
  if (!entry) return nil;
  if ([identifier isEqualToString:@"time"]) {
    static NSDateFormatter *format;
    if (!format) {
      format = [[NSDateFormatter alloc] init];
      format.dateFormat = @"HH:mm:ss.SSS";
    }
    return entry.date ? [format stringFromDate:entry.date] : @"";
  }
  if ([identifier isEqualToString:@"method"]) return entry.method;
  if ([identifier isEqualToString:@"status"]) return entry.status ? [NSString stringWithFormat:@"%ld", (long)entry.status] : @"—";
  // The URL from the service root on, decoded to be read.
  NSString *url = entry.URL;
  NSString *root = _serviceRoot.absoluteString;
  if (root.length && [url hasPrefix:root]) url = [url substringFromIndex:root.length];
  return [url stringByRemovingPercentEncoding] ?: url;
}

+ (NSString *)reasonOfStatus:(NSInteger)status
{
  // HTTP's own reason phrases: Foundation's localized ones say "no error".
  static NSDictionary *reasons;
  if (!reasons) {
    reasons = @{ @200: @"OK", @201: @"Created", @202: @"Accepted", @204: @"No Content", @302: @"Found", @304: @"Not Modified",
                 @400: @"Bad Request", @401: @"Unauthorized", @403: @"Forbidden", @404: @"Not Found", @405: @"Method Not Allowed",
                 @406: @"Not Acceptable", @409: @"Conflict", @412: @"Precondition Failed", @415: @"Unsupported Media Type",
                 @428: @"Precondition Required", @500: @"Internal Server Error", @501: @"Not Implemented", @503: @"Service Unavailable" };
  }
  return reasons[@(status)] ?: [NSHTTPURLResponse localizedStringForStatusCode:status].capitalizedString ?: @"";
}

+ (NSString *)rawRequestOf:(WorkbenchLogEntry *)entry
{
  return [NSString stringWithFormat:@"%@ %@ HTTP/1.1\n%@\n%@", entry.method, entry.URL, WBRawHeaders(entry.requestHeaders),
                                    WBRawBody(entry.requestData)];
}

+ (NSString *)rawResponseOf:(WorkbenchLogEntry *)entry
{
  if (!entry.status) return [NSString stringWithFormat:@"(no answer: %@)", entry.failure ?: @"the request failed"];
  return [NSString stringWithFormat:@"HTTP/1.1 %ld %@\n%@\n%@", (long)entry.status, [self reasonOfStatus:entry.status],
                                    WBRawHeaders(entry.responseHeaders), WBRawBody(entry.responseData)];
}

@end
