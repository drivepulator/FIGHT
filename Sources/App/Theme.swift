import SwiftUI
import UIKit

/// FIGHT's design system: one accent (red), dark-first surfaces, big rounded numbers.
enum Theme {
    /// The only accent colour: actions and "you" moments.
    static let red = Color(red: 232 / 255.0, green: 38 / 255.0, blue: 46 / 255.0)

    /// Page background: dark grey (not pure black) in dark mode.
    static let canvas = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 18 / 255.0, green: 18 / 255.0, blue: 18 / 255.0, alpha: 1)
            : .systemGroupedBackground
    })
    /// Cards sitting on the canvas.
    static let card = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 30 / 255.0, green: 30 / 255.0, blue: 30 / 255.0, alpha: 1)
            : .secondarySystemGroupedBackground
    })
    /// Controls sitting on a card or a sheet.
    static let raised = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255.0, green: 38 / 255.0, blue: 38 / 255.0, alpha: 1)
            : .tertiarySystemGroupedBackground
    })

    static let cardRadius: CGFloat = 18

    /// Big numbers: rounded, heavy, fixed-width digits so clocks don't jitter.
    static func number(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
    }
}

// MARK: - Buttons

/// The one main action on a screen: full width, red, at least 52 pt tall.
struct FightPrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.red

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, tint: tint)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(tint.opacity(configuration.isPressed ? 0.8 : 1),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}

/// Press and hold to end, so a glove can't stop a session by accident.
struct HoldToEndButton: View {
    var title = "Hold to end"
    /// Whole seconds to hold; the button counts them down.
    var holdSeconds = 3
    var height: CGFloat = 56
    let action: () -> Void

    @State private var progress: CGFloat = 0
    /// Seconds left while held (3, 2, 1); nil when not held.
    @State private var remaining: Int?
    @State private var countdown: Task<Void, Never>?
    @State private var ended = 0

    var body: some View {
        Group {
            if let left = remaining {
                // Held: a big countdown, so you know exactly when it ends.
                VStack(spacing: 2) {
                    Text("\(left)")
                        .font(Theme.number(height >= 90 ? 48 : 28))
                        .contentTransition(.numericText(countsDown: true))
                    if height >= 90 {
                        Text("Ending… let go to keep going")
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                }
            } else if height >= 90 {
                // Tall button: big icon over the words, easy to find with a glove.
                VStack(spacing: 10) {
                    Image(systemName: "stop.fill").font(.system(size: 32, weight: .bold))
                    Text(title).font(.title3.weight(.bold))
                }
            } else {
                Label(title, systemImage: "stop.fill")
                    .font(.headline)
            }
        }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            // The fill sits behind the label at the label's own size, so the button never grows.
            .background(alignment: .leading) {
                GeometryReader { g in
                    Theme.red.opacity(0.4)
                        .frame(width: g.size.width * progress)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.red, lineWidth: 2.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: Double(holdSeconds), maximumDistance: 40) {
            stopCountdown()
            ended += 1
            action()
        } onPressingChanged: { pressing in
            if pressing {
                startCountdown()
            } else {
                stopCountdown()
            }
        }
        // A firm tap on every second of the countdown, and a success buzz when it ends.
        .sensoryFeedback(trigger: remaining) { _, new in
            guard let new else { return nil }
            return .impact(weight: .heavy, intensity: new == 1 ? 1.0 : 0.75)
        }
        .sensoryFeedback(.success, trigger: ended)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("End workout")
        .accessibilityHint("Press and hold for \(holdSeconds) seconds")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private func startCountdown() {
        countdown?.cancel()
        remaining = holdSeconds
        withAnimation(.linear(duration: Double(holdSeconds))) { progress = 1 }
        countdown = Task { @MainActor in
            for left in stride(from: holdSeconds - 1, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                withAnimation { remaining = left }
            }
        }
    }

    private func stopCountdown() {
        countdown?.cancel()
        countdown = nil
        remaining = nil
        withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
    }
}

// MARK: - Numbers

/// A big number with a small label under it.
struct BigNumber: View {
    let value: String
    let label: String
    var size: CGFloat = 26

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.number(size))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One dot per round: filled when done, ringed for the current one.
struct RoundDots: View {
    let current: Int
    let total: Int?

    var body: some View {
        let count = min(max(total ?? current, current, 1), 12)
        HStack(spacing: 6) {
            ForEach(1...count, id: \.self) { i in
                Circle()
                    .fill(i < current ? Theme.red : Color.clear)
                    .overlay(Circle().strokeBorder(i <= current ? Theme.red : Color.secondary.opacity(0.4), lineWidth: 2))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(total.map { "Round \(current) of \($0)" } ?? "Round \(current)")
    }
}

/// Live heart rate in a band tinted by the zone you're in.
struct LiveZoneBand: View {
    let bpm: Int
    let zoneName: String
    let color: Color
    let average: Int
    let maximum: Int
    let calories: Int
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 72

    var body: some View {
        let live = bpm > 0
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(live ? color : .secondary)
                    .symbolEffect(.pulse, isActive: live)
                Text(live ? "\(bpm)" : "--")
                    .font(Theme.number(size))
                    .contentTransition(.numericText())
                    .animation(.default, value: bpm)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("bpm")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text(live ? zoneName : "No signal")
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background((live ? color : Color.secondary).opacity(0.22), in: Capsule())
                .foregroundStyle(live ? color : .secondary)
            HStack {
                BigNumber(value: average > 0 ? "\(average)" : "--", label: "avg", size: 20)
                BigNumber(value: maximum > 0 ? "\(maximum)" : "--", label: "max", size: 20)
                BigNumber(value: "\(calories)", label: "kcal", size: 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background((live ? color : Color.secondary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder((live ? color : Color.secondary).opacity(0.5), lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live ? "Heart rate \(bpm), \(zoneName). Average \(average), max \(maximum)." : "No heart-rate signal")
    }
}
