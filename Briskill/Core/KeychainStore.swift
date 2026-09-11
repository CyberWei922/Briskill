import AppKit
import Foundation
import Security

enum KeychainStore {
    private static let service = "com.cyberwei.briskill.api-keys"

    static func save(_ value: String, account: String) throws {
        try save(value, account: account, service: service)
    }

    private static func save(_ value: String, account: String, service: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: itemLabel(for: account)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            item[kSecAttrLabel as String] = itemLabel(for: account)
            item[kSecAttrDescription as String] = "Briskill API Key"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.status(updateStatus)
        }
    }

    static func value(account: String) -> String? {
        value(account: account, service: service)
    }

    private static func value(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) throws {
        try delete(account: account, service: service)
    }

    @MainActor
    static func openKeychainAccess() -> Bool {
        let workspace = NSWorkspace.shared
        if let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: "com.apple.keychainaccess"
        ) {
            workspace.openApplication(
                at: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        }
        let fallbackURL = URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app")
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return false }
        workspace.openApplication(
            at: fallbackURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return true
    }

    static func searchableLabel(account: String) -> String {
        itemLabel(for: account)
    }

    private static func itemLabel(for account: String) -> String {
        let providerName: String
        switch account {
        case AIProvider.deepSeek.rawValue: providerName = "DeepSeek"
        case AIProvider.glm.rawValue: providerName = "GLM"
        case AIProvider.gemini.rawValue: providerName = "Gemini"
        case AIProvider.openAI.rawValue: providerName = "OpenAI"
        default: providerName = account
        }
        return "Briskill · \(providerName) API Key"
    }

    private static func delete(account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串操作失败（\(status)）"
        }
    }
}
