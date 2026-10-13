# review-implementation — family-contacts-unify (phase-end full-diff review)

**Decision: GO** · **Confidence: 0.93** (threshold 0.85)
**Reviewer:** review-implementation (ai-sdd overlays reviewer) · **Date:** 2026-10-12
**Worktree:** `elderly-ai-assistant-family-contacts-unify` @ `feat/family-contacts-unify`, HEAD `e7158a26`
**Diff under review:** `81de796a..HEAD` (153 files; merge-base = the master merge 81de796a on the branch). Feature work spans T-144..T-165 plus amendments 1-2. Per-unit reviews were deferred to this phase-end review by the owner's speed-mode directive (plan amendment 2); this report discharges them.
**Read-only:** no artifact was modified; no ai-sdd command was run.

---

## 1. Verdict per checklist item

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | `SystemContactLink` + `FamilyContact` model/decoder | PASS | Presence-wins decode for `nicknames`; `LegacyNicknameKeys` in a separate container (only read, never written); corrupt/blank link fields decode to nil; synthesized encoder kept; `normalizedNicknames` trims/drops/preserves; `cappedNickname` 64-Character grapheme-safe prefix. Migration tests exist (single-nickname lossless, optional-fields nil). |
| 2 | `VerifiedLinksSnapshot` + `SystemContactLinkService` drain (§4.2) | PASS | Single-flight coalescing with LATEST `pendingContacts` capture (one documented `Task.yield()` window); one batched verification fetch; duplicate claims first-in-roster-order; degraded publish guarded on `allowsReading`; empty-links roster publishes without a store call; photo cache 24/16 MiB/16-hex keys; `invalidate` async (documented deviation 1); closed-vocabulary events; no console writes; no network. |
| 3 | `SystemContactPhotoWriter` attempt sequence + confinement | PASS | Exact §1.4 sequence: preAttempt → fetch → throw/empty classification → fingerprint BEFORE any request → `assert(isPhotoConfined)` → checked `as? CNMutableContact` → single `imageData` assignment → update-only request → do/catch → read-back byte equality (`.unverifiable` never success). `FamilyPhotoEditorState.from` exhaustive no-default. Raw failure values ARE the log codes. No `try!`, no force casts. |
| 4 | `FamilyContactIndex` (§1.2) | PASS | Pure value; roster order; multi-valued `idsByNickname` (empty keys never indexed); one normalize pass via `NepaliTextNormalizer` only; `.empty` anchor; rebuild semantics pinned. |
| 5 | `UnifiedContactSearch` Passes 1-5 (§1.6) | PASS | Pass 1 tiers incl. nickname via O(1) map + Character-safe substring; Pass 2 unchanged; Pass 3 linkMerge (empty-snapshot short-circuit; no phantom drop; one synthesized row per person; name-equal suppression; `linkedBookNames` keyed by `Result.family(contact).id`); Pass 4 unchanged; Pass 5 recount. Signature requires `index:`; all four production call sites updated; zero stale `SystemContactSearch.search` call sites; zero `contactPhoto(for:` references (T-157 deletion confirmed). |
| 6 | `ContactResolver` bands (§1.7) | PASS | Bands 1.00/0.90/0.85/0.80/0.75/0.60; accept 0.6, margin 0.15 unchanged; `indexProvider` injected; publish-lag fallback (costs time, never a wrong answer); `nearMiss` counts CONTACTS. F2 consequence pins present (1.00−0.85 == 0.15000000000000002). |
| 7 | `MissedCallContactResolver` order (§1.8) | PASS | familyMatch → linkedFamilyMatch (roster order, snapshot-only) → `allowsReading` gate → nativeMatch with verified-link identifier remap → unresolved. Never consults stored claims or native internals. |
| 8 | Coordinator seams (§1.9) | PASS | `familyContacts.didSet` = single choke point (unlinked roster never touches the address book); generation-guarded publish; `faceEpoch` bumps exactly on identity change; duplicate-claim guard refuses BEFORE any write; add/update widened to `nicknames:` + `link:`; `unlinkMode` pure total rule; `setFamilyContactLink` copy-before-clear with never-lose refusal, ONE atomic record write, orphan cleanup, never writes the system record (source-pinned); `syncSystemPhoto` thin delegation; lazy first-use seams; `familyContact(matchingPhone:)` own-phone-first then snapshot; `refreshContactsIdentity` ordering; boot assigns through the choke point. |
| 9 | Wizard states (§2.1-§2.7) | PASS | State set exactly as specified; find step runs the unified engine with the PUBLISHED index+links; draftLink non-empty-identifier guard; 4-state link section with live roster row; steering in-place sheet swap; photo step caption/cards/outcome line; nickname list with 8-cap add row, ≥44 pt removes, `cappedNickname`; save flow per §2.6; `loadDraft` loads the FULL list; async face via `faceImageWithSource`. |
| 10 | CallView caption + gates (§3.5) | PASS | All six gate sites → `allowsReading`; `call.search.accessLimited` caption leads the readable block; synthesized-row caption composed from `linkedBookNames` (defaulted `caption: String? = nil`); family list chip (verified links only, ≥44 pt, a11y label); batch face passes with post-await re-checks. Call-dialer dial layer untouched. |
| 11 | L10n pins (§7) | PASS | All 21 frozen keys present exactly once; 7 keys sampled verbatim en+ne match; live catalog count = 1,415 (= 1389+5+21; per-feature pins 1_396/1_410); the 22-line contiguity pin present. |
| 12 | Log-safety roots + gates | PASS | `FEATURE_ROOTS` = our three files + call-dialer's `Services/Calls` (union intact); live gate run exit 0; `Info.plist` diff = exactly the frozen disclosure string, NO new keys. |
| 13 | Faces / cache contract (§4.3-§4.4) | PASS | Identity `<id>:<token>:<filename>:<epoch>` with the `-` / `link-nil` literals; token map written ONLY inside the `@MainActor` face path; system bytes downsampled before return; `sysphoto:` / `contact:` families distinct; precedence in ONE pass (`faceImageWithSource`). |

