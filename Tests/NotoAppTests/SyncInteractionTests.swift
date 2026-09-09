import XCTest
import NotoCore
@testable import NotoApp

final class SyncInteractionTests: XCTestCase {
    func testAccountSwitchRefusesUnsentAndHiddenDrafts() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let note = try store.startConversation("Saved conversation")
            let model = AppModel(store: store)
            await model.waitForReload()
            model.draft = "Unsent note"
            XCTAssertFalse(model.canChangeSyncAccount())
            XCTAssertEqual(model.draft, "Unsent note")
            model.draft = ""
            model.openConversation(note); model.chatDraft = "Unsent question"
            model.closeConversation()
            XCTAssertFalse(model.canChangeSyncAccount())
            model.openConversation(note); model.chatDraft = ""; model.closeConversation()
            model.beginEditing(note); model.editDraft = "Unsaved edit"
            XCTAssertFalse(model.canChangeSyncAccount())
            model.cancelEditing()
            model.showNewTask(); model.taskDraft = "Hidden task draft"; model.taskCreating = false
            XCTAssertFalse(model.canChangeSyncAccount())
            model.taskDraft = ""; model.taskDraftHasDue = false
            XCTAssertTrue(model.canChangeSyncAccount())
        }.value
    }

    func testAccountReplacementClearsOldContentUndoAndSelection() async throws {
        try await Task { @MainActor in
            let local = try Store(url: nil), account = try Store(url: nil)
            let localTask = try local.add(kind: "todo", text: "Local account")
            let remoteTask = try account.add(kind: "todo", text: "Other account")
            let model = AppModel(store: local)
            model.mode = .board; model.reload(); await model.waitForReload()
            model.toggle(localTask); await model.waitForReload()
            XCTAssertTrue(model.undoAvailable)
            model.highlightedTaskID = localTask.id
            model.search = "Local"
            model.replaceAccountStore(account)
            XCTAssertTrue(model.tasks.isEmpty)
            XCTAssertFalse(model.undoAvailable)
            XCTAssertNil(model.highlightedTaskID)
            XCTAssertTrue(model.search.isEmpty)
            await model.waitForReload()
            XCTAssertEqual(model.tasks.map(\.id), [remoteTask.id])
            model.undo()
            XCTAssertEqual(try account.todos().map(\.id), [remoteTask.id])
        }.value
    }

    func testTaskDeletionAndRestoreRefreshTheBoardWithoutRemovingOtherTasks() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let task = try store.add(kind: "todo", text: "Delete then restore")
            let other = try store.add(kind: "todo", text: "Keep this")
            let model = AppModel(store: store)
            model.mode = .board; model.reload(); await model.waitForReload()
            model.deleteTask(task); await model.waitForReload()
            XCTAssertEqual(model.lastDeletedTaskID, task.id)
            XCTAssertEqual(model.tasks.map(\.id), [other.id])
            model.restoreLastDeletedTask(); await model.waitForReload()
            XCTAssertNil(model.lastDeletedTaskID)
            XCTAssertEqual(Set(model.tasks.map(\.id)), Set([task.id, other.id]))
        }.value
    }
}
