# T-053 — Learning-Loop Privacy Review: the determination (rev 2)

**Task:** `.ai-sdd/outputs/plan-tasks/tasks/TG-10-continuous-learning-loop/T-053-learning-loop-privacy-review.md`
**Worktree:** `.claude/worktrees/t053-privacy-review` (branch `worktree-t053-privacy-review`, base master `7289b95`).
**Scope discipline:** documentation only. No production code changed, no build, no test run, no training run, no device access, no merge, no push. This determination is a **binding input** to T-054, T-055, T-056, T-057 and T-058, and the audit criterion for T-059.

**Revision note — what rev 2 is, and why it exists.** Rev 1 of this determination landed at `331db76`
(`specs/T-053-notes.md` in `worktree-tg10-rnd`). Between that revision and this one, the capture layer
changed under it: `f2cbbab` (`[INTENTLOG-CAPTURE]`) widened the flywheel from two writers to the full
confirm-tier verdict set, added `Record.confidence`, and made `latencyMs` live. Rev 1 ruled on a
two-writer, call-only, no-confidence store; three of its rulings are **stale as written** and are
re-decided here (§12 records each delta explicitly). Rev 2 also adds the four things the task brief
asks for that rev 1 did not carry as such: the **field-by-field egress audit** (§2), the **threat
walk** (§4), the **consent-mechanics gap** (§5), and an **explicit verdict** (§0). Everything in rev 1
that remains true is retained, re-verified against the code at this revision, and cited to the line
numbers as they are **here** — not copied forward.

**Status: every ruling below is a yes/no, a number, or a named owner with a date, so T-059 can check
it mechanically.** Five items are escalated to the project owner rather than decided here, and they
are named as such with an owner and a date (§10). Nothing in this document is a principle offered in
place of a decision.

---

## 0. Verdict

### 0.1 The verdict

**GO-WITH-CONDITIONS.** The hashed-only egress path (design D-2) is permissible for this product, and
the privacy basis for it is sound **only under the nine conditions in §11**, each of which is
checkable and each of which is owned by a later task. The conditions are not advisory: a build that
ships the egress without them is not covered by this determination.

Three narrower verdicts, so the boundary is unambiguous:

1. **NO-GO today** for any egress at all. Nothing may leave the device on a loop path until T-056's
   opt-in exists and T-054's payload passes the four-part test (§3.5). The shipped state — an
   always-on, on-device log that leaves only by the family's explicit export — is **compliant as
   shipped** and is not the thing under review.
2. **NO-GO, permanently**, for the design's rejected option (B): replicating the log to a server,
   encrypted or not (`…continuous-learning-loop-design.md` §8.1). That is what Architecture
   Constraint 1 and NFR-015 forbid, and this review does not soften it.
3. **GO-WITH-CONDITIONS, untouched by the loop's value case.** This verdict is on the *privacy*
   question only. T-052 measured the loop's supply argument and found it thin (`T-052-notes.md` §5.3,
   §8: no single week's mined rows can move any action to its floor, and 11 of 12 actions have no
   writer). If the loop is descoped to the design's fallback floor (D — mine on-device, family
   exports explicitly, no egress), then C-1, C-2, C-3, C-7 and C-9 evaporate and only the copy and
   policy items remain (§11).

### 0.2 What the loop's egress is, in one line

It is a **pseudonymous, bucketed, low-volume counter channel** — not anonymity, not content — and the
determination's whole job is to keep it that and no more (`R-3`; design §5.2).

### 0.3 The head-line findings

| # | Finding | Where |
|---|---|---|
| F-1 | **The loop needs its own disclosure and consent.** It is not covered by Open Decision 12, whose scope is closed at "voice transcription (and only that)". It is a *second* consent-gated, non-default path, built on OD-12's five obligations as the project's template, and it must be recorded as its own Open Decision entry. | §5, OQ-1 |
| F-2 | **The collection widened under this review, and the consent copy rev 1 wrote was written for the narrower collection.** Since `f2cbbab` the log records denials and non-answers as well as confirmations and corrections, for a second action (`create_calendar_event`), each carrying the interpreter's confidence. NFR-032 requires the disclosure to describe **what is actually collected** — so the copy in §7 is the widened copy, and rev 1's strings are superseded. | §1, §7 |
| F-3 | **The shipped capture already diverges from the design's hashed-only promise in one direction only: it is *stricter* on egress and *looser* on storage than the promise reads.** Nothing egresses today at all; the on-device record now carries content (`slots` with contact names), a raw confidence float and a raw latency integer. The divergence is an **accepted local feature, not an egress hazard** — but only because the payload is built from a whitelist and never by serialising `Record`. That is now a condition (C-1), not an assumption. | §2, §3 |
| F-4 | **The family export is a plaintext egress path with no protection attribute set on the file.** It is a pre-existing, user-initiated, separately-disclosed channel, not a loop path — but it is the one path on which contact names leave the device, and the loop must not reuse it (C-6). | §2.3, §4/T1 |
| F-5 | **`correctedTo` may not egress, even though its value is an enum today.** It is typed as a value map (`[String: String]?`), so the type cannot hold a value space, and the next writer may put anything in it. Only a closed-vocabulary *correction kind* may egress. | §2.2, §3.2 |
| F-6 | **The shipped privacy policy is already inaccurate, before the loop adds anything.** It states "Nothing is sent to the cloud for AI processing" while the shipped default engine stack **is** the cloud engine (`?? .gemini`). The loop's amendment must fix that in the same pass rather than layering a second inaccuracy on the first. | §8 |
| F-7 | **The loop's own `latencyMs` ruling flips: it is now live.** Rev 1 ruled the latency bucket out of the payload because no writer ever populated `latencyMs`. `Capture.record` now does (`Int` whole ms, question → verdict). Re-ruled: a coarse bucket may egress; the raw millisecond value never may. | §2.2, §12 |
| F-8 | **Teacher transit: YES by owner decision (2026-09-15).** The project owner has ruled that the family's export consent covers feeding mined rows to `gen_teacher.py`. This unblocks the T-057 rephrase path under the standing conditions (opt-in active, whitelisted mined rows only, TLS-only teacher endpoint). | §9, OQ-2 |

---

## 1. What is actually collected — read before ruling

The determination must not describe a collection that does not exist, or bless one that does. Every
line number below was read at this revision.

### 1.1 The store

| Fact | Source (verified at this revision) |
|---|---|
| On-device JSONL in Application Support, directory created with `NSFileProtectionComplete`; the rewrite path re-applies `.complete` to the file | `ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift:99-106`, `:180-187` |
| Deliberately content-bearing and separate from the PII-free observability bus; the docstring names `slots` (contact names) as the training payload and says the log "leaves only via the family's explicit export" | `IntentLogStore.swift:3-24` |
| One store instance, owned by the coordinator | `ios/ElderlyAssistant/App/AppCoordinator.swift:1467` |
| **No consent gate of any kind exists on writes** — `append` has no caller-side condition | `IntentLogStore.swift:110-135`; both capture seams at `AppCoordinator.swift:7127-7131` |
| Cap 500 records, oldest trimmed, at an amortised threshold | `IntentLogStore.swift:90`, `:129-133` |
| Review screen: read-only, `ShareLink` on the export URL, and a family-owned "clear" that calls `removeAll()` | `ios/ElderlyAssistant/App/IntentLogReviewView.swift:23-34`, `:82-92` |
| Export writes JSONL to `FileManager.default.temporaryDirectory` and hands it to the share sheet; **no protection attribute is set on the exported copy** (contrast `:105`, `:185`), and nothing deletes it afterwards | `IntentLogStore.swift:149-164`; `removeAll` removes only the store file (`:166-168`) |

### 1.2 The writers, since `f2cbbab`

The flywheel is no longer call-only. Every confirm-tier verdict now travels one mapping
(`IntentLogStore.Capture` + `Verdict`, `IntentLogStore.swift:190-260`), and the append sites are:

