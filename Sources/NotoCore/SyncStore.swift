import Foundation
import CryptoKit
import GRDB

// 同步的本地落库层：outbox、ack、远端任务应用、冲突归档都持久化在这里（NotoCore），
// 网络传输（RPC 上传、PowerSync 下载）在 NotoSync。CLI 不依赖 NotoSync 也能读写同一套库。

public struct SyncMutation: Codable, FetchableRecord, Sendable {
    public let mutationID: String
    public let entryID: String
    public let operation: String
    public let document: String
    public let baseDocument: String?
}

public struct SyncConflict: Identifiable, Codable, FetchableRecord, Sendable {
    public let id: String
    public let taskID: String
    public let document: String
    public let reason: String
    public var text: String { (try? Store.decodeSyncEntry(document).text) ?? document }
}

extension Store {
    public static var localURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noto/notes.sqlite")
    }

    static func registerSyncMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6_sync_outbox") { db in
            try db.execute(sql: """
                CREATE TABLE noto_sync_state (id INTEGER PRIMARY KEY CHECK(id=1), account_id TEXT, suppress INTEGER NOT NULL DEFAULT 0);
                INSERT INTO noto_sync_state(id) VALUES(1);
                CREATE TABLE noto_sync_metadata (entry_id TEXT PRIMARY KEY, document TEXT NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL);
                CREATE TABLE noto_outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, mutationID TEXT NOT NULL UNIQUE, entryID TEXT NOT NULL, operation TEXT NOT NULL, document TEXT NOT NULL, baseDocument TEXT);
                CREATE INDEX noto_outbox_entry ON noto_outbox(entryID,seq);
                CREATE TABLE noto_conflicts (id TEXT PRIMARY KEY, taskID TEXT NOT NULL, document TEXT NOT NULL, reason TEXT NOT NULL);
                CREATE TABLE noto_deleted_entries (id TEXT PRIMARY KEY, document TEXT NOT NULL);
                """)
            let uuid = "lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(6)))"
            for (event, row, operation) in [("INSERT", "NEW", "upsert"), ("UPDATE", "NEW", "upsert"), ("DELETE", "OLD", "delete")] {
                let document = event == "UPDATE" ? "CASE WHEN NEW.kind='todo' THEN \(syncDocumentSQL("NEW")) ELSE \(syncDocumentSQL("OLD")) END" : syncDocumentSQL(row)
                let condition = event == "UPDATE" ? "(NEW.kind='todo' OR OLD.kind='todo')" : "\(row).kind='todo'"
                let action = event == "UPDATE" ? "CASE WHEN NEW.kind='todo' THEN 'upsert' ELSE 'delete' END" : "'\(operation)'"
                let changed = event == "UPDATE" ? " AND (NEW.text != OLD.text OR NEW.due IS NOT OLD.due OR NEW.status IS NOT OLD.status OR NEW.priority IS NOT OLD.priority OR NEW.completed != OLD.completed OR NEW.kind != OLD.kind)" : ""
                try db.execute(sql: """
                    CREATE TRIGGER noto_track_\(event.lowercased()) AFTER \(event) ON entries
                    WHEN \(condition) AND (SELECT account_id IS NOT NULL AND suppress=0 FROM noto_sync_state WHERE id=1)\(changed)
                    BEGIN
                        INSERT INTO noto_outbox(mutationID,entryID,operation,document,baseDocument)
                        VALUES(\(uuid),\(row).id,\(action),\(document),
                          COALESCE((SELECT document FROM noto_outbox WHERE entryID=\(row).id ORDER BY seq DESC LIMIT 1),
                                   (SELECT document FROM noto_sync_metadata WHERE entry_id=\(row).id)));
                    END;
                    """)
            }
        }
        migrator.registerMigration("v7_deleted_conversations") { db in
            try db.execute(sql: "ALTER TABLE noto_deleted_entries ADD COLUMN messages BLOB")
        }
        migrator.registerMigration("v8_reconversion_restore") { db in
            let uuid = "lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(2))||'-'||hex(randomblob(6)))"
            // Converting a note again is an explicit restore, unlike an old
            // device's ordinary edit, which must never resurrect a deleted task.
            try db.execute(sql: """
                DROP TRIGGER noto_track_update;
                CREATE TRIGGER noto_track_update AFTER UPDATE ON entries
                WHEN (NEW.kind='todo' OR OLD.kind='todo')
                  AND (SELECT account_id IS NOT NULL AND suppress=0 FROM noto_sync_state WHERE id=1)
                  AND (NEW.text != OLD.text OR NEW.due IS NOT OLD.due OR NEW.status IS NOT OLD.status
                    OR NEW.priority IS NOT OLD.priority OR NEW.completed != OLD.completed OR NEW.kind != OLD.kind)
                BEGIN
                    INSERT INTO noto_outbox(mutationID,entryID,operation,document,baseDocument)
                    VALUES(\(uuid),NEW.id,
                      CASE WHEN NEW.kind!='todo' THEN 'delete'
                        WHEN OLD.kind='note' AND (
                          COALESCE((SELECT operation='delete' FROM noto_outbox WHERE entryID=NEW.id ORDER BY seq DESC LIMIT 1),0)
                          OR COALESCE((SELECT deleted FROM noto_sync_metadata WHERE entry_id=NEW.id),0)
                        ) THEN 'restore'
                        ELSE 'upsert' END,
                      CASE WHEN NEW.kind='todo' THEN \(syncDocumentSQL("NEW")) ELSE \(syncDocumentSQL("OLD")) END,
                      COALESCE((SELECT document FROM noto_outbox WHERE entryID=NEW.id ORDER BY seq DESC LIMIT 1),
                               (SELECT document FROM noto_sync_metadata WHERE entry_id=NEW.id)));
                END;
                """)
        }
    }

    private static func archiveDeletedTask(_ db: Database, id: String, document: String) throws {
        let messages = try ChatMessage.filter(Column("entryID") == id).order(Column("id")).fetchAll(db)
        try db.execute(sql: "INSERT OR REPLACE INTO noto_deleted_entries(id,document,messages) VALUES(?,?,?)",
                       arguments: [id, document, try JSONEncoder().encode(messages)])
    }

    private static func syncDocumentSQL(_ row: String) -> String {
        """
        json_object('id',\(row).id,'kind',\(row).kind,'text',\(row).text,'due',\(row).due,
        'status',\(row).status,'priority',\(row).priority,'completed',json(CASE WHEN \(row).completed THEN 'true' ELSE 'false' END),
        'createdAt',strftime('%Y-%m-%dT%H:%M:%fZ',\(row).createdAt),'updatedAt',strftime('%Y-%m-%dT%H:%M:%fZ',\(row).updatedAt),
        'completedAt',strftime('%Y-%m-%dT%H:%M:%fZ',\(row).completedAt),'hasConversation',json('false'))
        """
    }

    public func enableSync(accountID: String) throws {
        guard UUID(uuidString: accountID) != nil else { throw NotoError("账号标识无效。") }
        try db.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT account_id FROM noto_sync_state WHERE id=1")
            guard existing == nil || existing == accountID else { throw NotoError("数据库属于另一个账号，不能混用。") }
            try db.execute(sql: "UPDATE noto_sync_state SET account_id=? WHERE id=1", arguments: [accountID])
        }
    }

    public func pendingMutations() throws -> [SyncMutation] {
        try db.read { try SyncMutation.fetchAll($0, sql: "SELECT * FROM noto_outbox ORDER BY seq LIMIT 100") }
    }
    public func pendingMutationCount() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM noto_outbox") ?? 0 }
    }
    public func syncConflicts() throws -> [SyncConflict] {
        try db.read { try SyncConflict.fetchAll($0, sql: "SELECT * FROM noto_conflicts ORDER BY id") }
    }

    /// The archive has no deletion timestamp; newest archive insertions appear first.
    public func deletedTodos() throws -> [Entry] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT document, messages FROM noto_deleted_entries
                WHERE NOT EXISTS (SELECT 1 FROM entries WHERE entries.id = noto_deleted_entries.id)
                ORDER BY rowid DESC
                """).map { row in
                    var entry = try Self.decodeSyncEntry(row["document"])
                    let messages: Data? = row["messages"]
                    let history = try messages.map { try JSONDecoder().decode([ChatMessage].self, from: $0) } ?? []
                    entry.hasConversation = !history.isEmpty
                    return entry
                }
        }
    }

    public func deleteTodo(id: String, expected: Entry? = nil) throws {
        try db.write { db in
            guard let entry = try Entry.fetchOne(db, key: id), entry.kind == "todo" else { throw NotoError("任务不存在。") }
            if let expected, expected != entry { throw NotoError("任务已修改，请刷新后重试。") }
            let document = try String.fetchOne(db, sql: "SELECT \(Self.syncDocumentSQL("entries")) FROM entries WHERE id=?", arguments: [id])!
            try Self.archiveDeletedTask(db, id: id, document: document)
            _ = try Entry.deleteOne(db, key: id)
        }
        AgentWorkspace.remove(database: storageURL, conversationID: id)
    }

    public func restoreTodo(id: String) throws {
        try db.write { db in
            guard try Entry.fetchOne(db, key: id) == nil,
                  let document = try String.fetchOne(db, sql: "SELECT document FROM noto_deleted_entries WHERE id=?", arguments: [id]) else { throw NotoError("没有可恢复的任务。") }
            var entry = try Self.decodeSyncEntry(document)
            let messagesData = try Data.fetchOne(db, sql: "SELECT messages FROM noto_deleted_entries WHERE id=?", arguments: [id])
            let messages = try messagesData.map { try JSONDecoder().decode([ChatMessage].self, from: $0) } ?? []
            entry.hasConversation = !messages.isEmpty
            try entry.insert(db)
            for message in messages { try message.insert(db) }
            try db.execute(sql: "UPDATE noto_outbox SET operation='restore' WHERE seq=(SELECT max(seq) FROM noto_outbox WHERE entryID=?)", arguments: [id])
            try db.execute(sql: "DELETE FROM noto_deleted_entries WHERE id=?", arguments: [id])
        }
    }

    public static func decodeSyncEntry(_ document: String) throws -> Entry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: string) else { throw NotoError("同步记录的日期无效。") }
            return date
        }
        let entry = try decoder.decode(Entry.self, from: Data(document.utf8))
        guard UUID(uuidString: entry.id) != nil, entry.kind == "todo" else { throw NotoError("同步记录不是有效任务。") }
        try validate(entry)
        return entry
    }

    /// Applied only after the backend durably acknowledges this exact queued mutation.
    public func acknowledgeMutation(_ mutation: SyncMutation, document: String, revision: Int64, deleted: Bool, outcome: String) throws {
        try db.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM noto_outbox WHERE mutationID=?)", arguments: [mutation.mutationID]) == true else { return }
            if outcome == "conflict" || (outcome == "deleted" && mutation.operation != "delete") {
                try db.execute(sql: "INSERT OR IGNORE INTO noto_conflicts(id,taskID,document,reason) VALUES(?,?,?,?)",
                               arguments: [mutation.mutationID, mutation.entryID, mutation.document, outcome == "deleted" ? "任务已在其他设备删除，本机修改已保留" : "同一内容在其他设备修改，本机版本已保留"])
            }
            try db.execute(sql: "DELETE FROM noto_outbox WHERE mutationID=?", arguments: [mutation.mutationID])
            try Self.applyRemote(db, id: mutation.entryID, document: document, revision: revision, deleted: deleted, acknowledging: true)
        }
    }

    public func applyRemoteTask(id: String, document: String, revision: Int64, deleted: Bool) throws {
        try db.write { try Self.applyRemote($0, id: id, document: document, revision: revision, deleted: deleted, acknowledging: false) }
        if deleted, try entry(id: id) == nil { AgentWorkspace.remove(database: storageURL, conversationID: id) }
    }

    /// One transaction per downloaded batch, rather than a disk commit for every task.
    public func applyRemoteTasks(_ tasks: [(id: String, document: String, revision: Int64, deleted: Bool)]) throws {
        guard !tasks.isEmpty else { return }
        try db.write { db in
            for task in tasks {
                try Self.applyRemote(db, id: task.id, document: task.document, revision: task.revision, deleted: task.deleted, acknowledging: false)
            }
        }
        for task in tasks where task.deleted {
            if try entry(id: task.id) == nil { AgentWorkspace.remove(database: storageURL, conversationID: task.id) }
        }
    }

    private static func applyRemote(_ db: Database, id: String, document: String, revision: Int64, deleted: Bool, acknowledging: Bool) throws {
        let floor = try Int64.fetchOne(db, sql: "SELECT revision FROM noto_sync_metadata WHERE entry_id=?", arguments: [id]) ?? 0
        guard revision >= floor, revision > 0, acknowledging || revision > floor else { return }
        let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM noto_outbox WHERE entryID=?)", arguments: [id]) ?? false
        if pending && !acknowledging { return }
        var entry = try decodeSyncEntry(document)
        guard entry.id == id else { throw NotoError("同步记录 ID 不匹配。") }
        try db.execute(sql: "INSERT INTO noto_sync_metadata(entry_id,document,revision,deleted) VALUES(?,?,?,?) ON CONFLICT(entry_id) DO UPDATE SET document=excluded.document,revision=excluded.revision,deleted=excluded.deleted",
                       arguments: [id, document, revision, deleted])
        guard !pending else { return }
        // Incoming records never produce outgoing mutations.
        try db.execute(sql: "UPDATE noto_sync_state SET suppress=1 WHERE id=1")
        defer { try? db.execute(sql: "UPDATE noto_sync_state SET suppress=0 WHERE id=1") }
        if deleted {
            if try Entry.fetchOne(db, key: id)?.kind == "todo" {
                try archiveDeletedTask(db, id: id, document: document)
                _ = try Entry.deleteOne(db, key: id)
            }
        } else {
            entry.hasConversation = try Entry.fetchOne(db, key: id)?.hasConversation ?? false
            if try Entry.fetchOne(db, key: id) != entry { try entry.save(db) }
        }
    }

    public func preserveRemoteConflict(id: String, taskID: String, document: String) throws {
        let entry = try Self.decodeSyncEntry(document)
        guard entry.id == taskID else { throw NotoError("冲突记录 ID 不匹配。") }
        try db.write { try $0.execute(sql: "INSERT OR IGNORE INTO noto_conflicts(id,taskID,document,reason) VALUES(?,?,?,?)", arguments: [id, taskID, document, "另一个设备的冲突版本"]) }
    }

    /// Resolve conservatively by keeping the preserved version as a new task.
    public func recoverConflict(id: String) throws {
        try db.write { db in
            guard let conflict = try SyncConflict.fetchOne(db, sql: "SELECT * FROM noto_conflicts WHERE id=?", arguments: [id]), conflict.reason != "已另存为新任务" else { return }
            var entry = try Self.decodeSyncEntry(conflict.document)
            entry.id = UUID().uuidString.lowercased(); entry.hasConversation = false
            entry.createdAt = Date(); entry.updatedAt = entry.createdAt
            try entry.insert(db)
            // Keep the conflict in history so downloaded conflict records do not appear as new again.
            try db.execute(sql: "UPDATE noto_conflicts SET reason='已另存为新任务' WHERE id=?", arguments: [id])
        }
    }

    public func importTasks(from source: Store) throws -> Int {
        let tasks = try source.todos()
        return try db.write { db in
            guard let account = try String.fetchOne(db, sql: "SELECT account_id FROM noto_sync_state WHERE id=1") else {
                throw NotoError("请先登录账号再导入本机任务。")
            }
            var count = 0
            for var entry in tasks {
                // The cloud task ID is global: importing the same local task into
                // another account must not collide with the first account.
                let hash = SHA256.hash(data: Data((account.lowercased() + ":" + entry.id.lowercased()).utf8))
                var hex = Array(hash.prefix(16).map { String(format: "%02x", $0) }.joined())
                hex[12] = "8"; hex[16] = "a"
                let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
                entry.id = groups.map { String(hex[$0]) }.joined(separator: "-")
                guard try Entry.fetchOne(db, key: entry.id) == nil,
                      try Int.fetchOne(db, sql: "SELECT 1 FROM noto_sync_metadata WHERE entry_id=?", arguments: [entry.id]) == nil,
                      try Int.fetchOne(db, sql: "SELECT 1 FROM noto_deleted_entries WHERE id=?", arguments: [entry.id]) == nil,
                      try Int.fetchOne(db, sql: "SELECT 1 FROM noto_outbox WHERE entryID=? LIMIT 1", arguments: [entry.id]) == nil else { continue }
                entry.hasConversation = false
                try Self.validate(entry)
                try entry.insert(db); count += 1
            }
            return count
        }
    }
}
