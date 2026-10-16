"""T-166 tests: the Nepali chat style spec and its loader.

Covers the unit's acceptance criteria end to end:

  * the shipped artifact loads and every section its consumers read is
    returned by name, with a version and a content hash for run evidence;
  * the particle budget, the AI-ism ban list and the guard-check inputs are
    data with exactly one origin section (no duplication in the spec);
  * a spec missing a required section fails loudly, naming the section, with
    no default substituted — in-process and through the CLI (non-zero exit);
  * the traceability/drift check is executable: a consumer that mirrors a
    spec section byte-for-byte passes, a drifted consumer is reported as a
    defect (consumer + section) and the check exits non-zero.

The loader is stdlib-only by contract (it also runs on the training box), so
one test parses the module's imports and holds that line.
"""
from __future__ import annotations

import ast
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import style_spec as ss  # noqa: E402

SEED_PATH = ROOT / "seeds" / "nepali-chat-style-spec"
SRC_PATH = ROOT / "src" / "style_spec.py"
STDLIB_IMPORTS = {
    "__future__", "argparse", "copy", "hashlib", "json", "re", "sys",
    "pathlib", "typing",
}


# ---------------------------------------------------------------------------
# Fixture builders (a synthetic well-formed spec, rendered to a temp file)
# ---------------------------------------------------------------------------

def _base_sections():
    """A minimal, well-formed spec: every required section + machine block."""
    return {
        "register": ("Register rule for the elder.", {"register": {
            "address_pronoun": "तपाईं",
            "attention_marker": "हजुर",
            "honorific_pairs": [["भन्यो", "भन्नुभयो"]],
            "non_honorific_verb_forms": ["भन्यो"],
            "forbidden_address_forms": ["तिमी"],
        }}),
        "particles": ("One particle per reply.", {"particles": {
            "budget": 1,
            "units": ["हुन्छ नि", "है"],
            "longest_match_first": True,
        }}),
        "sentence_shape": ("SOV, two sentences at most.", {"sentence_shape": {
            "word_order": "SOV",
            "max_sentences": 2,
        }}),
        "small_talk": ("Warm small talk.", {"small_talk": {
            "topics": [{"id": "wellbeing", "nepali": "हालखबर"}],
        }}),
        "code_switch": ("Devanagari renderings.", {"code_switch": {
            "nouns": [{"english": "doctor", "spoken": "डाक्टर"}],
        }}),
        "ai_isms": ("Never speak as an AI.", {"ai_isms": {
            "forbidden": [{"id": "ai_identity", "kind": "substring",
                           "patterns": ["As an AI"]}],
        }}),
        "persona_clause": ("The canonical clause.", None),
        "rubric": ("Gate criteria.", {"rubric": {
            "deterministic_criteria": [],
            "judge_criteria": [],
            "judge_mean_threshold": 4.0,
        }}),
        "guard_checks": ("Guard inputs.", {"guard_checks": {
            "checks": [],
            "latin_allowlist": [],
        }}),
        "coverage": ("Conversation classes.", {"coverage": {
            "classes": [{"id": "greeting"}],
        }}),
    }


def _render_spec(sections, version="1"):
    parts = ["NEPALI CHAT STYLE SPEC", f"style_spec_version: {version}", ""]
    for name, (prose, block) in sections.items():
        parts.append(f"## section: {name}")
        parts.append(prose)
        if block is not None:
            block_name = next(iter(block))
            parts.append(f"```json {block_name}")
            parts.append(json.dumps(block[block_name], ensure_ascii=False, indent=2))
            parts.append("```")
        parts.append("")
    return "\n".join(parts) + "\n"


def _write(path: Path, text: str) -> Path:
    path.write_text(text, encoding="utf-8")
    return path


def _quote(text: str, prefix: str) -> str:
    """Mirror rule text the way a consumer's comment prefix carries it."""
    lines = text.split("\n")
    return "\n".join(prefix + line for line in lines)


