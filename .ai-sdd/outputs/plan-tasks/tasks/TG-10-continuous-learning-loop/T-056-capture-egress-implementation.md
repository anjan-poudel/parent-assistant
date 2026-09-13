# T-056: Capture & Egress Implementation (opt-in)

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** `ios/ElderlyAssistant/Services/Intents/IntentLogStore.swift` (record extension and the §4.1 docstring amendment), a new opt-in egress uploader, the consent/opt-out UI surface and its externalised strings, `App/IntentLogReviewView.swift` (the family-facing control, if placed there), the two append sites `App/AppCoordinator.swift:4938-4944`, `:5076-5079`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-054](T-054-capture-schema-egress-contract-design.md) (schema and egress contract), [T-053](T-053-learning-loop-privacy-review.md) (consent copy, retention, salt ruling)
- **Blocks:** [T-057](T-057-correction-miner-implementation.md), [T-059](T-059-privacy-audit.md), [T-060](T-060-loop-end-to-end-fixture.md)
- **Requirements:** NFR-011, NFR-015, NFR-016, NFR-023, NFR-024
- **Origin:** TG-10 recorded decisions D-1 (opt-in) and D-2 (hashed-only egress); the T-054 contract; the T-053 determination

## Description

Build the on-device half of the loop behind an explicit opt-in: the capture record per [T-054](T-054-capture-schema-egress-contract-design.md), the consent control with [T-053](T-053-learning-loop-privacy-review.md)'s copy, and the hashed-only egress path. Nothing about the loop's *use* of what is captured belongs here — that is [T-057](T-057-correction-miner-implementation.md).

**The hard part is what must NOT happen.** Raw audio, raw transcript, slot values (contact names, medication names, message bodies) and health values never leave the device on this path (design §5.1, `…continuous-learning-loop-design.md`). The shipped `IntentLogStore` deliberately holds slot values — its own docstring says it is training data kept on-device under device protection (`IntentLogStore.swift:8-14`) — so the egress serialiser must be built from the *derived* fields, and the natural shape (encode the `Record` and post it) is the defect this task exists to prevent. T-059 audits exactly this, field by field.

**The docstring amendment is in scope.** `IntentLogStore`'s docstring states the log "leaves only via the family's explicit export" (`:11-14`). After this task, derived signals leave over the opt-in channel while content still leaves only via the export, so the sentence must be amended to say both truths ([T-054](T-054-capture-schema-egress-contract-design.md) specifies the wording; design §4.1 requires the amendment). Leaving it stale would make the shipped source misdescribe its own data flow.

**Opt-in means opt-in.** Default OFF; enabling requires the [T-053](T-053-learning-loop-privacy-review.md) disclosure; disabling stops future egress and deletes not-yet-egressed signal as the determination requires. An opt-out that flips a stored flag while an already-scheduled upload continues is the no-silent-stub failure mode — the same rule the constitution's Agent Principles apply to deferred work applies here to revocation. The visible indicator required while the loop is active (Open Decision 12's disclosure precedent, `constitution.md:130`) is part of this task.

**Transport.** The dedicated opt-in uploader from [T-054](T-054-capture-schema-egress-contract-design.md), TLS 1.2+ (NFR-011), timeouts and retries as configurable parameters (Agent Principles: "timeouts are configurable parameters, not hardcoded constants"), every failure mode with a defined user-visible or silent-by-design behaviour, and no failure path that discards signals without recording that it did (`EXIT_*`-style honesty, on the client side).

## Acceptance criteria

