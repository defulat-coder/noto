# 桌面端任务同步

目标：保留现有 Mac 记录、待办、AI 和 CLI，在 Mac 之间提供可离线使用、支持账号隔离和冲突恢复的待办同步。采用 Supabase Auth / PostgreSQL + PowerSync；不依赖 iCloud 文件同步。

当前只维护 macOS 客户端；以下保留桌面端仍使用的同步架构、配置方式和历史验证记录。

## 范围

- Mac 保留现有界面，设置增加服务配置、邮箱密码登录、退出、导入本机待办、同步状态和冲突恢复。
- 无账号也可本地使用；登录打开独立账号库。上传历史待办需要明确点击「导入本机待办」。退出返回原本机库，账号缓存保留以便下次离线打开。导入根据账号和来源任务生成稳定的新 ID，避免不同账号导入同一任务相互冲突；同账号重复导入保持幂等。
- 首期同步待办，笔记和 AI 对话仍留在来源设备；导入不会自动上传它们，也不会删除原始本机库。删除/恢复来源设备任务时保留其对话。
- CLI 默认跟随 Mac 当前账号数据库；`--database` / `NOTO_DATABASE` 仍可指定独立库。CLI 的写入进入同一持久队列，Mac 应用运行时负责网络同步；CLI 本身不是后台同步守护进程。

## 实现与数据保障

共享 `NotoCore` 承担业务数据和迁移，`NotoSync` 承担认证、上传和下载。桌面应用与本地 CLI 共用数据模块。

GRDB 业务库的 SQLite 触发器在业务写入的同一事务中写入 outbox，因此 GUI、CLI、AI 和恢复操作都被捕获。PowerSync 使用独立、仅下载的副本库，收到远端数据后批量写入业务库。上传只在 RPC 返回持久确认后移除对应队列项；网络失败和重启不会丢掉待上传修改。

每条任务使用服务器修订号，已确认的新版本不会被较旧的下载覆盖；尚未上传的本机修改也不会被下载直接覆盖。不同业务字段可合并，同一字段的冲突保存完整版本，可「另存为新任务」。删除使用墓碑，旧离线编辑不能复活任务；恢复必须是显式操作。服务器忽略设备的更新时间，避免设备时钟决定冲突胜负。

登录令牌只保存在系统钥匙串。账号数据库按服务和用户分别存放；后端由 JWT 身份限制 RPC 和 RLS，PowerSync 规则也按已验证身份过滤。客户端只配置 publishable/anon key，禁止 service-role key。

为避免同步干扰交互，业务库操作放在后台执行；下载按批次提交，已处理修订不重复写入；只有数据变化才通知界面刷新。同步状态与业务数据更新分开，空轮询不触发全列表重载。

## 构建和运行

Mac（macOS 14+，Swift 6.1+）：

```sh
zsh scripts/build.sh
open build/Noto.app
```

产物为 `build/Noto.app` 和 `build/bin/noto`。应用嵌入 PowerSync framework 和所需 Swift 兼容库；没有提供开发者签名时使用本地 ad-hoc 签名。公开分发仍需 Developer ID 签名与公证。


本地真实同步环境见 [backend/local/README.md](../backend/local/README.md)：

```sh
npm --prefix backend ci
(cd backend && ./local/start.sh)
npm --prefix backend test
npm --prefix backend run test:live
NOTO_LIVE_FIXTURE="$PWD/backend/.local-docker/client-fixture.json" swift test --filter LiveSyncTests
```

生成的 fixture 仅用于本机开发，不提交、不随应用分发。后台服务在 `127.0.0.1` 监听。云端迁移、复制权限、JWT 验证与部署流程见 [backend README](../backend/README.md)。

## 验收记录（2026-09-09）

| 层级 | 验证内容 | 结果 |
| --- | --- | --- |
| 数据与 Mac 逻辑 | 46 项 Swift 测试，含持久离线队列、CLI 双连接、账号隔离、旧修订保护、冲突恢复、删除/恢复对话、原有交互回归 | 已通过 |
| PostgreSQL 合约 | 真实 SQL/PLpgSQL、权限、幂等、字段合并、删除与恢复 | PGlite 已通过 |
| 本地真实服务 | Supabase Auth、RPC、PostgreSQL 逻辑复制、PowerSync 三个独立 SQLite 客户端、账号隔离 | 已通过 |
| Mac 发布包 | Release 构建、嵌套签名、严格验签、复制到独立目录后启动 | 已通过 |
| Swift 真实同步链路 | 生产 Swift SDK、GRDB outbox、真实 Auth/RPC、两端冲突/恢复和第三账号隔离 | 已通过 |

尚未获得可写入的指定云项目确认和 Apple 分发签名环境，因此本地验证不等同于云端上线。没有修改已有的远端 Supabase 项目。再次检查本机：`security find-identity -v -p codesigning` 返回 0 个有效签名身份；`xcrun devicectl list devices` 返回无设备。


## 云端上线验收

1. 指定 Supabase/PowerSync 测试环境，部署迁移与同步规则，分别创建两个测试账号。检查客户端仅包含公开配置。
2. 两台 Mac 登录同一账号：一端新增、改日期、改优先级、完成，另一端前台连接后收敛。记录实际同步延迟。
3. 两端离线修改，杀掉应用并重开后再联网：队列恢复、不同字段合并、相同字段冲突可见且原文可恢复。
4. 一端删除，另一端离线编辑后联网：任务保持删除且编辑保留为冲突；显式恢复后两端收敛。
5. 切换另一账号，任务与冲突不串号；退出后原本机笔记仍在。断网启动已登录账号仍能读写缓存。
6. 对历史数据先备份再迁移，验证导入幂等；运行大数据量交互与首轮同步检查；完成签名、公证和备份恢复演练。

墓碑、幂等收据和冲突当前保留，不自动清理；未来清理需先建立离线设备有效期与数据保留约定，不能直接删除以节省空间。
