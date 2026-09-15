# Encoder quality round-2 campaign — plan (prep, CPU-side)

**Status:** PREPARED, NOT FIRED. Everything below was authored and exercised on a
CPU-only Mac in the worktree `.claude/worktrees/round2-prep` (branch
`worktree-round2-prep`). No training ran, no GPU job ran, no merge was made, and
the pinned corpus was read but never written.
**Owner:** T-036 (encoder pipeline). **Runs against:** the T-035 contract
(`tools/train-intent/encoder_contract.yaml`) and the T-034 rules
(`tools/train-intent/annotation_rules.yaml`).
**Predecessor:** the v4 evaluation (closed-intent ≈ 0.870 on 370 rows) and the v5
run (`t036-full-0.1.0-internal-v5-8kcal-20260914-220729`) whose numbers were not
readable when this plan was written.

---

## 0. What this plan is, and what it is not

The campaign answers two measured weaknesses and adds one gated option:

| | Recipe | Deliverable today |
|---|--------|-------------------|
| **(a)** | **Emergency coverage** — additional emergency surface forms for the families the error analysis called coverage regressions | request list + quotas, generated and validated |
| **(b)** | **Confusion pairs** — contrastive rows for the five pairs the error analysis named, both sides, matched frames | request list + quotas, generated and validated |
| **(c)** | **Distillation leg** — the local Qwen 4B as a soft-label teacher through llama.cpp | **design only**: the teacher tool does not exist in this repo, and the KD branch cannot consume a measured distribution; §5 states the exact prerequisites |
| **(d)** | **v6 launch** — the exact chain to fire once (a)+(b) have produced rows | command template, fill-in-the-blank, §6 |

Honest scope notes, all of which matter at fire time:

- **No teacher has run here.** `gen_distill.py` and `distill.jsonl` do not exist
  anywhere in this repository (verified by exhaustive file search); they may
  exist on the training box as out-of-repo tooling — check with
  `ls src/gen_distill.py data/distill.jsonl` before assuming P-1 applies. Either
  way the request list is written against a *documented request schema* (§4.4),
  not against a runner's CLI, and `qa_round2_rows.py` enforces that schema, so an
  existing runner that speaks a different one fails loudly at the QA gate rather
  than silently upstream.
- **The v5 numbers were not readable.** §1.4 defines exactly what to read the
  moment they are, and `gen_round2_requests.py --confusion` turns those numbers
  into an advisory alignment against this plan's quotas.
- **The three CPU-side artifacts were run** (request generator, QA gate, and an
  E1 build dry-run), and their findings changed this plan twice — see §2.5,
  §4.3 and §4.5. Verified exit codes: 0 (clean), 3 (held-out corpus as input;
  unattributed ids), 4 (quota hold).

---

## 1. Where round 2 starts

### 1.1 What the v4 error analysis named

| Finding | Where it lands |
|---|---|
| emergency recall regressed on grown-corpus rows — **coverage, not confusion** | Recipe (a): EC-1…EC-8 |
| `create_calendar_event` → `set_reminder` | Recipe (b): CP-1a/CP-1b |
| guide breadth (plus its `query` boundary) | Recipe (b): CP-2a/CP-2b |
| `health_query` advice phrasings (plus the emergency boundary) | Recipe (b): CP-3a/CP-3b |
| `ack_med` declaratives (plus the refusal boundary) | Recipe (b): CP-4a/CP-4b |
| `suggest_video` → `music` | Recipe (b): CP-5a/CP-5b |
| supply-capped clean buckets | §4 — the mixer arithmetic says this is the binding constraint |

### 1.2 What the corpus is now

The held-out corpus is `eval/golden_corpus.jsonl`, **8,000 rows**, revision
`7f71b8ae`, sha256 `7f71b8aee37291a64deeba609864ac5f655c9926d6ecafda47377bedfad73648`.
Per intent: call 1200, set_reminder 960, emergency 800, send_message 800,
query 800, ack_med 640, health_query 560, music 480, guide 480,
create_calendar_event 480, none 400, suggest_video 400.
The adversarial set is `eval/emergency_nearmiss.jsonl`, **50 rows**
(30 `emergency_paraphrase` + 20 `calm_pain_health`).

### 1.3 The distinctness rule (the campaign's first hard constraint)

A round-2 row must not be a paraphrase of a held-out row. Enforced twice:

1. **By construction** — `gen_round2_requests.py` drops every candidate seed whose
   `build_dataset.normalize()` form is present in the golden corpus **or** the
   near-miss set. On the authored banks this drops **70 of 692 candidate seeds**
   (≈10%), overwhelmingly emergency forms that converge on the corpus's own
   phrasings — which is itself evidence that the emergency families were thin.
2. **By gate** — `qa_round2_rows.py` re-checks every generated row against both
   held-out sets and drops hits. This is **stricter than the E1 build**, whose
   leak guard covers only the golden corpus
   (`build_encoder_dataset.py` imports `pipeline_guards.golden_keys`), not
   `eval/emergency_nearmiss.jsonl`.

> The E1-only gap is not hypothetical: the near-miss set is an emergency gate
> (`emergency_recall_nearmiss`), so a round-2 emergency row that paraphrases a
> near-miss row would both weaken the gate and be invisible to the build's guard.
> `qa_round2_rows.py` is the only place that closes it. Verified: feeding all 50
> near-miss utterances as round-2 rows rejects 50/50 as `held_out_leak`.

