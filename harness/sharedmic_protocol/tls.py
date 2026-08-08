"""Self-signed device certificates and fingerprint pinning.

Trust comes from the fingerprint pinned during pairing, not from a
certificate authority. CA verification is therefore disabled on purpose;
the pin is the check, and it is enforced in MockMacClient after the
handshake completes.

Private key material is never logged. `server_context()` writes the key to
a temporary directory only for the duration of `load_cert_chain()` (the
stdlib `ssl` module has no way to load from memory) and removes the
directory before returning, so no key file survives on disk past this
call.
"""

import datetime
import hashlib
import ssl
import tempfile
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

CERT_VALIDITY_DAYS = 3650


def generate_self_signed_cert(common_name: str = "shared-mic") -> tuple[bytes, bytes]:
    """Generate a self-signed EC device certificate and its private key.

    Returns (cert_pem, key_pem). There is no CA anywhere in this design —
    the certificate exists only so its fingerprint can be pinned.
    """
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=CERT_VALIDITY_DAYS))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(common_name)]), critical=False)
        .sign(key, hashes.SHA256())
    )
    cert_pem = certificate.public_bytes(serialization.Encoding.PEM)
    key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return cert_pem, key_pem


def certificate_fingerprint(cert_pem: bytes) -> str:
    """Lowercase hex SHA-256 of the certificate's DER encoding.

    This is the value pinned during pairing and re-checked on every
    connection by MockMacClient — it is the entire trust model.
    """
    der = x509.load_pem_x509_certificate(cert_pem).public_bytes(serialization.Encoding.DER)
    return hashlib.sha256(der).hexdigest()


def server_context(cert_pem: bytes, key_pem: bytes) -> ssl.SSLContext:
    """Build a server-side TLS context serving the given certificate/key.

    The stdlib `ssl` module can only load a certificate chain from files on
    disk, so the PEM bytes are written to a temporary directory that is
    deleted again as soon as load_cert_chain() has read them — no key
    material is left behind once this function returns.
    """
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    with tempfile.TemporaryDirectory(prefix="sharedmic-tls-") as directory:
        cert_path = Path(directory) / "cert.pem"
        key_path = Path(directory) / "key.pem"
        cert_path.write_bytes(cert_pem)
        key_path.write_bytes(key_pem)
        context.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    return context


def client_context() -> ssl.SSLContext:
    """Build a client-side TLS context with CA verification disabled.

    This is intentional, not a bug: there is no certificate authority
    anywhere in this design. Trust comes entirely from the fingerprint
    pinned during pairing and checked by the caller after the handshake
    (MockMacClient._open_socket) — a mismatch there is a hard stop.
    """
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context
