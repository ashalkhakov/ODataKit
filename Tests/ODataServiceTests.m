// The server's core: ODataService over the Catalog model in memory.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData 4.01 Part 1 (Protocol) section 11 (data service requests),
// Part 2 (URL Conventions), JSON Format; and the round trip: the client's
// ODataIncrementalStore talking to the service in-process, with the
// service as its transport.

#import <XCTest/XCTest.h>
#import <OTelKit/OTelKit.h>
#import "OISCatalogModel.h"
#import "OISJWTFixtures.h"

@interface OISServiceResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic, copy) NSData *data;
@property (nonatomic, readonly) id json;
@property (nonatomic, readonly) NSString *text;
- (NSString *)header:(NSString *)name;
@end

@implementation OISServiceResponse
- (id)json
{
  return self.data.length ? [NSJSONSerialization JSONObjectWithData:self.data options:0 error:NULL] : nil;
}
- (NSString *)text
{
  return [[NSString alloc] initWithData:self.data ?: [NSData data] encoding:NSUTF8StringEncoding];
}
- (NSString *)header:(NSString *)name
{
  for (NSString *key in self.headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return self.headers[key];
  }
  return nil;
}
@end

// Changes of its own, not the store's history: a feed whose tokens are
// feed-1, feed-2, ...; from feed-1, Chai and Chang changed and Products(99)
// was deleted, told later, as a feed that is asked would.
@interface OISFeedProducts : ODataEntitySetHandler
@end

@implementation OISFeedProducts

- (BOOL)canTrackChanges
{
  return YES;
}

- (NSString *)changeTokenForRequest:(ODataRequest *)request
{
  return @"feed-1";
}

- (ODataChanges *)changesSince:(NSString *)token request:(ODataRequest *)request reply:(ODataReply *)reply
{
  if (![token hasPrefix:@"feed-"]) {
    [reply failWithError:ODataServiceError(400, @"Not a token of the feed")];
    return nil;
  }
  [reply defer];
  NSManagedObjectContext *context = request.context;
  NSEntityDescription *entity = self.entity;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [context performBlock:^{
      ODataChanges *changes = [ODataChanges changesWithToken:@"feed-2"];
      if ([token isEqualToString:@"feed-1"]) {
        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
        fetch.predicate = [NSPredicate predicateWithFormat:@"id IN %@", @[ @1, @2 ]];
        fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
        for (NSManagedObject *product in [context executeFetchRequest:fetch error:NULL]) [changes addChanged:product.objectID];
        [changes addDeletedEntity:entity keyValues:@{ @"id": @99 }];
      }
      [reply finishWithResult:changes];
    }];
  });
  return nil;
}

@end

// Hides discontinued products, and answers fetches later, from another
// thread, as a handler that waits on something would.
@interface OISLaterProducts : ODataEntitySetHandler
@property (nonatomic) NSInteger deferred;
@end

@implementation OISLaterProducts

- (NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request
{
  return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"discontinued"]
                                            rightExpression:[NSExpression expressionForConstantValue:@NO]
                                                   modifier:NSDirectPredicateModifier
                                                       type:NSEqualToPredicateOperatorType
                                                    options:0];
}

- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [reply defer];
  self.deferred++;
  NSManagedObjectContext *context = request.context;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [context performBlock:^{
      NSError *error = nil;
      NSArray *rows = [context executeFetchRequest:fetchRequest error:&error];
      if (rows) [reply finishWithResult:rows];
      else [reply failWithError:error];
    }];
  });
  return nil;
}

@end

// Writes later, from another thread, as a handler that asks elsewhere
// first would: inserts, updates and deletes.
@interface OISLaterWrites : ODataEntitySetHandler
@property (nonatomic) NSInteger inserts, updates, deletes;
@end

@implementation OISLaterWrites

- (void)later:(ODataReply *)reply context:(NSManagedObjectContext *)context work:(id (^)(void))work
{
  [reply defer];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [context performBlock:^{
      [reply finishWithResult:work()];
    }];
  });
}

- (NSManagedObject *)insertObjectWithValues:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  self.inserts++;
  [self later:reply context:request.context work:^id {
    return [super insertObjectWithValues:values request:request reply:reply];
  }];
  return nil;
}

- (NSManagedObject *)updateObject:(NSManagedObject *)object values:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  self.updates++;
  [self later:reply context:request.context work:^id {
    return [super updateObject:object values:values request:request reply:reply];
  }];
  return nil;
}

- (void)deleteObject:(NSManagedObject *)object request:(ODataRequest *)request reply:(ODataReply *)reply
{
  self.deletes++;
  [self later:reply context:request.context work:^id {
    [request.context deleteObject:object];
    return nil;
  }];
}

@end

#pragma mark Operations, declared in protocols

@class OISServedProduct;

@protocol OISProductFunctions <ODataFunctions>
- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply;
- (OISServedProduct *)cheapestInCategory:(ODataReply *)reply;
+ (NSArray *)pricierThanPrice:(double)price reply:(ODataReply *)reply;
@end

@protocol OISProductActions <ODataActions>
- (void)raisePriceByPercent:(double)percent reply:(ODataReply *)reply;
- (NSDecimalNumber *)discontinueWithReason:(NSString *)reason reply:(ODataReply *)reply;
@end

@interface OISServedProduct : NSManagedObject <OISProductFunctions, OISProductActions>
@end

@implementation OISServedProduct

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"pricierThanPrice:reply:": @"Collection(Default.Product)" };
}

- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply
{
  NSDecimalNumber *factor = [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)(100 - percent) exponent:-2 isNegative:NO];
  return [[self valueForKey:@"unitPrice"] decimalNumberByMultiplyingBy:factor];
}

- (OISServedProduct *)cheapestInCategory:(ODataReply *)reply
{
  NSArray *siblings = [[self valueForKeyPath:@"category.products"] allObjects];
  return [siblings sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"unitPrice" ascending:YES] ]].firstObject;
}

// Bound to the collection it is called on: all of Products, or a
// category's.
+ (NSArray *)pricierThanPrice:(double)price reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [reply.request.collectionFetchRequest copy];
  NSPredicate *pricier = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"unitPrice"]
                                                            rightExpression:[NSExpression expressionForConstantValue:@(price)]
                                                                   modifier:NSDirectPredicateModifier
                                                                       type:NSGreaterThanPredicateOperatorType
                                                                    options:0];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[ fetch.predicate, pricier ]];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  NSError *error = nil;
  NSArray *rows = [reply.request.context executeFetchRequest:fetch error:&error];
  if (!rows) [reply failWithError:error];
  return rows;
}

- (void)raisePriceByPercent:(double)percent reply:(ODataReply *)reply
{
  NSDecimalNumber *factor = [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)(100 + percent) exponent:-2 isNegative:NO];
  [self setValue:[[self valueForKey:@"unitPrice"] decimalNumberByMultiplyingBy:factor] forKey:@"unitPrice"];
}

// Answers later, from another thread, through the request's context.
- (NSDecimalNumber *)discontinueWithReason:(NSString *)reason reply:(ODataReply *)reply
{
  [reply defer];
  NSManagedObjectContext *context = reply.request.context;
  NSManagedObjectID *objectID = self.objectID;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [context performBlock:^{
      NSManagedObject *product = [context objectWithID:objectID];
      if ([reason length] == 0) {
        [reply failWithError:ODataServiceError(400, @"Say why")];
        return;
      }
      [product setValue:@YES forKey:@"discontinued"];
      [reply finishWithResult:[product valueForKey:@"unitPrice"]];
    }];
  });
  return nil;
}

@end

// What is current while an operation runs: its call's span. An engine of
// the application's own traces under it, now or (with reply.span) later on
// another thread.
@protocol OISTracedFunctions <ODataFunctions>
- (NSString *)currentSpan:(ODataReply *)reply;
- (NSString *)engineStep:(ODataReply *)reply;
- (NSString *)later:(ODataReply *)reply;
- (NSString *)never:(ODataReply *)reply;
@end

@protocol OISTracedActions <ODataActions>
- (NSString *)stepForProduct:(OISServedProduct *)product reply:(ODataReply *)reply;
@end

@interface OISTracedOperations : NSObject <OISTracedFunctions, OISTracedActions>
@end

@implementation OISTracedOperations

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"stepForProduct:reply:.product": @"Default.Product" };
}

- (NSString *)currentSpan:(ODataReply *)reply
{
  OTSpan *span = [OTSpan currentSpan];
  return span ? [NSString stringWithFormat:@"%@ %@", span.name, span.context.spanID] : @"";
}

- (NSString *)engineStep:(ODataReply *)reply
{
  [[[OTTracer tracerNamed:@"Engine" version:nil] startSpanNamed:@"engine step" attributes:nil] end];
  return @"stepped";
}

- (NSString *)later:(ODataReply *)reply
{
  [reply defer];
  OTSpan *call = reply.span;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
    [call becomeCurrent];
    [[[OTTracer tracerNamed:@"Engine" version:nil] startSpanNamed:@"later step" attributes:nil] end];
    [call resignCurrent];
    [reply finishWithResult:@"later"];
  });
  return nil;
}

- (NSString *)never:(ODataReply *)reply
{
  [reply defer];
  return nil;
}

- (NSString *)stepForProduct:(OISServedProduct *)product reply:(ODataReply *)reply
{
  [[[OTTracer tracerNamed:@"Engine" version:nil] startSpanNamed:@"product step" attributes:nil] end];
  // A change, which the service saves for it.
  NSString *name = [product valueForKey:@"name"];
  [product setValue:[name stringByAppendingString:@" (stepped)"] forKey:@"name"];
  return name;
}

@end

// Samples only a trace that an engine step begins: one that is not under
// the request, which should never happen.
@interface OISEngineOnlySampler : NSObject <OTSampler>
@end

@implementation OISEngineOnlySampler
- (BOOL)shouldSampleTraceID:(NSString *)traceID parent:(OTSpanContext *)parent name:(NSString *)name kind:(OTSpanKind)kind
{
  if (parent) return parent.sampled;
  return [name hasSuffix:@" step"];
}
@end

@protocol OISCatalogFunctions <ODataFunctions>
- (int32_t)countProductsCheaperThanPrice:(double)price reply:(ODataReply *)reply;
- (NSString *)echoWithText:(NSString *)text times:(int32_t)times reply:(ODataReply *)reply;
- (NSDecimalNumber *)sumOfPrices:(NSArray *)prices reply:(ODataReply *)reply;
- (NSArray *)namesInCategory:(ODataReply *)reply;
- (NSDictionary *)describeShape:(id)shape reply:(ODataReply *)reply;
@end

@protocol OISCatalogActions <ODataActions>
- (void)failWithCode:(int32_t)code reply:(ODataReply *)reply;
- (NSDictionary *)mergeWithBase:(NSDictionary *)base changes:(NSArray *)changes reply:(ODataReply *)reply;
@end

@interface OISCatalogOperations : NSObject <OISCatalogFunctions, OISCatalogActions>
@end

@implementation OISCatalogOperations

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"sumOfPrices:reply:.prices": @"Collection(Edm.Decimal)",
            @"namesInCategory:": @"Collection(Edm.String)",
            @"describeShape:reply:.shape": @"Edm.Untyped",
            @"mergeWithBase:changes:reply:.changes": @"Collection(Org.OData.JSON.V1.JSON)" };
}

+ (NSDictionary *)ODataOperationNames
{
  return @{ @"namesInCategory:": @"ProductNames" };
}

- (int32_t)countProductsCheaperThanPrice:(double)price reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"unitPrice"]
                                                       rightExpression:[NSExpression expressionForConstantValue:@(price)]
                                                              modifier:NSDirectPredicateModifier
                                                                  type:NSLessThanPredicateOperatorType
                                                               options:0];
  return (int32_t)[reply.request.context countForFetchRequest:fetch error:NULL];
}

- (NSString *)echoWithText:(NSString *)text times:(int32_t)times reply:(ODataReply *)reply
{
  NSMutableString *echo = [NSMutableString string];
  for (int32_t i = 0; i < times; i++) [echo appendString:text ?: @"?"];
  return echo;
}

- (NSDecimalNumber *)sumOfPrices:(NSArray *)prices reply:(ODataReply *)reply
{
  NSDecimalNumber *sum = [NSDecimalNumber zero];
  for (NSDecimalNumber *price in prices) sum = [sum decimalNumberByAdding:price];
  return sum;
}

- (NSArray *)namesInCategory:(ODataReply *)reply
{
  return @[ @"Chai", @"Chang" ];
}

- (void)failWithCode:(int32_t)code reply:(ODataReply *)reply
{
  [reply failWithError:ODataServiceError(code, @"Failing on purpose")];
}

- (NSDictionary *)describeShape:(id)shape reply:(ODataReply *)reply
{
  return @{ @"class": [shape isKindOfClass:[NSDictionary class]] ? @"object" : [shape isKindOfClass:[NSArray class]] ? @"array" : @"scalar",
            @"shape": shape ?: [NSNull null] };
}

- (NSDictionary *)mergeWithBase:(NSDictionary *)base changes:(NSArray *)changes reply:(ODataReply *)reply
{
  NSMutableDictionary *merged = [base mutableCopy] ?: [NSMutableDictionary dictionary];
  for (NSDictionary *change in changes) [merged addEntriesFromDictionary:change];
  return merged;
}

@end

// Declarations the service cannot use, each for its own reason.
@protocol OISBadFunctions <ODataFunctions>
- (NSNumber *)mystery:(ODataReply *)reply;
- (NSString *)noReply;
- (void)nothing:(ODataReply *)reply;
@end

@interface OISBadOperations : NSObject <OISBadFunctions>
@end

@implementation OISBadOperations
- (NSNumber *)mystery:(ODataReply *)reply { return @1; }
- (NSString *)noReply { return @""; }
- (void)nothing:(ODataReply *)reply {}
@end

// Defers, and never answers.
@interface OISSilentProducts : ODataEntitySetHandler
@end

@implementation OISSilentProducts
- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [reply defer];
  return nil;
}
@end

// Products for whoever asks: an admin sees them all, anyone else only
// those still sold. It remembers who asked.
@interface OISScopedProducts : ODataEntitySetHandler
@property (atomic, strong) HSPrincipal *lastPrincipal;
@end

@implementation OISScopedProducts
- (NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request
{
  self.lastPrincipal = request.principal;
  if ([request.principal.claims[@"groups"] containsObject:@"admin"]) return nil;
  return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"discontinued"]
                                            rightExpression:[NSExpression expressionForConstantValue:@NO]
                                                   modifier:NSDirectPredicateModifier
                                                       type:NSEqualToPredicateOperatorType
                                                    options:0];
}
@end

// What a caller may see has a version, as X-Scope says: their delta links
// hold only while it does.
@interface OISScopeVersionedProducts : ODataEntitySetHandler
@end

@implementation OISScopeVersionedProducts
- (NSString *)scopeVersionForRequest:(ODataRequest *)request
{
  return [request valueForHeader:@"X-Scope"];
}
@end

// Visible by a relationship: nothing a deleted row's tombstone keeps.
@interface OISBeveragesOnly : ODataEntitySetHandler
@end

@implementation OISBeveragesOnly
- (NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request
{
  return [NSPredicate predicateWithFormat:@"category.name == 'Beverages'"];
}
@end

// Everyone is someone: X-Scopes (or the bearer token itself) is what they
// may do, as a token's scope claim has it.
@interface OISScopeAuthenticator : NSObject <HSAuthenticator>
@end

@implementation OISScopeAuthenticator
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  NSString *bearer = [request valueForHeader:@"Authorization"];
  bearer = [bearer hasPrefix:@"Bearer "] ? [bearer substringFromIndex:7] : nil;
  NSString *scopes = [request valueForHeader:@"X-Scopes"] ?: bearer ?: @"";
  [reply finishWithPrincipal:[[HSPrincipal alloc] initWithSubject:@"someone" claims:@{ @"scope": scopes }]];
}

- (NSDictionary *)authorizationDescription
{
  return @{ @"@type": @"Org.OData.Authorization.V1.OpenIDConnect", @"Name": @"Provider",
            @"IssuerUrl": @"https://id.example.test/" };
}
@end

@protocol OISScopedActions <ODataActions>
- (int32_t)tallyWithAmount:(int32_t)amount reply:(ODataReply *)reply;
- (NSArray *)restock:(ODataReply *)reply;
- (NSManagedObject *)favourite:(ODataReply *)reply;
@end

@protocol OISScopedFunctions <ODataFunctions>
- (NSArray *)bargains:(ODataReply *)reply;
@end

// Operations that need a permission of their own; three answer with
// products, and count their calls.
@interface OISScopedOperations : NSObject <OISScopedActions, OISScopedFunctions>
@property (nonatomic) NSInteger calls;
@end

@implementation OISScopedOperations
+ (NSDictionary *)ODataOperationScopes
{
  return @{ @"tallyWithAmount:reply:": @[ @"Tally.Run", @"Tally.Admin" ],
            @"restock:": @"Stock.Keep",
            @"favourite:": [NSSet setWithObject:@"Stock.Keep"],
            @"bargains:": @"Stock.Keep" };
}

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"restock:": @"Collection(Default.Product)", @"favourite:": @"Default.Product", @"bargains:": @"Collection(Default.Product)" };
}

- (NSArray *)bargains:(ODataReply *)reply
{
  return [[self productsIn:reply] subarrayWithRange:NSMakeRange(0, 3)];
}

- (int32_t)tallyWithAmount:(int32_t)amount reply:(ODataReply *)reply
{
  return amount + 1;
}

- (NSArray *)productsIn:(ODataReply *)reply
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
  return [reply.request.context executeFetchRequest:fetch error:NULL];
}

- (NSArray *)restock:(ODataReply *)reply
{
  self.calls++;
  return [[self productsIn:reply] subarrayWithRange:NSMakeRange(0, 2)];
}

- (NSManagedObject *)favourite:(ODataReply *)reply
{
  self.calls++;
  return [self productsIn:reply].firstObject;
}
@end

// Scopes that name no scope, or no operation: each would leave one open.
@protocol OISMisscopedActions <ODataActions>
- (int32_t)countWithAmount:(int32_t)amount reply:(ODataReply *)reply;
- (int32_t)measureWithAmount:(int32_t)amount reply:(ODataReply *)reply;
@end

@interface OISMisscopedOperations : NSObject <OISMisscopedActions>
@end

@implementation OISMisscopedOperations
+ (NSDictionary *)ODataOperationScopes
{
  return @{ @"countWithAmount:reply:": @[ @"" ], @"measureWithAmount:reply:": @[ @"Measure.Run" ], @"mesureWithAmount:reply:": @"Measure.Run" };
}

- (int32_t)countWithAmount:(int32_t)amount reply:(ODataReply *)reply
{
  return amount;
}

- (int32_t)measureWithAmount:(int32_t)amount reply:(ODataReply *)reply
{
  return amount;
}
@end

@protocol OISScopedProductActions <ODataActions>
- (void)raisePriceByPercent:(double)percent reply:(ODataReply *)reply;
@end

// A bound action that needs a permission.
@interface OISScopedProduct : NSManagedObject <OISScopedProductActions>
@end

@implementation OISScopedProduct
+ (NSDictionary *)ODataOperationScopes
{
  return @{ @"raisePriceByPercent:reply:": @[ @"Prices.Raise" ] };
}

- (void)raisePriceByPercent:(double)percent reply:(ODataReply *)reply
{
  NSDecimalNumber *factor = [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)(100 + percent) exponent:-2 isNegative:NO];
  [self setValue:[[self valueForKey:@"unitPrice"] decimalNumberByMultiplyingBy:factor] forKey:@"unitPrice"];
}
@end

// Asks elsewhere, and answers later: Authorization: Token <name> is <name>,
// Token banned is refused.
@interface OISLaterAuthenticator : NSObject <HSAuthenticator>
@end

@implementation OISLaterAuthenticator
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  NSString *authorization = [request valueForHeader:@"Authorization"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
    if (![authorization hasPrefix:@"Token "]) {
      [reply finishWithPrincipal:nil];
    } else if ([authorization isEqualToString:@"Token banned"]) {
      [reply failWithError:HSError(403, @"Banned")];
    } else {
      [reply finishWithPrincipal:[[HSPrincipal alloc] initWithSubject:[authorization substringFromIndex:6] claims:nil]];
    }
  });
}

- (NSString *)challengeForRequest:(HSRequest *)request
{
  return @"Token realm=\"example\"";
}
@end

// An identity provider: JSON by URL, and introspection by token, answered
// later on another thread, as NSURLSession does.
@interface OISFakeIdentityProvider : NSObject <HSFetching>
@property (atomic, copy) NSDictionary<NSString *, id> *documents;       // URL -> JSON
@property (atomic, copy) NSDictionary<NSString *, id> *introspections;  // token -> JSON
@property (atomic, copy) NSString *credentials;                         // Basic ...
@property (atomic) NSInteger requests;
@end

@implementation OISFakeIdentityProvider
- (void)startFetch:(HSFetch *)fetch
{
  self.requests++;
  NSURLRequest *request = fetch.request;
  id json = nil;
  NSInteger status = 404;
  if ([request.HTTPMethod isEqualToString:@"POST"]) {
    NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
    NSString *token = nil;
    for (NSString *pair in [body componentsSeparatedByString:@"&"]) {
      if ([pair hasPrefix:@"token="]) token = [[pair substringFromIndex:6] stringByRemovingPercentEncoding];
    }
    if (![[request valueForHTTPHeaderField:@"Authorization"] isEqualToString:self.credentials]) {
      status = 401;
    } else if (token) {
      json = self.introspections[token] ?: @{ @"active": @NO };
      status = 200;
    }
  } else {
    json = self.documents[request.URL.absoluteString];
    if (json) status = 200;
  }
  dispatch_async(dispatch_get_global_queue(0, 0), ^{
    fetch.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1"
                                               headerFields:@{ @"Content-Type": @"application/json" }];
    fetch.data = json ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : [NSData data];
    [fetch finish];
  });
}
@end

// Products that have something to say: why some are missing, and what
// became of a price.
@interface OISChattyProducts : ODataEntitySetHandler
@end

@implementation OISChattyProducts
- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [request addMessage:@"Products no longer sold are listed too" code:@"Listed" severity:@"info" target:nil];
  return [super objectsForFetchRequest:fetchRequest request:request reply:reply];
}

- (NSManagedObject *)insertObjectWithValues:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [request addMessage:@"The price was rounded to cents" code:@"Rounded" severity:@"warning" target:@"UnitPrice"];
  return [super insertObjectWithValues:values request:request reply:reply];
}
@end

// Signs in with an API key in X-API-Key, and says so in $metadata.
@interface OISKeyAuthenticator : NSObject <HSAuthenticator>
@end

@implementation OISKeyAuthenticator
- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  BOOL open = [[request valueForHeader:@"X-API-Key"] isEqualToString:@"sesame"];
  [reply finishWithPrincipal:open ? [[HSPrincipal alloc] initWithSubject:@"keyholder" claims:nil] : nil];
}

- (NSDictionary *)authorizationDescription
{
  return @{ @"@type": @"Org.OData.Authorization.V1.ApiKey", @"Name": @"Key", @"KeyName": @"X-API-Key",
            @"Location": @{ @"$EnumMember": @"Org.OData.Authorization.V1.KeyLocation/Header" } };
}
@end

// Gives the tokens it holds, a fresh one when asked to refresh; keeps what
// it was asked.
@interface OISTokenProvider : NSObject <ODataCredentialProviding>
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *freshToken;
@property (atomic, strong) NSMutableArray *asked;
@end

@implementation OISTokenProvider
- (NSString *)accessTokenForAuthorization:(ODataSchemaAuthorization *)authorization refresh:(BOOL)refresh
{
  if (!self.asked) self.asked = [NSMutableArray array];
  [self.asked addObject:@[ authorization ?: [NSNull null], @(refresh) ]];
  return refresh ? self.freshToken : self.token;
}
@end

// Hands exchanges on to a service, keeping each request.
@interface OISRecordingTransport : NSObject <ODataTransport>
@property (nonatomic, strong) id<ODataTransport> next;
@property (atomic, strong) NSMutableArray<NSURLRequest *> *requests;
@end

@implementation OISRecordingTransport
- (void)startExchange:(ODataExchange *)exchange
{
  if (!self.requests) self.requests = [NSMutableArray array];
  [self.requests addObject:exchange.request];
  [self.next startExchange:exchange];
}
@end

// Answers a media resource's PUT as TripPin does: 200 with the entity,
// whose @odata.mediaEtag is the new one, and no ETag header. The service
// behind it answers at once.
@interface OISEntityAnsweringTransport : NSObject <ODataTransport>
@property (nonatomic, strong) id<ODataTransport> next;
@end

@implementation OISEntityAnsweringTransport
- (void)startExchange:(ODataExchange *)exchange
{
  NSString *path = exchange.request.URL.absoluteString;
  if (![exchange.request.HTTPMethod isEqualToString:@"PUT"] || ![path hasSuffix:@"/$value"]) {
    [self.next startExchange:exchange];
    return;
  }
  ODataExchange *put = [[ODataExchange alloc] initWithRequest:exchange.request target:nil action:NULL];
  [self.next startExchange:put];
  NSInteger status = [(NSHTTPURLResponse *)put.URLResponse statusCode];
  if (status >= 300) {
    exchange.URLResponse = put.URLResponse;
    exchange.data = put.data;
    [exchange finish];
    return;
  }
  NSURL *entity = [NSURL URLWithString:[path substringToIndex:path.length - @"/$value".length]];
  ODataExchange *read = [[ODataExchange alloc] initWithRequest:[NSURLRequest requestWithURL:entity] target:nil action:NULL];
  [self.next startExchange:read];
  exchange.URLResponse = [[NSHTTPURLResponse alloc] initWithURL:exchange.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                   headerFields:@{ @"Content-Type": @"application/json", @"OData-Version": @"4.0" }];
  exchange.data = read.data;
  [exchange finish];
}
@end

// Fails every fetch as a store would, with a message not for clients.
// Products as an analyst sees them: grouped by category or by whether
// discontinued, prices summed or averaged, names joined; and a forecast.
@interface OISAggregatingHandler : ODataEntitySetHandler
@end

@implementation OISAggregatingHandler
- (instancetype)initWithEntity:(NSEntityDescription *)entity
{
  if ((self = [super initWithEntity:entity])) {
    self.groupableProperties = [NSSet setWithObjects:@"Category", @"Discontinued", nil];
    self.aggregatableProperties = @{ @"UnitPrice": @[ @"sum", @"average", @"$count" ], @"ProductName": @[ @"Custom.concat" ] };
    self.customAggregationMethods = [NSSet setWithObject:@"Custom.concat"];
    self.customAggregates = @{ @"Forecast": @"Edm.Decimal" };
  }
  return self;
}
// Distinct values, sorted, joined by commas.
- (id)valueOfAggregationMethod:(NSString *)method values:(NSArray *)values request:(ODataRequest *)request
{
  return [[[NSSet setWithArray:values].allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}
// A tenth more than the prices come to.
- (id)valueOfCustomAggregate:(NSString *)name objects:(NSArray *)objects request:(ODataRequest *)request
{
  NSDecimalNumber *total = [NSDecimalNumber zero];
  for (NSManagedObject *object in objects) total = [total decimalNumberByAdding:[object valueForKey:@"unitPrice"] ?: [NSDecimalNumber zero]];
  return [total decimalNumberByMultiplyingBy:[NSDecimalNumber decimalNumberWithString:@"1.1"]];
}
@end

// Categories as an open type: Prices, each product's price by name (as a
// process's variables would be, rows of their own), and Size, how many
// products there are.
// Asked for a response's categories at once: each batch is kept, and with
// later set the answer comes from another thread, a little later. A request
// with an X-No-Size header may not filter by Size.
@interface OISOpenCategoriesHandler : ODataEntitySetHandler
@property (nonatomic, strong) NSMutableArray<NSArray *> *batches;
@property (nonatomic) BOOL later;
// What writes gave, by category ID (NSNull: removed); those a PUT
// replaced, which keep none of the rest; each write's categories; and
// whether writes are refused, as by default.
@property (nonatomic, strong) NSMutableDictionary *written;
@property (nonatomic, strong) NSMutableSet *replaced;
@property (nonatomic, strong) NSMutableArray<NSArray *> *writeBatches;
@property (nonatomic) BOOL refusesWrites;
@end

@implementation OISOpenCategoriesHandler
- (instancetype)initWithEntity:(NSEntityDescription *)entity
{
  if ((self = [super initWithEntity:entity])) {
    self.openType = YES;
    _batches = [NSMutableArray array];
    _written = [NSMutableDictionary dictionary];
    _replaced = [NSMutableSet set];
    _writeBatches = [NSMutableArray array];
  }
  return self;
}
- (id)writeDynamicProperties:(NSArray<NSDictionary *> *)values ofObjects:(NSArray<NSManagedObject *> *)objects
                     request:(ODataRequest *)request reply:(ODataReply *)reply
{
  if (self.refusesWrites) return [super writeDynamicProperties:values ofObjects:objects request:request reply:reply];
  [self.writeBatches addObject:[objects valueForKey:@"name"]];
  for (NSUInteger i = 0; i < objects.count; i++) {
    id key = [objects[i] valueForKey:@"id"];
    if ([request.method isEqualToString:@"PUT"]) {
      [self.replaced addObject:key];
      [self.written removeObjectForKey:key];
    }
    NSMutableDictionary *kept = self.written[key] ?: [NSMutableDictionary dictionary];
    [kept addEntriesFromDictionary:values[i]];
    self.written[key] = kept;
  }
  if (!self.later) return @YES;
  [reply defer];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [reply finishWithResult:@YES];
  });
  return nil;
}
- (NSDictionary *)dynamicPropertiesOfObjects:(NSArray<NSManagedObject *> *)objects request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [self.batches addObject:[objects valueForKey:@"name"]];
  NSMutableDictionary *answer = [NSMutableDictionary dictionary];
  for (NSManagedObject *object in objects) {
    NSMutableDictionary *prices = [NSMutableDictionary dictionary];
    for (NSManagedObject *product in [object valueForKey:@"products"]) prices[[product valueForKey:@"name"]] = [product valueForKey:@"unitPrice"];
    id key = [object valueForKey:@"id"];
    NSMutableDictionary *dynamic = [self.replaced containsObject:key] ? [NSMutableDictionary dictionary] : [@{
      @"Prices": prices, @"Size": @([[object valueForKey:@"products"] count]), @"CategoryName": @"not this",
      @"Reviewed": ODataDateFromString(@"2025-03-01T12:00:00Z"), @"Share": [NSDecimalNumber decimalNumberWithString:@"0.5"],
      @"Note": @"kept", @"Listed": @YES } mutableCopy];
    NSDictionary *written = self.written[key];
    for (NSString *name in written) {
      if (written[name] == [NSNull null]) [dynamic removeObjectForKey:name];
      else dynamic[name] = written[name];
    }
    answer[object.objectID] = dynamic;
  }
  if (!self.later) return answer;
  [reply defer];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [reply finishWithResult:answer];
  });
  return nil;
}
- (NSPredicate *)predicateForDynamicProperty:(NSArray<NSString *> *)path
                                    operator:(NSPredicateOperatorType)type
                                       value:(id)value
                                     request:(ODataRequest *)request
                                       error:(NSError **)error
{
  if ([request valueForHeader:@"X-No-Size"] && [path[0] isEqualToString:@"Size"]) {
    if (error) *error = ODataServiceError(403, @"Size is not filtered by here");
    return nil;
  }
  if (path.count == 1 && [path[0] isEqualToString:@"Size"]) {
    return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"products.@count"]
                                              rightExpression:[NSExpression expressionForConstantValue:value]
                                                     modifier:NSDirectPredicateModifier type:type options:0];
  }
  if (path.count == 2 && [path[0] isEqualToString:@"Prices"]) {
    NSPredicate *named = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionWithFormat:@"$p.name"]
                                                            rightExpression:[NSExpression expressionForConstantValue:path[1]]
                                                                   modifier:NSDirectPredicateModifier type:NSEqualToPredicateOperatorType options:0];
    NSPredicate *priced = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionWithFormat:@"$p.unitPrice"]
                                                             rightExpression:[NSExpression expressionForConstantValue:value]
                                                                    modifier:NSDirectPredicateModifier type:type options:0];
    NSExpression *matching = [NSExpression expressionForSubquery:[NSExpression expressionForKeyPath:@"products"] usingIteratorVariable:@"p"
                                                       predicate:[NSCompoundPredicate andPredicateWithSubpredicates:@[ named, priced ]]];
    return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForFunction:@"count:" arguments:@[ matching ]]
                                              rightExpression:[NSExpression expressionForConstantValue:@0]
                                                     modifier:NSDirectPredicateModifier type:NSGreaterThanPredicateOperatorType options:0];
  }
  if ([path[0] isEqualToString:@"Secret"]) {
    if (error) *error = ODataServiceError(403, @"Secret is not filtered by");
  }
  return nil;
}
@end

@interface OISFailingStoreHandler : ODataEntitySetHandler
@end

@implementation OISFailingStoreHandler
- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [reply failWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:134060
                                       userInfo:@{ NSLocalizedDescriptionKey: @"SQLite error at /var/db/secret.sqlite" }]];
  return nil;
}
@end

// Counts the writes a temporal action asks of it, and refuses a budget
// over 5000.
@interface OISBudgetGuard : ODataEntitySetHandler
@property (nonatomic) NSInteger inserts, updates;
@end

@implementation OISBudgetGuard
- (NSManagedObject *)insertObjectWithValues:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  self.inserts++;
  return [super insertObjectWithValues:values request:request reply:reply];
}

- (NSManagedObject *)updateObject:(NSManagedObject *)object values:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  self.updates++;
  if ([values[@"budget"] integerValue] > 5000) {
    [reply failWithError:ODataServiceError(403, @"That is more than a department gets")];
    return nil;
  }
  return [super updateObject:object values:values request:request reply:reply];
}
@end

// Refuses a $batch in JSON with 415, as a service that reads only
// multipart would; passes on everything else.
@interface OISMultipartOnlyTransport : NSObject <ODataTransport>
@property (nonatomic, strong) id<ODataTransport> next;
@property (atomic, strong) NSMutableArray<NSURLRequest *> *requests;
@end

@implementation OISMultipartOnlyTransport
- (void)startExchange:(ODataExchange *)exchange
{
  if (!self.requests) self.requests = [NSMutableArray array];
  [self.requests addObject:exchange.request];
  NSString *type = [exchange.request valueForHTTPHeaderField:@"Content-Type"] ?: @"";
  if ([exchange.request.URL.path hasSuffix:@"$batch"] && [type hasPrefix:@"application/json"]) {
    exchange.URLResponse = [[NSHTTPURLResponse alloc] initWithURL:exchange.request.URL statusCode:415 HTTPVersion:@"HTTP/1.1"
                                                     headerFields:@{ @"Content-Type": @"application/json" }];
    exchange.data = [@"{\"error\":{\"code\":\"415\",\"message\":\"multipart only\"}}" dataUsingEncoding:NSUTF8StringEncoding];
    [exchange finish];
    return;
  }
  [self.next startExchange:exchange];
}
@end

// Loses the answer to the first write it carries, as a dropped connection
// would: the service has done it, the client hears nothing.
@interface OISLosingTransport : NSObject <ODataTransport>
@property (nonatomic, strong) id<ODataTransport> next;
@property (nonatomic) NSInteger lost;
@property (atomic, strong) NSMutableArray<NSURLRequest *> *requests;
@end

@implementation OISLosingTransport
- (void)startExchange:(ODataExchange *)exchange
{
  if (!self.requests) self.requests = [NSMutableArray array];
  [self.requests addObject:exchange.request];
  if (self.lost == 0 && ![exchange.request.HTTPMethod isEqualToString:@"GET"]) {
    self.lost++;
    ODataExchange *done = [[ODataExchange alloc] initWithRequest:exchange.request target:nil action:NULL];
    [self.next startExchange:done];
    exchange.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil];
    [exchange finish];
    return;
  }
  [self.next startExchange:exchange];
}
@end

@interface ODataServiceTests : XCTestCase
@end

@implementation ODataServiceTests {
  NSPersistentStoreCoordinator *_coordinator;
  ODataService *_service;
  dispatch_semaphore_t _finished;
  NSMutableArray<NSURL *> *_storeFiles;
  ODataStreamTransfer *_finishedTransfer;
  ODataQuery *_finishedQuery;
  // serveStaff's model's configurations: name -> entity names.
  NSDictionary<NSString *, NSArray<NSString *> *> *_staffConfigurations;
}

- (void)setUp
{
  [super setUp];
  _storeFiles = [NSMutableArray array];
  [self serveModel:OISCatalogModel()];
}

- (void)tearDown
{
  for (NSURL *url in _storeFiles) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
  [super tearDown];
}

// A service over the Catalog rows in memory, in this model.
- (void)serveModel:(NSManagedObjectModel *)model
{
  [self serveModel:model storeType:NSInMemoryStoreType];
}

- (void)serveModel:(NSManagedObjectModel *)model storeType:(NSString *)storeType
{
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_storeFiles addObject:url];
  }
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  [self seed];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator
                                                          serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

- (NSManagedObject *)insert:(NSString *)entity into:(NSManagedObjectContext *)context values:(NSDictionary *)values
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) [object setValue:values[key] forKey:key];
  return object;
}

// A few of Northwind's rows.
- (void)seed
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  NSManagedObject *beverages = [self insert:@"Category" into:context values:@{ @"id": @1, @"name": @"Beverages" }];
  NSManagedObject *condiments = [self insert:@"Category" into:context values:@{ @"id": @2, @"name": @"Condiments" }];
  NSManagedObject *exotic = [self insert:@"Supplier" into:context values:@{ @"id": @1, @"companyName": @"Exotic Liquids", @"city": @"London", @"country": @"UK" }];
  NSManagedObject *cajun = [self insert:@"Supplier" into:context values:@{ @"id": @2, @"companyName": @"New Orleans Cajun Delights", @"city": @"New Orleans", @"country": @"USA" }];
  NSArray *products = @[
    @[ @1, @"Chai", @"18", @NO, beverages, @[ exotic ] ],
    @[ @2, @"Chang", @"19", @NO, beverages, @[ exotic ] ],
    @[ @3, @"Aniseed Syrup", @"10", @NO, condiments, @[ exotic ] ],
    @[ @4, @"Chef Anton's Cajun Seasoning", @"22", @NO, condiments, @[ cajun ] ],
    @[ @5, @"Chef Anton's Gumbo Mix", @"21.35", @YES, condiments, @[ cajun ] ],
  ];
  NSManagedObject *chai = nil;
  for (NSArray *p in products) {
    NSManagedObject *product = [self insert:@"Product" into:context values:@{
      @"id": p[0], @"name": p[1], @"unitPrice": [NSDecimalNumber decimalNumberWithString:p[2]],
      @"discontinued": p[3], @"category": p[4] }];
    [[product mutableSetValueForKey:@"suppliers"] addObjectsFromArray:p[5]];
    if (!chai) chai = product;
  }
  NSManagedObject *warehouse = [self insert:@"Location" into:context values:@{ @"id": @1, @"name": @"Warehouse", @"city": @"Leeds" }];
  [self insert:@"Stock" into:context values:@{ @"id": @1, @"quantity": @40, @"product": chai, @"location": warehouse }];
  NSError *error = nil;
  XCTAssertTrue([context save:&error], @"%@", error);
}

- (NSManagedObject *)productWithID:(NSInteger)identifier in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"id"]
                                                       rightExpression:[NSExpression expressionForConstantValue:@(identifier)]
                                                              modifier:NSDirectPredicateModifier
                                                                  type:NSEqualToPredicateOperatorType
                                                               options:0];
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

#pragma mark Sending

- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  dispatch_semaphore_signal(_finished);
}

- (OISServiceResponse *)send:(NSString *)method path:(NSString *)path headers:(NSDictionary *)headers body:(id)body
{
  NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSURL *url = [NSURL URLWithString:[@"http://example.test/odata/" stringByAppendingString:encoded]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = method;
  for (NSString *name in headers) [request setValue:headers[name] forHTTPHeaderField:name];
  if (body) {
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  _finished = dispatch_semaphore_create(0);
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:request target:self action:@selector(exchangeDidFinish:)];
  [_service startExchange:exchange];
  long waited = dispatch_semaphore_wait(_finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  XCTAssertEqual(waited, 0L, @"%@ %@ did not finish", method, path);
  OISServiceResponse *response = [[OISServiceResponse alloc] init];
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)exchange.URLResponse;
  response.status = http.statusCode;
  response.headers = http.allHeaderFields;
  response.data = exchange.data;
  return response;
}

- (OISServiceResponse *)get:(NSString *)path
{
  return [self send:@"GET" path:path headers:nil body:nil];
}

- (NSArray *)names:(OISServiceResponse *)response
{
  return [response.json[@"value"] valueForKey:@"ProductName"];
}

#pragma mark Documents

- (void)testServiceDocumentAndMetadata
{
  OISServiceResponse *doc = [self get:@""];
  XCTAssertEqual(doc.status, 200);
  XCTAssertEqualObjects([doc header:@"OData-Version"], @"4.01");
  XCTAssertEqualObjects(doc.json[@"@odata.context"], @"http://example.test/odata/$metadata");
  XCTAssertEqualObjects([[doc.json[@"value"] valueForKey:@"name"] sortedArrayUsingSelector:@selector(compare:)],
                        (@[ @"Categories", @"Locations", @"Products", @"Stocks", @"Suppliers" ]));

  OISServiceResponse *metadata = [self get:@"$metadata"];
  XCTAssertEqual(metadata.status, 200);
  XCTAssertTrue([[metadata header:@"Content-Type"] hasPrefix:@"application/xml"]);
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:metadata.data error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  XCTAssertEqualObjects(schema.version, @"4.01");
  XCTAssertEqualObjects(schema.entitySets[@"Products"], @"Default.Product");
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Default.Product"];
  XCTAssertEqualObjects([schema keyOfEntityType:product], @[ @"ProductID" ]);
  XCTAssertEqualObjects([schema property:@"UnitPrice" ofEntityType:product].type, @"Edm.Decimal");
  XCTAssertEqualObjects([schema navigationProperty:@"Category" ofEntityType:product].partner, @"Products");
  XCTAssertTrue([schema navigationProperty:@"Suppliers" ofEntityType:product].isCollection);

  // The client, given this $metadata, finds the model matches it.
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  XCTAssertEqualObjects([mapper problemsWithModel:OISCatalogModel()], @[]);
  XCTAssertEqualObjects(_service.metadataProblems, @[]);

  OISServiceResponse *old = [self send:@"GET" path:@"$metadata" headers:@{ @"OData-MaxVersion": @"4.0" } body:nil];
  XCTAssertEqualObjects([old header:@"OData-Version"], @"4.0");
  NSString *oldXML = [[NSString alloc] initWithData:old.data encoding:NSUTF8StringEncoding];
  XCTAssertTrue([oldXML containsString:@" Version=\"4.0\">"], @"4.0 CSDL for a 4.0 client: %@", oldXML);
  XCTAssertEqualObjects([ODataSchema schemaWithData:old.data error:NULL].version, @"4.01",
                        @"and it says the service speaks 4.01 too (Part 1 section 13.3, item 16)");
}

#pragma mark Reading

- (void)testQueryOptions
{
  OISServiceResponse *all = [self get:@"Products"];
  XCTAssertEqual(all.status, 200);
  XCTAssertEqualObjects(all.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products");
  XCTAssertEqual([all.json[@"value"] count], 5u);
  NSDictionary *chai = all.json[@"value"][0];
  XCTAssertEqualObjects(chai[@"ProductID"], @1);
  XCTAssertEqualObjects(chai[@"ProductName"], @"Chai");
  XCTAssertEqualObjects(chai[@"Discontinued"], @NO);
  XCTAssertTrue([chai[@"@odata.etag"] hasPrefix:@"W/\""]);

  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=UnitPrice gt 18&$orderby=UnitPrice desc"]],
                        (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix", @"Chang" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Category/CategoryName eq 'Beverages'"]], (@[ @"Chai", @"Chang" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=startswith(tolower(ProductName),'ch')&$top=2&$skip=1"]],
                        (@[ @"Chang", @"Chef Anton's Cajun Seasoning" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=tolower(ProductName) eq 'Chai'"]], @[], @"tolower never gives an upper-case letter");
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=contains(ProductName,'Anton') and not Discontinued"]],
                        @[ @"Chef Anton's Cajun Seasoning" ]);
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=ProductID in (1,3)"]], (@[ @"Chai", @"Aniseed Syrup" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Suppliers/any(s:s/City eq 'New Orleans')"]],
                        (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Suppliers/all(s:s/Country eq 'UK')"]],
                        (@[ @"Chai", @"Chang", @"Aniseed Syrup" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=ProductName eq @n&@n='Chang'"]], @[ @"Chang" ]);
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Category eq null"]], @[]);

  OISServiceResponse *counted = [self get:@"Products?$count=true&$top=1&$select=ProductName"];
  XCTAssertEqualObjects(counted.json[@"@odata.count"], @5);
  XCTAssertEqualObjects(counted.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(ProductName)");
  NSMutableSet *keys = [NSMutableSet setWithArray:[counted.json[@"value"][0] allKeys]];
  [keys removeObject:@"@odata.etag"];
  XCTAssertEqualObjects(keys, [NSSet setWithObject:@"ProductName"]);

  OISServiceResponse *count = [self get:@"Products/$count?$filter=UnitPrice lt 20"];
  XCTAssertEqual(count.status, 200);
  XCTAssertEqualObjects(count.text, @"3");
  XCTAssertTrue([[count header:@"Content-Type"] hasPrefix:@"text/plain"]);
}

// $top=0 is no rows (#20): the usual way to ask for a count alone.
- (void)testTopZeroIsNoRows
{
  for (NSString *query in @[ @"Products?$top=0", @"Products?$top=0&$skip=2", @"Products?$top=0&$orderby=ProductName",
                             @"Products?$top=0&$filter=UnitPrice gt 10", @"Categories(1)/Products?$top=0",
                             @"Products?$top=0&$orderby=UnitPrice mul 2 desc",  // sorted here, every row then the page
                             @"Products?$top=2&$skiptoken=2" ]) {
    OISServiceResponse *response = [self get:query];
    XCTAssertEqual(response.status, 200, @"%@: %@", query, response.text);
    XCTAssertEqualObjects(response.json[@"value"], @[], @"%@", query);
    XCTAssertNil(response.json[@"@odata.nextLink"], @"%@", query);
  }
  XCTAssertEqualObjects([self get:@"Products?$top=0&$count=true"].json[@"@odata.count"], @5);
  XCTAssertEqualObjects([self get:@"Products?$top=0&$count=true&$filter=UnitPrice lt 20"].json[@"@odata.count"], @3);
  XCTAssertEqualObjects([self get:@"Products?$top=0&$count=true&$orderby=UnitPrice mul 2"].json[@"@odata.count"], @5);
  XCTAssertEqualObjects([self get:@"Products?$top=0&$count=true&$apply=filter(UnitPrice lt 20)"].json[@"value"], @[]);
  // None read: the count is all the store is asked.
  _service.explains = YES;
  NSString *physical = [self get:@"$explain/Products?$top=0&$count=true"].json[@"physical"];
  XCTAssertTrue([physical hasPrefix:@"Objects (0)"], @"%@", physical);
  XCTAssertFalse([physical containsString:@"Store scan"], @"%@", physical);
  for (NSDictionary *category in [self get:@"Categories?$expand=Products($top=0)"].json[@"value"]) {
    XCTAssertEqualObjects(category[@"Products"], @[], @"%@", category);
  }
}

- (void)testEntitiesPropertiesAndNavigation
{
  OISServiceResponse *chai = [self get:@"Products(1)"];
  XCTAssertEqual(chai.status, 200);
  XCTAssertEqualObjects(chai.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products/$entity");
  XCTAssertEqualObjects(chai.json[@"ProductName"], @"Chai");
  XCTAssertEqualObjects([chai header:@"ETag"], chai.json[@"@odata.etag"]);
  XCTAssertEqualObjects([self get:@"Products/1"].json[@"ProductName"], @"Chai", @"a key as a segment");

  XCTAssertEqualObjects([self get:@"Products(1)/Category"].json[@"CategoryName"], @"Beverages");
  XCTAssertEqualObjects([self names:[self get:@"Categories(2)/Products?$orderby=ProductID desc"]],
                        (@[ @"Chef Anton's Gumbo Mix", @"Chef Anton's Cajun Seasoning", @"Aniseed Syrup" ]));
  XCTAssertEqualObjects([self names:[self get:@"Suppliers(2)/Products"]], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects([self get:@"Categories(2)/Products(3)"].json[@"ProductName"], @"Aniseed Syrup");
  XCTAssertEqual([self get:@"Categories(1)/Products(3)"].status, 404, @"3 is not a beverage");
  XCTAssertEqualObjects([self get:@"Categories(2)/Products/$count"].text, @"3");

  OISServiceResponse *name = [self get:@"Products(4)/ProductName"];
  XCTAssertEqualObjects(name.json[@"value"], @"Chef Anton's Cajun Seasoning");
  XCTAssertEqualObjects(name.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(4)/ProductName");
  XCTAssertEqualObjects([self get:@"Products(4)/UnitPrice/$value"].text, @"22");
  XCTAssertEqual([self get:@"Locations(1)/Country"].status, 204, @"null");

  XCTAssertEqual([self get:@"Products(99)"].status, 404);
  XCTAssertEqual([self get:@"Products(1)/Nothing"].status, 404);
  XCTAssertEqual([self get:@"Nothing"].status, 404);
}

- (void)testExpand
{
  OISServiceResponse *r = [self get:@"Products?$filter=ProductID eq 1&$expand=Category($select=CategoryName),Suppliers($filter=City eq 'London';$count=true)"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSDictionary *chai = r.json[@"value"][0];
  XCTAssertEqualObjects(chai[@"Category"][@"CategoryName"], @"Beverages");
  XCTAssertNil(chai[@"Category"][@"CategoryID"], @"$select within $expand");
  XCTAssertEqualObjects([chai[@"Suppliers"] valueForKey:@"CompanyName"], @[ @"Exotic Liquids" ]);
  XCTAssertEqualObjects(chai[@"Suppliers@odata.count"], @1);
  XCTAssertEqualObjects(r.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(Category(CategoryName),Suppliers())");

  OISServiceResponse *nested = [self get:@"Categories(2)?$expand=Products($orderby=UnitPrice desc;$top=1;$expand=Suppliers)"];
  NSArray *products = nested.json[@"Products"];
  XCTAssertEqual(products.count, 1u);
  XCTAssertEqualObjects(products[0][@"ProductName"], @"Chef Anton's Cajun Seasoning");
  XCTAssertEqualObjects([products[0][@"Suppliers"] valueForKey:@"City"], @[ @"New Orleans" ]);

  OISServiceResponse *refs = [self get:@"Categories(1)?$expand=Products/$ref"];
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *reference in refs.json[@"Products"]) [ids addObject:reference[@"@odata.id"] ?: @""];
  XCTAssertEqualObjects(ids, (@[ @"Products(1)", @"Products(2)" ]));
}

- (void)testServerDrivenPaging
{
  OISServiceResponse *first = [self send:@"GET" path:@"Products?$orderby=ProductName" headers:@{ @"Prefer": @"odata.maxpagesize=2" } body:nil];
  XCTAssertEqualObjects([self names:first], (@[ @"Aniseed Syrup", @"Chai" ]));
  XCTAssertEqualObjects([first header:@"Preference-Applied"], @"odata.maxpagesize=2");
  NSString *next = first.json[@"@odata.nextLink"];
  XCTAssertTrue([next hasPrefix:@"http://example.test/odata/Products?"], @"%@", next);
  NSMutableArray *names = [[self names:first] mutableCopy];
  while (next) {
    NSString *path = [[next substringFromIndex:@"http://example.test/odata/".length] stringByRemovingPercentEncoding];
    OISServiceResponse *page = [self send:@"GET" path:path headers:@{ @"Prefer": @"odata.maxpagesize=2" } body:nil];
    [names addObjectsFromArray:[self names:page]];
    next = page.json[@"@odata.nextLink"];
  }
  XCTAssertEqualObjects(names, (@[ @"Aniseed Syrup", @"Chai", @"Chang", @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));

  _service.maxPageSize = 3;
  OISServiceResponse *topped = [self get:@"Products?$top=4"];
  XCTAssertEqual([topped.json[@"value"] count], 3u);
  NSString *rest = [[topped.json[@"@odata.nextLink"] substringFromIndex:@"http://example.test/odata/".length] stringByRemovingPercentEncoding];
  XCTAssertEqual([[self get:rest].json[@"value"] count], 1u, @"$top counts across pages");
  XCTAssertNil([self get:rest].json[@"@odata.nextLink"]);
}

#pragma mark Writing

// Upsert (Part 1 section 11.4.4): PATCH or PUT to a key that names no
// entity creates it, with the URL's key; sent again, it updates it.
- (void)testUpsert
{
  NSDictionary *coffee = @{ @"ProductName": @"Ipoh Coffee", @"UnitPrice": @46, @"Category@odata.bind": @"Categories(1)" };
  OISServiceResponse *created = [self send:@"PATCH" path:@"Products(500)" headers:nil body:coffee];
  XCTAssertEqual(created.status, 201, @"%@", created.text);
  XCTAssertEqualObjects(created.json[@"ProductID"], @500, @"the URL's key");
  XCTAssertEqualObjects([created header:@"Location"], @"http://example.test/odata/Products(500)");
  XCTAssertEqualObjects([self get:@"Products(500)/Category"].json[@"CategoryName"], @"Beverages", @"bound as an insert binds");

  // Again, the same: an update now, with the same outcome.
  OISServiceResponse *again = [self send:@"PATCH" path:@"Products(500)" headers:nil body:coffee];
  XCTAssertEqual(again.status, 204, @"%@", again.text);
  XCTAssertEqualObjects([self get:@"Products/$count"].text, @"6", @"one product, not two");
  XCTAssertEqualObjects([self get:@"Products(500)"].json[@"UnitPrice"], @46);

  OISServiceResponse *put = [self send:@"PUT" path:@"Products(501)" headers:@{ @"Prefer": @"return=minimal" }
                                  body:@{ @"ProductName": @"Chartreuse verte", @"UnitPrice": @18 }];
  XCTAssertEqual(put.status, 204, @"%@", put.text);
  XCTAssertEqualObjects([put header:@"OData-EntityId"], @"http://example.test/odata/Products(501)");
  XCTAssertEqualObjects([self get:@"Products(501)"].json[@"ProductName"], @"Chartreuse verte");

  // The body may repeat the key, not contradict it.
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(502)" headers:nil body:@{ @"ProductID": @502, @"ProductName": @"Same" }].status), 201);
  OISServiceResponse *other = [self send:@"PATCH" path:@"Products(503)" headers:nil body:@{ @"ProductID": @504, @"ProductName": @"Other" }];
  XCTAssertEqual(other.status, 400, @"%@", other.text);
  XCTAssertEqual([self get:@"Products(503)"].status, 404);
  XCTAssertEqual([self get:@"Products(504)"].status, 404);
}

- (void)testUpsertPreconditions
{
  // If-Match: there must be an entity to match.
  OISServiceResponse *match = [self send:@"PATCH" path:@"Products(600)" headers:@{ @"If-Match": @"*" } body:@{ @"ProductName": @"X" }];
  XCTAssertEqual(match.status, 412, @"%@", match.text);
  XCTAssertEqual([self get:@"Products(600)"].status, 404);

  // If-None-Match: * only creates.
  OISServiceResponse *fresh = [self send:@"PATCH" path:@"Products(600)" headers:@{ @"If-None-Match": @"*" } body:@{ @"ProductName": @"X" }];
  XCTAssertEqual(fresh.status, 201, @"%@", fresh.text);
  OISServiceResponse *exists = [self send:@"PATCH" path:@"Products(600)" headers:@{ @"If-None-Match": @"*" } body:@{ @"ProductName": @"Y" }];
  XCTAssertEqual(exists.status, 412, @"%@", exists.text);
  XCTAssertEqualObjects([self get:@"Products(600)"].json[@"ProductName"], @"X", @"left as it was");
  // An ETag list: refused in that version, taken in another.
  NSString *etag = [[self get:@"Products(600)"] header:@"ETag"];
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(600)" headers:@{ @"If-None-Match": etag } body:@{ @"ProductName": @"Z" }].status), 412);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(600)" headers:@{ @"If-None-Match": @"W/\"other\"" } body:@{ @"ProductName": @"Z" }].status), 204);
}

- (void)testUpsertWhereItDoesNotApply
{
  // A set that does not take it, or no inserts at all: 404 as before.
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.allowsUpsert = NO;
  [_service setHandler:products forEntitySet:@"Products"];
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(700)" headers:nil body:@{ @"ProductName": @"X" }].status), 404);
  NSString *metadata = [self get:@"$metadata"].text;
  NSRange productsAt = [metadata rangeOfString:@"<EntitySet Name=\"Products\""];
  NSRange categoriesAt = [metadata rangeOfString:@"<EntitySet Name=\"Categories\""];
  XCTAssertTrue(productsAt.location != NSNotFound && categoriesAt.location != NSNotFound);
  NSRange productsEnd = [metadata rangeOfString:@"</EntitySet>" options:0 range:NSMakeRange(productsAt.location, metadata.length - productsAt.location)];
  NSString *productsSet = [metadata substringWithRange:NSMakeRange(productsAt.location, productsEnd.location - productsAt.location)];
  XCTAssertTrue([productsSet rangeOfString:@"Upsertable"].location == NSNotFound, @"%@", productsSet);
  NSRange categoriesEnd = [metadata rangeOfString:@"</EntitySet>" options:0 range:NSMakeRange(categoriesAt.location, metadata.length - categoriesAt.location)];
  NSString *categoriesSet = [metadata substringWithRange:NSMakeRange(categoriesAt.location, categoriesEnd.location - categoriesAt.location)];
  XCTAssertTrue([categoriesSet rangeOfString:@"Upsertable"].location != NSNotFound, @"a set that takes it says so: %@", categoriesSet);

  // Not through a navigation property, and not before the path's end.
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)/Products(999)" headers:nil body:@{ @"ProductName": @"X" }].status), 404);
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(77)/CategoryName" headers:nil body:@{ @"value": @"X" }].status), 404);
  XCTAssertEqual([self get:@"Categories(77)"].status, 404);
}

- (void)testUpsertInBatchAndWithScopes
{
  OISServiceResponse *batch = [self send:@"POST" path:@"$batch" headers:nil body:@{ @"requests": @[
    @{ @"method": @"PATCH", @"url": @"Products(800)", @"id": @"1", @"body": @{ @"ProductName": @"Batch one" } },
    @{ @"method": @"PATCH", @"url": @"Products(800)", @"id": @"2", @"body": @{ @"ProductName": @"Batch one, again" } } ] }];
  XCTAssertEqual(batch.status, 200, @"%@", batch.text);
  NSArray *statuses = [batch.json[@"responses"] valueForKey:@"status"];
  XCTAssertEqualObjects(statuses, (@[ @201, @204 ]), @"%@", batch.text);
  XCTAssertEqualObjects([self get:@"Products(800)"].json[@"ProductName"], @"Batch one, again");

  // Creating is an insert: its scopes.
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.insertScopes = [NSSet setWithObject:@"Products.Add"];
  [_service setHandler:products forEntitySet:@"Products"];
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(801)" headers:@{ @"X-Scopes": @"Products.Read" } body:@{ @"ProductName": @"X" }].status), 403);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(801)" headers:@{ @"X-Scopes": @"Products.Add" } body:@{ @"ProductName": @"X" }].status), 201);
}

- (void)testCreateUpdateDelete
{
  OISServiceResponse *created = [self send:@"POST" path:@"Products" headers:nil body:@{
    @"ProductName": @"Ipoh Coffee", @"UnitPrice": @46, @"Discontinued": @NO,
    @"Category@odata.bind": @"Categories(1)", @"Suppliers@odata.bind": @[ @"http://example.test/odata/Suppliers(1)" ] }];
  XCTAssertEqual(created.status, 201, @"%@", created.text);
  XCTAssertEqualObjects(created.json[@"ProductID"], @6, @"one more than the largest key");
  XCTAssertEqualObjects([created header:@"Location"], @"http://example.test/odata/Products(6)");
  XCTAssertEqualObjects([self get:@"Products(6)/Category"].json[@"CategoryName"], @"Beverages");
  XCTAssertEqualObjects([self get:@"Suppliers(1)/Products/$count"].text, @"4");

  NSString *etag = [created header:@"ETag"];
  OISServiceResponse *stale = [self send:@"PATCH" path:@"Products(6)" headers:@{ @"If-Match": @"W/\"nope\"" } body:@{ @"UnitPrice": @40 }];
  XCTAssertEqual(stale.status, 412);
  XCTAssertNotNil(stale.json[@"error"][@"message"]);

  OISServiceResponse *patched = [self send:@"PATCH" path:@"Products(6)" headers:@{ @"If-Match": etag } body:@{ @"UnitPrice": @40 }];
  XCTAssertEqual(patched.status, 204, @"%@", patched.text);
  XCTAssertNotEqualObjects([patched header:@"ETag"], etag);
  XCTAssertEqualObjects([self get:@"Products(6)/UnitPrice/$value"].text, @"40");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(6)" headers:@{ @"If-Match": etag } body:@{ @"UnitPrice": @1 }].status), 412, @"the old ETag no longer matches");

  OISServiceResponse *represented = [self send:@"PATCH" path:@"Products(6)" headers:@{ @"Prefer": @"return=representation" } body:@{ @"ProductName": @"Ipoh" }];
  XCTAssertEqual(represented.status, 200);
  XCTAssertEqualObjects(represented.json[@"ProductName"], @"Ipoh");
  XCTAssertEqualObjects(represented.json[@"UnitPrice"], @40);

  OISServiceResponse *put = [self send:@"PUT" path:@"Products(6)" headers:nil body:@{ @"ProductName": @"Ipoh Coffee" }];
  XCTAssertEqual(put.status, 204);
  XCTAssertEqual([self get:@"Products(6)/UnitPrice"].status, 204, @"PUT resets what it leaves out");

  XCTAssertEqual(([self send:@"PATCH" path:@"Products(6)" headers:nil body:@{ @"ProductID": @7 }].status), 400, @"keys do not change");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(6)" headers:nil body:@{ @"Colour": @"red" }].status), 400);
  XCTAssertEqual(([self send:@"POST" path:@"Products" headers:nil body:@{ @"ProductName": @"x", @"Category@odata.bind": @"Categories(9)" }].status), 400);

  OISServiceResponse *child = [self send:@"POST" path:@"Categories(2)/Products" headers:@{ @"Prefer": @"return=minimal" } body:@{ @"ProductName": @"Genen Shouyu" }];
  XCTAssertEqual(child.status, 204);
  XCTAssertEqualObjects([child header:@"OData-EntityId"], @"http://example.test/odata/Products(7)");
  XCTAssertEqualObjects([self get:@"Products(7)/Category/CategoryName"].json[@"value"], @"Condiments");

  XCTAssertEqual(([self send:@"DELETE" path:@"Products(6)" headers:nil body:nil].status), 204);
  XCTAssertEqual([self get:@"Products(6)"].status, 404);
  XCTAssertEqualObjects([self get:@"Suppliers(1)/Products/$count"].text, @"3");
}

- (void)testErrors
{
  OISServiceResponse *missing = [self get:@"Nothing(1)"];
  XCTAssertEqual(missing.status, 404);
  XCTAssertTrue([missing.json[@"error"][@"code"] length] > 0);
  XCTAssertTrue([missing.json[@"error"][@"message"] length] > 0);

  XCTAssertEqual([self get:@"Products?$filter=UnitPrice gt"].status, 400, @"does not parse");
  XCTAssertEqual([self get:@"Products?$filter=Colour eq 'red'"].status, 400, @"no such property");
  XCTAssertEqual([self get:@"Products?$filter=ProductName eq 1 add"].status, 400);
  XCTAssertEqual([self get:@"Products?$apply=groupby((Category))"].status, 501);
  XCTAssertEqual([self get:@"Products?$filter=Flags has Default.Colour'Red'"].status, 400, @"no such property");
  XCTAssertEqual([self get:@"$batch"].status, 405, @"$batch takes POST");
  XCTAssertEqual([self get:@"Products?$format=xml"].status, 406);
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"Accept": @"application/xml" } body:nil].status), 406);
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"OData-Version": @"5.0" } body:nil].status), 400);

  OISServiceResponse *method = [self send:@"POST" path:@"Products(1)" headers:nil body:@{}];
  XCTAssertEqual(method.status, 405);
  XCTAssertNotNil([method header:@"Allow"]);
  XCTAssertEqual(([self send:@"POST" path:@"Products" headers:@{ @"Content-Type": @"text/plain" } body:nil].status), 415);
}

- (void)testMetadataLevels
{
  OISServiceResponse *full = [self send:@"GET" path:@"Products(1)" headers:@{ @"Accept": @"application/json;odata.metadata=full" } body:nil];
  XCTAssertEqualObjects(full.json[@"@odata.id"], @"Products(1)");
  XCTAssertEqualObjects(full.json[@"@odata.type"], @"#Default.Product");
  XCTAssertTrue([[full header:@"Content-Type"] rangeOfString:@"odata.metadata=full"].location != NSNotFound);
  OISServiceResponse *none = [self get:@"Products(1)?$format=application/json;odata.metadata=none"];
  XCTAssertNil(none.json[@"@odata.context"]);
  XCTAssertNil(none.json[@"@odata.etag"]);
  XCTAssertEqualObjects(none.json[@"ProductName"], @"Chai");
  OISServiceResponse *strings = [self send:@"GET" path:@"Products(5)" headers:@{ @"Accept": @"application/json;IEEE754Compatible=true" } body:nil];
  XCTAssertEqualObjects(strings.json[@"UnitPrice"], @"21.35", @"Decimal as a string");
}

#pragma mark Handlers

// A read's plan, as $explain answers with it where the service says so:
// what the store does, what is done here.
- (void)testExplain
{
  XCTAssertNotEqual([self get:@"$explain/Products"].status, 200, @"not unless the service explains");
  _service.explains = YES;
  OISServiceResponse *r = [self get:@"$explain/Products?$filter=UnitPrice gt $these/aggregate(UnitPrice with average)&$orderby=ProductName&$top=2&$expand=Category&$count=true"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSString *physical = r.json[@"physical"], *logical = r.json[@"logical"];
  XCTAssertTrue([physical containsString:@"Store scan Product where UnitPrice gt $these/aggregate(UnitPrice with average)"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"sort ProductName, key top 2 page 2"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"$these/aggregate(UnitPrice with average) :=\n    Value $these/aggregate(UnitPrice with average)\n      Store scan Product"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"Nest Category"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"$count :=\n  Store count Product"], @"%@", physical);
  XCTAssertTrue([logical containsString:@"Limit top 2\n  Sort ProductName\n    Select UnitPrice gt $these/aggregate(UnitPrice with average)\n      Scan Product"], @"%@", logical);

  // Sorted here, by what the store cannot sort by: every row, then the page.
  physical = [self get:@"$explain/Products?$orderby=UnitPrice mul 2 desc&$top=1"].json[@"physical"];
  XCTAssertTrue([physical containsString:@"Limit top 1 page 1\n  Apply orderby(UnitPrice mul 2 desc)\n    Store scan Product sort key at most 10000"], @"%@", physical);
  // $apply: its leading filter in the store, the rest here.
  physical = [self get:@"$explain/Products?$apply=filter(UnitPrice gt 10)/groupby((Category/CategoryName),aggregate(UnitPrice with sum as T))"].json[@"physical"];
  XCTAssertTrue([physical containsString:@"groupby((Category/CategoryName),aggregate(UnitPrice with sum as T))"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"Store scan Product where UnitPrice gt 10"], @"%@", physical);
  XCTAssertEqual([[self get:@"Products?$top=1"].json[@"value"] count], 1u, @"a read is still a read");
}

- (void)testHandlerSeesAndAnswersLater
{
  OISLaterProducts *handler = [[OISLaterProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:handler forEntitySet:@"Products"];
  XCTAssertEqual([[self get:@"Products"].json[@"value"] count], 4u, @"the discontinued one is hidden");
  XCTAssertEqual(handler.deferred, 1);
  XCTAssertEqual([self get:@"Products(5)"].status, 404, @"by key too");
  XCTAssertEqualObjects([self get:@"Products/$count"].text, @"4");
  NSInteger asked = handler.deferred;
  NSArray *expanded = [self get:@"Categories(2)?$expand=Products"].json[@"Products"];
  XCTAssertEqual(expanded.count, 2u, @"and through $expand");
  XCTAssertEqual(handler.deferred, asked + 1, @"an expansion is read through the handler");

  // Answers that come later, as the plan runs again from the top: nested
  // expansions, counts, a grouping.
  OISServiceResponse *r = [self get:@"Categories?$expand=Products($expand=Category($expand=Products($select=ProductName));$count=true)&$count=true&$orderby=CategoryID"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects(r.json[@"@odata.count"], @2);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"Products@odata.count"], (@[ @2, @2 ]), @"%@", r.text);
  XCTAssertEqualObjects([[r.json[@"value"][1][@"Products"] firstObject] valueForKeyPath:@"Category.Products.ProductName"],
                        (@[ @"Aniseed Syrup", @"Chef Anton's Cajun Seasoning" ]), @"%@", r.text);
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate($count as N))&$orderby=Category/CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"N"], (@[ @2, @2 ]), @"%@", r.text);
  // A join's members too, through the handler: at the top, and within a
  // group's transformations.
  asked = handler.deferred;
  r = [self get:@"Categories?$apply=join(Products as P)/groupby((CategoryName),aggregate($count as N))&$orderby=CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"N"], (@[ @2, @2 ]), @"the discontinued one is not joined: %@", r.text);
  XCTAssertEqual(handler.deferred, asked + 1, @"the members, read once for all the categories");
  r = [self get:@"Categories?$apply=groupby((CategoryName),join(Products as P)/aggregate($count as N))&$orderby=CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"N"], (@[ @2, @2 ]), @"%@", r.text);

  handler.allowsDelete = NO;
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)" headers:nil body:nil].status), 405);
}

#pragma mark The client, talking to the service

// The store's fetch, its request, and the service's work, one trace: under
// the caller's span, its tracestate carried to the service.
- (void)testATraceFromTheStoreToTheService
{
  OTInMemoryExporter *memory = [[OTInMemoryExporter alloc] init];
  OTTracerProvider.sharedProvider = [[OTTracerProvider alloc] initWithResource:@{} sampler:[[OTRatioSampler alloc] initWithRatio:1]
                                                                    processor:[[OTSimpleSpanProcessor alloc] initWithExporter:memory]];
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  OTSpanContext *caller = [OTSpanContext contextWithTraceparent:@"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
                                                     tracestate:@"vendor=abc,other=1"];
  OTSpan *work = [[OTTracer tracerNamed:@"Tests" version:nil] startSpanNamed:@"work" kind:OTSpanKindInternal parent:caller attributes:nil];
  [work becomeCurrent];
  NSArray *rows = [context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Product"] error:&error];
  [work end];
  OTTracerProvider.sharedProvider = nil;
  XCTAssertTrue(rows.count > 0, @"%@", error);

  OTSpan *storeFetch = nil, *request = nil, *service = nil, *execute = nil, *serviceFetch = nil;
  for (OTSpan *span in memory.spans) {
    if ([span.name isEqualToString:@"fetch Product"] && [span.scopeName isEqualToString:@"ODataIncrementalStore"]) storeFetch = span;
    if ([span.name isEqualToString:@"GET Products"]) request = span;
    if ([span.name hasPrefix:@"ODataService GET Products"]) service = span;
    if ([span.name isEqualToString:@"execute"]) execute = span;
    if ([span.name isEqualToString:@"fetch Product"] && [span.scopeName isEqualToString:@"ODataService"]) serviceFetch = span;
  }
  XCTAssertNotNil(storeFetch, @"%@", memory.spans);
  XCTAssertNotNil(serviceFetch, @"%@", memory.spans);
  XCTAssertEqualObjects(storeFetch.parentSpanID, work.context.spanID);
  XCTAssertEqual(request.kind, OTSpanKindClient);
  XCTAssertEqualObjects(request.parentSpanID, storeFetch.context.spanID, @"the wire request under the store's fetch");
  XCTAssertEqualObjects(request.attributes[@"http.response.status_code"], @200);
  XCTAssertEqualObjects(service.parentSpanID, request.context.spanID, @"the service's span under the request, by its traceparent");
  XCTAssertEqualObjects(serviceFetch.parentSpanID, execute.context.spanID);
  for (OTSpan *span in @[ storeFetch, request, service, serviceFetch ]) {
    XCTAssertEqualObjects(span.context.traceID, caller.traceID, @"%@", span.name);
  }
  XCTAssertEqualObjects(service.context.traceState, @"vendor=abc,other=1", @"tracestate, sent as it came");
  XCTAssertEqualObjects(storeFetch.attributes[@"db.response.returned_rows"], @(rows.count));
}

// An operation's code runs under a span of its own, current on its thread:
// what it does, an engine's or a store's spans, goes under the request.
- (void)testAnOperationIsCalledUnderASpanOfItsOwn
{
  OTInMemoryExporter *memory = [[OTInMemoryExporter alloc] init];
  OTTracerProvider.sharedProvider = [[OTTracerProvider alloc] initWithResource:@{} sampler:[[OTRatioSampler alloc] initWithRatio:1]
                                                                    processor:[[OTSimpleSpanProcessor alloc] initWithExporter:memory]];
  _service.serviceOperations = [[OISTracedOperations alloc] init];
  OISServiceResponse *r = [self get:@"CurrentSpan()"];
  OTTracerProvider.sharedProvider = nil;
  XCTAssertEqual(r.status, 200, @"%@", r.text);

  OTSpan *call = nil, *execute = nil, *service = nil;
  for (OTSpan *span in memory.spans) {
    if ([span.name isEqualToString:@"call CurrentSpan"]) call = span;
    if ([span.name isEqualToString:@"execute"]) execute = span;
    if ([span.name hasPrefix:@"ODataService GET"]) service = span;
  }
  XCTAssertNotNil(call, @"%@", memory.spans);
  XCTAssertTrue(call.ended);
  // Nothing to read first: under the request's span, no execution.
  XCTAssertNil(execute, @"%@", memory.spans);
  XCTAssertEqualObjects(call.parentSpanID, service.context.spanID, @"%@", memory.spans);
  XCTAssertEqualObjects(call.attributes[@"code.function"], @"currentSpan:");
  XCTAssertEqualObjects(call.attributes[@"code.namespace"], @"OISTracedOperations");
  XCTAssertEqualObjects(r.json[@"value"], ([NSString stringWithFormat:@"call CurrentSpan %@", call.context.spanID]),
                        @"current while the operation ran");
  XCTAssertNil([OTSpan currentSpan], @"and no longer once it has");
}

- (NSArray<OTSpan *> *)spansOf:(NSString *)method path:(NSString *)path body:(id)body sampler:(id<OTSampler>)sampler
                         status:(NSInteger *)status
{
  OTInMemoryExporter *memory = [[OTInMemoryExporter alloc] init];
  OTTracerProvider.sharedProvider = [[OTTracerProvider alloc] initWithResource:@{} sampler:sampler
                                                                    processor:[[OTSimpleSpanProcessor alloc] initWithExporter:memory]];
  _service.serviceOperations = [[OISTracedOperations alloc] init];
  OISServiceResponse *r = [self send:method path:path headers:nil body:body];
  OTTracerProvider.sharedProvider = nil;
  if (status) {
    *status = r.status;
  } else {
    XCTAssertTrue(r.status < 300, @"%@ %@: %ld %@", method, path, (long)r.status, r.text);
  }
  return memory.spans;
}

static OTSpan *OISSpanNamed(NSArray<OTSpan *> *spans, NSString *name)
{
  for (OTSpan *span in spans) {
    if ([span.name isEqualToString:name]) return span;
  }
  return nil;
}

// What an operation traces is under its call; and an unsampled request's
// operation records nothing, rather than traces of its own.
- (void)testWhatAnOperationTracesFollowsTheRequest
{
  NSArray *spans = [self spansOf:@"GET" path:@"EngineStep()" body:nil sampler:[[OTRatioSampler alloc] initWithRatio:1] status:NULL];
  OTSpan *call = OISSpanNamed(spans, @"call EngineStep"), *step = OISSpanNamed(spans, @"engine step");
  XCTAssertNotNil(step, @"%@", spans);
  XCTAssertEqualObjects(step.parentSpanID, call.context.spanID);
  XCTAssertEqualObjects(step.context.traceID, call.context.traceID);

  spans = [self spansOf:@"GET" path:@"EngineStep()" body:nil sampler:[[OISEngineOnlySampler alloc] init] status:NULL];
  XCTAssertEqual(spans.count, 0u, @"the request was not sampled, so neither is its engine's step: %@", spans);
}

// A deferred operation: its span ends with its reply, and the work it does
// later, elsewhere, goes under it by reply.span.
- (void)testADeferredOperationEndsWithItsReply
{
  NSArray *spans = [self spansOf:@"GET" path:@"Later()" body:nil sampler:[[OTRatioSampler alloc] initWithRatio:1] status:NULL];
  OTSpan *call = OISSpanNamed(spans, @"call Later"), *step = OISSpanNamed(spans, @"later step");
  XCTAssertNotNil(step, @"%@", spans);
  XCTAssertEqualObjects(step.parentSpanID, call.context.spanID, @"made current where the work was done");
  XCTAssertTrue(call.endTime >= step.endTime, @"ended by the reply, not when the method returned");
  XCTAssertTrue((call.endTime - call.startTime) >= 25 * NSEC_PER_MSEC);
}

// Answered with the call still open (here, a reply that never came): the
// call failed too.
- (void)testAnOperationAnsweredForItIsMarkedFailed
{
  _service.replyTimeout = 0.2;
  NSInteger status = 0;
  NSArray *spans = [self spansOf:@"GET" path:@"Never()" body:nil sampler:[[OTRatioSampler alloc] initWithRatio:1] status:&status];
  OTSpan *call = OISSpanNamed(spans, @"call Never");
  XCTAssertEqual(status, 504);
  XCTAssertNotNil(call, @"%@", spans);
  XCTAssertTrue(call.ended);
  XCTAssertEqual(call.status, OTStatusError);
}

// An entity parameter is read first, by a plan: the call goes under its
// execution, with the read.
- (void)testAnOperationWithEntityParametersIsCalledUnderItsExecution
{
  NSArray *spans = [self spansOf:@"POST" path:@"StepForProduct" body:@{ @"Product": @{ @"@odata.id": @"Products(1)" } }
                         sampler:[[OTRatioSampler alloc] initWithRatio:1] status:NULL];
  OTSpan *execute = OISSpanNamed(spans, @"execute"), *call = OISSpanNamed(spans, @"call StepForProduct");
  OTSpan *step = OISSpanNamed(spans, @"product step");
  XCTAssertNotNil(execute, @"%@", spans);
  XCTAssertEqualObjects(call.parentSpanID, execute.context.spanID, @"%@", spans);
  XCTAssertEqualObjects(step.parentSpanID, call.context.spanID);
  // The action's changes saved as part of its call.
  OTSpan *save = nil;
  for (OTSpan *span in spans) {
    if ([span.name hasPrefix:@"save"]) save = span;
  }
  XCTAssertNotNil(save, @"%@", spans);
  XCTAssertEqualObjects(save.parentSpanID, call.context.spanID, @"%@", spans);
  XCTAssertTrue(call.endTime >= save.endTime, @"the call ends once its changes are saved");
  XCTAssertEqualObjects(save.attributes[@"odata.updated"], @1);
}

- (void)testNoTraceIsMadeUpForTheService
{
  // Nothing records it, and nobody began it: the request carries none.
  OTSpanContext *seen = nil;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/odata/Products"]];
  OTSpan *span = [[OTTracer tracerNamed:@"Tests" version:nil] startClientSpanForRequest:request name:nil parent:nil];
  seen = [OTSpanContext contextWithHeaders:request.allHTTPHeaderFields];
  XCTAssertNil(seen);
  XCTAssertFalse(span.recording);
}

- (void)testIncrementalStoreOverTheService
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  NSPersistentStore *store = [client addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                  configuration:nil
                                                            URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                                        options:@{ ODataIncrementalStoreTransportOption: _service }
                                                          error:&error];
  XCTAssertNotNil(store, @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 18 AND category.name == 'Condiments'"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  NSArray *rows = [context executeFetchRequest:fetch error:&error];
  XCTAssertNotNil(rows, @"%@", error);
  XCTAssertEqualObjects([rows valueForKey:@"name"], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  NSManagedObject *seasoning = rows.firstObject;
  XCTAssertEqualObjects([seasoning valueForKeyPath:@"category.name"], @"Condiments", @"a fault, fired through the service");
  XCTAssertEqualObjects([[seasoning valueForKey:@"suppliers"] valueForKey:@"city"], [NSSet setWithObject:@"New Orleans"]);

  // Insert, update and delete in one save.
  NSManagedObject *coffee = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
  [coffee setValue:@60 forKey:@"id"];
  [coffee setValue:@"Ipoh Coffee" forKey:@"name"];
  [coffee setValue:[NSDecimalNumber decimalNumberWithString:@"46"] forKey:@"unitPrice"];
  [coffee setValue:[seasoning valueForKey:@"category"] forKey:@"category"];
  [seasoning setValue:[NSDecimalNumber decimalNumberWithString:@"23.5"] forKey:@"unitPrice"];
  [context deleteObject:rows[1]];
  XCTAssertTrue([context save:&error], @"%@", error);

  // What the service's own store now holds.
  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  XCTAssertEqualObjects([[self productWithID:60 in:backing] valueForKeyPath:@"category.name"], @"Condiments");
  XCTAssertEqualObjects([[self productWithID:4 in:backing] valueForKey:@"unitPrice"], [NSDecimalNumber decimalNumberWithString:@"23.5"]);
  XCTAssertNil([self productWithID:5 in:backing]);

  // A change made behind the client's back is a conflict at its next save.
  NSManagedObject *behind = [self productWithID:4 in:backing];
  [behind setValue:@"Seasoning" forKey:@"name"];
  XCTAssertTrue([backing save:&error], @"%@", error);
  [seasoning setValue:[NSDecimalNumber decimalNumberWithString:@"24"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error]);
}

#pragma mark Operations

// The Catalog model, with Product's objects of a class that declares
// operations, and the service's own.
- (void)serveOperations
{
  // A model of its own to change: a copy (FreeCoreData's can be copied
  // since #43), else loaded again.
  NSManagedObjectModel *model = [OISCatalogModel() conformsToProtocol:@protocol(NSCopying)]
      ? [OISCatalogModel() copy]
      : [[NSManagedObjectModel alloc] initWithContentsOfURL:OISCatalogModelURL()];
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  product.managedObjectClassName = @"OISServedProduct";
  [self serveModel:model];
  _service.serviceOperations = [[OISCatalogOperations alloc] init];
}

- (void)testOperationsInMetadata
{
  [self serveOperations];
  XCTAssertEqualObjects(_service.operationProblems, @[]);
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Default.Product"];

  ODataSchemaOperation *discount = [schema operationNamed:@"DiscountedPriceByPercent" boundToEntityType:product collection:NO parameterNames:nil];
  XCTAssertNotNil(discount);
  XCTAssertFalse(discount.isAction);
  XCTAssertEqualObjects([discount.callerParameters valueForKey:@"name"], @[ @"Percent" ]);
  XCTAssertEqualObjects([discount.callerParameters valueForKey:@"type"], @[ @"Edm.Double" ]);
  XCTAssertEqualObjects(discount.returnType, @"Edm.Decimal");

  ODataSchemaOperation *pricier = [schema operationNamed:@"PricierThanPrice" boundToEntityType:product collection:YES parameterNames:nil];
  XCTAssertEqualObjects(pricier.returnType, @"Collection(Default.Product)");
  XCTAssertEqualObjects([schema operationNamed:@"CheapestInCategory" boundToEntityType:product collection:NO parameterNames:nil].returnType, @"Default.Product");
  ODataSchemaOperation *discontinue = [schema operationNamed:@"Discontinue" boundToEntityType:product collection:NO parameterNames:nil];
  XCTAssertTrue(discontinue.isAction);
  XCTAssertEqualObjects([discontinue.callerParameters valueForKey:@"name"], @[ @"Reason" ]);

  XCTAssertEqualObjects(schema.operationImports[@"CountProductsCheaperThanPrice"].operation, @"Default.CountProductsCheaperThanPrice");
  XCTAssertEqualObjects(schema.operationImports[@"ProductNames"].operation, @"Default.ProductNames", @"renamed");
  XCTAssertTrue(schema.operationImports[@"Fail"].isAction);
  NSArray *echo = [schema.operations[@"Default.Echo"] valueForKey:@"callerParameters"];
  XCTAssertEqualObjects([echo.firstObject valueForKey:@"name"], (@[ @"Text", @"Times" ]));
}

- (void)testFunctions
{
  [self serveOperations];
  OISServiceResponse *discount = [self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10)"];
  XCTAssertEqual(discount.status, 200, @"%@", discount.text);
  XCTAssertEqualObjects([discount.json[@"value"] description], @"16.2");
  XCTAssertEqualObjects(discount.json[@"@odata.context"], @"http://example.test/odata/$metadata#Edm.Decimal");

  OISServiceResponse *cheapest = [self get:@"Products(4)/Default.CheapestInCategory()"];
  XCTAssertEqualObjects(cheapest.json[@"ProductName"], @"Aniseed Syrup");
  XCTAssertEqualObjects(cheapest.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products/$entity");

  XCTAssertEqualObjects([self names:[self get:@"Products/Default.PricierThanPrice(Price=19)"]],
                        (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects([self names:[self get:@"Categories(1)/Products/Default.PricierThanPrice(Price=18)"]], @[ @"Chang" ],
                        @"bound to the category's products only");

  XCTAssertEqualObjects([self get:@"CountProductsCheaperThanPrice(Price=19)"].json[@"value"], @2);
  XCTAssertEqualObjects([self get:@"Echo(Text='ha',Times=3)"].json[@"value"], @"hahaha");
  XCTAssertEqualObjects([self get:@"Echo(Text=@t,Times=2)?@t='yo'"].json[@"value"], @"yoyo", @"a parameter alias");
  XCTAssertEqualObjects([[self get:@"SumOfPrices(Prices=@p)?@p=[1.5,2.25]"].json[@"value"] description], @"3.75", @"a JSON alias");
  OISServiceResponse *names = [self get:@"ProductNames()"];
  XCTAssertEqualObjects(names.json[@"value"], (@[ @"Chai", @"Chang" ]));
  XCTAssertEqualObjects(names.json[@"@odata.context"], @"http://example.test/odata/$metadata#Collection(Edm.String)");

  XCTAssertEqual(([self send:@"POST" path:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10)" headers:nil body:@{}].status), 405);
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent()"].status, 400, @"needs Percent");
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10,Extra=1)"].status, 400);
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent='x')"].status, 400);
  XCTAssertEqual([self get:@"Products(1)/Default.Nothing()"].status, 501);
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10)/Foo"].status, 400, @"a value cannot be read on from");
}

- (void)testActions
{
  [self serveOperations];
  OISServiceResponse *raised = [self send:@"POST" path:@"Products(1)/Default.RaisePriceByPercent" headers:nil body:@{ @"Percent": @50 }];
  XCTAssertEqual(raised.status, 204, @"%@", raised.text);
  XCTAssertEqualObjects([self get:@"Products(1)/UnitPrice/$value"].text, @"27", @"saved");
  XCTAssertEqual([self get:@"Products(1)/Default.RaisePriceByPercent"].status, 405);

  OISServiceResponse *discontinued = [self send:@"POST" path:@"Products(2)/Default.Discontinue" headers:nil body:@{ @"Reason": @"old" }];
  XCTAssertEqual(discontinued.status, 200, @"%@", discontinued.text);
  XCTAssertEqualObjects([discontinued.json[@"value"] description], @"19", @"answered later");
  XCTAssertEqualObjects([self get:@"Products(2)/Discontinued"].json[@"value"], @YES, @"and saved");
  XCTAssertEqual(([self send:@"POST" path:@"Products(3)/Default.Discontinue" headers:nil body:@{ @"Reason": @"" }].status), 400,
                 @"a deferred failure");
  XCTAssertEqualObjects([self get:@"Products(3)/Discontinued"].json[@"value"], @NO);

  OISServiceResponse *failed = [self send:@"POST" path:@"Fail" headers:nil body:@{ @"Code": @409 }];
  XCTAssertEqual(failed.status, 409);
  XCTAssertEqualObjects(failed.json[@"error"][@"message"], @"Failing on purpose");
  XCTAssertEqual(([self send:@"POST" path:@"Fail" headers:nil body:@{ @"Colour": @1 }].status), 400);
}

// Parameters and results that are any JSON: a dictionary, or what is
// declared Edm.Untyped or Org.OData.JSON.V1.JSON.
- (void)testUntypedOperations
{
  [self serveOperations];
  OISServiceResponse *metadata = [self get:@"$metadata"];
  ODataSchema *schema = [ODataSchema schemaWithData:metadata.data error:NULL];
  ODataSchemaOperation *merge = schema.operations[@"Default.Merge"].firstObject;
  XCTAssertEqualObjects([merge.callerParameters valueForKey:@"type"], (@[ @"Edm.Untyped", @"Collection(Org.OData.JSON.V1.JSON)" ]));
  XCTAssertEqualObjects(merge.returnType, @"Edm.Untyped");
  XCTAssertTrue([metadata.text rangeOfString:@"Namespace=\"Org.OData.JSON.V1\""].location != NSNotFound, @"referenced");
  // 4.0 has no Edm.Untyped: JSON's vocabulary stands in for it.
  OISServiceResponse *old = [self send:@"GET" path:@"$metadata" headers:@{ @"OData-MaxVersion": @"4.0" } body:nil];
  XCTAssertTrue([old.text rangeOfString:@"Edm.Untyped"].location == NSNotFound, @"%@", old.text);
  ODataSchemaOperation *merge40 = [ODataSchema schemaWithData:old.data error:NULL].operations[@"Default.Merge"].firstObject;
  XCTAssertEqualObjects([merge40.callerParameters valueForKey:@"type"],
                        (@[ @"Org.OData.JSON.V1.JSON", @"Collection(Org.OData.JSON.V1.JSON)" ]));
  XCTAssertEqualObjects(merge40.returnType, @"Org.OData.JSON.V1.JSON");
  XCTAssertTrue([old.text rangeOfString:@"Namespace=\"Org.OData.JSON.V1\""].location != NSNotFound, @"referenced");

  OISServiceResponse *merged = [self send:@"POST" path:@"Merge" headers:nil
                                     body:(@{ @"Base": @{ @"a": @1, @"b": @[ @"x", [NSNull null] ] },
                                              @"Changes": @[ @{ @"b": @{ @"deep": @YES } }, @{ @"c": @"new" } ] })];
  XCTAssertEqual(merged.status, 200, @"%@", merged.text);
  XCTAssertEqualObjects(merged.json[@"value"], (@{ @"a": @1, @"b": @{ @"deep": @YES }, @"c": @"new" }));
  XCTAssertEqualObjects(merged.json[@"@odata.context"], @"http://example.test/odata/$metadata#Edm.Untyped");
  XCTAssertEqualObjects([self send:@"POST" path:@"Merge" headers:nil body:@{}].json[@"value"], @{}, @"nothing given");
  XCTAssertEqual(([self send:@"POST" path:@"Merge" headers:nil body:@{ @"Changes": @{ @"a": @1 } }].status), 400,
                 @"a collection is still one");

  OISServiceResponse *object = [self get:@"DescribeShape(Shape=@s)?@s={\"n\":[1,2]}"];
  XCTAssertEqual(object.status, 200, @"%@", object.text);
  XCTAssertEqualObjects(object.json[@"value"], (@{ @"class": @"object", @"shape": @{ @"n": @[ @1, @2 ] } }));
  XCTAssertEqualObjects([self get:@"DescribeShape(Shape=@s)?@s=[true]"].json[@"value"][@"class"], @"array");
  XCTAssertEqualObjects([self get:@"DescribeShape(Shape='text')"].json[@"value"][@"shape"], @"text");
}

- (void)testDeclarationsTheServiceCannotUse
{
  _service.serviceOperations = [[OISBadOperations alloc] init];
  NSArray *problems = _service.operationProblems;
  XCTAssertEqual(problems.count, 3u, @"%@", problems);
  NSString *all = [problems componentsJoinedByString:@"\n"];
  for (NSString *selector in @[ @"mystery:", @"noReply", @"nothing:" ]) {
    XCTAssertTrue([all rangeOfString:selector].location != NSNotFound, @"%@ in %@", selector, all);
  }
  XCTAssertTrue([[self get:@"$metadata"].text rangeOfString:@"Mystery"].location == NSNotFound);
}

// The client, calling the service's operations as it calls any service's.
- (void)testClientCallsOperations
{
  [self serveOperations];
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertNotNil(chai, @"%@", error);

  id discounted = [chai invokeODataOperation:@"DiscountedPriceByPercent" parameters:@{ @"Percent": @10 } error:&error];
  XCTAssertEqualObjects([discounted description], @"16.2", @"%@", error);
  ODataOperationCall *call = [ODataOperationCall callOfOperation:@"CountProductsCheaperThanPrice" inContext:context];
  call.parameters = @{ @"Price": @19 };
  XCTAssertEqualObjects([call invoke:&error], @2, @"%@", error);
  id nothing = [chai invokeODataOperation:@"RaisePriceByPercent" parameters:@{ @"Percent": @50 } error:&error];
  XCTAssertTrue(nothing == nil || nothing == [NSNull null], @"%@", nothing);
  XCTAssertNil(error);
  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  XCTAssertEqualObjects([[self productWithID:1 in:backing] valueForKey:@"unitPrice"], [NSDecimalNumber decimalNumberWithString:@"27"]);
}

#pragma mark $batch

// A multipart $batch body: each unit a request ({method, url, body,
// headers, id}), or an array of them, a change set.
- (NSData *)multipartBatch:(NSArray *)units boundary:(NSString *)boundary
{
  NSMutableString *out = [NSMutableString string];
  NSUInteger changeSets = 0;
  for (id unit in units) {
    NSArray *requests = [unit isKindOfClass:[NSArray class]] ? unit : @[ unit ];
    NSString *into = boundary;
    if ([unit isKindOfClass:[NSArray class]]) {
      into = [NSString stringWithFormat:@"changeset_%lu", (unsigned long)++changeSets];
      [out appendFormat:@"--%@\r\nContent-Type: multipart/mixed; boundary=%@\r\n\r\n", boundary, into];
    }
    for (NSDictionary *request in requests) {
      [out appendFormat:@"--%@\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n", into];
      if (request[@"id"]) [out appendFormat:@"Content-ID: %@\r\n", request[@"id"]];
      [out appendFormat:@"\r\n%@ %@ HTTP/1.1\r\n", request[@"method"], request[@"url"]];
      for (NSString *name in request[@"headers"]) [out appendFormat:@"%@: %@\r\n", name, request[@"headers"][name]];
      NSString *body = @"";
      if (request[@"body"]) {
        body = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:request[@"body"] options:0 error:NULL] encoding:NSUTF8StringEncoding];
        [out appendString:@"Content-Type: application/json\r\n"];
      }
      [out appendFormat:@"\r\n%@\r\n", body];
    }
    if ([unit isKindOfClass:[NSArray class]]) [out appendFormat:@"--%@--\r\n", into];
  }
  [out appendFormat:@"--%@--\r\n", boundary];
  return [out dataUsingEncoding:NSUTF8StringEncoding];
}

- (OISServiceResponse *)postBatch:(NSArray *)units headers:(NSDictionary *)extra
{
  NSURL *url = [NSURL URLWithString:@"http://example.test/odata/$batch"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"multipart/mixed; boundary=batch_1" forHTTPHeaderField:@"Content-Type"];
  for (NSString *name in extra) [request setValue:extra[name] forHTTPHeaderField:name];
  request.HTTPBody = [self multipartBatch:units boundary:@"batch_1"];
  return [self exchange:request];
}

- (OISServiceResponse *)exchange:(NSURLRequest *)request
{
  _finished = dispatch_semaphore_create(0);
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:request target:self action:@selector(exchangeDidFinish:)];
  [_service startExchange:exchange];
  XCTAssertEqual(dispatch_semaphore_wait(_finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))), 0L);
  OISServiceResponse *response = [[OISServiceResponse alloc] init];
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)exchange.URLResponse;
  response.status = http.statusCode;
  response.headers = http.allHeaderFields;
  response.data = exchange.data;
  return response;
}

- (NSArray<ODataBatchPart *> *)partsOf:(OISServiceResponse *)response
{
  NSString *boundary = ODataMultipartBoundary([response header:@"Content-Type"] ?: @"");
  XCTAssertNotNil(boundary, @"%@", [response header:@"Content-Type"]);
  return boundary ? ODataBatchParts(response.data, boundary) : @[];
}

- (id)JSONOf:(ODataBatchPart *)part
{
  return part.body.length ? [NSJSONSerialization JSONObjectWithData:part.body options:0 error:NULL] : nil;
}

- (void)testMultipartBatchWithAChangeSet
{
  OISServiceResponse *r = [self postBatch:@[
    @{ @"method": @"GET", @"url": @"Products(1)" },
    @[ @{ @"method": @"POST", @"url": @"Categories", @"id": @"1", @"body": @{ @"CategoryName": @"Seafood" } },
       @{ @"method": @"POST", @"url": @"$1/Products", @"id": @"2", @"body": @{ @"ProductName": @"Ikura" } },
       @{ @"method": @"PATCH", @"url": @"http://example.test/odata/Products(2)", @"id": @"3", @"body": @{ @"UnitPrice": @20 } } ],
    @{ @"method": @"GET", @"url": @"/odata/Categories(3)/Products?$select=ProductName" },
  ] headers:nil];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray<ODataBatchPart *> *parts = [self partsOf:r];
  XCTAssertEqualObjects([parts valueForKey:@"status"], (@[ @200, @201, @201, @204, @200 ]));
  XCTAssertEqualObjects([self JSONOf:parts[0]][@"ProductName"], @"Chai");
  XCTAssertNil(parts[0].changeSet);
  XCTAssertNotNil(parts[1].changeSet, @"the change set's responses come in a change set of their own");
  XCTAssertEqualObjects([parts valueForKey:@"contentID"][1], @"1");
  XCTAssertEqualObjects([self JSONOf:parts[1]][@"CategoryID"], @3);
  XCTAssertEqualObjects([[self JSONOf:parts[4]][@"value"] valueForKey:@"ProductName"], @[ @"Ikura" ], @"$1 was the new category");
  XCTAssertEqualObjects([self get:@"Products(2)/UnitPrice/$value"].text, @"20");
}

- (void)testFailedChangeSetTakesNoEffect
{
  OISServiceResponse *r = [self postBatch:@[
    @[ @{ @"method": @"POST", @"url": @"Categories", @"id": @"1", @"body": @{ @"CategoryName": @"Seafood" } },
       @{ @"method": @"PATCH", @"url": @"Products(1)", @"id": @"2", @"headers": @{ @"If-Match": @"W/\"stale\"" }, @"body": @{ @"UnitPrice": @1 } } ],
    @{ @"method": @"GET", @"url": @"Categories/$count" },
  ] headers:nil];
  XCTAssertEqual(r.status, 200);
  NSArray<ODataBatchPart *> *parts = [self partsOf:r];
  XCTAssertEqualObjects([parts valueForKey:@"status"], @[ @412 ], @"the failure alone, and the batch stops");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"2", @"the category was not created");

  r = [self postBatch:@[
    @[ @{ @"method": @"POST", @"url": @"Categories", @"id": @"1", @"body": @{ @"CategoryName": @"Seafood" } },
       @{ @"method": @"POST", @"url": @"Products", @"id": @"2", @"body": @{ @"ProductName": @"X", @"Category@odata.bind": @"Categories(99)" } } ],
    @{ @"method": @"GET", @"url": @"Categories/$count" },
    @{ @"method": @"GET", @"url": @"Nothing" },
    @{ @"method": @"GET", @"url": @"Products(1)/ProductName" },
  ] headers:@{ @"Prefer": @"odata.continue-on-error" }];
  parts = [self partsOf:r];
  XCTAssertEqualObjects([parts valueForKey:@"status"], (@[ @400, @200, @404, @200 ]));
  XCTAssertEqualObjects([[NSString alloc] initWithData:parts[1].body encoding:NSUTF8StringEncoding], @"2");
  XCTAssertEqualObjects([r header:@"Preference-Applied"], @"odata.continue-on-error");

  parts = [self partsOf:[self postBatch:@[ @{ @"method": @"GET", @"url": @"Nothing" }, @{ @"method": @"GET", @"url": @"Products(1)" } ] headers:nil]];
  XCTAssertEqualObjects([parts valueForKey:@"status"], @[ @404 ], @"stops at the first failure");
  parts = [self partsOf:[self postBatch:@[ @[ @{ @"method": @"GET", @"url": @"Products(1)" } ] ] headers:nil]];
  XCTAssertEqualObjects([parts valueForKey:@"status"], @[ @400 ], @"no reads in a change set");
}

- (void)testJSONBatch
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/odata/$batch"]];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSDictionary *batch = @{ @"requests": @[
    @{ @"id": @"c", @"atomicityGroup": @"g1", @"method": @"post", @"url": @"Categories", @"body": @{ @"CategoryName": @"Seafood" } },
    @{ @"id": @"p", @"atomicityGroup": @"g1", @"method": @"post", @"url": @"$c/Products", @"body": @{ @"ProductName": @"Ikura" } },
    @{ @"id": @"r", @"method": @"get", @"url": @"Categories(3)/Products/$count" },
    @{ @"id": @"x", @"atomicityGroup": @"g2", @"method": @"post", @"url": @"Categories", @"body": @{ @"CategoryName": @"Grains" } },
    @{ @"id": @"y", @"atomicityGroup": @"g2", @"method": @"patch", @"url": @"Products(1)", @"headers": @{ @"If-Match": @"W/\"stale\"" }, @"body": @{ @"UnitPrice": @1 } },
  ] };
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:batch options:0 error:NULL];
  [request setValue:@"odata.continue-on-error" forHTTPHeaderField:@"Prefer"];
  OISServiceResponse *r = [self exchange:request];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *responses = r.json[@"responses"];
  XCTAssertEqualObjects([responses valueForKey:@"id"], (@[ @"c", @"p", @"r", @"x", @"y" ]));
  XCTAssertEqualObjects([responses valueForKey:@"status"], (@[ @201, @201, @200, @424, @412 ]));
  XCTAssertEqualObjects(responses[1][@"body"][@"ProductName"], @"Ikura");
  XCTAssertEqualObjects(responses[2][@"body"], @"1", @"a text body stays text");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"3", @"g1 saved, g2 not");
}

- (void)testBatchWaitsForHandlersThatAnswerLater
{
  OISLaterProducts *handler = [[OISLaterProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:handler forEntitySet:@"Products"];
  NSArray<ODataBatchPart *> *parts = [self partsOf:[self postBatch:@[
    @{ @"method": @"GET", @"url": @"Products?$select=ProductName" },
    @[ @{ @"method": @"PATCH", @"url": @"Categories(1)", @"body": @{ @"CategoryName": @"Drinks" } } ],
    @{ @"method": @"GET", @"url": @"Products/$count" },
  ] headers:nil]];
  XCTAssertEqualObjects([parts valueForKey:@"status"], (@[ @200, @204, @200 ]));
  XCTAssertEqual([[self JSONOf:parts[0]][@"value"] count], 4u);
  XCTAssertEqual(handler.deferred, 1);
  XCTAssertEqualObjects([self get:@"Categories(1)/CategoryName"].json[@"value"], @"Drinks");
}

// The client's save of several objects is one change set now: a conflict
// leaves none of them saved. (Inserts join it when the client gives the
// keys; by default it POSTs them first, for the service to assign them.)
- (void)testClientSavesAreAtomic
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  NSDictionary *options = @{ ODataIncrementalStoreTransportOption: _service, ODataIncrementalStorePostOnObtainPermanentIDsOption: @NO };
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:options error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  // Read now, so the client's row (and ETag) is from before the change
  // behind its back; a fault fired later may read the row again.
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai");

  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  [[self productWithID:1 in:backing] setValue:@"Chai tea" forKey:@"name"];
  XCTAssertTrue([backing save:&error], @"%@", error);

  NSManagedObject *coffee = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
  [coffee setValue:@70 forKey:@"id"];
  [coffee setValue:@"Ipoh Coffee" forKey:@"name"];
  [chai setValue:[NSDecimalNumber decimalNumberWithString:@"19"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error], @"Chai changed behind the client's back");
  [backing reset];
  XCTAssertNil([self productWithID:70 in:backing], @"and so the new product was not saved either");
  XCTAssertEqualObjects([[self productWithID:1 in:backing] valueForKey:@"unitPrice"], [NSDecimalNumber decimalNumberWithString:@"18"]);
}

// A reference to an entity ($select=ProductID inside another row) carries
// the entity's current ETag. The client keeps the ETag of the row it has,
// so an update from stale values still conflicts, however it learnt that
// the entity exists.
- (void)testReferencesDoNotRefreshTheClientsETag
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai");

  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  [[self productWithID:1 in:backing] setValue:@"Chai tea" forKey:@"name"];
  XCTAssertTrue([backing save:&error], @"%@", error);

  // Chai's stocks come with Chai as a reference, and its new ETag.
  NSSet *stocks = [chai valueForKey:@"stocks"];
  XCTAssertEqual(stocks.count, 1u);
  XCTAssertEqualObjects([stocks.anyObject valueForKeyPath:@"product.objectID"], chai.objectID);

  [chai setValue:[NSDecimalNumber decimalNumberWithString:@"19"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error], @"the name the client has is not the service's");
  [backing reset];
  XCTAssertEqualObjects([[self productWithID:1 in:backing] valueForKey:@"name"], @"Chai tea", @"not overwritten");
}

#pragma mark Timeouts, single properties, references

- (void)testAReplyThatNeverComesIsATimeout
{
  [_service setHandler:[[OISSilentProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  _service.replyTimeout = 0.2;
  OISServiceResponse *r = [self get:@"Products"];
  XCTAssertEqual(r.status, 504);
  XCTAssertTrue([r.json[@"error"][@"message"] length] > 0);
}

- (OISServiceResponse *)send:(NSString *)method path:(NSString *)path type:(NSString *)type text:(NSString *)text
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"http://example.test/odata/" stringByAppendingString:path]]];
  request.HTTPMethod = method;
  [request setValue:type forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = [text dataUsingEncoding:NSUTF8StringEncoding];
  return [self exchange:request];
}

- (OISServiceResponse *)send:(NSString *)method path:(NSString *)path headers:(NSDictionary *)headers data:(NSData *)data
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"http://example.test/odata/" stringByAppendingString:path]]];
  request.HTTPMethod = method;
  for (NSString *name in headers) [request setValue:headers[name] forHTTPHeaderField:name];
  request.HTTPBody = data;
  return [self exchange:request];
}

// Photos: a media entity (its content, and the content type it was put
// with) with a stream property, Thumbnail, of its own.
- (NSManagedObjectModel *)albumModel
{
  NSEntityDescription *photo = [[NSEntityDescription alloc] init];
  photo.name = @"Photo";
  photo.managedObjectClassName = @"NSManagedObject";
  photo.userInfo = @{ @"OData.entitySet": @"Photos", @"OData.mediaStream": @"content" };
  NSAttributeDescription *identifier = OISSwatchAttribute(@"id", NSInteger32AttributeType, nil);
  identifier.userInfo = @{ @"OData.key": @"YES" };
  NSAttributeDescription *content = OISSwatchAttribute(@"content", NSBinaryDataAttributeType, nil);
  content.userInfo = @{ @"OData.contentType": @"contentType" };
  NSAttributeDescription *thumbnail = OISSwatchAttribute(@"thumbnail", NSBinaryDataAttributeType, nil);
  thumbnail.userInfo = @{ @"OData.stream": @"YES", @"OData.contentType": @"thumbnailType" };
  photo.properties = @[ identifier, OISSwatchAttribute(@"name", NSStringAttributeType, nil), content,
                        OISSwatchAttribute(@"contentType", NSStringAttributeType, nil), thumbnail,
                        OISSwatchAttribute(@"thumbnailType", NSStringAttributeType, nil) ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ photo ];
  return model;
}

- (void)serveAlbumInStoreOfType:(NSString *)storeType
{
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self albumModel]];
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_storeFiles addObject:url];
  }
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

// Media entities and stream properties (Part 1 sections 11.1.2, 11.4.7).
- (void)testStreams
{
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType ]) {
    [self serveAlbumInStoreOfType:storeType];
    NSString *metadata = [self get:@"$metadata"].text;
    XCTAssertTrue([metadata containsString:@"<EntityType Name=\"Photo\" HasStream=\"true\">"], @"%@", metadata);
    XCTAssertTrue([metadata containsString:@"<Property Name=\"Thumbnail\" Type=\"Edm.Stream\""], @"%@", metadata);
    XCTAssertFalse([metadata containsString:@"\"ContentType\""], @"the stream's, not a property");
    XCTAssertFalse([metadata containsString:@"\"Content\""]);

    // A new media entity, its stream the body.
    const uint8_t bytes[] = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff };
    NSData *png = [NSData dataWithBytes:bytes length:sizeof bytes];
    OISServiceResponse *created = [self send:@"POST" path:@"Photos" headers:@{ @"Content-Type": @"image/png" } data:png];
    XCTAssertEqual(created.status, 201, @"%@: %@", storeType, created.text);
    XCTAssertEqualObjects(created.json[@"Id"], @1);
    XCTAssertEqualObjects(created.json[@"@odata.mediaContentType"], @"image/png");
    NSString *etag = created.json[@"@odata.mediaEtag"];
    XCTAssertNotNil(etag);
    XCTAssertNil(created.json[@"Content"]);
    XCTAssertNil(created.json[@"Thumbnail@odata.mediaEtag"], @"no thumbnail yet");

    OISServiceResponse *media = [self get:@"Photos(1)/$value"];
    XCTAssertEqual(media.status, 200);
    XCTAssertEqualObjects(media.data, png);
    XCTAssertEqualObjects([media header:@"Content-Type"], @"image/png");
    XCTAssertEqualObjects([media header:@"ETag"], etag);
    XCTAssertEqual(([self send:@"GET" path:@"Photos(1)/$value" headers:@{ @"If-None-Match": etag } data:nil].status), 304);

    // The other properties, by PATCH.
    XCTAssertEqual(([self send:@"PATCH" path:@"Photos(1)" headers:nil body:@{ @"Name": @"Sunset" }].status), 204);
    XCTAssertEqual(([self send:@"PATCH" path:@"Photos(1)" headers:nil body:@{ @"Thumbnail": @"AAAA" }].status), 400, @"a stream is not in a body");
    XCTAssertEqual(([self send:@"PATCH" path:@"Photos(1)" headers:nil body:@{ @"ContentType": @"text/plain" }].status), 400);

    // Replaced, with the media ETag.
    NSData *jpeg = [@"JFIF pretend" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual(([self send:@"PUT" path:@"Photos(1)/$value" headers:@{ @"Content-Type": @"image/jpeg", @"If-Match": @"W/\"stale\"" } data:jpeg].status), 412);
    OISServiceResponse *put = [self send:@"PUT" path:@"Photos(1)/$value" headers:@{ @"Content-Type": @"image/jpeg", @"If-Match": etag } data:jpeg];
    XCTAssertEqual(put.status, 204, @"%@: %@", storeType, put.text);
    XCTAssertNotEqualObjects([put header:@"ETag"], etag);
    XCTAssertEqualObjects([self get:@"Photos(1)/$value"].data, jpeg);
    XCTAssertEqualObjects([self get:@"Photos(1)"].json[@"@odata.mediaContentType"], @"image/jpeg");
    XCTAssertEqualObjects([self get:@"Photos(1)"].json[@"Name"], @"Sunset", @"the rest as it was");

    // A stream property.
    XCTAssertEqual([self get:@"Photos(1)/Thumbnail"].status, 204, @"none yet");
    XCTAssertEqual(([self send:@"PUT" path:@"Photos(1)/Thumbnail" headers:@{ @"Content-Type": @"image/gif" } data:png].status), 204);
    OISServiceResponse *thumbnail = [self get:@"Photos(1)/Thumbnail"];
    XCTAssertEqualObjects(thumbnail.data, png);
    XCTAssertEqualObjects([thumbnail header:@"Content-Type"], @"image/gif");
    NSDictionary *row = [self get:@"Photos(1)"].json;
    XCTAssertEqualObjects(row[@"Thumbnail@odata.mediaEtag"], [thumbnail header:@"ETag"]);
    XCTAssertEqualObjects(row[@"Thumbnail@odata.mediaContentType"], @"image/gif");
    XCTAssertNil(row[@"Thumbnail"]);
    NSDictionary *full = [self send:@"GET" path:@"Photos(1)" headers:@{ @"Accept": @"application/json;odata.metadata=full" } data:nil].json;
    XCTAssertEqualObjects(full[@"Thumbnail@odata.mediaReadLink"], @"Photos(1)/Thumbnail");
    XCTAssertEqualObjects(full[@"@odata.mediaEditLink"], @"Photos(1)/$value");
    XCTAssertEqual(([self send:@"DELETE" path:@"Photos(1)/Thumbnail" headers:nil data:nil].status), 204);
    XCTAssertEqual([self get:@"Photos(1)/Thumbnail"].status, 204);
    XCTAssertEqual(([self send:@"DELETE" path:@"Photos(1)/$value" headers:nil data:nil].status), 405, @"a media entity is deleted whole");
    XCTAssertEqual([self get:@"Photos(1)/Content"].status, 404);
    XCTAssertEqual(([self send:@"DELETE" path:@"Photos(1)" headers:nil data:nil].status), 204);
  }
}

// Answers a stream transfer's action.
- (void)transferDidFinish:(ODataStreamTransfer *)transfer
{
  _finishedTransfer = transfer;
}

// The client's streams, over the service: a media entity made from a file,
// its stream downloaded and kept, a stream property put and emptied.
// A service that answers an upload with the entity, not an ETag header:
// the media ETag is the entity's, and the file is kept at it.
- (void)testUploadAnsweredWithTheEntity
{
  [self serveAlbumInStoreOfType:NSInMemoryStoreType];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  [ODataIncrementalStore registerStore];
  OISEntityAnsweringTransport *answering = [[OISEntityAnsweringTransport alloc] init];
  answering.next = _service;
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = answering;
  NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
  [_storeFiles addObject:directory];
  [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:(@{ ODataIncrementalStoreTransportOption: transport,
                                                         ODataIncrementalStoreStreamDirectoryOption: directory }) error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSURL *first = [directory URLByAppendingPathComponent:@"first.png"];
  NSURL *second = [directory URLByAppendingPathComponent:@"second.png"];
  XCTAssertTrue([[@"first" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:first atomically:YES]);
  XCTAssertTrue([[@"second" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:second atomically:YES]);
  ODataStreamTransfer *create = [[ODataStreamTransfer alloc] initWithEntityName:@"Photo" context:context];
  XCTAssertTrue([create uploadFile:first contentType:@"image/png" error:&error], @"%@", error);

  ODataStreamTransfer *media = [[ODataStreamTransfer alloc] initWithObject:create.object stream:nil];
  NSString *before = media.mediaETag;
  XCTAssertTrue([media uploadFile:second contentType:@"image/png" error:&error], @"%@", error);
  NSString *now = [self get:@"Photos(1)"].json[@"@odata.mediaEtag"];
  XCTAssertEqualObjects(media.mediaETag, now, @"the entity's media ETag");
  XCTAssertNotEqualObjects(now, before);
  NSUInteger requests = transport.requests.count;
  NSURL *downloaded = [[[ODataStreamTransfer alloc] initWithObject:create.object stream:nil] download:&error];
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:downloaded], [@"second" dataUsingEncoding:NSUTF8StringEncoding]);
  XCTAssertEqual(transport.requests.count, requests, @"kept at that ETag, not asked again");
}

- (void)testStreamsThroughTheStore
{
  [self serveAlbumInStoreOfType:NSInMemoryStoreType];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  NSEntityDescription *photoEntity = model.entitiesByName[@"Photo"];
  XCTAssertNil(photoEntity.attributesByName[@"thumbnail"], @"a stream is not an attribute");
  [ODataIncrementalStore registerStore];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
  [_storeFiles addObject:directory];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:(@{ ODataIncrementalStoreTransportOption: transport,
                                                         ODataIncrementalStoreStreamDirectoryOption: directory }) error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSData *png = [@"PNG pretend" dataUsingEncoding:NSUTF8StringEncoding];
  NSURL *file = [directory URLByAppendingPathComponent:@"upload.png"];
  [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
  XCTAssertTrue([png writeToURL:file atomically:YES]);

  // A new media entity, made by its stream; the rest saved after.
  ODataStreamTransfer *create = [[ODataStreamTransfer alloc] initWithEntityName:@"Photo" context:context];
  XCTAssertTrue([create uploadFile:file contentType:@"image/png" error:&error], @"%@", error);
  NSManagedObject *photo = create.object;
  XCTAssertEqualObjects([photo valueForKey:@"id"], @1);
  XCTAssertEqualObjects(create.contentType, @"image/png");
  XCTAssertNotNil(create.mediaETag);
  [photo setValue:@"Sunset" forKey:@"name"];
  XCTAssertTrue([context save:&error], @"%@", error);
  XCTAssertEqualObjects([self get:@"Photos(1)/Name"].json[@"value"], @"Sunset");

  // Downloaded once, then kept while its media ETag is current.
  ODataStreamTransfer *media = [[ODataStreamTransfer alloc] initWithObject:photo stream:nil];
  NSURL *downloaded = [media download:&error];
  XCTAssertNotNil(downloaded, @"%@", error);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:downloaded], png);
  NSUInteger before = transport.requests.count;
  XCTAssertEqualObjects([[[ODataStreamTransfer alloc] initWithObject:photo stream:nil] download:&error], downloaded);
  XCTAssertEqual(transport.requests.count, before, @"not asked again");

  // A stream property, by its name in $metadata (in any case).
  NSData *gif = [@"GIF pretend" dataUsingEncoding:NSUTF8StringEncoding];
  NSURL *small = [directory URLByAppendingPathComponent:@"small.gif"];
  XCTAssertTrue([gif writeToURL:small atomically:YES]);
  ODataStreamTransfer *thumbnail = [[ODataStreamTransfer alloc] initWithObject:photo stream:@"thumbnail"];
  XCTAssertTrue([thumbnail uploadFile:small contentType:@"image/gif" error:&error], @"%@", error);
  XCTAssertEqualObjects([self get:@"Photos(1)/Thumbnail"].data, gif);
  XCTAssertEqualObjects(thumbnail.mediaETag, [[self get:@"Photos(1)/Thumbnail"] header:@"ETag"]);

  // Not waiting: the action comes with the file.
  [context refreshObject:photo mergeChanges:NO];
  ODataStreamTransfer *later = [[ODataStreamTransfer alloc] initWithObject:photo stream:@"Thumbnail"];
  _finishedTransfer = nil;
  [later downloadWithTarget:self action:@selector(transferDidFinish:)];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while (!_finishedTransfer && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  XCTAssertEqual(_finishedTransfer, later);
  XCTAssertNil(later.error);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:later.fileURL], gif);
  XCTAssertEqualObjects(later.contentType, @"image/gif");

  XCTAssertTrue([thumbnail remove:&error], @"%@", error);
  XCTAssertNil([[[ODataStreamTransfer alloc] initWithObject:photo stream:@"Thumbnail"] download:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorNoStream);
  XCTAssertFalse([[[ODataStreamTransfer alloc] initWithObject:photo stream:nil] remove:&error]);
  XCTAssertFalse([[[ODataStreamTransfer alloc] initWithObject:photo stream:@"Nothing"] download:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorNoStream);
}

- (void)testWritingOneProperty
{
  OISServiceResponse *put = [self send:@"PUT" path:@"Products(1)/ProductName" headers:nil body:@{ @"value": @"Chai tea" }];
  XCTAssertEqual(put.status, 204, @"%@", put.text);
  XCTAssertNotNil([put header:@"ETag"]);
  XCTAssertEqualObjects([self get:@"Products(1)/ProductName"].json[@"value"], @"Chai tea");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)/UnitPrice" headers:nil body:@{ @"value": @"18.5" }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(1)/UnitPrice/$value"].text, @"18.5");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/UnitPrice/$value" type:@"text/plain" text:@"20"].status), 204);
  XCTAssertEqualObjects([self get:@"Products(1)/UnitPrice/$value"].text, @"20");
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)/QuantityPerUnit" headers:nil body:nil].status), 204);
  XCTAssertEqual([self get:@"Products(1)/QuantityPerUnit"].status, 204, @"null now");

  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/ProductID" headers:nil body:@{ @"value": @9 }].status), 400, @"keys do not change");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/UnitPrice" headers:nil body:@{ @"value": @"cheap" }].status), 400);
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/UnitPrice" headers:nil body:@{ @"price": @1 }].status), 400);
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)/ProductName" headers:nil body:nil].status), 400, @"a required property");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/ProductName" headers:@{ @"If-Match": @"W/\"stale\"" } body:@{ @"value": @"x" }].status), 412);
}

- (void)testReferences
{
  OISServiceResponse *ref = [self get:@"Products(1)/Category/$ref"];
  XCTAssertEqual(ref.status, 200, @"%@", ref.text);
  XCTAssertEqualObjects(ref.json[@"@odata.id"], @"Categories(1)");
  XCTAssertEqualObjects(ref.json[@"@odata.context"], @"http://example.test/odata/$metadata#$ref");

  OISServiceResponse *list = [self get:@"Categories(1)/Products/$ref"];
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *each in list.json[@"value"]) [ids addObject:each[@"@odata.id"]];
  XCTAssertEqualObjects(ids, (@[ @"Products(1)", @"Products(2)" ]));
  XCTAssertEqualObjects(list.json[@"@odata.context"], @"http://example.test/odata/$metadata#Collection($ref)");

  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/Category/$ref" headers:nil
                        body:@{ @"@odata.id": @"http://example.test/odata/Categories(2)" }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(1)/Category/CategoryName"].json[@"value"], @"Condiments");
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)/Category/$ref" headers:nil body:nil].status), 204);
  XCTAssertEqual([self get:@"Products(1)/Category"].status, 204, @"no category now");
  XCTAssertEqual([self get:@"Products(1)/Category/$ref"].status, 204);

  XCTAssertEqual(([self send:@"POST" path:@"Suppliers(2)/Products/$ref" headers:nil body:@{ @"@odata.id": @"Products(1)" }].status), 204);
  XCTAssertEqualObjects([self get:@"Suppliers(2)/Products/$count"].text, @"3");
  XCTAssertEqual(([self send:@"DELETE" path:@"Suppliers(2)/Products/$ref?$id=http://example.test/odata/Products(1)" headers:nil body:nil].status), 204);
  XCTAssertEqual(([self send:@"DELETE" path:@"Suppliers(2)/Products(4)/$ref" headers:nil body:nil].status), 204);
  XCTAssertEqualObjects([self get:@"Suppliers(2)/Products/$count"].text, @"1");
  XCTAssertEqualObjects([self get:@"Products(4)/ProductName"].json[@"value"], @"Chef Anton's Cajun Seasoning", @"the product stays");

  XCTAssertEqual(([self send:@"DELETE" path:@"Suppliers(2)/Products/$ref?$id=Products(1)" headers:nil body:nil].status), 404, @"not a member");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/Category/$ref" headers:nil body:@{ @"@odata.id": @"Suppliers(1)" }].status), 400);
  XCTAssertEqual(([self send:@"POST" path:@"Products(1)/Category/$ref" headers:nil body:@{ @"@odata.id": @"Categories(1)" }].status), 405);
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/$ref" headers:nil body:@{ @"@odata.id": @"Products(2)" }].status), 405);
  XCTAssertEqualObjects([self get:@"Products(3)/$ref"].json[@"@odata.id"], @"Products(3)");
}

// What the client sends for a changed relationship, $ref requests, the
// service now takes.
- (void)testClientChangesRelationships
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  NSFetchRequest *condiments = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  condiments.predicate = [NSPredicate predicateWithFormat:@"name == 'Condiments'"];
  [chai setValue:[[context executeFetchRequest:condiments error:&error] firstObject] forKey:@"category"];
  NSFetchRequest *cajun = [NSFetchRequest fetchRequestWithEntityName:@"Supplier"];
  cajun.predicate = [NSPredicate predicateWithFormat:@"city == 'New Orleans'"];
  [[chai mutableSetValueForKey:@"suppliers"] addObject:[[context executeFetchRequest:cajun error:&error] firstObject]];
  XCTAssertTrue([context save:&error], @"%@", error);

  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  NSManagedObject *saved = [self productWithID:1 in:backing];
  XCTAssertEqualObjects([saved valueForKeyPath:@"category.name"], @"Condiments");
  XCTAssertEqualObjects([[saved valueForKey:@"suppliers"] valueForKey:@"city"], ([NSSet setWithObjects:@"London", @"New Orleans", nil]));
}

- (void)testComposingOnFunctions
{
  [self serveOperations];
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:&error];
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Default.Product"];
  XCTAssertTrue([schema operationNamed:@"PricierThanPrice" boundToEntityType:product collection:YES parameterNames:nil].isComposable);

  OISServiceResponse *r = [self get:@"Products/Default.PricierThanPrice(Price=10)?$filter=startswith(ProductName,'Ch')&$orderby=UnitPrice desc&$top=2&$count=true"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([self names:r], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects(r.json[@"@odata.count"], @4, @"Chai, Chang and both of Chef Anton's");
  XCTAssertEqualObjects([self get:@"Products/Default.PricierThanPrice(Price=20)/$count"].text, @"2");
  XCTAssertEqualObjects([self get:@"Categories(1)/Products/Default.PricierThanPrice(Price=18)/$count"].text, @"1");

  XCTAssertEqualObjects([self get:@"Products(4)/Default.CheapestInCategory()/ProductName"].json[@"value"], @"Aniseed Syrup");
  XCTAssertEqualObjects([self get:@"Products(4)/Default.CheapestInCategory()/Category/CategoryName"].json[@"value"], @"Condiments");
  OISServiceResponse *selected = [self get:@"Products(4)/Default.CheapestInCategory()?$select=UnitPrice&$expand=Category($select=CategoryName)"];
  XCTAssertEqualObjects(selected.json[@"Category"][@"CategoryName"], @"Condiments");
  XCTAssertNil(selected.json[@"ProductName"]);

  XCTAssertEqual([self get:@"CountProductsCheaperThanPrice(Price=19)/Foo"].status, 400, @"a value cannot be read on from");
  XCTAssertEqual(([self send:@"POST" path:@"Products(1)/Default.RaisePriceByPercent/Category" headers:nil body:@{ @"Percent": @1 }].status), 400);
}

#pragma mark Derived types and $levels

// A model of its own, made here since the Catalog has neither inheritance
// nor a relationship to its own entity: employees, managers among them
// (and executives among those, though there are none yet), each with a
// manager and reports.
- (void)serveStaff
{
  [self serveStaffInStoreOfType:NSInMemoryStoreType];
}

- (void)serveStaffInStoreOfType:(NSString *)storeType
{
  NSEntityDescription *employee = [[NSEntityDescription alloc] init];
  employee.name = @"Employee";
  employee.managedObjectClassName = @"NSManagedObject";
  NSEntityDescription *manager = [[NSEntityDescription alloc] init];
  manager.name = @"Manager";
  manager.managedObjectClassName = @"NSManagedObject";
  NSEntityDescription *executive = [[NSEntityDescription alloc] init];
  executive.name = @"Executive";
  executive.managedObjectClassName = @"NSManagedObject";

  NSAttributeDescription *identifier = [[NSAttributeDescription alloc] init];
  identifier.name = @"id";
  identifier.attributeType = NSInteger32AttributeType;
  identifier.optional = NO;
  NSAttributeDescription *name = [[NSAttributeDescription alloc] init];
  name.name = @"name";
  name.attributeType = NSStringAttributeType;
  name.optional = YES;
  NSAttributeDescription *hired = [[NSAttributeDescription alloc] init];
  hired.name = @"hired";
  hired.attributeType = NSDateAttributeType;
  hired.optional = YES;
  NSAttributeDescription *budget = [[NSAttributeDescription alloc] init];
  budget.name = @"budget";
  budget.attributeType = NSDecimalAttributeType;
  budget.optional = YES;
  NSRelationshipDescription *boss = [[NSRelationshipDescription alloc] init];
  boss.name = @"manager";
  boss.destinationEntity = employee;
  boss.maxCount = 1;
  boss.optional = YES;
  NSRelationshipDescription *reports = [[NSRelationshipDescription alloc] init];
  reports.name = @"reports";
  reports.destinationEntity = employee;
  reports.maxCount = 0;
  reports.optional = YES;
  boss.inverseRelationship = reports;
  reports.inverseRelationship = boss;
  employee.properties = @[ identifier, name, hired, boss, reports ];
  manager.properties = @[ budget ];
  manager.subentities = @[ executive ];
  employee.subentities = @[ manager ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ employee, manager, executive ];
  for (NSString *configuration in _staffConfigurations) {
    NSMutableArray *entities = [NSMutableArray array];
    for (NSString *entity in _staffConfigurations[configuration]) [entities addObject:model.entitiesByName[entity]];
    [model setEntities:entities forConfiguration:configuration];
  }

  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_storeFiles addObject:url];
  }
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  // Ann manages Bob, who manages Cy and Di (hired when, no one knows).
  NSManagedObject *ann = [self insert:@"Manager" into:context values:@{ @"id": @1, @"name": @"Ann", @"budget": [NSDecimalNumber decimalNumberWithString:@"5000"],
                                                                        @"hired": ODataDateFromString(@"2019-06-01T09:00:00Z") }];
  NSManagedObject *bob = [self insert:@"Manager" into:context values:@{ @"id": @2, @"name": @"Bob", @"budget": [NSDecimalNumber decimalNumberWithString:@"800"], @"manager": ann,
                                                                        @"hired": ODataDateFromString(@"2024-12-31T23:30:00Z") }];
  [self insert:@"Employee" into:context values:@{ @"id": @3, @"name": @"Cy", @"manager": bob, @"hired": ODataDateFromString(@"2025-01-01T00:00:00Z") }];
  [self insert:@"Employee" into:context values:@{ @"id": @4, @"name": @"Di", @"manager": bob }];
  XCTAssertTrue([context save:&error], @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

- (NSArray *)employeeNames:(OISServiceResponse *)response
{
  return [response.json[@"value"] valueForKey:@"Name"];
}

- (void)testTypeCasts
{
  [self serveStaff];
  OISServiceResponse *managers = [self get:@"Employees/Default.Manager"];
  XCTAssertEqual(managers.status, 200, @"%@", managers.text);
  XCTAssertEqualObjects([self employeeNames:managers], (@[ @"Ann", @"Bob" ]));
  XCTAssertEqualObjects(managers.json[@"@odata.context"], @"http://example.test/odata/$metadata#Employees/Default.Manager");
  XCTAssertEqualObjects([self get:@"Employees/Default.Manager/$count"].text, @"2");
  XCTAssertEqualObjects([self employeeNames:[self get:@"Employees/Default.Manager?$filter=Budget gt 1000"]], @[ @"Ann" ]);
  XCTAssertEqualObjects([self get:@"Employees(2)/Default.Manager/Budget"].json[@"value"], @800);
  XCTAssertEqual([self get:@"Employees(3)/Default.Manager"].status, 404, @"Cy manages no one");
  XCTAssertEqual([self get:@"Employees/Default.Nobody"].status, 404);

  OISServiceResponse *all = [self get:@"Employees?$select=Name,Default.Manager/Budget"];
  NSArray *rows = all.json[@"value"];
  XCTAssertEqualObjects(rows[0][@"Budget"], @5000);
  XCTAssertNil(rows[2][@"Budget"], @"an employee who is not a manager has none");
  XCTAssertEqualObjects(rows[2][@"@odata.type"], nil, @"the set's own type needs no @odata.type");
  XCTAssertEqualObjects(rows[0][@"@odata.type"], @"#Default.Manager");

  OISServiceResponse *created = [self send:@"POST" path:@"Employees/Default.Manager" headers:nil body:@{ @"Name": @"Eve", @"Budget": @100 }];
  XCTAssertEqual(created.status, 201, @"%@", created.text);
  XCTAssertEqualObjects(created.json[@"@odata.context"], @"http://example.test/odata/$metadata#Employees/Default.Manager/$entity",
                        @"the context names the type, so minimal metadata needs no @odata.type");
  XCTAssertEqualObjects(created.json[@"Budget"], @100);
  XCTAssertEqualObjects([self get:@"Employees/Default.Manager/$count"].text, @"3", @"created as the cast's type");
}

- (NSArray *)sortedEmployeeNames:(NSString *)path
{
  OISServiceResponse *response = [self get:path];
  XCTAssertEqual(response.status, 200, @"%@: %@", path, response.text);
  return [[self employeeNames:response] sortedArrayUsingSelector:@selector(compare:)];
}

- (void)testTypeCastsAndIsOfInFilters
{
  // Each store asks an object's type its own way: SQL, or the predicate
  // evaluated on its nodes, or on objects.
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType, NSXMLStoreType ]) {
    [self serveStaffInStoreOfType:storeType];
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
    context.persistentStoreCoordinator = _coordinator;
    NSFetchRequest *annRequest = [NSFetchRequest fetchRequestWithEntityName:@"Employee"];
    annRequest.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
    NSManagedObject *ann = [[context executeFetchRequest:annRequest error:NULL] firstObject];
    [self insert:@"Executive" into:context values:@{ @"id": @5, @"name": @"Zed", @"budget": [NSDecimalNumber decimalNumberWithString:@"100"], @"manager": ann }];
    NSError *error = nil;
    XCTAssertTrue([context save:&error], @"%@", error);

    NSDictionary *expected = @{
      @"isof(Default.Manager)": @[ @"Ann", @"Bob", @"Zed" ],
      @"isof(Default.Executive)": @[ @"Zed" ],
      @"isof(Default.Employee)": @[ @"Ann", @"Bob", @"Cy", @"Di", @"Zed" ],
      @"isof('Default.Executive')": @[ @"Zed" ],
      @"not isof(Default.Manager)": @[ @"Cy", @"Di" ],
      @"isof(Manager,Default.Manager)": @[ @"Bob", @"Cy", @"Di", @"Zed" ],
      @"Default.Manager/Budget gt 500": @[ @"Ann", @"Bob" ],
      @"Default.Manager/Budget eq null": @[ @"Cy", @"Di" ],
      @"Default.Manager/Budget ne 800": @[ @"Ann", @"Cy", @"Di", @"Zed" ],
      @"Default.Manager/Budget in (800,100)": @[ @"Bob", @"Zed" ],
      @"Default.Employee/Name eq 'Ann'": @[ @"Ann" ],
      @"Manager/Default.Manager/Budget lt 1000": @[ @"Cy", @"Di" ],
      @"Name eq 'Cy' or Default.Manager/Budget ge 5000": @[ @"Ann", @"Cy" ],
      @"Reports/Default.Manager/any(m:m/Budget lt 1000)": @[ @"Ann" ],
      @"Reports/Default.Executive/any()": @[ @"Ann" ],
      @"Reports/Default.Manager/$count eq 2": @[ @"Ann" ],
      @"Reports/any(r:isof(r,Default.Manager))": @[ @"Ann" ],
      @"Reports/all(r:isof(r,Default.Manager))": @[ @"Ann", @"Cy", @"Di", @"Zed" ],
      @"cast(Manager,Default.Manager)/Budget gt 1000": @[ @"Bob", @"Zed" ],
      @"cast(Manager,Default.Manager) eq null": @[ @"Ann" ],
      @"cast(Default.Manager)/Budget lt 1000": @[ @"Bob", @"Zed" ],
    };
    for (NSString *filter in expected) {
      NSString *path = [@"Employees?$filter=" stringByAppendingString:filter];
      XCTAssertEqualObjects([self sortedEmployeeNames:path], expected[filter], @"%@: %@", storeType, filter);
    }
    XCTAssertEqualObjects([self get:@"Employees/$count?$filter=isof(Default.Manager)"].text, @"3", @"%@", storeType);
    OISServiceResponse *expanded = [self get:@"Employees(1)?$expand=Reports($filter=isof(Default.Executive))"];
    XCTAssertEqualObjects([expanded.json[@"Reports"] valueForKey:@"Name"], @[ @"Zed" ], @"%@: %@", storeType, expanded.text);

    // Sorted here: the cast is null for an Employee that is no Manager,
    // and nulls come first.
    OISServiceResponse *byBudget = [self get:@"Employees?$orderby=Default.Manager/Budget"];
    XCTAssertEqual(byBudget.status, 200, @"%@: %@", storeType, byBudget.text);
    NSArray *managers = [self sortedEmployeeNames:@"Employees?$filter=isof(Default.Manager)"];
    NSArray *names = [byBudget.json[@"value"] valueForKey:@"Name"];
    XCTAssertEqual(names.count, 5u, @"%@", byBudget.text);
    for (NSUInteger i = 0; i < names.count; i++) {
      XCTAssertEqual([managers containsObject:names[i]], i >= names.count - managers.count, @"%@: %@", storeType, names);
    }
    XCTAssertEqualObjects([self get:@"Employees/$count?$filter=isof(Name,Edm.String)"].text, @"5", @"%@: its own type", storeType);
    XCTAssertEqual([self get:@"Employees?$filter=isof(Default.Nobody)"].status, 400);
    XCTAssertEqual([self get:@"Employees?$filter=Default.Manager/Nothing eq 1"].status, 400);
    XCTAssertEqual([self get:@"Employees?$filter=isof(Reports,Default.Manager)"].status, 400, @"a collection");
  }
}

- (void)testLevels
{
  [self serveStaff];
  OISServiceResponse *two = [self get:@"Employees(1)?$select=Name&$expand=Reports($select=Name;$levels=2)"];
  XCTAssertEqual(two.status, 200, @"%@", two.text);
  NSDictionary *bob = [two.json[@"Reports"] firstObject];
  XCTAssertEqualObjects(bob[@"Name"], @"Bob");
  XCTAssertEqualObjects([[bob[@"Reports"] valueForKey:@"Name"] sortedArrayUsingSelector:@selector(compare:)], (@[ @"Cy", @"Di" ]));
  XCTAssertNil([bob[@"Reports"] firstObject][@"Reports"], @"two levels, no more");

  OISServiceResponse *max = [self get:@"Employees(4)?$expand=Manager($levels=max)"];
  XCTAssertEqualObjects(max.json[@"Manager"][@"Name"], @"Bob");
  XCTAssertEqualObjects(max.json[@"Manager"][@"Manager"][@"Name"], @"Ann", @"to the top");
  XCTAssertEqualObjects(max.json[@"Manager"][@"Manager"][@"Manager"], [NSNull null]);

  OISServiceResponse *one = [self get:@"Employees(1)?$expand=Reports($levels=1)"];
  XCTAssertNil([one.json[@"Reports"] firstObject][@"Reports"]);
}

#pragma mark Deep inserts

- (void)testDeepInsert
{
  OISServiceResponse *category = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Seafood",
    @"Products": @[ @{ @"ProductName": @"Ikura", @"UnitPrice": @31 }, @{ @"ProductName": @"Konbu", @"UnitPrice": @6 } ] }];
  XCTAssertEqual(category.status, 201, @"%@", category.text);
  XCTAssertEqualObjects(category.json[@"CategoryID"], @3);
  NSArray *products = category.json[@"Products"];
  XCTAssertEqualObjects([[products valueForKey:@"ProductName"] sortedArrayUsingSelector:@selector(compare:)], (@[ @"Ikura", @"Konbu" ]),
                        @"what was created comes back expanded");
  XCTAssertEqualObjects([[products valueForKey:@"ProductID"] sortedArrayUsingSelector:@selector(compare:)], (@[ @6, @7 ]));
  XCTAssertEqualObjects([self get:@"Categories(3)/Products/$count"].text, @"2");

  OISServiceResponse *product = [self send:@"POST" path:@"Products" headers:nil body:@{
    @"ProductName": @"Tofu", @"Category": @{ @"CategoryName": @"Produce" }, @"Suppliers@odata.bind": @[ @"Suppliers(1)" ] }];
  XCTAssertEqual(product.status, 201, @"%@", product.text);
  XCTAssertEqualObjects(product.json[@"Category"][@"CategoryName"], @"Produce");
  XCTAssertEqualObjects([self get:@"Products(8)/Category/CategoryID"].json[@"value"], @4);
  XCTAssertEqualObjects([self get:@"Products(8)/Suppliers/$count"].text, @"1");

  OISServiceResponse *deep = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Confections",
    @"Products": @[ @{ @"ProductName": @"Teatime Biscuits",
                       @"Stocks": @[ @{ @"StockID": @9, @"Quantity": @5, @"Location@odata.bind": @"Locations(1)" } ] } ] }];
  XCTAssertEqual(deep.status, 201, @"%@", deep.text);
  XCTAssertEqualObjects([deep.json[@"Products"] firstObject][@"Stocks"][0][@"Quantity"], @5, @"three levels down");
  XCTAssertEqualObjects([self get:@"Stocks(9)/Location/LocationName"].json[@"value"], @"Warehouse");

  OISServiceResponse *bad = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Grains", @"Products": @[ @{ @"ProductName": @"Rice", @"UnitPrice": @"cheap" } ] }];
  XCTAssertEqual(bad.status, 400);
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"5", @"nothing of it was saved");
  XCTAssertEqual(([self send:@"POST" path:@"Categories" headers:nil body:@{ @"CategoryName": @"G", @"Products": @{ @"ProductName": @"R" } }].status), 400,
                 @"a to-many takes an array");
}

// Nested entities whose handler answers later: the write stops at each,
// and goes on from the top when it answers, doing nothing twice.
- (void)testDeepWritesThroughHandlersThatAnswerLater
{
  OISLaterWrites *products = [[OISLaterWrites alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:products forEntitySet:@"Products"];
  OISServiceResponse *category = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Seafood",
    @"Products": @[ @{ @"ProductName": @"Ikura", @"UnitPrice": @31 }, @{ @"ProductName": @"Konbu", @"UnitPrice": @6 } ] }];
  XCTAssertEqual(category.status, 201, @"%@", category.text);
  XCTAssertEqual(products.inserts, 2, @"each asked once");
  XCTAssertEqualObjects([[category.json[@"Products"] valueForKey:@"ProductName"] sortedArrayUsingSelector:@selector(compare:)], (@[ @"Ikura", @"Konbu" ]));
  XCTAssertEqualObjects([self get:@"Categories(3)/Products/$count"].text, @"2");

  // A deep update: Ikura changed, Kelp new, Konbu unlinked.
  OISServiceResponse *updated = [self send:@"PATCH" path:@"Categories(3)" headers:nil body:@{
    @"Products": @[ @{ @"ProductID": @6, @"UnitPrice": @35 }, @{ @"ProductName": @"Kelp" } ] }];
  XCTAssertEqual(updated.status, 204, @"%@", updated.text);
  XCTAssertEqual(products.updates, 1);
  XCTAssertEqual(products.inserts, 3);
  XCTAssertEqualObjects([self get:@"Products(6)/UnitPrice"].json[@"value"], @35);
  XCTAssertEqualObjects([self get:@"Categories(3)/Products/$count"].text, @"2");

  // And a delta that deletes one.
  OISServiceResponse *delta = [self send:@"PATCH" path:@"Categories(3)" headers:@{ @"OData-Version": @"4.01" } body:@{
    @"Products@delta": @[ @{ @"@removed": @{ @"reason": @"deleted" }, @"@id": @"Products(6)" } ] }];
  XCTAssertEqual(delta.status, 204, @"%@", delta.text);
  XCTAssertEqual(products.deletes, 1);
  XCTAssertEqual([self get:@"Products(6)"].status, 404);

  // An answer that fails fails the write, and nothing of it is kept.
  OISServiceResponse *bad = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Grains", @"Products": @[ @{ @"ProductName": @"Rice" }, @{ @"ProductName": @"Oats", @"UnitPrice": @"cheap" } ] }];
  XCTAssertEqual(bad.status, 400, @"%@", bad.text);
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"3");
}

#pragma mark Write plans

// A write is planned before anything is done: what it reads through the
// handlers, what it checks, what it writes, and what it answers with;
// explain shows the plan and writes nothing.
- (void)testWritePlans
{
  _service.explains = YES;
  OISServiceResponse *r = [self send:@"POST" path:@"$explain/Categories" headers:nil body:@{
    @"CategoryName": @"Tea", @"Products": @[ @{ @"ProductName": @"Sencha", @"Suppliers@odata.bind": @[ @"Suppliers(1)" ] } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSString *physical = r.json[@"physical"];
  XCTAssertTrue([physical hasPrefix:@"Returning\n  Nest Products\n  Objects (what Insert Category wrote)\nCommit\n  Insert Category set name\n"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"id :=\n      Sequence Category.id from Store scan Category sort id desc top 1"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"products := these\n      Insert Product set name"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"suppliers := these\n          Lookup Suppliers(1)"], @"%@", physical);
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"2", @"explained, not written");

  physical = [self send:@"PATCH" path:@"$explain/Products(1)" headers:@{ @"If-Match": @"W/\"1\"" } body:@{ @"UnitPrice": @20 }].json[@"physical"];
  XCTAssertTrue([physical containsString:@"Commit\n  Update Product set unitPrice\n    Assert If-Match W/\"1\"\n    Assert the key and what is immutable unchanged\n    Objects (1)"], @"%@", physical);
  physical = [self send:@"DELETE" path:@"$explain/Products/$filter(UnitPrice gt 20)/$each" headers:nil body:nil].json[@"physical"];
  XCTAssertTrue([physical containsString:@"Delete Product\n    Store scan Product where $filter(UnitPrice gt 20) sort key at most 10000"], @"%@", physical);
  XCTAssertEqualObjects([self get:@"Products/$count"].text, @"5");

  // A temporal action: the slices read, then its changes to them.
  [self serveDepartmentHistory];
  _service.explains = YES;
  physical = [self send:@"POST" path:@"$explain/Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D08", @"From": @"2012-04-01", @"Budget": @1 } } ] }].json[@"physical"];
  XCTAssertTrue([physical containsString:@"Commit\n  Temporal Update of Department (1 delta time slices)\n"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"    Store scan Department sort key at most 10000"], @"%@", physical);
}

// Everything a write reads and checks comes before anything is written:
// a deep insert whose second product binds to no supplier asks no handler
// to insert the first.
- (void)testWritesAreCheckedBeforeTheyAreMade
{
  OISLaterWrites *products = [[OISLaterWrites alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:products forEntitySet:@"Products"];
  OISServiceResponse *r = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Grains",
    @"Products": @[ @{ @"ProductName": @"Rice" }, @{ @"ProductName": @"Oats", @"Suppliers@odata.bind": @[ @"Suppliers(9)" ] } ] }];
  XCTAssertEqual(r.status, 400, @"%@", r.text);
  XCTAssertEqual(products.inserts, 0, @"nothing asked before the checks");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"2");

  // Keys: counted on from the largest, once for the write, and from above
  // any the request gives.
  r = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Grains", @"Products": @[ @{ @"ProductID": @20, @"ProductName": @"Rice" }, @{ @"ProductName": @"Oats" } ] }];
  XCTAssertEqual(r.status, 201, @"%@", r.text);
  XCTAssertEqualObjects([[r.json[@"Products"] valueForKey:@"ProductID"] sortedArrayUsingSelector:@selector(compare:)], (@[ @20, @21 ]));
  XCTAssertEqualObjects(r.json[@"CategoryID"], @3);
}

// 4.01's collection writes (Part 1 sections 11.4.12-14): each member a
// filter selects updated or deleted; a delta payload applied to a set;
// a set replaced.
- (void)testCollectionWrites
{
  XCTAssertEqualObjects([self get:@"Products/$filter(UnitPrice gt 20)/$count"].text, @"2", @"a filter segment");
  OISServiceResponse *r = [self send:@"PATCH" path:@"Products/$filter(UnitPrice gt 20)/$each" headers:nil body:@{ @"Discontinued": @YES }];
  XCTAssertEqual(r.status, 204, @"%@", r.text);
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Discontinued&$orderby=ProductID"]],
                        (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));

  r = [self send:@"PATCH" path:@"Products/$filter(@p)/$each?@p=UnitPrice lt 11" headers:@{ @"Prefer": @"return=representation" }
            body:@{ @"UnitPrice": @11 }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductID"], @[ @3 ], @"the updated members");
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"UnitPrice"], @[ @11 ]);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products/$each" headers:nil body:@{ @"Category": @{ @"CategoryName": @"New" } }].status), 501,
                 @"a nested entity for each member");
  XCTAssertEqual(([self send:@"GET" path:@"Products/$each" headers:nil body:nil].status), 405);

  r = [self send:@"DELETE" path:@"Products/$filter(Discontinued)/$each" headers:@{ @"Prefer": @"return=representation" } body:nil];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqual([r.json[@"value"] count], 2u, @"a deleted entry for each: %@", r.text);
  XCTAssertTrue([r.json[@"@odata.context"] hasSuffix:@"#Products/$delta"], @"%@", r.text);
  XCTAssertEqualObjects([self get:@"Products/$count"].text, @"3");

  // A delta payload: upserts, and a delete.
  r = [self send:@"PATCH" path:@"Categories" headers:@{ @"OData-Version": @"4.01", @"Prefer": @"return=representation" } body:@{
    @"@context": @"#$delta",
    @"value": @[ @{ @"CategoryID": @1, @"CategoryName": @"Drinks" }, @{ @"CategoryName": @"Tea" },
                 @{ @"@removed": @{ @"reason": @"deleted" }, @"@id": @"Categories(2)" } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *value = r.json[@"value"];
  XCTAssertEqual(value.count, 3u, @"in the request's order: %@", r.text);
  XCTAssertEqualObjects(value[0][@"CategoryName"], @"Drinks");
  XCTAssertEqualObjects(value[1][@"CategoryName"], @"Tea");
  XCTAssertEqual([self get:@"Categories(2)"].status, 404);
  XCTAssertEqualObjects([self get:@"Categories(1)/CategoryName"].json[@"value"], @"Drinks");
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories/$filter(CategoryID eq 1)" headers:nil body:@{ @"value": @[] }].status), 400,
                 @"a filtered collection is not updated as a whole");

  // PUT: the collection is what the body says.
  r = [self send:@"PUT" path:@"Suppliers" headers:nil body:@{
    @"value": @[ @{ @"SupplierID": @1, @"CompanyName": @"Exotic" }, @{ @"CompanyName": @"Pampas", @"City": @"Buenos Aires" } ] }];
  XCTAssertEqual(r.status, 204, @"%@", r.text);
  XCTAssertEqualObjects([self get:@"Suppliers/$count"].text, @"2");
  XCTAssertEqual([self get:@"Suppliers(2)"].status, 404, @"not in the body: deleted");
  XCTAssertEqualObjects([self get:@"Suppliers(1)/CompanyName"].json[@"value"], @"Exotic");
  XCTAssertEqualObjects([self get:@"Suppliers(3)/City"].json[@"value"], @"Buenos Aires");
}

// Core Data's batch requests, through the client: one PATCH or DELETE of
// each member a filter segment selects, with the objects' IDs back and
// their rows kept, merged into a context as a store's batch results are;
// what a filter segment cannot say, each object fetched and written.
- (void)testClientBatchUpdatesAndDeletes
{
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *context = [self clientOver:transport options:nil error:&error];
  XCTAssertNotNil(context, @"%@", error);
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
  NSArray *products = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqual(products.count, 5u, @"%@", error);

  NSBatchUpdateRequest *update = [NSBatchUpdateRequest batchUpdateRequestWithEntityName:@"Product"];
  update.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20"];
  update.propertiesToUpdate = @{ @"discontinued": [NSExpression expressionForConstantValue:@YES], @"quantityPerUnit": @"12 boxes" };
  update.resultType = NSUpdatedObjectIDsResultType;
  NSBatchUpdateResult *updated = (NSBatchUpdateResult *)[context executeRequest:update error:&error];
  XCTAssertEqual([updated.result count], 2u, @"%@", error);
  NSURLRequest *sent = transport.requests.lastObject;
  XCTAssertEqualObjects(sent.HTTPMethod, @"PATCH");
  NSString *url = [sent.URL.absoluteString stringByRemovingPercentEncoding];
  XCTAssertTrue([url hasSuffix:@"/Products/$filter(@f)/$each?@f=UnitPrice gt 20"], @"%@", url);
  [NSManagedObjectContext mergeChangesFromRemoteContextSave:@{ NSUpdatedObjectsKey: updated.result } intoContexts:@[ context ]];
  XCTAssertEqualObjects([products valueForKey:@"discontinued"], (@[ @NO, @NO, @NO, @YES, @YES ]));
  XCTAssertEqualObjects([products[4] valueForKey:@"quantityPerUnit"], @"12 boxes");
  XCTAssertEqualObjects([self get:@"Products(5)/QuantityPerUnit"].json[@"value"], @"12 boxes");

  // The objects deleted, known by the keys in the removed entries.
  NSFetchRequest *discontinued = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  discontinued.predicate = [NSPredicate predicateWithFormat:@"discontinued == YES"];
  NSBatchDeleteRequest *delete = [[NSBatchDeleteRequest alloc] initWithFetchRequest:discontinued];
  delete.resultType = NSBatchDeleteResultTypeObjectIDs;
  NSBatchDeleteResult *deleted = (NSBatchDeleteResult *)[context executeRequest:delete error:&error];
  XCTAssertEqualObjects([NSSet setWithArray:deleted.result], ([NSSet setWithObjects:[products[3] objectID], [products[4] objectID], nil]), @"%@", error);
  XCTAssertEqualObjects(transport.requests.lastObject.HTTPMethod, @"DELETE");
  XCTAssertEqualObjects([self get:@"Products/$count"].text, @"3");
  [NSManagedObjectContext mergeChangesFromRemoteContextSave:@{ NSDeletedObjectsKey: deleted.result } intoContexts:@[ context ]];
  XCTAssertEqual([context executeFetchRequest:fetch error:&error].count, 3u, @"%@", error);

  // By object ID (SELF IN them: a filter too).
  NSBatchDeleteRequest *byID = [[NSBatchDeleteRequest alloc] initWithObjectIDs:@[ [products[1] objectID] ]];
  byID.resultType = NSBatchDeleteResultTypeCount;
  XCTAssertEqualObjects(((NSBatchDeleteResult *)[context executeRequest:byID error:&error]).result, @1, @"%@", error);
  XCTAssertTrue([transport.requests.lastObject.URL.absoluteString containsString:@"$each"]);
  // A limit, which a filter segment cannot say: the object fetched, then
  // deleted at its own URL.
  NSFetchRequest *last = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  last.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:NO] ];
  last.fetchLimit = 1;
  NSBatchDeleteRequest *limited = [[NSBatchDeleteRequest alloc] initWithFetchRequest:last];
  limited.resultType = NSBatchDeleteResultTypeCount;
  XCTAssertEqualObjects(((NSBatchDeleteResult *)[context executeRequest:limited error:&error]).result, @1, @"%@", error);
  XCTAssertTrue([transport.requests.lastObject.URL.path hasSuffix:@"/Products/3"], @"%@", transport.requests.lastObject.URL);
  XCTAssertEqualObjects([self get:@"Products/$count"].text, @"1");

  // A value computed from each row is no value to send.
  update.propertiesToUpdate = @{ @"unitPrice": [NSExpression expressionWithFormat:@"unitPrice * 2"] };
  XCTAssertNil([context executeRequest:update error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedRequest);
}

#pragma mark Date and number functions

- (void)testYearAndDateInFilters
{
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType, NSXMLStoreType ]) {
    [self serveStaffInStoreOfType:storeType];
    NSDictionary *expected = @{
      @"year(Hired) eq 2025": @[ @"Cy" ],
      @"2025 eq year(Hired)": @[ @"Cy" ],
      @"year(Hired) ne 2025": @[ @"Ann", @"Bob", @"Di" ],
      @"year(Hired) lt 2025": @[ @"Ann", @"Bob" ],
      @"year(Hired) le 2024": @[ @"Ann", @"Bob" ],
      @"year(Hired) gt 2019": @[ @"Bob", @"Cy" ],
      @"year(Hired) ge 2024": @[ @"Bob", @"Cy" ],
      @"year(Hired) eq null": @[ @"Di" ],
      @"year(Hired) in (2019,2025)": @[ @"Ann", @"Cy" ],
      @"year(Manager/Hired) eq 2024": @[ @"Cy", @"Di" ],
      @"date(Hired) eq 2024-12-31": @[ @"Bob" ],
      @"date(Hired) gt 2024-12-31": @[ @"Cy" ],
      @"date(Hired) le 2019-06-01": @[ @"Ann" ],
      @"date(Hired) ne 2024-12-31": @[ @"Ann", @"Cy", @"Di" ],
    };
    for (NSString *filter in expected) {
      NSString *path = [@"Employees?$filter=" stringByAppendingString:filter];
      XCTAssertEqualObjects([self sortedEmployeeNames:path], expected[filter], @"%@: %@", storeType, filter);
    }
  }
  XCTAssertEqual([self get:@"Employees?$filter=year(Hired) add 1 eq 2026"].status, 501, @"only compared with a literal");
  XCTAssertEqual([self get:@"Employees?$filter=year(Hired) eq year(Hired)"].status, 501);
  XCTAssertEqual([self get:@"Employees?$orderby=year(Hired)"].status, 501);
  XCTAssertEqual([self get:@"Employees?$filter=year(Name) eq 2025"].status, 400);
  XCTAssertEqual([self get:@"Employees?$filter=date(Hired) eq 2025"].status, 400);
}

// A range in each year, month, day, hour or minute the dates span.
- (void)testMonthDayAndHourInFilters
{
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType, NSXMLStoreType ]) {
    [self serveStaffInStoreOfType:storeType];
    // Hired 2019-06-01T09:00Z (Ann), 2024-12-31T23:30Z (Bob), 2025-01-01T00:00Z (Cy), never (Di).
    NSDictionary *expected = @{
      @"month(Hired) eq 6": @[ @"Ann" ],
      @"month(Hired) eq 12": @[ @"Bob" ],
      @"month(Hired) lt 6": @[ @"Cy" ],
      @"month(Hired) ge 6": @[ @"Ann", @"Bob" ],
      @"month(Hired) gt 5.5": @[ @"Ann", @"Bob" ],
      @"month(Hired) ne 12": @[ @"Ann", @"Cy", @"Di" ],
      @"month(Hired) eq 13": @[],
      @"month(Hired) eq 0": @[],
      @"month(Hired) in (1,6)": @[ @"Ann", @"Cy" ],
      @"month(Manager/Hired) eq 12": @[ @"Cy", @"Di" ],
      @"day(Hired) eq 31": @[ @"Bob" ],
      @"day(Hired) eq 1": @[ @"Ann", @"Cy" ],
      @"day(Hired) gt 1": @[ @"Bob" ],
      @"day(Hired) eq null": @[ @"Di" ],
    };
    for (NSString *filter in expected) {
      NSString *path = [@"Employees?$filter=" stringByAppendingString:filter];
      XCTAssertEqualObjects([self sortedEmployeeNames:path], expected[filter], @"%@: %@", storeType, filter);
    }
    XCTAssertEqual([self get:@"Employees?$filter=hour(Hired) eq 9"].status, 501, @"%@: six years of days is too many ranges", storeType);
    // The span, read first, through the handler.
    _service.explains = YES;
    NSString *physical = [self get:@"$explain/Employees?$filter=month(Manager/Hired) eq 12"].json[@"physical"];
    XCTAssertTrue([physical hasPrefix:@"Span Employee.hired\nStore scan Employee where month(Manager/Hired) eq 12"], @"%@", physical);
    _service.explains = NO;

    // Ann hired the morning before Bob: two days of hours.
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
    context.persistentStoreCoordinator = _coordinator;
    NSFetchRequest *annRequest = [NSFetchRequest fetchRequestWithEntityName:@"Employee"];
    annRequest.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
    [[[context executeFetchRequest:annRequest error:NULL] firstObject] setValue:ODataDateFromString(@"2024-12-31T09:15:00Z") forKey:@"hired"];
    NSError *error = nil;
    XCTAssertTrue([context save:&error], @"%@", error);
    expected = @{
      @"hour(Hired) eq 23": @[ @"Bob" ],
      @"hour(Hired) lt 10": @[ @"Ann", @"Cy" ],
      @"hour(Hired) ne 9": @[ @"Bob", @"Cy", @"Di" ],
      @"minute(Hired) eq 30": @[ @"Bob" ],
      @"minute(Hired) ge 15": @[ @"Ann", @"Bob" ],
    };
    for (NSString *filter in expected) {
      NSString *path = [@"Employees?$filter=" stringByAppendingString:filter];
      XCTAssertEqualObjects([self sortedEmployeeNames:path], expected[filter], @"%@: %@", storeType, filter);
    }
    XCTAssertEqual([self get:@"Employees?$filter=second(Hired) eq 0"].status, 501, @"%@: 15 hours of minutes is too many", storeType);
  }
  XCTAssertEqual([self get:@"Employees?$filter=month(Name) eq 3"].status, 400);
  XCTAssertEqual([self get:@"Employees?$filter=totaloffsetminutes(Hired) eq 0"].status, 501);
}

- (NSArray *)productIDsWhere:(NSString *)filter
{
  NSString *path = [NSString stringWithFormat:@"Products?$filter=%@&$select=ProductID&$orderby=ProductID", filter];
  OISServiceResponse *response = [self get:path];
  XCTAssertEqual(response.status, 200, @"%@: %@", filter, response.text);
  return [response.json[@"value"] valueForKey:@"ProductID"];
}

// Casts to a primitive type that holds every value of the property's own
// (Part 2 section 5.1.1.10.1); the rest depend on rounding or on text.
- (void)testPrimitiveCastsInFilters
{
  // IDs 1 to 5; prices 18, 19, 10, 22, 21.35.
  XCTAssertEqualObjects([self productIDsWhere:@"cast(ProductID,Edm.Int64) eq 1"], @[ @1 ]);
  XCTAssertEqualObjects([self productIDsWhere:@"cast(ProductID,Edm.Decimal) gt 2.5"], (@[ @3, @4, @5 ]));
  XCTAssertEqualObjects([self productIDsWhere:@"cast(ProductID,Edm.Double) lt 2.5"], (@[ @1, @2 ]));
  XCTAssertEqualObjects([self productIDsWhere:@"cast(UnitPrice,Edm.Decimal) eq 18"], @[ @1 ], @"its own type");
  XCTAssertEqualObjects([self productIDsWhere:@"cast(ProductName,Edm.String) eq 'Chai'"], @[ @1 ]);
  XCTAssertEqualObjects([self productIDsWhere:@"cast(ProductID,'Edm.Int64') in (2,3)"], (@[ @2, @3 ]), @"the type in quotes");
  XCTAssertEqualObjects([self productIDsWhere:@"isof(ProductID,Edm.Int64)"], (@[ @1, @2, @3, @4, @5 ]));
  XCTAssertEqualObjects([self productIDsWhere:@"isof(UnitPrice,Edm.Decimal)"], (@[ @1, @2, @3, @4, @5 ]));
  XCTAssertEqualObjects([self productIDsWhere:@"isof(Edm.String)"], @[], @"a product is not a string");
  XCTAssertEqual([self get:@"Products?$filter=cast(UnitPrice,Edm.Int32) eq 18"].status, 501, @"rounding is the service's to choose");
  XCTAssertEqual([self get:@"Products?$filter=cast(ProductID,Edm.String) eq '1'"].status, 501);
  XCTAssertEqual([self get:@"Products?$filter=isof(UnitPrice,Edm.Int32)"].status, 501, @"depends on the value");
  XCTAssertEqual([self get:@"Products?$filter=cast(Edm.Int32) eq 1"].status, 400);
}

- (void)testRoundingInFilters
{
  // Prices 18, 19, 10, 22, 21.35.
  NSDictionary *expected = @{
    @"floor(UnitPrice) eq 21": @[ @5 ],
    @"ceiling(UnitPrice) eq 22": @[ @4, @5 ],
    @"round(UnitPrice) eq 21": @[ @5 ],
    @"round(UnitPrice) gt 19": @[ @4, @5 ],
    @"floor(UnitPrice) le 18": @[ @1, @3 ],
    @"ceiling(UnitPrice) lt 20": @[ @1, @2, @3 ],
    @"round(UnitPrice) ne 18": @[ @2, @3, @4, @5 ],
    @"floor(UnitPrice) in (10,22)": @[ @3, @4 ],
    @"floor(UnitPrice) eq 21.5": @[],
    @"floor(UnitPrice) ne 21.5": @[ @1, @2, @3, @4, @5 ],
    @"floor(UnitPrice) gt 18.5": @[ @2, @4, @5 ],
    @"round(UnitPrice) lt 21.5": @[ @1, @2, @3, @5 ],
    @"ceiling(UnitPrice) ge 21.2": @[ @4, @5 ],
  };
  for (NSString *filter in expected) {
    XCTAssertEqualObjects([self productIDsWhere:filter], expected[filter], @"%@", filter);
  }
  // Half away from zero: round(-4.5) is -5.
  XCTAssertEqual(([self send:@"POST" path:@"Products" headers:nil body:@{ @"ProductName": @"Refund", @"UnitPrice": @(-4.5) }].status), 201);
  XCTAssertEqualObjects([self productIDsWhere:@"round(UnitPrice) eq -5"], @[ @6 ]);
  XCTAssertEqualObjects([self productIDsWhere:@"round(UnitPrice) eq -4"], @[]);
  XCTAssertEqualObjects([self productIDsWhere:@"floor(UnitPrice) eq -5"], @[ @6 ]);
  XCTAssertEqualObjects([self productIDsWhere:@"ceiling(UnitPrice) eq -4"], @[ @6 ]);
  XCTAssertEqualObjects([self productIDsWhere:@"floor(UnitPrice) lt -4.5"], @[ @6 ]);
  XCTAssertEqual([self get:@"Products?$filter=round(ProductName) eq 1"].status, 400);
}

#pragma mark Enumerations

static NSAttributeDescription *OISSwatchAttribute(NSString *name, NSAttributeType type, NSString *odataType)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = ![name isEqualToString:@"id"];
  if (odataType) attribute.userInfo = @{ @"OData.type": odataType };
  return attribute;
}

// Swatches, with a flags enumeration kept as a number and as text, and a
// plain one.
- (void)serveSwatchesInStoreOfType:(NSString *)storeType
{
  NSEntityDescription *swatch = [[NSEntityDescription alloc] init];
  swatch.name = @"Swatch";
  swatch.managedObjectClassName = @"NSManagedObject";
  swatch.userInfo = @{ @"OData.entitySet": @"Swatches" };
  NSAttributeDescription *identifier = OISSwatchAttribute(@"id", NSInteger32AttributeType, nil);
  identifier.userInfo = @{ @"OData.property": @"SwatchID", @"OData.key": @"YES" };
  swatch.properties = @[ identifier,
                         OISSwatchAttribute(@"name", NSStringAttributeType, nil),
                         OISSwatchAttribute(@"colours", NSInteger32AttributeType, @"Default.Colour"),
                         OISSwatchAttribute(@"label", NSStringAttributeType, @"Default.Colour"),
                         OISSwatchAttribute(@"shade", NSInteger16AttributeType, @"Default.Shade") ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ swatch ];
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_storeFiles addObject:url];
  }
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  NSArray *rows = @[ @[ @1, @"none", @0, @1 ], @[ @2, @"red", @1, @2 ], @[ @3, @"orange", @3, @3 ],
                     @[ @4, @"white", @7, [NSNull null] ], @[ @5, @"blue", @4, [NSNull null] ], @[ @6, @"unknown", [NSNull null], [NSNull null] ] ];
  for (NSArray *row in rows) {
    NSMutableDictionary *values = [@{ @"id": row[0], @"name": row[1] } mutableCopy];
    // The label: the colours as text, as the service keeps it.
    NSDictionary *labels = @{ @1: @"Red", @3: @"Red,Green", @7: @"Red,Green,Blue", @4: @"Blue" };
    if (row[2] != [NSNull null] && labels[row[2]]) values[@"label"] = labels[row[2]];
    if (row[2] != [NSNull null]) values[@"colours"] = row[2];
    if (row[3] != [NSNull null]) values[@"shade"] = row[3];
    [self insert:@"Swatch" into:context values:values];
  }
  XCTAssertTrue([context save:&error], @"%@", error);
  NSString *csdl = @"<?xml version=\"1.0\"?><edmx:Edmx xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\" Version=\"4.0\">"
                   @"<edmx:DataServices><Schema xmlns=\"http://docs.oasis-open.org/odata/ns/edm\" Namespace=\"Default\">"
                   @"<EnumType Name=\"Colour\" IsFlags=\"true\"><Member Name=\"Red\" Value=\"1\"/><Member Name=\"Green\" Value=\"2\"/><Member Name=\"Blue\" Value=\"4\"/></EnumType>"
                   @"<EnumType Name=\"Shade\"><Member Name=\"Light\" Value=\"1\"/><Member Name=\"Dark\" Value=\"2\"/><Member Name=\"Darker\" Value=\"3\"/></EnumType>"
                   @"<EntityType Name=\"Swatch\"><Key><PropertyRef Name=\"SwatchID\"/></Key><Property Name=\"SwatchID\" Type=\"Edm.Int32\" Nullable=\"false\"/>"
                   @"<Property Name=\"Name\" Type=\"Edm.String\"/><Property Name=\"Colours\" Type=\"Default.Colour\"/>"
                   @"<Property Name=\"Label\" Type=\"Default.Colour\"/><Property Name=\"Shade\" Type=\"Default.Shade\"/></EntityType>"
                   @"<EntityContainer Name=\"Container\"><EntitySet Name=\"Swatches\" EntityType=\"Default.Swatch\"/></EntityContainer>"
                   @"</Schema></edmx:DataServices></edmx:Edmx>";
  ODataSchema *schema = [ODataSchema schemaWithData:[csdl dataUsingEncoding:NSUTF8StringEncoding] error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  _service.mapper.schema = schema;
}

- (NSArray *)swatchIDsWhere:(NSString *)filter
{
  OISServiceResponse *response = [self get:[NSString stringWithFormat:@"Swatches?$filter=%@&$select=SwatchID&$orderby=SwatchID", filter]];
  XCTAssertEqual(response.status, 200, @"%@: %@", filter, response.text);
  return [response.json[@"value"] valueForKey:@"SwatchID"];
}

- (void)testHas
{
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType, NSXMLStoreType ]) {
    [self serveSwatchesInStoreOfType:storeType];
    OISServiceResponse *metadata = [self get:@"$metadata"];
    XCTAssertTrue([metadata.text rangeOfString:@"<EnumType Name=\"Colour\" IsFlags=\"true\">"].location != NSNotFound, @"%@", metadata.text);
    NSDictionary *expected = @{
      @"Colours has Default.Colour'Red'": @[ @2, @3, @4 ],
      @"Colours has Default.Colour'Red,Green'": @[ @3, @4 ],
      @"Colours has Default.Colour'Blue'": @[ @4, @5 ],
      @"Colours has Default.Colour'Red,Blue'": @[ @4 ],
      @"Colours has Default.Colour'1'": @[ @2, @3, @4 ],
      @"Colours has Default.Colour'Red' and Name ne 'white'": @[ @2, @3 ],
      @"Shade has Default.Shade'Dark'": @[ @2, @3 ],
      @"Shade has Default.Shade'Light'": @[ @1, @3 ],
    };
    for (NSString *filter in expected) {
      XCTAssertEqualObjects([self swatchIDsWhere:filter], expected[filter], @"%@: %@", storeType, filter);
    }
    XCTAssertEqualObjects([self swatchIDsWhere:@"Label has Default.Colour'Red'"], (@[ @2, @3, @4 ]), @"%@: kept as text", storeType);
    XCTAssertEqualObjects([self swatchIDsWhere:@"Label has Default.Colour'Green,Red'"], (@[ @3, @4 ]), @"%@", storeType);
    XCTAssertEqualObjects([self swatchIDsWhere:@"Label eq Default.Colour'Green,Red'"], @[ @3 ], @"%@: one value, one text", storeType);
    // Written in any order, kept as the canonical text.
    OISServiceResponse *created = [self send:@"POST" path:@"Swatches" headers:nil
                                        body:@{ @"SwatchID": @7, @"Name": @"cyan", @"Label": @"Blue, Green" }];
    XCTAssertEqual(created.status, 201, @"%@", created.text);
    XCTAssertEqualObjects(created.json[@"Label"], @"Green,Blue");
    XCTAssertEqualObjects([self swatchIDsWhere:@"Label has Default.Colour'Green'"], (@[ @3, @4, @7 ]), @"%@", storeType);
    XCTAssertEqual([self get:@"Swatches?$filter=Name has Default.Colour'Red'"].status, 400);
    XCTAssertEqual([self get:@"Swatches?$filter=Colours has Default.Shade'Dark'"].status, 400);
    XCTAssertEqual([self get:@"Swatches?$filter=Colours has Default.Colour'Purple'"].status, 400);
  }
}

#pragma mark Authentication

- (void)testTrustedProxyHeaders
{
  OISScopedProducts *products = [[OISScopedProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:products forEntitySet:@"Products"];
  HSTrustedHeaderAuthenticator *proxy = [[HSTrustedHeaderAuthenticator alloc] init];
  proxy.secretHeader = @"X-OIS-Proxy-Secret";
  proxy.secret = @"s3cret";
  _service.authenticator = proxy;
  NSDictionary *ann = @{ @"X-OIS-Proxy-Secret": @"s3cret", @"X-Forwarded-User": @"ann",
                         @"X-Forwarded-Email": @"ann@example.com", @"X-Forwarded-Groups": @"buyers, staff" };

  OISServiceResponse *nobody = [self get:@"Products"];
  XCTAssertEqual(nobody.status, 401, @"%@", nobody.text);
  XCTAssertEqualObjects([nobody header:@"WWW-Authenticate"], @"Bearer");
  XCTAssertEqual([self get:@"$metadata"].status, 401, @"all of it");
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"X-Forwarded-User": @"ann" } body:nil].status), 401,
                 @"not through the proxy: no secret");
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"X-Forwarded-User": @"ann", @"X-OIS-Proxy-Secret": @"s3creT" } body:nil].status), 401);
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"X-OIS-Proxy-Secret": @"s3cret" } body:nil].status), 401, @"through the proxy, but no one");

  OISServiceResponse *asAnn = [self send:@"GET" path:@"Products" headers:ann body:nil];
  XCTAssertEqual(asAnn.status, 200, @"%@", asAnn.text);
  XCTAssertEqual([asAnn.json[@"value"] count], 4u, @"not an admin: what is still sold");
  XCTAssertEqualObjects(products.lastPrincipal.subject, @"ann");
  XCTAssertEqualObjects(products.lastPrincipal.claims[@"email"], @"ann@example.com");
  XCTAssertEqualObjects(products.lastPrincipal.claims[@"groups"], (@[ @"buyers", @"staff" ]));

  NSMutableDictionary *root = [ann mutableCopy];
  root[@"X-Forwarded-User"] = @"root";
  root[@"X-Forwarded-Groups"] = @"admin";
  XCTAssertEqual([[self send:@"GET" path:@"Products" headers:root body:nil].json[@"value"] count], 5u);

  // A batch is ann's, whoever its requests say they are.
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/odata/$batch"]];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  for (NSString *name in ann) [request setValue:ann[name] forHTTPHeaderField:name];
  NSDictionary *batch = @{ @"requests": @[
    @{ @"id": @"1", @"method": @"get", @"url": @"Products/$count",
       @"headers": @{ @"X-Forwarded-User": @"root", @"X-Forwarded-Groups": @"admin" } } ] };
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:batch options:0 error:NULL];
  OISServiceResponse *batched = [self exchange:request];
  XCTAssertEqual(batched.status, 200, @"%@", batched.text);
  XCTAssertEqualObjects([batched.json[@"responses"] firstObject][@"body"], @"4", @"%@", batched.text);
  XCTAssertEqualObjects(products.lastPrincipal.subject, @"ann");

  _service.allowsAnonymousRequests = YES;
  OISServiceResponse *anonymous = [self send:@"GET" path:@"Products" headers:@{ @"X-OIS-Proxy-Secret": @"s3cret" } body:nil];
  XCTAssertEqual(anonymous.status, 200);
  XCTAssertEqual([anonymous.json[@"value"] count], 4u);
  XCTAssertNil(products.lastPrincipal);
  XCTAssertEqual([self get:@"Products"].status, 401, @"the secret still holds");
}

- (void)testAuthenticatorThatAnswersLater
{
  OISScopedProducts *products = [[OISScopedProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:products forEntitySet:@"Products"];
  _service.authenticator = [[OISLaterAuthenticator alloc] init];
  OISServiceResponse *nobody = [self get:@"Products"];
  XCTAssertEqual(nobody.status, 401);
  XCTAssertEqualObjects([nobody header:@"WWW-Authenticate"], @"Token realm=\"example\"");
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"Authorization": @"Token banned" } body:nil].status), 403);
  OISServiceResponse *bob = [self send:@"GET" path:@"Products" headers:@{ @"Authorization": @"Token bob" } body:nil];
  XCTAssertEqual(bob.status, 200, @"%@", bob.text);
  XCTAssertEqualObjects(products.lastPrincipal.subject, @"bob");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:@{ @"Authorization": @"Token bob" } body:@{ @"UnitPrice": @20 }].status), 204);
  XCTAssertEqualObjects(([self send:@"GET" path:@"Products(1)/UnitPrice" headers:@{ @"Authorization": @"Token bob" } body:nil].json[@"value"]), @20);
}

#pragma mark Bearer tokens

- (NSDictionary *)JWTFixtures
{
  return [NSJSONSerialization JSONObjectWithData:[OISJWTFixturesJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

- (OISServiceResponse *)getProductsWithToken:(NSString *)token
{
  NSDictionary *headers = token ? @{ @"Authorization": [@"Bearer " stringByAppendingString:token] } : nil;
  return [self send:@"GET" path:@"Products" headers:headers body:nil];
}

- (void)testJWTs
{
  NSDictionary *fixtures = [self JWTFixtures];
  NSDictionary *tokens = fixtures[@"tokens"];
  OISScopedProducts *products = [[OISScopedProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:products forEntitySet:@"Products"];
  HSJWTAuthenticator *jwt = [[HSJWTAuthenticator alloc] initWithIssuer:fixtures[@"issuer"] audience:fixtures[@"audience"]];
  jwt.keySet = fixtures[@"keys"];
  _service.authenticator = jwt;

  for (NSString *name in @[ @"rs256", @"ps256", @"rs512", @"es256", @"es384", @"noKid", @"audienceList", @"readOnly" ]) {
    products.lastPrincipal = nil;
    OISServiceResponse *response = [self getProductsWithToken:tokens[name]];
    XCTAssertEqual(response.status, 200, @"%@: %@", name, response.text);
    XCTAssertEqualObjects(products.lastPrincipal.subject, @"ann", @"%@", name);
    XCTAssertEqualObjects(products.lastPrincipal.claims[@"email"], @"ann@example.com", @"%@", name);
  }
  // Each a way a token is forged, misused or stale.
  for (NSString *name in @[ @"expired", @"notYet", @"noExpiry", @"noSubject", @"wrongAudience", @"wrongIssuer", @"badSignature",
                            @"otherKeysSignature", @"none", @"hmacWithPublicKey", @"curveMismatch", @"rsaKeyForEC", @"weakKey",
                            @"critical", @"idToken", @"rotated" ]) {
    OISServiceResponse *response = [self getProductsWithToken:tokens[name]];
    XCTAssertEqual(response.status, 401, @"%@: %@", name, response.text);
    XCTAssertTrue([[response header:@"WWW-Authenticate"] hasPrefix:@"Bearer realm=\"api\", error=\"invalid_token\""], @"%@: %@", name,
                  [response header:@"WWW-Authenticate"]);
  }
  XCTAssertEqual([self getProductsWithToken:@"not.a.token"].status, 401);
  XCTAssertEqual([self getProductsWithToken:@"abc"].status, 401);
  OISServiceResponse *none = [self getProductsWithToken:nil];
  XCTAssertEqual(none.status, 401);
  XCTAssertEqualObjects([none header:@"WWW-Authenticate"], @"Bearer realm=\"api\"", @"no token, no error");
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"Authorization": @"Basic YW5uOnB3" } body:nil].status), 401);

  jwt.requiredScopes = [NSSet setWithObject:@"odata.write"];
  XCTAssertEqual([self getProductsWithToken:tokens[@"readOnly"]].status, 403);
  XCTAssertEqual([self getProductsWithToken:tokens[@"rs256"]].status, 200);
  jwt.requiredScopes = nil;
  jwt.algorithms = [NSSet setWithObject:@"ES256"];
  XCTAssertEqual([self getProductsWithToken:tokens[@"rs256"]].status, 401, @"not an algorithm the service takes");
  XCTAssertEqual([self getProductsWithToken:tokens[@"es256"]].status, 200);
}

// Tokens signed here (HSSignJWT: Security on Apple, gnutls elsewhere),
// checked with the public key alone; not with another key, not altered.
- (void)testSignedJWTs
{
  NSError *error = nil;
  NSDictionary *key = HSGenerateSigningKey(&error), *other = HSGenerateSigningKey(&error);
  XCTAssertNotNil(key, @"%@", error);
  XCTAssertEqualObjects(key[@"crv"], @"P-256");
  XCTAssertNotNil(key[@"d"]);
  XCTAssertNil(HSPublicKey(key)[@"d"], @"the public part only");
  XCTAssertNotEqualObjects(key[@"kid"], other[@"kid"]);
  OISScopedProducts *products = [[OISScopedProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:products forEntitySet:@"Products"];
  HSJWTAuthenticator *jwt = [[HSJWTAuthenticator alloc] initWithIssuer:@"https://issuer.example.test/" audience:@"ois-api"];
  jwt.keySet = @{ @"keys": @[ HSPublicKey(key) ] };
  jwt.algorithms = [NSSet setWithObject:@"ES256"];
  _service.authenticator = jwt;
  NSInteger now = (NSInteger)[NSDate date].timeIntervalSince1970;
  NSDictionary *claims = @{ @"iss": @"https://issuer.example.test/", @"aud": @"ois-api", @"sub": @"ann", @"iat": @(now), @"exp": @(now + 300) };

  // Signed more than once: ECDSA's signatures differ, each good.
  for (int i = 0; i < 3; i++) {
    NSString *token = HSSignJWT(claims, key, &error);
    XCTAssertNotNil(token, @"%@", error);
    products.lastPrincipal = nil;
    OISServiceResponse *response = [self getProductsWithToken:token];
    XCTAssertEqual(response.status, 200, @"%@", response.text);
    XCTAssertEqualObjects(products.lastPrincipal.subject, @"ann");
  }
  XCTAssertEqual([self getProductsWithToken:HSSignJWT(claims, other, NULL)].status, 401, @"another key");
  NSString *token = HSSignJWT(claims, key, NULL);
  NSMutableArray<NSString *> *parts = [[token componentsSeparatedByString:@"."] mutableCopy];
  NSMutableDictionary *altered = [claims mutableCopy];
  altered[@"sub"] = @"bob";
  NSString *payload = [[NSJSONSerialization dataWithJSONObject:altered options:0 error:NULL] base64EncodedStringWithOptions:0];
  payload = [[[payload stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
             stringByReplacingOccurrencesOfString:@"=" withString:@""];
  parts[1] = payload;
  XCTAssertEqual([self getProductsWithToken:[parts componentsJoinedByString:@"."]].status, 401, @"claims altered");
  XCTAssertNil(HSSignJWT(claims, HSPublicKey(key), &error), @"no d, no signature");
  XCTAssertNotNil(error);
}

- (void)testJWTKeysFromTheIssuer
{
  NSDictionary *fixtures = [self JWTFixtures];
  NSDictionary *tokens = fixtures[@"tokens"];
  NSString *issuer = fixtures[@"issuer"];
  NSString *discovery = [issuer stringByAppendingString:@"/.well-known/openid-configuration"];
  OISFakeIdentityProvider *provider = [[OISFakeIdentityProvider alloc] init];
  provider.documents = @{ discovery: @{ @"issuer": issuer, @"jwks_uri": @"https://id.example.test/keys" },
                          @"https://id.example.test/keys": fixtures[@"keys"] };
  HSJWTAuthenticator *jwt = [[HSJWTAuthenticator alloc] initWithIssuer:issuer audience:fixtures[@"audience"]];
  jwt.fetcher = provider;
  _service.authenticator = jwt;

  XCTAssertEqual([self getProductsWithToken:tokens[@"rs256"]].status, 200);
  XCTAssertEqual(provider.requests, 2, @"discovery, then the keys");
  XCTAssertEqual([self getProductsWithToken:tokens[@"es256"]].status, 200);
  XCTAssertEqual(provider.requests, 2, @"kept");

  // A key the set lacks: fetched again, but not at once.
  XCTAssertEqual([self getProductsWithToken:tokens[@"rotated"]].status, 401);
  XCTAssertEqual(provider.requests, 2, @"fetched too recently");
  provider.documents = @{ discovery: @{ @"issuer": issuer, @"jwks_uri": @"https://id.example.test/keys" },
                          @"https://id.example.test/keys": fixtures[@"rotatedKeys"] };
  jwt.keySetRefetchInterval = 0;
  XCTAssertEqual([self getProductsWithToken:tokens[@"rotated"]].status, 200, @"the issuer rotated its keys");
  XCTAssertEqual(provider.requests, 3, @"the keys again, not discovery");

  HSJWTAuthenticator *impostor = [[HSJWTAuthenticator alloc] initWithIssuer:issuer audience:nil];
  provider.documents = @{ discovery: @{ @"issuer": @"https://evil.example.test/", @"jwks_uri": @"https://id.example.test/keys" } };
  impostor.fetcher = provider;
  _service.authenticator = impostor;
  XCTAssertEqual([self getProductsWithToken:tokens[@"rs256"]].status, 503, @"a discovery document of another issuer");

  HSJWTAuthenticator *unreachable = [[HSJWTAuthenticator alloc] initWithIssuer:issuer audience:nil];
  unreachable.keySetURL = [NSURL URLWithString:@"https://id.example.test/nowhere"];
  unreachable.fetcher = provider;
  _service.authenticator = unreachable;
  XCTAssertEqual([self getProductsWithToken:tokens[@"rs256"]].status, 503);
}

- (void)testTokenIntrospection
{
  OISScopedProducts *products = [[OISScopedProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:products forEntitySet:@"Products"];
  OISFakeIdentityProvider *provider = [[OISFakeIdentityProvider alloc] init];
  // RFC 6749 2.3.1: the ID and secret form-encoded, then Basic.
  provider.credentials = [@"Basic " stringByAppendingString:[[@"ois-api:s%3Acret" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
  provider.introspections = @{
    @"opaque-ann": @{ @"active": @YES, @"sub": @"ann", @"scope": @"odata.read", @"exp": @4102444800, @"aud": @"ois-api",
                      @"groups": @[ @"admin" ] },
    @"opaque-client": @{ @"active": @YES, @"username": @"reporting", @"aud": @[ @"ois-api" ] },
    @"expired": @{ @"active": @YES, @"sub": @"ann", @"exp": @1000000000 },
    @"elsewhere": @{ @"active": @YES, @"sub": @"ann", @"aud": @"another-api" },
  };
  HSTokenIntrospectionAuthenticator *introspection =
    [[HSTokenIntrospectionAuthenticator alloc] initWithEndpoint:[NSURL URLWithString:@"https://id.example.test/introspect"]
                                                          clientID:@"ois-api" clientSecret:@"s:cret"];
  introspection.fetcher = provider;
  introspection.audience = @"ois-api";
  _service.authenticator = introspection;

  OISServiceResponse *ann = [self getProductsWithToken:@"opaque-ann"];
  XCTAssertEqual(ann.status, 200, @"%@", ann.text);
  XCTAssertEqual([ann.json[@"value"] count], 5u, @"an admin, by the provider's claims");
  XCTAssertEqualObjects(products.lastPrincipal.subject, @"ann");
  XCTAssertEqual([self getProductsWithToken:@"opaque-ann"].status, 200);
  XCTAssertEqual(provider.requests, 1, @"the answer is kept");
  XCTAssertEqual([self getProductsWithToken:@"opaque-client"].status, 200);
  XCTAssertEqualObjects(products.lastPrincipal.subject, @"reporting", @"username, without sub");

  OISServiceResponse *revoked = [self getProductsWithToken:@"revoked"];
  XCTAssertEqual(revoked.status, 401);
  XCTAssertTrue([[revoked header:@"WWW-Authenticate"] rangeOfString:@"error=\"invalid_token\""].location != NSNotFound);
  XCTAssertEqual([self getProductsWithToken:@"expired"].status, 401, @"active, the provider says, but expired");
  XCTAssertEqual([self getProductsWithToken:@"elsewhere"].status, 401, @"for another audience");
  NSInteger asked = provider.requests;
  XCTAssertEqual([self getProductsWithToken:@"revoked"].status, 401);
  XCTAssertEqual(provider.requests, asked, @"a refusal is kept too");

  introspection.requiredScopes = [NSSet setWithObject:@"odata.write"];
  XCTAssertEqual([self getProductsWithToken:@"opaque-ann"].status, 403);
  introspection.requiredScopes = nil;

  HSTokenIntrospectionAuthenticator *wrongSecret =
    [[HSTokenIntrospectionAuthenticator alloc] initWithEndpoint:[NSURL URLWithString:@"https://id.example.test/introspect"]
                                                          clientID:@"ois-api" clientSecret:@"guess"];
  wrongSecret.fetcher = provider;
  wrongSecret.cacheLifetime = 0;
  _service.authenticator = wrongSecret;
  XCTAssertEqual([self getProductsWithToken:@"opaque-ann"].status, 503, @"the provider would not answer");
}

#pragma mark Vocabularies

static NSComparisonPredicate *OISValidation(NSString *keyPath, NSPredicateOperatorType type, id constant)
{
  NSExpression *left = keyPath ? [NSExpression expressionForKeyPath:keyPath] : [NSExpression expressionForEvaluatedObject];
  return (NSComparisonPredicate *)[NSComparisonPredicate predicateWithLeftExpression:left rightExpression:[NSExpression expressionForConstantValue:constant]
                                                                             modifier:NSDirectPredicateModifier type:type options:0];
}

// Items with what Core and Validation say of them: constraints as Xcode
// writes them, and userInfo.
- (void)serveItems
{
  NSEntityDescription *item = [[NSEntityDescription alloc] init];
  item.name = @"Item";
  item.managedObjectClassName = @"NSManagedObject";
  item.userInfo = @{ @"OData.entitySet": @"Items", @"OData.description": @"Something in stock",
                     @"OData.annotations": @"{\"Validation.Constraint\": {\"FailureMessage\": \"A priced item needs a name\", "
                                           @"\"Condition\": {\"$Or\": [{\"$Eq\": [{\"$Path\": \"Price\"}, null]}, "
                                           @"{\"$Ne\": [{\"$Path\": \"Name\"}, null]}]}}}" };
  NSEntityDescription *tag = [[NSEntityDescription alloc] init];
  tag.name = @"Tag";
  tag.managedObjectClassName = @"NSManagedObject";
  tag.userInfo = @{ @"OData.entitySet": @"Tags" };

  NSAttributeDescription *identifier = OISSwatchAttribute(@"id", NSInteger32AttributeType, nil);
  identifier.userInfo = @{ @"OData.key": @"YES" };
  NSAttributeDescription *name = OISSwatchAttribute(@"name", NSStringAttributeType, nil);
  [name setValidationPredicates:@[ OISValidation(@"length", NSLessThanOrEqualToPredicateOperatorType, @50),
                                   OISValidation(nil, NSMatchesPredicateOperatorType, @"[A-Z].*") ]
         withValidationWarnings:@[ @(NSValidationStringTooLongError), @(NSValidationStringPatternMatchingError) ]];
  name.userInfo = @{ @"OData.description": @"What it is called",
                     @"OData.annotations": @"{\"Core.Description#fr\": \"Son nom\", \"Org.Example.V1.Searchable\": true}" };
  NSAttributeDescription *price = OISSwatchAttribute(@"price", NSDecimalAttributeType, nil);
  [price setValidationPredicates:@[ OISValidation(nil, NSGreaterThanOrEqualToPredicateOperatorType, [NSDecimalNumber zero]),
                                    OISValidation(nil, NSLessThanPredicateOperatorType, [NSDecimalNumber decimalNumberWithString:@"1000"]) ]
          withValidationWarnings:@[ @(NSValidationNumberTooSmallError), @(NSValidationNumberTooLargeError) ]];
  price.userInfo = @{ @"OData.annotations": @"{\"Validation.MultipleOf\": 0.25}" };
  NSAttributeDescription *colour = OISSwatchAttribute(@"colour", NSStringAttributeType, nil);
  [colour setValidationPredicates:@[ OISValidation(nil, NSInPredicateOperatorType, @[ @"red", @"blue" ]) ]
           withValidationWarnings:@[ @(NSValidationStringPatternMatchingError) ]];
  NSAttributeDescription *code = OISSwatchAttribute(@"code", NSStringAttributeType, nil);
  code.userInfo = @{ @"OData.immutable": @"YES",
                     @"OData.annotations": @"{\"Validation.Constraint#code\": {\"FailureMessage\": \"A code starts with a letter\", "
                                           @"\"Condition\": {\"$Apply\": [{\"$Path\": \"Code\"}, \"^[A-Z]\"], \"$Function\": \"odata.matchesPattern\"}}}" };
  NSAttributeDescription *stamp = OISSwatchAttribute(@"stamp", NSStringAttributeType, nil);
  stamp.userInfo = @{ @"OData.computed": @"YES" };
  NSAttributeDescription *note = OISSwatchAttribute(@"note", NSStringAttributeType, nil);
  note.userInfo = @{ @"OData.permissions": @"Read" };
  NSRelationshipDescription *tags = [[NSRelationshipDescription alloc] init];
  tags.name = @"tags";
  tags.destinationEntity = tag;
  tags.minCount = 0;
  tags.maxCount = 5;
  tags.optional = YES;
  NSAttributeDescription *tagID = OISSwatchAttribute(@"id", NSInteger32AttributeType, nil);
  tagID.userInfo = @{ @"OData.key": @"YES" };
  item.properties = @[ identifier, name, price, colour, code, stamp, note, tags ];
  tag.properties = @[ tagID ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ item, tag ];

  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  [self insert:@"Item" into:context values:@{ @"id": @1, @"name": @"Anvil", @"price": [NSDecimalNumber decimalNumberWithString:@"99"],
                                               @"code": @"A-1", @"stamp": @"made", @"note": @"heavy" }];
  XCTAssertTrue([context save:&error], @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

- (void)testVocabulariesInMetadata
{
  [self serveItems];
  _service.containerAnnotations = @{ @"Core.Description": @"The stock", @"Core.LongDescription#en": @"Everything in stock, by item" };
  HSJWTAuthenticator *jwt = [[HSJWTAuthenticator alloc] initWithIssuer:@"https://id.example.test/realms/ois" audience:@"ois-api"];
  jwt.keySet = @{ @"keys": @[] };
  jwt.requiredScopes = [NSSet setWithObjects:@"odata.read", nil];
  _service.authenticator = jwt;
  _service.allowsAnonymousRequests = YES;

  OISServiceResponse *metadata = [self get:@"$metadata"];
  XCTAssertEqual(metadata.status, 200);
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:metadata.data error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  NSString *type = @"Default.Item";
  XCTAssertEqualObjects([schema annotation:@"Core.Description" forTarget:type], @"Something in stock");
  XCTAssertEqualObjects([schema annotation:@"Core.Description" forTarget:@"Default.Item/Name"], @"What it is called");
  XCTAssertEqualObjects([schema annotation:@"Core.Description#fr" forTarget:@"Default.Item/Name"], @"Son nom");
  XCTAssertEqualObjects([schema annotation:@"Org.Example.V1.Searchable" forTarget:@"Default.Item/Name"], @YES, @"any term at all");
  XCTAssertEqualObjects([schema annotation:@"Validation.Pattern" forTarget:@"Default.Item/Name"], @"^[A-Z](?:\\r\\n|\\r(?!\\n)|[^\\r])*$");
  XCTAssertTrue([metadata.text rangeOfString:@"<Property Name=\"Name\" Type=\"Edm.String\" MaxLength=\"50\">"].location != NSNotFound, @"%@", metadata.text);
  XCTAssertEqualObjects([schema annotation:@"Validation.Minimum" forTarget:@"Default.Item/Price"], [NSDecimalNumber zero]);
  XCTAssertEqualObjects([schema annotation:@"Validation.Maximum" forTarget:@"Default.Item/Price"], [NSDecimalNumber decimalNumberWithString:@"1000"]);
  XCTAssertTrue([metadata.text rangeOfString:@"Org.OData.Validation.V1.Exclusive"].location != NSNotFound, @"below 1000, not up to it");
  XCTAssertEqualObjects([schema annotation:@"Validation.AllowedValues" forTarget:@"Default.Item/Colour"], (@[ @{ @"Value": @"red" }, @{ @"Value": @"blue" } ]));
  XCTAssertEqualObjects([schema annotation:@"Core.Immutable" forTarget:@"Default.Item/Code"], @YES);
  XCTAssertEqualObjects([schema annotation:@"Core.Computed" forTarget:@"Default.Item/Stamp"], @YES);
  XCTAssertEqualObjects([schema annotation:@"Core.Permissions" forTarget:@"Default.Item/Note"], @"Read");
  XCTAssertEqualObjects([schema annotation:@"Validation.MaxItems" forTarget:@"Default.Item/Tags"], @5);
  XCTAssertEqualObjects([schema annotation:@"Core.Description" forTarget:@"Default.Container"], @"The stock");
  XCTAssertEqualObjects([schema annotation:@"Core.LongDescription#en" forTarget:@"Default.Container"], @"Everything in stock, by item");
  NSArray *authorizations = [schema annotation:@"Authorization.Authorizations" forTarget:@"Default.Container"];
  XCTAssertEqualObjects([authorizations.firstObject objectForKey:@"@type"], @"Org.OData.Authorization.V1.OpenIDConnect");
  XCTAssertEqualObjects([authorizations.firstObject objectForKey:@"IssuerUrl"], @"https://id.example.test/realms/ois");
  NSArray *schemes = [schema annotation:@"Authorization.SecuritySchemes" forTarget:@"Default.Container"];
  XCTAssertEqualObjects(schemes, (@[ @{ @"Authorization": @"OpenIDConnect", @"RequiredScopes": @[ @"odata.read" ] } ]));
  for (NSString *vocabulary in @[ @"Core", @"Validation", @"Authorization" ]) {
    NSString *include = [NSString stringWithFormat:@"Namespace=\"Org.OData.%@.V1\" Alias=\"%@\"/>", vocabulary, vocabulary];
    XCTAssertTrue([metadata.text rangeOfString:include].location != NSNotFound, @"references %@", vocabulary);
  }
  XCTAssertEqualObjects(_service.metadataProblems, @[]);
}

- (void)testComputedAndImmutablePropertiesAreTheServices
{
  [self serveItems];
  OISServiceResponse *created = [self send:@"POST" path:@"Items" headers:nil body:@{ @"Id": @2, @"Name": @"Bolt", @"Code": @"B-2", @"Stamp": @"mine", @"Note": @"mine" }];
  XCTAssertEqual(created.status, 201, @"%@", created.text);
  XCTAssertEqualObjects(created.json[@"Stamp"], [NSNull null], @"a computed property is the service's to set");
  XCTAssertEqualObjects(created.json[@"Note"], [NSNull null], @"as is a read-only one");
  XCTAssertEqualObjects(created.json[@"Code"], @"B-2", @"an immutable one is set when the entity is made");

  XCTAssertEqual(([self send:@"PATCH" path:@"Items(1)" headers:nil body:@{ @"Code": @"A-2" }].status), 400, @"and not after");
  XCTAssertEqual(([self send:@"PATCH" path:@"Items(1)" headers:nil body:@{ @"Code": @"A-1", @"Stamp": @"changed" }].status), 204, @"the same value is no change");
  XCTAssertEqualObjects([self get:@"Items(1)/Stamp"].json[@"value"], @"made");
  XCTAssertEqual(([self send:@"PUT" path:@"Items(1)" headers:nil body:@{ @"Name": @"Anvil" }].status), 204);
  XCTAssertEqualObjects([self get:@"Items(1)/Code"].json[@"value"], @"A-1", @"PUT does not reset what cannot be written");
  XCTAssertEqualObjects([self get:@"Items(1)/Note"].json[@"value"], @"heavy");

  OISServiceResponse *invalid = [self send:@"PATCH" path:@"Items(1)" headers:nil body:@{ @"Price": @-1, @"Name": @"lowercase" }];
  XCTAssertEqual(invalid.status, 400, @"%@", invalid.text);
  XCTAssertEqualObjects([[invalid.json[@"error"][@"details"] valueForKey:@"target"] sortedArrayUsingSelector:@selector(compare:)], (@[ @"Name", @"Price" ]),
                        @"Core Data's validation, each property named");
}

- (NSURLRequest *)request:(NSString *)method in:(OISRecordingTransport *)transport since:(NSUInteger)index
{
  NSArray *requests = transport.requests;
  for (NSUInteger i = index; i < requests.count; i++) {
    if ([[requests[i] HTTPMethod] isEqualToString:method]) return requests[i];
  }
  return nil;
}

- (void)testClientsModelFromTheServicesVocabularies
{
  // The service writes Core and Validation from its model; a client
  // builds its model from that $metadata, validates as the service does,
  // and leaves out what the service sets.
  [self serveItems];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  [ODataIncrementalStore registerStore];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: transport } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSManagedObject *bad = [NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:context];
  [bad setValue:@3 forKey:@"id"];
  [bad setValue:@"lowercase" forKey:@"name"];
  [bad setValue:[NSDecimalNumber decimalNumberWithString:@"1000"] forKey:@"price"];
  NSUInteger asked = transport.requests.count;
  XCTAssertFalse([context save:&error], @"Pattern, and Maximum 1000 exclusive");
  XCTAssertEqual(transport.requests.count, asked, @"refused before the service is asked");
  [context deleteObject:bad];

  NSManagedObject *odd = [NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:context];
  [odd setValue:@4 forKey:@"id"];
  [odd setValue:@"Awl" forKey:@"name"];
  [odd setValue:[NSDecimalNumber decimalNumberWithString:@"1.3"] forKey:@"price"];
  asked = transport.requests.count;
  error = nil;
  XCTAssertFalse([context save:&error], @"Validation.MultipleOf 0.25");
  XCTAssertEqualObjects(error.userInfo[NSValidationKeyErrorKey], @"price", @"%@", error);
  XCTAssertEqual(transport.requests.count, asked, @"refused before the service is asked");
  [odd setValue:nil forKey:@"name"];
  [odd setValue:[NSDecimalNumber decimalNumberWithString:@"1.5"] forKey:@"price"];
  error = nil;
  XCTAssertFalse([context save:&error], @"the entity's constraint");
  XCTAssertEqualObjects(error.localizedDescription, @"A priced item needs a name", @"%@", error);
  XCTAssertEqual(transport.requests.count, asked);
  [context deleteObject:odd];

  NSManagedObject *item = [NSEntityDescription insertNewObjectForEntityForName:@"Item" inManagedObjectContext:context];
  [item setValue:@3 forKey:@"id"];
  [item setValue:@"Chisel" forKey:@"name"];
  [item setValue:@"C-3" forKey:@"code"];
  [item setValue:@"mine" forKey:@"stamp"];
  NSUInteger before = transport.requests.count;
  XCTAssertTrue([context save:&error], @"%@", error);
  NSURLRequest *post = [self request:@"POST" in:transport since:before];
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:post.HTTPBody ?: [NSData data] options:0 error:NULL];
  XCTAssertNotNil(post, @"%@", [transport.requests valueForKey:@"HTTPMethod"]);
  XCTAssertEqualObjects(body[@"Code"], @"C-3", @"an immutable property is sent when the entity is made");
  XCTAssertNil(body[@"Stamp"], @"a computed one never");

  [item setValue:@"C-4" forKey:@"code"];
  [item setValue:@"Chisels" forKey:@"name"];
  before = transport.requests.count;
  XCTAssertTrue([context save:&error], @"%@", error);
  NSURLRequest *patch = [self request:@"PATCH" in:transport since:before];
  NSDictionary *changes = [NSJSONSerialization JSONObjectWithData:patch.HTTPBody ?: [NSData data] options:0 error:NULL];
  XCTAssertNotNil(patch, @"%@", [transport.requests valueForKey:@"HTTPMethod"]);
  XCTAssertEqualObjects(changes.allKeys, @[ @"Name" ], @"nor an immutable one after");
}

#pragma mark Messages

- (void)testMessagesAlongsideTheAnswer
{
  [_service setHandler:[[OISChattyProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  NSArray *messages = [self get:@"Products"].json[ODataMessagesAnnotation];
  XCTAssertEqualObjects([messages valueForKey:@"code"], @[ @"Listed" ]);
  XCTAssertEqualObjects([messages.firstObject objectForKey:@"severity"], @"info");
  XCTAssertEqualObjects([[ODataMessage messagesInJSON:[self get:@"Products"].json].firstObject message], @"Products no longer sold are listed too");

  NSDictionary *included = @{ @"\"*\"": @YES, @"\"-*\"": @NO, @"\"Core.Messages\"": @YES, @"\"-Core.*\"": @NO,
                              @"\"*,-Org.OData.Core.V1.Messages\"": @NO, @"\"-*,Core.*\"": @YES, @"\"Measures.*\"": @NO };
  for (NSString *preference in included) {
    NSDictionary *prefer = @{ @"Prefer": [@"odata.include-annotations=" stringByAppendingString:preference] };
    OISServiceResponse *response = [self send:@"GET" path:@"Products" headers:prefer body:nil];
    XCTAssertEqual(response.json[ODataMessagesAnnotation] != nil, [included[preference] boolValue], @"%@", preference);
  }

  OISServiceResponse *created = [self send:@"POST" path:@"Products" headers:nil body:@{ @"ProductName": @"Mate", @"UnitPrice": @3.333 }];
  XCTAssertEqual(created.status, 201);
  // The insert's, and the handler's for the key read before it.
  NSDictionary *warning = [[created.json[ODataMessagesAnnotation] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"code == 'Rounded'"]] firstObject];
  XCTAssertEqualObjects(warning[@"target"], @"UnitPrice");
  XCTAssertEqualObjects(warning[@"severity"], @"warning");
  OISServiceResponse *minimal = [self send:@"POST" path:@"Products" headers:@{ @"Prefer": @"return=minimal" } body:@{ @"ProductName": @"Mate" }];
  XCTAssertEqual(minimal.status, 204, @"no body to carry them");
}

- (void)testClientsHearTheMessages
{
  [_service setHandler:[[OISChattyProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  NSPersistentStore *store = [client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                            URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                                        options:@{ ODataIncrementalStoreTransportOption: _service } error:&error];
  XCTAssertNotNil(store, @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSMutableArray<NSNotification *> *heard = [NSMutableArray array];
  id observer = [[NSNotificationCenter defaultCenter] addObserverForName:ODataIncrementalStoreDidReceiveMessagesNotification object:store
                                                                   queue:nil usingBlock:^(NSNotification *note) {
    [heard addObject:note];
  }];

  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  XCTAssertNotNil([context executeFetchRequest:fetch error:&error], @"%@", error);
  XCTAssertEqual(heard.count, 1u);
  ODataMessage *listed = [heard.firstObject.userInfo[ODataMessagesKey] firstObject];
  XCTAssertEqualObjects(listed.code, @"Listed");
  XCTAssertNil(heard.firstObject.userInfo[ODataMessagesObjectIDKey], @"of the collection");
  XCTAssertTrue([[heard.firstObject.userInfo[ODataMessagesURLKey] path] hasSuffix:@"/Products"]);

  NSManagedObject *mate = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
  [mate setValue:@"Mate" forKey:@"name"];
  [heard removeAllObjects];
  XCTAssertTrue([context save:&error], @"%@", error);
  XCTAssertEqual(heard.count, 1u);
  // The insert's, and the handler's for the key read before it.
  NSArray<ODataMessage *> *messages = heard.firstObject.userInfo[ODataMessagesKey];
  ODataMessage *rounded = [messages filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"code == 'Rounded'"]].firstObject;
  XCTAssertEqualObjects(rounded.code, @"Rounded");
  XCTAssertEqualObjects(rounded.target, @"UnitPrice");
  XCTAssertEqualObjects(heard.firstObject.userInfo[ODataMessagesObjectIDKey], mate.objectID, @"about the product it made");
  [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

#pragma mark Beyond Core Data's validation

- (void)testMultipleOfAndConstraints
{
  [self serveItems];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  XCTAssertEqualObjects([schema annotation:@"Validation.MultipleOf" forTarget:@"Default.Item/Price"], [NSDecimalNumber decimalNumberWithString:@"0.25"]);
  NSDictionary *constraint = [schema annotation:@"Validation.Constraint" forTarget:@"Default.Item"];
  XCTAssertEqualObjects(constraint[@"FailureMessage"], @"A priced item needs a name");
  XCTAssertNotNil(constraint[@"Condition"][@"$Or"]);

  OISServiceResponse *step = [self send:@"PATCH" path:@"Items(1)" headers:nil body:@{ @"Price": @1.3 }];
  XCTAssertEqual(step.status, 400);
  XCTAssertEqualObjects(step.json[@"error"][@"target"], @"Price", @"%@", step.text);
  XCTAssertEqual(([self send:@"PATCH" path:@"Items(1)" headers:nil body:@{ @"Price": @1.25 }].status), 204);

  OISServiceResponse *nameless = [self send:@"POST" path:@"Items" headers:nil body:@{ @"Id": @5, @"Price": @5 }];
  XCTAssertEqual(nameless.status, 400);
  XCTAssertEqualObjects(nameless.json[@"error"][@"message"], @"A priced item needs a name");
  XCTAssertEqual(([self send:@"POST" path:@"Items" headers:nil body:@{ @"Id": @5 }].status), 201, @"no price, no name needed");

  OISServiceResponse *code = [self send:@"POST" path:@"Items" headers:nil body:@{ @"Id": @6, @"Name": @"Rasp", @"Code": @"r-6" }];
  XCTAssertEqual(code.status, 400);
  XCTAssertEqualObjects(code.json[@"error"][@"message"], @"A code starts with a letter");
  XCTAssertEqualObjects(code.json[@"error"][@"target"], @"Code");
  XCTAssertEqual([self get:@"Items/$count"].text.integerValue, 2, @"neither was made");
}

#pragma mark Signing in as the service says

- (NSManagedObjectContext *)clientOver:(id<ODataTransport>)transport options:(NSDictionary *)options error:(NSError **)error
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:options ?: @{}];
  all[ODataIncrementalStoreTransportOption] = transport;
  if (![client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                      URL:[NSURL URLWithString:@"http://example.test/odata/"] options:all error:error]) return nil;
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  return context;
}

- (void)testClientsSignInAsTheServiceSays
{
  NSDictionary *fixtures = [NSJSONSerialization JSONObjectWithData:[OISJWTFixturesJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
  HSJWTAuthenticator *jwt = [[HSJWTAuthenticator alloc] initWithIssuer:fixtures[@"issuer"] audience:fixtures[@"audience"]];
  jwt.keySet = fixtures[@"keys"];
  jwt.requiredScopes = [NSSet setWithObject:@"odata.read"];
  _service.authenticator = jwt;
  _service.allowsAnonymousMetadata = YES;
  XCTAssertEqual([self get:@"$metadata"].status, 200, @"$metadata to anyone");
  XCTAssertEqual([self get:@"Products"].status, 401, @"the rest not");

  // OpenID Connect: a token from the provider, refreshed once refused.
  OISTokenProvider *provider = [[OISTokenProvider alloc] init];
  provider.token = fixtures[@"tokens"][@"expired"];
  provider.freshToken = fixtures[@"tokens"][@"rs256"];
  NSError *error = nil;
  NSManagedObjectContext *context = [self clientOver:_service options:@{ ODataIncrementalStoreCredentialProviderOption: provider } error:&error];
  XCTAssertNotNil(context, @"%@", error);
  NSArray *rows = [context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Product"] error:&error];
  XCTAssertEqual(rows.count, 5u, @"%@", error);
  NSMutableArray *refreshes = [NSMutableArray array];
  for (NSArray *call in provider.asked) [refreshes addObject:call.lastObject];
  XCTAssertEqualObjects(refreshes, (@[ @NO, @YES ]), @"asked, then asked again after a 401");
  ODataSchemaAuthorization *asked = [provider.asked.firstObject firstObject];
  XCTAssertEqualObjects(asked.kind, @"OpenIDConnect");
  XCTAssertEqualObjects(asked.issuerURL.absoluteString, fixtures[@"issuer"]);
  XCTAssertEqualObjects(asked.requiredScopes, @[ @"odata.read" ]);

  // Nothing to sign in with: the error says what would do.
  context = [self clientOver:_service options:nil error:&error];
  error = nil;
  XCTAssertNil([context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Product"] error:&error]);
  XCTAssertEqual([error.userInfo[ODataErrorHTTPStatusKey] integerValue], 401);
  NSString *suggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey];
  XCTAssertTrue([suggestion rangeOfString:@"OpenIDConnect"].location != NSNotFound && [suggestion rangeOfString:fixtures[@"issuer"]].location != NSNotFound,
                @"%@", suggestion);

  // An API key, where the service wants it.
  _service.authenticator = [[OISKeyAuthenticator alloc] init];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  context = [self clientOver:transport options:@{ ODataIncrementalStoreAPIKeyOption: @"sesame" } error:&error];
  XCTAssertNotNil(context, @"%@", error);
  rows = [context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Category"] error:&error];
  XCTAssertEqual(rows.count, 2u, @"%@", error);
  NSURLRequest *signed_ = transport.requests.lastObject;
  XCTAssertEqualObjects([signed_ valueForHTTPHeaderField:@"X-API-Key"], @"sesame");
  XCTAssertNil([signed_ valueForHTTPHeaderField:@"Authorization"]);

  // $metadata behind the sign-in too, so no way is known: the provider
  // asked once the service refuses.
  _service.authenticator = jwt;
  _service.allowsAnonymousMetadata = NO;
  XCTAssertEqual([self get:@"$metadata"].status, 401);
  provider = [[OISTokenProvider alloc] init];
  provider.token = fixtures[@"tokens"][@"rs256"];
  transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  context = [self clientOver:transport options:@{ ODataIncrementalStoreCredentialProviderOption: provider } error:&error];
  XCTAssertNotNil(context, @"%@", error);
  rows = [context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Product"] error:&error];
  XCTAssertEqual(rows.count, 5u, @"%@", error);
  XCTAssertEqualObjects(provider.asked, (@[ @[ [NSNull null], @NO ] ]), @"asked once, with no way known");
  signed_ = transport.requests.lastObject;
  XCTAssertEqualObjects([signed_ valueForHTTPHeaderField:@"Authorization"],
                        ([NSString stringWithFormat:@"Bearer %@", fixtures[@"tokens"][@"rs256"]]));
}

#pragma mark Capabilities

- (void)testCapabilitiesInMetadata
{
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.nonFilterableProperties = [NSSet setWithObject:@"QuantityPerUnit"];
  products.nonSortableProperties = [NSSet setWithObjects:@"ProductName", @"UnitPrice", nil];
  [_service setHandler:products forEntitySet:@"Products"];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  XCTAssertEqualObjects([schema capability:@"Capabilities.ConformanceLevel" forEntitySet:@"Products"], @"Intermediate");
  XCTAssertEqualObjects([schema capability:@"Capabilities.BatchSupported" forEntitySet:nil], @YES);
  XCTAssertEqualObjects([[schema capability:@"Capabilities.BatchSupport" forEntitySet:nil] objectForKey:@"ContinueOnErrorSupported"], @YES);
  XCTAssertTrue([[schema capability:@"Capabilities.FilterFunctions" forEntitySet:nil] containsObject:@"year"]);
  XCTAssertEqualObjects([schema capability:@"Capabilities.SearchRestrictions" forEntitySet:@"Categories"], @{ @"Searchable": @YES });
  XCTAssertEqualObjects([schema capability:@"Capabilities.FilterRestrictions" forEntitySet:@"Products"],
                        @{ @"NonFilterableProperties": @[ @{ @"$PropertyPath": @"QuantityPerUnit" } ] });
  NSArray *nonSortable = [schema capability:@"Capabilities.SortRestrictions" forEntitySet:@"Products"][@"NonSortableProperties"];
  XCTAssertEqual(nonSortable.count, 2u);
  XCTAssertNil([schema capability:@"Capabilities.FilterRestrictions" forEntitySet:@"Categories"]);

  XCTAssertEqual([self get:@"Products?$filter=QuantityPerUnit eq 'x'"].status, 400, @"as it says");
  XCTAssertEqual([self get:@"Products?$orderby=ProductName"].status, 400);
  XCTAssertEqual([self get:@"Products?$filter=UnitPrice gt 10&$orderby=ProductID"].status, 200);
  XCTAssertEqual([self get:@"Categories(1)/Products?$filter=QuantityPerUnit eq 'x'"].status, 400, @"however the products are reached");
}

// A to-many prefetched with $expand: its members are kept, so reading the
// relationship asks nothing, until a save may have moved them.
- (void)testPrefetchedToManyNeedsNoRequest
{
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *context = [self clientOver:transport options:nil error:&error];
  XCTAssertNotNil(context, @"%@", error);
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  fetch.relationshipKeyPathsForPrefetching = @[ @"products" ];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
  NSArray *categories = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqual(categories.count, 2u, @"%@", error);
  NSUInteger before = transport.requests.count;
  XCTAssertTrue([[[transport.requests.lastObject URL] query] containsString:@"$expand=Products"], @"%@", transport.requests.lastObject);
  NSSet *beverages = [categories[0] valueForKey:@"products"];
  NSSet *condiments = [categories[1] valueForKey:@"products"];
  XCTAssertEqual(beverages.count + condiments.count, 5u);
  XCTAssertEqualObjects([[beverages valueForKey:@"name"] containsObject:@"Chai"] ? @YES : @NO, @YES);
  XCTAssertEqual(transport.requests.count, before, @"no request for either: %@",
                 [[transport.requests subarrayWithRange:NSMakeRange(before, transport.requests.count - before)] valueForKey:@"URL"]);

  // A product moved: the next time the collection is read, it is asked for.
  NSManagedObject *chai = [[beverages filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"name == 'Chai'"]] anyObject];
  [chai setValue:categories[1] forKey:@"category"];
  XCTAssertTrue([context save:&error], @"%@", error);
  [context refreshObject:categories[1] mergeChanges:NO];
  before = transport.requests.count;
  XCTAssertTrue([[[categories[1] valueForKey:@"products"] valueForKey:@"name"] containsObject:@"Chai"]);
  XCTAssertGreaterThan(transport.requests.count, before, @"asked again after the save");
}

// Parcels: an amount whose currency is another property, a weight in kg,
// a JSON payload kept as it is and JSON notes kept as text.
- (void)serveParcels
{
  NSEntityDescription *parcel = [[NSEntityDescription alloc] init];
  parcel.name = @"Parcel";
  parcel.managedObjectClassName = @"NSManagedObject";
  parcel.userInfo = @{ @"OData.entitySet": @"Parcels" };
  NSAttributeDescription *identifier = OISSwatchAttribute(@"id", NSInteger32AttributeType, nil);
  identifier.userInfo = @{ @"OData.key": @"YES", @"OData.property": @"ParcelID" };
  NSAttributeDescription *price = OISSwatchAttribute(@"price", NSDecimalAttributeType, nil);
  price.userInfo = @{ @"OData.isoCurrency": @"currency" };
  NSAttributeDescription *weight = OISSwatchAttribute(@"weight", NSDoubleAttributeType, nil);
  weight.userInfo = @{ @"OData.unit": @"kg", @"OData.scale": @"2" };
  NSAttributeDescription *payload = OISSwatchAttribute(@"payload", NSTransformableAttributeType, @"Org.OData.JSON.V1.JSON");
  payload.valueTransformerName = @"NSSecureUnarchiveFromData";
  NSAttributeDescription *notes = OISSwatchAttribute(@"notes", NSStringAttributeType, @"Org.OData.JSON.V1.JSON");
  parcel.properties = @[ identifier, price, OISSwatchAttribute(@"currency", NSStringAttributeType, nil), weight, payload, notes ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ parcel ];
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error], @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

// The Measures and JSON vocabularies, both ways.
- (void)testMeasuresAndJSON
{
  [self serveParcels];
  XCTAssertEqualObjects(_service.metadataProblems, @[]);
  OISServiceResponse *metadata = [self get:@"$metadata"];
  ODataSchema *schema = [ODataSchema schemaWithData:metadata.data error:NULL];
  XCTAssertEqualObjects([schema annotation:@"Measures.ISOCurrency" forTarget:@"Default.Parcel/Price"], @{ @"$Path": @"Currency" });
  XCTAssertEqualObjects([schema annotation:@"Measures.Unit" forTarget:@"Default.Parcel/Weight"], @"kg");
  XCTAssertEqualObjects([schema annotation:@"Measures.Scale" forTarget:@"Default.Parcel/Weight"], @2);
  ODataSchemaEntityType *type = [schema entityTypeNamed:@"Default.Parcel"];
  XCTAssertEqualObjects([schema property:@"Payload" ofEntityType:type].type, @"Org.OData.JSON.V1.JSON");
  XCTAssertTrue([metadata.text containsString:@"Org.OData.JSON.V1.xml"], @"the JSON vocabulary is referenced");

  NSDictionary *payload = @{ @"a": @[ @1, @2 ], @"b": [NSNull null], @"c": @{ @"d": @"e" } };
  OISServiceResponse *created = [self send:@"POST" path:@"Parcels" headers:nil body:@{
    @"ParcelID": @1, @"Price": @9.5, @"Currency": @"EUR", @"Weight": @1.25, @"Payload": payload, @"Notes": @[ @"fragile", @3 ] }];
  XCTAssertEqual(created.status, 201, @"%@", created.text);
  NSDictionary *row = [self get:@"Parcels(1)"].json;
  XCTAssertEqualObjects(row[@"Payload"], payload, @"JSON as it was");
  XCTAssertEqualObjects(row[@"Notes"], (@[ @"fragile", @3 ]), @"JSON kept as text, read back as JSON");

  // The client, with the model $metadata makes.
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  NSEntityDescription *entity = model.entitiesByName[@"Parcel"];
  XCTAssertEqual([entity.attributesByName[@"payload"] attributeType], NSTransformableAttributeType);
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSManagedObject *fetched = [[context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Parcel"] error:&error] firstObject];
  XCTAssertEqualObjects([fetched valueForKey:@"payload"], payload, @"%@", error);
  XCTAssertEqualObjects([fetched valueForKey:@"notes"], (@[ @"fragile", @3 ]));
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  XCTAssertEqualObjects([mapper unitOfAttribute:entity.attributesByName[@"weight"]], @"kg");
  XCTAssertEqualObjects([mapper scaleOfAttribute:entity.attributesByName[@"weight"]], @2);
  XCTAssertEqualObjects([mapper currencyOfAttribute:entity.attributesByName[@"price"] inObject:fetched], @"EUR");
  XCTAssertNil([mapper unitOfAttribute:entity.attributesByName[@"price"]]);

  [fetched setValue:@{ @"a": @"changed" } forKey:@"payload"];
  XCTAssertTrue([context save:&error], @"%@", error);
  XCTAssertEqualObjects([self get:@"Parcels(1)"].json[@"Payload"], @{ @"a": @"changed" });
}

static NSString *OISHTTPDate(NSDate *date)
{
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
  return [formatter stringFromDate:date];
}

// Remembered answers take no more memory than repeatabilityMemory: past
// it the oldest go (a repeat of one is done again), the newest stay.
- (void)testRepeatableAnswersKeepToTheirMemory
{
  NSDictionary *(^headers)(NSString *) = ^NSDictionary *(NSString *requestID) {
    return @{ @"Repeatability-Request-ID": requestID, @"Repeatability-First-Sent": OISHTTPDate([NSDate date]) };
  };
  OISServiceResponse *one = [self send:@"POST" path:@"Categories" headers:headers(@"m1") body:@{ @"CategoryName": @"One" }];
  // Room for about two answers like it.
  _service.repeatabilityMemory = 2 * (one.data.length + 256) + 64;
  [self send:@"POST" path:@"Categories" headers:headers(@"m2") body:@{ @"CategoryName": @"Two" }];
  OISServiceResponse *three = [self send:@"POST" path:@"Categories" headers:headers(@"m3") body:@{ @"CategoryName": @"Three" }];
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"5");
  OISServiceResponse *threeAgain = [self send:@"POST" path:@"Categories" headers:headers(@"m3") body:@{ @"CategoryName": @"Three" }];
  XCTAssertEqualObjects(threeAgain.json[@"CategoryID"], three.json[@"CategoryID"], @"the newest, remembered");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"5");
  OISServiceResponse *oneAgain = [self send:@"POST" path:@"Categories" headers:headers(@"m1") body:@{ @"CategoryName": @"One" }];
  XCTAssertEqual(oneAgain.status, 201);
  XCTAssertNotEqualObjects(oneAgain.json[@"CategoryID"], one.json[@"CategoryID"], @"the oldest, let go of: done again");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"6");
  // An answer larger than all of it is not kept at all.
  _service.repeatabilityMemory = 0;
  OISServiceResponse *four = [self send:@"POST" path:@"Categories" headers:headers(@"m4") body:@{ @"CategoryName": @"Four" }];
  OISServiceResponse *fourAgain = [self send:@"POST" path:@"Categories" headers:headers(@"m4") body:@{ @"CategoryName": @"Four" }];
  XCTAssertNotEqualObjects(fourAgain.json[@"CategoryID"], four.json[@"CategoryID"]);
}

// Repeatable requests: the same request again is the same answer, not the
// same change twice.
- (void)testRepeatableRequests
{
  NSDictionary *headers = @{ @"Repeatability-Request-ID": @"3f7c", @"Repeatability-First-Sent": OISHTTPDate([NSDate date]) };
  OISServiceResponse *first = [self send:@"POST" path:@"Categories" headers:headers body:@{ @"CategoryName": @"Seafood" }];
  XCTAssertEqual(first.status, 201, @"%@", first.text);
  XCTAssertEqualObjects([first header:@"Repeatability-Result"], @"accepted");
  OISServiceResponse *again = [self send:@"POST" path:@"Categories" headers:headers body:@{ @"CategoryName": @"Seafood" }];
  XCTAssertEqual(again.status, 201);
  XCTAssertEqualObjects(again.json[@"CategoryID"], first.json[@"CategoryID"], @"the same answer");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"3", @"made once");

  XCTAssertEqualObjects([[self send:@"POST" path:@"Categories" headers:headers body:@{ @"CategoryName": @"Grains" }] header:@"Repeatability-Result"], @"rejected",
                        @"the ID of another request");
  NSDictionary *old = @{ @"Repeatability-Request-ID": @"9a0b", @"Repeatability-First-Sent": OISHTTPDate([NSDate dateWithTimeIntervalSinceNow:-7200]) };
  OISServiceResponse *stale = [self send:@"POST" path:@"Categories" headers:old body:@{ @"CategoryName": @"Grains" }];
  XCTAssertEqual(stale.status, 400);
  XCTAssertEqualObjects([stale header:@"Repeatability-Result"], @"rejected");
  XCTAssertEqual(([self send:@"POST" path:@"Categories" headers:@{ @"Repeatability-Request-ID": @"x" } body:@{ @"CategoryName": @"G" }].status), 400,
                 @"no First-Sent");
  XCTAssertNil([[self send:@"GET" path:@"Categories" headers:headers data:nil] header:@"Repeatability-Result"], @"reads are not remembered");
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  XCTAssertEqualObjects([schema annotation:@"Repeatability.Supported" forTarget:schema.containerName], @YES);

  // The client: a write whose answer is lost is sent again, and made once.
  OISLosingTransport *transport = [[OISLosingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *context = [self clientOver:transport options:nil error:&error];
  XCTAssertNotNil(context, @"%@", error);
  NSManagedObject *category = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:context];
  [category setValue:@"Produce" forKey:@"name"];
  XCTAssertTrue([context save:&error], @"%@", error);
  XCTAssertEqual(transport.lost, 1);
  NSArray *posts = [transport.requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"HTTPMethod == 'POST'"]];
  XCTAssertEqual(posts.count, 2u, @"sent twice");
  XCTAssertEqualObjects([posts[0] valueForHTTPHeaderField:@"Repeatability-Request-ID"], [posts[1] valueForHTTPHeaderField:@"Repeatability-Request-ID"]);
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"4", @"and made once");

  _service.repeatabilityDuration = 0;
  headers = @{ @"Repeatability-Request-ID": @"off", @"Repeatability-First-Sent": OISHTTPDate([NSDate date]) };
  [self send:@"POST" path:@"Categories" headers:headers body:@{ @"CategoryName": @"A" }];
  [self send:@"POST" path:@"Categories" headers:headers body:@{ @"CategoryName": @"A" }];
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"6", @"off: each made");
}

// Data Aggregation's other transformations, before a grouping and after.
- (void)testApplyTransformations
{
  NSArray *(^names)(NSString *) = ^NSArray *(NSString *query) {
    OISServiceResponse *r = [self get:query];
    XCTAssertEqual(r.status, 200, @"%@: %@", query, r.text);
    return [r.json[@"value"] valueForKey:@"ProductName"];
  };
  OISServiceResponse *r = [self get:@"Products?$apply=compute(UnitPrice mul 2 as Twice)/filter(Twice gt 40)&$orderby=Twice desc"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualWithAccuracy([[r.json[@"value"] firstObject][@"Twice"] doubleValue], 44.0, 0.001);
  XCTAssertEqualObjects(r.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products");

  r = [self get:@"Products?$apply=compute(UnitPrice mul 2 as Twice)/groupby((Category/CategoryName),aggregate(Twice with sum as Total))&$orderby=Category/CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualWithAccuracy([[r.json[@"value"] firstObject][@"Total"] doubleValue], 74.0, 0.001, @"%@", r.text);
  XCTAssertEqualWithAccuracy([[r.json[@"value"] lastObject][@"Total"] doubleValue], 106.7, 0.001);

  XCTAssertEqualObjects(names(@"Products?$apply=topcount(2,UnitPrice)"), (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects(names(@"Products?$apply=bottomsum(28,UnitPrice)"), (@[ @"Aniseed Syrup", @"Chai" ]));
  XCTAssertEqualObjects(names(@"Products?$apply=toppercent(50,UnitPrice)"), (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix", @"Chang" ]));
  XCTAssertEqualObjects(names(@"Products?$apply=orderby(UnitPrice desc)/skip(1)/top(2)"), (@[ @"Chef Anton's Gumbo Mix", @"Chang" ]));
  XCTAssertEqualObjects(names(@"Products?$apply=search(Chai)"), @[ @"Chai" ]);
  XCTAssertEqual(names(@"Products?$apply=identity").count, 5u);

  // After a grouping: its rows.
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))/topcount(1,Total)/compute(Total mul 2 as Double)"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSDictionary *row = [r.json[@"value"] firstObject];
  XCTAssertEqualObjects(row[@"Category"][@"CategoryName"], @"Condiments", @"%@", r.text);
  XCTAssertEqualWithAccuracy([row[@"Double"] doubleValue], 106.7, 0.001);
  XCTAssertEqual([r.json[@"value"] count], 1u);

  // concat: each sequence on the same input, one after the other.
  XCTAssertEqualObjects(names(@"Products?$apply=concat(topcount(1,UnitPrice),bottomcount(1,UnitPrice))"),
                        (@[ @"Chef Anton's Cajun Seasoning", @"Aniseed Syrup" ]));
  r = [self get:@"Products?$apply=concat(aggregate(UnitPrice with sum as Total),groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total)))"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *totals = r.json[@"value"];
  XCTAssertEqual(totals.count, 3u, @"the whole, then each category: %@", r.text);
  XCTAssertEqualWithAccuracy([totals.firstObject[@"Total"] doubleValue], 90.35, 0.001);
  XCTAssertNil(totals.firstObject[@"Category"]);

  // expand: a navigation property, with a filter of its own.
  r = [self get:@"Products?$apply=filter(ProductID eq 1)/expand(Category)"];
  XCTAssertEqualObjects([[r.json[@"value"] firstObject][@"Category"] objectForKey:@"CategoryName"], @"Beverages", @"%@", r.text);
  r = [self get:@"Categories?$apply=filter(CategoryID eq 1)/expand(Products,filter(UnitPrice gt 18))"];
  XCTAssertEqualObjects([[[r.json[@"value"] firstObject] objectForKey:@"Products"] valueForKey:@"ProductName"], @[ @"Chang" ], @"%@", r.text);

  XCTAssertEqual([self get:@"Products?$apply=concat(identity,aggregate(UnitPrice with sum as Total))"].status, 501, @"entities and groups");
  XCTAssertEqual([self get:@"Products?$apply=nest(groupby((Category/CategoryName)) as Grouped)"].status, 501);
  XCTAssertEqual([self get:@"Products?$apply=concat(identity)"].status, 400);
  XCTAssertEqual([self get:@"Products?$apply=top(two)"].status, 400);
}

// $filter's string functions, as patterns a store evaluates.
- (void)testStringFunctions
{
  NSArray *(^names)(NSString *) = ^NSArray *(NSString *filter) {
    OISServiceResponse *r = [self get:[NSString stringWithFormat:@"Products?$filter=%@&$orderby=ProductID", filter]];
    XCTAssertEqual(r.status, 200, @"%@: %@", filter, r.text);
    return [r.json[@"value"] valueForKey:@"ProductName"];
  };
  XCTAssertEqualObjects(names(@"substring(ProductName,1) eq 'hai'"), @[ @"Chai" ]);
  XCTAssertEqual(names(@"substring(ProductName,0,4) eq 'Chef'").count, 2u);
  XCTAssertEqual(names(@"substring(ProductName,0,4) ne 'Chef'").count, 3u);
  XCTAssertEqualObjects(names(@"trim(ProductName) eq 'Chai'"), @[ @"Chai" ]);
  XCTAssertEqual(names(@"indexof(ProductName,'Anton') eq 5").count, 2u);
  XCTAssertEqual(names(@"indexof(ProductName,'z') eq -1").count, 5u);
  XCTAssertEqualObjects(names(@"indexof(ProductName,'a') ge 0"), (@[ @"Chai", @"Chang", @"Chef Anton's Cajun Seasoning" ]));
  XCTAssertEqualObjects(names(@"indexof(ProductName,'a') lt 3"), (@[ @"Chai", @"Chang", @"Aniseed Syrup", @"Chef Anton's Gumbo Mix" ]), @"-1 is less");
  XCTAssertEqualObjects(names(@"concat(ProductName,' tea') eq 'Chai tea'"), @[ @"Chai" ]);
  XCTAssertEqualObjects(names(@"concat('The ',ProductName) eq 'The Chang'"), @[ @"Chang" ]);
  XCTAssertTrue([[self get:@"$metadata"].text containsString:@"<String>substring</String>"]);
  XCTAssertEqual([self get:@"Products?$filter=substring(ProductName,1) gt 'a'"].status, 501);
  XCTAssertEqual([self get:@"Products?$filter=concat(ProductName,QuantityPerUnit) eq 'x'"].status, 501);
}

// Grouping what is grouped; $select and $expand after $apply;
// $schemaversion.
- (void)testApplyMore
{
  OISServiceResponse *r = [self get:@"Products?$apply=groupby((Category/CategoryName,Discontinued),aggregate(UnitPrice with sum as Total))"
                                     @"/groupby((Category/CategoryName),aggregate(Total with sum as All))&$orderby=Category/CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualWithAccuracy([[r.json[@"value"] lastObject][@"All"] doubleValue], 53.35, 0.001, @"%@", r.text);
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))/aggregate(Total with max as Most)"];
  XCTAssertEqualWithAccuracy([[r.json[@"value"] firstObject][@"Most"] doubleValue], 53.35, 0.001, @"%@", r.text);

  r = [self get:@"Products?$apply=topcount(1,UnitPrice)&$select=ProductName&$expand=Category"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSDictionary *top = [r.json[@"value"] firstObject];
  XCTAssertEqualObjects(top[@"ProductName"], @"Chef Anton's Cajun Seasoning");
  XCTAssertNil(top[@"UnitPrice"], @"only what $select names");
  XCTAssertEqualObjects(top[@"Category"][@"CategoryName"], @"Condiments");
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total,$count as N))&$select=Total"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertNotNil([r.json[@"value"] firstObject][@"Total"]);
  XCTAssertNil([r.json[@"value"] firstObject][@"N"]);
  XCTAssertEqual([self get:@"Products?$apply=groupby((Category/CategoryName))&$expand=Category"].status, 400);

  XCTAssertEqual([self get:@"Products?$schemaversion=*"].status, 200);
  XCTAssertEqual([self get:@"Products?$schemaversion=2"].status, 404);
}

// Schema versions (Part 1, 11.2.12): $metadata says the service's
// (Core.SchemaVersion); a request names the one it is made against; another
// only where the service reads it (upgradeBody), and a batch's requests
// have the batch's.
- (void)testSchemaVersions
{
  _service.modelVersion = @"2";
  OISServiceResponse *metadata = [self get:@"$metadata"];
  XCTAssertTrue([metadata.text rangeOfString:@"<Annotation Term=\"Org.OData.Core.V1.SchemaVersion\"><String>2</String></Annotation></Schema>"].location
                    != NSNotFound, @"%@", metadata.text);
  XCTAssertEqual([self get:@"Products?$schemaversion=2"].status, 200);
  XCTAssertEqual([self get:@"Products?$schemaversion=*"].status, 200);
  XCTAssertEqual([self get:@"Products?$schemaversion=1"].status, 404, @"a version the service does not read");

  NSMutableArray *upgraded = [NSMutableArray array];
  _service.upgradeBody = ^NSDictionary *(NSDictionary *body, NSString *version, NSEntityDescription *entity, ODataRequest *request,
                                         NSError **error) {
    [upgraded addObject:version];
    NSMutableDictionary *now = [body mutableCopy];
    // Version 1 called it Title.
    if (now[@"Title"]) now[@"ProductName"] = now[@"Title"];
    [now removeObjectForKey:@"Title"];
    return now;
  };
  XCTAssertEqual([self get:@"Products?$schemaversion=1"].status, 200, @"read with the service's own schema");
  XCTAssertEqual([self get:@"$metadata?$schemaversion=1"].status, 404, @"the service has its own $metadata only");
  OISServiceResponse *patched = [self send:@"PATCH" path:@"Products(1)?$schemaversion=1" headers:nil body:@{ @"Title": @"Chai (v1)" }];
  XCTAssertEqual(patched.status, 204, @"%@", patched.text);
  XCTAssertEqualObjects([self get:@"Products(1)"].json[@"ProductName"], @"Chai (v1)");
  OISServiceResponse *batch = [self send:@"POST" path:@"$batch?$schemaversion=1" headers:nil body:@{ @"requests": @[
    @{ @"id": @"1", @"method": @"PATCH", @"url": @"Products(2)", @"headers": @{ @"Content-Type": @"application/json" },
       @"body": @{ @"Title": @"Chang (v1)" } } ] }];
  XCTAssertEqual(batch.status, 200, @"%@", batch.text);
  XCTAssertEqualObjects([self get:@"Products(2)"].json[@"ProductName"], @"Chang (v1)", @"the batch's version, inherited: %@", batch.text);
  XCTAssertEqualObjects(upgraded, (@[ @"1", @"1" ]));
  [self send:@"PATCH" path:@"Products(1)?$schemaversion=2" headers:nil body:@{ @"ProductName": @"Chai" }];
  XCTAssertEqual(upgraded.count, 2u, @"a client on the service's version is not upgraded");
}

// Data Aggregation 4.0 (CS04) beyond the minimal level: aggregating an
// expression, paths through collection-valued navigation and their $count,
// groupby with transformations of its own, isdefined; and what $metadata
// says of them.
- (void)testAggregationMore
{
  // An expression with a method.
  OISServiceResponse *r = [self get:@"Products?$apply=aggregate(UnitPrice mul 2 with sum as Twice,UnitPrice add 1 with max as Most)"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSDictionary *row = [r.json[@"value"] firstObject];
  XCTAssertEqualWithAccuracy([row[@"Twice"] doubleValue], 180.7, 0.001, @"%@", r.text);
  XCTAssertEqualWithAccuracy([row[@"Most"] doubleValue], 23.0, 0.001, @"%@", r.text);

  // Through a collection-valued navigation property: each category's
  // products' prices, and how many products.
  r = [self get:@"Categories?$apply=groupby((CategoryName),aggregate(Products/UnitPrice with sum as Total,Products/$count as N))"
                @"&$orderby=CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *rows = r.json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"CategoryName"], (@[ @"Beverages", @"Condiments" ]), @"%@", r.text);
  XCTAssertEqualWithAccuracy([rows.lastObject[@"Total"] doubleValue], 53.35, 0.001, @"%@", r.text);
  XCTAssertEqualObjects([rows valueForKey:@"N"], (@[ @2, @3 ]), @"%@", r.text);
  r = [self get:@"Categories?$apply=aggregate(Products/UnitPrice with average as Mean,Products/$count as N)"];
  XCTAssertEqualWithAccuracy([[r.json[@"value"] firstObject][@"Mean"] doubleValue], 18.07, 0.001, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] firstObject][@"N"], @5, @"%@", r.text);

  // groupby with transformations of its own: filtered, then counted, in each group.
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),filter(UnitPrice gt 15)/aggregate($count as N,UnitPrice with sum as Total))"
                @"&$orderby=Category/CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  rows = r.json[@"value"];
  XCTAssertEqualObjects([rows valueForKeyPath:@"Category.CategoryName"], (@[ @"Beverages", @"Condiments" ]), @"%@", r.text);
  XCTAssertEqualObjects([rows valueForKey:@"N"], (@[ @2, @2 ]), @"%@", r.text);
  XCTAssertEqualWithAccuracy([rows.lastObject[@"Total"] doubleValue], 43.35, 0.001, @"%@", r.text);
  XCTAssertTrue([r.json[@"@odata.context"] rangeOfString:@"(Category(CategoryName),N,Total)"].location != NSNotFound, @"%@", r.json[@"@odata.context"]);
  // A group's transformations have to aggregate.
  XCTAssertEqual([self get:@"Products?$apply=groupby((Category/CategoryName),filter(UnitPrice gt 15))"].status, 501);
  // And groupby of a groupby's rows.
  r = [self get:@"Products?$apply=groupby((Discontinued),groupby((Category/CategoryName),aggregate($count as N))/aggregate(N with max as Most))"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);

  // isdefined: of an entity, what its type declares; of a grouped row,
  // what the grouping kept.
  XCTAssertEqual([[self get:@"Products?$filter=isdefined(UnitPrice)"].json[@"value"] count], 5u);
  XCTAssertEqual([[self get:@"Products?$filter=isdefined(Nothing)"].json[@"value"] count], 0u);
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))/filter(isdefined(Total))"];
  XCTAssertEqual([r.json[@"value"] count], 2u, @"%@", r.text);
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))/filter(isdefined(UnitPrice))"];
  XCTAssertEqual([r.json[@"value"] count], 0u, @"%@", r.text);

  // What $apply writes back is what it read.
  NSError *error = nil;
  NSString *text = @"groupby((Category/CategoryName),filter(UnitPrice gt 15)/aggregate(UnitPrice mul 2 with sum as T,Suppliers/$count as S))";
  NSArray *read = [ODataApplyTransformation transformationsWithString:text error:&error];
  XCTAssertEqualObjects([ODataApplyTransformation stringForTransformations:read], text, @"%@", error);
  // A custom aggregate the set does not declare; from, which CS04 removed.
  XCTAssertEqual([self get:@"Products?$apply=aggregate(Forecast)"].status, 400);
  XCTAssertEqual([self get:@"Products?$apply=aggregate(UnitPrice with sum from Category as T)"].status, 501);

  // $metadata says which transformations there are: concat among them.
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSDictionary *apply = [schema annotation:@"Org.OData.Aggregation.V1.ApplySupportedDefaults" forTarget:schema.containerName];
  XCTAssertTrue([apply[@"Transformations"] containsObject:@"concat"], @"%@", apply);
  XCTAssertNil(apply[@"Rollup"], @"not a term of this version");
}

// What a set allows of $apply (Aggregation.ApplySupported: groupable and
// aggregatable properties), and custom aggregation methods and aggregates.
- (void)testAggregationCapabilities
{
  [_service setHandler:[[OISAggregatingHandler alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  OISServiceResponse *r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(ProductName with Custom.concat as Names,Forecast))"
                                     @"&$orderby=Category/CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *rows = r.json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"Names"], (@[ @"Chai,Chang", @"Aniseed Syrup,Chef Anton's Cajun Seasoning,Chef Anton's Gumbo Mix" ]), @"%@", r.text);
  XCTAssertEqualWithAccuracy([rows.firstObject[@"Forecast"] doubleValue], 40.7, 0.001, @"%@", r.text);
  r = [self get:@"Products?$apply=aggregate(Forecast as F,UnitPrice with average as Mean)"];
  XCTAssertEqualWithAccuracy([[r.json[@"value"] firstObject][@"F"] doubleValue], 99.385, 0.001, @"%@", r.text);
  XCTAssertEqual([self get:@"Products?$apply=groupby((Discontinued),aggregate(UnitPrice with sum as T))"].status, 200);

  // What the set does not allow.
  XCTAssertEqual([self get:@"Products?$apply=groupby((ProductName))"].status, 400, @"not groupable");
  XCTAssertEqual([self get:@"Products?$apply=aggregate(UnitPrice with max as M)"].status, 400, @"not with max");
  XCTAssertEqual([self get:@"Products?$apply=aggregate(ProductName with sum as S)"].status, 400, @"only with Custom.concat");
  XCTAssertEqual([self get:@"Products?$apply=aggregate(Nothing)"].status, 400, @"no such custom aggregate");
  XCTAssertEqual([self get:@"Products?$apply=aggregate(UnitPrice with Other.m as X)"].status, 400, @"no such method");

  // $metadata says so.
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSDictionary *apply = [schema capability:@"Org.OData.Aggregation.V1.ApplySupported" forEntitySet:@"Products"];
  XCTAssertEqualObjects([apply[@"GroupableProperties"] valueForKey:@"$PropertyPath"], (@[ @"Category", @"Discontinued" ]), @"%@", apply);
  XCTAssertEqualObjects([apply[@"AggregatableProperties"] valueForKeyPath:@"Property.$PropertyPath"], (@[ @"ProductName", @"UnitPrice" ]), @"%@", apply);
  XCTAssertEqualObjects(apply[@"CustomAggregationMethods"], @[ @"Custom.concat" ], @"%@", apply);
  XCTAssertEqualObjects([schema capability:@"Org.OData.Aggregation.V1.CustomAggregate#Forecast" forEntitySet:@"Products"], @"Edm.Decimal");
}

// join and outerjoin (Data Aggregation section 3.5.1): a row for each
// related entity, under an alias; then grouped, aggregated, filtered through
// it, or written with it where $expand names it.
// The sales organizations of the Data Aggregation spec's example data
// (section 2.2), a recursive hierarchy (SalesOrgHierarchy: ID, and
// Superordinate), and their sales.
- (void)serveSalesOrganizationsInStoreOfType:(NSString *)storeType
{
  NSAttributeDescription *(^attribute)(NSString *, NSAttributeType, NSString *) = ^(NSString *name, NSAttributeType type, NSString *wire) {
    NSAttributeDescription *a = OISSwatchAttribute(name, type, nil);
    a.userInfo = [name isEqualToString:@"id"] ? @{ @"OData.property": wire, @"OData.key": @"YES" } : @{ @"OData.property": wire };
    return a;
  };
  NSEntityDescription *organization = [[NSEntityDescription alloc] init];
  organization.name = @"SalesOrganization";
  organization.managedObjectClassName = @"NSManagedObject";
  organization.userInfo = @{ @"OData.entitySet": @"SalesOrganizations",
                             @"OData.annotations": @"{\"Aggregation.RecursiveHierarchy#SalesOrgHierarchy\": "
                                                    "{\"NodeProperty\": {\"$PropertyPath\": \"ID\"}, "
                                                    "\"ParentNavigationProperty\": {\"$NavigationPropertyPath\": \"Superordinate\"}}}" };
  NSEntityDescription *sale = [[NSEntityDescription alloc] init];
  sale.name = @"Sale";
  sale.managedObjectClassName = @"NSManagedObject";
  sale.userInfo = @{ @"OData.entitySet": @"Sales" };
  NSRelationshipDescription *(^relationship)(NSString *, NSString *, NSEntityDescription *, BOOL) = ^(NSString *name, NSString *wire, NSEntityDescription *to, BOOL many) {
    NSRelationshipDescription *r = [[NSRelationshipDescription alloc] init];
    r.name = name;
    r.destinationEntity = to;
    r.minCount = 0;
    r.maxCount = many ? 0 : 1;
    r.optional = YES;
    r.deleteRule = NSNullifyDeleteRule;
    r.userInfo = @{ @"OData.property": wire };
    return r;
  };
  NSRelationshipDescription *superordinate = relationship(@"superordinate", @"Superordinate", organization, NO);
  NSRelationshipDescription *subordinates = relationship(@"subordinates", @"Subordinates", organization, YES);
  superordinate.inverseRelationship = subordinates;
  subordinates.inverseRelationship = superordinate;
  NSRelationshipDescription *sales = relationship(@"sales", @"Sales", sale, YES);
  NSRelationshipDescription *seller = relationship(@"salesOrganization", @"SalesOrganization", organization, NO);
  sales.inverseRelationship = seller;
  seller.inverseRelationship = sales;
  NSEntityDescription *product = [[NSEntityDescription alloc] init];
  product.name = @"Product";
  product.managedObjectClassName = @"NSManagedObject";
  product.userInfo = @{ @"OData.entitySet": @"Products" };
  NSRelationshipDescription *productSales = relationship(@"sales", @"Sales", sale, YES);
  NSRelationshipDescription *sold = relationship(@"product", @"Product", product, NO);
  productSales.inverseRelationship = sold;
  sold.inverseRelationship = productSales;
  product.properties = @[ attribute(@"id", NSStringAttributeType, @"ID"), attribute(@"name", NSStringAttributeType, @"Name"), productSales ];
  organization.properties = @[ attribute(@"id", NSStringAttributeType, @"ID"), attribute(@"name", NSStringAttributeType, @"Name"),
                               superordinate, subordinates, sales ];
  sale.properties = @[ attribute(@"id", NSInteger32AttributeType, @"ID"), attribute(@"amount", NSDecimalAttributeType, @"Amount"), seller, sold ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ organization, sale, product ];
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_storeFiles addObject:url];
  }
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  NSMutableDictionary *organizations = [NSMutableDictionary dictionary];
  for (NSArray *row in @[ @[ @"Sales", @"Corporate Sales", @"" ], @[ @"US", @"US", @"Sales" ], @[ @"US West", @"US West", @"US" ],
                          @[ @"US East", @"US East", @"US" ], @[ @"EMEA", @"EMEA", @"Sales" ], @[ @"EMEA Central", @"EMEA Central", @"EMEA" ] ]) {
    NSManagedObject *o = [self insert:@"SalesOrganization" into:context values:@{ @"id": row[0], @"name": row[1] }];
    if ([row[2] length]) [o setValue:organizations[row[2]] forKey:@"superordinate"];
    organizations[row[0]] = o;
  }
  NSMutableDictionary *products = [NSMutableDictionary dictionary];
  for (NSArray *row in @[ @[ @"P1", @"Sugar" ], @[ @"P2", @"Coffee" ], @[ @"P3", @"Paper" ], @[ @"P4", @"Pencil" ] ]) {
    products[row[0]] = [self insert:@"Product" into:context values:@{ @"id": row[0], @"name": row[1] }];
  }
  NSArray *rows = @[ @[ @1, @"US West", @1, @"P3" ], @[ @2, @"US West", @2, @"P1" ], @[ @3, @"US West", @4, @"P2" ], @[ @4, @"US East", @8, @"P2" ],
                     @[ @5, @"US East", @4, @"P3" ], @[ @6, @"EMEA Central", @2, @"P1" ], @[ @7, @"EMEA Central", @1, @"P3" ], @[ @8, @"EMEA Central", @2, @"P3" ] ];
  for (NSArray *row in rows) {
    [self insert:@"Sale" into:context values:@{ @"id": row[0], @"salesOrganization": organizations[row[1]], @"product": products[row[3]],
                                                  @"amount": [NSDecimalNumber decimalNumberWithDecimal:[row[2] decimalValue]] }];
  }
  XCTAssertTrue([context save:&error], @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

// Recursive hierarchies (Data Aggregation sections 5.5 and 6), in the
// spec's examples: the functions in $filter, in the store as IN; ancestors,
// descendants and traverse in $apply.
- (void)testRecursiveHierarchies
{
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType ]) {
    [self serveSalesOrganizationsInStoreOfType:storeType];
    NSString *metadata = [self get:@"$metadata"].text;
    XCTAssertTrue([metadata containsString:@"RecursiveHierarchy\" Qualifier=\"SalesOrgHierarchy\""], @"%@", metadata);
    XCTAssertTrue([metadata containsString:@"<String>traverse</String>"], @"%@", metadata);

    NSString *h = @"HierarchyNodes=$root/SalesOrganizations,HierarchyQualifier='SalesOrgHierarchy'";
    NSArray *(^ids)(NSString *) = ^NSArray *(NSString *query) {
      OISServiceResponse *r = [self get:query];
      XCTAssertEqual(r.status, 200, @"%@ %@: %@", storeType, query, r.text);
      return [r.json[@"value"] valueForKey:@"ID"];
    };
    NSArray *(^filtered)(NSString *) = ^NSArray *(NSString *condition) {
      return ids([NSString stringWithFormat:@"SalesOrganizations?$filter=%@&$orderby=ID", condition]);
    };
    // Examples 47 to 49; and the rest of the functions.
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.isdescendant(%@,Node=ID,Ancestor='EMEA')", h]), @[ @"EMEA Central" ]);
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.isdescendant(%@,Node=ID,Ancestor='Sales',MaxDistance=1)", h]), (@[ @"EMEA", @"US" ]));
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.isleaf(%@,Node=ID)", h]), (@[ @"EMEA Central", @"US East", @"US West" ]));
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.isroot(%@,Node=ID)", h]), @[ @"Sales" ]);
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"not Org.OData.Aggregation.V1.isnode(%@,Node=ID)", h]), @[]);
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.isancestor(%@,Node=ID,Descendant='US East')", h]), (@[ @"Sales", @"US" ]));
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.isancestor(%@,Node=ID,Descendant='US East',IncludeSelf=true)", h]),
                          (@[ @"Sales", @"US", @"US East" ]));
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.issibling(%@,Node=ID,Other='US West')", h]), @[ @"US East" ]);
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.issibling(%@,Node=ID,Other='Sales')", h]), @[]);
    XCTAssertEqualObjects(filtered([NSString stringWithFormat:@"Aggregation.isleaf(%@,Node=ID) and startswith(ID,'US')", h]), (@[ @"US East", @"US West" ]));
    // Example 51: of a related entity's node.
    XCTAssertEqualObjects(ids([NSString stringWithFormat:@"Sales?$select=ID&$filter=Aggregation.isdescendant(%@,Node=SalesOrganization/ID,Ancestor='EMEA')", h]),
                          (@[ @6, @7, @8 ]));
    XCTAssertEqualObjects(ids([NSString stringWithFormat:@"SalesOrganizations?$filter=ID eq 'US'&$expand=Subordinates($filter=Aggregation.isleaf(%@,Node=ID);$orderby=ID)", h])
                              .firstObject, @"US");

    // Examples 53 to 56.
    XCTAssertEqualObjects(ids(@"SalesOrganizations?$apply=ancestors($root/SalesOrganizations,SalesOrgHierarchy,ID,filter(contains(Name,'East') or contains(Name,'Central')))"),
                          (@[ @"EMEA", @"Sales", @"US" ]));
    XCTAssertEqualObjects(ids(@"SalesOrganizations?$apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,ID,filter(Name eq 'US'),keep start)"),
                          (@[ @"US", @"US East", @"US West" ]));
    XCTAssertEqualObjects(ids(@"SalesOrganizations?$apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,ID,filter(ID eq 'Sales'),1)"),
                          (@[ @"EMEA", @"US" ]));
    XCTAssertEqualObjects(ids(@"Sales?$apply=ancestors($root/SalesOrganizations,SalesOrgHierarchy,SalesOrganization/ID,"
                               "filter(contains(SalesOrganization/Name,'East') or contains(SalesOrganization/Name,'Central')),keep start)"),
                          (@[ @4, @5, @6, @7, @8 ]));
    XCTAssertEqualObjects(ids(@"SalesOrganizations?$apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,ID,Name eq 'US',keep start)"
                               "/ancestors($root/SalesOrganizations,SalesOrgHierarchy,ID,contains(Name,'East'),keep start)"
                               "/traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder)"),
                          (@[ @"US", @"US East" ]));
    // Example 57, the children in an order of our choosing; example 88's
    // traversal of what is related to the nodes.
    XCTAssertEqualObjects(ids(@"SalesOrganizations?$apply=traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,postorder,Name desc)"),
                          (@[ @"US West", @"US East", @"US", @"EMEA Central", @"EMEA", @"Sales" ]));
    XCTAssertEqualObjects(ids(@"SalesOrganizations?$apply=traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder)"),
                          (@[ @"Sales", @"EMEA", @"EMEA Central", @"US", @"US East", @"US West" ]));
    XCTAssertEqualObjects(ids(@"Sales?$apply=traverse($root/SalesOrganizations,SalesOrgHierarchy,SalesOrganization/ID,preorder,Name asc)"),
                          (@[ @6, @7, @8, @4, @5, @1, @2, @3 ]));
    // Over grouped rows: each organization's total, in the tree's order.
    OISServiceResponse *grouped = [self get:@"Sales?$apply=groupby((SalesOrganization/ID),aggregate(Amount with sum as Total))"
                                             "/traverse($root/SalesOrganizations,SalesOrgHierarchy,SalesOrganization/ID,preorder)"];
    XCTAssertEqual(grouped.status, 200, @"%@", grouped.text);
    XCTAssertEqualObjects([grouped.json[@"value"] valueForKeyPath:@"SalesOrganization.ID"], (@[ @"EMEA Central", @"US East", @"US West" ]), @"%@", grouped.text);
    XCTAssertEqualObjects([grouped.json[@"value"] valueForKey:@"Total"], (@[ @5, @12, @7 ]), @"%@", grouped.text);
    grouped = [self get:@"Sales?$apply=groupby((SalesOrganization/ID),aggregate(Amount with sum as Total))"
                         "/ancestors($root/SalesOrganizations,SalesOrgHierarchy,SalesOrganization/ID,filter(Total gt 10),keep start)"];
    XCTAssertEqual(grouped.status, 200, @"%@", grouped.text);
    XCTAssertEqualObjects([grouped.json[@"value"] valueForKeyPath:@"SalesOrganization.ID"], @[ @"US East" ], @"%@", grouped.text);

    // Example 87 (marked ⚠): a sub-hierarchy's total, over the nodes. Over
    // the sales, as the definition has it, no sale is US's own, so there
    // is no start node, and no total.
    OISServiceResponse *r = [self get:@"SalesOrganizations?$apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,ID,"
                                       "filter(Name eq 'US'),keep start)/aggregate(Sales/Amount with sum as TotalAmount)"];
    XCTAssertEqual(r.status, 200, @"%@", r.text);
    XCTAssertEqualObjects(r.json[@"value"][0][@"TotalAmount"], @19, @"%@", r.text);
    r = [self get:@"Sales?$apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,SalesOrganization/ID,"
                   "filter(SalesOrganization/Name eq 'US'),keep start)/aggregate(Amount with sum as TotalAmount)"];
    XCTAssertEqualObjects(r.json[@"value"][0][@"TotalAmount"], [NSNull null], @"%@", r.text);

    // What it reads back is what it read; what it refuses.
    NSString *text = @"descendants($root/SalesOrganizations,SalesOrgHierarchy,ID,filter(Name eq 'US'),2,keep start)"
                     @"/traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,postorder,Name desc)";
    NSError *error = nil;
    NSArray *transformations = [ODataApplyTransformation transformationsWithString:text error:&error];
    XCTAssertEqualObjects([ODataApplyTransformation stringForTransformations:transformations], text, @"%@", error);
    XCTAssertEqual(([self get:[NSString stringWithFormat:@"SalesOrganizations?$filter=Aggregation.isroot(HierarchyNodes=$root/SalesOrganizations,"
                                                        "HierarchyQualifier='Nope',Node=ID)"]].status), 400);
    XCTAssertEqual(([self get:[NSString stringWithFormat:@"SalesOrganizations?$filter=Aggregation.isroot(HierarchyNodes=$root/Nope,"
                                                        "HierarchyQualifier='SalesOrgHierarchy',Node=ID)"]].status), 400);
    XCTAssertEqual(([self get:[NSString stringWithFormat:@"SalesOrganizations?$filter=Aggregation.isdescendant(%@,Node=ID,Ancestor=Name)", h]].status), 501);
    // Through a collection (section 6.1): a product's nodes are those of
    // its sales; example 88, each product once per node, with it.
    r = [self get:@"Products?$apply=traverse($root/SalesOrganizations,SalesOrgHierarchy,Sales/SalesOrganization/ID,preorder,Name asc)&$select=ID"];
    XCTAssertEqual(r.status, 200, @"%@", r.text);
    XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ID"], (@[ @"P1", @"P3", @"P2", @"P3", @"P1", @"P2", @"P3" ]), @"%@", r.text);
    XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"Sales"],
                          (@[ @[ @{ @"SalesOrganization": @{ @"ID": @"EMEA Central" } } ], @[ @{ @"SalesOrganization": @{ @"ID": @"EMEA Central" } } ],
                              @[ @{ @"SalesOrganization": @{ @"ID": @"US East" } } ], @[ @{ @"SalesOrganization": @{ @"ID": @"US East" } } ],
                              @[ @{ @"SalesOrganization": @{ @"ID": @"US West" } } ], @[ @{ @"SalesOrganization": @{ @"ID": @"US West" } } ],
                              @[ @{ @"SalesOrganization": @{ @"ID": @"US West" } } ] ]), @"%@", r.text);
    XCTAssertEqualObjects(ids(@"Products?$apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,Sales/SalesOrganization/ID,"
                               "filter(Name eq 'Coffee'),keep start)&$orderby=ID"), (@[ @"P1", @"P2", @"P3" ]), @"no Pencil: no sales");
    XCTAssertEqualObjects(ids(@"Products?$apply=ancestors($root/SalesOrganizations,SalesOrgHierarchy,Sales/SalesOrganization/ID,"
                               "filter(Name eq 'Coffee'))"), @[], @"none sold at US or Sales");
    XCTAssertEqual(([self get:@"SalesOrganizations?$apply=ancestors($root/SalesOrganizations,SalesOrgHierarchy,ID,groupby((Name)))"].status), 501);
  }
}

- (void)queryFinished:(ODataQuery *)query
{
  _finishedQuery = query;
}

// What a fetch request cannot say, sent as it is written: a query's rows
// as the context's objects (or as dictionaries), and a $filter of one's
// own within a fetch.
- (void)testClientsSendQueriesAsWritten
{
  [self serveSalesOrganizationsInStoreOfType:NSInMemoryStoreType];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  [ODataIncrementalStore registerStore];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: transport } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSString *nodeKeyPath = nil;
  NSRelationshipDescription *parent = nil;
  NSEntityDescription *organization = [ODataHierarchyPredicate entityOfHierarchy:@"SalesOrgHierarchy" model:model mapper:[[ODataPropertyMapper alloc] init]
                                                                     nodeKeyPath:&nodeKeyPath parent:&parent];

  // Objects, in the service's order, the context's own, what $expand
  // brought kept.
  NSFetchRequest *all = [NSFetchRequest fetchRequestWithEntityName:organization.name];
  NSArray *fetched = [context executeFetchRequest:all error:&error];
  ODataQuery *query = [ODataQuery queryOfEntity:organization.name inContext:context];
  query.options = @{ @"$apply": @"traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder)", @"$expand": @"Superordinate" };
  NSString *sent = [[[query URL:&error] absoluteString] stringByRemovingPercentEncoding];
  XCTAssertTrue([sent hasSuffix:@"SalesOrganizations?$apply=traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder)&$expand=Superordinate"], @"%@", sent);
  NSArray *tree = [query execute:&error];
  XCTAssertEqualObjects([tree valueForKeyPath:nodeKeyPath], (@[ @"Sales", @"EMEA", @"EMEA Central", @"US", @"US East", @"US West" ]), @"%@", error);
  NSManagedObject *us = tree[3];
  XCTAssertTrue([fetched indexOfObjectIdenticalTo:us] != NSNotFound, @"one object per entity");
  NSUInteger requests = transport.requests.count;
  XCTAssertEqualObjects([[us valueForKey:parent.name] valueForKeyPath:nodeKeyPath], @"Sales");
  XCTAssertEqual(transport.requests.count, requests, @"the expanded parent came with it");

  // Dictionaries, for rows that are no objects; which objects cannot be.
  NSEntityDescription *sale = model.entitiesByName[@"Sale"];
  query = [ODataQuery queryOfEntity:sale.name inContext:context];
  query.options = @{ @"$apply": @"groupby((SalesOrganization/ID),aggregate(Amount with sum as Total))"
                                 @"/traverse($root/SalesOrganizations,SalesOrgHierarchy,SalesOrganization/ID,preorder)" };
  query.resultType = NSDictionaryResultType;
  NSArray *totals = [query execute:&error];
  XCTAssertEqualObjects([totals valueForKeyPath:@"SalesOrganization.ID"], (@[ @"EMEA Central", @"US East", @"US West" ]), @"%@", error);
  XCTAssertEqualObjects([totals valueForKey:@"Total"], (@[ @5, @12, @7 ]));
  XCTAssertNil(totals.firstObject[@"@odata.id"], @"no annotations");
  query.resultType = NSManagedObjectResultType;
  XCTAssertNil([query execute:&error], @"grouped rows are no objects");
  XCTAssertTrue([error.localizedDescription containsString:@"ask for dictionaries"], @"%@", error);
  query.options = @{ @"$apply": @"nonsense(1)" };
  XCTAssertNil([query execute:&error]);
  XCTAssertNotNil(error, @"the service's refusal");

  // Without waiting.
  query = [ODataQuery queryOfEntity:organization.name inContext:context];
  query.options = @{ @"$filter": [NSString stringWithFormat:@"Aggregation.isleaf(HierarchyNodes=$root/SalesOrganizations,"
                                                               "HierarchyQualifier='SalesOrgHierarchy',Node=ID)"], @"$orderby": @"ID desc" };
  [query executeWithTarget:self action:@selector(queryFinished:)];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while (!_finishedQuery && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  XCTAssertEqualObjects([_finishedQuery.result valueForKeyPath:nodeKeyPath], (@[ @"US West", @"US East", @"EMEA Central" ]), @"%@", _finishedQuery.error);

  // A $filter of one's own in a fetch: $these, with the rest translated.
  NSString *saleKey = nil;
  for (NSString *name in sale.attributesByName) if ([name caseInsensitiveCompare:@"id"] == NSOrderedSame) saleKey = name;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:sale.name];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:saleKey ascending:YES] ];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
    [ODataFilterPredicate predicateWithFilter:@"Amount mul 4 ge $these/aggregate(Amount with sum)"],
    [NSPredicate predicateWithFormat:@"%K > 2", saleKey] ]];
  NSArray *large = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqualObjects([large valueForKey:saleKey], @[ @4 ], @"%@", error);
  NSString *filter = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding];
  XCTAssertTrue([filter containsString:@"$filter=Amount mul 4 ge $these/aggregate(Amount with sum) and ID gt 2"], @"%@", filter);
  XCTAssertFalse([fetch.predicate evaluateWithObject:large.firstObject], @"in memory, no object answers it");
  // The same, typed: $these as an expression, in memory too.
  NSString *(^named)(NSEntityDescription *, NSString *) = ^NSString *(NSEntityDescription *entity, NSString *name) {
    for (NSString *property in entity.propertiesByName) if ([property caseInsensitiveCompare:name] == NSOrderedSame) return property;
    return nil;
  };
  NSString *amount = named(sale, @"amount"), *seller = named(sale, @"salesOrganization"), *orgName = named(organization, @"name");
  NSExpression *total = [ODataTheseExpression expressionForAggregate:@"sum" keyPath:amount];
  NSPredicate *third = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionWithFormat:@"%K * 4", amount]
                                                          rightExpression:total modifier:NSDirectPredicateModifier
                                                                     type:NSGreaterThanOrEqualToPredicateOperatorType options:0];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[ third, [NSPredicate predicateWithFormat:@"%K > 2", saleKey] ]];
  XCTAssertEqualObjects([[context executeFetchRequest:fetch error:&error] valueForKey:saleKey], @[ @4 ], @"%@", error);
  filter = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding];
  XCTAssertTrue([filter containsString:@"ge $these/aggregate(Amount with sum)"], @"%@", filter);
  XCTAssertTrue([third evaluateWithObject:large.firstObject], @"in memory: 8 * 4 >= 24");
#ifdef __APPLE__
  NSString *subtract = @"from:subtract:";
#else
  NSString *subtract = @"_sub";  // gnustep-base's name for Apple's from:subtract:
#endif
  NSExpression *lastThree = [NSExpression expressionForFunction:subtract arguments:@[ [ODataTheseExpression expressionForCount],
                                                                                               [NSExpression expressionForConstantValue:@3] ]];
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:saleKey] rightExpression:lastThree
                                                              modifier:NSDirectPredicateModifier type:NSGreaterThanPredicateOperatorType options:0];
  XCTAssertEqualObjects([[context executeFetchRequest:fetch error:&error] valueForKey:saleKey], (@[ @6, @7, @8 ]), @"%@", error);

  // $apply's steps, typed.
  query = [ODataQuery queryOfEntity:organization.name inContext:context];
  [query addDescendantsInHierarchy:@"SalesOrgHierarchy" nodeKeyPath:nil of:[NSPredicate predicateWithFormat:@"%K == 'US'", orgName]
                       maxDistance:0 keepStart:YES];
  [query addTraversalOfHierarchy:@"SalesOrgHierarchy" nodeKeyPath:nil postorder:NO
                 sortDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:orgName ascending:NO] ]];
  sent = [[[query URL:&error] absoluteString] stringByRemovingPercentEncoding];
  XCTAssertTrue([sent hasSuffix:@"$apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,ID,filter(Name eq 'US'),keep start)"
                                 @"/traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder,Name desc)"], @"%@ %@", sent, error);
  XCTAssertEqualObjects([[query execute:&error] valueForKeyPath:nodeKeyPath], (@[ @"US", @"US West", @"US East" ]), @"%@", error);
  query = [ODataQuery queryOfEntity:sale.name inContext:context];
  [query addAncestorsInHierarchy:@"SalesOrgHierarchy" nodeKeyPath:[NSString stringWithFormat:@"%@.%@", seller, nodeKeyPath]
                              of:[NSPredicate predicateWithFormat:@"%K.%K CONTAINS 'East'", seller, orgName] maxDistance:0 keepStart:YES];
  query.options = @{ @"$orderby": @"ID" };
  XCTAssertEqualObjects([[query execute:&error] valueForKey:saleKey], (@[ @4, @5 ]), @"%@", error);
  [query addTraversalOfHierarchy:@"Nope" nodeKeyPath:nil postorder:NO sortDescriptors:nil];
  XCTAssertNil([query execute:&error], @"no such hierarchy");
  XCTAssertTrue([error.localizedDescription containsString:@"Nope"], @"%@", error);

  // A fetch request's query, typed: the store's own, to go on from.
  NSFetchRequest *start = [NSFetchRequest fetchRequestWithEntityName:sale.name];
  start.predicate = [NSPredicate predicateWithFormat:@"%K > 2", saleKey];
  start.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:saleKey ascending:YES] ];
  query = [ODataQuery queryWithFetchRequest:start inContext:context error:&error];
  XCTAssertEqualObjects(query.queryOptions.filter.description, @"ID gt 2", @"%@", error);
  XCTAssertEqualObjects([query URL:&error], [(ODataIncrementalStore *)client.persistentStores.firstObject URLForFetchRequest:start error:NULL]);
  ODataMutableQueryOptions *more = [query.queryOptions mutableCopy];
  ODataExpression *four = [ODataExpression binary:@"mul" left:[ODataExpression member:@"Amount" of:nil error:&error]
                                             right:[ODataExpression literalWithValue:@4] error:&error];
  ODataExpression *allSales = [ODataExpression aggregateOf:[ODataExpression variable:@"$these" error:&error] text:@"Amount with sum" error:&error];
  more.filter = [ODataExpression binary:@"and" left:more.filter
                                   right:[ODataExpression binary:@"ge" left:four right:allSales error:&error] error:&error];
  XCTAssertNotNil(more.filter, @"%@", error);
  query.queryOptions = more;
  XCTAssertEqualObjects([[query execute:&error] valueForKey:saleKey], @[ @4 ], @"%@", error);
  XCTAssertEqualObjects(query.options[@"$filter"], @"ID gt 2 and Amount mul 4 ge $these/aggregate(Amount with sum)");
  XCTAssertNil([ODataQuery queryWithFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Nope"] inContext:context error:&error]);
  query.options = @{ @"$filter": @"ID eq (" };
  XCTAssertNil([query execute:&error], @"options that are no OData");
  XCTAssertNotNil(error);

  NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:[ODataFilterPredicate predicateWithFilter:@"ID eq 1"] requiringSecureCoding:YES error:NULL];
  XCTAssertEqualObjects([NSKeyedUnarchiver unarchivedObjectOfClass:[ODataFilterPredicate class] fromData:archived error:NULL],
                        [ODataFilterPredicate predicateWithFilter:@"ID eq 1"]);
}

// A client asks where nodes are in a hierarchy, with a model from
// $metadata: in $filter, at the service; and in memory, alike.
- (void)testClientsAskHierarchies
{
  [self serveSalesOrganizationsInStoreOfType:NSInMemoryStoreType];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  NSString *nodeKeyPath = nil;
  NSRelationshipDescription *parent = nil;
  NSEntityDescription *organization = [ODataHierarchyPredicate entityOfHierarchy:@"SalesOrgHierarchy" model:model mapper:[[ODataPropertyMapper alloc] init]
                                                                     nodeKeyPath:&nodeKeyPath parent:&parent];
  XCTAssertEqualObjects(organization.name, @"SalesOrganization");
  XCTAssertNotNil(parent);
  [ODataIncrementalStore registerStore];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: transport } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSFetchRequest *all = [NSFetchRequest fetchRequestWithEntityName:organization.name];
  all.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:nodeKeyPath ascending:YES] ];
  NSArray *everyone = [context executeFetchRequest:all error:&error];
  XCTAssertEqual(everyone.count, 6u, @"%@", error);
  NSArray *tests = @[
    [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsDescendant hierarchy:@"SalesOrgHierarchy" node:@"EMEA"],
    [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsDescendant hierarchy:@"SalesOrgHierarchy" node:@"Sales" nodeKeyPath:nil maxDistance:1 includeSelf:YES],
    [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsAncestor hierarchy:@"SalesOrgHierarchy" node:@"US East"],
    [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsSibling hierarchy:@"SalesOrgHierarchy" node:@"US West"],
    [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsRoot hierarchy:@"SalesOrgHierarchy" node:nil],
    [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsLeaf hierarchy:@"SalesOrgHierarchy" node:nil],
    [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsNode hierarchy:@"SalesOrgHierarchy" node:nil],
  ];
  NSArray *expected = @[ @[ @"EMEA Central" ], @[ @"EMEA", @"Sales", @"US" ], @[ @"Sales", @"US" ], @[ @"US East" ], @[ @"Sales" ],
                         @[ @"EMEA Central", @"US East", @"US West" ], @[ @"EMEA", @"EMEA Central", @"Sales", @"US", @"US East", @"US West" ] ];
  for (NSUInteger i = 0; i < tests.count; i++) {
    NSFetchRequest *fetch = [all copy];
    fetch.predicate = tests[i];
    NSArray *rows = [context executeFetchRequest:fetch error:&error];
    XCTAssertEqualObjects([rows valueForKeyPath:nodeKeyPath], expected[i], @"%@: %@", tests[i], error);
    NSString *query = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding] ?: @"";
    XCTAssertTrue([query containsString:[@"$filter=Org.OData.Aggregation.V1." stringByAppendingString:[tests[i] functionName]]], @"%@", query);
    XCTAssertEqualObjects([[everyone filteredArrayUsingPredicate:tests[i]] valueForKeyPath:nodeKeyPath], expected[i], @"in memory: %@", tests[i]);
  }
  // With more of a predicate; of a related node.
  NSFetchRequest *fetch = [all copy];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[ tests[5], [NSPredicate predicateWithFormat:@"%K BEGINSWITH 'US'", nodeKeyPath] ]];
  XCTAssertEqualObjects([[context executeFetchRequest:fetch error:&error] valueForKeyPath:nodeKeyPath], (@[ @"US East", @"US West" ]), @"%@", error);
  NSEntityDescription *sale = model.entitiesByName[@"Sale"];
  NSString *seller = nil;
  for (NSRelationshipDescription *relationship in sale.relationshipsByName.allValues) {
    if (relationship.destinationEntity == organization) seller = relationship.name;
  }
  NSString *saleKey = nil;
  for (NSString *name in sale.attributesByName) if ([name caseInsensitiveCompare:@"id"] == NSOrderedSame) saleKey = name;
  fetch = [NSFetchRequest fetchRequestWithEntityName:sale.name];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:saleKey ascending:YES] ];
  fetch.predicate = [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsDescendant hierarchy:@"SalesOrgHierarchy" node:@"EMEA"
                                                   nodeKeyPath:[NSString stringWithFormat:@"%@.%@", seller, nodeKeyPath] maxDistance:0 includeSelf:NO];
  NSArray *sales = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqualObjects([sales valueForKey:saleKey], (@[ @6, @7, @8 ]), @"%@", error);
  NSFetchRequest *allSales = [NSFetchRequest fetchRequestWithEntityName:sale.name];
  XCTAssertEqual([[[context executeFetchRequest:allSales error:NULL] filteredArrayUsingPredicate:fetch.predicate] count], 3u, @"in memory");

  // Where it cannot be asked.
  fetch = [NSFetchRequest fetchRequestWithEntityName:sale.name];
  fetch.predicate = [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsRoot hierarchy:@"SalesOrgHierarchy" node:nil];
  XCTAssertNil([context executeFetchRequest:fetch error:&error], @"a sale is no node");
  fetch.predicate = [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsRoot hierarchy:@"Nope" node:nil];
  XCTAssertNil([context executeFetchRequest:fetch error:&error], @"no such hierarchy");
  NSError *archiving = nil, *unarchiving = nil;
  NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:tests[1] requiringSecureCoding:YES error:&archiving];
  id unarchived = [NSKeyedUnarchiver unarchivedObjectOfClass:[ODataHierarchyPredicate class] fromData:archived error:&unarchiving];
  XCTAssertEqualObjects(unarchived, tests[1], @"%lu bytes (%@), %@ (%@)", (unsigned long)archived.length, archiving, unarchived, unarchiving);
  ODataTemporalPredicate *at = [ODataTemporalPredicate predicateFrom:[NSDate dateWithTimeIntervalSince1970:0] toInclusive:[NSDate dateWithTimeIntervalSince1970:86400]];
  archived = [NSKeyedArchiver archivedDataWithRootObject:at requiringSecureCoding:YES error:NULL];
  XCTAssertEqualObjects([NSKeyedUnarchiver unarchivedObjectOfClass:[ODataTemporalPredicate class] fromData:archived error:&unarchiving], at, @"%@", unarchiving);
}

// Aggregates as values (Data Aggregation section 3.6): of the current
// collection ($these), and of a collection-valued path.
- (void)testAggregatesInExpressions
{
  // Prices 18, 19, 10, 22, 21.35: the whole is 90.35.
  OISServiceResponse *r = [self get:@"Products?$filter=UnitPrice mul 4.2 ge $these/aggregate(UnitPrice with sum)&$select=ProductName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], (@[ @"Chef Anton's Cajun Seasoning" ]), @"%@", r.text);
  r = [self get:@"Products?$filter=UnitPrice gt $these/aggregate(UnitPrice with average)&$select=ProductName"];
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], (@[ @"Chang", @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]), @"%@", r.text);
  r = [self get:@"Products?$compute=UnitPrice div $these/aggregate(UnitPrice with max) as Share&$select=ProductName,Share&$orderby=ProductID"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualWithAccuracy([r.json[@"value"][2][@"Share"] doubleValue], 10.0 / 22.0, 0.0001, @"%@", r.text);

  // In $apply: the input of the transformation.
  r = [self get:@"Products?$apply=filter(Discontinued eq false)/filter(UnitPrice lt $these/aggregate(UnitPrice with average))&$select=ProductName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], (@[ @"Aniseed Syrup" ]), @"%@", r.text);
  r = [self get:@"Products?$apply=topcount($these/$count div 2,UnitPrice)&$select=ProductName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]), @"%@", r.text);
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))"
                 "/compute(Total div $these/aggregate(Total with sum) as Share)&$orderby=Category/CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualWithAccuracy([r.json[@"value"][0][@"Share"] doubleValue], 37.0 / 90.35, 0.0001, @"%@", r.text);

  // In an expansion: each category's own products (Beverages average
  // 18.5, Condiments 17.78).
  r = [self get:@"Categories?$expand=Products($filter=UnitPrice gt $these/aggregate(UnitPrice with average);$select=ProductName;$orderby=ProductName)"
                 "&$select=CategoryName&$orderby=CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKeyPath:@"Products.ProductName"],
                        (@[ @[ @"Chang" ], @[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ] ]), @"%@", r.text);
  r = [self get:@"Categories?$expand=Products($orderby=UnitPrice sub $these/aggregate(UnitPrice with max);$select=ProductName;$top=1)&$orderby=CategoryName"];
  XCTAssertEqualObjects([r.json[@"value"] valueForKeyPath:@"Products.ProductName"], (@[ @[ @"Chai" ], @[ @"Aniseed Syrup" ] ]), @"%@", r.text);

  // In $orderby: of what the $filter leaves.
  r = [self get:@"Products?$filter=UnitPrice gt 15&$orderby=UnitPrice sub $these/aggregate(UnitPrice with min) desc&$select=ProductName&$top=2"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]), @"%@", r.text);
  r = [self get:@"Products?$apply=orderby(UnitPrice sub $these/aggregate(UnitPrice with average) desc)/top(1)&$select=ProductName"];
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], @[ @"Chef Anton's Cajun Seasoning" ], @"%@", r.text);

  // After $apply: of what it made (18, 19, 22, 21.35: the least is 18).
  r = [self get:@"Products?$apply=filter(UnitPrice gt 15)&$filter=UnitPrice gt $these/aggregate(UnitPrice with min)&$select=ProductName&$orderby=ProductID"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"ProductName"], (@[ @"Chang", @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]), @"%@", r.text);
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))"
                 "&$filter=Total gt $these/aggregate(Total with average)"];
  XCTAssertEqualObjects([r.json[@"value"] valueForKeyPath:@"Category.CategoryName"], @[ @"Condiments" ], @"%@", r.text);
  r = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))"
                 "&$orderby=Total sub $these/aggregate(Total with min) desc"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKeyPath:@"Category.CategoryName"], (@[ @"Condiments", @"Beverages" ]), @"%@", r.text);

  // Of a navigation: in the store, as a key path's collection operator.
  r = [self get:@"Categories?$filter=Products/aggregate(UnitPrice with sum) gt 40&$select=CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"CategoryName"], @[ @"Condiments" ], @"%@", r.text);
  r = [self get:@"Categories?$filter=Products/aggregate($count) eq 2&$select=CategoryName"];
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"CategoryName"], @[ @"Beverages" ], @"%@", r.text);
  r = [self get:@"Categories?$compute=Products/aggregate(UnitPrice with max) as Top&$select=CategoryName,Top&$orderby=CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualWithAccuracy([r.json[@"value"][0][@"Top"] doubleValue], 19.0, 0.001, @"%@", r.text);

  // What it reads back is what it read; what it cannot do.
  NSError *error = nil;
  ODataExpression *e = [ODataExpression expressionWithString:@"Sales/aggregate(Amount mul $it/TaxRate with sum) gt $these/aggregate(Amount with sum)" error:&error];
  XCTAssertEqualObjects(e.description, @"Sales/aggregate(Amount mul $it/TaxRate with sum) gt $these/aggregate(Amount with sum)", @"%@", error);
  XCTAssertEqual([e aggregatesOfThese].count, 1u);
  XCTAssertEqual([self get:@"Categories?$filter=Products/aggregate(ProductName with sum) gt 1"].status, 400, @"not a number");
  XCTAssertEqual([self get:@"Categories?$filter=Products/aggregate(UnitPrice mul 2 with sum) gt 1"].status, 501);
  XCTAssertEqual([self get:@"Products?$filter=UnitPrice gt $these/aggregate(Nothing with sum)"].status, 400);
  XCTAssertEqual([self get:@"Categories?$apply=groupby((Products/ProductName))"].status, 400, @"CS04 groups by single-valued paths");

  // SQLite (Apple's store) cannot compute with a collection's aggregate:
  // what it refuses is refused, not raised.
  [self serveModel:_coordinator.managedObjectModel storeType:NSSQLiteStoreType];
  r = [self get:@"Categories?$filter=Products/aggregate(UnitPrice with sum) gt 40&$select=CategoryName"];
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"CategoryName"], @[ @"Condiments" ], @"%@", r.text);
  r = [self get:@"Categories?$filter=Products/$count mul 20 gt 50"];
#ifdef __APPLE__
  XCTAssertEqual(r.status, 501, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"The store cannot evaluate this"], @"%@", r.text);
#else
  // FreeCoreData's SQLite store evaluates it.
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"CategoryName"], @[ @"Condiments" ], @"%@", r.text);
#endif
}

- (void)testJoin
{
  OISServiceResponse *r = [self get:@"Categories?$apply=join(Products as P)&$select=CategoryName&$expand=P($select=ProductName)"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *rows = r.json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"CategoryName"], (@[ @"Beverages", @"Beverages", @"Condiments", @"Condiments", @"Condiments" ]), @"%@", r.text);
  XCTAssertEqualObjects([rows valueForKeyPath:@"P.ProductName"],
                        (@[ @"Chai", @"Chang", @"Aniseed Syrup", @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]), @"%@", r.text);
  XCTAssertNil([self get:@"Categories?$apply=join(Products as P)"].json[@"value"][0][@"P"], @"only where $expand names it");

  // outerjoin keeps the rows with nothing related, with null.
  r = [self get:@"Products?$apply=outerjoin(Stocks as S)&$select=ProductName&$expand=S($select=Quantity)&$orderby=ProductID"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  rows = r.json[@"value"];
  XCTAssertEqual(rows.count, 5u, @"%@", r.text);
  XCTAssertEqualObjects(rows.firstObject[@"S"][@"Quantity"], @40, @"%@", r.text);
  XCTAssertEqualObjects(rows.lastObject[@"S"], [NSNull null], @"%@", r.text);
  XCTAssertEqual([[self get:@"Products?$apply=join(Stocks as S)"].json[@"value"] count], 1u, @"join leaves them out");

  // Grouped and aggregated through the alias.
  r = [self get:@"Categories?$apply=join(Products as P)/groupby((CategoryName),aggregate(P/UnitPrice with sum as T,$count as N))&$orderby=CategoryName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  rows = r.json[@"value"];
  XCTAssertEqualWithAccuracy([rows.lastObject[@"T"] doubleValue], 53.35, 0.001, @"%@", r.text);
  XCTAssertEqualObjects([rows valueForKey:@"N"], (@[ @2, @3 ]), @"%@", r.text);
  r = [self get:@"Categories?$apply=join(Products as P)/groupby((P/Discontinued),aggregate($count as N))&$orderby=P/Discontinued"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKeyPath:@"P.Discontinued"], (@[ @NO, @YES ]), @"%@", r.text);

  // The join's own transformations, on each collection; a filter through the alias.
  r = [self get:@"Suppliers?$apply=join(Products as P,filter(UnitPrice gt 20))/groupby((CompanyName),aggregate($count as N))"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"CompanyName"], @[ @"New Orleans Cajun Delights" ], @"%@", r.text);
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"N"], @[ @2 ], @"%@", r.text);
  r = [self get:@"Categories?$apply=join(Products as P)/filter(P/UnitPrice gt 20)&$select=CategoryName"];
  XCTAssertEqualObjects([r.json[@"value"] valueForKey:@"CategoryName"], (@[ @"Condiments", @"Condiments" ]), @"%@", r.text);

  // What cannot be joined; what it writes back is what it read.
  XCTAssertEqual([self get:@"Categories?$apply=join(CategoryName as X)"].status, 400);
  XCTAssertEqual([self get:@"Categories?$apply=join(Products as CategoryName)"].status, 400, @"an alias the rows have");
  NSString *text = @"outerjoin(Products as P,filter(UnitPrice gt 20)/orderby(UnitPrice desc))";
  NSArray *read = [ODataApplyTransformation transformationsWithString:text error:NULL];
  XCTAssertEqualObjects([ODataApplyTransformation stringForTransformations:read], text);
}

#pragma mark Serving part of a model

// A copy of the Catalog with a configuration of these entities.
- (void)serveCatalogConfiguration:(NSString *)configuration entities:(NSArray<NSString *> *)names
{
  NSManagedObjectModel *model = [OISCatalogModel() conformsToProtocol:@protocol(NSCopying)]
      ? [OISCatalogModel() copy]
      : [[NSManagedObjectModel alloc] initWithContentsOfURL:OISCatalogModelURL()];
  NSMutableArray *entities = [NSMutableArray array];
  for (NSString *name in names) [entities addObject:model.entitiesByName[name]];
  [model setEntities:entities forConfiguration:configuration];
  [self serveModel:model];
  _service.configurationName = configuration;
}

// A product's quantity per unit and its suppliers are the application's
// own (OData.served NO): the service has no such properties.
// A copy of the Catalog whose products keep these properties for
// themselves (OData.served NO), and a revision, their ETag, likewise.
static NSManagedObjectModel *OISCatalogKeeping(NSArray<NSString *> *names)
{
  NSManagedObjectModel *model = [OISCatalogModel() conformsToProtocol:@protocol(NSCopying)]
      ? [OISCatalogModel() copy]
      : [[NSManagedObjectModel alloc] initWithContentsOfURL:OISCatalogModelURL()];
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  NSAttributeDescription *revision = [[NSAttributeDescription alloc] init];
  revision.name = @"revision";
  revision.attributeType = NSInteger64AttributeType;
  revision.optional = YES;
  revision.defaultValue = @0;
  revision.userInfo = @{ ODataUserInfoETag: @"YES", ODataUserInfoServed: @"NO" };
  product.properties = [product.properties arrayByAddingObject:revision];
  for (NSString *name in names) {
    NSPropertyDescription *property = product.propertiesByName[name];
    NSMutableDictionary *userInfo = [property.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    userInfo[ODataUserInfoServed] = @"NO";
    property.userInfo = userInfo;
  }
  return model;
}

- (void)testPropertiesThatAreNotServed
{
  NSManagedObjectModel *model = OISCatalogKeeping(@[ @"quantityPerUnit", @"suppliers" ]);
  // Every product has a supplier, which no request can give it.
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  NSRelationshipDescription *suppliers = product.relationshipsByName[@"suppliers"];
  suppliers.minCount = 1;
  suppliers.optional = NO;
  [self serveModel:model];
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = _coordinator;
  NSString *(^quantity)(void) = ^NSString *{
    __block NSString *value = nil;
    [context performBlockAndWait:^{
      NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
      value = [[[context executeFetchRequest:fetch error:NULL] firstObject] valueForKey:@"quantityPerUnit"];
    }];
    return value;
  };
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
    [[[context executeFetchRequest:fetch error:NULL] firstObject] setValue:@"10 boxes" forKey:@"quantityPerUnit"];
    [context save:NULL];
  }];

  NSString *metadata = [self get:@"$metadata"].text;
  XCTAssertFalse([metadata containsString:@"QuantityPerUnit"], @"%@", metadata);
  XCTAssertFalse([metadata containsString:@"Name=\"Suppliers\" Type=\"Collection(Default.Supplier)\""], @"%@", metadata);
  XCTAssertTrue([metadata containsString:@"Name=\"Products\" Type=\"Collection(Default.Product)\""], @"the other way still is");
  XCTAssertFalse([metadata containsString:@"Partner=\"Suppliers\""], @"and names no partner that is not served");
  XCTAssertFalse([metadata containsString:@"Revision"], @"the ETag's property neither");
  XCTAssertFalse([metadata containsString:@"OptimisticConcurrency"]);
  XCTAssertEqualObjects(_service.metadataProblems, @[]);
  XCTAssertEqualObjects([self get:@"Products(1)"].headers[@"ETag"], @"W/\"0\"", @"its ETag all the same");
  // One the service keeps is not valid: its fault, and not named.
  OISServiceResponse *made = [self send:@"POST" path:@"Products" headers:nil
                                   body:@{ @"ProductID": @30, @"ProductName": @"Tea", @"UnitPrice": @1, @"Discontinued": @NO,
                                           @"Category@odata.bind": @"Categories(1)" }];
  XCTAssertEqual(made.status, 500, @"%@", made.text);
  XCTAssertFalse([made.text.lowercaseString containsString:@"suppliers"], @"%@", made.text);

  NSDictionary *chai = [self get:@"Products(1)?$expand=*"].json;
  XCTAssertEqualObjects(chai[@"ProductName"], @"Chai");
  XCTAssertNil(chai[@"QuantityPerUnit"]);
  XCTAssertNil(chai[@"Suppliers"]);
  XCTAssertNotNil(chai[@"Category"]);
  for (NSString *path in @[ @"Products?$filter=QuantityPerUnit eq '10 boxes'", @"Products?$select=QuantityPerUnit",
                            @"Products?$orderby=QuantityPerUnit", @"Products?$expand=Suppliers",
                            @"Products(1)/QuantityPerUnit" ]) {
    XCTAssertTrue([self get:path].status == 400 || [self get:path].status == 404, @"%@: %ld", path, (long)[self get:path].status);
  }
  XCTAssertEqualObjects([self get:@"Products?$search=boxes"].json[@"value"], @[], @"not searched");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil body:@{ @"QuantityPerUnit": @"none" }].status), 400);
  XCTAssertEqual(([self send:@"POST" path:@"Products" headers:nil
                        body:@{ @"ProductID": @9, @"ProductName": @"Tea", @"QuantityPerUnit": @"1" }].status), 400);
  // A PUT replaces what is served, not what is not.
  OISServiceResponse *put = [self send:@"PUT" path:@"Products(1)" headers:nil
                                  body:@{ @"ProductID": @1, @"ProductName": @"Chai tea" }];
  XCTAssertTrue(put.status == 204 || put.status == 200, @"%@", put.text);
  XCTAssertEqualObjects([self get:@"Products(1)/ProductName"].json[@"value"], @"Chai tea");
  XCTAssertEqualObjects(quantity(), @"10 boxes");

  // The key cannot be left out.
  NSManagedObjectModel *keyless = [OISCatalogModel() conformsToProtocol:@protocol(NSCopying)]
      ? [OISCatalogModel() copy]
      : [[NSManagedObjectModel alloc] initWithContentsOfURL:OISCatalogModelURL()];
  NSEntityDescription *category = keyless.entitiesByName[@"Category"];
  NSAttributeDescription *key = category.attributesByName[@"id"];
  NSMutableDictionary *keyInfo = [key.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
  keyInfo[ODataUserInfoServed] = @"NO";
  key.userInfo = keyInfo;
  [self serveModel:keyless];
  [self get:@"$metadata"];
  XCTAssertTrue([[_service.metadataProblems componentsJoinedByString:@"\n"] containsString:@"Category.id is the key"],
                @"%@", _service.metadataProblems);
}

// What names a property that is not served: a currency's holder, a
// timeline's period, a recursive hierarchy's node. Each a problem.
- (void)testWhatNamesAPropertyThatIsNotServed
{
  NSManagedObjectModel *model = OISCatalogKeeping(@[ @"name" ]);
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  NSAttributeDescription *price = product.attributesByName[@"unitPrice"];
  price.userInfo = @{ ODataUserInfoISOCurrency: @"name" };
  product.userInfo = @{ ODataUserInfoAnnotations: @"{\"Aggregation.RecursiveHierarchy#Line\": {\"NodeProperty\": {\"$PropertyPath\": \"ProductName\"}, "
                                                    @"\"ParentNavigationProperty\": {\"$NavigationPropertyPath\": \"Category\"}}}" };
  [self serveModel:model];
  NSString *metadata = [self get:@"$metadata"].text;
  XCTAssertFalse([metadata containsString:@"ISOCurrency"], @"%@", metadata);
  NSString *problems = [_service.metadataProblems componentsJoinedByString:@"\n"];
  XCTAssertTrue([problems containsString:@"Product.unitPrice: its currency is in name, which is not served"], @"%@", problems);
  XCTAssertTrue([problems containsString:@"RecursiveHierarchy#Line names ProductName, which is not served"], @"%@", problems);

  NSEntityDescription *slice = [[NSEntityDescription alloc] init];
  slice.name = @"Slice";
  slice.managedObjectClassName = @"NSManagedObject";
  slice.userInfo = @{ ODataUserInfoPeriodStart: @"from", ODataUserInfoPeriodEnd: @"to" };
  NSAttributeDescription *key = OISSwatchAttribute(@"id", NSInteger32AttributeType, nil);
  NSAttributeDescription *to = OISSwatchAttribute(@"to", NSDateAttributeType, nil);
  to.userInfo = @{ ODataUserInfoServed: @"NO" };
  slice.properties = @[ key, OISSwatchAttribute(@"from", NSDateAttributeType, nil), to ];
  NSManagedObjectModel *timeline = [[NSManagedObjectModel alloc] init];
  timeline.entities = @[ slice ];
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:timeline];
  [_coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:NULL];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  XCTAssertEqualObjects(_service.metadataProblems, @[ @"Slice: its timeline's to is not served, so it has no application time" ]);
  XCTAssertFalse([[self get:@"$metadata"].text containsString:@"ApplicationTimeSupport"]);
}

// A change to what the service keeps for itself is none a delta shows.
- (void)testChangesNotServedAreNoDelta
{
  [self serveTrackedCatalogWith:^(NSManagedObjectModel *model) {
    NSEntityDescription *product = model.entitiesByName[@"Product"];
    NSAttributeDescription *quantity = product.attributesByName[@"quantityPerUnit"];
    quantity.userInfo = @{ ODataUserInfoServed: @"NO" };
  }];
  NSString *link = [self send:@"GET" path:@"Products" headers:@{ @"Prefer": @"odata.track-changes" } body:nil].json[@"@odata.deltaLink"];
  XCTAssertNotNil(link);
  NSManagedObjectContext *context = [self serviceContext];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:NULL] firstObject];
  [chai setValue:@"10 boxes" forKey:@"quantityPerUnit"];
  XCTAssertTrue([context save:NULL]);
  OISServiceResponse *delta = [self get:[self pathOfLink:link]];
  XCTAssertEqualObjects(delta.json[@"value"], @[], @"%@", delta.text);
  [chai setValue:@"Chai tea" forKey:@"name"];
  XCTAssertTrue([context save:NULL]);
  delta = [self get:[self pathOfLink:link]];
  XCTAssertEqualObjects([delta.json[@"value"] valueForKey:@"ProductName"], @[ @"Chai tea" ], @"%@", delta.text);
}

// The client, over the same model: what the service does not serve is
// neither sent nor asked for, is kept in memory as saved, and cannot be
// filtered by.
- (void)testTheClientKeepsWhatIsNotServed
{
  NSManagedObjectModel *model = OISCatalogKeeping(@[ @"quantityPerUnit" ]);
  [self serveModel:model];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  ODataIncrementalStore *store = (ODataIncrementalStore *)[client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                                                        URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                                                                    options:@{ ODataIncrementalStoreTransportOption: transport } error:&error];
  XCTAssertNotNil(store, @"%@", error);
  XCTAssertEqualObjects(store.metadataProblems, @[]);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai", @"%@", error);
  XCTAssertNil([chai valueForKey:@"quantityPerUnit"]);

  // Changed alone: nothing to write. (A save may read, FreeCoreData's.)
  NSArray *(^writes)(void) = ^NSArray *{
    return [transport.requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"HTTPMethod != 'GET'"]];
  };
  NSUInteger sent = writes().count;
  [chai setValue:@"10 boxes" forKey:@"quantityPerUnit"];
  XCTAssertTrue([context save:&error], @"%@", error);
  XCTAssertEqual(writes().count, sent, @"%@", writes().lastObject);
  // Changed with the rest: the rest is sent.
  [chai setValue:@"20 boxes" forKey:@"quantityPerUnit"];
  [chai setValue:@"Chai tea" forKey:@"name"];
  XCTAssertTrue([context save:&error], @"%@", error);
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:[writes().lastObject HTTPBody] options:0 error:NULL];
  XCTAssertEqualObjects(body, @{ @"ProductName": @"Chai tea" });
  // Kept, as saved, when the row is read again.
  [store discardCachedRowsForObjectIDs:nil];
  [context refreshObject:chai mergeChanges:NO];
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai tea");
  XCTAssertEqualObjects([chai valueForKey:@"quantityPerUnit"], @"20 boxes");
  // The service has none of it to filter by.
  NSFetchRequest *boxed = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  boxed.predicate = [NSPredicate predicateWithFormat:@"quantityPerUnit == '20 boxes'"];
  XCTAssertNil([context executeFetchRequest:boxed error:&error]);
  XCTAssertTrue([error.localizedDescription containsString:@"OData.served NO"], @"%@", error);
  // A new one: posted without it.
  NSManagedObject *tea = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
  [tea setValue:@40 forKey:@"id"];
  [tea setValue:@"Green tea" forKey:@"name"];
  [tea setValue:@"1 tin" forKey:@"quantityPerUnit"];
  XCTAssertTrue([context save:&error], @"%@", error);
  NSURLRequest *post = nil;
  for (NSURLRequest *request in transport.requests) if ([request.HTTPMethod isEqualToString:@"POST"]) post = request;
  body = [NSJSONSerialization JSONObjectWithData:post.HTTPBody options:0 error:NULL];
  XCTAssertEqualObjects(body[@"ProductName"], @"Green tea");
  XCTAssertNil(body[@"QuantityPerUnit"], @"%@", body);
}

// A to-one relationship the service does not serve: rows are read
// without it, though the store expands every other to-one's key, to
// know what a row's relationships hold.
- (void)testTheClientAsksForNoToOneThatIsNotServed
{
  NSManagedObjectModel *model = OISCatalogKeeping(@[ @"category" ]);
  [self serveModel:model];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  ODataIncrementalStore *store = (ODataIncrementalStore *)[client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                                                        URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                                                                    options:@{ ODataIncrementalStoreTransportOption: transport } error:&error];
  XCTAssertNotNil(store, @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai", @"%@", error);
  XCTAssertNil([chai valueForKey:@"category"]);
  for (NSURLRequest *request in transport.requests) {
    XCTAssertFalse([[request.URL.absoluteString stringByRemovingPercentEncoding] containsString:@"Category"], @"%@", request.URL);
  }
}

// Only Products and Categories: Stocks, Locations and Suppliers are not
// there, nor is anything that leads to them.
- (void)testOnlyAConfigurationsEntities
{
  [self serveCatalogConfiguration:@"Shop" entities:@[ @"Product", @"Category" ]];
  [_service setHandler:[[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Supplier")] forEntitySet:@"Suppliers"];
  OISServiceResponse *doc = [self get:@""];
  XCTAssertEqualObjects([[doc.json[@"value"] valueForKey:@"name"] sortedArrayUsingSelector:@selector(compare:)],
                        (@[ @"Categories", @"Products" ]), @"a handler for a set it does not serve serves nothing");
  XCTAssertEqualObjects(_service.entitySets, (@[ @"Categories", @"Products" ]));
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Default.Product"];
  XCTAssertNotNil([schema navigationProperty:@"Category" ofEntityType:product]);
  XCTAssertNil([schema navigationProperty:@"Suppliers" ofEntityType:product]);
  XCTAssertNil([schema navigationProperty:@"Stocks" ofEntityType:product]);
  XCTAssertNil([schema entityTypeNamed:@"Default.Supplier"]);
  XCTAssertEqualObjects(_service.metadataProblems, @[]);

  XCTAssertEqual([self get:@"Suppliers"].status, 404);
  XCTAssertEqual([self get:@"Products(1)/Suppliers"].status, 404);
  XCTAssertEqual([self get:@"Products?$expand=Suppliers"].status, 400);
  XCTAssertEqual([self get:@"Products?$filter=Suppliers/any(s: s/City eq 'London')"].status, 400);
  XCTAssertEqual([self get:@"Products?$orderby=Stocks/$count"].status, 400);
  OISServiceResponse *all = [self get:@"Products(1)?$expand=*"];
  XCTAssertEqual(all.status, 200, @"%@", all.text);
  XCTAssertNotNil(all.json[@"Category"]);
  XCTAssertNil(all.json[@"Suppliers"]);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil
                        body:@{ @"Suppliers@odata.bind": @[ @"Suppliers(2)" ] }].status), 400);
  XCTAssertEqualObjects([self get:@"Categories(1)/Products/$count"].text, @"2", @"what it serves works as before");

  // A client of the same model: a store of the same configuration answers
  // for its entities, and looks for changes to them alone.
  [ODataIncrementalStore registerStore];
  NSURL *root = [NSURL URLWithString:@"http://example.test/odata/"];
  NSError *error = nil;
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_coordinator.managedObjectModel];
  ODataIncrementalStore *shop = (ODataIncrementalStore *)[client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:@"Shop"
                                                                                       URL:root options:@{ ODataIncrementalStoreTransportOption: _service }
                                                                                     error:&error];
  XCTAssertNotNil(shop, @"%@", error);
  XCTAssertEqualObjects(shop.metadataProblems, @[]);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  XCTAssertNotNil([shop fetchRemoteChanges:&error], @"%@", error);
  NSPersistentStoreCoordinator *whole = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_coordinator.managedObjectModel];
  ODataIncrementalStore *every = (ODataIncrementalStore *)[whole addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                                                     URL:root options:@{ ODataIncrementalStoreTransportOption: _service }
                                                                                   error:&error];
  XCTAssertTrue([every.metadataProblems containsObject:@"Supplier: no entity type Supplier in $metadata"], @"%@", every.metadataProblems);
}

// Stocks without their Locations: every way to a location is closed, and
// no answer names the relationship.
- (void)testNothingLeadsOutOfAConfiguration
{
  [self serveCatalogConfiguration:@"Stock" entities:@[ @"Product", @"Category", @"Stock" ]];
  XCTAssertEqualObjects(_service.metadataProblems, @[]);
  NSArray *reads = @[ @"Stocks?$apply=groupby((Location/City))", @"Stocks?$apply=aggregate(Location/LocationID with sum as S)",
                      @"Stocks?$apply=filter(Location/City eq 'Leeds')", @"Stocks?$filter=Location/City eq 'Leeds'",
                      @"Stocks?$orderby=Location/City", @"Stocks?$select=Location", @"Stocks(1)?$select=Location/City",
                      @"Stocks?$compute=Location/City as C&$select=C", @"Stocks?$expand=Location", @"Stocks(1)/Location" ];
  for (NSString *path in reads) {
    OISServiceResponse *r = [self get:path];
    XCTAssertTrue(r.status == 400 || r.status == 404, @"%@: %ld %@", path, (long)r.status, r.text);
    XCTAssertTrue([r.text rangeOfString:@"cannot"].location == NSNotFound, @"%@: %@", path, r.text);
  }
  OISServiceResponse *stock = [self get:@"Stocks(1)"];
  XCTAssertEqual(stock.status, 200, @"%@", stock.text);
  XCTAssertNil(stock.json[@"Location"]);
  for (NSDictionary *body in @[ @{ @"Location@odata.bind": [NSNull null] }, @{ @"Location": @{ @"LocationName": @"Shed" } } ]) {
    OISServiceResponse *w = [self send:@"PATCH" path:@"Stocks(1)" headers:nil body:body];
    XCTAssertEqual(w.status, 400, @"%@: %@", body, w.text);
    XCTAssertTrue([w.text rangeOfString:@"cannot"].location == NSNotFound, @"%@: %@", body, w.text);
  }
  XCTAssertEqualObjects([self get:@"Products(1)/Stocks/$count"].text, @"1", @"what it serves works as before");
}

// A root is served with every sub-entity; a configuration that says
// otherwise is a problem, and a sub-entity without its root is not served.
- (void)testAConfigurationsSubEntities
{
  _staffConfigurations = @{ @"All": @[ @"Employee", @"Manager", @"Executive" ], @"Partly": @[ @"Employee", @"Manager" ],
                            @"Bosses": @[ @"Manager", @"Executive" ] };
  [self serveStaff];
  _service.configurationName = @"All";
  XCTAssertEqualObjects(_service.metadataProblems, @[]);
  XCTAssertEqualObjects(_service.entitySets, @[ @"Employees" ]);

  [self serveStaff];
  _service.configurationName = @"Partly";
  XCTAssertEqualObjects(_service.metadataProblems,
                        @[ @"Configuration Partly lists Employee without its sub-entity Executive: it is served all the same" ]);
  XCTAssertEqualObjects(_service.entitySets, @[ @"Employees" ]);
  XCTAssertTrue([[self get:@"$metadata"].text rangeOfString:@"Name=\"Executive\""].location != NSNotFound);

  [self serveStaff];
  _service.configurationName = @"Bosses";
  NSArray *problems = [_service.metadataProblems sortedArrayUsingSelector:@selector(compare:)];
  XCTAssertEqualObjects(problems, (@[ @"Configuration Bosses lists Executive without its root entity Employee: it is not served",
                                      @"Configuration Bosses lists Manager without its root entity Employee: it is not served" ]));
  XCTAssertEqualObjects(_service.entitySets, @[]);

  [self serveStaff];
  _service.configurationName = @"Nothing";
  XCTAssertEqualObjects(_service.metadataProblems, @[ @"The model has no configuration Nothing: no entity is served" ]);
  XCTAssertEqual([self get:@"Employees"].status, 404);
  _staffConfigurations = nil;
}

// Properties the model does not have: an open type's, which its handler
// gives and filters by.
- (void)testAnOpenType
{
  [_service setHandler:[[OISOpenCategoriesHandler alloc] initWithEntity:OISCatalogEntity(@"Category")] forEntitySet:@"Categories"];
  NSString *metadata = [self get:@"$metadata"].text;
  XCTAssertTrue([metadata rangeOfString:@"<EntityType Name=\"Category\" OpenType=\"true\">"].location != NSNotFound, @"%@", metadata);
  XCTAssertTrue([metadata rangeOfString:@"<EntityType Name=\"Product\">"].location != NSNotFound);

  OISOpenCategoriesHandler *handler = (OISOpenCategoriesHandler *)[_service handlerForEntitySet:@"Categories"];
  NSDictionary *beverages = [self get:@"Categories(1)"].json;
  XCTAssertEqualObjects(beverages[@"Prices"], (@{ @"Chai": @18, @"Chang": @19 }));
  XCTAssertEqualObjects(beverages[@"Size"], @2);
  XCTAssertEqualObjects(beverages[@"CategoryName"], @"Beverages", @"a declared property is the model's");
  // Typed where the JSON does not say.
  XCTAssertEqualObjects(beverages[@"Size@odata.type"], @"#Int32");
  XCTAssertEqualObjects(beverages[@"Reviewed"], @"2025-03-01T12:00:00Z");
  XCTAssertEqualObjects(beverages[@"Reviewed@odata.type"], @"#DateTimeOffset");
  XCTAssertEqualObjects(beverages[@"Share"], [NSDecimalNumber decimalNumberWithString:@"0.5"]);
  XCTAssertEqualObjects(beverages[@"Share@odata.type"], @"#Decimal");
  XCTAssertEqualObjects(beverages[@"Note"], @"kept");
  XCTAssertEqualObjects(beverages[@"Listed"], @YES);
  for (NSString *untyped in @[ @"Note", @"Listed", @"Prices", @"CategoryName" ]) {
    XCTAssertNil(beverages[[untyped stringByAppendingString:@"@odata.type"]], @"%@", untyped);
  }
  NSDictionary *bare = [self send:@"GET" path:@"Categories(1)" headers:@{ @"Accept": @"application/json;odata.metadata=none" } body:nil].json;
  XCTAssertEqualObjects(bare[@"Size"], @2);
  XCTAssertNil(bare[@"Size@odata.type"], @"%@", bare);
  NSDictionary *selected = [self get:@"Categories(1)?$select=CategoryName,Size,Colour"].json;
  XCTAssertEqual([selected.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"NOT SELF CONTAINS '@'"]].count, 2u,
                 @"%@", selected);
  XCTAssertEqualObjects(selected[@"Size"], @2);

  // Asked once a response, for all it writes: its rows, and expansions'.
  [handler.batches removeAllObjects];
  XCTAssertEqual([self get:@"Categories?$orderby=CategoryName"].status, 200);
  XCTAssertEqualObjects(handler.batches, (@[ @[ @"Beverages", @"Condiments" ] ]));
  [handler.batches removeAllObjects];
  OISServiceResponse *expanded = [self get:@"Products?$expand=Category&$orderby=ProductID"];
  XCTAssertEqual(expanded.status, 200, @"%@", expanded.text);
  XCTAssertEqualObjects(handler.batches, (@[ @[ @"Beverages", @"Condiments" ] ]));
  XCTAssertEqualObjects([expanded.json[@"value"] valueForKeyPath:@"Category.Size"], (@[ @2, @2, @3, @3, @3 ]));
  [handler.batches removeAllObjects];
  XCTAssertEqual([self get:@"Products"].status, 200);
  XCTAssertEqualObjects(handler.batches, @[], @"no category written, none asked");
  // An answer to come: the plan goes on when it does.
  handler.later = YES;
  [handler.batches removeAllObjects];
  OISServiceResponse *later = [self get:@"Categories?$orderby=CategoryName&$expand=Products"];
  XCTAssertEqual(later.status, 200, @"%@", later.text);
  XCTAssertEqualObjects([later.json[@"value"] valueForKey:@"Size"], (@[ @2, @3 ]));
  XCTAssertEqual(handler.batches.count, 1u);
  handler.later = NO;
  _service.explains = YES;
  NSString *plan = [self get:@"$explain/Categories"].json[@"physical"];
  XCTAssertTrue([plan rangeOfString:@"Dynamic properties (Categories)"].location != NSNotFound, @"%@", plan);
  XCTAssertTrue([[self get:@"$explain/Products"].json[@"physical"] rangeOfString:@"Dynamic"].location == NSNotFound);

  // The handler is handed the request.
  XCTAssertEqual(([self send:@"GET" path:@"Categories?$filter=Size eq 2" headers:@{ @"X-No-Size": @"1" } body:nil].status), 403);

  NSArray *(^names)(NSString *) = ^NSArray *(NSString *filter) {
    OISServiceResponse *r = [self get:[@"Categories?$orderby=CategoryName&$filter=" stringByAppendingString:filter]];
    XCTAssertEqual(r.status, 200, @"%@: %@", filter, r.text);
    return [r.json[@"value"] valueForKey:@"CategoryName"];
  };
  XCTAssertEqualObjects(names(@"Prices/Chai eq 18"), @[ @"Beverages" ]);
  XCTAssertEqualObjects(names(@"Prices/Chai gt 18"), @[]);
  XCTAssertEqualObjects(names(@"Size ge 3"), @[ @"Condiments" ]);
  XCTAssertEqualObjects(names(@"3 le Size"), @[ @"Condiments" ], @"the property on either side");
  XCTAssertEqualObjects(names(@"Size in (2,5)"), @[ @"Beverages" ]);
  XCTAssertEqualObjects(names(@"Prices/Chai lt 18 or Prices/Chang eq 19"), (@[ @"Beverages" ]));
  XCTAssertEqualObjects(names(@"not (Size eq 2) and startswith(CategoryName,'C')"), @[ @"Condiments" ]);

  XCTAssertEqual([self get:@"Categories?$filter=Secret eq 1"].status, 403, @"refused by the handler");
  XCTAssertEqual([self get:@"Categories?$filter=Colour eq 1"].status, 400, @"none such");
  XCTAssertEqual([self get:@"Categories?$filter=Size eq CategoryName"].status, 501);
  XCTAssertEqual([self get:@"Categories?$filter=Size add 1 gt 2"].status, 400);
  XCTAssertEqual([self get:@"Categories?$orderby=Size"].status, 400);
  XCTAssertEqual([self get:@"Products?$filter=Size eq 1"].status, 400, @"Products is not open");

  // What the store evaluates, the SQLite store's too.
  [self serveModel:OISCatalogModel() storeType:NSSQLiteStoreType];
  [_service setHandler:[[OISOpenCategoriesHandler alloc] initWithEntity:OISCatalogEntity(@"Category")] forEntitySet:@"Categories"];
  XCTAssertEqualObjects(names(@"Prices/Chai eq 18"), @[ @"Beverages" ]);
  XCTAssertEqualObjects(names(@"Size ge 3 or Prices/Chang gt 20"), @[ @"Condiments" ]);
}

// The client over an open type: a model from $metadata with a property
// bag, filled from what each row has that the type does not declare,
// typed as annotated; filtered by; and written back, entry by entry.
- (void)testTheClientsPropertyBag
{
  [_service setHandler:[[OISOpenCategoriesHandler alloc] initWithEntity:OISCatalogEntity(@"Category")] forEntitySet:@"Categories"];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSURL *root = [NSURL URLWithString:@"http://example.test/odata/"];
  NSDictionary *options = @{ ODataIncrementalStoreTransportOption: transport };
  NSError *error = nil;
  [ODataIncrementalStore registerStore];
  NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:root options:options error:&error];
  XCTAssertNotNil(model, @"%@", error);
  NSEntityDescription *categoryEntity = model.entitiesByName[@"Category"], *productEntity = model.entitiesByName[@"Product"];
  NSAttributeDescription *bag = categoryEntity.attributesByName[@"dynamicProperties"];
  XCTAssertEqual(bag.attributeType, NSTransformableAttributeType);
  XCTAssertNil(productEntity.attributesByName[@"dynamicProperties"], @"Products is not open");
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:root options:options error:&error],
                  @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"categoryName" ascending:YES] ];
  NSArray *rows = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqual(rows.count, 2u, @"%@", error);
  XCTAssertTrue([transport.requests.lastObject.URL.query rangeOfString:@"select"].location == NSNotFound,
                @"no $select can name them: %@", transport.requests.lastObject.URL);
  NSManagedObject *beverages = rows.firstObject;
  NSDictionary *dynamic = [beverages valueForKey:@"dynamicProperties"];
  XCTAssertEqualObjects(dynamic[@"Size"], @2);
  XCTAssertEqualObjects(dynamic[@"Reviewed"], ODataDateFromString(@"2025-03-01T12:00:00Z"), @"a date, as its annotation says");
  XCTAssertTrue([dynamic[@"Share"] isKindOfClass:[NSDecimalNumber class]], @"%@", [dynamic[@"Share"] class]);
  XCTAssertEqualObjects(dynamic[@"Share"], [NSDecimalNumber decimalNumberWithString:@"0.5"]);
  // Nested, a value is what its JSON is: no annotation says more.
  XCTAssertEqualObjects([dynamic[@"Prices"][@"Chang"] description], @"19");
  XCTAssertEqualObjects(dynamic[@"Note"], @"kept");
  XCTAssertEqualObjects(dynamic[@"Listed"], @YES);
  XCTAssertNil(dynamic[@"CategoryName"], @"a declared property is no dynamic one");
  XCTAssertEqualObjects([beverages valueForKey:@"categoryName"], @"Beverages");

  // Filtered by one: the service is asked.
  NSFetchRequest *big = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  // (SIZE is a word of the predicate syntax: %K, to name it.)
  big.predicate = [NSPredicate predicateWithFormat:@"%K >= 3", @"dynamicProperties.Size"];
  XCTAssertEqualObjects([[context executeFetchRequest:big error:&error] valueForKey:@"categoryName"], @[ @"Condiments" ], @"%@", error);
  NSString *query = [transport.requests.lastObject.URL.query stringByRemovingPercentEncoding];
  XCTAssertTrue([query rangeOfString:@"$filter=Size ge 3"].location != NSNotFound, @"%@", query);
  // One asked for in a dictionary result: $select names it.
  NSFetchRequest *sizes = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  sizes.resultType = NSDictionaryResultType;
  NSExpressionDescription *size = [[NSExpressionDescription alloc] init];
  size.name = @"size";
  size.expression = [NSExpression expressionForKeyPath:@"dynamicProperties.Size"];
  size.expressionResultType = NSUndefinedAttributeType;
  sizes.propertiesToFetch = @[ @"categoryName", size ];
  sizes.sortDescriptors = fetch.sortDescriptors;
  NSArray *pairs = [context executeFetchRequest:sizes error:&error];
  XCTAssertEqualObjects([pairs valueForKey:@"size"], (@[ @2, @3 ]), @"%@ %@", pairs, error);
  query = [transport.requests.lastObject.URL.query stringByRemovingPercentEncoding];
  XCTAssertTrue([query rangeOfString:@"$select=CategoryName,Size"].location != NSNotFound, @"%@", query);

  // Changed: what changed, typed where JSON does not say; one removed, null.
  NSMutableDictionary *changed = [dynamic mutableCopy];
  [changed removeObjectForKey:@"Note"];
  changed[@"Size"] = @4;
  changed[@"Opened"] = ODataDateFromString(@"2026-01-02T03:04:05Z");
  [beverages setValue:changed forKey:@"dynamicProperties"];
  XCTAssertTrue([context save:&error], @"%@", error);
  NSURLRequest *patch = [self lastRequest:@"PATCH" in:transport];
  XCTAssertEqualObjects([NSJSONSerialization JSONObjectWithData:patch.HTTPBody options:0 error:NULL],
                        (@{ @"Note": [NSNull null], @"Size": @4, @"Size@odata.type": @"#Int32",
                            @"Opened": @"2026-01-02T03:04:05Z", @"Opened@odata.type": @"#DateTimeOffset" }));
  // Kept by the service, and read back as they were written.
  [(ODataIncrementalStore *)client.persistentStores.firstObject discardCachedRowsForObjectIDs:nil];
  [context refreshObject:beverages mergeChanges:NO];
  NSDictionary *again = [beverages valueForKey:@"dynamicProperties"];
  XCTAssertEqualObjects(again[@"Opened"], ODataDateFromString(@"2026-01-02T03:04:05Z"), @"%@", again);
  XCTAssertNil(again[@"Note"]);

  // Inserted: each one, beside the declared properties.
  NSManagedObject *snacks = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:context];
  [snacks setValue:@9 forKey:@"categoryID"];
  [snacks setValue:@"Snacks" forKey:@"categoryName"];
  [snacks setValue:@{ @"Mood": @"calm", @"Weight": [NSDecimalNumber decimalNumberWithString:@"1.25"] } forKey:@"dynamicProperties"];
  XCTAssertTrue([context save:&error], @"%@", error);
  NSDictionary *posted = [NSJSONSerialization JSONObjectWithData:[self lastRequest:@"POST" in:transport].HTTPBody options:0 error:NULL];
  XCTAssertEqualObjects(posted[@"CategoryName"], @"Snacks");
  XCTAssertEqualObjects(posted[@"Mood"], @"calm");
  XCTAssertEqualObjects(posted[@"Weight@odata.type"], @"#Decimal");
  XCTAssertNil(posted[@"DynamicProperties"], @"%@", posted);
  XCTAssertEqualObjects([self get:@"Categories(9)"].json[@"Mood"], @"calm", @"the service kept them");
}

- (NSURLRequest *)lastRequest:(NSString *)method in:(OISRecordingTransport *)transport
{
  for (NSURLRequest *request in transport.requests.reverseObjectEnumerator) {
    if ([request.HTTPMethod isEqualToString:method]) return request;
  }
  return nil;
}

// An open type's dynamic properties written: typed by their annotations,
// null removing one, all of a write's handed to the handler at once, and
// read back; refused where the type is not open, or its handler keeps none.
- (void)testWritingAnOpenType
{
  OISOpenCategoriesHandler *handler = [[OISOpenCategoriesHandler alloc] initWithEntity:OISCatalogEntity(@"Category")];
  [_service setHandler:handler forEntitySet:@"Categories"];
  OISServiceResponse *r = [self send:@"PATCH" path:@"Categories(1)" headers:nil
                                body:@{ @"Mood": @"calm", @"Opened@odata.type": @"#DateTimeOffset", @"Opened": @"2026-01-02T03:04:05Z",
                                        @"Visits": @3, @"Note": [NSNull null], @"CategoryName": @"Drinks" }];
  XCTAssertTrue(r.status < 300, @"%ld %@", (long)r.status, r.text);
  XCTAssertEqualObjects(handler.writeBatches, @[ @[ @"Drinks" ] ], @"after the declared ones are set");
  XCTAssertTrue([handler.written[@1][@"Opened"] isKindOfClass:[NSDate class]], @"typed as annotated: %@", handler.written[@1]);
  NSDictionary *drinks = [self get:@"Categories(1)"].json;
  XCTAssertEqualObjects(drinks[@"CategoryName"], @"Drinks");
  XCTAssertEqualObjects(drinks[@"Mood"], @"calm");
  XCTAssertEqualObjects(drinks[@"Opened"], @"2026-01-02T03:04:05Z");
  XCTAssertEqualObjects(drinks[@"Opened@odata.type"], @"#DateTimeOffset");
  XCTAssertEqualObjects(drinks[@"Visits"], @3);
  XCTAssertNil(drinks[@"Note"], @"null removes one");
  XCTAssertEqualObjects(drinks[@"Size"], @2, @"the rest as they were");

  // Several entities in one write, one ask: a deep insert, and later.
  handler.later = YES;
  [handler.writeBatches removeAllObjects];
  r = [self send:@"POST" path:@"Products" headers:nil
            body:@{ @"ProductID": @20, @"ProductName": @"Pretzels", @"UnitPrice": @3, @"Discontinued": @NO,
                    @"Category": @{ @"CategoryID": @7, @"CategoryName": @"Snacks", @"Mood": @"crunchy" } }];
  XCTAssertEqual(r.status, 201, @"%@", r.text);
  r = [self send:@"PATCH" path:@"Categories(2)" headers:nil body:@{ @"Mood": @"hot", @"Share@odata.type": @"#Decimal", @"Share": @"0.75" }];
  XCTAssertTrue(r.status < 300, @"%ld %@", (long)r.status, r.text);
  XCTAssertEqualObjects(handler.writeBatches, (@[ @[ @"Snacks" ], @[ @"Condiments" ] ]));
  XCTAssertEqualObjects([self get:@"Categories(7)"].json[@"Mood"], @"crunchy");
  XCTAssertEqualObjects(handler.written[@2][@"Share"], [NSDecimalNumber decimalNumberWithString:@"0.75"]);
  handler.later = NO;

  // PUT replaces them all.
  r = [self send:@"PUT" path:@"Categories(2)" headers:nil body:@{ @"CategoryName": @"Condiments", @"Mood": @"mild" }];
  XCTAssertTrue(r.status < 300, @"%ld %@", (long)r.status, r.text);
  NSDictionary *condiments = [self get:@"Categories(2)"].json;
  XCTAssertEqualObjects(condiments[@"Mood"], @"mild");
  XCTAssertNil(condiments[@"Size"], @"%@", condiments);

  // Not where the value is not what its annotation says, the type is not
  // open, or the handler keeps none: and then nothing of the write is saved.
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"When@odata.type": @"#DateTimeOffset", @"When": @"soon" }].status), 400);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil body:@{ @"Mood": @"x" }].status), 400);
  handler.refusesWrites = YES;
  r = [self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"CategoryName": @"Beverages", @"Mood": @"x" }];
  XCTAssertEqual(r.status, 400, @"%@", r.text);
  XCTAssertTrue([r.text rangeOfString:@"Mood"].location != NSNotFound, @"%@", r.text);
  XCTAssertEqualObjects([self get:@"Categories(1)/CategoryName"].json[@"value"], @"Drinks", @"not saved");
}

// A copy of the Catalog whose categories keep dynamic properties in a
// bag, extras.
static NSManagedObjectModel *OISCatalogWithBag(void)
{
  NSManagedObjectModel *model = [OISCatalogModel() conformsToProtocol:@protocol(NSCopying)]
      ? [OISCatalogModel() copy]
      : [[NSManagedObjectModel alloc] initWithContentsOfURL:OISCatalogModelURL()];
  NSEntityDescription *category = model.entitiesByName[@"Category"];
  NSAttributeDescription *bag = [[NSAttributeDescription alloc] init];
  bag.name = @"extras";
  bag.attributeType = NSTransformableAttributeType;
  bag.valueTransformerName = @"NSSecureUnarchiveFromData";
  bag.attributeValueClassName = @"NSDictionary";
  bag.optional = YES;
  bag.userInfo = @{ ODataUserInfoDynamicProperties: @"YES" };
  category.properties = [category.properties arrayByAddingObject:bag];
  return model;
}

// A client that shares the model: the service's bag is its bag too.
- (void)testAClientSharingTheBag
{
  NSManagedObjectModel *model = OISCatalogWithBag();
  [self serveModel:model];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  ODataIncrementalStore *store = (ODataIncrementalStore *)[client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                                                        URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                                                                    options:@{ ODataIncrementalStoreTransportOption: transport } error:&error];
  XCTAssertNotNil(store, @"%@", error);
  XCTAssertEqualObjects(store.metadataProblems, @[]);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
  NSManagedObject *beverages = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertNotNil(beverages, @"%@", error);
  XCTAssertEqualObjects([beverages valueForKey:@"extras"], @{}, @"none yet");

  [beverages setValue:@{ @"Mood": @"calm", @"Opened": ODataDateFromString(@"2026-01-02T03:04:05Z") } forKey:@"extras"];
  XCTAssertTrue([context save:&error], @"%@", error);
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:transport.requests.lastObject.HTTPBody options:0 error:NULL];
  XCTAssertEqualObjects(body, (@{ @"Mood": @"calm", @"Opened": @"2026-01-02T03:04:05Z", @"Opened@odata.type": @"#DateTimeOffset" }));
  [store discardCachedRowsForObjectIDs:nil];
  [context refreshObject:beverages mergeChanges:NO];
  XCTAssertEqualObjects([beverages valueForKey:@"extras"][@"Opened"], ODataDateFromString(@"2026-01-02T03:04:05Z"), @"kept by the service");

  NSFetchRequest *calm = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  calm.predicate = [NSPredicate predicateWithFormat:@"extras.Mood == 'calm'"];
  XCTAssertEqualObjects([[context executeFetchRequest:calm error:&error] valueForKey:@"name"], @[ @"Beverages" ], @"%@", error);
  NSString *query = [transport.requests.lastObject.URL.query stringByRemovingPercentEncoding];
  XCTAssertTrue([query containsString:@"$filter=Mood eq 'calm'"], @"%@", query);
}

// Dynamic properties kept by default: in the entity's bag, a
// Transformable (OData.dynamicProperties), with no handler to write.
// Filters on them are evaluated here, the store keeping an archive.
- (void)testDynamicPropertiesKeptInTheModel
{
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType ]) {
    [self serveModel:OISCatalogWithBag() storeType:storeType];
    _service.explains = YES;

    NSString *metadata = [self get:@"$metadata"].text;
    XCTAssertTrue([metadata containsString:@"<EntityType Name=\"Category\" OpenType=\"true\">"], @"%@: %@", storeType, metadata);
    XCTAssertFalse([metadata containsString:@"Extras"], @"the bag is no property");
    XCTAssertEqualObjects(_service.metadataProblems, @[]);
    NSString *before = [self get:@"Categories(1)"].headers[@"ETag"];
    OISServiceResponse *r = [self send:@"PATCH" path:@"Categories(1)" headers:nil
                                  body:@{ @"Mood": @"calm", @"Opened@odata.type": @"#DateTimeOffset", @"Opened": @"2026-01-02T03:04:05Z",
                                          @"Weight@odata.type": @"#Decimal", @"Weight": @"1.5", @"Visits": @3 }];
    XCTAssertTrue(r.status < 300, @"%@: %ld %@", storeType, (long)r.status, r.text);
    XCTAssertNotEqualObjects([self get:@"Categories(1)"].headers[@"ETag"], before, @"a change of them is a change of the entity");
    XCTAssertTrue(([self send:@"PATCH" path:@"Categories(2)" headers:nil body:@{ @"Mood": @"hot", @"Visits": @5 }].status < 300));

    // Kept in the store, typed.
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
    context.persistentStoreCoordinator = _coordinator;
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
    NSDictionary *kept = [[[context executeFetchRequest:fetch error:NULL] firstObject] valueForKey:@"extras"];
    XCTAssertTrue([kept[@"Opened"] isKindOfClass:[NSDate class]], @"%@: %@", storeType, kept);
    XCTAssertEqualObjects(kept[@"Weight"], [NSDecimalNumber decimalNumberWithString:@"1.5"]);
    NSDictionary *beverages = [self get:@"Categories(1)"].json;
    XCTAssertEqualObjects(beverages[@"Mood"], @"calm");
    XCTAssertEqualObjects(beverages[@"Opened"], @"2026-01-02T03:04:05Z");
    XCTAssertEqualObjects(beverages[@"Opened@odata.type"], @"#DateTimeOffset");
    XCTAssertNil(beverages[@"Extras"]);

    // Filtered by, here: every row read, then filtered, ordered and paged.
    NSArray *(^names)(NSString *) = ^NSArray *(NSString *path) {
      OISServiceResponse *answer = [self get:path];
      XCTAssertEqual(answer.status, 200, @"%@ %@: %@", storeType, path, answer.text);
      return [answer.json[@"value"] valueForKey:@"CategoryName"];
    };
    XCTAssertEqualObjects(names(@"Categories?$filter=Mood eq 'calm'"), @[ @"Beverages" ]);
    XCTAssertEqualObjects(names(@"Categories?$filter=Visits gt 2 and CategoryName ne 'Seafood'&$orderby=CategoryName desc"),
                          (@[ @"Condiments", @"Beverages" ]));
    XCTAssertEqualObjects(names(@"Categories?$filter=Mood ne null&$orderby=CategoryName&$top=1"), @[ @"Beverages" ]);
    XCTAssertEqualObjects([self get:@"Categories?$filter=Visits ge 3&$count=true&$top=1"].json[@"@odata.count"], @2);
    XCTAssertEqualObjects([self get:@"Categories/$count?$filter=Mood eq 'hot'"].text, @"1");
    XCTAssertEqualObjects(names(@"Categories?$apply=filter(Mood eq 'hot')"), @[ @"Condiments" ]);
    NSArray *expanded = [[self get:@"Products?$filter=ProductID eq 1&$expand=Category($filter=Mood eq 'calm')"].json[@"value"] valueForKeyPath:@"Category.CategoryName"];
    XCTAssertEqualObjects(expanded, @[ @"Beverages" ]);
    NSString *plan = [self get:@"$explain/Categories?$filter=Mood eq 'calm' and CategoryName ne 'Seafood'"].json[@"physical"];
    NSRange here = [plan rangeOfString:@"filter(Mood eq 'calm')"], store = [plan rangeOfString:@"CategoryName ne 'Seafood'"];
    XCTAssertTrue(here.location != NSNotFound && store.location != NSNotFound && store.location > here.location,
                  @"the dynamic part here, over the store's scan with the rest: %@", plan);

    // null removes one; a PUT replaces them all.
    XCTAssertTrue(([self send:@"PATCH" path:@"Categories(2)" headers:nil body:@{ @"Mood": [NSNull null] }].status < 300));
    NSDictionary *condiments = [self get:@"Categories(2)"].json;
    XCTAssertNil(condiments[@"Mood"]);
    XCTAssertEqualObjects(condiments[@"Visits"], @5);
    XCTAssertTrue(([self send:@"PUT" path:@"Categories(1)" headers:nil body:@{ @"CategoryName": @"Beverages" }].status < 300));
    XCTAssertNil([self get:@"Categories(1)"].json[@"Mood"], @"%@", storeType);
  }
}

// Nothing is written but by the application's actions.
- (void)testAReadOnlyService
{
  [self serveOperations];
  _service.readOnly = YES;
  ODataEntitySetHandler *products = [_service handlerForEntitySet:@"Products"];
  products.allowsUpdate = YES;
  XCTAssertFalse(products.allowsUpdate, @"whatever the handler says");
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSDictionary *update = [schema capability:@"Capabilities.UpdateRestrictions" forEntitySet:@"Products"];
  XCTAssertEqualObjects(update[@"Updatable"], @NO, @"%@", update);
  XCTAssertEqualObjects([schema capability:@"Capabilities.InsertRestrictions" forEntitySet:@"Categories"][@"Insertable"], @NO);
  XCTAssertEqualObjects([schema capability:@"Capabilities.DeleteRestrictions" forEntitySet:@"Suppliers"][@"Deletable"], @NO);

  XCTAssertEqual(([self send:@"POST" path:@"Categories" headers:nil body:@{ @"CategoryID": @9, @"CategoryName": @"New" }].status), 405);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil body:@{ @"ProductName": @"Tea" }].status), 405);
  XCTAssertEqual([self send:@"DELETE" path:@"Products(1)" headers:nil body:nil].status, 405);
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/Category/$ref" headers:nil
                        body:@{ @"@odata.id": @"http://example.test/odata/Categories(2)" }].status), 405);
  XCTAssertEqualObjects([self get:@"Products(1)/ProductName"].json[@"value"], @"Chai");
  OISServiceResponse *batch = [self postBatch:@[
    @[ @{ @"method": @"PATCH", @"url": @"Products(1)", @"id": @"1", @"body": @{ @"ProductName": @"Tea" } } ],
  ] headers:nil];
  XCTAssertEqualObjects([[self partsOf:batch] valueForKey:@"status"], @[ @405 ], @"%@", batch.text);

  // Actions run, and what one changes in the request's context is saved:
  // the application's own way to write.
  XCTAssertEqual(([self send:@"POST" path:@"Fail" headers:nil body:@{ @"Code": @409 }].status), 409);
  OISServiceResponse *raised = [self send:@"POST" path:@"Products(1)/Default.RaisePriceByPercent" headers:nil body:@{ @"Percent": @50 }];
  XCTAssertTrue(raised.status < 300, @"%ld %@", (long)raised.status, raised.text);
  XCTAssertEqualObjects([self get:@"Products(1)/UnitPrice/$value"].text, @"27", @"saved");
  XCTAssertEqualObjects([self get:@"CountProductsCheaperThanPrice(Price=19)"].json[@"value"], @1, @"functions as before, Chai now 27");
}

#pragma mark Limits

// What one request may ask of the service, and what a failure tells.
- (void)testLimits
{
  NSMutableString *longFilter = [NSMutableString stringWithString:@"Products?$filter=ProductID eq 1"];
  while (longFilter.length < 9000) [longFilter appendString:@" or ProductID eq 1"];
  XCTAssertEqual([self get:longFilter].status, 414);

  NSString *(^repeat)(NSString *, NSUInteger) = ^NSString *(NSString *text, NSUInteger times) {
    return [@"" stringByPaddingToLength:text.length * times withString:text startingAtIndex:0];
  };
  OISServiceResponse *r = [self get:[NSString stringWithFormat:@"Products?$filter=%@true%@", repeat(@"(", 200), repeat(@")", 200)]];
  XCTAssertEqual(r.status, 400, @"parentheses: %@", r.text);
  NSString *nots = [NSString stringWithFormat:@"Products?$filter=%@true", repeat(@"not ", 300)];
  NSString *search = [NSString stringWithFormat:@"Products?$search=%@tea%@", repeat(@"(", 200), repeat(@")", 200)];
  NSString *reasonable = [NSString stringWithFormat:@"Products?$filter=%@true%@", repeat(@"(", 20), repeat(@")", 20)];
  XCTAssertEqual([self get:nots].status, 400, @"not");
  XCTAssertEqual([self get:search].status, 400, @"$search");
  XCTAssertEqual([self get:reasonable].status, 200, @"what is reasonable");

  _service.maxExpandDepth = 2;
  XCTAssertEqual([self get:@"Categories?$expand=Products($expand=Suppliers)"].status, 200);
  XCTAssertEqual([self get:@"Categories?$expand=Products($expand=Suppliers($expand=Products))"].status, 400);
  XCTAssertEqual([self get:@"Categories?$expand=Products($levels=3)"].status, 400);

  NSMutableString *deep = [NSMutableString stringWithString:@"{\"CategoryName\":\"Deep\",\"Note\":"];
  [deep appendString:repeat(@"[", 100)];
  [deep appendString:repeat(@"]", 100)];
  [deep appendString:@"}"];
  NSURL *url = [NSURL URLWithString:@"http://example.test/odata/Categories"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = [deep dataUsingEncoding:NSUTF8StringEncoding];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  r = [self exchange:request];
  XCTAssertEqual(r.status, 400, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"nested deeper"], @"%@", r.text);

  _service.maxBatchRequests = 2;
  NSDictionary *get = @{ @"id": @"1", @"method": @"GET", @"url": @"Categories" };
  r = [self send:@"POST" path:@"$batch" headers:nil body:@{ @"requests": @[ get, [get mutableCopy], [get mutableCopy] ] }];
  XCTAssertEqual(r.status, 400, @"%@", r.text);

  // Work done in memory, over no more rows than the service takes.
  _service.maxRowsInMemory = 3;
  XCTAssertEqual([self get:@"Products?$apply=aggregate(UnitPrice with sum as Total)"].status, 400);
  XCTAssertEqual([self get:@"Products?$apply=filter(UnitPrice gt 20)/aggregate(UnitPrice with sum as Total)"].status, 200);
  XCTAssertEqual([self get:@"Products?$compute=UnitPrice mul 2 as Twice&$orderby=Twice"].status, 400);
  XCTAssertEqual([self get:@"Products?$orderby=UnitPrice"].status, 200, @"the store sorts that");
  // A computed name that stands for a path is that path: the store sorts by it.
  r = [self get:@"Products?$compute=Category/CategoryName as C&$orderby=C desc,ProductID&$select=ProductName"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([self names:r], (@[ @"Aniseed Syrup", @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix", @"Chai", @"Chang" ]));

  // A store's failure: a 500 that does not say what the store said.
  [_service setHandler:[[OISFailingStoreHandler alloc] initWithEntity:OISCatalogEntity(@"Category")] forEntitySet:@"Categories"];
  r = [self get:@"Categories"];
  XCTAssertEqual(r.status, 500);
  XCTAssertFalse([r.text containsString:@"secret"], @"%@", r.text);
}

// More asynchronous requests than the service keeps are answered at once.
- (void)testAsyncRequestsAreBounded
{
  _service.maxAsyncRequests = 1;
  [_service setHandler:[[OISLaterProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  NSDictionary *async = @{ @"Prefer": @"respond-async" };
  XCTAssertEqual([self send:@"GET" path:@"Products" headers:async body:nil].status, 202);
  OISServiceResponse *second = [self send:@"GET" path:@"Products" headers:async body:nil];
  XCTAssertEqual(second.status, 200, @"%@", second.text);
  XCTAssertEqual([second.json[@"value"] count], 4u);
}

#pragma mark Application time

// OData-Temporal's example departments (section 2.3): each row a time
// slice of a department, valid from From to To (closed-open dates).
- (void)serveDepartmentHistory
{
  NSEntityDescription *department = [[NSEntityDescription alloc] init];
  department.name = @"Department";
  department.managedObjectClassName = @"NSManagedObject";
  department.userInfo = @{ @"OData.entitySet": @"Departments", @"OData.periodStart": @"from", @"OData.periodEnd": @"to",
                           @"OData.objectKey": @"department" };
  NSAttributeDescription *slice = OISSwatchAttribute(@"tsid", NSInteger64AttributeType, nil);
  slice.userInfo = @{ @"OData.key": @"YES" };
  NSAttributeDescription *from = OISSwatchAttribute(@"from", NSDateAttributeType, nil);
  from.userInfo = @{ @"OData.type": @"Edm.Date" };
  NSAttributeDescription *to = OISSwatchAttribute(@"to", NSDateAttributeType, nil);
  to.userInfo = @{ @"OData.type": @"Edm.Date" };
  to.optional = YES;
  // A division, whose departments' slices are a timeline reached by navigation.
  NSEntityDescription *division = [[NSEntityDescription alloc] init];
  division.name = @"Division";
  division.managedObjectClassName = @"NSManagedObject";
  division.userInfo = @{ @"OData.entitySet": @"Divisions" };
  NSAttributeDescription *divisionID = OISSwatchAttribute(@"id", NSInteger32AttributeType, nil);
  divisionID.userInfo = @{ @"OData.key": @"YES" };
  NSRelationshipDescription *slices = [[NSRelationshipDescription alloc] init];
  slices.name = @"departments";
  slices.destinationEntity = department;
  slices.minCount = 0;
  slices.maxCount = 0;
  slices.optional = YES;
  NSRelationshipDescription *owner = [[NSRelationshipDescription alloc] init];
  owner.name = @"division";
  owner.destinationEntity = division;
  owner.maxCount = 1;
  owner.optional = YES;
  slices.inverseRelationship = owner;
  owner.inverseRelationship = slices;
  division.properties = @[ divisionID, slices ];
  department.properties = @[ slice, OISSwatchAttribute(@"department", NSStringAttributeType, nil), from, to,
                             OISSwatchAttribute(@"name", NSStringAttributeType, nil), OISSwatchAttribute(@"budget", NSInteger32AttributeType, nil), owner ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ department, division ];
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error], @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  NSArray *rows = @[ @[ @"D08", @"2010-01-01", @"2012-01-01", @"Support", @1000 ],
                     @[ @"D08", @"2012-01-01", @"2012-06-01", @"Support", @1250 ],
                     @[ @"D08", @"2012-06-01", @"2014-01-01", @"1st Level Support", @1250 ],
                     @[ @"D08", @"2014-01-01", [NSNull null], @"1st Level Support", @1400 ],
                     @[ @"D15", @"2010-01-01", @"2011-01-01", @"Services", @1100 ],
                     @[ @"D15", @"2011-01-01", [NSNull null], @"Services", @1170 ] ];
  for (NSArray *row in rows) {
    NSMutableDictionary *body = [@{ @"Department": row[0], @"From": row[1], @"Name": row[3], @"Budget": row[4] } mutableCopy];
    if (row[2] != [NSNull null]) body[@"To"] = row[2];
    XCTAssertEqual([self send:@"POST" path:@"Departments" headers:nil body:body].status, 201);
  }
  XCTAssertEqual([self send:@"POST" path:@"Divisions" headers:nil body:@{ @"Id": @1 }].status, 201);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  NSFetchRequest *d08 = [NSFetchRequest fetchRequestWithEntityName:@"Department"];
  d08.predicate = [NSPredicate predicateWithFormat:@"department == 'D08'"];
  NSManagedObject *first = [[context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Division"] error:NULL] firstObject];
  for (NSManagedObject *slice in [context executeFetchRequest:d08 error:NULL]) [slice setValue:first forKey:@"division"];
  NSError *saveError = nil;
  XCTAssertTrue([context save:&saveError], @"%@", saveError);
}

// A department's slices, in order: [From, To, Name, Budget].
- (NSArray *)historyOf:(NSString *)department
{
  NSString *path = [NSString stringWithFormat:@"Departments?$filter=Department eq '%@'&$orderby=From", department];
  NSMutableArray *slices = [NSMutableArray array];
  for (NSDictionary *row in [self get:path].json[@"value"]) [slices addObject:@[ row[@"From"], row[@"To"], row[@"Name"], row[@"Budget"] ]];
  return slices;
}

// OData-Temporal section 4.2: $at, $from with $to or $toInclusive.
- (void)testApplicationTimeQueries
{
  [self serveDepartmentHistory];
  NSString *metadata = [self get:@"$metadata"].text;
  XCTAssertTrue([metadata containsString:@"Term=\"Org.OData.Temporal.V1.ApplicationTimeSupport\""], @"%@", metadata);
  XCTAssertTrue([metadata containsString:@"<Record Type=\"Org.OData.Temporal.V1.TimelineVisible\">"], @"%@", metadata);
  XCTAssertTrue([metadata containsString:@"<PropertyValue Property=\"PeriodStart\"><PropertyPath>From</PropertyPath></PropertyValue>"], @"%@", metadata);
  XCTAssertTrue([metadata containsString:@"Org.OData.Temporal.V1.xml"]);

  NSArray *rows = [self get:@"Departments?$at=2012-03-01&$filter=Department eq 'D08'"].json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"Budget"], @[ @1250 ], @"%@", rows);
  rows = [self get:@"Departments?$at=2020-01-01&$orderby=Department"].json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"Budget"], (@[ @1400, @1170 ]), @"no end: still valid");
  rows = [self get:@"Departments?$from=2012-03-01&$to=2014-01-01&$filter=Department eq 'D08'&$orderby=From"].json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"From"], (@[ @"2012-01-01", @"2012-06-01" ]), @"closed-open");
  rows = [self get:@"Departments?$from=2012-03-01&$toInclusive=2014-01-01&$filter=Department eq 'D08'&$orderby=From"].json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"From"], (@[ @"2012-01-01", @"2012-06-01", @"2014-01-01" ]), @"closed-closed");
  rows = [self get:@"Departments?$from=2013-01-01&$filter=Department eq 'D08'&$orderby=From"].json[@"value"];
  XCTAssertEqualObjects([rows valueForKey:@"From"], (@[ @"2012-06-01", @"2014-01-01" ]), @"from on");
  XCTAssertEqualObjects([self get:@"Departments/$count?$at=2010-06-01"].text, @"2");
  XCTAssertEqual([self get:@"Departments?$at=2012-01-01&$from=2012-01-01"].status, 400);
  XCTAssertEqual([self get:@"Departments?$to=2012-01-01"].status, 400);
  XCTAssertEqual([self get:@"Departments?$at=Budget"].status, 501, @"a literal");

  // Inside $expand, for a timeline reached by navigation (section 4.2.1).
  OISServiceResponse *r = [self get:@"Divisions(1)?$expand=Departments($at=2012-03-01)"];
  XCTAssertEqualObjects([r.json[@"Departments"] valueForKey:@"Budget"], @[ @1250 ], @"%@", r.text);
  r = [self get:@"Divisions(1)?$expand=Departments($from=2012-03-01;$to=2014-01-01;$orderby=From)"];
  XCTAssertEqualObjects([r.json[@"Departments"] valueForKey:@"From"], (@[ @"2012-01-01", @"2012-06-01" ]), @"%@", r.text);
  XCTAssertEqual([self get:@"Divisions(1)?$expand=Departments($at=2012-03-01;$from=2012-03-01)"].status, 400);
}

// OData-Temporal section 4.3.2, with its own example 18: Update splits the
// slices at the period's edges and changes those inside it.
- (void)testApplicationTimeUpdate
{
  [self serveDepartmentHistory];
  OISServiceResponse *r = [self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D08", @"From": @"2012-04-01", @"To": @"2014-07-01", @"Budget": @1320 } } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects(r.json[@"@odata.context"], @"http://example.test/odata/$metadata#Collection(Org.OData.Temporal.V1.TimesliceWithPeriod)");
  NSArray *returned = [r.json[@"value"] valueForKey:@"Timeslice"];
  XCTAssertEqualObjects([returned valueForKey:@"From"], (@[ @"2012-01-01", @"2012-04-01", @"2012-06-01", @"2014-01-01", @"2014-07-01" ]), @"%@", r.text);
  XCTAssertEqualObjects([returned valueForKey:@"Budget"], (@[ @1250, @1320, @1320, @1320, @1400 ]));
  NSArray *expected = @[ @[ @"2010-01-01", @"2012-01-01", @"Support", @1000 ],
                         @[ @"2012-01-01", @"2012-04-01", @"Support", @1250 ],
                         @[ @"2012-04-01", @"2012-06-01", @"Support", @1320 ],
                         @[ @"2012-06-01", @"2014-01-01", @"1st Level Support", @1320 ],
                         @[ @"2014-01-01", @"2014-07-01", @"1st Level Support", @1320 ],
                         @[ @"2014-07-01", [NSNull null], @"1st Level Support", @1400 ] ];
  XCTAssertEqualObjects([self historyOf:@"D08"], expected, @"as the specification's table after");
  XCTAssertEqual([self historyOf:@"D15"].count, 2u, @"another object untouched");

  // An update outside every slice changes nothing; a period that ends
  // before it starts, or none at all, is refused.
  r = [self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D15", @"From": @"2000-01-01", @"To": @"2001-01-01", @"Budget": @1 } } ] }];
  XCTAssertEqualObjects(r.json[@"value"], @[]);
  XCTAssertEqual(([self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"From": @"2012-01-01", @"To": @"2011-01-01", @"Budget": @1 } } ] }].status), 400);
  XCTAssertEqual(([self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Budget": @1 } } ] }].status), 400);
  XCTAssertEqual(([self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"PeriodStart": @"2012-01-01", @"Timeslice": @{ @"Budget": @1 } } ] }].status), 400, @"a visible timeline");

  // The set's handler is asked for every write: it can refuse one, and
  // then nothing of the action is done.
  NSEntityDescription *entity = _coordinator.managedObjectModel.entitiesByName[@"Department"];
  OISBudgetGuard *guard = [[OISBudgetGuard alloc] initWithEntity:entity];
  [_service setHandler:guard forEntitySet:@"Departments"];
  r = [self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D15", @"From": @"2015-01-01", @"To": @"2016-01-01", @"Budget": @9999 } } ] }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertEqual([self historyOf:@"D15"].count, 2u, @"all or nothing");
  r = [self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D15", @"From": @"2015-01-01", @"To": @"2016-01-01", @"Budget": @2000 } } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqual([self historyOf:@"D15"].count, 4u);
  XCTAssertTrue(guard.inserts > 0 && guard.updates > 0, @"%ld inserts, %ld updates", (long)guard.inserts, (long)guard.updates);

  // One that answers later: the action waits for each of its writes, and
  // makes each once.
  OISLaterWrites *later = [[OISLaterWrites alloc] initWithEntity:entity];
  [_service setHandler:later forEntitySet:@"Departments"];
  r = [self send:@"POST" path:@"Departments/Temporal.Update" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D15", @"From": @"2015-06-01", @"Budget": @1 } } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqual(later.inserts, 1, @"the slice split");
  XCTAssertEqual(later.updates, 2, @"the slice it split from, and the one after");
  XCTAssertEqual([self historyOf:@"D15"].count, 5u);
}

// Delete takes a period away, splitting a slice around it; Upsert fills a
// gap from the slice before it, and makes an object's first slice.
- (void)testApplicationTimeDeleteAndUpsert
{
  [self serveDepartmentHistory];
  OISServiceResponse *r = [self send:@"POST" path:@"Departments/Org.OData.Temporal.V1.Delete" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D08", @"From": @"2011-01-01", @"To": @"2011-06-01" } } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSDictionary *gone = [r.json[@"value"] firstObject][@"Timeslice"];
  XCTAssertEqualObjects((@[ gone[@"From"], gone[@"To"], gone[@"Budget"] ]), (@[ @"2011-01-01", @"2011-06-01", @1000 ]), @"%@", r.text);
  NSArray *history = [self historyOf:@"D08"];
  XCTAssertEqualObjects(history[0], (@[ @"2010-01-01", @"2011-01-01", @"Support", @1000 ]));
  XCTAssertEqualObjects(history[1], (@[ @"2011-06-01", @"2012-01-01", @"Support", @1000 ]));
  XCTAssertEqual(history.count, 5u);

  // The gap, filled from the slice before it, with the new budget.
  r = [self send:@"POST" path:@"Departments/Temporal.Upsert" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D08", @"From": @"2010-06-01", @"To": @"2011-06-01", @"Budget": @1111 } } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  history = [self historyOf:@"D08"];
  XCTAssertEqualObjects([history subarrayWithRange:NSMakeRange(0, 4)], (@[ @[ @"2010-01-01", @"2010-06-01", @"Support", @1000 ],
                                                                          @[ @"2010-06-01", @"2011-01-01", @"Support", @1111 ],
                                                                          @[ @"2011-01-01", @"2011-06-01", @"Support", @1111 ],
                                                                          @[ @"2011-06-01", @"2012-01-01", @"Support", @1000 ] ]), @"%@", history);

  // A department that has no slices yet: its first, from the delta.
  r = [self send:@"POST" path:@"Departments/Temporal.Upsert" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D20", @"From": @"2020-01-01", @"Name": @"New", @"Budget": @10 } } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([self historyOf:@"D20"], (@[ @[ @"2020-01-01", [NSNull null], @"New", @10 ] ]));
  // No object key matches every object; where none has a slice there, a
  // new one would need its key.
  XCTAssertEqual(([self send:@"POST" path:@"Departments/Temporal.Upsert" headers:nil body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"From": @"1900-01-01", @"To": @"1901-01-01", @"Budget": @10 } } ] }].status), 400, @"a new object needs its key");

  // return=minimal; and a set without application time has no such actions.
  XCTAssertEqual(([self send:@"POST" path:@"Departments/Temporal.Delete" headers:@{ @"Prefer": @"return=minimal" } body:@{
    @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D20", @"From": @"2020-01-01" } } ] }].status), 204);
  XCTAssertEqualObjects([self historyOf:@"D20"], @[]);
  [self serveModel:OISCatalogModel()];
  XCTAssertEqual(([self send:@"POST" path:@"Products/Temporal.Update" headers:nil body:@{ @"deltaTimeslices": @[] }].status), 404);
}

static NSDate *OISDay(NSString *day)
{
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  formatter.dateFormat = @"yyyy-MM-dd";
  return [formatter dateFromString:day];
}

// The client: a model from $metadata knows the period; a fetch asks for a
// point or an interval of application time; the actions change it.
- (void)testIncrementalStoreApplicationTime
{
  [self serveDepartmentHistory];
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  NSEntityDescription *entity = model.entitiesByName[@"Department"];
  XCTAssertEqualObjects(entity.userInfo[ODataUserInfoPeriodStart], @"from");
  XCTAssertEqualObjects(entity.userInfo[ODataUserInfoPeriodEnd], @"to");
  XCTAssertEqualObjects(entity.userInfo[ODataUserInfoObjectKey], @"department");
  [ODataIncrementalStore registerStore];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  ODataIncrementalStore *store = (ODataIncrementalStore *)[client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
      URL:[NSURL URLWithString:@"http://example.test/odata/"] options:@{ ODataIncrementalStoreTransportOption: transport } error:&error];
  XCTAssertNotNil(store, @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Department"];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
    [ODataTemporalPredicate predicateAt:OISDay(@"2012-03-01")], [NSPredicate predicateWithFormat:@"department == 'D08'"] ]];
  NSArray *slices = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqualObjects([slices valueForKey:@"budget"], @[ @1250 ], @"%@", error);
  NSString *sent = [[transport.requests.lastObject URL].absoluteString stringByRemovingPercentEncoding];
  XCTAssertTrue([sent containsString:@"$at=2012-03-01"], @"%@", sent);
  XCTAssertTrue([fetch.predicate evaluateWithObject:slices.firstObject], @"in memory too");

  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
    [ODataTemporalPredicate predicateFrom:OISDay(@"2012-03-01") to:OISDay(@"2014-01-01")], [NSPredicate predicateWithFormat:@"department == 'D08'"] ]];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"from" ascending:YES] ];
  slices = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqual(slices.count, 2u, @"%@", error);
  ODataTemporalPredicate *later = [ODataTemporalPredicate predicateFrom:OISDay(@"2014-01-01") toInclusive:OISDay(@"2014-01-01")];
  XCTAssertFalse([later evaluateWithObject:slices.lastObject], @"ends the day before, closed-open");
  ODataTemporalPredicate *before = [ODataTemporalPredicate predicateFrom:OISDay(@"2013-12-31") toInclusive:OISDay(@"2013-12-31")];
  XCTAssertTrue([before evaluateWithObject:slices.lastObject]);
  XCTAssertFalse([before evaluateWithObject:slices.firstObject]);

  // Example 18 again, from the client.
  NSArray *changed = [store performTemporalAction:@"Update" onEntityNamed:@"Department" deltaTimeslices:@[
    @{ @"department": @"D08", @"from": OISDay(@"2012-04-01"), @"to": OISDay(@"2014-07-01"), @"budget": @1320 } ] context:context error:&error];
  XCTAssertEqual(changed.count, 5u, @"%@", error);
  XCTAssertEqualObjects([changed valueForKey:@"budget"], (@[ @1250, @1320, @1320, @1320, @1400 ]));
  fetch.predicate = [NSPredicate predicateWithFormat:@"department == 'D08'"];
  XCTAssertEqualObjects([[context executeFetchRequest:fetch error:&error] valueForKey:@"budget"], (@[ @1000, @1250, @1320, @1320, @1320, @1400 ]));
  XCTAssertNil([store performTemporalAction:@"Update" onEntityNamed:@"Department" deltaTimeslices:@[ @{ @"budget": @1 } ] context:context error:&error],
               @"no period");
  XCTAssertEqual([error.userInfo[ODataErrorHTTPStatusKey] integerValue], 400);
}

#pragma mark $compute

// Part 2 section 5.1.3: computed values, by name in $select, $filter and
// $orderby, and in one another.
- (void)testCompute
{
  XCTAssertTrue([[self get:@"$metadata"].text containsString:@"<PropertyValue Property=\"ComputeSupported\"><Bool>true</Bool></PropertyValue>"]);
  OISServiceResponse *r = [self get:@"Products?$compute=UnitPrice mul 2 as Twice&$select=ProductName,Twice&$filter=Twice gt 40&$orderby=Twice desc"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *values = r.json[@"value"];
  XCTAssertEqualObjects([values valueForKey:@"ProductName"], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]), @"%@", r.text);
  XCTAssertEqualWithAccuracy([values[0][@"Twice"] doubleValue], 44.0, 0.001);
  XCTAssertEqualWithAccuracy([values[1][@"Twice"] doubleValue], 42.7, 0.001);
  XCTAssertNil(values[0][@"UnitPrice"], @"only what is selected");

  // Without $select, with the rest; one name used by the next.
  r = [self get:@"Products(1)?$compute=UnitPrice mul 2 as Twice,Twice add 1 as More"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualWithAccuracy([r.json[@"More"] doubleValue], 37.0, 0.001, @"%@", r.text);
  XCTAssertEqualObjects(r.json[@"ProductName"], @"Chai");

  // Sorted by it here, and paged after: the pages follow on.
  NSMutableArray *names = [NSMutableArray array];
  NSString *next = @"Products?$compute=UnitPrice mul -1 as Negative&$orderby=Negative&$select=ProductName";
  while (next) {
    r = [self send:@"GET" path:next headers:@{ @"Prefer": @"odata.maxpagesize=2" } body:nil];
    XCTAssertEqual(r.status, 200, @"%@", r.text);
    [names addObjectsFromArray:[r.json[@"value"] valueForKey:@"ProductName"]];
    next = r.json[@"@odata.nextLink"] ? [self pathOfLink:r.json[@"@odata.nextLink"]] : nil;
  }
  XCTAssertEqualObjects(names, (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix", @"Chang", @"Chai", @"Aniseed Syrup" ]));

  XCTAssertEqualObjects([self get:@"Products/$count?$compute=UnitPrice mul 2 as Twice&$filter=Twice lt 30"].text, @"1");

  // Inside $expand, for its members.
  r = [self get:@"Categories(1)?$expand=Products($compute=UnitPrice mul 2 as Twice;$select=ProductName,Twice;$filter=Twice gt 30;$orderby=Twice desc)"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *members = r.json[@"Products"];
  XCTAssertEqualObjects([members valueForKey:@"ProductName"], (@[ @"Chang", @"Chai" ]), @"%@", r.text);
  XCTAssertEqualWithAccuracy([members.firstObject[@"Twice"] doubleValue], 38.0, 0.001);
  XCTAssertEqual([self get:@"Products?$compute=UnitPrice mul 2"].status, 400, @"a name for it");
  XCTAssertEqual([self get:@"Products?$compute=Category as Whole"].status, 400, @"not a value");
}

// A dictionary fetch's computed values: $compute where the service has
// it (4.01), computed from the rows here where it has not (4.0).
- (void)testIncrementalStoreComputes
{
  NSExpressionDescription *twice = [[NSExpressionDescription alloc] init];
  twice.name = @"twice";
  // As each platform names multiplication.
  twice.expression = [NSExpression expressionWithFormat:@"unitPrice * 2"];
  twice.expressionResultType = NSDecimalAttributeType;
  for (NSString *version in @[ @"4.01", @"4.0" ]) {
    [self serveModel:OISCatalogModel()];  // a service's version is its own from the first request
    _service.maxVersion = version;
    OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
    transport.next = _service;
    NSError *error = nil;
    NSManagedObjectContext *client = [self clientOver:transport options:nil error:&error];
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
    fetch.resultType = NSDictionaryResultType;
    fetch.propertiesToFetch = @[ @"name", @"category.name", twice ];
    fetch.predicate = [NSPredicate predicateWithFormat:@"id <= 2"];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
    NSArray *rows = [client executeFetchRequest:fetch error:&error];
    XCTAssertEqual(rows.count, 2u, @"%@: %@", version, error);
    XCTAssertEqualObjects([rows valueForKey:@"name"], (@[ @"Chai", @"Chang" ]), @"%@", version);
    XCTAssertEqualObjects(rows.firstObject[@"category.name"], @"Beverages", @"%@: %@", version, rows);
    XCTAssertEqualWithAccuracy([rows.firstObject[@"twice"] doubleValue], 36.0, 0.001, @"%@: %@", version, rows);
    XCTAssertEqualWithAccuracy([rows.lastObject[@"twice"] doubleValue], 38.0, 0.001, @"%@: %@", version, rows);
    NSString *sent = [[transport.requests.lastObject URL].absoluteString stringByRemovingPercentEncoding];
    BOOL computed = [sent containsString:@"$compute=UnitPrice mul 2 as twice"];
    XCTAssertEqual(computed, [version isEqualToString:@"4.01"], @"%@: %@", version, sent);
  }
}

// A dictionary's key paths through to-one relationships: each an $expand
// with its $select (a $select cannot follow a navigation property), and
// the values read from the expanded rows.
- (void)testDictionariesThroughRelationships
{
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *client = [self clientOver:transport options:nil error:&error];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Stock"];
  fetch.resultType = NSDictionaryResultType;
  fetch.propertiesToFetch = @[ @"quantity", @"product.name", @"product.category.name", @"location.city" ];
  fetch.relationshipKeyPathsForPrefetching = @[ @"location" ];
  NSArray *rows = [client executeFetchRequest:fetch error:&error];
  XCTAssertEqual(rows.count, 1u, @"%@", error);
  XCTAssertEqualObjects(rows.firstObject, (@{ @"quantity": @40, @"product.name": @"Chai", @"product.category.name": @"Beverages", @"location.city": @"Leeds" }));
  NSString *sent = [[transport.requests.lastObject URL].absoluteString stringByRemovingPercentEncoding];
  XCTAssertTrue([sent containsString:@"$select=Quantity&$expand=Location($select=City),Product($select=ProductName;$expand=Category($select=CategoryName))"], @"%@", sent);

  // Only related values: the row's key, not all of it.
  fetch.propertiesToFetch = @[ @"product.name" ];
  fetch.relationshipKeyPathsForPrefetching = nil;
  rows = [client executeFetchRequest:fetch error:&error];
  XCTAssertEqualObjects(rows, (@[ @{ @"product.name": @"Chai" } ]), @"%@", error);
  sent = [[transport.requests.lastObject URL].absoluteString stringByRemovingPercentEncoding];
  XCTAssertTrue([sent containsString:@"$select=StockID&$expand=Product($select=ProductName)"], @"%@", sent);
}

#pragma mark JSON $batch

- (NSArray<NSURLRequest *> *)batchesIn:(NSArray<NSURLRequest *> *)requests
{
  return [requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"URL.absoluteString ENDSWITH '$batch'"]];
}

// A 4.01 service's $batch in JSON (JSON Format section 19): a save of two
// changes is one atomicity group; a stale one fails it whole.
- (void)testJSONBatchSaves
{
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *client = [self clientOver:transport options:nil error:&error];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id <= 2"];
  NSArray *products = [client executeFetchRequest:fetch error:&error];
  XCTAssertEqual(products.count, 2u, @"%@", error);
  for (NSManagedObject *product in products) [product setValue:[[product valueForKey:@"name"] stringByAppendingString:@"!"] forKey:@"name"];
  [transport.requests removeAllObjects];
  XCTAssertTrue([client save:&error], @"%@", error);
  NSArray *batches = [self batchesIn:transport.requests];
  XCTAssertEqual(batches.count, 1u);
  XCTAssertEqualObjects([batches.firstObject valueForHTTPHeaderField:@"Content-Type"], @"application/json");
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:[batches.firstObject HTTPBody] options:0 error:NULL];
  XCTAssertEqualObjects([body[@"requests"] valueForKey:@"method"], (@[ @"PATCH", @"PATCH" ]));
  XCTAssertEqualObjects([body[@"requests"] valueForKey:@"atomicityGroup"], (@[ @"g1", @"g1" ]));
  XCTAssertEqualObjects([self get:@"Products(1)"].json[@"ProductName"], @"Chai!");
  XCTAssertEqualObjects([self get:@"Products(2)"].json[@"ProductName"], @"Chang!");

  // Meanwhile, product 2 changes at the service: the group fails whole,
  // and the save reports the conflict.
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(2)" headers:nil body:@{ @"UnitPrice": @20 }].status), 204);
  for (NSManagedObject *product in products) [product setValue:[[product valueForKey:@"name"] stringByAppendingString:@"?"] forKey:@"name"];
  XCTAssertFalse([client save:&error]);
  NSArray *conflicts = error.userInfo[NSPersistentStoreSaveConflictsErrorKey];
  XCTAssertEqual(conflicts.count, 1u, @"%@", error);
  XCTAssertEqualObjects([[conflicts.firstObject sourceObject] valueForKey:@"id"], @2);
  XCTAssertEqualObjects([self get:@"Products(1)"].json[@"ProductName"], @"Chai!", @"nothing of it done");
}

// A service that refuses the JSON form gets multipart, from then on; and
// the option keeps to multipart from the start.
- (void)testJSONBatchRefusedIsSentAsMultipart
{
  OISMultipartOnlyTransport *transport = [[OISMultipartOnlyTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *client = [self clientOver:transport options:nil error:&error];
  NSArray *categories = [client executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Category"] error:&error];
  XCTAssertEqual(categories.count, 2u, @"%@", error);
  for (int round = 0; round < 2; round++) {
    for (NSManagedObject *category in categories) [category setValue:[NSString stringWithFormat:@"%@ %d", [category valueForKey:@"name"], round] forKey:@"name"];
    [transport.requests removeAllObjects];
    XCTAssertTrue([client save:&error], @"%@", error);
    NSArray *types = [[self batchesIn:transport.requests] valueForKey:@"allHTTPHeaderFields"];
    NSArray *expected = round == 0 ? @[ @"application/json", @"multipart" ] : @[ @"multipart" ];
    XCTAssertEqual(types.count, expected.count, @"round %d: %@", round, types);
    for (NSUInteger i = 0; i < MIN(types.count, expected.count); i++) {
      XCTAssertTrue([types[i][@"Content-Type"] hasPrefix:expected[i]], @"round %d: %@", round, types);
    }
  }
  XCTAssertEqualObjects([self get:@"Categories(1)"].json[@"CategoryName"], @"Beverages 0 1");

  OISRecordingTransport *recording = [[OISRecordingTransport alloc] init];
  recording.next = _service;
  client = [self clientOver:recording options:@{ ODataIncrementalStoreJSONBatchOption: @NO } error:&error];
  categories = [client executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Category"] error:&error];
  for (NSManagedObject *category in categories) [category setValue:@"Same" forKey:@"name"];
  XCTAssertTrue([client save:&error], @"%@", error);
  XCTAssertTrue([[[self batchesIn:recording.requests].firstObject valueForHTTPHeaderField:@"Content-Type"] hasPrefix:@"multipart/mixed"]);
}

#pragma mark Asynchronous requests

// A status monitor's answer, once it has one: polled as a client would.
- (OISServiceResponse *)waitOnMonitor:(NSString *)location headers:(NSDictionary *)headers
{
  NSString *path = [self pathOfLink:location];
  OISServiceResponse *response = nil;
  for (int i = 0; i < 200; i++) {
    response = [self send:@"GET" path:path headers:headers body:nil];
    if (response.status != 202) break;
    usleep(10000);
  }
  return response;
}

// Part 1 sections 8.2.8.8 and 11.6: a request that prefers respond-async
// and is not answered at once is accepted, and its answer is at the status
// monitor.
- (void)testAsynchronousRequests
{
  XCTAssertTrue([[self get:@"$metadata"].text containsString:@"AsynchronousRequestsSupported"]);
  [_service setHandler:[[OISLaterProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  NSDictionary *async = @{ @"Prefer": @"respond-async" };
  OISServiceResponse *accepted = [self send:@"GET" path:@"Products?$select=ProductName" headers:async body:nil];
  XCTAssertEqual(accepted.status, 202, @"%@", accepted.text);
  XCTAssertEqualObjects(accepted.headers[@"Preference-Applied"], @"respond-async");
  NSString *monitor = accepted.headers[@"Location"];
  XCTAssertTrue([monitor hasPrefix:@"http://example.test/odata/$async/"], @"%@", monitor);

  OISServiceResponse *done = [self waitOnMonitor:monitor headers:nil];
  XCTAssertEqual(done.status, 200, @"%@", done.text);
  XCTAssertEqualObjects(done.headers[@"Content-Type"], @"application/http");
  XCTAssertEqualObjects(done.headers[@"AsyncResult"], @"200");
  ODataBatchPart *answer = ODataHTTPMessage(done.data);
  XCTAssertEqual(answer.status, 200);
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:answer.body options:0 error:NULL];
  XCTAssertEqual([json[@"value"] count], 4u, @"the handler's answer: %@", json);
  XCTAssertEqual([self get:[self pathOfLink:monitor]].status, 200, @"kept for another look");

  XCTAssertEqual([self send:@"DELETE" path:[self pathOfLink:monitor] headers:nil body:nil].status, 204);
  XCTAssertEqual([self get:[self pathOfLink:monitor]].status, 404, @"forgotten");
  XCTAssertEqual([self get:@"$async/anothermonitor"].status, 404);

  // Answered at once, or within wait=: answered as though not asked.
  OISServiceResponse *direct = [self send:@"GET" path:@"Categories" headers:async body:nil];
  XCTAssertEqual(direct.status, 200);
  XCTAssertNil(direct.headers[@"Preference-Applied"]);
  direct = [self send:@"GET" path:@"Products" headers:@{ @"Prefer": @"respond-async, wait=3" } body:nil];
  XCTAssertEqual(direct.status, 200, @"%@", direct.text);
  XCTAssertEqual([direct.json[@"value"] count], 4u);

  // Turned off.
  _service.asyncResultDuration = 0;
  XCTAssertEqual([self send:@"GET" path:@"Products" headers:async body:nil].status, 200);
}

// A status monitor is only for who sent the request.
- (void)testStatusMonitorsAreTheSenders
{
  _service.authenticator = [[OISLaterAuthenticator alloc] init];
  OISServiceResponse *accepted = [self send:@"POST" path:@"Categories"
                                    headers:@{ @"Prefer": @"respond-async", @"Authorization": @"Token alice" }
                                       body:@{ @"CategoryName": @"Asynchronous" }];
  XCTAssertEqual(accepted.status, 202, @"the authenticator answers later: %@", accepted.text);
  NSString *monitor = accepted.headers[@"Location"];
  XCTAssertEqual([self waitOnMonitor:monitor headers:@{ @"Authorization": @"Token bob" }].status, 404);
  OISServiceResponse *done = [self waitOnMonitor:monitor headers:@{ @"Authorization": @"Token alice" }];
  XCTAssertEqual(done.status, 200, @"%@", done.text);
  XCTAssertEqual(ODataHTTPMessage(done.data).status, 201);
}

// The client waits out a status monitor inside one exchange: a fetch and a
// $batch save see only their answers.
- (void)testIncrementalStorePollsStatusMonitors
{
  [_service setHandler:[[OISLaterProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  [_service setHandler:[[OISLaterWrites alloc] initWithEntity:OISCatalogEntity(@"Category")] forEntitySet:@"Categories"];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *client = [self clientOver:transport options:@{ ODataIncrementalStoreRespondAsyncOption: @YES } error:&error];
  XCTAssertNotNil(client, @"%@", error);

  NSArray *products = [client executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Product"] error:&error];
  XCTAssertEqual(products.count, 4u, @"%@", error);
  NSPredicate *polls = [NSPredicate predicateWithFormat:@"URL.absoluteString CONTAINS '$async/'"];
  XCTAssertGreaterThan([transport.requests filteredArrayUsingPredicate:polls].count, 0u, @"it was answered later");

  [transport.requests removeAllObjects];
  NSManagedObject *first = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:client];
  [first setValue:@"First" forKey:@"name"];
  NSManagedObject *second = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:client];
  [second setValue:@"Second" forKey:@"name"];
  XCTAssertTrue([client save:&error], @"%@", error);
  XCTAssertGreaterThan([transport.requests filteredArrayUsingPredicate:polls].count, 0u);

  // Two changes: one $batch change set, answered later too.
  [transport.requests removeAllObjects];
  [first setValue:@"First (new)" forKey:@"name"];
  [second setValue:@"Second (new)" forKey:@"name"];
  XCTAssertTrue([client save:&error], @"%@", error);
  NSPredicate *batches = [NSPredicate predicateWithFormat:@"URL.absoluteString ENDSWITH '$batch'"];
  XCTAssertEqual([transport.requests filteredArrayUsingPredicate:batches].count, 1u, @"%@", transport.requests);
  XCTAssertGreaterThan([transport.requests filteredArrayUsingPredicate:polls].count, 0u);
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"4");
  XCTAssertEqualObjects([self get:@"Categories/$count?$filter=endswith(CategoryName,'(new)')"].text, @"2");
}

#pragma mark Delta links

// The Catalog in a SQLite store that keeps persistent history, with each
// key kept in a deletion's tombstone: its sets' changes can be followed.
- (void)serveTrackedCatalog
{
  [self serveTrackedCatalogWith:nil];
}

- (void)serveTrackedCatalogWith:(void (^)(NSManagedObjectModel *model))change
{
  // A copy: the one loaded may already be in use, and so immutable.
  NSManagedObjectModel *model = [OISCatalogModel() copy];
  if (change) change(model);
  for (NSEntityDescription *entity in model.entities) {
    for (NSAttributeDescription *attribute in entity.attributesByName.allValues) attribute.preservesValueInHistoryOnDeletion = YES;
  }
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
  [_storeFiles addObject:url];
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url
                                                   options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error], @"%@", error);
  [self seed];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator
                                                          serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

// A link the service wrote, as a path for -get: (which encodes it again).
- (NSString *)pathOfLink:(NSString *)link
{
  NSString *root = @"http://example.test/odata/";
  NSString *path = [link hasPrefix:root] ? [link substringFromIndex:root.length] : link;
  return [path stringByRemovingPercentEncoding] ?: path;
}

- (NSManagedObjectContext *)serviceContext
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  return context;
}

// A handler's own changes, with no persistent history: its tokens in the
// delta links, its changes in the deltas.
- (void)testDeltaLinksFromTheHandler
{
  [_service setHandler:[[OISFeedProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  XCTAssertTrue([[self get:@"$metadata"].text containsString:@"ChangeTracking"]);
  OISServiceResponse *read = [self send:@"GET" path:@"Products?$select=ProductName" headers:@{ @"Prefer": @"odata.track-changes" } body:nil];
  XCTAssertEqual(read.status, 200, @"%@", read.text);
  NSString *link = read.json[@"@odata.deltaLink"];
  XCTAssertTrue([link containsString:@"$deltatoken=feed-1"], @"%@", read.text);
  OISServiceResponse *delta = [self get:[self pathOfLink:link]];
  XCTAssertEqual(delta.status, 200, @"%@", delta.text);
  NSArray *values = delta.json[@"value"];
  XCTAssertEqualObjects([[values subarrayWithRange:NSMakeRange(0, 2)] valueForKey:@"ProductName"], (@[ @"Chai", @"Chang" ]), @"%@", delta.text);
  XCTAssertEqualObjects(values.lastObject[@"@odata.id"], @"Products(99)", @"%@", delta.text);
  XCTAssertTrue([delta.json[@"@odata.deltaLink"] containsString:@"$deltatoken=feed-2"], @"%@", delta.text);
  XCTAssertEqual([self get:@"Products?$deltatoken=other"].status, 400, @"the handler's own refusal");
}

// Part 1 section 11.3: Prefer: odata.track-changes gives the read a delta
// link, and the delta link what changed since, from persistent history.
- (void)testDeltaLinks
{
  [self serveTrackedCatalog];
  XCTAssertTrue([[self get:@"$metadata"].text containsString:@"ChangeTracking"]);
  NSDictionary *track = @{ @"Prefer": @"odata.track-changes" };
  OISServiceResponse *read = [self send:@"GET" path:@"Products?$select=ProductName&$filter=UnitPrice gt 15" headers:track body:nil];
  XCTAssertEqual(read.status, 200, @"%@", read.text);
  XCTAssertEqualObjects(read.headers[@"Preference-Applied"], @"odata.track-changes");
  XCTAssertEqual([read.json[@"value"] count], 4u);
  NSString *link = read.json[@"@odata.deltaLink"];
  XCTAssertTrue([link containsString:@"$deltatoken="], @"%@", read.text);
  XCTAssertTrue([link containsString:@"$filter="] && [link containsString:@"$select="], @"the read's options: %@", link);

  OISServiceResponse *delta = [self get:[self pathOfLink:link]];
  XCTAssertEqual(delta.status, 200, @"%@", delta.text);
  XCTAssertEqualObjects(delta.json[@"value"], @[], @"nothing yet");
  XCTAssertEqualObjects(delta.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(ProductName)/$delta");
  link = delta.json[@"@odata.deltaLink"];

  // Meanwhile, in the store.
  NSManagedObjectContext *context = [self serviceContext];
  NSError *error = nil;
  [[self productWithID:2 in:context] setValue:@"Chang (new)" forKey:@"name"];
  [[self productWithID:3 in:context] setValue:[NSDecimalNumber decimalNumberWithString:@"16"] forKey:@"unitPrice"];   // now matches
  [[self productWithID:4 in:context] setValue:[NSDecimalNumber decimalNumberWithString:@"5"] forKey:@"unitPrice"];    // no longer
  [context deleteObject:[self productWithID:5 in:context]];
  NSManagedObject *category = [[self productWithID:1 in:context] valueForKey:@"category"];
  [self insert:@"Product" into:context values:@{ @"id": @6, @"name": @"Ipoh Coffee", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"46"],
                                                  @"discontinued": @NO, @"category": category }];
  NSManagedObject *fleeting = [self insert:@"Product" into:context values:@{ @"id": @7, @"name": @"Fleeting", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"50"],
                                                                             @"discontinued": @NO, @"category": category }];
  XCTAssertTrue([context save:&error], @"%@", error);
  [context deleteObject:fleeting];
  XCTAssertTrue([context save:&error], @"%@", error);

  delta = [self get:[self pathOfLink:link]];
  XCTAssertEqual(delta.status, 200, @"%@", delta.text);
  NSArray *values = delta.json[@"value"];
  NSArray *entities = [values filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"ProductName != nil"]];
  XCTAssertEqualObjects([NSSet setWithArray:[entities valueForKey:@"ProductName"]],
                        ([NSSet setWithObjects:@"Chang (new)", @"Aniseed Syrup", @"Ipoh Coffee", nil]), @"%@", delta.text);
  NSMutableDictionary *removed = [NSMutableDictionary dictionary];
  for (NSDictionary *value in values) {
    if (value[@"@odata.removed"]) removed[value[@"@odata.id"]] = value[@"@odata.removed"][@"reason"];
  }
  // Fleeting came and went since the link, and is told as deleted all the
  // same: a client may have it (one that made it after reading the link).
  XCTAssertEqualObjects(removed, (@{ @"Products(4)": @"changed", @"Products(5)": @"deleted", @"Products(7)": @"deleted" }), @"%@", delta.text);
  XCTAssertEqual(values.count, 6u, @"%@", delta.text);

  // Followed on, nothing more.
  link = delta.json[@"@odata.deltaLink"];
  XCTAssertEqualObjects([self get:[self pathOfLink:link]].json[@"value"], @[]);

  // 4.0's form of a deletion.
  [context deleteObject:[self productWithID:6 in:context]];
  XCTAssertTrue([context save:&error], @"%@", error);
  delta = [self send:@"GET" path:[self pathOfLink:link] headers:@{ @"OData-MaxVersion": @"4.0" } body:nil];
  XCTAssertEqualObjects(delta.json[@"value"], (@[ @{ @"@odata.context": @"http://example.test/odata/$metadata#Products/$deletedEntity",
                                                    @"id": @"Products(6)", @"reason": @"deleted" } ]), @"%@", delta.text);

  // Not a token this service wrote; a read that is not the whole set.
  XCTAssertEqual([self get:@"Products?$deltatoken=nonsense"].status, 400);
  read = [self send:@"GET" path:@"Products?$top=2" headers:track body:nil];
  XCTAssertNil(read.headers[@"Preference-Applied"]);
  XCTAssertNil(read.json[@"@odata.deltaLink"]);
  XCTAssertEqual([self get:@"Products?$top=2&$deltatoken=0"].status, 410);
}

// A delta link holds while the caller's scope version does: another is a
// 410, and the client reads the set again (docs/offline-sync.md, 4.1).
- (void)testDeltaLinksHoldWhileTheScopeDoes
{
  [self serveTrackedCatalog];
  [_service setHandler:[[OISScopeVersionedProducts alloc] initWithEntity:_coordinator.managedObjectModel.entitiesByName[@"Product"]] forEntitySet:@"Products"];
  NSDictionary *v1 = @{ @"Prefer": @"odata.track-changes", @"X-Scope": @"team-7:v1" };
  OISServiceResponse *read = [self send:@"GET" path:@"Products" headers:v1 body:nil];
  NSString *link = read.json[@"@odata.deltaLink"];
  XCTAssertTrue([link containsString:@"*"], @"the scope's version in the link: %@", link);
  XCTAssertFalse([link containsString:@"team-7"], @"opaque in it: %@", link);

  OISServiceResponse *same = [self send:@"GET" path:[self pathOfLink:link] headers:@{ @"X-Scope": @"team-7:v1" } body:nil];
  XCTAssertEqual(same.status, 200, @"%@", same.text);
  link = same.json[@"@odata.deltaLink"];
  OISServiceResponse *moved = [self send:@"GET" path:[self pathOfLink:link] headers:@{ @"X-Scope": @"team-7:v2" } body:nil];
  XCTAssertEqual(moved.status, 410, @"%@", moved.text);
  XCTAssertEqual(([self send:@"GET" path:[self pathOfLink:link] headers:nil body:nil].status), 410, @"no version now is another");

  // Pages too: a scope that moves between them.
  _service.maxPageSize = 2;
  read = [self send:@"GET" path:@"Products" headers:v1 body:nil];
  NSString *next = read.json[@"@odata.nextLink"];
  XCTAssertEqual(([self send:@"GET" path:[self pathOfLink:next] headers:@{ @"X-Scope": @"team-7:v2" } body:nil].status), 410);
  XCTAssertEqual(([self send:@"GET" path:[self pathOfLink:next] headers:@{ @"X-Scope": @"team-7:v1" } body:nil].status), 200);

  // A handler that has no scope version writes links as before.
  [_service setHandler:[[ODataEntitySetHandler alloc] initWithEntity:_coordinator.managedObjectModel.entitiesByName[@"Product"]] forEntitySet:@"Products"];
  _service.maxPageSize = 0;
  link = [self send:@"GET" path:@"Products" headers:@{ @"Prefer": @"odata.track-changes" } body:nil].json[@"@odata.deltaLink"];
  XCTAssertFalse([link containsString:@"*"], @"%@", link);
}

- (NSArray *)idsOf:(NSArray *)entries
{
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *entry in entries) [ids addObject:entry[@"@odata.id"] ?: [NSNull null]];
  return ids;
}

// A deletion is reported to those who could see the row, by what its
// tombstone kept; when the visibility reads anything else, to everyone.
- (void)testDeletionsGoToThoseWhoCouldSeeThem
{
  [self serveTrackedCatalog];
  [_service setHandler:[[OISScopedProducts alloc] initWithEntity:_coordinator.managedObjectModel.entitiesByName[@"Product"]] forEntitySet:@"Products"];
  NSString *link = [self send:@"GET" path:@"Products" headers:@{ @"Prefer": @"odata.track-changes" } body:nil].json[@"@odata.deltaLink"];
  NSManagedObjectContext *context = [self serviceContext];
  NSError *error = nil;
  [context deleteObject:[self productWithID:3 in:context]];   // seen: not discontinued
  [context deleteObject:[self productWithID:5 in:context]];   // discontinued: never seen
  XCTAssertTrue([context save:&error], @"%@", error);
  OISServiceResponse *delta = [self get:[self pathOfLink:link]];
  XCTAssertEqual(delta.status, 200, @"%@", delta.text);
  XCTAssertEqualObjects([self idsOf:delta.json[@"value"]], @[ @"Products(3)" ], @"%@", delta.text);

  // Visible by a relationship, which no tombstone keeps: every deletion.
  [self serveTrackedCatalog];
  [_service setHandler:[[OISBeveragesOnly alloc] initWithEntity:_coordinator.managedObjectModel.entitiesByName[@"Product"]] forEntitySet:@"Products"];
  link = [self send:@"GET" path:@"Products" headers:@{ @"Prefer": @"odata.track-changes" } body:nil].json[@"@odata.deltaLink"];
  context = [self serviceContext];
  [context deleteObject:[self productWithID:5 in:context]];   // a condiment
  XCTAssertTrue([context save:&error], @"%@", error);
  delta = [self get:[self pathOfLink:link]];
  XCTAssertEqualObjects([self idsOf:delta.json[@"value"]], @[ @"Products(5)" ], @"%@", delta.text);
}

// History kept only so long: a delta link from before what is kept is a
// 410, and the client reads the set again; one given after is good.
- (void)testHistoryRetention
{
  [self serveTrackedCatalog];
  NSDictionary *track = @{ @"Prefer": @"odata.track-changes" };
  NSString *old = [self send:@"GET" path:@"Products" headers:track body:nil].json[@"@odata.deltaLink"];
  NSManagedObjectContext *context = [self serviceContext];
  NSError *error = nil;
  [[self productWithID:1 in:context] setValue:@"Chai (new)" forKey:@"name"];
  XCTAssertTrue([context save:&error], @"%@", error);
  XCTAssertTrue([_service pruneHistoryBeforeDate:[NSDate dateWithTimeIntervalSinceNow:1] error:&error], @"%@", error);
  OISServiceResponse *expired = [self get:[self pathOfLink:old]];
  XCTAssertEqual(expired.status, 410, @"%@", expired.text);

  NSString *fresh = [self send:@"GET" path:@"Products" headers:track body:nil].json[@"@odata.deltaLink"];
  [[self productWithID:2 in:context] setValue:@"Chang (new)" forKey:@"name"];
  XCTAssertTrue([context save:&error], @"%@", error);
  OISServiceResponse *delta = [self get:[self pathOfLink:fresh]];
  XCTAssertEqual(delta.status, 200, @"%@", delta.text);
  XCTAssertEqualObjects([delta.json[@"value"] valueForKey:@"ProductName"], @[ @"Chang (new)" ], @"%@", delta.text);

  // By itself, as requests come: what is older than the retention goes.
  NSString *before = delta.json[@"@odata.deltaLink"];
  [[self productWithID:3 in:context] setValue:@"Aniseed Syrup (new)" forKey:@"name"];
  XCTAssertTrue([context save:&error], @"%@", error);
  [NSThread sleepForTimeInterval:1.2];
  _service.historyRetention = 1;
  [self get:@"Products/$count"];   // prunes, in the background
  NSInteger status = 0;
  for (int i = 0; i < 50 && status != 410; i++) {
    [NSThread sleepForTimeInterval:0.05];
    status = [self get:[self pathOfLink:before]].status;
  }
  XCTAssertEqual(status, 410, @"history older than a second was pruned");
}

// A tracked read in pages: each next link carries where the changes
// begin, so one made to a page already read still comes in the delta.
- (void)testDeltaLinkAfterPages
{
  [self serveTrackedCatalog];
  _service.maxPageSize = 2;
  NSDictionary *track = @{ @"Prefer": @"odata.track-changes" };
  OISServiceResponse *page = [self send:@"GET" path:@"Products" headers:track body:nil];
  XCTAssertNil(page.json[@"@odata.deltaLink"], @"only with the last page");
  NSString *next = page.json[@"@odata.nextLink"];
  XCTAssertTrue([next containsString:@"~"], @"%@", next);

  NSManagedObjectContext *context = [self serviceContext];
  [[self productWithID:1 in:context] setValue:@"Chai (new)" forKey:@"name"];
  NSError *error = nil;
  XCTAssertTrue([context save:&error], @"%@", error);

  NSString *link = nil;
  NSUInteger rows = [page.json[@"value"] count];
  while (next) {
    page = [self get:[self pathOfLink:next]];  // Prefer not sent again
    rows += [page.json[@"value"] count];
    next = page.json[@"@odata.nextLink"];
    link = page.json[@"@odata.deltaLink"];
  }
  XCTAssertEqual(rows, 5u);
  XCTAssertNotNil(link);
  OISServiceResponse *delta = [self get:[self pathOfLink:link]];
  XCTAssertEqualObjects([delta.json[@"value"] valueForKey:@"ProductName"], @[ @"Chai (new)" ], @"%@", delta.text);
}

// Without persistent history there is nothing to follow changes with.
- (void)testNoDeltaLinksWithoutHistory
{
  XCTAssertFalse([[self get:@"$metadata"].text containsString:@"ChangeTracking"]);
  OISServiceResponse *read = [self send:@"GET" path:@"Products" headers:@{ @"Prefer": @"odata.track-changes" } body:nil];
  XCTAssertEqual(read.status, 200);
  XCTAssertNil(read.headers[@"Preference-Applied"]);
  XCTAssertNil(read.json[@"@odata.deltaLink"]);
  XCTAssertEqual([self get:@"Products?$deltatoken=0"].status, 410);

  [self serveTrackedCatalog];
  [_service handlerForEntitySet:@"Products"].tracksChanges = NO;
  XCTAssertNil([self send:@"GET" path:@"Products" headers:@{ @"Prefer": @"odata.track-changes" } body:nil].json[@"@odata.deltaLink"]);
  XCTAssertNotNil([self send:@"GET" path:@"Categories" headers:@{ @"Prefer": @"odata.track-changes" } body:nil].json[@"@odata.deltaLink"]);
}

// The client follows the service's delta links: -fetchRemoteChanges:
// asks what changed, not for every set again.
- (void)testIncrementalStoreFollowsDeltaLinks
{
  [self serveTrackedCatalog];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *client = [self clientOver:transport options:nil error:&error];
  XCTAssertNotNil(client, @"%@", error);
  ODataIncrementalStore *store = (ODataIncrementalStore *)client.persistentStoreCoordinator.persistentStores.firstObject;
  XCTAssertNotNil([store fetchRemoteChanges:&error], @"%@", error);

  NSManagedObjectContext *context = [self serviceContext];
  [[self productWithID:2 in:context] setValue:@"Chang (new)" forKey:@"name"];
  [context deleteObject:[self productWithID:5 in:context]];
  XCTAssertTrue([context save:&error], @"%@", error);

  [transport.requests removeAllObjects];
  NSNotification *changes = [store fetchRemoteChanges:&error];
  XCTAssertNotNil(changes, @"%@", error);
  for (NSURLRequest *request in transport.requests) {
    XCTAssertTrue([request.URL.query containsString:@"$deltatoken="], @"%@", request.URL);
  }
  NSSet *updated = changes.userInfo[NSUpdatedObjectIDsKey];
  NSSet *deleted = changes.userInfo[NSDeletedObjectIDsKey];
  // The deletion changed its category's and supplier's products too.
  NSSet *products = [updated filteredSetUsingPredicate:[NSPredicate predicateWithFormat:@"entity.name == 'Product'"]];
  XCTAssertEqual(products.count, 1u, @"%@", changes.userInfo);
  XCTAssertEqual(deleted.count, 1u, @"%@", changes.userInfo);
  XCTAssertEqualObjects([[client objectWithID:products.anyObject] valueForKey:@"name"], @"Chang (new)");
  XCTAssertNil(changes.userInfo[NSInsertedObjectIDsKey]);
}

// A write refused for its ETag (412) is a save conflict, as Core Data's
// own stores report one; a merge policy settles it.
- (void)testStaleWritesAreMergeConflicts
{
  NSError *error = nil;
  NSManagedObjectContext *context = [self clientOver:_service options:nil error:&error];
  XCTAssertNotNil(context, @"%@", error);
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai");

  // Meanwhile, at the service.
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil body:@{ @"ProductName": @"Chai (new)" }].status), 204);

  [chai setValue:[NSDecimalNumber decimalNumberWithString:@"99"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error]);
  XCTAssertEqualObjects(error.domain, NSCocoaErrorDomain);
  NSArray *conflicts = error.userInfo[NSPersistentStoreSaveConflictsErrorKey];
  XCTAssertEqual(conflicts.count, 1u, @"%@", error);
  NSMergeConflict *conflict = conflicts.firstObject;
  XCTAssertEqual(conflict.sourceObject, chai);
  XCTAssertEqualObjects(conflict.persistedSnapshot[@"name"], @"Chai (new)", @"what the service has now");
  XCTAssertGreaterThan(conflict.newVersionNumber, conflict.oldVersionNumber);

  // Settled by the policy the application chooses, and saved again: the
  // object's change over the service's, property by property.
  context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
  XCTAssertTrue([context.mergePolicy resolveConflicts:conflicts error:&error], @"%@", error);
  XCTAssertTrue([context save:&error], @"%@", error);
  NSDictionary *row = [self get:@"Products(1)"].json;
  XCTAssertEqualObjects(row[@"ProductName"], @"Chai (new)", @"the service's change kept");
  XCTAssertEqualObjects(row[@"UnitPrice"], @99, @"and the object's");

  // A context whose merge policy is set settles it on its own.
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil body:@{ @"ProductName": @"Chai (newer)" }].status), 204);
  [chai setValue:[NSDecimalNumber decimalNumberWithString:@"100"] forKey:@"unitPrice"];
  BOOL saved = [context save:&error];
  XCTAssertTrue(saved, @"the merge policy applied: %@", error);
  row = [self get:@"Products(1)"].json;
  XCTAssertEqualObjects(row[@"UnitPrice"], @100);
  XCTAssertEqualObjects(row[@"ProductName"], @"Chai (newer)");

  // Deleted at the service: a conflict with no snapshot.
  XCTAssertEqual(([self send:@"POST" path:@"Products" headers:nil body:@{ @"ProductID": @50, @"ProductName": @"Kelp" }].status), 201);
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == 50"];
  NSManagedObject *kelp = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertNotNil(kelp, @"%@", error);
  OISServiceResponse *deleted = [self send:@"DELETE" path:@"Products(50)" headers:nil data:nil];
  XCTAssertEqual(deleted.status, 204, @"%@", deleted.text);
  context.mergePolicy = NSErrorMergePolicy;
  [kelp setValue:[NSDecimalNumber decimalNumberWithString:@"101"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error]);
  NSMergeConflict *gone = [error.userInfo[NSPersistentStoreSaveConflictsErrorKey] firstObject];
  XCTAssertNotNil(gone, @"%@", error);
  XCTAssertNil(gone.persistedSnapshot);
}

// $metadata in CSDL JSON, asked for by $format or Accept.
- (void)testMetadataInJSON
{
  for (OISServiceResponse *response in @[ [self get:@"$metadata?$format=json"],
                                          [self send:@"GET" path:@"$metadata" headers:@{ @"Accept": @"application/json" } data:nil] ]) {
    XCTAssertEqual(response.status, 200, @"%@", response.text);
    XCTAssertTrue([[response header:@"Content-Type"] hasPrefix:@"application/json"]);
    NSDictionary *json = response.json;
    XCTAssertEqualObjects(json[@"$EntityContainer"], @"Default.Container");
    XCTAssertEqualObjects(json[@"Default"][@"Product"][@"$Key"], @[ @"ProductID" ]);
    XCTAssertEqualObjects(json[@"Default"][@"Container"][@"Products"][@"$Type"], @"Default.Product");
    ODataSchema *schema = [ODataSchema schemaWithData:response.data error:NULL];
    XCTAssertEqualObjects(schema.entitySets[@"Products"], @"Default.Product", @"and it reads as CSDL");
  }
  XCTAssertTrue([[[self send:@"GET" path:@"$metadata" headers:@{ @"Accept": @"application/xml, application/json" } data:nil] header:@"Content-Type"] hasPrefix:@"application/xml"]);
  XCTAssertEqual([self get:@"$metadata?$format=atom"].status, 406);
}

// $metadata is written with NSXML: whatever a name or an annotation holds
// is escaped, and reads back as it was.
- (void)testMetadataIsWellFormedWhateverItHolds
{
  NSString *tricky = @"Fish & chips <\"best\"> ]]> 'quoted' é";
  _service.containerAnnotations = @{ @"Core.Description": tricky, @"Core.LongDescription": @[ @"a<b", @{ @"$Path": @"x&y" } ] };
  OISServiceResponse *metadata = [self get:@"$metadata"];
  NSError *error = nil;
  XCTAssertNotNil([[NSXMLDocument alloc] initWithData:metadata.data options:0 error:&error], @"%@\n%@", error, metadata.text);
  ODataSchema *schema = [ODataSchema schemaWithData:metadata.data error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  XCTAssertEqualObjects([schema annotation:@"Core.Description" forTarget:schema.containerName], tricky);
  XCTAssertEqualObjects([schema annotation:@"Core.LongDescription" forTarget:schema.containerName], (@[ @"a<b", @{ @"$Path": @"x&y" } ]));
  XCTAssertEqualObjects(schema.entitySets[@"Products"], @"Default.Product", @"the rest as before");
}

- (NSArray *)productIDsSearching:(NSString *)search more:(NSString *)more
{
  NSString *path = [NSString stringWithFormat:@"Products?$search=%@&$select=ProductID&$orderby=ProductID%@", search, more ?: @""];
  OISServiceResponse *response = [self get:path];
  XCTAssertEqual(response.status, 200, @"%@: %@", search, response.text);
  return [response.json[@"value"] valueForKey:@"ProductID"];
}

// $search: each word or phrase in a string property, regardless of case
// and diacritics.
- (void)testSearch
{
  // Chai, Chang, Aniseed Syrup, Chef Anton's Cajun Seasoning, Chef Anton's Gumbo Mix.
  NSDictionary *expected = @{
    @"chef": @[ @4, @5 ],
    @"chef gumbo": @[ @5 ],
    @"chef AND gumbo": @[ @5 ],
    @"chai OR syrup": @[ @1, @3 ],
    @"NOT chef": @[ @1, @2, @3 ],
    @"\"anton's cajun\"": @[ @4 ],
    @"ANISEED": @[ @3 ],
    @"chaï": @[ @1 ],
    @"(chai OR chang) NOT chai": @[ @2 ],
  };
  for (NSString *search in expected) {
    XCTAssertEqualObjects([self productIDsSearching:search more:nil], expected[search], @"%@", search);
  }
  XCTAssertEqualObjects([self productIDsSearching:@"chef" more:@"&$filter=Discontinued eq false"], @[ @4 ], @"with $filter");
  XCTAssertEqualObjects([self get:@"Products/$count?$search=chef"].text, @"2");
  NSArray *expanded = [self get:@"Categories(2)?$expand=Products($search=chef;$select=ProductID)"].json[@"Products"];
  XCTAssertEqualObjects([[expanded valueForKey:@"ProductID"] sortedArrayUsingSelector:@selector(compare:)], (@[ @4, @5 ]));
  XCTAssertEqual([self get:@"Products?$search=AND"].status, 400);
  XCTAssertEqual([self get:@"Products?$search=\"open"].status, 400);

  // Only where the set says.
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.searchableProperties = [NSSet setWithObject:@"QuantityPerUnit"];
  [_service setHandler:products forEntitySet:@"Products"];
  XCTAssertEqualObjects([self productIDsSearching:@"chai" more:nil], @[]);
  products.searchableProperties = [NSSet set];
  XCTAssertEqual([self get:@"Products?$search=chai"].status, 501);
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  XCTAssertEqualObjects([schema capability:@"Capabilities.SearchRestrictions" forEntitySet:@"Products"], @{ @"Searchable": @NO });
}

- (NSArray *)applied:(NSString *)query
{
  OISServiceResponse *response = [self get:[@"Products?" stringByAppendingString:query]];
  XCTAssertEqual(response.status, 200, @"%@: %@", query, response.text);
  return response.json[@"value"];
}

// $apply (Data Aggregation): filter, groupby and aggregate.
- (void)testApply
{
  // Prices 18, 19 (Beverages); 10, 22, 21.35 (Condiments, the last discontinued).
  NSDictionary *total = [[self applied:@"$apply=aggregate(UnitPrice with sum as Total,$count as N)"] firstObject];
  XCTAssertEqualWithAccuracy([total[@"Total"] doubleValue], 90.35, 1e-9);
  XCTAssertEqualObjects(total[@"N"], @5);
  XCTAssertTrue([total objectForKey:@"@odata.id"] == [NSNull null], @"an aggregate has no id");

  OISServiceResponse *grouped = [self get:@"Products?$apply=groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))&$orderby=Category/CategoryName"];
  XCTAssertEqualObjects(grouped.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(Category(CategoryName),Total)");
  NSArray *rows = grouped.json[@"value"];
  XCTAssertEqualObjects([rows valueForKeyPath:@"Category.CategoryName"], (@[ @"Beverages", @"Condiments" ]));
  XCTAssertEqualWithAccuracy([rows[0][@"Total"] doubleValue], 37.0, 1e-9);
  XCTAssertEqualWithAccuracy([rows[1][@"Total"] doubleValue], 53.35, 1e-9);

  rows = [self applied:@"$apply=filter(Discontinued eq false)/groupby((Category/CategoryName),aggregate(UnitPrice with max as Top,UnitPrice with min as Bottom))&$orderby=Top desc"];
  XCTAssertEqualObjects([rows valueForKeyPath:@"Category.CategoryName"], (@[ @"Condiments", @"Beverages" ]));
  XCTAssertEqualObjects([rows valueForKey:@"Top"], (@[ @22, @19 ]));
  XCTAssertEqualObjects([rows valueForKey:@"Bottom"], (@[ @10, @18 ]));

  rows = [self applied:@"$apply=groupby((Category/CategoryName),aggregate($count as N))/filter(N gt 2)"];
  XCTAssertEqualObjects([rows valueForKeyPath:@"Category.CategoryName"], @[ @"Condiments" ], @"a filter after grouping");
  rows = [self applied:@"$apply=groupby((Category/CategoryName),aggregate($count as N))&$filter=N lt 3&$count=true"];
  XCTAssertEqualObjects([rows valueForKeyPath:@"Category.CategoryName"], @[ @"Beverages" ], @"$filter on the result");
  rows = [self applied:@"$apply=groupby((Discontinued))&$orderby=Discontinued"];
  XCTAssertEqualObjects([rows valueForKey:@"Discontinued"], (@[ @NO, @YES ]));
  rows = [self applied:@"$apply=groupby((Category/CategoryName,Discontinued))&$orderby=Category/CategoryName,Discontinued&$top=2&$skip=1"];
  XCTAssertEqual(rows.count, 2u);
  XCTAssertEqualWithAccuracy([[[self applied:@"$apply=aggregate(UnitPrice with average as Mean)"] firstObject][@"Mean"] doubleValue], 18.07, 1e-9);
  XCTAssertEqualObjects([[self applied:@"$apply=aggregate(Category/CategoryName with countdistinct as Kinds)"] firstObject][@"Kinds"], @2);
  XCTAssertEqualObjects([[self applied:@"$apply=filter(UnitPrice gt 30)/aggregate(UnitPrice with sum as Total)"] firstObject][@"Total"], [NSNull null],
                        @"the sum of nothing is null");
  XCTAssertEqualObjects([[self applied:@"$apply=filter(UnitPrice gt 20)&$orderby=ProductID"] valueForKey:@"ProductID"], (@[ @4, @5 ]),
                        @"filter alone: entities");

  XCTAssertEqual([self get:@"Products?$apply=nest(groupby((Category/CategoryName)) as Grouped)"].status, 501);
  XCTAssertEqual([self get:@"Products?$apply=aggregate(UnitPrice with Custom.concat as X)"].status, 400, @"a method the set does not have");
  XCTAssertEqual([self get:@"Products?$apply=aggregate(UnitPrice sum)"].status, 400);
  XCTAssertEqual([self get:@"Products?$apply=groupby((Nothing))"].status, 400);
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:NULL];
  XCTAssertNotNil([schema annotation:@"Org.OData.Aggregation.V1.ApplySupportedDefaults" forTarget:schema.containerName]);
  XCTAssertNotNil([schema capability:@"Org.OData.Aggregation.V1.ApplySupported" forEntitySet:@"Products"], @"each set says it");
}

static NSExpressionDescription *OISAggregateOf(NSString *function, NSString *keyPath, NSString *name, NSAttributeType type)
{
  NSExpressionDescription *description = [[NSExpressionDescription alloc] init];
  description.name = name;
  description.expression = [NSExpression expressionForFunction:function arguments:@[ [NSExpression expressionForKeyPath:keyPath] ]];
  description.expressionResultType = type;
  return description;
}

// Grouped and aggregated dictionary fetches: by $apply where the service
// has it, here where it does not; the same rows either way.
// A collection operator in a client's predicate: aggregate() where the
// service has Data Aggregation.
- (void)testClientsAggregateNavigations
{
  for (NSNumber *applies in @[ @YES, @NO ]) {
    _service.containerAnnotations = applies.boolValue ? nil : @{ @"Aggregation.ApplySupportedDefaults": [NSNull null] };
    OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
    transport.next = _service;
    NSError *error = nil;
    NSManagedObjectContext *context = [self clientOver:transport options:nil error:&error];
    XCTAssertNotNil(context, @"%@", error);
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
    fetch.predicate = [NSPredicate predicateWithFormat:@"products.@sum.unitPrice > 40"];
    NSArray *rows = [context executeFetchRequest:fetch error:&error];
    NSString *query = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding] ?: @"";
    if (applies.boolValue) {
      XCTAssertEqualObjects([rows valueForKey:@"name"], @[ @"Condiments" ], @"%@", error);
      XCTAssertTrue([query containsString:@"$filter=Products/aggregate(UnitPrice with sum) gt 40"], @"%@", query);
    } else {
      XCTAssertNil(rows, @"no aggregate() at a service without it");
      XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedExpression, @"%@", error);
    }
  }
}

- (void)testClientsGroupAndAggregate
{
  // Every transformation; groupby, aggregate and filter only; none.
  NSArray *modes = @[ @"all", @"some", @"none" ];
  for (NSString *mode in modes) {
    NSNumber *applies = @(![mode isEqualToString:@"none"]);
    if ([mode isEqualToString:@"some"]) {
      _service.containerAnnotations = @{ @"Aggregation.ApplySupportedDefaults": @{ @"Transformations": @[ @"filter", @"groupby", @"aggregate" ] } };
    }
    if ([mode isEqualToString:@"none"]) _service.containerAnnotations = @{ @"Aggregation.ApplySupportedDefaults": [NSNull null] };
    OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
    transport.next = _service;
    NSError *error = nil;
    NSManagedObjectContext *context = [self clientOver:transport options:nil error:&error];
    XCTAssertNotNil(context, @"%@", error);

    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
    fetch.resultType = NSDictionaryResultType;
    fetch.propertiesToGroupBy = @[ @"category.name" ];
    fetch.propertiesToFetch = @[ @"category.name", OISAggregateOf(@"sum:", @"unitPrice", @"total", NSDecimalAttributeType),
                                 OISAggregateOf(@"count:", @"id", @"n", NSInteger64AttributeType),
                                 OISAggregateOf(@"max:", @"unitPrice", @"top", NSDecimalAttributeType) ];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"category.name" ascending:YES] ];
    NSArray *rows = [context executeFetchRequest:fetch error:&error];
    XCTAssertEqual(rows.count, 2u, @"%@: %@", applies, error);
    XCTAssertEqualObjects([rows valueForKey:@"category.name"], (@[ @"Beverages", @"Condiments" ]), @"%@", applies);
    XCTAssertEqualObjects([rows valueForKey:@"n"], (@[ @2, @3 ]), @"%@", applies);
    XCTAssertEqualObjects(rows[1][@"total"], [NSDecimalNumber decimalNumberWithString:@"53.35"], @"%@", applies);
    XCTAssertEqualObjects(rows[1][@"top"], [NSDecimalNumber decimalNumberWithString:@"22"], @"%@", applies);
    NSString *query = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding] ?: @"";
    XCTAssertEqual([query containsString:@"$apply="], applies.boolValue, @"%@: %@", applies, query);

    // Filtered first, then kept or not by the having predicate.
    fetch.predicate = [NSPredicate predicateWithFormat:@"discontinued == NO"];
    fetch.havingPredicate = [NSPredicate predicateWithFormat:@"total > 35"];
    rows = [context executeFetchRequest:fetch error:&error];
    XCTAssertEqualObjects([rows valueForKey:@"category.name"], @[ @"Beverages" ], @"%@: %@", applies, error);
    query = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding] ?: @"";
    XCTAssertEqual([query containsString:@"/filter(total gt 35)"], applies.boolValue, @"%@: %@", mode, query);

    // After the grouping, as far as the service lists the transformations:
    // the having predicate, the sort, the offset and the limit.
    fetch.predicate = nil;
    fetch.havingPredicate = [NSPredicate predicateWithFormat:@"n >= 2 AND total != nil"];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"total" ascending:NO] ];
    fetch.fetchOffset = 1;
    fetch.fetchLimit = 1;
    rows = [context executeFetchRequest:fetch error:&error];
    XCTAssertEqualObjects([rows valueForKey:@"category.name"], @[ @"Beverages" ], @"%@: %@", mode, error);
    query = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding] ?: @"";
    BOOL everything = [mode isEqualToString:@"all"];
    XCTAssertEqual([query containsString:@"/filter(n ge 2 and total ne null)"], applies.boolValue, @"%@: %@", mode, query);
    XCTAssertEqual([query containsString:@"/orderby(total desc)/skip(1)/top(1)"], everything, @"%@: %@", mode, query);

    // A having predicate the rows' filter cannot say: here, and then the
    // offset and the limit here too, after it.
    fetch.havingPredicate = [NSPredicate predicateWithFormat:@"category.name BEGINSWITH 'C' OR n == 2"];
    rows = [context executeFetchRequest:fetch error:&error];
    XCTAssertEqualObjects([rows valueForKey:@"category.name"], @[ @"Beverages" ], @"%@: %@", mode, error);
    query = [[[transport.requests.lastObject URL] query] stringByRemovingPercentEncoding] ?: @"";
    XCTAssertFalse([query containsString:@"top("], @"%@: %@", mode, query);
    XCTAssertEqual([query containsString:@"/orderby(total desc)"], everything, @"%@: %@", mode, query);
    fetch.havingPredicate = nil;
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"category.name" ascending:YES] ];
    fetch.fetchOffset = 0;
    fetch.fetchLimit = 0;

    // No grouping: one row for them all.
    NSFetchRequest *all = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
    all.resultType = NSDictionaryResultType;
    all.propertiesToFetch = @[ OISAggregateOf(@"average:", @"unitPrice", @"mean", NSDoubleAttributeType) ];
    rows = [context executeFetchRequest:all error:&error];
    XCTAssertEqual(rows.count, 1u, @"%@", error);
    XCTAssertEqualWithAccuracy([rows.firstObject[@"mean"] doubleValue], 18.07, 1e-9, @"%@", applies);

    all.propertiesToFetch = @[ @"name", OISAggregateOf(@"sum:", @"unitPrice", @"total", NSDecimalAttributeType) ];
    XCTAssertNil([context executeFetchRequest:all error:&error], @"what is fetched is grouped by");
  }
}

// The client's $search: ODataSearchPredicate at the top of the predicate.
- (void)testClientsSearch
{
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *context = [self clientOver:transport options:nil error:&error];
  XCTAssertNotNil(context, @"%@", error);
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
    [ODataSearchPredicate predicateWithSearch:@"chef"], [NSPredicate predicateWithFormat:@"unitPrice > 21.5"] ]];
  NSArray *rows = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqualObjects([rows valueForKey:@"name"], @[ @"Chef Anton's Cajun Seasoning" ], @"%@", error);
  NSString *query = [[transport.requests.lastObject URL] query];
  XCTAssertTrue([query containsString:@"$search=chef"], @"%@", query);
  XCTAssertTrue([query containsString:@"$filter="], @"%@", query);

  fetch.predicate = [ODataSearchPredicate predicateWithSearch:@"chai OR syrup"];
  XCTAssertEqual([context countForFetchRequest:fetch error:&error], 2u, @"%@", error);
  XCTAssertTrue([[transport.requests.lastObject URL].path hasSuffix:@"/$count"]);

  fetch.predicate = [NSCompoundPredicate orPredicateWithSubpredicates:@[
    [ODataSearchPredicate predicateWithSearch:@"chef"], [NSPredicate predicateWithFormat:@"unitPrice > 21.5"] ]];
  XCTAssertNil([context executeFetchRequest:fetch error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedPredicate, @"not under OR: %@", error);
  XCTAssertTrue([[ODataSearchPredicate predicateWithSearch:@"anton NOT gumbo"] evaluateWithObject:@{ @"n": @"Chef Anton's Cajun" }]);
  XCTAssertNil([ODataSearchPredicate predicateWithSearch:@"(" error:&error]);
}

// Capabilities.FilterFunctions: a function it leaves out is not tried
// (Part 1 section 13.3, item 20).
- (void)testClientsFilterOnlyWithTheFunctionsListed
{
  _service.containerAnnotations = @{ @"Capabilities.FilterFunctions": @[ @"contains", @"tolower" ] };
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSError *error = nil;
  NSManagedObjectContext *context = [self clientOver:transport options:nil error:&error];
  XCTAssertNotNil(context, @"%@", error);
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[c] 'CHA'"];
  XCTAssertEqual([context executeFetchRequest:fetch error:&error].count, 2u, @"%@", error);
  fetch.predicate = [NSPredicate predicateWithFormat:@"name BEGINSWITH 'Ch'"];
  NSUInteger before = transport.requests.count;
  XCTAssertNil([context executeFetchRequest:fetch error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorNotAllowedByService, @"%@", error);
  XCTAssertTrue([error.localizedDescription rangeOfString:@"startswith"].location != NSNotFound, @"%@", error);
  XCTAssertEqual(transport.requests.count, before, @"not asked");
}

- (void)testClientsHeedTheCapabilities
{
  // A service that says it does not do $top, $skip, $count, $expand,
  // $select or $batch, sorting by name or filtering by quantity, or deleting
  // products: the client does not ask, and does it itself where it can.
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.nonFilterableProperties = [NSSet setWithObject:@"QuantityPerUnit"];
  products.nonSortableProperties = [NSSet setWithObject:@"ProductName"];
  products.allowsDelete = NO;
  [_service setHandler:products forEntitySet:@"Products"];
  _service.containerAnnotations = @{ @"Capabilities.TopSupported": @NO, @"Capabilities.SkipSupported": @NO,
                                     @"Capabilities.BatchSupported": @NO, @"Capabilities.CountRestrictions": @{ @"Countable": @NO },
                                     @"Capabilities.ExpandRestrictions": @{ @"Expandable": @NO },
                                     @"Capabilities.SelectSupport": @{ @"Supported": @NO } };
  [ODataIncrementalStore registerStore];
  OISRecordingTransport *transport = [[OISRecordingTransport alloc] init];
  transport.next = _service;
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: transport } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:NO] ];
  fetch.fetchOffset = 1;
  fetch.fetchLimit = 2;
  NSUInteger before = transport.requests.count;
  NSArray *rows = [context executeFetchRequest:fetch error:&error];
  XCTAssertEqualObjects([rows valueForKey:@"name"], (@[ @"Chef Anton's Cajun Seasoning", @"Chang" ]), @"%@", error);
  NSString *query = [[transport.requests[before] URL] query] ?: @"";
  for (NSString *option in @[ @"orderby", @"top", @"skip", @"expand", @"select" ]) {
    XCTAssertTrue([query rangeOfString:option].location == NSNotFound, @"%@ in %@", option, query);
  }

  fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"discontinued == NO"];
  before = transport.requests.count;
  XCTAssertEqual([context countForFetchRequest:fetch error:&error], 4u, @"%@", error);
  XCTAssertTrue([[[transport.requests[before] URL] path] rangeOfString:@"$count"].location == NSNotFound, @"counted here");

  fetch.predicate = [NSPredicate predicateWithFormat:@"quantityPerUnit == 'x'"];
  before = transport.requests.count;
  XCTAssertNil([context executeFetchRequest:fetch error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorNotAllowedByService, @"%@", error);
  XCTAssertEqual(transport.requests.count, before, @"not asked");

  fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == 2"];
  NSManagedObject *chang = [[context executeFetchRequest:fetch error:NULL] firstObject];
  [context deleteObject:chang];
  before = transport.requests.count;
  error = nil;
  XCTAssertFalse([context save:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorNotAllowedByService, @"%@", error);
  // Core Data reads the relationships its delete rules nullify; nothing
  // is deleted.
  NSArray *sent = [[transport.requests subarrayWithRange:NSMakeRange(before, transport.requests.count - before)] valueForKey:@"HTTPMethod"];
  XCTAssertFalse([sent containsObject:@"DELETE"], @"%@", sent);
  [context rollback];

  for (NSNumber *identifier in @[ @70, @71 ]) {
    NSManagedObject *product = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
    [product setValue:identifier forKey:@"id"];
    [product setValue:@"Tea" forKey:@"name"];
  }
  before = transport.requests.count;
  XCTAssertTrue([context save:&error], @"%@", error);
  NSArray *methods = [[transport.requests subarrayWithRange:NSMakeRange(before, transport.requests.count - before)] valueForKey:@"HTTPMethod"];
  XCTAssertEqual([methods indexesOfObjectsPassingTest:^BOOL(id m, NSUInteger i, BOOL *stop) { return [m isEqual:@"POST"]; }].count, 2u,
                 @"two POSTs, no $batch: %@", methods);
  for (NSURLRequest *request in [transport.requests subarrayWithRange:NSMakeRange(before, transport.requests.count - before)]) {
    XCTAssertTrue([request.URL.path rangeOfString:@"$batch"].location == NSNotFound);
  }
}

#pragma mark Deep updates

- (NSArray *)productIDsOf:(NSString *)path
{
  OISServiceResponse *response = [self get:[path stringByAppendingString:@"?$select=ProductID&$orderby=ProductID"]];
  XCTAssertEqual(response.status, 200, @"%@: %@", path, response.text);
  return [response.json[@"value"] valueForKey:@"ProductID"];
}

- (void)testDeepUpdate
{
  // A to-many's full set: one updated, one bound by @id, one created; the
  // one left out (Chang) unlinked, not deleted.
  OISServiceResponse *full = [self send:@"PATCH" path:@"Categories(1)" headers:@{ @"Prefer": @"return=representation" } body:@{
    @"CategoryName": @"Drinks",
    @"Products": @[ @{ @"ProductID": @1, @"ProductName": @"Chai Tea" }, @{ @"@id": @"Products(3)" }, @{ @"ProductName": @"Mate", @"UnitPrice": @12 } ] }];
  XCTAssertEqual(full.status, 200, @"%@", full.text);
  XCTAssertEqualObjects(full.json[@"CategoryName"], @"Drinks");
  XCTAssertEqualObjects([[full.json[@"Products"] valueForKey:@"ProductID"] sortedArrayUsingSelector:@selector(compare:)], (@[ @1, @3, @6 ]),
                        @"what it relates comes back expanded");
  XCTAssertEqualObjects([self productIDsOf:@"Categories(1)/Products"], (@[ @1, @3, @6 ]));
  XCTAssertEqualObjects([self get:@"Products(1)/ProductName"].json[@"value"], @"Chai Tea");
  XCTAssertEqualObjects([self get:@"Products(6)/UnitPrice"].json[@"value"], @12);
  XCTAssertEqual([self get:@"Products(2)/Category"].status, 204, @"Chang is unlinked");
  XCTAssertEqual([self get:@"Products(2)"].status, 200, @"and still there");

  // A to-one: the entity it names, updated; null; a new one.
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(2)" headers:nil body:@{ @"Category": @{ @"CategoryID": @2, @"CategoryName": @"Sauces" } }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(2)/Category/CategoryName"].json[@"value"], @"Sauces");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(2)" headers:nil body:@{ @"Category": [NSNull null] }].status), 204);
  XCTAssertEqual([self get:@"Products(2)/Category"].status, 204);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(2)" headers:nil body:@{ @"Category": @{ @"CategoryName": @"Snacks" } }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(2)/Category/CategoryID"].json[@"value"], @3);

  // A delta: Chang added, Cajun Seasoning unlinked, Gumbo Mix deleted.
  OISServiceResponse *delta = [self send:@"PATCH" path:@"Categories(2)" headers:nil body:@{
    @"Products@delta": @[ @{ @"@id": @"Products(2)" },
                          @{ @"@removed": @{ @"reason": @"changed" }, @"@id": @"Products(4)" },
                          @{ @"@removed": @{ @"reason": @"deleted" }, @"ProductID": @5 } ] }];
  XCTAssertEqual(delta.status, 204, @"%@", delta.text);
  NSArray *sauces = [self productIDsOf:@"Categories(2)/Products"];
  XCTAssertEqualObjects(sauces, (@[ @2 ]), @"%@", sauces);
  XCTAssertEqual([self get:@"Products(4)/Category"].status, 204);
  XCTAssertEqual([self get:@"Products(5)"].status, 404);

  // Failures change nothing.
  OISServiceResponse *bad = [self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{
    @"CategoryName": @"Nothing", @"Products": @[ @{ @"ProductID": @1, @"UnitPrice": @"cheap" } ] }];
  XCTAssertEqual(bad.status, 400);
  XCTAssertEqualObjects([self get:@"Categories(1)/CategoryName"].json[@"value"], @"Drinks");
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @[ @{ @"@id": @"Products(99)" } ] }].status), 400);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil body:@{ @"Category@delta": @[] }].status), 400, @"a delta is of a collection");
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @{ @"ProductID": @1 } }].status), 400, @"a to-many takes an array");
  OISServiceResponse *stale = [self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{
    @"Products": @[ @{ @"ProductID": @1, @"@odata.etag": @"W/\"999\"", @"ProductName": @"Old" } ] }];
  XCTAssertEqual(stale.status, 412, @"%@", stale.text);
  XCTAssertEqualObjects([self productIDsOf:@"Categories(1)/Products"], (@[ @1, @3, @6 ]));

  // Each nested entity as its set allows.
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.allowsUpdate = NO;
  products.allowsDelete = NO;
  [_service setHandler:products forEntitySet:@"Products"];
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @[ @{ @"ProductID": @1, @"ProductName": @"Chai" } ] }].status), 405);
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{
    @"Products@delta": @[ @{ @"@removed": @{ @"reason": @"deleted" }, @"@id": @"Products(6)" } ] }].status), 405);
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @[ @{ @"ProductID": @1 }, @{ @"@id": @"Products(3)" } ] }].status), 204,
                 @"naming entities, without changing them, only links them");
  XCTAssertEqualObjects([self productIDsOf:@"Categories(1)/Products"], (@[ @1, @3 ]));
}

// What a caller may do is the scopes it has: reading a set, through any
// path or expansion, writing it, calling an operation; $metadata says
// which each needs.
- (void)testScopesPermitWhatACallerMayDo
{
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  _service.serviceOperations = [[OISScopedOperations alloc] init];
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.readScopes = [NSSet setWithObjects:@"Products.Read", @"Catalog.Admin", nil];
  products.updateScopes = [NSSet setWithObject:@"Products.Write"];
  [_service setHandler:products forEntitySet:@"Products"];
  ODataEntitySetHandler *categories = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Category")];
  categories.readScopes = [NSSet setWithObject:@"Categories.Read"];
  [_service setHandler:categories forEntitySet:@"Categories"];
  NSInteger (^status)(NSString *, NSString *, NSString *, id) = ^NSInteger(NSString *method, NSString *path, NSString *scopes, id body) {
    return [self send:method path:path headers:@{ @"X-Scopes": scopes } body:body].status;
  };

  XCTAssertEqual(status(@"GET", @"Products", @"", nil), 403);
  OISServiceResponse *refused = [self send:@"GET" path:@"Products" headers:@{ @"X-Scopes": @"Other" } body:nil];
  XCTAssertTrue([refused.text containsString:@"Catalog.Admin Products.Read"], @"%@", refused.text);
  XCTAssertEqual(status(@"GET", @"Products", @"Products.Read", nil), 200);
  XCTAssertEqual(status(@"GET", @"Products", @"Other Catalog.Admin", nil), 200, @"any one of them");
  XCTAssertEqual(status(@"GET", @"Products(1)/ProductName", @"Products.Read", nil), 200);
  // Every set a read reaches.
  XCTAssertEqual(status(@"GET", @"Products?$expand=Category", @"Products.Read", nil), 403);
  XCTAssertEqual(status(@"GET", @"Products?$expand=Category", @"Products.Read Categories.Read", nil), 200);
  XCTAssertEqual(status(@"GET", @"Categories(1)/Products", @"Products.Read", nil), 403);
  XCTAssertEqual(status(@"GET", @"Categories(1)/Products", @"Products.Read Categories.Read", nil), 200);
  XCTAssertEqual(status(@"GET", @"Suppliers", @"", nil), 200, @"a set that asks for nothing");
  // Writes.
  XCTAssertEqual(status(@"PATCH", @"Products(1)", @"Products.Read", @{ @"ProductName": @"Tea" }), 403);
  XCTAssertEqualObjects([[self send:@"GET" path:@"Products(1)/ProductName" headers:@{ @"X-Scopes": @"Products.Read" } body:nil]
                         .json objectForKey:@"value"], @"Chai");
  XCTAssertEqual(status(@"PATCH", @"Products(1)", @"Products.Write", @{ @"ProductName": @"Tea" }), 204);
  // An operation.
  XCTAssertEqual(status(@"POST", @"Tally", @"Products.Read", @{ @"Amount": @2 }), 403);
  OISServiceResponse *tally = [self send:@"POST" path:@"Tally" headers:@{ @"X-Scopes": @"Tally.Run" } body:@{ @"Amount": @2 }];
  XCTAssertEqual(tally.status, 200, @"%@", tally.text);
  XCTAssertEqualObjects(tally.json[@"value"], @3);

  // What each needs, in $metadata.
  OISServiceResponse *metadata = [self send:@"GET" path:@"$metadata" headers:@{ @"X-Scopes": @"" } body:nil];
  ODataSchema *schema = [ODataSchema schemaWithData:metadata.data error:NULL];
  NSDictionary *read = [schema capability:@"Capabilities.ReadRestrictions" forEntitySet:@"Products"];
  NSDictionary *permission = [read[@"Permissions"] firstObject];
  XCTAssertEqualObjects(permission[@"SchemeName"], @"Provider", @"%@", read);
  XCTAssertEqualObjects([permission[@"Scopes"] valueForKey:@"Scope"], (@[ @"Catalog.Admin", @"Products.Read" ]));
  NSDictionary *update = [schema capability:@"Capabilities.UpdateRestrictions" forEntitySet:@"Products"];
  XCTAssertEqualObjects([[[update[@"Permissions"] firstObject] objectForKey:@"Scopes"] valueForKey:@"Scope"],
                        @[ @"Products.Write" ]);
  XCTAssertNil([schema capability:@"Capabilities.ReadRestrictions" forEntitySet:@"Suppliers"]);
  XCTAssertTrue([metadata.text containsString:@"Org.OData.Capabilities.V1.OperationRestrictions"], @"%@", metadata.text);
  XCTAssertTrue([metadata.text containsString:@"Tally.Admin"]);
}

// A request as someone whose token has these scopes (OISScopeAuthenticator).
- (OISServiceResponse *)send:(NSString *)method path:(NSString *)path scopes:(NSString *)scopes body:(id)body
{
  return [self send:method path:path headers:@{ @"X-Scopes": scopes } body:body];
}

// Each set's read scope: the scope is the set's name and .Read.
- (NSDictionary<NSString *, NSString *> *)readScopesOfSets:(NSArray<NSString *> *)sets
{
  NSMutableDictionary *scopes = [NSMutableDictionary dictionary];
  for (NSString *set in sets) {
    scopes[set] = [set stringByAppendingString:@".Read"];
    [_service handlerForEntitySet:set].readScopes = [NSSet setWithObject:scopes[set]];
  }
  return scopes;
}

// A read needs to read every set it reaches, wherever in it: its path,
// $filter (and the path's), $orderby, $compute, $apply, lambdas, $count
// of a navigation, $expand with its own options -- and no more.
- (void)testScopesAreNeededWhereverAReadReaches
{
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  NSDictionary *scopes = [self readScopesOfSets:@[ @"Products", @"Categories", @"Suppliers" ]];
  NSDictionary *reaches = @{
    @"Products?$filter=Category/CategoryName eq 'Beverages'": @[ @"Products", @"Categories" ],
    @"Products?$orderby=Category/CategoryName": @[ @"Products", @"Categories" ],
    @"Products?$compute=Category/CategoryName as Kind&$select=ProductName,Kind": @[ @"Products", @"Categories" ],
    @"Products?$filter=Suppliers/any(s:s/City eq 'London')": @[ @"Products", @"Suppliers" ],
    @"Products?$filter=Suppliers/$count gt 1": @[ @"Products", @"Suppliers" ],
    @"Products?$apply=groupby((Category/CategoryName))": @[ @"Products", @"Categories" ],
    @"Products?$apply=filter(Category/CategoryName eq 'Beverages')": @[ @"Products", @"Categories" ],
    @"Products?$expand=Category($select=CategoryName)": @[ @"Products", @"Categories" ],
    @"Products?$expand=Category/$ref": @[ @"Products", @"Categories" ],
    @"Products?$expand=*": @[ @"Products", @"Categories", @"Suppliers" ],
    @"Products?$select=ProductName": @[ @"Products" ],
    @"Products/$filter(Category/CategoryName eq 'Beverages')": @[ @"Products", @"Categories" ],
    @"Products/$count?$filter=Category/CategoryName eq 'Beverages'": @[ @"Products", @"Categories" ],
    @"Products(1)": @[ @"Products" ],
    @"Products(1)/Category": @[ @"Products", @"Categories" ],
    @"Products(1)/Category/CategoryName": @[ @"Products", @"Categories" ],
    @"Products(1)/Category/$ref": @[ @"Products", @"Categories" ],
    @"Products(1)/Suppliers": @[ @"Products", @"Suppliers" ],
    @"Categories(1)/Products?$filter=Suppliers/any(s:s/City eq 'London')": @[ @"Products", @"Categories", @"Suppliers" ],
    @"Categories?$expand=Products($filter=Suppliers/any(s:s/City eq 'London');$select=ProductName)": @[ @"Products", @"Categories", @"Suppliers" ],
  };
  NSArray *sets = [scopes.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *path in [reaches.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    OISServiceResponse *r = [self send:@"GET" path:path scopes:[[scopes allValues] componentsJoinedByString:@" "] body:nil];
    XCTAssertEqual(r.status, 200, @"%@: %@", path, r.text);
    for (NSString *set in sets) {
      NSMutableDictionary *held = [scopes mutableCopy];
      [held removeObjectForKey:set];
      r = [self send:@"GET" path:path scopes:[held.allValues componentsJoinedByString:@" "] body:nil];
      if ([reaches[path] containsObject:set]) {
        XCTAssertEqual(r.status, 403, @"%@ without %@: %@", path, scopes[set], r.text);
        XCTAssertTrue([r.text containsString:[@"read " stringByAppendingString:set]], @"%@: %@", path, r.text);
      } else {
        XCTAssertEqual(r.status, 200, @"%@ needs no %@: %@", path, scopes[set], r.text);
      }
    }
  }

  // $explain says what a plan needs.
  _service.explains = YES;
  NSString *physical = [self send:@"GET" path:@"$explain/Products?$filter=Category/CategoryName eq 'Beverages'"
                           scopes:@"Products.Read Categories.Read" body:nil].json[@"physical"];
  XCTAssertTrue([physical containsString:@"Permission to read Categories: Categories.Read\n"], @"%@", physical);
  XCTAssertTrue([physical containsString:@"Permission to read Products: Products.Read\n"], @"%@", physical);
}

// A write needs the permission of each row it makes, changes or deletes,
// all of them checked before anything is written -- not the read of what
// it writes, nor of the rows it answers with, which are its own; what else
// its answer reads ($expand) needs reading.
- (void)testScopesAreCheckedBeforeAnythingIsWritten
{
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  ODataEntitySetHandler *products = [_service handlerForEntitySet:@"Products"];
  products.readScopes = [NSSet setWithObject:@"Products.Read"];
  products.insertScopes = [NSSet setWithObject:@"Products.Add"];
  products.updateScopes = [NSSet setWithObject:@"Products.Write"];
  products.deleteScopes = [NSSet setWithObject:@"Products.Remove"];
  ODataEntitySetHandler *categories = [_service handlerForEntitySet:@"Categories"];
  categories.readScopes = [NSSet setWithObject:@"Categories.Read"];
  categories.insertScopes = [NSSet setWithObject:@"Categories.Add"];
  categories.updateScopes = [NSSet setWithObject:@"Categories.Write"];
  NSString *(^count)(NSString *) = ^NSString *(NSString *set) {
    return [self send:@"GET" path:[set stringByAppendingString:@"/$count"] scopes:@"Products.Read Categories.Read" body:nil].text;
  };
  NSString *products0 = count(@"Products"), *categories0 = count(@"Categories");

  // A deep insert: every row it makes.
  NSDictionary *tea = @{ @"CategoryName": @"Tea", @"Products": @[ @{ @"ProductName": @"Sencha" } ] };
  OISServiceResponse *r = [self send:@"POST" path:@"Categories" scopes:@"Categories.Add" body:tea];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"insert into Products"], @"%@", r.text);
  XCTAssertEqualObjects(count(@"Categories"), categories0, @"nothing made");
  XCTAssertEqualObjects(count(@"Products"), products0);
  r = [self send:@"POST" path:@"Categories" scopes:@"Categories.Add Products.Add" body:tea];
  XCTAssertEqual(r.status, 201, @"%@", r.text);
  XCTAssertEqualObjects(r.json[@"CategoryName"], @"Tea", @"what it made is its answer");
  XCTAssertNil(r.json[@"Products"], @"what it may not read is left out of what it was not asked for: %@", r.text);
  r = [self send:@"POST" path:@"Categories" scopes:@"Categories.Add Products.Add Products.Read" body:tea];
  XCTAssertEqualObjects([r.json[@"Products"] valueForKey:@"ProductName"], @[ @"Sencha" ], @"%@", r.text);
  // What it is asked to expand, it reads: before it writes.
  NSString *made = count(@"Products");
  r = [self send:@"POST" path:@"Products?$expand=Category" scopes:@"Products.Add" body:@{ @"ProductName": @"Matcha", @"Category@odata.bind": @"Categories(1)" }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertEqualObjects(count(@"Products"), made, @"nothing made");

  // An update: of the rows it changes, not a read of them.
  r = [self send:@"PATCH" path:@"Products(1)" scopes:@"Products.Read" body:@{ @"ProductName": @"Tea" }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  r = [self send:@"PATCH" path:@"Products(1)" scopes:@"Products.Write" body:@{ @"ProductName": @"Tea" }];
  XCTAssertEqual(r.status, 204, @"%@", r.text);
  r = [self send:@"PATCH" path:@"Products(1)" headers:@{ @"X-Scopes": @"Products.Write", @"Prefer": @"return=representation" }
            body:@{ @"ProductName": @"Chai" }];
  XCTAssertEqual(r.status, 200, @"its answer is what it wrote: %@", r.text);
  // A collection's, and its answer.
  r = [self send:@"PATCH" path:@"Products/$filter(ProductID le 2)/$each" headers:@{ @"X-Scopes": @"Products.Write", @"Prefer": @"return=representation" }
            body:@{ @"Discontinued": @YES }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqual([r.json[@"value"] count], 2u, @"%@", r.text);
  r = [self send:@"PATCH" path:@"Products/$filter(ProductID le 2)/$each?$expand=Category" headers:@{ @"X-Scopes": @"Products.Write" }
            body:@{ @"Discontinued": @NO }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertEqualObjects([self send:@"GET" path:@"Products(1)/Discontinued" scopes:@"Products.Read" body:nil].json[@"value"], @YES,
                        @"refused before it was written");
  // Through a navigation: the set it passes through is read.
  r = [self send:@"PATCH" path:@"Categories(1)/Products(1)" scopes:@"Products.Write" body:@{ @"ProductName": @"Chai" }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"read Categories"], @"%@", r.text);
  XCTAssertEqual([self send:@"PATCH" path:@"Categories(1)/Products(1)" scopes:@"Products.Write Categories.Read" body:@{ @"ProductName": @"Chai" }].status, 204);

  // A reference: the row whose navigation property it changes.
  r = [self send:@"PUT" path:@"Products(1)/Category/$ref" scopes:@"Categories.Write" body:@{ @"@odata.id": @"Categories(2)" }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"update Products"], @"%@", r.text);
  r = [self send:@"PUT" path:@"Products(1)/Category/$ref" scopes:@"Products.Write" body:@{ @"@odata.id": @"Categories(2)" }];
  XCTAssertEqual(r.status, 204, @"%@", r.text);
  r = [self send:@"POST" path:@"Categories(1)/Products/$ref" scopes:@"Categories.Write" body:@{ @"@odata.id": @"Products(1)" }];
  XCTAssertEqual(r.status, 204, @"its own navigation, not read: %@", r.text);

  // A delete.
  XCTAssertEqual([self send:@"DELETE" path:@"Products(7)" scopes:@"Products.Write" body:nil].status, 403);
  XCTAssertEqual([self send:@"DELETE" path:@"Products(7)" scopes:@"Products.Remove" body:nil].status, 204);

  // A change set: the request refused, and with it the change set.
  NSString *before = [self send:@"GET" path:@"Products(2)/ProductName" scopes:@"Products.Read" body:nil].json[@"value"];
  r = [self send:@"POST" path:@"$batch" headers:@{ @"X-Scopes": @"Products.Write" } body:@{ @"requests": @[
    @{ @"id": @"1", @"atomicityGroup": @"g", @"method": @"PATCH", @"url": @"Products(2)", @"body": @{ @"ProductName": @"Changed" } },
    @{ @"id": @"2", @"atomicityGroup": @"g", @"method": @"PATCH", @"url": @"Categories(1)", @"body": @{ @"CategoryName": @"Changed" } } ] }];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([self send:@"GET" path:@"Products(2)/ProductName" scopes:@"Products.Read" body:nil].json[@"value"], before,
                        @"all or nothing: %@", r.text);
}

// An open type's dynamic properties are what the caller changes too.
- (void)testScopesOfDynamicProperties
{
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  OISOpenCategoriesHandler *handler = [[OISOpenCategoriesHandler alloc] initWithEntity:OISCatalogEntity(@"Category")];
  handler.updateScopes = [NSSet setWithObject:@"Categories.Write"];
  [_service setHandler:handler forEntitySet:@"Categories"];
  OISServiceResponse *r = [self send:@"PATCH" path:@"Categories(1)" scopes:@"" body:@{ @"Mood": @"calm" }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertNil(handler.written[@1], @"not written: %@", handler.written);
  r = [self send:@"PATCH" path:@"Categories(1)" scopes:@"Categories.Write" body:@{ @"Mood": @"calm" }];
  XCTAssertTrue(r.status < 300, @"%ld %@", (long)r.status, r.text);
  XCTAssertEqualObjects(handler.written[@1][@"Mood"], @"calm");
}

// A temporal action: each slice it makes, changes or closes, checked before
// any is; what it answers with is what it wrote.
- (void)testScopesOfTemporalActions
{
  [self serveDepartmentHistory];
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  ODataEntitySetHandler *departments = [_service handlerForEntitySet:@"Departments"];
  departments.readScopes = [NSSet setWithObject:@"Departments.Read"];
  departments.insertScopes = [NSSet setWithObject:@"Departments.Add"];
  departments.updateScopes = [NSSet setWithObject:@"Departments.Write"];
  NSArray *history = [self historyOf:@"D08"];
  // Splitting slices makes some.
  NSDictionary *split = @{ @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D08", @"From": @"2012-04-01", @"To": @"2014-07-01", @"Budget": @1320 } } ] };
  OISServiceResponse *r = [self send:@"POST" path:@"Departments/Temporal.Update" scopes:@"Departments.Write" body:split];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"insert into Departments"], @"%@", r.text);
  XCTAssertEqualObjects([self historyOf:@"D08"], history, @"nothing changed");
  // One slice as it is: changed only.
  NSDictionary *within = @{ @"deltaTimeslices": @[ @{ @"Timeslice": @{ @"Department": @"D08", @"From": @"2012-01-01", @"To": @"2012-06-01", @"Budget": @1300 } } ] };
  r = [self send:@"POST" path:@"Departments/Temporal.Update" scopes:@"Departments.Write" body:within];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([[r.json[@"value"] valueForKey:@"Timeslice"] valueForKey:@"Budget"], @[ @1300 ], @"%@", r.text);
  r = [self send:@"POST" path:@"Departments/Temporal.Update" scopes:@"Departments.Write Departments.Add" body:split];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
}

// An operation's call needs its scopes; what it answers with is its own,
// what that is expanded with is read, before it is called; a bound one's
// path is read.
- (void)testScopesOfOperations
{
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  OISScopedOperations *operations = [[OISScopedOperations alloc] init];
  _service.serviceOperations = operations;
  [self readScopesOfSets:@[ @"Products", @"Categories" ]];
  XCTAssertEqualObjects(_service.operationProblems, @[]);

  XCTAssertEqual([self send:@"POST" path:@"Restock" scopes:@"Products.Read" body:@{}].status, 403);
  XCTAssertEqual(operations.calls, 0);
  OISServiceResponse *r = [self send:@"POST" path:@"Restock" scopes:@"Stock.Keep" body:@{}];
  XCTAssertEqual(r.status, 200, @"its answer is its own: %@", r.text);
  XCTAssertEqual([r.json[@"value"] count], 2u, @"%@", r.text);
  r = [self send:@"POST" path:@"Favourite" scopes:@"Stock.Keep" body:@{}];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects(r.json[@"ProductName"], @"Chai", @"%@", r.text);
  NSInteger calls = operations.calls;
  for (NSString *path in @[ @"Restock?$expand=Category", @"Favourite?$expand=Category" ]) {
    r = [self send:@"POST" path:path scopes:@"Stock.Keep" body:@{}];
    XCTAssertEqual(r.status, 403, @"%@: %@", path, r.text);
    XCTAssertTrue([r.text containsString:@"read Categories"], @"%@", r.text);
  }
  XCTAssertEqual(operations.calls, calls, @"refused before it was called");
  r = [self send:@"POST" path:@"Restock?$expand=Category" scopes:@"Stock.Keep Categories.Read" body:@{}];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertNotNil([r.json[@"value"] firstObject][@"Category"], @"%@", r.text);
  // A function's, read on from: its own too; what else is reached, read.
  r = [self send:@"GET" path:@"Bargains()?$filter=ProductName ne 'Chang'" scopes:@"Stock.Keep" body:nil];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqual([r.json[@"value"] count], 2u, @"%@", r.text);
  r = [self send:@"GET" path:@"Bargains()?$filter=Category/CategoryName eq 'Beverages'" scopes:@"Stock.Keep" body:nil];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"read Categories"], @"%@", r.text);
  r = [self send:@"GET" path:@"Bargains()?$filter=Category/CategoryName eq 'Beverages'" scopes:@"Stock.Keep Categories.Read" body:nil];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqual([self send:@"GET" path:@"Bargains()" scopes:@"Products.Read" body:nil].status, 403);

  // Bound: called on what its path reads.
  NSManagedObjectModel *model = [OISCatalogModel() conformsToProtocol:@protocol(NSCopying)]
      ? [OISCatalogModel() copy] : [[NSManagedObjectModel alloc] initWithContentsOfURL:OISCatalogModelURL()];
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  product.managedObjectClassName = @"OISScopedProduct";
  [self serveModel:model];
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  [self readScopesOfSets:@[ @"Products" ]];
  XCTAssertEqualObjects(_service.operationProblems, @[]);
  NSString *raise = @"Products(1)/Default.RaisePriceByPercent";
  XCTAssertEqual([self send:@"POST" path:raise scopes:@"Products.Read" body:@{ @"Percent": @10 }].status, 403);
  r = [self send:@"POST" path:raise scopes:@"Prices.Raise" body:@{ @"Percent": @10 }];
  XCTAssertEqual(r.status, 403, @"%@", r.text);
  XCTAssertTrue([r.text containsString:@"read Products"], @"%@", r.text);
  XCTAssertEqual([self send:@"POST" path:raise scopes:@"Prices.Raise Products.Read" body:@{ @"Percent": @10 }].status, 204);
  // $metadata says it of the overload, bound to Product.
  NSString *metadata = [self send:@"GET" path:@"$metadata" scopes:@"" body:nil].text;
  NSRange action = [metadata rangeOfString:@"<Action Name=\"RaisePriceByPercent\""];
  XCTAssertNotEqual(action.location, NSNotFound, @"%@", metadata);
  NSString *rest = action.location == NSNotFound ? @"" : [metadata substringFromIndex:action.location];
  NSString *element = [rest substringToIndex:[rest rangeOfString:@"</Action>"].location];
  XCTAssertTrue([element containsString:@"Org.OData.Capabilities.V1.OperationRestrictions"], @"%@", element);
  XCTAssertTrue([element containsString:@"Prices.Raise"], @"%@", element);
}

// Scopes that name no scope, or no operation, would leave one open: the
// operation is not served, and the problem said.
- (void)testOperationScopesThatCannotBeUsed
{
  _service.serviceOperations = [[OISMisscopedOperations alloc] init];
  NSString *problems = [_service.operationProblems componentsJoinedByString:@"\n"];
  XCTAssertEqual(_service.operationProblems.count, 2u, @"%@", problems);
  XCTAssertTrue([problems containsString:@"countWithAmount:reply:"], @"%@", problems);
  XCTAssertTrue([problems containsString:@"mesureWithAmount:reply:"], @"%@", problems);
  NSString *metadata = [self get:@"$metadata"].text;
  XCTAssertFalse([metadata containsString:@"\"CountWithAmount\""] || [metadata containsString:@"\"Count\""], @"%@", metadata);
  XCTAssertTrue([metadata containsString:@"Measure.Run"], @"%@", metadata);
}

// A refusal says which scopes would do, as RFC 6750 has it -- 403, or 401
// for no one at all -- and the client reads them back.
- (void)testScopeRefusalsNameTheScopes
{
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  [_service handlerForEntitySet:@"Products"].readScopes = [NSSet setWithObjects:@"Products.Read", @"Catalog.Admin", nil];
  [_service handlerForEntitySet:@"Products"].updateScopes = [NSSet setWithObject:@"Products.Write"];
  OISServiceResponse *r = [self send:@"GET" path:@"Products" scopes:@"Other" body:nil];
  XCTAssertEqual(r.status, 403);
  NSString *challenge = [r header:@"WWW-Authenticate"];
  XCTAssertTrue([challenge hasPrefix:@"Bearer "], @"%@", challenge);
  XCTAssertTrue([challenge containsString:@"error=\"insufficient_scope\""], @"%@", challenge);
  XCTAssertTrue([challenge containsString:@"scope=\"Catalog.Admin Products.Read\""], @"%@", challenge);

  // No one at all: 401.
  _service.authenticator = [[HSTrustedHeaderAuthenticator alloc] init];
  _service.allowsAnonymousRequests = YES;
  r = [self get:@"Products"];
  XCTAssertEqual(r.status, 401, @"%@", r.text);
  XCTAssertTrue([[r header:@"WWW-Authenticate"] containsString:@"scope=\"Catalog.Admin Products.Read\""], @"%@", [r header:@"WWW-Authenticate"]);
  XCTAssertEqual([self get:@"Categories"].status, 200, @"what needs no scope, anyone may");

  // The client: the scopes, and what to do.
  _service.authenticator = [[OISScopeAuthenticator alloc] init];
  ODataConfiguration *configuration = [[ODataConfiguration alloc] initWithURL:[NSURL URLWithString:@"http://example.test/odata/"] options:nil];
  configuration.accessToken = @"Other";
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  client.transport = _service;
  NSError *error = nil;
  XCTAssertNil([client JSONAtURL:[NSURL URLWithString:@"http://example.test/odata/Products"] error:&error]);
  XCTAssertEqualObjects(error.userInfo[ODataErrorHTTPStatusKey], @403);
  XCTAssertEqualObjects(error.userInfo[ODataErrorScopesKey], (@[ @"Catalog.Admin", @"Products.Read" ]));
  XCTAssertTrue([error.localizedDescription containsString:@"one of the scopes"], @"%@", error.localizedDescription);
  XCTAssertTrue([error.localizedRecoverySuggestion containsString:@"Catalog.Admin, Products.Read"], @"%@", error.localizedRecoverySuggestion);
  // In a change set, the request that failed.
  NSMutableURLRequest *patch = [client requestWithMethod:@"PATCH" URL:[NSURL URLWithString:@"http://example.test/odata/Products(1)"]
                                                    body:@{ @"ProductName": @"Tea" } etag:nil error:&error];
  error = nil;
  XCTAssertNil([client sendChangeSet:@[ patch ] error:&error]);
  XCTAssertEqualObjects(error.userInfo[ODataErrorScopesKey], @[ @"Products.Write" ], @"%@", error.userInfo);
}

- (void)testRestrictionsInMetadata
{
  // Everything allowed: no insert restrictions; what updates and deletes
  // take (Collection/$each after $filter(...) and cast segments, a delta
  // payload).
  NSString *allowed = [self get:@"$metadata"].text;
  XCTAssertTrue([allowed rangeOfString:@"InsertRestrictions"].location == NSNotFound, @"everything allowed");
  ODataSchema *all = [ODataSchema schemaWithData:[allowed dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
  XCTAssertEqualObjects([all annotation:@"Capabilities.UpdateRestrictions" forTarget:@"Default.Container/Products"],
                        (@{ @"FilterSegmentSupported": @YES, @"TypecastSegmentSupported": @YES, @"DeltaUpdateSupported": @YES,
                            @"Upsertable": @YES }));
  XCTAssertEqualObjects([all annotation:@"Capabilities.DeleteRestrictions" forTarget:@"Default.Container/Products"],
                        (@{ @"FilterSegmentSupported": @YES, @"TypecastSegmentSupported": @YES }));
  ODataEntitySetHandler *locations = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Location")];
  [_service setHandler:locations forEntitySet:@"Locations"];
  locations.allowsInsert = NO;
  locations.allowsDelete = NO;
  NSString *xml = [self get:@"$metadata"].text;
  XCTAssertTrue([xml rangeOfString:@"<EntitySet Name=\"Locations\" EntityType=\"Default.Location\">"].location != NSNotFound);
  ODataSchema *schema = [ODataSchema schemaWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
  XCTAssertNotNil(schema, @"still reads");
  XCTAssertEqualObjects([schema annotation:@"Capabilities.InsertRestrictions" forTarget:@"Default.Container/Locations"], @{ @"Insertable": @NO }, @"%@", xml);
  XCTAssertEqualObjects([schema annotation:@"Capabilities.DeleteRestrictions" forTarget:@"Default.Container/Locations"], @{ @"Deletable": @NO });
  XCTAssertEqualObjects([[schema annotation:@"Capabilities.UpdateRestrictions" forTarget:@"Default.Container/Locations"] objectForKey:@"FilterSegmentSupported"], @YES);
  XCTAssertEqual(([self send:@"POST" path:@"Locations" headers:nil body:@{ @"LocationName": @"Shed" }].status), 405);
}

// Employees, the cars they own and the cars they drive (ConQuer's Q5).
- (NSManagedObjectModel *)fleetModel
{
  NSEntityDescription *employee = [[NSEntityDescription alloc] init];
  employee.name = @"Employee";
  employee.managedObjectClassName = @"NSManagedObject";
  employee.userInfo = @{ @"OData.entitySet": @"Employees" };
  NSEntityDescription *car = [[NSEntityDescription alloc] init];
  car.name = @"Car";
  car.managedObjectClassName = @"NSManagedObject";
  car.userInfo = @{ @"OData.entitySet": @"Cars" };
  NSRelationshipDescription *(^many)(NSString *, NSEntityDescription *) = ^(NSString *name, NSEntityDescription *to) {
    NSRelationshipDescription *r = [[NSRelationshipDescription alloc] init];
    r.name = name;
    r.destinationEntity = to;
    r.minCount = 0;
    r.maxCount = 0;
    r.optional = YES;
    r.deleteRule = NSNullifyDeleteRule;
    return r;
  };
  NSRelationshipDescription *owns = many(@"ownsCars", car), *owners = many(@"isOwnedByEmployees", employee);
  NSRelationshipDescription *drives = many(@"cars", car), *drivers = many(@"drivers", employee);
  owns.inverseRelationship = owners;
  owners.inverseRelationship = owns;
  drives.inverseRelationship = drivers;
  drivers.inverseRelationship = drives;
  NSAttributeDescription *employeeKey = OISSwatchAttribute(@"nr", NSInteger32AttributeType, nil);
  employeeKey.optional = NO;
  employeeKey.userInfo = @{ @"OData.key": @"YES" };
  NSAttributeDescription *carKey = OISSwatchAttribute(@"nr", NSInteger32AttributeType, nil);
  carKey.optional = NO;
  carKey.userInfo = @{ @"OData.key": @"YES" };
  employee.properties = @[ employeeKey, owns, drives ];
  car.properties = @[ carKey, OISSwatchAttribute(@"name", NSStringAttributeType, nil), owners, drivers ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ employee, car ];
  return model;
}

- (void)serveFleetInStoreOfType:(NSString *)storeType
{
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self fleetModel]];
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_storeFiles addObject:url];
  }
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = _coordinator;
  [context performBlockAndWait:^{
    NSMutableDictionary *cars = [NSMutableDictionary dictionary];
    NSArray *names = @[ @"A", @"B", @"C", @"D" ];
    for (NSUInteger i = 0; i < names.count; i++) {
      cars[names[i]] = [self insert:@"Car" into:context values:@{ @"nr": @(10 + i), @"name": names[i] }];
    }
    // Employee: owns, drives. 1 drives no car it owns; 3 drives both of
    // its own; 4 drives one of its own.
    NSDictionary *fleet = @{ @1: @[ @"C", @"D" ], @3: @[ @"AB", @"AB" ], @4: @[ @"A", @"AC" ] };
    for (NSNumber *nr in fleet) {
      NSManagedObject *employee = [self insert:@"Employee" into:context values:@{ @"nr": nr }];
      NSMutableSet *own = [NSMutableSet set], *drive = [NSMutableSet set];
      for (NSString *n in names) {
        if ([fleet[nr][0] containsString:n]) [own addObject:cars[n]];
        if ([fleet[nr][1] containsString:n]) [drive addObject:cars[n]];
      }
      [employee setValue:own forKey:@"ownsCars"];
      [employee setValue:drive forKey:@"cars"];
    }
    NSError *saveError = nil;
    XCTAssertTrue([context save:&saveError], @"%@", saveError);
  }];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

- (NSArray *)employeesWhere:(NSString *)filter status:(NSInteger *)status
{
  OISServiceResponse *response = [self get:[NSString stringWithFormat:@"Employees?$filter=%@&$orderby=Nr", filter]];
  if (status) *status = response.status;
  return response.status == 200 ? [response.json[@"value"] valueForKey:@"Nr"] : nil;
}

// $apply naming what the builders refuse: a 400, as any syntax error is,
// not an exception out of the service.
- (void)testApplyWithNamesNotAllowed
{
  [self serveModel:OISCatalogModel()];
  for (NSString *apply in @[ @"groupby((1Name))", @"groupby((Category.))", @"aggregate(UnitPrice with sum as 1x)" ]) {
    OISServiceResponse *response = [self get:[@"Products?$apply=" stringByAppendingString:apply]];
    XCTAssertEqual(response.status, 400, @"%@: %@", apply, response.text);
  }
  XCTAssertEqual([self get:@"Products?$filter=Suppliers/aggregate(Amount.. with sum) gt 1"].status, 400);
  XCTAssertEqual([self get:@"Products?$apply=groupby((Category/CategoryName))"].status, 200);
}

// $count($filter=...) in $filter (OData 4.01): the members counted that
// pass, a path with no variable and $this the member's, $it the employee.
- (void)testFilteredCount
{
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType ]) {
    [self serveFleetInStoreOfType:storeType];
    NSInteger status = 0;
    // Q5: employees who own a car and do not drive more than one of the cars they own.
    NSArray *got = [self employeesWhere:@"OwnsCars/any() and not (Cars/$count($filter=IsOwnedByEmployees/any(x:x/Nr eq $it/Nr)) gt 1)" status:&status];
    XCTAssertEqualObjects(got, (@[ @1, @4 ]), @"%@: %ld", storeType, (long)status);
    // How many of the cars each drives are its own.
    XCTAssertEqualObjects([self employeesWhere:@"Cars/$count($filter=IsOwnedByEmployees/any(x:x/Nr eq $it/Nr)) eq 2" status:NULL], (@[ @3 ]), @"%@", storeType);
    XCTAssertEqualObjects([self employeesWhere:@"Cars/$count($filter=IsOwnedByEmployees/any(x:x/Nr eq $it/Nr)) eq 0" status:NULL], (@[ @1 ]), @"%@", storeType);
    // A bare path, and $this, are the car's.
    XCTAssertEqualObjects([self employeesWhere:@"Cars/$count($filter=Name eq 'A') eq 1" status:NULL], (@[ @3, @4 ]), @"%@", storeType);
    XCTAssertEqualObjects([self employeesWhere:@"Cars/$count($filter=$this/Name eq 'C' or Name eq 'D') ge 1" status:NULL], (@[ @1, @4 ]), @"%@", storeType);
    XCTAssertEqualObjects([self employeesWhere:@"Cars/$count($filter=Nr gt 10) lt Cars/$count" status:NULL], (@[ @3, @4 ]), @"%@", storeType);
    // $it is still the employee (whose Nr is 1, 3 or 4, no car's).
    XCTAssertEqualObjects([self employeesWhere:@"Cars/$count($filter=Nr eq $it/Nr) eq 0" status:NULL], (@[ @1, @3, @4 ]), @"%@", storeType);
    // Drives every car it owns: 3 (A and B), 4 (A).
    XCTAssertEqualObjects([self employeesWhere:@"OwnsCars/$count($filter=Drivers/any(d:d/Nr eq $it/Nr)) eq OwnsCars/$count" status:NULL], (@[ @3, @4 ]), @"%@", storeType);
    // Not the car's property; $search there.
    XCTAssertNil([self employeesWhere:@"Cars/$count($filter=OwnsCars/any()) gt 0" status:&status]);
    XCTAssertEqual(status, 400, @"%@", storeType);
    XCTAssertNil([self employeesWhere:@"Cars/$count($search=red) gt 0" status:&status]);
    XCTAssertEqual(status, 501, @"%@", storeType);
  }
}

@end
