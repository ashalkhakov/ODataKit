// ODataService — application time: timeline entity sets.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Periods are handled closed-open, with nil for no end: a closed-closed
// end (the last day) is one day more on the way in, one day less on the
// way out. The actions follow OData-Temporal section 4.3.2, as SQL's
// UPDATE and DELETE ... FOR PORTION OF do.

#import "ODataTimeline.h"
#import "ODataError.h"
#import "ODataValue.h"

static NSString * const OISTemporal = @"Org.OData.Temporal.V1";
static const NSTimeInterval OISDay = 86400;

@interface OISSliceRecord ()
@property (nonatomic, readwrite) BOOL isNew;
@property (nonatomic, readwrite) BOOL isDeleted;
@end

@implementation OISSliceRecord {
  NSMutableDictionary *_values;
  NSMutableDictionary *_changes;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _values = [NSMutableDictionary dictionary];
  _changes = [NSMutableDictionary dictionary];
  return self;
}

- (NSMutableDictionary *)values
{
  return _values;
}

- (NSMutableDictionary *)changes
{
  return _changes;
}

- (id)valueForKey:(NSString *)key
{
  id value = _values[key];
  return value == [NSNull null] ? nil : value;
}

@end

@implementation OISTimeslice
- (NSManagedObject *)object
{
  return self.record.object;
}
@end

@implementation OISTimelineChanges
@end

// An action at work: the records of the slices, and the ones it has
// touched, in order.
@interface OISTimelineWork : NSObject
@property (nonatomic, strong) NSMutableArray<OISSliceRecord *> *touched;
@end

@implementation OISTimelineWork
@end

// 9999-12-31, midnight UTC: what an end that must be given is for no end.
static NSDate *OISLastDay(void)
{
  static NSDate *last;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = 9999;
    parts.month = 12;
    parts.day = 31;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    last = [calendar dateFromComponents:parts];
  });
  return last;
}

// a < b, with nil the end of time.
static BOOL OISBefore(NSDate *a, NSDate *b)
{
  if (!a) return NO;
  if (!b) return YES;
  return [a compare:b] == NSOrderedAscending;
}

@interface OISTimeline ()
@property (nonatomic, strong) NSEntityDescription *entity;
@property (nonatomic, strong) ODataPropertyMapper *mapper;
@property (nonatomic, strong, readwrite) NSAttributeDescription *startAttribute;
@property (nonatomic, strong, readwrite) NSAttributeDescription *endAttribute;
@property (nonatomic, copy, readwrite) NSArray<NSAttributeDescription *> *objectKey;
@property (nonatomic, readwrite) BOOL isDate;
@property (nonatomic, readwrite) BOOL closedClosed;
@end

@implementation OISTimeline

+ (instancetype)timelineOfEntity:(NSEntityDescription *)entity mapper:(ODataPropertyMapper *)mapper
{
  // The root's: a derived type's slices are the set's.
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  NSDictionary *userInfo = root.userInfo;
  NSAttributeDescription *start = root.attributesByName[userInfo[ODataUserInfoPeriodStart]];
  NSAttributeDescription *end = root.attributesByName[userInfo[ODataUserInfoPeriodEnd]];
  if (start.attributeType != NSDateAttributeType || end.attributeType != NSDateAttributeType) return nil;
  // A period the service does not serve is no timeline a client can see.
  if (![mapper servesProperty:start] || ![mapper servesProperty:end]) return nil;
  NSMutableArray *objectKey = [NSMutableArray array];
  for (NSString *name in [userInfo[ODataUserInfoObjectKey] componentsSeparatedByString:@","]) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!trimmed.length) continue;
    NSAttributeDescription *attribute = root.attributesByName[trimmed];
    if (!attribute || ![mapper servesProperty:attribute]) return nil;
    [objectKey addObject:attribute];
  }
  OISTimeline *timeline = [[self alloc] init];
  timeline.entity = root;
  timeline.mapper = mapper;
  timeline.startAttribute = start;
  timeline.endAttribute = end;
  timeline.objectKey = objectKey;
  timeline.isDate = [[mapper.values typeNameOfAttribute:start] isEqualToString:@"Edm.Date"];
  id closed = userInfo[ODataUserInfoClosedClosedPeriods];
  timeline.closedClosed = timeline.isDate && ([closed isEqual:@"YES"] || [closed isEqual:@YES]);
  return timeline;
}

