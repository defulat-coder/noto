import SwiftUI
import NotoCore

// Keep the existing persisted "tasks" value for the board.
enum ContentMode: String, CaseIterable, Identifiable {
    case notes, board = "tasks", calendar
    var id: String { rawValue }
    var isTaskView: Bool { self != .notes }
    var label: String { switch self { case .notes: "记录"; case .board: "看板"; case .calendar: "日历" } }
    var icon: String { switch self { case .notes: "text.alignleft"; case .board: "rectangle.split.3x1"; case .calendar: "calendar" } }
    var shortcut: KeyEquivalent { switch self { case .notes: "1"; case .board: "2"; case .calendar: "3" } }
}

struct ViewModeMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            ForEach(ContentMode.allCases) { mode in
                Toggle(isOn: Binding(get: { model.mode == mode }, set: { if $0 { model.switchMode(mode) } })) {
                    Label(mode.label, systemImage: mode.icon)
                }.keyboardShortcut(mode.shortcut, modifiers: .command)
            }
        } label: { ActionIcon(model.mode.icon).contentShape(Rectangle()) }
            .actionMenuStyle()
            .help("当前：\(model.mode.label) · 切换视图（⌘1 / ⌘2 / ⌘3）")
            .accessibilityLabel("切换视图，当前\(model.mode.label)")
    }
}

struct TaskToolbarActions: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Button { model.setImportantOnly(!model.importantOnly) } label: {
                ActionIcon(model.importantOnly ? "star.fill" : "star")
                    .foregroundStyle(model.importantOnly ? Color.accentColor : Color.secondary)
                    .background(model.importantOnly ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(QuietButtonStyle(icon: true)).help(model.importantOnly ? "显示全部任务" : "只看重要任务")
                .accessibilityLabel("只看重要任务").accessibilityValue(model.importantOnly ? "已开启" : "已关闭")
            Button { model.showNewTask() } label: { ActionIcon("plus") }
                .buttonStyle(QuietButtonStyle(icon: true)).help("新建任务（⌘N）").accessibilityLabel("新建任务")
        }
    }
}

/// Calendar arithmetic, never UTC parsing or fixed 24-hour intervals for date-only tasks.
enum TaskDates {
    static var local: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current; calendar.firstWeekday = 2; return calendar }
    static func date(_ key: String, calendar: Calendar = local) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard key.count == 10, parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              calendar.component(.year, from: date) == parts[0], calendar.component(.month, from: date) == parts[1], calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }
    static func monthStart(_ date: Date, calendar: Calendar = local) -> Date {
        var parts = calendar.dateComponents([.year, .month], from: date); parts.day = 1; parts.hour = 12
        return calendar.date(from: parts)!
    }
    static func grid(_ date: Date, calendar: Calendar = local) -> [Date] {
        let first = monthStart(date, calendar: calendar)
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
    static func movingMonth(_ offset: Int, from date: Date, calendar: Calendar = local) -> Date {
        let target = calendar.date(byAdding: .month, value: offset, to: monthStart(date, calendar: calendar))!
        let day = min(calendar.component(.day, from: date), calendar.range(of: .day, in: .month, for: target)!.count)
        return calendar.date(byAdding: .day, value: day - 1, to: target)!
    }
}

extension AppModel {
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

struct TaskCalendar: View {
    @ObservedObject var model: AppModel
    @State private var completedExpanded = false
    private var searching: Bool { !model.search.isEmpty }
    private var displayed: [Entry] { searching ? model.calendarTasks : model.calendarDetailTasks }
    private var monthLabel: String {
        let formatter = DateFormatter(); formatter.calendar = TaskDates.local; formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: model.selectedCalendarDate)
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Text(searching ? "搜索任务" : monthLabel).font(.system(size: 18, weight: .semibold))
                    if !searching {
                        iconButton("chevron.left", "上个月") { model.moveCalendarMonth(-1) }
                        iconButton("chevron.right", "下个月") { model.moveCalendarMonth(1) }
                        iconButton("location", "回到今天") { model.selectCalendarDate(Date()) }
                    }
                    Spacer(minLength: 0)
                    TaskDropArea(onDrop: { model.rescheduleTask($0, due: nil) }) {
                        Button { model.showUnscheduled() } label: {
                            Label("未安排 \(model.calendarGroups[""]?.count ?? 0)", systemImage: "tray")
                                .font(NotoDesign.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(model.calendarUnscheduled && !searching ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(QuietButtonStyle(icon: true)).help("未安排 · 拖入任务可清除日期")
                    }.frame(width: 92, height: 28)
                    TaskToolbarActions(model: model)
                }
                if searching || model.importantOnly {
                    HStack {
                        Text("\(model.visibleTasks.count) 条匹配任务").foregroundStyle(.secondary)
                        Button("清除筛选") { model.setSearch(""); model.setImportantOnly(false) }.buttonStyle(QuietButtonStyle())
                    }.font(NotoDesign.caption)
                }
                if searching {
                    taskDetails
                } else if geometry.size.width >= 840 {
                    HStack(alignment: .top, spacing: 24) {
                        monthGrid.frame(width: 320)
                        Divider().overlay(NotoDesign.line)
                        taskDetails.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    monthGrid.frame(maxWidth: 420).frame(maxWidth: .infinity)
                    Divider().overlay(NotoDesign.line)
                    taskDetails
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
        }
    }
    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(searching ? "结果" : (model.calendarUnscheduled ? "未安排" : AppModel.dateKey(model.selectedCalendarDate)))
                    .font(.system(size: 14, weight: .semibold))
                Text("\(displayed.filter { !$0.completed }.count)").font(NotoDesign.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("\(displayed.filter { !$0.completed }.count) 个待完成任务")
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if displayed.isEmpty {
                        Text(searching ? "没有找到相关任务" : "这里还没有任务")
                            .font(NotoDesign.caption).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(displayed.filter { !$0.completed }) { entry in
                        CalendarTaskRow(entry: entry, model: model, showsDate: searching)
                    }
                    let completed = displayed.filter { $0.completed }
                    if !completed.isEmpty {
                        DisclosureGroup("已完成 \(completed.count)", isExpanded: $completedExpanded) {
                            ForEach(completed) { entry in CalendarTaskRow(entry: entry, model: model, showsDate: searching) }
                        }.font(NotoDesign.caption).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.id(searching ? "search" : (model.calendarUnscheduled ? "unscheduled" : AppModel.dateKey(model.selectedCalendarDate)))
        }
    }
    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ActionIcon(icon) }
            .buttonStyle(QuietButtonStyle(icon: true)).help(label).accessibilityLabel(label)
    }
    private var monthGrid: some View {
        let groups = model.calendarGroups
        return VStack(spacing: 4) {
            HStack {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 4), count: 7), spacing: 2) {
                ForEach(TaskDates.grid(model.selectedCalendarDate), id: \.self) { date in
                    CalendarDay(model: model, date: date, tasks: groups[AppModel.dateKey(date)] ?? []).frame(height: 36)
                }
            }
        }
    }
}

