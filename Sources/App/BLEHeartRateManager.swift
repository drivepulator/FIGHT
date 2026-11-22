import Foundation
import CoreBluetooth
import SwiftUI

/// Where the sensor sits on the body (Bluetooth Body Sensor Location, 0x2A38).
enum SensorBodyLocation: UInt8 {
    case other = 0, chest, wrist, finger, hand, earLobe, foot

    var label: String {
        switch self {
        case .other: return "Other"
        case .chest: return "Chest strap"
        case .wrist: return "Wrist / arm"
        case .finger: return "Finger"
        case .hand: return "Hand"
        case .earLobe: return "Ear"
        case .foot: return "Foot"
        }
    }

    /// Electrical (ECG) chest straps give the cleanest beat-to-beat data.
    var isChest: Bool { self == .chest }
}

/// What we know about the connected sensor, used for display and Apple Health.
struct SensorInfo: Equatable {
    var name: String
    var manufacturer: String?
    var model: String?
    var bodyLocation: SensorBodyLocation?

    var detailLine: String {
        [manufacturer, model, bodyLocation?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

struct DiscoveredHRDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
    /// True when the device advertises the Heart Rate service or is already connected to iOS with it.
    let advertisesHeartRate: Bool
    /// True when the name looks like a heart-rate sensor even without the service advertised.
    let looksLikeHeartRate: Bool

    var isLikelyHeartRate: Bool { advertisesHeartRate || looksLikeHeartRate }

    static func == (lhs: DiscoveredHRDevice, rhs: DiscoveredHRDevice) -> Bool {
        lhs.id == rhs.id && lhs.rssi == rhs.rssi && lhs.name == rhs.name && lhs.advertisesHeartRate == rhs.advertisesHeartRate
    }

    var signalBars: Int {
        switch rssi {
        case (-60)...: return 3
        case (-75)..<(-60): return 2
        default: return 1
        }
    }
}

/// Works with any monitor implementing the standard Bluetooth Heart Rate Profile:
/// chest straps, optical armbands, and watches in heart-rate broadcast mode.
@MainActor
final class BLEHeartRateManager: NSObject, ObservableObject {
    @Published var isBluetoothPoweredOn = false
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectedDeviceName: String = "Heart Rate Monitor"
    @Published var sensorInfo: SensorInfo?
    @Published var statusMessage: String = "Ready to scan for heart rate monitors"
    @Published var currentBPM: Int = 0
    @Published var batteryLevel: Int?
    @Published var sensorContactDetected: Bool?
    @Published var isSignalLost = false
    @Published var discoveredDevices: [DiscoveredHRDevice] = []
    @Published var connectionError: String?
    /// Connected to a FIGHT Logger (which relays the band and keeps every reading).
    @Published var isLogger = false
    /// The logger's latest report: is the band connected, its battery, readings stored.
    @Published var loggerStatus: LoggerProtocol.Status?
    /// Called with the readings a logger sent back after a gap.
    var onLoggerReadings: (([LoggerProtocol.Reading]) -> Void)?
    private var loggerControl: CBCharacteristic?
    private var loggerIncoming: [LoggerProtocol.Reading] = []
    private var loggerDownloading = false
    private var loggerRequestedAt: Date?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var latestRRBuffer: [Double] = []
    private var lastValidPacket: Date?
    private var connectStartedAt: Date?
    private var watchdog: Timer?
    private var hasHeartRateService = false
    private let lastDeviceUUIDKey = "fight_last_device_uuid_v1"

    // Standard Bluetooth SIG UUIDs
    nonisolated private let hrServiceUUID = CBUUID(string: "180D")
    nonisolated private let hrMeasurementUUID = CBUUID(string: "2A37")
    nonisolated private let bodyLocationUUID = CBUUID(string: "2A38")
    nonisolated private let batteryServiceUUID = CBUUID(string: "180F")
    nonisolated private let batteryLevelUUID = CBUUID(string: "2A19")
    nonisolated private let deviceInfoServiceUUID = CBUUID(string: "180A")
    nonisolated private let manufacturerUUID = CBUUID(string: "2A29")
    nonisolated private let modelUUID = CBUUID(string: "2A24")

    /// Name fragments used by common heart-rate sensors and watches that don't
    /// always advertise the Heart Rate service until connected.
    private static let heartRateNameHints = [
        "hrm", "heart", "pulse", "polar", "garmin", "wahoo", "tickr", "whoop", "suunto", "coros",
        "scosche", "rhythm", "verity", "magene", "igpsport", "amazfit", "zepp", "xoss", "moofit",
        "cycplus", "kalenji", "geonaute", "decathlon", "chileaf", "bryton", "lezyne", "myzone",
        "fitcare", "beat", "h10", "h9", "h7", "h6", "oh1", "armband", "strap"
    ]

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.shon.fight.blecentral"
        ])
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    // MARK: Public API

