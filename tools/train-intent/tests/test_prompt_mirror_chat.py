"""T-170 tests: the chat half of the prompt-mirror gate (design-l1 §6.3).

`ios/tools/check-prompt-mirror.py` is the ONE gate that keeps the training
side and the shipping side of every prompt a byte-mirror of the same origin
(`specs/plan-tasks/tasks/TG-35-.../T-170-prompt-mirror-discipline.md`). T-094
built its intent-prompt leg; this unit adds:

  * the PINNED intent prompt is asserted untouched — the seed + the training
    renderer reproduce both sha256 digests `IntentPromptTests` records
    (FR-CNR-023), and this suite pins those constants against the Swift
    suite's own literals so the two cannot drift;
  * the chat template seed
    (`tools/train-intent/seeds/chat_prompt_template.txt`) byte-mirrors
    `IntentPrompt.buildChat` (three placeholders, no few-shot, no medications
    slot), with the builder as the source of truth and `--regen-chat-seed` as
    the ONE regeneration path;
  * BOTH persona constants (`LlamaCommandInterpreter.chatPersonaSystemPrompt`,
    `GeminiCommandInterpreter.replyPersona`) end with the style spec's
    `persona_clause` byte-for-byte, exactly once, inside their own wrapper;
  * the guard's four embedded machine blocks (register, particles,
    code_switch, guard_checks) equal the spec's fenced block bodies
    byte-for-byte — and every embedded guard block is ON that mirror surface;
  * the chat token budget (NFR-CNR-004): the worst-case prompt side fits its
    share of the 1,024-token context, the margin is printed for T-186's
    sweep, and the estimator is pinned as CONSERVATIVE against the recorded
    real-tokenizer measurement (the exact-tokenizer leg is T-167's Character
    ceiling, not this file).

Every drift class is exercised in-process AND through the CLI (subprocess:
exit non-zero, naming both files and the differing line) — the gate is only
trusted if its negative path fires. The regeneration round trip is pinned
too: `--regen-chat-seed` derives from the builder, never from a hard-coded
copy.

Stdlib-only by contract, run from `tools/train-intent`:

    python3 -m unittest tests.test_prompt_mirror_chat
"""
from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent
REPO_ROOT = ROOT.parent.parent                         # the worktree root
sys.path.insert(0, str(ROOT / "src"))

import intent_prompt  # noqa: E402

CHECKER_PATH = REPO_ROOT / "ios" / "tools" / "check-prompt-mirror.py"
GATE_SH = REPO_ROOT / "ios" / "tools" / "check-prompt-mirror.sh"
BUILD_SH = REPO_ROOT / "ios" / "build.sh"
INTENT_PROMPT_TESTS = (REPO_ROOT / "ios" / "ElderlyAssistantTests"
                       / "Services" / "Voice" / "IntentPromptTests.swift")


