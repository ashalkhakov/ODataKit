# Moving an application onto relations

This guide is for an application whose server writes its own permission
checks in entity set handlers: visibility predicates, and "why not"
refusals in insert, update and delete. Since ODataKit #62 (the release
after 0.3.16), those can be stated as relations, Zanzibar's model; see
[permissions.md](permissions.md). The service then applies them
everywhere: reads, lookups, deep writes, `$ref`, batches, bound operations
and ODataSync's `MergeAttributes`.

Permissions are a file of their own, beside the Core Data model, which
the service is given (`ODataService.permissions`, or `ois-serve`'s
`Permissions` setting). The model does not change.

The guide has a general part, then one section per application:
SimpleNotes, Logbook (maintenance), Logbook (stock).

**Shorthand.** The tables below write relations in OpenFGA's notation,
which is shorter to read. In the file, each term is a dictionary, and a
relation is the list of its terms:

| Shorthand | In the file |
|---|---|
| `[user]` | `{ direct = YES; }` |
| `Owner` | `{ relation = Owner; }` |
| `Owner from vehicle` | `{ relation = Owner; from = vehicle; }` |
| `admin on service` | `{ relation = admin; on = service; }` |
| `where owner.email IN $user` | `{ where = "owner.email IN $user"; }` |
| `claim roles = admin` | `{ claim = roles; value = admin; }` |
| `a or b` | `( a, b )` |
| `a and b` | `{ all = ( a, b ); }` |

So `Driver = [user] or Owner` on Vehicle is, under `Entities`:

```
Vehicle = {
  Driver = ( { direct = YES; }, { relation = Owner; } );
};
```

## 1. The steps

1. **List what each handler decides,** per set:
   - who sees which rows (`predicateForVisibleObjectsInRequest:`, or your
     own `visibleTo:`);
   - who may add a row, and with which values;
   - who may change or remove one;
   - who may call each bound action.
2. **Start the file** (say `Permissions.plist`, next to the model):
   ```
   {
     Version = 1;
     Identities = ( sub, email, preferred_username, groups );
     Tuples = { };
     Entities = { };
   }
   ```
   `Identities` lists the claims the caller is known by; keep only the ones
   your rows hold (Logbook: `email`; SimpleNotes: `sub`).
3. **Find the tuples.** These are rows that give a person a role over an
   object, such as `WarehouseStaff` (warehouse, role, user) or
   `VehicleDriver` (vehicle, user). List each such entity under `Tuples`:
   ```
   Tuples = {
     WarehouseStaff = { object = warehouse; relation = staffRole; user = "user.email"; };
     VehicleDriver  = { object = vehicle; relationName = Driver; user = "user.email"; };
   };
   ```
   `object` is its to-one to the object (it needs an inverse); `relation`
   the attribute naming the role, or `relationName` the one role every
   row is; `user` the key path to what the caller is known by, one of their
   `Identities`.
4. **Find what holds by the row's own values,** usually an owner. Write it
   as a `where` term: `Owner = ( { where = "owner.email IN $user"; } )`.
5. **Write the relations** on each entity, under `Entities`:
   - **Roles first.** For example `manager = [user] or owner`. A role named
     by tuples must have the same name as the tuples' relation values:
     `Manager` if `staffRole` holds `"Manager"`.
   - **Then what the service checks:** `read`, `insert`, `update`,
     `delete` and `call.<Action>`.
   - **Reach other objects with `from`:** `read = read from vehicle` through
     a to-one, `keeper from warehouses` through a to-many ("any of them").
   - **Roles held without rows** (an administrator, a support desk) are
     claims the identity provider issues: define them under `Service`
     (`admin = ( { claim = roles; value = admin; } )`) and add
     `{ relation = admin; on = service; }` where they apply.
6. **Check it in the build:** `odatakit-permissions check Model.momd
   Permissions.plist` exits 1 and lists what does not fit. Run it in CI
   (or a test calling `-problemsWithModel:`).
7. **Load it in the server:**
   ```objc
   ODataPermissions *permissions = [ODataPermissions permissionsWithContentsOfURL:url error:&error];
   NSArray *problems = [permissions problemsWithModel:model];
   if (!permissions || problems.count) { /* log, and do not serve */ }
   service.permissions = permissions;
   ```
   With `ois-serve`, set `Permissions` to the file; it will not start on
   problems. Leave `permissions` nil where the server runs open (see the
   pitfalls).
8. **Delete the code the relations replace:** `visibleTo:`, the
   `whyNotAdd:`/`whyNotChange:` refusals, and helper predicates. Keep what
   is not a permission (section 3).
