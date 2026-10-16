# Security Design Review — family-contacts-unify

**Task:** `security-design-review` · **Decision: SECURITY-GO**
**Worktree:** `/Users/anjan/workspace/projects/elderly-ai-assistant-family-contacts-unify` (branch `feat/family-contacts-unify`, HEAD `f6ba251b`; base master `8089c735`)
**Date:** 2026-10-12 · **Reviewer:** security reviewer (read-only; no artifacts modified)
**Artifacts under review:** `specs/design-l1.md` (frozen architecture), `specs/design-l2.md` rev 3 (design commit `e687f075`; `review-l2` GO at `f6ba251b`)
**Inputs:** `specs/family-contacts-unify/constitution.md`; root `constitution.md` (Safety & Compliance Delta, Standards); `specs/define-requirements.md` + `FR/`/`NFR/` (esp. FR-FCU-005/006/008/009/010/014, NFR-FCU-002/003/007); `.ai-sdd/workflows/family-contacts-unify.yaml` (security-design-review scope comment)

## 0. Scope, method, and verification limitation

Method: the design's own §6.3 STRIDE notes were explicitly **not** accepted as evidence. Every claim below was re-derived from the design text and independently checked against the worktree code at HEAD; where a claim rests on a pin (source scan, test suite) rather than existing code, the pin's infrastructure was verified to exist and the claim is marked accordingly.

Limitation (stated honestly): this is a **design-stage** review. The new files (`SystemContactLinkService.swift`, `SystemContactPhotoWriter.swift`, `FamilyContactIndex.swift`) do not exist yet; the write seam's real glue (`CNSaveRequest.execute`, read-back) cannot be exercised at unit level (`CNContactStore` is not fakeable) and is covered by the source-scan pin, `security-test`, and the DV-3/DV-4 device gates. The risk of *implementation* diverging from this design belongs to `implement` (paired review + confidence 0.85), `review-implementation`, and `security-test` (SECURITY-GO exit).

## 1. Preconditions verified in the worktree

| # | Claim / precondition | Evidence | Verdict |
|---|---|---|---|
| P1 | `specs/design-l1.md` exists (frozen) and `specs/design-l2.md` rev 3 is the reviewed revision | files read; `git log`: `e687f075` "design-l2 rev 3"; header names rev 3 | ✓ |
| P2 | `review-l2` GO exists (dependency satisfied) | `f6ba251b` | ✓ |
| P3 | No `CNSaveRequest` / `CNMutableContact` anywhere in the app today (the "first write" premise) | `grep -rn` over `ios/` (incl. tests): **0 hits**, both symbols | ✓ |
| P4 | `CNContactStore` is constructed only in `AddressBookDirectory.swift` today | `grep`: other mentions are comments only (`LeafViews.swift:900`, `MissedCallContactResolver.swift:23`) | ✓ |
| P5 | The source-scan pin's helper exists | `ios/ElderlyAssistantTests/Services/LiveTranslate/FeatureSourceScan.swift:39` (`swiftFiles(in:)`), `:62` (`codeText(of:)`) | ✓ |
| P6 | Release log gate is wired into the build | `ios/build.sh:431` runs `tools/check-release-log-safety.sh` | ✓ |
| P7 | LogSanitiser's allow-list contains every key the design's events use | `LogSanitiser.swift:56-65` — `outcome`, `state`, `error_code`, `duration_ms`, `entry_count`, `contact_id_hash` all present | ✓ |
| P8 | The runtime sanitise choke point is real | `AppCoordinator.swift:11666` — `let clean = sanitiser.sanitise(event)` on the bus implementation's `emit` | ✓ |
| P9 | `MissedCallContactResolver.matches` is the floor-8 trailing-digit rule the design reuses | `MissedCallContactResolver.swift:44-53` | ✓ |
| P10 | `ContactResolver` scores are `Double`; accept 0.6 / margin 0.15 at :61-62; rival rule strict `<` at :83-84 | `ContactResolver.swift:61-62,77,83-84` | ✓ |
| P11 | `ContactsAccess` currently collapses `.limited` via `@unknown default → .denied` | `AddressBookDirectory.swift:245-249` (enum), `:348-355` | ✓ |
| P12 | `FamilyContact` custom-decoder degrade pattern exists | `FamilyContactStore.swift:61-150` | ✓ |
| P13 | `ContactPhotoStore` matches the fallback description: ≤512 px JPEG q0.8, orientation baked, metadata stripped, `.completeFileProtection`, non-throwing, plain-filename guard | `ContactPhotoStore.swift:8-19,27-28,75-104,143-149` | ✓ |
| P14 | All six scoped suites named by the constitution + L10n suite exist | files present under `ios/ElderlyAssistantTests/` | ✓ |
| P15 | L10n catalog anchors cited by the design exist where claimed | catalog greps | ✓ |
| P16 | The five `AddressBookDirectory.access()` consumers + the wizard/switch sites are where the design says | verified per site (AppCoordinator `:8333-8346`, SettingsView `:2117/:2323-2338`, LeafViews `:1343/:1347-1362/:1368-1370/:1379-1388/:1413/:1519`) | ✓ (see F6) |
| P17 | Duplicate-claim premise: wizard records the picked row's `entry.normalized` as `numberKey` | `UnifiedContactSearch.swift:37-55`, `AddressBookDirectory.swift:46-76` | ✓ |
| P18 | Four live `contactPhoto(for:)` call sites exist (deletion is compile-verified); `DownsampledImageCache.contactFace` key is `contact:<filename>` | `SettingsView.swift:1596, :2710`; `LeafViews.swift:1161, :2650`; `ViewCaches.swift:211` | ✓ |

