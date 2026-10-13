#!/bin/bash
# The libraries, the Workbench, the Device app and the launcher into the prefix's System domain, where gnustep-release-actions'
# appimage takes them from.
set -eo pipefail
# GNUstep.sh reads unset variables (ZSH_VERSION), so set -u comes after it.
. "$PREFIX/System/Library/Makefiles/GNUstep.sh"
set -u
make install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
for app in Workbench DeviceDesktop Launcher; do
  make -C "Examples/$app" install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
done
