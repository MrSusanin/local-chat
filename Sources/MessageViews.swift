import SwiftUI
import UIKit

// MARK: - Отслеживание положения прокрутки

/// Положение «дна» чата относительно экрана. Если дно не отрисовано (мы далеко от конца),
/// остаётся значение по умолчанию, и кнопка «вниз» показывается.
struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Простая разметка Markdown

struct TextSegment: Identifiable {
    let id: Int
    let isCode: Bool
    let text: String
}

enum MarkdownText {
    /// Делит ответ на обычный текст и блоки кода (```).
    static func segments(_ text: String) -> [TextSegment] {
        var result: [TextSegment] = []
        var buffer: [String] = []
        var inCode = false

        func flush() {
            let joined = buffer.joined(separator: "\n")
            buffer.removeAll()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            let body = inCode ? joined.trimmingCharacters(in: .newlines) : trimmed
            result.append(TextSegment(id: result.count, isCode: inCode, text: body))
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }

    /// Заголовки превращаются в жирный текст, маркеры списков в «•».
    static func prepare(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("#") {
                let title = trimmed
                    .drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**" + title + "**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return "• " + String(trimmed.dropFirst(2))
            }
            return line
        }
        .joined(separator: "\n")
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: prepare(text), options: options))
            ?? AttributedString(text)
    }
}

// MARK: - Сообщение

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    let isLast: Bool
    let isLong: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onRegenerate: () -> Void
    let onOpenAttachment: (ChatAttachment) -> Void

    @State private var copied = false

    // Закрытия не сравниваются: экран перерисовывает только изменившиеся сообщения.
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isStreaming == rhs.isStreaming
            && lhs.isLast == rhs.isLast
            && lhs.isLong == rhs.isLong
            && lhs.isCollapsed == rhs.isCollapsed
    }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantBlock
        }
    }

    // MARK: Сообщение пользователя

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.attachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(message.attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                onOpenAttachment(attachment)
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(isCollapsed ? String(message.text.prefix(500)) + "…" : message.text)
                        .lineLimit(isCollapsed ? 6 : nil)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.white)
                }
                if isLong {
                    toggleButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(white: 0.2))
            )
            .contextMenu {
                Button("Копировать", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.text
                }
            }
        }
    }

    // MARK: Ответ ассистента

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.text.isEmpty {
                if isStreaming {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse)
                        .padding(.vertical, 6)
                }
            } else if isCollapsed {
                Text(MarkdownText.attributed(String(message.text.prefix(600)) + "…"))
                    .lineLimit(8)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                toggleButton
            } else {
                RichText(text: message.text)
                if isLong && !isStreaming {
                    toggleButton
                }
            }

            if showActions {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Копировать", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            }
        }
    }

    private var showActions: Bool {
        !isStreaming && !message.text.isEmpty && !message.text.hasPrefix("⏳")
    }

    private var actionRow: some View {
        HStack(spacing: 20) {
            Button {
                UIPasteboard.general.string = message.text
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }

            ShareLink(item: message.text) {
                Image(systemName: "square.and.arrow.up")
            }

            if isLast {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Text(isCollapsed ? "Показать полностью" : "Свернуть")
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.orange)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Текст с блоками кода

struct RichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownText.segments(text)) { segment in
                if segment.isCode {
                    CodeBlock(code: segment.text)
                } else {
                    Text(MarkdownText.attributed(segment.text))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct CodeBlock: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Код")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Скопировано" : "Копировать",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(white: 0.22), lineWidth: 1)
        )
    }
}
