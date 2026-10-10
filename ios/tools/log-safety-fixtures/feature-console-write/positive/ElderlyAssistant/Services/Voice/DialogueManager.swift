// FIXTURE (positive) — rule feature-console-write, planted in the
// multi-turn-conversation feature's own root ([MULTI-TURN-CONVERSATION
// T-138 / design-l2 §17]).
//
// The point of this file: the four dialogue sources live in the shared
// Services/Voice/ group, so before the FEATURE_ROOTS extension a console
// write here was scanned as an ordinary file, where only the
// transcript/raw-error rules apply — this fixture pins that the extended
// per-file roots now classify it as a *feature* source.
// Content-free on purpose: the tree must trip `feature-console-write` and
// nothing else.
import Foundation

func dialogueFrameArmed(attempt: Int) {
    print("dialogue_probe_spoken")
}
