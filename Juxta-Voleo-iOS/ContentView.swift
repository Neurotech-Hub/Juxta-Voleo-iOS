//
//  ContentView.swift
//  Juxta-Voleo-iOS
//
//  Created by Matt Gaidica on 8/11/25.
//

import SwiftUI
import UIKit
import CoreBluetooth
import UniformTypeIdentifiers
import Charts

// MARK: - BLE UUIDs
struct HublinkUUIDs {
    static let service = CBUUID(string: "57617368-5501-0001-8000-00805f9b34fb")
    static let filename = CBUUID(string: "57617368-5502-0001-8000-00805f9b34fb")
    static let fileTransfer = CBUUID(string: "57617368-5503-0001-8000-00805f9b34fb")
    static let gateway = CBUUID(string: "57617368-5504-0001-8000-00805f9b34fb")
    static let node = CBUUID(string: "57617368-5505-0001-8000-00805f9b34fb")
}

// MARK: - Device Info
struct DiscoveredDevice: Identifiable {
    let id = UUID()
    let peripheral: CBPeripheral
    var rssi: Int?
    
    var name: String? {
        return peripheral.name
    }
}

// MARK: - Daily Package Model
struct DailyPackage: Identifiable {
    let id = UUID()
    let dateKey: String      // e.g. "20260507"
    let deviceID: String     // e.g. "JX_XXXXXX"
    var files: [String: URL] // filename -> local URL
    /// Latest `contentModificationDate` among local CSVs; used for ordering because `dateKey` is day-only.
    let lastFileWriteAt: Date

    init(dateKey: String, deviceID: String, files: [String: URL] = [:], lastFileWriteAt: Date = .distantPast) {
        self.dateKey = dateKey
        self.deviceID = deviceID
        self.files = files
        self.lastFileWriteAt = lastFileWriteAt
    }

    /// Strongest signal for “most recently transferred” on this device; falls back to local noon on `dateKey` when mtimes are unavailable (e.g. in-memory listing paths).
    static func resolvedLastFileWriteAt(files: [String: URL], dateKey: String) -> Date {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var best = Date.distantPast
        for (_, url) in files {
            guard let vals = try? url.resourceValues(forKeys: keys),
                  let d = vals.contentModificationDate else { continue }
            if d > best { best = d }
        }
        if best > .distantPast { return best }
        return noonOnDateKey(dateKey) ?? .distantPast
    }

    private static func noonOnDateKey(_ key: String) -> Date? {
        guard key.count == 8, key.allSatisfy({ $0.isNumber }) else { return nil }
        guard let y = Int(key.prefix(4)),
              let m = Int(key.dropFirst(4).prefix(2)),
              let d = Int(key.suffix(2)) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12, minute: 0, second: 0))
    }

    var displayDate: String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyyMMdd"
        if let date = inputFormatter.date(from: dateKey) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateStyle = .long
            return outputFormatter.string(from: date)
        }
        return dateKey
    }

    var vitalsURL: URL?    { files.first(where: { $0.key.hasPrefix("JXV") })?.value }
    var settingsURL: URL?  { files.first(where: { $0.key.hasPrefix("JXS") })?.value }
    var bleURL: URL?       { files.first(where: { $0.key.hasPrefix("JXB") })?.value }
    var isComplete: Bool   { vitalsURL != nil && settingsURL != nil && bleURL != nil }
    var fileCount: Int     { files.count }
}

// MARK: - Package Store
class PackageStore: ObservableObject {
    @Published var packages: [DailyPackage] = []

    enum StoreError: Error { case noDocumentsDirectory }

    init() { refresh() }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            var deviceMap: [String: [String: DailyPackage]] = [:]
            let fm = FileManager.default
            guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

            let deviceDirs = (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            for deviceDir in deviceDirs {
                let isDir = (try? deviceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let deviceID = deviceDir.lastPathComponent
                guard deviceID.hasPrefix("JX_") else { continue }

                let csvFiles = (try? fm.contentsOfDirectory(at: deviceDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                for fileURL in csvFiles {
                    let name = fileURL.lastPathComponent
                    guard let key = Self.dateKey(from: name) else { continue }
                    if deviceMap[deviceID] == nil { deviceMap[deviceID] = [:] }
                    if deviceMap[deviceID]![key] == nil {
                        deviceMap[deviceID]![key] = DailyPackage(dateKey: key, deviceID: deviceID, files: [:])
                    }
                    deviceMap[deviceID]![key]!.files[name] = fileURL
                }
            }

            var result: [DailyPackage] = []
            for (deviceID, dateMap) in deviceMap {
                for (key, pkg) in dateMap {
                    let writeAt = DailyPackage.resolvedLastFileWriteAt(files: pkg.files, dateKey: key)
                    result.append(DailyPackage(dateKey: key, deviceID: deviceID, files: pkg.files, lastFileWriteAt: writeAt))
                }
            }
            result.sort {
                if $0.lastFileWriteAt != $1.lastFileWriteAt { return $0.lastFileWriteAt > $1.lastFileWriteAt }
                if $0.dateKey != $1.dateKey { return $0.dateKey > $1.dateKey }
                return $0.deviceID > $1.deviceID
            }

            DispatchQueue.main.async { self.packages = result }
        }
    }

    @discardableResult
    func save(filename: String, content: String, deviceID: String) throws -> URL {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.noDocumentsDirectory
        }
        let deviceDir = docs.appendingPathComponent(deviceID)
        try fm.createDirectory(at: deviceDir, withIntermediateDirectories: true)
        let fileURL = deviceDir.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func delete(_ package: DailyPackage) {
        let fm = FileManager.default
        for (_, url) in package.files { try? fm.removeItem(at: url) }
        refresh()
    }

    static func dateKey(from filename: String) -> String? {
        // "JXV20260507.csv" -> "20260507"
        guard filename.hasPrefix("JX"),
              filename.count >= 14,
              filename.hasSuffix(".csv") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: 3)
        let end = filename.index(start, offsetBy: 8, limitedBy: filename.endIndex) ?? filename.endIndex
        let key = String(filename[start..<end])
        guard key.count == 8, key.allSatisfy({ $0.isNumber }) else { return nil }
        return key
    }
}

// MARK: - App State
class AppState: ObservableObject {
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var connectedDeviceRSSI: Int = 0
    @Published var terminalLog: [String] = []
    @Published var connectionStatus = "Ready"
    @Published var availablePackages: [DailyPackage] = []
    @Published var selectedPackageDate: String = ""
    @Published var isTransferringPackage = false
    @Published var transferProgress = ""
    @Published var showClearMemoryAlert = false
    @Published var showShelfModeAlert = false
    @Published var showDefaultSettingsAlert = false
    @Published var showIncompatibleFirmwareAlert = false
    @Published var currentTime = ""
    @Published var batteryLevel: Int? = nil
    @Published var transferredDateKeys: Set<String> = []
    @Published var pushFeedback: String = ""
    @Published var showShelfDisconnectOverlay = false
    /// True only after the node JSON includes every field required for the Device Settings card.
    @Published var hasFullNodeDeviceSettings = false
    /// 5.8 node without full device-settings fields (e.g. base station) — hide Device Settings and show a banner instead.
    @Published var isBaseStationConnection = false

    private var shelfDisconnectTimeoutWorkItem: DispatchWorkItem?
    fileprivate var didLogBaseStationNotice = false

    /// After "Reset to Shelf Mode", the node disconnects shortly; mask the stale connected UI until `didDisconnect` or timeout.
    func beginShelfDisconnectAwait() {
        shelfDisconnectTimeoutWorkItem?.cancel()
        showShelfDisconnectOverlay = true
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.showShelfDisconnectOverlay {
                self.showShelfDisconnectOverlay = false
                self.log("WARN: Shelf mode — no disconnect within 10s; dismissed overlay")
            }
        }
        shelfDisconnectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func endShelfDisconnectAwait() {
        shelfDisconnectTimeoutWorkItem?.cancel()
        shelfDisconnectTimeoutWorkItem = nil
        showShelfDisconnectOverlay = false
    }

    func resetSettingsToDefaults() {
        advInterval = 10
        scanInterval = 10
        advOff = false
        scanOff = false
        inactivityMultiplier = 5
        log("Settings reset to defaults")
    }
    @Published var memoryLevel: Int? = nil
    @Published var firmwareVersion: String? = nil

    // Session settings (populated from node on connect)
    @Published var subjectID: String = ""
    @Published var experiment: String = ""
    @Published var advInterval = 10
    @Published var scanInterval = 10
    @Published var advOff = false
    @Published var scanOff = false
    /// Multiplier applied to the scan interval during inactivity. Sent on the gateway as `inactivityMultiplier`.
    /// Valid options: 1, 2, 3, 4, 5 (1 = effectively disabled).
    @Published var inactivityMultiplier = 5