- (NSDictionary *)applicationTimeSupport
{
  NSDictionary *unit = self.isDate
      ? @{ @"@type": [OISTemporal stringByAppendingString:@".UnitOfTimeDate"], @"ClosedClosedPeriods": @(self.closedClosed) }
      : @{ @"@type": [OISTemporal stringByAppendingString:@".UnitOfTimeDateTimeOffset"], @"Precision": @0 };
  NSMutableArray *objectKey = [NSMutableArray array];
  for (NSAttributeDescription *attribute in self.objectKey) [objectKey addObject:@{ @"$PropertyPath": [self.mapper propertyForAttribute:attribute] }];
  NSMutableArray *actions = [NSMutableArray array];
  for (NSString *action in @[ @"Update", @"Upsert", @"Delete" ]) [actions addObject:[NSString stringWithFormat:@"%@.%@", OISTemporal, action]];
  return @{ @"UnitOfTime": unit,
            @"Timeline": @{ @"@type": [OISTemporal stringByAppendingString:@".TimelineVisible"],
                            @"PeriodStart": @{ @"$PropertyPath": [self.mapper propertyForAttribute:self.startAttribute] },
                            @"PeriodEnd": @{ @"$PropertyPath": [self.mapper propertyForAttribute:self.endAttribute] },
                            @"ObjectKey": objectKey },
            @"SupportedActions": actions };
}

- (ODataExpression *)filterFrom:(ODataExpression *)from to:(ODataExpression *)to inclusive:(BOOL)inclusive error:(NSError **)error
{
  ODataExpression *start = [ODataExpression member:[self.mapper propertyForAttribute:self.startAttribute] of:nil error:error];
  ODataExpression *end = [ODataExpression member:[self.mapper propertyForAttribute:self.endAttribute] of:nil error:error];
  // The slice ends after the interval begins (or has no end) ...
  ODataExpression *after = [ODataExpression binary:self.closedClosed ? @"ge" : @"gt" left:end right:from error:error];
  if (self.endAttribute.isOptional) {
    ODataExpression *open = [ODataExpression binary:@"eq" left:end right:[ODataExpression literalWithValue:[NSNull null]] error:error];
    after = [ODataExpression binary:@"or" left:after right:open error:error];
  }
  if (!to) return after;
  // ... and begins before it ends.
  ODataExpression *before = [ODataExpression binary:inclusive ? @"le" : @"lt" left:start right:to error:error];
  return [ODataExpression binary:@"and" left:before right:after error:error];
}

#pragma mark Periods

- (NSDate *)startOf:(id)slice
{
  return [slice valueForKey:self.startAttribute.name];
}

- (NSDate *)endOf:(id)slice
{
  return [self endFromStored:[slice valueForKey:self.endAttribute.name]];
}

- (NSDate *)endFromStored:(id)stored
{
  if (![stored isKindOfClass:[NSDate class]] || [stored compare:OISLastDay()] != NSOrderedAscending) return nil;
  return self.closedClosed ? [stored dateByAddingTimeInterval:OISDay] : stored;
}

- (id)storedEnd:(NSDate *)end
{
  if (!end) return self.endAttribute.isOptional ? [NSNull null] : OISLastDay();
  return self.closedClosed ? [end dateByAddingTimeInterval:-OISDay] : end;
}

// A slice's period as values to write.
- (NSMutableDictionary *)periodStart:(NSDate *)start end:(NSDate *)end
{
  return [@{ self.startAttribute.name: start, self.endAttribute.name: [self storedEnd:end] } mutableCopy];
}

// Another slice like this one, for another period: its values but its key.
- (NSMutableDictionary *)valuesOf:(OISSliceRecord *)slice
{
  NSMutableDictionary *values = [slice.values mutableCopy];
  [values removeObjectsForKeys:[[self.mapper keyAttributesForEntity:self.entity] valueForKey:@"name"]];
  return values;
}

// A slice given, as a record: its attributes and to-one relationships.
- (OISSliceRecord *)recordOf:(NSManagedObject *)slice
{
  OISSliceRecord *record = [[OISSliceRecord alloc] init];
  record.entity = slice.entity;
  record.object = slice;
  Class derived = NSClassFromString(@"NSDerivedAttributeDescription");
  for (NSString *name in slice.entity.attributesByName) {
    NSAttributeDescription *attribute = slice.entity.attributesByName[name];
    if (attribute.isTransient || (derived && [attribute isKindOfClass:derived])) continue;
    id value = [slice valueForKey:name];
    if (value) record.values[name] = value;
  }
  for (NSString *name in slice.entity.relationshipsByName) {
    NSRelationshipDescription *relationship = slice.entity.relationshipsByName[name];
    if (relationship.isToMany) continue;
    id value = [slice valueForKey:name];
    if (value) record.values[name] = value;
  }
  return record;
}

- (OISSliceRecord *)insertValues:(NSDictionary *)values entity:(NSEntityDescription *)entity work:(OISTimelineWork *)work
{
  OISSliceRecord *record = [[OISSliceRecord alloc] init];
  record.entity = entity;
  record.isNew = YES;
  [record.values addEntriesFromDictionary:values];
  [work.touched addObject:record];
  return record;
}

