import Foundation

enum InvocationRecordStatus: String, Codable {
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .completed: String(localized: "已完成")
        case .failed: String(localized: "失败")
        case .cancelled: String(localized: "已取消")
        }
    }
}

enum ConversationMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ConversationMessage: Codable, Identifiable, Sendable {
    let id: UUID
    let role: ConversationMessageRole
    let content: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ConversationMessageRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
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
    let tokenUsage: GenerationTokenUsage?
    let conversationMessages: [ConversationMessage]?
    let conversationSummary: String?
    let summarizedMessageCount: Int?

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        status: InvocationRecordStatus,
        input: String,
        title: String,
        source: String,
        result: String,
        tools: [String],
        didWriteClipboard: Bool,
        tokenUsage: GenerationTokenUsage? = nil,
        conversationMessages: [ConversationMessage]? = nil,
        conversationSummary: String? = nil,
        summarizedMessageCount: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.input = input
        self.title = title
        self.source = source
        self.result = result
        self.tools = tools
        self.didWriteClipboard = didWriteClipboard
        self.tokenUsage = tokenUsage
        self.conversationMessages = conversationMessages
        self.conversationSummary = conversationSummary
        self.summarizedMessageCount = summarizedMessageCount
    }

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    var isConversation: Bool {
        conversationMessages?.isEmpty == false
    }

    var conversationTurnCount: Int {
        conversationMessages?.filter { $0.role == .user }.count ?? 0
    }
}
