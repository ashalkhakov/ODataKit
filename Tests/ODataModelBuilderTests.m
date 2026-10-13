// A Core Data model from $metadata: built at runtime, written as versioned
// .xcdatamodeld packages, and checked against the service like any model
// against its store.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"
#import "ODataSnapshotTransport.h"

// A service whose $metadata is whatever the test says; nothing else.
@interface OISMetadataTransport : NSObject <ODataTransport>
@property (nonatomic, copy) NSString *xml;
@end

@implementation OISMetadataTransport
- (void)startExchange:(ODataExchange *)exchange
{
  BOOL metadata = [exchange.request.URL.path hasSuffix:@"$metadata"];
  exchange.URLResponse = [[NSHTTPURLResponse alloc] initWithURL:exchange.request.URL statusCode:metadata ? 200 : 404
                                                     HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"application/xml" }];
  exchange.data = metadata ? [self.xml dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
  [exchange finish];
}
@end

@interface ODataModelBuilderTests : XCTestCase
@end

@implementation ODataModelBuilderTests {
  NSString *_zooXML;
  ODataSchema *_zoo;
}

- (void)setUp
{
  [super setUp];
  [ODataIncrementalStore registerStore];
  NSString *path = [[OISSnapshotDirectory() stringByAppendingPathComponent:@"Zoo"] stringByAppendingPathComponent:@"metadata.json"];
  NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:NULL];
  _zooXML = snapshot[@"response"][@"bodyXML"];
  _zoo = [ODataSchema schemaWithData:[_zooXML dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
  XCTAssertNotNil(_zoo);
}

// The Zoo schema, with the keepers' phone numbers added: a new version.
- (NSString *)zooV2
{
  return [_zooXML stringByReplacingOccurrencesOfString:@"<Property Name=\"Code\" Type=\"Edm.String\" Nullable=\"false\"/>"
                                            withString:@"<Property Name=\"Code\" Type=\"Edm.String\" Nullable=\"false\"/><Property Name=\"Phone\" Type=\"Edm.String\"/>"];
}

- (ODataSchema *)schemaFrom:(NSString *)xml
{
  return [ODataSchema schemaWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
}

- (void)testBuildsTheModelTheSchemaDescribes
{
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:_zoo];
  NSEntityDescription *animal = model.entitiesByName[@"Animal"];
  NSEntityDescription *lion = model.entitiesByName[@"Lion"];
  NSEntityDescription *keeper = model.entitiesByName[@"Keeper"];
  XCTAssertNotNil(animal);
  XCTAssertEqualObjects(lion.superentity.name, @"Animal");
  XCTAssertEqualObjects(animal.userInfo[ODataUserInfoEntitySet], @"Animals");
  XCTAssertEqualObjects(keeper.userInfo[ODataUserInfoEntitySet], @"Staff");
  XCTAssertNil(lion.userInfo[ODataUserInfoEntitySet], @"a derived type is in its base's set");
  XCTAssertEqualObjects(lion.userInfo[ODataUserInfoType], @"Zoo.Lion");

  NSAttributeDescription *identifier = animal.attributesByName[@"id"];
  XCTAssertEqual(identifier.attributeType, NSInteger32AttributeType);
  XCTAssertFalse(identifier.isOptional);
  XCTAssertEqualObjects(identifier.userInfo[ODataUserInfoProperty], @"Id");
  XCTAssertEqualObjects(identifier.userInfo[ODataUserInfoKey], @"YES");
  XCTAssertEqual([animal.attributesByName[@"born"] attributeType], NSDateAttributeType);
  XCTAssertEqualObjects([animal.attributesByName[@"born"] userInfo][ODataUserInfoType], @"Edm.Date");
  XCTAssertEqualObjects([animal.attributesByName[@"diet"] userInfo][ODataUserInfoType], @"Zoo.Diet");
  NSAttributeDescription *home = animal.attributesByName[@"home"];
  XCTAssertEqual(home.attributeType, NSTransformableAttributeType);
  XCTAssertEqualObjects(home.userInfo[ODataUserInfoType], @"Zoo.Enclosure");
  XCTAssertEqualObjects(home.attributeValueClassName, @"NSDictionary");
  NSAttributeDescription *pastHomes = animal.attributesByName[@"pastHomes"];
  XCTAssertEqualObjects(pastHomes.userInfo[ODataUserInfoType], @"Collection(Zoo.Enclosure)");
  XCTAssertEqualObjects(pastHomes.attributeValueClassName, @"NSArray");
  XCTAssertFalse([animal.attributesByName[@"nicknames"] isOptional], @"Nullable=false");
  XCTAssertNil(animal.userInfo[ODataUserInfoUnmapped]);
  XCTAssertNotNil(lion.attributesByName[@"maxRoar"]);
  XCTAssertNotNil(lion.attributesByName[@"name"], @"inherited");

  NSRelationshipDescription *keeperOf = animal.relationshipsByName[@"keeper"];
  XCTAssertFalse(keeperOf.isToMany);
  XCTAssertEqualObjects(keeperOf.inverseRelationship.name, @"animals", @"partners are inverses");
  XCTAssertTrue(keeperOf.inverseRelationship.isToMany);
  XCTAssertEqualObjects([ODataModelBuilder versionIdentifierOfModel:model], [ODataModelBuilder versionIdentifierForSchema:_zoo]);
}

// An open type, TripPin's Person: its dynamic properties in a bag, an
// NSDictionary, which a derived type inherits.
- (void)testAnOpenTypeHasAPropertyBag
{
  NSString *xml = @"<edmx:Edmx xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\" Version=\"4.0\"><edmx:DataServices>"
                  @"<Schema xmlns=\"http://docs.oasis-open.org/odata/ns/edm\" Namespace=\"Trips\">"
                  @"<EntityType Name=\"Person\" OpenType=\"true\"><Key><PropertyRef Name=\"UserName\"/></Key>"
                  @"<Property Name=\"UserName\" Type=\"Edm.String\" Nullable=\"false\"/><Property Name=\"DynamicProperties\" Type=\"Edm.String\"/></EntityType>"
                  @"<EntityType Name=\"Employee\" BaseType=\"Trips.Person\"><Property Name=\"Cost\" Type=\"Edm.Int64\"/></EntityType>"
                  @"<EntityType Name=\"Airline\"><Key><PropertyRef Name=\"Code\"/></Key><Property Name=\"Code\" Type=\"Edm.String\" Nullable=\"false\"/></EntityType>"
                  @"<EntityContainer Name=\"Container\"><EntitySet Name=\"People\" EntityType=\"Trips.Person\"/>"
                  @"<EntitySet Name=\"Airlines\" EntityType=\"Trips.Airline\"/></EntityContainer></Schema></edmx:DataServices></edmx:Edmx>";
  ODataSchema *schema = [self schemaFrom:xml];
  ODataSchemaEntityType *personType = schema.entityTypes[@"Trips.Person"], *employeeType = schema.entityTypes[@"Trips.Employee"];
  XCTAssertTrue(personType.isOpen);
  XCTAssertFalse(employeeType.isOpen);
  XCTAssertTrue([schema entityTypeIsOpen:schema.entityTypes[@"Trips.Employee"]], @"through its base");
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  NSEntityDescription *person = model.entitiesByName[@"Person"];
  // A declared DynamicProperties keeps its name: the bag takes another.
  NSAttributeDescription *declared = person.attributesByName[@"dynamicProperties"];
  XCTAssertEqual(declared.attributeType, NSStringAttributeType);
  NSAttributeDescription *bag = person.attributesByName[@"dynamicProperties2"];
  XCTAssertEqual(bag.attributeType, NSTransformableAttributeType);
  XCTAssertEqualObjects(bag.attributeValueClassName, @"NSDictionary");
  XCTAssertEqualObjects(bag.userInfo[ODataUserInfoDynamicProperties], @"YES");
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  XCTAssertEqualObjects([mapper dynamicPropertiesAttributeOfEntity:model.entitiesByName[@"Employee"]].name, bag.name, @"inherited");
  NSEntityDescription *employee = model.entitiesByName[@"Employee"];
  NSUInteger bags = 0;
  for (NSAttributeDescription *attribute in employee.attributesByName.allValues) bags += [mapper attributeHoldsDynamicProperties:attribute];
  XCTAssertEqual(bags, 1u, @"and none of its own");
  XCTAssertNil([mapper dynamicPropertiesAttributeOfEntity:model.entitiesByName[@"Airline"]]);
  XCTAssertEqualObjects([mapper problemsWithModel:model], @[]);
  XCTAssertEqualObjects([mapper propertyPathForKeyPath:@"dynamicProperties2.Nickname" entity:person], @"Nickname");
  XCTAssertNil([mapper propertyForWireName:@"DynamicProperties2" entity:person], @"no property on the wire");

  // Being open is part of the model's version, and survives a model file.
  NSString *closed = [xml stringByReplacingOccurrencesOfString:@" OpenType=\"true\"" withString:@""];
  XCTAssertNotEqualObjects([ODataModelBuilder versionIdentifierForSchema:schema],
                           [ODataModelBuilder versionIdentifierForSchema:[self schemaFrom:closed]]);
  NSString *document = [[NSString alloc] initWithData:[ODataModelBuilder modelDocumentForModel:model] encoding:NSUTF8StringEncoding];
  XCTAssertTrue([document rangeOfString:@"<entry key=\"OData.dynamicProperties\" value=\"YES\"/>"].location != NSNotFound, @"%@", document);
  NSManagedObjectModel *closedModel = [ODataModelBuilder modelWithSchema:[self schemaFrom:closed]];
  XCTAssertNil([mapper dynamicPropertiesAttributeOfEntity:closedModel.entitiesByName[@"Person"]]);
}

- (void)testVersionIdentifierFollowsTheSchema
{
  NSString *v1 = [ODataModelBuilder versionIdentifierForSchema:_zoo];
  XCTAssertTrue([v1 hasPrefix:@"odata:"]);
  XCTAssertEqualObjects([ODataModelBuilder versionIdentifierForSchema:[self schemaFrom:_zooXML]], v1);
  XCTAssertNotEqualObjects([ODataModelBuilder versionIdentifierForSchema:[self schemaFrom:[self zooV2]]], v1);
}

- (void)testGeneratedModelWorksAgainstTheService
{
  NSError *error = nil;
  ODataSnapshotTransport *transport = [[ODataSnapshotTransport alloc] initWithDirectory:[OISSnapshotDirectory() stringByAppendingPathComponent:@"Zoo"]
                                                                            serviceRoot:[NSURL URLWithString:@"https://zoo.test/Zoo.svc/"] error:&error];
  NSURL *root = [NSURL URLWithString:@"https://zoo.test/Zoo.svc/"];
  NSDictionary *options = @{ ODataIncrementalStoreTransportOption: transport };
  NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:root options:options error:&error];
  XCTAssertNotNil(model, @"%@", error);
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  ODataIncrementalStore *store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                                             configuration:nil URL:root options:options error:&error];
  XCTAssertNotNil(store, @"%@", error);
  XCTAssertEqualObjects(store.metadataProblems, @[]);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = psc;
  NSArray *animals = [context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Animal"] error:&error];
  XCTAssertEqual(animals.count, (NSUInteger)3, @"%@", error);
  for (NSManagedObject *animal in animals) {
    if (![[animal valueForKey:@"name"] isEqual:@"Leo"]) continue;
    XCTAssertEqualObjects(animal.entity.name, @"Lion");
    XCTAssertEqualObjects([animal valueForKey:@"features"], @"Mane", @"a generated model holds enumerations as names");
    XCTAssertEqualObjects([animal valueForKey:@"home"][@"Zone"], @"Pride Rock");
  }
  XCTAssertEqualObjects(transport.refusals, @[]);
}

