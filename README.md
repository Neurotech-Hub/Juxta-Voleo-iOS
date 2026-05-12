# HublinkGateway iOS

A Bluetooth Low Energy (BLE) gateway application for iOS that enables communication with Hublink devices for file transfer and data management.

## Overview

HublinkGateway is a developer-focused iOS app that replicates core functionality from a Raspberry Pi-based gateway system. It provides a clean, efficient interface for discovering, connecting to, and managing Hublink devices over BLE.

## Features

- **BLE Device Discovery** - Scan for Hublink devices using custom service UUID
- **Device Connection** - Connect to discovered devices with automatic service discovery
- **Manual Controls** - Send timestamp, request filenames, and clear device memory
- **File Transfer** - Request and receive files from connected devices
- **Real-time Terminal** - View all BLE communication with timestamps
- **File Content Display** - Hex view of received file data with copy functionality
- **Auto-cleanup** - Device list automatically clears after 30 seconds of inactivity

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Bluetooth-enabled device
- Hublink-compatible peripheral devices

## Installation

1. Clone the repository
2. Open `HublinkGateway-iOS.xcodeproj` in Xcode
3. Configure Bluetooth permissions in project settings
4. Build and run on device (BLE requires physical device)

## Usage

### Scanning for Devices
- Tap "Scan" to discover nearby Hublink devices
- Devices are filtered by the Hublink service UUID
- Scan automatically stops after 10 seconds

### Connecting to Devices
- Tap "Connect" on any discovered device
- App automatically discovers Hublink characteristics
- Connection status is displayed in the header

### Manual Operations
- **Timestamp** - Send current timestamp to device
- **Get Files** - Request list of available files
- **Clear Memory** - Clear device memory (requires double confirmation)
- **Request File** - Enter filename and request file transfer

### File Management
- Received file content is displayed as hexadecimal
- Copy button to copy file content to clipboard
- Clear button to clear the display area

## BLE Protocol

The app communicates using custom Hublink UUIDs:
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
| `subject_id`         | string  | Always sent on Save; whitespace-trimmed.                                         |
| `experiment`         | string  | Sent only when non-empty after trimming.                                         |
| `adv_interval`       | int     | 1–10s, step 1.                                                                   |
| `scan_interval`      | int     | 5–60s, step 5.                                                                   |
| `inactivity_doubler` | bool    | Doubles intervals during periods of inactivity.                                  |

### Schema sync checklist

If you change the JSON schema in either direction:

1. Update this README (the node and gateway tables above).
2. Update `peripheral(_:didUpdateValueFor:)` in `ContentView.swift` (node parsing).
3. Update `BLEManager.saveSettings()` / `clearMemory()` / `sendFilenamesRequest()` / `resetToShelfMode()` (gateway writes).
4. Communicate the change to the firmware developer so the node side matches.

## Development

This app is designed for developers working with Hublink devices. The terminal provides real-time feedback for debugging BLE communication, and the interface is optimized for development workflows.

## License

[Add your license information here]