### 1.4 Reading v5 (do this first, on the box)

The run directory is whatever `T036_WORK_DIR` was set to at fire time; the run
name implies a v5 directory, so resolve it first:

```bash
cd tools/train-intent
V5=$(ls -d artifacts/*v5-8kcal-20260914-220729* | head -1); echo "$V5"
ls "$V5" "$V5/logs" | head -40
```

Read, in this order:

1. `"$V5"/build_report.json` → `sources[]` (the exact v6 `--sources` list),
   `buckets.*.supply_capped`, `kept.total`, `per_action`, `edge_families`,
   `floors.unwaived`.
2. `"$V5"/logs/pipeline_*.log` → the E4 harness block: `EMERGENCY RECALL`,
   `emergency near-miss`, `closed-intent`, `slot_f1`, `SIDE-EFFECT PRECISION`,
   `ABSTENTION PRECISION`, and the `[gemini gap]` block.
3. `"$V5"/eval_manifest.jsonl` (last line) → the same numbers machine-readably.
4. The `[closed-intent error]` block, **if present**. It is printed only when the
   Gemini baseline row exists in `eval/results.csv` *and* the gap gate failed,
   and it is capped at 50 rows (`_print_offenders(..., limit=50)`). Treat it as a
   sample, not a population.

For the full population, produce a confusion file (`confusion/v1`) with the
artifact in hand. The harness cannot dump predictions (`--preds` is an *input*
for `--backend fixture` only), so run the same backend the harness runs and count
locally — this is the only step in the campaign that needs the model, and it is
CPU-viable on the box while the GPU is busy:

```bash
# on the box, tools/train-intent, venv with llama-cpp-python (GPU not required)
python - <<'PY'
import argparse, collections, json, sys
from pathlib import Path
sys.path.insert(0, "src")
from config import load_config                 # (args, cfg); needs a parser
from eval_golden import predict_gguf           # the harness's own backend

_args, cfg = load_config(argparse.ArgumentParser())
MODEL = "<absolute path to the v5 intent GGUF>"
rows = [json.loads(l) for l in open("eval/golden_corpus.jsonl", encoding="utf-8") if l.strip()]
pairs, recall = collections.Counter(), {}
for i, r in enumerate(rows, 1):
    p = predict_gguf(r["utterance"], cfg, MODEL)      # memoized on first call
    if p.get("action") != r["intent"]:
        pairs[f"{r['intent']}->{p.get('action')}"] += 1
    if r["intent"] == "emergency":
        t = recall.setdefault("emergency", {"hits": 0, "total": 0})
        t["total"] += 1; t["hits"] += int(p.get("action") == "emergency")
    if i % 500 == 0:
        print(i, "rows", flush=True)
Path("data/round2").mkdir(parents=True, exist_ok=True)
json.dump({"schema": "confusion/v1", "rows": len(rows),
           "pairs": dict(pairs), "recall": recall},
          open("data/round2/v5_confusion.json", "w"), indent=2)
print(sum(pairs.values()), "closed-intent errors;", dict(pairs.most_common(10)))
PY
```

(`predict_gguf(utterance, cfg, model_path)` is the harness's own function; it
memoizes the llama instance, and it uses `seeds/prompt_template.txt` raw — the
same prompt training used. 8,000 rows on a 4B Q4 model is hours on CPU; run it
alongside a busy GPU, not during the v6 fire.)

Then align this plan's quotas against those numbers — advisory, never automatic:

```bash
python src/gen_round2_requests.py --confusion data/round2/v5_confusion.json
```

The report gains `confusion_alignment`, and stdout prints per class
`<planned rows> / <measured errors> = <rows per error>` plus an `UNCOVERED` list
of measured pair errors no class repairs. **If the v5 confusion disagrees with
the v4 findings**, edit the `ASK` table in `src/gen_round2_requests.py` — that
table is the single source of the quota plan — and re-run (deterministic,
seconds). Do not add a class without adding its rows; a class with zero measured
errors is insurance and should stay small.

---

## 2. Recipe (a): emergency coverage — EC-1…EC-8

**Why coverage and not confusion:** the v4 emergency failures were *misses*, not
binary confusions — a symptom stated without a plea, a third person collapsing,
an urgency verb with no symptom. The corpus's emergency family is plea-anchored,
so an unpleaded emergency form is under-supervised and calibrates toward
`health_query`/`none`. These classes supply the missing surface forms; they are
deliberately **not** contrastive (no exclusion cues except where a class would
otherwise invade `call`, see EC-3).

| Class | Target family | Rows | Registers (dev/frag/rom/cs) | Seed frames | Cue discipline |
|---|---|---|---|---|---|
| **EC-1** | bare symptom, no plea | 150 | 68 / 25 / 33 / 24 | 3 | **excludes** मद्दत / बचाउ / सहयोग / help — a plea would move the row into the corpus's existing family and teach nothing new |
| **EC-2** | collapse of another person | 100 | 45 / 17 / 22 / 16 | 3 | none (the speaker is not the patient) |
| **EC-3** | urgency / bring help | 100 | 45 / 17 / 22 / 16 | 4 | **excludes** फोन / कल / call / phone — dialing is `call`, and an urgency row carrying a phone cue would teach `emergency` on a `call` surface |
| **EC-4** | fall / inability to move | 120 | 54 / 21 / 26 / 19 | 3 | none |
| **EC-5** | bleeding / burn / injury | 80 | 36 / 13 / 18 / 13 | 4 | none |
| **EC-6** | breathing / chest / heart | 120 | 54 / 21 / 26 / 19 | 4 | none (highest-consequence miss family) |
| **EC-7** | fear / threat / safety | 80 | 36 / 13 / 18 / 13 | 4 | none |
| **EC-8** | fragmented / self-interrupting | 150 | 68 / 25 / 33 / 24 | 6 | **frozen cue** rule, §2.5 |