## 2. STRIDE threat model (independently verified)

### 2.1 Threats

| ID | Threat (entry point) | Mitigation in the design | Independent verification | Residual verdict |
|---|---|---|---|---|
| S-1 | Spoofing: wrong-contact photo write — a stale/reused identifier routes the save to a different person's card | Attempt-time fingerprint re-check BEFORE the request is built (§1.4 step 2, §6.2); read-back byte verification (§1.4 step 4) | The writer fetches by identifier, fingerprints with `matches` (P9), and only then builds the intent/request; a mismatch returns `.identityMismatch` with no request constructed | Acceptable (F8) |
| S-2 | Spoofing: wrong-person merge — an identifier now resolves to a different person | Refresh verification = record exists AND a current number satisfies `matches`; unverified links treated as ABSENT; stale line surfaced | Consumers read only the snapshot; `.empty`/unverified ⇒ today's unlinked behavior exactly | Acceptable |
| S-3 | Spoofing: a linked row over-claims reachability | Synthesized rows carry the FAMILY phone and channels; the caption only explains the book-side name | Caption key/`linkedBookNames` shape consistent with `Result.id = "family-<uuid>"` | Acceptable (informational) |
| S-4 | Spoofing/identity: voice resolution returns the wrong person | Conservative bands (1.00/0.90/0.85/0.80/0.75/0.60), margin 0.15, ties ⇒ ambiguity, near-miss exactly-one, family-roster-only candidates | Scores `Double` (P10); strict `<` rival rule re-derived — see math block | Acceptable (F2) |
| T-1 | Tampering: partial or other-field mutation of the system record | Single target file for `CNSaveRequest`/`CNMutableContact`; only `imageData` assigned; intent field-set asserted; read-back; actor serialization | Zero such construction today (P3); pin helper exists (P5); update-only, never add/delete | Acceptable (F1) |
| T-2 | Tampering: corrupt persisted payload | Decoder contract §3.4; separate `LegacyNicknameKeys`; empty identifier/numberKey ⇒ nil; synthesized encoder kept | Decode-degrade pattern verified (P12) | Strong |
| T-3 | Tampering: a second contact claims the same system record | Wizard steering + coordinator duplicate-claim guard + verification-side uniqueness (first in roster order wins) | `storedClaimant` uses the STORED link — defense in depth | Strong |
| T-4 | Tampering: unlink loses the displayed photo, or touches the system record | `SystemContactUnlinkMode` with copy-before-clear; `false` ⇒ link NOT cleared; unlink never writes the system record | Mode rule is pure and testable; no `CNSaveRequest` on the unlink path | Acceptable (F3) |
| T-5 | Tampering: dedupe hides a person or strands a call | Pass 3 fires only on VERIFIED links; SYNTHESIZE keeps the person findable; Pass 4 unchanged for unlinked pairs; recount before the limit slice | Current matched-only dedupe contract verified; `.nickname` tier insertion is additive | Strong |
| R-1 | Repudiation: write/unlink/refresh/claim-refusal leave no trace | §5.2 closed-vocabulary events, outcomes reason-coded | All metadata keys allow-listed (P7); runtime sanitiser choke point (P8) | Acceptable per house policy |
| I-1 | Information disclosure: PII reaching logs | Reason-code-only vocabularies; NO console writes in the three new files; FEATURE_ROOTS registration | Allowed keys (P7); gate rules + fixture harness (P6) | Acceptable |
| I-2 | Information disclosure: photo bytes / source metadata | Only the processed ≤512 px JPEG (metadata stripped) reaches the system record; display bytes downsampled; intent carries a hash; cache in-memory, 24/16 MiB | Pipeline claims verified against `ContactPhotoStore.swift` (P13) | Strong |
| I-3 | Information disclosure: identifiers in events | `contact_id_hash` declared but UNUSED; no identifier/nickname/name event fields | Key list verified; `imageBytesHash` is a sha256 prefix by construction | Strong |
| I-4 | Information disclosure: dishonest permission copy | `Info.plist:115` replacement adds the photo-update disclosure | Current copy is read/search-only (gap real); string-only edit — no new usage keys | Strong |
| I-5 | Information disclosure: alt caption reveals a book name | Re-displays a name already shown on ordinary book rows; suppressed when duplicating the family name | Design-internal | Neutral |
| D-1 | DoS: unbounded fetches/caches/loops | ≤12 identifiers per batch; NSCache 24/16 MiB; one fetch per cache miss; no retries/backoff/timeouts | `maxContacts = 12` verified; constants named | Acceptable |
| D-2 | DoS: crash loop from corrupt state | Decode-degrade; snapshot degrade; non-throwing photo store; checked casts; caught throws | Pattern verified; `try!`/force-casts absent from the write-seam contract | Strong |
| D-3 | DoS: refresh storms | Single-flight drain with latest-roster capture + coalescing; early-return when no link exists | Drain semantics coherent and terminating | Acceptable |
| D-4 | DoS: oversized strings entering the index/search | Editor caps 8 nicknames/contact; model/decoder accept more without failing | No length bound on entries or book-side names (F5) | Acceptable (low impact); F5 advisory |
| E-1 | Elevation of privilege: writing any other field or any other contact | Confinement to one file; update-only on the fingerprint-verified contact; single `imageData` assignment; source-scan pin | No such API today (P3); pin infra exists (P5) | Strong (F1 strengthens layer 2) |
| E-2 | Elevation of privilege: prompting/nagging outside user-initiated flows | Prompts only at the editor's photo step + pre-existing point-of-use paths; denied/limited never re-prompt | Existing `grantAccess` sites are user taps only | Strong |
| E-3 | Elevation of privilege: `.limited` silently collapsed or equality gates taking the else path | `.limited` + `allowsReading`; per-site enumeration; source-pin suite `ContactsAccessGateTests` | Independent enumeration matches (2 switches + equality sites + coordinator fifth site) | Strong (F6) |
| E-4 | Elevation of privilege: read-scope expansion under `.limited` | Reads limited to the GRANTED subset; writes attempt-based per-record | Matches Apple's limited-access model; removes a fail-closed collapse, does not widen beyond the grant | Acceptable |

