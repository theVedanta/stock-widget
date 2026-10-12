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

    static func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name)
    }
}

enum CredentialKey: String, CaseIterable, Sendable {
    /// Groww "TOTP token" (used as the bearer key for the token exchange).
    case growwAPIKey
    /// Base32 secret shown next to the TOTP token; codes are generated on device.
    case growwTOTPSecret
    /// Alternative to TOTP: API secret for the approval flow (key must be approved daily on groww.in).
    case growwAPISecret
    /// Cached daily access token ("token\nexpiryEpoch"). Written by the app/widget, not the user.
    case growwAccessToken
    /// IBKR Flex Web Service token (Client Portal → Settings → Flex Web Service).
    case ibkrFlexToken
    /// ID of an Activity Flex Query with Open Positions + Cash Report.
    case ibkrFlexQueryID
}

/// Broker credentials in a Keychain access group shared by the app and the widget.
/// `AfterFirstUnlockThisDeviceOnly` lets the widget refresh while the phone is locked,
/// and keeps the keys out of backups and off other devices.
struct Keychain: Sendable {
    static let shared = Keychain()

    private let service = "com.example.stockwidget.credentials"

    /// `$(AppIdentifierPrefix)` is injected into Info.plist at build time (see project.yml).
    private var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, !prefix.hasPrefix("$(") else { return nil }
        return prefix + AppGroup.keychainGroupSuffix
    }

    private func query(_ key: CredentialKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func string(_ key: CredentialKey) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Stores `value`, or deletes the item when `value` is nil or blank.
    func set(_ value: String?, for key: CredentialKey) throws {
        SecItemDelete(query(key) as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PortfolioError.keychain(status) }
    }
}
