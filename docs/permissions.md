# Permissions on objects

Scopes (`readScopes` and the rest, [server-design.md](server-design.md))
say what a caller may do anywhere in a set: "may update Locations". Many
applications need more than that: "Ben may ship stock from the Garage
warehouse", "Dee manages Anna's catalog". Here a permission is held *on an
object*, and it reaches what lies under that object: a warehouse's
locations and moves, a catalog's warehouses and items.

Moving an existing server's hand-written checks onto relations is covered
in [permissions-migration.md](permissions-migration.md), which also has
SimpleNotes' and Logbook's mappings.

## Nothing original

ODataKit takes the model and its notation from Google's **Zanzibar**:

- Ruoming Pang et al., "Zanzibar: Google's Consistent, Global Authorization
  System", USENIX ATC 2019.
- Its open implementations, chiefly **OpenFGA**, whose terms the
  permissions file below uses, and SpiceDB.

The `where` term is borrowed from **SAP CAP**'s `@restrict … where`, and
the `claim` term from CAP's roles (`@requires`), which the identity provider
issues.

What ODataKit adds is only the mapping onto Core Data and OData:
- tuples are rows of the application's model, so ODataSync syncs them;
- a check runs in the write check pass;
- the answer to "which objects" is a fetch predicate.

If something here differs from Zanzibar without a reason given below, that
is a mistake.

| Zanzibar / OpenFGA | ODataKit |
|---|---|
| authorization model | a permissions file, beside the Core Data model |
| object type | an entity (`Entities`) |
| relation tuple `object#relation@user` | a row of an entity listed in `Tuples` |
| relation definition, `define keeper: [user] or manager` | `keeper = ( { direct = YES; }, { relation = manager; } );` |
| direct relationship `[user]` | the tuples that name the object and the relation |
| computed userset `manager` | another relation of the same object |
| tuple to userset `keeper from warehouse` | the same, through the entity's own relationship `warehouse`; through a to-many, any of its members |
| permissions are relations | the service checks the relations `read`, `insert`, `update`, `delete` and `call.<Operation>` |
| Check | the relation, evaluated on the row |
| ListObjects | the relation, as a fetch predicate |
| intersection, `define writer: keeper from source and keeper from destination` | `{ all = ( …, … ); }` |
| conditions | `where`, from SAP CAP's `@restrict` |

## The permissions file

Permissions live in a property list of their own, not in the model: a
model is often shared, generated, or edited in Xcode's model editor, which
is a poor place to write rules. The service is given the file:

```objc
NSError *error = nil;
ODataPermissions *permissions = [ODataPermissions permissionsWithContentsOfURL:url error:&error];
NSArray *problems = [permissions problemsWithModel:model];   // empty: it fits
service.permissions = permissions;
```

`ois-serve` takes it as the `Permissions` setting, and does not start when
it does not fit the model. Without a file (`permissions` nil, the default)
nothing is limited by relations, only by scopes and handlers.

```
{
  Version = 1;
  Identities = ( sub, email, preferred_username, groups );
  Service = {
    admin = ( { claim = roles; value = admin; } );
  };
  Tuples = {
    WarehouseStaff = { object = warehouse; relation = role; user = "user.email"; };
  };
  Entities = {
    Warehouse = {
      manager = ( { direct = YES; }, { relation = owner; } );
      read    = ( { relation = manager; }, { relation = admin; on = service; } );
    };
  };
}
```

XML and binary property lists work as well; OpenStep's text, above, is the
easiest to write by hand and allows `//` comments.

**`Version`**: `1`. Required.

**`Identities`**: who the caller is, as a tuple's user and `$user` name
them: the claims, in order, whose values are the caller's identities. `sub`
is the principal's subject; a claim whose value is a list (`groups`)
gives each of its names. The default is `( sub, email, preferred_username,
groups )`. A tuple for a group therefore grants to everyone in it.

**`Tuples`**: the entities whose rows are relation tuples, each with:

| Key | Value |
|---|---|
| `object` | its to-one to the object (it needs an inverse) |
| `relation` | the attribute that names the relation, e.g. `role` |
| `relationName` | instead of `relation`: the one relation every row is |
| `user` | the key path to the user (or group) it is for, e.g. `user.email` |

**`Entities`**: relations defined on each entity, each a list of terms,
any of which grants it (they are joined by *or*):

| Term | Holds when |
|---|---|
| `{ direct = YES; }` | a tuple names this object, this relation and the caller |
| `{ relation = manager; }` | the caller holds `manager` on this object |
| `{ relation = keeper; from = warehouse; }` | the caller holds `keeper` on the object the to-one `warehouse` reaches |
| `{ relation = keeper; from = warehouses; }` | the caller holds `keeper` on any of the objects the to-many `warehouses` reaches |
| `{ relation = admin; on = service; }` | the caller holds `admin` on the service (`Service`) |
| `{ where = "owner.email IN $user"; }` | the predicate holds on the row; `$user` is the caller's identities |
| `{ claim = roles; value = admin; }` | the caller's claim is the value, or (a list) has it; a boolean or number claim matches `true`/`YES`, `false`/`NO` or its digits |
| `{ all = ( { relation = keeper; from = source; }, { relation = keeper; from = destination; } ); }` | every one of its terms holds (two or more, of any kind, `all` too): Zanzibar's intersection |

