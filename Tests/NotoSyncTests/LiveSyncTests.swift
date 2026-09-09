import Foundation
import XCTest
import NotoCore
@testable import NotoSync

/// Opt in with NOTO_LIVE_FIXTURE pointing to a disposable local backend fixture.
/// Uses real Auth, RPC, PostgreSQL replication and the production Swift PowerSync SDK.
final class LiveSyncTests: XCTestCase {
    struct Fixture: Decodable {
        struct User: Decodable { let email: String; let password: String; let id: String }
        let supabaseURL: URL; let publishableKey: String; let powerSyncURL: URL; let users: [User]
        var configuration: SyncConfiguration {
            .init(supabaseURL: supabaseURL, publishableKey: publishableKey, powerSyncURL: powerSyncURL)
        }
    }

    @MainActor
    func testRealSwiftOfflineReplicationConflictsAndIsolation() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTO_LIVE_FIXTURE"] else {
            throw XCTSkip("Set NOTO_LIVE_FIXTURE to test against disposable live services")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThanOrEqual(fixture.users.count, 2)
        let configuration = fixture.configuration
        try configuration.validate()
        func login(_ user: Fixture.User) async throws -> String {
            var request = URLRequest(url: URL(string: "auth/v1/token?grant_type=password", relativeTo: URL(string: fixture.supabaseURL.absoluteString + "/"))!)
            request.httpMethod = "POST"
            request.setValue(fixture.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["email": user.email, "password": user.password])
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try JSONDecoder().decode(UserSession.self, from: data).accessToken
        }
        let token = try await login(fixture.users[0])
        let otherToken = try await login(fixture.users[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noto-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aURL = directory.appendingPathComponent("a.sqlite")
        let a = try Store(url: aURL), b = try Store(url: directory.appendingPathComponent("b.sqlite"))
        try a.enableSync(accountID: fixture.users[0].id)
        try b.enableSync(accountID: fixture.users[0].id)
        let replica = PowerSyncReplica(path: directory.appendingPathComponent("replica.sqlite").path)
        let isolated = PowerSyncReplica(path: directory.appendingPathComponent("other.sqlite").path)
        try await replica.connect(endpoint: fixture.powerSyncURL.absoluteString) { token }
        try await isolated.connect(endpoint: fixture.powerSyncURL.absoluteString) { otherToken }
        do {
            func upload(_ store: Store, using accessToken: String? = nil) async throws {
                for mutation in try store.pendingMutations() {
                    let ack = try await SyncController.upload(mutation, configuration: configuration, token: accessToken ?? token)
                    try store.acknowledgeMutation(mutation, document: ack.document, revision: ack.revision, deleted: ack.deleted, outcome: ack.outcome)
                }
            }
            func receive(_ id: String, deleted: Bool = false, text: String? = nil) async throws {
                let deadline = Date().addingTimeInterval(45)
                repeat {
                    if let row = try await replica.readTasks().first(where: { $0.id == id }), row.deleted == deleted,
                       try (text == nil || Store.decodeSyncEntry(row.document).text == text) {
                        try b.applyRemoteTask(id: row.id, document: row.document, revision: row.revision, deleted: row.deleted)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } while Date() < deadline
                XCTFail("PowerSync did not deliver the expected task within 45s")
                throw NSError(domain: "LiveSyncTimeout", code: 1)
            }

            // Several edits survive reopening before the first network request.
            let task = try a.add(kind: "todo", text: "Offline initial " + UUID().uuidString)
            _ = try a.updateTodo(id: task.id, text: "Offline final")
            let reopened = try Store(url: aURL)
            XCTAssertEqual(try reopened.pendingMutationCount(), 2)
            try await upload(reopened)
            XCTAssertEqual(try a.pendingMutationCount(), 0)
            try await receive(task.id, text: "Offline final")
            XCTAssertEqual(try b.todos().first(where: { $0.id == task.id })?.text, "Offline final")

            // Both clients edit the same base while disconnected from the downloader.
            _ = try a.updateTodo(id: task.id, text: "Device A")
            _ = try b.updateTodo(id: task.id, text: "Device B retained")
            try await upload(a)
            try await upload(b)
            XCTAssertEqual(try b.todos().first(where: { $0.id == task.id })?.text, "Device A")
            let conflict = try XCTUnwrap(b.syncConflicts().first(where: { $0.taskID == task.id }))
            XCTAssertEqual(conflict.text, "Device B retained")
            try b.recoverConflict(id: conflict.id)
            try await upload(b)
            XCTAssertTrue(try b.todos().contains(where: { $0.text == "Device B retained" && $0.id != task.id }))

            try a.deleteTodo(id: task.id)
            try await upload(a)
            try await receive(task.id, deleted: true)
            XCTAssertFalse(try b.todos().contains(where: { $0.id == task.id }))
            try a.restoreTodo(id: task.id)
            try await upload(a)
            try await receive(task.id, text: "Device A")

            // New task created/deleted/restored entirely offline must not conflict on server timestamps.
            let transient = try a.add(kind: "todo", text: "Offline restored")
            try a.deleteTodo(id: transient.id)
            try a.restoreTodo(id: transient.id)
            try await upload(a)
            try await receive(transient.id, text: "Offline restored")
            XCTAssertFalse(try a.syncConflicts().contains(where: { $0.taskID == transient.id }))

            let note = try a.add(kind: "note", text: "Convert again")
            let converted = try a.convertToTodo(id: note.id)
            try a.undo(before: [note], after: [converted])
            _ = try a.convertToTodo(id: note.id)
            try await upload(a)
            try await receive(note.id, text: "Convert again")
            XCTAssertFalse(try a.syncConflicts().contains(where: { $0.taskID == note.id }))

            let source = try Store(url: nil)
            _ = try source.add(kind: "todo", text: "Imported shared local task")
            let otherStore = try Store(url: nil)
            try otherStore.enableSync(accountID: fixture.users[1].id)
            XCTAssertEqual(try a.importTasks(from: source), 1)
            XCTAssertEqual(try otherStore.importTasks(from: source), 1)
            let aliceImport = try XCTUnwrap(a.todos().first(where: { $0.text == "Imported shared local task" }))
            let bobImport = try XCTUnwrap(otherStore.todos().first)
            XCTAssertNotEqual(aliceImport.id, bobImport.id)
            try await upload(a)
            try await upload(otherStore, using: otherToken)
            try await receive(aliceImport.id, text: aliceImport.text)
            XCTAssertEqual(try a.importTasks(from: source), 0)
            XCTAssertEqual(try otherStore.importTasks(from: source), 0)
            let importDeadline = Date().addingTimeInterval(30)
            while !(try await isolated.readTasks().contains(where: { $0.id == bobImport.id })) && Date() < importDeadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            let bobRows = try await isolated.readTasks()
            XCTAssertTrue(bobRows.contains(where: { $0.id == bobImport.id }))
            XCTAssertFalse(bobRows.contains(where: { $0.id == aliceImport.id }))

            let deadline = Date().addingTimeInterval(30)
            while !isolated.hasSynced && Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
            XCTAssertTrue(isolated.hasSynced)
            let otherRows = try await isolated.readTasks()
            XCTAssertFalse(otherRows.contains(where: { $0.id == task.id || $0.id == transient.id }))
            let otherConflicts = try await isolated.readConflicts()
            XCTAssertFalse(otherConflicts.contains(where: { $0.taskID == task.id }))
        } catch {
            try? await replica.disconnect(); try? await isolated.disconnect()
            try? await replica.close(); try? await isolated.close()
            throw error
        }
        try await replica.disconnect(); try await isolated.disconnect()
        try await replica.close(); try await isolated.close()
    }
}
