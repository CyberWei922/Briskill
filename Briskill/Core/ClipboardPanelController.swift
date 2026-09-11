import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ClipboardPanelState: ObservableObject {
    @Published var selectedIndex = 0
    @Published var message: String?
    @Published var searchText = ""
    @Published var isSearching = false
    @Published var openedAt = Date()
    @Published var focusRequest = 0
}

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()

    private let store = ClipboardHistoryStore.shared
    private let state = ClipboardPanelState()
    private var panel: ClipboardHistoryPanel?
    private var previousApplication: NSRunningApplication?
    private let savedOriginXKey = "clipboardPanel.origin.x"
    private let savedOriginYKey = "clipboardPanel.origin.y"
    private let positionPreferenceKey = "clipboardManager.panelPosition"
    private var isApplyingAutomaticPosition = false

    func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        guard store.isEnabled else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        isApplyingAutomaticPosition = true
        applyPreferredSize(to: panel)
        state.searchText = ""
        state.isSearching = false
        state.selectedIndex = 0
        state.openedAt = Date()
        state.message = nil
        positionPanel(panel)
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingAutomaticPosition = false
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        AppConsole.shared.info("剪贴板历史面板已显示", category: "Clipboard")
    }

    private func makePanel() -> ClipboardHistoryPanel {
        let panel = ClipboardHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.contentView = NSHostingView(
            rootView: ClipboardPanelView(
                state: state,
                leftAction: { [weak self] item in self?.performClick(on: item, isSecondary: false) },
                rightAction: { [weak self] item in self?.performClick(on: item, isSecondary: true) }
            )
        )
        return panel
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let visibleItems = matchingItems
        let count = visibleItems.count

        if event.modifierFlags.contains(.command),
           let characters = event.charactersIgnoringModifiers,
           characters.count == 1,
           let number = Int(characters),
           (1...9).contains(number) {
            guard visibleItems.indices.contains(number - 1) else {
                NSSound.beep()
                return true
            }
            state.selectedIndex = number - 1
            paste(visibleItems[number - 1])
            return true
        }
        if event.keyCode == UInt16(kVK_UpArrow) {
            state.selectedIndex = max(0, state.selectedIndex - 1)
            return true
        }
        if event.keyCode == UInt16(kVK_DownArrow) {
            state.selectedIndex = min(max(count - 1, 0), state.selectedIndex + 1)
            return true
        }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            guard visibleItems.indices.contains(state.selectedIndex) else { return true }
            paste(visibleItems[state.selectedIndex])
            return true
        }
        if event.keyCode == UInt16(kVK_Escape) {
            panel?.orderOut(nil)
            return true
        }
        if !state.isSearching,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let characters = event.characters,
           !characters.isEmpty,
           characters.rangeOfCharacter(from: .controlCharacters) == nil {
            state.isSearching = true
            state.searchText = characters
            state.selectedIndex = 0
            state.focusRequest += 1
            return true
        }
        return false
    }

    private var matchingItems: [ClipboardHistoryItem] {
        let panelItems = Array(store.items.prefix(store.panelItemLimit))
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return panelItems }
        return panelItems.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.detail.localizedCaseInsensitiveContains(query)
                || (item.sourceApplication?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private func performClick(on item: ClipboardHistoryItem, isSecondary: Bool) {
        let action = isSecondary ? store.secondaryClickAction : store.primaryClickAction
        switch action {
        case .copy:
            store.putOnPasteboard(item)
            panel?.orderOut(nil)
        case .paste:
            paste(item)
        }
    }

    private func paste(_ item: ClipboardHistoryItem) {
        store.putOnPasteboard(item)
        let target = previousApplication
        panel?.orderOut(nil)
        guard AXIsProcessTrusted() else {
            target?.activate(options: [.activateAllWindows])
            PrivacyPermissionCenter.shared.requestAccessibility()
            AppConsole.shared.error(
                "缺少辅助功能权限，内容已放入剪贴板但未自动粘贴",
                category: "Clipboard"
            )
            return
        }
        target?.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            AppConsole.shared.info("已将剪贴板历史粘贴到原应用", category: "Clipboard")
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        window.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        guard !isApplyingAutomaticPosition else { return }
        UserDefaults.standard.set(window.frame.origin.x, forKey: savedOriginXKey)
        UserDefaults.standard.set(window.frame.origin.y, forKey: savedOriginYKey)
    }

    private func positionPanel(_ panel: NSPanel) {
        let preference = ClipboardPanelPosition(
            rawValue: UserDefaults.standard.string(forKey: positionPreferenceKey) ?? ""
        ) ?? .nearCursor
        switch preference {
        case .nearCursor:
            positionNearCursor(panel)
        case .lastLocation:
            positionAtLastLocation(panel)
        case .topCenter:
            positionAtTopCenter(panel)
        }
    }

    private func positionNearCursor(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        guard let frame = screen(at: mouseLocation)?.visibleFrame else {
            panel.center()
            return
        }
        let gap: CGFloat = 12
        let fitsOnRight = mouseLocation.x + gap + panel.frame.width <= frame.maxX
        let fitsBelow = mouseLocation.y - gap - panel.frame.height >= frame.minY
        let preferredOrigin = NSPoint(
            x: fitsOnRight ? mouseLocation.x + gap : mouseLocation.x - gap - panel.frame.width,
            y: fitsBelow ? mouseLocation.y - gap - panel.frame.height : mouseLocation.y + gap
        )
        panel.setFrameOrigin(clampedOrigin(preferredOrigin, panelSize: panel.frame.size, in: frame))
    }

    private func positionAtLastLocation(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: savedOriginXKey) != nil,
              defaults.object(forKey: savedOriginYKey) != nil else {
            positionAtTopCenter(panel)
            return
        }
        let savedOrigin = NSPoint(
            x: defaults.double(forKey: savedOriginXKey),
            y: defaults.double(forKey: savedOriginYKey)
        )
        let savedCenter = NSPoint(
            x: savedOrigin.x + panel.frame.width / 2,
            y: savedOrigin.y + panel.frame.height / 2
        )
        let frame = screen(at: savedCenter)?.visibleFrame
            ?? screen(at: NSEvent.mouseLocation)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        guard let frame else {
            panel.center()
            return
        }
        panel.setFrameOrigin(clampedOrigin(savedOrigin, panelSize: panel.frame.size, in: frame))
    }

    private func positionAtTopCenter(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        guard let frame = screen(at: mouseLocation)?.visibleFrame else {
            panel.center()
            return
        }
        let topInset: CGFloat = 24
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.maxY - panel.frame.height - topInset
        ))
    }

    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func clampedOrigin(_ origin: NSPoint, panelSize: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - panelSize.width)),
            y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - panelSize.height))
        )
    }

    private func applyPreferredSize(to panel: NSPanel) {
        let density = ClipboardRowDensity(
            rawValue: UserDefaults.standard.string(forKey: "clipboardManager.rowDensity") ?? ""
        ) ?? .comfortable
        let size: NSSize
        switch density {
        case .compact:
            size = NSSize(width: 580, height: 400)
        case .comfortable:
            size = NSSize(width: 660, height: 520)
        case .spacious:
            size = NSSize(width: 720, height: 600)
        }
        if panel.contentLayoutRect.size != size {
            panel.setContentSize(size)
        }
    }
}

