import SwiftUI
import AppKit
import NotoCore
import NotoSync
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [Entry] = [] { didSet { cachedGroups = nil } }
    @Published var tasks: [Entry] = [] { didSet { invalidateTaskViews() } }
    @Published var mode: ContentMode = .notes { didSet { if persistsViewMode { UserDefaults.standard.set(mode.rawValue, forKey: "contentMode") } } }
    @Published var selectedCalendarDate = Date()
    @Published var calendarUnscheduled = false
    @Published var taskDraftStarted = false
    @Published var importantOnly = false { didSet { invalidateTaskViews() } }
    @Published var completedLimit = 20
    @Published var taskCreating = false
    @Published var taskDraft = ""
    @Published var taskDraftStatus = "pending"
    @Published var taskDraftImportant = false
    @Published var taskDraftHasDue = false
    @Published var taskDraftDate = Date()
    @Published var editStatus = "pending"
    @Published var editImportant = false
    @Published var convertedTaskID: String?
    @Published var highlightedTaskID: String?
    var taskToEditAfterReload: String?
    @Published var draft = ""
    @Published var composerPosition: CGPoint?
    @Published var readingRequested = true
    @Published var search = "" { didSet { if search != oldValue { completedLimit = 20; reload(reset: true, debounce: true) } } }
    @Published var hasMore = false
    @Published var loadingMore = false
    @Published var message = ""
    @Published var isError = false
    @Published var busy = false
    @Published var conversation: Entry?
    @Published var messages: [ChatMessage] = []
    @Published var chatDraft = ""
    @Published var chatError = ""
    @Published var editing: Entry? { didSet { cachedGroups = nil } }
    @Published var editError = ""
    @Published var editDraft = ""
    @Published var editHasDue = false
    @Published var editDate = Date()
    @Published var settings = false
    @Published var recentlyDeleted = false
    @Published var aiUsesCurrentView = false
    @Published var undoAvailable = false
    @Published var provider: Provider { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") } }
    private(set) var store: Store?
    @Published private(set) var sync: SyncController?
    @Published private(set) var lastDeletedTaskID: String?
    private var syncSubscriptions = Set<AnyCancellable>()
    let preview: Bool
    private let persistsViewMode: Bool
    private var undoBefore: [Entry] = []
    private var undoAfter: [Entry] = []
    private var runner: AgentRunner?
    private var timer: Timer?
    private var dataVersion: Int?
    private(set) var reloadTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    @Published private(set) var opening = false
    private var pollTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    @Published private(set) var reloading = false
    private let pageSize = 40
    private var chatDrafts: [String: String] = [:]

    init(store injectedStore: Store? = nil) {
        preview = injectedStore == nil && CommandLine.arguments.contains("--preview")
        persistsViewMode = injectedStore == nil && !CommandLine.arguments.contains("--preview") && ProcessInfo.processInfo.environment["NOTO_DATABASE"] == nil
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "opencode") ?? .opencode
        if injectedStore != nil || preview {
            do {
                store = try injectedStore ?? Store(url: preview ? nil : Store.defaultURL)
                if preview {
                    _ = try store?.add(kind: "todo", text: "整理草图", due: Self.dateKey(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
                    _ = try store?.add(kind: "note", text: "今天想清楚了产品方向。")
                    _ = try store?.add(kind: "todo", text: "梳理任务看板的交互细节", status: "in_progress", priority: "important")
                    _ = try store?.add(kind: "todo", text: "完成第一轮设计讨论", status: "completed")
                    draft = "记一下，今天想清楚了产品方向。明天下午把草图整理好。"
                    message = "已记下，并添加了明天的待办。"
                    undoAfter = try store?.list() ?? []; undoAvailable = true
                }
            } catch { store = nil; message = "无法打开数据：\(error.localizedDescription)"; isError = true }
        }
        if !preview && injectedStore == nil { mode = ContentMode(rawValue: UserDefaults.standard.string(forKey: "contentMode") ?? "") ?? .notes }
        if preview || ProcessInfo.processInfo.environment["NOTO_DATABASE"] != nil {
            if CommandLine.arguments.contains("--calendar") { mode = .calendar }
            if CommandLine.arguments.contains("--board") { mode = .board }
        }
        if let store {
            if !preview { attachSync(to: store) }
            reload()
        }
        else if !isError {
            opening = true
            startupTask = Task { [weak self] in
                do {
                    let store = try await Task.detached(priority: .userInitiated) {
                        let url = ProcessInfo.processInfo.environment["NOTO_DATABASE"].map { URL(fileURLWithPath: $0) } ?? Store.localURL
                        return try Store(url: url, busyTimeout: 0.1)
                    }.value
                    guard let self else { return }
                    self.store = store; self.attachSync(to: store)
                    if ProcessInfo.processInfo.environment["NOTO_DATABASE"] == nil { await self.sync?.restoreSession() }
                    self.opening = false; self.reload()
                } catch {
                    self?.opening = false; self?.fail(error)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in if NSApp.isActive { self?.refreshIfChanged() } }
        }
        timer?.tolerance = 0.5
    }

    private func attachSync(to store: Store) {
        let controller = SyncController(localStore: store)
        sync = controller
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &syncSubscriptions)
        controller.$store.dropFirst().sink { [weak self] store in
            self?.replaceAccountStore(store)
        }.store(in: &syncSubscriptions)
        controller.$dataRevision.dropFirst().sink { [weak self] _ in
            // Sync writes use our own connection, so PRAGMA data_version cannot detect them.
            self?.reload()
        }.store(in: &syncSubscriptions)
    }

    func canChangeSyncAccount() -> Bool {
        guard !busy else { fail(NotoError("请先停止 AI 回复，再切换账号。")); return false }
        guard draft.isEmpty, chatDraft.isEmpty, !chatDrafts.contains(where: { $0.key != conversation?.id && !$0.value.isEmpty }),
              !taskDraftStarted || !taskDraftDirty else {
            fail(NotoError("还有未保存的内容或对话草稿。请先保存、发送或清空草稿，再切换账号。"))
            return false
        }
        return leaveUnchangedEditor()
    }

    func replaceAccountStore(_ replacement: Store) {
        guard store !== replacement else { return }
        reloadTask?.cancel(); pollTask?.cancel(); loadTask?.cancel()
        reloadGeneration += 1; dataVersion = nil
        store = replacement
        entries = []; tasks = []; messages = []; conversation = nil; chatDrafts = [:]
        aiUsesCurrentView = false
        undoBefore = []; undoAfter = []; undoAvailable = false; lastDeletedTaskID = nil
        editing = nil; editDraft = ""; editError = ""; draft = ""; chatDraft = ""; chatError = ""
        taskCreating = false; taskDraftStarted = false; taskDraft = ""; taskDraftHasDue = false; taskDraftImportant = false
        taskDraftStatus = "pending"; convertedTaskID = nil; highlightedTaskID = nil; taskToEditAfterReload = nil
        composerPosition = nil; readingRequested = true; message = ""; isError = false
        importantOnly = false; completedLimit = 20; hasMore = false
        if search.isEmpty { reload(reset: true) } else { search = "" }
    }

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
    }

    static func dateKey(_ date: Date) -> String {
        let parts = TaskDates.local.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private var cachedGroups: [DayGroup]?
    private var groupsTimeZone = TimeZone.current
    var cachedVisibleTasks: [Entry]?
    var cachedCalendarTasks: [Entry]?
    var cachedCalendarGroups: [String: [Entry]]?
    var cachedTaskColumns: [String: [Entry]]?
    private func invalidateTaskViews() {
        cachedVisibleTasks = nil; cachedCalendarTasks = nil
        cachedCalendarGroups = nil; cachedTaskColumns = nil
    }

    var filtered: [Entry] { mode.isTaskView ? visibleTasks : entries }
    var aiContext: [Entry] {
        if aiUsesCurrentView { return filtered }
        return conversation.map { [$0] } ?? []
    }
    var aiContextLabel: String {
        aiUsesCurrentView ? "\(mode.isTaskView ? "筛选任务" : "已载入记录") · \(aiContext.count) 条" : "当前记录"
    }
    struct DayGroup: Identifiable {
        let id: String
        let date: Date
        var entries: [Entry]
        var label: String {
            if Calendar.current.isDateInToday(date) { return "今天" }
            if Calendar.current.isDateInYesterday(date) { return "昨天" }
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let prefix = parts.year == Calendar.current.component(.year, from: Date()) ? "" : "\(parts.year!)年"
            return "\(prefix)\(parts.month!)月\(parts.day!)日"
        }
        var shortLabel: String {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let prefix = parts.year == Calendar.current.component(.year, from: Date()) ? "" : String(format: "%02d.", parts.year! % 100)
            return prefix + String(format: "%02d.%02d", parts.month!, parts.day!)
        }
    }
    var groups: [DayGroup] {
        if groupsTimeZone != .current { cachedGroups = nil; groupsTimeZone = .current }
        if let cachedGroups { return cachedGroups }
        var result: [DayGroup] = []
        var visible = entries
        // Keep an active editor reachable if an external change removes its search match.
        if let editing, !visible.contains(where: { $0.id == editing.id }) {
            visible.append(editing)
            visible.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        }
        for entry in visible {
            let key = Self.dateKey(entry.createdAt)
            if result.last?.id == key { result[result.count - 1].entries.append(entry) }
            else { result.append(DayGroup(id: key, date: entry.createdAt, entries: [entry])) }
        }
        cachedGroups = result
        return result
    }
    deinit {
        timer?.invalidate()
        startupTask?.cancel(); reloadTask?.cancel(); pollTask?.cancel(); loadTask?.cancel()
    }

    func reload(reset: Bool = false, debounce: Bool = false) {
        reloadTask?.cancel(); loadTask?.cancel(); loadingMore = false
        reloadGeneration += 1
        guard let store else { return }
        let generation = reloadGeneration, query = search, taskView = mode.isTaskView
        let limit = reset ? pageSize : max(pageSize, entries.count)
        reloading = true
        reloadTask = Task { [weak self] in
            do {
                if debounce && !query.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
                let result = try await Task.detached(priority: .userInitiated) {
                    // Read the version first: a concurrent commit will be caught on the next poll.
                    let version = try store.dataVersion()
                    let page = taskView ? nil : try store.page(limit: limit, search: query)
                    let tasks = taskView ? try store.todos(search: query) : nil
                    return (version, page, tasks)
                }.value
                try Task.checkCancellation()
                guard let self, generation == self.reloadGeneration else { return }
                if let page = result.1 {
                    if page.entries != self.entries { self.entries = page.entries }
                    self.hasMore = page.hasMore
                }
                if let tasks = result.2, tasks != self.tasks { self.tasks = tasks }
                self.dataVersion = result.0
                self.reloading = false
                if let id = self.taskToEditAfterReload {
                    self.taskToEditAfterReload = nil
                    if self.mode == .board, self.highlightedTaskID == id,
                       let task = self.tasks.first(where: { $0.id == id }) { self.beginEditing(task) }
                }
            } catch is CancellationError {
                // The newer request owns the loading state and results.
            } catch {
                guard let self, generation == self.reloadGeneration else { return }
                self.reloading = false; self.fail(error)
            }
        }
    }
    func refreshIfChanged() {
        guard pollTask == nil, !reloading, let store else { return }
        let generation = reloadGeneration
        pollTask = Task { [weak self] in
            defer { self?.pollTask = nil }
            do {
                let version = try await Task.detached(priority: .utility) { try store.dataVersion() }.value
                guard let self, generation == self.reloadGeneration else { return }
                if version != self.dataVersion { self.reload() }
            } catch { self?.fail(error) }
        }
    }
    // Also useful for callers that need to act on the newly loaded snapshot.
    func waitForReload() async {
        await startupTask?.value
        await pollTask?.value
        await reloadTask?.value
        await loadTask?.value
    }
    func loadMore() {
        guard hasMore, !loadingMore, !reloading, let cursor = entries.last, let store else { return }
        loadingMore = true
        let generation = reloadGeneration, query = search, limit = pageSize
        loadTask = Task { [weak self] in
            do {
                let page = try await Task.detached(priority: .userInitiated) {
                    try store.page(before: cursor, limit: limit, search: query)
                }.value
                try Task.checkCancellation()
                guard let self, generation == self.reloadGeneration else { return }
                self.entries.append(contentsOf: page.entries)
                self.hasMore = page.hasMore; self.loadingMore = false
            } catch is CancellationError {
            } catch {
                guard let self, generation == self.reloadGeneration else { return }
                self.loadingMore = false; self.fail(error)
            }
        }
    }
    func fail(_ error: Error) { message = error.localizedDescription; isError = true }
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
            remember(before: [], after: [entry], message: isTodo ? "已添加待办。" : "已记下。")
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
    func ask() {
        guard !busy, composerPosition != nil, let store else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        do {
            if let conversation { chatDrafts[conversation.id] = chatDraft }
            conversation = try store.startConversation(input)
            aiUsesCurrentView = false
            messages = try store.messages(for: conversation!.id)
            draft = ""; composerPosition = nil; readingRequested = false; chatDraft = ""; chatError = ""; message = ""; reload()
            requestReply()
        } catch { fail(error) }
    }
    func openConversation(_ entry: Entry) {
        guard !busy, leaveUnchangedEditor() else { return }
        do {
            messages = try store?.messages(for: entry.id) ?? []
            if let conversation { chatDrafts[conversation.id] = chatDraft }
            if conversation?.id != entry.id { aiUsesCurrentView = false }
            conversation = entry; chatDraft = chatDrafts[entry.id] ?? ""; chatError = ""
            composerPosition = nil; readingRequested = false
        } catch { fail(error) }
    }
    func closeConversation() {
        guard !busy else { return }
        if let conversation { chatDrafts[conversation.id] = chatDraft }
        conversation = nil
        readingRequested = true
    }
    func sendChat() {
        guard !busy, messages.last?.role != "user", let conversation, let store else { return }
        do {
            try store.appendQuestion(chatDraft, to: conversation.id)
            chatDraft = ""; messages = try store.messages(for: conversation.id)
            requestReply()
        } catch { chatError = error.localizedDescription }
    }
    func replyContext() throws -> [Entry] {
        guard let store, let conversation,
              let current = try store.entry(id: conversation.id) else { throw NotoError("这条记录已不存在，请返回记录列表。") }
        self.conversation = current
        if aiUsesCurrentView { return filtered.map { $0.id == current.id ? current : $0 } }
        return [current]
    }
    func requestReply() {
        guard !busy, let store, let question = messages.last, question.role == "user" else { return }
        let context: [Entry]
        do { context = try replyContext() }
        catch { chatError = error.localizedDescription; return }
        let history = Array(messages.dropLast())
        let selectedProvider = provider
        let active = AgentRunner(); runner = active
        busy = true; chatError = ""
        let startedAt = Date()
        recordExecution("已读取 \(history.count) 条历史消息与 \(context.count) 条记录", for: question)
        Task {
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try active.run(prompt: question.text, entries: context, provider: selectedProvider, history: history) { event in
                        Task { @MainActor in self.recordExecution(event, for: question) }
                    }
                }.value
                let changed = try store.apply(response.actions, expected: context, replyingTo: question, reply: response.message)
                if let updated = changed.first(where: { $0.id == conversation?.id }) { conversation = updated }
                if !changed.isEmpty { remember(before: context, after: changed, message: "已更新记录。") }
                messages = try store.messages(for: question.entryID)
                recordExecution("已保存回复\(changed.isEmpty ? "" : "，更新 \(changed.count) 条记录") · \(Int(Date().timeIntervalSince(startedAt))) 秒", for: question)
                reload()
            } catch {
                chatError = error.localizedDescription
                recordExecution("未完成：\(error.localizedDescription)", for: question)
            }
            busy = false; runner = nil
        }
    }
    func recordExecution(_ event: String, for question: ChatMessage) {
        do {
            let previous = messages.first(where: { $0.id == question.id })?.execution ?? ""
            try store?.setExecution(previous.isEmpty ? event : previous + "\n" + event, for: question)
            messages = try store?.messages(for: question.entryID) ?? messages
        } catch { chatError = "执行过程保存失败：\(error.localizedDescription)" }
    }
    func cancel() { runner?.cancel() }
}

