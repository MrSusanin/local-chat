import SwiftUI
import UIKit
import os
import MLXLLM
import MLXLMCommon

// MARK: - Модели данных

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]
}

struct ModelOption: Identifiable, Hashable {
    let id: String        // идентификатор репозитория на Hugging Face
    let title: String
    let detail: String
}

enum LoadState: Equatable {
    case idle
    case starting               // модель уже скачана, загружаем в память
    case downloading(Double)
    case ready
    case failed(String)
}

/// Режим нагрузки на телефон. Меняет не саму модель, а то, как приложение с ней работает:
/// как часто обновляется экран, какими порциями читаются длинные тексты, есть ли паузы
/// между порциями и какой длины бывают ответы.
enum PerformanceMode: String, CaseIterable, Identifiable {
    case eco, balanced, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eco: return "Экономный"
        case .balanced: return "Сбалансированный"
        case .max: return "Максимальный"
        }
    }

    var detail: String {
        switch self {
        case .eco:
            return "Меньше нагрузки и нагрева, интерфейс не лагает. Экран обновляется реже, длинные тексты читаются мелкими частями с паузами, ответы до ~500 токенов."
        case .balanced:
            return "Золотая середина для повседневной работы. Ответы до ~800 токенов."
        case .max:
            return "Самые быстрые обновления и самые длинные ответы (до ~1200 токенов). Телефон греется сильнее, возможны подтормаживания."
        }
    }

    /// Как часто (в секундах) обновляется текст ответа на экране.
    var uiInterval: TimeInterval {
        switch self {
        case .eco: return 0.35
        case .balanced: return 0.12
        case .max: return 0.03
        }
    }

    var maxTokens: Int {
        switch self {
        case .eco: return 500
        case .balanced: return 800
        case .max: return 1200
        }
    }

    /// Размер одной части при чтении длинного текста (в символах).
    var chunkSize: Int {
        switch self {
        case .eco: return 1800
        case .balanced: return 2500
        case .max: return 3000
        }
    }

    /// Пауза между частями длинного текста, чтобы телефон успевал остыть.
    var pauseSeconds: Double {
        switch self {
        case .eco: return 1.5
        case .balanced: return 0.4
        case .max: return 0
        }
    }
}

private enum LongTextError: LocalizedError {
    case lowMemory

    var errorDescription: String? {
        "Не хватает памяти для обработки длинного текста. Закройте другие приложения или вставьте текст покороче."
    }
}

