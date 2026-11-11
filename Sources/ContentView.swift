import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    let appState: AppSessionStore
    @StateObject private var vm = ChatViewModel()
    @StateObject private var network = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @State private var input = ""
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var atBottom = true
    @FocusState private var inputFocused: Bool

    // Вложения к следующему сообщению.
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showAudioPicker = false
    @State private var showDocumentPicker = false
    @State private var previewItem: PreviewItem?

    // Черновик API ключа на экране выбора ИИ.
    @State private var apiKeyDraft = ""

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
                ToolbarItem(placement: .topBarLeading) {
                    if showsChat {
                        Button {
                            inputFocused = false
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    } else if vm.canCloseModelSetup {
                        Button("Назад") {
                            vm.closeModelSetup()
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
                            Button("Сменить ИИ / модель", systemImage: "cpu") {
                                inputFocused = false
                                vm.openModelSetup()
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
            SettingsView(vm: vm, appState: appState)
        }
        .sheet(item: $previewItem) { item in
            QuickLookSheet(url: item.url)
        }
        .fileImporter(isPresented: $showAudioPicker, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importFile(url, kind: .audio)
            }
        }
        .fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: [.pdf, .plainText], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importFile(url, kind: .document)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // В фоне GPU недоступен, поэтому генерацию останавливаем и сохраняем чат.
            if phase != .active {
                vm.stop()
                vm.saveCurrent()
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await importPhoto(item) }
        }
        .onChange(of: vm.provider) { old, new in
            // Ключ прежнего провайдера сохраняем, черновик меняем на ключ нового.
            commitAPIKey(for: old)
            apiKeyDraft = vm.apiKey(for: new)
        }
        .onAppear {
            vm.autoLoadIfPossible()
            apiKeyDraft = vm.apiKey(for: vm.provider)
        }
    }

    /// Чат показываем сразу, даже пока локальная модель запускается: можно читать историю
    /// и писать сообщение. Для облачных провайдеров модель не нужна вовсе.
    private var showsChat: Bool {
        if vm.showsModelSetup { return false }
        if vm.provider == .local {
            switch vm.loadState {
            case .ready, .starting: return true
            default: return false
            }
        }
        return true
    }

    // MARK: - Заголовок со статусом

    private var statusInfo: (text: String, color: Color) {
        if vm.provider != .local {
            if vm.isGenerating { return (text: "Облако думает…", color: .orange) }
            return vm.hasAPIKey
                ? (text: "Готов · \(vm.modelDisplayName)", color: .green)
                : (text: "Нет API ключа", color: .orange)
        }
        switch vm.loadState {
        case .ready:
            if vm.isGenerating { return (text: "Думает…", color: .orange) }
            return (text: "Модель готова", color: .green)
        case .starting:
            return (text: "Запуск модели…", color: .orange)
        case .downloading(let progress):
            return (text: "Загрузка \(Int(progress * 100))%", color: .orange)
        case .idle:
            return (text: "Модель не загружена", color: .gray)
        case .failed:
            return (text: "Ошибка модели", color: .red)
        }
    }

    private var statusHeader: some View {
        let status = statusInfo
        return VStack(spacing: 1) {
            Text(vm.provider == .local ? "Локальный чат" : vm.provider.title)
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
            onRegenerate: { vm.regenerate() },
            onOpenAttachment: { attachment in
                previewItem = vm.attachmentURL(messageID: message.id, attachment: attachment)
                    .map { PreviewItem(url: $0) }
            }
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
                Text(vm.provider == .local
                     ? "Всё работает на вашем iPhone, без интернета."
                     : "Ответы придут из облака \(vm.provider.title).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if vm.provider != .local && !vm.hasAPIKey {
                Button("Указать API ключ") {
                    vm.openModelSetup()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
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

    private var canAttach: Bool {
        !vm.isGenerating
    }

    // MARK: - Поле ввода

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
            } else if input.utf8.count > 3000 && !vm.isGenerating && vm.provider == .local {
                Text("Длинный текст: приложение прочитает его по частям, это займёт время")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !pendingAttachments.isEmpty {
                attachmentChips
            }

            HStack(alignment: .bottom, spacing: 8) {
                if vm.provider != .local {
                    attachmentButtons
                }

                TextField(
                    vm.provider == .local
                        ? (vm.loadState == .ready ? "Сообщение" : "Сообщение (модель запускается…)")
                        : "Сообщение",
                    text: $input,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.vertical, 8)

                Button {
                    if vm.isGenerating {
                        vm.stop()
                    } else {
                        sendCurrent()
                    }
                } label: {
                    Image(systemName: vm.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(vm.isGenerating || canSend || !pendingAttachments.isEmpty ? .white : Color(white: 0.4))
                }
                .disabled(!vm.isGenerating && ((!canSend && pendingAttachments.isEmpty) || vm.queuedPrompt != nil))
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

    /// Кнопки вложений появляются в зависимости от возможностей модели.
    private var attachmentButtons: some View {
        HStack(spacing: 12) {
            if vm.supports(.image) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 21))
                        .foregroundColor(canAttach ? .orange : Color(white: 0.4))
                }
                .disabled(!canAttach)
            }
            if vm.supports(.audio) {
                Button {
                    showAudioPicker = true
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 21))
                        .foregroundColor(canAttach ? .orange : Color(white: 0.4))
                }
                .disabled(!canAttach)
            }
            if vm.supports(.document) {
                Button {
                    showDocumentPicker = true
                } label: {
                    Image(systemName: "doc")
                        .font(.system(size: 21))
                        .foregroundColor(canAttach ? .orange : Color(white: 0.4))
                }
                .disabled(!canAttach)
            }
        }
        .padding(.bottom, 6)
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.kind.systemImage)
                            .font(.footnote)
                        Text(attachment.fileName)
                            .font(.footnote)
                            .lineLimit(1)
                        Button {
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(white: 0.22)))
                    .foregroundColor(.orange)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sendCurrent() {
        let text = input
        let attachments = pendingAttachments
        vm.send(text, attachments: attachments)
        input = ""
        pendingAttachments = []
    }

    // MARK: - Выбор вложений

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { return }
        var payload = data
        var fileName = "photo"
        if let image = UIImage(data: data) {
            let prepared = image.preparedForUpload()
            if let jpeg = prepared.jpegData(compressionQuality: 0.85) {
                payload = jpeg
                fileName = "photo.jpg"
            }
        }
        guard payload.count <= PendingAttachment.maxSize else { return }
        pendingAttachments.append(PendingAttachment(
            kind: .image,
            fileName: fileName,
            mimeType: "image/jpeg",
            data: payload
        ))
    }

    private func importFile(_ url: URL, kind: ChatAttachment.Kind) {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= PendingAttachment.maxSize else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        pendingAttachments.append(PendingAttachment(
            kind: kind,
            fileName: url.lastPathComponent,
            mimeType: mime,
            data: data
        ))
    }

    // MARK: - Экран выбора ИИ и модели

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: vm.provider == .local ? "sparkles" : "cloud")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                    .padding(.top, 24)

                Text(vm.provider == .local ? "ИИ прямо на вашем iPhone" : "ИИ в облаке \(vm.provider.title)")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(vm.provider.summary)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Picker("Провайдер", selection: $vm.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.shortTitle).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                if vm.provider == .local {
                    VStack(spacing: 10) {
                        ForEach(AIProvider.local.models) { model in
                            modelRow(model)
                        }
                    }
                    if vm.selectedLocalModel?.isSuper == true {
                        Label(
                            "Супер-модель занимает ~1,9 ГБ и требует много памяти. На iPhone с 4 ГБ ОЗУ она может не запуститься.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    setupStatus
                } else {
                    remoteSetup
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .onAppear {
            // Черновик ключа всегда свежий: его могли поменять в настройках.
            apiKeyDraft = vm.apiKey(for: vm.provider)
        }
    }

    private func modelRow(_ model: AIModelOption) -> some View {
        let selected = vm.modelName == model.name
        return Button {
            vm.selectModel(model.name, for: vm.provider)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.title).font(.headline)
                        if model.isSuper {
                            Text("СУПЕР")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.25)))
                                .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
                                .foregroundColor(.orange)
                        }
                    }
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

    /// Настройка облачного провайдера: ключ + выбор модели.
    private var remoteSetup: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("API ключ \(vm.provider.title)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("Введите API ключ", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(white: 0.13))
                    )
                    .foregroundStyle(.white)
                Text("Ключ хранится в связке ключей устройства и уходит только на серверы \(vm.provider.title).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(vm.provider.models) { model in
                    modelRow(model)
                }
            }

            Button {
                commitAPIKey(for: vm.provider)
                vm.closeModelSetup()
            } label: {
                Text("Начать чат")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundColor(.black)
            }
            .padding(.top, 6)
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commitAPIKey(for provider: AIProvider) {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.updateAPIKey(trimmed, for: provider)
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
            Text(vm.selectedLocalModel?.isSuper == true ? "Скачать супер-модель" : "Скачать и запустить")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundColor(.black)
        }
        .padding(.top, 6)
    }
}

