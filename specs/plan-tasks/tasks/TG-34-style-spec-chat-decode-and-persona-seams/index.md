# TG-34 — Style Spec, Chat Decode and Persona Seams

> **Jira Epic:** Style Spec, Chat Decode and Persona Seams

## Description
The feature's foundation: one Nepali conversation style spec as the single source of truth, and the two chat decode/persona seams that consume it — the on-device chat shape (warm fixed-seed decode, upgraded local persona, command determinism preserved) and the cloud chat responder (spec persona, explicit temperature, transcript-only egress). Nothing here is user-visible on its own; every later group builds on these units.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-166](T-166-nepali-chat-style-spec-and-loader.md) | Nepali conversation style spec and its loader | M | — | HIGH |
| [T-167](T-167-local-chat-decode-shape-and-persona.md) | Local chat decode shape and upgraded local persona | M | T-166 | CRITICAL |
| [T-168](T-168-cloud-chat-responder-and-explicit-temperature.md) | Cloud chat responder: conformance, spec persona and explicit temperature | M | T-166 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~5.5 days
- Realistic (2 devs): ~4 days

## Group-wide gates and conventions
- Scoped-suite gate: the honest per-unit gate is a scoped run such as `ios/build.sh test:unit ChatSamplingTests`, which also executes the source privacy guard before the tests. The full suite carries a known pre-existing red baseline and is not the per-unit gate; it runs once in T-186 with the baseline named.
- No review or security-gate units exist anywhere in this plan: the workflow is the 2026-10-14 lean chain (design-l1 combined → plan-tasks → implement → final-sign-off with one advisory non-blocking security pass). Do not create review tasks.
- Every unit here declares its owned files; units that share a file are serialized into different waves. The style spec is the feature's one shared artifact — later units read it, but only T-166 writes it.
- Fresh-worktree note: a new worktree needs the whisper medium ne model and the kws assets symlinked from the main checkout before a link can succeed (house build notes).
- Content and key hygiene is a per-unit property from here on: no transcript, reply text or credential in any log line a unit adds.
