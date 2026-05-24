# TG-01: Foundation & Infrastructure

> **Jira Epic:** Foundation & Infrastructure

## Description

Establishes the project repositories, CI/CD pipelines, shared encrypted storage layer, and the cross-cutting observability bus with PII log sanitisation. All other task groups depend on this group being complete.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-001](T-001-repository-cicd-scaffolding.md) | Repository and CI/CD Scaffolding | S | — | LOW |
| [T-002](T-002-encrypted-local-storage/) | EncryptedLocalStorage (iOS + Android) | M+M | T-001 | MEDIUM |
| [T-004](T-004-observability-bus-log-sanitiser.md) | ObservabilityBus + LogSanitiser | S | T-001 | LOW |

## Group effort estimate

- Optimistic (full parallel, 2 devs on T-002 subtasks): 3–5 days
- Realistic (2 devs): 5–8 days
