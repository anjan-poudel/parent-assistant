# T-076: Cascade-Default Implementation (flip + kill switch)

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** The default flip itself — `IntentEncoderPreferences.isCascadeEnabled`, the `INTENT_ENCODER` release condition, the turn-level deadline in `LocalBrainChain`, and the kill switch
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-073](T-073-cascade-default-policy-design.md), [T-037-a](../../TG-08-nepali-intent-encoder/T-037-runtime-integration/T-037-a-ios.md)
- **Blocks:** [T-078](T-078-latency-residency-default-flip-verification.md), [T-078](T-078-latency-residency-default-flip-verification.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §6.1, §6.2, §6.4, §6.6; `IntentEncoderFeature.swift:54-60`, `:106-113`, `:154-194`; `LocalBrainChain.swift:28-74`

## Description

The mechanism exists. This task changes its default, and it lands the one structural fix the flip is conditional on.

**1. The flip is two changes, not one — and the design says so explicitly.** Design §6.2: `#if INTENT_ENCODER` compiles the entire encoder path out of a release build, deliberately (*"impossible for the encoder to become the local brain in a release build by accident"*, `IntentEncoderFeature.swift:54-60`). So "encoder-first is the default" requires **both** (a) `INTENT_ENCODER` becoming a condition on the shipping configuration and (b) `isCascadeEnabled` defaulting to `true` on an untouched device (`:106-109`, which today returns `false` when the key is absent). A reader could otherwise believe the flip is a UserDefaults default; it is also the decision that the encoder brain ships.

That decision is gated by Stage 0 and Stage 0b. **This task does not make it on its own authority**: it implements the flip *behind* the gate, and if Stage 0 is red the correct outcome is that (a) does not land and the task records why. Design §6.3 and D-6 are explicit that Stage 0 is a precondition and currently RED (the shipped artifact fails `emergency_recall` at ~0.9375 against a 1.00 hard gate).

**2. The turn-level deadline — the precondition that is not optional.** Design §6.4's finding: the encoder times out at 2.0 s with zero retries (`IntentEncoderInterpreter.swift:168-169`) and the picker brain at 10 s with one retry (`LocalIntentInterpreter.swift:47-49`), and `LocalBrainChain` passes no remaining-time budget to `standIn`. Worst-case escalate turn: **12 s** against NFR-002's 4 s. Condition 1.9 makes a turn-level deadline a precondition of the flip, so this task implements what T-073 specifies: the chain carries a per-turn deadline, derives `remaining`, and passes it to the stand-in; a stand-in with insufficient remaining declines rather than starting work it cannot finish.

The fix belongs in the chain, not in `LocalIntentInterpreter.Config`: the 10 s timeout serves the `.pickerBrain` default too, where there is no second brain and a slow answer beats no answer. Lowering it there would fix the cascade and regress the default. Design §6.4 states this; the implementation must honour it.

**3. The kill switch, already the right shape.** `IntentEncoderPreferences.setCascadeEnabled(false)` (`:111-113`) restores `.standaloneEncoder` — a mode the internal A/B already exercises, so it is a tested path rather than an untested escape hatch. Flipping the default does not remove it, and it is per device, applied on the **next turn with no relaunch** (`AppCoordinator.swift:1211-1245`, `:1265-1270`). The canonicalizer's kill switch is T-075's `Policy.enabled`.

**4. What is not touched.** `IntentRouter` (band policy, cloud escalation), `CommandRouter` (the net, the stage order), the confirmation flow, `TranscriptSanityGuard`, `IntentCommandCache`, and the stand-in's own configuration. The chain selects between two brains the router would consult anyway. In particular the keyword net is called at `CommandRouter.swift:716` before any interpreter runs, and nothing in this change moves it or puts a model upstream of it — FR-009's requirement is preserved by *not* touching the call graph, and T-078 asserts it.

**5. Honest failure.** If a Stage 1 condition fails on the reference device, this task's correct completion is a recorded "not flipped" with the failing numbers, not a retuned threshold. Design D-8 makes that a first-class outcome and §6.3 forbids the alternative.

## Acceptance criteria

```gherkin
Feature: Encoder-first-with-fallback becomes the default only behind its gates

  Scenario: The flip is implemented as the two changes the design names
    Given isCascadeEnabled returns false when the key is absent
    And INTENT_ENCODER compiles the encoder path out of a release build
    When the flip lands
    Then isCascadeEnabled defaults to true on an untouched device
    And INTENT_ENCODER becomes a condition on the shipping configuration
    And neither change lands while any Stage 0 or Stage 0b gate is red

  Scenario: The turn-level deadline bounds the escalated turn
    Given the encoder's 2.0 s timeout with zero retries and the picker brain's 10 s timeout
    And LocalBrainChain passing no remaining-time budget to the stand-in today
    When the chain is modified
    Then a per-turn deadline is carried and remaining is passed to the stand-in
    And a stand-in whose remaining budget is insufficient declines rather than starting an unbounded pass
    And the observed worst-case escalated turn is bounded by the turn budget, not by 2 s + 10 s

  Scenario: The picker brain's own configuration is not the lever
    Given LocalIntentInterpreter.Config.timeoutSeconds serves the .pickerBrain default as well as the cascade
    When the deadline is implemented
    Then LocalIntentInterpreter.Config.timeoutSeconds is unchanged at 10
    And the budget is enforced in the chain, so the default mode's behaviour is not regressed

  Scenario: The kill switch remains real after the flip
    Given IntentEncoderPreferences.setCascadeEnabled(false)
    When a device sets it to false
    Then the serving mode is .standaloneEncoder on the next turn, with no relaunch
    And the encoder remains usable and installable for inspection
    And turning it back on restores .encoderFirstEscalate on the next turn

  Scenario: The safety call graph is unchanged
    Given the keyword net runs on the raw transcript before any interpreter
    When the flip lands
    Then no model is placed upstream of routeSafetyNet
    And IntentRouter, CommandRouter, the band constants, the confirmation flow and the cache are unmodified
    And no change is made to the canonicalizer's composition seams

  Scenario: A failed gate produces a recorded non-flip
    Given one or more Stage 1 conditions failing on the reference device
    When the task completes
    Then the outcome recorded is "not flipped" with the failing condition and its measured value
    And no Stage 0, Stage 0b or Stage 1 threshold is relaxed to reach a flip
    And the implemented deadline change still lands, because it is a precondition rather than a flip feature
```

## Implementation notes

- Read first: design §6 in full, especially §6.2 (what "default" must mean), §6.4 (the budget and the 12 s bound) and §6.6 (the kill switch); `IntentEncoderFeature.swift:54-60`, `:106-113`, `:148-194`; `LocalBrainChain.swift:28-74`; `IntentEncoderInterpreter.swift` Config; `LocalIntentInterpreter.swift:47-49`.
- `IntentEncoderWiring.cascadeAcceptThreshold` is *derived* from `IntentRouter.Config.default.acceptThreshold` and pinned by `IntentEncoderWiringTests.swift:336-342`. Do not introduce a second number anywhere. Design D-7 and risk R-11 both concern this.
- The chain models escalation as three reasons — `abstained`, `failed`, `subBandConfidence` — and `onEscalated` reports them as metadata only (*"never transcript or reply content"*). Keep that; the reason breakdown is what makes a `failed`-heavy rate (encoder timing out) distinguishable from a `subBandConfidence`-heavy one (calibration off), and they have different fixes.
- The 12 s finding is the reason condition 1.9 is a precondition rather than a follow-up. If the deadline change and the flip are landed in the same commit and the gate later fails, the deadline must be separable — land it so the two changes are individually identifiable, since the deadline is a correctness fix that stands on its own.
- A decline-by-deadline path must produce a *user-visible outcome*, not silence: per design invariant 7 there is no path where a defect produces no answer. Falling back to the router's own policy is the outcome; the stand-in declining is not the same thing as the turn failing.
- `INTENT_ENCODER` is a compile condition, so the shipping-config change is verified by building the shipping configuration, not by a unit test. Confirm the shipping build's behaviour explicitly rather than inferring it.
- iOS verification uses `xcodebuild test`, not `build` (swift-syntax shims), with `./build.sh` as the canonical entry point.
- No `CommandRouter` or `IntentRouter` edits. If the deadline fix appears to require one, that is a signal the fix is in the wrong place — report it rather than making the edit.

## Definition of done
- [ ] `isCascadeEnabled` defaults true on an untouched device; `INTENT_ENCODER` conditional on the shipping configuration
- [ ] Both changes gated: not landed while any Stage 0 or Stage 0b gate is red, with the reason recorded if withheld
- [ ] A turn-level deadline carried by `LocalBrainChain` and `remaining` passed to the stand-in
- [ ] The stand-in's insufficient-budget path implemented and producing a real answer, not silence
- [ ] `LocalIntentInterpreter.Config.timeoutSeconds` unchanged
- [ ] Kill switch verified: false → `.standaloneEncoder`, true → `.encoderFirstEscalate`, both on the next turn with no relaunch
- [ ] `IntentRouter`, `CommandRouter`, band constants, confirmation flow and cache unmodified; keyword net still called on the raw transcript before any interpreter
- [ ] Shipping-configuration build verified explicitly, not inferred
- [ ] Outcome recorded as flipped or not-flipped with numbers; no threshold relaxed
- [ ] Tests pass under `xcodebuild test`
