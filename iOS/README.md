# Noto iOS

原生 SwiftUI 客户端，iOS 17+，复用仓库内 NotoCore / NotoSync。

打开 `NotoIOS.xcodeproj`，选择 NotoIOS scheme 和 iPhone 模拟器运行。真机运行需在 Signing & Capabilities 中选择自己的开发团队，并按团队权限设置 Bundle Identifier。

```sh
xcodebuild -project iOS/NotoIOS.xcodeproj -scheme NotoIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/noto-ios-derived build

xcodebuild -project iOS/NotoIOS.xcodeproj -scheme NotoIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/noto-ios-derived test
```

启动后无需账号即可在本地创建、编辑、完成、删除待办，支持搜索、重要筛选和日期分组。账号与同步页面输入自己的 Supabase URL、publishable key 与 PowerSync URL，再登录已创建的账号。公用配置不能填入 service-role key。

登录后的账号库与本机库隔离；需要把本机待办上传时，明确点击“导入本机待办”。冲突正文保留在同步设置中，可另存为新待办。退出登录返回本机库。

UI 测试通过启动参数使用独立临时数据库，验证离线增改、重启持久化、完成与删除。实际跨设备同步验收需要已部署的后端和两个客户端，模拟器本地通过不表示云端验收通过。

## 真实同步验收

先按 backend 文档启动测试服务并生成 `backend/.local-docker/client-fixture.json`，再运行：

```sh
iOS/run-live-tests.sh
```

也可通过 `NOTO_LIVE_FIXTURE` 指定同结构的测试环境文件（含两名测试账号）。脚本使用独立 `com.noto.ios.integration` 标识构建，避免覆盖普通客户端的本地数据和会话。fixture 临时复制到 `/tmp`，只供测试 runner 读取，执行后删除。不要用生产账号作为测试账号。

该 opt-in 测试通过真实界面配置并登录，验证创建任务上传到 PostgreSQL、服务端 RPC 修改经 PowerSync 下载、退出再登录恢复，以及第二账号的界面与 RLS 隔离。默认的普通测试会跳过此项。

DerivedData 放在 `/tmp`，避免模拟器动态框架加载被 macOS 的 Documents 目录访问权限阻塞；模拟器使用 Xcode 默认的 ad-hoc 签名，无需开发者账号。

2026-09-09 验证：Xcode 26.2、iPhone 17 模拟器（iOS 26.3）上，离线任务完整流程测试通过（26.278 秒）；真实本地 Supabase + PowerSync 的账号与双向同步测试通过（50.734 秒）。这不代替签名后的实体 iPhone 验收或生产云部署验收。


无开发团队时，可验证 iPhone 目标编译（不代表可安装或已做真机验收）：

```sh
xcodebuild -project iOS/NotoIOS.xcodeproj -scheme NotoIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/noto-ios-device-derived CODE_SIGNING_ALLOWED=NO build
```

本次该构建已通过，未签名产物复制到 `build/ios-device-unsigned/NotoIOS.app`。配置开发团队后应重新签名构建，并在实体设备上完成同步、离线恢复和前后台切换验收。
