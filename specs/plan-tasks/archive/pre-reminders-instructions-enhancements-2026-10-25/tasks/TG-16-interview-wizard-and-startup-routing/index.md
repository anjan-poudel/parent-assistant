# TG-16: Interview Wizard and Startup Routing

> **Jira Epic:** Interview Wizard and Startup Routing

## Description

The user-facing interview: the pure draft/merge helpers and entry bounds, the shared address-as field, the three new step views, and the app-start routing that surfaces an incomplete interview once per cold start (FR-PI-016 owner amendment). The step views live in a dedicated `App/ProfileInterviewSteps.swift` so the log-safety gate covers them under its strict rules (AM-4). All writes go through the coordinator's single writer from TG-14.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-097](T-097-onboarding-drafts-and-bounds.md) | Onboarding drafts, bounds and mandatory predicate (C02) | S | T-090 | MEDIUM |
| [T-098](T-098-address-as-field.md) | `AddressAsField` — chips + custom entry (C03) | M | T-091, T-093, T-097 | MEDIUM |
| [T-099](T-099-about-you-step.md) | About-you step (C02) | M | T-092, T-093, T-097, T-098 | MEDIUM |
| [T-100](T-100-emergency-contacts-step.md) | Emergency contacts step + family list (C02, C11) | M | T-092, T-093, T-097 | MEDIUM |
| [T-101](T-101-voice-fingerprint-step.md) | Voice fingerprint step (C12) | M | T-093 | MEDIUM |
| [T-102](T-102-step-enum-and-cold-start-routing.md) | Step enum extension + cold-start routing + shell wiring (C02, C13) | L | T-092, T-097, T-099, T-100, T-101 | HIGH |

## Group effort estimate

- Optimistic (full parallel where the dependencies allow): 9–11 days
- Realistic (2 devs): 14.5–18 days
