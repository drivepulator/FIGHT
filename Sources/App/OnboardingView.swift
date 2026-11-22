import SwiftUI

/// First-run setup: one minute, five screens, big buttons. Everything after this is personalised.
struct OnboardingView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @Environment(WorkoutSession.self) var session
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var draft = AthleteProfile()
    @State private var weightText = ""
    @State private var targetText = ""
    @State private var fightDate = Date().addingTimeInterval(56 * 86400)
    @State private var showingScanner = false
    @StateObject private var airPods = HeadMotionTracker()
    @FocusState private var typing: Bool

    private let pages = 5
    private static let formats = [FightFormat(rounds: 3, minutes: 2), FightFormat(rounds: 3, minutes: 3), FightFormat(rounds: 5, minutes: 3)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if page > 0 && page < pages - 1 {
                    Button("Skip") { page = pages - 1 }
                        .accessibilityHint("Jumps to the last step. You can change everything later in You.")
                }
                if workoutStore.activeProfile.setupDone {
                    Button("Close") { dismiss() }
                        .accessibilityHint("Closes setup without changing anything")
                }
                ProgressView(value: Double(page + 1), total: Double(pages))
                    .tint(.red)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            TabView(selection: $page) {
                aboutYou.tag(0)
                discipline.tag(1)
                goal.tag(2)
                sensors.tag(3)
                ready.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: page)

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button {
                    if typing { typing = false } else { advance() }
                } label: {
                    Text(typing ? "Done" : (page == pages - 1 ? "Start Training" : "Continue"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
            }
            .padding()
        }
        .sheet(isPresented: $showingScanner) {
            DeviceScannerSheet().presentationDetents([.medium, .large])
        }
        .onAppear {
            draft = workoutStore.activeProfile
            if draft.name == "Fighter" { draft.name = "" }
            weightText = WeightUnits.number(draft.weightKg, draft.useImperial)
            targetText = WeightUnits.number(draft.targetFightWeightKg, draft.useImperial)
            if let d = draft.fightDate, d > Date() { fightDate = d }
        }
        .onChange(of: page) { _, p in
            typing = false
            if p == 3 { airPods.start() } else { airPods.stop() }
        }
        .onDisappear { airPods.stop() }
        .interactiveDismissDisabled()
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Pages

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.heavy))
            Text(sub).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var aboutYou: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image("AppLogo")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("FIGHT")
                header("Hi, fighter", "Four quick questions so FIGHT can set your heart-rate zones.")
                field {
                    TextField("Your name", text: $draft.name)
                        .textContentType(.givenName)
                        .focused($typing)
                        .submitLabel(.done)
                        .font(.title3)
                }
                field {
                    Stepper("Age: \(draft.age)", value: $draft.age, in: 13...85)
                }
                field {
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("Weight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .focused($typing)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        WeightUnitChip(text: $weightText)
                    }
                }
                field {
                    HStack {
                        Text("Height")
                        Spacer()
                        Stepper(HeightUnits.text(draft.heightCm, draft.heightImperial), value: $draft.heightCm, in: 120...230,
                                step: draft.heightImperial ? HeightUnits.cmPerInch : 1)
                            .fixedSize()
                        UnitChip(metric: "cm", imperial: "ft", isImperial: $draft.heightImperial, accessibilityName: "Height unit")
                    }
                }
            }
            .padding(24)
        }
    }

    private var discipline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header("What do you train?", "Pick all that apply. Your first pick is your main sport: it sets weight classes and combos.")
                TrainingChoices(disciplines: Binding(get: { draft.trainedDisciplines },
                                                     set: { draft.setDisciplines($0) }),
                                equipment: $draft.equipment)
                Text("Your fight format").font(.headline).padding(.top, 6)
                HStack(spacing: 10) {
                    ForEach(Self.formats) { f in
                        bigChoice(f.label, selected: draft.formatRounds == f.rounds && draft.formatMinutes == f.minutes) {
                            draft.formatRounds = f.rounds
                            draft.formatMinutes = f.minutes
                        }
                    }
                }
                Text("Rounds × minutes. Your Gas Tank is measured against it.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var goal: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header("What's the goal?", "Today will lead with what matters most to you.")
                ForEach(FighterGoal.allCases) { g in
                    Button {
                        draft.goal = g
                    } label: {
                        Label(g.rawValue, systemImage: g.icon)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(draft.goal == g ? Color.red.opacity(0.18) : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(draft.goal == g ? Color.red : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                if draft.goal == .fight {
                    field {
                        DatePicker("Fight date", selection: $fightDate, in: Date()..., displayedComponents: .date)
                    }
                }
                if draft.goal != .fitter {
                    field {
                        HStack {
                            Text("Target weight")
                            Spacer()
                            TextField("Target", text: $targetText)
                                .keyboardType(.decimalPad)
                                .focused($typing)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 90)
                            Text(WeightUnits.unit(workoutStore.activeProfile.useImperial)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var sensors: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header("Your gear", "Both are optional. You can connect later.")
                sensorRow(icon: "heart.fill", title: "Heart-rate strap",
                          detail: bleManager.isConnected ? "Connected: \(bleManager.connectedDeviceName)" : "Put it on and wet the sensor",
                          ok: bleManager.isConnected, showFind: !bleManager.isConnected)
                sensorRow(icon: "airpodspro", title: "AirPods",
                          detail: airPods.isReceiving ? "Working. Move your head: \(airPods.totalMoves) moves" : "Put them in to track head movement and your chin",
                          ok: airPods.isReceiving, showFind: false)
                Text("No strap? You can still time rounds and use the bag coach.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            header("You're set, \(draft.name.isEmpty ? "fighter" : draft.name)", "Here's how FIGHT works:")
            tip("sun.max.fill", "Today", "Tells you to train hard, go easy or rest, and has your session ready. Press Start.")
            tip("chart.line.uptrend.xyaxis", "Progress", "Your fitness, gas tank, defence and fight camp.")
            tip("waveform.path.ecg", "Just train", "Rounds, recovery and head movement are tracked automatically.")
            Spacer()
        }
        .padding(24)
    }

    private func bigChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(selected ? Color.red.opacity(0.18) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(selected ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sensorRow(icon: String, title: String, detail: String, ok: Bool, showFind: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: ok ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(ok ? Color.green : Color.red)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showFind {
                Button("Find") { showingScanner = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.red).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Save

    private func advance() {
        if page < pages - 1 {
            page += 1
            return
        }
        var p = workoutStore.activeProfile
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { p.name = name }
        p.age = draft.age
        p.heightCm = draft.heightCm
        p.heightImperial = draft.heightImperial
        if let w = Double(weightText.replacingOccurrences(of: ",", with: ".")) {
            let kg = WeightUnits.toKg(w, p.useImperial)
            if (35...200).contains(kg) { p.weightKg = kg }
        }
        if draft.goal != .fitter, let t = Double(targetText.replacingOccurrences(of: ",", with: ".")) {
            let kg = WeightUnits.toKg(t, p.useImperial)
            if (35...200).contains(kg) { p.targetFightWeightKg = kg }
        }
        p.setDisciplines(draft.trainedDisciplines)
        p.equipment = draft.equipment
        p.formatRounds = draft.formatRounds
        p.formatMinutes = draft.formatMinutes
        p.goal = draft.goal
        if draft.goal == .fight { p.fightDate = fightDate }
        p.setupDone = true
        p.sanitize()
        workoutStore.activeProfile = p
        session.applyFirstSetup(discipline: p.bio.discipline, roundMinutes: p.formatMinutes)
        dismiss()
    }
}

/// Shows setup for any fighter who hasn't done it and has no sessions yet,
/// and offers the morning readiness check once a day before noon.
struct FirstRunModifier: ViewModifier {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @AppStorage("fight.morningOffered") private var morningOffered = ""
    @State private var showingOnboarding = false
    @State private var offerMorningCheck = false
    @State private var found: FoundFighter?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showingOnboarding) {
                OnboardingView()
            }
            .alert("Good morning", isPresented: $offerMorningCheck) {
                Button("Check Readiness") {
                    navigation.selectedTab = .corner
                    navigation.requestReadinessCheck = true
                }
                Button("Not Today", role: .cancel) {}
            } message: {
                Text("Take the 2-minute readiness check so FIGHT can plan today.")
            }
            .alert(found.map { "Restore \($0.name)?" } ?? "", isPresented: Binding(get: { found != nil }, set: { if !$0 { found = nil } })) {
                Button("Restore") {
                    if let f = found { workoutStore.restore(f) }
                    found = nil
                }
                Button("Not Now", role: .cancel) { found = nil }
            } message: {
                if let f = found {
                    Text("FIGHT found \(f.sessions) session\(f.sessions == 1 ? "" : "s") from \(f.name), a fighter that was deleted. You can also restore later from You → Recently Deleted.")
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let f = workoutStore.foundFighters.first {
                    found = f
                    return
                }
                if needsSetup {
                    showingOnboarding = true
                } else {
                    offerMorningCheckIfNeeded()
                }
            }
            .onChange(of: workoutStore.activeProfileID) { _, _ in
                if needsSetup { showingOnboarding = true }
            }
            .onChange(of: navigation.requestSetup) { _, want in
                guard want else { return }
                navigation.requestSetup = false
                showingOnboarding = true
            }
    }

    private var needsSetup: Bool {
        let p = workoutStore.activeProfile
        return !p.setupDone && !workoutStore.workouts.contains { $0.profileID == p.id }
    }

    private func offerMorningCheckIfNeeded() {
        let now = Date()
        let today = now.formatted(.iso8601.year().month().day())
        guard Calendar.current.component(.hour, from: now) < 12, morningOffered != today else { return }
        let checkedToday = workoutStore.activeReadings.contains { Calendar.current.isDateInToday($0.date) }
        morningOffered = today
        if !checkedToday { offerMorningCheck = true }
    }
}
