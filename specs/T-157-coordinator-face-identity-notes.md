# T-157 — Coordinator face identity, images and cache invalidation (notes)

**Feature:** family-contacts-unify (TG-31 write seam and coordinator integration)
**Branch:** `feat/family-contacts-unify` (worktree `elderly-ai-assistant-family-contacts-unify`)
**Commit:** `a8bc3986` (implementation; record commit follows this file)
**Date:** 2026-10-12
**Mode:** speed — implement + whole-module typecheck + commit only (scoped suite run, per-unit review and push deferred by the orchestrator)
**Design refs:** design-l2 §1.9 (coordinator face API), §4.3 (photo cache constants), §4.4 (identity-keyed tasks / stale-completion dropping / epochs), §5.2 (logging rules), §6.4 (source-scan pins), §8.1 (`contactPhoto(for:)` — DELETE), §8.2 (placement; ViewCaches doc-note row); design-l1 §10.1 (precedence resolver)
**Depends on:** T-156 (`6751cc50` — published identity state: `familyIndex`/`verifiedLinks`/`faceEpoch`/`systemPhotoTokens` + lazy link-service seam)
**Requirements:** FR-FCU-004 (one person, every surface), FR-FCU-007 (photo display precedence)

## What was built

### 1. `ios/ElderlyAssistant/App/AppCoordinator.swift` — the face surface

`import CryptoKit` added. The old sync `contactPhoto(for:)` resolver (and its
doc block) is DELETED per design §8.1; `ContactPhotoStore.load(named:)` is
retained — the app-local file read the coordinator now performs itself.

**`faceIdentity(for:) -> String`** (design-l2 §1.9) — `"<id>:<token>:<filename|->:<faceEpoch>"`:

