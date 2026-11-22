import AppIntents

// Siri and Shortcuts: hands-free control with gloves on.

@MainActor
private func liveSession() async -> WorkoutSession? {
    // When Siri launches the app, give it a moment to finish starting up.
    for _ in 0..<30 {
        if let s = WorkoutSession.shared, AppNavigation.shared != nil { return s }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return WorkoutSession.shared
}

struct StartWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Workout"
    static let description = IntentDescription("Starts recording a FIGHT workout with your current settings.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let session = await liveSession() else { return .result(dialog: "Open FIGHT once, then try again.") }
        AppNavigation.shared?.selectedTab = .corner
        guard !session.isRecording else { return .result(dialog: "You're already recording.") }
        session.begin()
        return .result(dialog: "Workout started. Fight well.")
    }
}

struct StartBagCoachIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Bag Coach"
    static let description = IntentDescription("Starts a bag-work session with called combinations.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let session = await liveSession() else { return .result(dialog: "Open FIGHT once, then try again.") }
        AppNavigation.shared?.selectedTab = .corner
        guard !session.isRecording else { return .result(dialog: "You're already recording.") }
        session.bagEnabled = true
        session.begin()
        return .result(dialog: "Bag coach starting. Hands up.")
    }
}

struct EndRoundIntent: AppIntent {
    static let title: LocalizedStringResource = "End Round"
    static let description = IntentDescription("Ends the current round and starts the rest period.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let session = WorkoutSession.shared, session.isRecording else {
            return .result(dialog: "No workout is running.")
        }
        guard session.roundTimerEnabled, !session.isRestPeriod else {
            return .result(dialog: "You're not in a round right now.")
        }
        session.endWorkPhase(manual: true)
        return .result(dialog: "Round over. Breathe.")
    }
}

struct FinishWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Workout"
    static let description = IntentDescription("Finishes and saves the workout in progress.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let session = WorkoutSession.shared, session.isRecording else {
            return .result(dialog: "No workout is running.")
        }
        session.finishAndSave()
        return .result(dialog: "Workout saved. Good work.")
    }
}

struct ReadinessCheckIntent: AppIntent {
    static let title: LocalizedStringResource = "Readiness Check"
    static let description = IntentDescription("Opens the 2-minute morning readiness check.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await liveSession()
        AppNavigation.shared?.selectedTab = .corner
        AppNavigation.shared?.requestReadinessCheck = true
        return .result()
    }
}

struct FightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWorkoutIntent(),
                    phrases: ["Start a workout in \(.applicationName)", "Start \(.applicationName) workout"],
                    shortTitle: "Start Workout", systemImageName: "heart.fill")
        AppShortcut(intent: StartBagCoachIntent(),
                    phrases: ["Start bag coach in \(.applicationName)", "Start \(.applicationName) bag work"],
                    shortTitle: "Bag Coach", systemImageName: "figure.boxing")
        AppShortcut(intent: EndRoundIntent(),
                    phrases: ["End round in \(.applicationName)", "\(.applicationName) end round"],
                    shortTitle: "End Round", systemImageName: "bell.fill")
        AppShortcut(intent: FinishWorkoutIntent(),
                    phrases: ["Finish \(.applicationName) workout", "Save my \(.applicationName) workout"],
                    shortTitle: "Finish Workout", systemImageName: "checkmark.circle.fill")
        AppShortcut(intent: ReadinessCheckIntent(),
                    phrases: ["\(.applicationName) readiness check", "Check my readiness in \(.applicationName)"],
                    shortTitle: "Readiness Check", systemImageName: "heart.text.square")
    }
}
