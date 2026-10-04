// NSPredicate → OData ABNF commonExpr. No network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Spec: OASIS OData Version 4.0 ABNF (eq / ne / gt / ge / lt / le,
// andExpr / orExpr / notExpr, boolMethodCallExpr startswith/endswith/contains,
// tolower, inExpr). Protocol §11.2.5.1 System Query Option $filter.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

@interface ODataPredicateTranslatorTests : XCTestCase
@end

@implementation ODataPredicateTranslatorTests {
  ODataPredicateTranslator *_translator;
}

- (void)setUp
{
  [super setUp];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  NSEntityDescription *product = OISCatalogEntity(@"Product");
  XCTAssertNotNil(product, @"Catalog.xcdatamodeld at %@", OISCatalogModelURL());
  _translator = [[ODataPredicateTranslator alloc] initWithMapper:mapper entity:product];
}

// What the translator writes is OData a parser reads.
- (void)assertParses:(NSString *)filter
{
  NSError *error = nil;
  XCTAssertNotNil([ODataExpression expressionWithString:filter ?: @"" error:&error], @"%@ does not parse: %@", filter, error);
}

- (void)assertPredicate:(NSString *)format filter:(NSString *)expected
{
  NSError *error = nil;
  NSPredicate *predicate = [NSPredicate predicateWithFormat:format];
  NSString *got = [_translator translatePredicate:predicate error:&error];
  XCTAssertNil(error, @"%@ → %@", format, error);
  XCTAssertEqualObjects(got, expected, @"predicate %@", format);
  [self assertParses:got];
}

- (void)testComparisonOperatorsMatchABNF
{
  [self assertPredicate:@"unitPrice == 18" filter:@"UnitPrice eq 18"];
  [self assertPredicate:@"unitPrice != 18" filter:@"UnitPrice ne 18"];
  [self assertPredicate:@"unitPrice > 20" filter:@"UnitPrice gt 20"];
  [self assertPredicate:@"unitPrice >= 20" filter:@"UnitPrice ge 20"];
  [self assertPredicate:@"unitPrice < 10" filter:@"UnitPrice lt 10"];
  [self assertPredicate:@"unitPrice <= 10" filter:@"UnitPrice le 10"];
}

- (void)testBooleanAndNullLiterals
{
  [self assertPredicate:@"discontinued == NO" filter:@"Discontinued eq false"];
  [self assertPredicate:@"discontinued == YES" filter:@"Discontinued eq true"];
  [self assertPredicate:@"name == nil" filter:@"ProductName eq null"];
}

- (void)testStringLiteralEscapesQuote
{
  [self assertPredicate:@"name == \"O'Brien\"" filter:@"ProductName eq 'O''Brien'"];
}

- (void)testLogicalConnectives
{
  [self assertPredicate:@"unitPrice > 20 AND discontinued == NO"
                 filter:@"UnitPrice gt 20 and Discontinued eq false"];
  [self assertPredicate:@"unitPrice < 10 OR unitPrice > 100"
                 filter:@"UnitPrice lt 10 or UnitPrice gt 100"];
  [self assertPredicate:@"NOT discontinued == YES" filter:@"not (Discontinued eq true)"];
}

- (void)testCanonicalFunctions
{
  [self assertPredicate:@"name BEGINSWITH \"Ch\"" filter:@"startswith(ProductName, 'Ch')"];
  [self assertPredicate:@"name ENDSWITH \"e\"" filter:@"endswith(ProductName, 'e')"];
  [self assertPredicate:@"name CONTAINS \"lager\"" filter:@"contains(ProductName, 'lager')"];
}

- (void)testCaseInsensitiveUsesTolower
{
  [self assertPredicate:@"name BEGINSWITH[c] \"ch\""
                 filter:@"startswith(tolower(ProductName), tolower('ch'))"];
  [self assertPredicate:@"name CONTAINS[c] \"IPA\""
                 filter:@"contains(tolower(ProductName), tolower('IPA'))"];
}

// OData has no diacritic-insensitive comparison: [d] is refused, not dropped.
- (void)testDiacriticInsensitiveIsRefused
{
  for (NSString *format in @[ @"name ==[d] 'creme'", @"name BEGINSWITH[cd] 'cr'", @"ANY suppliers.city CONTAINS[d] 'o'" ]) {
    NSError *error = nil;
    XCTAssertNil([_translator translatePredicate:[NSPredicate predicateWithFormat:format] error:&error], @"%@", format);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedPredicate, @"%@", format);
  }
}