## 2. The five T-163 test-side corrections

Commit `e46c3ed1` numstat: changes ONLY under `ElderlyAssistantTests/` (5 files), `project.pbxproj` (test-target references only), and spec/state files. **Zero production files.** Each correction read at its cited site: 2.1 fixture arithmetic (सीता = 2 clusters) with count guards; 2.2 order pin moved to `search()` (the layer that owns ranking); 2.3/2.4 atomic test-collector append + invalidate expectation corrected; 2.5/2.6 lazy-var Mirror labels (`$__lazy_storage_$_<name>`) making the not-built pins real; 2.7 photo-bearing fixtures reaching the writer; 2.8 per-coordinator roster restructure (init publishes empty by design); 2.9 bounded re-read search anchoring after the prompt. All right.

## 3. Full-bundle attribution honesty

7062 total / 7030 passed / 22 failed / 10 skipped; **FCU-touched suites failing = 0**; zero (a), zero (c); all 22 attributed (b) pre-existing at baseline `81de796a` with per-suite evidence and interleaved reruns. Three riskiest rows independently spot-checked: LiveTranslateAllowList (the three `correction_*` keys exist at `LogSanitiser.swift:143-148`; diff touches neither — master staleness from PR #162), Piper wedge (Speaker.swift untouched; identical baseline probe), SnapshotMode/Pipeline flakes (paths untouched; red at baseline; bimodal OCR-timing signature). Attempt-1 abort recorded, timeout guard disclosed.

## 4. Error paths + totality

`FamilyPhotoEditorState.from` exhaustive no-default; `.written` requires byte equality (no false-success path); decode degrades; zero `try!`/`as!`/`fatalError` in new code (the single cast is checked); no timeouts/retries by documented design (event-driven re-triggering).

## 5. PII/log safety + egress (NFR-FCU-002/003)

Closed vocabularies only; metadata `[:]` or state tokens; zero console writes in the three new files and in any added diff line; zero network primitives across the feature files; no new Info.plist keys; live release gate exit 0.

## 6. Devanagari/grapheme pin (NFR-FCU-007)

No new grapheme logic: index normalizes via the existing normalizer; substring reuses `range(of:options:[.caseInsensitive,.diacriticInsensitive])`; `cappedNickname` caps by whole-Character prefix; positive AND negative pins present; store-as-entered (OD-2) honored everywhere.

## 7. Call-dialer union (NFR-FCU-008)

Zero diff lines mentioning `secondaryCallApp` / `resolvedCallChannel` / `missedCallDialAction` / `MethodResolver` / `CallChannelChain`; union points intact (FEATURE_ROOTS, catalog 1,415, evidence union); our resolution upstream (choose the person), their chain downstream (choose the channel).

## 8. Migration (NFR-FCU-006)

Decoder + fixtures + tests verified; DV-6 (device staging) recorded BLOCKED with its dependency named — honest, not claimed.

## 9. Operator-visible honesty

Verified: verified-only chip; linked-to / stale / pick-hint lines; unlink hint copy visible AND as a11y hint; steering sentence + ≥44 pt edit button; source caption ONLY when the displayed face is the system one; four honest post-save states; accessLimited captions on both surfaces; F4 `.written` → label shown, sheet stays open. a11y labels/hints and tap floors pinned by the unit suites.

## 10. Out-of-scope check

Nothing absorbed from call-dialer; no new egress; no emergency-semantics change; CallView dial path untouched; all 16 production files in the diff map to named symbols in the design §8.2 placement table.

## 11. Findings (none blocking)

- F-1 (minor, documentation): design §8.3 names `ContactsAccessGateTests`; the shipped pins live in three scoped suites (recorded as R-8 in the evidence index). Pins verified green; consume R-8 as-is.
- F-2 (minor, noted in code): `familyMatches` has no on-the-fly normalization fallback for an index-missing contact (unlike the resolver); documented in-code; all production call sites pass the published index.
- F-3 (expected, tracked): DV-1..6 execution outstanding — every item BLOCKED with its named dependency; final sign-off holds on it (FR-FCU-017). The tracked completion gate, not a defect.
- F-4 (advisory for security-test): the F8 shared-number fingerprint residual remains accepted-for-DV; re-confirm against `FCU-security-evidence-index.md`.

## 12. Deferred-review discharge (speed mode, amendment 2)

The amendment deferred per-unit reviews to this phase-end review. Discharged: all 13 checklist themes verified directly from source against design-l2 rev 3 (not the unit notes); the five T-163 corrections verified genuinely test-side and correct; full-bundle attribution spot-checked; live re-runs during this review (release gate exit 0, catalog 1,415, frozen-copy checks, call-site/deletion scans: 0 stale unified-search-call sites, 0 `contactPhoto(for:` references, 0 call-dialer symbol touches). What remains deferred, correctly: DV-1..6 DEVICE execution (owner/device-dependent; protocol ready; BLOCKED by design) and the downstream `security-test` / `final-sign-off` gates.

**GO.** All criteria met: the implementation conforms to design-l2 rev 3 across interfaces, wizard, model/decoder, concurrency, observability and placement; the deferred per-unit reviews are discharged with direct source evidence; the recorded gates are honest and independently spot-checked; the only open item is the by-design DV-1..6 device run, which the workflow already holds at final sign-off.
