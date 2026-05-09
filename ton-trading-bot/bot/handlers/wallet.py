from aiogram import F, Router
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message

from ..config import settings
from ..db.repository import Repo
from ..services import crypto
from ..services.ton_client import wallet_from_mnemonic, get_ton_balance, get_jetton_balance
from ..services.wallet_unlock import unlock_cache
from ..states.flows import AddWallet, Unlock
from ..utils.format import short_addr

router = Router()


def _delete_when_possible(msg: Message):
    """Best-effort delete (for hiding mnemonic / password from chat)."""
    return msg.chat.bot.delete_message(msg.chat.id, msg.message_id)


# ---------- list / balance ----------

@router.message(Command("wallet"))
@router.callback_query(F.data == "menu:wallet")
async def show_wallets(event: Message | CallbackQuery, repo: Repo):
    user_id = event.from_user.id
    await repo.ensure_user(user_id)
    wallets = await repo.list_wallets(user_id)
    if not wallets:
        text = (
            "Кошельков нет.\n\n"
            "Добавь кошелёк командой /addwallet — потребуется 24-словный мнемоник "
            "и пароль для шифрования. Пароль хранится только в памяти на 15 минут."
        )
    else:
        rows = [
            f"#{w.id} <b>{w.label}</b>  <code>{short_addr(w.address, 6, 6)}</code>"
            for w in wallets
        ]
        text = "Твои кошельки:\n\n" + "\n".join(rows) + "\n\n/balance — показать балансы\n/addwallet — добавить ещё\n/removewallet ID — удалить"
    target = event.message if isinstance(event, CallbackQuery) else event
    await target.answer(text)


@router.message(Command("balance"))
async def balance_cmd(msg: Message, repo: Repo):
    wallets = await repo.list_wallets(msg.from_user.id)
    if not wallets:
        return await msg.answer("Сначала добавь кошелёк: /addwallet")
    lines = []
    for w in wallets:
        try:
            ton = await get_ton_balance(w.address)
            lines.append(f"#{w.id} {w.label}: {ton:.4f} TON  <code>{short_addr(w.address, 6, 6)}</code>")
        except Exception as e:
            lines.append(f"#{w.id} {w.label}: ошибка ({e})")
    await msg.answer("\n".join(lines))


# ---------- add wallet flow ----------

@router.message(Command("addwallet"))
async def addwallet_start(msg: Message, state: FSMContext):
    await state.set_state(AddWallet.waiting_label)
    await msg.answer("Дай название кошельку (например, <i>main</i>):")


@router.message(AddWallet.waiting_label)
async def addwallet_label(msg: Message, state: FSMContext):
    label = (msg.text or "").strip()
    if not label or len(label) > 32:
        return await msg.answer("Название 1–32 символа. Попробуй ещё раз:")
    await state.update_data(label=label)
    await state.set_state(AddWallet.waiting_mnemonic)
    await msg.answer(
        "Пришли <b>24 слова</b> мнемоника TON-кошелька одним сообщением.\n\n"
        "⚠️ После приёма я удалю это сообщение из чата. "
        "Мнемоник будет зашифрован паролем, который ты задашь следующим шагом, "
        "и сохранён только в зашифрованном виде."
    )


@router.message(AddWallet.waiting_mnemonic)
async def addwallet_mnemonic(msg: Message, state: FSMContext):
    mnemonic = (msg.text or "").strip()
    try:
        await _delete_when_possible(msg)
    except Exception:
        pass
    words = mnemonic.split()
    if len(words) not in (12, 24):
        await msg.answer("Ожидал 12 или 24 слова. /addwallet чтобы начать заново.")
        return await state.clear()
    try:
        kp = await wallet_from_mnemonic(mnemonic)
    except Exception as e:
        await msg.answer(f"Не получилось восстановить кошелёк: {e}")
        return await state.clear()
    await state.update_data(mnemonic=mnemonic, address=kp.address)
    await state.set_state(AddWallet.waiting_password)
    await msg.answer(
        f"Адрес: <code>{kp.address}</code>\n\n"
        "Теперь придумай <b>пароль</b> (≥ 8 символов). Им будет зашифрован мнемоник.\n"
        "Если потеряешь пароль — придётся удалить кошелёк и добавить заново."
    )


@router.message(AddWallet.waiting_password)
async def addwallet_password(msg: Message, state: FSMContext, repo: Repo):
    password = (msg.text or "")
    try:
        await _delete_when_possible(msg)
    except Exception:
        pass
    if len(password) < 8:
        await msg.answer("Пароль должен быть ≥ 8 символов. /addwallet чтобы начать заново.")
        return await state.clear()
    data = await state.get_data()
    salt = crypto.new_user_salt()
    ct = crypto.encrypt_secret(data["mnemonic"], password, settings.master_salt, salt)
    wallet_id = await repo.add_wallet(
        user_id=msg.from_user.id,
        label=data["label"],
        address=data["address"],
        user_salt=salt,
        ciphertext=ct,
        secret_kind="mnemonic",
    )
    unlock_cache.unlock(msg.from_user.id, password)
    await state.clear()
    await msg.answer(
        f"Кошелёк #{wallet_id} <b>{data['label']}</b> добавлен.\n"
        f"<code>{data['address']}</code>\n\n"
        "Сессия разлочена на 15 минут — можешь сразу торговать."
    )


# ---------- remove ----------

@router.message(Command("removewallet"))
async def removewallet(msg: Message, repo: Repo):
    parts = (msg.text or "").split()
    if len(parts) != 2 or not parts[1].isdigit():
        return await msg.answer("Использование: /removewallet <id>")
    wid = int(parts[1])
    w = await repo.get_wallet(wid, msg.from_user.id)
    if not w:
        return await msg.answer("Кошелёк не найден.")
    await repo.delete_wallet(wid, msg.from_user.id)
    await msg.answer(f"Кошелёк #{wid} удалён.")


# ---------- unlock / lock ----------

@router.message(Command("unlock"))
async def unlock_cmd(msg: Message, state: FSMContext):
    await state.set_state(Unlock.waiting_password)
    await msg.answer("Пришли пароль (сообщение будет удалено):")


@router.message(Unlock.waiting_password)
async def unlock_password(msg: Message, state: FSMContext, repo: Repo):
    password = msg.text or ""
    try:
        await _delete_when_possible(msg)
    except Exception:
        pass
    await state.clear()
    # verify by trying to decrypt the active wallet's secret
    w = await repo.get_active_wallet(msg.from_user.id)
    if not w:
        return await msg.answer("Сначала добавь кошелёк: /addwallet")
    try:
        crypto.decrypt_secret(w.ciphertext, password, settings.master_salt, w.user_salt)
    except ValueError:
        return await msg.answer("Неверный пароль.")
    unlock_cache.unlock(msg.from_user.id, password)
    await msg.answer("Кошелёк разлочен на 15 минут.")


@router.message(Command("lock"))
async def lock_cmd(msg: Message):
    unlock_cache.lock(msg.from_user.id)
    await msg.answer("Сессия заблокирована.")
