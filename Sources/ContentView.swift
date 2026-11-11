import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @StateObject private var network = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @State private var input = ""
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var atBottom = true
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Объясни простыми словами, как работает интернет",
        "Придумай 5 идей для подарка другу",
        "Помоги составить вежливый отказ от встречи",
        "Сделай краткий пересказ: "
    ]

    var body: some View {
        NavigationStack {
            Group {
                if showsChat {
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
                if showsChat {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            inputFocused = false
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if showsChat {
                        Menu {
                            Button("Новый чат", systemImage: "square.and.pencil") {
                                vm.newChat()
                            }
                            ShareLink(item: vm.exportText) {
                                Label("Поделиться чатом", systemImage: "square.and.arrow.up")
                            }
                            .disabled(vm.messages.isEmpty)
                            Button("Настройки", systemImage: "slider.horizontal.3") {
                                inputFocused = false
                                showSettings = true
                            }
                            Button("Сменить модель", systemImage: "cpu") {
                                vm.unloadModel()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    } else {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            }
        }
        .tint(.orange)
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

    /// Чат показываем сразу, даже пока модель запускается: можно читать историю и писать сообщение.
    private var showsChat: Bool {
        vm.loadState == .ready || vm.loadState == .starting
    }

    // MARK: - Заголовок со статусом

    private var statusInfo: (text: String, color: Color) {
        switch vm.loadState {
        case .ready:
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
            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            if vm.messages.isEmpty {
                                emptyHint
                            }
                            ForEach(vm.messages) { message in
                                messageRow(for: message)
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
                        .padding(.bottom, 24)
                    }
                    .coordinateSpace(name: "chatScroll")
                    .scrollDismissesKeyboard(.interactively)
                    .onPreferenceChange(BottomOffsetKey.self) { value in
                        let nearBottom = value <= outer.size.height + 80
                        if nearBottom != atBottom {
                            atBottom = nearBottom
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !atBottom {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(Color(white: 0.22)))
                                    .overlay(Circle().stroke(Color(white: 0.35), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                            }
                            .padding(.bottom, 12)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: atBottom)
                    .onChange(of: vm.scrollRequest) { _, id in
                        guard let id else { return }
                        // Показываем начало нового вопроса вверху экрана, а не конец ответа.
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: vm.bottomRequest) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            inputBar
        }
    }

    @ViewBuilder
    private func messageRow(for message: ChatMessage) -> some View {
        let isLast = message.id == vm.messages.last?.id
        let streaming = vm.isGenerating && isLast
        MessageRow(
            message: message,
            isStreaming: streaming,
            isLast: isLast,
            isLong: vm.isLong(message),
            isCollapsed: vm.isCollapsed(message, streaming: streaming),
            onToggle: { vm.toggleCollapse(message.id) },
            onRegenerate: { vm.regenerate() }
        )
        .equatable()
    }

    private var emptyHint: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Чем могу помочь?")
                    .font(.title2.weight(.semibold))
                Text("Всё работает на вашем iPhone, без интернета.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        input = suggestion
                        inputFocused = true
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color(white: 0.28), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 50)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let queued = vm.queuedPrompt {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Отправлю, как только модель запустится: «\(String(queued.prefix(40)))»")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Отмена") {
                        input = vm.takeQueued()
                    }
                    .font(.caption.weight(.semibold))
                }
            } else if input.utf8.count > 3000 && !vm.isGenerating {
                Text("Длинный текст: приложение прочитает его по частям, это займёт время")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    vm.loadState == .ready ? "Сообщение" : "Сообщение (модель запускается…)",
                    text: $input,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.vertical, 8)

                Button {
                    if vm.isGenerating {
                        vm.stop()
                    } else if vm.loadState == .ready {
                        vm.send(input)
                        input = ""
                    } else {
                        vm.queue(input)
                        input = ""
                    }
                } label: {
                    Image(systemName: vm.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(vm.isGenerating || canSend ? .white : Color(white: 0.4))
                }
                .disabled(!vm.isGenerating && (!canSend || vm.queuedPrompt != nil))
            }
            .padding(.leading, 16)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(white: 0.17))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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

// MARK: - Настройки

private struct SettingsView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PerformanceMode.allCases) { mode in
                        Button {
                            vm.mode = mode
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mode.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(mode.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                if vm.mode == mode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Нагрузка на телефон")
                } footer: {
                    Text("Режим не меняет саму модель и качество ответов. Он влияет на плавность интерфейса, нагрев и длину ответов. Применяется со следующего сообщения.")
                }

                Section {
                    TextEditor(text: $vm.customInstructions)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("Свои инструкции")
                } footer: {
                    Text("Например: «Отвечай коротко и на ты». Максимум 500 символов (\(vm.customInstructions.count)/500).")
                }

                Section {
                    Button("Удалить все чаты", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog(
                "Удалить все сохранённые чаты?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    vm.deleteAllChats()
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
    }
}

// MARK: - История чатов

private struct HistoryView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.conversations.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Сохранённых чатов пока нет")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vm.conversations) { conversation in
                            Button {
                                vm.openChat(conversation.id)
                                dismiss()
                            } label: {
                                row(conversation)
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { vm.conversations[$0].id }
                            for id in ids { vm.deleteChat(id) }
                        }
                    }
                }
            }
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
        .tint(.orange)
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
