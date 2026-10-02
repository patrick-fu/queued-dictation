#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "Usage: Scripts/build-app.sh [debug|release]" >&2
  exit 2
fi
swift build -c "$configuration" --arch arm64
binary_directory="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
app_path="$PWD/dist/Queued Dictation.app"
mkdir -p "$app_path/Contents/MacOS"
cp "$binary_directory/QueuedDictation" "$app_path/Contents/MacOS/QueuedDictation"
cp App/Info.plist "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
printf '%s\n' "$app_path"
