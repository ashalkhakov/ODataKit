// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataExpression.h"
#import "ODataLexer.h"
#import "ODataError.h"
#import "ODataApply.h"

// The parser, below the tree.
@class ODataQueryOptions, ODataResourcePath;
@interface OISParser : NSObject
- (instancetype)initWithString:(NSString *)string;
@property (nonatomic, strong, nullable) NSError *error;
- (nullable ODataExpression *)parseCommon;
- (BOOL)atEnd;
- (BOOL)parseOption:(NSString *)option into:(ODataQueryOptions *)options;
- (nullable ODataResourcePath *)parseResourcePath;
@end

#pragma mark - The tree

@interface ODataExpression ()
@property (nonatomic) ODataExpressionKind kind;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong, nullable) id value;
@property (nonatomic, copy, nullable) NSString *literalType;
@property (nonatomic, copy, nullable) NSString *raw;  // a literal as written, for its description
@property (nonatomic, strong, nullable) ODataExpression *operand;
@property (nonatomic, strong, nullable) ODataExpression *left;
@property (nonatomic, strong, nullable) ODataExpression *right;
@property (nonatomic, copy, nullable) NSArray<ODataExpression *> *arguments;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, ODataExpression *> *namedArguments;
@property (nonatomic, copy, nullable) NSString *variable;
@property (nonatomic, strong, nullable) ODataExpression *body;
@property (nonatomic, strong, nullable) id aggregate;
@property (nonatomic, copy, nullable) NSString *aggregateText;  // as written, for its description
@end

// Precedence, loosest first (Part 2 section 5.1.1.14).
static NSInteger OISPrecedence(NSString *op)
{
  static NSDictionary *levels;
  if (!levels) {
    levels = @{ @"or": @1, @"and": @2, @"eq": @3, @"ne": @3, @"gt": @4, @"ge": @4, @"lt": @4, @"le": @4, @"has": @4, @"in": @4,
                @"add": @5, @"sub": @5, @"mul": @6, @"div": @6, @"divby": @6, @"mod": @6 };
  }
  return [levels[op] integerValue];
}

static NSString *OISQuoted(NSString *text)
{
  return [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

// An OData identifier (Part 2 section 4.3): a letter or underscore, then
// letters, digits and underscores.
static BOOL OISIsODataIdentifier(NSString *name)
{
  if (name.length == 0 || name.length > 128) return NO;
  NSCharacterSet *first = [NSCharacterSet letterCharacterSet];
  NSCharacterSet *rest = [NSCharacterSet alphanumericCharacterSet];
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    if (c == '_') continue;
    if (![(i == 0 ? first : rest) characterIsMember:c]) return NO;
  }
  return YES;
}

static BOOL OISIsQualifiedName(NSString *name)
{
  NSArray *parts = [name componentsSeparatedByString:@"."];
  if (parts.count < 2) return NO;
  for (NSString *part in parts) {
    if (!OISIsODataIdentifier(part)) return NO;
  }
  return YES;
}

BOOL ODataIsIdentifier(NSString *name)
{
  return OISIsODataIdentifier(name);
}

BOOL ODataIsQualifiedName(NSString *name)
{
  return OISIsQualifiedName(name);
}

// What the builders write as it is, a name or an operator, checked: one
// OData's grammar does not allow there could carry filter text, and is a
// programming or model error. Raises NSInvalidArgumentException, its
// userInfo marking it the builders' (ODataExpressionBuilding).
static NSString * const OISRefusedNameKey = @"ODataExpressionRefusedName";

static void OISRequire(BOOL allowed, NSString *what, NSString *name)
{
  if (allowed) return;
  NSString *reason = [NSString stringWithFormat:@"ODataExpression: %@ \"%@\" is not one", what, name ?: @"(nil)"];
  @throw [NSException exceptionWithName:NSInvalidArgumentException reason:reason userInfo:@{ OISRefusedNameKey: name ?: @"" }];
}

id ODataExpressionBuilding(NSError **error, id (^build)(void))
{
  @try {
    return build();
  } @catch (NSException *exception) {
    if (![exception.name isEqualToString:NSInvalidArgumentException] || !exception.userInfo[OISRefusedNameKey]) @throw;
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, exception.reason);
    return nil;
  }
}

static BOOL OISIsVariableName(NSString *name)
{
  return [@[ @"$it", @"$root", @"$these", @"$this" ] containsObject:name ?: @""] || OISIsODataIdentifier(name);
}

@implementation ODataExpression

+ (instancetype)ofKind:(ODataExpressionKind)kind name:(NSString *)name
{
  ODataExpression *e = [[self alloc] init];
  e.kind = kind;
  e.name = name ?: @"";
  return e;
}

- (NSInteger)precedence
{
  switch (self.kind) {
    case ODataExpressionBinary: return OISPrecedence(self.name);
    case ODataExpressionUnary: return 7;
    default: return 8;
  }
}

// A child as text, in parentheses when it binds more loosely than its
// place needs: on the right of a left-associative operator, equally loose
// is too loose.
- (NSString *)text:(ODataExpression *)child tighterThan:(NSInteger)level orEqual:(BOOL)equal
{
  NSInteger p = [child precedence];
  BOOL parens = p < level || (equal && p == level);
  return parens ? [NSString stringWithFormat:@"(%@)", child.description] : child.description;
}

- (NSString *)description
{
  switch (self.kind) {
    case ODataExpressionLiteral:
      if (self.raw) return self.raw;
      if (!self.value || self.value == [NSNull null]) return @"null";
      if ([self.literalType isEqualToString:@"Edm.String"]) return OISQuoted(self.value);
      if ([self.literalType isEqualToString:@"Edm.Boolean"]) return [self.value boolValue] ? @"true" : @"false";
      return [self.value description];
    case ODataExpressionMember:
      return self.operand ? [NSString stringWithFormat:@"%@/%@", self.operand, self.name] : self.name;
    case ODataExpressionVariable:
      return self.name;
    case ODataExpressionAlias:
      return [@"@" stringByAppendingString:self.name];
    case ODataExpressionUnary:
      return [self.name isEqualToString:@"not"]
          ? [NSString stringWithFormat:@"not %@", [self text:self.operand tighterThan:7 orEqual:NO]]
          : [NSString stringWithFormat:@"-%@", [self text:self.operand tighterThan:7 orEqual:NO]];
    case ODataExpressionBinary: {
      NSInteger level = OISPrecedence(self.name);
      return [NSString stringWithFormat:@"%@ %@ %@", [self text:self.left tighterThan:level orEqual:NO], self.name,
                                        [self text:self.right tighterThan:level orEqual:![self.name isEqualToString:@"in"]]];
    }
    case ODataExpressionCall: {
      NSMutableArray *parts = [NSMutableArray array];
      if (self.namedArguments) {
        for (NSString *name in [self.namedArguments.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
          [parts addObject:[NSString stringWithFormat:@"%@=%@", name, self.namedArguments[name]]];
        }
      } else {
        for (ODataExpression *argument in self.arguments) [parts addObject:argument.description];
      }
      NSString *call = self.aggregate ? [NSString stringWithFormat:@"aggregate(%@)", self.aggregateText]
                                      : [NSString stringWithFormat:@"%@(%@)", self.name, [parts componentsJoinedByString:self.namedArguments ? @"," : @", "]];
      return self.operand ? [NSString stringWithFormat:@"%@/%@", self.operand, call] : call;
    }
    case ODataExpressionLambda: {
      NSString *inner = self.body ? [NSString stringWithFormat:@"%@:%@", self.variable, self.body] : @"";
      return [NSString stringWithFormat:@"%@/%@(%@)", self.operand, self.name, inner];
    }
    case ODataExpressionCast:
      return self.operand ? [NSString stringWithFormat:@"%@/%@", self.operand, self.name] : self.name;
    case ODataExpressionCount:
      return self.body ? [NSString stringWithFormat:@"%@/$count($filter=%@)", self.operand, self.body]
                       : [NSString stringWithFormat:@"%@/$count", self.operand];
    case ODataExpressionList: {
      NSMutableArray *parts = [NSMutableArray array];
      for (ODataExpression *item in self.arguments) [parts addObject:item.description];
      return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@","]];
    }
  }
  return @"";
}

