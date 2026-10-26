# Permissions on objects

Scopes (`readScopes` and the rest, [server-design.md](server-design.md))
say what a caller may do anywhere in a set: "may update Locations". Many
applications need more than that: "Ben may ship stock from the Garage
warehouse", "Dee manages Anna's catalog". Here a permission is held *on an
object*, and it reaches what lies under that object: a warehouse's
locations and moves, a catalog's warehouses and items.

## Nothing original

ODataKit takes the model and its notation from Google's **Zanzibar**:

- Ruoming Pang et al., "Zanzibar: Google's Consistent, Global Authorization
  System", USENIX ATC 2019.
- Its open implementations, chiefly **OpenFGA**, whose notation the
  annotations below use, and SpiceDB.

The `where` term is borrowed from **SAP CAP**'s `@restrict … where`.

What ODataKit adds is only the mapping onto Core Data and OData:
- tuples are rows of the application's model, so ODataSync syncs them;
- a check runs in the write check pass;
- the answer to "which objects" is a fetch predicate.

If something here differs from Zanzibar without a reason given below, that
is a mistake.

| Zanzibar / OpenFGA | ODataKit |
|---|---|
| object type | an entity |
| relation tuple `object#relation@user` | a row of an entity annotated `OData.tuple.*` |
| relation definition, `define keeper: [user] or manager` | an entity's `OData.relation.keeper` = `[user] or manager` |
| direct relationship `[user]` | the tuples that name the object and the relation |
| computed userset `manager` | another relation of the same object |
| tuple to userset `keeper from warehouse` | the same, through the entity's own to-one `warehouse` |
| permissions are relations | the service checks the relations `read`, `insert`, `update`, `delete` and `call.<Operation>` |
| Check | the relation, evaluated on the row |
| ListObjects | the relation, as a fetch predicate |
| conditions | `where <predicate>`, from SAP CAP's `@restrict` |

## The annotations

All of these are `userInfo` keys on the model's entities.

**Relation tuples** are the rows of an entity that says so:

| Key | Value |
|---|---|
| `OData.tuple.object` | its to-one to the object (it needs an inverse) |
| `OData.tuple.relation` | the attribute that names the relation, e.g. `role` |
| `OData.tuple.relationName` | instead of `OData.tuple.relation`: the one relation every row is |
| `OData.tuple.user` | the key path to the user (or group) it is for, e.g. `user.email` |

**Relations** are defined on the object's entity, under
`OData.relation.<name>`, as one or more terms joined by `or`:

| Term | Holds when |
|---|---|
| `[user]` | a tuple names this object, this relation and the caller |
| `manager` | the caller holds `manager` on this object |
| `keeper from warehouse` | the caller holds `keeper` on the object the to-one `warehouse` reaches |
| `where owner.email IN $user` | the predicate holds on the row; `$user` is the caller's identities |

A sub-entity uses its super-entity's definitions, unless it defines its
own. Relations can only be added this way, never taken away: there is no
`but not` and no deny.

