import Foundation
import Observation
import SwiftUI
import UIKit
import ActivityKit
import AVFoundation

// MARK: - Draft (autosave / crash recovery)

/// Everything needed to rebuild a workout if the app is killed mid-session.
struct WorkoutSetup: Codable, Equatable {
    var category: WorkoutCategory
    var drill: DrillTag
    var roundTimer: Bool
    var workSeconds: Int
    var restSeconds: Int
    var bag: Bool
    /// From the three-door picker: "Muay Thai · Bag work", the round count and bag tempo.
    var activity: String? = nil
    var rounds: Int? = nil
    var tempo: BagTempo? = nil
}

struct WorkoutSetupMemory: Codable {
    var last: WorkoutSetup?
    var byCategory: [String: WorkoutSetup] = [:]
}

struct WorkoutDraft: Codable {
    var id: UUID
    var profileID: UUID
    var startTime: Date
    var lastUpdate: Date
    var elapsedSeconds: TimeInterval
    var category: WorkoutCategory
    var drillTag: DrillTag
    var notes: String
    var samples: [HeartRatePoint]
    var zoneSeconds: [Int: TimeInterval]
    var activeCalories: Double
    var bmrCalories: Double
    var rounds: [RoundStat]
    var autoHRREvents: [AutoHRREvent]
    var strikesCued: Int
    var ghostTitle: String?
    var planTitle: String?
    var planTargetLow: Int?
    var planTargetHigh: Int?
    var trainingPlanID: UUID?
    var trainingPlanTitle: String?
    var blockResults: [BlockResult]?
    var comboEvents: [ComboEvent]?
    var headMovesPerMinute: Double?
    var breathingGuided: Bool?
    var impactsCount: Int?
    var jumps: [Double]?
    var activity: [ActivityPoint]?
    var run: RunSummary?
    var route: [RoutePoint]?
    var activityName: String?
    /// Estimated heart rate while the strap was off (never mixed with real readings).
    var estimatedSamples: [HeartRatePoint]?
    var estimatedCalories: Double?
    /// Seconds of real heart rate recovered from a FIGHT Logger after the phone dropped out.
    var recoveredSeconds: Int?
}

enum WorkoutFinalizer {
    /// Turns raw session data into a fully analysed SavedWorkout.
    static func makeWorkout(from d: WorkoutDraft, profile: AthleteProfile, ghost: GhostSession?, end: Date) -> SavedWorkout {
        let steadyKinds: [WorkoutCategory] = [.walk, .roadwork, .lthrTest]
        let detected = d.rounds.isEmpty && !steadyKinds.contains(d.category)
            ? AutoRounds.detect(samples: d.samples, activity: d.activity ?? [], profile: profile) : []
        let rounds = d.rounds.isEmpty ? detected : d.rounds
        let bpms = d.samples.map(\.bpm)
        let avg = bpms.isEmpty ? 0 : bpms.reduce(0, +) / bpms.count
        let maxB = bpms.max() ?? avg
        let minB = bpms.min() ?? avg

        var ghostDelta: Double?
        if let ghost, !d.samples.isEmpty {
            let deltas = d.samples.compactMap { pt -> Double? in
                ghost.interpolatedBPM(at: pt.elapsedSeconds).map { Double(pt.bpm - $0) }
            }
            if !deltas.isEmpty { ghostDelta = deltas.reduce(0, +) / Double(deltas.count) }
        }

        var adherence: Double?
        if let lo = d.planTargetLow, let hi = d.planTargetHigh, !d.samples.isEmpty {
            let inBand = d.samples.filter { $0.bpm >= lo && $0.bpm <= hi }.count
            adherence = Double(inBand) / Double(d.samples.count)
        }

        var made = SavedWorkout(
            id: d.id,
            profileID: d.profileID,
            profileName: profile.name,
            category: d.category,
            drillTag: d.drillTag,
            rpe: 5,
            notes: d.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: d.startTime,
            endDate: end,
            duration: d.elapsedSeconds,
            averageBPM: avg,
            maxBPM: maxB,
            minBPM: minB,
            activeCalories: d.activeCalories,
            bmrCalories: d.bmrCalories,
            calories: d.activeCalories + d.bmrCalories,
            epocBonusCalories: FighterAnalytics.calculateEPOC(zoneSeconds: d.zoneSeconds, weightKg: profile.weightKg),
            trimpScore: FighterAnalytics.calculateTRIMP(samples: d.samples, profile: profile),
            cardiacDriftPercent: FighterAnalytics.calculateCardiacDrift(samples: d.samples),
            hrr60Drop: d.autoHRREvents.map(\.dropBPM).max(),
            autoHRREvents: d.autoHRREvents,
            rmssdMs: FighterAnalytics.calculateRMSSD(samples: d.samples),
            strikesCuedCount: d.strikesCued,
            ghostBaselineName: d.ghostTitle,
            ghostAvgDeltaBPM: ghostDelta,
            zoneSeconds: d.zoneSeconds,
            roundStats: rounds,
            pointsOfInterest: FighterAnalytics.detectPointsOfInterest(
                samples: d.samples, roundStats: rounds, autoHRREvents: d.autoHRREvents, profile: profile
            ),
            samples: d.samples,
            isCompressedArchive: false,
            archiveFileName: nil,
            rpeRated: false,
            planTitle: d.planTitle,
            planTargetLow: d.planTargetLow,
            planTargetHigh: d.planTargetHigh,
            planAdherence: adherence,
            trainingPlanID: d.trainingPlanID,
            trainingPlanTitle: d.trainingPlanTitle,
            blockResults: d.blockResults ?? [],
            comboEvents: d.comboEvents ?? [],
            headMovesPerMinute: d.headMovesPerMinute,
            breathingGuided: d.breathingGuided ?? false
        )
        made.roundsAutoDetected = !detected.isEmpty
        if let hits = d.impactsCount { made.impactsCount = hits }
        made.run = d.run
        made.activityName = d.activityName
        made.estimatedSamples = d.estimatedSamples ?? []
        made.estimatedCalories = d.estimatedCalories ?? 0
        made.recoveredFromLogger = d.recoveredSeconds ?? 0
        made.jumps = d.jumps ?? []
        return made
    }
}

// MARK: - Session

/// Owns a live workout: timing, rounds, bag coach, coaching cues, autosave and
/// saving. Lives for the whole app session, so switching tabs never disturbs it.
@MainActor
@Observable
final class WorkoutSession {
    let audio = AudioCoachEngine()
    let headMotion = HeadMotionTracker()
    /// GPS for runs and walks.
    let run = RunTracker()

    /// Runs and walks record GPS.
    var tracksGPS: Bool { selectedCategory == .roadwork || selectedCategory == .walk }

    /// The app's live session, for Siri and Shortcuts.
    static weak var shared: WorkoutSession?

    @ObservationIgnored private var ble: BLEHeartRateManager?
    @ObservationIgnored private var store: WorkoutStore?
    @ObservationIgnored private var health: HealthKitManager?

    // MARK: Setup state
    var selectedCategory: WorkoutCategory = .muayThai {
        didSet {
            guard oldValue != selectedCategory, !suppressDefaults else { return }
            applyDisciplineDefaults(selectedCategory)
        }
    }
    var selectedDrillTag: DrillTag = .technical
    var workoutNotes: String = ""
    var roundTimerEnabled = true
    var workDurationSeconds = 180
    var restDurationSeconds = 60
    var bagEnabled = false {
        didSet {
            guard oldValue != bagEnabled else { return }
            bagEnabledChanged()
        }
    }
    var bagPrefs = BagPreferences() {
        didSet {
            guard oldValue != bagPrefs, !loadingPrefs else { return }
            bagPrefsChanged(old: oldValue)
        }
    }
    var selectedGhost: GhostSession?
    var activePlan: WorkoutPrescription?
    /// The picker's name for this workout ("Muay Thai · Bag work"); nil when set up another way.
    var activityName: String?
    /// Shown when a finished session couldn't be written to storage.
    var saveError: String?
    /// Why a fitness test didn't update the zones (too short, no heart rate).
    var lthrTestNote: String?
    @ObservationIgnored private var unsavedWorkout: SavedWorkout?
    static let saveErrorText = "This session couldn't be saved, probably because your iPhone is full. Nothing is lost: free up some space and reopen FIGHT, and it will offer to save it again."
    /// Round count for timed rounds without the bag coach (the bag coach counts its own).
    var plannedRounds: Int?

    // MARK: Live state
    private(set) var isRecording = false
    private(set) var startTime: Date?
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var samples: [HeartRatePoint] = []
    private(set) var zoneSeconds: [Int: TimeInterval] = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
    private(set) var activeCalories: Double = 0
    private(set) var bmrCalories: Double = 0
    private(set) var currentRound = 1
    private(set) var isRestPeriod = false
    private(set) var phaseElapsed: TimeInterval = 0
    private(set) var completedRounds: [RoundStat] = []
    private(set) var autoHRREvents: [AutoHRREvent] = []
    private(set) var latestAutoHRRBanner: String?
    var lthrTestResultBanner: Int?
    /// Zones before the last LTHR test, so its result can be undone.
    private var previousThreshold: (lthr: Int, method: ZoneCalculationMethod)?
    private(set) var liveAlpha1: Double?
    @ObservationIgnored private var lastAlpha1Elapsed: TimeInterval = 0
    private(set) var pendingRecoveryRemaining: Int?
    private(set) var bagSessionComplete = false

    // MARK: Plan runner state
    private(set) var queuedPlan: TrainingPlan?
    private(set) var runningPlan: TrainingPlan?
    private(set) var planBlockIndex = 0
    private(set) var planBlockElapsed: TimeInterval = 0
    private(set) var planTransitionRemaining: TimeInterval?
    private(set) var planComplete = false
    private(set) var blockResults: [BlockResult] = []
    private var blockStartElapsed: TimeInterval = 0
    private var blockStartStrikes = 0
    private(set) var blockExtraRounds = 0
    private(set) var blockExtraSeconds = 0
    /// Next time (block-elapsed seconds) a reaction call is spoken.
    private var nextCallAt: TimeInterval = 2
    private var roundNumberOffset = 0
    static let transitionSeconds: TimeInterval = 15
    static let firstBlockLeadIn: TimeInterval = 8

    // MARK: Flow state
    var finishedWorkout: SavedWorkout?
    var showingSummary = false
    var requestFinishPrompt = false
    var recoverableDraft: WorkoutDraft?

    // MARK: Private bookkeeping
    private var draftID = UUID()
    @ObservationIgnored private var timer: Timer?
    /// The clock is stopped (phone call, coach stopped the drill). Nothing is counted while paused.
    private(set) var isPaused = false
    /// Paused because a call came in (shown on screen so you know why).
    private(set) var pausedForCall = false
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    /// Pause automatically when a phone call comes in (set in You).
    static var pausesForCalls: Bool {
        UserDefaults.standard.object(forKey: "fight.pauseOnCalls") as? Bool ?? true
    }

