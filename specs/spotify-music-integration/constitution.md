# Constitution — spotify-music-integration (feature supplement)

Applies to the `spotify-music-integration` workflow only (`specs/spotify-music-integration/workflow.yaml`, mirrored at `.ai-sdd/workflows/spotify-music-integration.yaml`). The project constitution (`/constitution.md`) is inherited — including the 2026-10-06 Spotify amendment to Architecture Constraint 1 and the Required-integrations list, which is recorded below — and its Architecture Constraints 2–6, Standards, release gates, and Agent Principles all bind this feature. This supplement does not restate project-level rules; it records only what the feature adds, what it must not change, and the decisions left open. See `specs/spotify-music-integration/init-report.md` for the scaffold probe.

## Constitutional Amendment Record (2026-10-06)

This feature adds a new outbound network integration with user account linking, which the constitution did not previously permit. The amendment is recorded here and in the root constitution in the same change as this spec — it is an explicit constitutional amendment, **not a silent bypass**:

- **Architecture Constraint 1 — permitted network integrations.** Spotify is added to the enumerated list of permitted third-party network integrations (Calendar API, WhatsApp, YouTube, Facebook, **Spotify**). The amendment covers search (Spotify Web API) and user-initiated playback hand-off only; the on-device AI constraint is unchanged.
- **Required integrations.** Spotify is added to the root constitution's Required-integrations list: music playback and search, account linking via user OAuth.
- **Account-linking discipline (calendar-share Google OAuth pattern).** Scopes are requested at sign-in (`addScopes`), tokens are verified, tokens are stored encrypted on-device (Keychain / `EncryptedLocalStorage`, Data Protection Complete), and credentials never enter the repository or any log — header, never URL. The B2/T-050 release-log-gate precedent (`ios/tools/check-release-log-safety.sh`) is binding.
- **Privacy disclosure.** Linking the account sends the user's music queries and playback activity to Spotify. The privacy/settings surface discloses this, consistent with how the app already discloses its other integrations.
- **Scope limited to Spotify.** No other network egress is added or widened by this amendment.
- **Ordering.** The amendment is part of the feature change set: no Spotify code without it (constraint 10). The root-constitution entries this refers to are the two 2026-10-06 amendments in `constitution.md` (Architecture Constraint 1 and the Required-integrations list).

## Feature Purpose & Scope

Purpose: make voice-requested music actually play. Today a bare music request ('भजन बजाऊ', 'गीत चलाऊ', 'play a song') hits the first-class music stub (`router.musicStub`, `CommandRouter.swift:2640`) — the assistant says the feature is unavailable and nothing plays. This feature replaces the stub with real playback: for music requests both providers are searched and Spotify wins whenever it is linked and capable; YouTube serves explicit YouTube requests and the Spotify-can't-serve fallback.

Primary user: the elderly primary user (60+, Nepali-first, voice-only interaction) who asks for music by voice. Secondary user: the family member/caregiver who performs the Spotify account linking and credential setup on the parent's device — the elderly user never touches OAuth or keys (the established family-handles-credentials pattern).

In scope:

- Music requests that hit the stub today start real playback — the broken-to-working flip.
- Both-provider search for music requests, Spotify preferred whenever linked and capable; YouTube for explicit YouTube requests and the Spotify-can't-serve fallback.
- Spotify ships as an `AssistantPlugin` (`SpotifyPlugin`), twin of `YouTubePlugin`: `spotify.play` action, shared tool use, L10n, observability.
- `SpotifyTool`: Spotify Web API search plus `spotify:` deep-link construction, mirroring `YouTubeTool`; Spotify credential/account store on `EncryptedLocalStorage`.
- Spotify account-linking service following the `GoogleAccountSession` OAuth precedent (scopes at sign-in, token verification, Keychain storage).
- A deterministic music-domain rule in `KeywordIntentRule` (the no-model path), and `VoiceContactSearchRoute` YouTube-veto parity so music requests never open the Contacts screen.
- Music-intent wording changes in the intent/prompt layer within the pinned prompt budget; a Settings linking/status surface mirroring `YouTubeSettingsView`.
- All user-facing strings localized (ne/en) via `spotify.*` keys; spoken output follows the voice stack's formatting discipline.
- Tests following the YouTube suite pattern plus the golden-corpus music entries; a DV-* device-validation checklist as the completion gate.

