import AppKit
import Foundation
import SwiftUI
import Testing
import SwitcherCore
@testable import CodexAccountSwitcher

@MainActor
struct APIUsageModelTests {
    @Test func periodSelectionPersistsPerOrganizationAndFailedChangeKeepsActualRange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "api-period-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = APIUsageStore(directory: root)
        let transport = ModelTransport()
        let model = APIUsageModel(store: store, keys: MemoryKeys(), client: APIUsageClient(transport: transport))
        try model.saveOrganization(makeOrganization(), key: "sk-admin-synthetic-fixture-only")
        try model.setPeriod(APIPeriodSelection(preset: .lastMonth))
        await model.refreshAndWait()
        let old = try #require(model.snapshot)
        #expect(old.cycle.range == model.period.range(organization: makeOrganization(), now: Date()))
        #expect(try store.loadConfiguration().periods["org-synthetic"]?.preset == .lastMonth)
        await transport.setCostStatus(403)
        try model.setPeriod(APIPeriodSelection(preset: .last7Days))
        await model.refreshAndWait()
        #expect(model.snapshot?.cycle.range == old.cycle.range)
        #expect(model.snapshot?.cycle.error != nil)
        #expect(model.snapshot?.usage.range.start != old.usage.range.start)
        var other = makeOrganization(); other.id = "org-other"
        try model.saveOrganization(other, key: "sk-admin-synthetic-fixture-only")
        await model.refreshAndWait()
        #expect(model.period.preset == .configured)
        model.select("org-synthetic")
        await model.refreshAndWait()
        #expect(model.period.preset == .last7Days)
        let invalid = APIQueryRange(start: Date(), end: Date().addingTimeInterval(-86_400))
        #expect(throws: APIUsageError.rangeUnavailable) {
            try model.setPeriod(APIPeriodSelection(preset: .custom, customRange: invalid))
        }
    }

    @Test func verifiedCreditSnapshotIsIndependentOfCostFiltersAndKeepsUnknownBalance() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "api-credit-snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = APIUsageStore(directory: root)
        let model = APIUsageModel(store: store, keys: MemoryKeys(), client: APIUsageClient(transport: ModelTransport()))
        try model.saveOrganization(makeOrganization(), key: "sk-admin-synthetic-fixture-only")
        let record = APICreditBalance(totalCredits: 50, remainingCredits: nil, currency: "USD",
                                     isInitialGrantOnly: true, source: "Synthetic confirmation", verifiedAt: Date(timeIntervalSince1970: 1_900_000_000))
        try model.saveCreditBalance(record)
        try model.setPeriod(APIPeriodSelection(preset: .last30Days))
        await model.refreshAndWait()
        #expect(model.creditBalance == record)
        #expect(model.creditBalance?.remainingCredits == nil)
        #expect(try store.loadConfiguration().creditBalances["org-synthetic"] == record)
        var invalid = record; invalid.remainingCredits = -1
        #expect(throws: APIUsageError.invalidGrant) { try model.saveCreditBalance(invalid) }
        let old = Data(#"{"organizations":[],"grants":[],"remindersEnabled":false}"#.utf8)
        #expect(try JSONDecoder().decode(APIUsageConfiguration.self, from: old).creditBalances.isEmpty)
    }

    @Test func dateOnlyRemindersUseDaytimeWithoutInventingExpiryTime() throws {
        let account = APITrackedAccount(name: "Synthetic", credentialNote: "", creditNote: "",
                                        expiryDate: "2030-05-10", expiryTimeZone: "Asia/Shanghai")
        let now = try #require(APIUsageFormat.parse("2030-05-01T00:00:00+08:00"))
        let reminders = APIDateOnlyReminderPlanner.reminders(accounts: [account], now: now)
        #expect(reminders.map(\.fireAt) == [APIUsageFormat.parse("2030-05-07T09:00:00+08:00")!,
                                           APIUsageFormat.parse("2030-05-09T09:00:00+08:00")!])
        #expect(reminders.map(\.expiryDate) == ["2030-05-10", "2030-05-10"])
        #expect(APIDateOnlyReminderPlanner.parse("2030-02-30", timeZone: "Asia/Shanghai") == nil)
        #expect(APIDateOnlyReminderPlanner.reminders(accounts: [account], now: reminders.last!.fireAt).isEmpty)
    }

    @Test func pendingAccountsPersistWithoutInventingOrganizationsOrCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "api-accounts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = APIUsageStore(directory: root)
        let keys = MemoryKeys()
        let model = APIUsageModel(store: store, keys: keys)
        for name in ["Synthetic A", "Synthetic B", "Synthetic C"] {
            try model.registerAccount(name: name, credentialNote: "Project key only", creditNote: "Expiry unknown")
        }
        try model.registerAccount(name: "Synthetic A", credentialNote: "Updated", creditNote: "Expiry unknown")
        #expect(model.configuration.accounts.count == 3)
        #expect(model.configuration.accounts.allSatisfy { $0.organizationID == nil })
        #expect(keys.values.isEmpty)
        #expect(try store.loadConfiguration().accounts.count == 3)
        let old = Data(#"{"organizations":[],"grants":[],"remindersEnabled":false}"#.utf8)
        #expect(try JSONDecoder().decode(APIUsageConfiguration.self, from: old).accounts.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHER_TEST_KEYCHAIN"] == "1"))
    func keychainRoundTripWithAnIsolatedSyntheticItem() throws {
        let keys = APIKeychain()
        let id = "org-synthetic-keychain-\(UUID().uuidString)"
        defer { try? keys.delete(organizationID: id) }
        #expect(try keys.read(organizationID: id) == nil)
        try keys.save("synthetic-keychain-fixture-only", organizationID: id)
        #expect(try keys.read(organizationID: id) == "synthetic-keychain-fixture-only")
        try keys.save("synthetic-replacement-only", organizationID: id)
        #expect(try keys.read(organizationID: id) == "synthetic-replacement-only")
        try keys.delete(organizationID: id)
        #expect(try keys.read(organizationID: id) == nil)
    }

    @Test func organizationDeduplicationDisconnectAndPrivatePersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "api-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = APIUsageStore(directory: root)
        let keys = MemoryKeys()
        let transport = ModelTransport()
        let model = APIUsageModel(store: store, keys: keys, client: APIUsageClient(transport: transport))
        var organization = makeOrganization()
        try model.saveOrganization(organization, key: "sk-admin-synthetic-fixture-only")
        await model.refreshAndWait()
        organization.name = "Updated synthetic name"
        try model.saveOrganization(organization, key: "")
        await model.refreshAndWait()
        #expect(model.configuration.organizations.count == 1)
        #expect(model.organization?.name == "Updated synthetic name")
        #expect(keys.values.count == 1)
        #expect(model.snapshot?.cycle.value?.totals["USD"] == Decimal(string: "0.3"))
        let configData = try Data(contentsOf: root.appending(path: "configuration.json"))
        let cacheData = try Data(contentsOf: root.appending(path: "cache.json"))
        #expect(!String(decoding: configData + cacheData, as: UTF8.self).contains("sk-admin-"))
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: root.appending(path: "cache.json").path)[.posixPermissions] as? Int == 0o600)
        try model.disconnect()
        #expect(keys.values.isEmpty)
        #expect(model.snapshot == nil)
        #expect(try store.loadSnapshots().isEmpty)
        #expect(model.configuration.organizations.count == 1)
    }

    @Test func deniedCostsPreserveOldRangeWhileUsageRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "api-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemoryKeys(); let transport = ModelTransport()
        let model = APIUsageModel(store: APIUsageStore(directory: root), keys: keys, client: APIUsageClient(transport: transport))
        try model.saveOrganization(makeOrganization(), key: "sk-admin-synthetic-fixture-only")
        await model.refreshAndWait()
        let original = try #require(model.snapshot)
        await transport.setCostStatus(403)
        await model.refreshAndWait()
        let failed = try #require(model.snapshot)
        #expect(failed.cycle.value == original.cycle.value)
        #expect(failed.cycle.range == original.cycle.range)
        #expect(failed.cycle.fetchedAt == original.cycle.fetchedAt)
        #expect(failed.cycle.error == APIUsageError.permissionDenied.localizedDescription)
        #expect(failed.cycle.isStale(now: Date()))
        #expect(failed.usage.error == nil)
        #expect(failed.usage.value?.models.first?.requests == 3)
        keys.values.removeAll()
        await model.refreshAndWait()
        #expect(model.snapshot?.cycle.value == original.cycle.value)
        #expect(model.snapshot?.cycle.error == APIUsageError.missingCredential.localizedDescription)
    }

    @Test func missingCredentialDoesNotRequestOrShowZero() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "api-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ModelTransport()
        let model = APIUsageModel(store: APIUsageStore(directory: root), keys: MemoryKeys(), client: APIUsageClient(transport: transport))
        try model.saveOrganization(makeOrganization(), key: "")
        await model.refreshAndWait()
        #expect(model.snapshot?.today.value == nil)
        #expect(model.snapshot?.today.error == APIUsageError.missingCredential.localizedDescription)
        #expect(await transport.requestCount == 0)
    }

    @Test func grantsPersistExactInstantsAndStayIndependentOfCosts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "api-grants-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = APIUsageStore(directory: root)
        let model = APIUsageModel(store: store, keys: MemoryKeys())
        try model.saveOrganization(makeOrganization(), key: "")
        await model.refreshAndWait()
        let issued = Date(timeIntervalSince1970: 1_900_000_000.123)
        let grant = APICreditGrant(organizationID: "org-synthetic", amount: Decimal(string: "50.01")!, currency: "USD",
                                   issuedAt: issued, expiresAt: issued.addingTimeInterval(17 * 86_400),
                                   source: "synthetic statement", verifiedAt: issued)
        try await model.saveGrant(grant)
        var edited = grant; edited.amount = 60
        try await model.saveGrant(edited)
        #expect(model.grants.count == 1)
        #expect(try store.loadConfiguration().grants == [edited])
        #expect(model.snapshot?.cycle.value == nil)
        await model.deleteGrant(grant.id)
        #expect(try store.loadConfiguration().grants.isEmpty)
    }

    @Test func productionViewHasUsableMinimumSizeWithSyntheticData() {
        let model = APIUsageModel(demo: true)
        let host = NSHostingController(rootView: APIUsageView(model: model))
        let size = host.sizeThatFits(in: NSSize(width: 1180, height: 860))
        #expect(size.width >= 1020)
        #expect(size.height >= 720)
        #expect(APIUsageFormat.date(Date(timeIntervalSince1970: 0)).contains("08:00:00 +08:00"))
        #expect(APIUsageFormat.parse("2030-05-10T23:59:59+08:00") == APIUsageFormat.parse("2030-05-10T15:59:59Z"))
        #expect(APIUsageFormat.amount(Decimal(string: "0.000000000001")!, currency: "usd") == "USD 0.000000000001")
    }

    private func makeOrganization() -> APIOrganization {
        APIOrganization(id: "org-synthetic", name: "Synthetic", cycleStart: Date().addingTimeInterval(-86_400),
                        cycleEnd: Date().addingTimeInterval(5 * 86_400))
    }
}

private final class MemoryKeys: APIKeyStoring {
    var values: [String: String] = [:]
    func read(organizationID: String) throws -> String? { values[organizationID] }
    func save(_ key: String, organizationID: String) throws { values[organizationID] = key }
    func delete(organizationID: String) throws { values.removeValue(forKey: organizationID) }
}

private actor ModelTransport: APIUsageTransport {
    var costStatus = 200
    var requestCount = 0
    func setCostStatus(_ value: Int) { costStatus = value }
    func data(for request: URLRequest) async throws -> (Data, Int) {
        requestCount += 1
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let start = query.first { $0.name == "start_time" }!.value!
        let end = query.first { $0.name == "end_time" }!.value!
        let isCosts = request.url!.path.hasSuffix("/costs")
        let rows = isCosts
            ? "{\"amount\":{\"value\":0.3,\"currency\":\"usd\"}}"
            : "{\"model\":\"synthetic-model\",\"num_model_requests\":3,\"input_tokens\":100,\"output_tokens\":20}"
        let json = "{\"data\":[{\"start_time\":\(start),\"end_time\":\(end),\"results\":[\(rows)]}],\"has_more\":false,\"next_page\":null}"
        return (Data(json.utf8), isCosts ? costStatus : 200)
    }
}