Register weights are fixed for every class: **devanagari 45 / elder_fragmented 17 /
romanized 22 / code_switched 16** (per cent of the class's rows). They follow the
clean-bucket split the build samples at — `BUCKET_OF_REGISTER` puts
`devanagari`+`elder_fragmented` on the `clean_devanagari` side (0.62 of clean
rows) and `romanized`+`code_switched` on `romanized_codeswitched` (0.38) — so the
authored supply feeds both buckets in the ratio the mixer draws them.

**Teacher rows per request:** 3 paraphrases per seed
(`--variants 3`). Row counts above are *teacher output rows*: the generator
divides each register's row quota by the variant count and asks for that many
seeds, so `rows_requested` tracks the quota within one request per register.

### 2.5 The frozen-cue rule (found by running it, not by reasoning)

`elder_fragmented` seeds are derived by a deterministic elision transform
(drop one interior word, add a filler). The first run let it drop cue-bearing
words, and `qa_round2_rows.py` rejected the resulting rows
(`class_cue:missing_required_cue:सम्झा`) — correctly: a reminder utterance that
lost its reminder verb is not a fragmented example of `set_reminder`, it is a
different class. The transform now **freezes** every word carrying a class cue
(the same discipline TG-11 writes for clipped-tail elision), and the QA gate
stays as the second line of defence. A cue that is dropped is not a hard failure;
it is a rejected row and a visible shortfall.

---

## 3. Recipe (b): confusion pairs — CP-1…CP-5, both sides

Five pairs, **ten classes**, each pair generated from **matched frames**: both
sides draw from the same time/entity/media banks, so the *frame* is held constant
and only the discriminating cue varies. A row pair that differs in more than the
cue teaches the wrong feature.

| Pair | Side A (class, rows) | Side B (class, rows) | The cue that must carry the label | Devanagari cue | Romanized cue |
|---|---|---|---|---|---|
| `create_calendar_event` ~ `set_reminder` | CP-1a, 120 | CP-1b, 120 | event verb vs reminder verb, over a *shared* time span | राख / मिलाउ vs सम्झाउनु | rakh / milau vs samjhaunu |
| `guide` ~ `query` | CP-2a, 120 | CP-2b, 40 | operation ("how do I run it") vs fact ("what/when is it") | कसरी चलाउने vs कहाँ / के हो | kasari chalaune vs kaha |
| `health_query` ~ `emergency` | CP-3a, 140 | CP-3b, 60 | calm advice question vs the same symptom **plus a plea** | के गर्नुपर्छ (no plea) vs मद्दत/बचाउ/सहयोग | ke garnuparchha vs madat/bachau |
| `ack_med` ~ `none` | CP-4a, 90 | CP-4b, 50 | declarative dose taken vs refusal / not-yet | खाएँ / खाइसकें / लिएँ vs खाएको छैन / पछि | khaye / khaisake vs chhaina / pachhi |
| `suggest_video` ~ `music` | CP-5a, 80 | CP-5b, 80 | watch verb + video noun vs play verb | देखाउ / भिडियो vs बजाउ / सुनाउ | dekhau / video vs bajau / sunau |

Cue enforcement per class (teacher prompt + QA re-check):

- **CP-1a** excludes सम्झा / samjha. **CP-1b** *requires* सम्झा / samjha / samjhana.
  CP-1b's code-switched frame originally read `{time} reminder राख` and was
  **removed**: it put the create-side verb (`राख`) on the reminder side, i.e. it
  taught the confusion rather than resolving it. Caught by a cue check, not by
  inspection.
- **CP-2a** excludes कहाँ / कति / के हो (Devanagari-only; the Latin twins are
  deliberately not excluded — "kati" also appears in legitimate operation
  phrasings such as "कति बेर चलाउने", and over-rejecting there would starve the
  class. This is a known, stated gap in a lexical guard, not a semantic one).
- **CP-3a** excludes मद्दत / बचाउ / सहयोग / help; **CP-3b** requires one of
  मद्दत / बचाउ / सहयोग / madat / bachau / sahayog. **CP-3b is the boundary the
  near-miss set already tests**, so re-sampled near-miss phrasings are dropped by
  §1.3 — the campaign must not memorise the adversarial gate.
- **CP-4b** is labelled `none` and carries the medication words on purpose: the
  refusal family shares the medication *vocabulary* and differs only in polarity,
  which `annotation_rules.yaml`'s refusal-marker guard (छैन, होइन, नाइँ, खाइनँ,
  पछि) enforces at build time. CP-4b's jobs are the missed-dose (`पछि`) and
  bare-refusal forms.
- **CP-5a/5b** share the media nouns (भजन, गीत) and differ on the verb; `लगाउ` is
  excluded from the music side because it is ambiguous on audio nouns, while on
  the video side it is disambiguated by the video noun.

Registers for every CP class use the same 45/17/22/16 mix as §2 —
per-class dev/frag/rom/cs, computed by largest remainder:
CP-1a **54/21/26/19** (=CP-1b, CP-2a), CP-2b **18/7/9/6**, CP-3a **63/24/31/22**,
CP-3b **27/10/13/10**, CP-4a **41/15/20/14**, CP-4b **23/8/11/8**,
CP-5a **36/13/18/13** (=CP-5b).

