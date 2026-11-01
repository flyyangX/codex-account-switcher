import Foundation
import Security
import SwitcherCore

struct APITrackedAccount: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var organizationID: String?
    var credentialNote: String
    var creditNote: String
    var expiryDate: String? = nil
    var expiryTimeZone: String? = nil
}

struct APIDateOnlyReminder: Equatable {
    var id: String
    var accountID: UUID
    var fireAt: Date
    var expiryDate: String
    var days: Int
}

enum APIDateOnlyReminderPlanner {
    static func parse(_ date: String, timeZone: String) -> Date? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let value = formatter.date(from: date), formatter.string(from: value) == date else { return nil }
        return value
    }
    static func reminders(accounts: [APITrackedAccount], now: Date) -> [APIDateOnlyReminder] {
        accounts.flatMap { account -> [APIDateOnlyReminder] in
            guard let date = account.expiryDate, let zone = account.expiryTimeZone,
                  let day = parse(date, timeZone: zone), let timeZone = TimeZone(identifier: zone) else { return [] }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            return [3, 1].compactMap { days in
                guard let target = calendar.date(byAdding: .day, value: -days, to: day),
                      let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: target), fire > now else { return nil }
                return APIDateOnlyReminder(id: "api-credit.date-only.\(account.id).\(date).\(days)",
                                            accountID: account.id, fireAt: fire, expiryDate: date, days: days)
            }
        }.sorted { $0.fireAt < $1.fireAt }
    }
}

struct APINotificationStatus: Codable {
    struct Pending: Codable {
        var id: String
        var fireAt: Date?
    }
    var checkedAt: Date
    var authorization: String
    var pendingIDs: [String]
    var error: String?
    var pending: [Pending]? = nil
}

/// A manually verified billing snapshot, never inferred from Costs or a monthly spending limit.
struct APICreditBalance: Codable, Equatable {
    var totalCredits: Decimal?
    var remainingCredits: Decimal?
    var currency: String
    var isInitialGrantOnly: Bool
    var source: String
    var verifiedAt: Date
    var webSynced: Bool? = nil

    func validate() throws {
        guard totalCredits != nil || remainingCredits != nil,
              [totalCredits, remainingCredits].compactMap({ $0 }).allSatisfy({ !$0.isNaN && $0 >= 0 }),
              currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isLetter }),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw APIUsageError.invalidGrant }
    }
}

struct APIWebBillingConnection: Codable, Equatable {
    var profileID = UUID()
    var enabled = false
}

struct APIUsageConfiguration: Codable, Equatable {
    var organizations: [APIOrganization] = []
    var selectedID: String?
    var grants: [APICreditGrant] = []
    var remindersEnabled = false
    var accounts: [APITrackedAccount] = []
    var periods: [String: APIPeriodSelection] = [:]
    var creditBalances: [String: APICreditBalance] = [:]
    var webBilling: [String: APIWebBillingConnection] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey {
        case organizations, selectedID, grants, remindersEnabled, accounts, periods, creditBalances, webBilling
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        organizations = try values.decodeIfPresent([APIOrganization].self, forKey: .organizations) ?? []
        selectedID = try values.decodeIfPresent(String.self, forKey: .selectedID)
        grants = try values.decodeIfPresent([APICreditGrant].self, forKey: .grants) ?? []
        remindersEnabled = try values.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? false
        accounts = try values.decodeIfPresent([APITrackedAccount].self, forKey: .accounts) ?? []
        periods = try values.decodeIfPresent([String: APIPeriodSelection].self, forKey: .periods) ?? [:]
        creditBalances = try values.decodeIfPresent([String: APICreditBalance].self, forKey: .creditBalances) ?? [:]
        webBilling = try values.decodeIfPresent([String: APIWebBillingConnection].self, forKey: .webBilling) ?? [:]
    }
}

/// This document deliberately has no credential field and no relationship to auth.json.
struct APIUsageStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Codex API Monitor/API Usage", directoryHint: .isDirectory)
    }
    func loadConfiguration() throws -> APIUsageConfiguration {
        try read("configuration.json", default: APIUsageConfiguration())
    }
    func saveConfiguration(_ value: APIUsageConfiguration) throws { try write(value, name: "configuration.json") }
    func loadSnapshots() throws -> [APIUsageSnapshot] { try read("cache.json", default: []) }
    func saveSnapshots(_ value: [APIUsageSnapshot]) throws { try write(value, name: "cache.json") }
    func saveNotificationStatus(_ value: APINotificationStatus) throws { try write(value, name: "notification-status.json") }

    private func read<T: Decodable>(_ name: String, default fallback: T) throws -> T {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appending(path: name)
        // Set permissions on the temporary file before an atomic replacement.
        let temp = directory.appending(path: ".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        try encoder.encode(value).write(to: temp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: url) }
    }
}

protocol APIKeyStoring {
    @MainActor func readForRefresh(organizationID: String, allowInteraction: Bool) async throws -> String?
    func read(organizationID: String) throws -> String?
    func save(_ key: String, organizationID: String) throws
    func delete(organizationID: String) throws
}

extension APIKeyStoring {
    @MainActor func readForRefresh(organizationID: String, allowInteraction: Bool) async throws -> String? {
        try read(organizationID: organizationID)
    }
}

struct APIKeychain: APIKeyStoring, Sendable {
    // The legacy login keychain uses a process-wide interaction setting.
    // Serialize our operations so a silent read cannot suppress an explicit save/read.
    private static let accessLock = NSLock()
    @MainActor func readForRefresh(organizationID: String, allowInteraction: Bool) async throws -> String? {
        // Security may wait for the login keychain / system authorization. Keep AppKit responsive.
        try await Task.detached(priority: .userInitiated) {
            try self.readItem(organizationID: organizationID, allowInteraction: allowInteraction)
        }.value
    }

    private let service = "com.flyyang.codex-api-monitor.admin-key"
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }
    func read(organizationID: String) throws -> String? {
        try readItem(organizationID: organizationID, allowInteraction: true)
    }
    private func readItem(organizationID: String, allowInteraction: Bool) throws -> String? {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        var previousInteraction = DarwinBoolean(true)
        if !allowInteraction {
            let status = SecKeychainGetUserInteractionAllowed(&previousInteraction)
            guard status == errSecSuccess else { throw APIKeychainError(status: status) }
            let changed = SecKeychainSetUserInteractionAllowed(false)
            guard changed == errSecSuccess else { throw APIKeychainError(status: changed) }
        }
        defer {
            if !allowInteraction { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }
        }
        var query = query(organizationID)
        query[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { throw APIKeychainError(status: status) }
        return key
    }
    func save(_ key: String, organizationID: String) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(organizationID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(organizationID)
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw APIKeychainError(status: added) }
        } else if status != errSecSuccess { throw APIKeychainError(status: status) }
    }
    func delete(organizationID: String) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let status = SecItemDelete(query(organizationID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeychainError(status: status) }
    }
}

struct APIKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecInteractionNotAllowed || status == errSecInteractionRequired || status == errSecAuthFailed || status == errSecUserCanceled {
            return "密钥需要本机授权；自动刷新已暂停读取，不会弹窗。请主动点击“授权密钥”。"
        }
        return "钥匙串操作失败（\(status)），请检查登录钥匙串。"
    }
}
