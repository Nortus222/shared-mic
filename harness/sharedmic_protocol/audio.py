"""Synthetic PCM for the harness.

A phase-continuous sine wave, so that a listening test hears a clean tone
and any discontinuity is a real bug rather than an artifact of the
generator.
"""

import math
import struct

SAMPLE_RATE = 48000
FRAME_SAMPLES = 960
FRAME_BYTES = FRAME_SAMPLES * 2
FRAMES_PER_SECOND = SAMPLE_RATE // FRAME_SAMPLES
FRAME_DURATION_US = 1_000_000 // FRAMES_PER_SECOND

_PACK = struct.Struct(f"<{FRAME_SAMPLES}h")


def sine_frame(frame_index: int, freq_hz: float = 440.0, amplitude: float = 0.5) -> bytes:
    start = frame_index * FRAME_SAMPLES
    peak = amplitude * 32767.0
    samples = [
        int(peak * math.sin(2.0 * math.pi * freq_hz * (start + n) / SAMPLE_RATE))
        for n in range(FRAME_SAMPLES)
    ]
    return _PACK.pack(*samples)
