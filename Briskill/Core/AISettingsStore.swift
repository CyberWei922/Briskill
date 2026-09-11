import Foundation

@MainActor
final class AISettingsStore: ObservableObject {
    static let shared = AISettingsStore()

    @Published var selectedProvider: AIProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider) }
    }

    @Published private(set) var configurations: [AIProvider: AIProviderConfiguration]
    @Published private(set) var apiKeyStorageMode: APIKeyStorageMode
    @Published private(set) var providerOrder: [AIProvider]
    @Published private(set) var enabledProviders: Set<AIProvider>
    @Published private(set) var modelCatalogs: [AIProvider: [String]]
    @Published var automaticFailover: Bool {
        didSet { defaults.set(automaticFailover, forKey: Keys.automaticFailover) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let selectedProvider = "ai.selectedProvider"
        static let configurations = "ai.providerConfigurations"
        static let apiKeyStorageMode = "ai.apiKeyStorageMode"
        static let providerOrder = "ai.providerOrder"
        static let enabledProviders = "ai.enabledProviders"
        static let modelCatalogs = "ai.modelCatalogs"
        static let automaticFailover = "ai.automaticFailover"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKeyStorageMode = APIKeyStorageMode(
            rawValue: defaults.string(forKey: Keys.apiKeyStorageMode) ?? ""
        ) ?? .keychain
        automaticFailover = true
        defaults.set(true, forKey: Keys.automaticFailover)
        selectedProvider = AIProvider(rawValue: defaults.string(forKey: Keys.selectedProvider) ?? "") ?? .deepSeek

        if let storedValues = defaults.stringArray(forKey: Keys.providerOrder) {
            providerOrder = storedValues.compactMap(AIProvider.init(rawValue:))
        } else {
            providerOrder = AIProvider.allCases
        }

        if let storedEnabled = defaults.stringArray(forKey: Keys.enabledProviders) {
            enabledProviders = Set(storedEnabled.compactMap(AIProvider.init(rawValue:)))
        } else {
            enabledProviders = Set(AIProvider.allCases)
        }

        if let data = defaults.data(forKey: Keys.modelCatalogs),
           let storedCatalogs = try? JSONDecoder().decode([String: [String]].self, from: data) {
            modelCatalogs = Dictionary(uniqueKeysWithValues: storedCatalogs.compactMap { key, value in
                guard let provider = AIProvider(rawValue: key) else { return nil }
                return (provider, value)
            })
        } else {
            modelCatalogs = [:]
        }

        if let data = defaults.data(forKey: Keys.configurations),
           let decoded = try? JSONDecoder().decode([AIProvider: AIProviderConfiguration].self, from: data) {
            configurations = decoded
        } else {
            configurations = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0, .defaults(for: $0)) })
        }

        for provider in AIProvider.allCases where configurations[provider] == nil {
            configurations[provider] = .defaults(for: provider)
        }
        for provider in AIProvider.allCases where modelCatalogs[provider] == nil {
            modelCatalogs[provider] = provider.fallbackModels
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

    var primaryProvider: AIProvider {
        providerOrder.first(where: { isConfigured($0) })
            ?? providerOrder.first
            ?? .deepSeek
    }

    var routingProviders: [AIProvider] {
        providerOrder
    }

    var removedProviders: [AIProvider] {
        AIProvider.allCases.filter { !providerOrder.contains($0) }
    }

    func removeProvider(_ provider: AIProvider) {
        providerOrder.removeAll { $0 == provider }
        enabledProviders.remove(provider)
        if selectedProvider == provider, let next = providerOrder.first {
            selectedProvider = next
        }
        persistRouting()
    }

    func restoreProvider(_ provider: AIProvider) {
        guard !providerOrder.contains(provider) else { return }
        providerOrder.append(provider)
        enabledProviders.insert(provider)
        persistRouting()
    }

    func setProviderEnabled(_ provider: AIProvider, enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
        }
        persistRouting()
    }

    func moveProvider(_ provider: AIProvider, before destination: AIProvider) {
        guard provider != destination,
              let sourceIndex = providerOrder.firstIndex(of: provider),
              let destinationIndex = providerOrder.firstIndex(of: destination) else { return }
        var updated = providerOrder
        let item = updated.remove(at: sourceIndex)
        let insertionIndex = destinationIndex
        updated.insert(item, at: max(0, min(insertionIndex, updated.count)))
        providerOrder = updated
        persistRouting()
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        var updated = providerOrder
        updated.move(fromOffsets: source, toOffset: destination)
        providerOrder = updated
        persistRouting()
    }

    func availableModels(for provider: AIProvider) -> [String] {
        let cached = modelCatalogs[provider] ?? []
        return cached.isEmpty ? provider.fallbackModels : cached
    }

    func updateAvailableModels(_ models: [String], for provider: AIProvider) {
        let cleaned = Array(Set(models.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !cleaned.isEmpty else { return }
        modelCatalogs[provider] = cleaned

        var configuration = configuration(for: provider)
        if configuration.model.isEmpty || !cleaned.contains(configuration.model) {
            configuration.model = preferredModel(from: cleaned, for: provider)
            configurations[provider] = configuration
            persistConfigurations()
        }
        persistModelCatalogs()
    }

    private func preferredModel(from models: [String], for provider: AIProvider) -> String {
        if let preferred = provider.fallbackModels.first(where: models.contains) {
            return preferred
        }
        let stable = models.filter {
            !$0.localizedCaseInsensitiveContains("preview")
                && !$0.localizedCaseInsensitiveContains("experimental")
                && !$0.localizedCaseInsensitiveContains("embedding")
                && !$0.localizedCaseInsensitiveContains("image")
                && !$0.localizedCaseInsensitiveContains("audio")
        }
        return stable.first ?? models[0]
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

    private func persistRouting() {
        defaults.set(providerOrder.map(\.rawValue), forKey: Keys.providerOrder)
        defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: Keys.enabledProviders)
    }

    private func persistModelCatalogs() {
        let values = Dictionary(uniqueKeysWithValues: modelCatalogs.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Keys.modelCatalogs)
        }
    }
}
