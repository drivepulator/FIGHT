import SwiftUI
import PhotosUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

// MARK: - Instagram Stories

enum InstagramStories {
    /// Meta app ID required by Instagram for Sharing to Stories.
    static let facebookAppID = "1320411766881372"
    static let backgroundTop = "#2A0A0E"
    static let backgroundBottom = "#000000"

    private static var url: URL? { URL(string: "instagram-stories://share?source_application=\(facebookAppID)") }

    @MainActor
    static var isAvailable: Bool {
        guard let url else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Sends the card to Instagram as a movable sticker, over FIGHT's colours or the athlete's own photo or video.
    @MainActor
    static func share(sticker: UIImage, background: StoryBackground) -> Bool {
        guard let url, UIApplication.shared.canOpenURL(url), let png = sticker.pngData() else { return false }
        var item: [String: Any] = [
            "com.instagram.sharedSticker.stickerImage": png,
            "com.instagram.sharedSticker.appID": facebookAppID
        ]
        switch background {
        case .plain:
            item["com.instagram.sharedSticker.backgroundTopColor"] = backgroundTop
            item["com.instagram.sharedSticker.backgroundBottomColor"] = backgroundBottom
        case .photo(let image):
            guard let jpg = image.jpegData(compressionQuality: 0.9) else { return false }
            item["com.instagram.sharedSticker.backgroundImage"] = jpg
        case .video(let movieURL, _):
            guard let data = try? Data(contentsOf: movieURL) else { return false }
            item["com.instagram.sharedSticker.backgroundVideo"] = data
        }
        UIPasteboard.general.setItems([item], options: [.expirationDate: Date().addingTimeInterval(300)])
        UIApplication.shared.open(url)
        return true
    }
}

enum StoryBackground {
    case plain
    case photo(UIImage)
    /// The movie file and its first frame (for the preview and brightness check).
    case video(URL, UIImage?)

    var previewImage: UIImage? {
        switch self {
        case .plain: return nil
        case .photo(let i): return i
        case .video(_, let frame): return frame
        }
    }

    /// True when the picture is bright enough that white text would be hard to read.
    var isBright: Bool {
        guard let image = previewImage, let ci = CIImage(image: image) else { return false }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        guard let out = filter?.outputImage else { return false }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(out, toBitmap: &px, rowBytes: 4,
                                                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                                  format: .RGBA8, colorSpace: nil)
        let lum = (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255
        return lum > 0.6
    }
}

/// A video picked from the camera roll, copied somewhere we can read it.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("story-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

// MARK: - Card data

enum StoryCardKind: String, CaseIterable, Identifiable {
    case route, splits, roadwork, mainEvent, rounds, tape, poster, overlay, profile, fighter, progress, record, countdown
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainEvent: return "Main Event"
        case .rounds: return "Round by Round"
        case .tape: return "Tale of the Tape"
        case .poster: return "Fight Poster"
        case .overlay: return "Overlay"
        case .profile: return "Fighter Card"
        case .fighter: return "Fight Fitness"
        case .progress: return "Progress"
        case .record: return "Record"
        case .countdown: return "Countdown"
        case .route: return "Route"
        case .splits: return "Splits"
        case .roadwork: return "Roadwork"
        }
    }

    /// Stickers without a card behind them, made to sit on your own photo or video.
    var isTransparent: Bool { self == .overlay || self == .route || self == .splits }
}

struct StoryPrivacy {
    var hideName: Bool
    var hideWeight: Bool
    var onlyImprovements: Bool
    /// Leave the first and last ~200 m off shared routes (where you live or train).
    var hideRouteEnds = true
}

typealias StoryStat = (value: String, label: String, good: Bool)

/// Everything the cards show, computed once when the share screen opens.
struct StoryData {
    var name: String
    var profile = AthleteProfile()
    var photo: UIImage?
    var cardStats = FighterCardStats()
    var workout: SavedWorkout?
    var comparison: SavedWorkout?
    var workoutRecords: [PersonalRecord] = []
    var coachLine: String?
    var report: CoachReport?
    var gasTank: String?
    var benchmark: [Benchmark.Attempt] = []
    var latestRecord: PersonalRecord?
    var fightDate: Date?
    var campWeek: (index: Int, total: Int, title: String)?
    var kgToGo: Double?
    var useImperial = false
    var weekSessions = 0
    var monthSessions = 0
    var monthRounds = 0
    var monthMinutes = 0
    var recoveryChange: Int?
    var route: [RoutePoint] = []

