# Security Design Review — Spotify Music Integration (STRIDE)

**Task:** `security-design-review` (contract `review_report`) · **Agent:** `reviewer` (direct dispatch)
**Feature:** `spotify-music-integration` · worktree `elderly-ai-assistant-spotify-music-integration` (branch `feat/spotify-music-integration`)
**Artifacts under review (the design chain):** `specs/design-l1.md` (623 lines, `architecture_l1`) and `specs/design-l2.md` (845 lines, `component_design_l2`); cleared by `specs/review-l2.md` (GO, six security carry-forwards).
**Workflow exit condition:** `review.decision == "SECURITY-GO"` (`specs/spotify-music-integration/workflow.yaml`).
**Date:** 2026-10-06.

**Basis.** Root `constitution.md` — Standards (Security: encrypted app storage, Data Protection Complete, TLS 1.2+, injection quarantine; Privacy: logs must not contain PII; release gates: the build-blocking `ios/tools/check-release-log-safety.sh` and the pre-release device console/sysdiagnose check) and Architecture Constraint 1 as amended 2026-10-06 (Spotify added to the permitted integrations; the amendment scopes it to search plus user-initiated playback hand-off and requires the account-linking discipline and the privacy disclosure). The B2/T-050 precedent (recorded in Open Decision 11) is the binding log lesson: raw Release prints and raw error bodies were the real defects. Feature constitution `specs/spotify-music-integration/constitution.md` (constraints 1–12, the amendment record, the routing/degradation contract). The requirement set — NFR-SP-002 (log safety), NFR-SP-003 (egress), NFR-SP-007 (encryption at rest), NFR-SP-008 (URI hardening), NFR-SP-009 (redirect + token lifecycle), FR-SP-008/009/010/016 — plus the workflow's six security focus areas and the design's own §21 STRIDE pre-map.

**Verification method.** Every claim this report makes about shipped behaviour was read from the worktree source, not taken from the design's summary. Independent measurements relied on from `review-l2` (prompt fragment sizes, the 15-entry golden music block, the 1,341-key catalog) are noted where used and not re-measured here.

**Read-only.** No artifact under review, workflow file or git state was modified; this report is the only file written (the deliverable path `specs/security-design-review.md`).

## Summary

