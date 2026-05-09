from aiogram import Router

from . import start, wallet, trade, orders, settings as settings_handler


def build_router() -> Router:
    root = Router()
    root.include_router(start.router)
    root.include_router(wallet.router)
    root.include_router(trade.router)
    root.include_router(orders.router)
    root.include_router(settings_handler.router)
    return root
