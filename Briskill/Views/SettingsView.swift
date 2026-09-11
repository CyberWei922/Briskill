import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    /// One semantic surface for every non-glass area in the settings window.
    /// Keeping this dynamic preserves the correct native shade in light, dark,
    /// and system appearance without letting Form/List choose another canvas.
    static var settingsPaneBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

/// Bridges the settings SwiftUI hierarchy to the existing AppKit window without
/// replacing any window-controller behavior. It only intercepts an actual close
/// request while a skill draft is dirty, then forwards lifecycle callbacks to
/// the controller that originally owned the window delegate.
private struct SettingsWindowCloseGuard: NSViewRepresentable {
    let hasUnsavedChanges: Bool
    let discardChanges: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        context.coordinator.hasUnsavedChanges = hasUnsavedChanges
        context.coordinator.discardChanges = discardChanges
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(
        _ nsView: WindowObservingView,
        coordinator: Coordinator
    ) {
        nsView.windowDidChange = nil
        coordinator.detach()
    }

    final class WindowObservingView: NSView {
        var windowDidChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var guardedWindow: NSWindow?
        weak var previousDelegate: (any NSWindowDelegate)?
        var hasUnsavedChanges = false
        var discardChanges: () -> Void = {}

        func attach(to window: NSWindow?) {
            guard let window else { return }
            guard guardedWindow !== window || window.delegate !== self else { return }
            detach()
            guardedWindow = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if let guardedWindow, guardedWindow.delegate === self {
                guardedWindow.delegate = previousDelegate
            }
            guardedWindow = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if hasUnsavedChanges {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "放弃未保存的技能修改？")
                alert.informativeText = String(localized: "关闭设置窗口后，当前技能尚未保存的内容会丢失。")
                alert.addButton(withTitle: String(localized: "继续编辑"))
                alert.addButton(withTitle: String(localized: "放弃并关闭"))
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
                discardChanges()
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
        }
    }
}

