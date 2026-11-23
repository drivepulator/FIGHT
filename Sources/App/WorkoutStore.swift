import Foundation
import Compression
import UIKit

struct DeletedProfile: Codable, Identifiable {
    var profile: AthleteProfile
    var deletedAt: Date
    var id: UUID { profile.id }
}

struct FoundFighter: Identifiable, Equatable {
    let id: UUID
    let name: String
    let sessions: Int
}

@MainActor
final class WorkoutStore: ObservableObject {
    @Published var workouts: [SavedWorkout] = [] { didSet { dataVersion &+= 1 } }
    @Published var profiles: [AthleteProfile] = [] { didSet { dataVersion &+= 1 } }
    @Published var activeProfileID: UUID {
        didSet {
            dataVersion &+= 1
            saveProfilesToDisk()
        }
    }
    @Published var savedGhostSessions: [GhostSession] = []
    @Published var readinessReadings: [ReadinessReading] = [] { didSet { dataVersion &+= 1 } }
    @Published var weighIns: [WeighIn] = []
    @Published var plans: [TrainingPlan] = []
    @Published var soreness: [SorenessEntry] = [] { didSet { dataVersion &+= 1 } }

    // MARK: Shared coach report (computed once, in the background)

    /// Bumped whenever anything the coach reads changes.
    private var dataVersion = 0
    /// The coach's report and insights for the active fighter. Today, Progress, the fighter card
    /// and story cards all read these instead of each recomputing them on the main thread.
    @Published private(set) var coachReport: CoachReport?
    @Published private(set) var coachInsights = CoachInsights()
    @Published private(set) var coachProfileID: UUID?
    private var coachKey = ""
    private var coachTask: Task<Void, Never>?

    /// The cached report when it's for the active fighter, otherwise computed right now.
    func coachReportNow() -> CoachReport {
        if let r = coachReport, coachProfileID == activeProfileID { return r }
        return CoachEngine.buildReport(workouts: workouts, readings: activeReadings, profile: activeProfile,
                                       resolveSamples: { self.resolvedSamples(for: $0) })
    }

