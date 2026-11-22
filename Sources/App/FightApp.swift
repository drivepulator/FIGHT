import SwiftUI

@main
struct FightApp: App {
    @StateObject private var bleManager = BLEHeartRateManager()
    @StateObject private var workoutStore = WorkoutStore()
    @StateObject private var healthKit = HealthKitManager()
    @StateObject private var navigation = AppNavigation()
    @State private var session = WorkoutSession()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var undo = UndoCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.red)
            .modifier(FirstRunModifier())
            .undoHost(bottomInset: 84)
            .environmentObject(undo)
            .environmentObject(bleManager)
            .environmentObject(workoutStore)
            .environmentObject(healthKit)
            .environmentObject(navigation)
            .environment(session)
            .task {
                AppNavigation.shared = navigation
                LiveActivityActions.handler = { [weak s = session] action in
                    guard let s, !s.isPaused else { return }
                    if action == "endRound" { s.endWorkPhase(manual: true) }
                    if action == "skipRest" { s.skipRest() }
                }
                WeeklyNudge.install()
                session.bind(ble: bleManager, store: workoutStore, health: healthKit)
                workoutStore.refreshCoach()
                if !session.isRecording { WorkoutSession.endLeftoverActivities() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    workoutStore.flushPendingSaves()
                    // Leaving the app: don't risk losing the Health copy.
                    if phase == .background { session.flushPendingHealthSave() }
                }
            }
            .onOpenURL { url in
                navigation.handleOpenURL(url)
            }
            .sheet(item: $navigation.incomingPlan) { plan in
                PlanImportSheet(plan: plan)
                    .environmentObject(workoutStore)
                    .environmentObject(navigation)
            }
            .sheet(item: $navigation.incomingResult) { result in
                ResultViewerSheet(result: result)
            }
            .alert("Couldn't open plan", isPresented: Binding(
                get: { navigation.importError != nil },
                set: { if !$0 { navigation.importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(navigation.importError ?? "")
            }
            .alert("Some data couldn't be read", isPresented: Binding(
                get: { !workoutStore.storageWarnings.isEmpty },
                set: { if !$0 { workoutStore.storageWarnings.removeAll() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(workoutStore.storageWarnings.joined(separator: "\n\n"))
            }
            .modifier(RespectsReduceMotion())
            .preferredColorScheme(.dark)
        }
    }
}
