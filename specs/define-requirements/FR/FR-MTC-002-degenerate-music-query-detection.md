# FR-MTC-002: Degenerate music-query detection before playback

## Metadata
- **Area:** Music Path / Probe Trigger
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "In scope" (Phase 1: "degenerate-query detection in the music path"); feasibility study §2 ("the query is whatever survives token-stripping — or the marker itself"; `musicQuery(from:)` marker fallback, `KeywordIntentRule.swift:752-779`) and §6.2 (the probe trigger); worktree source verified: the never-empty marker fallback at `KeywordIntentRule.swift:765-775`, the ladder music arm at `CommandRouter.swift:1223-1234`, the interpreted `.music` path at `CommandRouter.swift:3336-3355`.

## Description
When a music command resolves and its search query is **degenerate**, the system **must not** execute the literal top-hit search blindly (today: `fireMusicRequest` → `runMusicTurn` → `SpotifyTool.fetchTopTrack` with whatever survives extraction). A degenerate query is: a bare music-marker word produced by the never-empty marker fallback (e.g. "play bhajans" → query `"bhajans"`, "भजन बजाऊ" → query `"भजन"`), or an extraction that canonicalizes to nothing (the raw-transcript fallback). Detection **must** run on both intake routes:

- the deterministic keyword-ladder music arm (`CommandRouter.swift:1223-1234`), and
- the interpreted `.music` action (`CommandRouter.swift:3336-3355`, the `interpretedQuery ?? musicQuery ?? raw` order).

A non-degenerate query (a specific artist/track/genre phrase present in the utterance) must keep today's behaviour exactly — no probe (NFR-MTC-012). Detection is deterministic and model-free (zero prompt tokens).

## Acceptance criteria

```gherkin
Feature: Degenerate music-query detection

  Scenario: A bare Nepali bhajan request is detected as degenerate and probes instead of searching
    Given the keyword ladder resolves the utterance "भजन बजाऊ" to the music domain
    And the extracted query is only the bare marker "भजन"
    When the music path evaluates the query
    Then no Spotify search is fired for the bare marker
    And the slot-fill probe is triggered (FR-MTC-003)

  Scenario: A specific music request passes straight through, unchanged
    Given the user says "दशैं दुर्गा भजन बजाऊ"
    When the music path extracts a specific query
    Then the query is not treated as degenerate
    And playback proceeds exactly as today with no probe

  Scenario: An empty extraction triggers the probe rather than searching the raw transcript
    Given a music command whose query canonicalizes to nothing
    When the music path evaluates the query
    Then no search is fired with the raw transcript as the query
    And the slot-fill probe is triggered
```

## Related
- FR: FR-MTC-003 (the slot-fill probe it triggers), FR-MTC-012 (barge-in interplay), FR-MTC-019 (the same mechanism later covers reminder/calendar slots)
- NFR: NFR-MTC-012 (no regression for specific queries), NFR-MTC-005 (detection is deterministic, brain-free)
