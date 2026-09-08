import SwiftUI
import AppKit
import NotoCore

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var draft = ""
    @Published var composerPosition: CGPoint?
    @Published var readingRequested = true
    @Published var search = "" { didSet { if search != oldValue { reload(reset: true) } } }
    @Published var hasMore = false
    @Published var loadingMore = false
    @Published var message = ""
    @Published var isError = false
    @Published var busy = false
    @Published var conversation: Entry?
    @Published var messages: [ChatMessage] = []
    @Published var chatDraft = ""
    @Published var chatError = ""
    @Published var editing: Entry?
    @Published var editError = ""
    @Published var editDraft = ""
    @Published var editHasDue = false
    @Published var editDate = Date()
    @Published var settings = false
    @Published var undoAvailable = false
    @Published var provider: Provider { didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") } }
    private(set) var store: Store?
    let preview: Bool
    private var undoBefore: [Entry] = []
    private var undoAfter: [Entry] = []
    private var runner: AgentRunner?
    private var timer: Timer?
    private var dataVersion: Int?
    private let pageSize = 40
    private var chatDrafts: [String: String] = [:]

    init(store injectedStore: Store? = nil) {
        preview = injectedStore == nil && CommandLine.arguments.contains("--preview")
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "opencode") ?? .opencode
        do {
            store = try injectedStore ?? Store(url: preview ? nil : Store.defaultURL)
            if preview {
                _ = try store?.add(kind: "todo", text: "整理草图", due: Self.dateKey(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
                _ = try store?.add(kind: "note", text: "今天想清楚了产品方向。")
                draft = "记一下，今天想清楚了产品方向。明天下午把草图整理好。"
                message = "已记下，并添加了明天的待办。"
                undoAfter = try store?.list() ?? []; undoAvailable = true
            }
        } catch { store = nil; message = "无法打开数据：\(error.localizedDescription)"; isError = true }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfChanged() }
        }
    }

    static func dateKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    var filtered: [Entry] { entries }
    struct DayGroup: Identifiable {
        let id: String
        let date: Date
        var entries: [Entry]
        var label: String {
            if Calendar.current.isDateInToday(date) { return "今天" }
            if Calendar.current.isDateInYesterday(date) { return "昨天" }
            let f = DateFormatter(); f.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "M月d日" : "yyyy年M月d日"
            return f.string(from: date)
        }
        var shortLabel: String {
            let f = DateFormatter(); f.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "MM.dd" : "yy.MM.dd"
            return f.string(from: date)
        }
    }
    var groups: [DayGroup] {
        var result: [DayGroup] = []
        var visible = entries
        // Keep an active editor reachable if an external change removes its search match.
        if let editing, !visible.contains(where: { $0.id == editing.id }) {
            visible.append(editing)
            visible.sort { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
        }
        for entry in visible {
            let key = Self.dateKey(entry.createdAt)
            if result.last?.id == key { result[result.count - 1].entries.append(entry) }
            else { result.append(DayGroup(id: key, date: entry.createdAt, entries: [entry])) }
        }
        return result
    }
    func reload(reset: Bool = false) {
        do {
            guard let store else { return }
            let version = try store.dataVersion()
            let page = try store.page(limit: reset ? pageSize : max(pageSize, entries.count), search: search)
            if page.entries != entries { entries = page.entries }
            hasMore = page.hasMore
            dataVersion = version
        } catch { fail(error) }
    }
    func refreshIfChanged() {
        do { if let version = try store?.dataVersion(), version != dataVersion { reload() } }
        catch { fail(error) }
    }
    func loadMore() {
        guard hasMore, !loadingMore, let cursor = entries.last, let store else { return }
        loadingMore = true
        do {
            let page = try store.page(before: cursor, limit: pageSize, search: search)
            entries.append(contentsOf: page.entries)
            hasMore = page.hasMore
        } catch { fail(error) }
        loadingMore = false
    }
    func fail(_ error: Error) { message = error.localizedDescription; isError = true }
    var editDue: String? { editHasDue ? Self.dateKey(editDate) : nil }
    var editDirty: Bool { editing.map { editDraft != $0.text || editDue != $0.due } ?? false }
    @discardableResult
    func leaveUnchangedEditor() -> Bool {
        guard !editDirty else {
            editError = "请先保存或取消当前编辑。"
            message = editError; isError = true
            return false
        }
        editing = nil
        return true
    }
    func showComposer(at point: CGPoint = CGPoint(x: 24, y: 40)) {
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
        editing = entry; editDraft = entry.text; editError = ""; editHasDue = entry.due != nil
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        editDate = entry.due.flatMap { f.date(from: $0) } ?? Date()
    }
    func saveEditing() {
        guard let editing, !editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        update(editing, text: editDraft, due: editDue)
    }
    func cancelEditing() { editing = nil; editError = "" }
    func setSearch(_ value: String) {
        guard leaveUnchangedEditor() else { return }
        search = value
    }
    func submitFocusedInput() {
        guard !settings else { return }
        if let input = NSApp.keyWindow?.firstResponder as? InputTextView { input.submit() }
        else if editing != nil { saveEditing() }
        else if composerPosition != nil { ask() }
    }
    func remember(before: [Entry], after: [Entry], message: String) {
        undoBefore = before; undoAfter = after; undoAvailable = !after.isEmpty
        self.message = message; isError = false; reload()
    }
    func save(todo: Bool = false) {
        guard !busy, let store else { return }
        var content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let isTodo = todo || content.hasPrefix("/todo ") || content.hasPrefix("待办：")
        if content.hasPrefix("/todo ") { content = String(content.dropFirst(6)) }
        if content.hasPrefix("待办：") { content = String(content.dropFirst(3)) }
        do {
            let entry = try store.add(kind: isTodo ? "todo" : "note", text: content)
            draft = ""; composerPosition = nil
            remember(before: [], after: [entry], message: isTodo ? "已添加待办。" : "已记下。")
        } catch { fail(error) }
    }
    func toggle(_ entry: Entry) {
        guard let store else { return }
        do {
            let changed = try store.setCompleted(id: entry.id, completed: !entry.completed)
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
        do { try store?.undo(before: undoBefore, after: undoAfter); undoAvailable = false; message = "已撤销。"; isError = false; reload() }
        catch { fail(error) }
    }
    func ask() {
        guard !busy, composerPosition != nil, let store else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        do {
            if let conversation { chatDrafts[conversation.id] = chatDraft }
            conversation = try store.startConversation(input)
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
    func requestReply() {
        guard !busy, let store, let question = messages.last, question.role == "user" else { return }
        let history = Array(messages.dropLast()), context = filtered
        let selectedProvider = provider
        let active = AgentRunner(); runner = active
        busy = true; chatError = ""
        let startedAt = Date()
        recordExecution("已读取 \(history.count) 条历史消息与 \(context.count) 条笔记", for: question)
        Task {
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try active.run(prompt: question.text, entries: context, provider: selectedProvider, history: history) { event in
                        Task { @MainActor in self.recordExecution(event, for: question) }
                    }
                }.value
                let changed = try store.apply(response.actions, expected: context, replyingTo: question, reply: response.message)
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
                .frame(minWidth: 620, minHeight: 480)
                .onAppear {
                    if model.preview && CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow {
                            window.titleVisibility = .hidden
                            window.titlebarAppearsTransparent = true
                            window.titlebarSeparatorStyle = .none
                            window.styleMask.insert(.fullSizeContentView)
                            window.isMovableByWindowBackground = true
                            window.backgroundColor = NSColor.textBackgroundColor
                            if model.preview { window.setContentSize(NSSize(width: 1340, height: 954)); window.center() }
                        }
                    }
                }
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建内容") { model.showComposer() }.keyboardShortcut("n")
                Button("提交当前输入") { model.submitFocusedInput() }.keyboardShortcut(.return, modifiers: .command)
                Button("添加待办") { model.save(todo: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(model.composerPosition == nil || model.busy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销文本编辑") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }.keyboardShortcut("z")
                Button("重做文本编辑") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }.keyboardShortcut("z", modifiers: [.command, .option])
                Button("撤销上次记录操作") { model.undo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.undoAvailable)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索记录") {
                    guard model.leaveUnchangedEditor() else { return }
                    model.composerPosition = nil
                    model.closeConversation()
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                }.keyboardShortcut("k")
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
private enum NotoDesign {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let field = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor).opacity(0.6)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 12)
    static let radius: CGFloat = 12
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion && NSApp.currentEvent?.type == .leftMouseDown ? 0.97 : 1)
            .contentShape(Rectangle())
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
                    if !model.message.isEmpty { feedback.padding(.horizontal, 24).padding(.bottom, 16) }
                    }
                    .overlay(alignment: .top) {
                        HStack {
                            Button {
                                withAnimation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) { datesExpanded.toggle() }
                            } label: { Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 20, height: 20) }
                                .buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).disabled(model.entries.isEmpty)
                                .help(datesExpanded ? "收起日期侧栏" : "展开日期侧栏")
                                .accessibilityLabel(datesExpanded ? "收起日期侧栏" : "展开日期侧栏")
                            if narrow && model.conversation != nil {
                                Button {
                                    guard model.leaveUnchangedEditor() else { return }
                                    model.composerPosition = nil; model.readingRequested = false
                                } label: { Image(systemName: "bubble.left.and.bubble.right").frame(width: 20, height: 20) }
                                    .buttonStyle(QuietButtonStyle()).help("返回当前对话").accessibilityLabel("返回当前对话")
                            }
                            Spacer()
                            SearchInput(text: Binding(get: { model.search }, set: { model.setSearch($0) })).frame(width: 190, height: 28)
                        }.padding(.leading, 86).padding(.trailing, 20).padding(.top, 10)
                    }
                }
                if model.conversation != nil && (!narrow || showChatOnly) {
                    if !narrow { Divider() }
                    ConversationView(model: model)
                        .frame(width: narrow ? geometry.size.width : min(440, max(340, geometry.size.width * 0.37)))
                }
            }
        }
        .background(NotoDesign.canvas).foregroundStyle(.primary)
        .ignoresSafeArea(.container, edges: .top)
        .onExitCommand {
            if model.editing != nil { model.cancelEditing() }
            else if model.composerPosition != nil { model.composerPosition = nil }
            else if !model.search.isEmpty { model.setSearch("") }
            else { model.closeConversation() }
        }
        .sheet(isPresented: $model.settings) { SettingsView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() }
    }
    private var feedback: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isError ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(model.isError ? Color.red : Color.secondary)
            Text(model.message).font(NotoDesign.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.undoAvailable { Button("撤销") { model.undo() }.buttonStyle(QuietButtonStyle()).help("撤销上次记录操作（⌘⇧Z）") }
            Button { model.message = "" } label: { Image(systemName: "xmark").frame(width: 18, height: 18) }
                .buttonStyle(QuietButtonStyle()).accessibilityLabel("关闭操作提示")
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
                                Image(systemName: model.search.isEmpty ? "square.and.pencil" : "magnifyingglass")
                                    .font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                                Text(model.search.isEmpty ? "留下一点今天。" : "没有找到相关记录").font(.system(size: 17, weight: .medium))
                                Text(model.search.isEmpty ? "双击空白处开始，或按 ⌘N。\n⌘ 回车发送给 AI，也可以记为小记或待办。" : "试试更短的关键词，也可以搜索对话里的内容。")
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                                if !model.search.isEmpty {
                                    Button("清空搜索") { model.setSearch("") }.buttonStyle(QuietButtonStyle()).font(NotoDesign.caption)
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
                                        VStack(spacing: 4) {
                                            ForEach(group.entries) { entry in EntryRow(entry: entry, model: model).excludeFromBlankInput() }
                                        }
                                    }.id("content-" + group.id)
                                        .background(GeometryReader { frame in
                                            Color.clear.preference(key: DayPositions.self, value: [group.id: frame.frame(in: .named("history")).minY])
                                        })
                                }
                                if model.hasMore {
                                    Button("加载更早的记录") { model.loadMore() }
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
                Text("写点什么").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { model.composerPosition = nil } label: { Image(systemName: "xmark").frame(width: 18, height: 18) }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("收起录入，保留草稿")
            }
            Composer(text: $model.draft, enabled: true, purpose: .newContent, onSubmit: { model.ask() }, onCancel: { model.composerPosition = nil })
                .frame(minHeight: 48)
            if model.busy { Text("AI 正在回复，可以先写下下一条。完成后即可发送。").font(NotoDesign.caption).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Button("记为小记") { model.save() }
                Button("添加待办") { model.save(todo: true) }
                Spacer(minLength: 0)
                Button("发送给 AI  ⌘↵") { model.ask() }.buttonStyle(.borderedProminent)
            }.font(NotoDesign.caption).buttonStyle(QuietButtonStyle()).disabled(empty || model.busy)
            Text("回车换行 · Esc 收起并保留草稿").font(.system(size: 11)).foregroundStyle(.secondary)
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
    private var pending: Bool { model.messages.last?.role == "user" }
    private var status: String {
        if model.busy { return "正在回复" }
        if !model.chatError.isEmpty { return "回复未完成" }
        if pending { return "等待重试" }
        if !model.chatDraft.isEmpty { return "草稿未发送" }
        return "对话已保存"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("对话").font(.system(size: 17, weight: .semibold))
                    Text(status).font(NotoDesign.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.closeConversation() } label: { Image(systemName: "xmark").frame(width: 18, height: 18) }
                    .buttonStyle(QuietButtonStyle()).help(model.busy ? "停止回复后可关闭" : "关闭对话（Esc）").accessibilityLabel("关闭对话").disabled(model.busy)
            }.padding(.horizontal, 24).padding(.top, 54).padding(.bottom, 20)
            Divider().padding(.horizontal, 24)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(message.role == "user" ? "你" : "AI").font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(message.createdAt, style: .time).font(.system(size: 11)).monospacedDigit()
                                }.foregroundStyle(.secondary)
                                Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
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
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在整理，完成后显示回复…").font(NotoDesign.caption).foregroundStyle(.secondary) }
                        }
                        if !model.chatError.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("这次回复没有完成", systemImage: "exclamationmark.circle").font(.system(size: 13, weight: .medium))
                                Text(model.chatError).font(NotoDesign.caption).textSelection(.enabled)
                                Text("问题已保存，可以重试。").font(NotoDesign.caption).foregroundStyle(.secondary)
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
                if pending && !model.busy {
                    HStack {
                        Text("上一条问题还没有回复").font(NotoDesign.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("重试") { model.requestReply() }.buttonStyle(.bordered)
                    }
                }
                Composer(text: $model.chatDraft, enabled: true, purpose: .chat, onSubmit: { model.sendChat() }, onCancel: { model.closeConversation() })
                    .frame(minHeight: 40).fixedSize(horizontal: false, vertical: true)
                    .padding(14).background(NotoDesign.field, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
                    .overlay(RoundedRectangle(cornerRadius: NotoDesign.radius).stroke(NotoDesign.line, lineWidth: 0.5))
                HStack {
                    Text("⌘↵ 发送 · 回车换行").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if model.busy {
                        Button { model.cancel() } label: { Label("停止", systemImage: "stop.fill") }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button { model.sendChat() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).frame(width: 24, height: 24) }
                            .buttonStyle(QuietButtonStyle()).foregroundStyle(Color.accentColor).help("发送消息（⌘ 回车）").accessibilityLabel("发送消息")
                            .disabled(pending || model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.font(NotoDesign.caption)
            }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 12)
        }.background(Color(nsColor: .windowBackgroundColor))
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
            if expanded { Text("日期").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 20) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: expanded ? 6 : 2) {
                        ForEach(model.groups) { group in
                            let selected = selectedID == group.id
                            Button { navigate(group.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "minus").font(.system(size: selected ? 13 : 9, weight: selected ? .semibold : .regular)).frame(width: 16)
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
                    Spacer(minLength: 0)
                    if entry.hasConversation {
                        Button { model.openConversation(entry) } label: { Label("对话", systemImage: "bubble.left.and.bubble.right").font(.system(size: 11)) }
                            .buttonStyle(QuietButtonStyle()).foregroundStyle(model.conversation?.id == entry.id ? Color.accentColor : Color.secondary)
                            .help("打开对话").accessibilityLabel("打开对话").disabled(model.busy)
                    }
                    Button(action: edit) { Image(systemName: "pencil").font(.system(size: 12)).frame(width: 16, height: 18) }
                        .buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).help("编辑记录").accessibilityLabel("编辑记录")
                }
            }
        }
        .padding(12)
        .background(model.conversation?.id == entry.id ? Color.accentColor.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .contextMenu {
            Button("编辑", action: edit)
            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
            if entry.hasConversation { Button("打开对话") { model.openConversation(entry) }.disabled(model.busy) }
        }
        }
        }
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
        case .newContent: view.placeholder = "写下想法，⌘ 回车发送给 AI。"
        case .chat: view.placeholder = "继续聊…"
        case .edit: view.placeholder = "记录内容不能为空。"
        }
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
        view.isEditable = enabled; view.needsDisplay = true
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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let view = NSSearchField()
        view.sendsSearchStringImmediately = true
        view.sendsWholeSearchString = false
        view.controlSize = .regular
        view.placeholderString = "搜索笔记与对话"; view.font = .systemFont(ofSize: 13)
        view.delegate = context.coordinator; view.setAccessibilityLabel("搜索")
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .focusSearch, object: nil, queue: .main) { [weak view] _ in view?.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: NSSearchField, context: Context) { context.coordinator.parent = self; if view.stringValue != text { view.stringValue = text } }
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
                    Toggle("截止日期", isOn: $model.editHasDue).toggleStyle(.checkbox)
                    Spacer()
                    if model.editHasDue { DatePicker("截止日期", selection: $model.editDate, displayedComponents: .date).labelsHidden().accessibilityLabel("截止日期") }
                }.font(NotoDesign.caption)
            }
            if entry.hasConversation {
                Text("仅修改列表中的文字，原始问答历史保持不变。").font(NotoDesign.caption).foregroundStyle(.secondary)
            }
            if !model.editError.isEmpty {
                Label(model.editError, systemImage: "exclamationmark.circle").font(NotoDesign.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("回车换行 · ⌘↵ 保存").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("取消") { model.cancelEditing() }.buttonStyle(QuietButtonStyle())
                Button("保存") { model.saveEditing() }.buttonStyle(.borderedProminent)
                    .disabled(model.editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(NotoDesign.caption)
        }.padding(16)
            .background(NotoDesign.field, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
            .overlay(RoundedRectangle(cornerRadius: NotoDesign.radius).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("设置").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                Picker("AI CLI", selection: $model.provider) {
                    ForEach(Provider.allCases) { provider in Text(provider.title).tag(provider) }
                }
                Text("使用本机已安装并登录的 AI CLI。\n更改后，将在下一轮对话中使用。").font(NotoDesign.caption).foregroundStyle(.secondary).lineSpacing(4)
            }
            Divider()
            HStack { Spacer(); Button("完成") { model.settings = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 340)
            .onExitCommand { model.settings = false }
    }
}
