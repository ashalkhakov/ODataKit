// ODataService — application time (OData-Temporal): entity sets whose
// rows are time slices.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// An entity whose userInfo names a period (OData.periodStart and
// OData.periodEnd, ODataPropertyMapper.h) is served as a timeline entity
// set (Temporal.TimelineVisible): each row a time slice, valid from its
// start to its end, of the object its object key names. Periods are
// closed-open, or closed-closed for dates with OData.closedClosedPeriods;
// no end, or 9999-12-31, is no end at all.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataPropertyMapper.h>
#import <ODataKit/ODataExpression.h>

NS_ASSUME_NONNULL_BEGIN

// A slice as an action works on it: one of the slices it was given, or one
// it makes. Its values as they are now (Core Data names; NSNull for none),
// and, for one it was given, what the action changes. -valueForKey: reads
// its values, so a record stands where a slice would.
@interface OISSliceRecord : NSObject
@property (nonatomic, strong) NSEntityDescription *entity;
// The slice given; for one made, the one written, once it is.
@property (nonatomic, strong, nullable) NSManagedObject *object;
@property (nonatomic, readonly) NSMutableDictionary<NSString *, id> *values;
@property (nonatomic, readonly) NSMutableDictionary<NSString *, id> *changes;
@property (nonatomic, readonly) BOOL isNew;
@property (nonatomic, readonly) BOOL isDeleted;
@end

// A time slice an action made, changed or took away: its record, or, for a
// period deleted, what the slice held then (Core Data values, the period
// included).
@interface OISTimeslice : NSObject
@property (nonatomic, strong, nullable) OISSliceRecord *record;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *values;
// The record's slice, once written.
@property (nonatomic, readonly, nullable) NSManagedObject *object;
@end

// What an action does: the slices it makes, changes and deletes (each
// once, in the order it first touched them: made ones with their values,
// changed ones with their changes), and what it answers with.
@interface OISTimelineChanges : NSObject
@property (nonatomic, copy) NSArray<OISSliceRecord *> *records;
@property (nonatomic, copy) NSArray<OISTimeslice *> *results;
@end

@interface OISTimeline : NSObject

// nil for an entity whose userInfo names no period (or names attributes
// it does not have, or that are not dates).
+ (nullable instancetype)timelineOfEntity:(NSEntityDescription *)entity mapper:(ODataPropertyMapper *)mapper;

@property (nonatomic, readonly) NSAttributeDescription *startAttribute;
@property (nonatomic, readonly) NSAttributeDescription *endAttribute;
@property (nonatomic, readonly) NSArray<NSAttributeDescription *> *objectKey;
@property (nonatomic, readonly) BOOL isDate;        // Edm.Date, else Edm.DateTimeOffset
@property (nonatomic, readonly) BOOL closedClosed;

// Temporal.ApplicationTimeSupport, as JSON CSDL has it.
- (NSDictionary *)applicationTimeSupport;

// $at, or $from with $to or $toInclusive, as a filter over the period
// (OData-Temporal section 4.2.3), built of the literals the request gave
// and the period's properties; nil and the error for a property's name
// that cannot be written.
- (nullable ODataExpression *)filterFrom:(ODataExpression *)from to:(nullable ODataExpression *)to inclusive:(BOOL)inclusive
                                   error:(NSError **)error;

// Temporal.Update, Upsert or Delete (the vocabulary's names, unqualified)
// of these delta time slices (Core Data values, each with its period),
// over the slices given: what it would write, and answer with. Nothing is
// written: the caller writes the records. nil, and why (an
// ODataServiceError), when it cannot.
- (nullable OISTimelineChanges *)changesOf:(NSString *)action
                                    deltas:(NSArray<NSDictionary<NSString *, id> *> *)deltas
                                candidates:(NSArray<NSManagedObject *> *)candidates
                                     error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
