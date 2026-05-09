from decimal import Decimal, InvalidOperation

from aiogram import F, Router
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from ..config import settings
from ..db.repository import Repo
from ..keyboards.inline import confirm_cancel
from ..services.dex import get_dex
from ..services.ton_client import get_jetton_balance
from ..services.trade_executor import execute_swap, TradeError
from ..services.wallet_unlock import unlock_cache
from ..states.flows import Buy, Sell
from ..utils.format import fmt_amount

router = Router()


def _require_unlock(user_id: int) -> str | None:
    return unlock_cache.get(user_id)


# ----------------------- BUY (TON -> jetton) -----------------------

@router.message(Command("buy"))
@router.callback_query(F.data == "menu:buy")
async def buy_start(event: Message | CallbackQuery, state: FSMContext, repo: Repo):
    user_id = event.from_user.id
    msg = event.message if isinstance(event, CallbackQuery) else event
    if not await repo.get_active_wallet(user_id):
        return await msg.answer("Сначала добавь кошелёк: /addwallet")
    if not _require_unlock(user_id):
        return await msg.answer("Сессия заблокирована. Разлочь: /unlock")
    await state.set_state(Buy.waiting_jetton)
    await msg.answer("Адрес master-контракта jetton (EQ.../UQ...):")


@router.message(Buy.waiting_jetton)
async def buy_jetton(msg: Message, state: FSMContext):
    addr = (msg.text or "").strip()
    if len(addr) < 40:
        return await msg.answer("Это не похоже на адрес. Попробуй ещё раз:")
    await state.update_data(jetton_master=addr)
    await state.set_state(Buy.waiting_ton_amount)
    await msg.answer("Сколько TON потратить? (например, 1.5)")


@router.message(Buy.waiting_ton_amount)
async def buy_amount(msg: Message, state: FSMContext):
    try:
        ton = Decimal((msg.text or "").strip().replace(",", "."))
        if ton <= 0:
            raise InvalidOperation
    except InvalidOperation:
        return await msg.answer("Нужно положительное число. Сколько TON?")
    nanotons = int(ton * 10**9)
    data = await state.get_data()
    dex = get_dex()
    try:
        q = await dex.quote(data["jetton_master"], "buy", nanotons)
    except Exception as e:
        await state.clear()
        return await msg.answer(f"Не получилось получить котировку: {e}")
    await state.update_data(amount=nanotons, est_out=q.amount_out, dex=dex.name)
    text = (
        f"<b>Покупка</b> через {dex.name}\n"
        f"Потратить: {ton} TON\n"
        f"Получишь ≈ {q.amount_out} (smallest units)\n"
        f"Slippage: {settings.default_slippage}%\n\n"
        "Подтвердить отправку в чейн?"
    )
    await state.set_state(Buy.confirm)
    await msg.answer(text, reply_markup=confirm_cancel("buy:confirm"))


@router.callback_query(Buy.confirm, F.data == "buy:confirm")
async def buy_confirm(cb: CallbackQuery, state: FSMContext, repo: Repo):
    user_id = cb.from_user.id
    password = _require_unlock(user_id)
    if not password:
        await state.clear()
        return await cb.message.edit_text("Сессия истекла. /unlock и попробуй снова.")
    data = await state.get_data()
    w = await repo.get_active_wallet(user_id)
    try:
        tx = await execute_swap(
            repo=repo, wallet_row=w, password=password,
            jetton_master=data["jetton_master"], side="buy",
            amount_in_units=int(data["amount"]),
            slippage_pct=settings.default_slippage,
            dex_name=data.get("dex"),
        )
    except TradeError as e:
        await state.clear()
        return await cb.message.edit_text(f"Ошибка: {e}")
    await state.clear()
    await cb.message.edit_text(f"Свап отправлен. tx: <code>{tx}</code>")


# ----------------------- SELL (jetton -> TON) -----------------------

@router.message(Command("sell"))
@router.callback_query(F.data == "menu:sell")
async def sell_start(event: Message | CallbackQuery, state: FSMContext, repo: Repo):
    user_id = event.from_user.id
    msg = event.message if isinstance(event, CallbackQuery) else event
    if not await repo.get_active_wallet(user_id):
        return await msg.answer("Сначала добавь кошелёк: /addwallet")
    if not _require_unlock(user_id):
        return await msg.answer("Сессия заблокирована. Разлочь: /unlock")
    await state.set_state(Sell.waiting_jetton)
    await msg.answer("Адрес master-контракта jetton (EQ.../UQ...):")


@router.message(Sell.waiting_jetton)
async def sell_jetton(msg: Message, state: FSMContext, repo: Repo):
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
    await state.set_state(Sell.waiting_jetton_amount)
    await msg.answer(
        f"Баланс: {fmt_amount(raw, decimals)}\n"
        "Сколько продать? Можно число (в полных единицах) или 'all'."
    )


@router.message(Sell.waiting_jetton_amount)
async def sell_amount(msg: Message, state: FSMContext):
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
    dex = get_dex()
    try:
        q = await dex.quote(data["jetton_master"], "sell", units)
    except Exception as e:
        await state.clear()
        return await msg.answer(f"Не получилось получить котировку: {e}")
    await state.update_data(amount=units, est_out=q.amount_out, dex=dex.name)
    await state.set_state(Sell.confirm)
    await msg.answer(
        f"<b>Продажа</b> через {dex.name}\n"
        f"Отдать: {fmt_amount(units, decimals)}\n"
        f"Получишь ≈ {q.amount_out / 10**9:.4f} TON\n"
        f"Slippage: {settings.default_slippage}%\n\n"
        "Подтвердить?",
        reply_markup=confirm_cancel("sell:confirm"),
    )


@router.callback_query(Sell.confirm, F.data == "sell:confirm")
async def sell_confirm(cb: CallbackQuery, state: FSMContext, repo: Repo):
    user_id = cb.from_user.id
    password = _require_unlock(user_id)
    if not password:
        await state.clear()
        return await cb.message.edit_text("Сессия истекла. /unlock и попробуй снова.")
    data = await state.get_data()
    w = await repo.get_active_wallet(user_id)
    try:
        tx = await execute_swap(
            repo=repo, wallet_row=w, password=password,
            jetton_master=data["jetton_master"], side="sell",
            amount_in_units=int(data["amount"]),
            slippage_pct=settings.default_slippage,
            dex_name=data.get("dex"),
        )
    except TradeError as e:
        await state.clear()
        return await cb.message.edit_text(f"Ошибка: {e}")
    await state.clear()
    await cb.message.edit_text(f"Свап отправлен. tx: <code>{tx}</code>")


# ----------------------- common cancel -----------------------

@router.callback_query(F.data == "cancel")
async def cancel_any(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    await cb.message.edit_text("Отменено.")
