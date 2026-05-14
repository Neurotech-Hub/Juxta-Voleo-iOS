# Voleo (iOS)

Companion app for Juxta 5.8+ wearable devices. Connect over Bluetooth Low Energy, sync session settings, transfer daily data packages, and inspect logs — all from your iPhone.

Developed by the [Neurotech Hub](https://neurotechhub.wustl.edu) at Washington University in St. Louis.

## Overview

Voleo is the iOS companion for Juxta 5.8+ devices. It reads the node (camelCase JSON), writes session settings over the gateway (camelCase JSON, UTC `timestamp`), discovers the daily files on the device, and pulls them down as locally stored CSV "Daily Packages" you can browse, plot, share, and copy long after disconnecting.

## Features

- **BLE scan & connect** with custom service UUID
- **Firmware** — reads `firmwareVersion` from the node; a strict 5.8-only disconnect gate may be enabled in code for specific builds
- **Session settings sync** — Subject ID, Experiment, advertising interval, scanning interval, inactivity scan multiplier; values are read from the node on connect and pushed back from the inline Device Settings card
- **Daily Packages** — groups `JXV/JXS/JXB YYYYMMDD.csv` files for a day, transfers all three at once, and stores them under `Documents/<device_id>/`
- **Packages tab** — browse all locally stored packages across all devices, plus per-package detail with raw text, **View Plots** (Vitals: battery / temperature / motion; BLE Activity: peer-vs-time scatter color-coded by RSSI), **View Table** (Settings), Copy All, and Share
- **Terminal tab** — full BLE log with copy / clear
- **Info tab** — app version, DFU note (uses Nordic **nRF Connect** with developer-supplied firmware), and magnet-gesture / LED reference
- **Visual connection cue** — while connected, the **Device** tab icon and label stay green (including on other tabs); battery glyph reflects the reported percent

## Requirements

- iOS 17.0+
- Xcode 15.0+
- A physical Bluetooth-enabled iPhone (BLE does not work in the Simulator)
- A Juxta 5.8+ device

## Installation

1. Clone the repository.
2. Open `Juxta-Voleo-iOS.xcodeproj` in Xcode.
3. Confirm Bluetooth and Background Modes capabilities are configured for your team / signing setup.
4. Build & run the **Voleo-iOS** scheme on a physical device.

## Usage

### Scan & connect

- Open the **Device** tab and tap **Scan** to discover Juxta devices (filtered by the service UUID below).
- Tap **Connect** on a discovered device. After service discovery, Voleo reads the node payload (camelCase JSON: battery, memory, firmware version, subject, experiment, advertising/scanning intervals, inactivity multiplier).
- If a firmware-version gate is enabled in the build and `firmwareVersion` does not start with `5.8`, Voleo disconnects and may show an **Incompatible Voleo (v5.8) device** alert.

### Device Settings (push)

- Edit Subject ID, Experiment, advertising interval (1–10 s, step 1), scanning interval (5–60 s, step 5), and the inactivity scan multiplier in the inline card.
- Each interval has an **Off** toggle to the right of its slider; turning it on disables the slider and sends `0` for that interval (advertising or scanning disabled on the node).
- The inactivity scan multiplier is a segmented control with `1×…5×`; the selected integer is sent as `inactivityMultiplier` and is applied to the scan interval during inactivity (`1×` effectively disables the multiplier).
- **Push** writes the values to the device. **Default** asks for confirmation, then restores Adv `10 s`, Scan `10 s`, Inactivity Scan Multiplier `5×`, and clears both **Off** toggles locally (you still need to **Push** to send them).

### Daily Packages

- The connected screen lists daily packages found on the device. Pick a date and tap **Transfer Selected**; Voleo will queue Vitals, Settings, and BLE Activity in turn.
- Transferred packages get a green checkmark for the duration of the session.
- Files land in `Documents/<device_id>/` and remain available offline in the **Packages** tab.
- In the Packages detail screen you can **Copy All** (filenames included in section headers), **Share** (via a temporary directory copy to satisfy iOS sandboxing), **View Plots**, or **View Table**.

### Maintenance

- **Shelf Mode** — sends `{"reset": true}` (gateway, camelCase) after a confirmation alert.
- **Clear Memory** — sends `{"clearMemory": true}` after a confirmation alert.

### Terminal

The **Terminal** tab shows the full BLE log with copy and clear actions in the navigation bar (same pattern as **Packages** and **Info**).

## BLE Protocol

The app communicates using these UUIDs:

- Service: `57617368-5501-0001-8000-00805f9b34fb`
- Filename: `57617368-5502-0001-8000-00805f9b34fb`
- File Transfer: `57617368-5503-0001-8000-00805f9b34fb`
- Gateway: `57617368-5504-0001-8000-00805f9b34fb`
- Node: `57617368-5505-0001-8000-00805f9b34fb`

### Node Characteristic Payload (READ)

On connect the app reads the node characteristic and expects a JSON object with **camelCase** keys. The app parses the keys below; any additional keys are ignored.

```json
{
  "uploadPath": "<from NVS>",
  "firmwareVersion": "5.8.0",
  "batteryLevel": 85,
  "memoryLevel": 42,
  "deviceId": "JX_XXXXXX",
  "alert": "",
  "product": "Juxta5-8",
  "logSchema": "jxta-nor-csv-v4",
  "loggingVersion": 4,
  "experiment": "<from NVS>",
  "subjectId": "<from NVS>",
  "advInterval": 5,
  "scanInterval": 20,
  "inactivityMultiplier": 2
}
```

| Key                     | Type   | App behavior                                                                 |
| ----------------------- | ------ | ---------------------------------------------------------------------------- |
| `firmwareVersion`       | string | Shown in header; strict 5.8 disconnect may apply when that gate is enabled. |
| `batteryLevel`          | int    | Shown in connected header.                                                  |
| `memoryLevel`           | int    | Shown in connected header (optional; only displayed if present).            |
| `deviceId`              | string | Logged on connect; packages use the peripheral name as folder key.          |
| `subjectId`             | string | Populates the Subject ID field in Device Settings.                          |
| `experiment`            | string | Populates the Experiment field in Device Settings.                         |
| `advInterval`           | int    | Populates the Advertising Interval slider (clamped 1–10s). `0` turns **Off** on. |
| `scanInterval`          | int    | Populates the Scanning Interval slider (clamped 5–60s, step 5). `0` turns **Off** on. |
| `inactivityMultiplier`  | int    | Populates the Inactivity Scan Multiplier control (clamped 1–5).            |
| other keys              | any    | Ignored.                                                                    |

### Gateway Characteristic Payload (WRITE)

All gateway commands use **camelCase** keys. After a successful node read, the app sends **one** JSON object with UTC `timestamp` and `sendFilenames: true` to start the session (Pi-style). Settings writes omit `experiment` when empty.

```json
{
  "timestamp": 1717003200,
  "sendFilenames": true,
  "clearMemory": true,
  "reset": true,
  "subjectId": "001",
  "experiment": "trial-A",
  "advInterval": 5,
  "scanInterval": 20,
  "inactivityMultiplier": 2
}
```

| Key                      | Type | Notes                                                                            |
| ------------------------ | ---- | -------------------------------------------------------------------------------- |
| `timestamp`              | int  | Unix **UTC** epoch seconds; combined with `sendFilenames` after connect.       |
| `sendFilenames`          | bool | Requests the file listing from the device.                                       |
| `clearMemory`            | bool | Wipes device storage; confirmed via UI alert.                                   |
| `reset`                  | bool | "Shelf Mode" — gracefully reset the device.                                     |
| `subjectId`              | str  | Always sent on Push; whitespace-trimmed.                                        |
| `experiment`             | str  | Sent only when non-empty after trimming.                                       |
| `advInterval`            | int  | 1–10s, step 1. Sent as `0` when **Off** (advertising disabled).                |
| `scanInterval`           | int  | 5–60s, step 5. Sent as `0` when **Off** (scanning disabled).                   |
| `inactivityMultiplier`   | int  | Integer in `1…5` (1 = effectively off).                                        |

### Daily Packages on disk

Transferred files are stored at:

```
Documents/<device_id>/
  JXV<YYYYMMDD>.csv   # Vitals
  JXS<YYYYMMDD>.csv   # Settings
  JXB<YYYYMMDD>.csv   # BLE Activity
```

The `<YYYYMMDD>` portion is the date key Voleo groups by.

### Schema sync checklist

If you change the JSON schema in either direction:

1. Update this README (the node and gateway tables above).
2. Update `peripheral(_:didUpdateValueFor:)` in `ContentView.swift` (node parsing and filename listing buffer).
3. Update `BLEManager` gateway helpers (`writeGatewayJSONObject`, `saveSettings()`, `clearMemory()`, `resetToShelfMode()`, `sendTimestampAndFilenamesRequest()`).
4. Communicate the change to the firmware developer so the node side matches.

## Firmware update (DFU)

Voleo does not flash firmware. To update a device:

1. Use the magnet gesture to enter DFU mode (see the **Info** tab in the app for the magnet/LED reference).
2. Use Nordic Semiconductor's **nRF Connect** app to flash a firmware image supplied by the developer.

## Development

Voleo is intended for developers and operators working with Juxta 5.8+ devices. The Terminal tab provides full BLE-level visibility for debugging, and the Info tab surfaces the build number (`CFBundleShortVersionString` + `CFBundleVersion`) for support reports.

## License

[Add your license information here]
