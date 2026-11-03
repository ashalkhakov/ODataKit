// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBTraces.h"

NSString * const WBTracesDidChangeNotification = @"WBTracesDidChange";

#pragma mark - Traces

@interface WBTrace ()
- (instancetype)initWithTraceID:(NSString *)traceID;
- (void)addSpan:(OTSpan *)span;
@end

@implementation WBTrace {
  NSMutableArray<OTSpan *> *_spans;
}

- (instancetype)initWithTraceID:(NSString *)traceID
{
  self = [super init];
  if (!self) return nil;
  _traceID = [traceID copy];
  _spans = [NSMutableArray array];
  return self;
}

- (void)addSpan:(OTSpan *)span
{
  @synchronized (self) {
    [_spans addObject:span];
  }
}

- (NSArray<OTSpan *> *)spans
{
  @synchronized (self) {
    return [_spans copy];
  }
}

- (OTSpan *)root
{
  NSArray<OTSpan *> *spans = self.spans;
  NSSet *ids = [NSSet setWithArray:[spans valueForKeyPath:@"context.spanID"]];
  OTSpan *root = nil;
  for (OTSpan *span in spans) {
    if (span.parentSpanID && [ids containsObject:span.parentSpanID]) continue;
    if (!root || span.startTime < root.startTime) root = span;
  }
  return root;
}

- (uint64_t)startTime
{
  uint64_t start = UINT64_MAX;
  for (OTSpan *span in self.spans) start = MIN(start, span.startTime);
  return start == UINT64_MAX ? 0 : start;
}

- (uint64_t)endTime
{
  uint64_t end = 0;
  for (OTSpan *span in self.spans) end = MAX(end, span.endTime);
  return end;
}

@end

@implementation WBTraceRecorder {
  NSMutableArray<WBTrace *> *_traces;  // newest first
  NSMutableDictionary<NSString *, WBTrace *> *_byID;
  BOOL _notifying;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _limit = 200;
  _traces = [NSMutableArray array];
  _byID = [NSMutableDictionary dictionary];
  return self;
}

- (BOOL)exportSpans:(NSArray<OTSpan *> *)spans error:(NSError **)error
{
  @synchronized (self) {
    for (OTSpan *span in spans) {
      NSString *traceID = span.context.traceID;
      WBTrace *trace = _byID[traceID];
      if (!trace) {
        trace = [[WBTrace alloc] initWithTraceID:traceID];
        _byID[traceID] = trace;
        [_traces insertObject:trace atIndex:0];
        while (_traces.count > _limit) {
          [_byID removeObjectForKey:_traces.lastObject.traceID];
          [_traces removeLastObject];
        }
      }
      [trace addSpan:span];
    }
    if (_notifying) return YES;
    _notifying = YES;
  }
  // Spans end in bursts (a fetch's dozen): one notice for the lot.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    @synchronized (self) {
      self->_notifying = NO;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:WBTracesDidChangeNotification object:self];
  });
  return YES;
}

- (NSArray<WBTrace *> *)traces
{
  @synchronized (self) {
    return [_traces copy];
  }
}

- (WBTrace *)traceWithID:(NSString *)traceID
{
  @synchronized (self) {
    return traceID ? _byID[traceID] : nil;
  }
}

- (void)clear
{
  @synchronized (self) {
    [_traces removeAllObjects];
    [_byID removeAllObjects];
  }
  [[NSNotificationCenter defaultCenter] postNotificationName:WBTracesDidChangeNotification object:self];
}

@end

#pragma mark - The provider

// Each ended span to every processor.
@interface WBSpanProcessors : NSObject <OTSpanProcessor>
@property (nonatomic, copy) NSArray<id<OTSpanProcessor>> *processors;
@end

@implementation WBSpanProcessors
- (void)spanDidEnd:(OTSpan *)span
{
  for (id<OTSpanProcessor> processor in self.processors) [processor spanDidEnd:span];
}
- (BOOL)forceFlushWithTimeout:(NSTimeInterval)timeout
{
  BOOL flushed = YES;
  for (id<OTSpanProcessor> processor in self.processors) flushed = [processor forceFlushWithTimeout:timeout] && flushed;
  return flushed;
}
- (void)shutdownWithTimeout:(NSTimeInterval)timeout
{
  for (id<OTSpanProcessor> processor in self.processors) [processor shutdownWithTimeout:timeout];
}
@end

