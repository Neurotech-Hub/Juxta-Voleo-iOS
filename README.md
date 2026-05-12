# Voleo (iOS)

Companion app for Juxta 5.8+ wearable devices. Connect over Bluetooth Low Energy, sync session settings, transfer daily data packages, and inspect logs — all from your iPhone.

Developed by the [Neurotech Hub](https://neurotechhub.wustl.edu) at Washington University in St. Louis.

## Overview

Voleo is the iOS companion for Juxta 5.8+ devices. It validates firmware, writes session settings (Subject ID, Experiment, advertising/scanning intervals, inactivity doubler), discovers the daily files on the device, and pulls them down as locally stored CSV "Daily Packages" you can browse, plot, share, and copy long after disconnecting.

## Features

- **BLE scan & connect** with custom service UUID
- **Firmware gate** — disconnects from any device not reporting `firmware_version` starting with `5.8`
- **Session settings sync** — Subject ID, Experiment, advertising interval, scanning interval, inactivity doubler; values are read from the node on connect and pushed back from the inline Device Settings card
- **Daily Packages** — groups `JXV/JXS/JXB YYYYMMDD.csv` files for a day, transfers all three at once, and stores them under `Documents/<device_id>/`
- **Packages tab** — browse all locally stored packages across all devices, plus per-package detail with raw text, **View Plots** (Vitals: battery / temperature / motion; BLE Activity: peer-vs-time scatter color-coded by RSSI), **View Table** (Settings), Copy All, and Share
- **Terminal tab** — full BLE log with copy / clear
- **Info tab** — app version, DFU note (uses Nordic **nRF Connect** with developer-supplied firmware), and magnet-gesture / LED reference
- **Visual connection cue** — Device tab icon turns green while connected; battery glyph reflects the reported percent

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
- Tap **Connect** on a discovered device. After service discovery, Voleo validates firmware and reads the node payload (battery, memory, firmware version, subject, experiment, advertising/scanning intervals, inactivity doubler).
- If firmware doesn't start with `5.8`, Voleo disconnects and shows an **Incompatible Voleo (v5.8) device** alert.

### Device Settings (push)

- Edit Subject ID, Experiment, advertising interval (1–10 s, step 1), scanning interval (5–60 s, step 5), and the inactivity doubler in the inline card.
- **Push** writes the values to the device. **Default** asks for confirmation, then restores Adv `1 s`, Scan `20 s`, Inactivity doubler `on` locally (you still need to **Push** to send them).

### Daily Packages

- The connected screen lists daily packages found on the device. Pick a date and tap **Transfer Selected**; Voleo will queue Vitals, Settings, and BLE Activity in turn.
- Transferred packages get a green checkmark for the duration of the session.
- Files land in `Documents/<device_id>/` and remain available offline in the **Packages** tab.
- In the Packages detail screen you can **Copy All** (filenames included in section headers), **Share** (via a temporary directory copy to satisfy iOS sandboxing), **View Plots**, or **View Table**.

### Maintenance

- **Shelf Mode** — sends `{"reset": true}` after a confirmation alert.
- **Clear Memory** — sends `{"clear_memory": true}` after a confirmation alert.

### Terminal

The Terminal tab opens a full-screen sheet with the BLE log. Copy or clear from the toolbar.

## BLE Protocol

The app communicates using these UUIDs:

- Service: `57617368-5501-0001-8000-00805f9b34fb`
- Filename: `57617368-5502-0001-8000-00805f9b34fb`
- File Transfer: `57617368-5503-0001-8000-00805f9b34fb`
- Gateway: `57617368-5504-0001-8000-00805f9b34fb`
- Node: `57617368-5505-0001-8000-00805f9b34fb`

### Node Characteristic Payload (READ)

On connect the app reads the node characteristic and expects a JSON object with **snake_case** keys. The app parses the keys below; any additional keys are ignored. Firmware **must** report a `firmware_version` that starts with `"5.8"` or the app disconnects.

```json
{
  "upload_path": "<from NVS>",
  "firmware_version": "5.8.0",
  "battery_level": 85,
  "device_id": "JX_XXXXXX",
  "alert": "",
  "product": "Juxta5-8",
  "log_schema": "jxta-nor-csv-v4",
  "logging_version": 4,
  "experiment": "<from NVS>",
  "subject_id": "<from NVS>",
  "adv_interval": 5,
  "scan_interval": 20,
  "inactivity_doubler": false
}
```

| Key                  | Type    | App behavior                                                                 |
| -------------------- | ------- | ---------------------------------------------------------------------------- |
| `firmware_version`   | string  | Must start with `"5.8"`; otherwise the app disconnects with an alert.        |
| `battery_level`      | int     | Shown in connected header.                                                   |
| `memory_level`       | int     | Shown in connected header (optional; only displayed if present).             |
| `device_id`          | string  | Used as the device folder name for stored packages and logged on connect.    |
| `subject_id`         | string  | Populates the Subject ID field in Settings.                                  |
| `experiment`         | string  | Populates the Experiment field in Settings.                                  |
| `adv_interval`       | int     | Populates the Advertising Interval slider (clamped 1–10s).                   |
| `scan_interval`      | int     | Populates the Scanning Interval slider (clamped 5–60s, step 5).              |
| `inactivity_doubler` | bool    | Populates the "Double during inactivity" toggle.                             |
| other keys           | any     | Ignored.                                                                     |

### Gateway Characteristic Payload (WRITE)

All gateway commands use **snake_case** keys, matching the node payload. Settings writes omit `experiment` when empty.

```json
{
  "timestamp": 1717003200,
  "send_filenames": true,
  "clear_memory": true,
  "reset": true,
  "subject_id": "001",
  "experiment": "trial-A",
  "adv_interval": 5,
  "scan_interval": 20,
  "inactivity_doubler": false
}
```

| Key                  | Type    | Notes                                                                            |
| -------------------- | ------- | -------------------------------------------------------------------------------- |
| `timestamp`          | int     | Unix epoch seconds, sent automatically after firmware validation.                |
| `send_filenames`     | bool    | Asks the device to return its file listing.                                      |
| `clear_memory`       | bool    | Wipes device storage; confirmed via UI alert.                                    |
| `reset`              | bool    | "Shelf Mode" — gracefully reset the device.                                      |
| `subject_id`         | string  | Always sent on Push; whitespace-trimmed.                                         |
| `experiment`         | string  | Sent only when non-empty after trimming.                                         |
| `adv_interval`       | int     | 1–10s, step 1.                                                                   |
| `scan_interval`      | int     | 5–60s, step 5.                                                                   |
| `inactivity_doubler` | bool    | Doubles intervals during periods of inactivity.                                  |

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
2. Update `peripheral(_:didUpdateValueFor:)` in `ContentView.swift` (node parsing).
3. Update `BLEManager.saveSettings()` / `clearMemory()` / `sendFilenamesRequest()` / `resetToShelfMode()` (gateway writes).
4. Communicate the change to the firmware developer so the node side matches.

## Firmware update (DFU)

Voleo does not flash firmware. To update a device:

1. Use the magnet gesture to enter DFU mode (see the **Info** tab in the app for the magnet/LED reference).
2. Use Nordic Semiconductor's **nRF Connect** app to flash a firmware image supplied by the developer.

## Development

Voleo is intended for developers and operators working with Juxta 5.8+ devices. The Terminal tab provides full BLE-level visibility for debugging, and the Info tab surfaces the build number (`CFBundleShortVersionString` + `CFBundleVersion`) for support reports.

## License

[Add your license information here]
