// ois-live — the store against a real OData v4 service.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The snapshot suite checks what the store sends; this checks that real
// services agree, using two of Microsoft's public reference services:
//
// - Northwind v4, read-only, through the Catalog model, whose Product and
//   Category match Northwind's: paging, filters, sorting, relationships.
// - Northwind v4 again, through Tests/Live/Northwind.xcdatamodeld, for
//   data types: dates in filters and rows, exact decimals, binary.
// - TripPin RW, through Tests/Live/TripPin.xcdatamodeld: creating a person
//   with a client-chosen key, updates carrying ETags, to-one and to-many
//   references, a 412 conflict, and a delete. TripPin gives each
//   client a session of its own, so these writes touch nobody's data.
//
// - Models from $metadata: TripPin's built at runtime, as a dynamic client
//   does, and Northwind's generated ahead of time by ois-model and
//   compiled with momc (NorthwindGenerated.momd), which the store checks
//   against the service's schema as Core Data checks a model version.
//
// - Streams and $search on TripPin, with its own model: a photo, a media
//   entity, downloaded, uploaded, and created from a file; people and
//   airports found by $search.
//
//   ois-live <directory holding Catalog.momd, Northwind.momd, TripPin.momd
//             and NorthwindGenerated.momd>
//
// Exits 1 if any check fails. The service is not ours, so CI runs this
// without letting it fail a build.

#import "ODataIncrementalStore.h"
#include <stdio.h>

static int failures = 0;

static void check(BOOL ok, NSString *what, NSString *detail)
{
  if (!ok) failures++;
  fprintf(stderr, "%s  %s%s%s\n", ok ? "PASS" : "FAIL", what.UTF8String,
          detail.length ? " — " : "", detail.UTF8String ?: "");
}

// The store's own error, where Core Data wrapped it in one of its own.
static NSString *reason(NSError *error)
{
  if (!error) return nil;
  NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
  if (!underlying) underlying = OISDetailedErrors(error).firstObject;
  NSError *e = underlying ?: error;
  NSString *why = e.userInfo[NSLocalizedFailureReasonErrorKey];
  return why ? [NSString stringWithFormat:@"%@ (%@)", e.localizedDescription, why] : e.localizedDescription;
}

static NSString *describe(NSArray *rows, NSError *error)
{
  if (error) return reason(error);
  return rows ? [NSString stringWithFormat:@"%lu rows", (unsigned long)rows.count] : @"nil";
}

static NSPersistentStoreCoordinator *openStore(NSString *modelPath, NSURL *root)
{
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:modelPath]];
  if (!model) {
    check(NO, @"load the model", modelPath);
    return nil;
  }
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  id store = [psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                               configuration:nil
                                         URL:root
                                     options:nil
                                       error:&error];
  check(store != nil, [NSString stringWithFormat:@"open %@ ($metadata)", root.host], error.localizedDescription);
  return store ? psc : nil;
}

static NSManagedObjectContext *newContext(NSPersistentStoreCoordinator *psc)
{
  NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  moc.persistentStoreCoordinator = psc;
  return moc;
}

