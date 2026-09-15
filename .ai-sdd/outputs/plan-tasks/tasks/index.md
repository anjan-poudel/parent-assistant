# Implementation Tasks — Elderly AI Assistant

| Group | Title | Tasks | Total Effort | Status |
|-------|-------|-------|-------------|--------|
| [TG-01](TG-01-foundation-infrastructure/index.md) | Foundation & Infrastructure | 4 tasks (T-001, T-002, T-004, T-050) | ~9–17 days | PENDING |
| [TG-02](TG-02-voice-interface/index.md) | Voice Interface | 6 tasks (T-005, T-007, T-009, T-011, T-012, T-049) | ~16–27 days | PENDING |
| [TG-03](TG-03-on-device-ai/index.md) | On-Device AI | 8 tasks (T-018, T-020, T-021, T-045, T-046, T-047, T-048, T-051) | ~17–27 days | PENDING |
| [TG-04](TG-04-authentication-security/index.md) | Authentication & Security | 3 tasks (T-014, T-016, T-017) | ~8–14 days | PENDING |
| [TG-05](TG-05-voice-session/index.md) | Voice Session | 1 task (T-022) | ~6–10 days | PENDING |
| [TG-06](TG-06-safety-critical-services/index.md) | Safety-Critical Services | 3 tasks (T-024, T-026, T-028) | ~9–15 days | PENDING |
| [TG-07](TG-07-remote-configuration/index.md) | Remote Configuration | 3 tasks (T-030, T-031, T-032) | ~14–22 days | PENDING |
| [TG-08](TG-08-nepali-intent-encoder/index.md) | Nepali Intent Encoder | 6 tasks (T-033–T-038) | ~31–55 days | PENDING |
| [TG-09](TG-09-plugin-recognition-contract/index.md) | Plugin Recognition & Contract | 6 tasks (T-039–T-044) | ~21–38 days | PENDING |
| [TG-10](TG-10-continuous-learning-loop/index.md) | Continuous Learning Loop | 9 tasks (T-052–T-060) | ~22–45 days | PENDING |
| [TG-11](TG-11-linguistic-robustness/index.md) | Linguistic Robustness | 9 tasks (T-061–T-069) | ~24–38 days | PENDING |
| [TG-12](TG-12-crux-resolution-pipeline/index.md) | Crux-Resolution Pipeline | 10 tasks (T-070–T-079) | ~24–40 days | PENDING |
| [TG-13](TG-13-environment-robustness-benchmark/index.md) | Environment Robustness Benchmark | 10 tasks (T-080–T-089) | ~26–42 days | PENDING |
> **In-flight groups (not in this checkout).** [TG-11](TG-11-linguistic-robustness/index.md) (Linguistic Robustness, T-061–T-068) and [TG-12](TG-12-crux-resolution-pipeline/index.md) (Crux-Resolution Pipeline, T-069–T-079) are being authored in their own worktrees; their rows and directories land with their own integrations. Their ID ranges are reserved, which is why TG-13 starts at **T-080** rather than the T-063 the original brief assumed. TG-13 consumes TG-11's fixtures (T-064, T-066, T-068) and TG-12's canonicalizer (T-074) by path and cross-references their gates rather than re-declaring them.


> **Rework tasks (security-test NO_GO).** [T-049](../TG-02-voice-interface/T-049-release-build-transcript-prints.md) (TG-02) and [T-050](../TG-01-foundation-infrastructure/T-050-api-key-error-code-log-leak.md) (TG-01) are the B1/B2 remediation tasks raised by the `security-test` SECURITY-NO_GO (`specs/security-test.md`). They are listed in their owning groups above; this note carries the cross-group link, because B2's emitter sites span TG-01, TG-02, TG-03 and TG-09 and are owned by TG-01 alone.
