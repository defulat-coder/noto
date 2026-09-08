import XCTest
import AppKit
import NotoCore
@testable import NotoApp

final class InteractionTests: XCTestCase {
    func testMarkedTextCannotSubmit() async {
        await MainActor.run {
            let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            var submitted = 0
            input.onSubmit = { submitted += 1 }
            input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(input.hasMarkedText())
            input.submit()
            XCTAssertEqual(submitted, 0)
            input.unmarkText(); input.submit()
            XCTAssertEqual(submitted, 1)
        }
    }
    func testDraftMovementAndDirtyEditProtection() async throws {
        try await MainActor.run {
            let store = try Store(url: nil)
            let first = try store.add(kind: "note", text: "原文")
            let other = try store.add(kind: "todo", text: "待办", due: "2026-09-09")
            let model = AppModel(store: store)
            XCTAssertNil(model.composerPosition)
            model.showComposer(at: CGPoint(x: 90, y: 120)); model.draft = "未发送的草稿"
            model.composerPosition = nil
            model.showComposer(at: CGPoint(x: 300, y: 240))
            XCTAssertEqual(model.draft, "未发送的草稿")
            model.beginEditing(first); model.editDraft = "修改后的文字"
            model.showComposer(); model.beginEditing(other); model.setSearch("其他")
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
        }
    }

    func testInlineEditPreservesConversationAndRejectsConcurrentChange() async throws {
        try await MainActor.run {
            let store = try Store(url: nil)
            let entry = try store.startConversation("原始问题")
            let question = try XCTUnwrap(store.messages(for: entry.id).first)
            _ = try store.apply([], replyingTo: question, reply: "原始回答")
            let history = try store.messages(for: entry.id)
            let model = AppModel(store: store)
            model.beginEditing(entry); model.editDraft = "仅改列表文字"; model.saveEditing()
            let changed = try XCTUnwrap(store.list().first)
            XCTAssertEqual(changed.id, entry.id)
            XCTAssertEqual(changed.createdAt, entry.createdAt)
            XCTAssertTrue(changed.hasConversation)
            XCTAssertEqual(try store.messages(for: entry.id), history)
            model.undo()
            XCTAssertEqual(try store.list().first?.text, entry.text)
            let current = try XCTUnwrap(store.list().first)
            model.beginEditing(current); model.editDraft = "本地编辑中的草稿"
            _ = try store.update(id: entry.id, text: "来自其他进程", due: nil)
            model.saveEditing()
            XCTAssertEqual(try store.list().first?.text, "来自其他进程")
            XCTAssertEqual(model.editDraft, "本地编辑中的草稿")
            XCTAssertNotNil(model.editing)
            XCTAssertFalse(model.editError.isEmpty)
        }
    }

    func testEmptyEditAndTodoMetadata() async throws {
        try await MainActor.run {
            let store = try Store(url: nil)
            let todo = try store.add(kind: "todo", text: "待办", due: "2026-09-09")
            let completed = try store.setCompleted(id: todo.id, completed: true)
            let model = AppModel(store: store)
            model.beginEditing(completed); model.editDraft = " \n "; model.saveEditing()
            XCTAssertNotNil(model.editing)
            XCTAssertEqual(try store.list().first?.text, "待办")
            model.editDraft = "已编辑待办"; model.saveEditing()
            let result = try XCTUnwrap(store.list().first)
            XCTAssertEqual(result.kind, completed.kind)
            XCTAssertEqual(result.completed, completed.completed)
            XCTAssertEqual(result.due, completed.due)
            XCTAssertEqual(result.createdAt, completed.createdAt)
        }
    }
}
