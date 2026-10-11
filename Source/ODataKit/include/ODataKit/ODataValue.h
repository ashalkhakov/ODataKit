// ODataIncrementalStore — values between Core Data and OData.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// One place decides how an attribute's value is written in a JSON payload,
// read back from one, and written as a URL literal (JSON Format section
// 7.1, Part 2 section 5.1.1.14). The Edm type comes from the attribute's
// Core Data type, or from userInfo[@"OData.type"] where one Core Data type
// stands for several Edm types: a Date attribute holding an Edm.Date, a
// Double holding an Edm.Duration in seconds, a String holding an
// Edm.TimeOfDay or an Edm.Guid.
//
// Complex values and collections live in Transformable attributes: a
// complex value as an NSDictionary keyed by the service's property names
// (nested for a nested complex value, with "@odata.type" when the value is
// of a derived type), a collection as an NSArray of such values or of
// primitive ones. Members hold what an attribute of their type would: an
// NSDate for an Edm.Date, an NSDecimalNumber for an Edm.Decimal, an
// enumeration's member names; null stays NSNull.

#pragma once
#import "OISCoreData.h"
#import "ODataSchema.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataUserInfoType;  // @"OData.type", e.g. @"Edm.Date"

typedef NS_ENUM(NSInteger, ODataEdmType) {
  ODataEdmUnknown = 0,
  ODataEdmBoolean,
  ODataEdmInteger,         // Byte, SByte, Int16, Int32
  ODataEdmInt64,
  ODataEdmDecimal,
  ODataEdmDouble,          // Single, Double
  ODataEdmString,
  ODataEdmDateTimeOffset,
  ODataEdmDate,
  ODataEdmTimeOfDay,       // on a String attribute: "13:20:00"
  ODataEdmDuration,        // on a Double attribute: seconds
  ODataEdmGuid,
  ODataEdmBinary,
  ODataEdmEnum,            // a schema enumeration: member names on a String
                           // attribute, member values on an integer one
  ODataEdmComplex,         // a schema complex type: an NSDictionary
  ODataEdmCollection,      // Collection(...): an NSArray
  ODataEdmJSON             // Org.OData.JSON.V1.JSON or Edm.Untyped: any JSON value, kept as it is
                           // (a Transformable attribute) or as its text (a String one)
};

@interface ODataValueCoder : NSObject

// Int64 and Decimal as JSON strings, both ways, so neither goes through a
// double (JSON Format section 3.2). The store asks for this format with
// IEEE754Compatible=true; reading accepts numbers and strings either way.
@property (nonatomic) BOOL IEEE754Compatible;

// By userInfo[@"OData.type"] and the Core Data type alone.
+ (ODataEdmType)edmTypeForAttribute:(nullable NSAttributeDescription *)attribute;

// The service's schema, and the type it declares for an attribute (set by
// ODataPropertyMapper). With them, an attribute's Edm type is its
// userInfo's, else the schema's, else its Core Data type's.
@property (nonatomic, strong, nullable) ODataSchema *schema;
@property (nonatomic, copy, nullable) NSString * _Nullable (^declaredTypeForAttribute)(NSAttributeDescription *attribute);
- (ODataEdmType)edmTypeOfAttribute:(nullable NSAttributeDescription *)attribute;
// The type's name, qualified where the schema knows it: userInfo's, else
// the schema's; nil when neither says.
- (nullable NSString *)typeNameOfAttribute:(nullable NSAttributeDescription *)attribute;
// The Edm type a type name stands for; complex types and enumerations by
// the schema.
- (ODataEdmType)edmTypeNamed:(nullable NSString *)typeName;

// The Core Data value for a JSON value, NSNull for null, or nil when the
// JSON cannot be one (a date that does not parse, say).
- (nullable id)coreDataValueForJSON:(id)json attribute:(NSAttributeDescription *)attribute;

