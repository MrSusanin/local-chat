import Foundation

// MARK: - Запрос к облачному ИИ

struct AttachmentPayload {
    let kind: ModelCapability
    let mimeType: String
    let fileName: String
    let data: Data

    var base64: String { data.base64EncodedString() }
}

struct ProviderMessage {
    let role: ChatMessage.Role
    let text: String
    let attachments: [AttachmentPayload]
}

struct ProviderRequest {
    let systemPrompt: String
    let history: [ProviderMessage]
    let userMessage: ProviderMessage
    let maxTokens: Int
}

// MARK: - Ошибки

enum AIProviderError: LocalizedError {
    case missingAPIKey
    case server(provider: String, status: Int, message: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Не указан API ключ. Откройте экран выбора ИИ и введите ключ."
        case .server(let provider, let status, let message):
            let trimmed = message.count > 300 ? String(message.prefix(300)) + "…" : message
            if status > 0 {
                return "\(provider) ответил ошибкой (код \(status)): \(trimmed)"
            }
            return "\(provider): \(trimmed)"
        case .badResponse(let message):
            return "Не удалось понять ответ сервера: \(message)"
        }
    }
}

// MARK: - Клиенты

/// Единый интерфейс облачных ИИ: поток текстовых кусочков ответа.
protocol AIProviderClient {
    var provider: AIProvider { get }
    var modelName: String { get }

    func stream(_ request: ProviderRequest, apiKey: String) -> AsyncThrowingStream<String, Error>
}

enum AIProviderClientFactory {
    /// Клиент для облачного провайдера. Для локального возвращает nil:
    /// локальная модель работает через MLX внутри ChatViewModel.
    static func client(provider: AIProvider, modelName: String) -> AIProviderClient? {
        switch provider {
        case .local:
            return nil
        case .openAI:
            return OpenAICompatibleClient(
                provider: .openAI,
                modelName: modelName,
                baseURL: URL(string: "https://api.openai.com/v1")!
            )
        case .groq:
            return OpenAICompatibleClient(
                provider: .groq,
                modelName: modelName,
                baseURL: URL(string: "https://api.groq.com/openai/v1")!
            )
        case .gemini:
            return GeminiClient(modelName: modelName)
        }
    }
}

// MARK: - OpenAI-совместимый API (OpenAI и Groq)

/// Клиент API, совместимого с OpenAI. Сам OpenAI и Groq говорят на этом языке.
struct OpenAICompatibleClient: AIProviderClient {
    let provider: AIProvider
    let modelName: String
    let baseURL: URL

    func stream(_ request: ProviderRequest, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request: request, apiKey: apiKey, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        request: ProviderRequest,
        apiKey: String,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 180
        urlRequest.httpBody = try Self.makeBody(request: request, modelName: modelName)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.badResponse("нет HTTP-ответа")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = await SSEHelpers.errorBody(from: bytes)
            throw AIProviderError.server(provider: provider.title, status: http.statusCode, message: message)
        }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
            if let text = Self.textDelta(from: data), !text.isEmpty {
                continuation.yield(text)
            }
        }
    }

    // MARK: Сборка запроса

    private static func makeBody(request: ProviderRequest, modelName: String) throws -> Data {
        var messages: [[String: Any]] = []
        let system = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for old in request.history {
            messages.append([
                "role": roleKey(old.role),
                "content": contentValue(text: old.text, attachments: old.attachments)
            ])
        }
        let user = request.userMessage
        messages.append([
            "role": roleKey(user.role),
            "content": contentValue(text: user.text, attachments: user.attachments)
        ])

        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "temperature": 0.6,
            "max_tokens": request.maxTokens
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func roleKey(_ role: ChatMessage.Role) -> String {
        role == .user ? "user" : "assistant"
    }

    /// Текст превращается в строку, а сообщение с вложениями — в массив частей
    /// (так OpenAI принимает фото и аудио).
    private static func contentValue(text: String, attachments: [AttachmentPayload]) -> Any {
        let usable = attachments.filter { $0.data.count <= PendingAttachment.maxSize }
        guard !usable.isEmpty else { return text.isEmpty ? " " : text }

        var parts: [[String: Any]] = []
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(["type": "text", "text": prompt.isEmpty ? "Опиши вложение." : prompt])
        for attachment in usable {
            switch attachment.kind {
            case .image:
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(attachment.mimeType);base64,\(attachment.base64)"]
                ])
            case .audio:
                parts.append([
                    "type": "input_audio",
                    "input_audio": [
                        "data": attachment.base64,
                        "format": audioFormat(mimeType: attachment.mimeType)
                    ]
                ])
            default:
                // Документы этот формат не поддерживает: пропускаем.
                continue
            }
        }
        return parts
    }

    private static func audioFormat(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        default: return "wav"
        }
    }

    // MARK: Разбор ответа

    private static func textDelta(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let delta = choice["delta"] as? [String: Any] else {
            return nil
        }
        return delta["content"] as? String
    }
}

