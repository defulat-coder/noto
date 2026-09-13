import SwiftUI
import NotoCore

struct ConversationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: TextDrafts
    var compact = false
    private var pending: Bool { model.messages.last?.role == "user" }
    @State private var toolAvailable: Bool?
    private var displayedProvider: Provider { model.activeProvider ?? model.provider }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if compact {
                    Button { model.readingRequested = true } label: { ActionIcon("arrow.left") }
                        .buttonStyle(QuietButtonStyle(icon: true)).help("返回记录，保留对话").accessibilityLabel("返回记录")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("AI 对话").font(.system(size: 15, weight: .semibold))
                        Button { model.settings = true } label: {
                            Label { Text(displayedProvider.title).font(NotoDesign.caption) }
                                icon: { Image(nsImage: displayedProvider.settingsIcon) }
                        }.buttonStyle(QuietButtonStyle()).disabled(model.busy)
                            .help(model.busy ? "当前正在执行的工具" : "下一次请求使用的工具；点击设置")
                    }
                    Text(model.conversation?.text ?? "有什么想聊的？").font(NotoDesign.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if !compact {
                    Button { model.closeConversation() } label: { ActionIcon("xmark") }
                        .buttonStyle(QuietButtonStyle(icon: true)).help("关闭对话（Esc）").accessibilityLabel("关闭对话").disabled(model.busy)
                }
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if model.messages.isEmpty {
                            Text(model.newConversationOpen ? "写下问题，或让 AI 帮你梳理想法。" : "围绕这条记录继续想一想，或请 AI 帮你整理成任务。")
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
                                .transition(.opacity.combined(with: .offset(y: 4)))
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
                        .animation(model.messages.last?.role == "assistant" ? NotoMotion.arrival : NotoMotion.animation(.feedback), value: model.messages.count)
                        .animation(NotoMotion.arrival, value: model.busy)
                }
                .onChange(of: model.messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: model.busy) { _, busy in
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                    if !busy && !pending && model.composerPosition == nil && model.editing == nil { NotificationCenter.default.post(name: .focusChat, object: nil) }
                }
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 10) {
                if !model.newConversationOpen { Menu {
                    Toggle("当前记录", isOn: Binding(get: { !model.aiUsesCurrentView }, set: { if $0 { model.aiUsesCurrentView = false } }))
                    Toggle("当前视图已载入的 \(model.filtered.count) 条内容", isOn: $model.aiUsesCurrentView)
                } label: {
                    Label(model.aiContextLabel, systemImage: "doc.text")
                        .font(NotoDesign.caption).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                    .help("此轮会提供所选记录和本对话历史；当前视图仅包含已载入或筛选的内容。")
                    .accessibilityLabel("AI 内容范围：\(model.aiContextLabel)") }
                if toolAvailable == false && !model.busy {
                    HStack {
                        Text("未找到 \(model.provider.title)").font(NotoDesign.caption).foregroundStyle(.secondary)
                        Button("前往设置") { model.settings = true }.buttonStyle(QuietButtonStyle())
                    }
                }
                if pending && !model.busy {
                    HStack {
                        Text("问题已保存").font(NotoDesign.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("重试") { model.requestReply() }.buttonStyle(QuietButtonStyle())
                    }
                }
                Composer(text: $drafts.chat, enabled: true, purpose: .chat, onSubmit: { model.sendChat() }, onCancel: { model.closeConversation() })
                    .frame(minHeight: 40).fixedSize(horizontal: false, vertical: true)
                    .padding(14).background(NotoDesign.field, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
                        HStack {
                    Spacer()
                    if model.busy {
                        Button { model.cancel() } label: { ActionIcon("stop.fill") }
                            .buttonStyle(QuietButtonStyle(icon: true)).help("停止回复").accessibilityLabel("停止回复")
                    } else {
                        Button("发送") { model.sendChat() }
                            .buttonStyle(QuietButtonStyle(prominent: true)).help("发送消息（⌘ 回车）").accessibilityLabel("发送消息")
                            .disabled(toolAvailable == false || pending || drafts.chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.font(NotoDesign.caption)
            }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 12)
        }
        .task(id: model.provider) { refreshToolAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshToolAvailability() }
    }
    private func refreshToolAvailability() {
        toolAvailable = model.provider.locate() != nil
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