    /// Seconds left of "Gloves on" before the bell; nil when not getting ready.
    private(set) var getReadyRemaining: Int?
    @ObservationIgnored private var getReadyTimer: Timer?
    /// The bag coach's voice is being prepared (usually instant; first time after a change, a few seconds).
    private(set) var preparingVoice = false
    /// Start as soon as the voice is ready (the countdown finished first).
    private(set) var startWhenVoiceReady = false
    /// The get-ready countdown length chosen in You (0 = off).
    static var getReadySeconds: Int {
        UserDefaults.standard.object(forKey: "fight.getReadySeconds") as? Int ?? 10
    }
    /// Whether a nod skips the countdown (AirPods with head tracking on).
    var nodSkipsGetReady: Bool { profile.trackHeadMovement && profile.nodToStart }
    private var lastTick: Date?
    private var lastDraftSave = Date.distantPast
    private var suppressDefaults = false
    private var loadingPrefs = false

    private var sumBPM = 0
    private var maxBPMSeen = 0

    private var currentRoundStartElapsed: TimeInterval = 0
    private var currentWorkEndElapsed: TimeInterval = 0
    private var currentRoundStartStrikes = 0
    private var roundEndPeakBPM = 0

    private struct PendingRecovery {
        let startElapsed: TimeInterval
        let peakBPM: Int
        let contextLabel: String
        var lowestSeenBPM: Int
    }
    private var pendingRecovery: PendingRecovery?

    private var lastAnnouncedZone = 0
    private var lastZone2AlertTime: TimeInterval = -999
    private var lastPeriodicMinute = 0
    private var redlineSecondsAccumulator: TimeInterval = 0
    private var lastRedlineAlertTime: TimeInterval = -999
    private var lastGhostAlertTime: TimeInterval = -999
    private var lastPlanAlertTime: TimeInterval = -999
    @ObservationIgnored private var hrAlertTracker = HRAlertTracker()
    @ObservationIgnored private var hrEstimator = HREstimator()
    @ObservationIgnored private var lastMoveDistance = 0.0
    @ObservationIgnored private var lastMoveClimb = 0.0
    /// Roadwork with a GPS position: calories come from movement, not heart rate.
    private var usesMovementCalories: Bool { run.isActive && !run.permissionDenied && run.hasFix }
    /// Estimated heart rate while the strap is off (nil when real readings are coming in).
    private(set) var estimatedBPM: Int?
    /// Estimates kept for the session (shown apart from real data).
    @ObservationIgnored private var estimatedSamples: [HeartRatePoint] = []
    /// Estimated burn while the strap was off (not in the measured calories).
    private(set) var estimatedCalories: Double = 0
    /// Seconds of real heart rate a FIGHT Logger sent back after gaps.
    private(set) var recoveredSeconds = 0
    /// When the current gap in heart rate started (the last real reading before it).
    @ObservationIgnored private var gapFrom: Date?
    @ObservationIgnored private var lastRealAt: Date?
    /// Completed pause intervals, used to compute per-timestamp elapsed time for logger gap fills.
    @ObservationIgnored private var completedPauseIntervals: [(start: Date, end: Date)] = []
    /// +1 above target, -1 under, 0 in range (for the live screen).
    private(set) var hrTargetPosition = 0
    private var lthrWarmupAnnounced = false
    private var finalRoundAnnounced = false

    @ObservationIgnored private var currentActivity: Activity<WorkoutActivityAttributes>?
    private var lastActivityPush = Date.distantPast
    private var lastActivityState: (bpm: Int, zone: Int, round: Int, rest: Bool)?

    // Signature-feature capture
    private var comboEvents: [ComboEvent] = []
    private var bestRecoveryRecord = 0
    private var recoveryRecordAnnounced = false
    private var nextBreathCue: TimeInterval?
    private var breathInhaleNext = true
    private var breathingUsed = false
    private var currentRoundStartHeadMoves = 0
    private var roundStartBounces = 0
    private var roundStartChin: Double = 0
    private var roundStartImpacts = 0
    /// Sensor counts captured at the bell, so rest time isn't counted in the round.
    private var workEndCounts: (moves: Int, bounces: Int, chin: Double, impacts: Int)?
    // Live AirPods cues
    private var firstRoundMovesPerMinute: Double?
    private var encourager = EncouragementCoach()
    private var firstRoundHitsPerMinute: Double?
    /// Recent (time, bag hit count) points for the live hit rate.
    private var hitTrail: [HitPoint] = []
    private struct HitPoint { let t: TimeInterval; let hits: Int }
    private var moveWindowStart: (t: TimeInterval, moves: Int)?
    private var moveCueGiven = false
    private var chinHighSince: TimeInterval?
    private var chinCueGiven = false
    private var chinBaselineSet = false
    /// Bag hits heard by the microphone this session.
    private(set) var bagHits = 0
    /// Jump heights (cm) measured by AirPods during plyo sets.
    private(set) var jumps: [Double] = []
    private(set) var setJumps: [Double] = []
    private var qualityStopGiven = false
    /// Movement per second (AirPods moves + bounces + bag hits), for finding rounds afterwards.
    @ObservationIgnored private var activityTrail: [ActivityPoint] = []
    @ObservationIgnored private var lastActivityTotal = 0
    private let debriefVoice = DebriefSpeaker()
    private var strapLostSince: Date?
    /// Short-lived banner, e.g. "New record: recovery −38 BPM".
    private(set) var liveRecordBanner: String?

    // MARK: Wiring

    func bind(ble: BLEHeartRateManager, store: WorkoutStore, health: HealthKitManager) {
        let firstBind = self.store == nil
        Self.shared = self
        audio.onComboPlayed = { [weak self] combo in self?.logCombo(combo) }
        self.ble = ble
        self.store = store
        self.health = health
        if firstBind {
            syncFromProfile()
            restoreLastSetup()
            recoverableDraft = loadDraft()
            retryPendingHealthSave()
        }
    }

    /// Re-attempts a Health save that persisted across a launch (e.g. app was killed before it fired).
    private func retryPendingHealthSave() {
        guard let idStr = UserDefaults.standard.string(forKey: Self.pendingHealthSaveKey),
              let id = UUID(uuidString: idStr),
              let store, let health, health.autoSaveEnabled else { return }
        if health.savedWorkoutIDs.contains(id) {
            UserDefaults.standard.removeObject(forKey: Self.pendingHealthSaveKey)
            return
        }
        guard let workout = store.workouts.first(where: { $0.id == id }) else {
            UserDefaults.standard.removeObject(forKey: Self.pendingHealthSaveKey)
            return
        }
        let samples = store.resolvedSamples(for: workout)
        let route = store.loadRoute(for: id)
        Task {
            await health.save(workout: workout, samples: samples, route: route)
            UserDefaults.standard.removeObject(forKey: Self.pendingHealthSaveKey)
        }
    }

    /// Reloads per-fighter bag preferences (call when the active profile changes).
    func syncFromProfile() {
        guard !isRecording, let store else { return }
        loadingPrefs = true
        bagPrefs = store.activeProfile.bagPreferences
        loadingPrefs = false
    }

    private var profile: AthleteProfile { store?.activeProfile ?? AthleteProfile() }
    private var currentBPM: Int { ble?.currentBPM ?? 0 }

    var liveAverageBPM: Int { samples.isEmpty ? currentBPM : sumBPM / samples.count }
    var liveMaxBPM: Int { samples.isEmpty ? currentBPM : maxBPMSeen }
    var currentPhaseTarget: TimeInterval { TimeInterval(isRestPeriod ? restDurationSeconds : workDurationSeconds) }
    var phaseRemaining: TimeInterval { max(0, currentPhaseTarget - phaseElapsed) }
    var totalBagRounds: Int { bagPrefs.estimatedTotalRounds }

    var isRunningPlan: Bool { runningPlan != nil }
    var isInPlanTransition: Bool { planTransitionRemaining != nil }

    /// The block being run (or, during a transition, the one coming up).
    var currentBlock: PlanBlock? {
        guard let p = runningPlan, planBlockIndex < p.blocks.count else { return nil }
        return p.blocks[planBlockIndex]
    }

    var upcomingBlock: PlanBlock? {
        guard let p = runningPlan else { return nil }
        let i = isInPlanTransition ? planBlockIndex : planBlockIndex + 1
        return i < p.blocks.count ? p.blocks[i] : nil
    }

    /// Rounds in the current round-based unit: a plan block, or a bag session.
    var roundsLimit: Int? {
        if isRunningPlan {
            guard let b = currentBlock, b.kind.isRoundBased, !isInPlanTransition, !planComplete else { return nil }
            return b.rounds + blockExtraRounds
        }
        return bagEnabled ? totalBagRounds : (roundTimerEnabled ? plannedRounds : nil)
    }

    /// Time left in a timed (non-round) plan block.
    var blockRemaining: TimeInterval {
        guard let b = currentBlock, !b.kind.isRoundBased, !isInPlanTransition else { return 0 }
        return max(0, Double(b.durationSeconds + blockExtraSeconds) - planBlockElapsed)
    }

    /// HR band to hold right now: the plan block's target, else a Coach-tab prescription.
    var activeTargetRange: ClosedRange<Int>? {
        if isRunningPlan {
            guard !isInPlanTransition, !planComplete, let t = currentBlock?.target else { return nil }
            return t.bpmRange(for: profile)
        }
        if let p = activePlan { return p.targetLowBPM...max(p.targetLowBPM, p.targetHighBPM) }
        return nil
    }

    // MARK: Setup changes

    // MARK: Remembered setup

    private var setupMemoryKey: String { "fight.setup.\(profile.id.uuidString)" }

    private func loadSetupMemory() -> WorkoutSetupMemory {
        guard let data = UserDefaults.standard.data(forKey: setupMemoryKey),
              let m = try? JSONDecoder().decode(WorkoutSetupMemory.self, from: data) else { return WorkoutSetupMemory() }
        return m
    }

    private var currentSetup: WorkoutSetup {
        WorkoutSetup(category: selectedCategory, drill: selectedDrillTag, roundTimer: roundTimerEnabled,
                     workSeconds: workDurationSeconds, restSeconds: restDurationSeconds, bag: bagEnabled,
                     activity: activityName, rounds: bagEnabled ? bagPrefs.estimatedTotalRounds : plannedRounds,
                     tempo: bagEnabled ? bagPrefs.tempo : nil)
    }

    /// Saves this workout's setup so the next one starts the same way (per workout type).
    private func rememberSetup() {
        guard selectedCategory != .lthrTest, queuedPlan == nil, runningPlan == nil else { return }
        var m = loadSetupMemory()
        m.last = currentSetup
        m.byCategory[selectedCategory.rawValue] = currentSetup
        if let data = try? JSONEncoder().encode(m) { UserDefaults.standard.set(data, forKey: setupMemoryKey) }
    }

    /// Puts back the setup from your last workout (call on launch and when the fighter changes).
    func restoreLastSetup() {
        guard !isRecording, queuedPlan == nil, let last = loadSetupMemory().last else { return }
        apply(last)
    }

