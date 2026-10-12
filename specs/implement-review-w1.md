# Implement review — Wave 1 (T-144 + T-155) — call-dialer-primary-secondary (final)

Paired challenger review, final pass after the F-1 rework. Revision: the uncommitted working tree of worktree elderly-ai-assistant-call-dialer-primary-secondary at base commit 7c1ba7da. Method: read-only re-derivation from the worktree — git diff and numstat, a mechanical hunk and change-block count, line-level reads of the reworked sentences, and independent reads of every source anchor they cite. No artifact was modified.

## Summary

Decision: GO

- History: the first pass returned NO_GO on exactly one MAJOR (F-1 — a newly introduced false clearing claim in the V-5 correction at design-l2.md:1149). The implementer reworked that sentence, its readers parenthetical, the consumer attribution, and the deregistration bullet at :1152. This pass re-derived all of it from the worktree; F-1 is resolved and F-2 is resolved by the corrected notes arithmetic.
- The rework is docs-only: design-l2 measures 21 insertions / 15 deletions over 13 hunks carrying 15 changed regions, and implement-notes carries the updated W1 row inside its already-added block. design-l1, Localizable.xcstrings and L10nCatalogCoverageTests.swift are byte-unchanged since the gate run (their mtimes precede the run start, same content as the reviewed revision), so no scoped re-run is owed.
- All mandated items from the first pass stand as verified: the M-1(a) row, the recovery attribution and the disposition (i) paragraph; the M-2 containment form at all four locations; V-1, V-2, V-3, V-4 in both halves, V-6; the five-key catalogue bound with parity, placement and placeholder contracts; the six new tests and the scoped gate evidence (16 executed, 16 passed, exit 0, all 16 confirmed as Passed in the result bundle). The retired phrase, the .facebook case name and the retired test name still grep empty in both records.
- Zero BLOCKER-class issues. Carried informational notes only: F-3 (gate-log stdout completeness), F-4 (Spotify pin red, pre-existing and outside ownership), F-5 (.ai-sdd bookkeeping), F-6 (the newly recorded shipped slot-liveness fact, an input for T-150).
- Confidence: 0.95 against the 0.85 threshold.

## F-1 — MAJOR — RESOLVED (was: the new false clearing claim at design-l2.md:1149)

What it was. The reviewed revision listed recordConfirmationTimeout as a writer with 'recordConfirmationTimeout → nil on expiry' and described it as 'reads the slot before clearing it', while the source only reads the slot — a falsehood introduced by the correction itself.

What changed. The writers clause now reads: writers = requestCallConfirmation (before the window opens), handleCallConfirmationOverride (amended action), and handleConfirmationResponse (→ nil before execution); on expiry the timeout path records the capture — recordConfirmationTimeout reads the slot (:10562), and the timeout closure clears the other pending slots (:3054-3066), not the call slot. The readers parenthetical now reads 'recordConfirmationTimeout (:10561-10569, which reads the slot)' — the false clearing clause is gone.

Independent re-verification against real source:
- Writers: requestCallConfirmation writes the slot at AppCoordinator.swift:7629; handleCallConfirmationOverride at :7675; handleConfirmationResponse nils it at :10612 before the yes/no switch. A re-grep confirms :10612 remains the file's only nil write of the slot, so the writers list is complete and accurate.
- Expiry: recordConfirmationTimeout reads the slot at :10562 and appends the capture; the timeout closure clears pendingConfirmationEntryId (:3054), pendingRephrase (:3055) and pendingAppLaunch (:3066) and never writes the call slot. The clause 'not the call slot' is source-true.
- Readers: confirmationPrompt, the override gate, isAwaitingCallConfirmation (:7553) and recordConfirmationTimeout (:10561-10569) are genuine readers; the call block reads and nils the slot at :10611-10612. Clean.

