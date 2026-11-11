import SwiftUI
import UIKit

// MARK: - Служебное для прокрутки

private struct ScrollCommand: Equatable {
    let messageID: UUID?        // nil — прокрутить в самый низ
    let anchor: UnitPoint
    let animated: Bool
    let token = UUID()
}

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Главный экран

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @StateObject private var network = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("followAnswer") private var followAnswer = false

    @State private var input = ""
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var command: ScrollCommand?
    @State private var isNearBottom = true
    @State private var viewportHeight: CGFloat = 0
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Объясни простыми словами, как работает интернет",
        "Придумай пять идей, чем заняться на выходных",
        "Помоги написать вежливое письмо с отказом",
        "Расскажи интересный факт про космос"
    ]

    var body: some View {
        NavigationStack {
            Group {
                if vm.loadState == .ready {
                    chatView
                } else {
                    setupView
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    statusHeader
                }
                if vm.loadState == .ready {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            inputFocused = false
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            vm.newChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        Menu {
                            Picker("Нагрузка", selection: $vm.performanceMode) {
                                ForEach(PerformanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            ShareLink(item: vm.exportText) {
                                Label("Поделиться чатом", systemImage: "square.and.arrow.up")
                            }
                            .disabled(vm.messages.isEmpty)
                            Button("Настройки", systemImage: "gearshape") {
                                inputFocused = false
                                showSettings = true
                            }
                            Button("Сменить модель", systemImage: "cpu") {
                                vm.unloadModel()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(vm: vm)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
        .onChange(of: scenePhase) { _, phase in
            // В фоне GPU недоступен, поэтому генерацию останавливаем и сохраняем чат.
            if phase != .active {
                vm.stop()
                vm.saveCurrent()
            }
        }
        .onAppear { vm.autoLoadIfPossible() }
    }

    // MARK: - Заголовок со статусом

    private var statusInfo: (text: String, color: Color) {
        switch vm.loadState {
        case .ready:
            if vm.thermalHot { return (text: "Телефон греется", color: Color.red) }
            if vm.isGenerating { return (text: "Думает…", color: Color.orange) }
            return (text: "Модель готова", color: Color.green)
        case .starting:
            return (text: "Запуск модели…", color: Color.orange)
        case .downloading(let progress):
            return (text: "Загрузка \(Int(progress * 100))%", color: Color.orange)
        case .idle:
            return (text: "Модель не загружена", color: Color.gray)
        case .failed:
            return (text: "Ошибка модели", color: Color.red)
        }
    }

    private var statusHeader: some View {
        let status = statusInfo
        return VStack(spacing: 1) {
            Text("Локальный чат")
                .font(.headline)
            HStack(spacing: 5) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                Text(status.text + (network.isOnline ? " · онлайн" : " · офлайн"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Экран чата

    private var chatView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        if vm.messages.isEmpty {
                            emptyState
                        }
                        ForEach(vm.messages) { message in
                            let isLast = message.id == vm.messages.last?.id
                            MessageRow(
                                message: message,
                                isStreaming: vm.isGenerating && isLast,
                                canRegenerate: !vm.isGenerating && isLast && message.role == .assistant,
                                onRegenerate: { vm.regenerate() }
                            )
                            .equatable()
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomOffsetKey.self,
                                        value: geo.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(name: "chatScroll")
                .scrollDismissesKeyboard(.interactively)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { viewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, height in
                                viewportHeight = height
                            }
                    }
                )
                .onPreferenceChange(BottomOffsetKey.self) { bottomY in
                    let near = bottomY <= viewportHeight + 120
                    if near != isNearBottom { isNearBottom = near }
                }
                .overlay(alignment: .bottom) {
                    scrollDownButton
                }
                .onChange(of: command) { _, newCommand in
                    guard let newCommand else { return }
                    DispatchQueue.main.async {
                        run(newCommand, proxy: proxy)
                    }
                }
                .onChange(of: vm.currentID) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: vm.messages.last?.text.count) { _, _ in
                    // По умолчанию экран стоит на месте, пока ИИ пишет.
                    // Если включена автопрокрутка, следуем за ответом.
                    guard followAnswer, vm.isGenerating, isNearBottom else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            inputBar
        }
    }

    private func run(_ command: ScrollCommand, proxy: ScrollViewProxy) {
        func perform() {
            if let id = command.messageID {
                proxy.scrollTo(id, anchor: command.anchor)
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        if command.animated {
            withAnimation(.easeOut(duration: 0.25)) { perform() }
        } else {
            perform()
        }
    }

    private var showScrollDown: Bool {
        !isNearBottom && !vm.messages.isEmpty
    }

    private var scrollDownButton: some View {
        ZStack {
            if showScrollDown {
                Button {
                    command = ScrollCommand(messageID: nil, anchor: .bottom, animated: true)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color(white: 0.22)))
                        .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showScrollDown)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Чем помочь?")
                .font(.title2.bold())
            Text("Всё работает на вашем iPhone, без интернета.\nДлинные тексты читаются по частям, чтобы не вылетало.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        submit(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(white: 0.13))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 40)
        .padding(.horizontal, 6)
    }

    // MARK: - Ввод

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !vm.isGenerating else { return }

        let before = vm.messages.count
        vm.send(prompt)
        input = ""
        inputFocused = false

        // Как в ChatGPT: наш вопрос встаёт наверх экрана, ответ растёт под ним,
        // и экран не улетает вниз.
        if vm.messages.count >= before + 2 {
            let question = vm.messages[vm.messages.count - 2]
            command = ScrollCommand(messageID: question.id, anchor: .top, animated: true)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if input.count > 3000 {
                Text("Длинный текст: приложение прочитает его по частям, это займёт больше времени.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Сообщение", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.leading, 16)
                    .padding(.vertical, 10)

                Button {
                    if vm.isGenerating {
                        vm.stop()
                    } else {
                        submit(input)
                    }
                } label: {
                    Image(systemName: vm.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(Color.white.opacity(vm.isGenerating || canSend ? 1 : 0.3))
                        )
                }
                .disabled(!vm.isGenerating && !canSend)
                .padding(.trailing, 6)
                .padding(.bottom, 5)
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(white: 0.16))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    // MARK: - Экран выбора и загрузки модели

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                    .padding(.top, 24)

                Text("ИИ прямо на вашем iPhone")
                    .font(.title2.bold())

                Text("Модель скачается один раз (лучше по Wi‑Fi). После этого чат работает без интернета.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    ForEach(ChatViewModel.models) { model in
                        modelRow(model)
                    }
                }

                setupStatus
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func modelRow(_ model: ModelOption) -> some View {
        let selected = vm.selectedModelID == model.id
        return Button {
            vm.selectedModelID = model.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.headline)
                    Text(model.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Color.orange : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var isBusy: Bool {
        switch vm.loadState {
        case .starting, .downloading: return true
        default: return false
        }
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch vm.loadState {
        case .starting:
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.orange)
                Text("Запускаю модель…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .tint(.orange)
                Text(progress >= 0.999
                     ? "Запускаю модель…"
                     : "Скачиваю: \(Int(progress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Не сворачивайте приложение, пока идёт загрузка.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                startButton
            }
        default:
            startButton
        }
    }

    private var startButton: some View {
        Button {
            vm.loadModel()
        } label: {
            Text("Скачать и запустить")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundColor(.black)
        }
        .padding(.top, 6)
    }
}

// MARK: - Сообщение

private struct MessageRow: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    let canRegenerate: Bool
    let onRegenerate: () -> Void

    @AppStorage("textScale") private var textScale = 1.0
    @State private var expanded: Bool
    @State private var copied = false

    init(message: ChatMessage, isStreaming: Bool, canRegenerate: Bool, onRegenerate: @escaping () -> Void) {
        self.message = message
        self.isStreaming = isStreaming
        self.canRegenerate = canRegenerate
        self.onRegenerate = onRegenerate
        // Ответ, который пишется на наших глазах, не сворачиваем, чтобы он не «схлопнулся»
        // в конце. Всё остальное длинное по умолчанию свёрнуто.
        _expanded = State(initialValue: isStreaming)
    }

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isStreaming == rhs.isStreaming
            && lhs.canRegenerate == rhs.canRegenerate
    }

    private var isUser: Bool { message.role == .user }
    private var isStatusText: Bool { message.text.hasPrefix("⏳") }

    private var isCollapsible: Bool {
        if isStreaming || isStatusText { return false }
        return message.text.count > (isUser ? 500 : 1800)
    }

    private var collapsed: Bool { isCollapsible && !expanded }

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: message.text, options: options))
            ?? AttributedString(message.text)
    }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    messageText
                    if isCollapsible { toggleButton }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(white: 0.2))
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if message.text.isEmpty && isStreaming {
                    ProgressView()
                        .tint(.secondary)
                        .padding(.vertical, 4)
                } else {
                    messageText
                    if isCollapsible { toggleButton }
                }
                if !isStreaming && !message.text.isEmpty && !isStatusText {
                    actions
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var messageText: some View {
        Text(rendered)
            .font(.system(size: 16 * textScale))
            .foregroundColor(.white)
            .lineLimit(collapsed ? (isUser ? 6 : 12) : nil)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
    }

    private var toggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "Свернуть" : "Показать полностью")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.orange)
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: 20) {
            Button {
                UIPasteboard.general.string = message.text
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            if canRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
    }
}

// MARK: - История чатов

private struct HistoryView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [Conversation] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return vm.conversations }
        return vm.conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(text)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(text) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.conversations.isEmpty {
                    placeholder("Сохранённых чатов пока нет")
                } else if filtered.isEmpty {
                    placeholder("Ничего не найдено")
                } else {
                    List {
                        ForEach(filtered) { conversation in
                            Button {
                                vm.openChat(conversation.id)
                                dismiss()
                            } label: {
                                row(conversation)
                            }
                        }
                        .onDelete { offsets in
                            let list = filtered
                            let ids = offsets.map { list[$0].id }
                            for id in ids { vm.deleteChat(id) }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Поиск по чатам")
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Новый чат") {
                        vm.newChat()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.white)
                Text("\(conversation.messages.count) сообщ. · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if conversation.id == vm.currentID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Настройки

private struct SettingsView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("followAnswer") private var followAnswer = false
    @State private var confirmDelete = false

    private var modelTitle: String {
        ChatViewModel.models.first { $0.id == vm.selectedModelID }?.title ?? vm.selectedModelID
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Нагрузка", selection: $vm.performanceMode) {
                        ForEach(PerformanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(vm.performanceMode.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Щадить при экономии энергии", isOn: $vm.autoEco)

                    if vm.thermalHot {
                        Label("Телефон сильно нагрет, приложение работает медленнее, пока он не остынет.",
                              systemImage: "thermometer.high")
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Нагрузка на телефон")
                } footer: {
                    Text("Режим «Плавно» не делает модель глупее: ответы просто выводятся спокойнее, а длинные тексты читаются небольшими частями с паузами, чтобы ничего не лагало.")
                }

                Section {
                    Picker("Стиль ответов", selection: $vm.answerStyle) {
                        ForEach(AnswerStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Свои инструкции (например: отвечай как учитель)",
                              text: $vm.customInstructions, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Ответы")
                } footer: {
                    Text("Инструкции учитываются в каждом новом чате и после смены настроек.")
                }

                Section {
                    Picker("Размер текста", selection: $textScale) {
                        Text("Мелкий").tag(0.9)
                        Text("Обычный").tag(1.0)
                        Text("Крупный").tag(1.15)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Прокручивать за ответом", isOn: $followAnswer)
                } header: {
                    Text("Вид")
                } footer: {
                    Text("По умолчанию экран стоит на месте, пока ИИ пишет. Кнопка со стрелкой вниз возвращает к концу чата.")
                }

                Section("Модель") {
                    HStack {
                        Text("Сейчас")
                        Spacer()
                        Text(modelTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Сменить модель") {
                        vm.unloadModel()
                        dismiss()
                    }
                }

                Section {
                    Button("Удалить все чаты", role: .destructive) {
                        confirmDelete = true
                    }
                } footer: {
                    Text("Чаты хранятся только на этом телефоне и никуда не отправляются.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Удалить все чаты?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    vm.deleteAllChats()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Это действие нельзя отменить.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
