# conversational-nepali-replies — DV-1…DV-6 device-validation protocol and record (T-187)

**Feature:** `conversational-nepali-replies` · **Task:** T-187 (`TG-38 — Release Gate, Acceptance and Device Validation`) · **Component:** the FR-CNR-025 device-validation protocol-and-record artifact — the feature's completion gate.
**Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies` · **Branch:** `feat/conversational-nepali-replies` · **Authored at HEAD:** `8b64c01cd5074297fb7a753fc414ea2c089f6bde` ("[CNR] T-186: implement-notes — end-to-end acceptance, scoped sweep, release gate (P0 accepting; v17 gated)") · **Date:** 2026-10-17.
**Governing requirements:** FR-CNR-025 (the completion gate), FR-CNR-016 (the v17 chat-aware variant), NFR-CNR-002 (listening-turn latency envelope), NFR-CNR-003 (memory and jetsam behaviour), NFR-CNR-009 (accessibility), NFR-CNR-006 / NFR-CNR-011 (release log gate and honest reporting), FR-CNR-024 (feasibility honesty).
**Binding sources of record for the item wording:** the feature constitution's completion gate (`specs/conversational-nepali-replies/constitution.md:128-137` — the DV-1…DV-6 list, verbatim); the workflow `final-sign-off` comment (`specs/conversational-nepali-replies/workflow.yaml:219-232` — the same list, the release-gate line, "DV-* device validation on Anzaan is part of the completion gate"); FR-CNR-025's description (`:11-18`) and Gherkin (`:22-42`); `specs/design-l1.md` §18 (`:765-778` — the script/evidence table); FR-CNR-025's own sources (proposal §6; the safety/compliance delta). The T-187 task file's implementation notes carry the item set as reproduced in §6.
**Format precedent:** the house 10-section device-validation protocols — `specs/MTC-device-validation-protocol.md` (T-143) and `specs/FCU-device-validation-protocol.md` (T-164). This file follows the merged protocol+record shape: the protocol (§1-§6, §8-§10) plus the record the owner fills in (§7).

> **Headline, stated first because everything below depends on it: no Anzaan session has run.**
> No device session was available to this authoring unit — the session is the owner's act (T-187 metadata; `specs/plan-tasks/plan.md:16`). **Every DV item below is recorded BLOCKED — not PASS — with the prerequisite that must clear it** (§7.3). Nothing in this file is a device observation; no simulator, unit-test, acceptance-sweep (§7.5's build-side evidence) or training-box gate result fills any row. The feature's completion status is therefore explicitly **DEVICE-VALIDATION-OUTSTANDING**, stated plainly per FR-CNR-024 and the T-187 Gherkin scenario "No session available".

> **State of the feature at authoring, stated honestly (verified; not re-litigated here).**
> The **P0 runtime slice ACCEPTS** — T-186's scoped sweep over the integrated tree is green except one characterisation-recorded flake and the three recorded pre-existing baseline reds (`specs/CNR-acceptance-notes.md` §2-§4). The **P1 chat-aware catalog entry `intentQwenS43ChatV17` is PRESENT BUT NOT PROMOTED**: it ships blocked — `ModelCatalog.swift:2466` resolves `.blocked(.gateReportMissing)` — and `defaultBrainModelID` is untouched (`AppCoordinator.swift:2202`, still `intentQwenS43`), so no serving path resolves to it (`specs/T-184-notes.md`). The **full-gate report** that would promote it is in flight/owner-gated: the chat-judge leg is blocked on a funded API key (an owner money gate) and the latency leg is unmeasured without exactly the DV session this file protocols (`specs/CNR-v17-evidence/box-records/run-restart-record.json`). **This session validates the built app's existing chat behaviour** (P0 surfaces against the shipped default brain); when a promoted-v17 row exists, it adds its own serve/rollback smoke as §7.6's appendix cell (T-184's open item) — never a DV-1..6 substitution.

> **Deliverable versus gate (read together with the two paragraphs above).**
> This unit's **deliverable is this protocol and its record structure** — complete when this file exists with DV-1…DV-6, step zero, the per-item steps/expected-outcomes/record slots and the record format, per the T-187 DoD. **Executing** the run is owner/device-dependent and did not happen in this authoring task. At the workflow's final sign-off, a missing execution is an **open gate item** — final sign-off cannot pass while the record is empty or while any item is not PASS (FR-CNR-025) — **not a missing deliverable of this unit**.

---

## 1. Why this protocol exists, and what binds it

The feature makes Pip's spoken Nepali conversational: warm, grammatical replies in the elder-family register (honorific agreement, particles within budget, no AI-isms) from the shipped tier, cloud-first chat routing behind explicit consent with a visible indicator, honest degradation to the on-device brain, and it must change none of the safety behaviours — emergency phrasing and command determinism. Unit tests and the acceptance sweep prove the wiring lives in the build (T-186: 716 tests over 30 classes; P0 accepting). Only a device run proves the feature works for the person holding the phone: a real microphone and STT, a real cloud round-trip with a real consent prompt, real airplane-mode offline behaviour, real emergency phrasing, real temperature-zero commands, real elderly listeners judging warmth — and a real memory profile on a 6 GB-class phone.

What binds this protocol:

- **FR-CNR-025 — the completion gate.** "The feature is **not complete** until the DV protocol has been executed on the reference device (Anzaan) and its results are recorded with the feature spec at final sign-off. Each item **must** be recorded with its outcome, and a failed item blocks completion" (FR-CNR-025:8-9). Its Gherkin failure scenario: "Given a DV item that failed or was not executed / When final sign-off is prepared / Then completion is withheld / And the failure or omission is stated explicitly for the owner (FR-CNR-024)" (:37-42). The **release gate** travels with it: "`ios/tools/check-release-log-safety.sh` exits 0 covering the new chat/routing/guard paths (NFR-CNR-006), and the pre-release device console check covers the same paths" (:17).
- **The constitution's completion gate** (`constitution.md:128-137`) carries the DV-1…DV-6 list verbatim (§6, per item) and the release-gate line. §6's item text quotes it; §8 states the mechanics.
- **The workflow's final gate.** The `final-sign-off` comment (`workflow.yaml:219-230`) repeats the list and reads "DV-* device validation on Anzaan is part of the completion gate"; the release line (`:231-232`): "`ios/tools/check-release-log-safety.sh` must exit 0 — wired into `ios/build.sh` ahead of every test scope". `final-sign-off` is **T2 + HIL** (`:233`).
- **NFR-CNR-002 — the latency envelope, measured on device.** For the 1.7B device default, the end-of-utterance to start-of-reply interval has **p50 within 5–8 s** on the reference tier, "measured over the DV session (FR-CNR-025)"; a degraded-to-local fallback "does not push the turn beyond the local envelope by more than the cloud attempt's own timeout budget" (NFR-CNR-002:11-13). Each chat item carries the felt-latency slot (§6).
- **NFR-CNR-003 — memory, counted on device.** "Exactly one brain model resident at a time … **no second resident model**"; during the DV session the app records **0** terminations in which the chat path is the memory driver" (NFR-CNR-003:11-12). Each chat item carries the eviction/reload observation slot; a second resident model or a per-turn reload is a **finding**, not a curiosity (§6).
- **NFR-CNR-009 — the consent/indicator surfaces are accessible.** The indicator is "present for **100%** of cloud-active chat turns" and consent/revocation/state-query are voice-reachable with no touch required; the copy asks no routing internals of the elder (NFR-CNR-009:13-16). DV-2 carries these as recorded observations.
- **NFR-CNR-011 — final sign-off records the DV results** and the feasibility-honesty statement: "`final-sign-off` at **T2 + HIL** records the DV-1..DV-6 results (FR-CNR-025)" (NFR-CNR-011:15).
- **The design's §18 table** is the intermediate wording this protocol expands to scripts and evidence per item; each §6 item quotes its §18 row.
- **No automation substitutes.** The simulator has no real cloud consent flow against the owner's settings, no airplane-mode radio behaviour, no real emergency phrasing path with its affordances, no real STT/microphone and no elderly listeners. No simulator or unit-test observation may fill any row; T-186's scoped sweep and the training-box gates are *supporting* evidence, never a DV item's own (T-186 §6 names exactly the limits the session must measure: the real decode, warmth/latency, offline device behaviour, toggle-back continuity, emergency recall on device, memory tiers). **No item's evidence is a unit test standing in for a device observation.**
- **Determinism posture of this record.** BLOCKED with a named reason is a legitimate terminal state for the session-less case (the T-187 failure-path scenario "No session available"); the record **never** infers a pass from unit tests, from the T-186 acceptance sweep, or from the training-box gates.

## 2. Environment and build identity

Recorded for reproducibility; **a measurement without a device and a build is not reproducible — a result without recorded build identity is not gate evidence** (the house recording rule; T-187's Gherkin "The build under test is not the built artifact" makes a mismatched-identity session invalid for the gate). Values marked `[OWNER INPUT]` do not exist yet and are **not invented here** — a cell that has no value says so.

| Field | Value |
|---|---|
| Reference device | **the Anzaan reference device** (named by the feature constitution and FR-CNR-025). Last recorded observation of this device (voice-OOM investigation, 2026-10-10): iPhone 14 Pro Max, 6 GB class, iOS 26.6.2 beta 23G90 — **not re-asserted here**; `[OWNER INPUT — confirm model, storage and the OS version actually installed at run time, e.g. Settings ▸ General ▸ About]` |
| Build configuration | **Release** is the house pre-release discipline and the configuration the §7.5 device console check names. The NV items below are behaviour-natured, so a Debug observation is *recordable* — but it is recorded **as Debug** and never substituted for a Release reading where the item's nature requires one. `[OWNER INPUT — the configuration actually installed]` |
| Build identity — commit | `[OWNER INPUT — git rev-parse HEAD in this worktree at build time]`. The authoring baseline (this file) is `8b64c01cd5074297fb7a753fc414ea2c089f6bde`; the tested build must be at least this commit. If integration/rebase onto master (81 commits ahead of the branch merge-base, `specs/CNR-acceptance-notes.md` §10) lands first, the tested build is the **integrated** tree — record the commit actually built, whatever it is |
| Build identity — branch / HEAD sha at build | `[OWNER INPUT — branch + `git rev-parse HEAD` at build time; the record must name the build it was observed on]` |
| Build identity — bundle id / version | `[OWNER INPUT — the built app's `CFBundleIdentifier` + `CFBundleVersion`, read from the artifact]`. **Derive the id from the artifact, never from memory**: the house device-install recipe reads it out of the built `.app`'s Info.plist (`ios/device-install.sh:51-63`), because a hardcoded id went stale at the 2026-10-10 rebrand and produced CoreDeviceError 10002 on Anzaan; the device has previously carried more than one installed build of this app |
| Build produced by | `[OWNER INPUT — e.g. `cd ios && DEVELOPMENT_TEAM=<team> ./build.sh build` (signed **Release** device build, `ios/build.sh:184-193`) or `./build.sh ipa` (archives Release, `ios/build.sh:216-233`), or `./device-install.sh` (convenience: builds **Debug-iphoneos**, installs and launches — `ios/device-install.sh:39-76`; record the configuration used either way)]` |
| Install method | `[OWNER INPUT — `xcrun devicectl device install app --device <name> <built .app>` / Xcode Devices / TestFlight / device-install.sh]. A **fresh install** is what makes DV-2's first-use-disclosure leg runnable (§3 S0-5); an upgrade install preserves the app container — record which was used and the consent state it started from` |
| Tester (holds the phone) | `[OWNER INPUT]` |
| Run date(s) | `[OWNER INPUT]` |
| App language under test | The owner's normal configuration — Nepali (`ne`) is the app's launch language (project constitution Architecture Constraint 6); the DV chat fixtures and the guard's locale gate need it. `[OWNER INPUT — record the app/device language actually set]` |
| Cloud-chat consent state at session start | `[OWNER INPUT — granted / denied / revoked / notRecorded; read at Settings ▸ (chat's cloud row, `settings.cloudChat.toggleLabel`) or the first prompt]. **DV-2's first-use leg requires `.notRecorded`** (a fresh install or an install that has never used cloud chat); other legs only require the state be *known* so each transition is recorded |
| Cloud path precondition (DV-2/DV-3 cloud legs) | `[OWNER INPUT — device online (Wi-Fi), provider key configured, cost allowed]. The routing decision reaches `.cloud` only when consent == granted AND online AND key AND cost (`CloudChatRouting.decide`); if the key is absent the cloud-active legs are recorded BLOCKED with that dependency named` |
| Airplane-mode control | `[OWNER INPUT — verified reachable and restored after DV-3]` |
| On-device brain served (the shipped tier) | The shipped default is `intentQwenS43` (1.7B, `AppCoordinator.swift:2202`); the v17 chat variant is present but **not promoted** and no serving path resolves to it (`ModelCatalog.swift:2466` resolves `.blocked(.gateReportMissing)`; T-184). `[OWNER INPUT — the brain model actually served during the session, and its warm/cold state at DV-1's first turn]` |
| Previous build (DV-5 side-by-side / DV-6 A/B baseline) | `[OWNER INPUT — the pre-feature build used as the reference (last shipped build or master tip) and its commit/bundle id]. DV-5's design-evidence form is side-by-side with the previous build; DV-6's available A/B for a P0-only landing is the P0-build-vs-previous form (`design-l1.md:776`)}` |
| Console capture (optional, for §7.5's device check) | `[OWNER INPUT — method, e.g. `xcrun devicectl device process launch --console --device <name> <bundle id>`]. If captured, only **content-free event names / classification fields** may be quoted into this record — §9` |
| Listening panel (DV-6) | `[OWNER INPUT — the elderly listeners present for the side-by-side; recorded by role, the verdict verbatim]` |

## 3. Step zero — the session prerequisites (HARD PREREQUISITE)

**Status as of authoring: not available.** No Anzaan session exists, so S0-1…S0-5 are all unmet and every DV item is BLOCKED (§7.3). The hard items below gate the **whole session**: a failed hard prerequisite (S0-1…S0-4) stops the session **without partial results** — no DV observation is recorded from a session with an unsound base, because every item is measured against it. The item-level prerequisites (S0-5 onward) gate **only their item**; a missing one records that item BLOCKED with the dependency named (the FCU §3 rule).

| # | Prerequisite | Detail | Hard? | State as of authoring |
|---|---|---|---|---|
| S0-1 | **An Anzaan device session** | The reference device, unlocked, on charge, with the owner present (consent prompt, Settings toggles, airplane mode, the emergency flow's resolution). | **Hard** | **Not available** — the dependency of every item |
| S0-2 | **The build under test IS the built artifact, identity recorded** | Install per the house recipe; derive `CFBundleIdentifier` from the built artifact (`ios/device-install.sh:51-63`), never from memory; fill §2's identity cells (commit, branch/HEAD, bundle id/version, configuration, install method). A session against a build whose identity does not match the record is **invalid for the gate**. | **Hard** | Not available |
| S0-3 | **The app launches, transcribes and answers one turn** | Mic permission granted; one spoken utterance transcribes and one reply is spoken. The owner-declared **STT invariant** (functioning STT is the invariant of any change) makes this the session's foundation: a session on a broken STT path measures nothing downstream. | **Hard** | Not available |
| S0-4 | **The shipped-tier brain is present** | The default 1.7B brain downloaded and serving (warm or cold-loadable); **one brain resident** (§6 DV-1's memory slot). The v17 entry must NOT be served by the automatic ladder while its record is blocked (`ModelCatalog.swift:2466`; T-184) — if a chat turn is answered with no brain (degraded pill up), the local-quality legs are not measurable. | **Hard** | Not available |
| S0-5 | **Consent state fit for DV-2's first-use leg** | `.notRecorded` at session start (fresh install, or an install that has never used cloud chat). If the device's install already carries a consent record, either plan the fresh install or record the first-use leg BLOCKED with that dependency named — never faked. | Item (DV-2) | `[OWNER INPUT]` |
| S0-6 | **Online + key + cost allowed** | For DV-2's cloud-active legs and DV-3's mid-turn failure leg. Key absence blocks those legs; it does not block DV-1's local legs. | Item (DV-2, DV-3) | `[OWNER INPUT]` |
| S0-7 | **Airplane-mode toggle reachable, and restored afterwards** | For DV-3's offline leg. | Item (DV-3) | `[OWNER INPUT]` |
| S0-8 | **A previous build for the side-by-side / A/B baseline** | For DV-5's design-evidence form and DV-6's P0-build-vs-previous A/B (`design-l1.md:776`). If unavailable, the affected legs are recorded BLOCKED with that dependency named. | Item (DV-5, DV-6) | `[OWNER INPUT]` |
| S0-9 | **The elderly listening panel present** | DV-6's judges. If the panel is not present, DV-6 is BLOCKED — its verdict cannot be produced by anyone else (the panel IS the authority, FR-CNR-025). | Item (DV-6) | `[OWNER INPUT]` |
| S0-10 | **The §7.5 console capture decided** | Capture the device console across the session (method in §2) or record that it was not taken. | Recording (§7.5) | `[OWNER INPUT]` |

**A failed hard prerequisite stops the session, without partial results.** Record step zero's result (PASS/FAIL with the failing item and its observed state) and leave the DV items BLOCKED; fix, and re-run on the fixed build with the fixed build's identity recorded (§8).

## 4. How to run this (owner procedure)

Written so a person holding the phone can execute it without this document's author present. Say every utterance **once per repetition**, wait for the spoken outcome, and touch the screen only where a step says so. **Nothing is authored on the device**: every fixture is a shipped utterance, a shipped line key, a Settings row, or a shipping control state — the session creates no copy, no content and no state the build does not already own.

1. **Clear step zero (§3).** Do not start the DV items before the hard prerequisites pass; a failed one stops the session with no partial results.
2. **Build, install, record §2.** Fill every `[OWNER INPUT]` cell, identity from the artifact. For DV-2's first-use leg prefer the fresh install (§3 S0-5).
3. **Order: DV-2 → DV-1 → DV-3 → DV-4 → DV-5 → DV-6.** The order is the consent state machine, not preference:
   - **DV-2 first** because it owns the consent transitions: first-use disclosure (needs `.notRecorded`) → grant → indicator → revoke. It **ends revoked**, which is exactly the "force local (consent declined or offline)" state DV-1's script requires (`design-l1.md:771`) — run in this order, DV-1 needs no artificial forcing.
   - **DV-1 next**, with consent revoked: chat turns answer on-device; a flagged local reply resolves to the safe template (no consent ⇒ no escalation attempt — FR-CNR-009's failure scenario).
   - **DV-3 next**: airplane mode on for the offline leg; then airplane off, consent granted if needed (the Settings toggle — the gate's one writer), and the mid-turn cloud-failure leg attempted (§6 DV-3's honesty rule).
   - **DV-4 with cloud chat granted and online** — the strongest form: prove the chat lane and its consent state do not gate or delay the emergency path.
   - **DV-5** commands (consent state irrelevant; leave it as DV-4 ended and record it).
   - **DV-6 last**: the listening panel's side-by-side (its own block if the panel convenes separately — one `§7.2` block per sitting).
   Where the order cannot be held (e.g. an already-granted consent record and no fresh install), record the deviation and the affected legs BLOCKED — never re-order silently.
4. **Run each item in §6 literally**, from its preconditions, in one session. Each item's text is the constitution's/FR-CNR-025's (quoted verbatim); the steps below it are the executable form. Do not substitute your own reproduction.
5. **Write the results into a new session block in §7.2, in the same change** — status (PASS / FAIL / BLOCKED), the observed result (line keys, labels, counts, yes/no — §9), and the evidence pointer. The protocol text of §6 is **not** edited to match results (recording rule 4, §10).
6. **A failed item stays recorded as failing, verbatim with its reproduction steps — not retried away.** Fix the build, re-run that item on the fixed build, record the fixed build's identity in the re-run's session block. Only PASS closes an item (§8).
7. **Capture the §7.5 device console** across the session (if taken): inspect, scrub, reference — never paste raw lines (§9). A content-bearing field in a log is itself a finding.
8. **After the session:** keep this file as the record; final sign-off (§8) consumes it — the T2 human gate cannot pass while the record is empty or any item is not PASS.

## 5. Record fields (defined per item; the format the owner fills)

For every session (§7.2), one appended block carrying:

- **Session-level fields** (they qualify every item row in the block): **date**; **device** (model + OS); **build** (commit + branch/HEAD + `CFBundleIdentifier`/`CFBundleVersion` + configuration); the **consent state at start**; the **step-zero result**; the **§7.5 console-capture reference**.
- **Per-item fields**, one row per DV item:
  - **Status** — PASS / FAIL / BLOCKED (no other value; see the vocabulary below).
  - **Observed result** — what was actually seen/heard: line keys and labels heard, counts, yes/no answers, the felt latency, the eviction/reload observation for chat items. Never a transcript of conversation content beyond the §6 fixtures (§9).
  - **Evidence** — the pointer(s): captured line key, event name with classification fields only, pill state, count, the panel's verdict verbatim (DV-6), the pull reference where one was taken.
- **Memory/latency slots** — per chat item (DV-1, DV-2, DV-3): felt latency (end-of-utterance → start-of-reply, against the 5–8 s p50 envelope) and any eviction/reload observed; **a second resident model or a per-turn reload is a finding, not a curiosity** (NFR-CNR-003).
- **Notes / deviations / tester.**

**Status vocabulary:** **PASS** / **FAIL** / **BLOCKED** (BLOCKED only with the dependency named). No other value is valid; no value is written before the observation exists. **Only PASS closes an item** — FAIL and BLOCKED both hold the completion gate (§8).

## 6. The DV items (the protocol)

Each item carries its **verbatim item text** from the three binding sources (feature constitution `:130-135`; FR-CNR-025 `:11-16`; the workflow `:220-230`) — not paraphrased — then its `design-l1.md` §18 row (script + evidence), preconditions, steps, expected outcome, pass/fail criteria and evidence class. Quoted copy is the shipped `ne`/`en` catalogue values (`ios/ElderlyAssistant/Resources/Localizable.xcstrings`); record a **line key / label**, never a conversation transcript beyond the fixtures (§9). **Evidence classes, stated per item:** DV-1 cites the guard telemetry (`reply_grammar_flag`) with classification fields only; DV-2 cites the cloud-chat telemetry (`cloud_chat_served` / `cloud_chat_voice_control`) and the consent record state; DV-3 cites the fallback classification (`cloud_chat_fallback`); DV-4 cites the emergency phrasing outcomes; DV-5 cites reminder/alarm behaviour at temperature zero; DV-6 cites the panel's side-by-side verdict. No item's evidence is a unit test standing in for a device observation. **Telemetry is read for classification fields only — a content-bearing field in a log is itself a finding** (§9).

### DV-1 — local chat quality: warm, grammatical replies from the shipped tier

- **Item text (verbatim, feature constitution):** "DV-1 — local chat: warm, grammatical replies (honorific agreement, no AI-isms) from the shipped tier."
- **Item text (verbatim, FR-CNR-025):** "**DV-1 — local chat quality**: warm, grammatical replies from the shipped tier (honorific agreement, particles within budget, no AI-isms) — the elderly-user-facing quality claim measured on device."
- **Item text (verbatim, workflow):** "DV-1 — local chat: warm, grammatical replies (honorific agreement, no AI-isms) from the shipped tier;"
- **Item set (verbatim, T-187 implementation notes):** "DV-1 local chat quality (warm, grammatical, honorific agreement, particles within budget, no AI-isms, and a seeded guard flag engaging the safe template)".
- **Source of record:** constitution DV-1; FR-CNR-025; workflow; design-l1 §18 (`:771`); FR-CNR-001/002/003/005/006 (style spec, personas, chat sampling, guard, safe template); NFR-CNR-001 (reproducibility), NFR-CNR-002/003 (the latency/memory slots).
- **Evidence class:** the guard telemetry — `reply_grammar_flag` (`CommandRouter.swift:5015`), classification fields only: `path` (on-device), `check` classes, `outcome` (`escalated` / `safeTemplate` / `degraded` / `notApplicable`); plus session notes per turn (line keys heard). Optionally the pre-existing `command_llm_chat` local-chat dispatch event name if the console is captured. Never reply text (§9).
- **Preconditions:** step zero passed; §2 build; forced local — run after DV-2 ends **revoked** (§4); consent state read and recorded; the shipped default brain warm (`intentQwenS43`); app/device language `ne`.
- **Steps (fixtures: shipped exact-table chat turns, `ChatIntentClassifier.chatFormulas` — these route to the chat surfaces by construction):**
  1. Say **'नमस्ते'**. Expect a short warm greeting reply; nothing executes.
  2. Say **'कस्तो छ नि'**. Expect a warm answer, ≤2 sentences.
  3. Say **'खाना खानुभयो'** (the small-talk exchange). Expect a natural answer in the elder-family register.
  4. Say **'थकाइ लाग्यो'**. Expect warmth/acknowledgement, no canned service phrases.
  5. Say **'मलाई एक्लो लाग्छ'** (live, grammatical, warm — the emotional-register probe). Expect an empathic reply in the register.
  6. Say **'धन्यवाद'**. Expect a short warm acknowledgement.
  7. Optionally probe once in English (**'i am tired'**) — record the reply's language/register honestly.
  Between turns, judge each reply against the style spec: तपाईं + honorific agreement, particles ≤1, SOV and ≤2 sentences, no lists/markdown/AI-isms/translation-ese, code-switched health/tech nouns spoken as such. Record per-turn: line heard (paraphrase by line key/gist only if needed), the four rubric judgements (honorific / particles / no-AI-ism / warmth), the felt latency, and any eviction/reload.
  8. **The guard-flag leg (seeded).** Continue local chat with utterances likely to stress the guard (longer or unusual small talk); watch for `reply_grammar_flag` (console, if captured). When a flagged reply occurs, the expected outcome is the **safe template spoken in place of the reply** — `chat.safeTemplate.<checkClass>` (`honorificAgreement` / `devanagariPurity` / `danglingParticle`, fallback `chat.safeTemplate.generic`) — and the user never hears the flagged text. If the session cannot produce a genuine flag (the shipped model is the regression model and may pass every turn), record that observation and the leg **BLOCKED with the dependency named** (a genuinely flagged reply; no device-side seeding seam is shipped — do not fake one, do not pass on the design's structural argument).
- **Pass criteria:** every scripted turn is answered **from the shipped tier on-device** (no indicator badge shown — the local path was taken; consent state revoked as recorded) with warm, grammatical replies meeting the spec's rubric; no dead-end line, no crash; a genuine flag (if one occurs) yields the safe template and the `reply_grammar_flag` classification; latency within the envelope (§6 slots); no eviction/reload beyond one resident brain.
- **Fail criteria:** a robotic/assistant-like reply or a grammar violation (honorific break, particle over-budget, AI-ism) — recorded verbatim with the turn's fixture and the outcome; a flagged reply **spoken anyway** (no safe template); the flag leg passed without an observed flag; a crash; a second resident model or a per-turn reload observed.
- **Evidence to capture:** per-turn observed outcome (gist/line key), the rubric judgements, felt latency, eviction/reload observation, `reply_grammar_flag` fields if captured. **Record template:** `Status: PASS / FAIL / BLOCKED — <turns observed + rubric verdict + flag leg state> | Evidence: <line keys; reply_grammar_flag fields; latency; memory observation>`.
- **Record as:** the DV-1 row of the session block (§7.2).

### DV-2 — cloud-first chat: consent + visible indicator; toggling off returns to the on-device brain without losing chat

- **Item text (verbatim, feature constitution):** "DV-2 — cloud-first chat: consent + visible indicator work; toggling off returns to the on-device brain without losing chat."
- **Item text (verbatim, FR-CNR-025):** "**DV-2 — cloud-first chat**: consent + plain-language disclosure + visible indicator work; toggling off (revocation) returns to the on-device brain without losing chat."
- **Item text (verbatim, workflow):** "DV-2 — cloud-first chat: consent + visible indicator work; toggling off returns to the on-device brain without losing chat;"
- **Item set (verbatim, T-187 implementation notes):** "DV-2 cloud chat consent plus visible indicator, and toggling off returning to the on-device brain without losing chat".
- **Source of record:** constitution DV-2; FR-CNR-025; workflow; design-l1 §18 (`:772`) and §8.3-§8.6 (gate, disclosure, indicator, revocation); FR-CNR-008/009/010; NFR-CNR-009 (accessibility), NFR-CNR-006 (log safety).
- **Evidence class:** the consent record state transitions (observed at the prompt/Settings, recorded per transition) + the indicator presence count (100% of cloud-active turns, NFR-CNR-009:13) + the cloud-chat telemetry — `cloud_chat_served` and `cloud_chat_voice_control` (`IntentRouter`/`CommandRouter`), classification fields only. Session notes for the copy heard/seen (shipped line keys).
- **Preconditions:** step zero passed (**S0-5: consent `.notRecorded` for the first-use leg**; S0-6: online + key + cost allowed for the cloud-active legs); §2 build; a chat fixture at hand; the first cloud-active chat turn available.
- **Steps:**
  1. **First-use disclosure.** With consent `.notRecorded`, say a chat fixture (**'नमस्ते'**). Expect the blocking consent prompt (`cloud.chat.consent.title` / `cloud.chat.consent.body` — plain language: what goes, what stays, "it's fine to say no") **before any content is sent**; until answered the turn answers locally. Record what was heard/seen and that no content left the device before consent (the prompt precedes the send).
  2. **Grant.** Answer the prompt affirmatively — by voice (**'हो'**) or the `cloud.chat.consent.allow` control. Expect the state to move to granted (record the observed acknowledgement; TTS in `ne`).
  3. **Cloud-active turns + indicator.** Say chat fixtures (repeat step 1's or a fresh one). Expect: the reply arrives via the cloud path; the **visible indicator is present while conversation content is going to the cloud** (`cloud.chat.indicator` badge in the status slot) for **100%** of cloud-active turns — not a one-time toast; the one-per-session spoken notice (`cloud.chat.indicatorSpoken`) at the first cloud-active turn. Count turns vs turns-with-indicator (`n/n = 100%?`).
  4. **Voice state query (accessibility, NFR-CNR-009).** Without touching the device, ask the state — the shipped shape is an internet-word + a state marker (e.g. **'इन्टरनेट चालु छ?'**). Expect the spoken state answer (`cloud.chat.state.spoken.on`).
  5. **Revoke by voice.** Without touching the device, say the shipped revoke shape — an internet-word + a stop verb (e.g. **'इन्टरनेट बन्द गर'**). Expect the revoke flow (`cloud.chat.revoke.title/body/done`) and the state to move to revoked (`cloud_chat_voice_control` classification if the console is captured).
  6. **Toggle-back without losing chat.** Immediately say a chat fixture again. Expect the **next turn answered on-device** (local path; no indicator), **in the same turn** — no error, no lockout, no dropped turn; chat keeps working exactly as before (the `cloud.chat.revoke.body` promise: "Chat keeps working just as before. Nothing is lost."). Record whether the conversation context carried on naturally.
  7. Optional (re-grant for DV-3's failure leg, §4): toggle back on via the Settings row (`settings.cloudChat.toggleLabel`) — record the row's state and the transition.
- **Pass criteria:** disclosure shown before any send with `.notRecorded`; consent grant observed and recorded; indicator present for 100% of cloud-active turns in the language of the device; state query and revoke both voice-reachable with spoken confirmations; revocation takes effect at the next turn's routing decision (no cached route) and the next chat turn is answered on-device with chat fully functional; no crash; no content sent without consent.
- **Fail criteria:** any content leaving before consent; the indicator missing on any cloud-active turn (record the count — it fails the NFR-CNR-009 100% property); a revoked state that still routes cloud or requires touch to recover; chat unavailable after revoke; the flow requiring the elder to reason about routing internals.
- **Evidence to capture:** per-transition consent state; prompt/indicator/state/revoke line keys heard; indicator count `n/n`; the next-turn-local observation; felt latency on the cloud turns and the post-revoke local turn; any eviction/reload observed. **Record template:** `Status: PASS / FAIL / BLOCKED — <disclosure + grant + indicator count + revoke + toggle-back local> | Evidence: <line keys; counts; cloud_chat_* classification fields>`.
- **Record as:** the DV-2 row of the session block (§7.2).

### DV-3 — offline chat degrades honestly to the local brain

- **Item text (verbatim, feature constitution):** "DV-3 — offline chat degrades honestly to the local brain (no crash, no false success)."
- **Item text (verbatim, FR-CNR-025):** "**DV-3 — offline/honest degradation**: with no cloud available, chat degrades honestly to the local brain — no crash, no false success, no dropped turn."
- **Item text (verbatim, workflow):** "DV-3 — offline chat degrades honestly to the local brain (no crash, no false success);"
- **Item set (verbatim, T-187 implementation notes):** "DV-3 offline chat degrading honestly to the local brain (no crash, no false success)".
- **Source of record:** constitution DV-3; FR-CNR-025; workflow; design-l1 §18 (`:773`) and §8.8 (degradation); FR-CNR-008; NFR-CNR-002 (the fallback bound).
- **Evidence class:** session notes + the fallback classification — `cloud_chat_fallback` (`IntentRouter`), classification and reason token only. No content (§9).
- **Preconditions:** step zero passed (S0-6, S0-7); §2 build; consent **granted** for the mid-turn failure leg (DV-2 step 7 / §4); airplane-mode control reachable.
- **Steps:**
  1. **Offline leg.** Airplane mode **on** (record it in force). Say chat fixtures (**'नमस्ते'**, then **'कस्तो छ नि'**). Expect: each turn **answered on-device in the same turn** — no indicator, no error where a reply is expected, no dropped turn, no crash; the reply still meets the register rubric. Record per-turn latency (the local envelope).
  2. Restore connectivity (airplane mode **off**); confirm online.
  3. **Mid-turn cloud-failure leg (attempt to force it).** With consent granted + online, start a cloud-active chat turn and force the attempt to fail — e.g. flip airplane mode on inside the attempt window, or drop Wi-Fi mid-turn. **Honesty rule:** the failure must be **observed in force** for that turn (the `cloud_chat_fallback` classification with its reason, or the observable equivalent — the reply arriving locally where the cloud was expected). If the failure cannot be produced in force on the day, record that observation and this leg **BLOCKED with the dependency named** — never mark it pass on the structural argument alone.
  4. Observe the same-turn outcome: the turn is answered by the local brain **in the same turn**, within the bound "local envelope + the cloud attempt's bounded budget" (NFR-CNR-002) — never an indefinite wait; the fallback is recorded as a classification, **not as a cloud success** (no false success).
- **Pass criteria:** offline turns answered locally, honestly, without crash or dropped turn; the forced failure (when in force) degrades to local **in the same turn**, recorded as fallback classification, within the bound; no false success anywhere.
- **Fail criteria:** a dropped turn or an error where a reply is expected; a crash; a fallback presented as a cloud success; an indefinite wait beyond the bound; the failure leg passed without the failure observed in force.
- **Evidence to capture:** airplane-mode state; per-turn outcome + latency; the `cloud_chat_fallback` classification (reason token) if captured; the forcing route used and how the failure was confirmed in force; any eviction/reload observed. **Record template:** `Status: PASS / FAIL / BLOCKED — <offline turns local + forced-failure leg state + bound observed yes/no> | Evidence: <line keys; fallback classification; latency>`.
- **Record as:** the DV-3 row of the session block (§7.2).

### DV-4 — emergency phrasing still triggers exactly (recall untouched on device)

- **Item text (verbatim, feature constitution):** "DV-4 — emergency phrasing still triggers exactly (recall untouched on device)."
- **Item text (verbatim, FR-CNR-025):** "**DV-4 — emergency phrasing recall on device**: emergency phrasing still triggers exactly; recall is untouched by the chat work (the gate form is 1.00, FR-CNR-014/021)."
- **Item text (verbatim, workflow):** "DV-4 — emergency phrasing still triggers exactly (recall untouched on device);"
- **Item set (verbatim, T-187 implementation notes):** "DV-4 emergency phrasing triggering exactly (recall untouched on device)".
- **Source of record:** constitution DV-4; FR-CNR-025; workflow; design-l1 §18 (`:774`, "existing emergency check script"); FR-CNR-014 (safety path unchanged); the frozen phrase list (`DialectCanonicalizer.swift:751-755` = `CommandRouter.swift:1468-1473`: 7 English + 10 Nepali).
- **Evidence class:** the **emergency phrasing outcomes** — per-phrase trigger observed (yes/no) over the frozen list; optional `command_emergency_keyword` classification (content-free) if the console is captured. The model-side gate form (recall 1.00, FR-CNR-021) belongs to the training-box gates — this item is the device form.
- **Preconditions:** step zero passed; §2 build; **cloud chat granted and online** (§4 — the strongest form: the chat lane and its consent state must not gate or delay the emergency path); a nominated emergency contact configured so the flow has its normal target.
- **Steps (the "existing emergency check script" = the frozen list, phrase by phrase):**
  1. Speak (or type-face, if the venue is noisy — record which) each of the **17 frozen emergency phrases** once each, one per turn: "help", "emergency", "i fell", "fell down", "chest pain", "can't breathe", "cant breathe", "मद्दत", "सहयोग गर", "बचाउ", "आपतकाल", "लडेँ", "लडें", "लड्नुभयो", "सास फेर्न सकिन", "सास फेर्न गाह्रो", "छाती दुख्यो".
  2. Per phrase, observe: the emergency path triggers **exactly as the pre-feature build does** — the ack is spoken (`router.emergencyAck`) and the emergency flow presents its shipped affordance (the item is about the **trigger**; do not place a real emergency call unless the owner intends to — resolve/cancel via the flow's normal affordance and record which resolution was taken). Record trigger yes/no per phrase.
  3. Optional discriminator: interleave one chat turn (**'नमस्ते'**) between two emergency phrases and confirm the chat turn does not consume or delay the following trigger.
  4. Optional side-by-side: repeat two phrases on the previous build (§2) and record that the trigger behaviour matches.
- **Pass criteria:** **every** phrase in the frozen list triggers (recall = 1.00 in the list's own terms) with the same behaviour as pre-feature (ack + flow); no chat state (routing, consent, guard, in-flight cloud request) gates, delays or re-classifies any trigger; no crash.
- **Fail criteria:** any phrase failing to trigger (record it verbatim with the phrase and the observed outcome — a failure here is a safety finding, not a tuning invitation, and it holds the gate); a trigger delayed or consumed by a chat turn; the flow's behaviour changed from the pre-feature reference; a crash.
- **Evidence to capture:** the per-phrase table (17 rows: phrase → trigger yes/no → ack heard → resolution taken); the `command_emergency_keyword` classification if captured; the chat-granted state in force. **Record template:** `Status: PASS / FAIL / BLOCKED — <17/17 trigger table or the failing phrase(s)> | Evidence: <per-phrase outcomes; console classification if captured>`.
- **Record as:** the DV-4 row of the session block (§7.2).

### DV-5 — command determinism unchanged (reminders and alarms at temperature zero)

- **Item text (verbatim, feature constitution):** "DV-5 — command determinism unchanged (temp-0 behaviors, e.g. reminders/alarms)."
- **Item text (verbatim, FR-CNR-025):** "**DV-5 — command determinism unchanged**: temp-0 behaviours (e.g. reminders/alarms) are unchanged on device (FR-CNR-004)."
- **Item text (verbatim, workflow):** "DV-5 — command determinism unchanged (e.g. reminders/alarms at temp-0 behaviors);"
- **Item set (verbatim, T-187 implementation notes):** "DV-5 command determinism unchanged (for example reminders and alarms at temperature zero)".
- **Source of record:** constitution DV-5; FR-CNR-025; workflow; design-l1 §18 (`:775`); FR-CNR-004 (temp-0 + fixed seed + GBNF untouched; `OnDeviceSampling.fixedSeed` = 20_260_907; the per-turn re-assertion is the mitigation, `plan.md` risk 1).
- **Evidence class:** **reminder/alarm behaviour at temperature zero** — repeated commands' spoken confirmations identical (line keys/heard text), the alarm actually arming/ringing, side-by-side with the previous build where available.
- **Preconditions:** step zero passed; §2 build; a near-future alarm time chosen (e.g. two minutes ahead); the previous build available for the side-by-side leg (S0-8) or that leg BLOCKED with the dependency named.
- **Steps:**
  1. **Reminder, twice.** Say a shipped reminder-shape command twice (the reminder corpus's shape, e.g. **'बिहान ६ बजे उठाउनु'**; wait for the first confirmation before repeating). Record both confirmations: the spoken line/words and their identity (`identical: yes/no`) — temp-0 determinism's device form.
  2. **Alarm, twice.** Say a shipped alarm-shape command twice (e.g. **'बिहान ६ बजे अलार्म लगाऊ'** / "set an alarm for 6 am"; a near-future minute for the ringing leg). Record both confirmations' identity; record whether the second reports the same outcome or an honest already-set state (**record what it says**, either way).
  3. **Alarm rings (optional but strongest).** Let the near-future alarm fire: the alarm rings/speaks its shipped behaviour. Record it fired yes/no.
  4. **Side-by-side.** Repeat one reminder and one alarm command on the previous build (§2) and compare the observed behaviour: `matches pre-feature: yes/no` (design's evidence form, `:775`). If the previous build is unavailable, record the leg BLOCKED with that dependency named.
  5. Optional: repeat step 1's command a third time after a chat turn interlude (chat decode cannot leak temperature/seed into a command turn — FR-CNR-004's own scenario) and record that the confirmation is still identical.
- **Pass criteria:** repeated commands produce **identical** confirmations (the temp-0 path); the alarm arms and fires as before; behaviour matches the previous build; a chat turn between commands changes nothing on the command path; no crash.
- **Fail criteria:** repeat commands producing different outcomes; a changed confirmation; the alarm not arming/firing where the pre-feature build did; a chat turn altering the command path (a NO-GIBBERISH invariant violation — report, do not retune).
- **Evidence to capture:** the two repeat pairs (commands described by shape/fixture, confirmations' line keys + identical yes/no); alarm-fired yes/no; side-by-side match yes/no; the post-chat repeat if run. **Record template:** `Status: PASS / FAIL / BLOCKED — <reminder x2 identical + alarm x2 + fired + side-by-side> | Evidence: <line keys; identical/match yes-no>`.
- **Record as:** the DV-5 row of the session block (§7.2).

### DV-6 — the elderly listening panel's side-by-side verdict recorded

- **Item text (verbatim, feature constitution):** "DV-6 — elderly listening panel A/B verdict recorded."
- **Item text (verbatim, FR-CNR-025):** "**DV-6 — elderly listening panel A/B verdict recorded**: real elderly listeners judge the A/B behind the catalog pick; their verdict is the "human-like" authority and is recorded, whatever it says."
- **Item text (verbatim, workflow):** "DV-6 — elderly listening panel A/B verdict recorded."
- **Item set (verbatim, T-187 implementation notes):** "DV-6 the elderly listening panel's side-by-side verdict recorded".
- **Source of record:** constitution DV-6 and Success ("The elderly listening panel's verdict is recorded"); FR-CNR-025 (its own Gherkin scenario: "the verdict is recorded verbatim / And it is not summarised into a claim the panel did not make"); workflow; design-l1 §18 (`:776` — the A/B behind the catalog pick; "v17 vs previous, or P0-build vs previous for a P0-only landing"; the verdict "VERBATIM"; "A/B pick flip + rollback exercised here"); FR-CNR-022 (the catalog pick).
- **Evidence class:** **the panel's side-by-side verdict, recorded verbatim** — the panel's own words; the item's evidence is the verdict, not a résumé of it.
- **Preconditions:** step zero passed; §2 build; **the elderly listeners present** (S0-9); the A/B baseline available (S0-8). With the v17 record blocked (PRESENT BUT NOT PROMOTED — §headline), the available A/B is the design's P0-build-vs-previous form (`:776`); if a promoted-v17 row exists by the session, the A/B follows the catalog pick (v17 vs previous) and the pick flip + rollback is exercised here (design `:776`; §7.6's appendix carries the serve/rollback smoke).
- **Steps:**
  1. Present the same chat fixtures (DV-1's list, or the panel's own natural questions within the register) in a **side-by-side** between the build under test and the baseline (previous build, or the catalog pick per the design). Fix which is A and which is B, and record the mapping (and that the listeners were not told which is which, if that is how the session runs it — record the actual protocol used).
  2. Let the listeners judge: which sounds more human/warm/natural, and **why in their words**. Do not instruct, steer or translate their judgement.
  3. Record the verdict **verbatim** — per listener where the panel gave individual verdicts, plus any consensus statement — including dissenting or negative verdicts, unchanged (`whatever it says`, FR-CNR-025).
- **Pass criteria:** the panel judged a side-by-side behind the catalog pick; the verdict is recorded verbatim, complete, unsteered, including any negative verdict; the recording does not summarise it into a claim the panel did not make.
- **Fail criteria:** a verdict recorded second-hand or paraphrased into a stronger claim; listeners steered or primed with the expected answer; the A/B not actually side-by-side (e.g. one arm missing); no panel (record BLOCKED with the dependency named — the panel IS the authority and cannot be substituted).
- **Evidence to capture:** the A/B mapping (which build was A/B); the listening protocol used; the verdict verbatim (names recorded by role, §9); any dissent. **Record template:** `Status: PASS / FAIL / BLOCKED — <A/B mapping + verdict verbatim (or BLOCKED — panel unavailable)> | Evidence: <verdict text; protocol note>`.
- **Record as:** the DV-6 row of the session block (§7.2).

## 7. Record (to be filled by the owner at run time)

**State as of authoring: no device run has occurred.** No session block exists below; every item is **BLOCKED** (§7.3). The outcome vocabulary the owner writes when the run happens: **PASS** / **FAIL** / **BLOCKED** (BLOCKED only with the dependency named). No other value is valid; no value is written before the observation exists.

### 7.1 Environment and build identity (run record)

Fill §2's table in place — it is the single environment block for every session in this file. **Re-runs after a fix record their build identity in the re-run's session block** (device/OS follow §2 unless the re-run moved devices); §2 keeps the first run's identity, and the fixed-build session block is the record the completion claim rests on.

### 7.2 Session blocks (one per session, accumulated — copy the template)

<!-- TEMPLATE — copy for each session, fill, leave nothing blank (a field that has no value says so). -->

**Session 1 — [OWNER INPUT — date]**

- **Date:** `[OWNER INPUT]`
- **Device:** `[OWNER INPUT — model + OS version; the "Anzaan" reference device]`
- **Build:** `[OWNER INPUT — commit + branch/HEAD + CFBundleIdentifier + CFBundleVersion + configuration]`
- **Consent state at start:** `[OWNER INPUT]`
- **Step zero (§3):** `[OWNER INPUT — PASS/FAIL; the failing prerequisite if any]`
- **Console capture (§7.5):** `[OWNER INPUT — reference; inspected: yes/no]`
- **Per-item results:**

| Item | Status (PASS / FAIL / BLOCKED) | Observed result (line keys / labels / counts / yes-no / latency / memory observation — §9) | Evidence pointer |
|---|---|---|---|
| DV-1 — local chat quality (rubric + seeded guard flag → safe template) | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-2 — consent + disclosure + indicator (100%) + revoke → on-device without losing chat | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-3 — offline + forced-failure honest degradation | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-4 — emergency phrasing recall (frozen 17-phrase list) | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-5 — reminder/alarm determinism at temp 0 (+ side-by-side) | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-6 — elderly listening panel A/B verdict (verbatim) | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |

- **Notes / deviations:** `[OWNER INPUT]`
- **Tester:** `[OWNER INPUT]`

### 7.3 Item status as of authoring (not observations)

| Item | Status as of authoring | Named dependency (what must clear it) |
|---|---|---|
| DV-1 — local chat quality | **BLOCKED** | An Anzaan device session + the §2 build (S0-1/S0-2) + a working STT path (S0-3) + the shipped-tier brain present (S0-4) + the forced-local state (DV-2's revoke, or an equivalent recorded state); the guard-flag leg additionally needs a genuinely flagged reply observed in the session |
| DV-2 — consent + indicator + toggle-back | **BLOCKED** | An Anzaan device session + the §2 build + a **`.notRecorded` consent state** (S0-5) + online with key and cost allowed (S0-6) |
| DV-3 — offline / honest degradation | **BLOCKED** | An Anzaan device session + the §2 build + airplane-mode control (S0-7); the mid-turn failure leg additionally needs consent granted (S0-6) and the failure produced in force (DV-3's honesty rule) |
| DV-4 — emergency phrasing recall | **BLOCKED** | An Anzaan device session + the §2 build + cloud chat granted and online (the strongest form) + a configured emergency contact for the flow's target |
| DV-5 — command determinism | **BLOCKED** | An Anzaan device session + the §2 build + a near-future alarm time; the side-by-side leg additionally needs the previous build (S0-8) |
| DV-6 — listening panel verdict | **BLOCKED** | An Anzaan device session + the §2 build + the elderly listeners present (S0-9) + the A/B baseline (S0-8, the P0-build-vs-previous form while the v17 record is blocked) |

**Feature completion status: DEVICE-VALIDATION-OUTSTANDING.** No item is PASS; none may be reported as such until a session executes it and this record carries the observation (FR-CNR-025; FR-CNR-024 honesty).

### 7.4 Owner actions carried (decisions, not measurements)

| # | Owner action | Why it is the owner's | State |
|---|---|---|---|
| OA-1 | Provide an Anzaan device session and execute DV-1…DV-6 against the §2 build, filling §2/§7.2 | Only the owner has the device, the accounts and the consent decisions | **Open — BLOCKED** (the dependency of every item) |
| OA-2 | Install a build whose identity is recorded from the artifact (§2 cells; S0-2) | The build identity is the gate's anchor; the device has carried more than one install | Open |
| OA-3 | Decide the fresh-install route for DV-2's first-use leg (S0-5) | Household/devices state ownership; a fresh install resets consent and app state | Open |
| OA-4 | Assemble the elderly listening panel for DV-6 | The panel IS the "human-like" authority (FR-CNR-025) — it cannot be substituted by agents or tests | Open |
| OA-5 | Resolve any FAIL or BLOCKED item: fix, re-run on the fixed build, or record an explicit owner resolution | FR-CNR-025: a failure blocks completion until fixed and re-run — no silent waiver | Open |
| OA-6 | Fund the chat-judge API key for the v17 full-gate report (the promotion gate; not a DV item) | An owner money gate (T-184; `specs/CNR-acceptance-notes.md` §10); its latency leg is measured in this DV session | Open |
| OA-7 | Confirm the consent/disclosure and indicator copy before the first App Store submission | FR-CNR-009's review clause; the DV-2 session is where the copy is first exercised end to end | Open |

### 7.5 Accompanying release-gate evidence (required by FR-CNR-025, NFR-CNR-006, NFR-CNR-011)

FR-CNR-025: "the release log-safety gate's exit-zero result for the built artifact" travels with the DV record; the workflow names it part of the gate (`workflow.yaml:231-232`). This is **not** a DV item — it is the record half that accompanies it:

| Evidence | Source | State |
|---|---|---|
| Log-safety gate exits 0 over the feature roots and event types | **Build-side, executed by this unit at authoring (2026-10-17):** `bash tools/check-release-log-safety.sh` from `ios/` — exit code **0** (`RELEASE_GATE_EXIT=0`). Verbatim coverage lines: `33 feature root(s) grade no Release console write, no content-bearing field; 7 feature event type(s) are payload-graded at every emission site` · `log-safety fixtures: 24 case(s) over 12 rule(s)` · `log-safety coverage self-test: 7 leg(s)` · `✓ coverage-registry — 33 root(s) and 7 event type(s) resolve under ElderlyAssistant/` · `✓ every rule has a positive and a negative fixture, and every fixture behaves` · the seeded violations (console write, content print, unlisted metadata key, text-interpolated event field) each caught **by name**, off-root control quiet. The 7 payload-graded event types: `reply_grammar_flag`, `cloud_chat_fallback`, `cloud_chat_served`, `cloud_chat_voice_control`, `chat_respond_unusable`, `chat_respond_done`, `chat_respond_failed`. | **Done (build-side)** — T-186 §8 recorded the same exit 0 at the sweep; this run re-executed it at the authoring HEAD |
| The gate runs ahead of every test scope | **Build-side:** wired into `ios/build.sh` (`run_tests()` — the guard output heads every scoped run; T-186 §8) | Done (build-side) |
| **Pre-release device console check on the new paths** — a console capture across the DV session (local chat decode, guard flag, escalation attempt, cloud chat success/failure/timeout, consent/revocation, offline fallback) inspected for: utterance text, reply text, transcript, prompt dumps, request/response bodies, key material. Expected **zero occurrences**; only classification fields and the closed event names appear. Inspect → scrub → reference; the raw capture is never pasted into this file (§9) | **Device-side, owner:** runs during the §4 session; captured via §2's console method | **Open — pending the session** |

### 7.6 Appendix — the promoted-v17 row's serve/rollback smoke (T-184's open item; NOT a DV item)

When a **promoted-v17 row exists** (i.e. the full-gate report exists and `chatVariantPromotionRecord` resolves `.promoted`; today it is `.blocked(.gateReportMissing)` — T-184), the session adds this **appendix cell** — additive evidence, never a DV-1..6 substitution:

| Cell | Detail | State |
|---|---|---|
| v17 row serve smoke | Tap the v17 row in the picker: with the placeholder URL, the download fails honestly (no wrong file); once the artifact publishes, the download serves the pinned digest and the row is selectable | **Not applicable yet — entry present but not promoted** (`[OWNER INPUT]` for the run itself) |
| v17 rollback smoke | Flip the pick back to the previous entry: the previous entry serves again with zero chain/router change, no gate re-run (FR-CNR-022's reversibility; design `:776`'s "A/B pick flip + rollback exercised here") | **Not applicable yet — entry present but not promoted** (`[OWNER INPUT]` for the run itself) |
| v17 latency-gate measurement | The chat-latency numbers this DV session produces feed the full-gate report's latency leg (unmeasured today; T-186 §10) — recorded in the gate report, referenced here | **Open — pending the session** |

### 7.7 Honesty notes about this record

- **No device model, OS version, build identifier, measurement or outcome in this file is fabricated.** Where a value does not exist, the cell says it does not exist (`[OWNER INPUT]`). Every DV item is BLOCKED, none is PASS.
- **The simulator and the unit suites are not used as substitutes**, and neither is the T-186 acceptance sweep or any training-box gate. T-186's scoped sweep (716 tests / 30 classes, P0 accepting) and the T-184 v17 evidence are the *wiring* evidence; no row here is filled from them (T-186 §6 names exactly the limits only this session can observe).
- **No item is marked passed, and no incomplete item is dressed up as complete.** The completion claim is blocked until every item carries a PASS from the device session (§8).
- **The §6 fixtures are protocol material.** The chat fixtures are the shipped classifier's own small-talk table, the emergency phrases are the frozen list, the command shapes are the shipped parsers' documented shapes, and the voice-control shapes are the shipped keyword groups — recorded to be reproducible. Real conversation content beyond them is **described**, not transcribed (§9).
- **The known baselines are untouched by this record.** The pre-existing test reds and the T-186 §3 flake remain recorded where T-186 recorded them; none is DV evidence either way.

## 8. The completion gate (FR-CNR-025)

The gate, verbatim from FR-CNR-025's Gherkin (`:36-42`): "Given a DV item that failed or was not executed / When final sign-off is prepared / Then completion is withheld / And the failure or omission is stated explicitly for the owner (FR-CNR-024)". The workflow's line (`:219`): "DV-* device validation on Anzaan is part of the completion gate".

Mechanics:

1. **Only PASS closes an item.** FAIL and BLOCKED both hold the gate. A failed item stays recorded as failing **verbatim with its reproduction steps** (T-187's "not retried away"); the fix is made, the item re-run on the fixed build, and the re-run recorded with the fixed build's identity — the completion claim stays blocked until then.
2. **BLOCKED is the honest session-less state, not a pass.** With no session, the record states DEVICE-VALIDATION-OUTSTANDING — exactly what this authored record does (§7.3).
3. **A failed hard prerequisite stops the session without partial results** (§3): no DV observation is recorded from an unsound session; the DV items stay BLOCKED until step zero passes on a fixed build.
4. **An identity-mismatched session is invalid for the gate** (T-187's failure-path Gherkin): results must name the build they were observed on; a session against a build whose identity does not match the recorded build is recorded as invalid and re-run.
5. **The device console evidence (§7.5) travels with the record** — its device half cannot move until the session runs and the capture is inspected; a content-bearing field found in a log is itself a finding.
6. **Consumers of this protocol:** the workflow's `final-sign-off` (**T2 + HIL**; `workflow.yaml:233`; NFR-CNR-011:15 — "final-sign-off at T2 + HIL records the DV-1..DV-6 results (FR-CNR-025) and the feasibility-honesty statement (FR-CNR-024)") evaluates this record before sign-off can pass; the plan carries it as the device-validation gate (`plan.md:16`).
7. **Missing execution is an open gate item, not a missing deliverable.** The T-187 deliverable is this protocol and its record structure; the run is owner/device-dependent. At final review, an empty record — or any item not PASS — holds final sign-off exactly as a FAIL would.

**Coverage of this unit's Gherkin (T-187 task file `:18-65`):**

| T-187 scenario | Where the protocol satisfies it |
|---|---|
| The protocol and record are prepared (every item has exact steps, expected outcomes and a record slot for pass/fail/blocked; executable in one session without authoring anything on the device) | §6 — DV-1…DV-6 each with verbatim item text, preconditions, exact steps, expected outcome, pass/fail, evidence class and a record template; §5 + §7.2 define the record fields; §4 is the session procedure ("nothing is authored on the device" stated); §2/§3 carry everything the tester needs before touching the phone |
| The session executes the checklist (each item recorded with its observed result in the item's own words; any fail recorded verbatim with reproduction steps — not retried away) | §5/§7.2's per-item Status + Observed + Evidence fields; §6's Steps ARE the reproduction script; §8 mechanic 1 (fail recorded verbatim, fix + re-run on the fixed build) |
| Each item carries its evidence class (DV-1 guard/cloud-chat telemetry classification-only; DV-4 emergency outcomes; DV-5 reminder/alarm at temp 0; DV-6 panel verdict; no unit test as device evidence) | §6's per-item **Evidence class** lines + §1's no-automation-substitutes rule; §9's classification-only telemetry rule ("a content-bearing field in a log is itself a finding") |
| No session available (every item BLOCKED with the reason; completion status device-validation-outstanding) | §7.3 (the BLOCKED table with named dependencies) + the headline + §7.7 — this is the state as of authoring |
| A DV item fails on device (reproduction steps kept, item stays failed, completion gate not marked passed) | §6 per-item Fail criteria + Steps as the reproduction script; §8 mechanic 1 |
| A partial session (executed items carry observed results; the remainder BLOCKED — no inference, no filling in from unit tests) | §5's status vocabulary + §7.2 per-item rows + §7.7's no-substitution note; §8 mechanics 1-2 |
| The build under test is not the built artifact (record invalid for the gate) | §2's identity cells + S0-2 ("a result without recorded build identity is not gate evidence") + §8 mechanic 4 |

## 9. Capture discipline (NFR-CNR-006 / NFR-CNR-007 applied to the record and the captures)

- **This file contains no conversation content beyond the protocol fixtures.** Evidence is a **line key, a label, a count, a yes/no, a latency and a classification token** — never a transcript of the elder's conversation. The §6 fixtures are the design's own material (the shipped classifier's small-talk table, the frozen emergency list, the shipped command/voice shapes) and are the only query-shaped strings permitted; any ad-hoc run-time utterance beyond them is **described**, not transcribed, unless the owner explicitly chooses otherwise.
- **Telemetry is read for classification fields only. A content-bearing field in a log is itself a finding** — recorded as a fail-class finding against NFR-CNR-006/NFR-CNR-007, never pasted into this record. The permitted observables are the closed event names and their classification fields: `reply_grammar_flag` (`path` / `check` / `outcome`), `cloud_chat_served`, `cloud_chat_fallback` (reason token), `cloud_chat_voice_control`, `chat_respond_unusable` / `chat_respond_done` / `chat_respond_failed`, and the pre-existing content-free names (`command_llm_chat`, `command_emergency_keyword`, `model_loaded`, `model_load_denied:*`, `chat_variant_promotion`).
- **No console content is pasted.** If the console is captured, only event names and classification fields go into the record; the raw capture is inspected, scrubbed and referenced (a path or an attachment), never inlined.
- **Copy heard is recorded as line keys** (the shipped `cloud.chat.*`, `chat.safeTemplate.*`, `settings.cloudChat.*` values); the DV-6 verdict is the panel's own words and is recorded **verbatim** — that is the one quoted-content surface this record owns by requirement.
- **The A/B mapping and the listeners are recorded by role**, not by household identity where the identity is not the evidence.
- **The line keys are the evidence, not the audio.** A "reply heard" is recorded as its gist/line key; spoken reply text stays out of the record.

## 10. Recording rules

1. **Every row gets a value or BLOCKED with a reason.** No row is left blank, and no row is filled from a simulator, unit-test or training-gate observation. Every row names the session (date, device, build) it was observed on (§7.1/§7.2), and a result without recorded build identity is not gate evidence.
2. **Measurements and decisions are different columns.** An observed outcome is not a decision to change anything; owner decisions are recorded as such (§7.4).
3. **A failed check is a finding, not a tuning invitation.** Fixing an item is valid only with the observation and the fixed build's identity recorded next to it.
4. **This protocol is not edited to match the results.** Results go in §7. If an item turns out to be unexecutable as written, §7 records that and §6 is updated in a separate, visible edit. The checklist content is DV-1…DV-6 exactly as the constitution and FR-CNR-025 record it — executed as written, not re-interpreted or extended here.
