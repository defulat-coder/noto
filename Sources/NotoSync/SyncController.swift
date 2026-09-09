import Foundation
import Combine
import NotoCore

@MainActor
public final class SyncController: ObservableObject {
    @Published public private(set) var store: Store
    @Published public private(set) var email: String?
    @Published public private(set) var status = "仅保存在本机"
    @Published public private(set) var lastError = ""
    @Published public private(set) var pendingCount = 0
    @Published public private(set) var isSyncing = false
    @Published public private(set) var dataRevision = 0
    @Published public private(set) var conflicts: [SyncConflict] = []
    @Published public private(set) var configuration: SyncConfiguration?
    public var isSignedIn: Bool { email != nil }
    private let localStore: Store
    private var auth: SupabaseAuth?
    private var replica: PowerSyncReplica?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var restored = false
    private var downloadedRevisions: [String: Int64] = [:]
    private var downloadedConflicts: Set<String> = []

    public init(localStore: Store) {
        self.localStore = localStore; self.store = localStore
        configuration = SyncConfiguration.load()
    }
    deinit { loop?.cancel() }

    public func configure(_ config: SyncConfiguration) throws {
        guard !isSignedIn, !isSyncing else { throw NotoError("请先退出当前账号再更换服务配置。") }
        try config.validate(); try config.save(); configuration = config
        restored = false; lastError = ""
    }

    public func restoreSession() async {
        guard !restored, !isSyncing, let configuration else { return }
        restored = true; isSyncing = true
        defer { isSyncing = false }
        do {
            try configuration.validate()
            let auth = SupabaseAuth(configuration: configuration)
            if let session = try await auth.restore() { try await activate(session, auth: auth, configuration: configuration) }
        } catch { lastError = error.localizedDescription; status = "登录状态恢复失败，本机数据未变" }
    }

    public func signIn(email: String, password: String) async {
        guard !isSignedIn, !isSyncing else { return }
        guard let configuration else { lastError = "请先配置同步服务。"; return }
        isSyncing = true; lastError = ""; status = "正在登录…"
        defer { isSyncing = false }
        do {
            try configuration.validate()
            let auth = SupabaseAuth(configuration: configuration)
            let session = try await auth.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            try await activate(session, auth: auth, configuration: configuration)
        } catch { lastError = error.localizedDescription; status = "登录未完成，本机数据未变" }
    }