def _consumer(path: Path, section: str, text: str, prefix: str = "# ") -> Path:
    body = (
        f"{prefix}@style-spec-section: {section}\n"
        f"{_quote(text, prefix)}\n"
        f"{prefix}@style-spec-section-end: {section}\n"
    )
    return _write(path, body)


def _run_cli(*args, cwd=None):
    return subprocess.run(
        [sys.executable, str(SRC_PATH), *args],
        capture_output=True, text=True, cwd=cwd,
    )


# ---------------------------------------------------------------------------
# The shipped artifact: every section its consumers read, by name
# ---------------------------------------------------------------------------

class ArtifactLoadingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = ss.load()

    def test_returns_every_required_section_by_name(self):
        self.assertEqual(self.spec.section_names(), ss.REQUIRED_SECTIONS)
        for name in ss.REQUIRED_SECTIONS:
            self.assertTrue(self.spec.section_text(name).strip(),
                            f"section '{name}' has no rule text")

    def test_reports_version_and_content_hash_for_run_evidence(self):
        raw = SEED_PATH.read_bytes()
        self.assertEqual(self.spec.version, "1")
        self.assertEqual(self.spec.sha256, hashlib.sha256(raw).hexdigest())
        self.assertEqual(len(self.spec.sha256), 64)
        self.assertEqual(self.spec.evidence(), {
            "path": str(SEED_PATH.resolve()),
            "version": "1",
            "sha256": self.spec.sha256,
        })

    def test_particle_budget_is_one_and_the_lexicon_is_data(self):
        self.assertEqual(self.spec.particle_budget(), 1)
        lexicon = self.spec.particle_lexicon()
        for unit in ("है", "नि", "ल", "ला", "अनि", "हुन्छ नि"):
            self.assertIn(unit, lexicon)
        # Longest-match-first: multi-word units precede the single words.
        key = lambda unit: (-len(unit.split()), -len(unit))  # noqa: E731
        self.assertEqual(list(lexicon), sorted(lexicon, key=key))

    def test_register_carries_the_shipped_register_facts(self):
        register = self.spec.register()
        self.assertEqual(register["address_pronoun"], "तपाईं")
        self.assertEqual(register["attention_marker"], "हजुर")
        pairs = dict((pair[0], pair[1]) for pair in register["honorific_pairs"])
        self.assertEqual(pairs.get("भन्यो"), "भन्नुभयो")
        self.assertEqual(pairs.get("गर्यो"), "गर्नुभयो")
        self.assertEqual(pairs.get("खायो"), "खानुभयो")
        for forbidden in ("तिमी", "तँ", "तिम्रो"):
            self.assertIn(forbidden, register["forbidden_address_forms"])
        forms = self.spec.respectful_forms()
        for form in ("हजुर", "तपाईं", "भन्नुभयो", "गर्नुभयो"):
            self.assertIn(form, forms)

    def test_ai_ism_ban_list_covers_the_named_classes(self):
        entries = self.spec.forbidden_ai_isms()
        ids = [entry["id"] for entry in entries]
        for expected in ("lists_and_markdown", "ai_identity",
                         "canned_service_phrase", "translation_ese",
                         "hedging_boilerplate", "over_politeness_stacking"):
            self.assertIn(expected, ids)
        patterns = [p for entry in entries for p in entry["patterns"]]
        self.assertIn("As an AI", patterns)
        self.assertIn("म एक AI हुँ", patterns)
        lists = next(e for e in entries if e["id"] == "lists_and_markdown")
        self.assertEqual(lists["kind"], "regex")
        for sample in ("1. first", "१. पहिलो", "- item", "**bold**"):
            self.assertTrue(
                any(__import__("re").search(p, sample) for p in lists["patterns"]),
                f"no list/markdown pattern matches {sample!r}")
        hedging = next(e for e in entries if e["id"] == "hedging_boilerplate")
        self.assertTrue(hedging["patterns"])

    def test_small_talk_repertoire_names_the_six_topics(self):
        ids = [topic["id"] for topic in self.spec.small_talk_topics()]
        for expected in ("wellbeing", "food", "sleep", "family", "weather",
                         "reminiscence"):
            self.assertIn(expected, ids)

    def test_code_switch_nouns_are_devanagari_renderings(self):
        nouns = self.spec.code_switch_nouns()
        spoken = [noun["spoken"] for noun in nouns]
        for expected in ("प्रेसर", "डाक्टर", "मेडिसिन", "फोन", "चार्जर"):
            self.assertIn(expected, spoken)
        for text in spoken:
            self.assertFalse(any(ch.isascii() and ch.isalpha() for ch in text),
                             f"'{text}' carries a Latin letter")

    def test_rubric_criteria_are_data(self):
        rubric = self.spec.rubric_criteria()
        judge_ids = [c["id"] for c in rubric["judge_criteria"]]
        self.assertEqual(judge_ids, ["naturalness", "grammar", "warmth", "brevity"])
        deterministic = {c["id"]: c for c in rubric["deterministic_criteria"]}
        for expected in ("honorific_agreement", "no_ai_isms",
                         "particles_within_budget"):
            self.assertIn(expected, deterministic)
        self.assertEqual(deterministic["honorific_agreement"]["threshold"], 0.98)
        self.assertEqual(deterministic["no_ai_isms"]["threshold"], 0.98)
        self.assertEqual(deterministic["honorific_agreement"]["source"], "register")
        self.assertEqual(deterministic["no_ai_isms"]["source"], "ai_isms")
        self.assertEqual(deterministic["particles_within_budget"]["source"],
                         "particles")
        self.assertEqual(rubric["judge_mean_threshold"], 4.0)

    def test_persona_clause_is_the_one_embeddable_clause(self):
        clause = self.spec.persona_clause()
        self.assertEqual(clause, self.spec.section_text("persona_clause"))
        self.assertNotIn("\n", clause)
        self.assertLess(len(clause), 600)
        for token in ("तपाईं", "हजुर", "भन्नुभयो", "गर्नुभयो", "तिमी"):
            self.assertIn(token, clause)

    def test_coverage_inventory_lists_the_conversation_classes(self):
        ids = [entry["id"] for entry in self.spec.coverage_classes()]
        for expected in ("greeting", "farewell", "thanks", "wellbeing",
                         "health_adjacent_small_talk", "family",
                         "weather_and_time", "code_switched_nouns"):
            self.assertIn(expected, ids)

    def test_sentence_shape_encodes_the_brevity_rule(self):
        shape = self.spec.sentence_shape()
        self.assertEqual(shape["word_order"], "SOV")
        self.assertEqual(shape["max_sentences"], 2)
        self.assertTrue(shape["no_echo_user_words"])
        self.assertTrue(shape["one_idea_per_sentence"])

    def test_guard_checks_use_the_shared_single_origins(self):
        checks = self.spec.guard_checks()
        self.assertEqual(checks["latin_allowlist"], [])
        sources = {c["id"]: c["sources"] for c in checks["checks"]}
        self.assertEqual(set(sources), {"honorificAgreement", "devanagariPurity",
                                        "danglingParticle"})
        self.assertIn("particles.units", sources["danglingParticle"])
        self.assertIn("register.forbidden_address_forms",
                      sources["honorificAgreement"])
        self.assertIn("code_switch.nouns", sources["devanagariPurity"])


