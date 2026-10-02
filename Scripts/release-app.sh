#!/bin/bash
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
usage() {
  cat >&2 <<'USAGE'
Usage:
  Scripts/release-app.sh sign --identity NAME_OR_SHA1 --output NEW_DIRECTORY
  Scripts/release-app.sh notarize --identity NAME_OR_SHA1 --notary-profile NAME --output NEW_DIRECTORY

sign builds and verifies a Developer ID App without submitting or making a release ZIP.
notarize uploads to Apple, waits for Accepted, staples and verifies, then makes a release ZIP.
Credentials must already be available in Keychain. Passwords and private keys are not arguments.
USAGE
}
fail() { echo "Release failed: $*" >&2; exit 1; }
[[ $# -gt 0 ]] || { usage; exit 2; }
mode="$1"
shift
[[ "$mode" == sign || "$mode" == notarize ]] || { usage; exit 2; }
identity=''
output_directory=''
notary_profile=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { usage; exit 2; }
  case "$1" in
    --identity) identity="$2" ;;
    --output) output_directory="$2" ;;
    --notary-profile) notary_profile="$2" ;;
    *) usage; exit 2 ;;
  esac
  shift 2
done
[[ -n "$identity" && -n "$output_directory" ]] || { usage; exit 2; }
if [[ "$mode" == notarize ]]; then
  [[ -n "$notary_profile" ]] || fail 'An explicit notary Keychain profile name is required.'
else
  [[ -z "$notary_profile" ]] || fail 'The sign command does not use a notary profile.'
fi
[[ ! -e "$output_directory" && ! -L "$output_directory" ]] || fail 'Output already exists; choose a new directory.'
signing_hash=''
signing_name=''
team_id=''
identity_pattern='^[[:space:]]*[[:digit:]]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Developer ID Application: .+ \(([[:alnum:]]{10})\))"[[:space:]]*$'
identities="$(/usr/bin/security find-identity -v -p codesigning)"
while IFS= read -r line; do
  if [[ "$line" =~ $identity_pattern ]]; then
    candidate_hash="${BASH_REMATCH[1]}"
    candidate_name="${BASH_REMATCH[2]}"
    candidate_team="${BASH_REMATCH[3]}"
    if [[ "$identity" == "$candidate_name" || "$(printf '%s' "$identity" | /usr/bin/tr '[:lower:]' '[:upper:]')" == "$candidate_hash" ]]; then
      [[ -z "$signing_hash" ]] || fail 'Signing identity is ambiguous; use its SHA-1 fingerprint.'
      signing_hash="$candidate_hash"
      signing_name="$candidate_name"
      team_id="$candidate_team"
    fi
  fi
done <<< "$identities"
[[ -n "$signing_hash" ]] || fail 'The explicit identity must resolve to a valid Developer ID Application identity.'
source_commit="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain)" ]] || fail 'Source worktree must be clean so the artifact can be traced to a commit.'
if [[ "$mode" == notarize ]]; then
  /usr/bin/xcrun --find notarytool >/dev/null
  /usr/bin/xcrun --find stapler >/dev/null
