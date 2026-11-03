# OData Workbench in UDCode

ODataKit ships a [UDCode](https://github.com/ashalkhakov/UDCodeKit)
extension, OData Workbench, which lets you try OData v4 services inside
UDCode the way the Workbench app does: keep the services you work with,
write requests as text files in your project, send them from the editor,
and read the answers, the wire log and the traces in the bottom area. It is
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
(`engines.udcode` in its `package.json`: 0.19 and later), and UDCode refuses
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

An `.odata` file is a list of requests, written as VS Code's REST Client
writes them:

```
# Requests to Northwind
GET Products?$filter=UnitPrice gt 20
  &$expand=Category&$top=10

### Raise a price
PATCH Products(1)
Content-Type: application/json

{ "UnitPrice": 19.5 }
```

- A request line is `METHOD URL` (`GET` when the method is left out); a
  relative URL goes on from the service root. Lines after it that begin
  with `?` or `&` add to its query.
- Headers follow, one `Name: value` to a line; then a blank line and the
  body.
- `###` begins the next request (and names it, when text follows it).
  Lines beginning with `#` or `//` are comments.

**Editor > Run** (⌘↩) sends the request at the caret; **Run All** (⇧⌘↩)
sends them all, one after another. (They are UDCode's, from 0.19, and run
the SQL mode's statements in a `.sql` document.) A document sends to the
service chosen for it (a service's **Send Requests To This Service**,
remembered for the file), or to the only service connected. A service not
connected yet is connected first. **New Request Document** on a service, or
double-clicking an entity set, opens one already sent to it.

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

- **`ODWExtension`**, its principal class: the `odata` mode
  (`LanguageInfo.plist`), the navigator and the bottom area's segment, for
  each window; it answers UDCode's Editor > Run for `.odata` documents
  (`-workbench:canRunDocument:`, `-workbench:runDocument:selection:all:`).
- **`ODWServices`**, a window's services: kept where they say, connected
  through the Workbench's `WBConnection` (the built-in service's
  `WorkbenchEngine`, or the network), signed in with `ODataSignIn` and
  `WBSignInPanel`, its secrets in UDCode's `UDCredentialStore`. A request is
  sent as written (`-[WBConnection sendRequest:done:]`: signed as the store
  signs its own, asked again once with fresh credentials after a 401),
  inside a client span (OTelKit's `OTHTTP`).
- **`ODWRequests`**, the REST Client format.
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
  GNUstep and GCDWebServer's on a Mac, from the release tags they are pinned
  to.
- **On a Mac** it is signed with `$CODESIGN_IDENTITY`: UDCode's hardened
  runtime loads only code signed by its own team.

The release workflows run that script through `.github/release/udcode.conf`
(gnustep-release-actions' `scripts/udcode-extension.sh`) and attach each
package to the release.

The tests in `UDCodeExtension/Tests` (`ODWTests`, run by `make check` and by
`make -f Makefile.apple check`) need no network. They check that:

- requests are read as REST Client writes them, and their URLs made from the
  service root;
- the presets are there, a user's service is kept in the defaults and a
  project's in its settings (never a secret);
- a request to the built-in service is answered, its rows read, its
  exchange in the wire log and its trace kept;
- the navigator, the bottom pane and the service sheet load from their
  XIBs, connected, with their menus;
- UDCode's Run sends an `.odata` document's request at the caret.
