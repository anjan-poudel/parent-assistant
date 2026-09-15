# T-054 — Capture Schema & Egress Contract: the design

**Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/T-054-capture-schema-egress-contract-design.md`
**Worktree:** `.claude/worktrees/t054-capture-egress` (branch `worktree-t054-capture-egress`, base master `df4ab51`).
**Scope discipline:** documentation only. No production code changed, no build, no test run, no training run, no device access, no merge, no push. This design is a **binding input** to T-055, T-056, T-057, T-058 and the audit criterion for T-059.

**Binding inputs (read for this design, not recalled).** `specs/T-052-notes.md` rev 2 (FEASIBLE-WITH-CONDITIONS; C-1…C-7; M0–M10) and `specs/T-053-notes.md` rev 2 (GO-WITH-CONDITIONS; C-1…C-9; §2.2 field audit; §3.4–§3.6; §4/T3; §5.4; §6; §7; §8; §9) are treated as **fixed constraints, not options**. The loop design (`docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md`, D-1…D-4, §4, §5) fixes the shape. Everything else below is read from the code as it is at `df4ab51` and cited to the line numbers as they are **here**.

**Two premises in this task's own brief are stale, and this design corrects them rather than designing around them** (T-052 §14 flags the first explicitly):

1. *"the confidence signal is not derivable today (no confidence field exists)"* — **false since `f2cbbab`.** `Record.confidence: Double?` ships and is populated for every voice-originated `call` record (`IntentLogStore.swift:50`, `:76-87`; T-052 §3.4). So the acceptance criterion's "at minimum the confidence signal, **if** T-052 found it absent" resolves to **absent? no — present**. No capture field is added for confidence. T-052 rev 2 §12 withdrew rev 1's `confidenceBucket` capture proposal for exactly this reason; a confidence *bucket* is now an **egress** decision (§3.2 below), not a capture gap.
2. *"`Record` is a plain `Codable` struct … a non-optional new field would make every existing on-disk line fail to decode"* — the **requirement stands, the premise does not.** A tolerant `init(from:)` now exists (`IntentLogStore.swift:76-87`) and legacy lines are pinned by `IntentLogStoreTests.testLegacyRecordWithoutConfidenceDecodes`. The decode-compatibility obligation is still discharged here as a design-stage test vector (§2.5), because it constrains the shape.

**The field that is genuinely missing is the utterance.** `Record` carries no transcript and no join key to one (`IntentLogStore.swift:27-51`), so the shipped yield is **0 rows** (T-052 §4, §8.2). §2.1 decides the utterance-vs-join-key question with evidence.

**Status: every ruling below is a yes/no, a field name, a number, or a named owner with a date, so T-059 can check it mechanically.** Eight conditions are added to T-053's series (§9, C-10…C-17), twelve of T-053's rulings are refined with reasons (§10, R-1…R-12), and five items are escalated rather than decided unilaterally (§11). Ids are namespaced so a checker can cite one unambiguously: **`RF-n`** is a capture-schema field, **`L-n`** a loop-owned artifact, **`F-n`** a finding, **`C-n`** a condition, **`R-n`** a refinement.

---

## 0. The two contracts in one line, and the decisions taken here

### 0.1 The contracts in one line

1. **The capture record gains exactly one loop-only field, and the words it references live in a separate opt-in-gated store.** The record carries an **opaque, on-device, salted handle** for the utterance — never the utterance. With the opt-in OFF the record is field-for-field the shipped record (C-7).
2. **The egress payload is a fixed-size, weekly, CBOR-encoded envelope carrying day-granular records built from an enumerated schema — never a serialisation of `Record`.** Seven fields per record, no maps, no free text, no nulls, no install pseudonym, no content digest. It is permissioned by an explicit, revocable opt-in whose scope is the payload version.

### 0.2 The decisions taken here

| # | Decision | Where |
|---|---|---|
| **D-A** | **Join key, not utterance.** `Record.utteranceHandle: String?` — `HMAC-SHA256(salt, normalize(transcript))` truncated to 16 hex — **plus** a separate loop-owned, opt-in-gated, encrypted content store holding `handle → sanitised transcript`. The utterance is **never** a `Record` field. | §2.1–§2.3 |
| **D-B** | **A mined cursor, not a derived-signal digest.** T-052 §6.2 measured the 500-cap as non-binding (break-even ≈ 71 records/day sustained); the real gap is **addressing**, so this design specifies one loop-owned cursor artifact with two high-water marks. | §2.6 |
| **D-C** | **The payload is versioned, enumerated and minimal.** A field is carried only if no other payload field determines it, so `path_class` and `slot_keys` are **dropped**. | §3.1–§3.3 |
| **D-D** | **Every weekly upload is exactly 256 KiB, unconditionally — including a zero-signal week.** Timing and size must not correlate with the household's week (C-3). | §3.6 |
| **D-E** | **Content never rides the loop's egress.** Mined rows leave only as a separate bundle by an explicit family act, ingested through `--consent-export`; the loop's automated channel carries the hashed signal only. | §4.1–§4.3 |
| **D-F** | **The consent's scope is the payload version, and its state machine has five states with named data effects.** The opt-out is destructive on-device and irreversible; it cannot recall what was sent, and the copy says so. | §5.1 |

### 0.3 Head-line findings

| # | Finding | Where |
|---|---|---|
| **F-1** | **The join key must be a function of the normalized transcript, not `Record.id`.** T-052 M2 (correction recurrence) and M7 (low-confidence cluster) both count *the same utterance appearing ≥ 2 / ≥ 3 times*, which only a content-derived key can group. `Record.id` is fresh per record and joins nothing (T-052 §3.1). | §2.1 |
| **F-2** | **The utterance cannot go on `Record`, and the reason is `exportURL()`.** `exportURL()` serialises **every** `Record` field to the family's shared file (`IntentLogStore.swift:149-164`, `:155-157`). A transcript on `Record` would therefore ride the pre-existing family export on the day it ships — which is the one path on which content leaves, and C-6 forbids the loop reusing or extending it. A **handle** on `Record` carries no words; the words stay in a store `exportURL()` never reads. | §2.1, §2.3 |
| **F-3** | **`IntentCommandCache` is not the join, and cannot be.** It is an always-on performance structure: `maxEntries = 200` LRU (`IntentCommandCache.swift:42`), gated to three cacheable actions (`:51-65`), with no time-based expiry, and it stores **only** the normalized key and the command — not the transcript. It is not opt-in-gated, so mining it would read content the loop's consent did not create, and opting out could not delete it without breaking a shipped feature. Named as a **non-choice**, with the reason. | §2.1 |
| **F-4** | **`path_class` must be dropped from the payload, and that is the *comfortable* reading of T-053's ruling.** T-053 §2.2 row 4 permits the field only if the observed set is enumerated; the observed set is `{model, override}` and the two are **fully determined by `outcome`** (`override` ⟺ `corrected`). Carrying it would add no information and a value space the field's own docstring already proves unstable (`IntentLogStore.swift:30` documents five values, one of which is real). | §3.2 |
| **F-5** | **"One scrambled code for each sentence" in T-053's own consent copy is discharged by the per-record pseudonym — a keyed digest of `Record.id`, never of the utterance.** T-053 §3.4 says "hashes are for per-record identity and dedup only" and §4/T4 rule 1 forbids content digests; §2.2 row 2 authorises `HMAC(salt, id)` truncated to 16 hex. The copy and the hash ruling therefore agree, and the payload **must** carry that field for C-5 to hold. | §3.2, §3.4 |
| **F-6** | **The loop's envelope must NOT inherit the channel family's `timestamp`.** `docs/remote-config-channel-design.md:15` and `:60-62` carry an ISO-8601 timestamp (inner) and an E2E CBOR envelope `{v, sender_id_hash, ciphertext, mac}` (outer). T-053 §3.3 forbids any egress timestamp finer than a day and any timezone, so the loop rides the family's **encoding and no-PII discipline**, not its envelope shape, and carries a week bucket instead. | §3.5 |
| **F-7** | **The `--consent-export` refusal is a *nominal* guard today, because `--sources` is an open side door.** `run_encoder_pipeline.py:387-392` refuses loudly and exits 3, but `--sources` accepts arbitrary JSONL paths (`:372-373`, `:397-399`, `:437-442`), so the same rows would enter through it with no consent check at all. The design's own §4.3 warns about a side door; it already exists, and closing it is part of the ingestion contract. | §4.3 |
| **F-8** | **`annotation_rules.yaml`'s recorded bundle source is now wrong.** `governance.real_user_data.bundle_source` names `IntentLogStore.exportURL()` (`annotation_rules.yaml:251`) — the family export — which C-6 forbids the loop from reusing, and which cannot be mined anyway (it carries no utterance). T-057 must amend it; the replacement text is fixed here. | §4.5 |
| **F-9** | **The 90-day egress clock and the consent's `accepted_at` are two different filters, and both are needed.** T-053 §6 fixes the 90-day bound; nothing in T-053 stops a record written *before* the opt-in from egressing afterwards. The eligibility rule is `timestamp >= max(consent.accepted_at, seal_time - 90d)`. | §3.8 |
| **F-10** | **The loop content store is strictly better protected than the store it extends.** `IntentLogStore` is plaintext JSONL in Application Support (`.complete` file protection, **not** excluded from backup). The loop's content store uses the project's existing encrypted channel with `isExcludedFromBackup`, following `LocalToolLogStore` — the shipped precedent for a store that holds user text. | §2.3 |

---

## 1. Ground truth read for this design

Every claim below is a file read at this revision, not recalled.

| Fact | Source (verified at `df4ab51`) |
|---|---|
| `Record` fields: `id: UUID`, `timestamp: Date`, `path: String`, `action: String`, `slots: [String:String]?`, `outcome: String`, `correctedTo: [String:String]?`, `confidence: Double?`, `latencyMs: Int?` | `IntentLogStore.swift:27-51` |
| Tolerant decode: five mandatory keys with bare `try`, four optional with `try? decodeIfPresent`; unknown keys ignored; a line missing a mandatory key is dropped by `readAll`'s `compactMap` | `IntentLogStore.swift:76-87`, `:172-178` |
| Default date strategy: `JSONEncoder`/`JSONDecoder` with **no** custom strategy — dates are `timeIntervalSinceReferenceDate` doubles | `IntentLogStore.swift:116`, `:156`, `:176`, `:182` |
| `exportURL()` serialises **every** `Record` field to `tmp/sahayak-intent-log-<ISO8601>.jsonl`, sets **no** protection attribute, deletes nothing afterwards | `IntentLogStore.swift:149-164` |
| Cap `maxRecords = 500`; trim fires only above `maxRecords + 50` (= 552nd record); store holds everything until then | `IntentLogStore.swift:90`, `:110-135` |
| Store directory created with `.protectionKey: FileProtectionType.complete`; the rewrite path re-applies it | `IntentLogStore.swift:104-105`, `:180-187` |
| Verdict vocabulary `confirmed / denied / corrected / timeout`, raw values are a storage format | `IntentLogStore.swift:197-207` |
| `Capture` = `{action, slots, confidence, requestedAt}`; `record(_:path:correctedTo:at:)` is the single verdict→record mapping; `latencyMs` floored at 0, nil when the start is unknown | `IntentLogStore.swift:219-260` |
| One append seam `appendCapture` and **seven** callers: `AppCoordinator.swift:5301`, `:5481`, `:5617`, `:7141`, `:7143`, `:7197`, `:7222` | T-052 §3.2; seam at `AppCoordinator.swift:7127-7132` |
| `IntentCommandCache`: `maxEntries = 200`, LRU by `lastUsedAt`, keyed by `NepaliTextNormalizer.normalize(transcript)`, stores `{command, createdAt, lastUsedAt, hitCount}` — **not** the transcript; cacheable actions are `call`, `music`, `suggestVideo` only | `IntentCommandCache.swift:32-42`, `:51-65`, `:70-103` |
| Family export path is the `ShareLink` on `IntentLogStore.exportURL()` in the read-only review screen | `IntentLogReviewView.swift:28` |
| `ConsoleObservabilityBus.emit` sanitises then `print`s: timestamp, component, eventType, outcome, errorCode, **sanitised** metadata | `AppCoordinator.swift:7829-7850` |
| `LogSanitiser.allowedKeys` is a closed set of twenty keys; unknown metadata keys are dropped; `error_code` is charset- and length-bounded. **The set already contains two id hashes — `entry_id_hash`, `contact_id_hash`** (see §8) | `LogSanitiser.swift:56-78`, `:94-96`, `:116-133` |
| `KeychainEncryptedStorage`: `kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false` | `KeychainEncryptedStorage.swift:82`, `:105` |
| `EncryptedFileStorage`: `.atomic, .completeFileProtection` on write, then `isExcludedFromBackup` | `EncryptedFileStorage.swift:155-156`, `:212-217` |
| `StoragePlacementPolicy` defaults every key to `.encryptedFile`; only an explicit `keychainResidentKeys` set is Keychain-resident | `StoragePlacement.swift:44-53`, `:55-57` |
| `LocalToolLogStore` — the shipped precedent for user-text content — uses the encrypted channel, not plaintext JSONL | `LocalToolLogStore.swift:66-76`, `:93` |
| Remote-config channel: E2E CBOR envelope `{v, sender_id_hash, ciphertext, mac}`; inner payload `{v, alert_type, timestamp}` (ISO-8601); no-PII rule; 8 KB blob cap; 24 h TTL; exponential backoff up to 1 h; "no payload, no `convId` in logs" | `docs/remote-config-channel-design.md:15`, `:38`, `:60-62`, `:69-78`, `:103-116` |
| T-034 row format `{id, utterance, action, register, source, confidence, spans, slots}`; validator requires `id`, `utterance`, `action ∈ VALID_ACTIONS`, `register` (non-noised), `source`, `confidence ∈ [0,1]` | `build_encoder_dataset.py:5-12`, `:219-252`, `:282-284` |
| Bucket assignment: a row whose `source` prefix is `stt_noise` is `stt_noised`; everything else is classified by `register` | `build_encoder_dataset.py:296-300` |
| Twelve schema-v2 action ids (the only legal labels); `plugin` is runtime-only and must stay absent from every training row | `annotation_rules.yaml:31-46` |
| `--consent-export` refusal: `[guard] REFUSED: … not implemented (NFR-015)`, `return EXIT_GUARD` (= 3); pinned by a test | `run_encoder_pipeline.py:387-392`; `tests/test_encoder_pipeline.py:337-341` |
| Run-manifest consent block: `{"real_user_rows": 0, "consent_export_ingestion": "not implemented (NFR-015); --consent-export refuses loudly"}` | `run_encoder_pipeline.py:598-600` |
| Recorded governance: `admission: explicit_consent_export_bundle`; the run manifest records the bundle's **opaque export reference (never its content)**; refuse bundles without a consent/export record and flag the encryption gap | `annotation_rules.yaml:249-256` |
| `--sources` accepts arbitrary paths (comma- or space-separated) | `run_encoder_pipeline.py:372-373`, `:437-442` |
| Exit codes: `EXIT_USAGE=2`, `EXIT_GUARD=3`, `EXIT_FLOOR=4`, `EXIT_STAGE=1`; `GuardError` printed as `[guard] REFUSED: …` | `pipeline_guards.py:33-42` |
| Open Decision 12: scope closed at "voice transcription (and only that)"; consent + plain-language disclosure at the point of selection; **visible indicator** while a cloud engine is active; switching back must not lose functionality; re-review by 2026-10-13 | `constitution.md:128-132` |
| NFR-011 TLS 1.2+, and connections failing certificate validation must be rejected; NFR-015; NFR-016; NFR-023; NFR-024; NFR-032 | `requirements.md:246-247`, `:262-266`, `:294-298`, `:329-330` |
| Settings precedents: opt-in card `cloudFallbackCard` (an explicit **"OPT-IN"** label, a three-state honest caption — `requiresKey` / `on` / `off` — and a caption colour that changes with the state); honest interpreter-state caption at `SettingsView.swift:1109-1118` (`[LAT-M3]`: *"one line stating which interpreter answers … so the caption can never disagree with what the chain actually does next"*); recovering diagnostics card at `:253-269` (disappears the moment every failure recovers); the point-of-use plain-language ask card (`askMicCard`, `VoiceSettingsView.swift:514-543`: a plain-language card first, the system prompt only after the user taps Allow) | `SettingsView.swift:1148-1182`, `:1109-1118`, `:253-269`; `VoiceSettingsView.swift:514-543` |
| Strings live in one String Catalog with `en` + `ne`; `L10n.str(_:locale:)` for non-View code | `Resources/Localizable.xcstrings`; `AppLanguage.swift` |

**No `settings.learningLoop.*` key exists yet** (`Localizable.xcstrings` contains zero). §5.3 is therefore the whole string set T-056 lands, not a delta to an existing one.

---

## 2. Decision A — the opt-in-gated capture schema

### 2.1 Utterance or join key — the decision, with evidence

**RULING: the join key. `Record` gains one optional field, `utteranceHandle: String?`, and the transcript it references lives in a separate loop-owned, opt-in-gated content store. No utterance text is ever written to `Record`.**

The evidence, in the order it decided the question:

1. **T-052 §4.1 names both options and recommends the key.** Its words: *"This report recommends (2) — the join key — for the log, and (1) only if T-053's consent determination concludes that the log itself may hold text."* T-053 did **not** so conclude: §2.2 row 1 classifies the utterance surface **never-leaves** and says it *"Stays absent from both the record and the payload"*, while permitting an on-device handle *"resolved at MINE time … and must never egress."* The condition on T-052's option (1) failed, so option (1) is closed. T-052 C-1's own wording — *"an utterance (or an utterance join key)"* — is satisfied either way.

2. **`exportURL()` serialises every `Record` field (`IntentLogStore.swift:149-164`, `:155-157`).** This is decisive and is not a consideration T-052 or T-053 had. A transcript on `Record` would be written into the family's shared file by the pre-existing export, unchanged code and unchanged user act. That is content leaving the device on a path the loop did not design, did not disclose, and may not touch (C-6: *"never writes to, reuses, or extends the family export path"*). No amount of opt-in gating fixes it: the export is the family's act, and it would carry words the loop put there. **A handle carries no words**, so the export gains a 16-hex opaque token and no content, and the words stay behind a store `exportURL()` never reads.

3. **The key must be a function of the normalized transcript, not of `Record.id`.** T-052's mining rules count *recurrence of the same utterance*: M2 needs the *"same (normalized original utterance, corrected method) pair"* to occur **≥ 2 times**, and M7 defines a cluster as *"≥ 3 records sharing the same normalized-utterance hash and the same action"*. `Record.id` is fresh per record and joins nothing (T-052 §3.1), so it cannot group. The key is therefore `HMAC-SHA256(salt, NepaliTextNormalizer.normalize(transcript))` truncated to **16 hex** — the same normalization the cache and resolver already use (`IntentCommandCache.swift:70`, `:87`; `build_dataset.normalize` on the training side).

4. **`IntentCommandCache` is not the join, and was examined and refused.** T-052 named it as the candidate; it does not survive the constraints:
   - **Not opt-in-gated.** It is an always-on performance structure. Mining it would read content the loop's consent never created, and D-1 governs *the loop's* collection (§5.3). T-053 §5.3(a): *"the loop may not silently widen the always-on collection."*
   - **Partial coverage.** `maxEntries = 200` LRU (`:42`) with only `call`, `music`, `suggestVideo` cacheable (`:51-65`). A record for an action that is not cacheable, or one whose entry has been evicted, has no resolvable key — M0 would drop it.
   - **Wrong lifetime and wrong deleter.** Entries live until eviction, with no time bound, and **no** time-based expiry. The loop's opt-out must delete what the loop collected; it cannot delete cache entries without degrading a shipped feature, and §5.4.5 requires opt-out to leave the assistant fully working.
   - It also does not store the transcript at all (key + `InterpretedCommand` only), so it is a *command* index, not an utterance index.
   **It is recorded as a non-choice with these four reasons, so the same proposal is not re-opened in T-056.**

**Consequences, stated because they are obligations and not side-effects:**

- The handle is **opaque**: it is a keyed digest of the *normalized* transcript, so it is identical for two utterances that normalize alike (that is the point — M2/M7) and unguessable without the salt. It is **not** reversible, and the words it points at exist only in the loop content store.
- The handle is **never** eligible for egress, in any form (T-053 §2.2 row 1). T-059's check is mechanical: no egress field may be named `surface*`/`utterance*` or carry a value resolvable to content.
- **One salt keys both the on-device handle and the egress pseudonym**, so the opt-out's single salt destruction ends both linkability paths at once (§3.4).

### 2.2 The added fields

`Record` gains **exactly one** field. The loop-owned artifacts are outside it.

| # | Field | Type | Optionality / default | Value space | Written by | Storage class | Opt-in gate |
|---|---|---|---|---|---|---|---|
| **RF-1** | `utteranceHandle` | `String?` | **optional; absent (not `null`) when the opt-in is off, when the action carries no transcript, or when the salt is unavailable.** Tolerant decode: `try? c.decodeIfPresent(String.self, forKey: .utteranceHandle)` | `^[0-9a-f]{16}$` — `HMAC-SHA256(salt, normalize(transcript))` truncated to 16 hex, lowercase | the loop capture seam at verdict time (T-056) | on-disk in `intent-log.jsonl`, `.complete` file protection, same as every other field | **written only while the opt-in is ON** (C-7) |

**Nothing else is added to `Record`.** Specifically:

- **No confidence field** — it ships (`IntentLogStore.swift:50`); T-052 rev 2 §12 withdrew the capture-side bucket.
- **No latency field** — it ships (`:51`).
- **No egress bucket field** — buckets are computed at **seal** time and never stored back (§3.2). A stored bucket is a second, avoidable copy of a derived value on a backed-up file.
- **No `minedAt` field** — the cursor is a separate loop-owned artifact (§2.6), not a per-record field. A per-record `minedAt` would rewrite the store on every mine and would put loop state into the family export.
- **No consent flag on the record** — the consent record is its own artifact (§5.1), and eligibility is decided by `timestamp >= accepted_at` plus handle-presence (F-9).

**The loop-owned artifacts, listed so the boundary is explicit:**

| # | Artifact | Shape | Storage class | Opt-in gate | Deleted on opt-out |
|---|---|---|---|---|---|
| **L-1** | **loop content store** | `handle (16 hex) → { text: String, firstSeen: Date, lastSeen: Date }` | `EncryptedFileStorage` channel: `.atomic, .completeFileProtection` + `isExcludedFromBackup`, under one key `learningLoop.utterances` | written only while ON | **yes, entire store** |
| **L-2** | **loop cursor** | `{ minedThroughId: UUID?, egressedThroughId: UUID?, minedCount: Int, egressCount: Int }` under `learningLoop.cursor` | encrypted channel, same class | written only while ON | **yes** |
| **L-3** | **consent record** | `{ payloadVersion: String, schemaSha8: String, acceptedAt: Date }` under `learningLoop.consent` | encrypted channel, same class | the artifact *is* the gate | retained as the record of the revoked consent (§5.1 S4) |
| **L-4** | **salt** | 32 random bytes, raw | **Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`, never escrowed** — and it **must** be added to `StoragePlacement.keychainResidentKeys`, because the placement policy's default for an unknown key is `.encryptedFile` (`StoragePlacement.swift:55-57`) | minted on the OFF→ON transition | **destroyed** |
| **L-5** | **sealed batch** (transient) | the padded CBOR body, in memory only | never written to disk — a batch that fails to send is discarded and its records are re-sealed at the next slot (§3.6, §7.2) | ON | n/a |

