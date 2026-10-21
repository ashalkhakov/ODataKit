// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataValue.h"
#include <math.h>

NSString * const ODataUserInfoType = @"OData.type";

#pragma mark - Calendar arithmetic

// Days since 1970-01-01 of a proleptic Gregorian date, and back (Howard
// Hinnant's algorithms). Done by hand rather than with NSDateFormatter or
// NSCalendar, so both platforms read and write dates the same way, in UTC,
// whatever the locale.
static int64_t OISDaysFromCivil(int64_t y, unsigned m, unsigned d)
{
  y -= m <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (int64_t)doe - 719468;
}

static void OISCivilFromDays(int64_t z, int64_t *year, unsigned *month, unsigned *day)
{
  z += 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  *day = doy - (153 * mp + 2) / 5 + 1;
  *month = mp < 10 ? mp + 3 : mp - 9;
  *year = (int64_t)yoe + era * 400 + (*month <= 2);
}

// Reads `count` digits (count 0: one or more) into *value.
static BOOL OISDigits(const char **p, int count, int64_t *value)
{
  int64_t v = 0;
  int n = 0;
  while (**p >= '0' && **p <= '9' && (count == 0 || n < count)) {
    v = v * 10 + (**p - '0');
    (*p)++;
    n++;
  }
  *value = v;
  return count ? n == count : n > 0;
}

static BOOL OISExpect(const char **p, char c)
{
  if (**p != c) return NO;
  (*p)++;
  return YES;
}

// A number without exponent notation or locale: 0.1 is "0.1", not
// "0.10000000000000001" or "1e-01".
static NSString *OISDoubleString(double x)
{
  NSString *s = nil;
  for (int precision = 15; precision <= 17; precision++) {
    s = [NSString stringWithFormat:@"%.*g", precision, x];
    if ([s doubleValue] == x) break;
  }
  return s;
}

// A decimal written out in full. gnustep-base writes large and small
// NSDecimalNumbers with an exponent (1E-10, 1.23E19) where Apple does not,
// and a decimal must not have one in a payload unless the payload says so
// (JSON Format section 24, 9d) - nor, in OData 4.0, in a URL literal.
static NSString *OISPlainDecimalString(NSDecimalNumber *number)
{
  NSString *s = number.stringValue;
  NSRange e = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"eE"]];
  if (e.location == NSNotFound) return s;
  NSInteger exponent = [[s substringFromIndex:e.location + 1] integerValue];
  NSString *mantissa = [s substringToIndex:e.location];
  NSString *sign = [mantissa hasPrefix:@"-"] ? @"-" : @"";
  if (sign.length) mantissa = [mantissa substringFromIndex:1];
  NSRange dot = [mantissa rangeOfString:@"."];
  NSInteger point = dot.location == NSNotFound ? (NSInteger)mantissa.length : (NSInteger)dot.location;
  NSString *digits = [mantissa stringByReplacingOccurrencesOfString:@"." withString:@""];
  point += exponent;
  NSMutableString *out = [NSMutableString stringWithString:sign];
  if (point <= 0) {
    [out appendString:@"0."];
    for (NSInteger i = 0; i < -point; i++) [out appendString:@"0"];
    [out appendString:digits];
  } else if (point >= (NSInteger)digits.length) {
    [out appendString:digits];
    for (NSInteger i = digits.length; i < point; i++) [out appendString:@"0"];
  } else {
    [out appendFormat:@"%@.%@", [digits substringToIndex:point], [digits substringFromIndex:point]];
  }
  return out;
}

#pragma mark - Textual forms

// dateValue / dateTimeOffsetValue (Part 2 ABNF): 2024-03-01, or
// 2024-03-01T12:34[:56[.1234567]] with Z or an offset such as +02:00.
NSDate *ODataDateFromString(NSString *string)
{
  const char *p = string.UTF8String;
  if (!p) return nil;
  int64_t sign = OISExpect(&p, '-') ? -1 : 1;
  int64_t year, month, day;
  const char *start = p;
  if (!OISDigits(&p, 0, &year) || p - start < 4) return nil;
  if (!OISExpect(&p, '-') || !OISDigits(&p, 2, &month) || !OISExpect(&p, '-') || !OISDigits(&p, 2, &day)) return nil;
  if (month < 1 || month > 12 || day < 1 || day > 31) return nil;
  double seconds = (double)OISDaysFromCivil(sign * year, (unsigned)month, (unsigned)day) * 86400.0;
  if (*p == 0) return [NSDate dateWithTimeIntervalSince1970:seconds];

  int64_t hour, minute, second = 0;
  if (!OISExpect(&p, 'T') && !OISExpect(&p, 't')) return nil;
  if (!OISDigits(&p, 2, &hour) || !OISExpect(&p, ':') || !OISDigits(&p, 2, &minute)) return nil;
  double fraction = 0;
  if (OISExpect(&p, ':')) {
    if (!OISDigits(&p, 2, &second)) return nil;
    if (OISExpect(&p, '.')) {
      double scale = 0.1;
      if (!(*p >= '0' && *p <= '9')) return nil;
      while (*p >= '0' && *p <= '9') {
        fraction += (*p - '0') * scale;
        scale /= 10;
        p++;
      }
    }
  }
  if (hour > 23 || minute > 59 || second > 60) return nil;
  seconds += hour * 3600.0 + minute * 60.0 + second + fraction;
  if (OISExpect(&p, 'Z') || OISExpect(&p, 'z')) {
    // UTC
  } else if (*p == '+' || *p == '-') {
    int64_t offsetSign = *p == '-' ? -1 : 1, offsetHour, offsetMinute;
    p++;
    if (!OISDigits(&p, 2, &offsetHour) || !OISExpect(&p, ':') || !OISDigits(&p, 2, &offsetMinute)) return nil;
    seconds -= offsetSign * (offsetHour * 3600.0 + offsetMinute * 60.0);
  } else {
    return nil;
  }
  return *p == 0 ? [NSDate dateWithTimeIntervalSince1970:seconds] : nil;
}

