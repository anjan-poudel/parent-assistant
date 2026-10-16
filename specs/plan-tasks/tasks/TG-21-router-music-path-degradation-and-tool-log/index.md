# TG-21: Router Music Path, Degradation and Tool Log

> **Jira Epic:** Router Music Path, Degradation and Tool Log

## Description
Delivers the heart of the feature: the router music path (C-SP-06) with its three dormant-nil seams, `selectMusicOutcome` and the full 12-row state x outcome matrix (§13) — Spotify preferred when linked and capable, YouTube fallback when Spotify cannot serve, honest spoken line in every row, never the stub — plus the music intake in the route ladder (FR-SP-015), the query-free logging variant for reused YouTube helpers (M-1), and the new tool-log kind (C-SP-14, C-4).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-114](T-114-youtube-query-free-logging.md) | Query-free logging variant for reused YouTube helpers (M-1) | M | — | HIGH |
| [T-115](T-115-tool-log-spotify-kind.md) | LocalToolLogStore spotify kind and tool-log view switches (C-4) | S | — | MEDIUM |
| [T-116](T-116-router-music-path.md) | Router music path: seams, matrix, intake and pins | XL | T-106, T-107, T-110, T-112, T-114, T-115 | CRITICAL |

## Group effort estimate
- Optimistic (full parallel): 6–8 days
- Realistic (2 devs): 9 days