### 2.3 The loop content store

**Why it exists.** The handle is a pseudonym; the row needs the words. The words must be somewhere they can be read at MINE time, on-device, without being on `Record` (F-2) and without being in `IntentCommandCache` (F-3).

**How it is written.** At verdict time, when the opt-in is ON and the salt is readable, the capture seam resolves the transcript and writes `handle → text` **before** appending the record. Two call sites matter (T-052 C-3):

1. **the verdict's own transcript** — `PendingCallAction.sourceTranscript` (in memory, `AppCoordinator.swift:5473-5474`, used at `:5614-5616`) and `pendingRephrase.sourceTranscript` (`:5378`);
2. **the correction's amendment utterance** — today discarded after the method keyword is parsed at `AppCoordinator.swift:5456-5458`. T-052 C-3 requires it; the shape is: `PendingCallAction` gains `amendmentTranscript: String?`, set at the correction site and read by the capture seam. This is what makes M3 (*"correction needs both ends"*) satisfiable.

**How it is deleted.** Swept opportunistically on write and on launch by `lastSeen < now - 90 days`. The pairing is what makes the sweep correct: a record at time `t` needs its handle to resolve while `t` is inside its own 90-day window, and `lastSeen` is at least the `t` of the newest record referencing the entry — so sweeping on `lastSeen` never strands an in-window record. Deleted **wholesale** on opt-out.

**Why this store is strictly better protected than the store it extends (F-10).** `IntentLogStore` is plaintext JSONL under `.complete` file protection, and it is **not** excluded from backup. The loop content store uses the project's existing encrypted channel (`.completeFileProtection` **and** `isExcludedFromBackup`), which is the pattern the shipped `LocalToolLogStore` adopted for exactly this reason — it holds user query text, so plaintext JSONL was rejected. The loop follows that precedent rather than `IntentLogStore`'s.

**What it is not.** It is not a second activity log, it is not readable from the review screen, and it is not serialised by `exportURL()` — it is a different store, a different file and a different key, so the family export's field set is unchanged by its existence.

### 2.4 C-7: with the opt-in OFF the record is the shipped record

C-7's check is *"the record's field set with the opt-in off vs. on"*. This design fixes the answer in both directions:

| Opt-in state | `Record` key set written | Loop artifacts | Egress |
|---|---|---|---|
| **OFF (default, and before any consent)** | **exactly the shipped nine keys** | none exist: no salt, no content store, no cursor | none |
| **ON** | the shipped nine **plus** `utteranceHandle` (and `utteranceHandle` is absent, not `null`, when the action carries no transcript or the salt is unavailable) | all five (L-1…L-5) | at the sealed weekly cadence |
| **revoked (S4)** | the shipped nine — the field is **stripped** from every existing record | none: content store, cursor and salt are destroyed | none |

The `utteranceHandle` key is **omitted**, never written as `null`: `JSONEncoder` omits a `nil` optional by default, which the shipped decoder already relies on (`IntentLogStore.swift:70-75`), and the wire schema forbids nulls for the same reason (§3.1).

**The strip on opt-out is a real operation, and it is why this is a condition.** T-053 §5.4.5 requires the opt-out to *"delete every not-yet-egressed derived signal"*. The handle **is** a derived signal, and it lives inside the always-on store. The opt-out therefore rewrites `intent-log.jsonl` with `utteranceHandle` removed from every line, using the existing `writeAll` path (`IntentLogStore.swift:180-187`, which re-applies `.complete`). Two consequences are stated rather than discovered:

- the rewrite is a **whole-file write**, so it must run on the same `ioQueue` as `append` (`:93`) and must preserve the current record order;
- after the strip, `exportURL()`'s output is field-for-field the shipped export again — the C-7 proof holds in the revoked state too, not only before the first consent.

### 2.5 Test vectors — the pre-extension decode proof

Design-stage vectors for T-056 to implement as unit tests. `V1` is the acceptance criterion's "pre-extension JSONL line still decodes"; `V4` is the one that is easy to miss.

| # | Vector | Input | Required result |
|---|---|---|---|
| **V1** | pre-extension line | a line with `id`, `timestamp`, `path`, `action`, `outcome` only — no `confidence`, `latencyMs`, `correctedTo`, `utteranceHandle` | decodes; all four optionals `nil`; **not** dropped by `readAll`'s `compactMap` |
| **V2** | opt-in line | a line with `utteranceHandle: "3f9a1c7d2b6e8405"` | decodes; handle equals the value |
| **V3** | explicit null | a line with `utteranceHandle: null` | decodes; handle `nil`. (The writer never emits this; the reader must still tolerate it.) |
| **V4** | **forward-compatible line** | a line with an **unknown** extra key (a field a *later* schema adds) plus the shipped nine | decodes; unknown key ignored; record kept. This is the downgrade-safety proof: a future build's line must not make an older build drop the record |
| **V5** | **C-7 byte-compat proof** | append the same verdict with the opt-in OFF through (a) the shipped code and (b) the new code | the **decoded key sets are identical**. The test must compare parsed key sets, **not** bytes: `JSONEncoder`'s key ordering is unspecified and JSONL line bytes are not a stable artifact |
| **V6** | handle shape | any record written with the opt-in ON | `utteranceHandle` matches `^[0-9a-f]{16}$` and `handle != id.uuidString.lowercased()` |
| **V7** | opt-out strip | a store with a mix of handle-bearing and handle-free lines, then the opt-out | every line decodes and `utteranceHandle == nil` for all; the line count and order are unchanged |
| **V8** | no content in the store file | grep the raw `intent-log.jsonl` bytes for a fixture transcript after a full opt-in capture | the transcript does not appear; the handle does |