- (void)addPartsPassingTest:(BOOL (^)(ODataExpression *))test to:(NSMutableArray *)found
{
  if (test(self)) {
    if (![[found valueForKey:@"description"] containsObject:self.description]) [found addObject:self];
    return;
  }
  [self.operand addPartsPassingTest:test to:found];
  [self.left addPartsPassingTest:test to:found];
  [self.right addPartsPassingTest:test to:found];
  [self.body addPartsPassingTest:test to:found];
  for (ODataExpression *argument in self.arguments) [argument addPartsPassingTest:test to:found];
  for (NSString *name in [self.namedArguments.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [self.namedArguments[name] addPartsPassingTest:test to:found];
  }
}

- (NSArray *)partsPassingTest:(BOOL (^)(ODataExpression *))test
{
  NSMutableArray *found = [NSMutableArray array];
  [self addPartsPassingTest:test to:found];
  return found;
}

- (NSArray *)aggregatesOfThese
{
  return [self partsPassingTest:^BOOL(ODataExpression *part) {
    BOOL these = part.operand.kind == ODataExpressionVariable && [part.operand.name isEqualToString:@"$these"];
    return these && (part.kind == ODataExpressionCount || part.aggregate);
  }];
}

+ (instancetype)literalWithValue:(id)value
{
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionLiteral name:@""];
  if (!value || value == [NSNull null]) return e;
  e.value = value;
  if ([value isKindOfClass:[NSString class]]) {
    e.literalType = @"Edm.String";
  } else if ([value isKindOfClass:[NSNumber class]]) {
    const char *type = [value objCType];
#ifdef __APPLE__
    BOOL boolean = CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
#else
    BOOL boolean = strcmp(type, @encode(BOOL)) == 0 || strcmp(type, @encode(bool)) == 0;
#endif
    e.literalType = boolean ? @"Edm.Boolean"
                  : [value isKindOfClass:[NSDecimalNumber class]] ? @"Edm.Decimal"
                  : (strcmp(type, @encode(double)) == 0 || strcmp(type, @encode(float)) == 0) ? @"Edm.Double" : @"Edm.Int64";
  }
  return e;
}

+ (instancetype)literalWithText:(NSString *)text
{
  ODataExpression *e = [ODataExpression expressionWithString:text error:NULL];
  return e.kind == ODataExpressionLiteral || (e.kind == ODataExpressionUnary && e.operand.kind == ODataExpressionLiteral) ? e : nil;
}

+ (instancetype)member:(NSString *)name of:(ODataExpression *)operand
{
  OISRequire(OISIsODataIdentifier(name), @"a member name must be an OData identifier;", name);
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionMember name:name];
  e.operand = operand;
  return e;
}

+ (instancetype)memberPath:(NSArray<NSString *> *)path of:(ODataExpression *)operand
{
  ODataExpression *e = operand;
  for (NSString *name in path) e = [self member:name of:e];
  return e;
}

+ (instancetype)variable:(NSString *)name
{
  OISRequire(OISIsVariableName(name), @"a variable must be $it, $root, $these, $this or an OData identifier;", name);
  return [ODataExpression ofKind:ODataExpressionVariable name:name];
}

+ (instancetype)alias:(NSString *)name
{
  NSString *bare = [name hasPrefix:@"@"] ? [name substringFromIndex:1] : name;
  OISRequire(OISIsODataIdentifier(bare), @"a parameter alias must be @ and an OData identifier;", name);
  return [ODataExpression ofKind:ODataExpressionAlias name:bare];
}

+ (instancetype)binary:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right
{
  OISRequire(OISPrecedence(op) > 0, @"a binary operator must be one of eq ne gt ge lt le has in and or add sub mul div divby mod;", op);
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionBinary name:op];
  e.left = left;
  e.right = right;
  return e;
}

+ (instancetype)unary:(NSString *)op operand:(ODataExpression *)operand
{
  OISRequire([op isEqualToString:@"not"] || [op isEqualToString:@"-"], @"a unary operator must be not or -;", op);
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionUnary name:op];
  e.operand = operand;
  return e;
}

+ (instancetype)call:(NSString *)name arguments:(NSArray<ODataExpression *> *)arguments
{
  OISRequire(OISIsODataIdentifier(name) || OISIsQualifiedName(name), @"a function name must be an OData identifier or a qualified name;", name);
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionCall name:name];
  e.arguments = arguments ?: @[];
  return e;
}

+ (instancetype)call:(NSString *)name of:(ODataExpression *)operand namedArguments:(NSDictionary *)namedArguments
{
  OISRequire(OISIsODataIdentifier(name) || OISIsQualifiedName(name), @"a function name must be an OData identifier or a qualified name;", name);
  for (NSString *parameter in namedArguments) {
    OISRequire(OISIsODataIdentifier(parameter), @"a parameter name must be an OData identifier;", parameter);
  }
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionCall name:name];
  e.operand = operand;
  e.arguments = @[];
  e.namedArguments = namedArguments ?: @{};
  return e;
}

+ (instancetype)lambda:(NSString *)name of:(ODataExpression *)collection variable:(NSString *)variable body:(ODataExpression *)body
{
  OISRequire([name isEqualToString:@"any"] || [name isEqualToString:@"all"], @"a lambda must be any or all;", name);
  if (body) OISRequire(OISIsODataIdentifier(variable), @"a lambda variable must be an OData identifier;", variable);
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionLambda name:name];
  e.operand = collection;
  e.variable = body ? variable : nil;
  e.body = body;
  return e;
}

+ (instancetype)countOf:(ODataExpression *)collection
{
  return [self countOf:collection filter:nil];
}

+ (instancetype)countOf:(ODataExpression *)collection filter:(ODataExpression *)filter
{
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionCount name:@"$count"];
  e.operand = collection;
  e.body = filter;
  return e;
}

- (ODataExpression *)countFilter
{
  return self.kind == ODataExpressionCount ? self.body : nil;
}

+ (instancetype)cast:(NSString *)type of:(ODataExpression *)operand
{
  OISRequire(OISIsQualifiedName(type), @"a cast must name a qualified type (NS.Type, Edm.String);", type);
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionCast name:type];
  e.operand = operand;
  return e;
}

+ (instancetype)list:(NSArray<ODataExpression *> *)items
{
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionList name:@""];
  e.arguments = items;
  return e;
}

+ (instancetype)aggregateOf:(ODataExpression *)collection text:(NSString *)text
{
  // The aggregate expression in $apply's syntax, as the parser reads one.
  NSArray *transformations = [ODataApplyTransformation transformationsWithString:[NSString stringWithFormat:@"aggregate(%@ as value)", text] error:NULL];
  ODataApplyTransformation *only = transformations.count == 1 ? transformations.firstObject : nil;
  if (only.aggregates.count != 1) return nil;
  ODataExpression *call = [ODataExpression ofKind:ODataExpressionCall name:@"aggregate"];
  call.operand = collection;
  call.arguments = @[];
  call.aggregate = only.aggregates.firstObject;
  call.aggregateText = text;
  return call;
}

+ (instancetype)aggregateOf:(ODataExpression *)collection aggregate:(id)aggregate
{
  if (![aggregate isKindOfClass:[ODataAggregate class]]) return nil;
  ODataAggregate *a = aggregate;
  // A custom aggregate named alone, or an expression's: not written here.
  // (A custom method, NS.median, is isCustom too, and is taken below.)
  if (a.custom || a.expression) return nil;
  if (a.path && !a.path.count) return nil;
  for (NSString *name in a.path ?: @[]) {
    if (!OISIsODataIdentifier(name)) return nil;
  }
  NSString *text = nil;
  if (!a.path) {
    // $count of the collection; a method needs a path.
    if (a.method && ![a.method isEqualToString:@"$count"]) return nil;
    text = @"$count";
  } else if (a.isCount) {
    text = [[a.path componentsJoinedByString:@"/"] stringByAppendingString:@"/$count"];
  } else {
    NSSet *methods = [NSSet setWithObjects:@"sum", @"min", @"max", @"average", @"countdistinct", nil];
    if (!([methods containsObject:a.method] || OISIsQualifiedName(a.method))) return nil;
    text = [NSString stringWithFormat:@"%@ with %@", [a.path componentsJoinedByString:@"/"], a.method];
  }
  ODataExpression *call = [ODataExpression ofKind:ODataExpressionCall name:@"aggregate"];
  call.operand = collection;
  call.arguments = @[];
  call.aggregate = a;
  call.aggregateText = text;
  return call;
}

+ (instancetype)expression:(ODataExpression *)e inValues:(NSArray *)values
{
  if (!values.count) return [self literalWithValue:@NO];
  ODataExpression *list = [ODataExpression ofKind:ODataExpressionList name:@""];
  NSMutableArray *items = [NSMutableArray array];
  for (id value in values) [items addObject:[self literalWithValue:value]];
  list.arguments = items;
  ODataExpression *in = [ODataExpression ofKind:ODataExpressionBinary name:@"in"];
  in.left = e;
  in.right = list;
  return in;
}