- (void)update:(OISSliceRecord *)record values:(NSDictionary *)values work:(OISTimelineWork *)work
{
  [record.values addEntriesFromDictionary:values];
  if (record.isNew) return;
  [record.changes addEntriesFromDictionary:values];
  if (![work.touched containsObject:record]) [work.touched addObject:record];
}

- (void)delete:(OISSliceRecord *)record work:(OISTimelineWork *)work
{
  record.isDeleted = YES;
  // One made and taken away again is not written at all.
  if (record.isNew) [work.touched removeObject:record];
  else if (![work.touched containsObject:record]) [work.touched addObject:record];
}

- (OISSliceRecord *)copyOf:(OISSliceRecord *)slice start:(NSDate *)start end:(NSDate *)end work:(OISTimelineWork *)work
{
  NSMutableDictionary *values = [self valuesOf:slice];
  values[self.startAttribute.name] = start;
  id stored = [self storedEnd:end];
  if (stored == [NSNull null]) [values removeObjectForKey:self.endAttribute.name];
  else values[self.endAttribute.name] = stored;
  return [self insertValues:values entity:slice.entity work:work];
}

#pragma mark Actions

- (BOOL)slice:(id)slice hasObjectKeyOf:(NSDictionary *)delta
{
  for (NSAttributeDescription *attribute in self.objectKey) {
    id wanted = delta[attribute.name];
    if (wanted && ![[slice valueForKey:attribute.name] isEqual:wanted]) return NO;
  }
  return YES;
}

- (NSArray *)objectKeyOf:(id)slice
{
  NSMutableArray *key = [NSMutableArray array];
  for (NSAttributeDescription *attribute in self.objectKey) [key addObject:[slice valueForKey:attribute.name] ?: [NSNull null]];
  return key;
}

