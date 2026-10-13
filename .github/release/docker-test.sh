#!/bin/bash
# ODataKit's images, for gnustep-release-actions' docker-release.yml (given
# the target and the image built and loaded):
#   sdk        the loopback check, and an application built against what is
#              installed (not the source tree) with the fragment every
#              GNUmakefile includes and with pkg-config, answering for the
#              Catalog model (the Dockerfile's check stage, run here)
#   ois-serve  the service started with its default settings (the Catalog
#              example in SQLite), its health and $metadata read back
#   runtime    its libraries are checked as it is built
set -euo pipefail
target=$1 image=$2
case "$target" in
  sdk)
    docker run --rm "$image" /bin/sh -c '
      set -e
      cd /usr/src/odatakit
      make -C Server check
      mkdir -p /tmp/app && cp Server/Examples/Docker/GNUmakefile Server/Examples/CatalogServer.m /tmp/app/
      make -C /tmp/app
      clang Server/Examples/CatalogServer.m $(pkg-config --cflags --libs odataservice) -o /tmp/catalog-server-pc
      for app in /tmp/app/obj/catalog-server /tmp/catalog-server-pc; do
        "$app" -Model /usr/local/share/ois-serve/Catalog.momd -PrintMetadata YES | grep -q "<EntitySet Name=\"Products\""
      done
      echo "check: the loopback check, and an application built both ways, pass"'
    ;;
  ois-serve)
    trap 'docker rm -f odatakit-ois-serve > /dev/null 2>&1 || true' EXIT
    docker run -d --name odatakit-ois-serve -p 18640:8080 -p 19090:9090 \
      -e OIS_SERVICE_ROOT=http://127.0.0.1:18640/ "$image" > /dev/null
    for _ in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:19090/health && break; sleep 1; done
    curl -sf http://127.0.0.1:19090/health
    curl -sf 'http://127.0.0.1:18640/$metadata' | grep -q '<EntitySet Name="Products"' \
      || { docker logs odatakit-ois-serve; echo "::error::ois-serve does not serve the Catalog"; exit 1; }
    echo "ois-serve: healthy, serving the Catalog"
    ;;
esac
