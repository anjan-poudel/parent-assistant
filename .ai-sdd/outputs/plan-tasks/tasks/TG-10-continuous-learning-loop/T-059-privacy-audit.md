# T-059: Privacy Audit (verification)

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** End-to-end audit of the loop's data paths — the [T-056](T-056-capture-egress-implementation.md) capture/egress implementation, the [T-053](T-053-learning-loop-privacy-review.md) determination as the audit criterion, and the log boundary (`Services/Observability/LogSanitiser.swift`, `App/AppCoordinator.swift:7260-7278`)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-056](T-056-capture-egress-implementation.md)
- **Blocks:** —
- **Requirements:** NFR-015, NFR-016, NFR-032
- **Origin:** `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §5 (what leaves, what never leaves), R-3, R-6, R-8; the project's existing audit standard is T-049/T-050's `security-test` finding and remediation record

## Description

Produce the evidence — not the argument — that nothing raw left the device on any loop path, and that the opt-in is honest. This is a verification task: the deliverable is an audit report with reproducible evidence, and it is expected to try to *break* the claim rather than restate it.

**What must be proven, per design §5 and §11:**

1. **No raw transcript, audio, slot value or health value egresses.** The strongest available evidence is a byte-level inspection of the egress payload produced by the shipped serialiser from a record that *does* contain a contact name, a medication name and a message body. The audit must construct that record, drive the real path, and inspect the serialised bytes — inspected output, not an allow-list read off the source. If on-device execution is impractical in the audit environment, the report must say so and state the residual uncertainty rather than claim a device-level result.
2. **The opt-in is honest.** The consent state is genuinely consulted before capture/egress; the default state is off; revocation stops future egress and deletes not-yet-egressed signal; the visible indicator is present while active. Each claim is a test or a recorded observation against the shipped build.
3. **The telemetry boundary holds.** Any divergence/loop event that reaches a log sink carries only allow-listed, content-free values. `LogSanitiser` drops undeclared metadata keys (`:56-70`) and bounds `error_code` (`:106-122`); the audit must verify the loop's own events against those rules, and must verify that a content-bearing value passed through a *declared* key fails loudly rather than silently — the T-050 lesson (`LogSanitiser.swift:22-49`).
4. **The determination matches the implementation.** Every ruling in [T-053](T-053-learning-loop-privacy-review.md)'s determination — salt required, retention window, consent copy, what an opt-out deletes — is checked against what the code does. A deviation is a finding, classified as blocking or non-blocking.
5. **The policy text is true.** NFR-032 requires the in-app privacy policy to describe accurately what is collected and transmitted; the audit checks the shipped text against the shipped behaviour.

**Findings discipline.** Findings are numbered, evidence-bearing, and classified: BLOCKING (the loop's privacy claim is false as shipped), or NON-BLOCKING (documentation/drift). A BLOCKING finding blocks the loop's enablement — the same relationship the `security-test` NO_GO had to the release. The audit does not fix what it finds; fixes route to their owning task ([T-056](T-056-capture-egress-implementation.md) or a follow-up), which is the existing pattern (`final-sign-off` blocked on the security findings).

**Audit hygiene.** The audit's own artifacts must satisfy the standard they audit: no PII, no real secret, no full 40-character hash, sentinel placeholders only (the project has already tripped a secret scanner on a long opaque string — `tasks/TG-01-foundation-infrastructure/T-050-api-key-error-code-log-leak.md` records it).

## Acceptance criteria

```gherkin
Feature: Loop privacy audit — evidence that nothing raw leaves the device

  Scenario: The egress payload is inspected byte by byte on a content-bearing record
    Given a record containing a contact name, a medication name and a message body
    When the shipped capture/egress path serialises it
    Then the serialised payload is shown to contain none of those three values (asserted on the bytes, not on the source's field list)
    And the report states whether this was executed on-device or in a test environment, and the residual uncertainty if the latter

  Scenario: Every loop data path is enumerated and each is shown to leave the device or not
    Given the design's egress table (design §5.1: audio never, transcript never, slot values never, health never; ids/buckets/counters/salted hashes yes)
    When the audit enumerates every path the loop can write to (capture store, egress uploader, observability bus, any file the miner reads)
    Then each path has a verdict with evidence, and an unenumerated path is a finding rather than an omission
    And the audit checks the loop's own telemetry, not only the capture payload (design R-6)

  Scenario: The opt-in and opt-out are tested, not described
    Given recorded decision D-1 and the T-053 determination
    When the audit drives the shipped consent states
    Then it records, with evidence: capture/egress inactive before consent; active after consent with the disclosure shown; stopped and not-yet-egressed signal deleted after revocation; indicator present while active
    And any state where egress continues after revocation is a BLOCKING finding

  Scenario: The implementation is checked against the determination's specific rulings
    Given T-053's determination (salt ruling, retention window, consent copy, deletion semantics)
    When the audit compares it to the shipped code
    Then each ruling is marked MATCHED or DEVIATES, with the file:line evidence for the verdict
    And a deviation on the salt, retention or revocation semantics is classified BLOCKING

  Scenario: The log boundary holds for the loop's own events
    Given LogSanitiser's allow-list and bounding (LogSanitiser.swift:56-70, :106-122)
    And T-049/T-050 as the precedent for content reaching a log sink
    When the audit drives the loop's telemetry events through the shipped sanitised bus
    Then no transcript, slot value or health value reaches the output for any event the loop can emit
    And the report states whether a content-bearing value on a new, declared key would be caught by the boundary or must be prevented at the emitter — with the test that demonstrates the answer

  Scenario: NFR-032 policy accuracy is verified and the audit is PII-free
    Given NFR-032 (the in-app privacy policy must accurately describe collection and transmission)
    When the audit closes
    Then the shipped policy text is checked against the shipped behaviour, and any gap is a numbered finding
    And the audit report itself contains no PII, no secret and no full 40-character hash (sentinel placeholders only)
    And every finding is numbered, evidence-bearing, and classified BLOCKING or NON-BLOCKING, with its owning task named
```

## Implementation notes

- The audit criterion is [T-053](T-053-learning-loop-privacy-review.md)'s determination, not a re-derivation of it. Read it first, then the [T-054](T-054-capture-schema-egress-contract-design.md) payload contract, then the [T-056](T-056-capture-egress-implementation.md) implementation.
- This task is a sibling of the project's `security-test` posture: verification is a task, its findings are classified, and a BLOCKING finding blocks enablement rather than being logged and ignored (see `constitution.md:121-126` for how the project recorded the last set of blocking findings and their descope decision).
- Byte-level evidence matters here more than usual: the natural implementation mistake in this loop is "encode the `Record` and post it", and a field-list review would miss it. Assert on the serialised output.
- If the audit cannot run on a physical device in its environment, say so explicitly and scope the claim; the design's R-3 (hash re-identification) and R-8 (dishonest opt-out) are the two claims most likely to need device-level evidence, and an unverifiable claim must be recorded as UNVERIFIED rather than asserted.
- Do not modify production code from this task; every fix is routed. Keep the report's evidence reproducible (fixtures, commands, exact revisions at 12-character prefixes).
- No build, test or simulator commands are in this task's own scope only insofar as they are the audit's evidence-gathering; the canonical iOS gate is `./ios/build.sh test:unit` (T-050's DoD cites it) and the training-suite gates are the `eval_golden.py`/`run_encoder_pipeline.py` exit codes.

## Definition of done
- [ ] Audit report committed under `specs/` (T-059 notes) with numbered findings
- [ ] Byte-level egress evidence on a content-bearing record, with the environment stated and residual uncertainty named
- [ ] Every loop data path enumerated with a verdict; loop telemetry audited as well as the capture payload
- [ ] Consent lifecycle driven and recorded (off → on with disclosure → revoke with deletion), with any continuation a BLOCKING finding
- [ ] Each T-053 ruling marked MATCHED/DEVIATES with file:line evidence
- [ ] Log-boundary result stated with the test that demonstrates it
- [ ] NFR-032 policy text checked against shipped behaviour
- [ ] No PII, no secret, no full 40-character hash in the report; findings classified and routed to owning tasks
