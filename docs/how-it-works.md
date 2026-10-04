# How it works

What each Core Data idea becomes in OData and what runs where, at a glance.
For the protocol item by item, see the [client conformance](odata-conformance.md)
page and the [server design](server-design.md) page. This page describes how
the code works today.

The client and the server use the same mapping (`ODataPropertyMapper`, in
ODataKit). A model the server writes as `$metadata` is therefore the model
the client reads back.

## The model

| Core Data | OData | Notes |
|---|---|---|
| Entity | Entity type, in an entity set | The set's name comes from `OData.entitySet`, or from `$metadata` (Person is in People), or else it is the entity's name |
| Super-entity | Base type | A sub-entity in its base type's set is read at `People/NS.Employee` and posted with `@odata.type` |
| Attribute | Structural property | The wire name comes from `OData.property`, or it is the name in PascalCase (`unitPrice` → `UnitPrice`) |
| Key attributes | `<Key>` | `OData.key` on the entity (comma-separated); without it, the key from `$metadata` |
| To-one / to-many relationship | Navigation property, single / `Collection(…)` | An inverse is a partner |
| Integer attribute with `OData.etag` | The ETag, `W/"<version>"` | The server increments it on every update. Without one, the ETag is a hash of the values |
| Transformable attribute | Complex value, or `Collection(…)` | Members are key paths past the attribute: `address.city` → `Address/City` |
| Transformable attribute with `OData.dynamicProperties` | An open type's dynamic properties | An `NSDictionary`; each entry is a property of its own on the wire: `dynamicProperties.Nickname` → `Nickname` |
| Binary attribute with `OData.stream` | `Edm.Stream` property | Read and written at its own URL, never in a body |
| Binary attribute named by the entity's `OData.mediaStream` | Media entity (`HasStream`), at `$value` | |
| Entity with `OData.periodStart`/`periodEnd` | Timeline entity set (`Temporal.TimelineVisible`) | Each row is a time slice of an object |
| Transient attribute | Not served | |

### Attribute types

| Core Data | Server writes | Client also accepts |
|---|---|---|
| String | `Edm.String` | `Edm.TimeOfDay`, enumerations |
| Boolean | `Edm.Boolean` | |
| Integer 16 / 32 / 64 | `Edm.Int16` / `Int32` / `Int64` | `Edm.Byte`, `SByte`; enumerations as numbers |
| Decimal | `Edm.Decimal` | `Edm.Double` |
| Double | `Edm.Double` | `Edm.Decimal`, `Single`, `Duration` (seconds) |
| Float | `Edm.Single` | |
| Date | `Edm.DateTimeOffset` | `Edm.Date` |
| Binary | `Edm.Binary` | |
| UUID | `Edm.Guid` | `Edm.Guid` as a String attribute |
| URI | `Edm.String` | |
| Transformable | via `OData.type` | complex types, collections |

`OData.type` on an attribute overrides the type the server writes; an
`Edm.Date` on a Date attribute is the common case. Geography and geometry
types are not mapped.

### `userInfo` keys

| Key | On | Meaning |
|---|---|---|
| `OData.entitySet` | entity | The entity set's name |
| `OData.type` | entity, attribute | A qualified entity type name; an attribute's Edm type |
| `OData.key` | entity | Key attributes, comma-separated |
| `OData.property` | attribute, relationship | The wire name |
| `OData.etag` | Integer attribute | The entity's version, sent as its ETag |
| `OData.computed` | attribute | `Core.Computed`: the service sets it, and the client never writes it |
| `OData.immutable` | attribute | `Core.Immutable`: written on insert only |
| `OData.permissions` | attribute | `Core.Permissions`: `Read`, `ReadWrite` or `None` |
| `OData.description`, `OData.longDescription` | any | `Core.Description`, `Core.LongDescription` |
| `OData.annotations` | any | Any other terms, as JSON CSDL (`{"Validation.Pattern": "^[A-Z]"}`) |
| `OData.unit`, `OData.isoCurrency`, `OData.scale` | attribute | `Measures.Unit`, `ISOCurrency` (a code, or the attribute that holds one), and `Scale` |
| `OData.stream` | Binary attribute | The attribute is an `Edm.Stream` property |
| `OData.mediaStream` | entity | The Binary attribute that is its media resource |
| `OData.contentType` | stream attribute | The String attribute that holds the stream's content type |
| `OData.periodStart`, `OData.periodEnd` | entity | The period's Date attributes (no end, or 9999-12-31, means open) |
| `OData.objectKey` | entity | The attributes that say which object a time slice belongs to |
| `OData.closedClosedPeriods` | entity | `YES`: the period's end is its last day (`Edm.Date` only) |
| `OData.unmapped` | entity | Written by `ois-model`: what could not be mapped (spatial types) |
| `OData.dynamicProperties` | Transformable attribute | `YES`: the property bag of an open type's dynamic properties |
| `OData.served` | attribute, relationship | `NO`: not served, nor sent by a client; the application's own |

