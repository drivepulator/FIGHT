import SwiftUI

/// Two-minute morning check: resting HR and (when the strap provides clean
/// beat-to-beat data) HRV, plus sleep and soreness self-ratings.
struct ReadinessCheckView: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var healthKit: HealthKitManager
    @State private var sleepHours: Double?
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case intro, measuring, questions, result }

    @State private var phase: Phase = .intro
    @State private var duration = 120
    @State private var elapsed = 0
    @State private var rrCollected: [Double] = []
    @State private var hrCollected: [Int] = []
    @State private var timer: Timer?
    @State private var sleepQuality = 3
    @State private var soreness = 2
    @State private var soreRegions: Set<BodyRegion> = []
    @State private var result: ReadinessReading?
    @State private var showingDeviceSheet = false
    @StateObject private var jumpTracker = HeadMotionTracker()
    @State private var testJumps: [Double] = []
    @State private var jumpTesting = false

    private let settleSeconds = 15

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch phase {
                    case .intro: intro
                    case .measuring: measuring
                    case .questions: questions
                    case .result: resultView
                    }
                }
                .padding()
            }
            .navigationTitle("Readiness Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .result ? "Done" : "Cancel") {
                        stopTimer()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingDeviceSheet) {
                DeviceScannerSheet()
                    .presentationDetents([.medium, .large])
            }
            .interactiveDismissDisabled(phase == .measuring)
            .onDisappear {
                stopTimer()
                stopJumpTest()
            }
        }
    }

    // MARK: Phases

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "heart.text.square.fill")
                .font(.largeTitle)
                .foregroundStyle(.pink)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Text("Measure how recovered you are")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                instruction("1.circle.fill", "Do it first thing in the morning, before coffee or training.")
                instruction("2.circle.fill", "Sit or lie still, in the same position every day.")
                instruction("3.circle.fill", "Breathe normally and don't talk for 2 minutes.")
            }

            Picker("Length", selection: $duration) {
                Text("1 min").tag(60)
                Text("2 min (recommended)").tag(120)
                Text("3 min").tag(180)
            }
            .pickerStyle(.segmented)

            if bleManager.isConnected {
                Label("\(bleManager.connectedDeviceName) connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                Button {
                    startMeasuring()
                } label: {
                    Text("Start Check")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.pink)
            } else {
                Label("Connect your heart rate monitor first", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                Button {
                    showingDeviceSheet = true
                } label: {
                    Text("Connect Sensor")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("HRV uses beat-to-beat data. Chest straps give the most accurate HRV. Armbands and watches work best while you're completely still. If the signal is too noisy, the check still records your resting heart rate.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func instruction(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.pink)
        }
        .font(.subheadline)
    }

    private var measuring: some View {
        let remaining = max(0, duration - elapsed)
        let progress = Double(elapsed) / Double(max(1, duration))
        return VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.pink.opacity(0.2), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.pink, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: elapsed)
                VStack(spacing: 4) {
                    Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                    Text(elapsed < settleSeconds ? "Settling…" : "Stay still")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(remaining) seconds remaining")

            HStack(spacing: 32) {
                stat("Heart Rate", bleManager.currentBPM > 0 ? "\(bleManager.currentBPM)" : "--", "BPM")
                stat("Beats Captured", "\(rrCollected.count)", rrCollected.isEmpty && elapsed > 20 ? "no RR data" : "RR")
            }

            if bleManager.sensorContactDetected == false {
                Label("Poor sensor contact — adjust the strap", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            }
            if !bleManager.isConnected {
                Label("Sensor disconnected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.red)
            }

            Button("Cancel Check", role: .cancel) {
                stopTimer()
                phase = .intro
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.bold)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Color.clear.frame(height: 0)
                .task {
                    guard sleepHours == nil, let h = await healthKit.lastNightSleepHours() else { return }
                    sleepHours = h
                    sleepQuality = SleepScore.quality(hours: h)
                }
            Text("How do you feel?")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sleep quality").font(.headline)
                    Spacer()
                    if let h = sleepHours {
                        Label(String(format: "%.1f h from Apple Health", h), systemImage: "bed.double.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.indigo)
                    }
                }
                Picker("Sleep quality", selection: $sleepQuality) {
                    Text("Awful").tag(1)
                    Text("Poor").tag(2)
                    Text("OK").tag(3)
                    Text("Good").tag(4)
                    Text("Great").tag(5)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Muscle soreness").font(.headline)
                Picker("Muscle soreness", selection: $soreness) {
                    Text("None").tag(1)
                    Text("Mild").tag(2)
                    Text("Some").tag(3)
                    Text("Sore").tag(4)
                    Text("Very").tag(5)
                }
                .pickerStyle(.segmented)
                if soreness >= 3 {
                    Text("Where? (optional)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    SorenessRegionPicker(selection: $soreRegions)
                }
            }

            if jumpTracker.isAvailable { jumpTest }

            Button {
                finish()
            } label: {
                Text("See Results")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.pink)
        }
    }

    // MARK: Jump test (AirPods)

    private var jumpTest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Jump test", systemImage: "airpodspro").font(.headline)
                Text("optional").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let best = testJumps.max() {
                    Text(jumpLabel(best)).font(.headline).monospacedDigit().foregroundStyle(.pink)
                }
            }
            if jumpTesting {
                Text(testJumps.count < 3 ? "Jump \(testJumps.count + 1) of 3. Hands on hips, jump as high as you can."
                                         : "Done.")
                    .font(.subheadline)
                ProgressView(value: Double(testJumps.count), total: 3).tint(.pink)
            } else {
                Text("Wear your AirPods, hands on hips, 3 max jumps. Tired legs show up here before you feel them.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(testJumps.isEmpty ? "Start Jump Test" : "Redo") { startJumpTest() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func jumpLabel(_ cm: Double) -> String {
        workoutStore.activeProfile.useImperial
            ? String(format: "%.0f in", cm / 2.54) : String(format: "%.0f cm", cm)
    }

    private func startJumpTest() {
        testJumps = []
        jumpTesting = true
        jumpTracker.onJump = { cm in
            guard testJumps.count < 3 else { return }
            testJumps.append(cm)
            if testJumps.count >= 3 { stopJumpTest() }
        }
        jumpTracker.start()
    }

    private func stopJumpTest() {
        jumpTracker.onJump = nil
        jumpTracker.stop()
        jumpTesting = false
    }

    /// Today's jump vs the fighter's usual (0.9 = 10% lower), nil without a baseline.
    static func jumpRatio(_ r: ReadinessReading, history: [ReadinessReading]) -> Double? {
        CoachEngine.jumpRatio(today: r, readings: history)
    }

    @ViewBuilder
    private var resultView: some View {
        if let r = result {
            let baseline = workoutStore.activeReadings.filter { $0.id != r.id }.prefix(14)
            let baseRHR = baseline.isEmpty ? nil : Double(baseline.map(\.restingHR).reduce(0, +)) / Double(baseline.count)
            let baseHRV = baseline.compactMap(\.hrvScore)
            let avgHRV = baseHRV.isEmpty ? nil : Double(baseHRV.reduce(0, +)) / Double(baseHRV.count)

            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Check saved").font(.title2.weight(.bold))

                HStack(spacing: 12) {
                    resultTile(
                        title: "Resting HR",
                        value: "\(r.restingHR)",
                        unit: "BPM",
                        comparison: baseRHR.map { String(format: "%+.0f vs usual", Double(r.restingHR) - $0) }
                    )
                    resultTile(
                        title: "HRV Score",
                        value: r.hrvScore.map(String.init) ?? "--",
                        unit: r.rmssd.map { String(format: "RMSSD %.0f ms", $0) } ?? "signal too noisy",
                        comparison: zip2(r.hrvScore, avgHRV).map { String(format: "%+.0f vs usual", Double($0.0) - $0.1) }
                    )
                }

                if let j = r.jumpCm {
                    let ratio = Self.jumpRatio(r, history: workoutStore.activeReadings)
                    resultTile(title: "Jump", value: jumpLabel(j).components(separatedBy: " ")[0],
                               unit: workoutStore.activeProfile.useImperial ? "in" : "cm",
                               comparison: ratio.map { String(format: "%+.0f%% vs usual", ($0 - 1) * 100) })
                }

                Text(interpretation(r, baseRHR: baseRHR, avgHRV: avgHRV))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if baseline.count < 3 {
                    Text("Your personal baseline builds after 3+ checks. Daily checks give the best trend.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func zip2(_ a: Int?, _ b: Double?) -> (Int, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    private func resultTile(title: String, value: String, unit: String, comparison: String?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.largeTitle, design: .rounded).weight(.heavy)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
            if let comparison {
                Text(comparison).font(.caption.weight(.semibold)).foregroundStyle(.pink)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func interpretation(_ r: ReadinessReading, baseRHR: Double?, avgHRV: Double?) -> String {
        var flags = 0
        if let b = baseRHR, Double(r.restingHR) - b >= 5 { flags += 1 }
        if let h = r.hrvScore, let a = avgHRV, Double(h) - a <= -6 { flags += 1 }
        if r.sleepQuality <= 2 { flags += 1 }
        if r.soreness >= 4 { flags += 1 }
        let legsTired = (Self.jumpRatio(r, history: workoutStore.activeReadings) ?? 1) < 0.9
        if legsTired { flags += 1 }
        if flags == 1 && legsTired { return "Legs are tired today. Train, but skip plyos and keep the footwork light." }
        return generalInterpretation(flags) + (legsTired ? " Your jump is down too: skip plyos today." : "")
    }

    private func generalInterpretation(_ flags: Int) -> String {
        switch flags {
        case 0: return "You look recovered. Check the Coach tab for today's session."
        case 1: return "One warning sign today. Train, but keep an eye on how you feel during warm-up."
        default: return "Several signs of fatigue. Favour technique or an easy session today."
        }
    }

    // MARK: Measurement

    private func startMeasuring() {
        _ = bleManager.consumeLatestRRIntervals()
        rrCollected = []
        hrCollected = []
        elapsed = 0
        phase = .measuring
        UIApplication.shared.isIdleTimerDisabled = true

        let t = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard phase == .measuring else { return }
        elapsed += 1
        let rr = bleManager.consumeLatestRRIntervals()
        if elapsed > settleSeconds {
            rrCollected.append(contentsOf: rr)
            if bleManager.currentBPM > 0 { hrCollected.append(bleManager.currentBPM) }
        }
        if elapsed >= duration {
            stopTimer()
            phase = .questions
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func finish() {
        let quality = HRVMath.cleanRR(rrCollected)
        let rmssd = quality.isUsableForHRV ? HRVMath.rmssd(quality.cleanRR) : nil
        let rhr: Int
        if quality.isUsableForHRV, let hr = HRVMath.meanHR(fromRR: quality.cleanRR) {
            rhr = Int(hr.rounded())
        } else if !hrCollected.isEmpty {
            rhr = Int((Double(hrCollected.reduce(0, +)) / Double(hrCollected.count)).rounded())
        } else {
            rhr = bleManager.currentBPM
        }
        var reading = ReadinessReading(
            durationSeconds: duration,
            restingHR: rhr,
            rmssd: rmssd,
            artifactRate: rrCollected.isEmpty ? nil : quality.artifactRate,
            sleepQuality: sleepQuality,
            soreness: soreness
        )
        reading.sleepHours = sleepHours
        reading.jumpCm = testJumps.max()
        stopJumpTest()
        workoutStore.addReadiness(reading)
        if soreness >= 3 {
            let severity = soreness >= 5 ? 3 : 2
            workoutStore.addSoreness(soreRegions.map {
                SorenessEntry(profileID: workoutStore.activeProfileID, region: $0, severity: severity)
            })
        }
        result = reading
        phase = .result
    }
}
