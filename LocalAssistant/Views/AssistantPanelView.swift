import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AssistantPanelView: View {
    @AppStorage("recentSkillIDs") private var recentSkillIDs = "ocr,summarize,files,rewrite"
    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var aiSettings = AISettingsStore.shared
    @FocusState private var searchIsFocused: Bool

    @State private var prompt = ""
    @State private var submittedPrompt = ""
    @State private var response: DemoResponse?
    @State private var isThinking = false
    @State private var copied = false
    @State private var requestID = UUID()
    @State private var activeTask: Task<Void, Never>?
    @State private var selectedSuggestionIndex = 0
    @State private var pendingSkill: UserSkill?
    @State private var parameterValues: [String: String] = [:]
    @State private var parameterFiles: [String: [URL]] = [:]
    @State private var tabCompletion: PanelTabCompletion?

    var body: some View {
        panelContent
            .background(panelBackground)
            .clipShape(panelShape)
            .overlay {
                panelShape
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            }
            .overlay(alignment: .top) {
                PanelDragRegion()
                    .frame(height: 17)
                    .padding(.horizontal, 52)
            }
            .padding(14)
            .frame(minWidth: 720, minHeight: 450)
            .onAppear {
                DispatchQueue.main.async {
                    searchIsFocused = true
                }
            }
            .onChange(of: prompt) { oldValue, newValue in
                handlePromptChange(from: oldValue, to: newValue)
            }
            .onDisappear {
                PanelController.shared.setInteractionPinned(false)
            }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
    }

    private var panelBackground: some View {
        ZStack {
            panelShape
                .fill(.ultraThickMaterial)

            panelShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.indigo.opacity(0.075),
                            Color.clear,
                            Color.cyan.opacity(0.035)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            searchArea

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
    }

    private var searchArea: some View {
        searchControls
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 13)
    }

    @ViewBuilder
    private var searchControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    searchFieldContent
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        )

                    Button {
                        executeCurrentInput()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(.indigo)
                    .disabled(!canExecuteCurrentState)
                    .help("发送")
                }
            }
        } else {
            HStack(spacing: 12) {
                searchFieldContent
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                    }

                Button {
                    executeCurrentInput()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.indigo)
                .disabled(!canExecuteCurrentState)
                .help("发送")
            }
        }
    }

    private var searchFieldContent: some View {
        HStack(spacing: 12) {
            Image(systemName: isThinking ? "sparkles" : "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isThinking ? Color.indigo : Color.secondary)
                .symbolEffect(.pulse, isActive: isThinking)
                .frame(width: 24)

            ZStack(alignment: .leading) {
                if let inlineCompletion {
                    HStack(spacing: 0) {
                        Text(prompt)
                            .foregroundStyle(.clear)
                        Text(inlineCompletion.commandSuffix)
                            .foregroundStyle(.tertiary)
                        if let parameterHint = inlineCompletion.parameterHint {
                            Text(" \(parameterHint)")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .font(.system(size: 19, weight: .regular))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                }

                TextField("搜索、执行，或者问任何问题…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .regular))
                    .focused($searchIsFocused)
                    .onSubmit {
                        executeCurrentInput()
                    }
                    .onKeyPress(.tab) {
                        selectNextSuggestionWithTab() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        cycleSuggestion(by: 1) ? .handled : .ignored
                    }
                    .onKeyPress(.upArrow) {
                        cycleSuggestion(by: -1) ? .handled : .ignored
                    }
            }

            if let attachedFile = firstAttachedFile {
                HStack(spacing: 5) {
                    Image(systemName: attachedFile.url.hasDirectoryPath ? "folder.fill" : "doc.fill")
                        .foregroundStyle(Color.indigo)
                    Text(attachedFile.url.lastPathComponent)
                        .lineLimit(1)
                        .frame(maxWidth: 100)
                    Button {
                        parameterFiles[attachedFile.parameter.id] = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 10.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.055), in: Capsule())
            }

            if let fileParameter = nextUnfilledFileParameter {
                Menu {
                    Button("选择\(fileParameter.type.displayName)…") {
                        chooseFiles(for: fileParameter)
                    }
                    Button("从剪贴板粘贴") {
                        pasteFiles(for: fileParameter)
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("添加\(fileParameter.type.displayName)")
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(aiSettings.isConfigured() ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(aiSettings.isConfigured() ? aiSettings.selectedProvider.shortName : "本地")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.055), in: Capsule())

            if !prompt.isEmpty {
                Button {
                    if pendingSkill != nil {
                        cancelParameterEntry(clearPrompt: true)
                    } else {
                        prompt = ""
                    }
                    searchIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            searchIsFocused = true
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let fileParameter = nextUnfilledFileParameter else { return false }
            addFiles(urls, to: fileParameter)
            return !urls.isEmpty
        }
    }

    @ViewBuilder
    private var content: some View {
        if isThinking {
            thinkingView
                .transition(.opacity)
        } else if let response {
            responseView(response)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let pendingSkill {
            parameterGuidanceView(for: pendingSkill)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            recommendations
                .transition(.opacity)
        }
    }

    private func parameterGuidanceView(for skill: UserSkill) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("所有参数都在上方命令框中输入")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Image(systemName: nextUnfilledFileParameter == nil ? "text.cursor" : "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.indigo)
                    .frame(width: 34, height: 34)
                    .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(nextInlineParameterHint.map { "下一项：\($0)" } ?? "参数已经齐全")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(parameterGuidanceDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            Text(skill.executionExample)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(isPredicting ? "预测补全" : "最近与推荐")
                    .font(.system(size: 13.5, weight: .semibold))

                Text(isPredicting ? "根据命令名、别名与描述实时匹配" : "会随你的使用习惯调整")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(isPredicting ? "Tab 切换 · ↩ 执行" : "选择一项立即开始")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            if totalVisibleCount == 0 {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("没有匹配到明确工具")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("按回车后会作为普通问题继续处理")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 66)
                .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            } else {
                VStack(spacing: 2) {
                    ForEach(visibleUserSkills.indices, id: \.self) { index in
                        let skill = visibleUserSkills[index]
                        UserSkillSuggestionRow(
                            skill: skill,
                            badge: isPredicting ? "我的技能" : (index == 0 ? "最近创建" : "我的技能"),
                            isBestMatch: isPredicting && selectedSuggestionIndex == index
                        ) {
                            run(skill)
                        }
                    }

                    ForEach(displayedBuiltInSkills.indices, id: \.self) { index in
                        let skill = displayedBuiltInSkills[index]
                        SkillSuggestionRow(
                            skill: skill,
                            badge: isPredicting ? skill.commandName : (visibleUserSkills.isEmpty && index == 0 ? "最近使用" : "推荐"),
                            isBestMatch: isPredicting && selectedSuggestionIndex == visibleUserSkills.count + index
                        ) {
                            run(skill)
                        }
                    }
                }
                .padding(5)
                .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.7)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    private var thinkingView: some View {
        VStack(spacing: 13) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.10))
                    .frame(width: 42, height: 42)

                Image(systemName: "sparkles")
                    .foregroundStyle(Color.indigo)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            Text("正在理解你的请求")
                .font(.system(size: 13.5, weight: .semibold))

            Text(aiSettings.isConfigured() ? "正在调用 \(aiSettings.selectedProvider.displayName)…" : "正在匹配本地命令与技能…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func responseView(_ response: DemoResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: response.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(response.tint)
                        .frame(width: 28, height: 28)
                        .background(response.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(response.title)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(response.skillName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(response.badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.indigo.opacity(0.09), in: Capsule())
                }

                Text(submittedPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                MarkdownContentView(
                    markdown: response.body,
                    baseFontSize: 13.5,
                    blockSpacing: 10
                )
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button {
                        copy(response.body)
                    } label: {
                        Label(copied ? "已复制" : "复制结果", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button("新问题") {
                        resetConversation()
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("Local Assistant", systemImage: "sparkles")

            Button {
                SkillCreatorWindowController.shared.show()
            } label: {
                Label("创建技能", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            KeyHint(keys: "↩", label: "执行")
            KeyHint(keys: "tab", label: "切换")
            KeyHint(keys: "esc", label: "关闭")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 20)
        .frame(height: 38)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canExecuteCurrentState: Bool {
        if pendingSkill != nil {
            return missingRequiredParameters.isEmpty
        }
        return !trimmedPrompt.isEmpty
    }

    private var missingRequiredParameters: [String] {
        guard let pendingSkill else { return [] }
        return pendingSkill.resolvedParameters.compactMap { parameter in
            guard parameter.required else { return nil }
            if parameter.type.acceptsFiles {
                return (parameterFiles[parameter.id]?.isEmpty == false) ? nil : parameter.name
            }
            return parameterValues[parameter.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? nil
                : parameter.name
        }
    }

    private var nextUnfilledFileParameter: SkillParameterDefinition? {
        pendingSkill?.resolvedParameters.first { parameter in
            parameter.type.acceptsFiles && parameterFiles[parameter.id]?.isEmpty != false
        }
    }

    private var firstAttachedFile: (parameter: SkillParameterDefinition, url: URL)? {
        guard let pendingSkill else { return nil }
        for parameter in pendingSkill.resolvedParameters where parameter.type.acceptsFiles {
            if let url = parameterFiles[parameter.id]?.first {
                return (parameter, url)
            }
        }
        return nil
    }

    private var nextInlineParameterHint: String? {
        guard let pendingSkill else { return nil }
        if let fileParameter = nextUnfilledFileParameter {
            return fileParameter.name
        }

        let valueParameters = pendingSkill.resolvedParameters.filter { !$0.type.acceptsFiles }
        guard !valueParameters.isEmpty else { return nil }
        let remainder = commandRemainder(for: pendingSkill, input: prompt)
        if remainder.isEmpty { return valueParameters.first?.name }
        guard prompt.last?.isWhitespace == true else { return nil }
        let completedCount = splitCommandArguments(remainder).count
        guard valueParameters.indices.contains(completedCount) else { return nil }
        return valueParameters[completedCount].name
    }

    private var parameterGuidanceDetail: String {
        if let fileParameter = nextUnfilledFileParameter {
            return "从上方回形针选择，或把\(fileParameter.type.displayName)拖入上方输入框"
        }
        if let nextInlineParameterHint {
            return "继续在上方输入“\(nextInlineParameterHint)”"
        }
        return missingRequiredParameters.isEmpty ? "按回车立即执行" : "还需：\(missingRequiredParameters.joined(separator: "、"))"
    }

    private var recommendedSkills: [FeatureItem] {
        let ids = recentSkillIDs.split(separator: ",").map(String.init)
        let ordered = ids.compactMap { id in
            FeatureItem.all.first(where: { $0.id == id })
        }
        let remaining = FeatureItem.all.filter { feature in
            !ordered.contains(where: { $0.id == feature.id })
        }
        return Array((ordered + remaining).prefix(4))
    }

    private var isPredicting: Bool {
        !trimmedPrompt.isEmpty
    }

    private var visibleSkills: [FeatureItem] {
        isPredicting ? predictedSkills(for: trimmedPrompt) : recommendedSkills
    }

    private var visibleUserSkills: [UserSkill] {
        if isPredicting {
            return Array(predictedUserSkills(for: trimmedPrompt).prefix(3))
        }
        return Array(skillStore.skills.filter(\.isEnabled).prefix(1))
    }

    private var displayedBuiltInSkills: [FeatureItem] {
        Array(visibleSkills.prefix(max(0, 4 - visibleUserSkills.count)))
    }

    private var totalVisibleCount: Int {
        visibleUserSkills.count + displayedBuiltInSkills.count
    }

    private var visibleSuggestionTargets: [PanelSuggestionTarget] {
        visibleUserSkills.map(PanelSuggestionTarget.userSkill)
            + displayedBuiltInSkills.map(PanelSuggestionTarget.builtIn)
    }

    private var selectedSuggestion: PanelSuggestionTarget? {
        guard isPredicting, !visibleSuggestionTargets.isEmpty else { return nil }
        return visibleSuggestionTargets[min(selectedSuggestionIndex, visibleSuggestionTargets.count - 1)]
    }

    private var inlineCompletion: PanelInlineCompletion? {
        if pendingSkill != nil, let nextInlineParameterHint {
            return PanelInlineCompletion(commandSuffix: "", parameterHint: nextInlineParameterHint)
        }

        if let tabCompletion, tabCompletion.sourcePrompt == prompt {
            let suffix = commandSuffix(command: tabCompletion.command, query: tabCompletion.sourcePrompt) ?? ""
            return PanelInlineCompletion(
                commandSuffix: suffix,
                parameterHint: tabCompletion.parameterHint
            )
        }

        guard let selectedSuggestion,
              let command = preferredCommand(for: selectedSuggestion, query: trimmedPrompt),
              normalized(command) != normalized(trimmedPrompt),
              let suffix = commandSuffix(command: command, query: trimmedPrompt) else {
            return nil
        }
        return PanelInlineCompletion(commandSuffix: suffix, parameterHint: nil)
    }

    private func preferredCommand(
        for suggestion: PanelSuggestionTarget,
        query: String
    ) -> String? {
        guard !query.isEmpty, !query.contains(where: \.isWhitespace) else { return nil }

        let terms: [String]
        switch suggestion {
        case .userSkill(let skill):
            terms = [skill.registeredKeyword].compactMap { $0 } + skill.aliases + [skill.name]
        case .builtIn(let skill):
            terms = [skill.commandName, skill.id] + skill.searchTerms
        }

        let normalizedQuery = normalized(query)
        return terms
            .filter({ normalized($0).hasPrefix(normalizedQuery) })
            .sorted(by: { $0.count < $1.count })
            .first
    }

    private func commandSuffix(command: String, query: String) -> String? {
        guard command.count >= query.count else { return nil }
        let suffixStart = command.index(command.startIndex, offsetBy: query.count)
        return String(command[suffixStart...])
    }

    @discardableResult
    private func cycleSuggestion(by offset: Int) -> Bool {
        let count = visibleSuggestionTargets.count
        guard isPredicting, count > 0 else { return false }
        tabCompletion = nil
        selectedSuggestionIndex = (selectedSuggestionIndex + offset + count) % count
        return true
    }

    @discardableResult
    private func selectNextSuggestionWithTab() -> Bool {
        guard cycleSuggestion(by: 1),
              let selectedSuggestion,
              let command = preferredCommand(for: selectedSuggestion, query: trimmedPrompt) else {
            return false
        }

        let parameterHint: String?
        switch selectedSuggestion {
        case .userSkill(let skill):
            parameterHint = skill.resolvedParameters.first?.name
        case .builtIn(let skill):
            let parts = skill.executionExample.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            parameterHint = parts.count > 1 ? String(parts[1]) : nil
        }

        tabCompletion = PanelTabCompletion(
            sourcePrompt: prompt,
            command: command,
            parameterHint: parameterHint,
            target: selectedSuggestion
        )
        AppConsole.shared.info(
            "Tab 已预选命令：\(command)；下一参数=\(parameterHint ?? "无")",
            category: "Assistant"
        )
        return true
    }

    private func handlePromptChange(from oldValue: String, to newValue: String) {
        defer { selectedSuggestionIndex = 0 }

        if let pendingSkill {
            tabCompletion = nil
            guard commandMatches(skill: pendingSkill, input: newValue) else {
                cancelParameterEntry(clearPrompt: false)
                return
            }
            refreshInlineArguments(for: pendingSkill, input: newValue)
            return
        }

        if let tabCompletion,
           oldValue == tabCompletion.sourcePrompt,
           newValue.hasPrefix(oldValue),
           newValue.count > oldValue.count {
            let enteredStart = newValue.index(newValue.startIndex, offsetBy: oldValue.count)
            let enteredText = String(newValue[enteredStart...].drop(while: \.isWhitespace))
            acceptCommand(tabCompletion.target, command: tabCompletion.command, enteredText: enteredText)
            return
        }

        tabCompletion = nil
        let oldQuery = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldQuery.isEmpty,
              !oldQuery.contains(where: \.isWhitespace),
              newValue.hasPrefix(oldValue),
              newValue.count > oldValue.count else {
            return
        }
        let appendedStart = newValue.index(newValue.startIndex, offsetBy: oldValue.count)
        let appended = newValue[appendedStart...]
        guard appended.allSatisfy(\.isWhitespace),
              let suggestion = suggestionTarget(for: oldQuery, index: selectedSuggestionIndex),
              let command = preferredCommand(for: suggestion, query: oldQuery) else {
            return
        }
        acceptCommand(suggestion, command: command, enteredText: "")
    }

    private func suggestionTarget(for query: String, index: Int) -> PanelSuggestionTarget? {
        let userSkills = Array(predictedUserSkills(for: query).prefix(3))
        let builtIns = Array(predictedSkills(for: query).prefix(max(0, 4 - userSkills.count)))
        let targets = userSkills.map(PanelSuggestionTarget.userSkill)
            + builtIns.map(PanelSuggestionTarget.builtIn)
        guard !targets.isEmpty else { return nil }
        return targets[min(index, targets.count - 1)]
    }

    private func acceptCommand(
        _ target: PanelSuggestionTarget,
        command: String,
        enteredText: String
    ) {
        tabCompletion = nil
        let rewrittenInput = command + " " + enteredText
        AppConsole.shared.info(
            "已锁定命令：\(command)；后续内容在顶部输入线作为参数接收",
            category: "Assistant"
        )
        switch target {
        case .userSkill(let skill):
            if skill.resolvedParameters.isEmpty {
                prompt = command
            } else {
                beginParameterEntry(for: skill, input: rewrittenInput)
                prompt = rewrittenInput
            }
        case .builtIn:
            prompt = rewrittenInput
        }
        searchIsFocused = true
    }

    private func commandMatches(skill: UserSkill, input: String) -> Bool {
        guard let command = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) else {
            return false
        }
        return commandTerms(for: skill).contains { normalized($0) == normalized(command) }
    }

    private func refreshInlineArguments(for skill: UserSkill, input: String) {
        parameterValues = [:]
        applyInlineArguments(commandRemainder(for: skill, input: input), to: skill.resolvedParameters)
    }

    private func predictedSkills(for rawQuery: String) -> [FeatureItem] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullQuery = normalized(trimmed)
        let commandQuery = trimmed.split(whereSeparator: \.isWhitespace).first.map { normalized(String($0)) } ?? fullQuery
        let query = trimmed.contains(where: \.isWhitespace) ? commandQuery : fullQuery
        guard !query.isEmpty else { return recommendedSkills }

        let matches = FeatureItem.all.compactMap { skill -> (skill: FeatureItem, score: Int)? in
            let scores = skill.searchTerms.compactMap { term -> Int? in
                let candidate = normalized(term)

                if candidate == query {
                    return 0
                }
                if candidate.hasPrefix(query) {
                    return 10 + candidate.count - query.count
                }
                if query.count >= 2, let range = candidate.range(of: query) {
                    return 100 + candidate.distance(from: candidate.startIndex, to: range.lowerBound)
                }
                return nil
            }

            guard let bestScore = scores.min() else { return nil }
            return (skill, bestScore)
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.skill.title < rhs.skill.title
            }
            .prefix(4)
            .map(\.skill)
    }

    private func predictedUserSkills(for rawQuery: String) -> [UserSkill] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullQuery = normalized(trimmed)
        let commandQuery = trimmed.split(whereSeparator: \.isWhitespace).first.map { normalized(String($0)) } ?? fullQuery
        let query = trimmed.contains(where: \.isWhitespace) ? commandQuery : fullQuery
        guard !query.isEmpty else { return skillStore.skills.filter(\.isEnabled) }

        return skillStore.skills
            .filter(\.isEnabled)
            .compactMap { skill -> (skill: UserSkill, score: Int)? in
                let scores = skill.searchTerms.compactMap { term -> Int? in
                    let candidate = normalized(term)
                    if candidate == query { return 0 }
                    if candidate.hasPrefix(query) { return 10 + candidate.count - query.count }
                    if query.count >= 2, let range = candidate.range(of: query) {
                        return 100 + candidate.distance(from: candidate.startIndex, to: range.lowerBound)
                    }
                    return nil
                }
                guard let score = scores.min() else { return nil }
                return (skill, score)
            }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.skill.name < rhs.skill.name : lhs.score < rhs.score
            }
            .map(\.skill)
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func executeCurrentInput() {
        if pendingSkill != nil {
            executePendingSkill()
            return
        }
        guard !trimmedPrompt.isEmpty else { return }

        if let selectedSuggestion {
            switch selectedSuggestion {
            case .userSkill(let userSkill):
                AppConsole.shared.info("输入已匹配用户技能：\(userSkill.name)", category: "Assistant")
                run(userSkill)
            case .builtIn(let builtIn):
                AppConsole.shared.info("输入已匹配内置技能：\(builtIn.id)", category: "Assistant")
                run(builtIn)
            }
            return
        }

        if let userSkill = predictedUserSkills(for: trimmedPrompt).first {
            AppConsole.shared.info("输入已匹配用户技能：\(userSkill.name)", category: "Assistant")
            run(userSkill)
            return
        }
        let preferredSkill = predictedSkills(for: trimmedPrompt).first
        submit(prompt, preferredSkill: preferredSkill)
    }

    private func run(_ skill: FeatureItem) {
        prompt = skill.samplePrompt
        submit(skill.samplePrompt, preferredSkill: skill)
    }

    private func run(_ skill: UserSkill) {
        let input = trimmedPrompt.isEmpty ? skill.name : trimmedPrompt
        prompt = input
        guard !skill.resolvedParameters.isEmpty else {
            submit(skill, input: input, values: [:], files: [:])
            return
        }
        let hasInlineArguments = !commandRemainder(for: skill, input: input).isEmpty
        beginParameterEntry(for: skill, input: input)
        if hasInlineArguments, missingRequiredParameters.isEmpty {
            AppConsole.shared.info(
                "技能“\(skill.name)”已从命令行收齐参数，跳过二次确认",
                category: "Assistant"
            )
            executePendingSkill()
        }
    }

    private func beginParameterEntry(for skill: UserSkill, input: String) {
        pendingSkill = skill
        response = nil
        parameterFiles = [:]
        refreshInlineArguments(for: skill, input: input)
        let acceptsFiles = skill.resolvedParameters.contains(where: { $0.type.acceptsFiles })
        PanelController.shared.setInteractionPinned(acceptsFiles)
        searchIsFocused = true
        AppConsole.shared.info(
            "技能“\(skill.name)”进入单行参数输入；参数数=\(skill.resolvedParameters.count)，文件参数=\(acceptsFiles ? "是" : "否")",
            category: "Assistant"
        )
    }

    private func executePendingSkill() {
        guard let skill = pendingSkill, missingRequiredParameters.isEmpty else { return }
        let input = trimmedPrompt.isEmpty ? skill.name : trimmedPrompt
        let values = parameterValues
        let files = parameterFiles
        cancelParameterEntry(clearPrompt: false)
        submit(skill, input: input, values: values, files: files)
    }

    private func cancelParameterEntry(clearPrompt: Bool) {
        pendingSkill = nil
        tabCompletion = nil
        parameterValues = [:]
        parameterFiles = [:]
        PanelController.shared.setInteractionPinned(false)
        if clearPrompt { prompt = "" }
    }

    private func commandRemainder(for skill: UserSkill, input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = commandTerms(for: skill).sorted { $0.count > $1.count }
        guard let term = terms.first(where: { candidate in
            let normalizedInput = normalized(trimmed)
            let normalizedCandidate = normalized(candidate)
            return normalizedInput == normalizedCandidate
                || normalizedInput.hasPrefix(normalizedCandidate + " ")
        }) else { return "" }
        let index = trimmed.index(trimmed.startIndex, offsetBy: min(term.count, trimmed.count))
        return String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commandTerms(for skill: UserSkill) -> [String] {
        [skill.registeredKeyword].compactMap { $0 } + skill.aliases + [skill.name]
    }

    private func applyInlineArguments(_ rawValue: String, to parameters: [SkillParameterDefinition]) {
        guard !rawValue.isEmpty else { return }
        let valueParameters = parameters.filter { !$0.type.acceptsFiles }
        let fileParameters = parameters.filter(\.type.acceptsFiles)

        if valueParameters.count == 1, let parameter = valueParameters.first {
            parameterValues[parameter.id] = rawValue
        } else {
            let values = splitCommandArguments(rawValue)
            for (parameter, value) in zip(valueParameters, values) {
                parameterValues[parameter.id] = value
            }
        }

        let possiblePath = (rawValue as NSString).expandingTildeInPath
        if let fileParameter = fileParameters.first,
           FileManager.default.fileExists(atPath: possiblePath) {
            addFiles([URL(fileURLWithPath: possiblePath)], to: fileParameter)
        }
    }

    private func splitCommandArguments(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in value {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { current.append(character) }
            } else if character.isWhitespace && quote == nil {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func chooseFiles(for parameter: SkillParameterDefinition) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = parameter.type == .folder
        openPanel.canChooseFiles = parameter.type != .folder
        if parameter.type == .image {
            openPanel.allowedContentTypes = [.image]
        }
        openPanel.prompt = "选择"
        openPanel.message = "为“\(parameter.name)”选择\(parameter.type.displayName)"
        openPanel.begin { response in
            guard response == .OK else { return }
            addFiles(openPanel.urls, to: parameter)
        }
    }

    private func pasteFiles(for parameter: SkillParameterDefinition) {
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let fileURLs = objects.filter(\.isFileURL)
        guard !fileURLs.isEmpty else {
            AppConsole.shared.warning("剪贴板中没有可粘贴的文件", category: "Assistant")
            return
        }
        addFiles(fileURLs, to: parameter)
    }

    private func addFiles(_ urls: [URL], to parameter: SkillParameterDefinition) {
        guard let url = urls.first(where: { accepts($0, for: parameter.type) }) else {
            AppConsole.shared.warning("传入内容与参数“\(parameter.name)”的类型不匹配", category: "Assistant")
            return
        }
        parameterFiles[parameter.id] = [url]
        AppConsole.shared.info("参数“\(parameter.name)”已接收：\(url.lastPathComponent)", category: "Assistant")
    }

    private func accepts(_ url: URL, for type: SkillParameterType) -> Bool {
        guard url.isFileURL else { return false }
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if type == .folder { return resourceValues?.isDirectory == true }
        if resourceValues?.isDirectory == true { return false }
        if type == .image {
            guard let contentType = UTType(filenameExtension: url.pathExtension) else { return false }
            return contentType.conforms(to: .image)
        }
        return type == .file
    }

    private func submit(_ rawPrompt: String, preferredSkill: FeatureItem? = nil) {
        let trimmed = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let currentRequestID = UUID()
        activeTask?.cancel()
        requestID = currentRequestID
        submittedPrompt = trimmed
        copied = false
        AppConsole.shared.info(
            "开始处理面板请求；字符数=\(trimmed.count)，指定内置技能=\(preferredSkill?.id ?? "无")",
            category: "Assistant"
        )

        withAnimation(.easeOut(duration: 0.16)) {
            response = nil
            isThinking = true
        }

        let matchedSkill = preferredSkill ?? detectSkill(in: trimmed)
        if let matchedSkill {
            remember(matchedSkill)
            AppConsole.shared.info("已匹配内置技能：\(matchedSkill.id)", category: "Assistant")
        }

        if let matchedSkill {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                finish(makeResponse(skill: matchedSkill), requestID: currentRequestID)
            }
            return
        }

        guard aiSettings.isConfigured() else {
            AppConsole.shared.warning("没有匹配本地命令，且尚未配置 AI 服务", category: "Assistant")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                finish(
                    DemoResponse(
                        title: "需要配置 AI 服务",
                        body: "我没有匹配到明确的本地命令。请从菜单栏打开“设置 → AI 服务”，保存 DeepSeek、GLM、Gemini 或 OpenAI 的 API Key；之后这里会直接显示真实回答。",
                        skillName: "自由问答尚未连接",
                        icon: "key.horizontal",
                        tint: .orange,
                        badge: "需要设置"
                    ),
                    requestID: currentRequestID
                )
            }
            return
        }

        activeTask = Task {
            do {
                let answer = try await AIService.shared.generateText(
                    prompt: trimmed,
                    system: """
                    你是一个运行在 macOS 快捷面板中的个人助手。直接、简洁地回答用户，不要声称执行了任何尚未调用的系统工具。
                    使用清晰、克制的 Markdown 输出：仅在有助于理解时使用标题或列表；代码必须放在带语言名称的围栏代码块中；不要用代码块包裹整篇回答；不要输出 HTML。
                    """,
                    maxTokens: 700
                )
                guard !Task.isCancelled else { return }
                finish(
                    DemoResponse(
                        title: "问答结果",
                        body: answer,
                        skillName: "由 \(aiSettings.selectedProvider.displayName) 回答",
                        icon: "bubble.left.and.text.bubble.right",
                        tint: .indigo,
                        badge: aiSettings.selectedProvider.shortName
                    ),
                    requestID: currentRequestID
                )
            } catch {
                guard !Task.isCancelled else { return }
                AppConsole.shared.error("自由问答失败：\(error.localizedDescription)", category: "Assistant")
                finish(errorResponse(error), requestID: currentRequestID)
            }
        }
    }

    private func submit(
        _ skill: UserSkill,
        input: String,
        values: [String: String],
        files: [String: [URL]]
    ) {
        let currentRequestID = UUID()
        activeTask?.cancel()
        requestID = currentRequestID
        submittedPrompt = input
        copied = false
        AppConsole.shared.info(
            "开始执行用户技能：\(skill.name)；输入字符数=\(input.count)，文本参数=\(values.count)，文件参数=\(files.values.flatMap { $0 }.count)",
            category: "Assistant"
        )

        let runtimeParameterSummary = skill.resolvedParameters.compactMap { parameter -> String? in
            if parameter.type.acceptsFiles {
                guard let url = files[parameter.id]?.first else { return nil }
                return "\(parameter.name)：\(url.lastPathComponent)"
            }
            guard let value = values[parameter.id], !value.isEmpty else { return nil }
            return "\(parameter.name)：\(value)"
        }.joined(separator: "\n")

        withAnimation(.easeOut(duration: 0.16)) {
            response = nil
            isThinking = true
        }

        if files.values.contains(where: { !$0.isEmpty }) {
            AppConsole.shared.warning(
                "技能“\(skill.name)”已接收文件参数，但当前统一模型执行器尚未发送多模态内容",
                category: "Assistant"
            )
            finish(
                DemoResponse(
                    title: skill.name,
                    body: "文件参数已经成功传入：\n\(runtimeParameterSummary)\n\n当前统一模型接口仍是纯文本通道，所以不会把文件路径假装成文件内容发给模型。接入 Gemini 等模型的多模态请求格式，或先由 OCR / 文件读取工具产出文本后，这份技能定义可以直接继续执行。",
                    skillName: "我的技能 · 参数已接收",
                    icon: "paperclip",
                    tint: .orange,
                    badge: "等待多模态执行器"
                ),
                requestID: currentRequestID
            )
            return
        }

        switch WorkflowEngine.shared.readiness(for: skill) {
        case .unavailable(let unavailableTools):
            AppConsole.shared.warning(
                "用户技能“\(skill.name)”缺少执行能力：\(unavailableTools.joined(separator: "、"))",
                category: "Assistant"
            )
            let steps = skill.actions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let missing = unavailableTools.joined(separator: "、")
            finish(
                DemoResponse(
                    title: skill.name,
                    body: "这项技能已经保存并成功匹配，但还不能完整执行。\n\n计划：\n\(steps)\n\n还需要接入：\(missing)\n\n完成对应系统工具后，不需要重新创建技能，它会直接使用现有定义运行。",
                    skillName: "我的技能 · \(skill.generatedBy)",
                    icon: "bolt.fill",
                    tint: .purple,
                    badge: "等待工具"
                ),
                requestID: currentRequestID
            )

        case .ready:
            activeTask = Task {
                do {
                    let result = try await WorkflowEngine.shared.execute(
                        skill: skill,
                        input: input,
                        values: values,
                        files: files
                    )
                    guard !Task.isCancelled else { return }
                    copied = result.didWriteClipboard
                    let sourceName = skill.resolvedExecutionMode == .localOnly
                        ? "我的技能 · 本地执行"
                        : "我的技能 · \(skill.generatedBy)"
                    finish(
                        DemoResponse(
                            title: skill.name,
                            body: result.outputText,
                            skillName: sourceName,
                            icon: result.didWriteClipboard ? "doc.on.clipboard.fill" : "bolt.fill",
                            tint: result.didWriteClipboard ? .green : .purple,
                            badge: result.didWriteClipboard ? "已复制" : aiSettings.selectedProvider.shortName
                        ),
                        requestID: currentRequestID
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    AppConsole.shared.error("用户技能“\(skill.name)”执行失败：\(error.localizedDescription)", category: "Assistant")
                    finish(errorResponse(error), requestID: currentRequestID)
                }
            }
        }
    }

    private func detectSkill(in text: String) -> FeatureItem? {
        let value = text.lowercased()
        let mapping: [(String, [String])] = [
            ("ocr", ["ocr", "识别", "截图", "图片文字"]),
            ("summarize", ["总结", "摘要", "提炼"]),
            ("files", ["文件", "pdf", "找到", "查找", "下载"]),
            ("rewrite", ["改写", "润色", "自然", "语气"]),
            ("translate", ["翻译", "英文", "中文"]),
            ("clipboard", ["剪贴板", "复制过", "刚才复制"]),
            ("diagnose", ["卡", "变慢", "异常", "没反应"])
        ]

        guard let matchedID = mapping.first(where: { pair in
            pair.1.contains(where: value.contains)
        })?.0 else {
            return nil
        }

        return FeatureItem.all.first(where: { $0.id == matchedID })
    }

    private func makeResponse(skill: FeatureItem?) -> DemoResponse {
        if let skill {
            return DemoResponse(
                title: skill.title,
                body: skill.demoResponse,
                skillName: "已匹配 · \(skill.title)",
                icon: skill.icon,
                tint: skill.tint,
                badge: "功能雏形"
            )
        }

        return DemoResponse(
            title: "本地问答",
            body: "这是当前问答界面的演示回答。接入本地模型后，我会先理解你的意图，再选择合适的安全工具；普通问题则会直接在这里给出简短回答。",
            skillName: "自由问答",
            icon: "bubble.left.and.text.bubble.right",
            tint: .indigo,
            badge: "本地"
        )
    }

    private func finish(_ newResponse: DemoResponse, requestID expectedID: UUID) {
        guard requestID == expectedID else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            isThinking = false
            response = newResponse
        }
        AppConsole.shared.success(
            "面板请求完成；结果=\(newResponse.title)，字符数=\(newResponse.body.count)",
            category: "Assistant"
        )
    }

    private func errorResponse(_ error: Error) -> DemoResponse {
        let isToolError = error is ToolExecutionError
        return DemoResponse(
            title: "请求没有完成",
            body: error.localizedDescription,
            skillName: isToolError ? "本地工作流" : aiSettings.selectedProvider.displayName,
            icon: "exclamationmark.triangle.fill",
            tint: .red,
            badge: isToolError ? "执行错误" : "连接错误"
        )
    }

    private func remember(_ skill: FeatureItem) {
        var ids = recentSkillIDs.split(separator: ",").map(String.init)
        ids.removeAll(where: { $0 == skill.id })
        ids.insert(skill.id, at: 0)
        recentSkillIDs = ids.prefix(7).joined(separator: ",")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        AppConsole.shared.info("结果已复制到剪贴板；字符数=\(text.count)", category: "Assistant")
    }

    private func resetConversation() {
        activeTask?.cancel()
        activeTask = nil
        cancelParameterEntry(clearPrompt: false)
        requestID = UUID()
        prompt = ""
        submittedPrompt = ""
        response = nil
        isThinking = false
        copied = false
        searchIsFocused = true
        AppConsole.shared.info("已新建面板会话", category: "Assistant")
    }
}

private enum PanelSuggestionTarget {
    case userSkill(UserSkill)
    case builtIn(FeatureItem)
}

private struct PanelTabCompletion {
    let sourcePrompt: String
    let command: String
    let parameterHint: String?
    let target: PanelSuggestionTarget
}

private struct PanelInlineCompletion {
    let commandSuffix: String
    let parameterHint: String?
}

private struct PanelDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PanelDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PanelDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

private struct SkillSuggestionRow: View {
    let skill: FeatureItem
    let badge: String
    let isBestMatch: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: skill.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(skill.tint)
                    .frame(width: 32, height: 32)
                    .background(skill.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(skill.executionExample)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(badge)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            .background(
                (isHovering || isBestMatch) ? Color.primary.opacity(0.065) : Color.clear,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct UserSkillSuggestionRow: View {
    let skill: UserSkill
    let badge: String
    let isBestMatch: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.purple)
                    .frame(width: 32, height: 32)
                    .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(skill.executionExample)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(badge)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            .background(
                (isHovering || isBestMatch) ? Color.primary.opacity(0.065) : Color.clear,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
        }
    }
}

private struct DemoResponse {
    let title: String
    let body: String
    let skillName: String
    let icon: String
    let tint: Color
    let badge: String
}

#Preview {
    AssistantPanelView()
        .frame(width: 780, height: 510)
}