| Writer | Action | Verdict | `slots` | `confidence` | `path` | Source |
|---|---|---|---|---|---|---|
| Confirmed call (on the write, not on the "yes") | `call` | `confirmed` | `contact` (name), `method` (enum raw) | from the interpreted command; nil for touch-originated | `model` | `AppCoordinator.swift:5611-5617`, capture at `:5362-5368` |
| Method-override correction (`"होइन, फोन नै गर"`) | `call` | `corrected` | same as above — the *original* plan's values | the misheard interpretation's | `override` | `AppCoordinator.swift:5456-5483` |
| Declined call confirmation | `call` | `denied` | `contact`, `method` | as above | `model` | `AppCoordinator.swift:7197` |
| Confirmed calendar event (on the EventKit write) | `create_calendar_event` | `confirmed` | **deliberately nil** — the title is user content with no reviewed capture policy | nil | `model` | `AppCoordinator.swift:5176-5183`, `:5301` |
| Declined calendar event | `create_calendar_event` | `denied` | nil | nil | `model` | `AppCoordinator.swift:7222` |
| Either confirmation's 45 s window expiry | `call` / `create_calendar_event` | `timeout` | as per action | as per action | `model` | `AppCoordinator.swift:7136-7144` |

`latencyMs` is now populated for every writer that has a `requestedAt`: whole milliseconds from the
confirmation question to the verdict, floored at 0, **nil** (never a fabricated 0) when the start is
unknown — `IntentLogStore.swift:243-259`.

**The medication challenge is deliberately not captured** (the flow is `neverGated` and its pending
entry is a dose, not a confirm-tier intent — `AppCoordinator.swift:7133-7138`). No medication name,
dose or schedule enters this store today.

### 1.3 What is *not* collected — the part the copy must not overstate

Read from the struct and from every writer, not inferred:

- **No transcript, and no field that can hold one.** `Record` is `id, timestamp, path, action, slots,
  outcome, correctedTo, confidence, latencyMs` (`IntentLogStore.swift:27-51`). The utterance is
  resolved to a `Capture` and dropped; the transcript the correction protocol holds
  (`PendingCallAction.sourceTranscript`) is **in-memory only**.
- **No raw audio.** The app does not record it.
- **No health values, no message bodies, no calendar titles** (the last by explicit decision, above).
- **No contact identifiers** — the name string is stored, not a contact id or phone number.
- **No location.**

So the collection today is: *who was called and how, what the elder decided about it, how sure the
interpreter was, how long the elder took to decide, and when*. That is what the consent copy and the
privacy policy must describe — and it is what the egress rulings in §2 and §3 are about.

---

## 2. Field-by-field egress audit

### 2.1 The four classifications used below

| Class | Meaning |
|---|---|
| **never-leaves** | No loop path may carry it, in any form, hashed or not. It may still leave the device on the pre-existing, user-initiated family-export channel — that channel is disclosed separately (§8) and is not a loop path. |
| **hashed-only** | May leave on the loop path, and only as a **keyed digest under the per-install salt**, a **closed-vocabulary identifier**, or a **bucket/counter**. Never raw, never free-text. "hashed-only" is the design's shorthand for the whole D-2 payload; each row below names which of the three value classes the field must use. |
| **leaves-encrypted** | May leave the device only inside the project's end-to-end envelope (the double-ratchet broker posture, `docs/remote-config-channel-design.md:53-80`). **No field today is in this class**; it is reserved for any future payload above hashed-only, and its existence is why C-3 exists. |
| **local-only** | Persists on the device under device protection, and is not eligible for egress on any path — not even hashed — because its value space cannot be constrained by a schema. |

### 2.2 The audit — every field the widened `Record` can carry