- (ODataExpression *)expressionReplacing:(NSDictionary *)values
{
  id value = values[self.description];
  if ([value isKindOfClass:[ODataExpression class]]) return value;
  if (value) return [ODataExpression literalWithValue:value];
  ODataExpression *e = [ODataExpression ofKind:self.kind name:self.name];
  e.value = self.value;
  e.literalType = self.literalType;
  e.raw = self.raw;
  e.operand = [self.operand expressionReplacing:values];
  e.left = [self.left expressionReplacing:values];
  e.right = [self.right expressionReplacing:values];
  e.variable = self.variable;
  e.body = [self.body expressionReplacing:values];
  e.aggregate = self.aggregate;
  e.aggregateText = self.aggregateText;
  if (self.arguments) {
    NSMutableArray *arguments = [NSMutableArray array];
    for (ODataExpression *argument in self.arguments) [arguments addObject:[argument expressionReplacing:values]];
    e.arguments = arguments;
  }
  if (self.namedArguments) {
    NSMutableDictionary *named = [NSMutableDictionary dictionary];
    for (NSString *key in self.namedArguments) named[key] = [self.namedArguments[key] expressionReplacing:values];
    e.namedArguments = named;
  }
  return e;
}

+ (instancetype)expressionWithString:(NSString *)text error:(NSError **)error
{
  OISParser *parser = [[OISParser alloc] initWithString:text];
  ODataExpression *e = [parser parseCommon];
  if (e && ![parser atEnd]) e = nil;
  if (!e && error) *error = parser.error ?: OISError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"Cannot read \"%@\"", text]);
  return e;
}

- (NSArray *)memberPath
{
  if (self.kind != ODataExpressionMember) return nil;
  if (!self.operand) return @[ self.name ];
  NSArray *before = self.operand.memberPath;
  return before ? [before arrayByAddingObject:self.name] : nil;
}

@end

@implementation ODataOrderItem
+ (instancetype)itemWithExpression:(ODataExpression *)expression descending:(BOOL)descending
{
  return [[self alloc] initWithExpression:expression descending:descending];
}
- (instancetype)initWithExpression:(ODataExpression *)expression descending:(BOOL)descending
{
  self = [super init];
  if (!self) return nil;
  _expression = expression;
  _descending = descending;
  return self;
}
- (NSString *)description
{
  return self.descending ? [NSString stringWithFormat:@"%@ desc", self.expression] : self.expression.description;
}
@end

@implementation ODataSelectItem
+ (instancetype)itemWithPath:(NSArray<NSString *> *)path
{
  return [[self alloc] initWithPath:path star:[path isEqual:@[ @"*" ]]];
}
- (instancetype)initWithPath:(NSArray *)path star:(BOOL)star
{
  self = [super init];
  if (!self) return nil;
  _path = [path copy];
  _isStar = star;
  return self;
}
- (NSString *)description
{
  return self.isStar ? @"*" : [self.path componentsJoinedByString:@"/"];
}
@end

@interface ODataQueryOptions ()
- (void)setTemporal:(NSString *)option expression:(ODataExpression *)e text:(NSString *)text;
@property (nonatomic, strong, nullable) ODataExpression *filter;
@property (nonatomic, copy) NSArray *orderBy;
@property (nonatomic, copy) NSArray *select;
@property (nonatomic, copy) NSArray *expand;
@property (nonatomic, strong, nullable) NSNumber *top;
@property (nonatomic, strong, nullable) NSNumber *skip;
@property (nonatomic, strong, nullable) NSNumber *includeCount;
@property (nonatomic, strong, nullable) NSNumber *levels;
@property (nonatomic, copy, nullable) NSString *search;
@property (nonatomic, strong, nullable) ODataSearchExpression *searchExpression;
@property (nonatomic, copy, nullable) NSArray *apply;
@property (nonatomic, copy) NSArray *compute;
@property (nonatomic, strong, nullable) ODataExpression *temporalAt;
@property (nonatomic, strong, nullable) ODataExpression *temporalFrom;
@property (nonatomic, strong, nullable) ODataExpression *temporalTo;
@property (nonatomic, strong, nullable) ODataExpression *temporalToInclusive;
@property (nonatomic, copy) NSDictionary *temporalText;
@property (nonatomic, copy) NSDictionary *aliases;
@property (nonatomic, copy, nullable) NSString *format;
@property (nonatomic, copy, nullable) NSString *skipToken;
@property (nonatomic, copy) NSDictionary *customOptions;
@end

@interface ODataComputeItem ()
@property (nonatomic, strong) ODataExpression *expression;
@property (nonatomic, copy) NSString *alias;
@end

@implementation ODataComputeItem
+ (instancetype)itemWithExpression:(ODataExpression *)expression alias:(NSString *)alias
{
  ODataComputeItem *item = [[self alloc] init];
  item.expression = expression;
  item.alias = alias;
  return item;
}
- (NSString *)description
{
  return [NSString stringWithFormat:@"%@ as %@", self.expression, self.alias];
}
@end

// $compute: items at the commas outside parentheses and quotes, each an
// expression, "as", and a name.
static NSArray *OISComputeItems(NSString *text, NSError **error)
{
  NSMutableArray *pieces = [NSMutableArray array];
  NSInteger depth = 0, start = 0;
  BOOL quoted = NO;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c == '\'') quoted = !quoted;
    if (quoted) continue;
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == ',' && depth == 0) {
      [pieces addObject:[text substringWithRange:NSMakeRange((NSUInteger)start, i - (NSUInteger)start)]];
      start = (NSInteger)i + 1;
    }
  }
  [pieces addObject:[text substringFromIndex:(NSUInteger)start]];
  NSRegularExpression *as = [NSRegularExpression regularExpressionWithPattern:@"^(.*\\S)\\s+as\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*$" options:0 error:NULL];
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *piece in pieces) {
    NSString *trimmed = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSTextCheckingResult *match = [as firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    ODataExpression *expression = match ? [ODataExpression expressionWithString:[trimmed substringWithRange:[match rangeAtIndex:1]] error:error] : nil;
    if (!expression) {
      if (error && !*error) *error = OISError(ODataIncrementalStoreErrorSyntax,
                                              [NSString stringWithFormat:@"$compute=%@: each item is an expression as a name", trimmed]);
      return nil;
    }
    ODataComputeItem *item = [[ODataComputeItem alloc] init];
    item.expression = expression;
    item.alias = [trimmed substringWithRange:[match rangeAtIndex:2]];
    [items addObject:item];
  }
  return items;
}

@interface ODataExpandItem ()
@property (nonatomic, copy) NSArray *path;
@property (nonatomic) BOOL isStar;
@property (nonatomic) BOOL isRef;
@property (nonatomic) BOOL isCount;
@property (nonatomic, strong) ODataQueryOptions *options;
@end

@implementation ODataExpandItem
+ (instancetype)itemWithPath:(NSArray<NSString *> *)path options:(ODataQueryOptions *)options
{
  ODataExpandItem *item = [[self alloc] init];
  item.path = path;
  item.isStar = [path isEqual:@[ @"*" ]];
  item.options = options ?: [[ODataQueryOptions alloc] init];
  return item;
}
- (NSString *)description
{
  NSMutableString *text = [NSMutableString stringWithString:self.isStar ? @"*" : [self.path componentsJoinedByString:@"/"]];
  if (self.isRef) [text appendString:@"/$ref"];
  if (self.isCount) [text appendString:@"/$count"];
  NSString *options = self.options.description;
  if (options.length) [text appendFormat:@"(%@)", options];
  return text;
}
@end

@interface ODataPathSegment ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSDictionary *keys;
@property (nonatomic, copy, nullable) NSDictionary *arguments;
@property (nonatomic) BOOL isCall;
@end

@implementation ODataPathSegment
- (NSString *)description
{
  NSDictionary *inside = self.isCall ? self.arguments : self.keys;
  if (!inside) return self.name;
  if (inside.count == 1 && inside[@""]) return [NSString stringWithFormat:@"%@(%@)", self.name, inside[@""]];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *key in [inside.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [parts addObject:[NSString stringWithFormat:@"%@=%@", key, inside[key]]];
  }
  return [NSString stringWithFormat:@"%@(%@)", self.name, [parts componentsJoinedByString:@","]];
}
@end

@interface ODataResourcePath ()
@property (nonatomic, copy) NSArray *segments;
@end

@implementation ODataResourcePath

