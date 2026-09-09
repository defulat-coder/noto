import XCTest
import AppKit
import NotoCore
@testable import NotoApp

final class InteractionTests: XCTestCase {
    func testNoteSubmissionSavesLocallyWhileAIIsBusy() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let model = AppModel(store: store)
            await model.waitForReload()
            model.showComposer(); model.draft = "先记下来"; model.busy = true
            model.submitFocusedInput()
            let entry = try XCTUnwrap(store.list().first)
            XCTAssertEqual(entry.text, "先记下来")
            XCTAssertEqual(entry.kind, "note")
            XCTAssertFalse(entry.hasConversation)
            XCTAssertTrue(model.draft.isEmpty)
        }.value
    }

    func testMarkedTextCannotSubmit() async {
        await Task { @MainActor in
            let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            var submitted = 0
            input.onSubmit = { submitted += 1 }
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(input.hasMarkedText())
            input.submit()
            XCTAssertEqual(submitted, 0)
            input.unmarkText(); input.submit()
            XCTAssertEqual(submitted, 1)
        }.value
    }
    func testDraftMovementAndDirtyEditProtection() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let first = try store.add(kind: "note", text: "原文")
            let other = try store.add(kind: "todo", text: "待办", due: "2026-09-09")
            let model = AppModel(store: store)
            await model.waitForReload()
            XCTAssertNil(model.composerPosition)
            model.showComposer(at: CGPoint(x: 90, y: 120)); model.draft = "未发送的草稿"
            model.composerPosition = nil
            model.showComposer(at: CGPoint(x: 300, y: 240))
            XCTAssertEqual(model.draft, "未发送的草稿")
            model.beginEditing(first); model.editDraft = "修改后的文字"
            model.showComposer(); model.beginEditing(other); model.setSearch("其他")
            await model.waitForReload()
            XCTAssertEqual(model.editing?.id, first.id)
            XCTAssertEqual(model.editDraft, "修改后的文字")
            XCTAssertNil(model.composerPosition)
            XCTAssertTrue(model.search.isEmpty)
            XCTAssertFalse(model.editError.isEmpty)
            model.cancelEditing(); model.showComposer(); model.save()
            XCTAssertNil(model.composerPosition)
            XCTAssertTrue(model.draft.isEmpty)
            XCTAssertEqual(try store.list().filter { $0.text == "未发送的草稿" }.count, 1)
            model.busy = true; model.showComposer(); model.draft = "AI 运行时的草稿"
            model.ask()
            XCTAssertEqual(model.draft, "AI 运行时的草稿")
            XCTAssertNotNil(model.composerPosition)
            XCTAssertNil(model.conversation)
        }.value
    }

    func testInlineEditPreservesConversationAndRejectsConcurrentChange() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let entry = try store.startConversation("原始问题")
            let question = try XCTUnwrap(store.messages(for: entry.id).first)
            _ = try store.apply([], replyingTo: question, reply: "原始回答")
            let history = try store.messages(for: entry.id)
            let model = AppModel(store: store)
            await model.waitForReload()
            model.beginEditing(entry); model.editDraft = "仅改列表文字"; model.saveEditing()
            await model.waitForReload()
            let changed = try XCTUnwrap(store.list().first)
            XCTAssertEqual(changed.id, entry.id)
            XCTAssertEqual(changed.createdAt, entry.createdAt)
            XCTAssertTrue(changed.hasConversation)
            XCTAssertEqual(try store.messages(for: entry.id), history)
            model.undo()
            await model.waitForReload()
            XCTAssertEqual(try store.list().first?.text, entry.text)
            let current = try XCTUnwrap(store.list().first)
            model.beginEditing(current); model.editDraft = "本地编辑中的草稿"
            _ = try store.update(id: entry.id, text: "来自其他进程", due: nil)
            model.saveEditing()
            await model.waitForReload()
            XCTAssertEqual(try store.list().first?.text, "来自其他进程")
            XCTAssertEqual(model.editDraft, "本地编辑中的草稿")
            XCTAssertNotNil(model.editing)
            XCTAssertFalse(model.editError.isEmpty)
        }.value
    }

    func testEmptyEditAndTodoMetadata() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let todo = try store.add(kind: "todo", text: "待办", due: "2026-09-09")
            let completed = try store.setCompleted(id: todo.id, completed: true)
            let model = AppModel(store: store)
            await model.waitForReload()
            model.beginEditing(completed); model.editDraft = " \n "; model.saveEditing()
            await model.waitForReload()
            XCTAssertNotNil(model.editing)
            XCTAssertEqual(try store.list().first?.text, "待办")
            model.editDraft = "已编辑待办"; model.saveEditing()
            await model.waitForReload()
            let result = try XCTUnwrap(store.list().first)
            XCTAssertEqual(result.kind, completed.kind)
            XCTAssertEqual(result.completed, completed.completed)
            XCTAssertEqual(result.due, completed.due)
            XCTAssertEqual(result.createdAt, completed.createdAt)
        }.value
    }
    func testBoardCreationFiltersConversionAndDirtyProtection() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let note = try store.add(kind: "note", text: "转为任务")
            let model = AppModel(store: store)
            await model.waitForReload()
            model.setSearch("转为"); model.switchMode(.board)
            await model.waitForReload()
            XCTAssertTrue(model.search.isEmpty)
            model.showNewTask(status: "in_progress"); model.taskDraft = "重要任务"; model.taskDraftImportant = true
            model.switchMode(.notes)
            await model.waitForReload()
            XCTAssertEqual(model.mode, .board); XCTAssertTrue(model.taskCreating)
            model.saveNewTask()
            await model.waitForReload()
            let task = try XCTUnwrap(model.tasks.first)
            XCTAssertEqual(task.status, "in_progress"); XCTAssertEqual(task.priority, "important")
            model.beginEditing(task); model.editStatus = "completed"
            XCTAssertTrue(model.editDirty)
            model.setImportantOnly(true)
            XCTAssertFalse(model.importantOnly)
            model.saveEditing()
            await model.waitForReload()
            XCTAssertEqual(model.tasks.first?.status, "completed")
            model.undo()
            await model.waitForReload()
            XCTAssertEqual(model.tasks.first?.status, "in_progress")
            model.switchMode(.notes); model.convertToTask(note)
            await model.waitForReload()
            XCTAssertEqual(model.convertedTaskID, note.id)
            model.showConvertedTask()
            await model.waitForReload()
            XCTAssertEqual(model.mode, .board); XCTAssertEqual(model.editing?.id, note.id)
        }.value
    }

    func testBoardExternalRefreshDragConflictAndCompletedLimit() async throws {
        try await Task { @MainActor in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try Store(url: url), cli = try Store(url: url)
            let task = try cli.add(kind: "todo", text: "外部任务", due: "2026-09-11")
            for i in 0..<45 { _ = try cli.add(kind: "note", text: "遮挡旧任务 \(i)") }
            for i in 0..<25 { _ = try cli.add(kind: "todo", text: "完成 \(i)", status: "completed") }
            let model = AppModel(store: store); model.switchMode(.board)
            await model.waitForReload()
            XCTAssertEqual(model.tasks.count, 26)
            XCTAssertEqual(model.completedLimit, 20)
            XCTAssertEqual(model.visibleTasks.filter { $0.completed }.prefix(model.completedLimit).count, 20)
            model.completedLimit += 20
            XCTAssertEqual(model.visibleTasks.filter { $0.completed }.prefix(model.completedLimit).count, 25)
            XCTAssertTrue(model.changeTask(task, status: "in_progress"))
            await model.waitForReload()
            let started = try XCTUnwrap(model.tasks.first { $0.id == task.id })
            XCTAssertEqual(started.due, task.due)
            XCTAssertEqual(started.priority, task.priority)
            _ = try cli.updateTodo(id: task.id, priority: "important")
            XCTAssertFalse(model.changeTask(started, status: "completed"))
            await model.waitForReload()
            XCTAssertEqual(model.tasks.first { $0.id == task.id }?.status, "in_progress")
            model.beginEditing(try XCTUnwrap(model.tasks.first { $0.id == task.id }))
            model.editDraft = "本地未保存"
            _ = try cli.updateTodo(id: task.id, text: "CLI 已修改")
            model.refreshIfChanged(); model.saveEditing()
            await model.waitForReload()
            XCTAssertEqual(model.editDraft, "本地未保存"); XCTAssertNotNil(model.editing)
            XCTAssertEqual(model.tasks.first { $0.id == task.id }?.text, "CLI 已修改")
        }.value
    }

}
