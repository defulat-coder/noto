import Foundation
import GRDB

// 数据模型：App 与 CLI 共享的持久化类型。业务与落库逻辑在 Store.swift / SyncStore.swift。

public enum TodoStatus: String, Codable, CaseIterable, Sendable {
    case pending, inProgress = "in_progress", completed
    public var label: String {
        switch self { case .pending: "待开始"; case .inProgress: "进行中"; case .completed: "已完成" }
    }
}

public enum TodoPriority: String, Codable, CaseIterable, Sendable {
    case normal, important
}

public struct Entry: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "entries"
    public var id: String
    public var kind: String
    public var text: String
    public var due: String?
    public var completed: Bool
    public var status: String?
    public var priority: String?
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var hasConversation: Bool = false

    public init(id: String = UUID().uuidString.lowercased(), kind: String, text: String, due: String? = nil, completed: Bool = false, createdAt: Date = Date(), status: String? = nil, priority: String? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.due = due
        self.status = kind == "todo" ? (status ?? (completed ? "completed" : "pending")) : status
        self.priority = kind == "todo" ? (priority ?? "normal") : priority
        self.completed = self.status == "completed"
        self.completedAt = self.completed ? createdAt : nil
        self.createdAt = createdAt; self.updatedAt = createdAt
    }
}

public struct ChatMessage: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "messages"
    public var id: Int64?
    public var entryID: String
    public var role: String
    public var text: String
    public var createdAt: Date = Date()
    public var execution: String? = nil
}

public struct NotoError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AIAction: Codable, Sendable {
    public var operation: String
    public var id: String?
    public var text: String?
    public var due: String?
    public var status: String?
    public var priority: String?
    public var clearDue: Bool?
    public init(operation: String, id: String? = nil, text: String? = nil, due: String? = nil, status: String? = nil, priority: String? = nil, clearDue: Bool? = nil) {
        self.status = status; self.priority = priority; self.clearDue = clearDue
        self.operation = operation; self.id = id; self.text = text; self.due = due
    }
}

public struct AIResponse: Codable, Sendable {
    public var message: String
    public var actions: [AIAction]
}
