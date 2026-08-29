#!/bin/bash
set -euo pipefail

# Elderly AI Assistant — iOS build script.
#
# Uses XcodeGen to generate ElderlyAssistant.xcodeproj from project.yml so the
# project file is not hand-maintained. Any change to sources or targets goes
# through project.yml → regenerate → build.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ElderlyAssistant"
SCHEME="${APP_NAME}"
BUILD_DIR="${PROJECT_DIR}/build"
DERIVED_DATA="${IOS_DERIVED_DATA:-${BUILD_DIR}/DerivedData}"
TEST_DERIVED_DATA="${IOS_TEST_DERIVED_DATA:-${BUILD_DIR}/DerivedDataTests}"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
IPA_DIR="${BUILD_DIR}/ipa"
EXPORT_PLIST="${PROJECT_DIR}/ExportOptions.plist"

echo "=== Elderly AI Assistant — iOS build ==="
echo "Project: ${PROJECT_DIR}"

check_prereqs() {
    echo ""
    echo "[1/4] Checking prerequisites..."

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

generate_project() {
    echo ""
    echo "[2/4] Generating Xcode project from project.yml..."
    cd "${PROJECT_DIR}"
    xcodegen generate --spec project.yml --project .
    echo "  ✓ ${APP_NAME}.xcodeproj regenerated"
}

build_app() {
    echo ""
    echo "[3/4] Building ${APP_NAME}..."

    # If DEVELOPMENT_TEAM is set, produce a signed build for a real device.
    # Otherwise skip signing so a bare `./build.sh` still verifies the code
    # compiles — useful in CI and for reviewers without a Team ID.
    local signing_args
    if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
        signing_args=(
            CODE_SIGN_STYLE=Automatic
            DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}"
        )
    else
        echo "  (no DEVELOPMENT_TEAM set — building unsigned, compile-check only)"
        signing_args=(
            CODE_SIGNING_ALLOWED=NO
            CODE_SIGNING_REQUIRED=NO
            CODE_SIGN_IDENTITY=""
        )
    fi

    xcodebuild clean build \
        -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
        -scheme "${SCHEME}" \
        -destination "generic/platform=iOS" \
        -configuration Release \
        -derivedDataPath "${DERIVED_DATA}" \
        -allowProvisioningUpdates \
        -skipMacroValidation \
        -skipPackagePluginValidation \
        "${signing_args[@]}" \
        | tail -20

    echo "  ✓ Build complete"
}

create_ipa() {
    echo ""
    echo "[4/4] Creating IPA..."

    cat > "${EXPORT_PLIST}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>development</string>
    <key>teamID</key><string></string>
    <key>compileBitcode</key><false/>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

    xcodebuild archive \
        -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
        -scheme "${SCHEME}" \
        -archivePath "${ARCHIVE_PATH}" \
        -destination "generic/platform=iOS" \
        -configuration Release \
        -derivedDataPath "${DERIVED_DATA}" \
        -allowProvisioningUpdates \
        | tail -10

    xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${IPA_DIR}" \
        -exportOptionsPlist "${EXPORT_PLIST}" \
        -allowProvisioningUpdates \
        | tail -10

    echo "  ✓ IPA at: ${IPA_DIR}/${APP_NAME}.ipa"
}

run_tests() {
    echo ""
    echo "[3/4] Running unit tests..."
    local destination="${IOS_TEST_DESTINATION:-}"
    if [ -z "${destination}" ]; then
        local simulator_id
        simulator_id="$(xcrun simctl list devices available -j | ruby -rjson -e '
          devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
          phone = devices.find { |d| d["isAvailable"] && d["name"].start_with?("iPhone") }
          abort("No available iPhone simulator found") unless phone
          puts phone["udid"]
        ')"
        destination="platform=iOS Simulator,id=${simulator_id}"
    fi
    echo "  destination: ${destination}"
    xcodebuild test \
        -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
        -scheme "${SCHEME}" \
        -destination "${destination}" \
        -derivedDataPath "${TEST_DERIVED_DATA}" \
        | tail -30
    echo "  ✓ Tests passed"
}

case "${1:-build}" in
    build)
        check_prereqs
        generate_project
        build_app
        echo ""
        echo "=== Build complete ==="
        ;;
    ipa)
        check_prereqs
        generate_project
        build_app
        create_ipa
        echo ""
        echo "=== IPA ready ==="
        ;;
    test)
        check_prereqs
        generate_project
        run_tests
        ;;
    generate)
        check_prereqs
        generate_project
        ;;
    *)
        echo "Usage: $0 {build|ipa|test|generate}"
        exit 1
        ;;
esac
