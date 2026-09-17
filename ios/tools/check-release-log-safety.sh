#!/bin/bash
#
# check-release-log-safety.sh — Release-log privacy source gate (B1/T-049, T-028).
#
# Entry point kept in shell so the gate stays one line in ios/build.sh. The
# checks themselves live in check-release-log-safety.py: multi-line call
# accumulation, one-hop transcript taint and the raw-error rules are not
# reasonably expressible in awk, and the v1 awk gate was falsified by exactly
# those shapes (a raw `\(error)` print in a `#if canImport` region).
#
# Two things run here, in this order:
#
#   1. the rule engine over the real tree — the gate's verdict;
#   2. the engine's own fixture suite (`check-release-log-safety-fixtures.py`)
#      — the gate's test of itself, run over the fixture trees in
#      tools/log-safety-fixtures/. A rule engine that is never exercised is
#      indistinguishable from one that has stopped firing, and this is the
#      cheapest place to notice: a rule deleted, renamed, or merely narrowed
#      past its own fixture fails the next gate.
#
# The fixture step is not optional and cannot be switched off by configuration.
# A missing fixture tree is a failure, not a skip: `a rule without a positive
# fixture is not a rule`. Run `check-release-log-safety-fixtures.py --falsify`
# to also prove each rule is load-bearing (slower; not part of the build path).
#
# Exit 0 = guarded, 1 = violation (including a missing engine file, or a
# fixture that no longer behaves).
#
# AM-5 note, stated so nobody has to infer it: this gate is a source-level
# check. Static rules cannot follow every indirection — see the "Known
# limitations" section of check-release-log-safety.py, which is part of the
# evidence, and do not restate its coverage as stronger than it is.

set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

/usr/bin/env python3 "${TOOLS_DIR}/check-release-log-safety.py" || exit 1

/usr/bin/env python3 "${TOOLS_DIR}/check-release-log-safety-fixtures.py" || {
    echo "  ✗ the log-safety gate's own fixture suite failed (see above)." >&2
    echo "    The gate is not trusted until its rules behave on the fixtures:" >&2
    echo "    fix the rule or fix the fixture — do not delete the case." >&2
    exit 1
}
