# TG-08: Session Commands, Spoken Output and In-Session Capture

> **Jira Epic:** Session Commands, Spoken Output and In-Session Capture

## Description

The two explicit ways the elder hears a translation — tapping one bubble, or asking to read the
visible regions top-to-bottom (C12, FR-LCT-021) — plus the deterministic, offline, session-local
command parser that recognises those phrases in English and Nepali (FR-LCT-022), and the
single-utterance capture with microphone/speech arbitration that keeps the feature from hearing
itself (R10). Nothing is spoken automatically: there are exactly two speech construction sites.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-023](T-023-session-command-parser.md) | `LiveTranslateCommandParser` (C12) | M | T-005 | MEDIUM |
| [T-024](T-024-spoken-output.md) | Tap-to-hear and "read this to me" | M | T-002, T-005, T-017, T-020, T-021 | MEDIUM |
| [T-025](T-025-in-session-capture-and-audio-arbitration.md) | In-session capture and audio arbitration (R10) | M | T-006, T-023, T-024 | MEDIUM |

## Group effort estimate

- Optimistic (parser authoring parallel with speech wiring): 2–3 days
- Realistic (1–2 devs; T-025 needs both predecessors): 3–5 days
