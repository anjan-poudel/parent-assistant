#!/bin/bash
#
# check-unguarded-transcript-prints.sh — Release-build privacy guard (B1/T-049).
#
# The defect of record (security-test SECURITY-NO_GO, finding B1): both
# on-device STT engines printed the recognised transcript verbatim from a
# `print` that was compiled into Release builds — every utterance the user
# spoke (medication names, symptoms, family names, an emergency phrase) on
# the device console, bypassing `LogSanitiser` / `ConsoleObservabilityBus`.
#
# `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set only in the Debug
# configuration (seniOS.xcodeproj, `name = Debug;`), so a print inside a
# `#if DEBUG` region cannot be compiled into Release. This guard fails when
# a transcript-content print in the iOS app source is NOT inside such a
# region.
#
# What it checks:
#   - every `*.swift` under ios/ElderlyAssistant,
#   - candidate lines are `print(` / `NSLog(` / `os_log(` calls whose text
#     mentions "transcript" as a word of its own (a bare `empty_transcript`
#     event name is not content; `transcript=` / `transcript="…"` is);
#     comment lines are skipped,
#   - each candidate must sit inside an open `#if DEBUG` region.
#
# It also fails if either on-device engine file is missing: a guard that
# silently passes once the code it guards has moved is not a guard.
#
# The check is deliberately a source gate, not a runtime test: the unit
# suite runs in Debug, where a re-introduced unguarded print would still
# read as "present and working". Exit 0 = guarded, 1 = violation.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${PROJECT_DIR}/ElderlyAssistant"

ENGINE_FILES=(
    "${SOURCE_ROOT}/Services/Voice/WhisperSpeechRecognizer.swift"
    "${SOURCE_ROOT}/Services/Voice/WhisperKitSpeechRecognizer.swift"
)

violations=0

for engine in "${ENGINE_FILES[@]}"; do
    if [ ! -f "${engine}" ]; then
        echo "  ✗ guarded engine file is missing: ${engine#"${PROJECT_DIR}/"}"
        echo "    update tools/check-unguarded-transcript-prints.sh deliberately"
        violations=$((violations + 1))
    fi
done

# awk per file: maintain a stack of open `#if` regions and a "is a #if DEBUG
# region open" test. `#else` inside a DEBUG region means the lines that
# follow are NOT the Debug branch — tracked so the guard cannot be defeated
# by an `#else` that happens to hold the print.
while IFS= read -r file; do
    [ -n "${file}" ] || continue
    report="$(awk -v rel="${file#"${PROJECT_DIR}/"}" '
        function in_debug(   i) {
            for (i = 1; i <= depth; i++) if (stack[i] == "debug") return 1
            return 0
        }
        /^[[:space:]]*#if[[:space:]]+DEBUG[[:space:]]*$/ {
            depth++; stack[depth] = "debug"; next
        }
        /^[[:space:]]*#if/ {
            depth++; stack[depth] = "other"; next
        }
        /^[[:space:]]*#else/ {
            if (depth > 0 && stack[depth] == "debug") stack[depth] = "not_debug"
            next
        }
        /^[[:space:]]*#endif/ {
            if (depth > 0) { delete stack[depth]; depth-- }
            next
        }
        /^[[:space:]]*\/\// { next }
        /(print|NSLog|os_log)[[:space:]]*\(/ {
            if ($0 ~ /(^|[^A-Za-z0-9_])[Tt]ranscript/ && !in_debug())
                printf("%s:%d: %s\n", rel, NR, $0)
        }
    ' "${file}")"
    if [ -n "${report}" ]; then
        echo "${report}"
        violations=$((violations + $(printf '%s\n' "${report}" | wc -l | tr -d ' ')))
    fi
done < <(find "${SOURCE_ROOT}" -name '*.swift' -type f | sort)

if [ "${violations}" -gt 0 ]; then
    echo "  ✗ ${violations} transcript-content print(s) outside #if DEBUG (B1/T-049)."
    echo "    A transcript print must be Debug-only: wrap it in #if DEBUG, delete"
    echo "    it, or route a content-free signal (count/duration) through the"
    echo "    sanitised observability bus — never the raw transcript."
    exit 1
fi

echo "  ✓ no transcript-content print can be compiled into a non-Debug configuration"
