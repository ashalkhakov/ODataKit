// The client's ODataPredicateTranslator and the server's
// ODataPredicateBuilder, each against the other, over the same rows.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Both ways:
//   - what a client fetches: predicate -> $filter -> predicate, the two
//     predicates selecting the same rows;
//   - what a service reads: $filter -> predicate -> $filter -> predicate,
//     the same.
// Rows, not text: tolower(Name) eq 'chai' comes back as name ==[c] 'chai',
// and writes back as tolower(ProductName) eq 'chai', and all of them are
// the same question. Each case runs over an in-memory store, SQLite, and
// FreeCoreData's SQL backends where they are linked and given a server
// (below), and writes both OData 4.0 and 4.01; the rows it should select
// are the in-memory store's for the predicate it starts from (Apple's
// SQLite store does not take ALL).
//
// The SQL backends: CD_TEST_POSTGRES_URL and CD_TEST_MYSQL_URL, as
// FreeCoreData's own suites name them; each backend's library is loaded
// from the library path
// (make -C Tests run-tests FREECOREDATA_BACKENDS=<FreeCoreData>/Backends). Each store gets a schema of its own, dropped after the
// test. A URL whose backend cannot be loaded is a failure, not a skip.
//
// A $filter the service reads and the client cannot write is listed, with
// why (and "4.0: " before the why for one it cannot write in 4.0 only): the
// test checks that the client refuses it cleanly, and fails when it no
// longer does, so the list stays true.

#import <XCTest/XCTest.h>
#import <dlfcn.h>
#import "OISCatalogModel.h"

// FreeCoreData's CDSQLStore, where a backend is loaded: the store and its
// schema, dropped.
@interface NSPersistentStore (OISPairSQLStore)
+ (BOOL)destroyStoreAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error;
@end

// The stores each case runs over: the store type, and for a SQL backend
// its class name, the variable that holds its server's URL, and its
// library.
static NSArray<NSArray<NSString *> *> *OISPairSQLBackends(void)
{
  return @[ @[ @"CDPostgreSQLStore", @"CD_TEST_POSTGRES_URL", @"libCDPostgreSQLStore.so" ],
            @[ @"CDMySQLStore", @"CD_TEST_MYSQL_URL", @"libCDMySQLStore.so" ] ];
}

static NSAttributeDescription *OISPairAttribute(NSString *name, NSAttributeType type)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = ![name isEqualToString:@"id"];
  return attribute;
}

// Employees, managers among them, each with a manager and reports. One
// model, so that its entities are the same in every store's predicates.
static NSManagedObjectModel *OISMakeStaffModel(void);
static NSManagedObjectModel *OISStaffModel(void)
{
  static NSManagedObjectModel *model;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    model = OISMakeStaffModel();
  });
  return model;
}

static NSManagedObjectModel *OISMakeStaffModel(void)
{
  NSEntityDescription *employee = [[NSEntityDescription alloc] init];
  employee.name = @"Employee";
  employee.managedObjectClassName = @"NSManagedObject";
  employee.userInfo = @{ @"OData.type": @"Default.Employee", @"OData.entitySet": @"Employees" };
  NSEntityDescription *manager = [[NSEntityDescription alloc] init];
  manager.name = @"Manager";
  manager.managedObjectClassName = @"NSManagedObject";
  manager.userInfo = @{ @"OData.type": @"Default.Manager" };
  NSAttributeDescription *identifier = OISPairAttribute(@"id", NSInteger32AttributeType);
  identifier.userInfo = @{ @"OData.key": @"YES" };
  NSRelationshipDescription *boss = [[NSRelationshipDescription alloc] init];
  boss.name = @"manager";
  boss.destinationEntity = employee;
  boss.maxCount = 1;
  boss.optional = YES;
  NSRelationshipDescription *reports = [[NSRelationshipDescription alloc] init];
  reports.name = @"reports";
  reports.destinationEntity = employee;
  reports.optional = YES;
  boss.inverseRelationship = reports;
  reports.inverseRelationship = boss;
  employee.properties = @[ identifier, OISPairAttribute(@"name", NSStringAttributeType), OISPairAttribute(@"hired", NSDateAttributeType), boss, reports ];
  manager.properties = @[ OISPairAttribute(@"budget", NSDecimalAttributeType) ];
  employee.subentities = @[ manager ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ employee, manager ];
  return model;
}

// Counts the groupings a service asks the store for.
@interface OISPairGroupingHandler : ODataEntitySetHandler
@property (nonatomic) NSUInteger groupings;
@end

@implementation OISPairGroupingHandler
- (NSArray *)groupedRowsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  self.groupings++;
  return [super groupedRowsForFetchRequest:fetchRequest request:request reply:reply];
}
@end

// Signals when an exchange finishes.
// (An ivar: a dispatch object is an Objective-C object on Apple only.)
@interface OISPairWaiter : NSObject
- (BOOL)waitForExchange;
@end

