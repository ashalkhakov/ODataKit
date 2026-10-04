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
  ODataExpressionVariable,  // name: $it, $root, $these, $this, a lambda's variable
  ODataExpressionAlias,     // name: @p, a parameter alias
  ODataExpressionUnary,     // name: not, -; operand
  ODataExpressionBinary,    // name: eq ne gt ge lt le has in and or add sub mul div divby mod; left, right
  ODataExpressionCall,      // name; arguments (a canonical function's, in order) or namedArguments
                            // (a service's function); operand, when bound: Category/NS.F(p=1)
  ODataExpressionLambda,    // name: any, all; operand (the collection), variable, body (nil: any())
  ODataExpressionCast,      // name: the qualified type; operand
  ODataExpressionCount,     // operand/$count; body: its $filter, operand/$count($filter=body) (countFilter)
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
// A count's filter: the members of the collection it counts, those for
// which it is true (OData 4.01, $count($filter=...)); nil for any other
// node, and for a count of all the members. In it, a member path with no
// variable, and $this, are the counted member's; $it is still the object
// of the resource path (the outer one), and a lambda variable in scope
// outside is still in scope: Cars/$count($filter=Color eq 'red' and
// Owner/Nr eq $it/Nr). It is the node's body, so whatever walks a
// lambda's body walks it too.
@property (nonatomic, readonly, strong, nullable) ODataExpression *countFilter;

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
//
// Names and operators are written as they are given, so each is checked
// against what OData's grammar allows in its place, and one that is not
// allowed raises NSInvalidArgumentException: it could otherwise carry
// filter text (a member named "Price eq 0 or true"). Names come from
// models and code, so one refused is a programming or model error, as an
// index out of range is. An OData identifier (Part 2 section 4.3) is a
// letter or _, then letters, digits and _, 128 at most; a qualified name
// is identifiers joined by dots (NS.Type, Edm.String). Values are never
// refused: a literal is quoted as it is written.
//
// A member of operand (nil: of $it, or of the lambda variable in scope);
// the name an OData identifier.
+ (instancetype)member:(NSString *)name of:(nullable ODataExpression *)operand;
// Category/CategoryName: members along a path from $it (or a variable);
// each name an OData identifier.
+ (instancetype)memberPath:(NSArray<NSString *> *)path of:(nullable ODataExpression *)operand;
// $it, $root, $these, $this, or a lambda's variable (an OData identifier).
+ (instancetype)variable:(NSString *)name;
// @p: an OData identifier, with or without the @.
+ (instancetype)alias:(NSString *)name;
// eq ne gt ge lt le has in and or add sub mul div divby mod.
+ (instancetype)binary:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right;
// not, or - (negation).
+ (instancetype)unary:(NSString *)op operand:(ODataExpression *)operand;
// A function: contains(a, b); bound, of operand (Zoo.Age(On=...) of $it).
// Its name an OData identifier or a qualified name; parameter names OData
// identifiers.
+ (instancetype)call:(NSString *)name arguments:(NSArray<ODataExpression *> *)arguments;
+ (instancetype)call:(NSString *)name of:(nullable ODataExpression *)operand
      namedArguments:(NSDictionary<NSString *, ODataExpression *> *)namedArguments;
// any or all over a collection: variable (an OData identifier) and body
// nil for any().
+ (instancetype)lambda:(NSString *)name of:(ODataExpression *)collection
              variable:(nullable NSString *)variable body:(nullable ODataExpression *)body;
// collection/$count.
+ (instancetype)countOf:(ODataExpression *)collection;
// collection/$count($filter=filter): its members for which filter is true
// (OData 4.01; see countFilter for what names mean in it); nil filter:
// all of them, collection/$count.
+ (instancetype)countOf:(ODataExpression *)collection filter:(nullable ODataExpression *)filter;
// A type cast, NS.Manager, of operand (nil: of $it): a qualified name.
+ (instancetype)cast:(NSString *)type of:(nullable ODataExpression *)operand;
// (1,2,3), for in.
+ (instancetype)list:(NSArray<ODataExpression *> *)items;
// collection/aggregate(...): an aggregate expression as $apply writes it
// (Amount with sum, $count); nil for text that is none.
+ (nullable instancetype)aggregateOf:(ODataExpression *)collection text:(NSString *)text;
// The same of an aggregate built (ODataApply.h: a path with a method, or
// $count, of the collection or of a path), its alias not written: nothing
// is read from text. nil for one whose path is empty or not OData
// identifiers, whose method is not sum, min, max, average, countdistinct
// or a qualified name (a custom method, NS.median), that has a method but
// no path, or that is an expression's or a custom aggregate named alone.
+ (nullable instancetype)aggregateOf:(ODataExpression *)collection aggregate:(id)aggregate;
// e in (values...), literals; false for no values.
+ (instancetype)expression:(ODataExpression *)e inValues:(NSArray *)values;

// The member names along a path of members from $it (Category/Name is
// Category, Name); nil when this is not such a path.
@property (nonatomic, readonly, nullable) NSArray<NSString *> *memberPath;

// Parses a boolean or value expression: $filter, an $orderby item.
+ (nullable instancetype)expressionWithString:(NSString *)text error:(NSError **)error;

@end

// Whether a name is an OData identifier (Part 2 section 4.3: a letter or
// _, then letters, digits and _, 128 at most), or a qualified name
// (identifiers joined by dots, two or more: NS.Type, Edm.String).
FOUNDATION_EXPORT BOOL ODataIsIdentifier(NSString *_Nullable name);
FOUNDATION_EXPORT BOOL ODataIsQualifiedName(NSString *_Nullable name);

// Runs build, and returns what it returns; a name or operator it gave the
// builders that they refuse (above) is an error instead, nil returned and
// *error an ODataIncrementalStoreErrorUnsupportedExpression saying which.
// For code that builds from names it does not choose (a model's, whose
// OData.property is the model's text): its fetch fails, and does not
// raise. Other exceptions go on.
FOUNDATION_EXPORT id _Nullable ODataExpressionBuilding(NSError *_Nullable *_Nullable error, id _Nullable (^build)(void));

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
