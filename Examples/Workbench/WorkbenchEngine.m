// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchEngine.h"
// Only the bitmap: all of AppKit after CoreData redefines, on GNUstep, the
// attribute types NSPredicateEditorRowTemplate.h declares as well.
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSGraphics.h>

#pragma mark - The built-in service's operations

// What a product can be asked, and told: declared here, served by
// ODataService (see ODataService.h), and offered by the Workbench's
// Operations menu like any service's.
@protocol WorkbenchProductFunctions <ODataFunctions>
- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply;
+ (NSArray *)cheaperThanPrice:(double)price reply:(ODataReply *)reply;
@end

@protocol WorkbenchProductActions <ODataActions>
- (NSDecimalNumber *)raisePriceByPercent:(double)percent reply:(ODataReply *)reply;
@end

@interface WorkbenchProduct : NSManagedObject <WorkbenchProductFunctions, WorkbenchProductActions>
@end

@implementation WorkbenchProduct

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"cheaperThanPrice:reply:": @"Collection(Catalog.Product)" };
}

- (NSDecimalNumber *)price:(double)percent
{
  NSDecimalNumber *factor = [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)llround(fabs(percent) * 100) exponent:-4 isNegative:percent < 0];
  NSDecimalNumber *price = [self valueForKey:@"unitPrice"] ?: [NSDecimalNumber zero];
  NSDecimalNumberHandler *cents = [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundPlain scale:2
                                                                             raiseOnExactness:NO raiseOnOverflow:NO
                                                                             raiseOnUnderflow:NO raiseOnDivideByZero:NO];
  return [price decimalNumberByAdding:[price decimalNumberByMultiplyingBy:factor] withBehavior:cents];
}

- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply
{
  return [self price:-percent];
}

- (NSDecimalNumber *)raisePriceByPercent:(double)percent reply:(ODataReply *)reply
{
  if (percent <= -100) {
    [reply failWithError:ODataServiceError(400, @"A price cannot fall by 100% or more")];
    return nil;
  }
  NSDecimalNumber *price = [self price:percent];
  NSString *what = [NSString stringWithFormat:@"%@: %@ raised by %g%% to %@", [self valueForKey:@"name"], [self valueForKey:@"unitPrice"], percent, price];
  [self setValue:price forKey:@"unitPrice"];
  // Written with the change, in the same save; nothing of it is served.
  NSManagedObject *entry = [NSEntityDescription insertNewObjectForEntityForName:@"AuditEntry" inManagedObjectContext:self.managedObjectContext];
  [entry setValue:[NSUUID UUID].UUIDString forKey:@"id"];
  [entry setValue:[NSDate date] forKey:@"at"];
  [entry setValue:what forKey:@"what"];
  return price;
}

// Bound to the collection it is called on: all the products, or one
// category's (Categories(1)/Products/Catalog.CheaperThanPrice(Price=20)).
+ (NSArray *)cheaperThanPrice:(double)price reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [reply.request.collectionFetchRequest copy];
  NSPredicate *cheaper = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"unitPrice"]
                                                            rightExpression:[NSExpression expressionForConstantValue:@(price)]
                                                                   modifier:NSDirectPredicateModifier
                                                                       type:NSLessThanPredicateOperatorType
                                                                    options:0];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[ fetch.predicate, cheaper ]];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"unitPrice" ascending:YES] ];
  NSError *error = nil;
  NSArray *rows = [reply.request.context executeFetchRequest:fetch error:&error];
  if (!rows) [reply failWithError:error];
  return rows;
}

@end

@protocol WorkbenchCatalogFunctions <ODataFunctions>
- (int32_t)countProductsInCategoryWithName:(NSString *)name reply:(ODataReply *)reply;
// The products, after a wait: a request that takes its time, for
// Prefer: respond-async.
- (int32_t)countProductsSlowlyInSeconds:(double)seconds reply:(ODataReply *)reply;
@end

