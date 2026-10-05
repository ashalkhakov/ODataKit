// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataOperationCatalog.h"
#import <ODataKit/ODataXML.h>
#import "ODataMetadataWriter.h"
#import "ODataService.h"
#import <objc/runtime.h>

// Both runtimes export it: a protocol method's types with each object
// parameter's class ("@\"NSString\""), where a class's own method records
// only "@".
const char *_protocol_getMethodTypeEncoding(Protocol *protocol, SEL selector, BOOL isRequiredMethod, BOOL isInstanceMethod);

// What a class may say about its operations; see ODataService.h.
@interface NSObject (OISOperationDeclarations)
+ (NSDictionary *)ODataOperationTypes;
+ (NSDictionary *)ODataOperationNames;
+ (NSDictionary *)ODataOperationScopes;
@end

// A method's types, one token each: the return type, self, _cmd, then the
// arguments; the offsets between them dropped.
static NSArray<NSString *> *OISTypeTokens(const char *encoding)
{
  NSMutableArray *tokens = [NSMutableArray array];
  const char *p = encoding;
  while (p && *p) {
    const char *start = p;
    while (*p && strchr("rnNoORVAj", *p)) p++;
    // One type, which may nest; a pointer goes on to the type it points to.
    int depth = 0;
    for (;;) {
      char c = *p;
      if (!c) break;
      p++;
      if (c == '^') continue;
      if (c == '{' || c == '(' || c == '[') {
        depth++;
      } else if (c == '}' || c == ')' || c == ']') {
        depth--;
      } else if (c == '@' && *p == '"') {
        const char *close = strchr(p + 1, '"');
        p = close ? close + 1 : p + strlen(p);
      } else if (c == '@' && *p == '?') {
        p++;
      } else if (c == 'b') {
        while (*p >= '0' && *p <= '9') p++;
      }
      if (depth <= 0) break;
    }
    [tokens addObject:[[NSString alloc] initWithBytes:start length:(NSUInteger)(p - start) encoding:NSUTF8StringEncoding]];
    while (*p == '-' || (*p >= '0' && *p <= '9')) p++;
  }
  return tokens;
}

static NSString *OISUnqualifiedToken(NSString *token)
{
  NSUInteger i = 0;
  while (i < token.length && strchr("rnNoORVAj", (char)[token characterAtIndex:i])) i++;
  return [token substringFromIndex:i];
}

// @"NSString<Proto>" is NSString; @"<Proto>" and @ are no class at all.
static NSString *OISClassNameOfToken(NSString *token)
{
  if (![token hasPrefix:@"@\""]) return nil;
  NSString *inner = [token substringWithRange:NSMakeRange(2, token.length - 3)];
  NSRange angle = [inner rangeOfString:@"<"];
  if (angle.location != NSNotFound) inner = [inner substringToIndex:angle.location];
  return inner.length ? inner : nil;
}

static NSString *OISLowerFirst(NSString *name)
{
  return name.length ? [[[name substringToIndex:1] lowercaseString] stringByAppendingString:[name substringFromIndex:1]] : name;
}

@implementation OISServedParameter
@end

@implementation OISServedOperation
- (NSString *)signature
{
  NSString *where = self.boundEntity ? self.boundEntity.managedObjectClassName : @"serviceOperations";
  return [NSString stringWithFormat:@"%@[%@ %@]", self.isClassMethod ? @"+" : @"-", where, NSStringFromSelector(self.selector)];
}
@end

@implementation OISOperationCatalog {
  NSManagedObjectModel *_model;
  ODataPropertyMapper *_mapper;
  ODataMetadataWriter *_writer;
  NSMutableArray<OISServedOperation *> *_operations;
  NSMutableArray<NSString *> *_problems;
}

- (instancetype)initWithModel:(NSManagedObjectModel *)model
                       mapper:(ODataPropertyMapper *)mapper
                       writer:(ODataMetadataWriter *)writer
            serviceOperations:(id)serviceOperations
{
  self = [super init];
  if (!self) return nil;
  _model = model;
  _mapper = mapper;
  _writer = writer;
  _operations = [NSMutableArray array];
  _problems = [NSMutableArray array];
  for (NSEntityDescription *entity in writer.entities) {
    Class cls = NSClassFromString(entity.managedObjectClassName ?: @"");
    if (!cls || cls == [NSManagedObject class]) continue;
    [self readClass:cls entity:entity];
  }
  if (serviceOperations) [self readClass:[serviceOperations class] entity:nil];
  NSMutableSet *imports = [NSMutableSet set];
  for (OISServedOperation *operation in _operations) {
    if (operation.boundEntity) continue;
    if ([imports containsObject:operation.name]) {
      [_problems addObject:[NSString stringWithFormat:@"%@: a second unbound operation named %@", operation.signature, operation.name]];
    }
    [imports addObject:operation.name];
  }
  return self;
}

