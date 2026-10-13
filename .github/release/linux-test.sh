#!/bin/bash
# The offline self-test drives the window against the built-in service.
set -euo pipefail
timeout 300 xvfb-run -a "$1" --self-test builtin
