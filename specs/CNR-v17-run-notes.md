# CNR v17 chat-aware QLoRA run — run notes (Phase A: corpus + launch · Phase B fold-in 2026-10-16/17)

Unit T-183 (TG-37, v17 chat-aware QLoRA run). Feature: conversational-nepali-replies (CNR).
Run workspace: **training box `anjan-ubuntu` (192.168.1.117)**, `/mnt/nvme1/cnr-v17/`.
Worktree on the box: `/mnt/nvme1/cnr-v17/repo` (`feat/conversational-nepali-replies` @
`5169c040`), separate from the run outputs under `/mnt/nvme1/cnr-v17/{logs,corpus,prep,train}`.
Phase A = source prep + corpus build + detached training launch. Phase B (GGUF export +
`--full-gates` harness + final notes) is a later step; this file is written as the run
progresses and finalized in Phase B.

> **Status (A5 close-out): Phase A complete as designed — corpus build #1 runs detached on
> the box (teacher-bound, ~14 h), and training launches automatically via `chain-train.sh`
> once the L2 spot-check gate clears and build #2 converts.** In-session observation stops
> at wave 3 (149/126/49 keys recorded; 0 pending at 03:27:46); wave 4 + the final sweep +
> the build-#2 transition are deferred to Phase B because the box's sshd wedged at ~03:25
> (§9, §11.16). Sections carrying `(pending)` are filled in Phase B.

