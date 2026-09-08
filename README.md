# noto

一个原生 macOS 小记与待办应用。一个输入入口，本地保存；需要时交给已安装的 AI CLI 整理。

## 运行

需要 macOS 14+、Xcode/Swift 6 工具链。

```sh
zsh scripts/build.sh
open build/Noto.app
```

默认以记录列表为主体。双击阅读区空白处就近打开输入框，或用 ⌘N 在顶部唤起。回车换行，⌘ 回车保存问题并发送给当前 AI；也可以点“记为小记”或“添加待办”。Esc 或点击外部收起输入框，进程内草稿保留；再次双击只移动同一个输入框。AI 运行时可以继续写草稿，完成后才能再次发送。

双击记录正文原位编辑，⌘ 回车或“保存”提交，Esc 或“取消”放弃。未保存修改会阻止切换到其他记录或新建。待办沿用原生日期控件；带对话的记录只修改列表文字，历史问答不变。打开历史对话统一点击记录上的“对话”按钮。

⌘K 搜索，⌘, 设置 AI CLI，⌘⇧ 回车添加待办（输入框打开时）。⌘Z 撤销文本、⌘⌥Z 重做文本、⌘⇧Z 撤销记录操作。操作反馈固定在阅读区底部，保存冲突保留草稿。宽度不足 980pt 时对话切为单栏；⌘N 返回记录并打开输入，顶栏对话按钮可返回当前对话。

## 双击交互交付（2026-09-09）

[交互规范与验收](design/DOUBLE-CLICK-QA.md)包含按需录入、AI、原位编辑的状态约定和原生截图。以下早期验收中的旧快捷键已由本次规范替代。

## 全项目设计交付（2026-09-08）

- [设计规范](design/DESIGN-SYSTEM.md)：页面、功能、视觉、组件、动效和状态契约。
- [目标与交付清单](design/DELIVERY.md)：逐功能验收结果。
- [本次验证报告与截图](design/REDESIGN-QA.md)：原生操作、真实 AI、测试日志及明确限制。

回归检查：`python3 scripts/verify-cli.py`。长历史测试数据：`python3 scripts/seed-design-fixture.py /tmp/noto-new-fixture.sqlite`（拒绝覆盖已有数据库）。深色视觉检查：`open -n build/Noto.app --args --preview --dark`；只改变预览进程的外观，不修改系统设置。

左侧默认显示短横杠与日期锚点，左上角按钮可展开为日期侧栏，并记住展开状态。日期按记录的本地创建日期分组，点击定位正文，滚动正文同步高亮。历史首次读取 40 条，接近列表末尾再加载下一批；搜索直接查询数据库中的全部历史。

## 本地 CLI 和 Skill

```sh
build/bin/noto note add --text '今天想清楚了产品方向。' --json
build/bin/noto todo add --title '整理草图' --due 2026-09-09 --json
build/bin/noto todo list --status open --json
build/bin/noto search '草图' --json
build/bin/noto todo complete --id FULL_ID --json
build/bin/noto conversation --id FULL_ID --json
build/bin/noto export --include-conversations --json
build/bin/noto doctor
```

命令返回 JSON，失败返回非零退出码。`--request-id` 支持创建重试去重。可将 `build/bin` 加入 PATH；`Skills/noto/SKILL.md` 是可安装到所用 Agent 的技能包。Skill 不等于云端到本机的连接：ChatGPT 云端写入仍需后续 MCP/隧道接入。

应用与 CLI 共享 `~/Library/Application Support/Noto/notes.sqlite`。界面每 1.5 秒读取变更。测试可用 `NOTO_DATABASE` 或 CLI 的 `--database` 指定隔离数据库。数据库迁移由 GRDB 管理。备份建议使用 `export --include-conversations` 导出笔记及完整对话；不要在运行时只复制 SQLite 主文件而遗漏 WAL。

## AI

支持启动本机 Codex、Claude Code、OpenCode 和 Kimi CLI，使用各自的现有登录和默认模型。默认 OpenCode，设置中仅提供一个 AI CLI 选择项。首次使用请先在该 CLI 中完成登录。

首次提问自动保存为一条笔记；点击记录上的“对话”按钮重新打开完整对话并继续。每轮用户消息与 AI 回复独立保存，搜索会命中完整对话并返回所属记录。对话输入回车换行，⌘ 回车发送；失败可重试，停止会保留已保存的消息。修改列表文字不会改写原问题或历史回复。

每轮问题下的「执行过程」默认收起，点击查看上下文读取数量、实际 CLI 启动与返回、回复保存结果及耗时。失败信息也会保存。这里显示应用的实际执行状态，不包含模型内部推理文本。

输入、此前对话和当前已加载的记录（搜索时为已加载的匹配结果）会提供给设置里选定的 CLI。AI 返回结构化意图，Noto 校验后在同一事务中执行，失败不做部分修改。AI 运行期间的外部修改会阻止覆盖。超时 150 秒，支持取消，错误时保留输入。不会使用假回复代替真实 AI。

持续对话由 Noto 保存和重放历史：每轮调用 CLI 的非交互接口，不依赖 CLI 自己的 session ID，因此重启应用后仍可继续。回复完成后显示，不逐 token 流式输出；保存的是用户和 AI 可见消息，不包括 CLI 内部推理或工具日志。历史不会静默截断，达到输入容量后会提示开启新对话。不提供终端 TUI 或 CLI 原生工具审批流。CLI 各版本可能改变参数，需要按安装版本核实。到期日目前精确到天，不会在指定时间弹出提醒。

`noto ask '明天整理草图' --provider codex` 只生成建议；加 `--apply` 才写入。AI 工具已有此 Skill 时应直接调用数据命令，无需再嵌套调用 ask。

## 验证与视觉稿

```sh
swift test
open build/Noto.app --args --preview
```

`--preview` 使用内存示例数据，供视觉检查，不写入个人数据。正式启动为空数据或用户已保存的数据。所选视觉稿：`design/reference.png`。

SwiftUI + AppKit / GRDB + SQLite / Swift Argument Parser。构建脚本生成本机 ad-hoc 签名的应用，不是已公证的公开发行包。

## 早期本机验证（2026-09-08；旧输入规则已替代）

- 单元测试：事务回滚、幂等创建、撤销冲突保护、共享数据库、JSON 解析通过。
- CLI：创建、重试、查询、完成、过滤、导出通过。
- 原生 GUI：回车记录、搜索快捷键、完成/撤销、设置单项选择通过。
- OpenCode：原生窗口 ⌘ 回车 → 真实 CLI → SQLite → 界面待办完整闭环通过。
- Kimi：stream-json 结构化返回通过。
- Codex：本机 0.144.1 CLI 无法使用配置中的默认模型，服务端要求升级 CLI；未修改用户配置或切换其模型。
- Claude Code：本机调用 150 秒超时，错误路径与输入保留正常；尚未完成成功调用验证。
