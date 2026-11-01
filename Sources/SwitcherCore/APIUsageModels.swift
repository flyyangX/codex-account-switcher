import Foundation

/// API billing is explicitly bound to an organization, never to a Codex profile.
public struct APIOrganization: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var projectID: String?
    public var cycleStart: Date
    public var cycleEnd: Date

    public init(id: String, name: String, projectID: String? = nil, cycleStart: Date, cycleEnd: Date) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name
        self.projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.cycleStart = cycleStart
        self.cycleEnd = cycleEnd
    }

    public func validate() throws {
        guard id.hasPrefix("org-"), id.count > 4, !id.contains(where: \.isWhitespace),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cycleStart < cycleEnd, cycleEnd.timeIntervalSince(cycleStart) <= 366 * 86_400,
              projectID == nil || (projectID!.hasPrefix("proj_") && !projectID!.contains(where: \.isWhitespace))
        else { throw APIUsageError.invalidConfiguration }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct APIQueryRange: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) {
        // The API accepts Unix seconds; keep persisted/displayed boundaries identical.
        self.start = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970))
        self.end = Date(timeIntervalSince1970: floor(end.timeIntervalSince1970))
    }
    public var isValid: Bool { start < end }
    public static func today(now: Date) -> APIQueryRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return APIQueryRange(start: calendar.startOfDay(for: now), end: now)
    }
}

/// Date filters use UTC calendar days to match the official daily billing buckets.
public enum APIPeriodPreset: String, Codable, CaseIterable, Sendable {
    case today, last7Days, last30Days, thisMonth, lastMonth, configured, custom
    public var title: String {
        switch self {
        case .today: "今日"
        case .last7Days: "近 7 天"
        case .last30Days: "近 30 天"
        case .thisMonth: "本月"
        case .lastMonth: "上月"
        case .configured: "已设周期"
        case .custom: "自定义"
        }
    }
}

public struct APIPeriodSelection: Codable, Equatable, Sendable {
    public var preset: APIPeriodPreset
    public var customRange: APIQueryRange?
    public init(preset: APIPeriodPreset, customRange: APIQueryRange? = nil) {
        self.preset = preset; self.customRange = customRange
    }
    public func range(organization: APIOrganization, now: Date) -> APIQueryRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: now)
        let month = calendar.dateInterval(of: .month, for: now)!
        switch preset {
        case .today: return .today(now: now)
        case .last7Days, .last30Days:
            let days = preset == .last7Days ? 6 : 29
            return APIQueryRange(start: calendar.date(byAdding: .day, value: -days, to: day)!, end: now)
        case .thisMonth: return APIQueryRange(start: month.start, end: now)
        case .lastMonth:
            return APIQueryRange(start: calendar.date(byAdding: .month, value: -1, to: month.start)!, end: month.start)
        case .configured:
            return APIQueryRange(start: organization.cycleStart, end: min(organization.cycleEnd, now))
        case .custom:
            guard let customRange else { return APIQueryRange(start: now, end: now) }
            return APIQueryRange(start: customRange.start, end: min(customRange.end, now))
        }
    }
}

public struct APICostDay: Codable, Equatable, Sendable, Identifiable {
    public var start: Date
    public var end: Date
    public var totals: [String: Decimal]
    public var id: Date { start }
    public init(start: Date, end: Date, totals: [String: Decimal]) {
        self.start = start; self.end = end; self.totals = totals
    }
}

public struct APICostLine: Codable, Equatable, Sendable {
    public var amount: Decimal
    public var currency: String
    public var projectID: String?
    public var lineItem: String?
    public init(amount: Decimal, currency: String, projectID: String?, lineItem: String?) {
        self.amount = amount
        self.currency = currency.uppercased()
        self.projectID = projectID
        self.lineItem = lineItem
    }
}

public struct APICostSummary: Codable, Equatable, Sendable {
    public var lines: [APICostLine]
    public var bucketRange: APIQueryRange?
    public var days: [APICostDay]?
    public init(lines: [APICostLine], bucketRange: APIQueryRange? = nil, days: [APICostDay]? = nil) {
        self.lines = lines; self.bucketRange = bucketRange; self.days = days
    }
    public var totals: [String: Decimal] {
        lines.reduce(into: [:]) { $0[$1.currency, default: 0] += $1.amount }
    }
}

public struct APIModelUsage: Codable, Equatable, Sendable, Identifiable {
    public var model: String
    public var projectID: String?
    public var requests: Int64
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cachedInputTokens: Int64
    public var id: String { model + "|" + (projectID ?? "") }
    public init(model: String, projectID: String?, requests: Int64, inputTokens: Int64,
                outputTokens: Int64, cachedInputTokens: Int64) {
        self.model = model; self.projectID = projectID; self.requests = requests
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }
}

