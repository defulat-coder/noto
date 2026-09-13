import Foundation
import os

// 统一日志通道：Console.app 过滤 subsystem == "noto"，或 `log stream --predicate 'subsystem == "noto"'`。
// 动态字符串默认 privacy 为私有（诊断时可见），UI 层不加日志，CLI 的 print 是 JSON 契约。
public enum NotoLog {
    public static let sync = Logger(subsystem: "noto", category: "sync")
    public static let agent = Logger(subsystem: "noto", category: "agent")
}
