# NFR-CNR-006: Log safety — no conversation content, transcript or key material in any log

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution "Cloud-first chat routing toggle (P0)" property 4 and Safety & Compliance Delta 5; project constitution Standards ("Logs must not contain PII (names, health values, contacts). Log sanitiser required") and Release gates ("**Release-build log-surface gate.** `ios/tools/check-release-log-safety.sh` must pass … It is a build-blocking gate, not a report"; "**Pre-release device check.** … confirm that no transcript content, key material, or raw upstream body appears in the device console or in a sysdiagnose capture"); B2/T-050 precedent; feature constitution "Success Criteria & Completion Gate" (release gate); workflow `security-test` focus.

## Description
No conversation content **must** reach any log surface beyond the existing transcript policy. Measurable properties:

- **Zero occurrences**: in a Release build exercising the new paths — local chat decode, the grammar guard (pass and flag), the escalation attempt, cloud chat routing (success, failure, timeout), consent/revocation handling, and the offline fallback — the console/log output contains **0** occurrences of conversation content: user utterance text, reply text, transcript text, system-persona diagnostics, prompt dumps, request/response bodies, or provider key material.
- **Classification-only observability**: the new paths may emit event kinds, outcomes, reason codes, counters, the failed-check class (FR-CNR-007) and routing decisions — never content. Error paths record a reason code, never the payload or upstream body.
- **Build-blocking release gate**: `ios/tools/check-release-log-safety.sh` **exits 0** and its rule coverage/RED-baseline includes the new chat/routing/guard source paths; because it is wired into `ios/build.sh` ahead of every test scope, no gate runs with a re-introduced raw print.
- **Device console check**: the pre-release check on a real device confirms the same for the new paths (console and sysdiagnose capture).
- **No regression** of the existing B1/B2 disciplines in any touched file.

## Acceptance criteria

```gherkin
Feature: Log safety across the chat, guard and routing paths

  Scenario: A Release exercise of the new paths logs no content
    Given a Release build
    When local chat, a guard flag, an escalation, a cloud chat success and failure, and an offline fallback are exercised
    Then no utterance text, reply text, transcript text, request/response body or key material appears in the console or logs
    And only classification-level records are emitted

  Scenario: The release log-surface gate covers the new paths and exits 0
    Given the feature's chat/routing/guard source paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And its coverage includes those paths

  Scenario: An error path leaks the payload (failure)
    Given a cloud chat failure, a guard failure or a router fallback
    When the error is recorded
    Then only a reason classification is written
    And no conversation content, transcript text or key material reaches any log
```

## Related
- FR: FR-CNR-012 (hygiene on the new paths), FR-CNR-007 (telemetry), FR-CNR-025 (pre-release/device check)
- NFR: NFR-CNR-007 (telemetry content hygiene), NFR-CNR-011 (release gates)
