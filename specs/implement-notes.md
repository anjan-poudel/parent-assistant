# implement — running unit log (conversational-nepali-replies)

Short per-unit summaries for the engine record (full notes per unit live in
`specs/T-NNN-notes.md`).

- **Description:** Implementation log for the unit-based `implement` task of the conversational-nepali-replies feature (worktree elderly-ai-assistant-conversational-nepali-replies, branch feat/conversational-nepali-replies). One section per unit, appended as waves complete.

## T-166 — Nepali chat style spec and its loader — DONE

Wave 0. The single source of truth for Nepali conversation style plus its
stdlib-only loader and executable drift check. Artifact
`tools/train-intent/seeds/nepali-chat-style-spec`: sectioned text with prose
rule text (byte-mirrorable) and JSON machine blocks; 10 required sections
(register, particles, sentence_shape, small_talk, code_switch, ai_isms,
persona_clause, rubric, guard_checks, coverage); style_spec_version 1;
content sha256 recorded in the unit notes. Loader
`tools/train-intent/src/style_spec.py`: typed accessors, no-default failures
naming the missing section, version+sha256 evidence, executable consumer
drift check with a documented marker contract, CLI exit 0/1/2, stdlib-only
(proven under an isolated interpreter). Tests
`tools/train-intent/tests/test_style_spec.py`: 42 tests, all OK (python3 -m
unittest tests.test_style_spec). Recorded deviation: JSON machine blocks
instead of a whole-file YAML document (the stdlib-only contract rules out
PyYAML; JSON is a subset of YAML so the design intent holds). rubric and
coverage are required sections beyond design section 6.1 because the
acceptance criteria and T-178/T-181 cite them. Training-box (anjan-ubuntu)
execution not performed here; owned by T-179/T-183. Full notes: the unit
notes file in specs.

## T-172 — CloudChatConsentGate: fail-closed consent record — DONE

Wave 0. The cloud chat consent record and its one-writer gate in the shipped
OD-12 shape (LiveTranslate/PointAsk precedent reused, not forked). Decision
with four states (granted, notRecorded, denied, unreadable); allowsEgress
true only for granted; ConsentRecord {granted, recordedAt,
disclosureVersion} over the same encrypted-at-rest consent storage with the
same key-store composition; stale disclosure version re-asks (notRecorded),
never granted; unreadable distinct from notRecorded and denied, fail-closed,
never crashes; one writer under NSLock with read-back verification, revoke
clears memory before the stored record is rewritten, a write that does not
persist is surfaced (never a false success); per-turn read with no caching.
Disclosure stamp placeholder cloudchat.disclosure.draft.14oct2026.r1 (final
copy owned by T-176). Classification-only events (component cloud_chat, five
types, metadata only disclosureVersion). Tests: 37 executed, 0 failures
(./build.sh test:unit CloudChatConsentGateTests; the release-log and
prompt-mirror pre-test guards passed; full test log in the suite).
