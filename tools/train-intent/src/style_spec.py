"""style_spec.py — loader and drift check for the Nepali chat style spec.

The artifact `tools/train-intent/seeds/nepali-chat-style-spec` is the single
source of truth for the Nepali conversational register (register/honorifics,
particle budget, small-talk repertoire, code-switched nouns, forbidden
AI-isms, persona clause, guard-check inputs, eval rubric criteria, coverage
inventory). This module is the ONLY supported way tooling reads it:

  * `load()` parses the artifact, validates it and returns a `StyleSpec`;
  * every section is exposed by name (`section_text`), every machine block by
    name (`block`), and the fields downstream units cite have typed
    accessors (`particle_budget`, `particle_lexicon`, `forbidden_ai_isms`,
    `persona_clause`, `register`, `guard_check_inputs`, ...);
  * the spec reports its `version` and the sha256 of its bytes for run
    evidence (`evidence()`);
  * a missing required section or block raises `StyleSpecError` naming it —
    there is NO default substitution anywhere in this module;
  * the drift check (`check_consumers`) is executable: a consumer that cites
    a spec section between `@style-spec-section:` /
    `@style-spec-section-end:` markers but carries different rule text is
    reported as a defect (consumer + section) and the CLI exits non-zero.

The module is stdlib-only by contract: it runs on the training box
(anjan-ubuntu) as well as locally, so no third-party import may creep in
(JSON is used for the machine blocks because it is a strict subset of YAML
and parses with the standard library alone).

CLI:
    python3 src/style_spec.py                     # print version + hash
    python3 src/style_spec.py --json              # machine-readable evidence
    python3 src/style_spec.py --spec PATH         # point at another artifact
    python3 src/style_spec.py --check-consumers F [F ...]
Exit codes: 0 = ok; 1 = the spec failed to load/validate; 2 = drift defects.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

__all__ = [
    "DEFAULT_SPEC_PATH",
    "REQUIRED_SECTIONS",
    "REQUIRED_BLOCKS",
    "DriftDefect",
    "StyleSpec",
    "StyleSpecError",
    "check_consumer_file",
    "check_consumers",
    "format_defects",
    "load",
    "main",
]

# Resolved relative to this file so the loader works from any cwd.
DEFAULT_SPEC_PATH = (
    Path(__file__).resolve().parent.parent / "seeds" / "nepali-chat-style-spec"
)

# The sections every consumer may count on. A spec missing any of these does
# not load — no default is substituted for a missing section, ever.
REQUIRED_SECTIONS: Tuple[str, ...] = (
    "register",
    "particles",
    "sentence_shape",
    "small_talk",
    "code_switch",
    "ai_isms",
    "persona_clause",
    "rubric",
    "guard_checks",
    "coverage",
)

# section -> the machine block(s) it must carry (persona_clause is prose-only:
# the clause text itself is the section's rule text).
REQUIRED_BLOCKS: Dict[str, Tuple[str, ...]] = {
    "register": ("register",),
    "particles": ("particles",),
    "sentence_shape": ("sentence_shape",),
    "small_talk": ("small_talk",),
    "code_switch": ("code_switch",),
    "ai_isms": ("ai_isms",),
    "persona_clause": (),
    "rubric": ("rubric",),
    "guard_checks": ("guard_checks",),
    "coverage": ("coverage",),
}

_SECTION_MARKER_RE = re.compile(r"^## section: ([a-z0-9_]+)[ \t]*$")
_BLOCK_OPEN_RE = re.compile(r"^```json[ \t]+([a-z0-9_]+)[ \t]*$")
_BLOCK_CLOSE_RE = re.compile(r"^```[ \t]*$")
_VERSION_RE = re.compile(r"^style_spec_version:[ \t]*(\S+)[ \t]*$")

# Citation markers a consumer writes around rule text it mirrors. The prefix
# group accepts the comment tokens of the languages the consumers live in.
_CITATION_BEGIN_RE = re.compile(
    r"^[ \t]*(?P<prefix>///|//|/\*|#|\*)?[ \t]*@style-spec-section:[ \t]*"
    r"(?P<name>[a-z0-9_]+)[ \t]*(?:\*/)?[ \t]*$"
)
_CITATION_END_RE = re.compile(
    r"^[ \t]*(?P<prefix>///|//|/\*|#|\*)?[ \t]*@style-spec-section-end:[ \t]*"
    r"(?P<name>[a-z0-9_]+)[ \t]*(?:\*/)?[ \t]*$"
)

# Ordered longest-first: the first token a line starts with wins.
_COMMENT_TOKENS: Tuple[str, ...] = ("///", "//", "/*", "#", "*")


class StyleSpecError(Exception):
    """A style-spec failure that must stop the caller (never a default)."""


class DriftDefect:
    """One consumer/section drift finding reported by the traceability check."""

    __slots__ = ("consumer", "section", "line", "kind", "detail")

    def __init__(self, consumer: str, section: str, line: int, kind: str,
                 detail: str = "") -> None:
        self.consumer = consumer
        self.section = section
        self.line = line
        self.kind = kind          # drift | unknown_section | unterminated | prefix_mismatch
        self.detail = detail

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return (f"DriftDefect(consumer={self.consumer!r}, section={self.section!r}, "
                f"line={self.line}, kind={self.kind!r})")

    def __str__(self) -> str:
        head = f"DEFECT consumer={self.consumer} line={self.line} section={self.section}: "
        if self.kind == "unknown_section":
            return head + "cited section does not exist in the style spec"
        if self.kind == "unterminated":
            return head + "citation block has no @style-spec-section-end marker"
        if self.kind == "prefix_mismatch":
            return head + ("citation block mixes comment prefixes; every non-blank "
                           "content line must share one prefix (or none)")
        return head + ("cited rule text differs from the style spec section"
                       + (f" ({self.detail})" if self.detail else ""))


class StyleSpec:
    """A loaded, validated style spec. Construct through :func:`load`."""

    def __init__(self, path: Path, version: str, sha256: str,
                 sections: Dict[str, str], blocks: Dict[str, Dict[str, Any]],
                 section_order: Sequence[str], block_order: Sequence[str]) -> None:
        self.path = path
        self.version = version
        self.sha256 = sha256
        self._sections = dict(sections)
        self._blocks = dict(blocks)
        self._section_order = tuple(section_order)
        self._block_order = tuple(block_order)

    # -- metadata -----------------------------------------------------------

    def evidence(self) -> Dict[str, str]:
        """The version + content hash record for run evidence."""
        return {"path": str(self.path), "version": self.version, "sha256": self.sha256}

    def section_names(self) -> Tuple[str, ...]:
        return self._section_order

    def block_names(self) -> Tuple[str, ...]:
        return self._block_order

    # -- raw section / block access ----------------------------------------

    def section_text(self, name: str) -> str:
        """The rule text of `name` — the text a consumer mirrors byte-exactly."""
        if name not in self._sections:
            raise StyleSpecError(
                f"style spec has no section '{name}' "
                f"(sections: {', '.join(self._section_order)})")
        return self._sections[name]

    def block(self, name: str) -> Dict[str, Any]:
        """A machine block by name, as a fresh copy."""
        if name not in self._blocks:
            raise StyleSpecError(
                f"style spec has no machine block '{name}' "
                f"(blocks: {', '.join(self._block_order)})")
        return copy.deepcopy(self._blocks[name])

    # -- typed accessors (the interface downstream units cite) --------------

    def register(self) -> Dict[str, Any]:
        return self._typed_block("register", "register")

    def particle_budget(self) -> int:
        data = self._require_fields("particles", "particles", ("budget",))
        budget = data["budget"]
        if isinstance(budget, bool) or not isinstance(budget, int) or budget < 0:
            raise StyleSpecError(
                "section 'particles': field 'budget' must be a non-negative integer, "
                f"got {budget!r}")
        return budget

    def particle_lexicon(self) -> Tuple[str, ...]:
        data = self._require_fields("particles", "particles", ("units",))
        return self._string_tuple("particles", "particles", "units", data["units"])

    def respectful_forms(self) -> Tuple[str, ...]:
        """Composed from the register block's single origins (no duplication):
        the attention marker, the address pronoun and every honorific partner."""
        register = self.register()
        for field in ("attention_marker", "address_pronoun", "honorific_pairs"):
            if field not in register:
                raise StyleSpecError(
                    f"section 'register': machine block 'register' is missing "
                    f"required field '{field}' (no default is substituted)")
        forms: List[str] = [str(register["attention_marker"]),
                            str(register["address_pronoun"])]
        pairs = register["honorific_pairs"]
        if not isinstance(pairs, list):
            raise StyleSpecError(
                "section 'register': field 'honorific_pairs' must be a list of "
                "[familiar, honorific] pairs")
        for pair in pairs:
            if not isinstance(pair, list) or len(pair) != 2:
                raise StyleSpecError(
                    f"section 'register': 'honorific_pairs' entry is not a "
                    f"[familiar, honorific] pair: {pair!r}")
            forms.append(str(pair[1]))
        seen: Dict[str, None] = {}
        for form in forms:
            seen.setdefault(form, None)
        return tuple(seen)

    def sentence_shape(self) -> Dict[str, Any]:
        return self._typed_block("sentence_shape", "sentence_shape")

    def small_talk_topics(self) -> Tuple[Dict[str, Any], ...]:
        data = self._require_fields("small_talk", "small_talk", ("topics",))
        topics = data["topics"]
        if not isinstance(topics, list) or not topics:
            raise StyleSpecError(
                "section 'small_talk': field 'topics' must be a non-empty list")
        return tuple(copy.deepcopy(topic) for topic in topics)

    def code_switch_nouns(self) -> Tuple[Dict[str, Any], ...]:
        data = self._require_fields("code_switch", "code_switch", ("nouns",))
        nouns = data["nouns"]
        if not isinstance(nouns, list) or not nouns:
            raise StyleSpecError(
                "section 'code_switch': field 'nouns' must be a non-empty list")
        return tuple(copy.deepcopy(noun) for noun in nouns)

    def forbidden_ai_isms(self) -> Tuple[Dict[str, Any], ...]:
        data = self._require_fields("ai_isms", "ai_isms", ("forbidden",))
        forbidden = data["forbidden"]
        if not isinstance(forbidden, list) or not forbidden:
            raise StyleSpecError(
                "section 'ai_isms': field 'forbidden' must be a non-empty list")
        return tuple(copy.deepcopy(entry) for entry in forbidden)

    def persona_clause(self) -> str:
        """The canonical clause both personas embed byte-identically."""
        return self.section_text("persona_clause")

    def rubric_criteria(self) -> Dict[str, Any]:
        return self._typed_block("rubric", "rubric")

    def guard_checks(self) -> Dict[str, Any]:
        return self._typed_block("guard_checks", "guard_checks")

    def coverage_classes(self) -> Tuple[Dict[str, Any], ...]:
        data = self._require_fields("coverage", "coverage", ("classes",))
        classes = data["classes"]
        if not isinstance(classes, list) or not classes:
            raise StyleSpecError(
                "section 'coverage': field 'classes' must be a non-empty list")
        return tuple(copy.deepcopy(entry) for entry in classes)

    def guard_check_inputs(self) -> Dict[str, Any]:
        """The guard's executable inputs, composed from their single origins.

        The lexicons are not restated in `guard_checks`: honorific agreement
        reads the register block, the particle check the particles block and
        the code-switch allowance the code_switch block. This composition is
        what makes "the same section is the only origin" a property of the
        loader rather than a review note.
        """
        register = self.register()
        for field in ("forbidden_address_forms", "non_honorific_verb_forms",
                      "honorific_pairs"):
            if field not in register:
                raise StyleSpecError(
                    f"section 'register': machine block 'register' is missing "
                    f"required field '{field}' (no default is substituted)")
        checks = self.guard_checks()
        latin_allowlist = checks.get("latin_allowlist")
        if not isinstance(latin_allowlist, list):
            raise StyleSpecError(
                "section 'guard_checks': field 'latin_allowlist' must be a list "
                "(empty by default, never omitted)")
        return {
            "honorificAgreement": {
                "forbidden_address_forms": tuple(register["forbidden_address_forms"]),
                "non_honorific_verb_forms": tuple(register["non_honorific_verb_forms"]),
                "honorific_pairs": tuple(
                    tuple(pair) for pair in register["honorific_pairs"]),
            },
            "devanagariPurity": {
                "latin_allowlist": tuple(latin_allowlist),
                "code_switch_nouns": self.code_switch_nouns(),
            },
            "danglingParticle": {
                "particle_lexicon": self.particle_lexicon(),
                "particle_budget": self.particle_budget(),
            },
        }

    # -- internals ----------------------------------------------------------

    def _typed_block(self, section: str, block_name: str) -> Dict[str, Any]:
        self._require_fields(section, block_name, ())
        return copy.deepcopy(self._blocks[block_name])

    def _require_fields(self, section: str, block_name: str,
                        fields: Sequence[str]) -> Dict[str, Any]:
        if block_name not in self._blocks:
            raise StyleSpecError(
                f"section '{section}': required machine block '{block_name}' is "
                f"missing from the style spec")
        data = self._blocks[block_name]
        for field in fields:
            if field not in data:
                raise StyleSpecError(
                    f"section '{section}': machine block '{block_name}' is missing "
                    f"required field '{field}' (no default is substituted)")
        return data

    def _string_tuple(self, section: str, block_name: str, field: str,
                      value: Any) -> Tuple[str, ...]:
        if not isinstance(value, list) or not value:
            raise StyleSpecError(
                f"section '{section}': field '{field}' must be a non-empty list "
                f"of strings, got {value!r}")
        for item in value:
            if not isinstance(item, str) or not item:
                raise StyleSpecError(
                    f"section '{section}': field '{field}' carries a non-string "
                    f"entry: {item!r}")
        return tuple(value)


# ---------------------------------------------------------------------------
# Loading and validation
# ---------------------------------------------------------------------------

def load(path: Optional[Union[str, Path]] = None) -> StyleSpec:
    """Load and validate the style spec (default: the seeds artifact).

    Raises `StyleSpecError` naming the offending section/block/field for any
    structural problem. There is no tolerant mode and no default value.
    """
    spec_path = Path(path) if path is not None else DEFAULT_SPEC_PATH
    spec_path = spec_path.expanduser().resolve()
    if not spec_path.is_file():
        raise StyleSpecError(f"style spec not found: {spec_path}")
    raw = spec_path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise StyleSpecError(
            f"style spec is not valid UTF-8: {spec_path} ({exc})") from exc

    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")

    header: List[str] = []
    section_order: List[str] = []
    sections: Dict[str, str] = {}
    block_order: List[str] = []
    blocks: Dict[str, Dict[str, Any]] = {}

    current: Optional[str] = None
    prose: List[Tuple[int, str]] = []

    def commit(prose_lines: List[Tuple[int, str]], name: Optional[str]) -> None:
        if name is None:
            return
        for line_no, line in prose_lines:
            if line != line.rstrip():
                raise StyleSpecError(
                    f"section '{name}': line {line_no} carries trailing whitespace; "
                    "rule text must be mirrorable byte-exactly")
        sections[name] = "\n".join(line for _, line in prose_lines).strip("\n")

    index = 0
    total = len(lines)
    while index < total:
        line = lines[index]
        marker = _SECTION_MARKER_RE.match(line)
        if marker:
            commit(prose, current)
            current = marker.group(1)
            if current in sections:
                raise StyleSpecError(
                    f"style spec defines section '{current}' twice "
                    f"(line {index + 1})")
            section_order.append(current)
            prose = []
            index += 1
            continue
        if current is None:
            header.append(line)
            index += 1
            continue
        if line.startswith("```"):
            opener = _BLOCK_OPEN_RE.match(line)
            if opener is None:
                raise StyleSpecError(
                    f"section '{current}': malformed machine-block fence on "
                    f"line {index + 1}: {line!r} (expected ```json <block-name>)")
            block_name = opener.group(1)
            body: List[str] = []
            index += 1
            while index < total and not _BLOCK_CLOSE_RE.match(lines[index]):
                body.append(lines[index])
                index += 1
            if index >= total:
                raise StyleSpecError(
                    f"section '{current}': machine block '{block_name}' is never "
                    "closed (missing ``` line)")
            index += 1  # consume the closing fence
            try:
                data = json.loads("\n".join(body))
            except json.JSONDecodeError as exc:
                raise StyleSpecError(
                    f"section '{current}': machine block '{block_name}' is not "
                    f"valid JSON ({exc})") from exc
            if not isinstance(data, dict):
                raise StyleSpecError(
                    f"section '{current}': machine block '{block_name}' must be a "
                    f"JSON object, got {type(data).__name__}")
            if block_name in blocks:
                raise StyleSpecError(
                    f"machine block '{block_name}' is defined twice in the style spec")
            blocks[block_name] = data
            block_order.append(block_name)
            continue
        prose.append((index + 1, line))
        index += 1
    commit(prose, current)

    version_lines = [line for line in header if _VERSION_RE.match(line)]
    if not version_lines:
        raise StyleSpecError(
            f"style spec {spec_path} has no `style_spec_version:` line in its "
            "header (before the first `## section:` marker)")
    if len(version_lines) > 1:
        raise StyleSpecError(
            f"style spec {spec_path} declares `style_spec_version:` more than once")
    version = _VERSION_RE.match(version_lines[0]).group(1)  # type: ignore[union-attr]

    missing = [name for name in REQUIRED_SECTIONS if name not in sections]
    if missing:
        raise StyleSpecError(
            f"style spec {spec_path} is missing required section(s): "
            + ", ".join(missing)
            + " (no default is substituted for a missing section)")

    missing_blocks: List[str] = []
    for name in REQUIRED_SECTIONS:
        for block_name in REQUIRED_BLOCKS.get(name, ()):
            if block_name not in blocks:
                missing_blocks.append(f"{name}:{block_name}")
    if missing_blocks:
        raise StyleSpecError(
            f"style spec {spec_path} is missing required machine block(s): "
            + ", ".join(missing_blocks)
            + " (no default is substituted for a missing block)")

    for name in REQUIRED_SECTIONS:
        if not sections[name].strip():
            raise StyleSpecError(
                f"section '{name}' carries no rule text; a required section with "
                "no prose cannot be mirrored by a consumer")

    _validate_particles_block(blocks["particles"])
    _validate_persona_clause(sections["persona_clause"])

    return StyleSpec(spec_path, version, digest, sections, blocks,
                     section_order, block_order)


def _validate_particles_block(particles: Dict[str, Any]) -> None:
    budget = particles.get("budget")
    if isinstance(budget, bool) or not isinstance(budget, int) or budget < 0:
        raise StyleSpecError(
            "section 'particles': field 'budget' must be a non-negative integer, "
            f"got {budget!r}")
    units = particles.get("units")
    if not isinstance(units, list) or not units or not all(isinstance(u, str) and u for u in units):
        raise StyleSpecError(
            "section 'particles': field 'units' must be a non-empty list of strings")
    key = lambda unit: (-len(unit.split()), -len(unit))  # noqa: E731 - tiny sort key
    if list(units) != sorted(units, key=key):
        raise StyleSpecError(
            "section 'particles': field 'units' must be ordered longest-match-first "
            "(word count then character count, descending); the guard and the eval "
            "tokenizer depend on this order")


def _validate_persona_clause(clause: str) -> None:
    normalized = " ".join(clause.split())
    if "\n" in clause:
        raise StyleSpecError(
            "section 'persona_clause': the canonical clause must be a single "
            "paragraph so both personas can embed it byte-identically")
    if not normalized:
        raise StyleSpecError("section 'persona_clause': the canonical clause is empty")


# ---------------------------------------------------------------------------
# Drift check (executable traceability)
# ---------------------------------------------------------------------------

def _content_token(line: str) -> str:
    stripped = line.lstrip(" \t")
    for token in _COMMENT_TOKENS:
        if stripped.startswith(token):
            return token
    return ""


def _normalize_citation_content(lines: Sequence[str], consumer: str, name: str,
                                line_no: int) -> Tuple[str, Optional[DriftDefect]]:
    """Strip the consumer's uniform comment prefix, or take content verbatim."""
    first_token: Optional[str] = None
    for line in lines:
        if line.strip():
            first_token = _content_token(line)
            break
    if first_token is None:
        return "", None  # blank citation: compared as the empty string
    out: List[str] = []
    for line in lines:
        if not line.strip():
            out.append("")
            continue
        if first_token and not line.lstrip(" \t").startswith(first_token):
            defect = DriftDefect(
                consumer, name, line_no, "prefix_mismatch",
                f"line {line_no + 1}: {line!r}")
            return "", defect
        if not first_token:
            out.append(line)
            continue
        stripped = line.lstrip(" \t")[len(first_token):]
        if stripped.startswith(" "):
            stripped = stripped[1:]
        out.append(stripped)
    return "\n".join(out).strip("\n"), None


