import SwiftUI
import MapKit

// MARK: - Live run numbers

/// Big, glanceable numbers while running. The map comes after the run.
struct RunLiveCard: View {
    let run: RunTracker
    @ScaledMetric private var distanceFontSize: CGFloat = 72

    private var unit: String { run.imperial ? "mi" : "km" }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(run.isPaused ? "Paused" : run.source, systemImage: run.isPaused ? "pause.fill" : signalIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(run.isPaused ? Color.orange : signalColor)
                Spacer()
                if run.signal != .good && !run.isPaused {
                    Text(run.signal.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(RouteMath.distanceText(run.distanceM, imperial: run.imperial))
                    .font(.system(size: distanceFontSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit).font(.title2.weight(.bold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                number(RouteMath.paceText(run.currentPace), "Pace /\(unit)")
                Divider().frame(height: 36)
                number(RouteMath.paceText(run.averagePace), "Avg /\(unit)")
                Divider().frame(height: 36)
                number(runClock(run.movingSeconds), "Moving")
            }
            if run.permissionDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Allow location to track distance", systemImage: "location.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private var signalIcon: String { run.signal == .good ? "location.fill" : "location" }
    private var signalColor: Color { run.signal == .good ? .green : .secondary }

    private func number(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

func runClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - After the run

/// Pace colours, slow → fast.
let paceColors: [Color] = [
    Color(red: 0.89, green: 0.29, blue: 0.29), Color(red: 0.94, green: 0.55, blue: 0.2),
    Color(red: 0.95, green: 0.78, blue: 0.2), Color(red: 0.55, green: 0.8, blue: 0.35), Color(red: 0.11, green: 0.62, blue: 0.46)
]

/// Strava-style run summary at the top of a run's detail page.
struct RunSummarySection: View {
    @EnvironmentObject var workoutStore: WorkoutStore
    let workout: SavedWorkout
    let run: RunSummary
    @State private var route: [RoutePoint] = []

    private var unit: String { run.imperial ? "mi" : "km" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if route.count >= 2 {
                RouteMapView(route: route)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            stats
            if !run.splits.isEmpty { splits }
            if let line = coachLine { Label(line, systemImage: "sparkles").font(.subheadline).foregroundStyle(.secondary) }
        }
        .onAppear { if route.isEmpty { route = workoutStore.loadRoute(for: workout.id) } }
    }

    private var stats: some View {
        let zone2 = zoneShare(2)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 12) {
            stat("Distance", "\(RouteMath.distanceText(run.distanceM, imperial: run.imperial)) \(unit)")
            stat("Avg pace", "\(RouteMath.paceText(run.avgPace)) /\(unit)")
            stat("Moving", runClock(run.movingSeconds))
            stat("Avg HR", workout.hasHeartRate ? "\(workout.averageBPM)" : "–")
            stat("Elevation", "+\(Int(run.elevationGain.rounded())) m")
            stat("Zone 2", zone2.map { "\($0)%" } ?? "–")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var splits: some View {
        let paces = run.splits.map { $0.pace(unit: run.unitMeters) }
        let fastest = paces.min() ?? 0
        let slowest = paces.max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Splits").font(.headline)
                Spacer()
                Text(run.source).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(run.splits) { s in
                let p = s.pace(unit: run.unitMeters)
                let share = slowest > fastest ? 0.45 + 0.55 * (slowest - p) / (slowest - fastest) : 1
                HStack(spacing: 10) {
                    Text(s.meters < run.unitMeters - 1 ? String(format: "%.1f", s.meters / run.unitMeters) : "\(s.index)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    Text(RouteMath.paceText(p)).font(.subheadline.weight(p == fastest ? .bold : .regular).monospacedDigit())
                        .frame(width: 46, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(p == fastest ? Color.green : Color.green.opacity(0.4))
                            .frame(width: g.size.width * share, height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 16)
                    Text(s.avgBPM.map(String.init) ?? "–").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    private func zoneShare(_ zone: Int) -> Int? {
        let total = workout.zoneSeconds.values.reduce(0, +)
        guard total > 60 else { return nil }
        return Int((workout.zoneSeconds[zone, default: 0] / total * 100).rounded())
    }

    /// One fighter-specific takeaway.
    private var coachLine: String? {
        if let d = RouteMath.decoupling(run.splits) {
            if d < 5 { return String(format: "Heart rate held steady with pace (drift %.0f%%). Your aerobic base is doing its job.", max(0, d)) }
            return String(format: "Heart rate drifted %.0f%% against pace in the second half. More easy Zone 2 runs fix this.", d)
        }
        if let z2 = zoneShare(2), workout.category == .roadwork {
            return z2 >= 70 ? "Held Zone 2 for \(z2)%. Aerobic base work done right." : "Only \(z2)% in Zone 2. Slow down on easy runs: it builds the engine faster."
        }
        return nil
    }
}

/// Apple Maps with the route drawn in pace colours, start and finish marked.
struct RouteMapView: View {
    let route: [RoutePoint]

    private var segments: [(points: [CLLocationCoordinate2D], band: Int)] {
        let bands = RouteMath.paceBands(route)
        var out: [(points: [CLLocationCoordinate2D], band: Int)] = []
        for i in 0..<bands.count {
            let a = route[i], b = route[i + 1]
            let ca = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
            let cb = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
            if let last = out.last, last.band == bands[i] {
                out[out.count - 1].points.append(cb)
            } else {
                out.append(([ca, cb], bands[i]))
            }
        }
        return out
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.zoom, .pan]) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                MapPolyline(coordinates: seg.points)
                    .stroke(paceColors[min(4, max(0, seg.band))], style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let s = route.first {
                Annotation("Start", coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)) {
                    Circle().fill(.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
            if let e = route.last {
                Annotation("Finish", coordinate: CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon)) {
                    Circle().fill(.black).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }
}

/// The route as a plain line in a square (for stickers: no map, transparent background).
struct RouteShape: Shape {
    let points: [CGPointValue]

    func path(in rect: CGRect) -> Path {
        Path { p in
            guard let first = points.first else { return }
            func pt(_ v: CGPointValue) -> CGPoint { CGPoint(x: rect.minX + v.x * rect.width, y: rect.minY + v.y * rect.height) }
            p.move(to: pt(first))
            for v in points.dropFirst() { p.addLine(to: pt(v)) }
        }
    }
}