static NSString *OISYear(int64_t year)
{
  return year < 0 ? [NSString stringWithFormat:@"-%04lld", (long long)-year]
                  : [NSString stringWithFormat:@"%04lld", (long long)year];
}

NSString *ODataDateTimeOffsetString(NSDate *date)
{
  double t = date.timeIntervalSince1970;
  double whole = floor(t);
  // Microseconds: what a double holds of a present-day date, and more than
  // most services keep.
  long long micros = llround((t - whole) * 1e6);
  if (micros >= 1000000) {
    whole += 1;
    micros -= 1000000;
  }
  int64_t days = (int64_t)floor(whole / 86400.0);
  int64_t secs = (int64_t)whole - days * 86400;
  int64_t year;
  unsigned month, day;
  OISCivilFromDays(days, &year, &month, &day);
  NSMutableString *out = [NSMutableString stringWithFormat:@"%@-%02u-%02uT%02lld:%02lld:%02lld", OISYear(year), month, day,
                                                           (long long)(secs / 3600), (long long)(secs / 60 % 60), (long long)(secs % 60)];
  if (micros) {
    NSString *fraction = [NSString stringWithFormat:@"%06lld", micros];
    while ([fraction hasSuffix:@"0"]) fraction = [fraction substringToIndex:fraction.length - 1];
    [out appendFormat:@".%@", fraction];
  }
  [out appendString:@"Z"];
  return out;
}

NSString *ODataDateString(NSDate *date)
{
  int64_t days = (int64_t)floor(date.timeIntervalSince1970 / 86400.0);
  int64_t year;
  unsigned month, day;
  OISCivilFromDays(days, &year, &month, &day);
  return [NSString stringWithFormat:@"%@-%02u-%02u", OISYear(year), month, day];
}

// durationValue: [-]P[nD][T[nH][nM][n[.n]S]]
NSNumber *ODataDurationFromString(NSString *string)
{
  const char *p = string.UTF8String;
  if (!p) return nil;
  double sign = OISExpect(&p, '-') ? -1 : 1;
  if (!OISExpect(&p, 'P')) return nil;
  double total = 0;
  BOOL time = NO, any = NO;
  while (*p) {
    if (OISExpect(&p, 'T')) {
      if (time) return nil;
      time = YES;
      continue;
    }
    const char *numberStart = p;
    while ((*p >= '0' && *p <= '9') || *p == '.') p++;
    if (p == numberStart) return nil;
    double n = [[[NSString alloc] initWithBytes:numberStart length:(NSUInteger)(p - numberStart) encoding:NSASCIIStringEncoding] doubleValue];
    char unit = *p++;
    if (unit == 'D' && !time) total += n * 86400;
    else if (unit == 'H' && time) total += n * 3600;
    else if (unit == 'M' && time) total += n * 60;
    else if (unit == 'S' && time) total += n;
    else return nil;
    any = YES;
  }
  return any ? @(sign * total) : nil;
}

NSString *ODataDurationString(double seconds)
{
  NSString *sign = seconds < 0 ? @"-" : @"";
  return [NSString stringWithFormat:@"%@PT%@S", sign, OISDoubleString(fabs(seconds))];
}

