import pytest

from sharedmic_protocol.auth import (
    TOKEN_BYTES,
    auth_proof,
    decode_pairing_string,
    encode_pairing_string,
    generate_nonce,
    generate_token,
    verify_proof,
)


def test_token_is_256_bits():
    assert len(generate_token()) == TOKEN_BYTES == 32


def test_tokens_are_not_repeated():
    assert generate_token() != generate_token()


def test_pairing_string_round_trip():
    token = generate_token()
    assert decode_pairing_string(encode_pairing_string(token)) == token


def test_pairing_string_tolerates_human_transcription():
    token = generate_token()
    text = encode_pairing_string(token)
    assert decode_pairing_string(text.lower().replace("-", " ")) == token


def test_pairing_string_rejects_garbage():
    with pytest.raises(ValueError):
        decode_pairing_string("not-a-valid-token")


def test_pairing_string_rejects_wrong_length():
    # Valid base32 string (AAAAAAAA = 5 bytes) but not 32 bytes
    with pytest.raises(ValueError):
        decode_pairing_string("AAAAAAAA")


def test_proof_verifies_with_correct_token_and_nonce():
    token, nonce = generate_token(), generate_nonce()
    assert verify_proof(token, nonce, auth_proof(token, nonce))


def test_proof_fails_with_wrong_token():
    nonce = generate_nonce()
    assert not verify_proof(generate_token(), nonce, auth_proof(generate_token(), nonce))


def test_proof_fails_with_replayed_nonce():
    token = generate_token()
    proof_for_old_nonce = auth_proof(token, generate_nonce())
    assert not verify_proof(token, generate_nonce(), proof_for_old_nonce)


def test_proof_is_lowercase_hex_sha256():
    proof = auth_proof(generate_token(), generate_nonce())
    assert len(proof) == 64
    assert proof == proof.lower()
    int(proof, 16)


def test_verify_rejects_malformed_proof_without_raising():
    token, nonce = generate_token(), generate_nonce()
    assert not verify_proof(token, nonce, "short")