- `token` = `systemPhotoTokens[contact.id]` when the contact has a verified/
  published link: the 16-hex sha256 prefix of the last-resolved system bytes;
  `"-"` when linked but not yet resolved (the design's literal); `"link-nil"`
  when there is no verified link;
- `filename` = `contact.photoFilename ?? "-"`;
- `faceEpoch` = the T-156 counter verbatim — it participates, so an epoch bump
  alone changes the identity and rotates every `.task(id:)` consumer.

**`faceImage(for:) async -> UIImage?`** and
**`faceThumbnail(for:diameter:displayScale:) async -> UIImage?`** — precedence
per design-l1 §10.1: (1) verified link → `SystemContactLinkReading.photoImageData(forIdentifier:)`
readable-access-gated read → decode → downsampled to `ContactPhotoStore.maxDimension`;
(2) app-local `photoFilename` via `ContactPhotoStore.load(named:)`; (3) nil
(caller renders the initials avatar). Never throws.

`resolvedSystemPhoto` (private) is the only place the token map is written:
`systemPhotoTokens[contact.id] = Self.systemPhotoToken(of: data)`, where
`static systemPhotoToken(of:)` = CryptoKit SHA256 → lowercase hex → 16-char
prefix, and `static systemPhotoCacheKey(identifier:token:)` =
`"sysphoto:<identifier>:<token>"`. All face methods are `@MainActor`, so
identity reads compose atomically per contact and the token map has a single,
main-confined writer (the "token map churn" failure scenario).

**Thumbnail cache routing (design-l1 §10.1 / design-l2 §1.9):**
`faceThumbnail` serves system faces through `DownsampledImageCache.shared.thumbnail(forKey: "sysphoto:<identifier>:<token>", …)`
and app-local faces through the existing `contactFace(for:diameter:displayScale:resolve:)`
(`contact:<filename>` family). Both families are content-addressed: new bytes →
new token → new key → cache miss; replaced/cleared file → new/absent filename →
miss or nil. A stale serve is impossible by construction, and `faceEpoch`
deliberately does NOT appear in these keys (see the interpretation note below).

**Interpretation (not a deviation): the "readable access" conjunct is delegated.**
The coordinator consults no `CNAuthorizationStatus`; the gate lives inside
`SystemContactLinkReading.photoImageData`, which returns nil without touching the
store when Contacts access is unreadable. Keeping real Contacts access out of the
coordinator is exactly what lets the full precedence pipeline be fake-driven in
tests (the fake scripts per-identifier bytes and nils).

### 2. Call-site migration — the four sync callers now use the async face path

Every former `contactPhoto(for:)` call site resolves through the face path with
a post-await identity re-check that abandons the assignment on mismatch
(design §8.1/§4.4 — cancellation is best-effort; the guard is the guarantee):

| Site | `.task(id:)` (file:line) | Post-await guard |
|---|---|---|
| Family list rows | `faceIdentities: [String]` — SettingsView.swift:1588 | :1600 `guard coordinator.faceIdentity(for: contact) == identity else { continue }` |
| Wizard stored photo | `storedFaceIdentity: String?` — SettingsView.swift:2002 | :2009 `guard … else { return }` |
| Call result rows | `resultFaceKey: [String]` (query + all identities) — LeafViews.swift:1027 | :1175 `guard … else { continue }` |
| ContactTile avatar | `coordinator.faceIdentity(for: contact)` — LeafViews.swift:2737 | :2746 `guard … else { return }` |

The list-shaped keys (`faceIdentities`, `resultFaceKey`) cover every row that
can show a face — a superset of the unit's per-contact key — and each row
re-checks its own captured identity after its await. The wizard no longer reads
a sync `storedPhoto` in `loadDraft()`; its `.task(id: storedFaceIdentity)`
resolves the stored face. Convergence: the first system resolve writes a token,
which changes the identity, which re-runs the `.task` once more as a cache hit —
bounded, matching §4.4's "exactly one extra resolve".

### 3. `ios/ElderlyAssistant/App/ViewCaches.swift` — invalidation contract (design-l2 §8.2)

Class doc gained the "Face key families and the invalidation contract (T-157)"
section: `contact:<filename>` and `sysphoto:<identifier>:<token>` families and
why content keys make every change a miss; explicit note that `faceEpoch` is
deliberately NOT in these keys (it re-triggers RESOLUTION via the identity-keyed
`.task`; cache validity is decided by content). `contactFace` doc now states its
app-local branch and points system photos to `thumbnail(forKey:)`. No API change.

### 4. `ios/ElderlyAssistantTests/App/CoordinatorFaceIdentityTests.swift` (new, 707 lines)

`@MainActor final class`, self-contained fakes: an in-memory
`ProfilePayloadStorage`, a `Gate` latch actor, and `FakeLinkService:
SystemContactLinkReading` (scripted per-identifier photo bytes, verifies-links
toggle, held/parked photo reads, read log). Eight tests:

1. `testFaceIdentityComposesIdTokenFilenameAndEpoch` — the pinned format through
   all four states: `link-nil` unlinked, `-` linked-unresolved, 16-hex token
   after a system resolve (recomputed independently with CryptoKit), filename
   clearing back to `-`; stability across repeat derivation; epoch participation
   via the foreground hook; an unlinked resolve never mints a token.
2. `testSystemPhotoWinsThenDegradesToTheAppLocalPhoto` — precedence on BOTH
   accessors: system beats app-local; link degradation (`link-nil`) serves the
   app-local file on both accessors; a re-verified record with no photo still
   degrades to the app-local file.
3. `testNoPhotoAnywhereReturnsNilAndNeverAnotherContactsFace` — nil from both
   accessors for a photo-less contact even after another contact's face filled
   every cache (no cross-contact leakage).
4. `testNewSystemBytesChangeTheTokenAndNoStaleThumbIsServed` — external byte
   change → new token → fresh thumbnail (no stale serve).
5. `testReplacingTheAppLocalFileChangesTheKeyAndTheFace` — file-name-keyed decode.
6. `testACrossAwaitIdentityChangeMakesTheCompletionStale` — parked system read;
   the link degrades mid-await and the epoch bumps; the parked completion
   returns the pre-change (red) face, the identity differs across the await
   (the premise of the guard), and a fresh resolve serves the local (blue) face
   — the value the call-site guards drop.
7. `testTokenAndCacheKeyAreHashShapedAndCollisionFree` — token equals the
   16-hex lowercase sha256 prefix recomputed independently; deterministic;
   distinct bytes → distinct tokens; `sysphoto:record-a:<token>` shape;
   `sysphoto:`/`contact:` families cannot collide.
8. `testFacePathWiringAndDeletionArePinnedAtTheSource` — source pins via
   `FeatureSourceScan` (comments stripped): the `@MainActor` face declarations,
   the literal identity format string, exactly ONE token-map write, the
   `sysphoto:` key literal, all four `.task(id:)` keys, exactly 4 post-await
   identity guards (2 + 2), ZERO code references to `contactPhoto(for` anywhere
   under `ElderlyAssistant/`, and the ViewCaches doc-note prose (raw file).

Suite registered in `ios/seniOS.xcodeproj/project.pbxproj` (manual groups — no
filesystem-synchronized groups): PBXBuildFile `A7F3C21D9E4B48A1B6C0D157`,
PBXFileReference `E2B4D6F80A1C4E3D9B7F5A21`, four occurrences each; `plutil -lint` OK.

## Verification (speed mode)

- **Whole-module typecheck: GREEN on the final tree.**
  `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant -destination "platform=iOS Simulator,id=14AE2228-4EC9-4CBE-A935-A50DF75A35E2" -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests`
  → `** TEST BUILD SUCCEEDED **`, exit 0, zero `error:` lines
  (`ios/build/t157-typecheck3.log` / `.exit`). Run 1 failed (2× `'async' call
  in an autoclosure` from awaits inside `XCTAssert`); fixed by hoisting every
  awaited call into a local. Run 3 compiled the final source — confirmed by
  object-file mtime (17:01:03) newer than the last source edit (16:59:48).
- **Deletion scan:** `grep -rn "contactPhoto(for" ios/ElderlyAssistant/` → 0
  hits (the only remaining occurrences are inside the test file's own
  anti-regression scan).
- **No PII in logs (NFR-FCU-002 / §5.2):** no logging was added anywhere in the
  face path; nothing prints identifiers or tokens.
- **pbxproj:** `plutil -lint` clean; 4 entries present.

## Interpretation flagged — spec line vs design keys

The unit spec says "Never cache face images without the epoch in the key"; the
design (l1 §10.1, l2 §1.9/§4.4) fixes the decoded-image cache keys as
`contact:<filename>` / `sysphoto:<identifier>:<token>` — no epoch. Both hold in
this implementation at different layers: every UI cache is TRIGGERED by a
`.task(id:)` whose key is the full `faceIdentity` (epoch included), so an epoch
change always re-resolves; the decoded-image cache beneath is content-addressed,
where a hit can be stale only if the content is identical — in which case the
hit IS the correct image. A live re-resolve after an epoch bump with unchanged
content is a cache hit, not a duplicate entry. Pinned by tests 4/5 plus the
ViewCaches doc-note scan.

## Deferred (speed mode, per assignment)

- Scoped suite run (`CoordinatorFaceIdentityTests`) — tests exist and compile
  (whole-module build-for-testing green) but were NOT executed in this mode.
- No `ViewCaches` XCTest suite exists anywhere in the test target (checked);
  the face suite's cache-key/no-stale-serve tests plus the ViewCaches doc-note
  source pins are the ViewCaches leg of the unit gate.
- Per-unit review; push (worktree-only commit, per assignment).

## Deviation — notes file name

The assignment's default path `specs/T-157-notes.md` is occupied by the
call-dialer feature's merged T-157 record (present on this branch's base,
merged via PR #171). Overwriting it would destroy a merged record, and doing so
on this branch would clobber it again at family-contacts merge time. This
unit's notes therefore live at `specs/T-157-coordinator-face-identity-notes.md`;
the unit identity is unambiguous from this header. Orchestrator may rename if
the harness requires the default path.

## Definition of done (unit spec)

- [ ] Code reviewed and merged — review deferred (speed mode); merge is the orchestrator's call
- [x] All Gherkin scenarios covered by automated tests — 3 happy scenarios
      (identity stability/epoch, precedence, cache invalidation) and both
      failure scenarios (nil fallback, token-map atomicity) map to tests 1/2/4/6
      and 3/8 above; execution deferred
- [ ] Unit gate green: focused face-identity suite + ViewCaches suite + typecheck —
      typecheck GREEN; suite run deferred (speed mode)
- [x] `faceIdentity` format pinned (`"<id>:<token>:<filename|->:<faceEpoch>"`) —
      runtime test 1 + literal-string source pin in test 8
- [x] Precedence + placeholder fallback pinned — tests 2 and 3 (both accessors)
- [x] No PII in logs — nothing logs identifiers or tokens
