import XCTest

final class TrainingPlanTests: XCTestCase {

    func testCoachExampleTemplateMatchesTheBrief() throws {
        let plan = PlanTemplates.comboSharpening
        let bag = try XCTUnwrap(plan.blocks.first { $0.kind == .bagRounds })
        XCTAssertEqual(bag.rounds, 3)
        XCTAssertTrue(bag.combos.allSatisfy { combo in
            combo.allSatisfy { [.jab, .cross, .leadLowKick, .rearLowKick].contains($0) }
        }, "1-2s and low kicks only")
        let rope = try XCTUnwrap(plan.blocks.first { $0.title == "Jump rope" })
        XCTAssertEqual(rope.durationSeconds, 120)
    }

    func testPlannedDuration() {
        var b = PlanBlock(kind: .bagRounds)
        b.rounds = 3; b.workSeconds = 180; b.restSeconds = 60
        XCTAssertEqual(b.plannedSeconds, 3 * 180 + 2 * 60, "no rest after the last round")
        var rope = PlanBlock(kind: .timedDrill)
        rope.durationSeconds = 120
        XCTAssertEqual(TrainingPlan(title: "t", blocks: [b, rope]).plannedSeconds, 780)
    }

    func testFileRoundTrip() throws {
        let plan = PlanTemplates.comboSharpening
        let decoded = try PlanTransfer.plan(from: try PlanTransfer.data(for: plan))
        XCTAssertEqual(decoded.title, plan.title)
        XCTAssertEqual(decoded.blocks, plan.blocks)
        XCTAssertEqual(decoded.id, plan.id, "same id lets a coach resend an updated plan")
    }

    func testLinkRoundTripAndEveryTemplateFitsInAQRCode() throws {
        for plan in PlanTemplates.all {
            let url = try PlanTransfer.link(for: plan)
            XCTAssertEqual(url.scheme, "fight")
            XCTAssertTrue(PlanTransfer.fitsInQRCode(url), "\(plan.title) is \(url.absoluteString.count) chars")
            XCTAssertEqual(try PlanTransfer.plan(fromLink: url).blocks, plan.blocks)
        }
    }

    func testDecodesOlderOrPartialFilesWithDefaults() throws {
        let json = #"{"title":"From coach","blocks":[{"kind":"bagRounds","rounds":4},{"kind":"timedDrill","title":"Rope","futureField":true}]}"#
        let plan = try PlanTransfer.plan(from: Data(json.utf8))
        XCTAssertEqual(plan.blocks.count, 2)
        XCTAssertEqual(plan.blocks[0].rounds, 4)
        XCTAssertEqual(plan.blocks[0].workSeconds, 180, "missing fields fall back to defaults")
        XCTAssertEqual(plan.blocks[1].title, "Rope")
        XCTAssertEqual(plan.discipline, "Kickboxing")
    }

