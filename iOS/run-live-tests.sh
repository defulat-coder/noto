#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_source="${NOTO_LIVE_FIXTURE:-$repo_root/backend/.local-docker/client-fixture.json}"
derived_dir="${NOTO_IOS_DERIVED_DATA:-/tmp/noto-ios-derived}"
destination="${NOTO_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
[[ -f "$fixture_source" ]] || { echo "Missing test backend fixture: $fixture_source" >&2; exit 1; }
fixture_copy="$(mktemp /tmp/noto-ios-fixture.XXXXXX)"
cp "$fixture_source" "$fixture_copy"
trap 'rm -f "$fixture_copy"' EXIT
xcodebuild -project "$repo_root/iOS/NotoIOS.xcodeproj" -scheme NotoIOS \
  -configuration Debug -destination "$destination" -derivedDataPath "$derived_dir" \
  PRODUCT_BUNDLE_IDENTIFIER=com.noto.ios.integration build-for-testing
python3 - "$derived_dir" "$fixture_copy" <<'PY'
import pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1]) / 'Build/Products'
source = max(products.glob('*.xctestrun'), key=lambda p: p.stat().st_mtime)
data = plistlib.loads(source.read_bytes())
def inject(node):
    if isinstance(node, dict):
        if 'TestBundlePath' in node:
            node.setdefault('EnvironmentVariables', {})['NOTO_LIVE_FIXTURE'] = sys.argv[2]
        for value in node.values(): inject(value)
    elif isinstance(node, list):
        for value in node: inject(value)
inject(data)
(products / 'NotoLive.xctestrun').write_bytes(plistlib.dumps(data))
PY
xcodebuild test-without-building -xctestrun "$derived_dir/Build/Products/NotoLive.xctestrun" \
  -destination "$destination" \
  -only-testing:NotoIOSUITests/NotoIOSUITests/testLiveAccountSyncAndIsolation
