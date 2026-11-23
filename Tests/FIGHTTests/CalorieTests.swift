import XCTest

final class CalorieTests: XCTestCase {
    private func athlete() -> AthleteProfile {
        var p = AthleteProfile()
        p.sex = .male
        p.age = 25
        p.weightKg = 89
        p.heightCm = 184
        p.restingHR = 60
        p.useAutoMaxHR = false
        p.maxHR = 195
        return p
    }

    func testEasyWalkFromMovement() {
        // 0.84 km at 13:05 /km (about 64 m/min) with 10 m of climb, 89 kg: about 45 active kcal.
        let kcal = FighterAnalytics.movementActiveCalories(distanceM: 840, climbM: 10, speedMetersPerMinute: 64, weightKg: 89)
        XCTAssertEqual(kcal, 45, accuracy: 3)
    }

    func testRunningCostsMorePerMetre() {
        let walk = FighterAnalytics.movementActiveCalories(distanceM: 1000, climbM: 0, speedMetersPerMinute: 100, weightKg: 80)
        let run = FighterAnalytics.movementActiveCalories(distanceM: 1000, climbM: 0, speedMetersPerMinute: 180, weightKg: 80)
        XCTAssertEqual(walk, 40, accuracy: 1)
        XCTAssertEqual(run, 80, accuracy: 1, "about 1 kcal per kg per km running")
    }

    func testStandingStillBurnsNothingExtra() {
        XCTAssertEqual(FighterAnalytics.movementActiveCalories(distanceM: 0, climbM: 0, speedMetersPerMinute: 0, weightKg: 89), 0)
    }

    func testLightHeartRateNoLongerDoublesTheBurn() {
        // 118 bpm is 43% of reserve for this athlete: well under the old ~9.8 kcal/min.
        let p = athlete()
        let walk = FighterAnalytics.calculateCalorieBreakdown(bpm: 118, durationSeconds: 60, profile: p)
        XCTAssertLessThan(walk.total, 8.5)
        XCTAssertGreaterThan(walk.total, 4)
    }

    func testHardRoundsAreUnchanged() {
        // From half of reserve upward the published formula applies in full.
        let p = athlete()
        let hard = FighterAnalytics.calculateCalorieBreakdown(bpm: 170, durationSeconds: 60, profile: p)
        let vo2max = 15.3 * 195.0 / 60.0
        let keytel = (-95.7735 + 0.634 * 170 + 0.404 * vo2max + 0.394 * 89 + 0.271 * 25) / 4.184
        XCTAssertEqual(hard.total, keytel, accuracy: 0.01)
    }

    func testThresholdZonesUseRunningPercentages() {
        var p = athlete()
        p.zoneMethod = .lactateThreshold
        p.lactateThresholdHR = 170
        let z = p.activeZones
        XCTAssertEqual(z.z1Max, 145)
        XCTAssertEqual(z.z2Max, 151)
        XCTAssertEqual(z.z3Max, 160)
        XCTAssertEqual(z.z4Max, 168)
    }
}