+ (instancetype)pathWithString:(NSString *)text error:(NSError **)error
{
  OISParser *parser = [[OISParser alloc] initWithString:text];
  ODataResourcePath *path = [parser parseResourcePath];
  if (!path && error) *error = parser.error;
  return path;
}

- (NSString *)description
{
  NSMutableArray *parts = [NSMutableArray array];
  for (ODataPathSegment *segment in self.segments) [parts addObject:segment.description];
  return [parts componentsJoinedByString:@"/"];
}

@end

#pragma mark - The parser

@implementation OISParser {
  OISLexer *_lexer;
  OISToken *_token;
  OISToken *_ahead;
  NSMutableArray *_variables;  // lambda variables in scope
  NSInteger _depth;            // how deep in parentheses, not and minus, and $expand
}

// Deeper than any real request goes, and shallow enough that parsing it,
// and walking what it parses to, does not run out of stack.
static const NSInteger OISMaxNesting = 100;

- (instancetype)initWithString:(NSString *)string
{
  self = [super init];
  if (!self) return nil;
  _lexer = [[OISLexer alloc] initWithString:string];
  _token = [_lexer next];
  _variables = [NSMutableArray arrayWithObject:@"$it"];
  return self;
}

- (OISToken *)peek
{
  if (!_ahead) _ahead = [_lexer next];
  return _ahead;
}

- (void)advance
{
  if (_ahead) {
    _token = _ahead;
    _ahead = nil;
  } else {
    _token = [_lexer next];
  }
}

- (BOOL)accept:(OISTokenKind)kind
{
  if (_token.kind != kind) return NO;
  [self advance];
  return YES;
}

- (BOOL)isName:(NSString *)name
{
  return _token.kind == OISTokenName && [_token.text isEqualToString:name];
}

// The first error is the one reported; what follows it is noise.
- (id)fail:(NSString *)message
{
  if (!self.error) {
    NSString *text = [NSString stringWithFormat:@"%@ at %lu in \"%@\"", message, (unsigned long)_token.range.location, _lexer.string];
    self.error = OISError(ODataIncrementalStoreErrorSyntax, text);
  }
  return nil;
}

- (id)expect:(OISTokenKind)kind what:(NSString *)what
{
  if ([self accept:kind]) return @YES;
  return [self fail:[NSString stringWithFormat:@"%@ expected, not %@", what, _token]];
}

- (BOOL)atEnd
{
  if (_token.kind == OISTokenEnd) return YES;
  [self fail:[NSString stringWithFormat:@"unexpected %@", _token]];
  return NO;
}

#pragma mark Expressions

- (ODataExpression *)binary:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right
{
  if (!left || !right) return nil;
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionBinary name:op];
  e.left = left;
  e.right = right;
  return e;
}

// One level of left-associative binary operators.
- (ODataExpression *)parseLevel:(NSArray *)operators next:(SEL)next
{
  ODataExpression *(*sub)(id, SEL) = (ODataExpression * (*)(id, SEL))[self methodForSelector:next];
  ODataExpression *left = sub(self, next);
  while (left && _token.kind == OISTokenName && [operators containsObject:_token.text]) {
    NSString *op = _token.text;
    [self advance];
    left = [self binary:op left:left right:sub(self, next)];
  }
  return left;
}

- (ODataExpression *)parseCommon
{
  return [self parseLevel:@[ @"or" ] next:@selector(parseAnd)];
}

- (ODataExpression *)parseAnd
{
  return [self parseLevel:@[ @"and" ] next:@selector(parseEquality)];
}

- (ODataExpression *)parseEquality
{
  return [self parseLevel:@[ @"eq", @"ne" ] next:@selector(parseRelational)];
}

- (ODataExpression *)parseRelational
{
  return [self parseLevel:@[ @"gt", @"ge", @"lt", @"le", @"has", @"in" ] next:@selector(parseAdditive)];
}

- (ODataExpression *)parseAdditive
{
  return [self parseLevel:@[ @"add", @"sub" ] next:@selector(parseMultiplicative)];
}

- (ODataExpression *)parseMultiplicative
{
  return [self parseLevel:@[ @"mul", @"div", @"divby", @"mod" ] next:@selector(parseUnary)];
}

- (ODataExpression *)parseUnary
{
  if (++_depth > OISMaxNesting) {
    _depth--;
    return [self fail:@"nested too deep"];
  }
  ODataExpression *e = [self parseUnaryUnchecked];
  _depth--;
  return e;
}

- (ODataExpression *)parseUnaryUnchecked
{
  if ([self isName:@"not"]) {
    [self advance];
    ODataExpression *operand = [self parseUnary];
    if (!operand) return nil;
    ODataExpression *e = [ODataExpression ofKind:ODataExpressionUnary name:@"not"];
    e.operand = operand;
    return e;
  }
  if ([self accept:OISTokenMinus]) {
    ODataExpression *operand = [self parseUnary];
    if (!operand) return nil;
    ODataExpression *e = [ODataExpression ofKind:ODataExpressionUnary name:@"-"];
    e.operand = operand;
    return e;
  }
  return [self parsePrimary];
}

- (ODataExpression *)literal:(id)value type:(NSString *)type raw:(NSString *)raw
{
  ODataExpression *e = [ODataExpression ofKind:ODataExpressionLiteral name:@""];
  e.value = value;
  e.literalType = type;
  e.raw = raw;
  return e;
}

// A comma-separated list up to a closing token.
- (NSArray *)parseListUntil:(OISTokenKind)closing
{
  NSMutableArray *items = [NSMutableArray array];
  if ([self accept:closing]) return items;
  while (YES) {
    ODataExpression *item = [self parseCommon];
    if (!item) return nil;
    [items addObject:item];
    if ([self accept:OISTokenComma]) continue;
    if (![self expect:closing what:closing == OISTokenRParen ? @"')'" : @"']'"]) return nil;
    return items;
  }
}

- (ODataExpression *)parsePrimary
{
  OISToken *t = _token;
  switch (t.kind) {
    case OISTokenLParen: {
      [self advance];
      NSArray *items = [self parseListUntil:OISTokenRParen];
      if (!items) return nil;
      if (items.count == 1) return items[0];  // grouping
      ODataExpression *list = [ODataExpression ofKind:ODataExpressionList name:@""];
      list.arguments = items;
      return list;
    }
    case OISTokenLBracket: {
      [self advance];
      NSArray *items = [self parseListUntil:OISTokenRBracket];
      if (!items) return nil;
      ODataExpression *list = [ODataExpression ofKind:ODataExpressionList name:@""];
      list.arguments = items;
      return list;
    }
    case OISTokenString:
      [self advance];
      return [self literal:t.text type:@"Edm.String" raw:OISQuoted(t.text)];
    case OISTokenNumber: {
      [self advance];
      NSString *text = t.text;
      if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"eE"]].location != NSNotFound) {
        return [self literal:@([text doubleValue]) type:@"Edm.Double" raw:text];
      }
      if ([text rangeOfString:@"."].location != NSNotFound || text.length > 18) {
        NSDecimalNumber *d = [NSDecimalNumber decimalNumberWithString:text locale:@{ NSLocaleDecimalSeparator: @"." }];
        return [self literal:d type:@"Edm.Decimal" raw:text];
      }
      return [self literal:@([text longLongValue]) type:@"Edm.Int64" raw:text];
    }
    case OISTokenTyped: {
      [self advance];
      NSString *prefix = t.type;
      NSString *raw = [_lexer.string substringWithRange:t.range];
      if ([prefix hasPrefix:@"Edm."]) return [self literal:t.text type:prefix raw:raw];
      NSDictionary *prefixed = @{ @"duration": @"Edm.Duration", @"binary": @"Edm.Binary", @"X": @"Edm.Binary",
                                  @"geography": @"Edm.Geography", @"geometry": @"Edm.Geometry" };
      return [self literal:t.text type:prefixed[prefix] ?: prefix raw:raw];
    }
    case OISTokenAlias:
      [self advance];
      return [self parsePathAfter:[ODataExpression ofKind:ODataExpressionAlias name:t.text]];
    case OISTokenName:
      return [self parseName];
    default:
      return [self fail:[NSString stringWithFormat:@"unexpected %@", t]];
  }
}

