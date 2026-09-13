import SwiftUI
import AppKit
import NotoCore

extension AppModel {
    var visibleTasks: [Entry] {
        if let cachedVisibleTasks { return cachedVisibleTasks }
        let result = importantOnly ? tasks.filter { $0.priority == "important" } : tasks
        cachedVisibleTasks = result
        return result
    }
    var taskColumns: [String: [Entry]] {
        if let cachedTaskColumns { return cachedTaskColumns }
        let result = Dictionary(grouping: visibleTasks, by: { $0.status ?? "pending" })
        cachedTaskColumns = result
        return result
    }
    var taskDraftDirty: Bool { !taskDraft.isEmpty || taskDraftImportant || taskDraftHasDue }

    func switchMode(_ value: ContentMode) {
        guard value != mode, leaveUnchangedEditor() else { return }
        composerPosition = nil; readingRequested = true
        mode = value; completedLimit = 20
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
        if !taskDraftStarted {
            taskDraftStatus = status
            taskDraftHasDue = mode == .calendar && !calendarUnscheduled
            taskDraftDate = selectedCalendarDate
        }
        taskDraftStarted = true; editError = ""; taskCreating = true
    }

    func saveNewTask() {
        guard !taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            guard let store else { throw NotoError("无法打开本地数据，草稿已保留。") }
            let entry = try store.add(kind: "todo", text: taskDraft,
                                      due: taskDraftHasDue ? Self.dateKey(taskDraftDate) : nil,
                                      status: taskDraftStatus, priority: taskDraftImportant ? "important" : "normal")
            taskCreating = false; taskDraftStarted = false; taskDraft = ""; taskDraftHasDue = false; taskDraftImportant = false
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


}

struct TaskCompletionButton: View {
    let entry: Entry
    @ObservedObject var model: AppModel
    var body: some View {
        Button { model.changeTask(entry, status: entry.completed ? "pending" : "completed") } label: {
            ActionIcon(entry.completed ? "checkmark.circle.fill" : entry.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
                .contentTransition(.symbolEffect(.replace))
                .animation(NotoMotion.animation(.feedback), value: entry.status)
                .foregroundStyle(entry.completed ? Color.accentColor : Color.secondary)
        }.buttonStyle(QuietButtonStyle(icon: true)).help(entry.completed ? "重新打开" : "完成任务")
            .accessibilityLabel(entry.completed ? "重新打开：\(entry.text)" : "完成：\(entry.text)")
    }
}

struct TaskBoard: View {
    @ObservedObject var model: AppModel
    @State private var column: TodoStatus = .pending
    @State private var revealedTaskID: String?
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            VStack(alignment: .leading, spacing: 16) {
                if compact {
                    HStack(spacing: 4) {
                        ForEach(TodoStatus.allCases, id: \.self) { status in
                            TaskDropArea(onDrop: { entry in
                                guard model.changeTask(entry, status: status.rawValue) else { return false }
                                column = status; return true
                            }) {
                                Button { column = status } label: {
                                    HStack(spacing: 6) {
                                        Text(status.label)
                                        Text("\(model.taskColumns[status.rawValue]?.count ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                                    }.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                        .background {
                                            if column == status {
                                                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07))
                                            }
                                        }
                                        .animation(NotoMotion.animation(.navigation), value: column == status)
                                }.buttonStyle(NavigationButtonStyle(minHeight: 32)).accessibilityLabel("显示\(status.label)")
                                    .accessibilityAddTraits(column == status ? .isSelected : [])
                                    .help("显示\(status.label)；拖入任务可更改状态")
                            }.frame(maxWidth: .infinity).frame(height: 32)
                        }
                    }
                }
                if model.importantOnly || !model.search.isEmpty {
                    HStack {
                        Text("\(model.visibleTasks.count) 个匹配任务").foregroundStyle(.secondary)
                        Button("清除筛选") { model.setSearch(""); model.setImportantOnly(false) }
                    }.font(NotoDesign.caption)
                }
                if compact {
                    ZStack { TaskColumn(model: model, status: column, showsHeading: false).id(column).transition(.opacity) }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(TodoStatus.allCases, id: \.self) { status in TaskColumn(model: model, status: status) }
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 16)
                .animation(NotoMotion.animation(.navigation), value: column)
        }
        .onChange(of: model.tasks) { _, tasks in revealNewTask(in: tasks) }
        .onChange(of: model.highlightedTaskID) { _, _ in revealNewTask(in: model.tasks) }
    }
    private func revealNewTask(in tasks: [Entry]) {
        guard let id = model.highlightedTaskID, id != revealedTaskID,
              let task = tasks.first(where: { $0.id == id }), let status = TodoStatus(rawValue: task.status ?? "pending") else { return }
        column = status; revealedTaskID = id
    }
}