// binaryValue is base64url (RFC 4648 section 5). Some services, Northwind
// among them, send plain base64; both read.
NSData *ODataDataFromBase64(NSString *string)
{
  NSMutableString *s = [[string stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
  [s replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, s.length)];
  while (s.length % 4) [s appendString:@"="];
  return [[NSData alloc] initWithBase64EncodedString:s options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

NSString *ODataBase64URLString(NSData *data)
{
  NSMutableString *s = [[data base64EncodedStringWithOptions:0] mutableCopy];
  [s replaceOccurrencesOfString:@"+" withString:@"-" options:0 range:NSMakeRange(0, s.length)];
  [s replaceOccurrencesOfString:@"/" withString:@"_" options:0 range:NSMakeRange(0, s.length)];
  while ([s hasSuffix:@"="]) [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
  return s;
}

NSString *ODataTypeNameFromControlInformation(NSString *value)
{
  // "#NS.Type", "NS.Type" (4.01), or a URL ending in it: .../$metadata#NS.Type.
  NSRange hash = [value rangeOfString:@"#" options:NSBackwardsSearch];
  return hash.location == NSNotFound ? value : [value substringFromIndex:hash.location + 1];
}

#pragma mark - The coder

static ODataEdmType OISEdmTypeNamed(NSString *declared)
{
  if (![declared isKindOfClass:[NSString class]]) return ODataEdmUnknown;
  {
    static NSDictionary *byName;
    if (!byName) {
      byName = @{
        @"Edm.Boolean": @(ODataEdmBoolean),
        @"Edm.Byte": @(ODataEdmInteger), @"Edm.SByte": @(ODataEdmInteger),
        @"Edm.Int16": @(ODataEdmInteger), @"Edm.Int32": @(ODataEdmInteger),
        @"Edm.Int64": @(ODataEdmInt64),
        @"Edm.Decimal": @(ODataEdmDecimal),
        @"Edm.Single": @(ODataEdmDouble), @"Edm.Double": @(ODataEdmDouble),
        @"Edm.String": @(ODataEdmString),
        @"Edm.DateTimeOffset": @(ODataEdmDateTimeOffset),
        @"Edm.Date": @(ODataEdmDate),
        @"Edm.TimeOfDay": @(ODataEdmTimeOfDay),
        @"Edm.Duration": @(ODataEdmDuration),
        @"Edm.Guid": @(ODataEdmGuid),
        @"Edm.Binary": @(ODataEdmBinary),
        @"Org.OData.JSON.V1.JSON": @(ODataEdmJSON), @"JSON.JSON": @(ODataEdmJSON),
        @"Edm.Untyped": @(ODataEdmJSON),
      };
    }
    NSNumber *type = byName[declared];
    if (type) return (ODataEdmType)type.integerValue;
  }
  return ODataEdmUnknown;
}

static ODataEdmType OISEdmTypeOfCoreDataType(NSAttributeDescription *attribute)
{
  switch (attribute.attributeType) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType: return ODataEdmInteger;
    case NSInteger64AttributeType: return ODataEdmInt64;
    case NSDecimalAttributeType: return ODataEdmDecimal;
    case NSDoubleAttributeType:
    case NSFloatAttributeType: return ODataEdmDouble;
    case NSStringAttributeType: return ODataEdmString;
    case NSBooleanAttributeType: return ODataEdmBoolean;
    case NSDateAttributeType: return ODataEdmDateTimeOffset;
    case NSBinaryDataAttributeType: return ODataEdmBinary;
    default:
      return attribute.attributeType == NSUUIDAttributeType ? ODataEdmGuid : ODataEdmUnknown;
  }
}

// Any JSON value as its text, a lone string or number too (gnustep-base
// has no NSJSONWritingFragmentsAllowed): written inside an array, and
// taken out of it.
static NSString *OISJSONText(id value)
{
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ] options:0 error:NULL];
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (text.length < 2) return nil;
  return [text substringWithRange:NSMakeRange(1, text.length - 2)];
}

@implementation ODataValueCoder

+ (ODataEdmType)edmTypeForAttribute:(NSAttributeDescription *)attribute
{
  if (!attribute) return ODataEdmUnknown;
  NSString *declared = attribute.userInfo[ODataUserInfoType];
  ODataEdmType type = OISEdmTypeNamed(declared);
  if (type == ODataEdmUnknown && [declared isKindOfClass:[NSString class]] && [declared hasPrefix:@"Collection("]) {
    type = ODataEdmCollection;
  }
  return type != ODataEdmUnknown ? type : OISEdmTypeOfCoreDataType(attribute);
}

- (ODataEdmType)edmTypeNamed:(NSString *)typeName
{
  if (![typeName isKindOfClass:[NSString class]] || !typeName.length) return ODataEdmUnknown;
  if ([typeName hasPrefix:@"Collection("] && [typeName hasSuffix:@")"]) return ODataEdmCollection;
  if ([self.schema enumTypeNamed:typeName]) return ODataEdmEnum;
  if ([self.schema complexTypeNamed:typeName]) return ODataEdmComplex;
  return OISEdmTypeNamed(typeName);
}

- (NSString *)typeNameOfAttribute:(NSAttributeDescription *)attribute
{
  if (!attribute) return nil;
  NSString *explicit = attribute.userInfo[ODataUserInfoType];
  if ([explicit isKindOfClass:[NSString class]] && explicit.length) {
    return self.schema ? [self.schema qualifiedName:explicit] : explicit;
  }
  return self.declaredTypeForAttribute ? self.declaredTypeForAttribute(attribute) : nil;
}

- (ODataEdmType)edmTypeOfAttribute:(NSAttributeDescription *)attribute
{
  if (!attribute) return ODataEdmUnknown;
  NSString *explicit = attribute.userInfo[ODataUserInfoType];
  ODataEdmType type = [self edmTypeNamed:explicit];
  if (type != ODataEdmUnknown) return type;
  NSString *declared = self.declaredTypeForAttribute ? self.declaredTypeForAttribute(attribute) : nil;
  type = [self edmTypeNamed:declared];
  if (type != ODataEdmUnknown) return type;
  return OISEdmTypeOfCoreDataType(attribute);
}

// The type name an attribute's value is coded by: its own, or with neither
// userInfo nor schema to say, none.
- (NSString *)codingTypeNameOfAttribute:(NSAttributeDescription *)attribute
{
  NSString *explicit = attribute.userInfo[ODataUserInfoType];
  if ([self edmTypeNamed:explicit] != ODataEdmUnknown) return [self typeNameOfAttribute:attribute];
  NSString *declared = self.declaredTypeForAttribute ? self.declaredTypeForAttribute(attribute) : nil;
  return [self edmTypeNamed:declared] != ODataEdmUnknown ? declared : nil;
}

static BOOL OISIsIntegerAttribute(NSAttributeDescription *attribute)
{
  NSAttributeType t = attribute.attributeType;
  return t == NSInteger16AttributeType || t == NSInteger32AttributeType || t == NSInteger64AttributeType;
}

// enumValue: member names, or member values, joined by commas for flags
// ("Red,Blue"). As a number, the members' values or'ed together.
static NSNumber *OISEnumNumber(ODataSchemaEnumType *type, NSString *text)
{
  long long total = 0;
  for (NSString *part in [text componentsSeparatedByString:@","]) {
    NSString *member = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSNumber *value = type.values[member];
    if (!value) {
      NSScanner *scanner = [NSScanner scannerWithString:member];
      long long n;
      if (![scanner scanLongLong:&n] || !scanner.isAtEnd) return nil;
      value = @(n);
    }
    total |= value.longLongValue;
  }
  return @(total);
}

// Member names as the enumeration spells them: red,BLUE is Red,Blue.
static NSString *OISEnumSpelling(ODataSchemaEnumType *type, NSString *text)
{
  if (!type || ![text isKindOfClass:[NSString class]]) return text;
  NSMutableArray *members = [NSMutableArray array];
  for (NSString *member in [text componentsSeparatedByString:@","]) {
    NSString *trimmed = [member stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [members addObject:ODataSchemaSpelling(trimmed, type.memberNames)];
  }
  return [members componentsJoinedByString:@","];
}

// A number as member names: the member with that value, or for flags, the
// members whose bits make it up. A value no member names stays a number.
static NSString *OISEnumText(ODataSchemaEnumType *type, NSNumber *number)
{
  long long n = number.longLongValue;
  for (NSString *member in type.memberNames) {
    if (type.values[member].longLongValue == n) return member;
  }
  if (type.isFlags && n > 0) {
    NSMutableArray *members = [NSMutableArray array];
    long long covered = 0;
    for (NSString *member in type.memberNames) {
      long long bits = type.values[member].longLongValue;
      if (bits && (n & bits) == bits) {
        [members addObject:member];
        covered |= bits;
      }
    }
    if (covered == n) return [members componentsJoinedByString:@","];
  }
  return number.stringValue;
}

NSNumber *ODataEnumValue(ODataSchemaEnumType *type, NSString *text)
{
  return [text isKindOfClass:[NSString class]] ? OISEnumNumber(type, text) : nil;
}

NSString *ODataEnumText(ODataSchemaEnumType *type, NSNumber *value)
{
  return OISEnumText(type, value);
}

static ODataEdmType OISEdmTypeOfValue(id value)
{
  if ([value isKindOfClass:[@YES class]]) return ODataEdmBoolean;
  if ([value isKindOfClass:[NSDecimalNumber class]]) return ODataEdmDecimal;
  if ([value isKindOfClass:[NSNumber class]]) {
    const char *t = [value objCType];
    return (t && (t[0] == 'd' || t[0] == 'f')) ? ODataEdmDouble : ODataEdmInt64;
  }
  if ([value isKindOfClass:[NSDate class]]) return ODataEdmDateTimeOffset;
  if ([value isKindOfClass:[NSUUID class]]) return ODataEdmGuid;
  if ([value isKindOfClass:[NSData class]]) return ODataEdmBinary;
  if ([value isKindOfClass:[NSDictionary class]]) return ODataEdmComplex;
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSOrderedSet class]]) {
    return ODataEdmCollection;
  }
  return ODataEdmString;
}

