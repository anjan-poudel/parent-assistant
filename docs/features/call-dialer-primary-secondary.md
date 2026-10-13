# Feature: Call Dialer Primary/Secondary

**Shipped:** 2026-10-12 · **PR:** [#171](https://github.com/anjan-poudel/parent-assistant/pull/171) · **Merge commit:** `81de796a` · **Branch:** `feat/call-dialer-primary-secondary`

## What it does

Before this feature the app had ONE global dialer preference; when that
channel could not place a call (Messenger with no handle, WhatsApp not
installed) the tap dead-ended. Now calls run a **primary → secondary → GSM**
fallback chain so a call always goes through, and the actually-routed channel
is spoken out loud before dialing.

- `CallChannelChain` (`Services/Calls/CallChannelChain.swift`) — pure static
  resolver: attempt preferred, then secondary (deduped), then `phone` (GSM,
  always feasible — the hard floor).
- Feasibility checks: Messenger = handle on file; WhatsApp =
  `canOpenURL("whatsapp://")` probe (local only); FaceTime/phone = always.
- Settings gain **Primary dialer** and **Fallback dialer** pickers
  (`secondaryCallApp`, default `.phone`).
- All call paths route the chain: address-book rows, family-contact buttons,
  missed-call dial-back, and voice-initiated calls; per-contact and family
  picks still win as the chain's preferred input. The existing multi-turn
  confirmation is reused — the fallback resolves BEFORE the spoken
  confirmation, which names the actually-routed channel.

## Gate evidence

- Design frozen + owner-approved (`docs/superpowers/specs/2026-10-12-call-dialer-primary-secondary-design.md`)
- review-l2 GO, security-design-review **SECURITY-GO**
- implement (waves W2–W10), review-implementation **GO** (`e9b74b76`),
  security-test **SECURITY-GO** (`67a85676`)
- final sign-off: T2 approved under the owner's push-and-merge directive
  (2026-10-12) — `specs/final-sign-off.md`

## Outstanding (tracking gate)

**DV-1..7 device validation on Anzaan** — recorded as outstanding in the
sign-off record; must be executed on the reference device before the next
release build ships.

## Union with family-contacts-unify

The family-contacts-unify feature (PR #172) merged on top and deliberately
kept this chain untouched: its link resolution sits UPSTREAM (choose the
person), this chain sits DOWNSTREAM (choose the channel). `MethodResolver` /
`CallingSettingsView` / the dial layer were not modified by PR #172.

## Spec trail

`specs/call-dialer-primary-secondary/` (constitution, workflow, init-report)
plus the frozen design doc above.
