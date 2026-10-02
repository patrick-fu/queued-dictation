#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ $# -gt 2 || ( "$configuration" != "debug" && "$configuration" != "release" ) ]]; then
  echo "Usage: Scripts/build-app.sh [debug|release] [output-directory]" >&2
  exit 2
fi
output_directory="${2:-$PWD/dist}"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd -P)"
app_path="$output_directory/Queued Dictation.app"
if [[ $# -eq 2 && ( -e "$app_path" || -L "$app_path" ) ]]; then
  echo 'The custom output already contains an App; choose a new directory.' >&2
  exit 2
fi
swift build -c "$configuration" --arch arm64 --jobs 2
binary_directory="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_directory/QueuedDictation" "$app_path/Contents/MacOS/QueuedDictation"
cp App/Info.plist "$app_path/Contents/Info.plist"
cp LICENSE "$app_path/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
printf '%s\n' "$app_path"
