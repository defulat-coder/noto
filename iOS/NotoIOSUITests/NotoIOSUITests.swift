import XCTest

final class NotoIOSUITests: XCTestCase {
    @MainActor func testOfflineTaskLifecycleAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["add-todo"].waitForExistence(timeout: 15))
        app.buttons["add-todo"].tap()
        let editor = app.textViews["待办内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Offline delivery check")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["Offline delivery check"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["Offline delivery check"].waitForExistence(timeout: 10))
        app.buttons["Offline delivery check"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" revised")
        let revisedText = (editor.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(revisedText.contains("revised"))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons[revisedText].waitForExistence(timeout: 5))
        app.buttons["完成待办"].firstMatch.tap()
        app.buttons["筛选与显示"].tap()
        app.buttons["已完成"].tap()
        let task = app.buttons[revisedText]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.swipeLeft()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["没有匹配的待办"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.buttons["筛选与显示"].tap()
        app.buttons["最近删除"].tap()
        let restore = app.buttons["恢复" + revisedText]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        XCTAssertTrue(app.staticTexts["没有最近删除的待办"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["筛选与显示"].tap()
        app.buttons["已完成"].tap()
        XCTAssertTrue(app.buttons[revisedText].waitForExistence(timeout: 5))
        let restored = XCTAttachment(screenshot: app.screenshot()); restored.name = "iOS restored task"; restored.lifetime = .keepAlways; add(restored)
    }

    @MainActor func testEditorPreservesDraftAndSupportsStatusAndDate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["storage-scope"].waitForExistence(timeout: 15))
        app.buttons["add-todo"].tap()
        let editor = app.textViews["待办内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("Keep this draft")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertEqual(editor.value as? String, "Keep this draft")
        app.buttons["todo-status"].tap()
        app.buttons["进行中"].tap()
        app.buttons["待办日期"].tap()
        app.buttons["明天"].tap()
        let selectedDate = app.buttons["待办日期"].value as? String
        XCTAssertNotNil(selectedDate)
        XCTAssertNotEqual(selectedDate, "未设置")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["Keep this draft"].waitForExistence(timeout: 5))
        app.buttons["Keep this draft"].tap()
        XCTAssertTrue(app.buttons["todo-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["todo-status"].label.contains("进行中") || app.staticTexts["进行中"].exists)
        XCTAssertEqual(app.buttons["待办日期"].value as? String, selectedDate)
        let editing = XCTAttachment(screenshot: app.screenshot()); editing.name = "iOS status and date editor"; editing.lifetime = .keepAlways; add(editing)
        app.buttons["待办日期"].tap()
        app.buttons["清除日期"].tap()
        app.buttons["保存"].tap()
        app.buttons["同步设置"].tap()
        XCTAssertTrue(app.staticTexts["当前使用本机数据"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Supabase URL"].exists)
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "iOS local account settings"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["完成"].tap()
        app.buttons["筛选与显示"].tap()
        app.buttons["已完成"].tap()
        app.buttons["add-todo"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("Visible after creating")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["Visible after creating"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["filter-summary"].label.contains("未完成"))
    }
}

extension NotoIOSUITests {
    private struct LiveFixture: Decodable {
        struct User: Decodable { let email: String; let password: String; let id: String }
        let supabaseURL: URL
        let publishableKey: String
        let powerSyncURL: URL
        let users: [User]
    }

    @MainActor func testLiveAccountSyncAndIsolation() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTO_LIVE_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set NOTO_LIVE_FIXTURE via iOS/run-live-tests.sh to run against a real test backend.")
        }
        let fixture = try JSONDecoder().decode(LiveFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThanOrEqual(fixture.users.count, 2)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-testing"]
        app.launchEnvironment = ["NOTO_SUPABASE_URL": fixture.supabaseURL.absoluteString,
                                 "NOTO_SUPABASE_KEY": fixture.publishableKey,
                                 "NOTO_POWERSYNC_URL": fixture.powerSyncURL.absoluteString]
        app.launch()
        try await login(app, user: fixture.users[0])
        let title = "iOS live " + UUID().uuidString.lowercased()
        app.buttons["add-todo"].tap()
        app.textViews["待办内容"].tap()
        app.textViews["待办内容"].typeText(title)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))

        let authData = try await request(fixture, path: "auth/v1/token?grant_type=password", body: ["email": fixture.users[0].email, "password": fixture.users[0].password])
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: authData) as? [String: Any])?["access_token"] as? String)
        var uploaded: [String: Any]?
        for _ in 0..<30 {
            let data = try await request(fixture, path: "rest/v1/noto_tasks?select=id,document&deleted=eq.false", token: token)
            uploaded = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first { ($0["document"] as? [String: Any])?["text"] as? String == title }
            if uploaded != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let record = try XCTUnwrap(uploaded, "iOS task did not upload to the real backend")
        let original = try XCTUnwrap(record["document"] as? [String: Any])
        var remote = original
        let remoteTitle = "Remote " + title
        remote["text"] = remoteTitle
        _ = try await request(fixture, path: "rest/v1/rpc/noto_apply_mutation", token: token,
                              body: ["p_mutation_id": UUID().uuidString.lowercased(), "p_task_id": try XCTUnwrap(record["id"] as? String),
                                     "p_operation": "upsert", "p_document": remote, "p_base_document": original])
        XCTAssertTrue(app.buttons[remoteTitle].waitForExistence(timeout: 35), "Remote RPC edit did not download through PowerSync")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "iOS real backend synchronized task"; screenshot.lifetime = .keepAlways; add(screenshot)
        await logout(app)
        XCTAssertFalse(app.buttons[remoteTitle].exists)
        try await login(app, user: fixture.users[0])
        XCTAssertTrue(app.buttons[remoteTitle].waitForExistence(timeout: 30), "Account task not restored after login")
        await logout(app)
        try await login(app, user: fixture.users[1])
        XCTAssertFalse(app.buttons[remoteTitle].exists, "Another account can see the first account task")
        let secondAuth = try await request(fixture, path: "auth/v1/token?grant_type=password", body: ["email": fixture.users[1].email, "password": fixture.users[1].password])
        let secondToken = try XCTUnwrap((try JSONSerialization.jsonObject(with: secondAuth) as? [String: Any])?["access_token"] as? String)
        let otherData = try await request(fixture, path: "rest/v1/noto_tasks?select=id", token: secondToken)
        let otherRows = try XCTUnwrap(try JSONSerialization.jsonObject(with: otherData) as? [[String: Any]])
        XCTAssertFalse(otherRows.contains { $0["id"] as? String == record["id"] as? String }, "RLS exposed another account task")
        await logout(app)
    }

    @MainActor private func login(_ app: XCUIApplication, user: LiveFixture.User) async throws {
        app.buttons["同步设置"].tap()
        XCTAssertTrue(app.textFields["邮箱"].waitForExistence(timeout: 5))
        app.textFields["邮箱"].tap(); app.textFields["邮箱"].typeText(user.email)
        app.secureTextFields["密码"].tap(); app.secureTextFields["密码"].typeText(user.password)
        app.buttons["登录"].tap()
        XCTAssertTrue(app.staticTexts[user.email].waitForExistence(timeout: 30), "Login did not activate account")
        app.buttons["完成"].tap()
    }

    @MainActor private func logout(_ app: XCUIApplication) async {
        app.buttons["同步设置"].tap()
        for _ in 0..<10 {
            if app.textFields["邮箱"].exists { break }
            if app.buttons["退出登录"].exists { app.buttons["退出登录"].tap() }
            try? await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(app.textFields["邮箱"].exists, "Logout did not return to local mode")
        app.buttons["完成"].tap()
    }

    private func request(_ fixture: LiveFixture, path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        let url = try XCTUnwrap(URL(string: fixture.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path))
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue(fixture.publishableKey, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), "Backend HTTP request failed")
        return data
    }
}
