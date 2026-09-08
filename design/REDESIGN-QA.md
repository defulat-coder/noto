# Noto 全项目设计验收

2026-09-08。交付：`build/Noto.app`，SwiftUI/AppKit 原生应用。设计先于实现，规范见 [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md)，目标见 [DELIVERY.md](DELIVERY.md)。

## 结果

本次范围内的主输入、记录与待办列表、日期导航、搜索、反馈、编辑、AI 对话和设置均已完成设计与实现。保留本地 SQLite、现有 CLI 和 AI provider 契约。没有新增依赖。修改集中在 `Sources/NotoApp/NotoApp.swift`；原始源码备份保存在 `redesign/NotoApp.before.swift.txt`。

最终 Release 构建成功；4 项核心测试零失败；新增可重复运行的 CLI 端到端检查通过。原生 GUI 在独立数据库中验证，个人数据库未用于测试写入。真实 Kimi 对话成功，OpenCode 运行后手动停止以检验恢复路径；不将过去的 provider 成功当作本次结果。

## 设计变更评审

| Before | After | Why |
| --- | --- | --- |
| 操作反馈排在全部历史之后 | 阅读区域底部固定反馈，可撤销与关闭 | 长列表也能确认结果 |
| 正文、时间、截止日、编辑按钮挤在同一行 | 正文一行层级，元信息与操作一行层级 | 长中文和窄窗口保持可读 |
| 待办创建藏在快捷键/右键 | 输入下方直接展示待办与 AI 操作 | 让操作可发现 |
| 快捷键打开对话也做全局布局动画 | 对话、搜索、列表更新即时完成；鼠标日期展开 180ms | 高频使用无需等待 |
| 960pt 对话最小窗口 | 980pt 以下切为单栏对话，保持原 620pt 窗口最小宽度 | 避免强制放大或裁切 |
| 日期字符串手填 | 截止日期开关与原生日期控件 | 预防格式错误 |
| 草稿为空就显示“已保存” | 区分正在回复、回复未完成、等待重试、草稿未发送、对话已保存 | 状态与真实持久化结果一致 |
| 未回复时还能追加问题 | 先重试悬空问题，再继续下一轮 | 保持对话顺序与恢复路径明确 |
| 无上限的输入高度 | 原生滚动文本框；主输入上限 160pt、对话 120pt | 长文本不挤走发送按钮 |
| ⌘⇧Z 同时绑定系统重做与记录撤销 | ⌘Z 文本撤销、⌘⌥Z 文本重做、⌘⇧Z 记录撤销 | 原生实测发现并修复冲突 |
| 快捷键定位可能让输入滚到顶栏下 | 顶部内容边界与包含留白的滚动定位 | 长历史返回输入仍可读可操作 |

## 功能证据

| 流程 | 本次验证 |
| --- | --- |
| 空状态 | 输入提示、第一条记录引导；无内容时记录、待办、AI 禁用 |
| 记录 | 原生粘贴中文 → 回车 → 列表与反馈；SQLite/CLI 导出确认保存；另一个应用进程重读记录 |
| 长输入 | 24 行中文在框内滚动，保存按钮可达；回车保存成功 |
| 换行/撤销 | Shift 回车留下两行草稿；最终版本 ⌘Z 撤销文本、⌘⌥Z 重做、⌘⇧Z 撤销记录均实测 |
| 待办 | 显式按钮创建、复选框完成、反馈栏撤销、⌘⇧ 回车创建、快捷键撤销 |
| 编辑 | 待办编辑器自动聚焦；清空后保存禁用；恢复文本、启用日期、⌘ 回车保存；列表出现今天到期 |
| 搜索 | ⌘K 聚焦；关键词命中并显示 1 条记录；无结果引导；Esc 清空；第 55 天历史能被检索 |
| 日期 | 展开与收起；9 月 3 日跳转后内容与选中同步；⌘N 回到输入 |
| 分页 | 110 条测试记录、55 天；滚到底部加载后可达 7 月 16 日及第 55 天；数据库分页顺序/去重另有核心测试 |
| 设置 | 原生选择器包含四个 provider；选 Codex 后关闭重开保留；再切 OpenCode、Kimi；无新增永久设置 |
| AI 运行 | ⌘ 回车保存原问题并显示执行过程；OpenCode 等待时提供停止；停止后保留原问题并显示错误、重试 |
| AI 成功 | 切 Kimi 重试同一问题，10 秒内真实返回并创建 `检查新版 Noto 的设计`，到期日 `2026-09-09` |
| AI 多轮 | 第二轮正确引用第一轮任务；独立导出确认 4 条有序消息、仅 1 条该待办，无重复创建 |
| AI 重新打开 | Esc 返回主输入；重开恢复同一对话与未发送草稿；新应用进程能读取已保存的历史 |
| 响应式 | 主界面展开日期在约 718px 的截图宽度中正常换行；窄对话变单栏；宽窗口恢复分栏 |
| 明暗外观 | 浅色各主流程截图；深色内存预览验证系统语义色、正文、输入、列表与反馈。不修改 macOS 系统外观 |

