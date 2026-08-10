"""Wire framing for the shared-mic protocol.

Pure functions only: no sockets, no logging, no I/O. Everything here is
covered by golden vectors that both platform implementations must match.
"""

import struct

FRAME_TYPE_CONTROL = 1
FRAME_TYPE_AUDIO = 2
_VALID_FRAME_TYPES = (FRAME_TYPE_CONTROL, FRAME_TYPE_AUDIO)

MAX_PAYLOAD = 1048576

_ENVELOPE = struct.Struct("!BI")
_AUDIO_HEADER = struct.Struct("!IQ")

ENVELOPE_SIZE = _ENVELOPE.size
AUDIO_HEADER_SIZE = _AUDIO_HEADER.size


class ProtocolError(Exception):
    """Raised when bytes on the wire violate the protocol."""


def encode_frame(frame_type: int, payload: bytes) -> bytes:
    if frame_type not in _VALID_FRAME_TYPES:
        raise ProtocolError(f"unknown frame type {frame_type}")
    if len(payload) > MAX_PAYLOAD:
        raise ProtocolError("payload too large")
    return _ENVELOPE.pack(frame_type, len(payload)) + payload


def decode_frame(buf: bytes) -> tuple[int, bytes, int] | None:
    """Decode one frame from the head of buf.

    Returns (frame_type, payload, bytes_consumed), or None if buf does not
    yet hold a complete frame. Raises ProtocolError on malformed input.
    """
    if len(buf) < ENVELOPE_SIZE:
        return None
    frame_type, length = _ENVELOPE.unpack_from(buf, 0)
    if frame_type not in _VALID_FRAME_TYPES:
        raise ProtocolError(f"unknown frame type {frame_type}")
    if length > MAX_PAYLOAD:
        raise ProtocolError("payload too large")
    end = ENVELOPE_SIZE + length
    if len(buf) < end:
        return None
    return frame_type, buf[ENVELOPE_SIZE:end], end


def encode_audio_payload(sequence: int, timestamp_us: int, pcm: bytes) -> bytes:
    return _AUDIO_HEADER.pack(sequence, timestamp_us) + pcm


def decode_audio_payload(payload: bytes) -> tuple[int, int, bytes]:
    if len(payload) < AUDIO_HEADER_SIZE:
        raise ProtocolError("audio payload shorter than header")
    sequence, timestamp_us = _AUDIO_HEADER.unpack_from(payload, 0)
    return sequence, timestamp_us, payload[AUDIO_HEADER_SIZE:]
