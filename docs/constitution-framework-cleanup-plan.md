# Constitution & Framework Doc Cleanup — Plan (#5)

**Status:** Plan (for implementation by a future session)
**Date:** 2026-08-30
**Problem:** The constitution still declares **React Native** a fixed technology constraint (Open Decision #4 "RESOLVED: React Native"), while every line of implementation is native Swift (iOS) and Kotlin (Android) and `docs/medication-scheduler-implementation-plan.md` explicitly says "No React Native". Multiple research docs still assume RN bindings (`whisper.rn`, `llama.rn`, "native modules bridged to RN"). The docs contradict each other and the code.

## 1. Changes — `constitution.md`

1. **§Platform & Tech Stack, "Technology constraints (fixed)"**: replace the React Native bullet with:
   > Cross-platform framework: **native per-platform** for the MVP — Swift/SwiftUI (iOS), Kotlin (Android). React Native is out of MVP scope; revisit only if a single-codebase companion app is needed post-MVP.
2. **Open Decision #4**: change "RESOLVED: React Native" → "RESOLVED (revised 2026-08-30): native Swift (iOS MVP) + Kotlin (Android). Supersedes the earlier React Native answer; rationale: safety-critical services need platform-native APIs (UNUserNotification, AlarmManager, HealthKit/Health Connect) with per-platform implementations."
3. Add a short **Decision Log** section at the bottom of constitution.md listing the two reversals (framework; wake word → v2, already reflected in §4/OD-10) with dates, so future sessions see the revision trail.

## 2. Sweep the docs for stale RN references

Edit only the affected paragraphs; do not rewrite research docs wholesale.

| File | Fix |
|---|---|
| `docs/nepali-voice-stt-research.md` | §2 table "React Native" row → native + note the iOS MVP uses SwiftWhisper/LLM.swift (iOS) and the RN bindings are Android-later options; §6a.5 "llama.rn supports LoRA hot-swap" → correct to "LLM.swift (iOS) / llama.cpp; LoRA hot-swap fragile — merge adapters for v1" per the fine-tuning guide §0 |
| `docs/messaging-calling-platform-research.md` | "How this maps to the existing architecture" section — replace "native modules bridged to RN" framing with "platform-native services (Swift/Kotlin)" |
| `docs/llm-spec-and-implementation-plan.md` | §2 Phase 2 "llama.cpp" references fine; §6a references to whisper.rn/llama.rn in the STT doc are covered above |
| `docs/voice-pipeline-setup.md` | Update Porcupine "personal use is free" note → free tier ended 2026-06-30; wake word is v2 (see constitution §4) |

## 3. Verification

- `grep -rn "React Native" docs/ constitution.md` → only the revised decision + revision notes remain.
- `grep -rn "whisper.rn\|llama.rn" docs/` → no unqualified RN claims.
- Constitution §Platform, §Architecture Constraints, and the code (Swift/Kotlin only) are consistent.

## 4. Effort estimate

0.5 day.