- (void)testPackagesGainAVersionWhenTheSchemaChanges
{
  NSString *package = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"ois-%@/Zoo.xcdatamodeld", [[NSUUID UUID] UUIDString]]];
  NSError *error = nil;
  BOOL changed = NO;
  NSManagedObjectModel *v1 = [ODataModelBuilder modelWithSchema:_zoo];
  XCTAssertEqualObjects([ODataModelBuilder writeModel:v1 toPackage:package changed:&changed error:&error], @"Zoo", @"%@", error);
  XCTAssertTrue(changed);
  XCTAssertEqualObjects([ODataModelBuilder writeModel:v1 toPackage:package changed:&changed error:&error], @"Zoo");
  XCTAssertFalse(changed, @"the same schema is the same version");

  NSManagedObjectModel *v2 = [ODataModelBuilder modelWithSchema:[self schemaFrom:[self zooV2]]];
  XCTAssertEqualObjects([ODataModelBuilder writeModel:v2 toPackage:package changed:&changed error:&error], @"Zoo 2");
  XCTAssertTrue(changed);
  NSDictionary *current = [NSDictionary dictionaryWithContentsOfFile:[package stringByAppendingPathComponent:@".xccurrentversion"]];
  XCTAssertEqualObjects(current[@"_XCCurrentVersionName"], @"Zoo 2.xcdatamodel");
  NSString *old = [NSString stringWithContentsOfFile:[package stringByAppendingPathComponent:@"Zoo.xcdatamodel/contents"]
                                            encoding:NSUTF8StringEncoding error:NULL];
  NSString *now = [NSString stringWithContentsOfFile:[package stringByAppendingPathComponent:@"Zoo 2.xcdatamodel/contents"]
                                            encoding:NSUTF8StringEncoding error:NULL];
  XCTAssertTrue([old rangeOfString:@"phone"].location == NSNotFound, @"the old version is kept as it was");
  XCTAssertTrue([now rangeOfString:@"name=\"phone\""].location != NSNotFound);
  XCTAssertTrue([now rangeOfString:[ODataModelBuilder versionIdentifierOfModel:v2]].location != NSNotFound);
  XCTAssertTrue([now rangeOfString:@"parentEntity=\"Animal\""].location != NSNotFound);
  XCTAssertTrue([now rangeOfString:@"attributeType=\"Transformable\" valueTransformerName=\"NSSecureUnarchiveFromData\" customClassName=\"NSDictionary\""].location != NSNotFound, @"%@", now);
  [[NSFileManager defaultManager] removeItemAtPath:package.stringByDeletingLastPathComponent error:NULL];
}

