// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What a call's work took: planning, execution, and each request of the
// store (a handler's, which is the store's unless it says otherwise), as
// spans under the call's and as metrics.

#import "ODataServiceInternal.h"
#import "OISPlan.h"
#import <HTTPServerKit/HSObservability.h>
#import <HTTPServerKit/HSLog.h>
#import <OTelKit/OTTrace.h>

// How long a plan's tree may be as an attribute: a collector keeps it, and
// a plan of hundreds of nodes says little more.
static const NSUInteger OISPlanAttributeLength = 4096;

static double OISSeconds(uint64_t from, uint64_t to)
{
  return to > from ? (double)(to - from) / 1e9 : 0;
}

// OpenTelemetry's db.system.name for the store a coordinator has first:
// what its type is backed by.
NSString *OISStoreSystemName(NSPersistentStoreCoordinator *coordinator)
{
  NSPersistentStore *store = coordinator.persistentStores.firstObject;
  NSString *type = store.type ?: @"";
  if ([type isEqualToString:NSSQLiteStoreType]) return @"sqlite";
  if ([type rangeOfString:@"PostgreSQL" options:NSCaseInsensitiveSearch].location != NSNotFound) return @"postgresql";
  if ([type rangeOfString:@"MySQL" options:NSCaseInsensitiveSearch].location != NSNotFound) return @"mysql";
  return @"coredata";
}

BOOL OISTimedSave(ODataService *service, NSManagedObjectContext *context, OTSpan *parent, NSString *entity, NSError **error)
{
  uint64_t started = OTNow();
  OTSpan *span = nil;
  if (parent.recording) {
    span = [service.tracer startSpanNamed:entity.length ? [@"save " stringByAppendingString:entity] : @"save" kind:OTSpanKindInternal
                                   parent:parent.context
                               attributes:@{ @"db.system.name": OISStoreSystemName(context.persistentStoreCoordinator),
                                             @"db.operation.name": @"save",
                                             @"odata.inserted": @(context.insertedObjects.count),
                                             @"odata.updated": @(context.updatedObjects.count),
                                             @"odata.deleted": @(context.deletedObjects.count) }];
    [span becomeCurrent];
  }
  NSError *failure = nil;
  BOOL saved = !service.willSave || !context.hasChanges || service.willSave(context, &failure);
  if (!saved && !failure) failure = ODataServiceError(500, @"The save was refused");
  saved = saved && [context save:&failure];
  [span resignCurrent];
  NSString *label = entity.length ? entity : @"(batch)";
  [service.metrics observeHistogram:@"odata_store_request_duration_seconds"
                               help:@"How long the store (or a handler) took to answer, by operation and entity."
                             labels:@{ @"operation": @"save", @"entity": label } value:OISSeconds(started, OTNow()) buckets:nil];
  if (!saved) {
    [service.metrics incrementCounter:@"odata_store_errors_total" help:@"Store requests that failed, by operation and entity."
                               labels:@{ @"operation": @"save", @"entity": label } by:1];
    [span recordError:failure];
  }
  [span end];
  if (error) *error = failure;
  return saved;
}

@implementation OISServiceCall (Tracing)

- (NSString *)metricsEntity
{
  return self.entity.name ?: @"(none)";
}

- (void)tracePlanned:(OISPlan *)plan
{
  uint64_t now = OTNow();
  [self traceExecuted];
  ODataService *service = self.service;
  [service.metrics observeHistogram:@"odata_plan_duration_seconds" help:@"How long requests took to read and plan, by entity."
                             labels:@{ @"entity": [self metricsEntity] } value:OISSeconds(self.phaseStarted, now) buckets:nil];
  if (self.span.recording) {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    attributes[@"odata.plan.kind"] = plan.write ? @"write" : @"read";
    NSString *tree = [plan treeDescription];
    if (tree.length > OISPlanAttributeLength) tree = [[tree substringToIndex:OISPlanAttributeLength] stringByAppendingString:@"…"];
    attributes[@"odata.plan"] = tree;
    OTSpan *planning = [service.tracer startSpanNamed:@"plan" kind:OTSpanKindInternal parent:self.span.context attributes:attributes
                                            startTime:self.phaseStarted ?: now];
    [planning endAtTime:now];
    self.executeSpan = [service.tracer startSpanNamed:@"execute" kind:OTSpanKindInternal parent:self.span.context attributes:nil
                                            startTime:now];
  }
  self.executeStarted = now;
}