@implementation OISPairWaiter {
  dispatch_semaphore_t _finished;
}
- (instancetype)init
{
  if ((self = [super init])) _finished = dispatch_semaphore_create(0);
  return self;
}
- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  dispatch_semaphore_signal(_finished);
}
- (BOOL)waitForExchange
{
  return dispatch_semaphore_wait(_finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC))) == 0;
}
@end

// A GET of a service over a context's store: the response's JSON, or its
// status when it is not 200.
static id OISPairGET(ODataService *service, NSString *path)
{
  NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSURL *url = [NSURL URLWithString:[@"http://example.test/odata/" stringByAppendingString:encoded]];
  OISPairWaiter *waiter = [[OISPairWaiter alloc] init];
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:[NSURLRequest requestWithURL:url] target:waiter action:@selector(exchangeDidFinish:)];
  [service startExchange:exchange];
  if (![waiter waitForExchange]) return @"timed out";
  NSInteger status = ((NSHTTPURLResponse *)exchange.URLResponse).statusCode;
  if (status != 200) return [NSString stringWithFormat:@"%ld %@", (long)status, [[NSString alloc] initWithData:exchange.data encoding:NSUTF8StringEncoding]];
  return [NSJSONSerialization JSONObjectWithData:exchange.data options:0 error:NULL];
}

@interface ODataPredicatePairTests : XCTestCase
@end

@implementation ODataPredicatePairTests {
  ODataPropertyMapper *_mapper;
  NSMutableArray<NSURL *> *_files;
  NSMutableArray<NSArray *> *_schemas;  // class, URL, options
}

- (void)setUp
{
  [super setUp];
  _mapper = [[ODataPropertyMapper alloc] init];
  _files = [NSMutableArray array];
  _schemas = [NSMutableArray array];
}

- (void)tearDown
{
  for (NSURL *url in _files) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
  for (NSArray *schema in _schemas) {
    NSError *error = nil;
    if (![schema[0] destroyStoreAtURL:schema[1] options:schema[2] error:&error]) NSLog(@"could not drop %@: %@", schema[2], error);
  }
  [super tearDown];
}

#pragma mark Rows

// In-memory first: it is what the others are compared with.
- (NSArray<NSString *> *)storeTypes
{
  NSMutableArray *types = [NSMutableArray arrayWithObjects:NSInMemoryStoreType, NSSQLiteStoreType, nil];
  NSDictionary *environment = [[NSProcessInfo processInfo] environment];
  NSArray *wanted = [OISPairSQLBackends() filteredArrayUsingPredicate:
                       [NSPredicate predicateWithBlock:^BOOL(NSArray *backend, NSDictionary *bindings) {
                         return [environment[backend[1]] length] > 0;
                       }]];
  for (NSArray *backend in wanted) {
    if (!NSClassFromString(backend[0]) && !dlopen([backend[2] fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL)) {
      XCTFail(@"%@ is set, but %@ cannot be loaded (FREECOREDATA_BACKENDS): %s", backend[1], backend[2], dlerror());
      continue;
    }
    [NSPersistentStoreCoordinator registerStoreClass:NSClassFromString(backend[0]) forStoreType:backend[0]];
    [types addObject:backend[0]];
  }
  return types;
}

- (NSManagedObjectContext *)contextForModel:(NSManagedObjectModel *)model storeType:(NSString *)storeType
{
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = nil;
  NSDictionary *options = nil;
  NSString *variable = nil;
  for (NSArray *backend in OISPairSQLBackends()) {
    if ([backend[0] isEqualToString:storeType]) variable = backend[1];
  }
  if (variable) {
    // Short: PostgreSQL cuts identifiers at 63 bytes, MySQL at 64.
    static NSUInteger counter = 0;
    url = [NSURL URLWithString:[[NSProcessInfo processInfo] environment][variable]];
    options = @{ @"CDSQLStoreSchemaName": [NSString stringWithFormat:@"oispair_%d_%lu",
                                           (int)[[NSProcessInfo processInfo] processIdentifier], (unsigned long)++counter] };
    [_schemas addObject:@[ NSClassFromString(storeType), url, options ]];
  } else if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_files addObject:url];
  }
  NSError *error = nil;
  NSPersistentStore *store = [coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:options error:&error];
  XCTAssertNotNil(store, @"%@ at %@: %@", storeType, url, error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = coordinator;
  return context;
}

- (NSManagedObject *)insert:(NSString *)entity into:(NSManagedObjectContext *)context values:(NSDictionary *)values
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) {
    id value = values[key];
    if ([value isKindOfClass:[NSArray class]]) {
      [[object mutableSetValueForKey:key] addObjectsFromArray:value];
    } else if (value != [NSNull null]) {
      [object setValue:value forKey:key];
    }
  }
  return object;
}