// A file or an image is kept beside the store (allows external storage),
// which is part of its version hash: the package says so, or the model
// compiled from it is not the version of the service's (Northwind's
// pictures and photos were).
- (void)testPackagesKeepExternalStorage
{
  NSString *xml = [_zooXML stringByReplacingOccurrencesOfString:@"<Property Name=\"Code\" Type=\"Edm.String\" Nullable=\"false\"/>"
                                                     withString:@"<Property Name=\"Code\" Type=\"Edm.String\" Nullable=\"false\"/><Property Name=\"Photo\" Type=\"Edm.Binary\"/>"];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:[self schemaFrom:xml]];
  NSAttributeDescription *photo = (NSAttributeDescription *)model.entitiesByName[@"Keeper"].propertiesByName[@"photo"];
  XCTAssertTrue(photo.allowsExternalBinaryDataStorage);
  NSString *package = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"ois-%@/Zoo.xcdatamodeld", [[NSUUID UUID] UUIDString]]];
  NSError *error = nil;
  BOOL changed = NO;
  XCTAssertEqualObjects([ODataModelBuilder writeModel:model toPackage:package changed:&changed error:&error], @"Zoo", @"%@", error);
  NSString *document = [NSString stringWithContentsOfFile:[package stringByAppendingPathComponent:@"Zoo.xcdatamodel/contents"]
                                                 encoding:NSUTF8StringEncoding error:NULL];
  NSRange element = [document rangeOfString:@"<attribute name=\"photo\"[^>]*>" options:NSRegularExpressionSearch];
  XCTAssertTrue(element.location != NSNotFound, @"%@", document);
  if (element.location != NSNotFound) {
    XCTAssertTrue([[document substringWithRange:element] rangeOfString:@"allowsExternalBinaryDataStorage=\"YES\""].location != NSNotFound,
                  @"%@", [document substringWithRange:element]);
  }
  [[NSFileManager defaultManager] removeItemAtPath:package.stringByDeletingLastPathComponent error:NULL];
}

