# syntax=docker/dockerfile:1
#
# ODataKit on Linux, on the GNUstep stack, FreeCoreData and GCDWebServer, in
# four images (docs/building.md):
#
#   docker build -f Docker/Dockerfile --target sdk       -t odatakit-sdk .
#   docker build -f Docker/Dockerfile --target runtime   -t odatakit-runtime .
#   docker build -f Docker/Dockerfile --target ois-serve -t ois-serve .
#   docker build -f Docker/Dockerfile --target check .
#   docker build -f Docker/Dockerfile --target unit .
#
#   sdk        everything to build an application with: clang, the stack,
#              FreeCoreData (with momc and the PostgreSQL and MySQL stores),
#              GCDWebServer, ODataKit and ODataServer installed, with the make
#              fragment and pkg-config files (Server/Examples/Docker builds in it)
#   runtime    what such an application needs to run, and no more
#   ois-serve  runtime and ois-serve, serving a model from settings
#              (OIS_ variables, or a property list at OIS_CONFIG)
#   check      sdk, with the loopback check run and an application built
#              against the installed libraries both ways (CI runs the same in
#              the sdk image: .github/release/docker-test.sh)
#   unit       sdk, with the XCTest suite run (make -C Tests run-tests), as
#              CI's unit tests: tools-xctest is part of the stack for it, and
#              avahi-daemon runs for the peer discovery test
#
# What it builds on is what CI builds on: the releases .github/pins.env names
# (the GNUstep stack, FreeCoreData, GCDWebServer), each an archive unpacked
# at /. gnustep-release-actions' docker.yml passes their versions as build
# arguments of the same names; built by hand, pins.env's are taken.

# The runtime image is the same Ubuntu the archives are built on, so its
# libraries are the ones built against.
ARG UBUNTU=22.04

FROM ubuntu:${UBUNTU} AS stack
ARG DEBIAN_FRONTEND=noninteractive
ARG GNUSTEP_PATCHES_VERSION
ARG FREECOREDATA_VERSION
ARG GCDWEBSERVER_VERSION
# Through caching proxies that answer with stale indexes, which apt then
# refuses (hash sum mismatch): no pipelining, no proxy caches, retries.
RUN printf 'Acquire::http::No-Cache "true";\nAcquire::BrokenProxy "true";\nAcquire::http::Pipeline-Depth "0";\nAcquire::Retries "3";\n' \
      > /etc/apt/apt.conf.d/99-odatakit
