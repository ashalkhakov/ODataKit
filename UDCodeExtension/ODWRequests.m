// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWRequests.h"

@interface ODWRequest ()
@property (nonatomic, readwrite, copy) NSString *method;
@property (nonatomic, readwrite, copy) NSString *target;
@property (nonatomic, readwrite, copy) NSArray<NSArray<NSString *> *> *headers;
@property (nonatomic, readwrite, copy, nullable) NSString *body;
@property (nonatomic, readwrite) NSRange range;
@property (nonatomic, readwrite) NSUInteger line;
@property (nonatomic, copy, nullable) NSString *name;
@end

@implementation ODWRequest

- (NSString *)title
{
  return _name.length ? _name : [NSString stringWithFormat:@"%@ %@", _method, _target];
}

- (NSURLRequest *)URLRequestWithServiceRoot:(NSURL *)root error:(NSString **)error
{
  // A root ends in a slash, so that a relative URL goes on from it.
  NSString *rootText = root.absoluteString;
  NSURL *base = [rootText hasSuffix:@"/"] ? root : [NSURL URLWithString:[rootText stringByAppendingString:@"/"]];
  NSString *target = _target;
  // An OData filter is written with spaces and quotes: encoded as a URL has
  // them, what is encoded already (%20) left so.
  NSURL *url = [NSURL URLWithString:target relativeToURL:base];
  if (!url) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"%"];
    url = [NSURL URLWithString:[target stringByAddingPercentEncodingWithAllowedCharacters:allowed] relativeToURL:base];
  }
  url = url.absoluteURL;
  if (!url.scheme.length || !url.host.length) {
    if (error) *error = [NSString stringWithFormat:@"%@ is not a URL.", target];
    return nil;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = _method;
  for (NSArray<NSString *> *header in _headers) [request setValue:header[1] forHTTPHeaderField:header[0]];
  if (_body.length) {
    request.HTTPBody = [_body dataUsingEncoding:NSUTF8StringEncoding];
    if (![request valueForHTTPHeaderField:@"Content-Type"]) [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  if (![request valueForHTTPHeaderField:@"Accept"]) [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  return request;
}

@end

static NSSet<NSString *> *ODWMethods(void)
{
  static NSSet *methods;
  if (!methods) methods = [NSSet setWithObjects:@"GET", @"POST", @"PUT", @"PATCH", @"MERGE", @"DELETE", @"HEAD", @"OPTIONS", nil];
  return methods;
}

static BOOL ODWIsComment(NSString *trimmed)
{
  return [trimmed hasPrefix:@"//"] || ([trimmed hasPrefix:@"#"] && ![trimmed hasPrefix:@"###"]);
}

NSArray<ODWRequest *> *ODWRequestsOfText(NSString *text)
{
  NSMutableArray<ODWRequest *> *requests = [NSMutableArray array];
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  // The part being read: where it began, its name, and how far it has got.
  enum { ODWBefore, ODWQuery, ODWHeaders, ODWBody } phase = ODWBefore;
  __block NSUInteger partStart = 0, end = 0;
  NSUInteger lineNumber = 0;
  NSString *name = nil;
  __block ODWRequest *request = nil;
  __block NSMutableArray *headers = nil;
  __block NSMutableArray<NSString *> *body = nil;

  void (^close)(void) = ^{
    if (!request) return;
    // A body's blank lines at its end are not its.
    while (body.count && ![[body.lastObject stringByTrimmingCharactersInSet:space] length]) [body removeLastObject];
    request.headers = headers;
    request.body = body.count ? [body componentsJoinedByString:@"\n"] : nil;
    request.range = NSMakeRange(partStart, MAX(end, partStart) - partStart);
    [requests addObject:request];
  };

  NSUInteger length = text.length, start = 0;
  while (start <= length) {
    NSRange lineRange = [text lineRangeForRange:NSMakeRange(MIN(start, length), 0)];
    NSUInteger contentsEnd = 0;
    [text getLineStart:NULL end:NULL contentsEnd:&contentsEnd forRange:lineRange];
    NSString *line = [text substringWithRange:NSMakeRange(lineRange.location, contentsEnd - lineRange.location)];
    NSString *trimmed = [line stringByTrimmingCharactersInSet:space];
    lineNumber++;

    if ([trimmed hasPrefix:@"###"]) {
      close();
      request = nil;
      phase = ODWBefore;
      partStart = lineRange.location;
      end = contentsEnd;
      NSString *rest = [[trimmed substringFromIndex:3] stringByTrimmingCharactersInSet:space];
      name = rest.length ? rest : nil;
    } else if (phase == ODWBefore) {
      if (trimmed.length && !ODWIsComment(trimmed)) {
        // The request line: METHOD URL [HTTP/1.1], or the URL alone.
        NSMutableArray *words = [[trimmed componentsSeparatedByCharactersInSet:space] mutableCopy];
        [words removeObject:@""];
        if (words.count > 1 && [[words.lastObject uppercaseString] hasPrefix:@"HTTP/"]) [words removeLastObject];
        request = [[ODWRequest alloc] init];
        if (words.count > 1 && [ODWMethods() containsObject:[words[0] uppercaseString]]) {
          request.method = [words[0] uppercaseString];
          [words removeObjectAtIndex:0];
        } else {
          request.method = @"GET";
        }
        request.target = [words componentsJoinedByString:@" "];
        request.line = lineNumber;
        request.name = name;
        if (!name) partStart = lineRange.location;
        headers = [NSMutableArray array];
        body = [NSMutableArray array];
        end = contentsEnd;
        phase = ODWQuery;
      }
    } else if (phase == ODWQuery && ([trimmed hasPrefix:@"?"] || [trimmed hasPrefix:@"&"])) {
      request.target = [request.target stringByAppendingString:trimmed];
      end = contentsEnd;
    } else if (phase == ODWQuery || phase == ODWHeaders) {
      if (!trimmed.length) {
        phase = ODWBody;
      } else if (ODWIsComment(trimmed)) {
        // a comment among the headers
      } else {
        NSRange colon = [trimmed rangeOfString:@":"];
        if (colon.location != NSNotFound && colon.location > 0) {
          NSString *header = [[trimmed substringToIndex:colon.location] stringByTrimmingCharactersInSet:space];
          NSString *value = [[trimmed substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:space];
          [headers filterUsingPredicate:[NSPredicate predicateWithFormat:@"NOT (SELF[0] ==[c] %@)", header]];
          [headers addObject:@[ header, value ]];
          end = contentsEnd;
          phase = ODWHeaders;
        } else {
          // No blank line before the body: it begins here.
          phase = ODWBody;
          [body addObject:line];
          end = contentsEnd;
        }
      }
    } else {
      [body addObject:line];
      if (trimmed.length) end = contentsEnd;
    }

    if (NSMaxRange(lineRange) <= start || NSMaxRange(lineRange) >= length) break;
    start = NSMaxRange(lineRange);
  }
  close();
  return requests;
}

ODWRequest *ODWRequestAt(NSString *text, NSUInteger location)
{
  ODWRequest *before = nil;
  for (ODWRequest *request in ODWRequestsOfText(text)) {
    if (location >= request.range.location && location <= NSMaxRange(request.range)) return request;
    if (request.range.location <= location) before = request;
  }
  return before;
}