// The JSON value for a Core Data value; NSNull for nil.
- (id)JSONForCoreDataValue:(nullable id)value attribute:(NSAttributeDescription *)attribute;

// A URL literal: typed by the attribute where there is one, else by the
// value's class.
- (NSString *)literalForValue:(nullable id)value attribute:(nullable NSAttributeDescription *)attribute;

// The same, for a value of a named type rather than an attribute's: a
// member of a complex value, an element of a collection.
- (nullable id)valueForJSON:(id)json typeName:(nullable NSString *)typeName;
- (id)JSONForValue:(nullable id)value typeName:(nullable NSString *)typeName;
- (NSString *)literalForValue:(nullable id)value typeName:(nullable NSString *)typeName;

// Dynamic properties, an open type's, which no schema types (JSON Format
// section 4.6.3). The type a value is written as where its JSON does not
// tell it: Edm.DateTimeOffset for an NSDate, Edm.Decimal, Edm.Int32 or
// Edm.Int64, Edm.Double, Edm.Guid for an NSUUID, Edm.Binary for NSData;
// nil for a string, a boolean, a dictionary or an array.
- (nullable NSString *)dynamicTypeNameOfValue:(id)value;
// The members of an entity's JSON that are none of these names, nor
// control information or annotations: its dynamic properties, each
// decoded as its type annotation (Name@odata.type, or 4.01's Name@type)
// says -- a Guid as an NSUUID -- or kept as it came. null is no value.
- (NSDictionary<NSString *, id> *)dynamicPropertiesInJSON:(NSDictionary<NSString *, id> *)json
                                                 declared:(NSSet<NSString *> *)declared;
// And back: each value into json, annotated with its type where
// -dynamicTypeNameOfValue: gives one; NSNull as null, which removes it.
- (void)addDynamicProperties:(NSDictionary<NSString *, id> *)values toJSON:(NSMutableDictionary<NSString *, id> *)json;

@end

// The textual forms, for anyone who needs them without an attribute.
FOUNDATION_EXPORT NSDate * _Nullable ODataDateFromString(NSString *string);  // DateTimeOffset or Date
FOUNDATION_EXPORT NSString *ODataDateTimeOffsetString(NSDate *date);         // UTC, fraction only when there is one
FOUNDATION_EXPORT NSString *ODataDateString(NSDate *date);                   // the UTC calendar day
FOUNDATION_EXPORT NSNumber * _Nullable ODataDurationFromString(NSString *string);  // seconds
FOUNDATION_EXPORT NSString *ODataDurationString(double seconds);
FOUNDATION_EXPORT NSData * _Nullable ODataDataFromBase64(NSString *string);  // base64url or base64
FOUNDATION_EXPORT NSString *ODataBase64URLString(NSData *data);
// An enumeration value's number, from member names and numbers
// ("Red,Blue", "Red, 4"); nil for text that is neither.
FOUNDATION_EXPORT NSNumber * _Nullable ODataEnumValue(ODataSchemaEnumType *type, NSString *text);
// A number as its canonical text: the member with that value, or for
// flags, the members whose bits make it up, in declaration order; a value
// no member names stays a number. One value, one text, so an enumeration
// kept as text compares as its values do.
FOUNDATION_EXPORT NSString *ODataEnumText(ODataSchemaEnumType *type, NSNumber *value);
// A type name from @odata.type: "#NS.Type", "NS.Type", or a context URL
// ending in "#NS.Type", as NS.Type.
FOUNDATION_EXPORT NSString *ODataTypeNameFromControlInformation(NSString *value);
// The bytes JSON (dictionaries, arrays, strings, numbers, null) takes as
// NSJSONSerialization writes it, at most: strings as UTF-8 with what it
// escapes, read a chunk at a time (a file's base64 is not copied to be
// measured). For a page or a batch kept to a size, without writing it twice.
FOUNDATION_EXPORT NSUInteger ODataJSONByteCount(id json);

NS_ASSUME_NONNULL_END