// MARK: - Google Gemini

/// Клиент Google Gemini: потоковая генерация через server-sent events.
struct GeminiClient: AIProviderClient {
    let provider: AIProvider = .gemini
    let modelName: String

    private static let apiBase = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    func stream(_ request: ProviderRequest, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request: request, apiKey: apiKey, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        request: ProviderRequest,
        apiKey: String,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }

        let encoded = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelName
        let path = Self.apiBase
            .appendingPathComponent("models")
            .appendingPathComponent("\(encoded):streamGenerateContent")
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        // alt=sse — поток в формате server-sent events.
        components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let url = components?.url else {
            throw AIProviderError.badResponse("не удалось собрать адрес запроса")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.timeoutInterval = 180
        urlRequest.httpBody = try Self.makeBody(request: request)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.badResponse("нет HTTP-ответа")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = await SSEHelpers.errorBody(from: bytes)
            throw AIProviderError.server(provider: "Google Gemini", status: http.statusCode, message: message)
        }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
            let parsed = Self.parseChunk(data)
            if let message = parsed.error {
                throw AIProviderError.server(provider: "Google Gemini", status: 0, message: message)
            }
            if !parsed.text.isEmpty {
                continuation.yield(parsed.text)
            }
        }
    }

    // MARK: Сборка запроса

    private static func makeBody(request: ProviderRequest) throws -> Data {
        var contents: [[String: Any]] = []
        for message in request.history {
            contents.append([
                "role": message.role == .user ? "user" : "model",
                "parts": parts(text: message.text, attachments: message.attachments)
            ])
        }
        let user = request.userMessage
        contents.append([
            "role": "user",
            "parts": parts(text: user.text, attachments: user.attachments)
        ])

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": ["maxOutputTokens": request.maxTokens, "temperature": 0.6]
        ]
        let system = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Текст и вложения (фото, аудио, PDF) уходят как «части» одного сообщения.
    private static func parts(text: String, attachments: [AttachmentPayload]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result.append(["text": prompt.isEmpty ? "Опиши вложение." : prompt])
        for attachment in attachments where attachment.data.count <= PendingAttachment.maxSize {
            result.append([
                "inlineData": [
                    "mimeType": attachment.mimeType,
                    "data": attachment.base64
                ]
            ])
        }
        return result
    }

    // MARK: Разбор ответа

    private static func parseChunk(_ data: Data) -> (text: String, error: String?) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ("", nil)
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return ("", message)
        }
        var text = ""
        if let candidates = json["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                if let content = candidate["content"] as? [String: Any],
                   let chunks = content["parts"] as? [[String: Any]] {
                    for chunk in chunks {
                        if let piece = chunk["text"] as? String {
                            text += piece
                        }
                    }
                }
            }
        }
        return (text, nil)
    }
}

// MARK: - Общие помощники

enum SSEHelpers {
    /// Читает тело ошибочного ответа и вытаскивает из него понятное сообщение.
    static func errorBody(from bytes: URLSession.AsyncBytes) async -> String {
        var collected = ""
        do {
            var lines = 0
            for try await line in bytes.lines {
                collected += line + "\n"
                lines += 1
                if lines >= 30 { break }
            }
        } catch {}
        if let data = collected.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return collected.isEmpty ? "нет описания ошибки" : collected
    }
}