    /// Snapshot of settings as they exist on the connected device (after node read or successful Push).
    /// Compared against the live values to detect unsaved edits.
    private struct SettingsSnapshot: Equatable {
        var subjectID: String
        var experiment: String
        var advInterval: Int
        var scanInterval: Int
        var advOff: Bool
        var scanOff: Bool
        var inactivityMultiplier: Int
    }
    @Published private var settingsBaseline: SettingsSnapshot? = nil

    func captureSettingsBaseline() {
        settingsBaseline = SettingsSnapshot(
            subjectID: subjectID,
            experiment: experiment,
            advInterval: advInterval,
            scanInterval: scanInterval,
            advOff: advOff,
            scanOff: scanOff,
            inactivityMultiplier: inactivityMultiplier
        )
    }

    func clearSettingsBaseline() {
        settingsBaseline = nil
    }

    func resetNodeDeviceSettingsAvailability() {
        hasFullNodeDeviceSettings = false
        isBaseStationConnection = false
        didLogBaseStationNotice = false
    }

    /// Device Settings UI requires these camelCase keys (with matching types) in the node characteristic JSON.
    fileprivate static func nodePayloadHasAllDeviceSettingsFields(_ json: [String: Any]) -> Bool {
        guard json["subjectId"] as? String != nil else { return false }
        guard json["experiment"] as? String != nil else { return false }
        guard json["advInterval"] as? Int != nil else { return false }
        guard json["scanInterval"] as? Int != nil else { return false }
        guard json["inactivityMultiplier"] as? Int != nil else { return false }
        return true
    }

    var hasUnsavedSettings: Bool {
        guard let baseline = settingsBaseline else { return false }
        let current = SettingsSnapshot(
            subjectID: subjectID,
            experiment: experiment,
            advInterval: advInterval,
            scanInterval: scanInterval,
            advOff: advOff,
            scanOff: scanOff,
            inactivityMultiplier: inactivityMultiplier
        )
        return current != baseline
    }
    
    private var clearDevicesTimer: Timer?
    private var clockTimer: Timer?
    private var rssiTimer: Timer?
    
    func log(_ message: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        terminalLog.append("[\(timestamp)] \(message)")
        if terminalLog.count > 1000 {
            terminalLog.removeFirst(100)
        }
    }
    
    func clearLog() {
        terminalLog.removeAll()
    }
    
    
    func scheduleClearDevices() {
        // Cancel existing timer
        clearDevicesTimer?.invalidate()
        
        // Schedule new timer to clear devices after 30 seconds
        clearDevicesTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.discoveredDevices.removeAll()
            }
        }
        RunLoop.main.add(clearDevicesTimer!, forMode: .common)
    }
    
    func cancelClearDevices() {
        clearDevicesTimer?.invalidate()
        clearDevicesTimer = nil
    }

    func startClock() {
        updateTime()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateTime()
        }
    }
    
    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }
    
    func startRSSIMonitoring(bleManager: BLEManager) {
        stopRSSIMonitoring()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            bleManager.readRSSI()
        }
    }
    
    func stopRSSIMonitoring() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }
    
    private func updateTime() {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yy • HH:mm:ss"
        currentTime = formatter.string(from: Date())
    }
}

// MARK: - BLE Manager
class BLEManager: NSObject, ObservableObject {
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var filenameCharacteristic: CBCharacteristic?
    private var fileTransferCharacteristic: CBCharacteristic?
    private var gatewayCharacteristic: CBCharacteristic?
    private var nodeCharacteristic: CBCharacteristic?

    @Published var appState: AppState
    private var packageStore: PackageStore
    private var filesToTransfer: [String] = []
    private var currentFileIndex = 0
    private var currentTransferFilename = ""
    private var currentTransferDeviceID = ""
    private var currentTransferDateKey = ""
    private var stagingContent = ""
    private var sessionHandshakeStarted = false
    /// Accumulates filename-characteristic indications until listing is complete (`EOF` / full `…;EOF` frame).
    private var filenameListingBuffer = ""

