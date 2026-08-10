"""Pairing token and challenge-response authentication.

The token never crosses the wire. The server issues a fresh nonce per
connection and the client proves possession with HMAC-SHA256, which makes
a captured proof useless against the next connection.
"""

import base64
import hashlib
import hmac
import os
import re

TOKEN_BYTES = 32
NONCE_BYTES = 32

_GROUP_SIZE = 8
_NON_BASE32 = re.compile(r"[^A-Z2-7]")


def generate_token() -> bytes:
    return os.urandom(TOKEN_BYTES)


def generate_nonce() -> bytes:
    return os.urandom(NONCE_BYTES)


def encode_pairing_string(token: bytes) -> str:
    """Base32, uppercase, unpadded, hyphen-grouped so a human can retype it."""
    raw = base64.b32encode(token).decode("ascii").rstrip("=")
    return "-".join(raw[i : i + _GROUP_SIZE] for i in range(0, len(raw), _GROUP_SIZE))


def decode_pairing_string(text: str) -> bytes:
    cleaned = _NON_BASE32.sub("", text.upper())
    padding = "=" * (-len(cleaned) % 8)
    try:
        token = base64.b32decode(cleaned + padding)
    except Exception as exc:
        raise ValueError(f"invalid pairing string: {exc}") from exc
    if len(token) != TOKEN_BYTES:
        raise ValueError(f"pairing string decodes to {len(token)} bytes, expected {TOKEN_BYTES}")
    return token


def auth_proof(token: bytes, nonce: bytes) -> str:
    return hmac.new(token, nonce, hashlib.sha256).hexdigest()


def verify_proof(token: bytes, nonce: bytes, proof: str) -> bool:
    if not isinstance(proof, str):
        return False
    return hmac.compare_digest(auth_proof(token, nonce), proof)
