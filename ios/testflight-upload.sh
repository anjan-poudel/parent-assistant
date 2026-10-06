#!/usr/bin/env bash
set -euo pipefail

# Elderly AI Assistant (seniOS) — build, archive, and upload to App Store
# Connect for TestFlight distribution, without opening Xcode.
#
# Adapted from the ai-coaching-assistant testflight-upload.sh. This project
# is a native SwiftUI app (XcodeGen project.yml → seniOS.xcodeproj, SPM deps,
# no CocoaPods), so: xcodegen regenerates the project first, and the build
# number is bumped in ElderlyAssistant/Info.plist (hardcoded CFBundleVersion).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/seniOS.xcodeproj"
APP_INFO_PLIST="$SCRIPT_DIR/ElderlyAssistant/Info.plist"
SCHEME="ElderlyAssistant"
APP_NAME="seniOS"
DEFAULT_TEAM_ID="BKXWPS4X87"

TEAM_ID="${DEVELOPMENT_TEAM:-$DEFAULT_TEAM_ID}"

# Optional local credentials (gitignored): APPSTORE_API_KEY_ID,
# APPSTORE_API_ISSUER_ID, APPSTORE_API_KEY_PATH
if [[ -f "$SCRIPT_DIR/.testflight.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.testflight.env"
fi

# Ensure the dedicated signing keychain holds the Apple Distribution identity
# and is first in the search list. Idempotent; uses assets under
# ~/.testflight-signing/ (created once by the App Store Connect API flow).
ensure_signing_keychain() {
  local kc="$HOME/Library/Keychains/testflight-signing.keychain-db"
  local pw_file="$HOME/.testflight-signing-pw"
  local p12="$HOME/.testflight-signing/distribution.p12"
  [[ -f "$p12" ]] || return 0
  [[ -f "$pw_file" ]] || fail "Signing keychain password file missing: $pw_file"
  local pw
  pw="$(cat "$pw_file")"
  # Unlock before probing: a locked keychain makes show-keychain-info fail
  # ("User canceled the operation") in non-interactive shells, which sent us
  # down the create path — and create on an existing keychain exits 48,
  # aborting the run after the archive was already built.
  security unlock-keychain -p "$pw" "$kc" >/dev/null 2>&1 || true
  if ! security show-keychain-info "$kc" >/dev/null 2>&1; then
    security create-keychain -p "$pw" "$kc" >/dev/null 2>&1 || true
    security set-keychain-settings -lut 21600 "$kc" >/dev/null 2>&1 || true
    security unlock-keychain -p "$pw" "$kc" >/dev/null 2>&1 || true
  fi
  if ! security find-identity -v -p codesigning "$kc" 2>/dev/null | grep -q "Apple Distribution"; then
    security import "$p12" -P temporary -k "$kc" -T /usr/bin/codesign >/dev/null 2>&1
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" >/dev/null 2>&1
  fi
  security list-keychains -d user -s "$kc" "$HOME/Library/Keychains/login.keychain-db" >/dev/null
}
# Separate from build.sh's warm build/DerivedData so concurrent runs never
# fight over the same Xcode build database.
DERIVED_DATA="${IOS_APPSTORE_DERIVED_DATA:-$SCRIPT_DIR/build/DerivedDataAppStore}"
ARCHIVE_PATH="$DERIVED_DATA/$APP_NAME.xcarchive"
EXPORT_DIR="$SCRIPT_DIR/build/testflight-export"
LOG_FILE="$SCRIPT_DIR/build/testflight-upload.log"
LOCK_DIR="$SCRIPT_DIR/build/testflight-upload.lock"

BUMP_BUILD=1
BUILD_NUMBER=""
CLEAN_BUILD=0
EXPORT_ONLY=0
ADD_ENCRYPTION_KEY=0

usage() {
  cat <<'USAGE'
Build, archive, and upload ElderlyAssistant (seniOS) to App Store Connect
for TestFlight distribution — without opening Xcode.

Usage:
  ./ios/testflight-upload.sh [options]

Options:
  --team <team-id>            Apple Developer Team ID (default: BKXWPS4X87).
  --no-bump                   Keep CFBundleVersion unchanged.
  --build-number <n>          Set CFBundleVersion in Info.plist to <n> instead
                              of auto-incrementing. TestFlight requires a
                              unique build number for every upload.
  --clean                     Remove this script's DerivedData path first.
  --export-only               Export the IPA but do not upload it.
  --add-encryption-key        Add ITSAppUsesNonExemptEncryption=NO to
                              Info.plist (avoids the App Store compliance
                              questionnaire; use only if the app uses no
                              non-exempt encryption).
  -h, --help                  Show this help.

Environment alternatives:
  DEVELOPMENT_TEAM, IOS_APPSTORE_DERIVED_DATA

App Store Connect authentication (optional; defaults to the Apple ID added
under Xcode > Settings > Accounts):
  APPSTORE_API_KEY_ID         App Store Connect API key ID (10-char key name).
  APPSTORE_API_ISSUER_ID      App Store Connect issuer ID (UUID).
  APPSTORE_API_KEY_PATH       Path to the API key .p8 file.

Requirements:
  - An Apple ID with App Store Connect access under Xcode > Settings > Accounts
    (or the APPSTORE_API_* environment variables)
  - An App Store Connect app registered for bundle ID
    ai.voicebridge.senior.assistant
  - XcodeGen on PATH (the Xcode project is generated from project.yml)
USAGE
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || fail "$option requires a value."
}

# Print an error summary from the build log and exit 1.
fail_after_build() {
  local stage="$1"
  printf '\n%s failed. Full log: %s\n' "$stage" "$LOG_FILE" >&2
  printf 'Relevant error lines:\n' >&2
  grep -E "(^|[ :])error:|fatal error|The following build commands failed|Code Signing Error|Provisioning profile|No profiles for|Authentication|Failed to Use Accounts" \
    "$LOG_FILE" | tail -40 >&2 || true
  if grep -q "Failed to Use Accounts" "$LOG_FILE"; then
    printf '\nHint: no usable Apple ID is signed into Xcode (Xcode > Settings > Accounts),\n' >&2
    printf 'or set APPSTORE_API_KEY_ID / APPSTORE_API_ISSUER_ID / APPSTORE_API_KEY_PATH\n' >&2
    printf 'to an App Store Connect API key.\n' >&2
  fi
  exit 1
}

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

# Serialize runs: two invocations sharing the same DerivedData corrupt each
# other's build database ("database is locked" mid-build). mkdir is atomic.
acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [[ -f "$LOCK_DIR/pid" ]] && ! kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      printf 'Removing stale lock left by dead process %s.\n' "$(cat "$LOCK_DIR/pid")"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" || return 1
    else
      return 1
    fi
  fi
  echo $$ > "$LOCK_DIR/pid"
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

while (( $# > 0 )); do
  case "$1" in
    --team)
      require_value "$1" "${2:-}"
      TEAM_ID="$2"
      shift 2
      ;;
    --no-bump)
      BUMP_BUILD=0
      shift
      ;;
    --build-number)
      require_value "$1" "${2:-}"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
    --export-only)
      EXPORT_ONLY=1
      shift
      ;;
    --add-encryption-key)
      ADD_ENCRYPTION_KEY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -z "$BUILD_NUMBER" || "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || \
  fail "--build-number must be a positive integer."
