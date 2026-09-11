import AppKit
import Carbon.HIToolbox
import CryptoKit
import LocalAuthentication
import SwiftUI

extension Notification.Name {
    static let assistantShortcutConfigurationDidChange = Notification.Name(
        "Briskill.assistantShortcutConfigurationDidChange"
    )
    static let clipboardShortcutConfigurationDidChange = Notification.Name(
        "Briskill.clipboardShortcutConfigurationDidChange"
    )
}

enum ClipboardItemAction: String, CaseIterable, Identifiable {
    case copy
    case paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: String(localized: "设为当前剪贴板")
        case .paste: String(localized: "直接粘贴到原应用")
        }
    }

    var opposite: ClipboardItemAction {
        self == .copy ? .paste : .copy
    }
}

enum ClipboardRowDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: String(localized: "小")
        case .comfortable: String(localized: "中")
        case .spacious: String(localized: "大")
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 32
        case .comfortable: 64
        case .spacious: 94
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .compact: 0
        case .comfortable: 7
        case .spacious: 10
        }
    }
}

enum ClipboardPanelPosition: String, CaseIterable, Identifiable {
    case nearCursor
    case lastLocation
    case topCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearCursor: String(localized: "光标旁")
        case .lastLocation: String(localized: "上次打开位置")
        case .topCenter: String(localized: "屏幕上方中央")
        }
    }
}

enum ClipboardRetentionPeriod: String, CaseIterable, Identifiable {
    case oneDay
    case threeDays
    case sevenDays
    case oneMonth
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDay: String(localized: "1 天")
        case .threeDays: String(localized: "3 天")
        case .sevenDays: String(localized: "7 天")
        case .oneMonth: String(localized: "一个月")
        case .forever: String(localized: "永久")
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .oneDay: 86_400
        case .threeDays: 3 * 86_400
        case .sevenDays: 7 * 86_400
        case .oneMonth: 30 * 86_400
        case .forever: nil
        }
    }
}

struct ClipboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = ClipboardShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | optionKey)
    )

    private static let storageKey = "clipboardManager.shortcut"
    private static let configuredKey = "clipboardManager.shortcutConfigured"

    var displayName: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += Self.keyName(for: keyCode)
        return value
    }

    static func load() -> ClipboardShortcut {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let shortcut = try? JSONDecoder().decode(ClipboardShortcut.self, from: data) else {
            return .default
        }
        return shortcut
    }

    static var isConfigured: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: configuredKey) == nil {
            return true
        }
        return defaults.bool(forKey: configuredKey)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        UserDefaults.standard.set(true, forKey: Self.configuredKey)
        NotificationCenter.default.post(name: .clipboardShortcutConfigurationDidChange, object: nil)
    }

    static func clear() {
        UserDefaults.standard.set(false, forKey: configuredKey)
        NotificationCenter.default.post(name: .clipboardShortcutConfigurationDidChange, object: nil)
    }

    static func from(_ event: NSEvent) -> ClipboardShortcut? {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard !flags.isEmpty else { return nil }
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        return ClipboardShortcut(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): String(localized: "空格"),
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→"
        ]
        return names[keyCode] ?? "#\(keyCode)"
    }
}

enum AssistantShortcut {
    static let `default` = ClipboardShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey)
    )

    private static let storageKey = "assistant.shortcut"
    private static let configuredKey = "assistant.shortcutConfigured"

    static func load() -> ClipboardShortcut {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let shortcut = try? JSONDecoder().decode(ClipboardShortcut.self, from: data) else {
            return .default
        }
        return shortcut
    }

    static func save(_ shortcut: ClipboardShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        UserDefaults.standard.set(true, forKey: configuredKey)
        NotificationCenter.default.post(name: .assistantShortcutConfigurationDidChange, object: nil)
    }

    static var isConfigured: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: configuredKey) == nil { return true }
        return defaults.bool(forKey: configuredKey)
    }

    static func clear() {
        UserDefaults.standard.set(false, forKey: configuredKey)
        NotificationCenter.default.post(name: .assistantShortcutConfigurationDidChange, object: nil)
    }
}

