// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataResourceIdentifier.h"
#include <string.h>

NSString *OISKeyLiteral(id value)
{
  if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
  if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
  NSString *s = [value description];
  s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
  return [NSString stringWithFormat:@"'%@'", s];
}

static NSString *OISPathEncode(NSString *literal);

@implementation ODataResourceIdentifier

- (instancetype)initWithEntitySet:(NSString *)entitySet keys:(NSDictionary *)keys
{
  self = [super init];
  if (!self) return nil;
  _entitySet = [entitySet copy];
  _keys = [keys copy] ?: @{};
  _unquotedKeys = [NSSet set];
  return self;
}

// A key as a segment where it reads as nothing else (Part 2 section
// 4.3.6): not one a service could read as a cast or an operation (a '.',
// as in an email address or a decimal), a system segment ('$'), a path
// ('/'), a key predicate or a call ('(', ')'), or no segment at all (empty).
// Those go in parentheses, Set('anna@example.org'), which every service
// reads alike (#47).
- (NSString *)pathWithKeyAsSegment:(BOOL)keyAsSegment
{
  if (!keyAsSegment || self.keys.count != 1) return self.path;
  id value = self.keys.allValues.firstObject;
  NSString *bare = [value isKindOfClass:[NSString class]] ? value : OISKeyLiteral(value);
  static NSCharacterSet *ambiguous;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ambiguous = [NSCharacterSet characterSetWithCharactersInString:@"./$()"];
  });
  if (!bare.length || [bare rangeOfCharacterFromSet:ambiguous].location != NSNotFound) return self.path;
  return [NSString stringWithFormat:@"%@/%@", self.entitySet, OISPathEncode(bare)];
}

- (NSString *)path
{
  if (self.keys.count == 1) {
    NSString *name = self.keys.allKeys.firstObject;
    return [NSString stringWithFormat:@"%@(%@)", self.entitySet, [self literalForKey:name]];
  }
  NSMutableArray *parts = [NSMutableArray array];
  NSArray *names = [self.keys.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    [parts addObject:[NSString stringWithFormat:@"%@=%@", name, [self literalForKey:name]]];
  }
  return [NSString stringWithFormat:@"%@(%@)", self.entitySet, [parts componentsJoinedByString:@","]];
}

// A literal as it goes into a path segment: percent-encoded, except for
// what RFC 3986 allows in a segment and OData's key syntax uses (quotes,
// parentheses, '=' and ','). A key with a space, '/', '#', '?' or
// non-ASCII text used to make an invalid URL, or the wrong one.
static NSString *OISPathEncode(NSString *literal)
{
  static const char hex[] = "0123456789ABCDEF";
  NSData *data = [literal dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *bytes = data.bytes;
  NSMutableString *out = [NSMutableString stringWithCapacity:data.length];
  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char c = bytes[i];
    BOOL keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                (c != 0 && strchr("-._~'()=,:@!$*;", c) != NULL);
    if (keep) [out appendFormat:@"%c", c];
    else [out appendFormat:@"%%%c%c", hex[c >> 4], hex[c & 15]];
  }
  return out;
}

- (NSString *)literalForKey:(NSString *)name
{
  id value = self.keys[name];
  if ([self.unquotedKeys containsObject:name] && [value isKindOfClass:[NSString class]]) return OISPathEncode(value);
  return OISPathEncode(OISKeyLiteral(value));
}

// "unquoted" only when there are any, so the reference of an object with
// plain keys, and so its object ID, is what it always was.
- (NSDictionary *)dictionary
{
  if (!self.unquotedKeys.count) return @{ @"set": self.entitySet, @"keys": self.keys };
  NSArray *unquoted = [self.unquotedKeys.allObjects sortedArrayUsingSelector:@selector(compare:)];
  return @{ @"set": self.entitySet, @"keys": self.keys, @"unquoted": unquoted };
}

- (NSData *)data
{
  NSJSONWritingOptions opts = 0;
#ifdef NSJSONWritingSortedKeys
  opts = NSJSONWritingSortedKeys;
#endif
  return [NSJSONSerialization dataWithJSONObject:self.dictionary options:opts error:nil] ?: [NSData data];
}

+ (instancetype)identifierFromReference:(id)ref
{
  if ([ref isKindOfClass:[ODataResourceIdentifier class]]) return ref;
  if ([ref isKindOfClass:[NSData class]]) {
    id json = [NSJSONSerialization JSONObjectWithData:ref options:0 error:nil];
    return [self identifierFromReference:json];
  }
  if ([ref isKindOfClass:[NSDictionary class]]) {
    NSDictionary *d = ref;
    if (d[@"set"] && d[@"keys"]) {
      ODataResourceIdentifier *identifier = [[ODataResourceIdentifier alloc] initWithEntitySet:d[@"set"] keys:d[@"keys"]];
      if ([d[@"unquoted"] isKindOfClass:[NSArray class]]) identifier.unquotedKeys = [NSSet setWithArray:d[@"unquoted"]];
      return identifier;
    }
  }
  return nil;
}

@end
