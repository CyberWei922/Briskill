import Foundation
import OSLog

enum AIStreamEvent: Sendable {
    case reasoning(String)
    case content(String)
    case usage(GenerationTokenUsage)
    case finished(String?)
}

@MainActor
final class AIService {
    static let shared = AIService()

    private let settings = AISettingsStore.shared
    private let session: URLSession
    private let streamingSession: URLSession
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LocalAssistant",
        category: "AIService"
    )

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)

        let streamingConfiguration = URLSessionConfiguration.ephemeral
        streamingConfiguration.timeoutIntervalForRequest = 60
        streamingConfiguration.timeoutIntervalForResource = 3_600
        streamingSession = URLSession(configuration: streamingConfiguration)
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
        maxTokens: Int? = nil,
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
        AppConsole.shared.info(
            "[\(requestID)] 开始请求；服务商=\(provider.displayName)，模型=\(configuration.model)，JSON=\(expectsJSON)",
            category: "AI"
        )

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
                maxTokens: maxTokens,
                expectsJSON: expectsJSON
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
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                AppConsole.shared.info("[\(requestID)] 请求已由用户终止", category: "AI")
                throw CancellationError()
            }
            logger.error("[\(requestID, privacy: .public)] 网络请求失败：\(error.localizedDescription, privacy: .public)")
            AppConsole.shared.error("[\(requestID)] 网络请求失败：\(error.localizedDescription)", category: "AI")
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("[\(requestID, privacy: .public)] 收到非 HTTP 响应")
            throw AIServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data)
            logger.error("[\(requestID, privacy: .public)] HTTP \(httpResponse.statusCode) ：\(message, privacy: .public)")
            AppConsole.shared.error("[\(requestID)] HTTP \(httpResponse.statusCode)：\(message)", category: "AI")
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
            AppConsole.shared.error("[\(requestID)] 响应无最终文字：\(details)", category: "AI")
            throw AIServiceError.emptyResponse(details)
        }
        let diagnostics = responseDiagnostics(from: data, provider: provider)
        logger.notice("[\(requestID, privacy: .public)] 请求成功，返回 \(text.count) 个字符；\(diagnostics, privacy: .public)")
        AppConsole.shared.success(
            "[\(requestID)] 请求成功；返回 \(text.count) 个字符；\(diagnostics)",
            category: "AI"
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func streamSkillDraft(
        description: String,
        system: String,
        provider: AIProvider,
        thinkingEnabled: Bool
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard provider == .deepSeek || provider == .gemini else {
                        throw AIServiceError.streamingUnsupported(provider.displayName)
                    }

                    let configuration = settings.configuration(for: provider)
                    let apiKey = settings.apiKey(for: provider)
                    guard !apiKey.isEmpty else {
                        throw AIServiceError.missingAPIKey(provider.displayName)
                    }

                    let request: URLRequest
                    switch provider {
                    case .deepSeek:
                        request = try makeDeepSeekStreamingRequest(
                            configuration: configuration,
                            apiKey: apiKey,
                            description: description,
                            system: system,
                            thinkingEnabled: thinkingEnabled
                        )
                    case .gemini:
                        request = try makeGeminiStreamingRequest(
                            configuration: configuration,
                            apiKey: apiKey,
                            description: description,
                            system: system,
                            thinkingEnabled: thinkingEnabled
                        )
                    default:
                        throw AIServiceError.streamingUnsupported(provider.displayName)
                    }
                    let requestID = String(UUID().uuidString.prefix(8))
                    AppConsole.shared.info(
                        "[\(requestID)] 开始流式生成技能；模型=\(configuration.model)，Think=\(thinkingEnabled ? "开启" : "关闭")，max_tokens=未设置",
                        category: provider.shortName
                    )

                    let (bytes, response) = try await streamingSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIServiceError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            if errorData.count < 8_192 { errorData.append(byte) }
                        }
                        throw AIServiceError.http(
                            status: httpResponse.statusCode,
                            message: extractErrorMessage(from: errorData)
                        )
                    }

                    switch provider {
                    case .deepSeek:
                        try await consumeDeepSeekStream(bytes, continuation: continuation)
                    case .gemini:
                        try await consumeGeminiStream(bytes, continuation: continuation)
                    default:
                        break
                    }

                    AppConsole.shared.success("[\(requestID)] \(provider.shortName) 流式响应接收完成", category: provider.shortName)
                    continuation.finish()
                } catch is CancellationError {
                    AppConsole.shared.warning("用户终止了正在进行的技能生成", category: provider.shortName)
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        AppConsole.shared.warning("用户终止了正在进行的技能生成", category: provider.shortName)
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    AppConsole.shared.error("流式技能生成失败：\(error.localizedDescription)", category: provider.shortName)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func makeDeepSeekStreamingRequest(
        configuration: AIProviderConfiguration,
        apiKey: String,
        description: String,
        system: String,
        thinkingEnabled: Bool
    ) throws -> URLRequest {
        let url = try endpointURL(configuration.endpoint, path: "chat/completions")
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": description]
            ],
            "response_format": ["type": "json_object"],
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        body["thinking"] = ["type": thinkingEnabled ? "enabled" : "disabled"]
        if thinkingEnabled {
            body["reasoning_effort"] = "high"
        }
        return try jsonRequest(url: url, apiKey: apiKey, body: body)
    }

    private func makeGeminiStreamingRequest(
        configuration: AIProviderConfiguration,
        apiKey: String,
        description: String,
        system: String,
        thinkingEnabled: Bool
    ) throws -> URLRequest {
        let model = configuration.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.model
        let baseURL = try endpointURL(configuration.endpoint, path: "models/\(model):streamGenerateContent")
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AIServiceError.invalidConfiguration("Gemini API 地址无效")
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let url = components.url else {
            throw AIServiceError.invalidConfiguration("Gemini API 地址无效")
        }

        let generationConfig: [String: Any] = [
            "temperature": 0.2,
            "responseMimeType": "application/json",
            "thinkingConfig": geminiThinkingConfig(
                model: configuration.model,
                enabled: thinkingEnabled
            )
        ]
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": description]]
            ]],
            "systemInstruction": ["parts": [["text": system]]],
            "generationConfig": generationConfig
        ]

        var request = try jsonRequest(url: url, apiKey: nil, body: body)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func consumeDeepSeekStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        var receivedFinishedEvent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                if !receivedFinishedEvent {
                    continuation.yield(.finished(nil))
                }
                break
            }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let usage = parseUsage(from: object) {
                continuation.yield(.usage(usage))
            }

            guard let choice = (object["choices"] as? [[String: Any]])?.first else {
                continue
            }
            if let delta = choice["delta"] as? [String: Any] {
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    continuation.yield(.content(content))
                }
            }
            if let finishReason = choice["finish_reason"] as? String {
                receivedFinishedEvent = true
                continuation.yield(.finished(finishReason))
            }
        }
    }

    private func consumeGeminiStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        var receivedFinishedEvent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let usage = parseGeminiUsage(from: object) {
                continuation.yield(.usage(usage))
            }

            if let feedback = object["promptFeedback"] as? [String: Any],
               let blockReason = feedback["blockReason"] as? String {
                throw AIServiceError.emptyResponse("Gemini 拒绝了请求：\(blockReason)")
            }

            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else {
                continue
            }
            let content = candidate["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                if part["thought"] as? Bool == true {
                    continuation.yield(.reasoning(text))
                } else {
                    continuation.yield(.content(text))
                }
            }
            if let finishReason = candidate["finishReason"] as? String, !finishReason.isEmpty {
                receivedFinishedEvent = true
                continuation.yield(.finished(finishReason))
            }
        }
        if !receivedFinishedEvent {
            continuation.yield(.finished(nil))
        }
    }

    private func geminiThinkingConfig(model: String, enabled: Bool) -> [String: Any] {
        let normalizedModel = model.lowercased()
        if normalizedModel.contains("gemini-3") {
            return [
                "thinkingLevel": enabled ? "high" : "low",
                "includeThoughts": enabled
            ]
        }
        if normalizedModel.contains("2.5-pro") {
            return [
                "thinkingBudget": -1,
                "includeThoughts": enabled
            ]
        }
        if normalizedModel.contains("2.5") {
            return [
                "thinkingBudget": enabled ? -1 : 0,
                "includeThoughts": enabled
            ]
        }
        return ["includeThoughts": enabled]
    }

    private func parseUsage(from object: [String: Any]) -> GenerationTokenUsage? {
        guard let usage = object["usage"] as? [String: Any],
              let totalTokens = usage["total_tokens"] as? Int else {
            return nil
        }
        let details = usage["completion_tokens_details"] as? [String: Any]
        return GenerationTokenUsage(
            promptTokens: usage["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage["completion_tokens"] as? Int ?? 0,
            reasoningTokens: details?["reasoning_tokens"] as? Int ?? 0,
            totalTokens: totalTokens
        )
    }

    private func parseGeminiUsage(from object: [String: Any]) -> GenerationTokenUsage? {
        guard let usage = object["usageMetadata"] as? [String: Any],
              let totalTokens = usage["totalTokenCount"] as? Int else {
            return nil
        }
        return GenerationTokenUsage(
            promptTokens: usage["promptTokenCount"] as? Int ?? 0,
            completionTokens: usage["candidatesTokenCount"] as? Int ?? 0,
            reasoningTokens: usage["thoughtsTokenCount"] as? Int ?? 0,
            totalTokens: totalTokens
        )
    }

    private func makeChatCompletionsRequest(
        provider: AIProvider,
        configuration: AIProviderConfiguration,
        apiKey: String,
        prompt: String,
        system: String?,
        maxTokens: Int?,
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
            "stream": false
        ]
        if let maxTokens {
            body["max_tokens"] = maxTokens
        }
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
        maxTokens: Int?,
        expectsJSON: Bool
    ) throws -> URLRequest {
        let model = configuration.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? configuration.model
        let url = try endpointURL(configuration.endpoint, path: "models/\(model):generateContent")
        var generationConfig: [String: Any] = [
            "temperature": 0.2,
            "thinkingConfig": geminiThinkingConfig(
                model: configuration.model,
                enabled: false
            )
        ]
        if let maxTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if expectsJSON {
            generationConfig["responseMimeType"] = "application/json"
        }
        var body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]],
            "generationConfig": generationConfig
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
        maxTokens: Int?
    ) throws -> URLRequest {
        let url = try endpointURL(configuration.endpoint, path: "responses")
        var body: [String: Any] = [
            "model": configuration.model,
            "input": prompt
        ]
        if let maxTokens {
            body["max_output_tokens"] = maxTokens
        }
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
    case streamingUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "尚未保存 \(provider) API Key"
        case .invalidConfiguration(let message): message
        case .invalidResponse: "服务返回了无效响应"
        case .emptyResponse(let details): "模型没有返回最终文字内容。响应摘要：\(details)"
        case .http(let status, let message): "API 请求失败（HTTP \(status)）：\(message)"
        case .streamingUnsupported(let provider): "当前透明流式生成支持 DeepSeek 和 Gemini，已选择 \(provider)"
        }
    }
}