static NSNumber *OISInteger(id json)
{
  if ([json isKindOfClass:[NSNumber class]]) return @([json longLongValue]);
  if (![json isKindOfClass:[NSString class]]) return nil;
  NSScanner *scanner = [NSScanner scannerWithString:json];
  long long value;
  return ([scanner scanLongLong:&value] && scanner.isAtEnd) ? @(value) : nil;
}

// A decimal from JSON: a number a parser made a double of by the text it
// was written as (the shortest that reads back as it: 68.4, where the
// double's -decimalValue is 68.40000000000001), so that a decimal sent
// as 68.4 is kept as 68.4.
static NSDecimalNumber *OISDecimal(id json)
{
  if ([json isKindOfClass:[NSDecimalNumber class]]) return json;
  if ([json isKindOfClass:[NSNumber class]]) {
    const char *type = [json objCType];
    if (type[0] == 'd' || type[0] == 'f') {
      double x = [json doubleValue];
      if (isfinite(x)) return [NSDecimalNumber decimalNumberWithString:OISDoubleString(x) locale:@{ NSLocaleDecimalSeparator: @"." }];
    }
    return [NSDecimalNumber decimalNumberWithDecimal:[json decimalValue]];
  }
  if (![json isKindOfClass:[NSString class]]) return nil;
  NSDecimalNumber *d = [NSDecimalNumber decimalNumberWithString:json locale:@{ NSLocaleDecimalSeparator: @"." }];
  return [d isEqual:[NSDecimalNumber notANumber]] ? nil : d;
}

