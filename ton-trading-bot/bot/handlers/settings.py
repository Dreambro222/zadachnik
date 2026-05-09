from aiogram import F, Router
from aiogram.filters import Command
from aiogram.types import CallbackQuery, Message

from ..config import settings as app_settings

router = Router()


@router.message(Command("settings"))
@router.callback_query(F.data == "menu:settings")
async def show_settings(event: Message | CallbackQuery):
    msg = event.message if isinstance(event, CallbackQuery) else event
    await msg.answer(
        "<b>Настройки</b>\n"
        f"Сеть: {app_settings.ton_network}\n"
        f"DEX по умолчанию: {app_settings.default_dex}\n"
        f"Slippage по умолчанию: {app_settings.default_slippage}%\n"
        f"Watcher SL/TP: каждые {app_settings.order_poll_interval}s\n\n"
        "Эти параметры задаются в .env."
    )
