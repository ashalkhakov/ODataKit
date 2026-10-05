# Building

## Toolchain

ODataKit **will not compile** against GCC's `libobjc`: the headers refuse
anything that is not clang, Objective-C 2.0, ARC and blocks.

| | |
|---|---|
| Language | Objective-C 2.0 (properties, literals, blocks, ARC, `NS_ENUM`, zeroing weak) |
| Runtime | **libobjc2** (`-fobjc-runtime=gnustep-2.0`) or Apple's |
| ABI | Non-fragile: ivars live in `@implementation { }` blocks |
| Foundation | gnustep-base or Apple Foundation |
| Core Data | Apple Core Data, or **[FreeCoreData](https://github.com/ashalkhakov/FreeCoreData)** on GNUstep |
| Transport | `NSURLSession`, on Apple and on a gnustep-base built with libcurl; `NSURLConnection` otherwise (with the patched stack below it follows relative redirects and reads `$batch` answers) |
| Strings | `-fconstant-string-class=NSConstantString` on GNUstep |

The libraries are ARC. FreeCoreData is manual reference counting
(`-fno-objc-arc`); they link, since methods named `new…` return +1 on both
sides.

```
clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks \
      -fconstant-string-class=NSConstantString
```

## macOS: Xcode

Open **`ODataKit.xcworkspace`** (not a lone `.xcodeproj`: the example apps
need the framework project in the same workspace).

| Scheme | Product |
|---|---|
| `ODataKit` | macOS framework, the shared core |
| `ODataIncrementalStore` | macOS framework, the client (links `ODataKit`) |
| `ODataService` | macOS framework, the server (links `ODataKit`) |
| `ODataKitTests` | XCTest for all three: snapshots, the service in process, no network (⌘U) |
| `Catalog` | A small AppKit client |
| `Workbench` | The workbench |
| `Device` | The Workbench's device on iOS ([iOS](#ios)) |
| `DeviceDesktop` | The same device on macOS (and Linux, with `make`): its desktop counterpart |

```
xcodebuild -workspace ODataKit.xcworkspace -scheme ODataKitTests -destination 'platform=macOS' test
```

A client app embeds `ODataKit.framework` and `ODataIncrementalStore.framework`
(Catalog does); one that serves as well adds `ODataService.framework` and
`HTTPServerKit.framework` and `OTelKit.framework`, which it links
(Workbench does). The server tools build with plain clang, with no Xcode
project: `make -C Server` writes `Server/build/ois-serve`, and
`make -C Server check` runs it over a loopback socket.

## iOS

ODataKit, OTelKit, ODataIncrementalStore, HTTPServerKit, ODataService and
ODataSync build for iOS 15 and later (devices and the simulator) as well
as for macOS: the same targets in
`ODataKit.xcodeproj`, the same schemes, chosen by the destination.

```
xcodebuild -workspace ODataKit.xcworkspace -scheme ODataSync -destination 'generic/platform=iOS Simulator' build
```

HTTPServerKit and ODataService build for iOS too, so that a device can
serve its store to its peers ([peer sync](peer-sync.md)). On iOS:

- **HTTPServerKit**: a server is started (`-startOnPort:error:`), never
  run (`-runOnPort:` answers that it is unsupported).
- **ODataService**: no XML store (`NSXMLStoreType` is macOS only).
- **ODataSync**: its peer identity, listener, trust, transport and discovery
  (TLS, Bonjour) are Apple's, on iOS and macOS alike.
- **XML**: Foundation on iOS has no `NSXMLDocument`, which reading and
  writing `$metadata` (and a generated model) use. `ODataXML.h` names the
  classes the client uses, `ODataXMLDocument`, `ODataXMLElement` and
  `ODataXMLNode`: NSXML's where Foundation has them, and on iOS OISXML's,
  the subset of NSXML they need, over `NSXMLParser`. OISXML is built on
  every platform and checked against NSXML (`ODataXMLTests`).

An app embeds the frameworks it links. `Examples/Device` is one: the
Workbench's Sync window on an iPhone ([its README](../Examples/Device/README.md)).
For a device, it needs your signing team (`Examples/Device/Local.xcconfig`).

## GNUstep

CI builds against a GNUstep stack from
[gnustep-patches](https://github.com/ashalkhakov/gnustep-patches), whose
`Scripts/build-gnustep.sh` makes it; `.github/workflows/ci.yml` has the exact
recipe and the commits it pins.

Install [FreeCoreData](https://github.com/ashalkhakov/FreeCoreData) first: it
is the Core Data this store subclasses (`NSIncrementalStore`, the coordinator)
and the server stores in. Install its model compiler too (`make -C Tools/momc
install` there): the tests and example apps compile `Catalog.xcdatamodeld` to
`.momd`, which is what FreeCoreData loads. ODataSync's peers need
GnuTLS, libcurl (built with GnuTLS) and Avahi's dns_sd compatibility
library: on Ubuntu, `libgnutls28-dev libcurl4-gnutls-dev
libavahi-compat-libdnssd-dev`, and `avahi-daemon` running to find peers
([peer sync](peer-sync.md)). Then:

```sh
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make && make install                 # libODataKit, libODataIncrementalStore, libOTelKit, libHTTPServerKit, libODataService
make -C Server && make -C Server install   # ois-serve
```

### Building against what is installed

`make install` also installs what an application builds with
(`Scripts/install-build-files.sh`): a fragment in
`$GNUSTEP_MAKEFILES/Additional/`, which every GNUmakefile includes by itself,
and pkg-config files beside the libraries.

With gnustep-make, name its variables (`Server/Examples/Docker/GNUmakefile`):

```make
include $(GNUSTEP_MAKEFILES)/common.make
TOOL_NAME = myserver
myserver_OBJC_FILES = main.m
myserver_INCLUDE_DIRS = $(ODATASERVICE_INCLUDE_DIRS)
myserver_OBJCFLAGS = $(ODATAKIT_OBJCFLAGS)
myserver_TOOL_LIBS = $(ODATASERVICE_LIBS)
include $(GNUSTEP_MAKEFILES)/tool.make
```

`ODATAKIT_*` is what a client and a service share, `ODATAINCREMENTALSTORE_*`
the client, `ODATASERVICE_*` the service, on its own or on the network
(`ODataServer.h`); `HTTPSERVERKIT_*` is the HTTP server alone, for an
application with no OData in it; `OTELKIT_*` the tracing alone.

Without it, pkg-config (`odatakit`, `odataincrementalstore`, `otelkit`,
`httpserverkit`, `odataservice`) gives the same, GNUstep's own flags
included:

```sh
export PKG_CONFIG_PATH=$(gnustep-config --variable=GNUSTEP_LOCAL_LIBRARIES)/pkgconfig
clang main.m $(pkg-config --cflags --libs odataservice) -o myserver
```

### Docker

`Docker/Dockerfile` builds the stack once, as CI does, into four images:

```sh
docker build -f Docker/Dockerfile --target sdk       -t odatakit-sdk .
docker build -f Docker/Dockerfile --target runtime   -t odatakit-runtime .
docker build -f Docker/Dockerfile --target ois-serve -t ois-serve .
docker build -f Docker/Dockerfile --target check .
docker build -f Docker/Dockerfile --target unit .
```

- `odatakit-sdk`: clang, GNUstep, FreeCoreData (with `momc` and its
  PostgreSQL and MySQL stores), ODataKit and HTTPServerKit installed with the
  fragment and pkg-config files. Build an application in it.
- `check` and `unit` are for CI and for trying a change on Linux: the
  loopback check (`make -C Server check`) and an application built
  against what is installed; and the XCTest suite (`make test`, with
  `tools-xctest` in the stack).
- `odatakit-runtime`: what such an application needs to run, and no more;
  a library it would lack fails the image's build, not a server at start.
- `ois-serve`: the runtime and `ois-serve`, on every address at 8080, as a
  user of its own, with a volume at `/var/lib/ois-serve` and a health check.
  It logs JSON lines, and answers metrics, health and readiness on an admin
  port, 9090, for Prometheus and the orchestrator: publish that one only
  where they are. Under Kubernetes, point the liveness probe at `/health`,
  the readiness probe at `/ready`, and give `OIS_DRAIN_DELAY` a few seconds.
  Its settings are `ois-serve`'s, as `OIS_` variables
  (`HSApplication.h`), or a property list at `OIS_CONFIG`
  (`/etc/ois-serve/service.plist`: the Catalog example in SQLite):

  ```sh
  docker run -p 8080:8080 -v catalog:/var/lib/ois-serve \
    -e OIS_SERVICE_ROOT=https://api.example.com/odata/ ois-serve
  docker run -p 8080:8080 -e OIS_STORE_TYPE=CDPostgreSQLStore \
    -e OIS_STORE_URL=postgresql://user:secret@db/catalog ois-serve
  ```

- `check`: the SDK, with the loopback check run and an application built
  against what is installed, both ways. CI builds it.

An application of its own builds in the SDK and runs on the runtime
(`Server/Examples/Docker/Dockerfile`):

```dockerfile
FROM odatakit-sdk AS build
COPY . /app
RUN make -C /app

FROM odatakit-runtime
COPY --from=build /app/obj/myserver /usr/local/bin/myserver
ENV OIS_PORT=8080 OIS_LOCALHOST=NO
ENTRYPOINT ["/usr/local/bin/ois-env", "myserver"]
```

`ois-env` runs a command with the stack in its environment (`GNUstep.sh`).

Without gnustep-make, clang and `gnustep-config` build the command-line tool:

```sh
make -f Makefile
./ois-filter 'unitPrice > 20 AND discontinued == NO'
# UnitPrice gt 20 and Discontinued eq false
```

## Tests

XCTest, and no network: HTTP is a directory of OData v4 request/response
snapshots of real services (`Tests/Snapshots/`, each citing the protocol
section it pins), and the service is tested in process, a store talking to
it through `ODataTransport`. The tests load
`Examples/Catalog/Catalog.xcdatamodeld`, the example apps' model.

```sh
make test            # GNUstep
```

On Apple: the `ODataKitTests` scheme (⌘U).

The predicate pair tests (`$filter` → `NSPredicate` → rows, and `$apply`
grouping in the store against grouping in memory) also run over
FreeCoreData's SQL backends, given a server and the backends built there
(`make -C Backends/PostgreSQL`, `make -C Backends/MySQL`):

```sh
CD_TEST_POSTGRES_URL=postgresql://postgres:secret@localhost:5432/postgres \
CD_TEST_MYSQL_URL=mysql://root:secret@localhost:3306/oistest \
  make -C Tests run-tests FREECOREDATA_BACKENDS=<FreeCoreData>/Backends
```

Each store works in a schema of its own, dropped afterwards. CI runs them
against PostgreSQL 16, MySQL 8 and MariaDB 11.

`Tests/Live/` checks that real services agree: Microsoft's Northwind v4
(read) and TripPin (write, in a session of its own), streams and `$search`
among them. CI runs it without letting it fail a build, since the services are
not ours:

```sh
make -C Tests/Live live      # GNUstep
```

## The example apps

- `Examples/Workbench`: the workbench ([its README](../Examples/Workbench/README.md)).
  `Workbench --self-test` drives its window against each service and prints a
  line per check; `--self-test builtin` needs no network.
- `Examples/Device`: the Workbench's device on iOS, which syncs with a
  Workbench serving on the network (`Workbench --serve`) ([its README](../Examples/Device/README.md)).
- `Examples/DeviceDesktop`: the same device on a desktop, macOS or Linux,
  for peer sync between desktops and phones (`make -C Examples/DeviceDesktop`
  on Linux; it needs `libqrencode-dev` too). `DeviceDesktop --self-test
  <Workbench root>` tests peer sync end to end ([its README](../Examples/DeviceDesktop/README.md)).
- `Examples/Catalog`: a smaller client: a table, a predicate, an inspector.
- `Examples/QuickStart`: the README's first path, one file.

```sh
make -C Examples/Workbench && openapp Examples/Workbench/Workbench.app   # GNUstep
```