fi
umask 077
mkdir -p "$(dirname "$output_directory")"
mkdir "$output_directory"
output_directory="$(cd "$output_directory" && pwd -P)"
work="$output_directory/.work"
evidence="$output_directory/evidence"
mkdir "$work" "$evidence"
stage='build'
record_failure() {
  local result="$1"
  if [[ "$result" -ne 0 ]]; then
    printf 'result=failed\nstage=%s\nexit_code=%s\n' "$stage" "$result" > "$evidence/result.txt"
    printf 'Release stopped at %s. Evidence: %s\n' "$stage" "$evidence" >&2
  fi
}
trap 'record_failure "$?"' EXIT
{
  printf 'source_commit=%s\nmode=%s\nsigning_identity=%s\nsigning_sha1=%s\nteam_id=%s\n' "$source_commit" "$mode" "$signing_name" "$signing_hash" "$team_id"
  /usr/bin/sw_vers
  /usr/bin/uname -m
  swift --version
  /usr/bin/xcodebuild -version
} > "$evidence/build-environment.txt" 2>&1
echo 'Building an isolated release App.' >&2
(umask 022; bash Scripts/build-app.sh release "$work") > "$evidence/build.log" 2>&1
app_path="$work/Queued Dictation.app"
stage='Developer ID signing'
echo 'Signing with Developer ID and hardened runtime.' >&2
/usr/bin/codesign --force --sign "$signing_hash" --options runtime --timestamp --entitlements App/Release.entitlements "$app_path" > "$evidence/signing.log" 2>&1
stage='signature verification'
bash Scripts/verify-app.sh signed "$app_path" > "$evidence/signature-check.log" 2>&1
/usr/bin/codesign --verify -R="certificate leaf[subject.OU] = \"$team_id\"" "$app_path" >> "$evidence/signature-check.log" 2>&1
(cd "$app_path/Contents/MacOS" && /usr/bin/shasum -a 256 QueuedDictation) > "$evidence/executable.sha256"
if [[ "$mode" == notarize ]]; then
  stage='notary submission'
  echo 'Submitting the signed ZIP to Apple and waiting for Accepted.' >&2
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$work/notary-submission.zip"
  /usr/bin/shasum -a 256 "$work/notary-submission.zip" > "$evidence/notary-submission.sha256"
  /usr/bin/xcrun notarytool submit "$work/notary-submission.zip" --keychain-profile "$notary_profile" --wait --timeout 20m --output-format json > "$evidence/notary-submit.json" 2> "$evidence/notary-submit.log"
  notary_status="$(/usr/bin/plutil -extract status raw -o - "$evidence/notary-submit.json")"
  [[ "$notary_status" == Accepted ]] || fail 'Notarization was not Accepted; no release package will be produced.'
  submission_id="$(/usr/bin/plutil -extract id raw -o - "$evidence/notary-submit.json")"
  [[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'Notary response has no valid submission identifier.'
  stage='notary log retrieval'
  /usr/bin/xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" "$evidence/notary-log.json" > "$evidence/notary-log-command.log" 2>&1
  [[ "$(/usr/bin/plutil -extract status raw -o - "$evidence/notary-log.json")" == Accepted ]] || fail 'Notary log does not confirm Accepted.'
  stage='stapling'
  /usr/bin/xcrun stapler staple "$app_path" > "$evidence/staple.log" 2>&1
  stage='notarized App verification'
  bash Scripts/verify-app.sh notarized "$app_path" > "$evidence/notarized-check.log" 2>&1
  version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")"
  [[ "$version" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]] || fail 'App version cannot be used safely as an artifact name.'
  package_name="Queued-Dictation-$version-macOS-arm64.zip"
  stage='ZIP verification'
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$work/$package_name"
  /usr/bin/ditto -x -k "$work/$package_name" "$work/extracted"
  bash Scripts/verify-app.sh notarized "$work/extracted/Queued Dictation.app" > "$evidence/extracted-check.log" 2>&1
  /usr/bin/cmp "$app_path/Contents/MacOS/QueuedDictation" "$work/extracted/Queued Dictation.app/Contents/MacOS/QueuedDictation"
fi
stage='source consistency check'
case "$output_directory" in
  "$PWD"/*) source_status="$(git status --porcelain -- . ":(exclude)${output_directory#"$PWD"/}")" ;;
  *) source_status="$(git status --porcelain)" ;;
esac
[[ "$(git rev-parse HEAD)" == "$source_commit" && -z "$source_status" ]] || fail 'Source changed during packaging; the artifact is not ready for release.'
mv "$app_path" "$output_directory/Queued Dictation.app"
if [[ "$mode" == notarize ]]; then
  mv "$work/$package_name" "$output_directory/$package_name"
  (cd "$output_directory" && /usr/bin/shasum -a 256 "$package_name") > "$evidence/package.sha256"
  printf 'result=verified_package\nsource_commit=%s\nnotarization=Accepted\nsubmission_id=%s\npackage=%s\n' "$source_commit" "$submission_id" "$package_name" > "$evidence/result.txt"
  echo "Verified notarized package: $output_directory/$package_name"
  echo "Review Apple's log before publishing: $evidence/notary-log.json"
else
  printf 'result=verified_signature\nsource_commit=%s\nnotarization=not_submitted\n' "$source_commit" > "$evidence/result.txt"
  echo "Verified Developer ID App (notarization not submitted): $output_directory/Queued Dictation.app"
fi
rm -rf "$work"
