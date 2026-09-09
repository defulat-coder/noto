import XCTest
import GRDB
@testable import NotoCore

final class StoreTests: XCTestCase {
    func testConversationPersistsSearchesAndCommitsAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        let note = try store.startConversation("怎样整理想法？")
        let first = try XCTUnwrap(store.messages(for: note.id).last)
        try store.setExecution("已启动 CLI\n已读取上下文", for: first)
        XCTAssertThrowsError(try store.apply([AIAction(operation: "complete", id: "missing")], replyingTo: first, reply: "不应保存"))
        XCTAssertEqual(try store.messages(for: note.id).count, 1)
        _ = try store.apply([], replyingTo: first, reply: "可以使用双向链接，把零散思考串起来。")
        XCTAssertThrowsError(try store.apply([], replyingTo: first, reply: "重复回复"))
        try store.appendQuestion("具体怎么做？", to: note.id)
        let second = try XCTUnwrap(store.messages(for: note.id).last)
        _ = try store.apply([], replyingTo: second, reply: "从一个主题开始。")
        let reopened = try Store(url: url)
        XCTAssertEqual(try reopened.list().count, 1)
        XCTAssertEqual(try reopened.list().first?.text, "怎样整理想法？")
        XCTAssertEqual(try reopened.page(search: "双向链接").entries.map(\.id), [note.id])
        XCTAssertEqual(try reopened.page(search: "具体怎么做").entries.map(\.id), [note.id])
        XCTAssertEqual(try reopened.messages(for: note.id).map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(try reopened.messages(for: note.id).first?.execution, "已启动 CLI\n已读取上下文")
        XCTAssertThrowsError(try reopened.appendQuestion("", to: note.id))
    }

    func testHistoryPaginationDoesNotSkipOrRepeatAfterNewInsertion() throws {
        let store = try Store(url: nil)
        for i in 0..<105 { _ = try store.add(kind: "note", text: "历史 \(i)") }
        let expected = try store.list().map(\.id)
        let first = try store.page()
        XCTAssertEqual(first.entries.count, 40)
        XCTAssertTrue(first.hasMore)
        let inserted = try store.add(kind: "todo", text: "新插入的记录")
        var loaded = first.entries
        var page = first
        while page.hasMore {
            page = try store.page(before: loaded.last)
            loaded += page.entries
        }
        XCTAssertEqual(loaded.map(\.id), expected)
        XCTAssertEqual(Set(loaded.map(\.id)).count, 105)
        XCTAssertFalse(loaded.contains(where: { $0.id == inserted.id }))
        let search = try store.page(limit: 2, search: "历史 1")
        XCTAssertEqual(search.entries.count, 2)
        XCTAssertTrue(search.hasMore)
        XCTAssertEqual(try store.page(search: "%").entries.count, 0)
        XCTAssertThrowsError(try store.page(limit: 0))
    }

    func testAtomicActionsIdempotencyAndUndoConflict() throws {
        let store = try Store(url: nil)
        let note = try store.add(kind: "note", text: "小记", requestID: "one")
        XCTAssertEqual(try store.add(kind: "note", text: "小记", requestID: "one").id, note.id)
        XCTAssertThrowsError(try store.add(kind: "note", text: "其他内容", requestID: "one"))
        XCTAssertThrowsError(try store.apply([AIAction(operation: "add_todo", text: "不应留下"), AIAction(operation: "complete", id: "missing")]))
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertThrowsError(try store.add(kind: "todo", text: "日期错误", due: "2026-02-30"))
        let before = try store.list()
        let changed = try store.apply([AIAction(operation: "add_todo", text: "整理草图", due: "2026-09-09")])
        try store.undo(before: before, after: changed)
        XCTAssertEqual(try store.list().count, 1)
        let todo = try store.add(kind: "todo", text: "原始内容")
        _ = try store.update(id: todo.id, text: "由其他进程修改", due: nil)
        XCTAssertThrowsError(try store.undo(before: [], after: [todo]))
        XCTAssertEqual(try store.list().first(where: { $0.id == todo.id })?.text, "由其他进程修改")
    }

