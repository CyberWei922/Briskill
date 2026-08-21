import Foundation

enum InvocationRecordStatus: String, Codable {
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

struct InvocationRecord: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let status: InvocationRecordStatus
    let input: String
    let title: String
    let source: String
    let result: String
    let tools: [String]
    let didWriteClipboard: Bool

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}
