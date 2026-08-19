import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case deepSeek
    case glm
    case gemini
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .glm: "智谱 GLM"
        case .gemini: "Google Gemini"
        case .openAI: "OpenAI"
        }
    }

    var shortName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .glm: "GLM"
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openAI: "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek-v4-flash"
        case .glm: "glm-4.7-flash"
        case .gemini: "gemini-2.5-flash"
        case .openAI: "gpt-5-mini"
        }
    }

    var symbol: String {
        switch self {
        case .deepSeek: "waveform.path.ecg"
        case .glm: "brain.head.profile"
        case .gemini: "diamond"
        case .openAI: "sparkles"
        }
    }
}

struct AIProviderConfiguration: Codable, Equatable {
    var endpoint: String
    var model: String

    static func defaults(for provider: AIProvider) -> AIProviderConfiguration {
        AIProviderConfiguration(endpoint: provider.defaultEndpoint, model: provider.defaultModel)
    }
}