COPY .github/pins.env /tmp/pins.env
# The archives, the stack first; then the packages building on the stack
# needs (its own list, beside it), and ODataKit's: FreeCoreData's SQLite,
# PostgreSQL and MySQL clients, and Avahi's dns_sd for ODataSync's peers.
RUN set -e; \
    apt-get update; apt-get install -y --no-install-recommends ca-certificates curl xz-utils; \
    for name in GNUSTEP_PATCHES FREECOREDATA GCDWEBSERVER; do \
      eval "version=\${${name}_VERSION:-}"; \
      [ -n "$version" ] || version=$(sed -n "s/^${name}_VERSION=//p" /tmp/pins.env); \
      repo=$(echo "$name" | tr 'A-Z_' 'a-z-'); \
      curl -fsSL "https://github.com/ashalkhakov/$repo/releases/download/v$version/$repo-$version-ubuntu22.04-$(uname -m).tar.xz" \
        | tar -C / -xJ; \
    done; \
    grep -v '^#' /opt/gnustep/share/gnustep-patches/packages-ubuntu.txt \
      | xargs apt-get install -y --no-install-recommends libsqlite3-dev libpq-dev libmariadb-dev libavahi-compat-libdnssd-dev; \
    update-alternatives --install /usr/bin/ld ld /usr/bin/ld.gold 10; \
    rm -rf /var/lib/apt/lists/*
ENV CC=clang CXX=clang++ LIBRARY_COMBO=ng-gnu-gnu RUNTIME_VERSION=gnustep-2.0
# Every RUN in the images after this one sees the stack (GNUstep.sh).
COPY Docker/ois-env /usr/local/bin/ois-env
SHELL ["/usr/local/bin/ois-env", "/bin/sh", "-c"]

FROM stack AS sdk
ARG VERSION=0.0.0
COPY . /usr/src/odatakit
WORKDIR /usr/src/odatakit
# The libraries and the server's tools; not the example apps.
RUN set -e; \
    make -j"$(nproc)" ODATAKIT_PARTS=Server ODATAKIT_VERSION="$VERSION" HTTPSERVERKIT_VERSION="$VERSION"; \
    make install ODATAKIT_PARTS=Server ODATAKIT_INSTALLED=Server ODATAKIT_VERSION="$VERSION" HTTPSERVERKIT_VERSION="$VERSION"; \
    mkdir -p /usr/local/share/ois-serve; \
    momc Examples/Catalog/Catalog.xcdatamodeld /usr/local/share/ois-serve/Catalog.momd
ENV PKG_CONFIG_PATH=/opt/gnustep/Local/Library/Libraries/pkgconfig
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/ois-env"]
CMD ["/bin/bash"]

FROM sdk AS check
WORKDIR /usr/src/odatakit
RUN make -C Server check
# An application built against what is installed, not the source tree:
# with the fragment every GNUmakefile includes, and with pkg-config.
RUN set -e; \
    mkdir -p /tmp/app && cp Server/Examples/Docker/GNUmakefile Server/Examples/CatalogServer.m /tmp/app/; \
    make -C /tmp/app; \
    clang Server/Examples/CatalogServer.m $(pkg-config --cflags --libs odataservice) -o /tmp/catalog-server-pc; \
    for app in /tmp/app/obj/catalog-server /tmp/catalog-server-pc; do \
      "$app" -Model /usr/local/share/ois-serve/Catalog.momd -PrintMetadata YES | grep -q '<EntitySet Name="Products"'; \
    done; \
    echo "check: the loopback check, and an application built both ways, pass"

FROM sdk AS unit
ARG DEBIAN_FRONTEND=noninteractive
# The peer discovery test advertises and browses: avahi-daemon, which
# talks to the system D-Bus, both started for the run.
RUN apt-get update && apt-get install -y --no-install-recommends avahi-daemon dbus \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /usr/src/odatakit
RUN set -e; \
    mkdir -p /run/dbus; dbus-daemon --system --fork; avahi-daemon --daemonize --no-chroot; \
    AVAHI_COMPAT_NOWARN=1 make -C Tests run-tests

# What a server needs of the stack: the stack image carries the GUI too
# (gnustep-gui, the backend and its bundles, the Eau theme, Opal), which no
# service here loads and whose libraries the runtime image does not have; it
# leaves, with every library and program that links it or what it draws and
# plays with (images, sound, cairo, X, fonts: gui's tools too), and XCTest.
FROM sdk AS runtime-files
RUN set -e; cd /opt/gnustep; \
    rm -rf Local/Library/Bundles Local/Library/ColorPickers Local/Library/Themes Local/Library/Images \
           Local/Library/Sounds Local/Library/PostScript System/Library/Bundles System/Library/Themes \
           System/Library/CoreServices/Applications; \
    find . -type f \( -name '*.so*' -o -perm -u+x \) | while read -r f; do \
      if readelf -d "$f" 2>/dev/null | grep -qE 'NEEDED.*\[lib(gnustep-gui|opal|XCTest|tiff|png|jpeg|gif|sndfile|ao|cairo|X|freetype|fontconfig|icns|lcms)'; then rm -f "$f"; fi; \
    done; \
    rm -f Local/Library/Libraries/libgnustep-gui.so* Local/Library/Libraries/libopal.so* Local/Library/Libraries/libXCTest.so*

FROM ubuntu:${UBUNTU} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
# Through caching proxies that answer with stale indexes, which apt then
# refuses (hash sum mismatch): no pipelining, no proxy caches, retries.
RUN printf 'Acquire::http::No-Cache "true";\nAcquire::BrokenProxy "true";\nAcquire::http::Pipeline-Depth "0";\nAcquire::Retries "3";\n' \
      > /etc/apt/apt.conf.d/99-odatakit
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libgnutls30 libffi8 libicu70 libxml2 libxslt1.1 zlib1g libcurl3-gnutls libgmp10 \
      libsqlite3-0 libpq5 libmariadb3 libstdc++6 libatomic1 libavahi-compat-libdnssd1 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=runtime-files /opt/gnustep /opt/gnustep
COPY --from=sdk /usr/local/share/ois-serve /usr/local/share/ois-serve
COPY Docker/ois-env /usr/local/bin/ois-env
# A library the image lacks fails the build here, not a server at start.
RUN set -e; \
    missing=$(find /opt/gnustep -type f \( -name '*.so*' -o -perm -u+x \) -exec sh -c \
      'file="$1"; LD_LIBRARY_PATH=/opt/gnustep/lib:/opt/gnustep/System/Library/Libraries:/opt/gnustep/Local/Library/Libraries ldd "$file" 2>/dev/null | grep "not found" | sed "s|^|$file: |"' _ {} \; | sort -u); \
    if [ -n "$missing" ]; then echo "$missing" >&2; exit 1; fi
ENTRYPOINT ["/usr/local/bin/ois-env"]

FROM runtime AS ois-serve
RUN useradd --system --home-dir /var/lib/ois-serve --create-home ois
COPY Docker/service.plist /etc/ois-serve/service.plist
# In a container: on every address, at 8080. Set OIS_SERVICE_ROOT to the
# public URL the service is reached at; its links begin with it. The access
# log is JSON lines, for a log collector; metrics, health and readiness are
# on the admin port, 9090, for Prometheus and the orchestrator (publish it
# only where they are).
ENV OIS_CONFIG=/etc/ois-serve/service.plist \
    OIS_PORT=8080 \
    OIS_LOCALHOST=NO \
    OIS_ACCESS_LOG=json \
    OIS_ADMIN_PORT=9090 \
    OIS_ADMIN_LOCALHOST=NO \
    HOME=/var/lib/ois-serve
USER ois
WORKDIR /var/lib/ois-serve
VOLUME /var/lib/ois-serve
EXPOSE 8080 9090
HEALTHCHECK --interval=30s --timeout=3s \
  CMD ["/bin/bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${OIS_PORT:-8080} && printf 'GET /health HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q '200 OK' <&3"]
ENTRYPOINT ["/usr/local/bin/ois-env", "ois-serve"]