    @MainActor
    static func build(store: WorkoutStore, workout: SavedWorkout?) -> StoryData {
        let profile = store.activeProfile
        let mine = store.workouts.filter { $0.profileID == profile.id }
        var d = StoryData(name: profile.name)
        d.profile = profile
        d.photo = store.fighterPhoto(for: profile.id)
        d.cardStats = FighterCardStats.current(store: store, profile: profile)
        d.report = store.coachReportNow()
        d.gasTank = GasTank.evaluate(workouts: mine, profile: profile)?.headline
        if let workout {
            d.workout = workout
            if workout.run != nil { d.route = store.loadRoute(for: workout.id) }
            let owner = store.profile(for: workout)
            d.name = owner.name
            d.workoutRecords = Records.newRecords(in: workout, workouts: store.workouts, profile: owner)
            d.comparison = comparableSession(for: workout, in: store.workouts)
            if let r = d.workoutRecords.first {
                d.coachLine = "New record: \(r.title.lowercased()), \(r.valueText)."
            } else if let t = CoachEngine.review(workout: workout, profile: owner, history: store.workouts).takeaways.first {
                d.coachLine = t
            } else {
                d.coachLine = d.gasTank
            }
        }
        d.benchmark = Benchmark.attempts(mine)
        d.latestRecord = Records.all(workouts: store.workouts, profile: profile).max { $0.date < $1.date }
        d.useImperial = profile.useImperial
        if let fight = profile.fightDate, fight > Date() {
            d.fightDate = fight
            d.kgToGo = max(0, (store.weighIns.first { $0.profileID == profile.id }?.weightKg ?? profile.weightKg) - profile.targetFightWeightKg)
            if let plan = CampPlanner.buildPlan(profile: profile, workouts: store.workouts),
               let week = plan.currentWeek, let i = plan.weeks.firstIndex(where: { $0.start == week.start }) {
                d.campWeek = (i + 1, plan.weeks.count, week.title)
            }
        }
        let now = Date()
        d.weekSessions = mine.filter { now.timeIntervalSince($0.startDate) < 7 * 86400 }.count
        let thisMonth = mine.filter { now.timeIntervalSince($0.startDate) < 30 * 86400 }
        let lastMonth = mine.filter { (30 * 86400..<60 * 86400).contains(now.timeIntervalSince($0.startDate)) }
        d.monthSessions = thisMonth.count
        d.monthRounds = thisMonth.reduce(0) { $0 + $1.roundStats.count }
        d.monthMinutes = Int(thisMonth.reduce(0) { $0 + $1.duration } / 60)
        let rNow = thisMonth.compactMap(\.avgInterRoundDrop)
        let rThen = lastMonth.compactMap(\.avgInterRoundDrop)
        if !rNow.isEmpty, !rThen.isEmpty {
            d.recoveryChange = rNow.reduce(0, +) / rNow.count - rThen.reduce(0, +) / rThen.count
        }
        return d
    }

    /// The same kind of session about 4 weeks earlier (3 to 8 weeks), for the tale of the tape.
    static func comparableSession(for w: SavedWorkout, in all: [SavedWorkout]) -> SavedWorkout? {
        let target = 28.0 * 86400
        return all.filter { o in
            let gap = w.startDate.timeIntervalSince(o.startDate)
            return o.id != w.id && o.profileID == w.profileID && o.category == w.category
                && gap >= 21 * 86400 && gap <= 56 * 86400
        }
        .min { a, b in
            abs(w.startDate.timeIntervalSince(a.startDate) - target) < abs(w.startDate.timeIntervalSince(b.startDate) - target)
        }
    }

    /// Cards that have something worth sharing right now.
    var availableKinds: [StoryCardKind] {
        var k: [StoryCardKind] = []
        if let run = workout?.run {
            if route.count >= 2 { k.append(.route) }
            if run.splits.count >= 2 { k.append(.splits) }
            k.append(.roadwork)
        }
        // Heart-rate cards only when a strap was worn (a "0 BPM peak" card helps nobody).
        if let w = workout, w.hasHeartRate {
            k.append(.mainEvent)
            if w.roundStats.count >= 2 { k.append(.rounds) }
            if comparison?.hasHeartRate == true { k.append(.tape) }
            k.append(.poster)
            k.append(.overlay)
        }
        k.append(.profile)
        if report?.fightFitness != nil { k.append(.fighter) }
        k.append(.progress)
        if latestRecord != nil || !workoutRecords.isEmpty { k.append(.record) }
        if fightDate != nil { k.append(.countdown) }
        return k
    }
}

/// Small shared numbers for a workout.
private extension SavedWorkout {
    var bestRecovery: Int? { (roundStats.compactMap(\.stoolDropBPM) + autoHRREvents.map(\.dropBPM)).max() }
    var workMinutes: Int {
        let rounds = roundStats.reduce(0.0) { $0 + ($1.endElapsed - $1.startElapsed) }
        return Int((rounds > 0 ? rounds : duration) / 60)
    }
    var roundLength: String? {
        guard !roundStats.isEmpty else { return nil }
        let s = Int(roundStats.map { $0.endElapsed - $0.startElapsed }.reduce(0, +) / Double(roundStats.count))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
    var headline: String {
        if let len = roundLength { return "\(roundStats.count) rounds × \(len)" }
        return "\(Int(duration / 60)) min"
    }
}

// MARK: - Broadcast building blocks

private let broadcastRed = Color(red: 0.91, green: 0.15, blue: 0.18)
private let panelBlack = Color(red: 0.05, green: 0.055, blue: 0.07)
private let coachGrey = Color(red: 0.11, green: 0.12, blue: 0.145)
private let improveGreen = Color(red: 0.49, green: 0.88, blue: 0.63)

private func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.compressed) }
private func condensed(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight).width(.condensed) }