`V5` and `V8` together are the mechanical form of F-2: the export path gains a token, and the file never holds words.

### 2.6 The 500-cap question: a cursor, not a digest

**RULING: a mined cursor. No compact derived-signal digest is specified, and none is needed.**

This is the acceptance criterion's *"either … or state explicitly why a trimmed window is sufficient"* branch, decided on T-052's measurement, and it is a reversal of what D-3's rationale assumed:

1. **The cap is not binding at any plausible rate.** T-052 §6.2 measures break-even at **≈ 71 records/day sustained** — a confirmation every 20 minutes, all day, every day, for two confirm-tier actions. The planning range is **5–40 records per household-week** (T-052 §5.2), i.e. 0.7–5.7/day, so the retained window is **88–500 days** and **100 % of a week survives**. Below 71/day the store also holds *everything ever written* until its 552nd record, so a young install has no trimming at all.
2. **Therefore D-3's stated rationale is contradicted by its own sizing, and T-052 §6.3 says so.** The cap was chosen on the assumption that a *month* fits inside it; D-3 assumes a month does not. Both cannot be true at the §5.2 rate. Weekly is still defensible on latency-to-benefit and on the pipeline's cheap, resumable, gate-checked runs (`run_encoder_pipeline.py:303-330`) — it is simply not defensible on signal loss.
3. **What actually breaks the weekly cadence is addressing, and T-052 C-2 names it.** The store has no notion of "already mined": no cursor, no digest, and `Record.id` is a fresh UUID (`IntentLogStore.swift:57`, T-052 §3.1). A weekly miner reading `recent(limit:)` re-reads the **same** records every week — the signal accumulates in place. The `lossless_key` dedup makes that idempotent rather than harmful, but it also means week N's mine is not new signal and the loop's **marginal** value is unmeasurable. T-052 §6.3 states the conclusion directly: the artefact T-054 was charged with is *"load-bearing for addressing, not for survival."*

**The artefact, specified (L-2):**

```
learningLoop.cursor = {
  minedThroughId:  UUID?   // id of the last record mined, in file order
  egressedThroughId: UUID? // id of the last record sealed into a batch
  minedCount:      Int
  egressCount:     Int
}
```

