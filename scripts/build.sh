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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/build/bin"
chmod -R u+w "$APP/Contents/Resources"
cp "$BIN/NotoDesktop" "$APP/Contents/MacOS/Noto"
cp "$BIN/noto" "$PWD/build/bin/noto"
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
cp .build/checkouts/GRDB.swift/LICENSE "$APP/Contents/Resources/GRDB-LICENSE.txt"
cp .build/checkouts/swift-argument-parser/LICENSE.txt "$APP/Contents/Resources/ArgumentParser-LICENSE.txt"
# This app has no nested executable code; sign the app after copying resources.
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "$APP"
