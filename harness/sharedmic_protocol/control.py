"""Control message types, validation, and JSON codec.

Pure: no sockets, no I/O. Validation happens on both encode and decode so
that a bug in the harness surfaces as a loud failure rather than as bytes
the other side has to guess about.
"""

import json

from .framing import ProtocolError

PROTOCOL_VERSION = 1

AUDIO_FORMAT = {"sampleRate": 48000, "channels": 1, "sampleFormat": "s16le"}

REQUIRED_FIELDS: dict[str, tuple[str, ...]] = {
    "GREETING": ("serverId", "nonce"),
    "HELLO": ("clientId", "mac"),
    "HELLO_ACK": ("serverId", "micPresent", "deviceLabel"),
    "START": ("requestId", "preferredFormat"),
    "START_ACK": ("requestId", "sessionId", "format"),
    "START_NACK": ("requestId", "reason"),
    "STOP": ("requestId", "sessionId"),
    "STOP_ACK": ("requestId", "sessionId"),
    "STATUS": ("micPresent", "active", "deviceLabel"),
    "PING": ("seq",),
    "PONG": ("seq",),
}


def _validate(msg: dict) -> dict:
    if not isinstance(msg, dict):
        raise ProtocolError("control message must be a JSON object")
    msg_type = msg.get("type")
    if msg_type not in REQUIRED_FIELDS:
        raise ProtocolError(f"unknown control type {msg_type!r}")
    if msg.get("v") != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported protocol version {msg.get('v')!r}")
    for field in REQUIRED_FIELDS[msg_type]:
        if field not in msg:
            raise ProtocolError(f"{msg_type} missing required field {field!r}")
    return msg


def encode_control(msg: dict) -> bytes:
    """Encode a control message with canonical (sorted) key order.

    Two implementations that build the same logical message with fields
    in a different order must still produce byte-identical wire output —
    otherwise conformance would depend on incidental code structure rather
    than on the message's actual content. `sort_keys=True` makes the wire
    bytes a pure function of the message, recursively through nested
    objects such as `preferredFormat`.
    """
    return json.dumps(
        _validate(msg), ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def decode_control(payload: bytes) -> dict:
    try:
        msg = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"malformed JSON control payload: {exc}") from exc
    return _validate(msg)