### 2.2 Identity-integrity math — independent re-derivation

- 1.00 − 0.85 = `0.15000000000000002` → **not** `< 0.15` → name-exact resolves over nickname-exact (FR-FCU-014 scenario 2 holds).
- 0.90 vs 0.85 = 0.05 → ambiguous; 0.85 vs 0.80 = 0.0499… → ambiguous; 0.85 vs 0.75 = 0.10 → ambiguous; 0.85 vs 0.85 = 0.0 → ambiguous.
- New pairs from the 0.75 band land exactly on the margin: 0.90 − 0.75 = `0.15000000000000002` and 0.75 − 0.60 = `0.15000000000000002` → both **decisive** by the same representation artifact; not enumerated in the design's table or pins — advisory F2.
- Fingerprint: stored `numberKey` = the picked row's normalized number; verification accepts ANY current number satisfying `matches` (floor 8, trailing 8-10 digits; ADDED/kept verifies, changed/gone does not). Conservative direction confirmed.

### 2.3 Write authority — layer-by-layer verification

1. **File-local construction** — HOLDS as a design pin: zero `CNSaveRequest`/`CNMutableContact` today (P3); the only-writer file and source-scan test are specified; scan helper exists (P5); `CNContactStore` allowance list matches reality (P4). No bulk path: `update` of one fetched contact only.
2. **PhotoWriteIntent field-set assertion** — PARTIAL: single-case `PhotoWriteField` makes `fields == [.photo]` unfalsifiable; the `assert` is DEBUG-only. Effective enforcement = single-assignment construction + file confinement + review/security-test. Advisory F1.
3. **Read-back byte verification** — HOLDS: `.written` requires byte equality; anything else → `.failed(.readBackMismatch)` → fallback label (never a false success). The acknowledged imperfect-read case errs safe (false negative, never false positive) — F7.
4. **Attempt-time fingerprint re-check** — HOLDS: fetch → fingerprint → build → execute; a mismatch returns before any request exists — prevented, not detected (S-1).
5. **mutableCopy crash-safety** — HOLDS: L1's `as!` replaced by checked `as?` → `.failed(.saveRejected)` + DEBUG `assertionFailure`; no `try!`; `execute` throws caught.
6. **Serialization** — HOLDS: actor isolation; the refresh drain cannot interleave write attempts.

