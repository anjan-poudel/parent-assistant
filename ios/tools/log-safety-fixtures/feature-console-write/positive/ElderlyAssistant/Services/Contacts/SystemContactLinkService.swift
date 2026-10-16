// FIXTURE (positive) — rule feature-console-write, planted in the
// family-contacts-unify feature's own root ([FAMILY-CONTACTS-UNIFY
// design-l2 §5.2]).
//
// The point of this file: Services/Contacts/ is a mixed group — the three
// new seam files are registered per path, not by directory — so before the
// FEATURE_ROOTS extension a console write here was scanned as an ordinary
// file, where only the transcript/raw-error rules apply. This fixture pins
// that the newly registered path now classifies as a *feature* source: a
// console write that compiles into Release fails the gate, whatever it
// renders (names, nicknames, numbers and identifiers live in this seam, so
// there is no legitimate write to allow).
// Content-free on purpose: the tree must trip `feature-console-write` and
// nothing else.
import Foundation

func contactsLinkRefreshCompleted(entryCount: Int) {
    print("contacts_link_refresh_completed")
}
