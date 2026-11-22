import Foundation

/// The FIGHT Logger: a small box on the heart-rate band that keeps every reading and sends the
/// seconds the phone missed. This is the message format it speaks (see Firmware/FightLogger).
enum LoggerProtocol {
    static let serviceUUID = "6F0A0001-5A3E-4D6B-9C1F-46494748540A"
    static let controlUUID = "6F0A0002-5A3E-4D6B-9C1F-46494748540A"
    static let dataUUID = "6F0A0003-5A3E-4D6B-9C1F-46494748540A"
    static let statusUUID = "6F0A0004-5A3E-4D6B-9C1F-46494748540A"

    struct Status: Equatable {
        var bandConnected: Bool
        var batteryPercent: Int
        var storedReadings: Int
        var clockSet: Bool
        var bandRSSI: Int
    }

    struct Reading: Equatable {
        let time: Date
        let bpm: Int
    }

    /// One data notification: some readings, or the end of a download.
    enum Packet: Equatable {
        case readings([Reading])
        case end(total: Int)
    }

    static func setClock(_ now: Date) -> Data {
        Data([0x01]) + le32(UInt32(max(0, now.timeIntervalSince1970)))
    }

    static func sendSince(_ since: Date) -> Data {
        Data([0x02]) + le32(UInt32(max(0, since.timeIntervalSince1970)))
    }

    static let forgetBand = Data([0x03])
    static let clearLog = Data([0x04])

    static func parseStatus(_ d: Data) -> Status? {
        let b = [UInt8](d)
        guard b.count >= 6 else { return nil }
        return Status(bandConnected: b[0] == 1,
                      batteryPercent: Int(b[1]),
                      storedReadings: Int(b[2]) | Int(b[3]) << 8,
                      clockSet: b[4] == 1,
                      bandRSSI: Int(Int8(bitPattern: b[5])))
    }

    static func parsePacket(_ d: Data) -> Packet? {
        let b = [UInt8](d)
        guard let kind = b.first else { return nil }
        if kind == 0xD2 {
            return .end(total: b.count >= 3 ? Int(b[1]) | Int(b[2]) << 8 : 0)
        }
        guard kind == 0xD1, b.count >= 2 else { return nil }
        let n = Int(b[1])
        guard b.count >= 2 + n * 5 else { return nil }
        var out: [Reading] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let p = 2 + i * 5
            let t = UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
            let bpm = Int(b[p + 4])
            guard bpm > 0 else { continue }
            out.append(Reading(time: Date(timeIntervalSince1970: TimeInterval(t)), bpm: bpm))
        }
        return .readings(out)
    }

    /// Readings that fill gaps: inside the session, and at least `spacing` seconds from every
    /// reading the phone already has. Sorted, one per second.
    static func gapFillers(_ readings: [Reading], existing: [Date], from start: Date, to end: Date,
                           spacing: TimeInterval = 1.5) -> [Reading] {
        let have = existing.sorted()
        var seen = Set<Int>()
        var out: [Reading] = []
        for r in readings.sorted(by: { $0.time < $1.time }) {
            guard r.time > start, r.time <= end else { continue }
            let key = Int(r.time.timeIntervalSince1970)
            guard !seen.contains(key) else { continue }
            if nearest(in: have, to: r.time) < spacing { continue }
            seen.insert(key)
            out.append(r)
        }
        return out
    }

    private static func nearest(in sorted: [Date], to t: Date) -> TimeInterval {
        guard !sorted.isEmpty else { return .infinity }
        var lo = 0, hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best = abs(sorted[lo].timeIntervalSince(t))
        if lo > 0 { best = min(best, abs(sorted[lo - 1].timeIntervalSince(t))) }
        return best
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}
