import Foundation

@MainActor
final class InvocationHistoryStore: ObservableObject {
    static let shared = InvocationHistoryStore()

    @Published private(set) var records: [InvocationRecord] = []

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumRecordCount = 500

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func add(_ record: InvocationRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        if records.count > maximumRecordCount {
            records.removeLast(records.count - maximumRecordCount)
        }
        persist()
        AppConsole.shared.info(
            "调用历史已保存：\(record.title)，状态=\(record.status.displayName)，耗时=\(String(format: "%.1f", record.duration))秒",
            category: "History"
        )
    }

    func delete(_ record: InvocationRecord) {
        records.removeAll { $0.id == record.id }
        persist()
        AppConsole.shared.warning("调用历史已删除：\(record.title)", category: "History")
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let previousCount = records.count
        records.removeAll { ids.contains($0.id) }
        let deletedCount = previousCount - records.count
        persist()
        AppConsole.shared.warning("批量删除了 \(deletedCount) 条调用历史", category: "History")
    }

    func clear() {
        records.removeAll()
        persist()
        AppConsole.shared.warning("用户清空了全部调用历史", category: "History")
    }

    private func load() {
        guard let url = try? storageURL(createDirectory: false),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([InvocationRecord].self, from: data) else {
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
            AppConsole.shared.error("调用历史保存失败：\(error.localizedDescription)", category: "History")
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
        return directory.appendingPathComponent("invocations.json")
    }
}
