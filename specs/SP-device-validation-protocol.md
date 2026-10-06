# Spotify music integration — device-validation protocol and record (T-124)

**Feature:** `spotify-music-integration` · **Task:** T-124 (`TG-23 — Release Gates, Security Evidence and Device Validation`) · **Component:** C-SP-16 (the DV protocol-and-record artifact).
**Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant-spotify-music-integration` · **Branch:** `feat/spotify-music-integration` · **Authored at HEAD:** `4f6d4b1c3962eb8291ac2e3554b48d70345bf5a5` ("Implement spotify-music-integration W7 (T-123): security evidence bundle") · **Date:** 2026-10-07.
**Governing requirement:** FR-SP-017 (`specs/define-requirements/FR/FR-SP-017-device-validation-checklist-recorded-and-passed.md`) and the feature constitution's completion gate (`specs/spotify-music-integration/constitution.md` § "Success Criteria & Completion Gate").
**Binding sources of record for the item wording:** the constitution's DV-1…DV-5 table; `specs/design-l1.md:156-166` (the DV-1…DV-5 table plus the DV-6/DV-7 additions); `specs/design-l2.md` §23 (:407-411, the expanded list DV-1…DV-7 and the OD-S2 appendix); the T-124 task file (`specs/plan-tasks/tasks/TG-23-release-gates-security-evidence-and-device-validation/T-124-device-validation-protocol.md`, 4 Gherkin scenarios and the DoD checklist).
**Format precedent:** `specs/LCT-device-validation-protocol.md` → `specs/LCT-device-validation-results.md` (the shipped live-camera-translation pair). This file merges the two shapes into one artifact because the T-123 bundle cites the single exact path `specs/SP-device-validation-protocol.md` for the DV-7 half of security evidence obligation 6.

> **Headline, stated first because everything below depends on it: no device run has happened.**
> No physical device run was made available to this authoring work; no real Spotify account was driven; the OD-S2 Dashboard registration does not exist yet. **Every DV item below is recorded as BLOCKED with the dependency that must clear it.** Nothing in this file is a device observation, and no simulator or unit-test run was used to fill any row — the T-124 task file states it literally ("No automation substitutes for this task: simulator runs do not satisfy FR-SP-017") and FR-SP-017 carries the equivalent (tests are necessary; the device run is what signs the feature off). The file is the protocol plus the empty record the owner fills in on the Anzaan reference device; the authoring agent executed nothing on device or simulator for it.

---

## 1. Why this protocol exists, and what binds it

The feature replaces the first-class music stub (`router.musicStub`, was `CommandRouter.swift:2640`) with real playback: for a bare music request both providers are searched and Spotify wins whenever it is linked and capable; YouTube serves explicit YouTube requests and the Spotify-can't-serve fallback; every degradation path speaks an honest localized line. Unit tests prove the wiring lives in the build; only a device run can prove the feature works for the person holding the phone — a real Spotify account, a real network stack, a real Spotify app, and real sound.

What binds this protocol:

- **FR-SP-017** — the feature "**must** carry a DV-* style acceptance checklist recorded with the feature … and **must** pass it on the reference device (Anzaan) before it is considered done". Requirements on the checklist itself: it is recorded with the feature's artifacts; each item carries steps, expected outcome and an observed result; every item has an explicit pass/fail record; a failed item is recorded as failing and the feature is **not** declared done on an unmet item; results are captured on a Release build on the reference device where the item's nature requires it; "the checklist is the completion gate regardless of unit-test status: tests are necessary, the device run is what signs the feature off."
- **The simulator clause** — "No automation substitutes for this task: simulator runs do not satisfy FR-SP-017" (T-124 implementation notes; `specs/plan-tasks/plan.md` risk 5). A simulator cannot install the Spotify app, cannot complete the `spotify:` deep-link hand-off truthfully, cannot exercise a real radio or a real account. No row of this record may ever be filled from a simulator observation.
- **The unmet-item rule** — "An unmet item is recorded as failing and blocks the completion claim (FR-SP-017); deviation requires explicit owner resolution" (design-l1.md:168; design-l2.md:409). BLOCKED is an unmet item: the feature is not done while any item is unmet.
- **Run with the OD-S2 registered accounts** — design-l2.md:409. DV-2/DV-3/DV-4 need a real linked account; the Development-mode allowlist means only accounts registered in the Dashboard's User Management can link at all (design-l1.md §5). §3 below is that prerequisite block.
- **The project's pre-release device check** — "On a Release build on a real device, confirm that no transcript content, key material, or raw upstream body appears in the device console or in a sysdiagnose capture. The result is recorded in the release checklist before submission" (root `constitution.md`, Release gates). DV-7 is that check for the music paths, and it is also the device half of the Spotify security review's evidence obligation 6 (`specs/security-design-review.md:141`), referenced by the T-123 bundle (`specs/SP-security-evidence-index.md`, O6 pending).

## 2. Environment and build identity

Recorded for reproducibility; a measurement without a device and a build is not reproducible (the LCT precedent's recording rule 1). Values marked `[OWNER INPUT]` do not exist yet and are **not invented here** — a cell that has no value says so.

| Field | Value |
|---|---|
| Reference device | **the Anzaan reference device** (named by FR-SP-017 and the feature constitution). Model, storage and identifiers: `[OWNER INPUT — device model, e.g. from Settings ▸ General ▸ About]` |
| iOS version | `[OWNER INPUT — Settings ▸ General ▸ About ▸ Software Version at run time]` |
| Build mode | **Release** (required: the project's pre-release device-check discipline and FR-SP-017's "Release build"); never a debug build for DV-1…DV-7 |
| Build identity — commit | `[OWNER INPUT — `git rev-parse HEAD` in this worktree at build time]`. The authoring baseline (this file) is `4f6d4b1c3962eb8291ac2e3554b48d70345bf5a5`; the tested build must be at least this commit |
| Build identity — build number | `[OWNER INPUT — CFBundleVersion of the installed build]` |
| Build produced by | `[OWNER INPUT — the exact command/method, e.g. `cd ios && DEVELOPMENT_TEAM=<team> ./build.sh ipa`, or an Xcode Product ▸ Archive]` |
| Install method | `[OWNER INPUT — Xcode Devices / TestFlight / other; record it because the sysdiagnose surface differs]` |
| Tester (holds the phone) | `[OWNER INPUT]` |
| Run date(s) | `[OWNER INPUT]` |
| App locale under test | Nepali (`ne`) for DV-5; the owner's normal configuration otherwise; `[OWNER INPUT — record the app/device language actually set]` |
| Spotify app installed | Yes for DV-1…DV-5 and DV-7; **removed** for DV-6 (`[OWNER INPUT — confirm at each item]`) |
| YouTube configuration present | `[OWNER INPUT — key present (keyed path) or keyless (the shipped openingSearch hand-off); DV-1/DV-3 require this stated]` |

## 3. OD-S2 prerequisites — the registration block (owner action, not performed)

**State: step 4 landed after authoring.** As written at authoring time: not performed — no Dashboard app existed, no client ID pasted, no test user registered, no quota-extension request filed (corroborated by `specs/SP-security-evidence-index.md` recorded limits 4–5). **[Owner update, 2026-10-07]** the owner created the Dashboard app and provided its public client ID; it is pasted into `Info.plist` (`SpotifyClientID`) — step 4 below. The Dashboard-side facts (app name, accepted scheme, registered scopes, test users, quota filing) remain unverified from the repo and stay open. Every field below is still `[OWNER INPUT]` where no value exists; no account, email, ID or Dashboard value is invented in this file. The registration steps must be completed **before** any device validation that links a real account — DV-1/DV-2 need a working link (design-l1.md:105).

| # | Prerequisite | Detail | Value / state |
|---|---|---|---|
| 1 | Create the app in the Spotify Developer Dashboard | Final app name `[OWNER INPUT — final name; a recognizable product name]` | Not done |
| 2 | Add the redirect URI | `sahayak-spotify://callback` — **exact string**, one constant shared by the Dashboard, `Info.plist` and the validator (`specs/design-l2.md:537`). If the Dashboard refuses the custom scheme, re-shape per the L1 §15 scheme note (e.g. the SDK-style `spotify-<clientid>://callback` form), move the single constant, the plist entry and the tests together (V-2), and record the final value here. **The scheme's acceptance is confirmed by DV-2's real link flow on device.** | Not done — `[OWNER INPUT — accepted scheme; equals the constant or the recorded re-shaped value]` |
| 3 | Register the scopes | `user-read-private`, `user-modify-playback-state` — exactly the pinned two-scope set (M-3 supersession; `specs/design-l2.md:540`; `specs/security-design-review.md` M-3). Do **not** register `user-read-playback-state`; it was deliberately dropped before registration and is asserted absent by `SpotifyAuthFlowTests.testAuthorizeURLRequestsExactlyThePinnedLeastPrivilegeScopeSet` | Not done |
| 4 | Paste the client ID into `Info.plist` | Key `SpotifyClientID` `[OWNER INPUT — public identifier; paste from the Dashboard into the plist, never into a document]`. Without this the feature is dormant (`notConfigured`) — every linked-path item then records BLOCKED, not executed | **Done (owner paste, 2026-10-07)** — value present in `Info.plist`; the id is public by definition (ADR-SP-01). Repo-verifiable: `ASWebSpotifyAuthSessionTests.testSourceInfoPlistCarriesTheSpotifyClientIDKey` requires the key and no stray whitespace |
| 5 | Client secret | **NOT USED** — PKCE public client (ADR-SP-01). Do not paste it anywhere; if the Dashboard displays one, ignore it (design-l1.md:146) | Not applicable |
| 6 | User Management (test users, Development mode) | The account classes of design-l1.md §5(a): Dashboard-owning account `[OWNER INPUT — email]`; the Anzaan household account, **Premium** `[OWNER INPUT — email; confirm Premium — if not Premium, DV-2 records the free-tier deep-link outcome with the deviation named]`; a free-tier test account for DV-4(a) `[OWNER INPUT — if none exists, DV-4(a) records BLOCKED with that dependency]`; additional test-user emails `[OWNER INPUT — if used]` | Not done |
| 7 | Quota-extension request | File when design-l1.md §5(b)'s four criteria hold (DV-1…DV-5 pass in Development mode; Dashboard metadata final and matching the shipped build; privacy disclosure and App Store privacy entries in place; no further OAuth/scope changes planned). Business/contact details and privacy-policy URL `[OWNER INPUT]`; use-case description drafted in `specs/design-l2.md:411`. Timeline: before the first distribution outside the registered test set. Record the observed review window at filing `[OWNER INPUT]` | Not filed |
| 8 | Owner sign-off line | `[OWNER INPUT — approve/amend design-l1.md §5(a)-(d); record the decision and date at final-sign-off]` | Open |

