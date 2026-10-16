# TG-20: Music Intent Intake and Contact Veto

> **Jira Epic:** Music Intent Intake and Contact Veto

## Description
Delivers the deterministic on-device recognition of music requests: the `KeywordIntentRule` music domain with its markers, verbs, excluded forms and query extractor (C-SP-07, §14), and the `VoiceContactSearchRoute` music veto that keeps music utterances out of contact search (C-SP-08, §15). Explicit-YouTube behaviour stays byte-identical via the rule-level YouTube exclusion.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-112](T-112-keyword-intent-rule-music.md) | KeywordIntentRule music domain, markers and extractor | L | — | HIGH |
| [T-113](T-113-contact-search-music-veto.md) | VoiceContactSearchRoute music veto | S | T-112 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): 3–4 days
- Realistic (2 devs): 4 days
