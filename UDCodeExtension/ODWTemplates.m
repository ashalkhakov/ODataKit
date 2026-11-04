// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODWTemplates.h"
#import <ODataKit/ODataSchema.h>

// A sample value of an Edm type, as JSON (in a body).
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

// The same, as a URL's literal (a key's value, a function's parameter).
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

// A value as typed, as a literal of its type: a string's quoted (its quotes
// doubled) unless it is already.
static NSString *ODWTyped(NSString *value, NSString *type)
{
  value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (![type isEqualToString:@"Edm.String"] || [value hasPrefix:@"'"]) return value;
  return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

static ODataSchemaEntityType *ODWTypeOfEntitySet(ODataSchema *schema, NSString *set)
{
  NSString *typeName = set ? schema.entitySets[set] : nil;
  return typeName ? [schema entityTypeNamed:typeName] : nil;
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

// The unbound overload an operation import names.
static ODataSchemaOperation *ODWOperationOfImport(ODataSchema *schema, NSString *name)
{
  ODataSchemaOperationImport *import = name ? schema.operationImports[name] : nil;
  for (ODataSchemaOperation *overload in import ? schema.operations[[schema qualifiedName:import.operation]] : @[]) {
    if (!overload.isBound) return overload;
  }
  return nil;
}

#pragma mark Entity sets

NSString *ODWEntityOfEntitySet(ODataSchema *schema, NSString *set)
{
  return ODWTypeOfEntitySet(schema, set).name;
}

NSString *ODWEntitySetOfEntity(ODataSchema *schema, NSString *entity)
{
  ODataSchemaEntityType *type = entity.length ? [schema entityTypeWithSimpleName:entity] : nil;
  return type ? [schema entitySetForEntityType:type] : nil;
}

NSArray<NSString *> *ODWKeyOfEntitySet(ODataSchema *schema, NSString *set)
{
  ODataSchemaEntityType *type = ODWTypeOfEntitySet(schema, set);
  return type ? [schema keyOfEntityType:type] : @[];
}

NSDictionary<NSString *, NSString *> *ODWSampleKeyOfEntitySet(ODataSchema *schema, NSString *set)
{
  ODataSchemaEntityType *type = ODWTypeOfEntitySet(schema, set);
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSString *name in ODWKeyOfEntitySet(schema, set)) {
    NSString *literal = ODWLiteral(schema, [schema property:name ofEntityType:type].type ?: @"Edm.String");
    // A string's as typed: without its quotes (put back as it is sent).
    if ([literal hasPrefix:@"'"] && [literal hasSuffix:@"'"] && literal.length >= 2) literal = [literal substringWithRange:NSMakeRange(1, literal.length - 2)];
    key[name] = literal;
  }
  return key;
}

// In the order their types declare them (a base's first), names sorted
// within a type; computed ones, and streams, left out; the key too, unless
// asked for.
NSString *ODWSampleBodyOfEntitySet(ODataSchema *schema, NSString *set, BOOL withKey)
{
  ODataSchemaEntityType *type = ODWTypeOfEntitySet(schema, set);
  if (!type) return @"{}";
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

NSString *ODWKeyPath(ODataSchema *schema, NSString *set, NSDictionary<NSString *, NSString *> *values)
{
  ODataSchemaEntityType *type = ODWTypeOfEntitySet(schema, set);
  NSArray<NSString *> *key = type ? [schema keyOfEntityType:type] : @[];
  if (!key.count) return nil;
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *name in key) {
    NSString *value = [values[name] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!value.length) return nil;
    NSString *literal = ODWTyped(value, [schema property:name ofEntityType:type].type ?: @"Edm.String");
    [parts addObject:key.count == 1 ? literal : [NSString stringWithFormat:@"%@=%@", name, literal]];
  }
  return [NSString stringWithFormat:@"%@(%@)", set, [parts componentsJoinedByString:@","]];
}

#pragma mark Operations

NSArray<NSString *> *ODWParametersOfOperation(ODataSchema *schema, NSString *name)
{
  return [ODWOperationOfImport(schema, name).callerParameters valueForKey:@"name"] ?: @[];
}

NSDictionary<NSString *, NSString *> *ODWSampleParametersOfOperation(ODataSchema *schema, NSString *name)
{
  BOOL action = ODWOperationIsAction(schema, name);
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  for (ODataSchemaParameter *parameter in ODWOperationOfImport(schema, name).callerParameters) {
    NSString *literal = action ? ODWJSONValue(ODWSample(schema, parameter.type, 0)) : ODWLiteral(schema, parameter.type);
    // A string's as typed: without its quotes.
    if (([literal hasPrefix:@"'"] || [literal hasPrefix:@"\""]) && literal.length >= 2) literal = [literal substringWithRange:NSMakeRange(1, literal.length - 2)];
    parameters[parameter.name] = literal;
  }
  return parameters;
}

BOOL ODWOperationIsAction(ODataSchema *schema, NSString *name)
{
  return schema.operationImports[name].isAction;
}

NSString *ODWFunctionPath(ODataSchema *schema, NSString *name, NSDictionary<NSString *, NSString *> *values)
{
  NSMutableArray *arguments = [NSMutableArray array];
  for (ODataSchemaParameter *parameter in ODWOperationOfImport(schema, name).callerParameters) {
    NSString *value = values[parameter.name] ?: @"";
    [arguments addObject:[NSString stringWithFormat:@"%@=%@", parameter.name, value.length ? ODWTyped(value, parameter.type) : @"null"]];
  }
  return [NSString stringWithFormat:@"%@(%@)", name, [arguments componentsJoinedByString:@","]];
}

NSString *ODWActionBody(ODataSchema *schema, NSString *name, NSDictionary<NSString *, NSString *> *values)
{
  NSMutableArray *names = [NSMutableArray array], *parsed = [NSMutableArray array];
  for (ODataSchemaParameter *parameter in ODWOperationOfImport(schema, name).callerParameters) {
    NSString *text = values[parameter.name] ?: @"";
    id value = nil;
    if (![parameter.type isEqualToString:@"Edm.String"] && text.length) {
      NSData *data = [[NSString stringWithFormat:@"[%@]", text] dataUsingEncoding:NSUTF8StringEncoding];
      value = [[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] firstObject];
    }
    [names addObject:parameter.name];
    [parsed addObject:value ?: (text.length ? text : [NSNull null])];
  }
  return ODWJSONObject(names, parsed);
}

#pragma mark Templates

NSDictionary *ODWTemplateOfEntitySet(ODataSchema *schema, NSString *set, ODWTemplate kind)
{
  NSString *entity = ODWEntityOfEntitySet(schema, set);
  if (!entity) return nil;
  switch (kind) {
  case ODWTemplateGetAll:
    return @{ @"request": @"query", @"query": @{ @"entity": entity, @"limit": @"20" } };
  case ODWTemplateGetByKey:
    return @{ @"request": @"query", @"query": @{ @"entity": entity }, @"key": ODWSampleKeyOfEntitySet(schema, set) };
  case ODWTemplateCount:
    return @{ @"request": @"query", @"query": @{ @"entity": entity, @"type": @"count" } };
  case ODWTemplatePost:
    return @{ @"request": @"create", @"entitySet": set, @"body": ODWSampleBodyOfEntitySet(schema, set, YES) };
  case ODWTemplatePatch:
    return @{ @"request": @"update", @"entitySet": set, @"key": ODWSampleKeyOfEntitySet(schema, set),
              @"body": ODWSampleBodyOfEntitySet(schema, set, NO) };
  case ODWTemplateDelete:
    return @{ @"request": @"delete", @"entitySet": set, @"key": ODWSampleKeyOfEntitySet(schema, set) };
  }
  return nil;
}

NSDictionary *ODWTemplateOfOperation(ODataSchema *schema, NSString *name)
{
  if (!schema.operationImports[name]) return nil;
  return @{ @"request": @"call", @"operation": name, @"parameters": ODWSampleParametersOfOperation(schema, name) };
}

#pragma mark curl

// 'text', its own quotes ended, escaped and begun again: a shell's word.
static NSString *ODWShellQuoted(NSString *text)
{
  return [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

NSString *ODWCurlOfRequest(NSURLRequest *request)
{
  NSMutableArray *lines = [NSMutableArray array];
  NSString *method = request.HTTPMethod ?: @"GET";
  [lines addObject:[NSString stringWithFormat:@"curl%@ %@", [method isEqualToString:@"GET"] ? @"" : [@" -X " stringByAppendingString:method],
                                              ODWShellQuoted(request.URL.absoluteString ?: @"")]];
  for (NSString *name in [request.allHTTPHeaderFields.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
    NSString *header = [NSString stringWithFormat:@"%@: %@", name, request.allHTTPHeaderFields[name]];
    [lines addObject:[@"  -H " stringByAppendingString:ODWShellQuoted(header)]];
  }
  if (request.HTTPBody.length) {
    NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
    [lines addObject:[@"  --data-raw " stringByAppendingString:ODWShellQuoted(body)]];
  }
  return [[lines componentsJoinedByString:@" \\\n"] stringByAppendingString:@"\n"];
}