    private func activate(_ session: UserSession, auth: SupabaseAuth, configuration: SyncConfiguration) async throws {
        let accountDirectory = Store.localURL.deletingLastPathComponent().appendingPathComponent("accounts")
            .appendingPathComponent(configuration.identity).appendingPathComponent(session.user.id.lowercased())
        let accountURL = accountDirectory.appendingPathComponent("notes.sqlite")
        let accountStore = try await Task.detached(priority: .userInitiated) {
            let value = try Store(url: accountURL, busyTimeout: 0.1)
            try value.enableSync(accountID: session.user.id)
            return value
        }.value
        let replica = PowerSyncReplica(path: accountDirectory.appendingPathComponent("replica.sqlite").path)
        // The account's cached data remains usable even when connecting is offline.
        try await replica.connect(endpoint: configuration.powerSyncURL.absoluteString) { try await auth.token() }
        generation += 1
        downloadedRevisions = [:]; downloadedConflicts = []
        self.auth = auth; self.replica = replica
        self.store = accountStore; email = session.user.email ?? session.user.id
        pendingCount = try accountStore.pendingMutationCount(); conflicts = try accountStore.syncConflicts()
        try Self.selectCLIStore(accountURL)
        status = "已打开账号数据，正在连接同步服务…"
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    public func signOut() async {
        guard isSignedIn, !isSyncing else { return }
        isSyncing = true; generation += 1
        loop?.cancel(); await loop?.value; loop = nil
        defer { isSyncing = false }
        do {
            try await replica?.disconnect()
            try await replica?.close()
            replica = nil // Later keychain/pointer failures must remain retryable.
            try await auth?.signOut()
            try Self.selectCLIStore(nil)
            replica = nil; auth = nil; email = nil; store = localStore
            conflicts = []; pendingCount = 0; lastError = ""; status = "已退出；账号离线数据保留在独立目录"
        } catch { lastError = error.localizedDescription; status = "退出未完成，请重试" }
    }

    public func syncNow() async {
        guard !isSyncing, let auth, let replica, let configuration else { return }
        isSyncing = true
        let version = generation, target = store
        var dataChanged = false
        defer {
            if version == generation {
                if dataChanged {
                    dataRevision += 1
                    conflicts = (try? target.syncConflicts()) ?? conflicts
                }
                isSyncing = false
            }
        }
        do {
            let mutations = try await Task.detached { try target.pendingMutations() }.value
            for mutation in mutations {
                try Task.checkCancellation()
                guard version == generation, let token = try await auth.token() else { return }
                let ack = try await Self.upload(mutation, configuration: configuration, token: token)
                guard version == generation else { return }
                try await Task.detached {
                    try target.acknowledgeMutation(mutation, document: ack.document, revision: ack.revision, deleted: ack.deleted, outcome: ack.outcome)
                }.value
                dataChanged = true
                downloadedRevisions.removeValue(forKey: mutation.entryID)
            }
            let tasks = try await replica.readTasks().filter { downloadedRevisions[$0.id] != $0.revision }
            let remoteConflicts = try await replica.readConflicts().filter { !downloadedConflicts.contains($0.id) }
            guard version == generation else { return }
            if !tasks.isEmpty { dataChanged = true }
            let counts = try await Task.detached {
                try target.applyRemoteTasks(tasks.map { (id: $0.id, document: $0.document, revision: $0.revision, deleted: $0.deleted) })
                for conflict in remoteConflicts { try target.preserveRemoteConflict(id: conflict.id, taskID: conflict.taskID, document: conflict.document) }
                return (try target.pendingMutationCount(), try target.syncConflicts())
            }.value
            guard version == generation else { return }
            if counts.0 == 0 { for task in tasks { downloadedRevisions[task.id] = task.revision } }
            downloadedConflicts.formUnion(remoteConflicts.map(\.id))
            pendingCount = counts.0; conflicts = counts.1; lastError = ""
            if !replica.isConnected { status = "本机已保存，等待同步连接" }
            else if !replica.hasSynced { status = "正在下载账号数据…" }
            else if pendingCount > 0 { status = "还有 \(pendingCount) 项修改待上传" }
            else { status = "已同步" }
        } catch is CancellationError {
        } catch {
            guard version == generation else { return }
            pendingCount = (try? target.pendingMutationCount()) ?? pendingCount
            lastError = error.localizedDescription; status = "本机修改已保留，将自动重试"
        }
    }

    public func importLocalTasks() async {
        guard isSignedIn, !isSyncing else { return }
        isSyncing = true
        let destination = store, source = localStore
        do {
            let count = try await Task.detached { try destination.importTasks(from: source) }.value
            if count > 0 { dataRevision += 1 }
            status = "已导入 \(count) 条本机任务，等待同步"; lastError = ""
        } catch { lastError = error.localizedDescription }
        isSyncing = false
        await syncNow()
    }

    public func recoverConflict(id: String) async {
        guard !isSyncing else { return }
        do {
            try store.recoverConflict(id: id); dataRevision += 1; conflicts = try store.syncConflicts()
            await syncNow()
        } catch { lastError = error.localizedDescription }
    }

    struct Acknowledgement: Sendable {
        let document: String; let revision: Int64; let deleted: Bool; let outcome: String
    }
    static func upload(_ mutation: SyncMutation, configuration: SyncConfiguration, token: String) async throws -> Acknowledgement {
        let document = try JSONSerialization.jsonObject(with: Data(mutation.document.utf8))
        let base: Any = try mutation.baseDocument.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()
        let body: [String: Any] = ["p_mutation_id": mutation.mutationID, "p_task_id": mutation.entryID,
                                  "p_operation": mutation.operation, "p_document": document, "p_base_document": base]
        let url = configuration.supabaseURL.appendingPathComponent("rest/v1/rpc/noto_apply_mutation")
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NotoError("上传未完成（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），修改仍在本机队列。")
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let document = value["document"] as? [String: Any], let revision = value["revision"] as? NSNumber,
              let deleted = value["deleted"] as? Bool, let outcome = value["outcome"] as? String,
              ["applied", "conflict", "deleted"].contains(outcome), revision.int64Value > 0 else { throw NotoError("同步响应格式无效，修改仍在本机队列。") }
        return Acknowledgement(document: String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self),
                               revision: revision.int64Value, deleted: deleted, outcome: outcome)
    }

    private static func selectCLIStore(_ url: URL?) throws {
        #if os(macOS)
        let pointer = Store.localURL.deletingLastPathComponent().appendingPathComponent("active-account.json")
        if let url { try JSONEncoder().encode(url.path).write(to: pointer, options: .atomic) }
        else if FileManager.default.fileExists(atPath: pointer.path) { try FileManager.default.removeItem(at: pointer) }
        #endif
    }
}
