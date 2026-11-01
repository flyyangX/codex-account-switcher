import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit
import SwitcherCore

struct APIWebCreditPage: Decodable, Sendable {
    var headers: [String]
    var rows: [[String]]
    var hasMore: Bool
}

struct APIWebBillingResult: Sendable {
    var balance: APICreditBalance
    var nextExpiry: String?
}

enum APIWebBillingError: LocalizedError {
    case loginRequired, wrongOrganization, layoutChanged, incompletePage, busy, network
    var errorDescription: String? {
        switch self {
        case .loginRequired: "网页登录尚未完成或已失效，请打开网页登录。"
        case .wrongOrganization: "请在网页切换到当前账号对应的组织；尚未保存其他组织的数据。"
        case .layoutChanged: "未能完整识别官方赠额表格，保留上次结果。请打开网页检查。"
        case .incompletePage: "赠额表格包含其他页，尚未取得完整数据；保留上次结果。"
        case .busy: "该账号正在同步网页账单。"
        case .network: "官方网页暂时无法加载，保留上次结果。"
        }
    }
}

/// Reads rendered credit-grant table cells only. Never treats the page's used/total meter as balance.
enum APIWebCreditParser {
    static func parse(_ page: APIWebCreditPage, now: Date = Date()) throws -> APIWebBillingResult {
        guard !page.hasMore else { throw APIWebBillingError.incompletePage }
        let headers = page.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let stateIndex = headers.firstIndex(where: { ["state", "status", "状态"].contains($0) }),
              let balanceIndex = headers.firstIndex(where: { ["balance", "余额"].contains($0) }),
              let expiryIndex = headers.firstIndex(where: { ["expires", "expiration", "到期时间", "到期日期"].contains($0) }),
              !page.rows.isEmpty else { throw APIWebBillingError.layoutChanged }
        var total = Decimal.zero; var remaining = Decimal.zero; var expiryDates: [String] = []
        var activeCount = 0
        for row in page.rows {
            guard row.count > max(stateIndex, balanceIndex, expiryIndex) else { throw APIWebBillingError.layoutChanged }
            let state = row[stateIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["expired", "exhausted", "used", "used up", "已到期", "已过期", "已用完"].contains(state) { continue }
            guard ["available", "active", "可用", "有效"].contains(state) else { throw APIWebBillingError.layoutChanged }
            let halves = row[balanceIndex].split(separator: "/", omittingEmptySubsequences: false)
            guard halves.count == 2 else { throw APIWebBillingError.layoutChanged }
            let available = try usd(String(halves[0])); let granted = try usd(String(halves[1]))
            guard available <= granted else { throw APIWebBillingError.layoutChanged }
            total += granted; remaining += available; activeCount += 1
            if let expiry = dateOnly(row[expiryIndex]) { expiryDates.append(expiry) }
            else if !["never", "no expiration", "永不过期", "不过期"].contains(row[expiryIndex].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) {
                throw APIWebBillingError.layoutChanged
            }
        }
        let value = APICreditBalance(totalCredits: total, remainingCredits: remaining, currency: "USD",
                                    isInitialGrantOnly: false,
                                    source: "官方 Credit grants 网页自动同步；仅合计 Available 有效批次（\(activeCount) 批），不含历史过期批次。",
                                    verifiedAt: now, webSynced: true)
        try value.validate()
        return APIWebBillingResult(balance: value, nextExpiry: expiryDates.sorted().first)
    }

    private static func usd(_ text: String) throws -> Decimal {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^(?:\$|USD\s*|US\$)(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value.replacingOccurrences(of: "USD", with: "").replacingOccurrences(of: "US", with: "")
                .replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces),
                locale: Locale(identifier: "en_US_POSIX")) else { throw APIWebBillingError.layoutChanged }
        return amount
    }

    static func dateOnly(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false
        for format in ["yyyy-MM-dd", "yyyy/M/d", "MMM d, yyyy", "MMMM d, yyyy", "yyyy年M月d日"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
            }
        }
        return nil
    }
}