`$metadata` fills in whatever the model does not say. When both say
something, the model's `userInfo` wins.

## Reading: a fetch request as a URL

`ODataQueryBuilder` and `ODataPredicateTranslator`, on the client. Every
query is typed before it is written: the translator builds a predicate
into an `ODataExpression` tree, and the builder makes a fetch request
into ODataKit's `ODataQueryOptions` (order items, select and expand
items with options of their own, `$apply`'s transformations), which the
builder alone writes into a URL, and which the store sends through one
reader for fetches, grouped fetches and `ODataQuery` alike.
`+[ODataQuery queryWithFetchRequest:inContext:error:]` gives a fetch's
query, typed, to go on from; the server parses a request into the same
types. The URL is the tree's own writing, in parentheses only where
precedence needs them: `UnitPrice gt 20 and Discontinued eq false`.

| `NSFetchRequest` | Request |
|---|---|
| `entity` | `GET Products`, or `GET People/NS.Employee` for a sub-entity |
| `predicate` | `$filter` (below) |
| `sortDescriptors` | `$orderby`, with the key appended as a tiebreaker: `UnitPrice desc,ProductID` |
| `fetchLimit`, `fetchOffset` | `$top`, `$skip`; then `@odata.nextLink` is followed until the limit is reached |
| `resultType = NSCountResultType` | `GET Products/$count?$filter=…` |
| `relationshipKeyPathsForPrefetching` | `$expand`, nested for key paths (`category.products` → `Category($expand=Products)`) |
| `propertiesToFetch` (managed objects) | `$select` |
| `propertiesToFetch` with key paths (dictionaries) | `$select`, plus nested `$expand($select=…)` for key paths through to-one relationships (`$select` cannot follow navigation) |
| `propertiesToGroupBy` + aggregate expression descriptions | `$apply=filter(…)/groupby((…),aggregate(…))` |
| A non-aggregate `NSExpressionDescription` (`unitPrice * 2`) | `$compute=UnitPrice mul 2 as doubled` |
| `ODataSearchPredicate` (ANDed with the rest) | `$search` |
| `ODataTemporalPredicate` | `$at`, or `$from` with `$to` / `$toInclusive` |
| Managed objects and object IDs | `$select` of the mapped properties, and each to-one relationship not prefetched as `$expand=Category($select=CategoryID)`, so a relationship fault knows its destination without a request |

### Predicates as `$filter`

| `NSPredicate` | `$filter` |
|---|---|
| `a == b`, `!=`, `<`, `<=`, `>`, `>=` | `eq`, `ne`, `lt`, `le`, `gt`, `ge` |
| `AND`, `OR`, `NOT` | `and`, `or`, `not` |
| `name ==[c] 'x'` | `tolower(Name) eq tolower('x')` |
| `BEGINSWITH`, `ENDSWITH`, `CONTAINS` (with `[c]`) | `startswith`, `endswith`, `contains` (with `tolower`) |
| `LIKE 'Ch?i*'` | `matchesPattern(Name, '^Ch.i.*$')`, 4.01 only, each wildcard written as any character including line breaks |
| `MATCHES 're'` | `matchesPattern(Name, '^re$')`, 4.01 only, not `[c]`; read as a tree (`ODataRegex`) and written in ECMAScript, and refused where ECMAScript cannot say the same |
| `x IN {a, b}` | `x in (a,b)` in 4.01; `x eq a or x eq b` in 4.0 |
| `x BETWEEN {a, b}` | `x ge a and x le b` |
| `category == %@` (an object or object ID) | `Category/CategoryID eq 1` |
| `category.name == 'x'` | `Category/Name eq 'x'` |
| `ANY products.price > 20`, `ALL …` | `Products/any(p:p/Price gt 20)`, `all(…)` |
| `SUBQUERY(products, $p, …).@count > 0` | `Products/any(p:…)` |
| `SUBQUERY(products, $p, $p.price > 20).@count > 2` | `Products/$count($filter=Price gt 20) gt 2` (4.01) |
| `products.@count > 2` | `Products/$count gt 2` |
| `name.length > 3` | `length(Name) gt 3` |
| `lowercase:(x)`, `uppercase:(x)` | `tolower(x)`, `toupper(x)` |
| `+ - * / %` | `add`, `sub`, `mul`, `div`, `mod` |
| `entity == %@` | `isof(NS.Employee)` (and `not isof` for its sub-entities) |
| `ODataFunctionExpression` | Any OData function: `year(Hired)`, a bound function… |
| `[d]` (diacritic-insensitive) | **Refused**: OData has no such comparison |

