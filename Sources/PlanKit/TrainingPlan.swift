import Foundation

// MARK: - Plan model (shared file format)

/// A heart-rate target expressed in zones, so one plan resolves to the right
/// BPM range on every fighter's own profile.
struct ZoneTarget: Codable, Equatable, Hashable {
    var lowZone: Int
    var highZone: Int

    init(lowZone: Int, highZone: Int) {
        self.lowZone = min(max(lowZone, 1), 5)
        self.highZone = min(max(highZone, self.lowZone), 5)
    }

    var label: String {
        lowZone == highZone ? "Zone \(lowZone)" : "Zones \(lowZone)–\(highZone)"
    }
}

enum PlanBlockKind: String, Codable, CaseIterable, Identifiable {
    case bagRounds, intervals, timedDrill, steady, strength, rest
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bagRounds: return "Bag rounds"
        case .intervals: return "Intervals"
        case .timedDrill: return "Timed drill"
        case .steady: return "Steady cardio"
        case .strength: return "Strength / reps"
        case .rest: return "Rest / transition"
        }
    }

    var icon: String {
        switch self {
        case .bagRounds: return "figure.boxing"
        case .intervals: return "timer"
        case .timedDrill: return "figure.jumprope"
        case .steady: return "figure.run"
        case .strength: return "dumbbell.fill"
        case .rest: return "pause.circle"
        }
    }

    /// Round-based blocks run on the round bell; the others on a single countdown.
    var isRoundBased: Bool { self == .bagRounds || self == .intervals }

    var defaultTitle: String {
        switch self {
        case .bagRounds: return "Bag rounds"
        case .intervals: return "Intervals"
        case .timedDrill: return "Jump rope"
        case .steady: return "Steady run"
        case .strength: return "Strength"
        case .rest: return "Rest"
        }
    }
}

