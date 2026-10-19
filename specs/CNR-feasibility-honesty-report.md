# CNR feasibility honesty statement — FR-CNR-024 (T-192)

**Requirement:** FR-CNR-024 (feasibility honesty — every named leg reported with its measured outcome and an evidence pointer; no silent drop). Related: FR-CNR-025 (device-validation completion gate), FR-CNR-003 (chat sampling fixed seed / recorded temperature).
**Feature / branch / worktree:** `conversational-nepali-replies` · `feat/conversational-nepali-replies` · `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`. **Authoring HEAD:** `ae091984` ("[CNR] T-187: implement-notes fixup — reword inline gate invocation (INJ-011 shell-scanner trip)"). **Date:** 2026-10-17.
**Consumers:** the workflow's `final-sign-off` (T2 + HIL — NFR-CNR-011 records the DV-1..DV-6 results and this statement), read alongside the acceptance record, the DV record and the provenance manifest.
**Verdict source of record:** `specs/design-l1.md` §20 ("Feasibility honesty statement (FR-CNR-024; locked constraint C13)") — the seven-row table this statement mirrors leg by leg. Legs the design names outside that table (its §11.7 P2 hooks, §18's DV protocol, NFR-CNR-002 latency) are carried in Part B, each marked as such.

**Cross-references the sign-off needs, explicit:**
- **Provenance manifest:** sha `fb7f7779…` post-re-emission (run notes §6.4 / §15); full sha `fb7f7779c801706caddc74ef499198eb14c1ddc05dd89da1a7766cd476adab55` (also carried in the shipped promotion record, `specs/T-184-notes.md` §1).
- **Gate report identity:** `eval/gate-report-cnr-v17.jsonl` — report #1, launched 2026-10-16 23:43:22, `--preds-out eval/preds-qwen-s43-chat-v17.jsonl`, "Live decode ≈3.5-3.9 s/turn (~8050 rows) → ETA ~08:00-08:30 Oct 17" (run notes §14.5). **It does not exist locally as of authoring; no verdict is claimed for it here.**
- **DV record version:** `specs/CNR-device-validation-protocol.md` at commit `aaf0143c` ("[CNR] T-187: DV-1..6 device-validation protocol and record (all items BLOCKED — no Anzaan session)").

**Status vocabulary (per leg; a status is never upgraded without an evidence pointer):** **DELIVERED** (shipped with its measured evidence recorded, as far as the layer measured) · **UNDER-DELIVERED** (shipped short of the design's claim; shortfall stated) · **MEASURED AT THE RUN** (the training-box leg; sub-states stated) · **NOT MEASURED / NOT ATTEMPTED** (named, with its dependency) · **BLOCKED** (T-187's vocabulary: a named dependency prevents the observation; never a pass) · **OWNER-DESCOPED** (the owner's 2026-10-15 decision moved the leg to the successor initiative; the explicit record is the reporting — `specs/plan-tasks/amendments/amendment-6-p2-descoped-2026-10-15.md`) · **RE-OPENED / EXECUTING** (added 2026-10-17: the owner re-opened T-190; executing in this run with no measured outcome claimed yet — `specs/plan-tasks/amendments/amendment-7-t190-4b-reopened-2026-10-17.md`; sole exception to the descope, carried in §5).

## The leg table — mirroring design §20 row by row

| # | Leg (the design's §20 name) | Design §20 verdict | Executed state | Evidence pointer |
|---|---|---|---|---|
| 1 | Chat sampling (temp 0.3, fixed seed, GBNF) — the design's row also covers the GBNF/command-schema interplay and command determinism in its own statement column; both halves answered in §1 | FEASIBLE as specified | **DELIVERED** at the implementation layer (values in §1); the on-device form **BLOCKED** (DV-1/DV-5 — no session) | T-186 §2, §6(a), §9(a)-(b); T-187 §7.3; design §5 |
| 2 | Grammar-guard coverage | PARTIALLY feasible — bounded, stated | **DELIVERED AS THE STATED BOUND** (§2); the seeded guard-flag device leg **BLOCKED** (DV-1) | T-186 §2, §6(d); T-187 §6 DV-1 / §7.3; design §7.2 |
| 3 | Cloud chat routing (consent/disclosure/indicator/revocation) | FEASIBLE as specified, with one recorded scope note | **DELIVERED** at the implementation layer (§3); DV-2/DV-3 **BLOCKED**; one CNR-suite flake open | T-186 §2, §3, §6(b)-(c), §9; design §8.2 |
| 4 | Training thresholds (P1) — carries the 1.7B chat-quality leg | FEASIBILITY MEASURED AT THE RUN | **MEASURED AT THE RUN** — candidate exists; the design's gate verdicts **NOT YET LANDED** at authoring; no swap ships (§4) | run notes §6.4, §8.3, §11.22, §12–§14; T-184-notes; T-186 §10 |
| 5 | 4B tier admission | LIKELY NOT ADMISSIBLE on the reference 6 GB tier | **RE-OPENED 2026-10-17 (owner, amendment 7) — EXECUTING**; was OWNER-DESCOPED 2026-10-15..17; no admission verdict produced yet (§5) | `specs/CNR-p2-4b-tier-notes.md` ("RE-OPENED" section); amendments 6 + 7 |
| 6 | Romanized chat (P2) | UNPROVEN | **OWNER-DESCOPED** (T-189) — not attempted; reported not-delivered by the descope record (§6) | `specs/CNR-p2-romanized-notes.md`; amendment 6 |
| 7 | Chat-classified surface scope | STATED BOUND | **DELIVERED AS THE STATED BOUND** (§7) | T-186 §2 (Run E), §9(a); design §8.2 |

Legs this statement carries beyond the §20 table (each marked with its source section):

| # | Leg | Source in the design | Executed state | Evidence pointer |
|---|---|---|---|---|
| 8 | DPO (P2, FR-CNR-026) | §11.7 | **OWNER-DESCOPED** (T-188) | `specs/CNR-p2-dpo-notes.md`; amendment 6 |
| 9 | Consent-based real transcripts (P2, FR-CNR-029) | §11.7 | **OWNER-DESCOPED** (T-191) | `specs/CNR-p2-transcripts-notes.md`; amendment 6 |
| 10 | Device validation (T-187, FR-CNR-025 — the completion gate) | §18 | **BLOCKED** — all six items; DEVICE-VALIDATION-OUTSTANDING (§10) | `specs/CNR-device-validation-protocol.md` §3, §7.3, §7.5 (commit `aaf0143c`) |
| 11 | Latency (NFR-CNR-002) | §13, §18; harness row §11.4 | **NOT MEASURED** (§11) | run notes §14.5; T-187 §1, §7.6; T-186 §10 |

Leg-coverage map (so nothing is left to infer): on-device chat sampling reproducibility at the fixed seed and recorded temperature = §1 (implementation half) + §10 (device half); GBNF/command-schema play and command determinism untouched = §1; guard coverage = §2; cloud-routing behaviour (per-turn decision, fallback, no leak) = §3; 1.7B chat quality on the reference tier = §4; the four P2 legs (T-188 DPO, T-189 romanized, T-190 4B tier, T-191 transcripts) = §§5, 6, 8, 9; chat-classified surface scope = §7 (the design's added §20 row); device validation = §10; latency = §11. No leg of the design's record is omitted.

---

## 1. Chat sampling (temp 0.3, fixed seed, GBNF) — DELIVERED (implementation layer); on-device form BLOCKED

The design's §20 row reads (verbatim): "Reproducibility holds per device tier + build (byte-identical repeats, NFR-CNR-001's own scope). GBNF validity is preserved at temp 0.3 (grammar masks before sampling). NOT claimed: byte-identity across different tiers/builds (Metal float differences can shift distribution tails) — the requirement does not demand it. The per-turn override re-asserts temp 0 for commands, so command determinism is untouched".

Delivered, measured green on the integrated tree (T-186 scoped sweep, Run B):

- `ChatSamplingTests` **20/0** — shape→temperature mapping; "command decode requests temp 0 on every turn (including after a chat turn); chat decode requests 0.3; repeat-decode byte-identity probe via `lastDecodeParameters`; schema passthrough unchanged" (design §21's own test plan; run counts from T-186 §2).
- `LlamaCommandInterpreterTests` **32/0**, `ChatResponseShapeTests` **19/0**, `ChatConfidenceFloorTests` **10/0** (T-186 §2, Run B).
- GBNF/command-schema untouched: "The GBNF constant `LlamaGrammar.chatJSONSchema` … is unchanged in both ranges"; the P0 schema line routes the same string ("that value is DEFINED AS `LlamaGrammar.chatJSONSchema` … the same string, one source, no shape change"); `IntentPrompt.swift` "is **byte-identical across the whole CNR work**" (T-186 §9(a)).
- Command determinism: `IntentRouterCloudChatLaneTests.testNonChatRoutingIsByteIdenticalToThePreChangeReference` — "13-cell byte-identity reference vs the pre-lane structure" — green (T-186 §9(b)).

The on-device form — the actual reproducibility observation at the fixed seed and the recorded temperature — is **BLOCKED**: "No device session was available to this authoring unit … **Every DV item below is recorded BLOCKED — not PASS — with the prerequisite that must clear it**" (T-187 headline); DV-1 and DV-5 rows in T-187 §7.3. T-186 §6(a) states the same limit from the sweep side: "The local DECODE itself (llama.cpp sampling over a GGUF) cannot run in a unit-test process — `ChatSamplingTests` states this in its own header. … The on-device decode, warm/cold latency and reproducibility are T-187's DV-1/DV-5 observations."

The design's explicit non-claim is restated in plain words: byte-identity across different device tiers or builds is NOT claimed (Metal float differences can shift distribution tails); the requirement measures per tier and build (design §5.4).

## 2. Grammar-guard coverage — DELIVERED AS THE STATED BOUND

The design's §20 row (verbatim): "The deterministic checks catch: forbidden तिमी-family forms, the curated familiar↔honorific verb pairs, Latin-script runs in Nepali replies, particle count >1, positionally dangling particles. They do NOT catch: agreement forms outside the curated pairs, case/postposition errors, complex agreement, word-order errors. The guard is a floor (never a false "verified"), not a grammar proof; the gates + P1 corpus carry the rest. A `flag` never invents text; false negatives are the honest residual".

Measured green: `NepaliGrammarGuardTests` **37/0**, `ReplyGrammarFlagResolutionTests` **21/0** (T-186 §2 Run B; journey (d) in T-186 §6, including "testGuardUnavailableKeepsTodaysBehaviourAndRecordsDegraded").

Honest limits, in plain words (the design's own words for each):

- **Lexicon-bounded honorific catch:** "Lexicon-bounded: forms outside the curated pairs are NOT caught (honest limit, §20)" (design §7.2, `honorificAgreement` row). The guard flags the तिमी family and the curated familiar↔honorific pairs; it does not know agreement it has no pair for.
- **Script-classification scope:** "Script classification only; not a spell checker" (design §7.2, `devanagariPurity` row). It flags Latin-letter runs and mixed-script tokens in a Nepali reply; it cannot tell a misspelling from a word.
- The guard verifies, never rewrites: "The guard returns a verdict, never text. There is NO code path in which guard output substitutes model words" (design §7.1). On a flag the flagged text is never spoken — the resolution is escalation (when a consent-granted cloud lane exists) or the safe template.

Device leg: the seeded guard-flag leg of DV-1 is **BLOCKED** with its dependency named — "If the session cannot produce a genuine flag … record that observation and the leg **BLOCKED with the dependency named** (a genuinely flagged reply; no device-side seeding seam is shipped — do not fake one, do not pass on the design's structural argument)" (T-187 §6 DV-1); the DV-1 row as a whole is BLOCKED (T-187 §7.3).

## 3. Cloud chat routing (consent/disclosure/indicator/revocation) — DELIVERED (implementation layer); device form BLOCKED

The design's §20 verdict: "FEASIBLE as specified, with one recorded scope note".

Measured green on the integrated tree (T-186 §2, Run A): the six cloud-chat suites ran as "Executed 160 tests, with 1 failure" (xcresult 159/1/0) — `CloudChatConsentGateTests` 37, `CloudChatRoutingTests` **15/0**, `CloudChatResponderTests` **27/0**, `CloudChatConsentPromptTests` **24/0**, `CloudChatIndicatorAndRevocationTests` **25/0**, `IntentRouterCloudChatLaneTests` **32/0**; the one failure is the flake below. Routing-behaviour journeys (T-186 §6(c)): "testExactlyOneOfTheThirtyTwoCellsIsCloud", "testNoCombinationOfUnknownInputsEverProducesCloud", "testEveryLocalReasonAnswersOnDeviceInTheSameTurnWithZeroCloudCalls", "testAChatTurnCannotReachTheCloudThroughTheFailureReCheckDoor", "testEveryCloudAttemptFailureFallsBackInTheSameTurnWithItsClass" — green; `CloudFallbackTests` **3/0** (T-186 §2 Run E).

**The one recorded scope note — the cloud path's recorded transcription exception on a Gemini stack** (design §20, verbatim): "On a Gemini SPEECH stack device, the utterance transcript already travels for transcription under the existing stack-level consent (recorded OD-12 transcription exception) before the chat decision exists; this feature does not widen that path and cannot retroactively gate it — "no chat content leaves the device" is guaranteed at the chat reply/escalation surfaces, and fully (including transcription) on the on-device speech stack. Recorded, not dropped". Design §8.2 carries the same record; assumption A3 fixes the boundary. In plain words: on a Gemini-speech device the transcript already goes to the provider for transcription before any chat decision exists; the chat consent gate governs the reply surfaces (routing + escalation), cannot retroactively cover transcription, and the feature does not widen that path.

Device legs: DV-2 and DV-3 are **BLOCKED** with named dependencies (T-187 §7.3) — the consent/indicator/revocation journey and the offline/mid-turn-failure degradation have not been observed on device.

Open item carried: the T-186 §3 flake — `CloudChatConsentGateTests.testConcurrentGrantAndRevokeNeverLeaveATornOrMixedRecord()` red in Run A, "1 red in 1 of 4 observations, **green 3/3 re-runs** (37/37 each)"; recorded as a genuine finding (the file was added by the CNR feature, so it is NOT absorbed into the pre-existing baseline) with the recommendation to T-172's owner to admit `.notRecorded` into the `:510` predicate or make the coda deterministic (T-186 §3).

## 4. Training thresholds (P1) — MEASURED AT THE RUN; gate verdicts not yet landed; no swap ships

The design's §20 row (verbatim): "If the corpus/gates do not reach ≥0.98/≥0.98/≥4/5 with all regressions green, the swap does NOT ship; the measured shortfall is reported to the owner. P0 is unaffected either way". The design's thresholds themselves are §11.4's (≥0.98 honorific-agreement pass rate, ≥0.98 no-AI-ism pass rate, ≥4/5 judge mean, with the regression harness green).

Recorded values, verbatim from the run notes (file `specs/CNR-v17-run-notes.md`):

- **Run identity:** "Run: **`cnr-v17-20261015-0209`** (started 2026-10-15 02:09:41 +11:00)" (§6.1).
- **Corpus:** "**17,735 rows**" (§6.4); counters' recorded shortfall: "`shortfalls`: L3 (10,000 target → 5,609) plus the five absent sources" (§6.4).
- **Manifest:** sha "**`fb7f7779…`** (post-re-emission, §15)" (§6.4; full sha in the cross-references above).
- **Training:** "Training ran the full 3,234/3,234 steps and **completed clean 2026-10-16 16:09:05 (exit=0)**: 4:49:33 stepping, final eval_loss 0.1656 (still descending; ~0.187 @ 1000)" (§8.3).
- **The two preserved red floor aborts:** "read red twice: **0.862 @ 300** and (step moved to 1000) **0.884 @ 1000**; both abort records kept verbatim; **no threshold, fixture or measurement was adjusted anywhere**" (§11.22; detail §12.1–§12.2: token_acc 0.862 < 0.90 at step 300 and 0.884 < 0.90 at step 1000; owner-ratified guard relocation with a ratification block in `run-restart-record.json`).
- **Post-hoc end-probe (500 rows):** "**token_acc 0.8940** (0.006 below the stack's 0.90 default — per the ratified relocation this is evidence, not a gate), command 0.9508, chat 0.8696, json_start 1.000, scored 500/500, prefix_mismatch 0" (§12.3).
- **Model artifact:** "**1,107,408,736 B**, sha256 `e05cc8a266198336f508cef2f6d2a8887b3db1eee3f4a4159cdeb2ab3df59d71`" (§13).
- **Candidate replies:** "**23:42:39 (exit 0)**: 500/500 turns, no_json 0, raw_fallback 0, wall 1,653.2 s" (§14.2).

**What has NOT landed at authoring — stated plainly:** the design's chat gates (≥0.98 / ≥0.98 / ≥4/5) are **not measured** — the full-gate report is the harness that carries them and it is in flight. Its recorded identity and advance-stated expectation, verbatim (run notes §14.5): report #1 launched "2026-10-16 **23:43:22**" with "`--preds-out eval/preds-qwen-s43-chat-v17.jsonl`" and "`--gate-report eval/gate-report-cnr-v17.jsonl`"; "Expected verdict, stated in advance: **exit 1 — hard gates measured; chat gates `not_measured` on the 402-blocked judge (§14.4); §10 latency `not_measured` pending the Anzaan DV session** — the report is still written (only refusals write nothing). Verdict recorded here when it lands." The file `eval/gate-report-cnr-v17.jsonl` does not exist locally as of authoring; no verdict is claimed for it in this statement.

**The judge-key money gate** (run notes §14.4, verbatim): a deliberate 1-call smoke "returned **HTTP 402 "prepayment credits are depleted"** — the only judge key on the box. Recorded as an owner money gate (~<$1 of flash-lite)." The harness runs honestly without it (chat gates land as `not_measured`), and the funded re-run pays its 500 judge calls fresh via the recorded preds replay seam (§14.4).

**The swap does NOT ship** — the design's own rule is met by inaction, not by loosening: the P1 catalog entry `intentQwenS43ChatV17` "is PRESENT BUT NOT PROMOTED" (`specs/T-184-notes.md`; same in T-186 §10 and T-187 §7.6); the shipped promotion record resolves `.blocked(.gateReportMissing)` because "`gateReportPath`/`gateReportSHA256`/`gates` are empty ON PURPOSE (no full-gate report exists)" (T-184 §1); `defaultBrainModelID` is untouched (still `intentQwenS43`); and the entry's 160-byte arithmetic hazard (it would otherwise win the automatic ladder's "largest fitting" step) is blocked by the eligibility filter, pinned green (T-184 §1; T-186 §9(e)).

**The 1.7B quality on the reference tier** (the on-device half of this leg): **BLOCKED** — DV-1 (local chat quality from the shipped tier) has no session (T-187 §7.3), and the v17 latency-gate measurement is "**Open — pending the session**" (T-187 §7.6). Honest reading of this leg: the run and its candidate exist with every value above standing as recorded; the design's gate thresholds have not been measured at authoring; no threshold is reported green; and because the swap has not shipped, P0 is unaffected — exactly the design's row.

## 5. 4B tier admission — RE-OPENED 2026-10-17 (owner; executing — verdict pending)

The design's §20 row reads — verdict: "LIKELY NOT ADMISSIBLE on the reference 6 GB tier"; statement: "The 4B latency failure is documented at default; admission requires the latency envelope AND memory behavior on that tier. Until a tier holds both, the 4B variant exists only as a gated, non-default catalog candidate (P2, COULD). Recorded".

Executed: **OWNER-DESCOPED** — "Status: DESCoped by the owner — not implemented in this run" (`specs/CNR-p2-4b-tier-notes.md`, citing the owner decision of 2026-10-15 and amendment 6). No admission verdict was produced in this run; per that record "no measured outcome is claimed here; the leg's feasibility evidence (including the 4B-tier jetsam/latency admission question, plan risk 6) is owned by the successor initiative". The design's recorded likelihood is not restated as a measurement either way.

**Amendment — dated annotation (2026-10-17).** T-190 was **re-opened by the owner** (relayed via the main session, recorded with owner provenance; umbrella record `specs/plan-tasks/amendments/amendment-7-t190-4b-reopened-2026-10-17.md` — "the owner wants the 4B chat variant for the iPhone 17 Pro Max") and is **executing inside this run**, in parallel with the in-flight v17 full-gate decode. Execution record: `specs/CNR-p2-4b-tier-notes.md` ("RE-OPENED" section) — base `checkpoints/qwen4b-s43-merged` (the 4B seed-43 lineage merged checkpoint, the structural mirror of the 1.7B's `qwen-s43-merged`, with the recorded alternative and rationale), unchanged v17 corpus (17,235/500 verified) and pinned recipe (trainer-printed ~3,234 steps; floor guard disabled per the ratified restart-#2 discipline), run id `cnr-v17-4b-20261017-0437`, launched 2026-10-17T04:37 box-local, chain train → end-of-run probe → Q4_K_M export + sha, ETA ~9-10 h. The descope paragraph above stands as the record of 2026-10-15..17. **No measured outcome is claimed here**: no gate report, no export identity, no admission measurement exists yet; T-190's verdict slot above remains unfilled until its own evidence lands. T-188/T-189/T-191 remain owner-descoped (amendments 6 and 7).

## 6. Romanized chat (P2) — OWNER-DESCOPED (T-189)

The design's §20 row reads — verdict: "UNPROVEN"; statement: "Ships only if the full harness stays green; otherwise reported as not delivered (FR-CNR-027)". Design §11.7 adds: "Romanized chat: additive; Devanagari behavior and all gates unchanged; if unreliable, it is reported not-delivered (FR-CNR-024 honesty)".

Executed: **OWNER-DESCOPED** — "not implemented in this run" (`specs/CNR-p2-romanized-notes.md`, owner decision 2026-10-15; amendment 6). The descope record is the explicit not-delivered form FR-CNR-024/027 asks for; the romanized unavailable-degradation this statement must carry is exactly that: romanized input handling is not in the shipped feature, and the descope, not a silent gap, is why.

## 7. Chat-classified surface scope — DELIVERED AS THE STATED BOUND

The design's §20 row (verbatim): "The P0 decode/persona/cloud-chat improvements act on turns `ChatIntentClassifier` routes as chat (the conservative closed small-talk table); content-bearing conversational turns keep the command decode by design (FR-CNR-004), improving via the P1 model's register. The table is not widened".

Executed: **DELIVERED AS THE STATED BOUND** — no classifier file appears in the CNR P0 or P1 change lists, and the untouched classifier ran green as the witness (`ChatIntentClassifierTests` **13/0**, T-186 §2 Run E); assumption A1 records the table and its semantics staying as shipped. The register improvement named in the design's row for content-bearing turns rides the P1 model, which is not served (v17 present-not-promoted, §4) — so that half is not currently in effect on the shipped default, and this statement says so rather than implying it.

## 8. DPO (P2, FR-CNR-026) — OWNER-DESCOPED (T-188)

Design §11.7: "DPO: preference pairs from the SAME judge rubric; result is a NEW catalog candidate behind the full harness (never an in-place mutation); starts only after P1's swap is live and DV has run; descopable only by the owner explicitly (FR-CNR-026)".

Executed: **OWNER-DESCOPED** — "not implemented in this run"; "no measured outcome is claimed here; the leg's feasibility evidence is owned by the successor initiative" (`specs/CNR-p2-dpo-notes.md`). Amendment 6 records that neither precondition (P1 swap live; DV run) was reached, so the descope timing is coherent — not a silent drop.

## 9. Consent-based real transcripts (P2, FR-CNR-029) — OWNER-DESCOPED (T-191)

Design §11.7: "Real transcripts: explicit informed revocable consent before collection (UAT/test-device sessions first), withdrawal removes future mixes, classified as own data in the manifest, no silent harvest, gated as a new candidate (FR-CNR-029)".

Executed: **OWNER-DESCOPED** — "not implemented in this run"; and the recorded accounting is explicit: "The data-provenance constraint that motivated this leg (no unconsented user content reaching mixes; plan risk 3 / advisory mapping) is unchanged and remains covered in this run by T-180's ship-mix manifest enforcement" (`specs/CNR-p2-transcripts-notes.md`).

## 10. Device validation (T-187, FR-CNR-025) — BLOCKED, all six items

The completion gate (FR-CNR-025: "The feature is not complete until the DV protocol has been executed on the reference device (Anzaan) and its results are recorded"). Executed state, verbatim from the DV record (T-187, commit `aaf0143c`): "no Anzaan session has run. … **Every DV item below is recorded BLOCKED — not PASS — with the prerequisite that must clear it**"; "The feature's completion status is therefore explicitly **DEVICE-VALIDATION-OUTSTANDING**". §7.3 records DV-1 through DV-6 each BLOCKED with its named dependency (step zero S0-1…S0-4 "Not available"; the item-level prerequisites unmet); §8: "Only PASS closes an item. FAIL and BLOCKED both hold the gate"; the headline blockquote adds: "Nothing in this file is a device observation; no simulator, unit-test, acceptance-sweep (§7.5's build-side evidence) or training-box gate result fills any row."

The build-side half that IS done: the release gate — "`RELEASE_GATE_EXIT=0`" over the feature roots and event types (T-186 §8; re-executed in T-187 §7.5 as part of the DV record). The device console check remains "**Open — pending the session**" (T-187 §7.5). No device-level claim is made anywhere in this statement.

## 11. Latency (NFR-CNR-002) — NOT MEASURED

NFR-CNR-002's envelope: "the end-of-utterance to start-of-reply interval has **p50 within 5–8 s** on the reference tier, 'measured over the DV session (FR-CNR-025)'" (T-187 §1, quoting the requirement). Executed state: **NOT MEASURED** — recorded as unmeasured in each place it is owed: the run notes' advance-stated gate expectation ("§10 latency `not_measured` pending the Anzaan DV session", §14.5); the DV record's appendix ("v17 latency-gate measurement — **Open — pending the session**", T-187 §7.6); the acceptance record ("the latency leg is unmeasured without an Anzaan device session", T-186 §10). The harness-side regression latency row (design §11.4's list) rides the same un-landed full-gate report (§4). No latency value is claimed anywhere in this statement.

---

## Delivered state for the sign-off

- **P0: DELIVERED AND ACCEPTING.** "the **P0 runtime slice ACCEPTS**" (T-186 headline); sweep "**716 tests over 30 classes — 711 passed, 4 failed in 3 cases, 1 skipped**" (T-186 §2), the 4 red cases being the one CNR-suite flake (§3 there) and the 3 pre-existing baseline cases (files untouched — not attributable to any CNR unit, §4 there); release gate exit 0 (T-186 §8); P0 tip `5169c040`, "already merged to master via PR #224 (MERGED)" (T-186). The full iOS bundle was NOT run — the scoped sweep substitutes per the owner policy in force, recorded rather than glossed (T-186 §5).
- **P1: PRESENT BUT NOT PROMOTED.** The catalog entry `intentQwenS43ChatV17` ships blocked on `.gateReportMissing`; no serving path resolves to it; `defaultBrainModelID` untouched (T-184; T-186 §10). The candidate's recorded training evidence exists (§4 above); the gate report that would promote it has not landed.
- **Device validation: DEVICE-VALIDATION-OUTSTANDING.** All six DV items BLOCKED; no Anzaan session (§10).
- **P2: four legs OWNER-DESCOPED** (2026-10-15; amendment 6), each with its explicit record (§§5, 6, 8, 9) — **with one dated exception: T-190 re-opened by the owner 2026-10-17 and executing (amendment 7; §5's annotation).**

## Open items (each explicit — nothing left to infer)

1. **An Anzaan DV session executing DV-1…DV-6** (T-187; the FR-CNR-025 completion gate). Until PASS per item, completion is withheld; the record's §7.4 owner actions (device, build identity, fresh-install route, listening panel, failure resolution, judge key, copy confirmation) are open.
2. **A funded chat-judge API key** (owner money gate; HTTP 402 recorded, run notes §14.4) — closes the chat-gates leg of the full-gate report.
3. **Full-gate report #1 landing** (`eval/gate-report-cnr-v17.jsonl`; in flight on the training box at authoring — recorded launch identity and ETA in run notes §14.5) and, after funding, report #2 (the recorded-preds replay plus the fresh 500 judge calls).
4. **v17 promotion** — the T-184 reference-data edit (`gateReportPath`/`gateReportSHA256`/`gates` filled from a green report); blocked today.
5. **Latency** — unmeasured in both forms (§11).
6. **The T-186 §3 flake** — `CloudChatConsentGateTests` concurrency-assertion red, green 3/3 re-runs; genuine finding for T-172's owner; not absorbed into the pre-existing baseline, not fixed here.
7. **Three pre-existing baseline red cases** (stale `intentQwen4BSlotCanon` pins in `MultipartDownloadTests`/`InterpreterAvailabilityTests`) — named and recorded, not fixed (T-186 §4).
8. **Publication of the v17 artifact** (the entry's `downloadURL` is an RFC 2606 `.invalid` placeholder until the asset publishes) and the `framing_check.py` measurement replacing the inherited framing row (T-184 open items).
9. **Integration/rebase onto master** (81 commits ahead of the branch merge-base) — a later T2 step (T-186 §10).
10. **The four P2 legs** — T-188/T-189/T-191 remain owned by the successor initiative (amendment 6); **T-190 was re-opened by the owner 2026-10-17 and is executing in this run (amendment 7; §5)** — its remaining open items are its own definition of done: the full-harness report over the candidate, the catalog entry (lands with the real sha256/size), the tier admission measurement (device-side, iPhone 17 Pro Max), and the verdict notes; this statement's obligation to all four legs is discharged by §§5, 6, 8, 9.

## The honesty statement (for the final-sign-off record)

> Every leg the design's §20 feasibility record names is accounted for above, with the recorded values and pointers: chat sampling (delivered at the implementation layer; the on-device reproducibility observation is blocked with T-187), the GBNF/command-schema play and command determinism (untouched, pinned green), guard coverage (a lexicon-bounded floor, never a grammar proof, script-classification only), cloud routing (delivered; the recorded OD-12 transcription exception on a Gemini speech stack is stated, not hidden), and the 1.7B chat-quality leg, whose run and candidate exist but whose design-gate verdicts have NOT landed — the full-gate report is in flight and the chat-judge leg sits behind the owner's money gate; nothing is reported green that was not measured, both red floor readings stand as recorded, and no swap has shipped (v17 present but not promoted). The four P2 legs were descoped by the owner on 2026-10-15 and are reported as such — **amendment (2026-10-17): the owner re-opened T-190 (the 4B tier leg); it is executing in this run and no measured outcome is claimed for it yet (see §5's dated annotation; T-188/T-189/T-191 remain descoped).** Device validation (DV-1…DV-6, T-187) is BLOCKED — no Anzaan session — and device-validation-outstanding holds the feature's completion; the latency leg is unmeasured. P0 accepts on the recorded sweep; the open items above are the complete set this statement knows of.

## How this statement is checked

- Every value above is quoted from its recorded source, with the file and section named at the claim; no value is re-derived, rounded toward a threshold, or drawn from a favourable subset. Red readings (the two floor aborts, the §3 flake, the pre-existing reds, every BLOCKED item) are stated as recorded.
- Interpretation appears only where the design defines a threshold or bound (its §20 verdicts, §11.4's gates, §5.4's non-claim, NFR-CNR-002's envelope); elsewhere the records' own wording is used.
- Cross-references the advisory security pass reads alongside this statement: the provenance manifest sha (full, above), the gate report identity (above; explicitly not-yet-landed), and the DV record version (`aaf0143c`).
