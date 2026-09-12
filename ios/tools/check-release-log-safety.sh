#!/bin/bash
#
# check-release-log-safety.sh — Release-log privacy source gate (B1/T-049).
#
# Entry point kept in shell so the gate stays one line in ios/build.sh. The
# checks themselves live in check-release-log-safety.py: multi-line call
# accumulation, one-hop transcript taint and the raw-error rules are not
# reasonably expressible in awk, and the v1 awk gate was falsified by exactly
# those shapes (a raw `\(error)` print in a `#if canImport` region).
#
# Exit 0 = guarded, 1 = violation (including a missing engine file).

set -uo pipefail

exec /usr/bin/env python3 "$(cd "$(dirname "$0")" && pwd)/check-release-log-safety.py"
