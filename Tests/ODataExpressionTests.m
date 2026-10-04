// OData's URL syntax, parsed: expressions, query options, resource paths.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData 4.01 Part 2 (URL Conventions) and its ABNF: section 4
// (resource paths, key predicates), 5.1 (system query options), 5.1.1.14
// (operator precedence), and the literal forms of section 5.1.1.14.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

@interface ODataExpressionTests : XCTestCase
@end

@implementation ODataExpressionTests

- (ODataExpression *)parse:(NSString *)text
{
  NSError *error = nil;
  ODataExpression *e = [ODataExpression expressionWithString:text error:&error];
  XCTAssertNotNil(e, @"%@: %@", text, error);
  return e;
}

// Parsed, described canonically, and the description parses to itself.
- (void)assertText:(NSString *)text reads:(NSString *)canonical
{
  ODataExpression *e = [self parse:text];
  XCTAssertEqualObjects(e.description, canonical, @"%@", text);
  ODataExpression *again = [self parse:e.description ?: @""];
  XCTAssertEqualObjects(again.description, canonical, @"the description of %@ parses to itself", text);
}

- (void)testComparisonsAndConnectivesRoundTrip
{
  [self assertText:@"UnitPrice gt 20" reads:@"UnitPrice gt 20"];
  [self assertText:@"(UnitPrice gt 20) and (Discontinued eq false)" reads:@"UnitPrice gt 20 and Discontinued eq false"];
  [self assertText:@"not (A eq 1 or B eq 2)" reads:@"not (A eq 1 or B eq 2)"];
  [self assertText:@"A eq 1 or B eq 2 and C eq 3" reads:@"A eq 1 or B eq 2 and C eq 3"];
  [self assertText:@"(A eq 1 or B eq 2) and C eq 3" reads:@"(A eq 1 or B eq 2) and C eq 3"];
  [self assertText:@"ProductID in (1, 2, 3)" reads:@"ProductID in (1,2,3)"];
  [self assertText:@"Flags has Zoo.Features'Mane'" reads:@"Flags has Zoo.Features'Mane'"];
}

// A name the builders refuse: nil, and the error saying which.
- (void)assertRefused:(id (^)(NSError **error))build name:(NSString *)name
{
  NSError *error = nil;
  XCTAssertNil(build(&error), @"%@ built", name);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorInvalidName, @"%@: %@", name, error);
  XCTAssertTrue([error.localizedDescription containsString:name], @"%@: %@", name, error);
}

