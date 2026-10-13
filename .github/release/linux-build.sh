#!/bin/bash
# FreeCoreData (beside this repository: the framework, momc and its SQL
# stores), the libraries and the Workbench, on the stack in $PREFIX.
set -eo pipefail
# GNUstep.sh reads unset variables (ZSH_VERSION), so set -u comes after it.
. "$PREFIX/System/Library/Makefiles/GNUstep.sh"
set -u
(cd ../FreeCoreData
 make -j"$(nproc)" && make install
 make -C Tools/momc && make -C Tools/momc install
 make -C Backends/PostgreSQL && make -C Backends/MySQL)
make -j"$(nproc)"
make -C Examples/Workbench