    init(appState: AppState, packageStore: PackageStore) {
        self.appState = appState
        self.packageStore = packageStore
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startScanning() {
        guard let centralManager = centralManager,
              centralManager.state == .poweredOn else {
            appState.log("ERROR: Bluetooth not available - State: \(centralManager?.state.rawValue ?? -1)")
            return
        }
        
        appState.isScanning = true
        appState.discoveredDevices.removeAll()
        appState.cancelClearDevices() // Cancel any pending clear timer
        appState.log("Starting BLE scan for service: \(HublinkUUIDs.service.uuidString)")
        
        centralManager.scanForPeripherals(
            withServices: [HublinkUUIDs.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        
        // Stop scanning after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.stopScanning()
        }
    }
    
    func stopScanning() {
        centralManager?.stopScan()
        appState.isScanning = false
        appState.log("Scan stopped")
        appState.scheduleClearDevices()
    }
    
    func connect(to peripheral: CBPeripheral) {
        appState.log("Connecting to \(peripheral.name ?? "Unknown")...")
        centralManager?.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    func forceDisconnect() {
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    @discardableResult
    private func writeGatewayJSONObject(_ object: [String: Any]) -> Bool {
        guard let characteristic = gatewayCharacteristic else {
            appState.log("ERROR: Gateway characteristic not available")
            return false
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let payload = String(data: jsonData, encoding: .utf8) else {
                appState.log("ERROR: Gateway JSON UTF-8 encode failed")
                return false
            }
            connectedPeripheral?.writeValue(jsonData, for: characteristic, type: .withResponse)
            appState.log("SENT: \(payload)")
            return true
        } catch {
            appState.log("ERROR: Failed to serialize gateway JSON - \(error.localizedDescription)")
            return false
        }
    }

    private func sendTimestampAndFilenamesRequest() {
        let timestamp = Int(Date().timeIntervalSince1970)
        writeGatewayJSONObject([
            "timestamp": timestamp,
            "sendFilenames": true
        ])
    }

    func clearMemory() {
        guard gatewayCharacteristic != nil else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        guard writeGatewayJSONObject(["clearMemory": true]) else { return }
        DispatchQueue.main.async {
            self.appState.memoryLevel = 0
            self.appState.availablePackages = []
            self.appState.selectedPackageDate = ""
            self.appState.isTransferringPackage = false
            self.appState.transferProgress = ""
            self.appState.log("Device memory cleared")
        }
    }

    func resetToShelfMode() {
        guard gatewayCharacteristic != nil else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        _ = writeGatewayJSONObject(["reset": true])
    }
    
    func readRSSI() {
        guard let peripheral = connectedPeripheral else { return }
        peripheral.readRSSI()
    }
    
    func readNodeCharacteristic() {
        guard let characteristic = nodeCharacteristic else {
            appState.log("ERROR: Node characteristic not available")
            return
        }
        
        connectedPeripheral?.readValue(for: characteristic)
        appState.log("Reading node characteristic for device info...")
    }
    
    func saveSettings() {
        guard gatewayCharacteristic != nil else {
            appState.log("ERROR: Gateway characteristic not available")
            return
        }
        guard appState.hasFullNodeDeviceSettings else {
            appState.log("ERROR: Push skipped — node has not reported full device settings")
            return
        }

        let trimmedSubject = appState.subjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.subjectID = trimmedSubject

        var command: [String: Any] = [
            "subjectId": trimmedSubject,
            "advInterval": appState.advOff ? 0 : appState.advInterval,
            "scanInterval": appState.scanOff ? 0 : appState.scanInterval,
            "inactivityMultiplier": max(1, min(5, appState.inactivityMultiplier))
        ]

        let trimmedExperiment = appState.experiment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExperiment.isEmpty {
            command["experiment"] = trimmedExperiment
        }

        if writeGatewayJSONObject(command) {
            appState.pushFeedback = "Pushed"
            appState.captureSettingsBaseline()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak appState] in
                appState?.pushFeedback = ""
            }
        }
    }
    
    func requestFilenames() {
        guard let characteristic = filenameCharacteristic else {
            appState.log("ERROR: Filename characteristic not available")
            return
        }
        
        let payload = "request"
        if let data = payload.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
            appState.log("SENT: Request filenames")
        }
    }
    
    func startPackageTransfer(dateKey: String, deviceID: String) {
        guard filenameCharacteristic != nil else {
            appState.log("ERROR: Filename characteristic not available")
            return
        }

        let candidates = ["JXV\(dateKey).csv", "JXS\(dateKey).csv", "JXB\(dateKey).csv"]
        let deviceFiles = Set(appState.availablePackages
            .filter { $0.deviceID == deviceID && $0.dateKey == dateKey }
            .flatMap { $0.files.keys })

        filesToTransfer = candidates.filter { deviceFiles.contains($0) }
        guard !filesToTransfer.isEmpty else {
            appState.log("ERROR: No files found for package \(dateKey)")
            return
        }

        currentFileIndex = 0
        currentTransferDeviceID = deviceID
        currentTransferDateKey = dateKey
        stagingContent = ""
        appState.isTransferringPackage = true
        appState.transferProgress = "Preparing transfer…"
        transferNextFile()
    }

    private func transferNextFile() {
        guard currentFileIndex < filesToTransfer.count else {
            appState.isTransferringPackage = false
            appState.transferProgress = "Transfer complete (\(filesToTransfer.count) file\(filesToTransfer.count == 1 ? "" : "s"))"
            appState.log("✓ Package transfer complete (\(filesToTransfer.count) files)")
            if !currentTransferDateKey.isEmpty {
                appState.transferredDateKeys.insert(currentTransferDateKey)
            }
            packageStore.refresh()
            return
        }

        let filename = filesToTransfer[currentFileIndex]
        currentTransferFilename = filename
        stagingContent = ""

        appState.transferProgress = "Transferring \(currentFileIndex + 1)/\(filesToTransfer.count): \(filename)"
        appState.log("Transferring \(currentFileIndex + 1)/\(filesToTransfer.count): \(filename)")

        guard let characteristic = filenameCharacteristic else {
            appState.log("ERROR: Filename characteristic not available")
            appState.isTransferringPackage = false
            return
        }

        if let data = filename.data(using: .utf8) {
            connectedPeripheral?.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func completeCurrentFileTransfer() {
        if !currentTransferFilename.isEmpty && !stagingContent.isEmpty {
            do {
                try packageStore.save(filename: currentTransferFilename,
                                      content: stagingContent,
                                      deviceID: currentTransferDeviceID)
                appState.log("✓ Saved '\(currentTransferFilename)' (\(stagingContent.count) chars)")
            } catch {
                appState.log("ERROR: Could not save '\(currentTransferFilename)': \(error.localizedDescription)")
            }
        }
        currentFileIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.transferNextFile() }
    }
    
    private func checkAndReadNode() {
        guard gatewayCharacteristic != nil, nodeCharacteristic != nil else {
            return
        }
        readNodeCharacteristic()
    }

    private func startSessionHandshake() {
        guard !sessionHandshakeStarted else { return }
        sessionHandshakeStarted = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendTimestampAndFilenamesRequest()
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appState.log("Bluetooth ready")
        case .poweredOff:
            appState.log("ERROR: Bluetooth powered off")
        case .unauthorized:
            appState.log("ERROR: Bluetooth unauthorized")
        case .unsupported:
            appState.log("ERROR: Bluetooth unsupported")
        default:
            appState.log("ERROR: Bluetooth state: \(central.state.rawValue)")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssiValue = RSSI.intValue
        
        if let name = peripheral.name {
            if let existingIndex = appState.discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
                // Update existing device with new RSSI
                appState.discoveredDevices[existingIndex].rssi = rssiValue
            } else {
                // Add new device
                let discoveredDevice = DiscoveredDevice(peripheral: peripheral, rssi: rssiValue)
                appState.discoveredDevices.append(discoveredDevice)
                appState.log("DISCOVERED: \(name) (RSSI: \(rssiValue))")
            }
        } else {
            if let existingIndex = appState.discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
                // Update existing device with new RSSI
                appState.discoveredDevices[existingIndex].rssi = rssiValue
            } else {
                // Add new device
                let discoveredDevice = DiscoveredDevice(peripheral: peripheral, rssi: rssiValue)
                appState.discoveredDevices.append(discoveredDevice)
                appState.log("DISCOVERED: Unnamed device \(peripheral.identifier.uuidString) (RSSI: \(rssiValue))")
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Stop scanning when we connect
        stopScanning()
        
        appState.isConnected = true
        appState.connectedDevice = peripheral
        appState.connectionStatus = peripheral.name ?? "Unknown"
        appState.log("CONNECTED: \(peripheral.name ?? "Unknown")")
        
        stagingContent = ""
        sessionHandshakeStarted = false
        filenameListingBuffer = ""
        appState.transferredDateKeys.removeAll()
        appState.clearSettingsBaseline()
        appState.resetNodeDeviceSettingsAvailability()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([HublinkUUIDs.service])
        
        // Start RSSI monitoring
        appState.startRSSIMonitoring(bleManager: self)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        appState.log("ERROR: Failed to connect - \(error?.localizedDescription ?? "Unknown error")")
        appState.connectionStatus = "Connection failed"
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        appState.endShelfDisconnectAwait()
        appState.isConnected = false
        appState.connectedDevice = nil
        appState.connectionStatus = "Disconnected"
        
        if let error = error {
            appState.log("DISCONNECTED: \(peripheral.name ?? "Unknown") - Error: \(error.localizedDescription)")
        } else {
            appState.log("DISCONNECTED: \(peripheral.name ?? "Unknown") - Device disconnected")
        }
        
        // Clear connected state
        connectedPeripheral = nil
        filenameCharacteristic = nil
        fileTransferCharacteristic = nil
        gatewayCharacteristic = nil
        nodeCharacteristic = nil
        sessionHandshakeStarted = false
        filenameListingBuffer = ""
        stagingContent = ""
        
        // Clear any pending timers
        appState.cancelClearDevices()
        appState.stopRSSIMonitoring()
        
        appState.availablePackages = []
        appState.selectedPackageDate = ""
        appState.isTransferringPackage = false
        appState.transferProgress = ""
        appState.transferredDateKeys.removeAll()

        appState.connectedDeviceRSSI = 0
        appState.batteryLevel = nil
        appState.memoryLevel = nil
        appState.firmwareVersion = nil
        appState.clearSettingsBaseline()
        appState.resetNodeDeviceSettingsAvailability()
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    /// Avoid flooding the terminal with megabytes of CSV during file transfer; still log control/listing frames.
    private func shouldLogReceivedPayload(characteristic: CBCharacteristic, utf8 payload: String) -> Bool {
        if characteristic.uuid == HublinkUUIDs.filename {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "EOF" || trimmed == "NFF" { return true }
            if payload.contains("|"), payload.contains(";") { return true }
            return payload.count <= 200
        }
        guard characteristic.uuid == HublinkUUIDs.fileTransfer else { return true }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "EOF" || trimmed == "NFF" { return true }
        if payload.contains("|"), payload.contains(";"), payload.contains("EOF") { return true }
        return false
    }

    /// Parses a complete file-listing buffer (`name|size;…`). Completion is signaled by a separate `EOF` indication (buffer may not contain the literal `EOF`) or by `;…EOF` in one chunk.
    private func processFilenameListingPayload(_ buffer: String) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            DispatchQueue.main.async {
                self.appState.availablePackages = []
                self.appState.selectedPackageDate = ""
                self.appState.log("File listing: empty")
            }
            return
        }
        guard trimmed.contains("|") else { return }

        var namesInListing: [String] = []
        for raw in trimmed.components(separatedBy: ";") {
            let component = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !component.isEmpty else { continue }
            if component == "EOF" { continue }
            guard let pipe = component.firstIndex(of: "|") else { continue }
            let name = String(component[..<pipe]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != "EOF" {
                namesInListing.append(name)
            }
        }

        let connectedDeviceID = self.appState.connectedDevice?.name ?? "JX_UNKNOWN"
        var packageMap: [String: DailyPackage] = [:]
        var jxCsvCount = 0
        for name in namesInListing {
            guard let key = PackageStore.dateKey(from: name) else { continue }
            jxCsvCount += 1
            if packageMap[key] == nil {
                packageMap[key] = DailyPackage(dateKey: key, deviceID: connectedDeviceID, files: [:])
            }
            packageMap[key]!.files[name] = URL(fileURLWithPath: name)
        }
        let packages = packageMap.values
            .map { pkg in
                DailyPackage(
                    dateKey: pkg.dateKey,
                    deviceID: pkg.deviceID,
                    files: pkg.files,
                    lastFileWriteAt: DailyPackage.resolvedLastFileWriteAt(files: pkg.files, dateKey: pkg.dateKey)
                )
            }
            .sorted {
                if $0.lastFileWriteAt != $1.lastFileWriteAt { return $0.lastFileWriteAt > $1.lastFileWriteAt }
                return $0.dateKey > $1.dateKey
            }

        DispatchQueue.main.async {
            self.appState.availablePackages = packages
            let validKeys = Set(packages.map { $0.dateKey })
            if !validKeys.contains(self.appState.selectedPackageDate) {
                self.appState.selectedPackageDate = packages.first?.dateKey ?? ""
            }
            self.appState.log("File listing: \(namesInListing.count) name(s), \(jxCsvCount) JX*.csv in package format → \(packages.count) daily package(s) on device")
        }
    }

    /// Handles UTF-8 payloads on the filename characteristic (chunked listing + `NFF`).
    private func handleFilenameCharacteristicUTF8(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "NFF" {
            filenameListingBuffer = ""
            DispatchQueue.main.async {
                self.appState.log("ERROR: File not found on device")
                self.stagingContent = ""
            }
            return
        }
        if trimmed == "EOF" {
            let buf = filenameListingBuffer
            filenameListingBuffer = ""
            processFilenameListingPayload(buf)
            return
        }
        filenameListingBuffer += string
        let buf = filenameListingBuffer
        if buf.contains("|"), buf.contains("EOF") {
            filenameListingBuffer = ""
            processFilenameListingPayload(buf)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Service discovery failed - \(error!.localizedDescription)")
            return
        }
        
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Characteristic discovery failed - \(error!.localizedDescription)")
            return
        }
        
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case HublinkUUIDs.filename:
                filenameCharacteristic = characteristic
                appState.log("Found filename characteristic")
            case HublinkUUIDs.fileTransfer:
                fileTransferCharacteristic = characteristic
                appState.log("Found file transfer characteristic")
            case HublinkUUIDs.gateway:
                gatewayCharacteristic = characteristic
                appState.log("Found gateway characteristic")
            case HublinkUUIDs.node:
                nodeCharacteristic = characteristic
                appState.log("Found node characteristic")
            default:
                break
            }
        }
        
