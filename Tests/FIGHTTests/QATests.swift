import XCTest

final class HostileInputTests: XCTestCase {
    private func decodePlan(_ json: String) throws -> TrainingPlan {
        try PlanTransfer.plan(from: Data(json.utf8))
    }

    func testOutOfRangePlanValuesAreClamped() throws {
        let plan = try decodePlan("""
        {"title":"x","blocks":[
          {"kind":"bagRounds","rounds":9223372036854775807,"workSeconds":9223372036854775807,"restSeconds":-5},
          {"kind":"intervals","rounds":0,"workSeconds":0,"restSeconds":0,"target":{"lowZone":99,"highZone":-3}},
          {"kind":"steady","durationSeconds":-100}
        ]}
        """)
        let a = plan.blocks[0], b = plan.blocks[1], c = plan.blocks[2]
        XCTAssertEqual(a.rounds, 50)
        XCTAssertEqual(a.workSeconds, 3600)
        XCTAssertEqual(a.restSeconds, 0)
        XCTAssertGreaterThanOrEqual(b.workSeconds, 5, "a zero-second round would spin the clock")
        XCTAssertEqual(b.rounds, 1)
        XCTAssertEqual(b.target?.lowZone, 5)
        XCTAssertEqual(b.target?.highZone, 5)
        XCTAssertEqual(c.durationSeconds, 5)
        XCTAssertGreaterThan(plan.plannedSeconds, 0, "no overflow")
    }

    func testPlannedSecondsNeverTraps() {
        var block = PlanBlock(kind: .bagRounds)
        block.rounds = Int.max
        block.workSeconds = Int.max
        XCTAssertGreaterThan(block.plannedSeconds, 0)
        let plan = TrainingPlan(title: "x", blocks: [block, block, block])
        XCTAssertGreaterThan(plan.plannedSeconds, 0)
    }

    func testOnlyHttpsTechniqueLinks() throws {
        XCTAssertNil(PlanBlock.safeVideoURL("tel:+15555550100"))
        XCTAssertNil(PlanBlock.safeVideoURL("sms:12345"))
        XCTAssertNil(PlanBlock.safeVideoURL("instagram://user?username=x"))
        XCTAssertNil(PlanBlock.safeVideoURL("http://example.com/v"))
        XCTAssertEqual(PlanBlock.safeVideoURL("https://youtube.com/watch?v=abc"), "https://youtube.com/watch?v=abc")
        let plan = try decodePlan(#"{"blocks":[{"kind":"timedDrill","videoURL":"tel:911"}]}"#)
        XCTAssertNil(plan.blocks[0].videoURL)
    }

    func testOversizedPlansAreRefused() {
        // 10 MB of zeros compresses to a few KB: a classic zip bomb in a link.
        let bomb = Data(count: 10 * 1024 * 1024)
        let packed = (try? (bomb as NSData).compressed(using: .zlib) as Data) ?? Data()
        let url = URL(string: "fight://plan?d=\(PlanTransfer.base64url(packed))")!
        XCTAssertThrowsError(try PlanTransfer.plan(fromLink: url))
        XCTAssertThrowsError(try PlanTransfer.plan(from: Data(count: PlanTransfer.maxPlanBytes + 1)))
    }

    func testLinksStillRoundTrip() throws {
        let plan = PlanTemplates.all[0]
        let back = try PlanTransfer.plan(fromLink: try PlanTransfer.link(for: plan))
        XCTAssertEqual(back.blocks.count, plan.blocks.count)
        XCTAssertEqual(back.title, plan.title)
    }

    func testBoundedInflateStopsAtTheLimit() {
        let raw = Data(repeating: 65, count: 100_000)
        let packed = (try? (raw as NSData).compressed(using: .zlib) as Data) ?? Data()
        XCTAssertEqual(PlanTransfer.inflate(packed, limit: 200_000), raw)
        XCTAssertNil(PlanTransfer.inflate(packed, limit: 50_000))
        XCTAssertNil(PlanTransfer.inflate(Data([1, 2, 3, 4]), limit: 1000), "garbage isn't a plan")
    }
}

final class PrivacyAndStorageTests: XCTestCase {
    func testPrivacyZoneTrimsBothEnds() {
        let pts = (0...1000).map { RoutePoint(lat: 51.5 + Double($0) / 111_195, lon: -0.12, t: Double($0)) }  // ~1 km north
        let trimmed = RouteMath.trimEnds(pts)
        XCTAssertEqual(RouteMath.totalDistance(trimmed), 600, accuracy: 3)
        XCTAssertEqual(RouteMath.distance(pts[0], trimmed[0]), 200, accuracy: 2)
        XCTAssertTrue(RouteMath.trimEnds(Array(pts.prefix(300))).isEmpty, "a 300 m route is too short to share safely")
    }

    func testOneBadRecordDoesNotLoseTheList() throws {
        let json = #"[{"lowZone":2,"highZone":3},{"lowZone":"oops"},{"lowZone":1,"highZone":2}]"#
        let lossy = try JSONDecoder().decode([Lossy<StrictPair>].self, from: Data(json.utf8))
        XCTAssertEqual(lossy.compactMap(\.value).count, 2)
    }
}

/// A strict type for the lossy-decoding test (ZoneTarget itself tolerates bad values).
private struct StrictPair: Decodable {
    let lowZone: Int
    let highZone: Int
}