### 2.4 Degradation safety — outcome→state totality

The §1.5 mapping covers every outcome case and payload, total by construction (exhaustive switch, no default). No unhandled case. No false success (`.written` requires read-back equality). No crash paths. Permission states: skip-and-label for notDetermined/denied (no prompt, no nag), attempt-and-detect for limited/full. One comment inconsistency (F4) — no security impact.

## 3. Security checklist (template mapped to this app)

| Checklist item | Verdict | Basis |
|---|---|---|
| Data flows identified; transit encryption | PASS — on-device only; no network transit surface exists in this feature at all | NFR-FCU-003 by construction |
| PII identified with handling specified | PASS with one advisory — names/numbers/nicknames/photos/identifiers/link; display on owner/parent surfaces; logs reason-code-only; caches bounded; strings not length-bounded (F5) | §4.3/§5.2/§3.4, P7/P8/P13 |
| Input validation for external inputs | PASS with advisory — identifier non-emptiness gated; digits()/matches filtering; plain-filename guard; decode-degrade; Text-only sinks; missing explicit length caps (F5) | P9/P12/P13 |
| Audit logging covers security-relevant events | PASS — write/unlink/refresh/claim-refusal all reason-coded with allow-listed metadata; console-only sink is the stated residual | §5.2/P7/P8 |
| Secrets management | PASS (N/A) — no credentials, keys or tokens introduced; access is OS-mediated | §1.4/§9.3 |
| Least privilege | PASS — photo-field-only write on the verified-linked record; key-scoped fetches; limited access respected per-record; no new usage keys | P3/P4/P11 |
| Compliance traceability (App Store, disclosure, limited-access honesty) | PASS — point-of-use plain-language copy; honest NSContactsUsageDescription; never claims an unverified write; limited-access honesty on both search surfaces | FR-FCU-009, NFR-FCU-002/003 |
| Explicit error return types | PASS — typed outcome enums, documented-Optional seams, no `any`/`unknown`; `@unknown default` fails closed | §1.1-§1.9 |
| Async/external failure modes + recovery | PASS — every seam has a typed degrade path | §1.3-§1.5, §4.5, §5 |
| Timeouts/retries configurable, not hardcoded | PASS — none introduced; future waits must be named constants; cache/limit constants are named statics | §4.5/§6.2 |
| Every element traces to an FR/NFR | PASS — L1 §18 and L2 §10 tables | |
| Design describes what the operator sees on run and failure | PASS — full fallback label table, source caption, stale-link line, steering cards; one internal comment inconsistency (F4) | §1.5/§2.2-§2.6 |

