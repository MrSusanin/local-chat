import Foundation

// MARK: - Провайдеры ИИ

/// Кто отвечает на сообщения: локальная модель на iPhone или облачный сервис.
enum AIProvider: String, CaseIterable, Identifiable {
    case local
    case openAI = "openai"
    case gemini
    case groq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "На iPhone"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        }
    }

    /// Короткое название для сегментированного переключателя.
    var shortTitle: String {
        switch self {
        case .local: return "На iPhone"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        }
    }

    /// Модели, доступные у провайдера.
    var models: [AIModelOption] {
        switch self {
        case .local: return Self.localModels
        case .openAI: return Self.openAIModels
        case .gemini: return Self.geminiModels
        case .groq: return Self.groqModels
        }
    }

    var defaultModelName: String {
        models.first?.name ?? ""
    }

    /// Пояснение, что происходит при выборе провайдера.
    var summary: String {
        switch self {
        case .local:
            return "Модель скачивается на iPhone один раз (лучше по Wi‑Fi) и дальше работает без интернета."
        case .openAI:
            return "Запросы уходят в облако OpenAI. Нужен API ключ с platform.openai.com."
        case .gemini:
            return "Запросы уходят в облако Google. Нужен API ключ с aistudio.google.com."
        case .groq:
            return "Очень быстрое облако Groq. Нужен API ключ с console.groq.com."
        }
    }

    // MARK: Каталоги моделей

    /// Локальные модели MLX. Подойдут любые 4-битные из mlx-community до ~3B.
    static let localModels: [AIModelOption] = [
        AIModelOption(
            name: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            title: "Qwen 2.5 · 1.5B",
            detail: "Около 1 ГБ. Рекомендуется: умная и хорошо понимает русский.",
            capabilities: [.text]
        ),
        AIModelOption(
            name: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            title: "Qwen 2.5 · 0.5B",
            detail: "Около 0,4 ГБ. Очень быстрая, но отвечает проще.",
            capabilities: [.text]
        ),
        AIModelOption(
            name: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            title: "Llama 3.2 · 1B",
            detail: "Около 0,7 ГБ. Лучше всего говорит по-английски.",
            capabilities: [.text]
        ),
        AIModelOption(
            name: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            title: "Qwen 2.5 · 3B",
            detail: "Около 1,9 ГБ. Заметно умнее остальных, но требует много памяти: на iPhone с 4 ГБ ОЗУ может не запуститься.",
            capabilities: [.text],
            isSuper: true
        )
    ]

    static let openAIModels: [AIModelOption] = [
        AIModelOption(
            name: "gpt-4o-mini",
            title: "GPT‑4o mini",
            detail: "Быстрая и дешёвая. Понимает фото.",
            capabilities: [.text, .image]
        ),
        AIModelOption(
            name: "gpt-4o",
            title: "GPT‑4o",
            detail: "Умнее и дороже. Понимает фото.",
            capabilities: [.text, .image],
            isSuper: true
        ),
        AIModelOption(
            name: "gpt-4o-audio-preview",
            title: "GPT‑4o audio",
            detail: "Понимает фото и аудио (голосовые заметки, музыка).",
            capabilities: [.text, .image, .audio]
        )
    ]

    static let geminiModels: [AIModelOption] = [
        AIModelOption(
            name: "gemini-2.0-flash",
            title: "Gemini 2.0 Flash",
            detail: "Быстрая, щедрая бесплатная квота. Понимает фото, аудио и PDF.",
            capabilities: [.text, .image, .audio, .document]
        ),
        AIModelOption(
            name: "gemini-2.5-flash",
            title: "Gemini 2.5 Flash",
            detail: "Новее и умнее. Понимает фото, аудио и PDF.",
            capabilities: [.text, .image, .audio, .document]
        ),
        AIModelOption(
            name: "gemini-2.5-pro",
            title: "Gemini 2.5 Pro",
            detail: "Самая умная модель Google. Понимает фото, аудио и PDF.",
            capabilities: [.text, .image, .audio, .document],
            isSuper: true
        )
    ]

    static let groqModels: [AIModelOption] = [
        AIModelOption(
            name: "llama-3.1-8b-instant",
            title: "Llama 3.1 · 8B",
            detail: "Молниеносно быстрая. Только текст.",
            capabilities: [.text]
        ),
        AIModelOption(
            name: "llama-3.3-70b-versatile",
            title: "Llama 3.3 · 70B",
            detail: "Супер-модель в облаке: очень умная и всё ещё быстрая. Только текст.",
            capabilities: [.text],
            isSuper: true
        )
    ]
}

// MARK: - Возможности модели

/// Что модель умеет принимать вместе с текстом. По этим возможностям
/// над полем ввода появляются кнопки «фото», «аудио» и «документ».
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

// MARK: - Описание модели

struct AIModelOption: Identifiable, Hashable {
    /// Для локальных моделей — репозиторий на Hugging Face, для облаков — имя модели в API.
    let name: String
    let title: String
    let detail: String
    let capabilities: Set<ModelCapability>
    /// «Супер-модель»: крупнее и умнее обычных.
    var isSuper: Bool = false

    var id: String { name }
}
