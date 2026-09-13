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

private enum SettingsSection: String, CaseIterable {
    case account = "账号与同步", ai = "AI", appearance = "外观"
    var icon: String {
        switch self { case .account: "person.crop.circle"; case .ai: "sparkles"; case .appearance: "slider.horizontal.3" }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var section = SettingsSection.account
    @State private var showDeleted = false
    @Namespace private var navigationSelection
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
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 20)
                ForEach(SettingsSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        HStack(spacing: 8) {
                            SidebarBadge(symbol: item.icon)
                            Text(item.rawValue)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).frame(height: 40)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .background {
                                if section == item {
                                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.10))
                                        .matchedGeometryEffect(id: "settings", in: navigationSelection).allowsHitTesting(false)
                                }
                            }
                    }.buttonStyle(NavigationButtonStyle()).accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }.font(.system(size: 13)).animation(NotoMotion.animation(.navigation), value: section).padding(.horizontal, 8).frame(width: 152)
                .padding(4)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(section.rawValue).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button { model.settings = false } label: { ActionIcon("xmark") }
                        .help("关闭设置").accessibilityLabel("关闭设置").disabled(model.sync?.isSyncing == true)
                }.padding(20)
                ScrollView {
                    ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 20) {
                        switch section {
                        case .account:
                            settingsGroup {
                                if let sync = model.sync { SyncSettingsView(model: model, controller: sync) }
                                else { Label("预览模式不连接同步服务", systemImage: "internaldrive").foregroundStyle(.secondary) }
                            }
                            settingsGroup {
                                HStack {
                                    Label("最近删除", systemImage: "trash")
                                    Spacer()
                                    Button("查看") { showDeleted = true }.accessibilityLabel("查看最近删除")
                                }
                            }
                        case .ai:
                            settingsGroup {
                                Picker("工具", selection: $model.provider) {
                                    ForEach(Provider.allCases) { provider in Text(provider.title).tag(provider) }
                                }
                                Text("使用本机已登录的工具，下次对话生效。默认只使用当前记录，可在对话中调整内容范围。")
                                    .font(NotoDesign.caption).foregroundStyle(.secondary)
                            }
                        case .appearance:
                            settingsGroup {
                                HStack {
                                    Text("屏幕边缘"); Spacer()
                                    Picker("屏幕边缘", selection: edgeVisibility) {
                                        Text("悬停展开").tag("hover")
                                        Text("始终展开").tag("always")
                                        Text("隐藏").tag("hidden")
                                    }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                                }
                                Color.clear.frame(height: 6)
                                HStack {
                                    Text("位置"); Spacer()
                                    Picker("位置", selection: $pillEdge) {
                                        ForEach(PillEdge.allCases) { edge in Text(edge.label).tag(edge.rawValue) }
                                    }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                                }
                                Color.clear.frame(height: 6)
                                HStack {
                                    Text("表面"); Spacer()
                                    Picker("表面", selection: $pillSurface) {
                                        Text("液态玻璃").tag("glass")
                                        Text("纯黑").tag("black")
                                    }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                                }
                                HStack {
                                    Text("拖动移动弧线可换边，⌥ 拖动可微调位置。")
                                        .font(NotoDesign.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Button("居中") { model.pill?.resetPosition() }.disabled(!pillEnabled)
                                }
                            }
                            Text("外观跟随系统；液态玻璃也遵循系统的辅助功能设置。")
                                .font(NotoDesign.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 24)
                        .id(section).transition(.opacity)
                    }.animation(NotoMotion.animation(.navigation), value: section)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 620, height: 480).background(NotoGlassSurface(radius: 20)).buttonStyle(QuietButtonStyle())
            .sheet(isPresented: $showDeleted) { RecentlyDeletedView(model: model).presentationBackground(.clear) }
            .interactiveDismissDisabled(model.sync?.isSyncing == true)
            .onExitCommand { if model.sync?.isSyncing != true { model.settings = false } }
    }
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }
}