## 截图索引

截图是原生应用实际渲染，不是生成效果图。宽窗口常规截图约 1106×768；紧凑截图尺寸不同。前后内容不是完全相同的数据集，比较的是层级、留白和控件位置，不宣称像素级复刻。

| 区域 | 原始参考/Before | 实现/After |
| --- | --- | --- |
| 主阅读结构 | [原有界面](native-polish-before.jpg) | [最终主界面](redesign/main-final.png) |
| 日期侧栏 | [原日期侧栏](date-anchors-expanded.jpg) | [日期展开与定位](redesign/dates-expanded.png) |
| 对话 | [原有对话](native-polish-after.jpg) | [真实多轮回复](redesign/chat-final.png) |
| 设置 | [原设置](settings.png) | [新版设置](redesign/settings.png) |

其他状态：[空界面](redesign/empty.png)、[搜索](redesign/search.png)、[无结果](redesign/search-empty.png)、[编辑待办](redesign/edit-todo.png)、[长输入](redesign/long-input.png)、[运行中](redesign/chat-running.png)、[停止与恢复](redesign/chat-error.png)、[单栏对话](redesign/chat-compact.png)、[紧凑主界面](redesign/main-compact.png)、[历史末尾](redesign/history-end.png)、[深色预览](redesign/dark.png)。早期截图中的临时悬停与旧反馈由后续修正覆盖，以 `main-final.png` 和最终源码为准。

## 可重复检查

```sh
swift test
zsh scripts/build.sh
python3 scripts/verify-cli.py
python3 scripts/seed-design-fixture.py /tmp/noto-fresh-history.sqlite
open -n build/Noto.app --env NOTO_DATABASE=/tmp/noto-fresh-history.sqlite
open -n build/Noto.app --args --preview --dark
```

[测试日志](redesign/tests.log)、[构建日志](redesign/build.log)、[CLI 日志](redesign/cli.log)、[隔离测试数据库导出](redesign/verified-data.json)。导出含测试过程中创建的临时内容；不是产品示例数据，也不进入正式用户数据库。

## 边界

- Kimi 的成功经过真实 GUI → CLI → SQLite → GUI 验证；OpenCode 本次验证的是运行与手动停止，未取得成功回复。Codex 与 Claude Code 未重新做成功调用；README 历史限制仍单独保留。
- AI 是完成后整条显示，未新增 token 流式回复、定时提醒或云端连接。
- 草稿在本次进程中切换对话时保留，未发送草稿不承诺跨退出恢复。已发送对话持久化已验证。
- 辅助功能名称、原生控件、键盘操作和减少动态效果分支已覆盖实现；未做完整 VoiceOver 审计、全部系统版本/多显示器/所有窗口尺寸或逐帧性能基准。
- 应用是本机构建的 ad-hoc 签名版本，未做公开分发公证。
