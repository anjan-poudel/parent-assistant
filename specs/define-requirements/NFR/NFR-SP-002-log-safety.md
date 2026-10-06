# NFR-SP-002: Log safety — no credentials, queries or provider bodies in logs

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 2 (credentials never in the repository or logs — header, never URL; the B2/T-050 release-log-gate precedent `ios/tools/check-release-log-safety.sh` is binding) and the amendment; workflow `security-design-review` focus ("Log sanitisation: music queries, provider responses and error bodies must not reach logs"); project constitution Standards (Privacy: logs must not contain PII; release gates)

## Description
No Spotify credential, token, authorization header, music query text or raw provider body **must** reach any log, telemetry event or diagnostic surface, in any build. Measurable properties:

- **Zero occurrences**: in a Release build exercising linking, unlinking, a successful music session, every failure path (timeout, non-200, malformed payload, revoked token) and the settings surface, the console and log output contain **0** credentials, tokens, client secrets, authorization header values, query strings or raw response/error bodies.
- **Header, never URL**: credentials travel in request headers; no credential appears in any URL, query parameter or deeplink — checked over the new code paths.
- **Sanitiser coverage**: the log sanitiser treats the new fields/values as sensitive; diagnostic call sites redact or omit them; observability events carry only non-content classifications ("provider: spotify; outcome: not_found") and never query text (mirroring `YouTubeTool`'s "observability events carry no query text" discipline).
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) covers the new Spotify plugin, tool, linking and settings paths and **exits 0** — a build-blocking gate, not a report. The pre-release device console check (project release gates) covers the same paths.

## Acceptance criteria

```gherkin
Feature: Log safety for the Spotify paths

  Scenario: A full linked session produces no sensitive output
    Given a Release build with a linked Spotify account
    When a music request, a fallback, a failure and an unlink are exercised
    Then no credential, token, authorization header, query text or provider body appears in the console or logs

  Scenario: A provider error body is never logged raw
    Given the provider returns an error body
    When the failure is handled
    Then only a non-content classification is recorded
    And no raw body or provider message reaches the log

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's logging paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new Spotify plugin, tool, linking and settings paths
```

## Related
- FR: FR-SP-007 (tool), FR-SP-008 (linking), FR-SP-009 (store), FR-SP-010 (unlink)
- NFR: NFR-SP-007 (encryption at rest), NFR-SP-011 (compliance gates)