static void northwind(NSString *models)
{
  fprintf(stderr, "== Northwind (read)\n");
  NSURL *root = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
  NSPersistentStoreCoordinator *psc = openStore([models stringByAppendingPathComponent:@"Catalog.momd"], root);
  if (!psc) return;
  ODataIncrementalStore *catalogStore = psc.persistentStores.firstObject;
  fprintf(stderr, "      (the Catalog model against Northwind's $metadata: %lu differences, e.g. %s)\n",
          (unsigned long)catalogStore.metadataProblems.count, [catalogStore.metadataProblems.firstObject UTF8String] ?: "none");
  NSManagedObjectContext *moc = newContext(psc);
  [moc performBlockAndWait:^{
      NSError *e = nil;
      NSFetchRequest *all = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      NSUInteger count = [moc countForFetchRequest:all error:&e];
      check(e == nil && count > 0 && count != NSNotFound, @"count products ($count)",
            e ? e.localizedDescription : [NSString stringWithFormat:@"%lu", (unsigned long)count]);

      // Northwind pages at 20, so every product means following next links.
      e = nil;
      NSArray *products = [moc executeFetchRequest:all error:&e];
      check(products.count == count, @"fetch every product across pages",
            [NSString stringWithFormat:@"%@, expected %lu", describe(products, e), (unsigned long)count]);

      e = nil;
      NSFetchRequest *filtered = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      filtered.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
      filtered.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
      NSArray *some = [moc executeFetchRequest:filtered error:&e];
      NSUInteger someCount = [moc countForFetchRequest:filtered error:NULL];
      check(some.count > 0 && some.count == someCount, @"filter and sort ($filter, $orderby)",
            [NSString stringWithFormat:@"%@, count says %lu", describe(some, e), (unsigned long)someCount]);

      // A dictionary's key path through a to-one relationship: an $expand
      // with its $select (Northwind answers 400 to Category/CategoryName in
      // a $select).
      e = nil;
      NSFetchRequest *withCategory = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      withCategory.resultType = NSDictionaryResultType;
      withCategory.propertiesToFetch = @[ @"name", @"category.name" ];
      withCategory.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
      NSDictionary *chai = [[moc executeFetchRequest:withCategory error:&e] firstObject];
      check([chai[@"category.name"] isEqual:@"Beverages"], @"a dictionary through a to-one relationship ($expand=Category($select=CategoryName))",
            e ? reason(e) : [chai description]);

      NSManagedObject *product = some.firstObject;
      NSManagedObject *category = [product valueForKey:@"category"];
      NSString *categoryName = [category valueForKey:@"name"];
      check(categoryName.length > 0, @"fault a to-one relationship", categoryName);

      e = nil;
      NSFetchRequest *byCategory = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      byCategory.predicate = [NSPredicate predicateWithFormat:@"category == %@", category];
      NSArray *inCategory = [moc executeFetchRequest:byCategory error:&e];
      NSUInteger related = [[category valueForKey:@"products"] count];
      check(inCategory.count > 0 && inCategory.count == related, @"compare a relationship with an object",
            [NSString stringWithFormat:@"%@, the category has %lu", describe(inCategory, e), (unsigned long)related]);

      e = nil;
      NSFetchRequest *sorted = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      sorted.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"category.name" ascending:YES] ];
      NSArray *byName = [moc executeFetchRequest:sorted error:&e];
      NSString *firstName = [byName.firstObject valueForKeyPath:@"category.name"];
      NSString *lastName = [byName.lastObject valueForKeyPath:@"category.name"];
      check(byName.count == count && [firstName compare:lastName] != NSOrderedDescending,
            @"sort through a relationship", [NSString stringWithFormat:@"%@, %@ … %@", describe(byName, e), firstName, lastName]);

      e = nil;
      NSFetchRequest *named = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      named.predicate = [NSPredicate predicateWithFormat:@"name IN %@", @[ @"Chai", @"Chang", @"Tofu" ]];
      NSArray *three = [moc executeFetchRequest:named error:&e];
      check(three.count == 3, @"IN over values, in 4.0 (eq … or …: a 4.0 service refuses `in`)", describe(three, e));

      e = nil;
      NSFetchRequest *pricey = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
      pricey.predicate = [NSPredicate predicateWithFormat:@"ANY products.unitPrice > 100"];
      NSArray *categories = [moc executeFetchRequest:pricey error:&e];
      check(categories.count > 0, @"ANY over a to-many relationship (any())", describe(categories, e));

      e = nil;
      NSFetchRequest *cheap = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
      cheap.predicate = [NSPredicate predicateWithFormat:@"ALL products.unitPrice < 1000"];
      NSArray *allCheap = [moc executeFetchRequest:cheap error:&e];
      NSUInteger categoryCount = [moc countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Category"] error:NULL];
      check(allCheap.count > 0 && allCheap.count == categoryCount, @"ALL over a to-many relationship (all())",
            [NSString stringWithFormat:@"%@ of %lu", describe(allCheap, e), (unsigned long)categoryCount]);
  }];
}