private struct SlantShape: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - 10, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// Slanted red name tab that sits on top of a broadcast panel.
private struct BroadcastTab: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.white).frame(width: 7, height: 7)
            Text(text.uppercased()).font(condensed(19, .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.leading, 13)
        .padding(.trailing, 23)
        .padding(.vertical, 5)
        .background(broadcastRed, in: SlantShape())
        .foregroundStyle(.white)
    }
}

private struct BroadcastSignature: View {
    let left: String
    var body: some View {
        HStack {
            Text(left.uppercased())
            Spacer()
            Text("COACHED BY FIGHT")
        }
        .font(condensed(12, .bold))
        .tracking(0.5)
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
        .background(broadcastRed)
    }
}

private struct StatStrip: View {
    let stats: [StoryStat]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.value).font(heavy(28)).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(s.good ? Color(red: 0.1, green: 0.55, blue: 0.3) : panelBlack)
                    Text(s.label).font(condensed(12, .medium)).foregroundStyle(panelBlack.opacity(0.75)).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if i < stats.count - 1 { Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1) }
                }
            }
        }
        .background(Color.white)
    }
}

private struct CoachStrip: View {
    let text: String
    var body: some View {
        (Text("COACH  ").foregroundColor(broadcastRed).font(condensed(14, .bold)) + Text(text).font(condensed(14, .medium)))
            .foregroundStyle(.white)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(coachGrey)
    }
}

/// The standard broadcast panel: tab, big number, three stats, coach line, signature.
private struct BroadcastPanel: View {
    let tab: String
    let big: String
    let unit: String
    let sub: String
    let stats: [StoryStat]
    let coach: String?
    let signature: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BroadcastTab(text: tab)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(big).font(heavy(76)).lineLimit(1).minimumScaleFactor(0.5)
                    Text(unit.uppercased()).font(heavy(26)).foregroundStyle(broadcastRed).lineLimit(1).minimumScaleFactor(0.6)
                }
                Text(sub).font(condensed(15, .medium)).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelBlack)
            .overlay(alignment: .leading) { Rectangle().fill(broadcastRed).frame(width: 6) }
            if !stats.isEmpty { StatStrip(stats: stats) }
            if let coach { CoachStrip(text: coach) }
            BroadcastSignature(left: signature)
        }
    }
}

// MARK: - The cards

/// The sticker itself: what gets sent to Instagram.
struct StoryCard: View {
    let kind: StoryCardKind
    let data: StoryData
    let privacy: StoryPrivacy
    var overlayOneLine = false
    var darkInk = false

    private var displayName: String { privacy.hideName || data.name.isEmpty ? "FIGHT" : data.name }

