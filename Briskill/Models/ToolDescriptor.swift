import Foundation

enum ToolExecutionLocation: String, Codable {
    case local
    case cloud
}

enum ToolRiskLevel: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case critical

    var displayName: String {
        switch self {
        case .low: String(localized: "低")
        case .medium: String(localized: "中")
        case .high: String(localized: "高")
        case .critical: String(localized: "极高")
        }
    }
}

struct ToolArgumentDescriptor: Codable, Equatable, Identifiable {
    let name: String
    let type: String
    let required: Bool
    let summary: String

    var id: String { name }
}

struct ToolDescriptor: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let category: String
    let summary: String
    let arguments: [ToolArgumentDescriptor]
    let outputType: String
    let permissions: [String]
    let executionLocation: ToolExecutionLocation
    let riskLevel: ToolRiskLevel

    func promptLine() -> String {
        let argumentText = arguments.isEmpty
            ? "{}"
            : "{" + arguments.map { argument in
                "\"\(argument.name)\":\"\(argument.type)\(argument.required ? "" : "?")\""
            }.joined(separator: ",") + "}"
        let permissionText = permissions.isEmpty ? "无额外权限" : permissions.joined(separator: ",")
        return "- \(id)，arguments=\(argumentText)，output=\(outputType)，权限=\(permissionText)：\(summary)"
    }
}

enum ToolDescriptorCatalog {
    static let all: [ToolDescriptor] = [
        descriptor("clipboard.readText", "读取剪贴板", "剪贴板", "读取当前剪贴板纯文本。", output: "text", permissions: ["clipboard"]),
        descriptor("clipboard.writeText", "写入剪贴板", "剪贴板", "把文字写入系统剪贴板。", arguments: [argument("text", "text", "要写入的文字")], output: "text", permissions: ["clipboard"]),
        descriptor("screen.captureRegion", "区域截图", "图像", "让用户框选屏幕区域并返回图片路径。", output: "file", permissions: ["screen_recording"], risk: .medium),
        descriptor("image.ocr", "本地 OCR", "图像", "使用 Apple Vision 在本机识别图片文字。", arguments: [argument("path", "file", "图片路径")], output: "text", permissions: ["user_selected_file"]),
        descriptor("file.readText", "读取文件文字", "文件", "读取文本、代码、RTF 或含文字层的 PDF。", arguments: [argument("path", "file", "文件路径")], output: "text", permissions: ["user_selected_file"], risk: .medium),
        descriptor("file.list", "列出目录", "文件", "列出用户授权目录中的项目。", arguments: [argument("directory", "folder", "目录路径"), optionalArgument("limit", "number", "最大结果数")], output: "array", permissions: ["user_selected_folder"]),
        descriptor("file.search", "搜索文件", "文件", "在用户授权范围内按名称搜索文件。", arguments: [argument("query", "text", "搜索词"), optionalArgument("directory", "folder", "限定目录"), optionalArgument("limit", "number", "最大结果数")], output: "array", permissions: ["user_selected_folder"]),
        descriptor("file.rename", "重命名文件", "文件", "在不覆盖现有文件的前提下重命名。", arguments: [argument("path", "file", "目标文件"), argument("newName", "text", "新名称")], output: "file", permissions: ["user_selected_file", "confirmation_required"], risk: .high),
        descriptor("file.createEmpty", "新建空文件", "文件", "在下载目录创建带后缀的空文件。", arguments: [argument("name", "text", "带后缀的文件名")], output: "file", permissions: ["downloads_write"], risk: .medium),
        descriptor("file.trash", "移到废纸篓", "文件", "将用户选择的文件移到 macOS 废纸篓。", arguments: [argument("path", "file", "目标文件")], output: "file", permissions: ["user_selected_file", "confirmation_required"], risk: .high),
        descriptor("system.snapshot", "系统诊断快照", "系统", "读取磁盘、内存压力和高占用进程等诊断数据。", output: "object", permissions: ["process_information"], risk: .medium),
        descriptor(
            "automation.appleScript",
            "运行 AppleScript",
            "自动化",
            "执行技能中保存的、已由用户确认风险的 AppleScript 源码；运行参数通过 argv 传入。",
            arguments: [optionalArgument("argv", "array", "按顺序传给 on run argv 的参数")],
            output: "text",
            permissions: ["apple_events", "risk_acknowledgement_required"],
            risk: .high
        ),
        descriptor(
            "model.generateText",
            "云端模型生成文字",
            "模型",
            "使用技能的运行时提示词调用用户配置的云端模型。",
            arguments: [argument("input", "text", "发送给模型的运行时输入")],
            output: "text",
            permissions: ["cloud_api"],
            location: .cloud,
            risk: .medium
        )
    ]

    static let byIdentifier = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptors(for mode: SkillExecutionMode) -> [ToolDescriptor] {
        switch mode {
        case .local:
            all.filter { $0.executionLocation == .local }
        case .hybrid:
            all
        case .cloud:
            all.filter { $0.executionLocation == .cloud }
        }
    }

    static func promptCatalog(for mode: SkillExecutionMode) -> String {
        descriptors(for: mode).map { $0.promptLine() }.joined(separator: "\n")
    }

    private static func descriptor(
        _ id: String,
        _ displayName: String,
        _ category: String,
        _ summary: String,
        arguments: [ToolArgumentDescriptor] = [],
        output: String,
        permissions: [String],
        location: ToolExecutionLocation = .local,
        risk: ToolRiskLevel = .low
    ) -> ToolDescriptor {
        ToolDescriptor(
            id: id,
            displayName: NSLocalizedString(displayName, comment: "Tool name"),
            category: NSLocalizedString(category, comment: "Tool category"),
            summary: NSLocalizedString(summary, comment: "Tool summary"),
            arguments: arguments.map {
                ToolArgumentDescriptor(
                    name: $0.name,
                    type: $0.type,
                    required: $0.required,
                    summary: NSLocalizedString($0.summary, comment: "Tool argument")
                )
            },
            outputType: output,
            permissions: permissions,
            executionLocation: location,
            riskLevel: risk
        )
    }

    private static func argument(_ name: String, _ type: String, _ summary: String) -> ToolArgumentDescriptor {
        ToolArgumentDescriptor(name: name, type: type, required: true, summary: summary)
    }

    private static func optionalArgument(_ name: String, _ type: String, _ summary: String) -> ToolArgumentDescriptor {
        ToolArgumentDescriptor(name: name, type: type, required: false, summary: summary)
    }
}