static void northwindTypes(NSString *models)
{
  fprintf(stderr, "== Northwind (types)\n");
  NSURL *root = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
  NSPersistentStoreCoordinator *psc = openStore([models stringByAppendingPathComponent:@"Northwind.momd"], root);
  if (!psc) return;
  NSManagedObjectContext *moc = newContext(psc);
  [moc performBlockAndWait:^{
    NSError *e = nil;
    // A DateTimeOffset literal in $filter, and dates read back as NSDate.
    NSDate *since = ODataDateFromString(@"1998-05-01T00:00:00Z");
    NSFetchRequest *late = [NSFetchRequest fetchRequestWithEntityName:@"Order"];
    late.predicate = [NSPredicate predicateWithFormat:@"orderDate >= %@", since];
    NSArray *orders = [moc executeFetchRequest:late error:&e];
    BOOL datesOK = orders.count > 0;
    for (NSManagedObject *order in orders) {
      NSDate *date = [order valueForKey:@"orderDate"];
      datesOK = datesOK && [date isKindOfClass:[NSDate class]] && [date compare:since] != NSOrderedAscending;
    }
    check(datesOK, @"filter on a date, read dates back (DateTimeOffset)", describe(orders, e));

    // Freight arrives as "32.3800" with IEEE754Compatible, and stays exact.
    e = nil;
    NSFetchRequest *first = [NSFetchRequest fetchRequestWithEntityName:@"Order"];
    first.predicate = [NSPredicate predicateWithFormat:@"id == 10248"];
    NSManagedObject *order = [[moc executeFetchRequest:first error:&e] firstObject];
    NSDecimalNumber *freight = [order valueForKey:@"freight"];
    check([freight isKindOfClass:[NSDecimalNumber class]] && [freight isEqual:[NSDecimalNumber decimalNumberWithString:@"32.38"]],
          @"decimals keep every digit (IEEE754Compatible)", reason(e) ?: freight.stringValue);

    e = nil;
    NSFetchRequest *filtered = [NSFetchRequest fetchRequestWithEntityName:@"Order"];
    filtered.predicate = [NSPredicate predicateWithFormat:@"freight > %@", [NSDecimalNumber decimalNumberWithString:@"1000.5"]];
    NSArray *heavy = [moc executeFetchRequest:filtered error:&e];
    BOOL heavyOK = heavy.count > 0;
    for (NSManagedObject *o in heavy) heavyOK = heavyOK && [[o valueForKey:@"freight"] compare:@1000.5] == NSOrderedDescending;
    check(heavyOK, @"filter on a decimal", describe(heavy, e));

    // Pictures are base64 (Northwind's is plain base64, not base64url).
    e = nil;
    NSFetchRequest *categories = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
    categories.fetchLimit = 1;
    NSData *picture = [[[moc executeFetchRequest:categories error:&e] firstObject] valueForKey:@"picture"];
    check([picture isKindOfClass:[NSData class]] && picture.length > 1000, @"read binary data (Binary)",
          reason(e) ?: [NSString stringWithFormat:@"%lu bytes", (unsigned long)picture.length]);
  }];
}

// TripPin keeps each client's writes in a session named in the URL,
// /(S(<24 characters>))/TripPinServiceRW/, and creates one on first use.
// The session is named here, so every run starts from TripPin's own data
// and nothing it writes is seen by anyone else.
static NSURL *tripPinSession(void)
{
  static const char alphabet[] = "abcdefghijklmnopqrstuvwxyz0123456789";
  char session[25] = "ois";
  for (int i = 3; i < 24; i++) session[i] = alphabet[arc4random_uniform(sizeof alphabet - 1)];
  session[24] = 0;
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://services.odata.org/V4/(S(%s))/TripPinServiceRW/", session]];
}

// A write the store knows nothing about, as another client would make it:
// the person's ETag changes behind the store's back.
static BOOL changeBehindTheStoresBack(NSURL *root, NSString *userName)
{
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"People('%@')", userName] relativeToURL:root];
  NSMutableURLRequest *get = [NSMutableURLRequest requestWithURL:url];
  [get setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSHTTPURLResponse *response = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [NSURLConnection sendSynchronousRequest:get returningResponse:(NSURLResponse **)&response error:NULL];
  NSString *etag = response.allHeaderFields[@"ETag"] ?: response.allHeaderFields[@"Etag"];
  NSMutableURLRequest *patch = [NSMutableURLRequest requestWithURL:url];
  patch.HTTPMethod = @"PATCH";
  patch.HTTPBody = [@"{\"LastName\":\"Elsewhere\"}" dataUsingEncoding:NSUTF8StringEncoding];
  [patch setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [patch setValue:@"4.0" forHTTPHeaderField:@"OData-Version"];
  if (etag) [patch setValue:etag forHTTPHeaderField:@"If-Match"];
  response = nil;
  [NSURLConnection sendSynchronousRequest:patch returningResponse:(NSURLResponse **)&response error:NULL];
#pragma clang diagnostic pop
  return response.statusCode / 100 == 2;
}

static NSManagedObject *personNamed(NSManagedObjectContext *moc, NSString *userName, NSError **error)
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Person"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"userName == %@", userName];
  return [[moc executeFetchRequest:fetch error:error] firstObject];
}

