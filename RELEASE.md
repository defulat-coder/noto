# macOS 打包与发布

需要 macOS 14+。Apple 芯片下载 arm64，Intel 下载 x86_64。打开 DMG，把 Noto.app 拖到 Applications，然后从“应用程序”启动。笔记和待办独立工作；AI 需要安装并登录对应 CLI。

## 本机打包

```sh
zsh scripts/package.sh
```

生成 `dist/Noto-0.1.0-macOS-arm64-unnotarized.dmg`（名称按版本和当前架构变化）及 SHA-256 校验文件。`VERSION` 是版本来源；`BUILD_NUMBER` 默认为 1。`build/`、`dist/` 和证书不入 Git。

未配置签名时只生成带 `unnotarized` 标记的测试版。它不是已公证发行版，其他 Mac 的 Gatekeeper 可能阻止打开。不修改系统安全设置。应用数据存放在用户的 Application Support/Noto 下；安装包不包含开发者数据库或 AI 登录凭据。

## GitHub 自动构建

`.github/workflows/release.yml` 使用 macos-15 / macos-15-intel，各自运行测试、DMG 打包、CLI 回归并上传附件。

- 手动运行 `macOS release`，关闭 `notarize`：生成两个架构的未公证测试包，在运行页 Artifacts 下载。
- 推送正式 `vX.Y.Z` 标签：要求标签与 VERSION 一致，强制签名、公证；两个架构均成功后自动发布 GitHub Release。
- 手动运行只构建附件；正式标签触发才发布。测试 Release 使用 `preview-` 标签，避免触发正式发布。

```sh
gh workflow run release.yml -f notarize=false
# 正式发行：先修改 VERSION、提交并推送，再创建版本标签
# git tag v0.1.1
# git push origin v0.1.1
```

## Apple 签名与公证

正式发行需要 Apple Developer Program 的 Developer ID Application 证书与私钥；本机当前未发现有效签名身份，尚未完成真实公证。不要把私钥或密码提交到仓库或聊天。

在仓库 Settings → Secrets and variables → Actions 配置以下 Secrets：

| Secret | 内容 |
| --- | --- |
| APPLE_CERTIFICATE_BASE64 | Developer ID Application 的 .p12 文件，Base64 编码 |
| APPLE_CERTIFICATE_PASSWORD | 导出 .p12 时设置的非空密码 |
| APPLE_SIGNING_IDENTITY | 完整 Developer ID Application 签名名称 |
| APPLE_ID | 开发者 Apple ID |
| APPLE_TEAM_ID | 开发者 Team ID |
| APPLE_APP_PASSWORD | Apple ID 专用 App 密码 |

CI 在一次性 macOS runner 中创建临时钥匙串、导入证书，开启 hardened runtime 签名，公证并装订应用，再公证并装订 DMG，结束时清理证书和临时钥匙串。本应用不使用沙盒或需要额外权限的 entitlement。

本机也可使用钥匙串里的签名和 notarytool 凭据配置：

```sh
# 按提示输入凭据，避免把密码写入命令历史
xcrun notarytool store-credentials noto-release
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE=noto-release REQUIRE_SIGNING=1 zsh scripts/package.sh
```

## 验证

```sh
swift test
python3 scripts/verify-cli.py
hdiutil verify dist/*.dmg
# 在 dist 目录运行对应 .sha256 文件
(cd dist && shasum -a 256 -c Noto-0.1.0-macOS-arm64-unnotarized.dmg.sha256)
```

当前本机验证记录见 `design/RELEASE-QA.md`。Intel 构建可在 GitHub runner 验证，不能把本机 arm64 成功当作 Intel 实机验证。签名公证和其他 Mac 的 Gatekeeper 安装验证需有证书后完成。

官方依据：[GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)、[macOS runner 签名](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)、[Apple Developer ID](https://developer.apple.com/developer-id/)。
