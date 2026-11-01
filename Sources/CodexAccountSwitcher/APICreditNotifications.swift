import Foundation
import UserNotifications
import SwitcherCore

@MainActor
final class APICreditNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func enable() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func reconcile(grants: [APICreditGrant], enabled: Bool, now: Date = Date()) async throws {
        let pending = await center.pendingNotificationRequests()
        let owned = pending.filter { $0.identifier.hasPrefix("api-credit.") }
        let reminders = enabled ? APICreditReminderPlanner.reminders(grants: grants, now: now) : []
        // macOS limits pending notifications. Keep the nearest reminders visible and bounded.
        let next = Array(reminders.prefix(60))
        let ids = Set(next.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier).filter { !ids.contains($0) })
        guard enabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw NotificationError.denied
        }
        // Existing identifiers are replaced in-place: edits update text without duplicate alerts.
        for reminder in next {
            guard let grant = grants.first(where: { $0.id == reminder.grantID }) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "API 赠额将在 \(reminder.days) 天后到期"
            content.body = "\(grant.organizationID) · 记录金额 \(grant.currency) \(grant.amount)。请到官方账单核对余额和到期时间。"
            content.sound = .default
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
            components.timeZone = calendar.timeZone
            let request = UNNotificationRequest(identifier: reminder.id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try await center.add(request)
        }
    }
}

private enum NotificationError: LocalizedError {
    case denied
    var errorDescription: String? { "通知未获授权。请在系统设置 → 通知中允许本应用，再重新开启提醒。" }
}