static void tripPin(NSString *models)
{
  fprintf(stderr, "== TripPin (write)\n");
  NSURL *root = tripPinSession();
  check(root != nil, @"start a TripPin session", root.absoluteString);
  if (!root) return;
  NSPersistentStoreCoordinator *psc = openStore([models stringByAppendingPathComponent:@"TripPin.momd"], root);
  if (!psc) return;
  NSString *userName = [NSString stringWithFormat:@"ois%u", (unsigned)(arc4random() % 1000000)];

  // The model leaves Person's key and entity set to $metadata.
  ODataIncrementalStore *store = psc.persistentStores.firstObject;
  NSEntityDescription *personEntity = psc.managedObjectModel.entitiesByName[@"Person"];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = store.schema;
  check(store.schema && !store.metadataProblems.count && [[mapper entitySetForEntity:personEntity] isEqualToString:@"People"] &&
            [[[mapper keyAttributesForEntity:personEntity] valueForKey:@"name"] isEqual:@[ @"userName" ]],
        @"take the key, the entity set and the types from $metadata",
        store.metadataProblems.count ? [store.metadataProblems componentsJoinedByString:@"; "] : [mapper entitySetForEntity:personEntity]);

  NSManagedObjectContext *moc = newContext(psc);
  [moc performBlockAndWait:^{
    NSError *e = nil;
    NSManagedObject *person = [NSEntityDescription insertNewObjectForEntityForName:@"Person" inManagedObjectContext:moc];
    [person setValue:userName forKey:@"userName"];
    [person setValue:@"Ois" forKey:@"firstName"];
    [person setValue:@"Live" forKey:@"lastName"];
    BOOL saved = [moc save:&e];
    check(saved && !person.objectID.isTemporaryID, @"insert with a client-chosen key (POST)", reason(e) ?: userName);
    if (!saved) return;

    // Concurrency is an Int64 past 2^53: the store's value has to be the
    // service's, digit for digit.
    NSURL *raw = [NSURL URLWithString:[NSString stringWithFormat:@"People('%@')?$select=Concurrency", userName] relativeToURL:root];
    NSMutableURLRequest *get = [NSMutableURLRequest requestWithURL:raw];
    [get setValue:@"application/json;IEEE754Compatible=true" forHTTPHeaderField:@"Accept"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *body = [NSURLConnection sendSynchronousRequest:get returningResponse:NULL error:NULL];
#pragma clang diagnostic pop
    NSString *digits = body ? [[NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] objectForKey:@"Concurrency"] : nil;
    NSManagedObjectContext *fetched = newContext(psc);
    __block NSNumber *concurrency = nil;
    [fetched performBlockAndWait:^{ concurrency = [personNamed(fetched, userName, NULL) valueForKey:@"concurrency"]; }];
    check(digits.length && [[NSString stringWithFormat:@"%lld", concurrency.longLongValue] isEqualToString:digits],
          @"Int64 keeps every digit (IEEE754Compatible)", [NSString stringWithFormat:@"%@ vs %@", concurrency, digits]);

    // Two updates in a row: the second has to send the ETag the first
    // came back with.
    e = nil;
    [person setValue:@"Ois2" forKey:@"firstName"];
    BOOL first = [moc save:&e];
    [person setValue:@"Ois3" forKey:@"firstName"];
    BOOL second = first && [moc save:&e];
    NSManagedObjectContext *check1 = newContext(psc);
    __block NSString *firstName = nil;
    [check1 performBlockAndWait:^{ firstName = [personNamed(check1, userName, NULL) valueForKey:@"firstName"]; }];
    check(second && [firstName isEqualToString:@"Ois3"], @"update twice, each with the current ETag (PATCH, If-Match)",
          reason(e) ?: firstName);

    e = nil;
    NSFetchRequest *photos = [NSFetchRequest fetchRequestWithEntityName:@"Photo"];
    photos.fetchLimit = 1;
    NSManagedObject *photo = [[moc executeFetchRequest:photos error:&e] firstObject];
    [person setValue:photo forKey:@"photo"];
    BOOL bound = photo && [moc save:&e];
    NSManagedObjectContext *check2 = newContext(psc);
    __block id photoID = nil;
    [check2 performBlockAndWait:^{ photoID = [[personNamed(check2, userName, NULL) valueForKey:@"photo"] valueForKey:@"id"]; }];
    check(bound && [photoID isEqual:[photo valueForKey:@"id"]], @"change a to-one relationship (PUT $ref)",
          reason(e) ?: [NSString stringWithFormat:@"photo %@", photoID]);

    e = nil;
    NSManagedObject *russell = personNamed(moc, @"russellwhyte", &e);
    [[person mutableSetValueForKey:@"friends"] addObject:russell];
    BOOL added = russell && [moc save:&e];
    NSManagedObjectContext *check3 = newContext(psc);
    __block NSUInteger friends = NSNotFound;
    [check3 performBlockAndWait:^{ friends = [[personNamed(check3, userName, NULL) valueForKey:@"friends"] count]; }];
    check(added && friends == 1, @"add to a to-many relationship (POST $ref)",
          reason(e) ?: [NSString stringWithFormat:@"%lu friends", (unsigned long)friends]);

    e = nil;
    [[person mutableSetValueForKey:@"friends"] removeObject:russell];
    BOOL removed = [moc save:&e];
    NSManagedObjectContext *check4 = newContext(psc);
    [check4 performBlockAndWait:^{ friends = [[personNamed(check4, userName, NULL) valueForKey:@"friends"] count]; }];
    check(removed && friends == 0, @"remove from a to-many relationship (DELETE $ref)",
          reason(e) ?: [NSString stringWithFormat:@"%lu friends", (unsigned long)friends]);

    // One save, two requests (a PATCH and a POST $ref): one $batch change
    // set, and both take effect.
    e = nil;
    [person setValue:@"Batched" forKey:@"lastName"];
    [[person mutableSetValueForKey:@"friends"] addObject:russell];
    BOOL batched = [moc save:&e];
    NSManagedObjectContext *check5 = newContext(psc);
    __block NSString *lastName = nil;
    [check5 performBlockAndWait:^{
      NSManagedObject *again = personNamed(check5, userName, NULL);
      lastName = [again valueForKey:@"lastName"];
      friends = [[again valueForKey:@"friends"] count];
    }];
    check(batched && [lastName isEqualToString:@"Batched"] && friends == 1, @"a save of several requests is one change set ($batch)",
          reason(e) ?: [NSString stringWithFormat:@"%@, %lu friends", lastName, (unsigned long)friends]);

    // Gender is an enumeration: read as its member name, and filtered on
    // with the qualified literal OData 4.0 requires.
    e = nil;
    NSString *russellsGender = [russell valueForKey:@"gender"];
    NSFetchRequest *women = [NSFetchRequest fetchRequestWithEntityName:@"Person"];
    women.predicate = [NSPredicate predicateWithFormat:@"gender == %@", @"Female"];
    NSArray *found = [moc executeFetchRequest:women error:&e];
    BOOL allWomen = found.count > 0;
    for (NSManagedObject *woman in found) allWomen = allWomen && [[woman valueForKey:@"gender"] isEqual:@"Female"];
    check([russellsGender isEqualToString:@"Male"] && allWomen, @"read and filter an enumeration (Gender eq NS.PersonGender'Female')",
          e ? reason(e) : [NSString stringWithFormat:@"Russell is %@; %lu women", russellsGender, (unsigned long)found.count]);

    // Someone else changes the person; saving over it has to fail.
    e = nil;
    BOOL elsewhere = changeBehindTheStoresBack(root, userName);
    [person setValue:@"Stale" forKey:@"firstName"];
    BOOL overwrote = [moc save:&e];
    NSError *cause = e.userInfo[NSUnderlyingErrorKey] ?: OISDetailedErrors(e).firstObject ?: e;
    check(elsewhere && !overwrote && cause.code == ODataIncrementalStoreErrorOptimisticLocking, @"a stale ETag is refused (412)",
          overwrote ? @"the save went through" : reason(e));
    [moc rollback];

    e = nil;
    [moc refreshObject:person mergeChanges:NO];
    NSManagedObject *fresh = personNamed(moc, userName, &e);
    if (fresh) [moc deleteObject:fresh];
    BOOL deleted = fresh && [moc save:&e];
    NSManagedObjectContext *check6 = newContext(psc);
    __block NSManagedObject *gone = nil;
    [check6 performBlockAndWait:^{ gone = personNamed(check6, userName, NULL); }];
    check(deleted && !gone, @"delete with the current ETag (DELETE)", reason(e));
  }];
}

// Receives a call made without waiting.
@interface OISLiveCallTarget : NSObject
@property (atomic, strong) ODataOperationCall *finished;
@property (atomic) BOOL onContextQueue;
@end

@implementation OISLiveCallTarget
- (void)callFinished:(ODataOperationCall *)call
{
  self.onContextQueue = ![NSThread isMainThread];
  self.finished = call;
}
@end

static void operations(void)
{
  fprintf(stderr, "== Actions and functions\n");
  NSError *error = nil;
  NSURL *tripPin = tripPinSession();
  NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:tripPin options:nil error:&error];
  NSPersistentStoreCoordinator *psc = model ? [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model] : nil;
  if (![psc addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:tripPin options:nil error:&error]) {
    check(NO, @"open TripPin with its own model", reason(error));
    return;
  }
  NSManagedObjectContext *moc = newContext(psc);
  __block NSString *airline = nil, *airport = nil, *city = nil;
  __block id shared = nil;
  __block NSError *e1 = nil, *e2 = nil, *e3 = nil;
  [moc performBlockAndWait:^{
    NSManagedObject *russell = personNamed(moc, @"russellwhyte", NULL);
    NSError *e = nil;
    NSManagedObject *favorite = [russell invokeODataOperation:@"GetFavoriteAirline" parameters:nil error:&e];
    airline = [favorite valueForKey:@"name"];
    e1 = e;

    e = nil;
    ODataOperationCall *nearest = [ODataOperationCall callOfOperation:@"GetNearestAirport" inContext:moc];
    nearest.parameters = @{ @"lat": @33.94, @"lon": @-118.4 };
    NSManagedObject *found = [nearest invoke:&e];
    airport = [found valueForKey:@"icaoCode"];
    NSDictionary *location = [found valueForKey:@"location"];
    city = [location isKindOfClass:[NSDictionary class]] ? location[@"City"][@"Name"] : nil;
    e2 = e;

    e = nil;
    shared = [russell invokeODataOperation:@"ShareTrip" parameters:@{ @"userName": @"scottketchum", @"tripId": @0 } error:&e];
    e3 = e;
  }];
  check([airline isEqualToString:@"American Airlines"], @"a function bound to an entity, returning one (GetFavoriteAirline)",
        airline ?: reason(e1));
  check([airport isEqualToString:@"KLAX"] && [city isEqualToString:@"Los Angeles"], @"an imported function with parameters (GetNearestAirport)",
        airport ? [NSString stringWithFormat:@"%@, %@", airport, city] : reason(e2));
  check(shared == [NSNull null], @"an action bound to an entity, returning nothing (ShareTrip)", shared ? @"done" : reason(e3));

  OISLiveCallTarget *target = [[OISLiveCallTarget alloc] init];
  [moc performBlockAndWait:^{
    NSManagedObject *russell = personNamed(moc, @"russellwhyte", NULL);
    [[ODataOperationCall callOfOperation:@"GetFavoriteAirline" onObject:russell] invokeWithTarget:target action:@selector(callFinished:)];
  }];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
  while (!target.finished && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  __block NSString *later = nil;
  if (target.finished.result) {
    [moc performBlockAndWait:^{
      later = [target.finished.result valueForKey:@"name"];
    }];
  }
  check([later isEqualToString:@"American Airlines"] && target.onContextQueue, @"called without waiting: target-action, on the context's queue",
        later ?: (target.finished ? reason(target.finished.error) : @"no answer"));
}

static void remoteChanges(void)
{
  fprintf(stderr, "== Changes at the service (delta)\n");
  NSError *error = nil;
  NSURL *tripPin = tripPinSession();
  NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:tripPin options:nil error:&error];
  if (!model) {
    check(NO, @"TripPin's model", reason(error));
    return;
  }
  // Two clients of one session: one tracks People, the other changes them.
  NSDictionary *tracking = @{ NSPersistentHistoryTrackingKey: @YES, ODataIncrementalStoreTrackedEntitiesOption: @[ @"Person" ] };
  NSPersistentStoreCoordinator *watcher = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  ODataIncrementalStore *store = (ODataIncrementalStore *)[watcher addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                                                          URL:tripPin options:tracking error:&error];
  NSPersistentStoreCoordinator *other = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  BOOL opened = store && [other addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:tripPin options:nil error:&error];
  NSNotification *first = opened ? [store fetchRemoteChanges:&error] : nil;
  check(first && first.userInfo.count == 0, @"start tracking People (Prefer: odata.track-changes)", first ? @"" : reason(error));
  if (!first) return;

  NSManagedObjectContext *moc = newContext(other);
  __block NSError *saveError = nil;
  __block BOOL saved = NO;
  [moc performBlockAndWait:^{
    NSManagedObject *added = [NSEntityDescription insertNewObjectForEntityForName:@"Person" inManagedObjectContext:moc];
    [added setValue:@"oisdelta" forKey:@"userName"];
    [added setValue:@"Del" forKey:@"firstName"];
    [added setValue:@"Ta" forKey:@"lastName"];
    [added setValue:@[] forKey:@"emails"];
    [added setValue:@[] forKey:@"addressInfo"];
    [added setValue:@"Female" forKey:@"gender"];
    [added setValue:@0 forKey:@"concurrency"];
    NSManagedObject *gone = personNamed(moc, @"ronaldmundy", NULL);
    if (gone) [moc deleteObject:gone];
    NSError *e = nil;
    saved = gone && [moc save:&e];
    saveError = e;
  }];
  if (!saved) {
    check(NO, @"another client adds a person and deletes one", reason(saveError));
    return;
  }

  NSNotification *changes = [store fetchRemoteChanges:&error];
  NSMutableArray *added = [NSMutableArray array], *removed = [NSMutableArray array];
  for (NSManagedObjectID *oid in changes.userInfo[NSInsertedObjectIDsKey]) {
    [added addObject:[ODataResourceIdentifier identifierFromReference:[store referenceObjectForObjectID:oid]].path];
  }
  for (NSManagedObjectID *oid in changes.userInfo[NSDeletedObjectIDsKey]) {
    [removed addObject:[ODataResourceIdentifier identifierFromReference:[store referenceObjectForObjectID:oid]].path];
  }
  check([added containsObject:@"People('oisdelta')"] && [removed containsObject:@"People('ronaldmundy')"],
        @"another client's changes arrive: an insert and a delete",
        changes ? [NSString stringWithFormat:@"inserted %@; deleted %@", [added componentsJoinedByString:@","], [removed componentsJoinedByString:@","]]
                : reason(error));

  __block NSArray *history = nil;
  NSManagedObjectContext *watching = newContext(watcher);
  [watching performBlockAndWait:^{
    NSPersistentHistoryResult *result = (NSPersistentHistoryResult *)[watching executeRequest:[NSPersistentHistoryChangeRequest fetchHistoryAfterToken:nil] error:NULL];
    history = result.result;
  }];
  NSPersistentHistoryTransaction *transaction = history.lastObject;
  check(history.count == 1 && [transaction.author isEqualToString:ODataRemoteChangesAuthor] && transaction.changes.count == added.count + removed.count,
        @"they are a persistent history transaction", [NSString stringWithFormat:@"%lu transactions, %@", (unsigned long)history.count, transaction]);
}

