import Foundation

enum SkillStoreError: LocalizedError {
    case missingRegisteredKeyword
    case invalidRegisteredKeyword
    case duplicateRegisteredKeyword(String)

    var errorDescription: String? {
        switch self {
        case .missingRegisteredKeyword:
            "技能必须设置一个唯一索引"
        case .invalidRegisteredKeyword:
            "索引不能包含空格，也不能以“-”开头"
        case .duplicateRegisteredKeyword(let keyword):
            "索引“\(keyword)”已被其他技能使用"
        }
    }
}

struct LocalAssistantSkillPackage: Codable {
    static let formatIdentifier = "com.localassistant.skill"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let skill: UserSkill
}

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [UserSkill] = []
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let deletedBuiltInsKey = "skills.deletedBuiltInIdentifiers"

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
        seedBuiltInSkillsIfNeeded()
    }

    func save(_ skill: UserSkill) throws {
        var skill = skill
        let keyword = skill.registeredKeyword?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !keyword.isEmpty else { throw SkillStoreError.missingRegisteredKeyword }
        guard !keyword.contains(where: \.isWhitespace), !keyword.hasPrefix("-") else {
            throw SkillStoreError.invalidRegisteredKeyword
        }
        let normalizedKeyword = normalizedIndex(keyword)
        if skills.contains(where: { existing in
            existing.id != skill.id
                && existing.registeredKeyword.map(normalizedIndex) == normalizedKeyword
        }) {
            throw SkillStoreError.duplicateRegisteredKeyword(keyword)
        }
        skill.registeredKeyword = keyword

        let previousSkills = skills
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.insert(skill, at: 0)
        }
        do {
            try persist()
        } catch {
            skills = previousSkills
            throw error
        }
        AppConsole.shared.success("技能已保存：\(skill.name)（\(skill.id.uuidString)）", category: "SkillStore")
    }

    private func normalizedIndex(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    func delete(_ skill: UserSkill) throws {
        let previousSkills = skills
        let previousDeletedBuiltIns = deletedBuiltInIdentifiers
        skills.removeAll { $0.id == skill.id }
        if let identifier = skill.builtInIdentifier {
            var deleted = previousDeletedBuiltIns
            deleted.insert(identifier)
            deletedBuiltInIdentifiers = deleted
        }
        do {
            try persist()
        } catch {
            skills = previousSkills
            deletedBuiltInIdentifiers = previousDeletedBuiltIns
            throw error
        }
        AppConsole.shared.warning(
            "技能已删除：\(skill.name)\(skill.isBuiltIn ? "（已记住不再自动恢复）" : "")",
            category: "SkillStore"
        )
    }

    func exportPackageData(for skill: UserSkill) throws -> Data {
        let package = LocalAssistantSkillPackage(
            format: LocalAssistantSkillPackage.formatIdentifier,
            schemaVersion: LocalAssistantSkillPackage.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            skill: skill
        )
        let data = try encoder.encode(package)
        AppConsole.shared.info("已生成技能导出包：\(skill.name)，字节数=\(data.count)", category: "SkillStore")
        return data
    }

    private func load() {
        do {
            let url = try storageURL(createDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            skills = try decoder.decode([UserSkill].self, from: data)
            lastError = nil
            AppConsole.shared.info("已加载 \(skills.count) 个本地技能", category: "SkillStore")
        } catch {
            lastError = error.localizedDescription
            AppConsole.shared.error("本地技能加载失败：\(error.localizedDescription)", category: "SkillStore")
        }
    }

    private func persist() throws {
        do {
            let url = try storageURL(createDirectory: true)
            let data = try encoder.encode(skills)
            try data.write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppConsole.shared.error("本地技能写入失败：\(error.localizedDescription)", category: "SkillStore")
            throw error
        }
    }

    private var deletedBuiltInIdentifiers: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: deletedBuiltInsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: deletedBuiltInsKey)
        }
    }

    private func seedBuiltInSkillsIfNeeded() {
        let existingIdentifiers = Set(skills.compactMap(\.builtInIdentifier))
        let deletedIdentifiers = deletedBuiltInIdentifiers
        let additions = BuiltInSkillCatalog.skills.filter { skill in
            guard let identifier = skill.builtInIdentifier else { return false }
            return !existingIdentifiers.contains(identifier) && !deletedIdentifiers.contains(identifier)
        }
        guard !additions.isEmpty else { return }

        let previousSkills = skills
        skills.append(contentsOf: additions)
        do {
            try persist()
            AppConsole.shared.success(
                "已安装 \(additions.count) 个可编辑的内置技能",
                category: "SkillStore"
            )
        } catch {
            skills = previousSkills
            AppConsole.shared.error(
                "内置技能初始化失败：\(error.localizedDescription)",
                category: "SkillStore"
            )
        }
    }

    private func storageURL(createDirectory: Bool) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = baseURL.appendingPathComponent("LocalAssistant/Skills", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("skills.json")
    }
}