```gherkin
Feature: Capture and hashed-only egress behind explicit opt-in

  Scenario: Nothing content-bearing can reach the egress path
    Given the shipped IntentLogStore holds slot values by design (IntentLogStore.swift:8-14, :20-47)
    And the design's egress rule (closed-vocabulary ids, buckets, counters, salted hashes only)
    When the egress serialiser is implemented
    Then a test proves that a record containing a contact name, a medication name and a message body produces an egress payload containing none of the three, asserted on the serialised bytes rather than on the field list alone
    And the serialiser is constructed from derived fields, not from encoding IntentLogStore.Record wholesale

  Scenario: Capture is off until the user turns it on, and turning it off is honest
    Given recorded decision D-1 (default OFF, revocable) and the T-053 consent determination
    When the capture path is implemented
    Then no record is captured, no signal is queued and no upload is attempted while the consent is absent, proven by a test that drives the real consent state
    And revoking the consent stops future egress and deletes not-yet-egressed signal, and a test proves the deletion and the stop

  Scenario: The consent surface uses externalised copy in both supported languages
    Given NFR-023/NFR-024 (all UI strings externalised; Nepali primary, English secondary)
    And the exact consent/opt-in/opt-out/indicator strings delivered by T-053
    When the consent surface is implemented
    Then every string is resolved through the app's localisation mechanism, with no hard-coded user-facing text, and both locales are present
    And the visible indicator appears while the loop is active and disappears when it is off

  Scenario: The record extension decodes existing on-disk data
    Given the shipped record is decoded straight from JSONL (IntentLogStore.swift:131-137)
    And T-054's schema requires added fields to be optional or defaulted
    When the extension lands
    Then a fixture written in the shipped format still decodes after the change, and the appended record serialises with the new fields
    And the 500-cap trimming behaviour is unchanged unless T-054 explicitly changed it, in which case the change is covered by a test

  Scenario: Egress transport meets the security and failure requirements
    Given NFR-011 (TLS 1.2+) and the T-054 transport contract
    When the uploader is implemented
    Then the connection refuses anything below TLS 1.2, timeouts and retries are configurable parameters, and a failed upload is recorded as failed rather than silently dropped
    And no credential, endpoint secret or key material appears in a log, a URL or a test fixture (SENTINEL_ placeholders only in tests); T-050 is the precedent

  Scenario: The store's stated contract matches what the code does
    Given IntentLogStore's docstring claims the log "leaves only via the family's explicit export" (IntentLogStore.swift:11-14)
    When the capture and egress paths land
    Then the docstring is amended to state both channels: content via the family's explicit export, derived signals via the opt-in hashed path
    And the review screen's read-only contract is unchanged (IntentLogReviewView.swift:3-7) unless T-054 placed the control there, in which case the change is covered by tests
```

## Implementation notes

- Read first: `IntentLogStore.swift:3-17`, `:20-47`, `:49-56`, `:88-92`, `:100-123`, `:131-137`; `AppCoordinator.swift:4938-4944`, `:5076-5079`, `:1219` (`intentLogStore` declaration), `:7260-7278` (the bus, for the contrast); `IntentLogReviewView.swift:23-27`; `LogSanitiser.swift:56-70` (what an allow-list does and does not protect).
- Do not route egress through `ObservabilityBus`: the shipped implementation prints (`AppCoordinator.swift:7277`) and its contract is local diagnostics. The design's §5.3 records the rejection.
- Test discipline: the canonical iOS gate is `./ios/build.sh test:unit` (T-050's DoD cites it); keep it green. Do not add a test that prints transcript content — T-049's task exists because that mistake was made once already.
- The salt ([T-053](T-053-learning-loop-privacy-review.md)'s ruling, design §5.2) needs storage that survives app restarts and is not synced; where it lives is an implementation decision that must be recorded in the task notes, and its absence must fail the upload closed rather than degrade to an unsalted hash.
- Retention: if T-053 set a window, this task enforces it on-device (and the egress side is [T-057](T-057-correction-miner-implementation.md)'s ingest boundary). A window that exists only in the document is not enforcement.
- [T-059](T-059-privacy-audit.md) audits this implementation end to end; keep the evidence it will need (payload schema file, redaction test, consent-state test) discoverable rather than describing it in prose only.
- No PII or secret in any test fixture (NFR-016); use obvious sentinels such as `SENTINEL_CONTACT_NAME` and never a realistic key.

## Definition of done
- [ ] Capture record implemented per T-054, with pre-extension decode proven
- [ ] Egress serialiser built from derived fields; test asserts on serialised bytes that no slot value, transcript or health value can appear
- [ ] Opt-in consent surface with T-053's copy, externalised in Nepali and English; visible indicator while active
- [ ] Opt-out stops egress and deletes not-yet-egressed signal, both covered by tests
- [ ] Uploader meets NFR-011, with configurable timeouts/retries and honest failure recording; no credential in any log, URL or fixture
- [ ] `IntentLogStore` docstring amended to state both channels
- [ ] Retention window enforced if T-053 set one; salt stored per T-053's ruling, failing closed if unavailable
- [ ] `./ios/build.sh test:unit` green with no new failures; no transcript or secret in test output (T-049/T-050)
