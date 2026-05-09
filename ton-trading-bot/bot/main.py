from __future__ import annotations

import asyncio
import logging

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.fsm.storage.memory import MemoryStorage

from .config import settings
from .db.repository import Repo
from .handlers import build_router
from .middlewares import AllowlistMiddleware
from .services.orders_engine import run_watcher


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("bot")


async def main() -> None:
    repo = Repo(settings.db_file())
    await repo.init()

    bot = Bot(
        token=settings.bot_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher(storage=MemoryStorage())

    # inject repo into every handler
    dp["repo"] = repo

    dp.update.outer_middleware(AllowlistMiddleware())
    dp.include_router(build_router())

    async def notify(user_id: int, text: str) -> None:
        try:
            await bot.send_message(user_id, text)
        except Exception:
            log.exception("failed to notify user %s", user_id)

    watcher_task = asyncio.create_task(run_watcher(repo, notify), name="orders-watcher")

    log.info("bot is starting (network=%s, dex=%s)", settings.ton_network, settings.default_dex)
    try:
        await dp.start_polling(bot)
    finally:
        watcher_task.cancel()
        try:
            await watcher_task
        except asyncio.CancelledError:
            pass
        await bot.session.close()


if __name__ == "__main__":
    asyncio.run(main())