# ---------------------------------------------------------------------------
# One rule, one origin: the budget and the ban list live in one section only
# ---------------------------------------------------------------------------

class SingleOriginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = ss.load()

    def _blocks_with_key(self, key):
        return [name for name in self.spec.block_names()
                if key in self.spec.block(name)]

    def test_the_particle_budget_has_exactly_one_origin(self):
        self.assertEqual(self._blocks_with_key("budget"), ["particles"])
        self.assertEqual(self.spec.particle_budget(), 1)

    def test_the_ai_ism_ban_list_has_exactly_one_origin(self):
        self.assertEqual(self._blocks_with_key("forbidden"), ["ai_isms"])

    def test_the_particle_lexicon_has_exactly_one_origin(self):
        self.assertEqual(self._blocks_with_key("units"), ["particles"])

    def test_guard_inputs_compose_from_the_single_origins(self):
        inputs = self.spec.guard_check_inputs()
        register = self.spec.register()
        self.assertEqual(inputs["danglingParticle"]["particle_budget"],
                         self.spec.particle_budget())
        self.assertEqual(inputs["danglingParticle"]["particle_lexicon"],
                         self.spec.particle_lexicon())
        self.assertEqual(inputs["honorificAgreement"]["forbidden_address_forms"],
                         tuple(register["forbidden_address_forms"]))
        self.assertEqual(inputs["honorificAgreement"]["non_honorific_verb_forms"],
                         tuple(register["non_honorific_verb_forms"]))
        self.assertEqual(inputs["devanagariPurity"]["latin_allowlist"], ())


