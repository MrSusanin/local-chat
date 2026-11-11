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
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is required for this provider."
        case .unsupportedCapability(let capability):
            return "This provider does not support the capability: \(capability.title)."
        case .notImplemented(let message):
            return message
        }
    }
}

struct LocalMLXClient: AIProviderClient {
    let provider: AIProvider = .local
    let modelName: String

    func sendText(_ text: String, apiKey: String?) async throws -> String {
        // Local MLX chat remains handled by the current ChatViewModel and MLX pipeline.
        // This placeholder keeps the provider contract consistent with other providers.
        return "Local MLX processing is handled by the app's local model engine."
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
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return "OpenAI text request prepared for model \(modelName)."
    }

    func sendImage(_ imageData: Data, prompt: String, apiKey: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return "OpenAI image request prepared for model \(modelName)."
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

    func sendText(_ text: String, apiKey: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return "Gemini text request prepared for model \(modelName)."
    }

    func sendImage(_ imageData: Data, prompt: String, apiKey: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return "Gemini image request prepared for model \(modelName)."
    }

    func sendAudio(_ audioData: Data, prompt: String, apiKey: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return "Gemini audio request prepared for model \(modelName)."
    }

    func sendDocument(_ documentData: Data, prompt: String, apiKey: String?) async throws -> String {
        throw AIProviderError.unsupportedCapability(.document)
    }
}

struct GroqClient: AIProviderClient {
    let provider: AIProvider = .groq
    let modelName: String

    func sendText(_ text: String, apiKey: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey }
        return "Groq text request prepared for model \(modelName)."
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

extension AIProviderClient {
    func makeClient(for provider: AIProvider, modelName: String) -> AIProviderClient {
        switch provider {
        case .local:
            return LocalMLXClient(modelName: modelName)
        case .openAI:
            return OpenAIClient(modelName: modelName)
        case .gemini:
            return GeminiClient(modelName: modelName)
        case .groq:
            return GroqClient(modelName: modelName)
        }
    }
}
