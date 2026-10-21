// Values between Core Data and OData: JSON both ways, and URL literals.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData 4.01 JSON Format section 7.1 (primitive values), section 3.2
// (IEEE754Compatible), Part 2 section 5.1.1.14 and the ABNF (literals).

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"
#include <math.h>

@interface ODataValueTests : XCTestCase
@end

@implementation ODataValueTests {
  ODataValueCoder *_coder;
}

- (void)setUp
{
  [super setUp];
  _coder = [[ODataValueCoder alloc] init];
  _coder.IEEE754Compatible = YES;
}

- (NSAttributeDescription *)attribute:(NSAttributeType)type edm:(NSString *)edm
{
  NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
  attr.name = @"value";
  attr.attributeType = type;
  if (edm) attr.userInfo = @{ ODataUserInfoType: edm };
  return attr;
}

- (NSDate *)date:(NSString *)iso
{
  NSDate *date = ODataDateFromString(iso);
  XCTAssertNotNil(date, @"%@", iso);
  return date;
}

#pragma mark - Dates

- (void)testDateTimeOffsetReadsFractionsAndOffsets
{
  NSDate *utc = [self date:@"2024-03-01T12:34:56Z"];
  XCTAssertEqualObjects(ODataDateTimeOffsetString(utc), @"2024-03-01T12:34:56Z");
  // Seven fractional digits and an offset, as .NET services write them.
  NSDate *offset = [self date:@"2024-03-01T14:34:56.1234567+02:00"];
  XCTAssertEqualWithAccuracy(offset.timeIntervalSince1970 - utc.timeIntervalSince1970, 0.1234567, 1e-6);
  XCTAssertEqualObjects(ODataDateTimeOffsetString(offset), @"2024-03-01T12:34:56.123457Z");
  XCTAssertEqualObjects(ODataDateTimeOffsetString([self date:@"2024-03-01T07:04:56-05:30"]), @"2024-03-01T12:34:56Z");
  // Minutes only: seconds are optional in dateTimeOffsetValue.
  XCTAssertEqualObjects(ODataDateTimeOffsetString([self date:@"2024-03-01T12:34Z"]), @"2024-03-01T12:34:00Z");
}

- (void)testDateTimeOffsetRejectsWhatIsNotOne
{
  for (NSString *bad in @[ @"", @"2024-13-01", @"2024-03-01T25:00:00Z", @"2024-03-01T12:34:56", @"yesterday", @"2024-03-01T12:34:56Zjunk" ]) {
    XCTAssertNil(ODataDateFromString(bad), @"%@", bad);
  }
}

- (void)testDatesBeforeTheEpochAndLeapDays
{
  XCTAssertEqualObjects(ODataDateTimeOffsetString([self date:@"1948-12-08T00:00:00Z"]), @"1948-12-08T00:00:00Z");
  XCTAssertEqualObjects(ODataDateString([self date:@"2000-02-29"]), @"2000-02-29");
  XCTAssertEqualObjects(ODataDateString([self date:@"0001-01-01"]), @"0001-01-01");
}

- (void)testDateAttributeCanHoldAnEdmDate
{
  NSAttributeDescription *day = [self attribute:NSDateAttributeType edm:@"Edm.Date"];
  NSDate *date = [_coder coreDataValueForJSON:@"2024-03-01" attribute:day];
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:date attribute:day], @"2024-03-01");
  XCTAssertEqualObjects([_coder literalForValue:date attribute:day], @"2024-03-01");
  NSAttributeDescription *instant = [self attribute:NSDateAttributeType edm:nil];
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:date attribute:instant], @"2024-03-01T00:00:00Z");
  XCTAssertEqualObjects([_coder literalForValue:date attribute:instant], @"2024-03-01T00:00:00Z");
}

- (void)testUnparseableDateIsNoValue
{
  XCTAssertNil([_coder coreDataValueForJSON:@"not a date" attribute:[self attribute:NSDateAttributeType edm:nil]]);
}

#pragma mark - Numbers

- (void)testInt64KeepsEveryDigit
{
  NSAttributeDescription *attr = [self attribute:NSInteger64AttributeType edm:nil];
  // TripPin's Concurrency: past 2^53, so a double would round it.
  NSNumber *n = [_coder coreDataValueForJSON:@"639260022539945567" attribute:attr];
  XCTAssertEqual(n.longLongValue, 639260022539945567LL);
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:n attribute:attr], @"639260022539945567");
  XCTAssertEqualObjects([_coder literalForValue:n attribute:attr], @"639260022539945567");
  _coder.IEEE754Compatible = NO;
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:n attribute:attr], @639260022539945567LL);
  XCTAssertEqual([[_coder coreDataValueForJSON:@42 attribute:attr] longLongValue], 42LL);
}

