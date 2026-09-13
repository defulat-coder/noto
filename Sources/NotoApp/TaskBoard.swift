import SwiftUI
import AppKit
import NotoCore

struct TaskDraftAttributes: Equatable {
    var status = "pending"
    var important = false
    var due: String?
}

extension AppModel {
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
                HStack(spacing: 4) {
                    if compact && !model.dueOnly {
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
                    } else { Spacer() }
                    ImportantTaskFilter(model: model)
                }
                if model.dueOnly || model.importantOnly || !model.search.isEmpty {
                    HStack {
                        Text(model.dueOnly ? "到期待办 · \(model.visibleTasks.count) 项" : "\(model.visibleTasks.count) 个匹配任务").foregroundStyle(.secondary)
                        Button("清除筛选") { model.setSearch(""); model.setImportantOnly(false); model.dueOnly = false }
                    }.font(NotoDesign.caption)
                }
                if model.dueOnly {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if model.visibleTasks.isEmpty { Text("暂无到期待办").font(NotoDesign.caption).foregroundStyle(.secondary).padding(24) }
                            ForEach(model.visibleTasks) { entry in TaskCard(entry: entry, model: model) }
                        }.frame(maxWidth: 620).frame(maxWidth: .infinity)
                    }
                } else if compact {
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
    @State private var occupied: [CGRect] = []
    private var inputSpace: String { "board-" + status.rawValue }
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
                    if displayed.isEmpty { Button("添加任务") { model.quickCreateTask(status: status.rawValue) }.buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24).excludeFromBlankInput(in: inputSpace) }
                    ForEach(displayed) { entry in
                        TaskCard(entry: entry, model: model).excludeFromBlankInput(in: inputSpace).transition(.opacity.combined(with: .scale(scale: 0.985)))
                    }
                    if displayed.count < tasks.count {
                        Button("加载更多") { model.completedLimit += 20 }
                            .buttonStyle(QuietButtonStyle()).font(NotoDesign.caption).padding(.vertical, 10).excludeFromBlankInput(in: inputSpace)
                    }
                }.padding(2)
                    .animation(NotoMotion.animation(.layout), value: displayed.map(\.id))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .coordinateSpace(name: inputSpace)
        .onPreferenceChange(OccupiedAreas.self) { occupied = $0 }
        .background(BlankClickObserver(excluded: occupied, floatingRect: nil,
            onDoubleClick: { _ in model.quickCreateTask(status: status.rawValue) }, onOutsideClick: {}))

        }
    }
}

struct TaskCard: View {
    @State private var hovering = false
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
                    Text(TaskDates.taskLabel(due, completed: entry.completed))
                        .font(.system(size: 11)).foregroundStyle(overdue ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.hasConversation { ConversationShortcut(entry: entry, model: model, compact: true) }
                Spacer(minLength: 0)
                if !entry.hasConversation { ConversationShortcut(entry: entry, model: model, revealed: hovering) }
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
        .onHover { hovering = $0 }
    }
}

struct TaskEditor: View {
    @State private var confirmClose = false
    @ObservedObject var model: AppModel
    private var creating: Bool { model.taskCreating }
    private var text: Binding<String> { creating ? $model.taskDraft : $model.editDraft }
    private var status: Binding<String> { creating ? $model.taskDraftStatus : $model.editStatus }
    private var important: Binding<Bool> { creating ? $model.taskDraftImportant : $model.editImportant }
    private var hasDue: Binding<Bool> { creating ? $model.taskDraftHasDue : $model.editHasDue }
    private var date: Binding<Date> { creating ? $model.taskDraftDate : $model.editDate }
    private func save() { if creating { model.saveNewTask() } else { model.saveEditing() } }
    private func cancel() {
        if !creating && model.editDirty { confirmClose = true }
        else { model.taskCreating = false; model.cancelEditing() }
    }
    private var attributesLabel: String {
        let state = TodoStatus(rawValue: status.wrappedValue)?.label ?? "待开始"
        return status.wrappedValue == "pending" ? (important.wrappedValue ? "重要" : "更多") : state
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(creating ? (model.taskDraftRestored ? "继续草稿" : "新建任务") : "编辑任务")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(action: cancel) { ActionIcon("xmark") }
                    .buttonStyle(QuietButtonStyle(icon: true))
                    .help(creating ? "收起，保留草稿（Esc）" : "取消编辑（Esc）")
                    .accessibilityLabel(creating ? "收起新建任务，保留草稿" : "取消编辑")
            }
            Composer(text: text, enabled: true, purpose: .edit, onSubmit: save, onCancel: cancel, placeholder: "想做什么？")
                .frame(minHeight: 48).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18).padding(.bottom, 22)
            if !model.editError.isEmpty {
                Label(model.editError, systemImage: "exclamationmark.circle")
                    .font(NotoDesign.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
            HStack(spacing: 4) {
                TaskDateControl(hasDue: hasDue, date: date)
                Menu {
                    Toggle("重要任务", isOn: important)
                    Divider()
                    Picker("状态", selection: status) {
                        ForEach(TodoStatus.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }.pickerStyle(.inline)
                } label: {
                    Label(attributesLabel, systemImage: important.wrappedValue ? "star.fill" : "ellipsis")
                        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
                        .foregroundStyle(important.wrappedValue ? Color.accentColor : Color.secondary)
                }.actionMenuStyle().accessibilityLabel("任务属性")
                    .accessibilityValue("\(TodoStatus(rawValue: status.wrappedValue)?.label ?? "待开始")，\(important.wrappedValue ? "重要" : "普通")")
                    .help("设置重要标记和任务状态")
                Spacer(minLength: 12)
                Button(creating ? "创建" : "保存", action: save)
                    .buttonStyle(QuietButtonStyle(prominent: true)).help("⌘↵ 保存；回车换行")
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
        .background(NotoGlassSurface(radius: 20))
        .interactiveDismissDisabled(model.editDirty || (creating && model.taskDraftDirty))
        .onExitCommand(perform: cancel)
        .alert("保存任务修改？", isPresented: $confirmClose) {
            Button("保存") { save() }.disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("放弃修改", role: .destructive) { model.cancelEditing() }
            Button("继续编辑", role: .cancel) { }
        } message: { Text("关闭前可以保存修改，或继续编辑。") }
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