    private func apply(_ s: WorkoutSetup) {
        suppressDefaults = true
        selectedCategory = s.category
        suppressDefaults = false
        let c = s.category
        // Only what fits the workout type survives (a run never comes back with a bag coach or rounds).
        selectedDrillTag = c.drillTags.contains(s.drill) ? s.drill : c.defaultDrill
        bagEnabled = s.bag && c.allowsBagCoach
        roundTimerEnabled = (s.roundTimer || bagEnabled) && c.allowsRounds
        activityName = s.activity
        plannedRounds = roundTimerEnabled && !bagEnabled ? s.rounds : nil
        if bagEnabled, let r = s.rounds {
            var prefs = bagPrefs
            prefs.workSeconds = s.workSeconds
            prefs.restSeconds = s.restSeconds
            prefs.totalMinutes = Self.bagMinutes(rounds: r, work: s.workSeconds, rest: s.restSeconds)
            if let t = s.tempo { prefs.tempo = t }
            bagPrefs = prefs
            workDurationSeconds = s.workSeconds
            restDurationSeconds = s.restSeconds
        }
        if !bagEnabled {
            workDurationSeconds = s.workSeconds
            restDurationSeconds = s.restSeconds
        }
    }

    /// First-run setup: default workout type and round length for this fighter.
    func applyFirstSetup(discipline: String, roundMinutes: Int) {
        guard !isRecording else { return }
        let category: WorkoutCategory
        switch discipline {
        case "Muay Thai": category = .muayThai
        case "Boxing": category = .heavyBag
        case "BJJ", "Wrestling": category = .bjj
        default: category = .kickboxing
        }
        apply(WorkoutSetup(category: category, drill: .technical, roundTimer: true,
                           workSeconds: roundMinutes * 60, restSeconds: 60, bag: false))
        rememberSetup()
    }

    /// One line describing what Start will do, e.g. "Muay Thai · 5 × 3:00 · Bag Coach".
    var setupSummary: String {
        if let plan = queuedPlan { return plan.title }
        var parts = [selectedCategory.rawValue]
        if selectedCategory == .lthrTest { return "30-min threshold test" }
        func clockShort(_ s: Int) -> String { s % 60 == 0 ? "\(s / 60):00" : String(format: "%d:%02d", s / 60, s % 60) }
        if let name = activityName {
            if bagEnabled { return "\(name) · \(bagPrefs.estimatedTotalRounds) × \(clockShort(bagPrefs.workSeconds))" }
            if roundTimerEnabled, let r = plannedRounds { return "\(name) · \(r) × \(clockShort(workDurationSeconds))" }
            return name
        }
        if selectedCategory.isRun { return "\(selectedCategory.rawValue) · \(selectedDrillTag.label(for: selectedCategory))" }
        func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
        if bagEnabled {
            parts.append("\(bagPrefs.estimatedTotalRounds) × \(clock(bagPrefs.workSeconds))")
            parts.append("Bag Coach")
        } else if roundTimerEnabled {
            parts.append("\(clock(workDurationSeconds)) rounds")
        }
        return parts.joined(separator: " · ")
    }

    private func applyDisciplineDefaults(_ category: WorkoutCategory) {
        if let saved = loadSetupMemory().byCategory[category.rawValue] {
            apply(saved)
            return
        }
        roundTimerEnabled = category.usesRoundTimerByDefault && category.allowsRounds
        workDurationSeconds = category.defaultWorkSeconds
        restDurationSeconds = category.defaultRestSeconds
        selectedDrillTag = category.defaultDrill
        if !category.allowsBagCoach { bagEnabled = false }
        if !category.allowsPlans { unqueuePlan() }
        if !category.allowsGhost { selectedGhost = nil }
    }

    private func bagEnabledChanged() {
        if bagEnabled {
            roundTimerEnabled = true
            workDurationSeconds = bagPrefs.workSeconds
            restDurationSeconds = bagPrefs.restSeconds
            if isRecording {
                startBagCoach()
            } else if bagPrefs.mode != .cadenceBeep {
                let prefs = bagPrefs
                Task { await audio.prepareVocabulary(prefs: prefs) }
            }
        } else {
            audio.stopBagCoach()
        }
    }

    private func bagPrefsChanged(old: BagPreferences) {
        if let store {
            var p = store.activeProfile
            p.bagPreferences = bagPrefs
            store.activeProfile = p
        }
        if bagEnabled && !isRecording {
            workDurationSeconds = bagPrefs.workSeconds
            restDurationSeconds = bagPrefs.restSeconds
        }
        let voiceChanged = old.stance != bagPrefs.stance || old.numberCalls != bagPrefs.numberCalls || old.tempo != bagPrefs.tempo
        if voiceChanged && bagEnabled && bagPrefs.mode != .cadenceBeep && !isRecording {
            let prefs = bagPrefs
            Task { await audio.prepareVocabulary(prefs: prefs) }
        }
        if isRecording && bagEnabled {
            startBagCoach()
        }
    }

    func apply(_ p: WorkoutPrescription) {
        guard !isRecording else { return }
        suppressDefaults = true
        selectedCategory = p.category
        suppressDefaults = false
        selectedDrillTag = p.drillTag
        var prefs = bagPrefs
        prefs.workSeconds = p.workSeconds
        prefs.restSeconds = p.restSeconds
        prefs.tempo = p.bagTempo
        let totals = [10, 15, 20, 30, 45, 60]
        prefs.totalMinutes = totals.min(by: { abs($0 - p.durationMinutes) < abs($1 - p.durationMinutes) }) ?? 30
        bagPrefs = prefs
        let noBag: [WorkoutCategory] = [.walk, .roadwork, .lthrTest]
        bagEnabled = p.useBagCoach && !noBag.contains(p.category)
        roundTimerEnabled = p.roundTimer
        workDurationSeconds = p.workSeconds
        restDurationSeconds = p.restSeconds
        activityName = nil
        plannedRounds = p.roundTimer && !bagEnabled ? p.rounds : nil
        activePlan = p
    }

    /// Bag-coach minutes that give exactly `rounds` rounds (the bag coach counts by total time).
    static func bagMinutes(rounds: Int, work: Int, rest: Int) -> Int {
        max(1, Int((Double(rounds * (work + rest) - rest) / 60).rounded(.up)))
    }

    /// Sets up a workout chosen behind one of the three doors.
    func choose(_ option: ActivityOption, length: LengthOption?) {
        guard !isRecording else { return }
        unqueuePlan()
        activePlan = nil
        suppressDefaults = true
        selectedCategory = option.category
        suppressDefaults = false
        selectedDrillTag = option.drill
        selectedGhost = nil
        if option.bagCoach, let l = length {
            var prefs = bagPrefs
            prefs.workSeconds = l.work
            prefs.restSeconds = l.rest
            prefs.totalMinutes = Self.bagMinutes(rounds: l.rounds, work: l.work, rest: l.rest)
            if let t = l.tempo { prefs.tempo = t }
            bagPrefs = prefs
        }
        bagEnabled = option.bagCoach
        roundTimerEnabled = length != nil
        if let l = length {
            workDurationSeconds = l.work
            restDurationSeconds = l.rest
        }
        plannedRounds = option.bagCoach ? nil : length?.rounds
        activityName = option.displayName
    }

    // MARK: Training plans

    /// Loads a plan to run on the next Start.
    func queue(_ plan: TrainingPlan) {
        guard !isRecording else { return }
        suppressDefaults = true
        selectedCategory = plan.category
        suppressDefaults = false
        bagEnabled = false
        activePlan = nil
        activityName = nil
        plannedRounds = nil
        queuedPlan = plan
    }

    func unqueuePlan() {
        guard !isRecording else { return }
        queuedPlan = nil
    }

    private func prefs(for block: PlanBlock) -> BagPreferences {
        var p = bagPrefs // keeps the fighter's stance, call style, level and strike toggles
        p.tempo = block.tempo
        p.workSeconds = block.workSeconds
        p.restSeconds = block.restSeconds
        if block.combos.isEmpty {
            p.customOnly = false
        } else {
            p.customCombos = block.combos
            p.customOnly = true
        }
        return p
    }

    private func beginTransition(to index: Int, seconds: TimeInterval) {
        guard let plan = runningPlan, index < plan.blocks.count else { return }
        audio.stopBagCoach()
        roundTimerEnabled = false
        isRestPeriod = false
        phaseElapsed = 0
        planBlockIndex = index
        planBlockElapsed = 0
        planTransitionRemaining = seconds
        let b = plan.blocks[index]
        let lead = index == 0 ? "First up: " : "Next up: "
        audio.announceCoachingCue(lead + b.spokenIntro + (b.cue.isEmpty ? "" : " \(b.cue)"), enabled: true)
    }

    private func startBlock(_ index: Int) {
        guard let plan = runningPlan, index < plan.blocks.count else { return }
        let b = plan.blocks[index]
        planBlockIndex = index
        planBlockElapsed = 0
        planTransitionRemaining = nil
        blockExtraRounds = 0
        blockExtraSeconds = 0
        nextCallAt = 2
        setJumps = []
        qualityStopGiven = false
        blockStartElapsed = elapsedSeconds
        blockStartStrikes = audio.strikesCuedCount
        roundNumberOffset = completedRounds.count
        pendingRecovery = nil
        pendingRecoveryRemaining = nil

        if b.kind.isRoundBased {
            roundTimerEnabled = true
            workDurationSeconds = b.workSeconds
            restDurationSeconds = b.restSeconds
            currentRound = 1
            isRestPeriod = false
            phaseElapsed = 0
            currentRoundStartElapsed = elapsedSeconds
            currentWorkEndElapsed = 0
            currentRoundStartStrikes = audio.strikesCuedCount
            roundEndPeakBPM = 0
        } else {
            roundTimerEnabled = false
            isRestPeriod = false
            phaseElapsed = 0
        }
        audio.playRoundStartBell()
        if b.kind == .bagRounds {
            startBagCoach(prefs: prefs(for: b))
        } else {
            audio.stopBagCoach()
        }
        saveDraft()
    }

    private func appendResult(for b: PlanBlock, completed: Bool, start: TimeInterval) {
        let blockSamples = samples.filter { $0.elapsedSeconds >= start }
        let bpms = blockSamples.map(\.bpm)
        var inTarget: Double?
        if let t = b.target, !bpms.isEmpty {
            let r = t.bpmRange(for: profile)
            inTarget = Double(bpms.filter { r.contains($0) }.count) / Double(bpms.count)
        }
        blockResults.append(BlockResult(
            blockID: b.id, title: b.title, kind: b.kind, plannedSeconds: b.plannedSeconds,
            startElapsed: start, endElapsed: elapsedSeconds, completed: completed,
            avgBPM: bpms.isEmpty ? nil : bpms.reduce(0, +) / bpms.count,
            peakBPM: bpms.max(), timeInTarget: inTarget, targetLabel: b.target?.label,
            roundsCompleted: b.kind.isRoundBased ? max(0, completedRounds.count - roundNumberOffset) : nil,
            strikesCalled: max(0, audio.strikesCuedCount - blockStartStrikes)
        ))
    }