- (void)testInAndBetween
{
  // 4.0 has no `in`: Northwind answers it with 400, TripPin with 500.
  [self assertPredicate:@"name IN {\"Chai\", \"Chang\"}"
                 filter:@"ProductName eq 'Chai' or ProductName eq 'Chang'"];
  [self assertPredicate:@"name IN %@" filter:@"ProductName eq 'Chai'" arguments:@[ @[ @"Chai" ] ]];
  [self assertPredicate:@"name IN %@" filter:@"false" arguments:@[ @[] ]];
  _translator.version = @"4.01";
  [self assertPredicate:@"name IN {\"Chai\", \"Chang\"}"
                 filter:@"ProductName in ('Chai','Chang')"];
  _translator.version = @"4.0";
  // gnustep-base's parser rewrites BETWEEN as >= AND <= before the
  // translator sees it; the tree, and so the filter, is the same.
  [self assertPredicate:@"unitPrice BETWEEN {10, 20}" filter:@"UnitPrice ge 10 and UnitPrice le 20"];
}

- (void)assertPredicate:(NSString *)format filter:(NSString *)expected arguments:(NSArray *)arguments
{
  NSError *error = nil;
  NSString *got = [_translator translatePredicate:[NSPredicate predicateWithFormat:format argumentArray:arguments] error:&error];
  XCTAssertNil(error, @"%@ → %@", format, error);
  XCTAssertEqualObjects(got, expected, @"predicate %@", format);
  [self assertParses:got];
}

- (void)testPatternsAreMatchesPatternIn401
{
  _translator.version = @"4.01";
  // A wildcard is any character, a line terminator too, and \r\n as one.
  NSString *any = @"(?:\\r\\n|\\r(?!\\n)|[^\\r])";
  [self assertPredicate:@"name LIKE %@" filter:[NSString stringWithFormat:@"matchesPattern(ProductName, '^Ch%@*a%@$')", any, any] arguments:@[ @"Ch*a?" ]];
  [self assertPredicate:@"name LIKE[c] %@" filter:[NSString stringWithFormat:@"matchesPattern(tolower(ProductName), '^o''b\\.%@*$')", any] arguments:@[ @"O'B.*" ]];
  [self assertPredicate:@"name MATCHES %@" filter:@"matchesPattern(ProductName, '^C[a-z]+$')" arguments:@[ @"C[a-z]+" ]];
  [self assertPredicate:@"name MATCHES %@" filter:[NSString stringWithFormat:@"matchesPattern(ProductName, '^C%@\\.(?:x|y)$')", any] arguments:@[ @"\\AC.\\.(?:x|y)\\z" ]];
  NSError *error = nil;
  XCTAssertNil([_translator translatePredicate:[NSPredicate predicateWithFormat:@"name MATCHES[c] 'c.*'"] error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedPredicate);
  // What ICU and ECMAScript read differently is refused, not guessed: ^
  // and $ where this platform's MATCHES has them at each line (Apple's,
  // gnustep-base's with its fix), \d and \w (Unicode in ICU), inline
  // flags, sets within sets.
  NSMutableArray *refusals = [NSMutableArray arrayWithObjects:@"\\d+", @"\\w+", @"(?i)chai", @"[[a-z]]", nil];
  if ([ODataRegex matchesAnchorsMatchLines]) [refusals addObjectsFromArray:@[ @"^C.*", @"C.*$" ]];
  for (NSString *pattern in refusals) {
    error = nil;
    NSPredicate *refused = [NSPredicate predicateWithFormat:@"name MATCHES %@", pattern];
    NSString *written = [_translator translatePredicate:refused error:&error];
    XCTAssertNil(written, @"%@", pattern);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedPredicate, @"%@", pattern);
  }
}

- (void)assertPredicate:(NSString *)format on:(NSString *)entityName filter:(NSString *)expected
{
  ODataPredicateTranslator *t =
      [[ODataPredicateTranslator alloc] initWithMapper:[[ODataPropertyMapper alloc] init]
                                                entity:OISCatalogEntity(entityName)];
  NSError *error = nil;
  NSString *got = [t translatePredicate:[NSPredicate predicateWithFormat:format] error:&error];
  XCTAssertNil(error, @"%@ → %@", format, error);
  XCTAssertEqualObjects(got, expected, @"predicate %@", format);
  [self assertParses:got];
}

- (void)testAnyAndAllBecomeLambdas
{
  [self assertPredicate:@"ANY products.unitPrice > 100" on:@"Category"
                 filter:@"Products/any(x0:x0/UnitPrice gt 100)"];
  [self assertPredicate:@"ALL products.discontinued == NO" on:@"Category"
                 filter:@"Products/all(x0:x0/Discontinued eq false)"];
  [self assertPredicate:@"ANY category.products.name == 'Chai'" on:@"Product"
                 filter:@"Category/Products/any(x0:x0/ProductName eq 'Chai')"];
}

