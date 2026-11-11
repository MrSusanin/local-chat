import Foundation

// Keep this list aligned with the operations actually implemented by AIProviderClient.
enum AIProvider: String, CaseIterable, Identifiable {
    case local
    case openAI = "openai"
    case gemini
    case groq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local MLX"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        }
    }

    var defaultModelName: String {
        switch self {
        case .local: return "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case .openAI: return "gpt-4o-mini"
        case .gemini: return "gemini-2.0-flash"
        case .groq: return "llama-3.1-8b-instant"
        }
    }

    var supportedCapabilities: [ModelCapability] {
        switch self {
        case .local: return [.text]
        case .openAI: return [.text, .image]
        case .gemini: return [.text, .image]
        case .groq: return [.text]
        }
    }
}

enum ModelCapability: String, CaseIterable, Identifiable {
    case text
    case image
    case audio
    case document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Текст"
        case .image: return "Фото"
        case .audio: return "Аудио"
        case .document: return "Документ"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .audio: return "waveform"
        case .document: return "doc.fill"
        }
    }
}

struct AIModelProfile {
    let provider: AIProvider
    let modelName: String
    let capabilities: [ModelCapability]
}