OTTracerProvider *WBTracerProvider(WBTraceRecorder *recorder)
{
  NSMutableArray *processors = [NSMutableArray arrayWithObject:[[OTSimpleSpanProcessor alloc] initWithExporter:recorder]];
  NSDictionary *resource = @{ @"service.name": @"Workbench" };
  NSError *error = nil;
  OTTracerProvider *collector = [OTTracerProvider providerWithEnvironment:[NSProcessInfo processInfo].environment
                                                                  defaults:resource error:&error];
  if (error) NSLog(@"Workbench: traces are not sent: %@", error.localizedDescription);
  if (collector.processor) {
    [processors addObject:collector.processor];
    resource = collector.resource;
  }
  WBSpanProcessors *all = [[WBSpanProcessors alloc] init];
  all.processors = processors;
  // Every trace kept here, whatever a collector would sample.
  return [[OTTracerProvider alloc] initWithResource:resource sampler:[[OTRatioSampler alloc] initWithRatio:1] processor:all];
}

NSString *WBTraceIDOfHeaders(NSDictionary<NSString *, NSString *> *headers)
{
  return [OTSpanContext contextWithHeaders:headers].traceID;
}

NSString *WBSpanIDOfHeaders(NSDictionary<NSString *, NSString *> *headers)
{
  return [OTSpanContext contextWithHeaders:headers].spanID;
}

#pragma mark - The window

// A span in the tree, with its children by when they began.
@interface WBSpanNode : NSObject
@property (nonatomic, strong) OTSpan *span;
@property (nonatomic, strong) NSMutableArray<WBSpanNode *> *children;
@end

@implementation WBSpanNode
@end

static NSString *WBMilliseconds(uint64_t nanos)
{
  double ms = (double)nanos / 1e6;
  return ms < 10 ? [NSString stringWithFormat:@"%.2f", ms] : [NSString stringWithFormat:@"%.1f", ms];
}

static NSString *WBKindName(OTSpanKind kind)
{
  switch (kind) {
    case OTSpanKindInternal: return @"internal";
    case OTSpanKindServer: return @"server";
    case OTSpanKindClient: return @"client";
    case OTSpanKindProducer: return @"producer";
    case OTSpanKindConsumer: return @"consumer";
  }
  return @"internal";
}

@interface WBTracesViewController ()
@property (nonatomic, readwrite, weak) IBOutlet NSTableView *traceTable;
@property (nonatomic, readwrite, weak) IBOutlet NSOutlineView *spanOutline;
@property (nonatomic, readwrite, strong) IBOutlet NSTextView *detailView;
@end

@implementation WBTracesViewController {
  NSArray<WBTrace *> *_traces;       // as the table shows them
  WBTrace *_shown;                   // the one the tree is of
  NSArray<WBSpanNode *> *_roots;
  uint64_t _shownStart;
}

- (instancetype)initWithRecorder:(WBTraceRecorder *)recorder
{
  self = [super initWithNibName:@"WBTraces" bundle:[NSBundle bundleForClass:[WBTracesViewController class]]];
  if (!self) return nil;
  _recorder = recorder;
  _traces = @[];
  _roots = @[];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tracesChanged:) name:WBTracesDidChangeNotification
                                             object:recorder];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// gnustep-gui has no -viewDidLoad: the view's parts set up as it loads.
- (void)loadView
{
  [super loadView];
  _detailView.font = [NSFont userFixedPitchFontOfSize:11];
  _detailView.textContainer.widthTracksTextView = YES;
  [(NSSplitView *)self.view setPosition:380 ofDividerAtIndex:0];
  NSSplitView *down = (NSSplitView *)[[(NSSplitView *)self.view subviews] lastObject];
  if ([down isKindOfClass:[NSSplitView class]]) [down setPosition:380 ofDividerAtIndex:0];
  [self showDetailOf:nil];
  [self reloadTraces];
}

// Whether it is shown, and so kept up.
- (BOOL)isShowing
{
  return self.isViewLoaded && self.view.window != nil && self.view.window.isVisible;
}

- (void)tracesChanged:(NSNotification *)notification
{
  if (![self isShowing]) return;
  [self reloadTraces];
  // The trace shown may have more spans now (a reply that came later).
  if (_shown) [self showTree:_shown keepingSelection:YES];
}

- (void)reloadTraces
{
  WBTrace *selected = _shown;
  _traces = _recorder.traces;
  [_traceTable reloadData];
  NSUInteger row = selected ? [_traces indexOfObjectIdenticalTo:selected] : NSNotFound;
  if (row != NSNotFound) {
    [_traceTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  } else if (selected) {
    _shown = nil;
    [self showTree:nil keepingSelection:NO];
  }
}

- (BOOL)showTraceWithID:(NSString *)traceID spanID:(NSString *)spanID
{
  [self view];
  [self reloadTraces];
  WBTrace *trace = [_recorder traceWithID:traceID];
  NSUInteger row = trace ? [_traces indexOfObjectIdenticalTo:trace] : NSNotFound;
  if (row == NSNotFound) return NO;
  [_traceTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  [_traceTable scrollRowToVisible:(NSInteger)row];
  [self showTree:trace keepingSelection:NO];
  WBSpanNode *node = spanID ? [self nodeWithSpanID:spanID in:_roots] : nil;
  if (node) {
    NSInteger at = [_spanOutline rowForItem:node];
    if (at >= 0) {
      [_spanOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)at] byExtendingSelection:NO];
      [_spanOutline scrollRowToVisible:at];
    }
  }
  return YES;
}

