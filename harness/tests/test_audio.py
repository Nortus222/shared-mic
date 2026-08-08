import struct

from sharedmic_protocol.audio import (
    FRAME_BYTES,
    FRAME_DURATION_US,
    FRAME_SAMPLES,
    FRAMES_PER_SECOND,
    SAMPLE_RATE,
    sine_frame,
)


def test_constants_match_spec():
    assert (SAMPLE_RATE, FRAME_SAMPLES, FRAME_BYTES) == (48000, 960, 1920)
    assert FRAMES_PER_SECOND == 50
    assert FRAME_DURATION_US == 20000


def test_frame_is_exactly_one_frame_of_pcm():
    assert len(sine_frame(0)) == FRAME_BYTES


def test_frame_is_little_endian_signed_16_bit():
    samples = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0))
    assert len(samples) == FRAME_SAMPLES
    assert all(-32768 <= s <= 32767 for s in samples)


def test_sine_starts_at_zero_crossing():
    first = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0))[0]
    assert first == 0


def test_frames_are_phase_continuous():
    """Frame N+1 must continue the wave, not restart it.

    A restarted wave would produce a click every 20 ms and would mask real
    discontinuity bugs during listening tests.
    """
    tail = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0))[-1]
    head = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(1))[0]
    step = 2 * 32767 * 0.5 * 3.14159 * 440.0 / SAMPLE_RATE
    assert abs(head - tail) < step * 2


def test_amplitude_is_respected():
    quiet = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0, amplitude=0.1))
    loud = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0, amplitude=0.9))
    assert max(loud) > max(quiet) * 5