### 3.1 The quota table (this is the campaign's supply ask)

| Family | Classes | Rows | Purpose |
|---|---|---|---|
| Emergency coverage (a) | EC-1…EC-8 | **900** | repair emergency misses |
| Confusion pairs (b) | CP-1a…CP-5b | **900** | repair five measured confusions, both sides |
| **Total** | 18 classes | **1,800** | → **1,866** teacher rows requested (622 requests × 3; the excess is per-register ceiling rounding) |

By intent: emergency 996, health_query 144, set_reminder 123,
create_calendar_event 123, guide 123, suggest_video 84, music 84, ack_med 93,
none 54, query 42. Emergency dominates because (a) is eight classes and because
the v4 finding was a coverage regression; **if the v5 confusion file says
emergency recall is already at gate, cut EC-1…EC-8 first** (see §1.4).

---

## 4. From authored rows to training rows

### 4.1 The mixer, in the arithmetic that actually runs

`build_encoder_dataset.select_mixture()`:

- `stt_noised` is kept whole and **anchors the total**:
  `total = ceil(n_noised / 0.60)`.
- `clean_devanagari` gets `round(total × 0.25)`, `romanized_codeswitched`
  `round(total × 0.15)`, each filled with edge-priority rows first, then a
  shuffled pool; if the pool is short the bucket is reported `supply_capped`.
- Floors (`annotation_rules.mixture.supply_caps`): `corpus_floor: 8000`,
  `hard_floor_stt_noised: 0.55`, `per_action_floor: 0.25 × taxonomy target`.

**Consequence 1 — the noise stage is mandatory, not optional.** A clean-only
source produces **zero** training rows: with `n_noised = 0`, `total = 0` and both
clean targets are 0. Verified on CPU:
`build_encoder_dataset.py --sources <clean-only> --smoke` → `kept 0 rows`.
Any round-2 row that does not get an STT twin does not exist as far as the
trainer is concerned; it only exists insofar as it raises the clean *supply* that
the anchor lets the mixer draw.

**Consequence 2 — round-2 rows raise the anchor through their twins.** Each
round-2 clean row that survives `stt_noise.py` adds one `stt_noised` row, which
raises `total` by 1/0.6 ≈ 1.67 rows, of which 0.25/0.40 ≈ 0.67 are new
clean-bucket capacity. Net effect: the campaign grows the corpus by roughly
**1.4–1.7 rows per authored row** once the twins exist, and by 0 without them.

**Consequence 3 — priority-keep is not automatic for these sources.**
`select_mixture` priority-keeps rows whose source starts with one of
`encoder_rules.EDGE_SOURCE_PREFIXES` (`edge_cases:`, `teacher:abstain_low_confidence:`,
`teacher:gibberish_to_none:`, `teacher:corrections_overrides:`). Round-2 rows use
`teacher:round2_emergency_coverage:*` / `teacher:round2_confusion_pair:*`, which
match none of them — verified: an E1 dry run over the round-2 rows reports
`edge_families: {}` and `edge_priority_*: 0`. Two honest options:

- **Option A (recommended, 2-line patch, inert until round-2 sources appear):**
  add the two prefixes to `EDGE_SOURCE_PREFIXES` in `src/encoder_rules.py`, so a
  later bucket surplus can never sample the campaign's rows away.
- **Option B (no code change):** run E1 and read
  `buckets.*.supply_capped` in its report. If a bucket is supply-capped,
  everything is kept and priority is moot. If it is *not* supply-capped, the
  round-2 rows compete with the round-1 pool on a shuffle, and some will be
  dropped — visible as `edge_priority_* = 0` plus a `kept` count below supply.

E1 is CPU-only and takes seconds, so Option B's check is nearly free; take Option
A before the v6 fire if either clean bucket comes back *not* supply-capped.

### 4.2 The numbers to read in the E1 report