- (void)testNestedToManyNestsLambdas
{
  [self assertPredicate:@"ANY products.suppliers.city == 'London'" on:@"Category"
                 filter:@"Products/any(x0:x0/Suppliers/any(x1:x1/City eq 'London'))"];
}

- (void)testAnyOverToOneIsTheValue
{
  [self assertPredicate:@"ANY category.name == 'Beverages'" on:@"Product"
                 filter:@"Category/CategoryName eq 'Beverages'"];
}

- (void)testTrueFalsePredicate
{
  [self assertPredicate:@"TRUEPREDICATE" filter:@"true"];
  [self assertPredicate:@"FALSEPREDICATE" filter:@"false"];
}

- (void)testNavigationPathUsesSlash
{
  NSError *error = nil;
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"category.name == %@", @"Beverages"];
  NSString *got = [_translator translatePredicate:predicate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(got, @"Category/CategoryName eq 'Beverages'");
}

- (void)testCaseInsensitiveEquality
{
  // ==[c] is tolower on both sides, not a plain eq that forgets the case.
  [self assertPredicate:@"name ==[c] 'Chai'" filter:@"tolower(ProductName) eq tolower('Chai')"];
  [self assertPredicate:@"name !=[c] 'Chai'" filter:@"tolower(ProductName) ne tolower('Chai')"];
}

- (void)testCountsAndLength
{
  [self assertPredicate:@"suppliers.@count > 1" filter:@"Suppliers/$count gt 1"];
  [self assertPredicate:@"SUBQUERY(suppliers, $s, $s.city == 'London').@count > 0"
                 filter:@"Suppliers/any(x0:x0/City eq 'London')"];
  [self assertPredicate:@"SUBQUERY(suppliers, $s, $s.city == 'London').@count == 0"
                 filter:@"not Suppliers/any(x0:x0/City eq 'London')"];
  [self assertPredicate:@"SUBQUERY(suppliers, $s, NOT ($s.country == 'UK')).@count == 0"
                 filter:@"Suppliers/all(x0:x0/Country eq 'UK')"];
  [self assertPredicate:@"name.length > 10" filter:@"length(ProductName) gt 10"];
  [self assertPredicate:@"unitPrice + 1 > 20" filter:@"UnitPrice add 1 gt 20"];
}