// MARK: - ViewModel

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

    // Пороговые значения (в символах). Подобраны для iPhone с 4 ГБ памяти.
    private static let longTextThreshold = 3000      // выше этого текст обрабатывается по частям
    private static let maxLongTextChars = 60_000     // больше не читаем
    private static let notesLimit = 6000             // максимум выжимок, которые отдаём в финальный запрос
    private static let sessionResetChars = 6000      // после этого объёма диалога контекст пересобирается
    private static let mb = 1_048_576
    private static let writeQueue = DispatchQueue(label: "localchat.store", qos: .utility)

    private let baseSystemPrompt =
        "Ты дружелюбный и полезный ассистент. Отвечай на том языке, на котором пишет пользователь. " +
        "Отвечай кратко и по делу. Если не знаешь ответа, так и скажи."

    @Published var messages: [ChatMessage] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentID = UUID()
    @Published var loadState: LoadState
    @Published var selectedModelID: String
    @Published private(set) var isGenerating = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = isGenerating }
    }

    /// Режим нагрузки. Новый режим применяется со следующего сообщения.
    @Published var mode: PerformanceMode = .balanced {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "perfMode")
            sessionDirty = true
        }
    }

    /// Свои инструкции для ассистента (например, «отвечай коротко»).
    @Published var customInstructions: String = "" {
        didSet {
            if customInstructions.count > 500 {
                customInstructions = String(customInstructions.prefix(500))
            }
            UserDefaults.standard.set(customInstructions, forKey: "customInstructions")
            sessionDirty = true
        }
    }

    /// Какие сообщения пользователь вручную свернул или развернул.
    @Published private(set) var toggledIDs: Set<UUID> = []

    /// Просьбы к экрану прокрутить: к началу нового сообщения или в самый низ.
    @Published private(set) var scrollRequest: UUID?
    @Published private(set) var bottomRequest = 0

    /// Сообщение, написанное, пока модель ещё запускалась.
    @Published private(set) var queuedPrompt: String?

    private var loadAttempt: UUID?
    private var container: ModelContainer?
    private var session: ChatSession?
    private var sessionChars = 0
    private var sessionDirty = false
    private var isLoadingModel = false
    private var generationTask: Task<Void, Never>?
    private var currentToken: UUID?
    private let storeURL: URL

    init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "selectedModel") ?? Self.models[0].id
        selectedModelID = id
        // Если модель уже скачана, сразу показываем «запуск», а не экран выбора.
        loadState = defaults.bool(forKey: "downloaded.\(id)") ? .starting : .idle
        storeURL = Self.makeStoreURL()

        mode = PerformanceMode(rawValue: defaults.string(forKey: "perfMode") ?? "") ?? .balanced
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""

        conversations = Self.readConversations(from: storeURL)
        if let last = conversations.first {
            currentID = last.id
            messages = last.messages
        }
    }

    private var systemPrompt: String {
        var prompt = baseSystemPrompt
        let extra = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            prompt += "\n\nДополнительные инструкции пользователя: " + extra
        }
        return prompt
    }

    // MARK: - Модель

    func autoLoadIfPossible() {
        if case .starting = loadState { loadModel() }
    }

    func loadModel() {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        let attempt = UUID()
        loadAttempt = attempt

        let id = selectedModelID
        let defaults = UserDefaults.standard
        defaults.set(id, forKey: "selectedModel")
        let wasDownloaded = defaults.bool(forKey: "downloaded.\(id)")
        loadState = wasDownloaded ? .starting : .downloading(0)
        // Если модель уже скачана, читаем её прямо из папки на телефоне
        // и не обращаемся к Hugging Face при каждом запуске.
        let localURL = wasDownloaded ? Self.localModelURL(for: id) : nil

        Task {
            do {
                let loaded = try await openContainer(id: id, localURL: localURL)
                guard loadAttempt == attempt else { return }   // модель успели сменить
                container = loaded
                session = makeSession(for: loaded, transcript: contextTranscript())
                sessionDirty = false
                defaults.set(true, forKey: "downloaded.\(id)")
                loadState = .ready
                isLoadingModel = false

                if let queued = queuedPrompt {
                    queuedPrompt = nil
                    send(queued)
                } else {
                    warmUp(loaded)
                }
            } catch {
                guard loadAttempt == attempt else { return }
                loadState = .failed(
                    "Не удалось загрузить модель: \(error.localizedDescription)\n" +
                    "Проверьте интернет и свободное место, затем попробуйте ещё раз."
                )
                queuedPrompt = nil
                isLoadingModel = false
            }
        }
    }

    /// Сначала пробуем быструю загрузку из локальной папки, при неудаче обычную.
    private func openContainer(id: String, localURL: URL?) async throws -> ModelContainer {
        let handler: @Sendable (Progress) -> Void = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self?.updateProgress(fraction)
            }
        }

        if let localURL {
            do {
                return try await LLMModelFactory.shared.loadContainer(
                    configuration: ModelConfiguration(directory: localURL)
                ) { handler($0) }
            } catch {
                // Не вышло (например, другая структура папок): загружаем обычным способом.
            }
        }
        return try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: id)
        ) { handler($0) }
    }

    /// Где библиотека хранит скачанную модель. Если файлов там нет, возвращает nil.
    private static func localModelURL(for id: String) -> URL? {
        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("huggingface/models/\(id)", isDirectory: true)
        guard manager.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            return nil
        }
        let files = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        guard files.contains(where: { $0.hasSuffix(".safetensors") }) else { return nil }
        return directory
    }

    /// «Прогрев»: один крошечный запрос, пока вы читаете экран или печатаете.
    /// Первый настоящий ответ после этого приходит быстрее.
    private func warmUp(_ container: ModelContainer) {
        Task(priority: .utility) {
            let temporary = ChatSession(
                container,
                instructions: "Отвечай одним словом.",
                generateParameters: GenerateParameters(maxTokens: 1, temperature: 0)
            )
            _ = try? await temporary.respond(to: "Привет")
        }
    }

    // MARK: - Сообщение, отправленное во время запуска модели

    /// Пока модель запускается, сообщение можно написать: оно уйдёт само, когда всё будет готово.
    func queue(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, queuedPrompt == nil else { return }
        queuedPrompt = prompt
    }

    /// Отменяет ожидающее сообщение и возвращает его текст.
    func takeQueued() -> String {
        let text = queuedPrompt ?? ""
        queuedPrompt = nil
        return text
    }

    private func updateProgress(_ fraction: Double) {
        let value = min(max(fraction, 0), 1)
        switch loadState {
        case .downloading:
            loadState = .downloading(value)
        case .starting:
            // Файлов на устройстве не оказалось: показываем честный прогресс скачивания.
            if value > 0.02 && value < 0.98 { loadState = .downloading(value) }
        default:
            break
        }
    }

    func unloadModel() {
        stop()
        saveCurrent()
        loadAttempt = nil          // результат незавершённой загрузки будет отброшен
        isLoadingModel = false
        queuedPrompt = nil
        session = nil
        container = nil
        loadState = .idle
    }

    private func makeSession(for container: ModelContainer, transcript: String? = nil) -> ChatSession {
        var instructions = systemPrompt
        if let transcript {
            instructions +=
                "\n\nЭто продолжение прежнего разговора. Вот его последние сообщения, " +
                "учитывай их как контекст (не пересказывай их без просьбы):\n" + transcript
        }
        sessionChars = 0
        return ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: mode.maxTokens, temperature: 0.6, topP: 0.9)
        )
    }

    /// Краткая выдержка из последних сообщений. Нужна, чтобы продолжить сохранённый чат
    /// и не держать в памяти огромный контекст.
    private func contextTranscript() -> String? {
        let recent = messages.filter { !$0.text.isEmpty && !$0.text.hasPrefix("⏳") }.suffix(8)
        guard !recent.isEmpty else { return nil }
        var lines: [String] = []
        for message in recent {
            let who = message.role == .user ? "Пользователь" : "Ассистент"
            let body = message.text.count > 600 ? String(message.text.prefix(600)) + "…" : message.text
            lines.append("\(who): \(body)")
        }
        var result = lines.joined(separator: "\n")
        if result.count > 3000 { result = String(result.suffix(3000)) }
        return result
    }

    // MARK: - Свёрнутые сообщения

    func isLong(_ message: ChatMessage) -> Bool {
        let isUser = message.role == .user
        if message.text.count > (isUser ? 500 : 1500) { return true }
        let lines = message.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return lines > (isUser ? 8 : 40)
    }

    /// Сообщения пользователя по умолчанию свёрнуты, если они длинные.
    /// Ответы ассистента по умолчанию развёрнуты, но их тоже можно свернуть.
    func isCollapsed(_ message: ChatMessage, streaming: Bool) -> Bool {
        guard !streaming, isLong(message) else { return false }
        let toggled = toggledIDs.contains(message.id)
        return message.role == .user ? !toggled : toggled
    }

    func toggleCollapse(_ id: UUID) {
        if toggledIDs.contains(id) {
            toggledIDs.remove(id)
        } else {
            toggledIDs.insert(id)
        }
    }

    // MARK: - Отправка сообщений

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating, let container else { return }

        guard hasEnoughMemory(minBytes: 250 * Self.mb) else {
            messages.append(ChatMessage(role: .user, text: prompt))
            messages.append(ChatMessage(
                role: .assistant,
                text: "⚠️ Не хватает памяти. Закройте другие приложения и попробуйте ещё раз."
            ))
            saveCurrent()
            return
        }

        // Пересобираем сессию, если диалог разросся, сменились настройки
        // или прошлая генерация была прервана.
        if session == nil || sessionDirty || sessionChars > Self.sessionResetChars {
            session = makeSession(for: container, transcript: contextTranscript())
            sessionDirty = false
        }
        guard let session else { return }

        let userMessage = ChatMessage(role: .user, text: prompt)
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(userMessage)
        messages.append(reply)
        // Экран прокручивается к вопросу, а не к концу ответа, поэтому не «прыгает».
        scrollRequest = userMessage.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let replyID = reply.id
        let token = UUID()
        currentToken = token
        isGenerating = true
        let isLongPrompt = prompt.count > Self.longTextThreshold
        let interval = mode.uiInterval

        generationTask = Task {
            var finalPrompt = prompt
            var footnote = ""
            var buffer = ""
            var lastFlush = Date()
            do {
                if isLongPrompt {
                    let prepared = try await prepareLongText(prompt, container: container, replyID: replyID)
                    finalPrompt = prepared.prompt
                    footnote = prepared.footnote
                    setText("", for: replyID)
                }

                var produced = 0
                for try await chunk in session.streamResponse(to: finalPrompt) {
                    if Task.isCancelled { break }
                    buffer += chunk
                    produced += 1

                    // Экран обновляется порциями: так интерфейс не лагает.
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= interval {
                        append(buffer, to: replyID)
                        buffer = ""
                        lastFlush = now
                    }

                    if produced % 24 == 0, !hasEnoughMemory(minBytes: 120 * Self.mb) {
                        buffer += "\n\n⚠️ Не хватает памяти, ответ остановлен."
                        break
                    }
                }
                if !buffer.isEmpty {
                    append(buffer, to: replyID)
                    buffer = ""
                }
                if !footnote.isEmpty && !Task.isCancelled {
                    append(footnote, to: replyID)
                }
            } catch {
                if !buffer.isEmpty {
                    append(buffer, to: replyID)
                    buffer = ""
                }
                if !(error is CancellationError) {
                    showError(error.localizedDescription, in: replyID)
                }
            }
            finishGeneration(token: token, replyID: replyID, promptChars: finalPrompt.count)
        }
    }

    /// Генерирует ответ на последний вопрос заново.
    func regenerate() {
        guard !isGenerating, container != nil else { return }
        guard let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let prompt = messages[index].text
        messages.removeSubrange(index...)
        sessionDirty = true
        send(prompt)
    }

    /// Останавливает генерацию. Вызывается и при сворачивании приложения:
    /// iOS не разрешает приложению считать на GPU в фоне.
    func stop() {
        if isGenerating { sessionDirty = true }
        generationTask?.cancel()
        generationTask = nil
        currentToken = nil
        isGenerating = false
    }

    private func finishGeneration(token: UUID, replyID: UUID, promptChars: Int) {
        if let index = messages.firstIndex(where: { $0.id == replyID }) {
            let text = messages[index].text
            if text.isEmpty || text.hasPrefix("⏳") {
                messages.remove(at: index)
            } else {
                sessionChars += promptChars + text.count
            }
        }
        if currentToken == token {
            isGenerating = false
            currentToken = nil
        }
        saveCurrent()
    }

    private func append(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }

    private func setText(_ text: String, for id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func showError(_ message: String, in id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let current = messages[index].text
        if current.isEmpty || current.hasPrefix("⏳") {
            messages[index].text = "⚠️ " + message
        } else {
            messages[index].text += "\n\n⚠️ " + message
        }
    }

    // MARK: - Длинные тексты

    private struct PreparedPrompt {
        let prompt: String
        let footnote: String
    }

    /// Длинный текст не отдаётся модели целиком (это быстро забивает память iPhone).
    /// Вместо этого он читается по частям: из каждой части делается короткая выжимка,
    /// а затем модель отвечает по выжимкам. Сама модель при этом не меняется.
    private func prepareLongText(
        _ prompt: String,
        container: ModelContainer,
        replyID: UUID
    ) async throws -> PreparedPrompt {
        let (instruction, body) = Self.splitInstruction(prompt)
        let mode = self.mode

        var text = body
        var footnote = ""
        if text.count > Self.maxLongTextChars {
            text = String(text.prefix(Self.maxLongTextChars))
            footnote = "\n\n_Текст очень длинный: обработаны только первые \(Self.maxLongTextChars) символов._"
        }

        let chunks = Self.splitIntoChunks(text, size: mode.chunkSize)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            guard hasEnoughMemory(minBytes: 300 * Self.mb) else { throw LongTextError.lowMemory }
            setText("⏳ Читаю длинный текст: часть \(index + 1) из \(chunks.count)…", for: replyID)
            notes.append(try await digest(chunk, container: container))
            try await coolDown(mode)
        }

        // Если выжимок получилось слишком много, сжимаем их ещё раз.
        var rounds = 0
        while notes.joined(separator: "\n").count > Self.notesLimit && rounds < 3 {
            let groups = Self.splitIntoChunks(notes.joined(separator: "\n"), size: 3500)
            notes = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                guard hasEnoughMemory(minBytes: 300 * Self.mb) else { throw LongTextError.lowMemory }
                setText("⏳ Сжимаю выжимки: шаг \(rounds + 1), часть \(index + 1) из \(groups.count)…", for: replyID)
                notes.append(try await digest(group, container: container))
                try await coolDown(mode)
            }
            rounds += 1
        }

        let task = instruction ?? "Сделай связный пересказ: главное, ключевые факты и выводы."
        let joined = notes.enumerated()
            .map { "Часть \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n\n")
        let final =
            "\(task)\n\n" +
            "Текст был слишком длинным, поэтому ниже его краткие выжимки по частям. " +
            "Опирайся только на них.\n\n\(joined)"
        return PreparedPrompt(prompt: final, footnote: footnote)
    }

    /// Пауза между частями: телефон успевает остыть, а интерфейс остаётся плавным.
    private func coolDown(_ mode: PerformanceMode) async throws {
        if mode.pauseSeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(mode.pauseSeconds * 1_000_000_000))
        } else {
            await Task.yield()
        }
    }

    /// Короткая выжимка одного фрагмента. Для каждой выжимки создаётся отдельная
    /// временная сессия, чтобы контекст не накапливался.
    private func digest(_ text: String, container: ModelContainer) async throws -> String {
        let temporary = ChatSession(
            container,
            instructions: "Ты точный помощник. Делаешь краткие выжимки текста, ничего не выдумывая.",
            generateParameters: GenerateParameters(maxTokens: 200, temperature: 0.3, topP: 0.9)
        )
        let answer = try await temporary.respond(
            to: "Сделай краткую выжимку фрагмента ниже в 3-5 предложениях на языке фрагмента. " +
                "Сохрани важные факты, имена, числа и выводы.\n\nФрагмент:\n\(text)"
        )
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Если в сообщении есть короткая просьба в начале или в конце («Сделай краткий пересказ»),
    /// отделяем её от самого текста.
    private static func splitInstruction(_ prompt: String) -> (String?, String) {
        let lines = prompt
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, let first = lines.first, let last = lines.last else {
            return (nil, prompt)
        }
        let limit = 250
        if first.count <= limit && last.count > limit {
            return (first, lines.dropFirst().joined(separator: "\n"))
        }
        if last.count <= limit && first.count > limit {
            return (last, lines.dropLast().joined(separator: "\n"))
        }
        return (nil, prompt)
    }

    private static func splitIntoChunks(_ text: String, size: Int) -> [String] {
        var units: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.count <= size {
                units.append(trimmed)
            } else {
                units.append(contentsOf: hardSplit(trimmed, size: size))
            }
        }

        var chunks: [String] = []
        var current = ""
        for unit in units {
            if current.isEmpty {
                current = unit
            } else if current.count + unit.count + 1 <= size {
                current += "\n" + unit
            } else {
                chunks.append(current)
                current = unit
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Режет очень длинный абзац по границам предложений или слов.
    private static func hardSplit(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while rest.count > size {
            let limit = rest.index(rest.startIndex, offsetBy: size)
            var cut = limit
            let head = rest[..<limit]
            if let boundary = head.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" || $0 == " " }),
               rest.distance(from: rest.startIndex, to: boundary) > size / 2 {
                cut = rest.index(after: boundary)
            }
            result.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }

    // MARK: - Контроль памяти

    /// Сколько памяти ещё разрешено использовать приложению. 0 означает, что система
    /// не сообщает лимит (например, в симуляторе), тогда считаем, что памяти хватает.
    private func hasEnoughMemory(minBytes: Int) -> Bool {
        let available = Int(os_proc_available_memory())
        return available == 0 || available > minBytes
    }

    // MARK: - Сохранённые чаты

    var exportText: String {
        messages
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("⏳") }
            .map { ($0.role == .user ? "Я: " : "ИИ: ") + $0.text }
            .joined(separator: "\n\n")
    }

    func saveCurrent() {
        let cleaned = messages.filter { !($0.role == .assistant && ($0.text.isEmpty || $0.text.hasPrefix("⏳"))) }
        guard !cleaned.isEmpty else { return }

        let conversation = Conversation(
            id: currentID,
            title: Self.title(from: cleaned),
            updatedAt: Date(),
            messages: cleaned
        )
        if let index = conversations.firstIndex(where: { $0.id == currentID }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func newChat() {
        stop()
        saveCurrent()
        messages = []
        currentID = UUID()
        if let container {
            session = makeSession(for: container)
            sessionDirty = false
        }
    }

    func openChat(_ id: UUID) {
        stop()
        guard id != currentID, let conversation = conversations.first(where: { $0.id == id }) else { return }
        saveCurrent()
        messages = conversation.messages
        currentID = id
        bottomRequest += 1
        if let container {
            session = makeSession(for: container, transcript: contextTranscript())
            sessionDirty = false
        }
    }

    func deleteChat(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if id == currentID {
            stop()
            messages = []
            currentID = UUID()
            if let container {
                session = makeSession(for: container)
                sessionDirty = false
            }
        }
        persist()
    }

    func deleteAllChats() {
        stop()
        conversations = []
        messages = []
        toggledIDs = []
        currentID = UUID()
        if let container {
            session = makeSession(for: container)
            sessionDirty = false
        }
        persist()
    }

    private static func title(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user })?.text else { return "Новый чат" }
        let line = first
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? first
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conversations) else { return }
        let url = storeURL
        Self.writeQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeStoreURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("conversations.json")
    }

    private static func readConversations(from url: URL) -> [Conversation] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Conversation].self, from: data)) ?? []
    }
}
