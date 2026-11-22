import SwiftUI

// MARK: - Corner (home) cards

/// Monday to Sunday: a red dot for every day you trained.
struct WeekStrip: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var navigation: AppNavigation

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }
    private var weekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
    }
    private var days: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }
    private var thisWeek: [SavedWorkout] {
        workoutStore.workouts.filter { $0.profileID == workoutStore.activeProfileID && $0.startDate >= weekStart }
    }

    var body: some View {
        let sessions = thisWeek
        let minutes = Int(sessions.reduce(0) { $0 + $1.duration } / 60)
        Button {
            navigation.recordSegment = .sessions
            navigation.selectedTab = .record
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("This week").font(.headline)
                    Spacer()
                    Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(minutes) min")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        let trained = sessions.contains { calendar.isDate($0.startDate, inSameDayAs: day) }
                        let today = calendar.isDateInToday(day)
                        VStack(spacing: 6) {
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(today ? Theme.red : .secondary)
                            Circle()
                                .fill(trained ? Theme.red : Color.secondary.opacity(0.18))
                                .overlay(Circle().strokeBorder(today && !trained ? Theme.red : .clear, lineWidth: 2))
                                .frame(width: 24, height: 24)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(sessions.count) sessions, \(minutes) minutes")
        .accessibilityHint("Opens your sessions")
        .accessibilityAddTraits(.isButton)
    }
}

/// Days to fight night and your weight, with the camp one tap away.
struct FightCountdownCard: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @State private var showingWarmUp = false
    @State private var showingBreathing = false

    private var daysToFight: Int? {
        guard let fight = workoutStore.activeProfile.fightDate else { return nil }
        let cal = Calendar.current
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: fight)).day ?? -1
        return d >= 0 ? d : nil
    }

    private var weightText: String {
        let p = workoutStore.activeProfile
        let w = workoutStore.weighIns.first { $0.profileID == p.id }?.weightKg ?? p.weightKg
        return WeightUnits.text(w, p.useImperial)
    }

    var body: some View {
        if let days = daysToFight {
            VStack(spacing: 12) {
                NavigationLink {
                    CampView()
                } label: {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fight night").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(days == 0 ? "Tonight" : "\(days) day\(days == 1 ? "" : "s")")
                                .font(Theme.number(30))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Weight").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(weightText).font(Theme.number(22))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your fight camp")

                if days <= 2 {
                    HStack(spacing: 10) {
                        Button { showingWarmUp = true } label: {
                            Label("Fight-night warm-up", systemImage: "flame.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        Button { showingBreathing = true } label: {
                            Label("Breathe", systemImage: "wind")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline.weight(.semibold))
                }
            }
            .card()
            .sheet(isPresented: $showingWarmUp) { FightNightWarmUpSheet() }
            .sheet(isPresented: $showingBreathing) { BreathingTrainerView() }
        } else if workoutStore.activeProfile.goal == .fight {
            NavigationLink {
                CampView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.title3)
                        .foregroundStyle(Theme.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Got a fight?").font(.headline)
                        Text("Set the date for a camp plan, weight cut and taper.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }
}

/// Your most recent session, one tap from the full review.
struct LastSessionCard: View {
    @EnvironmentObject var workoutStore: WorkoutStore

    private var last: SavedWorkout? {
        workoutStore.workouts
            .filter { $0.profileID == workoutStore.activeProfileID }
            .max { $0.startDate < $1.startDate }
    }

    var body: some View {
        if let w = last {
            NavigationLink {
                WorkoutDetailView(workout: w)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: w.category.icon)
                        .font(.title3)
                        .foregroundStyle(Theme.red)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.when(w.startDate))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(w.displayTitle).font(.headline).lineLimit(1)
                        Text(Self.detail(w))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the session review")
        }
    }

    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Last session · Today" }
        if cal.isDateInYesterday(date) { return "Last session · Yesterday" }
        return "Last session · " + date.formatted(.dateTime.weekday(.wide).day().month())
    }

    static func detail(_ w: SavedWorkout) -> String {
        var parts = ["\(max(1, Int(w.duration / 60))) min"]
        if let run = w.run, run.distanceM > 0 {
            let value = run.distanceM / run.unitMeters
            parts.append(String(format: "%.2f %@", value, run.imperial ? "mi" : "km"))
        }
        if w.hasHeartRate { parts.append("avg \(w.averageBPM) bpm") }
        return parts.joined(separator: " · ")
    }
}

/// Session scorecard at the top of a session review: the headline, three numbers,
/// round by round, and one button to share it.
struct ScorecardHeader: View {
    let workout: SavedWorkout
    let onShare: () -> Void

    private var headline: String {
        let rounds = workout.roundStats
        if workout.run != nil {
            return "Roadwork in the bank"
        }
        if rounds.count >= 3, let first = rounds.first?.avgBPM, let last = rounds.last?.avgBPM, first > 0 {
            if last <= first + 3 { return "You held pace to the bell" }
            if last > first + 12 { return "You faded late. Build the gas tank." }
            return "\(rounds.count) rounds done"
        }
        if rounds.count >= 1 { return "\(rounds.count) round\(rounds.count == 1 ? "" : "s") done" }
        return "Work in the bank"
    }

    private var middle: (String, String) {
        if let run = workout.run, run.distanceM > 0 {
            return (String(format: "%.2f", run.distanceM / run.unitMeters), run.imperial ? "mi" : "km")
        }
        if workout.hasHeartRate { return ("\(workout.averageBPM)", "avg bpm") }
        return (workout.roundStats.isEmpty ? "--" : "\(workout.roundStats.count)", "rounds")
    }

    var body: some View {
        let mid = middle
        let rounds = workout.roundStats.filter { $0.avgBPM > 0 }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(workout.displayTitle) · \(workout.startDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                BigNumber(value: Self.clock(workout.duration), label: "time")
                BigNumber(value: mid.0, label: mid.1)
                BigNumber(value: "\(Int(workout.calories))", label: "kcal")
            }
            if rounds.count >= 2 {
                let top = Double(rounds.map(\.avgBPM).max() ?? 1)
                let low = Double(rounds.map(\.avgBPM).min() ?? 0) * 0.85
                VStack(alignment: .leading, spacing: 6) {
                    Text("Round by round").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(rounds) { r in
                            let share = max(0.12, (Double(r.avgBPM) - low) / max(1, top - low))
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.red)
                                    .frame(height: 56 * share)
                                Text("R\(r.roundNumber)").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 76, alignment: .bottom)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Average heart rate by round: " + rounds.map { "round \($0.roundNumber) \($0.avgBPM)" }.joined(separator: ", "))
                }
            }
            Button(action: onShare) {
                Label("Share story", systemImage: "camera.fill")
            }
            .buttonStyle(FightPrimaryButtonStyle())
        }
        .card()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
