#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export VERSION=${VERSION:-$(<VERSION)}
if [[ "${REQUIRE_SIGNING:-0}" == 1 ]]; then
    [[ -n "${SIGNING_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]] || { print -u2 '正式发布需要 SIGNING_IDENTITY 和 NOTARY_PROFILE。'; exit 1; }
fi
if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGNING_IDENTITY:-}" ]]; then
    print -u2 '公证需要 Developer ID 签名。'; exit 1
fi
zsh scripts/build.sh
APP="$PWD/build/Noto.app"
ARCH=$(uname -m)
SUFFIX=-unnotarized
[[ -z "${NOTARY_PROFILE:-}" ]] || SUFFIX=''
mkdir -p dist
STAGE=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" "$STAGE/notarize.zip"
    xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose "$APP"
fi
mkdir "$STAGE/image"
ditto "$APP" "$STAGE/image/Noto.app"
ln -s /Applications "$STAGE/image/Applications"
cat > "$STAGE/image/安装说明.txt" <<'INFO'
把 Noto.app 拖到 Applications 文件夹完成安装，然后从应用程序打开。
需要 macOS 14 或更高版本；下载时请选择与 Mac 芯片匹配的文件。
小记和待办无需 AI；AI 功能需要预先安装并登录所选 AI CLI。
带 unnotarized 的文件是未公证测试版，可能被 macOS 阻止打开。
INFO
NAME="Noto-$VERSION-macOS-$ARCH$SUFFIX"
DMG="$PWD/dist/$NAME.dmg"
hdiutil create -volname "Noto $VERSION" -srcfolder "$STAGE/image" -ov -format UDZO "$DMG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    codesign --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
print "$DMG"
