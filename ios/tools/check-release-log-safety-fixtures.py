#!/usr/bin/env python3
"""check-release-log-safety-fixtures.py — the log-safety gate's own test suite (T-028).

The gate in `check-release-log-safety.py` is a rule engine, and a rule engine
that is never exercised is indistinguishable from one that has stopped
firing. This harness is what makes "the gate works" a claim with evidence:

  * for **every** rule the engine declares (`--list-rules`), a `positive`
    fixture (a tree the gate must fail on, naming that rule) and a `negative`
    fixture (a tree the gate must pass) must exist. A rule without a positive
    fixture is not a rule, and the harness fails rather than skipping it;
  * every fixture tree is run through the real engine, as a subprocess, with
    the real exit code inspected — not imported, not stubbed;
  * a `positive` case must exit 1 **and** name its rule in the output; a
    `negative` case must exit 0. Nothing weaker counts as passing.

Layout:

    log-safety-fixtures/<rule-id>/positive/ElderlyAssistant/…   (must fail)
    log-safety-fixtures/<rule-id>/negative/ElderlyAssistant/…   (must pass)

A case directory may contain an `arguments` file whose whitespace-separated
tokens are appended to the engine invocation; `{fixture}` in a token is
replaced with the case directory, so a case can point the engine at a
fixture-local allow-list. Fixture trees are *not* compiled and are not under
`ios/ElderlyAssistant`, so the shipped gate never scans them.

`--falsify` is the second, optional discipline: for every rule, the engine is
re-run over that rule's *positive* fixture with `--disable-rule <rule>`, and
the case passes only if the gate **stops catching the tree at all** (exit 0).
A rule whose positive fixture still fails with the rule disabled is a rule
that fires only in company — it would not be missed, so it is not carrying
its own weight, and the harness says so instead of printing a green tick. It
is opt-in because it is a slower, deliberately destructive run; the default
invocation stays fast enough for every build.

Exit 0 when every rule has both fixtures and every fixture behaves; 1
otherwise.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(TOOLS_DIR, "check-release-log-safety.py")
FIXTURE_ROOT = os.path.join(TOOLS_DIR, "log-safety-fixtures")
KINDS = ("positive", "negative")
SOURCE_DIR_NAME = "ElderlyAssistant"


class Case:
    __slots__ = ("rule", "kind", "directory", "passed", "detail")

    def __init__(self, rule, kind, directory):
        self.rule = rule
        self.kind = kind
        self.directory = directory
        self.passed = False
        self.detail = ""


def declared_rules():
    """The engine's rule registry, read from the engine itself."""
    process = subprocess.run([sys.executable, ENGINE, "--list-rules"],
                             capture_output=True, text=True)
    if process.returncode != 0:
        print(f"  ✗ could not read the rule registry:\n{process.stderr}")
        sys.exit(1)
    rules = []
    for line in process.stdout.splitlines():
        if line.strip():
            rules.append(line.split("\t", 1)[0].strip())
    if not rules:
        print("  ✗ the engine declares no rules — nothing to test")
        sys.exit(1)
    return rules


def fixture_arguments(directory):
    path = os.path.join(directory, "arguments")
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as handle:
        tokens = handle.read().split()
    return [token.replace("{fixture}", directory) for token in tokens]


def swift_file_count(directory):
    count = 0
    for _root, _dirs, files in os.walk(directory):
        count += sum(1 for name in files if name.endswith(".swift"))
    return count


