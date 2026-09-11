import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InvocationHistorySettingsView: View {
    @ObservedObject private var history = InvocationHistoryStore.shared
    @Binding var searchText: String
    let openRecord: (InvocationRecord) -> Void
    @State private var recordPendingDeletion: InvocationRecord?
    @State private var isConfirmingClear = false
    @State private var isSelecting = false
    @State private var selectedRecordIDs: Set<UUID> = []
    @State private var isConfirmingBatchDelete = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "还没有调用记录" : "没有匹配的记录",
                    systemImage: searchText.isEmpty ? "clock.badge.questionmark" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "在悬浮窗运行问答或技能后，输入、结果和真实工具步骤会保存在这里。" : "尝试搜索输入内容、技能名称或执行结果。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredRecords.enumerated()), id: \.element.id) { index, record in
                            Button {
                                if isSelecting {
                                    toggleSelection(for: record.id)
                                } else {
                                    openRecord(record)
                                }
                            } label: {
                                InvocationHistoryRow(
                                    record: record,
                                    isSelecting: isSelecting,
                                    isSelected: selectedRecordIDs.contains(record.id)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if !isSelecting {
                                    Button("查看详情") { openRecord(record) }
                                    Divider()
                                    Button("删除", role: .destructive) { recordPendingDeletion = record }
                                }
                            }

                            if index + 1 < filteredRecords.count {
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
            }

            historyFloatingControls
                .padding(18)
        }
        .background(Color.settingsPaneBackground)
        .onChange(of: history.records.map(\.id)) {
            selectedRecordIDs.formIntersection(Set(history.records.map(\.id)))
        }
        .alert(
            "删除这条调用记录？",
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            ),
            presenting: recordPendingDeletion
        ) { record in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                history.delete(record)
                recordPendingDeletion = nil
            }
        } message: { record in
            Text("“\(record.title)”的输入和结果会从本机历史中删除。")
        }
        .alert("清空全部调用历史？", isPresented: $isConfirmingClear) {
            Button("取消", role: .cancel) {}
            Button("全部清空", role: .destructive) { history.clear() }
        } message: {
            Text("这会永久删除全部 \(history.records.count) 条本地调用记录，技能和生成历史不会受影响。")
        }
        .alert("删除选中的 \(selectedRecordIDs.count) 条记录？", isPresented: $isConfirmingBatchDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                history.delete(ids: selectedRecordIDs)
                leaveSelectionMode()
            }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var historyFloatingControls: some View {
        HStack(spacing: 8) {
            if isSelecting {
                SettingsFloatingActionButton(title: "取消", symbol: "xmark") {
                    leaveSelectionMode()
                }
                SettingsFloatingActionButton(
                    title: "导出 \(selectedRecordIDs.count) 条",
                    symbol: "square.and.arrow.up.on.square",
                    disabled: selectedRecordIDs.isEmpty,
                    action: exportSelectedRecords
                )
                SettingsFloatingActionButton(
                    title: "删除 \(selectedRecordIDs.count) 条",
                    symbol: "trash",
                    tint: .red,
                    disabled: selectedRecordIDs.isEmpty
                ) {
                    isConfirmingBatchDelete = true
                }
            } else {
                SettingsFloatingActionButton(
                    title: "全部清空",
                    symbol: "trash",
                    tint: .red,
                    disabled: history.records.isEmpty
                ) {
                    isConfirmingClear = true
                }
                SettingsFloatingActionButton(
                    title: "多选",
                    symbol: "checkmark.circle",
                    disabled: history.records.isEmpty
                ) {
                    isSelecting = true
                }
            }
        }
    }

    private var filteredRecords: [InvocationRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.records }
        return history.records.filter { record in
            [record.input, record.title, record.source, record.result]
                .contains { $0.localizedCaseInsensitiveContains(query) }
                || record.tools.contains { $0.localizedCaseInsensitiveContains(query) }
                || record.conversationMessages?.contains {
                    $0.content.localizedCaseInsensitiveContains(query)
                } == true
        }
    }

    private var selectedRecords: [InvocationRecord] {
        history.records.filter { selectedRecordIDs.contains($0.id) }
    }

    private func toggleSelection(for id: UUID) {
        if selectedRecordIDs.contains(id) {
            selectedRecordIDs.remove(id)
        } else {
            selectedRecordIDs.insert(id)
        }
    }

    private func leaveSelectionMode() {
        isSelecting = false
        selectedRecordIDs.removeAll()
    }

    private func exportSelectedRecords() {
        let records = selectedRecords
        guard !records.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "导出调用历史")
        panel.prompt = String(localized: "导出")
        panel.nameFieldStringValue = "Briskill-History-\(Date.now.formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(records)
                try data.write(to: url, options: .atomic)
                AppConsole.shared.success("导出 \(records.count) 条调用历史到：\(url.path)", category: "History")
            } catch {
                AppConsole.shared.error("调用历史导出失败：\(error.localizedDescription)", category: "History")
            }
        }
    }
}

