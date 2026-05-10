"""Configuration loading: .env + sender.yaml + offer.md + mailer + inbox."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent


def load_env() -> None:
    env_path = ROOT / ".env"
    if env_path.exists():
        load_dotenv(env_path)


@dataclass
class MailerConfig:
    host: str
    port: int
    user: str
    password: str
    use_tls: bool                      # True = STARTTLS, False = SSL
    from_name: str
    from_email: str
    reply_to: str | None
    daily_limit: int
    delay_seconds: int


@dataclass
class InboxConfig:
    host: str
    port: int
    user: str
    password: str
    folder: str
    poll_seconds: int


def _bool(value: str | None, default: bool = True) -> bool:
    if value is None or value == "":
        return default
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def load_mailer() -> MailerConfig:
    load_env()
    host = os.environ.get("SMTP_HOST", "")
    user = os.environ.get("SMTP_USER", "")
    if not host or not user:
        raise RuntimeError(
            "SMTP_HOST and SMTP_USER must be set in .env before sending mail"
        )
    return MailerConfig(
        host=host,
        port=int(os.environ.get("SMTP_PORT") or 587),
        user=user,
        password=os.environ.get("SMTP_PASSWORD", ""),
        use_tls=_bool(os.environ.get("SMTP_USE_TLS"), default=True),
        from_name=os.environ.get("SMTP_FROM_NAME") or os.environ.get("SENDER_NAME") or "",
        from_email=os.environ.get("SMTP_FROM_EMAIL") or user,
        reply_to=os.environ.get("REPLY_TO") or None,
        daily_limit=int(os.environ.get("MAIL_DAILY_LIMIT") or 20),
        delay_seconds=int(os.environ.get("MAIL_DELAY_SECONDS") or 30),
    )


def load_inbox() -> InboxConfig:
    load_env()
    host = os.environ.get("IMAP_HOST", "")
    user = os.environ.get("IMAP_USER", "")
    if not host or not user:
        raise RuntimeError(
            "IMAP_HOST and IMAP_USER must be set in .env before polling inbox"
        )
    return InboxConfig(
        host=host,
        port=int(os.environ.get("IMAP_PORT") or 993),
        user=user,
        password=os.environ.get("IMAP_PASSWORD", ""),
        folder=os.environ.get("IMAP_FOLDER") or "INBOX",
        poll_seconds=int(os.environ.get("IMAP_POLL_SECONDS") or 120),
    )


def load_sender() -> dict[str, Any]:
    load_env()
    yaml_path = ROOT / "sender.yaml"
    base: dict[str, Any] = {}
    if yaml_path.exists():
        with yaml_path.open("r", encoding="utf-8") as f:
            base = yaml.safe_load(f) or {}

    def _env_or(key: str, env_key: str) -> Any:
        return base.get(key) or os.environ.get(env_key) or ""

    return {
        "name":          _env_or("name",    "SENDER_NAME"),
        "company":       _env_or("company", "SENDER_COMPANY"),
        "email":         _env_or("email",   "SENDER_EMAIL"),
        "phone":         _env_or("phone",   "SENDER_PHONE"),
        "website":       _env_or("website", "SENDER_WEBSITE"),
        "country":       base.get("country") or "",
        "role":          base.get("role") or "",
        "address":       base.get("address") or "",
        "product_short": base.get("product_short") or "",
    }


def load_offer() -> str:
    path = ROOT / "offer.md"
    return path.read_text(encoding="utf-8")
