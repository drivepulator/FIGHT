import XCTest

final class HRAlertTests: XCTestCase {
    private let zones = ZoneThresholds(z1Max: 127, z2Max: 142, z3Max: 160, z4Max: 175)

    func testEasyRunTargetsZoneTwoBothWays() {
        let t = HRTargetRules.target(drill: .aerobicZ2, category: .roadwork, zones: zones, maxHR: 190)
        XCTAssertEqual(t?.low, 128)
        XCTAssertEqual(t?.high, 142)
    }

    func testWalkOnlyHasACeiling() {
        let t = HRTargetRules.target(drill: .aerobicZ2, category: .walk, zones: zones, maxHR: 190)
        XCTAssertNil(t?.low)
        XCTAssertEqual(t?.high, 142)
    }

    func testTechniqueStaysUnderZoneThree() {
        let t = HRTargetRules.target(drill: .technical, category: .kickboxing, zones: zones, maxHR: 190)
        XCTAssertNil(t?.low)
        XCTAssertEqual(t?.high, 160)
    }

    func testHardWorkOnlyWarnsAtRedline() {
        let t = HRTargetRules.target(drill: .bagWork, category: .heavyBag, zones: zones, maxHR: 190)
        XCTAssertNil(t?.low)
        XCTAssertEqual(t?.high, 174)
    }

    func testThresholdTestHasNoAlerts() {
        XCTAssertNil(HRTargetRules.target(drill: .lthrProtocol, category: .lthrTest, zones: zones, maxHR: 190))
    }

    func testOnlySpeaksAfterTwentySecondsOut() {
        let t = HRTarget(low: 128, high: 142, label: "")
        var a = HRAlertTracker()
        XCTAssertEqual(a.update(bpm: 150, target: t, at: 100, allowLow: true), 0)
        XCTAssertEqual(a.update(bpm: 150, target: t, at: 110, allowLow: true), 0)
        XCTAssertEqual(a.update(bpm: 150, target: t, at: 120, allowLow: true), 1, "20 s above: slow down")
    }

    func testAShortSpikeSaysNothing() {
        let t = HRTarget(low: 128, high: 142, label: "")
        var a = HRAlertTracker()
        _ = a.update(bpm: 150, target: t, at: 100, allowLow: true)
        _ = a.update(bpm: 140, target: t, at: 110, allowLow: true)
        XCTAssertEqual(a.update(bpm: 150, target: t, at: 120, allowLow: true), 0, "back in range resets the clock")
    }

    func testWithinTheBufferIsInRange() {
        let t = HRTarget(low: 128, high: 142, label: "")
        var a = HRAlertTracker()
        _ = a.update(bpm: 146, target: t, at: 0, allowLow: true)
        XCTAssertEqual(a.update(bpm: 146, target: t, at: 60, allowLow: true), 0, "4 beats over is fine")
    }

    func testRemindsEveryNinetySecondsWhileOut() {
        let t = HRTarget(low: 128, high: 142, label: "")
        var a = HRAlertTracker()
        _ = a.update(bpm: 120, target: t, at: 0, allowLow: true)
        XCTAssertEqual(a.update(bpm: 120, target: t, at: 20, allowLow: true), -1, "pick it up")
        XCTAssertEqual(a.update(bpm: 120, target: t, at: 60, allowLow: true), 0)
        XCTAssertEqual(a.update(bpm: 120, target: t, at: 110, allowLow: true), -1)
    }

    func testNoLowAlertWhenNotAllowed() {
        let t = HRTarget(low: 128, high: 142, label: "")
        var a = HRAlertTracker()
        _ = a.update(bpm: 100, target: t, at: 0, allowLow: false)
        XCTAssertEqual(a.update(bpm: 100, target: t, at: 60, allowLow: false), 0)
    }
}