// MARK: - Элемент для просмотра вложения

private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Настройки

private struct SettingsView: View {
    @ObservedObject var vm: ChatViewModel
    let appState: AppSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var apiKeyDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                if !appState.username.isEmpty {
                    Section("Аккаунт") {
                        LabeledContent("Логин", value: appState.username)
                        Button("Выйти из аккаунта", role: .destructive) {
                            dismiss()
                            appState.logout()
                        }
                    }
                }

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
                    Text("Нагрузка на телефон (локальная модель)")
                } footer: {
                    Text("Режим не меняет саму модель и качество ответов. Он влияет на плавность интерфейса, нагрев и длину ответов. Применяется со следующего сообщения.")
                }

                if vm.provider != .local {
                    Section {
                        SecureField("API ключ", text: $apiKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Сохранить ключ") {
                            let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            vm.updateAPIKey(trimmed, for: vm.provider)
                        }
                        .disabled(apiKeyDraft == vm.apiKey(for: vm.provider))
                    } header: {
                        Text("API ключ \(vm.provider.title)")
                    } footer: {
                        Text("Ключ хранится в связке ключей устройства и уходит только на серверы \(vm.provider.title).")
                    }
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
                } footer: {
                    Text("Чаты сохраняются в Core Data на устройстве и никуда не отправляются.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear {
                apiKeyDraft = vm.apiKey(for: vm.provider)
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
