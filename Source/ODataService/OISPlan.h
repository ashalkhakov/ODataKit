// ODataService — a request's plan: a tree in a nested relational algebra.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A read is planned before it runs (docs/query-plan.md). The logical plan
// says what the request asks, operator by operator; rewriting it puts what
// the store can do into store operators, which reach the store through the
// set's handler; the rest runs here, over relations: entities (managed
// objects, with what compute gave them) or grouped rows (nested
// dictionaries). A write is planned too (docs/write-plan.md): what it
// reads, what it checks, what it changes, then its save.

#pragma once
#import <Foundation/Foundation.h>
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataExpression.h>
#import <ODataKit/ODataApply.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OISPlanOperator) {
  // Relations the plan starts from.
  OISPlanScan,        // entity: its set's rows (a navigation's, some given) as the caller may see them; fixed: predicates
  OISPlanObjects,     // objects: given, not read (an entity read, an operation's result, a write's)
  OISPlanChanges,     // a delta token's changes of the set: rows, removed and deleted
  OISPlanInput,       // a binding's input: the relation of the operator it is for
  OISPlanClosure,     // a recursive hierarchy: hierarchy (set path), qualifier
  OISPlanSpan,        // the earliest and latest of a date attribute (entity, attributeName): what month() and the rest range over
  // Operators over a relation.
  OISPlanSelect,      // filters: expressions
  OISPlanSort,        // order
  OISPlanLimit,       // skip, top, pageSize
  OISPlanApply,       // transformation: one of $apply's (or $compute's, $search's), here
  OISPlanNest,        // item: an $expand, its plan per parent (nested), its own nests
  // Scalars, for bindings.
  OISPlanValue,       // expression: a $these, over the input
  OISPlanCount,       // the input's count
  // What rewriting makes: the store does it, through the handler.
  OISPlanStoreScan,       // entity, fixed, filters, order (then by key), skip, top (+1 for paging), prefetch
  OISPlanStoreAggregate,  // transformation: the first grouping, over the store scan it replaced
  OISPlanStoreCount,      // the count of a store scan's rows (its predicate)
  // Writes (docs/write-plan.md): read, checked, then written, through the
  // handler.
  OISPlanLookup,      // entity, key (reference: as the request named it): the one row, through the handler; optional: or none
  OISPlanSequence,    // entity, attributeName: the largest key, read once; the plan's new rows count on from it
  OISPlanInsert,      // entity, values; sequences for the keys it is not given
  OISPlanUpdate,      // target's rows, values (replace: PUT)
  OISPlanDelete,      // target's rows
  OISPlanLink,        // target's row, relationship: member added (or, to-one, set)
  OISPlanUnlink,      // target's row, relationship: member taken away (or, to-one, cleared)
  OISPlanMerge,       // input: the Lookup it matches by; matched (an Update of it) when there is one, else otherwise (an Insert)
  OISPlanTemporal,    // action, deltas, over input (the slices): the timeline's changes, as inserts, updates and deletes
  OISPlanCall,        // an action: the handler's own code (operation)
  OISPlanCommit       // inputs, then input, then the save
};

// A relationship's value in a write: its members, from the row's (adds)
// or none, with nodes' rows added and others' taken away.
@interface OISPlanMembers : NSObject
@property (nonatomic, copy) NSArray *nodes;       // OISPlanNode (its row), or an object
@property (nonatomic, copy) NSArray *removes;     // likewise
@property (nonatomic) BOOL adds;
+ (instancetype)membersOf:(NSArray *)nodes removing:(NSArray *)removes adding:(BOOL)adds;
@end

@interface OISPlanNode : NSObject
+ (instancetype)operator:(OISPlanOperator)op input:(nullable OISPlanNode *)input;
@property (nonatomic) OISPlanOperator op;
@property (nonatomic, strong, nullable) OISPlanNode *input;
// Scalars its expressions refer to, by what each stands for (the $these
// node's description): worked out before it runs.
@property (nonatomic, copy) NSDictionary<NSString *, OISPlanNode *> *bindings;

@property (nonatomic, strong, nullable) NSEntityDescription *entity;
@property (nonatomic, copy) NSArray<NSPredicate *> *fixed;         // what is not the request's to say: visibility, a navigation
@property (nonatomic, copy) NSString *fixedSummary;                 // how explain names them
@property (nonatomic, copy) NSArray<ODataExpression *> *filters;
@property (nonatomic, strong, nullable) ODataSearchExpression *search;
@property (nonatomic, strong, nullable) ODataQueryOptions *time;    // application time ($at, $from...)
@property (nonatomic, copy) NSArray<ODataOrderItem *> *order;
@property (nonatomic) BOOL keyOrder;                                // then by key: pages do not overlap
@property (nonatomic, strong, nullable) NSPredicate *after;         // a store scan's rows after a key (keyset paging)
@property (nonatomic, strong, nullable) NSNumber *skip;
@property (nonatomic, strong, nullable) NSNumber *top;
@property (nonatomic) NSUInteger pageSize;                          // 0: all; else a page, and one more to know there is another
@property (nonatomic) NSUInteger limit;                             // at most so many (maxRowsInMemory, and one more)
@property (nonatomic, copy) NSArray<NSString *> *prefetch;          // relationships read with the rows
@property (nonatomic, strong, nullable) ODataApplyTransformation *transformation;
@property (nonatomic, strong, nullable) ODataExpandItem *item;
@property (nonatomic, strong, nullable) OISPlanNode *nested;
@property (nonatomic, copy) NSArray<OISPlanNode *> *nests;
@property (nonatomic, strong, nullable) ODataExpression *expression;
@property (nonatomic, copy, nullable) NSArray *objects;
@property (nonatomic, copy, nullable) NSArray<NSString *> *hierarchy;
@property (nonatomic, copy, nullable) NSString *qualifier;
@property (nonatomic, copy, nullable) NSString *deltaToken;
@property (nonatomic, copy, nullable) NSString *attributeName;
// $compute's names, and what each stands for: the rows' computed values,
// which a sort here or a write computes.
@property (nonatomic, copy) NSDictionary<NSString *, id> *computed;

