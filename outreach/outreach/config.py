"""Configuration loading: .env + sender.yaml + offer.md."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent


def load_env() -> None:
    env_path = ROOT / ".env"
    if env_path.exists():
        load_dotenv(env_path)


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
        "name":    _env_or("name",    "SENDER_NAME"),
        "company": _env_or("company", "SENDER_COMPANY"),
        "email":   _env_or("email",   "SENDER_EMAIL"),
        "phone":   _env_or("phone",   "SENDER_PHONE"),
        "website": _env_or("website", "SENDER_WEBSITE"),
        "country": base.get("country") or "",
        "role":    base.get("role") or "",
    }


def load_offer() -> str:
    path = ROOT / "offer.md"
    return path.read_text(encoding="utf-8")
