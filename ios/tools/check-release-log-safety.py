#!/usr/bin/env python3
"""check-release-log-safety.py — Release-log privacy source gate (B1/T-049).

The defect of record (security-test SECURITY-NO_GO, finding B1): both
on-device STT engines printed the recognised transcript verbatim from a
`print` that was compiled into Release builds — every utterance the user
spoke (medication names, symptoms, family names, an emergency phrase) on
the device console, bypassing `LogSanitiser` / `ConsoleObservabilityBus`.
The paired review then falsified two more Release-compiled prints of the
same class: raw `error` objects (`warm failed:` / `extractDialectEmbedding
failed:`) that had slipped through because v1 of this gate only looked for
transcript-worded prints.

`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set only in the Debug
configuration, so a print inside a `#if DEBUG` region cannot be compiled
into Release. This gate fails when a Release-compiled print would render
content that must never reach a Release log sink:

  1. transcript content — every `*.swift` under ios/ElderlyAssistant;
  2. a raw error object / its description — the two on-device STT engine
     files only (`ENGINE_FILES`); other subsystems' raw-error prints are
     tracked separately and deliberately out of this gate's scope.

What counts as a print: `print(`, `debugPrint(`, `NSLog(`, `os_log(`,
`fputs(`. A statement is accumulated across lines until its parentheses
balance (string literals are skipped), so a call split over several lines
is judged as a whole.

Detection rules (all skipped when the region is Debug):
  - the statement mentions `transcript` as a word of its own, in any case,
    including a camelCase suffix (`rawTranscript`) — bare snake_case event
    names (`empty_transcript`) are not content;
  - the statement renders a variable that was assigned from a
    transcript-mentioning expression (one-hop taint, plus chains resolved
    in file order);
  - the statement uses `String(describing:)` / `String(reflecting:)`, or
    `.localizedDescription` / `.debugDescription`;
  - the statement interpolates an error object itself (`\\(error)`,
    `\\(err)`, `\\(nsError)`) or reaches a non-content-free member off one
    (only `.domain`, `.code`, `.errorCode`, `.statusCode`, `.rawValue`
    count as content-free);
  - the statement passes an error object as a bare argument
    (`print(error)`).

Re-run the guard after changing it: it fails (exit 1) when a listed engine
file is missing, so it cannot go green by having nothing to check.
"""

from __future__ import annotations

import os
import re
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_ROOT = os.path.join(PROJECT_DIR, "ElderlyAssistant")

# The two on-device STT engines: the files whose prints carry utterance
# content or the errors that can embed a key-bearing URL. A third engine
# added later must be listed here deliberately.
ENGINE_FILES = [
    "ElderlyAssistant/Services/Voice/WhisperSpeechRecognizer.swift",
    "ElderlyAssistant/Services/Voice/WhisperKitSpeechRecognizer.swift",
]

CALL_RE = re.compile(r"(?<![A-Za-z0-9_])(print|debugPrint|NSLog|os_log|fputs)\s*\(")
IF_DEBUG_RE = re.compile(r"^#if\s+DEBUG\s*$")
IF_RE = re.compile(r"^#if\b")
ELSE_RE = re.compile(r"^#else\b")
ENDIF_RE = re.compile(r"^#endif\b")

# Members of an error that are content-free by construction (type/shape
# identity). Anything else off an error object — a description, userInfo, a
# path, a URL — is not.
SAFE_ERROR_MEMBERS = {"domain", "code", "errorCode", "statusCode", "rawValue"}

# `String(describing: error)` is the exact T-050 defect shape.
STRINGIFY_RE = re.compile(r"\bString\s*\(\s*(?:describing|reflecting)\s*:")
# Error descriptions embed the failing URL, upstream bodies and paths.
DESCRIPTION_RE = re.compile(r"\.(?:localizedDescription|debugDescription)\b")
# A transcript word: not preceded by an identifier character (`empty_transcript`
# is an event name, not content) but catching `rawTranscript` camelCase too.
LOWER_TRANSCRIPT_RE = re.compile(r"(?<![a-z0-9_])transcript")
CAMEL_TRANSCRIPT_RE = re.compile(r"[a-z0-9]Transcript")
LET_RE = re.compile(r"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")
ASSIGN_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")


def is_error_identifier(name: str) -> bool:
    lowered = name.lower()
    return lowered.endswith(("err", "error", "exception"))


def mentions_transcript(text: str) -> bool:
    return bool(LOWER_TRANSCRIPT_RE.search(text.lower())
                or CAMEL_TRANSCRIPT_RE.search(text))


def strip_line_comments(line: str) -> str:
    """Drop `// …` while leaving string literals (and `\\(` interpolations) intact."""
    out, in_string, i = [], False, 0
    while i < len(line):
        char = line[i]
        if in_string:
            if char == "\\" and i + 1 < len(line):
                out.append(line[i:i + 2])
                i += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "/" and i + 1 < len(line) and line[i + 1] == "/":
            break
        out.append(char)
        i += 1
    return "".join(out)


def paren_balance(text: str) -> int:
    """Parenthesis balance ignoring string literals (interpolation parens included)."""
    balance, in_string, i = 0, False, 0
    while i < len(text):
        char = text[i]
        if in_string:
            if char == "\\" and i + 1 < len(text):
                i += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "(":
            balance += 1
        elif char == ")":
            balance -= 1
        i += 1
    return balance


def interpolation_bodies(text: str):
    """Yield the code inside each `\\( … )` interpolation, paren-aware."""
    for match in re.finditer(r"\\\(", text):
        depth, in_string, i = 1, False, match.end()
        while i < len(text) and depth > 0:
            char = text[i]
            if in_string:
                if char == "\\" and i + 1 < len(text):
                    i += 2
                    continue
                if char == '"':
                    in_string = False
            elif char == '"':
                in_string = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield text[match.end():i]