// Products with nulls, mixed case, no category, several suppliers or none.
- (NSManagedObjectContext *)catalogIn:(NSString *)storeType
{
  NSManagedObjectContext *context = [self contextForModel:OISCatalogModel() storeType:storeType];
  NSManagedObject *beverages = [self insert:@"Category" into:context values:@{ @"id": @1, @"name": @"Beverages" }];
  NSManagedObject *condiments = [self insert:@"Category" into:context values:@{ @"id": @2, @"name": @"Condiments" }];
  [self insert:@"Category" into:context values:@{ @"id": @3, @"name": @"Produce" }];
  NSManagedObject *exotic = [self insert:@"Supplier" into:context values:@{ @"id": @1, @"companyName": @"Exotic Liquids", @"city": @"London", @"country": @"UK" }];
  NSManagedObject *cajun = [self insert:@"Supplier" into:context values:@{ @"id": @2, @"companyName": @"New Orleans Cajun Delights", @"city": @"New Orleans", @"country": @"USA" }];
  NSManagedObject *tokyo = [self insert:@"Supplier" into:context values:@{ @"id": @3, @"companyName": @"Tokyo Traders", @"city": @"Tokyo", @"country": @"Japan" }];
  NSArray *rows = @[
    @[ @1, @"Chai", @"18", @NO, beverages, @[ exotic ], @"10 boxes x 20 bags" ],
    @[ @2, @"Chang", @"19", @NO, beverages, @[ exotic ], @"24 - 12 oz bottles" ],
    @[ @3, @"Aniseed Syrup", @"10", @NO, condiments, @[ exotic ], [NSNull null] ],
    @[ @4, @"Chef Anton's Cajun Seasoning", @"22", @NO, condiments, @[ cajun ], @"48 - 6 oz jars" ],
    @[ @5, @"Chef Anton's Gumbo Mix", @"21.35", @YES, condiments, @[ cajun ], [NSNull null] ],
    @[ @6, @"Ikura", @"31", @NO, [NSNull null], @[ tokyo, exotic ], @"12 - 200 ml jars" ],
    @[ @7, @"chai latte", @"4.5", [NSNull null], beverages, @[], [NSNull null] ],
    @[ @8, @"Mystery", [NSNull null], @YES, [NSNull null], @[], [NSNull null] ],
    @[ @9, @" Pavlova ", @"17.45", @NO, condiments, @[ tokyo ], @"32 - 500 g boxes" ],
  ];
  for (NSArray *row in rows) {
    [self insert:@"Product" into:context values:@{
      @"id": row[0], @"name": row[1],
      @"unitPrice": row[2] == [NSNull null] ? row[2] : [NSDecimalNumber decimalNumberWithString:row[2]],
      @"discontinued": row[3], @"category": row[4], @"suppliers": row[5], @"quantityPerUnit": row[6] }];
  }
  NSError *error = nil;
  XCTAssertTrue([context save:&error], @"%@", error);
  [context reset];
  return context;
}

- (NSManagedObjectContext *)staffIn:(NSString *)storeType
{
  NSManagedObjectContext *context = [self contextForModel:OISStaffModel() storeType:storeType];
  NSManagedObject *ann = [self insert:@"Manager" into:context values:@{ @"id": @1, @"name": @"Ann", @"budget": [NSDecimalNumber decimalNumberWithString:@"5000"],
                                                                        @"hired": ODataDateFromString(@"2019-06-01T09:00:00Z") }];
  NSManagedObject *bob = [self insert:@"Manager" into:context values:@{ @"id": @2, @"name": @"Bob", @"budget": [NSDecimalNumber decimalNumberWithString:@"800"],
                                                                        @"manager": ann, @"hired": ODataDateFromString(@"2024-12-31T23:30:00Z") }];
  [self insert:@"Employee" into:context values:@{ @"id": @3, @"name": @"Cy", @"manager": bob, @"hired": ODataDateFromString(@"2025-01-01T00:00:00Z") }];
  [self insert:@"Employee" into:context values:@{ @"id": @4, @"name": @"Di", @"manager": bob }];
  NSError *error = nil;
  XCTAssertTrue([context save:&error], @"%@", error);
  [context reset];
  return context;
}

