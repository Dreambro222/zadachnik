from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    bot_token: str
    allowed_user_ids: list[int] = Field(default_factory=list)
    ton_network: Literal["mainnet", "testnet"] = "mainnet"
    db_path: str = "./data/bot.db"
    master_salt: str
    toncenter_api_key: str = ""
    order_poll_interval: int = 15
    default_dex: Literal["stonfi", "dedust"] = "stonfi"
    default_slippage: float = 1.0

    @field_validator("allowed_user_ids", mode="before")
    @classmethod
    def parse_ids(cls, v):
        if isinstance(v, str):
            return [int(x.strip()) for x in v.split(",") if x.strip()]
        return v

    @field_validator("master_salt")
    @classmethod
    def salt_strength(cls, v: str):
        if len(v) < 16:
            raise ValueError("MASTER_SALT must be at least 16 chars")
        return v

    def db_file(self) -> Path:
        p = Path(self.db_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        return p


settings = Settings()
