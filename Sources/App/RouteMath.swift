import Foundation

// MARK: - Data

/// One point of a run's route. `t` is seconds since the workout started.
struct RoutePoint: Codable, Equatable {
    var lat: Double
    var lon: Double
    var alt: Double?
    var t: TimeInterval
    /// Metres per second from the GPS (nil when unknown).
    var speed: Double?

    private enum CodingKeys: String, CodingKey { case a, o, h, t, v }

    init(lat: Double, lon: Double, alt: Double? = nil, t: TimeInterval, speed: Double? = nil) {
        self.lat = lat; self.lon = lon; self.alt = alt; self.t = t; self.speed = speed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lat = try c.decode(Double.self, forKey: .a)
        lon = try c.decode(Double.self, forKey: .o)
        alt = try c.decodeIfPresent(Double.self, forKey: .h)
        t = try c.decode(Double.self, forKey: .t)
        speed = try c.decodeIfPresent(Double.self, forKey: .v)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // ~1 cm precision is plenty and keeps files small.
        try c.encode((lat * 1e7).rounded() / 1e7, forKey: .a)
        try c.encode((lon * 1e7).rounded() / 1e7, forKey: .o)
        if let alt { try c.encode((alt * 10).rounded() / 10, forKey: .h) }
        try c.encode((t * 10).rounded() / 10, forKey: .t)
        if let speed { try c.encode((speed * 100).rounded() / 100, forKey: .v) }
    }
}

/// One kilometre (or mile) of a run.
struct RunSplit: Codable, Equatable, Identifiable {
    var index: Int
    /// Metres covered (a full unit, or less for the final partial split).
    var meters: Double
    /// Moving seconds for this split.
    var seconds: Double
    var avgBPM: Int?
    /// Metres climbed minus descended.
    var elevation: Double?
    var id: Int { index }

    /// Seconds per km (or per mile when `unit` is a mile), scaled for partial splits.
    func pace(unit: Double) -> Double { meters > 0 ? seconds / meters * unit : 0 }
}

/// What a GPS run adds to a workout. The route itself is stored in its own compressed file.
struct RunSummary: Codable, Equatable {
    var distanceM: Double
    var movingSeconds: Double
    var elevationGain: Double
    var splits: [RunSplit]
    /// Where the position came from: "iPhone GPS", "External GPS", or a sensor name.
    var source: String
    var imperial: Bool
    var hasRoute: Bool

    var unitMeters: Double { imperial ? RouteMath.mile : 1000 }
    /// Seconds per km (or mile).
    var avgPace: Double { distanceM > 0 ? movingSeconds / distanceM * unitMeters : 0 }
}

// MARK: - Maths

