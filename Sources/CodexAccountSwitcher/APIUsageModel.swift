import Combine
import Foundation
import SwitcherCore

@MainActor
final class APIUsageModel: ObservableObject {
    @Published private(set) var configuration = APIUsageConfiguration()
    @Published private(set) var snapshots: [APIUsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published var message: String?
    let isDemo: Bool
    private let store: APIUsageStore
    private let keys: any APIKeyStoring
    private let client: APIUsageClient
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var revision = UUID()
    private var notifications: APICreditNotifications?

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

    func start() {
        guard !isDemo, timerTask == nil else { return }
        notifications = APICreditNotifications()
        Task { await syncNotifications() }
        refresh()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
                guard let self else { return }
                self.refresh()
                await self.syncNotifications()
            }
        }
    }

    func select(_ id: String) {
        invalidateRefresh()
        var next = configuration; next.selectedID = id
        persist(next)
        refresh()
    }

    func saveOrganization(_ organization: APIOrganization, key: String) throws {
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
        // Save configuration before a new secret, so an interrupted save cannot orphan a key.
        try store.saveConfiguration(next)
        configuration = next
        if !cleanKey.isEmpty { try keys.save(cleanKey, organizationID: organization.id) }
        invalidateRefresh()
        snapshots.removeAll { $0.organization.id == organization.id && $0.organization != organization }
        try store.saveSnapshots(snapshots)
        refresh()
    }

    func disconnect() throws {
        guard let organization, !isDemo else { return }
        invalidateRefresh()
        try keys.delete(organizationID: organization.id)
        snapshots.removeAll { $0.organization.id == organization.id }
        try store.saveSnapshots(snapshots)
        message = "已断开：该组织的 Keychain 凭据和本地账单缓存已清理；赠额手工记录保留。"
    }

    func removeOrganization() async throws {
        guard let organization, !isDemo else { return }
        try disconnect()
        var next = configuration
        next.organizations.removeAll { $0.id == organization.id }
        next.grants.removeAll { $0.organizationID == organization.id }
        next.selectedID = next.organizations.first?.id
        try store.saveConfiguration(next); configuration = next
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
        do { try await notifications?.reconcile(grants: configuration.grants, enabled: configuration.remindersEnabled) }
        catch { message = "提醒排程失败：\(error.localizedDescription)" }
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

    func refresh() {
        guard !isDemo, !isRefreshing, let organization else { return }
        let generation = revision
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var next = APIUsageSnapshot(organization: organization, now: Date())
            do {
                guard let key = try keys.read(organizationID: organization.id) else { throw APIUsageError.missingCredential }
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
        var snapshot = APIUsageSnapshot(organization: org, now: now)
        snapshot.today.value = APICostSummary(lines: [APICostLine(amount: Decimal(string: "0.123456")!, currency: "USD",
                                                                 projectID: "proj_demo", lineItem: "synthetic-model, input_tokens")])
        snapshot.cycle.value = APICostSummary(lines: [APICostLine(amount: Decimal(string: "4.56789")!, currency: "USD",
                                                                 projectID: "proj_demo", lineItem: "synthetic-model, input_tokens")])
        snapshot.usage.value = APIUsageSummary(models: [APIModelUsage(model: "synthetic-model", projectID: "proj_demo",
                                                                   requests: 42, inputTokens: 120_000, outputTokens: 8_000,
                                                                   cachedInputTokens: 40_000)])
        snapshot.today.fetchedAt = now; snapshot.cycle.fetchedAt = now; snapshot.usage.fetchedAt = now
        snapshots = [snapshot]
    }
}
