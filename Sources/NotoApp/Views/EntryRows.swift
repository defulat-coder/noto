import SwiftUI
import AppKit
import NotoCore

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
        .padding(.top, 0)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: expanded ? .topLeading : .center)
        .background(Color.clear)
    }
}

struct EntryRow: View {
    @State private var hovering = false
    let entry: Entry
    @ObservedObject var model: AppModel
    private var overdue: Bool { !entry.completed && (entry.due.map { $0 < AppModel.dateKey(Date()) } ?? false) }
    var dueLabel: String { entry.due.map { TaskDates.taskLabel($0, completed: entry.completed) } ?? "" }
    private func edit() { model.beginEditing(entry) }
    var body: some View {
        Group {
        if model.editing?.id == entry.id { InlineEditView(entry: entry, model: model, drafts: model.drafts).transition(.opacity) } else {
        HStack(alignment: .top, spacing: 10) {
            if entry.kind == "todo" { TaskCompletionButton(entry: entry, model: model) }
            else { Color.clear.frame(width: 28, height: 1).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 6) {
                EntryBodyText(text: entry.text, completed: entry.completed, onEdit: edit)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    .help(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                if entry.due != nil || entry.status == "in_progress" || entry.priority == "important" || entry.hasConversation {
                    HStack(spacing: 8) {
                        if entry.priority == "important" { Image(systemName: "star.fill").foregroundStyle(.secondary).accessibilityLabel("重要任务") }
                        if entry.status == "in_progress" { Text("进行中") }
                        if entry.due != nil { Text(dueLabel).foregroundStyle(overdue ? Color.orange : Color.secondary) }
                        if entry.hasConversation { ConversationShortcut(entry: entry, model: model, compact: true) }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !entry.hasConversation { ConversationShortcut(entry: entry, model: model, revealed: hovering) }
            Menu { actions } label: { ActionIcon("ellipsis") }
                .actionMenuStyle().foregroundStyle(.secondary)
                .help("记录操作").accessibilityLabel("记录操作")
        }
        .padding(.vertical, 10).padding(.horizontal, 4)
        .background(model.conversation?.id == entry.id ? Color.accentColor.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .contextMenu { actions }
        .onHover { hovering = $0 }
        }
        }
        .animation(NotoMotion.animation(.navigation), value: model.editing?.id == entry.id)
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

struct InlineEditView: View {
    @State private var confirmClose = false
    let entry: Entry
    @ObservedObject var model: AppModel
    @ObservedObject var drafts: TextDrafts
    private func close() { if model.editDirty { confirmClose = true } else { model.cancelEditing() } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.kind == "todo" ? "编辑任务" : "编辑记录").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Composer(text: $drafts.edit, enabled: true, purpose: .edit, onSubmit: { model.saveEditing() }, onCancel: close)
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
                    .disabled(drafts.edit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(NotoDesign.caption)
        }.padding(16)
            .background(NotoDesign.field, in: RoundedRectangle(cornerRadius: NotoDesign.radius))
            .onExitCommand(perform: close)
            .alert("保存记录修改？", isPresented: $confirmClose) {
                Button("保存") { model.saveEditing() }.disabled(drafts.edit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("放弃修改", role: .destructive) { model.cancelEditing() }
                Button("继续编辑", role: .cancel) { }
            } message: { Text("关闭前可以保存修改，或继续编辑。") }
    }
}

struct ConversationShortcut: View {
    let entry: Entry
    @ObservedObject var model: AppModel
    var compact = false
    var revealed = true
    @FocusState private var focused: Bool
    var body: some View {
        Button { model.openConversation(entry) } label: {
            if compact { Label("对话", systemImage: "bubble.left").font(.system(size: 11)).padding(.vertical, 4) }
            else { ActionIcon("bubble.left") }
        }
        .buttonStyle(QuietButtonStyle(icon: true)).focused($focused)
        .foregroundStyle(model.conversation?.id == entry.id ? Color.accentColor : Color.secondary)
        .opacity(revealed || focused ? 1 : 0).allowsHitTesting(revealed || focused)
        .animation(NotoMotion.hover, value: revealed || focused)
        .help(entry.hasConversation ? "继续 AI 对话" : "与 AI 讨论")
        .accessibilityLabel(entry.hasConversation ? "继续 AI 对话：\(entry.text)" : "与 AI 讨论：\(entry.text)")
        .disabled(model.busy)
    }
}
