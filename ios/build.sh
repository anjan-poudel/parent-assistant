#!/bin/bash
set -euo pipefail

# Elderly AI Assistant — iOS build script.
#
# Uses XcodeGen to generate ElderlyAssistant.xcodeproj from project.yml so the
# project file is not hand-maintained. Any change to sources or targets goes
# through project.yml → regenerate → build.
#
# Modes:
#   build       Compile-check the app (unsigned unless DEVELOPMENT_TEAM is
#               set). Reuses a canonical warm DerivedData — no clean — so
#               repeat runs are incremental. For a from-scratch build, delete
#               IOS_DERIVED_DATA yourself (there is no build-clean mode).
#   ipa         build + archive + export an .ipa.
#   test        FULL test gate: unit AND UI tests (for merges/nightly).
#   test:unit   Fast gate: unit tests only (skips the UI suite).
#   test:ui     UI tests only.
#   test:impact IMPACT-AWARE unit gate: diffs the working tree against the
#               last recorded green baseline (ios/build/.last-tested-sha) and
#               runs only the test classes whose source areas changed, plus
#               the always-on safety net (MedicationSchedulerTests,
#               VoiceSessionStateMachineTests, DesignTokensTests). Falls back
#               to the full unit gate when the mapping is ambiguous or more
#               than 40% of suites are affected. The baseline is advanced
#               ONLY after a run that covered the full unit gate, so a green
#               impact run never silently skips later work.
#   test-clean  FULL test gate after wiping the warm test DerivedData —
#               rare (new simulator runtime, suspect build cache).
#   generate    Regenerate the Xcode project from project.yml only.
#
# Impact mapping convention: the test tree mirrors the source tree
# (ElderlyAssistantTests/Services/<Area>/ ↔ ElderlyAssistant/Services/<Area>/,
# ElderlyAssistantTests/App/ ↔ ElderlyAssistant/App/). A change under a
# source area runs every XCTest suite declared in the mirroring test area
# (+ the safety net). Changes to test files run that suite. Anything that
# does not map cleanly (Resources, project.yml, areas without tests, helper
# files, …) is treated as ambiguous → full unit gate.
#
# Test runs reuse a canonical warm DerivedData (build/DerivedDataTests) so
# repeat cycles are incremental — minutes, not the ~20 min cold package
# compile (WhisperKit/sherpa-onnx) of a fresh directory. `test` and `test:ui`
# enable parallel testing; set IOS_TEST_CLONES=N to fan the UI suite out over
# N simulator clones. The default is serial so nothing boots extra
# simulators unless you ask for it.
#
# Environment:
#   DEVELOPMENT_TEAM       Codesigning team id (default: unsigned build).
#   IOS_DERIVED_DATA       Build DerivedData path  (default: build/DerivedData).
#   IOS_TEST_DERIVED_DATA  Test DerivedData path   (default: build/DerivedDataTests).
#   IOS_TEST_DESTINATION   xcodebuild -destination for tests (default: first
#                          available iPhone simulator).
#   IOS_TEST_CLONES        N>0: -parallel-testing-worker-count N for UI runs.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="seniOS"
SCHEME="ElderlyAssistant"
BUILD_DIR="${PROJECT_DIR}/build"
DERIVED_DATA="${IOS_DERIVED_DATA:-${BUILD_DIR}/DerivedData}"
TEST_DERIVED_DATA="${IOS_TEST_DERIVED_DATA:-${BUILD_DIR}/DerivedDataTests}"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
IPA_DIR="${BUILD_DIR}/ipa"
EXPORT_PLIST="${PROJECT_DIR}/ExportOptions.plist"
REPO_ROOT="$(git -C "${PROJECT_DIR}" rev-parse --show-toplevel)"
LAST_TESTED_FILE="${BUILD_DIR}/.last-tested-sha"

# Always-on safety net for test:impact — the pinned core tests. These run
# regardless of which source areas changed.
SAFETY_NET_CLASSES="MedicationSchedulerTests VoiceSessionStateMachineTests DesignTokensTests"

# Impact mapping: >40% of all unit suites affected → run the full gate.
IMPACT_FULL_THRESHOLD_PCT=40

echo "=== Elderly AI Assistant — iOS build ==="
echo "Project:           ${PROJECT_DIR}"
echo "Build DerivedData: ${DERIVED_DATA}  (warm — no clean)"
echo "Test DerivedData:  ${TEST_DERIVED_DATA}  (warm — no clean)"

