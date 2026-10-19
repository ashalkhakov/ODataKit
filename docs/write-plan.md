# A plan for the service's writes

Reads are planned ([query-plan.md](query-plan.md)); writes are too, as
databases plan DML. An INSERT, UPDATE or DELETE is a tree whose leaves
read (the rows to change, the rows referred to), whose top modifies, and
whose `RETURNING` is a read over what was modified. The plan is `OISPlan`
with its `write` set (`OISPlan.h`), made and run by
`OISServiceCall+Write.m`.

## What databases do

- **PostgreSQL**: one `ModifyTable` node (Insert, Update, Delete or Merge)
  over a subplan that yields the rows to change: a scan with the `WHERE`
  for UPDATE and DELETE, `VALUES` or a query for INSERT. Defaults and
  `nextval()` are expressions of that subplan. Foreign keys are checked by
  lookups (`SELECT 1 FROM pk WHERE key = $1`); `RETURNING` is evaluated
  over the modified rows. A writable CTE (`WITH p AS (INSERT … RETURNING
  id) INSERT INTO child …`) is a deep insert: the parent's returned key
  feeds the child's insert. `MERGE` matches source rows to targets, then
  updates the matched and inserts the rest.
- **SQL Server**: the modify operator (`Clustered Index Insert/Update/
  Delete`) with `Assert` operators before it for constraints, so a row
  that breaks one fails the statement before anything is written.
- **All of them**: a transaction is statements, each planned on its own;
  `EXPLAIN` of DML shows the plan without running it.

## Why

Each write path used to work its own way. `@odata.bind`, `$ref` targets,
a deep update's nested entities and the slices of a temporal action were
read from the context, not through the handler. New keys were the
largest plus one, read from the context for every insert. The checks
(If-Match, the key unchanged, `Core.Immutable`, what the set allows) were
spread through the paths, and some ran after a handler had been asked to
write: a deep insert whose second product bound to no supplier failed
after the first was inserted. The context's rollback undid that, but a
handler whose rows live elsewhere had written it. A temporal action
wrote as it worked its changes out, so a handler that answered later
could not take part (`501`).

## The operators

Along with the read operators (Objects, Store scan…):

| Operator | OData | Database |
|---|---|---|
| **Lookup**(set, key or id) | `@odata.bind`, a `$ref`'s `@odata.id` or `$id`, a nested `@id` or key, an operation's entity parameter | an FK check or a key lookup: a fetch of one row through the set's handler, with what the caller may see. One that must find a row and finds none is `400` |
| **Sequence**(entity.key) | an integer key the body leaves out | `nextval()`: the row with the largest key read once through the handler (of all rows, not only the visible ones), then counted on for every new row of the write, from above any key the request gives. Strings and UUIDs are made up |
| **Insert**(entity; values) | POST, a deep insert's nested entity | `ModifyTable Insert` |
| **Update**(target; values) | PATCH, PUT (**Replace**), a property, a stream, `$each` | `ModifyTable Update`, over the target's rows |
| **Delete**(target) | DELETE, `@removed` deleted, `$each`, PUT of a collection (but the rows it names) | `ModifyTable Delete` |
| **Link / Unlink**(holder, relationship, member) | `$ref`; a new row through a navigation property with no inverse | an FK update, or a join table's insert or delete |
| **Merge**(match; matched, otherwise) | a deep update's nested entity, `Nav@delta`, a delta payload, PUT of a collection | `MERGE`: the Update when the Lookup finds the row, else the Insert |
| **Temporal**(action, deltas) over a Store scan | `Temporal.Update`, `Upsert`, `Delete` | `MERGE` with a computed source: the changes to the slices, as inserts, updates and deletes |
| **Call**(operation) | an action or function, after the Lookups of its entity parameters | a stored procedure: the operation's own code |
| **Commit** | the save: an open type's dynamic properties, each set's handed to its handler at once (`-writeDynamicProperties:ofObjects:request:reply:`), `Validation.MultipleOf` and `Constraint`, then the service's `willSave` (an application's rules over several objects), then the context's save (in a change set, the change set's) | the statement's end |
| **Returning** | the response's entities, and their `$expand` | `RETURNING`: the read plan over what was written (`planOfObjects:`) |

A value of an Insert or Update is a constant, a node (a Lookup's row,
what a nested Insert or Merge wrote), or members (`OISPlanMembers`): a
to-many relationship's rows (from the row's own, for a bind in an update
or a delta, or none), with nodes' rows added and others' taken away.

A deep insert is a writable CTE: nested Inserts are the values of the
Insert whose relationship they fill. For