// A model's name override that is no OData identifier: a problem of the
// model, and an error of the fetch that names it, not an exception.
- (void)testNameOverrideNoIdentifier
{
  NSEntityDescription *gadget = [[NSEntityDescription alloc] init];
  gadget.name = @"Gadget";
  gadget.managedObjectClassName = @"NSManagedObject";
  gadget.userInfo = @{ ODataUserInfoEntitySet: @"Gadgets" };
  NSAttributeDescription *key = [[NSAttributeDescription alloc] init];
  key.name = @"id";
  key.attributeType = NSInteger32AttributeType;
  key.userInfo = @{ @"OData.key": @"YES" };
  NSAttributeDescription *price = [[NSAttributeDescription alloc] init];
  price.name = @"price";
  price.attributeType = NSDoubleAttributeType;
  price.userInfo = @{ ODataUserInfoProperty: @"Price eq 0 or true" };
  gadget.properties = @[ key, price ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ gadget ];

  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  NSArray *problems = [mapper problemsWithModel:model];
  XCTAssertEqual(problems.count, 1u, @"%@", problems);
  XCTAssertTrue([problems.firstObject containsString:@"Gadget.price"], @"%@", problems);

  ODataPredicateTranslator *translator = [[ODataPredicateTranslator alloc] initWithMapper:mapper entity:gadget];
  NSError *error = nil;
  XCTAssertNil([translator translatePredicate:[NSPredicate predicateWithFormat:@"price > 1"] error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedExpression);
  XCTAssertTrue([error.localizedDescription containsString:@"Price eq 0 or true"], @"%@", error);
  XCTAssertEqualObjects([translator translatePredicate:[NSPredicate predicateWithFormat:@"id == 1"] error:NULL], @"Id eq 1");
}

// A SUBQUERY's count against anything but nought: at 4.01, the members
// counted that pass, $count($filter=...); its variable's paths the
// member's, SELF $it. 4.0 has no such count.
- (void)testFilteredCount
{
  NSError *error = nil;
  NSPredicate *more = [NSPredicate predicateWithFormat:@"SUBQUERY(suppliers, $s, $s.city == 'London').@count > 1"];
  XCTAssertNil([_translator translatePredicate:more error:&error]);
  XCTAssertTrue([error.localizedDescription containsString:@"4.01"], @"%@", error);
  _translator.version = @"4.01";
  [self assertPredicate:@"SUBQUERY(suppliers, $s, $s.city == 'London').@count > 1"
                 filter:@"Suppliers/$count($filter=City eq 'London') gt 1"];
  [self assertPredicate:@"count:(SUBQUERY(suppliers, $s, $s.city == 'London' AND $s.country != 'UK')) == 2"
                 filter:@"Suppliers/$count($filter=City eq 'London' and Country ne 'UK') eq 2"];
  [self assertPredicate:@"2 <= SUBQUERY(suppliers, $s, $s.city == 'London').@count"
                 filter:@"Suppliers/$count($filter=City eq 'London') ge 2"];
  [self assertPredicate:@"SUBQUERY(suppliers, $s, $s == SELF).@count < 3"
                 filter:@"Suppliers/$count($filter=$this eq $it) lt 3"];
  // Some and none are any and not any still.
  [self assertPredicate:@"SUBQUERY(suppliers, $s, $s.city == 'London').@count > 0"
                 filter:@"Suppliers/any(x0:x0/City eq 'London')"];
  // A key path not through the variable is the outer object's: refused.
  error = nil;
  NSPredicate *outer = [NSPredicate predicateWithFormat:@"SUBQUERY(suppliers, $s, city == 'London').@count > 1"];
  XCTAssertNil([_translator translatePredicate:outer error:&error]);
  XCTAssertTrue([error.localizedDescription containsString:@"$s.city"], @"%@", error);
  _translator.version = @"4.0";
}

// A collection operator after a to-many relationship is Data
// Aggregation's aggregate(), where the service has it; else refused.
- (void)testCollectionOperatorsAreAggregates
{
  ODataPredicateTranslator *categories = [[ODataPredicateTranslator alloc] initWithMapper:[[ODataPropertyMapper alloc] init]
                                                                                  entity:OISCatalogEntity(@"Category")];
  NSPredicate *sum = [NSPredicate predicateWithFormat:@"products.@sum.unitPrice > 40"];
  NSError *error = nil;
  XCTAssertNil([categories translatePredicate:sum error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedExpression);
  XCTAssertTrue([error.localizedDescription containsString:@"ApplySupported"], @"%@", error);

  categories.writesAggregates = YES;
  NSDictionary *cases = @{
    @"products.@sum.unitPrice > 40": @"Products/aggregate(UnitPrice with sum) gt 40",
    @"products.@avg.unitPrice < 20": @"Products/aggregate(UnitPrice with average) lt 20",
    @"products.@max.unitPrice >= products.@min.unitPrice": @"Products/aggregate(UnitPrice with max) ge Products/aggregate(UnitPrice with min)",
    @"products.@count > 2": @"Products/$count gt 2",
  };
  for (NSString *format in cases) {
    error = nil;
    NSString *got = [categories translatePredicate:[NSPredicate predicateWithFormat:format] error:&error];
    XCTAssertEqualObjects(got, cases[format], @"%@: %@", format, error);
    [self assertParses:got];
  }
  error = nil;
  XCTAssertNil([categories translatePredicate:[NSPredicate predicateWithFormat:@"products.@sum.suppliers > 1"] error:&error], @"not an attribute");
  XCTAssertNotNil(error);
}

- (void)testUnknownNamesAreErrorsNotGuesses
{
  NSError *error = nil;
  XCTAssertNil([_translator translatePredicate:[NSPredicate predicateWithFormat:@"colour == 'red'"] error:&error]);
  XCTAssertNotNil(error);
  error = nil;
  XCTAssertNil([_translator translatePredicate:[NSPredicate predicateWithFormat:@"suppliers.city == 'London'"] error:&error],
               @"a collection needs ANY or ALL");
  XCTAssertNotNil(error);
  error = nil;
  NSPredicate *notAnEntity = [NSPredicate predicateWithFormat:@"entity == %@", @"Product"];
  NSString *written = [_translator translatePredicate:notAnEntity error:&error];
  XCTAssertNil(written, @"a type test compares with an entity");
  XCTAssertNotNil(error);
}

- (void)testUnsupportedPredicateErrors
{
  NSError *error = nil;
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name MATCHES %@", @".*"];
  NSString *got = [_translator translatePredicate:predicate error:&error];
  XCTAssertNil(got);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedPredicate);
}

@end
