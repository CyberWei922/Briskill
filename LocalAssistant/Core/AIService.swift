import Foundation
import OSLog

@MainActor
final class AIService {
    static let shared = AIService()

    private let settings = AISettingsStore.shared
    private let session: URLSession
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LocalAssistant",
        category: "AIService"
    )

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
    }

    func testConnection(provider: AIProvider) async throws -> String {
        try await generateText(
            prompt: "只回复 OK，不要添加其他内容。",
            system: "你正在执行 API 连接测试。",
            provider: provider,
            maxTokens: 64
        )
    }

    func generateText(
        prompt: String,
        system: String? = nil,
        provider: AIProvider? = nil,
        maxTokens: Int = 900,
        expectsJSON: Bool = false
    ) async throws -> String {
        let provider = provider ?? settings.selectedProvider
        let configuration = settings.configuration(for: provider)
        let apiKey = settings.apiKey(for: provider)

        guard !apiKey.isEmpty else { throw AIServiceError.missingAPIKey(provider.displayName) }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.invalidConfiguration("模型名称不能为空")
        }

        let requestID = String(UUID().uuidString.prefix(8))
        logger.notice("[\(requestID, privacy: .public)] 开始请求 \(provider.displayName, privacy: .public) / \(configuration.model, privacy: .public)")

        let request: URLRequest
        switch provider {
        case .deepSeek, .glm:
            request = try makeChatCompletionsRequest(
                provider: provider,
                configuration: configuration,
                apiKey: apiKey,
                prompt: prompt,
                system: system,
                maxTokens: maxTokens,
                expectsJSON: expectsJSON
            )
        case .gemini:
            request = try makeGeminiRequest(
                configuration: configuration,
                apiKey: apiKey,
                prompt: prompt,
                system: system,
                maxTokens: maxTokens
            )
        case .openAI:
            request = try makeOpenAIResponsesRequest(
                configuration: configuration,
                apiKey: apiKey,
                prompt: prompt,
                system: system,
                maxTokens: maxTokens
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("[\(requestID, privacy: .public)] 网络请求失败：\(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("[\(requestID, privacy: .public)] 收到非 HTTP 响应")
            throw AIServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data)
            logger.error("[\(requestID, privacy: .public)] HTTP \(httpResponse.statusCode) ：\(message, privacy: .public)")
            throw AIServiceError.http(
                status: httpResponse.statusCode,
                message: message
            )
        }

        let text: String?
        switch provider {
        case .deepSeek, .glm:
            text = extractChatCompletionsText(from: data)
        case .gemini:
            text = extractGeminiText(from: data)
        case .openAI:
            text = extractOpenAIResponseText(from: data)
        }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let details = responseDiagnostics(from: data, provider: provider)
            logger.error("[\(requestID, privacy: .public)] HTTP 成功，但没有解析到文字：\(details, privacy: .public)")
            throw AIServiceError.emptyResponse(details)
        }
        logger.notice("[\(requestID, privacy: .public)] 请求成功，返回 \(text.count) 个字符")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeChatCompletionsRequest(
        provider: AIProvider,
        configuration: AIProviderConfiguration,
        apiKey: String,
        prompt: String,
        system: String?,
        maxTokens: Int,
        expectsJSON: Bool
    ) throws -> URLRequest {
        let url = try endpointURL(configuration.endpoint, path: "chat/completions")
        var messages: [[String: String]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false
        ]
        if provider == .deepSeek || provider == .glm {
            body["thinking"] = ["type": "disabled"]
        }
        if expectsJSON {
            body["response_format"] = ["type": "json_object"]
        }
        return try jsonRequest(url: url, apiKey: apiKey, body: body)
    }

    private func makeGeminiRequest(
        configuration: AIProviderConfiguration,
        apiKey: String,
        prompt: String,
        system: String?,
        maxTokens: Int
    ) throws -> URLRequest {
        let model = configuration.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.model
        let url = try endpointURL(configuration.endpoint, path: "models/\(model):generateContent")
        var body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": maxTokens
            ]
        ]
        if let system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        var request = try jsonRequest(url: url, apiKey: nil, body: body)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func makeOpenAIResponsesRequest(
        configuration: AIProviderConfiguration,
        apiKey: String,
        prompt: String,
        system: String?,
        maxTokens: Int
    ) throws -> URLRequest {
        let url = try endpointURL(configuration.endpoint, path: "responses")
        var body: [String: Any] = [
            "model": configuration.model,
            "input": prompt,
            "max_output_tokens": maxTokens
        ]
        if let system, !system.isEmpty {
            body["instructions"] = system
        }
        return try jsonRequest(url: url, apiKey: apiKey, body: body)
    }

    private func endpointURL(_ endpoint: String, path: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed) else {
            throw AIServiceError.invalidConfiguration("API 地址无效")
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !components.path.hasSuffix("/\(normalizedPath)") {
            let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + [basePath, normalizedPath]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        }
        guard let url = components.url else {
            throw AIServiceError.invalidConfiguration("API 地址无效")
        }
        return url
    }

    private func jsonRequest(url: URL, apiKey: String?, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func extractChatCompletionsText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message["content"] as? String
    }

    private func extractGeminiText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func extractOpenAIResponseText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let direct = object["output_text"] as? String {
            return direct
        }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        return output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private func responseDiagnostics(from data: Data, provider: AIProvider) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "响应不是可读取的 JSON（\(data.count) bytes）"
        }

        switch provider {
        case .deepSeek, .glm:
            let choice = (object["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            let finishReason = choice?["finish_reason"] as? String ?? "未知"
            let reasoningCount = (message?["reasoning_content"] as? String)?.count ?? 0
            let toolCallCount = (message?["tool_calls"] as? [[String: Any]])?.count ?? 0
            let usage = object["usage"] as? [String: Any]
            let completionTokens = usage?["completion_tokens"] as? Int
            return "finish_reason=\(finishReason)，reasoning_content=\(reasoningCount) 字符，tool_calls=\(toolCallCount)，completion_tokens=\(completionTokens.map(String.init) ?? "未知")"
        case .gemini:
            let candidate = (object["candidates"] as? [[String: Any]])?.first
            return "finishReason=\(candidate?["finishReason"] as? String ?? "未知")"
        case .openAI:
            return "status=\(object["status"] as? String ?? "未知")，output_items=\((object["output"] as? [[String: Any]])?.count ?? 0)"
        }
    }

    private func extractErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "服务返回了无法读取的错误"
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = object["message"] as? String {
            return message
        }
        return "服务未提供错误详情"
    }
}

enum AIServiceError: LocalizedError {
    case missingAPIKey(String)
    case invalidConfiguration(String)
    case invalidResponse
    case emptyResponse(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "尚未保存 \(provider) API Key"
        case .invalidConfiguration(let message): message
        case .invalidResponse: "服务返回了无效响应"
        case .emptyResponse(let details): "模型没有返回最终文字内容。响应摘要：\(details)"
        case .http(let status, let message): "API 请求失败（HTTP \(status)）：\(message)"
        }
    }
}
