"""
Thin wrapper around `tonutils` for the operations the bot actually performs:

  - derive a wallet from a 24-word mnemonic
  - read TON balance and jetton balance
  - swap TON <-> jetton via STON.fi or DeDust

`tonutils` exposes WalletV4R2 (the standard v4r2 wallet contract) and
ready-to-use DEX swap helpers, so we keep this module small and let `tonutils`
handle the on-chain encoding.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from decimal import Decimal
from typing import Optional

from tonutils.client import TonapiClient, ToncenterClient
from tonutils.jetton import JettonMaster, JettonWallet
from tonutils.utils import to_amount, to_nano
from tonutils.wallet import WalletV4R2

from ..config import settings

log = logging.getLogger(__name__)


@dataclass
class WalletKeypair:
    address: str
    wallet: WalletV4R2  # holds private key in memory only
    public_key: bytes


def make_client():
    """Toncenter REST client (free tier OK; provide TONCENTER_API_KEY for higher limits)."""
    return ToncenterClient(
        api_key=settings.toncenter_api_key or None,
        is_testnet=settings.ton_network == "testnet",
    )


async def wallet_from_mnemonic(mnemonic: str) -> WalletKeypair:
    """Restore a v4r2 wallet from a 24-word BIP-39 style TON mnemonic."""
    words = mnemonic.strip().split()
    if len(words) not in (12, 24):
        raise ValueError("Mnemonic must be 12 or 24 words")
    client = make_client()
    wallet, public_key, _private_key, _seed = WalletV4R2.from_mnemonic(client, words)
    return WalletKeypair(address=wallet.address.to_str(), wallet=wallet, public_key=public_key)


async def get_ton_balance(address: str) -> Decimal:
    """Returns TON balance in TON (not nanotons)."""
    client = make_client()
    info = await client.run_get_method(address=address, method_name="seqno", stack=[])  # cheap probe
    # Use account info endpoint via tonutils helper:
    raw = await client.get_account_info(address)
    nanotons = int(raw.get("balance", 0))
    return Decimal(nanotons) / Decimal(10**9)


async def get_jetton_balance(owner_address: str, jetton_master: str) -> tuple[int, int]:
    """
    Returns (raw_units, decimals) of jetton on owner's wallet.
    raw_units is the smallest-unit integer balance.
    """
    client = make_client()
    master = JettonMaster(client, jetton_master)
    jw_address = await master.get_wallet_address(owner_address)
    jw = JettonWallet(client, jw_address)
    data = await jw.get_wallet_data()
    decimals = await master.get_decimals()
    return int(data.balance), int(decimals)


def format_units(raw: int, decimals: int) -> str:
    if decimals <= 0:
        return str(raw)
    s = str(raw).rjust(decimals + 1, "0")
    int_part, frac = s[:-decimals], s[-decimals:].rstrip("0")
    return f"{int_part}.{frac}" if frac else int_part