def _first_difference(cited: str, expected: str) -> str:
    cited_lines = cited.split("\n")
    expected_lines = expected.split("\n")
    for index, (left, right) in enumerate(zip(cited_lines, expected_lines), start=1):
        if left != right:
            return f"first difference at line {index}"
    return (f"cited {len(cited_lines)} line(s) vs spec {len(expected_lines)} line(s)")


def check_consumer_file(consumer_path: Union[str, Path],
                        spec: StyleSpec) -> List[DriftDefect]:
    """Compare every cited spec section in one consumer file with the spec."""
    consumer = Path(consumer_path)
    if not consumer.is_file():
        raise StyleSpecError(f"consumer file not found: {consumer}")
    text = consumer.read_text(encoding="utf-8")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")

    defects: List[DriftDefect] = []
    index = 0
    total = len(lines)
    while index < total:
        begin = _CITATION_BEGIN_RE.match(lines[index])
        if not begin:
            index += 1
            continue
        name = begin.group("name")
        line_no = index + 1
        body: List[str] = []
        index += 1
        end_found = False
        while index < total:
            end = _CITATION_END_RE.match(lines[index])
            if end:
                if end.group("name") != name:
                    defects.append(DriftDefect(
                        str(consumer), name, line_no, "unterminated",
                        f"end marker names '{end.group('name')}'"))
                    break
                end_found = True
                index += 1
                break
            # A nested begin marker means the previous block never closed.
            if _CITATION_BEGIN_RE.match(lines[index]):
                defects.append(DriftDefect(
                    str(consumer), name, line_no, "unterminated",
                    f"a new citation begins at line {index + 1}"))
                break
            body.append(lines[index])
            index += 1
        if not end_found:
            if index >= total:
                defects.append(DriftDefect(
                    str(consumer), name, line_no, "unterminated",
                    "end of file reached"))
            continue
        if name not in spec.section_names():
            defects.append(DriftDefect(str(consumer), name, line_no,
                                       "unknown_section"))
            continue
        cited_text, prefix_defect = _normalize_citation_content(
            body, str(consumer), name, line_no)
        if prefix_defect is not None:
            defects.append(prefix_defect)
            continue
        expected = spec.section_text(name)
        if cited_text != expected:
            defects.append(DriftDefect(
                str(consumer), name, line_no, "drift",
                _first_difference(cited_text, expected)))
    return defects


