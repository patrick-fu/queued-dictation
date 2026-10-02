#!/bin/bash
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
if [[ $# -gt 2 ]]; then
  echo 'Usage: Scripts/check-release-tools.sh [development-app-path [development-zip-path]]' >&2
  exit 2
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/queued-dictation-release-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
if [[ $# -eq 0 ]]; then
  bash Scripts/build-app.sh release "$scratch/build"
  app_path="$scratch/build/Queued Dictation.app"
else
  app_path="$1"
fi
zip_path="${2:-$scratch/development.zip}"
if [[ $# -lt 2 ]]; then
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
fi
/usr/bin/ditto -x -k "$zip_path" "$scratch/extracted"
extracted_app="$scratch/extracted/Queued Dictation.app"
[[ -x "$extracted_app/Contents/MacOS/QueuedDictation" ]]
[[ "$(/usr/bin/lipo -archs "$extracted_app/Contents/MacOS/QueuedDictation")" == arm64 ]]
/usr/bin/codesign --verify --deep --strict --verbose=2 "$extracted_app"
/usr/bin/cmp "$app_path/Contents/MacOS/QueuedDictation" "$extracted_app/Contents/MacOS/QueuedDictation"
/usr/bin/cmp "$app_path/Contents/Resources/LICENSE.txt" "$extracted_app/Contents/Resources/LICENSE.txt"
echo 'PASS: development ZIP preserves the executable and valid arm64 App signature.'
bash Scripts/verify-app.sh development "$extracted_app"
if bash Scripts/verify-app.sh signed "$extracted_app" > "$scratch/adhoc-rejection.log" 2>&1; then
  echo 'FAIL: an ad-hoc development App was accepted as a Developer ID release.' >&2
  exit 1
fi
/usr/bin/grep -q 'Developer ID' "$scratch/adhoc-rejection.log"
/usr/bin/grep -Fq 'code failed to satisfy specified code requirement(s)' "$scratch/adhoc-rejection.log"
echo 'PASS: an ad-hoc development App cannot pass the release signature check.'
/usr/bin/ditto "$extracted_app" "$scratch/modified/Queued Dictation.app"
printf '\nmodified notice\n' >> "$scratch/modified/Queued Dictation.app/Contents/Resources/LICENSE.txt"
if bash Scripts/verify-app.sh development "$scratch/modified/Queued Dictation.app" > "$scratch/modification-rejection.log" 2>&1; then
  echo 'FAIL: modifying a sealed App resource was not detected.' >&2
  exit 1
fi
echo 'PASS: a modified sealed resource is rejected.'
/usr/bin/ditto "$extracted_app" "$scratch/no-execute/Queued Dictation.app"
chmod -x "$scratch/no-execute/Queued Dictation.app/Contents/MacOS/QueuedDictation"
if bash Scripts/verify-app.sh development "$scratch/no-execute/Queued Dictation.app" > "$scratch/permission-rejection.log" 2>&1; then
  echo 'FAIL: an App without an executable launch binary was accepted.' >&2
  exit 1
fi
echo 'PASS: losing executable permissions is rejected.'
for line_break in $'\n' $'\r'; do
  line_break_app="$scratch/path${line_break}break/Queued Dictation.app"
  /usr/bin/ditto "$extracted_app" "$line_break_app"
  if bash Scripts/verify-app.sh development "$line_break_app" > "$scratch/path-rejection.log" 2>&1; then
    echo 'FAIL: an App path containing a line break was accepted.' >&2
    exit 1
  fi
  /usr/bin/grep -q 'App path must not contain LF or CR' "$scratch/path-rejection.log"
done
echo 'PASS: App paths containing LF or CR are rejected.'
if bash Scripts/release-app.sh sign --identity - --output "$scratch/invalid-identity" > "$scratch/identity-rejection.log" 2>&1; then
  echo 'FAIL: release signing accepted an ad-hoc identity.' >&2
  exit 1
fi
/usr/bin/grep -q 'Developer ID Application identity' "$scratch/identity-rejection.log"
[[ ! -e "$scratch/invalid-identity" ]]
if bash Scripts/release-app.sh notarize --identity unused --output "$scratch/missing-profile" > "$scratch/profile-rejection.log" 2>&1; then
  echo 'FAIL: notarization accepted missing profile configuration.' >&2
  exit 1
fi
/usr/bin/grep -q 'profile name is required' "$scratch/profile-rejection.log"
[[ ! -e "$scratch/missing-profile" ]]
mkdir "$scratch/existing-output"
printf 'keep\n' > "$scratch/existing-output/sentinel"
if bash Scripts/release-app.sh sign --identity unused --output "$scratch/existing-output" > "$scratch/output-rejection.log" 2>&1; then
  echo 'FAIL: release signing accepted an existing output directory.' >&2
  exit 1
fi
[[ "$(cat "$scratch/existing-output/sentinel")" == keep ]]
echo 'PASS: unsafe release preconditions fail before creating or replacing output.'
