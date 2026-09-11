#!/usr/bin/env python3
"""[TIMER-ALARM] Generates ios/ElderlyAssistant/Resources/timer-alarm-bell.wav
— the bundled loud timer-alarm bell loop. Synthesized from scratch (sum of
decaying sine partials), so it carries NO third-party recording rights; the
output is CC0 (see Resources/TimerAlarmBell.LICENSE.txt next to the asset).

Design:
  - Three bell strikes over ~4.6 s. An in-app AVAudioPlayer loops the file
    (`numberOfLoops = -1`), so the alarm rings as strike-strike-strike,
    pause, repeat — a natural alarm pattern, loud, until the user stops it.
  - 44.1 kHz / 16-bit / mono linear PCM WAV. That format is required for
    custom UN notification sounds (≤ 30 s, linear PCM) and plays everywhere
    AVAudioPlayer runs.

Usage: python3 ios/tools/generate-timer-alarm-bell.py
"""

import math
import os
import struct
import wave

RATE = 44100
DURATION = 4.6  # seconds — one loop pass
# Bell-like partial set: fundamental + inharmonic-ish overtones with a
# struck-bell decay. Amplitudes are pre-mix weights.
PARTIALS = [
    (660.0, 1.00),
    (990.0, 0.60),
    (1320.0, 0.40),
    (1760.0, 0.25),
    (2640.0, 0.12),
]
STRIKE_TIMES = [0.0, 1.6, 3.2]  # one loop = three strikes
DECAY_TAU = 0.42  # seconds; e^(-t/tau) — longer tail = more "bell", less "beep"
PEAK = 0.95  # peak normalization target — loud without clipping


def sample_at(t: float) -> float:
    value = 0.0
    for strike in STRIKE_TIMES:
        age = t - strike
        if age < 0:
            continue
        attack = min(age / 0.004, 1.0)  # 4 ms attack avoids a click
        for freq, amp in PARTIALS:
            # Slight per-strike detune on the fundamental only keeps the
            # three strikes from sounding identical (hand-bell character).
            f = freq * (1.002 if freq == PARTIALS[0][0] and strike > 0 else 1.0)
            value += amp * attack * math.exp(-age / DECAY_TAU) * math.sin(2 * math.pi * f * age)
    return value


def main() -> None:
    out_path = os.path.join(
        os.path.dirname(__file__),
        "..", "ElderlyAssistant", "Resources", "timer-alarm-bell.wav",
    )
    out_path = os.path.normpath(out_path)

    frame_count = int(RATE * DURATION)
    samples = [sample_at(i / RATE) for i in range(frame_count)]
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = PEAK / peak

    with wave.open(out_path, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)  # 16-bit
        wav.setframerate(RATE)
        frames = bytearray()
        for s in samples:
            frames += struct.pack("<h", int(round(s * scale * 32767)))
        wav.writeframes(bytes(frames))
    print(f"wrote {out_path} ({frame_count} frames, peak {PEAK:.2f})")


if __name__ == "__main__":
    main()
