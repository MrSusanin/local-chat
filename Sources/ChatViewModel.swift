import SwiftUI
import UIKit
import MLXLLM
import MLXLMCommon

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
}

struct ModelOption: Identifiable, Hashable {
    let id: String        // идентификатор репозитория на Hugging Face
    let title: String
    let detail: String
}

enum LoadState: Equatable {
    case idle
    case downloading(Double)
    case ready
    case failed(String)
}

@MainActor
final class ChatViewModel: ObservableObject {
    static let models: [ModelOption] = [
        ModelOption(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            title: "Qwen 2.5 · 1.5B (рекомендуется)",
            detail: "Около 1 ГБ. Умнее, лучше понимает русский."
        ),
        ModelOption(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            title: "Qwen 2.5 · 0.5B (быстрая)",
            detail: "Около 0,4 ГБ. Очень быстрая, но отвечает проще."
        ),
        ModelOption(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            title: "Llama 3.2 · 1B",
            detail: "Около 0,7 ГБ. Лучше всего говорит по-английски."
        )
    ]

    private let systemPrompt =
        "Ты дружелюбный и полезный ассистент. Отвечай на том языке, на котором пишет пользователь. " +
        "Отвечай кратко и по делу. Если не знаешь ответа, так и скажи."

    @Published var messages: [ChatMessage] = []
    @Published var loadState: LoadState = .idle
    @Published var selectedModelID: String
    @Published private(set) var isGenerating = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = isGenerating }
    }

    private var container: ModelContainer?
    private var session: ChatSession?
    private var generationTask: Task<Void, Never>?
    private var currentToken: UUID?

    init() {
        selectedModelID = UserDefaults.standard.string(forKey: "selectedModel") ?? Self.models[0].id
    }

    // MARK: - Модель

    /// Если модель уже скачивали, запускаем её сразу при открытии приложения.
    func autoLoadIfPossible() {
        guard case .idle = loadState else { return }
        if UserDefaults.standard.bool(forKey: "downloaded.\(selectedModelID)") {
            loadModel()
        }
    }

    func loadModel() {
        if case .downloading = loadState { return }
        let id = selectedModelID
        UserDefaults.standard.set(id, forKey: "selectedModel")
        loadState = .downloading(0)

        Task {
            do {
                let loaded = try await LLMModelFactory.shared.loadContainer(
                    configuration: ModelConfiguration(id: id)
                ) { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self?.updateProgress(fraction)
                    }
                }
                container = loaded
                session = makeSession(for: loaded)
                messages = []
                UserDefaults.standard.set(true, forKey: "downloaded.\(id)")
                loadState = .ready
            } catch {
                loadState = .failed(
                    "Не удалось загрузить модель: \(error.localizedDescription)\n" +
                    "Проверьте интернет и свободное место, затем попробуйте ещё раз."
                )
            }
        }
    }

    private func updateProgress(_ fraction: Double) {
        if case .downloading = loadState {
            loadState = .downloading(min(max(fraction, 0), 1))
        }
    }

    func unloadModel() {
        stop()
        session = nil
        container = nil
        messages = []
        loadState = .idle
    }

    private func makeSession(for container: ModelContainer) -> ChatSession {
        ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: GenerateParameters(maxTokens: 800, temperature: 0.6, topP: 0.9)
        )
    }

    // MARK: - Чат

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating, let session else { return }

        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(reply)

        let replyID = reply.id
        let token = UUID()
        currentToken = token
        isGenerating = true

        generationTask = Task {
            do {
                for try await chunk in session.streamResponse(to: prompt) {
                    if Task.isCancelled { break }
                    append(chunk, to: replyID)
                }
            } catch {
                if !(error is CancellationError) {
                    append("\n\n⚠️ \(error.localizedDescription)", to: replyID)
                }
            }
            if currentToken == token {
                isGenerating = false
                currentToken = nil
            }
        }
    }

    /// Останавливает генерацию (также вызывается при сворачивании приложения:
    /// iOS не разрешает приложению считать на GPU в фоне).
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        currentToken = nil
        isGenerating = false
    }

    func newChat() {
        stop()
        messages = []
        if let container {
            session = makeSession(for: container)
        }
    }

    private func append(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }
}
