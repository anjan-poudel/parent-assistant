# T-047: Catalogue comment reconciliation (brain default + STT hidden-list claims)

## Metadata
- **Group:** [TG-03 — On-Device AI](../index.md)
- **Component:** ModelCatalog comments (Services/ModelStore), AppCoordinator default-brain comment (App)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-046](T-046-chat-framing-per-offered-brain-id.md)
- **Blocks:** —
- **Requirements:** FR-007, FR-008

## Description

Doc-only truth-up of comments that no longer match the code at master `2061566`, plus a repo-wide sweep proving no stale claim about these models survives un-dispositioned. The named items:

- **(a) `ModelCatalog.swift:169-171`** — the `intentNepali1B` declaration comment (static id at 172) still describes the model as a pre-bake-off "PLACEHOLDER until the bake-off produces a release artifact", while the entry it labels (516-532) is a real, hosted, superseded v12 seed-42 artifact (displayName 519, filename 526, release-v12 URL 527). The entry's own comment (520-525) describes the seed-43 slim-template workload that now lives under `intentQwenS43` (entry 533-548).
- **(b) `ModelCatalog.swift:501-507`** — the hidden `llama3_2_1B` entry comment claims the model "is still the auto-download default (`AppCoordinator.defaultBrainModelID`)"; false since `af7e981` — the default is `intentQwenS43` (AppCoordinator.swift:1170).
- **(c) `ModelCatalog.swift:764-766`** — the hidden-STT rationale says the teacher-v2 fine-tune "never beat its own base on the FLEURS harness", while the catalogue's own entries record teacher-v2 at FLEURS WER 34.51 against the base's 39.63 (whisperKitNepali comment, 370-372) and repeat 39.63 (whisperKitNepaliLargeBase comment, 391-393); lower WER is better, so the comments contradict each other. The reconciliation must establish, per artifact (the GGML `whisperLargeV3NepaliV2` vs the ANE teacher), which claim the recorded eval evidence supports.
- **(d) `AppCoordinator.swift:1158-1167`** — the doc comment above `defaultBrainModelID` (1170) still describes LLaMA 3.2 1B Instruct Q4_K_M from bartowski at ~807 MB; the interior comment at 1168-1169 says "v12, seed 42". The actual default is the v14 seed-43 `intentQwenS43` entry (ModelCatalog.swift:533-548; URL 543, size 544, sha256 545).

The sweep also has known starting points beyond the four named items: the `availableBrainEntries` header calls the first entry "the v12 bake-off winner" (`ModelCatalog.swift:784-785`); the hidden-list comment (788-792) omits the superseded `intentNepali1B`, which is in `all` (516-532) but offered nowhere; `AppCoordinator.swift:1071-1075` still says "Until the bake-off artifact ships" on `localIntentInterpreter`; and `LlamaCommandInterpreter.swift:334` / `416` ("Phase-1 skeleton only", "MARK: - LoRA skeleton") are the skeleton-style claims the brief asks about. Each gets a disposition, none is assumed stale.

Comments are the only change: no behaviour, no constant values, no identifier or event-name renames, no test edits. Where the sweep finds that the code (not the comment) is wrong, the finding is recorded and routed as its own task; this task does not fix code.

## Acceptance criteria

