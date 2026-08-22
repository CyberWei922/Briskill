import Foundation

enum SkillStoreError: LocalizedError {
    case missingRegisteredKeyword
    case invalidRegisteredKeyword
    case duplicateRegisteredKeyword(String)
    case appleScriptRiskAcknowledgementRequired
    case executionCategoryMismatch(String)
    case missingAppleScriptStep
    case unavailableTools([String])
    case invalidWorkflow(String)
    case unsupportedFutureSchema(Int)
    case protectedDefinitionConflict
    case storageRequiresNewerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .missingRegisteredKeyword:
            "技能必须设置一个唯一索引"
        case .invalidRegisteredKeyword:
            "索引不能包含空格，也不能以“-”开头"
        case .duplicateRegisteredKeyword(let keyword):
            "索引“\(keyword)”已被其他技能使用"
        case .appleScriptRiskAcknowledgementRequired:
            "保存前必须阅读 AppleScript 源代码并勾选“我已知晓风险”"
        case .executionCategoryMismatch(let reason):
            "技能执行类型与工作流不一致：\(reason)"
        case .missingAppleScriptStep:
            "技能包含 AppleScript 源代码，但工作流中没有 automation.appleScript 步骤"
        case .unavailableTools(let tools):
            "技能引用了尚未安装的工具：\(tools.joined(separator: "、"))"
        case .invalidWorkflow(let reason):
            "工作流无法保存：\(reason)"
        case .unsupportedFutureSchema(let version):
            "这个技能使用了较新的格式（v\(version)），请升级 Local Assistant 后再编辑"
        case .protectedDefinitionConflict:
            "磁盘上存在同一 ID 的未识别技能文件。为避免覆盖原始数据，当前版本拒绝保存"
        case .storageRequiresNewerVersion(let version):
            "技能索引使用了较新的格式（v\(version)）。当前版本已进入只读保护，请升级 Local Assistant"
        }
    }
}

private struct SkillDefinitionsIndex: Codable {
    static let currentFormatVersion = 2

    var formatVersion: Int
    var orderedIDs: [UUID]
    var deletedIDs: [UUID]
    var definitionFiles: [String: String]

    init(orderedIDs: [UUID], deletedIDs: [UUID], definitionFiles: [UUID: String]) {
        formatVersion = Self.currentFormatVersion
        self.orderedIDs = orderedIDs
        self.deletedIDs = deletedIDs
        self.definitionFiles = Dictionary(
            uniqueKeysWithValues: definitionFiles.map { ($0.key.uuidString, $0.value) }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case orderedIDs
        case deletedIDs
        case definitionFiles
    }

    init(from decoder: Decoder) throws {
        // DefinitionsV3 最初使用裸 [UUID] 作为索引；继续无损读取该格式。
        if let legacyIDs = try? decoder.singleValueContainer().decode([UUID].self) {
            formatVersion = 1
            orderedIDs = legacyIDs
            deletedIDs = []
            definitionFiles = [:]
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? Self.currentFormatVersion
        orderedIDs = try container.decodeIfPresent([UUID].self, forKey: .orderedIDs) ?? []
        deletedIDs = try container.decodeIfPresent([UUID].self, forKey: .deletedIDs) ?? []
        definitionFiles = try container.decodeIfPresent([String: String].self, forKey: .definitionFiles) ?? [:]
    }

    var resolvedDefinitionFiles: [UUID: String] {
        var result: [UUID: String] = [:]
        for (identifier, filename) in definitionFiles {
            guard let uuid = UUID(uuidString: identifier) else { continue }
            result[uuid] = filename
        }
        return result
    }
}

private struct SkillDeletionTombstones: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var deletedIDs: [UUID]

    init(deletedIDs: [UUID]) {
        formatVersion = Self.currentFormatVersion
        self.deletedIDs = deletedIDs
    }
}

private struct SkillV3LoadResult {
    var skills: [UserSkill]
    var deletedIDs: Set<UUID>
    var preservedIDs: [UUID]
    var futureIDs: Set<UUID>
    var definitionFiles: [UUID: String]
    var storageFormatRequiresNewerVersion: Int?
    var suspendAutomaticMaintenance: Bool
    var warnings: [String]
}

struct LocalAssistantSkillPackage: Codable {
    static let formatIdentifier = "com.localassistant.skill"
    static let currentSchemaVersion = SkillWorkflowDefinitionV3.currentVersion

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
    private let retiredBuiltInIdentifiers: Set<String> = ["builtin.file.move"]
    private var deletedSkillIDs: Set<UUID> = []
    private var preservedDefinitionIDs: [UUID] = []
    private var futureDefinitionIDs: Set<UUID> = []
    private var definitionFilesByID: [UUID: String] = [:]
    private var storageFormatRequiresNewerVersion: Int?
    private var suspendAutomaticMaintenance = false

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
        removeRetiredBuiltInSkills()
        seedBuiltInSkillsIfNeeded()
    }

