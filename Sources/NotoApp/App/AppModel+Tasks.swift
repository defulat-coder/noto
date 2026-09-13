import Foundation
import NotoCore

struct TaskDraftAttributes: Equatable {
    var status = "pending"
    var important = false
    var due: String?
}

// 任务域：删除恢复、看板筛选与草稿、日历选择与重排。
extension AppModel {
    func deleteTask(_ entry: Entry) {
        guard !busy, leaveUnchangedEditor(), let store else { return }
        let unsentQuestion = conversation?.id == entry.id ? chatDraft : chatDrafts[entry.id] ?? ""
        if !unsentQuestion.isEmpty {
            fail(NotoError("请先发送或清空这条任务的对话草稿。")); return
        }
        do {
            try store.deleteTodo(id: entry.id, expected: entry)
            lastDeletedTaskID = entry.id
            if conversation?.id == entry.id { conversation = nil; messages = []; chatDraft = ""; readingRequested = true }
            chatDrafts.removeValue(forKey: entry.id)
            message = "已删除任务，可恢复上次删除。"; isError = false; reload()
            sync?.kick()
        } catch { fail(error) }
    }

    func restoreLastDeletedTask() {
        guard let id = lastDeletedTaskID else { return }
        do { try restoreTask(id) } catch { fail(error) }
    }
    func restoreTask(_ id: String) throws {
        guard let store else { throw NotoError("无法打开本地数据。") }
        try store.restoreTodo(id: id)
        if lastDeletedTaskID == id { lastDeletedTaskID = nil }
        message = "已恢复任务。"; isError = false; reload()
        sync?.kick()
    }

    /// 最近删除列表：读取走 AppModel，按当前 store 身份丢弃过期结果。
    func deletedTasks() async -> [Entry] {
        guard let store else { return [] }
        let result = (try? await Task.detached(priority: .utility) { try store.deletedTodos() }.value) ?? []
        guard store === self.store else { return [] }
        return result
    }

    var visibleTasks: [Entry] {
        if let cachedVisibleTasks { return cachedVisibleTasks }
        let result = tasks.filter {
            (!importantOnly || $0.priority == "important") &&
            (!dueOnly || (!$0.completed && ($0.due.map { $0 <= Self.dateKey(Date()) } ?? false)))
        }
        cachedVisibleTasks = result
        return result
    }
    var taskColumns: [String: [Entry]] {
        if let cachedTaskColumns { return cachedTaskColumns }
        let result = Dictionary(grouping: visibleTasks, by: { $0.status ?? "pending" })
        cachedTaskColumns = result
        return result
    }
    var taskDraftAttributes: TaskDraftAttributes {
        TaskDraftAttributes(status: taskDraftStatus, important: taskDraftImportant,
                            due: taskDraftHasDue ? Self.dateKey(taskDraftDate) : nil)
    }
    var taskDraftDirty: Bool { !taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || taskDraftAttributes != taskDraftBaseline }

    func showDueTasks() {
        guard leaveUnchangedEditor() else { return }
        switchMode(.board)
        importantOnly = false; search = ""; dueOnly = true
    }

    func switchMode(_ value: ContentMode) {
        guard value != mode, leaveUnchangedEditor() else { return }
        composerPosition = nil; readingRequested = true
        mode = value; dueOnly = false; completedLimit = 20
        if search.isEmpty { reload(reset: true) } else { search = "" }
    }

    func setImportantOnly(_ value: Bool) {
        guard leaveUnchangedEditor() else { return }
        importantOnly = value; completedLimit = 20
    }

    func showNewTask(status: String = "pending") {
        if taskCreating { return }
        guard leaveUnchangedEditor() else { return }
        composerPosition = nil; readingRequested = true
        taskDraftRestored = taskDraftStarted && taskDraftDirty
        if !taskDraftRestored {
            taskDraftStatus = status
            taskDraftHasDue = mode == .calendar && !calendarUnscheduled
            taskDraftDate = selectedCalendarDate
            taskDraftImportant = false
            taskDraftBaseline = taskDraftAttributes
        }
        taskDraftStarted = true; editError = ""; taskCreating = true
    }