private struct TaskColumn: View {
    @ObservedObject var model: AppModel
    let status: TodoStatus
    var showsHeading = true
    private var tasks: [Entry] { model.taskColumns[status.rawValue] ?? [] }
    private var displayed: [Entry] { status == .completed ? Array(tasks.prefix(model.completedLimit)) : tasks }
    var body: some View {
        TaskDropArea(onDrop: { model.changeTask($0, status: status.rawValue) }) {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                HStack(spacing: 8) {
                    Text(status.label).font(.system(size: 13, weight: .medium))
                    Text("\(tasks.count)").font(NotoDesign.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText()).animation(NotoMotion.animation(.feedback), value: tasks.count)
                    Spacer()
                }.frame(height: 28)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if displayed.isEmpty { Text("暂无\(status.label)任务").font(NotoDesign.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24) }
                    ForEach(displayed) { entry in
                        TaskCard(entry: entry, model: model).transition(.opacity.combined(with: .scale(scale: 0.985)))
                    }
                    if displayed.count < tasks.count {
                        Button("加载更多") { model.completedLimit += 20 }
                            .buttonStyle(QuietButtonStyle()).font(NotoDesign.caption).padding(.vertical, 10)
                    }
                }.padding(2)
                    .animation(NotoMotion.animation(.layout), value: displayed.map(\.id))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())

        }
    }
}

