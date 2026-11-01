import Foundation

struct APIAccountSummary {
    struct Row: Identifiable {
        var id: String
        var name: String
        var organizationID: String?
        var balance: APICreditBalance?
        var expiryDate: String?

        func daysUntilExpiry(now: Date) -> Int? {
            guard let expiryDate,
                  let date = APIDateOnlyReminderPlanner.parse(expiryDate, timeZone: "Asia/Shanghai") else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day
        }
    }
    var rows: [Row]
    var totals: [String: Decimal] = [:]
    var remaining: [String: Decimal] = [:]
    var missingTotals = 0
    var missingRemaining = 0

    init(configuration: APIUsageConfiguration) {
        rows = configuration.accounts.map {
            Row(id: $0.id.uuidString, name: $0.name, organizationID: $0.organizationID,
                balance: $0.organizationID.flatMap { configuration.creditBalances[$0] }, expiryDate: $0.expiryDate)
        }
        for org in configuration.organizations where !configuration.accounts.contains(where: { $0.organizationID == org.id }) {
            rows.append(Row(id: org.id, name: org.name, organizationID: org.id,
                            balance: configuration.creditBalances[org.id], expiryDate: nil))
        }
        var seen = Set<String>()
        for row in rows {
            guard let id = row.organizationID else { missingTotals += 1; missingRemaining += 1; continue }
            guard seen.insert(id).inserted else { continue }
            if let balance = row.balance, !balance.isInitialGrantOnly, let amount = balance.totalCredits {
                totals[balance.currency, default: 0] += amount
            } else { missingTotals += 1 }
            if let balance = row.balance, let amount = balance.remainingCredits {
                remaining[balance.currency, default: 0] += amount
            } else { missingRemaining += 1 }
        }
    }
}