[[ -d "$PROJECT" ]] || fail "Xcode project not found: $PROJECT"
[[ -f "$APP_INFO_PLIST" ]] || fail "Info.plist not found: $APP_INFO_PLIST"

for tool in xcodebuild xcrun plutil xcodegen; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done

mkdir -p "$SCRIPT_DIR/build"
acquire_lock || fail "Another testflight-upload.sh run is in progress (lock: $LOCK_DIR)."

: > "$LOG_FILE"
exec 2> >(tee -a "$LOG_FILE" >&2)

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/senios-testflight.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"; release_lock' EXIT
EXPORT_OPTIONS="$TEMP_DIR/ExportOptions.plist"

log "== testflight-upload: $(date '+%Y-%m-%d %H:%M:%S') =="
log "Project: $PROJECT"
log "Team:    $TEAM_ID"

# project.yml is the source of truth; regenerate so the archive matches it.
printf 'Regenerating Xcode project from project.yml…\n'
(
  cd "$SCRIPT_DIR"
  xcodegen generate
) 2>&1 | tee -a "$LOG_FILE" || fail_after_build "xcodegen generate"

printf 'Verifying scheme %s…\n' "$SCHEME"
if ! xcodebuild -project "$PROJECT" -list 2>&1 | grep -q "^\s*$SCHEME$"; then
  fail "Scheme '$SCHEME' not found in project. Shared schemes: see Xcode > Manage Schemes."
fi

# TestFlight requires a unique build number per upload; bump it by default.
if [[ "$BUMP_BUILD" == 1 ]]; then
  OLD_BUILD="$(plutil -extract CFBundleVersion raw "$APP_INFO_PLIST")"
  if [[ -n "$BUILD_NUMBER" ]]; then
    NEW_BUILD="$BUILD_NUMBER"
  else
    NEW_BUILD="$((OLD_BUILD + 1))"
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$APP_INFO_PLIST"
  printf 'Build number: %s -> %s (Info.plist).\n' "$OLD_BUILD" "$NEW_BUILD"