- (ODataExpression *)parseName
{
  NSString *name = _token.text;
  static NSDictionary *constants;
  if (!constants) {
    constants = @{ @"null": @[ [NSNull null], @"" ], @"true": @[ @YES, @"Edm.Boolean" ], @"false": @[ @NO, @"Edm.Boolean" ],
                   @"INF": @[ @(INFINITY), @"Edm.Double" ], @"NaN": @[ @(NAN), @"Edm.Double" ] };
  }
  NSArray *constant = constants[name];
  if (constant) {
    [self advance];
    return [self literal:constant[0] type:[constant[1] length] ? constant[1] : nil raw:name];
  }
  [self advance];
  ODataExpression *e;
  if (_token.kind == OISTokenLParen) {
    e = [self parseCallNamed:name];
  } else if ([_variables containsObject:name] || [@[ @"$root", @"$these", @"$this" ] containsObject:name]) {
    e = [ODataExpression ofKind:ODataExpressionVariable name:name];
  } else if ([name rangeOfString:@"."].location != NSNotFound) {
    e = [ODataExpression ofKind:ODataExpressionCast name:name];
  } else {
    e = [ODataExpression ofKind:ODataExpressionMember name:name];
  }
  return e ? [self parsePathAfter:e] : nil;
}

// name(...): a canonical function's arguments in order; a service's
// function (a qualified name) by name, p=value.
- (ODataExpression *)parseCallNamed:(NSString *)name
{
  [self advance];  // (
  ODataExpression *call = [ODataExpression ofKind:ODataExpressionCall name:name];
  if ([name rangeOfString:@"."].location != NSNotFound) {
    NSMutableDictionary *named = [NSMutableDictionary dictionary];
    if (![self accept:OISTokenRParen]) {
      while (YES) {
        if (_token.kind != OISTokenName) return [self fail:[NSString stringWithFormat:@"a parameter name expected, not %@", _token]];
        NSString *parameter = _token.text;
        [self advance];
        if (![self expect:OISTokenEquals what:@"'='"]) return nil;
        ODataExpression *value = [self parseCommon];
        if (!value) return nil;
        named[parameter] = value;
        if ([self accept:OISTokenComma]) continue;
        if (![self expect:OISTokenRParen what:@"')'"]) return nil;
        break;
      }
    }
    call.namedArguments = named;
    return call;
  }
  NSArray *arguments = [self parseListUntil:OISTokenRParen];
  if (!arguments) return nil;
  call.arguments = arguments;
  return call;
}

// What follows a path's start: /Member, /NS.Cast, /NS.Function(...),
// /$count, /any(x:...), /all(x:...).
- (ODataExpression *)parsePathAfter:(ODataExpression *)operand
{
  ODataExpression *current = operand;
  while (current && _token.kind == OISTokenSlash) {
    [self advance];
    if (_token.kind != OISTokenName) return [self fail:[NSString stringWithFormat:@"a name expected after '/', not %@", _token]];
    NSString *name = _token.text;
    [self advance];
    ODataExpression *next;
    if (([name isEqualToString:@"any"] || [name isEqualToString:@"all"]) && _token.kind == OISTokenLParen) {
      next = [self parseLambda:name over:current];
    } else if ([name isEqualToString:@"$count"]) {
      next = [ODataExpression ofKind:ODataExpressionCount name:name];
      next.operand = current;
      if (_token.kind == OISTokenLParen && ![self parseCountOptionsOf:next]) return nil;
    } else if ([name isEqualToString:@"aggregate"] && _token.kind == OISTokenLParen) {
      next = [self parseAggregateOf:current];
    } else if (_token.kind == OISTokenLParen) {
      next = [self parseCallNamed:name];
      next.operand = current;
    } else {
      next = [ODataExpression ofKind:[name rangeOfString:@"."].location != NSNotFound ? ODataExpressionCast : ODataExpressionMember name:name];
      next.operand = current;
    }
    current = next;
  }
  return current;
}

// collection/$count($filter=...): the members counted, those that pass
// (4.01 ABNF collectionPathExpr: count [ OPEN expandCountOption *( SEMI
// expandCountOption ) CLOSE ], an option $filter or $search, with or
// without the $). One $filter; $search is not supported here.
- (BOOL)parseCountOptionsOf:(ODataExpression *)count
{
  [self advance];  // (
  while (YES) {
    if (_token.kind != OISTokenName) {
      [self fail:[NSString stringWithFormat:@"$filter expected in $count(...), not %@", _token]];
      return NO;
    }
    NSString *option = _token.text;
    if ([option isEqualToString:@"$search"] || [option isEqualToString:@"search"]) {
      if (!self.error) self.error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, @"$search in $count(...) is not supported");
      return NO;
    }
    if (!([option isEqualToString:@"$filter"] || [option isEqualToString:@"filter"])) {
      [self fail:[NSString stringWithFormat:@"$filter expected in $count(...), not %@", option]];
      return NO;
    }
    if (count.body) {
      [self fail:@"one $filter in $count(...)"];
      return NO;
    }
    [self advance];
    if (![self expect:OISTokenEquals what:@"'='"]) return NO;
    ODataExpression *filter = [self parseCommon];
    if (!filter) return NO;
    count.body = filter;
    if ([self accept:OISTokenSemicolon]) continue;
    return [self expect:OISTokenRParen what:@"')'"] != nil;
  }
}

// collection/aggregate(aggregate expression): the argument is $apply's
// syntax (Amount with sum), not an expression's, and is read as that.
- (ODataExpression *)parseAggregateOf:(ODataExpression *)collection
{
  NSUInteger start = NSMaxRange(_token.range);
  NSInteger depth = 0;
  while (_token.kind != OISTokenEnd) {
    if (_token.kind == OISTokenLParen) depth++;
    if (_token.kind == OISTokenRParen && --depth == 0) break;
    [self advance];
  }
  if (_token.kind != OISTokenRParen) return [self fail:@"')' expected after aggregate("];
  NSString *text = [[_lexer.string substringWithRange:NSMakeRange(start, _token.range.location - start)]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  [self advance];  // )
  NSError *error = nil;
  NSArray *transformations = [ODataApplyTransformation transformationsWithString:[NSString stringWithFormat:@"aggregate(%@ as value)", text] error:&error];
  ODataApplyTransformation *only = transformations.count == 1 ? transformations.firstObject : nil;
  if (only.aggregates.count != 1) {
    if (!self.error) self.error = error ?: OISError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"aggregate(%@): one aggregate expression", text]);
    return nil;
  }
  ODataExpression *call = [ODataExpression ofKind:ODataExpressionCall name:@"aggregate"];
  call.operand = collection;
  call.arguments = @[];
  call.aggregate = only.aggregates.firstObject;
  call.aggregateText = text;
  return call;
}

- (ODataExpression *)parseLambda:(NSString *)name over:(ODataExpression *)collection
{
  [self advance];  // (
  ODataExpression *lambda = [ODataExpression ofKind:ODataExpressionLambda name:name];
  lambda.operand = collection;
  if ([self accept:OISTokenRParen]) {
    if ([name isEqualToString:@"all"]) return [self fail:@"all() needs a variable and a condition"];
    return lambda;
  }
  if (_token.kind != OISTokenName) return [self fail:[NSString stringWithFormat:@"a lambda variable expected, not %@", _token]];
  NSString *variable = _token.text;
  [self advance];
  if (![self expect:OISTokenColon what:@"':'"]) return nil;
  [_variables addObject:variable];
  ODataExpression *body = [self parseCommon];
  [_variables removeLastObject];
  if (!body || ![self expect:OISTokenRParen what:@"')'"]) return nil;
  lambda.variable = variable;
  lambda.body = body;
  return lambda;
}

#pragma mark Query options

// A path of names joined by '/': Category/Name, NS.Type/Prop.
- (NSArray *)parseNamePath
{
  NSMutableArray *path = [NSMutableArray array];
  while (YES) {
    if (_token.kind != OISTokenName) return [self fail:[NSString stringWithFormat:@"a name expected, not %@", _token]];
    [path addObject:_token.text];
    [self advance];
    if (_token.kind == OISTokenSlash && [self peek].kind == OISTokenName && ![[self peek].text hasPrefix:@"$"]) {
      [self advance];
      continue;
    }
    return path;
  }
}

- (NSArray *)parseOrderBy
{
  NSMutableArray *items = [NSMutableArray array];
  while (YES) {
    ODataExpression *expression = [self parseCommon];
    if (!expression) return nil;
    BOOL descending = NO;
    if ([self isName:@"desc"] || [self isName:@"asc"]) {
      descending = [_token.text isEqualToString:@"desc"];
      [self advance];
    }
    [items addObject:[[ODataOrderItem alloc] initWithExpression:expression descending:descending]];
    if (![self accept:OISTokenComma]) return items;
  }
}

