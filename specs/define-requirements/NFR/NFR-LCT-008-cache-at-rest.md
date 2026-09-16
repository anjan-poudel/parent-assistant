# NFR-LCT-008: Cache at rest — encrypted, keyed, bounded

## Metadata
- **Category:** Security / Privacy
- **Priority:** MUST
- **Source:** Feature constitution binding rule 10; design §3, §5; workflow security-design-review focus ("persistent cache = user content at rest")

## Description
The persistent translation cache is user content and must be protected accordingly:

- **Encrypted at rest** using the app's existing `StoragePlacement` / encrypted-storage pattern
  (the same classes used for other user content); no plaintext cache file may exist on disk,
  including temporary files used during writes.
- **Keyed** `(normalizedText|targetLang)` so entries are addressable without storing scene context;
  no image, bounding box, timestamp of the scene, or location is stored alongside the translation.
- **Bounded and evictable**: the general-entry LRU bound (~200 entries) is enforced, so the cache
  cannot grow without limit; dictionary/label entries are effectively non-evicting by policy
  (a recorded policy choice, not an accident of size).
- **Deletable**: removing the feature's stored data (or the app) removes the cache; a corrupt cache
  must be discarded and rebuilt, never crash the feature.

## Acceptance criteria

```gherkin
Feature: Cache at rest

  Scenario: No plaintext cache on disk
    Given translations have been cached
    When the app container is inspected
    Then no file contains readable translation text

  Scenario: Stored entries carry no scene metadata
    Given a translation is cached
    When the stored entry is inspected
    Then it contains the normalized source text, the target language and the translation only
    And it contains no image, bounding box, scene timestamp or location

  Scenario: A corrupt cache is discarded, not fatal
    Given the cache payload is unreadable
    When the feature starts
    Then the cache is discarded and rebuilt from the dictionary
    And live translation still opens
```

## Related
- FR: FR-LCT-019 (persistent cache), FR-LCT-020 (shared store)
- NFR: NFR-LCT-005 (privacy)
