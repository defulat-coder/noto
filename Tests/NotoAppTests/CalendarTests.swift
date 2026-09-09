import XCTest
import AppKit
import NotoCore
@testable import NotoApp

final class CalendarTests: XCTestCase {
    func testMonthGridLeapYearAndLocalDateArithmetic() throws {
        var calendar = TaskDates.local; calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let january = try XCTUnwrap(TaskDates.date("2024-01-31", calendar: calendar))
        let february = TaskDates.movingMonth(1, from: january, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: february), 29)
        let grid = TaskDates.grid(february, calendar: calendar)
        XCTAssertEqual(grid.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: grid[0]), 2)
        XCTAssertEqual(calendar.component(.month, from: grid[0]), 1)
        XCTAssertEqual(calendar.component(.day, from: grid[0]), 29)
        XCTAssertEqual(Set(grid).count, 42)
        XCTAssertNil(TaskDates.date("2025-02-29", calendar: calendar))
        let december = try XCTUnwrap(TaskDates.date("2025-12-31", calendar: calendar))
        XCTAssertEqual(calendar.component(.year, from: TaskDates.movingMonth(1, from: december, calendar: calendar)), 2026)
        let march = try XCTUnwrap(TaskDates.date("2026-03-15", calendar: calendar))
        let springGrid = TaskDates.grid(march, calendar: calendar)
        XCTAssertTrue(springGrid.allSatisfy { calendar.component(.hour, from: $0) == 12 })
        for offset in [-12, 14] {
            calendar.timeZone = TimeZone(secondsFromGMT: offset * 3600)!
            let day = try XCTUnwrap(TaskDates.date("2026-01-01", calendar: calendar))
            XCTAssertEqual(calendar.component(.day, from: day), 1)
            XCTAssertEqual(calendar.component(.year, from: day), 2026)
        }
    }

    func testCalendarGroupingIncludesAllCompletedAndUnscheduled() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let normal = try store.add(kind: "todo", text: "普通", due: "2026-09-09")
            let important = try store.add(kind: "todo", text: "重要", due: "2026-09-09", priority: "important")
            for i in 0..<25 { _ = try store.add(kind: "todo", text: "完成 \(i)", due: "2026-09-09", status: "completed") }
            let undated = try store.add(kind: "todo", text: "未安排", status: "completed")
            let model = AppModel(store: store); model.switchMode(.calendar)
            await model.waitForReload()
            model.selectCalendarDate(try XCTUnwrap(TaskDates.date("2026-09-09")))
            model.moveCalendarMonth(1)
            model.moveCalendarMonth(-1)
            XCTAssertEqual(model.calendarDetailTasks.count, 27)
            XCTAssertEqual(Array(model.calendarDetailTasks.prefix(2)).map(\.id), [important.id, normal.id])
            XCTAssertEqual(model.calendarGroups[""]?.map(\.id), [undated.id])
            model.setImportantOnly(true)
            XCTAssertEqual(model.calendarDetailTasks.map(\.id), [important.id])
            XCTAssertNil(model.calendarGroups[""])
            model.setImportantOnly(false); model.setSearch("未安排"); model.showUnscheduled()
            await model.waitForReload()
            XCTAssertEqual(model.calendarDetailTasks.map(\.id), [undated.id])
            model.switchMode(.board)
            await model.waitForReload()
            XCTAssertTrue(model.search.isEmpty)
            XCTAssertEqual(ContentMode(rawValue: "tasks"), .board)
            XCTAssertTrue(ContentMode.calendar.isTaskView)
        }.value
    }

    func testCreationDateDefaultsDraftRetentionAndModeGuard() async throws {
        try await Task { @MainActor in
            let model = AppModel(store: try Store(url: nil)); model.switchMode(.calendar)
            await model.waitForReload()
            model.selectCalendarDate(try XCTUnwrap(TaskDates.date("2026-12-31")))
            model.showComposer()
            XCTAssertTrue(model.taskCreating); XCTAssertTrue(model.taskDraftHasDue)
            XCTAssertEqual(AppModel.dateKey(model.taskDraftDate), "2026-12-31")
            model.taskDraft = "保留草稿"; model.taskDraftImportant = true
            model.switchMode(.notes)
            await model.waitForReload()
            XCTAssertEqual(model.mode, .calendar)
            model.taskCreating = false
            model.selectCalendarDate(try XCTUnwrap(TaskDates.date("2027-01-10")))
            model.showNewTask()
            XCTAssertEqual(AppModel.dateKey(model.taskDraftDate), "2026-12-31")
            XCTAssertTrue(model.taskDraftImportant)
            model.saveNewTask()
            await model.waitForReload()
            XCTAssertEqual(model.tasks.first?.due, "2026-12-31")
            model.showUnscheduled(); model.showNewTask()
            XCTAssertFalse(model.taskDraftHasDue)
            model.taskDraft = "无需日期"; model.saveNewTask()
            await model.waitForReload()
            XCTAssertNil(model.tasks.first { $0.text == "无需日期" }?.due)
        }.value
    }

    func testReschedulePreservesStatusAndSupportsUndoAndConflict() async throws {
        try await Task { @MainActor in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try Store(url: url), cli = try Store(url: url)
            let entry = try store.add(kind: "todo", text: "原日期", due: "2026-09-09", status: "completed", priority: "important")
            let model = AppModel(store: store); model.switchMode(.calendar)
            await model.waitForReload()
            XCTAssertTrue(model.rescheduleTask(entry, due: "2026-10-01"))
            await model.waitForReload()
            let moved = try XCTUnwrap(model.tasks.first)
            XCTAssertEqual(moved.status, entry.status); XCTAssertEqual(moved.completedAt, entry.completedAt)
            XCTAssertEqual(moved.priority, entry.priority)
            XCTAssertEqual(AppModel.dateKey(model.selectedCalendarDate), "2026-10-01")
            model.undo()
            await model.waitForReload()
            XCTAssertEqual(model.tasks.first, entry)
            XCTAssertTrue(model.rescheduleTask(entry, due: nil))
            await model.waitForReload()
            XCTAssertTrue(model.calendarUnscheduled)
            let noDate = try XCTUnwrap(model.tasks.first)
            XCTAssertNil(noDate.due)
            XCTAssertTrue(model.rescheduleTask(noDate, due: nil))
            await model.waitForReload()
            XCTAssertEqual(model.tasks.first, noDate)
            _ = try cli.updateTodo(id: entry.id, text: "CLI 修改")
            XCTAssertFalse(model.rescheduleTask(noDate, due: "2026-09-12"))
            await model.waitForReload()
            XCTAssertEqual(model.tasks.first?.text, "CLI 修改")
            XCTAssertNil(model.tasks.first?.due)
            XCTAssertFalse(model.rescheduleTask(noDate, due: "2026-02-30"))
            await model.waitForReload()
            _ = try cli.updateTodo(id: entry.id, due: "2026-09-18")
            model.refreshIfChanged()
            await model.waitForReload()
            XCTAssertEqual(model.calendarGroups["2026-09-18"]?.first?.id, entry.id)
        }.value
    }

    func testConversationSearchAndImportanceUseTheSameCalendarGroups() async throws {
        try await Task { @MainActor in
            let store = try Store(url: nil)
            let note = try store.startConversation("讨论日期分布")
            let question = try XCTUnwrap(store.messages(for: note.id).first)
            _ = try store.apply([], replyingTo: question, reply: "月历检索关键词")
            let task = try store.convertToTodo(id: note.id)
            _ = try store.updateTodo(id: task.id, due: "2026-09-09", priority: "important")
            for i in 0..<45 { _ = try store.add(kind: "note", text: "更新的笔记 \(i)") }
            let model = AppModel(store: store); model.switchMode(.calendar)
            await model.waitForReload()
            model.setSearch("月历检索关键词"); model.setImportantOnly(true)
            await model.waitForReload()
            XCTAssertEqual(model.visibleTasks.map(\.id), [task.id])
            XCTAssertEqual(model.calendarGroups["2026-09-09"]?.map(\.id), [task.id])
            XCTAssertNil(model.calendarGroups[""])
            model.switchMode(.notes)
            await model.waitForReload()
            XCTAssertTrue(model.search.isEmpty)
        }.value
    }

    func testPrivateDragTypeRejectsOrdinaryTextAndKeepsSnapshot() async throws {
        try await Task { @MainActor in
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let entry = Entry(kind: "todo", text: "拖动快照")
            let data = try JSONEncoder().encode(entry)
            pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
            XCTAssertNil(TaskDropHost.entry(from: pasteboard))
            pasteboard.clearContents(); pasteboard.setData(data, forType: .notoTask)
            XCTAssertEqual(TaskDropHost.entry(from: pasteboard), entry)
            pasteboard.clearContents(); pasteboard.setData(try JSONEncoder().encode(Entry(kind: "note", text: "笔记")), forType: .notoTask)
            XCTAssertNil(TaskDropHost.entry(from: pasteboard))
        }.value
    }
}
