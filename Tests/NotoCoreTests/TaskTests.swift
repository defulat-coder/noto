import XCTest
import GRDB
@testable import NotoCore

final class TaskTests: XCTestCase {
    func testMigrationFromV4() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = try DatabaseQueue(path: url.path)
        try legacy.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1'), ('v2_history_index'), ('v3_conversations'), ('v4_execution');
                CREATE TABLE entries (id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, due TEXT,
                  completed BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, hasConversation BOOLEAN NOT NULL DEFAULT 0);
                CREATE TABLE requests (key TEXT PRIMARY KEY, entryID TEXT NOT NULL);
                CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, entryID TEXT, role TEXT, text TEXT, createdAt DATETIME, execution TEXT);
                INSERT INTO entries (id, kind, text, completed, createdAt, updatedAt) VALUES
                  ('n', 'note', '旧笔记', 0, '2026-09-01 12:00:00', '2026-09-02 12:00:00'),
                  ('p', 'todo', '旧待办', 0, '2026-09-01 12:00:00', '2026-09-02 12:00:00'),
                  ('c', 'todo', '旧完成', 1, '2026-09-01 12:00:00', '2026-09-02 12:00:00');
                """)
        }
        let store = try Store(url: url)
        let entries = try store.list()
        let done = try XCTUnwrap(entries.first { $0.id == "c" })
        XCTAssertEqual(done.status, "completed"); XCTAssertEqual(done.completedAt, done.updatedAt)
        XCTAssertEqual(entries.first { $0.id == "p" }?.status, "pending")
        XCTAssertNil(entries.first { $0.id == "n" }?.priority)
        XCTAssertEqual(try store.todos().map(\.priority), ["normal", "normal"])
        XCTAssertEqual(try Store(url: url).list(), entries)
    }

    func testTransitionsPreserveCompletionTimeAndPartialFields() throws {
        let store = try Store(url: nil)
        let todo = try store.add(kind: "todo", text: "开始", due: "2026-09-10", priority: "important")
        let started = try store.updateTodo(id: todo.id, status: "in_progress", expected: todo)
        XCTAssertFalse(started.completed); XCTAssertNil(started.completedAt)
        let done = try store.setCompleted(id: todo.id, completed: true)
        XCTAssertNotNil(done.completedAt); XCTAssertEqual(done.status, "completed")
        XCTAssertEqual(try store.setCompleted(id: todo.id, completed: true), done)
        let edited = try store.updateTodo(id: todo.id, text: "改文字")
        XCTAssertEqual(edited.completedAt, done.completedAt)
        XCTAssertEqual(edited.due, todo.due); XCTAssertEqual(edited.priority, "important")
        let reopened = try store.setCompleted(id: todo.id, completed: false)
        XCTAssertEqual(reopened.status, "pending"); XCTAssertNil(reopened.completedAt)
        XCTAssertThrowsError(try store.updateTodo(id: todo.id, priority: "high"))
        XCTAssertThrowsError(try store.updateTodo(id: todo.id, status: "unknown"))
        XCTAssertThrowsError(try store.updateTodo(id: todo.id, due: "2026-09-11", clearDue: true))
        XCTAssertEqual(try store.todos().first, reopened)
        XCTAssertNil(try store.updateTodo(id: todo.id, clearDue: true).due)
    }

    func testConversionAIAtomicityAndUndo() throws {
        let store = try Store(url: nil)
        let note = try store.startConversation("保留完整对话")
        let question = try XCTUnwrap(store.messages(for: note.id).last)
        _ = try store.apply([], replyingTo: question, reply: "历史回答")
        let history = try store.messages(for: note.id)
        let todo = try store.convertToTodo(id: note.id, expected: note)
        XCTAssertEqual(todo.id, note.id); XCTAssertEqual(todo.createdAt, note.createdAt)
        XCTAssertEqual(todo.priority, "normal"); XCTAssertEqual(todo.status, "pending")
        XCTAssertEqual(try store.messages(for: note.id), history)
        XCTAssertEqual(try store.convertToTodo(id: note.id), todo)
        try store.undo(before: [note], after: [todo])
        XCTAssertEqual(try store.list().first, note)
        XCTAssertThrowsError(try store.apply([AIAction(operation: "convert_to_todo", id: note.id), AIAction(operation: "update", id: note.id, priority: "bad")]))
        XCTAssertEqual(try store.list().first, note)
        let converted = try XCTUnwrap(store.apply([AIAction(operation: "convert_to_todo", id: note.id, status: "in_progress", priority: "important")], expected: [note]).first)
        XCTAssertEqual(converted.status, "in_progress")
        XCTAssertEqual(try store.todos(search: "历史回答", priority: "important").map(\.id), [note.id])
        let done = try XCTUnwrap(store.apply([AIAction(operation: "update", id: note.id, status: "completed")]).first)
        XCTAssertTrue(done.completed); XCTAssertEqual(done.priority, "important")
        XCTAssertThrowsError(try store.apply([AIAction(operation: "add_note", text: "非法任务属性", status: "pending")]))
    }

    func testQueryBeyondTimelineAndOrderAndIdempotency() throws {
        let store = try Store(url: nil)
        let oldest = try store.add(kind: "todo", text: "重要旧任务", priority: "important")
        let due = try store.add(kind: "todo", text: "重要有日期", due: "2026-09-12", priority: "important")
        let normal = try store.add(kind: "todo", text: "普通有日期", due: "2026-09-01")
        for i in 0..<45 { _ = try store.add(kind: "note", text: "笔记 \(i)") }
        XCTAssertFalse(try store.page().entries.contains { $0.id == oldest.id })
        XCTAssertEqual(try store.todos().map(\.id), [due.id, oldest.id, normal.id])
        _ = try store.updateTodo(id: normal.id, status: "in_progress")
        XCTAssertEqual(try store.todos(status: "open").count, 3)
        XCTAssertEqual(try store.todos(status: "in_progress").map(\.id), [normal.id])
        XCTAssertEqual(try store.todos(search: "旧", priority: "important").map(\.id), [oldest.id])
        let first = try store.add(kind: "todo", text: "幂等", requestID: "one", status: "in_progress", priority: "important")
        XCTAssertEqual(try store.add(kind: "todo", text: "幂等", requestID: "one", status: "in_progress", priority: "important").id, first.id)
        XCTAssertThrowsError(try store.add(kind: "todo", text: "幂等", requestID: "one", status: "pending", priority: "important"))
        XCTAssertThrowsError(try store.add(kind: "todo", text: "幂等", requestID: "one", status: "in_progress", priority: "normal"))
    }
}
