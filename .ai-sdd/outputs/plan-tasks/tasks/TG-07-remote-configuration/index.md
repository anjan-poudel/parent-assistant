# TG-07: Remote Configuration

> **Jira Epic:** Remote Configuration

## Description

Delivers the end-to-end remote configuration pipeline: Signal Protocol E2E encryption over WebSocket relay, config payload decryption/validation/application with atomicity and hot-reload, and the companion (family/caregiver) iOS + Android app for pushing config updates. All config transmissions are Signal-encrypted.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-030](T-030-signal-protocol-client-relay-websocket.md) | SignalProtocolClient + RelayWebSocketClient | L | T-002, T-004 | HIGH |
| [T-031](T-031-config-payload-decryptor-validator-applicator.md) | ConfigPayloadDecryptor + ConfigSchemaValidator + ConfigApplicator | M | T-030, T-024, T-028, T-005 | MEDIUM |
| [T-032](T-032-companion-app/) | Companion App (iOS + Android) | L | T-030 | MEDIUM |

## Group effort estimate

- Optimistic (full parallel, T-032 subtasks run in parallel with T-031): 6–10 days
- Realistic (2 devs, sequential): 14–22 days
