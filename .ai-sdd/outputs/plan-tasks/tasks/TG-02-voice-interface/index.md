# TG-02: Voice Interface

> **Jira Epic:** Voice Interface

## Description

Implements all voice pipeline components: wake word detection (openWakeWord), audio session management, speech-to-text (Whisper.cpp), text-to-speech (Coqui/Piper), and accent tuning. Each component has iOS and Android subtasks developed in parallel. This group provides the voice I/O layer consumed by TG-05 (Voice Session Coordinator).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-005](T-005-wake-word-detector/) | WakeWordDetector (openWakeWord) | M+M | T-002, T-004 | MEDIUM |
| [T-007](T-007-audio-session-manager/) | AudioSessionManager | M+M | T-002, T-004 | MEDIUM |
| [T-009](T-009-stt-engine/) | STTEngine (Whisper.cpp) | M+M | T-007, T-004 | MEDIUM |
| [T-011](T-011-accent-tuner.md) | AccentTuner | M | T-009, T-010, T-002, T-003 | MEDIUM |
| [T-012](T-012-tts-engine/) | TTSEngine (Coqui/Piper) | M+M | T-007, T-004 | MEDIUM |

## Group effort estimate

- Optimistic (full parallel, 2 devs on all iOS+Android subtasks): 3–5 days
- Realistic (2 devs, sequential component delivery): 12–20 days
