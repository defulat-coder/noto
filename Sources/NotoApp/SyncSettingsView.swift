import SwiftUI
import NotoCore
import NotoSync

struct SyncSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: SyncController
    @State private var server = ""
    @State private var publicKey = ""
    @State private var syncServer = ""
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""
    @State private var showConfiguration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("账号与同步").font(.headline)
            Label(controller.status, systemImage: controller.isSignedIn ? "arrow.triangle.2.circlepath" : "internaldrive")
                .font(NotoDesign.caption).foregroundStyle(.secondary)
                .accessibilityLabel("同步状态：\(controller.status)")
            if controller.isSignedIn { signedIn }
            else { signedOut }
            if !error.isEmpty { errorText(error) }
            if !controller.lastError.isEmpty { errorText(controller.lastError) }
            if !model.message.isEmpty && model.isError { errorText(model.message) }

            DisclosureGroup("同步服务配置", isExpanded: $showConfiguration) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Supabase URL", text: $server)
                    TextField("Publishable / anon key", text: $publicKey)
                    TextField("PowerSync URL", text: $syncServer)
                    Button("保存服务配置") { saveConfiguration() }
                    Text("服务地址与公开密钥由部署方提供。账号密码不会写入服务配置。")
                        .font(NotoDesign.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(.top, 8)
                    .disabled(controller.isSignedIn || controller.isSyncing)
            }
        }
        .onAppear {
            server = controller.configuration?.supabaseURL.absoluteString ?? ""
            publicKey = controller.configuration?.publishableKey ?? ""
            syncServer = controller.configuration?.powerSyncURL.absoluteString ?? ""
            showConfiguration = controller.configuration == nil
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登录后打开独立的账号资料。本机笔记和对话继续保留，任务需手动导入才会上传。")
                .font(NotoDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("邮箱", text: $email).textContentType(.username)
            SecureField("密码", text: $password).textContentType(.password)
            Button("登录") {
                guard model.canChangeSyncAccount() else { return }
                Task {
                    await controller.signIn(email: email, password: password)
                    if controller.isSignedIn { password = "" }
                }
            }.disabled(controller.configuration == nil || email.isEmpty || password.isEmpty || controller.isSyncing)
            Text("请使用部署方创建的邮箱账号。Mac 与 iPhone 登录同一账号即可同步任务。")
                .font(NotoDesign.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.email ?? "").textSelection(.enabled)
            if controller.pendingCount > 0 {
                Text("\(controller.pendingCount) 项修改待上传；退出后保留在该账号的本机资料中。")
                    .font(NotoDesign.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("立即同步") { Task { await controller.syncNow() } }
                Spacer()
                Button("退出账号") {
                    guard model.canChangeSyncAccount() else { return }
                    Task { await controller.signOut() }
                }
            }.disabled(controller.isSyncing)
            Button("导入本机任务到此账号并同步") {
                Task { await controller.importLocalTasks() }
            }.disabled(controller.isSyncing)
            Text("只导入待办；不会上传本机笔记、对话。重复导入不会创建重复任务。")
                .font(NotoDesign.caption).foregroundStyle(.secondary)
            if !controller.conflicts.isEmpty {
                Divider()
                Text("保留的冲突版本").font(.subheadline.weight(.semibold))
                ForEach(controller.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.text).lineLimit(4).textSelection(.enabled)
                        Text(conflict.reason).font(NotoDesign.caption).foregroundStyle(.secondary)
                        if conflict.reason != "已另存为新任务" {
                            Button("另存为新任务") { Task { await controller.recoverConflict(id: conflict.id) } }
                                .disabled(controller.isSyncing)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    private func errorText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(NotoDesign.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }

    private func saveConfiguration() {
        do {
            guard let serverURL = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let syncURL = URL(string: syncServer.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw NotoError("请输入有效的服务地址。")
            }
            try controller.configure(SyncConfiguration(supabaseURL: serverURL,
                publishableKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines), powerSyncURL: syncURL))
            error = ""; showConfiguration = false
        } catch { self.error = error.localizedDescription }
    }
}
