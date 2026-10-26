# Moving an application onto relations

This guide is for an application whose server writes its own permission
checks in entity set handlers: visibility predicates, and "why not"
refusals in insert, update and delete. Since ODataKit #62 (the release
after 0.3.16), those can be stated as relations, Zanzibar's model; see
[permissions.md](permissions.md). The service then applies them
everywhere: reads, lookups, deep writes, `$ref`, batches, bound operations
and ODataSync's `MergeAttributes`.

The guide has a general part, then one section per application:
SimpleNotes, Logbook (maintenance), Logbook (stock).

## 1. The steps

1. **List what each handler decides,** per set:
   - who sees which rows (`predicateForVisibleObjectsInRequest:`, or your
     own `visibleTo:`);
   - who may add a row, and with which values;
   - who may change or remove one;
   - who may call each bound action.
2. **Find the tuples.** These are rows that give a person a role over an
   object, such as `WarehouseStaff` (warehouse, role, user) or
   `VehicleDriver` (vehicle, user). Annotate each such entity:
   ```
   OData.tuple.object   = warehouse      // its to-one to the object (needs an inverse)
   OData.tuple.relation = staffRole      // the attribute naming the role…
   OData.tuple.relationName = driver     // …or the one role every row is
   OData.tuple.user     = user.email     // what the caller is known by
   ```
   The `user` key path must give something in the caller's identities:
   their subject, their `email` or `preferred_username` claim, or one of
   their `groups`.
3. **Find what holds by the row's own values,** usually an owner. Write it
   as a `where` term: `owner = where owner.email IN $user`.
4. **Write the relations** on each entity, under `OData.relation.<name>`:
   - **Roles first.** For example `manager = [user] or owner`. A role named
     by tuples must have the same name as the tuples' relation values:
     `Manager` if `staffRole` holds `"Manager"`.
   - **Then what the service checks:** `read`, `insert`, `update`,
     `delete` and `call.<Action>`.
   - **Reach other objects with `from`:** `read = read from vehicle` through
     a to-one, `keeper from warehouses` through a to-many ("any of them").