`<run>/build_report.json`: `kept.total` / `kept.train` / `kept.valid`,
`buckets.*.{rows,share,supply_capped}`, `per_action` vs `per_action_target`,
`edge_families`, `stt_noised_by_parent_register`, `span_bearing_rows`,
`counters.{dup_clean,relabel_or_drop,span_omitted_under_noise,leak}`,
`floors.{violations,waived,unwaived,usable_for_training}`, and
`leak_waiver.note` (which carries the **measured** parent-leak baseline:
"teacher 67 exact hits / 25 keys, noised 32 / 2 plus **118 rows whose
clean_utterance parent is a golden utterance (22 keys)**, edge_cases 6 / 5").

### 4.3 Verified on CPU (what the artifacts actually do)

| Step | Command | Result |
|---|---|---|
| Generate | `python3 src/gen_round2_requests.py` | 622 requests, 1,866 rows, **0 short classes**, 70 held-out seed drops |
| QA (degenerate teacher) | `qa_round2_rows.py` on a stub that repeats each seed | 1,866 in → 617 clean, 1,249 rejected (1,237 duplicates, 12 cue), **exit 4** (quota hold) |
| QA (varying teacher) | same, stub varies per variant | 1,866 in → **1,866 clean, 0 rejected, exit 0** |
| QA (adversarial) | 40 golden + 20 near-miss + 30 unattributed rows | `held_out_leak: 60`, `unattributed_id: 30`, **exit 3** |
| QA (near-miss only) | all 50 near-miss rows | `held_out_leak: 50/50`, **exit 4** (nothing clean survived) |
| QA (noised audit) | 600 good + 3 poisoned noised rows | usable 600; 1 unattributed, 1 parent-action mismatch, 1 held-out leak — each detected distinctly |
| E1 build | `build_encoder_dataset.py --sources <clean> --smoke` | `kept 0` — the anchor rule, Consequence 1 |
| E1 build (clean + twins) | `--sources <noised> <clean> --waive-floor …` | `kept 375` (stt_noised 225 = 60.0%, clean 94 + 56), no schema/span refusals, `edge_families: {}` |

The stub is a *test harness*, not a teacher: it exists to prove attribution,
schema, leak, duplicate, cue and quota logic, and the exit codes. It was never
written into the repo (it lives in `/tmp`), and its rows are not part of the
campaign.

### 4.4 The teacher I/O contract (what the runner must emit)

The request list fixes the input; this fixes the output, and it is the same shape
`gen_teacher.py` already writes, plus the id convention:

- one row per paraphrase, `intent/v2` fields:
  `utterance`, `action`, `entryId`, `contact`, `time`, `medication`, `message`,
  `callType`, `requestedApp`, `topic`, `steps`, `confidence`, `reply`;
- `id` = `"<request_id>-v<k>"` (k = 1…variants), e.g. `r2-ec01-dev-0001-v1`.
  The STT stage appends `:noise<n>`; the class stays recoverable either way, and
  the QA gate refuses ids it cannot attribute to a request;
- `register` = the request's register; `action` = the request's intent (a
  mismatch is rejected, not silently accepted);
- `source` = `teacher:round2_<family>:<class>:<register>`;
- slot fields carry entities **verbatim** from the utterance (no resolved values
  — `build_encoder_dataset` refuses those);
- `confidence` in [0, 1] — for these rows it is **not** a soft label; see §5.

### 4.5 Running the teacher, and the one knob that matters

The teacher is the local Qwen 4B (`intentQwen4BSlotCanon`, the incumbent
on-device model — v16 ships as the two-part GGUF in `ModelCatalog.swift`). Two
options, both CPU-viable, neither sanctioned by a file in this repo today (§5.5):

- **Prompt-paraphrase only** — the runner answers each request with `variants`
  labelled paraphrases. This is what the QA gate expects and all the chain needs.
- **Prompt-paraphrase + measured distribution** — additionally read the teacher's
  label distribution per paraphrase (llama.cpp `n_probs`) and write
  `teacher_probs` (12 floats, canonical logit order). Only the KD leg uses it.

Throughput note: 622 requests × 3 paraphrases on a 4B Q4 model is a CPU-scale
job (hours, not minutes). The noise stage is the other long pole: 1,866 rows ×
`stt_noise.variants_per_utterance` (read the value — `config.yaml` currently says
2; the round-1 LLM path used 6) TTS→STT round trips on the GPU backend. Smoke
both with `--limit 20` before committing the box.

---

## 5. Recipe (c): the distillation leg — design, prerequisites, and an honest status

**The contract already fixes the objective.** `encoder_contract.yaml`
`loss.distillation`: `enabled: conditional`, `temperature: 2.0`,
`lambda_kd: 0.5`, `objective: kd_tau2_kl`,
`L_kd = tau² · KL(softmax(teacher/tau) ‖ softmax(student/tau))`,
`slot_distillation: none` (no slot distillation), and a
`teacher_preference_order` whose first entry —
`incumbent_local_llm` — is marked `availability: tooling_not_in_repo`, while
`gemini_teacher_rows` is `available` with an explicitly **stated** construction
(`p[gold] = confidence`, rest uniform).

**What exists in code:** `encoder_contract.distill_loss()` and
`soft_targets()`; `train_encoder.distillation_spec()`
(lines 274–304), which today derives everything from the row `confidence`; and
the KD branch at `train_encoder.py:788–798`:

```python
if spec["enabled"]:
    # Contract target construction: p[gold] = row confidence, rest uniform.
    teacher_probs = [soft_targets(c if c is not None else 1.0, int(y),
                                  len(intents))
                     for c, y in zip(batch.get("confidence", []),
                                     gold.tolist())] or None
    if teacher_probs:
        loss = loss + kd_lambda * distill_loss(intent_logits, teacher_probs, kd_tau)
```

**There is no code path that consumes a measured per-class teacher
distribution.** Setting `encoder.distillation.enabled: true` today therefore
trains against the stated construction — a *fabricated* soft target derived from
a scalar confidence — not against the local teacher. That is not a defect to
work around; it is the reason the contract says `conditional`. Enabling the leg
without the plumbing below would produce a run that reports "distillation ACTIVE"
while nothing was distilled, which is worse than skipping it.

### 5.1 The teacher, pinned

| | |
|---|---|
| Identity | `intentQwen4BSlotCanon` — `intent-ne-qwen4b-slotcanon-q4_k_m.gguf`, sha256 `1662e217…a45f`, 2,497,278,784 B (v16 ships it as two ordered parts) |
| Why it | It is the incumbent on-device model: the strongest Nepali intent model the project owns, and the one whose label vocabulary already matches the 12 canonical intents |
| Scope | **Training-time only.** FR-007 forbids teacher-at-runtime; the teacher runs on the training box and never ships |
| Sampling | Label probabilities from llama.cpp `n_probs` at the first generated position, over the 12 label strings in canonical logit order, renormalized. **Stated approximation:** a multi-token label uses its first token's mass — record it in the run manifest rather than implying an exact sequence likelihood |
| Temperature | The KD temperature is the contract's `tau = 2.0`; if the sampling temperature differs (`tau_sampling`), record both — they are different quantities and conflating them is the classic KD bug |

### 5.2 The tooling that must land first (none of it exists in this repo)

1. **`tools/train-intent/src/gen_distill.py`** — the local teacher runner.
   Input: `data/round2/round2_requests.jsonl` (or a teacher-prompt file in the
   same shape) + the GGUF path. Output: the §4.4 schema + `teacher_probs[12]`,
   `teacher_id`, `teacher_sha256`, `tau_sampling`, resumable by id, one row per
   paraphrase. Effort: a day.
2. **Rules amendment** — `annotation_rules.yaml` `teacher:` block currently says
   `local_teacher: forbidden`, `script: …/gen_teacher.py`,
   `model: config.gemini.model`. It must gain the local teacher explicitly
   (`local_teacher: allowed_training_time_only` plus the script/model/rationale),
   or the leg is unsanctioned *by the rules file* even though the T-036 task spec
   sanctions it ("`gen_teacher.py` (Gemini) and/or the incumbent fine-tuned model
   as the distillation teacher, per T-035",
   `…/TG-08-nepali-intent-encoder/T-036-training-distillation-pipeline.md:75`).
   This is a contract amendment, not a code change, and it is **the operator's
   decision**, not this plan's.
3. **Contract status flip** — `teacher_preference_order[incumbent_local_llm].availability`
   from `tooling_not_in_repo` to `available`, so
   `EncoderContract.available_teacher()` picks it (it returns the *first*
   available entry; today that is `gemini_teacher_rows`).
4. **Three plumbing touchpoints** for `teacher_probs` to reach the loss:
   - `build_encoder_dataset.convert_row()` (returns a fixed 8-field dict) — pass
     through a validated `teacher_probs` (12 non-negative floats summing to 1) or
     refuse the row;
   - `train_encoder.py` — carry it through `load()` (~line 88–94),
     `build_features()` (~line 155) and `collate()` (~line 180);
   - the KD branch above — prefer `batch["teacher_probs"]`, fall back to
     `soft_targets(...)`, and record `distillation.target_source: measured|stated`
     in the run manifest.
5. **Config change to enable the leg** (after 1–4):
   ```yaml
   encoder:
     distillation:
       enabled: true          # was false; the contract says conditional
       teacher: intent-ne-qwen4b-slotcanon-q4_k_m
       temperature: null      # null -> contract 2.0 (do NOT restate it here)
       lambda_kd: null        # null -> contract 0.5
   ```
   `temperature`/`lambda_kd` stay `null` on purpose: the file's own comment says
   `null` means "use the contract value", and the run manifest records any
   override.

### 5.3 Do not confound it with the authored supply

The KD leg changes the *objective*; recipes (a)+(b) change the *data*. Fire them
separately — **v6 = recipes only**, **v6-KD = recipes + KD** — so the KD effect is
attributable. The contract's own gate set (closed-intent 0.95, slot F1 0.90,
emergency recall corpus 1.00 / adversarial 0.98, side-effect precision 0.97,
abstention precision 0.90, max gap vs Gemini 0.03) is unchanged either way.

