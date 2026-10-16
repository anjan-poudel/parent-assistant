#!/bin/bash
set -euo pipefail

# Elderly AI Assistant — TestFlight beta packaging script.
#
# Builds and packages the app for beta testing via the App Store (TestFlight):
# archive → export with the App Store Connect distribution method → optionally
# validate and upload the .ipa to App Store Connect. Distinct from
# `./build.sh ipa`, whose export method is `development` (ad-hoc device
# installs) — the two pipelines must not share export options.
#
# Modes:
#   package   Full pipeline: release gates → project generate → build-number
#             bump → archive → app-store-connect export. Leaves the .ipa,
#             the .xcarchive and the ExportOptions.plist it used in one
#             per-build folder under ios/build/beta/<version>-<build>/
#             (build/ is gitignored). Does NOT upload — run validate then
#             upload, or `release`, when the build looks right.
#   bump      Bump CFBundleVersion in ElderlyAssistant/Info.plist only, then
#             exit. Use it standalone when you want to land the bump commit
#             separately (package bumps by default too).
#   validate  Run App Store Connect validation on the .ipa (altool
#             --validate-app). Requires ASC credentials.
#   upload    Upload the .ipa to App Store Connect. Once processed it appears
#             under TestFlight. Requires ASC credentials.
#   release   package + validate + upload in one run.
#   dry-run   Print the resolved configuration and the commands each mode
#             would run, without executing anything.
#   help      Show this help.
#
# Build numbers: every TestFlight upload for a version must carry a build
# number higher than the previous upload for that version. `package` bumps
# CFBundleVersion in the hand-maintained Info.plist (+1 by default, or
# BETA_BUILD_NUMBER to pin an exact number). That file IS tracked — commit
# the bump (the script only edits the working tree). The marketing version
# (CFBundleShortVersionString) is a human decision and is never touched;
# edit Info.plist by hand when a beta cycle starts a new version. The widget
# extension's Info.plist is XcodeGen-generated (TimerAlarmWidget/Info.plist
# from project.yml) and regenerates on every `generate` — its short version
# (1.0) must keep matching the app's; if the app's short version ever moves,
# set the extension's CFBundleShortVersionString in project.yml alongside it.
#
# App Store Connect credentials (needed for validate/upload/release and for
# dSYM upload during export). One of:
#   API key (preferred):  ASC_KEY_PATH=<path to AuthKey_*.p8>
#                         ASC_ISSUER_ID=<Issuer ID from App Store Connect>
#                         ASC_KEY_ID=<Key ID> (optional — derived from the
#                         .p8 filename, "AuthKey_XXXXXXXXXX.p8" → XXXXXXXX).
#   Apple ID:             ASC_USERNAME=<Apple ID>
#                         plus either ASC_KEYCHAIN_ITEM=<keychain item name>
#                         (the password was stored with
#                          `xcrun altool --store-password-in-keychain-item`)
#                         or ASC_PASSWORD=<app-specific password> in the
#                         environment (avoid — prefer the keychain).
# With an API key the export also authenticates with it
# (-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID)
# and uploads dSYMs to App Store Connect (uploadSymbols=true) so TestFlight
# crash reports symbolicate. Without one, uploadSymbols=false and the export
# works but dSYMs must be uploaded later (Xcode Organizer → Distribute App).
#
# Release gates: the constitution's Release-build log-safety gate
# (tools/check-release-log-safety.sh) runs before every package — a
# re-introduced transcript/error print blocks the build, not just the
# report. The full test gates (./build.sh test) stay the merge/nightly
# responsibility; packaging does not re-run tests.
#
# Environment:
#   DEVELOPMENT_TEAM       Signing team id (default: BKXWPS4X87 — the team
#                          project.yml pins; see the comment there).
#   IOS_DERIVED_DATA       DerivedData path (default: build/DerivedData,
#                          the same warm cache ./build.sh uses).
#   BETA_BUILD_NUMBER      Pin the build number instead of auto-bumping.
#   BETA_NO_BUMP=1         Skip the CFBundleVersion bump entirely.
#   BETA_IPA               Override the .ipa path for validate/upload.
#   ASC_KEY_PATH           App Store Connect API key (.p8).
#   ASC_ISSUER_ID          API key issuer id.
#   ASC_KEY_ID             API key id (derived from the .p8 name if unset).
#   ASC_USERNAME           Apple ID (alternative to the API key).
#   ASC_KEYCHAIN_ITEM      Keychain item holding the app-specific password.
#   ASC_PASSWORD           App-specific password (discouraged — use keychain).

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="seniOS"
SCHEME="ElderlyAssistant"
BUILD_DIR="${PROJECT_DIR}/build"
BETA_DIR="${BUILD_DIR}/beta"
DERIVED_DATA="${IOS_DERIVED_DATA:-${BUILD_DIR}/DerivedData}"
# The team whose Apple ID is signed into Xcode on this machine — matches the
# DEVELOPMENT_TEAM pinned in project.yml (see the comment there).
TEAM_ID="${DEVELOPMENT_TEAM:-BKXWPS4X87}"
INFO_PLIST="${PROJECT_DIR}/ElderlyAssistant/Info.plist"

