import Foundation
import UserNotifications

/// Limit notifications.
///
/// For every usage window of every provider (Claude session / All models / Fable,
/// Codex session / weekly, …):
///  • when it fills up (≥ 100 %, or the vendor marks it locked) → "limit reached,
///    resets at …, I'll let you know" — and a second notification is *scheduled*
///    for the reset time, so it arrives on the minute even if the app is idle;
///  • when the window is observed open again → "reset, full limit available"
///    (and any pending scheduled notification for it is cancelled).
///
/// Nothing fires while the toggle is off; state is tracked per (provider, window).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let enabledKey = "notificationsEnabled"
    private let center = UNUserNotificationCenter.current()
    private var full: Set<String> = []         // keys currently at 100 %
    private var scheduledResets: Set<String> = []

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Show banners even if Brink happens to be the frontmost app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Menu → "Test notification": shows the two messages a user will get.
    func sendTest() {
        let when = " " + L("Resets in %d min", 51).lowercasedFirst + "."
        post(id: "test|full", title: L("%@ — %@ limit reached", "Claude", L("Current session")),
             body: L("You've used 100 %%.%@ I'll let you know when it resets.", when))
        let content = UNMutableNotificationContent()
        content.title = L("%@ — %@ reset", "Claude", L("Current session"))
        content.body = L("Your full limit is available again.")
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "test|reset", content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false)))
    }

    // MARK: Preference

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { requestAuthorizationIfNeeded() } else { cancelAll() }
    }

    func requestAuthorizationIfNeeded() {
        guard isEnabled else { return }
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: Observation (called after every refresh)

    func observe(_ snapshots: [ProviderSnapshot]) {
        guard isEnabled else { return }
        let now = Date()
        for snap in snapshots where !snap.isDemo {
            for window in snap.windows {
                let key = "\(snap.id)|\(window.label)"
                let isFull = window.usedPercent >= 99.5
                    && (window.resetsAt.map { $0 > now } ?? true)

                if isFull && !full.contains(key) {
                    full.insert(key)
                    notifyFull(snap, window, key: key)
                    scheduleReset(snap, window, key: key)
                } else if !isFull && full.contains(key) {
                    full.remove(key)
                    // If the scheduled one already fired at reset time, don't repeat it.
                    if scheduledResets.contains(key), let r = window.resetsAt, r <= now {
                        scheduledResets.remove(key)
                        continue
                    }
                    cancelScheduled(key)
                    notifyReset(snap, window)
                }
            }
        }
    }

    // MARK: Messages

    private func notifyFull(_ snap: ProviderSnapshot, _ w: UsageWindow, key: String) {
        let when = w.resetText.map { " " + $0.lowercasedFirst + "." } ?? ""
        post(id: "full|\(key)",
             title: L("%@ — %@ limit reached", snap.displayName, L(w.label)),
             body: L("You've used 100 %%.%@ I'll let you know when it resets.", when))
    }

    private func notifyReset(_ snap: ProviderSnapshot, _ w: UsageWindow) {
        post(id: "reset|\(snap.id)|\(w.label)",
             title: L("%@ — %@ reset", snap.displayName, L(w.label)),
             body: L("Your full limit is available again."))
    }

    private func scheduleReset(_ snap: ProviderSnapshot, _ w: UsageWindow, key: String) {
        guard let resetsAt = w.resetsAt else { return }
        let delay = resetsAt.timeIntervalSinceNow + 20   // small grace for clock skew
        guard delay > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = L("%@ — %@ reset", snap.displayName, L(w.label))
        content.body = L("Your full limit is available again.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: "reset|\(key)", content: content, trigger: trigger))
        scheduledResets.insert(key)
    }

    private func cancelScheduled(_ key: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["reset|\(key)"])
        scheduledResets.remove(key)
    }

    private func cancelAll() {
        center.removeAllPendingNotificationRequests()
        scheduledResets.removeAll()
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
