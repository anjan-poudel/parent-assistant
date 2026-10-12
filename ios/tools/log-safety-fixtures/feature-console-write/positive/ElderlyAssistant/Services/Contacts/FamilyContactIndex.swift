// FIXTURE (positive) — rule feature-console-write, planted in the
// family-contacts-unify feature's own root ([FAMILY-CONTACTS-UNIFY
// design-l2 §5.2]).
//
// The point of this file: the index holds names and normalized nicknames
// (household data), and it is a pure in-memory structure — it has no
// console diagnostic at all. This fixture pins that the newly registered
// path classifies as a *feature* source: a console write compiled into
// Release fails the gate, whatever it renders.
// Content-free on purpose: the tree must trip `feature-console-write` and
// nothing else.
import Foundation

func familyContactIndexBuilt(entryCount: Int) {
    print("family_contact_index_built")
}
