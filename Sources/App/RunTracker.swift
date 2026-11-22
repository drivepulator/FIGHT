import Foundation
import CoreLocation
import CoreBluetooth
import Observation

/// GPS run tracking: distance, pace, auto-pause, splits and the route.
///
/// Position sources, best first:
/// 1. A Bluetooth "Location and Navigation" GPS receiver (0x1819), used directly.
/// 2. iPhone location. External MFi GPS receivers (Garmin GLO, Bad Elf, Dual XGPS) feed this
///    automatically through iOS, and are labelled "External GPS".
/// A foot pod ("Running Speed and Cadence", 0x1814) fills in distance and pace whenever the GPS
/// signal drops (trees, tunnels, tall buildings).
@MainActor
@Observable
final class RunTracker {
    enum Signal: String { case searching = "Finding GPS", good = "GPS", weak = "Weak GPS" }

    private(set) var isActive = false
    private(set) var distanceM = 0.0
    private(set) var movingSeconds = 0.0
    private(set) var isPaused = false
    /// Seconds per km (or mile), smoothed over the last ~20 s of movement.
    private(set) var currentPace = 0.0
    private(set) var signal: Signal = .searching
    private(set) var source = "iPhone GPS"
    private(set) var splits: [RunSplit] = []
    private(set) var imperial = false
    private(set) var permissionDenied = false
    /// The workout is paused: keep tracking position but don't add distance.
    @ObservationIgnored var holdDistance = false
    /// After resuming an ended run: the first fix only sets the position (no jump in distance).
    @ObservationIgnored private var skipNextDistance = false

    /// Called when a km (or mile) is completed.
    @ObservationIgnored var onSplit: (@MainActor (RunSplit) -> Void)?
    /// Called on auto-pause (true) and resume (false).
    @ObservationIgnored var onPauseChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private(set) var points: [RoutePoint] = []
    @ObservationIgnored private var startDate = Date()
    @ObservationIgnored private var filter = GPSFilter()
    @ObservationIgnored private var autoPause = AutoPause()
    @ObservationIgnored private var splitTracker = SplitTracker(unit: 1000)
    @ObservationIgnored private var elevation = ElevationGain()
    @ObservationIgnored private var lastFixAt: TimeInterval = -100
    @ObservationIgnored private var lastExternalFixAt: TimeInterval = -100
    @ObservationIgnored private var paceWindow: [(t: TimeInterval, d: Double)] = []
    @ObservationIgnored private var lastAltitude: Double?

    private let location = CLLocationManager()
    private let delegate = LocationDelegate()
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    private let sensors = RunSensors()

    var unitMeters: Double { imperial ? RouteMath.mile : 1000 }
    var averagePace: Double { distanceM > 30 ? movingSeconds / distanceM * unitMeters : 0 }

    init() {
        location.delegate = delegate
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        delegate.onLocations = { [weak self] locs in self?.handle(locs) }
        delegate.onAuthorization = { [weak self] status in
            guard let self else { return }
            self.permissionDenied = status == .denied || status == .restricted
            if self.isActive, status == .authorizedWhenInUse || status == .authorizedAlways { self.beginUpdates() }
        }
        sensors.onLocation = { [weak self] fix in self?.handleExternal(fix) }
    }

    // MARK: Start / stop

