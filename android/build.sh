#!/bin/bash
set -euo pipefail

# Elderly AI Assistant — Android Build Script
# Builds the Android APK for device installation.
# Requires: Android SDK, Gradle (wrapped), JDK 17+

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ElderlyAssistant"
APK_OUTPUT="${PROJECT_DIR}/app/build/outputs/apk"

echo "=== Elderly AI Assistant — Android Build ==="
echo "Project: ${PROJECT_DIR}"

check_prereqs() {
    echo ""
    echo "[1/5] Checking prerequisites..."

    # Check Java
    if ! command -v java &> /dev/null; then
        echo "ERROR: Java not found. Install JDK 17+: brew install openjdk@17"
        exit 1
    fi
    echo "  ✓ Java: $(java -version 2>&1 | head -1)"

    # Check Android SDK
    ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
    if [ ! -d "${ANDROID_SDK}" ]; then
        echo ""
        echo "ERROR: Android SDK not found at ${ANDROID_SDK}"
        echo "Install Android Studio: https://developer.android.com/studio"
        echo "Or set ANDROID_HOME environment variable."
        exit 1
    fi
    echo "  ✓ Android SDK: ${ANDROID_SDK}"

    # Check Gradle wrapper
    if [ ! -f "${PROJECT_DIR}/gradlew" ]; then
        echo "  Generating Gradle wrapper..."
        cd "${PROJECT_DIR}"
        gradle wrapper --gradle-version 8.5
    fi
    echo "  ✓ Gradle wrapper ready"
}

build_debug() {
    echo ""
    echo "[2/5] Building debug APK..."

    cd "${PROJECT_DIR}"
    ./gradlew assembleDebug 2>&1 | tail -15

    local apk="${APK_OUTPUT}/debug/app-debug.apk"
    if [ -f "${apk}" ]; then
        echo "  ✓ Debug APK built: ${apk}"
        ls -lh "${apk}"
    else
        echo "  ERROR: APK not found. Check build output above."
        exit 1
    fi
}

build_release() {
    echo ""
    echo "[2/5] Building release APK..."

    cd "${PROJECT_DIR}"
    ./gradlew assembleRelease 2>&1 | tail -15

    local apk="${APK_OUTPUT}/release/app-release-unsigned.apk"
    if [ -f "${apk}" ]; then
        echo "  ✓ Release APK built: ${apk}"
        ls -lh "${apk}"
        echo ""
        echo "  NOTE: APK is unsigned. Sign with:"
        echo "  apksigner sign --ks your-keystore.jks ${apk}"
    else
        echo "  ERROR: APK not found. Check build output above."
        exit 1
    fi
}

install_device() {
    echo ""
    echo "[3/5] Installing on connected device..."

    # Check for connected device
    local devices=$("${ANDROID_SDK}/platform-tools/adb" devices 2>/dev/null | grep -v "List" | grep "device$" | wc -l)
    if [ "${devices}" -eq 0 ]; then
        echo "  ERROR: No Android device connected."
        echo "  Connect your phone via USB and enable USB Debugging."
        echo "  Settings → Developer Options → USB Debugging → ON"
        exit 1
    fi

    local apk="${APK_OUTPUT}/debug/app-debug.apk"
    "${ANDROID_SDK}/platform-tools/adb" install -r "${apk}"
    echo "  ✓ Installed on device"
}

run_tests() {
    echo ""
    echo "[4/5] Running unit tests..."

    cd "${PROJECT_DIR}"
    ./gradlew test 2>&1 | tail -15

    echo "  ✓ Tests passed"
}

lint_check() {
    echo ""
    echo "[5/5] Running lint..."

    cd "${PROJECT_DIR}"
    ./gradlew lint 2>&1 | tail -10

    echo "  ✓ Lint complete"
}

# Main execution
case "${1:-build}" in
    build)
        check_prereqs
        build_debug
        echo ""
        echo "=== Build complete ==="
        echo "APK: ${APK_OUTPUT}/debug/app-debug.apk"
        echo "Install: $0 install"
        ;;
    release)
        check_prereqs
        build_release
        echo ""
        echo "=== Release build complete ==="
        ;;
    install)
        check_prereqs
        build_debug
        install_device
        echo ""
        echo "=== App installed ==="
        echo "Find 'Elderly Assistant' on your phone's home screen."
        ;;
    test)
        check_prereqs
        run_tests
        lint_check
        ;;
    *)
        echo "Usage: $0 {build|release|install|test}"
        echo ""
        echo "  build     Build debug APK (default)"
        echo "  release   Build release APK (unsigned)"
        echo "  install   Build and install on connected device"
        echo "  test      Run unit tests and lint"
        exit 1
        ;;
esac