- (void)testAChangedServiceIsAVersionChange
{
  NSURL *root = [NSURL URLWithString:@"https://zoo.test/Zoo.svc/"];
  OISMetadataTransport *service = [[OISMetadataTransport alloc] init];
  service.xml = [self zooV2];
  NSDictionary *options = @{ ODataIncrementalStoreTransportOption: service };

  // The versions an app ships: Core Data picks the one the service matches.
  NSManagedObjectModel *v1 = [ODataModelBuilder modelWithSchema:_zoo];
  NSManagedObjectModel *v2 = [ODataModelBuilder modelWithSchema:[self schemaFrom:[self zooV2]]];
  NSError *error = nil;
  NSDictionary *metadata = [ODataIncrementalStore metadataForServiceAtURL:root options:options error:&error];
  XCTAssertNotNil(metadata, @"%@", error);
  XCTAssertTrue([v2 isConfiguration:nil compatibleWithStoreMetadata:metadata]);
  XCTAssertFalse([v1 isConfiguration:nil compatibleWithStoreMetadata:metadata]);

  // Opening with the old version fails as Core Data fails any store whose
  // model has moved on.
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:v1];
  id store = [psc addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:root options:options error:&error];
  XCTAssertNil(store);
  NSError *cause = error.userInfo[NSUnderlyingErrorKey] ?: error;
  XCTAssertEqual(cause.code, NSPersistentStoreIncompatibleVersionHashError, @"%@", error);

  psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:v2];
  error = nil;
  XCTAssertNotNil([psc addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:root options:options error:&error], @"%@", error);
}

