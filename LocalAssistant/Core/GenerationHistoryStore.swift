import Foundation

@MainActor
final class GenerationHistoryStore: ObservableObject {
    static let shared = GenerationHistoryStore()

    @Published private(set) var records: [GenerationRecord] = []

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumRecordCount = 100

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func add(_ record: GenerationRecord) {
        records.insert(record, at: 0)
        if records.count > maximumRecordCount {
            records.removeLast(records.count - maximumRecordCount)
        }
        persist()
        AppConsole.shared.info("生成历史已保存：\(record.status.displayName)，耗时 \(String(format: "%.1f", record.duration)) 秒", category: "History")
    }

    func clear() {
        records.removeAll()
        persist()
        AppConsole.shared.warning("用户清空了技能生成历史", category: "History")
    }

    private func load() {
        guard let url = try? storageURL(createDirectory: false),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([GenerationRecord].self, from: data) else {
            return
        }
        records = Array(decoded.prefix(maximumRecordCount))
    }

    private func persist() {
        do {
            let url = try storageURL(createDirectory: true)
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            AppConsole.shared.error("生成历史保存失败：\(error.localizedDescription)", category: "History")
        }
    }

    private func storageURL(createDirectory: Bool) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = baseURL.appendingPathComponent("LocalAssistant/History", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("skill-generation.json")
    }
}
