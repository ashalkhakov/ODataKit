// ODataIncrementalStore — OData's URL syntax, parsed.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What a service reads out of a request URL (OData 4.01 Part 2, and its
// ABNF): the resource path with its key predicates, and the system query
// options, $filter and $orderby expressions, $select, $expand with its
// options nested to any depth, $top, $skip, $count, $search. A lexer
// turns the text into tokens and a recursive descent parser, one method
// per precedence level (Part 2 section 5.1.1.14), builds the tree.
//
// Each node describes itself as canonical OData text, with parentheses
// only where precedence needs them, so parsing what a node describes
// gives the same tree back.
//
// Query option values are taken as they are after percent-decoding.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ODataExpressionKind) {
  ODataExpressionLiteral,   // value, literalType
  ODataExpressionMember,    // name, of operand (nil: of $it, or of the lambda variable in scope)
  ODataExpressionVariable,  // name: $it, $root, a lambda's variable
  ODataExpressionAlias,     // name: @p, a parameter alias
  ODataExpressionUnary,     // name: not, -; operand
  ODataExpressionBinary,    // name: eq ne gt ge lt le has in and or add sub mul div divby mod; left, right
  ODataExpressionCall,      // name; arguments (a canonical function's, in order) or namedArguments
                            // (a service's function); operand, when bound: Category/NS.F(p=1)
  ODataExpressionLambda,    // name: any, all; operand (the collection), variable, body (nil: any())
  ODataExpressionCast,      // name: the qualified type; operand
  ODataExpressionCount,     // operand/$count
  ODataExpressionList       // arguments: (1,2,3) for in, [1,2,3]
};

@interface ODataExpression : NSObject

@property (nonatomic, readonly) ODataExpressionKind kind;
@property (nonatomic, readonly, copy) NSString *name;
// A literal's value: NSNull, NSNumber (Boolean, Int64), NSDecimalNumber, a
// double's NSNumber, NSString; dates, times, durations, GUIDs, binaries
// and enumeration members as the text of the literal.
@property (nonatomic, readonly, strong, nullable) id value;
// Edm.String, Edm.Int64, Edm.Decimal, Edm.Double, Edm.Boolean, Edm.Date,
// Edm.DateTimeOffset, Edm.TimeOfDay, Edm.Guid, Edm.Duration, Edm.Binary;
// an enumeration's qualified name; nil for null.
@property (nonatomic, readonly, copy, nullable) NSString *literalType;
@property (nonatomic, readonly, strong, nullable) ODataExpression *operand;
@property (nonatomic, readonly, strong, nullable) ODataExpression *left;
@property (nonatomic, readonly, strong, nullable) ODataExpression *right;
@property (nonatomic, readonly, copy, nullable) NSArray<ODataExpression *> *arguments;
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, ODataExpression *> *namedArguments;
@property (nonatomic, readonly, copy, nullable) NSString *variable;
@property (nonatomic, readonly, strong, nullable) ODataExpression *body;

// A collection's aggregate (Data Aggregation section 3.6.1): a call named
// aggregate, of operand (a collection-valued path, or $these, the current
// collection), its argument an aggregate expression (an ODataAggregate:
// Amount with sum), aggregated as the value; nil for any other call.
@property (nonatomic, readonly, strong, nullable) id aggregate;
// The values of the current collection it asks for: each $these/$count
// and $these/aggregate(...) in it, first first, each once.
- (NSArray<ODataExpression *> *)aggregatesOfThese;
// Its parts that pass the test, outermost first, each description once;
// the parts of one that passes are not looked into.
- (NSArray<ODataExpression *> *)partsPassingTest:(BOOL (^)(ODataExpression *part))test;
// The same with some of its parts replaced: each part whose description
// is a key, by its value, an expression, or a literal of a value (a
// number, a string, or NSNull).
- (ODataExpression *)expressionReplacing:(NSDictionary<NSString *, id> *)values;
// A literal: a number, a string, a boolean NSNumber, or NSNull.
+ (instancetype)literalWithValue:(id)value;
// A literal as OData writes it (2024-01-01, Zoo.Diet'Carnivore',
// duration'P1D'); nil for text that is no literal.
+ (nullable instancetype)literalWithText:(NSString *)text;

// Expressions built, not read; each describes itself as $filter writes it.
// A member of operand (nil: of $it, or of the lambda variable in scope).
+ (instancetype)member:(NSString *)name of:(nullable ODataExpression *)operand;
// Category/CategoryName: members along a path from $it (or a variable).
+ (instancetype)memberPath:(NSArray<NSString *> *)path of:(nullable ODataExpression *)operand;
// $it, $root, $these, or a lambda's variable.
+ (instancetype)variable:(NSString *)name;
// @p.
+ (instancetype)alias:(NSString *)name;
// eq ne gt ge lt le has in and or add sub mul div divby mod.
+ (instancetype)binary:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right;
// not, or - (negation).
+ (instancetype)unary:(NSString *)op operand:(ODataExpression *)operand;
// A function: contains(a, b); bound, of operand (Zoo.Age(On=...) of $it).
+ (instancetype)call:(NSString *)name arguments:(NSArray<ODataExpression *> *)arguments;
+ (instancetype)call:(NSString *)name of:(nullable ODataExpression *)operand
      namedArguments:(NSDictionary<NSString *, ODataExpression *> *)namedArguments;
