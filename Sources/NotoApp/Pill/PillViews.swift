// 屏幕边缘的界面与数据：通透或纯黑的贴边凸舌，悬停展开出「今日任务」环和「写一笔」，
// 再悬停到具体元素时弹出带箭头的描述卡。视觉语言对齐 codenotch 的刘海。
//
// 动效质感的关键：窗口尺寸恒定，展开/收起是剪影在窗口内的形变，
// 由 SwiftUI 按帧重绘——不做窗口 frame 动画，避免窗口级缩放的迟滞与抖动。

import SwiftUI
import NotoCore

enum PillElement: Int {
    case today, compose, settings, move
}

struct PillSummary {
    let todayOpen: Int
    let todayDone: Int
    let overdue: Int
    let openCount: Int
    let todayItems: [Entry]
    init(todos: [Entry], today: String) {
        let open = todos.filter { $0.status != "completed" }
        todayItems = open.filter { $0.due.map { $0 <= today } ?? false }
        todayOpen = todayItems.count
        overdue = todayItems.filter { $0.due! < today }.count
        todayDone = todos.filter { $0.status == "completed" && $0.due == today }.count
        openCount = open.count
    }
}

@MainActor
final class PillModel: ObservableObject {
    @Published var expanded = false
    @Published var isMoving = false
    var hasCard: Bool { hovered == .today || hovered == .compose }
    @Published var hovered: PillElement?
    @Published var edge: PillEdge = .right
    // 今日任务数据
    @Published private(set) var todayOpen = 0
    @Published private(set) var todayDone = 0
    @Published private(set) var overdue = 0
    @Published private(set) var openCount = 0
    @Published private(set) var todayItems: [Entry] = []

    weak var controller: PillController?
    private var lastStore: Store?
    private var lastVersion: Int?
    private var lastDay: String?
    private var refreshTask: Task<Void, Never>?

    /// 环的进度 = 今日到期里未完成的占比；颜色随负担从绿到红。
    var todayFraction: CGFloat {
        guard todayOpen + todayDone > 0 else { return 0 }
        return CGFloat(todayOpen) / CGFloat(todayOpen + todayDone)
    }

    func cardHeight(for element: PillElement) -> CGFloat {
        guard element == .today else { return 80 }
        guard todayOpen + todayDone > 0 else { return 100 }
        return 112 + CGFloat(min(todayItems.count, 3)) * 18 + (todayItems.count > 3 ? 16 : 0)
    }

    var ringColor: Color {
        switch todayFraction {
        case ..<0.5: Color(red: 0.19, green: 0.82, blue: 0.35)
        case ..<0.85: Color(red: 1.0, green: 0.84, blue: 0.04)
        default: Color(red: 1.0, green: 0.27, blue: 0.23)
        }
    }

    /// 按数据版本和本地日期刷新，跨午夜也会更新到期状态。
    func refresh(force: Bool = false) {
        guard let store = controller?.appModel?.store else { return }
        let todayKey = AppModel.dateKey(Date())
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let snapshot = try? await Task.detached(priority: .utility) { () -> (version: Int, todos: [Entry]) in
                (try store.dataVersion(), try store.todos(status: "all"))
            }.value
            guard let self, let (version, todos) = snapshot, !Task.isCancelled else { return }
            if !force, store === self.lastStore, version == self.lastVersion, todayKey == self.lastDay { return }
            self.lastStore = store
            self.lastVersion = version
            self.lastDay = todayKey
            let summary = PillSummary(todos: todos, today: todayKey)
            self.openCount = summary.openCount
            self.todayOpen = summary.todayOpen
            self.overdue = summary.overdue
            self.todayDone = summary.todayDone
            self.todayItems = summary.todayItems
        }
    }
}

