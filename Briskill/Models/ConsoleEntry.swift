import Foundation

enum ConsoleLevel: String, Codable, CaseIterable, Identifiable {
    case info
    case success
    case warning
    case error

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .info: String(localized: "信息")
        case .success: String(localized: "成功")
        case .warning: String(localized: "警告")
        case .error: String(localized: "错误")
        }
    }
}

struct ConsoleEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let level: ConsoleLevel
    let category: String
    let message: String

    init(level: ConsoleLevel, category: String, message: String) {
        id = UUID()
        timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
    }
}