    /// Ends the running block (naturally, via "Done", or skipped) and moves on.
    func finishCurrentBlock(skipped: Bool = false) {
        guard isRecording, let plan = runningPlan, !planComplete else { return }
        if isInPlanTransition {
            // Skipping the block that was about to start.
            if let b = currentBlock {
                blockStartStrikes = audio.strikesCuedCount
                roundNumberOffset = completedRounds.count
                appendResult(for: b, completed: false, start: elapsedSeconds)
            }
        } else if let b = currentBlock {
            if b.kind.isRoundBased && skipped && !isRestPeriod {
                currentWorkEndElapsed = elapsedSeconds
                recordRound(stoolDrop: nil)
            }
            appendResult(for: b, completed: !skipped, start: blockStartElapsed)
            if let best = setJumps.max() {
                audio.announceCoachingCue("Best jump \(jumpText(best)).", enabled: true)
            }
            audio.flushCombos()
            if !b.kind.isRoundBased || skipped { audio.playRoundEndBell() }
        }
        audio.stopBagCoach()
        roundTimerEnabled = false
        isRestPeriod = false
        pendingRecovery = nil
        pendingRecoveryRemaining = nil

        let next = planBlockIndex + 1
        if next < plan.blocks.count {
            beginTransition(to: next, seconds: Self.transitionSeconds)
        } else {
            planTransitionRemaining = nil
            planComplete = true
            audio.announceCoachingCue("Plan complete. Great work.", enabled: true)
            requestFinishPrompt = true
        }
        saveDraft()
    }

    func startNextBlockNow() {
        guard isInPlanTransition else { return }
        startBlock(planBlockIndex)
    }

    /// +1 round for round blocks, +1 minute for timed blocks.
    func extendCurrentBlock() {
        guard let b = currentBlock, !isInPlanTransition, !planComplete else { return }
        if b.kind.isRoundBased { blockExtraRounds += 1 } else { blockExtraSeconds += 60 }
    }

    private func advancePlan(by dt: TimeInterval) {
        if let t = planTransitionRemaining {
            let after = t - dt
            if t > 3 && after <= 3 && profile.audioCoach.clapperWarnings { audio.playClapper() }
            if after <= 0 {
                startBlock(planBlockIndex)
            } else {
                planTransitionRemaining = after
            }
            return
        }
        guard let b = currentBlock, !b.kind.isRoundBased else { return }
        planBlockElapsed += dt
        let total = Double(b.durationSeconds + blockExtraSeconds)
        let before = total - (planBlockElapsed - dt)
        let after = total - planBlockElapsed
        if total > 30 && before > 10 && after <= 10 && profile.audioCoach.clapperWarnings { audio.playClapper() }
        if total >= 240 && before > total / 2 && after <= total / 2 {
            audio.announceCoachingCue("Halfway.", enabled: true)
        }
        // Reaction game: random calls ("Left", "Up"...) every 1.8–2.8 s.
        if !b.calls.isEmpty, planBlockElapsed >= nextCallAt, after > 1, let call = b.calls.randomElement() {
            audio.announceCoachingCue(call, enabled: true)
            nextCallAt = planBlockElapsed + Double.random(in: 1.8...2.8)
        }
        // Rest until recovered: move on early once the heart rate is back down (at least 45 s rest).
        if b.untilRecovered, planBlockElapsed >= 45, after > 3, currentBPM > 0,
           currentBPM <= profile.activeZones.z1Max + 5 {
            audio.announceCoachingCue("Recovered. Go.", enabled: true)
            finishCurrentBlock()
            return
        }
        if after <= 0 { finishCurrentBlock() }
    }

    // MARK: Start / stop

