"""
Glue layer: takes a stored encrypted wallet + a password, instantiates a
signed `WalletV4R2`, executes a swap on the chosen DEX, and returns the tx hash.

Used by both interactive buy/sell handlers and the SL/TP order watcher.
"""
from __future__ import annotations

import logging
from decimal import Decimal
from typing import Optional

from ..config import settings
from ..db.repository import Repo, Wallet
from ..services import crypto
from ..services.dex import DexName, Side, get_dex
from ..services.ton_client import wallet_from_mnemonic

log = logging.getLogger(__name__)


class TradeError(Exception):
    pass


async def execute_swap(
    repo: Repo,
    wallet_row: Wallet,
    password: str,
    jetton_master: str,
    side: Side,
    amount_in_units: int,
    slippage_pct: float,
    dex_name: Optional[DexName] = None,
    order_id: Optional[int] = None,
) -> str:
    """
    Decrypt mnemonic with `password`, send swap, log a trade row.
    Returns external message hash (string).
    """
    if wallet_row.secret_kind != "mnemonic":
        raise TradeError(f"Unsupported secret kind: {wallet_row.secret_kind}")

    try:
        mnemonic = crypto.decrypt_secret(
            wallet_row.ciphertext, password, settings.master_salt, wallet_row.user_salt
        )
    except ValueError as e:
        raise TradeError("Wrong password") from e

    kp = await wallet_from_mnemonic(mnemonic)
    dex = get_dex(dex_name)

    try:
        tx_hash = await dex.swap(
            wallet=kp.wallet,
            jetton_master=jetton_master,
            side=side,
            amount_in=amount_in_units,
            slippage_pct=slippage_pct,
        )
    except Exception as e:
        await repo.log_trade(
            user_id=wallet_row.user_id, wallet_id=wallet_row.id,
            side=side, jetton_master=jetton_master,
            amount_in=str(amount_in_units), amount_out_estimate=None,
            dex=dex.name, status="failed", order_id=order_id, tx_hash=None,
        )
        raise TradeError(f"DEX swap failed: {e}") from e

    await repo.log_trade(
        user_id=wallet_row.user_id, wallet_id=wallet_row.id,
        side=side, jetton_master=jetton_master,
        amount_in=str(amount_in_units), amount_out_estimate=None,
        dex=dex.name, status="sent", order_id=order_id, tx_hash=str(tx_hash),
    )
    return str(tx_hash)