@interface WorkbenchCatalogOperations : NSObject <WorkbenchCatalogFunctions, ODataSyncPeerTokenActions>
// Peer tokens for devices (ODataSync's peer sync): the sync service's.
@property (nonatomic, weak) ODataSyncService *sync;
@end

// Who calls the built-in service: "workbench", whoever it is. It serves
// itself, or the local network with no authentication (Sync > Serve on the
// Network); a device gets a peer token for this subject.
// The key the built-in service signs peer tokens with: made once and kept
// (the user's defaults: an example's key, not a secret worth more), so
// that tokens issued before the Workbench restarted still check with the
// keys the devices kept.
static NSDictionary *WBPeerSigningKey(void)
{
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *kept = [defaults dictionaryForKey:@"WBPeerSigningKey"];
  if ([kept[@"d"] isKindOfClass:[NSString class]] && [kept[@"kty"] isEqual:@"EC"]) return kept;
  NSDictionary *made = HSGenerateSigningKey(NULL);
  if (made) [defaults setObject:made forKey:@"WBPeerSigningKey"];
  return made;
}

@interface WorkbenchSignIn : NSObject <HSAuthenticator>
@end

@implementation WorkbenchSignIn
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  [reply finishWithPrincipal:[[HSPrincipal alloc] initWithSubject:@"workbench" claims:@{}]];
}
@end

@implementation WorkbenchCatalogOperations

- (NSDictionary *)peerTokenWithReplica:(NSString *)replica thumbprint:(NSString *)thumbprint reply:(ODataReply *)reply
{
  ODataSyncService *sync = self.sync;
  if (!sync) {
    [reply failWithError:ODataServiceError(501, @"The Workbench issues no peer tokens (it has no signing key)")];
    return nil;
  }
  return [sync peerTokenWithReplica:replica thumbprint:thumbprint reply:reply];
}

+ (NSDictionary *)ODataOperationNames
{
  return @{ @"countProductsInCategoryWithName:reply:": @"CountProductsInCategoryNamed",
            @"countProductsSlowlyInSeconds:reply:": @"CountProductsSlowly" };
}

- (int32_t)countProductsSlowlyInSeconds:(double)seconds reply:(ODataReply *)reply
{
  NSUInteger count = [reply.request.context countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Product"] error:NULL];
  [reply defer];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, MIN(seconds, 30)) * NSEC_PER_SEC)),
                 dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [reply finishWithResult:@(count == NSNotFound ? 0 : count)];
  });
  return 0;
}

- (int32_t)countProductsInCategoryWithName:(NSString *)name reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"category.name"]
                                                       rightExpression:[NSExpression expressionForConstantValue:name ?: @""]
                                                              modifier:NSDirectPredicateModifier
                                                                  type:NSEqualToPredicateOperatorType
                                                               options:0];
  NSUInteger count = [reply.request.context countForFetchRequest:fetch error:NULL];
  return count == NSNotFound ? 0 : (int32_t)count;
}

@end

// A picture to download: 4x4 pixels, a PNG.
static NSData *WBPicturePNG(void)
{
  // Four colours blending across, drawn pixel by pixel: no drawing context
  // needed, so the same on Apple and GNUstep, headless or not.
  NSInteger width = 96, height = 64;
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                                                                  bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width * 3 bitsPerPixel:24];
  unsigned char *pixels = bitmap.bitmapData;
  const double corners[4][3] = { { 230, 80, 60 }, { 250, 200, 60 }, { 60, 120, 220 }, { 70, 190, 120 } };
  for (NSInteger y = 0; y < height; y++) {
    for (NSInteger x = 0; x < width; x++) {
      double u = (double)x / (width - 1), v = (double)y / (height - 1);
      for (int c = 0; c < 3; c++) {
        double top = corners[0][c] * (1 - u) + corners[1][c] * u, bottom = corners[2][c] * (1 - u) + corners[3][c] * u;
        pixels[y * width * 3 + x * 3 + c] = (unsigned char)(top * (1 - v) + bottom * v);
      }
    }
  }
  return [bitmap representationUsingType:NSPNGFileType properties:@{}];
}