private struct InvocationHistoryRow: View {
    let record: InvocationRecord
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(record.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(record.status.displayName)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                Text(rowSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                    .padding(.leading, 4)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var rowSubtitle: String {
        if record.isConversation {
            return String(localized: "\(record.conversationTurnCount) 轮对话")
        }
        return record.input.isEmpty ? record.source : record.input
    }

    private var statusColor: Color {
        switch record.status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private var statusSymbol: String {
        switch record.status {
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }
}

struct InvocationHistoryDetail: View {
    let record: InvocationRecord
    let delete: () -> Void
    @State private var showsExecutedTools = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let messages = record.conversationMessages, !messages.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(
                                        message.role == .user ? "用户" : "助手",
                                        systemImage: message.role == .user
                                            ? "person.crop.circle"
                                            : "bubble.left.and.text.bubble.right"
                                    )
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                    if message.role == .assistant {
                                        MarkdownContentView(markdown: message.content, baseFontSize: 12.5)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Text(message.content)
                                            .font(.system(size: 12.5))
                                            .textSelection(.enabled)
                                    }
                                }

                                if message.id != messages.last?.id {
                                    Divider()
                                }
                            }
                        }
                    } else {
                        historySection("输入", symbol: "text.cursor") {
                            Text(record.input.isEmpty ? "无文字输入" : record.input)
                                .textSelection(.enabled)
                        }
                    }

                    if !record.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    showsExecutedTools.toggle()
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Text("显示运行命令")
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .rotationEffect(.degrees(showsExecutedTools ? 90 : 0))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showsExecutedTools {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(Array(record.tools.enumerated()), id: \.offset) { _, tool in
                                        HStack(spacing: 7) {
                                            Image(systemName: "terminal")
                                                .font(.system(size: 10.5))
                                                .frame(width: 14)
                                            Text(tool)
                                                .font(.system(size: 11.5))
                                        }
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 3)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Label(
                                String(format: String(localized: "耗时 %.1f 秒"), record.duration),
                                systemImage: "clock"
                            )

                            Spacer()

                            if let tokenUsage = record.tokenUsage {
                                Text(
                                    String(
                                        format: String(localized: "Token：%lld"),
                                        tokenUsage.totalTokens
                                    )
                                )
                            } else if usedCloudModel {
                                Text("Token：未记录")
                            }
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                        if !record.isConversation {
                            MarkdownContentView(markdown: record.result, baseFontSize: 12.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(13)
                                .background(
                                    Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                )
                        }
                    }
                }
                .padding(22)
                .padding(.bottom, 64)
            }

            SettingsFloatingActionButton(
                title: "删除记录",
                symbol: "trash",
                tint: .red,
                action: delete
            )
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.settingsPaneBackground)
    }

    private var usedCloudModel: Bool {
        record.tools.contains {
            $0 == "model.generateText" || $0.localizedCaseInsensitiveContains("model")
        }
    }

    private func historySection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}
