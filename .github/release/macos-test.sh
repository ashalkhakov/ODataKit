#!/bin/bash
# The offline self-test, against the built-in service.
set -euo pipefail
"$1/Contents/MacOS/Workbench" --self-test builtin