// Names the builders write as they are: those OData allows there, and no
// other (it could carry filter text), refused with an error.
- (void)testNamesBuiltAreChecked
{
  NSError *error = nil;
  ODataExpression *price = [ODataExpression member:@"UnitPrice" of:nil error:&error];
  XCTAssertEqualObjects(price.description, @"UnitPrice", @"%@", error);
  XCTAssertEqualObjects(([ODataExpression memberPath:@[ @"Category", @"_Name2" ] of:nil error:NULL].description), @"Category/_Name2");
  XCTAssertEqualObjects(([ODataExpression cast:@"Edm.Int32" of:price error:NULL].description), @"UnitPrice/Edm.Int32");
  XCTAssertEqualObjects(([ODataExpression cast:@"Org.Example.Manager" of:nil error:NULL].description), @"Org.Example.Manager");
  for (NSString *name in @[ @"$it", @"$root", @"$these", @"$this", @"x0" ]) {
    XCTAssertEqualObjects([ODataExpression variable:name error:NULL].description, name);
  }
  XCTAssertEqualObjects([ODataExpression alias:@"@p1" error:NULL].description, @"@p1");
  XCTAssertEqualObjects([ODataExpression alias:@"p" error:NULL].description, @"@p");
  XCTAssertEqualObjects(([ODataExpression call:@"NS.Rating" of:price namedArguments:@{ @"On": [ODataExpression literalWithValue:@1] } error:NULL].description),
                        @"UnitPrice/NS.Rating(On=1)");

  NSString *long128 = [@"" stringByPaddingToLength:128 withString:@"a" startingAtIndex:0];
  XCTAssertNotNil([ODataExpression member:long128 of:nil error:NULL]);
  XCTAssertTrue(ODataIsIdentifier(@"_a1") && ODataIsIdentifier(long128) && ODataIsQualifiedName(@"Edm.String"));
  XCTAssertFalse(ODataIsIdentifier(@"1a") || ODataIsIdentifier(@"") || ODataIsIdentifier(nil) || ODataIsQualifiedName(@"String") ||
                 ODataIsQualifiedName(@"NS..T") || ODataIsIdentifier([long128 stringByAppendingString:@"a"]));

  [self assertRefused:^id(NSError **e) { return [ODataExpression member:@"A eq 1 or true" of:nil error:e]; } name:@"A eq 1 or true"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression member:@"Category/Name" of:nil error:e]; } name:@"Category/Name"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression member:@"Unit Price" of:nil error:e]; } name:@"Unit Price"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression member:@"$count" of:nil error:e]; } name:@"$count"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression memberPath:@[ @"Category", @"Name) or (1" ] of:nil error:e]; } name:@"Name) or (1"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression cast:@"NS.T) or (1" of:nil error:e]; } name:@"NS.T) or (1"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression cast:@"Manager" of:nil error:e]; } name:@"Manager"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression variable:@"$x" error:e]; } name:@"$x"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression alias:@"@p or true" error:e]; } name:@"@p or true"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression binary:@"eq 1 or" left:price right:price error:e]; } name:@"eq 1 or"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression unary:@"not not" operand:price error:e]; } name:@"not not"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression call:@"contains(x) or startswith" arguments:@[] error:e]; } name:@"contains(x)"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression call:@"NS.F" of:nil namedArguments:@{ @"p) or (q": price } error:e]; } name:@"p) or (q"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression lambda:@"some" of:price variable:@"x" body:price error:e]; } name:@"some"];
  [self assertRefused:^id(NSError **e) { return [ODataExpression lambda:@"any" of:price variable:@"x:true) or (y" body:price error:e]; } name:@"x:true"];

  // A tree built as it is written, checked once at its root: the part that
  // failed says why, and what holds it is nil without a word of its own.
  error = nil;
  ODataExpression *filter = [ODataExpression binary:@"and"
                                               left:[ODataExpression binary:@"gt" left:[ODataExpression member:@"Price eq 0 or true" of:nil error:&error]
                                                                      right:[ODataExpression literalWithValue:@1] error:&error]
                                              right:[ODataExpression unary:@"not" operand:price error:&error] error:&error];
  XCTAssertNil(filter);
  XCTAssertTrue([error.localizedDescription containsString:@"Price eq 0 or true"], @"%@", error);
  error = nil;
  ODataExpression *failed = nil;
  XCTAssertNil([ODataExpression binary:@"eq" left:failed right:price error:&error]);
  XCTAssertNil(error, @"nothing to say: what built the nil has said it");
  XCTAssertNil([ODataExpression countOf:failed]);

  // The parser builds through the builders: what they refuse does not parse.
  error = nil;
  XCTAssertNil([ODataExpression expressionWithString:@"$foo eq 1" error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@", error);
}

// Cars/$count($filter=...): the members counted that pass (OData 4.01).
- (void)testFilteredCount
{
  NSError *error = nil;
  ODataExpression *cars = [ODataExpression member:@"Cars" of:nil error:&error];
  XCTAssertEqualObjects([ODataExpression countOf:cars filter:nil].description, @"Cars/$count");
  ODataExpression *nr = [ODataExpression member:@"Nr" of:[ODataExpression variable:@"x" error:&error] error:&error];
  ODataExpression *itsNr = [ODataExpression member:@"Nr" of:[ODataExpression variable:@"$it" error:&error] error:&error];
  ODataExpression *owned = [ODataExpression lambda:@"any" of:[ODataExpression member:@"IsOwnedByEmployees" of:nil error:&error] variable:@"x"
                                              body:[ODataExpression binary:@"eq" left:nr right:itsNr error:&error] error:&error];
  XCTAssertNotNil(owned, @"%@", error);
  ODataExpression *count = [ODataExpression countOf:cars filter:owned];
  XCTAssertEqualObjects(count.countFilter, owned);
  XCTAssertNil([ODataExpression countOf:cars].countFilter);
  XCTAssertNil(owned.countFilter, @"a lambda's body is no count's filter");
  NSString *text = @"OwnsCars/any() and not (Cars/$count($filter=IsOwnedByEmployees/any(x:x/Nr eq $it/Nr)) gt 1)";
  ODataExpression *some = [ODataExpression lambda:@"any" of:[ODataExpression member:@"OwnsCars" of:nil error:&error] variable:nil body:nil error:&error];
  ODataExpression *more = [ODataExpression binary:@"gt" left:count right:[ODataExpression literalWithValue:@1] error:&error];
  ODataExpression *built = [ODataExpression binary:@"and" left:some right:[ODataExpression unary:@"not" operand:more error:&error] error:&error];
  XCTAssertEqualObjects(built.description, text, @"%@", error);

  // Read: the same tree; filter without its $, and $this, a variable.
  ODataExpression *parsed = [ODataExpression expressionWithString:text error:&error];
  XCTAssertEqualObjects(parsed.description, text, @"%@", error);
  ODataExpression *readCount = parsed.right.operand.left;
  XCTAssertEqual(readCount.kind, ODataExpressionCount);
  XCTAssertEqualObjects(readCount.countFilter.description, owned.description);
  ODataExpression *bare = [ODataExpression expressionWithString:@"Cars/$count(filter=$this/Color eq 'red') ge 2" error:&error];
  XCTAssertEqualObjects(bare.description, @"Cars/$count($filter=$this/Color eq 'red') ge 2", @"%@", error);
  XCTAssertEqual(bare.left.countFilter.left.operand.kind, ODataExpressionVariable);
  XCTAssertEqualObjects([ODataExpression expressionWithString:@"Cars/$count($filter=Color eq 'red';$filter=Nr eq 1) gt 0" error:NULL], nil);
  XCTAssertNil([ODataExpression expressionWithString:@"Cars/$count($top=1) gt 0" error:NULL]);
  XCTAssertNil([ODataExpression expressionWithString:@"Cars/$count($filter=Color eq 'red' gt 0" error:NULL]);
  error = nil;
  XCTAssertNil([ODataExpression expressionWithString:@"Cars/$count($search=red) gt 0" error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedExpression, @"%@", error);

  // Its parts are walked: replaced, found.
  ODataExpression *red = [ODataExpression expressionWithString:@"Cars/$count($filter=Color eq @c) gt 0" error:NULL];
  XCTAssertEqualObjects([red expressionReplacing:@{ @"@c": @"red" }].description, @"Cars/$count($filter=Color eq 'red') gt 0");
  XCTAssertEqual([red partsPassingTest:^BOOL(ODataExpression *part) { return part.kind == ODataExpressionAlias; }].count, 1u);
}

// Expressions built, not read: each describes itself as $filter writes it,
// in parentheses only where the precedence needs them.
- (void)testExpressionsBuilt
{
  NSError *error = nil;
  ODataExpression *price = [ODataExpression member:@"UnitPrice" of:nil error:&error];
  ODataExpression *sum = [ODataExpression binary:@"add" left:price right:[ODataExpression literalWithValue:@1] error:&error];
  ODataExpression *gt = [ODataExpression binary:@"gt" left:sum right:[ODataExpression literalWithValue:@20] error:&error];
  XCTAssertEqualObjects(gt.description, @"UnitPrice add 1 gt 20", @"%@", error);
  ODataExpression *times = [ODataExpression binary:@"mul" left:sum right:[ODataExpression literalWithValue:@2] error:&error];
  XCTAssertEqualObjects(times.description, @"(UnitPrice add 1) mul 2");
  ODataExpression *category = [ODataExpression memberPath:@[ @"Category", @"CategoryName" ] of:nil error:&error];
  ODataExpression *either = [ODataExpression binary:@"or" left:gt
                                              right:[ODataExpression binary:@"eq" left:category right:[ODataExpression literalWithValue:@"it's"] error:&error]
                                              error:&error];
  ODataExpression *both = [ODataExpression binary:@"and" left:either
                                            right:[ODataExpression unary:@"not" operand:[ODataExpression member:@"Discontinued" of:nil error:&error] error:&error]
                                            error:&error];
  XCTAssertEqualObjects(both.description, @"(UnitPrice add 1 gt 20 or Category/CategoryName eq 'it''s') and not Discontinued");
  ODataExpression *city = [ODataExpression binary:@"eq" left:[ODataExpression member:@"City" of:[ODataExpression variable:@"s" error:&error] error:&error]
                                            right:[ODataExpression literalWithValue:@"London"] error:&error];
  ODataExpression *suppliers = [ODataExpression member:@"Suppliers" of:nil error:&error];
  XCTAssertEqualObjects(([ODataExpression lambda:@"any" of:suppliers variable:@"s" body:city error:&error].description),
                        @"Suppliers/any(s:s/City eq 'London')");
  XCTAssertEqualObjects(([ODataExpression lambda:@"any" of:suppliers variable:nil body:nil error:&error].description), @"Suppliers/any()");
  XCTAssertEqualObjects(([ODataExpression call:@"contains" arguments:@[ [ODataExpression member:@"Name" of:nil error:&error], [ODataExpression literalWithValue:@"x"] ]
                                         error:&error].description),
                        @"contains(Name, 'x')");
  XCTAssertEqualObjects(([ODataExpression call:@"Zoo.Age" of:nil namedArguments:@{ @"On": [ODataExpression literalWithText:@"2024-01-01"] } error:&error].description),
                        @"Zoo.Age(On=2024-01-01)");
  XCTAssertEqualObjects(([ODataExpression countOf:suppliers].description), @"Suppliers/$count");
  XCTAssertEqualObjects(([ODataExpression member:@"Budget" of:[ODataExpression cast:@"NS.Manager" of:nil error:&error] error:&error].description),
                        @"NS.Manager/Budget");
  XCTAssertEqualObjects(([ODataExpression binary:@"in" left:price right:[ODataExpression list:@[ [ODataExpression literalWithValue:@1], [ODataExpression literalWithValue:@2] ]]
                                           error:&error].description),
                        @"UnitPrice in (1,2)");
  ODataExpression *these = [ODataExpression variable:@"$these" error:&error];
  XCTAssertEqualObjects(([ODataExpression aggregateOf:these text:@"Amount with sum" error:&error].description), @"$these/aggregate(Amount with sum)");
  XCTAssertNil([ODataExpression aggregateOf:these text:@"Amount with sum) or (true" error:&error], @"what is read is written, never the text");
  // Built rather than read: the same, and what is no identifier refused.
  ODataExpression *sales = [ODataExpression member:@"Sales" of:nil error:&error];
  ODataAggregate *byPrice = [ODataAggregate aggregateOfPath:@[ @"Product", @"Price" ] method:@"sum" alias:@"x" error:&error];
  ODataExpression *total = [ODataExpression aggregateOf:sales aggregate:byPrice error:&error];
  XCTAssertEqualObjects(total.description, @"Sales/aggregate(Product/Price with sum)", @"%@", error);
  XCTAssertEqualObjects([ODataExpression expressionWithString:[total.description stringByAppendingString:@" gt 5"] error:NULL].description,
                        [total.description stringByAppendingString:@" gt 5"]);
  XCTAssertEqualObjects(([ODataExpression aggregateOf:sales aggregate:[ODataAggregate aggregateOfPath:nil method:nil alias:@"n" error:NULL] error:NULL].description),
                        @"Sales/aggregate($count)");
  ODataAggregate *expressed = [ODataAggregate aggregateOfExpression:[ODataExpression binary:@"mul" left:price right:[ODataExpression literalWithValue:@2] error:NULL]
                                                             method:@"sum" alias:@"d" error:&error];
  XCTAssertEqualObjects(([ODataExpression aggregateOf:sales aggregate:expressed error:&error].description), @"Sales/aggregate(UnitPrice mul 2 with sum)");
  XCTAssertNil(([ODataExpression aggregateOf:sales aggregate:@"Price with sum" error:NULL]));
  // A custom method is a qualified name; $count of a path.
  XCTAssertEqualObjects(([ODataExpression aggregateOf:sales aggregate:[ODataAggregate aggregateOfPath:@[ @"Price" ] method:@"Custom.median" alias:@"m" error:NULL]
                                                error:NULL].description),
                        @"Sales/aggregate(Price with Custom.median)");
  XCTAssertEqualObjects(([ODataExpression aggregateOf:sales aggregate:[ODataAggregate aggregateOfPath:@[ @"Lines" ] method:@"$count" alias:@"n" error:NULL]
                                                error:NULL].description),
                        @"Sales/aggregate(Lines/$count)");
  XCTAssertNil(([ODataExpression aggregateOf:sales aggregate:[ODataAggregate aggregateOfCustom:@"Forecast" alias:@"f" error:NULL] error:NULL]));
  XCTAssertEqualObjects(([ODataExpression literalWithText:@"Zoo.Diet'Carnivore'"].description), @"Zoo.Diet'Carnivore'");
  XCTAssertNil(([ODataExpression literalWithText:@"Name"]), @"no literal");
}

// Query options' and $apply's names: checked as the expressions' are,
// refused with an error; and an $apply that names what they refuse is a
// syntax error, never an exception.
- (void)testQueryNamesBuiltAreChecked
{
  ODataExpression *price = [ODataExpression member:@"Price" of:nil error:NULL];
  XCTAssertEqualObjects(([ODataSelectItem itemWithPath:@[ @"Category", @"NS.Special", @"Name" ] error:NULL].description), @"Category/NS.Special/Name");
  XCTAssertEqualObjects(([ODataSelectItem itemWithPath:@[ @"NS.*" ] error:NULL].description), @"NS.*");
  XCTAssertEqualObjects(([ODataSelectItem itemWithPath:@[ @"NS.Type", @"*" ] error:NULL].description), @"NS.Type/*");
  XCTAssertTrue(([ODataSelectItem itemWithPath:@[ @"*" ] error:NULL].isStar));
  XCTAssertTrue(([ODataExpandItem itemWithPath:@[ @"*" ] options:nil error:NULL].isStar));
  [self assertRefused:^id(NSError **e) { return [ODataSelectItem itemWithPath:@[ @"Nr eq 0 or true" ] error:e]; } name:@"Nr eq 0 or true"];
  [self assertRefused:^id(NSError **e) { return [ODataSelectItem itemWithPath:@[ @"*", @"Name" ] error:e]; } name:@"*"];
  [self assertRefused:^id(NSError **e) { return [ODataExpandItem itemWithPath:@[ @"Orders($filter=true)" ] options:nil error:e]; } name:@"Orders($filter=true)"];
  [self assertRefused:^id(NSError **e) { return [ODataExpandItem itemWithPath:@[ @"Orders", @"*" ] options:nil error:e]; } name:@"*"];
  [self assertRefused:^id(NSError **e) { return [ODataComputeItem itemWithExpression:price alias:@"x,y" error:e]; } name:@"x,y"];
  [self assertRefused:^id(NSError **e) { return [ODataAggregate aggregateOfPath:@[ @"Price) gt 0 or (1" ] method:@"sum" alias:@"x" error:e]; } name:@"Price) gt 0 or (1"];
  [self assertRefused:^id(NSError **e) { return [ODataAggregate aggregateOfPath:@[ @"Price" ] method:@"sum) or (x" alias:@"x" error:e]; } name:@"sum) or (x"];
  [self assertRefused:^id(NSError **e) { return [ODataAggregate aggregateOfPath:@[ @"Price" ] method:@"sum" alias:@"x as y" error:e]; } name:@"x as y"];
  [self assertRefused:^id(NSError **e) { return [ODataAggregate aggregateOfPath:@[] method:@"$count" alias:@"n" error:e]; } name:@"("];
  [self assertRefused:^id(NSError **e) { return [ODataAggregate aggregateOfPath:nil method:@"sum" alias:@"n" error:e]; } name:@"sum"];
  [self assertRefused:^id(NSError **e) { return [ODataAggregate aggregateOfCustom:@"F) or (x" alias:@"f" error:e]; } name:@"F) or (x"];
  [self assertRefused:^id(NSError **e) { return [ODataAggregate aggregateOfExpression:price method:@"sum as z" alias:@"f" error:e]; } name:@"sum as z"];
  [self assertRefused:^id(NSError **e) { return [ODataApplyTransformation groupByPaths:@[ @[ @"A)/aggregate(" ] ] aggregates:@[] error:e]; } name:@"A)/aggregate("];
  [self assertRefused:^id(NSError **e) {
    return [ODataApplyTransformation hierarchical:@"ancestors" hierarchy:@[ @"Orgs" ] qualifier:@"H) or (x" nodePath:@[ @"ID" ] sequence:@[] maxDistance:0
                                        keepStart:NO error:e];
  } name:@"H) or (x"];
  [self assertRefused:^id(NSError **e) {
    return [ODataApplyTransformation traverseHierarchy:@[ @"Orgs" ] qualifier:@"H" nodePath:@[ @"ID,x" ] postorder:NO orderBy:nil error:e];
  } name:@"ID,x"];
  [self assertRefused:^id(NSError **e) {
    return [ODataSearchExpression searchWithKind:ODataSearchWord text:@"tea OR coffee" left:nil right:nil error:e];
  } name:@"tea OR coffee"];
  [self assertRefused:^id(NSError **e) { return [ODataSearchExpression searchWithKind:ODataSearchWord text:@"OR" left:nil right:nil error:e]; } name:@"OR"];
  XCTAssertEqualObjects(([ODataSearchExpression searchWithKind:ODataSearchPhrase text:@"say \"hi\"" left:nil right:nil error:NULL].description), @"\"say \\\"hi\\\"\"");

  // $apply that names what the builders refuse: a syntax error (a 400).
  for (NSString *apply in @[ @"groupby((1Name))", @"groupby((Sales.))", @"aggregate(Price with sum as 1x)", @"groupby((a..b))" ]) {
    NSError *error = nil;
    XCTAssertNil([ODataApplyTransformation transformationsWithString:apply error:&error], @"%@", apply);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@: %@", apply, error);
  }
  NSError *error = nil;
  XCTAssertNil([ODataExpression expressionWithString:@"Sales/aggregate(Amount.. with sum) gt 1" error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@", error);

  // expand(): its filter read as an expression and written from it, in
  // $apply's own syntax, which reads back the same.
  NSArray *expanded = [ODataApplyTransformation transformationsWithString:@"expand(Products,filter(UnitPrice  gt 18))" error:&error];
  ODataApplyTransformation *expand = expanded.firstObject;
  XCTAssertEqualObjects(expand.expandItem.options.filter.description, @"UnitPrice gt 18", @"%@", error);
  XCTAssertEqualObjects([ODataApplyTransformation stringForTransformations:expanded], @"expand(Products,filter(UnitPrice gt 18))");
  XCTAssertEqualObjects(expand.expansion, @"Products($filter=UnitPrice gt 18)");
  XCTAssertEqualObjects([ODataApplyTransformation stringForTransformations:
                          [ODataApplyTransformation transformationsWithString:@"expand(Category)" error:NULL]], @"expand(Category)");
  for (NSString *apply in @[ @"expand(Products,filter(UnitPrice gt))", @"expand(Products,filter(true) or (1))", @"expand(Products/x y)" ]) {
    error = nil;
    XCTAssertNil([ODataApplyTransformation transformationsWithString:apply error:&error], @"%@", apply);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@: %@", apply, error);
  }
  ODataMutableQueryOptions *tooMuch = [[ODataMutableQueryOptions alloc] init];
  tooMuch.top = @1;
  ODataExpandItem *topped = [ODataExpandItem itemWithPath:@[ @"Products" ] options:tooMuch error:NULL];
  [self assertRefused:^id(NSError **e) { return [ODataApplyTransformation expandWithItem:topped error:e]; } name:@"Products($top=1)"];
  ODataExpandItem *star = [ODataExpandItem itemWithPath:@[ @"*" ] options:nil error:NULL];
  [self assertRefused:^id(NSError **e) { return [ODataApplyTransformation expandWithItem:star error:e]; } name:@"*"];

  // Names written as they are, into the query string: aliases' and custom
  // options', checked as they are written.
  ODataMutableQueryOptions *options = [[ODataMutableQueryOptions alloc] init];
  options.customOptions = @{ @"x=1&$filter": @"true" };
  error = nil;
  XCTAssertNil([options queryItemsWithError:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorInvalidName, @"%@", error);
  options.customOptions = @{ @"$filter": @"true" };
  XCTAssertNil([options queryItemsWithError:NULL], @"no system option by the back door");
  options.customOptions = @{ @"debug-mode": @"on" };
  options.aliases = @{ @"p) or (q": [ODataExpression literalWithValue:@1] };
  XCTAssertNil([options queryItemsWithError:NULL]);
  options.aliases = @{ @"p": [ODataExpression literalWithValue:@1] };
  XCTAssertEqualObjects([options queryItemsWithError:NULL], (@[ @[ @"@p", @"1" ], @[ @"debug-mode", @"on" ] ]));
}

// Query options as a query string's items, and read back the same.
- (void)testQueryOptionsWrittenAndReadBack
{
  NSDictionary *query = @{ @"$filter": @"UnitPrice gt 20", @"$orderby": @"Name desc,ID", @"$select": @"ID,Name", @"$top": @"5", @"$skip": @"10",
                           @"$count": @"true", @"$expand": @"Category($select=Name;$expand=Products($filter=Price gt 1;$top=2))",
                           @"$search": @"(tea OR coffee)", @"$apply": @"filter(Price gt 1)/groupby((Category/Name),aggregate(Price with sum as Total))",
                           @"$compute": @"Price mul 2 as Twice", @"$at": @"2024-01-01", @"@p": @"5", @"custom": @"yes" };
  NSError *error = nil;
  ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:query error:&error];
  XCTAssertNotNil(options, @"%@", error);
  NSArray *items = [options queryItemsWithError:&error];
  NSMutableDictionary *written = [NSMutableDictionary dictionary];
  for (NSArray *item in items) written[item[0]] = item[1];
  XCTAssertEqualObjects(written, query, @"%@", error);
  NSMutableArray *names = [NSMutableArray array];
  for (NSArray *item in items) [names addObject:item[0]];
  XCTAssertEqualObjects(names,
                        (@[ @"$at", @"$filter", @"$search", @"$apply", @"$orderby", @"$top", @"$skip", @"$count", @"$compute", @"$select", @"$expand", @"@p", @"custom" ]));

  ODataMutableQueryOptions *built = [[ODataMutableQueryOptions alloc] init];
  ODataExpression *price = [ODataExpression member:@"Price" of:nil error:&error];
  built.filter = [ODataExpression binary:@"gt" left:price right:[ODataExpression literalWithValue:@1] error:&error];
  built.orderBy = @[ [ODataOrderItem itemWithExpression:[ODataExpression member:@"Name" of:nil error:&error] descending:YES] ];
  ODataMutableQueryOptions *nested = [[ODataMutableQueryOptions alloc] init];
  nested.select = @[ [ODataSelectItem itemWithPath:@[ @"ID" ] error:&error] ];
  built.expand = @[ [ODataExpandItem itemWithPath:@[ @"Category" ] options:nested error:&error] ];
  built.searchExpression = [ODataSearchExpression searchWithString:@"tea" error:NULL];
  built.temporalFrom = [ODataExpression literalWithText:@"2024-01-01"];
  built.compute = @[ [ODataComputeItem itemWithExpression:price alias:@"P" error:&error] ];
  XCTAssertEqualObjects([built queryItemsWithError:&error], (@[ @[ @"$from", @"2024-01-01" ], @[ @"$filter", @"Price gt 1" ], @[ @"$search", @"tea" ],
                                                               @[ @"$orderby", @"Name desc" ], @[ @"$compute", @"Price as P" ], @[ @"$expand", @"Category($select=ID)" ] ]),
                        @"%@", error);
  XCTAssertEqualObjects(built.search, @"tea");
  XCTAssertEqualObjects(built.temporalText, @{ @"$from": @"2024-01-01" });
  ODataMutableQueryOptions *copy = [options mutableCopy];
  copy.top = @1;
  XCTAssertEqualObjects(options.top, @5, @"a copy of its own");
  XCTAssertEqualObjects(copy.filter.description, @"UnitPrice gt 20");
}

- (void)testArithmeticBindsAsThePrecedenceTableSays
{
  ODataExpression *e = [self parse:@"Price add 1 mul 2 gt 10"];
  XCTAssertEqualObjects(e.name, @"gt");
  XCTAssertEqualObjects(e.left.name, @"add");
  XCTAssertEqualObjects(e.left.right.name, @"mul", @"mul binds tighter than add");
  [self assertText:@"(Price add 1) mul 2 gt 10" reads:@"(Price add 1) mul 2 gt 10"];
  [self assertText:@"Price sub (Discount sub 1) lt 5" reads:@"Price sub (Discount sub 1) lt 5"];
  [self assertText:@"-Price lt 0" reads:@"-Price lt 0"];
  [self assertText:@"Price lt -5" reads:@"Price lt -5"];
}

- (void)testLiteralsOfEveryKind
{
  NSDictionary *cases = @{
    @"'it''s'": @[ @"Edm.String", @"it's" ],
    @"42": @[ @"Edm.Int64", @42 ],
    @"32.38": @[ @"Edm.Decimal", [NSDecimalNumber decimalNumberWithString:@"32.38"] ],
    @"1.5E3": @[ @"Edm.Double", @1500.0 ],
    @"true": @[ @"Edm.Boolean", @YES ],
    @"2018-02-11": @[ @"Edm.Date", @"2018-02-11" ],
    @"2024-03-01T14:34:56.1234567+02:00": @[ @"Edm.DateTimeOffset", @"2024-03-01T14:34:56.1234567+02:00" ],
    @"2024-01-01T12:00:00Z": @[ @"Edm.DateTimeOffset", @"2024-01-01T12:00:00Z" ],
    @"13:20:00": @[ @"Edm.TimeOfDay", @"13:20:00" ],
    @"01234567-89ab-cdef-0123-456789abcdef": @[ @"Edm.Guid", @"01234567-89ab-cdef-0123-456789abcdef" ],
    @"deadbeef-89ab-cdef-0123-456789abcdef": @[ @"Edm.Guid", @"deadbeef-89ab-cdef-0123-456789abcdef" ],
    @"duration'P1DT2H'": @[ @"Edm.Duration", @"P1DT2H" ],
    @"binary'AQID'": @[ @"Edm.Binary", @"AQID" ],
    @"NS.Color'Red,Blue'": @[ @"NS.Color", @"Red,Blue" ],
  };
  for (NSString *text in cases) {
    ODataExpression *e = [self parse:[@"X eq " stringByAppendingString:text]].right;
    XCTAssertEqual(e.kind, ODataExpressionLiteral, @"%@", text);
    XCTAssertEqualObjects(e.literalType, cases[text][0], @"%@", text);
    XCTAssertEqualObjects(e.value, cases[text][1], @"%@", text);
    XCTAssertEqualObjects(e.description, text, @"a literal describes itself as written");
  }
  ODataExpression *null = [self parse:@"X eq null"].right;
  XCTAssertEqualObjects(null.value, [NSNull null]);
}

- (void)testPathsLambdasAndFunctions
{
  ODataExpression *e = [self parse:@"Category/CategoryName eq 'Beverages'"];
  XCTAssertEqualObjects(e.left.memberPath, (@[ @"Category", @"CategoryName" ]));

  ODataExpression *any = [self parse:@"Products/any(x0:x0/UnitPrice gt 100)"];
  XCTAssertEqual(any.kind, ODataExpressionLambda);
  XCTAssertEqualObjects(any.operand.memberPath, @[ @"Products" ]);
  XCTAssertEqualObjects(any.variable, @"x0");
  XCTAssertEqual(any.body.left.operand.kind, ODataExpressionVariable, @"x0 is the lambda's variable, not a member");
  [self assertText:@"Products/any(x0:x0/Suppliers/any(x1:x1/City eq 'London'))" reads:@"Products/any(x0:x0/Suppliers/any(x1:x1/City eq 'London'))"];
  [self assertText:@"Emails/any(x0:endswith(x0, 'example.com'))" reads:@"Emails/any(x0:endswith(x0, 'example.com'))"];
  [self assertText:@"Orders/any()" reads:@"Orders/any()"];

  [self assertText:@"startswith(tolower(ProductName),tolower('c'))" reads:@"startswith(tolower(ProductName), tolower('c'))"];
  ODataExpression *age = [self parse:@"Zoo.Age(On=2024-01-01) gt 5"].left;
  XCTAssertEqual(age.kind, ODataExpressionCall);
  XCTAssertEqualObjects(age.namedArguments[@"On"].literalType, @"Edm.Date");
  [self assertText:@"Animals/Zoo.Heaviest()/Name eq 'Leo'" reads:@"Animals/Zoo.Heaviest()/Name eq 'Leo'"];
  [self assertText:@"Orders/$count gt 2" reads:@"Orders/$count gt 2"];
  ODataExpression *cast = [self parse:@"Zoo.Lion/MaxRoar gt 100"].left;
  XCTAssertEqual(cast.operand.kind, ODataExpressionCast);
  [self assertText:@"Name eq @name" reads:@"Name eq @name"];
}

- (void)testSyntaxErrorsSayWhere
{
  for (NSString *bad in @[ @"UnitPrice gt", @"Name eq 'x')", @"(A eq 1", @"Products/any(x0 x0 eq 1)", @"A eq eq 1", @"Zoo.F(1)" ]) {
    NSError *error = nil;
    XCTAssertNil([ODataExpression expressionWithString:bad error:&error], @"%@", bad);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@", bad);
    XCTAssertTrue([error.localizedDescription rangeOfString:@" at "].location != NSNotFound, @"%@", error);
  }
}

- (void)testQueryOptionsNestAsDeepAsTheyGo
{
  NSDictionary *query = @{
    @"$filter": @"Price gt 1",
    @"$orderby": @"Category/Name desc,ProductID",
    @"$select": @"Name,Price",
    @"$expand": @"Category($select=CategoryID;$expand=Products($top=2;$filter=Price gt 1;$orderby=Name)),Supplier/$ref,Photo($levels=max)",
    @"$top": @"5",
    @"$skip": @"10",
    @"$count": @"true",
    @"$skiptoken": @"8",
    @"@p": @"'x'",
    @"custom": @"anything",
  };
  NSError *error = nil;
  ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:query error:&error];
  XCTAssertNotNil(options, @"%@", error);
  XCTAssertEqualObjects(options.filter.description, @"Price gt 1");
  XCTAssertEqual(options.orderBy.count, (NSUInteger)2);
  XCTAssertTrue(options.orderBy[0].descending);
  XCTAssertEqualObjects(options.orderBy[0].expression.memberPath, (@[ @"Category", @"Name" ]));
  XCTAssertEqualObjects([options.select valueForKey:@"description"], (@[ @"Name", @"Price" ]));
  XCTAssertEqual(options.expand.count, (NSUInteger)3);
  ODataExpandItem *category = options.expand[0];
  XCTAssertEqualObjects(category.path, @[ @"Category" ]);
  XCTAssertEqualObjects([category.options.select valueForKey:@"description"], @[ @"CategoryID" ]);
  ODataExpandItem *products = category.options.expand.firstObject;
  XCTAssertEqualObjects(products.options.top, @2);
  XCTAssertEqualObjects(products.options.filter.description, @"Price gt 1");
  XCTAssertTrue(options.expand[1].isRef);
  XCTAssertEqualObjects(options.expand[2].options.levels, @-1);
  XCTAssertEqualObjects(options.top, @5);
  XCTAssertEqualObjects(options.skip, @10);
  XCTAssertEqualObjects(options.includeCount, @YES);
  XCTAssertEqualObjects(options.aliases[@"p"].value, @"x");
  XCTAssertEqualObjects(category.description, @"Category($select=CategoryID;$expand=Products($filter=Price gt 1;$orderby=Name;$top=2))");

  XCTAssertNil([ODataQueryOptions optionsWithQuery:@{ @"$expand": @"Category($select=CategoryID" } error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax);
  XCTAssertNil([ODataQueryOptions optionsWithQuery:@{ @"$top": @"five" } error:&error]);
}

// $search (Part 2 section 5.1.7): NOT, then AND (or nothing), then OR.
- (void)testSearchExpressions
{
  NSDictionary *cases = @{
    @"tea": @"tea",
    @"green tea": @"(green AND tea)",
    @"green AND tea": @"(green AND tea)",
    @"tea OR coffee milk": @"(tea OR (coffee AND milk))",
    @"NOT decaf tea": @"(NOT decaf AND tea)",
    @"(tea OR coffee) NOT decaf": @"((tea OR coffee) AND NOT decaf)",
    @"\"earl grey\" OR \"say \\\"hi\\\"\"": @"(\"earl grey\" OR \"say \\\"hi\\\"\")",
  };
  for (NSString *text in cases) {
    NSError *error = nil;
    ODataSearchExpression *search = [ODataSearchExpression searchWithString:text error:&error];
    XCTAssertNotNil(search, @"%@: %@", text, error);
    XCTAssertEqualObjects(search.description, cases[text], @"%@", text);
    XCTAssertEqualObjects([ODataSearchExpression searchWithString:search.description error:NULL].description, cases[text], @"%@ reads back", text);
  }
  for (NSString *bad in @[ @"", @"AND tea", @"tea OR", @"(tea", @"tea)", @"\"open", @"\"\"" ]) {
    NSError *error = nil;
    XCTAssertNil([ODataSearchExpression searchWithString:bad error:&error], @"%@", bad);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@", bad);
  }
  ODataSearchExpression *search = [ODataSearchExpression searchWithString:@"(tea OR café) NOT \"iced tea\"" error:NULL];
  XCTAssertTrue([search matchesTexts:@[ @"Green TEA" ]]);
  XCTAssertTrue([search matchesTexts:@[ @"Cafe au lait" ]], @"diacritics aside");
  XCTAssertFalse([search matchesTexts:@[ @"Iced tea, lemon" ]]);
  XCTAssertFalse([search matchesTexts:@[ @"Water" ]]);
  ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:@{ @"$search": @"\"earl grey\" OR mint", @"$expand": @"Items($search=blue green)" } error:NULL];
  XCTAssertEqualObjects(options.searchExpression.description, @"(\"earl grey\" OR mint)");
  XCTAssertEqualObjects([options.expand.firstObject options].searchExpression.description, @"(blue AND green)");
  NSError *error = nil;
  XCTAssertNil([ODataQueryOptions optionsWithQuery:@{ @"$search": @"OR" } error:&error]);
}

// $apply: filter, groupby and aggregate read and written back.
- (void)testApplyTransformations
{
  for (NSString *text in @[ @"aggregate(UnitPrice with sum as Total,$count as N)",
                            @"filter(UnitPrice gt 10)/groupby((Category/CategoryName,Discontinued),aggregate(UnitPrice with max as Top))",
                            @"groupby((Category/CategoryName))/filter(Name eq 'a/b,c')",
                            @"filter(ProductName eq 'it''s (so)')/aggregate(ProductName with countdistinct as Names)" ]) {
    NSError *error = nil;
    NSArray *transformations = [ODataApplyTransformation transformationsWithString:text error:&error];
    XCTAssertNotNil(transformations, @"%@: %@", text, error);
    NSString *written = [ODataApplyTransformation stringForTransformations:transformations];
    XCTAssertEqualObjects([ODataApplyTransformation stringForTransformations:[ODataApplyTransformation transformationsWithString:written error:NULL]], written, @"%@", text);
  }
  NSArray *parsed = [ODataApplyTransformation transformationsWithString:@"groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))" error:NULL];
  ODataApplyTransformation *groupBy = parsed.firstObject;
  XCTAssertEqual(groupBy.kind, ODataApplyGroupBy);
  XCTAssertEqualObjects(groupBy.groupPaths, (@[ @[ @"Category", @"CategoryName" ] ]));
  XCTAssertEqualObjects([groupBy.aggregates.firstObject alias], @"Total");
  NSDictionary *codes = @{ @"nest(groupby((Name)) as Grouped)": @(ODataIncrementalStoreErrorUnsupportedExpression),
                           @"aggregate(Sales/Forecast)": @(ODataIncrementalStoreErrorUnsupportedExpression),
                           @"groupby((rollup($all,Category)))": @(ODataIncrementalStoreErrorUnsupportedExpression),
                           @"aggregate(UnitPrice sum)": @(ODataIncrementalStoreErrorSyntax),
                           @"nonsense": @(ODataIncrementalStoreErrorSyntax), @"": @(ODataIncrementalStoreErrorSyntax) };
  for (NSString *text in codes) {
    NSError *error = nil;
    XCTAssertNil([ODataApplyTransformation transformationsWithString:text error:&error], @"%@", text);
    XCTAssertEqual(error.code, [codes[text] integerValue], @"%@: %@", text, error);
  }
  NSArray *rows = [ODataAggregation groupObjects:@[ @{ @"k": @"a", @"v": @1 }, @{ @"k": @"b", @"v": @2 }, @{ @"k": @"a", @"v": [NSNull null] } ]
                                      byKeyPaths:@[ @"k" ]
                                      aggregates:@[ [ODataAggregate aggregateOfPath:@[ @"v" ] method:@"sum" alias:@"s" error:NULL],
                                                    [ODataAggregate aggregateOfPath:nil method:nil alias:@"n" error:NULL] ]];
  XCTAssertEqualObjects(rows, (@[ @{ @"k": @"a", @"s": [NSDecimalNumber one], @"n": @2 },
                                  @{ @"k": @"b", @"s": [NSDecimalNumber decimalNumberWithString:@"2"], @"n": @1 } ]));
}

- (void)testResourcePathsAndKeys
{
  NSError *error = nil;
  ODataResourcePath *path = [ODataResourcePath pathWithString:@"People('russellwhyte')/Trips(0)/Microsoft.X.GetInvolvedPeople()" error:&error];
  XCTAssertNotNil(path, @"%@", error);
  XCTAssertEqual(path.segments.count, (NSUInteger)3);
  XCTAssertEqualObjects(path.segments[0].name, @"People");
  XCTAssertEqualObjects(path.segments[0].keys[@""].value, @"russellwhyte");
  XCTAssertEqualObjects(path.segments[1].keys[@""].value, @0);
  XCTAssertTrue(path.segments[2].isCall);
  XCTAssertEqualObjects(path.description, @"People('russellwhyte')/Trips(0)/Microsoft.X.GetInvolvedPeople()");

  ODataResourcePath *compound = [ODataResourcePath pathWithString:@"OrderItems(OrderID=1,ItemNo=2)/$count" error:&error];
  XCTAssertEqualObjects(compound.segments[0].keys[@"ItemNo"].value, @2);
  XCTAssertEqualObjects(compound.segments[1].name, @"$count");
  ODataResourcePath *segment = [ODataResourcePath pathWithString:@"Products/1" error:&error];
  XCTAssertEqualObjects([segment.segments valueForKey:@"name"], (@[ @"Products", @"1" ]), @"a key as a segment");
  // One the lexer reads as several tokens: as written.
  ODataResourcePath *colon = [ODataResourcePath pathWithString:@"Forms/1B99E324-0C77-49C5-9EE1-34FBEA1B8FE9:approve/Document"
                                                         error:&error];
  XCTAssertNotNil(colon, @"%@", error);
  XCTAssertEqualObjects([colon.segments valueForKey:@"name"],
                        (@[ @"Forms", @"1B99E324-0C77-49C5-9EE1-34FBEA1B8FE9:approve", @"Document" ]));
  ODataResourcePath *spaced = [ODataResourcePath pathWithString:@"Notes/a b-c" error:&error];
  XCTAssertEqualObjects(spaced.segments.lastObject.name, @"a b-c", @"%@", error);
  XCTAssertNil([ODataResourcePath pathWithString:@"Forms//Document" error:NULL], @"an empty segment is none");
  XCTAssertNil([ODataResourcePath pathWithString:@"Forms//a:b" error:NULL]);
  // What is not a key still parses as before: a cast, a call, $filter(...).
  ODataResourcePath *calls = [ODataResourcePath pathWithString:@"Employees/NS.Manager/NS.Promote(Level=2)/$filter(@f)/$count" error:&error];
  XCTAssertEqualObjects([calls.segments valueForKey:@"name"], (@[ @"Employees", @"NS.Manager", @"NS.Promote", @"$filter", @"$count" ]), @"%@", error);
  XCTAssertTrue(calls.segments[2].isCall);
  XCTAssertNotNil(calls.segments[2].arguments[@"Level"]);
}

@end