        // Enable notifications for relevant characteristics
        if let filenameChar = filenameCharacteristic {
            peripheral.setNotifyValue(true, for: filenameChar)
        }
        if let fileTransferChar = fileTransferCharacteristic {
            peripheral.setNotifyValue(true, for: fileTransferChar)
        }
        
        // Read node characteristic first; gateway handshake runs after node payload is handled.
        checkAndReadNode()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error = error {
            appState.log("ERROR: RSSI read failed - \(error.localizedDescription)")
        } else {
            DispatchQueue.main.async {
                self.appState.connectedDeviceRSSI = RSSI.intValue
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            appState.log("ERROR: Characteristic update failed - \(error!.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            appState.log("ERROR: No data received from characteristic")
            return
        }

        // Try to decode as UTF-8 string first (for commands/responses)
        if let string = String(data: data, encoding: .utf8) {
            if shouldLogReceivedPayload(characteristic: characteristic, utf8: string) {
                appState.log("RECEIVED: \(string)")
            }
            
            // Handle node characteristic response (device info JSON)
            if characteristic.uuid == HublinkUUIDs.node {
                do {
                    if let jsonData = string.data(using: .utf8),
                       let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                        if let battery = json["batteryLevel"] as? Int {
                            DispatchQueue.main.async {
                                self.appState.batteryLevel = battery
                                self.appState.log("Device battery level: \(battery)%")
                            }
                        }

                        if let memory = json["memoryLevel"] as? Int {
                            DispatchQueue.main.async {
                                self.appState.memoryLevel = memory
                                self.appState.log("Device memory level: \(memory)%")
                            }
                        }

                        if let subjectID = json["subjectId"] as? String {
                            DispatchQueue.main.async {
                                self.appState.subjectID = subjectID
                            }
                        }

                        if let experiment = json["experiment"] as? String {
                            DispatchQueue.main.async {
                                self.appState.experiment = experiment
                            }
                        }

                        if let advInterval = json["advInterval"] as? Int {
                            DispatchQueue.main.async {
                                if advInterval <= 0 {
                                    self.appState.advOff = true
                                } else {
                                    self.appState.advOff = false
                                    self.appState.advInterval = max(1, min(10, advInterval))
                                }
                            }
                        }

                        if let scanInterval = json["scanInterval"] as? Int {
                            DispatchQueue.main.async {
                                if scanInterval <= 0 {
                                    self.appState.scanOff = true
                                } else {
                                    self.appState.scanOff = false
                                    self.appState.scanInterval = max(5, min(60, scanInterval))
                                }
                            }
                        }

                        if let multiplier = json["inactivityMultiplier"] as? Int {
                            DispatchQueue.main.async {
                                self.appState.inactivityMultiplier = max(1, min(5, multiplier))
                            }
                        }

                        if let deviceId = json["deviceId"] as? String {
                            appState.log("Device ID: \(deviceId)")
                        }

                        let firmware = json["firmwareVersion"] as? String
                        if let firmware = firmware {
                            DispatchQueue.main.async {
                                self.appState.firmwareVersion = firmware
                                self.appState.log("Firmware version: \(firmware)")
                            }
                        }

                        let settingsFieldsComplete = AppState.nodePayloadHasAllDeviceSettingsFields(json)
                        // Firmware 5.8 gate (disabled): session used to run only when `firmware?.hasPrefix("5.8")`; else branch disconnected (see comment block below).
                        DispatchQueue.main.async {
                            self.appState.isBaseStationConnection = !settingsFieldsComplete
                            self.appState.hasFullNodeDeviceSettings = settingsFieldsComplete
                            if settingsFieldsComplete {
                                self.appState.captureSettingsBaseline()
                            } else {
                                self.appState.clearSettingsBaseline()
                                if !self.appState.didLogBaseStationNotice {
                                    self.appState.didLogBaseStationNotice = true
                                    self.appState.log("Detected Base Station Connection")
                                }
                            }
                            self.startSessionHandshake()
                        }
                        /*
                        Firmware 5.8 gate (disabled): wrap the `DispatchQueue.main.async` above in
                          `if let firmware = firmware, firmware.hasPrefix("5.8") { … }`
                          and restore the else branch: clear hasFull/isBaseStation, incompatible alert, `forceDisconnect()`.
                        */
                    } else {
                        DispatchQueue.main.async {
                            self.appState.hasFullNodeDeviceSettings = false
                            self.appState.isBaseStationConnection = false
                            self.appState.clearSettingsBaseline()
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.appState.hasFullNodeDeviceSettings = false
                        self.appState.isBaseStationConnection = false
                        self.appState.clearSettingsBaseline()
                    }
                    appState.log("ERROR: Failed to parse node characteristic JSON - \(error.localizedDescription)")
                }
                return
            }

            if characteristic.uuid == HublinkUUIDs.filename {
                handleFilenameCharacteristicUTF8(string)
                return
            }
            
            // Handle NFF (No File Found) response
            if string.trimmingCharacters(in: .whitespacesAndNewlines) == "NFF" {
                DispatchQueue.main.async {
                    self.appState.log("ERROR: File not found on device")
                    self.stagingContent = ""
                }
                return
            }

            // Handle EOF — end of individual file in a package transfer
            if string.trimmingCharacters(in: .whitespacesAndNewlines) == "EOF" {
                DispatchQueue.main.async {
                    if self.appState.isTransferringPackage {
                        self.completeCurrentFileTransfer()
                    } else {
                        self.appState.log("✓ File transfer completed")
                    }
                }
                return
            }

            if characteristic.uuid == HublinkUUIDs.fileTransfer {
                stagingContent += string
            }
        } else if characteristic.uuid == HublinkUUIDs.fileTransfer {
            stagingContent += String(decoding: data, as: UTF8.self)
        } else {
            appState.log("WARNING: Received binary data on non-file-transfer characteristic")
        }
    }
}

// MARK: - Date Formatter Extension
extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Custom Button Style
struct JuxtaButtonStyle: ButtonStyle {
    let color: Color
    let isDestructive: Bool
    let isOperatingMode: Bool
    let isSubtle: Bool
    
