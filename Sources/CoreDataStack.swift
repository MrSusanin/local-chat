import CoreData
import Foundation

@MainActor
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
        let positionAttribute = NSAttributeDescription.integerAttribute("position")

        let conversationRelation = NSRelationshipDescription()
        conversationRelation.name = "conversation"
        conversationRelation.destinationEntity = conversationEntity
        conversationRelation.minCount = 1
        conversationRelation.maxCount = 1
        conversationRelation.deleteRule = .nullifyDeleteRule

        let messagesRelation = NSRelationshipDescription()
        messagesRelation.name = "messages"
        messagesRelation.destinationEntity = messageEntity
        messagesRelation.minCount = 0
        messagesRelation.maxCount = 0
        messagesRelation.deleteRule = .cascadeDeleteRule

        messagesRelation.inverseRelationship = conversationRelation
        conversationRelation.inverseRelationship = messagesRelation

        conversationEntity.properties = [idAttribute, titleAttribute, updatedAtAttribute, messagesRelation]
        messageEntity.properties = [messageIdAttribute, roleAttribute, textAttribute, positionAttribute, conversationRelation]

        model.entities = [conversationEntity, messageEntity]

        container = NSPersistentContainer(name: "LocalChatModel", managedObjectModel: model)
        container.loadPersistentStores { _, error in
            if let error {
                assertionFailure("Core Data failed to load: \(error.localizedDescription)")
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    func saveContext() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        try context.save()
    }

    func fetchConversations() throws -> [Conversation] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try viewContext.fetch(request).compactMap(convert)
    }

    func saveConversation(_ conversation: Conversation) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", conversation.id.uuidString)

        let stored = try viewContext.fetch(request).first ?? NSEntityDescription.insertNewObject(
            forEntityName: "StoredConversation",
            into: viewContext
        )

        stored.setValue(conversation.id.uuidString, forKey: "id")
        stored.setValue(conversation.title, forKey: "title")
        stored.setValue(conversation.updatedAt, forKey: "updatedAt")

        let oldMessages = (stored.value(forKey: "messages") as? Set<NSManagedObject>) ?? []
        oldMessages.forEach(viewContext.delete)

        for (index, message) in conversation.messages.enumerated() {
            let managedMessage = NSEntityDescription.insertNewObject(
                forEntityName: "StoredMessage",
                into: viewContext
            )
            managedMessage.setValue(message.id.uuidString, forKey: "messageID")
            managedMessage.setValue(message.role.rawValue, forKey: "role")
            managedMessage.setValue(message.text, forKey: "text")
            managedMessage.setValue(index, forKey: "position")
            managedMessage.setValue(stored, forKey: "conversation")
        }

        try saveContext()
    }

    func deleteConversation(id: UUID) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id.uuidString)
        if let row = try viewContext.fetch(request).first {
            viewContext.delete(row)
            try saveContext()
        }
    }

    func deleteAllConversations() throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "StoredConversation")
        try viewContext.fetch(request).forEach(viewContext.delete)
        try saveContext()
    }

    private func convert(_ object: NSManagedObject) -> Conversation? {
        guard
            let idValue = object.value(forKey: "id") as? String,
            let uuid = UUID(uuidString: idValue),
            let title = object.value(forKey: "title") as? String,
            let updatedAt = object.value(forKey: "updatedAt") as? Date,
            let rawMessages = object.value(forKey: "messages") as? Set<NSManagedObject>
        else { return nil }

        let messages = rawMessages.compactMap { messageObject -> (Int, ChatMessage)? in
            guard
                let rawId = messageObject.value(forKey: "messageID") as? String,
                let messageID = UUID(uuidString: rawId),
                let roleValue = messageObject.value(forKey: "role") as? String,
                let role = ChatMessage.Role(rawValue: roleValue),
                let text = messageObject.value(forKey: "text") as? String
            else { return nil }

            var message = ChatMessage(role: role, text: text)
            message.id = messageID
            let position = (messageObject.value(forKey: "position") as? NSNumber)?.intValue ?? 0
            return (position, message)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)

        return Conversation(id: uuid, title: title, updatedAt: updatedAt, messages: messages)
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

    static func integerAttribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = false
        attribute.defaultValue = 0
        return attribute
    }
}
