# TG-18: Spotify Tool and Deep-Link Hardening

> **Jira Epic:** Spotify Tool and Deep-Link Hardening

## Description
Delivers the network-facing half of the Spotify integration: the `SpotifyTool` track search and remote-play client (C-SP-01) and the hardened `spotify:` deep-link construction and open path used whenever remote play cannot serve (C-SP-01 deep-link half). Covers the design-l2 component specifications for C-SP-01, the URI grammar (§24) and the free-tier degradation contract (FR-SP-011).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-106](T-106-spotify-tool-search-and-play.md) | SpotifyTool search and remote-play client | L | — | HIGH |
| [T-107](T-107-deep-link-grammar-and-hardening.md) | Deep-link grammar, hostile corpus and open probe | M | T-106 | HIGH |

## Group effort estimate
- Optimistic (full parallel): 4–6 days
- Realistic (2 devs): 6 days
