import SwiftUI
import AVFoundation

/// One reaction-drill result.
struct DrillResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var averageMs: Int
    var accuracy: Int?
    var calls: Int
}

enum DrillHistory {
    private static func key(_ id: UUID) -> String { "fight.drill.\(id.uuidString)" }

    static func load(_ profileID: UUID) -> [DrillResult] {
        guard let d = UserDefaults.standard.data(forKey: key(profileID)),
              let list = try? JSONDecoder().decode([DrillResult].self, from: d) else { return [] }
        return list
    }

    static func add(_ r: DrillResult, profileID: UUID) {
        var list = load(profileID)
        list.append(r)
        if list.count > 60 { list.removeFirst(list.count - 60) }
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key(profileID)) }
    }
}

/// Slip-and-roll reaction drill: the coach calls a defence, AirPods time how fast you move
/// and check you slipped the right way.
@MainActor
final class ReactionDrillModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable { case ready, calibrating(String), drilling, done }

    @Published var phase: Phase = .ready
    @Published var currentCall = ""
    @Published var lastReactionMs: Int?
    @Published var lastCorrect: Bool?
    @Published var reactions: [Int] = []
    @Published var slipChecks: [Bool] = []
    @Published var airPodsMissing = false

    let totalCalls = 16
    private let tracker = HeadMotionTracker()
    private let voice = AVSpeechSynthesizer()
    private var calledAt: TimeInterval?
    private var callName = ""
    private var rollAtCall: Double = 0
    private var onsetAt: TimeInterval?
    private var maxRollDelta: Double = 0
    private var latestRoll: Double = 0
    private var leftSign: Double?
    private var calibrationStep = 0
    private var callsMade = 0
    private var task: Task<Void, Never>?
    private static let calls = ["Slip left", "Slip right", "Roll left", "Roll right", "Pull back"]

    override init() {
        super.init()
        voice.delegate = self
    }

    var averageMs: Int? { reactions.isEmpty ? nil : reactions.reduce(0, +) / reactions.count }
    var accuracy: Int? { slipChecks.isEmpty ? nil : slipChecks.filter { $0 }.count * 100 / slipChecks.count }

    func start() {
        reactions = []
        slipChecks = []
        lastReactionMs = nil
        lastCorrect = nil
        callsMade = 0
        calibrationStep = 0
        leftSign = nil
        tracker.onSample = { [weak self] ts, rx, ry, rz, roll, _ in
            self?.sample(ts: ts, magnitude: (rx * rx + ry * ry + rz * rz).squareRoot(), roll: roll)
        }
        tracker.start()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.tracker.isReceiving {
                self.airPodsMissing = true
                self.stop()
                return
            }
            self.phase = .calibrating("Slip left")
            self.call("Slip left")
        }
    }

    func stop() {
        task?.cancel()
        voice.stopSpeaking(at: .immediate)
        tracker.onSample = nil
        tracker.stop()
        if phase != .done { phase = airPodsMissing ? .ready : phase }
    }

    private func call(_ name: String) {
        callName = name
        currentCall = name
        calledAt = nil
        onsetAt = nil
        maxRollDelta = 0
        let u = AVSpeechUtterance(string: name)
        u.rate = 0.58
        voice.speak(u)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            self.calledAt = now
            self.rollAtCall = self.latestRoll
            self.scheduleTimeout()
        }
    }

    private func scheduleTimeout() {
        let expected = callName
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, !Task.isCancelled, self.callName == expected, self.onsetAt == nil, self.calledAt != nil else { return }
            self.lastReactionMs = nil
            self.lastCorrect = false
            self.finishCall(reaction: nil)
        }
    }

    private func sample(ts: TimeInterval, magnitude: Double, roll: Double) {
        latestRoll = roll
        guard let t0 = calledAt else { return }
        if onsetAt == nil, magnitude > 1.5, ts > t0 {
            onsetAt = ts
        }
        if let onset = onsetAt {
            let d = roll - rollAtCall
            if abs(d) > abs(maxRollDelta) { maxRollDelta = d }
            if ts - onset >= 0.4 {
                let ms = Int(((onset - t0) * 1000).rounded())
                finishCall(reaction: ms)
            }
        }
    }

    private func finishCall(reaction ms: Int?) {
        let name = callName
        calledAt = nil
        onsetAt = nil
        switch phase {
        case .calibrating:
            if calibrationStep == 0 {
                if abs(maxRollDelta) > 0.08 { leftSign = maxRollDelta > 0 ? 1 : -1 }
                calibrationStep = 1
                phase = .calibrating("Slip right")
                nextCall(after: 1.2) { $0.call("Slip right") }
            } else {
                phase = .drilling
                nextCall(after: 1.5) { $0.randomCall() }
            }
        case .drilling:
            callsMade += 1
            if let ms {
                reactions.append(ms)
                lastReactionMs = ms
                var correct = true
                if name.hasPrefix("Slip"), let left = leftSign, abs(maxRollDelta) > 0.05 {
                    let movedLeft = (maxRollDelta > 0 ? 1.0 : -1.0) == left
                    correct = movedLeft == (name == "Slip left")
                    slipChecks.append(correct)
                }
                lastCorrect = correct
            }
            if callsMade >= totalCalls {
                complete()
            } else {
                nextCall(after: 1.0 + Double.random(in: 0...1.5)) { $0.randomCall() }
            }
        default:
            break
        }
    }

    private func nextCall(after seconds: Double, _ action: @escaping @MainActor (ReactionDrillModel) -> Void) {
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            action(self)
        }
    }

    private func randomCall() {
        var next = Self.calls.randomElement() ?? "Slip left"
        if next == callName { next = Self.calls.randomElement() ?? next }
        call(next)
    }

    private func complete() {
        phase = .done
        currentCall = ""
        tracker.onSample = nil
        tracker.stop()
    }
}

