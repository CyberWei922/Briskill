import Foundation

enum SkillCreationMode: String, Codable, CaseIterable, Identifiable {
    case guided
    case freeform

    var id: String { rawValue }
}

enum SkillOrigin: String, Codable {
    case user
    case builtIn
}

enum SkillExecutionMode: String, Codable, CaseIterable, Identifiable {
    case localOnly
    case cloudAssisted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localOnly: "本地执行"
        case .cloudAssisted: "云端 AI"
        }
    }

    var compactDescription: String {
        switch self {
        case .localOnly: "不调用云端模型；可使用经授权的本地与网络工具"
        case .cloudAssisted: "可组合本地工具，并通过统一模型接口生成内容"
        }
    }
}

enum SkillParameterType: String, Codable, CaseIterable, Identifiable {
    case text
    case file
    case image
    case folder
    case number
    case boolean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: "文本"
        case .file: "文件"
        case .image: "图片"
        case .folder: "文件夹"
        case .number: "数字"
        case .boolean: "是 / 否"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.cursor"
        case .file: "doc"
        case .image: "photo"
        case .folder: "folder"
        case .number: "number"
        case .boolean: "switch.2"
        }
    }

    var acceptsFiles: Bool {
        self == .file || self == .image || self == .folder
    }
}

struct SkillParameterDefinition: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var type: SkillParameterType
    var required: Bool
    var description: String

    static func blank(index: Int) -> SkillParameterDefinition {
        SkillParameterDefinition(
            id: UUID().uuidString,
            name: "参数\(index)",
            type: .text,
            required: true,
            description: ""
        )
    }
}

enum SkillJSONValue: Codable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([SkillJSONValue])
    case object([String: SkillJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SkillJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SkillJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                SkillJSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "参数值必须是有效的 JSON 字符串、数字、布尔值、数组、对象或 null"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var displayText: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .boolean(let value): value ? "true" : "false"
        case .array(let values):
            "[\(values.map(\.jsonFragment).joined(separator: ", "))]"
        case .object(let values):
            "{\(values.keys.sorted().map { key in "\"\(key)\": \(values[key]?.jsonFragment ?? "null")" }.joined(separator: ", "))}"
        case .null: "null"
        }
    }

    private var jsonFragment: String {
        switch self {
        case .string(let value): "\"\(value)\""
        default: displayText
        }
    }
}

struct SkillWorkflowStep: Codable, Equatable {
    var id: String
    var tool: String
    var arguments: [String: SkillJSONValue]
    var saveAs: String?
}

struct SkillModelTask: Codable, Equatable {
    var tool: String
    var promptTemplate: String
    var inputVariables: [String]
    var providerPolicy: String
}

struct SkillCreationRequest {
    var executionMode: SkillExecutionMode
    var mode: SkillCreationMode
    var skillName: String
    var keyword: String
    var parameters: [SkillParameterDefinition]
    var processText: String
    var outputText: String
    var freeformText: String