struct SettingsView: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("automaticInputSourceSwitching") private var automaticInputSourceSwitching = true
    @AppStorage("preferredAppearance") private var preferredAppearance = "system"
    @AppStorage("preferredLanguage") private var preferredLanguage = AppLanguage.system.rawValue
    @AppStorage("appAccent") private var appAccent = AppAccent.purple.rawValue
    @AppStorage(AppOpenAction.statusItemDefaultsKey) private var statusItemAction = AppOpenAction.assistant.rawValue
    @AppStorage(AppOpenAction.dockIconDefaultsKey) private var dockIconAction = AppOpenAction.assistant.rawValue
    @AppStorage(MainPanelPositionPreference.defaultsKey) private var mainPanelPosition = MainPanelPositionPreference.screenTopCenter.rawValue
    @ObservedObject private var invocationHistory = InvocationHistoryStore.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    @State private var selection: SettingsSection? = .general
    @State private var historySearchText = ""
    @State private var historyDetailRecord: InvocationRecord?
    @State private var clipboardHistorySearchText = ""
    @State private var clipboardShowsFullHistory = false
    @State private var aiServiceDetailProvider: AIProvider?
    @State private var navigationHistory: [SettingsSection] = [.general]
    @State private var navigationIndex = 0
    @State private var isApplyingHistory = false
    @State private var isDetailScrolled = false
    @State private var skillEditorHasUnsavedChanges = false
    @State private var pendingSectionSelection: SettingsSection?
    @State private var showsDiscardedSkillChangesConfirmation = false
    @State private var showsLanguageRestartAlert = false
    @State private var assistantShortcut = AssistantShortcut.load()
    @State private var assistantShortcutIsConfigured = AssistantShortcut.isConfigured
    @State private var generalClipboardShortcut = ClipboardShortcut.load()
    @State private var generalClipboardShortcutIsConfigured = ClipboardShortcut.isConfigured

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsWindowDragRegion()
                    .frame(height: 58)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(SettingsSection.allCases) { section in
                            SettingsSidebarRow(
                                section: section,
                                isSelected: selection == section,
                                accentColor: accentColor
                            ) {
                                requestSelection(section)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 214)
            .settingsSidebarGlass()

            SettingsSplitSeam()

            rightDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.settingsPaneBackground)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, minHeight: 520)
        .tint(accentColor)
        .background {
            SettingsWindowCloseGuard(
                hasUnsavedChanges: skillEditorHasUnsavedChanges,
                discardChanges: discardSkillChangesForWindowClose
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            AppAppearance.apply(preferredAppearance)
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantShortcutConfigurationDidChange)) { _ in
            assistantShortcut = AssistantShortcut.load()
            assistantShortcutIsConfigured = AssistantShortcut.isConfigured
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardShortcutConfigurationDidChange)) { _ in
            generalClipboardShortcut = ClipboardShortcut.load()
            generalClipboardShortcutIsConfigured = ClipboardShortcut.isConfigured
        }
        .onChange(of: preferredAppearance) { _, newValue in
            AppAppearance.apply(newValue)
        }
        .onChange(of: preferredLanguage) { _, newValue in
            AppLanguage.applyForNextLaunch(newValue)
            showsLanguageRestartAlert = true
        }
        .onChange(of: selection) {
            historyDetailRecord = nil
            aiServiceDetailProvider = nil
            recordSelectionInHistory()
        }
        .alert(
            "放弃未保存的技能修改？",
            isPresented: $showsDiscardedSkillChangesConfirmation
        ) {
            Button("继续编辑", role: .cancel) {
                pendingSectionSelection = nil
            }
            Button("放弃修改", role: .destructive) {
                guard let pendingSectionSelection else { return }
                skillEditorHasUnsavedChanges = false
                selection = pendingSectionSelection
                self.pendingSectionSelection = nil
            }
        } message: {
            Text("切换设置页面后，当前技能尚未保存的内容会丢失。")
        }
        .alert("重新启动以切换语言", isPresented: $showsLanguageRestartAlert) {
            Button("稍后", role: .cancel) {}
            Button("立即重新启动") {
                AppLanguage.restartApplication()
            }
        } message: {
            Text("Briskill 将在重新启动后使用所选语言。")
        }
    }

    private var currentSection: SettingsSection {
        selection ?? .general
    }

    private var accentColor: Color {
        AppAccent.resolve(appAccent).color
    }

    @ViewBuilder
    private var rightDetail: some View {
        if currentSection == .skills {
            SkillManagementView(
                canGoBack: navigationIndex > 0,
                canGoForward: navigationIndex + 1 < navigationHistory.count,
                goBack: { moveInHistory(by: -1) },
                goForward: { moveInHistory(by: 1) },
                onEditingDirtyChange: { skillEditorHasUnsavedChanges = $0 }
            )
        } else {
            VStack(spacing: 0) {
                SettingsPageHeader(
                    title: settingsHeaderTitle,
                    subtitle: settingsHeaderSubtitle,
                    showsSeparator: isDetailScrolled,
                    searchText: settingsHeaderSearchText,
                    searchPrompt: settingsHeaderSearchPrompt,
                    canGoBack: historyDetailRecord != nil || clipboardShowsFullHistory || aiServiceDetailProvider != nil || navigationIndex > 0,
                    canGoForward: historyDetailRecord == nil && !clipboardShowsFullHistory && aiServiceDetailProvider == nil && navigationIndex + 1 < navigationHistory.count,
                    goBack: { goBackFromSettingsHeader() },
                    goForward: { moveInHistory(by: 1) },
                    trailingActionTitle: historyDetailRecord?.isConversation == true
                        ? String(localized: "继续对话")
                        : nil,
                    trailingActionSymbol: "bubble.left.and.bubble.right",
                    trailingAction: historyDetailRecord?.isConversation == true
                        ? { continueConversationFromHistory() }
                        : nil
                )

                settingsDetail
                    .trackSettingsScroll($isDetailScrolled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.settingsPaneBackground)
        }
    }

    private func recordSelectionInHistory() {
        isDetailScrolled = false
        guard !isApplyingHistory, let selection else { return }
        guard navigationHistory[navigationIndex] != selection else { return }
        if navigationIndex + 1 < navigationHistory.count {
            navigationHistory.removeSubrange((navigationIndex + 1)..<navigationHistory.count)
        }
        navigationHistory.append(selection)
        navigationIndex = navigationHistory.count - 1
    }

    private func requestSelection(_ section: SettingsSection) {
        if section == currentSection {
            if section == .clipboard { clipboardShowsFullHistory = false }
            if section == .history { historyDetailRecord = nil }
            if section == .aiServices { aiServiceDetailProvider = nil }
            return
        }
        clipboardShowsFullHistory = false
        if currentSection == .skills, skillEditorHasUnsavedChanges {
            pendingSectionSelection = section
            showsDiscardedSkillChangesConfirmation = true
        } else {
            selection = section
        }
    }

    private func discardSkillChangesForWindowClose() {
        skillEditorHasUnsavedChanges = false
        pendingSectionSelection = nil
        showsDiscardedSkillChangesConfirmation = false
        selection = .general
    }

    private func moveInHistory(by offset: Int) {
        let target = navigationIndex + offset
        guard navigationHistory.indices.contains(target) else { return }
        isApplyingHistory = true
        navigationIndex = target
        selection = navigationHistory[target]
        DispatchQueue.main.async {
            isApplyingHistory = false
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch currentSection {
        case .general: generalSettings
        case .history:
            if let record = historyDetailRecord {
                InvocationHistoryDetail(
                    record: record,
                    delete: {
                        invocationHistory.delete(record)
                        historyDetailRecord = nil
                    }
                )
            } else {
                InvocationHistorySettingsView(
                    searchText: $historySearchText,
                    openRecord: {
                        historyDetailRecord = $0
                        isDetailScrolled = false
                    }
                )
            }
        case .clipboard:
            if clipboardShowsFullHistory {
                ClipboardFullHistorySettingsView(searchText: $clipboardHistorySearchText)
            } else {
                ClipboardManagerSettingsView(openFullHistory: openFullClipboardHistory)
            }
        case .aiServices: AIProviderSettingsView(detailProvider: $aiServiceDetailProvider)
        case .localModel: modelSettings
        case .skills: EmptyView()
        case .privacy: PrivacySettingsView()
        case .about: AboutSettingsView()
        }
    }

    private var settingsHeaderTitle: String {
        if currentSection == .history, let historyDetailRecord {
            return historyDetailRecord.title
        }
        if currentSection == .clipboard && clipboardShowsFullHistory {
            return String(localized: "完整剪贴板历史")
        }
        if currentSection == .aiServices, let aiServiceDetailProvider {
            return aiServiceDetailProvider.displayName
        }
        return currentSection.title
    }

    private var settingsHeaderSubtitle: String? {
        guard currentSection == .history, let historyDetailRecord else { return nil }
        return historyDetailRecord.startedAt.formatted(date: .long, time: .shortened)
    }

    private var settingsHeaderSearchText: Binding<String>? {
        if currentSection == .history, historyDetailRecord == nil { return $historySearchText }
        if currentSection == .clipboard, clipboardShowsFullHistory { return $clipboardHistorySearchText }
        return nil
    }

    private var settingsHeaderSearchPrompt: String? {
        if currentSection == .history, historyDetailRecord == nil {
            return String(localized: "在 \(invocationHistory.records.count) 条记录中搜索")
        }
        if currentSection == .clipboard, clipboardShowsFullHistory {
            return String(
                format: String(localized: "在 %lld 条历史中搜索"),
                ClipboardHistoryStore.shared.fullHistoryCount
            )
        }
        return nil
    }

    private func goBackFromSettingsHeader() {
        if historyDetailRecord != nil {
            historyDetailRecord = nil
            isDetailScrolled = false
        } else if clipboardShowsFullHistory {
            clipboardShowsFullHistory = false
            clipboardHistorySearchText = ""
            isDetailScrolled = false
        } else if aiServiceDetailProvider != nil {
            aiServiceDetailProvider = nil
            isDetailScrolled = false
        } else {
            moveInHistory(by: -1)
        }
    }

    private func continueConversationFromHistory() {
        guard let historyDetailRecord, historyDetailRecord.isConversation else { return }
        PanelController.shared.resumeConversation(historyDetailRecord)
    }

    private func openFullClipboardHistory() {
        Task { @MainActor in
            guard await ClipboardHistoryStore.shared.authorizeFullHistoryAccess() else { return }
            guard ClipboardHistoryStore.shared.prepareFullHistory() else { return }
            clipboardHistorySearchText = ""
            clipboardShowsFullHistory = true
            isDetailScrolled = false
        }
    }

    private var generalSettings: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动", isOn: launchAtLoginBinding)
                Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)

                if launchAtLogin.requiresApproval {
                    HStack {
                        Label("等待在系统设置中允许", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("打开登录项设置…") {
                            launchAtLogin.openSystemSettings()
                        }
                    }
                } else if let errorMessage = launchAtLogin.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("操作") {
                HStack(alignment: .center, spacing: 12) {
                    Text("主面板快捷键")
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        ClipboardShortcutRecorder(
                            shortcut: $assistantShortcut,
                            isConfigured: $assistantShortcutIsConfigured,
                            onShortcutChange: { AssistantShortcut.save($0) },
                            isShortcutAllowed: { candidate in
                                !generalClipboardShortcutIsConfigured
                                    || candidate != generalClipboardShortcut
                            }
                        )
                        .id("assistant-shortcut-recorder")
                        .frame(width: 92, height: operationControlHeight)
                        Button {
                            assistantShortcutIsConfigured = false
                            AssistantShortcut.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: operationTrailingControlWidth, height: operationControlHeight)
                        }
                        .buttonStyle(.plain)
                        .disabled(!assistantShortcutIsConfigured)
                        .help("清除快捷键")
                    }
                    .frame(width: operationControlColumnWidth, alignment: .trailing)
                }
                .frame(height: operationRowHeight)

                HStack(alignment: .center, spacing: 12) {
                    Text("剪贴板快捷键")
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        ClipboardShortcutRecorder(
                            shortcut: $generalClipboardShortcut,
                            isConfigured: $generalClipboardShortcutIsConfigured,
                            isShortcutAllowed: { candidate in
                                !assistantShortcutIsConfigured || candidate != assistantShortcut
                            }
                        )
                        .id("clipboard-shortcut-recorder-general")
                        .frame(width: 92, height: operationControlHeight)
                        Button {
                            generalClipboardShortcutIsConfigured = false
                            ClipboardShortcut.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: operationTrailingControlWidth, height: operationControlHeight)
                        }
                        .buttonStyle(.plain)
                        .disabled(!generalClipboardShortcutIsConfigured)
                        .help("清除快捷键")
                    }
                    .frame(width: operationControlColumnWidth, alignment: .trailing)
                }
                .frame(height: operationRowHeight)

                HStack(alignment: .center, spacing: 12) {
                    Text("左键点击状态栏图标")
                    Spacer(minLength: 12)
                    Picker("", selection: $statusItemAction) {
                        ForEach(AppOpenAction.allCases) { action in
                            Text(action.title).tag(action.rawValue)
                        }
                    }
                    .labelsHidden()
                    .tint(.primary)
                    .foregroundStyle(.primary)
                    .frame(width: operationControlColumnWidth, height: operationControlHeight, alignment: .trailing)
                }
                .frame(height: operationRowHeight)

                HStack(alignment: .center, spacing: 12) {
                    Text("点击软件图标")
                    Spacer(minLength: 12)
                    Picker("", selection: $dockIconAction) {
                        ForEach(AppOpenAction.allCases) { action in
                            Text(action.title).tag(action.rawValue)
                        }
                    }
                    .labelsHidden()
                    .tint(.primary)
                    .foregroundStyle(.primary)
                    .frame(width: operationControlColumnWidth, height: operationControlHeight, alignment: .trailing)
                }
                .frame(height: operationRowHeight)

                HStack(alignment: .center, spacing: 12) {
                    Text("主面板打开位置")
                    Spacer(minLength: 12)
                    Picker("", selection: $mainPanelPosition) {
                        ForEach(MainPanelPositionPreference.allCases) { preference in
                            Text(preference.title).tag(preference.rawValue)
                        }
                    }
                    .labelsHidden()
                    .tint(.primary)
                    .foregroundStyle(.primary)
                    .frame(width: operationControlColumnWidth, height: operationControlHeight, alignment: .trailing)
                }
                .frame(height: operationRowHeight)
            }
            Section("输入") {
                Toggle("根据参数自动切换输入法", isOn: $automaticInputSourceSwitching)
                Text("唤起面板时使用英文输入技能关键词；确认技能后，如果下一个参数是文本或段落文字，则恢复到唤起前使用的输入法。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("外观") {
                Picker("外观", selection: $preferredAppearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)

                LabeledContent("主题色") {
                    HStack(spacing: 10) {
                        ForEach(AppAccent.allCases) { accent in
                            Button {
                                appAccent = accent.rawValue
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(accent.color)
                                        .frame(width: 22, height: 22)
                                        .overlay {
                                            if accent == .system {
                                                Circle()
                                                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8)
                                            }
                                        }
                                    if appAccent == accent.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(accent.displayName)
                        }
                    }
                }
            }
            Section("语言") {
                Picker("应用语言", selection: $preferredLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .tint(.primary)
                Text("更改将在重新启动 Briskill 后生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsPaneBackground)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isRegistered },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var operationRowHeight: CGFloat { 22 }
    private var operationControlHeight: CGFloat { 22 }
    private var operationControlColumnWidth: CGFloat { 188 }
    private var operationTrailingControlWidth: CGFloat { 16 }

    private var modelSettings: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("本地模型将在下一阶段接入")
                .font(.headline)
            Text("当前版本已经可以使用 DeepSeek、GLM、Gemini 或 OpenAI 完成真实问答和技能草稿生成。本地模型管理仍保留为独立模块。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.settingsPaneBackground)
    }

}

private struct ClipboardManagerSettingsView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @AppStorage("clipboardManager.rowDensity") private var rowDensity = ClipboardRowDensity.comfortable.rawValue
    @AppStorage("clipboardManager.panelPosition") private var panelPosition = ClipboardPanelPosition.nearCursor.rawValue
    @State private var shortcut = ClipboardShortcut.load()
    @State private var shortcutIsConfigured = ClipboardShortcut.isConfigured
    @State private var securityError: String?
    let openFullHistory: () -> Void

    var body: some View {
        Form {
            Section("剪贴板管理") {
                Toggle("启用剪贴板历史", isOn: enabledBinding)
                HStack {
                    Text("面板保留记录条数")
                    Spacer()
                    TextField("", value: panelItemLimitBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 58)
                    Text("条")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("剪贴板保留时长")
                    Spacer()
                    Picker("", selection: retentionPeriodBinding) {
                        ForEach(ClipboardRetentionPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .labelsHidden()
                    .tint(.primary)
                    .foregroundStyle(.primary)
                }
                Text("到期内容会自动转移至硬盘保存，保留内容过多可能会占用大量运行内存，影响电脑性能，建议选择 7 天以内。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                HStack(spacing: 8) {
                    Text("打开剪贴板面板")
                    Spacer(minLength: 12)
                    ClipboardShortcutRecorder(
                        shortcut: $shortcut,
                        isConfigured: $shortcutIsConfigured,
                        isShortcutAllowed: { candidate in
                            !AssistantShortcut.isConfigured || candidate != AssistantShortcut.load()
                        }
                    )
                    .frame(width: 92, height: 30)
                    Button {
                        shortcutIsConfigured = false
                        ClipboardShortcut.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!shortcutIsConfigured)
                    .help("清除快捷键")
                }
                .padding(.trailing, 18)
                Text("点击快捷键后直接按下新的组合键；不能与主面板快捷键相同。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!store.isEnabled)

            Section("面板外观") {
                Picker("显示大小", selection: $rowDensity) {
                    ForEach(ClipboardRowDensity.allCases) { density in
                        Text(density.title).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("面板位置", selection: $panelPosition) {
                    ForEach(ClipboardPanelPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                }
                .tint(.primary)
                .foregroundStyle(.primary)
                Text("小尺寸只保留主要内容；中尺寸显示类型图标和静态复制时间；大尺寸会为图片提供内容预览。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!store.isEnabled)

            Section("鼠标操作") {
                Picker("左键默认操作", selection: primaryActionBinding) {
                    ForEach(ClipboardItemAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .tint(.primary)
                .foregroundStyle(.primary)
                LabeledContent("右键默认操作") {
                    Text(store.secondaryClickAction.title)
                        .foregroundStyle(.secondary)
                }
                Text("左右键始终使用相反动作。Command 加 1 至 9 会直接粘贴对应记录，方向键移动，按回车粘贴当前选中项；输入普通字符后才会进入搜索。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!store.isEnabled)

            Section("历史数据") {
                Toggle("启用完整剪贴板历史", isOn: fullHistoryEnabledBinding)
                Toggle("加密历史记录", isOn: encryptionBinding)
                Toggle("使用 Touch ID 或锁屏密码打开完整历史记录", isOn: touchIDBinding)

                Button(action: openFullHistory) {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("完整剪贴板历史")
                                .foregroundStyle(.primary)
                            Text(String(format: String(localized: "共 %lld 条"), store.fullHistoryCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(store.formattedLocalStorageSize)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let message = securityError ?? store.securityMessage {
                    let isError = securityError != nil || store.securityMessageIsError
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }

            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsPaneBackground)
        .onReceive(NotificationCenter.default.publisher(for: .clipboardShortcutConfigurationDidChange)) { _ in
            shortcut = ClipboardShortcut.load()
            shortcutIsConfigured = ClipboardShortcut.isConfigured
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { store.isEnabled }, set: { store.setEnabled($0) })
    }

    private var primaryActionBinding: Binding<ClipboardItemAction> {
        Binding(get: { store.primaryClickAction }, set: { store.setPrimaryClickAction($0) })
    }

    private var panelItemLimitBinding: Binding<Int> {
        Binding(get: { store.panelItemLimit }, set: { store.setPanelItemLimit($0) })
    }

    private var retentionPeriodBinding: Binding<ClipboardRetentionPeriod> {
        Binding(get: { store.retentionPeriod }, set: { store.setRetentionPeriod($0) })
    }

    private var fullHistoryEnabledBinding: Binding<Bool> {
        Binding(get: { store.isFullHistoryEnabled }, set: { store.setFullHistoryEnabled($0) })
    }

    private var encryptionBinding: Binding<Bool> {
        Binding(
            get: { store.isEncryptionEnabled },
            set: { enabled in
                do {
                    try store.setEncryptionEnabled(enabled)
                    securityError = nil
                } catch {
                    securityError = error.localizedDescription
                }
            }
        )
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { store.requiresTouchID },
            set: { required in
                Task { @MainActor in
                    let changed = await store.setTouchIDRequired(required)
                    if changed { securityError = nil }
                }
            }
        )
    }
}

private struct ClipboardFullHistorySettingsView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @Binding var searchText: String
    @State private var copiedItemID: UUID?
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var isConfirmingClear = false
    @State private var isConfirmingBatchDelete = false

    private var filteredItems: [ClipboardHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.fullHistoryItems }
        return store.fullHistoryItems.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.detail.localizedCaseInsensitiveContains(query)
                || (item.sourceApplication?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if filteredItems.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "暂无完整剪贴板历史" : "没有匹配的剪贴板历史",
                    systemImage: searchText.isEmpty ? "clipboard" : "magnifyingglass"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            ClipboardFullHistoryRow(
                                item: item,
                                wasCopied: copiedItemID == item.id,
                                isSelecting: isSelecting,
                                isSelected: selectedItemIDs.contains(item.id),
                                primaryAction: {
                                    if isSelecting {
                                        toggleSelection(item.id)
                                    } else {
                                        store.putOnPasteboard(item)
                                        copiedItemID = item.id
                                    }
                                },
                                deleteAction: { store.remove(item) }
                            )
                            if index < filteredItems.count - 1 {
                                Divider()
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 72)
                }
            }

            fullHistoryFloatingControls
                .padding(18)
        }
        .background(Color.settingsPaneBackground)
        .onChange(of: store.fullHistoryItems.map(\.id)) {
            selectedItemIDs.formIntersection(Set(store.fullHistoryItems.map(\.id)))
        }
        .onDisappear {
            store.releaseFullHistory()
        }
        .alert("清空全部剪贴板历史？", isPresented: $isConfirmingClear) {
            Button("取消", role: .cancel) {}
            Button("全部清空", role: .destructive) {
                store.clear()
                leaveSelectionMode()
            }
        } message: {
            Text("这会永久删除全部剪贴板历史，但不会改变当前系统剪贴板。")
        }
        .alert("删除选中的 \(selectedItemIDs.count) 条剪贴板历史？", isPresented: $isConfirmingBatchDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                store.delete(ids: selectedItemIDs)
                leaveSelectionMode()
            }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var fullHistoryFloatingControls: some View {
        HStack(spacing: 8) {
            if isSelecting {
                SettingsFloatingActionButton(title: "取消", symbol: "xmark") {
                    leaveSelectionMode()
                }
                SettingsFloatingActionButton(
                    title: "删除 \(selectedItemIDs.count) 条",
                    symbol: "trash",
                    tint: .red,
                    disabled: selectedItemIDs.isEmpty
                ) {
                    isConfirmingBatchDelete = true
                }
            } else {
                SettingsFloatingActionButton(
                    title: "全部清空",
                    symbol: "trash",
                    tint: .red,
                    disabled: store.fullHistoryItems.isEmpty
                ) {
                    isConfirmingClear = true
                }
                SettingsFloatingActionButton(
                    title: "多选",
                    symbol: "checkmark.circle",
                    disabled: store.fullHistoryItems.isEmpty
                ) {
                    isSelecting = true
                }
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func leaveSelectionMode() {
        isSelecting = false
        selectedItemIDs.removeAll()
    }
}

private struct ClipboardFullHistoryRow: View {
    let item: ClipboardHistoryItem
    let wasCopied: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let primaryAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: primaryAction) {
                HStack(spacing: 11) {
                    historyPreview
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let source = item.sourceApplication { Text(source) }
                            Text(item.kindTitle)
                            Text(item.detail)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()
                    if wasCopied {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isSelecting {
                Button(role: .destructive, action: deleteAction) {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("删除这条历史")
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
    }

    @ViewBuilder
    private var historyPreview: some View {
        if let image = item.previewImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: item.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct PrivacySettingsView: View {
    @ObservedObject private var permissions = PrivacyPermissionCenter.shared
    @ObservedObject private var locations = AuthorizedLocationStore.shared
    @ObservedObject private var aiSettings = AISettingsStore.shared

    @State private var message: String?
    @State private var messageIsError = false
    @State private var permissionMessage: String?
    @State private var permissionMessageIsError = false
    @State private var confirmsLocalStorage = false

    var body: some View {
        Form {
            Section("系统权限") {
                PermissionSettingsRow(
                    title: "辅助功能",
                    detail: "仅在你选择直接粘贴剪贴板记录时，向此前使用的应用发送 Command-V",
                    symbol: "cursorarrow.motionlines",
                    granted: permissions.accessibilityGranted,
                    actionTitle: permissions.accessibilityGranted ? "管理…" : "请求授权"
                ) {
                    if permissions.accessibilityGranted {
                        permissions.openAccessibilitySettings()
                    } else {
                        permissions.requestAccessibility()
                    }
                }

                PermissionSettingsRow(
                    title: "屏幕录制",
                    detail: "仅在运行区域截图技能时读取你框选的屏幕范围",
                    symbol: "rectangle.dashed",
                    granted: permissions.screenRecordingGranted,
                    actionTitle: permissions.screenRecordingGranted ? "管理…" : "请求授权"
                ) {
                    if permissions.screenRecordingGranted {
                        permissions.openScreenRecordingSettings()
                    } else {
                        permissions.requestScreenRecording()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("文件与文件夹")
                            Text("通过原生选择器逐个保存可访问位置；不会获得整个磁盘权限")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(
                            locations.locations.isEmpty
                                ? String(localized: "按需选择")
                                : String(localized: "已保存 \(locations.locations.count) 个位置")
                        )
                            .font(.caption)
                            .foregroundStyle(locations.locations.isEmpty ? Color.secondary : Color.green)
                        Button("添加位置…", action: chooseAuthorizedLocations)
                    }

                    ForEach(locations.locations) { location in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(location.displayName)
                                Text(location.originalPath)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                locations.remove(location)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("移除这个持久访问位置")
                        }
                        .padding(.leading, 32)
                    }
                }
                .padding(.vertical, 3)

                Text("授权状态由 macOS 管理并通常会跨重启保留；你可以随时在系统设置中撤销。应用更新、签名或安装位置变化时，系统可能要求重新授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let permissionMessage {
                    Label(
                        permissionMessage,
                        systemImage: permissionMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(permissionMessageIsError ? Color.red : Color.green)
                }
            }

            Section("API Key 保存位置") {
                Picker("保存方式", selection: storageModeBinding) {
                    ForEach(APIKeyStorageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(aiSettings.apiKeyStorageMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if aiSettings.apiKeyStorageMode == .localFile {
                    LabeledContent("本地文件") {
                        Text(aiSettings.localAPIKeyFileURL?.path ?? "保存第一个密钥后创建")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button("在 Finder 中显示") {
                        revealLocalAPIKeyFile()
                    }
                    .disabled(!localAPIKeyFileExists)
                    Text("本地模式使用 0600 文件权限，仅允许当前 macOS 用户读取，但密钥仍是可查看的明文；不要把该文件同步、分享或加入 Git。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(messageIsError ? Color.red : Color.green)
                }
            }

            Section("无需单独授权") {
                localizedPermissionValueRow("剪贴板", value: "只在运行对应技能时访问")
                localizedPermissionValueRow("Apple Vision OCR", value: "图片识别完全在本机运行")
                localizedPermissionValueRow("系统状态", value: "仅读取本机公开诊断信息")
                localizedPermissionValueRow("网络请求", value: "仅云端 AI 技能使用")
            }

            Section("本地数据") {
                Label("自定义技能、生成记录和调用历史保存在 Application Support", systemImage: "externaldrive.fill")
                Label("创建技能时不会自动上传真实文件、截图或剪贴板内容", systemImage: "checkmark.shield")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsPaneBackground)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .confirmationDialog(
            "改用本地可查看文件？",
            isPresented: $confirmsLocalStorage,
            titleVisibility: .visible
        ) {
            Button("迁移并使用本地文件") {
                changeStorageMode(to: .localFile)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现有 API Key 会从钥匙串迁移到仅当前用户可读的 JSON 文件。该方式便于再次查看，但安全性低于钥匙串。")
        }
    }

    private var storageModeBinding: Binding<APIKeyStorageMode> {
        Binding(
            get: { aiSettings.apiKeyStorageMode },
            set: { newMode in
                if newMode == .localFile {
                    confirmsLocalStorage = true
                } else {
                    changeStorageMode(to: newMode)
                }
            }
        )
    }

    private func localizedPermissionValueRow(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(LocalizedStringKey(value))
                .foregroundStyle(.secondary)
        } label: {
            Text(LocalizedStringKey(title))
        }
    }

    private func changeStorageMode(to mode: APIKeyStorageMode) {
        do {
            try aiSettings.changeAPIKeyStorageMode(to: mode)
            message = "API Key 已迁移到\(mode.displayName)"
            messageIsError = false
        } catch {
            message = "迁移失败：\(error.localizedDescription)"
            messageIsError = true
        }
    }

    private func chooseAuthorizedLocations() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "添加 Briskill 可访问的位置")
        panel.message = String(localized: "选择的文件夹会通过系统安全书签保存，供文件搜索和整理技能在以后继续使用。")
        panel.prompt = String(localized: "授权此位置")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            do {
                for url in panel.urls {
                    try locations.add(url)
                }
                permissionMessage = "已保存 \(panel.urls.count) 个文件访问位置"
                permissionMessageIsError = false
            } catch {
                permissionMessage = "文件授权保存失败：\(error.localizedDescription)"
                permissionMessageIsError = true
            }
        }
    }

    private func revealLocalAPIKeyFile() {
        guard let url = aiSettings.localAPIKeyFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private var localAPIKeyFileExists: Bool {
        guard let url = aiSettings.localAPIKeyFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label {
                Text(granted ? String(localized: "已授权") : String(localized: "未授权"))
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
            }
                .font(.caption)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            Button(action: action) {
                Text(LocalizedStringKey(actionTitle))
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsSplitSeam: View {
    var body: some View {
        ZStack {
            // The settings window itself is transparent so Liquid Glass can sample
            // the desktop. Give the split gutter an opaque backing; otherwise the
            // translucent system Divider exposes a one-pixel strip behind the app.
            Color.settingsPaneBackground

            Color.primary.opacity(0.12)
                .frame(width: 0.5)
        }
        .frame(width: 1)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

private struct SettingsWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : accentColor)
                    .frame(width: 17)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
                .background(
                    isSelected ? accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    @ViewBuilder
    func settingsSidebarGlass() -> some View {
        if #available(macOS 26.0, *) {
            background(.ultraThinMaterial)
                .glassEffect(.regular, in: Rectangle())
        } else {
            background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func settingsNavigationGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
        }
    }

    @ViewBuilder
    func settingsHeaderSearchGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                }
        }
    }

    @ViewBuilder
    func settingsFloatingGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
        }
    }

    func trackSettingsScroll(_ isScrolled: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 1
        } action: { _, newValue in
            if isScrolled.wrappedValue != newValue {
                isScrolled.wrappedValue = newValue
            }
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    var subtitle: String? = nil
    var showsSeparator = false
    var searchText: Binding<String>? = nil
    var searchPrompt: String? = nil
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
    var trailingActionTitle: String? = nil
    var trailingActionSymbol: String = "arrow.right"
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            SettingsHistoryControl(
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                goBack: goBack,
                goForward: goForward
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: subtitle == nil ? 15 : 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let searchText {
                SettingsHeaderSearchField(
                    text: searchText,
                    prompt: searchPrompt ?? "搜索"
                )
            }


            if let trailingActionTitle, let trailingAction {
                Button(action: trailingAction) {
                    Label(trailingActionTitle, systemImage: trailingActionSymbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .settingsFloatingGlass()
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 58)
        .background(Color.settingsPaneBackground)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Divider()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsSeparator)
    }
}

private struct SettingsHeaderSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 210, height: 36)
        .settingsHeaderSearchGlass()
    }
}

struct SettingsFloatingActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.45) : tint)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .settingsFloatingGlass()
        .disabled(disabled)
    }
}

private struct SettingsHistoryControl: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(canGoBack ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.24))
                    .frame(width: 33, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .help(canGoBack ? "后退" : "没有可后退的页面")

            Divider()
                .frame(height: 18)

            Button(action: goForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(canGoForward ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.24))
                    .frame(width: 33, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
            .help(canGoForward ? "前进" : "没有可前进的页面")
        }
        .padding(4)
        .settingsNavigationGlass()
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case history
    case clipboard
    case aiServices
    case localModel
    case skills
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .history: String(localized: "历史记录")
        case .clipboard: String(localized: "剪贴板管理")
        case .aiServices: String(localized: "AI 服务")
        case .localModel: String(localized: "本地模型")
        case .skills: String(localized: "技能管理")
        case .privacy: String(localized: "隐私与权限")
        case .about: String(localized: "关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .clipboard: "clipboard"
        case .aiServices: "sparkles"
        case .localModel: "cpu"
        case .skills: "square.stack.3d.up"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

private struct AboutSettingsView: View {
    @ObservedObject private var updateChecker = BriskillUpdateChecker.shared
    @AppStorage("updates.automaticChecksEnabled") private var automaticChecksEnabled = true

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text("Briskill")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(
                        String(
                            format: String(localized: "版本 %@（构建 %@）"),
                            updateChecker.currentVersion,
                            updateChecker.currentBuild
                        )
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section("项目") {
                Button {
                    updateChecker.openProjectPage()
                } label: {
                    AboutLinkRow(title: "GitHub 项目主页", symbol: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.plain)

                Button {
                    updateChecker.openChangelog()
                } label: {
                    AboutLinkRow(title: "更新日志", symbol: "doc.text")
                }
                .buttonStyle(.plain)
            }

            Section("软件更新") {
                Toggle("自动检查更新", isOn: $automaticChecksEnabled)

                updateStatus

                HStack {
                    Button("检查更新") {
                        Task { await updateChecker.checkForUpdates() }
                    }
                    .disabled(updateChecker.status == .checking)

                    Spacer()

                    if case .updateAvailable(let release) = updateChecker.status {
                        Button("查看并下载…") {
                            updateChecker.openRelease(release)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsPaneBackground)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateChecker.status {
        case .idle:
            Label("尚未检查更新", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查更新…")
            }
            .foregroundStyle(.secondary)
        case .upToDate(let latestVersion):
            Label(
                String(format: String(localized: "当前已是最新版本（%@）。"), latestVersion),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .updateAvailable(let release):
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    String(format: String(localized: "发现新版本 %@"), release.version),
                    systemImage: "arrow.down.circle.fill"
                )
                    .foregroundStyle(Color.accentColor)
                Text(release.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AboutLinkRow: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(LocalizedStringKey(title))
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct SkillManagementView: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
    let onEditingDirtyChange: (Bool) -> Void
    @ObservedObject private var skillStore = SkillStore.shared
    @State private var editingSkillID: UUID?
    @State private var searchText = ""
    @State private var message: SkillManagementMessage?
    @State private var skillPendingDeletion: UserSkill?
    @State private var isLibraryScrolled = false
    @State private var forwardEditingSkillID: UUID?
    @State private var isSelecting = false
    @State private var selectedSkillIDs: Set<UUID> = []
    @State private var isConfirmingBatchDelete = false

    var body: some View {
        Group {
            if let skill = skillBeingEdited {
                SkillEditorView(
                    skill: skill,
                    message: message,
                    onBack: closeEditorForBack,
                    canGoForward: canGoForward,
                    goForward: goForward,
                    onEnabledChange: { setEnabled($0, for: skill.id) },
                    onSave: save,
                    onExport: export,
                    onDelete: { skillPendingDeletion = $0 },
                    onDirtyChange: onEditingDirtyChange
                )
                .id(skill.id)
            } else {
                VStack(spacing: 0) {
                    SettingsPageHeader(
                        title: SettingsSection.skills.title,
                        showsSeparator: isLibraryScrolled,
                        searchText: $searchText,
                        searchPrompt: String(localized: "在 \(skillStore.skills.count) 项技能中搜索"),
                        canGoBack: canGoBack,
                        canGoForward: forwardEditingSkillID != nil || canGoForward,
                        goBack: goBack,
                        goForward: moveForwardFromLibrary
                    )
                    skillLibrary
                }
            }
        }
        .background(Color.settingsPaneBackground)
        .onChange(of: skillStore.skills.map(\.id)) {
            selectedSkillIDs.formIntersection(Set(skillStore.skills.map(\.id)))
            if let editingSkillID,
               !skillStore.skills.contains(where: { $0.id == editingSkillID }) {
                self.editingSkillID = nil
            }
            if let forwardEditingSkillID,
               !skillStore.skills.contains(where: { $0.id == forwardEditingSkillID }) {
                self.forwardEditingSkillID = nil
            }
        }
        .alert(
            "删除技能？",
            isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
            ),
            presenting: skillPendingDeletion
        ) { skill in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { delete(skill) }
        } message: { skill in
            Text("“\(skill.name)”会从本机永久删除。你可以先导出备份。")
        }
        .alert("删除选中的 \(selectedSkillIDs.count) 项技能？", isPresented: $isConfirmingBatchDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive, action: deleteSelectedSkills)
        } message: {
            Text("删除后无法恢复。需要保留的技能请先批量导出。")
        }
    }

    private var skillLibrary: some View {
        ZStack(alignment: .bottomTrailing) {
            if filteredSkills.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "还没有技能" : "没有匹配的技能",
                    systemImage: searchText.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "创建第一个技能后，它会出现在这里。" : "尝试搜索名称、关键词或说明。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredSkills.enumerated()), id: \.element.id) { index, skill in
                            Button {
                                if isSelecting {
                                    toggleSelection(for: skill.id)
                                } else {
                                    openEditor(for: skill)
                                }
                            } label: {
                                SkillManagementRow(
                                    skill: skill,
                                    isSelecting: isSelecting,
                                    isSelected: selectedSkillIDs.contains(skill.id)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if !isSelecting {
                                    Button("编辑") { openEditor(for: skill) }
                                    Button("导出…") { export(skill) }
                                    Divider()
                                    Button("删除", role: .destructive) { skillPendingDeletion = skill }
                                }
                            }

                            if index + 1 < filteredSkills.count {
                                Divider()
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.7)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 72)
                }
                .trackSettingsScroll($isLibraryScrolled)
            }

            skillFloatingControls
                .padding(18)
        }
        .background(Color.settingsPaneBackground)
    }

    private var skillFloatingControls: some View {
        HStack(spacing: 8) {
            if isSelecting {
                SettingsFloatingActionButton(title: "取消", symbol: "xmark") {
                    leaveSelectionMode()
                }
                SettingsFloatingActionButton(
                    title: "导出 \(selectedSkillIDs.count) 项",
                    symbol: "square.and.arrow.up.on.square",
                    disabled: selectedSkillIDs.isEmpty,
                    action: exportSelectedSkills
                )
                SettingsFloatingActionButton(
                    title: "删除 \(selectedSkillIDs.count) 项",
                    symbol: "trash",
                    tint: .red,
                    disabled: selectedSkillIDs.isEmpty
                ) {
                    isConfirmingBatchDelete = true
                }
            } else {
                SettingsFloatingActionButton(title: "创建技能", symbol: "plus") {
                    SkillCreatorWindowController.shared.show()
                }
                SettingsFloatingActionButton(
                    title: "多选",
                    symbol: "checkmark.circle",
                    disabled: skillStore.skills.isEmpty
                ) {
                    isSelecting = true
                }
            }
        }
    }

    private var filteredSkills: [UserSkill] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skillStore.skills }
        return skillStore.skills.filter { skill in
            skill.searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var skillBeingEdited: UserSkill? {
        guard let editingSkillID else { return nil }
        return skillStore.skills.first(where: { $0.id == editingSkillID })
    }

    private func openEditor(for skill: UserSkill) {
        editingSkillID = skill.id
        forwardEditingSkillID = nil
        message = nil
    }

    private func toggleSelection(for id: UUID) {
        if selectedSkillIDs.contains(id) {
            selectedSkillIDs.remove(id)
        } else {
            selectedSkillIDs.insert(id)
        }
    }

    private func leaveSelectionMode() {
        isSelecting = false
        selectedSkillIDs.removeAll()
    }

    private func closeEditorForBack() {
        forwardEditingSkillID = editingSkillID
        editingSkillID = nil
        message = nil
    }

    private func moveForwardFromLibrary() {
        if let forwardEditingSkillID,
           skillStore.skills.contains(where: { $0.id == forwardEditingSkillID }) {
            editingSkillID = forwardEditingSkillID
            self.forwardEditingSkillID = nil
            message = nil
        } else {
            goForward()
        }
    }

    @discardableResult
    private func setEnabled(_ isEnabled: Bool, for skillID: UUID) -> Bool {
        do {
            try skillStore.setEnabled(isEnabled, for: skillID)
            message = nil
            return true
        } catch {
            message = SkillManagementMessage(text: "无法更新启用状态：\(error.localizedDescription)", isError: true)
            return false
        }
    }

    @discardableResult
    private func save(_ editedSkill: UserSkill) -> Bool {
        var skill = editedSkill
        skill.name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skill.name.isEmpty else {
            message = SkillManagementMessage(text: "技能名称不能为空", isError: true)
            return false
        }
        skill.registeredKeyword = skill.registeredKeyword?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard skill.registeredKeyword?.isEmpty == false else {
            message = SkillManagementMessage(text: "唯一索引不能为空", isError: true)
            return false
        }
        if let keyword = skill.registeredKeyword {
            skill.aliases.removeAll { $0.compare(keyword, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        if let originalSkill = skillStore.skills.first(where: { $0.id == skill.id }) {
            skill = migratingParameterReferences(from: originalSkill, to: skill)
        }
        let parameterNames = skill.resolvedParameters.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parameterNames.allSatisfy({ !$0.isEmpty }) else {
            message = SkillManagementMessage(text: "参数名称不能为空", isError: true)
            return false
        }
        guard Set(parameterNames).count == parameterNames.count else {
            message = SkillManagementMessage(text: "参数名称不能重复", isError: true)
            return false
        }
        if skill.resolvedExecutionMode.allowsCloudModel {
            guard let prompt = skill.modelTask?.promptTemplate,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                message = SkillManagementMessage(text: "云端 AI 技能必须填写运行时提示词", isError: true)
                return false
            }
            var inputVariables = skill.resolvedParameters.map(\.id)
            if prompt.contains("{{userInput}}") {
                inputVariables.append("userInput")
            }
            skill.modelTask?.inputVariables = Array(Set(inputVariables)).sorted()
            if !skill.requiredTools.contains("model.generateText") {
                skill.requiredTools.append("model.generateText")
            }
            if !skill.permissions.contains("cloud_api") {
                skill.permissions.append("cloud_api")
            }
        }
        skill.trigger = "用户输入 \(skill.executionExample)"
        skill.updatedAt = Date()
        do {
            try skillStore.save(skill)
            message = SkillManagementMessage(text: "已保存", isError: false)
            return true
        } catch {
            message = SkillManagementMessage(text: error.localizedDescription, isError: true)
            return false
        }
    }

    private func migratingParameterReferences(from original: UserSkill, to edited: UserSkill) -> UserSkill {
        let originalNames = original.resolvedParameters.reduce(into: [String: String]()) { result, parameter in
            if result[parameter.id] == nil { result[parameter.id] = parameter.name }
        }
        let replacements = edited.resolvedParameters.reduce(into: [String: String]()) { result, parameter in
            guard let oldName = originalNames[parameter.id], oldName != parameter.name else { return }
            result[oldName] = parameter.name
        }
        guard !replacements.isEmpty else { return edited }

        var migrated = edited
        if var modelTask = migrated.modelTask {
            modelTask.promptTemplate = modelTask.promptTemplate
                .replacingSkillParameterPlaceholders(replacements)
            modelTask.inputVariables = modelTask.inputVariables.map { replacements[$0] ?? $0 }
            migrated.modelTask = modelTask
        }
        migrated.workflow = migrated.workflow?.map { step in
            var migratedStep = step
            migratedStep.arguments = step.arguments.mapValues {
                $0.replacingParameterReferences(replacements)
            }
            return migratedStep
        }
        if var workflowV3 = migrated.workflowV3 {
            for index in workflowV3.steps.indices {
                if let prompt = workflowV3.steps[index].promptTemplate {
                    workflowV3.steps[index].promptTemplate = prompt
                        .replacingSkillParameterPlaceholders(replacements)
                }
                workflowV3.steps[index].arguments = workflowV3.steps[index].arguments.mapValues {
                    $0.replacingSkillParameterPlaceholders(replacements)
                }
            }
            migrated.workflowV3 = workflowV3
        }
        return migrated
    }

    private func delete(_ skill: UserSkill) {
        do {
            try skillStore.delete(skill)
            skillPendingDeletion = nil
            if editingSkillID == skill.id { editingSkillID = nil }
            if forwardEditingSkillID == skill.id { forwardEditingSkillID = nil }
            message = SkillManagementMessage(text: "已删除 \(skill.name)", isError: false)
        } catch {
            message = SkillManagementMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func export(_ skill: UserSkill) {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出技能")
        panel.prompt = String(localized: "导出")
        panel.nameFieldStringValue = "\(safeFilename(skill.name)).bsk"
        panel.allowedContentTypes = [UTType(filenameExtension: "bsk") ?? .json]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try skillStore.exportPackageData(for: skill)
                try data.write(to: url, options: .atomic)
                message = SkillManagementMessage(text: "已导出 \(url.lastPathComponent)", isError: false)
                AppConsole.shared.success("技能已导出：\(url.path)", category: "SkillStore")
            } catch {
                message = SkillManagementMessage(text: "导出失败：\(error.localizedDescription)", isError: true)
                AppConsole.shared.error("技能导出失败：\(error.localizedDescription)", category: "SkillStore")
            }
        }
    }

    private var selectedSkills: [UserSkill] {
        skillStore.skills.filter { selectedSkillIDs.contains($0.id) }
    }

    private func deleteSelectedSkills() {
        let skills = selectedSkills
        do {
            for skill in skills {
                try skillStore.delete(skill)
            }
            message = SkillManagementMessage(text: "已删除 \(skills.count) 项技能", isError: false)
            leaveSelectionMode()
        } catch {
            message = SkillManagementMessage(text: "批量删除失败：\(error.localizedDescription)", isError: true)
            selectedSkillIDs.formIntersection(Set(skillStore.skills.map(\.id)))
        }
    }

    private func exportSelectedSkills() {
        let skills = selectedSkills
        guard !skills.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = String(localized: "选择批量导出位置")
        panel.prompt = String(localized: "导出到此处")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            do {
                for skill in skills {
                    let url = availableExportURL(
                        in: directory,
                        filename: safeFilename(skill.name),
                        pathExtension: "bsk"
                    )
                    let data = try skillStore.exportPackageData(for: skill)
                    try data.write(to: url, options: .atomic)
                }
                message = SkillManagementMessage(text: "已导出 \(skills.count) 项技能", isError: false)
                AppConsole.shared.success("批量导出 \(skills.count) 项技能到：\(directory.path)", category: "SkillStore")
            } catch {
                message = SkillManagementMessage(text: "批量导出失败：\(error.localizedDescription)", isError: true)
                AppConsole.shared.error("技能批量导出失败：\(error.localizedDescription)", category: "SkillStore")
            }
        }
    }

    private func availableExportURL(in directory: URL, filename: String, pathExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(filename).appendingPathExtension(pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(filename)-\(suffix)")
                .appendingPathExtension(pathExtension)
            suffix += 1
        }
        return candidate
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return components.joined(separator: "-").isEmpty ? "Briskill-Skill" : components.joined(separator: "-")
    }
}

private struct SkillManagementRow: View {
    let skill: UserSkill
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: executionSymbol)
                .foregroundStyle(skill.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(skill.name)
                .lineLimit(1)
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 14)

            Text(skill.executionExample)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var executionSymbol: String {
        switch skill.resolvedExecutionMode {
        case .local: "desktopcomputer"
        case .hybrid: "arrow.triangle.2.circlepath"
        case .cloud: "cloud"
        }
    }
}

struct SkillManagementMessage {
    let text: String
    let isError: Bool
}

private extension SkillWorkflowBinding {
    func replacingSkillParameterPlaceholders(
        _ replacements: [String: String]
    ) -> SkillWorkflowBinding {
        switch self {
        case .template(let value):
            return .template(value.replacingSkillParameterPlaceholders(replacements))
        case .array(let values):
            return .array(values.map {
                $0.replacingSkillParameterPlaceholders(replacements)
            })
        case .object(let values):
            return .object(values.mapValues {
                $0.replacingSkillParameterPlaceholders(replacements)
            })
        case .userInput, .parameter, .stepOutput, .literal:
            return self
        }
    }
}

private struct AIProviderSettingsView: View {
    @ObservedObject private var settings = AISettingsStore.shared
    @Binding var detailProvider: AIProvider?

    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var hasStoredAPIKey = false
    @State private var availableModels: [String] = []
    @State private var balanceText = "—"
    @State private var isRefreshingMetadata = false
    @State private var isTesting = false
    @State private var status: ConnectionStatus?
    @State private var draggedProvider: AIProvider?

    private let connectionControlWidth: CGFloat = 330

    private var activeProvider: AIProvider {
        detailProvider ?? settings.selectedProvider
    }

    var body: some View {
        Form {
            if detailProvider == nil {
                Section {
                    ForEach(Array(settings.providerOrder.enumerated()), id: \.element) { index, provider in
                        providerPriorityRow(provider, index: index)
                            .onDrop(
                                of: [UTType.text],
                                delegate: AIProviderDropDelegate(
                                    target: provider,
                                    draggedProvider: $draggedProvider,
                                    move: settings.moveProvider
                                )
                            )
                    }
                } header: {
                    HStack {
                        Text("服务优先级")
                        Spacer()
                        Menu {
                            ForEach(settings.removedProviders) { provider in
                                Button(provider.displayName) {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        settings.restoreProvider(provider)
                                    }
                                }
                            }
                            if settings.removedProviders.isEmpty {
                                Text("没有可添加的服务")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 22, height: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("添加 AI 服务")
                    }
                }
            }

            if detailProvider != nil {
                Section {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                        Text(apiKeyStorageNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasStoredAPIKey {
                        Button("管理", action: manageAPIKey)
                            .buttonStyle(.bordered)
                            .tint(.primary)
                            .foregroundStyle(.primary)
                    } else {
                        SecureField("", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: connectionControlWidth)
                    }
                }

                LabeledContent("选择模型") {
                    if modelPickerOptions.isEmpty {
                        Text("保存密钥后自动获取")
                            .foregroundStyle(.secondary)
                            .frame(width: connectionControlWidth, alignment: .trailing)
                    } else {
                        Picker("选择模型", selection: $model) {
                            ForEach(modelPickerOptions, id: \.self) { modelID in
                                Text(modelID).tag(modelID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .foregroundStyle(.primary)
                        .frame(width: connectionControlWidth, alignment: .trailing)
                    }
                }

                LabeledContent("API 地址") {
                    if activeProvider == .custom {
                        TextField(
                            "API 地址",
                            text: $endpoint,
                            prompt: Text("https://example.com/v1")
                                .foregroundStyle(.tertiary)
                        )
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: connectionControlWidth)
                    } else {
                        Text(endpoint)
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(width: connectionControlWidth, alignment: .trailing)
                    }
                }

                if activeProvider.supportsBalanceLookup {
                    LabeledContent("可用余额") {
                        HStack(spacing: 7) {
                            if isRefreshingMetadata {
                                ProgressView().controlSize(.small)
                            }
                            Text(balanceText)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: connectionControlWidth, alignment: .trailing)
                    }
                }

                HStack {
                    if let status {
                        Label(
                            status.text,
                            systemImage: status.isError
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.red : Color.green)
                        .lineLimit(2)
                    }

                    Spacer()

                    Button("恢复默认") {
                        let defaults = AIProviderConfiguration.defaults(for: activeProvider)
                        endpoint = defaults.endpoint
                        model = settings.availableModels(for: activeProvider).contains(defaults.model)
                            ? defaults.model
                            : settings.availableModels(for: activeProvider).first ?? ""
                        balanceText = "—"
                        status = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .foregroundStyle(.primary)

                    Button {
                        testConnection()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 70)
                        } else {
                            Text("保存并测试")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isTesting
                            || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            } header: {
                HStack {
                    Text("连接配置")
                    Spacer()
                    Button {
                        Task { await refreshProviderMetadata() }
                    } label: {
                        if isRefreshingMetadata {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(
                        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isRefreshingMetadata
                    )
                    .help("刷新模型与账户信息")
                }
            }

            if activeProvider.isOfficial {
                Section("官方入口") {
                    if let consoleURL = activeProvider.consoleURL {
                        browserLinkRow(
                            providerConsoleTitle,
                            detail: providerConsoleDetail,
                            url: consoleURL
                        )
                    }
                    if let apiKeyURL = activeProvider.apiKeyURL {
                        browserLinkRow("创建或管理 API Key", detail: "使用系统默认浏览器打开官方密钥页面。", url: apiKeyURL)
                    }
                    if let usageURL = activeProvider.usageURL {
                        browserLinkRow(providerUsageTitle, detail: providerUsageDetail, url: usageURL)
                    }
                }
            } else {
                Section("第三方服务说明") {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        Text("提示词、文件内容和对话记录会发送到这个 API 地址，请只使用你信任的服务。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.settingsPaneBackground)
        .onAppear(perform: loadSelectedProvider)
        .task { await refreshAllConfiguredModels() }
        .onChange(of: detailProvider) {
            loadSelectedProvider()
        }
    }

    private func providerPriorityRow(_ provider: AIProvider, index: Int) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 28)
                .contentShape(Rectangle())
                .onDrag {
                    draggedProvider = provider
                    return NSItemProvider(object: provider.rawValue as NSString)
                } preview: {
                    providerDragPreview(provider, index: index)
                }

            Text("\(index + 1)")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Button {
                settings.selectedProvider = provider
                detailProvider = provider
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(provider.displayName)
                                .fontWeight(.medium)
                            if index == 0 {
                                Text("首选")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(providerStatusText(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(settings.configuration(for: provider).model)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 210, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    settings.removeProvider(provider)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("删除服务")

            Button {
                settings.selectedProvider = provider
                detailProvider = provider
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
        }
        .opacity(draggedProvider == provider ? 0.2 : 1)
        .animation(.easeOut(duration: 0.14), value: draggedProvider)
    }

    private func providerStatusText(_ provider: AIProvider) -> String {
        if settings.isConfigured(provider) { return String(localized: "已配置 · 可参与自动顺延") }
        return String(localized: "尚未配置")
    }

    private func providerDragPreview(_ provider: AIProvider, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .fontWeight(.semibold)
                Text(providerStatusText(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 30)
            Text(settings.configuration(for: provider).model)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(width: 520, height: 58)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private func loadSelectedProvider() {
        guard detailProvider != nil else { return }
        let configuration = settings.configuration(for: activeProvider)
        endpoint = configuration.endpoint
        model = configuration.model
        apiKey = settings.apiKey(for: activeProvider)
        hasStoredAPIKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        availableModels = settings.availableModels(for: activeProvider)
        if !model.isEmpty, !availableModels.contains(model) { availableModels.insert(model, at: 0) }
        balanceText = "—"
        status = nil
        if hasStoredAPIKey, settings.apiKeyStorageMode == .keychain {
            try? KeychainStore.save(apiKey, account: activeProvider.rawValue)
        }
        if hasStoredAPIKey {
            Task { await refreshProviderMetadata() }
        }
    }

    private var modelPickerOptions: [String] {
        var values = availableModels
        if !model.isEmpty, !values.contains(model) { values.insert(model, at: 0) }
        if values.isEmpty, !activeProvider.defaultModel.isEmpty {
            values = [activeProvider.defaultModel]
        }
        return values
    }

    private var providerConsoleTitle: String {
        switch activeProvider {
        case .deepSeek: String(localized: "打开 DeepSeek 开放平台")
        case .glm: String(localized: "打开智谱开放平台")
        case .gemini: String(localized: "打开 Google AI Studio")
        case .openAI: String(localized: "打开 OpenAI Platform")
        case .custom: ""
        }
    }

    private var providerConsoleDetail: String {
        switch activeProvider {
        case .deepSeek: String(localized: "在浏览器中进行对话、充值或管理开放平台账户。")
        case .glm: String(localized: "在浏览器中查看模型、资源包和账户配置。")
        case .gemini: String(localized: "在浏览器中生成提示、测试模型和管理项目。")
        case .openAI: String(localized: "在浏览器中管理 API 项目和开发配置。")
        case .custom: ""
        }
    }

    private var providerUsageTitle: String {
        activeProvider == .deepSeek
            ? String(localized: "查看用量与充值")
            : String(localized: "查看用量与结算")
    }

    private var providerUsageDetail: String {
        switch activeProvider {
        case .deepSeek: String(localized: "查看 API 消耗明细并为账户充值。")
        case .glm: String(localized: "余额、资源包和账单由智谱控制台管理。")
        case .gemini: String(localized: "Gemini 的免费额度、预付费和后付费由 AI Studio 管理。")
        case .openAI: String(localized: "普通 API Key 不读取组织账单，请在官方页面查看费用。")
        case .custom: ""
        }
    }

    private func browserLinkRow(_ title: String, detail: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var apiKeyStorageNote: String {
        settings.apiKeyStorageMode == .keychain
            ? String(localized: "密钥保存在这台 Mac 的钥匙串。")
            : String(localized: "密钥保存在本机 Application Support。")
    }

    private func manageAPIKey() {
        if settings.apiKeyStorageMode == .localFile {
            guard let url = settings.localAPIKeyFileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            status = ConnectionStatus(text: "已在 Finder 中显示 API Key 文件", isError: false)
            return
        }
        if KeychainStore.openKeychainAccess() {
            status = ConnectionStatus(
                text: String(
                    format: String(localized: "已打开钥匙串访问，请搜索“%@”。"),
                    KeychainStore.searchableLabel(account: activeProvider.rawValue)
                ),
                isError: false
            )
        } else {
            status = ConnectionStatus(text: String(localized: "无法打开钥匙串访问。"), isError: true)
        }
    }

    @MainActor
    private func refreshProviderMetadata() async {
        let provider = activeProvider
        let storedKey = settings.apiKey(for: provider)
        if !storedKey.isEmpty {
            apiKey = storedKey
            hasStoredAPIKey = true
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isRefreshingMetadata = true
        defer { isRefreshingMetadata = false }
        do {
            let models: [String]
            if provider == .deepSeek {
                let metadata = try await AIService.shared.fetchDeepSeekAccountMetadata(
                    endpoint: endpoint,
                    apiKey: apiKey
                )
                models = metadata.models
                balanceText = formattedBalance(metadata)
            } else {
                models = try await AIService.shared.fetchAvailableModels(
                    provider: provider,
                    endpoint: endpoint,
                    apiKey: apiKey
                )
            }
            guard detailProvider == provider else { return }
            settings.updateAvailableModels(models, for: provider)
            availableModels = settings.availableModels(for: provider)
            if !availableModels.contains(model), let firstModel = availableModels.first {
                model = firstModel
            }
            status = nil
        } catch {
            status = ConnectionStatus(text: error.localizedDescription, isError: true)
        }
    }

    @MainActor
    private func refreshAllConfiguredModels() async {
        for provider in settings.providerOrder where settings.isConfigured(provider) {
            let configuration = settings.configuration(for: provider)
            let key = settings.apiKey(for: provider)
            do {
                let models: [String]
                if provider == .deepSeek {
                    models = try await AIService.shared.fetchDeepSeekAccountMetadata(
                        endpoint: configuration.endpoint,
                        apiKey: key
                    ).models
                } else {
                    models = try await AIService.shared.fetchAvailableModels(
                        provider: provider,
                        endpoint: configuration.endpoint,
                        apiKey: key
                    )
                }
                settings.updateAvailableModels(models, for: provider)
            } catch {
                AppConsole.shared.warning(
                    "刷新 \(provider.displayName) 模型目录失败，继续使用本地缓存：\(error.localizedDescription)",
                    category: "Models"
                )
            }
        }
        loadSelectedProvider()
    }

    private func formattedBalance(_ metadata: DeepSeekAccountMetadata) -> String {
        guard !metadata.balances.isEmpty else {
            return metadata.isAvailable ? String(localized: "可用") : String(localized: "不可用")
        }
        return metadata.balances.map { balance in
            let symbol: String
            switch balance.currency.uppercased() {
            case "CNY": symbol = "¥"
            case "USD": symbol = "$"
            default: symbol = "\(balance.currency) "
            }
            return "\(symbol)\(balance.totalBalance)"
        }
        .joined(separator: " · ")
    }

    private func testConnection() {
        let provider = activeProvider
        isTesting = true
        status = nil
        Task {
            do {
                try settings.saveAPIKey(apiKey, for: provider)
                hasStoredAPIKey = true
                do {
                    let refreshedModels = try await AIService.shared.fetchAvailableModels(
                        provider: provider,
                        endpoint: endpoint,
                        apiKey: apiKey
                    )
                    settings.updateAvailableModels(refreshedModels, for: provider)
                } catch {
                    guard !settings.availableModels(for: provider).isEmpty else { throw error }
                    AppConsole.shared.warning(
                        "\(provider.displayName) 没有返回模型目录，连接测试继续使用缓存模型：\(error.localizedDescription)",
                        category: "Models"
                    )
                }
                availableModels = settings.availableModels(for: provider)
                if !availableModels.contains(model) {
                    model = availableModels.first ?? ""
                }
                guard !model.isEmpty else {
                    throw AIServiceError.invalidConfiguration("没有获取到可用于生成内容的模型")
                }
                settings.update(
                    AIProviderConfiguration(
                        endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                        model: model
                    ),
                    for: provider
                )
                let reply = try await AIService.shared.testConnection(provider: provider)
                status = ConnectionStatus(text: "连接成功 · \(reply.prefix(40))", isError: false)
                if provider == .deepSeek {
                    await refreshProviderMetadata()
                }
            } catch {
                status = ConnectionStatus(text: error.localizedDescription, isError: true)
            }
            isTesting = false
        }
    }
}

private struct AIProviderDropDelegate: DropDelegate {
    let target: AIProvider
    @Binding var draggedProvider: AIProvider?
    let move: (AIProvider, AIProvider) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedProvider, draggedProvider != target else { return }
        withAnimation(.snappy(duration: 0.18)) {
            move(draggedProvider, target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedProvider = nil
        return true
    }
}

private struct ConnectionStatus {
    let text: String
    let isError: Bool
}

private struct SettingsKeyCap: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

#Preview {
    SettingsView()
}
