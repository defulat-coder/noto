import SwiftUI
import NotoCore

struct RecentlyDeletedView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var error = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近删除").font(.system(size: 16, weight: .semibold))
                    Text(model.sync?.isSignedIn == true ? "当前账号空间 · 恢复后继续同步" : "本机空间")
                        .font(NotoDesign.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Color.clear.frame(height: 4)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if entries.isEmpty {
                Text("没有已删除的任务").font(NotoDesign.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.text).font(NotoDesign.body).lineLimit(4).textSelection(.enabled)
                                    HStack {
                                        if let due = entry.due { Text(TaskDates.taskLabel(due, completed: entry.completed)) }
                                        if entry.hasConversation { Label("含对话", systemImage: "bubble.left") }
                                    }.font(NotoDesign.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("恢复") { restore(entry) }.disabled(model.busy)
                                    .accessibilityLabel("恢复：\(entry.text)")
                            }.padding(.vertical, 14).transition(.opacity)
                            Color.clear.frame(height: 4)
                        }
                    }.animation(NotoMotion.animation(.layout), value: entries.map(\.id))
                }
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle").font(NotoDesign.caption).foregroundStyle(.red)
            }
        }.padding(24).background(NotoGlassSurface(radius: 20)).frame(width: 490, height: 470).buttonStyle(QuietButtonStyle())
            .task(id: model.store.map(ObjectIdentifier.init)) { await reload() }
    }
    @MainActor private func reload() async {
        entries = await model.deletedTasks()
        loading = false
    }
    private func restore(_ entry: Entry) {
        guard !model.busy else { return }
        do {
            try model.restoreTask(entry.id)
            entries.removeAll { $0.id == entry.id }; error = ""
        } catch { self.error = error.localizedDescription }
    }
}
