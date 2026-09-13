# Task Breakdown — Elderly AI Assistant

## Summary
- Task groups: 10 (Jira Epics)
- Total tasks: 49 parent tasks (60 task IDs: T-001–T-060)
- Subtasks: 26 subtasks (platform splits)
- Estimated effort: 39–64 days (full parallel — the TG-08 ML track is the longest chain; TG-09, TG-10 and T-046–T-050 are iOS-/ML-side work inside the existing streams) / 161–266 days (sequential, TG-10's ~28–45 days included)
- Critical path: T-033 → T-034 → T-035 → T-036 → T-037 → T-038 (TG-08; conditional on the T-033 GO/NO-GO and gated at entry by T-009 and T-021)
- TG-10 (Continuous Learning Loop, T-052–T-060) runs **off** the critical path: its design and privacy half (T-052/T-053, then T-054/T-055) is independent of the encoder chain, and T-058 consumes the T-038 harness as it exists rather than re-opening it. The group adds no task to T-033 → T-034 → T-035 → T-036 → T-037 → T-038 and does not extend that chain.
- Rework stream: T-049, T-050 (+3–6 days) — the B1/B2 remediation tasks raised by the `security-test` SECURITY-NO_GO (`specs/security-test.md`). Both are iOS-side and HIGH risk, neither extends the critical path, and both are prerequisites in substance (not in the dependency graph) for `final-sign-off`, whose gate the failed security test blocks.

## Contents
- [tasks/index.md](tasks/index.md) — all task groups

## Critical path

**TG-08 chain (longest chain, conditional).** The encoder track runs:

```
T-033 → T-034 → T-035 → T-036 → T-037-a/b → T-038
```

`T-033` is the GO/NO-GO gate (licence/access, tokenizer fertility, on-device export, golden-corpus bake-off); a NO-GO closes the group in 6–10 days. Entry into the chain is gated by two existing tasks: `T-009` (the bundled Whisper used for the STT-noise round-trip) for `T-034`, and `T-021` (the intent classifier being re-scoped) for `T-035`. Sequential effort on this chain: ~34–55 days; from project start on the full-parallel plan, ~39–64 days.

**TG-09 chain (iOS-side, parallel to the app streams):**

```
T-039 → T-040 → T-041 → T-044
```

with `T-042` and `T-043` running from `T-040` in parallel. Sequential effort on the chain: ~16–25 days. `T-039` needs no predecessor; only its encoder branch waits on the `T-033` GO, and if `T-033` is NO-GO the chain continues on the LLaMA/cloud/deterministic rows alone. TG-09 never extends the TG-08 chain.

**MVP chain (unchanged, now third-longest):**

```
T-001 → T-002-a → T-018-a → T-020 → T-021 → T-022-a
```

Sequential effort on this chain: ~27 days iOS.

**Safety-critical path (independent of LLM — should be delivered first):**
```
T-001 → T-002-a → T-024-a → T-026-a
```
Sequential effort: ~12 days iOS.

**Full parallelisation opportunity:** iOS and Android streams run simultaneously across all task groups. TG-06 (Safety-Critical Services) can be developed fully in parallel with TG-03 (On-Device AI) and TG-04 (Authentication). TG-08 runs as a separate ML workstream on the training box, in parallel with the app streams once its T-009/T-021 entry gates land. TG-09 runs as an iOS workstream once TG-08's interface is stable enough that the plugin routing decision can name it; it does not block or extend TG-08.

## Key risks

1. **HIGH — PAD/liveness detection BLOCKER (T-014-a, T-014-b):** THREAT-001 from security-design-review.md requires a PAD design note to be reviewed and approved before either VoiceBiometricAuth subtask can start. This is a CI gate.
2. **HIGH — LLM OOM on low-end Android (T-018-b):** Runtime RAM check required; decline load if < 2.5 GB available with user-visible notice.
3. **HIGH — Emergency silent TTS failure (T-012-a, T-012-b, T-026-a, T-026-b):** Platform-native TTS fallback required; blocking CI test failure.
4. **HIGH — Safety-critical services not isolated from LLM (T-024–T-028):** Build target isolation enforced; CI build test verifies no LLM import.
5. **HIGH — Signal Protocol prekey exhaustion (T-030):** Pre-generate 100 prekeys; auto-refresh when supply < 5.
6. **MEDIUM — iOS BGTaskScheduler budget exceeded (T-028-a):** Local notifications as primary; BGTask supplemental only.
7. **MEDIUM — openWakeWord model size in app binary (T-005-a, T-005-b):** Download-on-first-launch with fallback to manual activation.
8. **HIGH — Candidate model access and licence unverified (T-033):** `ai4bharat/IndicBERT-v3-270M` is gated on Hugging Face (contact-sharing agreement) and its licence is only indirectly indicated as MIT; `jhu-clsp/mmBERT-small`'s terms and the MASSIVE MiniLM checkpoint's provenance must be verified before any base is selected. No training on an unverified base — T-033 records licence/access evidence per candidate and marks unverifiable candidates NOT USABLE.
9. **HIGH — On-device export feasibility unproven (T-033, T-037-a, T-037-b):** ModernBERT-family encoders (RoPE, GLU, Flash Attention 2) have no proven CoreML / ONNX Runtime Mobile / LiteRT export path; this is the single largest technical risk, larger than headline accuracy. T-033's export spike is the kill gate; the fallback is the incumbent fine-tuned LLM local brain with no new artifact.
10. **HIGH — Taxonomy reconciliation is safety-critical (T-034):** the proposal's MASSIVE-derived intent list omits `emergency`, `abstain`, `ack_med`, `music` and `guide` — all first-class in schema v2 (`build_dataset.py` VALID_ACTIONS, spec §9.1). Training on a MASSIVE-derived taxonomy would silently drop the emergency intent; T-034 reconciles onto the existing taxonomy, never the reverse.
11. **HIGH — Slot resolution conflict (T-034, T-035):** the proposal's resolved-value output style ("time = tomorrow 09:00") conflicts with the code-disposes principle — `ContactResolver` / `MethodResolver` / `NepaliTimeParser` / `MedicationResolver` resolve slots in code inside confirm-before-execute. The encoder must emit token spans (BIO) for slot candidates only; the design maps spans onto `InterpretedCommand` as spoken.
12. **HIGH — Tokenizer fertility and latency budget (T-033, T-038):** both leading candidates use ~256K Gemma-family vocabularies; romanised Nepali and Nepali-English code-switching (15% of the mixture, spec §9.2) must be measured for tokens-per-word before any latency claim. Gate: interpret p50 ≤ 1.0 s / p95 ≤ 2.0 s on the oldest supported device.
13. **HIGH — Regression vs the Gemini baseline (T-038):** the spec §10 gate "no worse than −3 points on closed intents vs `GeminiCommandInterpreter`" exists in config.yaml (`max_gap_vs_gemini: 0.03`) but is not yet enforced by `eval_golden.py`; so are abstention precision ≥ 90% and calibration ±10 points. T-038 wires all three, with failing fixtures proving each can fail the run.
14. **HIGH — Emergency recall hard gate (T-036, T-038):** corpus recall must stay at 1.00 and adversarial near-miss recall at ≥ 0.98; a single corpus miss fails the run and blocks artifact publication and the default-brain switch. The keyword net remains the constitution-mandated backstop before any model.
15. **MEDIUM — SetFit cannot do token-level slot filling (T-035):** a sentence-embedding + linear head cannot produce slot spans; it is at most a slotless fallback and the design must say so explicitly.
16. **MEDIUM — Accuracy claims in the proposal are unverified and non-Nepali (T-033):** 82.34% (MASSIVE MiniLM), 91.1% (SetFit) and 97.3% (NyayaBench English) are not Nepali numbers and are not comparable to this project's §10 gates. Each candidate is measured on the project's own golden corpus with the existing harness; no such number is carried into the design as evidence.
17. **HIGH — Plugin recognition is cloud-only today (T-039, T-041):** plugin fragments are composed only by `GeminiCommandInterpreter` (GeminiCommandInterpreter.swift:72-75); `LlamaCommandInterpreter` deliberately omits them (LlamaCommandInterpreter.swift:319-327, 449-453) and its GBNF grammar (189-193) and JSON schema (219-221) exclude the value "plugin"; `LocalIntentInterpreter` builds the prompt without plugins (LocalIntentInterpreter.swift:106) and its schema (303-312) excludes it too. On the on-device stack a plugin utterance can never be emitted as `.plugin` — a live architectural defect, independent of TG-08.
18. **HIGH — Plugin doc contradicts the TG-08 encoder proposal (T-039, T-040):** `docs/plugin-architecture.md` line 43 ("the ONLY core case, added once, forever") and its recognition flow presume brain-independent recognition, while the fixed-class encoder in `docs/architecture/nepali-intent-recognition-model.md` cannot ingest runtime fragments or emit arbitrary namespaced action names. T-039/T-040 must resolve the contradiction; when the encoder branch is chosen while T-033 is GO, the taxonomy change is cross-referenced against TG-08 T-035 and T-036, never silently diverged.
19. **HIGH — `PluginCommand.transcript` contract broken (T-042):** documented as the sanitised transcript (AssistantPlugin.swift:65-66), normal dispatch passes `""` (CommandRouter.swift:2302-2307), the guide-deferral path passes the raw pending transcript (CommandRouter.swift:2345-2348), and the router performs no sanitisation at all (only the three interpreters do: LlamaCommandInterpreter.swift:444, LocalIntentInterpreter.swift:101, GeminiCommandInterpreter.swift:56). Consequence: `ApplianceHelperPlugin.extractQuestion`'s transcript fallback (ApplianceHelperPlugin.swift:88-95) can never fire on normal dispatch.
20. **HIGH — Plugin confirmation governance hole (T-043):** plugin dispatch is `ConfirmationTier.free` with policy delegated to the plugin (ConfirmationTier.swift:25-32); `RoutinePlugin` persists the entry before speaking a post-hoc confirmation (RoutinePlugin.swift:125-149) and `YouTubePlugin` confirms after opening the external app (YouTubePlugin.swift:10-16). A newly added plugin can therefore perform a side-effecting action with no core confirm-before-execute gate.
21. **MEDIUM — `docs/plugin-architecture.md` is wrong on load-bearing facts (T-042, T-044):** registration is claimed in `AppCoordinator.init` (doc line 10) but is a lazy first-use factory (AppCoordinator.swift:1150-1156, factory at 1275-1285); `ApplianceHelperPlugin` is described as a "not ready" skeleton (doc lines 90-93) while shipping the live camera/vision flow (ApplianceHelperPlugin.swift:69-106; tests at ApplianceHelperPluginTests.swift:73, 88); the localization key `plugin.applianceHelper.notReady` (Localizable.xcstrings:7687) is dead (no Swift usage); the reference list names 2 of the 4 registered plugins.
22. **MEDIUM — "The ONLY core case" is not strictly true, and a second recognition path exists (T-040, T-041):** core hard-codes `"appliance.identify"` (CommandRouter.swift:2341) and `"nepali_calendar.query"` (AppCoordinator.swift:5349), and YouTube requests are also reachable by the deterministic marker stage (CommandRouter.swift:888) executing through `YouTubeTool` (CommandRouter.swift:1873-1929), bypassing `YouTubePlugin`. T-040 records a disposition per case; T-042 corrects the wording; T-041 keeps the deterministic stage.
23. **MEDIUM — Compile-time-only and iOS-only plugin reality is undocumented (T-040, T-044):** registration is a fixed compile-time list (PluginRegistry.swift:7-9), no dynamic-loading API exists in the app sources, and the Android tree contains no plugin code (only Gradle `plugins` blocks match a search). Written down as contract in T-040 and pinned by T-044.
24. **MEDIUM — Brain catalogue/default contract red on master (T-045):** the iOS aggregate gate (`ios/build.sh test:unit`) fails on two unit tests — `BrainModelSelectionTests.testAvailableBrainEntriesIsTheCuratedList` and `InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact` — and stays red at `2061566`. `availableBrainEntries` (ModelCatalog.swift:793-798) now leads with `intentQwenS43` (entry ModelCatalog.swift:533-548) and still includes `qwen4BNepali` (LAN-only URL at 632, RAM floor lowered to 4 GB at 639 by `09b037e`), while `AppCoordinator.defaultBrainModelID` is `intentQwenS43` (AppCoordinator.swift:1170) after `af7e981` (`7d42852` had moved the default from `llama3_2_1B` to the now-superseded v12 `intentNepali1B`, ModelCatalog.swift:516-532). T-045 must prove per test whether the expectation is stale or the assertion caught a real production defect (a shipped picker offering a LAN-only model; default-brain artifact/wiring or doc drift, including the v12 entry carrying the seed-43 comment at ModelCatalog.swift:520-525); a caught defect routes to its own production fix — never a weakened, skipped or deleted assertion, and the gate stays red until that fix lands.
25. **HIGH — Wrong chat framing for the offered Nepali brains (T-046, EXPEDITE):** `LlamaCommandInterpreter.chatFormat(for:)` (LlamaCommandInterpreter.swift:490-515) maps only `qwen3_1_7BInstruct` and `qwen3_4BInstruct` to the Qwen3 `<|im_start|>` scheme (switch case 492) and sends every other id to the default branch (503-514), the LLaMA 3.2 framing the function's own doc comment calls "gibberish" to Qwen models (486-489). The default brain `intentQwenS43` (AppCoordinator.swift:1170; entry ModelCatalog.swift:533-548; first curated entry at 794) and the offered `qwen4BNepali` (entry 622-641; offered at 795) are both Qwen3-derived — the v14 Qwen3-1.7B QLoRA fine-tune and the assembled Qwen3-4B Nepali model — and the hidden but still-resolvable `intentNepali1B` (516-532; AppCoordinator.swift:1176-1179) shares that lineage. The fine-tunes were trained on raw text with no chat-template wrap (tools/train-intent/src/train_qlora.py:45-58; eval_golden.py:120-126) while the runtime builds the prompt with chat special tokens (LlamaCommandInterpreter.swift:522-537, 620-627, 699-703), and the only chat-format test covers the two stock Qwen3 ids (BrainModelSelectionTests.swift:96-111 at `2061566`). Wrong framing degrades the JSON/intent output the router consumes, including emergency classification, before the keyword-net backstop — T-046 fixes it with a per-id determination, an offline reproduce-then-fix check, and an every-offered-id regression test.
26. **MEDIUM — Catalogue/default comments contradict the code (T-047):** four named drifts at `2061566` — the `intentNepali1B` declaration comment still calls the id a pre-bake-off PLACEHOLDER while its entry (ModelCatalog.swift:516-532) is the real-but-superseded v12 seed-42 artifact and that entry's comment (520-525) describes the seed-43/slim-template workload belonging to `intentQwenS43` (533-548); the hidden `llama3_2_1B` comment (501-507) still claims to be the auto-download default (false: AppCoordinator.swift:1170); the hidden-STT rationale (764-766) contradicts the FLEURS numbers recorded at 370-372 and 391-393; and the default-brain doc comment (AppCoordinator.swift:1158-1169) still describes LLaMA 3.2 1B / bartowski / ~807 MB with "v12, seed 42". T-047 reconciles all four and sweeps Swift, `docs/`, the plan artifacts, `Localizable.xcstrings` and README for related stale LLaMA-3.2-as-default / v12-seed-42 / skeleton-style claims, recording the sweep method and result — comments only, no behaviour or constants.
27. **MEDIUM — Two deferred decisions are undocumented (T-048):** the LAN-only `qwen4BNepali` (ModelCatalog.swift:632) is offered in the shipped picker (795; consumers SettingsView.swift:3216, 3225) with no decision on hosting vs hiding, against the "anything offered must be fetchable" rule (AppCoordinator.swift:1255-1263), the App Store/Play compliance constraints (constitution.md:61-64) and FR-007 (requirements.md:40-42); and the interpreter construction default `llama3_2_1B` (LlamaCommandInterpreter.swift:386) diverges from the app default `intentQwenS43` (AppCoordinator.swift:1170), pinned by a test (BrainModelSelectionTests.swift:145-161 at `2061566`). T-048 decides both and either names an implementation follow-up task or records an explicit Open Decision (constitution.md:93) — an undocumented divergence is not an outcome.
28. **HIGH — Release builds print the recognised transcript (T-049):** `WhisperSpeechRecognizer.swift:815` and `WhisperKitSpeechRecognizer.swift:488` print the utterance verbatim, and `WhisperKitSpeechRecognizer.swift:493` prints the raw error object. Neither file contains a `#if DEBUG` region — only `#if canImport(SwiftWhisper)` (3, 186, 544, 932) and `#if canImport(WhisperKit)` (4, 71, 104, 161, 293, 319, 417, 646) — and `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set only in the Debug configuration (project.pbxproj:2702, closed by `name = Debug;` at 2706; Release at 2708 does not set it), so both prints ship. They bypass `LogSanitiser` and `ConsoleObservabilityBus` (AppCoordinator.swift:7049, print at 7066) entirely: on the on-device stack every medication name, symptom, family name and emergency phrase reaches the device console, retrievable via sysdiagnose, against NFR-016 and the constitution's Privacy bullet. The correctly guarded Gemini pattern already exists to copy (`GeminiSpeechRecognizer.swift:122-125`, `:129-135`; `GeminiCommandInterpreter.swift:62-70`). The adjacent metadata prints (`WhisperSpeechRecognizer.swift:809-812`, `WhisperKitSpeechRecognizer.swift:487`) are PII-free and must survive. Reported as B1 of the `security-test` SECURITY-NO_GO.
29. **HIGH — The Gemini API key and raw upstream bodies reach the console (T-050):** the key sits in the request URL query (`GeminiClient.swift:230`, `:395`), transport failures rethrow the untouched `URLError` that carries that URL (`:258-263`, `:413-418`), six sites stringify it with `String(describing: error)` into `error_code` (`GeminiSpeechRecognizer.swift:139`, `GeminiCommandInterpreter.swift:107`, `VoicePipeline.swift:855`, `GeminiClient+Vision.swift:117`, `ApplianceHelperSession.swift:190`, `NepaliCalendarPlugin.swift:90`), and `LogSanitiser` copies `errorCode` unscrubbed (`:59`) because `error_code` is allow-listed (`:30`) and the scrub pass (`:64-76`, patterns `:37-47`) runs only over allow-listed metadata and matches only phone/e-mail/blood-pressure shapes. `error_code` is therefore the one content-bearing field no allow-list decision and no scrub pattern ever touches. The `security-test` repro shows `String(describing: URLError)` containing `...key=SECRET_API_KEY_VALUE, NSErrorFailingURLStringKey=https://…`, so a mere offline/DNS/TLS/timeout failure leaks the key. `GeminiClientError.httpError(status:body:)` (`:53`, thrown `:428-429`) retains the raw upstream body and is stringified at the same sites. Gate is green while both defects ship — tests do not cover the error path's content. Reported as B2 of the `security-test` SECURITY-NO_GO.
30. **HIGH — The continuous-learning loop's egress boundary is the project's first device-data channel (T-053, T-054, T-056, T-059):** the shipped flywheel log is content-bearing by design — `IntentLogStore` holds slot values (contact names included) and states it "leaves only via the family's explicit export" (`IntentLogStore.swift:8-14`) — and the loop's hashed egress (hashes/signals leave; raw audio and raw text do not) is a second channel over the same record. The natural implementation mistake is to serialise `IntentLogStore.Record` and post it, which would send slot values off-device against NFR-015 (`requirements.md:262-263`) and Architecture Constraint 1 (`constitution.md:43`). A hash of a low-entropy utterance is a pseudonym, not anonymity, so an unsalted hash would overstate the guarantee. Controls: T-053 rules on the consent basis, salt and retention; T-054 writes the payload field by field; T-056 builds the serialiser from derived fields and amends the store's docstring so the shipped source describes both channels; T-059 audits the serialised bytes end to end and classifies any deviation as BLOCKING.
31. **HIGH — The promotion gate can publish a regression, or be bypassed (T-058, T-060):** the eight T-038 gates are absolute floors (`config.yaml:56-69`) and the harness exits non-zero on any failure (`eval_golden.py:821-838`, `:895-898`), but a candidate can clear every floor and still lose to the brain the user actually has. The incumbent comparison rides on the corpus-revision binding (`@<hash8>`), whose missing-baseline case is UNEVALUATED and must fail closed (`:742-763`, `:814-815`). A promotion gate wired as a second, parallel decision path — or one that reads "no baseline" as "pass" — would publish unmeasured brains, and the weekly cadence multiplies the opportunity. Controls: T-058 adds the comparison to the existing single refusal list in `run_encoder_pipeline.py:303-330`, `:556-559`; T-060 drives the blocking cases, including an all-gates-pass candidate that loses to the incumbent and a stale-baseline candidate, and asserts the artifact was never written.

## Security blockers

From `security-design-review.md`:

- **THREAT-001 — BLOCKER on T-014-a and T-014-b (VoiceBiometricAuth):** PAD/liveness detection design note must be reviewed and approved by the security reviewer before either VoiceBiometricAuth subtask can start. The implementing team must document which PAD approach is selected: (a) ECAPA-TDNN variant with built-in PAD, or (b) AASIST-based separate anti-spoofing model.

No new security BLOCKERs are introduced by TG-08. The encoder keeps the on-device-only constraint (FR-007), runs after `InputSanitiser.sanitise(.quarantine)` (NFR-013), emits no PII through observability (NFR-016), and cannot gate the keyword safety net or the emergency path (FR-009).

No new security BLOCKERs are introduced by TG-09. The plugin boundary keeps emergency dispatch, medication acknowledgement/reminders and the deterministic keyword net in core (constitution; plugin design §5), the transcript fix applies quarantine-level sanitisation at the dispatch boundary (NFR-013), plugin confirmation governance removes the confirm-before-execute hole (T-043), and plugin observability remains PII-free (NFR-016).

No new security BLOCKERs are introduced by T-045. The task reads the catalogue/default wiring only, and if it routes a production fix, the fix keeps the on-device model constraint (FR-007).

No new security BLOCKERs are introduced by T-046–T-048. T-046 keeps `InputSanitiser.sanitise(.quarantine)` as the sole transcript entry into the prompt (NFR-013) and does not touch the keyword safety net or the router stage order (FR-009); T-047 changes comments only; T-048 keeps the on-device-only constraint (FR-007) and the auto-download default on a real hosted artifact.

No new security BLOCKERs are introduced by TG-10. The loop is opt-in (recorded decision D-1), leaves raw audio and raw text on the device (D-2, NFR-015), carries no PII or secret on any path it adds (NFR-016), and cannot gate, suppress or replace the keyword safety net, the emergency path or medication acknowledgement (FR-009; design §7.1). TG-10 depends on T-050's sanitiser hardening rather than re-opening it: its telemetry rides the existing `LogSanitiser` boundary (T-059 audits it), and a loop event that carries content on a declared key is a finding against the boundary, not a reason to bypass it. Two of the group's tasks are privacy-verification tasks by construction (T-053's review, T-059's audit), and a BLOCKING finding in either blocks the loop's enablement rather than being logged and waived.

**T-049 and T-050 are remediation tasks, not new BLOCKERs** — they close findings B1 and B2 of `specs/security-test.md`, where the `security-test` task returned **SECURITY-NO_GO**. T-049 removes transcript content from Release output without removing the PII-free counts and timings that make on-device STT diagnosable. T-050 restores the sanitiser's guarantee at the `LogSanitiser` boundary rather than by emitter-by-emitter discipline, so the next emitter inherits the safe behaviour. Neither touches the keyword safety net, the router stage order or the emergency path (FR-009); T-050's binding of `errorCode` must not weaken the existing allow-list behaviour for the sanitiser's other keys, and T-049 must not re-create the leak in its own tests (NFR-016).

**The security test's remaining findings stay open.** B3 (sensitive-action authentication unwired; BLOCKER-1/2 still open), B4/B6 (no emergency-call module; APNs/FCM alert stubs return success silently), B5 (remote-config chain absent; cleartext LAN model URLs against NFR-011) and B7 (constitution Privacy bullet vs. the default cloud voice stack) are **not** covered by T-049 or T-050. They are recorded here so that landing the rework stream is not mistaken for a passing security posture: `final-sign-off` remains blocked until those findings are either remediated under their own tasks or explicitly descoped by a human decision recorded as an Open Decision (constitution.md:93).

---

## Task Group Summary

| Group | Title | Tasks | Subtasks | Key Risk |
|-------|-------|-------|----------|----------|
| [TG-01](tasks/TG-01-foundation-infrastructure/index.md) | Foundation & Infrastructure | 4 | 2 (T-002) | MEDIUM/HIGH |
| [TG-02](tasks/TG-02-voice-interface/index.md) | Voice Interface | 6 | 8 (T-005, T-007, T-009, T-012) | MEDIUM/HIGH |
| [TG-03](tasks/TG-03-on-device-ai/index.md) | On-Device AI | 8 | 2 (T-018) | HIGH |
| [TG-04](tasks/TG-04-authentication-security/index.md) | Authentication & Security | 3 | 2 (T-014) | HIGH |
| [TG-05](tasks/TG-05-voice-session/index.md) | Voice Session | 1 | 2 (T-022) | HIGH |
| [TG-06](tasks/TG-06-safety-critical-services/index.md) | Safety-Critical Services | 3 | 6 (T-024, T-026, T-028) | HIGH (SAFETY CRITICAL) |
| [TG-07](tasks/TG-07-remote-configuration/index.md) | Remote Configuration | 3 | 2 (T-032) | HIGH/MEDIUM |
| [TG-08](tasks/TG-08-nepali-intent-encoder/index.md) | Nepali Intent Encoder | 6 | 2 (T-037) | HIGH (GO/NO-GO gate) |
| [TG-09](tasks/TG-09-plugin-recognition-contract/index.md) | Plugin Recognition & Contract | 6 | 0 | HIGH (governance + doc-contract) |
| [TG-10](tasks/TG-10-continuous-learning-loop/index.md) | Continuous Learning Loop | 9 | 0 | HIGH (privacy boundary + promotion gate) |
| **Total** | | **49** | **26** | |

---

## Traceability

| Task | Requirements Covered |
|------|---------------------|
| T-002 (a+b) | NFR-015, NFR-016 |
| T-004 | NFR-015, NFR-016 |
| T-005 (a+b) | FR-004, NFR-006, NFR-007 |
| T-007 (a+b) | FR-004, NFR-006, NFR-007 |
| T-009 (a+b) | FR-001, FR-002, FR-005, NFR-001 |
| T-011 | FR-005 |
| T-012 (a+b) | FR-002, FR-003, FR-006 |
| T-014 (a+b) | FR-011, FR-012, FR-013, NFR-011 |
| T-016 | FR-014 |
| T-017 | FR-013, FR-014, FR-015 |
| T-018 (a+b) | FR-007, FR-008, FR-009, NFR-002 |
| T-020 | NFR-013 (prompt injection) |
| T-021 | FR-008 |
| T-022 (a+b) | FR-001–FR-006, NFR-001–NFR-002 |
| T-024 (a+b) | FR-031, FR-032, NFR-004, NFR-026 |
| T-026 (a+b) | FR-033, FR-034, FR-035, FR-036, NFR-026, NFR-028 |
| T-028 (a+b) | FR-026, FR-027, FR-028, FR-029, NFR-026, NFR-027 |
| T-030 | FR-038, FR-039, NFR-012 |
| T-031 | FR-040, FR-041, FR-042 |
| T-032 (a+b) | FR-038–FR-046 |
| T-033 | FR-007, FR-008, NFR-002 |
| T-034 | FR-003, FR-008, NFR-015 |
| T-035 | FR-007, FR-008, NFR-002 |
| T-036 | FR-007, FR-008, NFR-015, NFR-016 |
| T-037 (a+b) | FR-007, FR-008, FR-009, NFR-002, NFR-013 |
| T-038 | FR-008, FR-009, NFR-002 |
| T-039 | FR-007, FR-008, FR-009, NFR-002 |
| T-040 | FR-008, FR-009, FR-012, NFR-013, NFR-025 |
| T-041 | FR-007, FR-008, NFR-002, NFR-013 |
| T-042 | FR-008, NFR-013, NFR-016, NFR-023 |
| T-043 | FR-009, FR-012, NFR-016, NFR-023 |
| T-044 | FR-008, FR-009, NFR-013, NFR-016, NFR-023 |
| T-045 | FR-007, FR-008, NFR-001, NFR-002 |
| T-046 | FR-007, FR-008, NFR-002 |
| T-047 | FR-007, FR-008 |
| T-048 | FR-007, FR-008 |
| T-049 | NFR-013, NFR-016 |
| T-050 | NFR-010, NFR-011, NFR-016 |
| T-051 | FR-007, FR-008 |
| T-052 | NFR-015, NFR-016 |
| T-053 | NFR-015, NFR-016, NFR-032 |
| T-054 | NFR-011, NFR-015, NFR-016, NFR-032 |
| T-055 | NFR-002, NFR-013, NFR-016 |
| T-056 | NFR-011, NFR-015, NFR-016, NFR-023, NFR-024 |
| T-057 | FR-008, NFR-015, NFR-016 |
| T-058 | FR-009, NFR-016, NFR-029 |
| T-059 | NFR-015, NFR-016, NFR-032 |
| T-060 | FR-009, NFR-016, NFR-029 |