A predicate the translator cannot write is an error. It is never quietly
evaluated in memory, because that would read every row.

## Writing: a save as requests

| Core Data | Request |
|---|---|
| Inserted object | `POST Products`, with to-one relationships as `Category@odata.bind` |
| Updated object | `PATCH Products(1)` with `If-Match: <etag>`, changed properties only |
| A changed relationship | `PUT`/`POST`/`DELETE …/Category/$ref` |
| Deleted object | `DELETE Products(1)` with `If-Match` |
| Two or more changes | One `$batch` change set: multipart, or JSON with a 4.01 service. It takes effect whole or not at all |
| `412` / `404` in a save | `NSPersistentStoreSaveConflictsError` with an `NSMergeConflict` per object; the context's merge policy settles it |
| A stream property / media entity | `PUT …/Photo` / `PUT …/$value`, with the media ETag |
| Repeatable requests (when the service supports them) | `Repeatability-Request-ID`, `-First-Sent`, so a retried save is not applied twice |
| `-performTemporalAction:…` | `POST Budgets/Org.OData.Temporal.V1.Update` (or `Upsert`, `Delete`) |
| `NSBatchUpdateRequest` | `PATCH Products/$filter(@f)/$each?@f=…` with the values, where the service takes a filter segment (4.01, `Capabilities.UpdateRestrictions/FilterSegmentSupported`); elsewhere, the objects fetched and each PATCHed, in one change set |
| `NSBatchDeleteRequest` | `DELETE Products/$filter(@f)/$each?@f=…`, likewise; one with a limit or offset, the objects fetched and each deleted |

Changes at the service go the other way: `-fetchRemoteChanges:` follows
`@odata.deltaLink`, and a set is read again and compared where the service
gives no delta links. The result is a notification to merge.

## What runs where

The rule is that computation goes as far down as it can: the client asks the
service, and the service asks the Core Data store, which for SQLite means
SQL. The tables below show where each step runs today, and where it could
move further down.

### Client: service, or here?

The client sends everything to the service unless the service's
`$metadata` says it cannot do that step.

| Step | Where | When it runs here instead |
|---|---|---|
| `$filter` | Service | Never. A filter the service refuses (`FilterRestrictions`) is an error |
| `$orderby` | Service | When it is not `Sortable`, or a key is a `NonSortableProperty`. Every row is then read, sorted here, and then skipped and limited here |
| `$top`, `$skip` | Service | When `TopSupported` or `SkipSupported` is false |
| `$count` | Service | When it is not `Countable`: the keys are read and counted here |
| `$select` | Service | When `SelectSupport/Supported` is false, whole rows are read |
| `groupby`, `aggregate` | Service with `Aggregation.ApplySupported` | When it is not declared, the matching rows are read and grouped here |
| `havingPredicate`, and the sort, offset and limit of a grouped fetch | Service, as `$apply=…/filter(…)/orderby(…)/skip(n)/top(n)` after the grouping | Each one the service does not list in `ApplySupported/Transformations`, or that its grouped-row syntax cannot say (a `havingPredicate` beyond comparisons with literals, a sort with a comparator); the offset and limit then too |
| `$compute` | Service, when it speaks 4.01 | With 4.0, or when `ComputeSupported` is false: evaluated here from each object |
| Faults | Here, from cached rows | A fault fires a request only when its row is not cached. Prefetched (`$expand`) rows fill the cache |

