# Voleo (iOS)

Companion app for Juxta 5.8+ wearable devices and Hublink gateways. Connect over Bluetooth Low Energy, sync session settings, transfer daily data packages, and inspect logs — all from your iPhone.

Developed by the [Neurotech Hub](https://neurotechhub.wustl.edu) at Washington University in St. Louis.

## Overview

Voleo is the iOS companion for Juxta 5.8+ nodes and gateway-style base stations. It reads the node (camelCase JSON), writes session settings over the gateway (camelCase JSON, UTC `timestamp`), discovers daily files on the device, and pulls them down as locally stored CSV **Daily Packages** you can browse, plot, share, and copy long after disconnecting.

For the full BLE protocol (characteristics, file listing, transfer flow), see [`spec_HUBLINK.md`](spec_HUBLINK.md).

## Features

- **BLE scan & connect** — filtered by the Hublink service UUID; peripherals advertise as `JX_*`
- **Firmware** — reads `firmwareVersion` from the node; a strict 5.8-only disconnect gate exists in code but is **disabled** in current builds
- **Wearable vs base station** — if the node JSON includes all Device Settings fields (`subjectId`, `experiment`, `advInterval`, `scanInterval`, `inactivityMultiplier`), the inline **Device Settings** card is shown; otherwise Voleo treats the connection as a **base station** (banner only, no settings card) and still runs the session handshake and file transfer
- **Session settings sync** — Subject ID, Experiment, advertising interval, scanning interval, inactivity scan multiplier; values are read from the node on connect and pushed back from the Device Settings card (wearables only)
- **Daily Packages** — groups `JXV` / `JXS` / `JXB` + `YYYYMMDD` CSV files for a day, transfers all three in sequence, and stores them under `Documents/<device_id>/`
- **Packages tab** — browse all local packages **grouped by device**; devices are ordered by most recently transferred package (file modification time), then by calendar date; each package row shows date, V/S/B file badges, and completeness
- **Package detail** — truncated raw CSV preview per file; **View Plots** (Vitals / BLE Activity), **View All** (Settings — full CSV in the same preview style), **Copy All**, **Share**
- **Plots** — Vitals: battery voltage, temperature, optional **lux** and **motion** when those columns exist; BLE Activity: peer vs time (point color = RSSI). CSV parsing tolerates UTF-8 BOM, CRLF, and common export whitespace (typical of SD-card copies)
- **Terminal tab** — full BLE log with copy / clear
- **Info tab** — app version, DFU note (Nordic **nRF Connect** + developer-supplied firmware), magnet-gesture / LED reference
- **Visual connection cue** — while connected, the **Device** tab icon and label stay green (including on other tabs); battery glyph reflects reported percent when present

## Requirements

- iOS 17.0+
- Xcode 15.0+
- A physical Bluetooth-enabled iPhone (BLE does not work in the Simulator)
- A Juxta 5.8+ device or compatible Hublink gateway / base station

## Installation

1. Clone the repository.
2. Open `Juxta-Voleo-iOS.xcodeproj` in Xcode.
3. Confirm Bluetooth and Background Modes capabilities are configured for your team / signing setup.
4. Build & run the **Voleo-iOS** scheme on a physical device.

## Usage

### Scan & connect

- Open the **Device** tab and tap **Scan** to discover devices (service UUID below).
- Tap **Connect**. After service discovery, Voleo reads the node payload (camelCase JSON: battery, memory, firmware version, and optionally subject, experiment, intervals).
- **Wearable:** all Device Settings keys are present → settings card appears; edit and **Push** as needed.
- **Base station:** one or more settings keys are missing → **Detected Base Station Connection** banner; no Device Settings card; file listing and transfer still work.
- If the firmware 5.8 gate is re-enabled in a build and `firmwareVersion` does not start with `5.8`, Voleo may disconnect and show **Incompatible Voleo (v5.8) device**.

### Device Settings (wearables only)

- Edit Subject ID, Experiment, advertising interval (1–10 s, step 1), scanning interval (5–60 s, step 5), and the inactivity scan multiplier.
- Each interval has an **Off** toggle; when on, the slider is disabled and `0` is sent for that interval.
- Inactivity scan multiplier: segmented `1×…5×` (sent as `inactivityMultiplier`; `1×` effectively disables the multiplier on the node).
- **Push** writes values to the device. **Default** restores Adv `10 s`, Scan `10 s`, multiplier `5×`, clears both **Off** toggles on screen (still requires **Push** to send).

### Daily Packages (on device)

- The connected screen lists daily packages from the device file listing. Select a date and tap **Transfer Selected**; Voleo queues Vitals, Settings, and BLE Activity in turn.
- Transferred dates show a green checkmark for the session.
- Files are saved to `Documents/<device_id>/` and remain in the **Packages** tab offline.

### Packages tab (local library)

- Packages are grouped under each **device ID** (`JX_*` folder name).
- Within a device, packages are newest-first (by local file write time, then `YYYYMMDD` date key).
- Tap a package for detail: preview snippets, **View Plots**, **View All** (Settings), **Copy All**, **Share**, swipe-to-delete.

### Maintenance

- **Shelf Mode** — `{"reset": true}` on the gateway (confirmed).
- **Clear Memory** — `{"clearMemory": true}` on the gateway (confirmed).

### Terminal

The **Terminal** tab shows the full BLE log with copy and clear in the navigation bar.

## CSV file formats (plots & preview)

Voleo does not require every column below; plotting uses what is present. Headers are matched case-insensitively after trimming.

### Vitals — `JXV<YYYYMMDD>.csv`

| Column (typical)   | Used for                          |
| ------------------ | --------------------------------- |
| `unix`             | Required — X-axis time (epoch s)  |
| `batt_v`           | Battery voltage chart             |
| `temp_c`           | Temperature chart                 |
| `lux`              | Lux chart (only if column exists) |
| `motion`           | Motion chart (only if column exists) |
| `datetime`, `batt_per`, `humidity_pct`, `gas_kohm`, … | Shown in raw preview / **View All**; not plotted unless listed above |

Example (gateway / base station):

```csv
unix,datetime,batt_v,batt_per,lux,temp_c,humidity_pct,gas_kohm
1778790483,2026-05-14 20:28:03,0,0,0.06,28.78,24.84,8.37
```

### Settings — `JXS<YYYYMMDD>.csv`

Single-row or multi-row key/value CSV; opened via **View All** as full monospaced text (same 10 pt preview styling as the package screen, scrollable).

### BLE Activity — `JXB<YYYYMMDD>.csv`

| Column (typical) | Used for                                      |
| ---------------- | --------------------------------------------- |
| `unix`           | Required — X-axis time                        |
| `peer_id`        | Y-axis peer label (preferred)                 |
| `observer_id`    | Fallback peer label if `peer_id` is absent    |
| `rssi`           | Point color (RSSI legend on plot screen)      |

Example:

```csv
unix,observer_id,peer_id,rssi
1778790483,JX_BBB32D,JX_563E56,-56
```

## BLE Protocol

The app uses these UUIDs (see [`spec_HUBLINK.md`](spec_HUBLINK.md) for listing/transfer details):

| Role           | UUID                                   |
| -------------- | -------------------------------------- |
| Service        | `57617368-5501-0001-8000-00805f9b34fb` |
| Filename       | `57617368-5502-0001-8000-00805f9b34fb` |
| File Transfer  | `57617368-5503-0001-8000-00805f9b34fb` |
| Gateway        | `57617368-5504-0001-8000-00805f9b34fb` |
| Node           | `57617368-5505-0001-8000-00805f9b34fb` |

### Node characteristic (READ)

On connect the app reads the node characteristic and expects camelCase JSON. Keys used by the app:

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
| `firmwareVersion`       | string | Shown in header; optional 5.8 gate when enabled in code.                    |
| `batteryLevel`          | int    | Shown in connected header when present.                                     |
| `memoryLevel`           | int    | Shown in connected header when present.                                       |
| `deviceId`              | string | Logged on connect; local packages use the peripheral **name** as folder key. |
| `subjectId`             | string | Device Settings (required for “full” wearable node).                        |
| `experiment`            | string | Device Settings (required for “full” wearable node).                        |
| `advInterval`           | int    | Device Settings; `0` → **Off** for advertising.                             |
| `scanInterval`          | int    | Device Settings; `0` → **Off** for scanning.                                |
| `inactivityMultiplier`  | int    | Device Settings (1–5).                                                      |
| other keys              | any    | Ignored.                                                                    |

If any of `subjectId`, `experiment`, `advInterval`, `scanInterval`, or `inactivityMultiplier` is missing, Voleo classifies the device as a **base station** for UI purposes.

### Gateway characteristic (WRITE)

All gateway commands use camelCase keys. After a successful node read, the app sends **one** JSON object with UTC `timestamp` and `sendFilenames: true` to start the session. Settings writes omit `experiment` when empty.

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
| `reset`                  | bool | Shelf Mode — gracefully reset the device.                                       |
| `subjectId`              | str  | Always sent on Push; whitespace-trimmed.                                        |
| `experiment`             | str  | Sent only when non-empty after trimming.                                       |
| `advInterval`            | int  | 1–10 s, step 1. Sent as `0` when **Off**.                                      |
| `scanInterval`           | int  | 5–60 s, step 5. Sent as `0` when **Off**.                                       |
| `inactivityMultiplier`   | int  | Integer in `1…5`.                                                              |

### Daily packages on disk

```
Documents/<device_id>/
  JXV<YYYYMMDD>.csv   # Vitals
  JXS<YYYYMMDD>.csv   # Settings
  JXB<YYYYMMDD>.csv   # BLE Activity
```

The `<YYYYMMDD>` segment is the date key used to group the three files into one logical package. A package is **complete** when all three files are present.

### Schema sync checklist

If you change the JSON or CSV schema:

1. Update this README and [`spec_HUBLINK.md`](spec_HUBLINK.md).
2. Update node parsing and filename listing in `ContentView.swift` (`peripheral(_:didUpdateValueFor:)`, `processFilenameListingPayload`, `AppState.nodePayloadHasAllDeviceSettingsFields`).
3. Update gateway helpers in `BLEManager` (`writeGatewayJSONObject`, `saveSettings()`, `clearMemory()`, `resetToShelfMode()`, `sendTimestampAndFilenamesRequest()`).
4. Update plot column mapping in `PlotsView` / `parseCSV` if CSV columns change.
5. Align firmware / gateway firmware with the app team.

## Firmware update (DFU)

Voleo does not flash firmware. To update a device:

1. Use the magnet gesture to enter DFU mode (see the **Info** tab for the magnet/LED reference).
2. Use Nordic Semiconductor's **nRF Connect** app with a firmware image from the developer.

## Development

- Primary UI and BLE logic live in `Juxta-Voleo-iOS/ContentView.swift`.
- Protocol reference: [`spec_HUBLINK.md`](spec_HUBLINK.md).
- The **Terminal** tab provides BLE-level visibility; the **Info** tab shows `CFBundleShortVersionString` + `CFBundleVersion` for support reports.

## License

[Add your license information here]
