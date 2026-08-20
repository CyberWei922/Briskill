import AppKit
import Foundation
import OSLog

@MainActor
final class AppConsole: ObservableObject {
    static let shared = AppConsole()

    @Published private(set) var entries: [ConsoleEntry] = []

    private let fileManager = FileManager.default
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LocalAssistant",
        category: "Application"
    )
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumEntryCount = 2_000

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func info(_ message: String, category: String) {
        append(level: .info, message: message, category: category)
    }

    func success(_ message: String, category: String) {
        append(level: .success, message: message, category: category)
    }

    func warning(_ message: String, category: String) {
        append(level: .warning, message: message, category: category)
    }

    func error(_ message: String, category: String) {
        append(level: .error, message: message, category: category)
    }

    func clear() {
        entries.removeAll()
        persist()
        logger.notice("Console history cleared")
    }

    func copyAll() {
        let formatter = ISO8601DateFormatter()
        let text = entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
        }
        .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func append(level: ConsoleLevel, message: String, category: String) {
        let sanitized = message.replacingOccurrences(
            of: #"(?i)(bearer\s+|api[_ -]?key\s*[:=]\s*)[A-Za-z0-9._-]+"#,
            with: "$1<redacted>",
            options: .regularExpression
        )
        entries.append(ConsoleEntry(level: level, category: category, message: sanitized))
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        persist()

        switch level {
        case .info: logger.info("[\(category, privacy: .public)] \(sanitized, privacy: .public)")
        case .success: logger.notice("[\(category, privacy: .public)] \(sanitized, privacy: .public)")
        case .warning: logger.warning("[\(category, privacy: .public)] \(sanitized, privacy: .public)")
        case .error: logger.error("[\(category, privacy: .public)] \(sanitized, privacy: .public)")
        }
    }

    private func load() {
        guard let url = try? storageURL(createDirectory: false),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([ConsoleEntry].self, from: data) else {
            return
        }
        entries = Array(decoded.suffix(maximumEntryCount))
    }

    private func persist() {
        do {
            let url = try storageURL(createDirectory: true)
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not persist console: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func storageURL(createDirectory: Bool) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = baseURL.appendingPathComponent("LocalAssistant/Logs", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("console.json")
    }
}