enum RouteMath {
    static let mile = 1609.344
    private static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres.
    static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = p2 - p1, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h))
    }

    static func totalDistance(_ pts: [RoutePoint]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// "5:28" for a pace in seconds; "--:--" when stopped or unknown.
    static func paceText(_ secondsPerUnit: Double) -> String {
        guard secondsPerUnit.isFinite, secondsPerUnit > 60, secondsPerUnit < 60 * 30 else { return "--:--" }
        let s = Int(secondsPerUnit.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    static func distanceText(_ meters: Double, imperial: Bool) -> String {
        String(format: "%.2f", meters / (imperial ? mile : 1000))
    }

    /// Local flat projection (metres east / north of the first point). Fine for a run-sized area.
    static func project(_ pts: [RoutePoint]) -> [(x: Double, y: Double)] {
        guard let o = pts.first else { return [] }
        let k = cos(o.lat * .pi / 180)
        return pts.map { p in ((p.lon - o.lon) * .pi / 180 * earthRadius * k, (p.lat - o.lat) * .pi / 180 * earthRadius) }
    }

    /// Route points scaled into a unit box (0...1, y down), keeping the aspect ratio. For drawing.
    static func normalized(_ pts: [RoutePoint]) -> [CGPointValue] {
        let xy = project(pts)
        let xs = xy.map { $0.x }, ys = xy.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let span = max(maxX - minX, maxY - minY, 1)
        let ox = (span - (maxX - minX)) / 2, oy = (span - (maxY - minY)) / 2
        return xy.map { CGPointValue(x: (($0.x - minX) + ox) / span, y: 1 - (($0.y - minY) + oy) / span) }
    }

    /// Privacy zone, like Strava's: drops the first and last `meters` of a route so a shared map
    /// doesn't show where you live or train. Routes too short to trim safely come back empty.
    static func trimEnds(_ pts: [RoutePoint], meters: Double = 200) -> [RoutePoint] {
        guard pts.count >= 2, totalDistance(pts) > meters * 2.5 else { return [] }
        func firstIndexPast(_ list: [RoutePoint]) -> Int {
            var d = 0.0
            for i in 1..<list.count {
                d += distance(list[i - 1], list[i])
                if d >= meters { return i }
            }
            return list.count - 1
        }
        let start = firstIndexPast(pts)
        let end = pts.count - 1 - firstIndexPast(Array(pts.reversed()))
        guard end > start else { return [] }
        return Array(pts[start...end])
    }

    /// Ramer–Douglas–Peucker simplification (tolerance in metres), then at most one point per
    /// `minSpacing` metres. Keeps the shape of the route at a fraction of the points.
    static func simplify(_ pts: [RoutePoint], tolerance: Double = 2, minSpacing: Double = 5) -> [RoutePoint] {
        guard pts.count > 2 else { return pts }
        let xy = project(pts)
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let pair = stack.popLast() {
            let s = pair.0, e = pair.1
            guard e > s + 1 else { continue }
            let (ax, ay) = xy[s], (bx, by) = xy[e]
            let dx = bx - ax, dy = by - ay
            let len = max(1e-9, (dx * dx + dy * dy).squareRoot())
            var best = 0.0, bestIdx = s
            for i in (s + 1)..<e {
                let d = abs(dy * xy[i].x - dx * xy[i].y + bx * ay - by * ax) / len
                if d > best { best = d; bestIdx = i }
            }
            if best > tolerance {
                keep[bestIdx] = true
                stack.append((s, bestIdx))
                stack.append((bestIdx, e))
            }
        }
        var out: [RoutePoint] = []
        for (i, p) in pts.enumerated() where keep[i] {
            if let last = out.last, i != pts.count - 1, distance(last, p) < minSpacing { continue }
            out.append(p)
        }
        return out
    }

    /// 0 (slow) ... 4 (fast) per segment, relative to this run, for pace-coloured routes.
    static func paceBands(_ pts: [RoutePoint]) -> [Int] {
        guard pts.count >= 2 else { return [] }
        var speeds: [Double] = []
        for (a, b) in zip(pts, pts.dropFirst()) {
            let dt = b.t - a.t
            speeds.append(b.speed ?? (dt > 0 ? distance(a, b) / dt : 0))
        }
        // Smooth over ~5 segments so GPS jitter doesn't make a rainbow.
        let smooth = speeds.indices.map { i -> Double in
            let lo = max(0, i - 2), hi = min(speeds.count - 1, i + 2)
            return speeds[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        let sorted = smooth.sorted()
        let cuts = [0.2, 0.4, 0.6, 0.8].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
        return smooth.map { v in cuts.filter { v > $0 }.count }
    }

    /// Aerobic decoupling (%): how much pace-per-heartbeat fell from the first to the second half.
    /// Under 5% means the aerobic base held up.
    static func decoupling(_ splits: [RunSplit]) -> Double? {
        let full = splits.filter { $0.avgBPM != nil && $0.meters > 200 && $0.seconds > 0 }
        guard full.count >= 4 else { return nil }
        func efficiency(_ s: ArraySlice<RunSplit>) -> Double {
            let m = s.reduce(0) { $0 + $1.meters }, t = s.reduce(0) { $0 + $1.seconds }
            let hr = Double(s.compactMap(\.avgBPM).reduce(0, +)) / Double(s.count)
            return (m / t) / hr
        }
        let half = full.count / 2
        let a = efficiency(full[..<half]), b = efficiency(full[half...])
        return a > 0 ? (a - b) / a * 100 : nil
    }
}

/// A plain point (keeps RouteMath free of CoreGraphics so it can be unit tested anywhere).
struct CGPointValue: Equatable {
    var x: Double
    var y: Double
}

// MARK: - Live filters

/// Drops bad GPS fixes: poor accuracy, stale fixes, the first few settling seconds, and jumps
/// faster than a human can run.
struct GPSFilter {
    var maxAccuracy = 25.0
    var maxSpeed = 8.0          // m/s ≈ 29 km/h
    var settleSeconds = 3.0
    private(set) var last: RoutePoint?
    private var firstFix: TimeInterval?

    mutating func accept(_ p: RoutePoint, accuracy: Double) -> Bool {
        guard accuracy >= 0, accuracy <= maxAccuracy else { return false }
        if firstFix == nil { firstFix = p.t }
        if let f = firstFix, p.t - f < settleSeconds, accuracy > 10 { return false }
        if let l = last {
            let dt = p.t - l.t
            guard dt > 0 else { return false }
            if RouteMath.distance(l, p) / dt > maxSpeed { return false }
        }
        last = p
        return true
    }

    mutating func reset() {
        last = nil
        firstFix = nil
    }
}

/// Strava-style auto-pause: stopped for 6 s pauses, moving again resumes.
struct AutoPause {
    private(set) var isPaused = false
    private var slowSince: TimeInterval?

    /// Feed the latest speed (m/s) and time; returns true when the state changed.
    mutating func feed(speed: Double, t: TimeInterval) -> Bool {
        if isPaused {
            if speed > 1.0 {
                isPaused = false
                slowSince = nil
                return true
            }
            return false
        }
        if speed < 0.5 {
            if slowSince == nil { slowSince = t }
            if let s = slowSince, t - s >= 6 {
                isPaused = true
                return true
            }
        } else {
            slowSince = nil
        }
        return false
    }

    mutating func reset() {
        isPaused = false
        slowSince = nil
    }
}

/// Builds splits as distance accumulates.
struct SplitTracker {
    let unit: Double
    private(set) var splits: [RunSplit] = []
    private var startMoving = 0.0
    private var startAlt: Double?
    private var bpmSum = 0
    private var bpmCount = 0

    init(unit: Double) { self.unit = unit }

    mutating func addHeartRate(_ bpm: Int) {
        guard bpm > 0 else { return }
        bpmSum += bpm
        bpmCount += 1
    }

    /// Call after the distance changes. Returns a finished split when a unit boundary was crossed.
    mutating func update(distance: Double, moving: Double, altitude: Double?) -> RunSplit? {
        if startAlt == nil { startAlt = altitude }
        let done = Double(splits.count + 1) * unit
        guard distance >= done else { return nil }
        let split = RunSplit(index: splits.count + 1, meters: unit, seconds: max(1, moving - startMoving),
                             avgBPM: bpmCount > 0 ? bpmSum / bpmCount : nil,
                             elevation: zip2(altitude, startAlt).map { $0 - $1 })
        splits.append(split)
        startMoving = moving
        startAlt = altitude
        bpmSum = 0
        bpmCount = 0
        return split
    }

    /// The final partial split (if it's at least 100 m).
    mutating func finish(distance: Double, moving: Double, altitude: Double?) -> [RunSplit] {
        let rest = distance - Double(splits.count) * unit
        if rest >= 100 {
            splits.append(RunSplit(index: splits.count + 1, meters: rest, seconds: max(1, moving - startMoving),
                                   avgBPM: bpmCount > 0 ? bpmSum / bpmCount : nil,
                                   elevation: zip2(altitude, startAlt).map { $0 - $1 }))
        }
        return splits
    }

    private func zip2(_ a: Double?, _ b: Double?) -> (Double, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}

/// Climb with a 3 m dead band so GPS altitude noise doesn't add fake metres.
struct ElevationGain {
    private(set) var total = 0.0
    private var anchor: Double?

    mutating func feed(_ altitude: Double?) {
        guard let altitude else { return }
        guard let a = anchor else { anchor = altitude; return }
        if altitude - a >= 3 {
            total += altitude - a
            anchor = altitude
        } else if a - altitude >= 3 {
            anchor = altitude
        }
    }
}

// MARK: - Bluetooth run sensors (pure parsers)

/// Bluetooth SIG "Location and Navigation" (0x1819) and "Running Speed and Cadence" (0x1814)
/// measurements, as sent by external GPS receivers and foot pods.
enum RunSensorParser {
    struct LocationAndSpeed: Equatable {
        var speed: Double?         // m/s
        var totalDistance: Double? // m
        var lat: Double?
        var lon: Double?
        var elevation: Double?     // m
    }

    struct RunningSpeed: Equatable {
        var speed: Double          // m/s
        var cadence: Int           // steps per minute
        var totalDistance: Double? // m
    }

    /// Location and Speed characteristic (0x2A67).
    static func locationAndSpeed(_ d: [UInt8]) -> LocationAndSpeed? {
        guard d.count >= 2 else { return nil }
        let flags = UInt16(d[0]) | UInt16(d[1]) << 8
        var i = 2
        var out = LocationAndSpeed()
        func u16() -> UInt16? { guard i + 2 <= d.count else { return nil }; defer { i += 2 }; return UInt16(d[i]) | UInt16(d[i + 1]) << 8 }
        func u24() -> UInt32? { guard i + 3 <= d.count else { return nil }; defer { i += 3 }; return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 }
        func s32() -> Int32? {
            guard i + 4 <= d.count else { return nil }
            defer { i += 4 }
            return Int32(bitPattern: UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24)
        }
        if flags & 0x01 != 0, let v = u16() { out.speed = Double(v) / 100 }
        if flags & 0x02 != 0, let v = u24() { out.totalDistance = Double(v) / 10 }
        if flags & 0x04 != 0, let la = s32(), let lo = s32() {
            out.lat = Double(la) / 1e7
            out.lon = Double(lo) / 1e7
        }
        if flags & 0x08 != 0, let v = u24() {
            let signed = v & 0x800000 != 0 ? Int32(bitPattern: v | 0xFF000000) : Int32(v)
            out.elevation = Double(signed) / 100
        }
        return out
    }

    /// RSC Measurement characteristic (0x2A53).
    static func runningSpeed(_ d: [UInt8]) -> RunningSpeed? {
        guard d.count >= 4 else { return nil }
        let flags = d[0]
        let speed = Double(UInt16(d[1]) | UInt16(d[2]) << 8) / 256
        let cadence = Int(d[3])
        var i = 4
        if flags & 0x01 != 0 { i += 2 }   // stride length
        var total: Double?
        if flags & 0x02 != 0, i + 4 <= d.count {
            let v = UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
            total = Double(v) / 10
        }
        return RunningSpeed(speed: speed, cadence: cadence, totalDistance: total)
    }
}
