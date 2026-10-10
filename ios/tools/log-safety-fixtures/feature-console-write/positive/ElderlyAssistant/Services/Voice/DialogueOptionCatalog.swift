// FIXTURE (positive) — rule feature-console-write, planted in the
// multi-turn-conversation feature's own root ([MULTI-TURN-CONVERSATION
// T-138 / design-l2 §17]).
//
// The option catalog is one of the four dialogue files the gate must
// classify as a *feature* source; before the root extension a console
// write here was scanned as an ordinary file and the feature rules could
// not look at it.
// Content-free on purpose: the tree must trip `feature-console-write` and
// nothing else.
import Foundation

func catalogLoaded(optionCount: Int) {
    print("dialogue_catalog_loaded")
}