### Server: store, or service memory?

`ODataService` turns a request back into an `NSFetchRequest`
(`ODataPredicateBuilder`), and gives it to a handler, which by default runs
it on the store.

| Step | Where | How |
|---|---|---|
| `$filter` | **Store** | An `NSPredicate` ([below](#filter-as-nspredicate)) |
| `$orderby` on key paths | **Store** | Sort descriptors |
| `$top`, `$skip`, server paging, `$count` | **Store** | `fetchLimit`/`fetchOffset`, `countForFetchRequest:` |
| `$search` | **Store** | `CONTAINS[cd]` over the string properties, per word |
| `$at`, `$from`/`$to` | **Store** | A filter over the period |
| Delta links | **Store** | Persistent history since the token |
| `$apply` `filter` (and `search`) steps before the first grouping | **Store** | Folded into the fetch's predicate |
| `$apply`'s first `groupby` or `aggregate`, right after those filters | **Store**, where it can be exact | A dictionary fetch with `propertiesToGroupBy` and aggregate expressions: `GROUP BY` in SQLite and FreeCoreData's SQL stores. Grouped by attributes through to-one relationships; `$count`, `sum` and `average` of integers and doubles, `min` and `max` of numbers and dates |
| Other groupings (by a computed value, of decimals, strings, `countdistinct`; on Apple, over a store other than SQLite), `compute`, `topcount`…, `concat`, and anything after the first grouping | Memory | `ODataApply` over the fetched (or grouped) rows, bounded by `maxRowsInMemory` |
| `$filter` on a `$compute`d value | **Store** | The computed expression in the predicate: `$compute=UnitPrice mul 2 as T&$filter=T gt 40` is `unitPrice * 2 > 40` |
| `$orderby` on a `$compute`d name that stands for a path | **Store** | That path's key path |
| `$orderby` on any other `$compute`d value | Memory | The fetch is sorted, skipped and limited in memory, bounded by `maxRowsInMemory`: Core Data sorts by key paths only |
| `$compute` values | Memory | Evaluated per row as it is written |
| First-level `$expand` | **Store** | `relationshipKeyPathsForPrefetching` on the fetch |
| `$expand` of a to-many relationship, with its own `$filter`, `$search` and `$orderby` | **Store** | For every parent on the page at once, filtered and sorted there, then split among the parents: a one-to-many in one fetch (`inverse IN parents`); a many-to-many, or one with no inverse, in two (the parents with the relationship prefetched, then `SELF IN` their related rows). Nested expansions and `$levels` likewise, per level |
| Its `$top`, `$skip` and `$count`, per parent; an expansion with its own `$compute`; a page whose many-to-many members are more than 500 | Memory | Over each parent's members |
| Temporal actions (split and trim) | Memory, then store | The slices read through the handler, the changes worked out here, then written through the handler |
| `PATCH` and `DELETE` of `Collection/$each`, `$filter(…)` path segments | **Store**, then each row | The members read in one fetch, then each updated or deleted through the handler |
| A write's references (`@odata.bind`, `$ref`, a nested entity's `@id` or key), new integer keys | **Store** | Read through the handler before anything is written; a new key counts on from the largest, read once per write |

### `$filter` as `NSPredicate`

`ODataPredicateBuilder` writes every `$filter` as a predicate that the store
evaluates, so no filtering happens in the service's memory. A function the
store has no equivalent for works only when it is compared with a literal:
the comparison is then rewritten into something the store does have.

**Comparisons and logic**

| `$filter` | `NSPredicate` |
|---|---|
| `Price gt 20` | `price > 20` (and `eq`, `ne`, `lt`, `le`, `ge`) |
| `a and b`, `a or b`, `not a` | `AND`, `OR`, `NOT` |
| `Name eq null` | `name == nil` |
| `Category/Name eq 'x'` | `category.name == 'x'` |
| `ID in (1, 2)` | `id IN {1, 2}` |
| `Style has NS.Style'Bold'` | `style IN {…}`: every flag value that includes Bold |
| `Price add 5 gt 20` | `price + 5 > 20` (and `sub`, `mul`, `div`, `mod`) |
| `Hired lt now()` | `hired < <the request's time>` |

**Navigation and types**

| `$filter` | `NSPredicate` |
|---|---|
| `Products/any(p:p/Price gt 20)` | `SUBQUERY(products, $p, $p.price > 20).@count > 0` |
| `Products/all(p:p/Price gt 20)` | `SUBQUERY(products, $p, NOT $p.price > 20).@count == 0` |
| `Products/$count($filter=Price gt 20) gt 2` | `count:(SUBQUERY(products, $p, $p.price > 20)) > 2` |
| `Products/any()` | `products.@count > 0` |
| `Products/$count gt 2` | `products.@count > 2` |
| `isof(NS.Manager)` | `entity IN {Manager, and its sub-entities}` |
| `cast(Boss, NS.Manager)/Budget gt 5` | Holds only for objects of that entity |

**Strings**

| `$filter` | `NSPredicate` |
|---|---|
| `startswith(Name, 'Ch')` | `name BEGINSWITH 'Ch'` |
| `endswith(Name, 'ai')` | `name ENDSWITH 'ai'` |
| `contains(Name, 'ha')` | `name CONTAINS 'ha'` |
| `tolower(Name) eq 'chai'` | `name ==[c] 'chai'` (and `toupper`) |
| `length(Name) gt 3` | `name MATCHES '.{4,}'` |
| `substring(Name, 1, 2) eq 'ha'` | `name MATCHES '.ha.*'` |
| `indexof(Name, 'a') eq 2` | a `MATCHES` expression: no `a` before position 2, then `a` |
| `trim(Name) eq 'Chai'` | `name MATCHES '\s*Chai\s*'` |
| `concat(First, 'x') eq 'Annx'` | `first == 'Ann'` |
| `matchesPattern(Name, '^C')` | `name MATCHES '\AC.*'` (ECMAScript's search, made a whole-string match, in ICU's syntax) |

The regular expressions above are sketches; the builder makes them as trees
(`ODataRegex`), which escape the literals and anchor the patterns. `substring`, `trim` and `concat` are compared with
`eq` and `ne` only.

**Dates**

| `$filter` | `NSPredicate` |
|---|---|
| `year(Hired) eq 2025` | `hired >= 2025-01-01 AND hired < 2026-01-01` |
| `year(Hired) gt 2025` | `hired >= 2026-01-01` |
| `date(Hired) eq 2025-03-01` | `hired >= 2025-03-01 AND hired < 2025-03-02` |
| `month(Hired) eq 3` | One March range for each year from the earliest to the latest `hired` in the store, ORed |
| `day()`, `hour()`, `minute()`, `second()` | Likewise, one range for each month, day, hour or minute; more than 200 ranges is 501 |

### What stays in memory, and why

| In memory | Why |
|---|---|
| `$orderby` by a computed value beyond a path | Core Data sorts a fetch by key paths only: an `NSSortDescriptor` has no expression, and a fetch is not sorted by an `NSExpressionDescription` |
| `sum` and `average` of decimals, `min` and `max` of strings, `countdistinct` | SQLite sums decimals as doubles, and SQL orders strings by collation rather than as `NSString` does; Core Data has no count of distinct values |
| An expanded to-many's `$top` and `$skip` | Per parent: one fetch for every parent cannot page each one |
| `$apply` after the first grouping, and `compute` and the top and bottom kin | Over grouped rows, which are the service's, not the store's |
| A recursive hierarchy's nodes and parents, and `ancestors`, `descendants` and `traverse` | Core Data has no recursive query; the functions (`isdescendant`, …) are then `IN` a set of identifiers, in the store |

What neither the store nor the service does: arithmetic on a
collection's aggregate or count (`Products/$count mul 20 gt 50`,
`Products/aggregate(UnitPrice with sum) div 2 gt 20`). The service reads
each as a key path's collection operator (`products.@count * 20`), which
Apple's SQLite store refuses to evaluate; the answer is `501`, with the
store's reason. FreeCoreData's stores evaluate it. Compared as they are (`Products/aggregate(UnitPrice with
sum) gt 40`, or with another aggregate), they are evaluated in every
store.
