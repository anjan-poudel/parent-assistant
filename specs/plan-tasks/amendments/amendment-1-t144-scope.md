# Plan amendment 1 — T-144 gate scope narrowed (2026-10-12)

Decision (parent session, owner speed directive): the T-144 sequencing gate's
blanket scope over T-145..T-165 is narrowed to the design's actual constraint —
L1 §16 / NFR-FCU-008 forbids parallel edits of the SHARED surfaces only:
`AppCoordinator.swift`, `LeafViews.swift`, wizard `SettingsView.swift`,
`CallingSettingsView.swift`.

**Unblocked now (file-disjoint with call-dialer's W3-W8 work, which touches
AppCoordinator/LeafViews/CallingSettingsView/MethodResolver + tests only):**
T-145 (done 5914777e), T-147 (done 4ffc9389), T-151, T-153,
T-148a (AddressBookDirectory half: `.limited` enum + `from(_:)` +
`allowsReading` + identifier additions + reading-protocol conformance +
`ContactsAccessTests` — no shared-file edits),
T-149, T-150, T-152, T-154, T-155 (each file-disjoint by construction).

CORRECTION (same day): T-148's unit spec itself marks it "Shared-surface unit:
runs only after T-144" — its per-site gate fixes (LeafViews/SettingsView/
AppCoordinator equality lines + `ContactsAccessGateTests`) are split out as
**T-148b** and stay gated.

**Still gated on T-144 (the call-dialer PR merge + master merge into this branch):**
T-148b (per-site gate lines), T-156, T-157, T-158 (AppCoordinator), T-159,
T-160, T-162 (SettingsView), T-161 (LeafViews), T-163, T-164, T-165.

Basis: design-l2 §16 union table — our edits to FamilyContactStore,
AddressBookDirectory, ContactResolver, UnifiedContactSearch, MissedCallContactResolver,
ContactPhotoStore, Localizable.xcstrings, Info.plist, check-release-log-safety.py and
the three new service files are disjoint from call-dialer's files by construction;
the T-144 merge will be conflict-free for them. Compile risk after the merge is
absorbed by T-163 (acceptance) and the merged-tree typecheck at T-144 itself.

Call-dialer status at amendment time: implement RUNNING in its worktree
(W2-W7 committed, W8 in progress, actively driven by another session — do not
touch that worktree).
