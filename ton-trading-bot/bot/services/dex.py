"""
DEX abstraction over STON.fi and DeDust.

Both DEXes on TON work the same way from the user's perspective:
the wallet sends a TON-with-payload (or jetton transfer with payload) to the
router contract, which executes the swap and returns the output token.

`tonutils` ships ready-made helpers (`StonfiRouterV1`, `DedustFactory`) that
build the correct internal message body. We expose a uniform `DEX` interface
on top of them so handlers can stay agnostic.

Price quote: we read the on-chain pool reserves and compute spot price as
reserve_out / reserve_in (after the constant-product fee), giving us the
TON-per-jetton price used by the stop-loss/take-profit engine.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from decimal import Decimal
from typing import Literal, Protocol

from tonutils.dex.dedust import Factory as DedustFactory
from tonutils.dex.stonfi import StonfiRouterV1
from tonutils.utils import to_amount, to_nano
from tonutils.wallet import WalletV4R2

from ..config import settings
from .ton_client import make_client

log = logging.getLogger(__name__)

DexName = Literal["stonfi", "dedust"]
Side = Literal["buy", "sell"]  # buy = TON -> jetton, sell = jetton -> TON


@dataclass
class Quote:
    dex: DexName
    side: Side
    amount_in: int          # smallest units of input token
    amount_out: int         # smallest units of output token (estimated)
    price_jetton_in_ton: Decimal  # 1 jetton = X TON


class DEX(Protocol):
    name: DexName

    async def quote(self, jetton_master: str, side: Side, amount_in: int) -> Quote: ...
    async def swap(
        self,
        wallet: WalletV4R2,
        jetton_master: str,
        side: Side,
        amount_in: int,
        slippage_pct: float,
    ) -> str:
        """Sends the swap and returns the external message hash."""


class StonfiDEX:
    name: DexName = "stonfi"

    async def quote(self, jetton_master: str, side: Side, amount_in: int) -> Quote:
        client = make_client()
        router = StonfiRouterV1(client)
        if side == "buy":
            est = await router.get_swap_ton_to_jetton_estimate(
                offer_jetton_address="ton",  # native TON
                ask_jetton_address=jetton_master,
                offer_amount=amount_in,
            )
            amount_out = int(est.ask_units)
            price = (Decimal(amount_in) / Decimal(amount_out)) if amount_out else Decimal(0)
        else:
            est = await router.get_swap_jetton_to_ton_estimate(
                offer_jetton_address=jetton_master,
                offer_amount=amount_in,
            )
            amount_out = int(est.ask_units)
            price = (Decimal(amount_out) / Decimal(amount_in)) if amount_in else Decimal(0)
        return Quote(self.name, side, amount_in, amount_out, price)

    async def swap(self, wallet, jetton_master, side, amount_in, slippage_pct):
        client = make_client()
        router = StonfiRouterV1(client)
        min_out = await self._min_out(jetton_master, side, amount_in, slippage_pct)
        if side == "buy":
            tx = await router.swap_ton_to_jetton(
                wallet=wallet,
                jetton_master_address=jetton_master,
                ton_amount=amount_in,
                min_ask_amount=min_out,
            )
        else:
            tx = await router.swap_jetton_to_ton(
                wallet=wallet,
                jetton_master_address=jetton_master,
                jetton_amount=amount_in,
                min_ask_amount=min_out,
            )
        return tx

    async def _min_out(self, jetton_master, side, amount_in, slippage_pct) -> int:
        q = await self.quote(jetton_master, side, amount_in)
        return int(q.amount_out * (100 - slippage_pct) / 100)


class DedustDEX:
    name: DexName = "dedust"

    async def quote(self, jetton_master: str, side: Side, amount_in: int) -> Quote:
        client = make_client()
        factory = DedustFactory(client)
        if side == "buy":
            est = await factory.get_swap_estimate_native_to_jetton(jetton_master, amount_in)
            amount_out = int(est.amount_out)
            price = (Decimal(amount_in) / Decimal(amount_out)) if amount_out else Decimal(0)
        else:
            est = await factory.get_swap_estimate_jetton_to_native(jetton_master, amount_in)
            amount_out = int(est.amount_out)
            price = (Decimal(amount_out) / Decimal(amount_in)) if amount_in else Decimal(0)
        return Quote(self.name, side, amount_in, amount_out, price)

    async def swap(self, wallet, jetton_master, side, amount_in, slippage_pct):
        client = make_client()
        factory = DedustFactory(client)
        q = await self.quote(jetton_master, side, amount_in)
        min_out = int(q.amount_out * (100 - slippage_pct) / 100)
        if side == "buy":
            return await factory.swap_native_to_jetton(
                wallet=wallet, jetton_master=jetton_master,
                amount=amount_in, min_amount_out=min_out,
            )
        return await factory.swap_jetton_to_native(
            wallet=wallet, jetton_master=jetton_master,
            amount=amount_in, min_amount_out=min_out,
        )


_REGISTRY: dict[DexName, DEX] = {"stonfi": StonfiDEX(), "dedust": DedustDEX()}


def get_dex(name: DexName | None = None) -> DEX:
    return _REGISTRY[name or settings.default_dex]
