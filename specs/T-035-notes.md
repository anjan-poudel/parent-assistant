# T-035 — Joint Intent+Slot Encoder Design + L2 §4.2 Amendment: implementation notes

- **Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-08-nepali-intent-encoder/T-035-joint-intent-slot-encoder-design.md`
- **Branch:** `worktree-t035-encoder-design` (worktree `.claude/worktrees/t035-encoder-design`, base `840bcd7`) — not merged, not pushed
- **Deliverable type:** design/documentation only — no training run, no model download, no build, no code change
- **Successor tasks already in flight (not by this task):** T-036 (training + distillation), T-037 (iOS/Android integration), T-038 (eval + device verification)

## Artifacts committed

| Path | What it is |
|---|---|
| `docs/superpowers/specs/2026-09-13-joint-intent-slot-encoder-design.md` | The design: architecture/heads/loss, distillation, calibration, runtime format, field-by-field mapping, band reconciliation, failure modes, SetFit scoping, determinism, divergences, ungroundable items, open risks |
| `docs/superpowers/specs/2026-09-13-l2-4.2-amendment.md` | The L2 §4.2 **replacement text**, standalone and reviewable, with a reviewer change summary |
| `tools/train-intent/encoder_contract.yaml` | Machine-readable contract (`schema: encoder-contract/v1`) for T-036/T-038: model, heads, loss, slot field map, `app` projection, calibration, bands, runtime, ladder, failure modes, gates, per-task hand-offs |
| `specs/T-035-notes.md` | This file |

Layout mirrors the completed T-034 work (`docs/superpowers/specs/<doc>.md` +
`tools/train-intent/<contract>.yaml` + `specs/T-*-notes.md`); the T-034 worktree was
read-only and was not modified.

`.ai-sdd/outputs/design-l2.md` was **read and not edited** — the amendment is delivered
as reviewable text, and applying it to the L2 artifact is an engine-owned step. No
`.ai-sdd/` state was touched, no `complete-task`, no merge, no push, no rebase.

## Decisions

1. **The design is the T-033 spike, widened — not a new architecture.** Shared encoder
   body, intent head on the pooled `[CLS]`, BIO slot head over all tokens — exactly
   `bakeoff_encoder.py:91-104`. The two deltas are the 13-tag slot head (the spike had
   5) and slicing the transcript for span surfaces instead of re-joining words.
2. **Spans are verbatim, resolution stays in code.** No contact id, phone number, URL or
   resolved time can leave the encoder. The only non-verbatim value is `requestedApp`'s
   canonical token, drawn from a closed vocabulary that names no target.
3. **The `app` span splits into `requestedApp` + `callType` by a code table.** This is
   the decision that reconciles the two acceptance scenarios (see "Conflicts resolved"
   #1). The matcher reuses the shipped vocabularies rather than inventing one.
4. **Contact clitic-trim is a runtime mapping rule, not a data-contract change.** T-034's
   spans stay surface-exact and gate-scored; `InterpretedCommand.contact` gets the
   trimmed form so eval parity with the golden corpus's resolver-ready values is
   possible at all (T-033's contact F1 was 0.333 for exactly this reason).
5. **Calibration is temperature scaling, shipped as a scalar in `meta.json`.** The graph
   keeps emitting raw logits (as the harness already assumes, `eval_golden.py:213-216`),
   so `T` is reviewable and diffable rather than compiled into the artifact. It is
   argmax-preserving, which is what lets it be fitted *after* the emergency class
   weighting without endangering the recall gate.
6. **`w_emergency` is a class weight in the loss, never a runtime threshold.** The hard
   constraint forbids a new threshold bypassing `bandChecked`; recall-first is achieved
   in training, and the band policy is untouched.
7. **The 0.10 calibration tolerance is pinned to a concrete rule** (ten fixed buckets,
   a 30-sample floor, pool-upward-and-report). "±10%" alone is ambiguous enough to be
   unverifiable, which would have made the gate decorative.
8. **The encoder installs as `LocalBrainChain.preferred`.** That placement makes
   "artifact not installed" fail soft for free via the existing `standIn` logic, and
   requires zero changes to `IntentRouter.swift` or the keyword net.
9. **Stage-2 distillation is explicitly conditional.** Its teacher distribution does not
   exist in the repo today; the design says so, specifies the fallback (stage 1 hard
   labels are sufficient to ship), and for the Gemini source states the soft-target
   *construction* rather than implying measured probabilities.
10. **Determinism is claimed by construction, not by policy.** The encoder has no
    sampler, so `OnDeviceSampling` (temp 0, seed `20_260_907`) governs the LLM
    interpreters only — the design does not claim to "use temperature 0", it claims
    there is nothing to sample.

## Conflicts resolved

1. **`requestedApp` nil vs `requestedApp` "whatsapp".** Scenario 1 requires `nil` for
   "maiya lai phone gara"; scenario 3 requires `"whatsapp"` for "वाट्सएपमा कल गर" "as
   explicitly named by the user"; T-034's `corrections_overrides` maps the `app` span
   "फोन" → `requestedApp: phone`. Resolution: named apps → `requestedApp`; generic
   method words → `callType`, `requestedApp` nil. The shipped schema's own wording
   ("an app the user explicitly named (facetime/whatsapp/messenger/viber), else null",
   `LlamaCommandInterpreter.swift:106-111`) is the tie-breaker.
   **Follow-on consequence:** with `requestedApp == nil` and `callType == "voice"`,
   `MethodResolver.explicitMethod` returns `nil` (`MethodResolver.swift:88-90`), so the
   "होइन, फोन नै गर" correction needs a T-037 decision — recorded as **I-1** with both
   options named, deliberately not picked here.
2. **Surface-exact spans vs "contact is the span छोरा".** T-034 pins affix-merged
   surfaces (डाक्टरलाई); the scenario wants छोरा out of छोरालाई. Resolution: both — spans
   stay surface-exact for the gates, the *slot* is clitic-trimmed by code. `contact`
   only; trimming inside "प्रेसरको औषधि" would corrupt a medication name.
3. **Emergency mid-band gap (a real shipped-behaviour finding).** `ConfirmationTier`
   returns `.neverGated` for `emergency`/`ackMed` (`ConfirmationTier.swift:19-20`), but
   `bandChecked`'s rephrase branch tests `== .confirm` (`IntentRouter.swift:320`), so a
   0.4–0.7 emergency is dropped for escalation rather than confirmed. The design does
   **not** fix this (hard constraint: no router edits, no new threshold) — it names it
   as open risk **R-1** and shows why it is non-blocking in practice (`routeSafetyNet`
   runs first at `CommandRouter.swift:651-653`).
4. **The spike's 5-tag slot head vs the design's 13.** Named as a deliberate widening,
   not glossed: T-034 defines six span labels, the spike only ever had contact and time.
5. **Word-join vs transcript-slice span decoding.** T-034's rule ("surface comes from
   the transcript") is honoured with a different mechanism (`is_split_into_words` +
   `word_ids`, matching the spike and the harness) instead of `return_offsets_mapping`.
   This removes the `▁`-leak risk by never touching decoded token strings.
6. **Slot loss masking retired.** T-033 masked ~35% of slot rows; T-034's alignability
   invariant removes the need. Recorded because that masking is the likeliest
   explanation for T-033's 0.333 contact F1.

## Verification performed (no build, no training)

- YAML parses under PyYAML; `schema: encoder-contract/v1` present.
- Contract ↔ `annotation_rules.yaml` cross-check (programmatic, PyYAML): the ordered
  `heads.intent.labels` (12) and `heads.slot.tags` (13) in `encoder_contract.yaml` are
  element-wise identical, in order, to T-034's `taxonomy.labels` and `spans.bio.tags`;
  `heads.intent.shape[1] == len(taxonomy.labels)` and
  `heads.slot.shape[1] == len(spans.bio.tags)` assert at parse time. No label in the
  contract is absent from T-034, and T-034's `excluded_runtime_actions: [plugin]` is
  honoured (the contract's intent list has no `plugin`).
- The design doc's band table was re-read against `IntentRouter.swift:56-58/316-330` and
  `ConfirmationTier.swift:17-34` line by line after writing.
- The amendment's "before" column quotes `.ai-sdd/outputs/design-l2.md:373-381` verbatim
  from a fresh read, and the file's mtime/status confirms it was not written to.
- Grep for the withdrawn vocabulary (`CALL_CONTACT`, `QUERY_CALENDAR`, `SET_REMINDER`,
  `GENERAL_CONVERSATION`): every surviving occurrence is a **quotation** — the
  amendment's "before" column and its change summary (both explicitly labelled as
  withdrawn/replaced), the proposal quote in design §13, and this notes file. No new
  document uses one as a live label.
- No 40+ char hex run anywhere in the four files (secret-scanner convention); revisions
  and digests use 8–12 char prefixes.

No test suite is added: this is a design deliverable, no repository code is modified,
and coverage/percentage rules do not apply to documentation.

## Not grounded in code (recorded rather than papered over)

1. **`MedicationResolver` does not exist.** Only spec §6.4 and task/plan text mention it.
   Shipped medication handling is `CommandRouter.swift:2200` (span becomes the reminder
   *title*) plus `MedicationScheduler`. The encoder still emits a medication span, which
   is the safe output either way.
2. **`ModelStore.installCoreMLEncoder(fromZip:for:)` is Whisper-shaped.** T-033's "the
   zip shape is already accepted" is true at the container level only — the destination
   is derived from the Whisper ggml filename and the only non-nil
   `coreMLEncoderBundledName` is `ggml-small-encoder`. A real intent-encoder install
   path is T-037.
3. **Android packaging/loading is new code** (T-033 states ONNX Runtime Mobile is not
   wired anywhere in the repo).
4. **Device-class latency is UNMEASURED** — T-033's figures are desktop proxies.
5. **Δ vs `GeminiCommandInterpreter` is UNMEASURED** — no API key in the experiment
   environment.
6. **No script reads teacher per-class logprobs**, so the preferred teacher distribution
   needs new T-036 tooling; the Gemini soft target is a construction from a scalar.
7. **The calibration gate is UNMEASURABLE today** — 20 golden rows cannot fill ten
   buckets; the T-036 corpus floor (8 000 rows) is what makes it meaningful.

## Open risks

| # | Risk | Owner |
|---|---|---|
| R-1 | Mid-band `emergency`/`ackMed` do not take `bandChecked`'s `.confirm` branch (tier is `.neverGated`) | design owner / T-037 |
| R-2 | `MethodResolver` cannot see a generic voice-method amendment (`requestedApp=nil`, `callType="voice"`) — item I-1 | T-037 |
| R-3 | Encoder-as-`preferred` abstention currently escalates without consulting the incumbent LLM — item I-2 | T-037 |
| R-4 | `ack_med`, `create_calendar_event`, `suggest_video` have zero seed templates | T-036 |
| R-5 | Emergency class weighting competes with the calibration gate (resolution order fixed in design §3.4) | T-036 |
| R-6 | Slot F1 gate (≥0.90) is far above T-033's measured 0.333; unproven until training | T-036 / T-038 |
| R-7 | A retrained head is a new graph; int8 decision-preservation must be re-verified (this is what killed C2) | T-038 |

## Open questions for the reviewer

1. **I-1**: does the correction family emit `requestedApp="phone"`, or does
   `explicitMethod` learn to read `callType=="voice"`? (Design names both, picks
   neither; the second also fixes the non-correction case for contacts whose default
   method is WhatsApp.)
2. **I-2**: is an abstention-only fall-through to the incumbent LLM in `LocalBrainChain`
   acceptable for T-037? Without it the FR-007 long tail escalates to the cloud or
   re-prompts, which is a behaviour delta from today.
3. **R-1**: should the L2 amendment be extended to state the emergency dispatch
   behaviour, or is that a router change outside this task? (Left out deliberately, to
   keep the amendment free of a safety-policy claim this task cannot verify.)
4. **Stage 2**: if no teacher distribution can be produced by T-036, is stage-1
   hard-label training accepted as the shipped model? The design says yes, with the
   rationale recorded.

## Not done

- **Lead-engineer review** (DoD item) is not claimed by this task; the branch is left
  for integration and review.
- Nothing is executed by design: no model downloaded, no dataset built, no training, no
  on-device run. Every measured figure cited is T-033's or T-034's, attributed as such.
- The four T-036/T-037/T-038 hand-off lists in `encoder_contract.yaml:consumers` are
  pointers, not implementations.
