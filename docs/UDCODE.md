# OData Workbench in UDCode

ODataKit ships a [UDCode](https://github.com/ashalkhakov/UDCodeKit)
extension, OData Workbench, which lets you try OData v4 services inside
UDCode the way the Workbench app does: keep the services you work with,
build requests (queries, creates, updates, deletes, calls) as files in your
project, send them from the editor or take them away as curl, and read the
answers, the wire log and the traces in the bottom area. It is
built on the Workbench's own parts (`Examples/Workbench/files.make`); the
Workbench remains its own app.

## Installing it

Each ODataKit release attaches a package for each platform:

| UDCode on | Package |
|---|---|
| macOS, Apple silicon | `odata-<version>-darwin-arm64.udcx` |
| macOS, Intel | `odata-<version>-darwin-x64.udcx` |
| Linux (the AppImage), x86_64 | `odata-<version>-linux-x64.udcx` |
| Linux, aarch64 | `odata-<version>-linux-arm64.udcx` |
| Windows | `odata-<version>-win32-x64.udcx` |

Install it with **UDCode > Extensions… > Install from Package…**, or from a
shell with `UDCode --install-extension odata-<version>-<platform>.udcx`,
then start UDCode again. A package states which UDCode versions it is for
(`engines.udcode` in its `package.json`: 0.19.2 and later 0.19 releases, whose
GNUstep has the predicate editor its query builder uses), and UDCode refuses
one built for another version or another platform.

## Services

The **OData** navigator lists the window's services:

- **Built-in Sample**: the Workbench's own service, in UDCode's process, with
  no network: the Catalog (products, categories, suppliers, stock), seeded
  with a few of Northwind's rows, and what the Workbench shows of OData
  besides (versions and conflicts, application time, media, an open type, a
  hierarchy, operations).
- **Northwind** (read-only) and **TripPin** (read/write, in a session of its
  own): Microsoft's public services.
- **The project's**, kept in its `.udcode/settings.json` (`"odataServices"`:
  a name and a service root), so everyone who opens the folder has them.
- **Yours**, for every project, kept in UDCode's defaults.