    var body: some View {
        content
            .frame(width: 320)
            .shadow(color: kind.isTransparent ? .clear : .black.opacity(0.4), radius: 14, y: 8)
            .padding(kind.isTransparent ? 4 : 16)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .mainEvent: mainEvent
        case .rounds: rounds
        case .tape: tape
        case .poster: PosterCard(data: data, privacy: privacy)
        case .overlay: OverlayCard(data: data, oneLine: overlayOneLine, dark: darkInk)
        case .profile: FighterProfileCard(profile: data.profile, photo: data.photo, stats: data.cardStats, hideName: privacy.hideName)
        case .fighter: fighter
        case .progress: progress
        case .record: record
        case .countdown: countdown
        case .route, .splits, .roadwork: RunSticker(kind: kind, data: data, dark: darkInk, hideName: privacy.hideName,
                                                    hideRouteEnds: privacy.hideRouteEnds)
        }
    }

    /// "Ready for 5×3" -> "5×3"
    private static func gasShort(_ s: String?) -> String? {
        guard let s, s.hasPrefix("Ready for ") else { return nil }
        return String(s.dropFirst("Ready for ".count))
    }

    // Main event

    @ViewBuilder
    private var mainEvent: some View {
        if let w = data.workout {
            BroadcastPanel(
                tab: "\(displayName) · \(w.category.rawValue)",
                big: "\(w.maxBPM)", unit: "BPM peak",
                sub: "\(w.headline) · \(Int(w.duration / 60)) min",
                stats: mainStats(w),
                coach: data.coachLine, signature: w.startDate.formatted(.dateTime.day().month()))
        }
    }

    private func mainStats(_ w: SavedWorkout) -> [StoryStat] {
        var s: [StoryStat] = []
        s.append(w.strikesCuedCount > 0 ? ("\(w.strikesCuedCount)", "strikes", false) : ("\(w.averageBPM)", "avg BPM", false))
        s.append(w.bestRecovery.map { ("−\($0)", "recovery", false) } ?? ("\(w.workMinutes)′", "work", false))
        s.append(Self.gasShort(data.gasTank).map { ($0, "gas tank", false) } ?? ("\(Int(w.effectiveLoad))", "load", false))
        return s
    }

    // Round by round

    @ViewBuilder
    private var rounds: some View {
        if let w = data.workout {
            let rs = Array(w.roundStats.sorted { $0.roundNumber < $1.roundNumber }.prefix(8))
            let lo = Double((rs.map(\.avgBPM).min() ?? 100) - 20)
            let hi = Double(max(rs.map(\.avgBPM).max() ?? 200, Int(lo) + 1))
            let peakRound = rs.max { $0.avgBPM < $1.avgBPM }?.roundNumber
            VStack(alignment: .leading, spacing: 0) {
                BroadcastTab(text: "Round by round")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Avg heart rate per round")
                        Spacer()
                        Text(w.headline)
                    }
                    .font(condensed(14, .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(rs, id: \.roundNumber) { r in
                            VStack(spacing: 3) {
                                Text("\(r.avgBPM)").font(heavy(17)).foregroundStyle(.white)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(r.roundNumber == peakRound ? broadcastRed : Color.white)
                                    .frame(height: max(10, CGFloat((Double(r.avgBPM) - lo) / (hi - lo)) * 92))
                                Text(r.stoolDropBPM.map { "−\($0)" } ?? " ")
                                    .font(condensed(14, .bold)).foregroundStyle(improveGreen)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 140, alignment: .bottom)
                    Text("Green: beats recovered in each rest").font(condensed(12)).foregroundStyle(.white.opacity(0.65))
                }
                .padding(14)
                .background(panelBlack)
                if let coach = data.coachLine { CoachStrip(text: coach) }
                BroadcastSignature(left: displayName)
            }
        }
    }

    // Tale of the tape

    private struct TapeRow {
        let label: String
        let today: String
        let before: String
        let better: Bool
    }

    private func tapeRows(_ w: SavedWorkout, _ o: SavedWorkout) -> [TapeRow] {
        let rows = [
            TapeRow(label: "PEAK BPM", today: "\(w.maxBPM)", before: "\(o.maxBPM)", better: false),
            TapeRow(label: "RECOVERY", today: w.bestRecovery.map { "−\($0)" } ?? "–", before: o.bestRecovery.map { "−\($0)" } ?? "–",
                    better: (w.bestRecovery ?? 0) > (o.bestRecovery ?? 0)),
            TapeRow(label: "STRIKES", today: "\(w.strikesCuedCount)", before: "\(o.strikesCuedCount)", better: w.strikesCuedCount > o.strikesCuedCount),
            TapeRow(label: "WORK", today: "\(w.workMinutes)′", before: "\(o.workMinutes)′", better: w.workMinutes > o.workMinutes)
        ]
        return privacy.onlyImprovements ? rows.filter { $0.better || $0.label == "PEAK BPM" } : rows
    }

    @ViewBuilder
    private var tape: some View {
        if let w = data.workout, let o = data.comparison {
            let weeks = max(1, Int((w.startDate.timeIntervalSince(o.startDate) / (7 * 86400)).rounded()))
            let rows = tapeRows(w, o)
            VStack(alignment: .leading, spacing: 0) {
                BroadcastTab(text: "Tale of the tape")
                HStack {
                    Text("TODAY")
                    Spacer()
                    Text("\(weeks) WEEKS AGO").foregroundStyle(.white.opacity(0.75))
                }
                .font(condensed(14, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(coachGrey)
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 0) {
                        Text(row.today).font(heavy(30)).foregroundStyle(row.better ? improveGreen : Color.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.label).font(condensed(12, .bold)).foregroundStyle(.white)
                            .frame(width: 92).padding(.vertical, 9).background(broadcastRed)
                        Text(row.before).font(heavy(30)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .background(i % 2 == 0 ? Color(red: 0.085, green: 0.09, blue: 0.11) : panelBlack)
                }
                BroadcastSignature(left: displayName)
            }
        }
    }

    // Fighter

    @ViewBuilder
    private var fighter: some View {
        if let report = data.report {
            BroadcastPanel(
                tab: "\(displayName) · fight fitness",
                big: report.fightFitness.map(String.init) ?? "--", unit: "/ 100",
                sub: "Rated from my heart-rate data",
                stats: report.metrics.prefix(3).map { m -> StoryStat in (m.score.map(String.init) ?? "--", m.title.lowercased(), false) },
                coach: data.gasTank, signature: Date().formatted(.dateTime.day().month()))
        }
    }

    // Progress

    private var benchmarkImproved: Bool {
        guard let f = data.benchmark.first, let l = data.benchmark.last else { return false }
        return l.averageWorkHR < f.averageWorkHR
    }

    @ViewBuilder
    private var progress: some View {
        if data.benchmark.count >= 2, let first = data.benchmark.first, let last = data.benchmark.last,
           !privacy.onlyImprovements || benchmarkImproved {
            let diff = last.averageWorkHR - first.averageWorkHR
            BroadcastPanel(
                tab: "\(displayName) · benchmark",
                big: diff <= 0 ? "−\(-diff)" : "+\(diff)", unit: "BPM",
                sub: "Same 5 × 3 min work as my first test",
                stats: [("\(data.benchmark.count)", "tests", false),
                        ("\(last.averageWorkHR)", "avg BPM now", false),
                        (last.averageRecovery.map { "−\($0)" } ?? "–", "recovery", (last.averageRecovery ?? 0) > (first.averageRecovery ?? 0))],
                coach: "Lower heart rate on the same work means I'm fitter.",
                signature: "since \(first.date.formatted(.dateTime.day().month()))")
        } else {
            BroadcastPanel(tab: "\(displayName) · last 30 days", big: "\(data.monthSessions)", unit: "sessions",
                           sub: "Tracked with heart rate", stats: monthStats, coach: data.gasTank,
                           signature: Date().formatted(.dateTime.day().month()))
        }
    }

    private var monthStats: [StoryStat] {
        var stats: [StoryStat] = [
            ("\(data.monthRounds)", "rounds", false),
            ("\(data.monthMinutes / 60)h \(data.monthMinutes % 60)m", "training", false)
        ]
        if let c = data.recoveryChange, !privacy.onlyImprovements || c > 0 {
            stats.append((String(format: "%+d", c), "recovery", c > 0))
        } else if let f = data.report?.fightFitness {
            stats.append(("\(f)", "fight fitness", false))
        }
        return stats
    }

    // Record

    @ViewBuilder
    private var record: some View {
        let records = data.workoutRecords.isEmpty ? (data.latestRecord.map { [$0] } ?? []) : data.workoutRecords
        if let r = records.first {
            let parts = r.valueText.split(separator: " ", maxSplits: 1).map(String.init)
            BroadcastPanel(
                tab: records.count > 1 ? "\(records.count) new records" : "New personal record",
                big: parts.first ?? r.valueText, unit: parts.count > 1 ? parts[1] : "",
                sub: r.title,
                stats: records.dropFirst().prefix(3).map { x -> StoryStat in
                    (x.valueText.split(separator: " ").first.map(String.init) ?? x.valueText, x.title.lowercased(), true)
                },
                coach: nil, signature: displayName)
        }
    }

    // Countdown

    @ViewBuilder
    private var countdown: some View {
        if let fight = data.fightDate {
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: fight)).day ?? 0
            BroadcastPanel(tab: "\(displayName) · fight camp", big: "\(days)", unit: days == 1 ? "day" : "days",
                           sub: "until fight night · \(fight.formatted(.dateTime.day().month()))",
                           stats: countdownStats, coach: data.campWeek.map { "\($0.title) of camp." }, signature: "fight night")
        }
    }

    private var countdownStats: [StoryStat] {
        var stats: [StoryStat] = []
        if let w = data.campWeek { stats.append(("\(w.index)/\(w.total)", "camp week", false)) }
        if let r = data.report?.readiness.score { stats.append(("\(r)", "readiness", false)) }
        if !privacy.hideWeight, let kg = data.kgToGo {
            stats.append(kg < 0.05 ? ("ON", "weight", false)
                                   : (WeightUnits.number(kg, data.useImperial), "\(WeightUnits.unit(data.useImperial)) to cut", false))
        } else {
            stats.append(("\(data.weekSessions)", "sessions this week", false))
        }
        return stats
    }
}

