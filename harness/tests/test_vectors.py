import json
from pathlib import Path

import pytest

from sharedmic_protocol.control import decode_control, encode_control
from sharedmic_protocol.framing import decode_frame, encode_audio_payload, encode_frame

VECTORS = Path(__file__).resolve().parents[2] / "protocol" / "vectors"


def _load(name):
    return json.loads((VECTORS / name).read_text())


def test_vector_files_exist():
    assert (VECTORS / "control-messages.json").is_file()
    assert (VECTORS / "audio-frames.json").is_file()


@pytest.mark.parametrize("case", _load("control-messages.json") if VECTORS.is_dir() else [])
def test_control_vectors_encode_to_expected_bytes(case):
    expected = bytes.fromhex(case["hex"])
    assert encode_frame(1, encode_control(case["message"])) == expected


@pytest.mark.parametrize("case", _load("control-messages.json") if VECTORS.is_dir() else [])
def test_control_vectors_decode_to_expected_message(case):
    _, payload, _ = decode_frame(bytes.fromhex(case["hex"]))
    assert decode_control(payload) == case["message"]


@pytest.mark.parametrize("case", _load("audio-frames.json") if VECTORS.is_dir() else [])
def test_audio_vectors_encode_to_expected_bytes(case):
    payload = encode_audio_payload(
        case["sequence"], case["timestampUs"], bytes.fromhex(case["pcmHex"])
    )
    assert encode_frame(2, payload) == bytes.fromhex(case["hex"])
