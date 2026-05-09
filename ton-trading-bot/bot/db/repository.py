from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

import aiosqlite

SCHEMA_FILE = Path(__file__).parent / "schema.sql"


@dataclass
class Wallet:
    id: int
    user_id: int
    label: str
    address: str
    user_salt: bytes
    ciphertext: bytes
    secret_kind: str
    is_active: bool
    created_at: int


@dataclass
class Order:
    id: int
    user_id: int
    wallet_id: int
    kind: str
    side: str
    jetton_master: str
    jetton_symbol: Optional[str]
    trigger_price: float
    amount_units: str
    slippage_pct: float
    dex: str
    status: str
    last_error: Optional[str]
    tx_hash: Optional[str]
    created_at: int
    updated_at: int


class Repo:
    def __init__(self, db_path: str | Path):
        self.db_path = str(db_path)

    async def init(self) -> None:
        sql = SCHEMA_FILE.read_text(encoding="utf-8")
        async with aiosqlite.connect(self.db_path) as db:
            await db.executescript(sql)
            await db.commit()

    # ---------- users ----------

    async def ensure_user(self, user_id: int) -> None:
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                "INSERT OR IGNORE INTO users(user_id, created_at) VALUES (?, ?)",
                (user_id, int(time.time())),
            )
            await db.commit()

    # ---------- wallets ----------

    async def add_wallet(
        self,
        user_id: int,
        label: str,
        address: str,
        user_salt: bytes,
        ciphertext: bytes,
        secret_kind: str,
    ) -> int:
        async with aiosqlite.connect(self.db_path) as db:
            cur = await db.execute(
                """INSERT INTO wallets(user_id, label, address, user_salt, ciphertext, secret_kind, is_active, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, 1, ?)""",
                (user_id, label, address, user_salt, ciphertext, secret_kind, int(time.time())),
            )
            await db.commit()
            return cur.lastrowid

    async def list_wallets(self, user_id: int) -> list[Wallet]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM wallets WHERE user_id=? ORDER BY id ASC", (user_id,)
            ) as cur:
                rows = await cur.fetchall()
        return [_to_wallet(r) for r in rows]

    async def get_wallet(self, wallet_id: int, user_id: int) -> Optional[Wallet]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM wallets WHERE id=? AND user_id=?", (wallet_id, user_id)
            ) as cur:
                row = await cur.fetchone()
        return _to_wallet(row) if row else None

    async def get_active_wallet(self, user_id: int) -> Optional[Wallet]:
        wallets = await self.list_wallets(user_id)
        return next((w for w in wallets if w.is_active), wallets[0] if wallets else None)

    async def delete_wallet(self, wallet_id: int, user_id: int) -> None:
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                "DELETE FROM wallets WHERE id=? AND user_id=?", (wallet_id, user_id)
            )
            await db.commit()

    # ---------- orders ----------

    async def add_order(
        self,
        user_id: int,
        wallet_id: int,
        kind: str,
        side: str,
        jetton_master: str,
        jetton_symbol: Optional[str],
        trigger_price: float,
        amount_units: str,
        slippage_pct: float,
        dex: str,
    ) -> int:
        now = int(time.time())
        async with aiosqlite.connect(self.db_path) as db:
            cur = await db.execute(
                """INSERT INTO orders(user_id, wallet_id, kind, side, jetton_master, jetton_symbol,
                                      trigger_price, amount_units, slippage_pct, dex, status,
                                      created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)""",
                (user_id, wallet_id, kind, side, jetton_master, jetton_symbol,
                 trigger_price, amount_units, slippage_pct, dex, now, now),
            )
            await db.commit()
            return cur.lastrowid

    async def list_active_orders(self) -> list[Order]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM orders WHERE status='active' ORDER BY id ASC"
            ) as cur:
                rows = await cur.fetchall()
        return [_to_order(r) for r in rows]

    async def list_user_orders(self, user_id: int) -> list[Order]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            async with db.execute(
                "SELECT * FROM orders WHERE user_id=? ORDER BY id DESC", (user_id,)
            ) as cur:
                rows = await cur.fetchall()
        return [_to_order(r) for r in rows]

    async def update_order_status(
        self,
        order_id: int,
        status: str,
        last_error: Optional[str] = None,
        tx_hash: Optional[str] = None,
    ) -> None:
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                """UPDATE orders SET status=?, last_error=?, tx_hash=COALESCE(?, tx_hash), updated_at=?
                   WHERE id=?""",
                (status, last_error, tx_hash, int(time.time()), order_id),
            )
            await db.commit()

    async def cancel_order(self, order_id: int, user_id: int) -> None:
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                "UPDATE orders SET status='cancelled', updated_at=? WHERE id=? AND user_id=?",
                (int(time.time()), order_id, user_id),
            )
            await db.commit()

    # ---------- trades ----------

    async def log_trade(
        self,
        user_id: int,
        wallet_id: int,
        side: str,
        jetton_master: str,
        amount_in: str,
        amount_out_estimate: Optional[str],
        dex: str,
        status: str,
        order_id: Optional[int] = None,
        tx_hash: Optional[str] = None,
    ) -> int:
        async with aiosqlite.connect(self.db_path) as db:
            cur = await db.execute(
                """INSERT INTO trades(user_id, wallet_id, order_id, side, jetton_master,
                                      amount_in, amount_out_estimate, dex, tx_hash, status, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (user_id, wallet_id, order_id, side, jetton_master,
                 amount_in, amount_out_estimate, dex, tx_hash, status, int(time.time())),
            )
            await db.commit()
            return cur.lastrowid


def _to_wallet(r) -> Wallet:
    return Wallet(
        id=r["id"], user_id=r["user_id"], label=r["label"], address=r["address"],
        user_salt=r["user_salt"], ciphertext=r["ciphertext"],
        secret_kind=r["secret_kind"], is_active=bool(r["is_active"]),
        created_at=r["created_at"],
    )


def _to_order(r) -> Order:
    return Order(
        id=r["id"], user_id=r["user_id"], wallet_id=r["wallet_id"],
        kind=r["kind"], side=r["side"], jetton_master=r["jetton_master"],
        jetton_symbol=r["jetton_symbol"], trigger_price=r["trigger_price"],
        amount_units=r["amount_units"], slippage_pct=r["slippage_pct"],
        dex=r["dex"], status=r["status"], last_error=r["last_error"],
        tx_hash=r["tx_hash"], created_at=r["created_at"], updated_at=r["updated_at"],
    )
