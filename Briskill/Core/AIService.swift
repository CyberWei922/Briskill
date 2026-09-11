import Foundation
import OSLog

enum AIStreamEvent: Sendable {
    case reasoning(String)
    case content(String)
    case usage(GenerationTokenUsage)
    case finished(String?)
}

struct DeepSeekAccountMetadata: Sendable {
    let models: [String]
    let isAvailable: Bool
    let balances: [DeepSeekBalanceInfo]
}

struct DeepSeekBalanceInfo: Sendable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String
}

struct AITextGenerationResult: Sendable {
    let text: String
    let usage: GenerationTokenUsage?
    let provider: AIProvider
    let model: String
    let failedAttempts: [AIRoutingAttempt]
}

struct AIRoutingAttempt: Sendable {
    let provider: AIProvider
    let message: String
}

@MainActor
final class AIService {
    static let shared = AIService()

    private let settings = AISettingsStore.shared
    private let session: URLSession
    private let streamingSession: URLSession
    private var refreshedModelProviders: Set<AIProvider> = []
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Briskill",
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

    func fetchDeepSeekAccountMetadata(
        endpoint: String,
        apiKey: String
    ) async throws -> DeepSeekAccountMetadata {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIServiceError.missingAPIKey(AIProvider.deepSeek.displayName)
        }

        async let modelsData = authenticatedGET(
            url: try endpointURL(endpoint, path: "models"),
            apiKey: trimmedKey
        )
        async let balanceData = authenticatedGET(
            url: try endpointURL(endpoint, path: "user/balance"),
            apiKey: trimmedKey
        )

