import Foundation

struct AppleScriptRiskReport: Equatable {
    let targetApplications: [String]
    let notes: [String]
    let riskLevel: ToolRiskLevel

    var summary: String {
        if notes.isEmpty {
            return "未发现明显的高风险语句；AppleScript 仍可能控制其他应用，请在保存前阅读完整代码。"
        }
        return notes.joined(separator: "；")
    }
}

enum AppleScriptRiskAnalyzer {
    static func analyze(_ source: String) -> AppleScriptRiskReport {
        let lowercased = source.lowercased()
        var notes: [String] = []
        var level: ToolRiskLevel = .medium

        func detect(_ fragments: [String], note: String, risk: ToolRiskLevel) {
            guard fragments.contains(where: lowercased.contains) else { return }
            notes.append(note)
            if rank(risk) > rank(level) { level = risk }
        }

        detect(["do shell script"], note: "脚本会执行 Shell 命令", risk: .critical)
        detect(["administrator privileges"], note: "脚本可能请求管理员权限", risk: .critical)
        detect(["system events"], note: "脚本会通过辅助功能控制界面", risk: .high)
        detect(["keystroke", "key code"], note: "脚本会模拟键盘输入", risk: .high)
        detect([" delete ", "delete every", "delete file", "delete folder"], note: "脚本可能删除数据", risk: .high)
        detect([" move ", "duplicate "], note: "脚本可能移动或复制数据", risk: .high)
        detect([" send "], note: "脚本可能向外发送内容", risk: .high)
        detect(["curl ", "wget ", "http://", "https://"], note: "脚本可能访问网络", risk: .high)

        let targets = applicationTargets(in: source)
        if targets.isEmpty {
            notes.append("无法静态确定脚本控制的目标应用")
            if rank(level) < rank(.high) { level = .high }
        }

        return AppleScriptRiskReport(
            targetApplications: targets,
            notes: Array(NSOrderedSet(array: notes)) as? [String] ?? notes,
            riskLevel: level
        )
    }

    private static func applicationTargets(in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)tell\s+(?:current\s+)?application\s+\"([^\"]+)\""#
        ) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        let values = expression.matches(in: source, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private static func rank(_ level: ToolRiskLevel) -> Int {
        switch level {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }
}

enum AppleScriptExecutionError: LocalizedError {
    case emptySource
    case acknowledgementRequired
    case launchFailed(String)
    case failed(status: Int32, message: String)
    case timedOut
    case cancelled
    case compilationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySource: "AppleScript 源代码为空。"
        case .acknowledgementRequired: "这项技能的 AppleScript 尚未完成风险确认，不能运行。"
        case .launchFailed(let message): "无法启动 AppleScript：\(message)"
        case .failed(_, let message): "AppleScript 执行失败：\(message)"
        case .timedOut: "AppleScript 执行超时，已终止。"
        case .cancelled: "AppleScript 已由用户终止。"
        case .compilationFailed(let message): "AppleScript 无法编译：\(message)"
        }
    }
}

enum AppleScriptCompiler {
    static func validate(_ source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleScriptExecutionError.emptySource }
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptExecutionError.compilationFailed("无法创建脚本对象")
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            let message = (error?[NSAppleScript.errorMessage] as? String)
                ?? error?.description
                ?? "未知语法错误"
            throw AppleScriptExecutionError.compilationFailed(message)
        }
    }
}

private final class AppleScriptProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func timeout() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        timedOut = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    var terminalState: (cancelled: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (cancelled, timedOut)
    }
}

enum AppleScriptRunner {
    static func run(
        source: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) async throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleScriptExecutionError.emptySource }

        let box = AppleScriptProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", source, "--"] + arguments
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    guard box.install(process) else {
                        continuation.resume(throwing: AppleScriptExecutionError.cancelled)
                        return
                    }

                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { box.timeout() }
                    }

                    do {
                        try process.run()
                        process.waitUntilExit()
                    } catch {
                        continuation.resume(throwing: AppleScriptExecutionError.launchFailed(error.localizedDescription))
                        return
                    }

                    let state = box.terminalState
                    if state.cancelled {
                        continuation.resume(throwing: AppleScriptExecutionError.cancelled)
                        return
                    }
                    if state.timedOut {
                        continuation.resume(throwing: AppleScriptExecutionError.timedOut)
                        return
                    }

                    let output = String(
                        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errorText = String(
                        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    guard process.terminationStatus == 0 else {
                        continuation.resume(
                            throwing: AppleScriptExecutionError.failed(
                                status: process.terminationStatus,
                                message: errorText.isEmpty ? "退出码 \(process.terminationStatus)" : errorText
                            )
                        )
                        return
                    }
                    continuation.resume(returning: output)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