    func testRejectsGarbageAndForeignLinks() {
        XCTAssertThrowsError(try PlanTransfer.plan(from: Data("not json".utf8)))
        XCTAssertThrowsError(try PlanTransfer.plan(fromLink: URL(string: "https://example.com/plan?d=abc")!))
        XCTAssertThrowsError(try PlanTransfer.plan(from: Data(#"{"title":"empty","blocks":[]}"#.utf8)), "a plan needs blocks")
    }

    func testDuplicateGetsFreshIDs() {
        let plan = PlanTemplates.fightPace
        let copy = plan.duplicated(title: "Copy")
        XCTAssertNotEqual(copy.id, plan.id)
        XCTAssertEqual(copy.title, "Copy")
        XCTAssertTrue(zip(copy.blocks, plan.blocks).allSatisfy { $0.id != $1.id })
    }

    func testZoneTargetResolvesToEachFightersOwnBPM() {
        var young = AthleteProfile()
        young.age = 20
        young.restingHR = 50
        young.zoneMethod = .karvonenHRR
        var older = young
        older.age = 45
        let target = ZoneTarget(lowZone: 2, highZone: 3)
        let a = target.bpmRange(for: young)
        let b = target.bpmRange(for: older)
        XCTAssertEqual(a.lowerBound, young.activeZones.z1Max + 1)
        XCTAssertEqual(a.upperBound, young.activeZones.z3Max)
        XCTAssertGreaterThan(a.upperBound, b.upperBound, "same plan, lower BPM for the older fighter")
    }

    func testResultPackageRoundTrip() throws {
        let block = BlockResult(blockID: UUID(), title: "Rope", kind: .timedDrill, plannedSeconds: 120,
                                startElapsed: 0, endElapsed: 118, completed: true, avgBPM: 150, peakBPM: 162,
                                timeInTarget: 0.8, targetLabel: "Zones 2–3", roundsCompleted: nil, strikesCalled: 0)
        let pkg = SessionResultPackage(id: UUID(), athleteName: "Shon", planID: UUID(), planTitle: "Sharpening",
                                       discipline: "Kickboxing", date: Date(), durationSeconds: 1500, averageBPM: 148,
                                       maxBPM: 182, activeCalories: 320, load: 90, rpe: 7, notes: "felt sharp",
                                       reviewScore: 81, zoneMinutes: [2, 8, 10, 4, 1], blocks: [block])
        let decoded = try PlanTransfer.result(from: try PlanTransfer.data(for: pkg))
        XCTAssertEqual(decoded.athleteName, "Shon")
        XCTAssertEqual(decoded.blocks, [block])
        XCTAssertEqual(decoded.completedBlocks, 1)
    }

    func testSpokenDurations() {
        XCTAssertEqual(PlanFormat.spokenDuration(120), "2 minutes")
        XCTAssertEqual(PlanFormat.spokenDuration(90), "a minute and a half")
        XCTAssertEqual(PlanFormat.spokenDuration(45), "45 seconds")
        XCTAssertEqual(PlanFormat.clock(185), "3:05")
    }

    // MARK: Untrusted input

    func testImportedPlanWithExtremeValuesIsClamped() throws {
        let json = """
        {"title":"evil","blocks":[{"kind":"bagRounds","rounds":4611686018427387904,"workSeconds":3,"restSeconds":-5},
                                  {"kind":"timedDrill","durationSeconds":-100,"sets":0,"reps":99999}]}
        """
        let plan = try PlanTransfer.plan(from: Data(json.utf8))
        let bag = plan.blocks[0]
        XCTAssertEqual(bag.rounds, PlanBlock.ImportLimits.rounds.upperBound)
        XCTAssertEqual(bag.workSeconds, PlanBlock.ImportLimits.workSeconds.lowerBound)
        XCTAssertEqual(bag.restSeconds, 0)
        let drill = plan.blocks[1]
        XCTAssertEqual(drill.durationSeconds, PlanBlock.ImportLimits.durationSeconds.lowerBound)
        XCTAssertEqual(drill.sets, 1)
        XCTAssertEqual(drill.reps, PlanBlock.ImportLimits.reps.upperBound)
        _ = plan.plannedSeconds   // must not trap
    }

    func testPlannedSecondsNeverTrapsOnOverflow() {
        var b = PlanBlock(kind: .bagRounds)
        b.rounds = Int.max
        b.workSeconds = Int.max
        b.restSeconds = Int.max
        XCTAssertGreaterThan(b.plannedSeconds, 0)
    }

    func testImportedPlanBlockCountIsCapped() throws {
        let block = #"{"kind":"timedDrill","durationSeconds":60}"#
        let json = #"{"title":"long","blocks":["# + Array(repeating: block, count: 500).joined(separator: ",") + "]}"
        let plan = try PlanTransfer.plan(from: Data(json.utf8))
        XCTAssertEqual(plan.blocks.count, TrainingPlan.maxImportedBlocks)
    }

    func testEveryTemplateSurvivesImportUnchanged() throws {
        for plan in PlanTemplates.all {
            let decoded = try PlanTransfer.plan(from: try PlanTransfer.data(for: plan))
            XCTAssertEqual(decoded.blocks, plan.blocks, plan.title)
        }
    }
}