- (OISTimelineChanges *)changesOf:(NSString *)action deltas:(NSArray *)deltas candidates:(NSArray *)candidates error:(NSError **)error
{
  BOOL upsert = [action isEqualToString:@"Upsert"];
  BOOL delete = [action isEqualToString:@"Delete"];
  OISTimelineWork *work = [[OISTimelineWork alloc] init];
  work.touched = [NSMutableArray array];
  NSMutableArray *slices = [NSMutableArray array];
  for (NSManagedObject *candidate in candidates) [slices addObject:[self recordOf:candidate]];
  NSMutableArray *results = [NSMutableArray array];
  NSSet *keys = [NSSet setWithArray:[[self.mapper keyAttributesForEntity:self.entity] valueForKey:@"name"]];
  for (NSDictionary *delta in deltas) {
    NSDate *from = [delta[self.startAttribute.name] isKindOfClass:[NSDate class]] ? delta[self.startAttribute.name] : nil;
    NSDate *to = [self endFromStored:delta[self.endAttribute.name]];
    if (!from) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"A delta time slice has its %@", [self.mapper propertyForAttribute:self.startAttribute]]);
      return nil;
    }
    if (!OISBefore(from, to)) {
      if (error) *error = ODataServiceError(400, @"A delta time slice's period ends after it starts");
      return nil;
    }
    // What changes: the rest of the delta, not its period or keys.
    NSMutableDictionary *changes = [delta mutableCopy];
    [changes removeObjectsForKeys:@[ self.startAttribute.name, self.endAttribute.name ]];
    [changes removeObjectsForKeys:keys.allObjects];

    // The slices of its objects whose periods overlap its own, in order.
    NSMutableArray *selected = [NSMutableArray array];
    for (OISSliceRecord *slice in slices) {
      if (![self slice:slice hasObjectKeyOf:delta]) continue;
      if (OISBefore([self startOf:slice], to) && OISBefore(from, [self endOf:slice])) [selected addObject:slice];
    }
    [selected sortUsingComparator:^NSComparisonResult(OISSliceRecord *a, OISSliceRecord *b) {
      return [[self startOf:a] compare:[self startOf:b]];
    }];

    if (delete) {
      for (OISSliceRecord *slice in selected) {
        NSDate *start = [self startOf:slice], *end = [self endOf:slice];
        NSMutableDictionary *taken = [self valuesOf:slice];
        NSDate *takenStart = OISBefore(start, from) ? from : start;
        NSDate *takenEnd = OISBefore(to, end) ? to : end;
        taken[self.startAttribute.name] = takenStart;
        id stored = [self storedEnd:takenEnd];
        if (stored == [NSNull null]) [taken removeObjectForKey:self.endAttribute.name];
        else taken[self.endAttribute.name] = stored;
        OISTimeslice *gone = [[OISTimeslice alloc] init];
        gone.values = taken;
        [results addObject:gone];
        BOOL keepsBefore = OISBefore(start, from), keepsAfter = OISBefore(to, end);
        if (keepsBefore && keepsAfter) {
          [slices addObject:[self copyOf:slice start:to end:end work:work]];
          [self update:slice values:[self periodStart:start end:from] work:work];
        } else if (keepsBefore) {
          [self update:slice values:[self periodStart:start end:from] work:work];
        } else if (keepsAfter) {
          [self update:slice values:[self periodStart:to end:end] work:work];
        } else {
          [self delete:slice work:work];
          [slices removeObject:slice];
        }
      }
      continue;
    }

    NSMutableArray *changed = [NSMutableArray array];
    for (OISSliceRecord *slice in selected) {
      NSDate *start = [self startOf:slice], *end = [self endOf:slice];
      if (OISBefore(start, from)) {
        OISSliceRecord *before = [self copyOf:slice start:start end:from work:work];
        [slices addObject:before];
        [changed addObject:before];
        start = from;
      }
      if (OISBefore(to, end)) {
        OISSliceRecord *after = [self copyOf:slice start:to end:end work:work];
        [slices addObject:after];
        [changed addObject:after];
        end = to;
      }
      NSMutableDictionary *values = [self periodStart:start end:end];
      [values addEntriesFromDictionary:changes];
      [self update:slice values:values work:work];
      [changed addObject:slice];
    }

    if (upsert) {
      // The gaps in the period, for each object it touched (or, touching
      // none, the one its object key names): filled from the slice just
      // before, where there is one, else from the delta alone.
      NSMutableDictionary *groups = [NSMutableDictionary dictionary];
      for (OISSliceRecord *slice in selected) {
        NSArray *key = [self objectKeyOf:slice];
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:slice];
      }
      if (!groups.count) {
        for (NSAttributeDescription *attribute in self.objectKey) {
          if (!delta[attribute.name]) {
            if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"A new time slice needs its %@", [self.mapper propertyForAttribute:attribute]]);
            return nil;
          }
        }
        groups[[self objectKeyOf:delta]] = [NSMutableArray array];
      }
      for (NSArray *key in groups) {
        NSMutableArray *gaps = [NSMutableArray array];
        NSDate *cursor = from;
        for (OISSliceRecord *slice in groups[key]) {
          if (OISBefore(cursor, [self startOf:slice])) [gaps addObject:@[ cursor, [self startOf:slice] ]];
          NSDate *end = [self endOf:slice];
          if (!end) {
            cursor = nil;
            break;
          }
          if (OISBefore(cursor, end)) cursor = end;
        }
        if (cursor && OISBefore(cursor, to)) [gaps addObject:to ? @[ cursor, to ] : @[ cursor ]];
        for (NSArray *gap in gaps) {
          NSDate *start = gap[0], *end = gap.count > 1 ? gap[1] : nil;
          OISSliceRecord *preceding = nil;
          for (OISSliceRecord *slice in slices) {
            if (![[self objectKeyOf:slice] isEqual:key]) continue;
            NSDate *sliceEnd = [self endOf:slice];
            if (sliceEnd && [sliceEnd isEqualToDate:start]) preceding = slice;
          }
          NSMutableDictionary *values = preceding ? [self valuesOf:preceding] : [NSMutableDictionary dictionary];
          for (NSUInteger i = 0; i < self.objectKey.count; i++) {
            if (key[i] != [NSNull null]) values[self.objectKey[i].name] = key[i];
          }
          [values addEntriesFromDictionary:changes];
          values[self.startAttribute.name] = start;
          id stored = [self storedEnd:end];
          if (stored == [NSNull null]) [values removeObjectForKey:self.endAttribute.name];
          else values[self.endAttribute.name] = stored;
          OISSliceRecord *made = [self insertValues:values entity:self.entity work:work];
          [slices addObject:made];
          [changed addObject:made];
        }
      }
    }
    for (OISSliceRecord *slice in changed) {
      OISTimeslice *result = [[OISTimeslice alloc] init];
      result.record = slice;
      [results addObject:result];
    }
  }
  // The same slice once, the latest; in order of object and period.
  NSMutableArray *unique = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (OISTimeslice *result in results.reverseObjectEnumerator) {
    if (result.record && [seen containsObject:[NSValue valueWithNonretainedObject:result.record]]) continue;
    if (result.record) [seen addObject:[NSValue valueWithNonretainedObject:result.record]];
    [unique insertObject:result atIndex:0];
  }
  [unique sortUsingComparator:^NSComparisonResult(OISTimeslice *a, OISTimeslice *b) {
    id sa = a.record ?: a.values, sb = b.record ?: b.values;
    NSArray *ka = [self objectKeyOf:sa], *kb = [self objectKeyOf:sb];
    if (![ka isEqual:kb]) return [ka.description compare:kb.description];
    return [[self startOf:sa] compare:[self startOf:sb]];
  }];
  OISTimelineChanges *changes = [[OISTimelineChanges alloc] init];
  changes.records = work.touched;
  changes.results = unique;
  return changes;
}

@end