Out of scope (must not change):

- On-device intent parsing and routing stance: no cloud LLM on the music path; music queries go to the provider APIs directly.
- Plugin isolation: the feature ships as an `AssistantPlugin` with no entanglement beyond the mapped `CommandRouter` seams; the plugin-isolation architecture from the voice-OS pivot direction is preserved.
- No new backend: the Spotify Web API is called directly from the app.
- No brain/router model-stack changes.
- Explicit YouTube routing is unchanged ('युट्युबमा गीत चलाऊ' must still reach YouTube exactly as today).
- Playback is read-only, user-initiated media control — no library edits, playlist mutations, or account modifications.

Document supersession: `requirements.md` lines 675–676 list "Music and bhajan playback" as Post-MVP. The project constitution is the operative document, and this feature elevates that entry into the real path — the Post-MVP placement for music is superseded by this feature.

## Music Request Routing & Degradation Contract

Routing (recorded as the top-level rule, constraint 9):

| Request | Provider outcome |
|---|---|
| Music request (bare: 'भजन बजाऊ', 'गीत चलाऊ', 'play a song') | Both providers searched; **Spotify wins whenever linked and capable** |
| Explicit YouTube request ('युट्युबमा गीत चलाऊ') | YouTube, exactly as today (unchanged) |
| Spotify cannot serve the request | YouTube fallback where it can serve; otherwise an honest localized line |

Degradation:

- Never a silent failure anywhere in the chain. Unlinked account, free tier, network failure, and empty search each produce an explicit, localized, spoken outcome (root Agent Principle: no silent stubs). The stub's honest "unavailable" line is replaced by real outcomes, never by pretense.
- Premium reality: playback control requires Spotify Premium, so free-tier or unlinked-account remote control degrades to the `spotify:` deep-link fallback with clear messaging rather than pretending to control playback (constraint 1).
- Spotify-unavailable/unlinked music requests fall back to YouTube (constraint 5).
- The precedence between these fallbacks across account and service states — free tier, unlinked account, network failure, empty search — is OD-S3. Both rules are binding; OD-S3 resolves how they compose, including the copy for each path.

## Integration Surfaces (mapped by the scaffold brief)

The surface below is the scaffold brief's mapping — the planning input for design-l1/design-l2, referenced here rather than re-derived.