    /// Scans for every nearby BLE device. Devices advertising the Heart Rate
    /// service (or whose name looks like a sensor) are ranked first; the rest
    /// are available via "Show all devices" for monitors that hide the service.
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            statusMessage = "Turn on Bluetooth in iOS Settings"
            return
        }
        discoveredDevices.removeAll()
        connectionError = nil
        isScanning = true
        statusMessage = "Scanning for heart rate monitors…"

        // Sensors already connected to iOS (or another app) don't advertise.
        for p in centralManager.retrieveConnectedPeripherals(withServices: [hrServiceUUID]) {
            addOrUpdateDevice(peripheral: p, rssi: -50, advertisesHR: true)
        }

        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        if !isConnected && !isConnecting {
            statusMessage = discoveredDevices.isEmpty ? "Tap Scan to find your heart rate monitor" : "Select your heart rate monitor"
        }
    }

    func connect(to device: DiscoveredHRDevice) {
        stopScanning()
        if let current = connectedPeripheral, current.identifier != device.id {
            centralManager.cancelPeripheralConnection(current)
        }
        connectionError = nil
        isConnecting = true
        connectStartedAt = Date()
        hasHeartRateService = false
        statusMessage = "Connecting to \(device.name)…"
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        sensorInfo = SensorInfo(name: device.name)
        UserDefaults.standard.set(device.id.uuidString, forKey: lastDeviceUUIDKey)
        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: lastDeviceUUIDKey)
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        connectedPeripheral = nil
        sensorInfo = nil
        cleanupConnection(message: "Disconnected")
    }

    func consumeLatestRRIntervals() -> [Double] {
        let copy = latestRRBuffer
        latestRRBuffer.removeAll()
        return copy
    }

    // MARK: Internals

    private func watchdogTick() {
        // Connection attempts that never complete (sensor asleep / out of range).
        if isConnecting, let started = connectStartedAt, Date().timeIntervalSince(started) > 15 {
            if let p = connectedPeripheral { centralManager.cancelPeripheralConnection(p) }
            isConnecting = false
            connectStartedAt = nil
            connectionError = "Couldn't reach the sensor. Wake it up (wear it or moisten the pads) and try again."
            statusMessage = "Connection timed out"
            return
        }
        // Connected, but the sensor stopped sending heart rate: clear the stale value
        // so it isn't recorded as if it were live.
        guard isConnected, hasHeartRateService else { return }
        let silentFor = lastValidPacket.map { Date().timeIntervalSince($0) } ?? .infinity
        if silentFor > 5 {
            if currentBPM != 0 { currentBPM = 0 }
            if !isSignalLost {
                isSignalLost = true
                statusMessage = "Connected • no heart-rate signal"
            }
        }
    }

    private func addOrUpdateDevice(peripheral: CBPeripheral, rssi: Int, advertisesHR: Bool, advertisedName: String? = nil) {
        let rawName = peripheral.name ?? advertisedName
        let name = (rawName?.isEmpty == false ? rawName : nil) ?? (advertisesHR ? "Heart Rate Monitor" : "Unnamed device")
        let lower = name.lowercased()
        let looksHR = Self.heartRateNameHints.contains { lower.contains($0) }
            || lower.range(of: #"\bhr\b"#, options: .regularExpression) != nil

        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            let old = discoveredDevices[idx]
            let mergedAdvertises = old.advertisesHeartRate || advertisesHR
            // Throttle UI churn from duplicate advertisements.
            guard abs(old.rssi - rssi) >= 4 || mergedAdvertises != old.advertisesHeartRate || old.name != name else { return }
            discoveredDevices[idx] = DiscoveredHRDevice(id: peripheral.identifier, name: name, rssi: rssi, peripheral: peripheral,
                                                        advertisesHeartRate: mergedAdvertises, looksLikeHeartRate: looksHR)
        } else {
            // Ignore anonymous devices that give no hint of being a sensor.
            guard rawName != nil || advertisesHR else { return }
            discoveredDevices.append(DiscoveredHRDevice(id: peripheral.identifier, name: name, rssi: rssi, peripheral: peripheral,
                                                        advertisesHeartRate: advertisesHR, looksLikeHeartRate: looksHR))
        }
        discoveredDevices.sort {
            if $0.isLikelyHeartRate != $1.isLikelyHeartRate { return $0.isLikelyHeartRate }
            return $0.rssi > $1.rssi
        }
    }

    private func cleanupConnection(message: String) {
        isLogger = false
        loggerStatus = nil
        loggerControl = nil
        loggerIncoming = []
        loggerDownloading = false
        isConnected = false
        isConnecting = false
        connectStartedAt = nil
        hasHeartRateService = false
        currentBPM = 0
        batteryLevel = nil
        sensorContactDetected = nil
        isSignalLost = false
        lastValidPacket = nil
        statusMessage = message
    }

    private func parseHeartRatePacket(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }

        let flags = bytes[0]
        let is16BitBPM = (flags & 0x01) != 0
        let contactSupported = (flags & 0x04) != 0
        let contactDetected = (flags & 0x02) != 0
        let energyExpendedPresent = (flags & 0x08) != 0
        let rrIntervalsPresent = (flags & 0x10) != 0

        if contactSupported {
            sensorContactDetected = contactDetected
        }

        var offset = 1
        let bpm: Int
        if is16BitBPM {
            guard bytes.count >= offset + 2 else { return }
            bpm = Int(UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
            offset += 2
        } else {
            bpm = Int(bytes[offset])
            offset += 1
        }

        if bpm > 25 && bpm < 250 {
            currentBPM = bpm
            lastValidPacket = Date()
            if isSignalLost {
                isSignalLost = false
                statusMessage = "Connected • Streaming HR"
            }
        } else if bpm == 0 {
            // Many sensors send 0 when they can't get a reading (e.g. strap off).
            currentBPM = 0
        }

        if energyExpendedPresent {
            offset += 2
        }

        if rrIntervalsPresent {
            while offset + 1 < bytes.count {
                let rawRR = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let rrMs = (Double(rawRR) / 1024.0) * 1000.0
                if rrMs >= 280 && rrMs <= 2000 {
                    latestRRBuffer.append(rrMs)
                }
                offset += 2
            }
            // Nothing drains the buffer while idle, so keep only the last ~5 minutes.
            if latestRRBuffer.count > 600 {
                latestRRBuffer.removeFirst(latestRRBuffer.count - 600)
            }
        }
    }

    private func handleConnected(_ peripheral: CBPeripheral) {
        isConnecting = false
        connectStartedAt = nil
        isConnected = true
        connectedDeviceName = peripheral.name ?? sensorInfo?.name ?? "Heart Rate Monitor"
        if sensorInfo == nil || sensorInfo?.name != connectedDeviceName {
            sensorInfo = SensorInfo(name: connectedDeviceName)
        }
        statusMessage = "Connected • finding heart rate…"
        peripheral.discoverServices([hrServiceUUID, batteryServiceUUID, deviceInfoServiceUUID])
    }

    private func handleServices(_ peripheral: CBPeripheral) {
        let services = peripheral.services ?? []
        guard services.contains(where: { $0.uuid == hrServiceUUID }) else {
            // Connected to something that isn't a heart-rate sensor.
            let name = peripheral.name ?? "This device"
            if UserDefaults.standard.string(forKey: lastDeviceUUIDKey) == peripheral.identifier.uuidString {
                UserDefaults.standard.removeObject(forKey: lastDeviceUUIDKey)
            }
            centralManager.cancelPeripheralConnection(peripheral)
            connectedPeripheral = nil
            sensorInfo = nil
            cleanupConnection(message: "Not a heart rate monitor")
            connectionError = "\(name) doesn't provide heart-rate data. If it's a watch, turn on its heart-rate broadcast mode and scan again."
            return
        }
        hasHeartRateService = true
        lastValidPacket = Date() // give the sensor 5 s before flagging no signal
        statusMessage = "Connected • Streaming HR"
        for service in services {
            if service.uuid == hrServiceUUID {
                peripheral.discoverCharacteristics([hrMeasurementUUID, bodyLocationUUID], for: service)
            } else if service.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
            } else if service.uuid == deviceInfoServiceUUID {
                peripheral.discoverCharacteristics([manufacturerUUID, modelUUID], for: service)
            } else if service.uuid == CBUUID(string: LoggerProtocol.serviceUUID) {
                isLogger = true
                peripheral.discoverCharacteristics([CBUUID(string: LoggerProtocol.controlUUID),
                                                    CBUUID(string: LoggerProtocol.dataUUID),
                                                    CBUUID(string: LoggerProtocol.statusUUID)], for: service)
            }
        }
    }

    private func handleValue(uuid: CBUUID, data: Data) {
        switch uuid {
        case hrMeasurementUUID:
            parseHeartRatePacket(data)
        case batteryLevelUUID:
            if let b = data.first { batteryLevel = Int(b) }
        case bodyLocationUUID:
            if let b = data.first { sensorInfo?.bodyLocation = SensorBodyLocation(rawValue: b) ?? .other }
        case manufacturerUUID:
            sensorInfo?.manufacturer = Self.cleanString(data)
        case modelUUID:
            sensorInfo?.model = Self.cleanString(data)
        case CBUUID(string: LoggerProtocol.statusUUID):
            loggerStatus = LoggerProtocol.parseStatus(data)
        case CBUUID(string: LoggerProtocol.dataUUID):
            handleLoggerPacket(data)
        default:
            break
        }
    }

    // MARK: FIGHT Logger

    private func loggerReady(control: CBCharacteristic) {
        loggerControl = control
        isLogger = true
        // The logger has no clock of its own: give it the time on every connect.
        writeLogger(LoggerProtocol.setClock(Date()))
    }

    private func writeLogger(_ data: Data) {
        guard let peripheral = connectedPeripheral, let control = loggerControl else { return }
        peripheral.writeValue(data, for: control, type: .withResponse)
    }

    /// Ask the logger for every reading after `since` (the start of a gap).
    func requestLoggerReadings(since: Date) {
        guard isLogger else { return }
        // One download at a time (a stuck one is given up after 20 s).
        if loggerDownloading, let at = loggerRequestedAt, Date().timeIntervalSince(at) < 20 { return }
        loggerDownloading = true
        loggerRequestedAt = Date()
        loggerIncoming = []
        writeLogger(LoggerProtocol.sendSince(since))
    }

    /// Pair the logger with a different band (the closest one it finds).
    func loggerForgetBand() {
        writeLogger(LoggerProtocol.forgetBand)
    }

    private func handleLoggerPacket(_ data: Data) {
        switch LoggerProtocol.parsePacket(data) {
        case .readings(let r):
            loggerIncoming.append(contentsOf: r)
        case .end:
            let readings = loggerIncoming
            loggerIncoming = []
            loggerDownloading = false
            if !readings.isEmpty { onLoggerReadings?(readings) }
        case nil:
            break
        }
    }

    private static func cleanString(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension BLEHeartRateManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            isBluetoothPoweredOn = (central.state == .poweredOn)
            switch central.state {
            case .poweredOn:
                if isConnected { return }
                statusMessage = "Bluetooth ready"
                // Auto-reconnect to the last used sensor.
                if let savedStr = UserDefaults.standard.string(forKey: lastDeviceUUIDKey),
                   let savedUUID = UUID(uuidString: savedStr),
                   let known = central.retrievePeripherals(withIdentifiers: [savedUUID]).first {
                    connectedPeripheral = known
                    connectedPeripheral?.delegate = self
                    sensorInfo = SensorInfo(name: known.name ?? "Heart Rate Monitor")
                    isConnecting = true
                    connectStartedAt = Date()
                    statusMessage = "Reconnecting to \(known.name ?? "your sensor")…"
                    central.connect(known, options: nil)
                }
            case .unauthorized:
                isScanning = false
                cleanupConnection(message: "Allow Bluetooth for FIGHT in iOS Settings")
            default:
                isScanning = false
                cleanupConnection(message: "Bluetooth is off")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = peripherals.first {
            Task { @MainActor in
                self.connectedPeripheral = first
                self.connectedPeripheral?.delegate = self
                if first.state == .connected {
                    self.handleConnected(first)
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssiVal = RSSI.intValue
        guard rssiVal != 127 else { return }
        let hrUUID = CBUUID(string: "180D")
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflow = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let advertisesHR = advertised.contains(hrUUID) || overflow.contains(hrUUID)
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        Task { @MainActor in
            addOrUpdateDevice(peripheral: peripheral, rssi: rssiVal, advertisesHR: advertisesHR, advertisedName: advName)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            handleConnected(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            cleanupConnection(message: "Couldn't connect")
            connectionError = "Couldn't connect to \(peripheral.name ?? "the sensor"). Wake it up (wear it or moisten the pads) and make sure no other app is using it."
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let wasSaved = UserDefaults.standard.string(forKey: lastDeviceUUIDKey) == peripheral.identifier.uuidString
            cleanupConnection(message: wasSaved ? "Signal lost — reconnecting…" : "Disconnected")
            // Automatic reconnect if the sensor briefly drops (iOS keeps trying indefinitely).
            if wasSaved {
                centralManager.connect(peripheral, options: nil)
            }
        }
    }
}

extension BLEHeartRateManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            handleServices(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        let hrMeasurement = CBUUID(string: "2A37")
        let battery = CBUUID(string: "2A19")
        let readOnce: Set<CBUUID> = [CBUUID(string: "2A38"), CBUUID(string: "2A29"), CBUUID(string: "2A24")]
        let loggerControl = CBUUID(string: LoggerProtocol.controlUUID)
        let loggerData = CBUUID(string: LoggerProtocol.dataUUID)
        let loggerStatus = CBUUID(string: LoggerProtocol.statusUUID)
        for ch in chars {
            if ch.uuid == hrMeasurement {
                peripheral.setNotifyValue(true, for: ch)
            } else if ch.uuid == battery {
                peripheral.readValue(for: ch)
                if ch.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: ch)
                }
            } else if readOnce.contains(ch.uuid) {
                peripheral.readValue(for: ch)
            } else if ch.uuid == loggerData {
                peripheral.setNotifyValue(true, for: ch)
            } else if ch.uuid == loggerStatus {
                peripheral.setNotifyValue(true, for: ch)
                peripheral.readValue(for: ch)
            } else if ch.uuid == loggerControl {
                Task { @MainActor in self.loggerReady(control: ch) }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            handleValue(uuid: uuid, data: data)
        }
    }
}

// MARK: - Sensor picker

struct DeviceScannerSheet: View {
    @State private var confirmingDisconnect = false
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAllDevices = false

    private var heartRateDevices: [DiscoveredHRDevice] {
        bleManager.discoveredDevices.filter { $0.isLikelyHeartRate && $0.id != bleManager.sensorInfoPeripheralID }
    }

    private var otherDevices: [DiscoveredHRDevice] {
        bleManager.discoveredDevices.filter { !$0.isLikelyHeartRate }
    }

    var body: some View {
        NavigationStack {
            List {
                if bleManager.isConnected {
                    Section("Connected") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "heart.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(bleManager.isSignalLost ? .orange : .red)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bleManager.connectedDeviceName)
                                        .font(.headline)
                                    if let detail = bleManager.sensorInfo?.detailLine, !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if bleManager.currentBPM > 0 {
                                    Text("\(bleManager.currentBPM) BPM")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.red)
                                }
                            }
                            HStack(spacing: 12) {
                                Text(bleManager.statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(bleManager.isSignalLost ? .orange : .green)
                                if let battery = bleManager.batteryLevel {
                                    Label("\(battery)%", systemImage: battery > 20 ? "battery.75" : "battery.25")
                                        .font(.caption)
                                        .foregroundStyle(battery > 20 ? Color.secondary : Color.orange)
                                }
                            }
                            if bleManager.isLogger {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let s = bleManager.loggerStatus {
                                        Label(s.bandConnected ? "Band connected to the logger" : "Logger can't find your band",
                                              systemImage: s.bandConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(s.bandConnected ? Color.green : Color.orange)
                                    }
                                    Text("The logger keeps every reading. If your phone drops out, the missed time is filled in with real data when it reconnects.")
                                        .foregroundStyle(.secondary)
                                    Button("Pair the logger with a different band") { bleManager.loggerForgetBand() }
                                        .controlSize(.small)
                                }
                                .font(.caption)
                            }
                            Button("Disconnect", role: .destructive) {
                                if WorkoutSession.shared?.isRecording == true {
                                    confirmingDisconnect = true
                                } else {
                                    bleManager.disconnect()
                                }
                            }
                            .confirmationDialog("Stop heart-rate recording?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                                Button("Disconnect", role: .destructive) { bleManager.disconnect() }
                                Button("Keep Connected", role: .cancel) {}
                            } message: {
                                Text("A workout is running. Without the strap, the rest of it is recorded without heart rate.")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let error = bleManager.connectionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if heartRateDevices.isEmpty {
                        HStack {
                            if bleManager.isScanning {
                                ProgressView().padding(.trailing, 8)
                            }
                            Text(bleManager.isScanning ? "Searching for heart rate monitors…" : "No monitors found")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(heartRateDevices) { device in
                            deviceRow(device)
                        }
                    }
                } header: {
                    Text("Heart Rate Monitors")
                } footer: {
                    Text("Works with any Bluetooth heart rate monitor: chest straps, armbands, and watches with heart-rate broadcast turned on. Wear the sensor so it wakes up, and close other apps that may be connected to it.")
                }

                Section {
                    Toggle("Show all nearby devices", isOn: $showAllDevices)
                    if showAllDevices {
                        if otherDevices.isEmpty {
                            Text("No other named devices nearby")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(otherDevices) { device in
                                deviceRow(device)
                            }
                        }
                    }
                } footer: {
                    Text("Some sensors only reveal their heart-rate service after connecting. If yours isn't listed above, find it here. FIGHT checks it and tells you if it doesn't provide heart rate.")
                }
            }
            .navigationTitle("Heart Rate Sensors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(bleManager.isScanning ? "Stop" : "Scan") {
                        if bleManager.isScanning {
                            bleManager.stopScanning()
                        } else {
                            bleManager.startScanning()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        bleManager.stopScanning()
                        dismiss()
                    }
                }
            }
            .onAppear {
                bleManager.startScanning()
            }
            .onDisappear {
                bleManager.stopScanning()
            }
        }
    }

    private func deviceRow(_ device: DiscoveredHRDevice) -> some View {
        Button {
            bleManager.connect(to: device)
        } label: {
            HStack {
                Image(systemName: device.isLikelyHeartRate ? "heart.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(device.isLikelyHeartRate ? .red : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(device.advertisesHeartRate ? "Heart rate sensor" : (device.looksLikeHeartRate ? "Possible heart rate sensor" : "Unknown device"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if bleManager.isConnecting && bleManager.sensorInfo?.name == device.name {
                    ProgressView()
                } else {
                    Image(systemName: "cellularbars", variableValue: Double(device.signalBars) / 3.0)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Signal \(device.signalBars) of 3")
                }
            }
        }
        .accessibilityHint("Connects to this sensor")
    }
}

extension BLEHeartRateManager {
    /// Identifier of the connected sensor, so it isn't listed twice in the picker.
    var sensorInfoPeripheralID: UUID? {
        isConnected ? connectedPeripheral?.identifier : nil
    }
}
