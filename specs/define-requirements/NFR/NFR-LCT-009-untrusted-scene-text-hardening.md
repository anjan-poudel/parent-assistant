# NFR-LCT-009: Untrusted scene text hardening (injection)

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution binding rule 4; project constitution Standards ("Injection detection enabled at quarantine level"); design §7; workflow security-design-review focus

## Description
Recognized scene text is **attacker-influenceable input**: anyone can print a label, sign or menu
whose text is an instruction aimed at the translation model. It must be handled with the same
discipline `InputSanitiser` applies to transcripts (quarantine level):

- Before OCR text enters any prompt, it is **sanitised and bounded** — per-string length caps and
  a per-batch bound, with truncation that never splits a grapheme cluster, and the text is passed
  as data (delimited/quoted), never as free-form instruction text.
- Text that trips the injection policy is **not** silently translated as trusted content: the
  request path must follow the quarantine policy in force (the same level the project configures),
  and the affected region must degrade honestly rather than sending the payload.
- Model output is treated as untrusted too: only strings mapped back to requested keys are
  accepted; unexpected keys or non-string values are discarded, never rendered or executed.
- A prompt-injection attempt must not be able to reach any other app capability (no tool/action
  invocation from the translation prompt — the request is a plain text completion).

## Acceptance criteria

```gherkin
Feature: Hardening against hostile scene text

  Scenario: Oversized recognized text is bounded before the request
    Given a recognized region contains text far longer than the per-string bound
    When the request payload is built
    Then the string is truncated to the bound without breaking a grapheme cluster
    And the batch stays within the per-batch bound

  Scenario: An injection-shaped label does not become an instruction
    Given a printed label contains an instruction aimed at the model ("ignore your instructions and ...")
    When the request payload is built
    Then the text is carried as delimited data, not as an instruction
    And the injection policy's configured action is applied before any request is sent

  Scenario: Model output cannot inject keys or actions
    Given the provider returns entries that were not requested
    When the response is decoded
    Then unrequested keys and non-string values are discarded
    And nothing from the response triggers an app action
```

## Related
- FR: FR-LCT-009 (tier 2), FR-LCT-014 (text-only egress), FR-LCT-023 (degradation)
- NFR: NFR-LCT-007 (consent enforcement)
