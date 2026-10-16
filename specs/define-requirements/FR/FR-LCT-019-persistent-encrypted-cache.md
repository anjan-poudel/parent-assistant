# FR-LCT-019: Persistent encrypted translation cache

## Metadata
- **Area:** Caching
- **Priority:** MUST
- **Source:** Design §3, §5 (cache), §11 D3 (generalizes addendum §13.2's in-memory `LabelTranslationCache`); feature constitution binding rule 10

## Description
Translated strings **must** be cached persistently on-device, keyed
`(normalizedText|targetLanguage)`, so that a repeat scene needs no network. The cache is **user
content at rest**:

- stored **encrypted** using the existing `StoragePlacement` / encrypted-storage pattern;
- **seeded from the curated dictionary**, so the first use of a known label is already a hit;
- general (non-dictionary) entries evicted by **LRU with a bound of ~200 entries**; dictionary /
  label-vocabulary entries effectively never evict;
- never written in plaintext and never sent to the cloud as a cache (only individual unresolved
  strings go to the cloud tier, subject to consent).

A cache hit produces the translation with zero network calls and must be preserved across app
launches and across camera session interruptions.

## Acceptance criteria

```gherkin
Feature: Persistent encrypted translation cache

  Scenario: A cached translation survives a relaunch without network
    Given a string was translated in a previous session and is cached
    When the app is relaunched with no network and the same string is recognized
    Then the cached translation is shown
    And no network request is made

  Scenario: The cache is seeded from the dictionary
    Given a freshly installed app with no prior translation history
    When a dictionary-known label is recognized
    Then it is resolved from the seeded cache/dictionary with no network request

  Scenario: The cache is bounded by LRU eviction
    Given the cache holds its maximum number of general entries
    When a new general entry is inserted
    Then the least recently used general entry is evicted
    And dictionary/label entries are not evicted by that policy

  Scenario: The cache is not stored in plaintext
    Given a translation has been cached
    When the on-device storage is inspected
    Then the cached content is not readable as plaintext
```

## Related
- FR: FR-LCT-020 (shared cache), FR-LCT-012 (revocation keeps cache usable)
- NFR: NFR-LCT-008 (cache at rest encryption)
- Depends on: FR-LCT-007 (tier 0)
