import Foundation
import Security
import SwitcherCore

struct APIUsageConfiguration: Codable, Equatable {
    var organizations: [APIOrganization] = []
    var selectedID: String?
    var grants: [APICreditGrant] = []
    var remindersEnabled = false
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
    func read(organizationID: String) throws -> String?
    func save(_ key: String, organizationID: String) throws
    func delete(organizationID: String) throws
}

struct APIKeychain: APIKeyStoring {
    private let service = "com.flyyang.codex-api-monitor.admin-key"
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }
    func read(organizationID: String) throws -> String? {
        var query = query(organizationID)
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
        let status = SecItemDelete(query(organizationID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeychainError(status: status) }
    }
}

private struct APIKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "钥匙串操作失败（\(status)），请解锁登录钥匙串后重试。" }
}
