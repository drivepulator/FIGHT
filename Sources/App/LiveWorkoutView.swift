import SwiftUI
import Charts
import UniformTypeIdentifiers

struct LiveWorkoutView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    @Environment(WorkoutSession.self) var session
    /// Two-way bindings into the session (pickers, toggles, sheets).
    private var sessionBinding: Bindable<WorkoutSession> { Bindable(session) }
    @EnvironmentObject var undo: UndoCenter
    @ScaledMetric(relativeTo: .largeTitle) private var heroBPMSize: CGFloat = 74

    @State private var showingDeviceSheet = false
    @State private var showingTCXImporter = false
    @State private var showingFinishConfirm = false
    @State private var showingBagSettings = false
    @State private var choosingPlan = false
    @State private var showingSetup = false
    @State private var plyoSheet: PlyoChoice?
    @State private var chooser: MainChoice?
    @State private var chooserFollowUp: ChooserFollowUp?
    @State private var showingMix = false
    /// A door picked on the Start sheet; its chooser opens once that sheet has closed.
    @State private var pendingDoor: MainChoice?
    /// 0 = fight clock, 1 = details.
    @State private var livePage = 0
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 84

    var body: some View {
        let profile = workoutStore.activeProfile
        let currentZone = profile.zone(for: bleManager.currentBPM)

        NavigationStack {
            Group {
                if session.isRecording {
                    // Bottom quarter: big controls. Above: the fight clock fills the screen,
                    // and the details are a scroll away.
                    GeometryReader { g in
                        let controls = min(max(150, g.size.height * 0.27), 240)
                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(spacing: 16) {
                                    liveMainPage(currentZone: currentZone)
                                        .frame(height: max(320, g.size.height - controls))
                                    liveDetailsContent(profile: profile)
                                }
                            }
                            .scrollIndicators(.hidden)
                            liveControlBar(height: controls)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            connectionBanner

                            if let lthr = session.lthrTestResultBanner {
                                lthrSuccessBanner(lthr: lthr)
                            }

                            AutoStartBanner()

                            if session.queuedPlan != nil {
                                ReadyCard()
                            }

                            TodayCard()

                            if bleManager.isConnected {
                                idleHeartRate(currentZone: currentZone)
                            }

                            WeekStrip()

                            FightCountdownCard()

                            LastSessionCard()
                        }
                        .padding()
                    }
                }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(session.isRecording ? "" : "Corner")
            .navigationBarTitleDisplayMode(session.isRecording ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDeviceSheet = true
                    } label: {
                        Label("Sensors", systemImage: bleManager.isConnected ? "heart.circle.fill" : "antenna.radiowaves.left.and.right")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !session.isRecording {
                        AvatarButton()
                    }
                }
            }
            .sheet(isPresented: $navigation.showingStart, onDismiss: {
                if let door = pendingDoor {
                    pendingDoor = nil
                    chooser = door
                }
            }) {
                StartSheet { door in pendingDoor = door }
            }
            .sheet(isPresented: $showingDeviceSheet) {
                DeviceScannerSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingBagSettings) {
                BagSettingsSheet(prefs: sessionBinding.bagPrefs)
            }
            .sheet(isPresented: $showingSetup) {
                setupSheet
            }
            .alert("Fitness test didn't count", isPresented: Binding(
                get: { session.lthrTestNote != nil },
                set: { if !$0 { session.lthrTestNote = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.lthrTestNote ?? "")
            }
            .alert("Session not saved", isPresented: Binding(
                get: { session.saveError != nil },
                set: { if !$0 { session.saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.saveError ?? "")
            }
            .sheet(item: $chooser, onDismiss: {
                // Plyo and Mix have their own screens: open them once the picker has closed.
                switch chooserFollowUp {
                case .plyo: plyoSheet = PlyoChoice(variant: .power)
                case .mix: showingMix = true
                case nil: break
                }
                chooserFollowUp = nil
            }) { door in
                ChooserSheet(main: door) { follow in chooserFollowUp = follow }
            }
            .sheet(item: $plyoSheet) { choice in
                PlyoPickerSheet(initial: choice.variant)
            }
            .sheet(isPresented: $showingMix) {
                MixBuilderSheet()
            }
            .onChange(of: navigation.plyoToPick) { _, v in
                guard let v else { return }
                navigation.plyoToPick = nil
                plyoSheet = PlyoChoice(variant: v)
            }
            .confirmationDialog(session.bagSessionComplete ? "Bag session complete" : "Finish workout?",
                                isPresented: $showingFinishConfirm, titleVisibility: .visible) {
                Button("Save Workout") { session.finishAndSave() }
                Button("Discard Workout", role: .destructive) {
                    if let w = session.discard() {
                        undo.show("Workout discarded") { workoutStore.restore(w) }
                    }
                }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("\(formatDuration(session.elapsedSeconds)) recorded")
            }
            .alert("Recover unfinished workout?", isPresented: Binding(
                get: { session.recoverableDraft != nil },
                set: { if !$0 && session.recoverableDraft != nil { session.postponeRecoveredDraft() } }
            )) {
                Button("Save It") { session.resolveRecoveredDraft(save: true) }
                Button("Discard", role: .destructive) { session.resolveRecoveredDraft(save: false) }
                Button("Decide Later", role: .cancel) { session.postponeRecoveredDraft() }
            } message: {
                if let d = session.recoverableDraft {
                    Text("A \(d.category.rawValue) session from \(d.startTime.formatted(date: .abbreviated, time: .shortened)) (\(formatDuration(d.elapsedSeconds))) was interrupted.")
                }
            }
            .onAppear {
                session.syncFromProfile()
                applyPending()
                applyPlanToRun()
                if let v = navigation.plyoToPick {
                    navigation.plyoToPick = nil
                    plyoSheet = PlyoChoice(variant: v)
                }
            }
            .onChange(of: navigation.pendingPrescription) { _, _ in applyPending() }
            .onChange(of: navigation.planToRun) { _, _ in applyPlanToRun() }
            .onChange(of: session.isRecording) { _, recording in
                if recording { choosingPlan = false; showingSetup = false; livePage = 0 }
            }
            .onChange(of: workoutStore.activeProfileID) { _, _ in
                session.syncFromProfile()
                session.restoreLastSetup()
            }
            .onChange(of: session.requestFinishPrompt) { _, wants in
                if wants {
                    showingFinishConfirm = true
                    session.requestFinishPrompt = false
                }
            }
            .sensoryFeedback(.impact(weight: .heavy), trigger: session.currentRound)
            .sensoryFeedback(.warning, trigger: session.isRestPeriod)
            .sensoryFeedback(.start, trigger: session.isRecording)
            .sheet(isPresented: sessionBinding.showingSummary) {
                if let workout = session.finishedWorkout {
                    NavigationStack {
                        WorkoutDetailView(workout: workout)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { session.showingSummary = false }
                                }
                            }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingTCXImporter,
                allowedContentTypes: [UTType(filenameExtension: "tcx") ?? .xml, .xml],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first,
                   let imported = workoutStore.importTCXGhost(from: url) {
                    session.selectedGhost = imported
                }
            }
        }
    }

    private var bagAvailable: Bool {
        session.selectedCategory.allowsBagCoach
    }

    private var planBagBlockActive: Bool {
        session.isRunningPlan && !session.isInPlanTransition && !session.planComplete && session.currentBlock?.kind == .bagRounds
    }

    private func applyPlanToRun() {
        guard let plan = navigation.planToRun, !session.isRecording else { return }
        navigation.planToRun = nil
        session.queue(plan)
        if navigation.startPlanNow {
            navigation.startPlanNow = false
            session.startWorkout()
        }
    }

    private func queuedPlanCard(_ plan: TrainingPlan, profile: AthleteProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PLAN LOADED", systemImage: "list.bullet.rectangle.portrait.fill")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    session.unqueuePlan()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove plan")
            }
            Text(plan.title).font(.title3.weight(.bold))
            Text("\(PlanFormat.totalLabel(plan.plannedSeconds)) • \(plan.blocks.count) blocks\(plan.author.isEmpty ? "" : " • by \(plan.author)")")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(plan.blocks.indices, id: \.self) { i in
                let b = plan.blocks[i]
                HStack(spacing: 8) {
                    Image(systemName: b.kind.icon).foregroundStyle(.orange).frame(width: 20)
                    Text(b.title).font(.subheadline)
                    Spacer()
                    Text(b.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func applyPending() {
        guard let p = navigation.pendingPrescription, !session.isRecording else { return }
        navigation.pendingPrescription = nil
        session.apply(p)
    }

    // MARK: Banners

    @ViewBuilder
    private var connectionBanner: some View {
        if bleManager.isConnected && !bleManager.isSignalLost {
            Button {
                showingDeviceSheet = true
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(bleManager.connectedDeviceName).lineLimit(1)
                    if let battery = bleManager.batteryLevel {
                        Text("· \(battery)%").foregroundStyle(battery > 20 ? Color.secondary : Color.orange)
                    }
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sensor connected: \(bleManager.connectedDeviceName)")
        } else {
            fullConnectionBanner
        }
    }

    private var fullConnectionBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(bleManager.isConnected ? (bleManager.isSignalLost ? Color.orange : Color.green) : Color.orange)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.isConnected ? bleManager.connectedDeviceName : "Sensor Not Connected")
                    .font(.subheadline.weight(.semibold))
                Text(bleManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = bleManager.batteryLevel {
                Label("\(battery)%", systemImage: battery > 20 ? "battery.75" : "battery.25")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(battery > 20 ? .green : .orange)
            }
            Button(bleManager.isConnected ? "Change" : "Connect") {
                showingDeviceSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func planBanner(_ p: WorkoutPrescription) -> some View {
        let bpm = bleManager.currentBPM
        let status: (text: String, color: Color)
        if bpm <= 0 {
            status = ("Waiting for HR", Color.secondary)
        } else if bpm < p.targetLowBPM {
            status = ("Below target", Color.blue)
        } else if bpm > p.targetHighBPM {
            status = ("Above target", Color.orange)
        } else {
            status = ("On target", Color.green)
        }
        return HStack(spacing: 10) {
            Image(systemName: "list.clipboard.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Coach plan: \(p.title)")
                    .font(.subheadline.weight(.bold))
                Text("\(p.structure) • \(p.targetLowBPM)–\(p.targetHighBPM) BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.isRecording {
                Text(status.text)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(status.color)
            } else {
                Button {
                    session.activePlan = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove coach plan")
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func lthrSuccessBanner(lthr: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lactate threshold updated: \(lthr) BPM")
                    .font(.subheadline.weight(.bold))
                Text("Your zones now use this threshold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo") { session.undoLTHRTest() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Keep") { session.lthrTestResultBanner = nil }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Setup

    private enum SetupMode: String, CaseIterable, Identifiable {
        case free = "Free"
        case rounds = "Rounds"
        case bag = "Bag Coach"
        case plan = "Plan"
        var id: String { rawValue }

        var explainer: String {
            switch self {
            case .free: return "Just record heart rate, zones and calories."
            case .rounds: return "Round bell and rest timer."
            case .bag: return "A voice coach calls combos for you on the bag."
            case .plan: return "Follow a step-by-step session from you or your coach."
            }
        }
    }

    /// Only the modes that make sense for this workout type.
    private var availableModes: [SetupMode] {
        let c = session.selectedCategory
        var modes: [SetupMode] = [.free]
        if c.allowsRounds { modes.append(.rounds) }
        if c.allowsBagCoach { modes.append(.bag) }
        if c.allowsPlans { modes.append(.plan) }
        return modes
    }

    private var setupMode: SetupMode {
        if session.queuedPlan != nil || choosingPlan { return .plan }
        if session.bagEnabled { return .bag }
        if session.roundTimerEnabled { return .rounds }
        return .free
    }

    private var setupModeBinding: Binding<SetupMode> {
        Binding(get: { setupMode }, set: { mode in
            choosingPlan = mode == .plan
            if mode != .plan { session.unqueuePlan() }
            switch mode {
            case .free:
                session.bagEnabled = false
                session.roundTimerEnabled = false
            case .rounds:
                session.bagEnabled = false
                session.roundTimerEnabled = true
            case .bag:
                if !bagAvailable { session.selectedCategory = .heavyBag }
                session.bagEnabled = true
            case .plan:
                session.bagEnabled = false
            }
        })
    }

    /// Only the workout types that fit what this fighter trains.
    private var workoutTypes: [WorkoutCategory] {
        var list = DisciplineRules.categories(for: workoutStore.activeProfile.trainedDisciplines)
        if !list.contains(session.selectedCategory) { list.insert(session.selectedCategory, at: 0) }
        return list
    }

    private var workoutSetupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your workout")
                    .font(.headline)
                Spacer()
                Picker("Workout type", selection: sessionBinding.selectedCategory) {
                    // Grouped so a run never sits between bag work and sparring.
                    Section("Fight training") {
                        ForEach(workoutTypes.filter { !$0.isRun && $0 != .conditioning && $0 != .lthrTest }) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                    Section("Run and walk") {
                        ForEach(workoutTypes.filter(\.isRun)) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                    Section("Other") {
                        ForEach(workoutTypes.filter { $0 == .conditioning || $0 == .lthrTest }) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(session.queuedPlan != nil)
            }

            if session.selectedCategory == .lthrTest {
                Text("30-minute threshold test: a 10-minute warm-up, then 20 minutes as hard as you can sustain. Your zones update automatically at the end.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if session.selectedCategory.isRun {
                runEssentials
            } else {
                if availableModes.count > 1 {
                    Picker("Mode", selection: setupModeBinding) {
                        ForEach(availableModes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Text(setupMode.explainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch setupMode {
                case .free:
                    EmptyView()
                case .rounds:
                    roundEssentials
                case .bag:
                    bagEssentials
                case .plan:
                    planEssentials
                }
            }
        }
        .card()
    }

    /// Runs and walks: GPS does the work; the only choice is easy or hard.
    private var runEssentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Run type", selection: sessionBinding.selectedDrillTag) {
                ForEach(session.selectedCategory.drillTags) { Text($0.label(for: session.selectedCategory)).tag($0) }
            }
            .pickerStyle(.segmented)
            Label("GPS distance, pace and splits. The coach calls every \(workoutStore.activeProfile.useImperial ? "mile" : "km").",
                  systemImage: "location.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var roundEssentials: some View {
        HStack {
            Picker("Round", selection: sessionBinding.workDurationSeconds) {
                ForEach([30, 60, 90, 120, 180, 240, 300], id: \.self) { s in
                    Text("\(formatDuration(TimeInterval(s))) rounds").tag(s)
                }
            }
            .pickerStyle(.menu)
            Spacer()
            Picker("Rest", selection: sessionBinding.restDurationSeconds) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { s in
                    Text("\(formatDuration(TimeInterval(s))) rest").tag(s)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var bagEssentials: some View {
        let prefs = session.bagPrefs
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                presetButton("Steady 30", minutes: 30, work: 180, rest: 60, tempo: .steady)
                presetButton("Fight Pace 15", minutes: 15, work: 180, rest: 60, tempo: .fightPace)
                presetButton("Burnout 10", minutes: 10, work: 60, rest: 30, tempo: .burnout)
            }
            Text("\(prefs.totalMinutes) min • \(prefs.estimatedTotalRounds) rounds • \(prefs.tempo.displayName) • \(prefs.stance.rawValue)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            BagPreparationStatus(audio: session.audio, compact: true)
        }
    }

    @ViewBuilder
    private var planEssentials: some View {
        if let plan = session.queuedPlan {
            queuedPlanCard(plan, profile: workoutStore.activeProfile)
        } else {
            Menu {
                let mine = workoutStore.plans
                if !mine.isEmpty {
                    Section("My Plans") {
                        ForEach(mine) { p in
                            Button(p.title) { session.queue(p) }
                        }
                    }
                }
                Section("Templates") {
                    ForEach(PlanTemplates.all) { p in
                        Button(p.title) { session.queue(p) }
                    }
                }
            } label: {
                Label("Choose a Plan", systemImage: "list.bullet.rectangle.portrait")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
    }

    /// Runs and tests have nothing extra to set; fight sessions get the session goal, bag
    /// settings and the ghost opponent.
    private var hasAdvancedOptions: Bool {
        let c = session.selectedCategory
        return !c.isRun && c != .lthrTest && session.queuedPlan == nil
    }

    private var advancedSubtitle: String {
        var parts = ["Session goal"]
        if session.bagEnabled { parts.append("bag settings") }
        if session.selectedCategory.allowsGhost { parts.append("ghost opponent") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var advancedSetup: some View {
        let c = session.selectedCategory
        if c.drillTags.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Session goal", selection: sessionBinding.selectedDrillTag) {
                    ForEach(c.drillTags) { tag in
                        Text(tag.label(for: c)).tag(tag)
                    }
                }
                .pickerStyle(.segmented)
                Text("Tells the coach what this session was for, so the review can judge it fairly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()
        }

        if session.bagEnabled {
            Button {
                showingBagSettings = true
            } label: {
                Label("Bag coach settings: stance, level, strikes, custom combos", systemImage: "slider.horizontal.3")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }

        if c.allowsGhost {
            ghostSimulatorCard
        }
    }

    // MARK: Hero

    private func heroBPMCard(currentZone: HeartRateZoneInfo, profile: AthleteProfile) -> some View {
        let totalCalories = session.activeCalories + session.bmrCalories
        let bpm = bleManager.currentBPM
        return VStack(spacing: 12) {
            HStack {
                Text(currentZone.name.uppercased())
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(currentZone.color.opacity(0.22), in: Capsule())
                    .foregroundStyle(currentZone.color)
                Spacer()
                if let remain = session.pendingRecoveryRemaining {
                    Label("Auto HRR: \(remain)s", systemImage: "arrow.down.heart.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cyan.opacity(0.2), in: Capsule())
                        .foregroundStyle(.cyan)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: heroBPMSize * 0.43))
                    .foregroundStyle(bpm > 0 ? currentZone.color : .secondary)
                    .symbolEffect(.pulse, isActive: bpm > 0)
                Text(bpm > 0 ? "\(bpm)" : "--")
                    .font(.system(size: heroBPMSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: bpm)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("BPM")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bpm > 0 ? "Heart rate \(bpm) beats per minute, \(currentZone.name)" : "No heart rate signal")

            zoneBar(bpm: bpm, profile: profile)

            if session.isRecording {
            HStack(spacing: 12) {
                stat("ELAPSED", formatDuration(session.elapsedSeconds), .primary)
                Divider().frame(height: 28)
                stat("ACTIVE KCAL", "\(Int(session.activeCalories))", .orange)
                Divider().frame(height: 28)
                stat("TOTAL KCAL", "\(Int(totalCalories))", .primary)
                Divider().frame(height: 28)
                stat("AVG / MAX", "\(session.liveAverageBPM)/\(session.liveMaxBPM)", .primary)
            }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color == .primary ? Color.secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func zoneBar(bpm: Int, profile: AthleteProfile) -> some View {
        let current = bpm > 0 ? profile.zone(for: bpm).number : 0
        let colors: [Color] = [.blue, .green, .yellow, .orange, .red]
        return HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { z in
                VStack(spacing: 3) {
                    Capsule()
                        .fill(colors[z - 1].opacity(z == current ? 1 : 0.25))
                        .frame(height: z == current ? 10 : 6)
                    Text("Z\(z)")
                        .font(.caption2.weight(z == current ? .heavy : .regular))
                        .foregroundStyle(z == current ? colors[z - 1] : Color.secondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: current)
        .accessibilityHidden(true)
    }

    // MARK: LTHR

    private var lthrFieldTestCard: some View {
        let elapsed = session.elapsedSeconds
        let warmupRemaining = max(0, 600 - Int(elapsed))
        let trialRemaining = max(0, 1200 - max(0, Int(elapsed) - 600))
        let trial = session.samples.filter { $0.elapsedSeconds >= 600 }
        let rolling = trial.isEmpty ? 0 : trial.map(\.bpm).reduce(0, +) / trial.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("30-MIN LTHR FIELD TEST", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.orange)
                Spacer()
                if session.isRecording {
                    Text(elapsed < 600 ? "PHASE 1: WARM-UP" : "PHASE 2: 20-MIN TRIAL")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text("10 min progressive warm-up, then 20 min at your maximum sustainable pace. The average HR of the final 20 minutes sets your lactate threshold and zones automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.isRecording {
                HStack {
                    if elapsed < 600 {
                        Text("Warm-up left: \(formatDuration(TimeInterval(warmupRemaining)))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    } else {
                        Text("Trial left: \(formatDuration(TimeInterval(trialRemaining)))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("Live LTHR: \(rolling > 0 ? "\(rolling)" : "--")")
                            .font(.subheadline.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Bag setup

    private func presetButton(_ title: String, minutes: Int, work: Int, rest: Int, tempo: BagTempo) -> some View {
        let p = session.bagPrefs
        let selected = p.totalMinutes == minutes && p.workSeconds == work && p.restSeconds == rest && p.tempo == tempo
        return Button(title) {
            var prefs = session.bagPrefs
            prefs.totalMinutes = minutes
            prefs.workSeconds = work
            prefs.restSeconds = rest
            prefs.tempo = tempo
            session.bagPrefs = prefs
        }
        .buttonStyle(.bordered)
        .tint(selected ? .orange : .secondary)
        .controlSize(.small)
    }

    // MARK: Round bell

    private var roundBellCard: some View {
        VStack(spacing: 10) {
            Toggle(isOn: sessionBinding.roundTimerEnabled) {
                Label("Round Bell & Corner Timer", systemImage: "bell.fill")
                    .font(.subheadline.weight(.bold))
            }
            .tint(.orange)
            .disabled(session.isRecording || session.bagEnabled)

            if session.roundTimerEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.isRestPeriod ? "ROUND \(session.currentRound) • REST" : "ROUND \(session.currentRound)\(session.roundsLimit.map { " OF \($0)" } ?? "") • WORK")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(session.isRestPeriod ? .cyan : .orange)
                        Text(formatDuration(session.isRecording ? session.phaseRemaining : session.currentPhaseTarget))
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(session.isRestPeriod ? .cyan : .primary)
                    }
                    Spacer()
                    if !session.isRecording && !session.bagEnabled {
                        VStack(alignment: .trailing, spacing: 6) {
                            Picker("Work", selection: sessionBinding.workDurationSeconds) {
                                ForEach([30, 60, 90, 120, 180, 240, 300], id: \.self) { s in
                                    Text("\(formatDuration(TimeInterval(s))) work").tag(s)
                                }
                            }
                            .pickerStyle(.menu)
                            Picker("Rest", selection: sessionBinding.restDurationSeconds) {
                                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { s in
                                    Text("\(formatDuration(TimeInterval(s))) rest").tag(s)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    } else if session.isRecording && !session.isRestPeriod && !session.bagSessionComplete {
                        Button("End Round") {
                            session.endWorkPhase(manual: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Ghost

    private var ghostSimulatorCard: some View {
        let ghostBPM = session.selectedGhost?.interpolatedBPM(at: session.elapsedSeconds)
        let delta: Int? = (bleManager.currentBPM > 0 && ghostBPM != nil) ? bleManager.currentBPM - (ghostBPM ?? 0) : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ghost Opponent Pace", systemImage: "figure.run.square.stack.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if !session.isRecording {
                    Button {
                        showingTCXImporter = true
                    } label: {
                        Label("Import .TCX", systemImage: "doc.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            if !session.isRecording {
                Picker("Ghost Session", selection: sessionBinding.selectedGhost) {
                    Text("None (solo session)").tag(Optional<GhostSession>.none)
                    ForEach(workoutStore.allAvailableGhosts()) { g in
                        Text(g.title).tag(Optional(g))
                    }
                }
                .pickerStyle(.menu)
            } else if let ghost = session.selectedGhost {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ghost.title).font(.caption.weight(.bold))
                        Text("Ghost BPM: \(ghostBPM.map(String.init) ?? "Finished")")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    if let d = delta {
                        Text(d <= 0 ? "\(d) BPM (more efficient)" : "+\(d) BPM (higher strain)")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background((d <= 0 ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                            .foregroundStyle(d <= 0 ? .green : .orange)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Sparkline

    private func liveSparklineCard(profile: AthleteProfile) -> some View {
        let recent = Array(session.samples.suffix(120))
        let zones = profile.activeZones
        let ghost = session.selectedGhost
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REAL-TIME HEART RATE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if ghost != nil {
                    Text("Purple = Ghost")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                }
            }
            if recent.count >= 2 {
                Chart {
                    RuleMark(y: .value("Z2", zones.z2Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.green.opacity(0.4))
                    RuleMark(y: .value("Threshold", zones.z4Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.orange.opacity(0.5))
                    ForEach(recent) { pt in
                        LineMark(x: .value("Time", pt.elapsedSeconds), y: .value("BPM", pt.bpm))
                            .foregroundStyle(by: .value("Series", "Live"))
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    if let ghost {
                        ForEach(recent) { pt in
                            if let g = ghost.interpolatedBPM(at: pt.elapsedSeconds) {
                                LineMark(x: .value("Time", pt.elapsedSeconds), y: .value("BPM", g))
                                    .foregroundStyle(by: .value("Series", "Ghost"))
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(["Live": Color.red, "Ghost": Color.purple.opacity(0.8)])
                .chartLegend(.hidden)
                .chartYScale(domain: 55...210)
                .chartXAxis(.hidden)
                .frame(height: 130)
                .accessibilityLabel("Heart rate over the last two minutes")
            } else {
                Text("Start a workout to see your live heart-rate trace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 95)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Controls

    // MARK: Quick start

    private enum QuickStart { case last, coach, plyo, mix, plan }

    private var quickStartSelection: QuickStart {
        if let q = session.queuedPlan {
            if PlyoVariant.allCases.contains(where: { $0.planID == q.id }) { return .plyo }
            if q.title == "Mix" { return .mix }
            return .plan
        }
        if choosingPlan { return .plan }
        if session.activePlan != nil { return .coach }
        return .last
    }

    /// Last workout · Plyo · Mix · Plans. (Coach's pick lives on the Today card.)
    private var quickStartRow: some View {
        HStack(spacing: 8) {
            quickChip("Last", icon: "arrow.counterclockwise", selected: quickStartSelection == .last) {
                choosingPlan = false
                session.unqueuePlan()
                session.activePlan = nil
                session.restoreLastSetup()
            }
            quickChip("Plyo", icon: "figure.jumprope", selected: quickStartSelection == .plyo) {
                plyoSheet = PlyoChoice(variant: .power)
            }
            quickChip("Mix", icon: "square.stack.3d.up.fill", selected: quickStartSelection == .mix) {
                showingMix = true
            }
            if !workoutStore.plans.isEmpty || quickStartSelection == .plan {
                quickChip("Plans", icon: "list.bullet.rectangle", selected: quickStartSelection == .plan) {
                    choosingPlan = true
                    session.activePlan = nil
                    showingSetup = true
                }
            }
        }
    }

    private func quickChip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color.green.opacity(0.18) : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(selected ? Color.green : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var setupSummaryCard: some View {
        Button {
            showingSetup = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: session.queuedPlan != nil ? "list.bullet.rectangle.fill" : session.selectedCategory.icon)
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.setupSummary)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(setupDetailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Change")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens workout setup")
    }

    private var setupDetailLine: String {
        if let plan = session.queuedPlan { return "\(plan.blocks.count) blocks · ~\(plan.plannedSeconds / 60) min" }
        if let p = session.activePlan { return "Coach's pick · target \(p.targetLowBPM)–\(p.targetHighBPM) BPM" }
        if session.selectedCategory.isRun { return "GPS distance, pace and splits" }
        if session.bagEnabled { return "\(session.bagPrefs.tempo.displayName) · \(session.bagPrefs.totalMinutes) min" }
        if session.roundTimerEnabled { return "\(formatDuration(TimeInterval(session.restDurationSeconds))) rest between rounds" }
        return "Heart rate, zones and calories"
    }

    private var setupSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    workoutSetupCard
                    if hasAdvancedOptions {
                        AdvancedSection("More options", subtitle: advancedSubtitle, key: "live.setup") {
                            advancedSetup
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Workout Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSetup = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Live: fight clock page

    /// Everything that matters mid-round, always on screen: round, clock, heart rate.
    private func liveMainPage(currentZone: HeartRateZoneInfo) -> some View {
        VStack(spacing: 12) {
            liveHeader
            liveBigNumber
                .frame(maxHeight: .infinity)
            liveCallLine
            liveHeartStrip(currentZone: currentZone)
            liveWarning
            Label("Scroll for chart, combos and notes", systemImage: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var liveHeader: some View {
        if session.run.isActive {
            HStack {
                Label(session.run.isPaused ? "Paused" : "Roadwork",
                      systemImage: session.run.isPaused ? "pause.fill" : "figure.run")
                    .font(.headline)
                    .foregroundStyle(session.run.isPaused ? Color.orange : Color.secondary)
                Spacer()
                Text(formatDuration(session.elapsedSeconds))
                    .font(Theme.number(22))
            }
        } else if session.roundTimerEnabled {
            HStack {
                RoundDots(current: session.currentRound, total: session.roundsLimit)
                Spacer()
                Text(session.isRestPeriod ? "Rest" : "Round \(session.currentRound)\(session.roundsLimit.map { " of \($0)" } ?? "")")
                    .font(.headline)
                    .foregroundStyle(session.isRestPeriod ? Color.cyan : Color.primary)
            }
        } else {
            HStack {
                Text("Time").font(.headline).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// The clock (or distance on a run), sized to the space that's left.
    @ViewBuilder
    private var liveBigNumber: some View {
        if session.run.isActive {
            let unit = session.run.imperial ? "mi" : "km"
            VStack(spacing: 8) {
                GeometryReader { g in
                    Text(RouteMath.distanceText(session.run.distanceM, imperial: session.run.imperial))
                        .font(Theme.number(max(40, min(g.size.height * 0.8, g.size.width * 0.34))))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(unit).font(.title3.weight(.bold)).foregroundStyle(.secondary)
                HStack {
                    BigNumber(value: RouteMath.paceText(session.run.currentPace), label: "pace /\(unit)", size: 22)
                    BigNumber(value: RouteMath.paceText(session.run.averagePace), label: "avg /\(unit)", size: 22)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            let rest = session.roundTimerEnabled && session.isRestPeriod
            VStack(spacing: 4) {
                GeometryReader { g in
                    Text(formatDuration(session.roundTimerEnabled ? session.phaseRemaining : session.elapsedSeconds))
                        .font(Theme.number(max(40, min(g.size.height * 0.8, g.size.width * 0.3))))
                        .foregroundStyle(rest ? Color.cyan : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if session.roundTimerEnabled {
                    Text("\(formatDuration(session.elapsedSeconds)) total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The bag coach's call or the plan step, when there is one.
    @ViewBuilder
    private var liveCallLine: some View {
        if session.bagEnabled || planBagBlockActive {
            BagCallStrip(audio: session.audio, isComplete: session.bagSessionComplete)
        } else if session.isRunningPlan, let block = session.currentBlock {
            HStack {
                Text(block.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(formatDuration(session.blockRemaining))
                    .font(Theme.number(20))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// Heart rate in one zone-tinted strip.
    private func liveHeartStrip(currentZone: HeartRateZoneInfo) -> some View {
        let bpm = bleManager.currentBPM
        let live = bleManager.isConnected && bpm > 0
        let tint = live ? currentZone.color : Color.secondary
        let avg = session.liveAverageBPM
        let top = session.liveMaxBPM
        return HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: live)
            VStack(alignment: .leading, spacing: 0) {
                Text(live ? "\(bpm)" : "--")
                    .font(Theme.number(44))
                    .contentTransition(.numericText())
                    .animation(.default, value: bpm)
                Text(live ? currentZone.name : (bleManager.isConnected ? "No signal" : "No strap · tap to connect"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("avg \(avg > 0 ? "\(avg)" : "--")")
                Text("max \(top > 0 ? "\(top)" : "--")")
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if !bleManager.isConnected { showingDeviceSheet = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live ? "Heart rate \(bpm), \(currentZone.name). Average \(avg), max \(top)." : "No heart rate")
    }

    /// One short line instead of a banner.
    @ViewBuilder
    private var liveWarning: some View {
        if bleManager.isConnected && (bleManager.sensorContactDetected == false || bleManager.isSignalLost) {
            Label(bleManager.isSignalLost ? "No signal. Check the strap is on." : "Poor contact. Tighten or wet the strap.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        } else if session.run.isActive && session.run.permissionDenied {
            Label("Location is off: distance isn't tracked.", systemImage: "location.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    // MARK: Live: details page

    /// Below the fold: chart, plan, combos, records, notes.
    private func liveDetailsContent(profile: AthleteProfile) -> some View {
            VStack(spacing: 16) {
                if let plan = session.activePlan {
                    planBanner(plan)
                }
                if let autoBanner = session.latestAutoHRRBanner {
                    Label(autoBanner, systemImage: "arrow.down.heart.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                }
                if session.run.isActive {
                    RunLiveCard(run: session.run)
                }
                if let record = session.liveRecordBanner {
                    Label(record, systemImage: "trophy.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                }
                if session.isRunningPlan {
                    PlanRunnerCard()
                }
                if session.bagEnabled || planBagBlockActive {
                    BagComboCard(audio: session.audio, round: session.currentRound,
                                 totalRounds: session.roundsLimit ?? session.totalBagRounds,
                                 isComplete: session.bagSessionComplete)
                }
                if session.selectedCategory == .lthrTest {
                    lthrFieldTestCard
                }
                Group {
                    HStack {
                        BigNumber(value: formatDuration(session.elapsedSeconds), label: "total", size: 22)
                        BigNumber(value: "\(Int(session.activeCalories))", label: "active kcal", size: 22)
                        BigNumber(value: "\(Int(session.activeCalories + session.bmrCalories))", label: "total kcal", size: 22)
                    }
                    .card()
                    if let a = session.liveAlpha1 {
                        Label(String(format: "%@ • DFA α1 %.2f", a >= 0.75 ? "Below aerobic threshold" : "Above aerobic threshold", a),
                              systemImage: "waveform.path.ecg")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(a >= 0.75 ? .green : .orange)
                    }
                    liveSparklineCard(profile: profile)
                    if session.selectedGhost != nil {
                        ghostSimulatorCard
                    }
                    TextField("Corner note…", text: sessionBinding.workoutNotes)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding()
            .padding(.bottom, 12)
    }

    /// The round clock: the biggest thing on the screen while training.
    private var liveClock: some View {
        VStack(spacing: 6) {
            if session.roundTimerEnabled {
                RoundDots(current: session.currentRound, total: session.roundsLimit)
                Text(session.isRestPeriod ? "Rest" : "Round \(session.currentRound)\(session.roundsLimit.map { " of \($0)" } ?? "")")
                    .font(.headline)
                    .foregroundStyle(session.isRestPeriod ? Color.cyan : Color.secondary)
                Text(formatDuration(session.phaseRemaining))
                    .font(Theme.number(clockSize))
                    .foregroundStyle(session.isRestPeriod ? Color.cyan : Color.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("\(formatDuration(session.elapsedSeconds)) total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Time").font(.headline).foregroundStyle(.secondary)
                Text(formatDuration(session.elapsedSeconds))
                    .font(Theme.number(clockSize))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Glove-sized controls in the bottom quarter: end the round / skip rest, and hold to end.
    private func liveControlBar(height: CGFloat) -> some View {
        let buttonHeight = max(56, height - 32)
        return HStack(spacing: 12) {
            if session.roundTimerEnabled && !session.bagSessionComplete {
                Button {
                    if session.isRestPeriod {
                        session.skipRest()
                    } else {
                        session.endWorkPhase(manual: true)
                    }
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: session.isRestPeriod ? "forward.fill" : "bell.fill")
                            .font(.system(size: 32, weight: .bold))
                        Text(session.isRestPeriod ? "Skip rest" : "End round")
                            .font(.title3.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: buttonHeight)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .heavy), trigger: session.isRestPeriod)
            }
            HoldToEndButton(height: buttonHeight) { showingFinishConfirm = true }
        }
        .padding(.horizontal)
        .padding(.vertical, 16)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider() }
    }

    /// Heart rate before you start: one quiet line.
    private func idleHeartRate(currentZone: HeartRateZoneInfo) -> some View {
        let bpm = bleManager.currentBPM
        return HStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .foregroundStyle(bpm > 0 ? currentZone.color : .secondary)
                .symbolEffect(.pulse, isActive: bpm > 0)
            Text(bpm > 0 ? "\(bpm)" : "--")
                .font(Theme.number(24))
            Text(bpm > 0 ? "bpm · \(currentZone.name)" : "Waiting for heart rate")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Strap on")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private var controlButtons: some View {
        VStack(spacing: 10) {
            if !session.isRecording {
                Button {
                    session.startWorkout()
                } label: {
                    Label(session.selectedCategory == .lthrTest && session.queuedPlan == nil ? "Start 30-Min LTHR Test" : "Start", systemImage: "play.fill")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                if !bleManager.isConnected {
                    Text("No sensor connected. You can still record time and rounds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(role: .destructive) {
                    showingFinishConfirm = true
                } label: {
                    Label("Finish Workout", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Bag coach live card

struct BagComboCard: View {
    @ObservedObject var audio: AudioCoachEngine
    let round: Int
    let totalRounds: Int
    let isComplete: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("BAG COACH", systemImage: "figure.boxing")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.orange)
                Spacer()
                Text(isComplete ? "COMPLETE" : "Round \(min(round, totalRounds)) / \(totalRounds)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Group {
                if audio.comboTokens.isEmpty {
                    Text(isComplete ? "SESSION COMPLETE" : (audio.bagStatus.isEmpty ? "READY — HANDS UP" : audio.bagStatus))
                        .font(.system(.title, design: .rounded).weight(.heavy))
                        .foregroundStyle(audio.bagStatus.contains("REST") ? .cyan : .orange)
                        .multilineTextAlignment(.center)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(Array(audio.comboTokens.enumerated()), id: \.offset) { i, token in
                            Text(token)
                                .font(.system(.title2, design: .rounded).weight(.heavy))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(chipColor(i).opacity(i == audio.activeTokenIndex ? 1 : 0.22), in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(i == audio.activeTokenIndex ? Color.black : chipColor(i))
                                .scaleEffect(i == audio.activeTokenIndex ? 1.06 : 1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .animation(.spring(duration: 0.25), value: audio.activeTokenIndex)
            .animation(.easeOut(duration: 0.2), value: audio.comboSerial)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(audio.comboTokens.isEmpty ? audio.bagStatus : audio.comboTokens.joined(separator: ", "))

            HStack {
                Text("Strikes called: \(audio.strikesCuedCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if audio.isPreparingAudio {
                    ProgressView(value: audio.preparationProgress)
                        .frame(width: 80)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .sensoryFeedback(.impact(weight: .light), trigger: audio.comboSerial)
    }

    private func chipColor(_ i: Int) -> Color {
        i <= audio.activeTokenIndex ? .orange : .orange.opacity(0.9)
    }
}

struct BagPreparationStatus: View {
    @ObservedObject var audio: AudioCoachEngine
    var compact = false

    var body: some View {
        if audio.isPreparingAudio {
            HStack(spacing: 8) {
                ProgressView(value: audio.preparationProgress)
                Text("Preparing voice…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if !audio.voiceName.isEmpty && !compact {
            Text("Voice: \(audio.voiceName). Install an Enhanced voice in Settings › Accessibility › Spoken Content for clearer calls.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Wraps children onto multiple lines (combo chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Lay out rows, then centre each row horizontally.
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var x: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > bounds.width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((v, s))
            x += s.width + spacing
        }
        let totalHeight = rows.reduce(CGFloat(0)) { $0 + ($1.map { $0.1.height }.max() ?? 0) } + spacing * CGFloat(max(0, rows.count - 1))
        var y = bounds.minY + max(0, (bounds.height - totalHeight) / 2)
        for row in rows {
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            let rowHeight = row.map { $0.1.height }.max() ?? 0
            var rx = bounds.minX + max(0, (bounds.width - rowWidth) / 2)
            for (v, s) in row {
                v.place(at: CGPoint(x: rx, y: y + (rowHeight - s.height) / 2), proposal: ProposedViewSize(s))
                rx += s.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}


// MARK: - Plan runner card

struct PlanRunnerCard: View {
    @Environment(WorkoutSession.self) var session
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore

    var body: some View {
        if let plan = session.runningPlan {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(plan.title, systemImage: "list.bullet.rectangle.portrait.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    Text(session.planComplete ? "COMPLETE" : "Block \(min(session.planBlockIndex + 1, plan.blocks.count)) of \(plan.blocks.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 3) {
                    ForEach(plan.blocks.indices, id: \.self) { i in
                        Capsule()
                            .fill(stripColor(i))
                            .frame(height: 6)
                    }
                }
                .accessibilityHidden(true)

                if session.planComplete {
                    Text("PLAN COMPLETE")
                        .font(.system(.title, design: .rounded).weight(.heavy))
                        .foregroundStyle(.green)
                } else if let b = session.currentBlock {
                    if session.isInPlanTransition {
                        Text("UP NEXT")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.cyan)
                        Text(b.title)
                            .font(.system(.title, design: .rounded).weight(.heavy))
                        Text("\(b.kind.displayName) • \(b.summary)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Starts in \(Int((session.planTransitionRemaining ?? 0).rounded(.up)))s")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.cyan)
                            Spacer()
                            Button("Start Now") { session.startNextBlockNow() }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                        }
                    } else {
                        Text(b.title.uppercased())
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.orange)
                        if b.kind.isRoundBased {
                            Text("Round \(session.currentRound) of \(session.roundsLimit ?? b.rounds)\(session.isRestPeriod ? " • Rest" : "")")
                                .font(.title2.weight(.heavy))
                        } else {
                            Text(clock(session.blockRemaining))
                                .font(.system(size: 52, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            if b.kind == .strength {
                                Text("\(b.sets) × \(b.reps) reps • tap Done when finished")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let range = session.activeTargetRange {
                            targetChip(range)
                        }
                        if let last = session.setJumps.last, let best = session.setJumps.max() {
                            Label("Jump \(jumpShort(last)) · best \(jumpShort(best))", systemImage: "arrow.up.to.line")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(last < best * 0.9 ? Color.orange : Color.green)
                        }
                    }

                    if !b.cue.isEmpty {
                        Text("“\(b.cue)”")
                            .font(.title3.weight(.semibold))
                            .italic()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Only plain web links, with the site shown so you know where it goes.
                    if let v = PlanBlock.safeVideoURL(b.videoURL), let url = URL(string: v), let host = url.host {
                        Link(destination: url) {
                            Label("Watch technique (\(host.replacingOccurrences(of: "www.", with: "")))", systemImage: "play.rectangle.fill")
                                .font(.subheadline)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Skip") { session.finishCurrentBlock(skipped: true) }
                            .buttonStyle(.bordered)
                        if !session.isInPlanTransition {
                            Button(b.kind.isRoundBased ? "+1 Round" : "+1 Min") { session.extendCurrentBlock() }
                                .buttonStyle(.bordered)
                            if b.kind == .strength {
                                Button("Done") { session.finishCurrentBlock() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                            }
                        }
                        Spacer()
                    }
                    .controlSize(.small)

                    if !session.isInPlanTransition, let next = session.upcomingBlock {
                        Text("Then: \(next.title) • \(next.summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            .animation(.easeInOut(duration: 0.25), value: session.planBlockIndex)
        }
    }

    private func stripColor(_ i: Int) -> Color {
        if i < session.blockResults.count {
            return session.blockResults[i].completed ? .green : .orange.opacity(0.6)
        }
        if i == session.planBlockIndex && !session.planComplete {
            return session.isInPlanTransition ? .cyan : .orange
        }
        return Color.secondary.opacity(0.3)
    }

    private func targetChip(_ range: ClosedRange<Int>) -> some View {
        let bpm = bleManager.currentBPM
        let (text, color): (String, Color) = {
            if bpm <= 0 { return ("Target \(range.lowerBound)–\(range.upperBound)", .secondary) }
            if bpm < range.lowerBound { return ("Below target \(range.lowerBound)–\(range.upperBound)", .blue) }
            if bpm > range.upperBound { return ("Above target \(range.lowerBound)–\(range.upperBound)", .orange) }
            return ("On target \(range.lowerBound)–\(range.upperBound)", .green)
        }()
        return Label(text, systemImage: "heart.circle.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(color)
    }

    private func jumpShort(_ cm: Double) -> String {
        workoutStore.activeProfile.useImperial ? String(format: "%.0f in", cm / 2.54) : String(format: "%.0f cm", cm)
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Which plyo session the picker opens on.
struct PlyoChoice: Identifiable {
    let variant: PlyoVariant
    var id: String { variant.rawValue }
}


/// The bag coach's current call, one line on the fight clock page.
struct BagCallStrip: View {
    @ObservedObject var audio: AudioCoachEngine
    let isComplete: Bool

    var body: some View {
        let text: String = {
            if isComplete { return "Session complete" }
            if !audio.comboTokens.isEmpty { return audio.comboTokens.joined(separator: " · ") }
            return audio.bagStatus.isEmpty ? "Hands up" : audio.bagStatus.capitalized
        }()
        Text(text)
            .font(.system(.title2, design: .rounded).weight(.heavy))
            .foregroundStyle(audio.bagStatus.contains("REST") ? Color.cyan : Color.orange)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Coach: \(text)")
    }
}
