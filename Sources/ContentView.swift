import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var input = ""
    @FocusState private var inputFocused: Bool

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
            .navigationTitle("Локальный чат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if vm.loadState == .ready {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Новый чат", systemImage: "square.and.pencil") {
                                vm.newChat()
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
        .onChange(of: scenePhase) { _, phase in
            // В фоне GPU недоступен, поэтому генерацию останавливаем.
            if phase != .active { vm.stop() }
        }
        .onAppear { vm.autoLoadIfPossible() }
    }

    // MARK: - Экран чата

    private var chatView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if vm.messages.isEmpty {
                            emptyHint
                        }
                        ForEach(vm.messages) { message in
                            MessageBubble(
                                message: message,
                                isStreaming: vm.isGenerating && message.id == vm.messages.last?.id
                            )
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: vm.messages) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            inputBar
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Спросите что-нибудь")
                .font(.title3.weight(.semibold))
            Text("Всё работает на вашем iPhone, без интернета.\nМодель небольшая, так что сложные вопросы ей даются хуже, чем большим ИИ.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 80)
        .padding(.horizontal, 24)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Сообщение", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(white: 0.17))
                )

            Button {
                if vm.isGenerating {
                    vm.stop()
                } else {
                    vm.send(input)
                    input = ""
                }
            } label: {
                Image(systemName: vm.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 36))
            }
            .disabled(!vm.isGenerating && !canSend)
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
        .disabled(isDownloading)
    }

    private var isDownloading: Bool {
        if case .downloading = vm.loadState { return true }
        return false
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch vm.loadState {
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

private struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool

    private var isUser: Bool { message.role == .user }

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: message.text, options: options))
            ?? AttributedString(message.text)
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 44) }

            Group {
                if message.text.isEmpty && isStreaming {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(rendered)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isUser ? Color.blue : Color(white: 0.17))
            )
            .contextMenu {
                Button("Копировать", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.text
                }
            }

            if !isUser { Spacer(minLength: 44) }
        }
    }
}
