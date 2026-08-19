# LocalAssistant

LocalAssistant 是一个原生 macOS 菜单栏 AI 助手的 UI 原型。

完整的产品方向、功能范围和长期约束记录在 [`PROJECT_CONTEXT.md`](PROJECT_CONTEXT.md)。后续开发应先阅读该文档。

当前版本只包含界面和交互外壳：

- 菜单栏入口
- `Option + Space` 全局快捷键
- 快捷操作主面板
- 设置窗口
- 翻译、文件、剪贴板、OCR、系统状态等功能占位入口

模型、文件操作、剪贴板记录和 OCR 均未接入。

## 打开工程

使用 Xcode 打开 `LocalAssistant.xcodeproj`，选择 `LocalAssistant` scheme 后运行。
