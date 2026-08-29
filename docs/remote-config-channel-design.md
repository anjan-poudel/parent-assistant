# Remote Configuration & Family-Notification Channel — Design

Resolves constitution **Open Decision #5** and unblocks the `FamilyNotifier`
redesign flagged during the 2026-08-28 code review.

## Problem

Two flows need to move small, safety-relevant messages between the elderly
user's phone (the "primary device") and one or more family members' phones
(the "family devices"):

1. **Remote config push** — family → primary. Payload: medication schedule
   diffs, contact list changes, health thresholds, language settings.
2. **Family notification** — primary → family. Payload: alert-type tag plus
   an ISO-8601 timestamp (see `FamilyAlertType`). Never a medication name,
   metric value, or contact display name.

Both must be end-to-end encrypted per constitution §Architecture Constraints
and §Security. Neither device can invoke APNs/FCM directly (Apple/Google only
accept provider-server auth), so a relay is unavoidable — but the relay must
never be able to read a payload.

## Non-goals

- Voice/audio transport. Voice never leaves the device (constitution §1).
- General-purpose messaging or presence. This is a config + alert channel.
- Multi-party group chat semantics.

## Overview

We use APNs (iOS) and FCM (Android) as the wake-up path only. The actual
payload is a Signal-style E2E-encrypted envelope stored briefly in a small
relay ("the config broker"), addressed by an opaque conversation id.

```
family device            config broker                 primary device
  |  encrypt(payload,     |                              |
  |    session_key)  ---> | POST /envelopes/{convId}     |
  |                       | store ciphertext (24h TTL)   |
  |                       | push wake-up to APNs/FCM --> | wake, GET envelope
  |                       |                              | decrypt, apply
  |                       | <---------------- DELETE ----|
  |                       |                              |
```

## Cryptography

- **Key agreement.** X3DH-style (identity key + one-time prekey) established
  during onboarding, when the family member scans a QR code shown on the
  primary device. QR carries the primary's identity public key and a signed
  prekey bundle; the family device replies with its identity key over the
  same session. No trust-on-first-use over network — the QR is out-of-band.
- **Session.** Double Ratchet after handshake. Each envelope is encrypted
  with a fresh chain key; compromise of one message key does not affect
  others (forward secrecy) and a full key compromise is self-healing after
  the next round-trip (post-compromise security).
- **On-device storage.** Identity keys live in the Secure Enclave / Android
  Keystore. Session state lives in `KeychainEncryptedStorage` (iOS) /
  `EncryptedSharedPreferences` (Android).
- **Payload format.** `{ v: 1, sender_id_hash, ciphertext, mac }`, CBOR-
  encoded. `sender_id_hash` is the SHA-256 truncation used elsewhere for
  observability — the relay never sees a real identifier.

## The relay ("config broker")

Minimum-trust design:

- **Storage.** Ciphertext blobs, indexed by opaque `convId` (256-bit random).
  TTL: 24h. Blob size cap: 8 KB (enough for a schedule diff; alert envelopes
  are ~200 bytes).
- **Auth.** Sender authenticates with a per-device token issued at pairing;
  receiver polls with the same. No account, no email, no phone number.
- **Push out.** Broker holds APNs / FCM tokens per device and sends a
  content-less wake-up notification when a new envelope lands. Payload of
  the push carries no user data; the device fetches the ciphertext next.
- **Logging.** No payload, no `convId` in logs — just size and status.
- **Metadata that DOES leak to broker.** Timing, envelope size, sender ↔
  recipient pairing, device tokens. This is unavoidable for any relay. We
  accept it: the broker knows the primary and family talk, but cannot read
  what they say.
- **Deployment.** Single stateless service + short-lived object store. No
  user database. Region: same as primary user's App Store region for data-
  residency simplicity (constitution Open Decision #9).

## What this replaces in the current code

`APNsFamilyNotifier` and `APNsProvider` in `Services/FamilyNotifier/` are
currently written as if the elderly user's device sends APNs pushes
directly. That cannot work — Apple only accepts pushes from provider
servers. The redesign:

```
FamilyNotifier.notifyAll(alertType, at:)
  -> RemoteChannel.send(envelope: alertEnvelope(alertType, at:))
      -> DoubleRatchet.encrypt(payload)
      -> ConfigBroker.upload(convId, ciphertext)
      -> broker POSTs to APNs/FCM
```

The `FamilyNotifierProtocol` contract stays the same. Only the transport
under it changes. Tests that mock `FamilyNotifierProtocol` are unaffected.

## Failure modes and fallbacks

- **Broker unreachable at emergency time.** Emergency call path (constitution
  Safety-critical constraint 2) never depends on the broker — it dials the
  carrier directly. Family notification is best-effort; the on-device event
  is logged and re-attempted with exponential backoff for up to 1 hour.
- **Envelope stuck in broker (recipient offline).** 24h TTL; sender surfaces
  a "family did not receive" state after 15 minutes, retryable.
- **Push suppressed by OS Focus/DND.** Critical Alerts entitlement is
  requested at onboarding for the primary device (already required for
  medication reminders, per NFR-027); family devices get a regular push
  and rely on the recipient's own notification settings.
- **Broker compromised.** By construction the broker cannot decrypt. Worst
  case: attacker learns pairing graph and event timing.

## Open items for architect

1. **Broker implementation.** In-house minimal service vs. reuse of a
   published relay (Signal's server is open-source but heavy; libsignal
   embeds well but its "server" side is not trivial). Recommend in-house
   for control over TTL and data-residency, using libsignal for the
   protocol only.
2. **Key rotation cadence.** Session ratchets on every message; identity
   keys rotate on pairing change. Confirm before onboarding v1.
3. **Multiple family recipients.** Do we fan-out per-recipient sessions on
   the primary device (N ratchets) or use sender-keys? Per-recipient is
   simpler; sender-keys scale better if a household has >5 caregivers.
   Recommend per-recipient for v1.
4. **QR pairing UX.** Elderly users may not comfortably show a QR. Optional
   fallback: family device displays a code, elderly user reads it aloud
   over a phone call; primary confirms via voice biometric. Adds a text-
   entry-free path but weakens the out-of-band guarantee. Confirm before
   accessibility review.

## Traceability

- Constitution §Architecture Constraints, item 2 (E2E-encrypted remote
  config channel).
- Constitution §Security (voice biometric on Secure Enclave, encrypted
  storage class Complete).
- Constitution Open Decision #5 (this document).
- Code review 2026-08-28, finding "device-originated APNs push is not a
  thing" — this design is the fix.