/// One step of a session. Fields that don't apply to a block's kind are ignored.
struct PlanBlock: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var kind: PlanBlockKind
    var title: String
    var rounds = 3
    var workSeconds = 180
    var restSeconds = 60
    var durationSeconds = 120
    /// Bag rounds: the only combos the bag coach may call (empty = the fighter's usual mix).
    var combos: [[Strike]] = []
    var tempo: BagTempo = .steady
    var target: ZoneTarget?
    var sets = 3
    var reps = 10
    var cue = ""
    var videoURL: String?
    /// Words the coach calls at random during the block (reaction games), e.g. ["Left", "Right", "Up"].
    var calls: [String] = []
    /// Rest that ends early once heart rate has recovered (at least 45 s).
    var untilRecovered = false
    /// Estimated foot contacts (plyometric volume).
    var contacts = 0

    init(kind: PlanBlockKind, title: String? = nil) {
        self.kind = kind
        self.title = title ?? kind.defaultTitle
        switch kind {
        case .intervals:
            rounds = 8; workSeconds = 30; restSeconds = 30
        case .steady:
            durationSeconds = 1200
            target = ZoneTarget(lowZone: 2, highZone: 2)
        case .strength:
            durationSeconds = 600
        case .rest:
            durationSeconds = 60
        default:
            break
        }
    }

    /// Planned length in seconds.
    var plannedSeconds: Int {
        guard kind.isRoundBased else { return max(0, durationSeconds) }
        // Overflow-safe: a hand-edited plan must never trap here.
        let r = max(0, rounds)
        let (work, o1) = r.multipliedReportingOverflow(by: max(0, workSeconds))
        let (rest, o2) = max(0, r - 1).multipliedReportingOverflow(by: max(0, restSeconds))
        let (total, o3) = work.addingReportingOverflow(rest)
        return (o1 || o2 || o3) ? Int.max / 4 : total
    }

    /// Short human summary, e.g. "3 × 3:00 / 1:00" or "2:00".
    var summary: String {
        switch kind {
        case .bagRounds, .intervals:
            return "\(rounds) × \(PlanFormat.clock(workSeconds)) / \(PlanFormat.clock(restSeconds))"
        case .strength:
            return "\(sets) × \(reps) reps"
        default:
            return PlanFormat.clock(durationSeconds)
        }
    }

    /// Sentence the voice coach reads when the block starts.
    var spokenIntro: String {
        switch kind {
        case .bagRounds:
            return "\(title). \(rounds) round\(rounds == 1 ? "" : "s") of \(PlanFormat.spokenDuration(workSeconds))."
        case .intervals:
            return "\(title). \(rounds) rounds, \(PlanFormat.spokenDuration(workSeconds)) on, \(PlanFormat.spokenDuration(restSeconds)) off."
        case .strength:
            return "\(title). \(sets) sets of \(reps)."
        default:
            return "\(title), \(PlanFormat.spokenDuration(durationSeconds))."
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, rounds, workSeconds, restSeconds, durationSeconds, combos, tempo, target, sets, reps, cue, videoURL
        case calls, untilRecovered, contacts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = (try? c.decodeIfPresent(PlanBlockKind.self, forKey: .kind)) ?? .timedDrill
        let d = PlanBlock(kind: decodedKind)
        kind = decodedKind
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? d.title
        rounds = (try? c.decodeIfPresent(Int.self, forKey: .rounds)) ?? d.rounds
        workSeconds = (try? c.decodeIfPresent(Int.self, forKey: .workSeconds)) ?? d.workSeconds
        restSeconds = (try? c.decodeIfPresent(Int.self, forKey: .restSeconds)) ?? d.restSeconds
        durationSeconds = (try? c.decodeIfPresent(Int.self, forKey: .durationSeconds)) ?? d.durationSeconds
        combos = (try? c.decodeIfPresent([[Strike]].self, forKey: .combos)) ?? []
        tempo = (try? c.decodeIfPresent(BagTempo.self, forKey: .tempo)) ?? d.tempo
        target = try? c.decodeIfPresent(ZoneTarget.self, forKey: .target)
        sets = (try? c.decodeIfPresent(Int.self, forKey: .sets)) ?? d.sets
        reps = (try? c.decodeIfPresent(Int.self, forKey: .reps)) ?? d.reps
        cue = (try? c.decodeIfPresent(String.self, forKey: .cue)) ?? ""
        videoURL = try? c.decodeIfPresent(String.self, forKey: .videoURL)
        calls = (try? c.decodeIfPresent([String].self, forKey: .calls)) ?? []
        untilRecovered = (try? c.decodeIfPresent(Bool.self, forKey: .untilRecovered)) ?? false
        contacts = (try? c.decodeIfPresent(Int.self, forKey: .contacts)) ?? 0
        sanitizeImported()
    }

    /// Limits for plans that arrive from outside the app (files, links, QR codes).
    /// The in-app editor stays well inside these.
    enum ImportLimits {
        static let rounds = 1...50
        static let workSeconds = 5...3600
        static let restSeconds = 0...1800
        static let durationSeconds = 5...14_400
        static let sets = 1...20
        static let reps = 1...500
        static let contacts = 0...10_000
        static let maxCombos = 200
        static let maxComboLength = 12
        static let maxCalls = 50
        static let maxText = 500
    }

    /// Clamps every decoded value into a range the round clock and the UI can handle,
    /// so a malformed or malicious plan can't crash the app or spin the clock.
    mutating func sanitizeImported() {
        func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }
        rounds = clamp(rounds, ImportLimits.rounds)
        workSeconds = clamp(workSeconds, ImportLimits.workSeconds)
        restSeconds = clamp(restSeconds, ImportLimits.restSeconds)
        durationSeconds = clamp(durationSeconds, ImportLimits.durationSeconds)
        sets = clamp(sets, ImportLimits.sets)
        reps = clamp(reps, ImportLimits.reps)
        contacts = clamp(contacts, ImportLimits.contacts)
        combos = Array(combos.prefix(ImportLimits.maxCombos).map { Array($0.prefix(ImportLimits.maxComboLength)) }.filter { !$0.isEmpty })
        calls = Array(calls.prefix(ImportLimits.maxCalls).map { String($0.prefix(ImportLimits.maxText)) })
        title = String(title.prefix(ImportLimits.maxText))
        cue = String(cue.prefix(ImportLimits.maxText))
        if let v = videoURL, v.count > 2048 { videoURL = nil }
    }
}