@main
struct NotoApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("noto", id: "main") {
            ContentView(model: model)
                .buttonStyle(QuietButtonStyle())
                .frame(minWidth: 620, minHeight: 480)
                .onAppear {
                    let isolated = model.preview || ProcessInfo.processInfo.environment["NOTO_DATABASE"] != nil
                    if isolated && CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow {
                            window.titleVisibility = .hidden
                            window.titlebarAppearsTransparent = true
                            window.titlebarSeparatorStyle = .none
                            window.styleMask.insert(.fullSizeContentView)
                            window.isMovableByWindowBackground = model.mode == .notes
                            window.backgroundColor = NSColor.textBackgroundColor
                            if isolated { window.setContentSize(CommandLine.arguments.contains("--compact") ? NSSize(width: 620, height: 700) : NSSize(width: 1340, height: 954)); window.center() }
                        }
                    }
                }
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建内容") { model.showComposer() }.keyboardShortcut("n").disabled(model.settings || model.recentlyDeleted)
                Button("提交当前输入") { model.submitFocusedInput() }.keyboardShortcut(.return, modifiers: .command).disabled(model.settings || model.recentlyDeleted)
                Button("添加待办") { model.save(todo: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(model.composerPosition == nil || model.settings || model.recentlyDeleted)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销文本编辑") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }.keyboardShortcut("z")
                Button("重做文本编辑") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }.keyboardShortcut("z", modifiers: [.command, .option])
                Button("撤销上次记录操作") { model.undo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.undoAvailable || model.settings || model.recentlyDeleted)
                Button("恢复上次删除的任务") { model.restoreLastDeletedTask() }.disabled(model.lastDeletedTaskID == nil || model.settings || model.recentlyDeleted)
                Button("最近删除…") { model.recentlyDeleted = true }.disabled(model.settings || model.recentlyDeleted)
            }
            CommandGroup(after: .toolbar) {
                ForEach(ContentMode.allCases) { mode in
                    Button("显示\(mode.label)") { model.switchMode(mode) }.keyboardShortcut(mode.shortcut, modifiers: .command).disabled(model.settings || model.recentlyDeleted)
                }
            }
            CommandGroup(after: .textEditing) {
                Button("搜索记录") {
                    guard model.leaveUnchangedEditor() else { return }
                    model.composerPosition = nil
                    model.closeConversation()
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                }.keyboardShortcut("k").disabled(model.settings || model.recentlyDeleted)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.settings = true }.keyboardShortcut(",")
            }
        }
    }
}