    func save(_ skill: UserSkill) throws {
        var skill = skill
        if let requiredVersion = requiredFutureSchemaVersion(for: skill) {
            throw SkillStoreError.unsupportedFutureSchema(requiredVersion)
        }
        if let storageFormatRequiresNewerVersion {
            throw SkillStoreError.storageRequiresNewerVersion(storageFormatRequiresNewerVersion)
        }
        guard !preservedDefinitionIDs.contains(skill.id), !futureDefinitionIDs.contains(skill.id) else {
            throw SkillStoreError.protectedDefinitionConflict
        }
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
        skill.schemaVersion = SkillWorkflowDefinitionV3.currentVersion
        try normalizeAndValidate(&skill)

        let previousSkills = skills
        let previousDeletedSkillIDs = deletedSkillIDs
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.insert(skill, at: 0)
        }
        deletedSkillIDs.remove(skill.id)
        do {
            try persist()
        } catch {
            skills = previousSkills
            deletedSkillIDs = previousDeletedSkillIDs
            throw error
        }
        AppConsole.shared.success("技能已保存：\(skill.name)（\(skill.id.uuidString)）", category: "SkillStore")
    }

    func setEnabled(_ isEnabled: Bool, for skillID: UUID) throws {
        if let storageFormatRequiresNewerVersion {
            throw SkillStoreError.storageRequiresNewerVersion(storageFormatRequiresNewerVersion)
        }
        guard let index = skills.firstIndex(where: { $0.id == skillID }) else {
            throw SkillStoreError.protectedDefinitionConflict
        }
        guard skills[index].isEnabled != isEnabled else { return }

        let previousSkills = skills
        skills[index].isEnabled = isEnabled
        skills[index].updatedAt = Date()
        do {
            try persist()
        } catch {
            skills = previousSkills
            throw error
        }
        AppConsole.shared.info(
            "技能已\(isEnabled ? "启用" : "停用")：\(skills[index].name)",
            category: "SkillStore"
        )
    }

    private func normalizedIndex(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    func delete(_ skill: UserSkill) throws {
        if let storageFormatRequiresNewerVersion {
            throw SkillStoreError.storageRequiresNewerVersion(storageFormatRequiresNewerVersion)
        }
        let previousSkills = skills
        let previousDeletedBuiltIns = deletedBuiltInIdentifiers
        let previousDeletedSkillIDs = deletedSkillIDs
        skills.removeAll { $0.id == skill.id }
        deletedSkillIDs.insert(skill.id)
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
            deletedSkillIDs = previousDeletedSkillIDs
            throw error
        }
        AppConsole.shared.warning(
            "技能已删除：\(skill.name)\(skill.isBuiltIn ? "（已记住不再自动恢复）" : "")",
            category: "SkillStore"
        )
    }

    func exportPackageData(for skill: UserSkill) throws -> Data {
        var exportedSkill = skill
        // Risk approval belongs to one user and one local installation. It must
        // never travel inside a shared package and silently authorize the script
        // on somebody else's Mac.
        exportedSkill.appleScript?.acknowledgedSourceHash = nil
        let package = LocalAssistantSkillPackage(
            format: LocalAssistantSkillPackage.formatIdentifier,
            schemaVersion: LocalAssistantSkillPackage.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            skill: exportedSkill
        )
        let data = try encoder.encode(package)
        AppConsole.shared.info("已生成技能导出包：\(skill.name)，字节数=\(data.count)", category: "SkillStore")
        return data
    }

    private func load() {
        do {
            let v3Directory = try definitionsDirectory(named: "DefinitionsV3", create: false)
            if fileManager.fileExists(atPath: v3Directory.path) {
                // DefinitionsV3 一旦存在就必须是权威数据源。即使索引或个别技能损坏，也绝不
                // 回退到旧 V2 后再覆盖 V3；改为逐文件恢复，并保留无法读取的原始文件。
                let result = loadV3Definitions(from: v3Directory)
                deletedSkillIDs = result.deletedIDs
                preservedDefinitionIDs = result.preservedIDs
                futureDefinitionIDs = result.futureIDs
                definitionFilesByID = result.definitionFiles
                storageFormatRequiresNewerVersion = result.storageFormatRequiresNewerVersion
                suspendAutomaticMaintenance = result.suspendAutomaticMaintenance
                skills = result.skills.map(migratingStoredSkill)
                lastError = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
                if result.warnings.isEmpty {
                    AppConsole.shared.info(
                        "已从 Skill V3 目录加载 \(skills.count) 个本地技能",
                        category: "SkillStore"
                    )
                } else {
                    AppConsole.shared.warning(
                        "Skill V3 已恢复 \(skills.count) 个技能；\(result.warnings.joined(separator: "；"))",
                        category: "SkillStore"
                    )
                }
                return
            }

            if let v2Skills = try loadV2DefinitionsIfPresent() {
                skills = v2Skills.map(migratingStoredSkill)
                try persistCurrentDefinitions()
                lastError = nil
                AppConsole.shared.info(
                    "已将 \(skills.count) 个技能迁移到独立的 Skill V3 目录；原 V2 文件保持不变",
                    category: "SkillStore"
                )
                return
            }
            let url = try storageURL(createDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            skills = try decoder.decode([UserSkill].self, from: data).map(migratingStoredSkill)
            try persistCurrentDefinitions()
            lastError = nil
            AppConsole.shared.info("已迁移 \(skills.count) 个旧技能到 Skill V3 独立文件；原 skills.json 保留为备份", category: "SkillStore")
        } catch {
            lastError = error.localizedDescription
            AppConsole.shared.error("本地技能加载失败：\(error.localizedDescription)", category: "SkillStore")
        }
    }

    private func migratingStoredSkill(_ storedSkill: UserSkill) -> UserSkill {
        var skill = storedSkill
        var definition = skill.workflowV3 ?? SkillWorkflowDefinitionV3.migrate(
            from: skill.workflow ?? [],
            parameters: skill.resolvedParameters,
            modelTask: skill.modelTask
        )
        let legacyStepsByID = Dictionary(
            (skill.workflow ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in definition.steps.indices where definition.steps[index].outputName == nil {
            definition.steps[index].outputName = legacyStepsByID[definition.steps[index].id]?.saveAs
        }
        if definition.steps.isEmpty {
            definition = explicitWorkflowForLegacySkill(skill)
        }
        canonicalizeTools(in: &definition)
        for index in definition.steps.indices where definition.steps[index].toolID == "model.generateText"
            && definition.steps[index].promptTemplate == nil {
            definition.steps[index].promptTemplate = skill.modelTask?.promptTemplate
        }
        skill.workflowV3 = definition
        skill.workflow = SkillWorkflowCompiler.compile(definition, parameters: skill.resolvedParameters)
        skill.schemaVersion = SkillWorkflowDefinitionV3.currentVersion
        skill.executionMode = SkillWorkflowCompiler.inferExecutionMode(from: definition)
        skill.requiredTools = normalizedToolIdentifiers(in: skill)
        skill.permissions = derivedPermissions(for: skill)
        return skill
    }

    private func explicitWorkflowForLegacySkill(_ skill: UserSkill) -> SkillWorkflowDefinitionV3 {
        let searchableText = ([skill.name, skill.summary, skill.originalRequest] + skill.actions)
            .joined(separator: " ")
            .lowercased()
        let toolHints = Set(skill.requiredTools.map {
            $0.lowercased().replacingOccurrences(of: "_", with: ".")
        })
        let isClipboardTranslation = (searchableText.contains("剪贴板")
            || searchableText.contains("剪切板")
            || toolHints.contains("clipboard")
            || toolHints.contains("clipboard.readtext"))
            && (searchableText.contains("翻译") || searchableText.contains("translate") || toolHints.contains("translate"))

        if isClipboardTranslation {
            let readStep = SkillWorkflowStepV3(
                id: "read_clipboard",
                toolID: "clipboard.readText",
                arguments: [:],
                promptTemplate: nil,
                outputName: "clipboardText"
            )
            let modelStep = SkillWorkflowStepV3(
                id: "translate_text",
                toolID: "model.generateText",
                arguments: ["input": .stepOutput(readStep.id)],
                promptTemplate: skill.modelTask?.promptTemplate
                    ?? "将下面的剪贴板文字翻译成自然、准确的目标语言。只输出译文。\n\n{{clipboardText}}",
                outputName: "translatedText"
            )
            let writeStep = SkillWorkflowStepV3(
                id: "write_clipboard",
                toolID: "clipboard.writeText",
                arguments: ["text": .stepOutput(modelStep.id)],
                promptTemplate: nil,
                outputName: "clipboardResult"
            )
            return SkillWorkflowDefinitionV3(steps: [readStep, modelStep, writeStep])
        }

        if let modelTask = skill.modelTask {
            return SkillWorkflowDefinitionV3(
                steps: [
                    SkillWorkflowStepV3(
                        id: "generate_text",
                        toolID: "model.generateText",
                        arguments: ["input": .userInput],
                        promptTemplate: modelTask.promptTemplate,
                        outputName: "modelResult"
                    )
                ]
            )
        }

        return SkillWorkflowDefinitionV3(steps: [])
    }

    private func normalizeAndValidate(_ skill: inout UserSkill) throws {
        var definition = skill.resolvedWorkflowV3
        canonicalizeTools(in: &definition)
        skill.workflowV3 = definition
        skill.workflow = SkillWorkflowCompiler.compile(definition, parameters: skill.resolvedParameters)
        do {
            try SkillWorkflowValidator.validateForSaving(
                definition,
                parameters: skill.resolvedParameters,
                executionMode: skill.resolvedExecutionMode,
                modelTask: skill.modelTask,
                appleScript: skill.appleScript
            )
        } catch {
            throw SkillStoreError.invalidWorkflow(error.localizedDescription)
        }

        let toolIdentifiers = normalizedToolIdentifiers(in: skill)
        let hasModel = toolIdentifiers.contains("model.generateText")
        let hasLocalTool = toolIdentifiers.contains { identifier in
            ToolDescriptorCatalog.byIdentifier[identifier]?.executionLocation == .local
        }
        let unavailable = toolIdentifiers.filter { ToolDescriptorCatalog.byIdentifier[$0] == nil }
        guard unavailable.isEmpty else {
            throw SkillStoreError.unavailableTools(unavailable)
        }

        switch skill.resolvedExecutionMode {
        case .local:
            guard !hasModel else {
                throw SkillStoreError.executionCategoryMismatch("本地技能不能调用云端模型")
            }
        case .hybrid:
            guard hasModel, hasLocalTool else {
                throw SkillStoreError.executionCategoryMismatch("混合技能必须同时包含本地步骤和云端模型步骤")
            }
        case .cloud:
            guard hasModel, !hasLocalTool else {
                throw SkillStoreError.executionCategoryMismatch("云端技能只能包含云端模型步骤")
            }
        }

        if skill.containsAppleScript {
            let hasExecutableAppleScriptStep = definition.steps.contains { step in
                step.toolID == "automation.appleScript"
            } == true
            guard hasExecutableAppleScriptStep else {
                throw SkillStoreError.missingAppleScriptStep
            }
            guard skill.hasValidAppleScriptRiskAcknowledgement else {
                throw SkillStoreError.appleScriptRiskAcknowledgementRequired
            }
            try AppleScriptCompiler.validate(skill.appleScript?.source ?? "")
        }

        skill.requiredTools = toolIdentifiers
        skill.permissions = derivedPermissions(for: skill)
        if var appleScript = skill.appleScript {
            let report = AppleScriptRiskAnalyzer.analyze(appleScript.source)
            appleScript.targetApplications = report.targetApplications
            appleScript.riskNotes = report.notes
            skill.appleScript = appleScript
        }
    }

    private func normalizedToolIdentifiers(in skill: UserSkill) -> [String] {
        let workflowTools = skill.workflowV3?.steps.map(\.toolID)
            ?? skill.workflow?.map(\.tool)
            ?? []
        let source = workflowTools.isEmpty ? skill.requiredTools : workflowTools
        var seen = Set<String>()
        return source.compactMap { rawIdentifier in
            let identifier = ToolRegistry.shared.canonicalIdentifier(for: rawIdentifier)
            guard seen.insert(identifier).inserted else { return nil }
            return identifier
        }
    }

    private func derivedPermissions(for skill: UserSkill) -> [String] {
        var values: [String] = []
        for identifier in normalizedToolIdentifiers(in: skill) {
            values.append(contentsOf: ToolDescriptorCatalog.byIdentifier[identifier]?.permissions ?? [])
        }
        if !(skill.networkHosts ?? []).isEmpty { values.append("network_access") }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func inferredExecutionMode(for skill: UserSkill) -> SkillExecutionMode {
        if let definition = skill.workflowV3 {
            return SkillWorkflowCompiler.inferExecutionMode(from: definition)
        }
        let identifiers = normalizedToolIdentifiers(in: skill)
        let hasModel = identifiers.contains("model.generateText")
        let hasLocal = identifiers.contains { ToolDescriptorCatalog.byIdentifier[$0]?.executionLocation == .local }
        if hasModel && hasLocal { return .hybrid }
        if hasModel { return .cloud }
        return .local
    }

    private func canonicalizeTools(in definition: inout SkillWorkflowDefinitionV3) {
        for index in definition.steps.indices {
            definition.steps[index].toolID = ToolRegistry.shared.canonicalIdentifier(
                for: definition.steps[index].toolID
            )
        }
    }

    private func persist() throws {
        do {
            try persistCurrentDefinitions()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppConsole.shared.error("本地技能写入失败：\(error.localizedDescription)", category: "SkillStore")
            throw error
        }
    }

    private func loadV3Definitions(from directory: URL) -> SkillV3LoadResult {
        let indexURL = directory.appendingPathComponent("index.json")
        let backupIndexURL = directory.appendingPathComponent("index.backup.json")
        let tombstonesURL = directory.appendingPathComponent("tombstones.json")
        var orderedIDs: [UUID] = []
        var deletedIDs = Set<UUID>()
        var definitionFiles: [UUID: String] = [:]
        var warnings: [String] = []
        var requiredStorageVersion: Int?
        var suspendMaintenance = false
        var loadedIndex: SkillDefinitionsIndex?

        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                let data = try Data(contentsOf: indexURL)
                if let version = futureStorageFormatVersion(
                    in: data,
                    currentVersion: SkillDefinitionsIndex.currentFormatVersion
                ) {
                    requiredStorageVersion = version
                    warnings.append("索引格式 v\(version) 高于当前支持版本，已启用只读保护")
                    suspendMaintenance = true
                }
                loadedIndex = try decoder.decode(SkillDefinitionsIndex.self, from: data)
            } catch {
                suspendMaintenance = true
                warnings.append("index.json 无法读取，已尝试只读备份与逐文件恢复（原技能文件未被覆盖）")
                AppConsole.shared.error(
                    "Skill V3 索引损坏，开始逐文件恢复：\(error.localizedDescription)",
                    category: "SkillStore"
                )
                if fileManager.fileExists(atPath: backupIndexURL.path) {
                    do {
                        let backupData = try Data(contentsOf: backupIndexURL)
                        loadedIndex = try decoder.decode(SkillDefinitionsIndex.self, from: backupData)
                        warnings.append("已使用上一次提交的索引备份")
                    } catch {
                        warnings.append("索引备份也无法读取")
                    }
                }
            }
        } else {
            warnings.append("缺少 index.json，已改用逐文件恢复")
        }

        if let index = loadedIndex {
            orderedIDs = uniqueIdentifiers(index.orderedIDs)
            deletedIDs = Set(index.deletedIDs)
            definitionFiles = index.resolvedDefinitionFiles
            if index.formatVersion > SkillDefinitionsIndex.currentFormatVersion {
                requiredStorageVersion = max(requiredStorageVersion ?? index.formatVersion, index.formatVersion)
                suspendMaintenance = true
                warnings.append("索引格式 v\(index.formatVersion) 高于当前支持版本，已启用只读保护")
            }
        }
        if fileManager.fileExists(atPath: tombstonesURL.path) {
            // Keep deletion tombstones outside the generation pointer as well.
            // If index.json is later damaged and index.backup.json is older, a
            // deleted definition must still not reappear during recovery.
            do {
                let data = try Data(contentsOf: tombstonesURL)
                if let version = futureStorageFormatVersion(
                    in: data,
                    currentVersion: SkillDeletionTombstones.currentFormatVersion
                ) {
                    requiredStorageVersion = max(requiredStorageVersion ?? version, version)
                    suspendMaintenance = true
                    warnings.append("删除墓碑格式 v\(version) 高于当前支持版本，已启用只读保护")
                }
                deletedIDs.formUnion(
                    try decoder.decode(SkillDeletionTombstones.self, from: data).deletedIDs
                )
            } catch {
                suspendMaintenance = true
                warnings.append("删除墓碑文件无法读取；原文件已保留")
            }
        }

        let definitionURLs: [URL]
        do {
            definitionURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                url.pathExtension.lowercased() == "json"
                    && url.lastPathComponent != indexURL.lastPathComponent
                    && url.lastPathComponent != backupIndexURL.lastPathComponent
                    && url.lastPathComponent != tombstonesURL.lastPathComponent
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            warnings.append("技能目录无法枚举；为保护 V3 数据，未尝试读取 V2")
            AppConsole.shared.error(
                "Skill V3 目录枚举失败：\(error.localizedDescription)",
                category: "SkillStore"
            )
            return SkillV3LoadResult(
                skills: [],
                deletedIDs: deletedIDs,
                preservedIDs: orderedIDs,
                futureIDs: [],
                definitionFiles: definitionFiles,
                storageFormatRequiresNewerVersion: requiredStorageVersion,
                suspendAutomaticMaintenance: true,
                warnings: warnings
            )
        }

        var urlsByIdentifier: [UUID: URL] = [:]
        for url in definitionURLs {
            guard let identifier = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                // 未知 JSON 文件既不参与加载，也绝不被清理。
                continue
            }
            if urlsByIdentifier[identifier] == nil {
                urlsByIdentifier[identifier] = url
            }
        }

        let indexedSet = Set(orderedIDs)
        let orphanIDs = urlsByIdentifier.keys
            .filter { !indexedSet.contains($0) && definitionFiles[$0] == nil }
            .sorted { $0.uuidString < $1.uuidString }
        let mappedIDs = definitionFiles.keys.sorted { $0.uuidString < $1.uuidString }
        let candidateIDs = uniqueIdentifiers(orderedIDs + mappedIDs + orphanIDs)

        var recoveredSkills: [UserSkill] = []
        var preservedIDs: [UUID] = []
        var futureIDs = Set<UUID>()
        var resolvedDefinitionFiles: [UUID: String] = [:]
        var recoveredOrphanCount = 0

        for identifier in candidateIDs {
            guard !deletedIDs.contains(identifier) else { continue }
            let url: URL?
            if let mappedFilename = definitionFiles[identifier] {
                if isSafeDefinitionFilename(mappedFilename) {
                    url = directory.appendingPathComponent(mappedFilename)
                    resolvedDefinitionFiles[identifier] = mappedFilename
                } else {
                    url = nil
                    suspendMaintenance = true
                    warnings.append("技能 \(identifier.uuidString) 的文件映射不安全，已隔离")
                }
            } else {
                url = urlsByIdentifier[identifier]
                if let url {
                    resolvedDefinitionFiles[identifier] = url.lastPathComponent
                }
            }
            guard let url, fileManager.fileExists(atPath: url.path) else {
                preservedIDs.append(identifier)
                suspendMaintenance = true
                warnings.append("索引中的技能 \(identifier.uuidString) 缺少定义文件")
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                if let version = futureSchemaVersion(in: data) {
                    futureIDs.insert(identifier)
                    preservedIDs.append(identifier)
                    warnings.append("技能 \(identifier.uuidString) 使用未来格式 v\(version)，已只读保留")
                    continue
                }

                let skill = try decoder.decode(UserSkill.self, from: data)
                guard skill.id == identifier else {
                    preservedIDs.append(identifier)
                    suspendMaintenance = true
                    warnings.append("技能文件 \(url.lastPathComponent) 的内部 ID 不一致，已隔离保留")
                    continue
                }
                if let version = requiredFutureSchemaVersion(for: skill) {
                    futureIDs.insert(identifier)
                    preservedIDs.append(identifier)
                    warnings.append("技能 \(identifier.uuidString) 使用未来格式 v\(version)，已只读保留")
                    continue
                }

                recoveredSkills.append(skill)
                if !indexedSet.contains(identifier) {
                    recoveredOrphanCount += 1
                }
            } catch {
                preservedIDs.append(identifier)
                suspendMaintenance = true
                warnings.append("技能 \(identifier.uuidString) 无法读取，原文件已保留")
                AppConsole.shared.error(
                    "Skill V3 单文件读取失败 \(url.lastPathComponent)：\(error.localizedDescription)",
                    category: "SkillStore"
                )
            }
        }

        if recoveredOrphanCount > 0 {
            warnings.append("已恢复 \(recoveredOrphanCount) 个未写入索引的完整技能")
        }

        return SkillV3LoadResult(
            skills: recoveredSkills,
            deletedIDs: deletedIDs,
            preservedIDs: uniqueIdentifiers(preservedIDs),
            futureIDs: futureIDs,
            definitionFiles: resolvedDefinitionFiles,
            storageFormatRequiresNewerVersion: requiredStorageVersion,
            suspendAutomaticMaintenance: suspendMaintenance,
            warnings: warnings
        )
    }

    private func isSafeDefinitionFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && (filename as NSString).lastPathComponent == filename
            && URL(fileURLWithPath: filename).pathExtension.lowercased() == "json"
            && filename != "index.json"
            && filename != "index.backup.json"
            && filename != "tombstones.json"
    }

    private func uniqueIdentifiers(_ identifiers: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private func requiredFutureSchemaVersion(for skill: UserSkill) -> Int? {
        let versions = [skill.resolvedSchemaVersion, skill.workflowV3?.version]
            .compactMap { $0 }
            .filter { $0 > SkillWorkflowDefinitionV3.currentVersion }
        return versions.max()
    }

    private func futureSchemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        var versions: [Int] = []
        if let schemaVersion = dictionary["schemaVersion"] as? NSNumber {
            versions.append(schemaVersion.intValue)
        }
        if let workflow = dictionary["workflowV3"] as? [String: Any],
           let workflowVersion = workflow["version"] as? NSNumber {
            versions.append(workflowVersion.intValue)
        }
        return versions.filter { $0 > SkillWorkflowDefinitionV3.currentVersion }.max()
    }

    private func futureStorageFormatVersion(in data: Data, currentVersion: Int) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let value = dictionary["formatVersion"] as? NSNumber,
              value.intValue > currentVersion else {
            return nil
        }
        return value.intValue
    }

    private func loadV2DefinitionsIfPresent() throws -> [UserSkill]? {
        try loadDefinitionsIfPresent(directoryName: "Definitions")
    }

    private func loadDefinitionsIfPresent(directoryName: String) throws -> [UserSkill]? {
        let directory = try definitionsDirectory(named: directoryName, create: false)
        let indexURL = directory.appendingPathComponent("index.json")
        guard fileManager.fileExists(atPath: indexURL.path) else { return nil }
        let identifiers = try decoder.decode([UUID].self, from: Data(contentsOf: indexURL))
        return try identifiers.map { identifier in
            let url = directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("json")
            return try decoder.decode(UserSkill.self, from: Data(contentsOf: url))
        }
    }

    private func persistCurrentDefinitions() throws {
        if let storageFormatRequiresNewerVersion {
            throw SkillStoreError.storageRequiresNewerVersion(storageFormatRequiresNewerVersion)
        }
        let directory = try definitionsDirectory(named: "DefinitionsV3", create: true)
        let commitIdentifier = UUID().uuidString.lowercased()
        var nextDefinitionFiles: [UUID: String] = [:]

        for skill in skills {
            if let version = requiredFutureSchemaVersion(for: skill) {
                throw SkillStoreError.unsupportedFutureSchema(version)
            }
            let encodedSkill = try encoder.encode(skill)
            if let currentFilename = definitionFilesByID[skill.id],
               isSafeDefinitionFilename(currentFilename) {
                let currentURL = directory.appendingPathComponent(currentFilename)
                if let currentData = try? Data(contentsOf: currentURL),
                   currentData == encodedSkill {
                    // A snapshot only needs a new immutable file for definitions
                    // that actually changed. Reusing identical committed files keeps
                    // the transactional model without multiplying the whole library
                    // after every small edit.
                    nextDefinitionFiles[skill.id] = currentFilename
                    continue
                }
            }
            let filename = "\(skill.id.uuidString).\(commitIdentifier).json"
            let url = directory.appendingPathComponent(filename)
            try encodedSkill.write(to: url, options: .atomic)
            nextDefinitionFiles[skill.id] = filename
        }

        let sortedDeletedIDs = deletedSkillIDs.sorted { $0.uuidString < $1.uuidString }
        let activeIDs = skills.map(\.id)
        let activeSet = Set(activeIDs)
        let protectedIDs = preservedDefinitionIDs.filter {
            !activeSet.contains($0) && !deletedSkillIDs.contains($0)
        }
        for identifier in protectedIDs {
            if let filename = definitionFilesByID[identifier], isSafeDefinitionFilename(filename) {
                nextDefinitionFiles[identifier] = filename
            }
        }
        let index = SkillDefinitionsIndex(
            orderedIDs: uniqueIdentifiers(activeIDs + protectedIDs),
            deletedIDs: sortedDeletedIDs,
            definitionFiles: nextDefinitionFiles
        )
        let nextIndexData = try encoder.encode(index)
        let indexURL = directory.appendingPathComponent("index.json")
        let backupIndexURL = directory.appendingPathComponent("index.backup.json")
        if fileManager.fileExists(atPath: indexURL.path),
           let currentData = try? Data(contentsOf: indexURL),
           (try? decoder.decode(SkillDefinitionsIndex.self, from: currentData)) != nil,
           futureStorageFormatVersion(
               in: currentData,
               currentVersion: SkillDefinitionsIndex.currentFormatVersion
           ) == nil {
            try currentData.write(to: backupIndexURL, options: .atomic)
        }

        // 每个技能先写入全新的版本文件，索引是唯一提交点且最后原子切换。
        // 提交前崩溃时，旧索引仍指向完整旧版本；未提交版本不会被当作 orphan 加载。
        try nextIndexData.write(to: indexURL, options: .atomic)
        let tombstonesURL = directory.appendingPathComponent("tombstones.json")
        let tombstones = SkillDeletionTombstones(deletedIDs: sortedDeletedIDs)
        do {
            try encoder.encode(tombstones).write(to: tombstonesURL, options: .atomic)
        } catch {
            // index.json already committed successfully. Report the degraded
            // backup protection without pretending the user's save failed.
            AppConsole.shared.warning(
                "技能已保存，但删除墓碑备份写入失败：\(error.localizedDescription)",
                category: "SkillStore"
            )
        }
        if !fileManager.fileExists(atPath: backupIndexURL.path) {
            // A brand-new store has no previous generation to back up. Once the
            // first index is committed, keep an identical readable fallback for
            // later disk corruption. Failure here does not invalidate the commit.
            try? nextIndexData.write(to: backupIndexURL, options: .atomic)
        }
        definitionFilesByID = nextDefinitionFiles
        suspendAutomaticMaintenance = false
    }

    private func definitionsDirectory(named name: String, create: Bool) throws -> URL {
        let legacyURL = try storageURL(createDirectory: create)
        let directory = legacyURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private var deletedBuiltInIdentifiers: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: deletedBuiltInsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: deletedBuiltInsKey)
        }
    }

    private func removeRetiredBuiltInSkills() {
        guard !suspendAutomaticMaintenance else { return }
        let retiredSkills = skills.filter { skill in
            skill.builtInIdentifier.map(retiredBuiltInIdentifiers.contains) == true
        }
        guard !retiredSkills.isEmpty else { return }
        let previousSkills = skills
        let previousDeletedSkillIDs = deletedSkillIDs
        let retiredIDs = Set(retiredSkills.map(\.id))
        skills.removeAll { retiredIDs.contains($0.id) }
        deletedSkillIDs.formUnion(retiredIDs)
        do {
            try persist()
            AppConsole.shared.info("已移除不再提供的内置移动文件技能", category: "SkillStore")
        } catch {
            skills = previousSkills
            deletedSkillIDs = previousDeletedSkillIDs
            AppConsole.shared.error("清理旧内置技能失败：\(error.localizedDescription)", category: "SkillStore")
        }
    }

    private func seedBuiltInSkillsIfNeeded() {
        guard !suspendAutomaticMaintenance else {
            AppConsole.shared.warning(
                "Skill V3 正处于只读恢复状态，已暂停自动写入内置技能",
                category: "SkillStore"
            )
            return
        }
        let existingIdentifiers = Set(skills.compactMap(\.builtInIdentifier))
        let deletedIdentifiers = deletedBuiltInIdentifiers
        let additions = BuiltInSkillCatalog.skills.filter { skill in
            guard let identifier = skill.builtInIdentifier else { return false }
            return !existingIdentifiers.contains(identifier)
                && !deletedIdentifiers.contains(identifier)
                && !deletedSkillIDs.contains(skill.id)
                && !preservedDefinitionIDs.contains(skill.id)
                && !futureDefinitionIDs.contains(skill.id)
        }
        guard !additions.isEmpty else { return }

        let previousSkills = skills
        let previousDeletedSkillIDs = deletedSkillIDs
        skills.append(contentsOf: additions)
        deletedSkillIDs.subtract(additions.map(\.id))
        do {
            try persist()
            AppConsole.shared.success(
                "已安装 \(additions.count) 个可编辑的内置技能",
                category: "SkillStore"
            )
        } catch {
            skills = previousSkills
            deletedSkillIDs = previousDeletedSkillIDs
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
            executionMode: .local,
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
            executionMode: .local,
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
            executionMode: .hybrid,
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
            executionMode: .hybrid,
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
            executionMode: .local,
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
            executionMode: .hybrid,
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
            executionMode: .local,
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
            executionMode: .local,
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
            executionMode: .local,
            parameters: [
                parameter("file", "文件", .file, "要重命名的文件"),
                parameter("new_name", "新名称", .text, "包含扩展名的新文件名")
            ],
            workflow: [step("rename", "file.rename", ["path": .string("{{文件}}"), "newName": .string("{{新名称}}")], saveAs: "newPath")]
        ),
        make(
            number: 16,
            identifier: "builtin.file.create-empty",
            name: "新建空文件",
            keyword: "new",
            aliases: ["新建文件", "create file"],
            summary: "按给定的完整文件名在下载目录创建一个空文件。",
            actions: ["接收带后缀的文件名", "在下载目录创建空文件", "显示可拖拽的文件卡片"],
            output: "显示新文件，可拖动、双击打开或移到废纸篓",
            requiredTools: ["file.createEmpty"],
            permissions: ["downloads_write"],
            executionMode: .local,
            parameters: [parameter("name", "名称.后缀", .text, "例如 1.txt、notes.md 或 script.py")],
            workflow: [step("create", "file.createEmpty", ["name": .string("{{名称.后缀}}")], saveAs: "createdFile")]
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
            executionMode: .local,
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
            executionMode: .hybrid,
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
            executionMode: .hybrid,
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