- (NSArray *)parseSelect
{
  NSMutableArray *items = [NSMutableArray array];
  while (YES) {
    if ([self accept:OISTokenStar]) {
      [items addObject:[[ODataSelectItem alloc] initWithPath:@[] star:YES]];
    } else {
      NSArray *path = [self parseNamePath];
      if (!path) return nil;
      if (_token.kind == OISTokenSlash && [self peek].kind == OISTokenStar) {  // NS.Type/*
        [self advance];
        [self advance];
        path = [path arrayByAddingObject:@"*"];
      }
      [items addObject:[[ODataSelectItem alloc] initWithPath:path star:NO]];
    }
    if (![self accept:OISTokenComma]) return items;
  }
}

- (NSArray *)parseExpand
{
  if (++_depth > OISMaxNesting) {
    _depth--;
    return [self fail:@"$expand nested too deep"];
  }
  NSArray *items = [self parseExpandUnchecked];
  _depth--;
  return items;
}

- (NSArray *)parseExpandUnchecked
{
  NSMutableArray *items = [NSMutableArray array];
  while (YES) {
    ODataExpandItem *item = [[ODataExpandItem alloc] init];
    item.options = [[ODataQueryOptions alloc] init];
    if ([self accept:OISTokenStar]) {
      item.isStar = YES;
      item.path = @[];
    } else {
      NSArray *path = [self parseNamePath];
      if (!path) return nil;
      item.path = path;
    }
    if (_token.kind == OISTokenSlash) {
      [self advance];
      if ([self isName:@"$ref"]) item.isRef = YES;
      else if ([self isName:@"$count"]) item.isCount = YES;
      else return [self fail:[NSString stringWithFormat:@"$ref or $count expected, not %@", _token]];
      [self advance];
    }
    if ([self accept:OISTokenLParen]) {
      // Nested options, separated by ';' (Part 2 section 5.1.3).
      while (YES) {
        if (_token.kind != OISTokenName || ![_token.text hasPrefix:@"$"]) {
          return [self fail:[NSString stringWithFormat:@"a query option expected, not %@", _token]];
        }
        NSString *option = _token.text;
        [self advance];
        if (![self expect:OISTokenEquals what:@"'='"] || ![self parseOption:option into:item.options]) return nil;
        if ([self accept:OISTokenSemicolon]) continue;
        if (![self expect:OISTokenRParen what:@"';' or ')'"]) return nil;
        break;
      }
    }
    [items addObject:item];
    if (![self accept:OISTokenComma]) return items;
  }
}

- (NSNumber *)parseCountValue
{
  if ([self isName:@"true"] || [self isName:@"false"]) {
    NSNumber *value = @([_token.text isEqualToString:@"true"]);
    [self advance];
    return value;
  }
  return [self fail:[NSString stringWithFormat:@"true or false expected, not %@", _token]];
}

- (NSNumber *)parseInteger
{
  if (_token.kind != OISTokenNumber || [_token.text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".eE-"]].location != NSNotFound) {
    return [self fail:[NSString stringWithFormat:@"a whole number expected, not %@", _token]];
  }
  NSNumber *value = @([_token.text longLongValue]);
  [self advance];
  return value;
}

