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
    @State private var error = ""
    init(store: Store) { _sync = StateObject(wrappedValue: SyncController(localStore: store)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("状态", selection: $filter) {
                        Text("未完成").tag("open")
                        Text("全部").tag("all")
                        Text("已完成").tag("completed")
                    }.pickerStyle(.segmented)
                    Toggle("只看重要", isOn: $important)
                    Toggle("按日期浏览", isOn: $dated)
                }
                if entries.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "暂时没有待办" : "没有匹配的待办", systemImage: "checklist", description: Text("点击右上角加号，记录下一件事。"))
                } else if dated {
                    let groups = Dictionary(grouping: entries, by: { $0.due ?? "未设置日期" })
                    ForEach(groups.keys.sorted(), id: \.self) { date in
                        Section(date) { ForEach(groups[date] ?? []) { row($0) } }
                    }
                } else {
                    Section { ForEach(entries) { row($0) } }
                }
                Section {
                    Button { settings = true } label: {
                        Label(sync.status, systemImage: sync.isSignedIn ? "icloud" : "iphone")
                    }
                    if !sync.lastError.isEmpty { Text(sync.lastError).font(.footnote).foregroundStyle(.red) }
                } footer: { Text(sync.isSignedIn ? "待同步：\(sync.pendingCount) 项" : "当前数据只保存在这台设备。") }
            }
            .navigationTitle("待办")
            .searchable(text: $search, prompt: "搜索待办")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("同步设置", systemImage: "person.crop.circle") { settings = true } }
                ToolbarItem(placement: .topBarTrailing) { Button("新增待办", systemImage: "plus") { editor = EditorSelection(entry: nil) } }
            }
            .refreshable { await sync.syncNow(); await reload() }
            .task { if !ProcessInfo.processInfo.arguments.contains("-ui-testing") { await sync.restoreSession() }; await reload() }
            .task(id: "\(search)|\(filter)|\(important)") {
                do { try await Task.sleep(for: .milliseconds(150)); await reload() } catch {}
            }
            .onChange(of: ObjectIdentifier(sync.store)) { _, _ in entries = []; editor = nil; Task { await reload() } }
            .onChange(of: sync.dataRevision) { _, _ in Task { await reload() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await sync.syncNow(); await reload() } } }
            .sheet(item: $editor) { selection in
                TodoEditor(store: sync.store, entry: selection.entry) { Task { await reload(); await sync.syncNow() } }
            }
            .sheet(isPresented: $settings, onDismiss: { Task { await reload() } }) { SyncSettings(sync: sync) }
            .alert("操作未完成", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Button {
                mutate { _ = try sync.store.setCompleted(id: entry.id, completed: !entry.completed, expected: entry) }
            } label: {
                Image(systemName: entry.completed ? "checkmark.circle.fill" : "circle").font(.title2)
            }.buttonStyle(.borderless).accessibilityLabel(entry.completed ? "恢复待办" : "完成待办")
            Button { editor = EditorSelection(entry: entry) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.text).foregroundStyle(.primary).strikethrough(entry.completed).lineLimit(3)
                    if let due = entry.due { Text(due).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
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
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var important: Bool
    @State private var hasDate: Bool
    @State private var due: Date
    @State private var error = ""
    private static var dateFormat: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }
    init(store: Store, entry: Entry?, saved: @escaping () -> Void) {
        self.store = store; self.entry = entry; self.saved = saved
        _text = State(initialValue: entry?.text ?? "")
        _important = State(initialValue: entry?.priority == "important")
        _hasDate = State(initialValue: entry?.due != nil)
        _due = State(initialValue: entry?.due.flatMap { Self.dateFormat.date(from: $0) } ?? Date())
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("内容") { TextEditor(text: $text).frame(minHeight: 120).accessibilityLabel("待办内容") }
                Toggle("重要", isOn: $important)
                Toggle("设置日期", isOn: $hasDate)
                if hasDate { DatePicker("日期", selection: $due, displayedComponents: .date) }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.navigationTitle(entry == nil ? "新增待办" : "编辑待办")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
    private func save() {
        do {
            let date = hasDate ? Self.dateFormat.string(from: due) : nil
            if let entry {
                _ = try store.updateTodo(id: entry.id, text: text, due: date, clearDue: !hasDate, priority: important ? "important" : "normal", expected: entry)
            } else {
                _ = try store.add(kind: "todo", text: text, due: date, priority: important ? "important" : "normal")
            }
            saved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
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
    var body: some View {
        NavigationStack {
            Form {
                Section("同步服务") {
                    TextField("Supabase URL", text: $supabase).keyboardType(.URL)
                    TextField("Publishable key", text: $key)
                    TextField("PowerSync URL", text: $powersync).keyboardType(.URL)
                    Button("保存配置") {
                        do {
                            guard let url = URL(string: supabase), let power = URL(string: powersync) else { throw NotoError("请输入有效的服务地址") }
                            try sync.configure(SyncConfiguration(supabaseURL: url, publishableKey: key, powerSyncURL: power))
                            error = ""
                        } catch { self.error = error.localizedDescription }
                    }.disabled(sync.isSignedIn)
                }
                Section("账号") {
                    if sync.isSignedIn {
                        Text(sync.email ?? "已登录")
                        Button("立即同步") { Task { await sync.syncNow() } }.disabled(sync.isSyncing)
                        Button("导入本机待办") { importConfirmation = true }
                        Button("退出登录", role: .destructive) { Task { await sync.signOut() } }
                    } else {
                        TextField("邮箱", text: $email).keyboardType(.emailAddress).textContentType(.username)
                        SecureField("密码", text: $password).textContentType(.password)
                        Button("登录") { Task { await sync.signIn(email: email, password: password); password = "" } }.disabled(sync.configuration == nil || email.isEmpty || password.isEmpty || sync.isSyncing)
                        Text("请使用已在同步服务中创建的账号。登录后，本机待办需手动导入。") .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !sync.conflicts.isEmpty {
                    Section("冲突版本") {
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
                Section("同步状态") {
                    Text(sync.status)
                    Text("待同步：\(sync.pendingCount) 项")
                    if !sync.lastError.isEmpty { Text(sync.lastError).foregroundStyle(.red) }
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("账号与同步")
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
