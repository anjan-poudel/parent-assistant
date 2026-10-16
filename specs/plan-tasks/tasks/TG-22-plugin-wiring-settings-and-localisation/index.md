# TG-22: Plugin, Wiring, Settings and Localisation

> **Jira Epic:** Plugin, Wiring, Settings and Localisation

## Description
Delivers everything the user touches: the 20-key localisation inventory (C-SP-11) including the M-2-amended privacy copy, the `SpotifyPlugin` twin of the YouTube plugin with the C-1-trimmed prompt fragment (C-SP-05), the `AppCoordinator` wiring that constructs and injects the Spotify services (C-SP-09), and the Settings linking surface with unlink and privacy disclosure (C-SP-10, NFR-SP-010).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-117](T-117-localisation-catalog.md) | Localisation catalog: 20 keys ne/en incl. privacy disclosure (M-2) | M | — | HIGH |
| [T-118](T-118-spotify-plugin-and-prompt-fragment.md) | SpotifyPlugin and trimmed prompt fragment (C-1) | L | T-106, T-107, T-110, T-117 | HIGH |
| [T-119](T-119-app-coordinator-wiring.md) | AppCoordinator wiring for the Spotify services | M | T-110, T-111, T-116, T-118 | MEDIUM |
| [T-120](T-120-settings-surface.md) | Settings linking surface, unlink and privacy disclosure | L | T-110, T-117, T-119 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): 6–8 days
- Realistic (2 devs): 9 days
