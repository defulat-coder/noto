# macOS 分发验收 · 2026-09-09

- 本机 arm64 Release 构建成功；DMG 生成、hdiutil 校验、应用代码签名完整性验证通过。
- DMG 只读挂载，Applications 链接指向 /Applications；将应用复制至独立临时目录后原生启动成功（内存预览数据，未写入个人数据库）。
- 8 项 Swift 测试和 CLI 回归通过。脚本 zsh 语法、workflow YAML 语法通过。
- REQUIRE_SIGNING=1 且缺少证书/公证凭据时立即失败；无效 VERSION 被拒绝。
- 安装包带依赖许可证，未包含用户数据库或 AI 认证。产物不提交 Git。
- 当前产物是 ad-hoc 签名、未 Apple 公证的预览版；不声称通过其他 Mac 的 Gatekeeper 或正式公证验证。
- 本机没有 Developer ID 身份，Apple 签名与公证自动化已配置但未真实执行。配置步骤见 [RELEASE.md](../RELEASE.md)。

日志：[打包](release/package.log)、[Swift 测试](release/tests.log)、[CLI](release/cli.log)。

本机应用已安装至 `/Applications/Noto.app`，安装后的签名完整性验证通过。

GitHub Actions [34251419454](https://github.com/indie-builder/noto/actions/runs/34251419454) 两个架构均成功：macos-15/arm64 和 macos-15-intel/x86_64 各自通过 Swift 测试、CLI 回归、DMG 生成与上传。下载后两个架构 SHA-256 校验和 DMG 完整性检查通过；云端 arm64 包的应用签名完整性验证通过。

首个 [公开预览 Release](https://github.com/indie-builder/noto/releases/tag/preview-0.1.0) 使用该次 CI 产物。正式签名、公证路径仍待 Apple 凭据；本次明确标为未公证预览版。
