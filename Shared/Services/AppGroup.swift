import Foundation
import Security

/// Shared container between the app and the widget extension.
/// Change these identifiers to match your team's App Group / Keychain group.
enum AppGroup {
    static let identifier = "group.com.example.stockwidget"
    static let keychainGroupSuffix = "com.example.stockwidget.shared"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }
}

/// Non-secret backend settings, written by the host app.
enum BackendConfiguration {
    private static let endpointKey = "backendEndpoint"

    /// `nil` until configured; the widget shows sample data in that case.
    static var endpoint: URL? {
        guard let raw = AppGroup.defaults?.string(forKey: endpointKey),
              let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    static func setEndpoint(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppGroup.defaults?.removeObject(forKey: endpointKey)
            return
        }
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else {
            throw PortfolioError.invalidEndpoint
        }
        AppGroup.defaults?.set(url.absoluteString, forKey: endpointKey)
    }
}

/// Bearer token for the aggregation backend, stored in a Keychain access group
/// shared with the widget. `AfterFirstUnlockThisDeviceOnly` lets the widget refresh
/// while the phone is locked without the token ever leaving the device in backups.
struct CredentialStore: Sendable {
    static let shared = CredentialStore()

    private let service = "com.example.stockwidget.backend"
    private let account = "api-token"

    /// `$(AppIdentifierPrefix)` is injected into Info.plist at build time (see project.yml).
    private var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, !prefix.hasPrefix("$(") else { return nil }
        return prefix + AppGroup.keychainGroupSuffix
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PortfolioError.keychain(status) }
    }

    func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