### 5.4 What it costs, and what it could go wrong

Training-time cost only (the KD branch adds a KL per step; the teacher runs
offline). Risks: (i) a measured distribution can be *sharper* than the labels —
if the teacher disagrees with the corpus on a row, KD will push the student
toward the teacher and away from the gold label; cap `lambda_kd` at the
contract's 0.5 and read per-class agreement before trusting it; (ii) the 4B
teacher's errors are the same errors v5 has, so distilling it can *freeze* the
incumbent's confusion pairs — which is precisely why the confusion-pair supply in
§3 must land first.

### 5.5 Status of the sanction, stated plainly

The T-036 task spec sanctions a local teacher; the contract prefers one; the
annotation rules still forbid one; and the tooling does not exist. This plan
therefore schedules the leg as a **separate, gated follow-up** and fires v6
without it. Nothing in the v6 chain depends on §5.

---

## 6. Recipe (d): the v6 launch command template

Same shape as v5 (run-name convention, absolute sources, no floor waivers,
`waive_leak` as belt-and-braces, version `0.1.0-internal`, explicit publish dir).
Run on the box from `tools/train-intent/`.

### 6.0 Pre-flight (all of it, in order)

```bash
cd tools/train-intent
V5=$(ls -d artifacts/*v5-8kcal-20260914-220729* | head -1)     # §1.4
python -c "import json,sys; r=json.load(open('$V5/build_report.json'));
print(r['sources']); print(r['kept'], r['floors']['unwaived'])"

# 1. regenerate the request list for THIS operator session (deterministic)
python src/gen_round2_requests.py --confusion data/round2/v5_confusion.json   # if §1.4 ran
# 2. teacher runs (§4.4 schema) -> data/round2/round2_teacher.jsonl
# 3. QA gate — MUST exit 0 before anything is fired
python src/qa_round2_rows.py \
  --rows data/round2/round2_teacher.jsonl \
  --requests data/round2/round2_requests.jsonl \
  --out data/round2/round2_clean.jsonl \
  --rejects data/round2/round2_rejects.jsonl \
  --report data/round2/round2_qa_report.json
echo "qa exit=$?  (0 = fire; 4 = quota hold, do NOT fire; 3 = refused input)"
# 4. noise stage: GPU, must not overlap another GPU stage; smoke first
python src/stt_noise.py --backend hf --limit 20 \
  --in data/round2/round2_clean.jsonl --out data/round2/round2_noised.jsonl
python src/stt_noise.py --backend hf \
  --in data/round2/round2_clean.jsonl --out data/round2/round2_noised.jsonl
# 5. E1 dry run (CPU, seconds) — read §4.2 BEFORE firing the GPU chain
python src/build_encoder_dataset.py \
  --sources "$V5/data/noised.jsonl" "$V5/data/teacher.jsonl" \
            data/round2/round2_noised.jsonl data/round2/round2_clean.jsonl \
  --out-dir /tmp/r2-preflight --report /tmp/r2-preflight/build_report.json \
  --waive-floor corpus_floor,per_action_floor --waive-reason "pre-flight only"
```

