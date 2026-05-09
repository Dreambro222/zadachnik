from aiogram.fsm.state import State, StatesGroup


class AddWallet(StatesGroup):
    waiting_label = State()
    waiting_mnemonic = State()
    waiting_password = State()


class Unlock(StatesGroup):
    waiting_password = State()


class Buy(StatesGroup):
    waiting_jetton = State()
    waiting_ton_amount = State()
    confirm = State()


class Sell(StatesGroup):
    waiting_jetton = State()
    waiting_jetton_amount = State()
    confirm = State()


class CreateOrder(StatesGroup):
    waiting_kind = State()
    waiting_jetton = State()
    waiting_amount = State()
    waiting_trigger_price = State()
    confirm = State()
