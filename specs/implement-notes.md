# Spotify Music Integration — Implementation Notes (T-106 … T-124)

- **Description:** Implementation record of the spotify-music-integration feature run — voice-requested music playback with both-provider search (Spotify preferred when linked and capable), caregiver account linking over a keychain-resident credential store, honest degradation on every path, and the release gates (release log-safety, the nine-obligation security evidence bundle, the device-validation protocol). All 19 units across 8 dependency waves are implemented and reviewed; this file records per-unit status, wave-review verdicts, gate evidence, and the owner/device items that remain open by design.
- **Feature:** spotify-music-integration (ai-sdd run, direct dispatch, unit_based execution in topological waves)
- **Branch and worktree:** feat/spotify-music-integration in the dedicated feature worktree; the main checkout was not used for task work.
- **Date:** 2026-10-07
- **Scope honoured:** iOS only; no router or brain model changes; no new backend; no cloud LLM on the music path; no emergency, medication or health surface changes; no secrets or real PII in any artifact (synthetic identifiers only).

## 1. Per-unit status (19 units)

| Unit | Title (short) | Wave | Status | Evidence summary |
|---|---|---|---|---|
| T-106 | SpotifyTool search and remote-play client | W1 | DONE | Search/play half plus the transport seam per design §24; the tool test count grew 30 to 39 across W1/W2. |
| T-107 | Deep-link grammar, hostile corpus, open probe | W2 | DONE | Open outcome pinned to the canOpenURL probe alone; URI construction is the sole allowlist point; 88 hostile identifier fixtures over 13 pinned categories plus 14 query fixtures, one named rejection assertion per entry; 20 deep-link tests. |
| T-108 | SpotifyCredentialStore (keychain-resident record) | W1 | DONE | The single encrypted session record lives in the keychain; store tests green. |
| T-109 | SpotifyAuthFlow (PKCE authorize, callback, refresh) | W1 | DONE | S256 PKCE, exact-match callback validation, exchange and refresh; the scope set is pinned by a tripwire test asserting nothing beyond the two shipped scopes. |
| T-110 | SpotifyAccountSession (link, refresh, unlink, status) | W2 | DONE | Exactly one record written on success, none on any failure; one bounded refresh with the 60s skew applied once at write; invalid-grant wipes the record, transport failure keeps it; unlink is local-only. |
| T-111 | Web-auth presenter and Info.plist declarations | W2 | DONE | The ASWeb presenter seam plus the plist declarations; the plist-seam test pins key presence and no stray whitespace. |
| T-112 | Keyword intent rule: music domain, markers, extractor | W1 | DONE | Music domain, markers, verb families and the music-query extractor; two fixtures re-seated as music fixtures per FR-SP-013. |
| T-113 | Contact-search music veto | W2 | DONE | The contact-search route vetoes music-domain turns. |
| T-114 | Query-free logging variant (M-1) | W1 | DONE | Log projection with explicit and query-free modes; defaulted parameters keep every existing call site unchanged; byte-identity pinned by a baseline capture test. |
| T-115 | Tool-log spotify kind and view mappings | W1 | DONE | The new spotify kind in the tool-log store plus the review-view mappings (C-4). |
| T-116 | Router music path: seams, matrix, intake, pins | W3 | DONE | Three dormant-nil seams (every pre-existing construction site untouched); a pure outcome selector encoding the 12-row state matrix; intake replaces the music stub arm and its spoken line; the tool-log contract (at most one spotify entry per music turn, query always empty, response only the exact terminal line); a single 401 retry, bounded at one. |
| T-117 | Localisation catalog: 20 keys ne/en | W1 | DONE | Includes the amended privacy disclosure copy (M-2). |
| T-118 | SpotifyPlugin and prompt fragment | W4 | DONE | The plugin at the pinned interface with the verbatim handle contract; degraded outcomes per the matrix; the prompt fragment trimmed per C-1. |
| T-119 | AppCoordinator wiring | W5 | DONE | Lazy services (first use, never at init); the observability bus passed by name; the presenter resolved at present time; the plugin registered once beside the YouTube plugin; wiring tests include a dormant fresh-install probe. |
| T-120 | Settings linking surface, unlink, disclosure | W6 | DONE | Settings route inserted after YouTube; status card with a total state mapping; confirm-then-wipe unlink observed on real storage; 14 surface tests; no credential field, no log lines. |
| T-121 | Release log-safety gate extension | W5 | DONE | Feature roots extended; the planted-violation demonstration was reproduced 7/7 by the paired review; clean gate, 24 fixtures over 12 rules. |
| T-122 | Golden-corpus supersession mechanics (C-3) | W4 | DONE | Supersession mechanics plus the pinned-surface guard. |
| T-123 | Security evidence bundle (nine obligations) | W7 | DONE — two pendings parked | O1..O9 each carry producer, verbatim command, recorded output and status; the machine-enforced completeness suite (8 tests) exercises the rejection path; exactly two PASS-partial pendings (O6: DV-7 device capture; O8: Dashboard registration), each naming its dependency, never an implied pass. |
| T-124 | DV-1..DV-7 protocol and record (FR-SP-017) | W8 | PROTOCOL DONE — EXECUTION PENDING (owner/device) | The protocol is authored with utterances, observables, pass/fail criteria, evidence fields, a build-identity block and capture discipline (NFR-SP-002). Every DV item is recorded BLOCKED with its named dependency; no device run has occurred and nothing claims otherwise. |