static NSString *OISElementType(NSString *typeName)
{
  if ([typeName hasPrefix:@"Collection("] && [typeName hasSuffix:@")"]) {
    return [typeName substringWithRange:NSMakeRange(11, typeName.length - 12)];
  }
  return nil;
}

// A complex value's type: the one it names in @odata.type (4.01: @type),
// when that is the declared type or derives from it, else the declared one.
- (ODataSchemaComplexType *)complexTypeOf:(NSDictionary *)value declared:(NSString *)typeName
{
  ODataSchemaComplexType *declared = [self.schema complexTypeNamed:typeName];
  id named = value[@"@odata.type"];
  if (![named isKindOfClass:[NSString class]]) return declared;
  NSString *name = ODataTypeNameFromControlInformation(named);
  ODataSchemaComplexType *actual = [self.schema complexTypeNamed:name];
  for (ODataSchemaComplexType *t = actual; t; t = t.baseType ? [self.schema complexTypeNamed:t.baseType] : nil) {
    if (!declared || [t.qualifiedName isEqualToString:declared.qualifiedName]) return actual;
  }
  return declared;
}

#pragma mark Reading

- (id)decode:(id)json edm:(ODataEdmType)edm typeName:(NSString *)typeName
     enumAsInteger:(BOOL)enumAsInteger asUUID:(BOOL)asUUID
{
  if (!json || json == [NSNull null]) return [NSNull null];
  switch (edm) {
    case ODataEdmJSON:
      return json;
    case ODataEdmBoolean:
      return [json isKindOfClass:[NSNumber class]] ? [NSNumber numberWithBool:[json boolValue]] : nil;
    case ODataEdmInteger:
    case ODataEdmInt64:
      return OISInteger(json);
    case ODataEdmDecimal:
      return OISDecimal(json);
    case ODataEdmDouble:
      if ([json isKindOfClass:[NSNumber class]]) return @([json doubleValue]);
      if ([json isEqual:@"INF"]) return @(INFINITY);
      if ([json isEqual:@"-INF"]) return @(-INFINITY);
      if ([json isEqual:@"NaN"]) return @(NAN);
      return [json isKindOfClass:[NSString class]] ? @([json doubleValue]) : nil;
    case ODataEdmString:
    case ODataEdmTimeOfDay:
      return [json isKindOfClass:[NSString class]] ? json : [json description];
    case ODataEdmDateTimeOffset:
    case ODataEdmDate:
      return [json isKindOfClass:[NSString class]] ? ODataDateFromString(json) : nil;
    case ODataEdmDuration:
      return [json isKindOfClass:[NSString class]] ? ODataDurationFromString(json) : nil;
    case ODataEdmGuid:
      if (![json isKindOfClass:[NSString class]]) return nil;
      return asUUID ? [[NSUUID alloc] initWithUUIDString:json] : json;
    case ODataEdmBinary:
      return [json isKindOfClass:[NSString class]] ? ODataDataFromBase64(json) : nil;
    case ODataEdmEnum: {
      ODataSchemaEnumType *type = [self.schema enumTypeNamed:typeName];
      if (enumAsInteger) {
        return [json isKindOfClass:[NSNumber class]] ? json
             : ([json isKindOfClass:[NSString class]] && type ? OISEnumNumber(type, json) : nil);
      }
      if ([json isKindOfClass:[NSNumber class]] && type) return OISEnumText(type, json);
      if (![json isKindOfClass:[NSString class]]) return [json description];
      // Kept as its canonical text: Blue,Red and 3 are Red,Blue.
      NSNumber *number = type ? OISEnumNumber(type, json) : nil;
      return number ? OISEnumText(type, number) : json;
    }
    case ODataEdmComplex: {
      if (![json isKindOfClass:[NSDictionary class]]) return nil;
      ODataSchemaComplexType *type = [self complexTypeOf:json declared:typeName];
      NSMutableDictionary *value = [NSMutableDictionary dictionary];
      for (NSString *key in json) {
        id member = json[key];
        if ([key isEqualToString:@"@odata.type"]) {
          // Only a type other than the declared one is worth keeping.
          if (type && ![type.qualifiedName isEqualToString:[self.schema qualifiedName:typeName]]) {
            value[@"@odata.type"] = [@"#" stringByAppendingString:type.qualifiedName];
          }
          continue;
        }
        if ([key rangeOfString:@"@"].location != NSNotFound) continue;  // annotations
        ODataSchemaProperty *property = type ? [self.schema property:key ofComplexType:type] : nil;
        // A member the schema does not declare (an open type's) is kept as
        // it came.
        id decoded = property ? [self valueForJSON:member typeName:property.type] : member;
        if (decoded) value[key] = decoded;
      }
      return value;
    }
    case ODataEdmCollection: {
      if (![json isKindOfClass:[NSArray class]]) return nil;
      NSString *element = OISElementType(typeName);
      NSMutableArray *values = [NSMutableArray array];
      for (id item in json) {
        id decoded = element ? [self valueForJSON:item typeName:element] : item;
        [values addObject:decoded ?: [NSNull null]];
      }
      return values;
    }
    case ODataEdmUnknown:
      return json;
  }
  return json;
}

