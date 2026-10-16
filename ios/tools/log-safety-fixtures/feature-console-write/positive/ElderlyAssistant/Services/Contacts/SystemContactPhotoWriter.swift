// FIXTURE (positive) — rule feature-console-write, planted in the
// family-contacts-unify feature's own root ([FAMILY-CONTACTS-UNIFY
// design-l2 §5.2]).
//
// The point of this file: the write seam's diagnostics are bus events
// only; photo bytes, record identifiers and filenames must never reach a
// console. This fixture pins that the newly registered path classifies as
// a *feature* source — a console write compiled into Release fails the
// gate, whatever it renders.
// Content-free on purpose: the tree must trip `feature-console-write` and
// nothing else.
import Foundation

func contactPhotoWriteCompleted() {
    print("contacts_photo_write_completed")
}
