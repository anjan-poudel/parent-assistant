# T-012: `LabelTranslationCache`

## Metadata
- **Group:** [TG-04 — Dictionary Tier and Translation Cache](index.md)
- **Component:** C05 — `LabelTranslationCache`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md), [T-011](T-011-curated-dictionary-extension.md)
- **Blocks:** T-013, T-019, T-026
- **Requirements:** FR-LCT-007, FR-LCT-010, FR-LCT-012, FR-LCT-019, FR-LCT-020, NFR-LCT-002, NFR-LCT-008

## Description

One shared store, two layers, one name: a **dictionary layer answered by lookup** so a freshly
installed app resolves a known label with zero network and zero prior history, and a **persisted cloud
layer** written encrypted under a single storage key. The store self-heals on every failure, bounds
itself by LRU without ever evicting curated keys, and never surfaces an error to the elder.

Source: `Services/LiveTranslate/` `LabelTranslationCache.swift` using the shipped storage protocol and
`StoragePlacementPolicy` under `ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Two-layer translation cache

  Scenario: A curated label is a hit on a fresh install
    Given an app that has never translated anything
    When a curated label is resolved
    Then it is answered from the dictionary layer by lookup
    And nothing curated was written to disk (FR-LCT-019)

  Scenario: A repeated cloud translation is served from the persisted layer
    Given a cloud-resolved translation previously stored
    When the same key is resolved again, in this session or a later one
    Then the stored translation is returned with no cloud request
    And the hit is recorded with its origin token (FR-LCT-010)

  Scenario: The key is the normalized text plus the target language
    Given a recognized string
    When it is stored and looked up
    Then the key is the normalized text joined with the target language code
    And the normalization is identical to the stabiliser's, so a region maps to exactly one key

  Scenario: Nothing beyond the permitted fields is stored
    Given a populated cache payload
    When the stored bytes are inspected
    Then each entry holds only the key, the translation and the LRU bookkeeping timestamp
    And no image, bounding box, scene timestamp, device identifier or location is present (NFR-LCT-008 scenario 2)

  Scenario: The persisted payload is encrypted and reset-safe
    Given the storage channel the placement policy selects
    When the payload is written
    Then it is encrypted at rest with no plaintext copy and no temporary file
    And a payload that is unreadable or carries an unknown schema version is discarded and the store rebuilds from the dictionary layer, with nothing user-visible (NFR-LCT-008 scenario 3)

  Scenario: Eviction respects the curated set
    Given a persisted layer at its configured entry limit
    When a new entry must be written
    Then the least-recently-used non-curated entry is evicted
    And an entry whose key is curated is never chosen as a victim, regardless of the bound

  Scenario: LRU touching is coalesced
    Given the overlay resolving the same key repeatedly within a session
    When the key is served from the persisted layer
    Then the payload is written at most once for that key in the session
    And dictionary-layer hits touch nothing at all (NFR-LCT-002)

  Scenario: A write failure never breaks the feature
    Given a storage write that fails or is unavailable
    When the failure surfaces
    Then the translation is still rendered from the in-memory index, the failure is recorded, and no error is shown to the elder (FR-LCT-023)

  Scenario: Revocation does not clear the cache
    Given a populated cache and a consent revocation
    When the revocation completes
    Then the cached translations remain usable with no egress
    And only deleting the declared storage key removes the cache (FR-LCT-012 scenario 3)
```

## Implementation notes

- Single storage key `plugin.live_translate.cache.v1` holding the whole payload
  (`schemaVersion` + entries), because the shipped storage protocol has no key enumeration. Never call
  the file system directly and never invent a second location.
- Key = normalized text joined with the target language code, using the same normalization as T-009
  (trim, collapse whitespace, case-fold; no stemming, no synonyms).
- Persistence reads/writes under an `NSLock`-guarded in-memory index with writes coalesced on a serial
  queue (the shipped governor's pattern). One lock means one writer at a time; whole-payload writes
  mean no reader sees a partial payload. The live pipeline and the appliance helper are readers; only
  the tier-2 completion path (T-019) plus seed/LRU upkeep write.
- Eviction: `cacheGeneralEntryLimit` (200) bounds the persisted layer by LRU; curated keys are
  non-evicting **by policy** — the predicate asks the dictionary layer rather than inferring from size.
- Touch coalescing: `cacheTouchCoalescing` (T-001). The overlay renders at the OCR cadence, so
  rewriting the payload per frame would be a real thermal and battery cost.
- Failure behaviour is self-healing and never fatal: unreadable/corrupt/unknown-version payload ⇒
  discard + rebuild from the dictionary layer; write failure ⇒ render from memory, retry implicitly on
  the next resolution of the same key. No cache failure is ever surfaced to the elder.
- Emit `cache_hit`, `cache_miss`, `cache_evicted`, `cache_payload_reset`, `cache_write_failed` with
  `origin`, `count` and content-free codes only (T-003).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test inspects the on-disk bytes and asserts no plaintext translation is present
- [ ] A test asserts an unreadable or unknown-version payload resets to the dictionary layer and serves nothing stale
- [ ] A test asserts a curated key is never evicted at the bound
- [ ] A test asserts the touch coalescing bound holds over a long synthetic run
- [ ] No PII, no recognized text and no scene metadata in any event payload, asserted by test
- [ ] `ios/build.sh` passes