// Writes. The set's handler (ODataEntitySetHandler).
@property (nonatomic, strong, nullable) id handler;
// By Core Data name: a value (NSNull: none), a node (its row), or members.
@property (nonatomic, copy) NSDictionary<NSString *, id> *values;
// Writes done before this one (the nested ones a delta deletes).
@property (nonatomic, copy) NSArray<OISPlanNode *> *inputs;
// What an Update, Delete, Link or Unlink changes: Objects, a Lookup, a
// Store scan (a collection's members), an Insert.
@property (nonatomic, strong, nullable) OISPlanNode *target;
@property (nonatomic, strong, nullable) NSRelationshipDescription *relationship;
@property (nonatomic, strong, nullable) OISPlanNode *member;
@property (nonatomic, strong, nullable) OISPlanNode *matched;
@property (nonatomic, strong, nullable) OISPlanNode *otherwise;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *key;
@property (nonatomic, copy, nullable) NSString *reference;
@property (nonatomic) BOOL optional;
@property (nonatomic) BOOL replace;
// Sequences, by the key attribute they give.
@property (nonatomic, copy) NSDictionary<NSString *, OISPlanNode *> *sequences;
// Checked before anything is written: If-Match (ifMatch; of a stream,
// mediaAttribute's), a nested entity's @odata.etag (etag), its
// @odata.type (typed: target is entity).
@property (nonatomic, copy, nullable) NSString *ifMatch;
@property (nonatomic, strong, nullable) NSAttributeDescription *mediaAttribute;
@property (nonatomic, copy, nullable) NSString *etag;
@property (nonatomic) BOOL typed;
// A Temporal action's name and delta time slices (values, as Insert's).
@property (nonatomic, copy, nullable) NSString *action;
@property (nonatomic, copy, nullable) NSArray<NSDictionary<NSString *, id> *> *deltas;
// A Delete's rows but these Lookups' (PUT of a collection: those not given).
@property (nonatomic, copy) NSArray<OISPlanNode *> *except;
// A branch of a Merge that could not be planned: why, answered if it is
// the one taken.
@property (nonatomic, strong, nullable) NSError *failure;
// How explain names given objects ($objects: what a write made).
@property (nonatomic, copy, nullable) NSString *objectsSummary;

// The tree, one operator a line, its input indented beneath it.
- (NSString *)treeDescription;
- (void)describeInto:(NSMutableString *)text depth:(NSUInteger)depth;
@end

// What an operator gives: the rows, entities or (shape set: their paths)
// grouped rows, with what $apply's compute named and expand asked for.
@interface OISRelation : NSObject <NSCopying>
@property (nonatomic, copy) NSArray *rows;
@property (nonatomic, strong, nullable) NSMutableArray<NSArray<NSString *> *> *shape;
@property (nonatomic, strong) NSMutableDictionary *computed;
@property (nonatomic, strong) NSMutableArray<NSString *> *expansions;
// A page was cut from more.
@property (nonatomic) BOOL hasMore;
@property (nonatomic, strong, nullable) NSNumber *count;
+ (instancetype)relationOfRows:(NSArray *)rows;
@end

// A read's plan: what it answers with, and what runs before.
@interface OISPlan : NSObject
// The rows, then the expansions over them.
@property (nonatomic, strong) OISPlanNode *root;
@property (nonatomic, copy) NSArray<OISPlanNode *> *nests;
// $count=true: the rows' count before paging; nil for none.
@property (nonatomic, strong, nullable) OISPlanNode *count;
// Recursive hierarchies the read names, and the spans of the dates its
// month() and the rest range over: read before anything else.
@property (nonatomic, copy) NSArray<OISPlanNode *> *closures;
@property (nonatomic, copy) NSArray<OISPlanNode *> *spans;
// The entity sets of open types whose dynamic properties are read, once
// the rows and their expansions are: those it may write.
@property (nonatomic, copy) NSArray<NSString *> *dynamicSets;
// The same read before rewriting, for explain.
@property (nonatomic, strong, nullable) OISPlan *logical;
// A write's: its Commit, and the read of what it answers with.
@property (nonatomic, strong, nullable) OISPlanNode *write;
@property (nonatomic, strong, nullable) OISPlan *returning;
// The largest integer key each new row of an entity is given in the
// request, by "Entity.attribute": a sequence counts on from above it.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *givenKeys;
// What the caller needs to run it, worked out before it runs: for each
// thing it does that asks for a permission (read Products, update
// Categories, call NS.Raise), the scopes any one of which allows it. A
// Merge's branch, and a Temporal action's slices, are known only once
// read, and checked then, before anything is written.
@property (nonatomic, copy) NSDictionary<NSString *, NSSet<NSString *> *> *permissions;
- (NSString *)treeDescription;
@end

NS_ASSUME_NONNULL_END