## 4. Findings (advisory — **no blocking findings**)

- **F1 — LOW — `PhotoWriteIntent` assertion is documentation-grade, not an enforcement layer.** Recommendation (for `security-test` + writer tests): add a source-level assertion that no property other than `imageData` is assigned on the mutable contact and that `CNSaveRequest` usage is `update`-only, alongside the existing confinement scan.
- **F2 — LOW — Two new band pairs sit exactly on the ambiguity margin and are decisive but unpinned.** 0.90 vs 0.75 and 0.75 vs 0.60 → `0.15000000000000002` ≥ 0.15 → NOT ambiguous. Recommendation: add explicit `ContactResolverTests` consequence-table rows pinning both pairs (and keep the 1.00/0.85 row).
- **F3 — LOW — `unlinkKeepingDisplayedPhotoLocally` must set the contact's `photoFilename` to the copied file.** State it in the implement task spec and pin it in coordinator tests.
- **F4 — INFO — §2.6's comment (`.written`/`.skippedNoLink` → dismiss) contradicts §1.5's mapping (`.written` → `.updatedInSystem`, shown).** Both honest; pick one at implement (recommend: show the label) and align the comment.
- **F5 — INFO — No length bounds on externally-sourced strings.** Recommend: cap stored nickname length in `normalizedNicknames` (e.g. 64 chars) or add a worst-case long-string assertion to the §6.1 perf tests.
- **F6 — INFO — One adjacent `allEntries()` consumer (`AppCoordinator.makeDialectBiasProfileProvider` :2529) is outside the R2 enumeration.** Behavior unchanged by this feature; record it in §3.5's list (or footnote) so the claim stays exact.
- **F7 — INFO — Accepted honest false-negative: `.failed(.readBackMismatch)` can show "Kept in this app only" while the system record received the photo.** Safe direction (never a false success); keep as-is.
- **F8 — INFO — Shared-number fingerprint residual (S-1/S-2):** two distinct cards sharing the dialled number would pass the fingerprint if an identifier is reused. Extremely low likelihood and bounded (one photo field of a card the owner believed was the linked person). Recorded as accepted residual for `security-test`.

## 5. Accepted residual risks (recorded)

1. Write-seam real glue is unit-untestable (`CNContactStore` not fakeable): covered by source-scan pin + `security-test` + DV-3/DV-4 device evidence.
2. `request.update` writes the fetched snapshot back; minimal fetch keys limit materialised fields; any throw degrades to a labeled fallback.
3. New coordinator/UI lines remain outside the gate's rules 3-6 (documented §5.3); bounded by rules 1-2, the runtime allow-list choke point (P8), review, and `security-test`.
4. Audit events are console-only (existing house infrastructure).
5. `.limited` readable semantics: a deliberate, bounded scope correction (the user's granted subset), pinned per site (E-3, F6).
6. English-only usage strings (pre-existing project pattern).

## 6. Decision

**SECURITY-GO.**

The STRIDE analysis found no blocking weakness. The write-authority design satisfies the workflow's bar ("a wrong-contact write is prevented, not just detected"): target chosen once (fetch → fingerprint → build → execute), confinement pinned by a source scan, read-back gates every success claim, no crash path, and the wrong-contact direction requires a compound coincidence (F8). Identity integrity holds independently verified (ambiguity math re-derived exactly; ties refuse to dial; stale links degrade without false merges; unlink never writes the system record and never loses the displayed photo). Degradation is total by construction; no false success; PII discipline enforced by verified allow-listed keys, closed vocabularies, and the release gate; no new egress, permissions, or data collection.

Advisory findings F1-F8 are carried into `security-test` expectations and the implement task specs (F1/F2/F3 close the remaining "enforced vs inferred" gaps); none gates implementation.