// MARK: - Fight poster

private struct PosterCard: View {
    let data: StoryData
    let privacy: StoryPrivacy
    private let paper = Color(red: 0.945, green: 0.92, blue: 0.88)
    private let ink = Color(red: 0.08, green: 0.07, blue: 0.07)

    var body: some View {
        if let w = data.workout {
            VStack(spacing: 0) {
                HStack {
                    (Text("FIGHT").foregroundColor(broadcastRed) + Text(" PRESENTS"))
                    Spacer()
                    Text(w.startDate.formatted(.dateTime.weekday(.abbreviated).day().month()).uppercased())
                }
                .font(condensed(13, .medium))
                .tracking(0.6)
                .foregroundStyle(paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(ink)

                Text("★  MAIN EVENT  ★").font(condensed(14, .bold)).tracking(2).foregroundStyle(broadcastRed).padding(.top, 12)
                Text((privacy.hideName || data.name.isEmpty ? w.category.rawValue : data.name).uppercased())
                    .font(heavy(58)).lineLimit(1).minimumScaleFactor(0.4).foregroundStyle(ink).padding(.horizontal, 14)
                HStack(spacing: 8) {
                    Rectangle().fill(ink).frame(height: 2)
                    Text("\(w.headline) of \(w.category.rawValue)".uppercased())
                        .font(condensed(12, .medium)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
                    Rectangle().fill(ink).frame(height: 2)
                }
                .padding(.horizontal, 18)
                .padding(.top, 2)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(w.maxBPM)").font(heavy(54))
                    Text("PEAK BPM").font(condensed(16, .bold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 6)
                .background(broadcastRed)
                .rotationEffect(.degrees(-3))
                .padding(.horizontal, -8)
                .padding(.top, 12)

                HStack(spacing: 0) {
                    posterStat(w.strikesCuedCount > 0 ? "\(w.strikesCuedCount)" : "\(w.averageBPM)", w.strikesCuedCount > 0 ? "STRIKES" : "AVG BPM")
                    Rectangle().fill(ink).frame(width: 2, height: 38)
                    posterStat(w.bestRecovery.map { "−\($0)" } ?? "\(w.roundStats.count)", w.bestRecovery != nil ? "BPM IN 60 S" : "ROUNDS")
                    Rectangle().fill(ink).frame(width: 2, height: 38)
                    posterStat("\(w.workMinutes)′", "OF WORK")
                }
                .padding(.top, 16)
                .padding(.horizontal, 10)

                if let c = data.coachLine {
                    Text("“\(c)”").font(condensed(14, .medium)).italic().foregroundStyle(ink)
                        .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 18).padding(.top, 8)
                }
                (Text("COACHED BY ") + Text("FIGHT").foregroundColor(broadcastRed))
                    .font(condensed(12, .medium)).tracking(1).foregroundStyle(paper)
                    .frame(maxWidth: .infinity).padding(.vertical, 6).background(ink).padding(.top, 12)
            }
            .background(alignment: .bottomTrailing) { Halftone().foregroundStyle(ink.opacity(0.14)) }
            .background(paper)
            .clipped()
        }
    }

    private func posterStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(heavy(30)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(condensed(11, .medium)).foregroundStyle(ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Printed halftone dots, densest in the bottom-right corner.
private struct Halftone: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 7
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    let t = max(0, (x / size.width + y / size.height) - 0.9)
                    let r = min(step * 0.45, t * step * 0.9)
                    if r > 0.3 {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .foreground)
                    }
                    x += step
                }
                y += step
            }
        }
    }
}