**`all`** is how a rule says *and*: "a keeper at both ends of a move", "a
keeper where it ships from, if it is a parts sale" (`{ where =
"serviceAsPartsSale != nil"; }` as the second term). A `from` through a
relationship that is nil holds nothing, so a move with no source fails
`keeper from source`. Where a missing end is allowed, say so as another
term: `( { all = ( …source…, …destination… ); }, { all = ( { where =
"source == nil"; }, …destination… ); } )`.

**`Service`**: relations held on the service as a whole, made of `claim`
terms, other service relations and `all` of them. They are Zanzibar's relations on a
single object of type service, and what an identity provider can say
without knowing the rows: an administrator, a support role.

A sub-entity uses its super-entity's definitions, unless it defines its
own. A grant can only be narrowed by `all`, never taken away by another:
there is no `but not` (Zanzibar's exclusion) and no deny.

## Checking a file

The file is checked against the model before it is served, and the same
check runs when the service is given it:

```
odatakit-permissions check Model.momd Permissions.plist
```

It prints what does not fit, one line each, and exits 1 if anything does
(0 when it all fits, 2 when it cannot read a file). It finds:

- an entity, relationship or attribute the model does not have (in
  `Entities`, `Tuples`, `from`, a `where`'s key paths);
- a `from` through something that is not a relationship;
- a relation named but not defined (on the entity, on what `from`
  reaches, in `Service`, or a tuple's `relationName`);
- an `all` of fewer than two terms;
- a `where` that does not parse, or has a `%` outside quotes (there are
  no format arguments; `$user` is the caller). Inside quotes a `%` is
  only text: `name == 'C%'`;
- computed relations in a cycle (`a = b`, `b = a`). A `from` that comes
  back to the same entity, such as a folder's viewers from its parent's,
  is a tree and is allowed; it is followed to a depth of eight;
- a key it does not know, anywhere in the file;
- a `direct` term on an entity that no `Tuples` entry points at.

It cannot check a tuple's `relation` attribute's values: they are data.

The tool is built with the server tools (`make -C Server`, or
`make -f Makefile.apple` there); `make check` runs it on an example
(`Server/Examples/Catalog.permissions.plist`).

## An example: Logbook's stock

```
{
  Version = 1;
  Tuples = {
    WarehouseStaff = { object = warehouse; relation = role; user = "user.email"; };   // role: manager, keeper
  };
  Entities = {
    Catalog = {
      owner   = ( { where = "owner.email IN $user"; } );
      manager = ( { relation = owner; }, { relation = manager; from = warehouses; } );
      keeper  = ( { relation = manager; }, { relation = keeper; from = warehouses; } );
      read    = ( { relation = keeper; } );
    };
    Warehouse = {
      owner   = ( { relation = owner; from = catalog; } );
      manager = ( { direct = YES; }, { relation = owner; } );
      keeper  = ( { direct = YES; }, { relation = manager; } );
      read    = ( { relation = keeper; } );
      update  = ( { relation = manager; } );
      insert  = ( { relation = owner; from = catalog; } );
      delete  = ( { relation = owner; } );
    };
    Location = {
      read   = ( { relation = read; from = warehouse; } );
      insert = ( { relation = manager; from = warehouse; } );
      update = ( { relation = manager; from = warehouse; } );
      delete = ( { relation = manager; from = warehouse; } );
    };
    StockItem = {
      read   = ( { relation = read; from = catalog; } );
      insert = ( { relation = manager; from = catalog; } );
      update = ( { relation = manager; from = catalog; } );
    };
  };
}
```

What this gives:
- Anna owns the catalog, so she owns every warehouse in it, and so can do
  anything to their locations.
- A `WarehouseStaff` row (Garage, `keeper`, Ben) lets Ben see the Garage
  and its locations, but not change them.
- A row (Garage, `manager`, Dee) lets Dee change, add and remove the
  Garage's locations too, and only the Garage's.
- Through `warehouses`, a to-many: the Garage's staff see its catalog and
  the catalog's stock items. Dee, as a manager of one of the catalog's
  warehouses, manages them too.

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
- **Entities the file leaves out:** an entity with no relation for a verb
  is not limited by relations for it. Scopes, `allowsInsert` and the rest apply as
  before, and both must pass.
- **Define `insert` wherever you define `read`.** A `PATCH` to a key the
  caller cannot see is an upsert. With no `insert` relation to refuse it,
  that upsert succeeds and makes a second row with the hidden row's key.
- **Mistakes in the file** are listed in `metadataProblems` (and by
  `odatakit-permissions`). A term that cannot be read holds for no one.

## How it relates to scopes

Scopes stay as they are, and are checked first, from the plan, before
anything is read. A scope is a permission held on the whole service, and
that is what the identity provider issues.

Relations are decided per row, in the check pass, once the rows are read.
`$explain` prints the scopes a request needs; relations depend on the rows,
so it cannot print them.

## Delta links

- **Scope version:** for an entity that defines `read`, the default
  `-scopeVersionForRequest:` is a digest of the caller's tuples and the
  service relations they hold. A tuple given or taken, or a claim, changes
  it, and a delta link from before is answered
  `410`, so the client reads the set again.
- **Ownership changes are not covered:** a change that only affects a
  `where` condition, such as an owner changing, or an entity-level `claim`
  term, does not change the version.
- **Deletions:** tombstones keep no relationships, so a deletion is told to
  every caller following a delta link of the set
  ([server-design.md](server-design.md), `predicateForVisibleObjectsInRequest:`).

## Limits

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
