#!/bin/bash
# FreeCoreData (beside this repository: the framework, momc and its SQL
# stores), the libraries and the Workbench, on the stack in $PREFIX.
set -euo pipefail
. "$PREFIX/System/Library/Makefiles/GNUstep.sh"
(cd ../FreeCoreData
 make -j"$(nproc)" && make install
 make -C Tools/momc && make -C Tools/momc install
 make -C Backends/PostgreSQL && make -C Backends/MySQL)
make -j"$(nproc)"
make -C Examples/Workbench
