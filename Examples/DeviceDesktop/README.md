# OIS Device for the desktop

The [iOS Device app](../Device/README.md)'s counterpart, on macOS and on
Linux (GNUstep). It is an offline device kept in sync by ODataSync with a
Workbench that serves its built-in service. It syncs with other devices
nearby too, desktops and iPhones alike
([peer sync](../../docs/peer-sync.md)).

Most of it comes from elsewhere:
- The device and its peers are the iOS app's own: `DVSession` and `DVPeers`
  in `Examples/Device`, which are Foundation only.
- The window that shows the device is the Workbench's Sync window
  (`WBSyncWindow`): Data, Waiting, Conflicts, Requests.
- This app adds the Peers window, the Workbench's address, the menus, and a
  self-test.

## What it shows

- **The device window** (Window > Device):
  - The device's objects, an entity at a time: New, Delete, values edited
    in place.
  - What waits to be sent (a change set aside is retried or discarded).
  - The conflicts met, and the device's own requests.
  - Sync, Download, Upload, Reconcile; the conflict rule; Offline; Sync
    each change; Reset Device.
- **Peers** (Window > Peers):
  - **Get a Peer Token** asks the Workbench for this device's token.
    Devices with tokens from the same Workbench trust each other.
  - **Serve to peers** serves the store over TLS, advertised by Bonjour.
  - **Show Pairing Code** shows a QR code, for an iPhone to scan, and its
    text, which you **Copy**. On another desktop you **Paste** that text
    and press **Pair**.
  - **Nearby** lists the devices found: select one and choose **Sync with
    Selected**, or double-click it.
  - **Paired** lists the devices paired: **Forget** removes one.
- **Device > Workbench Address…** sets the address: the Workbench's
  status line shows it under Sync > Serve on the Network. A new address is
  a new device.

## Running it

1. Serve the Workbench's built-in service: Sync > Serve on the Network, or
   `Workbench --serve`.
2. Start the app:
   - On a Mac: open `ODataKit.xcworkspace`, choose the **DeviceDesktop**
     scheme, and run.
   - On Linux, with the libraries built at the root (`make` there):

     ```sh
     . /path/to/GNUstep.sh
     make -C Examples/DeviceDesktop
     openapp Examples/DeviceDesktop/DeviceDesktop.app
     ```

     Or, without building anything: the Workbench's AppImage carries this
     app too (`ODataWorkbench-Linux-*.AppImage device`, or its launcher's
     Device button).

     Discovery takes avahi-daemon running. A desktop has it; in a
     container, start D-Bus and avahi-daemon first. Set
     `AVAHI_COMPAT_NOWARN=1` to quiet Avahi's warning.
3. Set the Workbench's address (the app asks the first time), then Sync.

**Two devices on one machine:** start a second instance with its own
store, settings, identity and port:

```sh
DeviceDesktop -DVInstance B -DVPeerPort 8643
```

Each serves on its own port, and each finds the other nearby. This works
the same between a desktop and an iPhone (on the same network), and
between two machines.

## The self-test

With a Workbench serving, the app tests peer sync end to end, with no
window:

```sh
DeviceDesktop --self-test http://127.0.0.1:8640/odata/
```

It makes three devices of its own (instances `self-test-A`, `-B`, `-C`,
emptied first), on ports 8650 to 8652:
1. A and B sync with the Workbench and get peer tokens.
2. A serves, and B finds it by Bonjour.
3. A changes a product without sending it to the Workbench, and B syncs
   with A and has the change.
4. C, with no token, is refused; then it pairs with A, syncs, and has the
   change too.

Each step prints PASS or FAIL. The exit status is the number that failed.
At the end it discards the three devices: their stores, identities,
pairings and settings are removed.

## Peers from a terminal

With no window, between machines, or with a phone, there are two modes.
Each runs the device of `-DVInstance` (the app's own when none is given).
It syncs with the Workbench first and gets a peer token.

```sh
# Serve to peers, printing the root, the certificate's thumbprint and a
# pairing offer (for 600 seconds; 0 or nothing: until stopped):
DeviceDesktop --serve http://192.168.1.10:8640/odata/ 600 -DVInstance A -DVPeerPort 8642

# Sync with a peer by token (the thumbprint it printed is the only
# certificate taken):
DeviceDesktop --sync-with http://192.168.1.10:8640/odata/ https://192.168.1.20:8642/sync/<replica>/ <thumbprint> -DVInstance B

# Pair with it first, given its offer (the JSON --serve prints, or a
# Pairing Code's text), then sync:
DeviceDesktop --sync-with http://192.168.1.10:8640/odata/ https://192.168.1.20:8642/sync/<replica>/ '<offer>' -DVInstance C
```

These modes have been run both ways between a Mac and Linux (GNUstep in a
container), by token and by pairing. In one direction a Linux client
(libcurl and GnuTLS) reached a Mac's Network.framework listener; in the
other a Mac's URLSession reached a Linux GnuTLS listener.

## What it is made of

| File | What |
|---|---|
| `main.m` | The app, or no window: the self-test, `--serve`, `--sync-with` |
| `DDAppController.{h,m}` | The session, the device window, the Peers window, the menus, the address |
| `DDPeersWindow.{h,m}` | The Peers window |
| `DDSelfTest.{h,m}` | The self-test, and peers from a terminal (`--serve`, `--sync-with`) |
| `DDSystem.h`, `apple/`, `linux/` | What differs by system: the QR code (Core Image, libqrencode), the pasteboard, a button's bezel, the device's name |
| `GNUmakefile` | The Linux build |
| `DeviceDesktop.xcodeproj` | The Mac build |
| `../Device/DVSession`, `DVPeers` | The device and its peers, the iOS app's |
| `../Workbench/WorkbenchDevice`, `WorkbenchModel`, `WorkbenchSupport`, `WBSync` | The device, its model, its window: the Workbench's |