> **Phase B fold-in (2026-10-16/17).** Phase A ended at the box's ~14 h sshd wedge; the
> sanctioned power-cycle recovery, the build-#2 fallback, the corpus repair, the GPU wedge
> + card reseat, the training restarts and completion, the GGUF export, the owner's
> ACCEPT-ALL review, the candidate-reply generation and the full ship gate are recorded in
> §12–§15 and deviations §11.18–30 (the §6.4 / §7 / §8.3 `(pending)` blocks are filled
> in place). The box checkout stayed at `5169c040`; Phase-B tool edits were synced to the
> box as byte-identical files (`eval_golden.py` `ee0aca33…` — parse repair + `--preds-out`;
> the builder's concurrency patch `c7736b99…`) and committed on the branch
> (`caecbd1a`, `34d6be2b`, `ffcb9b7c`, `9cafa3cc`).

## 1. Base identity and the extended-tokenizer finding

| Item | Value |
|---|---|
| Base checkpoint | `tools/train-intent/checkpoints/qwen-s43-merged` (symlinked read-only into the run worktree) |
| `model.safetensors` sha256 | `06e326f4381858355e5b00cc01ec6f4b459d6e63fc47ab3243e4dcf20d776f95` |
| `config.json` sha256 | `511f4cbbdeb281f753a292b4d7855cbf8975320f6006d1d0cc22cef0d08da866` |
| `tokenizer.json` sha256 | `edfc0debec846c25f2dd452061f7725bf5b66336912a33ba1ec10ebd6c4b49cf` |
| Q4_K_M export of this base | `models/intent-ne-qwen-s43-q4_k_m.gguf`, sha256 `c2135f786ace9c1020a27bb115600d90f9e3c4d788c995730b379b67e1ae74ef` (1,107,408,576 B) — **verified byte-identical to the app's pinned artifact** (`ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift:1566`) |

**Recorded finding — "extended-tokenizer 1.7B base" does not exist in this lineage.**
The design/task text names an "extended-tokenizer 1.7B device default" as the v17 base.
On the box the extended-tokenizer base is the **4B** (`checkpoints/qwen4b-*`, the P2 leg),
not the 1.7B. The 1.7B device-default lineage is `qwen-s43` → `qwen-s43-merged` → the
pinned Q4_K_M above, and that is the base this run trains from. The "extended-tokenizer"
attribute is not part of the 1.7B lineage; the run uses the pinned 1.7B base and records
the naming discrepancy here rather than inventing an artifact.

## 2. Box + GPU + disk

* host `anjan-ubuntu`, kernel `6.17.0-29-generic` (the dispatch said 7.0.0-38 — the box
  reports 6.17.0-29; recorded as-observed).
* GPU: RTX 3090 24 GB, **idle at launch** (`nvidia-smi`: 0 MiB used, 0 % util before the run).
* Disk: `/mnt/nvme2` 1.8 T total, **21 G free (99 %)** — nothing new is written there;
  `/mnt/nvme1` 886 G free — the whole run lives under `/mnt/nvme1/cnr-v17/`.
* Discipline: long jobs are launched detached (`nohup setsid bash <chain>.sh`), waits use
  the house `job_running` pattern (never a bare `pgrep -f`), no `reload-gpu.sh`, no reboots.
* Only GPU stage in Phase A is the training run itself (teacher work is API-bound; the
  pre-flight, §8.2, ended before the build started — GPU stages never overlap).

## 3. Tooling staged into the run (and the trainer adaptation)

### 3.1 Staged under `/mnt/nvme1/cnr-v17/repo/tools/train-intent/`

| Path | sha256 | Origin |
|---|---|---|
| `v17-trainer/train_chat_lora.py` | `98c7bda384178b59d14510456ceff6739afdb3f2426336cabab85a950f2ed5ac` | box stage-3 `src/train_chat_lora.py` @ `ccc05e2d…` + the 6 edits below |
| `v17-trainer/train_qlora.py` | `a5c388dd7d0927711fb6767349a54eeb2c5c42cf176c3c126bff2a7b7e70ff01` | box stage-3 `src/train_qlora.py`, **verbatim** |
| `v17-trainer/chat_prompt.py` | `965c1acfdd9257e48896a48414e0b4dd587d648c496cadb82ece3c506d35badb` | box stage-3 `src/chat_prompt.py` @ `8a33cfff…` + the placeholder edit below |
| `seeds/chat_prompt_template.txt` | `abacefc60f559e8b0a901b6f7d6cc0a37d1805970a8654feedb432a1834a8721` | the CNR branch's chat seed (committed in `5367b539`, Wave 2) |
| `seeds/prompt_template.txt` | `425241446eefe8caddc1b9a557a03755b52fd2043127f738ad15ecfe9c2d38dd` | the command-family template (`to_text` byte-identity) |
| `seeds/nepali-chat-style-spec` | `64ada91d2562bb71f446ea95d4e24d66e294184b4395ad2f99494ab5d0a46788` | the recorded chat style spec (read by the builder's post-edit/GEC prompts) |
| `src/build_chat_corpus.py` | `3a8464d0198ec8fb8df004ababd1fce53a3cc57afdf68dd4cbaa68715a060b8d` | the T-179 corpus builder, **unmodified** |
| `config.yaml` | `1f176ce07a5bf42dafdb169d80e2e0e519720a1c7d39a3cb334a0b9d971e6bbd` | recipe + teacher config, **unmodified** |
| `eval/author_chat_golden.py` | `2fdc646c3c6e2ee8d1253a86d55b003f0327efed94e97c6544ee86a5daffadf6` | the OpenRouter teacher transport (`call_teacher_openrouter`) |
| `/mnt/nvme1/cnr-v17/patch-trainer.py` | `c21f67c34d24a14a72c3e0ee490d1cb55f9c31bfb8d58692d7698b91103ae8ad` | the adaptation script (assertion-guarded edits) |
| `checkpoints/qwen-s43-merged` | symlink → box checkout | read-only base (§1) |

**Deviation, recorded:** the dispatch said to copy `train_chat_lora.py` + `chat_prompt.py`
into the worktree "run-locally"; they live under `v17-trainer/` rather than `src/` so the
worktree's `src/` stays byte-identical to the branch (the builder, config, seeds and the
four-placeholder `intent_prompt.py` are all read from `src/` as committed). The trainer's
`ROOT` is `v17-trainer/../` → `tools/train-intent/`, and it appends `ROOT/src` to
`sys.path` for `config.py`/`intent_prompt.py`.

### 3.2 The adaptation diff (A1.5), exact hunks

`train_chat_lora.py` — 6 edits:

1. `+ import sys` and the import block moved below `ROOT` with `sys.path.append(str(ROOT / "src"))`
   (`from chat_prompt import …` resolves to the staged copy; `config`/`intent_prompt`/`train_qlora`
   to the repo `src/` — `intent_prompt.py` in the box's stage-3 tree still carries three
   placeholders and would leave `{address_as_clause}` literal).
2. `--base` default `"qwen4b"` → `"qwen"` (the 1.7B tokenizer/terminator family).
3. chat template path `seeds/prompt_template_chat.txt` → `seeds/chat_prompt_template.txt`.
4. `LoraConfig(r=64, lora_alpha=128, …)` → `r=lora_r, lora_alpha=lora_alpha` read from
   `cfg["training.lora_r"]`/`["training.lora_alpha"]` (fallbacks keep the stage-3 numbers).
5. `lr = 1e-4` → `lr = float(cfg.get("training.lr", 1e-4))`.
6. the recipe print now echoes `r={lora_r} alpha={lora_alpha}` so the log states the
   recipe actually built.

`chat_prompt.py` — the placeholder edit:

```
+DEFAULT_ADDRESS_AS_CLAUSE = ""  # un-personalized turn (fresh install)
-CHAT_PLACEHOLDERS = ("{language_hint}", "{transcript}")
+CHAT_PLACEHOLDERS = ("{language_hint}", "{address_as_clause}", "{transcript}")
 def render_chat_prompt(template, transcript, language_hint=DEFAULT_LANGUAGE_HINT,
+                       address_as_clause=DEFAULT_ADDRESS_AS_CLAUSE):
              .replace("{language_hint}", language_hint)
+            .replace("{address_as_clause}", address_as_clause)
              .replace("{transcript}", transcript)
```

`to_text` is **untouched**: command rows stay `render_prompt(cmd, u, language_hint="ne") +
"\n" + json.dumps(label) + <|im_end|>`; chat rows stay `render_chat_prompt(template, u) +
json.dumps(label) + <|im_end|>` (no separator newline) — the two-family byte-identity the
stage-3 trainer asserts.

### 3.3 `{address_as_clause}` = `""` — the fresh-install default, with evidence

The seed's third interpolation mirrors the app's current `IntentPrompt.buildChat`.
`addressAsClause(_ term: String?)` returns `""` when the term is nil/empty
(`ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift:142-145`), so a fresh install —
no address-as preference recorded — sends **no clause**. The trainer renders with
`address_as_clause=""`, i.e. byte-identical to the pre-feature text. Recorded; if an
personalized install later needs the clause variant, that is a *different* training text,
not this run's.

## 4. Ship-mix sources (A2)

Prepared as real files under the run worktree's `chat-sources/` and `data/`; every file
hashed. Licences are the ones the builder's registry records (`LICENSE_REGISTRY_ID =
chat_corpus_license_registry/v1`).

| Source | Layer | Licence (registry) | File | Rows | Candidates | sha256 |
|---|---|---|---|---|---|---|
| `devanagari_ecommerce` | L1 | Apache-2.0 | `chat-sources/l1/devanagari_ecommerce.jsonl` | 4,929 | 4,929 | `1a71922a640417fcca1c51e59524abefae5bcbec7475bbe577d6c4729fe82c76` |
| `taskmaster` (TM-1/2/3) | L2 | CC-BY 4.0 | `chat-sources/l2/taskmaster.jsonl` | 279 | 3,005 | `6af5ed04dc61e554c6954b0900e0a9cf639129ae49e0f6200475ef6a8569ae39` |
| `soda` | L2 | CC-BY 4.0 | `chat-sources/l2/soda.jsonl` | 733 | 2,501 | `9ce20822b799e119497aec44cc926bc9c585f5607c11109f8c0216f67591c838` |
| `prosocial_dialog` | L2 | CC-BY 4.0 | `chat-sources/l2/prosocial_dialog.jsonl` | 1,000 | 1,000 | `91820f12cbe722a215dc8ba6f861ff204d45fd7366793c85a110c35f73b91ecf` |
| `oasst1` | L2 | Apache-2.0 | `chat-sources/l2/oasst1.jsonl` | 1,200 | 1,200 | `fd0029dbbb5fab71ddf9df910ddfa390d0847212603d41b26f0ba1f569b3c726` |
| `intent_training_teacher` | L4 | own data | `data/teacher.jsonl` (reply added, below) | 20,294 | 20,294 | `2547395478b7519d0a16fc2daf27f64d8b65c5ae81766e09c45d9c320b84eea0` |
| `intent_training_noised` | L4 | own data | `data/noised.jsonl` (reply added) | 29,304 | 29,304 | `4b129db83e8b941ea8328dd2a0acfa7c819285dbcfd258367de362a52f1901eb` |
| `abstain_honesty_edge_cases` | L4 | own data | `data/edge_cases.jsonl` (reply added) | 109 | 109 | `0f52f12d187cec86f4d3b667430a7d607442f70b194d4750be804b8b20117753` |

Conversions (all deterministic, re-runnable; scripts staged in
`/mnt/nvme1/cnr-v17/prep/` with per-file sha256 below):

* `prep/convert_l1_source.py` (`ea799e22…`) — 4,930 raw rows → 4,929 (a header/blank guard).
* `prep/convert_l2_sources.py` (`6b92d077…`) — TM speaker map `USER|user→elder`,
  `ASSISTANT|assistant→assistant`; SODA first-speaker→elder with strict alternation and an
  exactly-two-speaker check; prosocial pair rows (`context`→user_turn, `response`→reply);
  oasst1 pair rows (assistant message, parent prompter, `lang=en`, not deleted,
  `review_result != False`); a 300-word sanity cap. Row budgets: tm 3,000 / soda 2,500 /
  prosocial 1,000 / oasst1 1,200.
* `prep/adapt_l4.py` (`24082be0…`) — adds `reply` := `response` to each L4 row, preserving
  every original key and row order. Verbatim pre-adaptation originals are preserved at
  `/mnt/nvme1/cnr-v17/originals/data/`:
  `teacher.jsonl` `ff2fcdc031fc4c6320c06b742b599b51aac451dd826ad4721ec0ebb20ca50027`,
  `noised.jsonl` `cff510f31b8f2edfa83dba34efa6f14c86cc36cd490cf1e62620fd2f3ad13414`,
  `edge_cases.jsonl` `6d75b0460b57d80bace8d24dd371782bb6e8df37fa5b25b9ec16a10aa8bbe4a2`.
  Raw upstream downloads (710 MB) stay under `/mnt/nvme1/cnr-v17/raw/` with the probes
  (`prep/probe_raw.py`, `prep/probe2.py`) that produced the mappings above.

**Absent / refused (recorded, never downloaded for this ship run).** The manifest's licence
registry carries these ids as absent or refused, and the builder counts them without
substituting anything: `indic_dialogue_ne` (CC BY-NC 3.0, research-only), `call_center_transcripts`
(research-gated — enterprise licence required to ship), `dailydialog`, `personachat_convai2`,
`empathetic_dialogues` (all CC BY-NC 4.0 research-only), `nepali_sft_himalaya` and
`nepali_sft_saugatkafley` (licence unclassified — refused until recorded), and the two held-out
eval fixtures (`golden_corpus_fixture`, `emergency_nearmiss_fixture` — `eval-fixture`
admissibility, excluded from both mixes). The chat golden fixture (`chat_golden_fixture`) stays
held-out and ineligible: the owner's 50-batch human review is still outstanding, and this run
does **not** fake it. Confirmation of the absent-by-file state is in the manifest's
`source_files` entries for the next poll (§6.4).

## 5. The translation tier: two offline NMT pilots, then the recorded teacher substitution

L2 rows need en→ne. The offline option on the box is the shipped NMT lineage
(`tools/train/models/translate-en-ne-qwen17b-*` GGUFs, app ids `nmt-en-ne-qwen17b-*`;
`nmt-en-ne-qwen17b-r3-q4_k_m` is the LIVE catalog artifact of this lineage and
`translate-en-ne-qwen17b-r7` is the conversation-slice round). A local llama.cpp runner was
wired (`prep/translate_l2_jsonl.py`, `9f10867c…`) and piloted on 20 real L2 elder turns
(`pilot-meta.json`), one source line each:

| Tier | Pilot result | Verdict |
|---|---|---|
| `translate-en-ne-qwen17b-r3` (app's live lineage) | `pilot-translate-stats.json`: 20 rows → **19 calls, 8 retry splits, 99.6 s**; outputs like `होसियार, म कोरियाली फोडका लागि अर्को अनुभव बुक गर्ने खोज्दैछिन।`, `माई सेयर बुक गर्न चाहनुहुन्छ।` — transliterated English, invented words ("another experience" for a table booking) | **rejected** (sign-style NMT; not dialogue) |
| `translate-en-ne-qwen17b-r7` (conversation round) | outputs like `होहले, म कोरियाली फोडका लागि टेबल बुक गर्न खोज्दैछु।`, `स्वस्थ होमले, म ड्राइभिङ गर्दैछिन्…` — still greeting/word errors on casual dialogue | **rejected** (better, still sign-text quality) |
| Teacher tier (`gemini-2.5-flash-lite`) | `pilot-teacher-stats.json`: 20 rows, **1 call, 4.5 s**; `नमस्ते, म कोरियन खानाको लागि टेबल बुक गर्न चाहन्छु।`, `ईयू कसरी काम गर्छ?` | **adopted** |

**Substitution record.** The L2 translation tier is the pipeline's own recorded teacher
model (`config.yaml gemini.model = gemini-2.5-flash-lite`), implemented as
`prep/translate_teacher_jsonl.py` (`f4c892b6…`) behind the builder's
`--translation-command` seam. It is batched by a word budget (never truncated into a short
array), maps answers back positionally, halves-and-recurses on a short/unparsable/slow
answer (a single row that still fails raises, and the builder records the source as HELD —
never a fabricated translation), caches by sha256(text) so a re-run reuses paid-for
translations, and logs every call (`logs/translate/tier.log`).

**Transport substitution (recorded).** The direct Google key is out of prepaid credits
(HTTP 402 `RESOURCE_EXHAUSTED` from the live API, on the box **and** on the authoring
machine — same depleted project). The same model is reached through OpenRouter
(`google/gemini-2.5-flash-lite`) — the transport the builder records via
`--teacher-transport openrouter`; the translation tier uses the identical transport
(verified serving that model). The key lives at `/mnt/nvme1/cnr-v17/secrets/openrouter.env`
(mode 600, written over stdin, never printed). Teacher pilot through this transport:
20/20 rows, 1 call, 4.5 s, 561 in / 508 out tokens.

**First-source tier accounting (taskmaster, complete 02:24:15 +11:00).**
`in=3005 rows, 145 calls, 314 cache hits, 5 retry splits, 1 empty output, 874.0 s`
(`logs/translate/tier.log`; the cache carries 2,691 new translations for the source).
The single empty output is a recorded-and-cached empty translation for one row
(`stats.empty_outputs` in the tier): that row reaches the corpus as an empty elder turn.
It is a Phase B screen item (`review_l2.py` flags `empty_user_turn`; the flagged batch
then goes through the Phase B disposition path) — recorded here rather than discovered
later. Per-source accounting for the remaining three sources: §6.4.

## 6. The corpus build (A3)

### 6.1 Command (verbatim, run by `chain-corpus.sh`)

```
$PY src/build_chat_corpus.py \
  --mix ship --run-id "$RUN_ID" \
  --out-dir /mnt/nvme1/cnr-v17/corpus/$RUN_ID/ship \
  --seed 42 --l3-target-turns 12000 --limit-per-source 5000 \
  --gec-budget 4000 --noise-backend auto --noise-pairs data/noised.jsonl \
  --teacher-transport openrouter \
  --translation-command "$TCMD"
```

with `$PY` = the box venv
(`/mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent/.venv/bin/python`;
torch 2.14.0+cu130, transformers 5.16.1, peft 0.20.0, datasets 5.0.1, google-genai 2.22.0,
llama_cpp 0.3.35 — the latter present for Phase B's GGUF export) and `$TCMD` =
`python3 /mnt/nvme1/cnr-v17/prep/translate_teacher_jsonl.py --batch 20 --max-words 900
--rpm 25 --cache-file /mnt/nvme1/cnr-v17/logs/translate/cache.jsonl
--log-file /mnt/nvme1/cnr-v17/logs/translate/tier.log
--stats-file /mnt/nvme1/cnr-v17/logs/translate/stats-$$.json`.

Run: **`cnr-v17-20261015-0209`** (started 2026-10-15 02:09:41 +11:00).
Mixture targets as built in: `TOTAL_TURNS_TARGET = 40,000`;
`LAYER_TARGETS` L3 = 10,000, L4 = 30 % of the total (12,000); claw-back share 0.30;
L2 post-edit batches of 20 (`L2_POSTEDIT_BATCH_TURNS`); STT-noise rate 0.60 (L4 only,
`--noise-backend auto` → recorded pairs from `data/noised.jsonl` if the toolchain is
absent). **STT-noise backend at build time: `auto`; final resolution recorded in §6.4.**
`--limit-per-source 5000` binds only L4 (10,109 candidate rows); L1/L2 are under it.

Chain scripts (both recorded, both live):

| File | sha256 |
|---|---|
| `/mnt/nvme1/cnr-v17/chain-corpus.sh` | `5013ffe8371dff1a710e92d1fb4430ba086caa3ad712104ea67ca2f82fc81284` |
| `/mnt/nvme1/cnr-v17/chain-train.sh` | `70c7839a16a9616c082736273c08612d1f2665fbbad1d1b7364df0db3be3b08c` |
| `/mnt/nvme1/cnr-v17/prep/convert_rows.py` | `66c9f272a05fecae7441e75dd2c1ac178c84c6a2ce720cb9d25330b01f7e0b4d` |
| `/mnt/nvme1/cnr-v17/prep/review_l2.py` | `0e1f636a4feafc8cc1db6e7f17ff1806b5ff5375a7653ad0f53625bd389539e6` |
| `/mnt/nvme1/cnr-v17/prep/review_state_counts.py` | `a6a51f86a80f07fb02e9e5a3afb49b2594eb5f7a46baf9fbe8e63ba489a6ac44` |
| `/mnt/nvme1/cnr-v17/prep/review_keys.py` | `bc25d1591d02b6bed6951b9eb1850eb884dc4e87a41de3e536807118a93a7d5b` |
| `/mnt/nvme1/cnr-v17/prep/review-watch.sh` | `8c8548e74ad76627bb9c3722f53602ecb4029d41120b024f08bd676056cb450c` |
| `/mnt/nvme1/cnr-v17/prep/postedit_replay.py` | `31647f575287b67ce5a4f9a6b9b04c5884363e14022cb579d5d3538ccef8489b` |
| `/mnt/nvme1/cnr-v17/prep/record-waves.sh` (v3, repair passes + final sweep) | `f75b47b26ec42e2bb5a194cd1fca69334775c48b7fe849b3ae3c8aa75c4a4883` |
| `/mnt/nvme1/cnr-v17/prep/replay_report.py` | `3c6d6a25d2a7f736a44866b862ef72f3b15e731de25cd9e697f2109fec5d077e` |
| `/mnt/nvme1/cnr-v17/logs/postedit-replay.jsonl` (evidence) | `1053b6bb1c39803e2a1829305e5e4785556976fa6e91319b04fc98757cad6417` |
| `/mnt/nvme1/cnr-v17/logs/postedit-replay-print.txt` (evidence) | `c39a13dc965494189aef4330136317a692d17c724a8f817a7d0178581487db34` |
| `/mnt/nvme1/cnr-v17/prep/status.sh` | `768ee0749b8608cf2904f2c38405458b35daf48b2916ce2a50718bbcee367a65` |
| `/mnt/nvme1/cnr-v17/prep/train-watch.sh` (v2, GPU-util verdict) | `2528479f5dffe20e4037137903c95523e47d35e7cbc5d685e8ec633b37b76ed6` |

**Aborted first attempt (recorded).** Run `cnr-v17-20261015-0157` was started 01:57:51 and
stopped at 02:09 with **no output written** (its run dir was empty and was removed). Reason:
the tier was uninstrumented — no cache (the spot-check gate's second pass would have
re-paid every translation) and no live log. It was replaced by the instrumented tier above.
No teacher spend of consequence (~$0.01) and no corpus rows were lost.

### 6.2 Why the chain builds the corpus **twice**

The builder materialises post-edited L2 rows only when it writes the run's outputs (end of
run), and its admission seam — where `l2-review.json` is read — runs after L3 + GEC. So the
L2 spot-check gate **cannot** be satisfied before a first build has produced rows to review.
The chain therefore:

1. **build #1** — runs with every L2 batch `pending`; the admission seam holds those rows
   (`pending_spot_check`) and the corpus is written with the hold recorded;
2. writes `logs/REVIEW-NEEDED.txt`, then **waits (bounded, 12 h)** for the review state to
   clear — `logs/REVIEW-MATERIALS-READY` + `review-{screen,batches,sample}.jsonl|json` are
   prepared by the detached watcher `prep/review-watch.sh` as soon as `layers/L2.jsonl`
   exists; an operator can bypass the wait with `logs/REVIEW-SKIP`;
3. **build #2** (same run id → same caches: `l3-generated.jsonl`, `gec-cache.jsonl`, and
   the tier's translation cache, so only the L2 post-edit stage is re-paid, ~1.3 h) — only
   if at least one batch was recorded `spot_checked`;
4. converts rows and launches training detached.

The review records batch ids (`<source>#NNNN`, deterministic by candidate index), so a
recorded disposition stays attached to the same batch across the two builds. The post-edit
text is re-generated in build #2 at the recorded temperature 0.8 — the disposition applies
to the batch (same candidates, same prompt, same config), and that nuance is recorded here
rather than hidden.

**Filling the gate during build #1 (the clobber hazard, handled).** The builder loads
`l2-review.json` at the *start* of each source's post-edit phase and saves the in-memory
state over the file at the phase's end; a wave that records source X's keys can therefore
be *reverted* (never corrupted — `pipeline_guards.write_json` is atomic tmp+replace) by
source X+1's save when X+1 happened to load the file mid-wave. `prep/record-waves.sh` (v3)
handles this in two stages: per-wave **repair passes** (re-list `pending`, re-record, up to
10 passes × 60 s) and one authoritative **final sweep** that runs after wave `oasst1` —
i.e. after the last save of the run's L2 stage — at which point this script is the only
writer until the admission seam reads the file, so the sweep converges and logs
`logs/REVIEW-RECORDED.txt` (the log records every pass's re-recorded count and the
settle check; the observed outcome is stated in §6.3). The chain's wait loop
(`pending == 0`) then clears promptly; the 12 h bound remains as a backstop only.

**Admission timing in this run's flow (material nuance — code-read during the ssh outage).**
The admission gate reads `l2-review.json` exactly once, inside `build_chat_corpus` after
L3 + GEC (`src/build_chat_corpus.py:2383`), i.e. ≈ 14 h into the run (~16:00), whereas the
waves + final sweep complete the review state by ~04:10. In the *human* flow the gate
therefore sees `pending` (rows are reviewed only after build #1's outputs appear); in
**this run's flow it will see the recorded dispositions already**, so build #1's own
output corpus applies the gate too (L2 admitted / oasst1 dropped as recorded). The chain
does not special-case that: it re-runs build #2 whenever any batch was recorded
`spot_checked` — here a **same-gate replay** whose freshly sampled post-edit text is the
corpus the chain converts and trains on. **Phase B records corpus identity from build
#2's outputs** (the final); build #1's outputs are an intermediate with the same gate
state, not an error.

### 6.3 L2 spot-check (the recorded gate) — AGENT-performed, owner-confirmable

**The per-batch record.** The builder's review CLI (a frozen, recorded artifact — sha256 in
§6.1) exposes only `--record-spot-check <batch> --reviewer <name> --disposition
<pending|spot_checked|rejected>`; it has **no note flag** (the library's `note` parameter is
not wired to argparse). The recorded per-batch tuple is therefore
`{status: spot_checked|rejected, reviewer: "cnr-t183-agent-review", recorded_at: <UTC+11>}`,
and the **method statement** for the audit trail lives in this section, in `logs/record-waves.log` (one
"wave … method note" line per source plus a `[spot-check] …` line per batch), and in
`logs/REVIEW-RECORDED.txt`. This differs from the dispatch's suggested invocation only by
the absent `--note`; nothing else about the recorded disposition changes. *(The first wave
attempt used `--note` and was rejected by argparse — exit 2, zero writes; found and fixed
during the run, `record-waves.sh` v3, §6.1.)*

**Why a replay.** During a build the post-edited L2 replies exist only in the builder's
memory (the run's `layers/L2.jsonl` appears at output-write time, and the builder refuses
a disposition for a batch post-edit has not produced), so the batch-level review cannot
read in-flight rows. The agent review therefore runs the **stage itself** through the
builder's own seams — same candidate extraction (`_dialogue_candidates`), same post-edit
prompt builder (style spec + 3 Layer-1 exemplars), same recorded teacher config
(`gemini-2.5-flash-lite`, temperature 0.8) and transport — over a deterministic spread of
batches, with the same batch keying (`<source>#<index//20:04d>`), so a finding names the
same batch the run's review state carries. Tool: `prep/postedit_replay.py`
(`sha256` in the box's `prep/`; evidence `logs/postedit-replay.jsonl` +
`logs/postedit-replay-print.txt`). **12 batches (3 per source) × 20 rows read in full**
(240 rows) against `seeds/nepali-chat-style-spec`.

**Findings (agent read, 2026-10-15 ~02:30-02:45).**

* **`oasst1` — REJECTED (all 60 batches).** The post-edit stage collapses on this source's
  long assistant-QA replies: distinct replies per sampled batch were **20 → 1**
  (`oasst1#0000`: every pair answered with the same apology
  `म खेद व्यक्त गर्दछु, तर म तपाईंले सोधेको कुरा बुझिनँ।`), **20 → 9** (`#0030`, canned
  repeats) and **20 → 5** (`#0059`: "यो एउटा रोचक प्रश्न हो।" ×10, "यस बारेमा मलाई
  खासै जानकारी छैन।" ×7). The source's register is assistant-QA essays (monopsony,
  contrastive learning, code questions), not spoken chat — admitted unedited it would
  teach a constant "I did not understand". Rejected for this reason (stated here and in the
  wave log's `oasst1` method-note line; the frozen CLI carries no note field — above).
* **`taskmaster` / `soda` — echo/misalignment defects at a low rate, kept with the
  finding recorded.** Sampled: `taskmaster#0000` 3/20 rows defective (two rows' reply =
  the elder's own turn; one neighbour-shifted), `taskmaster#0075` 1/20
  (neighbour-echo), `soda#0125` 1/1 (single-row tail batch, reply = the elder's turn;
  that batch is flagged and rejected by the screen), `soda#0000` 1 duplicate reply.
  The rest read as natural, faithful spoken Nepali (e.g. `हुन्छ। तपाईंलाई चाँडै फोनमा
  एक पुष्टिकरण आउनेछ।` for "Great. You will get a confirmation to your phone soon.").
* **`prosocial_dialog` — clean** (3 batches, 60/60 rows distinct and on-register).
* One `oasst1` call came back **truncated** (`finish_reason='error'`, 2,211 chars —
  "the response was cut short"); a single retry succeeded. The builder itself has **no
  retry** on a failed post-edit call: that batch is HELD (`postedit_unavailable`) and its
  rows are counted out. Build #2 re-runs the batch, but its call succeeding there creates
  the key as `pending` — and a pending key is held at admission, so the rows stay a
  **counted shortfall** unless a new disposition is recorded for that key; the waves do
  not chase build #2's new keys (recorded decision, §11.15). Recorded as a known, counted
  failure mode.

**Dispositions applied** (builder CLI, `--reviewer cnr-t183-agent-review`):

| Source | Disposition | Batches (planned) | Keys recorded |
|---|---|---|---|
| `taskmaster` | `spot_checked` | 151 | **149** at 02:45:33 (2 held; below) |
| `soda` | `spot_checked` | 126 | **126** at 03:15:42 (all) |
| `prosocial_dialog` | `spot_checked` | 50 | **49** at 03:27:46 (1 held) |
| `oasst1` | `rejected` (post-edit collapse) | 60 | wave fires on its save (~03:55-04:10 per the source's tier + post-edit pace); outcome not read in-session — ssh outage (§9) |

The builder refuses a disposition for a batch post-edit has not produced, and it saves the
state once per source, so the recording is applied in **waves** by
`prep/record-waves.sh` (`logs/record-waves.log`): each source's keys are recorded only
after they appear as `pending` (i.e. after that source's own save). **Wave 1
(taskmaster): 149 of 151 keys recorded `spot_checked` at 02:45:33, 0 left pending, 0
repair passes**; the two absent ids are **`taskmaster#0112` and `taskmaster#0136`** —
those batches' post-edit calls failed in build #1 (the recorded transient-failure mode
above), so no key exists to record and their ~40 rows are held/counted. **Waves 2–3
(soda, prosocial_dialog): recorded 126/126 at 03:15:42 and 49/50 at 03:27:46 — one
prosocial batch held (id in §6.4), 0 left pending, 0 repair passes.** The oasst1 wave and
the final sweep fire automatically on the box; their outcomes are logged in
`logs/REVIEW-RECORDED.txt` — **in-session verification of wave 4 + the sweep was cut off
by the ssh outage (§9), so Phase B confirms them first** (§6.4).

**Honesty note (plainly).** These dispositions are an **agent-performed** review — not a
human one — and they are **owner-confirmable**: the reviewer name, the per-batch note, the
method here, and the full replay evidence are all on the record. The
`spot_checked` dispositions are **provisional pending the mechanical screen of the shipped
rows** (`prep/review_l2.py --prepare`: empty/reply-echo/duplicate-collapse/Latin-run/
artefact/length checks over 100 % of `layers/L2.jsonl`), which Phase B runs on the final
corpus; any batch the screen flags is rejected with the reason and the build re-run — the
fix path is explicit, nothing is silently admitted. Phase B also re-reads a spread sample
of the *shipped* rows (12 batches × 15 rows) to confirm the replay's verdict on the actual
text.

**One recorded caveat about build #2.** Because the post-edit stage has no cache, build #2
re-generates the L2 text at the recorded temperature (0.8) for the same batch keys; the
disposition is therefore a **batch-level/tier-level** verdict, and the shipped text's
final check is the screen + the Phase-B read of the actual rows (above). The same caveat
applies to any build in this two-pass flow — stated, not hidden.

### 6.4 Corpus identity (filled in Phase B, from build #2's outputs — §6.2 / §11.19)

* `ship/chat-corpus-ship.jsonl` (the shipped corpus, post-repair): sha256
  **`ec2eee2fc24c35f75cd81c6d26816dfb180282204acb8805a3b1956ed796ea4d`**, **17,735 rows**.
  Pre-repair backup `chat-corpus-ship.jsonl.prerepair-20261015-214048.bak` (sha
  `5fd4262d…`); the single dropped row and its evidence: `corpus-repair-record.json` (§11.18).
* `ship/chat-corpus-counters.json` (schema `chat_corpus/v1`) — verbatim:
  * per-layer: L1 candidates 4,929 → admitted/selected **2,083**; L2 candidates 7,706 →
    admitted 5,085 → selected **4,723**; L3 candidates 12,080 → admitted/selected
    **5,609** (target 10,000 = the design band's floor; generation call budget bound);
    L4 candidates 10,109 → admitted 7,414 → selected **5,321** (target 12,000 = 30 % of
    the 40,000 total). Admitted total 20,191.
  * mixture achieved: conversation **12,415** / claw-back **5,321** / total **17,736**
    (shares 0.69999 / 0.30001) — counted before the one-row repair; final corpus 17,735
    (conversation 12,414). Pool note: "conversation anchors the mixture (scarce side): all
    12,415 taken; claw-back capped at 5,321 of 7,414".
  * held: `gec_missing` 40, `pending_spot_check` **362**, `postedit_unavailable` 40.
  * rejections (by reason): duplicate_within_corpus 8,372 · held_out_user_turn 3,400 ·
    sentence_shape 1,301 · devanagari_purity 1,182 · length 1,025 · dangling_particle 552 ·
    held_out_reply 368 · honorific_agreement 363 · held_out_eval_fixture 362 ·
    no_ai_isms 89 · held_out_eval_fixture_source 2 · unclassified_source 2.
  * stages: L2 post-edit batches/turns — taskmaster 151/2,983 · soda 126/2,501 ·
    prosocial_dialog 50/999 · oasst1 60/1,050; L3 12,080 turns from 1,210 calls (all
    cached at the final build); teacher GEC (gemini-2.5-flash-lite @ temp 0.0, openrouter):
    335 calls / 27,953 cache hits (28,736 entries) against a 4,000-call budget; refusals
    recorded (cut-short JSON retries).
  * one `deviations` entry (recorded): the eval fixtures are refused as L4 claw-back
    sources (the suite's own guard; 2 sources refused / 362 rows excluded at admission) —
    the design's §11.1 claw-back names them; retention is carried by intent_training +
    abstain_honesty (68 rows). `shortfalls`: L3 (10,000 target → 5,609) plus the five
    absent sources in `notes` (indic_dialogue_ne, call_center_transcripts, dailydialog,
    personachat_convai2, empathetic_dialogues — absent, never substituted).
* Provenance manifest `corpus/<run>/provenance-manifest.json`: sha **`fb7f7779…`**
  (post-re-emission, §15), `content_hash` **`add5954f…`**, `ship_mix_eligible: true`;
  `corpus` = {file chat-corpus-ship.jsonl, turns 17,735, admitted 20,191, sha256
  `ec2eee2f…`}. The counters' `held_out_guard.chat_golden` block records the **build-time**
  fixture state (sha `83283663…`, `eligible_gate_fixture: false`, "human review is
  pending"); the owner's ACCEPT-ALL review later revised the fixture itself to
  `40bec05d…` (§14.1) — admission never gated on eligibility either way.

## 7. Training rows (A4)

`prep/convert_rows.py` (`66c9f272…`) converts `chat-corpus-ship.jsonl` (SELECTED rows only)
into the trainer's schema, byte-compatible with the stage-3 reference rows:

```json
{"format": "chat", "utterance": "<elder turn>",
 "label": {"intent": "chat", "reply": "<assistant reply>", "confidence": 0.9}}
{"format": "command", "utterance": "<elder turn>",
 "label": {"intent": …, "entryId": …, "contact": …, "time": …, "medication": …,
           "message": …, "callType": …, "requestedApp": …, "topic": …, "steps": …,
           "confidence": …, "response": …}}
```

* Chat rows (L1/L2/L3) carry label confidence 0.9, the corpus source id and layer.
* Command rows (L4 claw-back) are joined back to their ORIGINAL suite row by
  `(provenance.source, provenance.line)` (noise variants inherit the parent's origin line),
  so the 12-key label is the suite's own canonical object; only `response` is taken from
  the corpus (the GEC-corrected reply).
* Strict: any unmappable row or empty utterance/reply prints every offender and exits 3 —
  never a partial set, never a guess (`to_text` refuses unknown formats; nothing is
  invented to fill a gap).
* Split: deterministic, seed 42, stratified by family, 5 % valid with a hard cap of
  `--valid-cap 500` (a recorded deviation from a plain 5 %: the trainer evaluates the whole
  valid set every 100 steps, and ~1,700 valid rows would add hours to a 3-epoch run; the
  stage-3 reference used 271 valid / 5,156 train).

*Filled in Phase B (convert ran 2026-10-15 21:40:48, rc=0, after the one-row repair):*
`data/train-v17.jsonl` **17,235 rows** — chat 12,064 / command 5,171, sha256
`52f98e20408166c31c2f8444c45cfcce2af4b8274e8a731ecea552f3d6a286ad`; `data/valid-v17.jsonl`
**500 rows** — chat 350 / command 150, sha256
`62e83a9e3b1400c6638c812613c6da451e1ea7a4cb05d96614f0b3186e20b59b`; report
`corpus/<run>/convert-report.json` (corpus_sha256 `ec2eee2f…`, rows_in 17,735, seed 42,
valid_frac 0.05, valid_cap 500; chat sources: synthetic_eldercare 5,609 · taskmaster 2,165 ·
devanagari_ecommerce 2,083 · soda 1,769 · prosocial_dialog 788; command sources:
intent_training_teacher 4,611 · intent_training_noised 642 · abstain_honesty_edge_cases 68).
Mix landed at **70.0 % chat** (12,414-of-17,735; the trainer's own header confirms
"17235 train (5171 command / 12064 chat = 70.0% chat) / 500 valid").

## 8. Training launch (A4)

### 8.1 Recipe (pinned by T-182, read from `config.yaml` by the trainer)

`r=16`, `alpha=32`, `lr=1.5e-4`, `epochs=3`, `max_seq_len=1024`, `bf16`, `bs=4 × ga=4`,
QLoRA 4-bit NF4, cosine, warmup 3 %, seed 42. `chain-train.sh` (verbatim flags):

```
v17-trainer/train_chat_lora.py \
  --base-path checkpoints/qwen-s43-merged --base qwen \
  --out cnr-cnr-v17-20261015-0209 \
  --train data/train-v17.jsonl --valid data/valid-v17.jsonl \
  --seed-offset 0 --floor-step 300 --floor-token-acc 0.90 --floor-json-start 0.90 \
  --save-steps 40 --save-total-limit 30
```

Terminators: `<|im_end|>` (id 151645), asserted to be exactly one token in the base's EOG
set. Eval every 100 steps, logging every 20, checkpoint every 40 (keep 30); floor gate at
step 300 (token accuracy ≥ 0.90, json_start ≥ 0.90, prefix mismatch ≤ 0.1, ≥ 1 scored row;
writes `eval/floor-<tag>.json` and aborts on failure); resumable via the latest checkpoint;
final model → `checkpoints/<tag>-final`.

### 8.2 Pre-flight evidence (run 02:36-02:39 on the stage-3 reference mix, then killed)

The trainer was exercised end-to-end for ~3 minutes on `data/train-chat-mix.jsonl` /
`valid-chat-mix.jsonl` (6,153 / 326 rows) before the real corpus existed:

```
[train] WARNING: hard determinism unavailable under this torch/bnb build (only Tensors of
        floating point dtype can require gradients) — fell back to soft determinism (cudnn
        flags + deterministic reductions only; residual bf16/bnb run-to-run variance remains)
[train] seed=42 determinism=soft base=qwen base_path=checkpoints/qwen-s43-merged
[train] 6153 train (4307 command / 1846 chat = 30.0% chat) / 326 valid
[train] terminator='<|im_end|>' (id 151645)
[train] recipe r=16 alpha=32 lr=0.00015 epochs=3.0 bs=4 ga=4 -> ~1155 steps (chkpt every 1000, keeping 1)
```

Config-driven recipe confirmed (r/alpha/lr came from `config.yaml`, not the stage-3
constants), GPU 100 % / ~13.9 GB, **~5.75 s/step** at `max_seq_len 1024`. Two warnings to
carry: the **soft-determinism fallback** (recorded above; honest — the box's torch/bnb
build cannot give hard determinism) and **one transient CUDA allocation warning** at step
25 (a 2.2 GB request against 241 MB free reported) that did **not** kill the run (training
continued to step 26). Pre-flight artifacts were removed afterwards
(`checkpoints/cnr-v17-preflight`, `eval/floor-cnr-v17-preflight.json`, the copied data
files); the reference mix itself is untouched.

### 8.3 Launch (filled in Phase B)

Launch sequence (all detached, verified live): first attempt **2026-10-15 21:40:55** →
died 21:41:13 at CUDA init (`CUDA_ERROR_UNKNOWN 999 from cuDevicePrimaryCtxRetain` — the
3090 display-engine wedge, §11.21); relaunched **2026-10-16 06:14:42** after the owner's
long power-off + card reseat (setsid pid 3805 / trainer 3808) — passed CUDA init.
Expected steps = ceil(17,235/16) × 3 = **3,234**; checkpoint dir
`repo/tools/train-intent/checkpoints/cnr-cnr-v17-20261015-0209` (the chain's double-prefix
tag `cnr-cnr-v17-20261015-0209` — cosmetic). Training ran the full 3,234/3,234 steps and
**completed clean 2026-10-16 16:09:05 (exit=0)**: 4:49:33 stepping, final eval_loss 0.1656
(still descending; ~0.187 @ 1000), `-final` written (seed 42, determinism soft). The run
carried **two floor-gate aborts and restarts** — recorded in full in §12 (both red readings
stand as recorded).

**Sanity verdict.** The automated poll did fire — `logs/TRAIN-SANITY.txt` (header stamped
2026-10-15T21:41:23+11:00) caught the FIRST launch: header lines read cleanly ("17235 train
(5171 command / 12064 chat = 70.0% chat) / 500 valid", terminator `<|im_end|>` 151645,
recipe → ~3234 steps) and the verdict was **FAILED at poll 1** with the CUDA-init
traceback in the tail (plus the `TRAIN-SANITY-FAILED` marker). That verdict was correct —
it caught the GPU wedge, not a training fault. For the successful post-reseat run the
equivalent verdict was taken live (header + step rate + GPU + error-free log) and is
recorded in §12.3; the watcher itself had died with the reboot (not re-armed).

**Sanity poll, automated (deviation, recorded).** The dispatch's ≤10-minute launch poll
assumed a build that finishes within the session; the corpus build is teacher-bound
(measured ~5 s per L2 call, ~15 s per L3/GEC call, ~5,000 calls → ETA ≈ 14 h, i.e. the
training starts long after this session). The poll is therefore performed by the detached
watcher `prep/train-watch.sh` (launched 02:1x, nohup+setsid): it waits for the `[train]`
header, then polls ~10 minutes on the house pattern (process alive, `[train]` header,
GPU utilisation, no traceback / floor-gate abort) and writes
`logs/TRAIN-SANITY.txt` (+ `logs/TRAIN-SANITY-FAILED` on failure) with the header lines and
log tail. Phase B reads the verdict rather than re-running the poll.

**Expected timeline (estimates, for Phase B planning).** Build #1's output write ≈
16:00-16:30; build #2 (same-gate replay, §6.2) ≈17:30-18:00; convert + launch ≈18:00-18:30;
`TRAIN-SANITY.txt` ≤ ~30 min after launch. Training ≈ 6,300 steps × ~5.75 s ≈ 10 h → the
`-final` model is expected ~04:00-05:00 on Oct 16, after which the GGUF export +
`--full-gates` harness run over it (Phase B's second half).

## 9. Monitors, resume, and the exact check-on-it commands

```bash
# one-screen status (processes, stage, tier log, review state, GPU, disk, spend)
ssh anjan@192.168.1.117 'bash /mnt/nvme1/cnr-v17/prep/status.sh'

# live translation-tier progress (the builder buffers its own [step] lines)
ssh anjan@192.168.1.117 'tail -f /mnt/nvme1/cnr-v17/logs/translate/tier.log'

# the chain log (stage transitions, builder exits, review waits)
ssh anjan@192.168.1.117 'tail -n 40 /mnt/nvme1/cnr-v17/logs/corpus-build.log'

# the training log once launched
ssh anjan@192.168.1.117 'tail -f /mnt/nvme1/cnr-v17/logs/train-cnr-v17.log'

# review state / materials
ssh anjan@192.168.1.117 '$PY /mnt/nvme1/cnr-v17/prep/review_state_counts.py /mnt/nvme1/cnr-v17/corpus/cnr-v17-20261015-0209/ship/l2-review.json'
ssh anjan@192.168.1.117 'cat /mnt/nvme1/cnr-v17/corpus/cnr-v17-20261015-0209/ship/review-summary.txt'

# the recording waves (per-source dispositions as each source's post-edit saves)
ssh anjan@192.168.1.117 'tail -n 30 /mnt/nvme1/cnr-v17/logs/record-waves.log'
ssh anjan@192.168.1.117 'ls -la /mnt/nvme1/cnr-v17/logs/REVIEW-RECORDED'   # present = all 4 waves done
# keys still pending for one source (re-run the wave by hand if it ever timed out):
ssh anjan@192.168.1.117 '$PY /mnt/nvme1/cnr-v17/prep/review_keys.py <out>/l2-review.json taskmaster pending'
# record a single batch by hand (exact builder CLI; NO --note flag exists — §6.3):
ssh anjan@192.168.1.117 'cd /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent && \
  /mnt/nvme2/workspace/projects/parent-assistant/tools/train-intent/.venv/bin/python src/build_chat_corpus.py \
  --mix ship --run-id cnr-v17-20261015-0209 --out-dir /mnt/nvme1/cnr-v17/corpus/cnr-v17-20261015-0209/ship \
  --record-spot-check taskmaster#0000 --reviewer cnr-t183-agent-review --disposition spot_checked'

# ALIVE check (house pattern — comm-filtered, never a bare pgrep -f)
ssh anjan@192.168.1.117 "ps -eo pid,etime,comm,args | awk '\$3 ~ /bash|python/ && /chain-corpus|chain-train|build_chat_corpus|train_chat_lora|translate_teacher|review-watch|train-watch/'"

# STOP everything cleanly (process groups; the chain is its own setsid leader)
ssh anjan@192.168.1.117 'kill -TERM -- -<chain-pid>'

# RESUME the trainer after any stop (caches make every stage resumable)
ssh anjan@192.168.1.117 'bash /mnt/nvme1/cnr-v17/chain-train.sh cnr-v17-20261015-0209'
```

Discipline notes for whoever touches the box next: nvme2 is 99 % full (the repo checkout
lives there — read-only use), never run `reload-gpu.sh`, never soft-reboot (power-off
protocol only), and `nvidia-smi` before launching anything GPU-bound.

**SSH outage (recorded, unresolved in-session).** Between the last good session
(03:22:21) and 03:31, the box's **sshd stopped completing handshakes**: TCP :22 is
accepted (SYN/ACK) but no `SSH-2.0-…` banner ever arrives (client: "Connection timed out
during banner exchange"; raw `nc` read: empty). The box itself is **alive and serving** —
ICMP answers in ~2 ms and Open WebUI on :3000 returns HTTP 200 with `x-process-time: 0`
(diagnostic checks run 03:45-03:48). This is an **sshd/userspace-login-path fault, not a
box hang**: the detached run (chain, builder, waves, watchers) needs no ssh and continues;
all monitoring from the authoring machine is blocked until sshd recovers (the background
retry loop exhausted its **full 55 attempts — NO-RECOVERY — ending 04:51**, with no
recovery sign at any point; a coordinator-armed recovery monitor (armed ~04:29; ~8 min
rounds, 04:37/04:45/04:53 each `:3000=200` `ssh_rc=255`; ~2 h window) keeps polling and
runs the recovery checks listed below automatically on the first successful login; a port probe found **no alternate management surface** — only :22 answers
among 22/2222/222/2200/8022/9090/8006/8443/443 — while the box kept serving **HTTP 200 on
:3000 in 10 ms and 0 % ICMP loss at 04:23**). If it never recovers, the recovery is a
physical/console intervention — power-off protocol, never a soft reboot. Verification
coverage that the outage affects: **wave 4 (oasst1) + the final sweep + the chain's
wait-loop exit + build #2's start were NOT observed from the Mac** — waves 1-3 were
(149/126/49 recorded; 0 pending at 03:27:46, see §6.3). What to check first after
recovery: `logs/record-waves.log` tail + `logs/REVIEW-RECORDED.txt`, then
`logs/corpus-build.log` for "review recorded … resuming builder" and the `[second]` start
line.

**Phase B correction (2026-10-16) — the "the detached run … needs no ssh and continues"
claim above is empirically WRONG.** The box-wide fault hit at ~03:26 **mid-build-#1**: the
builder's in-flight teacher call never returned (translation tier's last call 03:26:38-46
with `rows_so_far=2`, no spend afterwards), and build #1 never completed — when the box came
back, the run dir held only `l2-review.json`. The chain resumed **2026-10-15 18:00:53**
after the owner's sanctioned power-cycle (`chain-corpus-resume.sh`, byte-identical to
`chain-corpus.sh` except the header comment + pinned RUN_ID; the 324 recorded review keys
and the translation cache survived and were served hot). Detachment protected the processes
from the ssh client, not from a box-wide fault: such a fault stalls a detached run exactly
like an attached one. The standing watch discipline this produced: every stage runs
box-side detached (`nohup setsid` + start/done markers) under a caffeinated, bounded
Mac-side waiter — nothing depends on an ssh client surviving (§11.24).

**Expected on-box timeline for the deferred events (estimates).** Wave 4 + the sweep fire
at oasst1's own save (~03:55-04:10) and their logs are static thereafter; build #1's
output write lands ≈ 14 h into the run (~16:00-16:30); build #2 (same-gate replay, §6.2)
adds ~1.3 h (~17:30-18:00); convert + training launch ≈18:00-18:30 — `TRAIN-SANITY.txt`
≤ ~30 min later. **Phase B's first commands are the three above; none needs the box to be
mid-work — they read completed files.**

*Rollback of the remote-hand testing:* the sshd banner fault is unrelated to anything the
run wrote (the run's writes are confined to `/mnt/nvme1/cnr-v17/` and the nvme2 repo
tree); nothing in the run touches sshd or system auth files.

## 10. Spend

| Counter | Value (verbatim, +11:00) |
|---|---|
| OpenRouter account credits / usage at 02:10 | 3,180.00 / 3,156.69 → **≈ $23.31 headroom** |
| This key's `usage_daily` at 02:10 | $0.0722 (pilots + the aborted first attempt) |
| This key at 02:28 (last fetch before the ssh outage) | `usage=1615.0064`, `usage_daily=0.1249`, `usage_weekly=0.1249`, `byok_usage=25.1750` (prior-day BYOK), account `total_usage=3156.7406` |
| Observed burn 02:10→02:28 (taskmaster post-edit running) | +$0.0527 ≈ $0.003/min — consistent with the projection below |

Projected build spend is small (flash-lite class: ~$0.10/M in, ~$0.40/M out; the build's
~5,000 calls × ~1 k output tokens ≈ $2-3), but the **hard ceiling is the account balance,
not the projection** — if it runs dry, calls fail, batches are held and counted (never
substituted). *Filled in Phase B:* account `total_usage` **3156.6900 → 3159.39888
(+$2.71)** from the 02:10 baseline to the build's end (fetched 2026-10-17 00:40 +11:00) —
covering the retry waves, the resumed build, build #2 and L3/GEC under the 8-thread pool
(incl. the ~$2 of mid-L3 discarded by the owner-directed speed restart, §11.20); account
credits 3,180 → **headroom ≈ $20.60**. The projection ($2-3) held and the ceiling was
never approached.

## 11. Deviations, decisions, and owner-confirmable items

1. **Trainer staged at `v17-trainer/`, not `src/`** (§3.1) — keeps the worktree `src/`
   byte-identical to the branch; recorded with the exact diff (§3.2).
2. **Translation-tier substitution to the recorded teacher** (§5) — both offline NMT tiers
   piloted and rejected with evidence; teacher tier adopted and recorded.
3. **Transport substitution Gemini → OpenRouter** (same model id) — the direct key is 402
   (credits depleted), on both machines; the builder's own `--teacher-transport openrouter`
   seam is used and the tier shares it.
4. **Two-build flow with a bounded 12 h review wait** (§6.2) — a consequence of the
   builder's data flow (post-edited rows exist only at output-write time); the wait is
   recorded in `logs/REVIEW-NEEDED.txt` and bypassable via `logs/REVIEW-SKIP`.
5. **L2 spot-check is agent-performed, owner-confirmable** (§6.3) — method stated in
   advance; every batch screened mechanically, a spread sample read; nothing silently
   admitted.
6. **Training sanity poll automated** (`train-watch.sh`, §8.3) because the build outlives
   the session; the pre-flight (§8.2) already validated the launch path end-to-end.
7. **Soft-determinism fallback + the transient OOM warning** (§8.2) — recorded, not hidden.
8. **Box kernel is 6.17.0-29, not 7.0.0-38** (§2) — as-observed.
9. **`--valid-cap 500`** in the conversion (§7) — recorded deviation from a plain 5 %.
10. **First run aborted** (`cnr-v17-20261015-0157`) before writing anything, replaced by the
    instrumented tier (§6.1) — recorded for the audit trail.
11. **The chat golden fixture stays ineligible** (§4) — the owner's 50-batch human review is
    outstanding; this run does not fabricate eligibility.
12. **The L2 review ran as a faithful replay, not on the build's live text** (§6.3) — the
    builder keeps post-edited text in memory until output-write, so the agent review was
    performed in-session with the builder's own seams (`prep/postedit_replay.py`: same
    candidate extraction, prompt, style spec, teacher config/transport, same batch keys) and
    the recorded dispositions were applied per source through the builder's own
    `--record-spot-check` as soon as each source's batches materialised (`prep/record-waves.sh`
    → `l2-review.json`). Agent-performed, owner-confirmable; evidence hashed in §6.1.
13. **`oasst1` (60 batches, 1,200 rows) recorded as `rejected`** (§6.3) — the replay found a
    genuine post-edit failure mode (degenerate collapse to a constant apology on long
    assistant-QA pairs). Rejecting substandard batches is the dispatch's explicit remedy:
    the builder's admission seam will drop whatever the source still yields; nothing is
    silently admitted. If the post-reject mix misses its L4 floor, the builder's own
    hold/counters report it and the remedy is a floor-note decision, not a silent top-up.
14. **Dispositions are recorded *during* the build, before build #1's admission seam** —
    keyed by the same batch ids the builder holds; correctness rests on the builder's own
    save/read (schema `chat_corpus_l2_review/v1`): `record-waves.sh` waits for each source's
    keys to appear as `pending` (i.e. that source's post-edit has saved), then drives the
    builder's own `--record-spot-check` per key. Because the builder's per-source save can
    *revert* wave writes (in-memory state written over the file; atomic, so no corruption),
    the script adds per-wave repair passes plus a final sweep after the last save (§6.2).
    Build #2 then re-runs the selection with the dispositions present from the start. Two
    recorded refinements: the CLI carries **no note flag** (frozen artifact — the per-batch
    record is reviewer+disposition+timestamp; the method lives in §6.3 + the wave log), and
    "transient-failure recovery" is partial, item 15.
15. **Build #2 recovers a build-#1-held batch only if a disposition exists for its new
    key** — a batch whose post-edit call failed in build #1 has no key; if its call
    succeeds in build #2 the key appears as `pending` at build #2's admission and its rows
    are still held (counted). The waves deliberately do **not** chase build #2's new keys:
    in build #2 the per-source loads happen within seconds of each save (translations are
    cache hits), so recordings would race the builder's own saves *and* the (cache-fast)
    admission seam for ≤ ~40 rows of spend; the counted shortfall is the honest outcome and
    is reported in §6.4's counters. The affected ids in this run: `taskmaster#0112`,
    `taskmaster#0136` (observed) plus any analogue in later sources (§6.4).
16. **The box's sshd wedged at ~03:25-03:31 (unresolved in-session, §9)** — TCP :22
    accepts but no banner; the retry loop exhausted all 55 attempts (NO-RECOVERY, ended
    04:51; live probe 04:54 still banner-timeout); a coordinator-armed monitor keeps
    polling (04:37-04:53 rounds: `:3000=200`, `ssh_rc=255`) and runs the §9 checks on the
    first successful login; no alternate management port; the box stayed otherwise alive
    (ICMP + Open WebUI :3000 healthy at 04:23 and again ~04:54); the detached run is
    unaffected. Verification of wave 4 + the sweep
    + the build-#2 transition is deferred to Phase B's first minutes (exact commands in
    §9); if sshd never recovers, physical/console recovery is required (power-off
    protocol; never a soft reboot). Flagged for the owner: a box-side sshd/session fault
    independent of anything this run wrote.
17. **Build #1's admission already observes this run's recordings** (§6.2 admission-timing
    note; established by a code-read — `src/build_chat_corpus.py:2383` runs after
    L3+GEC, ≈ 14 h in, while the review state is complete by ~04:10). Consequence: the
    two builds produce the same gate state and build #2 is a same-gate replay (~1.3 h of
    post-edit re-pay, no cache for that stage). Phase B records corpus identity from
    build #2's outputs; build #1's outputs are an intermediate with the same state.

*Deviation numbering continues (Phase B, 2026-10-15/17).*

18. **Corpus repair — one row dropped** (§15). `taskmaster…dlg-054c8e35-…:9` carried
    `user_turn: ""` (reply intact; the ONLY empty row of 17,736) — a pre-existing cached
    empty translation of the profanity turn (the tier cache is sha256-keyed; the empty
    string is key `e5f5320c…`, one of 4 empty-text entries) plus a missing non-empty guard
    in L2 ingestion; not patch-related. Convert refused (exit 3) until dropped: 17,736 →
    **17,735** rows, sha `5fd4262d…` → **`ec2eee2f…`**; backup kept; full record
    `corpus-repair-record.json` (producer-evidence block verified on the box).
19. **Build #2 ran as the `pending>0` fallback** (§6.2 / §11.20). The SPEED RESTART's tail
    skips build #2 when the review is fully recorded; the patched build #1's post-edit
    created **6 new pending oasst1 keys** (re-keyed batches from the changed candidate
    count — §11.15's anticipated case, materialized), so the tail's designed fallback ran
    build #2 (21:16→21:24:41). Final review state **6 pending / 327 spot_checked /
    53 rejected / 386 total**; the shipped corpus is build #2's.
20. **SPEED RESTART (owner wall-clock directive, relayed 2026-10-15 ~20:50)** — three
    levers: build-#2 skip design (`chain-corpus-tail.sh`; falls back when pending ≠ 0,
    §11.19); a bounded 8-thread teacher pool in `build_chat_corpus.py` (opt-in
    `CNR_TEACHER_CONCURRENCY=8`; default 1 = the original serial loop; suite 126/126 green;
    sha `c7736b99…`; de-risked by a box rehearsal on the real transport, 48 s wall);
    `config.yaml` `gemini.requests_per_minute` 25→300 during the build only (restored
    after; additive pacing, no 429s). Restart cost ≈ $2 of discarded mid-L3 (L3's cache is
    end-only — deliberate, owner-directed).
21. **GPU wedge + reseat recovery** (§12 / §13). The 3090 display-engine wedge returned
    (CUDA 999 at `cuDevicePrimaryCtxRetain`; NVML readable, CUDA dead); two sanctioned
    cold boots (Oct 15 17:53, 23:31) did NOT clear it; the owner's long power-off + **card
    reseat** (Oct 16 06:12) DID — training then ran end-to-end. Card-replacement verdict
    withdrawn. Each CUDA-init death re-wedged sshd (the same banner-less mode as §11.16).
22. **Floor-gate relocation, owner-ratified; both red readings preserved** (§12). The
    in-run guard (stack default: token_acc ≥ 0.90 @ step 300, calibrated on the trivial
    stage-3 corpus) read red twice: **0.862 @ 300** and (step moved to 1000) **0.884 @
    1000**; both abort records kept verbatim; **no threshold, fixture or measurement was
    adjusted anywhere**. The run completed with the guard relocated out (`--floor-step 0`)
    and the same measurement retained as an end-of-run post-hoc probe: **0.8940** —
    recorded whatever it was (0.006 below the stack default; evidence, not a gate). Owner
    ratified 2026-10-16 (ratification block in `run-restart-record.json`; the countermand
    path is closed).
23. **Checkpoint resume is broken in the installed stack** (§12.2). Transformers resume
    rejects the trainer's own PEFT checkpoints (no full-model index); a resume attempt
    crashed. Every interruption therefore cost a full restart. Recorded; not repaired
    in-flight.
24. **7 h Mac-side silence + the new watch discipline.** The 16:30 verify/smoke payload
    ran box-side, but the Mac's ssh client hung while the Mac slept — nothing was
    caffeinated. Standing discipline since: every stage runs box-side detached
    (`nohup setsid` + start/done markers) under a caffeinated bounded Mac-side waiter;
    nothing depends on an ssh client surviving. §9's "unaffected" claim is corrected
    (see §9).
25. **Export `--base-id` catch** (§13). `export_gguf.py`'s `BASE_TAGS["qwen"]` is the raw
    hub id `Qwen/Qwen3-1.7B`; a default invocation would merge the adapter into the WRONG
    base. The export was run with `--base-id checkpoints/qwen-s43-merged` (the adapter's
    recorded base); invocation recorded.
26. **Config Phase-B change** (§15). Chat section enabled/run_id/corpus_root; sha
    `1f176ce0…` → `3a151ad5…`; the standard path is provably unaffected (single
    `chat_variant_config` call site, inside `_run_full_gate`).
27. **Harness parse defect found + repaired** (§14.3). `_first_complete_json` required the
    legacy wire key `"action"` while every current emitter (seeds/template, golden corpus,
    training corpus, app grammar) uses canonical `"intent"` — every correct gguf completion
    had been scored as an abstention. Minimal canonical-key bridge in the helper only; no
    metric/threshold/fixture/corpus touched; 38/38 tests; live-verified on the box;
    local↔box byte-identical `9a1e7484…` (was `357962ae…`).
28. **Manifest re-emission** (§15). `corpus.sha256`/`corpus.turns` re-pointed to the
    repaired corpus and `content_hash` recomputed; verified with the harness's own
    `provenance_evidence()` (pairing manifest == on-disk == trained). Manifest `25c55f6e…`
    → `fb7f7779…`; backup kept.
29. **Judge-key money gate + the gate decoupled** (§14.4). The only GEMINI key on the box
    returns HTTP 402 ("prepayment credits are depleted"); recorded as an owner money gate
    (~<$1 of flash-lite). The ~8,000-row decode is paid ONCE via the additive `--preds-out`
    seam (`ee0aca33…`, 41/41 tests) so the funded re-run is a minutes-long fixture replay
    plus the fresh 500 judge calls. The earlier standard-gate run was killed as superseded
    at 159/8,000 turns (zero evidence derived).
30. **The owner's ACCEPT-ALL review + candidate generation** (§14.1–14.2). Fixture
    `83283663…` → **`40bec05d…`** (500/500 accepted, reviewer "Anjan Poudel"; atomic
    rewrite touching provenance + header manifest only). Chat-outputs generated
    app-faithfully — **context turns are not fed** (the app's `buildChat` has no history
    slot) — recorded as a fidelity note.

## 12. Training run: the floor-gate saga, restarts, completion, and the post-hoc probe

### 12.1 Floor-gate abort #1 (2026-10-16 06:42:03)

The post-reseat run (launch 06:14:42, §8.3) aborted at its own mid-run floor gate: **step
300, token_acc 0.862 < 0.90** (command_acc 0.935, chat_acc 0.831, json_start 1.000 — the
shapes are learned; the curve was healthy: eval_loss 0.2647 @ 100 → 0.2336 @ 200). The
0.90-at-300 checkpoint is the trainer stack's **inherited default calibrated on the
stage-3 chat corpus** (chat-lora-v6: eval_loss 0.067 @ 300 — a trivial corpus; v17 runs at
~3× that loss scale); it is **not** pinned by T-183 or FR-CNR-016 and **not** a T-182
harness gate. Recorded red; checkpoint preserved aside
(`checkpoints/cnr-cnr-v17-20261015-0209.abort300-preserved`); `eval/floor-…at300-abort.json`.

### 12.2 Resume-broken finding + restart #1

**Checkpoint resume is broken in the installed stack** (transformers resume rejects the
trainer's own PEFT checkpoints — no full-model index; the resume attempt crashed 09:04:45).
Consequence, recorded: every interruption costs a full restart. RESTART #1 (launch
09:07:57, fresh step-0 run): the ONLY change = `--floor-step` 300→**1000** (all floor
values untouched) — script `chain-train-restart1-floor1000.sh`, diff `restart1-script.diff`,
record `run-restart-record.json`. It aborted again: **step 1000, token_acc 0.884 < 0.90**
(command 0.945, chat 0.857, json_start 1.000; eval_loss ~0.197 @ 700 → ~0.187 @ 1000,
still descending) — abort 10:37:55; preserved (`.abort1000-preserved`,
`eval/floor-…at1000-abort.json`).

### 12.3 Guard relocation (owner-ratified) + restart #2 + completion + the post-hoc probe

Both readings **stand as recorded red** (0.862 @ 300; 0.884 @ 1000). Decision (reported
with an explicit countermand path; **the owner RATIFIED 2026-10-16**, recorded as a
`ratification` block in `run-restart-record.json`): complete the run with the **in-run
guard disabled** (`--floor-step 0`) because (a) the 0.90 bar is the stack's inherited
stage-3 default, not a T-183/T-182 acceptance gate; (b) the spec's gates are the harness
chat + hard gates over the **exported candidate**, and a guard veto would extinguish the
unit's output with zero candidate and zero harness evidence — with resume broken, a veto
means another full restart; (c) the same measurement is retained as a **post-hoc
end-probe over the final artifacts**, its value recorded whatever it turns out to be.
RESTART #2 launched 11:19:17 (`chain-train-restart2-complete.sh`, diff
`restart2-script.diff`; header carries the full rationale; `run-restart-record.json` carries
both abort blocks + launch stamps).

**Training completed clean 2026-10-16 16:09:05 (exit=0): full 3,234/3,234 steps, 4:49:33
stepping, final eval_loss 0.1656** (descending to the end).

**End-probe.** No standalone probe existed in `v17-trainer/`, so the driver was written and
staged at `v17-trainer/end_probe_final.py` (113 L, py_compile OK, `--limit` smoke mode; it
imports `run_probe` from `train_chat_lora.py` = the same measurement code path; loads
base-4bit + the PEFT adapter from `<out>-final`; not an export gate). Full 500-row probe
**2026-10-16 22:58:48, exit=0** → `eval/floor-cnr-cnr-v17-20261015-0209.final-posthoc.json`:
**token_acc 0.8940** (0.006 below the stack's 0.90 default — per the ratified relocation
this is evidence, not a gate), command 0.9508, chat 0.8696, json_start 1.000, scored
500/500, prefix_mismatch 0. The value is what it is; nothing was tuned to move it.

## 13. GGUF export (Q4_K_M)

Export completed **2026-10-16 23:00:19 (exit=0)**:
`models/intent-ne-qwen-s43-chat-v17-q4_k_m.gguf` — **1,107,408,736 B**, sha256
`e05cc8a266198336f508cef2f6d2a8887b3db1eee3f4a4159cdeb2ab3df59d71` (+ `.sha256` sidecar,
`eval/export_history.tsv`); merged intermediate `checkpoints/qwen-s43-chat-v17-merged`.
**Recorded catch (§11.25):** `export_gguf.py`'s `BASE_TAGS["qwen"]` is the raw hub id
`Qwen/Qwen3-1.7B` — a default invocation would merge the adapter into the wrong base; the
export was run with `--base-id checkpoints/qwen-s43-merged` (the adapter's recorded base,
the shipped 1.7B lineage). Tool: `src/export_gguf.py` staged from the stage-3 checkout
(sha `040e3faf…`, byte-same); invocation record `corpus/<run>/export-invocation.txt`.

## 14. Phase B gates: the review gate, candidate generation, and the full ship gate

### 14.1 The 50-batch owner review — ACCEPTED (this unblocked everything downstream)

The full ship gate refused an ineligible fixture (harness design, not an obstacle to work
around): the first `--full-gates` attempt (2026-10-16 23:03) exited 2 with `load_fixture()`
→ "the fixture cannot serve as gate evidence … 50 batch finding(s)" — a refusal writes
nothing (`logs/fullgate-attempt.log`). Owner verdict (2026-10-16, via chat): **ACCEPT ALL
b001–b050**. Recorded with the fixture's own CLI, one call per batch
(`eval/author_chat_golden.py --record-review bNNN --disposition accepted --reviewer
"Anjan Poudel"`, no notes; the atomic rewrite touches provenance + header manifest only —
no turn text or ids) → fixture sha `83283663…` → **`40bec05deb7f2cc57c38a2dab3130bd93fe4c007c45aabc9ec331864aa19da47`**
(rev `40bec05d`), 500/500 accepted; `require_gate_fixture()` now passes.

**Revision split, recorded deliberately (not reconciled).** The accepted revision
`40bec05d…` is what every gate record in this section cites (the gate report's
`fixture` block included) and is the file the shipped artifact was gated against. The
branch's committed fixture (`tools/train-intent/eval/chat_golden.jsonl`) remains the
authored revision `83283663…`, including its pinned honesty assertion that the review
is pending — the acceptance is a review outcome recorded in this run's notes, and
retro-editing a closed unit's (T-178) declared fixture and its pins is not this run's
act; if folding the accepted revision into the repo is wanted, it is a T2-scope edit
recorded as such. The delta is provenance/header review state only — no turn text or
ids differ; the accepted revision's full sha is the evidence meta's `fixture.sha256`
(`specs/CNR-v17-evidence/chat-outputs-qwen-s43-chat-v17.meta.json`) and the authored
revision's full sha is the test pin at `tests/test_build_chat_corpus.py:1743`.

### 14.2 Candidate replies (chat-outputs)

Generated 2026-10-16 23:15:05 → **23:42:39 (exit 0)**: 500/500 turns, no_json 0,
raw_fallback 0, wall 1,653.2 s → `eval/chat-outputs-qwen-s43-chat-v17.jsonl` + `.meta.json`.
App-faithful recipe (`v17-trainer/gen_chat_golden_outputs.py`, sha `d035609c…`):
single-utterance prompt via the app's own `chat_prompt_template.txt`; **context turns are
NOT fed** (the app's `buildChat` has no history slot — recorded fidelity note);
`chatJSONSchema` grammar, max_tokens 256, temp 0.0, seed 20,260,907.

### 14.3 Harness parse defect found + repaired (§11.27)

`eval_golden._first_complete_json` (the gguf backend's parse; single caller `predict_gguf`)
required the legacy wire key `"action"`, while seeds/`prompt_template.txt`,
`eval/golden_corpus.jsonl`, the CNR training corpus and the app grammar
(`LlamaCommandInterpreter.swift` :306/:326/:367/:371) all use the canonical `"intent"` —
every correct completion was silently NO-JSON'd and scored as an abstention
(`{"action":"none"}`). Fixed with a minimal canonical-key bridge inside the helper only
(legacy shapes unchanged; `action` wins when both present); no metric/threshold/fixture/
corpus touched. 38/38 tests (3 new `CanonicalIntentKeyBridgeTests`); live re-verify on the
box: `predict_gguf('माइयालाई फोन गर')` → `action "call"` (was "none"); record
`corpus/<run>/harness-parse-defect-repair.json`; local↔box byte-identical sha `9a1e7484…`
(was `357962ae…`). The 0.8940 post-hoc probe is unaffected (different code path). This
repo's `results.csv` had zero recorded gguf rows — no prior live run had ever exercised
the path.

### 14.4 Judge-key money gate + the gate decoupled (§11.29)

The chat judge needs a funded `GEMINI_API_KEY` (direct Google transport,
`genai.Client(api_key=os.environ["GEMINI_API_KEY"])`; `eval_chat_gates` has no alternate
transport). A deliberate 1-call smoke (before paying any long decode) returned **HTTP 402
"prepayment credits are depleted"** — the only judge key on the box. Recorded as an owner
money gate (~<$1 of flash-lite). The gate runs honestly without it: `JudgeJournal` records
only successful calls and `run_judge` aborts after 10 failed calls, so a dead-key run
measures the hard gates, lands the chat gates as `not_measured`, writes an honest report,
and does not poison the journal — the funded re-run pays its 500 calls fresh. To pay the
~8,000-row decode once regardless, the additive `--preds-out` seam records scored
predictions for later `--full-gates --backend fixture --preds` replay (sha `ee0aca33…`,
41/41 tests, commit `ffcb9b7c`); a `preds-out WARNING` line exposes any unreplayable row
before a replay run. The earlier standard-gate run (launched 23:03) was **killed as
superseded at 159/8,000 turns** (~23 h ETA, CPU-only; zero evidence derived; note appended
to `logs/stdgate-qwen-s43-chat-v17.log`).

### 14.5 The full ship gate runs

**Report #1 (live gguf decode; judge not yet funded):** launched 2026-10-16 **23:43:22**
(detached `fullgate-run.sh`): `--full-gates --backend gguf --model-path/--artifact
models/intent-ne-qwen-s43-chat-v17-q4_k_m.gguf --preds-out eval/preds-qwen-s43-chat-v17.jsonl
--manifest-out eval/manifest-qwen-s43-chat-v17.jsonl --chat-outputs
eval/chat-outputs-qwen-s43-chat-v17.jsonl --gate-report eval/gate-report-cnr-v17.jsonl
--journal eval/judge-journal-qwen-s43-chat-v17.jsonl --tier "Anzaan" --label
qwen-s43-chat-v17`. Live decode ≈3.5-3.9 s/turn (~8050 rows) → ETA ~08:00-08:30 Oct 17.
Expected verdict, stated in advance: **exit 1 — hard gates measured; chat gates
`not_measured` on the 402-blocked judge (§14.4); §10 latency `not_measured` pending the
Anzaan DV session** — the report is still written (only refusals write nothing). Verdict
recorded here when it lands.
**Report #2 (judge funded):** immediately after the owner's key top-up,
`fullgate-replay.sh` replays the recorded preds (`--backend fixture --preds …`) — minutes —
and pays the 500 judge calls fresh → the complete evidence record (complete-except-latency).

## 15. Phase-B evidence-file changes (corpus repair, manifest, config)

* **Corpus repair (§11.18)** — one row dropped: `taskmaster…dlg-054c8e35-…:9` had
  `user_turn: ""` (reply intact) — a pre-existing cached empty translation (tier cache is
  sha256-keyed; the profanity turn's empty string is key `e5f5320c…`, one of 4 empty-text
  entries) + a missing non-empty guard in L2 ingestion; not patch-related. 17,736 →
  **17,735** rows, sha `5fd4262d…` → **`ec2eee2f…`**; backup
  `chat-corpus-ship.jsonl.prerepair-20261015-214048.bak`; full record
  `corpus/<run>/corpus-repair-record.json` (producer-evidence block verified on the box:
  `sha256("Fuck this shit.") = e5f5320c…` is one of the empty-text cache keys).
* **Manifest re-emission (§11.28)** — the builder-era manifest's `corpus.sha256` pointed
  at the pre-repair corpus; the harness hard-checks manifest↔corpus pairing (step 7:
  "evidence files were altered"), so a post-repair gate report could never be clean.
  Updated ONLY `corpus.sha256` → `ec2eee2f…`, `corpus.turns` → 17,735, and the recomputed
  `content_hash`; verified with the harness's own `provenance_evidence()` → status
  verified, pairing manifest == on-disk == trained, `ship_mix_eligible: true`. Manifest
  sha `25c55f6e…` → **`fb7f7779…`**; backup
  `provenance-manifest.json.prereemission-20261016-230845.bak`; record
  `manifest-reemission-record.json`. No other manifest key touched.
* **Config Phase-B change (§11.26)** — `config.yaml` chat section: `enabled` false→true,
  `run_id` → `cnr-v17-20261015-0209`, `corpus_root` → `/mnt/nvme1/cnr-v17/corpus` (sha
  `1f176ce0…` → **`3a151ad5…`**). Records `config-change-phase-b.{txt,diff}` +
  `config.yaml.before-phase-b`; the standard (non-chat) path is provably unaffected (the
  single `chat_variant_config` call site is inside `_run_full_gate`).
