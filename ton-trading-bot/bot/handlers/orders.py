from decimal import Decimal, InvalidOperation

from aiogram import F, Router
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from ..config import settings
from ..db.repository import Repo
from ..keyboards.inline import confirm_cancel, order_kinds
from ..services.dex import get_dex
from ..services.ton_client import get_jetton_balance
from ..services.wallet_unlock import unlock_cache
from ..states.flows import CreateOrder
from ..utils.format import fmt_amount

router = Router()


# ---------------- list / cancel ----------------

@router.message(Command("orders"))
@router.callback_query(F.data == "menu:orders")
async def list_orders(event: Message | CallbackQuery, repo: Repo):
    msg = event.message if isinstance(event, CallbackQuery) else event
    items = await repo.list_user_orders(event.from_user.id)
    if not items:
        return await msg.answer(
            "Активных ордеров нет.\n\n"
            "Создать: /neworder — Stop-Loss или Take-Profit, "
            "бот сам отправит свап в чейн при достижении цены."
        )
    lines = []
    for o in items[:30]:
        lines.append(
            f"#{o.id} <b>{o.kind}</b> {o.side} "
            f"<code>{o.jetton_master[:6]}...{o.jetton_master[-4:]}</code> "
            f"@ {o.trigger_price} TON  [{o.status}]"
        )
    await msg.answer(
        "\n".join(lines) + "\n\n/cancelorder ID — отменить",
    )


@router.message(Command("cancelorder"))
async def cancel_order_cmd(msg: Message, repo: Repo):
    parts = (msg.text or "").split()
    if len(parts) != 2 or not parts[1].isdigit():
        return await msg.answer("Использование: /cancelorder <id>")
    await repo.cancel_order(int(parts[1]), msg.from_user.id)
    await msg.answer("Ордер отменён.")


# ---------------- create flow ----------------

@router.message(Command("neworder"))
async def neworder_start(msg: Message, state: FSMContext, repo: Repo):
    if not await repo.get_active_wallet(msg.from_user.id):
        return await msg.answer("Сначала добавь кошелёк: /addwallet")
    if not unlock_cache.get(msg.from_user.id):
        return await msg.answer("Сначала разлочь: /unlock (пароль нужен и для размещения ордера, "
                                "так как при срабатывании бот должен подписать транзакцию).")
    await state.set_state(CreateOrder.waiting_kind)
    await msg.answer("Какой ордер?", reply_markup=order_kinds())


@router.callback_query(CreateOrder.waiting_kind, F.data.startswith("order_kind:"))
async def neworder_kind(cb: CallbackQuery, state: FSMContext):
    kind = cb.data.split(":", 1)[1]  # 'stop_loss' | 'take_profit'
    await state.update_data(kind=kind, side="sell")
    await state.set_state(CreateOrder.waiting_jetton)
    await cb.message.edit_text("Адрес master-контракта jetton, который продавать:")


@router.message(CreateOrder.waiting_jetton)
async def neworder_jetton(msg: Message, state: FSMContext, repo: Repo):
    addr = (msg.text or "").strip()
    if len(addr) < 40:
        return await msg.answer("Это не похоже на адрес. Попробуй ещё раз:")
    w = await repo.get_active_wallet(msg.from_user.id)
    try:
        raw, decimals = await get_jetton_balance(w.address, addr)
    except Exception as e:
        await state.clear()
        return await msg.answer(f"Не получилось узнать баланс: {e}")
    await state.update_data(jetton_master=addr, decimals=decimals, raw_balance=raw)
    await state.set_state(CreateOrder.waiting_amount)
    await msg.answer(
        f"Баланс: {fmt_amount(raw, decimals)}\n"
        "Сколько продавать при срабатывании? (число или 'all')"
    )


@router.message(CreateOrder.waiting_amount)
async def neworder_amount(msg: Message, state: FSMContext):
    text = (msg.text or "").strip().lower().replace(",", ".")
    data = await state.get_data()
    decimals = int(data["decimals"])
    raw_balance = int(data["raw_balance"])
    if text == "all":
        units = raw_balance
    else:
        try:
            v = Decimal(text)
            if v <= 0:
                raise InvalidOperation
            units = int(v * (Decimal(10) ** decimals))
        except InvalidOperation:
            return await msg.answer("Нужно положительное число или 'all'.")
        if units > raw_balance:
            return await msg.answer("Больше баланса. Введи меньшее значение.")
    await state.update_data(amount_units=str(units))
    await state.set_state(CreateOrder.waiting_trigger_price)
    kind = data["kind"]
    hint = "ниже которой" if kind == "stop_loss" else "выше которой"
    await msg.answer(
        f"Цена-триггер (TON за 1 jetton), {hint} сработать.\n"
        "Например, 0.0025"
    )


@router.message(CreateOrder.waiting_trigger_price)
async def neworder_price(msg: Message, state: FSMContext):
    try:
        price = Decimal((msg.text or "").strip().replace(",", "."))
        if price <= 0:
            raise InvalidOperation
    except InvalidOperation:
        return await msg.answer("Цена должна быть положительным числом.")
    data = await state.get_data()
    await state.update_data(trigger_price=str(price))
    await state.set_state(CreateOrder.confirm)
    await msg.answer(
        f"<b>Создать {data['kind']}</b>\n"
        f"Продать: {data['amount_units']} (smallest units)\n"
        f"Триггер: {price} TON за jetton\n"
        f"DEX: {settings.default_dex}\n"
        f"Slippage: {settings.default_slippage}%\n\n"
        "Подтвердить?",
        reply_markup=confirm_cancel("order:confirm"),
    )


@router.callback_query(CreateOrder.confirm, F.data == "order:confirm")
async def neworder_confirm(cb: CallbackQuery, state: FSMContext, repo: Repo):
    data = await state.get_data()
    w = await repo.get_active_wallet(cb.from_user.id)
    oid = await repo.add_order(
        user_id=cb.from_user.id,
        wallet_id=w.id,
        kind=data["kind"],
        side="sell",
        jetton_master=data["jetton_master"],
        jetton_symbol=None,
        trigger_price=float(data["trigger_price"]),
        amount_units=data["amount_units"],
        slippage_pct=settings.default_slippage,
        dex=settings.default_dex,
    )
    await state.clear()
    await cb.message.edit_text(
        f"Ордер #{oid} создан и активен.\n"
        "Бот будет проверять цену в фоне и автоматически отправит свап в чейн при срабатывании.\n"
        "Для этого сессия должна быть разлочена (/unlock) — иначе ордер пометится failed."
    )