- (void)testDecimalKeepsEveryDigit
{
  NSAttributeDescription *attr = [self attribute:NSDecimalAttributeType edm:nil];
  NSDecimalNumber *d = [_coder coreDataValueForJSON:@"12345678901234567890.123456789" attribute:attr];
  XCTAssertEqualObjects(d, [NSDecimalNumber decimalNumberWithString:@"12345678901234567890.123456789"]);
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:d attribute:attr], @"12345678901234567890.123456789");
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@"32.3800" attribute:attr], [NSDecimalNumber decimalNumberWithString:@"32.38"]);
  // No exponent in a literal, however small.
  NSDecimalNumber *tiny = [NSDecimalNumber decimalNumberWithString:@"0.0000000001"];
  XCTAssertEqualObjects([_coder literalForValue:tiny attribute:attr], @"0.0000000001");
  XCTAssertEqualObjects([_coder literalForValue:@20 attribute:attr], @"20");
  NSDecimalNumber *negative = [NSDecimalNumber decimalNumberWithString:@"-0.000123"];
  XCTAssertEqualObjects([_coder literalForValue:negative attribute:attr], @"-0.000123");
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:[NSDecimalNumber decimalNumberWithString:@"1200000000000000000000"] attribute:attr],
                        @"1200000000000000000000");
}

// A decimal written as a JSON number, which a parser reads as a double:
// the decimal it was written as, not the double's (68.40000000000001).
- (void)testADecimalReadAsADoubleIsTheDecimalWritten
{
  NSAttributeDescription *attr = [self attribute:NSDecimalAttributeType edm:nil];
  NSArray *parsed = [NSJSONSerialization JSONObjectWithData:[@"[68.4, 0.1, 1e-7, 12, -3.25]" dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0 error:NULL];
  NSArray *written = @[ @"68.4", @"0.1", @"0.0000001", @"12", @"-3.25" ];
  for (NSUInteger i = 0; i < written.count; i++) {
    XCTAssertEqualObjects([_coder coreDataValueForJSON:parsed[i] attribute:attr], [NSDecimalNumber decimalNumberWithString:written[i]]);
  }
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@68.4 attribute:attr], [NSDecimalNumber decimalNumberWithString:@"68.4"]);
}

- (void)testDecimalsMayComeWithAnExponent
{
  // JSON Format 4.01 section 7.1: a service may write 1.5E3 for 1500.
  NSAttributeDescription *attr = [self attribute:NSDecimalAttributeType edm:nil];
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@"1.5E3" attribute:attr], [NSDecimalNumber decimalNumberWithString:@"1500"]);
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@"2e-2" attribute:attr], [NSDecimalNumber decimalNumberWithString:@"0.02"]);
}

- (void)testDoubleSpecialValuesAreStrings
{
  NSAttributeDescription *attr = [self attribute:NSDoubleAttributeType edm:nil];
  XCTAssertTrue(isinf([[_coder coreDataValueForJSON:@"INF" attribute:attr] doubleValue]));
  XCTAssertTrue([[_coder coreDataValueForJSON:@"-INF" attribute:attr] doubleValue] < 0);
  XCTAssertTrue(isnan([[_coder coreDataValueForJSON:@"NaN" attribute:attr] doubleValue]));
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:@(NAN) attribute:attr], @"NaN");
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:@(-INFINITY) attribute:attr], @"-INF");
  XCTAssertEqualObjects([_coder literalForValue:@(INFINITY) attribute:attr], @"INF");
  XCTAssertEqualObjects([_coder literalForValue:@0.1 attribute:attr], @"0.1");
  // NSJSONSerialization throws on NaN; the body has to be writable.
  NSDictionary *body = @{ @"Value": [_coder JSONForCoreDataValue:@(NAN) attribute:attr] };
  XCTAssertNotNil([NSJSONSerialization dataWithJSONObject:body options:0 error:NULL]);
}

- (void)testBooleanIsAJSONBoolean
{
  NSAttributeDescription *attr = [self attribute:NSBooleanAttributeType edm:nil];
  NSDictionary *body = @{ @"Flag": [_coder JSONForCoreDataValue:@0 attribute:attr] };
  NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:body options:0 error:NULL]
                                         encoding:NSUTF8StringEncoding];
  XCTAssertTrue([json rangeOfString:@"false"].location != NSNotFound, @"%@", json);
  XCTAssertEqualObjects([_coder literalForValue:@1 attribute:attr], @"true");
}

