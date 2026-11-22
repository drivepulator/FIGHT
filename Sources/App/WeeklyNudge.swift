import Foundation
import UserNotifications

/// A Sunday-evening summary of the week, rescheduled with fresh numbers whenever
/// the app is used. Tapping it opens a ready-to-share progress story.
@MainActor
enum WeeklyNudge {
    static let identifier = "fight.weekly"
    private static let router = NotificationRouter()

    static func install() {
        UNUserNotificationCenter.current().delegate = router
    }

    /// Only schedules if notifications are already allowed (never asks on its own).
    static func reschedule(store: WorkoutStore) {
        let profile = store.activeProfile
        let body = summary(store: store, profile: profile)
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your week in FIGHT"
            content.body = body
            content.sound = .default
            var when = DateComponents()
            when.weekday = 1
            when.hour = 18
            when.minute = 41
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }

    static func summary(store: WorkoutStore, profile: AthleteProfile, now: Date = Date()) -> String {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now.addingTimeInterval(-7 * 86400)
        let week = store.workouts.filter { $0.profileID == profile.id && $0.startDate >= weekStart }
        guard !week.isEmpty else { return "No sessions logged this week. One good session tomorrow gets you back on track." }
        var parts = ["\(week.count) session\(week.count == 1 ? "" : "s")"]
        let rounds = week.reduce(0) { $0 + $1.roundStats.count }
        if rounds > 0 { parts.append("\(rounds) rounds") }
        var line = "This week: " + parts.joined(separator: ", ") + "."
        if let g = GasTank.evaluate(workouts: store.workouts.filter { $0.profileID == profile.id }, profile: profile) {
            line += " Gas tank: \(g.headline.lowercased())."
        }
        let chin = week.flatMap(\.roundStats).compactMap(\.chinUpSeconds)
        if chin.reduce(0, +) >= 60 { line += " Watch your chin in late rounds." }
        return line + " Tap to share your progress."
    }
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == WeeklyNudge.identifier else { return }
        await MainActor.run {
            AppNavigation.shared?.recordSegment = .trends
            AppNavigation.shared?.selectedTab = .record
            AppNavigation.shared?.storyToOpen = .progress
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