static NSDate *WBDay(NSString *day)
{
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  formatter.dateFormat = @"yyyy-MM-dd";
  return [formatter dateFromString:day];
}

#pragma mark - The engine

NSString *WorkbenchServiceStamp(NSString *previous)
{
  // Past the wall clock, and past the stamp it replaces.
  long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
  long long seen = previous.length >= 21 ? [[previous substringToIndex:16] longLongValue] : 0;
  if (now > seen) return [NSString stringWithFormat:@"%016lld.0000.service0", now];
  return [NSString stringWithFormat:@"%016lld.%04d.service0", seen, [[previous substringWithRange:NSMakeRange(17, 4)] intValue] + 1];
}

@implementation WorkbenchEngine {
  ODataSyncService *_sync;
  NSURL *_modelURL;
  NSMutableArray *_log;
  NSURL *_storeURL;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot modelURL:(NSURL *)modelURL
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _modelURL = [modelURL copy];
  _log = [NSMutableArray array];
  if (![self startService]) return nil;
  return self;
}

- (NSURL *)modelURL
{
  return _modelURL;
}

- (NSArray *)log
{
  return [_log copy];
}

- (void)reset
{
  [_log removeAllObjects];
  [self startService];
}

- (void)forgetStore
{
  if (!_storeURL) return;
  for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
    [[NSFileManager defaultManager] removeItemAtPath:[_storeURL.path stringByAppendingString:suffix] error:NULL];
  }
  _storeURL = nil;
}

- (void)dealloc
{
  [self forgetStore];
}

- (NSString *)changeAtTheService
{
  return [self changeProductAtTheService:nil];
}

- (NSString *)changeProductAtTheService:(NSNumber *)productID
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = self.service.coordinator;
  __block NSString *what = @"Nothing to change.";
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
    if (productID) fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", productID];
    fetch.fetchLimit = 1;
    NSManagedObject *product = [[context executeFetchRequest:fetch error:NULL] firstObject];
    if (!product) return;
    NSDecimalNumber *price = [product valueForKey:@"unitPrice"] ?: [NSDecimalNumber zero];
    NSDecimalNumber *raised = [price decimalNumberByAdding:[NSDecimalNumber one]];
    [product setValue:raised forKey:@"unitPrice"];
    [product setValue:@([[product valueForKey:@"version"] longLongValue] + 1) forKey:@"version"];
    [product setValue:WorkbenchServiceStamp([product valueForKey:@"lastChanged"]) forKey:@"lastChanged"];
    NSError *error = nil;
    what = [context save:&error] ? [NSString stringWithFormat:@"At the service, %@ now costs %@ (version %@).",
                                                              [product valueForKey:@"name"], raised, [product valueForKey:@"version"]]
                                 : [NSString stringWithFormat:@"The change failed: %@", error.localizedDescription];
  }];
  return what;
}