- (WBSpanNode *)nodeWithSpanID:(NSString *)spanID in:(NSArray<WBSpanNode *> *)nodes
{
  for (WBSpanNode *node in nodes) {
    if ([node.span.context.spanID isEqualToString:spanID]) return node;
    WBSpanNode *found = [self nodeWithSpanID:spanID in:node.children];
    if (found) return found;
  }
  return nil;
}

// The trace's spans as a tree: under their parents, by when they began; a
// span whose parent is elsewhere (another process's) at the top.
- (void)showTree:(WBTrace *)trace keepingSelection:(BOOL)keep
{
  NSString *selectedID = nil;
  if (keep) {
    WBSpanNode *selected = [_spanOutline itemAtRow:_spanOutline.selectedRow];
    selectedID = selected.span.context.spanID;
  }
  _shown = trace;
  NSArray<OTSpan *> *spans = [trace.spans sortedArrayUsingComparator:^NSComparisonResult(OTSpan *a, OTSpan *b) {
    return a.startTime < b.startTime ? NSOrderedAscending : a.startTime > b.startTime ? NSOrderedDescending : NSOrderedSame;
  }];
  NSMutableDictionary<NSString *, WBSpanNode *> *nodes = [NSMutableDictionary dictionary];
  for (OTSpan *span in spans) {
    WBSpanNode *node = [[WBSpanNode alloc] init];
    node.span = span;
    node.children = [NSMutableArray array];
    nodes[span.context.spanID] = node;
  }
  NSMutableArray *roots = [NSMutableArray array];
  for (OTSpan *span in spans) {
    WBSpanNode *parent = span.parentSpanID ? nodes[span.parentSpanID] : nil;
    [parent ? parent.children : roots addObject:nodes[span.context.spanID]];
  }
  _roots = roots;
  _shownStart = trace.startTime;
  [_spanOutline reloadData];
  // Each top span, and all under it (GNUstep does not take nil for all).
  for (WBSpanNode *root in _roots) [_spanOutline expandItem:root expandChildren:YES];
  WBSpanNode *again = selectedID ? [self nodeWithSpanID:selectedID in:_roots] : nil;
  NSInteger row = again ? [_spanOutline rowForItem:again] : -1;
  if (row >= 0) {
    [_spanOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
  } else {
    [self showDetailOf:nil];
  }
  if (_shownTraceChanged) _shownTraceChanged(trace);
}

- (void)showDetailOf:(OTSpan *)span
{
  if (!span) {
    _detailView.string = _shown ? @"Choose a span." : @"Choose a trace.";
    return;
  }
  NSMutableString *text = [NSMutableString string];
  [text appendFormat:@"%@\n\n", span.name];
  [text appendFormat:@"kind      %@\n", WBKindName(span.kind)];
  [text appendFormat:@"library   %@%@\n", span.scopeName, span.scopeVersion.length ? [@" " stringByAppendingString:span.scopeVersion] : @""];
  [text appendFormat:@"trace     %@\n", span.context.traceID];
  [text appendFormat:@"span      %@\n", span.context.spanID];
  if (span.parentSpanID) [text appendFormat:@"parent    %@\n", span.parentSpanID];
  [text appendFormat:@"started   +%@ ms\n", WBMilliseconds(span.startTime - _shownStart)];
  [text appendFormat:@"took      %@ ms\n", WBMilliseconds(span.endTime - span.startTime)];
  if (span.status == OTStatusError) [text appendFormat:@"status    error%@%@\n", span.statusMessage ? @": " : @"", span.statusMessage ?: @""];
  if (span.status == OTStatusOK) [text appendString:@"status    ok\n"];
  NSDictionary *attributes = span.attributes;
  NSMutableArray *multiline = [NSMutableArray array];
  if (attributes.count) [text appendString:@"\nattributes\n"];
  for (NSString *key in [attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *value = [attributes[key] description];
    // A URL as it reads, not as it is encoded.
    if ([key hasPrefix:@"url."]) value = [value stringByRemovingPercentEncoding] ?: value;
    // A long one (a plan's tree) after the rest, as it is.
    if ([value rangeOfString:@"\n"].location != NSNotFound) {
      [multiline addObject:key];
      continue;
    }
    [text appendFormat:@"  %@ = %@\n", key, value];
  }
  for (NSDictionary *event in span.events) {
    uint64_t at = [event[@"time"] unsignedLongLongValue];
    [text appendFormat:@"\nevent %@ at +%@ ms\n", event[@"name"], WBMilliseconds(at > _shownStart ? at - _shownStart : 0)];
    NSDictionary *eventAttributes = event[@"attributes"];
    for (NSString *key in [[eventAttributes allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      [text appendFormat:@"  %@ = %@\n", key, eventAttributes[key]];
    }
  }
  for (NSString *key in multiline) [text appendFormat:@"\n%@\n%@\n", key, attributes[key]];
  _detailView.string = text;
  [_detailView scrollRangeToVisible:NSMakeRange(0, 0)];
}

#pragma mark Traces table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  return (NSInteger)_traces.count;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _traces.count) return nil;
  WBTrace *trace = _traces[(NSUInteger)row];
  NSString *identifier = column.identifier;
  if ([identifier isEqualToString:@"time"]) {
    static NSDateFormatter *format;
    if (!format) {
      format = [[NSDateFormatter alloc] init];
      format.dateFormat = @"HH:mm:ss.SSS";
    }
    return [format stringFromDate:[NSDate dateWithTimeIntervalSince1970:(double)trace.startTime / 1e9]];
  }
  if ([identifier isEqualToString:@"name"]) return trace.root.name ?: @"";
  if ([identifier isEqualToString:@"ms"]) return WBMilliseconds(trace.endTime - trace.startTime);
  return [NSString stringWithFormat:@"%lu", (unsigned long)trace.spans.count];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  NSInteger row = _traceTable.selectedRow;
  WBTrace *trace = row >= 0 && (NSUInteger)row < _traces.count ? _traces[(NSUInteger)row] : nil;
  if (trace != _shown) [self showTree:trace keepingSelection:NO];
}

#pragma mark Span tree

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item
{
  return (NSInteger)(item ? [(WBSpanNode *)item children] : _roots).count;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item
{
  return (item ? [(WBSpanNode *)item children] : _roots)[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item
{
  return [(WBSpanNode *)item children].count > 0;
}

- (id)outlineView:(NSOutlineView *)outline objectValueForTableColumn:(NSTableColumn *)column byItem:(id)item
{
  OTSpan *span = [(WBSpanNode *)item span];
  NSString *identifier = column.identifier;
  if ([identifier isEqualToString:@"name"]) {
    return span.status == OTStatusError ? [span.name stringByAppendingString:@"  ⚠︎"] : span.name;
  }
  if ([identifier isEqualToString:@"start"]) return WBMilliseconds(span.startTime > _shownStart ? span.startTime - _shownStart : 0);
  if ([identifier isEqualToString:@"duration"]) return WBMilliseconds(span.endTime - span.startTime);
  return span.scopeName;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
  WBSpanNode *node = [_spanOutline itemAtRow:_spanOutline.selectedRow];
  [self showDetailOf:node.span];
}

@end

@interface WBTraceWindow ()
@property (nonatomic, readwrite, strong) IBOutlet NSWindow *window;
@end

@implementation WBTraceWindow

- (instancetype)initWithRecorder:(WBTraceRecorder *)recorder
{
  self = [super init];
  if (!self) return nil;
  NSNib *nib = [[NSNib alloc] initWithNibNamed:@"WBTraceWindow" bundle:[NSBundle bundleForClass:[WBTraceWindow class]]];
  NSArray *objects = nil;
  if (![nib instantiateWithOwner:self topLevelObjects:&objects] || !_window) return nil;
  _tracesController = [[WBTracesViewController alloc] initWithRecorder:recorder];
  NSView *content = _window.contentView, *traces = _tracesController.view;
  traces.frame = content.bounds;
  traces.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:traces];
  __weak NSWindow *window = _window;
  _tracesController.shownTraceChanged = ^(WBTrace *trace) {
    window.title = trace ? [NSString stringWithFormat:@"Traces — %@ (%@)", trace.root.name ?: @"", trace.traceID] : @"Traces";
  };
  return self;
}

- (NSTableView *)traceTable
{
  return _tracesController.traceTable;
}

- (NSOutlineView *)spanOutline
{
  return _tracesController.spanOutline;
}

- (NSTextView *)detailView
{
  return _tracesController.detailView;
}

- (void)show
{
  [_tracesController reloadTraces];
  [_window makeKeyAndOrderFront:nil];
}

- (BOOL)showTraceWithID:(NSString *)traceID spanID:(NSString *)spanID
{
  if (!_window.isVisible) [_window orderFront:nil];
  return [_tracesController showTraceWithID:traceID spanID:spanID];
}

@end