- **Advancing is "strictly after `minedThroughId` in file order"**, not "newer than a timestamp". File order is the store's own order (`append` writes to the end; `writeAll` preserves it), and it is total, whereas equal timestamps are not ordered.
- **A stale cursor is detected, not guessed.** If `minedThroughId` is absent from the 500-record window it has been trimmed away; the miner mines the whole window and records the event as `cursor_lost` — a **counted** condition (T-052 M10: *"monotonic cursor persisted across runs"*), never a silent reset.
- **Deleting the cursor on opt-out is sufficient to make a re-opt-in correct**, because the opt-out also strips every handle (§2.4). After a re-opt-in there is nothing to re-mine and no key from the previous consent to join on. No epoch counter is required, and none is specified.
- **The cursor never egresses** (§3.1's `forbidden` block). It is device state about the device's own store, and `minedThroughId` is a `Record.id`, which T-053 §2.2 row 2 classifies local-only.

**Consequence for mining yield, recorded as the decision requires:** adopting the cursor changes nothing about the yield itself — T-052 §5.3's **2–6 corrected/denied records per household-week** and §8.2's **~45–55 candidate rows per 100 records** stand. It changes whether the weekly cadence means anything: with the cursor, week N mines week N's signal; without it, every week re-mines the same store, and the loop's marginal value cannot be measured at all.

**And the roll-off is still handled, not ignored.** The 90-day filter (§3.8) removes any dependence on the cap: a record is ineligible for egress 90 days after capture whatever the cap does, and T-052 §6.2's table shows the cap cannot bite first below 71/day. The two bounds are stated together, which is what T-053 §6 requires (*"both sides get a time bound, with a named deleter"*).

### 2.7 M4/M5 — the collapses happen on-device, and that is why day granularity is enough

T-052 C-4 requires the two double-counting defects to be *"collapsed by rule, or fixed in the flow"*. Both are collapsed **on-device at MINE time**, and this is a load-bearing consequence of the payload's day granularity:

| Defect | Rule | Why it must be on-device |
|---|---|---|
| **M4** — a correction's derived `confirmed` twin (T-052 §3.5b) | drop the derived twin when a `corrected` record for the same pending action precedes it within one confirmation window | the rule needs *within-session* adjacency; after egress only a **day** bucket survives (§3.3) |
| **M5** — a timed-out confirmation that is later answered writes a second record (T-052 §3.5a) | drop the `timeout` when a later verdict exists for the same pending action | same |

The record still egresses as a **counter** (it exists and is counted); it is the *row* that is dropped. And this is the reason the payload can be day-granular at all: **the miner runs where the content is** (design D-2), so it has the full timestamps and the slot values, and the payload does not need them.

**A day bucket is not a degraded substitute for a timestamp here — it is the correct resolution for what the payload is for.** The payload answers "is there signal worth mining this week, of what kind, at what confidence and latency band". Session adjacency is a *mining* input, and mining is local.

---

## 3. Decision B — the egress contract

### 3.1 The payload schema (machine-checkable)

This block **is** the contract. T-056 extracts it verbatim to `tools/train-intent/src/loop_egress_schema.yaml` (or `specs/loop_egress_schema.yaml` until the tooling directory is touched); T-059 checks the shipped serialiser and the shipped payload against **this artifact**, not against prose. The payload version's hash (`schemaSha8`) is what the consent records (§3.3), so the artifact must be landed before T-056 wires the consent.

```yaml
# T-054 — loop egress payload schema: the machine-readable contract.
# Authority: specs/T-053-notes.md C-1…C-3, §2.2, §3.2–§3.6; specs/T-052-notes.md C-1, C-2, M0–M10;
#            docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md D-2, §5.
# Consumed by T-056 (serialiser + boundary check), T-057 (bundle provenance), T-059 (audit).
schema: loop-egress/v1
task: T-054
payload_version: "loop-1"

payload_version_rule: >
  Re-consent is REQUIRED when a new version ADDS a field, WIDENS a value space
  (a finer band, a new enumerand, an additional emitted action or outcome), or
  CHANGES a field's meaning toward content. Re-consent is NOT required when a
  version REMOVES a field or NARROWS a value space. Egress under an unaccepted
  version is REFUSED — fail closed. (T-053 §3.6.)

envelope:
  encoding: cbor
  additionalProperties: false
  required: [v, batch_week, aged_out_total, records, pad]
  fields:
    v:               {type: int, const: 1}
    batch_week:      {type: str, pattern: "^[0-9]{4}-W[0-9]{2}$",
                      derivation: "ISO-8601 week of the seal time, device-local calendar",
                      granularity: week, timezone: none}
    aged_out_total:  {type: int, min: 0, max: 100000,
                      note: "records deleted un-egressed by the 90-day filter. Normally 0; the honest admission that retention bit. No other counter is carried — every other count is derivable from records[]"}
    records:         {type: list, items: record, max_items: 500}
    pad:             {type: bytes, note: "zero bytes; fills the body to exactly envelope_bytes"}

envelope_bytes: 262144          # every upload is exactly 256 KiB
max_records_per_batch: 500      # = IntentLogStore.maxRecords (IntentLogStore.swift:90)
max_record_bytes: 400           # boundary invariant; 500 x 400 = 200000 < 262144

record:
  additionalProperties: false
  required: [day, action, outcome, record_dedup]
  fields:
    day:              {type: str, pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                       derivation: "local calendar day of Record.timestamp",
                       granularity: day, timezone: none}
    action:           {type: str, enum: [ack_med, call, create_calendar_event,
                                         emergency, guide, health_query, music,
                                         none, query, send_message, set_reminder,
                                         suggest_video]}
    outcome:          {type: str, enum: [confirmed, corrected, denied, timeout]}
    correction_kind:  {type: str, enum: [method],
                       condition: "present iff outcome == corrected",
                       derivation: "the KEYS of Record.correctedTo, never its values"}
    confidence_bucket: {type: str, enum: [lt_0_4, 0_4_0_7, ge_0_7],
                        condition: "present iff Record.confidence was non-nil"}
    latency_bucket:   {type: str, enum: [lt_5, 5_15, 15_30, 30_45, ge_45],
                       condition: "present iff Record.latencyMs was non-nil"}
    record_dedup:     {type: str, pattern: "^[0-9a-f]{16}$",
                       derivation: "HMAC-SHA256(salt, Record.id.uuidString), first 16 hex chars",
                       minted_at: seal_time, persisted_back: false}

bands:
  # Confidence: T-053 §2.2 row 9 fixes these at the router's own three bands.
  confidence:
    - {id: lt_0_4,   lo: 0.0, hi: 0.4, source: "IntentRouter.swift:49-58"}
    - {id: 0_4_0_7,  lo: 0.4, hi: 0.7}
    - {id: ge_0_7,   lo: 0.7, hi: 1.0}
  # Latency: T-053 §2.2 row 10 requires bands of AT LEAST 5 s. These are 5/10/15/15/open.
  latency:
    - {id: lt_5,    lo: 0,     hi: 4999}
    - {id: 5_15,    lo: 5000,  hi: 14999}
    - {id: 15_30,   lo: 15000, hi: 29999}
    - {id: 30_45,   lo: 30000, hi: 44999}
    - {id: ge_45,   lo: 45000, hi: null,
       note: "open top band; a late verdict after a 45 s expiry is the only way here"}

eligibility:
  # Both filters, always. F-9.
  - "record.timestamp >= consent.acceptedAt"
  - "record.timestamp >= seal_time - 90 days"
  - "the opt-in is ON at seal time"
  - "the record carries utteranceHandle, OR the record has no utterance surface at all
     (the calendar paths, whose capture is deliberately speech-free)"

derivation_sources:
  day:               Record.timestamp
  action:            Record.action
  outcome:           Record.outcome
  correction_kind:   keys(Record.correctedTo)
  confidence_bucket: Record.confidence
  latency_bucket:    Record.latencyMs
  record_dedup:      Record.id

forbidden:
  - "any timestamp finer than a calendar day"          # T-053 §3.3
  - "any timezone, offset or locale identifier"         # T-053 §3.3
  - "any map-typed field"                               # T-053 §3.2
  - "any field whose value space is 'a string'"         # T-053 §3.2
  - "any null value (omit the key instead)"             # this design, §3.1
  - "any digest of content (utterance, name, message)"  # T-053 §3.4, §4/T4 r1
  - "any digest of a closed-vocabulary value"           # low-entropy rule, T-053 §3.4
  - "install pseudonym, device id, vendor id, ad id"    # T-053 §2.2 r12, §4/T5 r2
  - "IP address, user agent, or connection metadata"    # T-053 C-3
  - "Record.id, Record.slots, Record.correctedTo, Record.path,
     Record.confidence, Record.latencyMs, Record.utteranceHandle"   # T-053 C-1
  - "any field sourced from the loop content store (L-1)"           # T-053 §2.2 r1

excluded_by_derivation:
  # Fields T-053 §2.2 permits that this design DROPS because another payload field
  # determines them. See §3.2. Dropping is a NARROWING and does not re-trigger consent.
  path_class: "fully determined by outcome (override <=> corrected)"
  slot_keys:  "fully determined by action (call => {contact, method}; calendar => none)"

size_stability:
  envelope_bytes: 262144
  padding: "zero bytes appended as the `pad` field so the encoded body is exactly envelope_bytes"
  on_overflow: "REFUSE — do not send; retain; count; surface (fail closed)"
  unreachable_because: "max_records_per_batch 500 x max_record_bytes 400 = 200000 < 262144"
```

### 3.2 The field rulings — what is carried, dropped, and why

**Per-field, against T-053 §2.2:**

| Payload field | T-053 source field & class | Ruling here |
|---|---|---|
| `day` | row 3 — "day-granular bucket, not a truncated timestamp", "no timezone" | **carried.** `JSONEncoder`'s default date strategy writes a full-precision double (`IntentLogStore.swift:116`), so the serialiser must construct the string itself and must never `encode(record)`. |
| `action` | row 5 — closed-vocabulary id, "a member of the encoder's schema-v2 action enumeration, not 'the observed strings at the time'" | **carried**, enumerated to the twelve ids in `annotation_rules.yaml:31-46`. `plugin` is excluded by that file's own rule and must stay excluded. |
| `outcome` | row 7 — closed-vocabulary id, "the field the mining signals key on" | **carried**, enumerated to `IntentLogStore.Verdict`'s four raw values (`:197-207`). The raw values are a storage format and are used unchanged. |
| `correction_kind` | row 8 — the *kind*, derived from the map's **keys**, never its values | **carried**, `enum: [method]` today. The map never egresses; the value never egresses; T-059's check is *no egressed value equals a `correctedTo` value*. |
| `confidence_bucket` | row 9 — raw is local-only, bucket permitted at the router's three bands | **carried**, bands taken verbatim from `IntentRouter.swift:49-58`. The raw float is never computed into the payload and never stored back. |
| `latency_bucket` | row 10 — raw is local-only, "bands of at least 5 seconds' width, edges fixed by T-054" | **carried.** Edges are fixed at **5/10/15/15/open** — every band ≥ 5 s, coarser than the allowance, which is a narrowing and therefore free (§3.3). Paired with a **day**, never a sub-day timestamp. |
| `record_dedup` | row 2 — `HMAC(salt, id)` truncated to 16 hex, "minted at egress time, never stored back" | **carried, and required.** It is the copy's *"one scrambled code for each sentence"* (F-5), and it is the receiver's only idempotency key (§3.5). |
| `path_class` | row 4 — permitted **only if** the observed set is enumerated | **DROPPED** — F-4. The observed set is `{model, override}`, and `override` ⟺ `outcome == corrected`, so the field is a function of `outcome`. T-053's row 4 explicitly offers "or the field is dropped", and this arm is taken. The docstring lie is still fixed on its own terms (§5.5, C-10). |
| `slot_keys` | row 6 — the slot **key names** may be carried, never the values | **DROPPED.** For `call` the capture always sets **both** keys (`AppCoordinator.swift:5362-5368`), and for the calendar paths `slots` is deliberately `nil` (`:5175-5184`). So the key set is a function of `action`. T-053 permits it; nothing needs it — the miner runs on-device and has the values, and the receiver can derive it. Excluding strictly more than the ruling requires is a narrowing. |
| transcript / utterance surface | row 1 — never-leaves; "must never egress — T-059 checks that no egress field is named `surface*` or carries a resolvable reference" | **never carried, and `utteranceHandle` is not carried either.** The handle is on-device only. A mechanical check is specified: no egress field name matches `^(surface|utterance)`, and no egressed value is resolvable against L-1. |
| `id`, `slots`, `correctedTo`, raw `confidence`, raw `latencyMs`, `timestamp` | C-1's explicit list | **never carried.** |
| counters | §3.1 — "buckets and counters … yes" | **only one**: `aged_out_total`. Every other count is derivable from `records[]`, so carrying it would be a second copy of the same fact — see the minimality rule below. |
| transport metadata (version, install pseudonym) | row 12 | **the payload version `v` is carried; no install pseudonym is.** T-053 row 12 permits one that is "a device-computed `HMAC(salt, install-constant)`", but §4/T5 rule 2 says *"No stable install pseudonym is required for the mining, and none may be added without a stated purpose."* The mining does not need one, and `record_dedup` already provides idempotency without one (§3.5). **Adding one is a re-consent-triggering amendment**, not a tuning change. |

**The minimality rule this design adds (a narrowing, so it re-triggers nothing):**

> **No payload field may be a function of another payload field.** A field that is determined by others adds no information to the receiver and adds surface to the consent.

It is what drops `path_class` and `slot_keys`, and it is what collapses the counter block to `aged_out_total`. It is checkable: T-059 can build the payload's field set from a fixture and confirm that removing any field leaves no field reconstructible from the rest.

**On nulls.** `correction_kind`, `confidence_bucket` and `latency_bucket` are **omitted** when not observed, never emitted as `null`. T-053 §3.2 forbids "a field whose value space is 'a string'"; a nullable enum is the same hole one step over, and omission keeps the required-set semantics checkable (*present ⟹ value ∈ enum*, and *action ∈ calendar ⟹ `confidence_bucket` absent*). Omission is also what the shipped encoder already does for `nil` optionals (`IntentLogStore.swift:70-75`), so the loop is consistent with the store it reads.

### 3.3 The payload version, the consent's scope, and re-consent

- **The version is `loop-1`**, and it is the `v` field of the envelope (envelope protocol version, currently `1`) *plus* the `payload_version` in the schema artifact. They are deliberately separate: `v` is a wire-format version, `payload_version` is the consent's scope. A change to either that widens a value space re-triggers consent.
- **The user accepts a payload version, and the accepted version is recorded with the consent** (T-053 §3.6): `learningLoop.consent = {payloadVersion, schemaSha8, acceptedAt}` (L-3). `schemaSha8` is the `<sha8>` of the extracted schema artifact, so "what did the user actually agree to" is answerable at audit time without trusting a code comment.
- **Re-consent is REQUIRED** if a new version **adds a field**, **widens a field's value space** (a finer confidence or latency band, a finer time resolution, a new enumerand, an additional `action` or `outcome`), or **changes a field's meaning toward content**. **Egress under an unaccepted version is REFUSED — fail closed, not fail open** (T-053 §3.6, §5.4.6).
- **Re-consent is NOT required** for a removal or a narrowing. That is why the two dropped fields (`path_class`, `slot_keys`), the coarser latency bands, the omitted nulls and the minimality rule re-trigger nothing.
- **The one-line test T-059 applies**, verbatim from T-053 §3.6: *does the new version's permitted value space contain any value the accepted version's did not?* If yes, re-consent.

**The re-consent trigger must be reachable and honest.** An unaccepted version fails closed and the Settings card says so in words (§5.3's `egressNeedsUpdate`), rather than silently shipping a narrower payload — which is what T-053 §5.4.6 requires and what T-053's §7.1 string set does not provide. That gap is closed here and flagged in §11.

### 3.4 The salt

The ruling is T-053 §3.4; this section fixes **where it lives, who may read it, and what happens when it is not available**. All of it is checkable.

| Property | Fixing | Check |
|---|---|---|
| **Size and mint time** | 32 random bytes (`SecRandomCopyBytes`), generated once on the **OFF → ON** transition, before any handle is written and before any content-store entry exists | the salt has no other creation path |
| **Storage** | **Keychain**, `kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false` — matching the shipped `KeychainEncryptedStorage` class (`:82`, `:105`) | the accessibility class and the synchronizable flag |
| **Placement** | the key **must** be added to `StoragePlacement.keychainResidentKeys` (`StoragePlacement.swift:44-53`), because the policy's default for an unknown key is `.encryptedFile` (`:55-57`) — an unlisted key would silently put the salt on the encrypted-*file* channel | membership in that set |
| **Escrow** | **forbidden**: never uploaded, never synced, never in an iCloud or encrypted-iTunes backup, never in a project artifact or a log | absence of any read path that leaves the process |
| **Use 1 — the on-device handle** | `handle = HMAC-SHA256(salt, NepaliTextNormalizer.normalize(transcript))` truncated to 16 hex, lowercase; stored on `Record.utteranceHandle` (§2.2) | V6 |
| **Use 2 — the egress pseudonym** | `record_dedup = HMAC-SHA256(salt, id.uuidString)` truncated to 16 hex, minted at **seal** time, held in memory, **never written back** to any store | the serialiser is the only producer; no store has the field |
| **Mechanism** | **HMAC-SHA256 keyed by the salt** — not a bare `SHA256(salt ‖ value)` (T-053 §3.4) | the algorithm identifier in code |
| **Digest length** | 16 hex characters (64 bits) | regex `^[0-9a-f]{16}$` |
| **Rotation** | **event-driven only**: destroy on opt-out and on an explicit "delete my data" action. **No scheduled rotation** — it would break the cross-revision dedup the miner depends on while buying nothing that salt destruction does not already give | no timer, no calendar reference |
| **Availability failure** | **fail closed.** If the Keychain item is unreadable (locked before first unlock; item missing), **no handle is written, no content entry is written, no batch is sealed and no upload is attempted**. The record is still appended with the shipped nine fields, and the state is visible (§5.3 `egressPending`). The loop never degrades to an unsalted or no-op-keyed digest | the seal path's guard; a test with an unavailable salt |
| **The intended failure mode** | if the salt is lost, every previously egressed digest becomes permanently unlinkable to the device — **stated as a property, not an accident** (T-053 §3.4) | — |

**Two things the salt is *not* for, said plainly so the claim is not overstated.** It is not device-at-rest protection: a thief with the passcode has the store and the content store, and the salt adds nothing there (T-053 §4/T2). It is protection **against the receiver** — a server, or an attacker of the server, cannot dictionary-attack the payload — and it is what makes the opt-out copy's *"can no longer be linked to anything you say from now on"* a guarantee rather than a hope.

**One salt, two uses, and no third.** Because the handle never egresses, the low-entropy rule cannot be violated by the shared key: no egressed object ever carries both a closed-vocabulary value and a digest of the surface that produced it. That is an invariant T-059 can check on the wire alone — **no payload object may carry a digest field other than `record_dedup`**.

### 3.5 The envelope, and the boundary with the channel family

The loop's egress rides **the channel family's encoding and no-PII discipline, not its envelope shape**. Stated as a boundary so the two documents cannot drift:

| Channel-family property | Loop's use | Why |
|---|---|---|
| CBOR encoding | **adopted** | same tooling, same inspectability, one encoding convention for the suite |
| No-PII rule (`remote-config-channel-design.md:15-16`, *"Never a medication name, metric value, or contact display name"*) | **adopted, and tightened** — the loop carries no content at all, hashed or otherwise | T-053 C-1 |
| *"No payload, no `convId` in logs — just size and status"* (`:76-77`) | **adopted verbatim** for the loop's uploader | T-053 C-3 rule 4 |
| E2E envelope `{v, sender_id_hash, ciphertext, mac}` (`:60-62`) | **NOT adopted.** The loop uses a **TLS-terminated receiver**, which C-3 permits *"only because D-2's content is hashed and bucketed"* and *"and nothing else"* | C-3 rule 1 |
| Inner `{v, alert_type, timestamp}` (`:15`) | **only `v` is adopted.** `alert_type` has no loop analogue, and **`timestamp` must not be carried** — T-053 §3.3 forbids any egress timestamp finer than a calendar day and any timezone, and the family's field is ISO-8601 with a time | F-6; this is the one place the family's convention would have broken a ruling if copied |
| `sender_id_hash` | **not carried in any form** — not as the family's SHA-256 truncation, not as an install pseudonym | T-053 §4/T5 rule 2 |

**The written "what would break this" test C-3 requires.** The E2E boundary is crossed, and the loop is no longer covered by C-3, if **any** of the following becomes true — each is a stop, not a warning:

1. any payload field's value space ceases to be an enumeration, a fixed band or an integer counter;
2. `records[]` or the envelope carries a string that is not a member of a declared enumeration;
3. a field is added whose value is derived from content, hashed or not;
4. the day bucket is refined, or a timezone/offset/locale field appears;
5. the TLS receiver is replaced by, or supplemented with, anything that terminates beyond TLS for this channel.

On (5) specifically: if a future version carries **anything above hashed-only**, it must ride the E2E envelope (`leaves-encrypted`), never a TLS-terminated endpoint. *"This is the line that must not be crossed later"* (T-053 §4/T3 rule 1).

**Idempotency, and why there is no install pseudonym.** `record_dedup` is stable across a re-delivery of the same record (same `id`, same salt) and cannot collide across installs (different salts), so it **is** the delivery idempotency key — which is the *stated purpose* T-053 §4/T5 rule 2 requires before a stable identifier may exist at all. Two restrictions follow and are conditions (C-11): the receiver must use it **only** to collapse duplicate deliveries, never to group records or to build a per-install series; and no batch id, session id or install pseudonym may be added beside it.

### 3.6 The sealer: cadence, size stability, and the boundary check

**The cadence is unconditional and the size is fixed. Both are required by C-3, and both cut against the intuition that an idle week should be silent.**

| Property | Ruling | Reason |
|---|---|---|
| **When** | the **first app-active moment on or after the week boundary** (Monday 00:00, device-local calendar) — no background scheduler is required | an upload can only happen while the app runs; the timing is therefore as stable as the app's own launch pattern, which is stated as a residual rather than claimed away |
| **How often** | **exactly once per ISO week when the opt-in is ON — including a week with zero eligible records** | C-3: *"uploads are batched at the loop's fixed cadence (weekly) and size-stable …, so envelope size and timing do not correlate with what happened in the household that week."* An empty week that sends nothing would make **presence** the signal |
| **D-3 reconciliation** | D-3's *"a week with no new signal produces no run"* governs the **retrain run**, not the upload. The upload happens; the retrain does not | the two statements are different subjects, and leaving them unreconciled is how a future implementer "optimises away" the empty upload |
| **Size** | **exactly `envelope_bytes` = 262144 (256 KiB)**, every time, padded with the `pad` byte string | F-6/C-3. A *bucketed* pad leaks log₂ of the volume; a single fixed size leaks nothing beyond "a loop upload happened" |
| **Overflow** | **refuse — do not send** (fail closed). Retain the records, count the event, surface it | T-053's four-part test is a boundary check; a payload that fails its own schema must never leave |
| **Unreachable by construction** | 500 records × 400 B = 200 000 B < 262 144 B | the store's own cap (`IntentLogStore.swift:90`) bounds the batch, so the overflow branch is a guard against a code defect, not a normal path — say so in the code, and keep the guard |
| **Retry** | the un-egressed records are **folded into the next scheduled slot's batch**; nothing is discarded and no off-cadence retry is attempted | retrying immediately would destroy the timing stability the cadence exists to provide. `record_dedup` makes at-least-once delivery safe |
| **Per-record bound** | ≤ 400 B serialised, checked at the boundary | makes the sizing argument in the row above a *checked* invariant rather than an estimate |

**What the sealer must not do, stated because it is the natural implementation mistake.** It must not `encode(record)` (`IntentLogStore.swift:116` already writes a full-precision date double — "serialise the record and post it" is exactly the leak T-053 §2.2 row 3 names), it must not read the loop content store, it must not read `slots` or `correctedTo` except to take the **keys** of the latter, and it must not consult `Record.id` for anything except `record_dedup`'s HMAC input.

### 3.7 The worked synthetic example

**Synthetic values only — no real utterance, name, contact or device appears, and the salt is not shown because it never appears in any artifact.** This is a **diagnostic rendering** of the decoded CBOR, not the wire bytes; the wire form is CBOR with the same keys, padded to 262144 bytes.

Batch `loop-1`, sealed in week 37 of 2026. The two `id` values that produced the digests are deliberately **not shown** — they are local-only and must not appear even in a design document (T-053 §2.2 row 2):

```jsonc
{
  "v": 1,
  "batch_week": "2026-W37",
  "aged_out_total": 0,
  "records": [
    {
      "day": "2026-09-08",
      "action": "call",
      "outcome": "corrected",
      "correction_kind": "method",
      "confidence_bucket": "lt_0_4",
      "latency_bucket": "15_30",
      "record_dedup": "3f9a1c7d2b6e8405"
    },
    {
      "day": "2026-09-08",
      "action": "call",
      "outcome": "denied",
      "confidence_bucket": "0_4_0_7",
      "latency_bucket": "lt_5",
      "record_dedup": "a70b41e6c9d27f38"
    },
    {
      "day": "2026-09-11",
      "action": "create_calendar_event",
      "outcome": "timeout",
      "latency_bucket": "ge_45",
      "record_dedup": "0c5e88b3f1a4d962"
    },
    {
      "day": "2026-09-12",
      "action": "call",
      "outcome": "confirmed",
      "confidence_bucket": "ge_0_7",
      "latency_bucket": "5_15",
      "record_dedup": "e2147ba95c6f03d8"
    }
  ],
  "pad": "…zero bytes to exactly 262144…"
}
```

**Reading the example against the rulings, field by field — this is the check T-059 performs:**

| Observation | Ruling it discharges |
|---|---|
| `record_dedup` is 16 lowercase hex, and the `id` it digests is absent | T-053 §2.2 row 2, §3.4; **F-5** — it is the copy's *"one scrambled code for each sentence"* |
| No field is named `surface*` or `utterance*`, and no value is resolvable to content | T-053 §2.2 row 1, and §3.4's low-entropy rule: `record_dedup` is the **only** digest in the payload, and its input is `id`, never an utterance |
| `correction_kind` is present **iff** `outcome == "corrected"`; no map, no `correctedTo` value | T-053 §2.2 row 8, C-1 |
| `confidence_bucket` is **absent** on the third record — it is a calendar record, whose capture is deliberately speech-free and confidence-free | T-052 §3.4, §8.3 M6; T-053 §2.2 row 9 |
| `latency_bucket` is present on all four, including the timeout | T-053 §2.2 row 10 (the raw `Int` never egresses; `ge_45` is the 45 s expiry) |
| Every latency band is ≥ 5 s wide (5/10/15/15/open) | T-053 §2.2 row 10's resolution limit |
| `day` is a bare `YYYY-MM-DD` with no offset; no `timestamp` key exists anywhere | T-053 §3.3; **F-6** |
| No `install_pseudonym`, no `sender_id_hash`, no batch id | T-053 §4/T5 rule 2 |
| `aged_out_total` is the only counter | the minimality rule, §3.2 |
| Realistic fields, synthetic values; the salt is never shown | T-053 §13's PII discipline |

### 3.8 Retention and the deletion semantics

T-053 §6 sets both clocks. This design fixes **the mechanism and the deleters**, because a clock without an enforcer is a sentence.

| Side | Bound | Enforced by | When | On failure |
|---|---|---|---|---|
| **On-device records** | eligibility filter `timestamp >= max(consent.acceptedAt, seal_time − 90d)` | the sealer, before building `records[]` | every seal | records older than the bound are **not** deleted for that reason — they stay on disk under the store's always-on behaviour and cannot egress; they are counted by age (§3.1's derivation) |
| **On-device loop content (L-1)** | `lastSeen < now − 90d` → delete the entry | the content store, opportunistically on write and on launch | continuous | **eager deletion** — content has no reason to outlive its egress window. This is a **narrowing** of T-053 §6's "applied as a filter at egress time" and therefore re-triggers nothing |
| **On-device cursor (L-2)** | deleted on opt-out | the opt-out path | at S3 → S4 | a stale cursor is *detected* (`cursor_lost`), never silently reset (§2.6) |
| **The salt (L-4)** | destroyed on opt-out and on an explicit "delete my data" | the opt-out path | at S3 → S4 | a lost salt means no egress at all (fail closed), not a degraded one |
| **Egressed records** | **180 days from receipt, or 30 days after the corpus revision they fed is superseded, whichever bites first** | **the project owner (Anjan Poudel)**, at the T-058/T-036 tooling boundary; supersession is observable from the corpus-revision binding (`eval_golden.py:505-537`) | scheduled | **a deletion job that has not run is a review-time finding, not a silent omission** (T-053 §6) |

**The eligibility filter is one line in the schema (`eligibility:`), and it carries the extra clause T-053 did not state** (F-9): `timestamp >= consent.acceptedAt`. Without it, a record captured before the opt-in was switched on would become eligible the moment the opt-in was turned on — a retrospective consent the copy does not describe. This is a **narrowing** (it can only remove records from the eligible set), so it re-triggers nothing and needs no re-consent.

**The opt-out's two halves, exactly, because the copy promises them:**

| Immediately, irreversibly, on the S3 → S4 transition | Retained |
|---|---|
| every not-yet-egressed record's `utteranceHandle`, stripped from `intent-log.jsonl` | **already-egressed records**, under the 180-day window, with **no further egress** |
| the entire loop content store (L-1) | the revoked consent record (L-3), kept as the record that a consent existed and was withdrawn |
| the cursor (L-2) | |
| **the salt (L-4)** — the single destruction that ends both linkability paths | |

**And the honest limit, which the copy states and this design does not soften.** Salt destruction makes *future* linkage arithmetically impossible, and that is a guarantee. It does **not** guarantee that an already-egressed record is un-re-identifiable in absolute terms — T-053 §4/T4 and §4/T5 are what bound that, and they are bounds, not proofs. The copy is written to the guarantee and not one word past it.

---

## 4. Decision C — the ingestion hand-off

### 4.1 The mined-rows bundle

**The loop's automated channel never carries content, so content needs its own path.** D-2's consequence states the split: *"MINE runs where the content is … and the hashed channel carries only the signal that says 'this is worth mining'."* T-053 §2.1 reinforces it: content *"may still leave the device on the pre-existing, user-initiated family-export channel"* — an explicit, user-initiated act, not a loop path.

**One consequence is worth stating plainly, because it is a product-shape decision and not a privacy footnote: the loop's automation is in the signal channel, not the content channel.** The weekly cadence is automatic; carrying the words is not, and cannot be made so without crossing Architecture Constraint 1 and NFR-015.

**The bundle (T-057 produces it; T-056 owns the share surface):**

| Property | Ruling |
|---|---|
| **Format** | JSONL. **Line 1 is a manifest object**, every following line is one T-034 row to the shipped row contract `{id, utterance, action, register, source, confidence, spans, slots}` |
| **Manifest fields** | `kind: "loop_mined_rows/v1"`, `payload_version`, `created_day` (day granularity, no time, no timezone), `row_count`, `bundle_sha8` (short prefix of the rows section), `consent: {loop_opt_in: true, accepted_day: <day>, payload_version: <v>}`, `producer: "ios-<version>"` |
| **Row `source`** | `mined:<action>:<ISO-week>` — a declared provenance prefix, so the existing `bucket_of` classification (`build_encoder_dataset.py:296-300`) and the existing guards apply unchanged, and so M8's register honesty is auditable |
| **Row `register`** | the miner's honest tag for raw Whisper output. A mined transcript is **never** presented as a clean row and is never blind-expanded through `stt_noise.py` as if its parent were clean (T-052 M8) |
| **File protection** | written under `.completeFileProtection` — unlike the shipped `exportURL()` copy, which sets **no** attribute (`IntentLogStore.swift:149-164`) |
| **The encryption gap** | **recorded, not fixed.** `annotation_rules.yaml:255` requires the pipeline to *"flag the encryption gap rather than silently ingesting"*. The bundle is at rest under file protection and in transit by the family's own act; if it is shared through a cloud or third-party app, that egress is the **family's**, and the disclosure string says so (§5.3) |
| **Whose act** | the family's, explicitly, from a **separate** share control with its own disclosure string. **Not** the `ShareLink` on `exportURL()` (C-6) |
| **Never** | never merged into the `intent-log.jsonl` export, never uploaded by the loop's uploader, never egressed as part of the payload |
| **What it is not covered by** | the loop's opt-in alone. The opt-in governs capture and the hashed channel; **the bundle leaves because a person chose to send it**, which is the same class of consent T-053 §9's owner decision ruled covers teacher transit |

### 4.2 What `run_encoder_pipeline.py` must accept — the refusal today

**Today:**
```python
387    if args.consent_export:
388        print("[guard] REFUSED: --consent-export is not implemented (NFR-015). Real "
389              "user data only enters training through the consented export bundle "
390              "path, which is an ops/T-035 gate; this pipeline will not ingest "
391              "arbitrary rows.")
392        return EXIT_GUARD
```
pinned by `tests/test_encoder_pipeline.py:337-341` (exit `3`, `"NFR-015"` in output). **This refusal is correct as shipped and must not be weakened** — T-053 §0.1's verdict is *"NO-GO today for any egress at all"*, and the refusal is the honest state that verdict describes.

**What T-056/T-057 must change, as a contract (not as a code change — this task changes nothing):**

| # | Requirement | Refusal when violated |
|---|---|---|
| **I-1** | `--consent-export <bundle>` ingests the bundle's **manifest** and its **rows**, and nothing else. A path that is not a bundle (missing/malformed manifest line, unknown `kind`, unknown `payload_version`) is refused | `EXIT_GUARD` (3), `[guard] REFUSED:` on stdout |
| **I-2** | the manifest's `consent.loop_opt_in` must be `true`, and `consent.payload_version` must be a version this build knows | `EXIT_GUARD` |
| **I-3** | `row_count` must equal the number of row lines, and every row `source` must match `^mined:[a-z_]+:\d{4}-W\d{2}$` | `EXIT_GUARD` |
| **I-4** | every row passes the **existing** `convert_row` / `load_encoder_rows` validators unchanged (`build_encoder_dataset.py:219-252`, `train_encoder.py:60-95`) | the existing counters, unchanged |
| **I-5** | the **existing** guards fire on mined rows exactly as on teacher rows: golden-corpus membership refusal (`pipeline_guards.leak_refusals`, `build_encoder_dataset.py:504-506`), per-bucket label-conflict dropping, dedup, floor checks | the existing counters and exit codes |
| **I-6** | the run manifest's `consent` block (`run_encoder_pipeline.py:598-600`) becomes `{real_user_rows: <n>, bundle_ref: "<sha8>", consent_export_ingestion: "enabled (T-054 bundle format)", encryption_gap_flagged: true}` — **the bundle's opaque reference, never its content** (`annotation_rules.yaml:253`) | the manifest is the audit artifact |
| **I-7** | `real_user_rows` and `bundle_ref` are recorded, and the **utterance is never written to a report, a log or the manifest** (NFR-016; `pipeline_guards.py:16`) | — |

### 4.3 Closing the `--sources` side door (F-7)

**The refusal above is nominal on its own.** `--sources` accepts arbitrary comma- or space-separated JSONL paths (`run_encoder_pipeline.py:372-373`, `:437-442`; `build_encoder_dataset.py:397-399`), and the design's own §4.3 requires that mined rows *"must not be able to bypass the guards by arriving through a side door."* The side door is open today: the identical rows would be ingested by `--sources data/x.jsonl` with **no consent check whatsoever**.

**RULING — the guard must be on the row's provenance, not on the flag:**

> **Any row whose `source` begins with `mined:` is refused unless the run was invoked with a validated `--consent-export`.** The check lives in the row-conversion path, so it fires for rows arriving through `--sources`, through a future default source list, and through any stage that reads rows — not only for rows arriving through the flag that happens to exist today.

This makes the consent gate a property of the data rather than of the invocation, which is the only form that survives a new entry point. It is a condition (C-13) and it is what I-3's `source` regex exists to make possible.

### 4.4 Teacher transit of whitelisted mined rows

**Owner decision, 2026-09-15 (T-053 §9, amended; C-9): YES.** The family's export consent covers feeding mined rows to `gen_teacher.py`. The standing conditions are unchanged and all three apply:

1. **the household's opt-in is active** (D-1);
2. **whitelisted mined rows only** — the rows that passed M0–M10 and the row validator, **never a whole-log serialisation** (C-1);
3. **the teacher endpoint is the TLS-only configured receiver** (C-3).

**Where it fits in this design.** After ingestion, in the AUGMENT stage, `gen_teacher.py` may be given the bundle's whitelisted rows as seed templates for rephrase expansion. Two properties keep the provenance legible:

- **The teacher's output rows carry `source: teacher:<family>:<register>`**, not `mined:`. Provenance therefore distinguishes a rephrased row from a direct one, and the `mined:` prefix means exactly "this utterance came off a device under the loop's opt-in".
- **T-057 must still keep the teacher-free path.** T-053 §9's carried-forward text and design §4.3 both require the loop to be buildable both ways, so a household without the opt-in — and any run that has not ingested a bundle — takes the direct-row plus local `stt_noise.py` path only.

**And the reference point for what this buys, so the ruling is not over-read.** T-052 §7.2 measured that teacher expansion is *target-driven*, so the value of teacher-rephrasing a mined row is the **real phrasings the teacher cannot invent** (T-052 §9), not supply toward a floor. T-052 §7.5's arithmetic (1–2 corpus rows per mined utterance) understates the post-amendment yield by the teacher factor; the direction of change is upward and is capped by T-052 §5.3's 2–6 minable records per household-week. **The loop's case remains a quality case, not a supply case** — T-052 C-7, which this design does not contradict.

### 4.5 The `annotation_rules.yaml` amendment T-057 owes (F-8)

`governance.real_user_data.bundle_source` currently names the family export:

> `bundle_source: "IntentLogStore.exportURL() (ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift:108-123), produced by the family's deliberate export act (IntentLogReviewView.swift:23-27 ShareLink)"` — `annotation_rules.yaml:251`

**Both line citations in that recorded text are themselves stale** — `exportURL()` is at `IntentLogStore.swift:149-164`, and the `ShareLink` is at `IntentLogReviewView.swift:28` — which is a small extra reason the record needs rewriting rather than patching: it is describing a code path that has moved twice since it was written.

That is now wrong on two counts: **C-6 forbids the loop from reusing that path**, and the export **cannot be mined anyway** (T-052 F-2 — it carries no utterance, so its mined yield is exactly zero). **Replacement text, for T-057 to land verbatim:**

```yaml
  real_user_data:
    admission: explicit_consent_export_bundle
    bundle_source: >-
      the loop's mined-rows bundle (specs/T-054-notes.md §4.1): a JSONL file whose first
      line is a `loop_mined_rows/v1` manifest and whose remaining lines are T-034 rows with
      `source: mined:<action>:<ISO-week>`, produced on-device by the miner under the
      household's active loop opt-in and handed over by the family's deliberate share act.
      NOT IntentLogStore.exportURL(): the loop may not reuse that path (T-053 C-6) and the
      export carries no utterance, so its mined yield is zero (T-052 F-2).
    requirements:
      - "no pipeline stage reads on-device log content except the exported bundle (NFR-015)"
      - "the run manifest records the bundle's opaque export reference (never its content)"
      - "a row whose source begins with `mined:` is refused unless the run carried a
         validated --consent-export (closes the --sources side door; T-054 §4.3)"
      - "T-036 must refuse bundles without a consent/export record and flag the encryption
         gap rather than silently ingesting (the bundle is file-protected at rest and in
         transit by the family's own act; the gap is recorded, not fixed)"
```

This is listed as a **condition on T-057** (C-14), and it is a documentation change to a governance record — not a payload change, so it re-triggers no consent.

---

## 5. Decision D — consent mechanics

### 5.1 The state machine

Five states, four transitions, and every state names what it does to already-captured and already-egressed data. T-053 §5.4 fixes the requirements; this is their externalised, checkable form.

```
   S0 OFF ──(tap)──▶ S1 CONSENTING ──(confirm)──▶ S2 ON
    ▲                   │                          │
    │              (cancel)                        │ (tap)
    └───────────────────┘                          ▼
    ▲                                        S3 REVOKING
    │                                              │
    └────────────── S4 REVOKED ◀─────────────(confirm)
```

| State | What the user sees | Captured & stored | Egress | Salt |
|---|---|---|---|---|
| **S0 OFF** (default; and the shipped state) | the Privacy card: `title`, `explanation`, `neverLeaves`, the switch OFF. Nothing is asked | records only, with the **shipped nine fields**; no loop artifacts exist | none | none |
| **S1 CONSENTING** (transient) | `consentQuestion` + `consentConfirm` / `consentCancel`, **before** the switch moves. Not an immediate toggle — T-053 §5.4.1 | **nothing.** No salt is minted, no handle is written | none | not yet minted |
| **S2 ON** | switch ON, `indicator` in words, and the **same state on the family review surface** (§5.2) | records with `utteranceHandle`; content store, cursor and consent record written | weekly, sealed, §3.6 | **minted here**, Keychain this-device-only |
| **S3 REVOKING** (transient) | `optOutConfirm` + `optOut` / `optOutCancel` | unchanged until confirm | none new | still present |
| **S4 REVOKED** | as S0, plus the consent record showing a withdrawal | the handle **stripped** from every line; loop content store, cursor and salt **destroyed** | none | **destroyed** |

**Transition effects, stated as the acceptance criterion requires — including what each does to *already-egressed* data:**

| Transition | Captured, not yet egressed | Already egressed |
|---|---|---|
| **S0 → S1** | nothing happens; no state is written | unaffected (there is none) |
| **S1 → S0** (cancel) | nothing happens; **no partial state may remain** — a cancelled consent must not leave a minted salt or a written handle | unaffected |
| **S1 → S2** (confirm) | from this instant records carry handles and the content store fills; **`acceptedAt` is set here and is the lower bound of eligibility** (§3.8) | unaffected |
| **S2 → S3** | nothing yet; the confirm dialog is shown first | unaffected |
| **S3 → S1/S2** (cancel) | nothing; the loop continues exactly as before | unaffected |
| **S3 → S4** (confirm) | **destroyed now, irreversibly**: handles stripped, content store deleted, cursor deleted, salt destroyed | **retained** under the 180-day window, **with no further egress** — and unlinkable from that moment on, because the salt is gone |

**Atomicity is a requirement, not a nicety.** The S1 → S2 entry and the S3 → S4 entry each perform several stores; each must be ordered so that a crash leaves a **safe** state, and the safe direction is the closed one:

- **S1 → S2:** mint the salt **first**, write the consent record **second**, and only then begin writing handles. A crash between the two leaves **no handle written and no egress** — recoverable, and it re-enters S1.
- **S3 → S4:** strip the handles **first**, delete the content store **second**, delete the cursor **third**, destroy the salt **last**. A crash at any point leaves egress already stopped and the most sensitive artifact (the content) already gone; a crash before the last step leaves the loop re-entering S3 on next launch, which is visible and honest.

**The no-silent-stub rule applies to this table.** An opt-out that flips a stored flag while a sealed batch is in flight, or that leaves the content store on disk, is the defect this design exists to make checkable — not a simplification. Specifically, **the S3 → S4 entry must cancel any in-flight request**; a request that has already completed is not recallable, which is why the copy says what is kept rather than pretending otherwise.

### 5.2 Surfaces, placement and the indicator

| Question | Ruling |
|---|---|
| **Where the control lives (primary user)** | **Settings → Privacy**, in the same screen as the policy text it amends (`PrivacySettingsView`, `SettingsView.swift:3730`). Not in Voice settings: the loop is not a voice-stack choice, and the disclosure it amends is the privacy policy's |
| **Where the control lives (family)** | the **family review surface** carries the *same state in words* — `IntentLogReviewView`. Not a second control by default: the family configures the device and may operate the switch, but the ruling T-053 §7.2 makes is about **visibility where the data is reviewed**, and that is satisfied by the state readout |
| **The indicator** | `settings.learningLoop.indicator` / `.indicatorOff` — a **worded state**, not a colour alone. Open Decision 12's precedent is *"a visible indicator while a cloud engine is active"* (`constitution.md:130`), and the shipped precedent is the honest interpreter-state caption (`SettingsView.swift:1115-1117`) |
| **Indicator on the review surface** | **required.** T-053 §7.2: *"A switch that is on but invisible on the review surface is not compliance with this ruling — the family reviews the data, so the family sees the state."* |
| **Refusing/blocked states** | a **recovering** card, following `degradationDiagnosticsSection` (`SettingsView.swift:253-269`, *"the card disappears the moment every failure recovers"*), showing `egressPending` or `egressNeedsUpdate` (§5.3). A refusing loop is never silent (T-053 §5.4.6; acceptance criterion 4) |
| **Externalisation** | every string lives in `Resources/Localizable.xcstrings` under the `settings.learningLoop.*` prefix with **both** `en` and `ne`. Non-View code resolves them through `L10n.str(key, locale:)`; Views use the literal-key `Text("…")` form. **No literal user-facing string may appear in Swift** (NFR-023/NFR-024; T-053 §7) |
| **Accessibility / register** | the strings use the shipped plain register (*"scrambled code"*, *"counts and codes"*) and contain no technical term: no "hash", no "anonymised", no "aggregate", no "telemetry". This is a copy ruling, not a style preference — the reader is an elderly Nepali speaker, and a term they would not use is a disclosure they did not receive |

### 5.3 The strings — verbatim, for T-056 to copy

**§5.3.1 — T-053 §7.1's set, unchanged.** Copy these **verbatim**; they are T-053's ruling and are the consent's text.

| Key | English | Nepali |
|---|---|---|
| `settings.learningLoop.title` | Help improve the assistant | सहायक सुधार्न मद्दत गर्नुहोस् |
| `settings.learningLoop.explanation` | When you turn this on, this phone counts the times you corrected the assistant, the times you said no, the times you did not answer, and how sure it was. Only those counts, small codes (which action, which kind of correction, how sure), and one scrambled code for each sentence leave this phone. The words you say, names, medicine names and messages never leave this phone. This helps the assistant get better at Nepali. You can turn it off at any time. | यो खोल्दा, तपाईंले सहायकलाई सुधार्नुभएको, नाइँ भन्नुभएको, जवाफ नदिनुभएको, र सहायक कति विश्वस्त थियो भन्ने कुराको गन्ती यही फोनले राख्छ। यही फोनबाट बाहिर जाने कुरा: ती गन्ती, साना कोड (कुन काम, कस्तो सुधार, कति विश्वस्त), र हरेक वाक्यको एउटा अव्यवस्थित कोड मात्र जान्छ। तपाईंले भन्नुभएका शब्द, नाम, औषधिका नाम र सन्देश यही फोनमा रहन्छन्। यसले सहायकलाई नेपालीमा अझ राम्रो बनाउन मद्दत गर्छ। तपाईं जहिले पनि यो बन्द गर्न सक्नुहुन्छ। |
| `settings.learningLoop.consentQuestion` | Turn this on? Nothing you say is sent — only counts and codes. | यो खोल्ने हो? तपाईंले भन्नुभएको कुरा पठाइँदैन — गन्ती र कोड मात्र पठाइन्छ। |
| `settings.learningLoop.consentConfirm` | Yes, turn it on | हो, खोल्नुहोस् |
| `settings.learningLoop.consentCancel` | Not now | अहिले नहोस् |
| `settings.learningLoop.indicator` | Sharing counts and codes: ON | गन्ती र कोड पठाउने सुविधा: खुला छ |
| `settings.learningLoop.indicatorOff` | Sharing counts and codes: OFF | गन्ती र कोड पठाउने सुविधा: बन्द छ |
| `settings.learningLoop.neverLeaves` | Your words, contact names, medicine names, messages and health information never leave this phone, on any setting. | तपाईंका शब्द, सम्पर्कका नाम, औषधिका नाम, सन्देश र स्वास्थ्य जानकारी कुनै पनि सेटिङमा यही फोनबाट बाहिर जाँदैनन्। |
| `settings.learningLoop.optOut` | Turn off and delete | बन्द गरी मेट्नुहोस् |
| `settings.learningLoop.optOutConfirm` | Turn this off? Everything not yet sent is deleted right away. What was already sent is kept for up to 6 months, but it can no longer be linked to anything you say from now on. The assistant keeps working exactly as it does now. | यो बन्द गर्ने हो? अहिलेसम्म नपठाइएका सबै कुरा तुरुन्तै मेटिन्छन्। पहिले पठाइसकेका कुरा बढीमा ६ महिनासम्म राखिन्छन्, तर ती अब तपाईंले अबदेखि भन्ने कुनै पनि कुरासँग जोडिन सक्दैनन्। सहायक अहिले जस्तै चलिरहन्छ। |
| `settings.learningLoop.optOutCancel` | Cancel | रद्द गर्नुहोस् |

**Three copy rulings, restated so they are not softened:** the copy says **"6 months", not "180 days"** (and a change to the retention rule changes this string); it **never uses a word the reader would not use**; and it **does not promise more than §3.8 delivers** — it says what is deleted now, what is kept, and the one thing salt destruction guarantees.

**§5.3.2 — two strings T-053's set does not provide, added here.**

T-053 §5.4.6 requires the app to *"say so honestly rather than shipping a narrower payload silently"* when egress is refused for an unaccepted version, and §7.2 requires a visible state while the loop is active — but §7.1's ten strings contain **no string for a loop that is ON and not sending**. The gap is real: with only `indicator`/`indicatorOff`, a refusing loop would display `indicator` ("ON") while nothing left the device, which is the dishonest reading T-053 §5.4.6 exists to forbid. Two states need words:

| Key | English | Nepali |
|---|---|---|
| `settings.learningLoop.egressPending` | Sharing is on. This phone is waiting to send; nothing is lost. | गन्ती र कोड पठाउने सुविधा खुला छ। यो फोनले पठाउन बाँकी छ; केही हराउँदैन। |
| `settings.learningLoop.egressNeedsUpdate` | Sharing is on. Nothing is sent until the app is updated. | गन्ती र कोड पठाउने सुविधा खुला छ। एप अपडेट नभएसम्म केही पठाइँदैन। |

`egressPending` covers a missing salt, a network failure, and a schema-refusal at the boundary; `egressNeedsUpdate` covers the unaccepted-payload-version refusal. **These are T-054's additions to T-053's set**, they are what makes C-4's "fail-closed refusal" and this design's "no silent failure path" externalised rather than asserted, and they are **flagged for T-053's next review** (§11, escalation 4). They add no payload field, so §3.6 re-consent is not triggered.

**§5.3.3 — one string for the mined-rows bundle (T-057 lands it with the bundle).**

T-053 §8 already discloses the family export as the path on which names leave. The mined-rows bundle is a **second** family-initiated content path, and leaving it undisclosed would be an NFR-032 failure of exactly the kind T-053 §8 exists to fix:

| Key | English | Nepali |
|---|---|---|
| `settings.learningLoop.shareMinedRows` | Send learning data to your family? This file has the words the assistant did not understand. It leaves the phone only when you send it. | सिकाइको डेटा परिवारलाई पठाउने हो? यो फाइलमा सहायकले बुझ्न नसकेका शब्दहरू हुन्छन्। तपाईंले पठाउनुभएमा मात्र यो फोनबाट बाहिर जान्छ। |

### 5.4 The policy amendment — T-053 §8, verbatim

**T-053's §8 text is the binding deliverable and is not rewritten here.** T-056 replaces `settings.privacy.body` with exactly these two strings, in both languages, as T-053 §8 delivers them:

- **English.** "Your voice, health information, contacts, and conversations stay on this phone. The assistant can work fully on this phone. If you choose the Gemini voice engine, what you say is sent to Google to be written down as text; you can switch to an on-device engine at any time in Settings and keep every feature. If you turn on 'Help improve the assistant', only counts, small codes, and one scrambled code for each sentence leave the phone — never your words. If your family exports the assistant activity log, that file leaves the phone with the names in it; only your family can start that export. Health data is only read from HealthKit with your permission. Family notifications are sent only when a configured alert fires."
- **Nepali.** "तपाईंको आवाज, स्वास्थ्य जानकारी, सम्पर्क र कुराकानी यही फोनमा रहन्छन्। सहायक यही फोनमै पूरै चल्न सक्छ। यदि तपाईं जेमिनी आवाज इन्जिन छान्नुहुन्छ भने, तपाईंले भन्नुभएको कुरा लेखाइको रूपमा परिणत गर्न Google मा पठाइन्छ; तपाईं जहिले पनि सेटिङमा गएर यन्त्रमै चल्ने इन्जिन छान्न सक्नुहुन्छ र सबै सुविधा यथावत् रहन्छ। यदि तपाईं 'सहायक सुधार्न मद्दत गर्नुहोस्' खोल्नुहुन्छ भने, गन्ती, साना कोड र हरेक वाक्यको एउटा अव्यवस्थित कोड मात्र फोनबाट बाहिर जान्छ — तपाईंका शब्द कदापि जाँदैनन्। यदि परिवारले 'सहायकको गतिविधि' को निर्यात गर्नुभयो भने, त्यो फाइलमा नामहरू सहित फोनबाट बाहिर जान्छ — त्यो निर्यात परिवारले मात्र सुरु गर्न सक्छ। स्वास्थ्य जानकारी तपाईंको अनुमतिमा मात्र HealthKit बाट पढिन्छ। परिवारलाई सूचना तोकिएको अलर्ट सक्रिय भएमा मात्र पठाइन्छ।"

**One amendment to §8 is owed and is flagged, not made** (§11, escalation 5). §8 introduces the loop and the export, and it does not introduce the **mined-rows bundle** (§4.1) — a second path on which words leave. Two clauses would fix it: after *"only your family can start that export"*, add *"If your family sends learning data, that file has the words the assistant did not understand, and it leaves only when your family sends it."* (and the Nepali equivalent from §5.3.3's key). The wording is T-053's to rule; this design records the gap with the string and the reason so it is not lost.

### 5.5 The `IntentLogStore` docstring amendment

The design's §4.1 requires the amendment; T-056's DoD carries it. **The wording is fixed here.** Note that the docstring's **first** sentence stays true and stays: the hashed channel deliberately does not ride `ObservabilityBus` (design §5.3, and F-2's reason above).

**Before — `IntentLogStore.swift:18-20`:**

```swift
/// telemetry, which stays PII-free (C9): this log contains slot values
/// (contact names) by design — it is TRAINING DATA, kept on-device under
/// device protection, and leaves only via the family's explicit export.
```

**After — land verbatim:**

```swift
/// telemetry, which stays PII-free (C9): this log contains slot values
/// (contact names) by design — it is TRAINING DATA, kept on-device under
/// device protection. CONTENT — the slot values, and the words they came
/// from — leaves only via the family's explicit export. DERIVED SIGNALS
/// leave over the loop's separate opt-in hashed channel (T-054; default
/// OFF, revocable): a calendar day, the action, the outcome, the kind of
/// correction, confidence and latency BUCKETS, and one scrambled per-record
/// code. Never a word the user said, and never a contact name. The hashed
/// channel does NOT ride `ObservabilityBus` — the bus stays a print-only,
/// PII-free diagnostics boundary.
```

**And the second, smaller lie in the same file — `IntentLogStore.swift:30`.** The `path` docstring lists five values of which one is real (T-052 §3.5c). T-053 §2.2 row 4 requires the mismatch fixed **or** the field dropped from the payload; this design drops the field (§3.2) **and** fixes the comment, because the comment misleads the next reader regardless of the payload:

```swift
        /// Observed: "model" (the interpreted path — the only layer with a
        /// confirmation flow) | "override" (the call-correction protocol).
```

Both are conditions (C-10).

---

## 6. Decision E — the one-page contract

**Every field every later task can check: field → allowed location → egress form → condition.** "Device" means the on-device stores; "payload" means the `loop-egress/v1` envelope of §3.1.

| Field | Allowed location | Egress form | Condition |
|---|---|---|---|
| `Record.id` | device | **NEVER — not even hashed** (T-053 §2.2 r2) | the **only** permitted use is as `record_dedup`'s HMAC input, in memory, at seal time. No store holds a derived handle |
| `Record.timestamp` | device | **never at full precision** | only the derived `day` (`YYYY-MM-DD`, local calendar, no timezone) may egress; never the double, never a time |
| `Record.path` | device | **NEVER** | no payload field; the value is determined by `outcome` (§3.2). C-10 fixes the docstring |
| `Record.action` | device + payload | closed-vocabulary id | must be a member of the twelve schema-v2 ids; `plugin` stays excluded |
| `Record.slots` | device + the family export (pre-existing, separately disclosed) | **NEVER, nor a hash of a value** | a hash of a contact name from a family-sized candidate set is a confirmable oracle (T-053 §4/T4 r3) |
| `Record.outcome` | device + payload | closed-vocabulary id | one of `confirmed / corrected / denied / timeout`, the persisted raw values |
| `Record.correctedTo` | device + the family export | **never the map; only `correction_kind`, from the KEYS** | present iff `outcome == corrected`; no egressed value may equal a `correctedTo` value |
| `Record.confidence` | device + the family export | raw **NEVER**; `confidence_bucket` only | bands fixed at the router's three (`lt_0_4`, `0_4_0_7`, `ge_0_7`); omitted when nil |
| `Record.latencyMs` | device + the family export | raw **NEVER**; `latency_bucket` only | bands ≥ 5 s (`lt_5`, `5_15`, `15_30`, `30_45`, `ge_45`); omitted when nil; never paired with a sub-day timestamp |
| **`Record.utteranceHandle`** (new) | device only | **NEVER — in any form** | written only while the opt-in is ON; matches `^[0-9a-f]{16}$`; stripped on opt-out; no egress field may be named `surface*`/`utterance*` or resolve to it |
| **loop content store L-1** (new) | device only, encrypted channel, excluded from backup | **NEVER** | written only while ON; holds `handle → sanitised transcript`; swept at 90 days by `lastSeen`; deleted wholesale on opt-out |
| **loop cursor L-2** (new) | device only, encrypted channel | **NEVER** | written only while ON; monotonic; `cursor_lost` counted, never silently reset; deleted on opt-out |
| **consent record L-3** (new) | device only, encrypted channel | **NEVER** | `{payloadVersion, schemaSha8, acceptedAt}`; `acceptedAt` is the eligibility floor; retained after revocation as the record of the withdrawal |
| **salt L-4** (new) | Keychain, `WhenUnlockedThisDeviceOnly`, `Synchronizable = false`, in `keychainResidentKeys` | **NEVER — not escrowed, not synced, not backed up** | minted on S1→S2; destroyed on S3→S4; event-driven rotation only; unavailable ⇒ fail closed |
| **`record_dedup`** (payload) | payload only | `^[0-9a-f]{16}$` | `HMAC-SHA256(salt, id)`, minted at seal, never persisted back; the receiver may use it **only** to collapse duplicate deliveries |
| **`day`** (payload) | payload only | `YYYY-MM-DD` | local calendar day of `timestamp`; no timezone, no offset, never finer |
| **`batch_week`** (payload) | payload only | `YYYY-Www` | ISO week of the seal; **coarser** than a day; timezone-free |
| **`aged_out_total`** (payload) | payload only | integer ≥ 0 | the only counter; normally 0; the honest admission that the 90-day filter bit |
| **`seed data`** (payload) | payload only | — | exactly 262144 bytes every time, including a zero-signal week |
| **mined-rows bundle** (new) | device → the family's explicit share → the training box | **not the loop's egress at all** | never serialised by `exportURL()`; never uploaded by the uploader; ingested only through a validated `--consent-export`; rows refuse without it (`mined:` provenance gate) |
| **any diagnostic/divergence telemetry** | `ObservabilityBus` → `LogSanitiser` allow-list only | **never this payload** | the two channels are disjoint (§8); no payload field may appear in a bus event, and no bus key may appear in the payload |

---

## 7. Transport and failure modes

### 7.1 The uploader

**A dedicated opt-in uploader, and explicitly not `ObservabilityBus`.** Design §5.3 gives the reason and F-2 sharpens it: the shipped bus's only implementation is `ConsoleObservabilityBus`, which **prints** every sanitised event (`AppCoordinator.swift:7829-7850`), and its contract is PII-free **local diagnostics** (`LogSanitiser.swift:56-80`). Routing device data through it would either add a network sink to a boundary T-049/T-050 just hardened, or print the payload to a console. The loop's **telemetry** rides the bus; the loop's **egress** does not.

| Property | Ruling | Authority |
|---|---|---|
| **Endpoint** | `POST {configured base}/v1/loop/signals`; body = the 262144-byte CBOR envelope; `Content-Type: application/cbor` | this design; the endpoint identifies the kind, so no `kind` field is carried (§3.2's minimality rule) |
| **TLS** | **TLS 1.2 minimum**, system trust evaluation, **no** `URLSessionDelegate` that overrides trust, no ATS exception | NFR-011, including its second sentence: *"Connections failing certificate validation must be rejected"* |
| **Credential** | **none in v1.** The receiver is a project-owned, write-only ingestion endpoint. Abuse control is an in-memory, short-TTL rate limit at the edge, applied to the connection and **never recorded with a payload** | T-053 C-3 r3; §4/T5 r2. If a credential becomes necessary it must be **rotating (per-batch), never stable** — a stable token is an install pseudonym by another name |
| **Timeout** | `learningLoop.upload.timeoutSeconds` — a **configurable parameter, default 30** | Agent Principles: timeouts are configurable parameters, not hardcoded constants |
| **Retries** | bounded per slot (`learningLoop.upload.maxAttemptsPerSlot`, default 3) with exponential backoff **inside** the slot; a batch that still fails is folded into the next weekly slot | §3.6; the cadence is the retry policy's outer bound |
| **Cadence** | weekly, unconditional, exactly one upload per ISO week while ON | §3.6; C-3 r2 |
| **Batch size** | exactly 262144 bytes, always | §3.6 |
| **Receipt** | a 2xx with a body the uploader can validate as the receiver's acknowledgement advances the **egress cursor**; anything else leaves it unadvanced | §2.6. A silent 2xx with a bad body must not advance the cursor |
| **Retention the uploader must respect** | **no payload in any log** — size and status only | `remote-config-channel-design.md:76-77`, adopted verbatim |
| **Credential discipline** | no secret in any log, URL or fixture | T-056's DoD; T-049/T-050 precedent |
| **Never** | never `exportURL()`, never the family `ShareLink`, never `ObservabilityBus`, never the loop content store | C-6; §8 |

### 7.2 Every failure mode, with its user-visible behaviour

The acceptance criterion requires every failure mode enumerated and **no failure path that silently discards captured signals without saying so**. All six required modes are below, plus three the design adds.

| # | Failure | What happens to the signal | User-visible behaviour | Fail direction |
|---|---|---|---|---|
| **1** | **Upload failure** — network error, timeout, non-2xx | **retained.** The egress cursor does not advance; the records are re-sealed at the next slot | after the first failure, `egressPending` on the Settings card and the review surface, as a recovering card (`SettingsView.swift:253-269`) | closed — no egress, no data loss |
| **2** | **Partial upload** — the connection drops after the body is sent, or the acknowledgement is lost | **at-least-once.** The batch is re-sent at the next slot folded in; the receiver collapses the duplicate by `record_dedup` | none (nothing is lost, nothing is duplicated) | closed |
| **3** | **Opt-out mid-flight** — S3 → S4 while a request is open | the request is **cancelled**; the sealed batch (memory only) is dropped; content store, cursor and salt are destroyed | `indicatorOff`; `optOutConfirm`'s copy already states that what was already sent is kept | closed — this is the one case where a *completed* upload is not recallable, and the copy says so rather than pretending |
| **4** | **Salt unavailable** — Keychain locked before first unlock, or the item is missing | **no handle written, no content entry, no seal, no upload.** The record still appends with the shipped nine fields | `egressPending` while the condition persists | closed (T-056's DoD: *"failing closed if unavailable"*) |
| **5** | **Clock skew** — the device clock jumps | the `day` and `batch_week` follow the device clock, as T-053 §6's retention does. A forward jump can age records out of the 90-day window early; a backward jump can write a `day` earlier than the true one | a forward jump that ages records out is **counted in `aged_out_total`** and therefore visible in the payload itself; a backward jump is bounded by the cursor's monotonicity (never re-sends a sealed window) | closed in the sense that matters: a skew can lose eligibility **visibly**, and can never cause a re-send of an already-egressed window |
| **6** | **Boundary schema check fails** — the sealed payload does not validate against §3.1 | **do not send.** The batch is retained, the cursor is not advanced | `egressPending`, and the event is counted. A schema failure is a **code defect** and must be loud | closed — *the payload must never leave a device it failed to satisfy* |
| **7** | **Envelope overflows 262144 B** | **do not send**; retained; counted | `egressPending` | closed. Unreachable by construction (500 × 400 B); the guard exists against a code defect |
| **8** | **Zero-signal week** | **an empty, padded envelope is still sent** | none — the indicator reads ON and is truthful | not a failure: this is what keeps timing uniform (§3.6) |
| **9** | **Unaccepted payload version** (§3.3) | **no egress at all**; records and handles continue to be captured (or not — see below) | `egressNeedsUpdate`; **the app says so honestly rather than shipping a narrower payload silently** (T-053 §5.4.6) | closed |

**On mode 9, one ruling so the state is unambiguous:** when the recorded consent's `payloadVersion` is not one this build implements, the loop **stops egressing but keeps capturing**, because the captured signal is still what the user consented to collect and destroying it would be the *opposite* of the user's intent. Capture stops only on opt-out. The un-egressed signal remains subject to the 90-day and opt-out bounds.

**On mode 1 and mode 6, the sentence the acceptance criterion asks for, verbatim as a requirement:** *no failure path may discard captured signals without saying so.* Every path above either retains the signal or is the opt-out the user asked for; the two paths that can drop signal for a reason other than opt-out — retention (mode 5) and envelope overflow (mode 7) — are **counted in the payload** (`aged_out_total`) and **surfaced in the UI** rather than being silent.

---

## 8. The boundary with T-055's telemetry channel

T-055 owns shadow scoring and divergence telemetry. T-053 §3.7 fixes it: divergence telemetry rides the **existing bus**, is **print-only** and therefore *diagnostic, not retained*, and its new keys must be declared in `LogSanitiser` with bounded value spaces. T-053 §3.7's permitted keys are `divergence_count` (int ≥ 0), `divergence_rate_bucket` (a **fixed band enumeration, not a float**), `action_id` (the schema-v2 action set) and `escalation_reason` (the existing `LocalBrainChain.EscalationReason` raw values).

**The two channels are disjoint, and the boundary is stated as a rule in both directions so the two documents cannot drift:**

| Direction | Rule | Checkable as |
|---|---|---|
| **Telemetry must not enter this payload** | no key from T-055's set — nor any divergence count, rate, bucket, reason, or `Record.id` — may appear in `loop-egress/v1` | the §3.1 schema's `additionalProperties: false` plus a grep of the serialiser for the four key names |
| **This payload must not enter telemetry** | no bus event may carry a payload field, `record_dedup`, a day, an action/outcome id from the loop's emission, or anything read from the loop content store, the cursor or the consent record | `LogSanitiser.allowedKeys` contains none of them; unknown keys are dropped (`LogSanitiser.swift:94-96`) |
| **Specifically: `record_dedup` must NOT be added to `allowedKeys`.** The allow-list **already carries two id hashes** — `entry_id_hash` and `contact_id_hash` (`LogSanitiser.swift:58-59`) — so "the bus already has id hashes" is the most plausible route by which a loop digest would be added to it. It must not be: the bus **prints** (`ConsoleObservabilityBus` → `print`), it is not consent-gated, and its hashes are unsalted SHA-256 while `record_dedup` is salt-keyed precisely so that opt-out destroys linkability. A bus-printed `record_dedup` would put an egress pseudonym into a console log with no consent and no deleter. **T-055's four permitted keys are the only loop-adjacent additions this design anticipates** | the allow-list's contents; a grep of the loop's serialiser and uploader for `allowedKeys` |
| **The bus is not widened for the loop's egress** | the loop's uploader is not an `ObservabilityBus` implementation, and no network sink is added to the bus | the uploader's type is not `ObservabilityBus`; `ConsoleObservabilityBus` remains the only implementation |
| **Retention differs by design, and that is the point** | telemetry is print-only and retained nowhere; the payload is retained by the receiver under the 180-day rule | T-053 §3.7 r2's *"the loop's telemetry goes through the bus; the loop's egress does not"* |

**And the reason the bus works for divergence at all, so the contrast is not mistaken for an oversight:** divergence telemetry is content-free *by construction* — both interpreter outputs are discarded and only a summary persists (T-053 §3.7 r1). The egress payload is not content-free in that sense; it is content-free *by schema*, and it therefore needs its own boundary, its own consent, its own salt and its own transport.

---

## 9. Conditions this design adds (C-10 … C-17)

Continuing T-053's series. Each is checkable by T-059, and each names the task that owns it.

| # | Condition | Owner | What T-059 checks |
|---|---|---|---|
| **C-10** | **The two docstrings are corrected.** `IntentLogStore`'s class docstring names **both** channels with the §5.5 wording, and the `path` field comment states the **observed** vocabulary (`model`, `override`) rather than the five-value list | **T-056** | the two docstrings against §5.5 verbatim; the `path` comment against T-052 §3.5c |
| **C-11** | **`record_dedup` is purpose-limited at the receiver.** It is used **only** to collapse duplicate deliveries. It is never used to group records, to build a per-install series, or to join loop payloads with any other dataset; and **no batch id, session id or install pseudonym may be added beside it** | **T-056** (client) / **owner** (receiver) | the receiver's ingestion code and its logging policy; the absence of any other identifier field in the schema |
| **C-12** | **The sealer is unconditional and fixed-size.** Exactly one upload per ISO week while ON, **including a zero-signal week**; exactly 262144 bytes every time; a batch that fails its own boundary check is **not sent**; an overflow is refused, retained and surfaced | **T-056** | the empty-week fixture; the boundary check's fail-closed branch; the sealed size |
| **C-13** | **The `mined:` provenance gate closes the `--sources` side door.** A row whose `source` begins with `mined:` is refused unless the run carried a validated `--consent-export`; the gate lives in the row-conversion path, not in the flag's handler | **T-056 / T-057** | a run with `--sources <bundle>` and **no** `--consent-export` exits `EXIT_GUARD` (3) |
| **C-14** | **The ingestion contract (I-1…I-7) is implemented, and `annotation_rules.yaml`'s `bundle_source`/`requirements` are replaced with §4.5's text.** The run manifest records `real_user_rows`, `bundle_ref` (`<sha8>`), and `encryption_gap_flagged: true` — **never the bundle's content** | **T-057** | the manifest's consent block; the bundle-source text; the refusal cases I-1…I-3 |
| **C-15** | **The loop content store is the encrypted channel, and content lives only there.** Not plaintext JSONL, not `exportURL()`'s file, not `IntentCommandCache`; written only while the opt-in is ON; excluded from backups; deleted wholesale on opt-out | **T-056** | the store's storage class; a test that no transcript appears in `intent-log.jsonl` or in `IntentCommandCache`; the opt-out deletion test |
| **C-16** | **A capture happens only on a verdict, and the loop adds no capture path of its own.** The loop writes its handle and content entry **from the existing seam** — at the seven `appendCapture` callers' verdict site and at the correction site for the amendment utterance (`PendingCallAction.amendmentTranscript`) — and it never widens the always-on collection (C-7) | **T-056** | the seam's call graph; the record's key set OFF vs ON (§2.4); the `amendmentTranscript` capture at `AppCoordinator.swift:5456-5483` |
| **C-17** | **The two added status strings are externalised in `en` and `ne` and shown wherever the indicator is** — Settings **and** the family review surface — so a refusing or blocked loop is never displayed as simply "ON" | **T-056** | the xcstrings keys in both locales; the card's states; the review surface's readout |

**If the loop is descoped to on-device-only mining (the design's option D):** C-11, C-12, C-13's `--consent-export` half and C-14's ingestion half fall away with T-053's C-1/C-2/C-3/C-7/C-9; **C-10, C-15, C-16 and C-17 survive** — the docstrings would still lie, the content store would still exist (it is what makes mining possible at all), the seam rule is what keeps the always-on collection unchanged, and the copy still has to be truthful about what is *not* sent.

---

## 10. Refinements to T-053's rulings (delta table)

Nothing below re-opens a ruling. Each is a **narrowing**, a **completion** of a gap T-053 left, or a **consequence T-053 did not have the evidence for**. Narrowings do not re-trigger consent (T-053 §3.6).

| # | T-053 said | This design says | Why |
|---|---|---|---|
| **R-1** | §2.2 row 4 permits a `path`-sourced payload field **only if** T-054 enumerates the observed set | **the field is dropped**, and the docstring is fixed anyway | the observed set `{model, override}` is a function of `outcome`; row 4's own alternative arm ("or the field is dropped") is taken. §3.2 |
| **R-2** | §2.2 row 6 permits the **slot key names** to be carried, never the values | **dropped**, because the key set is a function of `action` and the on-device miner already has it | the minimality rule; §3.2 |
| **R-3** | §3.2 forbids any field whose value space is "a string" | **and forbids a `null` value**: "not observed" is encoded by **omitting the key**, never by a null | a nullable enum is the same hole one step over, and omission matches the shipped encoder's treatment of `nil` optionals (`IntentLogStore.swift:70-75`). §3.1 |
| **R-4** | §3.3 forbids any egress timestamp finer than a day and any timezone | **the channel family's `timestamp` convention must not be inherited**: the loop's envelope carries `batch_week` (coarser than a day) and **no timestamp field at all** | `remote-config-channel-design.md:15` carries an ISO-8601 timestamp; copying the family shape would have broken §3.3. **F-6** |
| **R-5** | §2.2 row 10 requires latency bands of **at least 5 s**, "edges fixed by T-054" | edges fixed at **5 / 10 / 15 / 15 / open** — coarser than the allowance | coarser is a narrowing; fewer bands, less signal. §3.1 |
| **R-6** | §3.4 authorises `HMAC(salt, id)` truncated to 16 hex as a per-record **dedup** handle | it is also the **only** idempotency key, and that is its *stated purpose*; and it is what §7.1's *"one scrambled code for each sentence"* means — a keyed digest of `id`, **never** of the utterance | T-053 §4/T5 r2 requires a stated purpose before any stable identifier; the copy already promises the field. **F-5** |
| **R-7** | §4/T5 r2 permits a group key over an **enumerated** field (`HMAC(salt, action)`, `HMAC(salt, correction_kind)`) | **no group-key field is carried at all.** If the receiver needs to group, it groups over the enumerated fields it already has — no additional digest is needed or permitted | §3.4's low-entropy rule plus the minimality rule; a second digest field would be a second stable identifier for no new information. §3.1's `forbidden` |
| **R-8** | §6 fixes 90 days on-device "applied as a filter at egress time" | the **content store** is deleted **eagerly** at 90 days (`lastSeen`), not merely filtered | content has no reason to outlive its egress window; eager deletion is strictly narrower. §3.8 |
| **R-9** | §6/T-053 C-2 is answered by "the T-054 digest" for addressing | **a cursor, not a digest** — T-052 §6.2 measured the cap as non-binding, and T-052 §6.3 says the artefact is *"load-bearing for addressing, not for survival"* | §2.6 |
| **R-10** | §5.4.6 requires an honest refusal when a version is unaccepted, but §7.1 provides no string for it | `egressPending` and `egressNeedsUpdate` are added (§5.3.2) | without them a refusing loop displays "ON" — the dishonest reading §5.4.6 forbids. **§5.3.2; escalation 4** |
| **R-11** | §3.6's re-consent rule is about **fields** and value spaces | **the emitted action/outcome set is part of the version's value space**: widening `records[]` beyond the captured stream, or adding an action or an outcome, is a re-consent-triggering change | closes a hole where the mining rules could widen what leaves without a version bump. §3.3 |
| **R-12** | §8's policy text names the loop and the family export | it does **not** name the **mined-rows bundle** — a second family-initiated path on which words leave | NFR-032 requires the policy to describe what is transmitted; the gap and the fixing clause are recorded rather than silently skipped. §5.4; **escalation 5** |

---

## 11. Escalations

Five items are the owner's, not this design's. Each has an action and the existing review cadence (2026-10-13, aligned with OD-11 and OD-12) rather than a new one.

**Escalation 1 — record the second consent-gated path.** Owner: **Anjan Poudel (project owner)**. Action: add the Open Decision entry T-053 §10's escalation 1 calls for, citing OD-12's closed scope (*"voice transcription (and only that)"*, `constitution.md:128-132`) as the clause that makes a separate entry necessary. **This design adds one input to that entry**: the loop's payload is `loop-1`, its consent records `schemaSha8`, and the re-consent rule is §3.3's. Review by **2026-10-13**.

**Escalation 2 — the receiver's retention and no-join policy needs an operational owner.** Owner: **Anjan Poudel**. T-053's C-3 r3 (*"must not record IP addresses, user agents, or connection metadata with a payload, and must not join loop payloads with any other data source"*) and C-8's 180-day deletion job are **receiver-side** obligations with no code in this repository. Action: name the operator and record where the deletion job's execution is recorded, so T-059 has an artifact to check rather than a promise. Review by **2026-10-13**.

**Escalation 3 — the credential question for the loop endpoint.** Owner: **Anjan Poudel**. §7.1 rules **no credential in v1** (an install pseudonym without a stated purpose is what T-053 §4/T5 r2 forbids), accepting that the endpoint is an unauthenticated write target bounded by a non-persisting edge rate limit. Action: confirm that trade, or direct that a credential be added — in which case it must be **rotating per batch, never stable**, and the change must be re-reviewed against T-053 §4/T5 r2. Review by **2026-10-13**.

**Escalation 4 — two strings added to T-053's consent set.** Owner: **Anjan Poudel / T-053's next review**. T-053 §5.4.6 requires an honest refusal state and §7.1's ten strings cannot express one; §5.3.2 supplies `egressPending` and `egressNeedsUpdate` in `en` and `ne`. Action: adopt them into the §7.1 set (or rule alternatives) so the consent copy stays single-sourced rather than being split across two documents. The words are the owner's; the requirement is mechanical. Review by **2026-10-13**.

**Escalation 5 — the policy must name the mined-rows bundle.** Owner: **Anjan Poudel / T-053's next review**. T-053 §8's replacement text names the loop and the family export and **not** the second content path (§4.1), which is an NFR-032 accuracy gap of exactly the kind §8 exists to close. §5.4 carries the two clauses and §5.3.3 the string. Review by **2026-10-13**.

**And one item escalated *to* this design's successors rather than the owner**, recorded so it is not lost: **T-056 must not implement the sealer before the schema artifact of §3.1 is landed and hashed**, because the consent record's `schemaSha8` (§3.3) is meaningless if the artifact is still prose at the moment the consent is written.

---

## 12. What this design deliberately does not decide

- **The mining rules themselves.** M0–M10 are T-052's and T-057's; this design assumes them (the emission profile, the on-device collapse of M4/M5, the content-store resolution at MINE time) and adds nothing to them.
- **The shadow-scoring protocol, the divergence keys, the ladder and rollback.** T-055's. §8 fixes only the boundary.
- **The promotion rule and the incumbent comparison.** T-058's (and T-053 OQ-4 explicitly leaves OQ-4 to it).
- **Any runtime code.** T-056 builds. Every "must" below is a contract for it, not an implementation.
- **The training pipeline's behaviour.** T-057 lands it; §4 fixes only the contract it must satisfy.
- **The receiver's implementation.** This design fixes the boundary (TLS-only, no metadata, no joins, 180-day retention) and escalates its operational owner (escalation 2).
- **Any change to the encoder, its taxonomy, its data contract or the AUGMENT floors.** TG-08 owns those; the loop consumes them, and AUGMENT adds supply without lowering a floor (design §4.3).
- **Android.** No capture or shadow path is designed here (design §7.6, §9).

---

## 13. PII and secret discipline

- **No PII in this document.** No utterance, contact name, medication name, message body, health value, hostname or credential appears. The consent copy in §5.3 and the policy text in §5.4 are the only user-facing prose, and they contain no example data. Every value in §3.7's worked example is synthetic, and the two `Record.id` values that produced its digests are deliberately not shown at all — an `id` is local-only and does not belong in an artifact (T-053 §2.2 row 2).
- **No full hash and no credential-shaped value.** Every digest in this document is either a 16-hex interface description (*"a 16-hex-character prefix of a keyed digest"*) or a clearly synthetic 16-hex example. There is no 40-character hex run anywhere. Commit and revision references are 8-character prefixes (`df4ab51`), per T-035's convention and the security-test false-positive the T-054 brief names.
- **The salt is never specified, shown, or derivable.** §3.4 fixes its size, its storage class, its mechanism and its failure mode; it never shows a value, and no artifact in this design has a field for one.
- **Deliberately not asserted:** that the payload is anonymous (§3.4 says the opposite, and the copy is written to that limit); that the loop's accuracy benefit justifies the collection (T-052's measurement does not support a supply argument, and T-052 C-7 is not contradicted here); that the export-encryption gap is fixed (§4.1 records it, following `annotation_rules.yaml:255`); that the receiver's metadata leak is eliminated (§3.5 states the residual and §7.1's no-credential ruling makes the endpoint's knowledge *worse*, not better — accepted and named); and that the timing of an upload is uniform (it is as uniform as the app's launch pattern allows, and §3.6 says so).

---

## 14. Hand-off

| Task | What this design gives it |
|---|---|
| **T-055** | §8 in full: the disjointness rules in both directions, the four key names that must not cross, and the reason the bus is right for telemetry and wrong for egress |
| **T-056** | §2 (the field, the store, the seam, the cursor, the test vectors), §3 (the machine-checkable schema, the salt, the sealer, the boundary check), §5 (the state machine, the three surfaces, all thirteen strings verbatim, both docstring amendments), §7 (the uploader and every failure mode), and C-10, C-11, C-12, C-15, C-16, C-17 |
| **T-057** | §4 in full: the bundle format, I-1…I-7, the `mined:` provenance gate, the teacher-transit conditions, and §4.5's replacement text for `annotation_rules.yaml`. C-13, C-14 |
| **T-058** | §3.3's versioning rule applied to the promotion boundary (a publish under a new payload version requires that version to have been cleared), and §3.8's 180-day deletion job's supersession trigger |
| **T-059** | §6's one-page contract as its audit script, §3.1's schema artifact as its field checker, §3.7's worked example as its field-by-field template, and C-10…C-17 in §9. T-053's C-1, C-2, C-3 and C-6 are **discharged by this design** subject to that audit |
| **T-060** | §3.6's empty-week and overflow cases, §7.2's nine failure modes, and §5.1's four transitions as the fixture's state space |