def run_case(rule, kind, directory):
    case = Case(rule, kind, directory)
    source_root = os.path.join(directory, SOURCE_DIR_NAME)
    if not os.path.isdir(source_root):
        case.detail = f"no {SOURCE_DIR_NAME}/ tree under {directory}"
        return case
    if swift_file_count(source_root) == 0:
        case.detail = f"{source_root} contains no Swift source to scan"
        return case

    command = [sys.executable, ENGINE, "--source-root", source_root, "--quiet"]
    command += fixture_arguments(directory)
    process = subprocess.run(command, capture_output=True, text=True)
    output = process.stdout + process.stderr

    if kind == "positive":
        if process.returncode == 0:
            case.detail = "the gate passed a tree it must fail on"
        elif rule not in output:
            case.detail = (f"the gate failed but did not name the rule "
                           f"({process.returncode}): {output.strip()}")
        else:
            case.passed = True
    else:
        if process.returncode != 0:
            case.detail = ("the gate failed a tree it must pass (a rule fired "
                           f"where it must stay quiet): {output.strip()}")
        else:
            case.passed = True
    return case


def run_falsification(rule, directory):
    """Re-run a positive fixture with one rule disabled: it must stop failing."""
    case = Case(rule, "falsify", directory)
    source_root = os.path.join(directory, SOURCE_DIR_NAME)
    command = [sys.executable, ENGINE, "--source-root", source_root, "--quiet",
               "--disable-rule", rule]
    command += fixture_arguments(directory)
    process = subprocess.run(command, capture_output=True, text=True)
    output = process.stdout + process.stderr
    if process.returncode == 0:
        case.passed = True
    else:
        case.detail = (f"positive fixture is still caught with '{rule}' disabled "
                       f"({process.returncode}) — the rule fires only in company: "
                       f"{output.strip()}")
    return case


def discover(kind, rules):
    """Rules that have no <kind> fixture, and directories that are not rules."""
    missing = [rule for rule in rules
               if not os.path.isdir(os.path.join(FIXTURE_ROOT, rule, kind))]
    unknown = []
    if os.path.isdir(FIXTURE_ROOT):
        for name in sorted(os.listdir(FIXTURE_ROOT)):
            path = os.path.join(FIXTURE_ROOT, name)
            if os.path.isdir(path) and name not in rules:
                unknown.append(name)
    return missing, unknown


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--only", help="run just one rule's fixtures")
    parser.add_argument("--falsify", action="store_true",
                        help="also prove each rule is load-bearing: its positive "
                             "fixture must stop being caught when the rule is "
                             "disabled (slower; not part of the build path)")
    args = parser.parse_args(argv)

    rules = declared_rules()
    if args.only:
        if args.only not in rules:
            print(f"  ✗ '{args.only}' is not a rule the engine declares")
            return 1
        rules = [args.only]

    failures = []
    cases = []
    for kind in KINDS:
        missing, unknown = discover(kind, declared_rules())
        for rule in missing:
            failures.append(f"rule '{rule}' has no {kind} fixture "
                            "(a rule without both fixtures is not covered)")
        for name in unknown:
            failures.append(f"fixture directory '{name}' is not a declared rule "
                            "(a typo would silently test nothing)")

    for rule in rules:
        for kind in KINDS:
            directory = os.path.join(FIXTURE_ROOT, rule, kind)
            if not os.path.isdir(directory):
                continue
            case = run_case(rule, kind, directory)
            cases.append(case)
            if not case.passed:
                failures.append(f"{rule}/{kind}: {case.detail}")

    if args.falsify:
        for rule in rules:
            directory = os.path.join(FIXTURE_ROOT, rule, "positive")
            if not os.path.isdir(directory):
                continue
            case = run_falsification(rule, directory)
            cases.append(case)
            if not case.passed:
                failures.append(f"{rule}/falsify: {case.detail}")

    print(f"  log-safety fixtures: {len(cases)} case(s) over {len(rules)} rule(s)")
    for case in cases:
        marker = "✓" if case.passed else "✗"
        print(f"    {marker} {case.rule}/{case.kind}")
        if not case.passed:
            print(f"        {case.detail}")

    if failures:
        for failure in failures:
            print(f"  ✗ {failure}")
        print(f"  ✗ the log-safety gate's fixture suite failed ({len(failures)} problem(s)).")
        return 1

    print("  ✓ every rule has a positive and a negative fixture, and every fixture behaves")
    if args.falsify:
        print("  ✓ every rule is load-bearing: disabling it makes its positive fixture pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