    /// Start from a button: rounds and bag work get a short "gloves on" countdown first,
    /// so the first call doesn't come while you're still strapping up.
    func begin() {
        guard !isRecording, getReadyRemaining == nil, !startWhenVoiceReady else { return }
        // The coach's voice gets ready while you glove up, instead of making you wait first.
        if bagEnabled && !preparingVoice {
            preparingVoice = true
            let prefs = bagPrefs
            Task { [weak self] in
                guard let self else { return }
                await self.audio.prepareVocabulary(prefs: prefs)
                self.preparingVoice = false
                if self.startWhenVoiceReady {
                    self.startWhenVoiceReady = false
                    self.startWorkout()
                }
            }
        }
        let lead = Self.getReadySeconds
        guard lead > 0, bagEnabled || roundTimerEnabled, queuedPlan == nil, !tracksGPS else {
            startOrWaitForVoice()
            return
        }
        getReadyRemaining = lead
        UIApplication.shared.isIdleTimerDisabled = true
        audio.prepareForWorkout(settings: profile.audioCoach)
        audio.announceCoachingCue("Gloves on. Square up.", enabled: true)
        if nodSkipsGetReady {
            headMotion.start()
            headMotion.onNod = { [weak self] in self?.skipGetReady() }
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.getReadyTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        getReadyTimer = t
    }

    private func getReadyTick() {
        guard let r = getReadyRemaining else { return }
        let next = r - 1
        if next <= 0 {
            skipGetReady()
            return
        }
        getReadyRemaining = next
        if next <= 3 { audio.announceCoachingCue("\(next)", enabled: true) }
    }

    /// Skip the rest of the countdown (button or nod) and ring the bell.
    func skipGetReady() {
        guard getReadyRemaining != nil else { return }
        getReadyTimer?.invalidate()
        getReadyTimer = nil
        getReadyRemaining = nil
        headMotion.onNod = nil
        startOrWaitForVoice()
    }

    private func startOrWaitForVoice() {
        if preparingVoice {
            startWhenVoiceReady = true
        } else {
            startWorkout()
        }
    }

    /// Back out before the bell: nothing is recorded.
    func cancelGetReady() {
        guard getReadyRemaining != nil || startWhenVoiceReady else { return }
        startWhenVoiceReady = false
        getReadyTimer?.invalidate()
        getReadyTimer = nil
        getReadyRemaining = nil
        headMotion.onNod = nil
        headMotion.stop()
        audio.shutdownAudio()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func startWorkout() {
        guard !isRecording else { return }
        debriefVoice.stop()
        flushPendingHealthSave()
        // A finished session that couldn't be saved is still in the crash-safety copy, which a new
        // session would overwrite: save it first, or don't start.
        if let unsaved = unsavedWorkout {
            guard store?.save(unsaved) == true else {
                saveError = Self.saveErrorText
                return
            }
            unsavedWorkout = nil
            deleteDraft()
        }
        rememberSetup()
        isPaused = false
        pausedForCall = false
        pausedAt = nil
        pausedTotal = 0
        draftID = UUID()
        draftSamplesWritten = 0
        samples.removeAll()
        zoneSeconds = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        activeCalories = 0
        bmrCalories = 0
        elapsedSeconds = 0
        sumBPM = 0
        maxBPMSeen = 0
        currentRound = 1
        isRestPeriod = false
        phaseElapsed = 0
        currentRoundStartElapsed = 0
        currentWorkEndElapsed = 0
        currentRoundStartStrikes = 0
        roundEndPeakBPM = 0
        completedRounds.removeAll()
        pendingRecovery = nil
        pendingRecoveryRemaining = nil
        autoHRREvents.removeAll()
        latestAutoHRRBanner = nil
        lthrTestResultBanner = nil
        lastAnnouncedZone = 0
        lastZone2AlertTime = -999
        lastPeriodicMinute = 0
        redlineSecondsAccumulator = 0
        lastRedlineAlertTime = -999
        lastGhostAlertTime = -999
        lastPlanAlertTime = -999
        hrAlertTracker = HRAlertTracker()
        hrTargetPosition = 0
        hrEstimator = HREstimator()
        completedPauseIntervals = []
        lastMoveDistance = 0
        lastMoveClimb = 0
        estimatedBPM = nil
        estimatedSamples = []
        estimatedCalories = 0
        recoveredSeconds = 0
        gapFrom = nil
        lastRealAt = nil
        lthrWarmupAnnounced = false
        finalRoundAnnounced = false
        bagSessionComplete = false
        requestFinishPrompt = false
        liveAlpha1 = nil
        lastAlpha1Elapsed = 0
        audio.strikesCuedCount = 0
        comboEvents = []
        bestRecoveryRecord = store.map { Records.bestRecovery(workouts: $0.workouts, profileID: $0.activeProfileID) } ?? 0
        recoveryRecordAnnounced = false
        liveRecordBanner = nil
        nextBreathCue = nil
        breathInhaleNext = true
        breathingUsed = false
        currentRoundStartHeadMoves = 0
        roundStartBounces = 0
        roundStartChin = 0
        roundStartImpacts = 0
        workEndCounts = nil
        firstRoundMovesPerMinute = nil
        encourager = EncouragementCoach()
        firstRoundHitsPerMinute = nil
        hitTrail = []
        moveWindowStart = nil
        moveCueGiven = false
        chinHighSince = nil
        chinCueGiven = false
        chinBaselineSet = false
        bagHits = 0
        jumps = []
        setJumps = []
        activityTrail = []
        lastActivityTotal = 0
        strapLostSince = nil
        engageSensors()
        runningPlan = queuedPlan
        queuedPlan = nil
        planBlockIndex = 0
        planBlockElapsed = 0
        planTransitionRemaining = nil
        planComplete = false
        blockResults = []
        blockExtraRounds = 0
        blockExtraSeconds = 0
        roundNumberOffset = 0
        _ = ble?.consumeLatestRRIntervals()

        let now = Date()
        startTime = now
        lastTick = now
        lastDraftSave = now
        isRecording = true
        if tracksGPS { startRun(at: now) }
        UIApplication.shared.isIdleTimerDisabled = true

        audio.prepareForWorkout(settings: profile.audioCoach)
        if isRunningPlan {
            bagEnabled = false
            beginTransition(to: 0, seconds: Self.firstBlockLeadIn)
        } else {
            if roundTimerEnabled || bagEnabled {
                audio.playRoundStartBell()
            }
            if bagEnabled {
                if totalBagRounds == 1 { announceFinalRound() }
                startBagCoach()
            }
        }
        startLiveActivity()

        startClock()
    }

    /// Total pause time from all completed pauses that ended at or before `time`.
    private func pausedSecondsBefore(_ time: Date) -> TimeInterval {
        completedPauseIntervals
            .filter { $0.end <= time }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Real readings a FIGHT Logger kept while the phone was out of range: they fill the gaps,
    /// count like any other reading, and replace the estimates for the same stretch.
    private func mergeLoggerReadings(_ readings: [LoggerProtocol.Reading]) {
        guard isRecording, let start = startTime else { return }
        let fill = LoggerProtocol.gapFillers(readings, existing: samples.map(\.timestamp), from: start, to: Date())
        guard !fill.isEmpty else { return }
        let p = profile
        for r in fill {
            let elapsed = max(0, r.time.timeIntervalSince(start) - pausedSecondsBefore(r.time))
            samples.append(HeartRatePoint(timestamp: r.time, elapsedSeconds: elapsed, bpm: r.bpm, rrIntervalsMs: []))
            sumBPM += r.bpm
            maxBPMSeen = max(maxBPMSeen, r.bpm)
            zoneSeconds[p.zone(for: r.bpm).number, default: 0] += 1
            if !usesMovementCalories {
                activeCalories += FighterAnalytics.calculateCalorieBreakdown(bpm: r.bpm, durationSeconds: 1, profile: p).active
            }
        }
        samples.sort { $0.timestamp < $1.timestamp }
        if let first = fill.first?.time, let last = fill.last?.time, !estimatedSamples.isEmpty {
            let before = estimatedSamples.count
            estimatedSamples.removeAll { $0.timestamp >= first.addingTimeInterval(-1) && $0.timestamp <= last.addingTimeInterval(1) }
            estimatedCalories *= Double(estimatedSamples.count) / Double(before)
        }
        recoveredSeconds += fill.count
        // Samples were inserted in the middle: rewrite the recovery copy in full.
        draftSamplesWritten = 0
        saveDraft()
    }

    /// Head tracking, nods, call pausing and bag-hit counting for a live session.
    private func engageSensors() {
        ble?.onLoggerReadings = { [weak self] readings in self?.mergeLoggerReadings(readings) }
        if profile.trackHeadMovement {
            headMotion.start()
            headMotion.trackingChin = roundTimerEnabled
            headMotion.onJump = { [weak self] cm in self?.recordJump(cm) }
            if profile.nodToStart {
                headMotion.onNod = { [weak self] in self?.handleNod() }
            } else {
                headMotion.onNod = nil
            }
        }
        audio.onInterruptionBegan = { [weak self] in
            guard Self.pausesForCalls else { return }
            self?.pause(forCall: true)
        }
        let countHits = profile.countBagHits && bagEnabled
        audio.countBagHits = countHits
        if countHits {
            audio.onBagHit = { [weak self] in self?.bagHits += 1 }
        } else {
            audio.onBagHit = nil
        }
    }

    private func startClock() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        saveDraft()
    }

    // MARK: Resume a session that was ended by mistake

    /// The session just ended was a plan (plans can't be picked up again).
    @ObservationIgnored private var finishedWasPlan = false

    /// "Resume" on the summary: the session you just ended can carry on, within 15 minutes.
    /// Not for plans or the threshold test (the test may already have changed your zones).
    var canResumeFinished: Bool {
        guard let w = finishedWorkout, !isRecording else { return false }
        return !finishedWasPlan && w.category != .lthrTest && Date().timeIntervalSince(w.endDate) < 15 * 60
    }

    /// Un-end the session: the saved copy is removed and the clock carries on from where it
    /// stopped. The time in between doesn't count.
    func resumeFinished() {
        guard canResumeFinished, let w = finishedWorkout, let store else { return }
        pendingHealthSave = nil
        store.permanentlyDelete(w)
        if unsavedWorkout?.id == w.id { unsavedWorkout = nil }
        finishedWorkout = nil
        showingSummary = false
        workoutNotes = w.notes
        let now = Date()
        pausedTotal += max(0, now.timeIntervalSince(w.endDate))
        isPaused = false
        pausedForCall = false
        pausedAt = nil
        draftID = UUID()
        draftSamplesWritten = 0
        lastTick = now
        lastDraftSave = now
        lastActivityState = nil
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
        engageSensors()
        if tracksGPS { run.resumeAfterFinish() }
        audio.prepareForWorkout(settings: profile.audioCoach)
        audio.announceCoachingCue("Back to work.", enabled: true)
        if roundTimerEnabled && !isRestPeriod { audio.playRoundStartBell() }
        if bagEnabled && !bagSessionComplete { startBagCoach() }
        startLiveActivity()
        startClock()
    }

    private func startBagCoach(prefs override: BagPreferences? = nil) {
        let context = BagLoopContext(
            isWorkPhase: { [weak self] in
                guard let self else { return false }
                return self.isRecording && !self.isPaused && !self.bagSessionComplete && !self.isInPlanTransition && !self.planComplete
                    && (!self.roundTimerEnabled || !self.isRestPeriod)
            },
            roundProgress: { [weak self] in
                guard let self, self.roundTimerEnabled, self.workDurationSeconds > 0 else { return 0.5 }
                return min(1, self.livePhaseElapsed / Double(self.workDurationSeconds))
            },
            workRemaining: { [weak self] in
                guard let self, self.roundTimerEnabled, !self.isRestPeriod else { return nil }
                return Double(self.workDurationSeconds) - self.livePhaseElapsed
            },
            hrBandStatus: { [weak self] in
                guard let self, let range = self.activeTargetRange else { return 0 }
                let bpm = self.currentBPM
                if bpm <= 0 { return 0 }
                if bpm < range.lowerBound { return -1 }
                if bpm > range.upperBound { return 1 }
                return 0
            }
        )
        let prefsNow = override ?? bagPrefs
        // Lean toward the technique you haven't drilled lately; on easy days, call your most
        // expensive combos less so the heart rate stays where the session wants it.
        let insights = store?.coachInsights
        audio.focusStrikes = insights?.neglected.map { ComboGenerator.strikes(forFocus: $0.tag) } ?? []
        let easy = prefsNow.tempo == .technical || prefsNow.tempo == .steady
        audio.avoidComboLabels = easy ? Set(insights?.comboCost?.mostExpensive.map(\.label) ?? []) : []
        audio.startBagCoach(prefs: prefsNow, context: context)
    }

    /// Phase time including the fraction since the last 1-s tick (smooth countdowns).
    private var livePhaseElapsed: TimeInterval {
        phaseElapsed + (lastTick.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func stopRecordingCommon() {
        if isPaused, let at = pausedAt { pausedTotal += Date().timeIntervalSince(at) }
        timer?.invalidate()
        timer = nil
        lastTick = nil
        isRecording = false
        isPaused = false
        pausedForCall = false
        pausedAt = nil
        audio.onInterruptionBegan = nil
        ble?.onLoggerReadings = nil
        run.holdDistance = false
        UIApplication.shared.isIdleTimerDisabled = false
        headMotion.stop()
        headMotion.onNod = nil
        headMotion.onJump = nil
        run.stop()
        audio.onBagHit = nil
        audio.countBagHits = false
        audio.shutdownAudio()
        endLiveActivity()
    }

    func finishAndSave() {
        guard isRecording, let store else { return }
        if isRunningPlan && !planComplete, let b = currentBlock {
            if isInPlanTransition {
                // Remaining blocks were never started.
            } else {
                appendResult(for: b, completed: false, start: blockStartElapsed)
            }
        }
        let end = Date()
        let runResult = run.finish()
        let draft = makeDraft(now: end)
        stopRecordingCommon()

        let current = store.activeProfile
        if selectedCategory == .lthrTest {
            // Only a real test changes your zones: at least 15 of the 20 effort minutes, with heart rate.
            let trial = samples.filter { $0.elapsedSeconds >= 600 }
            let source = trial
            if trial.count < 900 {
                lthrTestNote = trial.isEmpty
                    ? "The test ended before the 20-minute effort started, so your zones haven't changed."
                    : "The test needs at least 15 minutes of the 20-minute effort with your strap on. You did \(trial.count / 60) min, so your zones haven't changed."
            } else {
                var updated = current
                previousThreshold = (current.lactateThresholdHR, current.zoneMethod)
                updated.lactateThresholdHR = source.map(\.bpm).reduce(0, +) / source.count
                updated.zoneMethod = .lactateThreshold
                updated.sanitize()
                store.activeProfile = updated
                lthrTestResultBanner = updated.lactateThresholdHR
            }
        }

        var saved = WorkoutFinalizer.makeWorkout(from: draft, profile: current, ghost: selectedGhost, end: end)
        if let runResult {
            saved.run = runResult.summary
            store.saveRoute(runResult.route, for: saved.id)
            if !saved.hasHeartRate {
                // No strap: estimate the burn from distance (≈1 kcal per kg per km running, about half walking).
                let km = runResult.summary.distanceM / 1000
                saved.activeCalories = current.weightKg * km * (saved.category == .walk ? 0.53 : 1.0)
                saved.calories = saved.activeCalories + saved.bmrCalories
            }
        }
        if store.save(saved) {
            deleteDraft()
        } else {
            // Not written (phone full?): the crash-safety copy stays and is offered again next launch.
            unsavedWorkout = saved
            saveError = Self.saveErrorText
        }

        if let health, health.autoSaveEnabled {
            // Sent to Apple Health once you close the summary, so "Discard" can still
            // take it back without leaving a copy in Health.
            let sensor = ble?.sensorInfo
            let hkSamples = saved.samples
            let route = runResult?.route ?? []
            // Persist the ID so the next launch can retry if the app is killed before the save fires.
            UserDefaults.standard.set(saved.id.uuidString, forKey: Self.pendingHealthSaveKey)
            pendingHealthSave = {
                Task {
                    await health.save(workout: saved, samples: hkSamples, sensor: sensor, route: route)
                    UserDefaults.standard.removeObject(forKey: Self.pendingHealthSaveKey)
                }
            }
        }

        speakDebrief(saved, history: store.workouts, profile: current)
        finishedWasPlan = isRunningPlan
        finishedWorkout = saved
        workoutNotes = ""
        activePlan = nil
        resetPlanState()
        showingSummary = true
    }

    /// Apple Health copy of the session just finished, sent when its summary closes.
    @ObservationIgnored private var pendingHealthSave: (() -> Void)?
    private static let pendingHealthSaveKey = "fight_pending_health_save_id_v1"

    /// Send the finished session to Apple Health (summary closed, app backgrounded, or a new session).
    func flushPendingHealthSave() {
        let save = pendingHealthSave
        pendingHealthSave = nil
        save?()
    }

    /// Throw away the session that was just saved (from its summary). It goes to Recently Deleted
    /// for 30 days, and never reaches Apple Health. Returns it so it can be restored.
    func discardFinished() -> SavedWorkout? {
        guard let w = finishedWorkout, let store else { return nil }
        pendingHealthSave = nil
        store.delete(w)
        finishedWorkout = nil
        showingSummary = false
        return w
    }

    /// Discards the session into Recently Deleted (so it can still be restored) and returns it.
    @discardableResult
    func discard() -> SavedWorkout? {
        guard isRecording else { return nil }
        let end = Date()
        let draft = makeDraft(now: end)
        stopRecordingCommon()
        var trashed: SavedWorkout?
        if let store, !draft.samples.isEmpty || draft.elapsedSeconds >= 60 {
            let w = WorkoutFinalizer.makeWorkout(from: draft, profile: store.activeProfile, ghost: nil, end: end)
            store.saveToTrash(w)
            trashed = w
        }
        deleteDraft()
        samples.removeAll()
        completedRounds.removeAll()
        elapsedSeconds = 0
        liveAlpha1 = nil
        resetPlanState()
        return trashed
    }

    private func resetPlanState() {
        runningPlan = nil
        planComplete = false
        planTransitionRemaining = nil
        planBlockIndex = 0
        planBlockElapsed = 0
        blockResults = []
        roundNumberOffset = 0
    }

    // MARK: Tick

    private func tick() {
        guard isRecording, let start = startTime else { return }
        let now = Date()
        // Real time since the previous tick. Timers can be late or skipped (e.g.
        // phone locked), so the round clock follows wall time, while HR-based
        // accounting only credits up to 5 s per tick (no data = no credit).
        let dt = max(0, now.timeIntervalSince(lastTick ?? now))
        let creditedDT = min(dt, 5)
        lastTick = now
        // Paused: the clock, rounds, calories and heart rate all stand still.
        if isPaused { return }
        elapsedSeconds = now.timeIntervalSince(start) - pausedTotal

        let bpm = currentBPM
        let p = profile
        let coachCfg = p.audioCoach

        var cal = FighterAnalytics.calculateCalorieBreakdown(bpm: bpm, durationSeconds: creditedDT, profile: p)
        if usesMovementCalories {
            // Roadwork with GPS: burn from distance and climb, not heart rate.
            let dDist = max(0, run.distanceM - lastMoveDistance)
            let dClimb = max(0, run.elevationGainM - lastMoveClimb)
            lastMoveDistance = run.distanceM
            lastMoveClimb = run.elevationGainM
            let speed = run.currentPace > 0 ? run.unitMeters / run.currentPace * 60 : dDist / max(1, creditedDT) * 60
            cal.active = FighterAnalytics.movementActiveCalories(distanceM: dDist, climbM: dClimb,
                                                                 speedMetersPerMinute: speed, weightKg: p.weightKg)
        }
        activeCalories += cal.active
        bmrCalories += cal.bmr

        // Context for estimates: work or rest in rounds, speed on runs.
        let phaseResting: Bool? = roundTimerEnabled ? isRestPeriod : nil
        let speed: Double? = (run.isActive && run.currentPace > 0) ? run.unitMeters / run.currentPace : nil
        if bpm > 0 {
            // Back after a gap: a FIGHT Logger can send the real readings we missed.
            if let from = gapFrom, now.timeIntervalSince(from) > 3, ble?.isLogger == true {
                ble?.requestLoggerReadings(since: from)
            }
            gapFrom = nil
            lastRealAt = now
            estimatedBPM = nil
            hrEstimator.addReal(bpm: bpm, at: elapsedSeconds, resting: phaseResting, speed: speed)
        } else if let est = hrEstimator.estimate(at: elapsedSeconds, resting: phaseResting, speed: speed, maxHR: p.effectiveMaxHR) {
            // Strap off: estimate, but keep it apart from real data.
            estimatedBPM = est
            estimatedSamples.append(HeartRatePoint(timestamp: now, elapsedSeconds: elapsedSeconds, bpm: est, rrIntervalsMs: []))
            if !usesMovementCalories {
                estimatedCalories += FighterAnalytics.calculateCalorieBreakdown(bpm: est, durationSeconds: creditedDT, profile: p).active
            }
        } else {
            estimatedBPM = nil
        }
        if bpm == 0, gapFrom == nil, let last = lastRealAt { gapFrom = last }

        if bpm > 0 {
            let rr = ble?.consumeLatestRRIntervals() ?? []
            samples.append(HeartRatePoint(timestamp: now, elapsedSeconds: elapsedSeconds, bpm: bpm, rrIntervalsMs: rr))
            sumBPM += bpm
            maxBPMSeen = max(maxBPMSeen, bpm)
            let z = p.zone(for: bpm)
            zoneSeconds[z.number, default: 0] += creditedDT
            if roundTimerEnabled && !isRestPeriod {
                roundEndPeakBPM = max(roundEndPeakBPM, bpm)
            }
            evaluateAutomaticHRR(bpm: bpm, profile: p)
            evaluateTargetAlerts(bpm: bpm, coachCfg: coachCfg)
            evaluateEncouragement(bpm: bpm, profile: p)
            if elapsedSeconds - lastAlpha1Elapsed >= 10 && samples.count >= 60 {
                lastAlpha1Elapsed = elapsedSeconds
                // Smoothed so one noisy window doesn't flip the threshold readout.
                if let a = HRVMath.liveAlpha1(recentSamples: Array(samples.suffix(150))) {
                    liveAlpha1 = liveAlpha1.map { $0 * 0.6 + a * 0.4 } ?? a
                } else {
                    liveAlpha1 = nil
                }
            }
        }

        if roundTimerEnabled && !bagSessionComplete && !isInPlanTransition {
            advanceRoundClock(by: dt, bpm: bpm, coachCfg: coachCfg)
        }
        if isRunningPlan && !planComplete {
            advancePlan(by: dt)
        }
        guideBreathingIfNeeded()
        recordActivity()
        run.tick(dt: min(dt, 5), bpm: bpm, elapsed: elapsedSeconds)
        evaluateHeadCues()
        watchStrap(now: now)

        if selectedCategory == .lthrTest {
            if !lthrWarmupAnnounced && elapsedSeconds >= 600 {
                lthrWarmupAnnounced = true
                audio.playRoundStartBell()
                audio.announceCoachingCue("Warm up complete. Begin your 20 minute threshold effort now!", enabled: true)
            } else if elapsedSeconds >= 1800 {
                finishAndSave()
                return
            }
        }

        updateLiveActivity()
        if now.timeIntervalSince(lastDraftSave) >= 30 {
            saveDraft()
        }
    }

    private func advanceRoundClock(by dt: TimeInterval, bpm: Int, coachCfg: AudioCoachSettings) {
        let before = currentPhaseTarget - phaseElapsed
        phaseElapsed += dt
        let after = currentPhaseTarget - phaseElapsed
        let warningsOn = coachCfg.masterEnabled && profile.encouragement

        if !isRestPeriod {
            if before > 30 && after <= 30 && warningsOn && coachCfg.announceRoundWarnings && workDurationSeconds >= 90 {
                audio.announceCoachingCue("30 seconds", enabled: true)
            }
            if before > 10 && after <= 10 {
                if coachCfg.clapperWarnings { audio.playClapper() }
            }
        } else if before > 10 && after <= 10 {
            if coachCfg.clapperWarnings { audio.playClapper() }
            if warningsOn && coachCfg.announceRoundWarnings {
                audio.announceCoachingCue("Round \(currentRound + 1) in 10 seconds", enabled: true)
            }
        }

        var guardCount = 0
        while phaseElapsed >= currentPhaseTarget && guardCount < 20 && !bagSessionComplete {
            guardCount += 1
            phaseElapsed -= currentPhaseTarget
            if isRestPeriod {
                beginNextRound(bpm: bpm, coachCfg: coachCfg)
            } else {
                endWorkPhase(bpm: bpm)
            }
        }
    }

    /// Ends the current work phase (bell or "End Round" button).
    func endWorkPhase(bpm: Int? = nil, manual: Bool = false) {
        guard isRecording, !isRestPeriod else { return }
        let hr = bpm ?? currentBPM
        if manual { phaseElapsed = 0 }
        currentWorkEndElapsed = elapsedSeconds
        workEndCounts = (headMotion.totalMoves, headMotion.totalBounces, headMotion.chinUpSeconds, bagHits)
        headMotion.trackingChin = false
        audio.flushCombos()
        audio.playRoundEndBell()

        if let limit = roundsLimit, currentRound >= limit {
            recordRound(stoolDrop: nil)
            if isRunningPlan {
                finishCurrentBlock()
                return
            }
            bagSessionComplete = true
            audio.stopBagCoach()
            audio.announceCoachingCue("Session complete. Great work.", enabled: true)
            requestFinishPrompt = true
            return
        }

        isRestPeriod = true
        nextBreathCue = elapsedSeconds + 2.5
        breathInhaleNext = true
        let peak = max(roundEndPeakBPM, hr)
        if peak > 90 {
            pendingRecovery = PendingRecovery(startElapsed: elapsedSeconds, peakBPM: peak,
                                              contextLabel: "Round \(currentRound) Stool Rest", lowestSeenBPM: peak)
        }
        saveDraft()
    }

    private func beginNextRound(bpm: Int, coachCfg: AudioCoachSettings) {
        let drop: Int? = (roundEndPeakBPM > 0 && bpm > 0) ? max(0, roundEndPeakBPM - bpm) : nil
        recordRound(stoolDrop: drop)
        if let drop, checkRecoveryRecord(drop) {
            // Record announcement replaces the normal recovery cue.
        } else if let drop, coachCfg.masterEnabled && coachCfg.announceStoolRecovery && profile.encouragement {
            audio.announceCoachingCue("Recovered \(drop) beats.", enabled: true)
        }
        currentRound += 1
        isRestPeriod = false
        nextBreathCue = nil
        currentRoundStartElapsed = elapsedSeconds
        currentRoundStartStrikes = audio.strikesCuedCount
        currentRoundStartHeadMoves = headMotion.totalMoves
        roundStartBounces = headMotion.totalBounces
        roundStartChin = headMotion.chinUpSeconds
        roundStartImpacts = bagHits
        workEndCounts = nil
        headMotion.trackingChin = true
        moveWindowStart = nil
        moveCueGiven = false
        chinHighSince = nil
        chinCueGiven = false
        roundEndPeakBPM = 0
        audio.playRoundStartBell()
        if let limit = roundsLimit, currentRound == limit, limit > 1 {
            if isRunningPlan {
                audio.announceCoachingCue("Last round.", enabled: true)
            } else {
                announceFinalRound()
            }
        }
    }

    private func announceFinalRound() {
        guard !finalRoundAnnounced else { return }
        finalRoundAnnounced = true
        audio.announceCoachingCue("Final round! Empty the tank.", enabled: true)
    }

    private func recordRound(stoolDrop: Int?) {
        let workEnd = currentWorkEndElapsed > currentRoundStartElapsed ? currentWorkEndElapsed : elapsedSeconds
        let roundSamples = samples.filter { $0.elapsedSeconds >= currentRoundStartElapsed && $0.elapsedSeconds <= workEnd }
        let avg = roundSamples.isEmpty ? currentBPM : roundSamples.map(\.bpm).reduce(0, +) / roundSamples.count
        let peak = roundSamples.map(\.bpm).max() ?? roundEndPeakBPM
        completedRounds.append(RoundStat(
            roundNumber: roundNumberOffset + currentRound,
            startElapsed: currentRoundStartElapsed,
            endElapsed: workEnd,
            avgBPM: avg,
            peakBPM: peak,
            stoolDropBPM: stoolDrop,
            strikesCued: max(0, audio.strikesCuedCount - currentRoundStartStrikes),
            headMoves: headMotion.isReceiving ? max(0, (workEndCounts?.moves ?? headMotion.totalMoves) - currentRoundStartHeadMoves) : nil,
            chinUpSeconds: headMotion.isReceiving ? Int(max(0, (workEndCounts?.chin ?? headMotion.chinUpSeconds) - roundStartChin)) : nil,
            bounces: headMotion.isReceiving ? max(0, (workEndCounts?.bounces ?? headMotion.totalBounces) - roundStartBounces) : nil,
            impacts: audio.countBagHits ? max(0, (workEndCounts?.impacts ?? bagHits) - roundStartImpacts) : nil
        ))
        if currentRound == 1, let moves = completedRounds.last?.headMoves {
            let secs = max(60, workEnd - currentRoundStartElapsed)
            firstRoundMovesPerMinute = Double(moves) / secs * 60
        }
        if currentRound == 1, let hits = completedRounds.last?.impacts {
            let secs = max(60, workEnd - currentRoundStartElapsed)
            firstRoundHitsPerMinute = Double(hits) / secs * 60
        }
    }

    // MARK: AirPods cues, nod, strap watch, debrief

    /// "Move your head" when head movement falls to half of round 1; "Chin down" when the chin stays up.
    private func startRun(at date: Date) {
        run.start(at: date, imperial: profile.useImperial)
        run.onSplit = { [weak self] split in
            guard let self, self.profile.audioCoach.masterEnabled else { return }
            let unit = self.run.imperial ? "Mile" : "Kilometre"
            let secs = Int(split.seconds.rounded())
            var line = "\(unit) \(split.index). \(secs / 60) \(String(format: "%02d", secs % 60))."
            if let hr = split.avgBPM { line += " Heart rate \(hr)." }
            self.audio.announceCoachingCue(line, enabled: true)
        }
        run.onPauseChange = { [weak self] paused in
            guard let self, self.profile.audioCoach.masterEnabled else { return }
            self.audio.announceCoachingCue(paused ? "Paused." : "Resumed.", enabled: true)
        }
    }

    private func recordActivity() {
        guard headMotion.isReceiving || audio.countBagHits else { return }
        let total = headMotion.totalMoves + headMotion.totalBounces + bagHits
        activityTrail.append(ActivityPoint(t: elapsedSeconds, n: max(0, total - lastActivityTotal)))
        lastActivityTotal = total
    }

    /// A jump measured by AirPods. Counts only inside plyo jump sets.
    private func recordJump(_ cm: Double) {
        guard isRecording, isRunningPlan, !isInPlanTransition, !planComplete,
              let b = currentBlock, b.contacts > 0, b.kind == .timedDrill || b.kind == .intervals else { return }
        jumps.append(cm)
        setJumps.append(cm)
        // Quality stop: plyos are for max effort. Two jumps in a row more than 10% under
        // the set's best means the legs are fading, so end the set.
        guard b.kind == .timedDrill, !qualityStopGiven, setJumps.count >= 4, let best = setJumps.max() else { return }
        let lastTwo = setJumps.suffix(2)
        if lastTwo.allSatisfy({ $0 < best * 0.9 }) {
            qualityStopGiven = true
            audio.announceCoachingCue("Jumps are getting lower. Stop the set and rest.", enabled: true)
            finishCurrentBlock()
        }
    }

    func jumpText(_ cm: Double) -> String {
        profile.useImperial ? "\(Int((cm / 2.54).rounded())) inches" : "\(Int(cm.rounded())) centimetres"
    }

    /// Corner-coach mode: push when the pace drops, breathe when redlining.
    private func evaluateEncouragement(bpm: Int, profile p: AthleteProfile) {
        guard p.encouragement, p.audioCoach.masterEnabled else { return }
        var isWork = false
        var isRest = false
        var remaining: TimeInterval?
        var phase = phaseElapsed
        if roundTimerEnabled {
            isWork = !isRestPeriod
            isRest = isRestPeriod
            let length = Double(isRestPeriod ? restDurationSeconds : workDurationSeconds)
            remaining = length - phaseElapsed
        } else if isRunningPlan, !isInPlanTransition, !planComplete, let b = currentBlock {
            phase = planBlockElapsed
            remaining = Double(b.durationSeconds + blockExtraSeconds) - planBlockElapsed
            isRest = b.kind == .rest || b.untilRecovered
            isWork = !isRest && (b.kind == .timedDrill || b.kind == .intervals) && b.calls.isEmpty
        }
        // Your own pace: the block's target, or round 1 of this block (minus a little).
        var floor = activeTargetRange?.lowerBound
        if floor == nil, roundTimerEnabled, completedRounds.count > roundNumberOffset {
            floor = completedRounds[roundNumberOffset].avgBPM - 8
        }
        var hitRate: Double?
        if audio.countBagHits {
            hitTrail.append(HitPoint(t: elapsedSeconds, hits: bagHits))
            hitTrail.removeAll { elapsedSeconds - $0.t > 20 }
            if isWork, let first = hitTrail.first, elapsedSeconds - first.t >= 15 {
                hitRate = Double(bagHits - first.hits) / (elapsedSeconds - first.t) * 60
            }
        }
        let input = EncouragementCoach.Input(
            now: elapsedSeconds, bpm: bpm, isWork: isWork, isRest: isRest, phaseElapsed: phase,
            phaseRemaining: remaining, paceFloor: floor, redLine: p.activeZones.z4Max,
            hitRate: hitRate, hitRateRef: firstRoundHitsPerMinute)
        if let cue = encourager.evaluate(input) {
            audio.announceCoachingCue(cue.line, enabled: true)
        }
    }

    private func evaluateHeadCues() {
        guard roundTimerEnabled, !isRestPeriod, headMotion.isReceiving else { return }
        let p = profile
        // Learn the guard position a few seconds into round 1.
        if !chinBaselineSet, currentRound == 1, phaseElapsed >= 6 {
            headMotion.setChinBaseline()
            chinBaselineSet = true
        }
        guard p.headCues, p.audioCoach.masterEnabled else { return }

        if let ref = firstRoundMovesPerMinute, ref >= 6, !moveCueGiven, currentRound >= 2 {
            if let w = moveWindowStart {
                let span = elapsedSeconds - w.t
                if span >= 30 {
                    let rate = Double(headMotion.totalMoves - w.moves) / span * 60
                    if rate < ref * 0.5 {
                        moveCueGiven = true
                        audio.announceCoachingCue("Move your head.", enabled: true)
                    }
                    moveWindowStart = (elapsedSeconds, headMotion.totalMoves)
                }
            } else {
                moveWindowStart = (elapsedSeconds, headMotion.totalMoves)
            }
        }

        if chinBaselineSet, !chinCueGiven {
            if headMotion.chinLiftNow > HeadMotionTracker.chinLift {
                if let since = chinHighSince {
                    if elapsedSeconds - since >= 5 {
                        chinCueGiven = true
                        audio.announceCoachingCue("Chin down.", enabled: true)
                    }
                } else {
                    chinHighSince = elapsedSeconds
                }
            } else {
                chinHighSince = nil
            }
        }
    }

    /// Nod on the stool to start the next round early.
    private func handleNod() {
        guard isRecording, roundTimerEnabled, isRestPeriod, phaseRemaining > 3, !isInPlanTransition else { return }
        phaseElapsed = currentPhaseTarget
    }

    /// Puts zones back the way they were before the LTHR test.
    func undoLTHRTest() {
        guard let prev = previousThreshold, let store else { return }
        var p = store.activeProfile
        p.lactateThresholdHR = prev.lthr
        p.zoneMethod = prev.method
        store.activeProfile = p
        previousThreshold = nil
        lthrTestResultBanner = nil
    }

    /// Lets Shortcuts and the Live Activity skip the rest.
    func skipRest() {
        guard isRecording, roundTimerEnabled, isRestPeriod else { return }
        phaseElapsed = currentPhaseTarget
    }

    /// Stop the clock. Bag calls, cues, calories and heart-rate recording all wait.
    func pause(forCall: Bool = false) {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pausedForCall = forCall
        pausedAt = Date()
        run.holdDistance = true
        if !forCall { audio.announceCoachingCue("Paused.", enabled: true) }
        lastActivityState = nil
        updateLiveActivity()
        saveDraft()
    }

    /// Back to work: the clock carries on from where it stopped.
    func resume() {
        guard isRecording, isPaused else { return }
        let now = Date()
        if let at = pausedAt {
            completedPauseIntervals.append((start: at, end: now))
            pausedTotal += now.timeIntervalSince(at)
        }
        pausedAt = nil
        isPaused = false
        pausedForCall = false
        lastTick = now
        hrAlertTracker.reset()
        run.holdDistance = false
        audio.prepareForWorkout(settings: profile.audioCoach)
        audio.announceCoachingCue("Back to work.", enabled: true)
        if roundTimerEnabled && !isRestPeriod { audio.playRoundStartBell() }
        lastActivityState = nil
        updateLiveActivity()
    }

    /// Water, gum shield, retape: 30 more seconds on this rest.
    func extendRest(by seconds: TimeInterval = 30) {
        guard isRecording, roundTimerEnabled, isRestPeriod, !isInPlanTransition else { return }
        phaseElapsed = max(0, phaseElapsed - seconds)
    }

    /// Strap off for 2 minutes during a session: offer to finish.
    private func watchStrap(now: Date) {
        let connected = (ble?.isConnected ?? false) && currentBPM > 0
        if connected {
            strapLostSince = nil
        } else if hadSignal {
            if let since = strapLostSince {
                if now.timeIntervalSince(since) >= 120 && !requestFinishPrompt {
                    requestFinishPrompt = true
                    strapLostSince = now
                }
            } else {
                strapLostSince = now
            }
        }
    }

    private var hadSignal: Bool { !samples.isEmpty }

    private func speakDebrief(_ w: SavedWorkout, history: [SavedWorkout], profile p: AthleteProfile) {
        // "Alerts only" coach: no spoken debrief either.
        guard p.audioCoach.masterEnabled, p.encouragement, w.duration >= 300 else { return }
        debriefVoice.speak(SessionDebrief.text(for: w, history: history, profile: p),
                           volume: Float(p.audioCoach.voiceVolume))
    }

    // MARK: Signature features

    private func logCombo(_ combo: [Strike]) {
        guard isRecording else { return }
        let t = elapsedSeconds + (lastTick.map { Date().timeIntervalSince($0) } ?? 0)
        comboEvents.append(ComboEvent(t: t, strikes: combo))
    }

    /// Speaks a new personal record the moment it happens. Returns true if it did.
    private func checkRecoveryRecord(_ drop: Int) -> Bool {
        guard bestRecoveryRecord >= 15, drop > bestRecoveryRecord else { return false }
        bestRecoveryRecord = drop
        liveRecordBanner = "New record: recovered \(drop) BPM in 60 s"
        guard !recoveryRecordAnnounced else { return false }
        recoveryRecordAnnounced = true
        audio.announceCoachingCue("New recovery record! \(drop) beats.", enabled: profile.audioCoach.masterEnabled)
        return profile.audioCoach.masterEnabled
    }

    /// Paced breathing tones on the stool: in for 4, out for 6 (6 breaths a minute).
    private func guideBreathingIfNeeded() {
        guard profile.guidedBreathing, roundTimerEnabled, isRestPeriod, let next = nextBreathCue,
              elapsedSeconds >= next else { return }
        let remaining = currentPhaseTarget - phaseElapsed
        guard remaining > 7 else { nextBreathCue = nil; return }
        let seconds: Double = breathInhaleNext ? 4 : 6
        audio.playBreathCue(inhale: breathInhaleNext, seconds: seconds)
        breathingUsed = true
        breathInhaleNext.toggle()
        nextBreathCue = next + seconds
    }

    private var headMovesPerMinute: Double? {
        guard headMotion.isReceiving else { return nil }
        let rounds = completedRounds.filter { $0.headMoves != nil }
        let workSeconds = rounds.reduce(0.0) { $0 + ($1.endElapsed - $1.startElapsed) }
        if workSeconds >= 60 {
            return Double(rounds.compactMap(\.headMoves).reduce(0, +)) / workSeconds * 60
        }
        guard elapsedSeconds >= 60 else { return nil }
        return Double(headMotion.totalMoves) / elapsedSeconds * 60
    }

    // MARK: Live analysis

    private func evaluateAutomaticHRR(bpm: Int, profile: AthleteProfile) {
        let highEffort = Int(Double(profile.effectiveMaxHR) * 0.80)
        if var tracker = pendingRecovery {
            tracker.lowestSeenBPM = min(tracker.lowestSeenBPM, bpm)
            if !isRestPeriod && bpm > tracker.peakBPM + 3 {
                pendingRecovery = nil
                pendingRecoveryRemaining = nil
                return
            }
            pendingRecovery = tracker
            let since = elapsedSeconds - tracker.startElapsed
            pendingRecoveryRemaining = max(0, 60 - Int(since))
            if since >= 60 {
                let drop = max(0, tracker.peakBPM - bpm)
                if drop >= 8 {
                    autoHRREvents.append(AutoHRREvent(elapsedSeconds: elapsedSeconds, peakBPM: tracker.peakBPM,
                                                      recovery60BPM: bpm, dropBPM: drop, contextLabel: tracker.contextLabel))
                    latestAutoHRRBanner = "Auto HRR-60: −\(drop) BPM (\(tracker.peakBPM) → \(bpm))"
                    _ = checkRecoveryRecord(drop)
                }
                pendingRecovery = nil
                pendingRecoveryRemaining = nil
            }
        } else if !roundTimerEnabled && bpm >= highEffort && samples.count >= 12 {
            let recent10 = samples.suffix(10).map(\.bpm)
            if let localPeak = recent10.max(), localPeak >= highEffort && (localPeak - bpm) >= 5 {
                pendingRecovery = PendingRecovery(startElapsed: elapsedSeconds, peakBPM: localPeak,
                                                  contextLabel: "Mid-Session Recovery", lowestSeenBPM: bpm)
            }
        }
    }

    /// What this session's heart rate should sit in (plan step, coach's pick, or the session type).
    var hrTarget: HRTarget? {
        if let r = activeTargetRange {
            return HRTarget(low: r.lowerBound, high: r.upperBound, label: "Target · \(r.lowerBound)–\(r.upperBound)")
        }
        return HRTargetRules.target(drill: selectedDrillTag, category: selectedCategory,
                                    zones: profile.activeZones, maxHR: profile.effectiveMaxHR)
    }

    /// Whether "pick it up" alerts apply: easy runs, and steady plan steps.
    private var hrAlertsAllowLow: Bool {
        if isRunningPlan {
            guard let b = currentBlock else { return false }
            return b.kind == .steady || b.kind == .timedDrill
        }
        if activePlan != nil { return false }
        return selectedDrillTag == .aerobicZ2 && selectedCategory != .walk
    }

    /// Time to settle in before alerts: a warm-up on runs, the start of each round or plan step.
    private var hrAlertsSettled: Bool {
        if isRunningPlan { return elapsedSeconds - blockStartElapsed >= 45 }
        if roundTimerEnabled { return elapsedSeconds - currentRoundStartElapsed >= 45 && elapsedSeconds >= 45 }
        if selectedCategory.isRun || selectedCategory == .walk { return elapsedSeconds >= 180 }
        return elapsedSeconds >= 60
    }

    /// Voice only when you're out of range for what you're doing: "Slow down. Above target." or
    /// "Pick it up. Under target." Nothing when you're in range, and no running commentary.
    private func evaluateTargetAlerts(bpm: Int, coachCfg: AudioCoachSettings) {
        guard let target = hrTarget else {
            hrTargetPosition = 0
            return
        }
        let allowLow = hrAlertsAllowLow
        let resting = (roundTimerEnabled && isRestPeriod) || isInPlanTransition || planComplete || bagSessionComplete
        hrTargetPosition = resting ? 0 : HRAlertTracker.position(bpm: bpm, target: target, buffer: 4, allowLow: allowLow)
        guard coachCfg.masterEnabled, coachCfg.zone2CeilingAlert, !resting, hrAlertsSettled else {
            hrAlertTracker.reset()
            return
        }
        switch hrAlertTracker.update(bpm: bpm, target: target, at: elapsedSeconds, allowLow: allowLow) {
        case 1: audio.announceCoachingCue("Slow down. Above target.", enabled: true)
        case -1: audio.announceCoachingCue("Pick it up. Under target.", enabled: true)
        default: break
        }
    }

    // MARK: Live Activity (throttled)

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let p = profile
        let attributes = WorkoutActivityAttributes(athleteName: p.name, discipline: selectedCategory.rawValue)
        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: currentBPM, zoneNumber: 1, zoneShortName: "Z1", calories: 0,
            workoutStartDate: Date(), isTimedRound: roundTimerEnabled, roundNumber: 1, isRest: false,
            phaseEndDate: Date().addingTimeInterval(TimeInterval(workDurationSeconds))
        )
        currentActivity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: Date().addingTimeInterval(120)), pushType: nil)
        lastActivityPush = Date()
        lastActivityState = nil
    }

