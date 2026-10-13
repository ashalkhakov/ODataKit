#!/bin/bash
# ODataWorkbench-Linux-<version>-x86_64.AppImage: the Workbench, the
# library, FreeCoreData and the GNUstep runtime in one file.
set -eo pipefail
# GNUstep.sh reads unset variables (ZSH_VERSION), so set -u comes after it.
. "$PREFIX/System/Library/Makefiles/GNUstep.sh"
set -u
GNUSTEP_PREFIX="$PREFIX" ./Scripts/prepare-appdir.sh
GNUSTEP_PREFIX="$PREFIX" ./Scripts/package-appimage.sh