def error_object_offence(statement: str):
    """Return a reason string when a Release-compiled print renders a raw error."""
    if STRINGIFY_RE.search(statement):
        return "String(describing:)/String(reflecting:) in a print"
    if DESCRIPTION_RE.search(statement):
        return ".localizedDescription/.debugDescription in a print"

    for body in interpolation_bodies(statement):
        cast_types = set(re.findall(r"\bas\s+([A-Za-z_][A-Za-z0-9_]*)", body))
        for match in re.finditer(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)", body):
            name = match.group(1)
            if not is_error_identifier(name) or name in cast_types:
                continue
            rest = body[match.end():].lstrip()
            if rest.startswith("as "):
                continue  # a cast target, judged on its own once skipped
            if rest.startswith("."):
                member = re.match(r"\.([A-Za-z_][A-Za-z0-9_]*)", rest)
                if member and member.group(1) in SAFE_ERROR_MEMBERS:
                    continue
            return "raw error object in a print interpolation"

    # Bare error argument: `print(error)`, `print(nsError as NSError)`,
    # `os_log("…", err)` — the object itself, with no content-free member
    # applied.
    for match in re.finditer(
            r"[(:,]\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s+as\s+[A-Za-z_][A-Za-z0-9_]*)?\s*[,)]",
            statement):
        if is_error_identifier(match.group(1)):
            return "raw error object passed to a print"
    return None


def scan(path: str, engine: bool):
    """Yield (line, message) offences for one Swift file."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    stack = []          # "#if" regions: "debug" / "other" / "not_debug"
    tainted = set()     # identifiers assigned from transcript-bearing expressions
    offences = []
    pending = None      # [start_line, text, in_debug]
    index = 0

    while index < len(lines):
        raw = lines[index]
        stripped = raw.strip()

        if IF_DEBUG_RE.match(stripped):
            stack.append("debug")
            index += 1
            continue
        if IF_RE.match(stripped):
            stack.append("other")
            index += 1
            continue
        if ELSE_RE.match(stripped):
            if stack and stack[-1] == "debug":
                stack[-1] = "not_debug"
            index += 1
            continue
        if ENDIF_RE.match(stripped):
            if stack:
                stack.pop()
            index += 1
            continue

        code = strip_line_comments(raw)
        in_debug = "debug" in stack

        # One-hop taint: `let message = "…" + transcript`, and chains in
        # file order (`let b = a` after `let a = …transcript…`).
        assignment = LET_RE.search(code) or ASSIGN_RE.match(code)
        if assignment:
            name = assignment.group(1)
            rhs = code[assignment.end():]
            if mentions_transcript(rhs) or any(
                    re.search(r"(?<![A-Za-z0-9_])" + re.escape(t) + r"\b", rhs)
                    for t in tainted):
                tainted.add(name)

        if pending is None:
            opener = CALL_RE.search(code)
            if opener:
                balance = paren_balance(code[opener.start():])
                pending = [index + 1, code, in_debug, balance]
                if balance <= 0:
                    offences.extend(_judge(path, pending, engine, tainted, lines))
                    pending = None
        else:
            pending[1] += " " + code
            pending[3] += paren_balance(code)
            if pending[3] <= 0:
                offences.extend(_judge(path, pending, engine, tainted, lines))
                pending = None
        index += 1

    if pending is not None:  # unbalanced (multi-line string / macro) — judge what we saw
        offences.extend(_judge(path, pending, engine, tainted, lines))
    return offences


def _judge(path, pending, engine, tainted, lines):
    line_no, statement, in_debug, _balance = pending
    if in_debug:
        return []
    relative = os.path.relpath(path, PROJECT_DIR)
    offences = []
    text = statement
    if mentions_transcript(text) or any(
            re.search(r"(?<![A-Za-z0-9_])" + re.escape(t) + r"\b", text) for t in tainted):
        offences.append((line_no, "transcript content in a print outside #if DEBUG",
                         lines[line_no - 1].strip() if line_no - 1 < len(lines) else ""))
    if engine:
        reason = error_object_offence(text)
        if reason:
            offences.append((line_no, reason + " outside #if DEBUG",
                             lines[line_no - 1].strip() if line_no - 1 < len(lines) else ""))
    return [(relative, line, message, source) for line, message, source in offences]


def main() -> int:
    violations = []
    for engine in ENGINE_FILES:
        if not os.path.isfile(os.path.join(PROJECT_DIR, engine)):
            print(f"  ✗ guarded engine file is missing: {engine}")
            print("    update tools/check-release-log-safety.py deliberately")
            violations.append((engine, 0, "guarded engine file is missing", ""))

    engine_set = {os.path.normpath(os.path.join(PROJECT_DIR, e)) for e in ENGINE_FILES}

    for root, _dirs, files in os.walk(SOURCE_ROOT):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            violations.extend(scan(path, os.path.normpath(path) in engine_set))

    if violations:
        for relative, line, message, source in violations:
            if line:
                print(f"{relative}:{line}: {message}")
                if source:
                    print(f"    {source}")
            else:
                print(f"  ✗ {message}: {relative}")
        print(f"  ✗ {len(violations)} Release-log privacy violation(s) (B1/T-049).")
        print("    A transcript or a raw error object must not be rendered by a print that")
        print("    compiles into Release: wrap it in #if DEBUG, delete it, or route a")
        print("    content-free signal (count/duration/domain+code) through the sanitised")
        print("    observability bus — never the raw content.")
        return 1

    print("  ✓ no transcript content or raw error object can be printed in a non-Debug configuration")
    return 0


if __name__ == "__main__":
    sys.exit(main())
