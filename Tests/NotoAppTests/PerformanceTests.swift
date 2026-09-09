import XCTest
import NotoCore
@testable import NotoApp

final class PerformanceTests: XCTestCase {
    func testLargeCalendarAndTimelineReadCost() async throws {
        try await Task { @MainActor in
            let model = AppModel(store: try Store(url: nil))
            await model.waitForReload()
            let date = Date(timeIntervalSince1970: 1_780_000_000)
            model.tasks = (0..<10_000).map {
                Entry(id: "task-\($0)", kind: "todo", text: "任务 \($0)", due: "2026-09-09",
                      createdAt: date.addingTimeInterval(Double($0)), status: $0 % 3 == 0 ? "completed" : "pending")
            }
            model.entries = Array(model.tasks.prefix(2_000))
            let start = Date()
            var count = 0
            for _ in 0..<20 {
                count += model.calendarGroups["2026-09-09"]?.count ?? 0
                count += model.groups.reduce(0) { $0 + $1.entries.count }
            }
            XCTAssertEqual(count, 240_000)
            print("PERF derived views 10k tasks / 2k timeline, 20 reads: \(Date().timeIntervalSince(start) * 1000) ms")
        }.value
    }
    func testDerivedViewsInvalidateOnlyWhenTheirInputsChange() async throws {
        try await Task { @MainActor in
            let model = AppModel(store: try Store(url: nil))
            await model.waitForReload()
            let first = Entry(kind: "todo", text: "第一条", due: "2026-09-09", priority: "important")
            let second = Entry(kind: "todo", text: "第二条", status: "completed")
            model.tasks = [first, second]; model.entries = [first]
            XCTAssertEqual(model.calendarGroups[""]?.first, second)
            XCTAssertEqual(model.taskColumns["pending"]?.first, first)
            XCTAssertEqual(model.groups.flatMap(\.entries), [first])
            model.draft = "输入不应改变数据分组"
            XCTAssertEqual(model.calendarTasks.count, 2)
            model.importantOnly = true
            XCTAssertEqual(model.visibleTasks, [first])
            XCTAssertNil(model.calendarGroups[""])
            XCTAssertNil(model.taskColumns["completed"])
            model.tasks = [second]
            XCTAssertTrue(model.calendarTasks.isEmpty)
            model.importantOnly = false
            XCTAssertEqual(model.calendarGroups[""]?.first, second)
            model.editing = second
            XCTAssertEqual(Set(model.groups.flatMap(\.entries).map(\.id)), Set([first.id, second.id]))
            model.editing = nil; model.entries = []
            XCTAssertTrue(model.groups.isEmpty)
        }.value
    }

    func testLatestSearchWinsAndOldPaginationCannotAppend() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            for i in 0..<85 { _ = try store.add(kind: "note", text: "笔记 \(i)") }
            let task = try store.add(kind: "todo", text: "任务目标")
            let model = AppModel(store: store)
            await model.waitForReload()
            XCTAssertEqual(model.entries.count, 40)
            XCTAssertTrue(model.tasks.isEmpty, "Notes must not load the task archive")
            model.loadMore(); model.loadMore()
            await model.waitForReload()
            XCTAssertEqual(model.entries.count, 80)
            XCTAssertEqual(Set(model.entries.map(\.id)).count, 80)
            model.loadMore()
            model.setSearch("笔记")
            model.setSearch("不存在")
            model.setSearch("任务目标")
            await model.waitForReload()
            XCTAssertEqual(model.entries.map(\.id), [task.id])
            XCTAssertFalse(model.loadingMore)
            XCTAssertFalse(model.hasMore)
            model.setSearch("不存在")
            model.switchMode(.calendar)
            await model.waitForReload()
            XCTAssertEqual(model.tasks.map(\.id), [task.id])
            XCTAssertTrue(model.search.isEmpty)
            XCTAssertFalse(model.reloading)
        }.value
    }

}