def _load_checker():
    """The gate module, loaded by path (its filename is not an identifier)."""
    spec = importlib.util.spec_from_file_location("check_prompt_mirror",
                                                  CHECKER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["check_prompt_mirror"] = module
    spec.loader.exec_module(module)
    return module


mirror = _load_checker()

#: The live tree, exactly as the gate's own defaults resolve it.
LIVE_TREE = mirror.Tree(swift=mirror.DEFAULT_SWIFT, seed=mirror.DEFAULT_SEED,
                        chat_seed=mirror.DEFAULT_CHAT_SEED,
                        llama=mirror.DEFAULT_LLAMA,
                        gemini=mirror.DEFAULT_GEMINI,
                        guard=mirror.DEFAULT_GUARD,
                        spec=mirror.DEFAULT_STYLE_SPEC)

#: Every drift class the gate's own mutation suite must reject (pinned: if
#: the self-test loses a class, this suite fails where the loss happened).
SELF_TEST_LABELS = (
    "seed-byte-flip",
    "seed-placeholder-dropped",
    "seed-line-altered",
    "swift-interpolation-dropped",
    "swift-interpolation-duplicated",
    "extraction-broken",
    "intent-pin-digest-broken-both-sides",
    "chat-seed-byte-flip",
    "chat-seed-placeholder-dropped",
    "chat-builder-line-altered",
    "chat-interpolation-dropped",
    "chat-interpolation-duplicated",
    "chat-seed-missing",
    "local-persona-clause-drift",
    "cloud-persona-clause-drift",
    "persona-clause-duplicated",
    "persona-wrapper-removed",
    "guard-block-byte-flip",
    "guard-block-marker-removed",
    "budget-overrun-consistent",
)


@contextmanager
def temp_tree():
    """The seven gate artifacts, copied into a scratch tree."""
    with tempfile.TemporaryDirectory(prefix="prompt-mirror-test-") as tmp:
        yield LIVE_TREE.copy_to(Path(tmp))


def _run_cli(*args):
    """The checker's CLI, end to end (the real entry point, real exit code)."""
    return subprocess.run(
        [sys.executable, str(CHECKER_PATH), *map(str, args)],
        capture_output=True, text=True, check=False)


def _cli_flags(tree):
    return ("--swift", tree.swift, "--seed", tree.seed,
            "--chat-seed", tree.chat_seed, "--llama", tree.llama,
            "--gemini", tree.gemini, "--guard", tree.guard,
            "--style-spec", tree.spec)


# ---------------------------------------------------------------------------
# Pass path: the live tree, every check

class PassPathTests(unittest.TestCase):
    def test_every_check_passes_on_the_live_tree(self):
        lines = mirror.run_checks(LIVE_TREE)
        self.assertEqual(len(lines), 7, "7 check lines: intent mirror, pin, "
                         "chat mirror, 2 personas, guard blocks, budget")
        for line in lines:
            self.assertTrue(line.startswith("  ✓ "), line)

    def test_the_intent_mirror_line_is_unchanged_by_this_unit(self):
        # T-094's line, byte-for-byte: the intent path is not this unit's.
        self.assertIn("  ✓ the seed mirrors IntentPrompt.build byte-for-byte "
                      "(2717 bytes, 4 placeholders)",
                      mirror.check(LIVE_TREE.swift, LIVE_TREE.seed))

    def test_the_chat_mirror_line_reports_the_measured_seed(self):
        # Measured 2026-10-14 (T-170): the normalized chat literal is 725
        # bytes with 3 placeholders. A legitimate template change is expected
        # to move this pin CONSCIOUSLY (builder + seed + this number).
        self.assertIn("725 bytes, 3 placeholders",
                      mirror.check_chat_template(LIVE_TREE.swift,
                                                 LIVE_TREE.chat_seed))

    def test_both_personas_mirror_the_spec_clause(self):
        spec = mirror.load_style_spec(LIVE_TREE.spec)
        clause = spec.persona_clause()
        local_line, local = mirror.check_persona(
            LIVE_TREE.llama, "chatPersonaSystemPrompt",
            "local chat system prompt", clause, LIVE_TREE.spec)
        cloud_line, cloud = mirror.check_persona(
            LIVE_TREE.gemini, "replyPersona", "cloud system instruction",
            clause, LIVE_TREE.spec)
        self.assertIn("persona_clause byte-for-byte", local_line)
        self.assertIn("persona_clause byte-for-byte", cloud_line)
        # The design's explicit equality assertion (design-l1 §10): the
        # clause is the LAST line of each constant, byte-for-byte.
        for literal in (local, cloud):
            self.assertEqual(literal.split("\n")[-1], clause)
            self.assertEqual(literal.count(clause), 1)

    def test_the_personas_differ_only_in_their_wrappers(self):
        # One clause, two transports: a drift in the clause cannot hide
        # behind a wrapper difference.
        spec = mirror.load_style_spec(LIVE_TREE.spec)
        clause = spec.persona_clause()
        _, local = mirror.check_persona(LIVE_TREE.llama,
                                        "chatPersonaSystemPrompt", "local",
                                        clause, LIVE_TREE.spec)
        _, cloud = mirror.check_persona(LIVE_TREE.gemini, "replyPersona",
                                        "cloud", clause, LIVE_TREE.spec)
        self.assertNotEqual(local, cloud, "the wrappers are transport-specific")
        self.assertEqual(local.split("\n")[1:], cloud.split("\n")[1:],
                         "everything after the wrapper line is the shared "
                         "clause, byte-identical")

    def test_the_guard_blocks_mirror_the_spec(self):
        spec = mirror.load_style_spec(LIVE_TREE.spec)
        line = mirror.check_guard_blocks(LIVE_TREE.guard, LIVE_TREE.spec, spec)
        for name in ("register", "particles", "code_switch", "guard_checks"):
            self.assertIn(name, line)
        self.assertIn("spec version=1", line)

    def test_the_budget_line_prints_the_margin(self):
        # T-186's sweep reads the margin from this line.
        line = mirror.run_checks(LIVE_TREE)[-1]
        self.assertIn("chat token budget", line)
        self.assertIn("1024", line)
        self.assertIn("turn/reply allowance", line)
        margin = re.search(r"margin ≈(\d+) tokens", line)
        self.assertIsNotNone(margin, f"the margin must be printed: {line}")
        self.assertGreater(int(margin.group(1)), 0)

    def test_the_chat_seed_carries_exactly_the_three_chat_placeholders(self):
        seed = LIVE_TREE.chat_seed.read_text(encoding="utf-8")
        for placeholder in mirror.CHAT_PLACEHOLDERS:
            self.assertEqual(seed.count(placeholder), 1, placeholder)
        self.assertEqual(sorted(mirror.CHAT_PLACEHOLDERS),
                         ["{address_as_clause}", "{language_hint}",
                          "{transcript}"])
        self.assertNotIn("{medications}", seed,
                         "a chat turn executes nothing — the medications "
                         "slot must not exist on this path (FR-CNR-023)")
        self.assertNotIn("Example:", seed,
                         "the chat template carries no few-shot exemplars")

    def test_the_chat_seed_ends_with_the_closing_imperative(self):
        seed = LIVE_TREE.chat_seed.read_text(encoding="utf-8")
        self.assertTrue(seed.endswith(
            "Now output ONLY the JSON object for that reply.\n"),
            "the literal's trailing newline is part of the byte contract")


# ---------------------------------------------------------------------------
# The builders' literal extraction (Swift semantics, negative path included)

class ExtractionTests(unittest.TestCase):
    def test_return_literal_is_dedented_and_drops_the_pre_close_newline(self):
        source = ('    static func buildChat(x: Int) -> String {\n'
                  '        return """\n'
                  '        alpha\n'
                  '          beta\n'
                  '\n'
                  '        gamma\n'
                  '        """\n'
                  '    }\n')
        literal = mirror.extract_return_literal(source, "static func buildChat(")
        self.assertEqual(literal, "alpha\n  beta\n\ngamma")

    def test_a_missing_function_anchor_fails_loudly(self):
        with self.assertRaises(mirror.Drift) as raised:
            mirror.extract_return_literal("let x = 1\n", "static func buildChat(")
        self.assertIn("static func buildChat(", str(raised.exception))

    def test_a_missing_open_delimiter_fails_loudly(self):
        source = 'static func buildChat() -> String {\n    return "x"\n}\n'
        with self.assertRaises(mirror.Drift) as raised:
            mirror.extract_return_literal(source, "static func buildChat(")
        self.assertIn("multiline literal not found", str(raised.exception))

    def test_a_missing_closing_delimiter_fails_loudly(self):
        source = 'static func buildChat() -> String {\n    return """\n    x\n}\n'
        with self.assertRaises(mirror.Drift) as raised:
            mirror.extract_return_literal(source, "static func buildChat(")
        self.assertIn("closing", str(raised.exception))

    def test_an_under_indented_content_line_is_rejected_as_non_compiling(self):
        # Swift refuses this literal; the extractor must refuse too, never
        # guess an indentation.
        source = ('        return """\n'
                  '        ok\n'
                  '    under\n'
                  '        """\n')
        with self.assertRaises(mirror.Drift) as raised:
            mirror._literal_value(source.split("\n"), 0, 3, "test literal")
        self.assertIn("indented less", str(raised.exception))

    def test_decl_literal_extracts_between_its_own_delimiters(self):
        source = ('    // a comment\n'
                  '    static let replyPersona = """\n'
                  '    wrapper\n'
                  '    clause\n'
                  '    """\n'
                  '    let other = """\n'
                  '    not this\n'
                  '    """\n')
        self.assertEqual(
            mirror.extract_decl_literal(source, "replyPersona"),
            "wrapper\nclause")

    def test_a_missing_declaration_fails_loudly(self):
        with self.assertRaises(mirror.Drift) as raised:
            mirror.extract_decl_literal("let x = 1\n", "replyPersona")
        self.assertIn("replyPersona", str(raised.exception))


# ---------------------------------------------------------------------------
# The chat template mirror — drift, loud and named

class ChatDriftFailureTests(unittest.TestCase):
    def _drift(self, tree):
        with self.assertRaises(mirror.Drift) as raised:
            mirror.check_chat_template(tree.swift, tree.chat_seed)
        return str(raised.exception)

    def test_a_flipped_seed_byte_names_both_files_and_the_line(self):
        with temp_tree() as tree:
            seed = tree.chat_seed.read_text(encoding="utf-8")
            tree.chat_seed.write_text(seed.replace("Sahayak", "Sahayek", 1),
                                      encoding="utf-8")
            message = self._drift(tree)
            self.assertIn(str(tree.swift), message, "file A must be named")
            self.assertIn(str(tree.chat_seed), message, "file B must be named")
            self.assertIn("first divergence at line 1", message)
            self.assertIn("Sahayek", message)

    def test_a_seed_line_deletion_fails_at_a_later_line(self):
        with temp_tree() as tree:
            seed = tree.chat_seed.read_text(encoding="utf-8")
            lines = seed.split("\n")
            del lines[4]                     # "Reply with ONLY one JSON object…"
            tree.chat_seed.write_text("\n".join(lines), encoding="utf-8")
            message = self._drift(tree)
            self.assertIn("first divergence at line 5", message)

    def test_a_builder_edit_without_regenerating_the_seed_is_rejected(self):
        # THE regression this unit exists for: the source of truth moved and
        # the mirror did not.
        with temp_tree() as tree:
            swift = tree.swift.read_text(encoding="utf-8")
            tree.swift.write_text(
                swift.replace("a warm companion talking with an elderly speaker",
                              "a warm assistant talking with an elderly speaker",
                              1), encoding="utf-8")
            message = self._drift(tree)
            self.assertIn(str(tree.swift), message)
            self.assertIn(str(tree.chat_seed), message)
            self.assertRegex(message, r"first divergence at line \d+")
            self.assertIn("--regen-chat-seed", message,
                          "the failure names the ONE regeneration path")

    def test_a_dropped_chat_interpolation_is_rejected(self):
        with temp_tree() as tree:
            swift = tree.swift.read_text(encoding="utf-8")
            tree.swift.write_text(
                swift.replace(
                    "in their own language (hint: \\(context.userLanguageHint))",
                    "in their own language", 1), encoding="utf-8")
            message = self._drift(tree)
            self.assertIn("0 occurrence(s)", message)
            self.assertIn("userLanguageHint", message)

    def test_the_transcript_line_occurs_in_both_builders(self):
        # Why every chat-builder mutation here is scoped to the buildChat
        # literal: `User said: "\(transcript)"` occurs in build()'s literal
        # AND buildChat()'s. A file-wide first-occurrence replace mutates the
        # intent one and the chat check rightly keeps passing — a construction
        # bug this suite shipped with until the wave-close rework (2026-10-14)
        # proved it by probe. If a legitimate prompt change moves either
        # occurrence, update this pin consciously along with it.
        source = LIVE_TREE.swift.read_text(encoding="utf-8")
        self.assertEqual(source.count('User said: "\\(transcript)"'), 2)

    def test_a_duplicated_chat_interpolation_is_rejected(self):
        # Duplicate INSIDE the buildChat literal's own line range (the region
        # must be this narrow — see test_the_transcript_line_occurs_in_both_
        # builders above). The probe that isolated the wave-close failure:
        # duplication at build()'s line -> chat check PASSED (reproducing the
        # failure); duplication at buildChat's line -> Drift, "2
        # occurrence(s)" (the pass this test now pins).
        with temp_tree() as tree:
            lines = tree.swift.read_text(encoding="utf-8").split("\n")
            open_index, close_index = mirror.literal_line_range(
                lines, "static func buildChat(")
            for index in range(open_index + 1, close_index):
                if "\\(transcript)" in lines[index]:
                    lines[index] = lines[index].replace(
                        "\\(transcript)", "\\(transcript) \\(transcript)", 1)
                    break
            else:
                self.fail("no \\(transcript) interpolation inside the "
                          "buildChat literal to duplicate")
            tree.swift.write_text("\n".join(lines), encoding="utf-8")
            message = self._drift(tree)
            self.assertIn("2 occurrence(s)", message)
            self.assertIn("transcript", message)

    def test_a_missing_seed_names_the_regeneration_command(self):
        with temp_tree() as tree:
            tree.chat_seed.unlink()
            message = self._drift(tree)
            self.assertIn("missing", message)
            self.assertIn("--regen-chat-seed", message)

    def test_a_seed_placeholder_duplication_is_rejected(self):
        with temp_tree() as tree:
            seed = tree.chat_seed.read_text(encoding="utf-8")
            tree.chat_seed.write_text(
                seed.replace("{transcript}", "{transcript} {transcript}", 1),
                encoding="utf-8")
            with self.assertRaises(mirror.Drift) as raised:
                mirror.validate_chat_seed(tree.chat_seed.read_text(
                    encoding="utf-8"))
            self.assertIn("2 occurrence(s)", str(raised.exception))

    def test_normalize_chat_maps_every_interpolation_to_its_placeholder(self):
        with temp_tree() as tree:
            normalized = mirror.normalize_chat(
                mirror.chat_literal(tree.swift))
            self.assertNotIn("\\(context.userLanguageHint)", normalized)
            self.assertNotIn("\\(addressAsClause(context.addressAs))", normalized)
            self.assertNotIn("\\(transcript)", normalized)
            self.assertEqual(normalized,
                             tree.chat_seed.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# The regeneration path — the seed is DERIVED, never a second author

class RegenerationTests(unittest.TestCase):
    def test_regen_writes_the_builder_derived_seed_and_the_gate_then_passes(self):
        with temp_tree() as tree:
            # Stage the drift the regen exists to repair.
            swift = tree.swift.read_text(encoding="utf-8")
            tree.swift.write_text(
                swift.replace("a warm companion", "a warm friend", 1),
                encoding="utf-8")
            seed_before = tree.chat_seed.read_text(encoding="utf-8")
            self.assertNotEqual(seed_before,
                                mirror.chat_seed_from_builder(tree.swift))

            result = _run_cli("--regen-chat-seed", *_cli_flags(tree))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(tree.chat_seed), result.stdout)
            self.assertEqual(tree.chat_seed.read_text(encoding="utf-8"),
                             mirror.chat_seed_from_builder(tree.swift),
                             "the seed IS the builder's normalized literal")
            self.assertIn("a warm friend",
                          tree.chat_seed.read_text(encoding="utf-8"),
                          "the regen reads the CURRENT builder, not a copy")
            # The repaired tree passes the whole gate end to end.
            result = _run_cli(*_cli_flags(tree))
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_regen_is_byte_exact_for_a_freshly_edited_builder(self):
        with temp_tree() as tree:
            swift = tree.swift.read_text(encoding="utf-8")
            tree.swift.write_text(
                swift.replace("This turn is SMALL TALK",
                              "This turn is quiet company", 1),
                encoding="utf-8")
            result = _run_cli("--regen-chat-seed", *_cli_flags(tree))
            self.assertEqual(result.returncode, 0, result.stderr)
            written = tree.chat_seed.read_bytes()
            expected = mirror.chat_seed_from_builder(tree.swift).encode("utf-8")
            self.assertEqual(written, expected)

    def test_regen_refuses_a_missing_builder(self):
        with temp_tree() as tree:
            tree.swift.unlink()
            result = _run_cli("--regen-chat-seed", *_cli_flags(tree))
            self.assertEqual(result.returncode, 1)
            self.assertIn("cannot regenerate", result.stderr)

    def test_the_documented_regeneration_command_is_in_both_scripts(self):
        # The one obvious path: edit the builder -> regenerate -> re-run.
        for path in (CHECKER_PATH, GATE_SH):
            text = path.read_text(encoding="utf-8")
            self.assertIn("--regen-chat-seed", text, str(path))
        self.assertIn("edit IntentPrompt.buildChat FIRST",
                      GATE_SH.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# The pinned intent prompt (FR-CNR-023) — untouched, and pinned against the
# Swift suite's own recorded digests

class IntentPinTests(unittest.TestCase):
    def test_the_seed_and_renderer_reproduce_both_pins(self):
        line = mirror.check_intent_pin(LIVE_TREE.seed)
        self.assertIn("18003ddd…24b8b78", line)
        self.assertIn("bd47910d…16e00ff", line)

    def test_the_checkers_pins_equal_the_swift_suites_recorded_digests(self):
        self._assert_pins_match_swift()

    def _assert_pins_match_swift(self):
        swift_text = INTENT_PROMPT_TESTS.read_text(encoding="utf-8")
        swift_digests = set(re.findall(r'"([0-9a-f]{64})"', swift_text))
        checker_digests = {digest
                           for _, digest in mirror.INTENT_PIN_FIXTURES}
        self.assertTrue(checker_digests.issubset(swift_digests),
                        "every checker pin must be a digest the Swift suite "
                        "records; the intent prompt's pins move together, "
                        "explicitly, in one change")

    def test_a_rephrased_intent_seed_breaks_the_pin(self):
        with temp_tree() as tree:
            seed = tree.seed.read_text(encoding="utf-8")
            tree.seed.write_text(
                seed.replace("Their language hint is:", "The hint is:", 1),
                encoding="utf-8")
            with self.assertRaises(mirror.Drift) as raised:
                mirror.check_intent_pin(tree.seed)
            message = str(raised.exception)
            self.assertIn("pinned", message)
            self.assertIn(str(tree.seed), message)

    def test_the_pin_render_uses_the_training_renderers_defaults(self):
        # The pin is only meaningful if it renders the training prompt: the
        # renderer is `intent_prompt.render_prompt` with the documented
        # defaults, not a lookalike with the same text.
        rendered = mirror.render_intent_prompt(LIVE_TREE.seed.read_text(
            encoding="utf-8"), "test transcript")
        self.assertEqual(
            rendered,
            intent_prompt.render_prompt(
                LIVE_TREE.seed.read_text(encoding="utf-8"),
                "test transcript"))


# ---------------------------------------------------------------------------
# The personas

class PersonaMirrorTests(unittest.TestCase):
    def _clause(self):
        return mirror.load_style_spec(LIVE_TREE.spec).persona_clause()

    def test_a_clause_byte_flip_in_either_constant_is_rejected(self):
        for field, declaration, label in (
                ("llama", "chatPersonaSystemPrompt", "local chat system prompt"),
                ("gemini", "replyPersona", "cloud system instruction")):
            with self.subTest(constant=declaration), temp_tree() as tree:
                path = Path(getattr(tree, field))
                lines = path.read_text(encoding="utf-8").split("\n")
                clause_index = next(
                    i for i, line in enumerate(lines)
                    if line.strip() == self._clause().strip())
                lines[clause_index] = lines[clause_index].replace(
                    "never तिमी;", "never तिमि;", 1)
                path.write_text("\n".join(lines), encoding="utf-8")
                with self.assertRaises(mirror.Drift) as raised:
                    mirror.check_persona(path, declaration, label,
                                         self._clause(), tree.spec)
                message = str(raised.exception)
                self.assertIn(str(path), message, "the constant file is named")
                self.assertIn(str(tree.spec), message, "the spec is named")
                self.assertIn("persona_clause", message)

    def test_a_duplicated_clause_is_rejected(self):
        with temp_tree() as tree:
            lines = tree.llama.read_text(encoding="utf-8").split("\n")
            clause_index = next(
                i for i, line in enumerate(lines)
                if line.strip() == self._clause().strip())
            lines.insert(clause_index, lines[clause_index])
            tree.llama.write_text("\n".join(lines), encoding="utf-8")
            with self.assertRaises(mirror.Drift) as raised:
                mirror.check_persona(tree.llama, "chatPersonaSystemPrompt",
                                     "local chat system prompt", self._clause(),
                                     tree.spec)
            self.assertIn("2 occurrence(s)", str(raised.exception))

    def test_a_wrapper_less_clause_only_persona_is_rejected(self):
        # The persona is the clause inside a transport wrapper; a bare
        # clause loses the answer-language line and the JSON-only framing.
        with temp_tree() as tree:
            lines = tree.gemini.read_text(encoding="utf-8").split("\n")
            declaration = next(i for i, line in enumerate(lines)
                               if "static let replyPersona" in line)
            del lines[declaration + 1]
            tree.gemini.write_text("\n".join(lines), encoding="utf-8")
            with self.assertRaises(mirror.Drift) as raised:
                mirror.check_persona(tree.gemini, "replyPersona",
                                     "cloud system instruction", self._clause(),
                                     tree.spec)
            self.assertIn("transport wrapper", str(raised.exception))

    def test_the_clause_is_the_specs_own_text_not_a_paraphrase(self):
        # The spec is the origin: the constants' last line equals
        # `persona_clause()` character for character, and that text is the
        # spec section's own line (read here from the artifact).
        clause = self._clause()
        section = mirror.load_style_spec(LIVE_TREE.spec).section_text(
            "persona_clause")
        self.assertIn(clause, section)
        for field, declaration in (("llama", "chatPersonaSystemPrompt"),
                                   ("gemini", "replyPersona")):
            literal = mirror.persona_literal(Path(getattr(LIVE_TREE, field)),
                                             declaration)
            self.assertEqual(literal.split("\n")[-1], clause)


# ---------------------------------------------------------------------------
# The guard's embedded machine blocks

class GuardBlockMirrorTests(unittest.TestCase):
    def test_every_embedded_guard_block_is_on_the_mirror_surface(self):
        # If the guard embeds a fifth block, the mirror must grow with it —
        # an embedded lexicon outside the surface could drift unnoticed.
        source = LIVE_TREE.guard.read_text(encoding="utf-8")
        starts = re.compile(r"^// @style-spec-block: ([a-z_]+)$")
        ends = re.compile(r"^// @style-spec-block-end: ([a-z_]+)$")
        begins = [m.group(1) for line in source.split("\n")
                  if (m := starts.match(line.strip()))]
        closes = [m.group(1) for line in source.split("\n")
                  if (m := ends.match(line.strip()))]
        self.assertEqual(begins, list(mirror.GUARD_BLOCK_NAMES),
                         "the embedded blocks are exactly the mirror surface, "
                         "in declaration order")
        self.assertEqual(closes, begins, "every begin marker is closed")

    def test_the_fence_extraction_agrees_with_the_loader_for_every_block(self):
        spec = mirror.load_style_spec(LIVE_TREE.spec)
        bodies = mirror.spec_block_bodies(LIVE_TREE.spec)
        for name in mirror.GUARD_BLOCK_NAMES:
            self.assertIn(name, spec.block_names())
            self.assertEqual(json.loads(bodies[name]), spec.block(name),
                             "the checker's raw-body extraction and the "
                             "loader's parse must agree")
            self.assertEqual(
                mirror.extract_style_spec_block(
                    LIVE_TREE.guard.read_text(encoding="utf-8"), name),
                bodies[name])

    def test_a_flipped_guard_block_byte_names_both_files_and_the_line(self):
        with temp_tree() as tree:
            guard = tree.guard.read_text(encoding="utf-8")
            tree.guard.write_text(guard.replace('"budget": 1,',
                                                '"budget": 2,', 1),
                                  encoding="utf-8")
            spec = mirror.load_style_spec(tree.spec)
            with self.assertRaises(mirror.Drift) as raised:
                mirror.check_guard_blocks(tree.guard, tree.spec, spec)
            message = str(raised.exception)
            self.assertIn(str(tree.guard), message)
            self.assertIn(str(tree.spec), message)
            self.assertRegex(message, r"first divergence at line \d+")

    def test_a_marker_typo_is_rejected_by_name(self):
        with temp_tree() as tree:
            guard = tree.guard.read_text(encoding="utf-8")
            tree.guard.write_text(
                guard.replace("// @style-spec-block: particles",
                              "// @style-spec-block: Particles", 1),
                encoding="utf-8")
            spec = mirror.load_style_spec(tree.spec)
            with self.assertRaises(mirror.Drift) as raised:
                mirror.check_guard_blocks(tree.guard, tree.spec, spec)
            self.assertIn("particles", str(raised.exception))

    def test_a_name_mentioned_inside_a_longer_comment_is_not_a_marker(self):
        # The guard's header mentions the marker form inside prose; a
        # substring match would count it as a second begin marker.
        source = ("//   // @style-spec-block: particles   ...   end form\n"
                  "    // @style-spec-block: particles\n"
                  "    static let particlesBlockJSON = \"\"\"\n"
                  "    {}\n"
                  "    \"\"\"\n"
                  "    // @style-spec-block-end: particles\n")
        self.assertEqual(mirror.extract_style_spec_block(source, "particles"),
                         "{}")

    def test_an_unpaired_marker_is_rejected(self):
        source = ('    // @style-spec-block: particles\n'
                  '    static let particlesBlockJSON = """\n'
                  '    {}\n'
                  '    """\n')
        with self.assertRaises(mirror.Drift) as raised:
            mirror.extract_style_spec_block(source, "particles")
        self.assertIn("no matching", str(raised.exception))

    def test_a_region_without_a_literal_is_rejected(self):
        source = ('    // @style-spec-block: particles\n'
                  '    let x = 1\n'
                  '    // @style-spec-block-end: particles\n')
        with self.assertRaises(mirror.Drift) as raised:
            mirror.extract_style_spec_block(source, "particles")
        self.assertIn('= """', str(raised.exception))

    def test_a_duplicated_machine_block_in_the_spec_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="spec-dup-") as tmp:
            path = Path(tmp) / "spec"
            path.write_text("```json particles\n{}\n```\n\n```json particles\n"
                            "{}\n```\n", encoding="utf-8")
            with self.assertRaises(mirror.Drift) as raised:
                mirror.spec_block_bodies(path)
            self.assertIn("twice", str(raised.exception))

    def test_an_unclosed_machine_block_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="spec-open-") as tmp:
            path = Path(tmp) / "spec"
            path.write_text("```json particles\n{}\n", encoding="utf-8")
            with self.assertRaises(mirror.Drift) as raised:
                mirror.spec_block_bodies(path)
            self.assertIn("never", str(raised.exception))