The pre-flight build is the go/no-go: `kept.total` must exceed v5's, the three
bucket shares must sit at 0.60/0.25/0.15, `per_action` must clear the floors
(§4.1), and `edge_families` must show either `round2_emergency_coverage` +
`round2_confusion_pair` (Option A applied) or the buckets must be
`supply_capped: true` (Option B, §4.1).

### 6.1 The launch (fill in the two `<…>`s)

```bash
cd tools/train-intent
export T036_PY=.venv/bin/python                     # the venv with torch
export T036_WORK_DIR="artifacts/t036-full-0.1.0-internal-v6-round2-8kcal-$(date +%Y%m%d-%H%M%S)"
export T036_PUBLISH_DIR="<v5's publish dir, version-suffixed v6>"

# floors: NONE. The v6 corpus clears corpus_floor / stt_noised_floor /
# per_action_floor on its own supply; a waiver here would be a silent admission
# that it does not. Leave T036_WAIVE_FLOOR unset.
export T036_WAIVE_LEAK=1                            # belt-and-braces (see below)
export T036_WAIVE_REASON="round-2: 1866 authored rows (EC-1..8, CP-1..5b) QA'd against the held-out golden corpus AND eval/emergency_nearmiss.jsonl by qa_round2_rows.py (report data/round2/round2_qa_report.json); exact-match leak counter waived as belt-and-braces. The counter sees exact normalized matches only and cannot see parent-derived noised rows; the E2 row-level guard is not waived, and the campaign's own rows were de-duplicated against both held-out sets by construction."

./queue_encoder.sh \
  "<v5's source list from build_report.json, verbatim>" \
  data/round2/round2_clean.jsonl \
  data/round2/round2_noised.jsonl
```

**Why `waive_leak` is the only waiver.** The counter is exact-match-only and
cannot see noised rows whose `clean_utterance` parent is a golden utterance — it
already reports 118 such rows in the round-1 corpora. Round-2's own rows were
de-duplicated against both held-out sets *and* QA-gated again, but their noised
twins inherit the same blind spot: `T036_WAIVE_LEAK=1` is what keeps a *known*
counting limitation from holding an otherwise clean run, and the manifest records
the reason verbatim. It does **not** excuse a real leak: if
`data/round2/round2_qa_report.json` shows `held_out_leak > 0`, fix the teacher
output and re-run the QA — never fire on a non-zero leak count.

**Fallbacks.** If `stt_noise.py --in/--out` is not on the box (the patch in §9 is
additive; defaults are unchanged), append the QA'd rows to `data/teacher.jsonl`
after backing it up — the stage's default input — and drop the round-2 clean file
from `--sources`:

```bash
cp -a data/teacher.jsonl data/teacher.jsonl.bak-$(date +%Y%m%d%H%M%S)
wc -l < data/round2/round2_clean.jsonl >> /dev/null && \
  cat data/round2/round2_clean.jsonl >> data/teacher.jsonl
```

### 6.2 Order of operations, one line each

1. Read v5 (§1.4) → confusion file → `--confusion` alignment → adjust `ASK` if the
   measured pairs disagree with the v4 findings → regenerate the request list.
2. Run the teacher → `round2_teacher.jsonl` (§4.4 schema).
3. QA gate → `round2_clean.jsonl`, **exit 0 required** (§4.3).
4. STT noise → `round2_noised.jsonl` (GPU; smoke first; never overlap).
5. E1 pre-flight dry run → read §4.2 → decide Option A/B (§4.1).
6. `queue_encoder.sh` (§6.1) → E1→E2→E3→E4→E5.
7. Verify the run: gates from the eval block, the build report counters, the
   publish gate's exit code (5 = withheld).

---

## 7. Gates, evidence, rollback

**The gates do not move.** Round 2 changes supply, not thresholds:
closed-intent 0.95, slot F1 0.90, emergency recall 1.00 on the corpus, 0.98 on
the near-miss set, side-effect precision 0.97, abstention precision 0.90, max gap
vs Gemini 0.03. A round-2 change that requires a gate to move is a finding, not a
tuning step.

**Evidence the campaign must leave behind** (all of it in the run directory, all
of it reproducible from the request list):

- `data/round2/round2_requests_report.json` — the quota table, the held-out seed
  drops, the register split;
- `data/round2/round2_qa_report.json` + `…_rejects.jsonl` — per-class fill, leak
  count, duplicate count, cue violations, and the sha256 of the rows file that
  was fed in;
