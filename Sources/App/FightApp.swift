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
            TabView(selection: $navigation.selectedTab) {
                LiveWorkoutView()
                    .tabItem { Label("Today", systemImage: "heart.fill") }
                    .tag(AppNavigation.Tab.live)

                CoachView()
                    .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(AppNavigation.Tab.coach)

                HistoryListView()
                    .tabItem { Label("History", systemImage: "list.bullet.clipboard") }
                    .tag(AppNavigation.Tab.history)

                ProfileSettingsView()
                    .tabItem { Label("You", systemImage: "person.crop.circle") }
                    .tag(AppNavigation.Tab.profile)
            }
            .modifier(FirstRunModifier())
            .undoHost(bottomInset: 56)
            .environmentObject(undo)
            .environmentObject(bleManager)
            .environmentObject(workoutStore)
            .environmentObject(healthKit)
            .environmentObject(navigation)
            .environment(session)
            .task {
                AppNavigation.shared = navigation
                LiveActivityActions.handler = { [weak s = session] action in
                    guard let s else { return }
                    if action == "endRound" { s.endWorkPhase(manual: true) }
                    if action == "skipRest" { s.skipRest() }
                }
                WeeklyNudge.install()
                session.bind(ble: bleManager, store: workoutStore, health: healthKit)
                workoutStore.refreshCoach()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    workoutStore.flushPendingSaves()
                    session.saveDraftNow()
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
            .preferredColorScheme(.dark)
        }
    }
}
