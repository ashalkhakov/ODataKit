#!/bin/bash
# The app's signature holds (ad hoc, or the release's), and the offline
# self-test against the built-in service passes.
set -euo pipefail
codesign --verify --deep --strict "$1"
"$1/Contents/MacOS/Workbench" --self-test builtin
