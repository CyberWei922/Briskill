import Foundation

enum APIKeyStorageMode: String, CaseIterable, Identifiable {
    case keychain
    case localFile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keychain: String(localized: "macOS 钥匙串")
        case .localFile: String(localized: "本地可查看文件")
        }
    }

    var detail: String {
        switch self {
        case .keychain:
            String(localized: "由 macOS 钥匙串保护，默认选项；应用可以使用，但界面不提供明文显示。")
        case .localFile:
            String(localized: "以仅当前用户可读的本地 JSON 保存，可在应用中再次显示；安全性低于钥匙串。")
        }
    }
}

enum LocalAPIKeyStore {
    private static let fileManager = FileManager.default

    static func value(for provider: AIProvider) -> String? {
        (try? load())?[provider.rawValue]
    }

    static func allValues() -> [AIProvider: String] {
        let values = (try? load()) ?? [:]
        return Dictionary(uniqueKeysWithValues: AIProvider.allCases.compactMap { provider in
            guard let value = values[provider.rawValue], !value.isEmpty else { return nil }
            return (provider, value)
        })
    }

    static func save(_ value: String, for provider: AIProvider) throws {
        var values = try load()
        values[provider.rawValue] = value
        try persist(values)
    }

    static func delete(for provider: AIProvider) throws {
        var values = try load()
        values.removeValue(forKey: provider.rawValue)
        try persist(values)
    }

    static func replace(with values: [AIProvider: String]) throws {
        try persist(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }

    static func deleteFile() throws {
        let url = try storageURL(createDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    static func storageURL(createDirectory: Bool = false) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = baseURL.appendingPathComponent("Briskill/Secrets", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory.appendingPathComponent("api-keys.json")
    }

    private static func load() throws -> [String: String] {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private static func persist(_ values: [String: String]) throws {
        let url = try storageURL(createDirectory: true)
        if values.isEmpty {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