Add one with **+** (a name, its service root, and whether the project keeps
it); a right click edits or removes it. Double-click a service to connect:
its `$metadata` is read, and the entity sets and the functions and actions it
serves are listed under it. A service that asks for a sign-in says so in its
`$metadata` (OData's Authorization vocabulary), and the Workbench's sign-in
panel asks: a user and password, or OpenID Connect's device flow (a code to
enter in the browser, and the identity provider's client to sign in as).
Tokens and passwords are kept where UDCode keeps passwords: the Keychain on
macOS, the Secret Service on Linux, Windows Credential Manager. **Sign Out**
forgets them. Nothing secret is ever written to a project's settings.

## Requests

A request is built, not written: an `.odataq` document opens in the
request builder, against a service of yours. **New Query Builder** (a right
click on a service, or on one of its entity sets) opens one; so does
double-clicking an entity set, which also sends it.

The **Request** popup says what kind it is:

- **Query (GET)**: the Workbench's query panel, a field or a list a row: an
  entity, a predicate in `NSPredicate` syntax, built as rows of the
  entity's attributes (**Builder**) or written (**Text**), `$top`, `$skip` and a page
  size, the result type (objects, object IDs, dictionaries, a count); sort
  keys (`$orderby`), relationships to prefetch, opened to nest (`$expand`),
  the properties of a dictionary result (`$select`); `$search`, values
  computed from each row (`$compute`), a grouping and its aggregates
  (`$apply`), and application time for an entity that has it. Give the
  **Key** above it and it is a GET of that one entity (`Products(1)`, its
  `$select` and `$expand` kept).
- **Create (POST)**, **Update (PATCH)**, **Delete (DELETE)**: an entity set,
  the key of the one to change (an update's and a deletion's), and the body
  as JSON (a create's and an update's), begun with the entity's properties.
  An update and a deletion are sent `If-Match: *`: whatever version the
  entity is at.
- **Call a Function or Action**: the operation and its parameters, a field
  each; a function's go in its URL, an action's are its body.

Values are typed as they are: a string as it is (`O'Neil`; the builder
quotes it), anything else as a URL has it (`1`, `true`, `2024-01-01`), an
action's parameters as JSON.

The line at the bottom is the request as it is sent (or why it cannot be
yet). **Execute**, or **Editor > Run** (⌘↩; UDCode's, from 0.19), sends it,
and the answer is the bottom area's **Results**. **Show curl** opens it as a
curl command in a new shell document, **Copy curl** puts that on the
clipboard: its method, URL, headers and body, quoted for a shell. (The
built-in service answers only in UDCode; curl cannot reach it.)

### Requests set up for you

A right click on an entity set offers **Insert Request**, a builder set up
from the service's `$metadata`:

- **GET All** (`$top=20`), **GET by Key** (`Products(1)`), **GET $count**;
- **POST a New One**, its body a JSON object of the entity's properties
  (its base types' first, computed ones and streams left out);
- **PATCH One** (the same body, its key left out) and **DELETE One**.

On a function or an action, **Insert Call** sets up its call. Values are
samples of their types (`1`, `text`, `2024-01-01`, an enumeration's first
member) for you to change.

### The file

The document's text is the request, kept as JSON:

```json
{
  "service" : "Northwind",
  "request" : "query",
  "query" : {
    "entity" : "Product",
    "predicate" : "unitPrice > 20",
    "sort" : [ { "key" : "unitPrice", "descending" : true } ],
    "expand" : [ "category" ],
    "limit" : "10"
  }
}
```

`request` is `query`, `create`, `update`, `delete` or `call`; with it come
`entitySet`, `key`, `body`, `operation` and `parameters`, as the kind asks.
Each change in the builder is written into it as one edit, so undo, saving
and diffs are UDCode's; save it where you like (`.odataq`), and opening it
again brings up the builder. **View > Open as Text** shows it with the JSON
mode's highlighting. A change to the text is read back into the builder.
The **Service** popup chooses the service it is sent to; another service
starts it again, over its entities.

## The answers

The extension's segment of the bottom area has three panes:

- **Results**: the last answer. A collection's rows (or the one entity) as a
  table, its properties as columns; the JSON indented under it; and a line
  saying what came back (`200 OK · 10 rows · 143 ms`) or why nothing did.
- **Wire Log**: every exchange with the services, newest first, the store's
  own (`$metadata`, the sign-in's) among them; the chosen one as it went over
  the wire, its request and its response.
- **Traces**: each request is an OpenTelemetry trace. At the built-in
  service, its planning and its store's requests are under it. With
  `OTEL_EXPORTER_OTLP_ENDPOINT` set, the spans also go to that collector
  (Jaeger, Tempo).

## How it is built

`UDCodeExtension/` holds the extension:

- **`ODWExtension`**, its principal class: the `odataq` mode
  (`LanguageInfo.plist`) and its editor, the navigator and the bottom
  area's segment, for each window; it answers UDCode's Editor > Run for
  `.odataq` documents (`-workbench:canRunDocument:`,
  `-workbench:runDocument:selection:all:`).
- **`ODWServices`**, a window's services: kept where they say, connected
  through the Workbench's `WBConnection` (the built-in service's
  `WorkbenchEngine`, or the network), signed in with `ODataSignIn` and
  `WBSignInPanel`, its secrets in UDCode's `UDCredentialStore`. A request is
  sent as built (`-[WBConnection sendRequest:done:]`: signed as the store
  signs its own, asked again once with fresh credentials after a 401),
  inside a client span (OTelKit's `OTHTTP`).
- **`ODWBuilderViewController`**, an `.odataq` document's editor: the kind
  of request, its fields, and for a query the Workbench's `WBQueryPanel`
  (the same panel as the Workbench's window, stacked:
  `WBQueryPanelStacked.xib`, its controls and outlets `WBQueryPanel.xib`'s)
  over the service's connection; its request the document's JSON (a
  query's WBQuery's `-dictionary` and `-takeDictionary:`).
- **`ODWTemplates`**, the requests Insert Request and Insert Call set up,
  and what the builder makes of them: a key's path, a call's, a body, curl.
- **`ODWNavigatorViewController`**, **`ODWServiceSheet`** and
  **`ODWBottomViewController`**, the navigator, the service sheet and the
  bottom pane, each a XIB of its own; the bottom pane shows the Workbench's
  `WBExchangeLog` and `WBTracesViewController`.

It builds against UDCode's SDK, the `udcodekit` archives attached to each
UDCode release, pinned by `UDCODEKIT_VERSION` in `.github/pins.env`, on the
same GNUstep stack as that UDCode release (`GNUSTEP_PATCHES_VERSION`). At
run time the extension uses UDCode's own copies of these, because two copies
of the same classes cannot be loaded into one process. On GNUstep the top
`GNUmakefile` builds it only where the SDK is installed. On a Mac,
`Makefile.apple` builds it only where `.deps` contains
`UDCodeKit.xcframework`.

`Scripts/udcx.sh <version> <directory>` packages it for the platform it runs
on:

- **The bundle carries what UDCode lacks.** On GNUstep, the Workbench's parts
  are compiled into the bundle, their XIBs and the built-in service's Catalog
  model among its resources; ODataKit's libraries and FreeCoreData's Core
  Data go beside its binary, and on Linux each gets an `$ORIGIN` runpath. On
  a Mac, ODataKit's frameworks, and GCDWebServer's, are in the bundle's
  `Contents/Frameworks`.
- **What UDCode has is left out:** GNUstep, DiagramKit, UDCodeKit and the
  system's libraries.
- **Licences:** ODataKit's own (LGPL 2.1 or later, with its source at the
  release tag that package.json's `repository` points to), FreeCoreData's on
  GNUstep, and GCDWebServer's (HTTPServerKit's), from the release tags they
  are pinned to.
- **On a Mac** it is signed with `$CODESIGN_IDENTITY`: UDCode's hardened
  runtime loads only code signed by its own team.

The release workflows run that script through `.github/release/udcode.conf`
(gnustep-release-actions' `scripts/udcode-extension.sh`) and attach each
package to the release.

The tests in `UDCodeExtension/Tests` (`ODWTests`, run by `make check` and by
`make -f Makefile.apple check`) need no network. They check that:

- the presets are there, a user's service is kept in the defaults and a
  project's in its settings (never a secret);
- a request to the built-in service is answered, its rows read, its
  exchange in the wire log and its trace kept;
- the navigator, the bottom pane and the service sheet load from their
  XIBs, connected, with their menus;
- each request set up for an entity set or an operation is the builder's
  request it means (its method, its URL, its body), the GETs answered by the
  built-in service, and curl gives it quoted for a shell;
- Insert Request and Insert Call open a builder set up for the request, from
  the row's context menu;
- the predicate is shown in the predicate editor, its rows the entity's
  attributes, and what is built there is the query's text and its
  `$filter`; a text the editor cannot show stays text, with Builder off;
- a query is kept whole as JSON and read back, and the builder writes each
  change into its document (another kind of request too), reads the
  document's changes back, and sends its request; given a key, a query is
  of that one entity.
