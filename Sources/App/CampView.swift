import SwiftUI
import Charts

struct CampView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var healthKit: HealthKitManager
    @AppStorage("fight_reminder_on") private var reminderOn = false
    @AppStorage("fight_reminder_minutes") private var reminderMinutes = 7 * 60
    @State private var reminderDenied = false
    @State private var importingHealth = false

    @State private var showingFightSetup = false
    @State private var showingWeighIn = false
    @State private var expandedWeek: Int?
    @State private var reportURL: URL?
    @State private var isGeneratingReport = false
    @State private var reportError: String?
    @State private var showingWarmUp = false
    @State private var showingStory = false

    var body: some View {
        let profile = workoutStore.activeProfile
        let plan = CampPlanner.buildPlan(profile: profile, workouts: workoutStore.workouts)
        let weight = CampPlanner.weightStatus(weighIns: workoutStore.weighIns, readings: workoutStore.activeReadings, profile: profile)

            ScrollView {
                VStack(spacing: 16) {
                    fightHeader(profile: profile, plan: plan)

                    if let plan, let week = plan.currentWeek {
                        currentWeekCard(week, plan: plan, profile: profile, detailed: false)
                    }

                    if plan?.currentWeek?.isFightWeek == true {
                        fightNightCard
                    }

                    if let days = weight.daysToFight, (0...3).contains(days) {
                        rehydrationCard(weight, profile: profile)
                    }

                    weightCard(weight, profile: profile, detailed: false)

                    AdvancedSection("Camp details", subtitle: "Weight trend, body signals, full plan, reminders, report", key: "camp.details") {
                        if let plan, let week = plan.currentWeek {
                            currentWeekCard(week, plan: plan, profile: profile, detailed: true)
                        }
                        weightCard(weight, profile: profile, detailed: true)
                        bodySignalsCard
                        if let plan {
                            planCard(plan)
                        }
                        if let comparison = CampCompare.compare(profile: profile, workouts: workoutStore.workouts, weighIns: workoutStore.weighIns) {
                            CampCompareCard(comparison: comparison)
                        }
                        reminderCard
                        reportCard
                    }
                }
                .padding()
            }
            .navigationTitle("Fight Camp")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let fight = profile.fightDate, fight > Date() {
                        Button {
                            showingStory = true
                        } label: {
                            Label("Share countdown", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        showingWeighIn = true
                    } label: {
                        Label("Log Weigh-In", systemImage: "scalemass")
                    }
                }
            }
            .sheet(isPresented: $showingStory) {
                StoryShareSheet(focus: .countdown)
            }
            .sheet(isPresented: $showingFightSetup) {
                FightSetupSheet()
            }
            .sheet(isPresented: $showingWarmUp) {
                FightNightWarmUpSheet()
            }
            .sheet(isPresented: $showingWeighIn) {
                WeighInSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(
                get: { reportURL.map(ShareableFile.init) },
                set: { if $0 == nil { reportURL = nil } }
            )) { file in
                ShareSheet(items: [file.url])
            }
            .alert("Couldn't create report", isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(reportError ?? "")
            }
    }

    // MARK: Fight night

    private var fightNightCard: some View {
        Button {
            showingWarmUp = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.boxing")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fight-Night Warm-Up").font(.headline)
                    Text("Set your walkout time and get a warm-up that finishes right on it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .card(tint: .red)
        }
        .buttonStyle(.plain)
    }

    // MARK: Fight header

    @ViewBuilder
    private func fightHeader(profile: AthleteProfile, plan: CampPlan?) -> some View {
        if let fight = profile.fightDate, let plan {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                       to: Calendar.current.startOfDay(for: fight)).day ?? 0
            HStack(spacing: 16) {
                VStack(spacing: 0) {
                    Text(days >= 0 ? "\(days)" : "—")
                        .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                    Text(days == 1 ? "day" : "days")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text(fight.formatted(date: .complete, time: .omitted))
                        .font(.subheadline.weight(.bold))
                    if plan.isOver {
                        Text("Fight date has passed. Set your next fight.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let w = plan.currentWeek {
                        Text("\(w.title) of \(plan.weeks.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(w.phase.color)
                    } else {
                        Text("Camp starts \(plan.campStart.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Target: \(WeightUnits.text(profile.targetFightWeightKg, profile.useImperial)) • \(plan.weeks.count)-week camp")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Edit") { showingFightSetup = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Plan your fight camp")
                    .font(.title3.weight(.bold))
                Text("Set your fight date and the coach counts back to build week-by-week load targets for base, build, peak and taper.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showingFightSetup = true
                } label: {
                    Text("Set Fight Date")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: Current week

    private func currentWeekCard(_ week: CampWeek, plan: CampPlan, profile: AthleteProfile, detailed: Bool) -> some View {
        let wantedPhase: CampPhase = week.isFightWeek ? .fightWeek : week.phase.profilePhase
        return VStack(alignment: .leading, spacing: 12) {
            if !detailed {
            HStack {
                Text("THIS WEEK")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(week.phase.rawValue.uppercased())
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(week.phase.color.opacity(0.2), in: Capsule())
                    .foregroundStyle(week.phase.color)
            }

            Text(week.focus)
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Load \(Int(week.actualLoad)) / \(Int(week.targetLoad))")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    Spacer()
                    Text("\(week.actualSessions) / \(week.targetSessions) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, week.completion))
                    .tint(week.completion > 1.15 ? .orange : week.phase.color)
                Text(loadStatus(week))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            } else {
            Text("This week's sessions").font(.headline)

            Text("Intensity mix: \(week.intensityMix.low)% easy • \(week.intensityMix.mid)% tempo • \(week.intensityMix.high)% hard")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Key sessions").font(.caption.weight(.bold))
                ForEach(week.keySessions, id: \.self) { k in
                    Label(k, systemImage: "checkmark.circle")
                        .font(.caption)
                }
            }

            if profile.campPhase != wantedPhase {
                Button {
                    var p = workoutStore.activeProfile
                    p.campPhase = wantedPhase
                    workoutStore.activeProfile = p
                } label: {
                    Label("Set profile phase to \(wantedPhase.rawValue)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func loadStatus(_ week: CampWeek) -> String {
        let daysLeft = max(0, Int(week.end.timeIntervalSince(Date()) / 86400))
        let remaining = max(0, week.targetLoad - week.actualLoad)
        if week.completion >= 1.15 { return "Over target. Keep the rest of the week easy to avoid overreaching." }
        if remaining <= 0 { return "Target hit. Anything more this week should be easy." }
        return "\(Int(remaining)) load to go with \(daysLeft) day\(daysLeft == 1 ? "" : "s") left (one hard session ≈ 80–120)."
    }

    // MARK: Weight

    private func weightCard(_ w: WeightCutStatus, profile: AthleteProfile, detailed: Bool) -> some View {
        let recent = w.series.filter { $0.date >= Date().addingTimeInterval(-56 * 86400) }
        let imp = profile.useImperial
        let u = WeightUnits.unit(imp)
        let shownWarnings = detailed ? Array(w.warnings.dropFirst()) : Array(w.warnings.prefix(1))
        return VStack(alignment: .leading, spacing: 12) {
            if !detailed {
            HStack {
                Text("Weight").font(.headline)
                Spacer()
                Button {
                    showingWeighIn = true
                } label: {
                    Label("Log Weigh-In", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                weightStat("Current", WeightUnits.number(w.currentKg, imp), u)
                weightStat("To go", w.toGoKg > 0 ? WeightUnits.number(w.toGoKg, imp) : "0", w.toGoKg > 0 ? "\(u) (\(CampPlanner.fmt(w.toGoPercent))%)" : "on weight")
                weightStat("Trend", w.trendKgPerWeek.map { String(format: "%+.1f", WeightUnits.value($0, imp)) } ?? "–", "\(u)/week")
            }

            if let req = w.requiredKgPerWeek, w.toGoKg > 0 {
                Text("Needed: \(WeightUnits.number(req, imp)) \(u)/week to make \(WeightUnits.text(w.targetKg, imp))" +
                     (w.projectedFightWeightKg.map { " • on current trend you'll weigh \(WeightUnits.text($0, imp))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(w.isOnTrack ? Color.secondary : Color.orange)
            }
            } else {
            Text("Weight trend").font(.headline)
            if recent.count >= 2 {
                Chart {
                    ForEach(recent) { e in
                        LineMark(x: .value("Date", e.date), y: .value("Weight", WeightUnits.value(e.weightKg, imp)))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.cyan)
                        PointMark(x: .value("Date", e.date), y: .value("Weight", WeightUnits.value(e.weightKg, imp)))
                            .foregroundStyle(.cyan)
                            .symbolSize(24)
                    }
                    RuleMark(y: .value("Target", WeightUnits.value(w.targetKg, imp)))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(.green)
                        .annotation(position: .top, alignment: .leading) {
                            Text("Fight weight").font(.caption2).foregroundStyle(.green)
                        }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
                .accessibilityLabel("Weight trend over the last 8 weeks")
            } else {
                Text("Log a weigh-in each morning after the bathroom, before eating, to track your cut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }

            ForEach(shownWarnings) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: warning.icon)
                        .foregroundStyle(warning.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.title).font(.subheadline.weight(.bold))
                        Text(warning.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(warning.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }

            if detailed && healthKit.isAvailable {
                Button {
                    importingHealth = true
                    Task {
                        await healthKit.importWeighIns(into: workoutStore, profileID: workoutStore.activeProfileID)
                        importingHealth = false
                    }
                } label: {
                    HStack {
                        if importingHealth { ProgressView().padding(.trailing, 4) }
                        Label("Import weight from Apple Health", systemImage: "heart.text.square")
                    }
                    .font(.subheadline)
                }
                .disabled(importingHealth)
                if !healthKit.statusMessage.isEmpty && !importingHealth {
                    Text(healthKit.statusMessage).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if detailed && !w.series.isEmpty {
                NavigationLink {
                    WeighInHistoryView()
                } label: {
                    Label("Weigh-in history (\(w.series.count))", systemImage: "list.bullet")
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func weightStat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Body signals

    private var bodySignalsCard: some View {
        let readings = workoutStore.activeReadings
            .filter { $0.date >= Date().addingTimeInterval(-28 * 86400) }
            .sorted { $0.date < $1.date }
        let hrvReadings = readings.filter { $0.hrvScore != nil }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Body Signals").font(.headline)
            if readings.count >= 2 {
                Text("Morning resting HR and HRV from your readiness checks. A rising HR or falling HRV during a cut means you're pushing too hard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Chart {
                    ForEach(readings) { r in
                        LineMark(x: .value("Date", r.date), y: .value("BPM", r.restingHR))
                            .foregroundStyle(by: .value("Signal", "Resting HR"))
                            .symbol(.circle)
                    }
                    ForEach(hrvReadings) { r in
                        LineMark(x: .value("Date", r.date), y: .value("BPM", r.hrvScore ?? 0))
                            .foregroundStyle(by: .value("Signal", "HRV score"))
                            .symbol(.square)
                    }
                }
                .chartForegroundStyleScale(["Resting HR": Color.red, "HRV score": Color.purple])
                .chartYScale(domain: .automatic(includesZero: false))
                .chartLegend(position: .bottom)
                .frame(height: 150)
                .accessibilityLabel("Resting heart rate and HRV over the last 4 weeks")
            } else {
                Text("Do the 2-minute readiness check in the Coach tab each morning. Your resting HR and HRV will appear here next to your weight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Plan

    private func planCard(_ plan: CampPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camp Plan").font(.headline)
            Text("Weekly load targets (TRIMP), built from your current fitness of about \(Int(plan.baselineWeeklyLoad))/week. Grey bars are targets; coloured bars are what you've done.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(plan.weeks) { w in
                    BarMark(x: .value("Week", "W\(w.index)"), y: .value("Load", w.targetLoad), width: .ratio(0.7))
                        .foregroundStyle(Color.gray.opacity(0.3))
                    BarMark(x: .value("Week", "W\(w.index)"), y: .value("Load", w.actualLoad), width: .ratio(0.45))
                        .foregroundStyle(w.phase.color)
                }
                if let cur = plan.currentWeekIndex {
                    RuleMark(x: .value("Week", "W\(cur)"))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .frame(height: 170)
            .accessibilityLabel("Weekly load targets versus actual load")

            HStack(spacing: 12) {
                ForEach(CampPhaseKind.allCases, id: \.self) { p in
                    Label(p.rawValue, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(p.color)
                }
            }

            ForEach(plan.weeks) { w in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedWeek == w.index },
                    set: { expandedWeek = $0 ? w.index : nil }
                )) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(w.focus).font(.caption.weight(.semibold))
                        ForEach(w.keySessions, id: \.self) { k in
                            Label(k, systemImage: "circle").font(.caption)
                        }
                        Text("Mix \(w.intensityMix.low)/\(w.intensityMix.mid)/\(w.intensityMix.high) • \(w.targetSessions) sessions")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } label: {
                    HStack {
                        Circle().fill(w.phase.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.title).font(.subheadline.weight(w.index == plan.currentWeekIndex ? .bold : .regular))
                            Text("\(w.start.formatted(.dateTime.month(.abbreviated).day())) – \(w.end.addingTimeInterval(-86400).formatted(.dateTime.month(.abbreviated).day()))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(w.actualLoad))/\(Int(w.targetLoad))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Rehydration

    private func rehydrationCard(_ w: WeightCutStatus, profile: AthleteProfile) -> some View {
        let imp = profile.useImperial
        let fight = profile.fightDate ?? Date()
        let window = w.series.filter {
            $0.date >= fight.addingTimeInterval(-14 * 86400) && $0.date <= fight.addingTimeInterval(-3 * 86400)
        }
        let preCut = window.map(\.weightKg).max() ?? w.currentKg
        let lost = max(0, preCut - w.currentKg)
        let fluidsL = max(1.0, lost * 1.5)
        let carbsLow = Int(w.currentKg * 5), carbsHigh = Int(w.currentKg * 8)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Rehydration plan (after weigh-ins)", systemImage: "drop.fill")
                .font(.headline)
                .foregroundStyle(.cyan)
            if lost > 0 {
                Text("You've cut about \(WeightUnits.text(lost, imp)) from \(WeightUnits.text(preCut, imp)).")
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("Drink about \(String(format: "%.1f", fluidsL)) L (150% of weight lost) over the first 4–6 hours, in sips of 500–750 ml per hour, not all at once.")
                bullet("Use an oral rehydration or electrolyte drink for the first litres. Sodium helps you keep the fluid.")
                bullet("Eat \(carbsLow)–\(carbsHigh) g of carbohydrate over the next 24 h, in small, familiar, low-fibre meals every 2–3 hours.")
                bullet("Aim for pale urine (1–3 on the chart) and re-weigh on fight morning.")
            }
            Text("General guidance for combat sports. Follow your coach's or dietitian's plan if you have one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
        }
    }

    // MARK: Reminder

    private var reminderCard: some View {
        let timeBinding = Binding<Date>(
            get: {
                Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                reminderMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                if reminderOn { scheduleReminder() }
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { reminderOn }, set: { on in
                reminderOn = on
                if on { scheduleReminder() } else { MorningReminder.cancel() }
            })) {
                Label("Morning check-in reminder", systemImage: "bell.badge")
                    .font(.headline)
            }
            if reminderOn {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
            }
            Text(reminderDenied ? "Notifications are off for FIGHT. Enable them in iOS Settings to get reminders." :
                    "A daily nudge to weigh in and take your readiness check.")
                .font(.caption)
                .foregroundStyle(reminderDenied ? Color.orange : Color.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func scheduleReminder() {
        let h = reminderMinutes / 60, m = reminderMinutes % 60
        Task {
            let ok = await MorningReminder.schedule(hour: h, minute: m)
            reminderDenied = !ok
            if !ok { reminderOn = false }
        }
    }

    // MARK: Report

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Report for your coach", systemImage: "doc.richtext")
                .font(.headline)
            Text("A 2-page PDF of the last 7 days: readiness, ratings, sessions with coach reviews, camp progress, weight and body signals.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                generateReport()
            } label: {
                HStack {
                    if isGeneratingReport { ProgressView().padding(.trailing, 4) }
                    Text(isGeneratingReport ? "Creating…" : "Export Weekly PDF")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGeneratingReport)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func generateReport() {
        isGeneratingReport = true
        // Let the button state render before the (synchronous) PDF render.
        Task { @MainActor in
            await Task.yield()
            if let url = WeeklyReportRenderer.render(store: workoutStore) {
                reportURL = url
            } else {
                reportError = "The PDF couldn't be written. Try again."
            }
            isGeneratingReport = false
        }
    }
}

// MARK: - Share sheet

struct ShareableFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Fight setup

struct FightSetupSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var undo: UndoCenter
    @Environment(\.dismiss) private var dismiss
    @State private var original: (Date, Int, String)?

    @State private var fightDate = Date().addingTimeInterval(56 * 86400)
    @State private var campWeeks = 8
    @State private var targetText = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Fight") {
                    DatePicker("Fight date", selection: $fightDate, in: Date()..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                Section {
                    Picker("Camp length", selection: $campWeeks) {
                        ForEach(4...16, id: \.self) { w in
                            Text("\(w) weeks").tag(w)
                        }
                    }
                    let start = Calendar.current.startOfDay(for: fightDate).addingTimeInterval(86400 - Double(campWeeks) * 7 * 86400)
                    LabeledContent("Camp starts", value: start.formatted(date: .abbreviated, time: .omitted))
                } footer: {
                    Text("8 weeks is standard. Use 10–12 for a title fight or a big weight cut.")
                }
                Section {
                    HStack {
                        TextField("Fight weight", text: $targetText)
                            .keyboardType(.decimalPad)
                        WeightUnitChip(text: $targetText)
                    }
                } header: {
                    Text("Fight weight target")
                } footer: {
                    Text("Current weight: \(WeightUnits.text(workoutStore.activeProfile.weightKg, workoutStore.activeProfile.useImperial))")
                }
                if workoutStore.activeProfile.fightDate != nil {
                    Section {
                        Button("Remove Fight Date", role: .destructive) {
                            var p = workoutStore.activeProfile
                            let old = p.fightDate
                            p.fightDate = nil
                            workoutStore.activeProfile = p
                            undo.show("Fight date removed") {
                                var q = workoutStore.activeProfile
                                q.fightDate = old
                                workoutStore.activeProfile = q
                            }
                            dismiss()
                        }
                    }
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Fight Setup")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(fightSetupChanged)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DiscardChangesButton(hasChanges: fightSetupChanged) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(parsedTarget == nil)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let p = workoutStore.activeProfile
                if let d = p.fightDate, d > Date() { fightDate = d }
                campWeeks = p.campLengthWeeks
                targetText = WeightUnits.number(p.targetFightWeightKg, p.useImperial)
                original = (fightDate, campWeeks, targetText)
            }
        }
    }

    private var fightSetupChanged: Bool {
        guard let o = original else { return false }
        return o.0 != fightDate || o.1 != campWeeks || o.2 != targetText
    }

    private var parsedTarget: Double? {
        guard let raw = Double(targetText.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let kg = WeightUnits.toKg(raw, workoutStore.activeProfile.useImperial)
        return (35...200).contains(kg) ? kg : nil
    }

    private func save() {
        var p = workoutStore.activeProfile
        p.fightDate = fightDate
        p.campLengthWeeks = campWeeks
        if let t = parsedTarget { p.targetFightWeightKg = t }
        workoutStore.activeProfile = p
        dismiss()
    }
}

// MARK: - Weigh-in entry

struct WeighInSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    @State private var weightText = ""
    @State private var date = Date()
    @State private var urineColor: Int?
    @State private var notes = ""
    @FocusState private var weightFocused: Bool

    static let urineColors: [Color] = [
        Color(red: 0.97, green: 0.97, blue: 0.86), Color(red: 0.98, green: 0.96, blue: 0.70),
        Color(red: 0.98, green: 0.93, blue: 0.50), Color(red: 0.97, green: 0.87, blue: 0.30),
        Color(red: 0.95, green: 0.78, blue: 0.18), Color(red: 0.88, green: 0.66, blue: 0.10),
        Color(red: 0.78, green: 0.53, blue: 0.08), Color(red: 0.62, green: 0.40, blue: 0.08)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Weight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .focused($weightFocused)
                        WeightUnitChip(text: $weightText)
                    }
                    DatePicker("Time", selection: $date, in: ...Date())
                } footer: {
                    Text("Weigh in each morning after the bathroom and before eating, for a consistent trend.")
                }

                Section {
                    HStack(spacing: 6) {
                        ForEach(1...8, id: \.self) { i in
                            Button {
                                urineColor = urineColor == i ? nil : i
                            } label: {
                                Circle()
                                    .fill(Self.urineColors[i - 1])
                                    .frame(height: 30)
                                    .overlay(
                                        Circle().stroke(Color.primary, lineWidth: urineColor == i ? 3 : 0)
                                    )
                                    .overlay(Text("\(i)").font(.caption2.weight(.bold)).foregroundStyle(.black.opacity(0.6)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Urine colour \(i) of 8")
                            .accessibilityAddTraits(urineColor == i ? .isSelected : [])
                        }
                    }
                } header: {
                    Text("Hydration (optional)")
                } footer: {
                    Text("Urine colour: 1–3 hydrated, 4–5 mildly dehydrated, 6–8 dehydrated.")
                }

                Section("Notes") {
                    TextField("e.g. after sauna, high-carb day", text: $notes)
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Log Weigh-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(parsedWeight == nil)
                }
            }
            .onAppear {
                let p = workoutStore.activeProfile
                let last = workoutStore.weighIns.first { $0.profileID == p.id }?.weightKg ?? p.weightKg
                weightText = WeightUnits.number(last, p.useImperial)
                weightFocused = true
            }
        }
    }

    private var parsedWeight: Double? {
        guard let raw = Double(weightText.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let kg = WeightUnits.toKg(raw, workoutStore.activeProfile.useImperial)
        return (30...250).contains(kg) ? kg : nil
    }

    private func save() {
        guard let w = parsedWeight else { return }
        workoutStore.addWeighIn(WeighIn(
            profileID: workoutStore.activeProfileID,
            date: date,
            weightKg: w,
            urineColor: urineColor,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        dismiss()
    }
}

// MARK: - History

struct WeighInHistoryView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var undo: UndoCenter

    var body: some View {
        let entries = workoutStore.weighIns.filter { $0.profileID == workoutStore.activeProfileID }
        List {
            ForEach(entries) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WeightUnits.text(e.weightKg, workoutStore.activeProfile.useImperial)).font(.headline).monospacedDigit()
                        Text(e.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if !e.notes.isEmpty {
                            Text(e.notes).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let u = e.urineColor {
                        Circle()
                            .fill(WeighInSheet.urineColors[max(0, min(7, u - 1))])
                            .frame(width: 18, height: 18)
                            .accessibilityLabel("Urine colour \(u)")
                    }
                }
            }
            .onDelete { offsets in
                let removed = offsets.map { entries[$0] }
                for e in removed { workoutStore.deleteWeighIn(e) }
                undo.show("Weigh-in deleted") {
                    for e in removed { workoutStore.addWeighIn(e) }
                }
            }
        }
        .navigationTitle("Weigh-Ins")
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No weigh-ins", systemImage: "scalemass")
            }
        }
    }
}


/// kg ⇄ lb chip for a weight text field: flipping it converts the typed number too.
struct WeightUnitChip: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Binding var text: String

    var body: some View {
        UnitChip(metric: "kg", imperial: "lb", isImperial: Binding(
            get: { workoutStore.activeProfile.useImperial },
            set: { newValue in
                let old = workoutStore.activeProfile.useImperial
                guard newValue != old else { return }
                if let raw = Double(text.replacingOccurrences(of: ",", with: ".")) {
                    text = WeightUnits.number(WeightUnits.toKg(raw, old), newValue)
                }
                var p = workoutStore.activeProfile
                p.useImperial = newValue
                workoutStore.activeProfile = p
            }
        ), accessibilityName: "Weight unit")
    }
}
