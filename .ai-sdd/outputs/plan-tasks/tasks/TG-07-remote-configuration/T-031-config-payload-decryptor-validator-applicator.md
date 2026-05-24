# T-031: ConfigPayloadDecryptor + ConfigSchemaValidator + ConfigApplicator

## Metadata
- **Group:** [TG-07 — Remote Configuration](../index.md)
- **Component:** ConfigPayloadDecryptor, ConfigSchemaValidator, ConfigApplicator
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-030](T-030-signal-protocol-client-relay-websocket.md), [T-024](../TG-06-safety-critical-services/T-024-health-monitor-service/index.md), [T-028](../TG-06-safety-critical-services/T-028-medication-scheduler-family-notifier/index.md), [T-005](../TG-02-voice-interface/T-005-wake-word-detector/index.md)
- **Blocks:** —
- **Requirements:** FR-040, FR-041, FR-042

## Description

Implement `ConfigPayloadDecryptor`, `ConfigSchemaValidator`, and `ConfigApplicator` from L2 §7.2–7.3. Atomicity: all in-memory updates before storage write; rollback on storage failure. Hot-reload all live services without app restart.

## Acceptance criteria

```gherkin
Feature: ConfigPayloadDecryptor, ConfigSchemaValidator, and ConfigApplicator

  Scenario: Protocols match L2 §7.2–7.3 exactly
    Given the ConfigPayloadDecryptor, ConfigSchemaValidator, and ConfigApplicator implementations
    When their interfaces are compared to L2 §7.2–7.3
    Then all methods and properties match exactly

  Scenario: Config version downgrade is rejected
    Given the current AppConfig.config_version is N
    When a config payload with version lower than N is received
    Then the result is SchemaValidationFailed
    And no fields are applied

  Scenario: Unknown config field key is rejected and entire payload refused
    Given a config payload containing a field key not in the allowlist
    When the payload is validated
    Then the result is SchemaValidationFailed
    And the entire payload is rejected (no partial application)

  Scenario: Wrong-type config field value is rejected and entire payload refused
    Given a config payload containing a field value of incorrect type
    When the payload is validated
    Then the result is SchemaValidationFailed
    And the entire payload is rejected

  Scenario: Valid config hot-reloads all live services without app restart
    Given a valid config payload is received
    When ConfigApplicator.apply() is called
    Then HealthMonitorService.updateThresholds() is called with new thresholds
    And MedicationScheduler.loadSchedule() is called with new schedule
    And WakeWordDetector.reloadModel() is called if model path changed
    And AppConfig is updated in EncryptedLocalStorage
    And no app restart is required

  Scenario: Storage write failure causes in-memory rollback
    Given EncryptedLocalStorage.write() is mocked to fail during apply()
    When ConfigApplicator.apply() is called with a valid payload
    Then all in-memory service state is rolled back to the previous values
    And each live service retains its original config after the failure

  Scenario: Successful config apply triggers TTS confirmation
    Given a valid config payload is successfully applied
    When apply() completes
    Then TTS announces "Your settings have been updated"
```

## Implementation notes

- Atomicity and rollback test is a CI gate.
- Integration test (hot-reload of all services) required on CI.
- Standard peer review (one reviewer).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Atomicity/rollback CI gate passing
- [ ] Integration test (hot-reload of all services) passing on CI
- [ ] No PII in logs
