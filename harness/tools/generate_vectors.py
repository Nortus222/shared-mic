"""Generate golden wire vectors from the reference implementation.

Run from the harness directory:  python tools/generate_vectors.py

These files are the contract. A Windows or macOS implementation that
produces different bytes for the same message is wrong, and this is how
that gets caught without needing both machines in the room.

Regeneration is a deliberate act, not a routine one — see protocol-v1.md
section 10 (Conformance) for why the audio vectors in particular should
not be casually regenerated.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sharedmic_protocol.audio import sine_frame  # noqa: E402
from sharedmic_protocol.control import AUDIO_FORMAT, PROTOCOL_VERSION  # noqa: E402
from sharedmic_protocol.control import encode_control  # noqa: E402
from sharedmic_protocol.framing import (  # noqa: E402
    FRAME_TYPE_AUDIO,
    FRAME_TYPE_CONTROL,
    encode_audio_payload,
    encode_frame,
)

OUT = Path(__file__).resolve().parents[2] / "protocol" / "vectors"

CONTROL_MESSAGES = [
    {"v": PROTOCOL_VERSION, "type": "GREETING", "serverId": "win-desktop", "nonce": "00" * 32},
    {"v": PROTOCOL_VERSION, "type": "HELLO", "clientId": "mac-studio", "mac": "ab" * 32},
    {
        "v": PROTOCOL_VERSION,
        "type": "HELLO_ACK",
        "serverId": "win-desktop",
        "micPresent": True,
        "deviceLabel": "USB Microphone",
    },
    {
        "v": PROTOCOL_VERSION,
        "type": "START",
        "requestId": "req-0001",
        "preferredFormat": AUDIO_FORMAT,
    },
    {
        "v": PROTOCOL_VERSION,
        "type": "START_ACK",
        "requestId": "req-0001",
        "sessionId": "sess-0001",
        "format": AUDIO_FORMAT,
    },
    {
        "v": PROTOCOL_VERSION,
        "type": "START_NACK",
        "requestId": "req-0002",
        "reason": "MIC_UNAVAILABLE",
    },
    {"v": PROTOCOL_VERSION, "type": "STOP", "requestId": "req-0003", "sessionId": "sess-0001"},
    {"v": PROTOCOL_VERSION, "type": "STOP_ACK", "requestId": "req-0003", "sessionId": "sess-0001"},
    {
        "v": PROTOCOL_VERSION,
        "type": "STATUS",
        "micPresent": False,
        "active": False,
        "deviceLabel": "USB Microphone",
    },
    {"v": PROTOCOL_VERSION, "type": "PING", "seq": 1},
    {"v": PROTOCOL_VERSION, "type": "PONG", "seq": 1},
]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    control = [
        {
            "name": msg["type"],
            "message": msg,
            "hex": encode_frame(FRAME_TYPE_CONTROL, encode_control(msg)).hex(),
        }
        for msg in CONTROL_MESSAGES
    ]
    (OUT / "control-messages.json").write_text(json.dumps(control, indent=2) + "\n")

    audio = []
    for index in (0, 1, 49):
        pcm = sine_frame(index)
        audio.append(
            {
                "name": f"frame-{index}",
                "sequence": index,
                "timestampUs": index * 20000,
                "pcmHex": pcm.hex(),
                "hex": encode_frame(
                    FRAME_TYPE_AUDIO, encode_audio_payload(index, index * 20000, pcm)
                ).hex(),
            }
        )
    (OUT / "audio-frames.json").write_text(json.dumps(audio, indent=2) + "\n")

    print(f"wrote {len(control)} control vectors and {len(audio)} audio vectors to {OUT}")


if __name__ == "__main__":
    main()