**SECURITY-GO.** The design chain carries a real, largely verified security architecture for a new outbound integration with user account linking: **PKCE-only with no app-held secret anywhere** (the workflow's "bundled secrets are extractable" focus is answered by removing the secret from the device entirely); exact-match callback validation with a state nonce and the PKCE verifier; a single encrypted session record in the Keychain's explicit resident set with defined refresh bounds and wipe semantics; a validated 22-character base62 identifier grammar before any URI construction, titles never in URIs, percent-encoded query components, a `spotify:`-only construction allowlist, and a named hostile-corpus suite; a content-free log contract for the feature's own entries (empty query, empty response on success, product calls; events with closed vocabularies and empty metadata, so no `LogSanitiser` allow-list change) with the release gate extended over the three new feature roots; an honest local-wipe unlink that never claims a remote revoke Spotify does not offer; and a Settings privacy surface.

Eight surfaces were threat-modelled (the six workflow focus areas plus cross-cutting availability and least-privilege). **Assessment counts: 8 surfaces, 0 BLOCKERs, 3 must-fix conditions (M-1…M-3), 4 verify-and-record items (V-1…V-4), 9 evidence obligations for `security-test`, 6 accepted residuals.** No finding requires an architecture change; every residual is either contained by a verified existing control or is a concrete, testable change.

**The three must-fix conditions, none architectural.** **(M-1)** Every YouTube fallback leg reused by the music path (`fireYouTubePlay`, `deliverYouTubeFailure`) writes the request text into the encrypted tool log, contradicting NFR-SP-002 ("music query text … must not reach any log … or diagnostic surface") and the design's own "no query text reaches any log" claim (§21/§33); the fix is a query-free logging variant on the reused call, pinned by the design's own tool-log test. **(M-2)** The privacy copy must state playback activity, not only search (FR-SP-016's acceptance criterion names both). **(M-3)** The sign-in scope set must be trimmed to scopes with call sites (least privilege) before the Dashboard registration, or the call site recorded. Details in the surfaces and the conditions section.

### Verification ledger (design claim → source checked → verdict)

| # | Claim under review | Source read | Verdict |
|---|---|---|---|
| 1 | Seams exist at `CommandRouter.swift` 646–648, defaulting nil at 689–691, assigned at 709–711; the dormant-seam pattern holds | `Services/` + `Voice/CommandRouter.swift` | Holds; mirrors the YouTube pattern exactly |
| 2 | Music stub at 2640–2643 (`case .music:`, `command_music_stub`, `router.musicStub`) | same | Holds (event 2642, speech 2643) |
| 3 | `fireYouTubePlay` at 2386; keyless path opens the search deeplink; failures via `deliverYouTubeFailure` | same | Holds; **the keyless path and the failure path both log the query** (see M-1) |
| 4 | `logToolRequest` at 2544 (nil store = no-op; encrypted store only) | same | Holds (2544–2552) |
| 5 | `handlePluginCommand` at 2922; ladder sites 898/1146/1189; registration at `AppCoordinator.swift` ~2058; construction ~3704–3717 | same + `App/AppCoordinator.swift` | Holds |
| 6 | The OAuth precedent is `GoogleAccountSession` (scopes at sign-in via `addScopes`, tokens kept in the Keychain, no storage of its own) | `Services/CalendarSync/` + `GoogleAccountSession.swift` | Holds (the SDK keeps its Keychain entry; the addScopes lesson is documented in source); the new flow inherits the discipline, not the SDK mechanism — its store is C-SP-02, correctly |
| 7 | `EncryptedLocalStorage` seam and `StorageError` cases | `Services/MedicationScheduler/` + `DependencyProtocols.swift` | Holds (`encryptedWriteFailed`, `encryptedReadFailed` — exactly two cases) |
| 8 | `keychainResidentKeys` is a short, explicit, reviewed set; everything else defaults to the encrypted file | `Services/Storage/StoragePlacement.swift` | Holds; the planned `spotify.session` addition is the deliberate tripwire (`StoragePlacementTests` set equality) |
| 9 | Keychain class is device-only when-unlocked; file class is complete-file-protection | `Services/Storage/` + `KeychainEncryptedStorage.swift`, `EncryptedFileStorage.swift` | Holds |
| 10 | `CallLinkOpening` already has `canOpenURL` + `open`; "no seam change" needed | `Services/Intents/CallLinks.swift` | Holds, with one precision item (V-4): the shipped `open` returns Void, so the design's `OpenOutcome` derives from the `canOpenURL` probe |
| 11 | The release gate really has `FEATURE_ROOTS` and per-rule fixtures; the four feature rules are fixture-covered | `ios/tools/check-release-log-safety.py`, `.sh`, fixtures harness | Holds. Rule scoping re-verified: rule 1 is judged for every role; rule 2 for engine files only; rules 3–6 for feature roots only — design-l2 §20's "rules 1–2 apply to every file" sentence is imprecise (review-l2's C-2, carried) |
| 12 | `Info.plist` precedents (public client ID `GIDClientID`; one `CFBundleURLTypes` entry; `LSApplicationQueriesSchemes`) and `Localizable.xcstrings` has 0 spotify keys yet | `Info.plist`; `Resources/Localizable.xcstrings` | Hold |
| 13 | `LocalToolLogStore.Kind` is weather/search/youtube, and the store's query field is documented raw user speech kept because the store is encrypted on-device (C9) | `Services/` + `Voice/LocalToolLogStore.swift` | Holds; this is the containment basis for M-1 |

### Assets, trust boundaries and data flows

| Asset | Where it lives | Sensitivity |
|---|---|---|
| Access token, refresh token | `SpotifySessionRecord` under the one key `spotify.session`, Keychain-resident (device-only, when-unlocked class) | High: transferable credential for the household account |
| Client ID (`SpotifyClientID`) | `Info.plist` + the authorize URL | Public by definition; not a secret |
| PKCE verifier, state nonce | Process memory for one link attempt; discarded after exchange | Per-attempt secret; one-shot |
| Music request text (query) | Memory → provider API request; **and the encrypted tool log on the paths that reuse the YouTube legs (M-1)** | User speech; disclosed for the Spotify search purpose |
| Track title (provider-controlled) | Spoken once via `spotify.playing`; never carded, never logged, never in a URI | Remote-controlled content; TTS only |
| Redirect scheme registration | `Info.plist` `CFBundleURLTypes` + Dashboard | Claims a URL scheme; not a credential |
| Log surface | Console/telemetry (must stay content-free) + the encrypted tool-log store (Settings review view) | Must stay content-free for this feature's entries |

Trust boundaries: **B1** the caregiver-driven link flow (user-interactive, `ASWebAuthenticationSession`); **B2** the encrypted session store (readable only with the app's key material, device unlocked); **B3** egress — exactly `accounts.spotify.com`, `api.spotify.com`, plus the pre-existing YouTube endpoints, nothing else; **B4** the log boundary (console, telemetry, encrypted tool log; the release gate is the build-time backstop, DV-7 the device-time evidence); **B5** the provider boundary — Spotify responses, including track IDs and titles, are untrusted input.

## STRIDE threat model

### Surface 1 — OAuth token lifecycle (focus 1)

Data flow: caregiver → authorize URL (all scopes at sign-in, S256 challenge, fresh state) → system browser → callback (exact-match validation) → token exchange (verifier only, no secret) → `/v1/me` verification (200 + granted-scope check) → one Keychain record → per-request `validAccessToken()` (at most one refresh) → unlink or revocation wipe.

- **S — spoofed callback / forged grant.** Mitigation: state nonce, exact redirect match (scheme/host/path), PKCE S256 with the verifier held only in this device flow; any mismatch stores nothing and logs no value (design §11 callback matrix; `SpotifyAuthFlowTests`). Residual: scheme co-registration (surface 4), DoS-grade only. **Ruling: accepted.**
- **S — fake "connected" state.** Mitigation: verification before first trusted use; the status is derived from the single store; L2-D5/L2-R2 store-nothing semantics remove the split-brain risk between `isLinked` and routing. **Ruling: accepted.**
- **T — token-record tampering / partial writes.** Mitigation: one Codable record, single-key atomic write; a failed write leaves the previous record; a failed clear is surfaced, and the status flips only on a confirmed wipe. **Ruling: accepted.**
- **T — refresh-token rotation.** Mitigation: "retained or rotated per the response" persisted on the successful-refresh path (same record write). **Ruling: accepted.**
- **R — linking/unlink audi.** Mitigation: content-free `spotify_link`/`spotify_unlink` events (outcome + case name only); single-household device, no per-person attribution owed. **Ruling: accepted.**
- **I — token disclosure.** Mitigation: header-only credential (never a URL, query parameter or deeplink); Keychain-resident storage; no token/code/verifier/state in any log or event; the gate's feature roots make any console write in the new files a build failure; DV-7 is the device-time check. Residual: none for credentials; the query-text residual is M-1 (not a credential). **Ruling: accepted.**
- **D — refresh loops / dead-grant hammering.** Mitigation: one refresh attempt per request; `invalid_grant` wipes and takes unlinked treatment; transport-only failure takes the search-failure shape; a second 401 on play wipes; the 300 s link-flow bound cancels to a defined outcome. No loop, no hang. **Ruling: accepted.**
- **E — credential extraction / privilege.** Mitigation: no app-held secret exists (surface 2); music playback is not a sensitive-command class under the constitution (calls, health access, config changes are), so no biometric/PIN gate is owed or added; the recorded OD-S1 contingency (family-entered credential) is not built, and the design states it would require a design-l2 change plus a security re-run. **Ruling: accepted** (contingency activation is a condition on any future change).

### Surface 2 — Client-secret handling (focus 2; OD-S1 resolution)

- **Threat: an app-held client secret, extractable from the binary or the device.** The design has no secret anywhere: public client, client ID public, search on the linked user's access token, the client-credentials flow (the only secret-requiring flow) unused, no credential field on the Settings surface, and the Dashboard checklist explicitly says the secret is not used and must not be pasted anywhere. The alternative was real — the Keychain `search.apiKey` precedent exists and is what the contingency records — and the resolution's rationale (bundled secrets are extractable; PKCE removes the secret from the device entirely) is sound for an iOS public client. Residual: none shipped. Verification owed: a built-artifact scan for secret-shaped values and for any `client_secret` usage (security-test obligation 1). **Ruling: accepted** — this is the strongest available answer to the focus area.
- **Search-on-user-token soundness.** `/v1/search` with the linked user's token is the documented pattern; the same authorization also yields the playback-control scope, so one flow serves both surfaces; the design's verifiability note (S256 challenge on the authorize URL, `code_verifier` on the exchange, no secret field in the form body) matches the interface in §26. **Ruling: accepted.**

### Surface 3 — Deep-link / URI injection (focus 3)

- **T — a hostile provider result crafts a URI or an arbitrary scheme open.** Mitigation (verified interfaces): `isSpotifyIdentifier` accepts exactly 22 base62 scalars and returns nil otherwise, so no partial URI can be built; titles are spoken-only and never a URI component; query components are percent-encoded with the delimiters removed from the allowed set; the tool constructs only `spotify:` URIs (plus the pre-existing YouTube shapes on the fallback leg, which the tool never builds); the play body carries only the URI the tool itself built from a validated id. The corpus suite (scheme text, `//`, quotes, control characters, traversal, over-long, percent-encoded traps, lengths 0/21/23, non-base62) is enumerated in §22 and proves the property; `testNoEgressBeyondThe` + `ProviderAllowlist` pins the hosts. The gate is a static backstop with documented limits, and the design correctly relies on runtime validation plus the corpus as primary. **Ruling: accepted** (corpus is a named evidence obligation).
- **I — request text in a URI or open.** The `spotify:search:` hand-off percent-encodes the user's own query, capped at 100 characters; no remote content; no web fallback chained after a failed open. **Ruling: accepted.**
- **D — spoofed or unbounded opens.** Single-shot opens; `canOpenURL` probed before `open`; a failed probe is terminal (honest line), never a chained open. Residual (minor): a hostile, very long title is read by TTS — parity with the shipped YouTube title discipline; no URI, log or egress involvement. **Ruling: accepted.**

### Surface 4 — OAuth redirect validation and the scheme-hijack residual (focus 4)

- **S — app-scheme callback hijack (token interception).** Mitigation: exact-match validator (scheme/host/path + state + code presence) independent of the scheme string; PKCE S256 so an intercepted code is not exchangeable without the verifier; `ASWebAuthenticationSession` owns the redirect detection and returns the callback to the initiating session, so a co-registered scheme handler does not receive that in-session redirect; nothing is stored or logged on any rejection (FR-SP-008 scenario 3). Residual: another app registering the scheme can degrade a link attempt (DoS / a blank link), not steal a token; a third party can launch the app via the scheme, but there is no app-level callback handler outside a live link attempt and the validator requires the in-memory state nonce. **Ruling: accepted (residual recorded).**
- **Dashboard acceptance contingency (design gap 2 / review-l2 carry-forward 2).** If the Dashboard refuses the custom scheme, only the shared constant's value changes (for example the SDK-style reversed form); the validator, its tests and the plist entry move together; no security property depends on the string. **Ruling: accepted; verify item V-2** (confirm the accepted value at registration and record it).

### Surface 5 — Log sanitisation (focus 5)

- **I — credentials, queries or provider bodies reaching logs.** Designed contract, verified against the seams it rides: the feature's own tool-log entries carry the query as empty always; response empty on ok and the static spoken line otherwise; status from the last HTTP response; never a title, id, token or provider body. Events are component `spotify`/`plugin_spotify` with `metadata: [:]` and closed outcome vocabularies, `errorCode` a case name only — so no `LogSanitiser` allow-list change is needed or made. The new files gain `FEATURE_ROOTS` entries (`Services/Spotify/`, `Services/Voice/SpotifyTool.swift`, `Services/Plugins/SpotifyPlugin.swift`) where any console write in any configuration fails the gate, and rules 4–6 catch content-bearing event fields; the fixture harness requires a positive and a negative fixture per rule, all of which exist. The rule scoping caveat (rules 3–6 are feature-roots only; the new code inside shared files relies on rule 1 plus review) is the project's established position. DV-7 (console/sysdiagnose capture during DV-1…DV-6) is concrete and testable — the proof is the recorded `specs/SP-device-validation-protocol.md` capture. **Ruling: accepted, with the residual below.**
- **M-1 (must-fix, carried to plan-tasks as a blocker task): the YouTube fallback legs write the request text into the encrypted tool log.** Verified in source: `fireYouTubePlay` (2386) and `deliverYouTubeFailure` (2482) call `logToolRequest` with the raw query — the keyless path (2396–2413), the keyed success path (~2440), and the failure path (2488). The design reuses `fireYouTubePlay` verbatim on every fallback or terminal row for a music request (ADR-SP-06 / L2-R1; matrix rows 4/6/7/8, keyed and keyless), so the music request text lands in the encrypted tool log's `.youtube` entry — an on-device diagnostic surface shown in Settings → Tool requests. NFR-SP-002 says music query text must not reach any log or diagnostic surface; the workflow focus repeats it; ADR-SP-15's own rationale deliberately chooses the strict reading over the YouTube raw-query habit; and design-l2 §21/§33 claim "No query text … reaches any log". As designed, every music turn Spotify cannot serve contradicts that claim. Existing containment: the store is encrypted on-device (complete file protection), never egressed, and the text is the user's own speech (the C9 convention for the YouTube tool) — which is why this is a must-fix and not a blocker. Concrete fix: give the reused fallback call a logging-only parameter defaulting to current behaviour (explicit-YouTube entries keep their shape; the spoken and routing outcome stays byte-identical to today) and have the music-intent path pass the query-free variant; extend the design's own pin (`testToolLogEntriesCarryNoQueryOrTitle`) across every entry written during a music turn. If the team instead chooses to scope NFR-SP-002 away from the encrypted tool log, that is an owner-visible requirement-scoping decision, not an implementer's choice. **Ruling: must-fix.**
- **Residual accepted (recorded): shared-file hunks outside rules 3–6.** New code inside `CommandRouter.swift` and the other pre-existing files is not a feature root; a raw print placed there escapes rules 2–6 (rule 1 still catches transcript-derived prints). This is the project's established position (the profile-interview SD-4 record; the gate's own documented static-analysis limits), mitigated by the no-console-writes rule for the new paths, the paired review, and DV-7. **Ruling: accepted with those mitigations named.**

### Surface 6 — Privacy disclosure (focus 6)

- **I — the data flow is not disclosed.** The flow: when linked, the request text goes to Spotify search; play commands and the track URI go to the playback API; results, including titles, come back; the token identifies the household account. The Settings surface carries `spotifySettings.privacy` in both languages, mirroring the YouTube disclosure shape, and the design records the amendment obligation plus the release/privacy entries. **Ruling: accepted in shape.**
- **M-2 (must-fix, carried): the copy must name playback activity.** FR-SP-016's acceptance criterion is explicit — the disclosure states "that music queries and playback activity are sent to Spotify". The current copy ("What you ask for is sent to Spotify to find the music; nothing else is sent.") covers search but not playback activity, and its second clause can be read as excluding the play commands the remote-control path sends. Concrete fix: amend the `spotifySettings.privacy` ne/en values to name both (requests, including play commands, are sent to Spotify to search and control playback; no other app data is sent); the copy is already the owner sign-off artifact, so amend before sign-off. Proof: the FR-SP-016 scenario in `security-test` plus catalog inspection in both languages. **Ruling: must-fix.**
- **I — undisclosed egress.** None: only the two Spotify hosts plus the pre-existing YouTube endpoints; no cloud LLM on the music path; the YouTube fallback's existing disclosure is unchanged. **Ruling: accepted.**

### Surface 7 — Cross-cutting: denial of service and availability

- **D — unbounded waits, retries, provider rate limits.** All bounds are named parameters with injected defaults (8 s fetch, one refresh, the 10 s/16 s budget assertions, 100-character caps, 300 s link flow); searches and opens are single-shot; the concurrent legs are joined and bounded; rate-limit and error responses degrade to the honest line. **Ruling: accepted.**
- **D — turn overlap.** Parity with the existing YouTube stage (a new turn supersedes, no cancellation); one spoken outcome per attempt; no shared mutable state (main-actor confinement; stateless tool). **Ruling: accepted** (existing behaviour, recorded).

### Surface 8 — Cross-cutting: elevation of privilege / least privilege

- **E — over-broad scopes.** The requested set is `user-read-private`, `user-read-playback-state`, `user-modify-playback-state`. Verification uses `user-read-private` (`/v1/me` product); control uses `user-modify-playback-state`; the design deliberately does no device management and reads no playback state (play success is judged from the 2xx), so `user-read-playback-state` has no call site in this design. **M-3 (must-fix, carried):** before the Dashboard registration is finalised (OD-S2 step 3) and before the quota-extension filing (a later scope change re-opens review by the plan's own criterion), either identify the concrete call site that uses the read-playback scope or drop it from `SpotifyAuthFlow.scopes` and the Dashboard list; pin the final set in the authorize-URL assertion (`SpotifyAuthFlowTests`). **Ruling: must-fix (least privilege).**
- **E — deep-link open privileges.** The tool is the only new caller of the opener seam, and it opens only URLs it built after validation (surface 3). **Ruling: accepted.**
- **E — sensitive-action gate.** Music playback is not a sensitive-command class under the constitution (calls, health access, config changes are), so no auth change is introduced or owed; recorded as consistent with the existing descope (B3), which is outside this feature's scope. **Ruling: fine (noted).**

### OD-S2 — dev-mode rollout: security exposure statement

**No security exposure arises from the OD-S2 plan itself.** The draft narrows access (registered test users only) rather than widening it, unregistered accounts degrade honestly with no code-path difference, and the quota extension changes availability, not capability. The owner decision therefore needs no security condition beyond hygiene already in the plan: (i) registration must not introduce a secret (the plan already states the Dashboard secret is not used; the only plist value is the public client ID); (ii) the final scope set is fixed per M-3 before filing; (iii) the accepted redirect scheme is confirmed and recorded per V-2 when the registration actually happens; (iv) the roll-out note copy and the (M-2-amended) privacy copy are the owner sign-off artifact.

## BLOCKERs

**None.** Every threat above has a mitigation in the design or a concrete, testable change carried as a condition (M-1…M-3, V-1…V-4). No finding requires an architecture change.

## Conditions carried to plan-tasks / implement

**MUST-FIX — record as task blockers in plan-tasks:**
1. **M-1 (tool log, fallback legs).** Add the query-free logging variant to the reused YouTube fallback call for music-intent turns (default behaviour unchanged for explicit YouTube; spoken/routing outcome byte-identical); extend `testToolLogEntriesCarryNoQueryOrTitle` across every entry written during a music turn (rows 4/6/7/8, keyed and failure paths).
2. **M-2 (privacy copy).** Amend `spotifySettings.privacy` (ne + en) to state that requests, including play commands, are sent to Spotify for search and playback, and that nothing else is sent; amend before the owner sign-off on the copy table; verify with the FR-SP-016 scenario in `security-test` and the catalog check.
3. **M-3 (least privilege).** Trim or justify `user-read-playback-state` before the Dashboard registration and the quota-extension filing; pin the final scope set in `SpotifyAuthFlowTests`.

**VERIFY-AND-RECORD:**
4. **V-1 (revocation claim).** The design states Spotify exposes no third-party token-revocation endpoint and FR-SP-010/NFR-SP-009 say "revokes upstream where supported". Verify the claim against Spotify's current documentation at implement time and record the result; if a documented revocation endpoint exists, wire it best-effort behind `unlink()` (bounded, never blocking the local wipe, never claiming more than it did).
5. **V-2 (scheme acceptance).** Confirm the registered redirect scheme is accepted at Dashboard registration; if re-shaped, move the single constant, the plist entry and the tests together; the exact-match validator is untouched.
6. **V-3 (provider error vocabulary).** Constrain the callback `error` value to the OAuth error registry (unknown values to a generic case) so no free-form provider text is carried in `SpotifyAuthError`; it is already never logged or displayed — this pins it. Test in `SpotifyAuthFlowTests`.
7. **V-4 (`OpenOutcome` semantics).** The shipped `open` seam returns Void; pin that `.opened`/`.notOpened` derives from the `canOpenURL` probe and that `spotify.appMissing` is spoken only when the platform probe says the app is absent, so the line stays tied to an observed condition.

**Carried review-l2 conditions remain:** C-1…C-4 (fragment-size contradiction, gate-scope sentence, golden-count wording, the tool-log icon case); none has a security dimension beyond their documented scope.

**Deferrals verified concrete and testable:** the hostile-URI corpus (enumerated cases in §22; proof: `SpotifyToolTests` + the NFR-SP-008 scenarios); the DV capture (proof: the recorded `specs/SP-device-validation-protocol.md` with the console/sysdiagnose result, DV-7); the callback accept/reject matrix (proof: `SpotifyAuthFlowTests`); the OD-S2 quota-request appendix (drafted in §23 with every owner value marked).

## Evidence obligations for security-test

1. Built-artifact scan: no secret-shaped value, no `client_secret` usage; the authorize URL carries `code_challenge_method=S256`; the exchange carries `code_verifier` only; the Settings surface has no credential field.
2. Token storage: `spotify.session` Keychain-resident placement test, relaunch read-back, and a wipe sweep after unlink (nothing recoverable).
3. Callback matrix: mismatched redirect/state/host/path rejected with nothing stored and nothing logged (console captured).
4. Refresh/revocation: one refresh per request; `invalid_grant` wipes; second 401 wipes; no loop.
5. Hostile corpus: zero non-allowlisted URI constructions/opens; titles never in URIs; rejected identifiers resolve to honest lines.
6. Log surface: the gate exits 0 over the new roots; the DV-7 console/sysdiagnose capture over linked/unlinked/failure paths contains zero tokens, queries or provider bodies; the M-1 fix holds (no music-turn entry carries the query); events carry empty metadata.
7. Disclosure: `spotifySettings.privacy` (ne/en) states queries and playback activity (M-2).
8. Scopes: the authorize-URL scope set equals the scopes actually exercised (M-3).
9. Egress: per-flow request hosts within `accounts.spotify.com`, `api.spotify.com` and the pre-existing YouTube hosts; no other host.

## Accepted residuals (explicit)

1. **Scheme co-registration:** DoS-grade (a link attempt can be degraded), no token transfer — PKCE plus in-session redirect detection plus exact-match validation.
2. **No remote revocation:** the local wipe is the guarantee and the design never claims otherwise; a provider-side grant survives until the user revokes it in their Spotify account — verify item V-1.
3. **Shared-file hunks outside gate rules 3–6:** mitigated by the no-console-writes rule, the paired review and DV-7 (project precedent, gate limits documented).
4. **Music request text in the encrypted tool log on fallback legs:** contained on-device (encrypted, complete protection); the remedy is M-1; if the team instead scopes NFR-SP-002 away from the encrypted tool log, that scoping must be recorded as an owner-visible requirement decision.
5. **Stale `product` capability:** bounded by the play attempt's honest 403 catch; worst case one extra deep-link hand-off, never a false claim.
6. **Long hostile title read by TTS:** YouTube-parity residual; no URI, log or egress involvement.

## Decision

decision: SECURITY-GO

**Rationale.** The design chain carries a real and independently cross-checked security architecture for a new outbound integration with account linking. The client-secret focus is answered categorically (PKCE-only; no secret shipped or stored); token custody, redirect/state validation, refresh bounds and wipe semantics are concrete and testable; URI construction is grammar-validated with an allowlisted scheme and a named hostile corpus; the feature's own log entries are content-free with the release gate extended over the new roots; and the privacy surface exists with one copy amendment owed. No blocking finding was identified — every residual is contained by a verified existing control or is one of the three mechanical must-fixes (M-1 tool-log fallback text, M-2 playback-activity disclosure, M-3 scope least-privilege), each of which becomes a plan-tasks blocker and a `security-test` evidence obligation. The OD-S2 draft creates no security exposure requiring a condition on the owner decision. All conditions and evidence obligations above are mandatory for `plan-tasks`, `implement` and `security-test`.