- (void)testClassesCarryTheOperationsAsMethods
{
  NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ois-%@", [[NSUUID UUID] UUIDString]]];
  NSString *classes = [root stringByAppendingPathComponent:@"Classes"];
  NSString *package = [root stringByAppendingPathComponent:@"Zoo.xcdatamodeld"];
  NSError *error = nil;
  BOOL changed = NO;
  // A package written before there were classes: the same version gains them.
  XCTAssertEqualObjects([ODataModelBuilder writeModel:[ODataModelBuilder modelWithSchema:_zoo] toPackage:package changed:&changed error:&error], @"Zoo");

  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:_zoo];
  NSArray *written = [ODataClassWriter writeClassesForModel:model schema:_zoo serviceName:@"ZooService" toDirectory:classes error:&error];
  XCTAssertNotNil(written, @"%@", error);
  NSEntityDescription *lion = model.entitiesByName[@"Lion"];
  XCTAssertEqualObjects(lion.managedObjectClassName, @"Lion");
  NSString *(^read)(NSString *) = ^NSString *(NSString *name) {
    return [NSString stringWithContentsOfFile:[classes stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:NULL] ?: @"";
  };
  NSString *animal = read(@"_Animal.h");
  NSArray *expected = @[
    @"@property (nonatomic, strong, nullable) NSDictionary *home;",
    @"@property (nonatomic, strong, nullable) Keeper *keeper;",
    @"- (nullable NSNumber *)ageWithOn:(nullable NSDate *)on error:(NSError **)error;",
    @"- (nullable Keeper *)caretaker:(NSError **)error;",
    @"- (nullable NSDictionary *)moveWithTo:(nullable NSDictionary *)to error:(NSError **)error;",
    @"- (BOOL)feed:(NSError **)error;",
    @"+ (nullable Animal *)heaviestInContext:(NSManagedObjectContext *)context error:(NSError **)error;",
  ];
  for (NSString *line in expected) XCTAssertTrue([animal rangeOfString:line].location != NSNotFound, @"%@ in\n%@", line, animal);
  XCTAssertTrue([read(@"_Lion.h") rangeOfString:@"@interface _Lion : Animal"].location != NSNotFound, @"a sub-entity's class derives from its super-entity's");
  XCTAssertTrue([read(@"_Keeper.h") rangeOfString:@"- (nullable NSArray<Animal *> *)animalsInWithZones:(nullable NSArray *)zones error:(NSError **)error;"].location != NSNotFound);
  NSString *service = read(@"_ZooService.h");
  XCTAssertTrue([service rangeOfString:@"+ (nullable Animal *)admitAnimalInContext:(NSManagedObjectContext *)context name:(nullable NSString *)name diet:(nullable NSString *)diet keeper:(nullable Keeper *)keeper error:(NSError **)error;"].location != NSNotFound, @"%@", service);
  XCTAssertTrue([read(@"_Animal.m") rangeOfString:@"invokeODataOperation:@\"Zoo.Age\""].location != NSNotFound);

  // Your own class is yours: writing again leaves it be.
  NSString *mine = [classes stringByAppendingPathComponent:@"Animal.m"];
  [@"// mine" writeToFile:mine atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  written = [ODataClassWriter writeClassesForModel:[ODataModelBuilder modelWithSchema:_zoo] schema:_zoo serviceName:@"ZooService" toDirectory:classes error:&error];
  XCTAssertFalse([written containsObject:mine]);
  XCTAssertEqualObjects([NSString stringWithContentsOfFile:mine encoding:NSUTF8StringEncoding error:NULL], @"// mine");

  XCTAssertEqualObjects([ODataModelBuilder writeModel:model toPackage:package changed:&changed error:&error], @"Zoo", @"the same version");
  XCTAssertTrue(changed, @"rewritten in place, with the class names");
  NSString *document = [NSString stringWithContentsOfFile:[package stringByAppendingPathComponent:@"Zoo.xcdatamodel/contents"] encoding:NSUTF8StringEncoding error:NULL];
  XCTAssertTrue([document rangeOfString:@"representedClassName=\"Lion\""].location != NSNotFound);
  [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

@end