private struct CalendarDay: View {
    @ObservedObject var model: AppModel
    let date: Date
    let tasks: [Entry]
    private var selected: Bool { !model.calendarUnscheduled && TaskDates.local.isDate(date, inSameDayAs: model.selectedCalendarDate) }
    private var inMonth: Bool { TaskDates.local.isDate(date, equalTo: model.selectedCalendarDate, toGranularity: .month) }
    var body: some View {
        let openCount = tasks.filter { !$0.completed }.count
        TaskDropArea(onDrop: { model.rescheduleTask($0, due: AppModel.dateKey(date)) }) {
            Button { model.selectCalendarDate(date) } label: {
                VStack(spacing: 0) {
                    Text("\(TaskDates.local.component(.day, from: date))")
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(TaskDates.local.isDateInToday(date) ? Color.accentColor : (inMonth ? Color.primary : Color.secondary))
                    Group {
                        if openCount > 0 { Text("\(openCount)").monospacedDigit() }
                        else if !tasks.isEmpty { Image(systemName: "checkmark") }
                        else { Text(" ") }
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(AppModel.dateKey(date))，\(openCount) 待完成，\(tasks.count - openCount) 已完成")
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

private struct CalendarTaskRow: View {
    @State private var hovering = false
    let entry: Entry
    @ObservedObject var model: AppModel
    let showsDate: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.changeTask(entry, status: entry.completed ? "pending" : "completed") } label: {
                ActionIcon(entry.completed ? "checkmark.circle.fill" : (entry.status == "in_progress" ? "circle.lefthalf.filled" : "circle"))
                    .foregroundStyle(.secondary)
            }.buttonStyle(QuietButtonStyle(icon: true)).help(entry.completed ? "重新打开" : "完成任务")
                .accessibilityLabel(entry.completed ? "重新打开：\(entry.text)" : "完成：\(entry.text)")
            VStack(alignment: .leading, spacing: 4) {
                TaskCardTitle(entry: entry, lines: 2) { model.beginEditing(entry) }.padding(.top, 4)
                if showsDate { Text(entry.due ?? "未安排").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if entry.priority == "important" {
                Button { model.changeTask(entry, priority: "normal") } label: { ActionIcon("star.fill") }
                    .buttonStyle(QuietButtonStyle(icon: true)).foregroundStyle(.secondary).help("取消重要").accessibilityLabel("取消重要")
            }
            if entry.hasConversation {
                Button { model.openConversation(entry) } label: { ActionIcon("bubble.left") }
                    .buttonStyle(QuietButtonStyle(icon: true)).help("打开对话").accessibilityLabel("打开对话").disabled(model.busy)
            }
            Menu {
                Button("编辑任务") { model.beginEditing(entry) }
                Button(entry.hasConversation ? "打开对话" : "与 AI 讨论") { model.openConversation(entry) }.disabled(model.busy)
                ForEach(TodoStatus.allCases, id: \.self) { status in
                    Button(status.label) { model.changeTask(entry, status: status.rawValue) }
                }
                Button(entry.priority == "important" ? "取消重要" : "标记重要") {
                    model.changeTask(entry, priority: entry.priority == "important" ? "normal" : "important")
                }
                Divider()
                Button("删除任务", role: .destructive) { model.deleteTask(entry) }.disabled(model.busy)
            } label: { ActionIcon("ellipsis") }
                .actionMenuStyle()
                .foregroundStyle(hovering ? .primary : .secondary).help("任务操作").accessibilityLabel("任务操作")
        }
        .padding(.vertical, 7).padding(.horizontal, 4)
        .background(hovering ? Color.primary.opacity(0.025) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
