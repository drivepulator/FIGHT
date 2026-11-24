import SwiftUI
import Charts
import UserNotifications

// MARK: - Insight bundle for the Coach tab

/// Everything the signature features compute, built once per refresh.
struct CoachInsights {
    var gasTank: GasTankResult?
    var comboCost: ComboCostResult?
    var drivers: [DriverInsight] = []
    var sorenessPatterns: [DriverInsight] = []
    var activeSoreness: [SorenessEntry] = []
    var benchmarkAttempts: [Benchmark.Attempt] = []
    var benchmarkDue = false
    var breathing: (with: Double, without: Double, sessions: Int)?
    var redline: DefensiveRedline?
    var sparring: [DriverInsight] = []
    var neglected: (tag: String, days: Int)?
    var drills: [DrillResult] = []

    @MainActor
    static func build(store: WorkoutStore) -> CoachInsights {
        build(profile: store.activeProfile, workouts: store.workouts, readings: store.activeReadings,
              soreness: store.soreness, resolveSamples: { store.resolvedSamples(for: $0) })
    }

    /// Pure version (safe off the main thread).
    static func build(profile: AthleteProfile, workouts: [SavedWorkout], readings: [ReadinessReading],
                      soreness: [SorenessEntry], resolveSamples: (SavedWorkout) -> [HeartRatePoint]) -> CoachInsights {
        let mine = workouts.filter { $0.profileID == profile.id }
        var i = CoachInsights()
        i.gasTank = GasTank.evaluate(workouts: mine, profile: profile)
        i.comboCost = ComboCost.analyze(workouts: Array(mine.prefix(40)), stance: profile.bagPreferences.stance,
                                        resolveSamples: resolveSamples)
        i.drivers = PerformanceDrivers.analyze(workouts: workouts, readings: readings, profile: profile)
        i.sorenessPatterns = SorenessInsights.patterns(soreness, workouts: mine, profileID: profile.id)
        i.activeSoreness = SorenessInsights.active(soreness, profileID: profile.id)
        i.benchmarkAttempts = Benchmark.attempts(mine)
        i.benchmarkDue = Benchmark.isDue(mine)
        i.breathing = BreathingEffect.compare(mine, profileID: profile.id)
        i.redline = DefensiveRedline.evaluate(workouts: mine, profileID: profile.id)
        i.sparring = SparringInsights.analyze(mine, profileID: profile.id)
        i.neglected = SparringInsights.neglected(mine, profileID: profile.id)
        i.drills = DrillHistory.load(profile.id)
        return i
    }

    /// Short lines for Today's "one insight a day".
    var dailyCandidates: [String] {
        var c: [String] = []
        if let r = redline { c.append("\(r.headline). Conditioning keeps your defence alive.") }
        if let g = gasTank, g.intenseEnough { c.append("Gas tank: \(g.headline).") }
        if let h = comboCost?.headline { c.append(h + ".") }
        c.append(contentsOf: drivers.prefix(2).map(\.detail))
        c.append(contentsOf: sparring.prefix(1).map(\.detail))
        if let n = neglected { c.append("You haven't drilled \(n.tag.lowercased()) in \(n.days) days.") }
        if let best = drills.map(\.averageMs).min() { c.append("Your fastest defensive reaction: \(best) ms. Try to beat it.") }
        return c
    }

    /// Tips that should jump the queue (an injury risk beats everything).
    var priorityTips: [CoachRecommendation] {
        SorenessInsights.recommendation(for: activeSoreness).map { [$0] } ?? []
    }

    /// Lower-priority tips, appended after the coach's own notes.
    var extraTips: [CoachRecommendation] {
        var tips: [CoachRecommendation] = []
        if let d = drivers.first {
            tips.append(CoachRecommendation(kind: .focus, title: d.title, detail: d.detail))
        }
        if let n = neglected {
            tips.append(CoachRecommendation(kind: .focus, title: "Time to drill \(n.tag.lowercased())",
                                            detail: "You haven't worked on \(n.tag.lowercased()) in \(n.days) days. Tag it after your next session."))
        }
        if benchmarkDue {
            let detail = benchmarkAttempts.isEmpty
                ? "Run the FIGHT Benchmark once to set your baseline. Repeat it every 4 weeks to see real progress."
                : "It's been 4+ weeks since your last benchmark. Run it again to measure your progress."
            tips.append(CoachRecommendation(kind: .test, title: "Benchmark due", detail: detail))
        }
        return tips
    }
}