9. **Test it as each kind of user:** who sees, adds, changes, moves and
   deletes what; `404` for a row the caller cannot see, `403` for one they
   see but may not change; and a delta link answered `410` after a grant
   changes. ODataKit's `testGrantsOnObjects` is a template.

## 2. Pitfalls

- **Anonymous callers hold nothing.** With no principal, a caller holds no
  relation, not even a `claim`: they see no row of an entity that defines
  `read`, and may not write where a relation is defined. A handler cannot
  let them through, because the write check runs in the service.
  - If your server also runs open (a household server, a self-test with no
    sign-in), give it no permissions file in that mode.
  - Or make the open mode sign in as someone, and give that someone an
    `admin` claim that `Service` grants everything through.
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
- **No `%` outside quotes in `where` text.** There are no format
  arguments (`$user` is the caller), so the check reports one. Inside
  quotes, `%` is plain text. Quote a `where` in the file (`where = "…";`): OpenStep text needs
  quotes around anything but letters, digits and `_.$`.
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
- **A rule the relations cannot state:** there is no deny and no `but
  not`.
- **Sets with no writes at all:** `allowsInsert`, `allowsUpdate` and
  `allowsDelete` stay the plainest way, and `$metadata` says so.

---

## 4. SimpleNotes (TopoText)

Today `SNNotebookHandler` limits every set with an `owner` attribute to
`owner == subject` when the server is per user (`perUser`), and stamps
`owner` on insert.

**Permissions.** A file listing each root entity with `owner` (here
`Notebook`; repeat for the others), loaded in `SNServeNotebooks` when
`perUser` is on:

```
{
  Version = 1;
  Identities = ( sub );
  Entities = {
    Notebook = {
      read   = ( { where = "owner IN $user"; } );
      update = ( { relation = read; } );
      delete = ( { relation = read; } );
      insert = ( { where = "$user.@count > 0"; } );
    };
  };
}
```

`owner` holds the subject (`sub`).

**Notes**
- **`insert` doesn't name `owner`,** since it's stamped after the check.
  Anyone signed in may add a row, and the handler makes it theirs.
- **Keep** `refusesWrites:` (note versions are the server's), version
  keeping, and the `owner` stamping.
- **Remove** the `perUser` predicate in `predicateForVisibleObjectsInRequest:`.
- **When `perUser` is off** (one household), give the service no
  permissions, and nothing changes.
- **ODataSync:** `MergeAttributes` (merged note text) now checks the
  relation `update`, so a user can no longer merge into another's note even
  if they know its key.

## 5. Logbook: maintenance

Today `LBVehicleHandler`, `LBRecordHandler`, `LBOfVehicleHandler`,
`LBOfRecordHandler`, `LBReschedulingHandler`, `LBUserHandler`,
`LBChecklistHandler`, `LBReferenceHandler` and `LBAddOnlyHandler`
(`Server/LBPermissions.m`) do this by hand. The caller is known by email
(`LBEmailOf`), and `email` is among their identities.

**Identities.** `( email )`.

**Tuples.** `VehicleDriver = { object = vehicle; relationName = Driver;
user = "user.email"; };`

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
  desktop self-test's server-side store has no sign-in, so give it the
  permissions file only when the server requires sign-in, or have the
  self-test sign in.

## 6. Logbook: stock

Today `LBStockHandler`, configured per set in `LBServeStock` with a
catalog path, warehouse paths and a writer (Owner, Manager or Keeper), does
this by hand.

**Identities.** `( email )`.

**Tuples.** `WarehouseStaff = { object = warehouse; relation = staffRole;
user = "user.email"; };` (its `staffRole` values are `Manager` and
`Keeper`).

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

**Moves** need a keeper at both their source and their destination, an
`and`: `insert = Keeper from source and Keeper from destination`, and the
same with `Manager` for `update` and `delete`. A move with a missing end
fails a `from` through it; allow that with another term if it may happen
([permissions.md](permissions.md), `all`). The same goes for a parts sale
a keeper writes where it ships from (`and where serviceAsPartsSale !=
nil`) and a contact a warehouse's staff make for a user. Write these with
`and`, not as a `where` that spells keeper and manager out as key paths:
that repeats the relations and drifts from them.

**Stays in handlers**
- **Consistency:** "that warehouse is of another catalog" stays.
- **Stamping:** the catalog's owner, SKUs, and the running numbers of
  orders and counts.

**Notes**
- **Upserts:** define `insert` on every set that defines `read` (section
  2), so an upsert can't duplicate a hidden key.
- **Anonymous requests:** as for maintenance, give the service the
  permissions file only when sign-in is required, or have the self-test
  sign in.
- **One file or two:** maintenance and stock can share one file if they
  share one service; otherwise each has its own.
