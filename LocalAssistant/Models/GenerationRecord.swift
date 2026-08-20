import Foundation

enum GenerationRecordStatus: String, Codable {
    case completed
    case cancelled
    case failed

    var displayName: String {
        switch self {
        case .completed: "已完成"
        case .cancelled: "已终止"
        case .failed: "失败"
        }
    }
}

struct GenerationTokenUsage: Codable, Hashable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
}

struct GenerationRecord: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let status: GenerationRecordStatus
    let requestDescription: String
    let mode: SkillCreationMode
    let executionMode: SkillExecutionMode?
    let provider: String
    let model: String
    let reasoning: String
    let rawOutput: String
    let draft: SkillDraft?
    let usage: GenerationTokenUsage?
    let estimatedTokens: Int
    let errorMessage: String?

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}