    func testSharedDatabaseAndAgentParsing() throws {
        XCTAssertEqual(try AgentRunner.decodeConversation("自然语言回复").message, "自然语言回复")
        XCTAssertTrue(try AgentRunner.decodeConversation("自然语言回复").actions.isEmpty)
        XCTAssertThrowsError(try AgentRunner.decodeConversation("{\"actions\":broken}"))
        XCTAssertThrowsError(try AgentRunner.decodeConversation(""))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.sqlite")
        let gui = try Store(url: url), cli = try Store(url: url)
        let todo = try cli.add(kind: "todo", text: "外部写入")
        XCTAssertEqual(try gui.list().first?.id, todo.id)
        _ = try cli.setCompleted(id: todo.id, completed: true)
        XCTAssertTrue(try XCTUnwrap(gui.list().first).completed)
        XCTAssertThrowsError(try AgentRunner.decode("I have updated it"))
        let response = try AgentRunner.decode("```json\n{\"message\":\"已记下\",\"actions\":[]}\n```")
        XCTAssertEqual(response.actions.count, 0)
    }
    func testFilteredNotesAtomicUpdateAndSnapshotBackup() throws {
        let store = try Store(url: nil)
        let note = try store.startConversation("原问题")
        let question = try XCTUnwrap(store.messages(for: note.id).first)
        _ = try store.apply([], replyingTo: question, reply: "回答")
        let task = try store.add(kind: "todo", text: "任务")
        XCTAssertEqual(try store.list(kind: "note").map(\.id), [note.id])
        XCTAssertThrowsError(try store.updateNote(id: task.id, text: "不能修改任务"))
        XCTAssertThrowsError(try store.updateNote(id: "missing", text: "不存在"))
        let changed = try store.updateNote(id: note.id, text: "新标题")
        XCTAssertTrue(changed.hasConversation)
        let backup = try store.backup()
        XCTAssertEqual(backup.entries, try store.list())
        XCTAssertEqual(backup.conversations[note.id], try store.messages(for: note.id))
        XCTAssertEqual(backup.conversations.count, 1)
    }

    func testAgentCancellationStopsCLIThatIgnoresTerminate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cli")
        let ready = directory.appendingPathComponent("ready")
        try "#!/bin/sh\ntrap '' TERM\ntouch '\(ready.path)'\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = AgentRunner()
        let running = Task.detached { try runner.run(prompt: "test", entries: [], provider: .claude, executable: executable.path) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let start = Date()
        runner.cancel()
        do { _ = try await running.value; XCTFail("Cancelled CLI must not produce a response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("取消")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testDesktopLockWaitIsBoundedAndDoesNotLoseData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.sqlite")
        let store = try Store(url: url, busyTimeout: 0.1)
        let blocker = try DatabaseQueue(path: url.path)
        try blocker.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
            defer { try? db.execute(sql: "ROLLBACK") }
            let start = Date()
            XCTAssertThrowsError(try store.add(kind: "note", text: "待重试草稿"))
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
        XCTAssertTrue(try store.list().isEmpty)
        _ = try store.add(kind: "note", text: "待重试草稿")
        XCTAssertEqual(try store.list().count, 1)
    }

    func testPooledReadersKeepExternalChangeDetectionStable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.sqlite")
        let store = try Store(url: url), external = try Store(url: url)
        let version = try store.dataVersion()
        _ = try store.add(kind: "note", text: "本地写入")
        for _ in 0..<10 {
            _ = try store.page(); _ = try store.todos()
            XCTAssertEqual(try store.dataVersion(), version)
        }
        _ = try external.add(kind: "note", text: "外部写入")
        XCTAssertNotEqual(try store.dataVersion(), version)
        XCTAssertEqual(try store.page().entries.count, 2)
    }

}