/// 元素沿边方向的中点，与 PillController 的命中矩形保持一致。
extension PillElement {
    var extent: CGFloat { extent(for: .right) }
    var centerAlong: CGFloat { centerAlong(for: .right) }
    func extent(for edge: PillEdge) -> CGFloat { self == .today || self == .compose ? (edge.isVertical ? PillMetrics.cell : 44) : 44 }
    func centerAlong(for edge: PillEdge) -> CGFloat {
        switch self {
        case .move: PillMetrics.start
        case .today: PillMetrics.ringCenter(0, edge: edge)
        case .compose: PillMetrics.ringCenter(1, edge: edge)
        case .settings: PillMetrics.start + PillMetrics.length(for: edge)
        }
    }
    func originAlong(for edge: PillEdge) -> CGFloat {
        centerAlong(for: edge) - ((self == .today || self == .compose) && edge.isVertical ? PillMetrics.ring / 2 : 22)
    }
}

struct PillRootView: View {
    @ObservedObject var model: PillModel
    @AppStorage("pillSurface") private var surface = "glass"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private var glassy: Bool { surface == "glass" && !reduceTransparency && PillGlass.available }
    private var contentAlignment: Alignment {
        switch model.edge { case .right: .topTrailing; case .left, .top: .topLeading; case .bottom: .bottomLeading }
    }
    var body: some View {
        GeometryReader { proxy in
            let depth = model.expanded ? PillMetrics.depth(for: model.edge) : PillController.collapsedAcross
            let length = model.expanded ? PillMetrics.length(for: model.edge) : PillController.collapsedLength
            let shape = NotchSilhouette(edge: model.edge)
            ZStack(alignment: .topLeading) {
                ZStack {
                    if glassy {
                        PillGlass(sampleSize: proxy.size).id(model.expanded)
                    }
                    shape.fill(.black).opacity(glassy ? 0 : 1)
                }
                .frame(width: model.edge.isVertical ? depth : length, height: model.edge.isVertical ? length : depth)
                .overlay(alignment: contentAlignment) {
                    PillBarView(model: model)
                        .frame(width: model.edge.isVertical ? PillMetrics.depth(for: model.edge) : PillMetrics.length(for: model.edge),
                               height: model.edge.isVertical ? PillMetrics.length(for: model.edge) : PillMetrics.depth(for: model.edge))
                        .opacity(model.expanded ? 1 : 0)
                }
                .clipShape(shape)
                .position(point(along: PillController.bodyStart + PillMetrics.length(for: model.edge) / 2, across: depth / 2, size: proxy.size))
                .offset(x: model.edge == .right ? 2 : model.edge == .left ? -2 : 0,
                        y: model.edge == .bottom ? 2 : model.edge == .top ? -2 : 0)
                ForEach([PillElement.move, .settings], id: \.rawValue) { element in
                    Button { model.controller?.activate(element) } label: {
                        PillOrb(edge: model.edge, moving: element == .move,
                                hovered: model.hovered == element || (element == .move && model.isMoving), glassy: glassy)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(element == .move ? "移动屏幕边缘，按住拖动" : "设置")
                        .scaleEffect(model.expanded ? 1 : 1.55)
                        .opacity(model.expanded ? 1 : 0)
                        .position(point(along: element.centerAlong(for: model.edge), across: 30.99, size: proxy.size))
                        .allowsHitTesting(model.expanded)
                }
                if model.expanded, model.hasCard, let element = model.hovered {
                    let frame = PillController.cardFrame(edge: model.edge, element: element, height: model.cardHeight(for: element), panelSize: proxy.size)
                    let tailOffset = element.centerAlong(for: model.edge) - (model.edge.isVertical ? frame.midY : frame.midX)
                    PillCardView(model: model, element: element, tailOffset: tailOffset)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: model.hovered)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78), value: model.expanded)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("屏幕边缘")
        .accessibilityValue("未完成 \(model.openCount) 项")
        .accessibilityAction { model.controller?.activate(.today) }
        .environment(\.colorScheme, glassy ? colorScheme : .dark)
    }
    private func point(along: CGFloat, across: CGFloat, size: CGSize) -> CGPoint {
        switch model.edge {
        case .left: CGPoint(x: across, y: along)
        case .right: CGPoint(x: size.width - across, y: along)
        case .top: CGPoint(x: along, y: across)
        case .bottom: CGPoint(x: along, y: size.height - across)
        }
    }
}

/// 剪影：经典「刘海」造型——主体是一根圆角条，两端各有一片
/// 内凹的翼形曲线张开、融进屏幕边框（codenotch 截图里的样子）。
/// 先在「右侧凸舌」的规范空间里画路径，再按目标边做镜像/转置。
struct NotchSilhouette: Shape {
    var edge: PillEdge

