#!/usr/bin/env python3
"""check-release-log-safety.py — Release-log privacy source gate (B1/T-049, AM-5/T-028).

The defect of record (security-test SECURITY-NO_GO, finding B1): both
on-device STT engines printed the recognised transcript verbatim from a
`print` that was compiled into Release builds — every utterance the user
spoke (medication names, symptoms, family names, an emergency phrase) on
the device console, bypassing `LogSanitiser` / `ConsoleObservabilityBus`.
The paired review then falsified two more Release-compiled prints of the
same class: raw `error` objects (`warm failed:` / `extractDialectEmbedding
failed:`) that had slipped through because v1 of this gate only looked for
transcript-worded prints.

T-028 (AM-5 / SD-2) added a second rule family. The security design review
found that this gate — named by the live-camera-translation design as its
enforcement point for NFR-LCT-006 — matched only the word `transcript` and
raw error objects, so `print(region.text)` or `print(translation)` in the
feature's sources passed. The feature's content class is now covered over
the feature's own scan roots (`FEATURE_ROOTS`).

`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set only in the Debug
configuration, so a print inside a `#if DEBUG` region cannot be compiled
into Release. This gate fails when a Release-compiled print would render
content that must never reach a Release log sink:

  1. transcript content — every `*.swift` under the source root;
  2. a raw error object / its description — the two on-device STT engine
     files only (`ENGINE_FILES`); other subsystems' raw-error prints are
     tracked separately and deliberately out of this gate's scope.

and, over the live-camera-translation feature's own roots only
(`FEATURE_ROOTS`, AM-5):

  3. a Release-compiled console write at all — the feature's events go
     through the sanitising observability bus or not at all;
  4. recognized or translated text in a console write, in **any**
     configuration;
  5. an event metadata key that is not in `LogSanitiser.allowedKeys`;
  6. a text value interpolated or rendered into an event field.

Rule 3 keeps the shipped Release framing (a `#if DEBUG` region cannot be
compiled into Release). Rules 4-6 do not: NFR-LCT-006 says content must not
reach a log surface "in any build", and the feature's sources have no
legitimate content-bearing console write. The two are deliberately
orthogonal — rule 3 catches the bypass whatever it renders, rule 4 catches
content even where the Debug exemption would apply — and
`LiveTranslateSourceHygieneTests` is stricter than both, forbidding any
console write in `Services/LiveTranslate/` outright. The gate is the
backstop, not the only arm.

What counts as a print: `print(`, `debugPrint(`, `NSLog(`, `os_log(`,
`fputs(`. A statement is accumulated across lines until its parentheses
balance (string literals are skipped), so a call split over several lines
is judged as a whole.

Detection rules (rules 1-2 skipped when the region is Debug):
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

Detection rules 3-6 (feature roots, any configuration):
  - any console write, whatever it renders;
  - a console write mentioning recognized/translated text: `text` and any
    `…Text` identifier, `translation(s)` / `translated`, `recognized` /
    `recognised` / `recognition`, `transcript`, `prompt` — as words of
    their own, so the `text_change` / `consent_prompt_shown` event names
    are not content;
  - an event metadata dictionary literal with a string key that is not in
    `LogSanitiser.allowedKeys`, or a `LiveTranslateEvents.MetadataKey`
    case whose raw value is not in that set (the additive allow-list entry
    is the deliberate decision point, per AM-2/CL-5);
  - an event field (`errorCode:` / `error_code:` / a `metadata:` value)
    built from a content-worded or error-derived interpolation, or from
    `String(describing:)` / `.localizedDescription` / `.debugDescription`.

**Known limitations, stated rather than implied (AM-5).** These rules are
static and textual. They cannot see through indirection: a value routed
through a helper (`let s = region.text; print(s)` is caught only if the
taint chain is one hop and in file order; a value returned across a
function boundary, stored in a dictionary under a non-content key, or
rendered by a framework, is not). They cannot read a metadata dictionary
handed over as a variable (`metadata: stringMetadata` has no keys to
inspect), so an *undeclared runtime key* is caught only where it is
spelled literally — the typed emitter plus T-003's per-key allow-list
survival tests remain the primary safeguard. They cannot see through a
wrapper function that prints on the caller's behalf, or a sink that does
not use the five call spellings above. A green gate therefore means "no
defect of these shapes is present in these files", not "content cannot
reach a sink"; that is why the design's invariant table names the runtime
tests first and this gate second. Reaching a sink through a path this gate
cannot see is a documented gap, not a covered case.

Run the guard after changing it: it fails (exit 1) when a listed engine
file is missing or the log allow-list cannot be read, so it cannot go
green by having nothing to check.

Usage:
  check-release-log-safety.py [--source-root DIR] [--allow-list PATH]
                              [--require-engine-files] [--list-rules] [--quiet]

`--source-root` scans a different tree and `--allow-list` reads a different
allow-list; the fixture harness uses both (the defaults are the project's
own `ElderlyAssistant/` and its shipped `LogSanitiser.swift`).
`--require-engine-files` is implied when the default root is used, and can
be forced on for a fixture tree.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SOURCE_ROOT = os.path.join(PROJECT_DIR, "ElderlyAssistant")

# The two on-device STT engines, source-root-relative. The files whose prints
# carry utterance content or the errors that can embed a key-bearing URL. A
# third engine added later must be listed here deliberately.
ENGINE_FILES = [
    "Services/Voice/WhisperSpeechRecognizer.swift",
    "Services/Voice/WhisperKitSpeechRecognizer.swift",
]
SOURCE_ROOT_LABEL = "ElderlyAssistant"  # prefix used in messages, as before

# The live-camera-translation feature's content roots (AM-5/T-028),
# source-root-relative. Every file here is new code owned by the feature, and
# none of it may write to a console or build an event field out of content.
FEATURE_ROOTS = [
    "Services/LiveTranslate",
    "App/LiveTranslate",
    "Services/Plugins/LiveTranslatePlugin.swift",
    "Services/Gemini/GeminiClient+Translate.swift",
    # [POINT-ASK] The point, tap & ask feature's own roots: same rules —
    # the OCR text, translations, class labels and the VLM's words are
    # user content and may never reach a console or an event field.
    "Services/PointAsk",
    "Services/Gemini/GeminiClient+PointAsk.swift",
]

# The shipped allow-list the feature's metadata keys must be declared in.
# Read out of the source rather than duplicated here: a copy would drift, and
# the point of rule 5 is that the *shipped* set is the authority.
DEFAULT_ALLOW_LIST = os.path.join(DEFAULT_SOURCE_ROOT,
                                  "Services/Observability/LogSanitiser.swift")

# Every rule this gate can report, with its one-line meaning. `--list-rules`
# prints these; the fixture harness requires a positive and a negative fixture
# for every entry, so a rule cannot exist without proving that it fires.
RULES = {
    "engine-file-missing":
        "a file this gate is required to inspect is absent (it cannot go green by having nothing to check)",
    "allow-list-unreadable":
        "the shipped log allow-list could not be read, so no metadata key could be judged",
    "transcript-print":
        "a Release-compiled print renders transcript content",
    "transcript-taint":
        "a Release-compiled print renders a value one hop from transcript content",
    "string-describing":
        "a Release-compiled print renders String(describing:)/String(reflecting:), which embeds arbitrary state",
    "error-description":
        "a Release-compiled print renders .localizedDescription/.debugDescription, which embeds a URL or body",
    "error-interpolation":
        "a Release-compiled print interpolates a raw error object",
    "error-argument":
        "a Release-compiled print passes a raw error object as an argument",
    "feature-console-write":
        "a console write in the feature's sources bypasses the sanitising observability bus",
    "feature-content-print":
        "recognized or translated text appears in a console write in the feature's sources",
    "feature-unlisted-metadata-key":
        "an event metadata key is not in LogSanitiser.allowedKeys",
    "feature-text-interpolated-into-event":
        "a text value is interpolated or rendered into an event field",
}

CALL_RE = re.compile(r"(?<![A-Za-z0-9_])(print|debugPrint|NSLog|os_log|fputs)\s*\(")
EVENT_OPENER_RE = re.compile(r"(?<![A-Za-z0-9_])(ObservabilityEvent|emit)\s*\(")
FEATURE_OPENER_RE = re.compile(CALL_RE.pattern + "|" + EVENT_OPENER_RE.pattern)
IF_DEBUG_RE = re.compile(r"^#if\s+DEBUG\s*$")
IF_RE = re.compile(r"^#if\b")
ELSE_RE = re.compile(r"^#else\b")
# `#else\b` cannot match `#elseif` (`e` and `i` are both word characters, so
# there is no boundary), which used to leave `#if DEBUG / #elseif X` inside
# the debug region: a print in the second branch was excused as Debug-only
# while it compiles into Release. The condition decides the branch that
# follows, so `#elseif DEBUG` stays Debug and anything else is checked.
ELSEIF_RE = re.compile(r"^#elseif\b\s*(.*)$")
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

# The feature's content vocabulary (AM-5). Each pattern matches a word of its
# own, so snake_case event names and camelCase type names are not content:
# `text_change`, `translation_batch_requested`, `TextRegionStabilizer`,
# `LiveTextDetector` and `consent_prompt_shown` all stay quiet.
FEATURE_CONTENT_PATTERNS = [
    LOWER_TRANSCRIPT_RE,                                   # transcript
    CAMEL_TRANSCRIPT_RE,                                   # rawTranscript
    re.compile(r"(?<![A-Za-z0-9_])(translated|translations?)(?![A-Za-z0-9_])"),
    re.compile(r"(?<![A-Za-z0-9_])(recognized|recognised|recognition)(?![A-Za-z0-9_])"),
    # `text` and its plural `texts`, bare or as the tail of a camelCase name
    # (`sceneText`, `regionTexts`). The plural was a hole: the trailing
    # lookahead rejected `texts`, so `debugPrint(regionTexts)` — a collection
    # of recognized strings — read as content-free.
    re.compile(r"(?<![A-Za-z0-9_])(?:[A-Za-z0-9]*[Tt]exts?|texts?)(?![A-Za-z0-9_])"),
    re.compile(r"(?<![A-Za-z0-9_])prompts?(?![A-Za-z0-9_])"),
]

# `metadata: [ … ]`, the field names an event can carry text in, and the
# `MetadataKey` declaration whose cases must be allow-listed.
METADATA_LITERAL_RE = re.compile(r"(?<![A-Za-z0-9_])metadata\s*:\s*\[")
DICT_KEY_RE = re.compile(r'^\s*(?:"([^"]+)"|\.([A-Za-z0-9_]+))\s*:')
ERROR_CODE_FIELD_RE = re.compile(r"(?<![A-Za-z0-9_])(errorCode|error_code)\s*:\s*")
METADATA_KEY_ENUM_RE = re.compile(r"enum\s+MetadataKey\s*:[^{]*\{(.*?)\n\s{4}\}", re.S)
ENUM_CASE_RE = re.compile(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", re.M)


class Violation:
    """One offence, with the rule that found it (AM-5: the failure names the rule)."""

    __slots__ = ("path", "line", "rule", "message", "source")

    def __init__(self, path, line, rule, message, source=""):
        self.path = path
        self.line = line
        self.rule = rule
        self.message = message
        self.source = source


def is_error_identifier(name: str) -> bool:
    lowered = name.lower()
    return lowered.endswith(("err", "error", "exception"))


def mentions_transcript(text: str) -> bool:
    return bool(LOWER_TRANSCRIPT_RE.search(text.lower())
                or CAMEL_TRANSCRIPT_RE.search(text))


def mentions_feature_content(text: str) -> bool:
    """AM-5 content vocabulary: recognized or translated text by its own words."""
    return any(pattern.search(text) for pattern in FEATURE_CONTENT_PATTERNS)


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


def _skip_string(text: str, index: int) -> int:
    """Index just past a string literal starting at `index` (the opening quote)."""
    i = index + 1
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            i += 2
            continue
        if text[i] == '"':
            return i + 1
        i += 1
    return len(text)


def _interpolation_end(text: str, index: int) -> int:
    """Index just past the `\\( … )` interpolation whose body starts at `index`."""
    depth, i = 1, index
    while i < len(text):
        char = text[i]
        if char == '"':
            i = _skip_string(text, i)
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


def bracket_span(text: str, start: int):
    """The index of the `]` closing the `[` at `start`, or None. String-aware."""
    depth, i = 0, start
    while i < len(text):
        char = text[i]
        if char == '"':
            i = _skip_string(text, i)
            continue
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def top_level_chunks(text: str):
    """Split on commas that are not inside brackets, parens or string literals."""
    chunks, current = [], []
    depth, i = 0, 0
    while i < len(text):
        char = text[i]
        if char == '"':
            end = _skip_string(text, i)
            current.append(text[i:end])
            i = end
            continue
        if char in "([":
            depth += 1
            current.append(char)
        elif char in ")]":
            depth -= 1
            current.append(char)
        elif char == "," and depth == 0:
            chunks.append("".join(current))
            current = []
        else:
            current.append(char)
        i += 1
    chunks.append("".join(current))
    return chunks


def interpolation_bodies(text: str):
    """Yield the code inside each `\\( … )` interpolation, string-aware."""
    for match in re.finditer(r"\\\(", text):
        end = _interpolation_end(text, match.end())
        yield text[match.end():end - 1]


def without_interpolations(value: str) -> str:
    """A field value with its `\\( … )` bodies blanked, for the bare-identifier test."""
    out, cursor = [], 0
    for match in re.finditer(r"\\\(", value):
        out.append(value[cursor:match.start()])
        cursor = _interpolation_end(value, match.end())
    out.append(value[cursor:])
    return "".join(out)


def error_object_offence(statement: str):
    """(rule, reason) when a Release-compiled print renders a raw error."""
    if STRINGIFY_RE.search(statement):
        return "string-describing", "String(describing:)/String(reflecting:) in a print"
    if DESCRIPTION_RE.search(statement):
        return "error-description", ".localizedDescription/.debugDescription in a print"

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
            return "error-interpolation", "raw error object in a print interpolation"

    # Bare error argument: `print(error)`, `print(nsError as NSError)`,
    # `os_log("…", err)` — the object itself, with no content-free member
    # applied.
    for match in re.finditer(
            r"[(:,]\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s+as\s+[A-Za-z_][A-Za-z0-9_]*)?\s*[,)]",
            statement):
        if is_error_identifier(match.group(1)):
            return "error-argument", "raw error object passed to a print"
    return None


def statements(lines, opener_re):
    """Accumulate call statements across lines, with the transcript taint set.

    Yields `[line_number, statement_text, in_debug, tainted]` in file order.
    The taint set is the one built from every assignment seen *up to and
    including* the line the statement ends on — the shipped order, preserved.
    """
    stack = []          # "#if" regions: "debug" / "other" / "not_debug"
    tainted = set()
    pending = None
    out = []
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
        if ELSEIF_RE.match(stripped):
            if stack:
                condition = ELSEIF_RE.match(stripped).group(1).strip()
                # Fail-safe direction: only a condition that *is* `DEBUG`
                # re-opens a Debug region; an unknown condition is Release
                # text and is judged.
                stack[-1] = ("debug" if IF_DEBUG_RE.match("#if " + condition)
                             else "not_debug")
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
            opener = opener_re.search(code)
            if opener:
                balance = paren_balance(code[opener.start():])
                pending = [index + 1, code, in_debug, balance]
                if balance <= 0:
                    pending.append(set(tainted))
                    out.append(pending)
                    pending = None
        else:
            pending[1] += " " + code
            pending[3] += paren_balance(code)
            if pending[3] <= 0:
                pending.append(set(tainted))
                out.append(pending)
                pending = None
        index += 1

    if pending is not None:  # unbalanced (multi-line string / macro) — judge what we saw
        pending.append(set(tainted))
        out.append(pending)
    return out


def metadata_entries(statement: str):
    """(key, value) for each entry of every `metadata: [ … ]` literal in a statement.

    A key is either a string literal (`"regionCount"`) or an enum case
    (`.regionCount`), returned with its leading dot so the caller can tell
    the two apart in messages.
    """
    entries = []
    for match in METADATA_LITERAL_RE.finditer(statement):
        start = match.end() - 1
        end = bracket_span(statement, start)
        if end is None:
            continue
        for chunk in top_level_chunks(statement[start + 1:end]):
            key_match = DICT_KEY_RE.match(chunk)
            if not key_match:
                continue
            key = key_match.group(1) if key_match.group(1) is not None \
                else "." + key_match.group(2)
            entries.append((key, chunk[key_match.end():].strip()))
    return entries


def field_values(statement: str, field_re):
    """The value expression after every `errorCode:` / `error_code:` field."""
    values = []
    for match in field_re.finditer(statement):
        rest = statement[match.end():]
        depth, i = 0, 0
        while i < len(rest):
            char = rest[i]
            if char == '"':
                i = _skip_string(rest, i)
                continue
            if char in "([":
                depth += 1
            elif char in ")]":
                if depth == 0:
                    break
                depth -= 1
            elif char == "," and depth == 0:
                break
            i += 1
        values.append(rest[:i].strip())
    return values


def content_bearing_value(value: str):
    """Why an event field value carries content, or None.

    Interpolating a content word, interpolating an error object, rendering a
    description, or using a bare content-worded identifier are the four
    shapes that put text into an event field.
    """
    if STRINGIFY_RE.search(value):
        return "String(describing:)/String(reflecting:) in an event field"
    if DESCRIPTION_RE.search(value):
        return ".localizedDescription/.debugDescription in an event field"
    for body in interpolation_bodies(value):
        if mentions_feature_content(body):
            return "recognized or translated text interpolated into an event field"
        for match in re.finditer(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)", body):
            name = match.group(1)
            if not is_error_identifier(name):
                continue
            rest = body[match.end():].lstrip()
            if rest.startswith("."):
                member = re.match(r"\.([A-Za-z_][A-Za-z0-9_]*)", rest)
                if member and member.group(1) in SAFE_ERROR_MEMBERS:
                    continue
            return "raw error object interpolated into an event field"
    if mentions_feature_content(without_interpolations(value)):
        return "a text value is used as an event field"
    return None


def load_allowed_keys(path: str):
    """The shipped `LogSanitiser.allowedKeys`, read from the source. None if unreadable."""
    try:
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
    except OSError:
        return None
    match = re.search(r"static let allowedKeys:\s*Set<String>\s*=\s*\[(.*?)\n    \]",
                      source, re.S)
    if not match:
        return None
    block = "\n".join(strip_line_comments(line) for line in match.group(1).split("\n"))
    keys = set(re.findall(r'"([^"]+)"', block))
    return keys or None


def judge_console(relative, line_no, text, in_debug, engine, tainted):
    """Rules 1-2: the shipped transcript and raw-error rules. Unchanged."""
    if in_debug:
        return []
    offences = []
    direct = mentions_transcript(text)
    tainted_hit = any(
        re.search(r"(?<![A-Za-z0-9_])" + re.escape(t) + r"\b", text) for t in tainted)
    if direct or tainted_hit:
        offences.append(Violation(
            relative, line_no,
            "transcript-print" if direct else "transcript-taint",
            "transcript content in a print outside #if DEBUG"))
    if engine:
        offence = error_object_offence(text)
        if offence:
            rule, reason = offence
            offences.append(Violation(relative, line_no, rule,
                                      reason + " outside #if DEBUG"))
    return offences


def judge_feature(relative, line_no, text, allowed_keys, in_debug):
    """Rules 3-6: the feature's content family.

    Rule 3 keeps the shipped Release framing (`#if DEBUG` is exempt: the
    region cannot be compiled into Release). Rules 4-6 are judged in every
    configuration — a content-bearing console write or a content-bearing event
    field is a defect in Debug too, and the two rules are therefore
    orthogonal: 3 catches the Release bypass whatever it renders, 4 catches
    content even where 3 cannot look.
    """
    offences = []
    if CALL_RE.search(text):
        if not in_debug:
            offences.append(Violation(
                relative, line_no, "feature-console-write",
                "console write in the feature's sources (route the signal through "
                "the sanitising observability bus)"))
        if mentions_feature_content(text):
            offences.append(Violation(
                relative, line_no, "feature-content-print",
                "recognized or translated text in a console write"))

    for key, _value in metadata_entries(text):
        name = key.lstrip(".")
        if name not in allowed_keys:
            offences.append(Violation(
                relative, line_no, "feature-unlisted-metadata-key",
                f"event metadata key '{name}' is not in LogSanitiser.allowedKeys"))

    values = field_values(text, ERROR_CODE_FIELD_RE)
    values += [value for _key, value in metadata_entries(text)]
    for value in values:
        reason = content_bearing_value(value)
        if reason:
            offences.append(Violation(
                relative, line_no, "feature-text-interpolated-into-event", reason))
            break
    return offences


def judge_metadata_key_enum(relative, source, allowed_keys):
    """Every `LiveTranslateEvents.MetadataKey` case must be allow-listed (AM-2/CL-5)."""
    match = METADATA_KEY_ENUM_RE.search(source)
    if not match:
        return []
    offences = []
    for case in ENUM_CASE_RE.finditer(match.group(1)):
        name = case.group(1)
        if name not in allowed_keys:
            line = source[:match.start(1) + case.start(1)].count("\n") + 1
            offences.append(Violation(
                relative, line, "feature-unlisted-metadata-key",
                f"MetadataKey case '{name}' has no LogSanitiser.allowedKeys entry"))
    return offences


def display_path(path: str, source_root: str) -> str:
    """A readable path: source-root-relative where possible, else project-relative."""
    parent = os.path.dirname(os.path.normpath(source_root))
    if path.startswith(parent + os.sep):
        return os.path.basename(os.path.normpath(source_root)) + "/" + \
            os.path.relpath(path, source_root)
    return os.path.relpath(path, PROJECT_DIR)


def scan(path: str, role: str, allowed_keys, source_root: str):
    """Yield Violations for one Swift file. `role` is "feature", "engine" or "other"."""
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    lines = source.split("\n")
    relative = display_path(path, source_root)

    offences = []
    for line_no, text, in_debug, _balance, tainted in statements(lines, CALL_RE):
        for violation in judge_console(relative, line_no, text, in_debug,
                                       role == "engine", tainted):
            violation.source = lines[line_no - 1].strip() if line_no - 1 < len(lines) else ""
            offences.append(violation)

    if role == "feature":
        for line_no, text, in_debug, _balance, _tainted in statements(lines, FEATURE_OPENER_RE):
            offences.extend(judge_feature(relative, line_no, text, allowed_keys, in_debug))
        offences.extend(judge_metadata_key_enum(relative, source, allowed_keys))
    return offences


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--source-root", default=DEFAULT_SOURCE_ROOT)
    parser.add_argument("--allow-list", default=DEFAULT_ALLOW_LIST)
    parser.add_argument("--require-engine-files", action="store_true")
    parser.add_argument("--list-rules", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument(
        "--disable-rule", action="append", default=[], metavar="RULE-ID",
        help="judge as if RULE-ID had never been declared. This exists for "
             "exactly one caller — the fixture suite's falsification run "
             "(`check-release-log-safety-fixtures.py --falsify`), which proves "
             "each rule is load-bearing by disabling it and watching its "
             "positive fixture stop being caught. It is deliberately "
             "command-line only: no environment variable, config file or "
             "build setting can reach it, so it cannot weaken a build.")
    args = parser.parse_args(argv)

    if args.list_rules:
        for rule_id in RULES:
            print(f"{rule_id}\t{RULES[rule_id]}")
        return 0

    for rule_id in args.disable_rule:
        if rule_id not in RULES:
            print(f"  ✗ '{rule_id}' is not a rule this gate declares "
                  "(a typo here would silently disable nothing)")
            return 1

    source_root = os.path.abspath(args.source_root)
    default_root = os.path.normpath(source_root) == os.path.normpath(DEFAULT_SOURCE_ROOT)
    violations = []

    if not os.path.isdir(source_root):
        print(f"  ✗ [engine-file-missing] no source root at {source_root}")
        return 1

    # Anti-green-by-emptiness: a guarded file that cannot be found fails the
    # gate. Skipped for a fixture tree unless it opts in, so a fixture can
    # exercise the absence itself.
    if default_root or args.require_engine_files:
        for engine in ENGINE_FILES:
            if not os.path.isfile(os.path.join(source_root, engine)):
                label = f"{SOURCE_ROOT_LABEL}/{engine}" if default_root else engine
                print(f"  ✗ [engine-file-missing] guarded engine file is missing: {label}")
                print("    update tools/check-release-log-safety.py deliberately")
                violations.append(Violation(label, 0, "engine-file-missing",
                                            "guarded engine file is missing"))

    allowed_keys = load_allowed_keys(os.path.abspath(args.allow_list))
    if allowed_keys is None:
        print("  ✗ [allow-list-unreadable] the log allow-list could not be read: "
              f"{os.path.relpath(os.path.abspath(args.allow_list), PROJECT_DIR)}")
        print("    update tools/check-release-log-safety.py deliberately")
        violations.append(Violation(os.path.relpath(os.path.abspath(args.allow_list),
                                                    PROJECT_DIR),
                                    0, "allow-list-unreadable",
                                    "the log allow-list could not be read"))

    feature_roots = tuple(os.path.join(source_root, root) for root in FEATURE_ROOTS)
    engine_set = {os.path.join(source_root, engine) for engine in ENGINE_FILES}

    for root, _dirs, files in os.walk(source_root):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            if path in engine_set:
                role = "engine"
            elif any(path == feature or path.startswith(feature + os.sep)
                     for feature in feature_roots):
                role = "feature"
            else:
                role = "other"
            violations.extend(scan(path, role, allowed_keys, source_root))

    if args.disable_rule:
        disabled = set(args.disable_rule)
        violations = [v for v in violations if v.rule not in disabled]

    # One statement can trip several rules; one line per (file, line, rule,
    # message) is reported, as the shipped gate reported one line per offence.
    seen, unique = set(), []
    for violation in violations:
        marker = (violation.path, violation.line, violation.rule, violation.message)
        if marker in seen:
            continue
        seen.add(marker)
        unique.append(violation)
    violations = unique

    if violations:
        for violation in violations:
            if violation.line:
                print(f"{violation.path}:{violation.line}: [{violation.rule}] "
                      f"{violation.message}")
                if violation.source:
                    print(f"    {violation.source}")
            else:
                print(f"  ✗ [{violation.rule}] {violation.message}: {violation.path}")
        print(f"  ✗ {len(violations)} Release-log privacy violation(s) (B1/T-049, AM-5).")
        print("    A transcript, a recognized or translated string, or a raw error object")
        print("    must not be rendered by a print that compiles into Release: wrap it in")
        print("    #if DEBUG, delete it, or route a content-free signal (count/duration/")
        print("    domain+code) through the sanitised observability bus — never the raw")
        print("    content. The feature's sources carry no console write at all, in any")
        print("    configuration, and their event fields are counts, closed tokens or the")
        print("    disclosure version — never a text value.")
        return 1

    if not args.quiet:
        print("  ✓ no transcript content or raw error object can be printed in a non-Debug")
        print("    configuration, and the live-camera-translation sources carry no console")
        print("    write or content-bearing event field")
    return 0


if __name__ == "__main__":
    sys.exit(main())
