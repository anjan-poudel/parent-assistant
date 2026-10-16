// FIXTURE (positive) — rule feature-console-write, planted in the
// profile-interview feature's own root ([PROFILE-INTERVIEW T-104 / AM-4]).
//
// The point of this file: the step views live in a dedicated source the
// scanner must classify as a *feature* root (check-release-log-safety.py
// FEATURE_ROOTS). A Release console write that lands in wizard code used
// to be scanned as an ordinary file, where only the transcript/raw-error
// rules apply — this fixture pins that the extended roots close that gap.
// Content-free on purpose: the tree must trip `feature-console-write` and
// nothing else.
import Foundation

func profileStepSaved() {
    print("profile_step_saved")
}