Consumer attribution (a precision carried beyond the prescribed sentence, inside the reworked sentence). The text now says isAwaitingCallConfirmation's consumers are CommandRouter.swift:1003 and :1017 via its coordinator protocol member CommandRouter.swift:60, plus the home confirmation chip at HomeView.swift:1207, and that the routing-busy check (:10717-10723) reads the slot directly at :10720. Source-verified: CommandRouter.swift:60 declares the requirement; :1003 and :1017 both consult coordinator?.isAwaitingCallConfirmation; HomeView.swift:1207 reads coordinator.isAwaitingCallConfirmation inside the ConfirmationChips chip handler (view header :1155, chip button :1188); and the busy property reads pendingCallAction directly at :10720, so it was never a consumer of the computed property — the new wording corrects that pre-existing misreading. VERDICT: ACCEPT — source-true, within the reworked sentence, strictly more accurate.

## F-2 — NOTE — RESOLVED (notes arithmetic)

The W1 row now reads: design-l2 13 hunks / 15 changed regions (21 insertions / 15 deletions; 14 regions were the reviewed revision, the 15th is the reviewer-sanctioned deregistration-bullet correction). Mechanically verified: 13 unified-diff hunks; 15 maximal change-blocks by an independent block count; numstat of 21 insertions / 15 deletions for design-l2 alone; and the one net-new region is the :1152 deregistration bullet (the :1149 shared-resource region was edited in place, and the two section-25 edits share a single hunk, which is why the hunk count did not move from 13). The evidence row now matches the diff exactly.

## F-3 — NOTE — carried (unchanged)

Gate-log stdout completeness: the per-case stdout lines for two of the sixteen cases — the calling and dialogue resolution tests (EveryCallingKey ResolvesInBothLanguages and EveryDialogueKey ResolvesInBothLanguages) — are absent from /tmp/l10n-gate.log while the suite summary reports 16 executed and the result bundle lists all 16 as Passed. Benign capture artifact, correctly recorded; no silent skip.

## F-4 — NOTE — carried (unchanged)

SpotifyLocalizationTests count pin: red by 8 at base (1,381 expected against 1,389 actual), 13 over after this unit's five keys. Correctly attributed as pre-existing and outside this unit's ownership; carry to the follow-up localisation evidence unit or T-157's audit so the red is reconciled rather than inherited silently.

## F-5 — NOTE — carried (unchanged)

Working-tree scope: .ai-sdd bookkeeping (workflow-state.json, tasks.jsonl, untracked workflow.yaml) is engine state outside the artifact surface under review; neither counted for nor against this wave.

## F-6 — NOTE — new observation, informational

The corrected deregistration bullet at design-l2.md:1152 now records as a shipped fact that an expired call window leaves the call slot pended (the timeout path records the capture and clears the other pending slots at :3054-3066, leaving the call slot pended). Source-verified true: there is no nil write on the timeout path, so isAwaitingCallConfirmation stays true after an expiry until a response or another write. The record is now truthful about this; no action is required for this document wave, and T-150's slot-liveness work — the reason the reader set is itemised in the same bullet — should treat it as a recorded input, especially when reasoning about the routing-busy check and the early-return removal.

## Re-verification scope statement

This pass re-derived: the design-l2 diff (all 13 hunks and 15 changed regions re-read line by line, no churn beyond the enumerated anchors), the numstat and hunk/region counts, the reworked sentences, the deregistration bullet and the notes row, plus every source anchor the reworked text cites (AppCoordinator.swift:7553, :7629, :7675, :10561-10569, :10562, :10611-10612, :10717-10723, :10720, :3046-3088, :3054-3066; CommandRouter.swift:60, :1003, :1017; HomeView.swift:1207). All other content of the first-pass review stands as reviewed; none of it changed in the worktree.

## Decision

decision: GO

F-1 resolved by the prescribed rework and verified against source; F-2 resolved; F-3 through F-6 are carried informational notes, none blocking. Zero BLOCKER-class issues, every in-scope mandatory item verified clean, confidence 0.95 against the 0.85 threshold. W1 (T-144 + T-155) is GO.