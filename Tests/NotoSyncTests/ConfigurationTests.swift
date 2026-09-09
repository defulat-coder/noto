import Foundation
import XCTest
@testable import NotoSync

final class ConfigurationTests: XCTestCase {
    func testRemoteServicesRequireHTTPSAndClientSafeKeys() throws {
        func config(_ url: String, key: String = "sb_publishable_test") -> SyncConfiguration {
            SyncConfiguration(supabaseURL: URL(string: url)!, publishableKey: key,
                              powerSyncURL: URL(string: "https://sync.example.com")!)
        }
        XCTAssertNoThrow(try config("https://project.supabase.co").validate())
        XCTAssertNoThrow(try config("http://127.0.0.1:54321").validate())
        XCTAssertThrowsError(try config("http://project.supabase.co").validate())
        XCTAssertThrowsError(try config("https://user:password@example.com").validate())
        XCTAssertThrowsError(try config("https://example.com?secret=test").validate())
        XCTAssertThrowsError(try config("https://example.com", key: "sb_secret_test").validate())
        let role = Data(#"{"role":"service_role"}"#.utf8).base64EncodedString()
        XCTAssertThrowsError(try config("https://example.com", key: "header.\(role).signature").validate())
    }
}
