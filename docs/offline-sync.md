# Offline sync: design

**Status: the service's part (section 9) and the library's phases 1–5
(section 10) exist**: `Source/ODataSync` (`ODataSyncEngine`,
`ODataSyncPeerServer`), with down, up and both entities, the outbox and
set-aside changes, key reconciliation, conflicts (shadows with values,
RemoteWins, LocalWins, LastWriterWins on a hybrid logical clock,
MergeFields, custom resolvers), and peers (a peer server, relaying); and
the Workbench's Sync window (an offline device beside its built-in
service).

An app that works offline keeps its data in a Core Data store on the device
and syncs it with an OData service when it can: entities the service owns
come down, entities the app collects go up, and entities both edit are
reconciled by rules the app can choose. Devices can also sync with each
other, so that one that reaches the service carries the others' work.

ODataSync is a library for that, on top of what ODataKit already is: the
OData client (`ODataClient`, the property mapper, the value coder), the
service (`ODataService`) and its delta links, and Core Data's persistent
history (Apple's, and FreeCoreData's). An app that serves its data with
ODataService gets the server half by configuration; the client half is
the library.

## 1. Goals

- The app works against **one local store** (SQLite, persistent history),
  online or not. The UI never waits for the network and never sees an
  `ODataIncrementalStore`.
- **Down**: entities the service owns (assets, price lists, users) are
  copied to the device and kept current by delta links. The app reads
  them; it does not edit them.
