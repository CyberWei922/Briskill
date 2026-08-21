import Foundation

@MainActor
final class AISettingsStore: ObservableObject {
    static let shared = AISettingsStore()

    @Published var selectedProvider: AIProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider) }
    }

    @Published private(set) var configurations: [AIProvider: AIProviderConfiguration]
    @Published private(set) var apiKeyStorageMode: APIKeyStorageMode

    private let defaults: UserDefaults

    private enum Keys {
        static let selectedProvider = "ai.selectedProvider"
        static let configurations = "ai.providerConfigurations"
        static let apiKeyStorageMode = "ai.apiKeyStorageMode"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKeyStorageMode = APIKeyStorageMode(
            rawValue: defaults.string(forKey: Keys.apiKeyStorageMode) ?? ""
        ) ?? .keychain
        selectedProvider = AIProvider(rawValue: defaults.string(forKey: Keys.selectedProvider) ?? "") ?? .deepSeek

        if let data = defaults.data(forKey: Keys.configurations),
           let decoded = try? JSONDecoder().decode([AIProvider: AIProviderConfiguration].self, from: data) {
            configurations = decoded
        } else {
            configurations = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0, .defaults(for: $0)) })
        }

        for provider in AIProvider.allCases where configurations[provider] == nil {
            configurations[provider] = .defaults(for: provider)
        }
    }

    func configuration(for provider: AIProvider) -> AIProviderConfiguration {
        configurations[provider] ?? .defaults(for: provider)
    }

    func update(_ configuration: AIProviderConfiguration, for provider: AIProvider) {
        configurations[provider] = configuration
        persistConfigurations()
        AppConsole.shared.info("更新 \(provider.displayName) 配置；模型=\(configuration.model)，地址=\(configuration.endpoint)", category: "Settings")
    }

    func apiKey(for provider: AIProvider) -> String {
        switch apiKeyStorageMode {
        case .keychain:
            KeychainStore.value(account: provider.rawValue) ?? ""
        case .localFile:
            LocalAPIKeyStore.value(for: provider) ?? ""
        }
    }

    func saveAPIKey(_ key: String, for provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch apiKeyStorageMode {
        case .keychain:
            if trimmed.isEmpty {
                try KeychainStore.delete(account: provider.rawValue)
            } else {
                try KeychainStore.save(trimmed, account: provider.rawValue)
            }
        case .localFile:
            if trimmed.isEmpty {
                try LocalAPIKeyStore.delete(for: provider)
            } else {
                try LocalAPIKeyStore.save(trimmed, for: provider)
            }
        }
        let destination = apiKeyStorageMode == .keychain ? "macOS 钥匙串" : "本地可查看文件"
        AppConsole.shared.info(
            trimmed.isEmpty ? "已删除 \(provider.displayName) API Key" : "已保存 \(provider.displayName) API Key 到\(destination)",
            category: "APIKey"
        )
        objectWillChange.send()
    }

    func changeAPIKeyStorageMode(to newMode: APIKeyStorageMode) throws {
        guard newMode != apiKeyStorageMode else { return }

        let currentValues: [AIProvider: String]
        switch apiKeyStorageMode {
        case .keychain:
            currentValues = Dictionary(uniqueKeysWithValues: AIProvider.allCases.compactMap { provider in
                guard let value = KeychainStore.value(account: provider.rawValue), !value.isEmpty else { return nil }
                return (provider, value)
            })
        case .localFile:
            currentValues = LocalAPIKeyStore.allValues()
        }

        switch newMode {
        case .localFile:
            try LocalAPIKeyStore.replace(with: currentValues)
            apiKeyStorageMode = .localFile
            defaults.set(newMode.rawValue, forKey: Keys.apiKeyStorageMode)
            for provider in currentValues.keys {
                do {
                    try KeychainStore.delete(account: provider.rawValue)
                } catch {
                    AppConsole.shared.warning(
                        "本地副本已保存，但未能删除 \(provider.displayName) 的旧钥匙串副本：\(error.localizedDescription)",
                        category: "APIKey"
                    )
                }
            }
        case .keychain:
            for (provider, value) in currentValues {
                try KeychainStore.save(value, account: provider.rawValue)
            }
            apiKeyStorageMode = .keychain
            defaults.set(newMode.rawValue, forKey: Keys.apiKeyStorageMode)
            do {
                try LocalAPIKeyStore.deleteFile()
            } catch {
                AppConsole.shared.warning(
                    "钥匙串迁移已完成，但未能删除旧本地密钥文件：\(error.localizedDescription)",
                    category: "APIKey"
                )
            }
        }

        AppConsole.shared.success("API Key 已迁移到\(newMode.displayName)", category: "APIKey")
        objectWillChange.send()
    }

    var localAPIKeyFileURL: URL? {
        try? LocalAPIKeyStore.storageURL()
    }

    func isConfigured(_ provider: AIProvider? = nil) -> Bool {
        let provider = provider ?? selectedProvider
        let config = configuration(for: provider)
        return !apiKey(for: provider).isEmpty
            && !config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func persistConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            defaults.set(data, forKey: Keys.configurations)
        }
    }
}