// MARK: - Gas Tank

struct GasTankLine: View {
    let result: GasTankResult

    var body: some View {
        Label {
            Text(result.headline)
                .font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: "fuelpump.fill")
                .foregroundStyle(result.formats.contains(where: \.isReady) ? .green : .orange)
        }
        .accessibilityLabel("Gas tank: \(result.headline)")
    }
}

struct GasTankCard: View {
    let result: GasTankResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Gas Tank", systemImage: "fuelpump.fill")
                .font(.title3.weight(.bold))
            Text("How many fight-pace rounds you can hold before your heart rate redlines (\(result.redlineBPM)+ BPM) or your recovery runs out.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(result.formats) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(f.format.label) min").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(f.isReady ? "Ready" : "Limit: round \(f.limitRound ?? f.format.rounds)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(f.isReady ? .green : .orange)
                    }
                    ProgressView(value: Double(f.percent), total: 100)
                        .tint(f.isReady ? .green : .orange)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Your heart rate climbs about \(Int(result.creepPerRound.rounded())) BPM per round, starting near \(result.firstRoundBPM). Based on \(result.sessionsUsed) round sessions from the last 6 weeks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - Combo cost

struct ComboCostCard: View {
    let result: ComboCostResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Combo Cost", systemImage: "bolt.heart.fill")
                .font(.title3.weight(.bold))
            if let h = result.headline {
                Text(h).font(.subheadline.weight(.semibold))
            }
            Chart(result.byType) { e in
                BarMark(x: .value("BPM rise", e.averageRise), y: .value("Type", e.label))
                    .foregroundStyle(.orange.gradient)
                    .annotation(position: .trailing) {
                        Text("+\(Int(e.averageRise.rounded()))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(1, result.byType.count)) * 34)
            if !result.mostExpensive.isEmpty {
                Text("Most expensive combos").font(.subheadline.weight(.semibold))
                ForEach(result.mostExpensive) { e in
                    HStack {
                        Text(e.label).font(.footnote.monospaced())
                        Spacer()
                        Text("+\(Int(e.averageRise.rounded())) BPM").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Average heart-rate rise in the 12 s after the bag coach calls a combo. \(result.combosAnalysed) combos analysed. Expensive weapons are worth conditioning, or saving for when they count.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - Drivers

struct DriversCard: View {
    let title: String
    let insights: [DriverInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            ForEach(insights) { d in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: d.icon)
                        .foregroundStyle(.pink)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.title).font(.subheadline.weight(.semibold))
                        Text(d.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

// MARK: - Benchmark

struct BenchmarkCard: View {
    let attempts: [Benchmark.Attempt]
    var onShare: (() -> Void)? = nil
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("FIGHT Benchmark", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.title3.weight(.bold))
                Spacer()
                if attempts.count >= 2, let onShare {
                    Button(action: onShare) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share your progress")
                }
            }
            if attempts.isEmpty {
                Text("A fixed 5 × 3 min test. Same work every time, so a lower heart rate and faster recovery prove you're fitter. Run it every 4 weeks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if let s = Benchmark.progressSummary(attempts) {
                    Text(s).font(.subheadline.weight(.semibold))
                }
                Chart(attempts) { a in
                    LineMark(x: .value("Date", a.date), y: .value("Avg HR", a.averageWorkHR))
                        .foregroundStyle(.red)
                        .symbol(.circle)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 120)
                Text("Average heart rate across the 5 rounds, test by test. Lower is better.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: onRun) {
                Label(attempts.isEmpty ? "Run Your First Benchmark" : "Run Benchmark", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .card()
    }
}

// MARK: - Breathing trainer

struct BreathingTrainerView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(WorkoutSession.self) var session
    @Environment(\.dismiss) private var dismiss

    @State private var minutes = 5
    @State private var startedAt: Date?
    @State private var rr: [Double] = []
    @State private var coherence: Int?
    @State private var startHR: Int?
    @State private var timer: Timer?

    private let inhale = 4.0
    private let exhale = 6.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let startedAt {
                        TimelineView(.animation) { ctx in
                            breathingCircle(now: ctx.date, start: startedAt)
                        }
                        stats
                        Button("Finish", role: .cancel) { stop() }
                            .buttonStyle(.bordered)
                    } else {
                        intro
                    }
                }
                .padding()
            }
            .navigationTitle("Breathing Trainer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { stop(); dismiss() }
                }
            }
            .onDisappear { stop() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "wind")
                .font(.largeTitle)
                .foregroundStyle(.teal)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text("Recover faster between rounds")
                .font(.title2.weight(.bold))
            Text("Breathe in for 4, out for 6. Slow breathing at about 6 breaths a minute brings your heart rate down faster. Practise here, then use it on the stool.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Length", selection: $minutes) {
                Text("3 min").tag(3)
                Text("5 min").tag(5)
                Text("10 min").tag(10)
            }
            .pickerStyle(.segmented)
            Button {
                start()
            } label: {
                Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.teal)
            Toggle("Breathing tones between rounds", isOn: Binding(
                get: { workoutStore.activeProfile.guidedBreathing },
                set: { var p = workoutStore.activeProfile; p.guidedBreathing = $0; workoutStore.activeProfile = p }
            ))
            .font(.subheadline)
            if let b = BreathingEffect.compare(workoutStore.workouts, profileID: workoutStore.activeProfileID) {
                let diff = Int((b.with - b.without).rounded())
                Text(diff >= 0
                     ? "With breathing tones you recover \(diff) BPM more between rounds (\(b.sessions) sessions)."
                     : "So far you recover \(-diff) BPM less with breathing tones. Give it a few more sessions.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.teal)
            } else {
                Text("Your coach will compare your recovery with and without the tones once you've used them a few times.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func breathingCircle(now: Date, start: Date) -> some View {
        let t = now.timeIntervalSince(start).truncatingRemainder(dividingBy: inhale + exhale)
        let breathingIn = t < inhale
        let scale = breathingIn ? 0.55 + 0.45 * (t / inhale) : 1.0 - 0.45 * ((t - inhale) / exhale)
        let remaining = max(0, Double(minutes * 60) - now.timeIntervalSince(start))
        return VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.teal.opacity(0.15))
                Circle().fill(Color.teal.gradient).scaleEffect(scale)
                Text(breathingIn ? "Breathe in" : "Breathe out")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 240, height: 240)
            Text(String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(breathingIn ? "Breathe in" : "Breathe out")
    }

    private var stats: some View {
        HStack(spacing: 28) {
            VStack(spacing: 2) {
                Text("Heart Rate").font(.caption).foregroundStyle(.secondary)
                Text(bleManager.currentBPM > 0 ? "\(bleManager.currentBPM)" : "--").font(.title.weight(.bold)).monospacedDigit()
                if let s = startHR, bleManager.currentBPM > 0 {
                    Text(String(format: "%+d since start", bleManager.currentBPM - s)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 2) {
                Text("Coherence").font(.caption).foregroundStyle(.secondary)
                Text(coherence.map { "\($0)" } ?? "--").font(.title.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.teal)
                Text(bleManager.isConnected ? "higher = in sync" : "connect a strap").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func start() {
        if !session.isRecording { _ = bleManager.consumeLatestRRIntervals() }
        rr = []
        coherence = nil
        startHR = bleManager.currentBPM > 0 ? bleManager.currentBPM : nil
        startedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let startedAt else { return }
        if startHR == nil, bleManager.currentBPM > 0 { startHR = bleManager.currentBPM }
        if !session.isRecording {
            rr.append(contentsOf: bleManager.consumeLatestRRIntervals())
            if rr.count > 90 { rr.removeFirst(rr.count - 90) }
            coherence = BreathingEffect.coherence(rrMs: rr)
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let phase = elapsed.truncatingRemainder(dividingBy: inhale + exhale)
        if phase < 1 || (phase >= inhale && phase < inhale + 1) {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        if elapsed >= Double(minutes * 60) { stop() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

// MARK: - Soreness

struct SorenessRegionPicker: View {
    @Binding var selection: Set<BodyRegion>

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(BodyRegion.allCases) { region in
                let on = selection.contains(region)
                Button {
                    if on { selection.remove(region) } else { selection.insert(region) }
                } label: {
                    Text(region.rawValue)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(on ? Color.red.opacity(0.2) : Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(on ? .red : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct SorenessLogSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var undo: UndoCenter
    @Environment(\.dismiss) private var dismiss
    @State private var regions: Set<BodyRegion> = []
    @State private var severity = 2

    var body: some View {
        NavigationStack {
            Form {
                Section("Where does it hurt?") {
                    SorenessRegionPicker(selection: $regions)
                        .padding(.vertical, 4)
                    Picker("How bad?", selection: $severity) {
                        Text("Niggle").tag(1)
                        Text("Sore").tag(2)
                        Text("Painful").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
                let mine = workoutStore.soreness.filter { $0.profileID == workoutStore.activeProfileID }.prefix(20)
                if !mine.isEmpty {
                    Section("Recent") {
                        ForEach(Array(mine)) { e in
                            HStack {
                                Text(e.region.rawValue)
                                Spacer()
                                Text(["", "Niggle", "Sore", "Painful"][min(3, max(1, e.severity))])
                                    .foregroundStyle(.secondary)
                                Text(e.date, format: .dateTime.day().month())
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    workoutStore.deleteSoreness(e)
                                    undo.show("\(e.region.rawValue) entry deleted") { workoutStore.addSoreness([e]) }
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("Your coach adjusts today's advice around sore spots and looks for patterns, like shin soreness after back-to-back kicking days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .undoHost()
            .navigationTitle("Soreness Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        workoutStore.addSoreness(regions.map {
                            SorenessEntry(profileID: workoutStore.activeProfileID, region: $0, severity: severity)
                        })
                        dismiss()
                    }
                    .disabled(regions.isEmpty)
                }
            }
        }
    }
}

// MARK: - Records & badges

struct RecordsView: View {
    @EnvironmentObject var workoutStore: WorkoutStore

    var body: some View {
        let profile = workoutStore.activeProfile
        let records = Records.all(workouts: workoutStore.workouts, profile: profile)
        let badges = Badges.all(workouts: workoutStore.workouts, readings: workoutStore.activeReadings, profile: profile)
        List {
            Section("Personal Records") {
                if records.isEmpty {
                    Text("Train with the round timer to start setting records.")
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { r in
                    HStack(spacing: 12) {
                        Image(systemName: r.icon).foregroundStyle(.orange).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.subheadline.weight(.semibold))
                            Text(r.date, format: .dateTime.day().month().year())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(r.valueText).font(.subheadline.weight(.bold)).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section("Badges") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                    ForEach(badges) { b in
                        VStack(spacing: 6) {
                            Image(systemName: b.icon)
                                .font(.title2)
                                .foregroundStyle(b.earned ? Color.orange : Color.secondary)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(b.earned ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill)))
                            Text(b.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                            if b.earned {
                                Text("Earned").font(.caption2).foregroundStyle(.green)
                            } else {
                                ProgressView(value: b.progress).tint(.orange)
                            }
                        }
                        .opacity(b.earned ? 1 : 0.75)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(b.title), \(b.detail), \(b.earned ? "earned" : "\(Int(b.progress * 100)) percent")")
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Records & Badges")
    }
}

/// Shown at the top of a workout when it set new personal records.
struct NewRecordsBanner: View {
    let records: [PersonalRecord]
    var onShare: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(records.count == 1 ? "New personal record!" : "\(records.count) new personal records!", systemImage: "trophy.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                if let onShare {
                    Button(action: onShare) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }
            }
            ForEach(records) { r in
                Text("\(r.title): \(r.valueText)").font(.subheadline)
            }
        }
        .card(tint: .orange)
    }
}

// MARK: - Fight-night warm-up

struct FightNightWarmUpSheet: View {
    @EnvironmentObject var navigation: AppNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var walkout = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var reminderSet = false
    @State private var reminderError = false

    private let plan = PlanTemplates.fightNightWarmUp

    var body: some View {
        let start = walkout.addingTimeInterval(-Double(plan.plannedSeconds))
        NavigationStack {
            Form {
                Section {
                    DatePicker("Walkout time", selection: $walkout, displayedComponents: [.date, .hourAndMinute])
                    LabeledContent("Start warming up", value: start.formatted(date: .omitted, time: .shortened))
                } footer: {
                    Text("A \(plan.plannedSeconds / 60)-minute warm-up that ends as you walk out: warm, sweating, heart rate settled.")
                }
                Section("The warm-up") {
                    ForEach(plan.blocks) { b in
                        HStack {
                            Image(systemName: b.kind.icon).foregroundStyle(.red).frame(width: 24)
                            Text(b.title)
                            Spacer()
                            Text(b.summary).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await remind(at: start) }
                    } label: {
                        Label(reminderSet ? "Reminder set" : "Remind me when to start", systemImage: reminderSet ? "checkmark" : "bell")
                    }
                    .disabled(reminderSet || start < Date())
                    Button {
                        navigation.run(plan)
                        dismiss()
                    } label: {
                        Label("Load in Live", systemImage: "play.fill")
                    }
                } footer: {
                    if reminderError { Text("Notifications are off for FIGHT. Turn them on in Settings.") }
                }
            }
            .navigationTitle("Fight-Night Warm-Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func remind(at date: Date) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { reminderError = true; return }
        let content = UNMutableNotificationContent()
        content.title = "Time to warm up"
        content.body = "Start your fight-night warm-up now to walk out ready."
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: "fight.walkout.warmup", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        do {
            try await center.add(request)
            reminderSet = true
        } catch {
            reminderError = true
        }
    }
}

// MARK: - Camp vs camp

struct CampCompareCard: View {
    let comparison: CampComparison

    private struct Point: Identifiable {
        let id = UUID()
        let week: Int
        let value: Double
        let series: String
    }

    var body: some View {
        let loads = comparison.weeks.flatMap { w -> [Point] in
            var pts = [Point(week: w.index, value: w.previousLoad, series: "Last camp")]
            if let c = w.currentLoad { pts.append(Point(week: w.index, value: c, series: "This camp")) }
            return pts
        }
        VStack(alignment: .leading, spacing: 12) {
            Label("This Camp vs Last Camp", systemImage: "square.on.square")
                .font(.title3.weight(.bold))
            Text(comparison.summary).font(.subheadline.weight(.semibold))
            Chart(loads) { p in
                LineMark(x: .value("Week", p.week), y: .value("Load", p.value))
                    .foregroundStyle(by: .value("Camp", p.series))
                    .symbol(by: .value("Camp", p.series))
            }
            .chartForegroundStyleScale(["Last camp": Color.gray, "This camp": Color.red])
            .frame(height: 150)
            Text("Weekly training load, lined up by weeks to fight. Last fight: \(comparison.previousFight.formatted(date: .abbreviated, time: .omitted)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}


/// Defence: the heart rate where head movement collapses, and reaction-drill progress.
struct DefenceCard: View {
    let redline: DefensiveRedline?
    let drills: [DrillResult]
    @State private var showingDrill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Defence", systemImage: "airpodspro")
                .font(.title3.weight(.bold))
            if let r = redline {
                Text(r.headline).font(.subheadline.weight(.semibold))
                Text(String(format: "Fresh you moves your head %.0f times a minute; above %d BPM it's %.0f. That's when you get hit. Conditioning and staying relaxed push this number up.",
                            r.freshPerMinute, r.redlineBPM, r.tiredPerMinute))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Wear AirPods during rounds and FIGHT finds the heart rate where your head movement drops off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reaction drill").font(.subheadline.weight(.semibold))
                    if let last = drills.last, let best = drills.map(\.averageMs).min() {
                        Text("Last \(last.averageMs) ms · best \(best) ms").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("How fast do you slip a punch?").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Start") { showingDrill = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
            }
        }
        .card()
        .sheet(isPresented: $showingDrill) { ReactionDrillView() }
    }
}
