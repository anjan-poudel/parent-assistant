# FR-CDP-008: `fellBackFrom` carries skipped channels in attempt order

## Metadata
- **Area:** Chain Resolution / Announcement Data
- **Priority:** MUST
- **Source:** Frozen design §3 (`Result` field: "Channels that were preferred but infeasible, in attempt order — empty when nothing fell back. Announcements compose from this."); feature constitution "In scope" bullet 3 ("with `fellBackFrom` carried in the result so announcements can name the actually-routed channel"); workflow `security-design-review` focus ("Announcement honesty: the spoken confirmation names the actually-routed channel (`fellBackFrom`); no silent route changes")); DV-2.

## Description
The chain's result **must** carry `fellBackFrom`: the channels that were attempted and found infeasible, in attempt order, so announcements and the spoken confirmation can name both the routed channel and what was skipped. Binding properties:

- **Empty when nothing fell back** — a feasible preferred channel produces an empty `fellBackFrom`.
- **Attempt order** — when the preferred channel is infeasible and the secondary is routed, `fellBackFrom` is `[preferred]`; when both are infeasible and `phone` is routed, it is `[preferred, secondary]` in that order.
- **The routed channel never appears** in `fellBackFrom`.
- **Dedupe is not duplicated** — an equal secondary skipped by dedupe is listed at most once.
- **Single source for copy** — the confirmation disclosure (FR-CDP-013), the routed-channel announcement (FR-CDP-016) and the launch-fail announcement (FR-CDP-015) **must** compose from this field, never from independently re-derived state, so the spoken line always matches the actual routing.

## Acceptance criteria

```gherkin
Feature: Fallback provenance in the result

  Scenario: A skipped preferred channel is reported in attempt order
    Given the preferred channel is infeasible
    And the secondary channel is feasible
    When the chain resolves
    Then fellBackFrom contains exactly the preferred channel
    And the routed channel is not present in fellBackFrom

  Scenario: Both skips are reported in order, deduplicated
    Given the preferred channel is infeasible
    And the secondary channel is infeasible
    When the chain resolves
    Then fellBackFrom contains the preferred channel and the secondary channel in attempt order
    And with an equal primary and fallback, the channel appears at most once
    And the routed channel is phone

  Scenario: Nothing fell back when the preferred channel is feasible
    Given the preferred channel is feasible
    When the chain resolves
    Then fellBackFrom is empty
```

## Related
- FR: FR-CDP-007 (the chain), FR-CDP-013 (confirmation composes from it), FR-CDP-015/016 (announcements compose from it)
- NFR: NFR-CDP-008 (matrix pins its content)
