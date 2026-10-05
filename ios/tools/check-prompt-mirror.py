#!/usr/bin/env python3
"""check-prompt-mirror.py — training/inference prompt-identity gate (T-094, C08).

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

Failure modes are loud: extraction failure, missing/duplicated interpolation,
missing/duplicated placeholder, or any byte mismatch exits non-zero with a
diff excerpt. There is no pass-by-default.

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
import shutil
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_SWIFT = REPO_ROOT / "ios" / "ElderlyAssistant" / "Services" / "Voice" / "IntentPrompt.swift"
DEFAULT_SEED = REPO_ROOT / "tools" / "train-intent" / "seeds" / "prompt_template.txt"

# Ordered so the replacement cannot shadow a longer source: the address
# clause source contains `context.addressAs`, nothing else does.
INTERPOLATIONS = (
    ("\\(context.userLanguageHint)", "{language_hint}"),
    ("\\(meds)", "{medications}"),
    ("\\(transcript)", "{transcript}"),
    ("\\(addressAsClause(context.addressAs))", "{address_as_clause}"),
)
PLACEHOLDERS = tuple(placeholder for _, placeholder in INTERPOLATIONS)


class Drift(Exception):
    """A named, loud failure — never caught past main()."""


def extract_build_literal(source: str) -> str:
    """The Swift value of `build`'s multiline literal, per Swift semantics.

    Locates `static func build(` then the first `return \"\"\"` after it and
    the next bare `\"\"\"` line. Every non-empty content line must carry the
    closing delimiter's indentation (Swift requires it); the value is the
    dedented lines joined by newline — the newline immediately preceding the
    closing delimiter is therefore not part of the value, exactly as the
    compiler defines it.
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

    closing = lines[close_index]
    indent = closing[:len(closing) - len(closing.lstrip())]
    if not indent:
        pass  # an unindented closing delimiter is legal; dedent is then empty

    content = []
    for line in lines[open_index + 1:close_index]:
        if line.strip() == "":
            content.append("")
            continue
        if not line.startswith(indent):
            raise Drift(
                "extraction failed: a content line is indented less than the "
                "closing delimiter — Swift would not compile this literal; "
                f"offending line: {line!r}")
        content.append(line[len(indent):])
    return "\n".join(content)


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


def check(swift_path: Path, seed_path: Path) -> str:
    """Returns the normalized Swift template; raises Drift on any mismatch."""
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


# ---------------------------------------------------------------------------
# Self-test: the gate's negative path, exercised on every run.

def self_test(swift_path: Path, seed_path: Path) -> list[str]:
    """Prove the gate is load-bearing: each mutation must exit non-zero.

    Runs over a temp copy of the two real files; the pristine copy must
    pass, then each drift class must be rejected by name.
    """
    results = []
    with tempfile.TemporaryDirectory(prefix="prompt-mirror-selftest-") as tmp:
        tmp_root = Path(tmp)
        swift_copy = tmp_root / "IntentPrompt.swift"
        seed_copy = tmp_root / "prompt_template.txt"
        shutil.copyfile(swift_path, swift_copy)
        shutil.copyfile(seed_path, seed_copy)

        def expect_ok(label: str):
            try:
                check(swift_copy, seed_copy)
                results.append(f"    ✓ self-test/{label}: pristine copy passes")
            except Drift as drift:
                raise Drift(f"self-test/{label}: pristine copy FAILED: {drift}")

        def expect_drift(label: str, mutate):
            original_swift = swift_copy.read_text(encoding="utf-8")
            original_seed = seed_copy.read_text(encoding="utf-8")
            mutate(original_swift, original_seed)
            try:
                check(swift_copy, seed_copy)
            except Drift:
                results.append(f"    ✓ self-test/{label}: drift rejected")
            else:
                raise Drift(f"self-test/{label}: the gate PASSED a drifted "
                            "copy — not load-bearing")
            finally:
                swift_copy.write_text(original_swift, encoding="utf-8")
                seed_copy.write_text(original_seed, encoding="utf-8")

        expect_ok("pristine")

        def flip_a_seed_byte(swift: str, seed: str):
            seed_copy.write_text(seed.replace("Sahayak", "Sahayek", 1),
                                 encoding="utf-8")

        def drop_a_seed_placeholder(swift: str, seed: str):
            seed_copy.write_text(seed.replace("{transcript}", "", 1),
                                 encoding="utf-8")

        def alter_a_seed_line(swift: str, seed: str):
            seed_copy.write_text(
                seed.replace("one short idea per sentence.",
                             "one short thought per sentence.", 1),
                encoding="utf-8")

        def drop_a_swift_interpolation(swift: str, seed: str):
            swift_copy.write_text(swift.replace("\\(transcript)", "", 1),
                                  encoding="utf-8")

        def duplicate_a_swift_interpolation(swift: str, seed: str):
            swift_copy.write_text(
                swift.replace("\\(transcript)", "\\(transcript) \\(transcript)", 1),
                encoding="utf-8")

        def break_extraction(swift: str, seed: str):
            swift_copy.write_text(swift.replace("static func build(",
                                                "static func buildX(", 1),
                                  encoding="utf-8")

        expect_drift("seed-byte-flip", flip_a_seed_byte)
        expect_drift("seed-placeholder-dropped", drop_a_seed_placeholder)
        expect_drift("seed-line-altered", alter_a_seed_line)
        expect_drift("swift-interpolation-dropped", drop_a_swift_interpolation)
        expect_drift("swift-interpolation-duplicated", duplicate_a_swift_interpolation)
        expect_drift("extraction-broken", break_extraction)
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, default=DEFAULT_SWIFT)
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    parser.add_argument("--self-test", action="store_true",
                        help="run only the gate's own mutation suite")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    try:
        if not args.self_test:
            line = check(args.swift, args.seed)
            if not args.quiet:
                print(line)
        if args.self_test:
            print("  prompt-mirror gate self-test (mutations must be rejected):")
            for line in self_test(args.swift, args.seed):
                print(line)
            if not args.quiet:
                print("  ✓ every drift class is rejected; the gate is load-bearing")
        return 0
    except Drift as drift:
        print(f"  ✗ prompt-mirror gate: {drift}", file=sys.stderr)
        print("    The seed and IntentPrompt.build must stay byte-identical: "
              "edit both in the SAME change (training/inference prompt "
              "identity is a hard requirement).", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