extension Notification.Name {
    static let focusComposer = Notification.Name("noto.focusComposer")
    static let focusSearch = Notification.Name("noto.focusSearch")
    static let focusChat = Notification.Name("noto.focusChat")
    static let focusEditor = Notification.Name("noto.focusEditor")
}

// Shared native tokens. Semantic colors follow macOS appearance and contrast.
enum NotoDesign {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let field = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor).opacity(0.6)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 12)
    static let radius: CGFloat = 12
}

// Shared chrome for actions; native menus retain their keyboard behavior.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    var icon = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .padding(.horizontal, icon ? 0 : 10)
            .frame(minWidth: 28, minHeight: 28)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .modifier(ActionSurface(pressed: configuration.isPressed))
            .opacity(enabled ? 1 : 0.4)
    }
}

private struct ActionSurface: ViewModifier {
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(enabled ? Color.primary.opacity(pressed ? 0.10 : (hovering ? 0.055 : 0)) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

extension View {
    func actionMenuStyle() -> some View {
        self.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .modifier(ActionSurface())
    }
}

struct ActionIcon: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name).font(.system(size: 13, weight: .regular))
            .frame(width: 28, height: 28)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("datesExpanded") private var datesExpanded = false
    @State private var activeDay: String?
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 980
            let showChatOnly = narrow && model.conversation != nil && !model.readingRequested
            HStack(spacing: 0) {
                if !showChatOnly {
                    VStack(spacing: 0) {
                    if model.mode == .calendar {
                        TaskCalendar(model: model).padding(.top, 48)
                    } else if model.mode == .board {
                        TaskBoard(model: model).padding(.top, 48)
                    } else {
                    ScrollViewReader { proxy in
                        HStack(spacing: 0) {
                            if !model.entries.isEmpty {
                                DateRail(model: model, expanded: datesExpanded, activeDay: activeDay, maxHeight: geometry.size.height,
                                         width: datesExpanded ? (geometry.size.width < 800 ? 144 : 180) : 88) { id in
                                    activeDay = id
                                    proxy.scrollTo("content-" + id, anchor: .top)
                                }
                            }
                            ReadingPane(model: model, activeDay: $activeDay)
                                .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in
                                    if model.composerPosition == CGPoint(x: 24, y: 40) { proxy.scrollTo("history-top", anchor: .top) }
                                }
                                .onChange(of: model.search) { _, _ in
                                    activeDay = model.groups.first?.id
                                    proxy.scrollTo("history-top", anchor: .top)
                                }
                                .padding(.top, 48)
                        }
                    }
                    }
                    if !model.message.isEmpty { feedback.padding(.horizontal, 24).padding(.bottom, 16) }
                    }
                    .overlay(alignment: .top) {
                        HStack {
                            if model.mode == .notes {
                            Button {
                                withAnimation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) { datesExpanded.toggle() }
                            } label: { ActionIcon("sidebar.left") }
                                .buttonStyle(QuietButtonStyle(icon: true)).foregroundStyle(.secondary).disabled(model.entries.isEmpty)
                                .help(datesExpanded ? "收起日期侧栏" : "展开日期侧栏")
                                .accessibilityLabel(datesExpanded ? "收起日期侧栏" : "展开日期侧栏")
                            }
                            ViewModeMenu(model: model)
                            if model.mode == .notes {
                                Button { model.showComposer() } label: { ActionIcon("square.and.pencil") }
                                    .buttonStyle(QuietButtonStyle(icon: true)).help("写一笔（⌘N）").accessibilityLabel("写一笔")
                            }
                            if narrow && model.conversation != nil {
                                Button {
                                    guard model.leaveUnchangedEditor() else { return }
                                    model.composerPosition = nil; model.readingRequested = false
                                } label: { ActionIcon("bubble.left") }
                                    .buttonStyle(QuietButtonStyle(icon: true)).help("返回当前对话").accessibilityLabel("返回当前对话")
                            }
                            Spacer()
                            Button { model.settings = true } label: {
                                Label(model.sync?.isSignedIn == true ? "账号" : "本机", systemImage: model.sync?.isSignedIn == true ? "person.crop.circle" : "internaldrive")
                                    .font(NotoDesign.caption).foregroundStyle(.secondary)
                            }.buttonStyle(QuietButtonStyle())
                                .help(model.sync?.isSignedIn == true ? "当前账号：\(model.sync?.email ?? "") · \(model.sync?.status ?? "")" : "当前内容保存在本机 · 打开设置")
                                .accessibilityLabel("\(model.sync?.isSignedIn == true ? "账号空间" : "本机空间")，打开设置")
                            if model.reloading { ProgressView().controlSize(.small).help("正在读取记录") }
                            SearchInput(text: Binding(get: { model.search }, set: { model.setSearch($0) }), placeholder: model.mode.isTaskView ? "搜索任务与对话" : "搜索记录与对话").frame(width: geometry.size.width < 800 ? 154 : 190, height: 28)
                        }.padding(.leading, 86).padding(.trailing, 20).padding(.top, 10)
                    }
                }
                if model.conversation != nil && (!narrow || showChatOnly) {
                    if !narrow { Divider() }
                    ConversationView(model: model, compact: narrow)
                        .frame(width: narrow ? geometry.size.width : min(440, max(340, geometry.size.width * 0.37)))
                }
            }
        }
        .onChange(of: model.mode) { _, mode in
            NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.isMovableByWindowBackground = mode == .notes
        }
        .disabled(model.opening)
        .overlay { if model.opening { ProgressView("正在打开记录…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        .background(NotoDesign.canvas).foregroundStyle(.primary)
        .ignoresSafeArea(.container, edges: .top)
        .onExitCommand {
            if model.taskCreating { model.taskCreating = false }
            else if model.editing != nil { model.cancelEditing() }
            else if model.composerPosition != nil { model.composerPosition = nil }
            else if !model.search.isEmpty { model.setSearch("") }
            else { model.closeConversation() }
        }
        .sheet(isPresented: Binding(get: { model.taskCreating || (model.mode.isTaskView && model.editing != nil) }, set: { value in
            if !value { _ = model.leaveUnchangedEditor() }
        })) { TaskEditor(model: model) }
        .sheet(isPresented: $model.settings) { SettingsView(model: model) }
        .sheet(isPresented: $model.recentlyDeleted) { RecentlyDeletedView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshIfChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() }
    }
    private var feedback: some View {
        HStack(spacing: 10) {
            if model.isError { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
            Text(model.message).font(NotoDesign.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.convertedTaskID != nil { Button("在看板查看") { model.showConvertedTask() }.buttonStyle(QuietButtonStyle()) }
            if model.undoAvailable { Button("撤销") { model.undo() }.buttonStyle(QuietButtonStyle()).help("撤销上次记录操作（⌘⇧Z）") }
            if model.lastDeletedTaskID != nil { Button("恢复删除") { model.restoreLastDeletedTask() }.buttonStyle(QuietButtonStyle()) }
            Button { model.message = "" } label: { ActionIcon("xmark") }
                .buttonStyle(QuietButtonStyle(icon: true)).accessibilityLabel("关闭操作提示")
        }.font(NotoDesign.caption).padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(NotoDesign.line, lineWidth: 0.5)).frame(maxWidth: 620)
    }
}

private struct ReadingPane: View {
    @ObservedObject var model: AppModel
    @Binding var activeDay: String?
    @State private var occupied: [CGRect] = []
    @State private var composerSize = CGSize(width: 480, height: 180)
    var body: some View {
        GeometryReader { geometry in
            let width = max(260, min(480, geometry.size.width - 32))
            let origin = CGPoint(
                x: min(max(16, model.composerPosition?.x ?? 24), max(16, geometry.size.width - width - 16)),
                y: min(max(16, model.composerPosition?.y ?? 40), max(16, geometry.size.height - composerSize.height - 16)))
            let floatingRect = model.composerPosition == nil ? nil : CGRect(origin: origin, size: CGSize(width: width, height: composerSize.height))
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.entries.isEmpty && model.editing == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(model.search.isEmpty ? "留下一点今天。" : "没有找到相关记录").font(.system(size: 17, weight: .medium))
                                Text(model.search.isEmpty ? "想法、待办，先记下来。" : "试试其他关键词。")
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                                if !model.search.isEmpty {
                                    Button("清空搜索") { model.setSearch("") }.buttonStyle(QuietButtonStyle()).font(NotoDesign.caption)
                                } else {
                                    Button("写一笔") { model.showComposer() }.buttonStyle(QuietButtonStyle(prominent: true)).help("新建记录（⌘N）")
                                }
                            }.excludeFromBlankInput()
                        } else {
                            if !model.search.isEmpty {
                                HStack {
                                    Text("搜索结果").font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text("\(model.entries.count)\(model.hasMore ? "+" : "") 条记录").font(NotoDesign.caption).foregroundStyle(.secondary)
                                }.padding(.bottom, 24).excludeFromBlankInput()
                            }
                            LazyVStack(alignment: .leading, spacing: 32) {
                                ForEach(model.groups) { group in
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack(spacing: 12) {
                                            Text(group.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                            Rectangle().fill(NotoDesign.line).frame(height: 0.5)
                                        }.excludeFromBlankInput()
                                        LazyVStack(spacing: 4) {
                                            ForEach(group.entries) { entry in EntryRow(entry: entry, model: model).excludeFromBlankInput() }
                                        }
                                    }.id("content-" + group.id)
                                        .background(GeometryReader { frame in
                                            Color.clear.preference(key: DayPositions.self, value: [group.id: frame.frame(in: .named("history")).minY])
                                        })
                                }
                                if model.hasMore {
                                    Button("加载更多") { model.loadMore() }
                                        .buttonStyle(QuietButtonStyle()).font(NotoDesign.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity).padding(.vertical, 12).excludeFromBlankInput()
                                        .onAppear { model.loadMore() }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading).padding(.horizontal, 24)
                    .padding(.top, 48).padding(.bottom, 100).id("history-top").frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "history")
                .onPreferenceChange(DayPositions.self) { positions in
                    let current = Set(model.groups.map(\.id))
                    let sorted = positions.filter { current.contains($0.key) }.sorted { $0.value < $1.value }
                    if let id = (sorted.last(where: { $0.value <= 12 }) ?? sorted.first)?.key { activeDay = id }
                }
                if model.composerPosition != nil {
                    NewContentInput(model: model)
                        .frame(width: width)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { composerSize = $0 }
                        .offset(x: origin.x, y: origin.y)
                }
            }
            .coordinateSpace(name: "reading")
            .onPreferenceChange(OccupiedAreas.self) { occupied = $0 }
            .background(BlankClickObserver(excluded: occupied, floatingRect: floatingRect,
                onDoubleClick: { model.showComposer(at: $0) }, onOutsideClick: { model.composerPosition = nil }))
        }
    }
}