- (NSArray *)idsOf:(NSString *)entity where:(NSPredicate *)predicate in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = predicate;
  NSError *error = nil;
  NSArray *objects = nil;
  @try {
    objects = [context executeFetchRequest:fetch error:&error];
  } @catch (NSException *exception) {
    return @[ [NSString stringWithFormat:@"raised %@", exception.reason] ];
  }
  if (!objects) return @[ [NSString stringWithFormat:@"failed %@", error] ];
  return [[objects valueForKey:@"id"] sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark The two sides

- (ODataPredicateBuilder *)builderForModel:(NSManagedObjectModel *)model
{
  ODataPredicateBuilder *builder = [[ODataPredicateBuilder alloc] initWithMapper:_mapper];
  NSMutableDictionary *types = [NSMutableDictionary dictionary];
  for (NSEntityDescription *entity in model.entities) {
    NSString *name = [_mapper qualifiedTypeForEntity:entity];
    if (name) types[name] = entity;
  }
  builder.entitiesByTypeName = types;
  return builder;
}

- (NSString *)write:(NSPredicate *)predicate entity:(NSEntityDescription *)entity version:(NSString *)version error:(NSError **)error
{
  ODataPredicateTranslator *translator = [[ODataPredicateTranslator alloc] initWithMapper:_mapper entity:entity];
  translator.version = version;
  translator.writesAggregates = YES;  // as ODataService has it
  return [translator translatePredicate:predicate error:error];
}

// With the context the rows are read from, for the span of month() and
// the rest.
- (NSPredicate *)read:(NSString *)filter entity:(NSEntityDescription *)entity context:(NSManagedObjectContext *)context error:(NSError **)error
{
  ODataExpression *expression = [ODataExpression expressionWithString:filter error:error];
  if (!expression) return nil;
  return [[self builderForModel:entity.managedObjectModel] predicateForExpression:expression entity:entity aliases:nil
                                                                           context:context error:error];
}

// predicate -> $filter -> predicate: the same rows.
- (void)assertClientPredicates:(NSArray *)formats entity:(NSString *)entityName contexts:(NSArray *)contexts
{
  NSManagedObjectContext *reference = contexts.firstObject;
  for (NSManagedObjectContext *context in contexts) {
    NSEntityDescription *entity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[entityName];
    NSString *store = ((NSPersistentStore *)context.persistentStoreCoordinator.persistentStores.firstObject).type;
    for (id format in formats) {
      @try {
        [self assertClientPredicate:format entity:entity entityName:entityName store:store context:context reference:reference];
      } @catch (NSException *exception) {
        XCTFail(@"%@: %@ raised %@: %@", store, format, exception.name, exception.reason);
      }
    }
  }
}

- (void)assertClientPredicate:(id)format entity:(NSEntityDescription *)entity entityName:(NSString *)entityName store:(NSString *)store
                      context:(NSManagedObjectContext *)context reference:(NSManagedObjectContext *)reference
{
  NSPredicate *predicate = [format isKindOfClass:[NSPredicate class]] ? format : [NSPredicate predicateWithFormat:format];
  NSArray *expected = [self idsOf:entityName where:predicate in:reference];
  for (NSString *version in @[ @"4.0", @"4.01" ]) {
    NSError *error = nil;
    NSString *filter = [self write:predicate entity:entity version:version error:&error];
    if (!filter) {
      XCTFail(@"%@ %@: the client cannot write %@: %@", store, version, format, error);
      continue;
    }
    NSPredicate *read = [self read:filter entity:entity context:context error:&error];
    if (!read) {
      XCTFail(@"%@ %@: the service cannot read %@ (from %@): %@", store, version, filter, format, error);
      continue;
    }
    NSArray *got = [self idsOf:entityName where:read in:context];
    XCTAssertEqualObjects(got, expected, @"%@ %@: %@ -> %@ -> %@", store, version, format, filter, read);
  }
}

// $filter -> predicate -> $filter -> predicate: the same rows. What the
// client cannot write, it refuses, as the list says.
- (void)assertServiceFilters:(NSArray<NSString *> *)filters clientCannotWrite:(NSDictionary<NSString *, NSString *> *)gaps
                      entity:(NSString *)entityName contexts:(NSArray *)contexts
{
  NSManagedObjectContext *reference = contexts.firstObject;
  for (NSManagedObjectContext *context in contexts) {
    NSEntityDescription *entity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[entityName];
    NSString *store = ((NSPersistentStore *)context.persistentStoreCoordinator.persistentStores.firstObject).type;
    for (NSString *filter in [filters arrayByAddingObjectsFromArray:gaps.allKeys]) {
      NSError *error = nil;
      NSPredicate *read = [self read:filter entity:entity context:context error:&error];
      if (!read) {
        XCTFail(@"%@: the service cannot read %@: %@", store, filter, error);
        continue;
      }
      NSArray *expected = [self idsOf:entityName where:read in:reference];
      XCTAssertEqualObjects([self idsOf:entityName where:read in:context], expected, @"%@: %@ read as %@", store, filter, read);
      for (NSString *version in @[ @"4.0", @"4.01" ]) {
        NSString *written = [self write:read entity:entity version:version error:&error];
        BOOL gap = gaps[filter] && (![gaps[filter] hasPrefix:@"4.0: "] || [version isEqualToString:@"4.0"]);
        if (gap) {
          XCTAssertNil(written, @"%@ %@: the client now writes %@ (%@), which the list says it cannot (%@): take it off the list",
                       store, version, filter, written, gaps[filter]);
          if (!written) XCTAssertNotNil(error, @"%@: a refusal says why", filter);
          continue;
        }
        if (!written) {
          XCTFail(@"%@ %@: the client cannot write %@ (read as %@): %@", store, version, filter, read, error);
          continue;
        }
        NSPredicate *again = [self read:written entity:entity context:context error:&error];
        if (!again) {
          XCTFail(@"%@ %@: the service cannot read what the client wrote, %@ (from %@): %@", store, version, written, filter, error);
          continue;
        }
        XCTAssertEqualObjects([self idsOf:entityName where:again in:context], expected, @"%@ %@: %@ -> %@ -> %@", store, version, filter, read, written);
      }
    }
  }
}

- (NSArray *)catalogs
{
  NSMutableArray *contexts = [NSMutableArray array];
  for (NSString *type in [self storeTypes]) [contexts addObject:[self catalogIn:type]];
  return contexts;
}

- (NSArray *)staffs
{
  NSMutableArray *contexts = [NSMutableArray array];
  for (NSString *type in [self storeTypes]) [contexts addObject:[self staffIn:type]];
  return contexts;
}

#pragma mark Cases

- (void)testWhatTheClientWrites
{
  [self assertClientPredicates:@[
    @"unitPrice == 18", @"unitPrice != 18", @"unitPrice > 20", @"unitPrice >= 21.35", @"unitPrice < 10", @"unitPrice <= 10",
    @"discontinued == YES", @"discontinued == NO", @"name == nil", @"unitPrice == nil", @"unitPrice != nil", @"quantityPerUnit == nil",
    @"name == 'Chai'", @"name ==[c] 'chai'", @"name !=[c] 'chai'",
    @"name BEGINSWITH 'Chef'", @"name BEGINSWITH[c] 'chai'", @"name ENDSWITH 'Mix'", @"name CONTAINS 'Anton'", @"name CONTAINS[c] 'CHAI'",
    @"unitPrice > 10 AND discontinued == NO", @"unitPrice < 10 OR unitPrice > 30", @"NOT (unitPrice > 20)",
    @"NOT (name BEGINSWITH 'C') AND (unitPrice >= 10 OR discontinued == YES)",
    @"id IN {1, 3, 5}", @"name IN {'Chai', 'Ikura'}", @"unitPrice BETWEEN {10, 20}",
    @"category.name == 'Beverages'", @"category == nil", @"category != nil", @"category.id == 2",
    @"ANY suppliers.city == 'London'", @"ANY suppliers.country IN {'Japan', 'USA'}",
    @"SUBQUERY(suppliers, $s, $s.city == 'London' AND $s.country == 'UK').@count > 0",
    @"ALL suppliers.country == 'UK'", @"suppliers.@count == 0", @"suppliers.@count > 1",
    @"TRUEPREDICATE", @"FALSEPREDICATE",
  ] entity:@"Product" contexts:[self catalogs]];
}

- (void)testWhatTheServiceReads
{
  [self assertServiceFilters:@[
    @"UnitPrice eq 18", @"UnitPrice gt 20 and Discontinued eq false", @"not (UnitPrice gt 20)", @"UnitPrice eq null",
    @"ProductName eq 'Chai'", @"tolower(ProductName) eq 'chai'", @"toupper(ProductName) eq 'CHAI'",
    @"startswith(ProductName,'Chef')", @"endswith(ProductName,'Mix')", @"contains(ProductName,'Anton')",
    @"contains(tolower(ProductName),'chai')",
    @"ProductID in (1,3,5)", @"UnitPrice add 1 gt 20", @"UnitPrice mul 2 lt 30",
    @"Category/CategoryName eq 'Beverages'", @"Category eq null", @"Category ne null",
    @"Suppliers/any(s:s/City eq 'London')", @"Suppliers/all(s:s/Country eq 'UK')", @"Suppliers/any()",
    @"Suppliers/$count gt 1", @"Suppliers/any(s:s/City eq 'London' and s/Country eq 'UK')",
    @"true", @"false", @"Discontinued",
    // Read as ranges of their argument, written back as those ranges.
    @"floor(UnitPrice) eq 21", @"round(UnitPrice) gt 19", @"ceiling(UnitPrice) le 19",
  ] clientCannotWrite:@{
    @"matchesPattern(ProductName,'^Ch')": @"4.0: matchesPattern is 4.01's",
    @"not matchesPattern(QuantityPerUnit,'jars')": @"4.0: matchesPattern is 4.01's",
    // Read as MATCHES, which the client writes as matchesPattern.
    @"length(ProductName) gt 10": @"4.0: length() is read as a pattern, and 4.0 has no matchesPattern",
    @"length(QuantityPerUnit) le 16": @"4.0: as length(ProductName)",
  } entity:@"Product" contexts:[self catalogs]];
}

// A navigation's aggregate (Data Aggregation section 3.6.1): a key path's
// collection operator, products.@sum.unitPrice, in each store, which the
// client writes back as aggregate().
- (void)testAggregatesOfNavigations
{
  [self assertServiceFilters:@[
    @"Products/aggregate($count) gt 2",
    @"Products/aggregate(UnitPrice with sum) gt 40",
    @"Products/aggregate(UnitPrice with average) lt 20",
    @"Products/aggregate(UnitPrice with max) ge 30",
    @"Products/aggregate(UnitPrice with min) le 10",
    @"Products/aggregate(UnitPrice with max) gt Products/aggregate(UnitPrice with min)",
  ] clientCannotWrite:@{} entity:@"Category" contexts:[self catalogs]];
}

// substring, trim, indexof and concat compared with a literal: each read
// as a pattern the property matches (which the client writes back as
// matchesPattern, 4.01 only), or, for concat, as equality.
- (void)testStringFunctions
{
  NSString *pattern = @"4.0: read as a pattern, and 4.0 has no matchesPattern";
  NSString *whitespace = @"read as a pattern of \\s, which is Unicode's whitespace in ICU and ECMAScript's own in OData";
  [self assertServiceFilters:@[
    @"concat(ProductName,' tea') eq 'Chai tea'", @"concat('The ',ProductName) eq 'The Ikura'",
    @"concat(ProductName,' tea') ne 'Chai tea'", @"concat(ProductName,'x') eq 'x'",
  ] clientCannotWrite:@{
    @"substring(ProductName,1) eq 'hai'": pattern,
    @"substring(ProductName,0,4) eq 'Chef'": pattern,
    @"substring(ProductName,1,2) ne 'ha'": pattern,
    @"substring(ProductName,20) eq ''": pattern,
    @"trim(ProductName) eq 'Pavlova'": whitespace,
    @"trim(QuantityPerUnit) ne '48 - 6 oz jars'": whitespace,
    @"indexof(ProductName,'a') eq 2": pattern,
    @"indexof(ProductName,'Anton') ge 5": pattern,
    @"indexof(ProductName,'z') eq -1": pattern,
    @"indexof(QuantityPerUnit,'oz') lt 10": pattern,
    @"length(ProductName) eq 4": pattern,
    @"length(ProductName) ne 4": pattern,
  } entity:@"Product" contexts:[self catalogs]];
}

// matchesPattern is ECMAScript's (Part 2 section 5.1.1.5.4), read into
// MATCHES, which is ICU's: where the two read a pattern differently, the
// service reads it as ECMAScript does. Each pair is a pattern and the
// strings it is found in, among these.
- (void)testMatchesPatternIsECMAScripts
{
  NSArray *strings = @[ @"ab", @"a\nb", @"a\r\nb", @"b\na", @"x\u0663", @"x3", @"\r\nz", @"tab\tx" ];
  NSDictionary *found = @{
    @"^b": @[ @"b\na" ],                            // the start of the string, not of a line
    @"a$": @[ @"b\na" ],                            // the end, not before a line break
    @"a.b": @[],                                     // . is not a line terminator
    @"a[\\s\\S]b": @[ @"a\nb" ],
    @"a\\r\\nb": @[ @"a\r\nb" ],
    @"x\\d": @[ @"x3" ],                            // \d is ASCII
    @"\\w$": @[ @"ab", @"a\nb", @"a\r\nb", @"b\na", @"x3", @"\r\nz", @"tab\tx" ],
    @"^\\nz": @[],
    @"\\nz": @[ @"\r\nz" ],                        // found after the \r of a \r\n
    @"t.b": @[ @"tab\tx" ],
  };
  NSEntityDescription *product = OISCatalogModel().entitiesByName[@"Product"];
  for (NSString *pattern in found) {
    NSString *filter = [NSString stringWithFormat:@"matchesPattern(ProductName,'%@')", pattern];
    NSError *error = nil;
    NSPredicate *read = [self read:filter entity:product context:nil error:&error];
    XCTAssertNotNil(read, @"%@: %@", filter, error);
    NSMutableArray *got = [NSMutableArray array];
    for (NSString *string in strings) {
      if ([read evaluateWithObject:@{ @"name": string }]) [got addObject:string];
    }
    XCTAssertEqualObjects(got, found[pattern], @"%@ read as %@", filter, read);
  }
}

// $apply's groupby and aggregate, which the store does where it can do
// them exactly (SQLite on Apple; every store on GNUstep, FreeCoreData's SQL
// backends in SQL): the same groups, each with the same values, as the
// service makes in memory.
- (void)assertGroupings:(NSArray<NSString *> *)paths inStore:(NSArray<NSString *> *)storePaths
               contexts:(NSArray<NSManagedObjectContext *> *)contexts entitySet:(NSString *)set entity:(NSString *)entityName
{
  NSMutableDictionary *expected = [NSMutableDictionary dictionary];
  for (NSManagedObjectContext *context in contexts) {
    NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
    NSString *store = ((NSPersistentStore *)coordinator.persistentStores.firstObject).type;
    ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator
                                                                         serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
    OISPairGroupingHandler *handler = [[OISPairGroupingHandler alloc] initWithEntity:coordinator.managedObjectModel.entitiesByName[entityName]];
    [service setHandler:handler forEntitySet:set];
#if defined(__APPLE__)
    BOOL groups = [store isEqualToString:NSSQLiteStoreType];
#else
    BOOL groups = YES;
#endif
    for (NSString *path in paths) {
      NSUInteger before = handler.groupings;
      id got = OISPairGET(service, path);
      XCTAssertTrue([got isKindOfClass:[NSDictionary class]], @"%@: %@ answered %@", store, path, got);
      if (![got isKindOfClass:[NSDictionary class]]) continue;
      NSSet *rows = [NSSet setWithArray:got[@"value"]];
      if (expected[path]) XCTAssertEqualObjects(rows, expected[path], @"%@: %@", store, path);
      else expected[path] = rows;
      BOOL inStore = groups && [storePaths containsObject:path];
      XCTAssertEqual(handler.groupings - before, (NSUInteger)(inStore ? 1 : 0), @"%@: %@ grouped %@", store, path, inStore ? @"here" : @"by the store");
    }
  }
}

- (void)testGroupingInTheStore
{
  NSArray *inStore = @[
    @"Products?$apply=groupby((Category/CategoryName),aggregate($count as N))",
    @"Products?$apply=groupby((Category/CategoryName,Discontinued),aggregate(ProductID with sum as S,ProductID with average as A,ProductID with min as Lo,ProductID with max as Hi,$count as N))",
    @"Products?$apply=aggregate(ProductID with sum as S,ProductID with average as A,$count as N)",
    @"Products?$apply=filter(ProductID gt 100)/aggregate(ProductID with sum as S,ProductID with average as A,ProductID with min as Lo,$count as N)",
    @"Products?$apply=filter(UnitPrice gt 15)/groupby((Discontinued))",
    @"Products?$apply=groupby((Category/CategoryName),aggregate(ProductID with sum as S))/filter(S gt 5)&$orderby=S desc&$count=true",
    @"Products?$apply=groupby((Category/CategoryID),aggregate(ProductID with average as A))/compute(A mul 2 as B)/groupby((B),aggregate($count as N))",
  ];
  NSArray *inMemory = @[
    @"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as T))",
    @"Products?$apply=groupby((Category/CategoryName),aggregate(ProductID with countdistinct as D))",
    @"Products?$apply=groupby((Category/CategoryName),aggregate(ProductName with max as Last))",
    @"Products?$apply=compute(ProductID mul 2 as Twice)/aggregate(Twice with sum as S)",
  ];
  [self assertGroupings:[inStore arrayByAddingObjectsFromArray:inMemory] inStore:inStore contexts:[self catalogs] entitySet:@"Products" entity:@"Product"];
  NSArray *staff = @[
    @"Employees?$apply=aggregate(Hired with min as First,Hired with max as Last,$count as N)",
    @"Employees?$apply=groupby((Manager/Name),aggregate(Id with sum as S,Hired with max as Last))",
  ];
  [self assertGroupings:staff inStore:staff contexts:[self staffs] entitySet:@"Employees" entity:@"Employee"];
}

static id OISWithoutETags(id json)
{
  if ([json isKindOfClass:[NSArray class]]) {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in json) [out addObject:OISWithoutETags(item)];
    return out;
  }
  if (![json isKindOfClass:[NSDictionary class]]) return json;
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *key in json) if (![key isEqualToString:@"@odata.etag"]) out[key] = OISWithoutETags(json[key]);
  return out;
}

