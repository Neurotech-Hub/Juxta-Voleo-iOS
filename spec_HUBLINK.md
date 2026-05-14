## BLE Characteristics & Protocol

To support "Hublink" BLE gateways that will scan and connect to our periperal, we require a custom BLE service with four characteristics for file transfer and device management. All characteristics use the service UUID: `57617368-5501-0001-8000-00805f9b34fb`. This peripheral shoud always have an advertising name of "JX_*" where "*" is the last size characters of this devices MAC address; this is considered the `deviceId` below.

Required characteristics:

### 1. Node Characteristic (READ)
**UUID**: `57617368-5505-0001-8000-00805f9b34fb`

Provides device status and configuration information in JSON format (**camelCase** keys):

```json
{
  "uploadPath": "/TEST",
  "firmwareVersion": "5.8.0",
  "batteryLevel": 85,
  "memoryLevel": 42,
  "deviceId": "JX_XXXXXX",
  "alert": "",
  "product": "Juxta5-8",
  "logSchema": "jxta-nor-csv-v4",
  "loggingVersion": 4,
  "experiment": "",
  "subjectId": "001",
  "advInterval": 5,
  "scanInterval": 20,
  "inactivityMultiplier": 2
}
```

**Fields** (camelCase):

- `uploadPath` (string): Base path for file uploads (from NVS)
- `firmwareVersion` (string): Current peripheral firmware version. Gateways may validate this (e.g. prefix `5.8`) before sending further gateway commands.
- `batteryLevel` (number): Battery level 0–100 percentage
- `memoryLevel` (number, optional): Memory use 0–100 percentage
- `deviceId` (string): Hardware device identifier (e.g. `JX_XXXXXX`)
- `alert` (string): Alert message (reserved for future use)
- `product` (string): Product identifier (e.g. `Juxta5-8`)
- `logSchema` (string): Log file schema identifier
- `loggingVersion` (number): Log schema version
- `experiment` (string): Experiment label (from NVS)
- `subjectId` (string): Subject identifier (from NVS)
- `advInterval` (integer): Advertising burst interval in seconds (`0` = off)
- `scanInterval` (integer): Scanning burst interval in seconds (`0` = off)
- `inactivityMultiplier` (integer): Multiplier applied to scan interval during inactivity (typically 1–5)

The gateway may safely ignore additional keys it does not recognize.

**Usage**: Gateway reads this characteristic immediately after connection. Gateways may validate `firmwareVersion` before sending any gateway commands; on mismatch they may disconnect and alert the user.

### 2. Gateway Characteristic (WRITE)
**UUID**: `57617368-5504-0001-8000-00805f9b34fb`

Accepts JSON commands to control device behavior (**camelCase** keys). Multiple commands can be sent in a single JSON object:

```json
{
  "timestamp": 1234567890,
  "sendFilenames": true,
  "clearMemory": true,
  "advInterval": 5,
  "scanInterval": 15,
  "inactivityMultiplier": 2,
  "subjectId": "001",
  "experiment": "trial-A",
  "reset": true
}
```

This implementation is unique from other nodes that have an internal memory card where `subjectId` and `experiment` would be manually set/written. Here, we rely on the BLE connection to push these values to NVS.

**Commands**:

**System Commands**:

- `timestamp` (number): Unix **UTC** epoch seconds for device synchronization (required for operation)
- `sendFilenames` (boolean): Triggers file listing process when true
- `clearMemory` (boolean): Clears device memory when true
- `reset` (boolean): Gracefully disconnects and reboots device when true

**Session Configuration**:

- `advInterval` (integer): Advertising burst interval in seconds (0 = no advertising)
- `scanInterval` (integer): Scanning burst interval in seconds (0 = no scanning)
- `inactivityMultiplier` (integer): Multiplier applied to the scan interval during inactivity (typically 1–5; `1` effectively disables the multiplier)

**Persistent Configuration** (saved to NVS):

- `subjectId` (string): Subject identifier for data files. Populated from the node on connect; gateway sends whatever the user has in the field at save time.
- `experiment` (string): Experiment label. Populated from the node on connect; omitted from the gateway payload when empty.

