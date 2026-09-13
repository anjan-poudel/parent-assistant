# T-034 — Training-Data Strategy (Schema-v2 Taxonomy + BIO Spans): implementation notes

- **Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-034-training-data-strategy.md`
- **Branch:** `worktree-t034-training-data` (worktree `.claude/worktrees/t034-training-data`, base `840bcd7`) — not merged, not pushed
- **Deliverable type:** design/documentation only — no training run, no model download, no build

## Artifacts committed

| Path | What it is |
|---|---|
| `docs/superpowers/specs/2026-09-13-encoder-training-data-strategy.md` | Narrative strategy: taxonomy reconciliation, BIO/alignment rule, coverage + supply-cap policy, ack_med/refusal rules, governance, worked examples, contradictions found |
| `tools/train-intent/annotation_rules.yaml` | Machine-readable contract (`schema: annotation-rules/v1`) consumed by T-035/T-036: labels, targets, span labels, BIO tags, tokenizer + alignment steps, under-noise policy, row format, validation rules, edge classes, mixture/measurement, governance, teacher/STT pins, 13 worked example rows |

The two artifacts agree by construction: the YAML is the machine-readable form of the
document's tables; the worked examples' utterances, labels and offsets are identical
in both (cross-checked programmatically, see Verification).

## What the strategy decides

- **Taxonomy:** schema v2 only — the 12 `VALID_ACTIONS` values, which are exactly
  `InterpretedCommand.Action` minus the runtime-only `plugin` case. `emergency`
  (1,000) and the abstain edge class (800, action `none` or guessed action, conf
  < 0.4) are first-class and counted; gibberish is `none` at conf < 0.2. All 42
  proposal/MASSIVE-derived labels are reconciled in the mapping table — 20 rejected
  outright (no schema-v2 home), the rest recoloured onto a schema-v2 label with two
  caveats (`HELP` → `emergency` recall-first; `play_radio/play_podcasts` → `music`
  with a content-bank supply limit).
- **Slot supervision:** BIO spans only (6 span labels: contact, time, medication,
  message, topic, app; 13 tags), Unicode-scalar half-open offsets, target =
  `{action, spans, confidence}`. No resolved value may appear in a target — enforced
  by the substring invariant, slot-equals-span-text rule and explicit forbidden-value
  checks.
- **Alignment:** word-first annotation projected through the XLM-R sentencepiece
  offset mapping (T-033's C3 tokenizer, 250,037 vocab, revision `08dc4816…`);
  first-subword tagging of word tags; decoding via the offset mapping so `▁` never
  leaks. Whole-word merges ("माइयालाई") widen the span; separate particle tokens are
  excluded. T-033's lossy slot masking (~35% of rows) is replaced by an authoring
  invariant: non-alignable rows are refused at build time and counted.
- **Under STT noise:** spans are re-annotated on the noised transcript, never
  inherited (the inherited fields in `stt_noise.py:138-145` are provenance only);
  non-supporting rows are dropped/relabelled and counted; emergency is never dropped.
- **Coverage:** 60% stt-noised / 25% clean Devanagari / 15% romanised+code-switched
  against the existing `config.yaml:mixture` keys, with the existing
  bucket/register map, a measurement plan (per bucket, per register inside noised,
  per action, per edge family, span-bearing rows, refusals/drops), and supply caps:
  never pad, never silently renormalise, edge rows never sampled away, floors
  (`stt_noised` ≥ 0.55, per-action ≥ 0.25 × target, corpus ≥ 8,000 rows).
- **ack_med gap:** sources named (add the intent to `seeds/intents.yaml` so the
  teacher expands it; refusal family labelled `none`; `data/edge_cases.jsonl`
  continues as stopgap), target 800 split ≥ 500 positives / ≥ 300 refusals, and the
  build must refuse any `ack_med` row carrying a refusal marker — refusal must never
  fire ack (golden gc-ack-002 pins this). Corrections keep schema-v2 meaning:
  "होइन, फोन नै गर" → action `call` with the `app` span "फोन".
- **Governance:** golden corpus held out with the existing normalized-leak refusal
  preserved for the BIO row format; real user utterances only via the
  explicit-consent `IntentLogStore` export bundle (NFR-015), with the spec §11
  "encrypted bundle" gap recorded rather than assumed.

## Verification performed (no build, no training)

- YAML parses (`PyYAML 6.0.2`, Python 3.12); tag set = `O` + 2 × 6 span labels = 13.
- Programmatic equality check: `set(annotation_rules.taxonomy.labels) ==
  build_dataset.VALID_ACTIONS` (parsed from source) and `==` the rawValues of
  `InterpretedCommand.Action` minus `plugin` — all three match.
- Every worked example re-checked: `utterance[start:end] == text` for all spans,
  every action in the 12-label set, all 6 span labels covered.
- Scan: no proposal/MASSIVE-derived label string appears anywhere in
  `annotation_rules.yaml`.
- Doc↔YAML cross-check: all example utterances/spans and all spec §9.1 targets
  present in both.

No test suite is added: the task is a design deliverable and the repository's
pipeline code is not modified (all required code changes are named as T-036 scope in
the strategy). Coverage/percentage rules do not apply to documentation.

## Decisions and deviations

1. Followed the task's suggestion: narrative under `docs/superpowers/specs/`, rules
   next to `seeds/` at `tools/train-intent/annotation_rules.yaml`.
2. Span convention follows the T-034 Gherkin pin (`डाक्टरलाई` — surface-exact,
   affix-merged tokens included; separate particles excluded) even though the golden
   corpus stores resolver-ready slot values (`माइया` for `माइयालाई`). The mismatch is
   recorded as a T-035/T-038 normalization requirement instead of weakening the pin.
3. Proposed non-zero targets for `create_calendar_event` (600) and `suggest_video`
   (500) because both are shipped actions (honest stubs) with zero seeds and no
   spec §9.1 count; marked as proposed, not spec-derived.
4. Did not modify `seeds/intents.yaml`, `gen_teacher.py` or `build_dataset.py`: this
   task defines the data contract; implementing it is T-036's DoD. The required
   changes are named with exact file:line references so T-036 cannot miss them.

## Contradictions found (real code vs the task's assumptions)

1. `ack_med` is not merely under-supplied — it does not exist in
   `seeds/intents.yaml`; `teacher.jsonl` produced 0 rows (measured in
   `build_dataset.py:44-48`, `docs/OPEN-ITEMS.md:127-133`).
2. `create_calendar_event` / `suggest_video` have no seeds and no spec §9.1 target
   despite being shipped actions.
3. "Edge rows are never sampled away" is only true for `edge_cases:*` today;
   teacher-born edge rows are sampled like ordinary rows
   (`build_dataset.py:222-231`).
4. The abstain/gibberish confidence bands disagree between the seed notes (< 0.4 /
   < 0.2) and `gen_teacher.edge_ok` (< 0.5 / < 0.3), and the abstain prompt text
   says "< 0.4" while its validator accepts < 0.5.
5. T-033's spike masked the slot loss on ~35% of slot rows (why contact F1 was
   0.333); the BIO row format removes the possibility by construction, but
   `eval_golden.py` still compares resolver-ready golden values against surface
   spans — a T-035/T-038 normalization step.
6. Spec §11 says "encrypted bundle"; `IntentLogStore.exportURL()` writes plaintext
   JSONL to tmp (encryption gap recorded).
7. `README.md:8` says the teacher is "Gemini 2.5 Flash" but `config.yaml:7` is
   `gemini-2.5-flash-lite` (config is the source of truth).
8. `noised.jsonl` rows inherit clean slot strings that no longer match the noised
   transcript; the strategy forbids using them as supervision.

## Not done / open

- **Lead-engineer review** (DoD item) is not claimed by this task — the branch is
  left for integration and review.
- The strategy is unexecuted by design: no dataset was built, no teacher/STT run
  was made. Measured supply figures cited in §5.4 are from the round-2 records in
  `docs/OPEN-ITEMS.md`, not re-measured here (the data lives on the training box and
  disk is critically low on this host).
- T-035/T-036 open items are listed in the strategy §9 and the YAML `consumers`.
