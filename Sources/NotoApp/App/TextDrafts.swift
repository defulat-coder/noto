import Combine
import Foundation

/// 高频输入文本（每个按键都变化）独立成 ObservableObject：
/// 只有承载输入的少数视图观察它，打字不再让整棵 UI 树重算。
/// 程序化写入（保存后清空、账号切换重置、跨会话草稿恢复）也走这里。
@MainActor
final class TextDrafts: ObservableObject {
    @Published var composer = ""   // 新建录入
    @Published var chat = ""       // 当前对话输入
    @Published var task = ""       // 新建任务草稿
    @Published var edit = ""       // 行内/任务编辑
}