// One system query option's value, into the options. Its text is what the
// parser is at.
- (BOOL)parseOption:(NSString *)option into:(ODataQueryOptions *)options
{
  if ([option isEqualToString:@"$filter"]) {
    options.filter = [self parseCommon];
    return options.filter != nil;
  }
  if ([option isEqualToString:@"$orderby"]) {
    options.orderBy = [self parseOrderBy];
    return options.orderBy != nil;
  }
  if ([option isEqualToString:@"$select"]) {
    options.select = [self parseSelect];
    return options.select != nil;
  }
  if ([option isEqualToString:@"$expand"]) {
    options.expand = [self parseExpand];
    return options.expand != nil;
  }
  if ([option isEqualToString:@"$top"]) {
    options.top = [self parseInteger];
    return options.top != nil;
  }
  if ([option isEqualToString:@"$skip"]) {
    options.skip = [self parseInteger];
    return options.skip != nil;
  }
  if ([option isEqualToString:@"$count"]) {
    options.includeCount = [self parseCountValue];
    return options.includeCount != nil;
  }
  if ([option isEqualToString:@"$levels"]) {
    if ([self isName:@"max"]) {
      [self advance];
      options.levels = @-1;
      return YES;
    }
    options.levels = [self parseInteger];
    return options.levels != nil;
  }
  if ([@[ @"$at", @"$from", @"$to", @"$toInclusive" ] containsObject:option]) {
    // A literal, kept as written for the filter made of it.
    NSUInteger start = _token.range.location;
    ODataExpression *e = [self parseCommon];
    if (!e) return NO;
    NSUInteger end = _token.kind == OISTokenEnd ? _lexer.string.length : _token.range.location;
    [options setTemporal:option expression:e
                    text:[[_lexer.string substringWithRange:NSMakeRange(start, end - start)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    return YES;
  }
  if ([option isEqualToString:@"$compute"]) {
    // Items as the top level reads them, up to the end of the option.
    NSUInteger start = _token.range.location;
    NSInteger depth = 0;
    while (_token.kind != OISTokenEnd && !(depth == 0 && (_token.kind == OISTokenSemicolon || _token.kind == OISTokenRParen))) {
      if (_token.kind == OISTokenLParen) depth++;
      if (_token.kind == OISTokenRParen) depth--;
      [self advance];
    }
    NSUInteger end = _token.kind == OISTokenEnd ? _lexer.string.length : _token.range.location;
    NSError *error = nil;
    options.compute = OISComputeItems([_lexer.string substringWithRange:NSMakeRange(start, end - start)], &error);
    if (!options.compute) {
      if (!self.error) self.error = error;
      return NO;
    }
    return YES;
  }
  if ([option isEqualToString:@"$search"]) {
    // Its own grammar; kept as written, up to the end of the option.
    NSUInteger start = _token.range.location;
    NSInteger depth = 0;
    while (_token.kind != OISTokenEnd && !(depth == 0 && (_token.kind == OISTokenSemicolon || _token.kind == OISTokenRParen))) {
      if (_token.kind == OISTokenLParen) depth++;
      if (_token.kind == OISTokenRParen) depth--;
      [self advance];
    }
    NSUInteger end = _token.kind == OISTokenEnd ? _lexer.string.length : _token.range.location;
    options.search = [[_lexer.string substringWithRange:NSMakeRange(start, end - start)]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSError *error = nil;
    options.searchExpression = [ODataSearchExpression searchWithString:options.search error:&error];
    if (!options.searchExpression) {
      if (!self.error) self.error = error;
      return NO;
    }
    return YES;
  }
  [self fail:[NSString stringWithFormat:@"no query option %@", option]];
  return NO;
}

#pragma mark Resource paths

- (ODataResourcePath *)parseResourcePath
{
  NSMutableArray *segments = [NSMutableArray array];
  while (_token.kind != OISTokenEnd) {
    ODataPathSegment *segment = [[ODataPathSegment alloc] init];
    OISToken *t = _token;
    OISTokenKind next = [self peek].kind;
    // (Not an empty segment, Forms//Document: still none at all.)
    if (segments.count > 0 && t.kind != OISTokenSlash && next != OISTokenSlash && next != OISTokenEnd && next != OISTokenLParen) {
      // A key as a segment of its own, of more than one token
      // (Forms/a:b, Items/2024-01-01T10:00): as written, up to the next '/'.
      NSUInteger start = t.range.location;
      while (_token.kind != OISTokenSlash && _token.kind != OISTokenEnd) [self advance];
      NSUInteger end = _token.kind == OISTokenEnd ? _lexer.string.length : _token.range.location;
      segment.name = [_lexer.string substringWithRange:NSMakeRange(start, end - start)];
      [segments addObject:segment];
      if (_token.kind == OISTokenEnd) break;
      [self advance];
      continue;
    }
    if (t.kind == OISTokenName) {
      segment.name = t.text;
    } else if (t.kind == OISTokenNumber || t.kind == OISTokenString || t.kind == OISTokenTyped) {
      // A key as a segment of its own (Products/1): the service knows.
      segment.name = t.kind == OISTokenString ? t.text : [_lexer.string substringWithRange:t.range];
    } else {
      return [self fail:[NSString stringWithFormat:@"a path segment expected, not %@", t]];
    }
    [self advance];
    if ([self accept:OISTokenLParen]) {
      BOOL qualified = [segment.name rangeOfString:@"."].location != NSNotFound;
      NSMutableDictionary *parts = [NSMutableDictionary dictionary];
      if (![self accept:OISTokenRParen]) {
        while (YES) {
          if (_token.kind == OISTokenName && [self peek].kind == OISTokenEquals) {
            NSString *name = _token.text;
            [self advance];
            [self advance];
            ODataExpression *value = [self parseCommon];
            if (!value) return nil;
            parts[name] = value;
          } else {
            ODataExpression *value = [self parseCommon];
            if (!value) return nil;
            parts[@""] = value;
          }
          if ([self accept:OISTokenComma]) continue;
          if (![self expect:OISTokenRParen what:@"')'"]) return nil;
          break;
        }
      }
      if (qualified) {
        segment.isCall = YES;
        segment.arguments = parts;
      } else {
        segment.keys = parts;
      }
    }
    [segments addObject:segment];
    if (_token.kind == OISTokenEnd) break;
    if (![self expect:OISTokenSlash what:@"'/'"]) return nil;
  }
  ODataResourcePath *path = [[ODataResourcePath alloc] init];
  path.segments = segments;
  return path;
}

@end

#pragma mark - Entry points

@implementation ODataQueryOptions

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _orderBy = @[];
  _select = @[];
  _expand = @[];
  _compute = @[];
  _temporalText = @{};
  _aliases = @{};
  _customOptions = @{};
  return self;
}

- (id)copyWithZone:(NSZone *)zone
{
  return [self mutableCopyWithZone:zone];
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
  ODataMutableQueryOptions *copy = [[ODataMutableQueryOptions alloc] init];
  copy.filter = self.filter;
  copy.orderBy = self.orderBy;
  copy.select = self.select;
  copy.expand = self.expand;
  copy.top = self.top;
  copy.skip = self.skip;
  copy.includeCount = self.includeCount;
  copy.levels = self.levels;
  ((ODataQueryOptions *)copy).search = self.search;
  ((ODataQueryOptions *)copy).searchExpression = self.searchExpression;
  copy.apply = self.apply;
  copy.compute = self.compute;
  ((ODataQueryOptions *)copy).temporalAt = self.temporalAt;
  ((ODataQueryOptions *)copy).temporalFrom = self.temporalFrom;
  ((ODataQueryOptions *)copy).temporalTo = self.temporalTo;
  ((ODataQueryOptions *)copy).temporalToInclusive = self.temporalToInclusive;
  ((ODataQueryOptions *)copy).temporalText = self.temporalText;
  copy.aliases = self.aliases;
  copy.format = self.format;
  copy.skipToken = self.skipToken;
  copy.customOptions = self.customOptions;
  return copy;
}

+ (instancetype)optionsWithQuery:(NSDictionary *)query error:(NSError **)error
{
  ODataQueryOptions *options = [[ODataQueryOptions alloc] init];
  NSMutableDictionary *aliases = [NSMutableDictionary dictionary];
  for (NSString *key in [query.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *value = query[key];
    if (![value isKindOfClass:[NSString class]]) continue;
    OISParser *parser = [[OISParser alloc] initWithString:value];
    BOOL ok;
    if ([key hasPrefix:@"@"]) {
      ODataExpression *e = [parser parseCommon];
      ok = e && [parser atEnd];
      if (ok) aliases[[key substringFromIndex:1]] = e;
    } else if ([key hasPrefix:@"$"]) {
      // 4.01 allows system query options without the $; 4.0 does not.
      if ([key isEqualToString:@"$format"]) {
        options.format = value;
        continue;
      }
      if ([key isEqualToString:@"$skiptoken"]) {
        options.skipToken = value;
        continue;
      }
      NSArray *temporal = @[ @"$at", @"$from", @"$to", @"$toInclusive" ];
      if ([temporal containsObject:key]) {
        ODataExpression *e = [parser parseCommon];
        if (!e || ![parser atEnd]) {
          if (error) *error = parser.error ?: OISError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@=%@", key, value]);
          return nil;
        }
        [options setTemporal:key expression:e text:[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        continue;
      }
      if ([key isEqualToString:@"$compute"]) {
        options.compute = OISComputeItems(value, error);
        if (!options.compute) return nil;
        continue;
      }
      if ([key isEqualToString:@"$apply"]) {
        options.apply = [ODataApplyTransformation transformationsWithString:value error:error];
        if (!options.apply) return nil;
        continue;
      }
      if ([key isEqualToString:@"$search"]) {
        // Its own grammar, with "phrases" the OData lexer has no token for.
        options.search = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        options.searchExpression = [ODataSearchExpression searchWithString:options.search error:error];
        if (!options.searchExpression) return nil;
        continue;
      }
      if ([key isEqualToString:@"$deltatoken"] ||
          [key isEqualToString:@"$schemaversion"] || [key isEqualToString:@"$id"] || [key isEqualToString:@"$index"]) {
        continue;
      }
      ok = [parser parseOption:key into:options] && [parser atEnd];
    } else {
      NSMutableDictionary *custom = [options.customOptions mutableCopy];
      custom[key] = value;
      options.customOptions = custom;
      continue;
    }
    if (!ok) {
      if (error) *error = parser.error;
      return nil;
    }
  }
  options.aliases = aliases;
  return options;
}

- (void)setTemporal:(NSString *)option expression:(ODataExpression *)e text:(NSString *)text
{
  // The ivars: a mutable copy's setters come back here.
  if ([option isEqualToString:@"$at"]) _temporalAt = e;
  else if ([option isEqualToString:@"$from"]) _temporalFrom = e;
  else if ([option isEqualToString:@"$to"]) _temporalTo = e;
  else _temporalToInclusive = e;
  NSMutableDictionary *texts = [self.temporalText mutableCopy];
  if (e && text) texts[option] = text;
  else [texts removeObjectForKey:option];
  self.temporalText = texts;
}

- (NSArray<NSArray<NSString *> *> *)queryItems
{
  NSMutableArray *items = [NSMutableArray array];
  void (^add)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
    if (value) [items addObject:@[ name, value ]];
  };
  add(@"$at", self.temporalAt.description);
  add(@"$from", self.temporalFrom.description);
  add(@"$to", self.temporalTo.description);
  add(@"$toInclusive", self.temporalToInclusive.description);
  add(@"$filter", self.filter.description);
  add(@"$search", self.searchExpression ? self.searchExpression.description : self.search);
  if (self.apply.count) add(@"$apply", [ODataApplyTransformation stringForTransformations:self.apply]);
  if (self.orderBy.count) add(@"$orderby", [[self.orderBy valueForKey:@"description"] componentsJoinedByString:@","]);
  if (self.top) add(@"$top", self.top.stringValue);
  if (self.skip) add(@"$skip", self.skip.stringValue);
  if (self.includeCount) add(@"$count", self.includeCount.boolValue ? @"true" : @"false");
  if (self.compute.count) add(@"$compute", [[self.compute valueForKey:@"description"] componentsJoinedByString:@","]);
  if (self.select.count) add(@"$select", [[self.select valueForKey:@"description"] componentsJoinedByString:@","]);
  if (self.expand.count) add(@"$expand", [[self.expand valueForKey:@"description"] componentsJoinedByString:@","]);
  if (self.levels) add(@"$levels", self.levels.integerValue < 0 ? @"max" : self.levels.stringValue);
  add(@"$format", self.format);
  add(@"$skiptoken", self.skipToken);
  for (NSString *name in [self.aliases.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    add([@"@" stringByAppendingString:name], [self.aliases[name] description]);
  }
  for (NSString *name in [self.customOptions.allKeys sortedArrayUsingSelector:@selector(compare:)]) add(name, self.customOptions[name]);
  return items;
}

- (NSString *)description
{
  NSMutableArray *parts = [NSMutableArray array];
  if (self.filter) [parts addObject:[@"$filter=" stringByAppendingString:self.filter.description]];
  if (self.orderBy.count) [parts addObject:[@"$orderby=" stringByAppendingString:[[self.orderBy valueForKey:@"description"] componentsJoinedByString:@","]]];
  if (self.select.count) [parts addObject:[@"$select=" stringByAppendingString:[[self.select valueForKey:@"description"] componentsJoinedByString:@","]]];
  if (self.expand.count) [parts addObject:[@"$expand=" stringByAppendingString:[[self.expand valueForKey:@"description"] componentsJoinedByString:@","]]];
  if (self.top) [parts addObject:[NSString stringWithFormat:@"$top=%@", self.top]];
  if (self.skip) [parts addObject:[NSString stringWithFormat:@"$skip=%@", self.skip]];
  if (self.includeCount) [parts addObject:[NSString stringWithFormat:@"$count=%@", self.includeCount.boolValue ? @"true" : @"false"]];
  if (self.levels) [parts addObject:self.levels.integerValue < 0 ? @"$levels=max" : [NSString stringWithFormat:@"$levels=%@", self.levels]];
  if (self.search) [parts addObject:[@"$search=" stringByAppendingString:self.search]];
  if (self.compute.count) [parts addObject:[@"$compute=" stringByAppendingString:[[self.compute valueForKey:@"description"] componentsJoinedByString:@","]]];
  return [parts componentsJoinedByString:@";"];
}

@end


@implementation ODataMutableQueryOptions
@dynamic filter, orderBy, select, expand, top, skip, includeCount, levels, apply, compute, aliases, format, skipToken, customOptions;
@dynamic searchExpression, temporalAt, temporalFrom, temporalTo, temporalToInclusive;

- (void)setSearchExpression:(ODataSearchExpression *)searchExpression
{
  ((ODataQueryOptions *)self).search = searchExpression.description;
  [super setSearchExpression:searchExpression];
}

- (void)setTemporalAt:(ODataExpression *)e
{
  [self setTemporal:@"$at" expression:e text:e.description];
}

- (void)setTemporalFrom:(ODataExpression *)e
{
  [self setTemporal:@"$from" expression:e text:e.description];
}

- (void)setTemporalTo:(ODataExpression *)e
{
  [self setTemporal:@"$to" expression:e text:e.description];
}

- (void)setTemporalToInclusive:(ODataExpression *)e
{
  [self setTemporal:@"$toInclusive" expression:e text:e.description];
}

@end

#pragma mark - $search

@interface ODataSearchExpression ()
@property (nonatomic) ODataSearchKind kind;
@property (nonatomic, copy, nullable) NSString *text;
@property (nonatomic, strong, nullable) ODataSearchExpression *left;
@property (nonatomic, strong, nullable) ODataSearchExpression *right;
@end

// A recursive descent over characters: $search has a grammar of its own.
@interface OISSearchParser : NSObject {
@public
  NSString *_text;
  NSUInteger _at;
  NSError *_error;
  NSInteger _depth;
}
@end

@implementation OISSearchParser

- (void)skipSpace
{
  while (_at < _text.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[_text characterAtIndex:_at]]) _at++;
}

- (id)fail:(NSString *)message
{
  if (!_error) {
    _error = OISError(ODataIncrementalStoreErrorSyntax,
                      [NSString stringWithFormat:@"$search: %@ at %lu in \"%@\"", message, (unsigned long)_at, _text]);
  }
  return nil;
}

// The next word, not consumed; nil at a parenthesis, a quote or the end.
- (NSString *)peekWord
{
  [self skipSpace];
  NSUInteger end = _at;
  while (end < _text.length) {
    unichar c = [_text characterAtIndex:end];
    if (c == '(' || c == ')' || c == '"' || [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) break;
    end++;
  }
  return end > _at ? [_text substringWithRange:NSMakeRange(_at, end - _at)] : nil;
}

- (BOOL)atKeyword:(NSString *)keyword
{
  if (![[self peekWord] isEqualToString:keyword]) return NO;
  _at += keyword.length;
  return YES;
}

- (ODataSearchExpression *)parseOr
{
  ODataSearchExpression *left = [self parseAnd];
  while (left && [self atKeyword:@"OR"]) {
    ODataSearchExpression *right = [self parseAnd];
    if (!right) return nil;
    left = [ODataSearchExpression searchWithKind:ODataSearchOr text:nil left:left right:right];
  }
  return left;
}

- (BOOL)startsTerm
{
  [self skipSpace];
  if (_at >= _text.length) return NO;
  unichar c = [_text characterAtIndex:_at];
  if (c == ')') return NO;
  return ![[self peekWord] isEqualToString:@"OR"];
}

- (ODataSearchExpression *)parseAnd
{
  ODataSearchExpression *left = [self parseUnary];
  while (left) {
    BOOL explicitAnd = [self atKeyword:@"AND"];
    if (!explicitAnd && ![self startsTerm]) break;
    ODataSearchExpression *right = [self parseUnary];
    if (!right) return nil;
    left = [ODataSearchExpression searchWithKind:ODataSearchAnd text:nil left:left right:right];
  }
  return left;
}

- (ODataSearchExpression *)parseUnary
{
  if (++_depth > OISMaxNesting) {
    _depth--;
    return [self fail:@"nested too deep"];
  }
  ODataSearchExpression *e = [self parseUnaryUnchecked];
  _depth--;
  return e;
}

- (ODataSearchExpression *)parseUnaryUnchecked
{
  if ([self atKeyword:@"NOT"]) {
    ODataSearchExpression *operand = [self parseUnary];
    return operand ? [ODataSearchExpression searchWithKind:ODataSearchNot text:nil left:operand right:nil] : nil;
  }
  [self skipSpace];
  if (_at >= _text.length) return [self fail:@"a word or a phrase is missing"];
  unichar c = [_text characterAtIndex:_at];
  if (c == '(') {
    _at++;
    ODataSearchExpression *inner = [self parseOr];
    if (!inner) return nil;
    [self skipSpace];
    if (_at >= _text.length || [_text characterAtIndex:_at] != ')') return [self fail:@"a ) is missing"];
    _at++;
    return inner;
  }
  if (c == '"') {
    // "a phrase", with \" and \\ inside (4.01).
    NSMutableString *phrase = [NSMutableString string];
    _at++;
    while (_at < _text.length) {
      unichar d = [_text characterAtIndex:_at++];
      if (d == '"') {
        if (!phrase.length) return [self fail:@"a phrase is empty"];
        return [ODataSearchExpression searchWithKind:ODataSearchPhrase text:phrase left:nil right:nil];
      }
      if (d == '\\' && _at < _text.length) d = [_text characterAtIndex:_at++];
      [phrase appendFormat:@"%C", d];
    }
    return [self fail:@"a phrase is not closed"];
  }
  if (c == ')') return [self fail:@"a word or a phrase is missing"];
  NSString *word = [self peekWord];
  if ([word isEqualToString:@"AND"] || [word isEqualToString:@"OR"]) return [self fail:[NSString stringWithFormat:@"%@ needs a word before it", word]];
  _at += word.length;
  return [ODataSearchExpression searchWithKind:ODataSearchWord text:word left:nil right:nil];
}

@end

@implementation ODataSearchExpression

+ (instancetype)searchWithString:(NSString *)text error:(NSError **)error
{
  OISSearchParser *parser = [[OISSearchParser alloc] init];
  parser->_text = text ?: @"";
  ODataSearchExpression *e = [parser parseOr];
  [parser skipSpace];
  if (e && parser->_at < parser->_text.length) e = [parser fail:@"unexpected text"];
  if (!e && error) *error = parser->_error ?: OISError(ODataIncrementalStoreErrorSyntax, @"$search is empty");
  return e;
}

+ (instancetype)searchWithKind:(ODataSearchKind)kind text:(NSString *)text left:(ODataSearchExpression *)left right:(ODataSearchExpression *)right
{
  ODataSearchExpression *e = [[self alloc] init];
  e.kind = kind;
  e.text = text;
  e.left = left;
  e.right = right;
  return e;
}

- (ODataSearchExpression *)operand
{
  return self.kind == ODataSearchNot ? self.left : nil;
}

- (BOOL)matchesTexts:(NSArray<NSString *> *)texts
{
  switch (self.kind) {
    case ODataSearchWord:
    case ODataSearchPhrase:
      for (NSString *text in texts) {
        if (![text isKindOfClass:[NSString class]]) continue;
        if ([text rangeOfString:self.text options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) return YES;
      }
      return NO;
    case ODataSearchAnd: return [self.left matchesTexts:texts] && [self.right matchesTexts:texts];
    case ODataSearchOr: return [self.left matchesTexts:texts] || [self.right matchesTexts:texts];
    case ODataSearchNot: return ![self.left matchesTexts:texts];
  }
  return NO;
}

- (NSString *)description
{
  switch (self.kind) {
    case ODataSearchWord: return self.text;
    case ODataSearchPhrase: {
      NSString *escaped = [[self.text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                           stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
      return [NSString stringWithFormat:@"\"%@\"", escaped];
    }
    case ODataSearchAnd: return [NSString stringWithFormat:@"(%@ AND %@)", self.left, self.right];
    case ODataSearchOr: return [NSString stringWithFormat:@"(%@ OR %@)", self.left, self.right];
    case ODataSearchNot: return [NSString stringWithFormat:@"NOT %@", self.left];
  }
  return @"";
}

@end
