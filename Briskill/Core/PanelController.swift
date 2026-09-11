import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    static let assistantPanelShouldFocusSearch = Notification.Name(
        "Briskill.assistantPanelShouldFocusSearch"
    )
    static let assistantPanelShouldCancelGeneration = Notification.Name(
        "Briskill.assistantPanelShouldCancelGeneration"
    )
    static let assistantPanelShouldResumeConversation = Notification.Name(
        "Briskill.assistantPanelShouldResumeConversation"
    )
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: AssistantPanel?
    private let positionPreferenceKey = MainPanelPositionPreference.defaultsKey
    private let savedOriginXKey = "assistantPanel.origin.x"
    private let savedOriginYKey = "assistantPanel.origin.y"
    private let automaticInputSourceSwitchingKey = "automaticInputSourceSwitching"
    private let inputSourceSession = KeyboardInputSourceSession()
    private var isInteractionPinned = false
    private var isPerformingSystemInteraction = false
    private var isGenerationActive = false
    private var conversationBackspaceHandler: (() -> Bool)?

    /// Builds and lays out the expensive SwiftUI panel before the first hot-key
    /// invocation. The window stays hidden, so prewarming has no visible side
    /// effects and subsequent presentations can be immediate.
    func prepare() {
        guard panel == nil else { return }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let preparedPanel = makePanel()
        self.panel = preparedPanel

        switch positionPreference {
        case .screenTopCenter:
            positionAtDefaultLocation(preparedPanel)
        case .rememberLast:
            restorePositionOrUseDefault(preparedPanel)
        }

        preparedPanel.contentView?.layoutSubtreeIfNeeded()
        inputSourceSession.prepareEnglishInputSource()

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        AppConsole.shared.info(
            "主面板预热完成，耗时 \(String(format: "%.3f", elapsed)) 秒",
            category: "Performance"
        )
    }

    func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            inputSourceSession.restore()
            AppConsole.shared.info("快捷面板已通过快捷键隐藏", category: "Panel")
        } else {
            show()
        }
    }

    func show() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let panel: AssistantPanel
        if let existingPanel = self.panel {
            panel = existingPanel
        } else {
            panel = makePanel()
            self.panel = panel
        }

        switch positionPreference {
        case .screenTopCenter:
            positionAtDefaultLocation(panel)
        case .rememberLast:
            restorePositionOrUseDefault(panel)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let wasAlreadyKey = panel.isKeyWindow
        panel.makeKeyAndOrderFront(nil)
        if wasAlreadyKey {
            scheduleSearchFocus(for: panel)
        }

        // Third-party input methods can make TISSelectInputSource noticeably
        // slow. Order the panel first, then switch input source after AppKit has
        // had a chance to commit the first frame.
        if automaticInputSourceSwitchingEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak panel] in
                guard let self, let panel, panel === self.panel, panel.isVisible else { return }
                self.inputSourceSession.beginInEnglish()
            }
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        AppConsole.shared.info(
            "快捷面板已显示，等待窗口激活后聚焦输入框；呼出耗时 \(String(format: "%.3f", elapsed)) 秒",
            category: "Panel"
        )
    }

    func resumeConversation(_ record: InvocationRecord) {
        show()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            NotificationCenter.default.post(
                name: .assistantPanelShouldResumeConversation,
                object: record
            )
        }
    }

    func prepareForTermination() {
        inputSourceSession.restore()
    }

    func prepareForCommandInput() {
        guard automaticInputSourceSwitchingEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            self.inputSourceSession.selectEnglish()
        }
    }

    func prepareForParameterInput(_ type: SkillParameterType) {
        guard automaticInputSourceSwitchingEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            switch type {
            case .text, .paragraph:
                self.inputSourceSession.selectPrevious()
                AppConsole.shared.info(
                    "下一参数为\(type.displayName)，已恢复唤起面板前的输入法",
                    category: "InputSource"
                )
            case .file, .image, .folder, .number, .boolean:
                self.inputSourceSession.selectEnglish()
                AppConsole.shared.info(
                    "下一参数为\(type.displayName)，继续使用英文输入源",
                    category: "InputSource"
                )
            }
        }
    }

    func setInteractionPinned(_ pinned: Bool) {
        isInteractionPinned = pinned
        panel?.hidesOnDeactivate = !pinned
        AppConsole.shared.info(
            pinned ? "快捷面板已临时固定，可从 Finder 拖入文件" : "快捷面板已恢复失焦自动隐藏",
            category: "Panel"
        )
    }

    func setGenerationActive(_ active: Bool) {
        isGenerationActive = active
    }

    func setConversationBackspaceHandler(_ handler: (() -> Bool)?) {
        conversationBackspaceHandler = handler
    }

    func hideForSystemInteraction() {
        isPerformingSystemInteraction = true
        panel?.orderOut(nil)
        AppConsole.shared.info("快捷面板为系统交互临时隐藏", category: "Panel")
    }

    func restoreAfterSystemInteraction() {
        guard isPerformingSystemInteraction else { return }
        isPerformingSystemInteraction = false
        show()
    }

    private func makePanel() -> AssistantPanel {
        let panel = AssistantPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 510),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.tabbingMode = .disallowed
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.cancelHandler = { [weak self] in
            guard self?.isGenerationActive == true else { return false }
            NotificationCenter.default.post(name: .assistantPanelShouldCancelGeneration, object: nil)
            return true
        }
        panel.backspaceHandler = { [weak self] in
            self?.conversationBackspaceHandler?() == true
        }
        panel.contentView = NSHostingView(rootView: AssistantPanelView())
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel else {
            return
        }
        guard !isInteractionPinned else { return }
        guard !isPerformingSystemInteraction else { return }
        inputSourceSession.restore()
        window.orderOut(nil)
        AppConsole.shared.info("快捷面板失去焦点并隐藏", category: "Panel")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel else { return }

        scheduleSearchFocus(for: window)
    }

    private func scheduleSearchFocus(for window: NSWindow) {
        // makeKeyAndOrderFront can complete before SwiftUI has restored its
        // responder chain. Defer one run-loop turn and ask the view to reset
        // FocusState before focusing again on every presentation.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  window === self.panel,
                  window.isVisible,
                  window.isKeyWindow else { return }
            NotificationCenter.default.post(name: .assistantPanelShouldFocusSearch, object: window)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel else { return }
        UserDefaults.standard.set(window.frame.origin.x, forKey: savedOriginXKey)
        UserDefaults.standard.set(window.frame.origin.y, forKey: savedOriginYKey)
    }

    private func restorePositionOrUseDefault(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: savedOriginXKey) != nil,
              defaults.object(forKey: savedOriginYKey) != nil else {
            positionAtDefaultLocation(panel)
            return
        }

        panel.setFrameOrigin(
            NSPoint(
                x: defaults.double(forKey: savedOriginXKey),
                y: defaults.double(forKey: savedOriginYKey)
            )
        )
        keepOnAvailableScreen(panel)
    }

    private func positionAtDefaultLocation(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - 72
        )
        panel.setFrameOrigin(origin)
    }

    private func keepOnAvailableScreen(_ panel: NSPanel) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let currentFrame = panel.frame
        let bestScreen = screens.max { lhs, rhs in
            intersectionArea(currentFrame, lhs.visibleFrame) < intersectionArea(currentFrame, rhs.visibleFrame)
        }
        guard let bestScreen,
              intersectionArea(currentFrame, bestScreen.visibleFrame) > 0 else {
            positionAtDefaultLocation(panel)
            return
        }

        let visibleFrame = bestScreen.visibleFrame.insetBy(dx: 10, dy: 10)
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - currentFrame.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - currentFrame.height)
        let clampedOrigin = NSPoint(
            x: min(max(currentFrame.origin.x, visibleFrame.minX), maximumX),
            y: min(max(currentFrame.origin.y, visibleFrame.minY), maximumY)
        )
        if clampedOrigin != currentFrame.origin {
            panel.setFrameOrigin(clampedOrigin)
        }
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private var automaticInputSourceSwitchingEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: automaticInputSourceSwitchingKey) != nil else {
            return true
        }
        return defaults.bool(forKey: automaticInputSourceSwitchingKey)
    }

    private var positionPreference: MainPanelPositionPreference {
        guard let rawValue = UserDefaults.standard.string(forKey: positionPreferenceKey),
              let preference = MainPanelPositionPreference(rawValue: rawValue) else {
            return .screenTopCenter
        }
        return preference
    }
}