final class ClipboardHistoryPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

private struct ClipboardPanelView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @ObservedObject var state: ClipboardPanelState
    @AppStorage("clipboardManager.rowDensity") private var densityRawValue = ClipboardRowDensity.comfortable.rawValue
    @FocusState private var searchIsFocused: Bool
    let leftAction: (ClipboardHistoryItem) -> Void
    let rightAction: (ClipboardHistoryItem) -> Void

    private var density: ClipboardRowDensity {
        ClipboardRowDensity(rawValue: densityRawValue) ?? .comfortable
    }

    private var visibleItems: [ClipboardHistoryItem] {
        let panelItems = Array(store.items.prefix(store.panelItemLimit))
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return panelItems }
        return panelItems.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.detail.localizedCaseInsensitiveContains(query)
                || (item.sourceApplication?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                if state.isSearching {
                    TextField("搜索剪贴板历史", text: $state.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: density == .compact ? 13.5 : 15))
                        .focused($searchIsFocused)
                } else {
                    Text("搜索剪贴板历史")
                        .font(.system(size: density == .compact ? 13.5 : 15))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                Text(String(format: String(localized: "%lld 条"), visibleItems.count))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                if !state.searchText.isEmpty {
                    Button {
                        state.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, density == .compact ? 12 : 15)
            .frame(height: density == .compact ? 34 : density == .comfortable ? 42 : 46)
            .clipboardSearchGlass()
            .padding(.horizontal, density == .compact ? 10 : 18)
            .padding(.top, density == .compact ? 9 : 16)
            .padding(.bottom, density == .compact ? 7 : 12)
            .background(ClipboardPanelDragRegion())
            .contentShape(Capsule())
            .onTapGesture { beginSearch() }

            historyContent
            panelFooter
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
        }
        .onChange(of: state.focusRequest) { _, _ in focusSearch() }
        .onChange(of: state.searchText) { _, _ in state.selectedIndex = 0 }
        .onChange(of: visibleItems.count) { _, count in
            state.selectedIndex = min(state.selectedIndex, max(count - 1, 0))
        }
    }

    private func focusSearch() {
        guard state.isSearching else { return }
        DispatchQueue.main.async {
            searchIsFocused = true
        }
    }

    private func beginSearch() {
        state.isSearching = true
        state.focusRequest += 1
    }

    @ViewBuilder
    private var historyContent: some View {
        if store.items.isEmpty {
            ContentUnavailableView(
                "暂无剪贴板记录",
                systemImage: "clipboard",
                description: Text("复制文本、文件或图片后会自动出现在这里。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleItems.isEmpty {
            ContentUnavailableView.search(text: state.searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: density.rowSpacing) {
                        ForEach(visibleItems.indices, id: \.self) { index in
                            historyRow(visibleItems[index], index: index)
                        }
                    }
                    .padding(.horizontal, density == .compact ? 8 : 12)
                    .padding(.vertical, density == .compact ? 2 : 10)
                }
                .onChange(of: state.selectedIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private var panelFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(density == .compact ? 0.28 : 0.55)
            VStack(spacing: 5) {
                if let message = state.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                footerHints
            }
            .padding(.horizontal, density == .compact ? 13 : 18)
            .frame(minHeight: footerHeight)
        }
    }

    @ViewBuilder
    private var footerHints: some View {
        if density == .compact {
            HStack(spacing: 14) {
                Text("↑↓ 选择")
                Text("↩ 直接粘贴")
                Spacer()
                Text("⌘1–9 直接粘贴")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 18) {
                Label("⌘1–9 直接粘贴", systemImage: "number")
                Label("↑↓ 移动", systemImage: "arrow.up.arrow.down")
                Label("回车直接粘贴", systemImage: "return")
                Spacer()
                Text(mouseActionSummary)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    private var footerHeight: CGFloat {
        if density == .compact { return 34 }
        return state.message == nil ? 46 : 62
    }

    private func historyRow(_ item: ClipboardHistoryItem, index: Int) -> some View {
        ClipboardHistoryRow(
            item: item,
            index: index,
            isSelected: index == state.selectedIndex,
            density: density,
            openedAt: state.openedAt,
            leftAction: { leftAction(item) },
            rightAction: { rightAction(item) }
        )
        .frame(height: density.rowHeight)
        .id(index)
    }

    private var mouseActionSummary: String {
        String(
            format: String(localized: "左键：%@ · 右键：%@"),
            store.primaryClickAction.title,
            store.secondaryClickAction.title
        )
    }
}

private extension View {
    @ViewBuilder
    func clipboardSearchGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                }
        }
    }
}

private struct ClipboardHistoryRow: NSViewRepresentable {
    let item: ClipboardHistoryItem
    let index: Int
    let isSelected: Bool
    let density: ClipboardRowDensity
    let openedAt: Date
    let leftAction: () -> Void
    let rightAction: () -> Void

    func makeNSView(context: Context) -> ClipboardHistoryRowView {
        ClipboardHistoryRowView()
    }

    func updateNSView(_ nsView: ClipboardHistoryRowView, context: Context) {
        nsView.configure(
            item: item,
            index: index,
            isSelected: isSelected,
            density: density,
            openedAt: openedAt,
            leftAction: leftAction,
            rightAction: rightAction
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ClipboardHistoryRowView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 560, height: density.rowHeight)
    }
}

private struct ClipboardPanelDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct ClipboardRowContent: View {
    let item: ClipboardHistoryItem
    let index: Int
    let isSelected: Bool
    let density: ClipboardRowDensity
    let openedAt: Date

    var body: some View {
        switch density {
        case .compact:
            compactContent
        case .comfortable:
            comfortableContent
        case .spacious:
            spaciousContent
        }
    }

    private var compactContent: some View {
        HStack(spacing: 9) {
            if !isTextItem {
                Image(systemName: item.systemImage)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 16)
            }
            Text(item.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.86) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 11)
    }

    private var comfortableContent: some View {
        HStack(spacing: 11) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                metadata
            }
            Spacer(minLength: 10)
            numberBadge
        }
        .padding(.horizontal, 11)
    }

    private var spaciousContent: some View {
        HStack(spacing: 14) {
            if let previewImage = item.previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                    }
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 72, height: 72)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    metadataChip(item.kindTitle)
                    if let source = item.sourceApplication, !source.isEmpty {
                        metadataChip(source)
                    }
                    metadataChip(item.relativeTime(at: openedAt))
                }
            }
            Spacer(minLength: 8)
            numberBadge
        }
        .padding(.horizontal, 12)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let source = item.sourceApplication, !source.isEmpty { Text(source) }
            Text(item.kindTitle)
            Text(item.detail)
            Text(item.relativeTime(at: openedAt))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var numberBadge: some View {
        Text(index < 9 ? "\(index + 1)" : "")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func metadataChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }

    private var isTextItem: Bool {
        if case .text = item.content { return true }
        return false
    }
}

