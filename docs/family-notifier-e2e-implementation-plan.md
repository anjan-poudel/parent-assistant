# Family Notifier — E2E Channel Implementation Plan (#4)

**Status:** Plan (for implementation by a future session)
**Date:** 2026-08-30
**Problem:** `APNsFamilyNotifier` (iOS) and `FCMFamilyNotifier` (Android) send pushes device→Apple/Google directly with stub providers that print and return `true`. Neither Apple nor Google accepts device-originated provider pushes, FCM "topic publish" is server-side-only, and alert payloads are unencrypted — violating constitution constraint §2. The design that fixes this already exists: [`docs/remote-config-channel-design.md`](remote-config-channel-design.md). This plan implements it.

**Scope decision (MVP):** per constitution §4 the MVP platform is iOS. This plan delivers the iOS leg first with the broker server (needed by both platforms). Android leg follows using the same broker + `org.signal:libsignal-client`.

## 1. Architecture recap (from the design doc)

```
family device            config broker                 primary device
  |  encrypt(payload,     |                              |
  |    session_key)  ---> | POST /envelopes/{convId}     |
  |                       | store ciphertext (24h TTL)   |
  |                       | push wake-up to APNs/FCM --> | wake, GET envelope
  |                       |                              | decrypt, apply
  |                       | <---------------- DELETE ----|
```

- Broker is minimum-trust: sees ciphertext + metadata only (timing, size, pairing graph).
- `FamilyNotifierProtocol` contract stays unchanged — tests mocking it keep passing; only the transport under it changes.

## 2. Phases

### Phase 1 — Envelope + crypto types (iOS, ~2 days)

- New `Services/FamilyNotifier/Envelope.swift`: `FamilyAlertPayload { v: 1, alert_type, timestamp }` (alert-type + ISO-8601 only — never medication names, values, or contacts), CBOR-encoded via a small dependency (e.g. `PotentCodables` or hand-rolled minimal CBOR for this 3-field schema).
- Crypto: **vendored `libsignal-protocol-swift`** (Signal's audited implementation) rather than a hand-rolled ratchet — the design doc's open item #1 recommends libsignal for protocol only. Wrapper: `SignalSessionStore` persisting session state in `KeychainEncryptedStorage`.
- Keys: identity key + prekey bundle in the Secure Enclave (generate 100 one-time prekeys, refresh when < 5 — plan-tasks risk #5).

### Phase 2 — Config broker server (in-house, ~3–5 days)

Minimal stateless service (Node/Go + object store with 24 h TTL; no user DB), per design doc §"The relay":

| Endpoint | Behavior |
|---|---|
| `POST /devices/{token}/token` | register APNs/FCM device token |
| `POST /envelopes/{convId}` | store ciphertext (≤ 8 KB, 24 h TTL); trigger content-less push to recipient |
| `GET /envelopes/{convId}` | return + delete envelope |

- Auth: per-device opaque token issued at pairing. No accounts, e-mail, or phone numbers.
- Push out: server holds APNs (.p8 key) / FCM credentials — this is the actual fix for "device-originated push is not a thing".
- Logging: size + status only, never `convId` or payload (design doc §Logging).
- Deploy: single service + S3/R2 bucket, region matching the primary user's App Store region (open decision #9). Deploy behind TLS 1.3 with certificate pinning on the client.

### Phase 3 — Pairing (iOS, ~2 days)

- Primary device shows a QR with identity pubkey + signed prekey bundle; family device scans and replies with its identity key over the same session (out-of-band, no TOFU over network).
- For MVP the "family device" is a second install of the app in **caregiver mode** (full companion app is TG-07 work). Store one session per family device (per-recipient sessions for v1 — design doc open item #3).
- Pairing flow must be reachable without voice biometric (setup-time UI), but session *use* requires the primary's normal auth.

### Phase 4 — Rewire the notifier (iOS, ~2 days)

- `E2EFamilyNotifier: FamilyNotifierProtocol` replaces `APNsFamilyNotifier` in `AppCoordinator` wiring:
  `notifyAll(alertType, at:)` → build envelope → ratchet-encrypt → broker upload → return `[NotificationResult]` from broker ACK (not "push delivered").
- Failure fallbacks (design doc §Failure modes): broker unreachable → log + exponential-backoff retry up to 1 h; surface "family did not receive" state after 15 min. Emergency call path never depends on this (unchanged — direct carrier call).
- On the receiving (caregiver-mode) side: fetch envelope on wake-up push → decrypt → local notification from `FamilyAlertType` + timestamp.

### Phase 5 — Tests & security sign-off (~2 days)

- Unit: envelope CBOR round-trip; ratchet session persistence across app relaunch; TTL expiry; partial-delivery results; tampered-ciphertext rejection (MAC failure).
- Integration: local broker instance + stub APNs; CI end-to-end test "missed dose → caregiver-mode device shows alert".
- STRIDE re-check against `security-design-review.md` THREAT-005 mitigations; security reviewer sign-off before merge (plan-tasks requirement).

## 3. Explicit decisions (resolve design-doc open items #1–#4)

1. Broker: **in-house** (control over TTL + residency); libsignal for protocol only.
2. Key rotation: identity keys rotate only on pairing change; sessions ratchet per message (v1).
3. Multi-recipient: **per-recipient sessions** on the primary device (v1).
4. Pairing UX: QR first; the read-aloud-over-call fallback is deferred to the accessibility review.

## 4. Effort estimate

| Phase | Effort |
|---|---|
| 1 Envelope + crypto | 2 days |
| 2 Broker server | 3–5 days |
| 3 Pairing | 2 days |
| 4 Rewire notifier | 2 days |
| 5 Tests + sign-off | 2 days |
| **Total** | **~11–13 days** |

## 5. Out of scope (deliberately)

- Remote **config** payloads (schedules, thresholds) — same channel, separate task (TG-07 / T-031 `ConfigApplicator`).
- Multi-party groups, presence, photo-verification delivery over the same channel (FR-D04b) — follow-ups that reuse Phase 1's envelope types.
- Android leg (same broker, libsignal-android) — after iOS MVP.
