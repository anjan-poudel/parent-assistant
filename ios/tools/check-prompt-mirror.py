#!/usr/bin/env python3
"""check-prompt-mirror.py — training/inference prompt-identity gate
(T-094, C08; [CNR] T-170 extends it with the chat discipline).

`IntentPrompt.build`'s multiline literal is the SOURCE OF TRUTH for the
on-device brain prompt; `tools/train-intent/seeds/prompt_template.txt` is its
mirror, tokenized raw by the QLoRA fine-tune and the golden-corpus eval. The
two had drifted apart once before (the seed still taught the pre-2026-09
`action`/`reply` wire shape), which is the training/inference mismatch the
identity contract exists to prevent. This gate makes that drift a build
failure instead of a training-time surprise.

What it checks, in order:

  1. extract `build`'s multiline literal from
     `Services/Voice/IntentPrompt.swift` with Swift's multiline-literal
     semantics (dedent by the closing delimiter's indentation; the newline
     immediately preceding the closing delimiter is not part of the value);
  2. each of the four interpolation sources appears EXACTLY once in the
     literal — missing or duplicated is a loud failure, never a partial pass:
       \\(context.userLanguageHint)  ->  {language_hint}
       \\(meds)                      ->  {medications}
       \\(transcript)                ->  {transcript}
       \\(addressAsClause(context.addressAs))  ->  {address_as_clause}
  3. normalize by replacing those sources with their placeholders;
  4. the seed contains each placeholder EXACTLY once;
  5. byte equality between the normalized Swift template and the seed.

[CNR] T-170 adds five more, all byte-identity (design-l1 §6.3):

  6. the PINNED INTENT PROMPT is asserted untouched: the seed, rendered by
     the training suite's own renderer (`tools/train-intent/src/intent_prompt.py`
     with its documented defaults), reproduces BOTH digest pins recorded in
     `IntentPromptTests` — "the pre-change intent prompt, its seed mirror and
     its pin" of FR-CNR-023. Nothing here re-pins: these ARE the shipped
     pins, and this gate fails if they stop matching.
  7. `tools/train-intent/seeds/chat_prompt_template.txt` ↔
     `IntentPrompt.buildChat` — the same mechanism, with the chat template's
     three interpolations (`{language_hint}`, `{address_as_clause}`,
     `{transcript}`).
  8. BOTH persona constants embed the style spec's `persona_clause`
     byte-identically as their final line, exactly once, inside their own
     minimal transport wrapper: the local chat system prompt
     (`LlamaCommandInterpreter.chatPersonaSystemPrompt`) and the cloud system
     instruction (`GeminiCommandInterpreter.replyPersona`).
  9. the guard's four embedded machine blocks (`NepaliGrammarGuard.swift`,
     `// @style-spec-block:` regions) equal the style spec's fenced block
     bodies byte-for-byte: `register` (the honorific lexicons), `particles`
     (the particle budget + lexicon), `code_switch` and `guard_checks`.
 10. the chat token budget (NFR-CNR-004): a conservative, documented ESTIMATE
     of the worst-case prompt side (local persona + the chat template at the
     personalization bound) must fit the prompt side's share of the
     1,024-token context (1,024 minus the 512-token turn/reply allowance
     recorded by `build_chat_corpus.TURN_TOKEN_CEILING`). The margin is
     printed — T-186's sweep reads it from this output.

The style spec and the training renderer are read through their own modules
(`tools/train-intent/src/style_spec.py`, `…/intent_prompt.py`) rather than by
a second parser here: both are stdlib-only, and reading the artifact through
the loader keeps exactly ONE parser for it (a checker with its own reader
would be the fork FR-CNR-001 forbids). The spec's raw block BYTES are
extracted here with the loader's own fence rules, and the extraction is
cross-checked against `style_spec.load()`'s parse so the two can never
disagree silently.

REGENERATION (the ONE path for a legitimate chat-template change): edit
`IntentPrompt.buildChat` first — it is the source of truth — then regenerate
its seed and re-run this gate:

    python3 ios/tools/check-prompt-mirror.py --regen-chat-seed

(`--regen-chat-seed` writes `tools/train-intent/seeds/chat_prompt_template.txt`
byte-exactly from the builder's literal; never hand-edit the seed.) The
intent prompt follows the same rule: edit `IntentPrompt.build` and
`seeds/prompt_template.txt` in the SAME change — and if that change is ever
legitimate, its recorded pin moves with it, explicitly, in one change.

Failure modes are loud: extraction failure, missing/duplicated interpolation,
missing/duplicated placeholder, any byte mismatch, a persona clause that
drifted or lost its wrapper, a guard block that no longer matches the spec, or
a budget overrun exits non-zero naming BOTH files and the differing line.
There is no pass-by-default.

Recorded history (design-l2 §9.2 / §13 item 3): the checker's first run
found the seed ending `request.\\n\\n` against the template's `request.\\n`
(2,699 vs 2,698 bytes after normalization); the T-094 change removed the
seed's extra newline and added the `{address_as_clause}` placeholder
(19 bytes — the design's "18-byte" line is off by one), netting a
2,717-byte mirror, making `render_prompt(..., address_as_clause="")`
byte-identical to the pre-feature rendered prompt.

Exit 0 = mirrored, 1 = drift (or a self-test failure).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, List, NamedTuple, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
VOICE_DIR = REPO_ROOT / "ios" / "ElderlyAssistant" / "Services" / "Voice"
SEEDS_DIR = REPO_ROOT / "tools" / "train-intent" / "seeds"
TRAIN_SRC = REPO_ROOT / "tools" / "train-intent" / "src"

DEFAULT_SWIFT = VOICE_DIR / "IntentPrompt.swift"
DEFAULT_SEED = SEEDS_DIR / "prompt_template.txt"
DEFAULT_CHAT_SEED = SEEDS_DIR / "chat_prompt_template.txt"
DEFAULT_STYLE_SPEC = SEEDS_DIR / "nepali-chat-style-spec"
DEFAULT_LLAMA = VOICE_DIR / "LlamaCommandInterpreter.swift"
DEFAULT_GEMINI = VOICE_DIR / "GeminiCommandInterpreter.swift"
DEFAULT_GUARD = VOICE_DIR / "NepaliGrammarGuard.swift"

# The intent prompt (T-094 — unchanged by [CNR] T-170). Ordered so the
# replacement cannot shadow a longer source: the address clause source
# contains `context.addressAs`, nothing else does.
INTERPOLATIONS = (
    ("\\(context.userLanguageHint)", "{language_hint}"),
    ("\\(meds)", "{medications}"),
    ("\\(transcript)", "{transcript}"),
    ("\\(addressAsClause(context.addressAs))", "{address_as_clause}"),
)
PLACEHOLDERS = tuple(placeholder for _, placeholder in INTERPOLATIONS)

# The chat template ([CNR] T-170; design-l1 §6.3 (a)): the same mechanism,
# three placeholders. `pendingMedications` is deliberately NOT rendered by
# `buildChat` (a chat turn executes nothing), so its placeholder is absent.
CHAT_INTERPOLATIONS = (
    ("\\(context.userLanguageHint)", "{language_hint}"),
    ("\\(addressAsClause(context.addressAs))", "{address_as_clause}"),
    ("\\(transcript)", "{transcript}"),
)
CHAT_PLACEHOLDERS = tuple(placeholder for _, placeholder in CHAT_INTERPOLATIONS)

# The two digest pins `IntentPromptTests` records for the pre-feature build()
# composition ("verified 2026-10-05 against the shipped template + seed";
# private constants `weatherNoTermDigest` / `defaultNoTermDigest`). This gate
# does NOT re-pin them: it asserts the shipped seed + the training renderer
# still reproduce them. A legitimate future intent-prompt change moves the
# Swift pins and these values together, in one explicit change — the drift
# this check exists to refuse is the silent one.
INTENT_PIN_FIXTURES = (
    ("test transcript",
     "18003dddc2a0c16d6fab3be7ffb0f2d93802e1a161f54e05e98a7f33f24b8b78"),
    ("भोलिको मौसम कस्तो छ?",
     "bd47910d74d5c10d2ad889e1bb9a6f1e6093b59bb8fb7f03bb765f8f016e00ff"),
)

# The guard's embedded spec blocks ([CNR] T-169/T-170; design-l1 §6.2's
# "grammar guard" row): every lexicon the guard executes is one of these
# bytes, so mirroring all four covers the particle budget/lexicon, the
# honorific tables, the code-switch renderings and the check inventory.
GUARD_BLOCK_NAMES = ("register", "particles", "code_switch", "guard_checks")

# The guard's block markers — the same `//`-commented form T-169 ships.
GUARD_BLOCK_BEGIN = "// @style-spec-block: {}"
GUARD_BLOCK_END = "// @style-spec-block-end: {}"

# The spec's fenced machine-block syntax (the fence rules of
# `style_spec.py`'s `_BLOCK_OPEN_RE` / `_BLOCK_CLOSE_RE`; kept in sync and
# cross-checked against the loader's parse in `check_guard_blocks`).
SPEC_BLOCK_OPEN_RE = re.compile(r"^```json[ \t]+([a-z0-9_]+)[ \t]*$")
SPEC_BLOCK_CLOSE_RE = re.compile(r"^```[ \t]*$")

# --- the chat token budget (NFR-CNR-004) -----------------------------------

#: The on-device runtime's context window (`LLM(from:maxTokenCount: 1024)`).
CHAT_CONTEXT_TOKENS = 1024
#: The turn's share of the window: the chat corpus admits a turn only when its
#: context + user text + reply stay at or under HALF the context
#: (`build_chat_corpus.TURN_TOKEN_CEILING = 512`); the other half must hold
#: the system text, the chat template and generation headroom. The budget
#: check asserts the prompt side fits its half.
CHAT_TURN_ALLOWANCE_TOKENS = 512
#: Deliberately CONSERVATIVE characters-per-token for the estimate below:
#: Devanagari runs roughly one token per two characters on the
#: extended-tokenizer base (the corpus builder's own CHARS_PER_TOKEN), and
#: everything else is charged at 3 — tighter than the recorded reference
#: measurement (the weather-fixture intent prompt measures 2,540 scalars /
#: 2,506 Swift Characters = 696 qwen3 / 677 gemma tokens, i.e. ~3.65
#: scalars/token; this estimator scores that same prompt at ~861), so the
#: estimate OVER-counts tokens. It is a guard, not a meter: the
#: exact-tokenizer leg is T-167's Character ceiling in the Swift suite and
#: T-186's sweep.
CHARS_PER_TOKEN_DEVANAGARI = 2
CHARS_PER_TOKEN_OTHER = 3
#: The address clause's shipped shape (`IntentPrompt.addressAsClause`), with
#: the term as the one slot. Its empty-term render is exactly the 56-Character
#: static half `IntentPromptTests` pins; the term is bounded at 24 Characters
#: (`ProfilePromptTextGuard`), so the worst-case clause is 56 + 24 = 80.
ADDRESS_CLAUSE_SHAPE = ' Address them as "{}" where it fits, never every sentence.'
ADDRESS_CLAUSE_STATIC_CHARACTERS = 56
ADDRESS_CLAUSE_TERM_CHARACTERS = 24
ADDRESS_CLAUSE_MAX_CHARACTERS = 80


class Drift(Exception):
    """A named, loud failure — never caught past main()."""


class Tree(NamedTuple):
    """The seven artifacts the gate reads, as one addressable set."""

    swift: Path
    seed: Path
    chat_seed: Path
    llama: Path
    gemini: Path
    guard: Path
    spec: Path

    def copy_to(self, root: Path) -> "Tree":
        """Copy every artifact into `root` (the self-test's temp tree)."""
        return Tree(*(_copy_file(path, root) for path in self))


def _copy_file(path: Path, root: Path) -> Path:
    destination = root / path.name
    shutil.copyfile(path, destination)
    return destination


# ---------------------------------------------------------------------------
# Swift multiline-literal extraction (the intent path's semantics, unchanged)

def _literal_value(lines: List[str], open_index: int, close_index: int,
                   what: str) -> str:
    """The Swift value of a `\"\"\"` literal, per Swift semantics.

    Every non-empty content line must carry the closing delimiter's
    indentation (Swift requires it); the value is the dedented lines joined by
    newline — the newline immediately preceding the closing delimiter is
    therefore not part of the value, exactly as the compiler defines it.
    """
    closing = lines[close_index]
    indent = closing[:len(closing) - len(closing.lstrip())]

    content = []
    for line in lines[open_index + 1:close_index]:
        if line.strip() == "":
            content.append("")
            continue
        if not line.startswith(indent):
            raise Drift(
                f"{what}: extraction failed: a content line is indented less "
                "than the closing delimiter — Swift would not compile this "
                f"literal; offending line: {line!r}")
        content.append(line[len(indent):])
    return "\n".join(content)


def extract_build_literal(source: str) -> str:
    """The Swift value of `build`'s multiline literal, per Swift semantics.

    Locates `static func build(` then the first `return \"\"\"` after it and
    the next bare `\"\"\"` line. (T-094's extraction, verbatim: the intent
    path of this gate is untouched by [CNR] T-170.)
    """
    lines = source.split("\n")
    try:
        func_index = next(i for i, line in enumerate(lines)
                          if "static func build(" in line)
    except StopIteration:
        raise Drift("`static func build(` not found in IntentPrompt.swift")

    try:
        open_index = next(i for i in range(func_index, len(lines))
                          if lines[i].strip() == 'return """')
    except StopIteration:
        raise Drift("build()'s `return \"\"\"` multiline literal not found")

    try:
        close_index = next(i for i in range(open_index + 1, len(lines))
                           if lines[i].strip() == '"""')
    except StopIteration:
        raise Drift("the closing `\"\"\"` of build()'s literal not found")

    return _literal_value(lines, open_index, close_index, "build()'s literal")


def literal_line_range(lines: List[str], function_anchor: str) -> Tuple[int, int]:
    """The (open, close) line indexes of a function's `return \"\"\"` literal.

    The delimiters' lines, so the CONTENT lines are `open + 1 … close - 1`:
    the region a line-scoped mutation must stay inside. Necessary because the
    same source line can occur in SEVERAL literals — `User said:
    "\\(transcript)"` sits in both `build` and `buildChat` — so a file-wide
    first-occurrence replace can land in a DIFFERENT function's literal and
    the targeted check will rightly keep passing (the wave-close rework
    failure of 2026-10-14: the chat leg's duplication class was uncovered
    exactly this way).
    """
    try:
        func_index = next(i for i, line in enumerate(lines)
                          if function_anchor in line)
    except StopIteration:
        raise Drift(f"`{function_anchor}` not found")

    try:
        open_index = next(i for i in range(func_index, len(lines))
                          if lines[i].strip() == 'return """')
    except StopIteration:
        raise Drift(f"`{function_anchor}`: its `return \"\"\"` multiline "
                    "literal not found")

    try:
        close_index = next(i for i in range(open_index + 1, len(lines))
                           if lines[i].strip() == '"""')
    except StopIteration:
        raise Drift(f"`{function_anchor}`: the closing `\"\"\"` of its "
                    "literal not found")
    return open_index, close_index


def extract_return_literal(source: str, function_anchor: str) -> str:
    """The value of the `return \"\"\"` literal of the function `function_anchor`
    (used for `buildChat`)."""
    lines = source.split("\n")
    open_index, close_index = literal_line_range(lines, function_anchor)
    return _literal_value(lines, open_index, close_index,
                          f"`{function_anchor}`'s literal")


def extract_decl_literal(source: str, declaration: str) -> str:
    """The value of the literal of `static let <declaration> = \"\"\"` (used for
    the two persona constants)."""
    lines = source.split("\n")
    anchor = f'static let {declaration} = """'
    try:
        decl_index = next(i for i, line in enumerate(lines) if anchor in line)
    except StopIteration:
        raise Drift(f"the declaration `{anchor}` not found")

    try:
        close_index = next(i for i in range(decl_index + 1, len(lines))
                           if lines[i].strip() == '"""')
    except StopIteration:
        raise Drift(f"`{anchor}`: the closing `\"\"\"` of its literal not found")
    return _literal_value(lines, decl_index, close_index,
                          f"`{anchor}`'s literal")


# ---------------------------------------------------------------------------
# The intent prompt (T-094 — behavior unchanged; T-170 adds the pin assertion)

def normalize(swift_literal: str) -> str:
    for source, placeholder in INTERPOLATIONS:
        count = swift_literal.count(source)
        if count != 1:
            raise Drift(
                f"the Swift literal carries {count} occurrence(s) of the "
                f"interpolation {source!r} — exactly 1 required (missing or "
                "duplicated, no partial pass)")
    normalized = swift_literal
    for source, placeholder in INTERPOLATIONS:
        normalized = normalized.replace(source, placeholder)
    return normalized


def validate_seed(seed: str) -> None:
    for placeholder in PLACEHOLDERS:
        count = seed.count(placeholder)
        if count != 1:
            raise Drift(
                f"the seed carries {count} occurrence(s) of {placeholder} — "
                "exactly 1 required; edit the seed in the SAME change as the "
                "Swift text")


def byte_diff_excerpt(normalized: str, seed: str) -> str:
    """First differing line plus the byte counts — enough to fix, no dump."""
    swift_bytes = len(normalized.encode("utf-8"))
    seed_bytes = len(seed.encode("utf-8"))
    swift_lines = normalized.split("\n")
    seed_lines = seed.split("\n")
    for index in range(max(len(swift_lines), len(seed_lines))):
        left = swift_lines[index] if index < len(swift_lines) else "<no line>"
        right = seed_lines[index] if index < len(seed_lines) else "<no line>"
        if left != right:
            return (f"first divergence at line {index + 1} "
                    f"(swift {swift_bytes} bytes / seed {seed_bytes} bytes):\n"
                    f"    swift: {left!r}\n"
                    f"    seed : {right!r}")
    return (f"line structure matches but the bytes differ "
            f"(swift {swift_bytes} / seed {seed_bytes}) — trailing newline?")


def diff_excerpt(left_label: str, left: str, right_label: str,
                 right: str) -> str:
    """`byte_diff_excerpt`'s generic twin, for the [CNR] T-170 pairs."""
    left_bytes = len(left.encode("utf-8"))
    right_bytes = len(right.encode("utf-8"))
    left_lines = left.split("\n")
    right_lines = right.split("\n")
    for index in range(max(len(left_lines), len(right_lines))):
        left_line = left_lines[index] if index < len(left_lines) else "<no line>"
        right_line = right_lines[index] if index < len(right_lines) else "<no line>"
        if left_line != right_line:
            return (f"first divergence at line {index + 1} "
                    f"({left_label} {left_bytes} bytes / "
                    f"{right_label} {right_bytes} bytes):\n"
                    f"    {left_label}: {left_line!r}\n"
                    f"    {right_label}: {right_line!r}")
    return (f"line structure matches but the bytes differ "
            f"({left_label} {left_bytes} / {right_label} {right_bytes}) — "
            "trailing newline?")


def check(swift_path: Path, seed_path: Path) -> str:
    """The intent-prompt check (T-094). Raises Drift on any mismatch."""
    swift_literal = extract_build_literal(swift_path.read_text(encoding="utf-8"))
    normalized = normalize(swift_literal)
    seed = seed_path.read_text(encoding="utf-8")
    validate_seed(seed)
    if normalized != seed:
        raise Drift("the Swift template and the seed are not byte-identical:\n"
                    + byte_diff_excerpt(normalized, seed))
    byte_count = len(normalized.encode("utf-8"))
    return f"  ✓ the seed mirrors IntentPrompt.build byte-for-byte " \
           f"({byte_count} bytes, 4 placeholders)"


def render_intent_prompt(seed: str, transcript: str) -> str:
    """The seed rendered by the training suite's OWN renderer.

    Uses `intent_prompt.render_prompt` with its documented defaults (hint
    "ne", medications "(none)", no personalization clause) — the same render
    `train_qlora` and `eval_golden` apply, so the digest assertion below
    pins the training prompt, not a lookalike.
    """
    renderer = _import_train_module("intent_prompt")
    return renderer.render_prompt(seed, transcript)


def check_intent_pin(seed_path: Path) -> str:
    """FR-CNR-023: the pinned intent prompt reproduces its recorded pins.

    The pins are the two digests `IntentPromptTests` records for the
    pre-feature composition. This unit must NOT move them; the check exists
    so the "intent prompt untouched" property is machine-asserted rather
    than reviewed by eye (design-l1 §10: "sha256-verified by the existing
    check plus a new equality assertion in the mirror report").
    """
    seed = seed_path.read_text(encoding="utf-8")
    recorded = []
    for transcript, expected in INTENT_PIN_FIXTURES:
        rendered = render_intent_prompt(seed, transcript)
        actual = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
        if actual != expected:
            raise Drift(
                "the PINNED intent prompt no longer reproduces its recorded "
                "pin (FR-CNR-023: this feature leaves it byte-identical):\n"
                f"    seed file   : {seed_path}\n"
                f"    renderer    : tools/train-intent/src/intent_prompt.py "
                "(documented defaults)\n"
                f"    fixture     : {transcript!r}\n"
                f"    pinned      : {expected}\n"
                f"    recomputed  : {actual}\n"
                "    If a future change legitimately moves the intent prompt, "
                "that change moves this pin AND the IntentPromptTests pins "
                "together, explicitly, in one change — never silently.")
        recorded.append(f"{actual[:8]}…{actual[-7:]}")
    return ("  ✓ the pinned intent prompt is untouched: the seed + the "
            "training renderer reproduce both recorded IntentPromptTests "
            f"digests ({', '.join(recorded)})")


# ---------------------------------------------------------------------------
# The chat template seed mirror ([CNR] T-170; design-l1 §6.3 (a))

def normalize_chat(swift_literal: str) -> str:
    for source, placeholder in CHAT_INTERPOLATIONS:
        count = swift_literal.count(source)
        if count != 1:
            raise Drift(
                f"the Swift chat literal carries {count} occurrence(s) of "
                f"the interpolation {source!r} — exactly 1 required (missing "
                "or duplicated, no partial pass)")
    normalized = swift_literal
    for source, placeholder in CHAT_INTERPOLATIONS:
        normalized = normalized.replace(source, placeholder)
    return normalized


def validate_chat_seed(seed: str) -> None:
    for placeholder in CHAT_PLACEHOLDERS:
        count = seed.count(placeholder)
        if count != 1:
            raise Drift(
                f"the chat seed carries {count} occurrence(s) of "
                f"{placeholder} — exactly 1 required; regenerate the seed "
                "from the builder (--regen-chat-seed), never by hand")


def chat_literal(swift_path: Path) -> str:
    """`buildChat`'s literal, or a Drift naming the file it was read from."""
    try:
        return extract_return_literal(swift_path.read_text(encoding="utf-8"),
                                      "static func buildChat(")
    except Drift as drift:
        raise Drift(f"{swift_path}: {drift}")


def chat_seed_from_builder(swift_path: Path) -> str:
    """The seed content the shipped builder produces (the regeneration body)."""
    return normalize_chat(chat_literal(swift_path))


def check_chat_template(swift_path: Path, seed_path: Path) -> str:
    """The chat template seed ↔ `IntentPrompt.buildChat`, byte-for-byte."""
    normalized = chat_seed_from_builder(swift_path)
    try:
        seed = seed_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise Drift(
            f"the chat template seed is missing: {seed_path}\n"
            "    Generate it from the builder (the ONE regeneration path — "
            "the builder is the source of truth):\n"
            "        python3 ios/tools/check-prompt-mirror.py --regen-chat-seed")
    validate_chat_seed(seed)
    if normalized != seed:
        raise Drift(
            "the chat template seed and IntentPrompt.buildChat are not "
            "byte-identical:\n"
            f"    file A (source of truth): {swift_path}\n"
            f"    file B (seed)           : {seed_path}\n"
            + diff_excerpt("builder", normalized, "seed", seed)
            + "\n    Fix: edit the builder first, then regenerate the seed "
              "(--regen-chat-seed) — never edit one without the other.")
    byte_count = len(normalized.encode("utf-8"))
    return (f"  ✓ the chat seed mirrors IntentPrompt.buildChat byte-for-byte "
            f"({byte_count} bytes, 3 placeholders)")


def regen_chat_seed(tree: Tree) -> int:
    """--regen-chat-seed: write the seed byte-exactly from the builder."""
    if not tree.swift.is_file():
        print(f"  ✗ cannot regenerate: {tree.swift} not found", file=sys.stderr)
        return 1
    content = chat_seed_from_builder(tree.swift)
    tree.chat_seed.parent.mkdir(parents=True, exist_ok=True)
    tree.chat_seed.write_text(content, encoding="utf-8")
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    print(f"  ✓ wrote {tree.chat_seed}")
    print(f"    from {tree.swift} — {len(content.encode('utf-8'))} bytes, "
          f"3 placeholders, sha256 {digest[:8]}…{digest[-7:]}")
    print("    Now re-run the gate (bash ios/tools/check-prompt-mirror.sh) and "
          "commit the builder + the seed in the SAME change.")
    return 0


# ---------------------------------------------------------------------------
# The style spec: loaded through its own loader, read byte-exactly here

def load_style_spec(spec_path: Path):
    """Load the style spec through `tools/train-intent/src/style_spec.py`.

    ONE parser for the artifact: this gate does not re-implement the spec's
    section/block syntax, it loads the loader's validated view and compares
    the corresponding BYTES.
    """
    style_spec = _import_train_module("style_spec")
    try:
        return style_spec.load(spec_path)
    except style_spec.StyleSpecError as exc:
        raise Drift(f"the style spec failed to load: {exc}")


def _import_train_module(name: str):
    if str(TRAIN_SRC) not in sys.path:
        sys.path.insert(0, str(TRAIN_SRC))
    try:
        return __import__(name)
    except ImportError as exc:
        raise Drift(
            f"the training-suite module '{name}' (in tools/train-intent/src) "
            f"is not importable: {exc}")


def spec_block_bodies(spec_path: Path) -> Dict[str, str]:
    """The raw bodies of the spec's fenced machine blocks, by block name.

    The fence rules are `style_spec.py`'s own (`_BLOCK_OPEN_RE` /
    `_BLOCK_CLOSE_RE`): the loader exposes parsed blocks, and this gate's
    contract is BYTE equality with the artifact, so the bytes are read here
    and cross-checked against the loader's parse in `check_guard_blocks`.
    """
    try:
        text = spec_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise Drift(f"the style spec is missing: {spec_path}")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    bodies: Dict[str, str] = {}
    index = 0
    while index < len(lines):
        opener = SPEC_BLOCK_OPEN_RE.match(lines[index])
        if opener:
            name = opener.group(1)
            body: List[str] = []
            index += 1
            while index < len(lines) and not SPEC_BLOCK_CLOSE_RE.match(lines[index]):
                body.append(lines[index])
                index += 1
            if index >= len(lines):
                raise Drift(f"{spec_path}: machine block '{name}' is never "
                            "closed (missing ``` line)")
            if name in bodies:
                raise Drift(f"{spec_path}: machine block '{name}' is defined "
                            "twice")
            bodies[name] = "\n".join(body)
        index += 1
    return bodies


# ---------------------------------------------------------------------------
# The guard's embedded spec blocks ([CNR] T-170; design-l1 §6.3 (c))

def extract_style_spec_block(source: str, name: str) -> str:
    """The literal value of the guard's `@style-spec-block: <name>` constant.

    T-169's contract: the block constant sits between the
    `// @style-spec-block: <name>` / `// @style-spec-block-end: <name>`
    markers, and its literal VALUE equals the spec's fenced block body
    byte-for-byte (Swift multiline-literal semantics).
    """
    lines = source.split("\n")
    begin = GUARD_BLOCK_BEGIN.format(name)
    end = GUARD_BLOCK_END.format(name)

    begins = [i for i, line in enumerate(lines) if line.strip() == begin]
    if len(begins) != 1:
        raise Drift(
            f"the guard carries {len(begins)} `{begin}` marker(s) — exactly 1 "
            "required (the mirror surface is the marked region)")
    begin_index = begins[0]
    ends = [i for i, line in enumerate(lines)
            if i > begin_index and line.strip() == end]
    if not ends:
        raise Drift(f"the guard's `{begin}` marker has no matching `{end}` "
                    "marker")
    end_index = ends[0]

    try:
        decl_index = next(i for i in range(begin_index + 1, end_index)
                          if lines[i].rstrip().endswith('= """'))
    except StopIteration:
        raise Drift(f"the guard's `{name}` region carries no `= \"\"\"` "
                    "declaration")
    try:
        close_index = next(i for i in range(decl_index + 1, end_index)
                           if lines[i].strip() == '"""')
    except StopIteration:
        raise Drift(f"the guard's `{name}` region's multiline literal is "
                    f"never closed before `{end}`")
    return _literal_value(lines, decl_index, close_index,
                          f"the guard's `{name}` block")


def check_guard_blocks(guard_path: Path, spec_path: Path, spec) -> str:
    """The guard's four lexicon blocks ↔ the spec's machine blocks."""
    source = guard_path.read_text(encoding="utf-8")
    bodies = spec_block_bodies(spec_path)
    sizes = []
    for name in GUARD_BLOCK_NAMES:
        if name not in bodies:
            raise Drift(f"the style spec {spec_path} carries no `{name}` "
                        "machine block")
        try:
            parsed = json.loads(bodies[name])
        except json.JSONDecodeError as exc:  # pragma: no cover - loader guards this
            raise Drift(f"{spec_path}: machine block '{name}' is not valid "
                        f"JSON ({exc})")
        if parsed != spec.block(name):
            raise Drift(
                "this checker's fence extraction disagrees with "
                f"style_spec.load for block '{name}' — fix the checker, "
                "never the artifact")
        literal = extract_style_spec_block(source, name)
        if literal != bodies[name]:
            raise Drift(
                f"the guard's `{name}` block and the style spec's are not "
                "byte-identical:\n"
                f"    file A (spec, source of truth): {spec_path}\n"
                f"    file B (guard constant)       : {guard_path}\n"
                f"    region: the `{name}` block of {guard_path} "
                f"(between its @style-spec-block markers)\n"
                + diff_excerpt("guard", literal, "spec", bodies[name])
                + "\n    Fix: change the spec first, then re-embed its block "
                  "body byte-for-byte in the guard — one change, one rule.")
        sizes.append(f"{name} {len(bodies[name].encode('utf-8'))}B")
    return ("  ✓ the guard's 4 machine blocks mirror the style spec "
            f"byte-for-byte ({', '.join(sizes)}; spec version={spec.version} "
            f"sha256={spec.sha256[:8]}…{spec.sha256[-7:]})")


# ---------------------------------------------------------------------------
# The personas ([CNR] T-170; design-l1 §6.3 (b))

def persona_literal(swift_path: Path, declaration: str) -> str:
    try:
        return extract_decl_literal(swift_path.read_text(encoding="utf-8"),
                                    declaration)
    except Drift as drift:
        raise Drift(f"{swift_path}: {drift}")


def check_persona(swift_path: Path, declaration: str, label: str,
                  clause: str, spec_path: Path) -> Tuple[str, str]:
    """One persona constant ↔ the spec clause. Returns (line, literal)."""
    literal = persona_literal(swift_path, declaration)
    lines = literal.split("\n")
    if len(lines) < 2:
        raise Drift(
            f"the {label} ({declaration} in {swift_path}) carries no "
            "transport wrapper — the persona is the spec clause inside a "
            "minimal wrapper (identity + the answer-language line), never "
            "the bare clause")
    if lines[-1] != clause:
        raise Drift(
            f"the {label} ({declaration} in {swift_path}) does not end with "
            "the spec's persona_clause byte-for-byte:\n"
            f"    spec   ({spec_path}): {clause!r}\n"
            f"    const  ({swift_path}) last line: {lines[-1]!r}")
    count = literal.count(clause)
    if count != 1:
        raise Drift(
            f"the {label} ({declaration} in {swift_path}) carries {count} "
            "occurrence(s) of the spec's persona_clause — exactly 1 required "
            "(a second copy would drift independently of the spec)")
    byte_count = len(clause.encode("utf-8"))
    return (f"  ✓ the {label} embeds the spec persona_clause byte-for-byte "
            f"({byte_count} bytes, wrapper + clause, {len(lines)} lines)",
            literal)


# ---------------------------------------------------------------------------
# The chat token budget ([CNR] T-170; NFR-CNR-004)

def devanagari_characters(text: str) -> int:
    """Devanagari scalars: the base block plus Devanagari Extended."""
    return sum(1 for char in text
               if "ऀ" <= char <= "ॿ" or "᳐" <= char <= "᳿")


def estimate_tokens(text: str) -> int:
    """A conservative token estimate (over-counts; see the constants).

    Devanagari at `CHARS_PER_TOKEN_DEVANAGARI`, everything else at
    `CHARS_PER_TOKEN_OTHER`, ceilings summed per class. The reference
    measurement (the weather-fixture intent prompt: 696 qwen3 / 677 gemma
    tokens) estimates at ≈861 here, i.e. the estimate is deliberately ~24%
    high — a margin computed from it is a LOWER bound on the real headroom.
    """
    devanagari = devanagari_characters(text)
    other = len(text) - devanagari
    return (math.ceil(devanagari / CHARS_PER_TOKEN_DEVANAGARI)
            + math.ceil(other / CHARS_PER_TOKEN_OTHER))


def worst_case_template(chat_seed: str) -> str:
    """The chat template at the personalization bound `IntentPromptTests` pins.

    `{language_hint}` renders the on-device default ("ne"), `{transcript}` is
    the turn's part of the budget (the allowance covers it, not the
    template), and `{address_as_clause}` renders the worst-case clause:
    the shipped shape with a 24-Character term (56 static + 24 = 80
    Characters, the bound `IntentPromptTests.testWorstCaseCompositionStays…`
    pins).
    """
    static = len(ADDRESS_CLAUSE_SHAPE.format(""))
    if static != ADDRESS_CLAUSE_STATIC_CHARACTERS:  # pragma: no cover - shape guard
        raise Drift(
            f"the address-clause shape renders {static} static Characters — "
            f"the Swift suite pins {ADDRESS_CLAUSE_STATIC_CHARACTERS}; the "
            "shape here and `IntentPrompt.addressAsClause` have diverged")
    clause = ADDRESS_CLAUSE_SHAPE.format("अ" * ADDRESS_CLAUSE_TERM_CHARACTERS)
    actual = len(clause)
    if actual != ADDRESS_CLAUSE_MAX_CHARACTERS:  # pragma: no cover - shape guard
        raise Drift(f"the worst-case clause renders {actual} Characters — "
                    f"the Swift suite pins {ADDRESS_CLAUSE_MAX_CHARACTERS}")
    return (chat_seed
            .replace("{language_hint}", "ne")
            .replace("{transcript}", "")
            .replace("{address_as_clause}", clause))


def check_token_budget(chat_seed: str, persona_literal_text: str,
                       chat_seed_path: Path, llama_path: Path) -> str:
    """The prompt side's share of the 1,024-token window, with its margin."""
    rendered = worst_case_template(chat_seed)
    template_tokens = estimate_tokens(rendered)
    persona_tokens = estimate_tokens(persona_literal_text)
    prompt_side = template_tokens + persona_tokens
    budget = CHAT_CONTEXT_TOKENS - CHAT_TURN_ALLOWANCE_TOKENS
    margin = budget - prompt_side
    if margin < 0:
        raise Drift(
            "the chat prompt side exceeds its share of the 1,024-token "
            "context (NFR-CNR-004):\n"
            f"    worst-case template ({chat_seed_path}) ≈{template_tokens} "
            "tokens\n"
            f"    local persona ({llama_path}) ≈{persona_tokens} tokens\n"
            f"    prompt side ≈{prompt_side} > {budget} "
            f"(= {CHAT_CONTEXT_TOKENS} − {CHAT_TURN_ALLOWANCE_TOKENS} "
            "turn/reply allowance)\n"
            f"    overrun ≈{-margin} tokens\n"
            "    Fix: trim the persona or the template text (style travels "
            "via data, FR-CNR-023) — never truncate the turn (NFR-CNR-004's "
            "headroom rule).")
    return ("  ✓ chat token budget: worst-case template "
            f"≈{template_tokens} + persona ≈{persona_tokens} = "
            f"≈{prompt_side} of the {budget}-token prompt side "
            f"({CHAT_CONTEXT_TOKENS} − {CHAT_TURN_ALLOWANCE_TOKENS} "
            f"turn/reply allowance); margin ≈{margin} tokens\n"
            "    (conservative estimator: "
            f"{CHARS_PER_TOKEN_DEVANAGARI} chars/Devanagari token, "
            f"{CHARS_PER_TOKEN_OTHER} chars/other — it over-counts the "
            "recorded reference measurement (the weather-fixture intent "
            "prompt: 696 qwen3 / 677 gemma tokens, estimated ≈861 here), so "
            "the margin is a lower bound; the exact-tokenizer leg is T-167's "
            "Character ceiling and T-186's sweep)")


# ---------------------------------------------------------------------------
# The full run, in order

def run_checks(tree: Tree) -> List[str]:
    """Every check, in order; the first Drift aborts the run (loud, no
    partial pass)."""
    lines = []
    lines.append(check(tree.swift, tree.seed))
    lines.append(check_intent_pin(tree.seed))
    lines.append(check_chat_template(tree.swift, tree.chat_seed))
    spec = load_style_spec(tree.spec)
    clause = spec.persona_clause()
    local_line, local_literal = check_persona(
        tree.llama, "chatPersonaSystemPrompt", "local chat system prompt",
        clause, tree.spec)
    cloud_line, _ = check_persona(
        tree.gemini, "replyPersona", "cloud system instruction",
        clause, tree.spec)
    lines.append(local_line)
    lines.append(cloud_line)
    lines.append(check_guard_blocks(tree.guard, tree.spec, spec))
    lines.append(check_token_budget(
        tree.chat_seed.read_text(encoding="utf-8"), local_literal,
        tree.chat_seed, tree.llama))
    return lines


# ---------------------------------------------------------------------------
# Self-test: the gate's negative path, exercised on every run.

def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def self_test(tree: Tree) -> List[str]:
    """Prove the gate is load-bearing: each mutation must exit non-zero.

    Runs over a temp copy of the real tree; the pristine copy must pass, then
    each drift class of each check must be rejected. `--regen-chat-seed` is
    exercised by the suite's own tests, not here (it is a maintenance tool,
    never part of the gate path).
    """
    results: List[str] = []
    with tempfile.TemporaryDirectory(prefix="prompt-mirror-selftest-") as tmp:
        temp = tree.copy_to(Path(tmp))

        def snapshot() -> Dict[str, str]:
            return {field: _read(Path(getattr(temp, field)))
                    for field in temp._fields}

        def restore(original: Dict[str, str]) -> None:
            for field, text in original.items():
                _write(Path(getattr(temp, field)), text)

        def expect_ok(label: str) -> None:
            try:
                run_checks(temp)
                results.append(f"    ✓ self-test/{label}: pristine copy passes")
            except Drift as drift:
                raise Drift(f"self-test/{label}: pristine copy FAILED: {drift}")

        def expect_drift(label: str, mutate: Callable[[], None]) -> None:
            original = snapshot()
            try:
                try:
                    mutate()
                except Exception as exc:
                    raise Drift(f"self-test/{label}: the mutation itself "
                                f"raised {exc!r}")
                try:
                    run_checks(temp)
                except Drift:
                    results.append(f"    ✓ self-test/{label}: drift rejected")
                else:
                    raise Drift(f"self-test/{label}: the gate PASSED a drifted "
                                "copy — not load-bearing")
            finally:
                restore(original)

        expect_ok("pristine")

        # --- the intent prompt (T-094's classes, unchanged) ----------------

        def flip_a_seed_byte():
            _write(temp.seed, _read(temp.seed).replace("Sahayak", "Sahayek", 1))

        def drop_a_seed_placeholder():
            _write(temp.seed, _read(temp.seed).replace("{transcript}", "", 1))

        def alter_a_seed_line():
            _write(temp.seed, _read(temp.seed).replace(
                "one short idea per sentence.",
                "one short thought per sentence.", 1))

        def drop_a_swift_interpolation():
            _write(temp.swift, _read(temp.swift).replace("\\(transcript)", "",
                                                         1))

        def duplicate_a_swift_interpolation():
            _write(temp.swift, _read(temp.swift).replace(
                "\\(transcript)", "\\(transcript) \\(transcript)", 1))

        def break_extraction():
            _write(temp.swift, _read(temp.swift).replace(
                "static func build(", "static func buildX(", 1))

        expect_drift("seed-byte-flip", flip_a_seed_byte)
        expect_drift("seed-placeholder-dropped", drop_a_seed_placeholder)
        expect_drift("seed-line-altered", alter_a_seed_line)
        expect_drift("swift-interpolation-dropped", drop_a_swift_interpolation)
        expect_drift("swift-interpolation-duplicated",
                     duplicate_a_swift_interpolation)
        expect_drift("extraction-broken", break_extraction)

        # --- the pinned intent prompt's digests ----------------------------

        def rephrase_the_pinned_intent_prompt():
            _write(temp.seed, _read(temp.seed).replace(
                "Their language hint is:", "The language hint is:", 1))
            _write(temp.swift, _read(temp.swift).replace(
                "Their language hint is:", "The language hint is:", 1))

        expect_drift("intent-pin-digest-broken-both-sides",
                     rephrase_the_pinned_intent_prompt)

        # --- the chat template ([CNR] T-170) -------------------------------

        def flip_a_chat_seed_byte():
            _write(temp.chat_seed, _read(temp.chat_seed).replace(
                "Sahayak", "Sahayek", 1))

        def drop_a_chat_seed_placeholder():
            _write(temp.chat_seed, _read(temp.chat_seed).replace(
                "{transcript}", "", 1))

        def alter_the_chat_builder_line():
            _write(temp.swift, _read(temp.swift).replace(
                "a warm companion talking with an elderly speaker",
                "a warm assistant talking with an elderly speaker", 1))

        def drop_a_chat_interpolation():
            _write(temp.swift, _read(temp.swift).replace(
                "in their own language (hint: \\(context.userLanguageHint))",
                "in their own language", 1))

        def duplicate_a_chat_interpolation():
            # Scoped to the buildChat literal's OWN lines. `User said:
            # "\(transcript)"` also occurs in build()'s literal, so a
            # file-wide first-occurrence replace lands THERE and the chat
            # check rightly keeps passing — the exact construction bug the
            # T-170 suite shipped with and this class exists to catch
            # (wave-close rework, 2026-10-14).
            path = Path(temp.swift)
            lines = _read(path).split("\n")
            open_index, close_index = literal_line_range(
                lines, "static func buildChat(")
            for index in range(open_index + 1, close_index):
                if "\\(transcript)" in lines[index]:
                    lines[index] = lines[index].replace(
                        "\\(transcript)", "\\(transcript) \\(transcript)", 1)
                    break
            else:
                raise AssertionError(
                    "no \\(transcript) interpolation inside the buildChat "
                    "literal to duplicate")
            _write(path, "\n".join(lines))

        def remove_the_chat_seed():
            temp.chat_seed.unlink()

        expect_drift("chat-seed-byte-flip", flip_a_chat_seed_byte)
        expect_drift("chat-seed-placeholder-dropped",
                     drop_a_chat_seed_placeholder)
        expect_drift("chat-builder-line-altered", alter_the_chat_builder_line)
        expect_drift("chat-interpolation-dropped", drop_a_chat_interpolation)
        expect_drift("chat-interpolation-duplicated",
                     duplicate_a_chat_interpolation)
        expect_drift("chat-seed-missing", remove_the_chat_seed)

        # --- the personas ([CNR] T-170) ------------------------------------

        def persona_file(field: str, declaration: str) -> Tuple[Path, List[str], int, int]:
            """(path, file lines, declaration index, closing-quote index)."""
            path = Path(getattr(temp, field))
            lines = _read(path).split("\n")
            anchor = f'static let {declaration} = """'
            declarations = [i for i, line in enumerate(lines) if anchor in line]
            if len(declarations) != 1:
                raise AssertionError(f"{path}: {len(declarations)} '{anchor}' lines")
            decl_index = declarations[0]
            close_index = next(i for i in range(decl_index + 1, len(lines))
                               if lines[i].strip() == '"""')
            return path, lines, decl_index, close_index

        def clause_line(path: Path, lines: List[str], close_index: int) -> int:
            """The clause is the literal's last line, i.e. the one just above
            the closing delimiter — derived, never hard-coded."""
            index = close_index - 1
            if "never तिमी;" not in lines[index]:
                raise AssertionError(f"{path}: line {index + 1} is not the clause")
            return index

        def drift_the_local_persona_clause():
            path, lines, _, close = persona_file("llama", "chatPersonaSystemPrompt")
            index = clause_line(path, lines, close)
            lines[index] = lines[index].replace("never तिमी;", "never तिमि;", 1)
            _write(path, "\n".join(lines))

        def drift_the_cloud_persona_clause():
            path, lines, _, close = persona_file("gemini", "replyPersona")
            index = clause_line(path, lines, close)
            lines[index] = lines[index].replace("never तिमी;", "never तिमि;", 1)
            _write(path, "\n".join(lines))

        def duplicate_the_local_persona_clause():
            path, lines, _, close = persona_file("llama", "chatPersonaSystemPrompt")
            index = clause_line(path, lines, close)
            lines.insert(index, lines[index])
            _write(path, "\n".join(lines))

        def remove_the_local_persona_wrapper():
            path, lines, decl, _ = persona_file("llama", "chatPersonaSystemPrompt")
            del lines[decl + 1]  # the wrapper is the literal's first line
            _write(path, "\n".join(lines))

        expect_drift("local-persona-clause-drift",
                     drift_the_local_persona_clause)
        expect_drift("cloud-persona-clause-drift",
                     drift_the_cloud_persona_clause)
        expect_drift("persona-clause-duplicated",
                     duplicate_the_local_persona_clause)
        expect_drift("persona-wrapper-removed",
                     remove_the_local_persona_wrapper)

        # --- the guard's lexicon blocks ([CNR] T-170) ----------------------

        def flip_a_guard_block_byte():
            _write(temp.guard, _read(temp.guard).replace(
                '"budget": 1,', '"budget": 2,', 1))

        def remove_a_guard_block_marker():
            _write(temp.guard, _read(temp.guard).replace(
                "// @style-spec-block: particles",
                "// @style-spec-block: Particles", 1))

        expect_drift("guard-block-byte-flip", flip_a_guard_block_byte)
        expect_drift("guard-block-marker-removed",
                     remove_a_guard_block_marker)

        # --- the budget (a consistent overrun, so the drift checks stay
        #     green and the BUDGET check is the one that must fire) ---------

        def grow_the_template_in_both_places():
            text = _read(temp.swift).replace(
                "This turn is SMALL TALK",
                "This turn is SMALL TALK " + "kalpana " * 150, 1)
            _write(temp.swift, text)
            _write(temp.chat_seed,
                   normalize_chat(extract_return_literal(
                       text, "static func buildChat(")))

        expect_drift("budget-overrun-consistent", grow_the_template_in_both_places)
    return results


# ---------------------------------------------------------------------------
# CLI

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, default=DEFAULT_SWIFT)
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    parser.add_argument("--chat-seed", type=Path, default=DEFAULT_CHAT_SEED)
    parser.add_argument("--llama", type=Path, default=DEFAULT_LLAMA)
    parser.add_argument("--gemini", type=Path, default=DEFAULT_GEMINI)
    parser.add_argument("--guard", type=Path, default=DEFAULT_GUARD)
    parser.add_argument("--style-spec", type=Path, default=DEFAULT_STYLE_SPEC)
    parser.add_argument("--regen-chat-seed", action="store_true",
                        help="write the chat template seed byte-exactly from "
                             "IntentPrompt.buildChat (the ONE regeneration "
                             "path) and exit")
    parser.add_argument("--self-test", action="store_true",
                        help="run only the gate's own mutation suite")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    tree = Tree(swift=args.swift, seed=args.seed, chat_seed=args.chat_seed,
                llama=args.llama, gemini=args.gemini, guard=args.guard,
                spec=args.style_spec)

    try:
        if args.regen_chat_seed:
            return regen_chat_seed(tree)
        if not args.self_test:
            for line in run_checks(tree):
                if not args.quiet:
                    print(line)
        if args.self_test:
            if not args.quiet:
                print("  prompt-mirror gate self-test (mutations must be "
                      "rejected):")
            for line in self_test(tree):
                if not args.quiet:
                    print(line)
            if not args.quiet:
                print("  ✓ every drift class is rejected; the gate is "
                      "load-bearing")
        return 0
    except Drift as drift:
        print(f"  ✗ prompt-mirror gate: {drift}", file=sys.stderr)
        print("    The seed and IntentPrompt.build/buildChat must stay "
              "byte-identical, the personas and guard lexicons must stay "
              "byte-identical to the style spec, and the chat prompt side must "
              "stay inside its budget share: edit source and mirror files in "
              "the SAME change (training/inference prompt identity is a hard "
              "requirement).", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
