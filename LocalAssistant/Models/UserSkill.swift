import Foundation

enum SkillCreationMode: String, Codable, CaseIterable, Identifiable {
    case guided
    case freeform

    var id: String { rawValue }
}

struct SkillCreationRequest {
    var mode: SkillCreationMode
    var whenText: String
    var conditionText: String
    var actionText: String
    var otherwiseText: String
    var outputText: String
    var freeformText: String

    var naturalLanguageDescription: String {
        switch mode {
        case .guided:
            return [
                whenText.isEmpty ? nil : "当：\(whenText)",
                conditionText.isEmpty ? nil : "如果：\(conditionText)",
                actionText.isEmpty ? nil : "执行：\(actionText)",
                otherwiseText.isEmpty ? nil : "否则：\(otherwiseText)",
                outputText.isEmpty ? nil : "结果：\(outputText)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case .freeform:
            return freeformText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct SkillDraft: Codable, Equatable {
    var name: String
    var aliases: [String]
    var summary: String
    var trigger: String
    var condition: String?
    var actions: [String]
    var fallback: String?
    var output: String
    var explanation: String
    var requiredTools: [String]
    var permissions: [String]

    static func localDraft(from request: SkillCreationRequest) -> SkillDraft {
        let action = request.mode == .guided ? request.actionText : request.freeformText
        let conciseAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedName = conciseAction.isEmpty ? "我的新技能" : String(conciseAction.prefix(12))

        return SkillDraft(
            name: generatedName,
            aliases: [],
            summary: request.naturalLanguageDescription,
            trigger: request.whenText.isEmpty ? "从快捷面板手动运行" : request.whenText,
            condition: request.conditionText.nilIfEmpty,
            actions: conciseAction.isEmpty ? ["等待补充要执行的动作"] : [conciseAction],
            fallback: request.otherwiseText.nilIfEmpty,
            output: request.outputText.isEmpty ? "在助手面板中显示结果" : request.outputText,
            explanation: "这是由本地模板生成的草稿。配置 AI 服务后，可以获得更准确的步骤、别名和能力分析。",
            requiredTools: [],
            permissions: []
        )
    }
}

struct UserSkill: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var aliases: [String]
    var summary: String
    var originalRequest: String
    var creationMode: SkillCreationMode
    var trigger: String
    var condition: String?
    var actions: [String]
    var fallback: String?
    var output: String
    var explanation: String
    var requiredTools: [String]
    var permissions: [String]
    var generatedBy: String
    var createdAt: Date
    var updatedAt: Date
    var isEnabled: Bool

    init(draft: SkillDraft, request: SkillCreationRequest, generatedBy: String) {
        id = UUID()
        name = draft.name
        aliases = draft.aliases
        summary = draft.summary
        originalRequest = request.naturalLanguageDescription
        creationMode = request.mode
        trigger = draft.trigger
        condition = draft.condition
        actions = draft.actions
        fallback = draft.fallback
        output = draft.output
        explanation = draft.explanation
        requiredTools = draft.requiredTools
        permissions = draft.permissions
        self.generatedBy = generatedBy
        createdAt = Date()
        updatedAt = Date()
        isEnabled = true
    }

    var searchTerms: [String] {
        [name, summary, originalRequest] + aliases
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