usage() {
    cat <<'EOF'
Usage: $0 {build|ipa|test|test:unit|test:ui|test:impact|test-clean|generate|help}

  build       Compile-check (unsigned unless DEVELOPMENT_TEAM set).
              Incremental on build/DerivedData — no clean.
  ipa         build + archive + export an .ipa.
  test        Full gate: unit + UI tests (merge/nightly). Warm DerivedData.
  test:unit   Fast: unit tests only (skips ElderlyAssistantUITests).
  test:ui     UI tests only, parallel-testing enabled.
  test:impact Impact-aware unit gate: only suites whose source areas changed
              since the last recorded green run (ios/build/.last-tested-sha),
              always plus the safety net (MedicationSchedulerTests,
              VoiceSessionStateMachineTests, DesignTokensTests). Falls back
              to the full unit gate when mapping is ambiguous or >40% of
              suites are affected. Baseline advances only after a full-coverage
              green run.
  test-clean  Full gate after wiping the warm test DerivedData (rare).
  generate    Re-run XcodeGen on project.yml.
  help        Show this help.

Test runs reuse build/DerivedDataTests so repeat cycles are incremental
(~minutes). UI runs parallelize only when IOS_TEST_CLONES=N is set (N>0 →
-parallel-testing-worker-count N; default serial = no simulator clones).

Environment:
  DEVELOPMENT_TEAM       Codesigning team id (default: unsigned build).
  IOS_DERIVED_DATA       Build DerivedData path (default: build/DerivedData).
  IOS_TEST_DERIVED_DATA  Test DerivedData path  (default: build/DerivedDataTests).
  IOS_TEST_DESTINATION   xcodebuild -destination for tests (default: first
                         available iPhone simulator).
  IOS_TEST_CLONES        N>0: parallel UI-testing worker count.

Examples:
  cd ios
  ./build.sh test:unit            # fast local check (minutes on warm dir)
  ./build.sh test:impact          # only suites hit by your edits + safety net
  ./build.sh test                 # full gate incl. UI tests
  IOS_TEST_CLONES=2 ./build.sh test:ui   # UI suite split over 2 sim clones
  IOS_TEST_DERIVED_DATA=/tmp/dd ./build.sh test-clean
EOF
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

generate_project() {
    echo ""
    echo "Generating Xcode project from project.yml..."
    cd "${PROJECT_DIR}"
    xcodegen generate --spec project.yml --project .
    echo "  ✓ ${APP_NAME}.xcodeproj regenerated"
}

build_app() {
    echo ""
    echo "Building ${APP_NAME} (incremental — warm DerivedData, no clean)..."

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

    xcodebuild build \
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
    echo "Creating IPA..."

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

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# unit_suite_classes <tests-dir> — prints the XCTest suite class names declared
# in the *.swift files directly under <tests-dir>. Only files whose basename
# ends in "Tests" AND declare `class <basename>` count (helper files like
# IntentTestHelpers.swift are skipped even though they end in "s").
unit_suite_classes() {
    local dir="$1" f name
    [ -d "${dir}" ] || return 0
    for f in "${dir}"/*.swift; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .swift)"
        case "${name}" in *Tests) ;; *) continue ;; esac
        grep -qE "(^|[^A-Za-z0-9_])class ${name} *:" "$f" 2>/dev/null || continue
        echo "${name}"
    done
}

# unit_suite_classes_recursive <root> — like above but descends (for App/).
unit_suite_classes_recursive() {
    local root="$1" f name
    [ -d "${root}" ] || return 0
    while IFS= read -r f; do
        name="$(basename "$f" .swift)"
        case "${name}" in *Tests) ;; *) continue ;; esac
        grep -qE "(^|[^A-Za-z0-9_])class ${name} *:" "$f" 2>/dev/null || continue
        echo "${name}"
    done < <(find "${root}" -name "*.swift" -type f)
}

# changed_paths_since <baseline-sha> — repo-root-relative paths under ios/
# that differ from the baseline (committed AND uncommitted, plus untracked
# non-ignored files).
changed_paths_since() {
    local baseline="$1"
    git -C "${REPO_ROOT}" diff --name-only "${baseline}" -- ios/
    git -C "${REPO_ROOT}" ls-files --others --exclude-standard -- ios/
}

# impact_class_for_test_file <ios-relative-path> — a changed test file maps to
# its own declared suite class, or "" if it is a helper file.
impact_class_for_test_file() {
    local rel="$1" name
    case "${rel}" in
        ElderlyAssistantTests/*.swift) ;;
        *) echo ""; return ;;
    esac
    name="$(basename "${rel}" .swift)"
    case "${name}" in *Tests) ;; *) echo ""; return ;; esac
    grep -qE "(^|[^A-Za-z0-9_])class ${name} *:" "${PROJECT_DIR}/${rel}" 2>/dev/null \
        && echo "${name}" || echo ""
}

# impact_suites_for_path <ios-relative-path> — prints the impact verdict for a
# single changed path:
#   IGNORE                  generated/noise (build/, .xcodeproj/, outside ios/)
#   AMBIGUOUS               cannot be mapped safely → caller runs the full gate
#   SELF:<Class>            a test file declaring its own suite
#   DIR:<tests-dir>         every suite in the mirroring area directory
#   DIRTREE:<tests-root>    every suite recursively under the mirroring root
impact_suites_for_path() {
    local rel="$1"
    case "${rel}" in
        ios/*) ;;
        *) echo "IGNORE"; return ;;
    esac
    rel="${rel#ios/}"
    case "${rel}" in
        build/*|ElderlyAssistant.xcodeproj/*) echo "IGNORE"; return ;;
    esac
    case "${rel}" in
        ElderlyAssistantTests/*)
            local cls
            cls="$(impact_class_for_test_file "${rel}")"
            if [ -n "${cls}" ]; then echo "SELF:${cls}"; else echo "AMBIGUOUS"; fi
            return
            ;;
        ElderlyAssistantUITests/*)
            echo "AMBIGUOUS"   # UI-suite change is outside the unit gate's reach
            return
            ;;
        ElderlyAssistant/Services/*)
            local area
            area="${rel#ElderlyAssistant/Services/}"
            case "${area}" in */*) ;; *) echo "AMBIGUOUS"; return ;; esac   # file at area root
            area="${area%%/*}"
            if [ -d "${PROJECT_DIR}/ElderlyAssistantTests/Services/${area}" ]; then
                echo "DIR:${PROJECT_DIR}/ElderlyAssistantTests/Services/${area}"
            else
                echo "AMBIGUOUS"   # source area with no mirroring test area
            fi
            return
            ;;
        ElderlyAssistant/App/*)
            if [ -d "${PROJECT_DIR}/ElderlyAssistantTests/App" ]; then
                echo "DIRTREE:${PROJECT_DIR}/ElderlyAssistantTests/App"
            else
                echo "AMBIGUOUS"
            fi
            return
            ;;
        ElderlyAssistant/*)
            echo "AMBIGUOUS"   # Resources/, root-level sources, Info.plist…
            return
            ;;
        *)
            echo "IGNORE"      # build.sh, docs, android/, …
            return
            ;;
    esac
}

# compute_impact_suites <baseline-sha> — echoes one of:
#   FULL                     mapping ambiguous or over threshold → full gate
#   NONE                     no impacted paths → safety net only
#   <space-separated class names>  suites to run (caller adds safety net)
compute_impact_suites() {
    local baseline="$1" verdict rel suites="" ambiguous=0 changed_count=0
    local total mapped threshold

    while IFS= read -r rel; do
        [ -n "${rel}" ] || continue
        changed_count=$((changed_count + 1))
        verdict="$(impact_suites_for_path "${rel}")"
        case "${verdict}" in
            IGNORE) ;;
            AMBIGUOUS)
                ambiguous=1
                echo "  impact: unmapped path → full unit gate: ${rel}" >&2
                ;;
            SELF:*)
                suites="${suites} ${verdict#SELF:}"
                ;;
            DIR:*|DIRTREE:*)
                if [ "${verdict#DIRTREE:}" != "${verdict}" ]; then
                    suites="${suites} $(unit_suite_classes_recursive "${verdict#DIRTREE:}")"
                else
                    suites="${suites} $(unit_suite_classes "${verdict#DIR:}")"
                fi
                ;;
        esac
    done < <(changed_paths_since "${baseline}" | sort -u)

    echo "  impact: baseline ${baseline} → working tree: ${changed_count} changed path(s)" >&2

    suites="$(echo ${suites} | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"

    if [ "${ambiguous}" = "1" ]; then
        echo "FULL"
        return
    fi
    if [ -z "${suites}" ]; then
        echo "NONE"
        return
    fi

    total="$(unit_suite_classes_recursive "${PROJECT_DIR}/ElderlyAssistantTests" | wc -l | tr -d ' ')"
    mapped="$(echo ${suites} | wc -w | tr -d ' ')"
    threshold=$(( total * IMPACT_FULL_THRESHOLD_PCT / 100 ))
    if [ "${mapped}" -gt "${threshold}" ]; then
        echo "  impact: ${mapped}/${total} suites affected (>${IMPACT_FULL_THRESHOLD_PCT}%) → full unit gate" >&2
        echo "FULL"
        return
    fi
    echo "  impact: running ${mapped} mapped suite(s) (+3 safety net) of ${total}: ${suites}" >&2
    echo "${suites}"
}

# run_tests <unit|ui|full> [extra test classes…]
#   unit — unit tests only  (-skip-testing:ElderlyAssistantUITests); extra
#          classes become -only-testing:ElderlyAssistantTests/<Class> entries
#   ui   — UI tests only    (-only-testing:ElderlyAssistantUITests)
#   full — unit + UI tests  (scheme default)
# UI runs get -parallel-testing-enabled YES; IOS_TEST_CLONES=N adds
# -parallel-testing-worker-count N. (xcodebuild has no `-parallelizable`
# CLI flag — that is a scheme TestAction attribute for Xcode's own UI —
# so parallelism is driven purely by the flags below.)
run_tests() {
    local scope="${1:-full}"
    shift || true
    local label extra only_count=$#
    local -a only_classes=("$@")
    local -a testing_args=()
    case "${scope}" in
        unit) label="unit tests"
              testing_args=(-skip-testing:ElderlyAssistantUITests) ;;
        ui)   label="UI tests"
              testing_args=(-only-testing:ElderlyAssistantUITests) ;;
        full) label="unit + UI tests" ;;
        *)    echo "internal error: unknown test scope '${scope}'" >&2; exit 2 ;;
    esac
    if [ "${only_count}" -gt 0 ]; then
        for extra in "${only_classes[@]}"; do
            testing_args+=(-only-testing:ElderlyAssistantTests/"${extra}")
        done
        echo "  only-testing: ${only_count} class(es): ${only_classes[*]}"
    fi

    echo ""
    echo "Running ${label}..."
    if [ "${scope}" != "unit" ]; then
        # Parallel UI testing. Default stays serial (safe on busy machines);
        # IOS_TEST_CLONES=N fans the suite out over N simulator clones.
        testing_args+=(-parallel-testing-enabled YES)
        if [ -n "${IOS_TEST_CLONES:-}" ]; then
            testing_args+=(-parallel-testing-worker-count "${IOS_TEST_CLONES}")
            echo "  parallel testing: ${IOS_TEST_CLONES} workers (IOS_TEST_CLONES)"
        fi
    fi
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
        "${testing_args[@]}" \
        | tail -40

    echo "  ✓ ${label} passed"
}

# record_green <sha> — persist the baseline of a full-coverage green run so
# the next test:impact diff starts from here.
record_green() {
    mkdir -p "${BUILD_DIR}"
    echo "$1" > "${LAST_TESTED_FILE}"
    echo "  ✓ recorded green baseline: $1"
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
        run_tests full
        echo ""
        echo "=== Full test gate passed ==="
        record_green "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        ;;
    test:unit)
        check_prereqs
        generate_project
        run_tests unit
        echo ""
        echo "=== Unit tests passed ==="
        record_green "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        ;;
    test:ui)
        check_prereqs
        generate_project
        run_tests ui
        echo ""
        echo "=== UI tests passed ==="
        ;;
    test:impact)
        check_prereqs
        generate_project
        baseline=""
        impact=""
        if [ -f "${LAST_TESTED_FILE}" ]; then
            baseline="$(cat "${LAST_TESTED_FILE}")"
        else
            baseline=""
        fi
        if [ -z "${baseline}" ]; then
            echo ""
            echo "Impact-aware unit tests..."
            echo "  no recorded green baseline yet (${LAST_TESTED_FILE}) → full unit gate"
            run_tests unit
            record_green "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        elif ! git -C "${REPO_ROOT}" rev-parse --verify -q "${baseline}" > /dev/null 2>&1; then
            echo ""
            echo "Impact-aware unit tests..."
            echo "  recorded baseline ${baseline} no longer exists in git → full unit gate"
            run_tests unit
            record_green "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        else
            echo ""
            echo "Impact-aware unit tests..."
            impact="$(compute_impact_suites "${baseline}")"
            if [ "${impact}" = "FULL" ]; then
                # Mapping was ambiguous or >40% affected — the run covers the
                # whole unit gate, so it may advance the green baseline.
                run_tests unit
                record_green "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
            elif [ "${impact}" = "NONE" ]; then
                # Nothing changed since the last full-coverage green run.
                # Partial runs never advance the baseline, so this stays
                # accurate even if the tree moves on.
                run_tests unit ${SAFETY_NET_CLASSES}
            else
                run_tests unit ${impact} ${SAFETY_NET_CLASSES}
            fi
        fi
        echo ""
        echo "=== Impact tests passed ==="
        ;;
    test-clean)
        check_prereqs
        generate_project
        echo ""
        echo "Wiping warm test DerivedData: ${TEST_DERIVED_DATA}"
        rm -rf "${TEST_DERIVED_DATA}"
        run_tests full
        echo ""
        echo "=== Full test gate passed (cold) ==="
        record_green "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
        ;;
    generate)
        check_prereqs
        generate_project
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
