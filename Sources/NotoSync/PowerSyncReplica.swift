import Foundation
import PowerSync

public struct RemoteTask: Sendable {
    public let id: String
    public let document: String
    public let revision: Int64
    public let deleted: Bool
}

public struct RemoteConflict: Sendable {
    public let id: String
    public let taskID: String
    public let document: String
}

/// A download-only replica. All writes belong to the business database's durable outbox.
/// Use a separate absolute path for each account, and disconnect before changing accounts.
public final class PowerSyncReplica: Sendable {
    private let database: any PowerSyncDatabaseProtocol

    public init(path: String) {
        database = PowerSyncDatabase(
            schema: Schema(
                Table(name: "noto_tasks", columns: [
                    .text("document"), .integer("revision"), .integer("deleted")
                ]),
                Table(name: "noto_conflicts", columns: [
                    .text("task_id"), .text("document")
                ])
            ),
            dbFilename: path
        )
    }

    public func connect(
        endpoint: String,
        tokenProvider: @escaping @Sendable () async throws -> String?
    ) async throws {
        try await database.connect(connector: ReplicaConnector(
            endpoint: endpoint, tokenProvider: tokenProvider
        ))
    }

    public func readTasks() async throws -> [RemoteTask] {
        try await database.getAll("SELECT id, document, revision, deleted FROM noto_tasks") { cursor in
            try RemoteTask(
                id: cursor.getString(name: "id"),
                document: cursor.getString(name: "document"),
                revision: cursor.getInt64(name: "revision"),
                deleted: cursor.getInt64(name: "deleted") != 0
            )
        }
    }

    public func readConflicts() async throws -> [RemoteConflict] {
        try await database.getAll("SELECT id, task_id, document FROM noto_conflicts") { cursor in
            try RemoteConflict(
                id: cursor.getString(name: "id"),
                taskID: cursor.getString(name: "task_id"),
                document: cursor.getString(name: "document")
            )
        }
    }

    public var isConnected: Bool { database.currentStatus.connected }
    public var hasSynced: Bool { database.currentStatus.hasSynced == true }

    public func disconnect() async throws {
        try await database.disconnect()
    }

    public func close() async throws {
        try await database.close()
    }
}

private struct ReplicaConnector: PowerSyncBackendConnectorProtocol {
    let endpoint: String
    let tokenProvider: @Sendable () async throws -> String?

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        guard let token = try await tokenProvider() else { return nil }
        return PowerSyncCredentials(endpoint: endpoint, token: token)
    }

    func uploadData(database: any PowerSyncDatabaseProtocol) async throws {
        // Never acknowledge unexpected writes: doing so would silently discard data.
        if try await database.getNextCrudTransaction() != nil {
            throw ReplicaError.unexpectedLocalWrites
        }
    }
}

private enum ReplicaError: LocalizedError {
    case unexpectedLocalWrites

    var errorDescription: String? {
        "The download-only sync replica contains unexpected local writes. They have been preserved."
    }
}
