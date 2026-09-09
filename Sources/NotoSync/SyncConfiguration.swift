import Foundation
import CryptoKit
import NotoCore

public struct SyncConfiguration: Codable, Equatable, Sendable {
    public let supabaseURL: URL
    public let publishableKey: String
    public let powerSyncURL: URL
    public init(supabaseURL: URL, publishableKey: String, powerSyncURL: URL) {
        self.supabaseURL = supabaseURL; self.publishableKey = publishableKey; self.powerSyncURL = powerSyncURL
    }
    public func validate() throws {
        for url in [supabaseURL, powerSyncURL] {
            let local = ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
            guard url.host != nil, url.user == nil, url.password == nil, url.query == nil,
                  url.scheme == "https" || (local && url.scheme == "http") else { throw NotoError("服务地址必须使用 HTTPS；仅本机开发允许 HTTP。") }
        }
        guard !publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !publishableKey.hasPrefix("sb_secret_") else { throw NotoError("请使用 Supabase publishable/anon key，不要使用服务端密钥。") }
        let parts = publishableKey.split(separator: ".")
        if parts.count == 3 {
            var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            body += String(repeating: "=", count: (4 - body.count % 4) % 4)
            if let data = Data(base64Encoded: body), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["role"] as? String == "service_role" {
                throw NotoError("service_role key 不能保存在客户端。")
            }
        }
    }
    var identity: String {
        SHA256.hash(data: Data(supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func load() -> Self? {
        let env = ProcessInfo.processInfo.environment
        let bundle = Bundle.main
        func value(_ key: String) -> String? {
            env[key] ?? bundle.object(forInfoDictionaryKey: key) as? String
        }
        if let server = value("NOTO_SUPABASE_URL"), let key = value("NOTO_SUPABASE_KEY"),
           let replica = value("NOTO_POWERSYNC_URL"), let serverURL = URL(string: server), let replicaURL = URL(string: replica) {
            return Self(supabaseURL: serverURL, publishableKey: key, powerSyncURL: replicaURL)
        }
        return UserDefaults.standard.data(forKey: "noto.sync.configuration").flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "noto.sync.configuration") }
}
