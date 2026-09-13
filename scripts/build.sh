#!/bin/zsh
set -eu
cd "${0:A:h:h}"
VERSION=${VERSION:-$(<VERSION)}
BUILD_NUMBER=${BUILD_NUMBER:-1}
export VERSION BUILD_NUMBER
python3 - <<'CHECK'
import os,re
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",os.environ["VERSION"]), "VERSION must be X.Y.Z"
assert re.fullmatch(r"[1-9][0-9]*",os.environ["BUILD_NUMBER"]), "BUILD_NUMBER must be positive"
CHECK
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="$PWD/build/Noto.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$PWD/build/bin"
chmod -R u+w "$APP/Contents/Resources"
cp "$BIN/NotoDesktop" "$APP/Contents/MacOS/Noto"
cp "$BIN/noto" "$PWD/build/bin/noto"
# SwiftPM leaves dynamic binary targets beside the executable. Bundle them so the
# installed app does not depend on the build directory or the developer's Xcode.
for framework in "$BIN"/*.framework(N); do
    ditto "$framework" "$APP/Contents/Frameworks/${framework:t}"
done
xcrun swift-stdlib-tool --copy --platform macosx \
    --scan-executable "$APP/Contents/MacOS/Noto" \
    --scan-folder "$APP/Contents/Frameworks" \
    --destination "$APP/Contents/Frameworks"
python3 - "$APP/Contents/MacOS/Noto" <<'RPATH'
import re, subprocess, sys
binary = sys.argv[1]
commands = subprocess.check_output(["otool", "-l", binary], text=True)
for path in re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset", commands):
    if ".xctoolchain/" in path:
        subprocess.run(["install_name_tool", "-delete_rpath", path, binary], check=True)
RPATH
cp design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for resource in "$BIN"/*.bundle(N); do
    cp -R "$resource" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.noto.local</string>
<key>CFBundleName</key><string>Noto</string>
<key>CFBundleDisplayName</key><string>noto</string>
<key>CFBundleExecutable</key><string>Noto</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp THIRD-PARTY-NOTICES/codenotch.txt "$APP/Contents/Resources/Codenotch-LICENSE.txt"
cp .build/checkouts/GRDB.swift/LICENSE "$APP/Contents/Resources/GRDB-LICENSE.txt"
cp .build/checkouts/swift-argument-parser/LICENSE.txt "$APP/Contents/Resources/ArgumentParser-LICENSE.txt"
cp .build/checkouts/powersync-swift/LICENSE "$APP/Contents/Resources/PowerSync-LICENSE.txt"
# Sign from the inside out; the outer signature seals nested frameworks and Swift
# compatibility libraries (including libswiftCompatibilitySpan when required).
signing_args=(--force --sign "${SIGNING_IDENTITY:--}")
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then signing_args+=(--options runtime --timestamp); fi
for nested in "$APP/Contents/Frameworks"/*.framework(N) "$APP/Contents/Frameworks"/*.dylib(N); do
    codesign "${signing_args[@]}" "$nested"
done
codesign "${signing_args[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