private struct NewContentInput: View {
    @ObservedObject var model: AppModel
    private var empty: Bool { model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("记一笔").font(NotoDesign.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.composerPosition = nil } label: { ActionIcon("xmark") }
                    .buttonStyle(QuietButtonStyle(icon: true)).accessibilityLabel("收起录入，保留草稿")
            }
            Composer(text: $model.draft, enabled: true, purpose: .newContent, onSubmit: { model.save() }, onCancel: { model.composerPosition = nil })
                .frame(minHeight: 48)
            if model.busy { Text("AI 正在回复，你可以继续保存笔记。").font(NotoDesign.caption).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Button("询问 AI") { model.ask() }.disabled(model.busy)
                Spacer(minLength: 0)
                Menu { Button("存为任务") { model.save(todo: true) } } label: {
                    ActionIcon("chevron.down")
                }.actionMenuStyle().help("其他保存方式").accessibilityLabel("其他保存方式")
                Button("保存小记") { model.save() }.buttonStyle(QuietButtonStyle(prominent: true)).help("保存小记（⌘↵）；回车换行")
            }.font(NotoDesign.caption).buttonStyle(QuietButtonStyle()).disabled(empty)
        }.padding(16)
            .background(NotoDesign.field, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
            .overlay(RoundedRectangle(cornerRadius: NotoDesign.radius).stroke(NotoDesign.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 5)
    }
}