// MARK: - See-through overlay

private struct OverlayCard: View {
    let data: StoryData
    let oneLine: Bool
    let dark: Bool

    private var ink: Color { dark ? Color(white: 0.08) : .white }
    private var glow: Color { dark ? .white.opacity(0.55) : .black.opacity(0.45) }

    var body: some View {
        if let w = data.workout {
            Group {
                if oneLine {
                    VStack(spacing: 14) {
                        HStack(alignment: .bottom) {
                            stat("Peak", "\(w.maxBPM)", size: 34)
                            Spacer()
                            stat(w.strikesCuedCount > 0 ? "Strikes" : "Time",
                                 w.strikesCuedCount > 0 ? "\(w.strikesCuedCount)" : "\(Int(w.duration / 60))′", size: 34)
                            Spacer()
                            stat(w.bestRecovery != nil ? "Recovery" : "Avg",
                                 w.bestRecovery.map { "−\($0)" } ?? "\(w.averageBPM)", size: 34)
                        }
                        logo
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        logo
                        Text("\(w.category.rawValue) · \(w.headline)").font(.system(size: 15, weight: .regular))
                        stat("Peak heart rate", "\(w.maxBPM)", unit: "bpm", size: 44)
                        if w.strikesCuedCount > 0 { stat("Strikes", "\(w.strikesCuedCount)", size: 44) }
                        if let r = w.bestRecovery { stat("Recovery", "−\(r)", unit: "bpm / 60 s", size: 44) }
                        stat("Time", "\(Int(w.duration / 60))", unit: "min", size: 44)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(ink)
            .shadow(color: glow, radius: 8)
        }
    }

    private var logo: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.boxing").font(.system(size: 17, weight: .semibold))
            Text("FIGHT").font(heavy(22)).tracking(2)
        }
    }

    private func stat(_ label: String, _ value: String, unit: String? = nil, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 14, weight: .regular)).opacity(0.85)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: size, weight: .light)).monospacedDigit()
                if let unit { Text(unit).font(.system(size: 16, weight: .regular)) }
            }
        }
    }
}

// MARK: - Run stickers

/// Three run stickers, Strava-clean:
/// - Route: the line of your run over your own photo, with distance, time and pace.
/// - Splits: km-by-km bars with the fastest one lit.
/// - Roadwork: the fighter version, with Zone 2 share (what a fight coach wants from a run).
private struct RunSticker: View {
    let kind: StoryCardKind
    let data: StoryData
    let dark: Bool
    let hideName: Bool
    var hideRouteEnds = true

    private var ink: Color { dark ? Color(white: 0.08) : .white }
    /// The route as shared: with the privacy zone applied.
    private var shownRoute: [RoutePoint] { hideRouteEnds ? RouteMath.trimEnds(data.route) : data.route }
    private var glow: Color { dark ? .white.opacity(0.5) : .black.opacity(0.45) }

    var body: some View {
        if let w = data.workout, let run = w.run {
            switch kind {
            case .route: route(run)
            case .splits: splits(run)
            default: roadwork(w, run)
            }
        }
    }

    private func unit(_ run: RunSummary) -> String { run.imperial ? "mi" : "km" }

    private func route(_ run: RunSummary) -> some View {
        VStack(spacing: 14) {
            if shownRoute.count >= 2 {
                RouteShape(points: RouteMath.normalized(shownRoute))
                    .stroke(ink, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: 190, height: 190)
            }
            HStack(alignment: .bottom, spacing: 26) {
                figure("Distance", RouteMath.distanceText(run.distanceM, imperial: run.imperial), unit(run))
                figure("Time", runClock(run.movingSeconds), nil)
                figure("Pace", RouteMath.paceText(run.avgPace), "/\(unit(run))")
            }
            mark
        }
        .foregroundStyle(ink)
        .shadow(color: glow, radius: 8)
        .frame(maxWidth: .infinity)
    }

