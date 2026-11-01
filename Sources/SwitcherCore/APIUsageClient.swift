import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol APIUsageTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
}

/// Ephemeral sessions do not persist cookies, credentials or response bodies.
public struct APIUsageURLTransport: APIUsageTransport {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct APIUsageClient: Sendable {
    private let transport: any APIUsageTransport
    public init(transport: any APIUsageTransport = APIUsageURLTransport()) { self.transport = transport }

    public func costs(organization: APIOrganization, key: String, range: APIQueryRange) async throws -> APICostSummary {
        let result: ([CostRow], APIQueryRange?) = try await fetch(path: "costs", groups: ["project_id", "line_item"],
                                            organization: organization, key: key, range: range)
        return APICostSummary(lines: try result.0.map { row in
            guard let value = row.amount?.value, !value.isNaN,
                  let currency = row.amount?.currency, currency.count == 3,
                  organization.projectID == nil || row.project_id == organization.projectID
            else { throw APIUsageError.malformedResponse }
            return APICostLine(amount: value, currency: currency, projectID: row.project_id, lineItem: row.line_item)
        }, bucketRange: result.1)
    }

    public func usage(organization: APIOrganization, key: String, range: APIQueryRange) async throws -> APIUsageSummary {
        let result: ([UsageRow], APIQueryRange?) = try await fetch(path: "usage/completions", groups: ["model", "project_id"],
                                              organization: organization, key: key, range: range)
        var models: [String: APIModelUsage] = [:]
        for row in result.0 {
            guard row.input_tokens >= 0, row.output_tokens >= 0, row.num_model_requests >= 0,
                  (row.input_cached_tokens ?? 0) >= 0,
                  organization.projectID == nil || row.project_id == organization.projectID
            else { throw APIUsageError.malformedResponse }
            let model = row.model ?? "未归属模型"
            let id = model + "|" + (row.project_id ?? "")
            var value = models[id] ?? APIModelUsage(model: model, projectID: row.project_id, requests: 0,
                                                   inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)
            value.requests = try adding(value.requests, row.num_model_requests)
            value.inputTokens = try adding(value.inputTokens, row.input_tokens)
            value.outputTokens = try adding(value.outputTokens, row.output_tokens)
            value.cachedInputTokens = try adding(value.cachedInputTokens, row.input_cached_tokens ?? 0)
            models[id] = value
        }
        return APIUsageSummary(models: models.values.sorted { $0.id < $1.id }, bucketRange: result.1)
    }

    private func adding(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw APIUsageError.malformedResponse }
        return sum
    }

    private func fetch<Row: Decodable & Sendable>(path: String, groups: [String], organization: APIOrganization,
                                                 key: String, range: APIQueryRange) async throws -> ([Row], APIQueryRange?) {
        try organization.validate()
        guard range.isValid else { throw APIUsageError.rangeUnavailable }
        guard !key.isEmpty else { throw APIUsageError.missingCredential }
        var page: String?
        var seenPages = Set<String>()
        var seenBuckets = Set<Int64>()
        var rows: [Row] = []
        var bucketStart: Int64?
        var bucketEnd: Int64?
        repeat {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://api.openai.com/v1/organization/\(path)")!
            url.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int64(range.start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int64(range.end.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: path == "costs" ? "180" : "31"),
            ] + groups.map { URLQueryItem(name: "group_by[]", value: $0) }
            if let project = organization.projectID {
                url.queryItems!.append(URLQueryItem(name: "project_ids[]", value: project))
            }
            if let page { url.queryItems!.append(URLQueryItem(name: "page", value: page)) }
            var request = URLRequest(url: url.url!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue(organization.id, forHTTPHeaderField: "OpenAI-Organization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let status: Int
            do { (data, status) = try await transport.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw APIUsageError.transport }
            switch status {
            case 200: break
            case 401: throw APIUsageError.unauthorized
            case 403: throw APIUsageError.permissionDenied
            default: throw APIUsageError.http(status)
            }
            let response: Page<Row>
            do { response = try JSONDecoder().decode(Page<Row>.self, from: Self.normalizeExponentZeros(data)) }
            catch { throw APIUsageError.malformedResponse }
            for bucket in response.data {
                guard bucket.start_time < Int64(range.end.timeIntervalSince1970),
                      bucket.end_time > Int64(range.start.timeIntervalSince1970),
                      bucket.start_time < bucket.end_time
                else { throw APIUsageError.rangeUnavailable }
                guard seenBuckets.insert(bucket.start_time).inserted else { throw APIUsageError.pagination }
                bucketStart = min(bucketStart ?? bucket.start_time, bucket.start_time)
                bucketEnd = max(bucketEnd ?? bucket.end_time, bucket.end_time)
                rows += bucket.results
            }
            if response.has_more {
                guard let next = response.next_page, !next.isEmpty,
                      seenPages.insert(next).inserted, seenPages.count <= 400
                else { throw APIUsageError.pagination }
                page = next
            } else { page = nil }
        } while page != nil
        let coverage = bucketStart.flatMap { start in bucketEnd.map {
            APIQueryRange(start: Date(timeIntervalSince1970: Double(start)), end: Date(timeIntervalSince1970: Double($0)))
        } }
        return (rows, coverage)
    }

    /// Some official zero amounts use a Decimal128 exponent outside Swift's range
    /// (e.g. 0E-6176). Normalize numeric zero tokens only; never round nonzero money
    /// or modify quoted strings. JSONDecoder still validates the resulting JSON.
    private static func normalizeExponentZeros(_ data: Data) -> Data {
        let bytes = Array(data)
        var output = Data(); var index = 0; var inString = false; var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                index += 1
            } else if byte == 34 {
                inString = true; output.append(byte); index += 1
            } else if byte == 45 || (48...57).contains(byte) {
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                let parts = token.split(whereSeparator: { $0 == "e" || $0 == "E" })
                if parts.count == 2,
                   token.range(of: #"^-?0(?:\.0+)?[eE][+-]?[0-9]+$"#, options: .regularExpression) != nil {
                    output.append(48)
                } else { output.append(contentsOf: bytes[start..<index]) }
            } else { output.append(byte); index += 1 }
        }
        return output
    }
}

private struct Page<Row: Decodable>: Decodable {
    var data: [Bucket<Row>]
    var has_more: Bool
    var next_page: String?
}
private struct Bucket<Row: Decodable>: Decodable {
    var start_time: Int64
    var end_time: Int64
    var results: [Row]
}
private struct CostRow: Decodable, Sendable {
    struct Amount: Decodable, Sendable { var value: Decimal?; var currency: String? }
    var amount: Amount?
    var project_id: String?
    var line_item: String?
}
private struct UsageRow: Decodable, Sendable {
    var model: String?
    var project_id: String?
    var num_model_requests: Int64
    var input_tokens: Int64
    var output_tokens: Int64
    var input_cached_tokens: Int64?
}
