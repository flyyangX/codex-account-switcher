import Foundation
import Testing
@testable import CodexAccountSwitcher

struct APIAccountSummaryTests {
    @Test func totalsDeduplicateOrganizationsAndKeepCurrenciesSeparate() {
        var config = APIUsageConfiguration()
        config.accounts = [
            APITrackedAccount(name: "Synthetic A", organizationID: "org-a", credentialNote: "", creditNote: ""),
            APITrackedAccount(name: "Synthetic alias", organizationID: "org-a", credentialNote: "", creditNote: ""),
            APITrackedAccount(name: "Synthetic B", organizationID: "org-b", credentialNote: "", creditNote: "")]
        config.creditBalances = ["org-a": record(total: 50, remaining: Decimal(string: "49.25"), currency: "USD"),
                                 "org-b": record(total: 20, remaining: 10, currency: "EUR")]
        let summary = APIAccountSummary(configuration: config)
        #expect(summary.rows.count == 3)
        #expect(summary.totals == ["USD": 50, "EUR": 20])
        #expect(summary.remaining == ["USD": Decimal(string: "49.25")!, "EUR": 10])
        #expect(summary.missingTotals == 0)
        #expect(summary.missingRemaining == 0)
    }

    @Test func unknownAndInitialOnlyAmountsDoNotBecomeCompleteTotals() {
        var config = APIUsageConfiguration()
        config.accounts = [APITrackedAccount(name: "Synthetic", organizationID: "org-a", credentialNote: "", creditNote: ""),
                           APITrackedAccount(name: "Unbound", credentialNote: "", creditNote: "")]
        var initial = record(total: 50, remaining: nil, currency: "USD"); initial.isInitialGrantOnly = true
        config.creditBalances["org-a"] = initial
        let summary = APIAccountSummary(configuration: config)
        #expect(summary.totals.isEmpty)
        #expect(summary.remaining.isEmpty)
        #expect(summary.missingTotals == 2)
        #expect(summary.missingRemaining == 2)
    }

    @Test func expiryCountdownUsesBeijingDateAcrossMidnight() throws {
        let row = APIAccountSummary.Row(id: "synthetic", name: "Synthetic", expiryDate: "2030-05-10")
        let formatter = ISO8601DateFormatter()
        #expect(row.daysUntilExpiry(now: try #require(formatter.date(from: "2030-05-08T15:59:59Z"))) == 2)
        #expect(row.daysUntilExpiry(now: try #require(formatter.date(from: "2030-05-08T16:00:00Z"))) == 1)
        #expect(row.daysUntilExpiry(now: try #require(formatter.date(from: "2030-05-09T16:00:00Z"))) == 0)
        #expect(row.daysUntilExpiry(now: try #require(formatter.date(from: "2030-05-10T16:00:00Z"))) == -1)
        var unknown = row; unknown.expiryDate = nil
        #expect(unknown.daysUntilExpiry(now: Date()) == nil)
    }

    private func record(total: Decimal?, remaining: Decimal?, currency: String) -> APICreditBalance {
        APICreditBalance(totalCredits: total, remainingCredits: remaining, currency: currency,
                         isInitialGrantOnly: false, source: "Synthetic", verifiedAt: Date())
    }
}