    init(color: Color = .blue, isDestructive: Bool = false, isOperatingMode: Bool = false, isSubtle: Bool = false) {
        self.color = color
        self.isDestructive = isDestructive
        self.isOperatingMode = isOperatingMode
        self.isSubtle = isSubtle
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .default))
            .foregroundColor(isOperatingMode ? color : (isDestructive ? .white : .primary))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSubtle ? AnyShapeStyle(Color(.systemGray6)) :
                        isDestructive ? 
                        AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.8)], startPoint: .top, endPoint: .bottom)) :
                        isOperatingMode ?
                        AnyShapeStyle(Color(.systemBackground)) :
                        AnyShapeStyle(LinearGradient(colors: [Color(.systemGray6), Color(.systemGray5)], startPoint: .top, endPoint: .bottom))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isOperatingMode ? color : color.opacity(0.3), 
                        lineWidth: isOperatingMode ? 2 : 0.5
                    )
            )
            .shadow(
                color: isSubtle ? Color.black.opacity(0.1) : 
                       isOperatingMode ? color.opacity(0.3) : color.opacity(0.2), 
                radius: configuration.isPressed ? 1 : (isSubtle ? 1 : (isOperatingMode ? 2 : 3)), 
                x: 0, 
                y: configuration.isPressed ? 1 : (isSubtle ? 1 : (isOperatingMode ? 1 : 2))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var appState: AppState
    @StateObject private var bleManager: BLEManager
    @StateObject private var packageStore: PackageStore

    init() {
        let state = AppState()
        let store = PackageStore()
        _appState = StateObject(wrappedValue: state)
        _packageStore = StateObject(wrappedValue: store)
        _bleManager = StateObject(wrappedValue: BLEManager(appState: state, packageStore: store))
        state.startClock()
    }

    enum AppTab: Hashable { case device, packages, terminal, info }

    @State private var selectedTab: AppTab = .device

    var body: some View {
        TabView(selection: $selectedTab) {
            deviceTab
                .tag(AppTab.device)
                .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
            NavigationView {
                PackagesView()
            }
            .environmentObject(packageStore)
            .tag(AppTab.packages)
            .tabItem { Label("Packages", systemImage: "folder") }
            NavigationStack {
                TerminalTabView(appState: appState)
            }
            .tag(AppTab.terminal)
            .tabItem { Label("Terminal", systemImage: "terminal") }
            NavigationStack {
                InfoAboutView()
            }
            .tag(AppTab.info)
            .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .background(
            DeviceTabBarTintRefresher(isConnected: appState.isConnected, selectedTab: selectedTab)
        )
        .onAppear {
            Self.applyDeviceTabBarConnectedTint(isConnected: appState.isConnected)
        }
        .onChange(of: appState.isConnected) { _, newValue in
            Self.applyDeviceTabBarConnectedTint(isConnected: newValue)
        }
        .onChange(of: selectedTab) { _, _ in
            Self.applyDeviceTabBarConnectedTint(isConnected: appState.isConnected)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("UITabBarControllerSelectionDidChange"))) { _ in
            Self.applyDeviceTabBarConnectedTint(isConnected: appState.isConnected)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Self.applyDeviceTabBarConnectedTint(isConnected: appState.isConnected)
        }
    }

    /// Re-applies green Device tab styling from SwiftUI's update cycle (tab switches often reset `UITabBarItem`).
    private struct DeviceTabBarTintRefresher: UIViewControllerRepresentable {
        let isConnected: Bool
        let selectedTab: AppTab

        func makeUIViewController(context: Context) -> UIViewController {
            let vc = UIViewController()
            vc.view.isUserInteractionEnabled = false
            vc.view.backgroundColor = .clear
            return vc
        }

        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            ContentView.applyDeviceTabBarConnectedTint(isConnected: isConnected)
        }
    }

    /// SwiftUI tab items ignore conditional `foregroundStyle` for the inactive tab; set the underlying
    /// `UITabBarItem` image and title attributes directly. Re-applied on tab changes because SwiftUI
    /// may restore its own tab item rendering when switching tabs.
    private static func applyDeviceTabBarConnectedTint(isConnected: Bool) {
        DispatchQueue.main.async { apply(isConnected: isConnected) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { apply(isConnected: isConnected) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { apply(isConnected: isConnected) }
    }

    private static func apply(isConnected: Bool) {
        guard let tabVC = findRootTabBarController(),
              let items = tabVC.tabBar.items,
              let deviceItem = items.first else { return }
        let symbolName = "antenna.radiowaves.left.and.right"
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        guard let base = UIImage(systemName: symbolName, withConfiguration: config) else { return }
        if isConnected {
            let green = base.withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
            deviceItem.image = green
            deviceItem.selectedImage = green
            let titleAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.systemGreen]
            deviceItem.setTitleTextAttributes(titleAttrs, for: .normal)
            deviceItem.setTitleTextAttributes(titleAttrs, for: .selected)
            deviceItem.setTitleTextAttributes(titleAttrs, for: .highlighted)
        } else {
            deviceItem.image = base.withRenderingMode(.alwaysTemplate)
            deviceItem.selectedImage = nil
            deviceItem.setTitleTextAttributes(nil, for: .normal)
            deviceItem.setTitleTextAttributes(nil, for: .selected)
            deviceItem.setTitleTextAttributes(nil, for: .highlighted)
        }
    }

    private static func findRootTabBarController() -> UITabBarController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                if let tab = findTabBarRecursively(from: window.rootViewController) {
                    return tab
                }
            }
        }
        return nil
    }

    private static func findTabBarRecursively(from vc: UIViewController?) -> UITabBarController? {
        guard let vc = vc else { return nil }
        if let tab = vc as? UITabBarController { return tab }
        for child in vc.children {
            if let tab = findTabBarRecursively(from: child) { return tab }
        }
        return findTabBarRecursively(from: vc.presentedViewController)
    }

    private var deviceTab: some View {
        VStack(spacing: 0) {
            clockView
            if appState.isConnected {
                connectedView
            } else {
                headerView
                deviceListView
                Spacer(minLength: 0)
            }
        }
        .background(Color(.systemBackground))
        .overlay {
            if appState.showShelfDisconnectOverlay {
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.1)
                        Text("Disconnecting...")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Resetting device to shelf mode")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .allowsHitTesting(true)
            }
        }
    }
    
    // MARK: - Clock View
    private var clockView: some View {
        HStack {
            Spacer()
            HStack(spacing: 0) {
                let components = appState.currentTime.components(separatedBy: " • ")
                if components.count == 2 {
                    Text(components[0])
                        .font(.system(size: 16, weight: .regular, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(" • ")
                        .font(.system(size: 16, weight: .regular, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(components[1])
                        .font(.system(size: 16, weight: .heavy, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text(appState.currentTime)
                        .font(.system(size: 16, weight: .regular, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            Spacer()
            
            // Debug bug icon
            Button(action: {
                appState.isConnected.toggle()
                appState.log("DEBUG: Connection state toggled to \(appState.isConnected)")
            }) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .opacity(0.5)
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
    
    // MARK: - Header View
    private var headerView: some View {
        VStack(spacing: 16) {
            if !appState.isConnected {
                Button(action: {
                    if appState.isScanning {
                        bleManager.stopScanning()
                    } else {
                        bleManager.startScanning()
                    }
                }) {
                    Text(appState.isScanning ? "Stop" : "Scan")
                        .font(.system(size: 20, weight: .semibold, design: .default))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.42, green: 0.05, blue: 0.68), // Deep purple ~#6A0DAD
                                    Color(red: 1.0, green: 0.0, blue: 1.0)     // Vibrant fuchsia ~#FF00FF
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
    
    // MARK: - Device List View
    private var deviceListView: some View {
        List {
            ForEach(appState.discoveredDevices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name ?? "Unknown")
                            .font(.system(size: 16, weight: .medium, design: .default))
                        
                        if let rssi = device.rssi {
                            Text("RSSI: \(rssi)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            Text("RSSI: --")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        bleManager.connect(to: device.peripheral)
                    }) {
                        Text("Connect")
                            .font(.system(size: 14, weight: .medium, design: .default))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isConnected)
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(PlainListStyle())
    }
    
    // MARK: - Connected View

    /// SF Symbol tier that matches `battery_level` (0–100) so the glyph is not stuck at "full".
    private func batterySystemImage(for percent: Int) -> String {
        let p = max(0, min(100, percent))
        switch p {
        case 0: return "battery.0"
        case 1...25: return "battery.25"
        case 26...50: return "battery.50"
        case 51...75: return "battery.75"
        default: return "battery.100"
        }
    }

    private var connectedView: some View {
        VStack(spacing: 16) {
            // Header with disconnect
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.connectedDevice?.name ?? "Not Connected")
                        .font(.system(size: 20, weight: .semibold, design: .default))
                        .foregroundColor(.white)
                    
                    // Device status row
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                            Text("\(appState.connectedDeviceRSSI) dB")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        if let battery = appState.batteryLevel {
                            HStack(spacing: 4) {
                                Image(systemName: batterySystemImage(for: battery))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                Text("\(battery)%")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        
                        if let memory = appState.memoryLevel {
                            HStack(spacing: 4) {
                                Image(systemName: "internaldrive")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                Text("\(memory)%")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        
                        if let firmware = appState.firmwareVersion {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                Text(firmware)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                    }
                }
                
                Spacer()
                
                Button(action: {
                    bleManager.disconnect()
                }) {
                    Text("Disconnect")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(color: .red, isDestructive: true))
            }
            
            if appState.isBaseStationConnection {
                baseStationConnectionBanner
            } else if appState.hasFullNodeDeviceSettings {
                deviceSettingsCard
            }

            dailyPackagesCard

            HStack(spacing: 12) {
                Button(action: {
                    appState.showShelfModeAlert = true
                }) {
                    Text("Shelf Mode")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(color: .orange))

                Button(action: {
                    appState.showClearMemoryAlert = true
                }) {
                    Text("Clear Memory")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(JuxtaButtonStyle(color: .orange))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .alert("Clear Memory", isPresented: $appState.showClearMemoryAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Memory", role: .destructive) { bleManager.clearMemory() }
        } message: {
            Text("This will permanently clear all memory on the device. This action cannot be undone.")
        }
        .alert("Shelf Mode", isPresented: $appState.showShelfModeAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset to Shelf Mode", role: .destructive) {
                appState.beginShelfDisconnectAwait()
                bleManager.resetToShelfMode()
            }
        } message: {
            Text("This will reset the device to shelf mode. The device will restart and return to its default state.")
        }
        .alert("Incompatible Device", isPresented: $appState.showIncompatibleFirmwareAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Incompatible Voleo (v5.8) device.")
        }
        .alert("Restore Defaults", isPresented: $appState.showDefaultSettingsAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                appState.resetSettingsToDefaults()
            }
        } message: {
            Text("Advertising interval will be set to 10 s, scanning interval to 10 s, and the inactivity scan multiplier to 5×. Tap Push to send these values to the device.")
        }
    }

    // MARK: - Base station (no device settings on node)

    private var baseStationConnectionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.secondary)
            Text("Detected Base Station Connection")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("DetectedBaseStationConnection")
    }

    // MARK: - Inline Device Settings card

    private var deviceSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text("Device Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button(action: { appState.showDefaultSettingsAlert = true }) {
                    Text("Default")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(.systemGray))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 22)
                .accessibilityLabel("Reset on-screen settings to defaults")
                if !appState.pushFeedback.isEmpty {
                    Text(appState.pushFeedback)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
                Button(action: { bleManager.saveSettings() }) {
                    Image(systemName: appState.pushFeedback.isEmpty ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(appState.pushFeedback.isEmpty ? .blue : .green)
                }
                .accessibilityLabel("Push settings to device")
            }

            HStack(spacing: 8) {
                Text("Subject")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("Subject ID", text: $appState.subjectID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }

            HStack(spacing: 8) {
                Text("Experiment")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("Experiment", text: $appState.experiment)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }

            HStack(spacing: 8) {
                Text("Adv")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(appState.advInterval) },
                    set: {
                        let rounded = Int($0.rounded())
                        appState.advInterval = max(1, min(10, rounded))
                    }
                ), in: 1...10, step: 1)
                .disabled(appState.advOff)
                Text(appState.advOff ? "-" : "\(appState.advInterval)s")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(appState.advOff ? .secondary : .primary)
                    .frame(width: 32, alignment: .trailing)
                HStack(spacing: 4) {
                    Text("Off")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $appState.advOff)
                        .labelsHidden()
                        .scaleEffect(0.75)
                }
            }

            HStack(spacing: 8) {
                Text("Scan")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(appState.scanInterval) },
                    set: {
                        let rounded = Int(($0 / 5).rounded()) * 5
                        appState.scanInterval = max(5, min(60, rounded))
                    }
                ), in: 5...60, step: 5)
                .disabled(appState.scanOff)
                Text(appState.scanOff ? "-" : "\(appState.scanInterval)s")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(appState.scanOff ? .secondary : .primary)
                    .frame(width: 32, alignment: .trailing)
                HStack(spacing: 4) {
                    Text("Off")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $appState.scanOff)
                        .labelsHidden()
                        .scaleEffect(0.75)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Inactivity Scan Multiplier")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Picker("Inactivity Scan Multiplier", selection: $appState.inactivityMultiplier) {
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value)×").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(appState.hasUnsavedSettings ? Color.blue : Color.clear, lineWidth: 2)
        )
        .shadow(color: appState.hasUnsavedSettings ? Color.blue.opacity(0.45) : .clear,
                radius: appState.hasUnsavedSettings ? 8 : 0)
        .animation(.easeInOut(duration: 0.2), value: appState.pushFeedback)
        .animation(.easeInOut(duration: 0.2), value: appState.hasUnsavedSettings)
    }

    private var dailyPackagesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily Packages")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(appState.availablePackages.count) on device")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if appState.availablePackages.isEmpty {
                Text("No packages available")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appState.availablePackages) { pkg in
                            packageRow(pkg)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button(action: {
                guard !appState.selectedPackageDate.isEmpty,
                      let pkg = appState.availablePackages.first(where: { $0.dateKey == appState.selectedPackageDate }) else { return }
                bleManager.startPackageTransfer(dateKey: pkg.dateKey, deviceID: pkg.deviceID)
            }) {
                HStack(spacing: 6) {
                    if appState.isTransferringPackage {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                        Text(appState.transferProgress.isEmpty ? "Transferring…" : appState.transferProgress)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                        Text("Transfer Selected")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            }
            .buttonStyle(JuxtaButtonStyle(color: .blue, isDestructive: true))
            .disabled(appState.selectedPackageDate.isEmpty || appState.availablePackages.isEmpty || appState.isTransferringPackage)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func packageRow(_ pkg: DailyPackage) -> some View {
        let isSelected = (pkg.dateKey == appState.selectedPackageDate)
        let isDone = appState.transferredDateKeys.contains(pkg.dateKey)
        return Button(action: {
            appState.selectedPackageDate = pkg.dateKey
        }) {
            HStack(spacing: 8) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isDone ? .green : Color(.systemGray3))
                Text(pkg.displayDate)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(pkg.fileCount) file\(pkg.fileCount == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.34) : Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(appState.isTransferringPackage)
    }
}

// MARK: - Packages View
private struct DevicePackageGroup: Identifiable {
    let id: String
    let deviceID: String
    /// Newest first within the device.
    let packages: [DailyPackage]
}

struct PackagesView: View {
    @EnvironmentObject var packageStore: PackageStore
    @State private var showDeleteConfirm = false
    @State private var packageToDelete: DailyPackage?

    /// Devices ordered by most recently written local package (`lastFileWriteAt`); `dateKey` alone is day-only.
    private var devicePackageGroups: [DevicePackageGroup] {
        let byDevice = Dictionary(grouping: packageStore.packages, by: { $0.deviceID })
        return byDevice
            .map { deviceID, pkgs -> DevicePackageGroup in
                let sorted = pkgs.sorted {
                    if $0.lastFileWriteAt != $1.lastFileWriteAt { return $0.lastFileWriteAt > $1.lastFileWriteAt }
                    return $0.dateKey > $1.dateKey
                }
                return DevicePackageGroup(id: deviceID, deviceID: deviceID, packages: sorted)
            }
            .sorted { a, b in
                let newestA = a.packages.first?.lastFileWriteAt ?? .distantPast
                let newestB = b.packages.first?.lastFileWriteAt ?? .distantPast
                if newestA != newestB { return newestA > newestB }
                let keyA = a.packages.first?.dateKey ?? ""
                let keyB = b.packages.first?.dateKey ?? ""
                if keyA != keyB { return keyA > keyB }
                return a.deviceID < b.deviceID
            }
    }

    var body: some View {
        Group {
            if packageStore.packages.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No packages yet.")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Transfer data from a connected device.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(devicePackageGroups) { group in
                        Section {
                            ForEach(group.packages) { pkg in
                                NavigationLink(destination: DailyPackageView(package: pkg)) {
                                    HStack(alignment: .center, spacing: 10) {
                                        Text(pkg.displayDate)
                                            .font(.system(size: 15, weight: .semibold))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                        Spacer(minLength: 8)
                                        HStack(spacing: 3) {
                                            fileIcon("V", present: pkg.vitalsURL != nil)
                                            fileIcon("S", present: pkg.settingsURL != nil)
                                            fileIcon("B", present: pkg.bleURL != nil)
                                        }
                                        Image(systemName: pkg.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle")
                                            .foregroundColor(pkg.isComplete ? .green : .orange)
                                            .font(.system(size: 14))
                                            .imageScale(.small)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        packageToDelete = pkg
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 8))
                            }
                        } header: {
                            Text(group.deviceID)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .textCase(nil)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .navigationTitle("Packages")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { packageStore.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .alert("Delete Package", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let pkg = packageToDelete { packageStore.delete(pkg) }
            }
        } message: {
            Text("This will permanently delete all files in this package from the device. This cannot be undone.")
        }
    }

    private func fileIcon(_ letter: String, present: Bool) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(present ? Color.blue.opacity(0.15) : Color(.systemGray5))
            .foregroundColor(present ? .blue : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Daily Package View
/// Atomic payload for `.sheet(item:)` — using a `@State Bool` + separate `[Any]` was
/// causing the first share tap to present with stale (empty) items.
private struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct DailyPackageView: View {
    let package: DailyPackage
    @State private var sharePayload: SharePayload?
    @State private var vitalsContent: String? = nil
    @State private var settingsContent: String? = nil
    @State private var bleContent: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                fileSection(title: "Vitals", filename: "JXV\(package.dateKey).csv",
                            url: package.vitalsURL, content: vitalsContent, action: .plots(.vitals))
                fileSection(title: "Settings", filename: "JXS\(package.dateKey).csv",
                            url: package.settingsURL, content: settingsContent, action: .table)
                fileSection(title: "BLE Activity", filename: "JXB\(package.dateKey).csv",
                            url: package.bleURL, content: bleContent, action: .plots(.ble))
            }
            .padding()
        }
        .navigationTitle("\(package.displayDate)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: copyAll) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button(action: share) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.urls.map { $0 as Any }) { sharePayload = nil }
        }
        .onAppear { loadFiles() }
    }

    private func fileSection(title: String, filename: String, url: URL?, content: String?, action: SectionAction?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: fileIcon(for: title))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if url != nil, let text = content, let action = action {
                    NavigationLink {
                        switch action {
                        case .plots(let kind):
                            PlotsView(csvText: text, kind: kind, displayDate: package.displayDate)
                        case .table:
                            CSVFullTextView(csvText: text, filename: filename, displayDate: package.displayDate)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: action.iconName)
                                .font(.system(size: 11, weight: .medium))
                            Text(action.linkLabel)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }
            if let url = url {
                if let text = content {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text.isEmpty ? "(empty)" : text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: 200)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("\(url.lastPathComponent) — \(text.components(separatedBy: "\n").count) lines")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("File not in this package.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func fileIcon(for title: String) -> String {
        switch title {
        case "Vitals":      return "heart.text.square"
        case "Settings":    return "gearshape"
        case "BLE Activity": return "dot.radiowaves.left.and.right"
        default:            return "doc.text"
        }
    }

    private func loadFiles() {
        Task { @MainActor in
            vitalsContent = package.vitalsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(stripUTF8BOMPrefix(from:)) ?? ""
            settingsContent = package.settingsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(stripUTF8BOMPrefix(from:)) ?? ""
            bleContent = package.bleURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(stripUTF8BOMPrefix(from:)) ?? ""
        }
    }

    private func copyAll() {
        let vitalsName   = package.vitalsURL?.lastPathComponent   ?? "JXV\(package.dateKey).csv"
        let settingsName = package.settingsURL?.lastPathComponent ?? "JXS\(package.dateKey).csv"
        let bleName      = package.bleURL?.lastPathComponent      ?? "JXB\(package.dateKey).csv"

        let parts = [
            vitalsContent.map   { "=== Vitals — \(vitalsName) ===\n\($0)" },
            settingsContent.map { "=== Settings — \(settingsName) ===\n\($0)" },
            bleContent.map      { "=== BLE Activity — \(bleName) ===\n\($0)" }
        ].compactMap { $0 }
        UIPasteboard.general.string = parts.joined(separator: "\n\n")
    }

    private func share() {
        let urls = Array(package.files.values)
        guard !urls.isEmpty else { return }
        sharePayload = SharePayload(urls: urls)
    }
}

// MARK: - Plot Models
enum PlotKind {
    case vitals
    case ble

    var title: String {
        switch self {
        case .vitals: return "Vitals"
        case .ble:    return "BLE Activity"
        }
    }
}

enum SectionAction {
    case plots(PlotKind)
    case table

    var iconName: String {
        switch self {
        case .plots: return "chart.xyaxis.line"
        case .table: return "doc.plaintext"
        }
    }

    var linkLabel: String {
        switch self {
        case .plots: return "View Plots"
        case .table: return "View All"
        }
    }
}

struct VitalsRow: Identifiable {
    let id: Int
    let date: Date
    let battV: Double?
    let tempC: Double?
    let lux: Double?
    let motion: Double?
}

struct BLERow: Identifiable {
    let id: Int
    let date: Date
    let peerID: String
    let rssi: Int
}

private extension CharacterSet {
    /// Whitespace/newlines plus BOM, ZWSP, NBSP (common in exports / SD tools).
    static let csvCellTrimming = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{00A0}\u{202F}"))
}

/// SD card / PC exports often start with UTF-8 BOM (`U+FEFF`), which breaks keyed lookups for `unix`, etc.
private func stripUTF8BOMPrefix(from text: String) -> String {
    if text.hasPrefix("\u{FEFF}") {
        var t = text
        t.removeFirst()
        return t
    }
    return text
}

private func normalizeCsvLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

private func trimCsvCell(_ raw: Substring) -> String {
    var s = String(raw).trimmingCharacters(in: .csvCellTrimming)
    while let c = s.first, c == "\u{FEFF}" || c == "\u{200B}" {
        s.removeFirst()
    }
    return s
}

private func parseCsvUnixSeconds(_ raw: String?) -> TimeInterval? {
    guard let s = raw?.trimmingCharacters(in: .csvCellTrimming), !s.isEmpty else { return nil }
    return Double(s)
}

private func parseCsvDouble(_ raw: String?) -> Double? {
    guard var s = raw?.trimmingCharacters(in: .csvCellTrimming), !s.isEmpty else { return nil }
    if s.contains(","), !s.contains(".") { s = s.replacingOccurrences(of: ",", with: ".") }
    return Double(s)
}

private func parseCsvInt(_ raw: String?) -> Int? {
    guard let s = raw?.trimmingCharacters(in: .csvCellTrimming), !s.isEmpty else { return nil }
    if let i = Int(s) { return i }
    if let d = Double(s) { return Int(d.rounded()) }
    return nil
}

private func parseCSV(_ text: String) -> [[String: String]] {
    let normalized = normalizeCsvLineEndings(stripUTF8BOMPrefix(from: text))
    let lines = normalized
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .csvCellTrimming) }
        .filter { !$0.isEmpty }
    guard let headerLine = lines.first else { return [] }
    let headers = headerLine
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { trimCsvCell($0).lowercased() }
    var rows: [[String: String]] = []
    rows.reserveCapacity(max(0, lines.count - 1))
    for line in lines.dropFirst() {
        let cols = line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(trimCsvCell)
        var dict: [String: String] = [:]
        for (i, header) in headers.enumerated() where i < cols.count && !header.isEmpty {
            dict[header] = cols[i]
        }
        rows.append(dict)
    }
    return rows
}

// MARK: - Plots View
struct PlotsView: View {
    /// In-memory CSV from `DailyPackageView` (no second file read; avoids errno 2 from background fopen).
    let csvText: String
    let kind: PlotKind
    let displayDate: String

    @State private var vitalsRows: [VitalsRow] = []
    @State private var bleRows: [BLERow] = []
    @State private var errorText: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let err = errorText {
                    Text(err)
                        .foregroundColor(.red)
                        .padding()
                } else {
                    switch kind {
                    case .vitals:
                        if vitalsRows.isEmpty { emptyState } else { vitalsCharts }
                    case .ble:
                        if bleRows.isEmpty { emptyState } else { bleSection }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("\(kind.title) — \(displayDate)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await parseCsvForCharts()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No plottable data in this file.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @ViewBuilder
    private var vitalsCharts: some View {
        chartCard(title: "Battery Voltage (V)") {
            Chart {
                ForEach(vitalsRows) { row in
                    if let v = row.battV {
                        LineMark(
                            x: .value("Time", row.date),
                            y: .value("Voltage", v)
                        )
                    }
                }
            }
        }
        chartCard(title: "Temperature (°C)") {
            Chart {
                ForEach(vitalsRows) { row in
                    if let t = row.tempC {
                        LineMark(
                            x: .value("Time", row.date),
                            y: .value("Temp", t)
                        )
                    }
                }
            }
        }
        if vitalsRows.contains(where: { $0.lux != nil }) {
            chartCard(title: "Lux") {
                Chart {
                    ForEach(vitalsRows) { row in
                        if let lux = row.lux {
                            LineMark(
                                x: .value("Time", row.date),
                                y: .value("Lux", lux)
                            )
                        }
                    }
                }
            }
        }
        chartCard(title: "Motion (Count)") {
            Chart {
                ForEach(vitalsRows) { row in
                    if let m = row.motion {
                        LineMark(
                            x: .value("Time", row.date),
                            y: .value("Motion", m)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bleSection: some View {
        chartCard(title: "BLE Peers Over Time") {
            Chart {
                ForEach(bleRows) { row in
                    PointMark(
                        x: .value("Time", row.date),
                        y: .value("Peer", row.peerID)
                    )
                    .foregroundStyle(Self.rssiColor(row.rssi))
                    .symbolSize(40)
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("RSSI legend")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 16) {
                legendDot(.red, "≤ -90 dBm")
                legendDot(.yellow, "-90 to -80")
                legendDot(.green, "> -80")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(size: 11))
        }
    }

    private func chartCard<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            content()
                .frame(height: 200)
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static func rssiColor(_ rssi: Int) -> Color {
        if rssi <= -90 { return .red }
        if rssi <= -80 { return .yellow }
        return .green
    }

    private func parseCsvForCharts() async {
        let text = csvText
        let k = kind
        let rows = await Task.detached(priority: .userInitiated) {
            parseCSV(text)
        }.value
        await MainActor.run {
            errorText = nil
            switch k {
            case .vitals:
                var vs: [VitalsRow] = []
                vs.reserveCapacity(rows.count)
                for row in rows {
                    guard let unix = parseCsvUnixSeconds(row["unix"]) else { continue }
                    vs.append(
                        VitalsRow(
                            id: vs.count,
                            date: Date(timeIntervalSince1970: unix),
                            battV: parseCsvDouble(row["batt_v"]),
                            tempC: parseCsvDouble(row["temp_c"]),
                            lux: parseCsvDouble(row["lux"]),
                            motion: parseCsvDouble(row["motion"])
                        )
                    )
                }
                vitalsRows = vs
            case .ble:
                var br: [BLERow] = []
                br.reserveCapacity(rows.count)
                for row in rows {
                    guard let unix = parseCsvUnixSeconds(row["unix"]) else { continue }
                    let peer = (row["peer_id"] ?? row["observer_id"] ?? "").trimmingCharacters(in: .csvCellTrimming)
                    guard !peer.isEmpty, let rssi = parseCsvInt(row["rssi"]) else { continue }
                    br.append(
                        BLERow(
                            id: br.count,
                            date: Date(timeIntervalSince1970: unix),
                            peerID: peer,
                            rssi: rssi
                        )
                    )
                }
                bleRows = br
            }
        }
    }
}

// MARK: - CSV full text (Settings “View All”)

private struct CSVFullTextView: View {
    /// In-memory CSV from `DailyPackageView` (same string as the package preview).
    let csvText: String
    let filename: String
    let displayDate: String

    private var lineCount: Int {
        csvText.components(separatedBy: "\n").count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(csvText.isEmpty ? "(empty)" : csvText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("\(filename) — \(lineCount) lines")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
        .navigationTitle("\(filename) — \(displayDate)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Info / About

private enum AppVersionInfo {
    static var marketing: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }
}

private struct MagnetGestureRow: Identifiable {
    let id: String
    let gesture: String
    let ledFeedback: String
    let effect: String

    init(gesture: String, ledFeedback: String, effect: String) {
        self.id = gesture
        self.gesture = gesture
        self.ledFeedback = ledFeedback
        self.effect = effect
    }

    static let reference: [MagnetGestureRow] = [
        MagnetGestureRow(
            gesture: "Apply at any time (device in shelf mode)",
            ledFeedback: "LED ON immediately",
            effect: "Wakes device from System OFF → cold boot"
        ),
        MagnetGestureRow(
            gesture: "Release < 3 s after cold boot",
            ledFeedback: "LED off on release",
            effect: "False positive — re-arms shelf; no datetime sync or DFU; no JXS write"
        ),
        MagnetGestureRow(
            gesture: "Release 3 s ≤ t < 10 s after cold boot",
            ledFeedback: "LED off at 3 s → slow blink (50/450 ms)",
            effect: "Connectable advertising; waits for time sync. JXS shelf_exit, user_connected, time_set deferred until sync"
        ),
        MagnetGestureRow(
            gesture: "Hold ≥ 10 s after cold boot",
            ledFeedback: "LED off at 3 s → 3× blink → fast blink (50/50 ms)",
            effect: "DFU mode; confirmed 3 s hold returns to shelf after 5 s debounce"
        ),
        MagnetGestureRow(
            gesture: "Any connect event",
            ledFeedback: "Solid ON",
            effect: "Active BLE connection (user_connected in JXS once clock is valid)"
        ),
        MagnetGestureRow(
            gesture: "Disconnect after valid timestamp",
            ledFeedback: "5× blink → LED off",
            effect: "Production begins (LED off). JXS user_disconnected then boot"
        ),
        MagnetGestureRow(
            gesture: "Disconnect without timestamp",
            ledFeedback: "Slow blink resumes",
            effect: "Restarts connectable advertising"
        ),
        MagnetGestureRow(
            gesture: "Brief magnet during DFU fast-blink (< 3 s)",
            ledFeedback: "None",
            effect: "False positive — stays in DFU"
        ),
        MagnetGestureRow(
            gesture: "Confirmed magnet hold ≥ 3 s during DFU",
            ledFeedback: "LED off",
            effect: "Returns device to shelf mode"
        ),
        MagnetGestureRow(
            gesture: "Brief magnet during production (< 3 s)",
            ledFeedback: "LED ON on apply → off on release",
            effect: "False positive — production continues"
        ),
        MagnetGestureRow(
            gesture: "Confirmed magnet ≥ 3 s during production",
            ledFeedback: "LED ON → off at 3 s → 5× blink",
            effect: "Release after commit cue; 5 s debounce then shelf mode; appends shelf_entry to JXS"
        ),
        MagnetGestureRow(
            gesture: "NOR or accelerometer init failure",
            ledFeedback: "Long blink (1 s / 1 s)",
            effect: "Fault loop; no production operation"
        )
    ]
}

struct InfoAboutView: View {
    private static let quickStartSteps: [String] = [
        "Shelf mode is the default: ultra-low-power System OFF — no LED, no radio. A magnet is the only way to wake.",
        "Hold a magnet ~3 s to wake: LED solid ON on apply, off at 3 s as a \"release now\" cue, then slow blink (50 ms on / 450 ms off). Holds under 3 s are rejected as false positives.",
        "In Voleo, scan and connect. The LED stays solid ON for the duration of the BLE connection.",
        "Time sync runs automatically; device settings populate the app. Tap Push to send any changes back.",
        "Disconnect to enter production: 5× blink, LED off, then vitals/logging run with LED off throughout.",
        "Return to shelf during production with a ~3 s magnet hold: solid ON → off at 3 s → 5× blink → grace period → one confirmation blink → System OFF. A shelf_entry row is written to JXS.",
        "Hold ≥ 10 s only to enter DFU: LED off at 3 s, then 3× blink and fast blink at 10 s. Release between 3 s and 10 s if you only want to wake, not update firmware."
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voleo")
                        .font(.system(size: 22, weight: .bold, design: .default))
                    Text("Companion app for Juxta 5.8+ wearable devices.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick start")
                        .font(.system(size: 13, weight: .semibold))
                    Text("End-to-end flow in Voleo. Magnet timing is enforced by firmware (3 s minimum hold, 10 s for DFU) — see Magnet gestures below.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(Self.quickStartSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1).")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(step)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Magnet gestures & LED feedback")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Every magnet gesture requires a confirmed 3 s minimum hold; shorter touches are false positives. At 3 s the LED turns off as a \"release now\" commit cue on wake and production paths. DFU requires a 10 s hold.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 8) {
                            gestureHeaderCell("Gesture")
                            gestureHeaderCell("LED feedback")
                            gestureHeaderCell("Effect")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Color(.secondarySystemBackground))

                        Divider()

                        ForEach(Array(MagnetGestureRow.reference.enumerated()), id: \.element.id) { index, row in
                            HStack(alignment: .top, spacing: 8) {
                                gestureBodyCell(row.gesture)
                                gestureBodyCell(row.ledFeedback)
                                gestureBodyCell(row.effect)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            if index < MagnetGestureRow.reference.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("App version")
                        .font(.system(size: 13, weight: .semibold))
                    Text("For support, include this build when reporting an issue.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("\(AppVersionInfo.marketing) (\(AppVersionInfo.build))")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Firmware update (DFU)")
                        .font(.system(size: 13, weight: .semibold))
                    (Text("DFU mode is entered with a ≥ 10 s magnet hold (see gestures above). Once in DFU, use Nordic Semiconductor's ")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                     + Text("nRF Connect")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                     + Text(" app to flash firmware. Firmware image files are supplied by the developer.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text("Developed by the Neurotech Hub at WashU in St. Louis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gestureHeaderCell(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gestureBodyCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Terminal tab
struct TerminalTabView: View {
    @ObservedObject var appState: AppState
    @State private var copyConfirmation = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.terminalLog.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black)
            .onChange(of: appState.terminalLog.count) { _, _ in
                if let lastIndex = appState.terminalLog.indices.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastIndex = appState.terminalLog.indices.last {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: clearLog) {
                    Image(systemName: "trash")
                }
                .disabled(appState.terminalLog.isEmpty)

                Button(action: copyLog) {
                    HStack(spacing: 4) {
                        Image(systemName: copyConfirmation.isEmpty ? "doc.on.doc" : "checkmark")
                        if !copyConfirmation.isEmpty {
                            Text(copyConfirmation).font(.system(size: 12))
                        }
                    }
                }
                .disabled(appState.terminalLog.isEmpty)
            }
        }
    }

    private func copyLog() {
        let joined = appState.terminalLog.joined(separator: "\n")
        UIPasteboard.general.string = joined
        copyConfirmation = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copyConfirmation = ""
        }
    }

    private func clearLog() {
        appState.clearLog()
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: () -> Void
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        // Set completion handler to hide the sheet after sharing
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                onComplete()
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
