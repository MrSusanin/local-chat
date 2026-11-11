import CoreData
import Foundation
import os

// MARK: - Объекты хранилища

@objc(StoredConversationMO)
final class StoredConversationMO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var title: String
    @NSManaged var updatedAt: Date
    @NSManaged var messages: Set<StoredMessageMO>
}

@objc(StoredMessageMO)
final class StoredMessageMO: NSManagedObject {
    @NSManaged var messageID: String
    @NSManaged var role: String
    @NSManaged var text: String
    /// Порядок сообщения внутри чата. Без него Core Data возвращал бы сообщения вперемешку.
    @NSManaged var sortIndex: Int64
    @NSManaged var attachmentsJSON: String?
    @NSManaged var conversation: StoredConversationMO?
}

// MARK: - Хранилище

/// Сохранение чатов в Core Data. Все обращения идут из главного потока.
final class CoreDataStack {
    static let shared = CoreDataStack()

    private let container: NSPersistentContainer
    private let log = Logger(subsystem: "com.example.localchat", category: "CoreData")

    private init() {
        container = NSPersistentContainer(name: "LocalChatModel", managedObjectModel: Self.makeModel())
        container.loadPersistentStores { [weak self] _, error in
            if let error {
                // assertionFailure здесь ломал бы сборку Release: просто пишем в журнал.
                self?.log.error("Не удалось открыть хранилище: \(error.localizedDescription)")
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    // MARK: Схема

    private static func makeModel() -> NSManagedObjectModel {
        let conversationEntity = NSEntityDescription()
        conversationEntity.name = "StoredConversation"
        conversationEntity.managedObjectClassName = "StoredConversationMO"

        let messageEntity = NSEntityDescription()
        messageEntity.name = "StoredMessage"
        messageEntity.managedObjectClassName = "StoredMessageMO"

        let idAttribute = NSAttributeDescription.stringAttribute("id")
        let titleAttribute = NSAttributeDescription.stringAttribute("title")
        let updatedAtAttribute = NSAttributeDescription.dateAttribute("updatedAt")

        let messageIdAttribute = NSAttributeDescription.stringAttribute("messageID")
        let roleAttribute = NSAttributeDescription.stringAttribute("role")
        let textAttribute = NSAttributeDescription.stringAttribute("text")
        let sortIndexAttribute = NSAttributeDescription.int64Attribute("sortIndex")
        let attachmentsAttribute = NSAttributeDescription.stringAttribute("attachmentsJSON", optional: true)

        // Связь «чат → сообщения» (многие) и обратная «сообщение → чат» (один).
        // Раньше обратная связь была выставлена только с одной стороны —
        // из-за этого сохранение падало с ошибкой валидации и чаты терялись.
        let messagesRelation = NSRelationshipDescription()
        messagesRelation.name = "messages"
        messagesRelation.destinationEntity = messageEntity
        messagesRelation.minCount = 0
        messagesRelation.maxCount = 0          // 0 означает «многие»
        messagesRelation.deleteRule = .cascadeDeleteRule
        messagesRelation.isOptional = true

        let conversationRelation = NSRelationshipDescription()
        conversationRelation.name = "conversation"
        conversationRelation.destinationEntity = conversationEntity
        conversationRelation.minCount = 0
        conversationRelation.maxCount = 1
        conversationRelation.deleteRule = .nullifyDeleteRule
        conversationRelation.isOptional = true

        messagesRelation.inverseRelationship = conversationRelation
        conversationRelation.inverseRelationship = messagesRelation

        conversationEntity.properties = [idAttribute, titleAttribute, updatedAtAttribute, messagesRelation]
        messageEntity.properties = [
            messageIdAttribute, roleAttribute, textAttribute, sortIndexAttribute,
            attachmentsAttribute, conversationRelation
        ]

        let model = NSManagedObjectModel()
        model.entities = [conversationEntity, messageEntity]
        return model
    }

    // MARK: Чтение

    func fetchConversations() -> [Conversation] {
        let request = NSFetchRequest<StoredConversationMO>(entityName: "StoredConversation")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            return try viewContext.fetch(request).compactMap(Self.makeConversation)
        } catch {
            log.error("Не удалось прочитать чаты: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Запись

    func saveConversation(_ conversation: Conversation) {
        let context = viewContext
        let request = NSFetchRequest<StoredConversationMO>(entityName: "StoredConversation")
        request.predicate = NSPredicate(format: "id == %@", conversation.id.uuidString)

        let existing = (try? context.fetch(request))?.first
        let row = existing
            ?? NSEntityDescription.insertNewObject(forEntityName: "StoredConversation", into: context) as! StoredConversationMO

        row.id = conversation.id.uuidString
        row.title = conversation.title
        row.updatedAt = conversation.updatedAt

        // Сообщения заменяем целиком: так проще поддерживать их порядок.
        let oldMessages = Array(row.messages)
        for message in oldMessages { context.delete(message) }

        for (index, message) in conversation.messages.enumerated() {
            let item = NSEntityDescription.insertNewObject(forEntityName: "StoredMessage", into: context) as! StoredMessageMO
            item.messageID = message.id.uuidString
            item.role = message.role.rawValue
            item.text = message.text
            item.sortIndex = Int64(index)
            item.attachmentsJSON = Self.encodeAttachments(message.attachments)
            item.conversation = row
        }
        saveContext()
    }

    func deleteConversation(id: UUID) {
        let request = NSFetchRequest<StoredConversationMO>(entityName: "StoredConversation")
        request.predicate = NSPredicate(format: "id == %@", id.uuidString)
        for row in (try? viewContext.fetch(request)) ?? [] {
            viewContext.delete(row)
        }
        saveContext()
    }

    func deleteAllConversations() {
        let request = NSFetchRequest<StoredConversationMO>(entityName: "StoredConversation")
        for row in (try? viewContext.fetch(request)) ?? [] {
            viewContext.delete(row)
        }
        saveContext()
    }

    func saveContext() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            log.error("Не удалось сохранить чаты: \(error.localizedDescription)")
        }
    }

    // MARK: Перенос старого хранилища (JSON)

    /// Один раз переносит чаты из старого файла conversations.json в Core Data,
    /// чтобы при обновлении приложения история не пропала.
    func migrateLegacyStoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didMigrateConversationsToCoreData") else { return }
        defaults.set(true, forKey: "didMigrateConversationsToCoreData")

        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let legacy = base.appendingPathComponent("conversations.json")
        guard manager.fileExists(atPath: legacy.path) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: legacy),
              let old = try? decoder.decode([Conversation].self, from: data),
              !old.isEmpty else {
            return
        }
        for conversation in old {
            saveConversation(conversation)
        }
        // Старый файл не удаляем, а переименовываем — как резервную копию.
        try? manager.moveItem(at: legacy, to: legacy.appendingPathExtension("backup"))
        log.info("Перенесено чатов из JSON: \(old.count)")
    }

    // MARK: Преобразования

    private static func makeConversation(_ row: StoredConversationMO) -> Conversation? {
        guard let id = UUID(uuidString: row.id) else { return nil }
        let messages = row.messages
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { item -> ChatMessage? in
                guard let role = ChatMessage.Role(rawValue: item.role) else { return nil }
                return ChatMessage(
                    id: UUID(uuidString: item.messageID) ?? UUID(),
                    role: role,
                    text: item.text,
                    attachments: decodeAttachments(item.attachmentsJSON)
                )
            }
        return Conversation(id: id, title: row.title, updatedAt: row.updatedAt, messages: messages)
    }

    private static func encodeAttachments(_ attachments: [ChatAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(attachments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeAttachments(_ json: String?) -> [ChatAttachment] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChatAttachment].self, from: data)) ?? []
    }
}

// MARK: - Помощники для атрибутов

private extension NSAttributeDescription {
    static func stringAttribute(_ name: String, optional: Bool = false) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = optional
        attribute.defaultValue = optional ? nil : ""
        return attribute
    }

    static func dateAttribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .dateAttributeType
        attribute.isOptional = false
        return attribute
    }

    static func int64Attribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = false
        attribute.defaultValue = 0
        return attribute
    }
}