@MainActor
final class APIWebBillingController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var busyIDs: Set<String> = []
    private var views: [String: WKWebView] = [:]
    private var generations: [String: UUID] = [:]
    private static let general = URL(string: "https://platform.openai.com/settings/organization/general")!
    private static let credits = URL(string: "https://platform.openai.com/settings/organization/billing/credit-grants")!

    func webView(organizationID: String, profileID: UUID) -> WKWebView {
        if let view = views[organizationID] { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileID)
        configuration.applicationNameForUserAgent = "CodexAPIMonitor"
        // A zero-sized detached view makes the responsive billing page hide its desktop table.
        // Keep a real viewport for background sync, even before any login sheet is presented.
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        views[organizationID] = view
        return view
    }

    func setStatus(_ value: String, organizationID: String) { statuses[organizationID] = value }
    func cancel(organizationID: String) {
        generations[organizationID] = UUID()
        views[organizationID]?.stopLoading()
        busyIDs.remove(organizationID)
    }

    func clearProfile(organizationID: String, profileID: UUID) async {
        cancel(organizationID: organizationID)
        let store = views.removeValue(forKey: organizationID)?.configuration.websiteDataStore
            ?? WKWebsiteDataStore(forIdentifier: profileID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        statuses.removeValue(forKey: organizationID)
    }

    func sync(organization: APIOrganization, profileID: UUID, interactive: Bool) async throws -> APIWebBillingResult {
        let id = organization.id
        guard !busyIDs.contains(id) else { throw APIWebBillingError.busy }
        let generation = UUID(); generations[id] = generation; busyIDs.insert(id)
        defer { if generations[id] == generation { busyIDs.remove(id) } }
        let view = webView(organizationID: id, profileID: profileID)
        setStatus(interactive ? "请在下方登录，并选择对应组织；登录完成后自动同步。" : "正在核对网页登录状态…", organizationID: id)
        view.load(URLRequest(url: Self.general))
        try await verifyOrganization(view, id: id, generation: generation, attempts: interactive ? 300 : 20)
        setStatus("组织已核对，正在读取官方赠额…", organizationID: id)
        view.load(URLRequest(url: Self.credits))
        var result: APIWebBillingResult?
        for _ in 0..<30 {
            try await pause(id: id, generation: generation)
            guard matches(view, url: Self.credits), !view.isLoading else { continue }
            guard let json = try? await view.evaluateJavaScript(Self.creditTableScript) as? String,
                  let data = json.data(using: .utf8),
                  let page = try? JSONDecoder().decode(APIWebCreditPage.self, from: data) else { continue }
            if page.hasMore { throw APIWebBillingError.incompletePage }
            if let parsed = try? APIWebCreditParser.parse(page) { result = parsed; break }
        }
        guard let result else { throw APIWebBillingError.layoutChanged }
        // Recheck the visible organization ID after reading to catch an intervening org switch.
        view.load(URLRequest(url: Self.general))
        try await verifyOrganization(view, id: id, generation: generation, attempts: 20)
        setStatus("网页自动同步成功 · \(Date().formatted(date: .omitted, time: .shortened))", organizationID: id)
        if interactive { view.load(URLRequest(url: Self.credits)) }
        return result
    }

    private func verifyOrganization(_ view: WKWebView, id: String, generation: UUID, attempts: Int) async throws {
        var wrongOrganization = false
        for _ in 0..<attempts {
            try await pause(id: id, generation: generation)
            if !view.isLoading, Self.shouldReturnToGeneral(view.url) {
                view.load(URLRequest(url: Self.general))
                continue
            }
            guard matches(view, url: Self.general), !view.isLoading else { continue }
            // Organization IDs are visible General-settings fields, not browser session material.
            let script = #"""
            (() => {
              const shown = e => !!(e.getClientRects().length) && getComputedStyle(e).visibility !== 'hidden';
              const inputs = [...document.querySelectorAll('input:not([type=password])')]
                .filter(shown).map(e => e.value).filter(v => /^org-[A-Za-z0-9]+$/.test(v));
              return JSON.stringify([...new Set([...(document.body.innerText.match(/\borg-[A-Za-z0-9]+\b/g) || []), ...inputs])]);
            })()
            """#
            if let json = try? await view.evaluateJavaScript(script) as? String,
               let data = json.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) {
                if ids == [id] { return }
                if !ids.isEmpty {
                    wrongOrganization = true
                    setStatus("请切换到组织 \(id)，自动同步会在匹配后继续。", organizationID: id)
                }
            }
        }
        throw wrongOrganization ? APIWebBillingError.wrongOrganization : APIWebBillingError.loginRequired
    }

    static func shouldReturnToGeneral(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "platform.openai.com" else { return false }
        return url.path != general.path && !url.path.hasPrefix("/auth")
            && !url.path.hasPrefix("/login") && !url.path.hasPrefix("/signup")
    }

    private func pause(id: String, generation: UUID) async throws {
        try await Task.sleep(for: .seconds(1))
        try Task.checkCancellation()
        guard generations[id] == generation else { throw CancellationError() }
    }
    private func matches(_ view: WKWebView, url: URL) -> Bool {
        view.url?.scheme == "https" && view.url?.host == url.host && view.url?.path == url.path
    }

    // Only visible table cell text is returned. Password inputs, cookies, storage and tokens are never read.
    static let creditTableScript = #"""
    (() => {
      const shown = e => !!e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
      const tables = [...document.querySelectorAll('table,[role=table]')].filter(shown);
      const table = tables.find(t => /BALANCE|余额/i.test(t.innerText) && /EXPIRES|到期/i.test(t.innerText));
      if (!table) return JSON.stringify({headers:[],rows:[],hasMore:false});
      const headers = [...table.querySelectorAll('thead th,[role=columnheader]')].map(e => e.innerText.trim());
      const rows = [...table.querySelectorAll('tbody tr,[role=row]')].filter(shown)
        .map(r => [...r.querySelectorAll('td,[role=cell]')].map(c => c.innerText.trim())).filter(r => r.length);
      const next = [...document.querySelectorAll('button,a[role=button]')].filter(shown).some(e =>
        /^(next|next page|下一页)$/i.test((e.getAttribute('aria-label') || e.innerText).trim()) &&
        !e.disabled && e.getAttribute('aria-disabled') !== 'true');
      return JSON.stringify({headers,rows,hasMore:next});
    })()
    """#

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private struct APIBillingWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct APIWebBillingSheet: View {
    @ObservedObject var model: APIUsageModel
    @ObservedObject var browser: APIWebBillingController
    let organization: APIOrganization
    let profileID: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("网页登录 · \(model.configuration.accounts.first { $0.organizationID == organization.id }?.name ?? organization.name)").font(.headline)
                    Text(browser.statuses[organization.id] ?? "准备连接官方网页…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重试同步") { Task { await model.syncWebBilling(organizationID: organization.id, interactive: true) } }
                    .disabled(browser.busyIDs.contains(organization.id))
                Button("完成") { browser.cancel(organizationID: organization.id); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            APIBillingWebView(webView: browser.webView(organizationID: organization.id, profileID: profileID))
            Divider()
            Text("每个账号使用独立网页登录状态。连接后应用运行时每 15 分钟同步；密码与验证码直接填在官方网页中。")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width: 1000, height: 740)
        .task { await model.syncWebBilling(organizationID: organization.id, interactive: true) }
    }
}

struct APIWebBillingStatusView: View {
    @ObservedObject var browser: APIWebBillingController
    let organizationID: String
    var body: some View {
        if let text = browser.statuses[organizationID] {
            Label(text, systemImage: browser.busyIDs.contains(organizationID) ? "arrow.triangle.2.circlepath" : "globe")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