    func start(at date: Date, imperial: Bool) {
        stop()
        startDate = date
        self.imperial = imperial
        isActive = true
        distanceM = 0
        movingSeconds = 0
        isPaused = false
        currentPace = 0
        signal = .searching
        source = "iPhone GPS"
        splits = []
        points = []
        paceWindow = []
        lastAltitude = nil
        lastFixAt = -100
        lastExternalFixAt = -100
        filter.reset()
        autoPause.reset()
        splitTracker = SplitTracker(unit: unitMeters)
        elevation = ElevationGain()
        sensors.start()
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .denied, .restricted: permissionDenied = true
        default: beginUpdates()
        }
    }

    private func beginUpdates() {
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        backgroundSession = CLBackgroundActivitySession()
        location.startUpdatingLocation()
    }

    /// Carry on a run that was ended by mistake, keeping its distance, splits and route.
    func resumeAfterFinish() {
        guard !isActive else { return }
        isActive = true
        skipNextDistance = true
        sensors.start()
        if !permissionDenied { beginUpdates() }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        sensors.stop()
    }

    /// Ends the run and returns its summary and simplified route (nil if it never moved).
    func finish() -> (summary: RunSummary, route: [RoutePoint])? {
        let wasActive = isActive
        stop()
        guard wasActive, distanceM >= 50 || !points.isEmpty else { return nil }
        // Work on a copy: the final partial split must not stay in the tracker in case the run is resumed.
        var closing = splitTracker
        let final = closing.finish(distance: distanceM, moving: movingSeconds, altitude: lastAltitude)
        let route = RouteMath.simplify(points)
        let summary = RunSummary(distanceM: distanceM, movingSeconds: movingSeconds, elevationGain: elevation.total,
                                 splits: final, source: source, imperial: imperial, hasRoute: route.count >= 2)
        return (summary, route)
    }

    /// The run so far (for crash-safe drafts).
    var snapshot: (summary: RunSummary, route: [RoutePoint])? {
        guard isActive else { return nil }
        return (RunSummary(distanceM: distanceM, movingSeconds: movingSeconds, elevationGain: elevation.total,
                           splits: splits, source: source, imperial: imperial, hasRoute: points.count >= 2), points)
    }

    // MARK: Per-second clock (called by the workout session)

    func tick(dt: TimeInterval, bpm: Int, elapsed: TimeInterval) {
        guard isActive else { return }
        if elapsed - lastFixAt > 6, signal == .good { signal = .weak }

        // GPS gone quiet: bridge distance with the foot pod, if there is one.
        let gpsQuiet = elapsed - max(lastFixAt, lastExternalFixAt) > 5
        if gpsQuiet, let pod = sensors.podSpeed, sensors.podFresh {
            updatePause(speed: pod, t: elapsed)
            if !isPaused {
                addDistance(pod * dt, at: elapsed)
                if source == "iPhone GPS" { source = "\(sensors.podName) (foot pod)" }
            }
        }
        if !isPaused { movingSeconds += dt }
        splitTracker.addHeartRate(bpm)
        updateSplits()
    }

    // MARK: Location input

    private func handle(_ locations: [CLLocation]) {
        guard isActive else { return }
        for loc in locations {
            let t = loc.timestamp.timeIntervalSince(startDate)
            // A Bluetooth GPS receiver is talking: it wins over the phone.
            if t - lastExternalFixAt < 3 { continue }
            guard loc.horizontalAccuracy >= 0 else { continue }
            if loc.sourceInformation?.isProducedByAccessory == true { source = "External GPS" }
            let p = RoutePoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                               alt: loc.verticalAccuracy >= 0 && loc.verticalAccuracy <= 15 ? loc.altitude : nil,
                               t: t, speed: loc.speed >= 0 ? loc.speed : nil)
            signal = loc.horizontalAccuracy <= 20 ? .good : .weak
            accept(p, accuracy: loc.horizontalAccuracy)
        }
    }

    private func handleExternal(_ fix: RunSensorParser.LocationAndSpeed) {
        guard isActive, let lat = fix.lat, let lon = fix.lon else { return }
        let t = Date().timeIntervalSince(startDate)
        lastExternalFixAt = t
        source = sensors.gpsName
        signal = .good
        accept(RoutePoint(lat: lat, lon: lon, alt: fix.elevation, t: t, speed: fix.speed), accuracy: 5)
    }

    private func accept(_ p: RoutePoint, accuracy: Double) {
        let previous = filter.last
        guard filter.accept(p, accuracy: accuracy) else { return }
        lastFixAt = p.t
        // Paused: remember where we are (so resuming doesn't add the gap) but count nothing.
        if holdDistance { return }
        if skipNextDistance {
            skipNextDistance = false
            points.append(p)
            return
        }
        let speed = p.speed ?? previous.map { RouteMath.distance($0, p) / max(0.5, p.t - $0.t) } ?? 0
        _ = updatePause(speed: speed, t: p.t)
        points.append(p)
        elevation.feed(p.alt)
        if p.alt != nil { lastAltitude = p.alt }
        if let previous, !isPaused {
            addDistance(RouteMath.distance(previous, p), at: p.t)
        }
    }

    @discardableResult
    private func updatePause(speed: Double, t: TimeInterval) -> Bool {
        guard autoPause.feed(speed: speed, t: t) else { return false }
        isPaused = autoPause.isPaused
        onPauseChange?(isPaused)
        return true
    }

    private func addDistance(_ d: Double, at t: TimeInterval) {
        guard d > 0 else { return }
        distanceM += d
        paceWindow.append((t, distanceM))
        paceWindow.removeAll { t - $0.t > 20 }
        if let first = paceWindow.first, distanceM - first.d > 10, t - first.t > 4 {
            currentPace = (t - first.t) / (distanceM - first.d) * unitMeters
        }
        updateSplits()
    }

    private func updateSplits() {
        if let split = splitTracker.update(distance: distanceM, moving: movingSeconds, altitude: lastAltitude) {
            splits = splitTracker.splits
            onSplit?(split)
        }
    }
}