#pragma mark - Everything else

- (void)testDurationIsSecondsInADouble
{
  NSAttributeDescription *attr = [self attribute:NSDoubleAttributeType edm:@"Edm.Duration"];
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@"P1DT2H3M4.5S" attribute:attr], @93784.5);
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@"-PT90S" attribute:attr], @-90.0);
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:@93784.5 attribute:attr], @"PT93784.5S");
  XCTAssertEqualObjects([_coder literalForValue:@90 attribute:attr], @"duration'PT90S'");
  XCTAssertNil([_coder coreDataValueForJSON:@"P1H" attribute:attr], @"hours need the T");
}

- (void)testTimeOfDayAndGuidOnStringsAreUnquoted
{
  NSAttributeDescription *time = [self attribute:NSStringAttributeType edm:@"Edm.TimeOfDay"];
  XCTAssertEqualObjects([_coder literalForValue:@"13:20:00" attribute:time], @"13:20:00");
  NSAttributeDescription *guidString = [self attribute:NSStringAttributeType edm:@"Edm.Guid"];
  XCTAssertEqualObjects([_coder literalForValue:@"9d9b2fa0-efbf-490e-a5e3-bac8f7d47354" attribute:guidString],
                        @"9d9b2fa0-efbf-490e-a5e3-bac8f7d47354");
  XCTAssertEqualObjects([_coder literalForValue:@"O'Brien" attribute:[self attribute:NSStringAttributeType edm:nil]], @"'O''Brien'");
}

- (void)testBinaryIsBase64URL
{
  NSAttributeDescription *attr = [self attribute:NSBinaryDataAttributeType edm:nil];
  unsigned char bytes[] = { 0xfb, 0xff, 0xbf, 0x00 };
  NSData *data = [NSData dataWithBytes:bytes length:sizeof bytes];
  XCTAssertEqualObjects([_coder JSONForCoreDataValue:data attribute:attr], @"-_-_AA");
  XCTAssertEqualObjects([_coder literalForValue:data attribute:attr], @"binary'-_-_AA'");
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@"-_-_AA" attribute:attr], data);
  // Northwind sends plain, padded base64.
  XCTAssertEqualObjects([_coder coreDataValueForJSON:@"+/+/AA==" attribute:attr], data);
}

- (void)testValuesWithoutAnAttributeAreTypedByClass
{
  XCTAssertEqualObjects([_coder literalForValue:[self date:@"2024-03-01T12:34:56Z"] attribute:nil], @"2024-03-01T12:34:56Z");
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:@"9D9B2FA0-EFBF-490E-A5E3-BAC8F7D47354"];
  XCTAssertEqualObjects([_coder literalForValue:uuid attribute:nil], @"9D9B2FA0-EFBF-490E-A5E3-BAC8F7D47354");
  XCTAssertEqualObjects([_coder literalForValue:@YES attribute:nil], @"true");
  XCTAssertEqualObjects([_coder literalForValue:nil attribute:nil], @"null");
}

#pragma mark - Through the translator

- (void)testPredicateLiteralsFollowTheComparedAttribute
{
  NSEntityDescription *entity = [[NSEntityDescription alloc] init];
  entity.name = @"Order";
  NSAttributeDescription *shipped = [self attribute:NSDateAttributeType edm:@"Edm.Date"];
  shipped.name = @"shipped";
  NSAttributeDescription *placed = [self attribute:NSDateAttributeType edm:nil];
  placed.name = @"placed";
  NSAttributeDescription *freight = [self attribute:NSDecimalAttributeType edm:nil];
  freight.name = @"freight";
  entity.properties = @[ shipped, placed, freight ];
  ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:[[ODataPropertyMapper alloc] init] entity:entity];
  NSDate *date = [self date:@"2024-03-01T12:00:00Z"];
  NSDecimalNumber *price = [NSDecimalNumber decimalNumberWithString:@"32.38"];
  NSError *error = nil;
  NSString *day = [t translatePredicate:[NSPredicate predicateWithFormat:@"shipped >= %@", date] error:&error];
  NSString *instant = [t translatePredicate:[NSPredicate predicateWithFormat:@"placed < %@", date] error:&error];
  NSString *amount = [t translatePredicate:[NSPredicate predicateWithFormat:@"freight > %@", price] error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqualObjects(day, @"Shipped ge 2024-03-01");
  XCTAssertEqualObjects(instant, @"Placed lt 2024-03-01T12:00:00Z");
  XCTAssertEqualObjects(amount, @"Freight gt 32.38");
}

@end
