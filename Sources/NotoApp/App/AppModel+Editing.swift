import AppKit
import NotoCore

// 记录编辑与基础动作：行内编辑、新建录入、保存、撤销。
extension AppModel {
    var editDue: String? { editHasDue ? Self.dateKey(editDate) : nil }
    var editDirty: Bool { editing.map { editDraft != $0.text || editDue != $0.due || ($0.kind == "todo" && (editStatus != $0.status || editImportant != ($0.priority == "important"))) } ?? false }
    @discardableResult
    func leaveUnchangedEditor() -> Bool {
        guard !editDirty && !(taskCreating && taskDraftDirty) else {
            editError = "请先保存或取消当前编辑。"
            message = editError; isError = true
            return false
        }
        editing = nil; taskCreating = false
        return true
    }
    func showComposer(at point: CGPoint = CGPoint(x: 24, y: 40)) {
        if mode.isTaskView { showNewTask(); return }
        guard leaveUnchangedEditor() else { return }
        readingRequested = true
        composerPosition = point
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusComposer, object: nil) }
    }
    func beginEditing(_ entry: Entry) {
        if editing?.id == entry.id {
            NotificationCenter.default.post(name: .focusEditor, object: nil)
            return
        }
        guard leaveUnchangedEditor() else { return }
        composerPosition = nil
        editStatus = entry.status ?? "pending"; editImportant = entry.priority == "important"
        editing = entry; editDraft = entry.text; editError = ""; editHasDue = entry.due != nil
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        editDate = entry.due.flatMap { f.date(from: $0) } ?? Date()
    }
    func saveEditing() {
        guard let editing, !editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if editing.kind == "todo" {
            do {
                guard let store else { throw NotoError("无法打开本地数据。") }
                let changed = try store.updateTodo(id: editing.id, text: editDraft, due: editDue, clearDue: editDue == nil,
                                                   status: editStatus, priority: editImportant ? "important" : "normal", expected: editing)
                remember(before: [editing], after: [changed], message: "已更新任务。")
                if conversation?.id == changed.id { conversation = changed }
                self.editing = nil
            } catch { editError = error.localizedDescription }
        } else { update(editing, text: editDraft, due: editDue) }
    }
    func cancelEditing() { editing = nil; editError = "" }
    func setSearch(_ value: String) {
        guard leaveUnchangedEditor() else { return }
        search = value
    }
    func submitFocusedInput() {
        guard !settings, !recentlyDeleted else { return }
        if let input = NSApp.keyWindow?.firstResponder as? InputTextView { input.submit() }
        else if taskCreating { saveNewTask() }
        else if editing != nil { saveEditing() }
        else if composerPosition != nil { save() }
    }
    func remember(before: [Entry], after: [Entry], message: String) {
        undoBefore = before; undoAfter = after; undoAvailable = !after.isEmpty
        self.message = message; isError = false; convertedTaskID = nil; reload()
        sync?.kick()
    }
    func save(todo: Bool = false) {
        guard let store else { return }
        var content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let isTodo = todo || content.hasPrefix("/todo ") || content.hasPrefix("待办：")
        if content.hasPrefix("/todo ") { content = String(content.dropFirst(6)) }
        if content.hasPrefix("待办：") { content = String(content.dropFirst(3)) }
        do {
            let entry = try store.add(kind: isTodo ? "todo" : "note", text: content)
            draft = ""; composerPosition = nil
            if !search.isEmpty { search = "" }
            remember(before: [], after: [entry], message: isTodo ? "已添加任务。" : "已记下。")
        } catch { fail(error) }
    }
    func toggle(_ entry: Entry) {
        guard let store else { return }
        do {
            let changed = try store.setCompleted(id: entry.id, completed: !entry.completed, expected: entry)
            remember(before: [entry], after: [changed], message: changed.completed ? "完成了一件事。" : "已重新打开。")
        } catch { fail(error) }
    }
    func update(_ entry: Entry, text: String, due: String?) {
        do {
            guard let store else { throw NotoError("无法打开本地数据，修改尚未保存。") }
            let changed = try store.update(id: entry.id, text: text, due: due, expected: entry)
            remember(before: [entry], after: [changed], message: "已更新。")
            if conversation?.id == changed.id { conversation = changed }
            editing = nil
        } catch { editError = error.localizedDescription }
    }
    func undo() {
        guard undoAvailable else { return }
        do { try store?.undo(before: undoBefore, after: undoAfter); undoAvailable = false; convertedTaskID = nil; message = "已撤销。"; isError = false; reload() }
        catch { fail(error) }
    }
}
