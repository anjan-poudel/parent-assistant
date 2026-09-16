# TG-02: Camera Capture and On-Device Text Detection

> **Jira Epic:** Camera Capture and On-Device Text Detection

## Description

Builds the capture stack with no photo output configured at all (C01) and the Vision layer that
recognises printed text entirely on-device with automatic language detection plus a geometry-only
tracking pass between OCR passes (C02), together with the permission and denial surfaces the elder
actually meets (FR-LCT-002).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-006](T-006-live-camera-session.md) | `LiveCameraSession` (C01) | L | T-001, T-003 | HIGH |
| [T-007](T-007-live-text-detector.md) | `LiveTextDetector` (C02) | L | T-001, T-003, T-006 | HIGH |
| [T-008](T-008-camera-permission-surfaces.md) | Camera permission and denial surfaces | S | T-005, T-006 | MEDIUM |

## Group effort estimate

- Optimistic (T-007 parallel with T-006's review, T-008 alongside): 3–4 days
- Realistic (2 devs, T-007 blocked on T-006's frame type): 5–7 days
