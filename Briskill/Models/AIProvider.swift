import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepSeek
    case glm
    case gemini
    case openAI
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .glm: "智谱 GLM"
        case .gemini: "Google Gemini"
        case .openAI: "OpenAI"
        case .custom: String(localized: "自定义兼容服务")
        }
    }

    var shortName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .glm: "GLM"
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        case .custom: String(localized: "自定义服务")
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openAI: "https://api.openai.com/v1"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek-v4-flash"
        case .glm: "glm-4.7-flash"
        case .gemini: "gemini-3.6-flash"
        case .openAI: "gpt-5-mini"
        case .custom: ""
        }
    }

    var symbol: String {
        switch self {
        case .deepSeek: "waveform.path.ecg"
        case .glm: "brain.head.profile"
        case .gemini: "diamond"
        case .openAI: "sparkles"
        case .custom: "point.3.connected.trianglepath.dotted"
        }
    }

    var fallbackModels: [String] {
        switch self {
        case .deepSeek: ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .glm: ["glm-4.7-flash", "glm-5.2"]
        case .gemini: ["gemini-3.6-flash", "gemini-3.5-flash-lite"]
        case .openAI: ["gpt-5-mini"]
        case .custom: []
        }
    }

    var consoleURL: URL? {
        switch self {
        case .deepSeek: URL(string: "https://platform.deepseek.com")
        case .glm: URL(string: "https://open.bigmodel.cn")
        case .gemini: URL(string: "https://aistudio.google.com")
        case .openAI: URL(string: "https://platform.openai.com")
        case .custom: nil
        }
    }

    var apiKeyURL: URL? {
        switch self {
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")
        case .glm: URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .custom: nil
        }
    }

    var usageURL: URL? {
        switch self {
        case .deepSeek: URL(string: "https://platform.deepseek.com/usage")
        case .glm: URL(string: "https://open.bigmodel.cn/usercenter")
        case .gemini: URL(string: "https://aistudio.google.com/usage")
        case .openAI: URL(string: "https://platform.openai.com/usage")
        case .custom: nil
        }
    }

    var supportsBalanceLookup: Bool { self == .deepSeek }

    var isOfficial: Bool { self != .custom }
}

struct AIProviderConfiguration: Codable, Equatable {
    var endpoint: String
    var model: String

    static func defaults(for provider: AIProvider) -> AIProviderConfiguration {
        AIProviderConfiguration(endpoint: provider.defaultEndpoint, model: provider.defaultModel)
    }
}
