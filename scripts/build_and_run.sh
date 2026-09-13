#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="$PWD/build/Noto.app"
# Only stop this checkout's app, never another installed/preview Noto instance.
pkill -f "^${app}/Contents/MacOS/Noto( |$)" 2>/dev/null || true
zsh scripts/build.sh
/usr/bin/open -n "$app" --args "$@"