// $expand of a to-many relationship, fetched for all the parents on a
// page at once, with its filter and ordering in the store: the same
// members, in the same order, as over the in-memory store.
- (void)assertExpansions:(NSArray<NSString *> *)paths contexts:(NSArray<NSManagedObjectContext *> *)contexts
{
  NSMutableDictionary *expected = [NSMutableDictionary dictionary];
  for (NSManagedObjectContext *context in contexts) {
    NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
    NSString *store = ((NSPersistentStore *)coordinator.persistentStores.firstObject).type;
    ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator
                                                                         serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
    for (NSString *path in paths) {
      id got = OISPairGET(service, path);
      XCTAssertTrue([got isKindOfClass:[NSDictionary class]], @"%@: %@ answered %@", store, path, got);
      if (![got isKindOfClass:[NSDictionary class]]) continue;
      // ETags are the store's own; the rest is the same everywhere.
      id value = OISWithoutETags(got[@"value"]);
      if (expected[path]) XCTAssertEqualObjects(value, expected[path], @"%@: %@", store, path);
      else expected[path] = value;
    }
  }
}

- (void)testExpansionsInTheStore
{
  [self assertExpansions:@[
    @"Categories?$expand=Products($select=ProductName)&$orderby=CategoryID",
    @"Categories?$expand=Products($filter=UnitPrice gt 15;$orderby=UnitPrice desc;$select=ProductName,UnitPrice)&$orderby=CategoryID",
    @"Categories?$expand=Products($filter=startswith(ProductName,'Ch');$top=1;$skip=1;$count=true;$select=ProductName)&$orderby=CategoryID",
    @"Categories?$expand=Products($search=chef;$select=ProductName)&$orderby=CategoryID",
    @"Categories?$expand=Products/$count&$orderby=CategoryID",
    @"Categories?$expand=Products($filter=length(ProductName) gt 5;$select=ProductName;$expand=Suppliers($select=CompanyName;$orderby=CompanyName))&$orderby=CategoryID",
    @"Categories?$filter=CategoryID eq 2&$expand=Products($orderby=ProductName desc;$select=ProductName)",
    @"Suppliers?$expand=Products($select=ProductName;$orderby=ProductID)&$orderby=SupplierID",
  ] contexts:[self catalogs]];
  [self assertExpansions:@[
    @"Employees?$expand=Reports($select=Name;$orderby=Name desc)&$orderby=Id",
    @"Employees?$expand=Reports($levels=max;$select=Name)&$orderby=Id",
    @"Employees?$filter=Id eq 1&$expand=Reports($filter=Name ne 'Cy';$expand=Reports($select=Name);$select=Name)",
  ] contexts:[self staffs]];
}

