#!/bin/bash
# The Device app syncing with the Workbench, as peers: the Workbench serves
# (--serve, at 127.0.0.1:8640), the Device app syncs with it and checks what
# came back (--self-test). make check runs it, on GNUstep and on macOS:
#
#   Scripts/peer-sync-check.sh <Workbench executable> <DeviceDesktop executable>
#
# XVFB, when set (xvfb-run -a), runs the windows under it.
set -euo pipefail
workbench=$1 device=$2
log=$(mktemp)
${XVFB:-} "$workbench" --serve > "$log" 2>&1 &
server=$!
trap 'kill $server 2> /dev/null || true; pkill -f "Workbench --serve" 2> /dev/null || true' EXIT
for _ in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:8640/odata/ && break; sleep 1; done
curl -sf -o /dev/null http://127.0.0.1:8640/odata/ || { cat "$log"; echo "peer-sync-check: the Workbench did not serve"; exit 1; }
${XVFB:-} "$device" --self-test http://127.0.0.1:8640/odata/
