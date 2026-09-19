#!/bin/bash
# test-impacted.sh — run ONLY the tests affected by the current diff.
#
# Maps changed files to XCTest classes:
#   - a changed test file (…/ElderlyAssistantTests/**/FooTests.swift)
#     selects class FooTests;
#   - a changed app file (…/ElderlyAssistant/**/Foo.swift) selects
#     FooTests if a matching FooTests.swift exists (stem match),
#     plus the curated "hub" files below that everything depends on.
# UI tests are skipped unless --ui is passed (they're slow and flaky
# under selection; run the full UI target deliberately instead).
#
# Usage:
#   ios/test-impacted.sh [--base <git-ref>] [--ui] [--list-only]
#
# Falls back to the FULL unit target when: no mapping found (safer than
# running nothing), a hub file changed, or the selection covers ≥50% of
# the test classes.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The generated project is named seniOS (project.yml `name:`); the scheme is
# still ElderlyAssistant. Build.sh uses the same pairing.
APP_NAME="seniOS"
SCHEME="ElderlyAssistant"
BUILD_DIR="${PROJECT_DIR}/../build"
TEST_DERIVED_DATA="${IOS_TEST_DERIVED_DATA:-${BUILD_DIR}/DerivedDataTests}"
TEST_SRC="${PROJECT_DIR}/ElderlyAssistantTests"
UI_TEST_SRC="${PROJECT_DIR}/ElderlyAssistantUITests"

BASE="origin/master"
WITH_UI=false
LIST_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base) BASE="$2"; shift 2 ;;
        --ui) WITH_UI=true; shift ;;
        --list-only) LIST_ONLY=true; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Hub files: changes here can break anything — run the full unit target.
HUBS=(
    "App/AppCoordinator.swift"
    "App/ElderlyAssistantApp.swift"
    "Services/ModelStore/ModelCatalog.swift"
    "Services/ModelStore/ModelStore.swift"
    "Services/ModelStore/ModelDownloadService.swift"
    "Services/Voice/CommandRouter.swift"
    "Services/Voice/VoicePipeline.swift"
    "Services/Gemini/GeminiClient.swift"
)

git -C "$PROJECT_DIR/.." fetch -q origin 2>/dev/null || true
CHANGED="$(git -C "$PROJECT_DIR/.." diff --name-only "${BASE}...HEAD" 2>/dev/null || true)"
# Also include uncommitted work-in-progress files.
CHANGED_WIP="$(git -C "$PROJECT_DIR/.." diff --name-only 2>/dev/null || true)"
ALL_CHANGED="$(printf '%s\n%s\n' "$CHANGED" "$CHANGED_WIP" | sort -u | grep -v '^$' || true)"

SELECTED_CLASSES=()
RUN_FULL=false

is_hub_changed() {
    local f
    for f in "${HUBS[@]}"; do
        if printf '%s\n' "$ALL_CHANGED" | grep -qx "ios/ElderlyAssistant/$f"; then
            return 0
        fi
    done
    return 1
}

if is_hub_changed; then
    echo "hub file changed → full unit target"
    RUN_FULL=true
else
    while IFS= read -r f; do
        case "$f" in
            "ios/ElderlyAssistantTests/"*.swift)
                stem="$(basename "$f" .swift)"
                SELECTED_CLASSES+=("$stem")
                ;;
            "ios/ElderlyAssistant/"*.swift)
                stem="$(basename "$f" .swift)"
                if [ -d "${TEST_SRC}" ] && \
                   find "$TEST_SRC" -name "${stem}Tests.swift" -print -quit | grep -q .; then
                    SELECTED_CLASSES+=("${stem}Tests")
                fi
                ;;
            "ios/ElderlyAssistantUITests/"*.swift)
                if $WITH_UI; then
                    stem="$(basename "$f" .swift)"
                    SELECTED_CLASSES+=("UI:${stem}")
                fi
                ;;
        esac
    done <<< "$ALL_CHANGED"
fi

UNIT_CLASSES=()
UI_CLASSES=()
for c in $(printf '%s\n' "${SELECTED_CLASSES[@]+"${SELECTED_CLASSES[@]}"}" | sort -u); do
    [[ "$c" == UI:* ]] && UI_CLASSES+=("${c#UI:}") || UNIT_CLASSES+=("$c")
done

TOTAL_UNIT_CLASSES="$(find "$TEST_SRC" -name "*Tests.swift" | wc -l | tr -d ' ')"
if [ "${#UNIT_CLASSES[@]}" -eq 0 ] && [ "${#UI_CLASSES[@]}" -eq 0 ]; then
    echo "no test files matched the diff → full unit target (safe default)"
    RUN_FULL=true
elif [ "${#UNIT_CLASSES[@]}" -ge $(( TOTAL_UNIT_CLASSES / 2 )) ]; then
    echo "selection covers ≥50% of unit test classes → full unit target"
    RUN_FULL=true
fi

ONLY=()
if ! $RUN_FULL; then
    # Guarded expansion: bash 3.2 (macOS default) treats an empty declared
    # array under `set -u` as an unbound variable — the +alt form keeps
    # a no-UI-class selection from aborting the script.
    for c in "${UNIT_CLASSES[@]+"${UNIT_CLASSES[@]}"}"; do
        ONLY+=("-only-testing:ElderlyAssistantTests/${c}")
    done
    for c in "${UI_CLASSES[@]+"${UI_CLASSES[@]}"}"; do
        ONLY+=("-only-testing:ElderlyAssistantUITests/${c}")
    done
fi

echo "diff base: ${BASE} (${#UNIT_CLASSES[@]} unit + ${#UI_CLASSES[@]} ui classes selected)"
$LIST_ONLY && { printf '%s\n' "${ONLY[@]:-<full unit target>}"; exit 0; }

# The checked-in xcodeproj drifts from project.yml — master has shipped
# source files its pbxproj never listed (#90's PointAsk), and build.sh
# hides the drift by regenerating. The harness must generate exactly like
# build.sh does, or it compiles a stale file list.
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 2
fi
(cd "${PROJECT_DIR}" && xcodegen generate --spec project.yml --project .)

# Same invocation as build.sh run_tests() so caching/warmup applies.
DESTINATION="${IOS_TEST_DESTINATION:-}"
if [ -z "${DESTINATION}" ]; then
    SIM_ID="$(xcrun simctl list devices available -j | ruby -rjson -e '
      devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
      phone = devices.find { |d| d["isAvailable"] && d["name"].start_with?("iPhone") }
      abort("No available iPhone simulator found") unless phone
      puts phone["udid"]
    ')"
    DESTINATION="platform=iOS Simulator,id=${SIM_ID}"
fi

xcodebuild test \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -destination "${DESTINATION}" \
    -derivedDataPath "${TEST_DERIVED_DATA}" \
    "${ONLY[@]+"${ONLY[@]}"}" \
    | tail -30
