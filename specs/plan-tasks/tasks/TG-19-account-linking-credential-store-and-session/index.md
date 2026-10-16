# TG-19: Account Linking, Credential Store and Session

> **Jira Epic:** Account Linking, Credential Store and Session

## Description
Delivers caregiver-facing account linking and the credential lifecycle: the encrypted `spotify.session` record (C-SP-02), the PKCE authorization-code flow with exact-match callback validation and single-refresh token lifecycle (C-SP-04), the session state machine with link / refresh / unlink / status and the revocation stance (C-SP-03), and the concrete `ASWebAuthenticationSession` presenter plus the `Info.plist` URL-scheme declarations (C-SP-12). Covers FR-SP-008, FR-SP-009, FR-SP-010 and NFR-SP-007/009.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-108](T-108-spotify-credential-store.md) | SpotifyCredentialStore with keychain-resident encrypted record | M | — | HIGH |
| [T-109](T-109-spotify-auth-flow-pkce.md) | SpotifyAuthFlow: PKCE authorize, callback validation, exchange, refresh | L | — | HIGH |
| [T-110](T-110-spotify-account-session.md) | SpotifyAccountSession: link, refresh, unlink, status | L | T-108, T-109 | HIGH |
| [T-111](T-111-web-auth-session-and-plist.md) | ASWebSpotifyAuthSession presenter and Info.plist declarations | M | T-109 | MEDIUM |

## Group effort estimate
- Optimistic (full parallel): 7–9 days
- Realistic (2 devs): 11 days