fi

if [[ "$ADD_ENCRYPTION_KEY" == 1 ]]; then
  if plutil -extract ITSAppUsesNonExemptEncryption raw "$APP_INFO_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :ITSAppUsesNonExemptEncryption NO" "$APP_INFO_PLIST"
  else
    /usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool NO" "$APP_INFO_PLIST"
  fi
  printf 'ITSAppUsesNonExemptEncryption set to NO in Info.plist.\n'
elif ! plutil -extract ITSAppUsesNonExemptEncryption raw "$APP_INFO_PLIST" >/dev/null 2>&1; then
  printf 'Warning: ITSAppUsesNonExemptEncryption is not set in Info.plist.\n' >&2
  printf '         App Store Connect will ask the encryption compliance question\n' >&2
  printf '         for each build. Re-run with --add-encryption-key if the app\n' >&2
  printf '         uses no non-exempt encryption.\n' >&2
fi

if [[ "$CLEAN_BUILD" == 1 ]]; then
  printf 'Cleaning build directory: %s\n' "$DERIVED_DATA"
  rm -rf "$DERIVED_DATA" "$EXPORT_DIR"
fi

# Fail fast: keychain/signing problems should surface before the long
# archive, not after it.
ensure_signing_keychain

printf 'Archiving %s (this takes several minutes)…\n' "$SCHEME"
rm -rf "$ARCHIVE_PATH"
if ! xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  2>&1 | tee -a "$LOG_FILE"; then
  fail_after_build "Archive"
fi
printf 'Archive created: %s\n' "$ARCHIVE_PATH"

# ExportOptions: "app-store-connect" with destination "upload" signs,
# exports, and uploads in one step. Uses the Apple ID signed into Xcode —
# or an App Store Connect API key when the env vars are provided.
if [[ "$EXPORT_ONLY" == 1 ]]; then
  DESTINATION="export"
  printf 'Exporting IPA (upload skipped)…\n'
else
  DESTINATION="upload"
  printf 'Exporting and uploading to App Store Connect…\n'
fi
METHOD="app-store-connect"

cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$METHOD</string>
    <key>destination</key>
    <string>$DESTINATION</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>ai.voicebridge.senior.assistant</key>
        <string>Senior AppStore</string>
        <key>ai.voicebridge.senior.assistant.TimerAlarmWidget</key>
        <string>Senior Widget AppStore</string>
    </dict>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF

# Never empty: macOS bash 3.2 raises "unbound variable" for "${arr[@]}" on an
# empty array under set -u, silently aborting the command (export would never
# run while the script still reported success).
EXPORT_ARGS=(-allowProvisioningUpdates)
if [[ -n "${APPSTORE_API_KEY_ID:-}" && -n "${APPSTORE_API_ISSUER_ID:-}" && -n "${APPSTORE_API_KEY_PATH:-}" ]]; then
  EXPORT_ARGS+=(
    -authenticationKeyID "$APPSTORE_API_KEY_ID"
    -authenticationKeyIssuerID "$APPSTORE_API_ISSUER_ID"
    -authenticationKeyPath "$APPSTORE_API_KEY_PATH"
  )
fi

# Capture to a file, not a variable: `VAR="$(cmd)"` under set -e exits the
# script at the assignment on failure, swallowing the error output entirely.
rm -rf "$EXPORT_DIR"
EXPORT_LOG="$TEMP_DIR/export.log"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  "${EXPORT_ARGS[@]}" > "$EXPORT_LOG" 2>&1
EXPORT_STATUS=$?
set -e
tee -a "$LOG_FILE" < "$EXPORT_LOG"
[[ $EXPORT_STATUS -eq 0 ]] || fail_after_build "Export"
if [[ "$EXPORT_ONLY" != 1 ]] && ! grep -qiE "uploaded package is processing|successfully uploaded|uploaded to app store connect|^Uploaded " "$EXPORT_LOG"; then
  fail "Export finished but no upload confirmation appeared in its output. Nothing was uploaded. Full log: $LOG_FILE"
fi

printf '\nDone.\n'
if [[ "$EXPORT_ONLY" == 1 ]]; then
  printf 'IPA: %s/seniOS.ipa\n' "$EXPORT_DIR"
  printf 'Upload manually: run this script without --export-only.\n'
else
  printf 'Build uploaded to App Store Connect. Next steps:\n'
  printf '  1. Wait ~10-30 min for processing (TestFlight tab in App Store Connect).\n'
  printf '  2. Internal testers get the build once internal testing is enabled.\n'
  printf '  3. External groups: select the build under TestFlight > Builds.\n'
  printf '  4. Commit the bumped CFBundleVersion in ElderlyAssistant/Info.plist.\n'
fi
