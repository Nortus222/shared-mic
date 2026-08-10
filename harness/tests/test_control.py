import pytest

from sharedmic_protocol.control import (
    AUDIO_FORMAT,
    PROTOCOL_VERSION,
    decode_control,
    encode_control,
)
from sharedmic_protocol.framing import ProtocolError


def test_ping_round_trip():
    msg = {"v": PROTOCOL_VERSION, "type": "PING", "seq": 3}
    assert decode_control(encode_control(msg)) == msg


def test_start_round_trip_carries_format():
    msg = {
        "v": PROTOCOL_VERSION,
        "type": "START",
        "requestId": "r-1",
        "preferredFormat": AUDIO_FORMAT,
    }
    assert decode_control(encode_control(msg))["preferredFormat"] == AUDIO_FORMAT


def test_canonical_audio_format_matches_spec():
    assert AUDIO_FORMAT == {"sampleRate": 48000, "channels": 1, "sampleFormat": "s16le"}


def test_rejects_unknown_message_type():
    with pytest.raises(ProtocolError, match="unknown control type"):
        encode_control({"v": 1, "type": "LAUNCH_MISSILES"})


def test_rejects_wrong_protocol_version():
    with pytest.raises(ProtocolError, match="version"):
        decode_control(b'{"v": 2, "type": "PING", "seq": 1}')


def test_rejects_missing_required_field():
    with pytest.raises(ProtocolError, match="missing required field 'nonce'"):
        encode_control({"v": 1, "type": "GREETING", "serverId": "win-1"})


def test_rejects_non_object_json():
    with pytest.raises(ProtocolError, match="object"):
        decode_control(b'["not", "an", "object"]')


def test_rejects_malformed_json():
    with pytest.raises(ProtocolError, match="malformed JSON"):
        decode_control(b"{not json")


def test_encodes_as_utf8_without_ascii_escaping():
    payload = encode_control(
        {"v": 1, "type": "HELLO_ACK", "serverId": "win-1", "micPresent": True, "deviceLabel": "Røde"}
    )
    assert "Røde".encode("utf-8") in payload