# ---------------------------------------------------------------------------
# Failure paths: a missing section fails loudly, naming it — no defaults
# ---------------------------------------------------------------------------

class MissingSectionFailureTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def _spec_file(self, sections, version="1"):
        return _write(self.tmp / "style-spec", _render_spec(sections, version))

    def test_a_missing_register_section_fails_loudly_naming_it(self):
        sections = _base_sections()
        del sections["register"]
        path = self._spec_file(sections)
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(path)
        message = str(raised.exception)
        self.assertIn("missing required section", message)
        self.assertIn("register", message)

    def test_a_missing_particles_section_is_not_defaulted(self):
        sections = _base_sections()
        del sections["particles"]
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(self._spec_file(sections))
        self.assertIn("particles", str(raised.exception))

    def test_a_missing_required_machine_block_names_section_and_block(self):
        sections = _base_sections()
        sections["register"] = (sections["register"][0], None)
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(self._spec_file(sections))
        self.assertIn("register:register", str(raised.exception))

    def test_a_section_without_rule_text_is_rejected(self):
        sections = _base_sections()
        sections["persona_clause"] = ("", None)
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(self._spec_file(sections))
        self.assertIn("persona_clause", str(raised.exception))

    def test_a_missing_field_raises_at_the_accessor_and_is_not_defaulted(self):
        sections = _base_sections()
        register = dict(sections["register"][1]["register"])
        del register["forbidden_address_forms"]
        sections["register"] = (sections["register"][0], {"register": register})
        spec = ss.load(self._spec_file(sections))
        with self.assertRaises(ss.StyleSpecError) as raised:
            spec.guard_check_inputs()
        message = str(raised.exception)
        self.assertIn("register", message)
        self.assertIn("forbidden_address_forms", message)
        self.assertIn("no default", message)

    def test_a_missing_header_version_is_rejected(self):
        sections = _base_sections()
        text = _render_spec(sections).replace("style_spec_version: 1\n", "")
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(_write(self.tmp / "style-spec", text))
        self.assertIn("style_spec_version", str(raised.exception))

    def test_the_cli_exits_non_zero_naming_the_missing_section(self):
        sections = _base_sections()
        del sections["register"]
        path = self._spec_file(sections)
        result = _run_cli("--spec", str(path), cwd=self.tmp)
        self.assertEqual(result.returncode, 1)
        self.assertIn("register", result.stderr)
        self.assertIn("missing required section", result.stderr)


class StructuralValidationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def _spec_file(self, text):
        return _write(self.tmp / "style-spec", text)

    def test_a_duplicated_section_is_rejected(self):
        sections = _base_sections()
        text = _render_spec(sections)
        text += "\n## section: register\nDuplicate.\n"
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(self._spec_file(text))
        self.assertIn("twice", str(raised.exception))

    def test_invalid_json_in_a_block_names_section_and_block(self):
        sections = _base_sections()
        text = _render_spec(sections)
        text = text.replace('"budget": 1,', '"budget": oops,')
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(self._spec_file(text))
        message = str(raised.exception)
        self.assertIn("particles", message)
        self.assertIn("not valid JSON", message)

    def test_particle_units_must_be_ordered_longest_match_first(self):
        sections = _base_sections()
        sections["particles"] = (sections["particles"][0], {"particles": {
            "budget": 1, "units": ["है", "हुन्छ नि"], "longest_match_first": True}})
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(self._spec_file(_render_spec(sections)))
        self.assertIn("longest-match-first", str(raised.exception))

    def test_trailing_whitespace_in_rule_text_is_rejected(self):
        sections = _base_sections()
        sections["register"] = ("Register rule for the elder. ",
                                sections["register"][1])
        with self.assertRaises(ss.StyleSpecError) as raised:
            ss.load(self._spec_file(_render_spec(sections)))
        message = str(raised.exception)
        self.assertIn("register", message)
        self.assertIn("trailing whitespace", message)

    def test_a_consumer_that_is_not_a_file_is_a_loud_error(self):
        spec = ss.load()
        with self.assertRaises(ss.StyleSpecError):
            ss.check_consumer_file(self.tmp / "missing-consumer.txt", spec)


# ---------------------------------------------------------------------------
# The traceability check: clean fixture passes, drifted fixture fails
# ---------------------------------------------------------------------------

class DriftCheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.spec = ss.load()

    def test_a_consumer_matching_a_spec_section_passes(self):
        text = self.spec.section_text("register")
        clean = _consumer(self.tmp / "clean_consumer.txt", "register", text)
        self.assertEqual(ss.check_consumer_file(clean, self.spec), [])
        self.assertEqual(ss.check_consumers([clean], self.spec), [])

    def test_swift_style_prefixes_and_verbatim_content_both_pass(self):
        swift = _consumer(self.tmp / "Clean.swift", "persona_clause",
                          self.spec.persona_clause(), prefix="// ")
        verbatim = _consumer(self.tmp / "clean.txt", "persona_clause",
                             self.spec.persona_clause(), prefix="")
        self.assertEqual(ss.check_consumer_file(swift, self.spec), [])
        self.assertEqual(ss.check_consumer_file(verbatim, self.spec), [])

    def test_a_drifted_consumer_is_reported_by_consumer_and_section(self):
        drifted_text = self.spec.section_text("register").replace(
            "तपाईं", "तिमी", 1)
        drifted = _consumer(self.tmp / "drifted_persona.swift",
                            "register", drifted_text, prefix="// ")
        defects = ss.check_consumer_file(drifted, self.spec)
        self.assertEqual(len(defects), 1)
        defect = defects[0]
        self.assertEqual(defect.kind, "drift")
        self.assertEqual(defect.section, "register")
        self.assertIn(str(drifted), str(defect))
        self.assertIn("differs", str(defect))

    def test_multiple_consumers_report_every_defect_and_keep_clean_ones_out(self):
        clean = _consumer(self.tmp / "clean.txt", "persona_clause",
                          self.spec.persona_clause())
        drifted = _consumer(self.tmp / "drifted.txt", "ai_isms",
                            "Never speak as a machine.", prefix="# ")
        defects = ss.check_consumers([clean, drifted], self.spec)
        self.assertEqual(len(defects), 1)
        self.assertEqual(defects[0].section, "ai_isms")
        self.assertIn("drifted.txt", str(defects[0]))

    def test_an_unknown_section_citation_is_a_defect(self):
        bad = _consumer(self.tmp / "unknown.txt", "no_such_section", "text")
        defects = ss.check_consumer_file(bad, self.spec)
        self.assertEqual(len(defects), 1)
        self.assertEqual(defects[0].kind, "unknown_section")
        self.assertEqual(defects[0].section, "no_such_section")

    def test_an_unterminated_citation_is_a_defect(self):
        text = ("# @style-spec-section: register\n"
                "# तपाईं\n")
        bad = _write(self.tmp / "unterminated.txt", text)
        defects = ss.check_consumer_file(bad, self.spec)
        self.assertEqual(len(defects), 1)
        self.assertEqual(defects[0].kind, "unterminated")

    def test_a_mixed_prefix_citation_is_a_defect(self):
        text = ("# @style-spec-section: register\n"
                "# तपाईं\n"
                "no prefix here\n"
                "# @style-spec-section-end: register\n")
        bad = _write(self.tmp / "mixed.txt", text)
        defects = ss.check_consumer_file(bad, self.spec)
        self.assertEqual(len(defects), 1)
        self.assertEqual(defects[0].kind, "prefix_mismatch")

    def test_a_consumer_without_citations_is_clean(self):
        plain = _write(self.tmp / "plain.txt", "no citations here\n")
        self.assertEqual(ss.check_consumer_file(plain, self.spec), [])
        self.assertEqual(ss.format_defects([]), "")


