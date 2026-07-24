import Foundation
import UserNotifications

/// A nudge to come back and train, at a time the fighter picks.
///
/// Local, not push: there's no server in the loop and nothing to deliver but a
/// reminder the phone already has everything it needs to raise. One per plan —
/// scheduling a second replaces the first, because "remind me at six, no, seven"
/// is a correction, not two reminders.
enum SessionReminder {

    /// The prefix on every reminder's identifier, so a plan's pending request can
    /// be found and replaced without touching anything else the app might one day
    /// schedule.
    private static let prefix = "session-reminder-"

    private static func identifier(for sessionID: String) -> String {
        prefix + sessionID
    }

    /// Asks once, returns whether it's allowed now. `.provisional` isn't
    /// requested: a reminder the fighter set by hand should arrive on the lock
    /// screen with a sound, not slip in quietly the way an unasked-for one
    /// should.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// Schedules the reminder for `date`, replacing any already set for this
    /// plan. Returns false when notifications aren't allowed or the time has
    /// already passed — the caller says so rather than the reminder failing
    /// silently.
    @discardableResult
    static func schedule(at date: Date, sessionID: String, focus: String) async -> Bool {
        guard await requestAuthorization() else { return false }
        guard date > .now else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Time to train"
        // The plan's own focus, so the reminder names the session waiting rather
        // than nagging in the abstract.
        content.body = focus.isEmpty ? "Your session is ready." : "\(focus.capitalized) session is ready."
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: identifier(for: sessionID),
            content: content,
            trigger: trigger
        )

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: sessionID)])
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    /// Drops the plan's reminder. Called when the session is started — a
    /// reminder to begin a session already begun is noise.
    static func cancel(sessionID: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier(for: sessionID)])
    }
}