static void modelsFromMetadata(NSString *models)
{
  fprintf(stderr, "== Models from $metadata\n");
  // A dynamic client: nothing known of TripPin until its $metadata is read.
  NSError *error = nil;
  NSURL *tripPin = tripPinSession();
  NSManagedObjectModel *dynamic = [ODataIncrementalStore modelForServiceAtURL:tripPin options:nil error:&error];
  NSPersistentStoreCoordinator *psc = dynamic ? [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:dynamic] : nil;
  ODataIncrementalStore *store = psc ? (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                                                   configuration:nil URL:tripPin options:nil error:&error] : nil;
  __block NSString *gender = nil;
  __block NSUInteger friends = 0;
  __block NSArray *emails = nil;
  __block NSString *city = nil;
  __block NSArray *found = nil;
  __block NSError *fetchError = nil;
  if (store) {
    NSManagedObjectContext *moc = newContext(psc);
    [moc performBlockAndWait:^{
      NSManagedObject *russell = personNamed(moc, @"russellwhyte", NULL);
      gender = [russell valueForKey:@"gender"];
      friends = [[russell valueForKey:@"friends"] count];
      emails = [russell valueForKey:@"emails"];
      NSArray *addresses = [russell valueForKey:@"addressInfo"];
      id first = [addresses isKindOfClass:[NSArray class]] ? addresses.firstObject : nil;
      city = [first isKindOfClass:[NSDictionary class]] ? first[@"City"][@"Name"] : nil;
      NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Person"];
      fetch.predicate = [NSPredicate predicateWithFormat:@"ANY emails == %@ AND ANY addressInfo.city.name == %@",
                                                         @"Russell@example.com", @"Boise"];
      found = [[moc executeFetchRequest:fetch error:&fetchError] valueForKey:@"userName"];
    }];
  }
  check(store && [gender isEqualToString:@"Male"] && friends > 0 && !store.metadataProblems.count,
        @"a dynamic client: TripPin's model built from its $metadata",
        store ? [NSString stringWithFormat:@"%lu entities; Russell is %@ with %lu friends", (unsigned long)dynamic.entities.count, gender, (unsigned long)friends]
              : reason(error));
  check([emails isKindOfClass:[NSArray class]] && [emails containsObject:@"Russell@example.com"] && [city isEqualToString:@"Boise"],
        @"complex values and collections: Russell's e-mail addresses and the city of his address",
        [NSString stringWithFormat:@"%@; %@", [emails isKindOfClass:[NSArray class]] ? [emails componentsJoinedByString:@", "] : emails, city]);
  check([found isEqual:@[ @"russellwhyte" ]], @"a filter through a collection and into complex values (any, City/Name)",
        found ? [found componentsJoinedByString:@","] : reason(fetchError));

  // Generated ahead of time: ois-model wrote it, momc compiled it.
  NSString *generatedPath = [models stringByAppendingPathComponent:@"NorthwindGenerated.momd"];
  NSManagedObjectModel *generated = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:generatedPath]];
  if (!generated) {
    check(NO, @"a generated model (ois-model, momc) opens against the service", [@"no model at " stringByAppendingString:generatedPath]);
    return;
  }
  NSURL *northwind = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
  error = nil;
  NSDictionary *metadata = [ODataIncrementalStore metadataForServiceAtURL:northwind options:nil error:&error];
  BOOL matches = metadata && [generated isConfiguration:nil compatibleWithStoreMetadata:metadata];
  psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:generated];
  store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                               URL:northwind options:nil error:&error];
  __block NSUInteger products = 0;
  __block NSString *chai = nil;
  if (store) {
    NSManagedObjectContext *moc = newContext(psc);
    [moc performBlockAndWait:^{
      products = [moc countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Product"] error:NULL];
      NSFetchRequest *first = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      first.predicate = [NSPredicate predicateWithFormat:@"productID == 1"];
      chai = [[[moc executeFetchRequest:first error:NULL] firstObject] valueForKey:@"productName"];
    }];
  }
  check(matches && store && products == 77 && [chai isEqualToString:@"Chai"],
        @"a generated model (ois-model, momc) is the service's version, and opens",
        store ? [NSString stringWithFormat:@"%@; %lu products, the first %@", matches ? @"versions match" : @"versions differ", (unsigned long)products, chai]
              : reason(error));
}