5. **Put the annotations in the model** (the model editor's User Info), or
   in code on the server's editable model (`ODataSyncModelAtURL`) before the
   coordinator is made, if they depend on configuration (see the pitfalls).
6. **Refuse to start on problems.** Log `service.metadataProblems` at
   start, and fail if it lists any relation problem, since a relation that
   cannot be read holds for no one.
7. **Delete the code the relations replace:** `visibleTo:`, the
   `whyNotAdd:`/`whyNotChange:` refusals, and helper predicates. Keep what
   is not a permission (section 3).
8. **Test it as each kind of user:** who sees, adds, changes, moves and
   deletes what; `404` for a row the caller cannot see, `403` for one they
   see but may not change; and a delta link answered `410` after a grant
   changes. ODataKit's `testGrantsOnObjects` is a template.

## 2. Pitfalls

- **Anonymous callers hold nothing.** With no principal, a caller holds no
  relation: they see no row of an entity that defines `read`, and may not
  write where a relation is defined. A handler cannot let them through,
  because the write check runs in the service.
  - If your server also runs open (a household server, a self-test with no
    sign-in), add the annotations in code only when sign-in is required.
  - Or make the open mode sign in as someone.
- **`insert` sees the row as the client sent it.** The check runs before
  your handler's insert, so it cannot depend on a value your handler stamps
  (`owner`, `enteredBy`, `madeBy`). For "anyone signed in", write
  `insert = where $user.@count > 0`.
- **Define `insert` wherever you define `read`.** A `PATCH` to a key the
  caller cannot see is an upsert. With no `insert` relation to refuse it,
  it makes a second row with the hidden row's key.
- **Visibility also limits lookups.** Binds (`@odata.bind`) and `$ref`
  targets must be visible to the caller. If a write must name rows the
  caller does not otherwise see (a user named by email, to share
  something with them), keep a handler override that returns `nil` for
  those writes instead of calling `super`.
- **An override that adds to visibility** must AND its predicate with
  `super`'s, which is now the relation `read`. Otherwise it drops the
  relations.
- **Updates are checked twice:** on the row as it is and as it will be.
  Moving a record to another vehicle needs `update` there as well. That
  replaces hand-written "moved: theirs to write there too" checks.
- **A row made in the same request** (a new record with its new answers)
  decides for the rows reached through it: their `insert` is not checked
  against it, and its own `insert` is.
- **Avoid `%` in `where` text.** Format specifiers are not supported
  there.
- **Delta links:**
  - A deletion is told to everyone who follows a delta link of the set.
  - The scope version follows the caller's tuples only: an ownership change
    in a `where` does not send clients to read again.

## 3. What stays in the handlers

Relations decide who may. Everything else stays where it is:
- **Stamping on insert:** an owner, `enteredBy`, `madeBy`, a running
  number, a SKU.
- **Values a client may not change** after the insert (your
  `changeable:`).
- **Consistency between rows** ("that warehouse is of another catalog").
- **A rule the relations cannot state yet:** there is no `and` and no
  deny. Logbook's moves are the one case below.
- **Sets with no writes at all:** `allowsInsert`, `allowsUpdate` and
  `allowsDelete` stay the plainest way, and `$metadata` says so.

---

## 4. SimpleNotes (TopoText)

Today `SNNotebookHandler` limits every set with an `owner` attribute to
`owner == subject` when the server is per user (`perUser`), and stamps
`owner` on insert.

**Relations.** For each root entity with `owner`, in code in
`SNServeNotebooks` when `perUser` is on:

```
OData.relation.read   = where owner IN $user
OData.relation.update = read
OData.relation.delete = read
OData.relation.insert = where $user.@count > 0
```

`owner` holds the subject, which is among the caller's identities.

**Notes**
- **`insert` doesn't name `owner`,** since it's stamped after the check.
  Anyone signed in may add a row, and the handler makes it theirs.
- **Keep** `refusesWrites:` (note versions are the server's), version
  keeping, and the `owner` stamping.
- **Remove** the `perUser` predicate in `predicateForVisibleObjectsInRequest:`.
- **When `perUser` is off** (one household), add no annotations, and
  nothing changes.
- **ODataSync:** `MergeAttributes` (merged note text) now checks the
  relation `update`, so a user can no longer merge into another's note even
  if they know its key.

## 5. Logbook: maintenance

Today `LBVehicleHandler`, `LBRecordHandler`, `LBOfVehicleHandler`,
`LBOfRecordHandler`, `LBReschedulingHandler`, `LBUserHandler`,
`LBChecklistHandler`, `LBReferenceHandler` and `LBAddOnlyHandler`
(`Server/LBPermissions.m`) do this by hand. The caller is known by email
(`LBEmailOf`), and `email` is among their identities.

**Tuples.** `VehicleDriver` is a tuple: `object = vehicle`,
`relationName = Driver`, `user = user.email`.

**Relations**

| Entity | Relations |
|---|---|
| Vehicle | `Owner = where owner.email IN $user` · `Driver = [user] or Owner` · `read = Driver` · `insert = where $user.@count > 0` · `update = Owner` · `delete = Owner` |
| Record (and its kinds) | `Owner = Owner from vehicle` · `Driver = Driver from vehicle` · `read = Driver` · `insert = Driver` · `update = Owner` · `delete = Owner` |
| VehicleDriver, VehicleWasValuedOnDateAtMoney | `read = Driver from vehicle` · `insert`, `update`, `delete = Owner from vehicle` |
| ServiceItem | `read = read from service` · `insert`, `update`, `delete = Owner from service` |
| Answer | the same, through `inspection` |
| Attachment | `read = read from record or read from stockItem` · `insert`, `update`, `delete = Owner from record or Owner from stockItem` (StockItem's `Owner`: section 6) |
| Rescheduling | `read = Driver from reminder` · `insert = Driver from reminder` · `update`, `delete = Owner from reminder` |
| Checklist | `Keeper = where user.email IN $user` · `read = Keeper or read from inspections` · `insert = where $user.@count > 0` · `update`, `delete = Keeper` |
| Question | `Keeper = Keeper from checklist` · `read = read from checklist` · `insert`, `update`, `delete = Keeper` |
| Option | the same, through `question` |
| User | `Self = where email IN $user` · `update = Self` (see the notes for `read`) |

**What this replaces**
- **Records:** "who drives a vehicle adds records to it; its owner changes
  them" is `insert = Driver`, `update = Owner`. Moving a record to another
  vehicle is checked there too.
- **Things of a record** (`LBOfRecordHandler`):
  - "added with a new record of one's own" holds because a row made in the
    same request decides: the new record's own `insert = Driver`;
  - otherwise it's the vehicle owner's.

**Notes**
- **Users:** keep `LBUserHandler`'s visibility override as it is. It
  returns `nil` for writes, so a vehicle can be shared with a user named by
  email before they sign in. Also keep its `whyNotAdd:` ("a user says only
  the email of another") and the `made:by:` email.
- **Stays in handlers:**
  - stamping: `owner` (vehicles), `enteredBy` (records), `madeBy`
    (reschedulings), a checklist's `user`;
  - `changeable:`, which drops `enteredBy` and `madeBy` from updates.
- **Units** (`LBReferenceHandler`): set `allowsInsert`, `allowsUpdate` and
  `allowsDelete` to NO.
- **Exchange rates and kinds of cost** (`LBAddOnlyHandler`): set
  `allowsUpdate` and `allowsDelete` to NO, and give them
  `insert = where $user.@count > 0`.
- **Anonymous requests** (section 2) are allowed everything today. The
  desktop self-test's server-side store has no sign-in, so add the
  annotations only when the server requires sign-in, or have the
  self-test sign in.

## 6. Logbook: stock

Today `LBStockHandler`, configured per set in `LBServeStock` with a
catalog path, warehouse paths and a writer (Owner, Manager or Keeper), does
this by hand.

**Tuples.** `WarehouseStaff` is a tuple: `object = warehouse`,
`relation = staffRole` (its values `Manager` and `Keeper`),
`user = user.email`.

**Relations: the catalog and its warehouses**

| Entity | Relations |
|---|---|
| Catalog | `Owner = where catalogOwner.email IN $user` · `Manager = Owner or Manager from warehouses` · `Keeper = Manager or Keeper from warehouses` · `read = Keeper` · `insert = where $user.@count > 0` · `update`, `delete = Owner` |
| Warehouse | `Owner = Owner from catalog` · `Manager = [user] or Owner` · `Keeper = [user] or Manager` · `read = read from catalog` · `insert`, `update`, `delete = Owner from catalog` |
| WarehouseStaff | `read = read from warehouse` · `insert`, `update`, `delete = Owner from warehouse` |

This replaces `LBSeesCatalog`, `LBManagesIn`, `LBManages` and `LBKeeps`:
- staff of any of a catalog's warehouses see the catalog;
- a manager of any of them manages at catalog level.

**Relations: everything else, by writer**

Each set below reaches its catalog through a path. Give each entity along
the path `read = read from <next>`, and the writer's relation from the
next entity along it.

| Writer | Sets (path) | Relations |
|---|---|---|
| Owner | StockItem, Category, Contact, Customer, Supplier, ItemAttribute (`catalog`); Address (`contact`); ItemAttributeValue, SupplierItem, ItemCode (`stockItem`); KitLine (`kit`) | `read = read from <path>` · `insert`, `update`, `delete = Owner from <path>`, so each entity along the path needs an `Owner = Owner from <next>` |
| Manager, by catalog | SaleOrder, PurchaseOrder (`catalog`); SaleLine (`saleOrder`), PurchaseLine (`purchaseOrder`) | `read = read from <path>` · `insert`, `update`, `delete = Manager from <path>` |
| Manager, by warehouse | Location, ReorderRule (`warehouse`) | `read = read from warehouse` · `insert`, `update`, `delete = Manager from warehouse` |
| Keeper, by warehouse | Holding (`location`), Shipment (`shippedFrom`), Receipt (`receivedAt`), Assembly (`assembledAt`), StockCount (`warehouse`) | `read`: through its order, item or warehouse, as today's catalog path goes · `insert = Keeper from <warehouse path>` · `update`, `delete = Manager from <warehouse path>`, since a keeper's row is a manager's to change |

A location's `Keeper` and `Manager` are its warehouse's
(`Keeper = Keeper from warehouse`, and the same for `Manager`), so
`Keeper from shippedFrom` works through a location.

**Stays in handlers**
- **Moves** need a keeper at both their source and their destination.
  Relations have no `and` yet, so keep that check in the handler. Give
  `Move` the relations for its source (`insert = Keeper from source`,
  `update`, `delete = Manager from source`), and let the handler check the
  destination.
- **Consistency:** "that warehouse is of another catalog" stays.
- **Stamping:** the catalog's owner, SKUs, and the running numbers of
  orders and counts.

**Notes**
- **Upserts:** define `insert` on every set that defines `read` (section
  2), so an upsert can't duplicate a hidden key.
- **Anonymous requests:** as for maintenance, add the annotations only when
  sign-in is required, or have the self-test sign in.