- (void)traceExecuted
{
  if (!self.executeStarted) return;
  uint64_t now = OTNow();
  [self.service.metrics observeHistogram:@"odata_execution_duration_seconds"
                                    help:@"How long plans took to run, store requests included, by entity."
                                  labels:@{ @"entity": [self metricsEntity] } value:OISSeconds(self.executeStarted, now) buckets:nil];
  [self.executeSpan endAtTime:now];
  self.executeSpan = nil;
  self.executeStarted = 0;
  self.phaseStarted = now;
}

- (void)beginStoreRequest:(NSString *)operation entity:(NSString *)entity handler:(ODataEntitySetHandler *)handler
{
  self.storeOperation = operation;
  self.storeEntity = entity ?: @"(none)";
  self.storeStarted = OTNow();
  // A span whether or not it is recorded: one that is not still carries the
  // trace and its sampling, so a store that traces goes under the request
  // rather than beginning traces of its own.
  OTSpan *parent = self.executeSpan ?: self.span;
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
  attributes[@"db.system.name"] = OISStoreSystemName(self.request.context.persistentStoreCoordinator);
  attributes[@"db.operation.name"] = operation;
  attributes[@"db.collection.name"] = self.storeEntity;
  if (handler) attributes[@"code.namespace"] = NSStringFromClass([handler class]);
  OTSpan *span = [self.service.tracer startSpanNamed:[NSString stringWithFormat:@"%@ %@", operation, self.storeEntity]
                                                kind:OTSpanKindInternal parent:parent.context attributes:attributes];
  // Current while the handler asks the store on this thread, so a store
  // that traces (FreeCoreData) puts its spans under it.
  [span becomeCurrent];
  self.storeSpan = span;
}

- (void)endStoreRequest:(id)result error:(NSError *)error
{
  if (!self.storeStarted) return;
  ODataService *service = self.service;
  NSDictionary *labels = @{ @"operation": self.storeOperation ?: @"fetch", @"entity": self.storeEntity ?: @"(none)" };
  [service.metrics observeHistogram:@"odata_store_request_duration_seconds"
                               help:@"How long the store (or a handler) took to answer, by operation and entity."
                             labels:labels value:OISSeconds(self.storeStarted, OTNow()) buckets:nil];
  OTSpan *span = self.storeSpan;
  if (error) {
    [service.metrics incrementCounter:@"odata_store_errors_total" help:@"Store requests that failed, by operation and entity." labels:labels by:1];
    [span recordError:error];
  } else if ([result isKindOfClass:[NSArray class]]) {
    NSUInteger rows = [(NSArray *)result count];
    [service.metrics incrementCounter:@"odata_store_rows_total" help:@"Rows the store answered with, by entity."
                               labels:@{ @"entity": labels[@"entity"] } by:rows];
    [span setAttribute:@(rows) forKey:@"db.response.returned_rows"];
  } else if ([result isKindOfClass:[NSNumber class]] && [labels[@"operation"] isEqualToString:@"count"]) {
    [span setAttribute:result forKey:@"odata.count"];
  }
  [span end];
  self.storeSpan = nil;
  self.storeStarted = 0;
}

- (void)beginOperationCall:(OISServedOperation *)operation target:(id)target
{
  // Made and current even when it is not recorded (an unsampled request):
  // what the operation traces then follows the request's choice, and its
  // own calls carry the trace on, rather than beginning traces of their own.
  OTSpan *parent = self.executeSpan ?: self.span;
  // An instance's class, or a class itself (+class answers itself).
  Class owner = [target class];
  OTSpan *span = [self.service.tracer startSpanNamed:[@"call " stringByAppendingString:operation.name ?: @"?"]
                                                kind:OTSpanKindInternal parent:parent.context
                                          attributes:@{ @"code.namespace": NSStringFromClass(owner),
                                                        @"code.function": NSStringFromSelector(operation.selector) }];
  [span becomeCurrent];
  self.callSpan = span;
}

- (void)endOperationCall:(NSError *)error
{
  OTSpan *span = self.callSpan;
  if (!span) return;
  if (error) [span recordError:error];
  [span end];
  self.callSpan = nil;
}

- (void)traceRespondedWithStatus:(NSInteger)status
{
  [self traceExecuted];
  [self endStoreRequest:nil error:nil];
  // Answered with the call still open (an action's save that failed, a
  // reply that timed out): the call failed too.
  if (status >= 400) [self.callSpan setStatus:OTStatusError message:nil];
  [self endOperationCall:nil];
  OTSpan *span = self.span;
  if (!span) return;
  [span setAttribute:@(status) forKey:@"http.response.status_code"];
  if (status >= 500) {
    [span setAttribute:[NSString stringWithFormat:@"%ld", (long)status] forKey:@"error.type"];
    [span setStatus:OTStatusError message:nil];
  }
  [span end];
  self.span = nil;
}

@end
