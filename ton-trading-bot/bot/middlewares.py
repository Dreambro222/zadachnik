from __future__ import annotations

from typing import Any, Awaitable, Callable

from aiogram import BaseMiddleware
from aiogram.types import TelegramObject, Update

from .config import settings


class AllowlistMiddleware(BaseMiddleware):
    """Drops any update from a user not in ALLOWED_USER_IDS."""

    async def __call__(
        self,
        handler: Callable[[TelegramObject, dict[str, Any]], Awaitable[Any]],
        event: TelegramObject,
        data: dict[str, Any],
    ) -> Any:
        user = data.get("event_from_user")
        if user is None or user.id not in settings.allowed_user_ids:
            # Silently ignore. Sending a message would help an attacker
            # confirm the bot is up.
            return None
        return await handler(event, data)
