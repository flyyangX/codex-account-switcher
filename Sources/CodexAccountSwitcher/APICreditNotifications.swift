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

    func reconcile(grants: [APICreditGrant], accounts: [APITrackedAccount] = [], enabled: Bool, now: Date = Date()) async throws {
        let pending = await center.pendingNotificationRequests()
        let owned = pending.filter { $0.identifier.hasPrefix("api-credit.") }
        let reminders = enabled ? APICreditReminderPlanner.reminders(grants: grants, now: now) : []
        // macOS limits pending notifications. Keep the nearest reminders visible and bounded.
        let dateOnly = enabled ? APIDateOnlyReminderPlanner.reminders(accounts: accounts, now: now) : []
        let nearest = (reminders.map { ($0.id, $0.fireAt) } + dateOnly.map { ($0.id, $0.fireAt) })
            .sorted { $0.1 < $1.1 }.prefix(60)
        let ids = Set(nearest.map { $0.0 })
        center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier).filter { !ids.contains($0) })
        guard enabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw NotificationError.denied
        }
        // Existing identifiers are replaced in-place: edits update text without duplicate alerts.
        for reminder in reminders where ids.contains(reminder.id) {
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
        for reminder in dateOnly where ids.contains(reminder.id) {
            guard let account = accounts.first(where: { $0.id == reminder.accountID }) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "API 赠额到期日期提醒"
            content.body = "\(account.name)：已知到期日\(reminder.expiryDate)，准确时刻待核实；请提前使用并核对余额。"
            content.sound = .default
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
            components.timeZone = calendar.timeZone
            try await center.add(UNNotificationRequest(identifier: reminder.id, content: content,
                                                       trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
    }

    func status() async -> APINotificationStatus {
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let authorization: String
        switch settings.authorizationStatus {
        case .authorized: authorization = "authorized"
        case .provisional: authorization = "provisional"
        case .denied: authorization = "denied"
        case .notDetermined: authorization = "notDetermined"
        default: authorization = "unknown"
        }
        return APINotificationStatus(checkedAt: Date(), authorization: authorization,
                                     pendingIDs: pending.map(\.identifier).filter { $0.hasPrefix("api-credit.") },
                                     error: authorization == "authorized" || authorization == "provisional" ? nil : "notification_permission_required",
                                     pending: pending.filter { $0.identifier.hasPrefix("api-credit.") }.map {
                                         APINotificationStatus.Pending(id: $0.identifier,
                                             fireAt: ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate())
                                     })
    }
}

private enum NotificationError: LocalizedError {
    case denied
    var errorDescription: String? { "通知未获授权。请在系统设置 → 通知中允许本应用，再重新开启提醒。" }
}
