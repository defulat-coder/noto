import SwiftUI
import AppKit
import NotoCore

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("datesExpanded") private var datesExpanded = true
    @State private var activeDay: String?
    @State private var searchFocused = false
    @State private var sidebarPreview = false
    @State private var sidebarHoverTask: Task<Void, Never>?
    @Namespace private var navigationSelection
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 1100
            let showChatOnly = narrow && model.conversationVisible && !model.readingRequested
            HStack(spacing: 0) {
                if !showChatOnly {
                    ScrollViewReader { proxy in
                        HStack(spacing: 0) {
                            if datesExpanded {
                                sidebar(proxy: proxy, height: geometry.size.height)
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            VStack(spacing: 0) {
                                ZStack(alignment: .topLeading) {
                                    if model.mode == .calendar { TaskCalendar(model: model).transition(.opacity) }
                                    else if model.mode == .board { TaskBoard(model: model).transition(.opacity) }
                                    else {
                                        ReadingPane(model: model, activeDay: $activeDay).transition(.opacity)
                                            .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in
                                                if model.composerPosition == CGPoint(x: 24, y: 40) { proxy.scrollTo("history-top", anchor: .top) }
                                            }
                                            .onChange(of: model.search) { _, _ in
                                                activeDay = model.groups.first?.id; proxy.scrollTo("history-top", anchor: .top)
                                            }
                                    }
                                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .animation(NotoMotion.animation(.navigation), value: model.mode)
                                if !model.message.isEmpty {
                                    feedback.padding(.horizontal, 24).padding(.bottom, 16)
                                        .transition(.opacity.combined(with: .offset(y: 6)))
                                }
                            }.environment(\.blankInputEnabled, !sidebarPreview || datesExpanded)
                        }
                        .overlay(alignment: .topLeading) {
                            if !datesExpanded && !model.settings && !model.taskCreating && model.editing == nil {
                                ZStack(alignment: .topLeading) {
                                    Color.clear.frame(width: 12).contentShape(Rectangle())
                                        .onHover { sidebarHover($0) }
                                        .accessibilityHidden(true)
                                    if sidebarPreview {
                                        sidebar(proxy: proxy, height: geometry.size.height - 68)
                                            .frame(height: max(200, geometry.size.height - 68))
                                            .background(NotoSidebarSurface())
                                            .shadow(color: .black.opacity(0.12), radius: 16, x: 4, y: 4)
                                            .contentShape(RoundedRectangle(cornerRadius: 16))
                                            .onHover { sidebarHover($0) }
                                            .padding(8)
                                            .transition(.opacity.combined(with: .offset(x: -8)))
                                    }
                                }.frame(maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
                if model.conversationVisible && (!narrow || showChatOnly) {
                    if !narrow { Color.clear.frame(width: 20) }
                    ConversationView(model: model, drafts: model.drafts, compact: narrow)
                        .frame(width: narrow ? geometry.size.width : 380)
                        .transition(.opacity.combined(with: .offset(x: 12)))
                }
            }
            .padding(.top, 52)
            .background(alignment: .leading) {
                if datesExpanded && !showChatOnly {
                    NotoSidebarSurface(radius: 0).frame(width: sidebarWidth)
                        .transition(.opacity)
                }
            }
            .animation(NotoMotion.animation(.layout), value: datesExpanded)
            .animation(NotoMotion.animation(.layout), value: !narrow && model.conversationVisible)
            .animation(NotoMotion.animation(.navigation), value: showChatOnly)
            .animation(NotoMotion.animation(.feedback), value: model.message.isEmpty)
        }
        .onChange(of: datesExpanded) { _, _ in dismissSidebarPreview() }
        .onChange(of: model.mode) { _, _ in dismissSidebarPreview() }
        .onChange(of: model.settings) { _, opened in if opened { dismissSidebarPreview() } }
        .onChange(of: model.taskCreating) { _, _ in dismissSidebarPreview() }
        .onChange(of: model.editing?.id) { _, _ in dismissSidebarPreview() }
        .onDisappear { dismissSidebarPreview() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 12) {
                    Button {
                        datesExpanded.toggle()
                        model.readingRequested = true
                    } label: { ActionIcon("sidebar.left") }
                    .buttonStyle(QuietButtonStyle(icon: true))
                    .help(datesExpanded ? "隐藏侧栏（⌃⌘S）" : "显示侧栏（⌃⌘S）")
                    .accessibilityLabel(datesExpanded ? "隐藏侧栏" : "显示侧栏")
                    Text(model.mode.label).font(.system(size: 15, weight: .semibold))
                }.fixedSize()
            }.integratedToolbarBackground()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .automatic) { Spacer() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13))
                            .foregroundStyle(searchFocused ? Color.accentColor : Color.secondary).accessibilityHidden(true)
                        SearchInput(text: Binding(get: { model.search }, set: { model.setSearch($0) }), placeholder: "搜索", focused: $searchFocused, commitDelay: 0.2)
                    }.padding(.horizontal, 6).frame(width: 180, height: 28)
                        .background(searchFocused ? Color.accentColor.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1).allowsHitTesting(false))
                        .animation(NotoMotion.hover, value: searchFocused)
                        .help(model.mode.isTaskView ? "搜索任务与对话（⌘K）" : "搜索记录与对话（⌘K）")
                    Button { model.openQuickConversation() } label: { ActionIcon("bubble.left") }
                        .buttonStyle(QuietButtonStyle(icon: true))
                        .help(model.conversationVisible ? "继续 AI 对话" : "发起 AI 对话")
                        .accessibilityLabel(model.conversationVisible ? "继续 AI 对话" : "AI 对话")
                    Button { model.showComposer() } label: { ActionIcon("plus") }
                        .buttonStyle(QuietButtonStyle(icon: true))
                        .help("新建内容（⌘N）").accessibilityLabel(model.mode.isTaskView ? "新建任务" : "新建记录")
                }.fixedSize()
            }.integratedToolbarBackground()
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear {
            NotoMotion.start()
            model.pill?.showWindow = { openWindow(id: "main") }
            model.pill?.start()
        }
        .onChange(of: model.mode) { _, mode in
            NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.isMovableByWindowBackground = mode == .notes
        }
        .disabled(model.opening)
        .overlay { if model.opening { ProgressView("正在打开记录…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        .background(NotoGlassSurface(radius: 20)).foregroundStyle(.primary)
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
        })) { TaskEditor(model: model, drafts: model.drafts).presentationBackground(.clear) }
        .sheet(isPresented: $model.settings) { SettingsView(model: model).presentationBackground(.clear) }
        .sheet(isPresented: $model.recentlyDeleted) { RecentlyDeletedView(model: model).presentationBackground(.clear) }
        .task(id: model.message) {
            guard !model.message.isEmpty, !model.isError else { return }
            do {
                try await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !model.isError else { return }
                model.message = ""
            } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshIfChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() }
    }
    private func sidebarHover(_ inside: Bool) {
        sidebarHoverTask?.cancel()
        sidebarHoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(inside ? 120 : 300)) }
            catch { return }
            guard !datesExpanded else { return }
            withAnimation(NotoMotion.animation(.navigation)) { sidebarPreview = inside }
        }
    }
    private func dismissSidebarPreview() {
        sidebarHoverTask?.cancel(); sidebarHoverTask = nil
        sidebarPreview = false
    }
    private var sidebarWidth: CGFloat { 168 }
    private func sidebar(proxy: ScrollViewProxy, height: CGFloat) -> some View {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(ContentMode.allCases) { mode in
                                    Button { model.switchMode(mode) } label: {
                                        HStack(spacing: 10) {
                                            SidebarBadge(symbol: mode.icon)
                                            Text(mode.label); Spacer()
                                        }.padding(.horizontal, 8).frame(height: 40)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .background {
                                                if model.mode == mode {
                                                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.10))
                                                        .matchedGeometryEffect(id: "navigation", in: navigationSelection).allowsHitTesting(false)
                                                }
                                            }
                                    }.buttonStyle(NavigationButtonStyle()).help(mode.label).accessibilityLabel(mode.label)
                                        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                                }.padding(.horizontal, 8)
                                if model.mode == .notes && !model.entries.isEmpty {
                                    Text("日期").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.leading, 20).padding(.top, 22)
                                    DateRail(model: model, expanded: true, activeDay: activeDay, maxHeight: height, width: sidebarWidth - 8) { id in
                                        NotoMotion.perform(.navigation) { activeDay = id; proxy.scrollTo("content-" + id, anchor: .top) }
                                    }
                                } else { Spacer() }
                                Button { model.settings = true } label: {
                                    HStack(spacing: 10) {
                                        SidebarBadge(symbol: "gearshape")
                                        Text("设置"); Spacer()
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                                }.buttonStyle(NavigationButtonStyle()).help("设置（⌘,）").accessibilityLabel("设置")
                            }.font(.system(size: 13)).padding(.bottom, 12)
                                .animation(NotoMotion.animation(.navigation), value: model.mode)
                                .frame(width: sidebarWidth - 8)
                                .padding(4)
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
            .frame(maxWidth: .infinity)
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
                                Text(model.search.isEmpty ? "想法、任务，先记下来。" : "试试其他关键词。")
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
                                if !model.search.isEmpty {
                                    Button("清空搜索") { model.setSearch("") }.buttonStyle(QuietButtonStyle()).font(NotoDesign.caption)
                                } else {
                                    Button("新建记录") { model.showComposer() }.buttonStyle(QuietButtonStyle(prominent: true)).help("新建记录（⌘N）")
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
                            LazyVStack(alignment: .leading, spacing: 24) {
                                ForEach(model.groups) { group in
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack(spacing: 12) {
                                            Text(group.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                        }.excludeFromBlankInput()
                                        LazyVStack(spacing: 1) {
                                            ForEach(group.entries) { entry in EntryRow(entry: entry, model: model).excludeFromBlankInput().transition(.opacity) }
                                        }
                                    }.id("content-" + group.id)
                                        .background(GeometryReader { frame in
                                            // 1pt 量化：sub-pt 滚动抖动不触发 preference 聚合。
                                            Color.clear.preference(key: DayPositions.self, value: [group.id: frame.frame(in: .named("history")).minY.rounded(.down)])
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
                    .padding(.top, 24).padding(.bottom, 100).id("history-top").frame(maxWidth: .infinity)
                    .animation(NotoMotion.animation(.layout), value: model.entries.map(\.id))
                }
                .coordinateSpace(name: "history")
                .onPreferenceChange(DayPositions.self) { positions in
                    let current = Set(model.groups.map(\.id))
                    let sorted = positions.filter { current.contains($0.key) }.sorted { $0.value < $1.value }
                    let candidate = (sorted.last(where: { $0.value <= 12 }) ?? sorted.first)?.key
                    if candidate != activeDay { activeDay = candidate }
                }
                if model.composerPosition != nil {
                    NewContentInput(model: model, drafts: model.drafts)
                        .frame(width: width)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { composerSize = $0 }
                        .offset(x: origin.x, y: origin.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
            }
            .animation(NotoMotion.animation(.layout), value: model.composerPosition)
            .coordinateSpace(name: "reading")
            .onPreferenceChange(OccupiedAreas.self) { if $0 != occupied { occupied = $0 } }
            .background(BlankClickObserver(excluded: occupied, floatingRect: floatingRect,
                onDoubleClick: { model.showComposer(at: $0) }, onOutsideClick: { model.composerPosition = nil }))
        }
    }
}

private struct NewContentInput: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: TextDrafts
    private var empty: Bool { drafts.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("新建记录").font(NotoDesign.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.composerPosition = nil } label: { ActionIcon("xmark") }
                    .buttonStyle(QuietButtonStyle(icon: true)).accessibilityLabel("收起录入，保留草稿")
            }
            Composer(text: $drafts.composer, enabled: true, purpose: .newContent, onSubmit: { model.save() }, onCancel: { model.composerPosition = nil })
                .frame(minHeight: 48)
            if model.busy { Text("AI 正在回复，你可以继续保存记录。").font(NotoDesign.caption).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Button("与 AI 讨论") { model.ask() }.disabled(model.busy)
                Spacer(minLength: 0)
                Menu { Button("保存为任务") { model.save(todo: true) } } label: {
                    ActionIcon("chevron.down")
                }.actionMenuStyle().help("其他保存方式").accessibilityLabel("其他保存方式")
                Button("保存") { model.save() }.buttonStyle(QuietButtonStyle(prominent: true)).help("保存记录（⌘↵）；回车换行")
            }.font(NotoDesign.caption).buttonStyle(QuietButtonStyle()).disabled(empty)
        }.padding(16)
            .background(NotoDesign.canvas, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 5)
    }
}

private struct DayPositions: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private extension ToolbarContent {
    @ToolbarContentBuilder func integratedToolbarBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) { sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}