```gherkin
Feature: Catalogue and default-brain comments match the code

  Scenario: Each named comment is reconciled against the current source of truth
    Given (a) the intentNepali1B declaration comment (ModelCatalog.swift:169-171) and the labeled entry (516-532)
    And (b) the llama3_2_1B entry comment claiming to be the auto-download default (ModelCatalog.swift:501-507)
    And (c) the hidden-STT rationale contradicting the FLEURS numbers recorded at 370-372 and 391-393 (ModelCatalog.swift:764-766)
    And (d) the default-brain doc comment and inline comment (AppCoordinator.swift:1158-1169) above the intentQwenS43 default (1170)
    When each is checked against the code it describes
    Then each receives a recorded disposition: comment corrected, or a defect finding (the code is wrong) routed with file:line and left uncorrected here
    And every corrected factual claim cites the actual id, entry, URL, size or sha256 it refers to (e.g. the v14 release URL at ModelCatalog.swift:543)
    And no claim is weakened, hedged with "may", or deleted to make the comment true

  Scenario: The repo-wide sweep is executed with a recorded method
    Given the sweep surfaces: ios/ElderlyAssistant/**/*.swift, ios/ElderlyAssistantTests/**/*.swift, docs/**, .ai-sdd/outputs/plan-tasks/** (both the project tree and the ai-sdd-claude example tree), ios/ElderlyAssistant/Resources/Localizable.xcstrings, README*, tools/train-intent/**
    And the stale-claim patterns: LLaMA-3.2-as-default (llama3_2_1B, "LLaMA 3.2 1B", bartowski, 807), v12/seed-42 (v12, "seed 42", seed-42, intentNepali1B), and placeholder/skeleton claims about these models (PLACEHOLDER, skeleton, "Until the bake-off", "not ready")
    When the sweep runs on the completed tree
    Then the record lists the exact search commands, every hit, and one disposition per hit: corrected comment, accurate as history (with the reason), or defect routed with file:line
    And the final re-run of the stale-claim patterns leaves no hit without a disposition

  Scenario: Comments are the only change
    Given the completed task's diff
    When a reviewer inspects it
    Then no executable Swift line, constant value, identifier, event name or test file is changed
    And any stale claim living in a non-comment string (e.g. an emitted event name) is recorded as a routed finding instead of edited
    And the existing unit gate result is unaffected because the change is comment-only

  Scenario: The fixed comments cannot drift back
    Given the reconciliation is complete
    When the stale-claim patterns are re-run
    Then no Swift comment claims LLaMA 3.2 1B is the auto-download default, no comment on the v12 entry claims the seed-43 workload, and the hidden-STT FLEURS claim is consistent with the numbers the catalogue records
    And the T-045 contract record and T-046 framing record remain the source of truth for the ids they verified; this task edits comments only, never those records

  Scenario: Scope is not duplicated from its neighbours
    Given T-045 verified the catalogue/default contract and T-046 determines framing per offered id
    When this task reconciles comments
    Then it consumes their determinations as inputs and does not re-derive, re-test or re-open them
    And it leaves the lane markers T-046 adds (if any) intact
```

## Implementation notes

- Evidence for each reconciliation at `2061566`: (a) entry facts ModelCatalog.swift:516-532 (v12 filename/URL/displayName) vs the seed-43 facts in the `intentQwenS43` entry 533-548; history `git show d19a8de`, `git show af7e981`. (b) default at AppCoordinator.swift:1170. (c) numbers at ModelCatalog.swift:370-372, 391-393, and the V2 entry comment 347-351 and 353-357; the eval record in `docs/OPEN-ITEMS.md:88-108` and `tools/train-intent/eval/results.csv` are the arbitration evidence. (d) entry facts 533-548.
- Sweep method must be reproducible: list the literal commands (`grep -rn` patterns per surface), the date/commit swept, and the hit table. "No hits" is a result only when the command and surface are stated.
- Plan artifacts under `.ai-sdd/outputs/plan-tasks/` are searched; completed-task records (e.g. T-045) and dated specs are dispositioned as accurate-as-history rather than rewritten. Both plan-trees are swept because the example tree mirrors the project tree.
- Non-goals: no code, no tests, no constants, no event-name changes; `docs/llm-spec-and-implementation-plan.md` and other dated design docs are historical and are dispositioned, not rewritten, unless they carry a live contract statement.
- iOS-only: the claims and files are iOS/Swift-side; there is no Android counterpart to sweep for these models (no brain catalogue or chat-format code under `android/`).
- Comment-only means the change must not alter runtime behaviour: after the edit, the same test suite outcomes hold. Running the aggregate iOS gate is optional for a comment-only diff; the reviewer verifies the diff contains no code lines.

## Definition of done
- [ ] All four named comments reconciled with file:line evidence; (c) arbitrated by the recorded eval evidence per artifact
- [ ] Repo-wide sweep executed across every listed surface with the exact commands, full hit list and a disposition per hit recorded
- [ ] Final re-run of the stale-claim patterns recorded, with no un-dispositioned hit
- [ ] Diff verified comment-only: no executable line, constant, identifier, event name or test changed
- [ ] Any stale non-comment string or code-wrong claim routed as its own finding with file:line (code untouched here)
- [ ] T-045's contract record and T-046's framing record left unedited; their determinations consumed as inputs
