import XCTest

final class HREstimatorTests: XCTestCase {
    func testNothingBeforeAMinuteOfRealData() {
        var e = HREstimator()
        for t in 0..<30 { e.addReal(bpm: 150, at: TimeInterval(t), resting: nil, speed: nil) }
        XCTAssertNil(e.estimate(at: 40, resting: nil, speed: nil, maxHR: 190))
    }

    func testSteadySessionHoldsRecentLevel() {
        var e = HREstimator()
        for t in 0..<120 { e.addReal(bpm: 150, at: TimeInterval(t), resting: nil, speed: nil) }
        XCTAssertEqual(e.estimate(at: 200, resting: nil, speed: nil, maxHR: 190), 150)
    }

    func testRoundsFollowWorkAndRest() {
        var e = HREstimator()
        for t in 0..<180 { e.addReal(bpm: 170, at: TimeInterval(t), resting: false, speed: nil) }
        for t in 180..<240 { e.addReal(bpm: 130, at: TimeInterval(t), resting: true, speed: nil) }
        XCTAssertEqual(e.estimate(at: 300, resting: false, speed: nil, maxHR: 200), 170)
        XCTAssertEqual(e.estimate(at: 300, resting: true, speed: nil, maxHR: 200), 130)
    }

    func testRunsFollowPace() {
        var e = HREstimator()
        // 2.5 m/s → 140, 3.5 m/s → 160
        for t in 0..<120 {
            let fast = t % 2 == 0
            e.addReal(bpm: fast ? 160 : 140, at: TimeInterval(t), resting: nil, speed: fast ? 3.5 : 2.5)
        }
        let est = e.estimate(at: 400, resting: nil, speed: 3.5, maxHR: 200) ?? 0
        XCTAssertEqual(est, 160, accuracy: 2)
    }

    func testEasesFromLastReadingAndStopsAfterThirtyMinutes() {
        var e = HREstimator()
        for t in 0..<100 { e.addReal(bpm: t < 99 ? 140 : 170, at: TimeInterval(t), resting: nil, speed: nil) }
        let justAfter = e.estimate(at: 100, resting: nil, speed: nil, maxHR: 200) ?? 0
        XCTAssertGreaterThan(justAfter, 160, "starts near the last real reading")
        XCTAssertNil(e.estimate(at: 99 + 31 * 60, resting: nil, speed: nil, maxHR: 200))
    }
}
