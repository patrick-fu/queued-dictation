#!/bin/bash
set -euo pipefail
export LC_ALL=C
if [[ $# -ne 2 || ( "$1" != development && "$1" != signed && "$1" != notarized ) ]]; then
  echo 'Usage: Scripts/verify-app.sh development|signed|notarized app-path' >&2
  exit 2
fi
mode="$1"
app_path="$2"
fail() { echo "App verification failed: $*" >&2; exit 1; }
[[ -d "$app_path" ]] || fail 'App bundle is missing.'
app_path="$(cd "$app_path" && pwd -P)"
info="$app_path/Contents/Info.plist"
binary="$app_path/Contents/MacOS/QueuedDictation"
[[ -x "$binary" ]] || fail 'App executable is missing or not executable.'
[[ -f "$app_path/Contents/Resources/LICENSE.txt" ]] || fail 'Bundled license notice is missing.'
/usr/bin/plutil -lint "$info" >/dev/null
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info")" == io.github.patrick-fu.queued-dictation ]] || fail 'Unexpected bundle identifier.'
[[ "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info")" == QueuedDictation ]] || fail 'Unexpected bundle executable.'
[[ "$(/usr/bin/plutil -extract CFBundlePackageType raw -o - "$info")" == APPL ]] || fail 'Unexpected bundle type.'
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$info")" == 14.0 ]] || fail 'Bundle must declare macOS 14.0.'
[[ -n "$(/usr/bin/plutil -extract NSMicrophoneUsageDescription raw -o - "$info")" ]] || fail 'Microphone usage description is missing.'
[[ "$(/usr/bin/lipo -archs "$binary")" == arm64 ]] || fail 'App must contain only the supported arm64 architecture.'
build_info="$(/usr/bin/xcrun vtool -show-build "$binary")"
[[ "$(printf '%s\n' "$build_info" | /usr/bin/awk '$1 == "platform" { print $2 }')" == MACOS ]] || fail 'Executable is not a macOS build.'
[[ "$(printf '%s\n' "$build_info" | /usr/bin/awk '$1 == "minos" { print $2 }')" == 14.0 ]] || fail 'Executable must target macOS 14.0.'
printf '%s\n' "$build_info"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
metadata="$(/usr/bin/codesign --display --verbose=4 "$app_path" 2>&1)"
printf '%s\n' "$metadata"
if [[ "$mode" != development ]]; then
  # This requirement checks certificate type and Apple trust, not the displayed name.
  developer_id_requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
  /usr/bin/codesign --verify --strict -R="$developer_id_requirement" "$app_path" || fail 'A valid Developer ID Application signature is required.'
  flags="$(printf '%s\n' "$metadata" | /usr/bin/sed -n 's/^CodeDirectory .*flags=.*(\([^)]*\)).*/\1/p')"
  case ",$flags," in
    *,runtime,*) ;;
    *) fail 'Hardened runtime is required.' ;;
  esac
  printf '%s\n' "$metadata" | /usr/bin/grep -q '^Timestamp=' || fail 'A secure signing timestamp is required.'
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/queued-dictation-signature-check.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  /usr/bin/codesign --display --entitlements - --xml "$app_path" > "$scratch/entitlements.plist"
  entitlements="$(/usr/bin/plutil -convert json -o - "$scratch/entitlements.plist")"
  [[ "$entitlements" == '{"com.apple.security.device.audio-input":true}' ]] || fail 'Release must have exactly the audio-input entitlement.'
  printf 'Entitlements=%s\n' "$entitlements"
fi
if [[ "$mode" == notarized ]]; then
  /usr/bin/xcrun stapler validate "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
fi
printf 'PASS: %s App artifact verification.\n' "$mode"