    /// Recomputes the coach report if data changed since the last time (cheap to call often).
    func refreshCoach(force: Bool = false) {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let drills = DrillHistory.load(activeProfileID).count
        let key = "\(activeProfileID)-\(dataVersion)-\(day)-\(drills)"
        guard force || key != coachKey else { return }
        coachKey = key
        let profile = activeProfile
        let all = workouts
        let readings = activeReadings
        let sore = soreness
        let resolve = Self.samplesResolver(archives: archivesDirectory)
        if coachProfileID != profile.id { coachReport = nil }
        coachTask?.cancel()
        coachTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)   // let a burst of edits settle
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                CoachSnapshot(
                    report: CoachEngine.buildReport(workouts: all, readings: readings, profile: profile, resolveSamples: resolve),
                    insights: CoachInsights.build(profile: profile, workouts: all, readings: readings,
                                                  soreness: sore, resolveSamples: resolve))
            }.value
            guard let self, !Task.isCancelled, self.coachKey == key else { return }
            self.coachReport = result.report
            self.coachInsights = result.insights
            self.coachProfileID = profile.id
        }
    }
    /// Recently Deleted.
    @Published var trash: [SavedWorkout] = []
    @Published var deletedProfiles: [DeletedProfile] = []
    // Cached so the Live tab doesn't decompress archives on every BPM-driven redraw.
    /// Built on first use (only when the ghost picker opens) and cleared when sessions change.
    private var cachedGhosts: [GhostSession]?
    private var cachedGhostsProfile: UUID?

    /// Heart-rate samples go to a compressed archive as soon as a session is saved, so the
    /// session list (read at launch) stays tiny and samples load only when needed.
    private let archiveThresholdDays: TimeInterval = 0

    var activeProfile: AthleteProfile {
        get {
            if let found = profiles.first(where: { $0.id == activeProfileID }) {
                return found
            }
            return profiles.first ?? AthleteProfile()
        }
        set {
            var clean = newValue
            clean.sanitize()
            if let old = profiles.first(where: { $0.id == clean.id }) {
                CampCompare.archiveFinishedCamp(old: old, new: &clean)
            }
            if let idx = profiles.firstIndex(where: { $0.id == clean.id }) {
                profiles[idx] = clean
            } else {
                profiles.append(clean)
            }
            scheduleProfileSave()
        }
    }

    private var pendingProfileSave: Task<Void, Never>?

    /// Typing in settings changes the profile on every keystroke; write the file once things settle.
    private func scheduleProfileSave() {
        pendingProfileSave?.cancel()
        pendingProfileSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveProfilesToDisk()
        }
    }

    /// Writes anything still waiting (called when the app goes to the background).
    func flushPendingSaves() {
        guard pendingProfileSave != nil else { return }
        pendingProfileSave?.cancel()
        pendingProfileSave = nil
        saveProfilesToDisk()
    }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var profilesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var profilesFileURL: URL {
        profilesDirectory.appendingPathComponent("fighter_profiles.json")
    }

    var workoutsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Workouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var archivesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("CompressedArchives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var exportsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var ghostsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("GhostOpponents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        self.activeProfileID = UUID()
        loadProfilesFromDisk()
        loadWorkouts()
        loadExternalGhosts()
        runLosslessAutoCompression()
        refreshGhostCache()
        loadReadiness()
        loadWeighIns()
        loadPlans()
        loadSoreness()
        // After everything is loaded, so clean-up never saves a half-loaded list.
        purgeOldTrash()
    }

    private struct ProfileContainer: Codable {
        var activeProfileID: UUID
        var profiles: [AthleteProfile]
        var deleted: [DeletedProfile]?
    }

    /// Same file, read one fighter at a time so one damaged entry doesn't lose the rest.
    private struct LossyProfileContainer: Decodable {
        var activeProfileID: UUID?
        var profiles: [Lossy<AthleteProfile>]
        var deleted: [Lossy<DeletedProfile>]?
    }

    // MARK: Damaged files

    /// Plain-language notes about files that couldn't be read fully. Shown once, then cleared.
    @Published var storageWarnings: [String] = []

    /// Copies a file that couldn't be read aside (next to it, as name.damaged-<date>.ext) before
    /// anything is written over it, and tells the fighter. Nothing is ever lost silently.
    private func keepDamagedCopy(of url: URL, what: String, partly: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = url.deletingPathExtension()
            .appendingPathExtension("damaged-\(stamp)")
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.copyItem(at: url, to: copy)
        let folder = url.deletingLastPathComponent().lastPathComponent
        let place = folder == "Documents" ? "Files › FIGHT" : "Files › FIGHT › \(folder)"
        storageWarnings.append(partly
            ? "Some of your \(what) couldn't be read and were skipped. The original file was kept as \(copy.lastPathComponent) in \(place)."
            : "Your \(what) couldn't be read. The original file was kept as \(copy.lastPathComponent) in \(place), so nothing has been deleted.")
    }

    /// Reads a list file record by record. Records that can't be read are skipped, and if any
    /// are, the original file is copied aside first. Returns nil when there's no file yet.
    private func loadList<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder, what: String) -> [T]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            keepDamagedCopy(of: url, what: what, partly: false)
            return []
        }
        if let all = try? decoder.decode([T].self, from: data) { return all }
        if let lossy = try? decoder.decode([Lossy<T>].self, from: data) {
            let good = lossy.compactMap(\.value)
            keepDamagedCopy(of: url, what: what, partly: !good.isEmpty)
            return good
        }
        keepDamagedCopy(of: url, what: what, partly: false)
        return []
    }

    private func loadProfilesFromDisk() {
        let decoder = JSONDecoder()

        let exists = FileManager.default.fileExists(atPath: profilesFileURL.path)
        let data = try? Data(contentsOf: profilesFileURL)
        if let data, let container = try? decoder.decode(ProfileContainer.self, from: data),
           !container.profiles.isEmpty {
            self.profiles = container.profiles
            self.activeProfileID = container.activeProfileID
            self.deletedProfiles = container.deleted ?? []
            return
        }
        // Damaged file: save every fighter that can still be read, and keep the original.
        if exists {
            let lossy = data.flatMap { try? decoder.decode(LossyProfileContainer.self, from: $0) }
            let good = lossy?.profiles.compactMap(\.value) ?? []
            keepDamagedCopy(of: profilesFileURL, what: "fighter profiles", partly: !good.isEmpty)
            if !good.isEmpty {
                self.profiles = good
                let wanted = lossy?.activeProfileID
                self.activeProfileID = good.contains { $0.id == wanted } ? wanted! : good[0].id
                self.deletedProfiles = lossy?.deleted?.compactMap(\.value) ?? []
                saveProfilesToDisk()
                return
            }
        }

        let defaultFighter = AthleteProfile()
        self.profiles = [defaultFighter]
        self.activeProfileID = defaultFighter.id
        saveProfilesToDisk()
    }

    func saveProfilesToDisk() {
        pendingProfileSave?.cancel()
        pendingProfileSave = nil
        let container = ProfileContainer(activeProfileID: activeProfileID, profiles: profiles, deleted: deletedProfiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(container) {
            try? data.write(to: profilesFileURL, options: .atomic)
        }
    }

    /// Adds a sample fighter with three realistic sessions, a week of morning checks,
    /// weigh-ins and an upcoming fight, so every coach feature has data to show.
    func loadSampleFighter() {
        if let existing = profiles.first(where: { $0.name == SampleData.profileName }) {
            activeProfileID = existing.id
            saveProfilesToDisk()
            return
        }
        let sample = SampleData.make()
        profiles.append(sample.profile)
        activeProfileID = sample.profile.id
        saveProfilesToDisk()
        for w in sample.workouts { save(w) }
        readinessReadings.append(contentsOf: sample.readings)
        readinessReadings.sort { $0.date > $1.date }
        saveReadiness()
        for wi in sample.weighIns { addWeighIn(wi) }
    }

    func addProfile(name: String) {
        var p = AthleteProfile()
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Sparring Partner" : name
        p.sanitize()
        profiles.append(p)
        activeProfileID = p.id
        saveProfilesToDisk()
    }

    func deleteProfile(_ profile: AthleteProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if profile.name == SampleData.profileName {
            // Sample data is removed completely with its profile.
            for w in workouts + trash where w.profileID == profile.id { permanentlyDelete(w) }
            readinessReadings.removeAll { $0.profileID == profile.id }
            saveReadiness()
            weighIns.removeAll { $0.profileID == profile.id }
            saveWeighIns()
        } else {
            // Real fighters go to Recently Deleted with their sessions.
            let now = Date()
            for w in workouts where w.profileID == profile.id {
                var t = w
                t.deletedAt = now
                writeWorkoutMetadata(t)
                trash.insert(t, at: 0)
            }
            workouts.removeAll { $0.profileID == profile.id }
            refreshGhostCache()
            deletedProfiles.insert(DeletedProfile(profile: profile, deletedAt: now), at: 0)
        }
        if activeProfileID == profile.id, let first = profiles.first {
            activeProfileID = first.id
        }
        saveProfilesToDisk()
    }

    func restore(_ deleted: DeletedProfile) {
        deletedProfiles.removeAll { $0.id == deleted.id }
        if !profiles.contains(where: { $0.id == deleted.id }) { profiles.append(deleted.profile) }
        for w in trash where w.profileID == deleted.id { restore(w) }
        activeProfileID = deleted.id
        saveProfilesToDisk()
    }

    /// Removes a deleted fighter and everything they logged, for good.
    func permanentlyDelete(_ deleted: DeletedProfile) {
        let id = deleted.id
        deletedProfiles.removeAll { $0.id == id }
        for w in trash + workouts where w.profileID == id { permanentlyDelete(w) }
        weighIns.removeAll { $0.profileID == id }
        saveWeighIns()
        readinessReadings.removeAll { $0.profileID == id }
        saveReadiness()
        soreness.removeAll { $0.profileID == id }
        saveSoreness()
        setFighterPhoto(nil, for: id)
        saveProfilesToDisk()
    }

    /// Counts shown before deleting a fighter.
    func dataCounts(for profileID: UUID) -> (sessions: Int, weighIns: Int) {
        (workouts.filter { $0.profileID == profileID }.count, weighIns.filter { $0.profileID == profileID }.count)
    }

    /// Sessions whose fighter no longer exists (e.g. a fighter deleted before Recently Deleted existed).
    var foundFighters: [FoundFighter] {
        let known = Set(profiles.map(\.id) + deletedProfiles.map(\.id))
        let orphans = workouts.filter { !known.contains($0.profileID) }
        return Dictionary(grouping: orphans, by: \.profileID).map { id, ws in
            FoundFighter(id: id, name: ws.first?.profileName ?? "Fighter", sessions: ws.count)
        }
        .sorted { $0.sessions > $1.sessions }
    }

    /// Brings back a fighter from their orphaned sessions.
    func restore(_ found: FoundFighter) {
        guard !profiles.contains(where: { $0.id == found.id }) else { return }
        var p = AthleteProfile()
        p.id = found.id
        p.name = found.name
        p.setupDone = true
        if let w = weighIns.first(where: { $0.profileID == found.id }) { p.weightKg = w.weightKg }
        p.sanitize()
        profiles.append(p)
        activeProfileID = p.id
        saveProfilesToDisk()
    }

    func loadWorkouts() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: workoutsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [SavedWorkout] = []
        var unreadable = 0
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let workout = try? decoder.decode(SavedWorkout.self, from: data) {
                loaded.append(workout)
            } else {
                // Moved (never deleted) into Workouts/Unreadable so it's only reported once.
                unreadable += 1
                let dir = workoutsDirectory.appendingPathComponent("Unreadable", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
            }
        }
        if unreadable > 0 {
            // The files stay where they are (nothing is overwritten); just say so.
            storageWarnings.append("\(unreadable) session\(unreadable == 1 ? "" : "s") couldn't be read and \(unreadable == 1 ? "isn't" : "aren't") shown. The file\(unreadable == 1 ? " was" : "s were") kept in Files › FIGHT › Workouts › Unreadable.")
        }
        workouts = loaded.filter { $0.deletedAt == nil }.sorted { $0.startDate > $1.startDate }
        trash = loaded.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Saves a session. Returns false if it couldn't be written (e.g. the phone is full); the
    /// caller then keeps its crash-safety copy so nothing is lost.
    @discardableResult
    func save(_ workout: SavedWorkout) -> Bool {
        var w = workout
        let age = Date().timeIntervalSince(w.startDate)
        if age >= archiveThresholdDays && !w.samples.isEmpty {
            w = compressWorkoutSamples(w)
        }
        let written = writeWorkoutMetadata(w)
        if !written { w = workout }   // keep the heart rate in memory, inside the session
        workouts.removeAll { $0.id == w.id }
        workouts.insert(w, at: 0)
        workouts.sort { $0.startDate > $1.startDate }
        refreshGhostCache()
        return written
    }

    /// Stores the athlete's post-session effort rating (enables session-RPE load).
    func updateRating(workoutID: UUID, rpe: Int, notes: String) {
        guard let idx = workouts.firstIndex(where: { $0.id == workoutID }) else { return }
        var w = workouts[idx]
        w.rpe = min(max(rpe, 1), 10)
        w.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        w.rpeRated = true
        workouts[idx] = w
        writeWorkoutMetadata(w)
    }

    /// Saves what a session was about: technique focus, sparring partner and round scores.
    func updateTags(workoutID: UUID, focus: [String], partner: String?, roundResults: [String]) {
        guard let idx = workouts.firstIndex(where: { $0.id == workoutID }) else { return }
        var w = workouts[idx]
        w.focusTags = focus
        let p = partner?.trimmingCharacters(in: .whitespacesAndNewlines)
        w.partner = (p?.isEmpty ?? true) ? nil : p
        w.roundResults = roundResults
        workouts[idx] = w
        writeWorkoutMetadata(w)
    }

    /// Partners this fighter has sparred with, most recent first.
    func recentPartners(profileID: UUID) -> [String] {
        var seen = Set<String>()
        return workouts.filter { $0.profileID == profileID }.compactMap(\.partner).filter { seen.insert($0).inserted }
    }

    /// Zips the whole Documents folder (workouts, profiles, checks, weigh-ins, exports)
    /// into a single backup file for the share sheet.
    func exportAllDataArchive() -> URL? {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: URL?
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("FIGHT-Backup-\(stamp.string(from: Date())).zip")
        coordinator.coordinate(readingItemAt: documentsDirectory, options: [.forUploading], error: &coordError) { zipURL in
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil {
                result = dest
            }
        }
        return result
    }

    // MARK: - Recently Deleted

    /// Days deleted things are kept before they're gone for good.
    static let trashDays = 30.0

    /// Moves a workout to Recently Deleted. It can be restored for 30 days.
    func delete(_ workout: SavedWorkout) {
        var w = workout
        w.deletedAt = Date()
        writeWorkoutMetadata(w)
        workouts.removeAll { $0.id == w.id }
        trash.removeAll { $0.id == w.id }
        trash.insert(w, at: 0)
        refreshGhostCache()
    }

    /// Puts a workout straight into Recently Deleted (a discarded session).
    func saveToTrash(_ workout: SavedWorkout) {
        var w = workout
        w.deletedAt = Date()
        writeWorkoutMetadata(w)
        trash.removeAll { $0.id == w.id }
        trash.insert(w, at: 0)
    }

    func restore(_ workout: SavedWorkout) {
        var w = workout
        w.deletedAt = nil
        writeWorkoutMetadata(w)
        trash.removeAll { $0.id == w.id }
        workouts.removeAll { $0.id == w.id }
        workouts.append(w)
        workouts.sort { $0.startDate > $1.startDate }
        refreshGhostCache()
    }

    private func purgeOldTrash(now: Date = Date()) {
        let limit = Self.trashDays * 86400
        for w in trash where now.timeIntervalSince(w.deletedAt ?? now) > limit { permanentlyDelete(w) }
        let expired = deletedProfiles.filter { now.timeIntervalSince($0.deletedAt) > limit }
        for d in expired { permanentlyDelete(d) }
    }

    /// Removes a workout and its files for good.
    func permanentlyDelete(_ workout: SavedWorkout) {
        let metaURL = workoutsDirectory.appendingPathComponent("\(workout.id.uuidString).json")
        try? FileManager.default.removeItem(at: metaURL)
        if let archiveName = workout.archiveFileName {
            let archiveURL = archivesDirectory.appendingPathComponent(archiveName)
            try? FileManager.default.removeItem(at: archiveURL)
        }
        try? FileManager.default.removeItem(at: routesDirectory.appendingPathComponent("\(workout.id.uuidString).route"))
        workouts.removeAll { $0.id == workout.id }
        trash.removeAll { $0.id == workout.id }
        refreshGhostCache()
    }

    // MARK: Run routes (compressed, one file per run)

    private var routesDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func saveRoute(_ route: [RoutePoint], for id: UUID) {
        guard route.count >= 2, let raw = try? JSONEncoder().encode(route), let packed = compressLZFSE(raw) else { return }
        try? packed.write(to: routesDirectory.appendingPathComponent("\(id.uuidString).route"), options: .atomic)
    }

    func loadRoute(for id: UUID) -> [RoutePoint] {
        guard let packed = try? Data(contentsOf: routesDirectory.appendingPathComponent("\(id.uuidString).route")),
              let raw = Self.decompressLZFSE(packed) else { return [] }
        return (try? JSONDecoder().decode([RoutePoint].self, from: raw)) ?? []
    }

    func resolvedSamples(for workout: SavedWorkout) -> [HeartRatePoint] {
        if !workout.samples.isEmpty {
            return workout.samples
        }
        guard let archiveName = workout.archiveFileName else { return [] }
        return SampleArchive.load(archivesDirectory.appendingPathComponent(archiveName), id: workout.id)
    }

    /// Resolves samples off the main thread (for background analysis).
    nonisolated static func samplesResolver(archives: URL) -> @Sendable (SavedWorkout) -> [HeartRatePoint] {
        { w in
            if !w.samples.isEmpty { return w.samples }
            guard let name = w.archiveFileName else { return [] }
            return SampleArchive.load(archives.appendingPathComponent(name), id: w.id)
        }
    }

    func runLosslessAutoCompression() {
        let now = Date()
        var didChange = false

        for i in workouts.indices {
            let age = now.timeIntervalSince(workouts[i].startDate)
            if age >= archiveThresholdDays && !workouts[i].isCompressedArchive && !workouts[i].samples.isEmpty {
                workouts[i] = compressWorkoutSamples(workouts[i])
                writeWorkoutMetadata(workouts[i])
                didChange = true
            }
        }
        if didChange {
            objectWillChange.send()
        }
    }

    private func compressWorkoutSamples(_ workout: SavedWorkout) -> SavedWorkout {
        var copy = workout
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let rawJSON = try? encoder.encode(workout.samples),
              let compressed = compressLZFSE(rawJSON) else {
            return workout
        }
        let archiveName = "\(workout.id.uuidString).fpk"
        let archiveURL = archivesDirectory.appendingPathComponent(archiveName)
        do {
            try compressed.write(to: archiveURL, options: .atomic)
        } catch {
            return workout   // couldn't write the archive: keep the samples in the session itself
        }
        SampleArchive.remember(workout.samples, id: workout.id)

        copy.samples = []
        copy.isCompressedArchive = true
        copy.archiveFileName = archiveName
        return copy
    }

    @discardableResult
    private func writeWorkoutMetadata(_ workout: SavedWorkout) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = workoutsDirectory.appendingPathComponent("\(workout.id.uuidString).json")
        guard let data = try? encoder.encode(workout) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func compressLZFSE(_ data: Data) -> Data? {
        return data.withUnsafeBytes { rawBuffer -> Data? in
            guard let srcPtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dstCapacity = max(4096, data.count)
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dstBuffer.deallocate() }
            let written = compression_encode_buffer(dstBuffer, dstCapacity, srcPtr, data.count, nil, COMPRESSION_LZFSE)
            guard written > 0 else { return nil }
            var output = Data()
            var originalSize = UInt32(data.count).littleEndian
            output.append(Data(bytes: &originalSize, count: 4))
            output.append(dstBuffer, count: written)
            return output
        }
    }

    nonisolated static func decompressLZFSE(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        let originalSize = UInt32(littleEndian: data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let payload = data.dropFirst(4)
        let dstCapacity = Int(originalSize) + 1024
        return payload.withUnsafeBytes { rawBuffer -> Data? in
            guard let srcPtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dstBuffer.deallocate() }
            let decodedCount = compression_decode_buffer(dstBuffer, dstCapacity, srcPtr, payload.count, nil, COMPRESSION_LZFSE)
            guard decodedCount > 0 else { return nil }
            return Data(bytes: dstBuffer, count: decodedCount)
        }
    }

    func importTCXGhost(from url: URL) -> GhostSession? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let parsed = TCXStreamParser.parse(data: data, fallbackName: url.deletingPathExtension().lastPathComponent) else {
            return nil
        }

        let dest = ghostsDirectory.appendingPathComponent(url.lastPathComponent)
        try? data.write(to: dest, options: .atomic)
        loadExternalGhosts()
        return parsed
    }

    func loadExternalGhosts() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ghostsDirectory, includingPropertiesForKeys: nil) else { return }
        var ghosts: [GhostSession] = []
        for file in files where file.pathExtension.lowercased() == "tcx" {
            if let data = try? Data(contentsOf: file),
               let session = TCXStreamParser.parse(data: data, fallbackName: file.deletingPathExtension().lastPathComponent) {
                ghosts.append(session)
            }
        }
        savedGhostSessions = ghosts
        refreshGhostCache()
    }

    func allAvailableGhosts() -> [GhostSession] {
        if let cached = cachedGhosts, cachedGhostsProfile == activeProfileID { return cached }
        let built = buildGhosts()
        cachedGhosts = built
        cachedGhostsProfile = activeProfileID
        return built
    }

    private func refreshGhostCache() {
        cachedGhosts = nil
    }

    /// The active fighter's 15 latest sessions plus imported ghosts.
    private func buildGhosts() -> [GhostSession] {
        let me = activeProfileID
        let fromWorkouts = workouts.filter { $0.profileID == me }.prefix(15).map { w -> GhostSession in
            var g = w.toGhostSession()
            if g.samples.isEmpty {
                let resolved = resolvedSamples(for: w)
                g = GhostSession(
                    id: w.id,
                    title: "\(w.category.rawValue) (\(w.startDate.formatted(date: .abbreviated, time: .omitted)))",
                    subtitle: "Avg \(w.averageBPM) • Peak \(w.maxBPM) BPM",
                    samples: resolved,
                    roundStats: w.roundStats,
                    avgBPM: w.averageBPM,
                    peakBPM: w.maxBPM
                )
            }
            return g
        }.filter { !$0.samples.isEmpty }

        return savedGhostSessions + Array(fromWorkouts)
    }

    func exportTCXFile(for workout: SavedWorkout) -> URL {
        let samples = resolvedSamples(for: workout)
        let iso = ISO8601DateFormatter()
        var rawNotes = "\(workout.category.rawValue) - \(workout.drillTag.rawValue) (RPE \(workout.rpe)/10)"
        if !workout.notes.isEmpty {
            rawNotes += " — " + workout.notes
        }
        let notesText = xmlEscape(rawNotes)
        var tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Other">
              <Id>\(iso.string(from: workout.startDate))</Id>
              <Lap StartTime="\(iso.string(from: workout.startDate))">
                <TotalTimeSeconds>\(String(format: "%.1f", workout.duration))</TotalTimeSeconds>
                <Calories>\(Int(workout.calories))</Calories>
                <AverageHeartRateBpm><Value>\(workout.averageBPM)</Value></AverageHeartRateBpm>
                <MaximumHeartRateBpm><Value>\(workout.maxBPM)</Value></MaximumHeartRateBpm>
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
        """
        for pt in samples {
            tcx += """
                      <Trackpoint>
                        <Time>\(iso.string(from: pt.timestamp))</Time>
                        <HeartRateBpm><Value>\(pt.bpm)</Value></HeartRateBpm>
                      </Trackpoint>
            """
        }
        tcx += """
                </Track>
              </Lap>
              <Notes>\(notesText)</Notes>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let safeCategory = workout.category.rawValue.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safeCategory)_\(formatter.string(from: workout.startDate)).tcx"
        let fileURL = exportsDirectory.appendingPathComponent(fileName)
        try? tcx.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Readiness checks

    var readinessFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("Readiness", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("readiness_checks.json")
    }

    private func loadReadiness() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = loadList(ReadinessReading.self, from: readinessFileURL, decoder: decoder, what: "morning checks") else { return }
        readinessReadings = list.sorted { $0.date > $1.date }
    }

    private func saveReadiness() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(readinessReadings) {
            try? data.write(to: readinessFileURL, options: .atomic)
        }
    }

    /// Readiness checks for the active fighter (older checks without a fighter show for everyone).
    var activeReadings: [ReadinessReading] {
        readinessReadings.filter { $0.profileID == nil || $0.profileID == activeProfileID }
    }

    func addReadiness(_ reading: ReadinessReading) {
        var reading = reading
        if reading.profileID == nil { reading.profileID = activeProfileID }
        readinessReadings.insert(reading, at: 0)
        readinessReadings.sort { $0.date > $1.date }
        saveReadiness()
    }

    func deleteReadiness(_ reading: ReadinessReading) {
        readinessReadings.removeAll { $0.id == reading.id }
        saveReadiness()
    }

    // MARK: - Training plans

    var plansFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("Plans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plans.json")
    }

    private func loadPlans() {
        guard let list = loadList(TrainingPlan.self, from: plansFileURL, decoder: PlanTransfer.decoder, what: "training plans") else { return }
        plans = list
    }

    private func savePlans() {
        if let data = try? PlanTransfer.encoder(pretty: true).encode(plans) {
            try? data.write(to: plansFileURL, options: .atomic)
        }
    }

    /// Adds or updates a plan (matched by id).
    /// Puts plans back in a previous order (after an undo).
    func reorderPlans(like order: [TrainingPlan]) {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0) })
        plans.sort { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
        savePlans()
    }

    func upsertPlan(_ plan: TrainingPlan) {
        if let i = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[i] = plan
        } else {
            plans.insert(plan, at: 0)
        }
        savePlans()
    }

    func deletePlan(_ plan: TrainingPlan) {
        plans.removeAll { $0.id == plan.id }
        savePlans()
    }

    func movePlans(from source: IndexSet, to destination: Int) {
        plans.move(fromOffsets: source, toOffset: destination)
        savePlans()
    }

    /// Plan workouts recorded for a given plan, newest first.
    func workouts(forPlan id: UUID) -> [SavedWorkout] {
        workouts.filter { $0.trainingPlanID == id }
    }

    // MARK: - Weigh-ins

    var weighInsFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("WeightCut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("weigh_ins.json")
    }

    private func loadWeighIns() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = loadList(WeighIn.self, from: weighInsFileURL, decoder: decoder, what: "weigh-ins") else { return }
        weighIns = list.sorted { $0.date > $1.date }
    }

    private func saveWeighIns() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(weighIns) {
            try? data.write(to: weighInsFileURL, options: .atomic)
        }
    }

    func addWeighIn(_ entry: WeighIn) {
        weighIns.append(entry)
        weighIns.sort { $0.date > $1.date }
        saveWeighIns()
        syncProfileWeight(profileID: entry.profileID)
    }

    func deleteWeighIn(_ entry: WeighIn) {
        weighIns.removeAll { $0.id == entry.id }
        saveWeighIns()
    }

    /// Keeps the profile's body weight (used for calories and EPOC) equal to the newest weigh-in.
    private func syncProfileWeight(profileID: UUID) {
        guard let newest = weighIns.first(where: { $0.profileID == profileID }),
              let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var p = profiles[idx]
        p.weightKg = newest.weightKg
        p.sanitize()
        profiles[idx] = p
        saveProfilesToDisk()
    }

    // MARK: - Fighter card photo

    /// Bumped when a fighter photo changes, so cards redraw.
    @Published var photoVersion = 0

    private func fighterPhotoURL(_ id: UUID) -> URL {
        let dir = documentsDirectory.appendingPathComponent("Body", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fighter-photo-\(id.uuidString).jpg")
    }

    func fighterPhoto(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: fighterPhotoURL(id).path)
    }

    func setFighterPhoto(_ image: UIImage?, for id: UUID) {
        let url = fighterPhotoURL(id)
        if let image {
            // Keep it light: the card never needs more than ~1200 px.
            let scale = min(1, 1200 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            try? resized.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        photoVersion += 1
    }

    // MARK: - Soreness log

    private var sorenessFileURL: URL {
        let dir = documentsDirectory.appendingPathComponent("Body", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("soreness.json")
    }

    private func loadSoreness() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = loadList(SorenessEntry.self, from: sorenessFileURL, decoder: decoder, what: "soreness notes") else { return }
        soreness = list.sorted { $0.date > $1.date }
    }

    private func saveSoreness() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(soreness) {
            try? data.write(to: sorenessFileURL, options: .atomic)
        }
    }

    func addSoreness(_ entries: [SorenessEntry]) {
        guard !entries.isEmpty else { return }
        soreness.append(contentsOf: entries)
        soreness.sort { $0.date > $1.date }
        saveSoreness()
    }

    func deleteSoreness(_ entry: SorenessEntry) {
        soreness.removeAll { $0.id == entry.id }
        saveSoreness()
    }

    var activeSoreness: [SorenessEntry] {
        SorenessInsights.active(soreness, profileID: activeProfileID)
    }

    func profile(for workout: SavedWorkout) -> AthleteProfile {
        profiles.first { $0.id == workout.profileID } ?? activeProfile
    }

    var savedStorageBytes: Int64 {
        let dirs = [profilesDirectory, workoutsDirectory, archivesDirectory, exportsDirectory, ghostsDirectory]
        var total: Int64 = 0
        for dir in dirs {
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for f in files {
                    if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(sz)
                    }
                }
            }
        }
        return total
    }

    var compressedArchiveCount: Int {
        workouts.filter(\.isCompressedArchive).count
    }
}