    func path(in rect: CGRect) -> Path {
        let across = edge.isVertical ? rect.width : rect.height
        let along = edge.isVertical ? rect.height : rect.width
        var p = canonicalPath(across: across, along: along)
        switch edge {
        case .right:
            break
        case .left:
            // 水平镜像：贴边从右侧换到左侧。
            p = p.applying(CGAffineTransform(translationX: across, y: 0).scaledBy(x: -1, y: 1))
        case .bottom:
            // 转置：贴边从右侧换到底部。
            p = p.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        case .top:
            // 转置后再垂直镜像，让贴边落在顶部。
            let t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
                .concatenating(CGAffineTransform(translationX: 0, y: across).scaledBy(x: 1, y: -1))
            p = p.applying(t)
        }
        return p
    }

    /// 规范路径：宽 = across（0 是自由端、across 是贴边），高 = along。
    /// 两端的翼形曲线从内侧边缘（竖直切线）张开、沿顶部/底边（水平切线）
    /// 汇入贴边——形状向贴边方向张开，像从边框里长出来。
    // Adapted from vinzdg/codenotch SideNotchShape (MIT; see THIRD-PARTY-NOTICES).
    private func canonicalPath(across: CGFloat, along: CGFloat) -> Path {
        let rect = CGRect(x: 0, y: 0, width: across, height: along)
        let wanted = max(0, min(23.71, rect.width / 2))
        let curl = max(0, min(30.99, rect.height / 2, rect.width - wanted))
        let corner = max(0, min(wanted, (rect.height - 2 * curl) / 2))
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - curl

        var path = Path()
        // Screen edge, above the body.
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Flare inward and down onto the top edge. Absent when flush: the
        // shape meets the bezel square, as the hardware notch does.
        if curl > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - curl, y: rect.minY),
                radius: curl,
                startAngle: .degrees(0), endAngle: .degrees(90),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + corner, y: bodyTop))
        path.addArc(
            center: CGPoint(x: rect.minX + corner, y: bodyTop + corner),
            radius: corner,
            startAngle: .degrees(270), endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom - corner))
        path.addArc(
            center: CGPoint(x: rect.minX + corner, y: bodyBottom - corner),
            radius: corner,
            startAngle: .degrees(180), endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - curl, y: bodyBottom))
        // Flare back out to the screen edge.
        if curl > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - curl, y: rect.maxY),
                radius: curl,
                startAngle: .degrees(270), endAngle: .degrees(360),
                clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }
}

/// 展开态的主体内容：今日任务环、写一笔、设置。
struct PillBarView: View {
    @ObservedObject var model: PillModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach([PillElement.today, .compose], id: \.rawValue) { element in
                Button { model.controller?.activate(element) } label: {
                    VStack(spacing: 8.1) {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.16), lineWidth: 4.66)
                            if element == .today {
                                Circle().trim(from: 0, to: model.todayFraction)
                                    .stroke(model.ringColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round)).rotationEffect(.degrees(-90))
                            }
                            Image(systemName: element == .today ? "checklist" : "square.and.pencil")
                                .font(.system(size: 13.8, weight: .regular)).foregroundStyle(.primary)
                        }.frame(width: 35.2, height: 35.2)
                        Text(element == .today ? "\(model.todayOpen)" : "新建")
                            .font(.system(size: element == .today ? 11.4 : 11, weight: .regular)).monospacedDigit()
                    }
                    .frame(width: model.edge.isVertical ? PillMetrics.depth(for: model.edge) : 44,
                           height: model.edge.isVertical ? PillMetrics.cell : PillMetrics.depth(for: model.edge), alignment: .top)
                }.buttonStyle(.plain)
                    .accessibilityLabel(element == .today ? "今日任务，未完成 \(model.todayOpen) 项" : "新建记录")
                    .offset(x: model.edge.isVertical ? 0 : element.originAlong(for: model.edge) - PillController.bodyStart,
                            y: model.edge.isVertical ? element.originAlong(for: model.edge) - PillController.bodyStart : (PillMetrics.depth(for: model.edge) - PillMetrics.cell) / 2)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 悬停描述卡：白底深字，尾巴指向悬停的元素。
