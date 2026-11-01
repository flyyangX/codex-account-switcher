import Combine
import Foundation
import SwitcherCore

@MainActor
final class APIUsageModel: ObservableObject {
    @Published private(set) var configuration = APIUsageConfiguration()
    @Published private(set) var snapshots: [APIUsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published var message: String?
    @Published private(set) var reminderStatus = "尚未检查通知权限与排程"
    let isDemo: Bool
    private let store: APIUsageStore
    private let keys: any APIKeyStoring
    private let client: APIUsageClient
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var revision = UUID()
    private var notifications: APICreditNotifications?
    private var credentialCache: [String: String] = [:]
    lazy var webBilling = APIWebBillingController()

    init(store: APIUsageStore = APIUsageStore(), keys: any APIKeyStoring = APIKeychain(),
         client: APIUsageClient = APIUsageClient(), demo: Bool = false) {
        self.store = store; self.keys = keys; self.client = client; self.isDemo = demo
        if demo { loadDemo() }
        else {
            do { configuration = try store.loadConfiguration(); snapshots = try store.loadSnapshots() }
            catch { message = "API 配置或缓存读取失败，请检查本地文件；未将其视为无数据。" }
        }
    }

    var organization: APIOrganization? { configuration.organizations.first { $0.id == configuration.selectedID } }
    var snapshot: APIUsageSnapshot? { snapshots.first { $0.organization == organization } }
    var grants: [APICreditGrant] {
        configuration.grants.filter { $0.organizationID == organization?.id }.sorted { $0.expiresAt < $1.expiresAt }
    }

    var creditBalance: APICreditBalance? { configuration.creditBalances[organization?.id ?? ""] }

    func saveCreditBalance(_ balance: APICreditBalance) throws {
        guard let organization else { throw APIUsageError.invalidConfiguration }
        try balance.validate()
        var next = configuration; next.creditBalances[organization.id] = balance
        if !isDemo { try store.saveConfiguration(next) }
        configuration = next
    }

    func prepareWebBilling(organizationID: String) throws -> UUID {
        guard !isDemo, configuration.organizations.contains(where: { $0.id == organizationID }) else { throw APIUsageError.invalidConfiguration }
        if let connection = configuration.webBilling[organizationID] { return connection.profileID }
        var next = configuration
        let connection = APIWebBillingConnection()
        next.webBilling[organizationID] = connection
        try store.saveConfiguration(next); configuration = next
        return connection.profileID
    }

    func syncWebBilling(organizationID: String, interactive: Bool = false) async {
        guard !isDemo, let org = configuration.organizations.first(where: { $0.id == organizationID }),
              let connection = configuration.webBilling[organizationID],
              !webBilling.busyIDs.contains(organizationID) else { return }
        do {
            let result = try await webBilling.sync(organization: org, profileID: connection.profileID, interactive: interactive)
            try Task.checkCancellation()
            guard configuration.webBilling[organizationID]?.profileID == connection.profileID else { return }
            var next = configuration
            next.creditBalances[organizationID] = result.balance
            next.webBilling[organizationID]?.enabled = true
            if let expiry = result.nextExpiry {
                for index in next.accounts.indices where next.accounts[index].organizationID == organizationID {
                    next.accounts[index].expiryDate = expiry
                    next.accounts[index].expiryTimeZone = "Asia/Shanghai"
                    next.accounts[index].creditNote = "官方赠额网页自动同步；仅显示到期日期，精确时刻待核实。"
                }
            }
            try store.saveConfiguration(next); configuration = next
            await syncNotifications()
        } catch is CancellationError {
            webBilling.setStatus("已暂停网页连接", organizationID: organizationID)
        } catch {
            webBilling.setStatus(error.localizedDescription, organizationID: organizationID)
        }
    }

    private func syncConnectedWebBilling() async {
        for (id, connection) in configuration.webBilling where connection.enabled {
            guard !Task.isCancelled else { return }
            await syncWebBilling(organizationID: id)
        }
    }

    func pauseWebBilling() {
        guard let id = organization?.id else { return }
        var next = configuration; next.webBilling[id]?.enabled = false
        persist(next)
        webBilling.cancel(organizationID: id)
        webBilling.setStatus("已暂停网页自动同步，历史数据保留。", organizationID: id)
    }

    func refreshAll() {
        refresh()
        if let id = organization?.id, configuration.webBilling[id]?.enabled == true {
            Task { await syncWebBilling(organizationID: id) }
        }
    }

    func authorizeCredential() {
        guard !isRefreshing else { return }
        invalidateRefresh()
        refresh(allowKeychainInteraction: true)
    }

    var period: APIPeriodSelection {
        configuration.periods[organization?.id ?? ""] ?? APIPeriodSelection(preset: .configured)
    }

    func setPeriod(_ selection: APIPeriodSelection) throws {
        guard let organization else { return }
        let range = selection.range(organization: organization, now: Date())
        guard range.isValid, range.end.timeIntervalSince(range.start) <= 366 * 86_400 else {
            throw APIUsageError.rangeUnavailable
        }
        var next = configuration; next.periods[organization.id] = selection
        if !isDemo { try store.saveConfiguration(next) }
        invalidateRefresh(); configuration = next
        if isDemo { updateDemoSnapshot() } else { refresh() }
    }

    func start() {
        guard !isDemo, timerTask == nil else { return }
        notifications = APICreditNotifications()
        Task { await syncNotifications(); await syncConnectedWebBilling() }
        refresh()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
                guard let self else { return }
                self.refresh()
                await self.syncNotifications()
                await self.syncConnectedWebBilling()
            }
        }
    }

    func select(_ id: String) {
        invalidateRefresh()
        var next = configuration; next.selectedID = id
        persist(next)
        refreshAll()
    }

    func saveOrganization(_ organization: APIOrganization, key: String, accountID: UUID? = nil) throws {
        try organization.validate()
        guard !isDemo else { throw APIUsageError.invalidConfiguration }
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            guard cleanKey.hasPrefix("sk-admin-"), !cleanKey.contains(where: \.isWhitespace) else {
                throw APIUsageError.unauthorized
            }
        }
        var next = configuration
        // One record and one credential per organization, regardless of Codex account count.
        next.organizations.removeAll { $0.id == organization.id }
        next.organizations.append(organization)
        next.selectedID = organization.id
        if let accountID, let index = next.accounts.firstIndex(where: { $0.id == accountID }) {
            next.accounts[index].organizationID = organization.id
            next.accounts[index].credentialNote = "已绑定组织；实际账单权限以下方同步结果为准。"
        }
        // Save configuration before a new secret, so an interrupted save cannot orphan a key.
        try store.saveConfiguration(next)
        configuration = next
        if !cleanKey.isEmpty {
            try keys.save(cleanKey, organizationID: organization.id)
            credentialCache[organization.id] = cleanKey
        }
        invalidateRefresh()
        snapshots.removeAll { $0.organization.id == organization.id && $0.organization != organization }
        try store.saveSnapshots(snapshots)
        refresh()
    }

    @discardableResult
    func registerAccount(name: String, organizationID: String? = nil,
                         credentialNote: String, creditNote: String) throws -> APITrackedAccount {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw APIUsageError.invalidConfiguration }
        var next = configuration
        let existing = next.accounts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let account = APITrackedAccount(id: existing?.id ?? UUID(), name: name,
                                        organizationID: organizationID ?? existing?.organizationID,
                                        credentialNote: credentialNote, creditNote: creditNote,
                                        expiryDate: existing?.expiryDate, expiryTimeZone: existing?.expiryTimeZone)
        next.accounts.removeAll { $0.id == account.id }; next.accounts.append(account)
        if !isDemo { try store.saveConfiguration(next) }
        configuration = next
        return account
    }

    func setDateOnlyExpiry(accountID: UUID, date: String?) async throws {
        let date = date?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = date?.isEmpty == true ? nil : date
        if let value, APIDateOnlyReminderPlanner.parse(value, timeZone: "Asia/Shanghai") == nil {
            throw APIUsageError.invalidGrant
        }
        var next = configuration
        guard let index = next.accounts.firstIndex(where: { $0.id == accountID }) else { throw APIUsageError.invalidConfiguration }
        next.accounts[index].expiryDate = value
        next.accounts[index].expiryTimeZone = value == nil ? nil : "Asia/Shanghai"
        if !isDemo { try store.saveConfiguration(next) }
        configuration = next
        if notifications == nil && !isDemo { notifications = APICreditNotifications() }
        await syncNotifications()
    }

    func disconnect() throws {
        guard let organization, !isDemo else { return }
        invalidateRefresh()
        credentialCache.removeValue(forKey: organization.id)
        try keys.delete(organizationID: organization.id)
        snapshots.removeAll { $0.organization.id == organization.id }
        try store.saveSnapshots(snapshots)
        message = "已断开：该组织的 Keychain 凭据和本地账单缓存已清理；赠额手工记录保留。"
    }

    func removeOrganization() async throws {
        guard let organization, !isDemo else { return }
        try disconnect()
        let webConnection = configuration.webBilling[organization.id]
        var next = configuration
        next.organizations.removeAll { $0.id == organization.id }
        next.grants.removeAll { $0.organizationID == organization.id }
        next.periods.removeValue(forKey: organization.id)
        next.creditBalances.removeValue(forKey: organization.id)
        next.webBilling.removeValue(forKey: organization.id)
        webBilling.cancel(organizationID: organization.id)
        next.selectedID = next.organizations.first?.id
        for index in next.accounts.indices where next.accounts[index].organizationID == organization.id {
            next.accounts[index].organizationID = nil
            next.accounts[index].credentialNote = "组织已移除，待重新绑定。"
        }
        try store.saveConfiguration(next); configuration = next
        if let webConnection {
            await webBilling.clearProfile(organizationID: organization.id, profileID: webConnection.profileID)
        }
        await syncNotifications()
    }

    func saveGrant(_ grant: APICreditGrant) async throws {
        try grant.validate()
        guard configuration.organizations.contains(where: { $0.id == grant.organizationID }) else {
            throw APIUsageError.invalidConfiguration
        }
        var next = configuration
        next.grants.removeAll { $0.id == grant.id }; next.grants.append(grant)
        if !isDemo { try store.saveConfiguration(next) }
        configuration = next
        await syncNotifications()
    }

    func deleteGrant(_ id: UUID) async {
        var next = configuration; next.grants.removeAll { $0.id == id }
        persist(next)
        await syncNotifications()
    }

    func useGrantPeriod(_ grant: APICreditGrant) throws {
        guard var organization else { return }
        organization.cycleStart = grant.issuedAt; organization.cycleEnd = grant.expiresAt
        try saveOrganization(organization, key: "")
        try setPeriod(APIPeriodSelection(preset: .configured))
    }

    func setReminders(_ enabled: Bool) async {
        guard !isDemo else { message = "演示模式不请求系统通知权限。"; return }
        do {
            if notifications == nil { notifications = APICreditNotifications() }
            if enabled, try await notifications?.enable() != true {
                message = "通知未获授权，请在系统设置中允许后重试。"; return
            }
            var next = configuration; next.remindersEnabled = enabled
            try store.saveConfiguration(next); configuration = next
            await syncNotifications()
        } catch { message = error.localizedDescription }
    }

    private func syncNotifications() async {
        guard !isDemo else { return }
        var syncError: String?
        do {
            try await notifications?.reconcile(grants: configuration.grants, accounts: configuration.accounts,
                                               enabled: configuration.remindersEnabled)
            if !configuration.remindersEnabled { reminderStatus = "未启用" }
            else if notifications == nil { reminderStatus = "尚未检查通知权限与排程" }
            else {
                let count = min(60, APICreditReminderPlanner.reminders(grants: configuration.grants, now: Date()).count
                    + APIDateOnlyReminderPlanner.reminders(accounts: configuration.accounts, now: Date()).count)
                reminderStatus = count > 0 ? "已排程 \(count) 条本机提醒" : "未排程：尚无已核实的赠额批次／未来提醒时点"
            }
        } catch {
            syncError = error.localizedDescription
            reminderStatus = "未生效：通知权限或排程失败"
            message = "提醒排程失败：\(error.localizedDescription)"
        }
        if let notifications {
            do {
                var status = await notifications.status()
                status.error = syncError ?? status.error
                if configuration.remindersEnabled && syncError == nil && !status.pendingIDs.isEmpty {
                    reminderStatus = "系统已确认待发送 \(status.pendingIDs.count) 条本机提醒（本功能总计）"
                }
                try store.saveNotificationStatus(status)
            }
            catch { message = "通知状态回读保存失败：\(error.localizedDescription)" }
        }
    }

    private func persist(_ next: APIUsageConfiguration) {
        do {
            if !isDemo { try store.saveConfiguration(next) }
            configuration = next
        } catch { message = "API 配置保存失败：\(error.localizedDescription)" }
    }

    private func invalidateRefresh() {
        revision = UUID(); refreshTask?.cancel(); refreshTask = nil; isRefreshing = false
    }

    func refresh(allowKeychainInteraction: Bool = false) {
        guard !isDemo, !isRefreshing, let organization else { return }
        let generation = revision
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var next = APIUsageSnapshot(organization: organization, now: Date(), period: period)
            do {
                let cachedKey = credentialCache[organization.id]
                let loadedKey: String?
                if let cachedKey { loadedKey = cachedKey }
                else { loadedKey = try await keys.readForRefresh(organizationID: organization.id, allowInteraction: allowKeychainInteraction) }
                guard let key = loadedKey else { throw APIUsageError.missingCredential }
                credentialCache[organization.id] = key
                try Task.checkCancellation()
                let old = snapshot
                let todayRange = next.today.range
                let cycleRange = next.cycle.range
                async let today = report(range: todayRange, old: old?.today) { [client] range in
                    try await client.costs(organization: organization, key: key, range: range)
                }
                async let cycle = report(range: cycleRange, old: old?.cycle) { [client] range in
                    try await client.costs(organization: organization, key: key, range: range)
                }
                async let usage = report(range: cycleRange, old: old?.usage) { [client] range in
                    try await client.usage(organization: organization, key: key, range: range)
                }
                next.today = await today; next.cycle = await cycle; next.usage = await usage
            } catch {
                let text = error.localizedDescription
                // No Keychain access is treated as an unknown connection, never as zero.
                if let old = snapshot { next = old }
                next.today.error = text; next.cycle.error = text; next.usage.error = text
            }
            guard !Task.isCancelled, revision == generation, self.organization == organization else { return }
            snapshots.removeAll { $0.organization.id == organization.id }; snapshots.append(next)
            do { try store.saveSnapshots(snapshots) }
            catch { message = "API 缓存保存失败：\(error.localizedDescription)" }
            isRefreshing = false; refreshTask = nil
        }
    }

    func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }

    private func report<T>(range: APIQueryRange, old: APIReport<T>?,
                           fetch: @Sendable (APIQueryRange) async throws -> T) async -> APIReport<T> {
        do { return APIReport(range: range, value: try await fetch(range), fetchedAt: Date()) }
        catch {
            // Keep the old range alongside the old value; never relabel a previous day's total as today.
            var result = old ?? APIReport(range: range)
            result.error = (error as? APIUsageError)?.localizedDescription ?? APIUsageError.transport.localizedDescription
            return result
        }
    }

    private func loadDemo() {
        let now = Date()
        let org = APIOrganization(id: "org-demo-synthetic", name: "演示组织（合成数据）", projectID: "proj_demo",
                                  cycleStart: now.addingTimeInterval(-5 * 86_400), cycleEnd: now.addingTimeInterval(12 * 86_400))
        configuration.organizations = [org]; configuration.selectedID = org.id
        configuration.grants = [APICreditGrant(organizationID: org.id, amount: 50, currency: "USD",
                                              issuedAt: org.cycleStart, expiresAt: org.cycleEnd,
                                              source: "合成演示账单", verifiedAt: now)]
        configuration.accounts = [APITrackedAccount(name: "Demo workspace", organizationID: org.id,
                                                    credentialNote: "合成演示", creditNote: "合成演示赠额")]
        configuration.creditBalances[org.id] = APICreditBalance(totalCredits: 50, remainingCredits: 38, currency: "USD",
                                                              isInitialGrantOnly: false, source: "合成演示账单", verifiedAt: now)
        configuration.periods[org.id] = APIPeriodSelection(preset: .last7Days)
        updateDemoSnapshot()
    }

    private func updateDemoSnapshot() {
        guard let org = organization else { return }
        let now = Date()
        var snapshot = APIUsageSnapshot(organization: org, now: now, period: period)
        var days: [APICostDay] = []
        var date = snapshot.cycle.range.start
        let samples = ["0.42", "0.71", "0.53", "1.18", "0.86", "1.42", "0.63"]
        while date < snapshot.cycle.range.end {
            let amount = Decimal(string: samples[days.count % samples.count])!
            days.append(APICostDay(start: date, end: date.addingTimeInterval(86_400), totals: ["USD": amount]))
            date = date.addingTimeInterval(86_400)
        }
        snapshot.today.value = APICostSummary(lines: [APICostLine(amount: Decimal(string: "0.63")!, currency: "USD",
                                                                 projectID: "proj_demo", lineItem: "synthetic-model, input_tokens")])
        snapshot.cycle.value = APICostSummary(lines: days.map {
            APICostLine(amount: $0.totals["USD"]!, currency: "USD", projectID: "proj_demo", lineItem: "synthetic-model, input_tokens")
        }, bucketRange: APIQueryRange(start: days.first!.start, end: days.last!.end), days: days)
        snapshot.usage.value = APIUsageSummary(models: [
            APIModelUsage(model: "demo-reasoning", projectID: "proj_demo", requests: 142,
                          inputTokens: 820_000, outputTokens: 180_000, cachedInputTokens: 340_000),
            APIModelUsage(model: "demo-fast", projectID: "proj_demo", requests: 86,
                          inputTokens: 240_000, outputTokens: 65_000, cachedInputTokens: 100_000)])
        snapshot.today.fetchedAt = now; snapshot.cycle.fetchedAt = now; snapshot.usage.fetchedAt = now
        snapshots = [snapshot]
    }
}