```
POST Categories
{"CategoryName": "Tea", "Products": [{"ProductName": "Sencha", "Suppliers@odata.bind": ["Suppliers(1)"]}]}
```

`physical` is:

```
Returning
  Nest Products
  Objects (what Insert Category wrote)
Commit
  Insert Category set name
    id :=
      Sequence Category.id from Store scan Category sort id desc top 1
    products := these
      Insert Product set name
        id :=
          Sequence Product.id from Store scan Product sort id desc top 1
        suppliers := these
          Lookup Suppliers(1)
```

A Merge plans both branches: one that cannot be planned (a nested entity
the set does not allow to be inserted, say) fails the write only if it
is the one taken.

## Running it

The executor is the read plan's: each answer is kept, by node, and a
handler that answers later starts the evaluation again from the top,
where nothing already answered is asked again. For writes, that keeps
them from being made twice.

The plan runs in phases, as a statement with Asserts does:

1. **Read**: every Lookup, Sequence and Store scan, through the handlers.
   A Merge reads its Lookup first, then only the branch it takes.
2. **Check**: If-Match (a stream's against its media ETag), a nested
   entity's `@odata.etag` and `@odata.type`, the key and what is
   immutable unchanged, what the set allows; a `$ref`'s member of the
   relationship's type (and, taken away, in it). PUT's defaults and the
   version are worked out here, and the new keys given out. A failure is
   answered before any handler is asked to write.
3. **Write**: the modifications, the ones a write depends on first
   (nested Inserts and Merges before the row they are values of, the
   deletes a delta asks for before the update it is part of). A handler
   whose answer fails the write rolls the context back.
4. **Commit**, then **Returning**.

An Update whose values come to nothing (a nested entity only named, to
be linked) asks no handler.

**The temporal action** reads the slices the caller may see, then
`OISTimeline` works out the changes over records of them
(`OISSliceRecord`: its values now, and what changes), writing nothing:
a slice made and then taken away again by a later delta is not written
at all, and one changed by several deltas is updated once, its version
moving on once. The writes are then the handler's inserts, updates and
deletes, one by one, each of which may answer later.

## Collections

4.01's writes to a collection (Part 1 sections 11.4.12-14):

- **`PATCH` of a collection**, with a delta payload: each entity a Merge,
  each `@removed` one a Lookup, deleted (from an entity set, or for the
  reason `deleted`) or, from a navigation property's collection,
  unlinked. Not after a cast or a `$filter(…)` segment (`400`).
- **`PUT` of a collection**: each entity a Merge, and a Delete over a
  Store scan of the collection, but of the rows the body names.
- **`PATCH …/$each`**: an Update over a Store scan of the collection, with
  its casts and `$filter(…)` segments, each row updated with the body.
  Nested entities in the body are not taken (`501`): bind them.
- **`DELETE …/$each`**: a Delete over the same.

`$metadata` says so: each set's `UpdateRestrictions` and
`DeleteRestrictions` have `FilterSegmentSupported` and
`TypecastSegmentSupported` (and `DeltaUpdateSupported`), which is how the
client knows to send `NSBatchUpdateRequest` and `NSBatchDeleteRequest` as
`$each`. A removed entry carries its key (and `@odata.type`, for a
derived type) in 4.01, so the client knows which object it was.

All or nothing (`continue-on-error` is not taken). With
`return=representation`, a collection is answered with its rows as they
are now (`$each`'s PATCH, PUT), or a delta payload of the changes in the
order the request gave them (PATCH of a collection, `$each`'s DELETE);
otherwise `204`. `$filter(…)` path segments are taken by reads too
(`Products/$filter(UnitPrice gt 20)/$count`).

## Explain

`POST`, `PATCH`, `PUT` and `DELETE` on `<root>/$explain/<resource path>`,
with the body, answer the plan without running it (`EXPLAIN`, not
`EXPLAIN ANALYZE`): Lookups and Sequences appear as the nodes they are,
not as what they would find, and a Merge with both its branches. The
permissions the plan needs follow it (`Permission to insert into
Products: Products.Add`): what each write node writes, and what the
answer's expansions read. A Merge's branch and a temporal action's slices
are checked in the check pass, once known, before anything is written.
`logsPlans` logs a write's plan as it does a read's.

## Batches

As in databases: each request of a change set is planned and run on its
own, within the change set's context, which is its transaction; its
Commit validates, and the change set's save is the save. A `$1` in a later
request's URL or bind is the path of what the earlier one created, which
the later one's Lookup reads.
