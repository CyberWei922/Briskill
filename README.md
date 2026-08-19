# LocalAssistant

LocalAssistant 是一个原生 macOS 菜单栏 AI 助手原型。当前版本已经从纯 UI Demo 进入可交互的核心功能原型。

## 版本状态

当前版本：**1.0 Beta**

这是一个早期开发版本。目前唯一按可用功能发布的完整链路是：

```text
配置 DeepSeek API
→ 用自然语言描述一个个人技能
→ DeepSeek 生成结构化技能草稿
→ 预览并保存到本地
→ 在快捷面板中搜索已保存的技能
```

OCR、剪贴板读取与历史、本地文件操作、选中文字处理、系统诊断、Spotlight 集成、本地模型，以及保存后技能的完整工具执行能力均仍在开发中。GLM、Gemini 和 OpenAI 已有初步接口代码，但本 Beta 版本暂不视为可用功能。

完整的产品方向、功能范围和长期约束记录在 [`PROJECT_CONTEXT.md`](PROJECT_CONTEXT.md)。后续开发应先阅读该文档。

当前已经完成的基础框架：

- 菜单栏入口
- `Option + Space` 全局快捷键
- 带命令预测和最近技能的快捷操作主面板
- DeepSeek 的技能生成调用
- 智谱 GLM、Gemini、OpenAI 的实验性统一接口
- macOS Keychain API Key 存储和连接测试
- 普通问题的云端模型调用原型
- “引导模式 / 自由发挥”自定义技能创建器
- AI 生成结构化技能草稿、执行计划和权限说明
- 自定义技能的本地持久化和搜索匹配

尚未接入的系统执行能力包括选中文字读取、Apple Vision OCR、文件操作、剪贴板历史和系统诊断。它们当前仍显示功能雏形或缺失能力，不会伪装成已经执行成功。

## 打开工程

使用 Xcode 打开 `LocalAssistant.xcodeproj`，选择 `LocalAssistant` scheme 后运行。
