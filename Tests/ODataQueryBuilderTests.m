// NSFetchRequest → OData system query options. No network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Spec: OASIS OData 4.0 Protocol §11.2.5 System Query Options
// ($filter, $orderby, $top, $skip, $select, $expand) and §11.2.5.5 /$count.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

@interface ODataQueryBuilderTests : XCTestCase
@end

@implementation ODataQueryBuilderTests {
  ODataQueryBuilder *_builder;
}

- (void)setUp
{
  [super setUp];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  _builder = [[ODataQueryBuilder alloc] initWithMapper:mapper serviceRoot:OISTestServiceRoot()];
}

- (NSDictionary *)queryFromURL:(NSURL *)url
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSString *query = url.query;
  if (!query.length) return out;
  for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location == NSNotFound) continue;
    NSString *name = [pair substringToIndex:eq.location];
    NSString *value = [pair substringFromIndex:eq.location + 1];
#ifdef __APPLE__
    value = [value stringByRemovingPercentEncoding] ?: value;
#else
    value = [value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: value;
#endif
    out[name] = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
  }
  return out;
}

- (NSEntityDescription *)productEntity
{
  NSEntityDescription *product = OISCatalogEntity(@"Product");
  XCTAssertNotNil(product, @"Catalog.xcdatamodeld at %@", OISCatalogModelURL());
  return product;
}

// What the builder writes as it is (a resource path's names, query option
// names) is checked: a name OData does not allow there is the error, not
// part of a URL.
- (void)testNamesWrittenAreChecked
{
  NSError *error = nil;
  ODataResourceIdentifier *bad = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products?$filter=true" keys:@{ @"ProductID": @1 }];
  XCTAssertNil([_builder URLForIdentifier:bad error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorInvalidName, @"%@", error);
  error = nil;
  XCTAssertNil([_builder URLForReadingIdentifier:bad entity:[self productEntity] error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorInvalidName, @"%@", error);
  ODataResourceIdentifier *keys = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Orders" keys:@{ @"A": @1, @"B) or (x": @2 }];
  error = nil;
  XCTAssertNil([_builder URLForIdentifier:keys error:&error]);
  XCTAssertTrue([error.localizedDescription containsString:@"B) or (x"], @"%@", error);
  ODataResourceIdentifier *good = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @1 }];
  XCTAssertNotNil([_builder URLForIdentifier:good error:NULL]);

  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  options.customOptions = @{ @"a=1&$filter": @"true" };
  error = nil;
  XCTAssertNil([_builder URLForPath:@"Products" options:options error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorInvalidName, @"%@", error);
}

- (void)testFilterOrderbyTop
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:[self productEntity] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(url.path, @"/V4/Northwind.svc/Products");
  NSDictionary *q = [self queryFromURL:url];
  XCTAssertEqualObjects(q[@"$filter"], @"UnitPrice gt 20 and Discontinued eq false");
  XCTAssertEqualObjects(q[@"$orderby"], @"ProductName,ProductID");
  XCTAssertEqualObjects(q[@"$top"], @"25");
}

- (void)testOrderbyThroughRelationshipUsesSlash
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"category.name" ascending:NO] ];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:[self productEntity] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects([self queryFromURL:url][@"$orderby"], @"Category/CategoryName desc,ProductID");
}

- (void)testOrderbyDoesNotRepeatTheKey
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:NO] ];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:[self productEntity] error:&error];
  XCTAssertEqualObjects([self queryFromURL:url][@"$orderby"], @"ProductID desc");
}

- (void)testSkipAndExpand
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.fetchOffset = 10;
  fetch.relationshipKeyPathsForPrefetching = @[ @"category" ];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:[self productEntity] error:&error];
  XCTAssertNil(error);
  NSDictionary *q = [self queryFromURL:url];
  XCTAssertEqualObjects(q[@"$skip"], @"10");
  XCTAssertEqualObjects(q[@"$expand"], @"Category");
}

- (void)testNestedPrefetchIsNestedExpand
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.relationshipKeyPathsForPrefetching = @[ @"suppliers.products", @"category", @"suppliers" ];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:[self productEntity] error:&error];
  XCTAssertNil(error);
  // 4.0 has no paths in $expand: nested options, and one item per start;
  // each expanded row names its to-ones, as a fetched one does.
  XCTAssertEqualObjects([self queryFromURL:url][@"$expand"], @"Suppliers($expand=Products($expand=Category($select=CategoryID))),Category");
  NSError *parse = nil;
  XCTAssertNotNil([ODataQueryOptions optionsWithQuery:@{ @"$expand": [self queryFromURL:url][@"$expand"] } error:&parse], @"%@", parse);
}

- (void)testCountPath
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.resultType = NSCountResultType;
  fetch.predicate = [NSPredicate predicateWithFormat:@"discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 5;
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:[self productEntity] error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([url.path hasSuffix:@"/Products/$count"]);
  // $filter alone: TripPin answers 400 to $orderby on /$count.
  XCTAssertEqualObjects([self queryFromURL:url], @{ @"$filter": @"Discontinued eq false" });
}

- (void)testSelectFromDictionaryResult
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.resultType = NSDictionaryResultType;
  fetch.propertiesToFetch = @[ @"name", @"unitPrice" ];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:[self productEntity] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects([self queryFromURL:url][@"$select"], @"ProductName,UnitPrice");
}

- (void)testEntityByKeyAndNavigation
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @1 }];
  NSError *error = nil;
  NSURL *url = [_builder URLForIdentifier:id1 error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([url.path hasSuffix:@"/Products(1)"]);
  NSRelationshipDescription *rel = [self productEntity].relationshipsByName[@"category"];
  NSURL *nav = [_builder URLForIdentifier:id1 relationship:rel error:&error];
  XCTAssertTrue([nav.path hasSuffix:@"/Products(1)/Category"]);
}

@end