- `data/round2/round2_noised.jsonl` — the twins actually produced (row count and
  id coverage are the anchor arithmetic's input);
- `<run>/build_report.json` — the §4.2 counters;
- `<run>/logs/pipeline_*.log` + `eval_manifest.jsonl` — the gates;
- the run manifest's `distillation` block — which must read
  `{"enabled": false, "reason": "…"}`. **A v6 run that reports distillation ACTIVE
  is a red flag** (§5): it means the stated construction was trained against.

**Rollback** is a re-fire, not an edit: `T036_WORK_DIR` is per-run,
`--fresh` exists, and `train_encoder.py` refuses a resumed run whose config or
dataset hash drifted (`resume_mismatch()`), so a bad campaign cannot silently
continue. Publishing is gated (`--publish-dir` + the E5 gate): a v6 artifact that
fails a gate exits 5 and stays unpublished, and the previous published artifact
is untouched.

---

## 8. Risks, prerequisites, open questions

| ID | Risk / prerequisite | Mitigation / decision needed |
|---|---|---|
| **P-1** | **No local teacher runner is in this repo** (`gen_distill.py`); it may exist on the box as out-of-repo tooling — check first. The campaign cannot fire without one. | If absent: write it to the §4.4 contract (a day's work). If present: check its output against the same contract — `qa_round2_rows.py` fails loudly on any drift (id convention, register, intent, slot types) instead of letting malformed rows into the pipeline |
| **P-2** | `annotation_rules.yaml` still says `local_teacher: forbidden`; the contract's preferred teacher is `tooling_not_in_repo` | Amendment + contract status flip (§5.2 items 2–3) — the operator's call, not the plan's. **Blocks §5 only**, not v6 |
| **P-3** | 1,866 rows may not clear `per_action_floor` for the thin actions (`query` 42, `none` 54 in the campaign) | Read the E1 pre-flight (§6.0 step 5) before firing; grow CP-2b/CP-4b if the floor is still short. The floors are **not** to be waived to make round 2 fit |
| **R-1** | Teacher paraphrases collapse (the degenerate-teacher run produced 66% duplicates) | The QA duplicate counter is the early warning; raise `--variants` or add frames, never loosen dedupe |
| **R-2** | Round-2 rows sampled away by the mixer (§4.1 Consequence 3) | Option A patch or Option B verification, before the fire |
| **R-3** | Emergency rows converge on held-out phrasings (70/692 candidate seeds already dropped) | Expected and desirable at the margins; if the drop rate exceeds ~25%, the class's frames are too close to the corpus and must be re-authored, not the guard relaxed |
| **R-4** | The stub-teacher dry run is not a real teacher's output distribution | The QA gate's counters (duplicate, cue, convert_row_refused) will move on real output; budget one QA iteration |
| **R-5** | A v5 confusion profile that contradicts the v4 findings | `--confusion` alignment (§1.4); the `ASK` table is the single edit point |
| **OQ-1** | Do the round-2 rows get priority-keep (Option A) or not? | E1 pre-flight answers it empirically (§4.1) |
| **OQ-2** | Should the KD leg be a v6-KD sibling run or a later round? | §5.3 recommends a separate run so the objective change is attributable |
| **OQ-3** | What is the v5 emergency recall *by family* (which EC class actually earns its rows)? | The confusion file gives the aggregate; a per-kind breakdown needs the near-miss `kind` field and the corpus's own family tags — a follow-up to the confusion dump, not a blocker |

---

## 9. Files this campaign adds or changes

| Path | Change | State |
|---|---|---|
| `tools/train-intent/src/gen_round2_requests.py` | **new** — the teacher request-list generator (recipes a+b, quotas, held-out de-dup, `--confusion` alignment) | written, run, committed in this worktree |
| `tools/train-intent/src/qa_round2_rows.py` | **new** — post-generation QA gate; reuses the taxonomy/schema/span gates by import (`build_encoder_dataset.convert_row`, `build_dataset.normalize`/`load_golden_keys`/`lossless_key`, `encoder_rules.load_rules`, `pipeline_guards.*`) | written, run, committed in this worktree |
| `tools/train-intent/src/stt_noise.py` | **additive** — `--in`/`--out` overrides (defaults unchanged: `data/teacher.jsonl` → `data/noised.jsonl`) so round-2 rows carry their own file-level accounting | written, committed in this worktree |
| `tools/train-intent/src/encoder_rules.py` | **not changed here** — Option A (§4.1) is a 2-line addition to `EDGE_SOURCE_PREFIXES` for `teacher:round2_emergency_coverage:` and `teacher:round2_confusion_pair:` | proposed, operator's call |
| `annotation_rules.yaml` `teacher:` block | **not changed here** — the local-teacher amendment (§5.2 item 2) | prerequisite P-2 |
| `eval/golden_corpus.jsonl`, `eval/emergency_nearmiss.jsonl` | **read only, never written** | unchanged |
| `data/round2/*` | run outputs (generated on the box; regenerated in seconds) | not committed |

**Existing gates reused by import, never copied:** `taxonomy/VALID_ACTIONS` and
the JSON/schema checks, `encoder_align.validate_spans`,
`build_encoder_dataset.convert_row` (refusal markers, edge bands,
resolved-value smells, span derivation), `pipeline_guards.{golden_keys,
assert_not_golden_input, sha256_file, write_json, utc_now, exit codes}`,
`build_dataset.{normalize, lossless_key, load_golden_keys}`.
