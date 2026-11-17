#!/bin/sh
set -eu
cd "$(dirname "$0")"

swift build "$@"
bin=$(swift build "$@" --show-bin-path)
app=.build/paint.mac.app
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
cp "$bin/Paint" "$app/Contents/MacOS/Paint"
codesign --force --sign - "$app"
echo "$app"
