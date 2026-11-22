import Foundation

/// Estimates heart rate while the strap has dropped out, from what this session already measured.
/// Estimates are always kept apart from real readings: they never count toward averages, zones,
/// records or "heart rate recorded".
struct HREstimator {
    /// Real readings needed before estimating (about a minute).
    static let minimumReadings = 60
    /// Stop estimating this long after the last real reading (seconds).
    static let maxGap: TimeInterval = 30 * 60

    private(set) var realCount = 0
    private(set) var lastReal: Int?
    private(set) var lastRealAt: TimeInterval?
    private var workSum = 0, workCount = 0
    private var restSum = 0, restCount = 0
    private var recent: [(t: TimeInterval, bpm: Int)] = []
    private var pace: [(speed: Double, bpm: Int)] = []

    /// A real reading. `resting` is nil when the session has no rounds; `speed` in m/s on runs.
    mutating func addReal(bpm: Int, at t: TimeInterval, resting: Bool?, speed: Double?) {
        guard bpm > 0 else { return }
        realCount += 1
        lastReal = bpm
        lastRealAt = t
        if let resting {
            if resting { restSum += bpm; restCount += 1 } else { workSum += bpm; workCount += 1 }
        }
        recent.append((t, bpm))
        recent.removeAll { t - $0.t > 120 }
        if let speed, speed > 0.8 {
            pace.append((speed, bpm))
            if pace.count > 1800 { pace.removeFirst(pace.count - 1800) }
        }
    }

    /// The estimate for now, or nil when there isn't enough to go on.
    func estimate(at t: TimeInterval, resting: Bool?, speed: Double?, maxHR: Int) -> Int? {
        guard realCount >= Self.minimumReadings, let lastReal, let lastAt = lastRealAt,
              t >= lastAt, t - lastAt <= Self.maxGap else { return nil }
        let recentAvg = recent.isEmpty ? Double(lastReal) : Double(recent.map(\.bpm).reduce(0, +)) / Double(recent.count)
        var base = recentAvg
        if let resting {
            // Rounds: what your heart rate did in this kind of phase earlier in the session.
            let work = workCount > 0 ? Double(workSum) / Double(workCount) : nil
            let rest = restCount > 0 ? Double(restSum) / Double(restCount) : nil
            base = (resting ? (rest ?? work) : (work ?? rest)) ?? recentAvg
        } else if let speed, speed > 0.8, let fit = paceFit() {
            // Runs: heart rate against pace, learned from this run.
            base = fit.a + fit.b * speed
        }
        // Ease from the last real reading toward the estimate over 30 seconds.
        let w = min(1, (t - lastAt) / 30)
        let value = Double(lastReal) * (1 - w) + base * w
        return Int(min(Double(maxHR), max(40, value)).rounded())
    }

    /// Straight line bpm = a + b × speed, when there's enough spread in pace to trust it.
    private func paceFit() -> (a: Double, b: Double)? {
        guard pace.count >= 60 else { return nil }
        let n = Double(pace.count)
        let mx = pace.map(\.speed).reduce(0, +) / n
        let my = Double(pace.map(\.bpm).reduce(0, +)) / n
        var sxx = 0.0, sxy = 0.0
        for p in pace {
            sxx += (p.speed - mx) * (p.speed - mx)
            sxy += (p.speed - mx) * (Double(p.bpm) - my)
        }
        guard sxx > 0.5 else { return nil }
        let b = sxy / sxx
        guard b > 0 else { return nil }
        return (my - b * mx, b)
    }
}