private struct PillCardView: View {
    @AppStorage("pillSurface") private var surface = "glass"
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var model: PillModel
    let element: PillElement
    let tailOffset: CGFloat
    private var direction: PillCardTailDirection {
        switch model.edge { case .right: .right; case .left: .left; case .top: .up; case .bottom: .down }
    }
    var body: some View {
        let shape = PillTooltipSilhouette(direction: direction, tailOffset: tailOffset)
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .padding(.leading, direction == .left ? 28.2 : 0)
            .padding(.trailing, direction == .right ? 28.2 : 0)
            .padding(.top, direction == .up ? 28.2 : 0)
            .padding(.bottom, direction == .down ? 28.2 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if surface == "glass" && !reduceTransparency {
                    if #available(macOS 26.0, *) { Color.clear.glassEffect(.regular, in: shape) }
                    else { shape.fill(.black) }
                } else { shape.fill(.black) }
            }
            .contentShape(shape)
            .onTapGesture { model.controller?.activate(element) }
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch element {
        case .today:
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 9.5, weight: .medium))
                Text("今日任务").font(.system(size: 13.7, weight: .semibold))
                Spacer(minLength: 0)
            }.foregroundStyle(Color.primary.opacity(0.88))
            if model.todayOpen + model.todayDone == 0 {
                Text("今天没有到期任务。")
                    .font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.55)).lineSpacing(3)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(model.ringColor)
                                .frame(width: max(4, geo.size.width * model.todayFraction))
                        }
                    }.frame(height: 4)
                    HStack {
                        Text("未完成 \(model.todayOpen)").font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.7))
                        Spacer()
                        Text("已完成 \(model.todayDone)").font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.45))
                    }
                }
                ForEach(model.todayItems.prefix(3)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill((entry.due ?? "") < AppModel.dateKey(Date()) ? Color.orange : Color.primary.opacity(0.3))
                            .frame(width: 4, height: 4).padding(.top, 4)
                        Text(entry.text).font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if model.todayItems.count > 3 {
                    Text("还有 \(model.todayItems.count - 3) 项…")
                        .font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
            Text("查看任务").font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.4))
        case .compose:
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").font(.system(size: 9.5, weight: .medium))
                Text("新建记录").font(.system(size: 13.7, weight: .semibold))
                Spacer(minLength: 0)
            }.foregroundStyle(Color.primary.opacity(0.88))
            Text("记下想法或任务。")
                .font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.65)).lineSpacing(4)
            Spacer(minLength: 0)
            Text("点击新建记录").font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.4))
        case .settings, .move:
            EmptyView()
        }
    }
}

enum PillCardTailDirection {
    case left, right, up, down
}

/// Uses the production view and in-memory fixture for repeatable visual checks.
struct PillPreviewView: View {
    @ObservedObject var model: PillModel
    @AppStorage("pillSurface") private var surface = "glass"
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Picker("边缘", selection: $model.edge) {
                    ForEach(PillEdge.allCases) { edge in Text(edge.label).tag(edge) }
                }.pickerStyle(.segmented)
                Picker("表面", selection: $surface) { Text("通透").tag("glass"); Text("纯黑").tag("black") }.pickerStyle(.segmented)
            }
            HStack {
                Toggle("展开", isOn: $model.expanded)
                ForEach([PillElement.today, .compose, .settings], id: \.rawValue) { element in
                    Button(element == .today ? "任务详情" : element == .compose ? "录入详情" : "设置详情") { model.expanded = true; model.hovered = element }
                }
            }
            PillRootView(model: model)
            Spacer(minLength: 0)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(NotoDesign.canvas)
            .onAppear { model.refresh(force: true); model.expanded = true; model.hovered = .today }
    }
}