**Usage**: Write JSON commands to control device behavior. Device responds via callbacks.

### 3. Filename Characteristic (READ/WRITE/INDICATE)
**UUID**: `57617368-5502-0001-8000-00805f9b34fb`

**WRITE**: This characteristic will receive a filename as a request for file transfer:

```
"data.txt"
```

**INDICATE**: Receives file listing or transfer status

- **File listing format**: `"filename1.txt|1234;filename2.csv|5678;EOF"` (may arrive in multiple indications; clients should buffer until `EOF`)
  - Each file: `"filename|filesize"`
  - Separator: `;`
  - End marker: `"EOF"` — may appear **inside** the last segment (e.g. `…;EOF`) or as a **separate** final indication after the `name|size` segments (listing body may omit the literal substring `EOF`)
  - Only names matching the daily CSV pattern (`JX…YYYYMMDD.csv`) are grouped into packages; other names in the listing are ignored for that UI
- **Transfer status**: `"NFF"` (No File Found) if requested file doesn't exist

**Usage**:

1. Write filename to request transfer
2. Subscribe to indications for file listing or status updates

### 4. File Transfer Characteristic (READ/INDICATE)
**UUID**: `57617368-5503-0001-8000-00805f9b34fb`

**INDICATE**: Sends file content in chunks

- **Data chunks**: UTF-8 text (MTU-sized, typically 512 bytes). Chunks are appended verbatim into a single human-readable file body.
- **End marker**: `"EOF"` when transfer complete
- **Error marker**: `"NFF"` if file not found

**Usage**: Subscribe to indications to receive file content. Monitor for "EOF" or "NFF" markers.

## Connection Protocol

### 1. Device Discovery

- **Service UUID**: `57617368-5501-0001-8000-00805f9b34fb`
- **Advertising Name**: "JX_*"
- **MTU Size**: Device negotiates to 515 bytes (512 + 3 byte header)

### 2. Connection Sequence

1. **Connect** to device
2. **Read Node Characteristic** to get current device status and configuration (camelCase JSON)
3. **Validate firmware** (optional gateway policy): e.g. `firmwareVersion` must start with `"5.8"`; otherwise the gateway may disconnect and alert the user before any further traffic
4. **Subscribe to indications** on Filename and File Transfer characteristics
5. **Gateway write**: synchronize time and request file listing — typically **one** JSON object, e.g. `{"timestamp": <UTC epoch int>, "sendFilenames": true}`
6. **Configure device** via further Gateway writes as needed (`advInterval`, `scanInterval`, `inactivityMultiplier`, `subjectId`, `experiment`)
7. **Perform file operations** (listing, transfer) as needed

### 3. Device Configuration Example

```json
{
  "timestamp": 1234567890,
  "advInterval": 10,
  "scanInterval": 30,
  "inactivityMultiplier": 2,
  "subjectId": "001",
  "experiment": "trial-A"
}
```

The `experiment` field is omitted by the gateway when empty.

### 4. File Transfer Workflow

#### File Listing

1. Gateway writes a JSON object that includes `"sendFilenames": true` (often combined with `"timestamp"` in the same write).
2. Gateway receives file list via Filename Characteristic indications in format: `"filename|size;filename2|size2;EOF"` (possibly split across multiple indications).
3. Gateway decides what files are required for download.

#### File Download

1. Filename is written to Filename Characteristic
2. Gateway receives file content via File Transfer Characteristic indications
3. Gateway monitors for "EOF" or "NFF" markers

### 5. Other Details

- Timeout: None for now, but this device must handle any disconnection gracefully (automatic cleanup) via callbacks and state management

- Error Handling
- **File not found**: Device sends "NFF" via Filename Characteristic
- **Transfer errors**: Device disconnects and resets state

- State Management
- **Alert messages**: Auto-clear after each sync cycle
- **Battery level**: Persists until next update
- **BLE state**: Reset between cycles; Node Characteristic is ideally updated with proper information