struct ReactionDrillView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ReactionDrillModel()
    @State private var history: [DrillResult] = []
    @State private var saved = false
    @ScaledMetric private var resultFontSize: CGFloat = 56

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    main
                    if !history.isEmpty { historyCard }
                }
                .padding()
            }
            .navigationTitle("Reaction Drill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { model.stop(); dismiss() } }
            }
            .onAppear { history = DrillHistory.load(workoutStore.activeProfileID) }
            .onDisappear { model.stop() }
            .onChange(of: model.phase) { _, phase in
                guard phase == .done, !saved, let avg = model.averageMs else { return }
                saved = true
                DrillHistory.add(DrillResult(averageMs: avg, accuracy: model.accuracy, calls: model.reactions.count),
                                 profileID: workoutStore.activeProfileID)
                history = DrillHistory.load(workoutStore.activeProfileID)
            }
        }
    }

    @ViewBuilder
    private var main: some View {
        switch model.phase {
        case .ready:
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "airpodspro").font(.largeTitle).foregroundStyle(.teal).frame(maxWidth: .infinity)
                Text("How fast is your defence?").font(.title2.weight(.bold))
                Text("Put your AirPods in and stand in your stance. The coach calls slips, rolls and pulls. Move as fast as you can. Your AirPods time every reaction.")
                    .foregroundStyle(.secondary)
                if model.airPodsMissing {
                    Label("No AirPods motion found. This needs AirPods Pro, AirPods (3rd gen or later) or AirPods Max.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                }
                Button {
                    saved = false
                    model.airPodsMissing = false
                    model.start()
                    model.phase = .calibrating("Get ready")
                } label: {
                    Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
            }
        case .calibrating(let text):
            bigCall(text, sub: "Warm-up: this teaches FIGHT which way is left")
        case .drilling:
            VStack(spacing: 12) {
                bigCall(model.currentCall, sub: "\(model.reactions.count) / \(model.totalCalls)")
                if let ms = model.lastReactionMs {
                    Text("\(ms) ms").font(.title.weight(.bold)).monospacedDigit()
                        .foregroundStyle(model.lastCorrect == false ? .orange : .green)
                }
                Button("Stop", role: .cancel) { model.stop(); model.phase = .ready }.buttonStyle(.bordered)
            }
        case .done:
            VStack(spacing: 10) {
                Text("Average reaction").font(.headline).foregroundStyle(.secondary)
                Text(model.averageMs.map { "\($0) ms" } ?? "--").font(.system(size: resultFontSize, weight: .heavy)).monospacedDigit()
                if let a = model.accuracy { Text("Slips the right way: \(a)%").font(.headline) }
                if let best = history.dropLast().map(\.averageMs).min(), let avg = model.averageMs {
                    Text(avg < best ? "New best! Previous best \(best) ms." : "Your best: \(best) ms")
                        .foregroundStyle(avg < best ? .green : .secondary)
                }
                Button {
                    saved = false
                    model.start()
                    model.phase = .calibrating("Get ready")
                } label: {
                    Text("Go Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.teal).padding(.top, 8)
            }
            .card()
        }
    }

    private func bigCall(_ text: String, sub: String) -> some View {
        VStack(spacing: 8) {
            Text(text.uppercased()).font(.system(size: 44, weight: .heavy).width(.condensed))
                .multilineTextAlignment(.center)
            Text(sub).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .card(tint: .teal)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your drills").font(.headline)
            ForEach(history.suffix(6).reversed()) { r in
                HStack {
                    Text(r.date, format: .dateTime.day().month())
                    Spacer()
                    if let a = r.accuracy { Text("\(a)%").foregroundStyle(.secondary) }
                    Text("\(r.averageMs) ms").font(.body.weight(.semibold)).monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .card()
    }
}