def check_consumers(paths: Sequence[Union[str, Path]],
                    spec: Optional[StyleSpec] = None) -> List[DriftDefect]:
    """Run the drift check over consumer files; returns all defects found."""
    resolved = spec if spec is not None else load()
    defects: List[DriftDefect] = []
    for path in paths:
        defects.extend(check_consumer_file(path, resolved))
    return defects


def format_defects(defects: Sequence[DriftDefect]) -> str:
    return "\n".join(str(defect) for defect in defects)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="style_spec.py",
        description="Load the Nepali chat style spec, or run the consumer "
                    "drift check.")
    parser.add_argument("--spec", default=None,
                        help="path to the style spec (default: the seeds artifact)")
    parser.add_argument("--check-consumers", nargs="+", metavar="FILE",
                        default=None,
                        help="consumer files whose cited rule text is compared "
                             "with the spec section they cite")
    parser.add_argument("--json", action="store_true",
                        help="print the evidence record as JSON")
    args = parser.parse_args(argv)

    try:
        spec = load(args.spec)
    except StyleSpecError as exc:
        print(f"style-spec error: {exc}", file=sys.stderr)
        return 1

    if args.check_consumers:
        defects = check_consumers(args.check_consumers, spec)
        if defects:
            print(format_defects(defects), file=sys.stderr)
            print(f"style-spec drift check: {len(defects)} defect(s) across "
                  f"{len(args.check_consumers)} consumer file(s); "
                  f"version={spec.version} sha256={spec.sha256}", file=sys.stderr)
            return 2
        print(f"style-spec drift check: clean ({len(args.check_consumers)} "
              f"consumer file(s)); version={spec.version} sha256={spec.sha256}")
        return 0

    if args.json:
        evidence = spec.evidence()
        record = {
            "path": evidence["path"],
            "version": evidence["version"],
            "sha256": evidence["sha256"],
            "sections": list(spec.section_names()),
            "blocks": list(spec.block_names()),
        }
        print(json.dumps(record, ensure_ascii=False, indent=2))
    else:
        print(f"style-spec version={spec.version} sha256={spec.sha256} "
              f"path={spec.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
