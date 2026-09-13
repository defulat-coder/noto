import SwiftUI
import AppKit
import NotoCore

// One continuous desktop-sampling surface, shared by the desktop windows.
private struct DesktopBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

struct NotoGlassSurface: View {
    var radius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                ZStack {
                    DesktopBackdrop()
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: radius))
                    }
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct SidebarBadge: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary).frame(width: 20, height: 20)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showDeleted = false
    @State private var accountExpanded = false
    @AppStorage("pillEnabled") private var pillEnabled = true
    @AppStorage("pillEdge") private var pillEdge = PillEdge.right.rawValue
    @AppStorage("pillSurface") private var pillSurface = "glass"
    @AppStorage("pillVisibility") private var pillVisibility = "hover"
    private var edgeVisibility: Binding<String> {
        Binding(get: { pillEnabled ? pillVisibility : "hidden" }, set: { value in
            if value == "hidden" { pillEnabled = false }
            else { pillVisibility = value; pillEnabled = true }
        })
    }
    private var accountSummary: String {
        if model.preview { return "示例空间" }
        return model.sync?.isSignedIn == true ? (model.sync?.email ?? "已登录") : "仅本机"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("完成") { model.settings = false }
                    .help("关闭设置").accessibilityLabel("关闭设置")
                    .disabled(model.sync?.isSyncing == true)
            }.padding(.horizontal, 40).padding(.vertical, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    appearancePage
                    settingsGroup {
                        HStack(spacing: 12) {
                            Text("AI 工具").font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 8)
                            Picker("AI 工具", selection: $model.provider) {
                                ForEach(Provider.allCases) { provider in
                                    Label { Text(provider.title) } icon: { Image(nsImage: provider.settingsIcon) }.tag(provider)
                                }
                            }.labelsHidden().pickerStyle(.menu).fixedSize().frame(width: 216, alignment: .trailing)
                                .help("下一次对话生效，已有对话保留原工具。")
                        }.frame(minHeight: 36)
                    }
                    VStack(spacing: 4) {
                        Button { accountExpanded.toggle() } label: {
                            HStack(spacing: 10) {
                                Text("账号与同步").font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 8)
                                Text(accountSummary)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if model.sync?.lastError.isEmpty == false {
                                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                        .help("同步需要处理，展开查看详情")
                                }
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary).rotationEffect(.degrees(accountExpanded ? 90 : 0))
                            }.padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
                        }.buttonStyle(NavigationButtonStyle())
                            .accessibilityLabel("账号与同步").accessibilityValue("\(accountSummary)，\(accountExpanded ? "已展开" : "已收起")")
                            .accessibilityHint(model.sync?.lastError.isEmpty == false ? "同步需要处理，展开查看详情" : "")
                        Group {
                            if let sync = model.sync { SyncSettingsView(model: model, controller: sync) }
                            else { Text("示例预览不连接同步服务。").font(NotoDesign.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).padding(.bottom, accountExpanded ? 14 : 0)
                        .frame(height: accountExpanded ? nil : 0, alignment: .top).clipped()
                        .opacity(accountExpanded ? 1 : 0).disabled(!accountExpanded)
                        .allowsHitTesting(accountExpanded).accessibilityHidden(!accountExpanded)
                        Button { showDeleted = true } label: {
                            HStack(spacing: 10) {
                                Text("最近删除").font(.system(size: 13, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            }.padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
                        }.buttonStyle(NavigationButtonStyle()).accessibilityLabel("查看最近删除")
                    }.padding(6).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                        .animation(NotoMotion.animation(.layout), value: accountExpanded)
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }.frame(width: 480, height: 460).background(NotoGlassSurface(radius: 20)).buttonStyle(QuietButtonStyle())
            .sheet(isPresented: $showDeleted) { RecentlyDeletedView(model: model).presentationBackground(.clear) }
            .interactiveDismissDisabled(model.sync?.isSyncing == true)
            .onExitCommand { if model.sync?.isSyncing != true { model.settings = false } }
    }

    private var appearancePage: some View {
        settingsGroup {
            HStack {
                Text("屏幕边缘")
                Spacer()
                Picker("屏幕边缘", selection: edgeVisibility) {
                    Text("悬停展开").tag("hover")
                    Text("常驻").tag("always")
                    Text("隐藏").tag("hidden")
                }.labelsHidden().pickerStyle(.segmented).fixedSize().frame(width: 216, alignment: .trailing)
            }.frame(minHeight: 36)
            HStack {
                Text("位置")
                Spacer()
                Menu {
                    Picker("位置", selection: $pillEdge) {
                        ForEach(PillEdge.allCases) { edge in Text(edge.label).tag(edge.rawValue) }
                    }.pickerStyle(.inline)
                    Button("恢复居中") { model.pill?.resetPosition() }.disabled(!pillEnabled)
                } label: {
                    Text((PillEdge(rawValue: pillEdge) ?? .right).label)
                }.fixedSize().frame(width: 216, alignment: .trailing).accessibilityLabel("边缘位置")
            }.frame(minHeight: 36)
            HStack {
                Text("材质")
                Spacer()
                Picker("材质", selection: $pillSurface) {
                    Text("玻璃").tag("glass")
                    Text("纯黑").tag("black")
                }.labelsHidden().pickerStyle(.segmented).fixedSize().frame(width: 216, alignment: .trailing)
            }.frame(minHeight: 36)
        }
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension Provider {
    var settingsIcon: NSImage {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }
}
