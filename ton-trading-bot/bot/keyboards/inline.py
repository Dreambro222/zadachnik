from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup
from aiogram.utils.keyboard import InlineKeyboardBuilder


def main_menu() -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="Кошелёк", callback_data="menu:wallet")
    kb.button(text="Купить", callback_data="menu:buy")
    kb.button(text="Продать", callback_data="menu:sell")
    kb.button(text="Ордера (SL/TP)", callback_data="menu:orders")
    kb.button(text="Настройки", callback_data="menu:settings")
    kb.adjust(1, 2, 1, 1)
    return kb.as_markup()


def confirm_cancel(confirm_data: str, cancel_data: str = "cancel") -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="Подтвердить", callback_data=confirm_data)
    kb.button(text="Отмена", callback_data=cancel_data)
    kb.adjust(2)
    return kb.as_markup()


def order_kinds() -> InlineKeyboardMarkup:
    kb = InlineKeyboardBuilder()
    kb.button(text="Stop-Loss (продать при падении)", callback_data="order_kind:stop_loss")
    kb.button(text="Take-Profit (продать при росте)", callback_data="order_kind:take_profit")
    kb.adjust(1)
    return kb.as_markup()