- (NSArray *)operations
{
  return _operations;
}

- (NSArray *)problems
{
  return _problems;
}

#pragma mark Reading

// The operations protocols a class adopts itself, with those they inherit,
// as pointers: libobjc2's Protocol objects cannot be retained, so they
// cannot go in a collection themselves.
static void OISCollectProtocols(Protocol *protocol, NSMutableArray *into, NSMutableSet *seen)
{
  NSString *name = @(protocol_getName(protocol));
  if ([seen containsObject:name]) return;
  [seen addObject:name];
  if (protocol_isEqual(protocol, @protocol(ODataFunctions)) || protocol_isEqual(protocol, @protocol(ODataActions))) return;
  if (protocol_conformsToProtocol(protocol, @protocol(ODataFunctions)) || protocol_conformsToProtocol(protocol, @protocol(ODataActions))) {
    [into addObject:[NSValue valueWithPointer:(__bridge const void *)protocol]];
  }
  unsigned int count = 0;
  Protocol * __unsafe_unretained *inherited = protocol_copyProtocolList(protocol, &count);
  for (unsigned int i = 0; i < count; i++) OISCollectProtocols(inherited[i], into, seen);
  free(inherited);
}

// The scopes +ODataOperationScopes names for an operation: one, or an
// array or set of them, each a non-empty string; nil for anything else.
static NSSet<NSString *> *OISScopesNamed(id named)
{
  NSArray *items = [named isKindOfClass:[NSString class]] ? @[ named ]
                 : [named isKindOfClass:[NSArray class]] ? named
                 : [named isKindOfClass:[NSSet class]] ? [named allObjects] : nil;
  if (!items.count) return nil;
  for (id item in items) {
    if (![item isKindOfClass:[NSString class]] || ![item length]) return nil;
  }
  return [NSSet setWithArray:items];
}

