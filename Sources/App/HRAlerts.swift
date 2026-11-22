import Foundation

/// The heart rate a session should sit in. A nil bound means "no limit that way".
struct HRTarget: Equatable {
    var low: Int?
    var high: Int?
    /// Shown on the live screen, e.g. "Zone 2 · 128–142".
    var label: String
}

enum HRTargetRules {
    /// The target for a kind of session, from your zones.
    static func target(drill: DrillTag, category: WorkoutCategory, zones: ZoneThresholds, maxHR: Int) -> HRTarget? {
        if category == .lthrTest || drill == .lthrProtocol { return nil }
        switch drill {
        case .aerobicZ2:
            if category == .walk {
                return HRTarget(low: nil, high: zones.z2Max, label: "Zones 1–2 · under \(zones.z2Max)")
            }
            return HRTarget(low: zones.z1Max + 1, high: zones.z2Max, label: "Zone 2 · \(zones.z1Max + 1)–\(zones.z2Max)")
        case .technical:
            return HRTarget(low: nil, high: zones.z3Max, label: "Zones 1–3 · under \(zones.z3Max)")
        default:
            // Hard work: anything goes up to redline.
            let redline = Int(Double(maxHR) * 0.92)
            return HRTarget(low: nil, high: redline, label: "Under redline · \(redline)")
        }
    }
}

/// Decides when to speak: only when you've been out of range for a while, and not too often.
struct HRAlertTracker {
    /// How far past a bound counts as out (beats).
    var buffer = 4
    /// How long you must stay out before the first alert (seconds).
    var sustain: TimeInterval = 20
    /// Gap between reminders while you stay out (seconds).
    var repeatEvery: TimeInterval = 90

    private var outSince: TimeInterval?
    private var direction = 0
    private var lastAlert: TimeInterval = -999

    /// +1 above, -1 below, 0 in range (with the buffer).
    static func position(bpm: Int, target: HRTarget, buffer: Int, allowLow: Bool) -> Int {
        if let high = target.high, bpm > high + buffer { return 1 }
        if allowLow, let low = target.low, bpm < low - buffer { return -1 }
        return 0
    }

    /// Feed one reading. Returns +1 to say "above target", -1 for "under target", 0 to stay quiet.
    mutating func update(bpm: Int, target: HRTarget, at now: TimeInterval, allowLow: Bool) -> Int {
        let pos = Self.position(bpm: bpm, target: target, buffer: buffer, allowLow: allowLow)
        guard pos != 0 else {
            outSince = nil
            direction = 0
            return 0
        }
        if pos != direction {
            direction = pos
            outSince = now
        }
        guard let since = outSince, now - since >= sustain, now - lastAlert >= repeatEvery else { return 0 }
        lastAlert = now
        return pos
    }

    /// Start of a round, a plan step or a pause: the out-of-range clock starts over.
    mutating func reset() {
        outSince = nil
        direction = 0
    }
}
