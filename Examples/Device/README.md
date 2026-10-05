# Device.app

The Workbench's Sync window (Sync > Show Device) on an iPhone or iPad: an
offline device kept in sync by ODataSync ([offline sync](../../docs/offline-sync.md)),
for trying it on a real device. It syncs over the network with a Workbench
on a Mac that serves its built-in service.

The device works the way the Sync window's does, and it is the same code:
`WorkbenchDevice` (the store, the sync engine, the conflict rules, the
request log) and `WorkbenchModel` (the built-in model), in
`Examples/Workbench`. This app adds UIKit screens, made in code, over them.

- **Data**: one entity at a time (the menu at the left shows which way each
  goes: Product and Stock both ways, Category, Supplier and Location down),
  with what that means above the rows. Pull down, or tap Sync, to sync;
  hold Sync for Download, Upload and Reconcile. For a both-ways entity,
  **+** makes an object, a swipe deletes one, and in a row's values a tap
  changes one.
- **Waiting**: changes not yet sent, with a badge on the tab. Swipe one that
  was set aside to retry it (the device's version over the service's) or
  discard it (the service's is read).
- **Conflicts**: conflicts met and how each was settled; tap one for its
  three versions (the one both last agreed on, the device's, the
  service's; `*` marks what changed).
- **Peers**: other devices running the app nearby, synced with directly
  ([peer sync](../../docs/peer-sync.md)), no Workbench needed once set up.
  - **Get a Peer Token** asks the Workbench for this device's token. Devices
    with tokens from the same Workbench trust each other.
  - **Serve to Peers** serves this device's store on port 8642, over TLS,
    and advertises it nearby.
  - **Nearby** lists the devices found: tap one to sync with it.
  - **Show Pairing Code** and **Pair with a Device** pair two devices
    without a token: one shows a QR code, the other scans it, or copies
    and pastes its text. Forget a paired device with a swipe.
- **Requests** (under More on an iPhone): the device's own exchanges,
  newest first; tap one for what went and what came back.
- **Settings**: the Workbench's address, the conflict rule, Offline, Sync
  each change, Reset Device.

The device's data is kept between launches (Application Support), and the
app syncs when it opens or comes back to the foreground. A new address
means a new device, so its store is emptied.

## Running it

1. On the Mac, in the Workbench: **Sync > Serve on the Network**, or start
   it with `Workbench --serve [port]`. The built-in service is then served
   at `http://<the Mac's address>:8640/odata/` with **no authentication**,
   to anyone on the network. The status line shows the address. The data
   starts again from the seed rows.
2. Open `ODataKit.xcworkspace`, choose the **Device** scheme and an iPhone
   (or a simulator), and run. On a device, Xcode signs the app with your
   team: either choose it in the target's Signing & Capabilities pane, or
   put `DEVELOPMENT_TEAM = <your team ID>` in `Examples/Device/Local.xcconfig`,
   which git ignores. The simulator needs neither.
3. In the app's Settings, type the address. The first time, iOS asks to
   allow access to the local network: allow it.

Then try it as you would in the Sync window.

For peers, run the app on two devices on the same network, each with the
Workbench's address set. On each, under Peers, choose Get a Peer Token,
then turn on Serve to Peers. Each then appears under the other's Nearby:
tap it to sync. A change made on one reaches the other with no Workbench in
between, and the Workbench later gets it from either. Two simulators on
one Mac share its port 8642, so only one of them can serve.

Pairing doesn't need a token:
1. On one device, choose Show Pairing Code.
2. On the other, choose Pair with a Device and scan the code, or paste
   its text. The simulator has no camera, so it can only paste.

On a device, iOS asks for the camera the first time. For example: change a
product on the phone and in the Workbench (Change at the Service, or edit
it in the main window), sync, and see how the rule settles it. Or turn
Offline on, make changes, and turn it off again.

```sh
xcodebuild -workspace ODataKit.xcworkspace -scheme Device \
  -destination 'generic/platform=iOS Simulator' build
```

## What it is made of

| File | What |
|---|---|
| `main.m` | The app delegate: the tabs, a sync on opening |
| `DVSession.{h,m}` | The device for the address set, and the settings kept across launches |
| `DVControllers.{h,m}` | The screens |
| `DVPeers.{h,m}` | The peers: identity, trust and token, serving and advertising, browsing, pairing |
| `DVPeersController.{h,m}` | The Peers tab, the pairing code (QR), the scanner |
| `Device.xcconfig` | iOS 15 and later, iPhone and iPad, the Info.plist keys (local network, camera), signing |
| `Info.plist` | App Transport Security (plain HTTP on the local network), the Bonjour service type browsed |
| `../Workbench/WorkbenchDevice.{h,m}`, `WorkbenchModel.{h,m}`, `WorkbenchSupport.{h,m}` | Shared with the Workbench |

It links ODataKit, OTelKit, ODataIncrementalStore, ODataSync, HTTPServerKit
and ODataService, built for iOS from `ODataKit.xcodeproj`
([building](../../docs/building.md#ios)).