# Gitignored model resources the archive must bundle (project.yml declares
# them under ElderlyAssistant/Resources/Models/). A fresh clone/worktree does
# not carry them — they are fetched, not committed.
MODEL_RESOURCES=(
    "ElderlyAssistant/Resources/Models/whisper-medium-ne-q5_1.bin"
    "ElderlyAssistant/Resources/Models/tts"
    "ElderlyAssistant/Resources/Models/kws"
)

usage() {
    cat <<'EOF'
Usage: $0 {package|bump|validate|upload|release|dry-run|help}

  package    Release gates → generate → bump build number → archive →
             export App Store Connect .ipa into
             build/beta/<version>-<build>/ (no upload).
  bump       Bump CFBundleVersion in ElderlyAssistant/Info.plist only.
  validate   altool --validate-app on the latest (or BETA_IPA) .ipa.
  upload     altool --upload-app — the build shows up in TestFlight after
             App Store Connect processing.
  release    package + validate + upload in one run.
  dry-run    Print resolved configuration and the commands each mode would
             run, without executing anything.
  help       Show this help.

Credentials (validate/upload/release need one of):
  API key:    ASC_KEY_PATH=<AuthKey_*.p8> ASC_ISSUER_ID=<issuer id>
              [ASC_KEY_ID=<key id>]
  Apple ID:   ASC_USERNAME=<apple id> and
              ASC_KEYCHAIN_ITEM=<item>  (password stored in keychain via
              `xcrun altool --store-password-in-keychain-item`) or
              ASC_PASSWORD=<app-specific password> (avoid)

Examples:
  cd ios
  ./beta.sh package                    # bump + build + export (no upload)
  ./beta.sh validate                   # then, when it looks right:
  ./beta.sh upload                     # or:
  ./beta.sh release                    # all three in one run
  BETA_BUILD_NUMBER=7 ./beta.sh package      # pin the build number
  BETA_NO_BUMP=1 ./beta.sh package           # reuse the committed number
  BETA_IPA=build/beta/1.0-7/ElderlyAssistant.ipa ./beta.sh upload
EOF
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "${INFO_PLIST}"
}

check_prereqs() {
    echo ""
    echo "Checking prerequisites..."

    if ! command -v xcodebuild &> /dev/null; then
        echo "ERROR: xcodebuild not found. Install Xcode from the Mac App Store."
        exit 1
    fi
    echo "  ✓ $(xcodebuild -version | head -1)"

    if ! command -v xcodegen &> /dev/null; then
        echo "ERROR: xcodegen not found. Install with: brew install xcodegen"
        exit 1
    fi
    echo "  ✓ xcodegen $(xcodegen --version 2>/dev/null | head -1 || echo installed)"
}

# check_model_resources — the archive must carry the gitignored model
# resources; a fresh checkout lacks them and would archive a silently
# crippled build (no bundled STT/TTS/KWS). Fail with fetch instructions.
check_model_resources() {
    echo ""
    echo "Checking bundled model resources..."
    local missing=0 rel
    for rel in "${MODEL_RESOURCES[@]}"; do
        if [ ! -e "${PROJECT_DIR}/${rel}" ]; then
            echo "  ✗ missing: ${rel}"
            missing=1
        else
            echo "  ✓ ${rel}"
        fi
    done
    if [ "${missing}" = "1" ]; then
        cat <<'EOF'
ERROR: bundled model resources are missing. These are gitignored — fetch them
before packaging:
  tools/fetch-tts-voices.sh     (tts/)
  tools/fetch-kws-model.sh      (kws/)
  whisper-medium-ne-q5_1.bin    (re-fetch from the models release v3 — see
                                 project.yml)
EOF
        exit 1
    fi
}

