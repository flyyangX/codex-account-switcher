import Foundation
import Testing
import WebKit
@testable import CodexAccountSwitcher

struct APIWebBillingTests {
    private let headers = ["RECEIVED", "STATE", "BALANCE", "EXPIRES"]

    @MainActor @Test func detachedBrowserKeepsDesktopTableReadable() async throws {
        let browser = APIWebBillingController()
        let profileID = UUID()
        let view = browser.webView(organizationID: "org-synthetic-viewport", profileID: profileID)
        view.loadHTMLString("""
        <meta name="viewport" content="width=device-width">
        <style>@media(max-width:600px){table{display:none}}</style>
        <table><thead><tr><th>RECEIVED</th><th>STATE</th><th>BALANCE</th><th>EXPIRES</th></tr></thead>
        <tbody><tr><td>Oct 1, 2030</td><td>Available</td><td>$45 / $50</td><td>Nov 17, 2030</td></tr></tbody></table>
        """, baseURL: nil)
        var page: APIWebCreditPage?
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let text = try? await view.evaluateJavaScript(APIWebBillingController.creditTableScript) as? String,
               let data = text.data(using: .utf8),
               let candidate = try? JSONDecoder().decode(APIWebCreditPage.self, from: data), !candidate.rows.isEmpty {
                page = candidate; break
            }
        }
        await browser.clearProfile(organizationID: "org-synthetic-viewport", profileID: profileID)
        let result = try APIWebCreditParser.parse(try #require(page))
        #expect(result.balance.remainingCredits == 45)
    }

    @MainActor @Test func loginLandingReturnsToGeneralWithoutInterruptingAuthentication() {
        #expect(APIWebBillingController.shouldReturnToGeneral(URL(string: "https://platform.openai.com/home")))
        #expect(!APIWebBillingController.shouldReturnToGeneral(URL(string: "https://platform.openai.com/auth/callback")))
        #expect(!APIWebBillingController.shouldReturnToGeneral(URL(string: "https://auth.openai.com/log-in")))
        #expect(!APIWebBillingController.shouldReturnToGeneral(URL(string: "https://platform.openai.com/settings/organization/general")))
    }

    @Test func sumsOnlyAvailableGrantBalancesAndPreservesDateOnlyExpiry() throws {
        let page = APIWebCreditPage(headers: headers, rows: [
            ["Oct 1, 2030", "Available", "$45.25 / $50.00", "Nov 17, 2030"],
            ["Oct 2, 2030", "Available", "$1,000.00 / $1,200.00", "Nov 21, 2030"],
            ["Oct 1, 2029", "Expired", "$0.00 / $500.00", "Nov 1, 2029"]
        ], hasMore: false)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let result = try APIWebCreditParser.parse(page, now: now)
        #expect(result.balance.totalCredits == 1250)
        #expect(result.balance.remainingCredits == Decimal(string: "1045.25"))
        #expect(result.balance.webSynced == true)
        #expect(result.balance.verifiedAt == now)
        #expect(result.nextExpiry == "2030-11-17")
    }

    @Test func incompleteUnknownAndMalformedPagesNeverReplaceBalance() {
        let row = ["Oct 1, 2030", "Available", "$45.25 / $50.00", "Nov 17, 2030"]
        for page in [
            APIWebCreditPage(headers: headers, rows: [row], hasMore: true),
            APIWebCreditPage(headers: headers, rows: [], hasMore: false),
            APIWebCreditPage(headers: ["usage", "total"], rows: [["$5 / $50"]], hasMore: false),
            APIWebCreditPage(headers: headers, rows: [["Oct 1, 2030", "Unknown", "$45 / $50", "Nov 17, 2030"]], hasMore: false),
            APIWebCreditPage(headers: headers, rows: [["Oct 1, 2030", "Available", "€45 / €50", "Nov 17, 2030"]], hasMore: false),
            APIWebCreditPage(headers: headers, rows: [["Oct 1, 2030", "Available", "$60 / $50", "Nov 17, 2030"]], hasMore: false),
            APIWebCreditPage(headers: headers, rows: [["Oct 1, 2030", "Available", "$45 / $50", "unknown"]], hasMore: false)
        ] {
            #expect(throws: (any Error).self) { try APIWebCreditParser.parse(page) }
        }
    }

    @Test func explicitlyExpiredRowsYieldNoActiveCreditInsteadOfLifetimeTotal() throws {
        let result = try APIWebCreditParser.parse(APIWebCreditPage(headers: headers, rows: [
            ["Oct 1, 2029", "Expired", "$0 / $500", "Nov 17, 2029"]
        ], hasMore: false))
        #expect(result.balance.totalCredits == 0)
        #expect(result.balance.remainingCredits == 0)
        #expect(result.nextExpiry == nil)
    }
}
