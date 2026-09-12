import Foundation
import XCTest
@testable import NotoCore

final class SyncStoreTests: XCTestCase {
    private let account = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    private func syncedStore() throws -> Store {
        let store = try Store(url: nil)
        try store.enableSync(accountID: account)
        return store
    }

    private func document(_ entry: Entry) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    private func text(_ store: Store, id: String) throws -> String? {
        try store.list().first(where: { $0.id == id })?.text
    }

    func testOutboxSharesTheBusinessTransactionAndIgnoresNotesAndNoOpEdits() throws {
        let store = try syncedStore()
        _ = try store.add(kind: "note", text: "Local note")
        XCTAssertThrowsError(try store.apply([
            AIAction(operation: "add_todo", text: "Rolled back"),
            AIAction(operation: "complete", id: "missing")
        ]))
        XCTAssertEqual(try store.pendingMutationCount(), 0)
        XCTAssertTrue(try store.todos().isEmpty)

        let task = try store.add(kind: "todo", text: "Created offline")
        _ = try store.updateTodo(id: task.id, text: task.text)
        let changed = try store.updateTodo(id: task.id, text: "Edited offline")
        let mutations = try store.pendingMutations()
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations.map(\.operation), ["upsert", "upsert"])
        XCTAssertNil(mutations[0].baseDocument)
        XCTAssertEqual(mutations[1].baseDocument, mutations[0].document)
        XCTAssertEqual(try Store.decodeSyncEntry(mutations[1].document).text, changed.text)
        XCTAssertNotEqual(mutations[0].mutationID, mutations[1].mutationID)
    }

    func testQueueSurvivesReopeningAndCapturesAnIndependentCLIConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("offline.sqlite")
        let firstMutationID: String
        let taskID: String
        do {
            let gui = try Store(url: url)
            try gui.enableSync(accountID: account)
            let cli = try Store(url: url)
            let task = try cli.add(kind: "todo", text: "CLI write")
            taskID = task.id
            firstMutationID = try XCTUnwrap(gui.pendingMutations().first).mutationID
            _ = try cli.setCompleted(id: task.id, completed: true)
            XCTAssertEqual(try gui.pendingMutationCount(), 2)
        }
        let reopened = try Store(url: url)
        XCTAssertEqual(try reopened.pendingMutationCount(), 2)
        XCTAssertEqual(try reopened.pendingMutations().first?.mutationID, firstMutationID)
        XCTAssertTrue(try XCTUnwrap(reopened.todos().first(where: { $0.id == taskID })).completed)
        try reopened.deleteTodo(id: taskID)
        XCTAssertEqual(try reopened.pendingMutations().last?.operation, "delete")
        XCTAssertEqual(try reopened.pendingMutationCount(), 3)
    }

    func testAnAccountCannotClaimAnotherAccountsDatabase() throws {
        let store = try Store(url: nil)
        _ = try store.add(kind: "todo", text: "Local only")
        XCTAssertEqual(try store.pendingMutationCount(), 0)
        XCTAssertThrowsError(try store.enableSync(accountID: "invalid"))
        try store.enableSync(accountID: account)
        try store.enableSync(accountID: account)
        XCTAssertThrowsError(try store.enableSync(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        _ = try store.add(kind: "todo", text: "Original account")
        XCTAssertEqual(try store.pendingMutationCount(), 1)
    }

    func testAcknowledgementEstablishesARevisionFloorAndDoesNotEchoDownloads() throws {
        let store = try syncedStore()
        let task = try store.add(kind: "todo", text: "Local version")
        let mutation = try XCTUnwrap(store.pendingMutations().first)
        var accepted = task; accepted.text = "Server accepted version"
        try store.acknowledgeMutation(mutation, document: document(accepted), revision: 10, deleted: false, outcome: "applied")
        XCTAssertEqual(try store.pendingMutationCount(), 0)
        XCTAssertEqual(try text(store, id: task.id), accepted.text)
        try store.applyRemoteTask(id: task.id, document: document(task), revision: 9, deleted: false)
        XCTAssertEqual(try text(store, id: task.id), accepted.text)
        // Retrying a previously acknowledged response must not regress newer state.
        var newer = task; newer.text = "Newer remote"
        try store.applyRemoteTask(id: task.id, document: document(newer), revision: 11, deleted: false)
        try store.acknowledgeMutation(mutation, document: document(accepted), revision: 10, deleted: false, outcome: "applied")
        XCTAssertEqual(try text(store, id: task.id), newer.text)
        XCTAssertEqual(try store.pendingMutationCount(), 0)
    }

    func testPendingLocalEditsSurviveDownloadsAndEarlierAcknowledgements() throws {
        let store = try syncedStore()
        let original = try store.add(kind: "todo", text: "First local")
        let first = try XCTUnwrap(store.pendingMutations().first)
        _ = try store.updateTodo(id: original.id, text: "Second local")
        var remote = original; remote.text = "Remote"
        try store.applyRemoteTask(id: original.id, document: document(remote), revision: 20, deleted: false)
        XCTAssertEqual(try text(store, id: original.id), "Second local")
        try store.acknowledgeMutation(first, document: document(original), revision: 21, deleted: false, outcome: "applied")
        XCTAssertEqual(try text(store, id: original.id), "Second local")
        XCTAssertEqual(try store.pendingMutationCount(), 1)
        let second = try XCTUnwrap(store.pendingMutations().first)
        try store.acknowledgeMutation(second, document: second.document, revision: 22, deleted: false, outcome: "applied")
        try store.applyRemoteTask(id: original.id, document: document(remote), revision: 21, deleted: false)
        XCTAssertEqual(try text(store, id: original.id), "Second local")
        XCTAssertEqual(try store.pendingMutationCount(), 0)
    }

    func testMalformedAcknowledgementRollsBackQueueRemoval() throws {
        let store = try syncedStore()
        let original = try store.add(kind: "todo", text: "Do not lose this")
        let mutation = try XCTUnwrap(store.pendingMutations().first)
        let wrong = Entry(kind: "todo", text: "Wrong ID")
        XCTAssertThrowsError(try store.acknowledgeMutation(mutation, document: document(wrong), revision: 1, deleted: false, outcome: "conflict"))
        XCTAssertEqual(try store.pendingMutations().map(\.mutationID), [mutation.mutationID])
        XCTAssertEqual(try text(store, id: original.id), original.text)
        XCTAssertTrue(try store.syncConflicts().isEmpty)
    }

    func testConflictsPreserveLocalTextAndRecoveryIsIdempotent() throws {
        let store = try syncedStore()
        let local = try store.add(kind: "todo", text: "My unsent text")
        let mutation = try XCTUnwrap(store.pendingMutations().first)
        var remote = local; remote.text = "Other device text"
        try store.acknowledgeMutation(mutation, document: document(remote), revision: 2, deleted: false, outcome: "conflict")
        let conflict = try XCTUnwrap(store.syncConflicts().first)
        XCTAssertEqual(conflict.text, local.text)
        XCTAssertEqual(try text(store, id: local.id), remote.text)
        try store.recoverConflict(id: conflict.id)
        try store.recoverConflict(id: conflict.id)
        XCTAssertEqual(try store.todos().filter { $0.text == local.text }.count, 1)
        XCTAssertEqual(try store.pendingMutationCount(), 1)

        let remoteConflictID = UUID().uuidString.lowercased()
        try store.preserveRemoteConflict(id: remoteConflictID, taskID: local.id, document: document(remote))
        try store.preserveRemoteConflict(id: remoteConflictID, taskID: local.id, document: document(remote))
        XCTAssertEqual(try store.syncConflicts().filter { $0.id == remoteConflictID }.count, 1)
    }

    func testDeletionRejectsStaleResurrectionAndExplicitRestoreQueuesRestore() throws {
        let store = try syncedStore()
        let task = Entry(kind: "todo", text: "A remote task")
        try store.applyRemoteTask(id: task.id, document: document(task), revision: 1, deleted: false)
        try store.applyRemoteTask(id: task.id, document: document(task), revision: 3, deleted: true)
        try store.applyRemoteTask(id: task.id, document: document(task), revision: 2, deleted: false)
        XCTAssertNil(try text(store, id: task.id))
        XCTAssertEqual(try store.pendingMutationCount(), 0)
        try store.restoreTodo(id: task.id)
        XCTAssertEqual(try text(store, id: task.id), task.text)
        XCTAssertEqual(try store.pendingMutations().map(\.operation), ["restore"])
    }

    func testImportIsIdempotentAndDoesNotResurrectPendingLocalDeletion() throws {
        let source = try Store(url: nil)
        _ = try source.add(kind: "todo", text: "Imported task")
        _ = try source.add(kind: "note", text: "Keep local")
        let destination = try syncedStore()
        XCTAssertEqual(try destination.importTasks(from: source), 1)
        XCTAssertEqual(try destination.importTasks(from: source), 0)
        XCTAssertEqual(try destination.pendingMutationCount(), 1)
        let importedID = try XCTUnwrap(destination.todos().first).id
        try destination.deleteTodo(id: importedID)
        XCTAssertEqual(try destination.importTasks(from: source), 0)
        XCTAssertNil(try text(destination, id: importedID))
        XCTAssertEqual(try destination.pendingMutationCount(), 2)
        XCTAssertEqual(try source.list().count, 2)
    }

    func testImportingTheSameLocalTaskIntoTwoAccountsUsesSeparateCloudIDs() throws {
        let source = try Store(url: nil)
        let original = try source.add(kind: "todo", text: "Personal task imported into two accounts")
        let first = try syncedStore()
        let second = try Store(url: nil)
        try second.enableSync(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        XCTAssertEqual(try first.importTasks(from: source), 1)
        XCTAssertEqual(try second.importTasks(from: source), 1)
        let firstTask = try XCTUnwrap(first.todos().first)
        let secondTask = try XCTUnwrap(second.todos().first)
        XCTAssertNotEqual(firstTask.id, secondTask.id,
                          "Cloud task IDs are globally unique; sharing an ID makes account B's upload fail permanently with 42501")
        XCTAssertEqual(firstTask.text, original.text)
        XCTAssertEqual(secondTask.text, original.text)
        XCTAssertEqual(try first.importTasks(from: source), 0)
        XCTAssertEqual(try second.importTasks(from: source), 0)
        XCTAssertEqual(try first.pendingMutationCount(), 1)
        XCTAssertEqual(try second.pendingMutationCount(), 1)
    }

    func testDeleteAndRestorePreserveExistingConversationHistory() throws {
        let store = try syncedStore()
        let note = try store.startConversation("Original question")
        let question = try XCTUnwrap(store.messages(for: note.id).last)
        _ = try store.apply([], replyingTo: question, reply: "Original answer")
        _ = try store.convertToTodo(id: note.id)
        let messages = try store.messages(for: note.id)
        try store.deleteTodo(id: note.id)
        try store.restoreTodo(id: note.id)
        XCTAssertTrue(try XCTUnwrap(store.todos().first).hasConversation)
        XCTAssertEqual(try store.messages(for: note.id).map(\.text), messages.map(\.text))
        XCTAssertEqual(try store.messages(for: note.id).map(\.role), messages.map(\.role))

        // The same backup guarantee must hold when a different device deletes the task.
        for (offset, mutation) in try store.pendingMutations().enumerated() {
            try store.acknowledgeMutation(mutation, document: mutation.document, revision: Int64(offset + 1),
                                          deleted: mutation.operation == "delete", outcome: "applied")
        }
        let restored = try XCTUnwrap(store.todos().first)
        try store.applyRemoteTask(id: note.id, document: document(restored), revision: 100, deleted: true)
        XCTAssertTrue(try store.todos().isEmpty)
        try store.restoreTodo(id: note.id)
        XCTAssertTrue(try XCTUnwrap(store.todos().first).hasConversation)
        XCTAssertEqual(try store.messages(for: note.id).map(\.text), messages.map(\.text))
    }

    func testDeletedTasksSurviveReopeningAndRestoreTheirContentAndConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("deleted.sqlite")
        let firstID: String, secondID: String
        let history: [ChatMessage]
        do {
            let store = try Store(url: url)
            try store.enableSync(accountID: account)
            let note = try store.startConversation("保留原来的问题")
            let question = try XCTUnwrap(store.messages(for: note.id).last)
            _ = try store.apply([], replyingTo: question, reply: "保留完整回复")
            _ = try store.convertToTodo(id: note.id)
            let first = try store.updateTodo(id: note.id, text: "修改后的任务正文", due: "2026-09-12", status: "in_progress", priority: "important")
            let second = try store.add(kind: "todo", text: "第二个任务")
            firstID = first.id; secondID = second.id
            history = try store.messages(for: first.id)
            try store.deleteTodo(id: first.id)
            try store.deleteTodo(id: second.id)
            XCTAssertEqual(try store.deletedTodos().map(\.id), [second.id, first.id])
        }

        let reopened = try Store(url: url)
        let deleted = try reopened.deletedTodos()
        XCTAssertEqual(deleted.map(\.id), [secondID, firstID])
        XCTAssertEqual(deleted.last?.text, "修改后的任务正文")
        XCTAssertEqual(deleted.last?.due, "2026-09-12")
        XCTAssertEqual(deleted.last?.status, "in_progress")
        XCTAssertEqual(deleted.last?.priority, "important")
        XCTAssertTrue(try XCTUnwrap(deleted.last).hasConversation)
        XCTAssertFalse(try XCTUnwrap(deleted.first).hasConversation)
        XCTAssertTrue(try reopened.messages(for: firstID).isEmpty)

        try reopened.restoreTodo(id: firstID)
        XCTAssertEqual(try reopened.deletedTodos().map(\.id), [secondID])
        let restored = try XCTUnwrap(reopened.todos().first)
        var archived = try XCTUnwrap(deleted.last)
        // Sync JSON and GRDB both persist milliseconds; Date conversion can differ below that precision.
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, archived.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(restored.updatedAt.timeIntervalSince1970, archived.updatedAt.timeIntervalSince1970, accuracy: 0.001)
        archived.createdAt = restored.createdAt; archived.updatedAt = restored.updatedAt
        XCTAssertEqual(restored, archived)
        XCTAssertEqual(try reopened.messages(for: firstID), history)
        XCTAssertEqual(try reopened.pendingMutations().last?.operation, "restore")
        XCTAssertThrowsError(try reopened.restoreTodo(id: firstID))

        let otherAccount = try Store(url: nil)
        try otherAccount.enableSync(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        XCTAssertTrue(try otherAccount.deletedTodos().isEmpty)
    }

    func testRemoteRestoreHidesArchiveAndRepeatedDeletionBecomesMostRecent() throws {
        let store = try syncedStore()
        let first = Entry(kind: "todo", text: "先删除的任务")
        let second = Entry(kind: "todo", text: "后删除的任务")
        for task in [first, second] {
            try store.applyRemoteTask(id: task.id, document: document(task), revision: 1, deleted: false)
            try store.applyRemoteTask(id: task.id, document: document(task), revision: 2, deleted: true)
        }
        XCTAssertEqual(try store.deletedTodos().map(\.id), [second.id, first.id])
        try store.applyRemoteTask(id: first.id, document: document(first), revision: 3, deleted: false)
        XCTAssertEqual(try store.deletedTodos().map(\.id), [second.id])
        XCTAssertThrowsError(try store.restoreTodo(id: first.id))
        try store.applyRemoteTask(id: first.id, document: document(first), revision: 4, deleted: true)
        XCTAssertEqual(try store.deletedTodos().map(\.id), [first.id, second.id])
        XCTAssertEqual(try store.pendingMutationCount(), 0)
    }

    func testUndoingConversionRemovesTheSyncedTodoButPreservesTheLocalNote() throws {
        let store = try syncedStore()
        let note = try store.add(kind: "note", text: "Note to task and back")
        let task = try store.convertToTodo(id: note.id)
        try store.undo(before: [note], after: [task])
        XCTAssertEqual(try store.list().first?.kind, "note")
        XCTAssertEqual(try store.pendingMutations().map(\.operation), ["upsert", "delete"])
        guard try store.pendingMutationCount() == 2 else { return }
        let creation = try XCTUnwrap(store.pendingMutations().first)
        let deletion = try XCTUnwrap(store.pendingMutations().last)
        XCTAssertEqual(try Store.decodeSyncEntry(deletion.document).kind, "todo")
        try store.acknowledgeMutation(creation, document: creation.document, revision: 1, deleted: false, outcome: "applied")
        try store.acknowledgeMutation(deletion, document: deletion.document, revision: 2, deleted: true, outcome: "applied")
        XCTAssertEqual(try store.list().first?.kind, "note")
        XCTAssertEqual(try text(store, id: note.id), note.text)
        XCTAssertEqual(try store.pendingMutationCount(), 0)
    }

    func testExplicitReconversionAfterUndoUsesRestoreInsteadOfRejectedUpsert() throws {
        for acknowledgeDeletion in [false, true] {
            let store = try syncedStore()
            let note = try store.add(kind: "note", text: "Convert again after undo")
            let task = try store.convertToTodo(id: note.id)
            try store.undo(before: [note], after: [task])
            if acknowledgeDeletion {
                for (offset, mutation) in try store.pendingMutations().enumerated() {
                    try store.acknowledgeMutation(mutation, document: mutation.document, revision: Int64(offset + 1),
                                                  deleted: mutation.operation == "delete", outcome: "applied")
                }
            }
            _ = try store.convertToTodo(id: note.id)
            let reconversion = try XCTUnwrap(store.pendingMutations().last)
            XCTAssertEqual(reconversion.operation, "restore",
                           "Explicit conversion after undo must survive the server tombstone; ordinary upsert is rejected")
            XCTAssertEqual(try Store.decodeSyncEntry(reconversion.document).id, note.id)
        }
    }
}