enum MainPanelPositionPreference: String, CaseIterable, Identifiable {
    case screenTopCenter
    case rememberLast

    static let defaultsKey = "assistantPanel.positionPreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenTopCenter:
            String(localized: "屏幕中央上方")
        case .rememberLast:
            String(localized: "记忆上次位置")
        }
    }
}

private final class KeyboardInputSourceSession {
    private var previousInputSource: TISInputSource?
    private var cachedEnglishInputSource: TISInputSource?

    func prepareEnglishInputSource() {
        guard cachedEnglishInputSource == nil else { return }
        cachedEnglishInputSource = TISCopyInputSourceForLanguage("en" as CFString)?.takeRetainedValue()
    }

    func beginInEnglish() {
        if previousInputSource == nil,
           let currentInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            previousInputSource = currentInputSource
        }
        selectEnglish()
    }

    func selectEnglish() {
        prepareEnglishInputSource()
        guard let englishInputSource = cachedEnglishInputSource else { return }
        TISSelectInputSource(englishInputSource)
    }

    func selectPrevious() {
        guard let previousInputSource else { return }
        TISSelectInputSource(previousInputSource)
    }

    func restore() {
        guard let previousInputSource else { return }
        TISSelectInputSource(previousInputSource)
        self.previousInputSource = nil
    }
}

final class AssistantPanel: NSPanel {
    var cancelHandler: (() -> Bool)?
    var backspaceHandler: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if cancelHandler?() == true {
            return
        }
        orderOut(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == UInt16(kVK_Delete),
           backspaceHandler?() == true {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window

        DockIconController.shared.retain(for: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        AppConsole.shared.info("设置窗口已打开", category: "Settings")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = String(localized: "Briskill 设置")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        // Keep controls and text in the full-size content view interactive.
        // The native titlebar remains the only window dragging region.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 520)
        window.setFrameAutosaveName("Briskill.SettingsWindow")
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView())
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DockIconController.shared.release(for: "settings")
        AppConsole.shared.info("设置窗口已关闭", category: "Settings")
    }
}
