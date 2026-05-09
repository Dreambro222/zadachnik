"""Smoke test for symmetric secret encryption. Run: python -m pytest tests/"""
from bot.services import crypto


def test_roundtrip():
    salt = crypto.new_user_salt()
    ct = crypto.encrypt_secret("word " * 24, "correct-horse-battery", "x" * 32, salt)
    pt = crypto.decrypt_secret(ct, "correct-horse-battery", "x" * 32, salt)
    assert pt == "word " * 24


def test_wrong_password_rejected():
    salt = crypto.new_user_salt()
    ct = crypto.encrypt_secret("hello", "right-pass", "y" * 32, salt)
    try:
        crypto.decrypt_secret(ct, "wrong-pass", "y" * 32, salt)
    except ValueError:
        return
    raise AssertionError("decrypt should have failed")


def test_master_salt_isolation():
    salt = crypto.new_user_salt()
    ct = crypto.encrypt_secret("data", "pwd", "salt-A" * 4, salt)
    try:
        crypto.decrypt_secret(ct, "pwd", "salt-B" * 4, salt)
    except ValueError:
        return
    raise AssertionError("different master salt should fail")