private final class ClipboardHistoryRowView: NSView {
    private var leftAction: (() -> Void)?
    private var rightAction: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false { didSet { refreshBackground() } }
    private var selected = false
    private var density: ClipboardRowDensity = .comfortable
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        let primaryClick = NSClickGestureRecognizer(target: self, action: #selector(handlePrimaryClick))
        primaryClick.buttonMask = 0x1
        addGestureRecognizer(primaryClick)
        let secondaryClick = NSClickGestureRecognizer(target: self, action: #selector(handleSecondaryClick))
        secondaryClick.buttonMask = 0x2
        addGestureRecognizer(secondaryClick)
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        item: ClipboardHistoryItem,
        index: Int,
        isSelected: Bool,
        density: ClipboardRowDensity,
        openedAt: Date,
        leftAction: @escaping () -> Void,
        rightAction: @escaping () -> Void
    ) {
        self.leftAction = leftAction
        self.rightAction = rightAction
        selected = isSelected
        self.density = density
        layer?.cornerRadius = density == .compact ? 7 : density == .comfortable ? 11 : 14
        hostingView.rootView = AnyView(
            ClipboardRowContent(
                item: item,
                index: index,
                isSelected: isSelected,
                density: density,
                openedAt: openedAt
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        )
        refreshBackground()
    }

    @objc private func handlePrimaryClick() { leftAction?() }
    @objc private func handleSecondaryClick() { rightAction?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func refreshBackground() {
        if selected {
            let opacity: CGFloat = density == .compact ? 0.92 : density == .comfortable ? 0.16 : 0.20
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(opacity).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(density == .compact ? 0.07 : 0.055).cgColor
        } else if density == .spacious {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
