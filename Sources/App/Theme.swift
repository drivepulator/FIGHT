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
    var holdSeconds: Double = 1.0
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        ZStack {
            GeometryReader { g in
                Theme.red.opacity(0.35)
                    .frame(width: g.size.width * progress)
            }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.red, lineWidth: 2)
            Label(holding ? "Keep holding…" : title, systemImage: "stop.fill")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: holdSeconds, maximumDistance: 40) {
            holding = false
            progress = 0
            action()
        } onPressingChanged: { pressing in
            holding = pressing
            if pressing {
                withAnimation(.linear(duration: holdSeconds)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: holding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("End workout")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
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
