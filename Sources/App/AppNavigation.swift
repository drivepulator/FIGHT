import SwiftUI

/// Shared navigation state so the Coach tab can hand a planned workout to the Live tab.
@MainActor
final class AppNavigation: ObservableObject {
    enum Tab: Hashable {
        case corner, record
    }
    enum RecordSegment: Hashable {
        case sessions, trends
    }

    /// The app's navigation, for Siri and Shortcuts.
    static weak var shared: AppNavigation?
    /// A plyo session the coach picked; the Today tab opens the plyo sheet with it.
    @Published var plyoToPick: PlyoVariant?

    @Published var selectedTab: Tab = .corner
    /// Sessions or Trends, on the Record tab.
    @Published var recordSegment: RecordSegment = .sessions
    /// The Start sheet (the red button).
    @Published var showingStart = false
    /// You: profile and settings, opened from the avatar.
    @Published var showingYou = false
    /// Set by the "Readiness check" shortcut; the Coach tab opens the check.
    @Published var requestReadinessCheck = false
    /// Set by "Run setup again" in You.
    @Published var requestSetup = false
    /// A story card to open on the Progress tab (from the weekly notification).
    @Published var storyToOpen: StoryCardKind?
    @Published var pendingPrescription: WorkoutPrescription?

    /// A plan opened from a file, link or QR code, waiting for the import preview.
    @Published var incomingPlan: TrainingPlan?
    /// A fighter's session result opened from a `.fightresult` file.
    @Published var incomingResult: SessionResultPackage?
    @Published var importError: String?
    /// A plan the fighter chose to run; picked up by the Live tab.
    @Published var planToRun: TrainingPlan?
    /// Start the plan right away (chosen from a picker) instead of just loading it.
    var startPlanNow = false

    func run(_ plan: TrainingPlan) {
        planToRun = plan
        showingYou = false
        selectedTab = .corner
    }

    /// Handles `fight://plan?d=…` links and opened `.fightplan` / `.fightresult` files.
    func handleOpenURL(_ url: URL) {
        do {
            if url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Check the size before reading: a plan is a few KB.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= PlanTransfer.maxPlanBytes * 4 else { throw PlanTransfer.TransferError.tooLarge }
                let data = try Data(contentsOf: url)
                if url.pathExtension.lowercased() == PlanTransfer.resultExtension {
                    incomingResult = try PlanTransfer.result(from: data)
                } else {
                    incomingPlan = try PlanTransfer.plan(from: data)
                }
            } else {
                incomingPlan = try PlanTransfer.plan(fromLink: url)
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    func load(_ prescription: WorkoutPrescription) {
        if let v = prescription.plyo {
            // Plyos open the picker first so the fighter can tick off the gear they brought.
            plyoToPick = v
            selectedTab = .corner
            return
        }
        pendingPrescription = prescription
        selectedTab = .corner
    }
}