// any or all over a collection: variable and body nil for any().
+ (instancetype)lambda:(NSString *)name of:(ODataExpression *)collection
              variable:(nullable NSString *)variable body:(nullable ODataExpression *)body;
// collection/$count.
+ (instancetype)countOf:(ODataExpression *)collection;
// A type cast, NS.Manager, of operand (nil: of $it).
+ (instancetype)cast:(NSString *)type of:(nullable ODataExpression *)operand;
// (1,2,3), for in.
+ (instancetype)list:(NSArray<ODataExpression *> *)items;
// collection/aggregate(...): an aggregate expression as $apply writes it
// (Amount with sum, $count); nil for text that is none.
+ (nullable instancetype)aggregateOf:(ODataExpression *)collection text:(NSString *)text;
// The same of an aggregate built (ODataApply.h: a path with a method, or
// $count), its alias not written: nothing is read from text. nil for one
// whose path is not OData identifiers, whose method is not sum, min, max,
// average, countdistinct or a qualified name, or that is an expression's
// or a custom aggregate.
+ (nullable instancetype)aggregateOf:(ODataExpression *)collection aggregate:(id)aggregate;
// e in (values...), literals; false for no values.
+ (instancetype)expression:(ODataExpression *)e inValues:(NSArray *)values;

// The member names along a path of members from $it (Category/Name is
// Category, Name); nil when this is not such a path.
@property (nonatomic, readonly, nullable) NSArray<NSString *> *memberPath;

// Parses a boolean or value expression: $filter, an $orderby item.
+ (nullable instancetype)expressionWithString:(NSString *)text error:(NSError **)error;

@end

@class ODataQueryOptions;

@interface ODataOrderItem : NSObject
+ (instancetype)itemWithExpression:(ODataExpression *)expression descending:(BOOL)descending;
@property (nonatomic, readonly, strong) ODataExpression *expression;
@property (nonatomic, readonly) BOOL descending;
@end

// One $select item: a path of names (with type casts, NS.Type), or *.
@interface ODataSelectItem : NSObject
+ (instancetype)itemWithPath:(NSArray<NSString *> *)path;
@property (nonatomic, readonly, copy) NSArray<NSString *> *path;
@property (nonatomic, readonly) BOOL isStar;
@end

// One $expand item: a navigation path, its options, and $ref or $count.
// $compute's items (Part 2 section 5.1.3): an expression, and the name
// it is known by in $select, $filter and $orderby.
@interface ODataComputeItem : NSObject
+ (instancetype)itemWithExpression:(ODataExpression *)expression alias:(NSString *)alias;
@property (nonatomic, readonly, strong) ODataExpression *expression;
@property (nonatomic, readonly, copy) NSString *alias;
@end

@interface ODataExpandItem : NSObject
// A navigation path expanded, with options of its own (nil: none).
+ (instancetype)itemWithPath:(NSArray<NSString *> *)path options:(nullable ODataQueryOptions *)options;
@property (nonatomic, readonly, copy) NSArray<NSString *> *path;
@property (nonatomic, readonly) BOOL isStar;
@property (nonatomic, readonly) BOOL isRef;
@property (nonatomic, readonly) BOOL isCount;
@property (nonatomic, readonly, strong) ODataQueryOptions *options;
@end

// $search (Part 2 section 5.1.7): words and "phrases", combined with AND
// (or nothing between them), OR and NOT, grouped by parentheses; NOT binds
// tightest, OR loosest. What a word matches is the service's to say.
typedef NS_ENUM(NSInteger, ODataSearchKind) {
  ODataSearchWord,     // text
  ODataSearchPhrase,   // text, without its quotes
  ODataSearchAnd,      // left, right
  ODataSearchOr,       // left, right
  ODataSearchNot       // operand
};

@interface ODataSearchExpression : NSObject
+ (nullable instancetype)searchWithString:(NSString *)text error:(NSError **)error;
+ (instancetype)searchWithKind:(ODataSearchKind)kind text:(nullable NSString *)text
                          left:(nullable ODataSearchExpression *)left right:(nullable ODataSearchExpression *)right;
@property (nonatomic, readonly) ODataSearchKind kind;
@property (nonatomic, readonly, copy, nullable) NSString *text;
@property (nonatomic, readonly, strong, nullable) ODataSearchExpression *left;
@property (nonatomic, readonly, strong, nullable) ODataSearchExpression *right;
@property (nonatomic, readonly, strong, nullable) ODataSearchExpression *operand;
// Whether texts answer it: a word or phrase is in one of them, regardless
// of case and diacritics.
- (BOOL)matchesTexts:(NSArray<NSString *> *)texts;
// -description is the expression as $search writes it.
@end

@interface ODataQueryOptions : NSObject <NSCopying, NSMutableCopying>

// The options of a query string, as a dictionary of decoded values
// ($filter, $orderby, ...; other keys are custom options and aliases).
+ (nullable instancetype)optionsWithQuery:(NSDictionary<NSString *, NSString *> *)query error:(NSError **)error;