**Who the caller is** (their identities, the tuple's user and `$user`): the
principal's subject, its `email` and `preferred_username` claims, and each
name in its `groups` claim. A tuple for a group therefore grants to
everyone in the group.

## An example: Logbook's stock

```
Catalog          owner   = where owner.email IN $user
                 manager = owner
                 keeper  = manager
                 read    = keeper

Warehouse        owner   = owner from catalog
                 manager = [user] or owner
                 keeper  = [user] or manager
                 read    = keeper
                 update  = manager
                 insert  = owner from catalog
                 delete  = owner

WarehouseStaff   OData.tuple.object = warehouse
                 OData.tuple.relation = role        ("manager", "keeper")
                 OData.tuple.user = user.email

Location         read   = read from warehouse
                 insert = manager from warehouse
                 update = manager from warehouse
                 delete = manager from warehouse
```

What this gives:
- Anna owns the catalog, so she owns every warehouse in it, and so can do
  anything to their locations.
- A `WarehouseStaff` row (Garage, `keeper`, Ben) lets Ben see the Garage
  and its locations, but not change them.
- A row (Garage, `manager`, Dee) lets Dee change, add and remove the
  Garage's locations too, and only the Garage's.

## What is checked, and where

- **Reads:** for an entity that defines `read`, the default
  `-predicateForVisibleObjectsInRequest:` is "the rows on which the caller
  holds `read`". That predicate is applied everywhere a row is reached:
  path, by key, `$expand`, `$count`, binds and `$ref`, delta entries. A
  handler that adds its own predicate ANDs it with `super`'s. Rows the
  caller cannot see are not there: `404`.
- **Inserts:** checked in the write check pass, before anything is written.
  The caller must hold `insert` on the row as its values make it, e.g.
  `manager from warehouse` through the warehouse it is bound to. A row
  that reaches its object through another row made in the same request
  (a deep insert) leaves the decision to that row's own `insert`.
- **Updates:** the caller must hold `update` on the row as it is, *and* as
  it will be. Moving a location to another warehouse needs `update` there
  too.
- **Deletes:** `delete` on the row. A `$ref` (link or unlink) needs
  `update` on the row whose navigation property it is.
- **Operations:** an operation bound to a row needs `call.<Name>` on it
  (its unqualified name, e.g. `call.Ship`).
- **ODataSync's `MergeAttributes`:** a merge is an update, and is allowed
  as one is: the set allows updates, the caller has its `updateScopes`, and
  holds `update` on the row.
- **Refusals:** a write the caller may not make is answered `403`, naming
  the relation. A row they cannot see is `404`, so a refusal never reveals
  that a hidden row exists. A `PATCH` to a hidden row's key is an upsert,
  which `insert` decides.
- **Unannotated entities:** an entity with no relation for a verb is not
  limited by relations for it. Scopes, `allowsInsert` and the rest apply as
  before, and both must pass.
- **Mistakes in the annotations** are listed in `metadataProblems`. A
  relation that cannot be read holds for no one.

## How it relates to scopes

Scopes stay as they are, and are checked first, from the plan, before
anything is read. A scope is a permission held on the whole service, and
that is what the identity provider issues.

Relations are decided per row, in the check pass, once the rows are read.
`$explain` prints the scopes a request needs; relations depend on the rows,
so it cannot print them.

## Delta links

- **Scope version:** for an entity that defines `read`, the default
  `-scopeVersionForRequest:` is a digest of the caller's tuples. A tuple
  given or taken changes it, and a delta link from before is answered
  `410`, so the client reads the set again.
- **Ownership changes are not covered:** a change that only affects a
  `where` condition, such as an owner changing, does not change the
  version.
- **Deletions:** tombstones keep no relationships, so a deletion is told to
  every caller following a delta link of the set
  ([server-design.md](server-design.md), `predicateForVisibleObjectsInRequest:`).

## Limits

- **Through to-ones only:** a `from` term walks a to-one relationship.
  "Keeper of the catalog if keeper of any of its warehouses" would need a
  to-many there, which is not supported.
- **Bounded depth:** a chain of `from` terms deeper than eight is no grant.
  Zanzibar bounds its rewrites as well.
- **Not advertised:** `$metadata` says nothing about relations, because the
  Capabilities vocabulary has no term for permissions held on objects.
- **No richer errors on the client:** a refusal is a plain `403` with a
  message. There is no `ODataErrorScopesKey` for relations.
- **Visibility is the root's:** `read` for visibility is read from the set's
  root entity (a sub-entity's own `read` does not narrow the set).

## In code

`ODataService` answers the two questions directly:

```objc
// Check: may the caller ship from this warehouse?
BOOL may = [service request:request holds:@"call.Ship" onObject:warehouse];

// ListObjects, as a predicate: the warehouses the caller keeps.
NSPredicate *kept = [service predicateForObjectsOfEntity:warehouseEntity
                                          onWhichRequest:request
                                                   holds:@"keeper"];
```