static void streamsAndSearch(void)
{
  fprintf(stderr, "== Streams and $search\n");
  NSError *error = nil;
  NSURL *tripPin = tripPinSession();
  NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:tripPin options:nil error:&error];
  NSPersistentStoreCoordinator *psc = model ? [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model] : nil;
  NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  NSDictionary *options = @{ ODataIncrementalStoreStreamDirectoryOption: [NSURL fileURLWithPath:directory] };
  if (![psc addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:tripPin options:options error:&error]) {
    check(NO, @"open TripPin with its own model", reason(error));
    return;
  }
  NSManagedObjectContext *moc = newContext(psc);
  [moc performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Photo"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
    NSError *e = nil;
    NSManagedObject *photo = [[moc executeFetchRequest:fetch error:&e] firstObject];

    // A media entity's resource ($value), into a file.
    ODataStreamTransfer *transfer = photo ? [[ODataStreamTransfer alloc] initWithObject:photo stream:nil] : nil;
    NSURL *file = [transfer download:&e];
    NSData *bytes = file ? [NSData dataWithContentsOfURL:file] : nil;
    BOOL jpeg = bytes.length > 2 && ((const uint8_t *)bytes.bytes)[0] == 0xFF && ((const uint8_t *)bytes.bytes)[1] == 0xD8;
    check(jpeg && [transfer.contentType isEqualToString:@"image/jpeg"] && transfer.mediaETag.length,
          @"download a media entity's stream (Photos(1)/$value)",
          file ? [NSString stringWithFormat:@"%lu bytes, %@, %@", (unsigned long)bytes.length, transfer.contentType, transfer.mediaETag] : reason(e));
    if (!jpeg) return;

    // Up again, with its media ETag (TripPin wants one: 428 without).
    NSString *before = transfer.mediaETag;
    e = nil;
    BOOL uploaded = [transfer uploadFile:file contentType:@"image/jpeg" error:&e];
    check(uploaded && transfer.mediaETag.length && ![transfer.mediaETag isEqualToString:before],
          @"upload a media entity's stream (PUT $value, If-Match)",
          uploaded ? [NSString stringWithFormat:@"%@ -> %@", before, transfer.mediaETag] : reason(e));

    // A new media entity from a file (POST to the set), then named.
    ODataStreamTransfer *create = [[ODataStreamTransfer alloc] initWithEntityName:@"Photo" context:moc];
    e = nil;
    BOOL created = [create uploadFile:file contentType:@"image/jpeg" error:&e];
    NSManagedObject *added = create.object;
    [added setValue:@"From ois-live" forKey:@"name"];
    BOOL named = created && [moc save:&e];
    NSFetchRequest *again = [NSFetchRequest fetchRequestWithEntityName:@"Photo"];
    again.predicate = [NSPredicate predicateWithFormat:@"name == 'From ois-live'"];
    NSArray *found = named ? [moc executeFetchRequest:again error:&e] : nil;
    check(created && named && found.count == 1 && !added.objectID.isTemporaryID,
          @"create a media entity from a file (POST Photos), then set its name",
          created ? [NSString stringWithFormat:@"%@, %lu found", [added valueForKey:@"id"], (unsigned long)found.count] : reason(e));
  }];

  [moc performBlockAndWait:^{
    // $search, alone and beside a $filter.
    NSError *e = nil;
    NSFetchRequest *people = [NSFetchRequest fetchRequestWithEntityName:@"Person"];
    people.predicate = [ODataSearchPredicate predicateWithSearch:@"Russell"];
    NSArray *russells = [moc executeFetchRequest:people error:&e];
    check([[russells valueForKey:@"userName"] isEqual:@[ @"russellwhyte" ]], @"$search (People?$search=Russell)", describe([russells valueForKey:@"userName"], e));

    e = nil;
    NSFetchRequest *airports = [NSFetchRequest fetchRequestWithEntityName:@"Airport"];
    airports.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
      [ODataSearchPredicate predicateWithSearch:@"Los"], [NSPredicate predicateWithFormat:@"icaoCode BEGINSWITH 'K'"] ]];
    NSArray *found = [moc executeFetchRequest:airports error:&e];
    check([[found valueForKey:@"icaoCode"] isEqual:@[ @"KLAX" ]], @"$search beside $filter (Airports?$search=Los&$filter=startswith(IcaoCode,'K'))",
          describe([found valueForKey:@"icaoCode"], e));
  }];
  [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSString *models = argc > 1 ? @(argv[1]) : @".";
    [ODataIncrementalStore registerStore];
    northwind(models);
    northwindTypes(models);
    tripPin(models);
    modelsFromMetadata(models);
    operations();
    remoteChanges();
    streamsAndSearch();
    fprintf(stderr, "%s\n", failures ? "ois-live: FAILED" : "ois-live: all checks passed");
    return failures ? 1 : 0;
  }
}
