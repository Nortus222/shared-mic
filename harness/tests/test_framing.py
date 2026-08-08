import pytest

from sharedmic_protocol.framing import (
    FRAME_TYPE_AUDIO,
    FRAME_TYPE_CONTROL,
    ProtocolError,
    decode_audio_payload,
    decode_frame,
    encode_audio_payload,
    encode_frame,
)


def test_envelope_round_trip():
    data = encode_frame(FRAME_TYPE_CONTROL, b'{"type":"PING"}')
    assert decode_frame(data) == (FRAME_TYPE_CONTROL, b'{"type":"PING"}', len(data))


def test_envelope_is_five_byte_header_big_endian():
    data = encode_frame(FRAME_TYPE_AUDIO, b"\x00\x01\x02")
    assert data[:5] == b"\x02\x00\x00\x00\x03"


def test_decode_returns_none_when_header_incomplete():
    assert decode_frame(b"\x01\x00\x00") is None


def test_decode_returns_none_when_payload_incomplete():
    data = encode_frame(FRAME_TYPE_CONTROL, b"hello")
    assert decode_frame(data[:-1]) is None


def test_decode_reports_consumed_so_stream_can_hold_two_frames():
    stream = encode_frame(FRAME_TYPE_CONTROL, b"one") + encode_frame(FRAME_TYPE_CONTROL, b"two")
    frame_type, payload, consumed = decode_frame(stream)
    assert payload == b"one"
    assert decode_frame(stream[consumed:]) == (FRAME_TYPE_CONTROL, b"two", 8)


def test_decode_rejects_unknown_frame_type():
    with pytest.raises(ProtocolError, match="frame type"):
        decode_frame(b"\x09\x00\x00\x00\x01x")


def test_decode_rejects_oversized_payload():
    with pytest.raises(ProtocolError, match="payload too large"):
        decode_frame(b"\x01\xff\xff\xff\xffx")


def test_audio_payload_round_trip():
    pcm = b"\x11\x22" * 960
    assert decode_audio_payload(encode_audio_payload(7, 123456789, pcm)) == (7, 123456789, pcm)


def test_audio_payload_header_is_twelve_bytes():
    pcm = b"\x00\x00" * 960
    assert len(encode_audio_payload(1, 2, pcm)) == 12 + 1920


def test_audio_payload_rejects_short_header():
    with pytest.raises(ProtocolError, match="audio payload"):
        decode_audio_payload(b"\x00" * 11)
