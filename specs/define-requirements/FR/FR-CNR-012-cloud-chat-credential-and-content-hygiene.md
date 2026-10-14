# FR-CNR-012: Cloud chat credential and content hygiene — header-only key, content off the logs

## Metadata
- **Area:** Cloud Chat Hygiene
- **Priority:** MUST
- **Source:** Feature constitution "Cloud-first chat routing toggle (P0)" property 4 ("the provider key travels in a header only — never in a URL, never in logs; conversation content must not reach logs beyond the existing transcript policy; the release-build log-surface gate (`ios/tools/check-release-log-safety.sh`) must cover the new routing/guard paths"); project constitution Open Decision 12 credential handling and the B2/T-050 binding precedent; project constitution Release gates (release-build log-surface gate; pre-release device check); workflow `security-design-review` / `security-test` focus.

## Description
The new cloud chat and grammar-guard paths **must** carry the same credential and content discipline the B2/T-050 remediation established (the binding precedent, not a new standard):

- **The provider key travels in a header only** — never in a URL, never in a query string, never in a log line, never in an error body.
- **Conversation content must not reach logs** beyond the existing transcript policy: the chat turn's text, the reply text, and the escalation's content are not logged by the new routing, consent or guard code. Errors on the cloud path record a reason classification, never the request payload or the response body.
- **The release-build log-surface gate covers the new paths**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of every test scope) exits 0 with the new chat/routing/guard source paths inside its coverage, and the pre-release device console/sysdiagnose check exercises those same paths.
- **Existing disciplines are not weakened** across the touched files (`GeminiClient`, `GeminiCommandInterpreter`, `LlamaCommandInterpreter`, `SpokenReplyPolisher`, `IntentRouter`, the new guard).

## Acceptance criteria

```gherkin
Feature: Credential and content hygiene on the new cloud chat paths

  Scenario: The provider key travels in a header
    Given a cloud chat request built by the feature
    When the request is inspected
    Then the key is present in a header only
    And no URL or query string contains it

  Scenario: A Release exercise of the new paths logs no content
    Given a Release build
    When a cloud chat turn, a guard flag and an escalation are exercised
    Then no conversation content, reply text or key material appears in the console or logs
    And only classification-level records are emitted

  Scenario: The log-safety gate covers the new paths and exits 0
    Given the feature's routing, consent, guard and escalation source paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And its rule coverage includes the new source paths

  Scenario: An error path leaks the payload (failure)
    Given a cloud chat failure or a guard escalation failure
    When the error is recorded
    Then only a reason classification is written
    And no request payload, response body, conversation text or key material reaches the log
```

## Related
- FR: FR-CNR-007 (telemetry), FR-CNR-008 (routing), FR-CNR-010 (egress scope), FR-CNR-025 (completion gate)
- NFR: NFR-CNR-006 (log safety, the measurable form), NFR-CNR-011 (release gates)