private struct OccupiedAreas: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
private extension View {
    func excludeFromBlankInput() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: OccupiedAreas.self, value: [geometry.frame(in: .named("reading"))])
        })
    }
}

// Observe without consuming clicks: text selection, native buttons and scrolling keep their own events.
private struct BlankClickObserver: NSViewRepresentable {
    let excluded: [CGRect]
    let floatingRect: CGRect?
    let onDoubleClick: (CGPoint) -> Void
    let onOutsideClick: () -> Void
    func makeNSView(context: Context) -> Surface {
        let view = Surface(); view.parent = self
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
            guard let view, let window = view.window, event.window === window, let parent = view.parent else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            if let rect = parent.floatingRect, !rect.contains(point), event.clickCount == 1 { parent.onOutsideClick() }
            guard event.clickCount == 2, view.visibleRect.contains(point),
                  !(parent.floatingRect?.contains(point) ?? false), !parent.excluded.contains(where: { $0.contains(point) }) else { return event }
            var hit = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil))
            while let candidate = hit {
                if candidate is NSScroller || candidate is NSControl || candidate is NSTextView { return event }
                hit = candidate.superview
            }
            parent.onDoubleClick(point)
            return event
        }
        return view
    }
    func updateNSView(_ view: Surface, context: Context) { view.parent = self }
    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor); view.monitor = nil }
    }
    final class Surface: NSView {
        var parent: BlankClickObserver?
        var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel
    var compact = false
    private var pending: Bool { model.messages.last?.role == "user" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if compact {
                    Button { model.readingRequested = true } label: { ActionIcon("arrow.left") }
                        .buttonStyle(QuietButtonStyle(icon: true)).help("返回记录，保留对话").accessibilityLabel("返回记录")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("对话").font(.system(size: 17, weight: .semibold))
                    Text(model.conversation?.text ?? "").font(NotoDesign.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if !compact {
                    Button { model.closeConversation() } label: { ActionIcon("xmark") }
                        .buttonStyle(QuietButtonStyle(icon: true)).help("关闭对话（Esc）").accessibilityLabel("关闭对话").disabled(model.busy)
                }
            }.padding(.horizontal, 24).padding(.top, 54).padding(.bottom, 20)
            Divider().padding(.horizontal, 24)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if model.messages.isEmpty {
                            Text("围绕这条记录继续想一想，或请 AI 帮你整理成任务。")
                                .font(NotoDesign.body).foregroundStyle(.secondary).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(message.role == "user" ? "你" : "AI").font(.system(size: 12, weight: .medium))
                                        .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                }.foregroundStyle(.secondary)
                                MessageText(text: message.text)
                                    .font(NotoDesign.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let execution = message.execution {
                                    DisclosureGroup {
                                        Text(execution).font(NotoDesign.caption).lineSpacing(5).foregroundStyle(.secondary).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                    } label: {
                                        Text(model.busy && message.id == model.messages.last?.id ? "执行中…" : "执行过程").font(NotoDesign.caption).foregroundStyle(.secondary)
                                    }.padding(.top, 4)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.busy {
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在回复…").font(NotoDesign.caption).foregroundStyle(.secondary) }
                        }
                        if !model.chatError.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(model.chatError, systemImage: "exclamationmark.circle").font(NotoDesign.caption).textSelection(.enabled)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(24)
                }
                .onChange(of: model.messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: model.busy) { _, busy in
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                    if !busy && !pending && model.composerPosition == nil && model.editing == nil { NotificationCenter.default.post(name: .focusChat, object: nil) }
                }
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    Toggle("当前记录", isOn: Binding(get: { !model.aiUsesCurrentView }, set: { if $0 { model.aiUsesCurrentView = false } }))
                    Toggle("当前视图已载入的 \(model.filtered.count) 条内容", isOn: $model.aiUsesCurrentView)
                } label: {
                    Label(model.aiContextLabel, systemImage: "doc.text")
                        .font(NotoDesign.caption).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                    .help("此轮会提供所选记录和本对话历史；当前视图仅包含已载入或筛选的内容。")
                    .accessibilityLabel("AI 内容范围：\(model.aiContextLabel)")
                if pending && !model.busy {
                    HStack {
                        Text("问题已保存").font(NotoDesign.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("重试") { model.requestReply() }.buttonStyle(QuietButtonStyle())
                    }
                }
                Composer(text: $model.chatDraft, enabled: true, purpose: .chat, onSubmit: { model.sendChat() }, onCancel: { model.closeConversation() })
                    .frame(minHeight: 40).fixedSize(horizontal: false, vertical: true)
                    .padding(14).background(NotoDesign.field, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
                    .overlay(RoundedRectangle(cornerRadius: NotoDesign.radius).stroke(NotoDesign.line, lineWidth: 0.5))
                HStack {
                    Spacer()
                    if model.busy {
                        Button { model.cancel() } label: { ActionIcon("stop.fill") }
                            .buttonStyle(QuietButtonStyle(icon: true)).help("停止回复").accessibilityLabel("停止回复")
                    } else {
                        Button { model.sendChat() } label: { ActionIcon("arrow.up") }
                            .buttonStyle(QuietButtonStyle(icon: true)).foregroundStyle(Color.accentColor).help("发送消息（⌘ 回车）").accessibilityLabel("发送消息")
                            .disabled(pending || model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.font(NotoDesign.caption)
            }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 12)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MessageText: View {
    let text: String
    @State private var rendered = AttributedString()
    var body: some View {
        Text(rendered)
            .task(id: text) {
                let value = text
                let parsed = await Task.detached(priority: .userInitiated) {
                    (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
                }.value
                if !Task.isCancelled { rendered = parsed }
            }
    }
}

private struct DayPositions: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct DateRail: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let expanded: Bool
    let activeDay: String?
    let maxHeight: CGFloat
    let width: CGFloat
    let navigate: (String) -> Void
    var body: some View {
        let selectedID = model.groups.contains(where: { $0.id == activeDay }) ? activeDay : model.groups.first?.id
        VStack(alignment: .leading, spacing: 16) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: expanded ? 6 : 2) {
                        ForEach(model.groups) { group in
                            let selected = selectedID == group.id
                            Button { navigate(group.id) } label: {
                                HStack(spacing: 8) {
                                    if !expanded { Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: selected ? 14 : 8, height: 2) }
                                    Text(expanded ? "\(group.shortLabel)  \(group.label == "今天" || group.label == "昨天" ? group.label : "")" : group.shortLabel)
                                        .font(.system(size: expanded ? 13 : 11, weight: selected ? .medium : .regular)).monospacedDigit()
                                    if expanded { Spacer(minLength: 0) }
                                }
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                .frame(height: expanded ? 32 : 28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, expanded ? 10 : 0)
                                .background(expanded && selected ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(group.id)
                            .help(group.id).accessibilityLabel("跳到 \(group.id)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        if model.hasMore {
                            Button("更早") { model.loadMore() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    }.padding(.horizontal, expanded ? 10 : 14)
                }
                .scrollIndicators(.hidden)
                .onChange(of: activeDay) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(maxHeight: expanded ? .infinity : min(400, maxHeight * 0.6))
        }
        .padding(.top, expanded ? 58 : 0)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: expanded ? .topLeading : .center)
        .background(expanded ? Color.primary.opacity(0.018) : Color.clear)
    }
}

struct EntryRow: View {
    let entry: Entry
    @ObservedObject var model: AppModel
    private var overdue: Bool { !entry.completed && (entry.due.map { $0 < AppModel.dateKey(Date()) } ?? false) }
    var dueLabel: String {
        guard let due = entry.due else { return "" }
        if due == AppModel.dateKey(Date()) { return "今天到期" }
        if due == AppModel.dateKey(Calendar.current.date(byAdding: .day, value: 1, to: Date())!) { return "明天到期" }
        return overdue ? "已逾期 · \(due)" : due
    }
    private func edit() { model.beginEditing(entry) }
    var body: some View {
        Group {
        if model.editing?.id == entry.id { InlineEditView(entry: entry, model: model) } else {
        HStack(alignment: .top, spacing: 12) {
            if entry.kind == "todo" {
                Toggle("完成待办", isOn: Binding(get: { entry.completed }, set: { _ in model.toggle(entry) }))
                    .toggleStyle(.checkbox).labelsHidden().padding(.top, 3)
                    .accessibilityLabel("\(entry.completed ? "重新打开" : "完成")：\(entry.text)")
            }
            VStack(alignment: .leading, spacing: 8) {
                EntryBodyText(text: entry.text, completed: entry.completed, onEdit: edit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(entry.createdAt, style: .time).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    if entry.due != nil {
                        Text(dueLabel).font(.system(size: 11)).foregroundStyle(overdue ? Color.orange : Color.secondary)
                    }
                    if entry.kind == "todo" {
                        if entry.status == "in_progress" { Text("进行中").font(NotoDesign.caption).foregroundStyle(.secondary) }
                        if entry.priority == "important" {
                            Button { model.changeTask(entry, priority: "normal") } label: {
                                ActionIcon("star.fill")
                            }.buttonStyle(QuietButtonStyle(icon: true)).help("取消重要")
                                .accessibilityLabel("取消重要")
                        }
                    }
                    Spacer(minLength: 0)
                    if entry.hasConversation {
                        Button { model.openConversation(entry) } label: { ActionIcon("bubble.left") }
                            .buttonStyle(QuietButtonStyle(icon: true)).foregroundStyle(model.conversation?.id == entry.id ? Color.accentColor : Color.secondary)
                            .help("打开对话").accessibilityLabel("打开对话").disabled(model.busy)
                    }
                    Menu { actions } label: { ActionIcon("ellipsis") }
                        .actionMenuStyle()
                        .help("记录操作").accessibilityLabel("记录操作")
                }
            }
        }
        .padding(12)
        .background(model.conversation?.id == entry.id ? Color.accentColor.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .contextMenu { actions }
        }
        }
    }
    @ViewBuilder private var actions: some View {
            Button("编辑", action: edit)
            if entry.kind == "note" { Button("转为任务") { model.convertToTask(entry) } }
            if entry.kind == "todo" {
                ForEach(TodoStatus.allCases, id: \.self) { status in
                    Button(status.label) { model.changeTask(entry, status: status.rawValue) }
                }
                Button(entry.priority == "important" ? "取消重要" : "标记重要") { model.changeTask(entry, priority: entry.priority == "important" ? "normal" : "important") }
                Button("删除任务", role: .destructive) { model.deleteTask(entry) }.disabled(model.busy)
            }
            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
            Button(entry.hasConversation ? "打开对话" : "与 AI 讨论") { model.openConversation(entry) }.disabled(model.busy)
    }
}

// NSTextView owns selectable text, so intercept its double click before word selection.
private struct EntryBodyText: NSViewRepresentable {
    let text: String
    let completed: Bool
    let onEdit: () -> Void
    func makeNSView(context: Context) -> BodyTextView {
        let view = BodyTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isRichText = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.setAccessibilityLabel("记录正文")
        return view
    }
    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: completed ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph, .strikethroughStyle: completed ? NSUnderlineStyle.single.rawValue : 0]
    }
    func updateNSView(_ view: BodyTextView, context: Context) {
        view.onEdit = onEdit
        if view.string != text || view.completed != completed {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            view.completed = completed
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BodyTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 600)
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return CGSize(width: width, height: max(20, ceil(rect.height)))
    }
    final class BodyTextView: NSTextView {
        var onEdit: (() -> Void)?
        var completed = false
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onEdit?() }
            else { super.mouseDown(with: event) }
        }
    }
}

enum InputPurpose {
    case newContent, chat, edit
    var focusNotification: Notification.Name {
        switch self { case .newContent: return .focusComposer; case .chat: return .focusChat; case .edit: return .focusEditor }
    }
    var label: String {
        switch self { case .newContent: return "新建内容"; case .chat: return "继续对话"; case .edit: return "编辑记录内容" }
    }
}

struct Composer: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let purpose: InputPurpose
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var placeholder: String? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = InputTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        view.purpose = purpose
        view.onSubmit = onSubmit; view.onCancel = onCancel
        view.delegate = context.coordinator; view.isRichText = false; view.drawsBackground = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 16); view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        switch purpose {
        case .newContent: view.placeholder = "写下想法，⌘ 回车保存。"
        case .chat: view.placeholder = "继续聊…"
        case .edit: view.placeholder = "记录内容不能为空。"
        }
        if let placeholder { view.placeholder = placeholder }
        view.setAccessibilityLabel(purpose.label)
        context.coordinator.view = view
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: purpose.focusNotification, object: nil, queue: .main) { [weak view] _ in view?.window?.makeFirstResponder(view) }
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? InputTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            view.string = text; view.undoManager?.removeAllActions()
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        view.onSubmit = onSubmit; view.onCancel = onCancel
        if view.isEditable != enabled { view.isEditable = enabled }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        let bounds = (text.isEmpty ? " " : text) as NSString
        let rect = bounds.boundingRect(with: NSSize(width: max(40, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 16)])
        return CGSize(width: width, height: min(purpose == .chat ? 120 : 160, max(32, ceil(rect.height) + 6)))
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: Composer
        weak var view: NSTextView?
        var observer: NSObjectProtocol?
        init(_ parent: Composer) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func textDidChange(_ notification: Notification) { parent.text = view?.string ?? ""; view?.needsDisplay = true }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
                parent.onCancel(); return true
            }
            return false // Return belongs to NSTextView, including input-method composition.
        }
    }
}

