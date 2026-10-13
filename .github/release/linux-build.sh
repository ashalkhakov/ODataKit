#!/bin/bash
# On the stack in $PREFIX: FreeCoreData (beside this repository: the
# framework, momc and its SQL stores), the libraries, built with gnustep-make
# and without it, and the example apps; then what CI ran: the unit tests
# (Avahi for the discovery test), predicates and grouping over PostgreSQL,
# MySQL and MariaDB (the servers gnustep-release-actions starts: databases in
# build.yml), the HTTP adapter over loopback, the live service checks and the
# Workbench's online self-test (warning only: services out of our hands), and
# the Device app syncing with the Workbench.
set -eo pipefail
# GNUstep.sh reads unset variables (ZSH_VERSION), so set -u comes after it.
. "$PREFIX/System/Library/Makefiles/GNUstep.sh"
set -u
(cd ../FreeCoreData
 make -j"$(nproc)" && make install
 make -C Tools/momc && make -C Tools/momc install
 make -C Backends/PostgreSQL && make -C Backends/MySQL)
make -j"$(nproc)"

make -f Makefile
got=$(LD_LIBRARY_PATH=".:$LD_LIBRARY_PATH" ./ois-filter 'unitPrice > 20 AND discontinued == NO')
want='UnitPrice gt 20 and Discontinued eq false'
[ "$got" = "$want" ] || { echo "::error::ois-filter printed '$got', expected '$want'"; exit 1; }
make -f Makefile clean

for app in Catalog Workbench DeviceDesktop Launcher; do make -C "Examples/$app"; done

sudo systemctl start avahi-daemon || echo "::warning::avahi-daemon did not start: the discovery test is not run"
AVAHI_COMPAT_NOWARN=1 make test

backends="FREECOREDATA_BACKENDS=$PWD/../FreeCoreData/Backends"
CD_TEST_POSTGRES_URL="$POSTGRES_URL" CD_TEST_MYSQL_URL="${MYSQL_URL%/*}/oistest" \
  make -C Tests run-tests "$backends"
CD_TEST_MYSQL_URL="${MARIADB_URL%/*}/oistest" make -C Tests run-tests "$backends"

make -C ThirdParty/GCDWebServer check
make -C Server check

make -C Tests/Live live || echo "::warning::the live service checks failed (services.odata.org)"
(cd Examples/Workbench
 LD_LIBRARY_PATH="$PWD/../../obj${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" xvfb-run -a ./Workbench.app/Workbench --self-test) \
  || echo "::warning::the Workbench's online self-test failed"

# The Device app syncing with the Workbench, as peers.
(export LD_LIBRARY_PATH="$PWD/obj${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" AVAHI_COMPAT_NOWARN=1
 cd Examples/Workbench
 xvfb-run -a ./Workbench.app/Workbench --serve > "$RUNNER_TEMP/workbench-serve.log" 2>&1 &
 server=$!
 trap 'kill $server 2> /dev/null || true; pkill -f "Workbench.app/Workbench --serve" || true' EXIT
 for i in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:8640/odata/ && break; sleep 1; done
 ../DeviceDesktop/DeviceDesktop.app/DeviceDesktop --self-test http://127.0.0.1:8640/odata/)
