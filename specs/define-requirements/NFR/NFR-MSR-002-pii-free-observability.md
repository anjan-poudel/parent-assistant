# NFR-MSR-002: PII-free observability — hash-only medication identifiers, sanitised logs, gate-covered paths

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Project constitution Privacy standards (logs must not contain PII; log sanitiser required) and release gate (release-build log-surface gate); `docs/medication-scheduler-implementation-plan.md` observability contract (all events use the one-way entry identifier, no medication names); feature constitution "Feature Constraints" 1 and 5.

## Description
Every observability event and log line produced on the feature's new or touched paths **must** be PII-free. The one-way hashed entry identifier is the only medication-level identifier permitted; **no medication names, dose text, label text, photo content, or conversation content** may appear in any event, span or log line, and the log sanitiser applies to everything the new paths emit. The release-build log-surface gate must cover the new paths.

Measurable form: zero PII tokens in the new events by audit; the release log-surface check exits zero over the feature's paths.

## Acceptance criteria

```gherkin
Feature: Observability stays PII-free on all new medication paths

  Scenario: New events carry only the hashed identifier and metadata
    Given the new events (slot mapping resolved, scan completed, acknowledgement with slot, challenge outcome, photo evidence state, notification outcome, escalation started)
    When each event payload is inspected
    Then it carries the one-way entry hash and categorical metadata only
    And it carries no medication name, no free text, no image or transcript content

  Scenario: Raw content in a log line fails the gate (failure)
    Given a development build that prints a medication name, label text or photo content to the log
    When the release log-surface check runs
    Then it fails
    And the offending line must be removed before the gate can pass
```

## Related
- FR: FR-MSR-005 (scan events), FR-MSR-010 (recording), FR-MSR-016 (notification outcomes), FR-MSR-017 (wire discipline)
- NFR: NFR-MSR-009 (release gates)