| Surface | Change |
|---|---|
| **NEW** `ios/ElderlyAssistant/Services/Plugins/SpotifyPlugin.swift` | `AssistantPlugin` twin of `YouTubePlugin`: `spotify.play` action, shared tool use, L10n, observability. |
| **NEW** `ios/ElderlyAssistant/Services/Voice/SpotifyTool.swift` | Spotify Web API search + `spotify:` deep-link construction, mirroring `YouTubeTool`; Spotify credential/account store on `EncryptedLocalStorage`. |
| **NEW** Spotify account-linking service | Follows the `GoogleAccountSession` OAuth precedent (scopes at sign-in, token verification, Keychain storage). |
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` | The music stub (`case .music:`, line 2640, speaking `router.musicStub` at 2643) is replaced by the real playback path; Spotify tool seams follow the configStore/transport/linkOpener pattern (lines 639–648); `logToolRequest(kind:)` additions. |
| `ios/ElderlyAssistant/Services/Voice/YouTubeRoute.swift` | A bare 'play some music' with no YouTube word deliberately falls through today; the music path changes or sits alongside it, while explicit 'युट्युबमा गीत चलाऊ' must still reach YouTube. |
| `ios/ElderlyAssistant/Services/Voice/KeywordIntentRule.swift` | Deterministic music domain rule (no-model path). |
| `ios/ElderlyAssistant/Services/Voice/VoiceContactSearchRoute.swift` | YouTube-veto parity so music requests never open the Contacts screen. |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | Plugin registration + store wiring (line ~2058 pattern). |
| `ios/ElderlyAssistant/App/SettingsView.swift` + `SettingsTabs.swift` | Spotify linking/status surface (mirror of `YouTubeSettingsView`, lines 759–840), including the privacy disclosure. |
| `ios/ElderlyAssistant/Resources/Localizable.xcstrings`, `ios/ElderlyAssistant/Info.plist` | `spotify.*` keys; `spotify` query scheme + OAuth callback URL. |
| Intent/prompt layer: `IntentPrompt.swift`, `ChatIntentClassifier.swift`, encoder/interpreter action lists | Music intent wording (prompt budget pinned by `IntentPromptTests`). |
| Tests: YouTube suite pattern + `GoldenCorpus.swift` music entries (lines 142–157) | `YouTubeRouteTests`, `YouTubePluginTests`, `CommandRouterYouTubeTests`, `KeywordIntentRuleTests`, `VoiceContactSearchRouteTests`, `SettingsTabMappingTests`, `StoragePlacementTests`; golden music entries move with the feature. |

Console-side / external (owner-confirmed, not visible in code):

- Spotify Developer Dashboard app registration: client ID + secret, redirect URI, scopes — same class as the Google OAuth console work from calendar-share (OD-S1, OD-S2).
- Spotify development-mode test-user limit until a quota-extension request is approved (OD-S2).
- No backend of ours: the Spotify Web API is called directly from the app (constraint 6).
- Device: the Spotify app is installed for the `spotify:` deep-link fallback (constraint 8).

## Safety & Compliance Delta

One new integration-class concern, following existing project precedent: a new outbound network integration with user account linking (the 2026-10-06 amendment above), credential handling under the calendar-share Google OAuth discipline, and a privacy disclosure for music queries and playback activity. The on-device stance is unchanged — voice intent parsing and routing stay on-device; Spotify is a playback/search provider, not a brain/router, and music queries never go through a cloud LLM. No other new safety or compliance concerns: playback is read-only, user-initiated media control. No feature-specific review gate is added beyond the amendment, the constraints below, and the DV-* completion gate; the project's safety-critical review gates apply unchanged.

## Feature Constraints

1. **Premium reality is an NFR — degradation must be honest.** Playback control requires a Spotify Premium account. Free-tier or unlinked-account remote control must degrade to the `spotify:` deep-link fallback with clear messaging, never a silent failure (root Agent Principle: no silent stubs). The exact degradation path is OD-S3.
2. **Credential discipline.** Scopes at sign-in (`addScopes`), token verification, encrypted on-device storage, no credentials in the repository or logs — the key travels in a header, never a URL; the B2/T-050 release-log-gate precedent (`ios/tools/check-release-log-safety.sh`) is binding. Client-secret handling for the search flow is OD-S1.
3. **Prompt budget.** `IntentPromptTests` pins the intent prompt's token budget; music/Spotify prompt additions must fit it. The YouTube route's zero-prompt-token discipline is the model.
4. **On-device stance.** Voice intent parsing and routing stay on-device; music queries go to the provider APIs directly, never through a cloud LLM. No network egress beyond the two provider APIs.
5. **Must-not-break paths.** Explicit YouTube requests ('युट्युबमा गीत चलाऊ') still route to YouTube; Spotify-unavailable/unlinked falls back to YouTube; existing YouTube golden tests and route behaviour change only where the music feature deliberately supersedes them. The golden-corpus music entries (`ios/ElderlyAssistantTests/Services/Voice/GoldenCorpus.swift:142–157`, 15 utterances pinned to intent `music` (16 -> 15 corrected by annotation; the code is authoritative — C-3 / review-l2 F-3)) move only where deliberately superseded, with the new expectation recorded alongside.
6. **No new backend.** The Spotify Web API is called directly from the app; nothing is provisioned on our side.
7. **Rollout constraint.** The Spotify app in development mode works only for registered test users until a quota-extension request is approved. The rollout plan is OD-S2; users outside the test set must still see honest behaviour, never a silent failure.
8. **Device expectation.** The Spotify app is installed for the `spotify:` deep-link fallback; behaviour without it follows the honest-messaging rule (constraints 1 and 5).
9. **Preference semantics — top-level rule.** For music requests both providers are searched and Spotify wins whenever it is linked and capable; YouTube is used only for explicit YouTube requests or when Spotify cannot serve the request. This is the feature's core requirement, not an implementation detail.
10. **Constitution moves with the spec.** The Architecture Constraint 1 amendment must land in the same change as the feature spec; no code without the constitutional amendment. Recorded above and in the root constitution (2026-10-06).
11. **Plugin isolation.** The feature ships as an `AssistantPlugin` (`SpotifyPlugin`) with no entanglement beyond the mapped `CommandRouter` seams, preserving the plugin-isolation architecture from the voice-OS pivot direction. No changes to the brain/router model stack.
12. **Localization discipline.** All Spotify user-facing strings are localized (ne/en) via `spotify.*` keys, mirroring the YouTube plugin's L10n pattern; spoken output follows the same formatting discipline as the rest of the voice stack.

## Open Decisions

### OD-S1 — Client-secret handling for the Spotify search flow (OPEN — architect / security review)

Spotify client-credentials search requires the app to hold the client secret, and there is no backend. Choose: family-entered credential per the `YouTubeConfigStore`/`SearchConfigStore` Keychain precedent (never in the repo, header not URL, never logged — B2 is the binding precedent) versus PKCE-only options where the flow permits. The choice must satisfy constraint 2 and interact cleanly with the dev-mode test-user limit (OD-S2).

### OD-S2 — Spotify development-mode rollout and quota-extension plan (OPEN — owner / architect)

The Spotify app in development mode works only for registered test users until a quota-extension request is approved. Define which accounts are registered during development and device validation, when and how the quota-extension request is filed, and what unregistered users experience before approval (honest messaging; no silent failure). This includes the console-side Spotify Developer Dashboard registration (client ID + secret, redirect URI, scopes) — the same class as the Google OAuth console work from calendar-share.

### OD-S3 — Premium-account degradation path (OPEN — architect)

The exact UX and precedence when Spotify cannot perform playback: free-tier linked account, unlinked account, network/service failure, empty search. Which cases degrade to the `spotify:` deep-link fallback with clear messaging (constraint 1), which fall back to YouTube where it can serve (constraint 5), the exact localized copy for each, and how the both-provider search behaves in each case. Must satisfy constraints 1, 5, and 9 and the no-silent-failure rule. Resolve in design-l1/design-l2.

## Success Criteria & Completion Gate

Success:

- Music requests that hit the stub today (`router.musicStub`) start real playback — the core broken-to-working flip.
- For music, both providers are searched and Spotify wins whenever linked and capable; YouTube serves explicit YouTube requests and the Spotify-can't-serve fallback.
- No silent failures anywhere in the chain: unlinked account, free tier, network failure, and empty search each speak an honest localized line.
- Explicit YouTube requests behave exactly as before (existing route, plugin, and golden tests hold).
- The user can ask for music in natural Nepali and get sound.

Completion gate — DV-* device validation: the feature is done only when it carries a DV-* style acceptance checklist (the DV-1..DV-16 pattern used by prior shipped features, recorded with the feature spec) and passes it on the reference device (Anzaan). The checklist covers at minimum:

- DV-1 — stub → real playback flip: a bare music request produces sound.
- DV-2 — Spotify-preferred selection: both-provider search with Spotify winning while linked and capable.
- DV-3 — explicit-YouTube routing unchanged: 'युट्युबमा गीत चलाऊ' still reaches YouTube.
- DV-4 — honest lines for free-tier, unlinked-account, network-failure, and empty-search paths (no silent failure).
- DV-5 — Nepali-language end-to-end on the Anzaan reference device.