    private func splits(_ run: RunSummary) -> some View {
        let paces = run.splits.map { $0.pace(unit: run.unitMeters) }
        let fastest = paces.min() ?? 0, slowest = paces.max() ?? 1
        let best = run.splits.first { $0.pace(unit: run.unitMeters) == fastest }
        return VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(run.splits) { s in
                    let p = s.pace(unit: run.unitMeters)
                    let h = slowest > fastest ? 0.35 + 0.65 * (slowest - p) / (slowest - fastest) : 1
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(p == fastest ? broadcastRed : ink.opacity(0.75))
                            .frame(height: 110 * h)
                        Text("\(s.index)").font(.system(size: 11, weight: .semibold)).opacity(0.85)
                    }
                    .frame(maxWidth: 26)
                }
            }
            .frame(height: 130, alignment: .bottom)
            if let best {
                Text("Fastest \(unit(run)) \(best.index) · \(RouteMath.paceText(fastest))")
                    .font(.system(size: 17, weight: .semibold))
            }
            Text("\(RouteMath.distanceText(run.distanceM, imperial: run.imperial)) \(unit(run)) · \(RouteMath.paceText(run.avgPace)) /\(unit(run)) avg")
                .font(.system(size: 14)).opacity(0.85)
            mark
        }
        .foregroundStyle(ink)
        .shadow(color: glow, radius: 8)
        .frame(maxWidth: .infinity)
    }

    private func roadwork(_ w: SavedWorkout, _ run: RunSummary) -> some View {
        let total = w.zoneSeconds.values.reduce(0, +)
        let zone2 = total > 60 ? Int((w.zoneSeconds[2, default: 0] / total * 100).rounded()) : nil
        return VStack(alignment: .leading, spacing: 0) {
            BroadcastTab(text: hideName || data.name.isEmpty ? "Roadwork" : "\(data.name) · Roadwork")
            VStack(alignment: .leading, spacing: 10) {
                if shownRoute.count >= 2 {
                    RouteShape(points: RouteMath.normalized(shownRoute))
                        .stroke(broadcastRed, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(RouteMath.distanceText(run.distanceM, imperial: run.imperial)).font(heavy(64))
                    Text(unit(run).uppercased()).font(heavy(24)).foregroundStyle(broadcastRed)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(RouteMath.paceText(run.avgPace)).font(heavy(30))
                        Text("PACE /\(unit(run).uppercased())").font(condensed(12, .medium)).opacity(0.75)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(panelBlack)
            .overlay(alignment: .leading) { Rectangle().fill(broadcastRed).frame(width: 6) }
            StatStrip(stats: [
                (runClock(run.movingSeconds), "MOVING", false),
                (zone2.map { "\($0)%" } ?? "–", "ZONE 2", (zone2 ?? 0) >= 70),
                (w.hasHeartRate ? "\(w.averageBPM)" : "–", "AVG BPM", false)
            ])
            BroadcastSignature(left: w.startDate.formatted(.dateTime.day().month()))
        }
    }

    private func figure(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 13)).opacity(0.85)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 30, weight: .light)).monospacedDigit()
                if let unit { Text(unit).font(.system(size: 13)) }
            }
        }
    }

    private var mark: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.boxing").font(.system(size: 15, weight: .semibold))
            Text("FIGHT").font(heavy(19)).tracking(2)
        }
    }
}

// MARK: - Share screen

