import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import SwitcherCore

struct APIUsageTests {
    private let range = APIQueryRange(start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 3_000))
    private var organization: APIOrganization {
        APIOrganization(id: "org-synthetic", name: "Synthetic", projectID: "proj_synthetic",
                        cycleStart: range.start, cycleEnd: range.end)
    }

    @Test func periodPresetsUseUTCAndHandleMonthBoundaries() throws {
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2032-03-01T01:30:00Z"))
        let expectations: [(APIPeriodPreset, String, String)] = [
            (.today, "2032-03-01T00:00:00Z", "2032-03-01T01:30:00Z"),
            (.last7Days, "2032-02-24T00:00:00Z", "2032-03-01T01:30:00Z"),
            (.last30Days, "2032-02-01T00:00:00Z", "2032-03-01T01:30:00Z"),
            (.thisMonth, "2032-03-01T00:00:00Z", "2032-03-01T01:30:00Z"),
            (.lastMonth, "2032-02-01T00:00:00Z", "2032-03-01T00:00:00Z")]
        for (preset, start, end) in expectations {
            let value = APIPeriodSelection(preset: preset).range(organization: organization, now: now)
            #expect(value.start == formatter.date(from: start))
            #expect(value.end == formatter.date(from: end))
        }
        let custom = APIQueryRange(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(86_400))
        #expect(APIPeriodSelection(preset: .custom, customRange: custom).range(organization: organization, now: now).end == now)
        let legacy = try JSONDecoder().decode(APICostSummary.self, from: Data(#"{"lines":[]}"#.utf8))
        #expect(legacy.days == nil)
    }

    @Test func costsPaginationDecimalCurrencyAndAttribution() async throws {
        let transport = QueueTransport(responses: [
            (200, page(start: 1_000, end: 2_000, rows: """
            {"amount":{"value":0.1,"currency":"usd"},"project_id":"proj_synthetic","line_item":"synthetic, input_tokens"}
            """, more: true, cursor: "next+page")),
            (200, page(start: 2_000, end: 3_000, rows: """
            {"amount":{"value":0.2,"currency":"usd"},"project_id":"proj_synthetic"},
            {"amount":{"value":-0.05,"currency":"usd"},"project_id":"proj_synthetic"},
            {"amount":{"value":1.25,"currency":"eur"},"project_id":"proj_synthetic"}
            """))
        ])
        let value = try await APIUsageClient(transport: transport).costs(organization: organization,
                                                                       key: "synthetic-test-token", range: range)
        #expect(value.totals["USD"] == Decimal(string: "0.25"))
        #expect(value.totals["EUR"] == Decimal(string: "1.25"))
        #expect(value.days?.count == 2)
        #expect(value.days?.first?.totals["USD"] == Decimal(string: "0.1"))
        #expect(value.days?.last?.totals["USD"] == Decimal(string: "0.15"))
        #expect(value.days?.first?.totals["EUR"] == nil)
        #expect(value.days?.last?.start == Date(timeIntervalSince1970: 2_000))
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.path == "/v1/organization/costs")
        #expect(requests[0].value(forHTTPHeaderField: "OpenAI-Organization") == "org-synthetic")
        let query = URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "page", value: "next+page")))
        #expect(query.contains(URLQueryItem(name: "project_ids[]", value: "proj_synthetic")))
        #expect(query.contains(URLQueryItem(name: "group_by[]", value: "line_item")))
        #expect(query.contains(URLQueryItem(name: "start_time", value: "1000")))
        #expect(query.contains(URLQueryItem(name: "end_time", value: "3000")))
    }

    @Test func usageAggregatesPagesWithoutDoubleCountingCachedInput() async throws {
        let row = """
        {"model":"synthetic-model","project_id":"proj_synthetic","num_model_requests":2,
        "input_tokens":100,"output_tokens":20,"input_cached_tokens":30}
        """
        let transport = QueueTransport(responses: [(200, page(start: 1_000, end: 2_000, rows: row, more: true, cursor: "next")),
                                                    (200, page(start: 2_000, end: 3_000, rows: row))])
        let value = try await APIUsageClient(transport: transport).usage(organization: organization,
                                                                       key: "synthetic-test-token", range: range)
        #expect(value.models.count == 1)
        #expect(value.models.first?.inputTokens == 200)
        #expect(value.models.first?.cachedInputTokens == 60)
        #expect(value.models.first?.requests == 4)
        #expect(await transport.requests.first?.url?.path == "/v1/organization/usage/completions")
    }

    @Test(arguments: [401, 403, 429, 500])
    func statusDoesNotBecomeZero(_ status: Int) async throws {
        let transport = QueueTransport(responses: [(status, "{\"error\":\"untrusted text must not be surfaced\"}")])
        let expected: APIUsageError = status == 401 ? .unauthorized : (status == 403 ? .permissionDenied : .http(status))
        await #expect(throws: expected) {
            try await APIUsageClient(transport: transport).costs(organization: organization, key: "synthetic-test-token", range: range)
        }
    }

    @Test func missingMoneyWrongProjectMalformedAndOutOfRangeAreUnknown() async throws {
        for rows in ["{\"amount\":null}", "{\"amount\":{\"value\":2,\"currency\":\"usd\"},\"project_id\":\"proj_other\"}"] {
            let transport = QueueTransport(responses: [(200, page(start: 1_000, end: 3_000, rows: rows))])
            await #expect(throws: APIUsageError.malformedResponse) {
                try await APIUsageClient(transport: transport).costs(organization: organization, key: "synthetic-test-token", range: range)
            }
        }
        let transport = QueueTransport(responses: [(200, page(start: 3_000, end: 86_400, rows: ""))])
        await #expect(throws: APIUsageError.rangeUnavailable) {
            try await APIUsageClient(transport: transport).costs(organization: organization, key: "synthetic-test-token", range: range)
        }
    }

    @Test func brokenPaginationAndDuplicateBucketsFail() async throws {
        for cursor in [nil, "repeat"] as [String?] {
            let first = page(start: 1_000, end: 2_000, rows: "", more: true, cursor: cursor)
            let transport = QueueTransport(responses: [(200, first), (200, first)])
            await #expect(throws: APIUsageError.pagination) {
                try await APIUsageClient(transport: transport).costs(organization: organization, key: "synthetic-test-token", range: range)
            }
        }
    }

    @Test func networkErrorAndInvalidJSONStayExplicit() async throws {
        await #expect(throws: APIUsageError.transport) {
            try await APIUsageClient(transport: BrokenTransport()).costs(organization: organization, key: "synthetic-test-token", range: range)
        }
        await #expect(throws: APIUsageError.malformedResponse) {
            try await APIUsageClient(transport: QueueTransport(responses: [(200, "not JSON")]))
                .costs(organization: organization, key: "synthetic-test-token", range: range)
        }
    }

    @Test func utcBillingDayRangeAndCacheStaleness() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2030-05-10T16:00:01Z"))
        let today = APIQueryRange.today(now: now)
        #expect(today.start == ISO8601DateFormatter().date(from: "2030-05-10T00:00:00Z"))
        #expect(today.end == now)
        let report = APIReport<APICostSummary>(range: today, value: APICostSummary(lines: []), fetchedAt: now)
        #expect(!report.isStale(now: now.addingTimeInterval(1_799)))
        #expect(report.isStale(now: now.addingTimeInterval(1_800)))
        var failed = report; failed.error = "permission denied"
        #expect(failed.isStale(now: now))
    }

    @Test func exponentZeroAndAlignedBucketsRemainExactWithoutRewritingStrings() async throws {
        let transport = QueueTransport(responses: [(200, page(start: 0, end: 86_400, rows: """
        {"amount":{"value":0E-6176,"currency":"usd"},"project_id":"proj_synthetic","line_item":"literal 0E-6176"},
        {"amount":{"value":0.000000000001,"currency":"usd"},"project_id":"proj_synthetic"}
        """))])
        let summary = try await APIUsageClient(transport: transport).costs(organization: organization,
                                                                         key: "synthetic-test-token", range: range)
        #expect(summary.totals["USD"] == Decimal(string: "0.000000000001"))
        #expect(summary.lines.first?.lineItem == "literal 0E-6176")
        #expect(summary.bucketRange?.start == Date(timeIntervalSince1970: 0))
        #expect(summary.bucketRange?.end == Date(timeIntervalSince1970: 86_400))
    }

    @Test func grantsUseHalfOpenIntervalsAndExactExpiryReminders() throws {
        let issued = Date(timeIntervalSince1970: 1_000_000)
        let expiry = issued.addingTimeInterval(10 * 86_400)
        let grant = APICreditGrant(organizationID: "org-synthetic", amount: 50, currency: "usd",
                                   issuedAt: issued, expiresAt: expiry, source: "synthetic invoice", verifiedAt: issued)
        try grant.validate()
        #expect(!grant.isActive(at: issued.addingTimeInterval(-1)))
        #expect(grant.isActive(at: issued))
        #expect(!grant.isActive(at: expiry))
        let reminders = APICreditReminderPlanner.reminders(grants: [grant], now: issued)
        #expect(reminders.map(\.days) == [7, 3, 1])
        #expect(reminders.first?.fireAt == expiry.addingTimeInterval(-7 * 86_400))
        #expect(Set(reminders.map(\.id)).count == 3)
        #expect(APICreditReminderPlanner.reminders(grants: [grant], now: expiry).isEmpty)
        var short = grant; short.issuedAt = expiry.addingTimeInterval(-2 * 86_400)
        #expect(APICreditReminderPlanner.reminders(grants: [short], now: issued).map(\.days) == [1])
        var edited = grant; edited.expiresAt = expiry.addingTimeInterval(3_600)
        #expect(APICreditReminderPlanner.reminders(grants: [edited], now: issued).first?.id != reminders.first?.id)
        var invalid = grant; invalid.amount = -1
        #expect(throws: APIUsageError.invalidGrant) { try invalid.validate() }
    }

    private func page(start: Int, end: Int, rows: String, more: Bool = false, cursor: String? = nil) -> String {
        """
        {"data":[{"start_time":\(start),"end_time":\(end),"results":[\(rows)]}],
        "has_more":\(more),"next_page":\(cursor.map { "\"\($0)\"" } ?? "null")}
        """
    }
}

private actor QueueTransport: APIUsageTransport {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(responses: [(Int, String)]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let next = responses.removeFirst()
        return (Data(next.1.utf8), next.0)
    }
}
private struct BrokenTransport: APIUsageTransport {
    func data(for request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
}
