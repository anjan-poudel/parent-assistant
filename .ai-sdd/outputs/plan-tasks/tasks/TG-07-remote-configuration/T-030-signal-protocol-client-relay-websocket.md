# T-030: SignalProtocolClient + RelayWebSocketClient

## Metadata
- **Group:** [TG-07 — Remote Configuration](../index.md)
- **Component:** SignalProtocolClient, RelayWebSocketClient
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-002](../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md), [T-004](../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-031](T-031-config-payload-decryptor-validator-applicator.md), [T-032](T-032-companion-app/index.md)
- **Requirements:** FR-038, FR-039, NFR-012

## Description

Integrate `libsignal` for Signal Protocol E2E encryption (iOS + Android). Implement `SignalProtocolClient` and `RelayWebSocketClient` protocols from L2 §7.1 and §7.4. Key storage in `EncryptedLocalStorage`. Certificate pinning for relay server TLS. Exponential backoff reconnection. Shared implementation for both platforms.

## Acceptance criteria

```gherkin
Feature: SignalProtocolClient and RelayWebSocketClient

  Scenario: Protocols match L2 §7.1 and §7.4 exactly
    Given the SignalProtocolClient and RelayWebSocketClient implementations
    When their interfaces are compared to L2 §7.1 and §7.4
    Then all methods and properties match exactly

  Scenario: Initialisation generates and stores keys
    Given initialise() is called for the first time
    When key generation completes
    Then identity key, signed prekey, and one-time prekeys are generated
    And all keys are stored in EncryptedLocalStorage

  Scenario: Encrypt then decrypt round trip produces identical plaintext
    Given a plaintext message
    When encrypt() is called to produce ciphertext
    And then decrypt() is called on the ciphertext
    Then the decrypted output is identical to the original plaintext

  Scenario: TLS certificate pin mismatch fails immediately with no fallback
    Given a relay server presenting a TLS certificate that does not match the pinned cert
    When a connection is attempted
    Then the connection fails immediately
    And no fallback to the system trust store occurs
    And this is verified using a self-signed cert different from the pinned cert

  Scenario: Tampered ciphertext returns failure with no partial data
    Given valid encrypted ciphertext that has been tampered with
    When decrypt() is called
    Then the result is Failure(.DecryptionFailed)
    And no partial or corrupted data is returned

  Scenario: Low prekey supply triggers automatic refresh
    Given prekey supply falls below 5
    When the system checks prekey inventory
    Then refreshPreKeys() is triggered automatically

  Scenario: WebSocket disconnect triggers exponential backoff reconnect
    Given the WebSocket connection is active
    When the connection drops
    Then reconnection is attempted with exponential backoff timing
    And reconnection succeeds within expected timing bounds

  Scenario: Config queued offline is delivered on reconnection
    Given the companion app queued a config update while the WebSocket was offline
    When the WebSocket reconnects
    Then the queued config payload is delivered to the primary device

  Scenario: Identity private key never written outside EncryptedLocalStorage
    Given the codebase is inspected
    When all code paths involving identity private key handling are traced
    Then no path writes the identity private key outside EncryptedLocalStorage
    And this is enforced by code review
```

## Implementation notes

- Certificate pinning failure test is a CI gate (security-critical).
- Tampered ciphertext test is a CI gate.
- Pre-generate 100 prekeys; auto-refresh when supply < 5 (L2 §14 risk mitigation).
- Security reviewer sign-off required before merge.

## Definition of done
- [ ] Code reviewed and merged (security reviewer + one peer reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Certificate pinning failure CI gate passing
- [ ] Tampered ciphertext CI gate passing
- [ ] End-to-end encrypt/decrypt integration test on CI
- [ ] No PII in logs
