# Voice Pre-Acknowledgment ("एक छिन" / "one moment")

Design spec — approved 2026-09-11 (approach A). Branch `task/voice-ack`.

## Problem

When a voice request lands on a stage whose reply takes a beat (LLM
round-trip, alarm/timer arming, YouTube, briefing, news, navigation),
the user hears silence between the command and the reply — no sign the
request was heard. Elderly UX needs an immediate verbal acknowledgment.

## Decision (user-approved)

- **Approach A — ordered ack lane.** When a slow stage fires, the router
  immediately speaks a short pre-acknowledgment; the stage's real reply
  follows through the same serialized lane, so ack-then-result always
  plays in committed order.
- **Wording:** 3 rotating warm variants per language (router-local
  counter, cycles 1→2→3):
  - en: "one moment…", "just a moment…", "okay, one moment…"
  - ne: "एक छिन…", "एक छिन है…", "हुन्छ, एकछिन…"
  - Catalog keys `voiceAck.moment1/2/3` (en + ne values in
    Localizable.xcstrings).
- **Scope (ack):** LLM interpreter round-trip; alarm SET; timer START;
  YouTube; morning briefing; news reader; directions `.navigate`.
- **Scope (no ack):** instant answers (topic pre-answers — greetings,
  time/date/weather; calculator), confirmation challenges (they already
  speak immediately), safety net/emergency, contact search, alarm
  off/snooze/timer cancel (synchronous replies).

## Architecture

- **`ReplySpeakLane`** (new, `Services/Voice/ReplySpeakLane.swift`): an
  actor holding the router's `Speaker`. Each `enqueue` chains onto the
  previous utterance's task (`await prior?.value`), so utterances drain
  FIFO. Callers `await` the enqueue to keep the existing per-utterance
  `noteSpeakingStarted`/`noteSpeakingEnded`/turn-tracer pairing intact.
- **`CommandRouter.speak(text:locale:)`** funnels through the lane
  (lazily constructed from the injected speaker). Every existing speak
  path — replies, `speakWithVisibleOutcome`, YouTube failure lines —
  inherits the ordering with no call-site change.
- **`speakPreAck(locale:)`** resolves the next variant key against the
  stage locale (same `activeLocale` every stage already uses), speaks it,
  advances the counter. Nil/empty text is a no-op (existing guards).

## Data flow

`route(transcript:)` matches a slow stage → `speakPreAck()` commits the
ack through the lane → the stage's async work runs → the result reply
commits through the same lane → lane plays ack, then result. The
pipeline's reply-pending hold (REST-DIP) is untouched: it still resolves
after the result commit; the ack plays while the session shows
"understanding".

## Boundaries (documented, not solved)

Briefing/news/directions RESULT speech is coordinator-owned
(SpeakQueue `.briefing`/`.interactive` lanes) — the router's ack and the
coordinator's result are two lanes sharing the Piper speaker (whose own
synthesis is serialized). The ack is emitted at stage fire, before the
coordinator's composition work, so it precedes the result in practice;
a hard cross-lane guarantee would move the ack into SpeakQueue and is
out of scope for this task.

## Testing (seam)

- ack-then-result ordering (timer set: ack first, confirmation second —
  asserted on `noteAssistantSpoke` commit order + lane FIFO execution);
- instant-answer skip (greeting, calculator — no ack);
- confirmation-challenge skip (yes-answer during a challenge — no ack);
- slow-stage acks (LLM path, YouTube, directions, briefing, news);
- localization keys resolve per locale (en/ne) via `L10n.str`.
