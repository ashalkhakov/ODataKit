// Resource path keys — OData ABNF keyPredicate / simpleKey / compoundKey.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import "ODataIncrementalStore.h"

@interface ODataResourceIdentifierTests : XCTestCase
@end

@implementation ODataResourceIdentifierTests

- (void)testSimpleNumericKey
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @1 }];
  XCTAssertEqualObjects(id1.path, @"Products(1)");
}

- (void)testSimpleStringKeyQuotes
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Categories" keys:@{ @"CategoryName": @"Beverages" }];
  XCTAssertEqualObjects(id1.path, @"Categories('Beverages')");
}

- (void)testCompoundKeyNamed
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Order_Details"
                                                    keys:@{ @"OrderID": @10248, @"ProductID": @11 }];
  XCTAssertEqualObjects(id1.path, @"Order_Details(OrderID=10248,ProductID=11)");
}

- (void)testKeyAsSegment
{
  // Part 2 section 4.3.6: the key's value, bare, as a segment of its own.
  ODataResourceIdentifier *product = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @1 }];
  XCTAssertEqualObjects([product pathWithKeyAsSegment:YES], @"Products/1");
  XCTAssertEqualObjects([product pathWithKeyAsSegment:NO], @"Products(1)");
  ODataResourceIdentifier *person = [[ODataResourceIdentifier alloc] initWithEntitySet:@"People" keys:@{ @"UserName": @"o'neil x y" }];
  XCTAssertEqualObjects([person pathWithKeyAsSegment:YES], @"People/o'neil%20x%20y", @"unquoted, and escaped");
  // Where a segment could read as something else (#47): in parentheses.
  NSDictionary *ambiguous = @{ @"anna@example.org": @"Users('anna@example.org')", @"a/b": @"Users('a%2Fb')", @"$count": @"Users('$count')",
                               @"f(x)": @"Users('f(x)')", @"": @"Users('')" };
  for (NSString *key in ambiguous) {
    ODataResourceIdentifier *user = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Users" keys:@{ @"Email": key }];
    XCTAssertEqualObjects([user pathWithKeyAsSegment:YES], ambiguous[key]);
  }
  ODataResourceIdentifier *price = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Prices" keys:@{ @"Amount": @1.5 }];
  XCTAssertEqualObjects([price pathWithKeyAsSegment:YES], @"Prices(1.5)", @"a decimal's '.'");
  ODataResourceIdentifier *line = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Order_Details"
                                                                                keys:@{ @"OrderID": @10248, @"ProductID": @11 }];
  XCTAssertEqualObjects([line pathWithKeyAsSegment:YES], @"Order_Details(OrderID=10248,ProductID=11)", @"a compound key keeps parentheses");
}

- (void)testRoundTripThroughJSONData
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @42 }];
  ODataResourceIdentifier *id2 = [ODataResourceIdentifier identifierFromReference:id1.data];
  XCTAssertEqualObjects(id2.path, id1.path);
  XCTAssertEqualObjects(id2.entitySet, @"Products");
}

- (void)testStringKeyEscapesQuote
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Employees" keys:@{ @"LastName": @"O'Brien" }];
  XCTAssertEqualObjects(id1.path, @"Employees('O''Brien')");
}

- (void)testKeyIsPercentEncodedInThePath
{
  // RFC 3986: a space, '/', '#', '?' and UTF-8 bytes are escaped; the
  // quotes and parentheses of OData's key syntax are not.
  ODataResourceIdentifier *identifier =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Customers" keys:@{ @"Name": @"Smith & Co/2 #1? \u00fc" }];
  XCTAssertEqualObjects(identifier.path, @"Customers('Smith%20%26%20Co%2F2%20%231%3F%20%C3%BC')");
  XCTAssertNotNil([NSURL URLWithString:[@"https://odata.test/" stringByAppendingString:identifier.path]]);
}

@end