// A model of the service's own, whose products are WorkbenchProducts: the
// client's model is the same file, with plain managed objects. A copy,
// since a model loaded again may be the one the client already uses, which
// can no longer change.
- (BOOL)startService
{
  NSManagedObjectModel *model = WorkbenchBuiltInModel(_modelURL);
  if (!model.entities.count) return NO;
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  product.managedObjectClassName = NSStringFromClass([WorkbenchProduct class]);
  // Deletions kept, for ODataSync's devices (not served: no key).
  [ODataSyncService addBookkeepingToModel:model configuration:nil];
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  // SQLite, which keeps persistent history: the service's delta links.
  [self forgetStore];
  _storeURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"Workbench-%@.sqlite", [NSProcessInfo processInfo].globallyUniqueString]]];
  if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:_storeURL
                                       options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error]) {
    NSLog(@"Workbench: the built-in service's store does not open: %@", error);
    return NO;
  }
  [self seedCoordinator:coordinator];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator serviceRoot:_serviceRoot];
  service.namespaceName = @"Catalog";
  // Not AuditEntry: the model's other configuration, the application's.
  service.configurationName = WorkbenchServedConfiguration;
  WorkbenchCatalogOperations *operations = [[WorkbenchCatalogOperations alloc] init];
  service.serviceOperations = operations;
  service.authenticator = [[WorkbenchSignIn alloc] init];
  // GET <root>/$explain/<path>: the Explain button's plans.
  service.explains = YES;
  // Histories compared, deletions kept: the Sync window's devices.
  _sync = [[ODataSyncService alloc] initWithService:service];
  // Peer tokens, signed by a key of this run's: devices that sync with the
  // Workbench trust each other by them (the Device app's Peers).
  NSDictionary *signingKey = WBPeerSigningKey();
  if (signingKey) {
    _sync.peerTokens = [[ODataSyncPeerTokenIssuer alloc] initWithIssuer:_serviceRoot.absoluteString signingKey:signingKey];
    operations.sync = _sync;
  }
  for (NSString *problem in service.operationProblems) NSLog(@"Workbench: %@", problem);
  for (NSString *problem in service.metadataProblems) NSLog(@"Workbench: %@", problem);
  _service = service;
  return YES;
}

static NSManagedObject *WBInsert(NSManagedObjectContext *context, NSString *entity, NSDictionary *values)
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) [object setValue:values[key] forKey:key];
  return object;
}

