import SwiftUI
import NotoCore
import NotoSync

@main
struct NotoIOSApp: App {
    private let startup: Result<Store, Error> = Result {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noto-ui-tests", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("-reset-testing"), FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try Store(url: folder.appendingPathComponent("notes.sqlite"))
        }
        return try Store()
    }
    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let store): TaskHome(store: store)
            case .failure(let error): ContentUnavailableView("无法打开本地数据", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
            }
        }
    }
}

private struct EditorSelection: Identifiable {
    let id = UUID()
    let entry: Entry?
    let store: Store
    let scope: String
}

struct TaskHome: View {
    @StateObject private var sync: SyncController
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [Entry] = []
    @State private var filter = "open"
    @State private var important = false
    @State private var dated = false
    @State private var search = ""
    @State private var editor: EditorSelection?
    @State private var settings = false
    @State private var recentlyDeleted = false
    @State private var error = ""
    init(store: Store) { _sync = StateObject(wrappedValue: SyncController(localStore: store)) }

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label(hasFilters ? "没有匹配的待办" : "暂时没有待办", systemImage: "checklist")
                    } description: {
                        Text(hasFilters ? "换个筛选，或记录一件新待办。" : "把下一件事记下来。")
                    } actions: {
                        if hasFilters { Button("清除筛选", action: clearFilters) }
                        Button("新增待办", systemImage: "plus") { openEditor() }.accessibilityIdentifier("empty-add-todo")
                    }
                } else if dated {
                    let groups = Dictionary(grouping: entries, by: { $0.due ?? "未设置日期" })
                    ForEach(groups.keys.sorted(), id: \.self) { date in
                        Section(date) { ForEach(groups[date] ?? []) { row($0) } }
                    }
                } else {
                    Section { ForEach(entries) { row($0) } }
                }
            }
            .navigationTitle("待办")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索待办")
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Button { settings = true } label: {
                        Label(sync.isSignedIn ? "账号 · \(sync.email ?? "")" : "本机 · 仅这台设备", systemImage: sync.isSignedIn ? "icloud" : "iphone")
                            .lineLimit(1)
                    }.buttonStyle(.plain).accessibilityIdentifier("storage-scope")
                    HStack {
                        Text(filterSummary).accessibilityIdentifier("filter-summary")
                        Spacer()
                        if hasFilters { Button("清除", action: clearFilters).accessibilityLabel("清除筛选") }
                    }
                    if !sync.lastError.isEmpty {
                        Button { settings = true } label: { Label("同步未完成，修改已保留", systemImage: "exclamationmark.icloud") }
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("同步设置", systemImage: "person.crop.circle") { settings = true } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("状态", selection: $filter) {
                            Text("未完成").tag("open")
                            ForEach(TodoStatus.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                            Text("全部").tag("all")
                        }
                        Toggle("只看重要", isOn: $important)
                        Toggle("按日期浏览", isOn: $dated)
                        Divider()
                        Button("最近删除", systemImage: "trash") { recentlyDeleted = true }
                    } label: { Image(systemName: hasFilters || dated ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("筛选与显示")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("新增待办", systemImage: "plus") { openEditor() }.accessibilityIdentifier("add-todo") }
            }
            .refreshable { await sync.syncNow(); await reload() }
            .task { if !ProcessInfo.processInfo.arguments.contains("-ui-testing") { await sync.restoreSession() }; await reload() }
            .task(id: "\(search)|\(filter)|\(important)") {
                do { try await Task.sleep(for: .milliseconds(150)); await reload() } catch {}
            }
            .onChange(of: ObjectIdentifier(sync.store)) { _, _ in entries = []; Task { await reload() } }
            .onChange(of: sync.dataRevision) { _, _ in Task { await reload() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await sync.syncNow(); await reload() } } }
            .sheet(item: $editor) { selection in
                TodoEditor(store: selection.store, entry: selection.entry, scope: selection.scope) { entry in
                    if selection.entry == nil, selection.store === sync.store {
                        search = ""
                        if important && entry.priority != "important" { important = false }
                        if filter != "all", filter != entry.status, !(filter == "open" && !entry.completed) { filter = entry.completed ? "completed" : "open" }
                    }
                    Task { await reload(); await sync.syncNow() }
                }
            }
            .sheet(isPresented: $settings, onDismiss: { Task { await reload() } }) { SyncSettings(sync: sync) }
            .sheet(isPresented: $recentlyDeleted, onDismiss: { Task { await reload() } }) { RecentlyDeleted(sync: sync) }
            .alert("操作未完成", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
        }
    }

    private var hasFilters: Bool { filter != "open" || important || !search.isEmpty }
    private var filterSummary: String {
        let status = filter == "open" ? "未完成" : filter == "all" ? "全部" : TodoStatus(rawValue: filter)?.label ?? "未完成"
        return ([status] + (important ? ["重要"] : []) + (dated ? ["按日期"] : []) + ["\(entries.count) 项"]).joined(separator: " · ")
    }
    private func clearFilters() { filter = "open"; important = false; search = "" }
    private func openEditor(_ entry: Entry? = nil) {
        editor = EditorSelection(entry: entry, store: sync.store, scope: sync.isSignedIn ? "账号 · \(sync.email ?? "")" : "本机 · 仅这台设备")
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Button {
                mutate { _ = try sync.store.setCompleted(id: entry.id, completed: !entry.completed, expected: entry) }
            } label: {
                Image(systemName: entry.completed ? "checkmark.circle.fill" : entry.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
                    .font(.title2).foregroundStyle(entry.completed ? Color.green : entry.status == "in_progress" ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.borderless).accessibilityLabel(entry.completed ? "恢复待办" : "完成待办")
            Button { openEditor(entry) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.text).foregroundStyle(.primary).strikethrough(entry.completed).lineLimit(3)
                    if entry.status == "in_progress" || entry.due != nil {
                        HStack(spacing: 8) {
                            if entry.status == "in_progress" { Text("进行中").foregroundStyle(Color.accentColor) }
                            if let due = entry.due { Text(due).foregroundStyle(.secondary) }
                        }.font(.caption)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(entry.text)
            if entry.priority == "important" { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("重要") }
        }
        .swipeActions { Button("删除", role: .destructive) { mutate { try sync.store.deleteTodo(id: entry.id, expected: entry) } } }
    }

    private func mutate(_ action: () throws -> Void) {
        do { try action(); Task { await reload(); await sync.syncNow() } }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func reload() async {
        let store = sync.store, query = search, status = filter, priority: String? = important ? "important" : nil
        do {
            let result = try await Task.detached { try store.todos(search: query, status: status, priority: priority) }.value
            guard !Task.isCancelled, store === sync.store, query == search, status == filter, priority == (important ? "important" : nil) else { return }
            entries = result
        } catch { self.error = error.localizedDescription }
    }
}

private struct TodoEditor: View {
    let store: Store
    let entry: Entry?
    let scope: String
    let saved: (Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var important: Bool
    @State private var status: TodoStatus
    @State private var hasDate: Bool
    @State private var due: Date
    @State private var showCalendar = false
    @State private var discardConfirmation = false
    @State private var error = ""
    @FocusState private var textFocused: Bool
    private static var dateFormat: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }
    init(store: Store, entry: Entry?, scope: String, saved: @escaping (Entry) -> Void) {
        self.store = store; self.entry = entry; self.scope = scope; self.saved = saved
        _text = State(initialValue: entry?.text ?? "")
        _important = State(initialValue: entry?.priority == "important")
        _status = State(initialValue: TodoStatus(rawValue: entry?.status ?? "pending") ?? .pending)
        _hasDate = State(initialValue: entry?.due != nil)
        _due = State(initialValue: entry?.due.flatMap { Self.dateFormat.date(from: $0) } ?? Date())
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 160).accessibilityLabel("待办内容").focused($textFocused)
                } footer: { Text("保存到\(scope)") }
                Section {
                    Picker("状态", selection: $status) {
                        ForEach(TodoStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("todo-status")
                    Toggle(isOn: $important) { Label("重要", systemImage: important ? "star.fill" : "star") }.tint(.orange)
                    HStack {
                        Label("日期", systemImage: "calendar")
                        Spacer()
                        Menu {
                            Button("今天") { selectDate(Date()) }
                            Button("明天") { selectDate(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) }
                            Button("选择日期…") { textFocused = false; showCalendar.toggle() }
                            if hasDate { Button("清除日期") { hasDate = false; showCalendar = false } }
                        } label: { Text(hasDate ? Self.dateFormat.string(from: due) : "未设置") }
                        .accessibilityLabel("待办日期").accessibilityValue(hasDate ? Self.dateFormat.string(from: due) : "未设置")
                    }
                    if showCalendar {
                        DatePicker("选择日期", selection: $due, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .onChange(of: due) { _, _ in hasDate = true }
                        if !hasDate { Button("使用此日期") { hasDate = true; showCalendar = false } }
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.navigationTitle(entry == nil ? "新增待办" : "编辑待办")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { if hasChanges { textFocused = false; discardConfirmation = true } else { dismiss() } } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                .interactiveDismissDisabled(hasChanges)
                .alert("有尚未保存的修改", isPresented: $discardConfirmation) {
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                } message: { Text("关闭后，这些修改不会保存。") }
                .task { if entry == nil { textFocused = true } }
        }
    }
    private var hasChanges: Bool {
        text != (entry?.text ?? "") || important != (entry?.priority == "important") || status.rawValue != (entry?.status ?? "pending") || (hasDate ? Self.dateFormat.string(from: due) : nil) != entry?.due
    }
    private func selectDate(_ date: Date) { due = date; hasDate = true; showCalendar = false; textFocused = false }
    private func save() {
        do {
            let date = hasDate ? Self.dateFormat.string(from: due) : nil
            let result: Entry
            if let entry {
                result = try store.updateTodo(id: entry.id, text: text, due: date, clearDue: !hasDate, status: status.rawValue, priority: important ? "important" : "normal", expected: entry)
            } else {
                result = try store.add(kind: "todo", text: text, due: date, status: status.rawValue, priority: important ? "important" : "normal")
            }
            saved(result); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct RecentlyDeleted: View {
    @ObservedObject var sync: SyncController
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView("没有最近删除的待办", systemImage: "trash", description: Text("删除的待办会保留在这里，可随时恢复。"))
                } else {
                    Section {
                        ForEach(entries) { entry in
                            HStack {
                                Text(entry.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                Button("恢复", systemImage: "arrow.uturn.backward") {
                                    do { try sync.store.restoreTodo(id: entry.id); reload(); Task { await sync.syncNow() } }
                                    catch { self.error = error.localizedDescription }
                                }.labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("恢复\(entry.text)")
                            }
                        }
                    } footer: { Text(sync.isSignedIn ? "当前账号中删除的待办。恢复后会同步到其他设备。" : "仅显示这台设备本机数据中删除的待办。") }
                }
            }
            .navigationTitle("最近删除").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { reload() }
            .onChange(of: sync.dataRevision) { _, _ in reload() }
            .onChange(of: ObjectIdentifier(sync.store)) { _, _ in reload() }
            .alert("恢复未完成", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
        }
    }
    private func reload() { do { entries = try sync.store.deletedTodos() } catch { self.error = error.localizedDescription } }
}

private struct SyncSettings: View {
    @ObservedObject var sync: SyncController
    @Environment(\.dismiss) private var dismiss
    @State private var supabase = ""
    @State private var key = ""
    @State private var powersync = ""
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""
    @State private var importConfirmation = false
    @State private var advanced = false
    @State private var configurationSaved = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(sync.isSignedIn ? "当前使用账号数据" : "当前使用本机数据", systemImage: sync.isSignedIn ? "icloud" : "iphone")
                    Text(sync.isSignedIn ? "账号待办可在其他已登录设备使用；本机待办独立保留。" : "无需登录，待办保存在这台设备上。登录账号后可跨设备同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("数据存储") }
                Section("账号") {
                    if sync.isSignedIn {
                        Text(sync.email ?? "已登录")
                        Button("立即同步") { Task { await sync.syncNow() } }.disabled(sync.isSyncing)
                        Button("导入本机待办") { importConfirmation = true }.disabled(sync.isSyncing)
                        Button("退出登录", role: .destructive) { Task { await sync.signOut() } }
                            .disabled(sync.isSyncing)
                        Text("退出后返回本机待办，账号数据保留。") .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        TextField("邮箱", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        SecureField("密码", text: $password).textContentType(.password)
                        Button("登录") { Task { await sync.signIn(email: email, password: password); password = "" } }.disabled(sync.configuration == nil || email.isEmpty || password.isEmpty || sync.isSyncing)
                        if sync.configuration == nil {
                            Button("设置账号连接") { advanced = true }
                        }
                        Text("使用已有账号登录。本机待办仅在你选择导入后上传。") .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !sync.conflicts.isEmpty {
                    Section("需要处理的修改") {
                        ForEach(sync.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(conflict.text).textSelection(.enabled)
                                Text(conflict.reason).font(.caption).foregroundStyle(.secondary)
                                if conflict.reason != "已另存为新任务" {
                                    Button("另存为新待办") { Task { await sync.recoverConflict(id: conflict.id) } }
                                }
                            }
                        }
                    }
                }
                if sync.isSignedIn || !sync.lastError.isEmpty || !error.isEmpty {
                    Section("同步状态") {
                        Text(sync.status)
                        if sync.isSignedIn { Text("待同步：\(sync.pendingCount) 项") }
                        if !sync.lastError.isEmpty { Text(sync.lastError).foregroundStyle(.red) }
                        if !error.isEmpty { Text(error).foregroundStyle(.red) }
                    }
                }
                Section {
                    DisclosureGroup("高级配置", isExpanded: $advanced) {
                        TextField("Supabase URL", text: $supabase).keyboardType(.URL)
                        TextField("Publishable key", text: $key)
                        TextField("PowerSync URL", text: $powersync).keyboardType(.URL)
                        Button("保存配置") {
                            do {
                                guard let url = URL(string: supabase), let power = URL(string: powersync) else { throw NotoError("请输入有效的服务地址") }
                                try sync.configure(SyncConfiguration(supabaseURL: url, publishableKey: key, powerSyncURL: power))
                                error = ""; configurationSaved = true
                            } catch { self.error = error.localizedDescription }
                        }.disabled(sync.isSignedIn || sync.isSyncing)
                        if configurationSaved { Label("配置已保存", systemImage: "checkmark.circle").foregroundStyle(.green) }
                        if sync.isSignedIn { Text("退出账号后可更换连接配置。").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("账号与同步")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear {
                    if let config = sync.configuration { supabase = config.supabaseURL.absoluteString; key = config.publishableKey; powersync = config.powerSyncURL.absoluteString }
                }
                .confirmationDialog("将这台设备的本机待办复制到当前账号并上传？", isPresented: $importConfirmation, titleVisibility: .visible) {
                    Button("导入本机待办") { Task { await sync.importLocalTasks() } }
                }
        }
    }
}
