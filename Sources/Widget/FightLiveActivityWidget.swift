import WidgetKit
import SwiftUI
import ActivityKit

@main
struct FightLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        FightLiveActivityWidget()
    }
}

struct FightLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            VStack(spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(context.attributes.discipline.uppercased())
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.secondary)
                        Text("• \(context.state.zoneShortName)")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(zoneColor(context.state.zoneNumber).opacity(0.25), in: Capsule())
                            .foregroundStyle(zoneColor(context.state.zoneNumber))
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(zoneColor(context.state.zoneNumber))
                        Text(context.state.currentBPM > 0 ? "\(context.state.currentBPM)" : "--")
                            .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
                        Text("BPM")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if context.state.isPaused == true {
                        Text("PAUSED")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(.orange)
                    } else if let distance = context.state.distanceText {
                        Text(distance)
                            .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
                        Text(context.state.paceText ?? "")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.orange)
                    } else if context.state.isTimedRound {
                        Text("R\(context.state.roundNumber) • \(context.state.isRest ? "REST" : "WORK")")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(context.state.isRest ? .cyan : .orange)

                        Text(timerInterval: Date.now...max(Date.now, context.state.phaseEndDate), countsDown: true)
                            .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(context.state.isRest ? .cyan : .orange)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("ELAPSED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(timerInterval: context.state.workoutStartDate...Date.distantFuture, countsDown: false)
                            .font(.title2.weight(.bold).monospacedDigit())
                            .multilineTextAlignment(.trailing)
                    }

                    Text("\(context.state.calories) kcal")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if context.state.isTimedRound {
                roundButton(isRest: context.state.isRest)
            }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(zoneColor(context.state.zoneNumber))
                        Text("\(context.state.currentBPM)")
                            .font(.title2.weight(.heavy).monospacedDigit())
                        Text(context.state.zoneShortName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(zoneColor(context.state.zoneNumber))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isPaused == true {
                        Text("PAUSED")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(.orange)
                    } else if let distance = context.state.distanceText {
                        VStack(alignment: .trailing) {
                            Text(distance).font(.headline.monospacedDigit())
                            Text(context.state.paceText ?? "").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        }
                    } else if context.state.isTimedRound {
                        VStack(alignment: .trailing) {
                            Text("R\(context.state.roundNumber) \(context.state.isRest ? "REST" : "WORK")")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(context.state.isRest ? .cyan : .orange)
                            Text(timerInterval: Date.now...max(Date.now, context.state.phaseEndDate), countsDown: true)
                                .font(.headline.monospacedDigit())
                        }
                    } else {
                        Text(timerInterval: context.state.workoutStartDate...Date.distantFuture, countsDown: false)
                            .font(.headline.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isTimedRound {
                        roundButton(isRest: context.state.isRest)
                    }
                    Text("\(context.attributes.athleteName) • \(context.attributes.discipline) • \(context.state.calories) kcal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(zoneColor(context.state.zoneNumber))
                    Text("\(context.state.currentBPM)")
                        .font(.caption.weight(.bold).monospacedDigit())
                }
            } compactTrailing: {
                if context.state.isPaused == true {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.orange)
                } else if let distance = context.state.distanceText {
                    Text(distance)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .frame(maxWidth: 64)
                } else if context.state.isTimedRound {
                    Text(timerInterval: Date.now...max(Date.now, context.state.phaseEndDate), countsDown: true)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(context.state.isRest ? .cyan : .orange)
                        .frame(width: 44)
                } else {
                    Text(context.state.zoneShortName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(zoneColor(context.state.zoneNumber))
                }
            } minimal: {
                Text("\(context.state.currentBPM)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(zoneColor(context.state.zoneNumber))
            }
        }
    }

    /// Gloves-on control: end the round, or start the next one early.
    private func roundButton(isRest: Bool) -> some View {
        Button(intent: RoundActionIntent(action: isRest ? "skipRest" : "endRound")) {
            Label(isRest ? "Start Next Round" : "End Round", systemImage: isRest ? "play.fill" : "bell.fill")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRest ? .cyan : .orange)
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: return .blue
        case 2: return .green
        case 3: return .yellow
        case 4: return .orange
        default: return .red
        }
    }
}