- (id)coreDataValueForJSON:(id)json attribute:(NSAttributeDescription *)attribute
{
  if ([self edmTypeOfAttribute:attribute] == ODataEdmJSON) {
    if (!json || json == [NSNull null]) return [NSNull null];
    if (attribute.attributeType != NSStringAttributeType) return json;
    return OISJSONText(json) ?: (id)[NSNull null];
  }
  return [self decode:json edm:[self edmTypeOfAttribute:attribute] typeName:[self codingTypeNameOfAttribute:attribute]
        enumAsInteger:OISIsIntegerAttribute(attribute) asUUID:attribute.attributeType == NSUUIDAttributeType];
}

- (id)valueForJSON:(id)json typeName:(NSString *)typeName
{
  return [self decode:json edm:[self edmTypeNamed:typeName] typeName:typeName enumAsInteger:NO asUUID:NO];
}

#pragma mark Writing

- (id)encode:(id)value edm:(ODataEdmType)edm typeName:(NSString *)typeName
{
  if (!value || value == [NSNull null]) return [NSNull null];
  if (edm == ODataEdmUnknown) edm = OISEdmTypeOfValue(value);
  switch (edm) {
    case ODataEdmJSON:
      return value;
    case ODataEdmBoolean:
      // A real JSON boolean: @0 set on a Boolean attribute would be written 0.
      return [NSNumber numberWithBool:[value boolValue]];
    case ODataEdmInteger:
      return @([value longLongValue]);
    case ODataEdmInt64: {
      NSNumber *n = @([value longLongValue]);
      return self.IEEE754Compatible ? n.stringValue : n;
    }
    case ODataEdmDecimal: {
      NSDecimalNumber *d = OISDecimal(value) ?: [NSDecimalNumber zero];
      return self.IEEE754Compatible ? OISPlainDecimalString(d) : d;
    }
    case ODataEdmDouble: {
      // JSON has no NaN or infinity; OData writes them as strings.
      double x = [value doubleValue];
      if (isnan(x)) return @"NaN";
      if (isinf(x)) return x > 0 ? @"INF" : @"-INF";
      return @(x);
    }
    case ODataEdmString:
    case ODataEdmTimeOfDay:
      return [value isKindOfClass:[NSString class]] ? value : [value description];
    case ODataEdmDateTimeOffset:
      return [value isKindOfClass:[NSDate class]] ? ODataDateTimeOffsetString(value) : value;
    case ODataEdmDate:
      return [value isKindOfClass:[NSDate class]] ? ODataDateString(value) : value;
    case ODataEdmDuration:
      return ODataDurationString([value doubleValue]);
    case ODataEdmGuid:
      return [value isKindOfClass:[NSUUID class]] ? [value UUIDString] : value;
    case ODataEdmBinary:
      return [value isKindOfClass:[NSData class]] ? ODataBase64URLString(value) : value;
    case ODataEdmEnum: {
      ODataSchemaEnumType *type = [self.schema enumTypeNamed:typeName];
      if ([value isKindOfClass:[NSNumber class]]) return type ? OISEnumText(type, value) : [value stringValue];
      return OISEnumSpelling(type, [value description]);
    }
    case ODataEdmComplex: {
      if (![value isKindOfClass:[NSDictionary class]]) return value;
      ODataSchemaComplexType *type = [self complexTypeOf:value declared:typeName];
      NSMutableDictionary *json = [NSMutableDictionary dictionary];
      for (NSString *key in value) {
        if ([key hasPrefix:@"@"]) {
          if ([key isEqualToString:@"@odata.type"]) json[key] = value[key];
          continue;
        }
        ODataSchemaProperty *property = type ? [self.schema property:key ofComplexType:type] : nil;
        json[key] = [self JSONForValue:value[key] typeName:property.type];
      }
      return json;
    }
    case ODataEdmCollection: {
      NSString *element = OISElementType(typeName);
      id items = value;
      if ([items isKindOfClass:[NSOrderedSet class]]) items = [items array];
      else if ([items isKindOfClass:[NSSet class]]) items = [items allObjects];
      if (![items isKindOfClass:[NSArray class]]) return value;
      NSMutableArray *json = [NSMutableArray array];
      for (id item in items) [json addObject:[self JSONForValue:item typeName:element]];
      return json;
    }
    case ODataEdmUnknown:
      return value;
  }
  return value;
}