// A few of Northwind's rows.
- (void)seedCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  [context performBlockAndWait:^{
    NSMutableDictionary *categories = [NSMutableDictionary dictionary];
    NSArray *categoryNames = @[ @"Beverages", @"Condiments", @"Confections", @"Dairy Products", @"Produce", @"Seafood" ];
    for (NSUInteger i = 0; i < categoryNames.count; i++) {
      categories[@(i + 1)] = WBInsert(context, @"Category", @{ @"id": @(i + 1), @"name": categoryNames[i] });
    }
    NSMutableDictionary *suppliers = [NSMutableDictionary dictionary];
    NSArray *supplierRows = @[ @[ @"Exotic Liquids", @"London", @"UK" ], @[ @"New Orleans Cajun Delights", @"New Orleans", @"USA" ],
                               @[ @"Grandma Kelly's Homestead", @"Ann Arbor", @"USA" ], @[ @"Tokyo Traders", @"Tokyo", @"Japan" ],
                               @[ @"Cooperativa de Quesos", @"Oviedo", @"Spain" ] ];
    for (NSUInteger i = 0; i < supplierRows.count; i++) {
      NSArray *row = supplierRows[i];
      suppliers[@(i + 1)] = WBInsert(context, @"Supplier", @{ @"id": @(i + 1), @"companyName": row[0], @"city": row[1], @"country": row[2] });
    }
    NSMutableDictionary *locations = [NSMutableDictionary dictionary];
    NSArray *locationRows = @[ @[ @"Warehouse North", @"Seattle", @"USA" ], @[ @"Dock 4", @"London", @"UK" ], @[ @"Cold Store", @"Tokyo", @"Japan" ] ];
    for (NSUInteger i = 0; i < locationRows.count; i++) {
      NSArray *row = locationRows[i];
      locations[@(i + 1)] = WBInsert(context, @"Location", @{ @"id": @(i + 1), @"name": row[0], @"city": row[1], @"country": row[2] });
    }
    // id, name, quantity per unit, price, discontinued, category, suppliers
    NSArray *productRows = @[
      @[ @1, @"Chai", @"10 boxes x 20 bags", @"18", @NO, @1, @[ @1, @4 ] ],
      @[ @2, @"Chang", @"24 - 12 oz bottles", @"19", @NO, @1, @[ @1 ] ],
      @[ @3, @"Aniseed Syrup", @"12 - 550 ml bottles", @"10", @NO, @2, @[ @1 ] ],
      @[ @4, @"Chef Anton's Cajun Seasoning", @"48 - 6 oz jars", @"22", @NO, @2, @[ @2 ] ],
      @[ @5, @"Grandma's Boysenberry Spread", @"12 - 8 oz jars", @"25", @NO, @2, @[ @3 ] ],
      @[ @6, @"Uncle Bob's Organic Dried Pears", @"12 - 1 lb pkgs.", @"30", @NO, @5, @[ @3 ] ],
      @[ @7, @"Ikura", @"12 - 200 ml jars", @"31", @NO, @6, @[ @4 ] ],
      @[ @8, @"Queso Cabrales", @"1 kg pkg.", @"21", @NO, @4, @[ @5 ] ],
      @[ @9, @"Konbu", @"2 kg box", @"6", @NO, @6, @[ @4 ] ],
      @[ @10, @"Tofu", @"40 - 100 g pkgs.", @"23.25", @NO, @5, @[ @4 ] ],
      @[ @11, @"Sir Rodney's Marmalade", @"30 gift boxes", @"81", @NO, @3, @[ @3 ] ],
      @[ @12, @"Côte de Blaye", @"12 - 75 cl bottles", @"263.5", @NO, @1, @[ @1 ] ],
      @[ @13, @"Guaraná Fantástica", @"12 - 355 ml cans", @"4.5", @YES, @1, @[ @2 ] ],
      @[ @14, @"NuNuCa Nuß-Nougat-Creme", @"20 - 450 g glasses", @"14", @NO, @3, @[ @3 ] ],
    ];
    NSMutableDictionary *products = [NSMutableDictionary dictionary];
    for (NSArray *row in productRows) {
      NSManagedObject *product = WBInsert(context, @"Product", @{
        @"id": row[0], @"name": row[1], @"quantityPerUnit": row[2],
        @"unitPrice": [NSDecimalNumber decimalNumberWithString:row[3]], @"discontinued": row[4],
        @"category": categories[row[5]], @"version": @1 });
      NSMutableSet *supplied = [product mutableSetValueForKey:@"suppliers"];
      for (NSNumber *supplier in row[6]) [supplied addObject:suppliers[supplier]];
      products[row[0]] = product;
    }
    // id, product, location, quantity
    NSArray *stockRows = @[ @[ @1, @1, @1, @39 ], @[ @2, @1, @2, @12 ], @[ @3, @2, @1, @17 ], @[ @4, @4, @1, @53 ],
                            @[ @5, @7, @3, @31 ], @[ @6, @11, @2, @40 ], @[ @7, @12, @2, @8 ], @[ @8, @13, @1, @20 ] ];
    for (NSArray *row in stockRows) {
      WBInsert(context, @"Stock", @{ @"id": row[0], @"product": products[row[1]], @"location": locations[row[2]], @"quantity": row[3] });
    }
    // A category's budget over time: [category, from, to, amount].
    NSArray *budgetRows = @[ @[ @"Beverages", @"2024-01-01", @"2025-01-01", @"1000" ], @[ @"Beverages", @"2025-01-01", [NSNull null], @"1200" ],
                             @[ @"Seafood", @"2024-01-01", @"2024-07-01", @"800" ], @[ @"Seafood", @"2024-07-01", [NSNull null], @"950" ] ];
    long long budgetID = 1;
    for (NSArray *row in budgetRows) {
      NSManagedObject *budget = WBInsert(context, @"Budget", @{ @"id": @(budgetID++), @"category": row[0], @"from": WBDay(row[1]),
                                                                @"amount": [NSDecimalNumber decimalNumberWithString:row[3]] });
      if (row[2] != [NSNull null]) [budget setValue:WBDay(row[2]) forKey:@"to"];
    }
    WBInsert(context, @"Picture", @{ @"id": @1, @"name": @"Swatch", @"content": WBPicturePNG(), @"contentType": @"image/png" });
    // Equipment, each kind with dynamic properties of its own:
    // [id, name, kind, location, dynamic properties].
    NSDecimalNumber *(^decimal)(NSString *) = ^NSDecimalNumber *(NSString *text) { return [NSDecimalNumber decimalNumberWithString:text]; };
    NSArray *unitRows = @[
      @[ @1, @"Forklift FL-1", @"Forklift", @1, @{ @"LoadCapacityKg": @2500, @"MastHeightM": decimal(@"4.5"), @"LastService": WBDay(@"2025-11-03") } ],
      @[ @2, @"Forklift FL-2", @"Forklift", @2, @{ @"LoadCapacityKg": @1800, @"MastHeightM": decimal(@"3.3"), @"LastService": WBDay(@"2026-02-14") } ],
      @[ @3, @"Freezer CF-1", @"Freezer", @3, @{ @"MinTemperatureC": @-25, @"Refrigerant": @"R-452A", @"AutoDefrost": @YES,
                                                  @"Alarm": @{ @"High": @-18, @"Low": @-30 } } ],
      @[ @4, @"Scale SC-1", @"Scale", @2, @{ @"MaxWeightKg": @300, @"Calibrated": WBDay(@"2026-01-10"), @"Certificate": @"PTB-2026-0113" } ],
    ];
    for (NSArray *row in unitRows) {
      WBInsert(context, @"EquipmentUnit", @{ @"id": row[0], @"name": row[1], @"kind": row[2], @"location": locations[row[3]],
                                             @"dynamicProperties": row[4] });
    }
    // The sales organizations, each under its superordinate, and their sales.
    NSMutableDictionary *organizations = [NSMutableDictionary dictionary];
    NSArray *organizationRows = @[ @[ @"Sales", @"Corporate Sales", @"" ], @[ @"US", @"US", @"Sales" ], @[ @"US West", @"US West", @"US" ],
                                   @[ @"US East", @"US East", @"US" ], @[ @"EMEA", @"EMEA", @"Sales" ], @[ @"EMEA Central", @"EMEA Central", @"EMEA" ] ];
    for (NSArray *row in organizationRows) {
      NSManagedObject *organization = WBInsert(context, @"SalesOrganization", @{ @"id": row[0], @"name": row[1] });
      if ([row[2] length]) [organization setValue:organizations[row[2]] forKey:@"superordinate"];
      organizations[row[0]] = organization;
    }
    NSArray *saleRows = @[ @[ @1, @"US West", @"1" ], @[ @2, @"US West", @"2" ], @[ @3, @"US West", @"4" ], @[ @4, @"US East", @"8" ],
                           @[ @5, @"US East", @"4" ], @[ @6, @"EMEA Central", @"2" ], @[ @7, @"EMEA Central", @"1" ], @[ @8, @"EMEA Central", @"2" ] ];
    for (NSArray *row in saleRows) {
      WBInsert(context, @"Sale", @{ @"id": row[0], @"salesOrganization": organizations[row[1]], @"amount": [NSDecimalNumber decimalNumberWithString:row[2]] });
    }
    NSError *error = nil;
    if (![context save:&error]) NSLog(@"Workbench: seeding the built-in service failed: %@", error);
  }];
}