struct TaskCard: View {
    let entry: Entry
    @ObservedObject var model: AppModel
    private var important: Bool { entry.priority == "important" }
    private var overdue: Bool { !entry.completed && (entry.due.map { $0 < AppModel.dateKey(Date()) } ?? false) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                TaskCompletionButton(entry: entry, model: model)
                TaskCardTitle(entry: entry) { model.beginEditing(entry) }.padding(.top, 4)
            }
            HStack(spacing: 4) {
                if important {
                Button { model.changeTask(entry, priority: important ? "normal" : "important") } label: {
                    ActionIcon(important ? "star.fill" : "star")
                        .foregroundStyle(important ? Color.accentColor : Color.secondary)
                }.buttonStyle(QuietButtonStyle(icon: true)).help(important ? "取消重要" : "标记重要")
                    .accessibilityLabel(important ? "取消重要" : "标记重要")
                }
                if let due = entry.due {
                    Text(overdue ? "已逾期 · \(due)" : (due == AppModel.dateKey(Date()) && !entry.completed ? "今天到期" : due))
                        .font(.system(size: 11)).foregroundStyle(overdue ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if entry.hasConversation {
                    Button { model.openConversation(entry) } label: {
                        ActionIcon("bubble.left")
                    }.buttonStyle(QuietButtonStyle(icon: true)).help("打开对话").accessibilityLabel("打开对话").disabled(model.busy)
                }
                Menu {
                    Button("编辑任务") { model.beginEditing(entry) }
                    Button(entry.hasConversation ? "打开对话" : "与 AI 讨论") { model.openConversation(entry) }.disabled(model.busy)
                    ForEach(TodoStatus.allCases, id: \.self) { status in
                        Button { model.changeTask(entry, status: status.rawValue) } label: {
                            if entry.status == status.rawValue { Label(status.label, systemImage: "checkmark") }
                            else { Text(status.label) }
                        }
                    }
                    Button(important ? "取消重要" : "标记重要") { model.changeTask(entry, priority: important ? "normal" : "important") }
                    Divider()
                    Button("删除任务", role: .destructive) { model.deleteTask(entry) }.disabled(model.busy)
                } label: { ActionIcon("ellipsis") }
                    .actionMenuStyle().help("任务操作").accessibilityLabel("任务操作")
            }.padding(.leading, 34)
        }
        .padding(12)
        .background(model.highlightedTaskID == entry.id ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture { model.beginEditing(entry) }
    }
}

struct TaskEditor: View {
    @ObservedObject var model: AppModel
    private var creating: Bool { model.taskCreating }
    private var text: Binding<String> { creating ? $model.taskDraft : $model.editDraft }
    private var status: Binding<String> { creating ? $model.taskDraftStatus : $model.editStatus }
    private var important: Binding<Bool> { creating ? $model.taskDraftImportant : $model.editImportant }
    private var hasDue: Binding<Bool> { creating ? $model.taskDraftHasDue : $model.editHasDue }
    private var date: Binding<Date> { creating ? $model.taskDraftDate : $model.editDate }
    private func save() { if creating { model.saveNewTask() } else { model.saveEditing() } }
    private func cancel() { model.taskCreating = false; model.cancelEditing() }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(creating ? "新建任务" : "编辑任务").font(.system(size: 18, weight: .semibold))
            Composer(text: text, enabled: true, purpose: .edit, onSubmit: save, onCancel: cancel, placeholder: "写下要做的事…")
                .frame(minHeight: 64, maxHeight: 140).padding(12)
                .background(NotoDesign.field, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                TaskDateControl(hasDue: hasDue, date: date)
                Button { important.wrappedValue.toggle() } label: {
                    ActionIcon(important.wrappedValue ? "star.fill" : "star")
                }.buttonStyle(QuietButtonStyle(icon: true)).foregroundStyle(important.wrappedValue ? Color.accentColor : Color.secondary)
                    .help(important.wrappedValue ? "取消重要" : "标记重要")
                    .accessibilityLabel("重要任务").accessibilityValue(important.wrappedValue ? "已开启" : "已关闭")
                Spacer()
                Picker("状态", selection: status) {
                        ForEach(TodoStatus.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 120).accessibilityLabel("任务状态")
            }
            if !model.editError.isEmpty {
                Label(model.editError, systemImage: "exclamationmark.circle").font(NotoDesign.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", action: cancel).buttonStyle(QuietButtonStyle())
                Button("保存", action: save).buttonStyle(QuietButtonStyle(prominent: true)).help("保存（⌘↵）；回车换行")
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
        .background(NotoGlassSurface(radius: 20))
        .interactiveDismissDisabled(model.editDirty || (creating && model.taskDraftDirty))
        .onExitCommand(perform: cancel)
    }
}

/// One optional date entry, shared by task creation and editing.
struct TaskDateControl: View {
    @Binding var hasDue: Bool
    @Binding var date: Date
    @State private var open = false
    @State private var choosing = false
    @State private var selectedDate = Date()
    private var label: String {
        guard hasDue else { return "日期" }
        let formatter = DateFormatter(); formatter.calendar = TaskDates.local; formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
    private func choose(_ value: Date) { date = value; hasDue = true; open = false }
    var body: some View {
        Button { choosing = false; selectedDate = date; open.toggle() } label: {
            Label(label, systemImage: "calendar")
        }.buttonStyle(QuietButtonStyle()).help(hasDue ? "修改或清除截止日期" : "设置截止日期")
            .accessibilityLabel(hasDue ? "截止日期 \(AppModel.dateKey(date))" : "设置截止日期")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("今天") { choose(Date()) }
                    Button("明天") { choose(TaskDates.local.date(byAdding: .day, value: 1, to: Date())!) }
                    Button("选择日期…") { choosing = true }
                    if choosing {
                        DatePicker("截止日期", selection: $selectedDate, displayedComponents: .date).datePickerStyle(.graphical)
                        Button("确定") { choose(selectedDate) }
                    }
                    Color.clear.frame(height: 6)
                    Button("清除日期") { hasDue = false; open = false }.disabled(!hasDue)
                }.buttonStyle(QuietButtonStyle()).padding(12)
            }
    }
}
