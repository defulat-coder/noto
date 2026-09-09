import Foundation
import Security
import NotoCore

struct UserSession: Codable, Sendable {
    struct User: Codable, Sendable { let id: String; let email: String? }
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double
    let user: User
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", user
    }
}

actor SupabaseAuth {
    let configuration: SyncConfiguration
    private var session: UserSession?
    private var generation = 0
    private var refreshTask: Task<UserSession, Error>?
    init(configuration: SyncConfiguration) { self.configuration = configuration }

    func restore() throws -> UserSession? {
        if let data = try SessionKeychain.read(service: configuration.identity) {
            session = try JSONDecoder().decode(UserSession.self, from: data)
        }
        return session
    }
    func signIn(email: String, password: String) async throws -> UserSession {
        let version = generation
        let value: UserSession = try await request(path: "auth/v1/token?grant_type=password", body: ["email": email, "password": password])
        guard version == generation else { throw CancellationError() }
        guard UUID(uuidString: value.user.id) != nil else { throw NotoError("登录返回了无效账号。") }
        try persist(value)
        return value
    }
    func token() async throws -> String? {
        guard let session else { return nil }
        if session.expiresAt > Date().timeIntervalSince1970 + 60 { return session.accessToken }
        let version = generation
        if let refreshTask {
            let value = try await refreshTask.value
            guard version == generation else { throw CancellationError() }
            return value.accessToken
        }
        let task = Task { () throws -> UserSession in
            let updated: UserSession = try await request(path: "auth/v1/token?grant_type=refresh_token", body: ["refresh_token": session.refreshToken])
            guard version == generation else { throw CancellationError() }
            guard updated.user.id == session.user.id else { throw NotoError("刷新后的账号不匹配，已停止同步。") }
            try persist(updated)
            return updated
        }
        refreshTask = task
        defer { if version == generation { refreshTask = nil } }
        let updated = try await task.value
        guard version == generation else { throw CancellationError() }
        return updated.accessToken
    }
    func signOut() throws {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
        try SessionKeychain.delete(service: configuration.identity)
        session = nil
    }
    private func persist(_ value: UserSession) throws {
        try SessionKeychain.save(try JSONEncoder().encode(value), service: configuration.identity)
        session = value
    }
    private func request<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        let base = configuration.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/" + path) else { throw NotoError("服务地址无效。") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NotoError("登录或续期失败，请检查账号、邮箱确认状态和网络。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private enum SessionKeychain {
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.noto.sync." + service, kSecAttrAccount as String: "session"]
    }
    static func read(service: String) throws -> Data? {
        var values = query(service: service); values[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(values as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NotoError("无法读取系统钥匙串（\(status)）。") }
        return item as? Data
    }
    static func save(_ data: Data, service: String) throws {
        let values = query(service: service)
        var status = SecItemUpdate(values as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = values; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NotoError("无法安全保存登录状态（\(status)）。") }
    }
    static func delete(service: String) throws {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NotoError("无法清除登录状态（\(status)）。") }
    }
}