    var naturalLanguageDescription: String {
        switch mode {
        case .guided:
            return [
                skillName.isEmpty ? nil : "功能名称：\(skillName)",
                keyword.isEmpty ? nil : "注册关键词：\(keyword)",
                "传入参数：\(parameterDescription)",
                processText.isEmpty ? nil : "处理过程：\(processText)",
                outputText.isEmpty ? nil : "结果：\(outputText)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case .freeform:
            return [
                "注册关键词：\(keyword)",
                "传入参数：\(parameterDescription)",
                "用户完整提示词：\(freeformText.trimmingCharacters(in: .whitespacesAndNewlines))"
            ].joined(separator: "\n")
        }
    }

    private var parameterDescription: String {
        guard !parameters.isEmpty else { return "无" }
        return parameters.map { parameter in
            let requirement = parameter.required ? "必填" : "可选"
            let note = parameter.description.isEmpty ? "" : "，\(parameter.description)"
            return "\(parameter.name)（\(parameter.type.displayName)，\(requirement)\(note)）"
        }.joined(separator: "；")
    }

    var generationPrompt: String {
        """
        <skill_request>
        execution_mode: \(executionMode.rawValue)
        editor_mode: \(mode.rawValue)
        user_requirement:
        \(naturalLanguageDescription)
        </skill_request>
        """
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
    var executionMode: SkillExecutionMode?
    var workflow: [SkillWorkflowStep]?
    var modelTask: SkillModelTask?
    var networkHosts: [String]?
    var dataDisclosure: [String]?
    var parameters: [SkillParameterDefinition]?

    var resolvedExecutionMode: SkillExecutionMode {
        executionMode ?? .cloudAssisted
    }

    var resolvedParameters: [SkillParameterDefinition] {
        parameters ?? []
    }

    static func localDraft(from request: SkillCreationRequest) -> SkillDraft {
        let action = request.mode == .guided ? request.processText : request.freeformText
        let conciseAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedName = request.skillName.nilIfEmpty ?? (conciseAction.isEmpty ? "我的新技能" : String(conciseAction.prefix(12)))

        return SkillDraft(
            name: generatedName,
            aliases: [],
            summary: request.naturalLanguageDescription,
            trigger: request.keyword.isEmpty ? "从快捷面板手动运行" : "输入 \(request.keyword)",
            condition: nil,
            actions: conciseAction.isEmpty ? ["等待补充要执行的动作"] : [conciseAction],
            fallback: nil,
            output: request.outputText.isEmpty ? "在助手面板中显示结果" : request.outputText,
            explanation: "这是由本地模板生成的草稿。配置 AI 服务后，可以获得更准确的步骤、别名和能力分析。",
            requiredTools: [],
            permissions: [],
            executionMode: request.executionMode,
            workflow: [],
            modelTask: request.executionMode == .cloudAssisted
                ? SkillModelTask(
                    tool: "model.generateText",
                    promptTemplate: request.naturalLanguageDescription + "\n\n用户本次输入：{{userInput}}",
                    inputVariables: ["userInput"],
                    providerPolicy: "userDefault"
                )
                : nil,
            networkHosts: [],
            dataDisclosure: [],
            parameters: request.parameters
        )
    }
}

struct UserSkill: Codable, Identifiable {
    var id: UUID
    var name: String
    var aliases: [String]
    var registeredKeyword: String?
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
    var executionMode: SkillExecutionMode?
    var workflow: [SkillWorkflowStep]?
    var modelTask: SkillModelTask?
    var networkHosts: [String]?
    var dataDisclosure: [String]?
    var parameters: [SkillParameterDefinition]?
    var generatedBy: String
    var createdAt: Date
    var updatedAt: Date
    var isEnabled: Bool
    var origin: SkillOrigin?
    var builtInIdentifier: String?

    init(draft: SkillDraft, request: SkillCreationRequest, generatedBy: String) {
        id = UUID()
        name = draft.name
        let registeredKeyword = request.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        aliases = Array(Set(draft.aliases + (registeredKeyword.isEmpty ? [] : [registeredKeyword])))
        self.registeredKeyword = registeredKeyword.nilIfEmpty
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
        executionMode = draft.executionMode ?? request.executionMode
        workflow = draft.workflow
        modelTask = draft.modelTask
        networkHosts = draft.networkHosts
        dataDisclosure = draft.dataDisclosure
        parameters = draft.parameters ?? request.parameters
        self.generatedBy = generatedBy
        createdAt = Date()
        updatedAt = Date()
        isEnabled = true
        origin = .user
        builtInIdentifier = nil
    }

    init(
        builtInIdentifier: String,
        id: UUID,
        name: String,
        keyword: String,
        aliases: [String],
        summary: String,
        actions: [String],
        output: String,
        requiredTools: [String],
        permissions: [String],
        executionMode: SkillExecutionMode,
        parameters: [SkillParameterDefinition] = [],
        workflow: [SkillWorkflowStep],
        modelTask: SkillModelTask? = nil,
        dataDisclosure: [String] = []
    ) {
        self.id = id
        self.name = name
        self.aliases = Array(Set([keyword] + aliases))
        registeredKeyword = keyword
        self.summary = summary
        originalRequest = summary
        creationMode = .guided
        trigger = "输入 \(keyword)" + (parameters.isEmpty ? "" : "，并提供所需参数")
        condition = nil
        self.actions = actions
        fallback = "执行失败时显示具体错误，不进行未授权的替代操作"
        self.output = output
        explanation = summary + " 这是随软件提供的可编辑默认技能；它与用户技能使用相同格式，可以关闭、修改、导出或删除。"
        self.requiredTools = requiredTools
        self.permissions = permissions
        self.executionMode = executionMode
        self.workflow = workflow
        self.modelTask = modelTask
        networkHosts = []
        self.dataDisclosure = dataDisclosure
        self.parameters = parameters
        generatedBy = "Local Assistant"
        createdAt = Date(timeIntervalSince1970: 1_787_225_600)
        updatedAt = createdAt
        isEnabled = true
        origin = .builtIn
        self.builtInIdentifier = builtInIdentifier
    }

    var searchTerms: [String] {
        [name, summary, originalRequest] + aliases
    }

    var resolvedExecutionMode: SkillExecutionMode {
        executionMode ?? .cloudAssisted
    }

    var resolvedParameters: [SkillParameterDefinition] {
        parameters ?? []
    }

    var isBuiltIn: Bool {
        origin == .builtIn || builtInIdentifier != nil
    }

    var executionExample: String {
        let command = registeredKeyword?.nilIfEmpty
            ?? aliases.first(where: { alias in
                !alias.contains(where: \.isWhitespace) && alias.unicodeScalars.allSatisfy(\.isASCII)
            })?.nilIfEmpty
            ?? aliases.first?.nilIfEmpty
            ?? name
        let arguments = resolvedParameters.map { parameter in
            let value = parameter.name.nilIfEmpty ?? parameter.type.displayName
            return parameter.required ? value : "[\(value)]"
        }
        return ([command] + arguments).joined(separator: " ")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
