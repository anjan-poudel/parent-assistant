# T-180 — Provenance manifest and ship-mix enforcement (implement notes)

**Status: implemented; module GREEN at the wave close — `tests.test_provenance_manifest`
52/52 after the Wave-close rework below (five reds found by the consolidated pass,
all fixed), `py_compile` clean, offline non-build checks green.** Tests were
authored in-unit per the still-binding authoring discipline; execution moved to
the wave close per amendment 4.
Worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`, HEAD `5367b539`). Declared files only.

| File | Role |
|---|---|
| `tools/train-intent/src/build_chat_corpus.py` (3,191 lines; +897 net, T-179's 2,294) | T-179's builder + the licence registry, the three provenance checks, `assert_provenance`, the manifest emitter (run-directory location, closed key sets), `--manifest-out`, `EXIT_PROVENANCE` |
| `tools/train-intent/tests/test_provenance_manifest.py` (1,194 lines, new) | 52 unittest cases in 9 classes: registry/classification/ship-mix pins, executed-build counts, consent refusal + bypass backstop, manifest emission + no-user-content, build/CLI failure paths, the recorded-fixture CLI end-to-end, a `--plan` subprocess check |

Inputs consumed (interfaces, never re-authored): `src/style_spec.py` (the spec
object; its `sha256` is recorded in the manifest and keys the GEC cache);
`eval/author_chat_golden.py` (`batch_plan`, `_batch_record`, `_header_record`,
`_turn_record`, `_write` — the synthetic held-out fixture is authored through
them, so a fixture-schema change breaks the test rather than silently changing
what the guard protects; `ChatGoldenError` is the fixture transport's failure
mode); `src/pipeline_guards.py` (`canonical_json`, `sha256_bytes`, `sha256_file`,
`write_json`, `assert_not_golden_input`, the 0–4 exit vocabulary);
`src/build_dataset.py` (`normalize` / `lossless_key`, read through T-179).

## How each acceptance criterion is executed

1. **The manifest is emitted by the SAME builder, into the run directory** —
   `write_provenance_manifest()` is called by `build_chat_corpus()` itself
   (there is no second producer): after `assert_provenance()`, after
   `_write_outputs()`, before `_counters_dict()` — so the counters carry the
   manifest's `content_hash` (the pairing that binds the artifact to the gate
   results) and the manifest exists only when a corpus was written.
   `manifest_path_for()`: the run directory (the corpus directory's parent — the
   design's `build/<run-id>/provenance-manifest.json`, beside the gate evidence);
   `--manifest-out` overrides; the DEV mix writes `provenance-manifest.dev.json`
   so a dev build can never overwrite the ship compliance artifact. Pinned by
   `ManifestTests.test_the_manifest_is_written_in_the_run_directory` /
   `..._is_the_design_path_in_the_cli_layout`.
2. **Every source and tooling input with licence, layer, classification,
   counts used and derived artifacts** — every manifest carries all 18 training
   sources and all 5 tooling inputs (FR-CNR-018): per source
   `license / license_family / classification / mix / admissible_to_ship /
   counts{candidates,admitted,selected} / derived_artifacts` (+ provenance,
   source_path, present, status, reason, consent fields); tooling entries carry
   the run's own stage evidence (GEC calls/cache entries, L3 turns, post-edit
   batches, translation-tier participation, STT-noise variants) and a tier that
   did not run says `not_exercised` with a reason rather than being omitted.
   The derived-artifact invariant is exact and pinned: a layer file is derived
   iff the source admitted > 0 turns, the corpus iff it was selected > 0 (a
   refused/excluded source derives nothing). Pinned by
   `test_every_source_appears_with_licence_layer_classification_counts_and_artifacts`,
   `test_the_derived_artifacts_are_artifacts_this_build_wrote`,
   `test_tooling_inputs_are_classified_and_never_omitted`.
3. **The held-out chat set recorded EXCLUDED** — `held_out_record`:
   `chat_golden` status `excluded` with revision / turns / sha256 /
   `exact_dedupe_keys` and the "EXCLUDED … never trained on" reason; the two
   eval fixtures `excluded` with their refusal reasons; the same sources appear
   in the per-source list as `excluded`, `mix: none`, no derived artifacts.
   Pinned by `test_the_held_out_chat_set_is_recorded_as_excluded`.
4. **The ship-mix assertion is CODE inside the build** — `ship_mix_check()`
   over the admitted per-source counts admits only CC-BY / Apache-2.0 / MIT /
   synthetic / own data; the never-admissible pin (`indic_dialogue_ne`,
   `dailydialog`, `personachat_convai2`, `empathetic_dialogues`,
   `call_center_transcripts`) is verified against the CURRENT registry each run
   (a promotion is `non_admissible_source_promoted`; a removal is
   `non_admissible_source_missing` — the check is never allowed to silently
   outdate). A violation FAILS the build naming source and licence:
   `ProvenanceError` → CLI prints `[provenance] FAILED: …` + the REJECTED line,
   records `stopped: true` / `provenance.verdict: fail` /
   `ship_mix_eligible: false` / the named violations in the counters, returns
   **`EXIT_PROVENANCE` (5)** and writes NO corpus and NO manifest. The
   assertion record cites the licence registry it used
   (`license_registry_record`: id `chat_corpus_license_registry/v1` + sha256
   over its entries) and is embedded in both the manifest and the counters.
   Preflight: the classification + pin checks run before any source read or
   teacher spend; the full assertion (with admitted-turn counts) runs before
   any output is written. Pinned by `ShipMixFailureTests` (direct + CLI),
   `CliEndToEndTests.test_the_cli_refuses_a_contaminated_registry_before_any_spend`,
   and the pure `ShipMixCheckTests` (admissible passes; each named source fails
   naming id + licence; dev records `not_applicable`).
5. **A source with no recorded classification FAILS the build** —
   `classification_violations()`: an `admissibility` outside `CLASSIFICATIONS`
   (empty, "maybe") or a missing licence record is `missing_classification`;
   nothing is defaulted into either mix. The recorded value `unclassified` is a
   *classification* with the recorded meaning (licence not recorded → refused
   from both mixes, counted `unclassified_source`) — the two failure modes are
   kept distinct, and the tests pin both. Pinned by `ClassificationTests` and
   `test_an_unclassified_present_source_fails_the_build`.
6. **Consent (FR-CNR-029) — a real-transcript source without its consent record
   is REFUSED from both mixes with the reason recorded** —
   `source_consent_missing()` drives three layers: the source-level refusal
   during staging (`unconsented_transcript`, manifest status `refused`, `mix:
   none`, the no-silent-harvest reason), the preflight record
   (`consent_refusals()`, same source, `mix: none`), and a bypass backstop
   (`unconsented_transcript_in_mix`) that fails any build in which such a
   source nevertheless contributed admitted turns. The tests exercise BOTH
   mixes, the consented control case (admitted as `own data`), and the bypass
   backstop. The P2 consent leg is T-191; the refusal stands until then.
7. **The content hash is stable across re-emissions + the artifact carries no
   user content** — `content_hash` = sha256 over the document minus
   `content_hash` / `content_hash_scope`, canonical JSON (sorted keys, compact);
   two fresh builds of the same inputs are byte-identical (manifest, corpus,
   counters — no wall-clock, no absolute path); the tests recompute the hash
   from the document itself. No user content: closed key sets (20 body keys,
   18 source-entry keys, 14 tooling-entry keys), no fixture text, no Devanagari
   codepoint anywhere (the corpus is Devanagari — any turn text leaking in
   trips the scan), no corpus row text, no `user_turn` / `acceptable_output`
   strings — counts, licences and identifiers only. Pinned by
   `test_the_content_hash_*`, `test_the_manifest_carries_no_user_content`,
   `test_each_artifact_carries_its_own_hash_and_row_count`, and the
   gate-evidence co-location test (the manifest travels beside the run's
   evidence and its hash is the pairing value the gate harness records).

## Executed vs recorded (honesty record)

**A. Executed in-unit (all allowed by amendment 4 — no test execution, no
build):**

1. `python3 -m py_compile src/build_chat_corpus.py tests/test_provenance_manifest.py`
   → clean.
2. An offline pure-function pass (import check + the check functions over the
   shipped registry): constants + `build_parser` carries `manifest_out` +
   the docstring documents exit 5; `classification_violations()` /
   `consent_refusals()` / `non_admissible_ship_sources()` violations empty on
   the shipped registry; every registry + tooling licence resolves to a
   recorded family; `ship_mix_check` fails naming source+licence for
   `indic_dialogue_ne` and `research-gated` for the transcripts, passes for
   admissible counts, records `not_applicable` for dev; the manifest path
   layout (run dir + dev suffix); `_source_entry_record` /
   `_tooling_record` emit EXACTLY the closed key sets the tests pin; a refused
   entry records `mix: none`. → `OFFLINE_CHECKS_OK`.
3. The manifest DOCUMENT assembled in memory (no build, no writes —
   `assert_provenance` on a clean registry + `provenance_manifest` with empty
   selections and the REAL held-out guard): 20 body keys == the test's
   `MANIFEST_KEYS`, 18 sources, 5 tooling, entry key sets exact, no Devanagari
   codepoint, no `user_turn` / `acceptable_output` strings, `content_hash`
   recomputation equal, and the unclassified mutation raising with
   `ship_mix_eligible is False`. → `MANIFEST_OFFLINE_OK`.
4. `git status --porcelain` → only the two declared files (plus `.ai-sdd/runs/**`
   state, expected).

**B. Authored, NOT executed in-unit (the wave close runs ONE consolidated
Python pass — the 52-case suite):** admissible ship mix passes; a contaminated
ship mix fails naming source+licence (direct + CLI, exit 5, preflight phase,
no artifact); an unclassified source fails and records ineligible; an
unconsented transcript is refused from both mixes with the reason (ship and
dev) and the bypass backstop fires; the held-out set + eval fixtures are
recorded excluded; tooling is classified (never omitted); the manifest lands in
the run directory with every source, the registry the assertion used, the
held-out exclusion and per-artifact hashes; the hash is stable across two
builds (byte-equal files) and carries no user content; the dev manifest is
emitted through a spot-check rebuild; the recorded-teacher-fixture CLI replay
writes the manifest beside the corpus with matching hashes and exit 4
(shortfalls recorded); `--plan` documents the rule from a real subprocess.

**C. Recorded, not executed anywhere yet:** a real corpus build against the
training-box sources (T-183), the real teacher transports, and the gate
harness consuming `provenance.content_hash` (T-182's harness work).

## Test results (exact commands)

1. `python3 -m py_compile src/build_chat_corpus.py tests/test_provenance_manifest.py`
   → clean (exit 0; re-run after every wave-close rework edit).
2. The offline checks in A2/A3 above → `OFFLINE_CHECKS_OK` /
   `MANIFEST_OFFLINE_OK 20 keys; 18 sources; 5 tooling`.
3. **In-unit (amendment 4): no `unittest` invocation and no corpus build.** The
   wave close then ran the consolidated six-module pass
   (`python3 -m unittest tests.test_provenance_manifest tests.test_build_chat_corpus
   tests.test_eval_chat_gates tests.test_prompt_mirror_chat tests.test_chat_golden
   tests.test_style_spec`): 410 tests, **0 reds in the five pre-existing
   modules, 5 reds in this module** — all fixed under the recorded narrow
   exception (the Wave-close rework section records each root cause).
4. `python3 -m unittest tests.test_provenance_manifest` (the rework's single
   scoped run) → `Ran 52 tests in 1.939s` — **OK (52/52)**.

## Decisions and deviations

1. **Run-level eligibility is the AND of every provenance check** (fix applied
   this unit). `assert_provenance` previously stored the licence-family
   assertion's own verdict as the run's `ship_mix_eligible` — so an
   unclassified-source failure (which fails the build) could still have
   recorded `eligible: true`. Now `eligible = bool(assertion["ship_mix_eligible"]
   and not (missing or pin["violations"] or bypassed))` — every check must pass
   for the artifact to claim ship-mix eligibility. Pinned by
   `test_the_build_fails_on_an_unclassified_source_and_reports_it`
   (`error.record["ship_mix_eligible"] is False`). The preflight failure record
   (the classification / pin check before any source read or teacher spend)
   carries `ship_mix_eligible: False` itself as well — added in the wave-close
   rework (root cause 3), so the direct-build failure path records
   ineligibility without depending on the CLI's stamp.
2. **Refused/excluded manifest entries record `mix: "none"`** (fix applied this
   unit). The entry's `mix` derived from the classification alone, so a
   consent-refused `ship`-classified source recorded `mix: "ship"` — while
   `consent_refusals()` records the same refusal as `mix: "none"`. The manifest
   now agrees with the preflight record: a refused source belongs to neither
   mix (its `status` + `reason` carry the refusal). Pinned by the consent
   tests (ship and dev) and the held-out exclusion test.
3. **`EXIT_PROVENANCE = 5`** — a new exit code outside the guards 0–4
   vocabulary: a contaminated mix is neither a floor miss (4) nor a guard stop
   (3) — the artifact is REJECTED as a compliance event and the run cannot
   claim ship-mix eligibility. Documented in the module docstring; pinned by
   test.
4. **The dev manifest is mix-qualified** (`provenance-manifest.dev.json`) so a
   dev build can never overwrite the ship compliance artifact; explicit
   `--manifest-out` wins. Pinned by `test_the_manifest_is_the_design_path_in_the_cli_layout`.
5. **The witness for the ship-mix rule over EXECUTED counts is the L1 CC BY-NC
   layer** (`indic_dialogue_ne`), with the pending L2 batch recorded where its
   hold actually lives. A fresh dev build holds its L2 post-edit batches
   pending the human spot-check: the candidates are LAYER-admitted (they land
   in `layers/L2.jsonl` and the file-backed per-source `admitted` count) but
   MIXTURE-excluded (`selected = False` + `hold("pending_spot_check")`, design
   §11.2 — no corpus row, manifest `counts.selected` 0). `RealCountsTests`
   asserts exactly that split (L1 witness ≥ 1 and named with its licence; the
   held batch admitted ≥ 1 with `selected == 0`, in the L2 layer file, absent
   from the corpus) — the corrected form from the wave-close rework, which had
   wrongly asserted the flat `admitted` count to be 0.
6. **Manifest before counters, one computation cited twice** —
   `assert_provenance` computes the record once; the manifest embeds it and
   the counters' provenance block references the manifest's `content_hash`.
   Pinned by equality assertions between the manifest and the counters.
7. **Data-not-code registry tests** — the family table, the pin ids and the
   tooling sources are read from the module under test; registry mutations use
   `mock.patch.object` over copies of `SOURCE_REGISTRY` / `SOURCES_BY_ID` /
   `TOOLING_SOURCES`, so a registry change moves the check (a promoted source,
   a removed pin id, an emptied admissibility each fail loudly).
8. **Fixture texts are T-179's verified collision-free set**, so the CLI
   end-to-end runs with the REAL held-out guard offline and the teacher seam
   is replayed from a fixture the test records itself (no network anywhere).
9. **Timestamp boundary** — corpus, counters and manifest carry no wall-clock
   (byte-identical re-emissions pinned); the only timestamp is in the human
   `l2-review.json` spot-check record, a legitimate new input the dev-manifest
   test consumes (so its rebuild exercises the real review flow).
10. **Declared files only; no commits, no pushes, no ai-sdd mutating
    commands.** The only artifact outside the two declared files is this notes
    file.

## Wave-close rework (2026-10-14)

The wave close ran the consolidated six-module Python pass: **410 tests, 0
reds in the five pre-existing modules, 5 reds in this module** — all five
raised only through execution (the in-unit offline passes could not see them).
The coordinator authorized the recorded narrow exception: fix, then run ONLY
`tests.test_provenance_manifest` until green — no other modules, no corpus
builds, no network. Root causes, each verified against the code before
changing:

1. **Manifest counts are NESTED**
   (`test_every_source_appears_with_licence_layer_classification_counts_and_artifacts`)
   — `KeyError: 'admitted'`: the flat `admitted` key is the COUNTERS file's
   shape (`_counts_from` reads it there); manifest entries nest
   `counts: {candidates, admitted, selected}`. TEST-SIDE. Fix:
   `entries[source_id]["counts"]["admitted"]`.
2. **Corpus rows nest the assistant turn**
   (`test_the_manifest_carries_no_user_content`) — `KeyError: 'reply'`:
   `_turn_record` emits `user_turn` top-level but
   `assistant: {reply, gec[, intent]}`. TEST-SIDE. Fix:
   `row["assistant"]["reply"]`.
3. **The preflight failure record omitted `ship_mix_eligible`**
   (`test_an_unclassified_present_source_fails_the_build`) — `KeyError`: the
   CLI handler stamps `False` and `assert_provenance`'s own record carries it,
   but the direct-build preflight record (classification / pin check, before
   any source read or teacher spend) did not. IMPL-SIDE. Fix: the preflight
   record now carries `ship_mix_eligible: False` (consistent with decision
   1's AND-semantics: a failed preflight is not eligible).
4. **`--plan`'s provenance line was not fully interpolated**
   (`test_plan_reports_the_ship_mix_rule_and_the_manifest`) — the captured
   stdout contained the literal `exit {EXIT_PROVENANCE}`: only the first
   adjacent fragment carried the `f` prefix, so the `{EXIT_PROVENANCE}`
   fragment printed verbatim (the docstring's exit-code line, in `__doc__`,
   was already correct — which is why that assertion passed). IMPL-SIDE.
   Fix: that fragment is an f-string; `--plan` now prints `exit 5`.
5. **The pending-spot-check hold is MIXTURE-exclusion, not
   layer-exclusion** (`test_a_real_dev_mix_corpus_fails_the_check_when_claimed_as_ship`)
   — the test asserted `counts["dailydialog"] == 0`; the executed build
   records 1. Verified in the production code before touching anything
   (and against T-179's notes/pins): the admission stage puts every kept
   candidate into `admitted` (file-backed per-source count +
   `layers/L2.jsonl`); the L2 spot-check gate then sets
   `candidate.selected = False` + `counters.hold("pending_spot_check")` and
   excludes it from the MIXTURE (`visible`) only — the corpus and `selected`
   stay 0, which is exactly T-179's recorded contract ("held out of the
   mixture"; the 4-row pending dev corpus). **No production semantics were
   changed.** TEST-SIDE. Fix: the test asserts the split exactly — L1 witness
   `indic_dialogue_ne` ≥ 1 and named with its licence; the held batch
   admitted ≥ 1, `counts.selected == 0`, present in `layers/L2.jsonl`, absent
   from the corpus rows, `hold("pending_spot_check")` recorded, and
   `dailydialog` named among the ship-mix violations again.

**Module verdict:** `python3 -m py_compile` clean after every edit;
`cd tools/train-intent && python3 -m unittest tests.test_provenance_manifest`
→ `Ran 52 tests in 1.939s` — **OK (52/52)**. No other module was run; nothing
under `ios/` or any other unit's files was touched; HEAD stayed `5367b539`.

## Open items

* **T-182 (gate harness):** record `provenance.content_hash` (from
  `provenance-manifest.json`, or `chat-corpus-counters.json`'s
  `provenance.content_hash`) beside the gate evidence in the run directory;
  the manifest's `pairing` note names this contract. A dev run's manifest is
  mix-qualified (`provenance-manifest.dev.json`).
* **T-183 (training box):** the 13 absent source files; a real corpus build
  (the manifest then records real GEC / L3 / post-edit counts and the real
  teacher transport substitutions).
* **T-191 (P2 consent leg):** supply `requires_consent=True, consent="<record
  id>"` on a real-transcript source; until then every transcript source is
  refused from BOTH mixes by code, as this unit's contract requires.
* **T-185 / release:** the manifest is a run artifact (`build/` is gitignored);
  if the release checklist wants it archived, the publish step copies run-dir
  manifests beside the corpus they describe.
* **Wave close:** DONE — the consolidated pass ran and this module's five reds
  were fixed (Wave-close rework section); the module is 52/52 green. The
  combined six-module re-run is the coordinator's to repeat.