        let (modelsPayload, balancePayload) = try await (modelsData, balanceData)
        let modelsResponse = try JSONDecoder().decode(DeepSeekModelsResponse.self, from: modelsPayload)
        let balanceResponse = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: balancePayload)
        let models = Array(Set(modelsResponse.data.map(\.id))).sorted()
        guard !models.isEmpty else { throw AIServiceError.invalidResponse }
        return DeepSeekAccountMetadata(
            models: models,
            isAvailable: balanceResponse.isAvailable,
            balances: balanceResponse.balanceInfos.map {
                DeepSeekBalanceInfo(
                    currency: $0.currency,
                    totalBalance: $0.totalBalance,
                    grantedBalance: $0.grantedBalance,
                    toppedUpBalance: $0.toppedUpBalance
                )
            }
        )
    }

    func fetchAvailableModels(
        provider: AIProvider,
        endpoint: String,
        apiKey: String
    ) async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AIServiceError.missingAPIKey(provider.displayName)
        }
        let url = try endpointURL(endpoint, path: "models")
        let data: Data
        if provider == .gemini {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
            data = try await responseData(for: request)
            let response = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
            let models = response.models.filter { model in
                model.supportedGenerationMethods?.contains("generateContent") ?? true
            }.map { model in
                model.name.hasPrefix("models/") ? String(model.name.dropFirst(7)) : model.name
            }
            return sanitizedModels(models, provider: provider)
        }

        data = try await authenticatedGET(url: url, apiKey: trimmedKey)
        let response = try JSONDecoder().decode(DeepSeekModelsResponse.self, from: data)
        return sanitizedModels(response.data.map(\.id), provider: provider)
    }

    func generateText(
        prompt: String,
        system: String? = nil,
        provider: AIProvider? = nil,
        maxTokens: Int? = nil,
        expectsJSON: Bool = false
    ) async throws -> String {
        try await generateTextWithUsage(
            prompt: prompt,
            system: system,
            provider: provider,
            maxTokens: maxTokens,
            expectsJSON: expectsJSON
        ).text
    }

    func generateTextWithUsage(
        prompt: String,
        system: String? = nil,
        provider: AIProvider? = nil,
        maxTokens: Int? = nil,
        expectsJSON: Bool = false
    ) async throws -> AITextGenerationResult {
        try await generateConversationWithUsage(
            messages: [ConversationMessage(role: .user, content: prompt)],
            system: system,
            provider: provider,
            maxTokens: maxTokens,
            expectsJSON: expectsJSON
        )
    }

    func generateConversationWithUsage(
        messages: [ConversationMessage],
        system: String? = nil,
        provider: AIProvider? = nil,
        maxTokens: Int? = nil,
        expectsJSON: Bool = false
    ) async throws -> AITextGenerationResult {
        guard !messages.isEmpty else { throw AIServiceError.invalidResponse }
        if let provider {
            return try await performConversationRequest(
                messages: messages,
                system: system,
                provider: provider,
                maxTokens: maxTokens,
                expectsJSON: expectsJSON,
                failedAttempts: []
            )
        }

        let candidates = settings.routingProviders.filter { settings.isConfigured($0) }
        guard !candidates.isEmpty else { throw AIServiceError.noConfiguredProvider }
        var failures: [AIRoutingAttempt] = []
        var lastError: Error?
        for candidate in candidates {
            do {
                return try await performConversationRequest(
                    messages: messages,
                    system: system,
                    provider: candidate,
                    maxTokens: maxTokens,
                    expectsJSON: expectsJSON,
                    failedAttempts: failures
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                failures.append(AIRoutingAttempt(provider: candidate, message: error.localizedDescription))
                AppConsole.shared.warning(
                    "\(candidate.displayName) 调用失败，\(settings.automaticFailover ? "准备顺延" : "自动顺延已关闭")：\(error.localizedDescription)",
                    category: "AIRouter"
                )
                guard settings.automaticFailover, isFailoverEligible(error) else { throw error }
            }
        }
        throw AIServiceError.routingFailed(
            failures.map { "\($0.provider.displayName)：\($0.message)" }.joined(separator: "\n"),
            underlying: lastError?.localizedDescription
        )
    }

    private func performConversationRequest(
        messages: [ConversationMessage],
        system: String?,
        provider: AIProvider,
        maxTokens: Int?,
        expectsJSON: Bool,
        failedAttempts: [AIRoutingAttempt]
    ) async throws -> AITextGenerationResult {
        await refreshModelCatalogIfNeeded(for: provider)
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
        case .deepSeek, .glm, .custom:
            request = try makeChatCompletionsRequest(
                provider: provider,
                configuration: configuration,
                apiKey: apiKey,
                messages: messages,
                system: system,
                maxTokens: maxTokens,
                expectsJSON: expectsJSON
            )
        case .gemini:
            request = try makeGeminiRequest(
                configuration: configuration,
                apiKey: apiKey,
                messages: messages,
                system: system,
                maxTokens: maxTokens,
                expectsJSON: expectsJSON
            )
        case .openAI:
            request = try makeOpenAIResponsesRequest(
                configuration: configuration,
                apiKey: apiKey,
                messages: messages,
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
        case .deepSeek, .glm, .custom:
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
        return AITextGenerationResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            usage: extractUsage(from: data, provider: provider),
            provider: provider,
            model: configuration.model,
            failedAttempts: failedAttempts
        )
    }

    private func refreshModelCatalogIfNeeded(for provider: AIProvider) async {
        guard !refreshedModelProviders.contains(provider) else { return }
        refreshedModelProviders.insert(provider)
        let configuration = settings.configuration(for: provider)
        let apiKey = settings.apiKey(for: provider)
        guard !apiKey.isEmpty, !configuration.endpoint.isEmpty else { return }
        do {
            let models = try await fetchAvailableModels(
                provider: provider,
                endpoint: configuration.endpoint,
                apiKey: apiKey
            )
            settings.updateAvailableModels(models, for: provider)
            AppConsole.shared.info(
                "已自动刷新 \(provider.displayName) 模型目录，共 \(models.count) 个",
                category: "Models"
            )
        } catch {
            AppConsole.shared.warning(
                "自动刷新 \(provider.displayName) 模型目录失败，继续使用缓存：\(error.localizedDescription)",
                category: "Models"
            )
        }
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

    private func extractUsage(from data: Data, provider: AIProvider) -> GenerationTokenUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch provider {
        case .deepSeek, .glm, .custom:
            return parseUsage(from: object)
        case .gemini:
            return parseGeminiUsage(from: object)
        case .openAI:
            guard let usage = object["usage"] as? [String: Any] else { return nil }
            let promptTokens = usage["input_tokens"] as? Int ?? 0
            let completionTokens = usage["output_tokens"] as? Int ?? 0
            let totalTokens = usage["total_tokens"] as? Int ?? promptTokens + completionTokens
            return GenerationTokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                reasoningTokens: 0,
                totalTokens: totalTokens
            )
        }
    }

    private func makeChatCompletionsRequest(
        provider: AIProvider,
        configuration: AIProviderConfiguration,
        apiKey: String,
        messages: [ConversationMessage],
        system: String?,
        maxTokens: Int?,
        expectsJSON: Bool
    ) throws -> URLRequest {
        let url = try endpointURL(configuration.endpoint, path: "chat/completions")
        var requestMessages: [[String: String]] = []
        if let system, !system.isEmpty {
            requestMessages.append(["role": "system", "content": system])
        }
        requestMessages.append(contentsOf: messages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        })

        var body: [String: Any] = [
            "model": configuration.model,
            "messages": requestMessages,
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
        messages: [ConversationMessage],
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
            "contents": messages.map { message in
                [
                    "role": message.role == .assistant ? "model" : "user",
                    "parts": [["text": message.content]]
                ]
            },
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
        messages: [ConversationMessage],
        system: String?,
        maxTokens: Int?
    ) throws -> URLRequest {
        let url = try endpointURL(configuration.endpoint, path: "responses")
        var body: [String: Any] = [
            "model": configuration.model,
            "input": messages.map { message in
                ["role": message.role.rawValue, "content": message.content]
            }
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

    private func authenticatedGET(url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIServiceError.http(
                status: httpResponse.statusCode,
                message: extractErrorMessage(from: data)
            )
        }
        return data
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIServiceError.http(
                status: httpResponse.statusCode,
                message: extractErrorMessage(from: data)
            )
        }
        return data
    }

    private func sanitizedModels(_ values: [String], provider: AIProvider) -> [String] {
        let unique = Array(Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        let filtered: [String]
        switch provider {
        case .deepSeek:
            filtered = unique.filter { $0.localizedCaseInsensitiveContains("deepseek") }
        case .glm:
            filtered = unique.filter { $0.localizedCaseInsensitiveContains("glm") }
        case .gemini:
            filtered = unique.filter { $0.localizedCaseInsensitiveContains("gemini") }
        case .openAI:
            filtered = unique.filter {
                let value = $0.lowercased()
                return (value.hasPrefix("gpt-") || value.hasPrefix("o"))
                    && !value.contains("audio")
                    && !value.contains("realtime")
                    && !value.contains("image")
                    && !value.contains("transcribe")
                    && !value.contains("tts")
            }
        case .custom:
            filtered = unique
        }
        let result = filtered.isEmpty ? unique : filtered
        guard !result.isEmpty else { return provider.fallbackModels }
        return result.sorted { lhs, rhs in
            let lhsPreferred = provider.fallbackModels.firstIndex(of: lhs) ?? Int.max
            let rhsPreferred = provider.fallbackModels.firstIndex(of: rhs) ?? Int.max
            return lhsPreferred == rhsPreferred ? lhs < rhs : lhsPreferred < rhsPreferred
        }
    }

    private func isFailoverEligible(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        switch error {
        case AIServiceError.missingAPIKey,
             AIServiceError.invalidConfiguration,
             AIServiceError.invalidResponse,
             AIServiceError.emptyResponse,
             AIServiceError.http,
             AIServiceError.streamingUnsupported:
            return true
        default:
            return false
        }
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
        case .deepSeek, .glm, .custom:
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

private struct DeepSeekModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct GeminiModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]?
    }
    let models: [Model]
}

private struct DeepSeekBalanceResponse: Decodable {
    struct Balance: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    let isAvailable: Bool
    let balanceInfos: [Balance]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

enum AIServiceError: LocalizedError {
    case missingAPIKey(String)
    case invalidConfiguration(String)
    case invalidResponse
    case emptyResponse(String)
    case http(status: Int, message: String)
    case streamingUnsupported(String)
    case noConfiguredProvider
    case routingFailed(String, underlying: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "尚未保存 \(provider) API Key"
        case .invalidConfiguration(let message): message
        case .invalidResponse: "服务返回了无效响应"
        case .emptyResponse(let details): "模型没有返回最终文字内容。响应摘要：\(details)"
        case .http(let status, let message): "API 请求失败（HTTP \(status)）：\(message)"
        case .streamingUnsupported(let provider): "当前透明流式生成支持 DeepSeek 和 Gemini，已选择 \(provider)"
        case .noConfiguredProvider:
            String(localized: "没有可用的 AI 服务。请先在设置中配置并启用至少一个 API。")
        case .routingFailed(let details, _):
            String(
                format: String(localized: "所有已启用的 AI 服务都调用失败：\n%@"),
                details
            )
        }
    }
}