- (void)testTypesAndDates
{
  [self assertServiceFilters:@[
    @"Name eq 'Ann'",
    @"Manager/Name eq 'Ann'",
    @"Reports/any(r:r/Name eq 'Cy')",
    // Through a to-one that may be null (Ann has no manager): no members.
    @"Manager/Reports/any()", @"Manager/Reports/any(r:r/Name eq 'Cy')", @"not Manager/Reports/any()",
    @"Manager/Reports/$count gt 1", @"Manager/Reports/$count eq 0", @"Manager/Reports/$count lt 1",
    @"Manager/Reports/all(r:r/Name eq 'Cy')", @"not Manager/Reports/any(r:not (r/Name eq 'Cy'))",
    @"isof(Default.Manager)", @"not isof(Default.Manager)", @"isof(Manager,Default.Manager)",
    @"Default.Manager/Budget gt 1000", @"Default.Manager/Budget eq null", @"Manager/Default.Manager/Budget lt 1000",
    @"Reports/any(r:isof(r,Default.Manager))", @"Reports/Default.Manager/any(m:m/Budget lt 1000)",
    @"year(Hired) eq 2025", @"year(Hired) ne 2025", @"date(Hired) eq 2024-12-31",
    @"year(Hired) in (2019,2025)", @"year(Hired) lt 2024",
    // A range in each year (month) or month (day) the dates span.
    // (hour() over these six years would be more ranges than a store takes.)
    @"month(Hired) eq 12", @"month(Hired) ne 6", @"month(Hired) ge 6", @"day(Hired) eq 1",
  ] clientCannotWrite:@{} entity:@"Employee" contexts:[self staffs]];
  for (NSManagedObjectContext *context in [self staffs]) {
    NSEntityDescription *entity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"Employee"];
    NSError *error = nil;
    NSPredicate *read = [self read:@"Manager/Reports/any()" entity:entity context:context error:&error];
    XCTAssertEqualObjects([self idsOf:@"Employee" where:read in:context], (@[ @2, @3, @4 ]), @"%@", read);
    read = [self read:@"not Manager/Reports/any()" entity:entity context:context error:&error];
    XCTAssertEqualObjects([self idsOf:@"Employee" where:read in:context], @[ @1 ], @"%@", read);
    // All of none holds, and none counts 0: as any's opposite says.
    read = [self read:@"Manager/Reports/all(r:r/Name eq 'Cy')" entity:entity context:context error:&error];
    XCTAssertEqualObjects([self idsOf:@"Employee" where:read in:context], @[ @1 ], @"%@", read);
    read = [self read:@"not Manager/Reports/any(r:not (r/Name eq 'Cy'))" entity:entity context:context error:&error];
    XCTAssertEqualObjects([self idsOf:@"Employee" where:read in:context], @[ @1 ], @"%@", read);
    read = [self read:@"Manager/Reports/$count eq 0" entity:entity context:context error:&error];
    XCTAssertEqualObjects([self idsOf:@"Employee" where:read in:context], @[ @1 ], @"%@", read);
    read = [self read:@"Manager/Reports/$count gt 1" entity:entity context:context error:&error];
    XCTAssertEqualObjects([self idsOf:@"Employee" where:read in:context], (@[ @3, @4 ]), @"%@", read);
  }
  NSDictionary *entities = OISStaffModel().entitiesByName;
  NSEntityDescription *employee = entities[@"Employee"], *manager = entities[@"Manager"];
  [self assertClientPredicates:@[
    [NSPredicate predicateWithFormat:@"entity == %@", manager],
    [NSPredicate predicateWithFormat:@"entity == %@", employee],
    [NSPredicate predicateWithFormat:@"entity != %@", employee],
    [NSPredicate predicateWithFormat:@"entity IN %@", @[ employee, manager ]],
    [NSPredicate predicateWithFormat:@"manager.entity == %@", manager],
    [NSPredicate predicateWithFormat:@"entity == %@ AND budget > 1000", manager],
    [NSPredicate predicateWithFormat:@"SUBQUERY(reports, $r, $r.entity == %@).@count > 0", manager],
  ] entity:@"Employee" contexts:[self staffs]];
}

@end
