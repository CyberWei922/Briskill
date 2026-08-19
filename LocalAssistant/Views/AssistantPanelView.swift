import AppKit
import SwiftUI

struct AssistantPanelView: View {
    @AppStorage("recentSkillIDs") private var recentSkillIDs = "ocr,summarize,files,rewrite"
    @FocusState private var searchIsFocused: Bool

    @State private var prompt = ""
    @State private var submittedPrompt = ""
    @State private var response: DemoResponse?
    @State private var isThinking = false
    @State private var copied = false
    @State private var requestID = UUID()

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

            TextField("搜索、执行，或者问任何问题…", text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($searchIsFocused)
                .onSubmit {
                    executeCurrentInput()
                }

            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("本地")
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

                Text(isPredicting ? "\(visibleSkills.count) 项匹配" : "选择一项立即开始")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            if visibleSkills.isEmpty {
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
                    ForEach(visibleSkills.indices, id: \.self) { index in
                        let skill = visibleSkills[index]
                        SkillSuggestionRow(
                            skill: skill,
                            badge: isPredicting ? skill.commandName : (index == 0 ? "最近使用" : "推荐"),
                            isBestMatch: isPredicting && index == 0
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

            Text("模拟本地模型选择合适的技能…")
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

                    Text("界面演示")
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

            Text("UI 原型")
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())

            Spacer()

            KeyHint(keys: "↩", label: "执行")
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

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func executeCurrentInput() {
        let preferredSkill = predictedSkills(for: trimmedPrompt).first
        submit(prompt, preferredSkill: preferredSkill)
    }

    private func run(_ skill: FeatureItem) {
        prompt = skill.samplePrompt
        submit(skill.samplePrompt, preferredSkill: skill)
    }

    private func submit(_ rawPrompt: String, preferredSkill: FeatureItem? = nil) {
        let trimmed = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let currentRequestID = UUID()
        requestID = currentRequestID
        submittedPrompt = trimmed
        copied = false

        withAnimation(.easeOut(duration: 0.16)) {
            response = nil
            isThinking = true
        }

        let matchedSkill = preferredSkill ?? detectSkill(in: trimmed)
        if let matchedSkill {
            remember(matchedSkill)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            guard requestID == currentRequestID else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isThinking = false
                response = makeResponse(skill: matchedSkill)
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
                tint: skill.tint
            )
        }

        return DemoResponse(
            title: "本地问答",
            body: "这是当前问答界面的演示回答。接入本地模型后，我会先理解你的意图，再选择合适的安全工具；普通问题则会直接在这里给出简短回答。",
            skillName: "自由问答",
            icon: "bubble.left.and.text.bubble.right",
            tint: .indigo
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
    }

    private func resetConversation() {
        requestID = UUID()
        prompt = ""
        submittedPrompt = ""
        response = nil
        isThinking = false
        copied = false
        searchIsFocused = true
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
}

#Preview {
    AssistantPanelView()
        .frame(width: 780, height: 510)
}
