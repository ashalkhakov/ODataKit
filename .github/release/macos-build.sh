#!/bin/bash
# The Workbench for gnustep-release-actions' macos-release.yml: universal,
# its frameworks embedded, into $RELEASE_DIR.
set -euo pipefail
xcodebuild -workspace ODataKit.xcworkspace -scheme Workbench \
  -destination 'generic/platform=macOS' -configuration Release \
  -derivedDataPath "$RUNNER_TEMP/DerivedData" \
  MARKETING_VERSION="${APP_VERSION%%-*}" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build
app=$RUNNER_TEMP/DerivedData/Build/Products/Release/Workbench.app
for fw in ODataKit ODataIncrementalStore OTelKit HTTPServerKit ODataService ODataSync; do
  test -d "$app/Contents/Frameworks/$fw.framework" \
    || { echo "::error::Workbench.app does not embed $fw.framework"; exit 1; }
done
ditto "$app" "$RELEASE_DIR/Workbench.app"
