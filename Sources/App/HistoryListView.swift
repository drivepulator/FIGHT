import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var undo: UndoCenter
    @State private var selectedFilter: WorkoutCategory?
    /// History shows the active fighter only, unless you ask for everyone.
    @AppStorage("fight.history.allFighters") private var showAllFighters = false
    @State private var showingComparison = false
    @State private var backupURL: URL?
    @State private var backupFailed = false
    @State private var showingRecords = false

    private struct WeekGroup {
        let start: Date
        let workouts: [SavedWorkout]
        var load: Double { workouts.reduce(0) { $0 + $1.effectiveLoad } }
        var minutes: Int { Int(workouts.reduce(0) { $0 + $1.duration } / 60) }
    }

    /// Sessions grouped by training week (newest first).
    private var weekGroups: [WeekGroup] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let grouped = Dictionary(grouping: filteredWorkouts) { w in
            cal.dateInterval(of: .weekOfYear, for: w.startDate)?.start ?? cal.startOfDay(for: w.startDate)
        }
        return grouped.map { WeekGroup(start: $0.key, workouts: $0.value.sorted { $0.startDate > $1.startDate }) }
            .sorted { $0.start > $1.start }
    }

    private func weekHeader(_ g: WeekGroup) -> some View {
        let thisWeek = Calendar.current.isDate(g.start, equalTo: Date(), toGranularity: .weekOfYear)
        return HStack {
            Text(thisWeek ? "This week" : "Week of \(g.start.formatted(.dateTime.day().month()))")
            Spacer()
            Text("\(g.workouts.count) sessions · \(g.minutes) min · load \(Int(g.load))")
                .monospacedDigit()
        }
    }

    private var filteredWorkouts: [SavedWorkout] {
        workoutStore.workouts.filter { w in
            let matchesCat = (selectedFilter == nil || w.category == selectedFilter)
            let matchesFighter = showAllFighters || w.profileID == workoutStore.activeProfileID
            return matchesCat && matchesFighter
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredWorkouts.isEmpty {
                    ContentUnavailableView(
                        showAllFighters || workoutStore.profiles.count == 1 ? "No Workouts Logged" : "No Workouts for \(workoutStore.activeProfile.name)",
                        systemImage: "heart.text.square",
                        description: Text("Recorded sessions save automatically to On My iPhone / FIGHT.")
                    )
                } else {
                    ForEach(weekGroups, id: \.start) { group in
                        Section {
                            ForEach(group.workouts) { workout in
                                NavigationLink {
                                    WorkoutDetailView(workout: workout)
                                } label: {
                                    workoutRow(workout)
                                }
                            }
                            .onDelete { offsets in
                                let removed = offsets.map { group.workouts[$0] }
                                for w in removed { workoutStore.delete(w) }
                                undo.show(removed.count == 1 ? "Workout deleted" : "\(removed.count) workouts deleted") {
                                    for w in removed { workoutStore.restore(w) }
                                }
                            }
                        } header: {
                            weekHeader(group)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { RecordSwitcher() }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(workoutStore.profiles.count > 1 && !showAllFighters ? workoutStore.activeProfile.name : "Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if workoutStore.profiles.count > 1 {
                            Toggle("Show all fighters", isOn: $showAllFighters)
                        }
                        Picker("Discipline", selection: $selectedFilter) {
                            Text("All disciplines").tag(Optional<WorkoutCategory>.none)
                            ForEach(WorkoutCategory.allCases) { cat in
                                Text(cat.rawValue).tag(Optional(cat))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: selectedFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingRecords = true
                        } label: {
                            Label("Records & Badges", systemImage: "trophy")
                        }
                        Button {
                            showingComparison = true
                        } label: {
                            Label("Compare Sessions", systemImage: "square.stack.3d.up")
                        }
                        .disabled(workoutStore.workouts.count < 2)
                        Button {
                            if let url = workoutStore.exportAllDataArchive() {
                                backupURL = url
                            } else {
                                backupFailed = true
                            }
                        } label: {
                            Label("Export All Data (Backup)", systemImage: "archivebox")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: Binding(
                get: { backupURL.map(ShareableFile.init) },
                set: { if $0 == nil { backupURL = nil } }
            )) { file in
                ShareSheet(items: [file.url])
            }
            .alert("Backup failed", isPresented: $backupFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The backup archive couldn't be created. Try again.")
            }
            .navigationDestination(isPresented: $showingRecords) {
                RecordsView()
            }
            .sheet(isPresented: $showingComparison) {
                ComparisonView(initialBaselineWorkout: workoutStore.workouts.first)
            }
        }
    }

    private func workoutRow(_ workout: SavedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: workout.category.icon)
                    .foregroundStyle(.green)
                Text(workout.displayTitle)
                    .font(.headline)
                Text("• \(workout.drillTag.rawValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                if workout.isCompressedArchive {
                    Image(systemName: "archivebox.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showAllFighters && workoutStore.profiles.count > 1 {
                Label(workout.profileName, systemImage: "person.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(formatDuration(workout.duration), systemImage: "clock")
                if let run = workout.run {
                    Label("\(RouteMath.distanceText(run.distanceM, imperial: run.imperial)) \(run.imperial ? "mi" : "km")",
                          systemImage: "location.fill")
                        .foregroundStyle(.green)
                }
                if workout.hasHeartRate {
                    Label("\(workout.averageBPM) avg", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                }
                Label("\(Int(workout.activeCalories)) act", systemImage: "flame.fill")
                    .foregroundStyle(.orange)
                if let hrr = workout.hrr60Drop {
                    Label("-\(hrr)", systemImage: "arrow.down.heart")
                        .foregroundStyle(.cyan)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