final class TCXStreamParser: NSObject, XMLParserDelegate {
    private var samples: [HeartRatePoint] = []
    private var currentElement = ""
    private var currentText = ""
    private var inTrackpoint = false
    private var inHeartRate = false
    private var currentTimestamp: Date?
    private var currentBPM: Int?
    private var firstDate: Date?
    private let iso = ISO8601DateFormatter()
    private let isoFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    static func parse(data: Data, fallbackName: String) -> GhostSession? {
        let delegate = TCXStreamParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard data.count <= 50 * 1024 * 1024, parser.parse(), delegate.samples.count >= 5 else { return nil }

        let bpms = delegate.samples.map(\.bpm)
        let avg = bpms.reduce(0, +) / bpms.count
        let peak = bpms.max() ?? avg
        return GhostSession(
            id: UUID(),
            title: "TCX: \(fallbackName)",
            subtitle: "Avg \(avg) • Peak \(peak) BPM",
            samples: delegate.samples,
            roundStats: [],
            avgBPM: avg,
            peakBPM: peak
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Trackpoint" {
            inTrackpoint = true
            currentTimestamp = nil
            currentBPM = nil
        } else if elementName == "HeartRateBpm" {
            inHeartRate = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inTrackpoint {
            if elementName == "Time" {
                currentTimestamp = isoFractional.date(from: trimmed) ?? iso.date(from: trimmed)
            } else if inHeartRate && elementName == "Value" {
                currentBPM = Int(trimmed)
            } else if elementName == "HeartRateBpm" {
                inHeartRate = false
            } else if elementName == "Trackpoint" {
                // Real heart rates only (and a sane number of points), whatever the file says.
                if let bpm = currentBPM, (30...250).contains(bpm), samples.count < 200_000 {
                    let ts = currentTimestamp ?? Date()
                    if firstDate == nil { firstDate = ts }
                    let elapsed = max(0, ts.timeIntervalSince(firstDate ?? ts))
                    samples.append(HeartRatePoint(timestamp: ts, elapsedSeconds: elapsed, bpm: bpm))
                }
                inTrackpoint = false
            }
        }
    }
}

/// Decompressed heart-rate samples, kept in memory so the same session isn't unpacked
/// again and again (coach report, insights, ghosts, detail view). Safe from any thread.
enum SampleArchive {
    private final class Box { let samples: [HeartRatePoint]; init(_ s: [HeartRatePoint]) { samples = s } }
    private static let cache: NSCache<NSUUID, Box> = {
        let c = NSCache<NSUUID, Box>()
        c.countLimit = 60
        return c
    }()

    static func remember(_ samples: [HeartRatePoint], id: UUID) {
        cache.setObject(Box(samples), forKey: id as NSUUID)
    }

    static func load(_ url: URL, id: UUID) -> [HeartRatePoint] {
        if let hit = cache.object(forKey: id as NSUUID) { return hit.samples }
        guard let compressed = try? Data(contentsOf: url),
              let raw = WorkoutStore.decompressLZFSE(compressed) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let samples = (try? decoder.decode([HeartRatePoint].self, from: raw)) ?? []
        if !samples.isEmpty { remember(samples, id: id) }
        return samples
    }
}

struct CoachSnapshot {
    let report: CoachReport
    let insights: CoachInsights
}
