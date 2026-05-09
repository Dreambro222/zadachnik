from aiogram import Router
from aiogram.filters import CommandStart, Command
from aiogram.types import Message

from ..keyboards.inline import main_menu

router = Router()


WELCOME = (
    "<b>TON Trading Bot</b>\n\n"
    "Этот бот позволяет торговать токенами на сети TON прямо из Telegram:\n"
    "• Купить / продать через STON.fi или DeDust\n"
    "• Поставить Stop-Loss / Take-Profit — бот сам отправит свап в чейн при срабатывании\n"
    "• Хранение приватного ключа: только в зашифрованном виде локально, ключ шифруется паролем, который знаешь только ты\n\n"
    "<b>Безопасность.</b> Бот хранит зашифрованный мнемоник; пароль не сохраняется. "
    "Перед каждой сессией торговли потребуется ввести пароль, чтобы разлочить кошелёк.\n\n"
    "Команды:\n"
    "/wallet — управление кошельками\n"
    "/buy — купить токен за TON\n"
    "/sell — продать токен за TON\n"
    "/orders — Stop-Loss / Take-Profit\n"
    "/balance — балансы\n"
    "/lock — заблокировать сессию\n"
)


@router.message(CommandStart())
async def on_start(msg: Message):
    await msg.answer(WELCOME, reply_markup=main_menu())


@router.message(Command("help"))
async def on_help(msg: Message):
    await msg.answer(WELCOME, reply_markup=main_menu())