struct StoryShareSheet: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    let focus: StoryCardKind
    var workout: SavedWorkout? = nil

    @AppStorage("fight.story.hideName") private var hideName = false
    @AppStorage("fight.story.hideWeight") private var hideWeight = true
    @AppStorage("fight.story.onlyImprovements") private var onlyImprovements = true
    @AppStorage("fight.story.hideRouteEnds") private var hideRouteEnds = true
    @AppStorage("fight.story.overlayOneLine") private var overlayOneLine = false

    private enum BackgroundChoice: String, CaseIterable, Identifiable {
        case plain = "Plain", photo = "Photo", video = "Video"
        var id: String { rawValue }
    }

    @State private var data: StoryData?
    @State private var selection: StoryCardKind = .mainEvent
    @State private var backgroundChoice: BackgroundChoice = .plain
    @State private var background: StoryBackground = .plain
    @State private var darkInk = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadingMedia = false
    @State private var shareImage: ShareableImage?
    @State private var alertText: String?

    private var privacy: StoryPrivacy {
        StoryPrivacy(hideName: hideName, hideWeight: hideWeight, onlyImprovements: onlyImprovements, hideRouteEnds: hideRouteEnds)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let data {
                        cardChips(data.availableKinds)
                        preview(data)
                        backgroundPicker
                        if selection == .overlay {
                            Picker("Layout", selection: $overlayOneLine) {
                                Text("Stacked").tag(false)
                                Text("One line").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        shareButtons(data)
                        privacyCard
                    } else {
                        ProgressView().padding(60)
                    }
                }
                .padding()
            }
            .navigationTitle("Share to Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $shareImage) { item in ShareSheet(items: [item.image]) }
            .alert("Can't share yet", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertText ?? "")
            }
            .onChange(of: pickerItem) { _, item in Task { await loadMedia(item) } }
            .onChange(of: backgroundChoice) { _, choice in
                pickerItem = nil
                background = .plain
                darkInk = false
                _ = choice
            }
            .task {
                guard data == nil else { return }
                let built = StoryData.build(store: workoutStore, workout: workout)
                let kinds = built.availableKinds
                selection = kinds.contains(focus) ? focus : (kinds.first ?? .progress)
                data = built
            }
        }
    }

    private func cardChips(_ kinds: [StoryCardKind]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(kinds) { k in
                    Button {
                        withAnimation(.snappy) { selection = k }
                    } label: {
                        Text(k.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selection == k ? Color.red : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(selection == k ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == k ? .isSelected : [])
                }
            }
        }
    }

    /// The story as it will look: background, with the sticker on top.
    private func preview(_ data: StoryData) -> some View {
        ZStack {
            backgroundView
            StoryCard(kind: selection, data: data, privacy: privacy, overlayOneLine: overlayOneLine, darkInk: darkInk)
                .scaleEffect(0.72)
                .frame(maxHeight: .infinity, alignment: selection.isTransparent ? .bottom : .center)
                .padding(.bottom, selection.isTransparent ? 24 : 0)
        }
        .frame(width: 270, height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.primary.opacity(0.15)))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var backgroundView: some View {
        if let img = background.previewImage {
            Image(uiImage: img).resizable().scaledToFill().frame(width: 270, height: 480).clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.165, green: 0.04, blue: 0.055), .black], startPoint: .top, endPoint: .bottom)
        }
    }

    private var backgroundPicker: some View {
        VStack(spacing: 10) {
            Picker("Background", selection: $backgroundChoice) {
                ForEach(BackgroundChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if backgroundChoice != .plain {
                PhotosPicker(selection: $pickerItem, matching: backgroundChoice == .photo ? .images : .videos) {
                    Label(loadingMedia ? "Loading…" : (background.previewImage == nil ? "Choose \(backgroundChoice.rawValue.lowercased())" : "Change \(backgroundChoice.rawValue.lowercased())"),
                          systemImage: backgroundChoice == .photo ? "photo" : "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(loadingMedia)
            }
        }
    }

    private func shareButtons(_ data: StoryData) -> some View {
        VStack(spacing: 10) {
            Button {
                shareToInstagram(data)
            } label: {
                Label("Share to Instagram Story", systemImage: "camera.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.pink)

            Button {
                if let img = composedImage(data) { shareImage = ShareableImage(image: img) }
            } label: {
                Label(backgroundChoice == .video ? "Save sticker…" : "More options…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var privacyCard: some View {
        VStack(spacing: 0) {
            Toggle("Hide my name", isOn: $hideName)
            Divider().padding(.vertical, 8)
            Toggle("Hide my weight", isOn: $hideWeight)
            Divider().padding(.vertical, 8)
            Toggle("Only show improvements", isOn: $onlyImprovements)
            if workout?.run?.hasRoute == true {
                Divider().padding(.vertical, 8)
                Toggle(isOn: $hideRouteEnds) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide start and end of my route")
                        Text("Leaves the first and last 200 m off, so nobody can see where you live or train.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.subheadline)
        .card()
    }

    // MARK: Actions

    private func loadMedia(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loadingMedia = true
        defer { loadingMedia = false }
        if backgroundChoice == .photo {
            if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                background = .photo(img)
            }
        } else if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 720, height: 1280)
            var frame: UIImage?
            if let cg = try? await gen.image(at: .zero).image { frame = UIImage(cgImage: cg) }
            background = .video(movie.url, frame)
        }
        darkInk = background.isBright
    }

    private func sticker(_ data: StoryData) -> UIImage? {
        render(StoryCard(kind: selection, data: data, privacy: privacy, overlayOneLine: overlayOneLine, darkInk: darkInk))
    }

    private func shareToInstagram(_ data: StoryData) {
        if backgroundChoice != .plain, background.previewImage == nil {
            alertText = "Choose a \(backgroundChoice.rawValue.lowercased()) first, or switch the background to Plain."
            return
        }
        guard let s = sticker(data) else { return }
        if !InstagramStories.share(sticker: s, background: background) {
            alertText = InstagramStories.isAvailable
                ? "That file couldn't be sent to Instagram. Try a shorter video or a photo."
                : "Instagram isn't installed. Use More options to save the image or send it to another app."
        }
    }

    /// A full 9:16 story image (or, with a video background, just the transparent sticker).
    private func composedImage(_ data: StoryData) -> UIImage? {
        if case .video = background { return sticker(data) }
        let card = StoryCard(kind: selection, data: data, privacy: privacy, overlayOneLine: overlayOneLine, darkInk: darkInk)
        let canvas = ZStack {
            if let img = background.previewImage {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 360, height: 640).clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.165, green: 0.04, blue: 0.055), .black], startPoint: .top, endPoint: .bottom)
            }
            card
                .frame(maxHeight: .infinity, alignment: selection.isTransparent ? .bottom : .center)
                .padding(.bottom, selection.isTransparent ? 40 : 0)
        }
        .frame(width: 360, height: 640)
        return render(canvas)
    }

    private func render<V: View>(_ view: V) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage
    }
}