/// CoreLocation's delegate lives in a plain NSObject so the tracker can stay @Observable.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocations: (@MainActor ([CLLocation]) -> Void)?
    var onAuthorization: (@MainActor (CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let handler = onLocations
        MainActor.assumeIsolated { handler?(locations) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let handler = onAuthorization
        MainActor.assumeIsolated { handler?(status) }
    }
}

// MARK: - Bluetooth GPS receivers and foot pods

/// Finds a Bluetooth GPS receiver (Location and Navigation) or a foot pod (Running Speed and
/// Cadence) while a run is recording. Sensors already connected to the phone (e.g. a strap that
/// also measures running speed) are picked up too.
private final class RunSensors: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let lns = CBUUID(string: "1819")
    static let rsc = CBUUID(string: "1814")
    static let lnsMeasurement = CBUUID(string: "2A67")
    static let rscMeasurement = CBUUID(string: "2A53")

    var onLocation: (@MainActor (RunSensorParser.LocationAndSpeed) -> Void)?
    private(set) var podSpeed: Double?
    private(set) var podUpdated = Date.distantPast
    private(set) var podName = "Foot pod"
    private(set) var gpsName = "Bluetooth GPS"
    var podFresh: Bool { Date().timeIntervalSince(podUpdated) < 4 }

    private var central: CBCentralManager?
    private var peripherals: [CBPeripheral] = []
    private var running = false
    private var scanStopper: DispatchWorkItem?

    /// Your own sensors: once FIGHT has used a foot pod or GPS receiver, it's remembered and
    /// reconnected; nobody else's device is picked up by accident at a group session.
    private static let rememberedKey = "fight.run.sensors"
    private var remembered: [UUID] {
        get { (UserDefaults.standard.stringArray(forKey: Self.rememberedKey) ?? []).compactMap(UUID.init) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.rememberedKey) }
    }
    /// A new device must be this close (on your shoe or arm) to be adopted.
    static let adoptRSSI = -50

    func start() {
        running = true
        if let central {
            if central.state == .poweredOn { scan(central) }
        } else {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stop() {
        running = false
        scanStopper?.cancel()
        scanStopper = nil
        central?.stopScan()
        for p in peripherals { central?.cancelPeripheralConnection(p) }
        peripherals.removeAll()
        podSpeed = nil
    }

    private func scan(_ c: CBCentralManager) {
        guard running else { return }
        // Already connected to this phone, or used before: these are yours.
        for p in c.retrieveConnectedPeripherals(withServices: [Self.lns, Self.rsc]) { connect(p, c) }
        for p in c.retrievePeripherals(withIdentifiers: remembered) { connect(p, c) }
        c.scanForPeripherals(withServices: [Self.lns, Self.rsc], options: nil)
        // Stop looking after 20 s: if nothing's around, don't keep the radio busy. This run's timer
        // only (an old one from an earlier run can't cut a new search short).
        scanStopper?.cancel()
        let stopper = DispatchWorkItem { [weak self] in self?.central?.stopScan() }
        scanStopper = stopper
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: stopper)
    }

    private func connect(_ p: CBPeripheral, _ c: CBCentralManager) {
        guard !peripherals.contains(where: { $0.identifier == p.identifier }) else { return }
        peripherals.append(p)
        p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan(central) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let known = remembered.contains(peripheral.identifier)
        // A device nobody has used here before is only adopted when it's right next to the phone.
        guard known || (RSSI.intValue >= Self.adoptRSSI && RSSI.intValue < 0) else { return }
        connect(peripheral, central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.lns, Self.rsc])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([Self.lnsMeasurement, Self.rscMeasurement], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] where ch.uuid == Self.lnsMeasurement || ch.uuid == Self.rscMeasurement {
            peripheral.setNotifyValue(true, for: ch)
            if !remembered.contains(peripheral.identifier) { remembered = remembered + [peripheral.identifier] }
            if ch.uuid == Self.lnsMeasurement { gpsName = peripheral.name ?? "Bluetooth GPS" }
            if ch.uuid == Self.rscMeasurement { podName = peripheral.name ?? "Foot pod" }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        if characteristic.uuid == Self.rscMeasurement, let m = RunSensorParser.runningSpeed(bytes) {
            podSpeed = m.speed
            podUpdated = Date()
        } else if characteristic.uuid == Self.lnsMeasurement, let fix = RunSensorParser.locationAndSpeed(bytes) {
            let handler = onLocation
            MainActor.assumeIsolated { handler?(fix) }
        }
    }
}
