import Foundation

protocol AIProviderClient {
    var provider: AIProvider { get }
    var modelName: String { get }

    func sendText(_ text: String, apiKey: String?) async throws -> String
    func sendImage(_ imageData: Data, prompt: String, apiKey: String?) async throws -> String
    func sendAudio(_ audioData: Data, prompt: String, apiKey: String?) async throws -> String
    func sendDocument(_ documentData: Data, prompt: String, apiKey: String?) async throws -> String
}

enum AIProviderError: LocalizedError {
    case missingAPIKey
    case unsupportedCapability(ModelCapability)
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Сначала добавьте API-ключ выбранного провайдера в настройках."
        case .unsupportedCapability(let capability):
            return "Выбранный провайдер не поддерживает функцию «\(capability.title)»."
        case .invalidResponse:
            return "Провайдер вернул ответ в неизвестном формате."
        case .httpError(let statusCode, let message):
            return "Ошибка API (HTTP \(statusCode)): \(message)"
        }
    }
}

enum AIProviderClientFactory {
    static func make(provider: AIProvider, modelName: String) -> AIProviderClient {
        switch provider {
        case .local: return LocalMLXClient(modelName: modelName)
        case .openAI: return OpenAIClient(modelName: modelName)
        case .gemini: return GeminiClient(modelName: modelName)
        case .groq: return GroqClient(modelName: modelName)
        }
    }
}

private enum HTTPAI {
    static let session = URLSession(configuration: .ephemeral)

    static func requireKey(_ key: String?) throws -> String {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.missingAPIKey
        }
        return key
    }

    static func postJSON(url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
                ?? String(data: data.prefix(500), encoding: .utf8)
                ?? "Неизвестная ошибка"
            throw AIProviderError.httpError(statusCode: http.statusCode, message: message)
        }
        return data
    }

    static func openAIText(_ data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw AIProviderError.invalidResponse }
        return content
    }

    static func geminiText(_ data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { throw AIProviderError.invalidResponse }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    static func imageMIME(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.starts(with: [0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return "image/jpeg"
    }
}

struct LocalMLXClient: AIProviderClient {
    let provider: AIProvider = .local
    let modelName: String

    func sendText(_ text: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.text)
    }
    func sendImage(_ imageData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.image)
    }
    func sendAudio(_ audioData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.audio)
    }
    func sendDocument(_ documentData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.document)
    }
}

struct OpenAIClient: AIProviderClient {
    let provider: AIProvider = .openAI
    let modelName: String

    func sendText(_ text: String, apiKey: String?) async throws -> String {
        let key = try HTTPAI.requireKey(apiKey)
        let data = try await HTTPAI.postJSON(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: ["model": modelName, "messages": [["role": "user", "content": text]]]
        )
        return try HTTPAI.openAIText(data)
    }

    func sendImage(_ imageData: Data, prompt: String, apiKey: String?) async throws -> String {
        let key = try HTTPAI.requireKey(apiKey)
        let mime = HTTPAI.imageMIME(imageData)
        let imageURL = "data:\(mime);base64,\(imageData.base64EncodedString())"
        let content: [[String: Any]] = [
            ["type": "text", "text": prompt.isEmpty ? "Опиши изображение." : prompt],
            ["type": "image_url", "image_url": ["url": imageURL]]
        ]
        let data = try await HTTPAI.postJSON(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: ["model": modelName, "messages": [["role": "user", "content": content]]]
        )
        return try HTTPAI.openAIText(data)
    }

    func sendAudio(_ audioData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.audio)
    }
    func sendDocument(_ documentData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.document)
    }
}

struct GeminiClient: AIProviderClient {
    let provider: AIProvider = .gemini
    let modelName: String

    private func endpoint(apiKey: String) throws -> URL {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw AIProviderError.invalidResponse }
        return url
    }

    func sendText(_ text: String, apiKey: String?) async throws -> String {
        let key = try HTTPAI.requireKey(apiKey)
        let data = try await HTTPAI.postJSON(
            url: endpoint(apiKey: key),
            headers: [:],
            body: ["contents": [["parts": [["text": text]]]]]
        )
        return try HTTPAI.geminiText(data)
    }

    func sendImage(_ imageData: Data, prompt: String, apiKey: String?) async throws -> String {
        let key = try HTTPAI.requireKey(apiKey)
        let parts: [[String: Any]] = [
            ["text": prompt.isEmpty ? "Опиши изображение." : prompt],
            ["inline_data": ["mime_type": HTTPAI.imageMIME(imageData), "data": imageData.base64EncodedString()]]
        ]
        let data = try await HTTPAI.postJSON(
            url: endpoint(apiKey: key),
            headers: [:],
            body: ["contents": [["parts": parts]]]
        )
        return try HTTPAI.geminiText(data)
    }

    func sendAudio(_ audioData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.audio)
    }
    func sendDocument(_ documentData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.document)
    }
}

struct GroqClient: AIProviderClient {
    let provider: AIProvider = .groq
    let modelName: String

    func sendText(_ text: String, apiKey: String?) async throws -> String {
        let key = try HTTPAI.requireKey(apiKey)
        let data = try await HTTPAI.postJSON(
            url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: ["model": modelName, "messages": [["role": "user", "content": text]]]
        )
        return try HTTPAI.openAIText(data)
    }

    func sendImage(_ imageData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.image)
    }
    func sendAudio(_ audioData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.audio)
    }
    func sendDocument(_ documentData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.document)
    }
}
