import CoreData
import Foundation

final class CoreDataStack {
    static let shared = CoreDataStack()

    private let container: NSPersistentContainer

    private init() {
        let model = NSManagedObjectModel()

        let conversationEntity = NSEntityDescription()
        conversationEntity.name = "StoredConversation"
        conversationEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        let idAttribute = NSAttributeDescription.stringAttribute("id")
        let titleAttribute = NSAttributeDescription.stringAttribute("title")
        let updatedAtAttribute = NSAttributeDescription.dateAttribute("updatedAt")

        let messageEntity = NSEntityDescription()
        messageEntity.name = "StoredMessage"
        messageEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        let roleAttribute = NSAttributeDescription.stringAttribute("role")
        let textAttribute = NSAttributeDescription.stringAttribute("text")
        let messageIdAttribute = NSAttributeDescription.stringAttribute("messageID")
        let conversationRelation = NSRelationshipDescription()
        conversationRelation.name = "conversation"
        conversationRelation.destinationEntity = messageEntity
        conversationRelation.minCount = 0
        conversationRelation.maxCount = 1
        conversationRelation.deleteRule = .nullifyDeleteRule

        let messagesRelation = NSRelationshipDescription()
        messagesRelation.name = "messages"
        messagesRelation.destinationEntity = messageEntity
        messagesRelation.deleteRule = .cascadeDeleteRule
        messagesRelation.minCount = 0
        messagesRelation.maxCount = 0
        messagesRelation.isToMany = true
        messagesRelation.inverseRelationship = conversationRelation

        conversationEntity.properties = [idAttribute, titleAttribute, updatedAtAttribute, messagesRelation]
        messageEntity.properties = [messageIdAttribute, roleAttribute, textAttribute, conversationRelation]

        model.entities = [conversationEntity, messageEntity]

        container = NSPersistentContainer(name: "LocalChatModel", managedObjectModel: model)
        container.loadPersistentStores { _, error in
            if let error {
                assertionFailure("Core Data failed to load: \(error.localizedDescription)")
            }
        }
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    func saveContext() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                assertionFailure("Failed to save context: \(error.localizedDescription)")
            }
        }
    }

    func fetchConversations() -> [Conversation] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        do {
            let rows = try viewContext.fetch(request)
            return rows.compactMap { convert($0) }
        } catch {
            return []
        }
    }

    func saveConversation(_ conversation: Conversation) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        request.predicate = NSPredicate(format: "id == %@", conversation.id.uuidString)

        let existing = (try? viewContext.fetch(request))?.first
        let entity = existing ?? NSEntityDescription.insertNewObject(
            forEntityName: "StoredConversation",
            into: viewContext
        )

        entity.setValue(conversation.id.uuidString, forKey: "id")
        entity.setValue(conversation.title, forKey: "title")
        entity.setValue(conversation.updatedAt, forKey: "updatedAt")

        let existingMessages = (entity.value(forKey: "messages") as? Set<NSManagedObject>) ?? []
        for message in existingMessages { viewContext.delete(message) }

        for message in conversation.messages {
            let managedMessage = NSEntityDescription.insertNewObject(
                forEntityName: "StoredMessage",
                into: viewContext
            )
            managedMessage.setValue(message.id.uuidString, forKey: "messageID")
            managedMessage.setValue(message.role.rawValue, forKey: "role")
            managedMessage.setValue(message.text, forKey: "text")
            managedMessage.setValue(entity, forKey: "conversation")
        }

        saveContext()
    }

    func deleteConversation(id: UUID) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        request.predicate = NSPredicate(format: "id == %@", id.uuidString)
        guard let row = (try? viewContext.fetch(request))?.first else { return }
        viewContext.delete(row)
        saveContext()
    }

    func deleteAllConversations() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        let rows = (try? viewContext.fetch(request)) ?? []
        rows.forEach { viewContext.delete($0) }
        saveContext()
    }

    private func convert(_ object: NSManagedObject) -> Conversation? {
        guard
            let idValue = object.value(forKey: "id") as? String,
            let title = object.value(forKey: "title") as? String,
            let updatedAt = object.value(forKey: "updatedAt") as? Date,
            let messages = object.value(forKey: "messages") as? Set<NSManagedObject>
        else {
            return nil
        }

        let storedMessages = messages.compactMap { messageObject -> ChatMessage? in
            guard
                let roleValue = messageObject.value(forKey: "role") as? String,
                let text = messageObject.value(forKey: "text") as? String,
                let id = UUID(uuidString: ((messageObject.value(forKey: "messageID") as? String) ?? UUID().uuidString))
            else {
                return nil
            }

            let role = ChatMessage.Role(rawValue: roleValue) ?? .user
            var chatMessage = ChatMessage(role: role, text: text)
            chatMessage.id = id
            return chatMessage
        }

        let uuid = UUID(uuidString: idValue) ?? UUID()
        return Conversation(id: uuid, title: title, updatedAt: updatedAt, messages: storedMessages.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}

private extension NSAttributeDescription {
    static func stringAttribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = false
        return attribute
    }

    static func dateAttribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .dateAttributeType
        attribute.isOptional = false
        return attribute
    }
}
