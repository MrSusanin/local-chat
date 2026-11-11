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
    var attachments: [ChatAttachment] = []

    init(role: Role, text: String, attachments: [ChatAttachment] = []) {
        self.init(id: UUID(), role: role, text: text, attachments: attachments)
    }

    init(id: UUID, role: Role, text: String, attachments: [ChatAttachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        // Старые чаты (до появления вложений) продолжают читаться.
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var updatedAt: Date
    var messages: [ChatMessage]
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

    // MARK: Провайдер и модели

    /// Активный ИИ: локальная модель или облако (OpenAI, Gemini, Groq).
    @Published var provider: AIProvider {
        didSet {
            guard oldValue != provider else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
            queuedPrompt = nil
            // Контекст диалога пересоберётся под нового ИИ.
            sessionDirty = true
        }
    }

    /// Выбранная модель для каждого провайдера (запоминается отдельно).
    @Published private(set) var selectedModelByProvider: [AIProvider: String] = [:]

    /// API ключи провайдеров — в связке ключей, не в настройках приложения.
    @Published private(set) var apiKeyByProvider: [AIProvider: String] = [:]

    /// Пользователь явно открыл экран выбора ИИ и модели.
    @Published var showsModelSetup = false

    /// Имя активной модели (для локальной — репозиторий на Hugging Face).
    var modelName: String {
        selectedModelByProvider[provider] ?? provider.defaultModelName
    }

    var hasAPIKey: Bool {
        !(apiKeyByProvider[provider] ?? "").isEmpty
    }

    /// Возможности активной модели: по ним появляются кнопки «фото», «аудио» и т.д.
    var capabilities: Set<ModelCapability> {
        provider.models.first { $0.name == modelName }?.capabilities ?? [.text]
    }

    func supports(_ capability: ModelCapability) -> Bool {
        capabilities.contains(capability)
    }

    var modelDisplayName: String {
        provider.models.first { $0.name == modelName }?.title ?? modelName
    }

    /// Выбранная локальная модель (нужна экрану загрузки).
    var selectedLocalModel: AIModelOption? {
        AIProvider.local.models.first { $0.name == selectedModelByProvider[.local] }
    }

    /// Можно ли закрыть экран выбора ИИ и вернуться в чат.
    var canCloseModelSetup: Bool {
        if provider != .local { return true }
        if case .ready = loadState { return true }
        return false
    }

    func selectModel(_ name: String, for provider: AIProvider) {
        selectedModelByProvider[provider] = name
        UserDefaults.standard.set(name, forKey: "selectedModel.\(provider.rawValue)")
        sessionDirty = true
    }

    func apiKey(for provider: AIProvider) -> String {
        apiKeyByProvider[provider] ?? ""
    }

    /// Пустой ключ удаляется из связки ключей.
    func updateAPIKey(_ key: String, for provider: AIProvider) {
        apiKeyByProvider[provider] = key
        try? KeychainStore.write(key, account: "apikey.\(provider.rawValue)")
    }

    // MARK: Состояние

    @Published var messages: [ChatMessage] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var currentID = UUID()
    @Published var loadState: LoadState
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

    /// Сообщение, написанное, пока локальная модель ещё запускалась.
    @Published private(set) var queuedPrompt: String?

    private var loadAttempt: UUID?
    private var container: ModelContainer?
    private var session: ChatSession?
    private var sessionChars = 0
    private var sessionDirty = false
    private var isLoadingModel = false
    private var loadedModelID: String?
    private var generationTask: Task<Void, Never>?
    private var currentToken: UUID?

    // Пороговые значения (в символах). Подобраны для iPhone с 4 ГБ памяти.
    private static let longTextThreshold = 3000      // выше этого текст обрабатывается по частям
    private static let maxLongTextChars = 60_000     // больше не читаем
    private static let notesLimit = 6000             // максимум выжимок, которые отдаём в финальный запрос
    private static let sessionResetChars = 6000      // после этого объёма диалога контекст пересобирается
    private static let mb = 1_048_576

    private let baseSystemPrompt =
        "Ты дружелюбный и полезный ассистент. Отвечай на том языке, на котором пишет пользователь. " +
        "Отвечай кратко и по делу. Если не знаешь ответа, так и скажи."

    init() {
        let defaults = UserDefaults.standard

        // Провайдер (по умолчанию — локальная модель).
        let providerRaw = defaults.string(forKey: "selectedProvider") ?? AIProvider.local.rawValue
        provider = AIProvider(rawValue: providerRaw) ?? .local

        // Выбранные модели и ключи.
        var models: [AIProvider: String] = [:]
        var keys: [AIProvider: String] = [:]
        for item in AIProvider.allCases {
            models[item] = defaults.string(forKey: "selectedModel.\(item.rawValue)") ?? item.defaultModelName
            keys[item] = (try? KeychainStore.read(account: "apikey.\(item.rawValue)")) ?? ""
        }
        // Переносим имя локальной модели из прежнего ключа.
        if models[.local] == AIProvider.local.defaultModelName,
           let legacy = defaults.string(forKey: "selectedModel"),
           AIProvider.local.models.contains(where: { $0.name == legacy }) {
            models[.local] = legacy
            defaults.set(legacy, forKey: "selectedModel.\(AIProvider.local.rawValue)")
        }
        selectedModelByProvider = models
        apiKeyByProvider = keys

        // Локальная модель: если она уже скачана, сразу показываем «запуск».
        let localID = models[.local] ?? AIProvider.local.defaultModelName
        loadState = (provider == .local && defaults.bool(forKey: "downloaded.\(localID)")) ? .starting : .idle

        mode = PerformanceMode(rawValue: defaults.string(forKey: "perfMode") ?? "") ?? .balanced
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""

        // Чаты: Core Data + одноразовый перенос из старого JSON-хранилища.
        CoreDataStack.shared.migrateLegacyStoreIfNeeded()
        conversations = CoreDataStack.shared.fetchConversations()
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

    // MARK: - Локальная модель

    func autoLoadIfPossible() {
        guard provider == .local, case .starting = loadState else { return }
        loadModel()
    }

    /// Открывает экран выбора ИИ (модель, провайдер, API ключ).
    func openModelSetup() {
        stop()
        saveCurrent()
        showsModelSetup = true
    }

    /// Закрывает экран выбора ИИ и возвращает в чат.
    func closeModelSetup() {
        showsModelSetup = false
    }

    func loadModel() {
        guard provider == .local, !isLoadingModel else { return }
        let id = modelName     // репозиторий Hugging Face
        if case .ready = loadState, let loadedModelID, loadedModelID == id {
            // Эта модель уже в памяти — просто возвращаемся в чат.
            showsModelSetup = false
            return
        }

        isLoadingModel = true
        let attempt = UUID()
        loadAttempt = attempt
        showsModelSetup = false
        selectedModelByProvider[.local] = id
        UserDefaults.standard.set(id, forKey: "selectedModel.\(AIProvider.local.rawValue)")

        // Выгружаем прежнюю модель, чтобы не держать в памяти две сразу.
        if let loadedModelID, loadedModelID != id {
            session = nil
            container = nil
            sessionDirty = true
        }

        let defaults = UserDefaults.standard
        let wasDownloaded = defaults.bool(forKey: "downloaded.\(id)")
        loadState = wasDownloaded ? .starting : .downloading(0)
        // Если модель уже скачана, читаем её прямо из папки на телефоне
        // и не обращаемся к Hugging Face при каждом запуске.
        let localURL = wasDownloaded ? Self.localModelURL(for: id) else nil

        Task {
            do {
                let loaded = try await openContainer(id: id, localURL: localURL)
                guard loadAttempt == attempt else { return }   // модель успели сменить
                container = loaded
                session = makeSession(for: loaded, transcript: contextTranscript())
                sessionDirty = false
                loadedModelID = id
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
        loadedModelID = nil
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

    // MARK: - Сообщение, отправленное во время запуска модели

    /// Пока локальная модель запускается, сообщение можно написать: оно уйдёт само, когда всё будет готово.
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

    /// Отправляет сообщение активному ИИ. Вместе с текстом можно передать вложения
    /// (фото, аудио, документ) — их поймут только облачные модели, которые их поддерживают.
    func send(_ text: String, attachments: [PendingAttachment] = []) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        guard !isGenerating else { return }

        switch provider {
        case .local:
            sendLocal(prompt)
        default:
            sendRemote(prompt, attachments: attachments)
        }
    }

    /// Генерирует ответ на последний вопрос заново.
    func regenerate() {
        guard !isGenerating, let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let prompt = messages[index].text
        let attachments = messages[index].attachments
        messages.removeSubrange(index...)
        sessionDirty = true

        // Вложения из прошлого вопроса переиспользуем (файлы уже на диске).
        let pending = attachments.compactMap { attachment -> PendingAttachment? in
            guard let data = AttachmentStore.data(forStoredName: attachment.storedName),
                  !data.isEmpty,
                  data.count <= PendingAttachment.maxSize else { return nil }
            return PendingAttachment(
                kind: attachment.kind,
                fileName: attachment.fileName,
                mimeType: Self.mimeType(for: attachment),
                data: data,
                existingStoredName: attachment.storedName
            )
        }
        send(prompt, attachments: pending)
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

    // MARK: Локальная генерация (MLX)

    private func sendLocal(_ prompt: String) {
        guard let container else {
            queue(prompt)
            return
        }

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

    // MARK: Облачная генерация (OpenAI, Gemini, Groq)

    private func sendRemote(_ prompt: String, attachments: [PendingAttachment]) {
        guard let client = AIProviderClientFactory.client(provider: provider, modelName: modelName) else { return }

        let key = apiKey(for: provider)
        guard !key.isEmpty else {
            messages.append(ChatMessage(role: .user, text: prompt))
            messages.append(ChatMessage(
                role: .assistant,
                text: "⚠️ Для \(provider.title) нужен API ключ. Откройте «Сменить ИИ / модель» и введите ключ."
            ))
            saveCurrent()
            return
        }

        // Сохраняем вложения в файлы и собираем данные для запроса.
        var stored: [ChatAttachment] = []
        var payloads: [AttachmentPayload] = []
        for pending in attachments {
            let storedName: String?
            if let existing = pending.existingStoredName,
               FileManager.default.fileExists(atPath: AttachmentStore.url(forStoredName: existing).path) {
                storedName = existing
            } else {
                storedName = AttachmentStore.save(data: pending.data, fileName: pending.fileName)
            }
            guard let storedName else { continue }
            stored.append(ChatAttachment(fileName: pending.fileName, storedName: storedName, kind: pending.kind))
            payloads.append(AttachmentPayload(
                kind: pending.kind.capability,
                mimeType: pending.mimeType,
                fileName: pending.fileName,
                data: pending.data
            ))
        }

        let history = remoteHistory()

        let userMessage = ChatMessage(role: .user, text: prompt, attachments: stored)
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(userMessage)
        messages.append(reply)
        scrollRequest = userMessage.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let replyID = reply.id
        let token = UUID()
        currentToken = token
        isGenerating = true
        let interval = mode.uiInterval

        let request = ProviderRequest(
            systemPrompt: systemPrompt,
            history: history,
            userMessage: ProviderMessage(role: .user, text: prompt, attachments: payloads),
            maxTokens: mode.maxTokens
        )

        generationTask = Task {
            var buffer = ""
            var lastFlush = Date()
            var received = false
            do {
                for try await chunk in client.stream(request, apiKey: key) {
                    if Task.isCancelled { break }
                    received = true
                    buffer += chunk
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= interval {
                        append(buffer, to: replyID)
                        buffer = ""
                        lastFlush = now
                    }
                }
                if !buffer.isEmpty {
                    append(buffer, to: replyID)
                    buffer = ""
                }
                if !received && !Task.isCancelled {
                    showError("Пустой ответ от \(provider.title). Попробуйте ещё раз.", in: replyID)
                }
            } catch {
                if !buffer.isEmpty {
                    append(buffer, to: replyID)
                    buffer = ""
                }
                if !Self.isCancellation(error) {
                    showError(Self.describe(error), in: replyID)
                }
            }
            finishGeneration(token: token, replyID: replyID, promptChars: prompt.count)
        }
    }

    /// Последние сообщения для облачного запроса. Вложения отдаём только из самых
    /// свежих сообщений, чтобы запрос не разросся до мегабайтов.
    private func remoteHistory() -> [ProviderMessage] {
        let recent = messages
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("⏳") }
            .suffix(10)
        var result: [ProviderMessage] = []
        for (offset, message) in recent.enumerated() {
            let includeAttachments = offset >= recent.count - 4
            let payloads: [AttachmentPayload] = includeAttachments
                ? message.attachments.compactMap(Self.payload(for:))
                : []
            let text = message.text.isEmpty && !payloads.isEmpty ? "Опиши вложение." : message.text
            guard !text.isEmpty else { continue }
            result.append(ProviderMessage(role: message.role, text: text, attachments: payloads))
        }
        return result
    }

    private static func payload(for attachment: ChatAttachment) -> AttachmentPayload? {
        guard let data = AttachmentStore.data(forStoredName: attachment.storedName),
              !data.isEmpty,
              data.count <= PendingAttachment.maxSize else { return nil }
        return AttachmentPayload(
            kind: attachment.kind.capability,
            mimeType: mimeType(for: attachment),
            fileName: attachment.fileName,
            data: data
        )
    }

    private static func mimeType(for attachment: ChatAttachment) -> String {
        let ext = (attachment.storedName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "mp3", "mpeg": return "audio/mpeg"
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    /// Адрес файла вложения для просмотра.
    func attachmentURL(messageID: UUID, attachment: ChatAttachment) -> URL? {
        guard messages.contains(where: { $0.id == messageID }) else { return nil }
        let url = AttachmentStore.url(forStoredName: attachment.storedName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        return false
    }

    private static func describe(_ error: Error) -> String {
        if let providerError = error as? AIProviderError {
            return providerError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "Нет соединения с интернетом. Проверьте сеть и попробуйте ещё раз."
            default:
                return "Ошибка сети: \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    // MARK: Завершение генерации

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

    // MARK: - Длинные тексты (локальная модель)

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

    // MARK: - Сохранённые чаты (Core Data)

    var exportText: String {
        messages
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("⏳") }
            .map { message -> String in
                var line = (message.role == .user ? "Я: " : "ИИ: ") + message.text
                for attachment in message.attachments {
                    line += "\n[\(attachment.kind.capability.title): \(attachment.fileName)]"
                }
                return line
            }
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
        CoreDataStack.shared.saveConversation(conversation)
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
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        // Удаляем и файлы вложений этого чата.
        for message in conversation.messages {
            for attachment in message.attachments {
                AttachmentStore.remove(storedName: attachment.storedName)
            }
        }
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
        CoreDataStack.shared.deleteConversation(id: id)
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
        AttachmentStore.removeAll()
        CoreDataStack.shared.deleteAllConversations()
    }

    private static func title(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "Новый чат" }
        var source = first.text
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let attachment = first.attachments.first {
            source = attachment.fileName
        }
        let line = source
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? source
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }
}