| # | Field | Carried today? | Classification | Ruling, and the condition that makes it checkable |
|---|---|---|---|---|
| 1 | **transcript / utterance surface** | **No** — no field, no writer (§1.3) | **never-leaves** | Stays absent from both the record and the payload. Any T-054 proposal that puts an utterance surface in the **egress payload** is refused. If T-054 adopts T-052 §4's `surfaceRef`, it must be an **opaque on-device handle resolved at MINE time** (`T-052-notes.md` §4) and must never egress — T-059 checks that no egress field is named `surface*` or carries a resolvable reference. |
| 2 | `id` (UUID) | Yes — every record | **local-only** | **Never egresses**, not even hashed: it is a *stable per-record identifier*, so any digest of it is a join key across corpus revisions. If a per-record dedup handle is genuinely needed, it is `HMAC(salt, id)` truncated to 16 hex — minted at egress time, never stored back, never equal to a digest of the raw UUID without the key. |
| 3 | `timestamp` (`Date`) | Yes — set at write | **local-only** at full precision; **hashed-only (bucket)** if egressed | Egress is permitted **only** as a calendar day with **no timezone** — a day-granular bucket, not a truncated timestamp. `JSONEncoder`'s default date strategy writes a full-precision number, so "serialise the record and post it" leaks seconds; this is the mistake the rule exists to stop. A weekly loop cannot use finer resolution and must not carry it. |
| 4 | `path` | Yes — observed values `"model"`, `"override"` | **hashed-only (closed-vocabulary id)** — *conditionally* | The documented vocabulary (`local / cloud / keyword / cache / override`, `IntentLogStore.swift:31`) still does **not** contain `"model"`, which is what both non-override writers send. Ruling: a payload field sourced from `path` may egress **only if T-054 enumerates the observed set in the payload schema**; today that set is two values and carries no content. T-059 checks the schema lists every value the writer can send, and that the docstring mismatch is fixed or the field is dropped. |
| 5 | `action` | Yes — `call`, `create_calendar_event` | **hashed-only (closed-vocabulary id)** | Permitted. Must be a member of the encoder's schema-v2 action enumeration, not "the observed strings at the time". |
| 6 | `slots` | Yes — `{contact: <name>, method: <enum raw>}` on the call paths; nil on the calendar paths | **never-leaves** | The map is typed `[String: String]?`, so the type **cannot** enforce a value space: the same field holds a person's name and an enum raw value. Nothing sourced from `slots` may egress — not the values, not a hash of the values (a hash of a contact name from a family-sized candidate set is a confirmable oracle, §4/T4). If the miner needs to know *which* slots were resolved, T-054 may carry the **slot key names** (`contact`, `method`) as a closed, enumerated vocabulary — never the values. |
| 7 | `outcome` | Yes — `confirmed`, `denied`, `corrected`, `timeout` | **hashed-only (closed-vocabulary id)** | Permitted, and encouraged: this is the field the mining signals key on. Enumeration is already exact (`IntentLogStore.Verdict`, `IntentLogStore.swift:196-207`). |
| 8 | `correctedTo` | Yes — `{method: <enum raw>}` on the override path | **never-leaves** — the map; **hashed-only** — the *kind* | See F-5. The map itself is a value map and may never egress, whatever it holds today. What may egress is a **`correction_kind`** closed-vocabulary id (`method` today; more if T-054 enumerates them), derived from the map's **keys**, never its values. T-059 checks: no egress field is a map, and no egressed value equals a `correctedTo` value. |
| 9 | `confidence` (`Double?`) | Yes — the raw float, for interpreted confirm-tier commands | **local-only** raw; **hashed-only (bucket)** bucketed | New since rev 1. The raw float is a model artifact with unbounded resolution and must never egress. The bucket may, at the router's own three bands (`lt_0_4`, `0_4_0_7`, `ge_0_7` — the accept ≥ 0.7 / rephrase 0.4–0.7 policy, `IntentRouter.swift:49-58`), because that is a restatement of a decision already made, not a new measurement. |
| 10 | `latencyMs` (`Int?`) | **Now yes** — question → verdict, whole ms | **local-only** raw; **hashed-only (bucket)** bucketed | Re-decided from rev 1 (F-7). The raw integer is a fine-grained behavioural measure of a specific elderly person's reaction time; it never egresses. A coarse bucket may — bands of **at least 5 seconds' width**, edges fixed by T-054 — and **only** where it is not paired with a timestamp finer than a day, because "answered a call confirmation in 41 s on 12 March" is a behavioural fingerprint. |
| 11 | `register` / accent (not a `Record` field; a T-052 proposal) | No | **hashed-only (closed-vocabulary id)** — conditionally | If mined rows need the household's dialect label, the label may egress as the enumerated set the project has already fixed (`standard`, `eastern`, `doteli` — `specs/T-062-notes.md` D-1/D-6). It may **not** be joined with a device model, OS build, locale string or install pseudonym; a dialect + model + day tuple is a device fingerprint. |
| 12 | Transport/envelope metadata (payload version, install pseudonym) | Does not exist | **hashed-only** | A payload-version id may egress (it is the consent's scope, §3.6). An install pseudonym may exist on the receiver but must be a device-computed `HMAC(salt, install-constant)`, never a vendor identifier, advertising id, or device name. **No IP address, coarse location, or network metadata may be recorded with or alongside a payload** — C-3. |

### 2.3 The divergences this audit found in the *current shipped capture*

The task asks directly whether the shipped capture already diverges from the design's hashed-only
promise. It does — in both directions — and the verdict on each is stated rather than implied.

| Divergence | Is it an egress hazard? | Ruling |
|---|---|---|
| **`slots` carries contact names** (and did before `f2cbbab`) | **No, as long as the payload is whitelisted and never serialised from `Record`.** It is an accepted local feature: the store is training data for the family's own export, the file is under `NSFileProtectionComplete`, and the record never leaves except through the family's explicit action. It becomes a *severe* hazard the moment an implementer egresses `Record` wholesale — which is the natural implementation mistake, and the reason C-1 is worded as a prohibition, not a preference. | **Accepted local feature + condition C-1.** |
| **The export writes plaintext JSONL to tmp with no protection attribute, and nothing deletes the copy** | **Yes, it is an egress hazard — but it is not the loop's path, and the loop does not create it.** It is a pre-existing, user-initiated channel already recorded as a producer-side gap (`docs/superpowers/specs/2026-09-13-encoder-training-data-strategy.md` §7; `IntentLogStore.swift:149-164`). | **Recorded, not fixed here** (§4/T1, C-6): the loop must never write to or reuse this path, and the privacy policy must describe it truthfully (§8). Fixing the export container is a device-side follow-up outside T-053 — the conclusion the T-036 strategy doc already reached. |
| **The raw `confidence` float and the raw `latencyMs` integer are now on disk** (neither was stored before `f2cbbab`) | No — they are local-only, under device protection. They are *more* than the loop needs, which is exactly why the payload may carry only their buckets. | **Accepted local feature + condition C-1** (bucket-only on egress). |
| **A second action and three more verdicts are now recorded**, so the on-device collection is wider than the design assumed | No. Wider *storage* on a protected local file is not egress. But it **does** change what the consent copy must say and what the policy must describe. | **Condition C-5** — the copy in §7 is the widened copy; rev 1's is superseded. |
| **The calendar-event capture deliberately carries no `slots`** (title is user content with no reviewed capture policy) | No — it is the capture layer *declining* to collect content, which is what this determination would have required anyway. | **Blessed, and cited as the precedent** T-054/T-056 should follow for any new action. |
| **The docstring still says the log "leaves only via the family's explicit export"** | Not yet — it is still literally true, because no loop exists. It becomes false the day the egress ships. | **Condition C-4**: T-056's DoD already includes amending it (design §4.1). This determination makes it a privacy condition, not just a documentation tidy-up: a source file that lies about its own data flow is how the *next* reviewer is misled. |

---

## 3. The egress contract — the rulings

The design's §5.1 rule is *"closed-vocabulary identifiers, buckets, counters, salted hashes"*. **The
rule is blessed, and narrowed by the five rulings below.** Each is binary or numeric.

### 3.1 Per-category ruling

| Category | Examples | Ruling |
|---|---|---|
| Raw audio | STT input buffers | **Never.** The app does not record it; keep it that way |
| Raw transcript | the sanitised utterance text | **Never, on any loop path.** Unconditional |
| Slot values | contact names, medication names, message bodies | **Never.** `slots` and `correctedTo` are the fields that carry them (§2.2 rows 6, 8) |
| Profile / health | thresholds, readings, schedules | **Never** |
| Closed-vocabulary identifiers | `action`, `outcome`, `path`, correction kind | **Yes**, each a member of a declared enumeration (row 4's condition applies to `path`) |
| Buckets and counters | confidence bucket, latency bucket, counts | **Yes**, at the resolution limits in §2.2 rows 9–10 |
| Hashes | per-record identity, install pseudonym | **Yes**, keyed and salted — §3.4 |
| Telemetry | divergence counts/rates, error codes | **Yes**, through `LogSanitiser`'s allow-list only — §3.7 |

### 3.2 No free-text field, and the schema is enumerated and versioned

- **Every string field in the payload must be a member of a declared enumeration listed in the
  payload schema.** A field whose value space is "a string" is **forbidden**, even if it only ever
  carries an enum value today. The reason is not theoretical: the sanitiser's scrub patterns
  (`LogSanitiser.swift:82-92`) are phone / e-mail / blood-pressure shapes and **would not catch a
  Nepali personal name**, so "any string" is a PII hole the current defence-in-depth does not cover.
- **No egress field may be a map of any kind.** This is the `correctedTo` rule generalised: a map's
  value space is unbounded by construction, whatever it holds today.
- The payload schema is a **versioned artifact**, and **the schema's hash is recorded with the
  consent version** (§3.6), so "what did the user actually agree to" is answerable at audit time
  without trusting a code comment. Use a short prefix (`<sha8>`-style) in any human-readable
  artifact; a full digest must not appear in a document (T-035's convention, and the security-test
  false-positive the task brief names).

### 3.3 Timestamps are day-granular and timezone-free

- **No timestamp finer than a calendar day may egress; no timezone may egress.** A precise timestamp
  is a linkage vector against everything else on the device, and a weekly loop cannot use finer
  resolution. Day granularity is the maximum — §4/T5 walks the attack.
- **`Record.id` must never egress** (row 2). Called out here as well as in the table because
  "serialise the Record and post it" is the natural implementation mistake.

### 3.4 The hash ruling — salt **required**, keyed, rotating on events only

- **Per-install salt: REQUIRED** (not optional, not forbidden). A 256-bit key generated on-device at
  opt-in time, stored in the Keychain with a **this-device-only, unlocked-this-device** accessibility
  class, never synced, never in an iCloud or encrypted-iTunes backup.
- **Mechanism: HMAC-SHA256 keyed by the per-install salt**, not a bare `SHA256(salt ‖ value)`. A bare
  salted hash is weakened the moment the salt is read; a keyed MAC keeps the key out of the egressed
  value entirely.
- **Egressed digest length: a 16-hex-character prefix (64 bits).** Ample for within-revision dedup,
  strictly less identifying than the full digest, and it keeps the project's existing "no full
  hash in an artifact" discipline visible at the wire.
- **Unsalted hashes are NOT acceptable.** The reasoning, made explicit as the task requires: this
  app's command space is small and predictable — the attested surface forms are the shipped seed
  taxonomy (`tools/train-intent/seeds/intents.yaml`) — and a family's contact names are drawn from a
  set discoverable by anyone who knows the family. An unsalted digest of a member of a small,
  guessable set is invertible by enumeration in seconds. **A hash is a pseudonym, not anonymity**
  (design §5.2, risk R-3) — the loop's claim is *hashed and salted*, never *anonymous*.
- **Rotation: event-driven, never calendar-driven.** Rotate on (a) opt-out and (b) any explicit
  "delete my data" action. **Scheduled rotation is not required and is discouraged** — it would
  silently break the cross-revision dedup the mining stage depends on while buying no protection that
  salt destruction does not already give.
- **Escrow: FORBIDDEN.** The salt is never escrowed, never uploaded, never placed in a syncable
  Keychain item, and never included in a backup that leaves the device. **The intended failure mode,
  stated as a property rather than an accident: if the salt is lost, every previously egressed digest
  becomes permanently unlinkable to the device that sent it.** That is what makes the opt-out copy in
  §7 truthful.
- **The low-entropy rule (narrowing).** Where a closed-vocabulary identifier exists for a signal, the
  payload **must** carry the identifier and **must not** carry a hash of the same surface. Hashes are
  for per-record identity and dedup only. T-059 can check this mechanically: *no payload field may
  pair a closed-vocabulary value with a digest of the surface that produced it.*

### 3.5 The one-line payload test

A field may egress if **and only if** all four hold: (1) it is in the versioned schema; (2) every value
it can take is a member of a declared enumeration, a bucket from a fixed band table, or an integer
counter; (3) it is not, and does not contain, a timestamp finer than a day, and carries no timezone;
(4) it is not derived from raw audio, a transcript, a slot value, a `correctedTo` value, or
profile/health data. **Any field failing one of the four does not egress, and the version does not
ship.**

### 3.6 The consent's scope is the payload definition, at a version

- **The user accepts a payload version**, and the accepted version is recorded alongside the consent.
- **Re-consent is REQUIRED** if a new version *adds a field*, *widens a field's value space* (a finer
  confidence or latency bucket, a finer time resolution, a new enumerand), or *changes a field's
  meaning toward content*. Egress under such a version is **refused until the user accepts it — fail
  closed, not fail open.**
- **Re-consent is NOT required** if a new version *removes* a field or *narrows* a value space.
- The one-line test T-059 applies: *does the new version's permitted value space contain any value
  the accepted version's did not?* If yes, re-consent.

### 3.7 Telemetry is a second, narrower boundary (binding on T-055)

Shadow scoring is not a new collection **only** while all of the following hold; break any one and it
becomes a new collection requiring its own consent:

1. **Both interpreter outputs are discarded.** Only a divergence *summary* may persist.
2. **Divergence telemetry rides the existing bus, and the bus is print-only** — so this telemetry is
   **diagnostic, not retained** ("the loop's telemetry goes through the bus; the loop's egress does
   not", design §5.3). If T-055 wants divergence retained across sessions it must be counters in a
   dedicated content-free store, and **the ruling forbids doing that by widening the bus**.
3. **New allow-listed keys must be declared in `LogSanitiser` (`LogSanitiser.swift:56`) and each
   must have a declared, bounded value space.** The allow-list is the boundary, and a key whose
   values are "any string" is a hole in it. Permitted keys and value spaces: `divergence_count`
   (integer ≥ 0), `divergence_rate_bucket` (a fixed band enumeration, **not** a float),
   `action_id` (the schema-v2 action set), `escalation_reason` (the existing
   `LocalBrainChain.EscalationReason` raw values).
4. **No shadow event may carry the transcript, either output, a slot value, or `Record.id`.**
5. **Shadow scoring stays off the reply path** (design §7.2, NFR-002's 4-second budget) — a
   safety-adjacent constraint, not a performance preference.

**Reuse what exists**: `EscalationReason` (`LocalBrainChain.swift:44-55`) is already a closed,
content-free vocabulary the cascade emits, and the `cascadeDecision` timing stage already measures
off the reply path. Building divergence telemetry on those two, rather than inventing a parallel
vocabulary, is how the "content-free" claim stays true.

### 3.8 The promotion rule's consent half (binding on T-058)

1. **The gate wires no deployment.** The rule can only **block**; publishing stays a human action
   through the existing artifact path. Automating the publish would change what the user's assistant
   does without a person deciding — a different act from the one the consent copy describes.
2. **A publish under a new payload version requires this review to have cleared that version**
   (§3.6's re-consent rule, applied to the promotion boundary). The published artifact records the
   payload version it was trained under; the owner's review is a recorded item.
3. **The fail-soft ladder is unchanged and is not a consent matter.** The loop may not gate it, and
   the promotion rule may not use it as a reason to publish earlier.

---

## 4. Threat walk

Five threats, each with the asset, the adversary, what they get **today** (shipped), what the loop
adds, the ruling, and the residual that remains after it.

### T1 — Household-member snooping on the export file

- **Asset:** the JSONL export — contact names, which app each call was placed through, which plans the
  elder declined, and (since `f2cbbab`) how long they took to answer.
- **Adversary:** a household member, a caregiver, or anyone the share sheet hands the file to
  (AirDrop, e-mail, a messaging app, a cloud drive); also anyone who picks up the unlocked phone and
  opens Settings → Assistant activity.
- **Today:** the export is **plaintext** in `tmp`, with **no protection attribute set** and no
  deletion after the share; and the review screen renders the same content on demand with no
  authentication in front of it, including an unauthenticated "clear" that destroys the audit trail.
- **What the loop adds:** nothing — the loop never touches this path.
- **Ruling:** the loop must **never** write to, reuse, or extend the export path (C-6). The export
  remains the family's explicit, user-initiated channel, disclosed as such alongside the loop's
  disclosure; it is not egress and is not consent-covered by the loop's opt-in. The residual —
  a family member reading or forwarding the file, or deleting it — is accepted local risk, bounded by
  device protection on the *store* (`.complete`), and is **not** worsened by the loop. The
  unauthenticated local "clear" is recorded as a local-integrity observation for the owner (FR-042's
  authenticated-administrator rule is about config edits, not this screen); it is not a condition of
  this verdict.
- **Residual after ruling:** local, family-scoped, unchanged by the loop. The one improvement named
  but not owned here: delete the tmp copy when the screen disappears and set a protection class on it.

### T2 — Lost or stolen device

- **Asset:** the on-device log (content-bearing), the per-install salt (once it exists).
- **Adversary:** a thief with the locked device; a thief with the passcode; a forensic image of a
  backup.
- **Today:** the store and its directory are `NSFileProtectionComplete` (`IntentLogStore.swift:105`,
  `:185`) — unreadable while locked. The **exported tmp copy is not** (no attribute set), so it is
  readable after the first unlock even while the device is locked again. There is no loop and no salt.
- **What the loop adds:** the salt — and therefore a new object worth stealing, and a new backup
  surface.
- **Ruling:** the salt lives in the Keychain, **this-device-only**, never synced, never in a backup
  (C-2). The ruling's justification is deliberately *not* "so a thief cannot invert the digests":
  a thief with the passcode has the log itself, which contains the raw names the digests would
  reveal. **The salt's protection is about the receiver, not the device** — it exists so that a
  server (or an attacker of the server) cannot dictionary-attack the payload, and so that an
  opt-out can end linkability arithmetically. A restored-onto-another-device backup must therefore
  yield no usable key and no linkability — which is exactly what a non-escrowed, non-synced,
  this-device-only Keychain item guarantees.
- **Residual after ruling:** a passcode-holding thief reads the same content they could read before
  the loop existed. The loop adds no marginal device-at-rest loss.

### T3 — Future transport compromise (the relay / broker)

- **Asset:** the egress payloads in transit and at the receiver; the metadata around them.
- **Adversary:** a compromised or curious relay operator; a network attacker; whoever operates the
  training endpoint.
- **Today:** there is no loop transport. The project's only designed transport is the double-ratchet
  broker (`docs/remote-config-channel-design.md:32-40`, `:53-60`, `:64-80`), whose **stated metadata
  leak is timing, envelope size, sender ↔ recipient pairing, and device tokens** — accepted there
  because the broker cannot read the payload.
- **What the loop adds:** a second, periodic upload from the device to somewhere.
- **Ruling (C-3), and it is the sharpest condition in this document:**
  1. **A TLS-only receiver may be used for the hashed/bucketed payload and nothing else.** It is
     permitted *only because* D-2's content is hashed and bucketed — the receiver sees pseudonyms,
     enums and counters. **Any future version that carries anything above hashed-only must ride the
     E2E envelope** (the `leaves-encrypted` class), never a TLS-terminated endpoint. This is the
     line that must not be crossed later.
  2. **Metadata discipline:** uploads are **batched at the loop's fixed cadence** (weekly) and
     **size-stable** (padded or fixed-size envelopes), so envelope size and timing do not correlate
     with what happened in the household that week — the same leak the broker design already accepts
     for config, applied to a channel whose *size* would otherwise encode "this elder corrected the
     assistant four times".
  3. **The receiver must not record IP addresses, user agents, or connection metadata** with a
     payload, and must not join loop payloads with any other data source (C-3; T-059 checks).
  4. **The broker's existing rules carry over if the broker is reused**: no payload and no `convId`
     in logs (`docs/remote-config-channel-design.md:76-78`), TLS 1.2+ (NFR-011).
- **Residual after ruling:** the endpoint still knows *that* this device uploaded, and the pairing
  graph if the broker is reused. Accepted, and stated — not claimed away.

### T4 — Low-entropy hash inversion (names, medications)

- **Asset:** any egressed digest; any egressed value that is a hash or a function of a small,
  guessable set.
- **Adversary:** anyone who holds the egressed records — including the training side, a future
  analyst, or an attacker of the receiver — with a candidate dictionary.
- **Today:** nothing egresses, so nothing to invert. The risk is entirely prospective.
- **What the loop adds:** per-record pseudonyms, and (if implemented naively) digests of surfaces.
- **Ruling:** the §3.4 salt requirements are **required**, and three narrowings apply:
  1. **Never hash content.** No payload field may be a digest of an utterance, a contact name, a
     medication name, or a message body. If the value cannot be enumerated, it does not egress at
     all — hashing it creates a *confirmable oracle* rather than removing the risk. This is what the
     low-entropy rule in §3.4 means in practice.
  2. **Medication names are a named, permanent exclusion.** They are not captured today (§1.2 —
     the medication challenge is deliberately not recorded, and no writer stores a med name). The
     ruling pre-empts the obvious future extension: a medication-name field must never be added to
     the egress payload, hashed or not, because the household's medication list is a small,
     guessable set and a digest of it is the single most damaging value this channel could leak.
  3. **Contact names are the same exclusion** — they are in `slots` (local-only), and §2.2 row 6
     forbids them and their digests from egress.
- **Residual after ruling:** the *attested surface forms of the app's own command vocabulary* remain
  a small set, so per-record pseudonyms of surfaces would still be weak — which is why rule 1 forbids
  them outright rather than relying on the salt. With the salt, escrow forbidden, and no content
  hashes, the residual is bounded to "an observer can tell two egressed records came from the same
  install" (T5).

### T5 — Re-identification from timestamp + action patterns

- **Asset:** the payload's non-content fields in combination: day, action, outcome, bucket, latency
  bucket, dialect label, install pseudonym.
- **Adversary:** anyone holding a corpus of loop payloads, correlating with any other dataset or with
  knowledge of the household.
- **Today:** nothing egresses. On-device, the full pattern is visible to whoever holds the phone and
  the family review screen.
- **What the loop adds:** a periodic, structured behavioural record of one elderly person — when they
  placed calls, which plans they refused, how long they took to answer.
- **Ruling:**
  1. **Day granularity maximum, no timezone** (§3.3) — the resolution that makes "which day" usable
     for retraining and "what time" unavailable.
  2. **No stable install pseudonym is required for the mining, and none may be added without a
     stated purpose.** Records within one install are already joinable by their salt-derived
     pseudonyms; if cross-record grouping is needed, the group key must be over the **enumerated**
     field (`HMAC(salt, action)`, `HMAC(salt, correction_kind)`), **never over `Record.id`** — a
     per-record key turns the payload into a longitudinal diary.
  3. **Latency and confidence egress only as coarse buckets, never paired with a sub-day timestamp**
     (§2.2 rows 9–10) — this is the field most likely to make a pattern identifying, because
     reaction time is the closest thing in the payload to a biometric.
  4. **The receiver must not retain per-record payloads beyond the retention window** (§6) and must
     not join them with anything else (T3's rule 3).
  5. **Aggregation truthfulness:** no claim of anonymity is made anywhere in the copy, the code, or
     the policy. The claim is *hashed and salted*; the copy in §7 is written to exactly that limit.
- **Residual after ruling:** a small household's weekly payload is a low-resolution behavioural
  sketch. That residual is **accepted by this determination, and recorded as the loop's permanent
  privacy cost** — it is the reason C-8's audit and the owner's review date exist, and the reason the
  design's no-egress fallback (D) is kept as a real floor rather than a gesture.

---

## 5. Consent mechanics — D-1 versus what exists today

### 5.1 What D-1 requires

*"The loop exists only for a household that has explicitly turned it on. Nothing is captured, mined
or egressed for a household that has not… The loop's default state is OFF and the consent is
revocable; the opt-out path must delete what has not yet been egressed and stop future egress."*
(design D-1, §2)

### 5.2 What exists today

**Nothing.** Read at this revision:

| D-1 requirement | Shipped state |
|---|---|
| Default OFF | **There is no switch, no consent record, no opt-in surface — and no egress.** The log is written unconditionally on every confirm-tier verdict; the loop does not exist, so there is nothing to be off. |
| Explicit consent | No consent object, key, or settings row for the loop. The only consent-shaped thing in the app is the voice-engine **selection screen**, which is a radio row that switches immediately (`SettingsView.swift:1185-1190`) with an explanatory caption above it (`settings.voiceEngine.explanation`) — **a disclosure, not a consent step.** That is the OD-12 precedent as shipped, and it is weaker than OD-12's own words. |
| Revocation deletes un-egressed data | The family can clear the local log (`IntentLogReviewView.swift:86-92`, `removeAll`), which is a data control but **not** a loop opt-out: it is not scoped to the loop, it is not accompanied by any statement about egress, and it does not destroy a salt because there is no salt. |
| Visible indicator while active | None for the loop. |
| A way back without losing functionality | Trivially satisfied (nothing is on), and must stay satisfied (§11 C-4). |

### 5.3 The two mechanics questions this raises, ruled

**(a) Does D-1's "nothing is captured" require the always-on local log to become opt-in?**
**Ruling: no — and the loop must not be built as if it did.** The local log is a pre-existing,
separately-purposeful feature (the family review screen and the family's explicit export), on a
device-protected file, which leaves the device only when the family chooses to export it. It is not a
loop collection, and the loop does not make it worse. What D-1 governs is the **loop's** collection:
mined derived signals and egress. Therefore:

- **No loop-only field may be written before the opt-in is on.** If T-054 adds fields whose only
  consumer is the loop (a summary, a hash handle, a bucket for egress), **those fields are written
  only when the opt-in is on** (C-7). The existing record fields keep their current always-on
  behaviour, unchanged — the loop may not silently widen the always-on collection.
- **The copy in §7 is loop-scoped and says so.** It must not read as though it governs the family
  review screen.

**(b) Is an un-consented always-on content-bearing local log acceptable at all?**
This is the elder's own standing — the person whose contact names and decisions are recorded is not
necessarily the person who set the device up — and it **pre-dates this loop by many months**. It is
not created by the loop, and the loop's privacy review cannot resolve it. **Escalated to the project
owner** (§10, escalation 3) with a recommendation: keep the log (it is the product's only correction
signal, it is family-facing, and it is deletable), but disclose it in the policy in the elder's own
language (§8) — which the current policy does not do.

### 5.4 What the consent mechanics must be, concretely (binding on T-056)

1. **A settings row, default OFF**, under the existing Settings chrome, whose ON requires an explicit
   confirmation (consent string in §7) — **not** an immediate toggle in the voice-engine style, and
   **not** styled as a passive caption.
2. **The consent records the payload version** (§3.6) and the time it was accepted.
3. **Disclosure at the point of selection**: the explanation string is on the same card and visible
   *before* the switch can be turned on.
4. **A visible indicator while active**, readable in the user's language, and — this is the part the
   OD-12 precedent does not do — **also visible on the family review surface**, because the family is
   the party who reviews the data. A switch that is on but invisible where the data is reviewed is
   **not** compliance with this ruling.
5. **Opt-out**: stops future egress, deletes every not-yet-egressed derived signal, **destroys the
   salt**, and leaves the assistant fully functional. Nothing loops back: with the salt gone, the
   install pseudonym cannot be recomputed, so future egress cannot be linked to past egress.
6. **Fail closed on an unaccepted payload version** (§3.6): egress refuses, and the app says so
   honestly rather than shipping a narrower payload silently.

---

## 6. Retention (resolves OQ-3)

`IntentLogStore`'s 500-record cap is a **size** bound, not a time bound (`IntentLogStore.swift:90`),
and the egress side has no bound at all. Ruling: **both sides get a time bound, with a named deleter.**

| Side | Retention | Deleter | Trigger |
|---|---|---|---|
| **On-device captured signals** | **90 days from capture, or the 500-record cap, whichever bites first** | The capture layer (T-056), automatically | The time bound is applied as a **filter at egress time**, so a record older than 90 days can never be sent even if it is still on disk |
| **Egressed records** | **180 days from receipt, or 30 days after the corpus revision they fed is superseded, whichever bites first** | A scheduled deletion job owned by the **project owner** (at the T-058/T-036 tooling boundary) | Supersession is observable from the corpus-revision binding (`eval_golden.py:505-537`) |

**Why 90 days on-device.** The measured window at plausible call volumes is 25–100 days
(`T-052-notes.md` §6), and the cadence is weekly. 90 days is ~12× the cadence — never the binding
constraint in normal operation — while still bounding a device that sits untouched with a stale
correction on it. The widened capture (`f2cbbab`) raises the arrival rate but leaves this conclusion
intact: at any plausible rate the 500 cap or the 90-day filter bites first, and the filter is the
privacy-relevant one. A bound that never triggers in normal operation and always triggers in the
pathological case is what a retention policy is for.

**Why 180 days egressed.** The window must outlive at least one full retrain-plus-promotion cycle
including a gate failure or two (weekly cadence) and one governance review (the constitution's own
re-review cadence is 30 days). 180 days puts at least one review inside every retention window, so no
egressed record is deleted between reviews without a human having had the chance to look at it.

**Who can delete what, and by when:**

- **The family / device owner** deletes everything on-device instantly and without asking anyone:
  the review screen's clear already does this for the log (`IntentLogReviewView.swift:86-92`), and
  opt-out does it for the capture layer.
- **The project owner (Anjan Poudel)** owns deletion of egressed records and owns the job that
  performs it. **A deletion job that has not run is a review-time finding, not a silent omission** —
  recorded so T-059 has something to check.

**Opt-out semantics — the honest split, which the consent copy must state:**

- **Deleted immediately, irreversibly, on opt-out:** every on-device derived signal not yet egressed,
  **plus the salt.**
- **Retained:** records already egressed, under the 180-day window, with **no further egress**.
- **Why the copy may say "can no longer be linked to anything you say from now on", and may not say
  more:** salt destruction makes future linkage arithmetically impossible, and that is a guarantee.
  It does **not** guarantee that an already-egressed record is un-re-identifiable in absolute terms —
  §4/T4 and §4/T5 are what bound that, and they are bounds, not proofs. The copy is written to the
  guarantee and not one word past it.

---

## 7. The consent copy (deliverable, not suggestion)

**Localisation convention, so nothing is hard-coded (NFR-023/NFR-024).** All strings live in
`ios/ElderlyAssistant/Resources/Localizable.xcstrings` under the **`settings.learningLoop.*`** prefix,
with **both** an `en` and a `ne` localization, exactly as `settings.privacy.*` and
`settings.voiceEngine.*` do today. Non-View code resolves them through
`L10n.str(key, locale:)` / `L10n.fmt(key, locale:, …)` (`ios/ElderlyAssistant/App/L10n.swift:18`,
`:53`); Views resolve the same keys through the environment locale (the literal-key `Text("…")` form
in `IntentLogReviewView.swift:27` is the ship-standard precedent). **No literal user-facing string
may appear in Swift.**

**Why these strings differ from rev 1's.** Rev 1's explanation described corrections, repeat-asks and
confidence. Since `f2cbbab` the collection also includes **denials and non-answers** and a second
action, so those strings under-described the collection — an NFR-032 accuracy failure. The set below
is the widened set and supersedes rev 1's.

### 7.1 The strings

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

**Three copy rulings, stated so they are not softened in implementation:**

1. **The copy says "6 months", not "180 days".** Months are the unit the reader lives in; the
   retention *rule* is 180 days (§6) and the two must not drift — a change to the rule changes this
   string.
2. **The copy never uses a word the reader would not use.** No "anonymised", no "aggregate", no
   "telemetry", no "hash". "Scrambled code" and "counts and codes" are the register of the existing
   shipped copy (`settings.privacy.body`), and staying in it is the point.
3. **The copy does not promise more than §6 delivers.** It says what is deleted now, what is kept,
   and the one thing salt destruction guarantees. It does not say the loop is anonymous, and it does
   not say the data cannot be used — it says it cannot be *linked to what you say from now on*.

### 7.2 The visible indicator

The settings card must state the state in words in both languages
(`settings.learningLoop.indicator` / `.indicatorOff`), **and the same state must be readable from the
screen the family already uses to review what the assistant recorded** (`IntentLogReviewView`). A
switch that is on but invisible on the review surface is **not** compliance with this ruling — the
family reviews the data, so the family sees the state.

---

## 8. NFR-032 — the privacy-policy amendment

**The shipped policy is already inaccurate (F-6), before the loop adds anything.** `settings.privacy.body`
states, in both languages, *"Nothing is sent to the cloud for AI processing"* — while the shipped
default engine stack is the cloud engine (`?? .gemini`, `AppCoordinator.swift:1987`, `:1997`), which
Open Decision 12 itself records (the OD-12 entry cites `:1612-1613`, which has drifted). NFR-032
requires the policy to describe what is transmitted accurately. **The loop does not get to add a
second inaccuracy on top of the first.** The amendment below delivers the loop's disclosure and fixes
the OD-12 gap in the same pass, as replacement text for `settings.privacy.body`.

**Proposed `settings.privacy.body` (replacement):**

- **English.** "Your voice, health information, contacts, and conversations stay on this phone. The
  assistant can work fully on this phone. If you choose the Gemini voice engine, what you say is sent
  to Google to be written down as text; you can switch to an on-device engine at any time in Settings
  and keep every feature. If you turn on 'Help improve the assistant', only counts, small codes, and
  one scrambled code for each sentence leave the phone — never your words. If your family exports the
  assistant activity log, that file leaves the phone with the names in it; only your family can start
  that export. Health data is only read from HealthKit with your permission. Family notifications are
  sent only when a configured alert fires."
- **Nepali.** "तपाईंको आवाज, स्वास्थ्य जानकारी, सम्पर्क र कुराकानी यही फोनमा रहन्छन्। सहायक यही फोनमै पूरै चल्न सक्छ। यदि तपाईं जेमिनी आवाज इन्जिन छान्नुहुन्छ भने, तपाईंले भन्नुभएको कुरा लेखाइको रूपमा परिणत गर्न Google मा पठाइन्छ; तपाईं जहिले पनि सेटिङमा गएर यन्त्रमै चल्ने इन्जिन छान्न सक्नुहुन्छ र सबै सुविधा यथावत् रहन्छ। यदि तपाईं 'सहायक सुधार्न मद्दत गर्नुहोस्' खोल्नुहुन्छ भने, गन्ती, साना कोड र हरेक वाक्यको एउटा अव्यवस्थित कोड मात्र फोनबाट बाहिर जान्छ — तपाईंका शब्द कदापि जाँदैनन्। यदि परिवारले 'सहायकको गतिविधि' को निर्यात गर्नुभयो भने, त्यो फाइलमा नामहरू सहित फोनबाट बाहिर जान्छ — त्यो निर्यात परिवारले मात्र सुरु गर्न सक्छ। स्वास्थ्य जानकारी तपाईंको अनुमतिमा मात्र HealthKit बाट पढिन्छ। परिवारलाई सूचना तोकिएको अलर्ट सक्रिय भएमा मात्र पठाइन्छ।"

*(Implementation note: the Nepali sentence above is delivered as replacement copy and must be
rendered by the app's normal localisation path; any typographical correction belongs in the xcstrings
entry, not in the code.)*

**What this amendment does and does not claim.** It *does* name the cloud voice transit, as OD-12
already requires. It *does* name the loop's payload. It *does* name the family export as the one path
on which names leave — which the current policy does not, and which the T-1 threat makes concrete. It
does *not* claim the loop is anonymous, and it does *not* claim nothing is transmitted — the current
text's failure is exactly that it makes the second claim.

**Not in scope for this determination, flagged rather than silently skipped:** the export path writes
plaintext JSONL with no protection attribute and no post-share deletion (§2.3, §4/T1). An unencrypted
bundle handed to a family member is a third collection surface, and NFR-032's "how it is stored"
clause arguably reaches it. It is recorded here so it is not lost; fixing it is a device-side
follow-up outside T-053 — the conclusion the T-036 strategy doc already reached
(`…encoder-training-data-strategy.md` §7).

---

## 9. OQ-2 — the teacher-transit tension, ruled (this blocks T-057)

**The question.** `gen_teacher.py` uses a cloud teacher (Gemini 2.5 Flash Lite, `config.yaml:4-13`).
Feeding a *real user utterance* as a seed sends that text to the teacher. Does the family's export
consent cover that transit?

**RULING (AMENDED 2026-09-15): YES — owner decision.** The project owner (Anjan Poudel) has ruled
that the family's export consent DOES cover teacher transit. T-057 may feed mined rows to
`gen_teacher.py` under the standing conditions: the household's opt-in is active (D-1), only
whitelisted mined rows transit (never a whole-log serialisation, per C-1), and the teacher endpoint
is the TLS-only configured receiver (per C-3). The original reasoning below remains on the record as
the pre-decision analysis; the owner's ruling supersedes it.

The reasoning, from the recorded governance rather than from preference:

- The T-036 governance admits consented exports into the training batch "only for consented
  correction/gold sampling", and states the admission rules as *"no pipeline stage reads on-device log
  content except the exported bundle"* (`…encoder-training-data-strategy.md` §7). **"Admitted into the
  training batch" and "transmitted to a third-party AI service" are different acts.** The first is a
  statement about which stage may read the bundle; the second is a disclosure to a processor.
- The repository already records that this path is **not implemented and refuses loudly**:
  `"consent_export_ingestion": "not implemented (NFR-015); --consent-export refuses loudly"`
  (`tools/train-intent/src/run_encoder_pipeline.py:598-600`). That refusal is the current, honest
  state — no real user utterance has been admitted at all yet.
- NFR-015 forbids transmitting personal data to a cloud service **for AI processing**. A cloud teacher
  paraphrasing a real user utterance *is* AI processing of personal data. Reading the export consent
  as covering it would be exactly the misreading §5 rejects for OD-12's closed scope.
- The family's export consent, as it exists, is consent to hand a file over — not consent to a named
  third party receiving the text inside it. **A consent cannot be widened by inference.**

**What this blocks, and what it does not.** Blocked: feeding a **mined real utterance** to
`gen_teacher.py`. Not blocked: everything else. The hashed channel (D-2) is unaffected — it never
carried text. On-device mining is unaffected. Teacher expansion of the **synthetic** seed taxonomy
(`seeds/intents.yaml`) is unaffected: those rows are not user data and are what the pipeline does
today. And the design already requires the loop to be buildable both ways (design §4.3: *"The loop must
be buildable both ways: the hashed channel (D-2) is unaffected either way"*), so the fallback is the
design's own, not an invention of this review:

> **Carried forward for T-057: mined rows may enter the corpus as direct rows (validated,
> lower-trust, deduped, guard-checked as usual), and may not be sent to the teacher for rephrase
> expansion, until an explicit teacher-transit consent item exists and the user has accepted it.**

**This is escalated, not decided unilaterally, because the constitution's Open Decisions are
owner-decided** — see §10, escalation 2.

---

## 10. Open questions: resolved and escalated

| # | Item | Status |
|---|---|---|
| **OQ-1** | Own disclosure vs. amendment to OD-12 | **RESOLVED (§5).** Own disclosure and consent, built on OD-12's five obligations, recorded as its own Open Decision entry. **Escalated to Anjan Poudel to record the entry** (escalation 1) |
| **OQ-2** | Does the family's export consent cover teacher transit? | **RESOLVED (§9): YES — owner decision 2026-09-15.** T-057 may feed whitelisted mined rows to `gen_teacher.py` under C-1/C-3 and with the opt-in active (D-1) |
| **OQ-3** | Retention window | **RESOLVED (§6).** 90 days on-device (or the cap), 180 days egressed (or 30 days after revision supersession); deleters named; opt-out semantics fixed |
| **OQ-4** | What "the incumbent" is per configuration | **Not T-053's.** Explicitly left to T-058 with its implementation context; noted in §3.8 only for the human-publish half |

**Escalation 1 — record the second consent-gated path.** Owner: **Anjan Poudel (project owner)**.
Action: add an Open Decision entry to `constitution.md` recording the loop's opt-in hashed-signal path
with the five OD-12-shaped obligations (§5), citing OD-12's closed scope ("voice transcription (and
only that)", `constitution.md:128-132`) as the clause that makes a separate entry necessary, and note
in the OD-12 entry that the project now has two consent-gated, non-default paths whose disclosures are
separate. **Review by 2026-10-13**, aligned with OD-11, OD-12 and the post-deploy monitoring bullet
(`constitution.md:95`, `:121-126`, `:128-132`). Reason it is escalated rather than decided: the
constitution's Open Decisions are owner-decided (`constitution.md:99`), and a recorded exception is
the owner's act by construction.

**Escalation 2 — the teacher-transit consent decision.** Owner: **Anjan Poudel (project owner)**.
Action: decide whether to add an explicit consent item naming third-party teacher transit, or to keep
the loop teacher-free for real utterances permanently. **Until that decision, the §9 ruling holds and
T-057 must implement the teacher-free path.** Reason it is escalated: it decides whether real user text
may reach a named third party, which is a product-level consent decision, not an engineering one —
and it would apply to the whole T-036 export path, not only to the loop.

**Escalation 3 — the always-on local log's own consent standing.** Owner: **Anjan Poudel (project
owner)**. Action: record whether the always-on, content-bearing local activity log (contact names,
verdicts, latency) is accepted as a standing product feature for a user who did not consent to it
personally — the elder — with the family as the reviewing party. Recommendation attached (§5.3(b)):
**keep it, and disclose it plainly in the elder's language** via the §8 policy text, which today
does not mention it. **Review by 2026-10-13.** Reason it is escalated: it pre-dates this loop by
months, it is not created or worsened by the loop, and it is a product-consent decision the
constitution's Open Decisions reserve to the owner — but a privacy review that found it and said
nothing would be worthless.

**Review cadence for this determination itself.** Owner: **Anjan Poudel. Review by 2026-10-13**,
folded into the existing cadence (OD-11, OD-12, post-deploy monitoring) rather than inventing a
parallel one. The determination is re-reviewed **and its rulings re-checked against the shipped
payload** at each review; a payload version change (§3.6) triggers a review ahead of the date rather
than waiting for it.

---

## 11. Conditions — the verdict, mapped to tasks

**GO-WITH-CONDITIONS.** Nine conditions. Each is checkable by T-059, and each names the task that
owns it. Failing any one of them means the loop's egress is not covered by this determination.

| # | Condition | Owner | What T-059 checks |
|---|---|---|---|
| **C-1** | **The egress payload is built from an enumerated, versioned schema (§3.2, §3.5) — never by serialising `Record`.** No `id`, no `slots`, no `correctedTo` map, no raw `confidence`, no raw `latencyMs`, no timestamp finer than a day, no timezone, no map-typed field, no free-text field. The §2.2 table is the field list. | **T-054** | Field-by-field diff of the payload schema against §2.2; a grep-level check that no egress path references `Record` serialisation |
| **C-2** | **The hash and salt ruling (§3.4):** per-install 256-bit salt, Keychain this-device-only and non-synced, HMAC-SHA256, 16-hex digest, event-driven rotation only, escrow forbidden. Unsalted hashing is not acceptable. No field is a digest of content. | **T-054** | Keychain accessibility class; absence of escrow/sync/backup paths; digest length; the low-entropy rule (no closed-vocab id paired with a digest of its surface) |
| **C-3** | **Transport discipline (§4/T3):** TLS 1.2+ minimum; a TLS-only receiver is permitted **only** for hashed/bucketed payloads, and anything above hashed-only must ride the E2E envelope; fixed weekly cadence with size-stable uploads; the receiver records no IP/connection metadata and joins the payload with no other dataset | **T-054** | Transport config; envelope sizing; receiver-side logging policy; a written "what would break this" test for the E2E boundary |
| **C-4** | **The consent mechanics (§5.4):** default OFF; explicit confirmation (not an immediate toggle); disclosure before selection; consent records the **payload version**; fail-closed refusal on an unaccepted version; opt-out stops egress, deletes un-egressed signal, **destroys the salt**, and keeps every feature working; the indicator is visible in Settings **and** on the family review surface; the `IntentLogStore` docstring is amended (design §4.1) | **T-056** | The consent record's stored fields; the opt-out path's deletions (log + salt); the indicator's presence on both surfaces; the docstring |
| **C-5** | **The consent copy is the §7 set, in both languages, externalised (no hard-coded strings), and describes the widened collection** — including denials and non-answers | **T-056** | xcstrings keys present in `en` and `ne`; no literal user-facing string in Swift; the explanation string matches §7.1 |
| **C-6** | **The loop never writes to, reuses, or extends the family export path** (`exportURL()`, the tmp copy, the ShareLink). The export stays the only content path, and the policy names it truthfully (§8) | **T-054 / T-056** | No egress code path references `exportURL`; the policy string contains the export disclosure |
| **C-7** | **No loop-only field is written before opt-in.** The always-on local log keeps exactly the fields it has today; any field whose only consumer is the loop is written only with the opt-in on | **T-056** | The record's field set with the opt-in off vs. on; the append path's conditions |
| **C-8** | **Retention is enforced on both sides (§6):** ≥ 90 days on-device as an egress filter; 180 days egressed or 30 days post-supersession; the deletion job exists and has run | **T-056 / owner (job)** | The egress filter's date test; the deletion job's record; the review-time finding if it has not run |
| **C-9** | **T-057 may feed whitelisted mined rows to the teacher** (owner decision 2026-09-15, §9) — opt-in active, whitelisted rows only, TLS-only teacher endpoint | **T-057** | The miner's output path and its teacher invocation satisfy C-1/C-3 and D-1 |

**If the loop is descoped to on-device-only mining (the design's option D):** C-1, C-2, C-3, C-7 and
C-9 fall away, C-4's egress half falls away, and C-5 and C-6 survive unchanged (the copy still has to
be truthful about what is *not* sent, and the policy still has to name the export). That asymmetry is
the cheapest exit from this determination and should be evaluated against T-052's thin supply
argument before T-054 is executed.

---

## 12. Delta from rev 1 (so nothing is silently re-ruled)

| Rev 1 said | Rev 2 says | Why |
|---|---|---|
| "Exactly two writers exist, both for `action: call`" | Six writer paths across two actions, four verdicts, one shared mapping | `f2cbbab` widened the capture; §1.2 |
| Record shape: `id, timestamp, path, action, slots, outcome, correctedTo, latencyMs` | …plus `confidence: Double?` | `f2cbbab` |
| "The latency bucket may not appear in the payload until a writer populates it — a field that is always `null` is a null collector" | **Re-ruled: `latencyMs` is live; a coarse bucket (≥ 5 s bands) may egress; the raw value never may** | `Capture.record` now populates it (`IntentLogStore.swift:243-259`). Rev 1's *reason* was right and its *condition* is now met — the bucket is permitted, at a resolution limit |
| Copy described corrections, repeat-asks and confidence only | Copy names corrections, denials, non-answers, confidence | The collection widened; an under-described disclosure is an NFR-032 failure (§2.3, §7) |
| Policy amendment named the cloud-transit and the loop | Also names the family export as the path on which names leave | The field audit (§2.3) made it concrete; the policy must describe what is transmitted |
| No explicit verdict | **GO-WITH-CONDITIONS**, with C-1…C-9 mapped to tasks | The task brief requires a verdict |
| No threat walk, no field-by-field audit, no consent-mechanics section | §2, §4, §5 | The task brief requires them |
| §3.1's per-category table and §3.4's salt ruling | Retained, and now cited to this revision's line numbers | Re-verified, not carried |

Everything else in rev 1 — the OD-12 scope reasoning, the four-part payload test, the retention
windows, the escalation set, the PII discipline — is retained. Rev 1 is superseded by this document at
the moment this commit lands.

---

## 13. PII and secret discipline

- **No PII in this document.** No utterance, contact name, medication name, message body, health
  value, hostname or credential appears. The consent copy in §7 and the policy text in §8 are the only
  user-facing prose, and they contain no example data.
- **No full hash and no credential-shaped value.** The only hash-shaped thing named is an interface:
  "a 16-hex-character prefix of a keyed digest", described, never instantiated. Where a digest would
  be needed in prose, a short sentinel prefix is used, never a 40-character hex run.
- **Deliberately not asserted:** that salted hashing makes the payload anonymous (§3.4 says the
  opposite, and the copy is written to that limit); that the loop's accuracy benefit justifies the
  collection (T-052's measurement does not support a supply argument); that the export-encryption gap
  is fixed (it is not, §8); that the receiver's metadata leak is eliminated (it is ruled against and
  bounded — `residual` is stated per threat in §4).

## 14. Hand-off

| Task | What this determination gives it |
|---|---|
| **T-054** | §2's field-by-field audit as the payload's field list; §3.2–§3.6 (enumerated/versioned schema, no maps, no free text, day granularity, the four-part test, the consent-scope/re-consent rule); §3.4's salt ruling in full; §4/T3's transport discipline; C-1, C-2, C-3, C-6 |
| **T-055** | §3.7 in full: the not-a-new-collection conditions, the four permitted telemetry keys with their value spaces, the "do not widen the bus" ruling, and the reuse of `EscalationReason` / the cascade-decision timing stage |
| **T-056** | §5.4's consent mechanics; §7's exact strings and the localisation convention; §7.2's indicator ruling; §6's opt-out semantics and retention; §3.6's fail-closed behaviour; §8's policy text; C-4, C-5, C-6, C-7, C-8 |
| **T-057** | §9: **the owner-approved teacher-transit path** (opt-in active, whitelisted mined rows, TLS-only teacher) and the teacher-free fallback it must keep for households without the opt-in; C-9 |
| **T-058** | §3.8: no deployment wiring; the publish-under-a-new-payload-version review hook |
| **T-059** | Every ruling in §2–§6 as a checkable criterion, and the C-1…C-9 check table in §11 as its audit script: payload-version match against the recorded consent, the four-part field test, the no-`Record.id` and no-map rules, timestamp granularity, the salt's accessibility class and non-escrow, both retention clocks, the opt-out's two halves, the indicator on both surfaces, and the four telemetry keys' value spaces |
| **Owner (Anjan Poudel)** | Escalations 1–3 (§10), each with an action and the 2026-10-13 review date |