## 2. Wave log and review verdicts

| Wave | Units | Commit | Review verdict |
|---|---|---|---|
| W1 | T-106, T-108, T-109, T-112, T-114, T-115, T-117 | a198830 | GO — confidence 0.90 |
| W2 | T-107, T-110, T-111, T-113 + §19 plist closure | 44e9511 | GO — confidence 0.90 |
| W3 | T-116 | 2df57c4 | GO — confidence 0.90 |
| W4 | T-118, T-122 | 1dce327 | GO — confidence 0.90 |
| W5 | T-119, T-121 | f55e74f | GO — confidence 0.92 |
| W6 | T-120 | 3519a34 | GO — confidence 0.92 |
| W7 | T-123 | 4f6d4b1 | NO_GO as returned — all three findings (R1 major, R2 minor, R3 nit) were applied pre-commit and the freshness rule was re-run; the verdict conditions are met at the amended revision (post-review section of the review file) |
| W8 | T-124 | 31dd53e | GO — high confidence; all six non-blocking findings applied pre-commit |

Full detail: the eight wave-review files under `specs/` (`implement-review-w1.md` … `w8.md`), the per-unit notes (`specs/` `T-*-notes.md`) and the wave commit bodies.

## 3. Gate evidence

- Freshness run (final, consolidated): 13 suites, 268 tests, 268 passed, 0 failed (xcresult 2026.10.07 03-03-12; per-suite counts recorded digit-for-digit in the T-123 bundle).
- W7 re-gates after the post-review remediation: 8/8 twice with TEST SUCCEEDED (logs under `/tmp/`: `w7-regate.log`, `w7-regate2.log`).
- W8 gate: the security-evidence-index suite 8/8 green on the agent run and on the driver consolidated run after all writes.
- Release log-safety gate: clean (24 fixtures over 12 rules) with the planted-violation demonstration 7/7 (this is evidence for obligation 6).
- Known pre-existing red at the branch base (unrelated; re-verified by the W6 review): the LiveTranslate reachability unit test fails on master because the Home redesign replaced the entry's icon property. `HomeSubviews.swift` is byte-identical to the branch base and this feature does not touch Home — a known baseline red, not a regression here.

## 4. What changed (summary)

New, under the iOS app and test trees: the `Services/` `Spotify/` group (tool, transport, credential store, auth flow, account session, web-auth presenter); the Spotify plugin (`Services/` `Plugins/` `SpotifyPlugin.swift`); the Settings surface (`SpotifySettingsView.swift`); music-domain additions to the intent rules; the log-projection variant; the security-evidence-index suite, settings-surface tests and router-music tests.

Modified: `CommandRouter.swift` (plus 683 lines), `AppCoordinator`, the Settings views and tab mapping, the tool-log store and review view, the localisation catalog, `Info.plist` (client-ID key), the project file, the golden-corpus fixture surface, and the design and plan artifacts per their closure annotations.

Branch summary: 147 files changed, roughly 23.8k insertions, over the branch base e2e2ae0.

## 5. Security evidence obligations (T-123 bundle) — status

- O1 secret scan (vendored code and app images): PASS.
- O2 credential storage placement: PASS.
- O3 URI validator and parser pins: PASS (the device-console half is routed to O6).
- O4 query-free logging record: PASS.
- O5 hostile corpus counts: PASS (88 entries, 13 categories, 43 at exactly 22 graphemes, 14 query fixtures).
- O6 release log-surface gate including the DV-7 device capture: PASS-PARTIAL — the device half is pending the T-124 owner run.
- O7 disclosure copy versus data flow: PASS.
- O8 OD-S2 Dashboard registration: PASS-PARTIAL — pending the owner registration facts (accepted scheme, test-user emails, quota filing).
- O9 router pinned-surface guard: PASS.

## 6. Owner/device items parked (open by design — nothing below is claimed done)

1. DV-1..DV-7 execution on the owner's device against a Release build (FR-SP-017; simulator runs do not satisfy it). The record's §2 (device and build identity) and §6 (results) remain empty until the owner runs them. Checklist and steps: `specs/` `SP-device-validation-protocol.md` §2 and §3.
2. OD-S2 remaining owner facts: accepted-scheme confirmation (proven by DV-2's real link flow), registered test-user emails recorded at DV time, and the quota-extension filing (§3 row 7; draft at design-l2 §OD-S2 appendix).
3. O6 closes when the DV-7 device capture lands and has been inspected; O8 closes with the Dashboard registration facts.
4. final-sign-off (risk tier T2, owner) follows the above; it is not attempted anywhere in this record.

## 7. Honest coverage picture

- The implementation itself is complete and committed: every unit's code, tests and evidence artifacts are in the branch, and every wave passed its paired review (W7 after remediation).
- The only open items are the owner/device ones in section 6 plus the two allowed PASS-partial pendings in the bundle. No DV result is asserted, implied or fabricated anywhere in this record.
- The implement phase therefore stays open in the ai-sdd run until the device-validation results land and the record is completed; the phase close and the T-124 unit record are withheld until then.
