// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWTemplates.h"
#import "ODWRequests.h"
#import <ODataKit/ODataSchema.h>

// A sample value of an Edm type, as JSON (in a body) or as a URL literal
// (a key, a function's parameter).
static id ODWSample(ODataSchema *schema, NSString *type, NSUInteger depth)
{
  if ([type hasPrefix:@"Collection("]) return @[];
  if ([type isEqualToString:@"Edm.String"]) return @"text";
  if ([type isEqualToString:@"Edm.Boolean"]) return @NO;
  if ([type isEqualToString:@"Edm.Guid"]) return @"00000000-0000-0000-0000-000000000000";
  if ([type isEqualToString:@"Edm.Date"]) return @"2024-01-01";
  if ([type isEqualToString:@"Edm.DateTimeOffset"]) return @"2024-01-01T00:00:00Z";
  if ([type isEqualToString:@"Edm.TimeOfDay"]) return @"12:00:00";
  if ([type isEqualToString:@"Edm.Duration"]) return @"PT1H";
  if ([type isEqualToString:@"Edm.Binary"]) return @"";
  if ([@[ @"Edm.Byte", @"Edm.SByte", @"Edm.Int16", @"Edm.Int32", @"Edm.Int64" ] containsObject:type]) return @1;
  if ([@[ @"Edm.Decimal", @"Edm.Double", @"Edm.Single" ] containsObject:type]) return @1.5;
  ODataSchemaEnumType *enumType = [schema enumTypeNamed:type];
  if (enumType) return enumType.memberNames.firstObject ?: @"";
  ODataSchemaComplexType *complex = [schema complexTypeNamed:type];
  if (complex && depth < 3) {
    NSMutableDictionary *value = [NSMutableDictionary dictionary];
    [[schema propertiesOfComplexType:complex] enumerateKeysAndObjectsUsingBlock:^(NSString *name, ODataSchemaProperty *property, BOOL *stop) {
      value[name] = ODWSample(schema, property.type, depth + 1);
    }];
    return value;
  }
  return [NSNull null];
}

static NSString *ODWLiteral(ODataSchema *schema, NSString *type)
{
  id sample = ODWSample(schema, type, 0);
  if ([type isEqualToString:@"Edm.String"]) return @"'text'";
  if ([schema enumTypeNamed:type]) return [NSString stringWithFormat:@"%@'%@'", [schema qualifiedName:type], sample];
  if ([sample isKindOfClass:[NSNumber class]]) {
    return [type isEqualToString:@"Edm.Boolean"] ? ([sample boolValue] ? @"true" : @"false") : [sample stringValue];
  }
  if ([sample isKindOfClass:[NSString class]]) return sample;
  if ([sample isKindOfClass:[NSArray class]]) return @"[]";
  return @"null";
}

// The type and its base types, the base first.
static NSArray<ODataSchemaEntityType *> *ODWLineage(ODataSchema *schema, ODataSchemaEntityType *type)
{
  NSMutableArray *lineage = [NSMutableArray array];
  for (ODataSchemaEntityType *at = type; at && lineage.count < 16; at = at.baseType ? [schema entityTypeNamed:at.baseType] : nil) {
    [lineage insertObject:at atIndex:0];
  }
  return lineage;
}

// Set(1), Set(Order=1,Line=2): the key's sample.
static NSString *ODWKeyed(ODataSchema *schema, NSString *set, ODataSchemaEntityType *type)
{
  NSArray<NSString *> *key = [schema keyOfEntityType:type];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *name in key) {
    NSString *literal = ODWLiteral(schema, [schema property:name ofEntityType:type].type ?: @"Edm.String");
    [parts addObject:key.count == 1 ? literal : [NSString stringWithFormat:@"%@=%@", name, literal]];
  }
  return [NSString stringWithFormat:@"%@(%@)", set, [parts componentsJoinedByString:@","]];
}

// A value as JSON, on one line: [v] written, its brackets taken off.
static NSString *ODWJSONValue(id value)
{
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ] options:0 error:NULL];
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[null]";
  text = [text stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
  return [text substringWithRange:NSMakeRange(1, text.length - 2)];
}

// A JSON object of these names' values, a name a line, in this order.
static NSString *ODWJSONObject(NSArray<NSString *> *names, NSArray *values)
{
  if (!names.count) return @"{}";
  NSMutableArray *lines = [NSMutableArray array];
  for (NSUInteger i = 0; i < names.count; i++) {
    [lines addObject:[NSString stringWithFormat:@"  %@: %@", ODWJSONValue(names[i]), ODWJSONValue(values[i])]];
  }
  return [NSString stringWithFormat:@"{\n%@\n}", [lines componentsJoinedByString:@",\n"]];
}

