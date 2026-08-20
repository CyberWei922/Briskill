import AppKit
import SwiftUI

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

    var body: some View {
        panelContent
            .background(panelBackground)
            .clipShape(panelShape)
            .overlay {
                panelShape
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            }
            .padding(14)
            .frame(minWidth: 720, minHeight: 450)
            .onAppear {
                DispatchQueue.main.async {
                    searchIsFocused = true
                }
            }
            .onChange(of: prompt) {
                selectedSuggestionIndex = 0
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
                    .disabled(trimmedPrompt.isEmpty)
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
                .disabled(trimmedPrompt.isEmpty)
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
                if let completionSuffix {
                    HStack(spacing: 0) {
                        Text(prompt)
                            .foregroundStyle(.clear)
                        Text(completionSuffix)
                            .foregroundStyle(.tertiary)
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
                        cycleSuggestion(by: 1) ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        cycleSuggestion(by: 1) ? .handled : .ignored
                    }
                    .onKeyPress(.upArrow) {
                        cycleSuggestion(by: -1) ? .handled : .ignored
                    }
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
                    prompt = ""
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
    }

    @ViewBuilder
    private var content: some View {
        if isThinking {
            thinkingView
                .transition(.opacity)
        } else if let response {
            responseView(response)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            recommendations
                .transition(.opacity)
        }
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

                Text(response.body)
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

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

    private var completionSuffix: String? {
        guard let selectedSuggestion else { return nil }
        let query = trimmedPrompt
        guard !query.isEmpty, !query.contains(where: \.isWhitespace) else { return nil }

        let terms: [String]
        switch selectedSuggestion {
        case .userSkill(let skill):
            terms = [skill.name] + skill.aliases
        case .builtIn(let skill):
            terms = [skill.commandName, skill.id] + skill.searchTerms
        }

        let normalizedQuery = normalized(query)
        guard let completion = terms
            .filter({ normalized($0).hasPrefix(normalizedQuery) && normalized($0) != normalizedQuery })
            .sorted(by: { $0.count < $1.count })
            .first,
              completion.count >= query.count else {
            return nil
        }

        let suffixStart = completion.index(completion.startIndex, offsetBy: query.count)
        return String(completion[suffixStart...])
    }

    @discardableResult
    private func cycleSuggestion(by offset: Int) -> Bool {
        let count = visibleSuggestionTargets.count
        guard isPredicting, count > 0 else { return false }
        selectedSuggestionIndex = (selectedSuggestionIndex + offset + count) % count
        return true
    }

    private func predictedSkills(for rawQuery: String) -> [FeatureItem] {
        let query = normalized(rawQuery)
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
        let query = normalized(rawQuery)
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
        submit(skill, input: input)
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
                    system: "你是一个运行在 macOS 快捷面板中的个人助手。直接、简洁地回答用户，不要声称执行了任何尚未调用的系统工具。",
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

    private func submit(_ skill: UserSkill, input: String) {
        let currentRequestID = UUID()
        activeTask?.cancel()
        requestID = currentRequestID
        submittedPrompt = input
        copied = false
        AppConsole.shared.info(
            "开始执行用户技能：\(skill.name)；输入字符数=\(input.count)",
            category: "Assistant"
        )

        withAnimation(.easeOut(duration: 0.16)) {
            response = nil
            isThinking = true
        }

        if skill.resolvedExecutionMode == .localOnly {
            let steps = skill.actions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let tools = skill.requiredTools.isEmpty ? "尚未声明工具" : skill.requiredTools.joined(separator: "、")
            AppConsole.shared.info(
                "本地技能“\(skill.name)”已匹配；不会调用云端模型；工具=\(tools)",
                category: "Assistant"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                finish(
                    DemoResponse(
                        title: skill.name,
                        body: "这是一项仅在本机运行的技能，不会调用云端大模型。\n\n计划：\n\(steps)\n\n所需工具：\(tools)\n\n当前版本已经保存并识别这份本地工作流；对应 Tool Executor 接入后会直接按现有定义运行，无需重新创建。",
                        skillName: "我的技能 · 本地执行",
                        icon: "desktopcomputer",
                        tint: .green,
                        badge: "本地"
                    ),
                    requestID: currentRequestID
                )
            }
            return
        }

        let unavailableTools = skill.requiredTools.filter { tool in
            let normalizedTool = tool.lowercased().replacingOccurrences(of: "_", with: ".")
            return ![
                "model",
                "model.generatetext",
                "text.generation",
                "translate",
                "summarize",
                "rewrite"
            ].contains(normalizedTool)
        }

        if !unavailableTools.isEmpty {
            AppConsole.shared.warning(
                "用户技能“\(skill.name)”缺少工具：\(unavailableTools.joined(separator: "、"))",
                category: "Assistant"
            )
            let steps = skill.actions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let missing = unavailableTools.joined(separator: "、")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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
            }
            return
        }

        guard aiSettings.isConfigured() else {
            AppConsole.shared.warning("用户技能“\(skill.name)”需要 AI，但尚未配置服务", category: "Assistant")
            finish(
                DemoResponse(
                    title: skill.name,
                    body: "技能已经匹配，但它需要模型处理文字。请先在设置中配置 AI 服务。\n\n执行计划：\n" + skill.actions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                    skillName: "我的技能",
                    icon: "bolt.fill",
                    tint: .purple,
                    badge: "需要设置"
                ),
                requestID: currentRequestID
            )
            return
        }

        let system = """
        你正在通过统一的 model.generateText 工具执行用户保存的个人技能“\(skill.name)”。
        严格执行运行时提示词模板，只返回最终交付给用户的内容。
        不要声称访问了未由前序工具实际提供的文件、屏幕、剪贴板或应用数据。
        输出要求：\(skill.output)
        """
        let runtimePrompt = (skill.modelTask?.promptTemplate ?? skill.originalRequest)
            .replacingOccurrences(of: "{{userInput}}", with: input)

        activeTask = Task {
            do {
                let answer = try await AIService.shared.generateText(prompt: runtimePrompt, system: system, maxTokens: 900)
                guard !Task.isCancelled else { return }
                finish(
                    DemoResponse(
                        title: skill.name,
                        body: answer,
                        skillName: "我的技能 · \(skill.generatedBy)",
                        icon: "bolt.fill",
                        tint: .purple,
                        badge: aiSettings.selectedProvider.shortName
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
        DemoResponse(
            title: "请求没有完成",
            body: error.localizedDescription,
            skillName: aiSettings.selectedProvider.displayName,
            icon: "exclamationmark.triangle.fill",
            tint: .red,
            badge: "连接错误"
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

                    Text(skill.subtitle)
                        .font(.system(size: 10.5))
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
                    Text(skill.summary)
                        .font(.system(size: 10.5))
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