- **Up**: entities the app owns (inspections, readings, photos' records)
  are created on the device with UUID keys and sent to the service by
  upsert, so sending one twice is harmless.
- **Both**: entities either side may change are reconciled by a conflict
  rule: the service wins, the device wins, last writer wins, a merge by
  field, or the app's own.
- **Peers**: devices sync with each other the same way, so changes travel
  device to device and on to the service.
- **Crash-safe**: whatever is interrupted is done again, never twice in
  effect: what was applied and how far it got are saved together.
- **Little to integrate**: annotate the model, add the library's
  bookkeeping entities, start the engine.

Not goals, at first: syncing schema changes (both ends share a model
version), partial replication by arbitrary query per user beyond what the
service's row scoping gives, and real-time push (the engine pulls).

## 2. The shape

```
 the app's contexts
        │
 ┌──────▼────────────────────────────┐
 │  local store (SQLite, history)    │◄────── ODataSyncEngine
 │  app entities + ODataSync's own   │          │  remotes:
 └───────────────────────────────────┘          ├─ the service (ODataClient)
                                                └─ peers (the same, over the LAN)
```

- **ODataSyncEngine** owns the sync: one per local store, with one or more
  **remotes**. A remote is a service root URL with its credentials; a
  peer is a remote too.
- Per remote, a **downloader** (section 4) and an **uploader** (section 5)
  run in a context of their own on the local coordinator, so the app's
  contexts merge their saves as any other.
- The library adds a few **bookkeeping entities** of its own to the app's
  model (section 3.3), in the same store, so its state is saved in the
  same transactions as the data it describes.

ODataSync links ODataKit and ODataIncrementalStore (for `ODataClient`,
`ODataConfiguration` and credentials) and OTelKit (each sync a trace); it
does not use `ODataIncrementalStore` as a store.

## 3. The model

### 3.1 Directions

Each synced entity says which way it goes, in its `userInfo`:

| `ODataSync.direction` | Owner | The device | Sent as |
|---|---|---|---|
| `down` | the service | reads | nothing: never sent |
| `up` | the device | creates, edits, deletes | upsert (PATCH to its key), DELETE |
| `both` | either | edits | upsert with If-Match, DELETE with If-Match |
| (none) | the device | anything | nothing: local only |

A `down` entity changed locally is an error the engine reports (and, in
debug builds, a save that changes one fails); an `up` entity changed at
the service is overwritten by the device's next upsert unless it is
`both`.

The entity set and keys are the service's, as the mapper reads them
(`OData.entitySet`, `OData.key`): an entity syncs with the set its
`userInfo` names.

### 3.2 Keys

- `up` and `both` entities have a **UUID key**, made on the device when the
  object is inserted (the library offers `-[NSManagedObject
  ods_assignKey]`, or a default value in the model). Its identity is the
  same everywhere, so no key is ever mapped back, and a record relayed by
  a peer is the same record.
- `down` entities have the **service's keys**, whatever they are.
- Relationships are ordinary, across directions: an inspection (`up`)
  points to its asset (`down`). On the wire, a to-one is `@odata.bind` to
  the related entity's key.

### 3.3 The library's entities

Added to the app's model by `+[ODataSyncEngine addBookkeepingToModel:]`
(before the coordinator is made), all in the same store:

- **ODSRemoteState**: per remote, its delta links (one per entity set),
  the history token the uploader has read up to, and for peers the peer
  vector (section 7).
- **ODSOutboxEntry**: one per object with changes not yet accepted by a
  remote: entity, key, what changed (insert, the changed property names,
  delete), the base ETag it was edited from, attempts, the last error,
  and `quarantined` when a remote refused it for good (section 5.4).
- **ODSShadow**: per `both` object, the last version a remote confirmed:
  its ETag, and its values (for a three-way merge, section 6). Only for
  `both` entities, and only their synced properties.

#### Indexes: ODataSync's part, and the app's

A sync looks rows up one at a time, one or more per object it moves.
Unindexed, each lookup reads a whole table, and a sync takes the square
of the objects it moves. So every lookup ODataSync makes has a fetch
index, made by `+addBookkeepingToModel:`:

| Entity | Index | Looked up by it |
|---|---|---|
| ODSShadow | `byObject`: remote, entity, key | each object downloaded or sent |
| ODSOutboxEntry | `byObject`: remote, entity, key | each local change; a remote's pending changes |
| ODSOutboxEntry | `bySequence`: sequence | each local change (the next entry's number) |
| ODSTombstone | `byObject`: entity, key; `byDeleted`: deleted | each deletion told, a key reused; pruning |
| each synced entity (its root) | `ODataSyncKey`: its key attributes, in order | each object downloaded, sent, resolved as a to-one, or in conflict |

The last is the app's own entities': ODataSync looks them up by key and
nothing else. An index of the app's own that begins with the key's
attributes takes its place (none is added then). A service's model gets
the same from `+[ODataSyncService addBookkeepingToModel:]`, for its sets
that keep version vectors, and the tombstones'.

What ODataSync cannot know is the app's: whatever its own queries filter
or sort by. A server that scopes each request by an attribute (an owner,
a tenant) should index it, as should one whose devices sync with filters
(`Region eq 'North'`: `region`), and so should the app for its own
fetches and lists. A key's uniqueness is the app's too: a uniqueness
constraint, where its store has them.

**A store made before the indexes does not get them.** An index does not
change an entity's version hash, so Core Data sees no change to migrate:
Apple's SQLite store opens an older store as it is, with or without the
migration options, and so do FreeCoreData's stores. Such a store works,
but unindexed; to have the indexes, delete it and let the device sync
again (a service's store, made again from its data). The same goes for
an index an app adds to its own entities.

## 4. Down

Per remote, per `down` and `both` entity set:

1. **First time**: GET the set with `Prefer: odata.track-changes` (and
   `$filter` when the app gives one: a set's rows for this user, by the
   service's row scoping or an explicit filter), following next links.
   Each row is applied by key; the final page's `@odata.deltaLink` is kept.
2. **After**: GET the delta link. Each entry is applied by key; `@removed`
   entries delete the local object; the new delta link is kept.
3. **410 Gone** (the service no longer has the history from there): read
   the set again as in 1, and delete the local objects of the set it did
   not return (mark and sweep).
4. **Applying**: in the downloader's context, with transaction author
   `ODataSync.down.<remote>`: update or insert by key (a key index makes
   this a lookup); to-one navigation values (`@odata.bind`-shaped
   references, or the foreign key properties the model maps) resolve to
   local objects by key, inserting a fault-like placeholder when the
   related row has not come yet (filled when it does).
5. **Saving**: the changes and the new delta link (in ODSRemoteState)
   in one save. A crash before it loses nothing: the old link is read
   again.

A removed `down` row that local `up` records still point to: the
relationship's delete rule decides (Nullify keeps the records; Deny makes
the downloader keep the row and report it). A `both` object with an
outbox entry is not overwritten: the incoming version is a conflict
(section 6).

### 4.1 When what a user may see changes

A set's rows are often scoped to the user (the handler's
`predicateForVisibleObjectsInRequest:`: their region, their team, rows
assigned to them). A delta link reports what changed among the rows, by
persistent history; what a user may see can change otherwise:

| # | What happened | What the user's delta says today | Right? |
|---|---|---|---|
| A | a visible row edited, still in scope and filter | the row | yes |
| B | a visible row edited out of the request's `$filter` | removed | yes |
| C | a row edited out of the user's scope (reassigned) | nothing | no: the device keeps it |
| D | a row deleted | removed, to every user | yes for those who had it; it tells the others the key of a row they never saw |
| E | a row the user never sees edited | nothing | yes |
| F | the user's own scope changed (role, region, team), no row did | nothing | no: rows left out stay, rows let in never come |
| G | a row let in by a change elsewhere (joining a team) | nothing | no: missing rows |

The service cannot tell C from E: whether the row was in this user's
scope when the link was made needs its values then, and history keeps
which properties changed, not what they were. Reporting every changed
row the user cannot see would send everyone the keys of everyone else's
changes. F and G leave nothing in history at all.

So:

1. **Key reconciliation** (the library; covers C, F, G). Now and then the
   downloader reads only the keys of a scoped set, with the app's filter
   (`GET Set?$select=<key>&$filter=...`, paged), deletes the local rows
   the service did not name, and reads the ones it lacks by key. When: on
   sign-in or a change of user, after a 410, when the service says the
   scope changed (2), and on a schedule the app sets (daily, say). It
   costs one read of keys per scoped set: for ten thousand rows, a few
   hundred kilobytes before gzip.
2. **A scope version in delta links** (the service; F and G at the next
   sync). The handler may say what version of the caller's scope a
   request has (`-scopeVersionForRequest:`: one made of the principal's
   claims that decide it, or a counter the application moves when a
   membership changes). Delta links carry it, and one followed with
   another answers 410: the client reconciles (1). Nothing changes for a
   handler that says none.
3. **Deletions checked against what they kept** (the service; D's leak).
   The attributes the visibility predicate reads are kept in history on
   deletion (`preservesValueInHistoryOnDeletion`, as the key must be
   already), and a deletion is reported only to a caller the predicate,
   evaluated on those values, lets see it. A predicate that reads
   anything not kept (a relationship, a property not preserved) reports
   it to every caller, as now.
4. **Reassignments** (the service, if ever: C at the next sync rather than
   the next reconciliation). A handler names the attributes that decide
   scope; a changed row whose history shows one of them changed, and that
   the caller cannot see now, is reported removed to the caller. It still
   tells every caller the key of a reassigned row (fewer than every
   change, but some), so it would be a handler's choice. Not planned
   until an app needs reassignments faster than reconciliation gives them.

## 5. Up

### 5.1 From history to the outbox

The uploader reads the local store's persistent history after the token
in ODSRemoteState, skipping transactions by any `ODataSync.down.*` author
(what came down is not sent back) and changes to entities that are not
`up` or `both`. Each change becomes or updates the object's
ODSOutboxEntry: an insert followed by updates stays an insert, changed
property names accumulate, a delete after an insert removes the entry
(never sent), a delete otherwise replaces it. The entries and the new
token are saved together. The outbox is the queue; history is how it is
filled, so the uploader never needs to read history twice.

With several remotes, each has its own token, and an entry records which
remotes still need it.

### 5.2 Sending

Entries go in dependency order (an object before those whose to-ones point
to it), as one `$batch` with `Prefer: odata.continue-on-error`, at most a
configured number per batch:

| Entry | `up` | `both` |
|---|---|---|
| insert | PATCH `Set(key)`: all synced properties, to-ones as `@odata.bind` | the same, with `If-None-Match: *` |
| update | PATCH `Set(key)`: the changed properties | the same, with `If-Match: <base ETag>` |
| delete | DELETE `Set(key)` | DELETE with `If-Match` |

PATCH to a key is an **upsert** (section 9.1): it creates the entity if
there is none, and otherwise updates it. An `up` insert and an `up` update
are the same request with more or fewer properties, so a repeat, after a
crash or by a peer that relayed it, ends as the first did.

### 5.3 Answers

| Answer | What the uploader does |
|---|---|
| 2xx | the entry is done (removed, or this remote crossed off); a `both` object's shadow takes the new ETag and values |
| DELETE 404 | done: it is already gone |
| 412 (`both`) | a conflict (section 6) |
| 400, 403, 409, 422 | refused: the entry is quarantined with the error, the app told; the rest go on |
| 401 | credentials (the remote's credential provider), then again |
| 5xx, no answer | left as it is, sent again later (backoff) |

### 5.4 Quarantine

A refused entry stays in the outbox, marked, with the service's error (an
OData error, its target and details): the app shows it, and the user
fixes the record (the next change clears the mark and it is sent again)
or discards it (`-[ODataSyncEngine discardIssue:]`, which also reverts
the local object to its shadow, or deletes it when it never reached the
service).

## 6. Conflicts

A conflict is a `both` object changed on the device (an outbox entry) and
at the remote (an ETag other than the base) since the version both last
agreed on (the shadow). It is found in two places: on upload (412 to an
If-Match), and on download (an incoming version of an object with an
outbox entry).

The engine then has three versions: **base** (the shadow), **local** (the
object now), **remote** (the remote's now: the incoming entry, or a GET
after the 412), and the properties each side changed since the base. A
**resolver** decides:

```objc
@protocol ODataSyncResolving <NSObject>
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict;
@end
```

`ODataSyncConflict` has the entity, key, the three versions as property
dictionaries, the changed names on each side, and for deletes which side
deleted. `ODataSyncResolution` is one of: **take remote** (the local
object becomes the remote version; the entry is dropped), **keep local**
(the entry is sent again with If-Match of the remote's ETag), **merged**
(these values: applied locally, and sent with If-Match of the remote's
ETag), or **defer** (quarantined for the user).

Rules that come with the library, per entity (`ODataSync.conflicts` in
`userInfo`, or set in code), or one for all:

- **RemoteWins** (default): the service's version stands. Safe, and what a
  `down` entity does anyway.
- **LocalWins**: the device's edit is sent again over the remote's.
- **LastWriterWins**: by a timestamp property the model names
  (`ODataSync.modified`), which both sides set on every change; ties go to
  the remote. Across devices a wall clock is not enough: the library sets
  the property to a hybrid logical clock (section 7), which orders
  changes causally and stays near real time.
- **MergeFields**: three-way by property: what only one side changed is
  taken from it; a property both changed falls back to another rule
  (RemoteWins unless given).
- **Custom**: any object conforming to `ODataSyncResolving`, per entity or
  for all; given the three versions, it can do anything, including defer.

Deletes: an edit against a delete goes by the rule's notion of winner
(RemoteWins: deleted; LocalWins: re-created by the upsert); MergeFields
hands a delete to its fallback; LastWriterWins lets the edit stand (a
delete carries no stamp of its own). That is with the service; between
peers a deletion is remembered and wins (section 7).

As built:

- `userInfo` names a rule with `ODataSync.conflicts`: `remote`, `local`,
  `lastwriter` or `merge`. Which applies, most specific first: a resolver
  set in code for the entity (`-setResolver:forEntityName:`, looked up
  through superentities), the `userInfo` rule, `engine.resolver`, then
  `engine.conflictPolicy`.
- `ODataSync.modified` names a string attribute. Every save not made by
  the engine stamps it with the replica's hybrid logical clock,
  `<milliseconds, 16 digits>.<counter, 4 digits>.<replica, 8>`, so
  stamps compare as strings; the clock moves past every stamp the engine
  reads from a remote. The replica's identifier is kept in the store's
  metadata (`-replicaID`).
- The shadow keeps the agreed version's JSON, so base, local and remote
  are compared in the service's names and values, and the conflict's
  dictionaries carry the model's attribute names.
- Keep local and merged both agree on the remote's version first (its
  ETag in the shadow), then the entry sends only what still differs from
  it; nothing, when the two already match.
- Defer sets the entry aside as an issue with status 409. Retrying it
  sends the local version over the remote's; discarding it turns it into
  a refresh, which reads the remote's version into the object at the next
  sync.
- A conflict met on upload (412) is settled at once: a GET of the row, the
  resolver, and the changed entry sent again, up to three rounds a sync.

## 7. Peers

Devices sync with each other the same way they sync with the service: a
device that offers its data runs an **ODataSyncPeerServer** (an
ODataService over its store, on HTTPServerKit), on the local network;
another device adds it as a remote, `+[ODataSyncRemote
peerWithServiceRoot:]`. So a phone that spent the day in a basement hands
its inspections to one with a signal, which sends them on.

Between phones and tablets, over TLS with each device's certificate,
found by Bonjour, trusted by a token the service issues or by pairing:
[peer sync](peer-sync.md). On a network the app trusts, plain HTTP, the
app's own authenticator:

```objc
// The device that offers its store:
ODataSyncPeerServer *peers = [[ODataSyncPeerServer alloc] initWithEngine:sync host:@"192.168.1.20" port:8642];
peers.service.authenticator = ...;               // who may sync
[peers start:&error];                            // advertise peers.serviceRoot
// A device that syncs with it:
[sync addRemote:[ODataSyncRemote peerWithServiceRoot:advertisedURL]];
```

How it goes:

- **Who changed what**: each store has a replica ID (a UUID in its
  metadata). A peer server's root is `http://<host>:<port>/sync/<replica
  ID>/`, and a peer remote's identifier is that replica ID. What the
  engine downloads from a remote is written by author
  `ODataSync.down.<identifier>`; what a device sends to a peer server
  names its replica (`ODataSync-Replica` header) and is written there by
  author `ODataSync.down.<its replica>`. So every change in a store says
  where it came from, whichever way it travelled.
- **Relaying**: a change is never sent back to where it came from. It is
  passed on to the other remotes when the source or the destination is a
  peer (a peer's work to the service, the service's data to a peer);
  between two services nothing is passed on. Up entities are sent by
  upsert and have UUID keys, so the service gets each change once in
  effect, whoever brings it.
- **Nothing goes round**: an incoming row is applied only where it
  differs (an equal value is no change, so no history), and a change for
  a remote is dropped when it equals the version that remote last agreed
  to (its shadow). A change that went A → B → service → A stops at A.
- **A peer is no authority**: with a peer, up entities are treated as
  both (shadows, If-Match, conflicts and resolvers); from a peer come
  changes of up and both entities, and of down entities only what is
  missing here, or newer by the service's version counter (below). What a
  peer reads deletes nothing here (neither its removals nor the rows it
  lacks): a peer's set may be scoped or filtered differently, and no
  peer's view is complete. A peer that lacks an object this device sends
  gets it whole.
- **The service's version, through a peer**: a down entity with a version
  attribute (an integer that `OData.etag` names, which ODataService
  increments on each update it makes, and which the server app's own
  writes must increment too) has ordered ETags. Its copy from a peer
  replaces this device's when its version is higher: it is the service's,
  only newer. Without one, a peer only fills in what is missing (ETags of
  hashed values cannot be ordered). Peers cannot change it: down sets are
  read only on a peer server.
- **Which deletions travel**: a device's own deletion is sent to every
  remote, peers included. One that a peer sent here is passed on to the
  other remotes: an engine sends a peer only deletions made on its device
  (or passed on so), and a peer's reads delete nothing, so it is a real
  one. One that came down from a service is not passed on: it may be the
  service's scope, not the object's end (a device out of scope keeps no
  copy; each device learns that from the service).
- **Relayed changes are checked**: an up entity's change that came from
  elsewhere is sent to the service as a both entity's (If-Match of the
  version it agreed to, `*` when none; If-None-Match for a new one), not
  by a plain upsert. A stale copy, or an edit of what the service has
  since deleted, meets a 412 and goes to the resolver, instead of
  overwriting a newer version or making a deleted object again. A change
  made on this device is sent by upsert as before: its own work.
- **Ordering**: last writer wins compares the `ODataSync.modified`
  stamps of a hybrid logical clock. A peer server keeps the stamps it is
  sent (its writes are the engine's, not the app's, so they are not
  stamped again) and moves its own clock past them, like a download.
- **Peer vectors**: per peer, the delta links of its sets (in the remote's
  state, as for the service); a peer's ODataService makes them from its
  store's persistent history. A new peer reads everything once.
- **What a peer serves**: the synced entities only, not the engine's
  bookkeeping nor local-only entities: `+addBookkeepingToModel:` adds a
  model configuration listing them (`ODataSyncPeerConfiguration`, which no
  store need use), and the peer server serves that configuration. Down
  sets are read only.
- **Conflicts with a peer are settled the same way on both sides**: each
  peer asks in turn, so a rule must choose the same version whichever
  side asks, or the two swap for ever. The remote's or this side's are
  not such: with a peer, RemoteWins and LocalWins (and MergeFields falling
  back to either) become LastWriterWins, whose ties (or missing stamps) go
  to the version whose values sort last. `ODataSyncConflict.withPeer` tells
  a custom resolver, which must be as even-handed.
- **Never an older version over a newer one**: a peer's row older (by the
  stamps) than this side's copy is not applied; it is agreed on as the
  peer's, and this side's is sent to it (a peer a step behind would
  otherwise pass its old copy round again). A change older than the
  version a remote last agreed to is not sent; the remote's is taken. A
  change of a version never agreed on with that remote (an object that
  came from elsewhere) goes with an `If-Match` that matches nothing, so it
  meets the remote's version (412, the resolver) instead of overwriting it
  unseen; a deletion goes with `*`.
- **Deletions remembered**: each device keeps the keys of synced objects
  deleted in its store (`ODSTombstone`), whoever deleted them. A peer
  server refuses an insert of such a key (410 Gone), and the sender takes
  the deletion (its copy deleted, and that passed on); a download from a
  peer does not make such an object again. So between peers a deletion
  wins over a change made without knowing of it, as in Ensembles, and an
  insert and a deletion cannot chase each other round a ring of peers. An
  object made again here, or by a service, is not deleted any more.
  Tombstones are kept `tombstoneRetention` (30 days by default).
- **Remotes in turn**: a sync goes through the remotes in the order they
  were added. That decides how soon a change travels (a peer added before
  the service has its work passed on in the same sync), not what the
  stores end up with: the checks above catch a copy that comes late.
- **Compared with others**: Ensembles (Core Data sync over a shared
  file store, or Multipeer Connectivity) has every device publish only its
  own change logs, and every device read every other's; peers forward the
  raw log files, so no one re-authors another's change, and a deletion
  spreads with its author's log. Each event records the events its
  author had seen (a revision set, a vector clock), and a device applies
  an event only once it has all of those (`checkIntegrationPrerequisites`);
  new events are applied with every event concurrent with them, in order
  (a global count, then time), so arrival order does not matter. A delete
  beats a concurrent update; all devices are equal, with no read-only
  data.
  Couchbase Lite keeps "deleted" (a tombstone, replicated) apart from "no
  longer visible to you" (purged locally, never replicated), which is the
  distinction behind which deletions travel here; its server is the
  authority through access control, as the service is here.
- **Out of scope here**: discovery (Bonjour, Multipeer Connectivity, a QR
  code) and how peers trust each other (a token the service issued to
  each, checked by the peer server's authenticator); the engine takes a
  remote's URL and credentials, however found.

### 7.1 An insert passed on late makes a deleted object again (closed with version vectors)

A device makes an object and gives it to a peer; the service gets it
(from either), and later deletes it. If the peer passes the *insert* on
to the service only after that (it had not synced since), the insert goes
with `If-None-Match: *`, finds nothing, and the object is made again. An
update passed on late is caught (`If-Match` finds nothing: a 412, and the
resolver), but an insert cannot tell "deleted" from "never there".

Ensembles does not have this hole. The device that deleted the object
had seen its insert, so its delete event depends on the insert's, and no
device applies the delete without the insert before it: a late insert is
never news. Only a genuinely new object made with the same global ID
comes back. CouchDB and Couchbase Lite get the same from revision
histories: a late copy of an old revision is an ancestor of the
tombstone, and cannot win; only a concurrent edit (a branch of its own)
can, since a live leaf beats a deleted one. CloudKit, as far as is known
here, refuses an update of a deleted record but lets a new save of its ID
make it again: this hole. What closes it is knowing the history: that
the copy which comes is older than the deletion (section 12).

With version vectors and `ODataSyncService` on the service (section 12)
it is closed: the service keeps the deleted version's vector, and an
insert whose version the deletion had seen is refused (410); one made
without knowing of it is a conflict (409), settled by the device's rule.
Without them, between devices it is closed by the peer servers' tombstones
(a deletion wins), and at a service it stays. Closing it there
needs the service to remember deleted keys too: a set that keeps
its tombstones (persistent history already does, for delta links, as long
as history is retained) could answer an upsert of a deleted key with 409
or 410 instead of making it, and the engine would take that as the
object's end; section 12 says how a key's history decides which inserts
are late. Until then, an app that deletes at the service what devices
collected should expect the odd one back, and can delete it again.

### 7.2 How it is tested

Data that syncs must end the same everywhere, and stay so; peers make the
orders in which changes meet too many to think through. Besides tests of
each behaviour (Tests/ODataSyncTests.m), Tests/ODataSyncConvergenceTests.m
tests reconciliation as a whole:

- **Every conflict under every rule**: a both object agreed on, then each
  side's change (none, an edit, an edit of another property, a delete)
  against each of the other's, under RemoteWins, LocalWins,
  LastWriterWins (either side later) and MergeFields, met on download and
  on upload (412). Each case checks what both sides end with against the
  rule, that nothing is left to send, and that another sync changes
  nothing.
- **Convergence**: four devices (two reach the service, the others reach
  them as peers, and some offer themselves back), and the service, making
  changes at random (tasks, inspections, assets; made, edited, deleted)
  and syncing in random orders, whole or half. Then every device reaches
  the service and syncs until nothing changes. It checks that this ends
  (within eight rounds), that every device has what the service has,
  that nothing is left to send and no change set aside, that every
  inspection no one deleted reached the service as last written, and
  (under last writer wins) that each task left has its last version.
  Odd seeds settle by last writer wins, even ones by the default. Eight
  seeds by default; `ODATASYNC_SEEDS=1000` for a long run (about ten
  minutes), `ODATASYNC_SEED=n` for one (stamps follow the wall clock, so a
  seed replays the same steps, not always the same timing).

What it found, and what changed for it: a delta that did not tell of an
object made and deleted since its link (section 9, 5); a change of a
version never agreed on overwriting a newer one (`If-Match: *`); peers
swapping versions for ever under a one-sided rule; a peer a step behind
passing its old copy round; and an insert and a deletion chasing each
other round three peers (tombstones).

## 8. Integrating

On the device:

```objc
NSManagedObjectModel *model = ...;                 // annotated: ODataSync.direction, keys
[ODataSyncEngine addBookkeepingToModel:model configuration:nil];
// the store: SQLite, with NSPersistentHistoryTrackingKey
ODataSyncEngine *sync = [[ODataSyncEngine alloc] initWithCoordinator:coordinator];
ODataSyncRemote *service = [ODataSyncRemote remoteWithServiceRoot:url];
service.configuration.credentialProvider = auth;   // ODataCredentialProviding
service.filters = @{ @"Asset": @"Region eq 'North'" };
[sync addRemote:service];
sync.resolver = [[ODataSyncMergeFields alloc] init];   // or per entity: -setResolver:forEntityName:, userInfo ODataSync.conflicts
sync.delegate = self;                              // changes set aside, local edits of down entities, progress
[sync syncWithTarget:self action:@selector(syncDidFinish:error:)];   // or -syncWithError: off the main thread
```

What exists, and how it goes (`ODataSyncEngine.h`):

- A sync, per remote: the store's history after the remote's token
  folded into the outbox (so what the device has not sent is known), then
  each down and both set read (whole the first time, by its delta link
  after, whole again after a 410 or a change of filter, with what the
  remote no longer has swept), then the outbox sent.
- The outbox goes as JSON `$batch` requests that stand or fall alone
  (`odata.continue-on-error`), one at a time where a service takes no
  JSON batch; upserts parents first, deletions children first.
- What waits to be sent: `-pendingChanges` (each an `ODataSyncChange`:
  its entity, key, operation, properties, attempts; an `ODataSyncIssue`
  when set aside), for a "3 changes to send".
- How far a sync is: the delegate's `-syncEngine:didProgress:`, with an
  `ODataSyncProgress` (the remote; the phase, receiving, sending or
  merging; how many done, of how many). Told as each phase with a remote
  begins (sending and merging only when something waits), then a few
  times a second at most, as soon as all of a phase's total is done, and
  as each phase ends, with what it came to, on the engine's thread. So the
  last a phase is told is true: all done, or as far as it got (a remote
  gone down midway). Sending counts the rows' changes that no longer
  wait, however each was settled (taken, refused, in conflict, gone at
  the remote), of those that waited; merging, the objects whose merged
  attributes were exchanged or tried (one that failed is tried again at
  the next sync), of those that waited; receiving, the rows that came
  down and the objects that went, of a total not known (0). For a
  "Sending 3,000 of 25,000 changes" while a large import goes up.
- Refused changes are set aside (`-issues`, the delegate), sent again
  when the object changes or the app retries them, or discarded.
- `-reconcileWithRemote:error:` reads each set's keys again (4.1).
- Each sync is a trace (OTelKit): `sync`, `download <Entity>`, `upload batch`.
- A both entity keeps, per object, the version both last agreed on
  (`ODSShadow`: its ETag, for If-Match, and its values, for merges);
  conflicts go to the resolver (section 6).
- Peers (section 7): `ODataSyncPeerServer.h` serves the store;
  `+[ODataSyncRemote peerWithServiceRoot:]` syncs with one. Remotes sync
  in the order they were added, so a device that adds its peers before the
  service passes their work on in the same sync.

On the service (ODataKit's server): the store keeps persistent history
(delta links), and the entity sets the devices write allow upsert
(section 9.1). With version vectors (section 12), the server's model has
`ODataSync.versions` on the synced entities too, and the server app
installs `ODataSyncService` on its ODataService
(`+addBookkeepingToModel:configuration:` first, for its tombstones). `ois-serve` does it by settings; an `ODataServerApplication`
the same.

## 9. The service's part

What ODataService needs, and what it has:

1. **Upsert** (OData 4.01 Part 1, 11.4.4): a PATCH or PUT to an entity's
   key where there is none creates it, through the set handler's insert
   (with the key from the URL, which the body need not repeat, and must
   not contradict), and answers 201 (or 204 with `Prefer:
   return=minimal`); where there is one, it updates it as now.
   `If-None-Match: *` makes it create only (412 when the entity exists);
   `If-Match` makes it update only (412 when it does not). On by default
   for a set whose handler allows insert, off by a handler property
   (`allowsUpsert`), and said in `$metadata` (Capabilities.UpdateRestrictions,
   `Upsertable`). *Exists*, for entity sets' keys (not through a navigation
   property).
2. **Binds in an upsert's body**: `@odata.bind` on to-ones (and to-many,
   4.01) as in an insert. *Exists*: the create path is the insert's.
3. **Continue-on-error in $batch**: *exists* (`Prefer:
   odata.continue-on-error`).
4. **ETags and If-Match** on update and delete: *exist*, with 412.
5. **Delta links** from persistent history, with `$filter`: *exist*;
   `Capabilities.ChangeTracking` in `$metadata`: *exists*. Scope changes:
   section 4.1; the service's part is the scope version (4.1, 2) and
   deletions checked against what they kept (4.1, 3). An object made and
   deleted since the link is told as deleted all the same: the client may
   have it (one that made it after reading the link, as an offline device
   does by its upload); one that never had it finds nothing to remove.
6. **History retention**: how long the store keeps history before delta
   links answer 410: `historyRetention` (`HistoryRetention` for
   `ois-serve`), pruned by date in the background as requests come, and
   410 for links from before it. *Exists*; the client side handles 410
   already. A delta token says when it was given, and the store's metadata
   how far history was pruned: a token given before that is 410 on any
   store (FreeCoreData's history does not report an expired token, as
   Apple's does). A device offline longer than that reads its sets again.
7. **Key uniqueness**: an upsert must find the one entity a key names; the
   store's key attribute is indexed and unique. *Indexed by
   `+[ODataSyncService addBookkeepingToModel:]` for the synced sets (3.3);
   uniqueness is the model's to declare (a uniqueness constraint), and is
   not checked.*

## 10. Order of work

1. The service: upsert (9.1, 9.2), its `$metadata`, tests (*done*); the
   scope version and deletions checked against what they kept (4.1);
   history retention (9.6). *Done.*
2. ODataSync: model annotations, bookkeeping entities, the downloader
   (with key reconciliation, 4.1), the uploader with the outbox and quarantine, RemoteWins and LocalWins;
   tracing (each sync a trace: a span per remote, per set, per batch).
   *Done* (Tests/ODataSyncTests.m against an ODataService in the process;
   Server/Tests/ois-serve-check.m over HTTP, on both platforms).
3. Conflicts: shadows, MergeFields, LastWriterWins with hybrid logical
   clocks, custom resolvers. *Done* (Tests/ODataSyncTests.m).
4. Peers: the peer server, relaying, peer vectors; discovery and trust left
   to the app. *Done* (Tests/ODataSyncTests.m in the process;
   Server/Tests/ois-serve-check.m over HTTP, on both platforms).
5. The Workbench: a sync pane (an offline store over the built-in service,
   the outbox, conflicts), as the self-test's ground. *Done*
   (`Examples/Workbench/WBSync.m`, Sync > Show Device; `checkSync` in its
   self-test).

## 11. Open questions

- Large binaries (photos): out of scope for now. Streams have their own
  upload (`ODataStreamTransfer`); the outbox could carry a stream entry
  after its record, retried the same way.
- Per-user subsets beyond row scoping: an app-given `$filter` per set is
  enough for most; a set whose filter changes (a user moves region) needs
  a re-read, which the engine can do when the filter differs from the one
  the delta link was made with.
- Changes that must arrive together: order is kept (history's order,
  parents first), but not all-or-nothing. A batch goes on after an error,
  so a refused order header leaves its lines taken; a download saves set
  by set, so a peer can hold an order's lines before its header changes;
  relayed changes are folded by object. A history transaction sent as one
  change set (all or nothing), by the app's choice, would make a group
  arrive whole, at the price of one refusal holding all of it.
- Schema versions: see section 13.

## 12. Causal history: what each version has seen

Ensembles and the CouchDB family know, for each change, what it came
after: Ensembles by the events each event's author had seen (a revision
set), CouchDB by each document's revision tree. So a copy that comes late
is known for an ancestor of what is there, and cannot win; only changes
made without knowing of each other are a conflict. ODataSync knows less:
a remote's version agreed on (the shadow), and the `ODataSync.modified`
stamps, which order changes but cannot tell "older" from "made without
knowing". The rules of section 7 (never an older version over a newer one,
deletions remembered) stand in for that, with stamps; the insert hole at
the service (7.1) is what they cannot close.

Why not Ensembles' way, events shipped and replayed in causal order: it
suits peers that are equal, hold everything, and all write through it.
Here the service is an authority that refuses changes and whose own app
writes rows; other clients (a web app, an integration) write rows and
make no events; a user sees a subset (scoping, filters), which a shared
log would leak or break; delta links and upserts are standard OData,
which a log protocol would not be; and a log grows, and needs baselines
and rebasing to stay small. So rows travel, and each row carries what
replay would have known: what its version has seen.

The plan: each synced object carries its history, not as a tree of
versions (a git DAG) but its summary, a **version vector**: for each
replica that changed it, the number of that replica's latest change it
includes. Each replica numbers its own changes 1, 2, 3... across all
objects (a save is a change, as an Ensembles event is), so `Kq3x9Zp1.4f,
svc.2a` is a version that includes replica `Kq3x9Zp1`'s changes up to its
151st and the service's up to its 82nd. Two
versions compare as git commits do: one includes the other (an ancestor,
a descendant), they are the same, or neither includes the other (made
without knowing of each other: a conflict). The tree itself is not
needed, since conflicts are settled when they meet and no branch is
kept.

- **Where**: a String attribute the model names (`ODataSync.versions` in
  the entity's userInfo), stored and served like any other property, so
  the service and the peers keep it too, and it travels with every row
  and every upload. An object without one has the empty vector, and the
  stamps' rules apply as now.
- **Encoding**: a replica is 8 characters (48 random bits, base64url, from
  its replica ID; the service is `svc`), a count is base 36, entries are
  sorted: about 10 to 12 bytes an entry, and most objects are changed by
  one or two replicas. Text, not binary, so that logs and the Workbench
  show it.
- **A change** (an app's save, or the service app's own): the object's
  entry for the replica becomes the replica's new count (kept in the
  store's metadata, saved with the save). Settling a conflict makes a
  version that includes both (each count the larger); with values new to
  both sides (merged), a change of this replica too. Two versions with
  the same values agree on the larger counts, conflict or not.
- **Meeting a version** (a download, a peer's row, a peer's push, a 412):
  the incoming version included in this one is old news, not applied,
  and this one is sent back where it is newer; one that includes this one
  is applied, conflict or not (it saw this side's change); neither is a
  conflict, for the resolver. Equal versions are agreed on. This replaces
  the stamp rules of section 7 with exact ones; last writer wins stays,
  as a rule for real conflicts.
- **Deletions**: a tombstone keeps the deleted version's vector, raised
  for the deletion. An insert or update of a deleted key whose version
  the tombstone includes is late (refused: 410); one that includes the
  tombstone's knew of the deletion and made the object again (taken);
  neither is a conflict, delete against change, for the resolver. So
  between peers a deletion no longer simply wins.
- **The service**: an `ODataSyncService` the server app installs on its
  ODataService does the same for the synced sets: compares the vector a
  write carries with the stored one (410 for late, 412 for a conflict),
  keeps tombstones of its own (an entity added to the server's model, as
  `+addBookkeepingToModel:` does the device's), and raises the service's
  count for changes the server app makes itself. That closes the insert
  hole (7.1). A service that is not ODataKit's still stores the vector as
  a property: devices compare as above, and the hole stays at it.
- **Size**: a vector has an entry per replica that ever changed that
  object, usually a few. The service, which sees everything, can drop the
  entries older than tombstones are kept (every device has those).
  Interval tree clocks would need no replica IDs at all, and suit devices
  that come and go, but a new device has to split an identity off one
  that exists: kept in reserve.
- **The stamp stays**: the vector says whether two versions conflict;
  `ODataSync.modified` says, for last writer wins, which one wins.
- **Built**: `ODSVersions.m` (the vectors), the engine (counting on save,
  tombstones with the deleted version, a DELETE's `ODataSync-Versions`
  header), meeting versions in downloads, uploads, 412s and conflicts
  (`ODSDownloader.m`, `ODSUploader.m`, `ODSConflicts.m`), and the
  service's part: `ODataSyncService.h` (`ODataSyncSetHandler`, which the
  peer server's handler is too; a 409's error details carry a deletion's
  vector, code `ODataSync.deleted`). An explicit stamp a save sets stands
  (a server app's, an import's). The conflict matrix and the convergence
  test run with vectors too (Tests/ODataSyncConvergenceTests.m, 300
  seeds), and the insert hole is a test that passes, and fails without
  the service's part. The Workbench's Products keep one.

## 13. Model versions

Devices update when their users let them, so a service is often on a
newer model than some of its devices, which go on sending what they
changed. Ensembles keeps each event's model (its entities' hashes) and
merges events of every version the app's model holds; an event of a newer
one waits until the app is updated. ODataSync works by property names:

- **Down**: a device ignores properties it does not know, and sets it
  does not sync; a property it has that the service no longer sends keeps
  its value.
- **Up**: OData 4.01's schema versioning (Part 1, 11.2.12). The
  service's `$metadata` says its version (`Core.SchemaVersion` on the
  schema: `ODataService.modelVersion`, by default the model's version
  identifiers), and every request a device sends names the one it speaks
  (`$schemaversion`, `ODataSyncEngine.modelVersion`; a `$batch`'s
  requests have the batch's). A version other than the service's is
  answered 404 (the spec's, for a version the service does not have),
  unless the service can read it: then its `upgradeBody` is handed each
  write (its body as sent, the version, the entity) and answers the body
  as its own model takes it, a renamed property under its new name, a new
  required one filled in; reads are answered from its own schema, and its
  `$metadata` is its own only. A data migration, as the app does for its
  store, but of one request. It can also refuse (a version too old): the
  change is set aside, not lost.
- **After an update**: the store is migrated (Core Data's migration), and
  the outbox with it: it holds keys and property names, not values, so
  what waited is sent from the migrated objects, in the new model's
  shape. When the engine sees its model version change, what remotes
  refused is sent again (a conflict set aside stays so).
- **Peers**: a peer server is an ODataService: an app sets its
  `upgradeBody` too, for peers on older versions.


## 14. Merged attributes

**Status: exists** (`ODataSyncMerging.h`, `ODSMerge.m`, `ODataSyncService`, the peer server; `Tests/ODataSyncMergeTests.m`).

Some values are not settled by a rule but merged: a note's text written on
two devices offline keeps both devices' typing. TopoTextSync does that
today as a resolver (section 6), over the whole state: every change sends
the text's whole state up, every read brings it whole down, and a state
only grows, since what was deleted cannot be forgotten until every copy
has seen it deleted, and no one knows when that is.

A **merged attribute** is a Binary attribute whose value is a mergeable
state (a CRDT): states merge in any order to the same result, a delta
since a version is what a copy at that version lacks, and what every copy
has seen can be collected. ODataSync moves deltas, not states, and keeps
what each replica has seen, so the state can be collected.

### 14.1 Declaring one

```
bodyText   Binary   ODataSync.merge   TopoText
```

`ODataSync.merge` names a **merger**, which the app registers on the
engine, on the device and at the service alike:

```objc
@protocol ODataSyncMerging <NSObject>
- (NSData *)versionOfState:(nullable NSData *)state;                         // nil: nothing seen
- (NSData *)deltaOfState:(nullable NSData *)state sinceVersion:(nullable NSData *)version;
- (nullable NSData *)stateByMerging:(NSData *)delta intoState:(nullable NSData *)state error:(NSError **)error;
- (NSData *)versionMeeting:(NSData *)version andVersion:(NSData *)other;    // what both have seen
- (nullable NSData *)stateByCollecting:(nullable NSData *)state seenBy:(NSData *)version;
@optional
- (void)mergedAttribute:(NSAttributeDescription *)attribute ofObject:(NSManagedObject *)object;  // a copy derived from it, set again
@end

[engine setMerger:[[TTSyncMerger alloc] init] forName:@"TopoText"];
```

Versions and deltas are the merger's bytes; ODataSync only stores and
moves them. The entity is a `both` entity. Two things are asked of a
merger beyond merging, for collecting (14.4):

- **A version never forgets.** Collecting forgets elements, not that they
  were seen: the version of a collected state has still seen them (a
  version vector keeps its counters), and a delta that brings one back is
  merged as nothing new.
- **Equal versions are equal bytes** from `-versionMeeting:andVersion:`,
  so whether one version has seen all another has can be told:
  `meet(a, b) == meet(b, b)`.

### 14.2 On the wire

One action import, which the service's operations answer (as `PeerToken`,
section 9 of peer-sync.md: an app with operations of its own adopts
`ODataSyncMergeActions` and forwards):

```
POST <root>MergeAttributes
{ "Replica": "<the device's replica ID>",
  "Items": [ { "EntitySet": "Notes", "Key": "<key text>", "Property": "BodyText",
               "Version": "<base64: what the device has>",
               "Delta": "<base64: what the service may lack>" }, ... ] }

→ { "Items": [ { "Delta": "<base64: what the device lacks>",
                 "Version": "<base64: the service's, after>",
                 "SeenByAll": "<base64>" },
               { "Error": "Body does not merge: ..." },
               { "Reset": true, "State": "<base64: the service's whole state>",
                 "Horizon": "<base64>", "Version": "<base64>" }, ... ] }
```

For each item the service finds the object as the request may see it
(its set handler's visibility: a user merges into their own rows only),
merges the delta in through the handler (none: a read), and answers what
the device lacks: a delta since the device's version. An item it cannot
answer (no such object, a delta that does not merge) has an `Error`
instead, and the others are answered and merged: one bad item holds up
no other. An item from a replica behind what was collected is answered
`Reset` (14.4). `Items` is `Edm.Untyped`: an app with operations of its
own says so in `+ODataOperationTypes`.

### 14.3 The device

- **What is exchanged**: an object whose merged attribute changed here
  (its history), and each row that came down of an entity with one, gets
  an outbox entry of its own (`ODataSyncOperationMerge`, which the row's
  entry, conflicts and the rest do not see). After the batch, the
  uploader's exchange takes them, a hundred to a call.
- **Two calls, nothing kept**: the first sends each object's version and
  gets what the device lacks, and the remote's version; the device merges
  it, and the second sends, for those that have more, a delta since that
  version, and for those the first changed, the version it has now (what
  the service collects by, 14.4). The device stores no remote version (no
  bookkeeping to migrate): the first call tells it.
- **An item that fails** (an `Error`, or an answer that does not merge
  here) is exchanged again at the next sync, and after three is set aside:
  an issue (`issues`), which the app retries or discards as it does a
  row's. It holds up nothing else.
- **Rows** go up (`PATCH`) and come down (`$select`) without merged
  attributes; a merged attribute is never compared in a conflict.
- What comes back is written as the remote's (transaction author
  `ODataSync.down.<remote>`): not sent back, passed on to peers.
- A remote with no `MergeAttributes` (404, 405, 501: an older service)
  leaves merged attributes as they are; the rest syncs.

### 14.4 Collecting

The service keeps, per object, attribute and replica, the version that
replica **says it has** (`ODSMergeSeen`, in the service's bookkeeping),
with when: what it sent as `Version`, never what it was answered, which
it may not get (a lost answer) or fail to merge. `SeenByAll` is the meet
of the versions of the replicas heard from within `mergeRetention`
(default: the tombstone retention, 30 days; it can be set longer), and of
the service's own: what nobody lacks. The service collects its state
with it, and so does the device when an answer carries it. A replica's
seeing a deletion is known one exchange later than it happens (the
device's second call tells it), so collecting lags by as much.

**Kicked, and back.** A replica not heard from within the retention is
let go of, as a game server kicks a client too far behind: it is no
longer waited for, and what everyone else has seen deleted is collected.
The service keeps what it last collected with, the **horizon** (an
`ODSMergeSeen` row of its own). When such a replica comes back, its
version does not cover the horizon, and the service answers it `Reset`
instead of merging what it sent: its whole state and the horizon. The
device re-bases: what it did since the horizon
(`deltaOfState:mine sinceVersion:horizon`), merged into that state, is
its state now, and its second call sends those edits. What was deleted
while it was away comes back nowhere, and its own new edits are kept.
Whatever a delta brings that the horizon has seen is dropped before it is
merged, so a stale copy cannot bring collected elements back either.

The same takes in a device that only ever met peers (the service never
heard from it, so never waited for it) and two devices with one replica
ID (one restored from another's backup): when they reach the service,
they are behind its horizon, and re-base.

The order matters: what the device lacks is computed **before** the
service collects. Collecting then may forget a deletion this very device
has not seen yet; it is in the delta it is answered with, and the device
collects it in turn. (Computed after, the device would never hear of the
deletion, and its next delta would bring the element back.)

A peer server answers `MergeAttributes` as the service does, but keeps
nothing of what peers have seen, and so collects nothing, and keeps no
horizon: a device that collected what the service told it serves a
peer that missed a deletion a state without it, so that peer keeps the
element until it reaches the service, and re-bases there. It cannot bring
the element back meanwhile: a delta it sends lacks what the device's
version has seen.

### 14.5 Clients that send states

A client that does not know merged attributes PATCHes the whole state:
the set handler merges it in (a state is a delta since nothing) instead
of storing it over what is there. Reads that do not `$select` it out get
the state, as before.
