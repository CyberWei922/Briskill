import Foundation

@MainActor
final class AISettingsStore: ObservableObject {
    static let shared = AISettingsStore()

    @Published var selectedProvider: AIProvider {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider) }
    }

    @Published private(set) var configurations: [AIProvider: AIProviderConfiguration]

    private let defaults: UserDefaults

    private enum Keys {
        static let selectedProvider = "ai.selectedProvider"
        static let configurations = "ai.providerConfigurations"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
    }

    func apiKey(for provider: AIProvider) -> String {
        KeychainStore.value(account: provider.rawValue) ?? ""
    }

    func saveAPIKey(_ key: String, for provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try KeychainStore.delete(account: provider.rawValue)
        } else {
            try KeychainStore.save(trimmed, account: provider.rawValue)
        }
        objectWillChange.send()
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