## 4. How to run this (owner procedure)

Written so a person holding the phone can execute it without this document's author present (the LCT precedent's rule). Say every utterance **once per repetition**, wait for the spoken outcome, and touch the screen only where a step says so.

1. **Clear the prerequisites.** Complete §3 (at minimum #1–#6) or accept that the linked items record BLOCKED with the missing dependency named. Charge the device.
2. **Build and install the Release build.** From this worktree: `cd ios && DEVELOPMENT_TEAM=<team> ./build.sh ipa`, or Xcode ▸ Product ▸ Archive. Install on the Anzaan reference device. Fill §2's `[OWNER INPUT]` fields (commit, build number, method).
3. **Set the state each item names, then run it literally.** Every item in §5 lists: what the device state must be, the exact steps (utterances verbatim), the expected observable outcome with the shipped line keys, pass/fail criteria, and what evidence to capture. Reset the state between items where the item says so.
4. **Write the result into §6 of this same file, in the item's row** — status (PASS / FAIL; BLOCKED only where the dependency was still missing), the line key heard, device/OS/build (already in §2), the evidence pointer, and notes. The protocol text of §5 is **not** edited to match results (Recording rule 4); results go in §6.
5. **A failed item stays recorded as failing.** Fix the build, re-run that item on the fixed build, record the fixed-build identity. The feature is not declared done while any item is unmet; deviation requires explicit owner resolution (FR-SP-017).
6. **DV-7 capture:** inspect, then scrub, before attaching (§7). The capture is also security evidence obligation 6's device half; the T-123 bundle's O6 stays open until this record carries the capture.
7. **After the run:** keep this file as the record; the driver integrates it and, in the same change, updates the T-123 bundle's O6 pending to cite the landed capture. O8's Dashboard column is closed only by §3's registration, never by anything in this file.

## 5. The DV items (the protocol)

Line keys name shipped catalog values (`ios/ElderlyAssistant/Resources/Localizable.xcstrings`, quoted at the M-2/M-3-amended state). Record a **line key**, never a transcript: no query text, title, id, token or provider body goes into this file (NFR-SP-002; §7).

### DV-1 — Stub → real playback flip: a bare music request produces sound

- **Source of record:** FR-SP-001; constitution DV-1; design-l1.md:160.
- **Device state required:** Release build on the Anzaan device; Spotify **unlinked** (Settings ▸ Spotify status reads `spotifySettings.status.notLinked` — "Not connected" / "जोडिएको छैन"); YouTube configured (record keyed or keyless in §2).
- **Steps:** (1) Note the state. (2) Say **'भजन बजाऊ'**. (3) Wait; the outcome line is expected within the design's outcome budget (`music.outcomeBudgetSeconds` 10 s where at least one provider answers; no path waits beyond ~16 s — design-l2.md §32). (4) Watch which app opens and whether sound can start.
- **Expected observable outcome (L1 wording):** "A real outcome (YouTube path or deep-link hand-off); **never** the stub line; sound can start via the provider app." Lines this item may legitimately produce: `youtube.playing` ("Playing %@ on YouTube." / "युट्युबमा %@ चलाउँदैछु।"), `youtube.openingSearch` ("Opening YouTube search for %@." / "युट्युबमा %@ खोज्दैछु।"), `spotify.openSearch` ("Opening Spotify search." / "स्पोटिफाइमा खोज खोल्दैछु।"), or — where a provider honestly cannot serve — `youtube.notFound` ("I couldn't find a video for that on YouTube." / "युट्युबमा त्यसको भिडियो भेटिएन।"), `youtube.unavailable` ("YouTube isn't available right now. Please try again." / "अहिले युट्युब उपलब्ध छैन। फेरि प्रयास गर्नुहोस्।"), `spotify.notLinked` ("Spotify isn't set up yet. A family member can add it in Settings." / "स्पोटिफाइ अझै जोडिएको छैन। परिवारका सदस्यले सेटिङमा जोड्न सक्नुहुन्छ।").
- **Pass criteria:** exactly one outcome line, from the set above; the stub line `router.musicStub` ("Music isn't ready yet. Coming soon." / "संगीत सुविधा अहिले तयार छैन। चाँडै आउनेछ।") is **not** spoken; the provider app opens on a plausible result and sound can start; no crash.
- **Fail criteria:** the stub line; silence; an "opening/playing" claim with no app opened; a crash; a raw error read aloud.
- **Evidence to capture:** line key heard; which app opened; sound started yes/no; any line arriving after the budget.
- **Record as:** the DV-1 row of §6.2.

### DV-2 — Spotify-preferred selection + the Dashboard-scheme-acceptance confirmation

- **Source of record:** FR-SP-002, FR-SP-003; constitution DV-2; design-l1.md:161; the V-2 verify-and-record item (`specs/security-design-review.md:126`).
- **Device state required:** §3 registration complete; the caregiver has **linked the household account through the real in-app flow on this device** — Settings ▸ Spotify ▸ `spotifySettings.link` ("Connect Spotify" / "स्पोटिफाइ जोड्नुहोस्"), completing OAuth on the device. **This real link flow completing on device is the Dashboard-scheme-acceptance confirmation:** the redirect scheme registered in the Dashboard (the `sahayak-spotify://callback` constant, or the recorded re-shaped value) was accepted by Spotify and the callback returned to the app without a mismatch — record the accepted scheme in the row. `spotifySettings.status.linked` ("Connected (Premium)" / "जोडिएको (प्रिमियम)") means Premium; if the household account is confirmed not Premium, the expected outcome becomes the free-tier deep-link path (`spotify.openApp`, app opens) and that deviation is named in the row (design-l1.md §5(a) contingency). YouTube configured.
- **Steps:** (1) Confirm the status line. (2) Say **'गीत चलाऊ'**. (3) Observe; do not touch. (4) Optional corroboration: Settings ▸ Tool requests shows the turn's `.spotify` entry (its text fields are empty by design — the M-1/ADR-SP-15 contract).
- **Expected observable outcome (L1 wording):** "Both providers searched; Spotify selected; remote playback line names Spotify; music plays." Expected line: `spotify.playing` ("Playing %@ on Spotify." / "स्पोटिफाइमा %@ चलाउँदैछु।") with a real title heard (record "title heard: yes/no" — never the title itself), and playback runs on the household's Spotify. Free-tier contingency line: `spotify.openApp` ("Opening Spotify — play it there." / "स्पोटिफाइ खोल्दैछु — त्यहाँ बजाउनुहोस्।").
- **Pass criteria:** the link flow completed on device (scheme accepted — this is the recorded V-2 confirmation); exactly one outcome line; it is `spotify.playing` with music playing (Premium) or the recorded free-tier contingency outcome; Spotify — not YouTube alone — served the request; no stub line.
- **Fail criteria:** the link flow failing to return to the app (a Dashboard-scheme rejection is a finding: re-shape the constant per V-2, rebuild, repeat); silence; a YouTube-only outcome while the account is Premium-capable and linked; a "playing" claim with no sound; the stub line.
- **Evidence to capture:** the accepted redirect scheme (string only — it is a public identifier); line key; title heard yes/no; playback observed yes/no; both-legs note (what the tool-requests surface showed for the turn).
- **Record as:** the DV-2 row of §6.2.

### DV-3 — Explicit-YouTube routing unchanged

- **Source of record:** FR-SP-005; constitution DV-3; design-l1.md:162.
- **Device state required:** Spotify linked (DV-2 state) **and** a YouTube key present.
- **Steps:** (1) Say **'युट्युबमा गीत चलाऊ'**. (2) Observe; do not touch.
- **Expected observable outcome (L1 wording):** "YouTube path exactly as before; music/Spotify path does not also handle it." The outcome is the pre-feature explicit-YouTube behaviour for the same request — one `youtube.*` line: `youtube.playing`, `youtube.openingSearch`, `youtube.notFound` or `youtube.unavailable` (whichever the pre-feature run produces; the owner compares with their known behaviour).
- **Pass criteria:** exactly one outcome line and it is a `youtube.*` line; no `spotify.*` line appears (in particular no `spotify.playing` / `spotify.openApp`); no double handling (no second outcome).
- **Fail criteria:** any `spotify.*` outcome; two outcome lines; a different YouTube result shape than the pre-feature run.
- **Evidence to capture:** line key; deviation description if the YouTube behaviour differs from before (name what differed).
- **Record as:** the DV-3 row of §6.2.

### DV-4 — Honest lines for free-tier, unlinked, network-failure and empty-search (each sub-case repeated ×2)

- **Source of record:** FR-SP-011, FR-SP-012; constitution DV-4; design-l1.md:163 ("each repeated"); design-l1.md §12 matrix rows 3/6/7/8; design-l2.md §13 mapping.
- **General rule for all four sub-cases:** every repetition produces exactly one honest outcome line (a fixed pre-acknowledgment, if the build speaks one, is not the outcome line); no silence; no false "playing" claim; nothing promises Spotify control that did not happen.

**DV-4(a) — free-tier linked account.**
- **State:** a linked account on the free tier (the OD-S2 free-tier test account, or a temporary downgrade if the owner accepts it); Settings shows `spotifySettings.status.freeTier` ("Connected (free — playback opens the Spotify app)" / "जोडिएको (निःशुल्क — गीत स्पोटिफाइ एपमा खुल्छ)"). Spotify app installed.
- **Steps:** say **'भजन बजाऊ'**; observe; repeat once.
- **Expected:** the validated `spotify:` deep link opens the Spotify app (track or search), and the spoken line is `spotify.openApp` — an explicit line that Spotify was opened, never a claim that remote playback was started (matrix row 3).
- **Evidence:** line key per repetition; app opened yes/no. If the Spotify app is absent the DV-6 outcome applies instead — record it under DV-6, not here.

**DV-4(b) — unlinked account.**
- **State:** unlink via Settings ▸ Spotify ▸ `spotifySettings.unlink` ("Remove Spotify" / "स्पोटिफाइ हटाउनुहोस्") through the `spotifySettings.removeConfirm` dialog ("Remove the Spotify connection? Music will use YouTube only." / "स्पोटिफाइ जडान हटाउने हो? संगीत युट्युबबाट मात्र बज्नेछ।"); status returns to `spotifySettings.status.notLinked`. (A never-linked install is equivalent.)
- **Steps:** say **'भजन बजाऊ'**; observe; repeat once.
- **Expected:** matrix row 8 in order — YouTube serves where it can (its existing lines); where YouTube cannot serve at all, the `spotify:search:` hand-off opens with `spotify.openSearch`; where even that cannot open, `spotify.notLinked`. Record which branch ran and why.
- **Evidence:** line key per repetition; the branch taken.

**DV-4(c) — airplane-mode network failure.**
- **State:** account linked (Premium or free); enable **airplane mode** (Control Center).
- **Steps:** say **'भजन बजाऊ'**; observe; repeat once; then disable airplane mode.
- **Expected:** matrix row 7 — the Spotify search cannot reach the provider, and where YouTube is serveable its leg answers with its existing lines (a keyless hand-off still speaks `youtube.openingSearch`; a keyed fetch fails to `youtube.unavailable`/`youtube.notFound` — record which); otherwise `spotify.unavailable` ("Spotify isn't available right now. Please try again." / "अहिले स्पोटिफाइ उपलब्ध छैन। फेरि प्रयास गर्नुहोस्।").
- **Evidence:** line key per repetition; time to the line (no path may hang beyond the ~16 s ceiling — design-l2.md §32).

**DV-4(d) — empty-search utterance.**
- **State:** account linked; phone on the network. The owner chooses at run time a music request that returns **zero usable Spotify results** (a music marker combined with a term expected to match nothing). **The chosen utterance is not transcribed into this file** (NFR-SP-002 — query text stays out of the record).
- **Steps:** say the chosen utterance; observe; repeat once.
- **Expected:** matrix row 6 — YouTube fallback where it can serve (its existing lines), otherwise `spotify.notFound` ("I couldn't find that music on Spotify." / "स्पोटिफाइमा त्यो संगीत भेटिएन।"). Record which branch ran.
- **Evidence:** line key per repetition; the branch taken; the fact that the search returned zero results (assert by the observed branch, not by pasting anything).

**DV-4 pass/fail (whole item):** pass = for every sub-case and both repetitions: one honest line from the stated set, no silence, no false "playing". Fail = silence; a claim of playback that did not happen; a raw error; a hang beyond the budget; or a sub-case that could not be set up (recorded BLOCKED with its dependency — e.g. no free-tier account — never silently skipped).
- **Record as:** the four sub-rows of the DV-4 row in §6.2.

### DV-5 — Nepali-language end-to-end on the Anzaan reference device

- **Source of record:** constitution DV-5; design-l1.md:164; FR-SP-017.
- **Device state required:** the device/app running the owner's normal Nepali configuration.
- **Steps:** re-run the DV-1…DV-4 scenarios in one Nepali session; listen to every spoken line; watch the visible surfaces touched (Settings status, dialogs).
- **Expected observable outcome (L1 wording):** "All spoken lines are Nepali; no English fallback." The expected utterances are the shipped `ne` values quoted in §5 for each line key (for example `spotify.playing` → "स्पोटिफाइमा %@ चलाउँदैछु।", `spotify.openApp` → "स्पोटिफाइ खोल्दैछु — त्यहाँ बजाउनुहोस्।", `youtube.playing` → "युट्युबमा %@ चलाउँदैछु।").
- **Pass criteria:** every line heard across the re-run corresponds to a shipped `ne` value; no `en` string is spoken anywhere; the Settings surfaces render Nepali.
- **Fail criteria:** any English line; a line not from the catalog; silence; TTS reading a line in the wrong language.
- **Evidence to capture:** "all lines Nepali: yes/no"; any line key that came out in the wrong language (name the key, not the audio).
- **Record as:** the DV-5 row of §6.2.

### DV-6 — Spotify app removed → honest app-absent / fallback behaviour

- **Source of record:** design additions (design-l1.md:165; design-l2.md:409); FR-SP-012's app-absent rule; Feature Constraint 8; design-l1.md §12 rows 4/5/8.
- **Device state required:** Spotify **linked (free tier is the natural state) or unlinked**, with YouTube configured; then **remove the Spotify app** from the device (long-press ▸ Remove App ▸ Delete). Record before/after: the Settings status line (the account link itself survives app removal — recording what the surface shows is part of the observation).
- **Steps:** say **'भजन बजाऊ'**; observe; repeat once. Then, in the linked state, say **'गीत चलाऊ'**; observe. Afterwards reinstall the Spotify app to restore the device.
- **Expected observable outcome (L1 wording):** "Honest app-absent/fallback behaviour; no crash, no false claim." Per the matrix: YouTube fallback where it can serve (its existing lines); otherwise the honest terminal line — `spotify.appMissing` ("The Spotify app isn't on this phone, so I can't play the music." / "यो फोनमा स्पोटिफाइ एप छैन, त्यसैले संगीत बजाउन सकिनँ।") where a deep-link open was attempted against the absent app (rows 4/5; the probe is the `canOpenURL` pre-check — V-4), or `spotify.notLinked` on the unlinked path where nothing else could serve. The spoken line must name the real condition; `spotify.playing` must never be heard.
- **Pass criteria:** no crash; per repetition exactly one honest line from the set above; no playback success claimed; no silent no-op (silence is a fail).
- **Fail criteria:** a crash; silence; `spotify.playing` or any control claim; a deep-link line claiming the app opened.
- **Evidence to capture:** line key(s); the state under test (linked/unlinked); what the Settings status showed after app removal.
- **Record as:** the DV-6 row of §6.2.

### DV-7 — Console/sysdiagnose capture during DV-1…DV-6: zero sensitive material

- **Source of record:** design additions (design-l1.md:166; design-l2.md:409); NFR-SP-002 (`specs/define-requirements/NFR/NFR-SP-002-log-safety.md`); the project's pre-release device check (root `constitution.md` Release gates); security evidence obligation 6 (`specs/security-design-review.md:141`).
- **Scripted session required:** one session exercising **link, play, fallback, failure and unlink**, i.e. a pass over DV-2 (link + play), DV-4 (fallback/failure: at least the unlinked and airplane-mode sub-cases, plus the empty-search utterance), and the unlink flow (DV-4(b) setup), with DV-1/DV-3 included where convenient and **DV-6 included in the session** (its spoken app-absent outcome must appear in the capture — T-124 scenario 3) — all with the capture running throughout.
- **Steps:**
  1. Start the console capture **before** the session: Console.app ▸ select the device ▸ filter to the app process (or Xcode ▸ Window ▸ Devices and Simulators ▸ device ▸ Open Console; `log collect` is an accepted equivalent). Record the exact method used.
  2. Run the scripted session end to end.
  3. Take a **sysdiagnose** on the device (the owner's standard trigger; record how it was obtained and where the archive lives).
  4. **Inspect both captures** for: token-shaped values (access/refresh token values, `Bearer`-prefixed values), the PKCE verifier value, authorization-header values, query text (search the console text for the utterances spoken during the session — this is the concrete query probe), and provider bodies (JSON fragments, track titles, raw error descriptions). Expected: **zero occurrences in both surfaces.**
  5. **Scrub before attaching** (§7): if a hit is found, the item is recorded as failing with the finding described by shape and location only (never the value), the raw capture is kept out of the repo, and the attachable artifact is the redacted copy or a note of the scrub. The raw capture with a hit must not be attached, committed, or copied into any document.
- **Pass criteria:** zero hits in both surfaces; the inspection method and the scrubbed capture recorded so a reviewer can reproduce the check; the capture attached to this record (path or attachment).
- **Fail criteria:** any hit — a finding that fails the item and blocks the completion claim; a capture attached without inspection.
- **Evidence to capture:** the scrubbed capture (path/attachment); the inspection method; hit count (expected 0).
- **Consequence:** this capture is security evidence **obligation 6's device half**; the T-123 bundle (`specs/SP-security-evidence-index.md`, O6) records that half as open and cites this exact file (`specs/SP-device-validation-protocol.md`) as where it lands. O6 cannot move while this item is unmet.
- **Record as:** the DV-7 row of §6.2.

## 6. Record (to be filled by the owner at run time)

**State as of authoring: no device run has occurred.** No row below carries a result; every item is BLOCKED. The outcome vocabulary the owner writes when the run happens: **PASS** / **FAIL** (BLOCKED stays only for an item whose dependency is still unmet at run time, with the dependency named). No other value is valid; no value is written before the observation exists.

### 6.1 Environment and build identity (run record)

Fill §2's table in place — it is the single environment block for every item in this file. **Re-runs after a fix (§4 item 5) record their build identity in the row's Result cell** (device/OS follow §2 unless the re-run moved devices); §2 keeps the first run's identity, and the fixed-build row is the record the completion claim rests on.

### 6.2 Item results

Statuses below are the authoring-time record, not observations.

| Item | Status as of authoring | Named dependency (what must clear it) | Result (owner fills) |
|---|---|---|---|
| DV-1 — stub → real playback flip ('भजन बजाऊ', unlinked) | **BLOCKED** | Owner's device (the Anzaan reference device) and a device Release build; unlinked state (no OD-S2 link needed for this item) | — |
| DV-2 — Spotify-preferred + scheme acceptance ('गीत चलाऊ', linked Premium) | **BLOCKED** | OD-S2 registration (Dashboard app, redirect scheme, client ID in the plist, household Premium account as a test user) + owner's device + the real Spotify account | — |
| DV-3 — explicit-YouTube routing unchanged ('युट्युबमा गीत चलाऊ') | **BLOCKED** | OD-S2 registration + the linked account + YouTube key present + owner's device | — |
| DV-4 — honest degradation lines (free-tier / unlinked / airplane mode / empty search; each repeated) | **BLOCKED** | Owner's device; sub-case (a) additionally the OD-S2 free-tier test account (or a temporary downgrade the owner accepts); sub-case (d) the linked state | — |
| DV-5 — Nepali end-to-end for DV-1…DV-4 | **BLOCKED** | Owner's device + the DV-1…DV-4 states (this item is a re-run of them, in Nepali) | — |
| DV-6 — Spotify app removed → honest app-absent path | **BLOCKED** | Owner's device + the linked/unlinked states; the Spotify app installed for removal | — |
| DV-7 — console/sysdiagnose capture during DV-1…DV-6 | **BLOCKED** | Owner's device + the OD-S2 registered accounts + the scripted session (it captures during DV-1…DV-6); the capture doubles as security obligation 6's device half | — |

### 6.3 Owner actions carried (decisions, not measurements)

| # | Owner action | Why it is the owner's | State |
|---|---|---|---|
| OA-1 | Complete the OD-S2 registration (§3, steps 1–6) and record the accepted redirect scheme | Console-side, account-owning work; not agent work (plan.md "Owner actions") | **In progress** — client ID provided and pasted (§3 step 4, 2026-10-07); app name / scheme acceptance / registered scopes / test users and the accepted-scheme record remain open |
| OA-2 | Execute DV-1…DV-7 on the Anzaan device against the Release build and fill §2/§6 | Only the owner has the device and the accounts | Open — BLOCKED |
| OA-3 | File the quota-extension request when §3 step 7's criteria hold; record the observed review window | Owner business/contact details; provider-side timeline | Open — not filed |
| OA-4 | If the household account is confirmed not Premium: record the DV-2 deep-link contingency outcome explicitly at final-sign-off | A deviation resolution, which FR-SP-017 reserves to the owner | Open — pending account confirmation |
| OA-5 | Resolve any FAIL or BLOCKED item: fix, re-run on the fixed build, or record an explicit owner resolution | FR-SP-017: an unmet item blocks the completion claim; deviation requires explicit owner resolution | Open |

### 6.4 Honesty notes about this record

- **No device model, iOS version, build identifier, measurement or outcome in this file is fabricated.** Where a value does not exist, the cell says it does not exist (`[OWNER INPUT]`).
- **The simulator is not used as a substitute.** No simulator observation fills any row, per FR-SP-017 and the T-124 implementation notes.
- **No item is marked passed, and no incomplete item is dressed up as complete.** The completion claim is blocked by FR-SP-017 until every item carries a result from the owner's device run.
- **The T-123 bundle stays authoritative for the security obligations.** This file is cited there for the DV-7 half only; nothing here closes O6 or O8 by itself.

## 7. Capture discipline — NFR-SP-002 applied to the capture and to this file

- **This file contains no sensitive material.** NFR-SP-002 and the M-1 discipline apply to the record itself: no credential, token, authorization-header value, PKCE verifier value, run-time query text, track title, track id or provider body is written into this file or its evidence fields. Evidence is a **line key**, a count, or a yes/no — never a transcript. The three scripted utterances of §5 ('भजन बजाऊ', 'गीत चलाऊ', 'युट्युबमा गीत चलाऊ') are protocol fixtures from the design (they appear verbatim in the constitution, design-l1 and the golden corpus); they are not captured user data and are the only query-shaped strings permitted here. The run-time empty-search utterance of DV-4(d) is chosen at run time and is **not** transcribed.
- **The DV-7 capture is scrubbed before attaching.** While capturing on device, the capture files themselves must not embed credentials or query text (T-124 implementation notes; NFR-SP-002). Inspect first (§5 DV-7 step 4); if a hit exists, describe it by shape and location only, keep the raw capture out of the repo, attach the redacted copy or record the scrub, and the item fails. An unscanned or unscrubbed capture is never attached.
- **This capture is security evidence obligation 6's device half.** `specs/SP-security-evidence-index.md` (O6, PASS-partial) names this record at the exact path `specs/SP-device-validation-protocol.md` as where the console/sysdiagnose half lands. Until DV-7 carries its result here, obligation 6's device half remains open, and no agent's word may move it.

## 8. Recording rules (mirroring the LCT precedent)

1. **Every row gets a value or BLOCKED with a reason.** No row is left blank, and no row is filled from a simulator observation. Every row names the device, OS version and build identifier it was observed on (the §2 block).
2. **Measurements and decisions are different columns.** An observed outcome is not a decision to change anything; owner decisions are recorded as such (§6.3).
3. **A failed check is a finding, not a tuning invitation.** Fixing an item is valid only with the observation and the fixed-build identity recorded next to it.
4. **This protocol is not edited to match the results.** Results go in §6. If an item turns out to be unexecutable as written, §6 records that and §5 is updated in a separate, visible edit.
