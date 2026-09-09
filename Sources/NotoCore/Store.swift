import Foundation
import GRDB

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

public final class Store: @unchecked Sendable {
    let db: any DatabaseWriter
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["NOTO_DATABASE"] { return URL(fileURLWithPath: path) }
        let pointer = localURL.deletingLastPathComponent().appendingPathComponent("active-account.json")
        if let data = try? Data(contentsOf: pointer), let path = try? JSONDecoder().decode(String.self, from: data) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let root = localURL.deletingLastPathComponent().appendingPathComponent("accounts").standardizedFileURL.path + "/"
            if url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return localURL
    }

    public init(url: URL? = Store.defaultURL, busyTimeout: TimeInterval = 5) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var config = Configuration()
            config.busyMode = .timeout(busyTimeout)
            db = try DatabasePool(path: url.path, configuration: config)
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
        migrator.registerMigration("v5_task_board") { db in
            try db.alter(table: "entries") { t in
                t.add(column: "status", .text)
                t.add(column: "priority", .text)
                t.add(column: "completedAt", .datetime)
            }
            try db.execute(sql: "UPDATE entries SET status = CASE WHEN completed THEN 'completed' ELSE 'pending' END, priority = 'normal', completedAt = CASE WHEN completed THEN updatedAt ELSE NULL END WHERE kind = 'todo'")
            try db.execute(sql: "CREATE INDEX entries_tasks ON entries(kind, status, priority, due)")
        }
        Self.registerSyncMigration(&migrator)
        try migrator.migrate(db)
    }

    public func list(kind: String? = nil) throws -> [Entry] {
        try db.read { db in
            var query = Entry.all()
            if let kind { query = query.filter(Column("kind") == kind) }
            return try query.order(Column("createdAt").desc, Column("id")).fetchAll(db)
        }
    }

    public struct Backup: Encodable {
        public let entries: [Entry]
        public let conversations: [String: [ChatMessage]]
    }

    /// Both tables come from one snapshot, with two queries regardless of conversation count.
    public func backup() throws -> Backup {
        try db.read { db in
            let entries = try Entry.order(Column("createdAt").desc, Column("id")).fetchAll(db)
            let messages = try ChatMessage.order(Column("id")).fetchAll(db)
            var conversations = Dictionary(grouping: messages, by: \.entryID)
            for entry in entries where entry.hasConversation && conversations[entry.id] == nil {
                conversations[entry.id] = []
            }
            return Backup(entries: entries, conversations: conversations)
        }
    }

    public func updateNote(id: String, text: String) throws -> Entry {
        try change(id: id, text: text, noteOnly: true)
    }

    /// Independent of the timeline's 40-row window; searches full task conversations.
    // ponytail: fetch matching tasks for column counts; move completed paging into SQL if large archives slow refresh.
    public func todos(search: String = "", status: String = "all", priority: String? = nil) throws -> [Entry] {
        guard ["all", "open"].contains(status) || TodoStatus(rawValue: status) != nil else { throw NotoError("任务状态无效。") }
        if let priority, TodoPriority(rawValue: priority) == nil { throw NotoError("任务优先级无效。") }
        return try db.read { db in
            var query = Entry.filter(Column("kind") == "todo")
            if status == "open" { query = query.filter(Column("status") != "completed") }
            else if status != "all" { query = query.filter(Column("status") == status) }
            if let priority { query = query.filter(Column("priority") == priority) }
            if !search.isEmpty {
                query = query.filter(sql: "instr(lower(entries.text), lower(?)) > 0 OR instr(COALESCE(due, ''), ?) > 0 OR EXISTS (SELECT 1 FROM messages WHERE messages.entryID = entries.id AND instr(lower(messages.text), lower(?)) > 0)", arguments: [search, search, search])
            }
            return try query.order(sql: "CASE status WHEN 'pending' THEN 0 WHEN 'in_progress' THEN 1 ELSE 2 END, CASE WHEN status = 'completed' THEN completedAt END DESC, CASE WHEN status != 'completed' THEN priority = 'important' END DESC, CASE WHEN status != 'completed' THEN due IS NULL END ASC, CASE WHEN status != 'completed' THEN due END ASC, createdAt DESC, id ASC").fetchAll(db)
        }
    }

    public struct Page: Sendable {
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
        // data_version is connection-local: always use the writer, never a pooled reader.
        try db.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA data_version") ?? 0 }
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

    public func add(kind: String, text: String, due: String? = nil, requestID: String? = nil, status: String? = nil, priority: String? = nil) throws -> Entry {
        let entry = Entry(kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), due: due, status: status, priority: priority)
        try Self.validate(entry)
        return try db.write { db in
            if let requestID,
               let id = try String.fetchOne(db, sql: "SELECT entryID FROM requests WHERE key = ?", arguments: [requestID]),
               let existing = try Entry.fetchOne(db, key: id) {
                guard existing.kind == entry.kind, existing.text == entry.text, existing.due == entry.due, existing.status == entry.status, existing.priority == entry.priority else {
                    throw NotoError("相同 request-id 已用于不同内容。")
                }
                return existing
            }
            try entry.insert(db)
            if let requestID { try db.execute(sql: "INSERT INTO requests (key, entryID) VALUES (?, ?)", arguments: [requestID, entry.id]) }
            return try Entry.fetchOne(db, key: entry.id)!
        }
    }

    public func setCompleted(id: String, completed: Bool, expected: Entry? = nil) throws -> Entry {
        try updateTodo(id: id, status: completed ? "completed" : "pending", expected: expected)
    }

    public func update(id: String, text: String, due: String?, expected: Entry? = nil) throws -> Entry {
        try change(id: id, text: text, due: due, clearDue: due == nil, expected: expected)
    }

    public func updateTodo(id: String, text: String? = nil, due: String? = nil, clearDue: Bool = false,
                           status: String? = nil, priority: String? = nil, expected: Entry? = nil) throws -> Entry {
        try change(id: id, text: text, due: due, clearDue: clearDue, status: status, priority: priority, todoOnly: true, expected: expected)
    }

    public func convertToTodo(id: String, expected: Entry? = nil) throws -> Entry {
        try change(id: id, convert: true, expected: expected)
    }

    private func change(id: String, text: String? = nil, due: String? = nil, clearDue: Bool = false,
                        status: String? = nil, priority: String? = nil, todoOnly: Bool = false,
                        convert: Bool = false, noteOnly: Bool = false, expected: Entry? = nil) throws -> Entry {
        try db.write { db in
            guard var entry = try Entry.fetchOne(db, key: id), !todoOnly || entry.kind == "todo" else { throw NotoError("记录不存在或不是任务。") }
            if noteOnly && entry.kind != "note" { throw NotoError("笔记不存在。") }
            if let expected, expected != entry { throw NotoError("这条记录已在其他地方修改。草稿已保留，请取消后重新打开记录。") }
            try Self.modify(&entry, text: text, due: due, clearDue: clearDue, status: status, priority: priority, convert: convert)
            try entry.update(db)
            return try Entry.fetchOne(db, key: entry.id)!
        }
    }

    private static func modify(_ entry: inout Entry, text: String? = nil, due: String? = nil, clearDue: Bool = false,
                               status: String? = nil, priority: String? = nil, convert: Bool = false) throws {
        let before = entry
        if convert && entry.kind == "note" { entry.kind = "todo"; entry.status = "pending"; entry.priority = "normal" }
        if let text { entry.text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if clearDue && due != nil { throw NotoError("不能同时设置和清除截止日期。") }
        if clearDue { entry.due = nil } else if let due { entry.due = due }
        if let status {
            if status != entry.status { entry.completedAt = status == "completed" ? Date() : nil }
            entry.status = status
        }
        if let priority { entry.priority = priority }
        entry.completed = entry.status == "completed"
        try validate(entry)
        if entry != before { entry.updatedAt = Date() }
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
                let originals = Dictionary(expected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for action in actions where action.id != nil {
                    let id = action.id!
                    guard originals[id] == (try Entry.fetchOne(db, key: id)) else {
                        throw NotoError("相关记录刚刚被修改，请重新提交这次操作。")
                    }
                }
            }
            var result: [Entry] = []
            for action in actions {
                switch action.operation {
                case "add_note", "add_todo":
                    let entry = Entry(kind: action.operation == "add_note" ? "note" : "todo", text: (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), due: action.due, status: action.status, priority: action.priority)
                    try Self.validate(entry); try entry.insert(db); result.append(entry)
                case "complete", "reopen", "update", "convert_to_todo":
                    guard let id = action.id, var entry = try Entry.fetchOne(db, key: id) else { throw NotoError("AI 引用的记录不存在，未做任何修改。") }
                    if ["complete", "reopen"].contains(action.operation) {
                        guard entry.kind == "todo" else { throw NotoError("只能完成或重新打开待办。") }
                        try Self.modify(&entry, status: action.operation == "complete" ? "completed" : "pending")
                    } else {
                        try Self.modify(&entry, text: action.text, due: action.due, clearDue: action.clearDue ?? false,
                                        status: action.status, priority: action.priority, convert: action.operation == "convert_to_todo")
                    }
                    try entry.update(db); result.append(entry)
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
            let originals = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for changed in after {
                if let original = originals[changed.id] { try original.update(db) }
                else { _ = try Entry.deleteOne(db, key: changed.id) }
            }
        }
    }

    static func validate(_ entry: Entry) throws {
        let length = entry.kind == "todo" ? entry.text.unicodeScalars.count : entry.text.count
        guard ["note", "todo"].contains(entry.kind), !entry.text.isEmpty, length <= 50_000 else {
            throw NotoError("内容不能为空，且不能超过 50,000 字。")
        }
        if entry.kind == "todo" {
            guard let status = entry.status, TodoStatus(rawValue: status) != nil,
                  let priority = entry.priority, TodoPriority(rawValue: priority) != nil,
                  entry.completed == (status == "completed"), (entry.completedAt != nil) == entry.completed else {
                throw NotoError("任务状态或优先级无效。")
            }
        } else if entry.status != nil || entry.priority != nil || entry.completedAt != nil || entry.completed {
            throw NotoError("只有任务可以设置状态和优先级。")
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