@property (nonatomic, readonly, strong, nullable) ODataExpression *filter;
@property (nonatomic, readonly, copy) NSArray<ODataOrderItem *> *orderBy;
@property (nonatomic, readonly, copy) NSArray<ODataSelectItem *> *select;
@property (nonatomic, readonly, copy) NSArray<ODataExpandItem *> *expand;
@property (nonatomic, readonly, strong, nullable) NSNumber *top;
@property (nonatomic, readonly, strong, nullable) NSNumber *skip;
// $count=true: a count along with the rows. (Not count: an id's -count
// would then be ambiguous wherever this header is seen.)
@property (nonatomic, readonly, strong, nullable) NSNumber *includeCount;   // BOOL
@property (nonatomic, readonly, strong, nullable) NSNumber *levels;  // -1: max
@property (nonatomic, readonly, copy, nullable) NSString *search;
@property (nonatomic, readonly, strong, nullable) ODataSearchExpression *searchExpression;
// $apply (OData Data Aggregation): its transformations (ODataApply.h).
@property (nonatomic, readonly, copy, nullable) NSArray *apply;
@property (nonatomic, readonly, copy) NSArray<ODataComputeItem *> *compute;
// Application time (OData-Temporal section 4.2): a point ($at), or an
// interval ($from with $to, closed-open, or $toInclusive, closed-closed),
// each a literal.
@property (nonatomic, readonly, strong, nullable) ODataExpression *temporalAt;
@property (nonatomic, readonly, strong, nullable) ODataExpression *temporalFrom;
@property (nonatomic, readonly, strong, nullable) ODataExpression *temporalTo;
@property (nonatomic, readonly, strong, nullable) ODataExpression *temporalToInclusive;
// The same as written ($at -> 2024-10-01), for a filter made of them.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *temporalText;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, ODataExpression *> *aliases;  // @p -> value
// Taken as written: $format (json, or a media type with parameters), and
// $skiptoken, which only the service that wrote it can read.
@property (nonatomic, readonly, copy, nullable) NSString *format;
@property (nonatomic, readonly, copy, nullable) NSString *skipToken;
// The service's own options, not OData's: by name, as written.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *customOptions;

// The options as a query string's items, each [name, value], the value not
// percent-encoded: $at, $from, $to, $toInclusive, $filter, $search,
// $apply, $orderby, $top, $skip, $count, $compute, $select, $expand,
// $levels, $format, $skiptoken, then aliases and custom options by name.
// -description is the same inside an $expand: name=value, with ;.
- (NSArray<NSArray<NSString *> *> *)queryItems;

@end

// Options built, not read: each property may be set.
@interface ODataMutableQueryOptions : ODataQueryOptions
@property (nonatomic, strong, nullable) ODataExpression *filter;
@property (nonatomic, copy) NSArray<ODataOrderItem *> *orderBy;
@property (nonatomic, copy) NSArray<ODataSelectItem *> *select;
@property (nonatomic, copy) NSArray<ODataExpandItem *> *expand;
@property (nonatomic, strong, nullable) NSNumber *top;
@property (nonatomic, strong, nullable) NSNumber *skip;
@property (nonatomic, strong, nullable) NSNumber *includeCount;
@property (nonatomic, strong, nullable) NSNumber *levels;
// Sets search too, as the expression writes it.
@property (nonatomic, strong, nullable) ODataSearchExpression *searchExpression;
@property (nonatomic, copy, nullable) NSArray *apply;
@property (nonatomic, copy) NSArray<ODataComputeItem *> *compute;
@property (nonatomic, strong, nullable) ODataExpression *temporalAt;
@property (nonatomic, strong, nullable) ODataExpression *temporalFrom;
@property (nonatomic, strong, nullable) ODataExpression *temporalTo;
@property (nonatomic, strong, nullable) ODataExpression *temporalToInclusive;
@property (nonatomic, copy) NSDictionary<NSString *, ODataExpression *> *aliases;
@property (nonatomic, copy, nullable) NSString *format;
@property (nonatomic, copy, nullable) NSString *skipToken;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *customOptions;
@end

// One segment of a resource path: People('russellwhyte'), NS.Employee,
// Trips(0), $count, $ref, $value, NS.GetFavoriteAirline().
@interface ODataPathSegment : NSObject
@property (nonatomic, readonly, copy) NSString *name;
// A key predicate: its parts by name, or under @"" for a single unnamed
// key, Products(1); nil when there is none.
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, ODataExpression *> *keys;
// A function's parameters: NS.F(p=1).
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, ODataExpression *> *arguments;
@property (nonatomic, readonly) BOOL isCall;
@end

@interface ODataResourcePath : NSObject
// A path relative to the service root, not percent-encoded:
// People('russellwhyte')/Trips(0)/PlanItems.
+ (nullable instancetype)pathWithString:(NSString *)text error:(NSError **)error;
@property (nonatomic, readonly, copy) NSArray<ODataPathSegment *> *segments;
@end

NS_ASSUME_NONNULL_END