// The entity's properties as a body: in the order their types declare
// them (a base's first), names sorted within a type; computed ones, and
// streams, left out; the key too, when asked.
static NSString *ODWBody(ODataSchema *schema, ODataSchemaEntityType *type, BOOL withKey)
{
  NSArray<NSString *> *key = [schema keyOfEntityType:type];
  NSMutableArray *names = [NSMutableArray array], *values = [NSMutableArray array];
  for (ODataSchemaEntityType *at in ODWLineage(schema, type)) {
    for (NSString *name in [at.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *property = at.declaredProperties[name];
      if ([property.elementType isEqualToString:@"Edm.Stream"]) continue;
      if (!withKey && [key containsObject:name]) continue;
      if ([[schema annotation:@"Core.Computed" forProperty:name ofEntityType:type] boolValue]) continue;
      [names addObject:name];
      [values addObject:ODWSample(schema, property.type, 0)];
    }
  }
  return ODWJSONObject(names, values);
}

NSString *ODWTemplateOfEntitySet(ODataSchema *schema, NSString *set, ODWTemplate kind)
{
  NSString *typeName = schema.entitySets[set];
  ODataSchemaEntityType *type = typeName ? [schema entityTypeNamed:typeName] : nil;
  if (!type) return nil;
  NSString *json = @"Content-Type: application/json\n\n";
  switch (kind) {
  case ODWTemplateGetAll:
    return [NSString stringWithFormat:@"### %@\nGET %@?$top=20\n", set, set];
  case ODWTemplateGetByKey:
    return [NSString stringWithFormat:@"### One of %@, by its key\nGET %@\n", set, ODWKeyed(schema, set, type)];
  case ODWTemplateCount:
    return [NSString stringWithFormat:@"### How many %@\nGET %@/$count\n", set, set];
  case ODWTemplatePost:
    return [NSString stringWithFormat:@"### A new one of %@\nPOST %@\n%@%@\n", set, set, json, ODWBody(schema, type, YES)];
  case ODWTemplatePatch:
    return [NSString stringWithFormat:@"### One of %@ changed\nPATCH %@\n%@%@\n", set, ODWKeyed(schema, set, type), json,
                                      ODWBody(schema, type, NO)];
  case ODWTemplateDelete:
    return [NSString stringWithFormat:@"### One of %@ deleted\nDELETE %@\n", set, ODWKeyed(schema, set, type)];
  }
  return nil;
}

NSString *ODWTemplateOfOperation(ODataSchema *schema, NSString *name)
{
  ODataSchemaOperationImport *import = schema.operationImports[name];
  if (!import) return nil;
  // The unbound overload: the import's.
  ODataSchemaOperation *operation = nil;
  for (ODataSchemaOperation *overload in schema.operations[[schema qualifiedName:import.operation]]) {
    if (!overload.isBound) {
      operation = overload;
      break;
    }
  }
  NSArray<ODataSchemaParameter *> *parameters = operation.callerParameters ?: @[];
  if (import.isAction) {
    NSMutableArray *names = [NSMutableArray array], *values = [NSMutableArray array];
    for (ODataSchemaParameter *parameter in parameters) {
      [names addObject:parameter.name];
      [values addObject:ODWSample(schema, parameter.type, 0)];
    }
    return [NSString stringWithFormat:@"### %@ (an action)\nPOST %@\nContent-Type: application/json\n\n%@\n", name, name,
                                      ODWJSONObject(names, values)];
  }
  NSMutableArray *arguments = [NSMutableArray array];
  for (ODataSchemaParameter *parameter in parameters) {
    [arguments addObject:[NSString stringWithFormat:@"%@=%@", parameter.name, ODWLiteral(schema, parameter.type)]];
  }
  return [NSString stringWithFormat:@"### %@ (a function)\nGET %@(%@)\n", name, name, [arguments componentsJoinedByString:@","]];
}

NSString *ODWTextWithTemplate(NSString *text, NSUInteger caret, NSString *request, NSRange *requestRange)
{
  caret = MIN(caret, text.length);
  // Inside a request: after it; at its start, before it; elsewhere (a
  // comment, a blank line), at the start of the caret's line.
  ODWRequest *around = ODWRequestAt(text, caret);
  NSUInteger at = caret;
  if (around && caret > around.range.location && caret <= NSMaxRange(around.range)) at = NSMaxRange(around.range);
  NSRange line = [text lineRangeForRange:NSMakeRange(at, 0)];
  if (at > line.location) at = NSMaxRange(line);
  else if (!around || caret != around.range.location) at = line.location;
  NSString *before = [text substringToIndex:at], *after = [text substringFromIndex:at];
  if (before.length && ![before hasSuffix:@"\n"]) before = [before stringByAppendingString:@"\n"];
  NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  // A blank line between it and what is before; what is after it kept
  // apart by a separator (its own, or one put in).
  NSString *lead = [before stringByTrimmingCharactersInSet:space].length && ![before hasSuffix:@"\n\n"] ? @"\n" : @"";
  NSString *trimmedAfter = [after stringByTrimmingCharactersInSet:space];
  NSString *tail = !trimmedAfter.length ? @"" : [trimmedAfter hasPrefix:@"###"] ? @"\n" : @"\n###\n";
  if (requestRange) {
    NSRange separator = [request rangeOfString:@"\n"];
    NSUInteger start = before.length + lead.length + ([request hasPrefix:@"###"] && separator.location != NSNotFound ? NSMaxRange(separator) : 0);
    *requestRange = NSMakeRange(start, before.length + lead.length + request.length - start);
  }
  return [NSString stringWithFormat:@"%@%@%@%@%@", before, lead, request, tail, after];
}
