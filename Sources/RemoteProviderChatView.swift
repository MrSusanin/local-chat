import SwiftUI
import PhotosUI

@MainActor
struct RemoteProviderChatView: View {
    @ObservedObject var appState: AppSessionStore
    @State private var messages: [ChatMessage] = []
    @State private var conversationID = UUID()
    @State private var input = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var isSending = false
    @State private var errorText: String?

    private var capabilities: [ModelCapability] { appState.currentProfile.capabilities }
    private var client: AIProviderClient {
        AIProviderClientFactory.make(provider: appState.selectedProvider, modelName: appState.selectedModelName)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            ContentUnavailableView(
                                "Чат с \(appState.selectedProvider.title)",
                                systemImage: "sparkles",
                                description: Text("Сообщения отправляются выбранному API-провайдеру.")
                            )
                            .padding(.top, 70)
                        }
                        ForEach(messages) { message in
                            HStack {
                                if message.role == .user { Spacer(minLength: 45) }
                                Text(message.text.isEmpty ? "…" : message.text)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .foregroundStyle(.white)
                                    .background(message.role == .user ? Color.orange.opacity(0.35) : Color(white: 0.16))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                if message.role == .assistant { Spacer(minLength: 45) }
                            }
                        }
                    }
                    .padding()
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                composer
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(appState.selectedProvider.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Новый чат", systemImage: "square.and.pencil") { startNewChat() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Text("Модель: \(appState.selectedModelName)")
                        Button("Выйти", systemImage: "rectangle.portrait.and.arrow.right") {
                            appState.logout()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { loadLatestConversation() }
            .onChange(of: selectedPhoto) { _, item in
                Task { await loadPhoto(item) }
            }
        }
        .tint(.orange)
        .preferredColorScheme(.dark)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if capabilities.contains(.image) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(photoData == nil ? .orange : .green)
                    }
                    .accessibilityLabel("Прикрепить фото")
                }

                TextField("Сообщение", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.vertical, 8)

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .disabled(isSending || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoData == nil))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 24))

            HStack {
                if photoData != nil {
                    Label("Фото прикреплено", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Убрать") { photoData = nil; selectedPhoto = nil }
                        .font(.caption)
                }
                Spacer()
                Text("Проверьте условия и стоимость API у провайдера")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { photoData = nil; return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorText = "Не удалось прочитать изображение."
                return
            }
            guard data.count <= 15 * 1_024 * 1_024 else {
                errorText = "Изображение слишком большое (лимит 15 МБ)."
                selectedPhoto = nil
                return
            }
            photoData = data
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !prompt.isEmpty || photoData != nil else { return }
        isSending = true
        errorText = nil

        let userText = photoData == nil ? prompt : "📷 Фото\n\(prompt.isEmpty ? "Опиши изображение." : prompt)"
        messages.append(ChatMessage(role: .user, text: userText))
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        let replyID = reply.id
        let image = photoData
        input = ""
        photoData = nil
        selectedPhoto = nil

        do {
            let answer: String
            if let image {
                answer = try await client.sendImage(image, prompt: prompt, apiKey: appState.apiKey)
            } else {
                answer = try await client.sendText(prompt, apiKey: appState.apiKey)
            }
            updateReply(replyID, text: answer)
            persistConversation()
        } catch {
            let message = error.localizedDescription
            updateReply(replyID, text: "⚠️ \(message)")
            errorText = message
            persistConversation()
        }
        isSending = false
    }

    private func updateReply(_ id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func startNewChat() {
        persistConversation()
        conversationID = UUID()
        messages = []
        input = ""
        errorText = nil
    }

    private func loadLatestConversation() {
        do {
            guard let latest = try CoreDataStack.shared.fetchConversations().first else { return }
            conversationID = latest.id
            messages = latest.messages
        } catch {
            errorText = "Не удалось загрузить историю: \(error.localizedDescription)"
        }
    }

    private func persistConversation() {
        let savedMessages = messages.filter { !$0.text.isEmpty }
        guard !savedMessages.isEmpty else { return }
        let firstUserText = savedMessages.first(where: { $0.role == .user })?.text ?? "Новый чат"
        let title = String(firstUserText.prefix(60))
        let conversation = Conversation(
            id: conversationID,
            title: title,
            updatedAt: Date(),
            messages: savedMessages
        )
        do {
            try CoreDataStack.shared.saveConversation(conversation)
        } catch {
            errorText = "Не удалось сохранить историю: \(error.localizedDescription)"
        }
    }
}
