# NFR-FCU-002: PII / log safety — names, nicknames, numbers, links and photos never reach logs

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution Safety & Compliance Delta ("PII / log discipline: names, numbers and photos must not reach logs beyond existing policy (B2/T-050 is the binding precedent); the release-build log-surface gate must cover the new write/fallback/resolution paths") and Feature Constraint 8; workflow `security-design-review` / `security-test` focus ("names/numbers/photos off the logs beyond B2/T-050; `check-release-log-safety.sh` coverage of the new paths"); project constitution Standards (logs must not contain PII — names, health values, contacts; log sanitiser required) and Release gates (release-build log-surface gate must pass; pre-release device console check).

## Description
No raw personal data from the new paths **must** reach any log, telemetry event or diagnostic surface beyond the existing transcript policy (B2/T-050 precedent). Measurable properties:

- **Zero occurrences**: in a Release build exercising the new paths — link creation/dedupe, photo write (success and failure), the app-local fallback, nickname matching in search and voice, ambiguity outcomes, unlink, and stale-link degradation — the console/log output contains **0** raw contact names, nicknames, phone numbers, system-contact identifiers/link values, photo data, or address-book contents.
- **Classification-only observability**: the new paths may emit non-content classifications (event kind, resolution outcome, write attempted/succeeded/fallback reason code) — never the name, number, nickname, identifier or image content. Errors (`CNSaveRequest` failures, lookup failures) log a reason code, never the payload or contact identity.
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of every test scope) **exits 0** and its rule coverage/RED-baseline includes the new write/fallback/resolution/dedupe source paths; the pre-release device console check covers the same paths.
- **No regression**: existing B1/B2 disciplines stay intact across the touched files (`FamilyContactStore`, `UnifiedContactSearch`, `ContactResolver`, `MissedCallContactResolver`, the new write seam, editor views).

## Acceptance criteria

```gherkin
Feature: Log safety for the contacts-unify paths

  Scenario: A Release exercise of the new paths logs no content
    Given a Release build
    When link/dedupe, a photo write, the fallback, nickname resolution and an ambiguity outcome are exercised
    Then no name, nickname, number, identifier or photo data appears in the console or logs
    And only non-content classifications are emitted

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's write/fallback/resolution paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And its coverage includes the new source paths

  Scenario: Error paths log no raw content (failure)
    Given a CNSaveRequest failure or a link-lookup failure
    When the error is handled
    Then only a reason classification is recorded
    And no contact name, number, nickname or identifier reaches the log
```

## Related
- FR: FR-FCU-006 (lookup failures), FR-FCU-008..010 (write/fallback paths), FR-FCU-012..014 (resolution paths), FR-FCU-005 (unlink)
- NFR: NFR-FCU-003 (no new egress), NFR-FCU-009 (release gates), NFR-FCU-007 (the log gate runs over the touched matching code)