private enum BuiltInSkillCatalog {
    static let skills: [UserSkill] = [
        make(
            number: 1,
            identifier: "builtin.ocr.region",
            name: "识别屏幕文字",
            keyword: "ocr",
            aliases: ["截图识别", "屏幕 OCR"],
            summary: "选择一块屏幕区域，并使用 Apple Vision 在本机识别文字。",
            actions: ["选择屏幕区域", "在本机识别图片文字", "显示识别结果"],
            output: "在面板中显示可复制的纯文字",
            requiredTools: ["screen.captureRegion", "image.ocr"],
            permissions: ["screen_recording"],
            executionMode: .localOnly,
            workflow: [
                step("capture", "screen.captureRegion", saveAs: "capturePath"),
                step("recognize", "image.ocr", ["path": .string("$capturePath")], saveAs: "recognizedText")
            ]
        ),
        make(
            number: 2,
            identifier: "builtin.ocr.image",
            name: "识别图片文字",
            keyword: "ocrfile",
            aliases: ["图片 OCR", "识图文字"],
            summary: "读取用户传入的图片，并使用 Apple Vision 在本机识别文字。",
            actions: ["接收一张图片", "在本机识别图片文字", "显示识别结果"],
            output: "在面板中显示可复制的纯文字",
            requiredTools: ["image.ocr"],
            permissions: ["user_selected_file"],
            executionMode: .localOnly,
            parameters: [parameter("image", "图片", .image, "要进行文字识别的图片")],
            workflow: [
                step("recognize", "image.ocr", ["path": .string("{{图片}}")], saveAs: "recognizedText")
            ]
        ),
        selectionModelSkill(
            number: 3,
            identifier: "builtin.selection.summarize",
            name: "总结选中文字",
            keyword: "sum",
            aliases: ["summary", "总结选中"],
            summary: "读取其他应用中已选中的文字，并生成简洁摘要。",
            instruction: "总结下面的选中文字。保留关键信息和结论，使用简洁的 Markdown，不要添加无关前言。",
            output: "在面板中显示结构清晰的摘要"
        ),
        selectionModelSkill(
            number: 4,
            identifier: "builtin.selection.translate",
            name: "翻译选中文字",
            keyword: "trans",
            aliases: ["translate", "翻译选中"],
            summary: "读取其他应用中已选中的文字；中文翻译为自然英语，其他语言翻译为中文。",
            instruction: "翻译下面的选中文字。如果原文主要是中文，翻译成自然英语；否则翻译成自然中文。保留段落和语气，只输出译文。",
            output: "在面板中显示译文"
        ),
        selectionModelSkill(
            number: 5,
            identifier: "builtin.selection.explain",
            name: "解释选中文字",
            keyword: "explain",
            aliases: ["解释选中", "ex"],
            summary: "读取其他应用中已选中的文字，并用容易理解的方式解释。",
            instruction: "解释下面的选中文字。先给出一句话结论，再说明关键概念；根据原文难度控制篇幅。",
            output: "在面板中显示通俗解释"
        ),
        make(
            number: 6,
            identifier: "builtin.selection.rewrite",
            name: "改写并替换选中文字",
            keyword: "rewrite",
            aliases: ["改写选中", "润色"],
            summary: "改写其他应用中已选中的文字，并在用户确认后替换原文。",
            actions: ["读取选中文字", "调用用户选择的云端模型改写", "显示原生确认框", "确认后替换原文"],
            output: "替换选中文字，并在面板中显示改写结果",
            requiredTools: ["selection.readText", "model.generateText", "selection.replaceText"],
            permissions: ["accessibility", "cloud_api", "confirmation_required"],
            executionMode: .cloudAssisted,
            workflow: [
                step("read_selection", "selection.readText", saveAs: "selectedText"),
                step("rewrite", "model.generateText", ["input": .string("$selectedText")], saveAs: "rewrittenText"),
                step("replace", "selection.replaceText", ["text": .string("$rewrittenText")], saveAs: "result")
            ],
            modelTask: modelTask(
                "改写下面的选中文字，使表达更清晰、自然、专业。保持原意、语言和必要格式，只输出改写后的正文。\n\n{{selectedText}}",
                variables: ["selectedText"]
            ),
            dataDisclosure: ["选中的文字会发送给用户选择的云端模型用于改写"]
        ),
        make(
            number: 7,
            identifier: "builtin.clipboard.translate",
            name: "翻译剪贴板",
            keyword: "cliptrans",
            aliases: ["剪贴板翻译", "clipboard translate"],
            summary: "读取剪贴板文字，翻译后显示结果并写回剪贴板。",
            actions: ["读取剪贴板文字", "调用用户选择的云端模型翻译", "把译文写回剪贴板"],
            output: "显示译文，并复制到剪贴板",
            requiredTools: ["clipboard.readText", "model.generateText", "clipboard.writeText"],
            permissions: ["clipboard", "cloud_api"],
            executionMode: .cloudAssisted,
            workflow: [
                step("read_clipboard", "clipboard.readText", saveAs: "clipboardText"),
                step("translate", "model.generateText", ["input": .string("$clipboardText")], saveAs: "translatedText"),
                step("write_clipboard", "clipboard.writeText", ["text": .string("$translatedText")], saveAs: "result")
            ],
            modelTask: modelTask(
                "将下面的剪贴板文本翻译成自然英语。保留原意、段落和标点，只输出译文。\n\n{{clipboardText}}",
                variables: ["clipboardText"]
            ),
            dataDisclosure: ["剪贴板文字会发送给用户选择的云端模型用于翻译"]
        ),
        make(
            number: 8,
            identifier: "builtin.file.read",
            name: "读取文件文字",
            keyword: "read",
            aliases: ["读取文件", "read file"],
            summary: "在本机读取文本、代码、RTF 或含文字层的 PDF。",
            actions: ["读取用户选择的文件", "提取其中的文字", "显示内容"],
            output: "在面板中显示文件文字",
            requiredTools: ["file.readText"],
            permissions: ["user_selected_file"],
            executionMode: .localOnly,
            parameters: [parameter("file", "文件", .file, "要读取的文本、代码、RTF 或 PDF 文件")],
            workflow: [step("read_file", "file.readText", ["path": .string("{{文件}}")], saveAs: "fileText")]
        ),
        make(
            number: 9,
            identifier: "builtin.file.summarize",
            name: "总结文件",
            keyword: "filesum",
            aliases: ["文件总结", "summarize file"],
            summary: "在本机读取文件文字，再交给用户选择的云端模型总结。",
            actions: ["读取用户选择的文件", "调用云端模型总结", "显示摘要"],
            output: "在面板中显示结构清晰的文件摘要",
            requiredTools: ["file.readText", "model.generateText"],
            permissions: ["user_selected_file", "cloud_api"],
            executionMode: .cloudAssisted,
            parameters: [parameter("file", "文件", .file, "要总结的文本、代码、RTF 或 PDF 文件")],
            workflow: [
                step("read_file", "file.readText", ["path": .string("{{文件}}")], saveAs: "fileText"),
                step("summarize", "model.generateText", ["input": .string("$fileText")], saveAs: "summary")
            ],
            modelTask: modelTask(
                "总结下面的文件内容。先给出核心结论，再列出重点和待办；不要编造文件中不存在的信息。\n\n{{fileText}}",
                variables: ["fileText"]
            ),
            dataDisclosure: ["所选文件中提取的文字会发送给用户选择的云端模型用于总结"]
        ),
        make(
            number: 10,
            identifier: "builtin.file.search",
            name: "搜索本地文件",
            keyword: "find",
            aliases: ["搜索文件", "file search"],
            summary: "按名称搜索桌面、文稿和下载目录中的本地文件。",
            actions: ["接收文件名关键词", "在常用目录中进行有界搜索", "列出匹配路径"],
            output: "显示最多 30 个匹配文件及完整路径",
            requiredTools: ["file.search"],
            permissions: ["files_and_folders"],
            executionMode: .localOnly,
            parameters: [parameter("query", "文件名", .text, "文件名包含的关键词")],
            workflow: [step("search", "file.search", ["query": .string("{{文件名}}"), "limit": .integer(30)], saveAs: "matches")]
        ),
        make(
            number: 11,
            identifier: "builtin.file.list",
            name: "查看文件夹内容",
            keyword: "list",
            aliases: ["列出文件", "folder list"],
            summary: "列出用户选择文件夹中的内容。",
            actions: ["接收一个文件夹", "读取其中的非隐藏项目", "按名称显示路径"],
            output: "显示文件夹中的项目列表",
            requiredTools: ["file.list"],
            permissions: ["user_selected_folder"],
            executionMode: .localOnly,
            parameters: [parameter("folder", "文件夹", .folder, "要查看的文件夹")],
            workflow: [step("list", "file.list", ["directory": .string("{{文件夹}}"), "limit": .integer(100)], saveAs: "items")]
        ),
        make(
            number: 12,
            identifier: "builtin.file.rename",
            name: "重命名文件",
            keyword: "rename",
            aliases: ["文件改名", "rename file"],
            summary: "在用户确认后重命名所选文件或文件夹。",
            actions: ["接收文件和新名称", "显示原生确认框", "确认后在原目录重命名"],
            output: "显示重命名后的完整路径",
            requiredTools: ["file.rename"],
            permissions: ["user_selected_file", "confirmation_required"],
            executionMode: .localOnly,
            parameters: [
                parameter("file", "文件", .file, "要重命名的文件"),
                parameter("new_name", "新名称", .text, "包含扩展名的新文件名")
            ],
            workflow: [step("rename", "file.rename", ["path": .string("{{文件}}"), "newName": .string("{{新名称}}")], saveAs: "newPath")]
        ),
        make(
            number: 13,
            identifier: "builtin.file.move",
            name: "移动文件",
            keyword: "move",
            aliases: ["移动本地文件", "move file"],
            summary: "在用户确认后把所选文件移动到目标文件夹。",
            actions: ["接收文件和目标文件夹", "显示原生确认框", "确认后移动文件"],
            output: "显示移动后的完整路径",
            requiredTools: ["file.move"],
            permissions: ["user_selected_file", "user_selected_folder", "confirmation_required"],
            executionMode: .localOnly,
            parameters: [
                parameter("file", "文件", .file, "要移动的文件"),
                parameter("destination", "目标文件夹", .folder, "文件要移动到的文件夹")
            ],
            workflow: [step("move", "file.move", ["path": .string("{{文件}}"), "destination": .string("{{目标文件夹}}")], saveAs: "newPath")]
        ),
        make(
            number: 14,
            identifier: "builtin.file.trash",
            name: "移到废纸篓",
            keyword: "trash",
            aliases: ["删除文件", "trash file"],
            summary: "在用户确认后把所选文件移到 macOS 废纸篓。",
            actions: ["接收一个文件", "显示原生确认框", "确认后移到废纸篓"],
            output: "显示操作结果",
            requiredTools: ["file.trash"],
            permissions: ["user_selected_file", "confirmation_required"],
            executionMode: .localOnly,
            parameters: [parameter("file", "文件", .file, "要移到废纸篓的文件")],
            workflow: [step("trash", "file.trash", ["path": .string("{{文件}}")], saveAs: "trashedPath")]
        ),
        make(
            number: 15,
            identifier: "builtin.system.diagnose",
            name: "诊断电脑卡顿",
            keyword: "diagnose",
            aliases: ["电脑为什么卡", "系统诊断"],
            summary: "读取必要的系统快照，并让云端模型把诊断结果解释成普通人能理解的建议。",
            actions: ["在本机读取系统和进程快照", "调用云端模型分析异常", "给出简明原因和建议"],
            output: "说明最可能的卡顿原因，并给出按优先级排列的处理建议",
            requiredTools: ["system.snapshot", "model.generateText"],
            permissions: ["process_information", "cloud_api"],
            executionMode: .cloudAssisted,
            workflow: [
                step("snapshot", "system.snapshot", saveAs: "systemSnapshot"),
                step("diagnose", "model.generateText", ["input": .string("$systemSnapshot")], saveAs: "diagnosis")
            ],
            modelTask: modelTask(
                "根据下面的 macOS 系统快照判断当前是否存在明显异常。不要重复罗列全部指标；先说最可能的问题，再给最多 4 条可执行建议。无法确定时要明确说明。\n\n{{systemSnapshot}}",
                variables: ["systemSnapshot"]
            ),
            dataDisclosure: ["系统快照和进程名称会发送给用户选择的云端模型用于诊断"]
        )
    ]

