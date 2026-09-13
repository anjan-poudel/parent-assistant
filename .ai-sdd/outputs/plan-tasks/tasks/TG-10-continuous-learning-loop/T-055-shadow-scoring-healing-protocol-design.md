# T-055: Shadow Scoring & Healing Protocol Design

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** Shadow scoring against the active brain; divergence telemetry through `ObservabilityBus` (`ios/ElderlyAssistant/Services/MedicationScheduler/DependencyProtocols.swift:23-34`) and `LogSanitiser` (`Services/Observability/LogSanitiser.swift`); the fail-soft ladder (`Services/Intents/LocalBrainChain.swift:28-69`); rollback
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-054](T-054-capture-schema-egress-contract-design.md) (the egress contract and the channel boundary it states)
- **Blocks:** —
- **Requirements:** NFR-002, NFR-013, NFR-016
- **Origin:** `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §4.5, §7.2, R-5, R-6, R-7; the runtime the design builds on is the shipped fail-soft chain and the encoder's abstention contract

## Description

Design the runtime half of the loop: how a candidate brain is scored against the brain the user actually has, what divergence telemetry leaves the device (and through which boundary), what happens when the active brain misbehaves, and how a bad publish is undone.

**Shadow scoring.** Two interpreters, one sanitised transcript, one turn: the active brain produces the reply the user hears, and the candidate produces a second, private result used only for comparison. The comparison is a *summary* — agreement/divergence per action, per confidence bucket, per slot-presence class — never the transcript and never either output's content. This is the only signal in the loop that reflects the household's real traffic rather than the held-out corpus, which is why the design treats it as the counter-measure to R-7 (a promotion that passes every gate and still regresses for this user).

**Hard constraint: shadow scoring is off the reply path.** NFR-002's 4-second budget belongs to the user. The protocol must specify where the shadow pass runs (after the reply is spoken; batched; skipped under memory pressure), how it is disabled for safety-critical turns, and how its cost is measured. The encoder's own runtime already distinguishes an abstention from a failure with content-free reasons (`IntentEncoderInterpreter.swift:16-32`) and is behind the compile-time `IntentEncoderFeature` gate (`IntentEncoderFeature.swift:29-40`, `:57-76`) — the shadow protocol reuses both rather than inventing a parallel availability model.

**Divergence telemetry must go through the existing sanitised bus.** Events are `ObservabilityEvent`s and reach a sink only via `LogSanitiser.sanitise` (`AppCoordinator.swift:7274`; `LogSanitiser.swift:84-97`), which **drops every metadata key that is not allow-listed** (`:56-70`). A new divergence key that is not declared does not "fail to leak" by luck — it silently disappears, which is its own defect. This task must therefore declare the exact allow-list additions (counts, rates, action ids, content-free codes) and prove to a reviewer that no declared key can carry content. T-049 and T-050 are the binding precedent: content must not reach a log sink even when it would be diagnostically convenient, and the boundary must hold for emitters that do not exist yet (`LogSanitiser.swift:22-49`).

**The fail-soft ladder is the healing guarantee.** The shipped chain already falls through rather than predicting: `preferred` while available, else `standIn` (`LocalBrainChain.swift:38-69`); the keyword safety net and confirmation flow are upstream of every interpreter (`CommandRouter.swift:651`, `:1429`). The protocol's job is to state precisely which runtime condition triggers which rung, what the user hears, and what is recorded — and to keep "a degraded brain is survivable" true at every rung. The design's §7.1 is binding: no loop artifact can gate, suppress or replace the safety stages, and the ladder's behaviour under a diverging candidate must be identical to its behaviour today.

**Rollback.** Two mechanisms, one of which already exists: the promotion rule refusing to publish ([T-058](T-058-promotion-gate-implementation.md)), and re-installing the previous artifact through the same `ModelStore` path. This task specifies the trigger (what divergence measurement warrants a rollback), the owner (a human — D-4), and the observable evidence for it. It does not build a second deployment mechanism.

**Out of scope.** The egress payload (T-054), the miner (T-057), the promotion decision (T-058). No router, safety-net, band-policy or confirmation-flow change: the design's §7.3 forbids a new runtime threshold, and divergence stays telemetry.

## Acceptance criteria

```gherkin
Feature: Shadow scoring and healing protocol

  Scenario: Shadow scoring is specified entirely off the user's reply path
    Given NFR-002 (complete NLU result and TTS start within 4 seconds of the transcription)
    And the shipped chain consults preferred only while available (LocalBrainChain.swift:38-69)
    When the protocol is designed
    Then it states when the shadow pass runs relative to the reply, how it is scheduled, and the conditions under which it is skipped (memory pressure, safety-critical turn, feature gate off)
    And it specifies how the added cost is measured and what budget it must stay within, with the measurement method named

  Scenario: Divergence telemetry is carryable only by declared, content-free fields
    Given LogSanitiser drops every metadata key not in allowedKeys (LogSanitiser.swift:56-70) and sanitises everything else (:84-97)
    And T-049/T-050 as the precedent that content must never reach a log sink even via a new field
    When the telemetry contract is written
    Then it lists the exact metadata keys to be added to allowedKeys, with each key's value domain and an argument that no value in that domain can carry transcript, slot, health or contact content
    And it states that an undeclared key is dropped rather than leaked, and that the protocol must not rely on dropping as a safety mechanism

  Scenario: The fail-soft ladder's behaviour under divergence is stated rung by rung
    Given the shipped ladder: keyword safety net (CommandRouter.swift:651, :1429) -> cache -> preferred -> standIn -> cloud -> re-prompt
    And the encoder's abstention reasons are content-free machine strings (IntentEncoderInterpreter.swift:16-32)
    When the protocol is designed
    Then each rung names its trigger (unavailable, abstained, timed out, diverged) and what the user hears, and the recording for each
    And it states explicitly that no loop artifact can gate, suppress or replace emergency, medication acknowledgement or the confirmation flow

  Scenario: Rollback is specified with a trigger, an owner and evidence
    Given the promotion rule can only block (recorded decision D-4), and the publish path re-installs through ModelStore
    When the rollback protocol is designed
    Then it names the divergence measurement that warrants a rollback, who acts on it, and what evidence is recorded
    And it states that rollback reuses the existing artifact install path and introduces no second deployment mechanism

  Scenario: The protocol introduces no new runtime threshold and no PII
    Given the band policy is accept >= 0.7 / rephrase 0.4-0.7 / abstain < 0.4 (IntentRouter.swift:49-58, :318-319)
    And NFR-016 requires logs to contain no PII
    When the protocol is written
    Then it states that divergence is telemetry and never a runtime decision, and that the band policy and router are unmodified
    And every event example in the design uses synthetic values with no transcript, contact, medication or message content