- (void)readClass:(Class)cls entity:(NSEntityDescription *)entity
{
  NSMutableArray *protocols = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  unsigned int count = 0;
  Protocol * __unsafe_unretained *adopted = class_copyProtocolList(cls, &count);
  for (unsigned int i = 0; i < count; i++) OISCollectProtocols(adopted[i], protocols, seen);
  free(adopted);

  NSDictionary *types = [cls respondsToSelector:@selector(ODataOperationTypes)] ? [cls ODataOperationTypes] : @{};
  NSDictionary *names = [cls respondsToSelector:@selector(ODataOperationNames)] ? [cls ODataOperationNames] : @{};
  NSDictionary *scopes = [cls respondsToSelector:@selector(ODataOperationScopes)] ? [cls ODataOperationScopes] : @{};
  NSMutableSet *declared = [NSMutableSet set];

  for (NSValue *pointer in protocols) {
    Protocol *protocol = (__bridge Protocol *)[pointer pointerValue];
    BOOL isAction = protocol_conformsToProtocol(protocol, @protocol(ODataActions));
    for (int kind = 0; kind < 4; kind++) {
      BOOL required = (kind & 1) == 0;
      BOOL instance = (kind & 2) == 0;
      unsigned int methods = 0;
      struct objc_method_description *list = protocol_copyMethodDescriptionList(protocol, required, instance, &methods);
      for (unsigned int i = 0; i < methods; i++) {
        [declared addObject:NSStringFromSelector(list[i].name)];
        const char *extended = _protocol_getMethodTypeEncoding(protocol, list[i].name, required, instance);
        OISServedOperation *operation = [self operationFor:list[i].name
                                              types:extended ?: list[i].types
                                            ofClass:cls
                                             entity:entity
                                           instance:instance
                                             action:isAction
                                          overrides:types
                                              names:names];
        if (operation) {
          id named = scopes[NSStringFromSelector(list[i].name)];
          if (named) {
            operation.scopes = OISScopesNamed(named);
            // Left out, it would be open to everyone: not served at all.
            if (!operation.scopes) {
              [self problem:@"%@: +ODataOperationScopes names %@, not a scope or a list of them", operation.signature, named];
              continue;
            }
          }
          [_operations addObject:operation];
        }
      }
      free(list);
    }
  }
  // A name that is no operation's (a typo) would leave the one meant open:
  // said once, of the class whose method it is, which may name those its
  // superclasses declare.
  Class superclass = class_getSuperclass(cls);
  SEL method = @selector(ODataOperationScopes);
  BOOL inherited = superclass && [superclass respondsToSelector:method] &&
                   method_getImplementation(class_getClassMethod(cls, method)) == method_getImplementation(class_getClassMethod(superclass, method));
  if (inherited) return;
  for (Class c = superclass; c; c = class_getSuperclass(c)) {
    NSMutableArray *above = [NSMutableArray array];
    unsigned int n = 0;
    Protocol * __unsafe_unretained *list = class_copyProtocolList(c, &n);
    for (unsigned int i = 0; i < n; i++) OISCollectProtocols(list[i], above, seen);
    free(list);
    for (NSValue *pointer in above) {
      Protocol *protocol = (__bridge Protocol *)[pointer pointerValue];
      for (int kind = 0; kind < 4; kind++) {
        unsigned int methods = 0;
        struct objc_method_description *descriptions = protocol_copyMethodDescriptionList(protocol, (kind & 1) == 0, (kind & 2) == 0, &methods);
        for (unsigned int i = 0; i < methods; i++) [declared addObject:NSStringFromSelector(descriptions[i].name)];
        free(descriptions);
      }
    }
  }
  for (NSString *selectorName in [scopes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (![declared containsObject:selectorName]) {
      [self problem:@"+[%@ ODataOperationScopes]: %@ is not an operation it declares", NSStringFromClass(cls), selectorName];
    }
  }
}

- (void)problem:(NSString *)format, ...
{
  va_list args;
  va_start(args, format);
  [_problems addObject:[[NSString alloc] initWithFormat:format arguments:args]];
  va_end(args);
}

- (OISServedOperation *)operationFor:(SEL)selector
                         types:(const char *)encoding
                       ofClass:(Class)cls
                        entity:(NSEntityDescription *)entity
                      instance:(BOOL)instance
                        action:(BOOL)isAction
                     overrides:(NSDictionary *)overrides
                         names:(NSDictionary *)names
{
  NSString *selectorName = NSStringFromSelector(selector);
  OISServedOperation *operation = [[OISServedOperation alloc] init];
  operation.selector = selector;
  operation.isAction = isAction;
  operation.isClassMethod = !instance;
  operation.boundEntity = entity;
  operation.boundToCollection = entity && !instance;
  NSString *signature = operation.signature;

  if (!entity && !instance) {
    [self problem:@"%@: an unbound operation is an instance method of serviceOperations", signature];
    return nil;
  }
  if (instance ? ![cls instancesRespondToSelector:selector] : ![cls respondsToSelector:selector]) {
    [self problem:@"%@ is declared but not implemented", signature];
    return nil;
  }
  NSArray<NSString *> *tokens = OISTypeTokens(encoding);
  NSArray<NSString *> *keywords = [selectorName componentsSeparatedByString:@":"];
  keywords = [keywords subarrayWithRange:NSMakeRange(0, keywords.count - 1)];
  if (!keywords.count || tokens.count != keywords.count + 3) {
    [self problem:@"%@ takes no ODataReply", signature];
    return nil;
  }
  if (![OISClassNameOfToken(OISUnqualifiedToken(tokens.lastObject)) isEqualToString:@"ODataReply"]) {
    [self problem:@"%@: the last parameter must be the ODataReply", signature];
    return nil;
  }

  // Names: the first keyword is the operation's, up to With, and names the
  // first parameter after it; the others name theirs.
  NSString *first = keywords[0];
  NSMutableArray<NSString *> *parameterNames = [NSMutableArray array];
  NSString *name = first;
  if (keywords.count > 1) {
    NSRange with = [first rangeOfString:@"With" options:NSBackwardsSearch];
    if (with.location != NSNotFound && with.location > 0 && NSMaxRange(with) < first.length &&
        [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[first characterAtIndex:NSMaxRange(with)]]) {
      name = [first substringToIndex:with.location];
      [parameterNames addObject:OISLowerFirst([first substringFromIndex:NSMaxRange(with)])];
    } else {
      NSUInteger last = first.length;
      while (last > 0 && ![[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[first characterAtIndex:last - 1]]) last--;
      [parameterNames addObject:OISLowerFirst(last > 0 ? [first substringFromIndex:last - 1] : first)];
    }
    for (NSUInteger i = 1; i + 1 < keywords.count; i++) [parameterNames addObject:keywords[i]];
  }
  operation.name = names[selectorName] ?: [_mapper wireName:name];
  operation.qualifiedName = [NSString stringWithFormat:@"%@.%@", _writer.namespaceName, operation.name];

  NSMutableArray *parameters = [NSMutableArray array];
  for (NSUInteger i = 0; i < parameterNames.count; i++) {
    NSString *derived = parameterNames[i];
    NSString *wire = names[[NSString stringWithFormat:@"%@.%@", selectorName, derived]] ?: [_mapper wireName:derived];
    NSString *declared = overrides[[NSString stringWithFormat:@"%@.%@", selectorName, derived]]
                      ?: overrides[[NSString stringWithFormat:@"%@.%@", selectorName, wire]];
    OISServedParameter *parameter = [self parameterForToken:tokens[3 + i] declared:declared];
    if (!parameter) {
      [self problem:@"%@: the type of %@ is not known; name it in +ODataOperationTypes as \"%@.%@\"", signature, derived, selectorName, derived];
      return nil;
    }
    parameter.name = wire;
    [parameters addObject:parameter];
  }
  operation.parameters = parameters;

  NSString *returnToken = OISUnqualifiedToken(tokens[0]);
  if (![returnToken isEqualToString:@"v"]) {
    OISServedParameter *returns = [self parameterForToken:returnToken declared:overrides[selectorName]];
    if (!returns) {
      [self problem:@"%@: the return type is not known; name it in +ODataOperationTypes as \"%@\"", signature, selectorName];
      return nil;
    }
    operation.returns = returns;
  } else if (!isAction) {
    [self problem:@"%@: a function must return something", signature];
    return nil;
  }
  return operation;
}

- (NSEntityDescription *)entityForClass:(Class)cls
{
  for (; cls && cls != [NSManagedObject class]; cls = class_getSuperclass(cls)) {
    for (NSEntityDescription *entity in _writer.entities) {
      if ([entity.managedObjectClassName isEqualToString:NSStringFromClass(cls)]) return entity;
    }
  }
  return nil;
}

- (NSEntityDescription *)entityForTypeName:(NSString *)typeName
{
  for (NSEntityDescription *entity in _writer.entities) {
    if ([[_writer typeNameForEntity:entity] isEqualToString:typeName]) return entity;
  }
  return nil;
}

- (OISServedParameter *)parameterForToken:(NSString *)rawToken declared:(NSString *)declared
{
  NSString *token = OISUnqualifiedToken(rawToken);
  OISServedParameter *parameter = [[OISServedParameter alloc] init];
  NSDictionary *scalars = @{ @"c": @"Edm.Boolean", @"C": @"Edm.Boolean", @"B": @"Edm.Boolean",
                             @"s": @"Edm.Int16", @"S": @"Edm.Int16", @"i": @"Edm.Int32", @"I": @"Edm.Int32",
                             @"l": @"Edm.Int32", @"L": @"Edm.Int32", @"q": @"Edm.Int64", @"Q": @"Edm.Int64",
                             @"f": @"Edm.Single", @"d": @"Edm.Double" };
  if (token.length == 1 && scalars[token]) {
    parameter.scalar = (char)[token characterAtIndex:0];
    parameter.type = declared ?: scalars[token];
    return parameter;
  }
  if (![token hasPrefix:@"@"]) return nil;
  if (declared) {
    parameter.type = declared;
    NSString *element = declared;
    if ([element hasPrefix:@"Collection("] && [element hasSuffix:@")"]) element = [element substringWithRange:NSMakeRange(11, element.length - 12)];
    parameter.entity = [self entityForTypeName:element];
    return parameter;
  }
  Class cls = NSClassFromString(OISClassNameOfToken(token) ?: @"");
  if (!cls) return nil;
  // A dictionary is a JSON object, whatever it holds.
  if ([cls isSubclassOfClass:[NSDictionary class]]) {
    parameter.type = @"Edm.Untyped";
    return parameter;
  }
  NSArray *known = @[ @[ [NSDecimalNumber class], @"Edm.Decimal" ], @[ [NSString class], @"Edm.String" ],
                      @[ [NSDate class], @"Edm.DateTimeOffset" ], @[ [NSUUID class], @"Edm.Guid" ],
                      @[ [NSData class], @"Edm.Binary" ] ];
  for (NSArray *pair in known) {
    if ([cls isSubclassOfClass:pair[0]]) {
      parameter.type = pair[1];
      return parameter;
    }
  }
  if ([cls isSubclassOfClass:[NSManagedObject class]]) {
    NSEntityDescription *entity = [self entityForClass:cls];
    if (!entity) return nil;
    parameter.entity = entity;
    parameter.type = [_writer typeNameForEntity:entity];
    return parameter;
  }
  return nil;  // NSNumber, a collection, id: the declaration must say
}

#pragma mark Finding

static BOOL OISEntityIsOrInherits(NSEntityDescription *entity, NSEntityDescription *ancestor)
{
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    if ([e.name isEqualToString:ancestor.name]) return YES;
  }
  return NO;
}

- (OISServedOperation *)operationNamed:(NSString *)name boundTo:(NSEntityDescription *)entity collection:(BOOL)collection
{
  for (OISServedOperation *operation in _operations) {
    if (!operation.boundEntity || operation.boundToCollection != collection) continue;
    if (![operation.qualifiedName isEqualToString:name] && ![operation.name isEqualToString:name]) continue;
    if (OISEntityIsOrInherits(entity, operation.boundEntity)) return operation;
  }
  return nil;
}

- (OISServedOperation *)importNamed:(NSString *)name
{
  for (OISServedOperation *operation in _operations) {
    if (!operation.boundEntity && [operation.name isEqualToString:name]) return operation;
  }
  return nil;
}

#pragma mark CSDL

static void OISSet(ODataXMLElement *element, NSString *name, NSString *value)
{
  [element addAttribute:[ODataXMLNode attributeWithName:name stringValue:value]];
}

static BOOL OISIsDecimal(NSString *type)
{
  return [type hasSuffix:@"Edm.Decimal"] || [type hasSuffix:@"Edm.Decimal)"];
}

- (ODataXMLElement *)parameterNamed:(NSString *)name type:(NSString *)type scalar:(BOOL)scalar
{
  ODataXMLElement *parameter = [[ODataXMLElement alloc] initWithName:@"Parameter"];
  OISSet(parameter, @"Name", name);
  OISSet(parameter, @"Type", type);
  if (scalar) OISSet(parameter, @"Nullable", @"false");
  if (OISIsDecimal(type)) OISSet(parameter, @"Scale", @"variable");
  return parameter;
}

- (NSArray<ODataXMLElement *> *)schemaElements
{
  NSMutableArray *elements = [NSMutableArray array];
  for (OISServedOperation *operation in _operations) {
    ODataXMLElement *element = [[ODataXMLElement alloc] initWithName:operation.isAction ? @"Action" : @"Function"];
    OISSet(element, @"Name", operation.name);
    if (operation.boundEntity) OISSet(element, @"IsBound", @"true");
    // A function's result can be read on from: the service composes on it.
    if (!operation.isAction) OISSet(element, @"IsComposable", @"true");
    if (operation.boundEntity) {
      NSString *type = [_writer typeNameForEntity:operation.boundEntity];
      if (operation.boundToCollection) type = [NSString stringWithFormat:@"Collection(%@)", type];
      [element addChild:[self parameterNamed:@"bindingParameter" type:type scalar:YES]];
    }
    for (OISServedParameter *parameter in operation.parameters) {
      [element addChild:[self parameterNamed:parameter.name type:parameter.type scalar:parameter.scalar != 0]];
    }
    if (operation.returns) {
      ODataXMLElement *returns = [[ODataXMLElement alloc] initWithName:@"ReturnType"];
      OISSet(returns, @"Type", operation.returns.type);
      if (operation.returns.scalar) OISSet(returns, @"Nullable", @"false");
      if (OISIsDecimal(operation.returns.type)) OISSet(returns, @"Scale", @"variable");
      [element addChild:returns];
    }
    [elements addObject:element];
  }
  return elements;
}

- (NSArray<ODataXMLElement *> *)containerElements
{
  NSMutableArray *elements = [NSMutableArray array];
  for (OISServedOperation *operation in _operations) {
    if (operation.boundEntity) continue;
    ODataXMLElement *element = [[ODataXMLElement alloc] initWithName:operation.isAction ? @"ActionImport" : @"FunctionImport"];
    OISSet(element, @"Name", operation.name);
    OISSet(element, operation.isAction ? @"Action" : @"Function", operation.qualifiedName);
    NSEntityDescription *returned = operation.returns.entity;
    if (returned) {
      while (returned.superentity) returned = returned.superentity;
      OISSet(element, @"EntitySet", [_mapper entitySetForEntity:returned]);
    }
    [elements addObject:element];
  }
  return elements;
}

@end