    private static func make(
        number: Int,
        identifier: String,
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
    ) -> UserSkill {
        UserSkill(
            builtInIdentifier: identifier,
            id: UUID(uuidString: String(format: "4C413000-0000-4000-8000-%012d", number))!,
            name: name,
            keyword: keyword,
            aliases: aliases,
            summary: summary,
            actions: actions,
            output: output,
            requiredTools: requiredTools,
            permissions: permissions,
            executionMode: executionMode,
            parameters: parameters,
            workflow: workflow,
            modelTask: modelTask,
            dataDisclosure: dataDisclosure
        )
    }

    private static func selectionModelSkill(
        number: Int,
        identifier: String,
        name: String,
        keyword: String,
        aliases: [String],
        summary: String,
        instruction: String,
        output: String
    ) -> UserSkill {
        make(
            number: number,
            identifier: identifier,
            name: name,
            keyword: keyword,
            aliases: aliases,
            summary: summary,
            actions: ["读取选中文字", "调用用户选择的云端模型处理", "显示结果"],
            output: output,
            requiredTools: ["selection.readText", "model.generateText"],
            permissions: ["accessibility", "cloud_api"],
            executionMode: .cloudAssisted,
            workflow: [
                step("read_selection", "selection.readText", saveAs: "selectedText"),
                step("generate", "model.generateText", ["input": .string("$selectedText")], saveAs: "result")
            ],
            modelTask: modelTask(instruction + "\n\n{{selectedText}}", variables: ["selectedText"]),
            dataDisclosure: ["选中的文字会发送给用户选择的云端模型用于处理"]
        )
    }

    private static func parameter(
        _ id: String,
        _ name: String,
        _ type: SkillParameterType,
        _ description: String
    ) -> SkillParameterDefinition {
        SkillParameterDefinition(id: id, name: name, type: type, required: true, description: description)
    }

    private static func step(
        _ id: String,
        _ tool: String,
        _ arguments: [String: SkillJSONValue] = [:],
        saveAs: String? = nil
    ) -> SkillWorkflowStep {
        SkillWorkflowStep(id: id, tool: tool, arguments: arguments, saveAs: saveAs)
    }

    private static func modelTask(_ prompt: String, variables: [String]) -> SkillModelTask {
        SkillModelTask(
            tool: "model.generateText",
            promptTemplate: prompt,
            inputVariables: variables,
            providerPolicy: "userDefault"
        )
    }
}