public struct APIUsageSummary: Codable, Equatable, Sendable {
    public var models: [APIModelUsage]
    public var bucketRange: APIQueryRange?
    public init(models: [APIModelUsage], bucketRange: APIQueryRange? = nil) {
        self.models = models; self.bucketRange = bucketRange
    }
}

/// Each endpoint has its own status, so denied Costs never hides successful Usage.
public struct APIReport<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var range: APIQueryRange
    public var value: Value?
    public var fetchedAt: Date?
    public var error: String?
    public init(range: APIQueryRange, value: Value? = nil, fetchedAt: Date? = nil, error: String? = nil) {
        self.range = range; self.value = value; self.fetchedAt = fetchedAt; self.error = error
    }
    public func isStale(now: Date) -> Bool {
        error != nil || fetchedAt.map { now.timeIntervalSince($0) >= 30 * 60 } ?? true
    }
}

public struct APIUsageSnapshot: Codable, Equatable, Sendable {
    public var organization: APIOrganization
    public var today: APIReport<APICostSummary>
    public var cycle: APIReport<APICostSummary>
    public var usage: APIReport<APIUsageSummary>
    public init(organization: APIOrganization, now: Date, period: APIPeriodSelection? = nil) {
        self.organization = organization
        let range = (period ?? APIPeriodSelection(preset: .configured)).range(organization: organization, now: now)
        today = APIReport(range: .today(now: now))
        cycle = APIReport(range: range)
        usage = APIReport(range: range)
    }
}

public struct APICreditGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var organizationID: String
    public var amount: Decimal
    public var currency: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var source: String
    public var verifiedAt: Date
    public init(id: UUID = UUID(), organizationID: String, amount: Decimal, currency: String,
                issuedAt: Date, expiresAt: Date, source: String, verifiedAt: Date) {
        self.id = id; self.organizationID = organizationID; self.amount = amount
        self.currency = currency.uppercased(); self.issuedAt = issuedAt
        self.expiresAt = expiresAt; self.source = source; self.verifiedAt = verifiedAt
    }
    public func validate() throws {
        guard amount > 0, !amount.isNaN, issuedAt < expiresAt,
              currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isLetter }),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw APIUsageError.invalidGrant }
    }
    public func isActive(at date: Date) -> Bool { issuedAt <= date && date < expiresAt }
}

public struct APICreditReminder: Equatable, Identifiable, Sendable {
    public var id: String
    public var grantID: UUID
    public var fireAt: Date
    public var days: Int
}

public enum APICreditReminderPlanner {
    public static func reminders(grants: [APICreditGrant], now: Date) -> [APICreditReminder] {
        grants.flatMap { grant in
            [7, 3, 1].compactMap { days -> APICreditReminder? in
                let date = grant.expiresAt.addingTimeInterval(-Double(days) * 86_400)
                guard date > now, date >= grant.issuedAt else { return nil }
                return APICreditReminder(
                    id: "api-credit.\(grant.id.uuidString).\(Int(grant.expiresAt.timeIntervalSince1970)).\(days)",
                    grantID: grant.id, fireAt: date, days: days)
            }
        }.sorted { $0.fireAt < $1.fireAt }
    }
}

public enum APIUsageError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, invalidGrant, missingCredential, permissionDenied, unauthorized
    case http(Int), transport, malformedResponse, pagination, rangeUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "请填写组织 ID、名称和有效统计周期（最长 366 天）；项目 ID 应以 proj_ 开头。"
        case .invalidGrant: "请填写正数金额、三位币种、来源和有效的发放／到期时间。"
        case .missingCredential: "未连接：请保存该组织的 Admin API Key。"
        case .permissionDenied: "权限不足（403）：请核对 Admin Key 的组织和 Usage／Costs 读取权限。"
        case .unauthorized: "认证失败（401）：请检查或更换该组织的 Admin API Key。"
        case .http(let status): "官方接口返回 HTTP \(status)，保留上次成功数据。"
        case .transport: "网络连接失败或超时，保留上次成功数据。"
        case .malformedResponse: "官方数据缺少必要字段或归属不符，未将其视为零。"
        case .pagination: "分页未完成，未使用不完整统计。"
        case .rangeUnavailable: "该范围尚未开始，或官方返回的日桶超出精确查询范围；请到官方账单核对。"
        }
    }
}