/// A coach-written session: an ordered list of blocks run as one workout.
struct TrainingPlan: Codable, Identifiable, Equatable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion = TrainingPlan.currentSchemaVersion
    var id = UUID()
    var title: String
    var author: String
    var discipline: String
    var notes: String
    var createdAt = Date()
    var blocks: [PlanBlock]

    init(title: String, author: String = "", discipline: String = "Kickboxing", notes: String = "", blocks: [PlanBlock] = []) {
        self.title = title
        self.author = author
        self.discipline = discipline
        self.notes = notes
        self.blocks = blocks
    }

    var plannedSeconds: Int {
        blocks.reduce(0) { $0 + $1.plannedSeconds }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, author, discipline, notes, createdAt, blocks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Training plan"
        author = (try? c.decodeIfPresent(String.self, forKey: .author)) ?? ""
        discipline = (try? c.decodeIfPresent(String.self, forKey: .discipline)) ?? "Kickboxing"
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        blocks = Array(((try? c.decodeIfPresent([PlanBlock].self, forKey: .blocks)) ?? []).prefix(Self.maxImportedBlocks))
        title = String(title.prefix(PlanBlock.ImportLimits.maxText))
        author = String(author.prefix(PlanBlock.ImportLimits.maxText))
        discipline = String(discipline.prefix(PlanBlock.ImportLimits.maxText))
        notes = String(notes.prefix(4000))
    }

    /// More blocks than any real session needs; caps imported plans.
    static let maxImportedBlocks = 100

    /// A fresh copy (new IDs) for editing or importing someone else's plan.
    func duplicated(title newTitle: String? = nil) -> TrainingPlan {
        var copy = self
        copy.id = UUID()
        copy.createdAt = Date()
        copy.title = newTitle ?? title
        copy.blocks = blocks.map { var b = $0; b.id = UUID(); return b }
        return copy
    }
}

// MARK: - Results

/// How one block went: saved with the workout and sent back to the coach.
struct BlockResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var blockID: UUID
    var title: String
    var kind: PlanBlockKind
    var plannedSeconds: Int
    var startElapsed: TimeInterval
    var endElapsed: TimeInterval
    var completed: Bool
    var avgBPM: Int?
    var peakBPM: Int?
    /// Fraction of the block spent inside its target band (nil if no target).
    var timeInTarget: Double?
    var targetLabel: String?
    var roundsCompleted: Int?
    var strikesCalled: Int

    var actualSeconds: TimeInterval { max(0, endElapsed - startElapsed) }
}

/// A finished plan session, packaged for the coach (`.fightresult`).
struct SessionResultPackage: Codable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion = SessionResultPackage.currentSchemaVersion
    var id: UUID
    var athleteName: String
    var planID: UUID?
    var planTitle: String
    var discipline: String
    var date: Date
    var durationSeconds: TimeInterval
    var averageBPM: Int
    var maxBPM: Int
    var activeCalories: Double
    var load: Double
    var rpe: Int?
    var notes: String
    var reviewScore: Int?
    var zoneMinutes: [Int]
    var blocks: [BlockResult]

    var completedBlocks: Int { blocks.filter(\.completed).count }
}

// MARK: - Formatting

