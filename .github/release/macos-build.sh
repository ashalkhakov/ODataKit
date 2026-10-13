#!/bin/bash
# For gnustep-release-actions' macos-release.yml: first what CI ran, the unit
# tests against Apple's Core Data, the HTTP adapter over loopback, the example
# apps (and the iOS Device app) built, the live service checks and the
# Workbench's online self-test (both on services out of our hands, so they
# warn rather than fail), and the Device app syncing with the Workbench; then
# the Workbench, universal, its frameworks embedded, into $RELEASE_DIR.
set -euo pipefail
xcodebuild -version
xcodebuild -workspace ODataKit.xcworkspace -scheme ODataKitTests \
  -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath "$RUNNER_TEMP/DerivedData" \
  -resultBundlePath "$RUNNER_TEMP/ODataKitTests.xcresult" test
make -C ThirdParty/GCDWebServer check
make -C Server check
for scheme in Catalog Workbench DeviceDesktop; do
  xcodebuild -workspace ODataKit.xcworkspace -scheme "$scheme" \
    -destination 'platform=macOS' -configuration Debug \
    -derivedDataPath "$RUNNER_TEMP/DerivedData" build
done
xcodebuild -workspace ODataKit.xcworkspace -scheme Device \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath "$RUNNER_TEMP/DerivedData-iOS" build

# Northwind and TripPin: generated models and classes, against the services.
live() {
  set -e
  inc="-ISource/ODataKit/include -ISource/ODataKit/include/ODataKit -ISource/ODataIncrementalStore/include -ISource/ODataIncrementalStore/include/ODataIncrementalStore"
  client="Source/ODataKit/*.m Source/ODataIncrementalStore/*.m"
  xcrun momc Examples/Catalog/Catalog.xcdatamodeld "$RUNNER_TEMP/Catalog.momd"
  xcrun momc Tests/Live/TripPin.xcdatamodeld "$RUNNER_TEMP/TripPin.momd"
  xcrun momc Tests/Live/Northwind.xcdatamodeld "$RUNNER_TEMP/Northwind.momd"
  clang -fobjc-arc -fmodules $inc $client Tools/ois-model.m \
    -framework Foundation -framework CoreData -o "$RUNNER_TEMP/ois-model"
  "$RUNNER_TEMP/ois-model" https://services.odata.org/V4/Northwind/Northwind.svc/ "$RUNNER_TEMP/NorthwindGenerated.xcdatamodeld"
  xcrun momc "$RUNNER_TEMP/NorthwindGenerated.xcdatamodeld" "$RUNNER_TEMP/NorthwindGenerated.momd"
  clang -fobjc-arc -fmodules $inc $client Tests/Live/ois-live.m \
    -framework Foundation -framework CoreData -o "$RUNNER_TEMP/ois-live"
  "$RUNNER_TEMP/ois-live" "$RUNNER_TEMP"
  "$RUNNER_TEMP/ois-model" --classes "$RUNNER_TEMP/TripPinClasses" \
    https://services.odata.org/V4/TripPinServiceRW/ "$RUNNER_TEMP/Generated/TripPin.xcdatamodeld"
  xcrun momc "$RUNNER_TEMP/Generated/TripPin.xcdatamodeld" "$RUNNER_TEMP/TripPinGenerated.momd"
  clang -fobjc-arc -fmodules $inc -I"$RUNNER_TEMP/TripPinClasses" \
    $client "$RUNNER_TEMP"/TripPinClasses/*.m Tests/Live/ois-classes.m \
    -framework Foundation -framework CoreData -o "$RUNNER_TEMP/ois-classes"
  "$RUNNER_TEMP/ois-classes" "$RUNNER_TEMP/TripPinGenerated.momd"
}
(live) || echo "::warning::the live service checks failed (services.odata.org)"
debug=$RUNNER_TEMP/DerivedData/Build/Products/Debug
"$debug/Workbench.app/Contents/MacOS/Workbench" --self-test \
  || echo "::warning::the Workbench's online self-test failed"

# The Device app syncing with the Workbench, as peers.
"$debug/Workbench.app/Contents/MacOS/Workbench" --serve > "$RUNNER_TEMP/workbench-serve.log" 2>&1 &
server=$!
trap 'kill $server 2> /dev/null || true' EXIT
for i in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:8640/odata/ && break; sleep 1; done
"$debug/DeviceDesktop.app/Contents/MacOS/DeviceDesktop" --self-test http://127.0.0.1:8640/odata/
kill $server

xcodebuild -workspace ODataKit.xcworkspace -scheme Workbench \
  -destination 'generic/platform=macOS' -configuration Release \
  -derivedDataPath "$RUNNER_TEMP/DerivedData" build
app=$RUNNER_TEMP/DerivedData/Build/Products/Release/Workbench.app
for fw in ODataKit ODataIncrementalStore OTelKit HTTPServerKit ODataService ODataSync; do
  test -d "$app/Contents/Frameworks/$fw.framework" \
    || { echo "::error::Workbench.app does not embed $fw.framework"; exit 1; }
done
ditto "$app" "$RELEASE_DIR/Workbench.app"
