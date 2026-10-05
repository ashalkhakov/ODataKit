# syntax=docker/dockerfile:1
#
# ODataKit on Linux: the GNUstep stack, FreeCoreData and ODataKit, built
# once, in four images (docs/building.md):
#
#   docker build -f Docker/Dockerfile --target sdk       -t odatakit-sdk .
#   docker build -f Docker/Dockerfile --target runtime   -t odatakit-runtime .
#   docker build -f Docker/Dockerfile --target ois-serve -t ois-serve .
#   docker build -f Docker/Dockerfile --target check .
#   docker build -f Docker/Dockerfile --target unit .
#
#   sdk        everything to build an application with: clang, the stack,
#              FreeCoreData (with momc and the PostgreSQL and MySQL stores),
#              ODataKit and ODataServer installed, with the make fragment
#              and pkg-config files (Server/Examples/Docker builds in it)
#   runtime    what such an application needs to run, and no more
#   ois-serve  runtime and ois-serve, serving a model from settings
#              (OIS_ variables, or a property list at OIS_CONFIG)
#   check      sdk, with the loopback check run and an application built
#              against the installed libraries both ways, for CI
#   unit       sdk, with the XCTest suite run (make test), as CI's unit
#              tests: tools-xctest is part of the stack for it, and
#              avahi-daemon runs for the peer discovery test
#
# The stack is gnustep-patches' build, as CI's: the same two pins.

ARG UBUNTU=24.04

FROM ubuntu:${UBUNTU} AS toolchain
ARG DEBIAN_FRONTEND=noninteractive
# Through caching proxies that answer with stale indexes, which apt then
# refuses (hash sum mismatch): no pipelining, no proxy caches, retries.
RUN printf 'Acquire::http::No-Cache "true";\nAcquire::BrokenProxy "true";\nAcquire::http::Pipeline-Depth "0";\nAcquire::Retries "3";\n' \
      > /etc/apt/apt.conf.d/99-odatakit
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git make cmake patch pkg-config clang lld \
      libgnutls28-dev libffi-dev libicu-dev libxml2-dev libxslt1-dev libssl-dev zlib1g-dev \
      libcurl4-gnutls-dev libgmp-dev libsqlite3-dev libpq-dev libmariadb-dev \
 && rm -rf /var/lib/apt/lists/* \
 # The gnustep-2.0 runtime needs ld.gold or lld.
 && update-alternatives --install /usr/bin/ld ld /usr/bin/ld.lld 10

ENV PREFIX=/opt/gnustep \
    CC=clang CXX=clang++ \
    LIBRARY_COMBO=ng-gnu-gnu RUNTIME_VERSION=gnustep-2.0 \
    COMPONENTS="libobjc2 libdispatch tools-make libs-base tools-xctest"
# Every RUN in the images after this one sees the stack (GNUstep.sh).
COPY Docker/ois-env /usr/local/bin/ois-env
SHELL ["/usr/local/bin/ois-env", "/bin/sh", "-c"]

FROM toolchain AS stack
ARG GNUSTEP_PATCHES_REF=7539fc686a72250574fff6c17e1c92eb024ddc33
ARG FREECOREDATA_REF=b612b0a90fcae0b0fabcd1ff71442988eb67b518
RUN set -e; \
    mkdir -p /tmp/src/gnustep-patches && cd /tmp/src/gnustep-patches; \
    git init -q && git remote add origin https://github.com/ashalkhakov/gnustep-patches.git; \
    git fetch -q --depth 1 origin "$GNUSTEP_PATCHES_REF" && git checkout -q FETCH_HEAD; \
    SOURCES=/tmp/src/gnustep Scripts/build-gnustep.sh; \
    rm -rf /tmp/src
RUN set -e; \
    mkdir -p /tmp/src/FreeCoreData && cd /tmp/src/FreeCoreData; \
    git init -q && git remote add origin https://github.com/ashalkhakov/FreeCoreData.git; \
    git fetch -q --depth 1 origin "$FREECOREDATA_REF" && git checkout -q FETCH_HEAD; \
    make -j"$(nproc)" && make install; \
    make -C Tools/momc && make -C Tools/momc install; \
    make -C Backends/PostgreSQL && make -C Backends/PostgreSQL install; \
    make -C Backends/MySQL && make -C Backends/MySQL install; \
    cd / && rm -rf /tmp/src

FROM stack AS sdk
ARG VERSION=0.0.0
ARG DEBIAN_FRONTEND=noninteractive
# ODataSync's peers: Bonjour by Avahi's dns_sd compatibility library (here,
# not in the toolchain, so the stack's layers stay cached).
RUN apt-get update && apt-get install -y --no-install-recommends libavahi-compat-libdnssd-dev \
 && rm -rf /var/lib/apt/lists/*
COPY . /usr/src/odatakit
WORKDIR /usr/src/odatakit
RUN set -e; \
    make -j"$(nproc)" ODATAKIT_VERSION="$VERSION" HTTPSERVERKIT_VERSION="$VERSION"; \
    make install ODATAKIT_VERSION="$VERSION" HTTPSERVERKIT_VERSION="$VERSION"; \
    make -C Server -j"$(nproc)" && make -C Server install; \
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
    AVAHI_COMPAT_NOWARN=1 make test

FROM ubuntu:${UBUNTU} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
# Through caching proxies that answer with stale indexes, which apt then
# refuses (hash sum mismatch): no pipelining, no proxy caches, retries.
RUN printf 'Acquire::http::No-Cache "true";\nAcquire::BrokenProxy "true";\nAcquire::http::Pipeline-Depth "0";\nAcquire::Retries "3";\n' \
      > /etc/apt/apt.conf.d/99-odatakit
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libgnutls30t64 libffi8 libicu74 libxml2 libxslt1.1 zlib1g libcurl3t64-gnutls libgmp10 \
      libsqlite3-0 libpq5 libmariadb3 libstdc++6 libatomic1 libavahi-compat-libdnssd1 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=sdk /opt/gnustep /opt/gnustep
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
