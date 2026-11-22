import SwiftUI
import Charts

struct WorkoutDetailView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var healthKit: HealthKitManager
    let workout: SavedWorkout
    @State private var isSavingToHealth = false
    @State private var storyFocus: StoryCardKind?
    @State private var exportURL: URL?

    @State private var selectedElapsed: Double?
    @State private var loadedSamples: [HeartRatePoint] = []
    @State private var showRollingTrend = true
    @State private var showingComparison = false

    /// Thinned once when the session loads (not on every redraw or drag).
    @State private var chartSamples: [HeartRatePoint] = []
    @State private var rollingTrendSamples: [HeartRatePoint] = []

    /// Keeps the shape of the curve with ~360 points: each bucket keeps its lowest and highest
    /// reading (in time order), so peaks and stool drops never vanish like they can with every-Nth thinning.
    static func thin(_ samples: [HeartRatePoint], target: Int = 360) -> [HeartRatePoint] {
        guard samples.count > target else { return samples }
        let bucket = max(1, Int((Double(samples.count) / Double(target / 2)).rounded(.up)))
        var out: [HeartRatePoint] = []
        out.reserveCapacity(target + 2)
        var i = 0
        while i < samples.count {
            let slice = samples[i..<min(samples.count, i + bucket)]
            if let lo = slice.indices.min(by: { samples[$0].bpm < samples[$1].bpm }),
               let hi = slice.indices.max(by: { samples[$0].bpm < samples[$1].bpm }) {
                if lo == hi {
                    out.append(samples[lo])
                } else {
                    out.append(samples[min(lo, hi)])
                    out.append(samples[max(lo, hi)])
                }
            }
            i += bucket
        }
        return out
    }

    static func trend(_ pts: [HeartRatePoint]) -> [HeartRatePoint] {
        guard pts.count >= 8 else { return [] }
        let window = 6
        var prefix = [0]
        for p in pts { prefix.append(prefix.last! + p.bpm) }
        return pts.indices.map { i in
            let lo = max(0, i - window), hi = min(pts.count - 1, i + window)
            let avg = (prefix[hi + 1] - prefix[lo]) / (hi - lo + 1)
            return HeartRatePoint(timestamp: pts[i].timestamp, elapsedSeconds: pts[i].elapsedSeconds, bpm: avg)
        }
    }

    private var selectedSample: HeartRatePoint? {
        guard let target = selectedElapsed else { return nil }
        return chartSamples.min(by: { abs($0.elapsedSeconds - target) < abs($1.elapsedSeconds - target) })
    }

    private func headMovementCard(_ perMinute: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Head Movement", systemImage: "airpodspro")
                .font(.title3.weight(.bold))
            Text(String(format: "%.0f movements per minute of work", perMinute))
                .font(.subheadline.weight(.semibold))
            let rounds = workout.roundStats.filter { $0.headMoves != nil }
            if !rounds.isEmpty {
                Chart(rounds) { r in
                    BarMark(x: .value("Round", "R\(r.roundNumber)"), y: .value("Moves", r.headMoves ?? 0))
                        .foregroundStyle(.teal.gradient)
                }
                .frame(height: 120)
            }
            let chin = workout.roundStats.compactMap(\.chinUpSeconds).reduce(0, +)
            let bounces = workout.roundStats.compactMap(\.bounces).reduce(0, +)
            if chin > 0 || bounces > 0 {
                Text("Chin up: \(chin) s · Footwork bounces: \(bounces)")
                    .font(.footnote.weight(.semibold))
            }
            Text("Slips, rolls and pulls counted by your AirPods. If it drops in later rounds, you're getting tired and standing still in front of your opponent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                let newRecords = Records.newRecords(in: workout, workouts: workoutStore.workouts,
                                                    profile: workoutStore.profile(for: workout))
                if !newRecords.isEmpty {
                    NewRecordsBanner(records: newRecords) { storyFocus = .record }
                }
                Group {
                ScorecardHeader(workout: workout) {
                    storyFocus = workout.run?.hasRoute == true ? .route : (workout.hasHeartRate ? .mainEvent : .profile)
                }
                if workout.recoveredFromLogger > 0 {
                    Label("\(workout.recoveredFromLogger / 60) min \(workout.recoveredFromLogger % 60) s of real heart rate recovered from your FIGHT Logger",
                          systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !workout.estimatedSamples.isEmpty {
                    EstimatedHeartRateCard(workout: workout, realSamples: chartSamples)
                }
                if !workout.notes.isEmpty {
                    Text("\"\(workout.notes)\"")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                }
                if let run = workout.run {
                    RunSummarySection(workout: workout, run: run).card()
                }
                if workout.roundsAutoDetected {
                    Label("\(workout.roundStats.count) rounds found automatically from your heart rate", systemImage: "wand.and.stars")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SessionRatingCard(workoutID: workout.id)
                SessionTagsCard(workoutID: workout.id)
                if !workout.blockResults.isEmpty {
                    PlanResultsCard(workoutID: workout.id)
                }
                let review = CoachEngine.review(
                    workout: workoutStore.workouts.first(where: { $0.id == workout.id }) ?? workout,
                    profile: workoutStore.profile(for: workout),
                    history: workoutStore.workouts
                )
                CoachReviewCard(review: review, showItems: false)
                if workout.hasHeartRate {
                    interactiveChartCard
                }

                AdvancedSection("Full analysis", subtitle: "Review breakdown, zones, rounds, calories, key moments, metrics", key: "workout.details") {
                    if !review.items.isEmpty {
                        CoachReviewCard(review: review, showItems: true, showTakeaways: false)
                    }
                    if workout.hasHeartRate {
                        zoneBreakdownCard
                    }
                    if workout.roundStats.count >= 2 {
                        roundDecayChartCard
                    }
                    if workout.hasHeartRate && !workout.pointsOfInterest.isEmpty {
                        poiSection
                    }
                    if !workout.autoHRREvents.isEmpty {
                        autoHRRSection
                    }
                    if let cost = ComboCost.analyze(workouts: [workout], stance: workoutStore.profile(for: workout).bagPreferences.stance,
                                                    resolveSamples: { _ in loadedSamples }) {
                        ComboCostCard(result: cost)
                    }
                    if let hm = workout.headMovesPerMinute {
                        headMovementCard(hm)
                    }
                    if let hits = workout.impactsCount, hits > 0 {
                        Label(workout.strikesCuedCount > 0 ? "Bag hits heard: \(hits) (\(workout.strikesCuedCount) strikes called)" : "Bag hits heard: \(hits)",
                              systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .card()
                    }
                    calorieBreakdownCard
                    if workout.hasHeartRate {
                        advancedMetricsGrid
                    }
                }
            }
            .padding()
        }
        .sheet(item: $storyFocus) { kind in StoryShareSheet(focus: kind, workout: workout) }
        .navigationTitle(workout.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // One clear menu instead of four look-alike icons.
                Menu {
                    Button {
                        storyFocus = workout.run?.hasRoute == true ? .route : (workout.hasHeartRate ? .mainEvent : .profile)
                    } label: {
                        Label("Share to your story", systemImage: "camera.fill")
                    }
                    if healthKit.isAvailable {
                        Button {
                            saveToHealth()
                        } label: {
                            Label(healthKit.isSaved(workout) ? "Saved to Apple Health" : "Save to Apple Health",
                                  systemImage: healthKit.isSaved(workout) ? "checkmark.circle.fill" : "heart.text.square")
                        }
                        .disabled(healthKit.isSaved(workout) || isSavingToHealth)
                    }
                    Button {
                        showingComparison = true
                    } label: {
                        Label("Compare with another session", systemImage: "square.stack.3d.up")
                    }
                    Button {
                        exportURL = workoutStore.exportTCXFile(for: workout)
                    } label: {
                        Label("Export TCX file", systemImage: "doc")
                    }
                } label: {
                    if isSavingToHealth {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .accessibilityLabel("Share and export")
            }
        }
        .sheet(item: Binding(
            get: { exportURL.map(ShareableFile.init) },
            set: { if $0 == nil { exportURL = nil } }
        )) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(isPresented: $showingComparison) {
            ComparisonView(initialBaselineWorkout: workout)
        }
        .onAppear {
            loadedSamples = workoutStore.resolvedSamples(for: workout)
            chartSamples = Self.thin(loadedSamples)
            rollingTrendSamples = Self.trend(chartSamples)
        }
    }

    private func saveToHealth() {
        guard !healthKit.isSaved(workout), !isSavingToHealth else { return }
        isSavingToHealth = true
        let samplesForHealth = loadedSamples
        let route = workout.run != nil ? workoutStore.loadRoute(for: workout.id) : []
        Task {
            await healthKit.save(workout: workout, samples: samplesForHealth, route: route)
            isSavingToHealth = false
        }
    }

    private var headerSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: workout.category.icon)
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.startDate.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(workout.drillTag.label(for: workout.category))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }

            if !workout.notes.isEmpty {
                Text("\"\(workout.notes)\"")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
            }

            Divider()

            if workout.hasHeartRate {
                HStack {
                    statBox(title: "DURATION", value: formatDuration(workout.duration))
                    Spacer()
                    statBox(title: "AVG HR", value: "\(workout.averageBPM)")
                    Spacer()
                    statBox(title: "MAX HR", value: "\(workout.maxBPM)")
                    Spacer()
                    statBox(title: "MIN HR", value: "\(workout.minBPM)")
                }
            } else {
                HStack {
                    statBox(title: "DURATION", value: formatDuration(workout.duration))
                    Spacer()
                    Label("No heart rate recorded", systemImage: "heart.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var calorieBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ENERGY EXPENDITURE BREAKDOWN")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE BURN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                    Text("\(Int(workout.activeCalories)) kcal")
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("+")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("RESTING BMR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("\(Int(workout.bmrCalories)) kcal")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                Spacer()
                Text("=")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TOTAL KCAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.cyan)
                    Text("\(Int(workout.calories)) kcal")
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.cyan)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func statBox(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }

    private var interactiveChartCard: some View {
        let zones = workoutStore.activeProfile.activeZones

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HEART RATE CURVE & POI MARKERS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Trend", isOn: $showRollingTrend)
                    .toggleStyle(.button)
                    .controlSize(.mini)
            }

            if let sample = selectedSample {
                let z = workoutStore.activeProfile.zone(for: sample.bpm)
                Text("Selected: \(formatDuration(sample.elapsedSeconds)) • \(sample.bpm) BPM (\(z.name))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(z.color)
            } else {
                Text("Drag on chart or tap a POI chip below to inspect")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if chartSamples.count >= 2 {
                Chart {
                    RuleMark(y: .value("Z2 Ceiling", zones.z2Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.green.opacity(0.45))

                    RuleMark(y: .value("Threshold", zones.z4Max))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.orange.opacity(0.55))

                    ForEach(chartSamples) { pt in
                        AreaMark(
                            x: .value("Time (s)", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.red.opacity(0.32), .orange.opacity(0.12), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time (s)", pt.elapsedSeconds),
                            y: .value("BPM", pt.bpm)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2.0))
                        .foregroundStyle(by: .value("Series", "Heart Rate"))
                    }

                    if showRollingTrend {
                        ForEach(rollingTrendSamples) { pt in
                            LineMark(
                                x: .value("Time (s)", pt.elapsedSeconds),
                                y: .value("BPM", pt.bpm)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 1.8, dash: [5, 3]))
                            .foregroundStyle(by: .value("Series", "Trend"))
                        }
                    }

                    ForEach(workout.pointsOfInterest) { poi in
                        RuleMark(x: .value("POI Line", poi.elapsedSeconds))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle((poi.isPositive ? Color.cyan : Color.yellow).opacity(0.55))

                        PointMark(
                            x: .value("Time (s)", poi.elapsedSeconds),
                            y: .value("BPM", poi.bpm)
                        )
                        .symbolSize(110)
                        .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                        .annotation(position: .top, spacing: 4) {
                            HStack(spacing: 3) {
                                Image(systemName: poi.symbol)
                                Text(poi.shortTag)
                            }
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.82), in: Capsule())
                            .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                        }
                    }

                    if let sample = selectedSample {
                        RuleMark(x: .value("Selected", sample.elapsedSeconds))
                            .foregroundStyle(.white.opacity(0.75))
                        PointMark(
                            x: .value("Selected", sample.elapsedSeconds),
                            y: .value("BPM", sample.bpm)
                        )
                        .symbolSize(120)
                        .foregroundStyle(.white)
                    }
                }
                .chartForegroundStyleScale([
                    "Heart Rate": Color.red,
                    "Trend": Color.cyan.opacity(0.85)
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: max(45, workout.minBPM - 10)...min(235, workout.maxBPM + 18))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let sec = value.as(Double.self) {
                                Text(formatDuration(sec))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXSelection(value: $selectedElapsed)
                .frame(height: 250)

                if !workout.pointsOfInterest.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(workout.pointsOfInterest) { poi in
                                Button {
                                    selectedElapsed = poi.elapsedSeconds
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: poi.symbol)
                                        Text("\(poi.shortTag) @ \(formatDuration(poi.elapsedSeconds))")
                                    }
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background((poi.isPositive ? Color.cyan : Color.yellow).opacity(0.18), in: Capsule())
                                    .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Not enough heart rate points recorded to plot graph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var poiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POINTS OF INTEREST")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(workout.pointsOfInterest) { poi in
                Button {
                    selectedElapsed = poi.elapsedSeconds
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: poi.symbol)
                            .font(.headline)
                            .foregroundStyle(poi.isPositive ? .cyan : .yellow)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(poi.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(poi.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(poi.elapsedSeconds))
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var autoHRRSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUTOMATIC IN-WORKOUT HRR-60 RECOVERIES")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(workout.autoHRREvents) { ev in
                HStack {
                    Image(systemName: "arrow.down.heart.fill")
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ev.contextLabel)
                            .font(.subheadline.weight(.semibold))
                        Text("\(ev.peakBPM) → \(ev.recovery60BPM) BPM @ \(formatDuration(ev.elapsedSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("-\(ev.dropBPM) BPM")
                        .font(.headline.monospacedDigit().weight(.bold))
                        .foregroundStyle(.cyan)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var roundDecayChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ROUND-BY-ROUND FATIGUE DECAY")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(workout.roundStats) { stat in
                    LineMark(
                        x: .value("Round", "R\(stat.roundNumber)"),
                        y: .value("BPM", stat.peakBPM)
                    )
                    .foregroundStyle(by: .value("Metric", "Peak BPM"))
                    .symbol(.circle)

                    LineMark(
                        x: .value("Round", "R\(stat.roundNumber)"),
                        y: .value("BPM", stat.avgBPM)
                    )
                    .foregroundStyle(by: .value("Metric", "Avg BPM"))
                    .symbol(.square)

                    if let drop = stat.stoolDropBPM {
                        BarMark(
                            x: .value("Round", "R\(stat.roundNumber)"),
                            y: .value("Stool Drop", drop)
                        )
                        .foregroundStyle(Color.cyan.opacity(0.35))
                    }
                }
            }
            .chartForegroundStyleScale([
                "Peak BPM": Color.red,
                "Avg BPM": Color.orange
            ])
            .frame(height: 190)

            Label("Cyan bars = 60s Stool HR Drop per round", systemImage: "arrow.down.heart.fill")
                .font(.caption2)
                .foregroundStyle(.cyan)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var zoneBreakdownCard: some View {
        let total = max(1.0, workout.zoneSeconds.values.reduce(0, +))
        let zoneMeta: [(Int, String, Color)] = [
            (5, "Z5 Peak", .red),
            (4, "Z4 Threshold", .orange),
            (3, "Z3 Tempo", .yellow),
            (2, "Z2 Aerobic", .green),
            (1, "Z1 Recovery", .blue)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            Text("TIME IN HEART RATE ZONES")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(zoneMeta, id: \.0) { zoneNum, label, color in
                let sec = workout.zoneSeconds[zoneNum, default: 0]
                let pct = sec / total
                VStack(spacing: 4) {
                    HStack {
                        Text(label)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(formatDuration(sec)) (\(Int(round(pct * 100)))%)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule()
                                .fill(color)
                                .frame(width: max(4, geo.size.width * pct))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var advancedMetricsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONDITIONING & FIGHTER ANALYTICS")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricTile(
                    title: "PEAK AUTO HRR-60",
                    value: workout.hrr60Drop != nil ? "-\(workout.hrr60Drop!) BPM" : "No 60s Drop",
                    subtitle: hrrGrade(workout.hrr60Drop),
                    color: .cyan
                )
                metricTile(
                    title: "REDLINE EXPOSURE (Z5)",
                    value: formatDuration(workout.redlineSeconds),
                    subtitle: "Time above Z4 threshold",
                    color: .red
                )
                metricTile(
                    title: "TRAINING LOAD",
                    value: "\(Int(workout.trimpScore))",
                    subtitle: workout.trimpScore > 120 ? "High fight load" : "Moderate load",
                    color: .orange
                )
                metricTile(
                    title: "CARDIAC DRIFT",
                    value: String(format: "%.1f%%", workout.cardiacDriftPercent),
                    subtitle: abs(workout.cardiacDriftPercent) <= 5.0 ? "Strong aerobic base" : "Aerobic decoupling",
                    color: .green
                )
                metricTile(
                    title: "AEROBIC EFFICIENCY",
                    value: String(format: "%.2f", workout.aerobicEfficiencyIndex),
                    subtitle: "Active kcal/min per 100 BPM",
                    color: .mint
                )
                metricTile(
                    title: "EPOC AFTERBURN",
                    value: "+\(Int(workout.epocBonusCalories)) kcal",
                    subtitle: "Post-session oxygen debt",
                    color: .yellow
                )
                if workout.strikesCuedCount > 0 {
                    let perMin = Double(workout.strikesCuedCount) / max(1.0, workout.duration / 60.0)
                    metricTile(
                        title: "BAG STRIKES CUED",
                        value: "\(workout.strikesCuedCount)",
                        subtitle: String(format: "%.1f strikes/min cadence", perMin),
                        color: .orange
                    )
                }
                if let ghostDelta = workout.ghostAvgDeltaBPM {
                    metricTile(
                        title: "VS GHOST PACE",
                        value: String(format: "%+.1f BPM", ghostDelta),
                        subtitle: ghostDelta <= 0 ? "More efficient than Ghost" : "Higher output than Ghost",
                        color: .purple
                    )
                }
                if let rmssd = workout.rmssdMs {
                    metricTile(
                        title: "SESSION HRV (RMSSD)",
                        value: "\(Int(rmssd)) ms",
                        subtitle: "Autonomic variability",
                        color: .purple
                    )
                }
            }
        }
    }

    private func metricTile(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func hrrGrade(_ drop: Int?) -> String {
        guard let d = drop else { return "Trigger >80% MaxHR + 60s rest" }
        if d >= 30 { return "Elite Fighter (<30s reset)" }
        if d >= 20 { return "Fight Ready" }
        if d >= 12 { return "Average Recovery" }
        return "Fatigued / Overreached"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Post-session rating

/// Asks "how hard was that?" after the session (RPE 1–10). Once rated, the
/// session's load blends heart-rate TRIMP with session-RPE.
struct SessionRatingCard: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    let workoutID: UUID

    @State private var rpe: Int = 6
    @State private var notes: String = ""
    @State private var editing = false
    @State private var loaded = false

    private static let labels = [
        1: "Very easy", 2: "Easy", 3: "Moderate", 4: "Somewhat hard", 5: "Hard",
        6: "Hard+", 7: "Very hard", 8: "Very hard+", 9: "Near max", 10: "Max effort"
    ]

    var body: some View {
        let workout = workoutStore.workouts.first { $0.id == workoutID }
        VStack(alignment: .leading, spacing: 10) {
            if let w = workout, w.rpeRated, !editing {
                HStack {
                    Label("Effort \(w.rpe)/10 • \(Self.labels[w.rpe] ?? "")", systemImage: "flame.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Edit") {
                        rpe = w.rpe
                        notes = w.notes
                        editing = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if !w.notes.isEmpty {
                    Text(w.notes).font(.caption).foregroundStyle(.secondary)
                }
                Text(w.hasHeartRate
                     ? String(format: "Session load %.0f (heart rate %.0f, effort %.0f)", w.effectiveLoad, w.trimpScore, w.sessionRPELoad)
                     : String(format: "Session load %.0f (from your effort rating)", w.effectiveLoad))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("How hard was that?")
                    .font(.headline)
                Text(workout?.hasHeartRate != false
                     ? "Your rating makes training load more accurate. Heart rate alone under-reads sparring, clinch and strength work."
                     : "No heart rate was recorded, so your rating is how the coach counts this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(1...10, id: \.self) { v in
                        Button {
                            rpe = v
                        } label: {
                            Text("\(v)")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(color(v).opacity(rpe == v ? 1 : 0.2), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(rpe == v ? Color.black : color(v))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Effort \(v), \(Self.labels[v] ?? "")")
                        .accessibilityAddTraits(rpe == v ? .isSelected : [])
                    }
                }
                Text(Self.labels[rpe] ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(rpe))
                TextField("Notes (optional): how it felt, what worked", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button {
                    workoutStore.updateRating(workoutID: workoutID, rpe: rpe, notes: notes)
                    editing = false
                } label: {
                    Text("Save Rating")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            guard !loaded, let w = workout else { return }
            loaded = true
            notes = w.notes
            if w.rpeRated { rpe = w.rpe }
        }
    }

    private func color(_ v: Int) -> Color {
        switch v {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}


// MARK: - Plan results

struct PlanResultsCard: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    let workoutID: UUID
    @State private var resultURL: URL?

    var body: some View {
        if let w = workoutStore.workouts.first(where: { $0.id == workoutID }) {
            let done = w.blockResults.filter(\.completed).count
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(w.trainingPlanTitle ?? "Training plan", systemImage: "list.bullet.rectangle.portrait.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("\(done)/\(w.blockResults.count) blocks")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(done == w.blockResults.count ? .green : .orange)
                }
                ForEach(w.blockResults) { BlockResultRow(result: $0) }
                Button {
                    let profile = workoutStore.profile(for: w)
                    let score = CoachEngine.review(workout: w, profile: profile, history: workoutStore.workouts).overall
                    let package = SessionResultPackage(workout: w, athlete: profile, reviewScore: score)
                    resultURL = try? PlanTransfer.writeResultFile(package)
                } label: {
                    Label("Send Result to Coach", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                if !w.rpeRated {
                    Text("Tip: rate your effort above first so your coach sees it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .sheet(item: Binding(
                get: { resultURL.map(ShareableFile.init) },
                set: { if $0 == nil { resultURL = nil } }
            )) { file in
                ShareSheet(items: [file.url])
            }
        }
    }
}


/// The stretch where the strap dropped out, kept clearly apart from the measured data.
struct EstimatedHeartRateCard: View {
    let workout: SavedWorkout
    let realSamples: [HeartRatePoint]

    private var estimatedAverage: Int {
        let e = workout.estimatedSamples
        return e.isEmpty ? 0 : e.map(\.bpm).reduce(0, +) / e.count
    }

    private var gapText: String {
        let s = Int(workout.estimatedSeconds)
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Estimated while your strap was off", systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Your strap dropped out for \(gapText). FIGHT estimated your heart rate for that stretch from the rest of this session. These are estimates, not measurements, and they aren't counted in your averages, zones, calories or records.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                BigNumber(value: "≈\(estimatedAverage)", label: "est. avg bpm", size: 22)
                BigNumber(value: "≈\(Int(workout.estimatedCalories))", label: "est. burn kcal", size: 22)
                BigNumber(value: gapText, label: "estimated", size: 22)
            }
            .foregroundStyle(.secondary)
            Chart {
                ForEach(realSamples) { p in
                    LineMark(x: .value("Time", p.elapsedSeconds / 60), y: .value("BPM", p.bpm),
                             series: .value("Kind", "Measured"))
                        .foregroundStyle(Theme.red)
                }
                ForEach(workout.estimatedSamples) { p in
                    PointMark(x: .value("Time", p.elapsedSeconds / 60), y: .value("BPM", p.bpm))
                        .symbolSize(6)
                        .foregroundStyle(Color.gray)
                }
            }
            .chartXAxisLabel("min")
            .frame(height: 120)
            HStack(spacing: 14) {
                Label("Measured", systemImage: "circle.fill").foregroundStyle(Theme.red)
                Label("Estimated", systemImage: "circle.dotted").foregroundStyle(.gray)
            }
            .font(.caption)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}