- (id)JSONForCoreDataValue:(id)value attribute:(NSAttributeDescription *)attribute
{
  if ([self edmTypeOfAttribute:attribute] == ODataEdmJSON) {
    if (!value || value == [NSNull null]) return [NSNull null];
    if (attribute.attributeType != NSStringAttributeType) return value;
    id json = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:NULL];
    return json ?: value;
  }
  return [self encode:value edm:[self edmTypeOfAttribute:attribute] typeName:[self codingTypeNameOfAttribute:attribute]];
}

- (id)JSONForValue:(id)value typeName:(NSString *)typeName
{
  return [self encode:value edm:[self edmTypeNamed:typeName] typeName:typeName];
}

#pragma mark Dynamic properties

- (NSString *)dynamicTypeNameOfValue:(id)value
{
  if ([value isKindOfClass:[@YES class]]) return nil;
  if ([value isKindOfClass:[NSDecimalNumber class]]) return @"Edm.Decimal";
  if ([value isKindOfClass:[NSNumber class]]) {
    const char *t = [value objCType];
    if (t && (t[0] == 'd' || t[0] == 'f')) return @"Edm.Double";
    long long n = [value longLongValue];
    return n >= INT32_MIN && n <= INT32_MAX ? @"Edm.Int32" : @"Edm.Int64";
  }
  if ([value isKindOfClass:[NSDate class]]) return @"Edm.DateTimeOffset";
  if ([value isKindOfClass:[NSUUID class]]) return @"Edm.Guid";
  if ([value isKindOfClass:[NSData class]]) return @"Edm.Binary";
  return nil;
}

// A type annotation's name, qualified: #Int32 is Edm.Int32, and
// #Collection(Int32) Collection(Edm.Int32).
static NSString *OISAnnotatedTypeName(id annotation)
{
  if (![annotation isKindOfClass:[NSString class]]) return nil;
  NSString *name = ODataTypeNameFromControlInformation(annotation);
  NSString *element = OISElementType(name);
  if (element) return [element rangeOfString:@"."].location == NSNotFound ? [NSString stringWithFormat:@"Collection(Edm.%@)", element] : name;
  return [name rangeOfString:@"."].location == NSNotFound ? [@"Edm." stringByAppendingString:name] : name;
}

- (NSDictionary *)dynamicPropertiesInJSON:(NSDictionary *)json declared:(NSSet *)declared
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *name in json) {
    if ([name rangeOfString:@"@"].location != NSNotFound || [declared containsObject:name]) continue;
    id member = json[name];
    if (member == [NSNull null]) continue;
    NSString *type = OISAnnotatedTypeName(json[[name stringByAppendingString:@"@odata.type"]] ?: json[[name stringByAppendingString:@"@type"]]);
    id value = type ? [self decode:member edm:[self edmTypeNamed:type] typeName:type enumAsInteger:NO asUUID:YES] : member;
    if (value && value != [NSNull null]) values[name] = value;
  }
  return values;
}

- (void)addDynamicProperties:(NSDictionary *)values toJSON:(NSMutableDictionary *)json
{
  for (NSString *name in values) {
    id value = values[name];
    NSString *type = value == [NSNull null] ? nil : [self dynamicTypeNameOfValue:value];
    json[name] = [self JSONForValue:value typeName:type];
    if (type) json[[name stringByAppendingString:@"@odata.type"]] = [@"#" stringByAppendingString:[type substringFromIndex:4]];
  }
}

#pragma mark Literals

