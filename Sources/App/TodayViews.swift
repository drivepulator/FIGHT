import SwiftUI

/// The top of the Today tab: what to do today, one insight, your goal, and today's review.
struct TodayCard: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(WorkoutSession.self) var session
    @EnvironmentObject var navigation: AppNavigation

    @State private var showingCheck = false
    @State private var preparingVoice = false

    /// Shared report, computed once in the background by the store.
    private var report: CoachReport? {
        workoutStore.coachProfileID == workoutStore.activeProfileID ? workoutStore.coachReport : nil
    }
    private var insight: String? {
        report == nil ? nil : DailyInsight.pick(workoutStore.coachInsights.dailyCandidates)
    }

    var body: some View {
        let profile = workoutStore.activeProfile
        VStack(alignment: .leading, spacing: 12) {
            if let p = report?.nextWorkout {
                verdict(p)
            }
            if !checkedToday {
                Button {
                    showingCheck = true
                } label: {
                    Label("Take your 2-minute morning check", systemImage: "heart.text.square")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.pink)
            }
            if let insight {
                Label {
                    Text(insight).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                }
            }
            if let goal = goalLine(profile) {
                Label(goal, systemImage: profile.goal.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .sheet(isPresented: $showingCheck, onDismiss: refresh) { ReadinessCheckView() }
        .onAppear {
            refresh()
            consumeCheckRequest()
        }
        .onChange(of: navigation.requestReadinessCheck) { _, _ in consumeCheckRequest() }
        .onChange(of: workoutStore.workouts.count) { _, _ in
            refresh()
            WeeklyNudge.reschedule(store: workoutStore)
        }
        .onChange(of: workoutStore.activeProfileID) { _, _ in refresh() }
    }

    private func verdict(_ p: WorkoutPrescription) -> some View {
        let v = Self.verdict(p, profile: workoutStore.activeProfile)
        return VStack(alignment: .leading, spacing: 8) {
            Label(v.text, systemImage: v.icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(v.color)
            Text(p.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(p.structure) · about \(p.durationMinutes) min")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !p.isRestDay {
                Button {
                    start(p)
                } label: {
                    if preparingVoice {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("Preparing the coach's voice…")
                        }
                    } else {
                        Label("Start this", systemImage: "play.fill")
                    }
                }
                .buttonStyle(FightPrimaryButtonStyle())
                .disabled(preparingVoice)
                .padding(.top, 4)
            }
        }
    }

    /// One tap from the coach's call to the bell.
    private func start(_ p: WorkoutPrescription) {
        if p.plyo != nil {
            navigation.load(p)
            return
        }
        session.apply(p)
        guard session.bagEnabled else {
            session.startWorkout()
            return
        }
        preparingVoice = true
        Task {
            await session.audio.prepareVocabulary(prefs: session.bagPrefs)
            preparingVoice = false
            session.startWorkout()
        }
    }

    private func consumeCheckRequest() {
        guard navigation.requestReadinessCheck else { return }
        navigation.requestReadinessCheck = false
        showingCheck = true
    }

    static func verdict(_ p: WorkoutPrescription, profile: AthleteProfile) -> (text: String, color: Color, icon: String) {
        if p.isRestDay { return ("Today: rest and recover", .cyan, "bed.double.fill") }
        if p.targetHighBPM > profile.activeZones.z3Max { return ("Today: train hard", Theme.red, "flame.fill") }
        return ("Today: go easy", .green, "leaf.fill")
    }

    private var checkedToday: Bool {
        workoutStore.activeReadings.contains { Calendar.current.isDateInToday($0.date) && $0.source == nil }
    }

    private var todaysSession: SavedWorkout? {
        workoutStore.workouts.first { $0.profileID == workoutStore.activeProfileID && Calendar.current.isDateInToday($0.startDate) }
    }

    private func goalLine(_ p: AthleteProfile) -> String? {
        let lastWeight = workoutStore.weighIns.first { $0.profileID == p.id }?.weightKg ?? p.weightKg
        let toCut = lastWeight - p.targetFightWeightKg
        switch p.goal {
        case .fight:
            // The fight countdown card shows the days; only the cut goes here.
            guard p.fightDate != nil, toCut > 0.2 else { return nil }
            return "\(WeightUnits.text(toCut, p.useImperial)) to cut"
        case .weight:
            return toCut > 0.2 ? "\(WeightUnits.text(toCut, p.useImperial)) to your target weight" : "On target weight. Hold it."
        case .fitter:
            guard let f = report?.fightFitness, report?.hasEnoughData == true else { return nil }
            return "Fight Fitness \(f)/100"
        }
    }

    private func refresh() {
        workoutStore.refreshCoach()
    }
}

/// "Looks like you're training" when the strap shows a working heart rate but nothing is recording.
struct AutoStartBanner: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(WorkoutSession.self) var session
    @State private var highSince: Date?
    @State private var visible = false
    @State private var dismissedAt: Date?

    var body: some View {
        Group {
            if visible && !session.isRecording {
                HStack(spacing: 12) {
                    Image(systemName: "figure.kickboxing").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Training already?").font(.headline)
                        Text("Your heart rate says so. Start recording.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start") {
                        visible = false
                        session.startWorkout()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Button {
                        visible = false
                        dismissedAt = Date()
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not now")
                }
                .card(tint: .orange)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: bleManager.currentBPM) { _, bpm in evaluate(bpm) }
    }

    private func evaluate(_ bpm: Int) {
        guard !session.isRecording, bleManager.isConnected else { highSince = nil; return }
        if let d = dismissedAt, Date().timeIntervalSince(d) < 20 * 60 { return }
        if bpm >= workoutStore.activeProfile.restingHR + 40 {
            if let since = highSince {
                if Date().timeIntervalSince(since) >= 20 && !visible {
                    withAnimation { visible = true }
                }
            } else {
                highSince = Date()
            }
        } else {
            highSince = nil
        }
    }
}

/// Tags after a session: what you worked on, and for sparring, your partner and how each round went.
struct SessionTagsCard: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    let workoutID: UUID

    @State private var focus: Set<String> = []
    @State private var partner = ""
    @State private var results: [String] = []
    @State private var loaded = false

    private var workout: SavedWorkout? { workoutStore.workouts.first { $0.id == workoutID } }

    /// Only the techniques that fit this workout (none for runs, conditioning or tests).
    private var options: [String] {
        guard let w = workout else { return [] }
        return w.category.focusOptions(disciplines: workoutStore.profile(for: w).trainedDisciplines)
    }

    var body: some View {
        if let w = workout, !options.isEmpty || Self.isSparring(w) {
            content(w)
        }
    }

    private func content(_ w: SavedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !options.isEmpty {
                Text("What did you work on?").font(.headline)
            }
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.self) { tag in
                    let on = focus.contains(tag)
                    Button {
                        if on { focus.remove(tag) } else { focus.insert(tag) }
                        save()
                    } label: {
                        Text(tag)
                            .font(.subheadline)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(on ? Color.green.opacity(0.2) : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(on ? Color.green : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if Self.isSparring(w) {
                if !options.isEmpty { Divider() }
                Text(w.category == .bjj ? "Who did you roll with?" : "Who did you spar?").font(.headline)
                TextField("Partner's name", text: $partner)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                let recent = workoutStore.recentPartners(profileID: w.profileID).filter { $0 != partner }.prefix(4)
                if !recent.isEmpty {
                    HStack {
                        ForEach(Array(recent), id: \.self) { name in
                            Button(name) { partner = name; save() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                if !w.roundStats.isEmpty {
                    Text("How did each round go? Tap to change.").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(0..<min(w.roundStats.count, 12), id: \.self) { i in
                            let r = i < results.count ? results[i] : ""
                            Button {
                                cycle(i, count: w.roundStats.count)
                            } label: {
                                VStack(spacing: 2) {
                                    Text("R\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                                    Text(r.isEmpty ? "–" : r)
                                        .font(.headline)
                                        .frame(width: 34, height: 34)
                                        .background(color(r).opacity(0.2), in: Circle())
                                        .foregroundStyle(color(r))
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Round \(i + 1): \(label(r))")
                        }
                    }
                }
            }
        }
        .card()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            focus = Set(w.focusTags)
            partner = w.partner ?? ""
            results = w.roundResults
        }
        .onDisappear(perform: save)
    }

    static func isSparring(_ w: SavedWorkout) -> Bool {
        w.category.hasPartner || (w.drillTag == .hardSparring && !w.category.isRun) || w.partner != nil
    }

    private func cycle(_ i: Int, count: Int) {
        if results.count < count { results += Array(repeating: "", count: count - results.count) }
        let order = ["", "W", "E", "L"]
        let next = (order.firstIndex(of: results[i]) ?? 0) + 1
        results[i] = order[next % order.count]
        save()
    }

    private func color(_ r: String) -> Color {
        switch r {
        case "W": return .green
        case "L": return .red
        case "E": return .orange
        default: return .secondary
        }
    }

    private func label(_ r: String) -> String {
        switch r {
        case "W": return "won"
        case "L": return "lost"
        case "E": return "even"
        default: return "not scored"
        }
    }

    private func save() {
        let trimmed = results.reversed().drop { $0.isEmpty }.reversed()
        workoutStore.updateTags(workoutID: workoutID, focus: options.filter { focus.contains($0) } + focus.filter { !options.contains($0) }.sorted(),
                                partner: partner, roundResults: Array(trimmed))
    }
}
