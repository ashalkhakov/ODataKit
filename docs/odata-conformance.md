# OData v4 conformance

What ODataIncrementalStore must support to work against real OData v4
services, and where it stands. Section numbers refer to the OData 4.01
OASIS specifications:
[Part 1: Protocol](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html),
[Part 2: URL Conventions](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part2-url-conventions.html),
[JSON Format](https://docs.oasis-open.org/odata/odata-json-format/v4.01/odata-json-format-v4.01.html).

The client speaks **OData 4.01** where it can and **4.0** where it must:
its `$metadata` tells the store which version a service speaks
(`<edmx:Edmx Version="4.0">`), and requests carry and are written in the
newer version both allow (`OData-Version`; `OData-MaxVersion` is `4.01`,
which `ODataIncrementalStoreMaxVersionOption` lowers). This matters: a 4.0
service refuses 4.01 syntax outright (Northwind answers `in` with `400`,
TripPin with `500`, **live**). Responses are read by their own
`OData-Version`, 4.01's shorter control information included (2.4). The
4.01-only client requirements are items 16–20 of section 1.

| Mark | Meaning |
|---|---|
| ✅ | Supported |
| ⚠️ | Partly supported, or works only in the common case |
| ❌ | Missing or broken |
| — | Out of scope, with the reason given |
| **live** | Checked against Microsoft's public reference services (Northwind v4, TripPin RW) on macOS and GNUstep |

## 1. Interoperable client requirements (Part 1 §13.3)

These are the spec's own list. Everything marked ❌ here is a blocker for
calling the client conformant.

| # | Requirement | Status | Notes |
|---|---|---|---|
| 1 | MUST send `OData-MaxVersion` | ✅ | `4.01` on every request, unless the option says otherwise. |
| 2 | MUST send `OData-Version` and `Content-Type` with a payload | ✅ | `OData-Version` on every request, the version the service speaks (4.0 until `$metadata` is read); `Content-Type` only with a body. |
| 3 | MUST be a conforming consumer of the JSON format | ⚠️ | See section 2. |
| 4 | MUST follow redirects (§9.1.5) | ✅ **live** | `NSURLSession` follows them, on Apple and on GNUstep, where the client uses it whenever gnustep-base was built with libcurl. TripPin's entry URL redirects with a relative `Location`. gnustep-base's `NSURLConnection`, the fallback, did not follow a relative `Location` (`NSURLProtocol` built the new URL without the request URL, and the request timed out); gnustep-patches' `urlprotocol-relative-redirect` resolves it against the request URL. |
| 5 | MUST handle next links (§11.2.6.7) | ✅ **live** | Followed, relative or absolute, for collections and to-many relationships, until the collection ends or `fetchLimit` is reached. Northwind pages at 20; all 77 products arrive. |
| 6 | MUST accept properties not in metadata (§11.2) | ✅ | Unknown properties are ignored. |
| 7 | MUST use PATCH for updates (§11.4.3) | ✅ | |
| 8 | MUST use the `$` prefix on system query options | ✅ | |
| 9 | MUST use case-sensitive options, operators, functions | ✅ | |
| 10 | SHOULD support Basic authentication over HTTPS | ✅ | Also Bearer tokens. |
| 11–15 | MAY: entity references, delta, async, `metadata=minimal`, streaming | ⚠️ | Optional. The client asks for `metadata=minimal` (see 2.1), and follows delta links and status monitors (section 8). Entity references: it writes relationships with `$ref` requests (section 4.2) and reads a delta's entries named only by `@odata.id`; Core Data has no use for reading a collection of references itself, so it does not ask for one. It does not ask for streaming responses. |
| 16 | 4.01: MUST send 4.0 payloads to a service that does not advertise 4.01 in `Core.ODataVersions` | ✅ | The container's `Core.ODataVersions` decides, its highest version listed; without it, `<edmx:Edmx Version>` does, since only a 4.01 service writes 4.01 CSDL. `ODataService` advertises `4.0 4.01`. |
| 17 | 4.01: MUST spell identifiers in payloads and URLs as `$metadata` does | ✅ | Property, navigation property, entity set, type and enumeration member names are given `$metadata`'s spelling where the model's differs only in case (`Id` for `ID`, `Staff` for `staff`), names from `userInfo` included. |
| 18 | 4.01: MUST be prepared for any valid 4.01 CSDL | ✅ | Tested with `Edm.Untyped` and abstract property types, `Scale` variable and floating, `SRID`, key aliases, a nullable singleton, `IncludeInServiceDocument`, `Edm.Int64` enumerations, `ContainsTarget` with `OnDelete`, action overloads with `EntitySetPath`, terms of its own, `IncludeAnnotations`, and `UrlRef`, `LabeledElement` and `Apply` annotations: parsed, and a model built from it. CSDL JSON is read too (`ODataCSDL` turns it into the XML it says the same as), and so is the specification's own example. |
| 19 | 4.01: MUST be prepared for any valid 4.01 response in the format asked for | ✅ | Control information without `odata.` (2.4), `@removed` and `#$deletedEntity`, `#$link` and `#$deletedLink` in deltas, decimals with exponents, `Nav@count` and unknown annotations. |
| 20 | 4.01: SHOULD check Capabilities before 4.01 syntax, or be ready for `400` and `501` | ✅ | `in` and `matchesPattern` go only to a service that speaks 4.01; a canonical function the set's `Capabilities.FilterFunctions` leaves out is refused before anything is sent (`ODataIncrementalStoreErrorNotAllowedByService`); a `400` or `501` otherwise is the fetch's error. |

## 2. JSON format consumer (JSON Format §24)

| # | Requirement | Status | Notes |
|---|---|---|---|
| 1 | Understand `metadata=minimal`, or request `none` / `full` | ✅ | Requests `minimal`. Reads `@odata.etag`, `@odata.nextLink`, `@odata.type` and `@odata.editLink` (writes go to the edit link where one is given). `@odata.id` is not needed: the key is in the row. |
| 2 | Consume `metadata=full` responses | ✅ | Extra control information is ignored. |
| 3 | Receive every data type (§7.1) | ⚠️ **live** | Every primitive type, enumerations, complex values and collections (of primitive, enumeration or complex values); see sections 4.3 and 5. Spatial types are left out for now; streams are not in a row but read and written apart, see section 8. |
| 4 | Interpret control information per the payload's `OData-Version` | ✅ | A 4.01 payload may leave out the `odata.` prefix (`@etag`, `@nextLink`, `@type`, `Orders@count`); the client gives such names their prefix when it parses a response, so the store reads one spelling. A payload that says it is 4.0 is taken as it is; one without `OData-Version` (a part of a `$batch` response, say) is read as 4.01. Decimals written with an exponent (`1.5E3`) are read. |
| 5 | Accept unknown annotations and control information | ✅ | Ignored. |
| 6 | Not require `streaming=true` | ✅ | |
| 7a | Accept the `odata.` prefix on control information | ✅ | 4.0 payloads always carry it. |
| 7b | Accept `#` in `@odata.type` | ✅ | With or without it, and as the fragment of a context URL (`…/$metadata#NS.Type`). |
| 7c | Bind related entities with `@odata.bind` in POST / PATCH | ✅ | Inserts bind (`Nav@odata.bind`). Updates use the `$ref` operations instead; see 4.2. |
| 7e | Accept `-INF`, `INF`, `NaN` strings for Single and Double | ✅ | Read into Float and Double attributes, and written that way, since JSON has no NaN or infinity. |
| 7f | Property annotations before or after the property | ✅ | Ignored. |

## 3. Protocol behaviour (Part 1)

| Area | Section | Status | Notes |
|---|---|---|---|
| Service root and `$metadata` fetch | §11.1 | ✅ **live** | Requested as XML. (It used to be sent with a JSON `Accept`, and Northwind refused to open.) CSDL JSON (4.01) is read as well, where a document is JSON. |
| `$metadata` use | §11.1.2 | ✅ **live** | Read when the store opens (CSDL XML: entity types, keys, base types, properties, navigation, enumerations, entity sets, containment). It fills in what the model leaves unsaid, and the model is checked against it (`metadataProblems`). It can also be the model: built at runtime, or generated as a versioned `.xcdatamodeld` by `ois-model`; see the README. |
| Status codes and error bodies | §9, JSON §21 | ✅ **live** | The service's message is the `NSError`'s description; its code, target, details, the HTTP status and the body are in `userInfo` (`ODataErrorCodeKey` and friends). XML error bodies too, for `$metadata`. A `412` is `ODataIncrementalStoreErrorOptimisticLocking`, alone or inside a change set; a save turns it into merge conflicts, see 4.2. |
| Errors surfaced from fetches | | ✅ **live** | A failed request fails the fetch with its `NSError`, for collections and relationships alike; it is never an empty result. |
| Content negotiation for `$count` | §11.2.10 | ✅ **live** | Requested as `text/plain`. |
| Server-driven paging | §11.2.6.7 | ✅ **live** | See 1.5. `$orderby` always ends with the key, because a service resumes a page after its last row's sort values: sorted by category name alone, Northwind skips 17 of 77 products. |
| `Prefer: odata.maxpagesize` | §8.2.8.3 | ✅ | From `fetchBatchSize`. |
| `Prefer: return=representation` | §8.2.8.7 | ✅ | Sent with entity POSTs and PATCHes. A `204` anyway: the new entity is read from `Location` (or `OData-EntityId`), a new ETag from the `ETag` header. |
| Create | §11.4.2 | ✅ **live** | Keys go in the body when the client set them (non-zero, non-empty), so TripPin's `UserName` works and server-assigned integer keys stay unset. |
| Update | §11.4.3 | ✅ **live** | PATCH with the changed attributes; relationships per 4.2. |
| Delete | §11.4.5 | ✅ | |
| ETags / optimistic concurrency | §11.4.1.1 | ✅ **live** | Kept exactly as sent (`@odata.etag` or the `ETag` header) and sent back in `If-Match`; none is sent when the service gave none. A write's response updates it, and after `$ref` requests the entity is read back, since they can change the ETag without returning it. A changed ETag bumps the node version, so Core Data sees a conflict before the service does. |
| Relationship changes (`@odata.bind`, `$ref`) | §11.4.2.2, §11.4.6 | ✅ **live** | See 4.2. |
| Atomic saves (`$batch` change sets) | §11.7 | ✅ **live** | A save of two or more requests is one change set, with absolute URLs (TripPin rejects relative ones in a batch): multipart, or, with a service that speaks 4.01, the JSON batch format (JSON Format §19: one atomicity group, JSON bodies as JSON; in its answer the failed request is the one that is not `424`). A service that refuses the JSON form (400 or 415, say) gets multipart from then on; `ODataIncrementalStoreJSONBatchOption` keeps to multipart from the start. A service that refuses `$batch` (400, 404, 405, 415 or 501 to the batch request) gets the requests one at a time from then on; any other failure fails the save, since TripPin shows a service can apply part of a batch and then answer 500. Inserts whose keys the service assigns are posted before the rest, because Core Data needs their object IDs first; assign keys on the client (`postOnObtainPermanentIDs` off) for a save that is atomic whole. `ODataIncrementalStoreBatchSavesOption` turns batching off. |
| Redirects | §9.1.5 | ⚠️ | See 1.4. |
| Key-as-segment URLs (`Products/1`) | Part 2 §4.3.6 | ✅ | `ODataIncrementalStoreKeyAsSegmentOption`, or on its own when `$metadata` annotates the container `Capabilities.KeyAsSegmentSupported`. Single-part keys, their values bare and percent-encoded (`People/russellwhyte`); compound keys keep parentheses. References in bodies (`@odata.id`, `@odata.bind`) stay canonical, which every service accepts. |
| Percent-encoding of key values in paths | Part 2 §4.3.1 | ✅ | Everything but what a path segment allows and OData's key syntax uses: `Customers('Smith%20%26%20Co%2F2')`. |
| Deep insert | §11.4.2.2 | — | Not needed: a save that inserts related objects is one `$batch` change set, with binds, which is as atomic. |
| Actions and functions | §11.5 | ✅ **live** | `ODataOperationCall`; see section 8. |
| Delta | §11.3 | ✅ **live** | As persistent history; see section 8. |
| Async | §8.2.8.8, §11.6 | ✅ | With `ODataIncrementalStoreRespondAsyncOption`, inside the transport exchange; see section 8. |
| Streams | §11.1.2, §11.4.7–8 | ✅ | Outside Core Data, with `ODataStreamTransfer`; see section 8. |

## 4. Core Data mapping

### 4.1 Fetching

| Core Data | OData | Status | Notes |
|---|---|---|---|
| Fetch an entity | `GET EntitySet` | ✅ **live** | Every page. |
| Fault an object | `GET EntitySet(key)` | ✅ **live** | |
| `predicate` | `$filter` | ✅ | See 4.4. |
| `sortDescriptors` | `$orderby` | ✅ **live** | Paths through relationships use `/` (`Category/CategoryName`); the key is appended as a tiebreaker. |
| `fetchLimit`, `fetchOffset` | `$top`, `$skip` | ✅ **live** | |
| `countForFetchRequest:` | `/$count` | ✅ **live** | |
| `propertiesToFetch` (dictionary results) | `$select`, `$expand` | ✅ **live** | Those properties. A key path through to-one relationships (`category.name`) is an `$expand` with its own `$select`, nested as deep as the path (`Product($select=ProductName;$expand=Category($select=CategoryName))`), since `$select` cannot follow a navigation property (Northwind and TripPin answer 400); the value is read from the expanded row. With only such paths, the row's own `$select` is its key. |
| `NSExpressionDescription`s computed from each row (`unitPrice * 2`), dictionary results | `$compute` | ✅ | `$compute=(UnitPrice mul 2) as twice`, with the name in `$select`, where the service speaks 4.01 and `Capabilities.SelectSupport` does not say `ComputeSupported` false; elsewhere the rows are read as objects and each value computed here, key paths through to-one relationships too. Typed as the description's `expressionResultType` says. |
| Rows read as objects | `$select` | ✅ | A fetch of objects or object IDs, a fault and a relationship read ask for the model's attributes that the service's type has, and a subentity's own behind its cast (`Zoo.Lion/MaxRoar`); an expanded entity's options do the same. Nothing is trimmed without `$metadata`, when a subentity names no type, or where `Capabilities.SelectSupport` says the set has none. |
| `relationshipKeyPathsForPrefetching` | `$expand` | ✅ | Inline entities are cached, a to-one's object ID goes in the row, and a to-many's members are kept, so reading the relationship asks nothing, unless the collection came in pages (`Nav@odata.nextLink`). Each expanded entity names its own to-ones (`Products($expand=Category($select=CategoryID))`). Kept members are dropped with their object's row and at every save, which may move them. |
| `fetchBatchSize` | `Prefer: odata.maxpagesize` | ✅ | The pages are followed to the end, each of that size. |
| `propertiesToGroupBy`, aggregate `NSExpressionDescription`s (dictionary results) | `$apply` | ✅ | OData Data Aggregation: the predicate as `filter()`, then `groupby((paths),aggregate(…))` or `aggregate(…)`, with `sum:`, `min:`, `max:`, `average:` as those methods and `count:` as `$count`. Sent where `$metadata` has `Aggregation.ApplySupported`; elsewhere the rows are read and grouped and aggregated here, with the same result. `havingPredicate`, the sort, the offset and the limit follow the grouping as `filter()`, `orderby()`, `skip()` and `top()` where `ApplySupported/Transformations` lists them and the grouped rows' syntax can say them (comparisons with literals; sorts by `compare:`); otherwise they are applied here, and the offset and limit after whatever was applied here. Keys are Core Data's: `category.name`, and each expression's name. |
| `ODataSearchPredicate` | `$search` | ✅ **live** | Part 2 §5.1.7: words, `"phrases"`, `AND` (or nothing), `OR`, `NOT`, parentheses. Alone or ANDed at the top of the predicate it is sent as `$search` beside the `$filter` the rest makes, counts too; under `OR` or `NOT` it is `ODataIncrementalStoreErrorUnsupportedPredicate`, and a set `SearchRestrictions` calls unsearchable is not asked. Evaluated in memory it looks for each word in the object's strings, regardless of case and diacritics. TripPin searches People and Airports, alone and beside a `$filter`. |
| To-one fault | `GET Entity(key)/Nav` | ✅ **live** | |
| To-many fault | `GET Entity(key)/Nav` | ✅ **live** | Every page; the rows are cached. |
| Firing faults | | ✅ | Every fetched row is cached, and each to-one relationship is expanded to its key (`Nav($select=Key)`), because Core Data asks for every to-one as soon as a fault fires. Firing N faults used to cost N or 2N requests; it costs none. Northwind ignores the nested `$select` and sends the whole related entity, which is cached as well. |
| Refreshing | | ✅ | Every fetch and relationship read refreshes the rows it returns. `-discardCachedRowsForObjectIDs:` drops kept rows, so the next fault reads the service; `refreshObject:mergeChanges:` alone refills from what the store kept. Core Data asks the store for a row during every save, so rows cannot simply expire after one use. |

### 4.2 Saving

| Core Data | OData | Status | Notes |
|---|---|---|---|
| Insert | `POST EntitySet` | ✅ **live** | New objects are posted each after the new objects they refer to, so a new Product can bind to a new Category in the same save; a cycle is closed by a `$ref` after the inserts. |
| Update attributes | `PATCH Entity(key)` | ✅ **live** | |
| Update a to-one relationship | `PUT Entity(key)/Nav/$ref`; `DELETE` it to clear | ✅ **live** | Not a bind in the PATCH: TripPin answers `204` to one and ignores it. |
| Update a to-many relationship | `POST` / `DELETE Entity(key)/Nav/$ref?$id=…` | ✅ **live** | Written from one side only: never from a to-many whose inverse is to-one (that side's reference says it), and for many-to-many from the side whose entity name sorts first. |
| Insert with relationships | `POST` with `@odata.bind` | ✅ | The only way to create an entity whose relationship is required. TripPin answers `500` to a POST with binds, in breach of JSON Format §24 item 7c. |
| Delete | `DELETE Entity(key)` | ✅ | |
| `NSBatchUpdateRequest` | `PATCH EntitySet/$filter(@f)/$each` (§11.4.13) | ✅ | Constant attribute values, as Core Data's own batch updates take; with 4.01, where `UpdateRestrictions` says `FilterSegmentSupported` (and `TypecastSegmentSupported` for a sub-entity). Elsewhere, and for a predicate a filter segment cannot carry (`$search`, application time), the objects are fetched and each PATCHed in one change set. The result type's object IDs or count; the rows the service answers with are kept. No context changes: merge the IDs, as with Core Data's stores. |
| `NSBatchDeleteRequest` | `DELETE EntitySet/$filter(@f)/$each` (§11.4.14) | ✅ | Likewise, `DeleteRestrictions`; also for `-initWithObjectIDs:` (`SELF IN` them). A fetch request with a limit or offset is fetched, then each deleted. The removed entries' keys give the object IDs. |
| Save atomicity | `$batch` change set | ✅ **live** | See section 3. |
| Merge conflicts | `412` → `NSMergeConflict` | ✅ | A `412` on an update or delete (or a `404`: the entity is gone) fails the save with `NSPersistentStoreSaveConflictsError`, one `NSMergeConflict` per object the failed request wrote, holding the row the service has now (none for a deleted entity), read back with its ETag. The context's merge policy settles them and saves again, as with any store; the error policy returns them, with the service's error underneath. FreeCoreData does this from `b7f3a7e` on. |

### 4.3 Model

| Feature | Status | Notes |
|---|---|---|
| Entity set names from `userInfo` or by pluralising | ✅ | |
| Property names from `userInfo` or PascalCase | ✅ | |
| Single and compound keys | ✅ | |
| Key discovery from `$metadata` | ✅ **live** | `userInfo`, else the schema's key (TripPin's `Person` by `UserName`), else an `id` / `<Entity>ID` attribute. Entity sets too: `Person` is in `People`. |
| Derived types (`@odata.type`, type casts) ↔ sub-entities | ✅ | A row's `@odata.type` makes its object one of the sub-entity; fetching a sub-entity casts (`Animals/Zoo.Lion`); a derived insert carries `@odata.type`. A fetch without sub-entities leaves derived rows out client-side, so its `$count` includes them. |
| Complex types | ✅ **live** | A Transformable attribute holding an `NSDictionary` keyed by the service's property names, nested for a nested complex value; members hold what an attribute of their type would (an `NSDate` for an `Edm.Date`, an `NSDecimalNumber`, an enumeration's names), null stays `NSNull`, and a value of a derived complex type keeps `@odata.type`. A change writes the whole value, so set a new dictionary rather than mutating the old one. (Apple's composite attributes, macOS 14 and later, have no FreeCoreData counterpart.) |
| Collections | ✅ **live** | A Transformable attribute holding an `NSArray` of primitive, enumeration or complex values, written whole. TripPin's `Emails` and `AddressInfo` read live. |
| Open entity types, dynamic properties | ✅ **live** | A property bag, `dynamicProperties` (an `NSDictionary`, `OData.dynamicProperties`): what a row has that its type does not declare, typed by its `@odata.type` annotation (JSON Format §4.6.3); written back entry by entry, annotated where JSON does not say the type, a removed one as `null`; filtered and selected by name (`dynamicProperties.Nickname` → `Nickname`). TripPin's `Person` written, read and filtered live, and `ODataService`'s open types the same (their handler reads, keeps and filters them). Open complex types keep undeclared members in their dictionary. |
| Type definitions | ✅ | Read as their underlying type. |
| Enumeration types | ✅ **live** | Member names on a String attribute, values on an integer one (flags or'ed); the qualified literal in `$filter` (`Gender eq NS.PersonGender'Female'`). |

### 4.4 Predicates → `$filter` (Part 2 §5.1.1)

| `NSPredicate` | `$filter` | Status | Notes |
|---|---|---|---|
| `==`, `!=`, `<`, `<=`, `>`, `>=` | `eq`, `ne`, `lt`, `le`, `gt`, `ge` | ✅ | |
| `AND`, `OR`, `NOT` | `and`, `or`, `not` | ✅ | |
| `IN` | `in` (4.01); `eq … or eq …` (4.0) | ✅ **live** | `in` is 4.01 only, and Northwind and TripPin refuse it, so a 4.0 service gets the `or` chain; an empty collection is `false`. |
| `BETWEEN` | `ge` … `and` … `le` | ✅ | gnustep-base rewrites it before translation. |
| `BEGINSWITH`, `ENDSWITH`, `CONTAINS` | `startswith`, `endswith`, `contains` | ✅ | |
| `[c]` | `tolower(…)` on both sides | ✅ | |
| `[d]` | | ✅ refused | OData has no diacritic-insensitive comparison, so the fetch fails with `ODataIncrementalStoreErrorUnsupportedPredicate` rather than match fewer rows than Core Data would. |
| `lowercase:`, `uppercase:` | `tolower`, `toupper` | ✅ | |
| `nil` | `null` | ✅ | |
| Key paths through to-one relationships | `Nav/Prop` | ✅ | |
| Key paths into complex values | `Address/City` | ✅ **live** | `address.city` or `address.City`: members are matched to the schema regardless of case, and literals are typed by the member (an `Edm.Date` member compares with a date). |
| `ANY` / `ALL` on a collection of values | `Emails/any(x0:x0 eq …)`, `AddressInfo/any(x0:x0/City/Name eq …)` | ✅ **live** | Primitive elements are the lambda variable itself; complex ones are reached through their members. |
| `rel == %@`, `!=`, `IN` with managed objects or object IDs | `Nav/Key eq …`, `not (…)`, `Nav/Key in (…)` | ✅ **live** | Compares keys through the to-one path; a compound key compares each part. An unsaved object is an error. |
| `self == %@`, `self IN %@` | `Key eq …`, `Key in (…)` | ✅ | Inside a lambda, against the lambda variable. |
| `ANY` / `ALL` on to-many | `Nav/any(x0:…)`, `Nav/all(x0:…)` | ✅ **live** | Split at the first to-many step; a further to-many step nests another lambda. `ANY` over a to-one path is the plain comparison. |
| `SUBQUERY(…).@count` | `Nav/any(…)`, `not Nav/any(…)`, `Nav/all(…)`; `Nav/$count($filter=…)` | ✅ | Counted against nought: more than none is `any`, none is `not any` (or `all` of a negated body). Any other comparison is `Nav/$count($filter=…) op n` at 4.01 (the variable's paths the member's, `SELF` `$it`; a key path not through the variable is refused), and an error at 4.0. |
| `rel.@count` | `Nav/$count` | ✅ | |
| `entity == %@`, `entity IN %@` | `isof(NS.Type)`, `isof(Nav,NS.Type)` | ✅ | An exact type leaves its subentities out (`isof(A) and not isof(B)`); a subentity's property is written through a cast (`NS.Manager/Budget`). |
| `name.length` | `length(Name)` | ✅ | |
| `LIKE`, `MATCHES` | `matchesPattern` | ✅ | 4.01 only: an error against a 4.0 service. Anchored, since both match the whole string. `LIKE`'s `*` and `?`, and `MATCHES`'s `.`, become any character as ICU takes it (a line terminator too, `\r\n` as one), and `LIKE[c]` lowercases both sides. The pattern is read into a tree (`ODataRegex`) as this platform's `MATCHES` reads it and written as ECMAScript; what ECMAScript cannot say the same (`^` and `$` at each line, Unicode `\d`, `\w`, `\s` and `\b`, inline flags) is an error, as is `MATCHES[c]`, since a regular expression cannot be lowercased safely. |
| Arithmetic (`+ - * /`, `modulus:by:`) | `add`, `sub`, `mul`, `div`, `mod` | ✅ | As Apple and gnustep-base name the functions. A key path the model does not have is an error, not a guess. |
| Date literals | `2024-01-01T12:00:00.5Z`, `2024-01-01` | ✅ **live** | Typed by the attribute compared with: a DateTimeOffset to the microsecond, an `Edm.Date` as the day. |
| UUID literals | unquoted Guid | ✅ | |
| Decimal and Int64 literals | `32.38`, `639260022539945567` | ✅ **live** | Every digit, never an exponent (gnustep-base writes `1E-10` for a small `NSDecimalNumber`; the literal is `0.0000000001`). A Boolean attribute compared with `@0` is `false`. |

## 5. Data types (JSON Format §7.1)

| Edm type | Core Data | Status | Notes |
|---|---|---|---|
| `Boolean` | Boolean | ✅ **live** | |
| `Byte`, `SByte`, `Int16`, `Int32` | Integer 16/32 | ✅ | |
| `Int64` | Integer 64 | ✅ **live** | The store asks for `IEEE754Compatible=true` (JSON Format §3.2), so Int64 travels as a string both ways and keeps every digit: TripPin's `Concurrency`, past 2^53, reads exactly. Numbers are read too. `ODataIncrementalStoreIEEE754CompatibleOption` turns the parameter off for a service that rejects it. An Int64 key read as `"1"` is the same object as `1`. |
| `Decimal` | Decimal | ✅ **live** | As Int64: a string both ways (`"32.3800"`), exact, and never written with an exponent. |
| `Single`, `Double` | Float, Double | ✅ | Including `INF`, `-INF`, `NaN`. Literals are the shortest exact form (`0.1`). |
| `String` | String | ✅ | |
| `DateTimeOffset` | Date | ✅ **live** | Any fraction and any offset read (`2024-03-01T14:34:56.1234567+02:00`); written in UTC to the microsecond. Parsed and written without `NSDateFormatter`, so both platforms agree whatever the locale. A value that is not a date is left out of the row rather than stored as a string. |
| `Date` | Date with `OData.type` `Edm.Date` | ✅ | Midnight UTC of the day, written back as the day. Without `OData.type` a Date attribute is a DateTimeOffset; step 5 learns this from `$metadata` instead. |
| `TimeOfDay`, `Duration` | String / Double with `OData.type` | ✅ | `TimeOfDay` stays a string (`13:20:00`) with an unquoted literal; `Duration` is seconds in a Double (`P1DT2H3M4.5S` is 93784.5), written `PT93784.5S`, with the literal `duration'…'`. |
| `Guid` | UUID, or String with `OData.type` `Edm.Guid` | ✅ | Unquoted in literals and in key paths. |
| `Binary` | Binary Data | ✅ **live** | Written as base64url, the spec's form; both base64url and plain base64 read, since Northwind sends plain base64. Literal `binary'…'`. |
| `Stream`, media entities | | ✅ **live** | Not in a row: a row keeps each stream's links, media ETag and content type; see section 8. |
| Geography, geometry | | — | Left out for now: listed under `OData.unmapped` in a generated model. |
| Enumerations | String or Integer | ✅ **live** | See 4.3. |

## 6. Transport and platforms

| Area | Status | Notes |
|---|---|---|
| HTTPS | ✅ **live** | `NSURLSession`, on Apple and on GNUstep (libcurl, gnutls). gnustep-base's `NSURLConnection` is only the fallback for a gnustep-base built without libcurl. It did not follow a relative redirect, and returned an empty body for a multipart response, which every `$batch` answer is (its MIME parser read the body into parts); gnustep-patches fixes both (`urlprotocol-relative-redirect`, `urlprotocol-multipart-body`). |
| Asynchronous transports | ✅ | Transports report by target-action (`ODataExchange`), and may finish on any thread; the client and store wait for them where they must be synchronous. |
| Basic and Bearer authentication | ✅ | Static credentials; no token refresh hook. |
| Timeouts | ✅ | |
| SAP Gateway CSRF token | ❌ | Vendor-specific: fetch `X-CSRF-Token` before writes. Needed only for SAP services. |
| Tests that exercise headers | ✅ | The snapshot transport refuses what a service would: no `OData-MaxVersion`, a body without a JSON `Content-Type` or `OData-Version`, an `Accept` that rules out the response (`406`). |
| Live smoke test in CI | ✅ | `Tests/Live/ois-live` reads Northwind and writes to TripPin, in a session of its own, on both platforms in CI, reported without failing the build. |

## 7. XML format (Atom)

Needed later for XForms 1.1, whose instance data is XML.

OData v4 defines two separate XML formats, and they have different
standing:

- **CSDL XML** is the `$metadata` document. It is part of the OData 4.0
  and 4.01 OASIS Standards, and every service provides it. The client
  already downloads it and does not parse it; see section 3.
- **The Atom format** (`application/atom+xml`) carries entities, feeds and
  errors as XML. It is specified in
  [OData Atom Format Version 4.0](https://docs.oasis-open.org/odata/odata-atom-format/v4.0/cs02/odata-atom-format-v4.0-cs02.html),
  which stopped at Committee Specification 02 in November 2013: it never
  became an OASIS Standard, and there is no 4.01 version. Part 1 §13.3
  requires clients to speak JSON only.

Server support is split along the same line. Microsoft's WCF Data Services
stack serves Atom: Northwind answers `Accept: application/atom+xml` with a
feed (**live**). The newer ODataLib / ASP.NET OData stack does not: TripPin
answers `415` (**live**). Northwind also answers `415` to
`Accept: application/xml` for a feed, so the media type has to be exact.

That gives XForms two routes, which can coexist:

1. **Map JSON to XML on the client.** The store and the wire stay JSON,
   and the XForms layer builds its instance from the managed objects, or
   from the JSON, and back again. This works with every OData v4 service.
2. **Speak Atom to services that offer it.** A second payload format in the
   client, used only where a service advertises it.

Route 1 needs nothing from this client beyond what the sections above
already require. Route 2 is the checklist below. Both platforms can do the
parsing: `NSXMLParser` and `NSXMLDocument` exist on Apple and in
gnustep-base (through libxml2).

| Area | Atom §§ | Status | Notes |
|---|---|---|---|
| Content negotiation: `Accept: application/atom+xml`, fall back to JSON on `406` / `415` | §3, §4.1 | ❌ | |
| Service document (`app:service`, `app:collection`) | §5 | ❌ | Lists the entity sets; optional for the store. |
| Entity (`atom:entry`, `atom:id`, `atom:category` for the type, `atom:link rel="edit"`) | §6 | ❌ | |
| ETag (`metadata:etag` on the entry) | §6.1.1 | ❌ | Same rules as JSON: keep it verbatim. |
| Properties (`metadata:properties`, `data:Name`, `metadata:type`, `metadata:null`) | §7.1–7.4 | ❌ | Values use the same ABNF literals as the JSON format's strings, so the type work in section 5 carries over. |
| Complex properties and collections (`metadata:element`) | §7.5–7.7 | ❌ | Mapped as for JSON (4.3); only the reading is missing. |
| Navigation links, association links | §8.1–8.2 | ❌ | |
| Expanded navigation (`metadata:inline`) | §8.3 | ❌ | |
| Bind operations in POST / PATCH | §8.5 | ❌ | Same need as `@odata.bind`. |
| Feeds (`atom:feed`, `metadata:count`, `atom:link rel="next"`) | §12 | ❌ | Next links: same paging rules as JSON. |
| Entity references (`metadata:ref`) | §13 | ❌ | For `$ref` relationship updates. |
| Individual property values (`metadata:value`) | §11 | — | Not used by the store. |
| Errors (`metadata:error`, `code`, `message`, `details`, `innererror`) | §19 | ❌ | |
| Request bodies in Atom (POST, PATCH) | §6, §8.4–8.5 | ❌ | |
| Stream properties, media entities | §9–10 | — | As for JSON. |
| Delta responses, bound functions and actions, instance annotations | §14–18 | — | As for JSON. |

For the server described in [server-design.md](server-design.md), Atom is
an output format like any other, and serving it would give XForms clients
route 2 against our own services, whatever third-party services do.

## 8. Beyond fetch and save: plans

What OData offers that a fetch or a save cannot say. None of it is
required of a client (Part 1 §13.3 items 11–15 are MAYs), but operations
and deltas are what real services are built around.

**Actions and functions** (Part 1 §11.5) are methods over the network. A
*function* has no side effects and is called with GET, parameters in the
URL (`GetNearestAirport(lat=33,lon=-118)`); an *action* may change things
and is called with POST, parameters in a JSON body (an invoicing
service's `CreateInvoice`). Bound to an entity
(`People('russellwhyte')/NS.ShareTrip`) one is an instance method; bound
to a collection (`Products/NS.Discount`), a class method; unbound,
reached through an import in the container, a function of the service.
✅ **live**, with `ODataOperationCall` (see the README):

- `$metadata`'s `Function`, `Action`, `FunctionImport` and `ActionImport`
  are read: parameters, their types, the binding parameter, the return
  type. An operation is found by its simple or qualified name among those
  bound to the object's entity type or a base of it; overloads are told
  apart by the parameters given.
- An instance method is called on the object
  (`[russell invokeODataOperation:@"GetFavoriteAirline" parameters:nil error:&error]`),
  a class method on an entity, a service function on the context. Each
  call waits, or, with `-invokeWithTarget:action:`, does not: the action
  arrives on the context's queue.
- Parameters are written by the value coder from their declared types: as
  literals in a function's URL, with complex values, collections and
  objects passed by alias as JSON (`AnimalsIn(Zones=@Zones)?@Zones=[…]`);
  as JSON in an action's body, in the order they are declared (TripPin
  answers `500` to `ShareTrip`'s parameters in another order, **live**).
  An object is passed as a reference (`{"@odata.id": …}`).
- Results come back as the store's fetches do: entities as managed objects
  in the caller's context, their rows kept, every page of a collection;
  other values as the coder reads them. An action that creates an entity
  hands back the new object, already saved. An action bound to an object
  drops its kept row, since it may have changed it.
- Functions in `$filter` and `$orderby` (Part 2 §5.1.1.12): an
  `ODataFunctionExpression` is a function call inside a predicate or an
  `ODataSortDescriptor` (`Zoo.Age(On=2024-01-01) gt 5`,
  `Zoo.Caretaker()/Name eq 'Ann'`, `Animals/Zoo.Heaviest()/Name eq 'Leo'`,
  `$orderby=Zoo.Age(…) desc`), bound to the fetched entity or to where a
  key path leads, with a path on into its result; the compared literal is
  typed by what that path ends at. Evaluated in memory it calls the
  function. ✅ with snapshots only: TripPin parses such filters and answers
  `500 not implemented`, **live**, and Northwind has no functions.
  `FUNCTION(…)` in a format string would have been the natural spelling,
  but gnustep-base parses neither it nor block expressions.
- Generated classes: `ois-model --classes DIR` writes a class per entity,
  mogenerator's way (`_Person`, rewritten each time, and `Person`, the
  client's), with the operations as methods: `-[Person getFavoriteAirline:]`,
  `+[Animal heaviestInContext:error:]`, and the imports on a service class,
  `+[TripPinService getNearestAirportInContext:lat:lon:error:]`. ✅ **live**:
  generated from TripPin's `$metadata`, compiled, and called, on both
  platforms.
- The Workbench can list an object's operations with
  `-[ODataSchema operationsBoundToEntityType:collection:]`.

**Delta** (Part 1 §11.3), mapped onto Core Data's persistent history.
✅ **live**. `-[ODataIncrementalStore fetchRemoteChanges:]` reads what
changed at the service since the store last looked, for every entity with
a set of its own (or those `ODataIncrementalStoreTrackedEntitiesOption`
names):

- The first call reads each set with `Prefer: odata.track-changes` and
  starts tracking it. Later calls follow the `@odata.deltaLink` the last
  page gave, reading both delta formats: entities new or changed (a
  change may carry only the changed properties, which are laid over the
  row the store kept), deleted entities (`@removed` in 4.01,
  `$deletedEntity` in 4.0), and added or deleted links (a change to
  their source). ODataService answers delta links from persistent
  history (see `docs/server-design.md`), and the store is tested over it
  in-process.
- Where there is no delta link, from a service that does not track
  changes or one that stops (TripPin sends a delta link with a collection
  but none with a delta response), or where the delta link is answered
  `410 Gone` (its history purged), the set is read again and compared
  with the rows from the last read. So changes can be followed on any
  service, at the cost of reading the set.
- The answer is an `NSManagedObjectContextDidSaveObjectIDsNotification`-
  shaped notification for `-mergeChangesFromContextDidSaveNotification:`,
  and the rows the store keeps are brought up to date first, so merged
  objects show the changes. A deleted object's last row is kept, since
  merging its deletion fires its fault.
- With `NSPersistentHistoryTrackingKey`, the store keeps persistent history:
  each save is a transaction (author and name from the context), and so is
  each read of remote changes (`ODataRemoteChangesAuthor`). History
  requests are answered by token, date or transaction, with every result
  type, and delete history too; with
  `NSPersistentStoreRemoteChangeNotificationPostOptionKey` the store posts
  `NSPersistentStoreRemoteChangeNotification`. Core Data's history classes
  are abstract on Apple and concrete in FreeCoreData, and the store hands
  out subclasses of its own on both; FreeCoreData's coordinator tokens
  work as well.
- Limits: history lives in memory, as long as the store (a token from an
  earlier store stands before everything); TripPin's delta leaves out
  updates (**live**: a PATCHed person is not in it), which a service that
  sends no further delta link then shows at the next read-and-compare.

**Asynchronous requests** (Part 1 §8.2.8.8, §11.6). ✅ With
`ODataIncrementalStoreRespondAsyncOption`, every request prefers
`respond-async`. One answered `202 Accepted` with a status monitor in
`Location` is followed inside `ODataClient`'s exchange, so neither the
store nor its callers notice: the monitor is polled as `Retry-After`
asks (a second when it does not say), signed as any request, until it
answers; an `application/http` answer is unwrapped and stands as the
response, a `$batch` change set's too. After `asyncTimeout` (600 seconds)
the monitor is `DELETE`d and the request fails. This is for long work, a
large `$batch` or a slow action, behind proxies that cut long requests
off. Tested against ODataService, which answers this way (see
`docs/server-design.md`).

**Streams** (Part 1 §11.1.2, §11.4.7–8) are blobs: a *media entity*
(`HasStream="true"`, TripPin's `Photo`) has its content at
`Entity(key)/$value`, a *stream property* (`Edm.Stream`) at
`Entity(key)/Property`, each with its own read and edit links, content
type and ETag. ✅ **live**, outside Core Data, with `ODataStreamTransfer`:

- A row keeps what the service says of each stream
  (`@odata.mediaReadLink`, `mediaEditLink`, `mediaEtag`,
  `mediaContentType`, and `Photo@odata.…` for a property); a fetch's
  `$select` names the stream properties so that it is sent. A stream the
  row says nothing of is at its conventional URL. Generated models leave
  `Edm.Stream` properties out.
- `-download:` reads a stream into the store's stream directory
  (`ODataIncrementalStoreStreamDirectoryOption`) and keeps the file while
  the row's media ETag is the one it was read at; without one it asks with
  `If-None-Match` and takes `304`. Nothing in it is
  `ODataIncrementalStoreErrorNoStream`.
- `-uploadFile:contentType:` is a `PUT` to the edit link with `If-Match`
  when the media ETag is known; the file then stands as downloaded, at
  the ETag the service answered with. `-remove:` empties a stream property.
- A transfer made with an entity instead of an object `POST`s its first
  upload to the entity set: a new media entity, whose other properties
  are then set on the object and saved as any change is.
- Each waits, or with a target and action does not, as operation calls
  do. Streams are not written inside a `$batch`.
- **live** against TripPin's `Photo`, a media entity: downloaded, uploaded
  again, and a new one created from a file and then named. TripPin wants
  `If-Match` on an upload (`428` without it), ignores `If-None-Match`,
  refuses bytes that are not an image, and answers an upload `200` with
  the entity and no `ETag` header, so the new media ETag is read from the
  entity (it had been lost, and the next upload would have been refused).

## 9. Vocabularies

A vocabulary is a set of *terms* that a service applies to its model with
annotations (CSDL §14): inline on an element of `$metadata`, or collected in
`<Annotations Target="…">`, under an alias the document declares with
`<edmx:Reference>`/`<edmx:Include>`. Terms can also appear in payloads as
instance annotations (`"@Core.Messages": […]`). OASIS standardises nine
vocabularies in
[odata-vocabularies](https://github.com/oasis-tcs/odata-vocabularies/tree/master/vocabularies)
(`Org.OData.<Name>.V1`, as XML, JSON and Markdown).

Each one has two sides here. The client reads the terms and acts on
them. The server (see [server-design.md](server-design.md)) writes them
into its `$metadata` from the Core Data model, and enforces the ones that
constrain requests. Where Core Data has the concept already, the model
is the source of truth and the annotation is derived from it. Anything
else is kept in `userInfo`, as the other `OData.*` mappings are.

✅ Annotations are read in general (`ODataSchema`): inline and in
`<Annotations Target>`, under the document's aliases or a standard
vocabulary's own name, with qualifiers, annotations of annotations
(`Validation.Maximum@Validation.Exclusive`, as JSON CSDL keys them), and
every expression (constants, paths, `Collection`, `Record`, `If`, `Apply`
and the rest), as JSON CSDL values. A model built from `$metadata` carries
every annotation of an entity or property in `userInfo`
(`OData.annotations`), for the application. What is marked ✅ below is
done on both sides; the rest is ❌ unless marked otherwise.

**Wanted first: Core, Validation, Authorization.**

- **Core** (44 terms). The ones that change behaviour:
  - ✅ `Computed` and `Immutable`. The client leaves computed properties
    out of POST and PATCH, and immutable ones out of PATCH. The server
    writes `Computed` for derived attributes and the version, and either
    from `userInfo` (`OData.computed`, `OData.immutable`); it ignores a
    computed value in a body, and refuses to change an immutable one
    (`400`).
  - ✅ `Permissions` (`Read`, `ReadWrite`): a read-only attribute, which
    both sides treat as computed (`OData.permissions`).
  - ✅ `OptimisticConcurrency`: the properties an ETag is made of. This
    answers the server's ETag open question with a standard spelling.
  - ✅ `Description` and `LongDescription`: documentation, from
    `OData.description` and `OData.longDescription`. They become comments
    in generated classes.
  - ✅ `Messages`, as an instance annotation: warnings and details
    alongside a success. A handler or an operation adds them to the
    request (`-[ODataRequest addMessage:code:severity:target:]`), and the
    service writes them into the JSON body as
    `@Org.OData.Core.V1.Messages`, as `Prefer: odata.include-annotations`
    allows (a `204` has no body to carry them). The client reads them
    (`ODataMessage`) and the store posts
    `ODataIncrementalStoreDidReceiveMessagesNotification`, with the object
    they are about when there is one (a POST's, a PATCH's, a row's own).
  - `MediaType`, `AcceptableMediaTypes`, `IsMediaType`, `IsURL`: for
    streams (section 8).
  - `Revisions`: deprecation. The client could warn when a request uses a
    deprecated element.
  - `ContentID`, `DefaultNamespace`, `Ordered`, `PositionalInsert`:
    later.
- **Validation** (14 terms): `Pattern`, `Minimum`/`Maximum` with
  `Exclusive`, `AllowedValues`, `MultipleOf`, `MinItems`/`MaxItems`,
  `Constraint`, `DerivedTypeConstraint`. These map onto Core Data's own
  validation:
  - `Pattern` is a `MATCHES` validation predicate: ECMAScript's pattern,
    found anywhere, written in ICU's syntax (`ODataRegex`); none where the
    two cannot say the same.
  - `Minimum` and `Maximum` are the attribute's min and max values.
  - `AllowedValues` is an `IN` predicate.
  - `MinItems` and `MaxItems` are a to-many relationship's min and max
    counts.

  ✅ The client adds them to models it builds from `$metadata`, so an
  invalid object fails at `-save:` locally rather than as a `400`; the
  facet `MaxLength` too, as `length <= n`. The server writes them from the
  model's validation predicates, as Xcode and FreeCoreData's momc write a
  minimum, a maximum, a length and a pattern (`SELF >= 1`, `SELF < 100` as
  a `Maximum` with `Exclusive`, `length <= 50` as `MaxLength`, `SELF
  MATCHES "..."`, `SELF IN {...}`), and a to-many relationship's counts as
  `MinItems`/`MaxItems`; enforcement comes free: `-save:` validates, and
  the failure becomes a `400` whose `details` name each property.
  ✅ `MultipleOf` and `Constraint`, which Core Data cannot hold, are
  checked before a save on both sides (`-[ODataPropertyMapper
  vocabularyViolationOfObject:]`): a `Constraint`'s condition (`Eq`, `Ne`,
  `Gt`, `Ge`, `Lt`, `Le`, `And`, `Or`, `Not`, `If`, `In`, paths, `Null`,
  constants, `odata.matchesPattern`) as a predicate of the entity's
  objects; a property's only while it has a value. The service answers
  `400` with the constraint's `FailureMessage`; the client refuses the save
  with a validation error before sending it. `DerivedTypeConstraint` is
  not mapped.
- **Authorization** (2 terms: `SecuritySchemes`, `Authorizations`, with
  API key, HTTP basic or bearer, OAuth 2 flows and OpenID Connect). This
  vocabulary describes authentication; it does not perform it.
  - ✅ The server declares what its authenticator enforces:
    `HSJWTAuthenticator` an `OpenIDConnect` scheme with its issuer,
    `HSTokenIntrospectionAuthenticator` an `Http` bearer one, each with
    `SecuritySchemes` naming the scopes a token needs; anything else
    through the service's `containerAnnotations`.
  - ✅ The client reads it (`schema.authorizations`, in `SecuritySchemes`
    order, with their scopes) and signs requests the first way its
    credentials can: a bearer token (the configuration's, or an
    `ODataCredentialProviding` provider's, asked again for a fresh one
    after a `401`), a user and password for `Http` basic, or an API key in
    the header, query option or cookie `ApiKey` names. Refused still, the
    error's recovery suggestion says what the service would take. A `403`
    for want of a scope (`WWW-Authenticate: Bearer
    error="insufficient_scope", scope="…"`) carries the scopes in
    `ODataErrorScopesKey`, and a recovery suggestion to ask the identity
    provider for them. A
    service can let anyone read `$metadata` (`allowsAnonymousMetadata`, or
    the `AllowAnonymousMetadata` setting) so that a client learns how to
    sign in.

- ✅ **Capabilities** (40 terms): what a service allows, per set.
  - The server declares what it does (`ConformanceLevel` Intermediate,
    `TopSupported`, `SkipSupported`, `BatchSupported` and `BatchSupport`,
    `SelectSupport`, `KeyAsSegmentSupported`, `DeepInsertSupport`,
    `DeepUpdateSupport`, `IndexableByKey`, `FilterFunctions`, and per set
    `SearchRestrictions`, searchable unless the handler's
    `searchableProperties` is empty), and what each set's handler allows:
    `Insert/Update/DeleteRestrictions`, and `FilterRestrictions` and
    `SortRestrictions` from its `nonFilterableProperties` and
    `nonSortableProperties`, which it enforces (`400`).
  - The client does not send what they rule out: without `$top` or
    `$skip`, or sorting by a property, it sorts, skips and limits the rows
    itself; without `$count`, it counts the keys; without `$expand`, or
    `$select`, it leaves them out; without `$batch`, it saves one request
    at a time. A filter the service will not take, or an insert, update
    or delete it refuses, fails before it is sent, with
    `ODataIncrementalStoreErrorNotAllowedByService`; `NonInsertable`
    and `NonUpdatableProperties` are left out of bodies.

- ✅ **Measures** (`ISOCurrency`, `Scale`, `Unit`, `UNECEUnit`):
  a model built from `$metadata` carries them in `userInfo`
  (`OData.isoCurrency`, `OData.scale`, `OData.unit`), and
  `ODataPropertyMapper` answers `-unitOfAttribute:`, `-scaleOfAttribute:`
  and `-currencyOfAttribute:inObject:`, which reads the currency from the
  object when `ISOCurrency` is a path to another property. The server
  writes the same `userInfo` as the terms, a currency naming an attribute
  as a path.
- ✅ **JSON**: a property of type `JSON.JSON` (`Edm.Stream` of
  `application/json`) is any JSON value, inline in payloads as 4.01 has
  it; a model keeps it in a Transformable attribute as it is, and a
  server serves a Transformable attribute (as it is) or a String one (as
  its JSON text) declared `OData.type` `Org.OData.JSON.V1.JSON`.
  `JSON.Schema` is carried as any annotation is.
- ✅ **Repeatability** (`Supported`; OData Repeatable Requests 1.0): a
  service that says it has them gets `Repeatability-Request-ID` and
  `Repeatability-First-Sent` on every write, and a write that has no
  answer at all is sent again, as it was, up to twice. `ODataService`
  remembers each answer `repeatabilityDuration` (an hour) and gives a
  repeat the same answer (`Repeatability-Result: accepted`); one first
  sent longer ago, or an ID reused for another request, is `400`,
  `rejected`. Deleting remembered requests
  (`DeleteWith…IDSupported`) is not offered.
- ✅ **Aggregation**: `ApplySupported`, with `$apply` (section 4.1).
- ✅ **Temporal** (OData-Temporal), for application time with a visible
  timeline: each row a time slice, its period two Date attributes named in
  the entity's `userInfo` (`OData.periodStart`, `OData.periodEnd`, and
  `OData.objectKey` for which object a slice belongs to; periods
  closed-open, or closed-closed for dates with
  `OData.closedClosedPeriods`; no end, or 9999-12-31, for none). A model
  built from `$metadata` sets these from `Temporal.ApplicationTimeSupport`.
  `ODataTemporalPredicate` asks for a point (`$at`) or an interval
  (`$from` with `$to` or `$toInclusive`), ANDed with the rest of the
  predicate, and evaluates the same in memory;
  `-performTemporalAction:onEntityNamed:deltaTimeslices:context:error:`
  calls `Temporal.Update`, `Upsert` and `Delete`, and refreshes the
  context's objects of the entity. `ODataService` serves both (see
  `docs/server-design.md`). A snapshot timeline, where slices hide behind
  an object's key, is not done: Core Data has one row per key. This is
  application time, not the system time Core Data's persistent history
  records, which delta links use.
- — Geographic types: left out, unless a clean and simple mapping to Core
  Data turns up.

The work common to all of them:

- Read `<Annotation>` and `<Annotations Target>` in general, with their
  constant and dynamic expressions (`Path`, `Collection`, `Record`, `If`,
  `Apply`), into `ODataSchema`. The one term read today is special-cased.
- Resolve terms through the aliases the document declares.
- Carry the terms the client does not act on through to the generated
  model's `userInfo`, so an application can read them.

## Order of work

1. ~~**Can connect and read correctly:** request headers, errors from
   fetches, next links (collections and to-many), `$orderby` through
   relationships, managed objects in predicates, `ANY` / `ALL`. Make the
   snapshot transport check headers, and add the live smoke test.~~
   Done.
2. ~~**Can write correctly:** keep the real ETag and send it back unchanged
   (and send none when there is none); send relationships with
   `@odata.bind`; `Prefer: return=representation`; client-supplied keys
   in POST.~~ Done.
3. ~~**Types:** `DateTimeOffset` in full, `Date`, `IEEE754Compatible` for
   Int64 and Decimal, `INF` / `NaN`, Binary.~~ Done, with `TimeOfDay` and
   `Duration` as well.
4. ~~**Robustness:** `$batch` change sets for atomic saves, OData error
   bodies, percent-encoded keys, `@odata.editLink`, cache refresh,
   `Prefer: odata.maxpagesize` from `fetchBatchSize`.~~ Done.
5. ~~**Model:** read `$metadata`: validate the Core Data model against it,
   discover keys, then derived types and enums.~~ Done, with models built
   from `$metadata` at runtime and generated ahead of time, versioned as
   Core Data versions a model.
6. ~~**Types, the rest:** complex types and collections, 4.01 payloads,
   key-as-segment.~~ Done; spatial types left out for now.
7. ~~**Versions:** speak 4.01 or 4.0 as the service does.~~ Done: `IN`
   had been sent as `in`, which both 4.0 reference services refuse.
8. ~~**Actions and functions**~~ Done, with composable functions in
   `$filter` and `$orderby`, and generated classes whose methods they are;
   and ~~**delta**~~, done as persistent history; see section 8.
9. **XML, for XForms:** JSON-to-XML mapping on the client first, since it
   works with every service; then Atom as a second wire format where a
   service offers it (section 7). Parsing CSDL XML in step 5 builds the
   XML reading this needs.
10. **Vocabularies:** general annotation reading first. Then Core,
   Validation and Authorization on both the client and the server, and
   Capabilities after them (section 9).
