# family-contacts-unify — DV-1…DV-6 device-validation protocol and record (T-164)

**Feature:** `family-contacts-unify` · **Task:** T-164 (`TG-33 — Acceptance, Evidence and Device Validation`) · **Component:** the FR-FCU-017 device-validation protocol-and-record artifact (the feature's completion gate).
**Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` · **Branch:** `feat/family-contacts-unify` · **Verified against:** `4d4d1e2852717b40e53b294338173cd619439323` ("implement: record T-163 acceptance unit (32/32 sweep green, honest baseline)") — the file's citations and copy were resolved at this tree · **Date:** 2026-10-12.
**Governing requirements:** FR-FCU-017 (`specs/define-requirements/FR/FR-FCU-017-device-validation-completion-gate.md` — the completion gate), FR-FCU-016 (feasibility honesty reporting), NFR-FCU-005 (accessibility / voice-first spot-checks), NFR-FCU-006 (migration compatibility — DV-6 is its on-device measurable), NFR-FCU-009 (release gates and baseline honesty — the log-surface evidence accompanies this record).
**Binding sources of record for the item wording:** the feature constitution's completion gate (`specs/family-contacts-unify/constitution.md:131-138`, DV-1…DV-6 verbatim); FR-FCU-017's description and Gherkin (`:9-42`); `specs/design-l1.md` §17 (`:791` — "Device gate FR-FCU-017: DV-1 … DV-6 on Anzaan, recorded with the feature spec"); the T-164 task file (4 Gherkin scenarios and the DoD checklist).
**Format precedent:** `specs/LCT-device-validation-protocol.md` → `specs/LCT-device-validation-results.md` (the shipped live-camera pair); `specs/SP-device-validation-protocol.md` (merged protocol + record); `specs/MTC-device-validation-protocol.md` (merged; session blocks). This file follows the merged SP/MTC shape — one artifact carrying the protocol *and* the record the owner fills in — because the T-164 task frames it as one artifact ("the DV-1..6 device-validation protocol and record").

> **Headline, stated first because everything below depends on it: no device run has happened.**
> No Anzaan device session was available to this authoring unit (the session is an owner/device-dependent act — T-164 metadata and `specs/plan-tasks/plan.md` risk 6). **Every DV item below is recorded as BLOCKED — not PASS — with the dependency that must clear it** (§7.3). Nothing in this file is a device observation; no simulator or unit-test run fills any row. The feature's completion status is therefore explicitly **“device validation outstanding”** — stated plainly per FR-FCU-016 (honest reporting) and the T-164 Gherkin scenario "No session available". The build-side evidence that exists (T-163's scoped sweep and the log-safety gate, §7.5) is *supporting* evidence and is never a DV item's own result.

> **Deliverable versus gate (read together with the paragraph above).**
> This unit's **deliverable is this protocol and its record structure** — complete when this file exists with DV-1…DV-6, per-item steps / expected outcomes / record slots and the record format, as the T-164 DoD requires. **Executing** the run is owner/device-dependent and did not happen in this authoring task. At the workflow's final sign-off, a missing execution is an **open gate item** — final sign-off cannot pass while the record shows any item not PASS (FR-FCU-017) — not a missing deliverable of this unit.

---

## 1. Why this protocol exists, and what binds it

The feature does three things for the person holding the phone: it links a family contact to the phone's own contact record so the two are ONE person everywhere; it makes the app's first-ever write into the shared address book (the edited contact's photo only); and it matches multiple nicknames/variations — typed or spoken — so the right person is found and called. Unit tests and source pins prove the wiring lives in the build (T-163: 32 scoped suites green, full-bundle run with the baseline recorded). Only a device run proves the feature works for the person holding the phone: a real address book, a real Apple Contacts write, real permission states, a real microphone and STT, and a real pre-change install upgraded in place.

What binds this protocol:

- **FR-FCU-017 — the completion gate.** The feature "**must not** be considered done until the DV-* checklist is executed on the reference device (Anzaan) and recorded with the feature spec". Requirements on the record itself: per item, steps + expected outcome + an observed result; "each item is recorded as passed/failed with evidence (session notes, screenshots, log pulls) attached to the feature spec; a failure blocks final sign-off until fixed and re-run — **no silent waiver**". The Gherkin adds the failing scenario: "Given any DV item fails (e.g. the linked person still appears twice) … Then the feature does not pass final sign-off / And the failure is fixed and the item re-run before sign-off proceeds."
- **FR-FCU-016 — honesty.** "A partially infeasible sub-capability … is reported as a bounded behavior with its honest fallback — neither dropped nor overstated." An unexecuted checklist is reported as BLOCKED with its dependency named; the feature does not claim the asks demonstrated on the device until this record says so.
- **NFR-FCU-005 — accessibility spot-checks ride the DV items.** The nickname call completes voice-only with zero touch; the new controls hold house touch/text standards; the elderly user's surfaces never show authorization reasoning. The spot-checks live inside the DV items that touch those surfaces and are recorded as observed.
- **NFR-FCU-006 — migration on a real install.** "DV-6 executed on-device on an upgrade over an existing install" is the requirement's own measurable; the unit fixtures (`FamilyContactStoreTests`) are the supporting half, never the substitute.
- **The workflow's final gate.** The `final-sign-off` comment (`.ai-sdd/workflows/family-contacts-unify.yaml:213`, mirrored in `specs/family-contacts-unify/workflow.yaml`) reads "DV-* device validation on Anzaan is part of the completion gate". §8 states the gate mechanics.
- **No automation substitutes.** The simulator has no Apple Contacts write against the user's real address book, no real permission states across launches, no real STT/microphone path, and no pre-change install to upgrade. No simulator observation may fill any row. The scoped suites' green (T-163) is the *wiring* proof; this record is the *behaviour* proof.
- **The unmet-item rule.** Only PASS closes an item. FAIL and BLOCKED both hold the completion gate; deviation requires explicit owner resolution.

**Interaction note (attribution honesty).** The voice path of DV-2 runs through the call-confirmation seam that `call-dialer-primary-secondary` also touches (merged to master at `81de796a`, merged into this branch at T-144). That feature's own DV-1…DV-7 are outstanding (`specs/final-sign-off.md`, call-dialer record). If a DV-2 step fails on the device, record whether the failure is in the nickname resolution (this feature) or the channel/confirmation layer (call-dialer), with the observed line — never assume, never cross-attribute.

## 2. Environment and build identity

Recorded for reproducibility; a measurement without a device and a build is not reproducible (the LCT precedent's recording rule 1). Values marked `[OWNER INPUT]` do not exist yet and are **not invented here** — a cell that has no value says so.

| Field | Value |
|---|---|
| Reference device | **the Anzaan reference device** (named by the feature constitution and FR-FCU-017). Last recorded observation of this device (MTC/voice-OOM investigations, 2026-10-10): iPhone 14 Pro Max, 6 GB class, iOS 26.6.2 beta 23G90 — **not re-asserted here**; `[OWNER INPUT — confirm model + OS version actually installed at run time, e.g. Settings ▸ General ▸ About]` |
| Build configuration | **Release** is the house pre-release discipline and the configuration the log-surface device check (§7.5) names. No DV item below is performance-natured, so a Debug observation is *recordable* — but it is recorded **as Debug** and never substituted for a Release reading where the item's nature requires one. `[OWNER INPUT — the configuration actually installed]` |
| Build identity — commit | `[OWNER INPUT — git rev-parse HEAD in this worktree at build time]`. The authoring baseline (this file) is `4d4d1e2852717b40e53b294338173cd619439323`; the tested build must be at least this commit |
| Build identity — bundle id / version | `[OWNER INPUT — CFBundleIdentifier + CFBundleVersion, read from the built artifact]`. The app's bundle id is `ai.voicebridge.senior.assistant` (`ios/project.yml:247`); it has been rebranded once and Anzaan has previously carried more than one installed build of the app — **derive the id from the artifact, never from memory** (the `device-install.sh` recipe, `ios/device-install.sh:52-60`; the CoreDeviceError 10002 class) |
| Build produced by | `[OWNER INPUT — e.g. `cd ios && DEVELOPMENT_TEAM=<team> ./build.sh build` (signed **Release** build for a real device, `ios/build.sh:162-195`), or `./build.sh ipa` (archives Release, `ios/build.sh:216-233`), or `./device-install.sh` (convenience: builds **Debug** and installs — record the configuration used)]. The merged tree builds — T-144's merge gate recorded build-green (`6c743f32`) and T-163 swept at `4d4d1e28` |
| Install method | `[OWNER INPUT — `xcrun devicectl device install app --device <name> <built .app>` / Xcode Devices / TestFlight / device-install.sh]. **An upgrade install (no delete) preserves the app container** — required for DV-6's migration ordering (§6 DV-6); for any other item it is the default |
| Tester (holds the phone) | `[OWNER INPUT]` |
| Run date(s) | `[OWNER INPUT]` |
| App language under test | The owner's normal configuration — Nepali (`ne`) is the app's launch language (project constitution Architecture Constraint 6); the DV-2/DV-5 fixtures are Devanagari forms and need it. `[OWNER INPUT — record the app/device language actually set]` |
| Contacts access state at start | `[OWNER INPUT — allowed / notDetermined / denied / limited; the wizard's point-of-use ask sets it, and iOS Settings ▸ Privacy & Security ▸ Contacts changes it for DV-4]` |
| Console capture (for §7.5's device check) | `[OWNER INPUT — method, e.g. `xcrun devicectl device process launch --console --device <name> ai.voicebridge.senior.assistant`; only content-free event names/fields may be quoted into this record — §9]` |

## 3. Prerequisites (owner action; checked before the session starts)

| # | Prerequisite | Detail | State as of authoring |
|---|---|---|---|
| 1 | **An Anzaan device session** | The reference device, unlocked, on charge, with the owner present for permission dialogs (the contact-permission prompt and the iOS Settings toggles). | **Not available to this unit** — every DV item is BLOCKED on this (§7.3) |
| 2 | **The merged tree builds** | Satisfied at authoring: T-144 merged master (call-dialer) and recorded build-green; T-163's scoped sweep (32 suites) and the full bundle ran at the authored HEAD. The DV session still records its own build identity (§2). | Satisfied (evidence: `specs/T-163-acceptance-notes.md` §1/§3) |
| 3 | **A system contact to link** | One contact in the phone's address book the owner is willing to link (the person's real record), plus the spelling differences used by the DV legs (a book-side name spelled differently from the family record is ideal). | `[OWNER INPUT — chosen at run time; record by role, not by name, where it is real household data (§9)]` |
| 4 | **A second system contact** | For DV-2's ambiguity leg (temporarily sharing a nickname) and DV-1's duplicate-link refusal leg. | `[OWNER INPUT]` |
| 5 | **A distinctive test photo** | A photo that cannot be confused with the contact's current one (e.g. a solid-color square), for DV-3/DV-4. Use a test image, not a personal photo. | `[OWNER INPUT]` |
| 6 | **Permission states reachable** | The owner can flip Contacts access to **off (denied)** and (iOS 18+) **Limited Access** in Settings ▸ Privacy & Security ▸ Contacts, and back to allowed — DV-4 needs both fallback states, and the state is restored afterwards. | `[OWNER INPUT]` |
| 7 | **A pre-change install for DV-6** | Route (a), preferred: the device's current install is a build **before** this feature and carries the owner's real family contacts (one with a single nickname). Route (b), staged: install a pre-change build (master tip `81de796a` or the last shipped build) and create the migration fixture on it. **DV-6 must run before any feature-build install rewrites the store, or as its own staged session** — see DV-6's preconditions. | `[OWNER INPUT — route (a) or (b) at run time; record which]` |
| 8 | **The four permission-dialog moments** | The system contacts prompt shows the frozen `NSContactsUsageDescription` copy (`ios/ElderlyAssistant/Info.plist`, verified at authoring, quoted in DV-3) — the owner allows or denies it deliberately per item. | `[OWNER INPUT]` |

## 4. How to run this (owner procedure)

Written so a person holding the phone can execute it without this document's author present (the LCT/SP rule). Say every utterance **once per repetition**, wait for the spoken outcome, and touch the screen only where a step says so.

1. **Check §3.** Anything missing records its item BLOCKED with the dependency named — never a guess, never a partial pass.
2. **Build and install** (§2). Record commit, bundle id/version, configuration, install method. Prefer the Release build; `./device-install.sh` is the quick Debug path (it derives the bundle id from the artifact and installs over the existing app — container preserved).
3. **Order:** run DV-1 → DV-2 → DV-3 → DV-5 → DV-4 → DV-6 (§6). DV-4 leaves the contacts permission denied/limited — it restores the state in its own last step. DV-6 is last because it stages a pre-change install and upgrades over it; **if the device's pre-change install still carries the real pre-feature store, run DV-6's pre-check before DV-1 saves anything** (a save rewrites the whole store in the new format — §6 DV-6 preconditions).
4. **Run each item literally, from its preconditions**, in one session where possible. The item text is the constitution's (§6, verbatim); the steps below it are the executable form. Do not substitute your own reproduction.
5. **Write results into a session block in §7.2, in the same change** — status (PASS / FAIL / BLOCKED), the observed result (line keys, labels, counts, yes/no — §9), and the evidence pointer. The protocol text of §6 is **not** edited to match results (recording rule 4, §10).
6. **A failed item stays recorded as failing.** Fix the build, re-run that item on the fixed build, record the fixed build's identity in the re-run's session block. Only PASS closes an item (§8).
7. **Capture the §7.5 device console** across the session (the release-build log-surface check that accompanies this record): inspect, scrub, reference — never paste raw lines (§9).
8. **After the session:** keep this file as the record; the final-sign-off step consumes it — the T2 human gate cannot pass while the record is empty or any item is not PASS (§8).

## 5. Record fields (defined per item; the format the owner fills)

For every session (§7.2), one appended block carrying:

- **Session-level fields** (they qualify every item row in the block): **date**; **device** (model + OS); **build** (commit + `CFBundleIdentifier`/`CFBundleVersion` + configuration); **contacts access state at start**; the **§7.5 console-capture reference**.
- **Per-item fields**, one row per DV item:
  - **Status** — PASS / FAIL / BLOCKED (no other value; see the vocabulary below).
  - **Observed result** — what was actually seen/heard: line keys and labels, counts of rows/tiles, the confirmation's named person and whether the dial target matched, yes/no answers. Never a transcript of household data (§9).
  - **Evidence** — the pointer(s): screenshot reference, session note, captured line key, log-pull/container reference. Test-fixture strings may be recorded; real household names/numbers are recorded by role (§9).
- **Notes / deviations / tester.**

**Status vocabulary:** **PASS** / **FAIL** / **BLOCKED** (BLOCKED only with the dependency named). No other value is valid; no value is written before the observation exists. **Only PASS closes an item** — FAIL and BLOCKED both hold the completion gate (§8).

## 6. The DV items (the protocol)

Each item carries its **verbatim item text** from the feature constitution (`specs/family-contacts-unify/constitution.md:133-138`; the same list is repeated in FR-FCU-017 and DV-1…DV-6 there) — not paraphrased — then sources, preconditions, exact steps, expected outcome, pass/fail criteria, the NFR-FCU-005 spot-check where one belongs to the item, and the per-item record slot. Quoted UI copy is the shipped `ne`/`en` catalog values (`ios/ElderlyAssistant/Resources/Localizable.xcstrings`); record a **line key / label**, never a household transcript (§9).

### DV-1 — Link: the person appears ONCE in search and in the call list

- **Item text (verbatim, feature constitution):** "DV-1 — Link: link a system contact as a family contact → the person appears ONCE in search results (matched AND unmatched queries) and in the call list."
- **Source of record:** constitution DV-1; FR-FCU-017; FR-FCU-001/003/004/005 (link, dedupe, one person, unlink); design-l1 §6/§7 (link identity; dedupe rules Pass 1–5) and §7.3 (the surface audit); design-l2 §2.2 (find step), §2.7 (family list chip).
- **Preconditions:** the §2 build installed; contacts access allowed (the wizard's ask card, or iOS Settings); the §3.3 system contact chosen; the family list states the expected "before" picture (the person may already exist as a manual family contact or is about to be added).

**Steps**

1. Note the "before" state: the family list (Settings ▸ tab **Family / परिवार** ▸ row **Family and friends / परिवार र साथीहरू**) and the Phone screen (Home hub tile **Call / फोन**, screen title **Make a call / फोन गर्नुहोस्**).
2. Add the person with the link: **Add contact / सम्पर्क थप्नुहोस्** → step 1 **Find the contact / सम्पर्क खोज्नुहोस्**. If the allow card shows, tap **Allow contacts access / सम्पर्कहरूको पहुँच दिनुहोस्** and allow the system prompt.
3. Type the person's name in **Search contacts / सम्पर्क खोज्नुहोस्**; tap the phone-book row for the person. The fields prefill and the link area (heading **Phone contact / फोन सम्पर्क**) shows **Linked to `<book name>` / `<book name>` सँग जोडिएको** plus **Remove link / लिंक हटाउनुहोस्**.
4. Continue through Relationship → Photo → Messenger → Nickname (the nickname step is where the person's variations are recorded — keep the ones used by DV-2/DV-5) and tap **Save / राख्नुहोस्**.
5. In the family list, confirm the linked row now carries the **Linked / जोडिएको** chip (one row for the person).
6. Search leg (a) — matched query, family-side name: Phone screen → **Search contacts / सम्पर्कहरू खोज्नुहोस्** → field **Search all contacts / सबै सम्पर्कहरू खोज्नुहोस्** → type the person's family-side name. Count the rows for the person: expected **exactly one** (the family row, **Family / परिवार** chip). Repeat with the person's number typed in a *different spelling* than the family record stores (e.g. without spaces or country code): still **exactly one** row (design-l1 §7.1 Pass 3 correctness note — dedupe by identifier, not number equality).
7. Search leg (b) — unmatched query, book-side-only spelling: type the spelling that exists only in the phone book (the book contact's name as stored in Contacts, different from the family record's). Expected **exactly one** row: the family row with the caption **Also in your phone book as `<book name>` / फोनबुकमा `<book name>` को रूपमा पनि छ**; the separate book row is **gone**.
8. Search leg (c) — no match: type a string matching nobody. Expected: no row for the person (no phantom row); the honest empty state (**No one found… / कोही भेटिएन…**).
9. Call-list leg: exit search (back button or clear the field). The family-tiles area (the call list) shows **exactly one tile** for the person.
10. One-person integrity leg: start a second **Add contact**, search the *same* system contact, and tap it. Expected: the steering card **`<book name>` is already a family contact. / `<book name>` पहिले नै परिवारको सम्पर्क हो।** with an edit button — **no second link is created, no second family record results**; close the sheet.
11. Optional (state restore): leave the link in place for DV-3; nothing else to restore.

- **Expected observable outcome:** one family row for the person in the family list and the call tiles; exactly one search row per query class (matched, book-side-only, number-spelling); the synthesized row explains itself with the phone-book caption; the duplicate-link attempt is steered, not absorbed.
- **Pass criteria:** every count above is exactly one where the item says ONCE; the book-side row never renders beside the family row; the caption appears on the synthesized row and only there; no crash; the linked chip is present after Save.
- **Fail criteria:** two rows for one person for any query (the item's named failure — "the linked person still appears twice"); the book row surviving beside the family row; the number-spelling query producing two rows; the duplicate-link attempt creating a second record; a crash.
- **Accessibility spot-check (NFR-FCU-005):** in the find step, every interactive control (result rows, the link area's Remove-link control, Next/Save) meets ≥ 44×44 pt, and the screen renders without clipping at the device's default text size (repeat at Accessibility XXXL if the owner is in that setting). Record what was observed.
- **Evidence to capture:** row counts per query class (with the queries' *class* named — family-side name / book-side spelling / number spelling / no-match), the caption seen, the chip seen, the steering card seen, the tile count, a screenshot of the family row + search results if the owner accepts attaching it.
- **Record template:** `Status: PASS / FAIL / BLOCKED — <counts + labels> | Evidence: <…>`
- **Record as:** the DV-1 row of the session block (§7.2).

### DV-2 — Voice: "call `<nickname>`" reaches the right person; ambiguity never silently dials

- **Item text (verbatim, feature constitution):** "DV-2 — Voice: "call `<nickname>`", including a Devanagari variation, reaches the right person; an ambiguous nickname never silently dials a wrong person (disambiguation, not a guess)."
- **Source of record:** constitution DV-2; FR-FCU-017; FR-FCU-013 (nickname voice resolution) and FR-FCU-014 (ambiguity safety, verbatim: "the system reports ambiguity and asks which person … no call is placed until the choice is resolved"); design-l1 §8.3 (voice bands; ambiguity margin 0.15; "ties are ambiguity, not order") and §8's linked-twin note; `DeterministicCallRoute` (name extraction), `AppCoordinator.requestCallConfirmation` (the seam), `ContactResolver`.
- **Preconditions:** DV-1's link in place (or any family contact with recorded nicknames); the contact carries at least **two Devanagari variations** recorded as nicknames (e.g. the spoken form and the ASR-shaped variant — record the fixture strings; §9 permits test fixtures); a second family contact exists for the ambiguity leg; the phone is **not** in a call; the owner ready to answer by voice.

**Steps**

1. Record the fixture nicknames on the contact (Settings → the row → Edit → **Nickname / उपनाम** step → **Add a name or variation (e.g. sanu, सानु) / नाम वा अर्को रूप थप्नुहोस् (जस्तै sanu, सानु)** → **Add / थप्नुहोस्** → Save). Note the exact strings — they are the legs' utterances.
2. Leg (a) — the first Devanagari nickname: say **"<nickname1>लाई फोन गर"** (e.g. "सानुलाई फोन गर"; the elder's natural dative form — the extractor strips "लाई फोन गर", so the name candidate is the nickname itself). Expected: the spoken confirmation **"`<contact name>` लाई फोन कल गर्ने हो?"** (`router.call.confirmQuestion`) — the **stored name** of the right person, not the nickname, not a wrong person.
3. Answer **by voice** — say **"हो"** (yes). Expected: **"ठिक छ, `<contact name>` लाई कल गर्दैछु।"** (`router.call.calling`) and the call UI opens on that person's number; **no touch was used anywhere in the flow**. Cancel the call in the call UI right after the target is confirmed if the owner prefers not to ring the family — record which.
4. Leg (b) — the Devanagari variation: say **"<nickname2>लाई फोन गर"** (the second recorded variation, e.g. "स्यानुलाई फोन गर"). Expected: the same right person's confirmation as leg (a); no "not found", no wrong person. (If the ASR returns a spelling that is NOT recorded, the honest outcomes are the near-miss disclose **"मैले `<heard>` लाई सम्पर्कमा भेटिनँ। के तपाईं `<proposed>` भन्न खोज्नुभएको हो?"** (`router.call.didYouMeanPrefix`) plus the confirmation, or `router.call.contactNotFound` — record which spelling the STT produced; the fixture legs are the recorded spellings.)
5. Leg (c) — ambiguity: temporarily add the SAME nickname (nickname1) to a **second** family contact. Say **"<nickname1>लाई फोन गर"**. Expected: the disambiguation line **"`<nameA>, <nameB>` भनेर धेरै जना भेटिए। कृपया पूरा नाम भन्नुहोस्।"** (`router.call.disambiguate`) — **no confirmation question, no dial** (check the phone did not start a call / recents unchanged). Then say the full name of the intended person → the normal confirmation naming that person (§FR-FCU-014: "the finally chosen person is the one dialed"). Remove the temporary nickname afterwards (restore the state).
6. Note whether the transcript visible on screen (if any) matches what was spoken and whether the STT produced the recorded spelling — the STT engine is the invariant of every change (a transcript regression cascades into resolution; record, don't fix on the spot).

- **Expected observable outcome:** a nickname — including a Devanagari variation — resolves to the right person through the ordinary confirmation; an ambiguous nickname produces the disambiguation line and **zero dials**; the flow completes with zero touch.
- **Pass criteria:** the confirmation names the right person in both leg (a) and leg (b); the spoken "हो" completes the call to the right target (dial target matches the contact's number: yes/no — never transcribe the number); the ambiguity leg dials nothing and asks; the resolved name leg then confirms the right person; no crash; no silent wrong-person dial anywhere.
- **Fail criteria:** a wrong person named or dialed; the ambiguity leg producing a confirmation question or a dial; the nickname not resolving though recorded; a touch required to complete the flow (NFR-FCU-005 scenario 1); silence; a crash; the wrong person after the full-name answer.
- **Accessibility spot-check (NFR-FCU-005):** the zero-touch leg is itself the spot-check (record: touches used = 0); where the on-screen transcript/confirmation card is displayed, its text is legible at the device's text size (record).
- **Evidence to capture:** per leg — the utterance class (nickname1 / nickname2 / ambiguous / full name), the line key and the named person ("right person: yes/no" against the fixture), whether the call was placed or cancelled after a correct target, dial-target-matches yes/no, touches used (expected 0), and the STT-produced spelling of the nickname (record the string when it is a test fixture).
- **Record template:** `Status: PASS / FAIL / BLOCKED — <per-leg lines + target match + touches> | Evidence: <…>`
- **Record as:** the DV-2 row of the session block (§7.2).

### DV-3 — Photo write: the app updates the system contact; the display reflects the system contact

- **Item text (verbatim, feature constitution):** "DV-3 — Photo write: setting a photo in the app updates the system contact when permission allows; the photo displayed in the app reflects the system contact."
- **Source of record:** constitution DV-3; FR-FCU-017; FR-FCU-007 (display precedence) and FR-FCU-008/009 (the confined write, authorization at point of use); design-l1 §9 (the write seam; read-back verification), §10.1/§10.2 (precedence; save sequencing), §10.3 (the `.written` row); design-l2 §1.5 (outcome→UI mapping), §2.4 (photo step), §2.6 (save flow), §4.5 (foreground refresh); F4 (the `.written` label is `family.photo.state.updatedInSystem`).
- **Preconditions:** DV-1's link in place and **verified** (the family row shows the Linked chip); contacts access **allowed** (full); the §3.5 test photo available in Photos; the owner can open the iOS Contacts app.

**Steps**

1. Note the "before" state in the iOS **Contacts** app: open the person's card and note whether it has a photo and which one.
2. In the app: Settings ▸ Family ▸ Family and friends → open the person (Edit). The editor opens at **Relationship / नाता**; tap **Next / अर्को** to the **Photo / फोटो** step.
3. Tap **Change photo / फोटो परिवर्तन** (or **Add photo / फोटो थप्नुहोस्**) and pick the test photo.
4. If the ask card appears (**"Update this person's photo in your phone's contacts? / यो व्यक्तिको फोटो फोनको सम्पर्कमा पनि अपडेट गर्ने हो?"** with **Allow contacts access / सम्पर्कहरूको पहुँच दिनुहोस्**), tap Allow; the system prompt shows the frozen `NSContactsUsageDescription` copy ("Searching from the phone screen can call anyone in your phone book … When you set a photo for a family contact who is also in your phone book, the app can save that photo onto the person's contact card if you allow it; it changes nothing else. The app works fully even if you say no.") — allow it. (Record: the system prompt's text matched the frozen copy: yes/no.)
5. Tap **Next** twice to the **Nickname / उपनाम** step, then **Save / राख्नुहोस्**. The sheet **stays open on the photo step** and shows **"Photo updated in your phone's contacts. / फोटो फोनको सम्पर्कमा अपडेट भयो।"** (`family.photo.state.updatedInSystem`; the primary button is now **Close / बन्द गर्नुहोस्**). Tap Close.
6. Verify the system side: open the same person's card in the iOS Contacts app — the photo is the picked test photo (identical image).
7. Verify display precedence in the app: reopen the person's editor — the preview shows the photo and the caption **"Shown from your phone's contacts. / फोनको सम्पर्कबाट देखाइएको।"** (`family.photo.sourceSystem`) renders under it; the family-list row / call tile shows the same face.
8. Display-follows-system leg: in the iOS Contacts app, change that contact's photo to a **different** image; return to the app (the foreground hook invalidates and re-reads); reopen the editor / the family list — the displayed photo is now the **new system photo** (and the source caption still shows). This is the "displayed photo reflects the system contact" half.
9. Check the app-local copy was not lost: the picked photo from step 3 remains the app-local fallback (observable in the editor's state and in the app's own storage behavior — the design persists the JPEG app-local in the same save); no crash at any point.

- **Expected observable outcome:** Save → `.written` → the honest success label; the Apple Contacts card carries the picked photo; the app displays the system photo (with `family.photo.sourceSystem`) and follows a later system-side change on foreground.
- **Pass criteria:** the system card is updated with the picked photo; the in-app preview/tile shows the same photo with the source caption; after the external change, the app shows the new system photo; the success label was shown exactly once; no crash; the app-local photo was never lost.
- **Fail criteria:** a success claim with no system-card change; the card updated with a different image; the app not reflecting the system photo; a crash; the picked photo lost; the label absent while the write happened (or vice versa).
- **Accessibility spot-check (NFR-FCU-005):** the photo step's controls (Change/Add/Remove photo, the allow button, Next/Save/Close) are ≥ 44×44 pt and their labels render without clipping at the device's text size; the success label is readable. Record what was observed.
- **Evidence to capture:** the label line key seen; system card updated yes/no; in-app photo + source caption seen yes/no; display followed the external change yes/no; the system prompt matched the frozen copy yes/no; the tap-target/clipping observation.
- **Record template:** `Status: PASS / FAIL / BLOCKED — <label key + card updated + display followed> | Evidence: <…>`
- **Record as:** the DV-3 row of the session block (§7.2).

### DV-4 — Fallback: no-write states leave the photo app-local, honestly, with no loss and no crash

- **Item text (verbatim, feature constitution):** "DV-4 — Fallback: with write access denied/limited (or a read-only system contact), the photo stays app-local as today, honestly surfaced — no loss, no crash."
- **Source of record:** constitution DV-4; FR-FCU-017; FR-FCU-010 (the non-writable fallback) and FR-FCU-009 (honest authorization states); design-l1 §9.3 (detected, not assumed), §10.3 (the fallback state machine, including `.notInGrantedSelection` and `.failed(.saveRejected)` rows), §10.1 (degradation never blanks a tile); design-l2 §1.5 (total mapping), §2.4 (the denied line; limited renders no card); NFR-FCU-005 (no authorization reasoning on the elderly user's surfaces).
- **Preconditions:** DV-3's linked, verified contact with a working photo path; the owner can flip contacts access in iOS Settings; a **second** distinctive test photo (different from DV-3's) to observe the fallback's persistence; iOS 18+ for the limited leg (the reference device is well past that).

**Steps (legs (a) and (b); leg (c) optional)**

1. **Leg (a) — denied.** iOS Settings ▸ Privacy & Security ▸ Contacts ▸ the app (Elderly Assistant) → **Off**. Return to the app (the foreground hook re-reads access).
2. In the app: open the linked contact's editor → Photo step. The denied line **"Contacts access is off, so the photo will be kept in this app only. You can change this in iPhone Settings. / सम्पर्कको पहुँच बन्द छ, त्यसैले फोटो यही एपमा मात्र रहन्छ। ताईं आईफोनको सेटिङमा यो बदल्न सक्नुहुन्छ।"** shows with the Open Settings button — **no prompt is raised, no nag**.
3. Set the second test photo (Change/Add photo → pick) → advance → **Save**. The sheet stays open and shows **"Kept in this app only. / यही एपमा मात्र राखिएको।"** (`family.photo.state.keptOnPhone`) with the denied explanation beside it (`family.photo.accessDeniedBody`). Tap Close.
4. Verify no loss: reopen the editor / the family list — the second test photo is displayed (from the app-local store).
5. Verify no false write: the person's card in the iOS Contacts app is **unchanged** from DV-3's end state (the picked photo did not land; no partial mutation of any field).
6. Verify the elderly user's surface: on the Phone screen, the person's tile shows the photo and **no** authorization explanation, dialog or failure state appears anywhere outside the family member's editor (NFR-FCU-005 scenario 3).
7. **Leg (b) — limited.** iOS Settings ▸ Privacy & Security ▸ Contacts ▸ the app → **Limited Access**, and ensure the linked system contact is **not** in the allowed selection. Return to the app; repeat steps 3–6 with a third pick if the editor shows the picked-photo state. Expected: the same **Kept in this app only** label (the attempted fetch fails → `.notInGrantedSelection` → the same honest fallback), app-local persistence, unchanged system card, no crash.
8. **Leg (c) — read-only record (optional, only if a read-only system contact can be produced).** If a read-only contact exists (e.g. a card synced from a read-only account), link it and set a photo: expected the same **Kept in this app only** fallback through `.failed(.saveRejected)`. If no such record can be produced, record "not available" — the denied and limited legs are the item's executable evidence; the save-rejected mapping is unit-pinned (`SystemContactPhotoWriterTests`), never invented on device.
9. **Restore:** set Contacts access back to **Allow** (full) in iOS Settings, return to the app, and confirm search/write behavior is normal again (the states were only for this item).

- **Expected observable outcome:** in both no-write states the picked photo stays app-local with the honest label, the system card is untouched, the photo is never lost, nothing crashes, and the elderly user's surfaces show no authorization reasoning.
- **Pass criteria:** leg (a) and leg (b) each: honest label shown; the photo persists in-app; the system card unchanged; the app continues working (search, display, tiles) after the fallback; no crash; the parent-facing surface clean.
- **Fail criteria:** the picked photo disappearing (loss); a success claim in a no-write state; the system card mutated; a crash; the photo step prompting repeatedly (nagging); the authorization state shown on the parent's surfaces; the write attempt producing a partial mutation.
- **Accessibility spot-check (NFR-FCU-005):** as in step 6 — the parent's surfaces show the photo/initials only, with no permission text; the editor's Open-Settings control is ≥ 44×44 pt. Record what was observed.
- **Evidence to capture:** per leg — label key seen, photo persisted yes/no, system card unchanged yes/no, crash no/yes, parent-surface clean yes/no; the read-only leg's availability.
- **Record template:** `Status: PASS / FAIL / BLOCKED — <per-leg label + persistence + card unchanged> | Evidence: <…>`
- **Record as:** the DV-4 row of the session block (§7.2).

### DV-5 — Search: the name and every recorded nickname/variation find the single linked row

- **Item text (verbatim, feature constitution):** "DV-5 — Search: querying by name and by each recorded nickname/variation (Devanagari included) finds the single linked row."
- **Source of record:** constitution DV-5; FR-FCU-017; FR-FCU-012 (nickname matching in search); design-l1 §8.1 (the `.nickname` tier between `.relationship` and `.containment`), §8.2 (normalization reuse; the Devanagari pin — behavior is *pinned*, not "fixed"), §7.1 Pass 1/3 (nickname-widened family matches; the linked pair still yields one row); T-152/T-151 evidence (supporting).
- **Preconditions:** DV-1's link in place and verified; contacts access allowed (the book half of search needs it; the family half does not — record the state used); the contact's recorded variations known (from DV-2/DV-1): at least one Devanagari nickname and, if recorded, a romanized one.

**Steps**

1. On the Phone screen, enter search (**Search contacts / सम्पर्कहरू खोज्नुहोस्**; field **Search all contacts / सबै सम्पर्कहरू खोज्नुहोस्**).
2. Query the person's **stored name** → exactly one row (the linked row; Family chip).
3. Query each **recorded nickname/variation in turn** — including the Devanagari form(s), typed exactly as recorded, and the romanized form if one is recorded ("sanu" and "सानु" are distinct spellings unless both are stored — each is its own query) → **each query finds the same single linked row**.
4. For each hit, note the row's identity: the same person, the family chip, and — where the query matched the book side — the phone-book caption (DV-1's leg (b) behavior, not repeated here).
5. Negative control inside the item's own discipline: a variation that was **not** recorded must not silently match (e.g. a different transliteration) — record whether the row appears (the store-as-entered rule; a match here would be a finding).
6. Tap one of the found rows once and confirm the action leads to the SAME person (the call card/confirmation naming them) — then dismiss without calling (this is the row's actionability, not a call test).

- **Expected observable outcome:** the stored name and **each** recorded variation each produce the single linked row; an unrecorded spelling does not match.
- **Pass criteria:** every recorded query (name + each variation, Devanagari included) yields exactly one row for the person; the row is the linked family row; the unrecorded spelling does not match; the row's action targets the same person; no crash.
- **Fail criteria:** any recorded variation not matching; two rows for a query; an unrecorded spelling silently matching a different person's row; a row targeting a different person; a crash.
- **Accessibility spot-check (NFR-FCU-005):** record whether the search field and result rows are usable at the device's text size without clipping (repeat at Accessibility XXXL if that is the owner's setting).
- **Evidence to capture:** per query (name / variation 1 / variation 2 / unrecorded control): row count and the row's identity ("same person: yes/no"); the Devanagari character sequence of each recorded variation as typed (fixture strings only, §9); tap-target/legibility observation.
- **Record template:** `Status: PASS / FAIL / BLOCKED — <per-query row counts + identity> | Evidence: <…>`
- **Record as:** the DV-5 row of the session block (§7.2).

### DV-6 — Migration: a pre-change install loads; the pre-change single nickname still matches

- **Item text (verbatim, feature constitution):** "DV-6 — Migration: an existing install's pre-change payloads load; the pre-change single nickname still matches."
- **Source of record:** constitution DV-6; FR-FCU-017; FR-FCU-011 (nickname storage + migration; the single `nickname` migrates into the multi-nickname structure without loss); FR-FCU-002 (link field migration); NFR-FCU-006 ("DV-6 executed on-device on an upgrade over an existing install"); design-l2 §3.3/§3.4 (encoder/decoder contracts — the legacy key is read, never written; corrupt shapes degrade to nil, never a failed read); T-145's decoder + T-163's `FamilyContactStoreTests` legacy fixtures (supporting pins, never the substitute).
- **Preconditions (read fully — the ordering is the item's crux):**
  - **Route (a) — natural, preferred:** the device's current install is a build **before** this feature and carries the owner's real family contacts. Then the migration event is the feature build's **first install over it**. If any DV-1…DV-5 save has already run on the feature build, the store was rewritten in the new format and the pre-change payloads are gone from the device — the pre-change single nickname can no longer be the migrated one; record that and take route (b).
  - **Route (b) — staged:** install a pre-change build (master tip `81de796a`, or the last shipped build) over the current install (an upgrade install preserves the container; a delete would wipe it — avoid), then on that build create/keep the migration fixture: at least one family contact **with a single nickname** (via that build's wizard Nickname step) and a photo; relaunch to confirm the store persists.
  - Record which route was used. The pre-change build's commit/bundle id/version is part of the evidence.
- **Steps**
  1. On the pre-change build: list the family contacts (Settings ▸ Family ▸ Family and friends) — record the count and, by role, which contact carries the single nickname (record the fixture nickname string itself — it is the test's fixture; real household names by role only, §9).
  2. (Optional but strong) Capture the pre-change payload shape: download the app container (Xcode ▸ Window ▸ Devices and Simulators ▸ the device ▸ the app ▸ Download Container) and note the store file contains the pre-change `nickname` key. Keep the container out of the repo; record the observation, not the file.
  3. **Install the feature build over the pre-change install** (no delete — upgrade install; `xcrun devicectl device install app` preserves the container). Record commit/bundle id/version (the §2 fields).
  4. Launch. Review the family list: **all** pre-change contacts are present — same count, same names by role, the photo preserved; nothing missing, nothing crashed, no empty store.
  5. The migrated nickname: on the Phone screen's search, type the **pre-change single nickname** → the contact is found (the nickname migrated into the multi-nickname structure — matching in the `nickname` tier; one row, linked if the contact was linked). Record the row found yes/no.
  6. Voice: say **"<the pre-change nickname>लाई फोन गर"** → the ordinary confirmation naming that person (no "not found", no wrong person); cancel after the target is confirmed if the owner prefers; no crash.
  7. Save-touch check: open the migrated contact's editor, make one benign no-op edit (or re-save the same data) → Save → reopen → everything is intact (a load→save→load round-trip on device: all fields preserved — name, number, relationship, the nickname, the photo). Record the preservation check.
  8. Note the state: the pre-change payload test is one-way (after step 7 the store is new-format); the evidence is collected — do not re-run the item hoping for a different result without a fix + a fresh staged fixture.

- **Expected observable outcome:** the new build reads the pre-change store with zero loss (contacts load; the single nickname still matches in search and voice); the round-trip preserves every field.
- **Pass criteria:** full contact count before/after; the pre-change nickname matches in typed search **and** voice; no contact missing; no decode failure (no empty/reset store); the re-save round-trip preserves all fields; no crash.
- **Fail criteria:** any pre-change contact missing or altered; the single nickname not matching in search or voice; a store read failure; a crash; a field dropped on the round-trip.
- **Accessibility spot-check:** not item-specific — the migrated contact's row/editor render as every other (record only if something deviates).
- **Evidence to capture:** route (a)/(b) with the pre-change build identity; contact count before/after; the fixture nickname string (test fixture) found-in-search yes/no and voice-confirmed person yes/no; the round-trip preservation check; the optional container-observation note; the fixed build's identity if the item was re-run.
- **Record template:** `Status: PASS / FAIL / BLOCKED — <route + counts + nickname found search/voice + round-trip> | Evidence: <…>`
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
- **Build:** `[OWNER INPUT — commit + CFBundleIdentifier + CFBundleVersion + configuration]`
- **Contacts access state at start:** `[OWNER INPUT]`
- **Console capture (§7.5):** `[OWNER INPUT — reference; inspected: yes/no]`
- **Per-item results:**

| Item | Status (PASS / FAIL / BLOCKED) | Observed result (line keys / labels / counts / yes-no — §9) | Evidence pointer |
|---|---|---|---|
| DV-1 — link → ONE row (matched + unmatched queries) and one call tile | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-2 — voice "call `<nickname>`" (Devanagari variation) + ambiguity never dials | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-3 — photo write updates the system contact; display reflects it | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-4 — denied/limited fallback: app-local, honest, no loss, no crash | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-5 — name + every recorded variation finds the single linked row | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |
| DV-6 — pre-change payloads load; the single nickname still matches | `[OWNER INPUT]` | `[OWNER INPUT]` | `[OWNER INPUT]` |

- **Notes / deviations:** `[OWNER INPUT]`
- **Tester:** `[OWNER INPUT]`

### 7.3 Item status as of authoring (not observations)

| Item | Status as of authoring | Named dependency (what must clear it) |
|---|---|---|
| DV-1 — link → ONE row (matched + unmatched queries) and one call tile | **BLOCKED** | An Anzaan device session + the §2 build installed + contacts access + a system contact to link |
| DV-2 — voice "call `<nickname>`" (Devanagari variation) + ambiguity never dials | **BLOCKED** | An Anzaan device session + the build + recorded Devanagari nicknames + a second contact for the ambiguity leg + a working STT path |
| DV-3 — photo write updates the system contact; display reflects it | **BLOCKED** | An Anzaan device session + the build + a verified link + contacts access allowed + the test photo + the iOS Contacts app for verification |
| DV-4 — denied/limited fallback: app-local, honest, no loss, no crash | **BLOCKED** | An Anzaan device session + the build + the owner's ability to flip Contacts access (denied, limited) + a second test photo |
| DV-5 — name + every recorded variation finds the single linked row | **BLOCKED** | An Anzaan device session + the build + the contact's recorded variations |
| DV-6 — pre-change payloads load; the single nickname still matches | **BLOCKED** | An Anzaan device session + a pre-change install carrying a single-nickname payload (route (a) or the staged route (b)) + the feature build for the upgrade install |

**Feature completion status: “device validation outstanding.”** No item is PASS; none may be reported as such until a session executes it and this record carries the observation (FR-FCU-017; FR-FCU-016 honesty).

### 7.4 Owner actions carried (decisions, not measurements)

| # | Owner action | Why it is the owner's | State |
|---|---|---|---|
| OA-1 | Provide an Anzaan device session and execute DV-1…DV-6 against the §2 build, filling §2/§7.2 | Only the owner has the device, the real address book and the permission states | **Open — BLOCKED** (the dependency of every item) |
| OA-2 | Choose the DV fixtures: which system contact to link, the recorded nickname/variation strings, the test photos | Household identity data and the owner's address book | Open |
| OA-3 | Choose DV-6's route: migrate the device's existing pre-change install (a) or stage one (b) | Requires knowledge of what the device currently carries; a container-preserving sequence | Open |
| OA-4 | Flip Contacts access denied/limited and back for DV-4 | System-permission ownership on the owner's device | Open |
| OA-5 | Resolve any FAIL/BLOCKED item: fix, re-run on the fixed build, or record an explicit owner resolution | FR-FCU-017: a failure blocks final sign-off until fixed and re-run — no silent waiver | Open |
| OA-6 | Accept or decline attaching screenshots/containers to this record where the copy discipline (§9) permits only by owner choice | The owner owns the household PII in the artifacts | Open |

### 7.5 Accompanying release-gate evidence (required by FR-FCU-017, NFR-FCU-009)

FR-FCU-017: "The release-build log-surface evidence (`check-release-log-safety.sh`, pre-release device console check) accompanies the DV record (NFR-FCU-002, NFR-FCU-009)." This is **not** a DV item (the checklist is DV-1…DV-6 as written) — it is the record half that travels with it:

| Evidence | Source | State |
|---|---|---|
| Log-safety gate exits 0 over the feature roots (link service, photo writer, index; the write/fallback/resolution paths) | **Build-side, executed:** T-163 §6 — `bash ios/tools/check-release-log-safety.sh` exit 0 at `4d4d1e28` (all fixtures green, all four FCU roots scanned), and green ahead of every scoped suite | **Done (build-side)** |
| No new egress (NFR-FCU-003 spot check) | **Build-side, executed:** T-163 §6 — the seam suites' no-network-egress pins pass | **Done (build-side)** |
| **Pre-release device console check on the new paths** — a console capture across the DV session (link, photo write, fallback, voice resolution, migration) inspected for: names, numbers, nicknames, contact identifiers, photo content, and any unlisted metadata key. Expected: **zero occurrences**; only the §5.2/§5.3 event names with allow-listed fields appear. Inspect → scrub → reference; the raw capture is never pasted into this file (§9) | **Device-side, owner:** runs during the §4 session; captured via §2's console method | **Open — pending the session** |

### 7.6 Honesty notes about this record

- **No device model, OS version, build identifier, measurement or outcome in this file is fabricated.** Where a value does not exist, the cell says it does not exist (`[OWNER INPUT]`). Every DV item is BLOCKED, none is PASS.
- **The simulator is not used as a substitute**, and neither are the unit suites. T-163's scoped sweep (32/32) and the solver pins are the *wiring* evidence recorded in `specs/T-163-acceptance-notes.md`; no row here is filled from them.
- **No item is marked passed, and no incomplete item is dressed up as complete.** The completion claim is blocked until every item carries a PASS from a device session (§8).
- **The pre-change fixtures are labelled.** DV-6's nickname string and the DV nickname fixtures are test fixtures and may be recorded; real household names/numbers are recorded by role (§9).
- **The known baseline is untouched by this record.** The full-bundle pre-existing failures recorded in T-163 §4 remain master-owned and are not DV evidence either way.

## 8. The completion gate (FR-FCU-017)

The gate, verbatim from FR-FCU-017 ("Recorded results"): "Each item is recorded as passed/failed with evidence (session notes, screenshots, log pulls) attached to the feature spec; a failure blocks final sign-off until fixed and re-run — no silent waiver." Its failing scenario: "Given any DV item fails (e.g. the linked person still appears twice) / When completion is assessed / Then the feature does not pass final sign-off / And the failure is fixed and the item re-run before sign-off proceeds."

Mechanics:

1. **Only PASS closes an item.** FAIL and BLOCKED both hold the gate. A failed item stays recorded as failing; the fix is made, the item re-run on the fixed build, and the re-run recorded with the fixed build's identity.
2. **BLOCKED is the honest session-less state, not a pass.** With no session, the record states "device validation outstanding" — exactly what this authored record does (§7.3).
3. **The device console evidence (§7.5) travels with the record** — its device half cannot move until the session runs and the capture is inspected.
4. **Consumers of this protocol:** the workflow's `final-sign-off` (T2 + HIL; `.ai-sdd/workflows/family-contacts-unify.yaml:213` — "DV-* device validation on Anzaan is part of the completion gate") evaluates this record before sign-off can pass; T-165's security evidence index cites DV-3/DV-4 as the device half of the write-seam obligations (`specs/security-design-review.md:118`).
5. **Missing execution is an open gate item, not a missing deliverable.** The T-164 deliverable is this protocol and its record structure; the run is owner/device-dependent. At final review, an empty record — or any item not PASS — holds final sign-off exactly as a FAIL would.

**Coverage of this unit's Gherkin (T-164 task file):**

| T-164 scenario | Where the protocol satisfies it |
|---|---|
| Protocol and record prepared (every DV item has steps, expected outcomes, a pass/fail/blocked slot; executable in one session without authoring on the device) | §6 — DV-1…DV-6 each with verbatim item text, preconditions, exact steps, expected outcome, pass/fail, evidence, and a record template; §5 + §7.2 define the record; §4 is the session procedure; §2/§3 carry everything the tester needs before touching the phone |
| Session executes the checklist (each item PASS with the observed result; a FAIL recorded verbatim with reproduction steps — not retried away) | §5/§7.2's per-item Status + Observed + Evidence fields; §8 mechanic 1 (only PASS closes; FAIL stays recorded, fix + re-run on the fixed build) |
| No session available (every item BLOCKED with the reason; completion status "device validation outstanding") | §7.3 (BLOCKED table with named dependencies) + the headline/§7.6 — this is the state as of authoring |
| A DV item fails on device (failure logged with reproduction steps; the item stays FAIL; the gate not marked passed) | The per-item **Steps** are the reproduction script; §8 mechanic 1; §4 step 6 |
| Partial session (executed items carry observed results; the remainder BLOCKED — no inference, no filling from unit tests) | §5's status vocabulary + §7.2 (per-item rows) + §7.6's no-substitution note; §8 mechanic 2 |

## 9. Capture discipline (NFR-FCU-002 applied to the record and the captures)

- **This file contains no sensitive material beyond agreed fixtures.** Evidence is a **line key, a label, a count, or a yes/no** — never a transcript of household content. Two classes of string are permitted by construction: (a) **test fixtures** created for the DV (the nickname strings recorded for the DV-2/DV-5 legs, the DV-6 migration fixture nickname) — these are the test's own material and are recorded to be reproducible; (b) the **protocol utterances** quoted in §6 (the shipped copy and the fixtures). Real household names, phone numbers, contact identifiers and photo content are **not** transcribed — record them by role ("the parent's stored name", "the linked contact's number — matches: yes/no"). A screenshot is attached **only if the owner accepts it** (OA-6); the default evidence is the recorded observation.
- **The console capture is inspected before it is referenced.** Names, numbers, nicknames, identifiers and photo bytes must not appear in any line; only the closed event names/fields of design-l2 §5.2 may be quoted. If a hit is found, the item is recorded as failing with the finding described by shape and location only, the raw capture is kept out of the repo, and the attachable artifact is the redacted copy or a note of the scrub.
- **The DV-6 container observation, if taken, stays out of the repo.** Record what was observed (the pre-change `nickname` key present), never the container itself.
- **A failed check is a finding, not a tuning invitation.** Fixing an item is valid only with the observation and the fixed build's identity recorded next to the change.

## 10. Recording rules (mirroring the LCT/SP/MTC precedents)

1. **Every row gets a value or BLOCKED with a reason.** No row is left blank, and no row is filled from a simulator or unit-test observation. Every row names the session (date, device, build) it was observed on (§7.1/§7.2).
2. **Measurements and decisions are different columns.** An observed outcome is not a decision to change anything; owner decisions are recorded as such (§7.4).
3. **A failed check is a finding, not a tuning invitation.** Fixing an item is valid only with the observation and the fixed-build identity recorded next to it.
4. **This protocol is not edited to match the results.** Results go in §7. If an item turns out to be unexecutable as written, §7 records that and §6 is updated in a separate, visible edit. The checklist content is DV-1…DV-6 exactly as the constitution records it — executed as written, not re-interpreted or extended here.
