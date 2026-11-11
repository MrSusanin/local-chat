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

    // MARK: Состояние

    @Published var messages: [ChatMessage] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentID = UUID()
    @Published var loadState: LoadState
    @Published var selectedModelID: String
    @Published private(set) var thermalHot = false
    @Published private(set) var isGenerating = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = isGenerating }
    }

    // MARK: Настройки (сохраняются на телефоне)

    @Published var performanceMode: PerformanceMode {
        didSet {
            UserDefaults.standard.set(performanceMode.rawValue, forKey: "performanceMode")
            sessionDirty = true
        }
    }
    @Published var autoEco: Bool {
        didSet {
            UserDefaults.standard.set(autoEco, forKey: "autoEco")
            sessionDirty = true
        }
    }
    @Published var answerStyle: AnswerStyle {
        didSet {
            UserDefaults.standard.set(answerStyle.rawValue, forKey: "answerStyle")
            sessionDirty = true
        }
    }
    @Published var customInstructions: String {
        didSet {
            UserDefaults.standard.set(customInstructions, forKey: "customInstructions")
            sessionDirty = true
        }
    }

    /// С включённым энергосбережением iOS автоматически работаем в щадящем режиме.
    private var effectiveMode: PerformanceMode {
        if autoEco && ProcessInfo.processInfo.isLowPowerModeEnabled { return .smooth }
        return performanceMode
    }

    private var systemPrompt: String {
        var prompt = "Ты дружелюбный и полезный ассистент. Отвечай на том языке, на котором пишет пользователь. "
        prompt += answerStyle.instruction
        prompt += " Если не знаешь ответа, так и скажи."
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            prompt += "\n\nДополнительные инструкции пользователя: " + custom
        }
        return prompt
    }

    private var container: ModelContainer?
    private var session: ChatSession?
    private var sessionChars = 0
    private var sessionDirty = false
    private var isLoadingModel = false
    private var generationTask: Task<Void, Never>?
    private var currentToken: UUID?
    private var thermalObserver: NSObjectProtocol?
    private let storeURL: URL

    init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "selectedModel") ?? Self.models[0].id
        selectedModelID = id
        // Если модель уже скачана, сразу показываем «запуск», а не экран выбора.
        loadState = defaults.bool(forKey: "downloaded.\(id)") ? .starting : .idle
        storeURL = Self.makeStoreURL()

        performanceMode = PerformanceMode(rawValue: defaults.string(forKey: "performanceMode") ?? "") ?? .balanced
        autoEco = defaults.object(forKey: "autoEco") as? Bool ?? true
        answerStyle = AnswerStyle(rawValue: defaults.string(forKey: "answerStyle") ?? "") ?? .normal
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""

        conversations = Self.readConversations(from: storeURL)
        if let last = conversations.first {
            currentID = last.id
            messages = last.messages
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateThermal() }
        }
        updateThermal()
    }

    private func updateThermal() {
        thermalHot = ProcessInfo.processInfo.thermalState.rawValue
            >= ProcessInfo.ThermalState.serious.rawValue
    }

    // MARK: - Модель

    func autoLoadIfPossible() {
        if case .starting = loadState { loadModel() }
    }

    func loadModel() {
        guard !isLoadingModel else { return }
        isLoadingModel = true

        let id = selectedModelID
        let defaults = UserDefaults.standard
        defaults.set(id, forKey: "selectedModel")
        loadState = defaults.bool(forKey: "downloaded.\(id)") ? .starting : .downloading(0)

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
                session = makeSession(for: loaded, transcript: contextTranscript())
                sessionDirty = false
                defaults.set(true, forKey: "downloaded.\(id)")
                loadState = .ready
            } catch {
                loadState = .failed(
                    "Не удалось загрузить модель: \(error.localizedDescription)\n" +
                    "Проверьте интернет и свободное место, затем попробуйте ещё раз."
                )
            }
            isLoadingModel = false
        }
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
            generateParameters: GenerateParameters(
                maxTokens: effectiveMode.maxTokens,
                temperature: 0.6,
                topP: 0.9
            )
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

        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(reply)

        let replyID = reply.id
        let token = UUID()
        currentToken = token
        isGenerating = true

        let mode = effectiveMode
        let flushInterval = mode.uiFlushInterval * (thermalHot ? 2 : 1)
        let isLong = prompt.count > Self.longTextThreshold

        generationTask = Task {
            var finalPrompt = prompt
            var footnote = ""
            do {
                if isLong {
                    let prepared = try await prepareLongText(
                        prompt, container: container, replyID: replyID, mode: mode
                    )
                    finalPrompt = prepared.prompt
                    footnote = prepared.footnote
                    setText("", for: replyID)
                }

                // Текст на экране обновляется пачками, а не на каждое слово:
                // так интерфейс не лагает, особенно в режиме «Плавно».
                var buffer = ""
                var lastFlush = Date.distantPast
                var produced = 0
                var lowMemory = false

                for try await chunk in session.streamResponse(to: finalPrompt) {
                    if Task.isCancelled { break }
                    buffer += chunk
                    produced += 1

                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= flushInterval {
                        append(buffer, to: replyID)
                        buffer = ""
                        lastFlush = now
                    }
                    if produced % 24 == 0, !hasEnoughMemory(minBytes: 120 * Self.mb) {
                        lowMemory = true
                        break
                    }
                }
                if !buffer.isEmpty { append(buffer, to: replyID) }
                if lowMemory {
                    append("\n\n⚠️ Не хватает памяти, ответ остановлен.", to: replyID)
                }
                if !footnote.isEmpty && !Task.isCancelled {
                    append(footnote, to: replyID)
                }
            } catch {
                if !(error is CancellationError) {
                    setText("⚠️ \(error.localizedDescription)", for: replyID)
                }
            }
            finishGeneration(token: token, replyID: replyID, promptChars: finalPrompt.count)
        }
    }

    /// Повторить последний ответ: убираем его и отправляем последний вопрос заново.
    func regenerate() {
        guard !isGenerating,
              let index = messages.lastIndex(where: { $0.role == .user }) else { return }
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        replyID: UUID,
        mode: PerformanceMode
    ) async throws -> PreparedPrompt {
        let (instruction, body) = Self.splitInstruction(prompt)

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
            try await coolDownIfNeeded(replyID: replyID)
            setText("⏳ Читаю длинный текст: часть \(index + 1) из \(chunks.count)…", for: replyID)
            notes.append(try await digest(chunk, container: container, mode: mode))
            if mode.cooldown > 0 {
                try await Task.sleep(nanoseconds: UInt64(mode.cooldown * 1_000_000_000))
            }
        }

        // Если выжимок получилось слишком много, сжимаем их ещё раз.
        var rounds = 0
        while notes.joined(separator: "\n").count > Self.notesLimit && rounds < 3 {
            let groups = Self.splitIntoChunks(notes.joined(separator: "\n"), size: 3500)
            notes = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                guard hasEnoughMemory(minBytes: 300 * Self.mb) else { throw LongTextError.lowMemory }
                try await coolDownIfNeeded(replyID: replyID)
                setText("⏳ Сжимаю выжимки: шаг \(rounds + 1), часть \(index + 1) из \(groups.count)…", for: replyID)
                notes.append(try await digest(group, container: container, mode: mode))
                if mode.cooldown > 0 {
                    try await Task.sleep(nanoseconds: UInt64(mode.cooldown * 1_000_000_000))
                }
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

    /// Если телефон сильно нагрелся, делаем паузу, чтобы он остыл (до минуты).
    private func coolDownIfNeeded(replyID: UUID) async throws {
        var waited = 0
        while thermalHot && waited < 12 {
            try Task.checkCancellation()
            setText("⏳ Телефон нагрелся, даю ему немного остыть…", for: replyID)
            try await Task.sleep(nanoseconds: 5_000_000_000)
            waited += 1
        }
    }

    /// Короткая выжимка одного фрагмента. Для каждой выжимки создаётся отдельная
    /// временная сессия, чтобы контекст не накапливался.
    private func digest(_ text: String, container: ModelContainer, mode: PerformanceMode) async throws -> String {
        let temporary = ChatSession(
            container,
            instructions: "Ты точный помощник. Делаешь краткие выжимки текста, ничего не выдумывая.",
            generateParameters: GenerateParameters(maxTokens: mode.digestTokens, temperature: 0.3, topP: 0.9)
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