# ---------------------------------------------------------------------------
# The token budget (NFR-CNR-004)

class TokenBudgetTests(unittest.TestCase):
    def test_the_worst_case_clause_is_the_pinned_eighty_characters(self):
        static = len(mirror.ADDRESS_CLAUSE_SHAPE.format(""))
        self.assertEqual(static, mirror.ADDRESS_CLAUSE_STATIC_CHARACTERS)
        clause = mirror.ADDRESS_CLAUSE_SHAPE.format(
            "अ" * mirror.ADDRESS_CLAUSE_TERM_CHARACTERS)
        self.assertEqual(len(clause), mirror.ADDRESS_CLAUSE_MAX_CHARACTERS)
        self.assertEqual(len(clause), 80,
                         "the bound IntentPromptTests pins (56 + 24)")

    def test_the_worst_case_template_renders_the_clause_not_the_placeholder(self):
        rendered = mirror.worst_case_template(
            LIVE_TREE.chat_seed.read_text(encoding="utf-8"))
        self.assertNotIn("{address_as_clause}", rendered)
        self.assertNotIn("{language_hint}", rendered)
        self.assertIn(' Address them as "' + "अ" * 24, rendered)

    def test_the_estimator_is_conservative_against_the_recorded_measurement(self):
        # The recorded real-tokenizer fact (IntentPromptTests): the shipped
        # intent template renders 696 qwen3 / 677 gemma tokens for the
        # weather fixture (2,506 Swift Characters = 2,540 scalars). The
        # estimator must OVER-count it — a margin computed from it is a
        # lower bound, never a flattering number. The exact estimate is
        # pinned because the artifact it scores is FROZEN (FR-CNR-023): a
        # number change here means the intent prompt moved.
        rendered = intent_prompt.render_prompt(
            LIVE_TREE.seed.read_text(encoding="utf-8"), "भोलिको मौसम कस्तो छ?")
        self.assertEqual(len(rendered), 2540, "the weather-fixture render")
        estimate = mirror.estimate_tokens(rendered)
        self.assertGreater(estimate, 696,
                           "the estimate must exceed the qwen3 measurement")
        self.assertGreater(estimate, 677,
                           "the estimate must exceed the gemma measurement")
        self.assertEqual(estimate, 861, "measured 2026-10-14 (T-170)")

    def test_the_estimator_charges_devanagari_and_other_text_separately(self):
        self.assertEqual(mirror.estimate_tokens(""), 0)
        self.assertEqual(mirror.estimate_tokens("अआइई"), 2)   # 4 / 2
        self.assertEqual(mirror.estimate_tokens("abc"), 1)     # 3 / 3
        self.assertEqual(mirror.devanagari_characters("abcअ"), 1)

    def test_the_prompt_side_fits_its_share_with_headroom(self):
        spec = mirror.load_style_spec(LIVE_TREE.spec)
        _, persona = mirror.check_persona(
            LIVE_TREE.llama, "chatPersonaSystemPrompt", "local",
            spec.persona_clause(), LIVE_TREE.spec)
        seed = LIVE_TREE.chat_seed.read_text(encoding="utf-8")
        line = mirror.check_token_budget(seed, persona, LIVE_TREE.chat_seed,
                                         LIVE_TREE.llama)
        margin = int(re.search(r"margin ≈(\d+) tokens", line).group(1))
        self.assertGreater(margin, 0)
        self.assertLess(margin, mirror.CHAT_TURN_ALLOWANCE_TOKENS,
                        "the margin is a headroom, not a free half")

    def test_a_consistent_overrun_fails_the_budget_not_the_mirror(self):
        # Grow the builder AND regenerate the seed: every byte check stays
        # green and ONLY the budget can fire — the check is load-bearing.
        with temp_tree() as tree:
            swift = tree.swift.read_text(encoding="utf-8")
            tree.swift.write_text(
                swift.replace("This turn is SMALL TALK",
                              "This turn is SMALL TALK " + "kalpana " * 150,
                              1), encoding="utf-8")
            tree.chat_seed.write_text(
                mirror.chat_seed_from_builder(tree.swift), encoding="utf-8")
            with self.assertRaises(mirror.Drift) as raised:
                mirror.run_checks(tree)
            message = str(raised.exception)
            self.assertIn("1,024-token", message)
            self.assertIn("overrun", message)
            self.assertIn(str(tree.chat_seed), message)

    def test_the_budget_constants_are_the_recorded_ones(self):
        self.assertEqual(mirror.CHAT_CONTEXT_TOKENS, 1024)
        self.assertEqual(mirror.CHAT_TURN_ALLOWANCE_TOKENS, 512)
        self.assertEqual(mirror.CHARS_PER_TOKEN_DEVANAGARI, 2)
        # One rule, two sites: the corpus builder's own conservative ratio
        # and turn ceiling. Read from the sibling module's source (not
        # imported — the builder is another unit's module) so a divergence
        # in either direction is a named failure here.
        source = (ROOT / "src" / "build_chat_corpus.py").read_text(
            encoding="utf-8")
        chars = re.search(r"(?m)^CHARS_PER_TOKEN = (\d+)\b", source)
        ceiling = re.search(r"(?m)^TURN_TOKEN_CEILING = (\d+)\b", source)
        self.assertIsNotNone(chars, "CHARS_PER_TOKEN moved or was renamed")
        self.assertIsNotNone(ceiling, "TURN_TOKEN_CEILING moved or was renamed")
        self.assertEqual(int(chars.group(1)),
                         mirror.CHARS_PER_TOKEN_DEVANAGARI)
        self.assertEqual(int(ceiling.group(1)),
                         mirror.CHAT_TURN_ALLOWANCE_TOKENS)