    /// Pushes only when something visible changes (zone, round, phase, ±3 BPM) or every 15 s.
    private func updateLiveActivity() {
        guard let activity = currentActivity else { return }
        let bpm = currentBPM
        let z = profile.zone(for: bpm)
        let key = (bpm: bpm, zone: z.number, round: currentRound * 100 + planBlockIndex + Int(run.distanceM / 100) * 10_000,
                   rest: isRestPeriod || isInPlanTransition)
        let now = Date()
        if let last = lastActivityState,
           last.zone == key.zone, last.round == key.round, last.rest == key.rest,
           abs(last.bpm - key.bpm) < 3, now.timeIntervalSince(lastActivityPush) < 15 {
            return
        }
        lastActivityState = key
        lastActivityPush = now
        let state = WorkoutActivityAttributes.ContentState(
            currentBPM: bpm, zoneNumber: z.number, zoneShortName: z.shortName, calories: Int(activeCalories),
            workoutStartDate: (startTime ?? now).addingTimeInterval(pausedTotal),
            isTimedRound: roundTimerEnabled || (isRunningPlan && !isInPlanTransition && !(currentBlock?.kind.isRoundBased ?? true)),
            roundNumber: isRunningPlan ? planBlockIndex + 1 : currentRound,
            isRest: isRestPeriod || isInPlanTransition,
            phaseEndDate: now.addingTimeInterval(isInPlanTransition ? (planTransitionRemaining ?? 0) : (roundTimerEnabled ? phaseRemaining : blockRemaining)),
            distanceText: run.isActive ? "\(RouteMath.distanceText(run.distanceM, imperial: run.imperial)) \(run.imperial ? "mi" : "km")" : nil,
            paceText: run.isActive ? "\(RouteMath.paceText(run.currentPace)) /\(run.imperial ? "mi" : "km")" : nil,
            isPaused: isPaused
        )
        // Updates come at least every 15 s; if the app stops, the Lock Screen shows it as stale.
        Task { await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(120))) }
    }

    /// Clears Lock Screen activities left over from a session that ended with a crash.
    static func endLeftoverActivities() {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func endLiveActivity() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Draft persistence

    private func makeDraft(now: Date) -> WorkoutDraft {
        WorkoutDraft(
            id: draftID, profileID: store?.activeProfileID ?? UUID(), startTime: startTime ?? now, lastUpdate: now,
            elapsedSeconds: elapsedSeconds, category: selectedCategory, drillTag: selectedDrillTag, notes: workoutNotes,
            samples: samples, zoneSeconds: zoneSeconds, activeCalories: activeCalories, bmrCalories: bmrCalories,
            rounds: completedRounds, autoHRREvents: autoHRREvents, strikesCued: audio.strikesCuedCount,
            ghostTitle: selectedGhost?.title, planTitle: activePlan?.title,
            planTargetLow: activePlan?.targetLowBPM, planTargetHigh: activePlan?.targetHighBPM,
            trainingPlanID: runningPlan?.id, trainingPlanTitle: runningPlan?.title,
            blockResults: blockResults,
            comboEvents: comboEvents,
            headMovesPerMinute: headMovesPerMinute,
            breathingGuided: breathingUsed,
            impactsCount: audio.countBagHits ? bagHits : nil,
            jumps: jumps.isEmpty ? nil : jumps,
            activity: activityTrail.isEmpty ? nil : activityTrail,
            run: run.snapshot?.summary,
            route: run.snapshot?.route,
            activityName: activityName,
            estimatedSamples: estimatedSamples.isEmpty ? nil : estimatedSamples,
            estimatedCalories: estimatedCalories > 0 ? estimatedCalories : nil,
            recoveredSeconds: recoveredSeconds > 0 ? recoveredSeconds : nil
        )
    }


    @ObservationIgnored private var cachedDraftsDirectory: URL?
    private var draftsDirectory: URL? {
        if let d = cachedDraftsDirectory { return d }
        guard let store else { return nil }
        let dir = store.documentsDirectory.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cachedDraftsDirectory = dir
        return dir
    }
    private var draftURL: URL? { draftsDirectory?.appendingPathComponent("active_workout.json") }
    /// Heart-rate samples of the running session, one JSON line each, appended every 30 s.
    private var draftSamplesURL: URL? { draftsDirectory?.appendingPathComponent("active_workout_samples.jsonl") }
    @ObservationIgnored private var draftSamplesWritten = 0
    /// Draft writes happen off the main thread, in order.
    private let draftQueue = DispatchQueue(label: "fight.draft", qos: .utility)

    /// Crash-safety save: a small header plus only the samples added since the last save,
    /// encoded and written in the background so long sessions never stutter.
    func saveDraftNow() {
        guard isRecording else { return }
        saveDraft()
    }

    private func saveDraft() {
        guard isRecording, let url = draftURL, let samplesURL = draftSamplesURL else { return }
        lastDraftSave = Date()
        var header = makeDraft(now: Date())
        header.samples = []
        let fresh = Array(samples[min(draftSamplesWritten, samples.count)...])
        let truncate = draftSamplesWritten == 0
        draftSamplesWritten = samples.count
        draftQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var lines = Data()
            for point in fresh {
                if let line = try? encoder.encode(point) {
                    lines.append(line)
                    lines.append(0x0A)
                }
            }
            if truncate || !FileManager.default.fileExists(atPath: samplesURL.path) {
                try? lines.write(to: samplesURL, options: .atomic)
            } else if !lines.isEmpty, let handle = try? FileHandle(forWritingTo: samplesURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lines)
                try? handle.close()
            }
            if let data = try? encoder.encode(header) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadDraft() -> WorkoutDraft? {
        guard let url = draftURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var draft = try? decoder.decode(WorkoutDraft.self, from: data), draft.elapsedSeconds >= 60 else {
            deleteDraft()
            return nil
        }
        // Older drafts kept the samples inside the header; newer ones append them to a side file.
        if draft.samples.isEmpty, let samplesURL = draftSamplesURL, let raw = try? Data(contentsOf: samplesURL) {
            draft.samples = raw.split(separator: 0x0A).compactMap { try? decoder.decode(HeartRatePoint.self, from: Data($0)) }
        }
        return draft
    }

    private func deleteDraft() {
        draftSamplesWritten = 0
        let urls = [draftURL, draftSamplesURL].compactMap { $0 }
        draftQueue.async {
            for u in urls { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// Saves or discards a workout recovered after the app was closed mid-session.
    /// Hides the recovery question without losing anything; it's asked again next launch.
    func postponeRecoveredDraft() {
        recoverableDraft = nil
    }

    func resolveRecoveredDraft(save: Bool) {
        guard let draft = recoverableDraft, let store else { return }
        recoverableDraft = nil
        let owner = store.profiles.first { $0.id == draft.profileID } ?? store.activeProfile
        let saved = WorkoutFinalizer.makeWorkout(from: draft, profile: owner, ghost: nil, end: draft.lastUpdate)
        if let route = draft.route { store.saveRoute(RouteMath.simplify(route), for: saved.id) }
        guard save else {
            // "Discard" still keeps it in Recently Deleted for 30 days.
            store.saveToTrash(saved)
            deleteDraft()
            return
        }
        guard store.save(saved) else {
            saveError = Self.saveErrorText
            return   // the draft stays, so it's offered again
        }
        deleteDraft()
        finishedWorkout = saved
        showingSummary = true
    }
}