# run_release_gate — the constitution's Release-build log-surface gate
# (B1/T-049, recorded 2026-09-13). Build-blocking: a raw transcript print or
# raw error-body print aborts packaging.
run_release_gate() {
    echo ""
    echo "Release log-safety gate..."
    "${PROJECT_DIR}/tools/check-release-log-safety.sh" || {
        echo "ERROR: Release-log privacy gate failed — see above." >&2
        exit 1
    }
    echo "  ✓ log-safety gate passed"
}

# bump_build_number — CFBundleVersion +1 (or BETA_BUILD_NUMBER). Prints the
# resulting number. Info.plist is hand-maintained (project.yml deliberately
# has no `info:` block) so editing it here is safe across `generate` runs;
# the edit stays uncommitted for the operator to land with the release.
#
# The edit is a targeted perl replacement of just the CFBundleVersion value,
# NOT PlistBuddy: PlistBuddy re-serializes the file (reorders keys, strips
# the curated comment blocks like the GIDClientID one) — a one-value bump
# must not rewrite the hand-maintained plist.
bump_build_number() {
    local current next
    current="$(plist_value CFBundleVersion)"
    if [ -n "${BETA_BUILD_NUMBER:-}" ]; then
        if [[ ! "${BETA_BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: BETA_BUILD_NUMBER must be a positive integer (got '${BETA_BUILD_NUMBER}')" >&2
            exit 1
        fi
        next="${BETA_BUILD_NUMBER}"
    else
        next=$((current + 1))
    fi
    echo "  bump: CFBundleVersion ${current} → ${next}"
    if [ "${next}" -le "${current}" ]; then
        echo "ERROR: new build number ${next} must be greater than the previous upload's ${current}" >&2
        exit 1
    fi
    # ${1}/${2} brace-delimited in the replacement: unbraced, "$199$2"
    # parses as group 199 — empty — which silently eats the value.
    perl -0pi -e "s{(<key>CFBundleVersion</key>\s*<string>)[0-9]+(</string>)}{\${1}${next}\${2}}" "${INFO_PLIST}"
    # perl edits in place even on a non-match — verify the value actually
    # changed rather than trusting the exit status.
    if [ "$(plist_value CFBundleVersion)" != "${next}" ]; then
        echo "ERROR: CFBundleVersion edit did not land (plist layout changed?) — ${INFO_PLIST} left as-is or partially edited; check git diff" >&2
        exit 1
    fi
    echo "  (Info.plist is tracked — commit this bump with the release)"
}

# resolve_auth — echoes the altool/xcodebuild credential flags for the
# configured App Store Connect identity. Exits with instructions if neither
# an API key nor an Apple ID is configured.
resolve_auth() {
    if [ -n "${ASC_KEY_PATH:-}" ]; then
        if [ ! -f "${ASC_KEY_PATH}" ]; then
            echo "ERROR: ASC_KEY_PATH does not exist: ${ASC_KEY_PATH}" >&2
            exit 1
        fi
        if [ -z "${ASC_ISSUER_ID:-}" ]; then
            echo "ERROR: ASC_ISSUER_ID is required with ASC_KEY_PATH (App Store Connect → Users and Access → Keys)" >&2
            exit 1
        fi
        echo "--apiKey ${ASC_KEY_PATH} --apiIssuer ${ASC_ISSUER_ID}"
        return
    fi
    if [ -n "${ASC_USERNAME:-}" ]; then
        local password_ref
        if [ -n "${ASC_KEYCHAIN_ITEM:-}" ]; then
            password_ref="@keychain:${ASC_KEYCHAIN_ITEM}"
        elif [ -n "${ASC_PASSWORD:-}" ]; then
            echo "  (warning: ASC_PASSWORD in the environment — prefer the keychain)" >&2
            password_ref="${ASC_PASSWORD}"
        else
            cat <<'EOF' >&2
ERROR: ASC_USERNAME set but no password source. Store the app-specific
password in the keychain once:
  xcrun altool --store-password-in-keychain-item "ASC-beta" -u "$ASC_USERNAME"
then re-run with ASC_KEYCHAIN_ITEM="ASC-beta".
EOF
            exit 1
        fi
        echo "-u ${ASC_USERNAME} -p ${password_ref}"
        return
    fi
    cat <<'EOF' >&2
ERROR: no App Store Connect credentials. Configure one of:
  API key:    ASC_KEY_PATH=<AuthKey_*.p8> ASC_ISSUER_ID=<issuer id>
              (App Store Connect → Users and Access → Integrations → Keys)
  Apple ID:   ASC_USERNAME=<apple id> ASC_KEYCHAIN_ITEM=<keychain item>
              (password stored via `xcrun altool --store-password-in-keychain-item`)
EOF
    exit 1
}

# xcodebuild_auth_flags — the -authenticationKey* flags for xcodebuild when
# an API key is configured ("" otherwise). Used by archive/export so the
# export phase can authenticate for provisioning and dSYM upload.
xcodebuild_auth_flags() {
    if [ -n "${ASC_KEY_PATH:-}" ]; then
        local key_id="${ASC_KEY_ID:-}"
        if [ -z "${key_id}" ]; then
            # AuthKey_XXXXXXXXXX.p8 → XXXXXXXX. Deriving it like altool does
            # keeps one source of truth in the file name.
            key_id="$(basename "${ASC_KEY_PATH}" .p8)"
            key_id="${key_id#AuthKey_}"
        fi
        echo "-authenticationKeyPath ${ASC_KEY_PATH} -authenticationKeyID ${key_id} -authenticationKeyIssuerID ${ASC_ISSUER_ID}"
    else
        echo ""
    fi
}

# write_export_plist <dir> <upload-symbols> — the App Store Connect export
# options for this build. Automatic signing + team id mirrors the rest of
# the project; uploadSymbols is on only when an API key authenticates the
# export (see the header).
write_export_plist() {
    local dir="$1" upload_symbols="$2"
    local plist="${dir}/ExportOptions.plist"
    cat > "${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>compileBitcode</key><false/>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><${upload_symbols}/>
</dict>
</plist>
PLIST
    echo "  ✓ export options: ${plist} (uploadSymbols=${upload_symbols})"
}

# package — the full pipeline up to (not including) the upload.
package() {
    check_prereqs
    run_release_gate
    check_model_resources

    echo ""
    echo "Generating Xcode project from project.yml (./build.sh generate)..."
    "${PROJECT_DIR}/build.sh" generate

    echo ""
    echo "Build number..."
    if [ "${BETA_NO_BUMP:-0}" = "1" ]; then
        echo "  BETA_NO_BUMP=1 — keeping the committed CFBundleVersion"
    else
        bump_build_number
    fi
    local version build
    version="$(plist_value CFBundleShortVersionString)"
    build="$(plist_value CFBundleVersion)"
    echo "  identity: ${version} (${build})"

    local out_dir="${BETA_DIR}/${version}-${build}"
    mkdir -p "${out_dir}"

    local auth_flags upload_symbols
    if [ -n "${ASC_KEY_PATH:-}" ]; then
        # Validate the API key path/issuer up front — a bad key must fail
        # with a clear message before the archive, not inside xcodebuild.
        resolve_auth > /dev/null
        upload_symbols="true"
        auth_flags="$(xcodebuild_auth_flags)"
    else
        upload_symbols="false"
        echo "  (no API key — dSYMs will not upload during export; see header)"
    fi
    write_export_plist "${out_dir}" "${upload_symbols}"

    echo ""
    echo "Archiving (Release, automatic signing, team ${TEAM_ID})..."
    # shellcheck disable=SC2086
    xcodebuild archive \
        -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
        -scheme "${SCHEME}" \
        -archivePath "${out_dir}/${APP_NAME}.xcarchive" \
        -destination "generic/platform=iOS" \
        -configuration Release \
        -derivedDataPath "${DERIVED_DATA}" \
        -allowProvisioningUpdates \
        -skipMacroValidation \
        -skipPackagePluginValidation \
        ${auth_flags} \
        | tail -10

    echo ""
    echo "Exporting App Store Connect .ipa..."
    # shellcheck disable=SC2086
    xcodebuild -exportArchive \
        -archivePath "${out_dir}/${APP_NAME}.xcarchive" \
        -exportPath "${out_dir}" \
        -exportOptionsPlist "${out_dir}/ExportOptions.plist" \
        -allowProvisioningUpdates \
        ${auth_flags} \
        | tail -10

    echo ""
    echo "=== Beta package ready ==="
    echo "  IPA:     ${out_dir}/${APP_NAME}.ipa"
    echo "  Archive: ${out_dir}/${APP_NAME}.xcarchive"
    echo ""
    echo "Next steps:"
    echo "  ./beta.sh validate    # App Store Connect validation"
    echo "  ./beta.sh upload      # upload to TestFlight"
    echo "  ./beta.sh release     # or validate + upload now"
}

# resolve_ipa — BETA_IPA if set, else the most recent per-build folder's
# .ipa, else exit with an error.
resolve_ipa() {
    local ipa
    if [ -n "${BETA_IPA:-}" ]; then
        ipa="${BETA_IPA}"
    else
        ipa="$(ls -t "${BETA_DIR}"/*/"${APP_NAME}".ipa 2>/dev/null | head -1 || true)"
        if [ -z "${ipa}" ]; then
            echo "ERROR: no .ipa under ${BETA_DIR}/ — run './beta.sh package' first" >&2
            exit 1
        fi
    fi
    if [ ! -f "${ipa}" ]; then
        echo "ERROR: .ipa not found: ${ipa}" >&2
        exit 1
    fi
    echo "${ipa}"
}

check_altool() {
    # xcrun --find, not command -v: altool is inside Xcode's Developer dir
    # and only xcrun resolves it (there is no standalone copy on PATH).
    if ! xcrun --find altool &> /dev/null; then
        cat <<'EOF' >&2
ERROR: altool not found. It still ships with current Xcode but is deprecated —
fallbacks: drag the .ipa into the Transporter app, or use Xcode → Organizer →
Distribute App.
EOF
        exit 1
    fi
}

validate() {
    check_altool
    local ipa auth_flags
    ipa="$(resolve_ipa)"
    auth_flags="$(resolve_auth)"
    echo ""
    echo "Validating ${ipa} with App Store Connect..."
    # shellcheck disable=SC2086
    xcrun altool --validate-app -f "${ipa}" -t ios ${auth_flags}
}

upload() {
    check_altool
    local ipa auth_flags
    ipa="$(resolve_ipa)"
    auth_flags="$(resolve_auth)"
    echo ""
    echo "Uploading ${ipa} to App Store Connect (TestFlight)..."
    # shellcheck disable=SC2086
    xcrun altool --upload-app -f "${ipa}" -t ios ${auth_flags}
    echo ""
    echo "=== Upload complete ==="
    echo "The build appears under TestFlight after App Store Connect processing."
}

# dry_run — print the resolved configuration and commands without executing.
dry_run() {
    echo ""
    echo "Resolved configuration:"
    echo "  project:            ${PROJECT_DIR}"
    echo "  scheme:             ${SCHEME}"
    echo "  team:               ${TEAM_ID}"
    echo "  derived data:       ${DERIVED_DATA}"
    echo "  version (plist):    $(plist_value CFBundleShortVersionString)"
    echo "  build (plist):      $(plist_value CFBundleVersion)"
    if [ "${BETA_NO_BUMP:-0}" = "1" ]; then
        echo "  bump:               skipped (BETA_NO_BUMP=1)"
    elif [ -n "${BETA_BUILD_NUMBER:-}" ]; then
        echo "  bump:               → ${BETA_BUILD_NUMBER} (pinned)"
    else
        echo "  bump:               → $(( $(plist_value CFBundleVersion) + 1 )) (auto)"
    fi
    if [ -n "${ASC_KEY_PATH:-}" ]; then
        echo "  auth:               API key ${ASC_KEY_PATH} (issuer ${ASC_ISSUER_ID:-<unset>})"
    elif [ -n "${ASC_USERNAME:-}" ]; then
        echo "  auth:               Apple ID ${ASC_USERNAME} (${ASC_KEYCHAIN_ITEM:-password from env})"
    else
        echo "  auth:               <unset — validate/upload/release will refuse>"
    fi
    echo "  artifact dir:       ${BETA_DIR}/$(plist_value CFBundleShortVersionString)-<build>"
    echo "  xcodebuild auth:    $(xcodebuild_auth_flags || true)"
    echo ""
    echo "Command plan:"
    echo "  1. ${PROJECT_DIR}/build.sh generate"
    echo "  2. tools/check-release-log-safety.sh (release gate)"
    echo "  3. bump CFBundleVersion (unless BETA_NO_BUMP)"
    echo "  4. xcodebuild archive    → build/beta/<version>-<build>/seniOS.xcarchive"
    echo "  5. xcodebuild -exportArchive (method: app-store-connect)"
    echo "  6. [release only] altool --validate-app → --upload-app"
    echo ""
    echo "Nothing executed."
}

case "${1:-package}" in
    package)
        package
        ;;
    bump)
        check_prereqs
        echo ""
        echo "Build number..."
        bump_build_number
        echo "  ✓ CFBundleVersion now $(plist_value CFBundleVersion)"
        ;;
    validate)
        validate
        ;;
    upload)
        upload
        ;;
    release)
        package
        validate
        upload
        ;;
    dry-run)
        dry_run
        ;;
    help|-h|--help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown command: ${1}" >&2
        echo ""
        usage
        exit 1
        ;;
esac