- (NSString *)literal:(id)value edm:(ODataEdmType)edm typeName:(NSString *)typeName
{
  if (!value || value == [NSNull null]) return @"null";
  ODataEdmType type = edm;
  if (type == ODataEdmUnknown || type == ODataEdmComplex || type == ODataEdmCollection) type = OISEdmTypeOfValue(value);
  // A string compared with a non-string property is still a string.
  if ([value isKindOfClass:[NSString class]] && type != ODataEdmTimeOfDay && type != ODataEdmGuid &&
      type != ODataEdmDateTimeOffset && type != ODataEdmDate && type != ODataEdmEnum) {
    type = ODataEdmString;
  }
  switch (type) {
    case ODataEdmBoolean:
      return [value boolValue] ? @"true" : @"false";
    case ODataEdmInteger:
    case ODataEdmInt64:
      return [NSString stringWithFormat:@"%lld", [value longLongValue]];
    case ODataEdmDecimal:
      return OISPlainDecimalString(OISDecimal(value) ?: [NSDecimalNumber zero]);
    case ODataEdmDouble: {
      double x = [value doubleValue];
      if (isnan(x)) return @"NaN";
      if (isinf(x)) return x > 0 ? @"INF" : @"-INF";
      return OISDoubleString(x);
    }
    case ODataEdmDateTimeOffset:
      return [value isKindOfClass:[NSDate class]] ? ODataDateTimeOffsetString(value) : value;
    case ODataEdmDate:
      return [value isKindOfClass:[NSDate class]] ? ODataDateString(value) : value;
    case ODataEdmTimeOfDay:
      return [value description];
    case ODataEdmDuration:
      return [NSString stringWithFormat:@"duration'%@'", ODataDurationString([value doubleValue])];
    case ODataEdmGuid:
      return [value isKindOfClass:[NSUUID class]] ? [value UUIDString] : [value description];
    case ODataEdmBinary:
      return [value isKindOfClass:[NSData class]]
          ? [NSString stringWithFormat:@"binary'%@'", ODataBase64URLString(value)] : [value description];
    case ODataEdmEnum: {
      // OData 4.0 wants the qualified form: NS.Color'Red,Blue'.
      ODataSchemaEnumType *enumType = [self.schema enumTypeNamed:typeName];
      NSString *members = [value isKindOfClass:[NSNumber class]] && enumType ? OISEnumText(enumType, value) : OISEnumSpelling(enumType, [value description]);
      NSString *escaped = [members stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
      return enumType ? [NSString stringWithFormat:@"%@'%@'", enumType.qualifiedName, escaped] : [NSString stringWithFormat:@"'%@'", escaped];
    }
    case ODataEdmComplex:
    case ODataEdmJSON: {
      NSString *json = OISJSONText(value) ?: [value description];
      return [NSString stringWithFormat:@"'%@'", [json stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
    }
    case ODataEdmCollection: {
      // A JSON literal (Part 2 section 5.1.1.14.5 in 4.01; [..] and {..}).
      id json = [self encode:value edm:edm typeName:typeName];
      NSData *data = [NSJSONSerialization isValidJSONObject:json] ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : nil;
      if (data) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      break;
    }
    case ODataEdmString:
    case ODataEdmUnknown:
      break;
  }
  NSString *s = [value isKindOfClass:[NSString class]] ? value : [value description];
  return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

- (NSString *)literalForValue:(id)value attribute:(NSAttributeDescription *)attribute
{
  return [self literal:value edm:[self edmTypeOfAttribute:attribute] typeName:[self codingTypeNameOfAttribute:attribute]];
}

- (NSString *)literalForValue:(id)value typeName:(NSString *)typeName
{
  return [self literal:value edm:[self edmTypeNamed:typeName] typeName:typeName];
}

@end

// The bytes a string takes as JSON, at most: its UTF-8, quoted, with what
// NSJSONSerialization escapes (a quote, a backslash, a slash: base64 is
// full of them; a control character, as \n or \u00XX). Read a chunk at a
// time: a file's base64 is not copied to be measured.
static NSUInteger ODataJSONStringByteCount(NSString *string)
{
  NSUInteger n = 2, length = string.length;
  unichar chunk[1024];
  for (NSUInteger at = 0; at < length; at += 1024) {
    NSUInteger count = MIN(1024u, length - at);
    [string getCharacters:chunk range:NSMakeRange(at, count)];
    for (NSUInteger i = 0; i < count; i++) {
      unichar c = chunk[i];
      if (c == '"' || c == '\\' || c == '/') n += 2;
      else if (c < 0x20) n += (c == '\n' || c == '\r' || c == '\t' || c == '\b' || c == '\f') ? 2 : 6;
      else if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (c >= 0xD800 && c <= 0xDFFF) n += 2;  // a surrogate: four for the pair
      else n += 3;
    }
  }
  return n;
}

NSUInteger ODataJSONByteCount(id value)
{
  if ([value isKindOfClass:[NSString class]]) return ODataJSONStringByteCount(value);
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSUInteger n = 2;
    for (id key in value) n += ODataJSONByteCount(key) + ODataJSONByteCount([value objectForKey:key]) + 2;
    return n;
  }
  if ([value isKindOfClass:[NSArray class]]) {
    NSUInteger n = 2;
    for (id item in value) n += ODataJSONByteCount(item) + 1;
    return n;
  }
  if (value == [NSNull null]) return 4;
  return 16;  // a number, true or false, at most
}
