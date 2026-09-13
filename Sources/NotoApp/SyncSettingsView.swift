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
    @State private var showImportConfirmation = false
    @State private var showConflicts = false

    private var unresolvedConflictCount: Int {
        controller.conflicts.filter { $0.reason != "已另存为新任务" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(controller.isSignedIn ? "账号空间" : "本机空间",
                      systemImage: controller.isSignedIn ? "person.crop.circle" : "internaldrive")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if controller.isSignedIn {
                    Text(controller.email ?? "").textSelection(.enabled)
                    Label(controller.status, systemImage: "arrow.triangle.2.circlepath")
                        .accessibilityLabel("同步状态：\(controller.status)")
                } else {
                    Text("记录、任务和对话仅保存在这台 Mac。")
                }
            }
            .font(NotoDesign.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if controller.isSignedIn { signedIn }
            else { signedOut }
            if !error.isEmpty { errorText(error) }
            if !controller.lastError.isEmpty { errorText(controller.lastError) }
            if !model.message.isEmpty && model.isError { errorText(model.message) }

            Color.clear.frame(height: 6)
            DisclosureGroup("高级服务配置", isExpanded: $showConfiguration) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.isSignedIn ? "返回本机后可更换同步服务。" : "填写部署方提供的服务地址与公开密钥，再登录账号。")
                        .font(NotoDesign.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Supabase 地址").font(NotoDesign.caption)
                        TextField("https://…supabase.co", text: $server)
                            .accessibilityLabel("Supabase 地址")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("公开密钥").font(NotoDesign.caption)
                        TextField("Publishable / anon key", text: $publicKey)
                            .accessibilityLabel("同步服务公开密钥")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PowerSync 地址").font(NotoDesign.caption)
                        TextField("https://…powersync.journeyapps.com", text: $syncServer)
                            .accessibilityLabel("PowerSync 地址")
                    }
                    Button { saveConfiguration() } label: {
                        Label("保存服务配置", systemImage: "checkmark")
                    }.buttonStyle(QuietButtonStyle(prominent: true))
                }.textFieldStyle(.roundedBorder).padding(.top, 8)
                    .disabled(controller.isSignedIn || controller.isSyncing)
            }
        }
        .buttonStyle(QuietButtonStyle())
        .confirmationDialog("复制本机任务到当前账号？", isPresented: $showImportConfirmation, titleVisibility: .visible) {
            Button("复制并同步") { Task { await controller.importLocalTasks() } }
                .disabled(controller.isSyncing)
            Button("取消", role: .cancel) { }
        } message: {
            Text("本机任务会复制到 \(controller.email ?? "当前账号") 并上传，同一账号的其他设备也能看到。本机原任务保留，记录和对话不会上传；重复导入不会创建重复任务。")
        }
        .onAppear {
            server = controller.configuration?.supabaseURL.absoluteString ?? ""
            publicKey = controller.configuration?.publishableKey ?? ""
            syncServer = controller.configuration?.powerSyncURL.absoluteString ?? ""
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登录后切换到账号空间，本机内容保留。只有任务跨设备同步。")
                .font(NotoDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.configuration == nil {
                Button { showConfiguration = true } label: {
                    Label("配置同步服务", systemImage: "slider.horizontal.3")
                }.buttonStyle(QuietButtonStyle(prominent: true))
                Text("使用同一账号同步多台 Mac 的任务。")
                    .font(NotoDesign.caption).foregroundStyle(.secondary)
            } else {
                TextField("邮箱", text: $email).textContentType(.username)
                SecureField("密码", text: $password).textContentType(.password)
                Button {
                    guard model.canChangeSyncAccount() else { return }
                    Task {
                        await controller.signIn(email: email, password: password)
                        if controller.isSignedIn { password = "" }
                    }
                } label: {
                    Label(controller.isSyncing ? "正在登录…" : "登录账号空间", systemImage: "person.crop.circle")
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || controller.isSyncing)
                Text("使用部署方创建的邮箱账号。本机任务可在登录后手动导入。")
                    .font(NotoDesign.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder)
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("任务在登录同一账号的 Mac 间同步；记录和对话只保存在当前设备的账号空间。")
                .font(NotoDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.pendingCount > 0 {
                Text("\(controller.pendingCount) 项修改待上传，已保存在本机。")
                    .font(NotoDesign.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { Task { await controller.syncNow() } } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                Spacer()
                Button {
                    guard model.canChangeSyncAccount() else { return }
                    Task { await controller.signOut() }
                } label: {
                    Label("返回本机", systemImage: "internaldrive")
                }
            }.disabled(controller.isSyncing)
            Text("返回本机会退出登录。账号数据与待同步修改仍保留，重新登录后可继续使用和同步。")
                .font(NotoDesign.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Color.clear.frame(height: 6)
            Button { showImportConfirmation = true } label: {
                Label("导入本机任务…", systemImage: "square.and.arrow.down")
            }.disabled(controller.isSyncing)
            Text("复制任务到此账号，本机原任务保留。")
                .font(NotoDesign.caption).foregroundStyle(.secondary)
            if !controller.conflicts.isEmpty {
                Color.clear.frame(height: 6)
                DisclosureGroup(isExpanded: $showConflicts) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("同一任务的另一份修改已保留，可另存为新任务。")
                            .font(NotoDesign.caption).foregroundStyle(.secondary)
                        ForEach(controller.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conflict.text).lineLimit(4).textSelection(.enabled)
                                Text(conflict.reason).font(NotoDesign.caption).foregroundStyle(.secondary)
                                if conflict.reason != "已另存为新任务" {
                                    Button { Task { await controller.recoverConflict(id: conflict.id) } } label: {
                                        Label("另存为新任务", systemImage: "doc.badge.plus")
                                    }.disabled(controller.isSyncing)
                                }
                            }.padding(.vertical, 4)
                        }
                    }.padding(.top, 8)
                } label: {
                    Label(unresolvedConflictCount > 0 ? "冲突版本 · \(unresolvedConflictCount) 项待处理" : "冲突版本 · 已全部另存",
                          systemImage: "doc.on.doc")
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