enum PlanFormat {
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func spokenDuration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        switch (m, s) {
        case (0, _): return "\(s) seconds"
        case (_, 0): return m == 1 ? "1 minute" : "\(m) minutes"
        case (_, 30): return m == 1 ? "a minute and a half" : "\(m) and a half minutes"
        default: return "\(m) minute\(m == 1 ? "" : "s") \(s)"
        }
    }

    static func totalLabel(_ seconds: Int) -> String {
        let m = Int((Double(seconds) / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

// MARK: - Built-in templates

enum PlanTemplates {
    static var all: [TrainingPlan] {
        [benchmark, comboSharpening, fightPace, clinchDay, conditioning, technicalRoadwork]
    }

    /// Templates keep fixed IDs so runs of the same template can be grouped and compared
    /// (and so SwiftUI lists don't see a "new" template on every redraw).
    static func stableID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "F1617000-0000-4000-8000-%012d", n))!
    }

    private static func stable(_ plan: TrainingPlan, _ n: Int) -> TrainingPlan {
        var p = plan
        p.id = stableID(n * 100)
        for i in p.blocks.indices { p.blocks[i].id = stableID(n * 100 + i + 1) }
        p.createdAt = Date(timeIntervalSince1970: 1_767_225_600)
        return p
    }

    static let benchmarkID = stableID(900)
    static let fightNightID = stableID(1000)

    /// Fight-night warm-up, timed to finish at the walkout: raise HR gradually,
    /// touch fight pace briefly, then settle so you walk out warm but fresh.
    static var fightNightWarmUp: TrainingPlan {
        var move = PlanBlock(kind: .steady, title: "Easy movement")
        move.durationSeconds = 300
        move.target = ZoneTarget(lowZone: 1, highZone: 2)
        move.cue = "Skip, jog on the spot, open the hips"

        var shadow = PlanBlock(kind: .timedDrill, title: "Shadowboxing")
        shadow.durationSeconds = 360
        shadow.target = ZoneTarget(lowZone: 2, highZone: 2)
        shadow.cue = "Rehearse your game plan. Relaxed, long breaths."

        var tech = PlanBlock(kind: .bagRounds, title: "Pads / technical rounds")
        tech.rounds = 2; tech.workSeconds = 120; tech.restSeconds = 60
        tech.tempo = .technical
        tech.target = ZoneTarget(lowZone: 2, highZone: 3)
        tech.cue = "Crisp and accurate, not hard"

        var sharp = PlanBlock(kind: .intervals, title: "Fight-pace bursts")
        sharp.rounds = 3; sharp.workSeconds = 30; sharp.restSeconds = 60
        sharp.target = ZoneTarget(lowZone: 3, highZone: 4)
        sharp.cue = "Explode for 30 s, then breathe it back down"

        var settle = PlanBlock(kind: .rest, title: "Settle & focus")
        settle.durationSeconds = 240
        settle.cue = "Slow nasal breathing. Gloves on, sweat on, mind on the plan."

        let plan = TrainingPlan(title: "Fight-Night Warm-Up", author: "FIGHT", discipline: "Kickboxing",
                                notes: "Finishes at your walkout time: warm, sweating, heart rate settled.",
                                blocks: [move, shadow, tech, sharp, settle])
        return stable(plan, 10)
    }

    /// A fixed test, identical every time, so your heart rate on the same work shows real progress.
    static var benchmark: TrainingPlan {
        var rope = PlanBlock(kind: .timedDrill, title: "Jump rope warm-up")
        rope.durationSeconds = 300
        rope.target = ZoneTarget(lowZone: 2, highZone: 2)
        rope.cue = "Easy. Same warm-up every test."

        var rounds = PlanBlock(kind: .bagRounds, title: "Benchmark rounds")
        rounds.rounds = 5; rounds.workSeconds = 180; rounds.restSeconds = 60
        rounds.combos = [[.jab, .cross], [.jab, .cross, .leadHook], [.jab, .cross, .rearLowKick],
                         [.leadTeep], [.cross, .leadHook, .cross], [.jab, .rearMidKick]]
        rounds.tempo = .fightPace
        rounds.cue = "Same effort every test: fight pace, every strike on the callout. Sit down in the rest."

        var cool = PlanBlock(kind: .steady, title: "Cool-down")
        cool.durationSeconds = 180
        cool.target = ZoneTarget(lowZone: 1, highZone: 1)

        let plan = TrainingPlan(title: "FIGHT Benchmark", author: "FIGHT", discipline: "Kickboxing",
                                notes: "Repeat every 4 weeks. Same work every time, so a lower heart rate and faster recovery mean you're fitter.",
                                blocks: [rope, rounds, cool])
        var p = stable(plan, 9)
        p.id = benchmarkID
        return p
    }

    /// The coach example: 1-2s and low kicks only for 3 rounds, then jump rope, then a burnout.
    static var comboSharpening: TrainingPlan { stable(_comboSharpening, 1) }

    private static var _comboSharpening: TrainingPlan {
        var warm = PlanBlock(kind: .timedDrill, title: "Shadowbox warm-up")
        warm.durationSeconds = 180
        warm.target = ZoneTarget(lowZone: 1, highZone: 2)
        warm.cue = "Loose shoulders, light on the feet"

        var bag = PlanBlock(kind: .bagRounds, title: "1-2 & low kicks")
        bag.rounds = 3; bag.workSeconds = 180; bag.restSeconds = 60
        bag.combos = [[.jab, .cross], [.jab, .cross, .rearLowKick], [.leadLowKick], [.jab, .cross, .leadLowKick]]
        bag.tempo = .steady
        bag.cue = "Snap the jab back. Turn the hip over on every kick."

        var rope = PlanBlock(kind: .timedDrill, title: "Jump rope")
        rope.durationSeconds = 120
        rope.target = ZoneTarget(lowZone: 2, highZone: 3)
        rope.cue = "Stay on the balls of your feet"

        var burnout = PlanBlock(kind: .bagRounds, title: "1-2 burnout")
        burnout.rounds = 2; burnout.workSeconds = 60; burnout.restSeconds = 30
        burnout.combos = [[.jab, .cross]]
        burnout.tempo = .burnout
        burnout.target = ZoneTarget(lowZone: 4, highZone: 5)

        var cool = PlanBlock(kind: .steady, title: "Cool-down")
        cool.durationSeconds = 300
        cool.target = ZoneTarget(lowZone: 1, highZone: 1)

        return TrainingPlan(title: "1-2 & Low Kick Sharpening", author: "FIGHT", discipline: "Kickboxing",
                            notes: "Clean, fast 1-2s and committed low kicks. Quality over volume.",
                            blocks: [warm, bag, rope, burnout, cool])
    }

    static var fightPace: TrainingPlan { stable(_fightPace, 2) }

    private static var _fightPace: TrainingPlan {
        var rope = PlanBlock(kind: .timedDrill, title: "Jump rope")
        rope.durationSeconds = 300
        rope.target = ZoneTarget(lowZone: 2, highZone: 3)
        var rounds = PlanBlock(kind: .bagRounds, title: "Fight-pace rounds")
        rounds.rounds = 5; rounds.workSeconds = 180; rounds.restSeconds = 60
        rounds.tempo = .fightPace
        rounds.target = ZoneTarget(lowZone: 3, highZone: 4)
        rounds.cue = "Every round as sharp as the first"
        var cool = PlanBlock(kind: .steady, title: "Cool-down")
        cool.durationSeconds = 300
        cool.target = ZoneTarget(lowZone: 1, highZone: 1)
        return TrainingPlan(title: "Fight-Pace Rounds", author: "FIGHT", discipline: "Kickboxing",
                            notes: "Championship-distance pacing.", blocks: [rope, rounds, cool])
    }

    static var clinchDay: TrainingPlan { stable(_clinchDay, 3) }

    private static var _clinchDay: TrainingPlan {
        var shadow = PlanBlock(kind: .timedDrill, title: "Shadow with knees")
        shadow.durationSeconds = 240
        var knees = PlanBlock(kind: .bagRounds, title: "Knees & elbows")
        knees.rounds = 4; knees.workSeconds = 120; knees.restSeconds = 45
        knees.combos = [[.leadKnee, .rearKnee], [.jab, .cross, .rearKnee], [.leadHook, .rearElbow], [.rearElbow, .leadElbow], [.leadTeep, .rearKnee]]
        knees.tempo = .fightPace
        knees.cue = "Hips through on every knee"
        var core = PlanBlock(kind: .strength, title: "Neck & core")
        core.sets = 3; core.reps = 15
        core.cue = "Neck bridges, hollow holds, Russian twists"
        return TrainingPlan(title: "Muay Thai Clinch Day", author: "FIGHT", discipline: "Muay Thai",
                            notes: "Close-range weapons and clinch strength.", blocks: [shadow, knees, core])
    }

    static var conditioning: TrainingPlan { stable(_conditioning, 4) }

    private static var _conditioning: TrainingPlan {
        var rope = PlanBlock(kind: .timedDrill, title: "Jump rope")
        rope.durationSeconds = 180
        var sprints = PlanBlock(kind: .intervals, title: "Burpee / sprawl intervals")
        sprints.rounds = 10; sprints.workSeconds = 20; sprints.restSeconds = 40
        sprints.target = ZoneTarget(lowZone: 4, highZone: 5)
        var finisher = PlanBlock(kind: .bagRounds, title: "Punch-out finisher")
        finisher.rounds = 3; finisher.workSeconds = 30; finisher.restSeconds = 30
        finisher.combos = [[.jab, .cross], [.jab, .cross, .leadHook, .cross]]
        finisher.tempo = .burnout
        return TrainingPlan(title: "Conditioning Circuit", author: "FIGHT", discipline: "S&C / Conditioning",
                            notes: "Short, hard, repeatable efforts.", blocks: [rope, sprints, finisher])
    }

    static var technicalRoadwork: TrainingPlan { stable(_technicalRoadwork, 5) }

    private static var _technicalRoadwork: TrainingPlan {
        var tech = PlanBlock(kind: .bagRounds, title: "Technical flow")
        tech.rounds = 4; tech.workSeconds = 180; tech.restSeconds = 60
        tech.tempo = .technical
        tech.target = ZoneTarget(lowZone: 2, highZone: 3)
        var run = PlanBlock(kind: .steady, title: "Zone 2 run")
        run.durationSeconds = 1800
        run.target = ZoneTarget(lowZone: 2, highZone: 2)
        run.cue = "Conversational pace"
        return TrainingPlan(title: "Technique + Roadwork", author: "FIGHT", discipline: "Kickboxing",
                            notes: "Low-stress skill work, then aerobic base.", blocks: [tech, run])
    }
}
