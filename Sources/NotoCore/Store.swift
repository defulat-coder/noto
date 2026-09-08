import Foundation
import GRDB

public struct Entry: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "entries"
    public var id: String
    public var kind: String
    public var text: String
    public var due: String?
    public var completed: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var hasConversation: Bool = false

    public init(id: String = UUID().uuidString.lowercased(), kind: String, text: String, due: String? = nil, completed: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.due = due
        self.completed = completed; self.createdAt = createdAt; self.updatedAt = createdAt
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

public final class Store: @unchecked Sendable {
    private let db: DatabaseQueue
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["NOTO_DATABASE"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noto/notes.sqlite")
    }

    public init(url: URL? = Store.defaultURL) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var config = Configuration()
            config.busyMode = .timeout(5)
            db = try DatabaseQueue(path: url.path, configuration: config)
            try db.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
        } else { db = try DatabaseQueue() }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "entries") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("due", .text)
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "requests") { t in
                t.column("key", .text).primaryKey()
                t.column("entryID", .text).notNull()
            }
        }
        migrator.registerMigration("v2_history_index") { db in
            try db.execute(sql: "CREATE INDEX entries_history ON entries(createdAt DESC, id ASC)")
        }
        migrator.registerMigration("v3_conversations") { db in
            try db.alter(table: "entries") { $0.add(column: "hasConversation", .boolean).notNull().defaults(to: false) }
            try db.create(table: "messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entryID", .text).notNull().references("entries", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.execute(sql: "CREATE INDEX messages_entry ON messages(entryID, id)")
        }
        migrator.registerMigration("v4_execution") { db in
            try db.alter(table: "messages") { $0.add(column: "execution", .text) }
        }
        try migrator.migrate(db)
    }

    public func list() throws -> [Entry] {
        try db.read { try Entry.order(Column("createdAt").desc, Column("id")).fetchAll($0) }
    }

    public struct Page {
        public let entries: [Entry]
        public let hasMore: Bool
    }

    /// Keyset pagination: tied timestamps are ordered by ID; new inserts do not shift older pages.
    public func page(before: Entry? = nil, limit: Int = 40, search: String = "") throws -> Page {
        guard limit > 0 else { throw NotoError("分页数量必须大于零。") }
        return try db.read { db in
            var query = Entry.all()
            if let before {
                query = query.filter(Column("createdAt") < before.createdAt || (Column("createdAt") == before.createdAt && Column("id") > before.id))
            }
            if !search.isEmpty {
                query = query.filter(sql: "instr(lower(entries.text), lower(?)) > 0 OR instr(COALESCE(due, ''), ?) > 0 OR EXISTS (SELECT 1 FROM messages WHERE messages.entryID = entries.id AND instr(lower(messages.text), lower(?)) > 0)", arguments: [search, search, search])
            }
            let rows = try query.order(Column("createdAt").desc, Column("id")).limit(limit + 1).fetchAll(db)
            return Page(entries: Array(rows.prefix(limit)), hasMore: rows.count > limit)
        }
    }

    /// Changes made by other connections; local writes explicitly refresh the UI.
    public func dataVersion() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "PRAGMA data_version") ?? 0 }
    }

    public func startConversation(_ question: String) throws -> Entry {
        var entry = Entry(kind: "note", text: question.trimmingCharacters(in: .whitespacesAndNewlines))
        entry.hasConversation = true
        try Self.validate(entry)
        return try db.write { db in
            try entry.insert(db)
            try ChatMessage(entryID: entry.id, role: "user", text: entry.text).insert(db)
            return try Entry.fetchOne(db, key: entry.id)!
        }
    }

    public func messages(for entryID: String) throws -> [ChatMessage] {
        try db.read { try ChatMessage.filter(Column("entryID") == entryID).order(Column("id")).fetchAll($0) }
    }

    public func setExecution(_ text: String, for question: ChatMessage) throws {
        guard let id = question.id else { throw NotoError("消息不存在。") }
        try db.write { db in
            try db.execute(sql: "UPDATE messages SET execution = ? WHERE id = ? AND entryID = ? AND role = 'user'", arguments: [text, id, question.entryID])
        }
    }

    public func appendQuestion(_ text: String, to entryID: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 50_000 else { throw NotoError("问题不能为空，且不能超过 50,000 字。") }
        try db.write { db in
            guard try Entry.fetchOne(db, key: entryID)?.hasConversation == true else { throw NotoError("对话不存在。") }
            try ChatMessage(entryID: entryID, role: "user", text: text).insert(db)
        }
    }

    public func add(kind: String, text: String, due: String? = nil, requestID: String? = nil) throws -> Entry {
        let entry = Entry(kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), due: due)
        try Self.validate(entry)
        return try db.write { db in
            if let requestID,
               let id = try String.fetchOne(db, sql: "SELECT entryID FROM requests WHERE key = ?", arguments: [requestID]),
               let existing = try Entry.fetchOne(db, key: id) {
                guard existing.kind == entry.kind, existing.text == entry.text, existing.due == entry.due else {
                    throw NotoError("相同 request-id 已用于不同内容。")
                }
                return existing
            }
            try entry.insert(db)
            if let requestID { try db.execute(sql: "INSERT INTO requests (key, entryID) VALUES (?, ?)", arguments: [requestID, entry.id]) }
            return try Entry.fetchOne(db, key: entry.id)!
        }
    }

    public func setCompleted(id: String, completed: Bool) throws -> Entry {
        try db.write { db in
            guard var entry = try Entry.fetchOne(db, key: id), entry.kind == "todo" else { throw NotoError("没有找到这条待办。") }
            entry.completed = completed; entry.updatedAt = Date()
            try entry.update(db)
            return try Entry.fetchOne(db, key: entry.id)!
        }
    }

    public func update(id: String, text: String, due: String?, expected: Entry? = nil) throws -> Entry {
        try db.write { db in
            guard var entry = try Entry.fetchOne(db, key: id) else { throw NotoError("记录不存在。") }
            if let expected, expected != entry { throw NotoError("这条记录已在其他地方修改。草稿已保留，请取消后重新打开记录。") }
            entry.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.due = due; entry.updatedAt = Date()
            try Self.validate(entry); try entry.update(db)
            return try Entry.fetchOne(db, key: entry.id)!
        }
    }

    public func apply(_ actions: [AIAction], expected: [Entry]? = nil, replyingTo: ChatMessage? = nil, reply: String? = nil) throws -> [Entry] {
        guard actions.count <= 30 else { throw NotoError("一次最多修改 30 条记录。") }
        return try db.write { db in
            if let question = replyingTo {
                let last = try ChatMessage.filter(Column("entryID") == question.entryID).order(Column("id").desc).fetchOne(db)
                guard last?.id == question.id, last?.text == question.text, question.role == "user", let reply, !reply.isEmpty, reply.count <= 50_000 else {
                    throw NotoError("对话已发生变化，或回复为空，请重新打开后重试。")
                }
            }
            if let expected {
                for action in actions where action.id != nil {
                    let id = action.id!
                    guard expected.first(where: { $0.id == id }) == (try Entry.fetchOne(db, key: id)) else {
                        throw NotoError("相关记录刚刚被修改，请重新提交这次操作。")
                    }
                }
            }
            var result: [Entry] = []
            for action in actions {
                switch action.operation {
                case "add_note", "add_todo":
                    let entry = Entry(kind: action.operation == "add_note" ? "note" : "todo", text: (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), due: action.due)
                    try Self.validate(entry); try entry.insert(db); result.append(entry)
                case "complete", "reopen", "update":
                    guard let id = action.id, var entry = try Entry.fetchOne(db, key: id) else { throw NotoError("AI 引用的记录不存在，未做任何修改。") }
                    if action.operation == "update" {
                        guard let text = action.text else { throw NotoError("修改缺少内容。") }
                        entry.text = text.trimmingCharacters(in: .whitespacesAndNewlines); entry.due = action.due
                    } else {
                        guard entry.kind == "todo" else { throw NotoError("只能完成或重新打开待办。") }
                        entry.completed = action.operation == "complete"
                    }
                    entry.updatedAt = Date(); try Self.validate(entry); try entry.update(db); result.append(entry)
                default: throw NotoError("AI 返回了不支持的操作，未做任何修改。")
                }
            }
            if let question = replyingTo, let reply {
                try ChatMessage(entryID: question.entryID, role: "assistant", text: reply).insert(db)
            }
            return try result.map { try Entry.fetchOne(db, key: $0.id)! }
        }
    }

    // Undo only this operation; don't overwrite concurrent CLI changes.
    public func undo(before: [Entry], after: [Entry]) throws {
        try db.write { db in
            for changed in after {
                guard try Entry.fetchOne(db, key: changed.id) == changed else { throw NotoError("记录已被其他操作修改，无法直接撤销。") }
            }
            for changed in after {
                if let original = before.first(where: { $0.id == changed.id }) { try original.update(db) }
                else { _ = try Entry.deleteOne(db, key: changed.id) }
            }
        }
    }

    static func validate(_ entry: Entry) throws {
        guard ["note", "todo"].contains(entry.kind), !entry.text.isEmpty, entry.text.count <= 50_000 else {
            throw NotoError("内容不能为空，且不能超过 50,000 字。")
        }
        if let due = entry.due {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard due.count == 10, let date = formatter.date(from: due), formatter.string(from: date) == due else {
                throw NotoError("日期请使用有效的 YYYY-MM-DD 格式。")
            }
            guard entry.kind == "todo" else { throw NotoError("只有待办可以设置日期。") }
        }
    }
}

public struct AIAction: Codable, Sendable {
    public var operation: String
    public var id: String?
    public var text: String?
    public var due: String?
    public init(operation: String, id: String? = nil, text: String? = nil, due: String? = nil) {
        self.operation = operation; self.id = id; self.text = text; self.due = due
    }
}

public struct AIResponse: Codable, Sendable {
    public var message: String
    public var actions: [AIAction]
}
