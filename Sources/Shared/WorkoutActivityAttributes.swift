import Foundation
import ActivityKit

struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentBPM: Int
        var zoneNumber: Int
        var zoneShortName: String
        var calories: Int
        var workoutStartDate: Date
        var isTimedRound: Bool
        var roundNumber: Int
        var isRest: Bool
        var phaseEndDate: Date
        /// Runs: "5.02 km" and "5:28 /km" (nil for other workouts).
        var distanceText: String? = nil
        var paceText: String? = nil
        /// The session is paused: show "Paused" instead of running clocks.
        var isPaused: Bool? = nil
    }

    var athleteName: String
    var discipline: String
}
