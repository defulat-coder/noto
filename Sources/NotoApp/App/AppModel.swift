import SwiftUI
import AppKit
import Combine
import NotoCore
import NotoSync

// 应用级状态中枢：持有数据快照、加载管线与账号切换。
// 业务动作按域拆在 AppModel+Editing / +Conversation / +Tasks。
@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [Entry] = [] { didSet { cachedGroups = nil } }
    @Published var tasks: [Entry] = [] { didSet { invalidateTaskViews() } }
    @Published var mode: ContentMode = .notes { didSet { if persistsViewMode { UserDefaults.standard.set(mode.rawValue, forKey: "contentMode") } } }
    @Published var selectedCalendarDate = Date()
    @Published var calendarUnscheduled = false
    @Published var taskDraftStarted = false
    @Published var taskDraftRestored = false
    var taskDraftBaseline = TaskDraftAttributes()
    @Published var dueOnly = false { didSet { invalidateTaskViews() } }
    @Published var importantOnly = false { didSet { invalidateTaskViews() } }
    @Published var completedLimit = 20
    @Published var taskCreating = false
    @Published var taskDraftStatus = "pending"
    @Published var taskDraftImportant = false
    @Published var taskDraftHasDue = false
    @Published var taskDraftDate = Date()
    @Published var editStatus = "pending"
    @Published var editImportant = false
    @Published var convertedTaskID: String?
    @Published var highlightedTaskID: String?
    var taskToEditAfterReload: String?
    @Published var composerPosition: CGPoint?
    @Published var readingRequested = true
    // 输入侧去抖在 SearchInput（commitDelay）；这里收到提交后立即刷新。
    @Published var search = "" { didSet { if search != oldValue { completedLimit = 20; reload(reset: true) } } }
    @Published var hasMore = false
    @Published var loadingMore = false
    @Published var message = ""
    @Published var isError = false
    @Published var busy = false
    @Published internal(set) var activeProvider: Provider?
    @Published var newConversationOpen = false
    var newConversationDraft = ""
    var conversationVisible: Bool { conversation != nil || newConversationOpen }
    @Published var conversation: Entry?
    @Published var messages: [ChatMessage] = []
    @Published var chatError = ""
    @Published var editing: Entry? { didSet { cachedGroups = nil } }
    @Published var editError = ""
    @Published var editHasDue = false
    @Published var editDate = Date()
    @Published var settings = false
    @Published var recentlyDeleted = false
    @Published var aiUsesCurrentView = false
    @Published var undoAvailable = false
    @Published var provider: Provider { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") } }
    private(set) var store: Store?
    private(set) var pill: PillController?
    @Published private(set) var sync: SyncController?
    @Published internal(set) var lastDeletedTaskID: String?
    private var syncSubscriptions = Set<AnyCancellable>()
    let preview: Bool
    private let persistsViewMode: Bool
    var undoBefore: [Entry] = []
    var undoAfter: [Entry] = []
    var runner: AgentRunner?
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
    var chatDrafts: [String: String] = [:]
    /// 逐键变化的输入文本在这里（见 TextDrafts）；以下计算属性保持既有 API。
    let drafts = TextDrafts()
    var draft: String {
        get { drafts.composer }
        set { drafts.composer = newValue }
    }
    var chatDraft: String {
        get { drafts.chat }
        set { drafts.chat = newValue }
    }
    var taskDraft: String {
        get { drafts.task }
        set { drafts.task = newValue }
    }
    var editDraft: String {
        get { drafts.edit }
        set { drafts.edit = newValue }
    }

    init(store injectedStore: Store? = nil) {
        preview = injectedStore == nil && CommandLine.arguments.contains("--preview")
        persistsViewMode = injectedStore == nil && !CommandLine.arguments.contains("--preview") && ProcessInfo.processInfo.environment["NOTO_DATABASE"] == nil
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "opencode") ?? .opencode
        pill = PillController(appModel: self)
        if injectedStore != nil || preview {
            do {
                store = try injectedStore ?? Store(url: preview ? nil : Store.defaultURL)
                if preview {
                    _ = try store?.add(kind: "todo", text: "整理草图", due: Self.dateKey(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
                    _ = try store?.add(kind: "note", text: "今天想清楚了产品方向。")
                    _ = try store?.add(kind: "todo", text: "梳理任务看板的交互细节", due: Self.dateKey(Date()), status: "in_progress", priority: "important")
                    _ = try store?.add(kind: "todo", text: "完成第一轮设计讨论", due: Self.dateKey(Date()), status: "completed")
                    draft = "记一下，今天想清楚了产品方向。明天下午把草图整理好。"
                    message = "已记下，并添加了明天的任务。"
                    undoAfter = try store?.list() ?? []; undoAvailable = true
                }
            } catch { store = nil; message = "无法打开数据：\(error.localizedDescription)"; isError = true }
        }
        if !preview && injectedStore == nil { try? AgentWorkspace.migrateLegacy() }
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
                        return try Store(url: url, busyTimeout: 1)
                    }.value
                    guard let self else { return }
                    self.store = store; self.attachSync(to: store)
                    // 本地数据先上屏；登录恢复（含 PowerSync 握手）放后台，网络慢时不再挡首屏。
                    self.opening = false; self.reload()
                    if ProcessInfo.processInfo.environment["NOTO_DATABASE"] == nil { await self.sync?.restoreSession() }
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
        guard draft.isEmpty, chatDraft.isEmpty, newConversationDraft.isEmpty, !chatDrafts.contains(where: { $0.key != conversation?.id && !$0.value.isEmpty }),
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
        entries = []; tasks = []; messages = []; conversation = nil; chatDrafts = [:]; newConversationOpen = false; newConversationDraft = ""
        aiUsesCurrentView = false
        undoBefore = []; undoAfter = []; undoAvailable = false; lastDeletedTaskID = nil
        editing = nil; editDraft = ""; editError = ""; draft = ""; chatDraft = ""; chatError = ""
        taskCreating = false; taskDraftStarted = false; taskDraft = ""; taskDraftHasDue = false; taskDraftImportant = false
        taskDraftStatus = "pending"; taskDraftBaseline = TaskDraftAttributes(); taskDraftRestored = false; dueOnly = false
        taskDraftStatus = "pending"; convertedTaskID = nil; highlightedTaskID = nil; taskToEditAfterReload = nil
        composerPosition = nil; readingRequested = true; message = ""; isError = false
        importantOnly = false; completedLimit = 20; hasMore = false
        if search.isEmpty { reload(reset: true) } else { search = "" }
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
                self.pill?.model.refresh()
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
}