struct SearchInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "搜索笔记与对话"
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let view = NSSearchField()
        view.sendsSearchStringImmediately = true
        view.sendsWholeSearchString = false
        view.controlSize = .regular
        view.placeholderString = placeholder; view.font = .systemFont(ofSize: 13)
        view.delegate = context.coordinator; view.setAccessibilityLabel("搜索")
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .focusSearch, object: nil, queue: .main) { [weak view] _ in view?.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: NSSearchField, context: Context) { view.placeholderString = placeholder; context.coordinator.parent = self; if view.stringValue != text { view.stringValue = text } }
    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchInput
        var observer: NSObjectProtocol?
        init(_ parent: SearchInput) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func controlTextDidChange(_ obj: Notification) { if let field = obj.object as? NSTextField { parent.text = field.stringValue } }
    }
}

class InputTextView: NSTextView {
    var purpose: InputPurpose = .newContent
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    func submit() { if isEditable && !hasMarkedText() { onSubmit?() } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 && flags.contains(.command) && !flags.contains(.shift) {
            submit(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}

struct InlineEditView: View {
    let entry: Entry
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.kind == "todo" ? "编辑待办" : "编辑小记").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Composer(text: $model.editDraft, enabled: true, purpose: .edit, onSubmit: { model.saveEditing() }, onCancel: { model.cancelEditing() })
                .frame(minHeight: 64)
            if entry.kind == "todo" {
                HStack {
                    Picker("状态", selection: $model.editStatus) {
                        ForEach(TodoStatus.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    Button { model.editImportant.toggle() } label: {
                        ActionIcon(model.editImportant ? "star.fill" : "star")
                    }.buttonStyle(QuietButtonStyle(icon: true)).help("切换重要标记").accessibilityLabel("重要任务")
                        .accessibilityValue(model.editImportant ? "已开启" : "已关闭")
                }.font(NotoDesign.caption)
                TaskDateControl(hasDue: $model.editHasDue, date: $model.editDate)
            }
            if !model.editError.isEmpty {
                Label(model.editError, systemImage: "exclamationmark.circle").font(NotoDesign.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button("放弃修改") { model.cancelEditing() }.buttonStyle(QuietButtonStyle())
                Button("保存") { model.saveEditing() }.buttonStyle(QuietButtonStyle(prominent: true)).help("保存（⌘↵）；回车换行")
                    .disabled(model.editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(NotoDesign.caption)
        }.padding(16)
            .background(NotoDesign.field, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
            .overlay(RoundedRectangle(cornerRadius: NotoDesign.radius).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showDeleted = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            Text("设置").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                Picker("AI CLI", selection: $model.provider) {
                    ForEach(Provider.allCases) { provider in Text(provider.title).tag(provider) }
                }
                Text("使用本机已登录的 CLI，下次对话生效。").font(NotoDesign.caption).foregroundStyle(.secondary).lineSpacing(4)
            }
            Divider()
            Button { showDeleted = true } label: { Label("最近删除", systemImage: "trash") }
            Divider()
            if let sync = model.sync { SyncSettingsView(model: model, controller: sync) }
            else { Text("预览模式不连接同步服务。").foregroundStyle(.secondary) }
            Divider()
            HStack { Spacer(); Button("完成") { model.settings = false }.keyboardShortcut(.defaultAction).disabled(model.sync?.isSyncing == true) }
        }.padding(28)
        }.buttonStyle(QuietButtonStyle()).frame(width: 540, height: 660)
            .sheet(isPresented: $showDeleted) { RecentlyDeletedView(model: model) }
            .interactiveDismissDisabled(model.sync?.isSyncing == true)
            .onExitCommand { if model.sync?.isSyncing != true { model.settings = false } }
    }
}
