import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

// MARK: - Вложения сообщений

/// Вложение, сохранённое на диске: в сообщении лежат метаданные,
/// сами данные — в файле внутри приложения.
struct ChatAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case image
        case audio
        case document

        var capability: ModelCapability {
            switch self {
            case .image: return .image
            case .audio: return .audio
            case .document: return .document
            }
        }

        var systemImage: String { capability.systemImage }
    }

    var id = UUID()
    /// Имя файла, как его видит пользователь.
    let fileName: String
    /// Имя файла в папке вложений приложения.
    let storedName: String
    let kind: Kind
}

/// Вложение, которое пользователь только что выбрал и ещё не отправил.
struct PendingAttachment: Identifiable {
    let id = UUID()
    let kind: ChatAttachment.Kind
    let fileName: String
    let mimeType: String
    let data: Data
    /// Если вложение уже сохранено (перегенерация ответа) — используем тот же файл.
    var existingStoredName: String?

    /// Максимальный размер файла, который вкладываем (10 МБ).
    static let maxSize = 10 * 1_048_576
}

// MARK: - Хранилище файлов вложений

enum AttachmentStore {
    /// Папка, где лежат данные вложений.
    static let directory: URL = {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let dir = base.appendingPathComponent("attachments", isDirectory: true)
        try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Сохраняет данные и возвращает имя файла в хранилище.
    static func save(data: Data, fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension
        let stored = UUID().uuidString + (ext.isEmpty ? "" : "." + ext.lowercased())
        do {
            try data.write(to: directory.appendingPathComponent(stored), options: .atomic)
            return stored
        } catch {
            return nil
        }
    }

    static func url(forStoredName storedName: String) -> URL {
        directory.appendingPathComponent(storedName)
    }

    static func data(forStoredName storedName: String) -> Data? {
        try? Data(contentsOf: url(forStoredName: storedName))
    }

    static func remove(storedName: String) {
        try? FileManager.default.removeItem(at: url(forStoredName: storedName))
    }

    static func removeAll() {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files {
            try? manager.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

// MARK: - Подготовка фото к отправке

extension UIImage {
    /// Уменьшает фото и убирает поворот, чтобы облако получило компактное «прямое» изображение.
    func preparedForUpload(maxDimension: CGFloat = 2048) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension, largest > 0 else { return self }
        let scale = maxDimension / largest
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Просмотр вложения

/// Быстрый просмотр файла (фото, аудио, PDF) средствами системы.
struct QuickLookSheet: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Значок вложения

/// Значок вложения внутри сообщения.
struct AttachmentChip: View {
    let attachment: ChatAttachment
    var onOpen: (() -> Void)?

    var body: some View {
        Button {
            onOpen?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind.systemImage)
                    .font(.footnote)
                Text(attachment.fileName)
                    .font(.footnote)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.24)))
            .overlay(Capsule().stroke(Color(white: 0.35), lineWidth: 1))
            .foregroundColor(.orange)
        }
        .buttonStyle(.plain)
    }
}