#pragma mark Transport

// The service answers, and the exchange is logged as it went: a handler
// that answers later is logged when it does.
- (void)startExchange:(ODataExchange *)exchange
{
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:self action:@selector(innerDidFinish:)];
  inner.context = @[ exchange, [NSDate date] ];
  @synchronized (self) {
    _started++;
  }
  [self.service startExchange:inner];
}

- (void)innerDidFinish:(ODataExchange *)inner
{
  ODataExchange *outer = inner.context[0];
  NSDate *started = inner.context[1];
  outer.URLResponse = inner.URLResponse;
  outer.data = inner.data;
  outer.error = inner.error;

  NSURLRequest *request = inner.request;
  NSHTTPURLResponse *http = [inner.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)inner.URLResponse : nil;
  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  entry.method = request.HTTPMethod.uppercaseString ?: @"GET";
  entry.URL = request.URL.absoluteString ?: @"";
  entry.status = http.statusCode;
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.responseHeaders = http.allHeaderFields;
  entry.responseData = inner.data ?: [NSData data];
  entry.failure = inner.error.localizedDescription;
  entry.date = started;
  entry.duration = -[started timeIntervalSinceNow];
  entry.storeHint = [self hintForURL:request.URL method:entry.method];
  @synchronized (_log) {
    [_log insertObject:entry atIndex:0];
    if (_log.count > 48) [_log removeLastObject];
  }
  if (self.didHandle) self.didHandle(entry);
  [outer finish];
}

