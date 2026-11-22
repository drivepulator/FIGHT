import SwiftUI

// MARK: - Today: three doors and a ready card

/// What's left to do after a door's sheet closes (these open their own screens).
enum ChooserFollowUp { case plyo, mix }

/// Fight · Roadwork · Conditioning, then "Go again" with one Start button.
struct StartWorkoutSection: View {
    @Environment(WorkoutSession.self) var session
    @EnvironmentObject var bleManager: BLEHeartRateManager
    let onPick: (MainChoice) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(MainChoice.allCases) { door in
                Button { onPick(door) } label: { DoorTile(door: door) }
                    .buttonStyle(.plain)
            }
            ReadyCard()
            if !bleManager.isConnected {
                Text("No heart-rate strap connected. You can still train; heart rate just won't be recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The red button's sheet: go again in one tap, or pick a door.
struct StartSheet: View {
    @Environment(WorkoutSession.self) var session
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (MainChoice) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !workoutStore.workouts.isEmpty || session.queuedPlan != nil || session.activePlan != nil {
                        ReadyCard(onStarted: { dismiss() })
                    }
                    ForEach(MainChoice.allCases) { door in
                        Button {
                            onPick(door)
                            dismiss()
                        } label: {
                            DoorTile(door: door)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink {
                        PlanLibraryView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("My plans").font(.headline)
                                Text(workoutStore.plans.isEmpty ? "Build one, or scan your coach's QR" : "\(workoutStore.plans.count) saved · templates · import")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !bleManager.isConnected {
                        Text("No heart-rate strap connected. You can still train; heart rate just won't be recorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
                .padding()
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct DoorTile: View {
    let door: MainChoice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: door.icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(door.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(door.rawValue).font(.title3.weight(.bold))
                Text(door.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.headline).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

extension MainChoice {
    var tint: Color {
        switch self {
        case .fight: return .red
        case .roadwork: return .green
        case .conditioning: return .orange
        }
    }
}

/// The workout that Start will run: last time's, the coach's pick, or a loaded plan.
struct ReadyCard: View {
    @Environment(WorkoutSession.self) var session
    @State private var preparingVoice = false
    /// Called once the session has started (the Start sheet closes itself).
    var onStarted: () -> Void = {}

    private var header: String {
        if session.queuedPlan != nil { return "Plan ready" }
        if session.activePlan != nil { return "Coach's pick" }
        return "Same as last time"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(header).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(session.setupSummary).font(.headline).lineLimit(2)
            }
            Spacer()
            if session.queuedPlan != nil || session.activePlan != nil {
                Button {
                    session.unqueuePlan()
                    session.activePlan = nil
                    session.restoreLastSetup()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
            Button {
                guard session.bagEnabled else {
                    session.begin()
                    onStarted()
                    return
                }
                preparingVoice = true
                Task {
                    await session.audio.prepareVocabulary(prefs: session.bagPrefs)
                    preparingVoice = false
                    session.begin()
                    onStarted()
                }
            } label: {
                Group {
                    if preparingVoice {
                        ProgressView().tint(.white)
                    } else {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.red)
            .controlSize(.large)
            .disabled(preparingVoice)
            .accessibilityLabel(preparingVoice ? "Preparing the coach's voice" : "Start")
        }
        .card()
    }
}

// MARK: - Behind each door

struct ChooserSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    let main: MainChoice
    let onFollowUp: (ChooserFollowUp) -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(main.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
        }
    }

    private var finish: () -> Void { { dismiss() } }

    @ViewBuilder
    private var content: some View {
        let profile = workoutStore.activeProfile
        switch main {
        case .fight:
            let sports = WorkoutMenu.sports(profile)
            if sports.count == 1, let only = sports.first {
                ActivityList(title: only, options: WorkoutMenu.fight(sport: only, format: profile.fightFormat), finish: finish)
            } else {
                ChoiceList {
                    Text("Which sport?").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(sports, id: \.self) { sport in
                        NavigationLink {
                            ActivityList(title: sport, options: WorkoutMenu.fight(sport: sport, format: profile.fightFormat), finish: finish)
                        } label: {
                            BigRow(icon: WorkoutMenu.category(forSport: sport).icon, title: sport, subtitle: nil, tint: .red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .roadwork:
            ActivityList(title: nil, options: WorkoutMenu.roadwork, finish: finish)
        case .conditioning:
            ConditioningList(finish: finish) { follow in
                onFollowUp(follow)
                dismiss()
            }
        }
    }
}

/// A scrolling column of big rows.
private struct ChoiceList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: 10) { content }
                .padding()
        }
    }
}

private struct BigRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minHeight: 56)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct ActivityList: View {
    let title: String?
    let options: [ActivityOption]
    let finish: () -> Void

    var body: some View {
        ChoiceList {
            Text("What are you doing?").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(options) { option in
                NavigationLink {
                    ReadyView(option: option, finish: finish)
                } label: {
                    BigRow(icon: option.icon, title: option.title, subtitle: option.subtitle, tint: option.category.isRun ? .green : .red)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(title ?? "")
    }
}

private struct ConditioningList: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    let finish: () -> Void
    let followUp: (ChooserFollowUp) -> Void

    var body: some View {
        ChoiceList {
            Text("What are you doing?").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            Button { followUp(.plyo) } label: {
                BigRow(icon: "figure.jumprope", title: "Plyo", subtitle: "Jumps and throws for explosive power", tint: .orange)
            }
            .buttonStyle(.plain)
            NavigationLink { ReadyView(option: WorkoutMenu.jumpRope, finish: finish) } label: {
                BigRow(icon: WorkoutMenu.jumpRope.icon, title: "Jump rope", subtitle: WorkoutMenu.jumpRope.subtitle, tint: .orange)
            }
            .buttonStyle(.plain)
            NavigationLink { ReadyView(option: WorkoutMenu.circuit, finish: finish) } label: {
                BigRow(icon: WorkoutMenu.circuit.icon, title: "Circuit", subtitle: WorkoutMenu.circuit.subtitle, tint: .orange)
            }
            .buttonStyle(.plain)
            Button { followUp(.mix) } label: {
                BigRow(icon: "square.stack.3d.up.fill", title: "Mix", subtitle: "Build one session: rope, bag, plyo, run…", tint: .orange)
            }
            .buttonStyle(.plain)
            NavigationLink { PlanChooser(finish: finish) } label: {
                BigRow(icon: "list.bullet.rectangle", title: "Plans", subtitle: workoutStore.plans.isEmpty ? "Ready-made sessions" : "Yours and ready-made sessions", tint: .orange)
            }
            .buttonStyle(.plain)
            NavigationLink { ReadyView(option: WorkoutMenu.fitnessTest, finish: finish) } label: {
                BigRow(icon: WorkoutMenu.fitnessTest.icon, title: "Fitness test", subtitle: WorkoutMenu.fitnessTest.subtitle, tint: .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PlanChooser: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation
    let finish: () -> Void

    var body: some View {
        ChoiceList {
            if !workoutStore.plans.isEmpty {
                Text("Your plans").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(workoutStore.plans) { row($0) }
            }
            Text("Ready-made").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            ForEach(PlanTemplates.all) { row($0) }
        }
        .navigationTitle("Plans")
    }

    private func row(_ plan: TrainingPlan) -> some View {
        Button {
            navigation.startPlanNow = true
            navigation.run(plan)
            finish()
        } label: {
            BigRow(icon: "play.circle.fill", title: plan.title, subtitle: "\(plan.blocks.count) parts · about \(plan.plannedSeconds / 60) min", tint: .orange)
        }
        .buttonStyle(.plain)
    }
}

/// Last step: how long (if it has rounds), what will happen, Start.
private struct ReadyView: View {
    @Environment(WorkoutSession.self) var session
    let option: ActivityOption
    let finish: () -> Void
    @State private var length: LengthOption?
    @State private var showingBagSettings = false
    @State private var preparingVoice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    if let sport = option.sport {
                        Text(sport).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(option.title).font(.largeTitle.weight(.bold))
                    Text(option.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if !option.lengths.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How long?").font(.headline)
                        ForEach(option.lengths) { l in
                            Button { length = l } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(l.title).font(.headline)
                                        Text(l.detail).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: length == l ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(length == l ? Theme.red : Color.secondary)
                                }
                                .padding(12)
                                .background(length == l ? Theme.red.opacity(0.12) : Theme.card,
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(option.checklist, id: \.self) { line in
                        Label(line, systemImage: "checkmark").font(.subheadline)
                    }
                }
                .foregroundStyle(.secondary)
                Button {
                    session.choose(option, length: length)
                    guard option.bagCoach else {
                        session.begin()
                        finish()
                        return
                    }
                    // The coach's voice has to be ready before the first combo (first time, or after
                    // changing stance or voice). Usually instant: lines are saved on the phone.
                    preparingVoice = true
                    Task {
                        await session.audio.prepareVocabulary(prefs: session.bagPrefs)
                        preparingVoice = false
                        session.begin()
                        finish()
                    }
                } label: {
                    Group {
                        if preparingVoice {
                            HStack(spacing: 10) {
                                ProgressView().tint(.white)
                                Text("Preparing the coach's voice…")
                            }
                        } else {
                            Label("Start", systemImage: "play.fill")
                        }
                    }
                }
                .buttonStyle(FightPrimaryButtonStyle())
                .disabled(preparingVoice)
                if option.bagCoach {
                    Button("Adjust stance, level and combos") { showingBagSettings = true }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .onAppear { if length == nil { length = option.lengths.first } }
        .sheet(isPresented: $showingBagSettings) {
            BagSettingsSheet(prefs: Bindable(session).bagPrefs)
        }
    }
}
