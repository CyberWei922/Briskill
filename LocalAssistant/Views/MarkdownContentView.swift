import AppKit
import SwiftUI

struct MarkdownContentView: View {
    let markdown: String
    var baseFontSize: CGFloat = 13.5
    var textColor: Color = .primary
    var blockSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(MarkdownBlockParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            inlineText(value)
                .font(.system(size: baseFontSize))
                .lineSpacing(baseFontSize * 0.26)
                .foregroundStyle(textColor)

        case .heading(let level, let value):
            inlineText(value)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(textColor)
                .padding(.top, level == 1 ? 2 : 0)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(textColor.opacity(0.72))
                            .frame(width: 4.5, height: 4.5)
                        inlineText(item)
                            .font(.system(size: baseFontSize))
                            .foregroundStyle(textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 3)

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + offset).")
                            .font(.system(size: baseFontSize - 0.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(textColor.opacity(0.70))
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(item)
                            .font(.system(size: baseFontSize))
                            .foregroundStyle(textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                inlineText(value)
                    .font(.system(size: baseFontSize))
                    .italic()
                    .foregroundStyle(textColor.opacity(0.78))
                    .padding(.vertical, 2)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let value):
            MarkdownCodeBlockView(
                code: value,
                language: language,
                fontSize: max(10, baseFontSize - 1.5)
            )

        case .rule:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(source)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: baseFontSize + 4
        case 2: baseFontSize + 2.5
        default: baseFontSize + 1
        }
    }
}

struct MarkdownCodeBlockView: View {
    let code: String
    var language: String?
    var fontSize: CGFloat = 11

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(languageLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: .medium))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.primary.opacity(0.035))

            Divider()

            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.88))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
        }
        .onChange(of: code) {
            copied = false
        }
    }

    private var languageLabel: String {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "代码" : value.uppercased()
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList(start: Int, items: [String])
    case quote(String)
    case code(language: String?, value: String)
    case rule
}

private enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let languageValue = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(
                    language: languageValue.isEmpty ? nil : languageValue,
                    value: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if unorderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let firstItem = orderedItem(from: trimmed) {
                var items = [firstItem.text]
                let start = firstItem.number
                index += 1
                while index < lines.count,
                      let item = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item.text)
                    index += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quoteLines.append(String(quoteLine.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                guard !next.isEmpty, !isBlockStart(next) else { break }
                paragraphLines.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks.isEmpty && !source.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func isBlockStart(_ line: String) -> Bool {
        line.hasPrefix("```")
            || heading(from: line) != nil
            || unorderedItem(from: line) != nil
            || orderedItem(from: line) != nil
            || line.hasPrefix(">")
            || isRule(line)
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count) else { return nil }
        let remainder = line.dropFirst(marks.count)
        guard remainder.first == " " else { return nil }
        return (marks.count, String(remainder.dropFirst()))
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        guard let separator = line.firstIndex(of: ".") else { return nil }
        let numberText = line[..<separator]
        guard !numberText.isEmpty, numberText.allSatisfy(\.isNumber), let number = Int(numberText) else { return nil }
        let afterSeparator = line.index(after: separator)
        guard afterSeparator < line.endIndex, line[afterSeparator] == " " else { return nil }
        return (number, String(line[line.index(after: afterSeparator)...]))
    }

    private static func isRule(_ line: String) -> Bool {
        let value = line.filter { !$0.isWhitespace }
        guard value.count >= 3, let first = value.first, ["-", "*", "_"].contains(String(first)) else { return false }
        return value.allSatisfy { $0 == first }
    }
}

#Preview {
    ScrollView {
        MarkdownContentView(markdown: """
        ## Markdown 渲染

        这是包含 **粗体**、*斜体* 和 `inline code` 的段落。

        - 第一项
        - 第二项

        ```swift
        let answer = "Hello"
        print(answer)
        ```
        """)
        .padding()
    }
    .frame(width: 520, height: 420)
}
