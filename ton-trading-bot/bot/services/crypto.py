"""
Symmetric encryption of wallet private keys / mnemonics.

Key derivation: PBKDF2-HMAC-SHA256(password + master_salt + user_salt) -> Fernet key.

Storage layout per wallet row:
  - user_salt:   random 16 bytes, stored alongside ciphertext
  - ciphertext:  Fernet token of mnemonic (or hex private key)

The user provides a password through the bot. We never persist the password —
it is held only in memory of the running process for the duration of a session,
and we re-prompt if it expires. To trade or sign, the password must be unlocked.
"""
from __future__ import annotations

import base64
import os

from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

PBKDF2_ITERATIONS = 480_000


def _derive_key(password: str, master_salt: str, user_salt: bytes) -> bytes:
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=user_salt + master_salt.encode("utf-8"),
        iterations=PBKDF2_ITERATIONS,
    )
    return base64.urlsafe_b64encode(kdf.derive(password.encode("utf-8")))


def new_user_salt() -> bytes:
    return os.urandom(16)


def encrypt_secret(secret: str, password: str, master_salt: str, user_salt: bytes) -> bytes:
    key = _derive_key(password, master_salt, user_salt)
    return Fernet(key).encrypt(secret.encode("utf-8"))


def decrypt_secret(token: bytes, password: str, master_salt: str, user_salt: bytes) -> str:
    key = _derive_key(password, master_salt, user_salt)
    try:
        return Fernet(key).decrypt(token).decode("utf-8")
    except InvalidToken as e:
        raise ValueError("Wrong password or corrupted data") from e
