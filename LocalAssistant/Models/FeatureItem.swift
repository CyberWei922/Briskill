import SwiftUI

struct FeatureItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let samplePrompt: String
    let demoResponse: String

    var commandName: String {
        switch id {
        case "files": "find"
        case "clipboard": "clipboard"
        case "diagnose": "diagnose"
        default: id
        }
    }

    var searchTerms: [String] {
        let aliases: [String]

        switch id {
        case "ocr":
            aliases = ["scan", "screen text", "截图", "识别", "图片文字"]
        case "summarize":
            aliases = ["summary", "摘要", "总结", "提炼"]
        case "files":
            aliases = ["file", "search file", "文件", "查找", "寻找"]
        case "rewrite":
            aliases = ["polish", "润色", "改写", "语气"]
        case "translate":
            aliases = ["translation", "翻译", "译成", "英文", "中文"]
        case "clipboard":
            aliases = ["pasteboard", "copy history", "剪贴板", "复制记录"]
        case "diagnose":
            aliases = ["check", "slow", "卡顿", "变慢", "异常"]
        default:
            aliases = []
        }

        return [commandName, id, title, subtitle, samplePrompt] + aliases
    }

    static let all: [FeatureItem] = [
        FeatureItem(
            id: "ocr",
            title: "识别屏幕文字",
            subtitle: "截图、OCR 与复制文字",
            icon: "viewfinder",
            tint: Color(red: 0.12, green: 0.62, blue: 0.48),
            samplePrompt: "识别屏幕上的文字",
            demoResponse: "演示结果：已准备好进入区域截图。后续接入 Apple Vision 后，这里会展示识别到的文字，并提供复制、翻译和总结操作。"
        ),
        FeatureItem(
            id: "summarize",
            title: "总结选中文字",
            subtitle: "提炼重点与待办事项",
            icon: "text.alignleft",
            tint: Color(red: 0.45, green: 0.34, blue: 0.95),
            samplePrompt: "总结我当前选中的文字",
            demoResponse: "演示总结：这段内容的核心观点会显示在这里，并按照“重点、结论、待办”整理。当前版本尚未读取真实选区。"
        ),
        FeatureItem(
            id: "files",
            title: "查找本地文件",
            subtitle: "按名称、时间或内容搜索",
            icon: "doc.text.magnifyingglass",
            tint: Color(red: 0.10, green: 0.49, blue: 0.93),
            samplePrompt: "帮我找到昨天下载的 PDF",
            demoResponse: "演示结果：找到 3 个可能相关的 PDF。真实版本会在这里显示文件名、位置和修改时间，并允许用 Quick Look 预览。"
        ),
        FeatureItem(
            id: "rewrite",
            title: "改写当前内容",
            subtitle: "调整语气、长度与表达",
            icon: "character.cursor.ibeam",
            tint: Color(red: 0.91, green: 0.43, blue: 0.20),
            samplePrompt: "把我选中的文字改得更自然",
            demoResponse: "演示改写：这里会呈现改写前后的对照，并在替换回原应用前让你确认。当前版本只展示交互流程。"
        ),
        FeatureItem(
            id: "translate",
            title: "翻译选中文字",
            subtitle: "保留原意与上下文语气",
            icon: "translate",
            tint: Color(red: 0.14, green: 0.58, blue: 0.78),
            samplePrompt: "把我选中的文字翻译成中文",
            demoResponse: "演示翻译：后续这里会同时显示原文与译文，并提供复制或替换原文操作。当前版本尚未连接翻译模型。"
        ),
        FeatureItem(
            id: "clipboard",
            title: "搜索剪贴板",
            subtitle: "找回复制过的文字与链接",
            icon: "clipboard",
            tint: Color(red: 0.72, green: 0.38, blue: 0.85),
            samplePrompt: "搜索我刚才复制过的地址",
            demoResponse: "演示结果：这里会按语义相关度列出剪贴板记录，并隐藏密码、验证码和密钥等敏感内容。"
        ),
        FeatureItem(
            id: "diagnose",
            title: "诊断电脑异常",
            subtitle: "组合证据解释变慢原因",
            icon: "stethoscope",
            tint: Color(red: 0.88, green: 0.28, blue: 0.34),
            samplePrompt: "为什么我的电脑突然变卡了？",
            demoResponse: "演示诊断：真实版本会在后台组合内存压力、进程、磁盘和网络等证据，再给出简明原因；不会把这些底层指标单独暴露成工具。"
        )
    ]
}