struct ClipboardShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: ClipboardShortcut
    @Binding var isConfigured: Bool
    var onShortcutChange: ((ClipboardShortcut) -> Void)? = nil
    var isShortcutAllowed: ((ClipboardShortcut) -> Bool)? = nil

    func makeNSView(context: Context) -> ClipboardShortcutRecorderView {
        let view = ClipboardShortcutRecorderView()
        view.shortcut = shortcut
        view.isConfigured = isConfigured
        view.onChange = { newShortcut in
            shortcut = newShortcut
            isConfigured = true
            if let onShortcutChange {
                onShortcutChange(newShortcut)
            } else {
                newShortcut.save()
            }
        }
        view.isShortcutAllowed = isShortcutAllowed
        return view
    }

    func updateNSView(_ nsView: ClipboardShortcutRecorderView, context: Context) {
        nsView.shortcut = shortcut
        nsView.isConfigured = isConfigured
        nsView.onChange = { newShortcut in
            shortcut = newShortcut
            isConfigured = true
            if let onShortcutChange {
                onShortcutChange(newShortcut)
            } else {
                newShortcut.save()
            }
        }
        nsView.isShortcutAllowed = isShortcutAllowed
        nsView.needsDisplay = true
    }
}

final class ClipboardShortcutRecorderView: NSView {
    var shortcut: ClipboardShortcut = .default
    var isConfigured = true
    var onChange: ((ClipboardShortcut) -> Void)?
    var isShortcutAllowed: ((ClipboardShortcut) -> Bool)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 22) }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }
        guard let candidate = ClipboardShortcut.from(event) else {
            NSSound.beep()
            return
        }
        if isShortcutAllowed?(candidate) == false {
            NSSound.beep()
            return
        }
        shortcut = candidate
        isRecording = false
        onChange?(candidate)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let string: String
        if isRecording {
            string = String(localized: "按下新快捷键…")
        } else if isConfigured {
            string = shortcut.displayName
        } else {
            string = String(localized: "未设置")
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = string.size(withAttributes: attributes)
        string.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

enum ClipboardHistoryContent: Codable, Equatable {
    case text(String)
    case files([String])
    case image(Data)
}

struct ClipboardHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    var content: ClipboardHistoryContent
    var createdAt: Date
    var sourceApplication: String?

    var title: String {
        switch content {
        case let .text(text):
            return text.replacingOccurrences(of: "\n", with: " ")
        case let .files(paths):
            if paths.count == 1 { return URL(fileURLWithPath: paths[0]).lastPathComponent }
            return String(format: String(localized: "%lld 个文件"), paths.count)
        case .image:
            return String(localized: "图片")
        }
    }

    var detail: String {
        switch content {
        case let .text(text):
            return String(format: String(localized: "%lld 个字符"), text.count)
        case let .files(paths):
            return paths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ""
        case let .image(data):
            guard let image = NSImage(data: data) else { return String(localized: "图像内容") }
            return "\(Int(image.size.width)) × \(Int(image.size.height))"
        }
    }

    var systemImage: String {
        switch content {
        case .text: "doc.text"
        case .files: "doc.on.doc"
        case .image: "photo"
        }
    }

    var kindTitle: String {
        switch content {
        case .text: String(localized: "文本")
        case let .files(paths):
            paths.count == 1 ? String(localized: "文件") : String(localized: "多个文件")
        case .image: String(localized: "图片")
        }
    }

    var previewImage: NSImage? {
        switch content {
        case let .image(data):
            return NSImage(data: data)
        case let .files(paths):
            guard paths.count == 1 else { return nil }
            let path = paths[0]
            let imageExtensions = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"]
            guard imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                return nil
            }
            return NSImage(contentsOfFile: path)
        case .text:
            return nil
        }
    }

    func relativeTime(at referenceDate: Date) -> String {
        let seconds = max(0, Int(referenceDate.timeIntervalSince(createdAt)))
        if seconds < 5 { return String(localized: "刚刚") }
        if seconds < 60 {
            return String(format: String(localized: "%lld 秒前"), seconds)
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(format: String(localized: "%lld 分钟前"), minutes)
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(format: String(localized: "%lld 小时前"), hours)
        }
        let days = hours / 24
        return String(format: String(localized: "%lld 天前"), days)
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var items: [ClipboardHistoryItem] = []
    @Published private(set) var fullHistoryItems: [ClipboardHistoryItem] = []
    @Published private(set) var isEnabled: Bool
    @Published private(set) var panelItemLimit: Int
    @Published private(set) var retentionPeriod: ClipboardRetentionPeriod
    @Published private(set) var isFullHistoryEnabled: Bool
    @Published private(set) var primaryClickAction: ClipboardItemAction
    @Published private(set) var isEncryptionEnabled: Bool
    @Published private(set) var requiresTouchID: Bool
    @Published private(set) var archivedItemCount = 0
    @Published private(set) var localStorageBytes: Int64 = 0
    @Published private(set) var securityMessage: String?
    @Published private(set) var securityMessageIsError = false

    private let defaults = UserDefaults.standard
    private let enabledKey = "clipboardManager.enabled"
    private let panelItemLimitKey = "clipboardManager.panelItemLimit"
    private let retentionPeriodKey = "clipboardManager.retentionPeriod"
    private let fullHistoryEnabledKey = "clipboardManager.fullHistoryEnabled"
    private let primaryActionKey = "clipboardManager.primaryClickAction"
    private let encryptionEnabledKey = "clipboardManager.historyEncryptionEnabled"
    private let touchIDRequiredKey = "clipboardManager.historyTouchIDRequired"
    private let archiveCountKey = "clipboardManager.archiveItemCount"
    private let splitStorageMigrationKey = "clipboardManager.splitStorageMigrated"
    private let encryptionKeyAccount = "clipboard-history-encryption-key"
    private var timer: Timer?
    private var observedChangeCount = -1
    private var lastMaintenanceDate = Date.distantPast
    private var isFullHistoryLoaded = false
    private var authenticationContext: LAContext?

    private init() {
        if defaults.object(forKey: enabledKey) == nil {
            defaults.set(true, forKey: enabledKey)
        }
        if defaults.object(forKey: panelItemLimitKey) == nil {
            defaults.set(50, forKey: panelItemLimitKey)
        }
        if defaults.object(forKey: retentionPeriodKey) == nil {
            defaults.set(ClipboardRetentionPeriod.sevenDays.rawValue, forKey: retentionPeriodKey)
        }
        if defaults.object(forKey: fullHistoryEnabledKey) == nil {
            defaults.set(true, forKey: fullHistoryEnabledKey)
        }
        isEnabled = defaults.bool(forKey: enabledKey)
        panelItemLimit = min(max(defaults.integer(forKey: panelItemLimitKey), 1), 200)
        retentionPeriod = ClipboardRetentionPeriod(
            rawValue: defaults.string(forKey: retentionPeriodKey) ?? ""
        ) ?? .sevenDays
        isFullHistoryEnabled = defaults.bool(forKey: fullHistoryEnabledKey)
        primaryClickAction = ClipboardItemAction(
            rawValue: defaults.string(forKey: primaryActionKey) ?? "copy"
        ) ?? .copy
        isEncryptionEnabled = defaults.bool(forKey: encryptionEnabledKey)
        requiresTouchID = defaults.bool(forKey: touchIDRequiredKey)
        load()
    }

    var secondaryClickAction: ClipboardItemAction { primaryClickAction.opposite }

    func startMonitoringIfEnabled() {
        guard isEnabled else { return }
        startMonitoring()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        if enabled {
            startMonitoring()
        } else {
            timer?.invalidate()
            timer = nil
        }
        NotificationCenter.default.post(name: .clipboardShortcutConfigurationDidChange, object: nil)
        AppConsole.shared.info(
            enabled ? "剪贴板管理已启用" : "剪贴板管理已停用",
            category: "Clipboard"
        )
    }

    func setPanelItemLimit(_ value: Int) {
        let sanitized = min(max(value, 1), 200)
        panelItemLimit = sanitized
        defaults.set(sanitized, forKey: panelItemLimitKey)
        pruneActiveItems()
    }

    func setRetentionPeriod(_ period: ClipboardRetentionPeriod) {
        retentionPeriod = period
        defaults.set(period.rawValue, forKey: retentionPeriodKey)
        pruneActiveItems()
    }

    func setFullHistoryEnabled(_ enabled: Bool) {
        isFullHistoryEnabled = enabled
        defaults.set(enabled, forKey: fullHistoryEnabledKey)
        pruneActiveItems()
        AppConsole.shared.info(
            enabled ? "完整剪贴板历史已启用" : "完整剪贴板历史已停用",
            category: "Clipboard"
        )
    }

    func setPrimaryClickAction(_ action: ClipboardItemAction) {
        primaryClickAction = action
        defaults.set(action.rawValue, forKey: primaryActionKey)
    }

    func setEncryptionEnabled(_ enabled: Bool) throws {
        guard enabled != isEncryptionEnabled else { return }
        let previousValue = isEncryptionEnabled
        let archive = try readArchive(encrypted: previousValue)
        let recent = try readRecent(encrypted: previousValue)
        isEncryptionEnabled = enabled
        do {
            try persistRecentThrowing(recent)
            try persistArchiveThrowing(archive)
            defaults.set(enabled, forKey: encryptionEnabledKey)
            if enabled {
                try? FileManager.default.removeItem(at: recentPlaintextStorageURL)
                try? FileManager.default.removeItem(at: plaintextStorageURL)
            } else {
                try? FileManager.default.removeItem(at: recentEncryptedStorageURL)
                try? FileManager.default.removeItem(at: encryptedStorageURL)
            }
            refreshStorageStatistics()
            securityMessage = enabled
                ? String(localized: "完整历史已经加密保存。")
                : String(localized: "完整历史已经迁移为普通本地文件。")
            securityMessageIsError = false
            AppConsole.shared.info(
                enabled ? "剪贴板历史加密已启用" : "剪贴板历史加密已关闭",
                category: "Clipboard"
            )
        } catch {
            isEncryptionEnabled = previousValue
            securityMessage = error.localizedDescription
            securityMessageIsError = true
            throw error
        }
    }

    func setTouchIDRequired(_ required: Bool) async -> Bool {
        if required || requiresTouchID {
            guard await authenticateWithTouchID(
                reason: required
                    ? String(localized: "启用身份验证保护完整剪贴板历史")
                    : String(localized: "关闭完整剪贴板历史的身份验证保护")
            ) else {
                return false
            }
        }
        requiresTouchID = required
        defaults.set(required, forKey: touchIDRequiredKey)
        securityMessage = required
            ? String(localized: "以后每次打开完整历史都需要 Touch ID 或锁屏密码。")
            : String(localized: "完整历史的身份验证保护已关闭。")
        securityMessageIsError = false
        return true
    }

    func authorizeFullHistoryAccess() async -> Bool {
        guard requiresTouchID else { return true }
        return await authenticateWithTouchID(
            reason: String(localized: "验证身份以查看完整剪贴板历史")
        )
    }

    func clearSecurityMessage() {
        securityMessage = nil
        securityMessageIsError = false
    }

    func prepareFullHistory() -> Bool {
        do {
            let archive = try readArchive(encrypted: isEncryptionEnabled)
            archivedItemCount = archive.count
            defaults.set(archive.count, forKey: archiveCountKey)
            isFullHistoryLoaded = true
            fullHistoryItems = mergedHistory(active: items, archive: archive)
            refreshStorageStatistics()
            return true
        } catch {
            securityMessage = String(
                format: String(localized: "读取剪贴板历史失败：%@"),
                error.localizedDescription
            )
            securityMessageIsError = true
            return false
        }
    }

    func releaseFullHistory() {
        isFullHistoryLoaded = false
        fullHistoryItems.removeAll(keepingCapacity: false)
    }

    func remove(_ item: ClipboardHistoryItem) {
        items.removeAll { $0.id == item.id }
        do {
            var archive = try readArchive(encrypted: isEncryptionEnabled)
            archive.removeAll { $0.id == item.id }
            try persistRecentThrowing(items)
            try persistArchiveThrowing(archive)
            updateLoadedFullHistory(archive: archive)
        } catch {
            AppConsole.shared.error("删除剪贴板历史失败：\(error.localizedDescription)", category: "Clipboard")
        }
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        do {
            var archive = try readArchive(encrypted: isEncryptionEnabled)
            archive.removeAll { ids.contains($0.id) }
            try persistRecentThrowing(items)
            try persistArchiveThrowing(archive)
            updateLoadedFullHistory(archive: archive)
            AppConsole.shared.info("批量删除了 \(ids.count) 条剪贴板历史", category: "Clipboard")
        } catch {
            AppConsole.shared.error("批量删除剪贴板历史失败：\(error.localizedDescription)", category: "Clipboard")
        }
    }

    func clear() {
        items.removeAll()
        do {
            try persistRecentThrowing([])
            try persistArchiveThrowing([])
            updateLoadedFullHistory(archive: [])
            AppConsole.shared.info("已清空剪贴板历史", category: "Clipboard")
        } catch {
            AppConsole.shared.error("清空剪贴板历史失败：\(error.localizedDescription)", category: "Clipboard")
        }
    }

    func putOnPasteboard(_ item: ClipboardHistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.content {
        case let .text(text):
            pasteboard.setString(text, forType: .string)
        case let .files(paths):
            pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        case let .image(data):
            pasteboard.setData(data, forType: .tiff)
        }
        observedChangeCount = pasteboard.changeCount
        promote(item)
        AppConsole.shared.info("已恢复一条剪贴板历史", category: "Clipboard")
    }

    private func startMonitoring() {
        guard timer == nil else { return }
        observedChangeCount = -1
        captureIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureIfNeeded()
                self?.performPeriodicMaintenanceIfNeeded()
            }
        }
    }

    private func captureIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != observedChangeCount else { return }
        observedChangeCount = pasteboard.changeCount
        guard let content = readContent(from: pasteboard) else { return }

        if let duplicate = items.first(where: { $0.content == content }) {
            promote(duplicate)
            return
        }
        let item = ClipboardHistoryItem(
            id: UUID(),
            content: content,
            createdAt: Date(),
            sourceApplication: NSWorkspace.shared.frontmostApplication?.localizedName
        )
        items.insert(item, at: 0)
        trimAndPersist()
    }

    private func readContent(from pasteboard: NSPasteboard) -> ClipboardHistoryContent? {
        let ignoredTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        ]
        guard !ignoredTypes.contains(where: { pasteboard.types?.contains($0) == true }) else {
            return nil
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            return .files(urls.map(\.path))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(text)
        }
        if let data = pasteboard.data(forType: .tiff), data.count <= 8 * 1_024 * 1_024 {
            return .image(data)
        }
        return nil
    }

    private func promote(_ item: ClipboardHistoryItem) {
        let wasActive = items.contains { $0.id == item.id }
        items.removeAll { $0.id == item.id }
        if !wasActive {
            do {
                var archive = try readArchive(encrypted: isEncryptionEnabled)
                archive.removeAll { $0.id == item.id }
                try persistArchiveThrowing(archive)
                updateLoadedFullHistory(archive: archive)
            } catch {
                AppConsole.shared.error("恢复归档剪贴板记录失败：\(error.localizedDescription)", category: "Clipboard")
            }
        }
        var promoted = item
        promoted.createdAt = Date()
        items.insert(promoted, at: 0)
        trimAndPersist()
    }

    private func trimAndPersist() {
        items.sort { $0.createdAt > $1.createdAt }
        pruneActiveItems()
    }

    private func performPeriodicMaintenanceIfNeeded() {
        guard Date().timeIntervalSince(lastMaintenanceDate) >= 60 else { return }
        lastMaintenanceDate = Date()
        pruneActiveItems()
    }

    private func pruneActiveItems() {
        let sorted = items.sorted { $0.createdAt > $1.createdAt }
        let cutoff = retentionPeriod.timeInterval.map { Date().addingTimeInterval(-$0) }
        var active: [ClipboardHistoryItem] = []
        var overflow: [ClipboardHistoryItem] = []
        for item in sorted {
            let isWithinTime = cutoff.map { item.createdAt >= $0 } ?? true
            if isWithinTime, active.count < panelItemLimit {
                active.append(item)
            } else {
                overflow.append(item)
            }
        }
        items = active
        do {
            var archive = try readArchive(encrypted: isEncryptionEnabled)
            if isFullHistoryEnabled, !overflow.isEmpty {
                let existingIDs = Set(archive.map(\.id))
                archive.append(contentsOf: overflow.filter { !existingIDs.contains($0.id) })
                archive.sort { $0.createdAt > $1.createdAt }
            }
            try persistRecentThrowing(items)
            if isFullHistoryEnabled, !overflow.isEmpty {
                try persistArchiveThrowing(archive)
            } else {
                refreshStorageStatistics()
            }
            updateLoadedFullHistory(archive: archive)
        } catch {
            AppConsole.shared.error("整理剪贴板历史失败：\(error.localizedDescription)", category: "Clipboard")
        }
    }

    private var storageDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Briskill/Clipboard", isDirectory: true)
    }

    private var plaintextStorageURL: URL {
        storageDirectoryURL.appendingPathComponent("history.json")
    }

    private var encryptedStorageURL: URL {
        storageDirectoryURL.appendingPathComponent("history.encrypted")
    }

    private var recentPlaintextStorageURL: URL {
        storageDirectoryURL.appendingPathComponent("recent.json")
    }

    private var recentEncryptedStorageURL: URL {
        storageDirectoryURL.appendingPathComponent("recent.encrypted")
    }

    private func load() {
        do {
            if !defaults.bool(forKey: splitStorageMigrationKey) {
                let legacyItems = try readArchive(encrypted: isEncryptionEnabled)
                items = legacyItems
                try FileManager.default.createDirectory(
                    at: storageDirectoryURL,
                    withIntermediateDirectories: true
                )
                let (active, overflow) = partitionForActiveStorage(legacyItems)
                items = active
                try persistRecentThrowing(active)
                try persistArchiveThrowing(isFullHistoryEnabled ? overflow : [])
                defaults.set(true, forKey: splitStorageMigrationKey)
            } else {
                items = try readRecent(encrypted: isEncryptionEnabled)
            }
            items.sort { $0.createdAt > $1.createdAt }
            archivedItemCount = defaults.integer(forKey: archiveCountKey)
            refreshStorageStatistics()
            pruneActiveItems()
        } catch {
            securityMessage = String(
                format: String(localized: "读取剪贴板历史失败：%@"),
                error.localizedDescription
            )
            securityMessageIsError = true
            AppConsole.shared.error("读取剪贴板历史失败：\(error.localizedDescription)", category: "Clipboard")
        }
    }

    private func partitionForActiveStorage(
        _ source: [ClipboardHistoryItem]
    ) -> (active: [ClipboardHistoryItem], overflow: [ClipboardHistoryItem]) {
        let sorted = source.sorted { $0.createdAt > $1.createdAt }
        let cutoff = retentionPeriod.timeInterval.map { Date().addingTimeInterval(-$0) }
        var active: [ClipboardHistoryItem] = []
        var overflow: [ClipboardHistoryItem] = []
        for item in sorted {
            if (cutoff.map { item.createdAt >= $0 } ?? true), active.count < panelItemLimit {
                active.append(item)
            } else {
                overflow.append(item)
            }
        }
        return (active, overflow)
    }

    private func readRecent(encrypted: Bool) throws -> [ClipboardHistoryItem] {
        try readItems(
            plaintextURL: recentPlaintextStorageURL,
            encryptedURL: recentEncryptedStorageURL,
            encrypted: encrypted
        )
    }

    private func readArchive(encrypted: Bool) throws -> [ClipboardHistoryItem] {
        try readItems(
            plaintextURL: plaintextStorageURL,
            encryptedURL: encryptedStorageURL,
            encrypted: encrypted
        )
    }

    private func readItems(
        plaintextURL: URL,
        encryptedURL: URL,
        encrypted: Bool
    ) throws -> [ClipboardHistoryItem] {
        let url = encrypted ? encryptedURL : plaintextURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let stored = try Data(contentsOf: url)
        let data = encrypted ? try decrypt(stored) : stored
        return try JSONDecoder().decode([ClipboardHistoryItem].self, from: data)
    }

    private func persistRecentThrowing(_ recent: [ClipboardHistoryItem]) throws {
        try writeItems(
            recent,
            plaintextURL: recentPlaintextStorageURL,
            encryptedURL: recentEncryptedStorageURL
        )
    }

    private func persistArchiveThrowing(_ archive: [ClipboardHistoryItem]) throws {
        try writeItems(
            archive,
            plaintextURL: plaintextStorageURL,
            encryptedURL: encryptedStorageURL
        )
        archivedItemCount = archive.count
        defaults.set(archive.count, forKey: archiveCountKey)
        refreshStorageStatistics()
    }

    private func writeItems(
        _ value: [ClipboardHistoryItem],
        plaintextURL: URL,
        encryptedURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoded = try JSONEncoder().encode(value)
        if isEncryptionEnabled {
            let encrypted = try encrypt(encoded)
            try encrypted.write(to: encryptedURL, options: .atomic)
        } else {
            try encoded.write(to: plaintextURL, options: .atomic)
        }
    }

    private func mergedHistory(
        active: [ClipboardHistoryItem],
        archive: [ClipboardHistoryItem]
    ) -> [ClipboardHistoryItem] {
        var seen: Set<UUID> = []
        return (active + archive)
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.id).inserted }
    }

    private func updateLoadedFullHistory(archive: [ClipboardHistoryItem]) {
        archivedItemCount = archive.count
        defaults.set(archive.count, forKey: archiveCountKey)
        if isFullHistoryLoaded {
            fullHistoryItems = mergedHistory(active: items, archive: archive)
        }
        refreshStorageStatistics()
    }

    private func refreshStorageStatistics() {
        let urls = [
            plaintextStorageURL,
            encryptedStorageURL,
            recentPlaintextStorageURL,
            recentEncryptedStorageURL
        ]
        localStorageBytes = urls.reduce(into: Int64(0)) { total, url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else { return }
            total += size.int64Value
        }
    }

    var fullHistoryCount: Int { items.count + archivedItemCount }

    var formattedLocalStorageSize: String {
        ByteCountFormatter.string(fromByteCount: localStorageBytes, countStyle: .file)
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let value = KeychainStore.value(account: encryptionKeyAccount),
           let data = Data(base64Encoded: value),
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try KeychainStore.save(data.base64EncodedString(), account: encryptionKeyAccount)
        return key
    }

    private func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey())
        guard let combined = sealedBox.combined else {
            throw ClipboardHistorySecurityError.encryptionFailed
        }
        return combined
    }

    private func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: encryptionKey())
    }

    private func authenticateWithTouchID(reason: String) async -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 180_000_000)

        let context = LAContext()
        context.localizedCancelTitle = String(localized: "取消")
        context.interactionNotAllowed = false
        authenticationContext?.invalidate()
        authenticationContext = context

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authenticationContext = nil
            if isAuthenticationCancellation(error) {
                securityMessage = nil
                securityMessageIsError = false
                return false
            }
            securityMessage = error?.localizedDescription
                ?? String(localized: "这台 Mac 无法使用 Touch ID 或锁屏密码验证。")
            securityMessageIsError = true
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) { [weak self] granted, evaluationError in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.authenticationContext = nil
                    if granted {
                        self.securityMessage = nil
                        self.securityMessageIsError = false
                        continuation.resume(returning: true)
                        return
                    }
                    if self.isAuthenticationCancellation(evaluationError) {
                        self.securityMessage = nil
                        self.securityMessageIsError = false
                    } else {
                        self.securityMessage = evaluationError?.localizedDescription
                            ?? String(localized: "身份验证未通过。")
                        self.securityMessageIsError = true
                    }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func isAuthenticationCancellation(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain else { return false }
        let cancellationCodes = [
            LAError.Code.userCancel.rawValue,
            LAError.Code.appCancel.rawValue,
            LAError.Code.systemCancel.rawValue,
            LAError.Code.userFallback.rawValue
        ]
        return cancellationCodes.contains(nsError.code)
    }
}

enum ClipboardHistorySecurityError: LocalizedError {
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            String(localized: "无法生成加密文件。")
        }
    }
}