    /// A fresh quick-entry adopts the clicked context; reopening a draft preserves its choices.
    func quickCreateTask(status: String = "pending", date: Date? = nil) {
        guard !taskCreating, !settings, !recentlyDeleted else { return }
        let resuming = taskDraftStarted && taskDraftDirty
        showNewTask(status: status)
        guard taskCreating, !resuming else { return }
        taskDraftHasDue = date != nil
        if let date { taskDraftDate = date }
        taskDraftImportant = importantOnly
        taskDraftBaseline = taskDraftAttributes
    }

    func saveNewTask() {
        guard !taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            guard let store else { throw NotoError("无法打开本地数据，草稿已保留。") }
            let entry = try store.add(kind: "todo", text: taskDraft,
                                      due: taskDraftHasDue ? Self.dateKey(taskDraftDate) : nil,
                                      status: taskDraftStatus, priority: taskDraftImportant ? "important" : "normal")
            taskCreating = false; taskDraftStarted = false; taskDraft = ""; taskDraftHasDue = false; taskDraftImportant = false; taskDraftStatus = "pending"; taskDraftBaseline = TaskDraftAttributes(); taskDraftRestored = false
            dueOnly = false
            if !search.isEmpty { search = "" }
            if importantOnly && entry.priority != "important" { importantOnly = false }
            remember(before: [], after: [entry], message: "已添加任务。")
            highlightedTaskID = entry.id
            if mode == .calendar {
                if let due = entry.due, let date = TaskDates.date(due) { selectedCalendarDate = date; calendarUnscheduled = false }
                else { calendarUnscheduled = true }
            }
        } catch { editError = error.localizedDescription }
    }

    @discardableResult
    func changeTask(_ entry: Entry, status: String? = nil, priority: String? = nil, due: String? = nil, clearDue: Bool = false) -> Bool {
        guard leaveUnchangedEditor() else { return false }
        do {
            guard let store else { throw NotoError("无法打开本地数据。") }
            let changed = try store.updateTodo(id: entry.id, due: due, clearDue: clearDue, status: status, priority: priority, expected: entry)
            if changed != entry {
                remember(before: [entry], after: [changed], message: "已更新任务。")
                if conversation?.id == entry.id { conversation = changed }
            }
            return true
        } catch { fail(error); reload(); return false }
    }

    func convertToTask(_ entry: Entry) {
        guard leaveUnchangedEditor() else { return }
        do {
            guard let store else { throw NotoError("无法打开本地数据。") }
            let changed = try store.convertToTodo(id: entry.id, expected: entry)
            remember(before: [entry], after: [changed], message: "已转为任务。")
            convertedTaskID = changed.id
            if conversation?.id == changed.id { conversation = changed }
        } catch { fail(error) }
    }

    func showConvertedTask() {
        guard let id = convertedTaskID, leaveUnchangedEditor() else { return }
        importantOnly = false; highlightedTaskID = id; taskToEditAfterReload = id
        if mode == .board { reload(reset: true) } else { switchMode(.board) }
    }

    var calendarTasks: [Entry] {
        if let cachedCalendarTasks { return cachedCalendarTasks }
        let result = visibleTasks.sorted {
            if $0.completed != $1.completed { return !$0.completed }
            if $0.priority != $1.priority { return $0.priority == "important" }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
        cachedCalendarTasks = result
        return result
    }
    var calendarGroups: [String: [Entry]] {
        if let cachedCalendarGroups { return cachedCalendarGroups }
        let result = Dictionary(grouping: calendarTasks, by: { $0.due ?? "" })
        cachedCalendarGroups = result
        return result
    }
    var calendarDetailTasks: [Entry] { calendarGroups[calendarUnscheduled ? "" : Self.dateKey(selectedCalendarDate)] ?? [] }
    func selectCalendarDate(_ date: Date) {
        guard leaveUnchangedEditor() else { return }
        selectedCalendarDate = date; calendarUnscheduled = false
    }
    func moveCalendarMonth(_ offset: Int) { selectCalendarDate(TaskDates.movingMonth(offset, from: selectedCalendarDate)) }
    func showUnscheduled() { guard leaveUnchangedEditor() else { return }; calendarUnscheduled = true }
    @discardableResult
    func rescheduleTask(_ entry: Entry, due: String?) -> Bool {
        guard due == nil || TaskDates.date(due!) != nil else { return false }
        guard changeTask(entry, due: due, clearDue: due == nil) else { return false }
        if let due, let date = TaskDates.date(due) { selectedCalendarDate = date; calendarUnscheduled = false }
        else { calendarUnscheduled = true }
        highlightedTaskID = entry.id
        return true
    }
}