# ---------------------------------------------------------------------------
# CLI end to end: exit codes, the script the build runs, the wiring

class CliEndToEndTests(unittest.TestCase):
    def test_the_checker_cli_passes_and_prints_every_line(self):
        result = _run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("chat seed mirrors IntentPrompt.buildChat", result.stdout)
        self.assertIn("persona_clause byte-for-byte", result.stdout)
        self.assertIn("guard's 4 machine blocks", result.stdout)
        self.assertIn("chat token budget", result.stdout)
        self.assertIn("margin ≈", result.stdout)

    def test_the_checker_cli_reports_drift_and_exits_nonzero(self):
        with temp_tree() as tree:
            seed = tree.chat_seed.read_text(encoding="utf-8")
            tree.chat_seed.write_text(seed.replace("Sahayak", "Sahayek", 1),
                                      encoding="utf-8")
            result = _run_cli(*_cli_flags(tree))
            self.assertEqual(result.returncode, 1)
            self.assertIn("✗ prompt-mirror gate", result.stderr)
            self.assertIn(str(tree.swift), result.stderr)
            self.assertIn(str(tree.chat_seed), result.stderr)
            self.assertIn("first divergence at line 1", result.stderr)
            self.assertIn("prompt identity is a hard requirement",
                          result.stderr)

    def test_the_checker_cli_reports_persona_drift_and_exits_nonzero(self):
        with temp_tree() as tree:
            # The CONSTANT's clause line, not the doc-comment citation of it
            # (both carry the text; only the constant is the gate's input).
            clause = mirror.load_style_spec(tree.spec).persona_clause()
            lines = tree.llama.read_text(encoding="utf-8").split("\n")
            index = next(i for i, line in enumerate(lines)
                         if line.strip() == clause.strip())
            lines[index] = lines[index].replace("ONE idea each",
                                                "one idea each", 1)
            tree.llama.write_text("\n".join(lines), encoding="utf-8")
            result = _run_cli(*_cli_flags(tree))
            self.assertEqual(result.returncode, 1)
            self.assertIn(str(tree.llama), result.stderr)
            self.assertIn("persona_clause", result.stderr)

    def test_quiet_mode_is_silent_on_success(self):
        result = _run_cli("--quiet")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_the_self_test_flag_exercises_every_drift_class(self):
        result = _run_cli("--self-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        for label in SELF_TEST_LABELS:
            self.assertIn(f"self-test/{label}: drift rejected", result.stdout,
                          f"the mutation suite lost {label}")
        self.assertIn("load-bearing", result.stdout)

    def test_the_gate_script_passes_on_the_live_tree(self):
        # The exact entry point ios/build.sh invokes before every test scope.
        result = subprocess.run(["bash", str(GATE_SH)], capture_output=True,
                                text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("chat token budget", result.stdout)
        self.assertIn("every drift class is rejected", result.stdout)

    def test_the_gate_runs_ahead_of_the_ios_test_scopes(self):
        # The wiring criterion: the gate is invoked ahead of the test runs in
        # build.sh, so no test scope can observe a drifted tree.
        text = BUILD_SH.read_text(encoding="utf-8")
        start = text.index("run_tests() {")
        body = text[start:]
        end = re.search(r"\n\}", body)
        body = body[:end.start()]
        mirror_at = body.index("check-prompt-mirror.sh")
        release_at = body.index("check-release-log-safety.sh")
        test_at = body.index("xcodebuild")
        self.assertLess(release_at, mirror_at)
        self.assertLess(mirror_at, test_at,
                        "the mirror gate must run before the test scopes")

    def test_the_shell_gate_runs_the_checker_and_the_self_test(self):
        text = GATE_SH.read_text(encoding="utf-8")
        invocations = re.findall(r"check-prompt-mirror\.py\" ([^|]*)",
                                 text)
        self.assertEqual(len(invocations), 2, invocations)
        self.assertIn("--self-test", invocations[1])


# ---------------------------------------------------------------------------
# The gate's own surface — a silent coverage loss must fail here

class GateSurfaceTests(unittest.TestCase):
    def test_the_tree_covers_every_artifact_the_gate_reads(self):
        self.assertEqual(
            mirror.Tree._fields,
            ("swift", "seed", "chat_seed", "llama", "gemini", "guard", "spec"))

    def test_the_guard_block_names_are_the_executable_lexicons(self):
        self.assertEqual(mirror.GUARD_BLOCK_NAMES,
                         ("register", "particles", "code_switch",
                          "guard_checks"))

    def test_the_checker_is_stdlib_only(self):
        # It runs on the training box and in the iOS build loop: no third-
        # party dependency may sneak in.
        import ast
        tree = ast.parse(CHECKER_PATH.read_text(encoding="utf-8"))
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name.split(".")[0]
                                for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split(".")[0])
        allowed = {"__future__", "argparse", "hashlib", "json", "math", "re",
                   "shutil", "sys", "tempfile", "pathlib", "typing"}
        self.assertTrue(imported.issubset(allowed),
                        f"unexpected imports: {imported - allowed}")

    def test_the_self_test_is_not_optional_in_the_shell_gate(self):
        text = GATE_SH.read_text(encoding="utf-8")
        self.assertNotIn("SDD_SKIP", text)
        self.assertIn("is not optional", text)
        self.assertIn("cannot be switched off", text)


if __name__ == "__main__":
    unittest.main()