```

## Implementation notes

- Read the runtime it extends: `LocalBrainChain.swift:28-69` (the chain and its availability rule), `IntentEncoderInterpreter.swift:16-32` (abstention reasons), `:94-110` (installed only as `preferred`), `IntentEncoderFeature.swift:29-40` (compile-time gate), `:71-76` (gated construction); `AppCoordinator.swift:7260-7278` (the bus implementation); `LogSanitiser.swift:22-49`, `:56-70`, `:84-122` (boundary, allow-list, bounding).
- The channel boundary is stated in `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §4.5 and §5.3: telemetry rides the bus; the capture egress payload does not. Keep the two documents consistent — [T-054](T-054-capture-schema-egress-contract-design.md) states the same boundary from its side.
- T-037-a is the runtime integration that installs the encoder (`tasks/TG-08-nepali-intent-encoder/T-037-runtime-integration/T-037-a-ios.md`); the shadow protocol must be specified so it can be switched off for builds where the encoder is not compiled in, without changing the ladder.
- Battery and memory are real constraints on a 24/7 elder-care device: specify a sampling policy (per-turn, per-session, or capped per day) and say what the sample size means for the confidence of a divergence rate.
- No PII in the design's examples (NFR-016). Where a transcript would illustrate an example, use a synthetic, non-user utterance or a placeholder token.
- Hand-off: [T-056](T-056-capture-egress-implementation.md) implements any shadow-side capture this protocol requires; [T-058](T-058-promotion-gate-implementation.md) consumes the divergence evidence as one input to the human publish decision; [T-060](T-060-loop-end-to-end-fixture.md) proves the ladder still holds when a candidate diverges.

## Definition of done
- [ ] Shadow-scoring protocol: scheduling, skip conditions, reply-path isolation, cost budget and measurement method
- [ ] Telemetry contract: exact allow-list additions with value domains and a content-freedom argument per key
- [ ] Ladder table: rung, trigger, user-visible behaviour, recording
- [ ] Rollback protocol: trigger, owner, evidence, reuse of the existing install path
- [ ] Explicit statements that the band policy, router and safety stages are unmodified and that divergence is never a runtime threshold
- [ ] No PII in any example; synthetic values only
- [ ] The channel boundary shared with [T-054](T-054-capture-schema-egress-contract-design.md) is consistent in both documents
