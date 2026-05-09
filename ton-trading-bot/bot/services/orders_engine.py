"""
Background task that polls all active orders, queries the chosen DEX for the
current price (TON per jetton), and triggers a swap when the condition is met.

Trigger logic
-------------
For a `sell` side order (the bot only supports sells today — protective exits):
  - stop_loss   triggers when price <= trigger_price
  - take_profit triggers when price >= trigger_price

When the trigger fires, the engine attempts to execute the swap using the
user's cached password. If the user has locked their session (no password in
unlock_cache), the order stays `active` so it can fire later — but the user is
notified via the bot that they should /unlock.

Notification: pass a callback `notify(user_id, text)` from main so this
module stays decoupled from aiogram internals.
"""
from __future__ import annotations

import asyncio
import logging
from decimal import Decimal
from typing import Awaitable, Callable

from ..config import settings
from ..db.repository import Order, Repo
from ..services.dex import get_dex
from ..services.trade_executor import TradeError, execute_swap
from ..services.wallet_unlock import unlock_cache

log = logging.getLogger(__name__)

NotifyFn = Callable[[int, str], Awaitable[None]]

# Quote with this much input to reduce slippage error in spot price.
QUOTE_PROBE_TON_NANO = 1_000_000_000  # 1 TON


def _condition_met(order: Order, current_price: Decimal) -> bool:
    if order.kind == "stop_loss":
        return current_price <= Decimal(str(order.trigger_price))
    if order.kind == "take_profit":
        return current_price >= Decimal(str(order.trigger_price))
    return False


async def _spot_price(order: Order) -> Decimal:
    """Returns TON-per-jetton spot price quoted by the order's DEX."""
    dex = get_dex(order.dex)  # type: ignore[arg-type]
    # Use a buy quote: amount of jetton you'd get for 1 TON, then invert.
    q = await dex.quote(order.jetton_master, "buy", QUOTE_PROBE_TON_NANO)
    if q.amount_out == 0:
        return Decimal(0)
    return (Decimal(QUOTE_PROBE_TON_NANO) / Decimal(q.amount_out))


async def _try_fire(order: Order, repo: Repo, notify: NotifyFn) -> None:
    password = unlock_cache.get(order.user_id)
    if not password:
        await notify(
            order.user_id,
            f"⚠️ Ордер #{order.id} достиг триггера, но сессия заблокирована. "
            "Сделай /unlock, чтобы бот смог отправить свап.",
        )
        return

    wallet = await repo.get_wallet(order.wallet_id, order.user_id)
    if not wallet:
        await repo.update_order_status(order.id, "failed", last_error="wallet missing")
        return

    await repo.update_order_status(order.id, "triggered")
    try:
        tx = await execute_swap(
            repo=repo,
            wallet_row=wallet,
            password=password,
            jetton_master=order.jetton_master,
            side=order.side,  # type: ignore[arg-type]
            amount_in_units=int(order.amount_units),
            slippage_pct=order.slippage_pct,
            dex_name=order.dex,  # type: ignore[arg-type]
            order_id=order.id,
        )
    except TradeError as e:
        await repo.update_order_status(order.id, "failed", last_error=str(e))
        await notify(order.user_id, f"❌ Ордер #{order.id} не исполнился: {e}")
        return

    await repo.update_order_status(order.id, "filled", tx_hash=tx)
    await notify(
        order.user_id,
        f"✅ Ордер #{order.id} ({order.kind}) исполнён.\nTX: <code>{tx}</code>",
    )


async def run_watcher(repo: Repo, notify: NotifyFn) -> None:
    interval = max(5, int(settings.order_poll_interval))
    log.info("orders watcher started, interval=%ss", interval)
    while True:
        try:
            active = await repo.list_active_orders()
            for order in active:
                try:
                    price = await _spot_price(order)
                except Exception as e:
                    log.warning("price probe failed for order %s: %s", order.id, e)
                    continue
                if _condition_met(order, price):
                    log.info("order %s triggered at price %s", order.id, price)
                    await _try_fire(order, repo, notify)
        except Exception:
            log.exception("watcher loop iteration failed")
        await asyncio.sleep(interval)