# ---------------------------------------------------------------------------
# CLI (end to end, real subprocess)
# ---------------------------------------------------------------------------

class CliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def test_the_evidence_command_prints_version_and_hash(self):
        result = _run_cli(cwd=self.tmp)  # cwd-independent: default artifact
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("version=1", result.stdout)
        self.assertIn("sha256=", result.stdout)

    def test_the_json_evidence_command_lists_sections(self):
        result = _run_cli("--json", cwd=self.tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record["version"], "1")
        self.assertEqual(len(record["sha256"]), 64)
        for name in ("register", "particles", "persona_clause", "rubric"):
            self.assertIn(name, record["sections"])

    def test_the_drift_check_cli_passes_clean_and_fails_drifted(self):
        text = ss.load().section_text("register")
        clean = _consumer(self.tmp / "clean.txt", "register", text)
        drifted = _consumer(self.tmp / "drifted.txt", "register",
                            text.replace("तपाईं", "तँ", 1))
        ok = _run_cli("--check-consumers", str(clean), cwd=self.tmp)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("clean", ok.stdout)
        bad = _run_cli("--check-consumers", str(drifted), cwd=self.tmp)
        self.assertEqual(bad.returncode, 2)
        self.assertIn("DEFECT", bad.stderr)
        self.assertIn("section=register", bad.stderr)
        self.assertIn(str(drifted), bad.stderr)

    def test_the_drift_check_cli_reports_that_the_spec_is_the_place_to_fix_it(self):
        # The check must fail even when the consumer is "newer" than the spec:
        # the spec, not the consumer, is where a rule changes.
        text = ss.load().persona_clause() + " New locally-invented rule."
        drifted = _consumer(self.tmp / "persona.swift", "persona_clause", text,
                            prefix="// ")
        bad = _run_cli("--check-consumers", str(drifted), cwd=self.tmp)
        self.assertEqual(bad.returncode, 2)
        self.assertIn("section=persona_clause", bad.stderr)


class StdlibOnlyTests(unittest.TestCase):
    def test_the_loader_imports_only_the_standard_library(self):
        tree = ast.parse(SRC_PATH.read_text(encoding="utf-8"))
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                if node.level == 0 and node.module:
                    imported.add(node.module.split(".")[0])
        self.assertTrue(imported <= STDLIB_IMPORTS,
                        f"non-stdlib imports: {sorted(imported - STDLIB_IMPORTS)}")

    def test_the_loader_runs_under_an_isolated_interpreter(self):
        # -I: no user site-packages, no PYTHONPATH — proves stdlib-only at run
        # time, the training-box contract.
        result = subprocess.run(
            [sys.executable, "-I", str(SRC_PATH)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("version=", result.stdout)


if __name__ == "__main__":
    unittest.main()
