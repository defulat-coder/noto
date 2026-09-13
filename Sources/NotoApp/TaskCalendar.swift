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

struct ImportantTaskFilter: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Button { model.setImportantOnly(!model.importantOnly) } label: {
                ActionIcon(model.importantOnly ? "star.fill" : "star")
                    .foregroundStyle(model.importantOnly ? Color.accentColor : Color.secondary)
                    .background(model.importantOnly ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(QuietButtonStyle(icon: true)).help(model.importantOnly ? "显示全部任务" : "只看重要任务")
                .accessibilityLabel("只看重要任务").accessibilityValue(model.importantOnly ? "已开启" : "已关闭")
        }
    }
}

/// Calendar arithmetic, never UTC parsing or fixed 24-hour intervals for date-only tasks.
enum TaskDates {
    static var local: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current; calendar.firstWeekday = 2; return calendar }
    static func taskLabel(_ key: String, completed: Bool = false, today: Date = Date()) -> String {
        guard let value = date(key) else { return key }
        let formatter = DateFormatter(); formatter.calendar = local
        formatter.dateFormat = local.isDate(value, equalTo: today, toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        if completed { return formatter.string(from: value) }
        if local.isDate(value, inSameDayAs: today) { return "今天" }
        if let tomorrow = local.date(byAdding: .day, value: 1, to: today), local.isDate(value, inSameDayAs: tomorrow) { return "明天" }
        return value < local.startOfDay(for: today) ? "已逾期 · " + formatter.string(from: value) : formatter.string(from: value)
    }
    @MainActor static func dayHeading(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = local; formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return taskLabel(AppModel.dateKey(date), completed: date < local.startOfDay(for: Date())) + " · " + formatter.string(from: date)
    }
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
    @State private var occupied: [CGRect] = []
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
                        .contentTransition(.opacity).animation(NotoMotion.animation(.navigation), value: monthLabel)
                    if !searching {
                        iconButton("chevron.left", "上个月") { model.moveCalendarMonth(-1) }
                        iconButton("chevron.right", "下个月") { model.moveCalendarMonth(1) }
                        iconButton("location", "回到今天") { model.selectCalendarDate(Date()) }
                    }
                    Spacer(minLength: 0)
                    ImportantTaskFilter(model: model)
                    TaskDropArea(onDrop: { model.rescheduleTask($0, due: nil) }) {
                        Button { model.showUnscheduled() } label: {
                            Label("未安排 \(model.calendarGroups[""]?.count ?? 0)", systemImage: "tray")
                                .font(NotoDesign.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(model.calendarUnscheduled && !searching ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(QuietButtonStyle(icon: true)).help("未安排 · 拖入任务可清除日期")
                    }.frame(width: 92, height: 28)
                }
                if searching || model.importantOnly {
                    HStack {
                        Text("\(model.visibleTasks.count) 条匹配任务").foregroundStyle(.secondary)
                        Button("清除筛选") { model.setSearch(""); model.setImportantOnly(false) }.buttonStyle(QuietButtonStyle())
                    }.font(NotoDesign.caption)
                }
                if searching {
                    animatedDetails
                } else if geometry.size.width >= 840 {
                    HStack(alignment: .top, spacing: 24) {
                        monthGrid.padding(16).frame(width: 352)
                        animatedDetails.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    monthGrid.padding(16).frame(maxWidth: 452).frame(maxWidth: .infinity)
                    Color.clear.frame(height: 12)
                    animatedDetails
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
        }
    }
    private var detailIdentity: String { searching ? "search" : model.calendarUnscheduled ? "unscheduled" : AppModel.dateKey(model.selectedCalendarDate) }
    private var animatedDetails: some View {
        ZStack(alignment: .topLeading) { taskDetails.id(detailIdentity).transition(.opacity) }
            .animation(NotoMotion.animation(.navigation), value: detailIdentity)
    }
    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(searching ? "结果" : (model.calendarUnscheduled ? "未安排" : TaskDates.dayHeading(model.selectedCalendarDate)))
                    .font(.system(size: 14, weight: .semibold))
                Text("\(displayed.filter { !$0.completed }.count) 项待办").font(NotoDesign.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("\(displayed.filter { !$0.completed }.count) 个待完成任务")
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if displayed.isEmpty {
                        Button(searching ? "没有匹配任务 · 新建" : "添加任务") {
                            model.quickCreateTask(date: searching || model.calendarUnscheduled ? nil : model.selectedCalendarDate)
                        }.buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).padding(.vertical, 16)
                            .excludeFromBlankInput(in: "calendar-details")
                    }
                    ForEach(displayed.filter { !$0.completed }) { entry in
                        CalendarTaskRow(entry: entry, model: model, showsDate: searching).excludeFromBlankInput(in: "calendar-details").transition(.opacity)
                    }
                    let completed = displayed.filter { $0.completed }
                    if !completed.isEmpty {
                        DisclosureGroup("已完成 \(completed.count)", isExpanded: $completedExpanded) {
                            ForEach(completed) { entry in CalendarTaskRow(entry: entry, model: model, showsDate: searching) }
                        }.font(NotoDesign.caption).foregroundStyle(.secondary).padding(.top, 12).excludeFromBlankInput(in: "calendar-details")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .animation(NotoMotion.animation(.layout), value: displayed.filter { !$0.completed }.map(\.id))
                    .animation(NotoMotion.animation(.layout), value: completedExpanded)
            }.id(searching ? "search" : (model.calendarUnscheduled ? "unscheduled" : AppModel.dateKey(model.selectedCalendarDate)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "calendar-details")
        .onPreferenceChange(OccupiedAreas.self) { occupied = $0 }
        .background(BlankClickObserver(excluded: occupied, floatingRect: nil,
            onDoubleClick: { _ in
                model.quickCreateTask(date: searching || model.calendarUnscheduled ? nil : model.selectedCalendarDate)
            }, onOutsideClick: {}))
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
            Button { if !model.taskCreating { model.selectCalendarDate(date) } } label: {
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
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    model.quickCreateTask(date: date)
                })
                .help("单击查看任务，双击新建当天任务")
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
            TaskCompletionButton(entry: entry, model: model)
            VStack(alignment: .leading, spacing: 4) {
                TaskCardTitle(entry: entry, lines: 2) { model.beginEditing(entry) }.padding(.top, 4)
                HStack(spacing: 8) {
                    if showsDate { Text(entry.due.map { TaskDates.taskLabel($0, completed: entry.completed) } ?? "未安排").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if entry.hasConversation { ConversationShortcut(entry: entry, model: model, compact: true) }
                }
            }
            if entry.priority == "important" {
                Button { model.changeTask(entry, priority: "normal") } label: { ActionIcon("star.fill") }
                    .buttonStyle(QuietButtonStyle(icon: true)).foregroundStyle(.secondary).help("取消重要").accessibilityLabel("取消重要")
            }
            if !entry.hasConversation { ConversationShortcut(entry: entry, model: model, revealed: hovering) }
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
        .animation(NotoMotion.hover, value: hovering)
    }
}