- (NSString *)hintForURL:(NSURL *)url method:(NSString *)method
{
  NSString *path = [self relativePath:url];
  if ([path isEqualToString:@"$batch"]) return @"executeRequest:withContext:error:  (NSSaveChangesRequest, one change set)";
  if ([method isEqualToString:@"PATCH"] || [method isEqualToString:@"POST"] || [method isEqualToString:@"DELETE"]) {
    return @"executeRequest:withContext:error:  (NSSaveChangesRequest)";
  }
  if ([path rangeOfString:@"/$count"].location != NSNotFound) {
    return @"executeRequest:withContext:error:  (NSCountResultType)";
  }
  if ([path rangeOfString:@")/"].location != NSNotFound) {
    return @"newValueForRelationship:forObjectWithID:withContext:error:";
  }
  if ([path rangeOfString:@"("].location != NSNotFound) {
    return @"newValuesForObjectWithID:withContext:error:";
  }
  return @"executeRequest:withContext:error:  (NSFetchRequest)";
}

- (NSString *)relativePath:(NSURL *)url
{
  NSString *path = url.path ?: @"";
  NSString *root = self.serviceRoot.path ?: @"";
  if (root.length && [path hasPrefix:root]) path = [path substringFromIndex:root.length];
  while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
  return path;
}

@end

#pragma mark - The network

@implementation WorkbenchNetworkTransport

- (void)startExchange:(ODataExchange *)exchange
{
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:self action:@selector(innerDidFinish:)];
  inner.context = @[ exchange, [NSDate date] ];
  @synchronized (self) {
    _started++;
  }
  [ODataDefaultTransport() startExchange:inner];
}

- (void)innerDidFinish:(ODataExchange *)inner
{
  ODataExchange *outer = inner.context[0];
  NSDate *started = inner.context[1];
  outer.URLResponse = inner.URLResponse;
  outer.data = inner.data;
  outer.error = inner.error;

  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  NSURLRequest *request = inner.request;
  entry.method = request.HTTPMethod.uppercaseString ?: @"GET";
  entry.URL = request.URL.absoluteString ?: @"";
  NSHTTPURLResponse *http = [inner.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)inner.URLResponse : nil;
  entry.status = http.statusCode;
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.responseHeaders = http.allHeaderFields;
  entry.responseData = inner.data;
  entry.failure = inner.error.localizedDescription;
  entry.date = started;
  entry.duration = -[started timeIntervalSinceNow];
  entry.storeHint = @"";
  void (^report)(WorkbenchLogEntry *) = self.didHandle;
  // The main thread may be waiting for this very exchange: report later,
  // never wait for it.
  if (report) [self performSelectorOnMainThread:@selector(report:) withObject:@[ [report copy], entry ] waitUntilDone:NO];
  [outer finish];
}

- (void)report:(NSArray *)blockAndEntry
{
  void (^report)(WorkbenchLogEntry *) = blockAndEntry[0];
  report(blockAndEntry[1]);
}

@end
